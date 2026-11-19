using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Cosmos;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// T5's run store (T5 has no control tables): demo.usp_run_begin's refusals, stop, the end of a run, the recovery of runs
/// whose runner ended without recording them, concurrent writers under the lock; and reset, which also deletes the storm
/// documents a run left behind. Nothing here needs a Cosmos DB account.
/// </summary>
public sealed class CosmosRunStoreTests : IDisposable
{
    private readonly string folder = Path.Combine(AppContext.BaseDirectory, "cosmos-store-" + Guid.NewGuid().ToString("N"));

    private string StorePath => Path.Combine(folder, CosmosRunStore.FileName);

    public void Dispose()
    {
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public async Task ARunIsRefusedWhileItsScenarioRunsAndWhenFourRunsAreRunning()
    {
        var store = new CosmosRunStore(StorePath);
        var token = TestContext.Current.CancellationToken;

        var registration = await store.BeginRunAsync(Start("r1", "ru-storm"), token);
        var running = await Assert.ThrowsAsync<CosmosRunRefusedException>(() => store.BeginRunAsync(Start("r2", "ru-storm"), token));
        await store.BeginRunAsync(Start("r3", "s3"), token);
        await store.BeginRunAsync(Start("r4", "s4"), token);
        await store.BeginRunAsync(Start("r5", "s5"), token);
        var limit = await Assert.ThrowsAsync<CosmosRunRefusedException>(() => store.BeginRunAsync(Start("r6", "s6"), token));

        Assert.Equal(300, registration.EffectiveDurationSeconds);
        Assert.Equal("running-run", running.Reason);
        Assert.Contains("already has a Running run on T5", running.Message, StringComparison.Ordinal);
        Assert.Equal("run-limit", limit.Reason);
        Assert.StartsWith("Four runs are already Running on T5", limit.Message, StringComparison.Ordinal);
        var run = await store.GetRunAsync("r1", token);
        Assert.Equal("Running", run!.Status);
        Assert.Equal("T5", run.Target);
        Assert.Equal(Environment.MachineName, run.Machine);
        Assert.Equal(Environment.ProcessId, run.ProcessId);
    }

    [Fact]
    public async Task TheDurationIsClampedToTheScenariosMaximumAndTheGlobalCap()
    {
        var store = new CosmosRunStore(StorePath);

        var registration = await store.BeginRunAsync(Start("r1", "ru-storm", durationSeconds: 99_999, maxSeconds: 1800), TestContext.Current.CancellationToken);

        Assert.Equal(1800, registration.EffectiveDurationSeconds);
    }

    [Fact]
    public async Task AStopMarksRunningRunsCancelledAndAnEndKeepsIt()
    {
        var store = new CosmosRunStore(StorePath);
        var token = TestContext.Current.CancellationToken;
        await store.BeginRunAsync(Start("r1", "ru-storm"), token);
        await store.BeginRunAsync(Start("r2", "healthy-baseline"), token);

        Assert.Equal(1, await store.StopAsync("scenario", null, "ru-storm", "tester", token));
        Assert.Equal(0, await store.StopAsync("run", "r1", null, "tester", token));
        await store.EndRunAsync("r1", CosmosRunStatus.Completed, "12 request(s).", new CosmosRunCounters { Requests = 12, Throttled = 3, RequestCharge = 40.5 }, token);
        Assert.Equal(1, await store.StopAsync("all", null, null, "tester", token));

        var document = await store.ReadAsync(token);
        var stopped = document.Runs!.Single(r => r.RunId == "r1");
        Assert.Equal("Cancelled", stopped.Status);
        Assert.NotNull(stopped.EndedAt);
        Assert.Contains("Stop requested by tester", stopped.Outcome, StringComparison.Ordinal);
        Assert.EndsWith("12 request(s).", stopped.Outcome, StringComparison.Ordinal);
        Assert.Equal(3, stopped.Counters!.Throttled);
        Assert.Null(stopped.Live);
        Assert.Equal("Cancelled", document.Runs!.Single(r => r.RunId == "r2").Status);
        Assert.Equal(["all", "run", "scenario"], document.StopRequests!.Select(s => s.Scope));
        Assert.Equal("*", document.StopRequests![0].Scenario);
        Assert.Equal("ru-storm", document.StopRequests![1].Scenario);
        Assert.Equal("r1", document.StopRequests![1].RunId);
    }

    [Fact]
    public async Task ARunPastItsDeadlineAndGraceIsTimedOutBeforeTheNextRegisters()
    {
        var time = new ManualClock(new DateTimeOffset(2026, 11, 18, 16, 0, 0, TimeSpan.Zero));
        var store = new CosmosRunStore(StorePath, time);
        var token = TestContext.Current.CancellationToken;
        await store.BeginRunAsync(Start("r1", "ru-storm", durationSeconds: 60), token);

        time.Advance(TimeSpan.FromSeconds(60) + RunLimits.Grace - TimeSpan.FromSeconds(1));
        await Assert.ThrowsAsync<CosmosRunRefusedException>(() => store.BeginRunAsync(Start("r2", "ru-storm"), token));
        time.Advance(TimeSpan.FromSeconds(2));
        await store.BeginRunAsync(Start("r3", "ru-storm"), token);

        var stale = await store.GetRunAsync("r1", token);
        Assert.Equal("TimedOut", stale!.Status);
        Assert.Contains("its runner ended without recording it", stale.Outcome, StringComparison.Ordinal);
        Assert.Equal("Running", (await store.GetRunAsync("r3", token))!.Status);
    }

    [Fact]
    public async Task ConcurrentWritersNeverLoseAChangeUnderTheLock()
    {
        var token = TestContext.Current.CancellationToken;
        var starts = Enumerable.Range(1, 12).Select(i => Task.Run(() => TryBeginAsync(new CosmosRunStore(StorePath), Start($"r{i}", $"s{i}"), token), token)).ToList();
        var registered = (await Task.WhenAll(starts)).Count(ok => ok);
        var progress = Enumerable.Range(1, 12).Select(i => Task.Run(() => new CosmosRunStore(StorePath).UpdateProgressAsync($"r{i}", new CosmosRunCounters { Requests = i }, new CosmosLiveRates { RequestsPerSecond = i, UpdatedAt = DateTimeOffset.UtcNow }, token), token));
        await Task.WhenAll(progress);

        var document = await new CosmosRunStore(StorePath).ReadAsync(token);
        Assert.Equal(CosmosRunStore.MaximumRunning, registered);
        Assert.Equal(CosmosRunStore.MaximumRunning, document.Runs!.Count);
        Assert.All(document.Runs!, r => Assert.Equal(int.Parse(r.RunId[1..], System.Globalization.CultureInfo.InvariantCulture), r.Counters!.Requests));
        Assert.False(File.Exists(StorePath + ".tmp"));
    }

    [Fact]
    public async Task TheStoreKeepsTheFiftyMostRecentRunsAndTenStopRequests()
    {
        var time = new ManualClock(new DateTimeOffset(2026, 11, 18, 16, 0, 0, TimeSpan.Zero));
        var store = new CosmosRunStore(StorePath, time);
        var token = TestContext.Current.CancellationToken;
        for (var i = 1; i <= 55; i++)
        {
            await store.BeginRunAsync(Start($"r{i}", "ru-storm"), token);
            await store.EndRunAsync($"r{i}", CosmosRunStatus.Completed, null, new CosmosRunCounters(), token);
            await store.StopAsync("scenario", null, "ru-storm", "tester", token);
            time.Advance(TimeSpan.FromSeconds(1));
        }

        var document = await store.ReadAsync(token);
        Assert.Equal(CosmosRunStore.MaximumRuns, document.Runs!.Count);
        Assert.Equal("r55", document.Runs![0].RunId);
        Assert.Equal("r6", document.Runs![^1].RunId);
        Assert.Equal(CosmosRunStore.MaximumStopRequests, document.StopRequests!.Count);
    }

    [Fact]
    public async Task OrphanedProfileRunsAreRecoveredOnlyWhenTheirProcessIsGone()
    {
        var store = new CosmosRunStore(StorePath);
        var token = TestContext.Current.CancellationToken;
        var gone = new CosmosRunOwner(Environment.MachineName, 1_000_001, DateTimeOffset.UtcNow.AddHours(-1));
        await store.BeginRunAsync(Start("r1", "ru-storm", requestedBy: "profile:showcase") with { Owner = gone }, token);
        await store.BeginRunAsync(Start("r2", "healthy-baseline", requestedBy: "profile:showcase"), token);
        await store.BeginRunAsync(Start("r3", "s3", requestedBy: "tester") with { Owner = gone }, token);

        var recovered = await store.RecoverOrphanedProfileRunsAsync(Environment.MachineName, DateTimeOffset.UtcNow.AddMinutes(1), (processId, _) => processId != gone.ProcessId, token);

        Assert.Equal(["r1"], recovered.Select(r => r.RunId));
        Assert.Equal("Cancelled", (await store.GetRunAsync("r1", token))!.Status);
        Assert.Equal("Running", (await store.GetRunAsync("r2", token))!.Status);
        Assert.Equal("Running", (await store.GetRunAsync("r3", token))!.Status);
    }

    [Fact]
    public async Task ResetStopsTheRunsAndDeletesLeftoverStormDocumentsAndIsIdempotent()
    {
        var store = new CosmosRunStore(StorePath);
        var account = new FakeCosmosAccount();
        for (var n = 0; n < 30; n++)
        {
            account.Put("p-storm-01", $"storm-01-{n:000}", RuStorm.Kind);
        }

        account.Put("p-storm-03", "storm-03-000", RuStorm.Kind);
        account.Put("p-0001", "patient");
        account.Put("p-0001", "hb-ev-3");
        var token = TestContext.Current.CancellationToken;
        var dead = new CosmosRunOwner(Environment.MachineName, 1_000_003, DateTimeOffset.UtcNow.AddHours(-2));
        await store.BeginRunAsync(Start("r1", "ru-storm") with { Owner = dead }, token);
        using var client = new CosmosRestClient(CosmosEndpoint.Create("cosmos01-abc123.documents.azure.com", null), new FakeTokens(), account);
        var options = new ResetOptions("tester", 5, KillSessions: true, KeepProfile: false, UndoRemediation: true, Reseed: false);

        var first = await CosmosReset.RunAsync(store, client, options, TimeProvider.System, token);
        var second = await CosmosReset.RunAsync(store, client, options, TimeProvider.System, token);

        Assert.Equal("Pass", first.Single(c => c.CheckId == "runs-stopped").Status);
        var noRunning = first.Single(c => c.CheckId == "no-running-runs");
        Assert.Equal("Pass", noRunning.Status);
        Assert.Contains("closed 1 run record", noRunning.Message, StringComparison.Ordinal);
        var removed = first.Single(c => c.CheckId == "storm-documents-removed");
        Assert.Equal("Pass", removed.Status);
        Assert.Contains("Deleted 31 ru-storm document(s)", removed.Message, StringComparison.Ordinal);
        Assert.Equal("Not supported", first.Single(c => c.CheckId == "remediation-undone").Status);
        Assert.Equal("Not selected", first.Single(c => c.CheckId == "reseeded").Status);
        Assert.Equal([("p-0001", "hb-ev-3"), ("p-0001", "patient")], account.Keys.Order());
        Assert.Equal("Pass", second.Single(c => c.CheckId == "storm-documents-removed").Status);
        Assert.Contains("No ru-storm document is left", second.Single(c => c.CheckId == "storm-documents-removed").Message, StringComparison.Ordinal);
        Assert.Equal("Cancelled", (await store.GetRunAsync("r1", token))!.Status);
    }

    [Fact]
    public async Task ResetReportsAnAccountItCantReachWithoutFailingTheRest()
    {
        var store = new CosmosRunStore(StorePath);
        var tokens = new FakeTokens();
        var account = new FakeCosmosAccount { FailWith = System.Net.HttpStatusCode.Forbidden };
        using var client = new CosmosRestClient(CosmosEndpoint.Create("cosmos01-abc123.documents.azure.com", null), tokens, account);

        var checks = await CosmosReset.RunAsync(store, client, new ResetOptions("tester", 0, true, false, false, false), TimeProvider.System, TestContext.Current.CancellationToken);

        var removed = checks.Single(c => c.CheckId == "storm-documents-removed");
        Assert.Equal("Warning", removed.Status);
        Assert.Contains("Cosmos DB Built-in Data Contributor", removed.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(tokens.Token, removed.Message, StringComparison.Ordinal);
        Assert.Equal("Pass", checks.Single(c => c.CheckId == "no-running-runs").Status);
    }

    [Fact]
    public async Task ResetHasNoStormDocumentToDeleteWhenT5sContainerDoesntExistNow()
    {
        // Between sessions T5's container doesn't exist (it exists only during a session): nothing is left to clean, a Pass.
        var store = new CosmosRunStore(StorePath);
        var account = new FakeCosmosAccount { ContainerMissing = true };
        using var client = new CosmosRestClient(CosmosEndpoint.Create("cosmos01-abc123.documents.azure.com", null), new FakeTokens(), account);
        var token = TestContext.Current.CancellationToken;

        var checks = await CosmosReset.RunAsync(store, client, new ResetOptions("tester", 0, true, false, false, false), TimeProvider.System, token);
        var cleanup = await StormCleanup.RunAsync(client, "ContosoCare.Demo/control/test", TimeProvider.System, TimeSpan.FromSeconds(30), token);

        var removed = checks.Single(c => c.CheckId == "storm-documents-removed");
        Assert.Equal("Pass", removed.Status);
        Assert.Equal("T5's container doesn't exist now (it exists only during a session), so no storm document is left.", removed.Message);
        Assert.Equal("Pass", checks.Single(c => c.CheckId == "no-running-runs").Status);
        Assert.True(cleanup.Complete);
        Assert.Equal(0, cleanup.Deleted);
        Assert.True(cleanup.ContainerMissing);
        Assert.Null(cleanup.Error);
        Assert.Equal(2, account.Requests.Count);
    }

    [Fact]
    public void TheRunStoreAndProfileFileSitNextToTheOthers()
    {
        Assert.EndsWith("activity-t5.json", FileProfileStore.DefaultPathFor(DemoTarget.T5), StringComparison.Ordinal);
        Assert.EndsWith("t5-runs.json", CosmosRunStore.DefaultPath, StringComparison.Ordinal);
        Assert.Equal(Path.GetDirectoryName(FileProfileStore.DefaultPath), Path.GetDirectoryName(CosmosRunStore.DefaultPath));
        Assert.Equal(Path.GetDirectoryName(FileProfileStore.DefaultPath), Path.GetDirectoryName(FileProfileStore.DefaultPathFor(DemoTarget.T5)));
    }

    private static CosmosRunStart Start(string runId, string scenarioId, int durationSeconds = 300, int maxSeconds = 14400, string requestedBy = "tester") =>
        new(runId, scenarioId, durationSeconds, maxSeconds, 2, 5, "{}", requestedBy, requestedBy.StartsWith("profile:", StringComparison.Ordinal) ? requestedBy[8..] : null);

    private static async Task<bool> TryBeginAsync(CosmosRunStore store, CosmosRunStart start, CancellationToken cancellationToken)
    {
        try
        {
            await store.BeginRunAsync(start, cancellationToken);
            return true;
        }
        catch (CosmosRunRefusedException)
        {
            return false;
        }
    }

    /// <summary>A clock that moves only when told to.</summary>
    private sealed class ManualClock(DateTimeOffset start) : TimeProvider
    {
        private long ticks;

        public void Advance(TimeSpan by) => Interlocked.Add(ref ticks, by.Ticks);

        public override DateTimeOffset GetUtcNow() => start + TimeSpan.FromTicks(Interlocked.Read(ref ticks));
    }
}
