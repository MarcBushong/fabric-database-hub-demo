using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Runs;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>Runner helpers that don't need SQL Server: outcome summaries, the free-space check, and the T3 profile file.</summary>
public sealed class RunnerTests
{
    [Fact]
    public void OutcomesAreSummarizedPerRole()
    {
        WorkerOutcome[] outcomes =
        [
            new("contender", 1, 61, new Dictionary<string, object?> { ["worker"] = 1, ["attempts"] = 10, ["longest_wait_ms"] = 900, ["stop_requested"] = false }, null, false),
            new("contender", 2, 62, new Dictionary<string, object?> { ["worker"] = 2, ["attempts"] = 12, ["longest_wait_ms"] = 1500, ["stop_requested"] = false }, null, false),
            new("holder", 1, 60, new Dictionary<string, object?> { ["hold_cycles"] = 3, ["locked_rows"] = 10, ["mode"] = "idle-transaction" }, null, true),
        ];

        var summary = ScenarioRunner.Summarize(outcomes);

        Assert.Equal("contender x2: attempts=22, longest_wait_ms=1500; holder x1 (1 stopped by the runner): hold_cycles=3, locked_rows=10.", summary);
        Assert.Equal("contender=61,62;holder=60", ScenarioRunner.DescribeSessions(outcomes));
    }

    [Fact]
    public void AnEmptyRunSaysSo()
    {
        Assert.Equal("No sessions ran.", ScenarioRunner.Summarize([]));
    }

    [Fact]
    public void SessionsStillEndingAreCountedNotLost()
    {
        // Phase 25a: runs the host stopped, whose sessions the watchdog stopped waiting for, recorded "No sessions ran."
        WorkerOutcome[] outcomes =
        [
            new("worker", 1, 71, new Dictionary<string, object?> { ["iterations"] = 5 }, null, false),
            new("worker", 2, 72, new Dictionary<string, object?>(), null, true) { Unfinished = true },
            new("worker", 3, 73, new Dictionary<string, object?>(), null, true),
        ];

        Assert.Equal("worker x3 (1 stopped by the runner, 1 still ending): iterations=5.", ScenarioRunner.Summarize(outcomes));
        Assert.Equal("worker=71,72,73", ScenarioRunner.DescribeSessions(outcomes));
    }

    [Fact]
    public async Task TheTrackerKnowsEverySessionThatRan()
    {
        var tracker = new WorkerTracker();
        var ended = new WorkerOutcome("worker", 1, 61, new Dictionary<string, object?> { ["iterations"] = 3 }, null, false);
        var stillRunning = new TaskCompletionSource<WorkerOutcome>();
        _ = tracker.Track("worker", 1, Task.FromResult(ended));
        tracker.NoteSession("worker", 2, 62);
        _ = tracker.Track("worker", 2, stillRunning.Task);
        tracker.NoteSession("holder", 1, 60);
        var failed = tracker.Track("holder", 1, Task.FromException<WorkerOutcome>(new InvalidCastException("odd column")));
        await Assert.ThrowsAsync<InvalidCastException>(() => failed);
        _ = tracker.Track("worker", 3, stillRunning.Task);

        var outcomes = tracker.Collect();

        Assert.Equal(4, outcomes.Count);
        Assert.Same(ended, outcomes[0]);
        Assert.True(outcomes[1].Unfinished);
        Assert.Equal(62, outcomes[1].SessionId);
        Assert.Equal("InvalidCastException: odd column", outcomes[2].Error);
        Assert.Equal(60, outcomes[2].SessionId);
        Assert.Null(outcomes[3].SessionId);
        Assert.Equal("worker x3 (2 still ending): iterations=3; holder x1: no counters.", ScenarioRunner.Summarize(outcomes));
    }

    [Theory]
    [InlineData("Refused", "running-run", true)]
    [InlineData("Refused", "run-limit", true)]
    [InlineData("Refused", "connect", true)]
    [InlineData("Refused", "sql", false)]
    [InlineData("Refused", "request", false)]
    [InlineData("Failed", "running-run", false)]
    public void OnlyARefusalThatPassesByItselfIsRetried(string status, string reason, bool retried)
    {
        var result = new RunResult { RunId = "r", ScenarioId = "healthy-baseline", Target = DemoTarget.T1, Status = status, Result = "Fail", Outcome = "x", RefusalReason = reason };

        Assert.Equal(retried, result.CanRetryRefusal);
    }

    [Fact]
    public void FreeSpaceCountsTheScratchSizeAndTheMargin()
    {
        var scenario = ScenarioCatalog.Default.Get("io-pressure");
        var parameters = ScenarioCatalog.ResolveParameters(scenario, DemoTarget.T2, new Dictionary<string, string> { ["scratchMb"] = "2048" });
        var root = Path.GetPathRoot(AppContext.BaseDirectory)!;
        var files = new[] { Path.Combine(root, "data", "ContosoCare.mdf"), Path.Combine(root, "log", "ContosoCare_log.ldf") };

        var check = FreeSpace.Check(scenario, parameters, scenario.FreeSpace!, files, _ => 5000L * 1024 * 1024);
        var error = Assert.Throws<ScenarioRequestException>(() => FreeSpace.Check(scenario, parameters, scenario.FreeSpace!, files, _ => 4000L * 1024 * 1024));

        Assert.Equal("Pass", check.Status);
        Assert.Contains("4096 MB", check.Message, StringComparison.Ordinal);
        Assert.Contains("needs 4096 MB", error.Message, StringComparison.Ordinal);
        Assert.Contains("VHDX", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void FreeSpaceSkipsVolumesItCannotRead()
    {
        var scenario = ScenarioCatalog.Default.Get("log-rate-pressure");
        var parameters = ScenarioCatalog.ResolveParameters(scenario, DemoTarget.T1, new Dictionary<string, string>());

        var check = FreeSpace.Check(scenario, parameters, scenario.FreeSpace!, ["F:\\SQLLog\\ContosoCare_log.ldf"], _ => null);

        Assert.Equal("Pass", check.Status);
    }

    [Fact]
    public async Task TheT3ProfileFileRoundTripsWithoutAnyDatabase()
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "profile-store-" + Guid.NewGuid().ToString("N"));
        var store = new FileProfileStore(Path.Combine(folder, "activity.json"));
        try
        {
            var missing = await store.GetAsync(TestContext.Current.CancellationToken);
            Assert.Equal("off", missing.Name);

            var expires = new DateTimeOffset(2026, 10, 21, 2, 0, 0, TimeSpan.Zero);
            var parameters = new ProfileParameters { DurationSeconds = 300, Parameters = new Dictionary<string, string> { ["maxLogMb"] = "512" } };
            await store.SetAsync("incident:log-rate-pressure", "tester", expires, parameters, TestContext.Current.CancellationToken);
            var state = await store.GetAsync(TestContext.Current.CancellationToken);

            Assert.Equal("incident:log-rate-pressure", state.Name);
            Assert.Equal("tester", state.SetBy);
            Assert.Equal(expires, state.ExpiresAt);
            Assert.Equal("512", state.Parameters!.Parameters!["maxLogMb"]);
            Assert.False(File.Exists(store.FilePath + ".tmp"));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void ProfileParametersRoundTripAsCompactJson()
    {
        var parameters = new ProfileParameters { Concurrency = 3, ResetBefore = true, Parameters = new Dictionary<string, string> { ["variant"] = "healthy" } };

        var json = ProfileParametersJson.Serialize(parameters);
        var parsed = ProfileParametersJson.Parse(json);

        Assert.DoesNotContain("\n", json, StringComparison.Ordinal);
        Assert.DoesNotContain("intensity", json, StringComparison.Ordinal);
        Assert.Equal(3, parsed!.Concurrency);
        Assert.True(parsed.ResetBefore);
        Assert.Equal("healthy", parsed.Parameters!["variant"]);
        Assert.Null(ProfileParametersJson.Parse("not json"));
    }

    [Fact]
    public void TheDefaultT3ProfileFileIsUnderProgramData()
    {
        if (OperatingSystem.IsWindows())
        {
            Assert.EndsWith(@"DbHubDemo\activity.json", FileProfileStore.DefaultPath, StringComparison.OrdinalIgnoreCase);
        }
        else
        {
            Assert.Equal("/var/lib/DbHubDemo/activity.json", FileProfileStore.DefaultPath);
        }
    }
}
