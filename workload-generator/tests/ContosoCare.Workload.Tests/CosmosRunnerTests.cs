using System.Text.Json;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Cosmos;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Xunit;
using CommandLineDefinition = ContosoCare.Workload.Cli.CommandLine;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// T5's runner on an accelerated clock against a fake account: healthy-baseline's mix stays in its bounded id space,
/// ru-storm alternates waves and calms, counts its 429s, and deletes its documents at the end, a stop ends a run within
/// seconds, and the deadline ends it. A container that doesn't exist now (it exists only during a session) is a refusal
/// the profile host tries again, with nothing for a cleanup to delete. Also status's JSON and T5's command line. No Cosmos
/// DB account is needed.
/// </summary>
public sealed class CosmosRunnerTests : IDisposable
{
    private const string Host = "cosmos01-abc123.documents.azure.com";

    private readonly string folder = Path.Combine(AppContext.BaseDirectory, "cosmos-runner-" + Guid.NewGuid().ToString("N"));

    private string StorePath => Path.Combine(folder, CosmosRunStore.FileName);

    public void Dispose()
    {
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public async Task HealthyBaselineStaysInItsBoundedIdSpaceAndEndsAtItsDeadline()
    {
        var time = new AcceleratedTime(20);
        var account = new FakeCosmosAccount(time);
        var tokens = new FakeTokens();
        using var writer = new StringWriter();
        using var log = new RunnerLog(writer);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), tokens, account);
        var runner = new CosmosScenarioRunner(client, new CosmosRunStore(StorePath, time), log, time);

        var result = await runner.RunAsync(Plan("healthy-baseline", TimeSpan.FromSeconds(30), concurrency: 4, intensity: 10, time), TestContext.Current.CancellationToken);

        Assert.Equal("Completed", result.Status);
        Assert.Equal("Pass", result.Result);
        Assert.InRange((result.EndedAt!.Value - result.DeadlineAt!.Value).TotalSeconds, -2, 10);
        var tag = SessionNames.ForRun("healthy-baseline", result.RunId);
        var work = account.Requests.Where(r => r.Header("User-Agent")!.StartsWith(tag + " ", StringComparison.Ordinal)).ToList();
        Assert.True(work.Count >= 40, $"Only {work.Count} requests ran.");
        Assert.Contains(work, r => r.IsUpsert);
        Assert.Contains(work, r => r.IsQuery);
        Assert.Contains(work, r => r.Method == "GET");
        Assert.All(work, r => Assert.Matches("^p-0(?:[0-4][0-9]{2}|500)$", r.PartitionKey));
        Assert.All(work.Where(r => r.Method == "GET"), r => Assert.Matches("^(patient|hb-ev-(?:1?[0-9]))$", r.DocumentId));
        foreach (var upsert in work.Where(r => r.IsUpsert))
        {
            var document = FakeCosmosAccount.Body(upsert);
            Assert.Matches("^(patient|hb-ev-(?:1?[0-9]))$", document["id"]!.GetValue<string>());
            Assert.Equal(upsert.PartitionKey, document["patientId"]!.GetValue<string>());
            Assert.Equal(tag, document["source"]!.GetValue<string>());
            Assert.InRange(document["payload"]!.GetValue<string>().Length, 512, 704);
            Assert.InRange(upsert.Body!.Length, 500, 1024);
        }

        Assert.All(work.Where(r => r.IsQuery), r => Assert.Equal("10", r.Header("x-ms-max-item-count")));
        Assert.All(account.Keys, k => Assert.Matches("^p-0", k.Partition));
        Assert.Contains(result.Checks, c => c.CheckId == "auto-cleanup" && c.Status == "Not selected");
        var stored = await new CosmosRunStore(StorePath).GetRunAsync(result.RunId, TestContext.Current.CancellationToken);
        Assert.Equal("Completed", stored!.Status);
        Assert.Equal(work.Count, stored.Counters!.Requests);
        Assert.DoesNotContain(tokens.Token, writer.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task RuStormAlternatesWavesAndCalmsCountsIts429sAndDeletesItsDocuments()
    {
        var time = new AcceleratedTime(40);
        var account = new FakeCosmosAccount(time) { ThrottleEvery = 3, RetryAfterMs = 100 };
        account.Put("p-0007", "patient");
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), account);
        var runner = new CosmosScenarioRunner(client, new CosmosRunStore(StorePath, time), RunnerLog.Null, time);
        var parameters = new Dictionary<string, string> { ["stormSeconds"] = "30", ["calmSeconds"] = "30", ["documentKb"] = "1" };

        var result = await runner.RunAsync(Plan("ru-storm", TimeSpan.FromSeconds(150), concurrency: 4, intensity: 8, time, parameters), TestContext.Current.CancellationToken);

        Assert.Equal("Completed", result.Status);
        var writes = account.Requests.Where(r => r.IsUpsert).ToList();
        Assert.NotEmpty(writes);
        foreach (var write in writes)
        {
            // A write starts only in a wave; one that started just before the calm may arrive a moment later.
            var elapsed = write.At - result.StartedAt!.Value;
            var phase = RuStorm.PhaseAt(elapsed, 30, 30);
            Assert.True(phase.Storm || RuStorm.PhaseAt(elapsed - TimeSpan.FromSeconds(2), 30, 30).Storm, $"A storm write at {elapsed.TotalSeconds:0.0} s fell in a calm.");
            Assert.Equal("p-storm-01", write.PartitionKey);
            Assert.Matches("^storm-01-0[0-9]{2}$", FakeCosmosAccount.Body(write)["id"]!.GetValue<string>());
            Assert.Equal(RuStorm.Kind, FakeCosmosAccount.Body(write)["kind"]!.GetValue<string>());
        }

        var waves = writes.Select(w => RuStorm.PhaseAt(w.At - result.StartedAt!.Value, 30, 30).Wave).Distinct().Count();
        Assert.True(waves >= 3, $"Writes fell in {waves} wave(s).");
        Assert.True(account.Throttled > 0);
        var stored = await new CosmosRunStore(StorePath).GetRunAsync(result.RunId, TestContext.Current.CancellationToken);
        Assert.Equal(account.Throttled, stored!.Counters!.Throttled);
        Assert.Equal(writes.Count, stored.Counters.Requests);
        Assert.Contains(result.Checks, c => c.CheckId == "throttled" && c.Status == "Pass");
        Assert.Contains($"{account.Throttled} throttled (429)", result.Outcome, StringComparison.Ordinal);

        // The cleanup left the container as the baseline had it.
        var cleanup = Assert.Single(result.Checks, c => c.CheckId == "auto-cleanup");
        Assert.Equal("Pass", cleanup.Status);
        Assert.DoesNotContain(account.Keys, k => k.Partition.StartsWith("p-storm-", StringComparison.Ordinal));
        Assert.Equal([("p-0007", "patient")], account.Keys);
        Assert.Contains(account.Requests, r => r.Method == "DELETE");
        Assert.All(account.Requests.Where(r => r.Method == "DELETE"), r => Assert.True(r.At >= writes.Max(w => w.At)));
    }

    [Fact]
    public async Task AStopRequestEndsARunWithinAFewSecondsAndItStillCleansUp()
    {
        var time = new AcceleratedTime(10);
        var account = new FakeCosmosAccount(time);
        var store = new CosmosRunStore(StorePath, time);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), account);
        var runner = new CosmosScenarioRunner(client, store, RunnerLog.Null, time);
        var token = TestContext.Current.CancellationToken;

        var run = runner.RunAsync(Plan("ru-storm", TimeSpan.FromSeconds(300), concurrency: 2, intensity: 5, time, new Dictionary<string, string> { ["stormSeconds"] = "60", ["calmSeconds"] = "0" }), token);
        await WaitForAsync(async () => account.Requests.Count(r => r.IsUpsert) >= 5, token);
        var stoppedAt = time.GetUtcNow();
        Assert.Equal(1, await store.StopAsync("scenario", null, "ru-storm", "tester", token));
        var result = await run.WaitAsync(TimeSpan.FromSeconds(20), token);

        Assert.Equal("Cancelled", result.Status);
        Assert.Equal("Pass", result.Result);
        var lastWrite = account.Requests.Where(r => r.IsUpsert).Max(r => r.At);
        Assert.True(lastWrite - stoppedAt < TimeSpan.FromSeconds(10), $"Writes went on {(lastWrite - stoppedAt).TotalSeconds:0.0} s after the stop.");
        Assert.True(result.EndedAt!.Value - stoppedAt < TimeSpan.FromSeconds(30), $"The run ended {(result.EndedAt!.Value - stoppedAt).TotalSeconds:0.0} s after the stop.");
        Assert.Equal("Pass", Assert.Single(result.Checks, c => c.CheckId == "auto-cleanup").Status);
        Assert.Empty(account.Keys);
        Assert.Equal("Cancelled", (await store.GetRunAsync(result.RunId, token))!.Status);
    }

    [Fact]
    public async Task ARoleThatIsntEffectiveYetRefusesTheRunForTheHostToRetry()
    {
        var account = new FakeCosmosAccount { FailWith = System.Net.HttpStatusCode.Forbidden };
        var tokens = new FakeTokens();
        using var writer = new StringWriter();
        using var log = new RunnerLog(writer);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), tokens, account);
        var store = new CosmosRunStore(StorePath);
        var runner = new CosmosScenarioRunner(client, store, log, TimeProvider.System);

        var result = await runner.RunAsync(Plan("healthy-baseline", TimeSpan.FromSeconds(60), 1, 2, TimeProvider.System), TestContext.Current.CancellationToken);

        Assert.Equal("Refused", result.Status);
        Assert.Equal("connect", result.RefusalReason);
        Assert.True(result.CanRetryRefusal);
        Assert.Contains("Cosmos DB Built-in Data Contributor", result.Outcome, StringComparison.Ordinal);
        Assert.DoesNotContain(tokens.Token, result.Outcome, StringComparison.Ordinal);
        Assert.DoesNotContain(tokens.Token, writer.ToString(), StringComparison.Ordinal);
        Assert.Empty((await store.ReadAsync(TestContext.Current.CancellationToken)).Runs!);
    }

    [Fact]
    public async Task AMissingContainerIsARefusalThatPassesOnceASessionCreatesIt()
    {
        // T5's container exists only during a session: a run before a session's start creates it, or after its end deleted
        // it, is refused ("request", as before) with that reason, and the profile host tries it again.
        var account = new FakeCosmosAccount { ContainerMissing = true };
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), account);
        var store = new CosmosRunStore(StorePath);
        var runner = new CosmosScenarioRunner(client, store, RunnerLog.Null, TimeProvider.System);
        var token = TestContext.Current.CancellationToken;

        var missing = await runner.RunAsync(Plan("ru-storm", TimeSpan.FromSeconds(60), 1, 2, TimeProvider.System), token);

        Assert.Equal("Refused", missing.Status);
        Assert.Equal("request", missing.RefusalReason);
        Assert.Equal("T5's container contosocare/patient-events doesn't exist now: it exists only during a session, so ./scripts/start-demo.ps1 or the control notebook's Run all creates it first.", missing.Outcome);
        Assert.True(missing.CanRetryRefusal);
        Assert.Single(account.Requests);
        Assert.Empty((await store.ReadAsync(token)).Runs!);
    }

    [Fact]
    public async Task AnotherTargetIsARefusalThatDoesntPass()
    {
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), new FakeCosmosAccount());
        var runner = new CosmosScenarioRunner(client, new CosmosRunStore(StorePath), RunnerLog.Null, TimeProvider.System);
        var baseline = ScenarioCatalog.Default.Get("healthy-baseline");

        var elsewhere = await runner.RunAsync(RunBounds.Plan(baseline, new RunRequest { ScenarioId = baseline.Id, Target = DemoTarget.T1, Duration = TimeSpan.FromSeconds(60) }, DateTimeOffset.UtcNow), TestContext.Current.CancellationToken);

        Assert.Equal("request", elsewhere.RefusalReason);
        Assert.False(elsewhere.CanRetryRefusal);
    }

    [Fact]
    public async Task TheProfileHostTriesAMissingContainerAgainUntilASessionCreatesIt()
    {
        // A T5 profile set a little before the session's start creates the container: each start is refused, tried again
        // after the host's retry delay (30 seconds; shorter here), never sooner, and the baseline starts once the container
        // exists. The host neither crashes nor gives up.
        Directory.CreateDirectory(folder);
        var account = new FakeCosmosAccount { ContainerMissing = true };
        using var writer = new StringWriter();
        using var log = new RunnerLog(writer);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), account);
        var runner = new CosmosScenarioRunner(client, new CosmosRunStore(StorePath), log, TimeProvider.System);
        var profiles = new FileProfileStore(Path.Combine(folder, "activity-t5.json"));
        var token = TestContext.Current.CancellationToken;
        await profiles.SetAsync("baseline", "tester", DateTimeOffset.UtcNow.AddMinutes(30), null, null, token);
        var options = new ProfileHostOptions { Poll = TimeSpan.FromMilliseconds(50), SupervisorInterval = TimeSpan.FromMilliseconds(50), RefusedRetryDelay = TimeSpan.FromMilliseconds(200), ShutdownWait = TimeSpan.FromSeconds(10) };
        var host = new ProfileHost(ActivityProfilesDefinition.Default, ScenarioCatalog.Default, log, TimeProvider.System, options);
        using var stop = new CancellationTokenSource();
        var hosting = Task.Run(() => host.RunAsync([new ProfileTarget(DemoTarget.T5, runner, profiles)], null, stop.Token), token);

        await WaitForAsync(() => Task.FromResult(ContainerReads(account).Count >= 3), token);
        account.ContainerMissing = false;
        await WaitForAsync(() => Task.FromResult(account.Requests.Any(r => r.Path.StartsWith(FakeCosmosAccount.DocumentsPath, StringComparison.Ordinal) && r.Header("User-Agent")!.StartsWith("ContosoCare.Demo/healthy-baseline/", StringComparison.Ordinal))), token);
        await stop.CancelAsync();
        await hosting.WaitAsync(TimeSpan.FromSeconds(30), token);

        var reads = ContainerReads(account);
        for (var i = 1; i < reads.Count; i++)
        {
            Assert.True(reads[i] - reads[i - 1] >= options.RefusedRetryDelay - TimeSpan.FromMilliseconds(15), $"The container was read again {(reads[i] - reads[i - 1]).TotalMilliseconds:0} ms after a refusal.");
        }

        var text = writer.ToString();
        Assert.Contains(CosmosEndpoint.ContainerMissingMessage, text, StringComparison.Ordinal);
        Assert.Contains("profile.start-retry", text, StringComparison.Ordinal);
        Assert.DoesNotContain("profile.start-gave-up", text, StringComparison.Ordinal);
        Assert.DoesNotContain("profile.lane-crashed", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task WarmupSaysTheContainerExistsOnlyDuringASession()
    {
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), new FakeCosmosAccount { ContainerMissing = true });

        var failure = await Assert.ThrowsAsync<CosmosException>(() => CosmosAccount.WarmupAsync(client, TimeProvider.System, TestContext.Current.CancellationToken));

        Assert.Equal(CosmosFailure.NotFound, failure.Failure);
        Assert.Equal(CosmosEndpoint.ContainerMissingMessage, failure.Message);
    }

    [Fact]
    public async Task SetupsContainerCheckFailsWithTheSessionsFixWhenTheContainerDoesntExistNow()
    {
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), new FakeCosmosAccount { ContainerMissing = true });

        var (check, container) = await CosmosAccount.VerifyContainerAsync(client, "ContosoCare.Demo/control/setup", TimeProvider.System, TestContext.Current.CancellationToken);

        Assert.Equal("Fail", check.Status);
        Assert.Null(container);
        Assert.Contains("contosocare/patient-events now (HTTP 404): it exists only during a session, so ./scripts/start-demo.ps1 (or deploy.ps1) creates it", check.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStormWhoseContainerIsDeletedMidRunHasNoDocumentLeftToCleanUp()
    {
        // A session's end deletes T5's container: a storm still running then fails (its writes get 404 with substatus
        // 1003), and its cleanup has no storm document left to delete, which is a Pass, not a Warning.
        var time = new AcceleratedTime(10);
        var account = new FakeCosmosAccount(time);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), account);
        var runner = new CosmosScenarioRunner(client, new CosmosRunStore(StorePath, time), RunnerLog.Null, time);
        var token = TestContext.Current.CancellationToken;

        var run = runner.RunAsync(Plan("ru-storm", TimeSpan.FromSeconds(300), concurrency: 2, intensity: 5, time, new Dictionary<string, string> { ["stormSeconds"] = "60", ["calmSeconds"] = "0" }), token);
        await WaitForAsync(() => Task.FromResult(account.Requests.Count(r => r.IsUpsert) >= 5), token);
        account.ContainerMissing = true;
        var result = await run.WaitAsync(TimeSpan.FromSeconds(30), token);

        Assert.Equal("Failed", result.Status);
        Assert.Contains("exists only during a session", result.Outcome, StringComparison.Ordinal);
        var cleanup = Assert.Single(result.Checks, c => c.CheckId == "auto-cleanup");
        Assert.Equal("Pass", cleanup.Status);
        Assert.Equal("T5's container doesn't exist now (it exists only during a session), so no storm document is left.", cleanup.Message);
        Assert.EndsWith(" Cleanup: " + StormCleanupResult.ContainerMissingMessage, result.Outcome, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARecoveredStormWhoseContainerIsGoneHasNothingToCleanUp()
    {
        var store = new CosmosRunStore(StorePath);
        var token = TestContext.Current.CancellationToken;
        var dead = new CosmosRunOwner(Environment.MachineName, 1_000_007, DateTimeOffset.UtcNow.AddHours(-1));
        await store.BeginRunAsync(new CosmosRunStart("20261118160000-t5-dead02", "ru-storm", 600, 1800, 8, 7, "{}", "profile:showcase", "showcase") { Owner = dead }, token);
        using var writer = new StringWriter();
        using var log = new RunnerLog(writer);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), new FakeCosmosAccount { ContainerMissing = true });
        var runner = new CosmosScenarioRunner(client, store, log, TimeProvider.System);

        var recovered = await runner.RecoverOrphanedProfileRunsAsync(Environment.MachineName, DateTimeOffset.UtcNow.AddMinutes(1), token);

        Assert.Equal(["20261118160000-t5-dead02"], recovered);
        var cleanup = Assert.Single(writer.ToString().Split(Environment.NewLine), l => l.Contains(" run.cleanup ", StringComparison.Ordinal));
        Assert.Contains("complete=True containerMissing=True", cleanup, StringComparison.Ordinal);
        Assert.Contains("error=\"\"", cleanup, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStormWhoseRunnerDiedMidRunIsCleanedUpWhenTheHostRecoversIt()
    {
        // A VM deallocated mid-storm: the next profile host ends the run its predecessor left Running and deletes its documents.
        var account = new FakeCosmosAccount();
        account.Put("p-storm-01", "storm-01-005", RuStorm.Kind);
        account.Put("p-storm-02", "storm-02-017", RuStorm.Kind);
        account.Put("p-0003", "hb-ev-1");
        var store = new CosmosRunStore(StorePath);
        var token = TestContext.Current.CancellationToken;
        var dead = new CosmosRunOwner(Environment.MachineName, 1_000_005, DateTimeOffset.UtcNow.AddHours(-1));
        await store.BeginRunAsync(new CosmosRunStart("20261118160000-t5-dead01", "ru-storm", 600, 1800, 8, 7, "{}", "profile:showcase", "showcase") { Owner = dead }, token);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), account);
        var runner = new CosmosScenarioRunner(client, store, RunnerLog.Null, TimeProvider.System);

        var recovered = await runner.RecoverOrphanedProfileRunsAsync(Environment.MachineName, DateTimeOffset.UtcNow.AddMinutes(1), token);

        Assert.Equal(["20261118160000-t5-dead01"], recovered);
        Assert.Equal([("p-0003", "hb-ev-1")], account.Keys);
        Assert.Equal("Cancelled", (await store.GetRunAsync("20261118160000-t5-dead01", token))!.Status);
    }

    [Fact]
    public async Task StatusJsonShowsTheAccountAndLiveRatesAndEndsWithTheHost()
    {
        Directory.CreateDirectory(folder);
        var store = new CosmosRunStore(StorePath);
        var token = TestContext.Current.CancellationToken;
        await store.BeginRunAsync(new CosmosRunStart("20261118160000-t5-a1b2c3", "ru-storm", 600, 1800, 8, 7, "{}", "profile:showcase", "showcase"), token);
        await store.UpdateProgressAsync("20261118160000-t5-a1b2c3", new CosmosRunCounters { Requests = 900, Throttled = 120 }, new CosmosLiveRates { RequestsPerSecond = 75.5, RuPerSecond = 401.2, ThrottledPerSecond = 12.25, ThrottledLastMinute = 600, UpdatedAt = DateTimeOffset.UtcNow }, token);
        await store.StopAsync("scenario", null, "healthy-baseline", "tester", token);
        var tokens = new FakeTokens();
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), tokens, new FakeCosmosAccount());

        var status = await CommandLineDefinition.ReadStatusT5Async(client, store, new FileProfileStore(Path.Combine(folder, "activity-t5.json")), 10, Path.Combine(folder, "host-lanes.json"), token);
        var json = CommandLineDefinition.StatusT5Node(status);

        Assert.Equal(["target", "profile", "runs", "stopRequests", "account", "host"], json.Select(p => p.Key));
        Assert.Equal("T5", json["target"]!.GetValue<string>());
        Assert.Equal("off", json["profile"]!["name"]!.GetValue<string>());
        var run = json["runs"]![0]!;
        Assert.Equal(["runId", "scenario", "target", "status", "startedAt", "deadlineAt", "stoppedAt", "maxDurationSeconds", "concurrency", "intensity", "profile", "requestedBy", "outcome"], run.AsObject().Select(p => p.Key));
        Assert.Equal("Running", run["status"]!.GetValue<string>());
        Assert.Equal("showcase", run["profile"]!.GetValue<string>());
        Assert.Equal(["scenario", "requestedAt", "requestedBy", "scope", "runId"], json["stopRequests"]![0]!.AsObject().Select(p => p.Key));
        var account = json["account"]!;
        Assert.Equal(["endpoint", "database", "container", "reachable", "containerExists", "partitionKey", "error", "note", "live"], account.AsObject().Select(p => p.Key));
        Assert.Equal(Host, account["endpoint"]!.GetValue<string>());
        Assert.Equal("contosocare", account["database"]!.GetValue<string>());
        Assert.Equal("patient-events", account["container"]!.GetValue<string>());
        Assert.True(account["reachable"]!.GetValue<bool>());
        Assert.True(account["containerExists"]!.GetValue<bool>());
        Assert.Equal("/patientId", account["partitionKey"]!["paths"]![0]!.GetValue<string>());
        Assert.Equal(2, account["partitionKey"]!["version"]!.GetValue<int>());
        Assert.Null(account["error"]);
        Assert.Null(account["note"]);
        Assert.Equal(75.5, account["live"]!["requestsPerSecond"]!.GetValue<double>());
        Assert.Equal(401.2, account["live"]!["ruPerSecond"]!.GetValue<double>());
        Assert.Equal(12.25, account["live"]!["throttledPerSecond"]!.GetValue<double>());
        Assert.Equal(600, account["live"]!["throttledLastMinute"]!.GetValue<long>());
        Assert.NotNull(account["live"]!["updatedAt"]);
        Assert.Equal("Warning", json["host"]!["status"]!.GetValue<string>());
        Assert.DoesNotContain(tokens.Token, json.ToJsonString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task StatusJsonSaysWhyTheAccountDoesntAnswer()
    {
        Directory.CreateDirectory(folder);
        var tokens = new FakeTokens();
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), tokens, new FakeCosmosAccount { FailWith = System.Net.HttpStatusCode.Forbidden });

        var json = CommandLineDefinition.StatusT5Node(await CommandLineDefinition.ReadStatusT5Async(client, new CosmosRunStore(StorePath), new FileProfileStore(Path.Combine(folder, "activity-t5.json")), 10, Path.Combine(folder, "host-lanes.json"), TestContext.Current.CancellationToken));

        var account = json["account"]!;
        Assert.False(account["reachable"]!.GetValue<bool>());
        Assert.Null(account["containerExists"]);
        Assert.Null(account["partitionKey"]);
        Assert.Contains("Cosmos DB Built-in Data Contributor", account["error"]!.GetValue<string>(), StringComparison.Ordinal);
        Assert.Null(account["note"]);
        Assert.Equal(0, account["live"]!["requestsPerSecond"]!.GetValue<double>());
        Assert.Null(account["live"]!["updatedAt"]);
        Assert.Equal("host", json.Last().Key);
        Assert.DoesNotContain(tokens.Token, json.ToJsonString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task StatusSaysT5sContainerDoesntExistNowWithoutAnError()
    {
        // Between sessions T5's container doesn't exist: the account answers, and status says so, which isn't an error.
        Directory.CreateDirectory(folder);
        using var client = new CosmosRestClient(CosmosEndpoint.Create(Host, null), new FakeTokens(), new FakeCosmosAccount { ContainerMissing = true });

        var status = await CommandLineDefinition.ReadStatusT5Async(client, new CosmosRunStore(StorePath), new FileProfileStore(Path.Combine(folder, "activity-t5.json")), 10, Path.Combine(folder, "host-lanes.json"), TestContext.Current.CancellationToken);
        var account = CommandLineDefinition.StatusT5Node(status)["account"]!;
        using var text = new StringWriter();
        CommandLineDefinition.WriteStatusT5Text(text, status);

        Assert.True(account["reachable"]!.GetValue<bool>());
        Assert.False(account["containerExists"]!.GetValue<bool>());
        Assert.Null(account["partitionKey"]);
        Assert.Null(account["error"]);
        Assert.Equal("T5's container doesn't exist now: it exists only during a session (./scripts/start-demo.ps1 or the control notebook's Run all creates it).", account["note"]!.GetValue<string>());
        Assert.Contains($"Account:  {Host} answers; T5's container doesn't exist now: it exists only during a session", text.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("run", "--target", "T5", "--scenario", "healthy-baseline")]
    [InlineData("status", "--target", "T5")]
    [InlineData("warmup", "--target", "T5")]
    [InlineData("setup", "--target", "T5")]
    [InlineData("reset", "--target", "T5")]
    public void T5NeedsTheAccountsHostName(params string[] args)
    {
        var (exitCode, _, error) = CliHarness.Invoke(args);

        Assert.Equal(1, exitCode);
        Assert.Contains("T5 needs --server", error, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("--server", "https://cosmos01-abc123.documents.azure.com:443/", "--server must be the Cosmos DB account's host name")]
    [InlineData("--user", "contosocare_runner", "--user and --pg-password-from-environment are for T4")]
    [InlineData("--pg-password-from-environment", null, "--user and --pg-password-from-environment are for T4")]
    [InlineData("--sql-login-from-environment", null, "T5 is Microsoft Entra only")]
    [InlineData("--replica-server", "pgreplica01-abc123", "--replica-server is for T4")]
    [InlineData("--managed-identity-client-id", "not-a-guid", "a GUID")]
    public void T5RefusesTheOtherTargetsOptions(string option, string? value, string message)
    {
        string[] args = ["status", "--target", "T5", "--run-file", StorePath, .. option == "--server" ? Array.Empty<string>() : ["--server", Host], option, .. value is null ? Array.Empty<string>() : [value]];

        var (exitCode, _, error) = CliHarness.Invoke(args);

        Assert.Equal(1, exitCode);
        Assert.Contains(message, error, StringComparison.Ordinal);
        Assert.False(File.Exists(StorePath));
    }

    [Theory]
    [InlineData("run", "--target", "T5", "--server", Host, "--scenario", "cpu-pressure")]
    [InlineData("setup", "--target", "T5", "--server", Host, "--include-base-schema")]
    [InlineData("setup", "--target", "T5", "--server", Host, "--grant-windows-login", "NT SERVICE\\ContosoCareWorkload")]
    [InlineData("setup", "--target", "T5", "--server", Host, "--runner-role", "contosocare_runner")]
    [InlineData("setup", "--target", "T5", "--server", Host, "--seed-scale", "51")]
    [InlineData("stop", "--target", "T5", "--scenario", "cpu-pressure")]
    [InlineData("status", "--target", "T1", "--run-file", "t5-runs.json")]
    [InlineData("profile", "set", "--target", "T5", "--name", "incident:cpu-pressure")]
    public void T5RefusesWhatDoesntApplyBeforeItSendsAnything(params string[] args)
    {
        var (exitCode, _, error) = CliHarness.Invoke(args);

        Assert.Equal(1, exitCode);
        Assert.NotEmpty(error);
    }

    [Theory]
    [InlineData("--target", "T2", "--t5-server", Host)]
    [InlineData("--target", "T3", "--server", "sql-x", "--t5-server", Host)]
    [InlineData("--target", "T1", "--t5-profile-file", "activity-t5.json")]
    [InlineData("--target", "T1", "--t5-run-file", "t5-runs.json")]
    [InlineData("--target", "T1", "--t5-managed-identity-client-id", "00000000-0000-0000-0000-000000000001")]
    [InlineData("--target", "T1", "--t5-server", "cosmos01")]
    [InlineData("--target", "T5", "--server", Host, "--t3-server", "sql-x")]
    [InlineData("--target", "T5", "--server", Host, "--t4-server", "pgflex01-abc123")]
    public void TheProfileHostTakesT5OnlyBesideAT1Primary(params string[] options)
    {
        var (exitCode, _, error) = CliHarness.Invoke(["profile", "run", "--host-state-file", Path.Combine(folder, "host-lanes.json"), .. options]);

        Assert.Equal(1, exitCode);
        Assert.NotEmpty(error);
        Assert.False(File.Exists(Path.Combine(folder, "host-lanes.json")), "The host must not start.");
    }

    [Fact]
    public void TheProfileHostHasT5sOptions()
    {
        Assert.Empty(CliHarness.ParseErrors("profile", "run", "--target", "T1", "--t5-server", Host, "--t5-managed-identity-client-id", "00000000-0000-0000-0000-000000000001", "--t5-profile-file", "a.json", "--t5-run-file", "b.json"));
        Assert.Empty(CliHarness.ParseErrors("run", "--target", "T5", "--server", Host, "--scenario", "ru-storm", "--run-file", "b.json"));
    }

    [Fact]
    public async Task StopAllSetsT5sProfileOffAndStopsItsRunsWithoutTheAccount()
    {
        var profileFile = Path.Combine(folder, "activity-t5.json");
        var token = TestContext.Current.CancellationToken;
        var store = new CosmosRunStore(StorePath);
        await store.BeginRunAsync(new CosmosRunStart("20261118160000-t5-a1b2c3", "ru-storm", 600, 1800, 8, 7, "{}", "tester", null), token);
        Assert.Equal(0, CliHarness.Invoke("profile", "set", "--target", "T5", "--name", "showcase", "--profile-file", profileFile).ExitCode);

        var (exitCode, output, error) = CliHarness.Invoke("stop", "--target", "T5", "--all", "--run-file", StorePath, "--profile-file", profileFile, "--json");

        Assert.True(exitCode == 0, error);
        var record = JsonNode.Parse(output)![0]!;
        Assert.Equal("WORKLOAD.T5.STOP.STOP", record["checkId"]!.GetValue<string>());
        Assert.Contains("1 Running run(s) marked Cancelled", record["message"]!.GetValue<string>(), StringComparison.Ordinal);
        Assert.Equal("https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units", record["docUrl"]!.GetValue<string>());
        Assert.Equal("off", JsonNode.Parse(File.ReadAllText(profileFile))!["profile"]!.GetValue<string>());
        Assert.Equal("Cancelled", (await store.GetRunAsync("20261118160000-t5-a1b2c3", token))!.Status);
        var get = CliHarness.Invoke("profile", "get", "--target", "T5", "--profile-file", profileFile, "--host-state-file", Path.Combine(folder, "host-lanes.json"), "--json");
        Assert.Equal("T5", JsonNode.Parse(get.Output)!["target"]!.GetValue<string>());
    }

    [Fact]
    public void AStampedStopOnT5ThatsOlderThanTheStoredRequestChangesNothing()
    {
        var profileFile = Path.Combine(folder, "activity-t5.json");
        Assert.Equal(0, CliHarness.Invoke("profile", "set", "--target", "T5", "--name", "showcase", "--profile-file", profileFile, "--if-newer", "2026-11-18T16:00:05Z", "--request-id", "job-2").ExitCode);

        var (exitCode, output, _) = CliHarness.Invoke("stop", "--target", "T5", "--all", "--run-file", StorePath, "--profile-file", profileFile, "--if-newer", "2026-11-18T16:00:00Z", "--request-id", "job-1");

        Assert.Equal(0, exitCode);
        Assert.Contains("Not applied", output, StringComparison.Ordinal);
        Assert.Equal("showcase", JsonNode.Parse(File.ReadAllText(profileFile))!["profile"]!.GetValue<string>());
        Assert.False(File.Exists(StorePath));
    }

    [Theory]
    [InlineData("warmup", "warmup", "Pass", "https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access")]
    [InlineData("setup", "container", "Fail", "https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access")]
    [InlineData("reset", "no-running-runs", "Pass", "https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units")]
    [InlineData("status", "account", "Pass", "https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units")]
    [InlineData("reset", "storm-throttled", "Warning", "https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-request-rate-too-large")]
    public void T5ResultRecordsMatchTheValidationSchema(string command, string checkId, string status, string docUrl)
    {
        var record = CommandLineDefinition.ResultRecord(DemoTarget.T5, command, new CheckRecord(checkId, status, "A T5 check."), "2026-11-18T16:00:00.000Z");
        using var document = JsonDocument.Parse(record.ToJsonString());

        Assert.True(CommandLineTests.ValidationResultSchema.Value.Evaluate(document.RootElement).IsValid);
        Assert.Equal(("WORKLOAD.T5." + command + "." + checkId).ToUpperInvariant().Replace('-', '_'), record["checkId"]!.GetValue<string>());
        Assert.Equal(docUrl, record["docUrl"]!.GetValue<string>());
        Assert.Equal(status == "Pass", record["remediation"]!.GetValue<string>().Length == 0);
    }

    [Fact]
    public void AThrottledWarmupPointsAtTheRequestRateTooLargeGuide()
    {
        var record = CommandLineDefinition.ResultRecord(DemoTarget.T5, "warmup", new CheckRecord("warmup", "Warning", "T5 answered and access works, but it throttled the warmup document's writes (HTTP 429, request rate too large) for 20 s."), "2026-11-18T16:00:00.000Z");

        Assert.Equal("https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-request-rate-too-large", record["docUrl"]!.GetValue<string>());
        Assert.Contains("ru-storm", record["remediation"]!.GetValue<string>(), StringComparison.Ordinal);
    }

    private static RunPlan Plan(string scenarioId, TimeSpan duration, int concurrency, int intensity, TimeProvider time, Dictionary<string, string>? parameters = null)
    {
        var scenario = ScenarioCatalog.Default.Get(scenarioId);
        return RunBounds.Plan(
            scenario,
            new RunRequest { ScenarioId = scenarioId, Target = DemoTarget.T5, Duration = duration, Concurrency = concurrency, Intensity = intensity, Parameters = parameters ?? [], RequestedBy = "tester" },
            time.GetUtcNow());
    }

    /// <summary>When each read of the container's definition arrived.</summary>
    private static List<DateTimeOffset> ContainerReads(FakeCosmosAccount account) =>
        [.. account.Requests.Where(r => r.Method == "GET" && r.Path == FakeCosmosAccount.ContainerPath).Select(r => r.At)];

    private static async Task WaitForAsync(Func<Task<bool>> condition, CancellationToken cancellationToken)
    {
        var until = DateTimeOffset.UtcNow.AddSeconds(20);
        while (!await condition())
        {
            Assert.True(DateTimeOffset.UtcNow < until, "The condition didn't become true in 20 seconds.");
            await Task.Delay(10, cancellationToken);
        }
    }
}
