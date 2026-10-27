using System.Data.SqlTypes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The profile host's lanes and supervisor (Phase 25b, after Phase 25a's T1 lane stopped serving without a trace), with a
/// fake profile store and fake runs on short real-time intervals. No SQL Server is needed.
/// </summary>
public sealed class ProfileHostTests
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(20);

    [Theory]
    [InlineData(typeof(SqlNullValueException))]
    [InlineData(typeof(TimeoutException))]
    [InlineData(typeof(NullReferenceException))]
    [InlineData(typeof(TaskCanceledException))]
    public async Task ALaneSurvivesAnyFailureOfOnePoll(Type exceptionType)
    {
        // Before Phase 25b, a profile read that failed with a type outside its catch filter ended the lane for good.
        var store = new FakeStore(Baseline());
        store.Fail(2, () => (Exception)Activator.CreateInstance(exceptionType)!);
        var work = new FakeWork();
        await using var host = HostHarness.Start(store, work, Options());

        await Until(() => work.Starts.Count >= 1);

        Assert.Equal("healthy-baseline", work.Starts[0].Scenario.Id);
        Assert.Contains("profile.read-failed", host.Log, StringComparison.Ordinal);
        Assert.Contains(exceptionType.Name, host.Log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AProfileReadThatNeverReturnsIsBounded()
    {
        var store = new FakeStore(Baseline());
        store.Hang(1, ignoreCancellation: true);
        var work = new FakeWork();
        await using var host = HostHarness.Start(store, work, Options());

        await Until(() => work.Starts.Count >= 1);

        Assert.Contains("took longer than", host.Log, StringComparison.Ordinal);
        Assert.DoesNotContain("profile.lane-stalled", host.Log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheSupervisorReplacesAStalledLaneAndReportsIt()
    {
        var store = new FakeStore(Baseline());
        store.Hang(1, ignoreCancellation: true);
        var work = new FakeWork();
        var options = Options() with { StoreTimeout = TimeSpan.FromSeconds(60), StallLimit = TimeSpan.FromMilliseconds(400) };
        await using var host = HostHarness.Start(store, work, options);

        await Until(() => work.Starts.Count >= 1);
        await Until(() => HostLanesFile.Read(host.StatePath).Document?.Lanes?.FirstOrDefault()?.Generation >= 2);

        Assert.Contains("profile.lane-stalled", host.Log, StringComparison.Ordinal);
        Assert.Contains("profile.lane-restarted", host.Log, StringComparison.Ordinal);
        var lane = HostLanesFile.Read(host.StatePath).Document!.Lanes!.Single();
        Assert.Equal(1, lane.Restarts);
        Assert.Contains("no poll finished", lane.LastRestartReason, StringComparison.Ordinal);
        Assert.Contains("reading the profile", lane.LastRestartReason, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AReplacedLaneKeepsItsRunsAndDoesNotStartThemAgain()
    {
        var store = new FakeStore(Baseline());
        var work = new FakeWork();
        var options = Options() with { StoreTimeout = TimeSpan.FromSeconds(60), StallLimit = TimeSpan.FromMilliseconds(400) };
        await using var host = HostHarness.Start(store, work, options);
        await Until(() => work.Starts.Count >= 1);

        store.Hang(1, ignoreCancellation: true);
        await Until(() => HostLanesFile.Read(host.StatePath).Document?.Lanes?.FirstOrDefault()?.Generation >= 2);
        await Task.Delay(500, TestContext.Current.CancellationToken);

        Assert.Single(work.Starts);
        Assert.Equal(0, work.Ended);
        Assert.Equal(1, HostLanesFile.Read(host.StatePath).Document!.Lanes!.Single().RunningRuns);
    }

    [Fact]
    public async Task ARunOfTheSameScenarioThatIsStillEndingDefersTheNextOne()
    {
        // Phase 25a (finding F1): a new profile's baseline started while the old baseline was still ending, so
        // demo.usp_run_begin refused it (50108) and it never ran. Now it waits until the old run has ended.
        var store = new FakeStore(Baseline());
        var work = new FakeWork { Behavior = FakeWork.UntilCancelled(TimeSpan.FromMilliseconds(600)) };
        await using var host = HostHarness.Start(store, work, Options());
        await Until(() => work.Starts.Count >= 1);

        store.Set(Baseline(DateTimeOffset.UtcNow));
        await Until(() => work.Starts.Count >= 2);

        Assert.True(work.Ended >= 1);
        Assert.True(work.Starts[1].At >= work.EndedAt[0], "The new baseline started before the old one had ended.");
        Assert.Contains("profile.start-deferred", host.Log, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("running-run")]
    [InlineData("run-limit")]
    [InlineData("connect")]
    public async Task ARefusalThatPassesIsRetried(string reason)
    {
        var store = new FakeStore(Baseline());
        var work = new FakeWork { Behavior = FakeWork.RefuseFirst(reason) };
        await using var host = HostHarness.Start(store, work, Options());

        await Until(() => work.Starts.Count >= 2);

        Assert.Contains("profile.start-retry", host.Log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RunsAnEarlierHostLeftRunningAreRecoveredBeforeTheFirstStartAndAfterA50108()
    {
        // Phase 25a: right after the task restarted, the new host's baseline was refused (50108) by the killed host's run.
        var store = new FakeStore(Baseline());
        var work = new FakeWork { Behavior = FakeWork.RefuseFirst("running-run") };
        var started = DateTimeOffset.UtcNow;
        await using var host = HostHarness.Start(store, work, Options());

        await Until(() => work.Starts.Count >= 2);

        Assert.Equal(2, work.Recoveries);
        Assert.InRange(work.RecoveredBefore!.Value, started - TimeSpan.FromSeconds(5), started + TimeSpan.FromSeconds(5));
        Assert.Contains("profile.orphans-recovered", host.Log, StringComparison.Ordinal);
        Assert.Contains("orphan-run", host.Log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARefusalThatDoesNotPassIsNotRetried()
    {
        var store = new FakeStore(Baseline());
        var work = new FakeWork { Behavior = FakeWork.RefuseFirst("sql") };
        await using var host = HostHarness.Start(store, work, Options());
        await Until(() => work.Starts.Count >= 1);

        await Task.Delay(800, TestContext.Current.CancellationToken);

        Assert.Single(work.Starts);
        Assert.DoesNotContain("profile.start-retry", host.Log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheHostWritesItsHeartbeatAndItsStop()
    {
        var store = new FakeStore(Baseline());
        var work = new FakeWork();
        var host = HostHarness.Start(store, work, Options());
        string statePath;
        try
        {
            statePath = host.StatePath;
            await Until(() => work.Starts.Count >= 1 && HostLanesFile.Read(statePath).Document?.Lanes?.Single().RunningRuns == 1);

            var running = HostLaneStatus.ForThisMachine(statePath, DemoTarget.T1, profileActive: true);
            Assert.Equal("Pass", running.Status);
            Assert.Equal("Serving", running.Lane!.State);

            await host.StopAsync();
            var stopped = HostLanesFile.Read(statePath).Document!;
            Assert.Equal("cancelled", stopped.StopReason);
            Assert.NotNull(stopped.StoppedAt);
            Assert.Equal("Stopped", stopped.Lanes!.Single().State);
            Assert.Equal(1, work.Ended);
            Assert.Equal("Pass", HostLaneStatus.ForThisMachine(statePath, DemoTarget.T1, profileActive: false).Status);
        }
        finally
        {
            await host.DisposeAsync();
        }
    }

    [Fact]
    public async Task TheHostStopsBeforeNotAfter()
    {
        var store = new FakeStore(Baseline());
        var work = new FakeWork();
        await using var host = HostHarness.Start(store, work, Options(), notAfter: DateTimeOffset.UtcNow + RunLimits.ShutdownMargin + TimeSpan.FromSeconds(1));

        await host.Task.WaitAsync(Wait, TestContext.Current.CancellationToken);

        Assert.Equal("not-after", HostLanesFile.Read(host.StatePath).Document!.StopReason);
        Assert.Contains("profile.not-after", host.Log, StringComparison.Ordinal);
    }

    private static ProfileHostOptions Options() => new()
    {
        Poll = TimeSpan.FromMilliseconds(50),
        StoreTimeout = TimeSpan.FromMilliseconds(300),
        CallGrace = TimeSpan.FromMilliseconds(100),
        ResetTimeout = TimeSpan.FromSeconds(5),
        StallLimit = TimeSpan.FromSeconds(5),
        SupervisorInterval = TimeSpan.FromMilliseconds(50),
        FirstRestartDelay = TimeSpan.FromMilliseconds(50),
        MaximumRestartDelay = TimeSpan.FromMilliseconds(200),
        RefusedRetryDelay = TimeSpan.FromMilliseconds(100),
        ShutdownWait = TimeSpan.FromSeconds(5),
    };

    private static ProfileState Baseline(DateTimeOffset? setAt = null)
    {
        var at = setAt ?? DateTimeOffset.UtcNow - TimeSpan.FromSeconds(1);
        return new ProfileState("baseline", at, "test", at + TimeSpan.FromMinutes(30), null);
    }

    private static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + Wait;
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "The condition wasn't met in time.");
            await Task.Delay(20, TestContext.Current.CancellationToken);
        }
    }

    /// <summary>Runs a profile host for one target (T1) with its heartbeat in a folder of its own.</summary>
    private sealed class HostHarness : IAsyncDisposable
    {
        private readonly CancellationTokenSource stop = new();
        private readonly LockedWriter writer = new();
        private readonly RunnerLog log;
        private readonly string folder = Path.Combine(AppContext.BaseDirectory, "profile-host-" + Guid.NewGuid().ToString("N"));
        private bool stopped;

        private HostHarness(FakeStore store, FakeWork work, ProfileHostOptions options, DateTimeOffset? notAfter)
        {
            StatePath = Path.Combine(folder, HostLanesFile.FileName);
            log = new RunnerLog(writer);
            var target = new ProfileTarget(DemoTarget.T1, new ScenarioRunner(new SqlConnectionOpener(TargetEndpoint.Create(DemoTarget.T1, null, false, null), log), log, TimeProvider.System), store);
            var host = new ProfileHost(ActivityProfilesDefinition.Default, ScenarioCatalog.Default, log, TimeProvider.System, options with { StateFilePath = StatePath }, _ => work);
            Task = Task.Run(() => host.RunAsync([target], notAfter, stop.Token), TestContext.Current.CancellationToken);
        }

        public Task Task { get; }

        public string StatePath { get; }

        public string Log => writer.Text;

        public static HostHarness Start(FakeStore store, FakeWork work, ProfileHostOptions options, DateTimeOffset? notAfter = null) => new(store, work, options, notAfter);

        public async Task StopAsync()
        {
            if (!stopped)
            {
                stopped = true;
                await stop.CancelAsync();
                await Task.WaitAsync(Wait, TestContext.Current.CancellationToken);
            }
        }

        public async ValueTask DisposeAsync()
        {
            await StopAsync();
            stop.Dispose();
            log.Dispose();
            writer.Dispose();
            if (Directory.Exists(folder))
            {
                Directory.Delete(folder, recursive: true);
            }
        }
    }

    private sealed class LockedWriter : StringWriter
    {
        private readonly Lock gate = new();

        public string Text
        {
            get
            {
                lock (gate)
                {
                    return ToString();
                }
            }
        }

        public override void WriteLine(string? value)
        {
            lock (gate)
            {
                base.WriteLine(value);
            }
        }
    }

    private sealed class FakeStore(ProfileState initial) : IProfileStore
    {
        private readonly Lock gate = new();
        private ProfileState state = initial;
        private int failures;
        private Func<Exception>? failure;
        private int hangs;
        private bool hangIgnoresCancellation;

        public string Description => "fake profile store";

        public void Set(ProfileState value)
        {
            lock (gate)
            {
                state = value;
            }
        }

        public void Fail(int times, Func<Exception> exception)
        {
            lock (gate)
            {
                failures = times;
                failure = exception;
            }
        }

        public void Hang(int times, bool ignoreCancellation)
        {
            lock (gate)
            {
                hangs = times;
                hangIgnoresCancellation = ignoreCancellation;
            }
        }

        public Task<ProfileState> GetAsync(CancellationToken cancellationToken)
        {
            lock (gate)
            {
                if (failures > 0)
                {
                    failures--;
                    throw failure!();
                }

                if (hangs > 0)
                {
                    hangs--;
                    return hangIgnoresCancellation ? new TaskCompletionSource<ProfileState>().Task : HangAsync(cancellationToken);
                }

                return Task.FromResult(state);
            }
        }

        public Task SetAsync(string profileName, string setBy, DateTimeOffset? expiresAt, ProfileParameters? parameters, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        private static async Task<ProfileState> HangAsync(CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken);
            throw new InvalidOperationException("Unreachable.");
        }
    }

    private sealed class FakeWork : ILaneWork
    {
        private readonly Lock gate = new();
        private readonly List<(RunPlan Plan, DateTimeOffset At)> starts = [];
        private readonly List<DateTimeOffset> ended = [];
        private int recoveries;

        public Func<RunPlan, CancellationToken, Task<RunResult>> Behavior { get; init; } = UntilCancelled(TimeSpan.Zero);

        public IReadOnlyList<(ScenarioDefinition Scenario, DateTimeOffset At)> Starts
        {
            get
            {
                lock (gate)
                {
                    return [.. starts.Select(s => (s.Plan.Scenario, s.At))];
                }
            }
        }

        public int Ended
        {
            get
            {
                lock (gate)
                {
                    return ended.Count;
                }
            }
        }

        public IReadOnlyList<DateTimeOffset> EndedAt
        {
            get
            {
                lock (gate)
                {
                    return [.. ended];
                }
            }
        }

        public static Func<RunPlan, CancellationToken, Task<RunResult>> UntilCancelled(TimeSpan ending) => async (plan, token) =>
        {
            try
            {
                await Task.Delay(Timeout.Infinite, token);
            }
            catch (OperationCanceledException)
            {
                // The host stopped the run; like a real run, it takes a moment to end and be recorded.
            }

            await Task.Delay(ending, CancellationToken.None);
            return Result(plan, "Cancelled", null);
        };

        public static Func<RunPlan, CancellationToken, Task<RunResult>> RefuseFirst(string reason)
        {
            var calls = 0;
            var rest = UntilCancelled(TimeSpan.Zero);
            return (plan, token) => Interlocked.Increment(ref calls) == 1 ? Task.FromResult(Result(plan, "Refused", reason)) : rest(plan, token);
        }

        public async Task<RunResult> RunAsync(RunPlan plan, CancellationToken cancellationToken)
        {
            lock (gate)
            {
                starts.Add((plan, DateTimeOffset.UtcNow));
            }

            try
            {
                return await Behavior(plan, cancellationToken);
            }
            finally
            {
                lock (gate)
                {
                    ended.Add(DateTimeOffset.UtcNow);
                }
            }
        }

        public Task<IReadOnlyList<CheckRecord>> ResetAsync(string requestedBy, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<CheckRecord>>([]);

        public int Recoveries => Volatile.Read(ref recoveries);

        public DateTimeOffset? RecoveredBefore { get; private set; }

        public Task<IReadOnlyList<string>?> RecoverOrphanedRunsAsync(DateTimeOffset startedBefore, CancellationToken cancellationToken)
        {
            RecoveredBefore = startedBefore;
            Interlocked.Increment(ref recoveries);
            return Task.FromResult<IReadOnlyList<string>?>(["orphan-run"]);
        }

        private static RunResult Result(RunPlan plan, string status, string? reason) => new()
        {
            RunId = "fake-" + Guid.NewGuid().ToString("N")[..8],
            ScenarioId = plan.Scenario.Id,
            Target = plan.Target,
            Status = status,
            Result = status == "Refused" ? "Fail" : "Pass",
            Outcome = status,
            RefusalReason = reason,
        };
    }
}
