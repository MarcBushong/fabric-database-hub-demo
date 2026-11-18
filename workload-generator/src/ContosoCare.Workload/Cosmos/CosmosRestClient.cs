using System.Buffers;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace ContosoCare.Workload.Cosmos;

/// <summary>One answer from T5: its HTTP status, what it cost, and the headers a caller acts on. The body is kept for metadata reads, queries, and error messages.</summary>
internal sealed record CosmosResponse(int StatusCode, double RequestCharge, TimeSpan? RetryAfter, int? SubStatus, string? ActivityId, string Body)
{
    public bool IsSuccess => StatusCode is >= 200 and < 300;

    public bool IsThrottled => StatusCode == (int)HttpStatusCode.TooManyRequests;

    /// <summary>A 404 on a point read: the document isn't there (a normal miss), unless the substatus says its container isn't (1003).</summary>
    public bool IsDocumentMiss => StatusCode == (int)HttpStatusCode.NotFound && SubStatus is null or 0;

    /// <summary>HTTP 408, 410, 449, and 5xx: the service asks the client to try again.</summary>
    public bool IsTransient => StatusCode is 408 or 410 or 449 or >= 500;

    /// <summary>The failure this answer means, with a message that says what to do. <paramref name="what"/> names the request, for example "Reading the container".</summary>
    public CosmosException ToException(string what, string host)
    {
        var status = string.Create(CultureInfo.InvariantCulture, $"HTTP {StatusCode}{(SubStatus is > 0 ? ", substatus " + SubStatus.Value.ToString(CultureInfo.InvariantCulture) : string.Empty)}");
        var activity = ActivityId is null ? string.Empty : " Activity ID " + ActivityId + ".";
        var service = ServiceMessage(Body) is { } text ? " Cosmos DB says: " + text : string.Empty;
        return StatusCode switch
        {
            401 or 403 => new CosmosException(
                CosmosFailure.Forbidden,
                $"{what} was refused ({status}): T1's managed identity has no data-plane access to T5 ({host}) yet. It needs the Cosmos DB Built-in Data Contributor role on the account, which deploy.ps1 assigns; a new assignment can take a few minutes to take effect.{service}{activity}",
                StatusCode,
                SubStatus,
                ActivityId),
            404 => new CosmosException(
                CosmosFailure.NotFound,
                $"{what} found nothing ({status}): T5 ({host}) has no database '{CosmosEndpoint.DatabaseName}' with a container '{CosmosEndpoint.ContainerName}'. The template creates them; run deploy.ps1.{activity}",
                StatusCode,
                SubStatus,
                ActivityId),
            429 => new CosmosException(
                CosmosFailure.Throttled,
                $"{what} was throttled ({status}, request rate too large): the container's throughput is used up, for example by ru-storm.{activity}",
                StatusCode,
                SubStatus,
                ActivityId),
            _ when IsTransient => new CosmosException(CosmosFailure.Transient, $"{what} failed ({status}), a transient service error.{service}{activity}", StatusCode, SubStatus, ActivityId),
            _ => new CosmosException(CosmosFailure.Request, $"{what} was refused ({status}).{service}{activity}", StatusCode, SubStatus, ActivityId),
        };
    }

    /// <summary>The first line of the service's error message (the body's "message"), shortened; null when there's none.</summary>
    internal static string? ServiceMessage(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            var line = (message.GetString() ?? string.Empty).ReplaceLineEndings("\n").Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();
            if (string.IsNullOrEmpty(line))
            {
                return null;
            }

            if (line.StartsWith("Message: ", StringComparison.Ordinal))
            {
                line = line["Message: ".Length..];
            }

            return line.Length <= 300 ? line : line[..297] + "...";
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>What the runner reads from T5's container definition: its partition key, and its default time to live.</summary>
internal sealed record CosmosContainerInfo(string Id, IReadOnlyList<string> PartitionKeyPaths, string? PartitionKeyKind, int? PartitionKeyVersion, int? DefaultTtl)
{
    public string? PartitionKeyPath => PartitionKeyPaths.Count > 0 ? PartitionKeyPaths[0] : null;

    /// <summary>True when the container is partitioned on <c>/patientId</c>, as the template creates it.</summary>
    public bool HasExpectedPartitionKey => PartitionKeyPaths.Count == 1 && string.Equals(PartitionKeyPath, CosmosEndpoint.PartitionKeyPath, StringComparison.Ordinal);

    public string DescribePartitionKey() => PartitionKeyPaths.Count == 0
        ? "no partition key"
        : string.Create(CultureInfo.InvariantCulture, $"{string.Join(", ", PartitionKeyPaths)} ({PartitionKeyKind ?? "?"}{(PartitionKeyVersion is { } version ? " v" + version.ToString(CultureInfo.InvariantCulture) : string.Empty)})");

    public static CosmosContainerInfo Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var id = root.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.String ? idElement.GetString() ?? string.Empty : string.Empty;
        var paths = new List<string>();
        string? kind = null;
        int? version = null;
        if (root.TryGetProperty("partitionKey", out var key) && key.ValueKind == JsonValueKind.Object)
        {
            if (key.TryGetProperty("paths", out var array) && array.ValueKind == JsonValueKind.Array)
            {
                paths.AddRange(array.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.String).Select(p => p.GetString()!));
            }

            kind = key.TryGetProperty("kind", out var kindElement) && kindElement.ValueKind == JsonValueKind.String ? kindElement.GetString() : null;
            version = key.TryGetProperty("version", out var versionElement) && versionElement.TryGetInt32(out var number) ? number : null;
        }

        int? ttl = root.TryGetProperty("defaultTtl", out var ttlElement) && ttlElement.TryGetInt32(out var seconds) ? seconds : null;
        return new CosmosContainerInfo(id, paths, kind, version, ttl);
    }
}

/// <summary>
/// T5's data-plane client: the documented Azure Cosmos DB REST API over HTTPS (port 443, the gateway), with a Microsoft
/// Entra token in every request's Authorization header (<c>type=aad&amp;ver=1.0&amp;sig=&lt;token&gt;</c>, URL-encoded).
/// It only reads the container's definition and upserts, reads, queries, and deletes documents in
/// <c>contosocare/patient-events</c>, within one partition per request. Every request's User-Agent starts with the run's
/// tag, <c>ContosoCare.Demo/&lt;scenario&gt;/&lt;run&gt;</c>. One pooled HttpClient per runner; each request may take 30
/// seconds. It never logs a header, so the token can't reach a log, and its errors never contain it.
/// </summary>
internal sealed class CosmosRestClient : IDisposable
{
    /// <summary>The REST API version every request sends (x-ms-version).</summary>
    public const string ApiVersion = "2018-12-31";

    /// <summary>The most documents one query page returns (x-ms-max-item-count).</summary>
    public const int MaxItemCount = 10;

    /// <summary>The longest one request may take.</summary>
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);

    private readonly HttpClient http;
    private readonly ICosmosTokenSource tokens;
    private readonly string product = "ContosoCare.Workload/" + Program.GetVersion();

    public CosmosRestClient(CosmosEndpoint endpoint, ICosmosTokenSource tokens, HttpMessageHandler? handler = null)
    {
        Endpoint = endpoint;
        this.tokens = tokens;
        http = new HttpClient(handler ?? CreateHandler(), disposeHandler: true) { BaseAddress = endpoint.BaseUri, Timeout = RequestTimeout };
    }

    public CosmosEndpoint Endpoint { get; }

    /// <summary>T1's connection pool: connections recycled every 5 minutes (so DNS changes, such as a private endpoint's, are picked up) and enough of them for 16 writers and the baseline.</summary>
    public static SocketsHttpHandler CreateHandler() => new()
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        MaxConnectionsPerServer = 64,
        ConnectTimeout = TimeSpan.FromSeconds(15),
    };

    /// <summary>Creates or replaces a document (Upsert Document): POST .../docs with x-ms-documentdb-is-upsert.</summary>
    public Task<CosmosResponse> UpsertAsync(string tag, string partitionKey, byte[] document, CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Post, CosmosEndpoint.DocumentsPath, tag, partitionKey, document, "application/json", [("x-ms-documentdb-is-upsert", "True")], cancellationToken);

    /// <summary>Reads one document (Get Document); a 404 is a normal miss.</summary>
    public Task<CosmosResponse> ReadAsync(string tag, string partitionKey, string id, CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Get, CosmosEndpoint.DocumentsPath + "/" + Uri.EscapeDataString(id), tag, partitionKey, null, null, [], cancellationToken);

    /// <summary>Deletes one document (Delete Document): 204, or 404 when it's already gone.</summary>
    public Task<CosmosResponse> DeleteAsync(string tag, string partitionKey, string id, CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Delete, CosmosEndpoint.DocumentsPath + "/" + Uri.EscapeDataString(id), tag, partitionKey, null, null, [], cancellationToken);

    /// <summary>A parameterized query within one partition (Query Documents): POST .../docs with x-ms-documentdb-isquery and application/query+json; one page of at most <paramref name="maxItemCount"/> documents.</summary>
    public Task<CosmosResponse> QueryAsync(string tag, string partitionKey, string query, IReadOnlyList<KeyValuePair<string, string>> parameters, int maxItemCount, CancellationToken cancellationToken) =>
        SendAsync(
            HttpMethod.Post,
            CosmosEndpoint.DocumentsPath,
            tag,
            partitionKey,
            QueryBody(query, parameters),
            "application/query+json",
            [("x-ms-documentdb-isquery", "True"), ("x-ms-max-item-count", maxItemCount.ToString(CultureInfo.InvariantCulture))],
            cancellationToken);

    /// <summary>Reads the container's definition (Get Collection): its partition key, indexing policy, and time to live.</summary>
    public Task<CosmosResponse> ReadContainerAsync(string tag, CancellationToken cancellationToken) =>
        SendAsync(HttpMethod.Get, CosmosEndpoint.ContainerPath, tag, null, null, null, [], cancellationToken);

    public void Dispose() => http.Dispose();

    /// <summary>The Authorization header for a Microsoft Entra token (access control on Cosmos DB resources): URL-encoded <c>type=aad&amp;ver=1.0&amp;sig=&lt;token&gt;</c>.</summary>
    internal static string AuthorizationHeader(string token) => Uri.EscapeDataString("type=aad&ver=1.0&sig=" + token);

    /// <summary>x-ms-documentdb-partitionkey: the partition key value as a JSON array, for example <c>["p-0001"]</c>.</summary>
    internal static string PartitionKeyHeader(string value) => "[\"" + JsonEncodedText.Encode(value).ToString() + "\"]";

    /// <summary>A query's body: its text and its parameters, so values never become part of the text.</summary>
    internal static byte[] QueryBody(string query, IReadOnlyList<KeyValuePair<string, string>> parameters)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteString("query", query);
            json.WriteStartArray("parameters");
            foreach (var (name, value) in parameters)
            {
                json.WriteStartObject();
                json.WriteString("name", name);
                json.WriteString("value", value);
                json.WriteEndObject();
            }

            json.WriteEndArray();
            json.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    private string UserAgent(string tag) => tag + " " + product;

    private async Task<CosmosResponse> SendAsync(
        HttpMethod method,
        string path,
        string tag,
        string? partitionKey,
        byte[]? body,
        string? contentType,
        (string Name, string Value)[] headers,
        CancellationToken cancellationToken)
    {
        var token = await tokens.GetTokenAsync(cancellationToken).ConfigureAwait(false);
        using var request = new HttpRequestMessage(method, path);
        request.Headers.TryAddWithoutValidation("Authorization", AuthorizationHeader(token));
        request.Headers.TryAddWithoutValidation("x-ms-date", DateTimeOffset.UtcNow.ToString("R", CultureInfo.InvariantCulture));
        request.Headers.TryAddWithoutValidation("x-ms-version", ApiVersion);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent(tag));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (partitionKey is not null)
        {
            request.Headers.TryAddWithoutValidation("x-ms-documentdb-partitionkey", PartitionKeyHeader(partitionKey));
        }

        foreach (var (name, value) in headers)
        {
            request.Headers.TryAddWithoutValidation(name, value);
        }

        if (body is not null)
        {
            // No charset parameter: the service expects exactly application/json or application/query+json.
            request.Content = new ByteArrayContent(body);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType ?? "application/json");
        }

        try
        {
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var text = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            return new CosmosResponse((int)response.StatusCode, Charge(response), RetryAfter(response), SubStatus(response), Header(response, "x-ms-activity-id"), text);
        }
        catch (HttpRequestException ex)
        {
            throw new CosmosException(CosmosFailure.Unreachable, $"Can't reach T5 ({Endpoint.Host}) over HTTPS: {Describe(ex)}", innerException: ex);
        }
        catch (TaskCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new CosmosException(CosmosFailure.Unreachable, string.Create(CultureInfo.InvariantCulture, $"T5 ({Endpoint.Host}) didn't answer within {RequestTimeout.TotalSeconds:0} s."), innerException: ex);
        }
    }

    private static string Describe(HttpRequestException exception) => exception.HttpRequestError switch
    {
        HttpRequestError.NameResolutionError => $"its name doesn't resolve ({exception.Message}). In private mode it resolves through the private endpoint's DNS zone, privatelink.documents.azure.com.",
        HttpRequestError.ConnectionError => $"the connection failed ({exception.Message}). T1 reaches it on TCP 443 only: through the private endpoint, or the account's virtual network rule for T1's subnet.",
        HttpRequestError.SecureConnectionError => $"TLS failed ({exception.Message}).",
        _ => exception.Message,
    };

    private static string? Header(HttpResponseMessage response, string name) =>
        response.Headers.TryGetValues(name, out var values) ? values.FirstOrDefault() : null;

    private static double Charge(HttpResponseMessage response) =>
        double.TryParse(Header(response, "x-ms-request-charge"), NumberStyles.Float, CultureInfo.InvariantCulture, out var charge) && charge >= 0 ? charge : 0;

    private static TimeSpan? RetryAfter(HttpResponseMessage response) =>
        double.TryParse(Header(response, "x-ms-retry-after-ms"), NumberStyles.Float, CultureInfo.InvariantCulture, out var milliseconds) && milliseconds >= 0
            ? TimeSpan.FromMilliseconds(milliseconds)
            : null;

    private static int? SubStatus(HttpResponseMessage response) =>
        int.TryParse(Header(response, "x-ms-substatus"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var subStatus) ? subStatus : null;
}
