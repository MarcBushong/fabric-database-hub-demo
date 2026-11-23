using System.Runtime.CompilerServices;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The sidecar's wiring into the evidence export, its store, and the observer lane (T1b; the review of 1ca916a9's three
/// seams, and A1's evidence end): the export seals at one commit point that every path past its lock reaches, before
/// retention, with its output unchanged; retention never deletes a span whose sidecar rows wait unsealed, at a span's
/// opening too; the final wait and the span's evidence end are the store's, for the sidecar's export to share; and the
/// lane releases a target where its evidence's own end was done, so slow Query Store end reads change nothing in the span
/// or the export.
/// </summary>
public sealed class RcaSidecarWiringTests : IDisposable
{
    private const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    private static readonly DateTimeOffset From = new(2026, 11, 24, 8, 0, 0, TimeSpan.Zero);

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-wiring-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void EveryExportPathSealsAtOneCommitPointBeforeRetention()
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(Path.Combine(root, "store"), clock, host: "sqlvm01");
        var old = ExportedSpan(store, clock);
        File.WriteAllText(Path.Combine(old, RcaContract.SidecarRowsFile("T3")), "{}\n");
        var sealings = 0;
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0", () =>
        {
            // The sealer deletes what it seals: a span's rows file left behind always means unsealed rows.
            sealings++;
            foreach (var file in Directory.GetFiles(store.Root, EvidenceStore.UnsealedRowsPattern, SearchOption.AllDirectories))
            {
                File.Delete(file);
            }
        });

        // Past retention, with nothing new: the export seals, then retention deletes the span its sealing emptied.
        clock.Set(From.AddDays(7.1));
        var nothingNew = exporter.Export(Session, final: false, TimeSpan.Zero);

        Assert.Equal(1, sealings);
        Assert.False(Directory.Exists(old));
        Assert.Empty(nothingNew.Documents);

        // No span left at all, and a session's stop on an empty store: both still reach the commit point.
        var empty = exporter.Export(Session, final: true, TimeSpan.Zero);
        Assert.Equal(("Not selected", 2), (empty.Status, sealings));
        var stop = exporter.Export(Session, final: true, TimeSpan.Zero, endCapture: true);
        Assert.Equal(("Not selected", 3), (stop.Status, sealings));

        // A host without a store has nothing to seal and nothing to clean up.
        var none = new Exporter(new EvidenceStore(Path.Combine(root, "none"), clock, host: "sqlvm01"), RunnerLog.Null, "1.0.0", () => sealings++);
        Assert.Equal("Not selected", none.Export(Session, final: false, TimeSpan.Zero).Status);
        Assert.Equal(3, sealings);
    }

    [Fact]
    public void SealingAtTheExportChangesNothingItPrints()
    {
        var plain = ExportTwice(Path.Combine(root, "plain"), seal: null);
        var sealing = ExportTwice(Path.Combine(root, "sealing"), seal: () => { });
        var failing = ExportTwice(Path.Combine(root, "failing"), seal: () => throw new IOException("The sidecar store is locked."));

        Assert.Equal(2, plain.Count);
        Assert.Equal(plain, sealing);
        Assert.Equal(plain, failing);
    }

    [Fact]
    public void RetentionKeepsASpanWhoseSidecarRowsWaitUnsealedAndDeletesItOnceSealed()
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(Path.Combine(root, "store"), clock, host: "sqlvm01");
        var exported = ExportedSpan(store, clock);
        var unexported = ClosedSpan(store, From.AddMinutes(10));
        var rows = Path.Combine(exported, RcaContract.SidecarRowsFile("T3"));
        var takenAside = Path.Combine(unexported, "sidecar-T4.0001" + RcaContract.SidecarRowsExtension);
        File.WriteAllText(rows, "{}\n");
        File.WriteAllText(takenAside, "{}\n");

        // A span's opening runs retention without the export's lock and seals nothing: past both retention periods, the
        // spans whose rows aren't sealed stay.
        clock.Set(From.AddDays(30.1));
        store.Open(clock.Now).Close(clock.Now);
        Assert.True(Directory.Exists(exported));
        Assert.True(Directory.Exists(unexported));

        // Once sealed, each goes on schedule: the exported span at its 7 days, the one never exported at its 30.
        File.Delete(rows);
        File.Delete(takenAside);
        store.Open(clock.Now).Close(clock.Now);
        Assert.False(Directory.Exists(exported));
        Assert.False(Directory.Exists(unexported));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SlowQueryStoreEndReadsLeaveTheSpanAndTheExportAsWithoutASidecar(bool hostStops)
    {
        // The lane releases a target where its evidence's own end was done (TargetObserver.EndAsync's hook), not once the
        // sidecar's end reads have returned, whether its session ends or its host stops: on the lane's clock those reads
        // take 4 s a block here.
        var without = await RunLaneAsync(Path.Combine(root, "without"), sidecar: false, hostStops);
        var with = await RunLaneAsync(Path.Combine(root, "with"), sidecar: true, hostStops);

        Assert.Equal(0, without.EndReads);
        Assert.InRange(with.EndReads, 1, 100);
        Assert.True(with.ClockAfterEnd > with.ClockAtEnd, "The Query Store end reads took no time on the lane's clock.");
        Assert.Equal(without.ClockAtEnd, with.ClockAtEnd);
        Assert.Equal(without.Span, with.Span);
        Assert.Equal(without.Export, with.Export);
    }

    [Fact]
    public void TheFinalWaitAndTheSpansEvidenceEndAreTheStores()
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(Path.Combine(root, "store"), clock, host: "sqlvm01");
        var span = store.Open(From);
        span.Began("T1", From);

        Assert.False(store.WaitForSpans(TimeSpan.Zero));
        Assert.Null(Assert.Single(store.Spans()).EvidenceEndUtc);

        span.Ended("T1", From.AddMinutes(5));
        span.Close(From.AddMinutes(5));

        Assert.True(store.WaitForSpans(TimeSpan.Zero));
        Assert.Equal(From.AddMinutes(5), Assert.Single(store.Spans()).EvidenceEndUtc);

        // A span whose process is gone ends where its targets' evidence did.
        var orphan = new SpanInfo(root, new SpanFile
        {
            SpanId = "orphan",
            ProcessId = int.MaxValue,
            StartedUtc = From,
            Targets = new(StringComparer.Ordinal)
            {
                ["T1"] = new SpanTarget { Intervals = [new SpanInterval { From = From, To = From.AddMinutes(7) }] },
                ["T3"] = new SpanTarget { Intervals = [new SpanInterval { From = From }], WatermarkUtc = From.AddMinutes(9) },
            },
        }, new SpanExport());
        Assert.True(orphan.Orphaned);
        Assert.Equal(From.AddMinutes(9), orphan.EvidenceEndUtc);
    }

    /// <summary>
    /// T1 observed by the real lane, on a clock only the test and a slow Query Store block move: begun at 16:50, ticked at
    /// 16:52, then out of its session, or its host stopping (the lane cancelled). Returns its span record, its final export
    /// as printed, how many Query Store blocks ran at its end, and the clock when its end began and once the span closed.
    /// </summary>
    private static async Task<(string Span, string Export, int EndReads, DateTimeOffset ClockAtEnd, DateTimeOffset ClockAfterEnd)> RunLaneAsync(string storeRoot, bool sidecar, bool hostStops)
    {
        var clock = new ManualTime(RcaSimulation.T1From);
        var connector = new TimedConnector(clock, RcaSimulation.T1(clock));
        var ending = new StrongBox<bool>();
        connector.Cost = _ => Volatile.Read(ref ending.Value) ? TimeSpan.FromSeconds(4) : TimeSpan.Zero;
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var gate = new Gate();
        var observer = new SqlTargetObserver("T1", DemoTarget.T1, connector, RcaV1PinTests.PinOptions, RunnerLog.Null, sidecar ? new MemorySidecarSink() : null);
        var lane = new ObserverLane([observer], [], gate, store, RunnerLog.Null, clock);
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        int before;
        DateTimeOffset atEnd;
        try
        {
            gate.Active = true;
            await Until(() => store.Spans().Count == 1 && connector.Calls.ToArray().Any(c => c.BlockId == "RCA-SQL-09"));
            var tick = RcaSimulation.T1From.AddMinutes(2);
            clock.Set(tick);
            await Until(() => connector.Calls.ToArray().Any(c => c.At == tick && c.BlockId == "RCA-SQL-09"));
            before = Calls(connector);
            atEnd = clock.Now;
            Volatile.Write(ref ending.Value, true);
            if (hostStops)
            {
                await stop.CancelAsync();
                await running.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
            }
            else
            {
                gate.Active = false;
            }

            await Until(() => store.Spans().Single().Span.ClosedUtc is not null);
        }
        finally
        {
            await stop.CancelAsync();
            await running.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
        }

        var afterEnd = clock.Now;
        var span = File.ReadAllText(Path.Combine(store.Spans().Single().Directory, "span.json"));
        clock.Set(RcaSimulation.T1From.AddMinutes(10));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        var result = exporter.Export(Session, final: true, TimeSpan.Zero);
        var export = result.IndexLine() + string.Concat(result.Documents.SelectMany(d => Enumerable.Range(1, d.Parts).Select(i => "\n" + exporter.Part(d.DocumentId, i))));
        return (span, export, Calls(connector) - before, atEnd, afterEnd);

        // The lane adds calls while the test reads them: a copy, never the list itself.
        static int Calls(TimedConnector connector) => connector.Calls.ToArray().Count(c => c.BlockId is { } block && TimedConnector.QueryStoreBlocks.Contains(block));
    }

    private static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "The condition wasn't met in time.");
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
    }

    /// <summary>A closed span of T1 that an export took all of at <see cref="From"/> plus 4 minutes; its folder.</summary>
    private static string ExportedSpan(EvidenceStore store, ManualTime clock)
    {
        var directory = ClosedSpan(store, From);
        clock.Set(From.AddMinutes(4));
        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero);
        Assert.Single(result.Documents);
        Assert.True(Assert.Single(store.Spans(), s => s.Directory == directory).Export.Complete);
        return directory;
    }

    /// <summary>A span of T1 with four samples, closed 2 minutes after <paramref name="at"/>; its folder.</summary>
    private static string ClosedSpan(EvidenceStore store, DateTimeOffset at)
    {
        var span = store.Open(at);
        span.Began("T1", at);
        for (var i = 0; i < 4; i++)
        {
            var sampled = at.AddSeconds(30 * (i + 1));
            span.Write(new CaptureRow(RcaContract.Resource, "T1", sampled, "RCA-SQL-01", sentinel: true)
                .Set("at_utc", sampled)
                .Set("target", "T1")
                .Set("source", "RCA-SQL-01")
                .Set("metric", "cpu_percent")
                .Set("value", 20.0 + i));
        }

        span.Watermark("T1", at.AddMinutes(2));
        span.Ended("T1", at.AddMinutes(2));
        span.Close(at.AddMinutes(2));
        return span.Directory;
    }

    /// <summary>Two spans' exports as the runner prints and stores them: each index line, and each document's parts.</summary>
    private static List<string> ExportTwice(string storeRoot, Action? seal)
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0", seal);
        var printed = new List<string>();
        foreach (var at in new[] { From, From.AddMinutes(10) })
        {
            var directory = ClosedSpan(store, at);
            File.WriteAllText(Path.Combine(directory, RcaContract.SidecarRowsFile("T3")), "{}\n");
            clock.Set(at.AddMinutes(4));
            var result = exporter.Export(Session, final: true, TimeSpan.Zero);
            printed.Add(result.IndexLine() + string.Concat(result.Documents.SelectMany(d => Enumerable.Range(1, d.Parts).Select(i => "\n" + exporter.Part(d.DocumentId, i)))));
        }

        return printed;
    }

    /// <summary>T1 in a session from long before, until the test takes it out.</summary>
    private sealed class Gate : IObservationGate
    {
        private volatile bool active;

        public bool Active
        {
            get => active;
            set => active = value;
        }

        public bool IsActive(DemoTarget target) => active && target == DemoTarget.T1;

        public bool IsActiveAfter(DemoTarget target, DateTimeOffset end) => false;

        public bool HoldsAfter(DemoTarget target, DateTimeOffset end) => false;
    }
}
