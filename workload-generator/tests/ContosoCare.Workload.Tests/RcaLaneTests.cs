using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The observer lane in real time (ADR 0031): a target is captured while the profile host says it's in a session and
/// for no other reason; its capture ends, with the event session dropped, when the session does; the replica joins the
/// span only once it answers; and T5 is only noted.
/// </summary>
public sealed class RcaLaneTests
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(15);

    [Fact]
    public async Task ATargetIsCapturedOnlyWhileTheGateSaysItsInASession()
    {
        var connector = RcaSimulation.T1(new ManualTime(RcaSimulation.T1From));
        var gate = new Gate();
        var store = new Store();
        var lane = new ObserverLane([new SqlTargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null)], [DemoTarget.T5], gate, store, RunnerLog.Null, TimeProvider.System);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(1.5), TestContext.Current.CancellationToken);
            Assert.Empty(store.Spans);
            Assert.Empty(Calls(connector));

            gate.Set(DemoTarget.T1, true);
            gate.Set(DemoTarget.T5, true);
            await Until(() => Calls(connector).Contains("RCA-SQL-09"));
            var span = Assert.Single(store.Spans);
            Assert.Contains(span.Membership, m => m.Target == "T1" && m.Began);
            await Until(() => span.Membership.Any(m => m.Target == "T5" && m.Began));
            Assert.Contains(span.Notes, n => n.Target == "T5" && n.Kind == NoteKind.Gap);

            gate.Set(DemoTarget.T1, false);
            gate.Set(DemoTarget.T5, false);
            await Until(() => span.ClosedAt is not null);
            Assert.Equal("RCA-XE-05", Calls(connector)[^1]);
            var calls = Calls(connector).Count;
            await Task.Delay(TimeSpan.FromSeconds(1.5), TestContext.Current.CancellationToken);
            Assert.Equal(calls, Calls(connector).Count);
            Assert.Single(store.Spans);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task AStopsEndOfCaptureEndsItWithinASecondWhileTheSessionRunsOnAndOnlyAProfileSetAfterItIsCapturedAgain()
    {
        // O1 (Final tests' live round at d7df4f9f): the session control's stop sends nothing to stop the profiles, so the
        // workload runs on until the VMs deallocate. The end that its export records ends the capture all the same, as a
        // profile's end does, so the export's --final wait sees the span close.
        var connector = RcaSimulation.T1(new ManualTime(RcaSimulation.T1From));
        var gate = new Gate();
        var store = new Store();
        var lane = new ObserverLane([new SqlTargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null)], [DemoTarget.T5], gate, store, RunnerLog.Null, TimeProvider.System);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            gate.Set(DemoTarget.T1, true);
            gate.Set(DemoTarget.T5, true);
            await Until(() => Calls(connector).Contains("RCA-SQL-09") && store.Spans.Count == 1 && store.Spans[0].Membership.Any(m => m.Target == "T5" && m.Began));
            var span = store.Spans[0];

            store.EndedAt = DateTimeOffset.UtcNow;
            var ended = DateTime.UtcNow;
            await Until(() => span.ClosedAt is not null);
            Assert.True(DateTime.UtcNow - ended < TimeSpan.FromSeconds(5), "The capture didn't end within a few seconds of the stop's end.");
            Assert.True(gate.IsActive(DemoTarget.T1), "The workload runs on: the profile host still says T1 is in its session.");
            Assert.Equal("RCA-XE-05", Calls(connector)[^1]);
            Assert.Contains(span.Membership, m => m.Target == "T5" && !m.Began);
            var calls = Calls(connector).Count;
            await Task.Delay(TimeSpan.FromSeconds(1.5), TestContext.Current.CancellationToken);
            Assert.Equal(calls, Calls(connector).Count);
            Assert.Single(store.Spans);

            // The next session sets T1's profile again, after the end: captured again, in a span of its own.
            gate.Set(DemoTarget.T1, true, profileSetAt: DateTimeOffset.UtcNow);
            await Until(() => store.Spans.Count == 2 && Calls(connector).Count > calls);
            Assert.Contains(store.Spans[1].Membership, m => m.Target == "T1" && m.Began);
            Assert.DoesNotContain(store.Spans[1].Membership, m => m.Target == "T5");
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task AnEndAheadOfTheLanesClockWhenFirstReadStaysIgnoredWhenTheClockCatchesUp()
    {
        // The review of 1ca916a9: an end more than a minute ahead was ignored only until the lane's clock caught up, so a
        // clock that went back postponed the end rather than leaving the capture as it was. Kept for that end now; a new
        // stop's end is decided afresh.
        var clock = new OffsetTime();
        var connector = RcaSimulation.T1(new ManualTime(RcaSimulation.T1From));
        var gate = new Gate();
        var store = new Store { EndedAt = DateTimeOffset.UtcNow + ObserverLane.FutureEndLimit + TimeSpan.FromMinutes(5) };
        var lane = new ObserverLane([new SqlTargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null)], [], gate, store, RunnerLog.Null, clock);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            gate.Set(DemoTarget.T1, true);
            await Until(() => Calls(connector).Contains("RCA-SQL-09"));
            await Task.Delay(TimeSpan.FromSeconds(1.5), TestContext.Current.CancellationToken);
            var span = Assert.Single(store.Spans);
            Assert.Null(span.ClosedAt);

            clock.Offset = TimeSpan.FromMinutes(10);
            await Task.Delay(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            Assert.Null(span.ClosedAt);
            Assert.Single(store.Spans);

            store.EndedAt = clock.GetUtcNow();
            await Until(() => span.ClosedAt is not null);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task AnEndAppliedWhenFirstReadStaysAppliedWhenTheClockGoesBack()
    {
        // The other way: once in force, an end that a clock gone back would put ahead mustn't open capture again.
        var clock = new OffsetTime();
        var connector = RcaSimulation.T1(new ManualTime(RcaSimulation.T1From));
        var gate = new Gate();
        var store = new Store();
        var lane = new ObserverLane([new SqlTargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null)], [], gate, store, RunnerLog.Null, clock);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            gate.Set(DemoTarget.T1, true);
            await Until(() => Calls(connector).Contains("RCA-SQL-09"));
            store.EndedAt = clock.GetUtcNow();
            await Until(() => store.Spans.Count == 1 && store.Spans[0].ClosedAt is not null);

            clock.Offset = -TimeSpan.FromMinutes(10);
            await Task.Delay(TimeSpan.FromSeconds(2.5), TestContext.Current.CancellationToken);
            Assert.Single(store.Spans);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task AtTheEndEveryTargetsCaptureEndsAndOnlyTheSpansCloseWaitsForTheAnswerKey()
    {
        // The review of 1ca916a9: the answer key of a fault run that ended by the end held its target's capture open, a
        // coverage tail that only the fault explained. Now every target's capture ends at the end, and the span stays open,
        // capturing nothing, until the answer key has the run, so the stop's export still takes it.
        var connector = RcaSimulation.T1(new ManualTime(RcaSimulation.T1From));
        var gate = new Gate();
        var store = new Store();
        var lane = new ObserverLane([new SqlTargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null)], [DemoTarget.T5], gate, store, RunnerLog.Null, TimeProvider.System);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            gate.Set(DemoTarget.T1, true);
            gate.Set(DemoTarget.T5, true);
            await Until(() => Calls(connector).Contains("RCA-SQL-09") && store.Spans.Count == 1 && store.Spans[0].Membership.Any(m => m.Target == "T5" && m.Began));
            var span = store.Spans[0];

            gate.Hold(DemoTarget.T1, true);
            store.EndedAt = DateTimeOffset.UtcNow;
            await Until(() => span.Membership.Any(m => m.Target == "T1" && !m.Began) && span.Membership.Any(m => m.Target == "T5" && !m.Began));
            Assert.Equal("RCA-XE-05", Calls(connector)[^1]);
            var ended = span.Membership.Where(m => !m.Began).Max(m => m.At);
            var calls = Calls(connector).Count;
            await Task.Delay(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            Assert.Null(span.ClosedAt);
            Assert.Equal(calls, Calls(connector).Count);

            gate.Hold(DemoTarget.T1, false);
            await Until(() => span.ClosedAt is not null);
            Assert.Equal(ended, span.ClosedAt);
            Assert.Equal(calls, Calls(connector).Count);
            Assert.Single(store.Spans);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task AHeldSpansCloseThatFailsIsTriedAgainTheNextSecond()
    {
        // The re-check of 9440acf2: a failed write of span.json ended the loop that closes a held span, for good.
        var (connector, gate, store, lane) = HoldingLane();
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            var (span, ended) = await HoldAtTheEndAsync(connector, gate, store);
            span.CloseFailures = 2;
            gate.Hold(DemoTarget.T1, false);
            await Until(() => span.ClosedAt is not null);
            Assert.Equal(ended, span.ClosedAt);
            Assert.Equal(0, span.CloseFailures);
            Assert.Single(store.Spans);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task ALaneStoppedDuringAHoldClosesTheSpanAtItsLastEndTryingAgainWhenItsWriteFails()
    {
        // The re-check of 9440acf2: the lane's stop closes a held span whatever the answer key does, and a failed write there
        // was thrown out of the lane's stop.
        var (connector, gate, store, lane) = HoldingLane();
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            var (span, ended) = await HoldAtTheEndAsync(connector, gate, store);
            await Task.Delay(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            Assert.Null(span.ClosedAt);
            span.CloseFailures = 1;
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
            Assert.Equal(ended, span.ClosedAt);
            Assert.Equal(0, span.CloseFailures);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task AProfileSetAfterTheEndDuringAHoldClosesTheHeldSpanAtItsLastEndAndOpensANewOne()
    {
        // The re-check of 9440acf2: a session that begins while the stopped session's span waits for the answer key gets a
        // span of its own, and the stopped session's ends where its capture did.
        var (connector, gate, store, lane) = HoldingLane();
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            var (span, ended) = await HoldAtTheEndAsync(connector, gate, store);
            gate.Set(DemoTarget.T1, true, profileSetAt: DateTimeOffset.UtcNow);
            await Until(() => store.Spans.Count == 2 && store.Spans[1].Membership.Any(m => m.Target == "T1" && m.Began));
            Assert.Equal(ended, span.ClosedAt);
            Assert.DoesNotContain(store.Spans[1].Membership, m => m.Target == "T5");
            Assert.Null(store.Spans[1].ClosedAt);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task ANotedTargetsNewSessionDuringAHoldTriesTheHeldSpansCloseAgainWhenItFails()
    {
        // The re-check of 9440acf2: the note loop has no catch of its own, so a failed close of the held span when T5's next
        // session began ended it, and T5 joined no span again.
        var (connector, gate, store, lane) = HoldingLane();
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            var (span, ended) = await HoldAtTheEndAsync(connector, gate, store);
            span.CloseFailures = 1;
            gate.Set(DemoTarget.T5, true, profileSetAt: DateTimeOffset.UtcNow);
            await Until(() => store.Spans.Count == 2 && store.Spans[1].Membership.Any(m => m.Target == "T5" && m.Began));
            Assert.Equal(ended, span.ClosedAt);
            Assert.Equal(0, span.CloseFailures);
            Assert.DoesNotContain(store.Spans[1].Membership, m => m.Target == "T1");
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task TheReplicaJoinsTheSpanOnlyOnceItAnswers()
    {
        var replica = new ScriptedConnector((_, _) => []) { OpenFailure = new CaptureException(CaptureFailureKind.Connection, "No such host is known.") };
        var primary = new ScriptedConnector((_, _) => []);
        var link = new ReplicaLink();
        var gate = new Gate();
        var store = new Store();
        var options = new ObserverOptions { Reconnect = TimeSpan.FromSeconds(1) };
        var lane = new ObserverLane([new PgPrimaryObserver(primary, options, RunnerLog.Null, link), new PgReplicaObserver(replica, options, RunnerLog.Null, link)], [], gate, store, RunnerLog.Null, TimeProvider.System, options);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        try
        {
            gate.Set(DemoTarget.T4, true);
            await Until(() => store.Spans.Count == 1 && store.Spans[0].Membership.Any(m => m.Target == "T4"));
            await Task.Delay(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
            Assert.DoesNotContain(store.Spans[0].Membership, m => m.Target == "T4-replica");

            replica.OpenFailure = null;
            await Until(() => store.Spans[0].Membership.Any(m => m.Target == "T4-replica" && m.Began));
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(Wait, TestContext.Current.CancellationToken);
        }

        Assert.NotNull(store.Spans[0].ClosedAt);
    }

    private static List<string> Calls(ScriptedConnector connector)
    {
        lock (connector.Calls)
        {
            return [.. connector.Calls.Select(c => c.BlockId)];
        }
    }

    /// <summary>A lane that observes T1 and notes T5, for the held span's tests.</summary>
    private static (ScriptedConnector Connector, Gate Gate, Store Store, ObserverLane Lane) HoldingLane()
    {
        var connector = RcaSimulation.T1(new ManualTime(RcaSimulation.T1From));
        var gate = new Gate();
        var store = new Store();
        return (connector, gate, store, new ObserverLane([new SqlTargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null)], [DemoTarget.T5], gate, store, RunnerLog.Null, TimeProvider.System));
    }

    /// <summary>
    /// T1 and T5 in a session, then the capture's end while the answer key still has to record a T1 fault run that ended by
    /// then: both captures end, and the span waits to close. Returns it, and when its last member ended.
    /// </summary>
    private static async Task<(MemorySink Span, DateTimeOffset Ended)> HoldAtTheEndAsync(ScriptedConnector connector, Gate gate, Store store)
    {
        gate.Set(DemoTarget.T1, true);
        gate.Set(DemoTarget.T5, true);
        await Until(() => Calls(connector).Contains("RCA-SQL-09") && store.Spans.Count == 1 && store.Spans[0].Membership.Any(m => m.Target == "T5" && m.Began));
        var span = store.Spans[0];
        gate.Hold(DemoTarget.T1, true);
        store.EndedAt = DateTimeOffset.UtcNow;
        await Until(() => span.Membership.Any(m => m.Target == "T1" && !m.Began) && span.Membership.Any(m => m.Target == "T5" && !m.Began));
        return (span, span.Membership.Where(m => !m.Began).Max(m => m.At));
    }

    private static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + Wait;
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "The condition wasn't met in time.");
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
    }

    private sealed class Gate : IObservationGate
    {
        private readonly HashSet<DemoTarget> active = [];
        private readonly HashSet<DemoTarget> held = [];
        private readonly Dictionary<DemoTarget, DateTimeOffset> setAt = [];
        private readonly Lock sync = new();

        /// <summary>A target in a session or not; with <paramref name="profileSetAt"/>, when its profile was set (an hour ago by default).</summary>
        public void Set(DemoTarget target, bool on, DateTimeOffset? profileSetAt = null)
        {
            lock (sync)
            {
                if (on)
                {
                    active.Add(target);
                    setAt[target] = profileSetAt ?? DateTimeOffset.UtcNow - TimeSpan.FromHours(1);
                }
                else
                {
                    active.Remove(target);
                }
            }
        }

        public bool IsActive(DemoTarget target)
        {
            lock (sync)
            {
                return active.Contains(target);
            }
        }

        public bool IsActiveAfter(DemoTarget target, DateTimeOffset end)
        {
            lock (sync)
            {
                return active.Contains(target) && setAt[target] > end;
            }
        }

        /// <summary>Whether the answer key still has to record a fault run of the target that ended by the end.</summary>
        public void Hold(DemoTarget target, bool on)
        {
            lock (sync)
            {
                if (on)
                {
                    held.Add(target);
                }
                else
                {
                    held.Remove(target);
                }
            }
        }

        public bool HoldsAfter(DemoTarget target, DateTimeOffset end)
        {
            lock (sync)
            {
                return held.Contains(target);
            }
        }
    }

    /// <summary>The system's clock, set ahead or back by <see cref="Offset"/>; its timers are the system's.</summary>
    private sealed class OffsetTime : TimeProvider
    {
        private long offsetTicks;

        public TimeSpan Offset
        {
            get => TimeSpan.FromTicks(Interlocked.Read(ref offsetTicks));
            set => Interlocked.Exchange(ref offsetTicks, value.Ticks);
        }

        public override DateTimeOffset GetUtcNow() => base.GetUtcNow() + Offset;
    }

    private sealed class Store : ICaptureStore
    {
        private readonly Lock sync = new();
        private DateTimeOffset? endedAt;

        public List<MemorySink> Spans { get; } = [];

        /// <summary>The capture's end, as rca export --end-capture records it.</summary>
        public DateTimeOffset? EndedAt
        {
            get
            {
                lock (sync)
                {
                    return endedAt;
                }
            }

            set
            {
                lock (sync)
                {
                    endedAt = value;
                }
            }
        }

        public ICaptureSpan Open(DateTimeOffset at)
        {
            var span = new MemorySink();
            lock (Spans)
            {
                Spans.Add(span);
            }

            return span;
        }

        public DateTimeOffset? CaptureEndedAt() => EndedAt;
    }
}
