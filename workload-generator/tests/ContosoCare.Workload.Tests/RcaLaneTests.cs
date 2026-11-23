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
        private readonly Lock sync = new();

        public void Set(DemoTarget target, bool on)
        {
            lock (sync)
            {
                if (on)
                {
                    active.Add(target);
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
    }

    private sealed class Store : ICaptureStore
    {
        public List<MemorySink> Spans { get; } = [];

        public ICaptureSpan Open(DateTimeOffset at)
        {
            var span = new MemorySink();
            lock (Spans)
            {
                Spans.Add(span);
            }

            return span;
        }
    }
}
