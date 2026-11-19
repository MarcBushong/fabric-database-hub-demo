using System.Globalization;
using System.Net;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Cosmos;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// T5's REST client against a fake account (no Cosmos DB account is needed): the documented headers, the Microsoft Entra
/// authorization and its scope fallback, the status codes the runner acts on, and that the token never reaches an error.
/// Also the workload's pure parts: the baseline's mix, the storm's waves, ids, and pacing, and the live rates.
/// </summary>
public sealed class CosmosClientTests
{
    private const string Host = "cosmos01-abc123.documents.azure.com";

    private static readonly CosmosEndpoint Endpoint = CosmosEndpoint.Create(Host, null);

    [Theory]
    [InlineData("cosmos01-abc123.documents.azure.com", "cosmos01-abc123.documents.azure.com")]
    [InlineData(" COSMOS01-ABC123.documents.azure.com ", "cosmos01-abc123.documents.azure.com")]
    public void TheEndpointTakesTheAccountsHostName(string server, string host)
    {
        var endpoint = CosmosEndpoint.Create(server, "00000000-0000-0000-0000-000000000001");

        Assert.Equal(host, endpoint.Host);
        Assert.Equal(new Uri("https://" + host + "/"), endpoint.BaseUri);
        Assert.Equal($"https://{host}/.default", endpoint.AccountScope);
        Assert.Contains("user-assigned identity", endpoint.Describe(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("cosmos01-abc123")]
    [InlineData("https://cosmos01-abc123.documents.azure.com:443/")]
    [InlineData("cosmos01-abc123.documents.azure.com:443")]
    [InlineData("cosmos01_abc123.documents.azure.com")]
    [InlineData("-cosmos01.documents.azure.com")]
    [InlineData("cosmos01-abc123.postgres.database.azure.com")]
    [InlineData("c.documents.azure.com")]
    public void TheEndpointRefusesAnythingButAnAccountHostName(string? server) =>
        Assert.Throws<ScenarioRequestException>(() => CosmosEndpoint.Create(server, null));

    [Fact]
    public void TheManagedIdentityClientIdMustBeAGuid() =>
        Assert.Throws<ScenarioRequestException>(() => CosmosEndpoint.Create(Host, "not-a-guid"));

    [Fact]
    public async Task AnUpsertSendsTheDocumentedHeaders()
    {
        var account = new FakeCosmosAccount();
        var tokens = new FakeTokens();
        using var client = new CosmosRestClient(Endpoint, tokens, account);
        var document = CosmosDocuments.Event("hb-ev-3", "p-0042", "vitals", 7, DateTimeOffset.UtcNow, "ContosoCare.Demo/healthy-baseline/20261118160000-t5-a1b2c3", 512);

        var response = await client.UpsertAsync("ContosoCare.Demo/healthy-baseline/20261118160000-t5-a1b2c3", "p-0042", document, TestContext.Current.CancellationToken);

        Assert.Equal(200, response.StatusCode);
        Assert.Equal(8.38, response.RequestCharge);
        var request = Assert.Single(account.Requests);
        Assert.Equal("POST", request.Method);
        Assert.Equal(FakeCosmosAccount.DocumentsPath, request.Path);
        Assert.Equal("type%3Daad%26ver%3D1.0%26sig%3D" + tokens.Token, request.Header("Authorization"));
        Assert.Equal(Uri.EscapeDataString("type=aad&ver=1.0&sig=" + tokens.Token), request.Header("Authorization"));
        Assert.Equal("2018-12-31", request.Header("x-ms-version"));
        Assert.True(DateTimeOffset.TryParseExact(request.Header("x-ms-date"), "R", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date));
        Assert.True(Math.Abs((DateTimeOffset.UtcNow - date).TotalMinutes) < 5);
        Assert.Equal("[\"p-0042\"]", request.Header("x-ms-documentdb-partitionkey"));
        Assert.Equal("True", request.Header("x-ms-documentdb-is-upsert"));
        Assert.Equal("application/json", request.Header("Content-Type"));
        Assert.StartsWith("ContosoCare.Demo/healthy-baseline/20261118160000-t5-a1b2c3 ContosoCare.Workload/", request.Header("User-Agent"), StringComparison.Ordinal);
        Assert.Null(request.Header("x-ms-documentdb-isquery"));

        // The bulk is one top-level, unindexed string; the indexed properties stay at the top level.
        using var json = JsonDocument.Parse(request.Body!);
        Assert.Equal("hb-ev-3", json.RootElement.GetProperty("id").GetString());
        Assert.Equal("p-0042", json.RootElement.GetProperty("patientId").GetString());
        Assert.Equal("vitals", json.RootElement.GetProperty("type").GetString());
        Assert.True(json.RootElement.TryGetProperty("at", out _));
        Assert.StartsWith("ContosoCare.Demo/healthy-baseline/", json.RootElement.GetProperty("source").GetString(), StringComparison.Ordinal);
        Assert.Equal(512, json.RootElement.GetProperty("payload").GetString()!.Length);
    }

    [Fact]
    public async Task AQueryIsParameterizedWithinOnePartition()
    {
        var account = new FakeCosmosAccount();
        using var client = new CosmosRestClient(Endpoint, new FakeTokens(), account);

        var response = await client.QueryAsync("ContosoCare.Demo/control/test", "p-0001", HealthyBaselineMix.Query, [new KeyValuePair<string, string>("@p", "p-0001")], CosmosRestClient.MaxItemCount, TestContext.Current.CancellationToken);

        Assert.Equal(200, response.StatusCode);
        var request = Assert.Single(account.Requests);
        Assert.Equal("True", request.Header("x-ms-documentdb-isquery"));
        Assert.Equal("application/query+json", request.Header("Content-Type"));
        Assert.Equal("10", request.Header("x-ms-max-item-count"));
        Assert.Equal("[\"p-0001\"]", request.Header("x-ms-documentdb-partitionkey"));
        using var body = JsonDocument.Parse(request.Body!);
        Assert.Equal("SELECT TOP 5 c.id, c.type, c.at FROM c WHERE c.patientId = @p ORDER BY c._ts DESC", body.RootElement.GetProperty("query").GetString());
        var parameter = Assert.Single(body.RootElement.GetProperty("parameters").EnumerateArray());
        Assert.Equal("@p", parameter.GetProperty("name").GetString());
        Assert.Equal("p-0001", parameter.GetProperty("value").GetString());
    }

    [Fact]
    public async Task PointReadsDeletesAndTheContainerReadUseTheirResourcePaths()
    {
        var account = new FakeCosmosAccount();
        account.Put("p-0002", "patient");
        using var client = new CosmosRestClient(Endpoint, new FakeTokens(), account);
        var token = TestContext.Current.CancellationToken;

        Assert.Equal(200, (await client.ReadAsync("t", "p-0002", "patient", token)).StatusCode);
        var miss = await client.ReadAsync("t", "p-0002", "hb-ev-4", token);
        Assert.Equal(404, miss.StatusCode);
        Assert.True(miss.IsDocumentMiss);
        Assert.Equal(204, (await client.DeleteAsync("t", "p-0002", "patient", token)).StatusCode);
        Assert.Equal(404, (await client.DeleteAsync("t", "p-0002", "patient", token)).StatusCode);
        var container = CosmosContainerInfo.Parse((await client.ReadContainerAsync("t", token)).Body);

        Assert.True(container.HasExpectedPartitionKey);
        Assert.Equal("/patientId (Hash v2)", container.DescribePartitionKey());
        var requests = account.Requests.ToList();
        Assert.Equal(["GET", "GET", "DELETE", "DELETE", "GET"], requests.Select(r => r.Method));
        Assert.Equal(FakeCosmosAccount.DocumentsPath + "/patient", requests[0].Path);
        Assert.Equal(FakeCosmosAccount.ContainerPath, requests[4].Path);
        Assert.Null(requests[4].Header("x-ms-documentdb-partitionkey"));
    }

    [Fact]
    public async Task A429CarriesItsRetryAfterAndTheWaitIsBounded()
    {
        var account = new FakeCosmosAccount { ThrottleEvery = 1, RetryAfterMs = 37 };
        using var client = new CosmosRestClient(Endpoint, new FakeTokens(), account);

        var response = await client.UpsertAsync("t", "p-storm-01", CosmosDocuments.StormReading("storm-01-000", "p-storm-01", 1, 0, DateTimeOffset.UtcNow, "t", 200), TestContext.Current.CancellationToken);

        Assert.True(response.IsThrottled);
        Assert.Equal(TimeSpan.FromMilliseconds(37), response.RetryAfter);
        Assert.Equal(3200, response.SubStatus);
        Assert.NotNull(response.ActivityId);
        Assert.Equal(TimeSpan.FromMilliseconds(37), RuStorm.RetryWait(response.RetryAfter));
        Assert.Equal(RuStorm.MinimumRetryAfter, RuStorm.RetryWait(TimeSpan.FromMilliseconds(1)));
        Assert.Equal(RuStorm.MaximumRetryAfter, RuStorm.RetryWait(TimeSpan.FromSeconds(30)));
        Assert.Equal(RuStorm.DefaultRetryAfter, RuStorm.RetryWait(null));
        Assert.Equal(CosmosFailure.Throttled, response.ToException("A write", Host).Failure);
    }

    [Fact]
    public async Task A403SaysTheDataPlaneRoleIsMissingAndIsARefusalThatPasses()
    {
        var account = new FakeCosmosAccount { FailWith = HttpStatusCode.Forbidden };
        var tokens = new FakeTokens();
        using var client = new CosmosRestClient(Endpoint, tokens, account);

        var response = await client.ReadContainerAsync("t", TestContext.Current.CancellationToken);
        var failure = response.ToException("Reading T5's container", Host);

        Assert.Equal(CosmosFailure.Forbidden, failure.Failure);
        Assert.Equal("connect", failure.RefusalReason);
        Assert.Contains("Cosmos DB Built-in Data Contributor", failure.Message, StringComparison.Ordinal);
        Assert.Contains("deploy.ps1", failure.Message, StringComparison.Ordinal);
        Assert.Contains("substatus 5301", failure.Message, StringComparison.Ordinal);
        Assert.Contains("required RBAC permissions", failure.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("ActivityId: 0000", failure.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(tokens.Token, failure.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(404, "NotFound", "request")]
    [InlineData(400, "Request", "request")]
    [InlineData(503, "Transient", "connect")]
    [InlineData(408, "Transient", "connect")]
    [InlineData(401, "Forbidden", "connect")]
    public void StatusCodesMapToFailuresAndRefusalReasons(int status, string failure, string reason)
    {
        var exception = new CosmosResponse(status, 0, null, null, null, string.Empty).ToException("A request", Host);

        Assert.Equal(Enum.Parse<CosmosFailure>(failure), exception.Failure);
        Assert.Equal(reason, exception.RefusalReason);
    }

    [Fact]
    public async Task AnAccountThatCantBeReachedIsAConnectFailureWithoutTheToken()
    {
        var account = new FakeCosmosAccount { ThrowWith = new HttpRequestException(HttpRequestError.NameResolutionError, "No such host is known. (cosmos01-abc123.documents.azure.com:443)") };
        var tokens = new FakeTokens();
        using var client = new CosmosRestClient(Endpoint, tokens, account);

        var failure = await Assert.ThrowsAsync<CosmosException>(() => client.ReadContainerAsync("t", TestContext.Current.CancellationToken));

        Assert.Equal(CosmosFailure.Unreachable, failure.Failure);
        Assert.Equal("connect", failure.RefusalReason);
        Assert.Contains("doesn't resolve", failure.Message, StringComparison.Ordinal);
        Assert.Contains("privatelink.documents.azure.com", failure.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(tokens.Token, failure.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheTokenFallsBackToTheCosmosScopeOnAadsts500011AndIsReused()
    {
        var token = "fallback-" + Guid.NewGuid().ToString("N");
        var credential = new FakeCredential(scope => scope == Endpoint.AccountScope
            ? throw new AuthenticationFailedException("ManagedIdentityCredential authentication failed: AADSTS500011: The resource principal named https://" + Host + " was not found in the tenant.")
            : new AccessToken(token, DateTimeOffset.UtcNow.AddHours(1)));
        var provider = new CosmosTokenProvider(credential, Endpoint);
        var account = new FakeCosmosAccount();
        using var client = new CosmosRestClient(Endpoint, provider, account);

        await client.ReadContainerAsync("t", TestContext.Current.CancellationToken);
        await client.ReadContainerAsync("t", TestContext.Current.CancellationToken);

        Assert.Equal([Endpoint.AccountScope, CosmosEndpoint.FallbackScope], credential.Scopes);
        Assert.Equal(CosmosEndpoint.FallbackScope, provider.Scope);
        Assert.All(account.Requests, r => Assert.Equal(CosmosRestClient.AuthorizationHeader(token), r.Header("Authorization")));
    }

    [Fact]
    public async Task ATokenIsRefreshedFiveMinutesBeforeItExpires()
    {
        var issued = 0;
        var credential = new FakeCredential(_ => new AccessToken("token-" + Interlocked.Increment(ref issued).ToString(CultureInfo.InvariantCulture), DateTimeOffset.UtcNow.AddMinutes(4)));
        var provider = new CosmosTokenProvider(credential, Endpoint);
        var token = TestContext.Current.CancellationToken;

        var first = await provider.GetTokenAsync(token);
        var second = await provider.GetTokenAsync(token);

        Assert.NotEqual(first, second);
        Assert.Equal(Endpoint.AccountScope, provider.Scope);
        Assert.Equal(2, credential.Scopes.Count);
    }

    [Fact]
    public async Task ATokenFailureIsACosmosFailureWithoutTheCredentialsDetailLeaking()
    {
        var credential = new FakeCredential(_ => throw new CredentialUnavailableException("ManagedIdentityCredential authentication unavailable. No response from the IMDS endpoint."));
        var provider = new CosmosTokenProvider(credential, Endpoint);

        var failure = await Assert.ThrowsAsync<CosmosException>(() => provider.GetTokenAsync(TestContext.Current.CancellationToken).AsTask());

        Assert.Equal(CosmosFailure.Token, failure.Failure);
        Assert.Equal("connect", failure.RefusalReason);
        Assert.Contains("managed identity", failure.Message, StringComparison.Ordinal);
        Assert.Single(credential.Scopes);
    }

    [Fact]
    public void TheHeadersAreBuiltAsTheRestApiDocumentsThem()
    {
        Assert.Equal("[\"p-0001\"]", CosmosRestClient.PartitionKeyHeader("p-0001"));
        Assert.Equal("a\"b", System.Text.Json.Nodes.JsonNode.Parse(CosmosRestClient.PartitionKeyHeader("a\"b"))![0]!.GetValue<string>());
        Assert.Equal("type%3Daad%26ver%3D1.0%26sig%3Dabc.def-ghi_jkl", CosmosRestClient.AuthorizationHeader("abc.def-ghi_jkl"));
    }

    [Fact]
    public void TheBaselineMixIsFortyFortyTwentyOverItsBoundedIds()
    {
        var random = new Random(20261118);
        var counts = new Dictionary<CosmosOperationKind, int>();
        var patients = new HashSet<string>(StringComparer.Ordinal);
        for (var turn = 0L; turn < 20_000; turn++)
        {
            var operation = HealthyBaselineMix.Next(random.Next, turn);
            counts[operation.Kind] = counts.GetValueOrDefault(operation.Kind) + 1;
            patients.Add(operation.PatientId);
            Assert.Matches("^p-0(?:[0-4][0-9]{2}|500)$", operation.PatientId);
            Assert.NotEqual("p-0000", operation.PatientId);
            if (operation.Kind != CosmosOperationKind.Query)
            {
                Assert.Matches("^(patient|hb-ev-(?:1?[0-9]))$", operation.DocumentId!);
            }
        }

        Assert.InRange(counts[CosmosOperationKind.Read] / 20_000.0, 0.38, 0.42);
        Assert.InRange(counts[CosmosOperationKind.Upsert] / 20_000.0, 0.38, 0.42);
        Assert.InRange(counts[CosmosOperationKind.Query] / 20_000.0, 0.18, 0.22);
        Assert.Equal(HealthyBaselineMix.Patients, patients.Count);
        Assert.InRange(HealthyBaselineMix.EventPayloadLength(3), 512, 704);
    }

    [Theory]
    [InlineData(0, true, 1)]
    [InlineData(149, true, 1)]
    [InlineData(150, false, 1)]
    [InlineData(239, false, 1)]
    [InlineData(240, true, 2)]
    [InlineData(500, true, 3)]
    public void StormWavesAlternateWithCalms(int seconds, bool storm, int wave)
    {
        var phase = RuStorm.PhaseAt(TimeSpan.FromSeconds(seconds), 150, 90);

        Assert.Equal(storm, phase.Storm);
        Assert.Equal(wave, phase.Wave);
        Assert.True(phase.Remaining > TimeSpan.Zero);
    }

    [Fact]
    public void WithoutACalmTheStormNeverStops()
    {
        Assert.All(Enumerable.Range(0, 1000), second => Assert.True(RuStorm.PhaseAt(TimeSpan.FromSeconds(second), 30, 0).Storm));
    }

    [Fact]
    public void StormIdsAreAFixedSetPerHotPartition()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var writer = 1; writer <= 16; writer++)
        {
            for (var sequence = 0L; sequence < 5_000; sequence++)
            {
                ids.Add(RuStorm.DocumentId(RuStorm.PartitionNumberFor(writer, 4), writer, sequence));
            }
        }

        Assert.Equal(RuStorm.MaximumHotPartitions * RuStorm.DocumentsPerPartition, ids.Count);
        Assert.All(ids, id => Assert.Matches("^storm-0[1-4]-0[0-9]{2}$", id));
        Assert.Equal("p-storm-01", RuStorm.PartitionFor(5, 4));
        Assert.Equal("p-storm-02", RuStorm.PartitionFor(2, 4));
        Assert.Equal("p-storm-01", RuStorm.PartitionFor(3, 1));
    }

    [Theory]
    [InlineData(1, 200)]
    [InlineData(7, 67)]
    [InlineData(10, 0)]
    public void StormWritersPauseByIntensity(int intensity, int milliseconds) =>
        Assert.Equal(TimeSpan.FromMilliseconds(milliseconds), RuStorm.PauseFor(intensity));

    [Theory]
    [InlineData(1, 1000)]
    [InlineData(2, 895)]
    [InlineData(10, 50)]
    public void TheBaselinePacesLikeTheSqlTargets(int intensity, int milliseconds) =>
        Assert.Equal(TimeSpan.FromMilliseconds(milliseconds), CosmosPacing.BaselinePause(intensity));

    [Fact]
    public void StormDocumentsAreAboutTheirSizeAndTagged()
    {
        var document = CosmosDocuments.StormReading("storm-01-007", "p-storm-01", 3, 42, DateTimeOffset.UtcNow, "ContosoCare.Demo/ru-storm/r", RuStorm.PayloadLength(4));
        using var json = JsonDocument.Parse(document);

        Assert.InRange(document.Length, 3800, 4200);
        Assert.Equal(RuStorm.Kind, json.RootElement.GetProperty("kind").GetString());
        Assert.Equal("p-storm-01", json.RootElement.GetProperty("patientId").GetString());
        Assert.Equal(CosmosDocuments.MaximumPayloadLength, RuStorm.PayloadLength(16) + 320);
    }

    [Fact]
    public void LiveRatesCoverTheLastTenSecondsAndTheLastMinute()
    {
        var start = new DateTimeOffset(2026, 11, 18, 16, 0, 0, TimeSpan.Zero);
        var window = new LiveRateWindow(start);
        CosmosLiveRates rates = null!;
        for (var second = 5; second <= 120; second += 5)
        {
            // 10 requests, 50 RU, and 2 throttled a second.
            rates = window.Add(new CosmosMeterSample(start.AddSeconds(second), second * 10, second * 2, second * 50.0, 0));
        }

        Assert.Equal(10, rates.RequestsPerSecond);
        Assert.Equal(50, rates.RuPerSecond);
        Assert.Equal(2, rates.ThrottledPerSecond);
        Assert.Equal(120, rates.ThrottledLastMinute);
        Assert.Equal(start.AddSeconds(120), rates.UpdatedAt);
    }
}
