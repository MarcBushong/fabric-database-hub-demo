using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Sidecar;
using ContosoCare.Workload.Rca.Store;
using Json.Schema;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The sidecar's wiring into the evidence export, its store, the observer lane, and the runner's commands (T1b; the review
/// of 1ca916a9's three seams, and A1's evidence end): the export seals at one commit point that every path past its lock
/// reaches, before retention, with its output unchanged; retention never deletes a span whose sidecar rows wait unsealed,
/// at a span's opening too; the final wait and the span's evidence end are the store's, for the sidecar's export to share;
/// the lane releases a target where its evidence's own end was done, so slow Query Store end reads change nothing in the
/// span or the export, on T1 and on T4 and its replica as the construction site makes them; the commands' lines and exit
/// codes; a sidecar export that comes first binds its span as the evidence export would; and the observer's start and a
/// span's close seal.
/// </summary>
public sealed class RcaSidecarWiringTests : IDisposable
{
    private const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    private static readonly DateTimeOffset From = new(2026, 11, 24, 8, 0, 0, TimeSpan.Zero);

    // A registry of its own: JsonSchema.Net registers a schema by its $id, once per registry.
    private static readonly Lazy<JsonSchema> SidecarSchema = new(() =>
        JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("rca", "sidecar.schema.json")), new BuildOptions { SchemaRegistry = new SchemaRegistry() }));

    private static readonly Lazy<Regex> SidecarPartLine = new(() =>
    {
        using var schema = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "transport.schema.json")));
        return new Regex(schema.RootElement.GetProperty("$defs").GetProperty("sidecarPartLine").GetProperty("pattern").GetString()!, RegexOptions.CultureInvariant);
    });

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
        // The lane releases a target where its evidence's own end was done (TargetObserver.EndAsync's hook, on the lane's
        // clock), not once the sidecar's end reads have returned, whether its session ends or its host stops: on the lane's
        // clock those reads take 4 s a block here, and the evidence's end 3 s, its event session's drop.
        var without = await RunLaneAsync(Path.Combine(root, "without"), sidecar: false, hostStops);
        var with = await RunLaneAsync(Path.Combine(root, "with"), sidecar: true, hostStops);

        Assert.Equal(0, without.EndReads);
        Assert.InRange(with.EndReads, 1, 100);
        Assert.True(with.ClockAfterEnd > with.ClockAtEnd + TimeSpan.FromSeconds(3), "The Query Store end reads took no time on the lane's clock.");
        Assert.Equal(without.ClockAtEnd, with.ClockAtEnd);
        Assert.Equal(without.Span, with.Span);
        Assert.Equal(without.Export, with.Export);

        // The span's end and the evidence's last watermark are where its own end was done, after the drop: not where the
        // lane began to end the target.
        var evidenceEnd = with.ClockAtEnd + TimeSpan.FromSeconds(3);
        Assert.Equal<(DateTimeOffset?, DateTimeOffset?, DateTimeOffset?)>((evidenceEnd, evidenceEnd, evidenceEnd), with.Ends);
        Assert.Equal(with.Ends, without.Ends);
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

    [Theory]
    [InlineData(false, "T4")]
    [InlineData(true, "T4")]
    [InlineData(false, "T4-replica")]
    [InlineData(true, "T4-replica")]
    public async Task SlowSidecarEndReadsOnT4LeaveTheSpanAndTheExportAsWithoutASidecar(bool hostStops, string target)
    {
        // T4 and its replica as the construction site makes them (SidecarRuntime.Postgres), against the same observers
        // without a sidecar: once their end begins, each sidecar block takes 4 s on the lane's clock (Query Store's, on
        // azure_sys and the observer's own connection, and the replica's RCA-PG-13). The span, its watermark, and the
        // export are as without a sidecar, and end where the evidence's own end was done, before those reads.
        var without = await RunT4LaneAsync(Path.Combine(root, "without"), target, sidecar: false, hostStops);
        var with = await RunT4LaneAsync(Path.Combine(root, "with"), target, sidecar: true, hostStops);

        Assert.Equal(0, without.EndReads);
        Assert.InRange(with.EndReads, 1, 100);
        Assert.True(with.ClockAfterEnd >= with.ClockAtEnd + TimeSpan.FromSeconds(4), "The sidecar's end reads took no time on the lane's clock.");
        Assert.Equal(without.ClockAtEnd, with.ClockAtEnd);
        Assert.Equal(without.Span, with.Span);
        Assert.Equal(without.Export, with.Export);
        Assert.Equal<(DateTimeOffset?, DateTimeOffset?, DateTimeOffset?)>((with.ClockAtEnd, with.ClockAtEnd, with.ClockAtEnd), with.Ends);
        Assert.Equal(with.Ends, without.Ends);
    }

    [Fact]
    public void TheSidecarCommandsPrintOneLineWhoseExitCodeSaysWhatHappened()
    {
        var store = Path.Combine(root, "store");
        var ids = AckFixtureIds();

        // A host with no store: nothing to fetch (exit code 2, with its line), and no ID it holds (exit code 0, each named).
        var (none, noneLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", "none", "--final", "--rca-store", store);
        var (ackNone, ackNoneLine, _) = CliHarness.Invoke("rca", "ack", "--document", string.Join(',', ids), "--rca-store", store);
        var (partNone, _, partError) = CliHarness.Invoke("rca", "part", "--document", ids[0], "--part", "1", "--rca-store", store);
        Assert.Equal((2, "Not selected", 0), (none, Index(noneLine)["status"]!.GetValue<string>(), Index(noneLine)["pages"]!.GetValue<int>()));
        Assert.Equal(0, ackNone);
        Assert.Single(ackNoneLine.Split('\n', StringSplitOptions.RemoveEmptyEntries));
        Assert.All(ids, id => Assert.Contains(id, ackNoneLine, StringComparison.Ordinal));
        Assert.Equal(1, partNone);
        Assert.Contains("No part 1 of sidecar", partError, StringComparison.Ordinal);
        Assert.False(Directory.Exists(store));

        // Refused before anything runs: exit code 1, with a Fail line.
        var (badSession, badSessionLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", "not-a-session", "--rca-store", store);
        var (badPage, badPageLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", "none", "--page", "0", "--rca-store", store);
        var (badAck, badAckLine, _) = CliHarness.Invoke("rca", "ack", "--document", ids[0] + ",20261120T165000Z-sqlvm01-0001", "--rca-store", store);
        Assert.Equal((1, "Fail"), (badSession, Index(badSessionLine)["status"]!.GetValue<string>()));
        Assert.Equal((1, "Fail"), (badPage, Index(badPageLine)["status"]!.GetValue<string>()));
        Assert.Equal(1, badAck);
        Assert.Contains("nothing was acknowledged", badAckLine, StringComparison.Ordinal);
        Assert.False(Directory.Exists(store));

        // A store the runner can't use: any failure is exit code 1 with its line, never exit code 2's nothing to fetch.
        Directory.CreateDirectory(store);
        File.WriteAllText(Path.Combine(store, SidecarStore.FolderName), "not a folder");
        var (failed, failedLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", "none", "--rca-store", store);
        var (ackFailed, ackFailedLine, _) = CliHarness.Invoke("rca", "ack", "--document", ids[0], "--rca-store", store);
        Assert.Equal((1, "Fail"), (failed, Index(failedLine)["status"]!.GetValue<string>()));
        Assert.Equal(1, ackFailed);
        Assert.StartsWith("rca ack: failed", ackFailedLine, StringComparison.Ordinal);
    }

    [Fact]
    public void ASidecarTravelsThroughTheCommandsUntilItsAcknowledged()
    {
        // The commands run on the system's clock: the span ends 18 minutes ago.
        var clock = new ManualTime(DateTimeOffset.UtcNow.AddMinutes(-20));
        var storeRoot = Path.Combine(root, "store");
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        ClosedSpan(store, clock.Now, new SidecarRuntime(store, "1.0.0", RunnerLog.Null).Sink);

        var (first, firstLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", Session, "--final", "--rca-store", storeRoot);
        var index = Index(firstLine);
        var listed = Assert.Single(index["documents"]!.AsArray())!;
        var documentId = listed["documentId"]!.GetValue<string>();
        Assert.Equal(0, first);
        Assert.Equal(("Pass", "new", Session), (index["status"]!.GetValue<string>(), listed["state"]!.GetValue<string>(), listed["sessionId"]!.GetValue<string>()));

        // Its parts, as rca part prints them: the sidecar the index names, by its SHA-256, the contract's schema, and its session.
        var parts = Enumerable.Range(1, listed["parts"]!.GetValue<int>())
            .Select(i => CliHarness.Invoke("rca", "part", "--document", documentId, "--part", i.ToString(CultureInfo.InvariantCulture), "--rca-store", storeRoot))
            .ToList();
        Assert.All(parts, p => Assert.Equal(0, p.ExitCode));
        var lines = parts.Select(p => p.Output.Trim()).ToList();
        Assert.All(lines, l => Assert.Matches(SidecarPartLine.Value, l));
        var gzip = lines.SelectMany(l => Convert.FromBase64String(l.Split(' ')[5])).ToArray();
        Assert.Equal(listed["sha256"]!.GetValue<string>(), PartCodec.Sha256(gzip));
        var json = Encoding.UTF8.GetString(PartCodec.Gunzip(gzip));
        Assert.Empty(RcaSchemas.Errors(SidecarSchema, json));
        Assert.Equal(Session, JsonNode.Parse(json)!["sessionId"]!.GetValue<string>());

        // Offered again, pending, until it's acknowledged; an ID the runner doesn't hold is named, with exit code 0.
        var (again, againLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", Session, "--rca-store", storeRoot);
        Assert.Equal((0, "pending"), (again, Assert.Single(Index(againLine)["documents"]!.AsArray())!["state"]!.GetValue<string>()));
        var gone = AckFixtureIds()[0];
        var (ack, ackLine, _) = CliHarness.Invoke("rca", "ack", "--document", documentId + "," + gone, "--rca-store", storeRoot);
        Assert.Equal(0, ack);
        Assert.StartsWith("rca ack: 1 sidecar acknowledged as written into the history now, and 0 sidecars before. 1 sidecar this runner doesn't hold", ackLine, StringComparison.Ordinal);
        Assert.EndsWith(": " + gone + ".", ackLine.Trim(), StringComparison.Ordinal);

        // Then nothing is offerable: exit code 2, with its line; and the same acknowledgement again changes nothing.
        var (after, afterLine, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", Session, "--rca-store", storeRoot);
        var (ackAgain, ackAgainLine, _) = CliHarness.Invoke("rca", "ack", "--document", documentId, "--rca-store", storeRoot);
        Assert.Equal((2, "Not selected"), (after, Index(afterLine)["status"]!.GetValue<string>()));
        Assert.Equal((0, "rca ack: 0 sidecars acknowledged as written into the history now, and 1 sidecar before."), (ackAgain, ackAgainLine.Trim()));
    }

    [Fact]
    public void ASidecarThatExpiredUnreadIsAWarningWithNothingToFetch()
    {
        // Sealed 31 days ago and never acknowledged: the next sidecar export deletes it and counts it, with exit code 2, its
        // line printed, and its status standing.
        var clock = new ManualTime(DateTimeOffset.UtcNow.AddDays(-31));
        var storeRoot = Path.Combine(root, "store");
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var runtime = new SidecarRuntime(store, "1.0.0", RunnerLog.Null);
        ClosedSpan(store, clock.Now, runtime.Sink);
        clock.Set(clock.Now.AddMinutes(5));
        Assert.Single(runtime.Sealer.SealAll().Sealed);

        var (exit, line, _) = CliHarness.Invoke("rca", "sidecar-export", "--session", "none", "--rca-store", storeRoot);

        var index = Index(line);
        Assert.Equal((2, "Warning", 0), (exit, index["status"]!.GetValue<string>(), index["pages"]!.GetValue<int>()));
        Assert.Contains("1 sidecar expired unread", index["message"]!.GetValue<string>(), StringComparison.Ordinal);
    }

    [Fact]
    public void TheEvidenceExportCommandSealsTheSpansSidecarRows()
    {
        var clock = new ManualTime(DateTimeOffset.UtcNow.AddMinutes(-20));
        var storeRoot = Path.Combine(root, "store");
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var runtime = new SidecarRuntime(store, "1.0.0", RunnerLog.Null);
        var span = ClosedSpan(store, clock.Now, runtime.Sink);

        var (exit, output, _) = CliHarness.Invoke("rca", "export", "--session", Session, "--final", "--wait-seconds", "0", "--rca-store", storeRoot);

        Assert.Equal(0, exit);
        Assert.StartsWith(RcaContract.IndexMarker + " {", output, StringComparison.Ordinal);
        Assert.False(EvidenceStore.HoldsUnsealedRows(span));
        Assert.Equal(Path.GetFileName(span), Assert.Single(runtime.Store.ReadLedger().Sidecars).SpanId);
    }

    [Fact]
    public void ASidecarExportBeforeTheEvidenceExportBindsTheSpanAsTheEvidenceExportWould()
    {
        // The first export that takes from a span binds it to the caller's session, whichever of the two it is; the
        // evidence export prints the same bytes either way, and the sidecar is the same.
        var sidecarFirst = BothExports(Path.Combine(root, "sidecar-first"), sidecarFirst: true, Session, Session);
        var evidenceFirst = BothExports(Path.Combine(root, "evidence-first"), sidecarFirst: false, Session, Session);

        Assert.Equal((Session, Session), (sidecarFirst.SidecarSession, sidecarFirst.EvidenceSession));
        Assert.Equal((Session, Session), (evidenceFirst.SidecarSession, evidenceFirst.EvidenceSession));
        Assert.Equal(evidenceFirst.Evidence, sidecarFirst.Evidence);
        Assert.Equal(evidenceFirst.Sidecar, sidecarFirst.Sidecar);

        // A later evidence export for another session keeps the span's, as it keeps an earlier evidence export's.
        var other = BothExports(Path.Combine(root, "other"), sidecarFirst: true, Session, "0123456789abcdef0123456789abcdef");
        Assert.Equal((Session, Session), (other.SidecarSession, other.EvidenceSession));
    }

    [Fact]
    public void AFinalSidecarExportWhoseWaitRunsOutSaysTheObserverWasStillCapturing()
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(Path.Combine(root, "store"), clock, host: "sqlvm01");
        var runtime = new SidecarRuntime(store, "1.0.0", RunnerLog.Null);
        var span = store.Open(From);
        span.Began("T1", From);
        runtime.Sink.Write(SidecarRig.Stats("T1", From.AddMinutes(-15), 412, 2400));
        runtime.Sink.Write(SidecarRig.Coverage("T1", From.AddMinutes(-15), From.AddMinutes(2)));
        clock.Set(From.AddMinutes(3));

        var page = SidecarCommands.Export(runtime, Session, final: true, TimeSpan.Zero, 1);

        // What it captured so far is sealed and offered, with the open span bound to the session; the rest comes later.
        Assert.Equal(("Warning", 0), (page.Status, page.ExitCode));
        Assert.Contains(SidecarCommands.StillCapturing, page.Message, StringComparison.Ordinal);
        Assert.Equal(Session, Assert.Single(page.Documents).SessionId);
        span.Close(clock.Now);
    }

    [Fact]
    public async Task TheObserversStartSealsWhatAnEarlierRunLeftAndEachSpanOnceItCloses()
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(Path.Combine(root, "store"), clock, host: "sqlvm01");

        // An earlier run's span, closed with its rows unsealed: this run's start seals it.
        var earlier = ClosedSpan(store, From, new SidecarRuntime(store, "1.0.0", RunnerLog.Null).Sink);
        clock.Set(From.AddMinutes(10));
        var runtime = new SidecarRuntime(store, "1.0.0", RunnerLog.Null);
        runtime.Start();
        await Until(() => Sealed(runtime, earlier));

        // A span this run closes is sealed once it's closed.
        var closed = ClosedSpan(store, From.AddMinutes(10), runtime.Sink);
        await Until(() => Sealed(runtime, closed));

        // After the observer's end, a span's close seals nothing: its rows wait for the next export.
        await runtime.StopAsync(TimeSpan.FromSeconds(30));
        var later = ClosedSpan(store, From.AddMinutes(20), runtime.Sink);
        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.True(EvidenceStore.HoldsUnsealedRows(later));
        Assert.Equal(2, runtime.Store.ReadLedger().Sidecars.Count);
    }

    /// <summary>
    /// T4's primary or its replica observed alone by the real lane, on a clock only the test and the sidecar's blocks move:
    /// begun at 17:00, then, once its first reads are done (with a sidecar, its first Query Store read too, whose coverage
    /// row is its last step), out of its session or its host stopping. From then on each sidecar block takes 4 s. Returns
    /// its span record, its final export as printed, how many sidecar blocks cost time, the clock when its end began and
    /// once the span closed, and the target's interval end, last watermark, and the span's close.
    /// </summary>
    private static async Task<(string Span, string Export, int EndReads, DateTimeOffset ClockAtEnd, DateTimeOffset ClockAfterEnd, (DateTimeOffset?, DateTimeOffset?, DateTimeOffset?) Ends)> RunT4LaneAsync(string storeRoot, string target, bool sidecar, bool hostStops)
    {
        var clock = new ManualTime(RcaSimulation.T4From);
        var t4 = new T4QueryStore(T4Fixtures.T4Statistics(), T4Fixtures.T4Waits());
        t4.Follow(clock);
        var ending = new StrongBox<bool>();
        TimeSpan Cost(string block) => Volatile.Read(ref ending.Value) ? TimeSpan.FromSeconds(4) : TimeSpan.Zero;
        var primary = new CostedConnector(clock, RcaSimulation.T4Primary(clock), block => block is "RCA-PG-13" or "RCA-PG-16" ? t4.ObserverAnswer(block) : null, Cost);
        var replica = new CostedConnector(clock, RcaSimulation.T4Replica(clock), block => block == "RCA-PG-13" ? T4Fixtures.Settings(clock.Now, inRecovery: true) : null, Cost);
        var azure = new CostedConnector(clock, t4.Connector, _ => null, Cost);
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var options = RcaSimulation.Options();
        var runtime = sidecar ? new SidecarRuntime(store, "1.0.0", RunnerLog.Null) : null;
        IReadOnlyList<TargetObserver> observers;
        if (runtime is not null)
        {
            observers = runtime.Postgres(primary, replica, azure, options, RunnerLog.Null);
        }
        else
        {
            var link = new ReplicaLink();
            observers = [new PgPrimaryObserver(primary, options, RunnerLog.Null, link), new PgReplicaObserver(replica, options, RunnerLog.Null, link)];
        }

        var gate = new Gate(DemoTarget.T4);
        var lane = new ObserverLane([observers.Single(o => o.Target == target)], [], gate, store, RunnerLog.Null, clock);
        var own = target == "T4" ? primary : replica;
        var sentinel = target == "T4" ? "RCA-PG-10" : "RCA-PG-06";
        using var stop = new CancellationTokenSource();
        var running = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        DateTimeOffset atEnd;
        try
        {
            gate.Active = true;
            await Until(() => store.Spans().Count == 1 && own.Calls.ToArray().Any(c => c.BlockId == sentinel));
            if (sidecar)
            {
                var rows = Path.Combine(store.Spans().Single().Directory, RcaContract.SidecarRowsFile(target));
                await Until(() => Holds(rows, "\"r\":\"" + RcaContract.QueryCoverage + "\""));
            }

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
        var closed = store.Spans().Single().Span;
        var state = closed.Targets[target];
        var ends = (state.Intervals[^1].To, state.WatermarkUtc, closed.ClosedUtc);
        var span = File.ReadAllText(Path.Combine(store.Spans().Single().Directory, "span.json"));
        clock.Set(RcaSimulation.T4From.AddMinutes(10));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0", runtime is null ? null : () => runtime.Sealer.SealAll());
        var result = exporter.Export(Session, final: true, TimeSpan.Zero);
        var export = result.IndexLine() + string.Concat(result.Documents.SelectMany(d => Enumerable.Range(1, d.Parts).Select(i => "\n" + exporter.Part(d.DocumentId, i))));
        return (span, export, primary.Charged + replica.Charged + azure.Charged, atEnd, afterEnd, ends);
    }

    /// <summary>
    /// One closed span of T1 with Query Store's rows, on a manual clock, exported both ways: the sidecar first, then the
    /// evidence, or the other way round, each for its session. The evidence export as printed and the sidecar's part lines,
    /// with the session each names.
    /// </summary>
    private static (string Evidence, string Sidecar, string? EvidenceSession, string? SidecarSession) BothExports(string storeRoot, bool sidecarFirst, string sidecarSession, string evidenceSession)
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var runtime = new SidecarRuntime(store, "1.0.0", RunnerLog.Null);
        ClosedSpan(store, From, runtime.Sink);
        clock.Set(From.AddMinutes(4));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0", () => runtime.Sealer.SealAll());
        ExportResult evidence;
        SidecarIndexPage sidecar;
        if (sidecarFirst)
        {
            sidecar = SidecarCommands.Export(runtime, sidecarSession, final: true, TimeSpan.Zero, 1);
            evidence = exporter.Export(evidenceSession, final: true, TimeSpan.Zero);
        }
        else
        {
            evidence = exporter.Export(evidenceSession, final: true, TimeSpan.Zero);
            sidecar = SidecarCommands.Export(runtime, sidecarSession, final: true, TimeSpan.Zero, 1);
        }

        var printed = evidence.IndexLine() + string.Concat(evidence.Documents.SelectMany(d => Enumerable.Range(1, d.Parts).Select(i => "\n" + exporter.Part(d.DocumentId, i))));
        var document = JsonNode.Parse(PartCodec.Gunzip(store.ReadDocument(Assert.Single(evidence.Documents).DocumentId)!))!;
        var listed = Assert.Single(sidecar.Documents);
        var lines = SidecarParts.Lines(listed.DocumentId, runtime.Store.ReadGzip(listed.DocumentId)!);
        return (printed, string.Join('\n', lines), document["sessionId"]?.GetValue<string>(), listed.SessionId);
    }

    /// <summary>Whether a span's rows are sealed: none left in its folder, and a sidecar of the span in the ledger, read as its file has it.</summary>
    private static bool Sealed(SidecarRuntime runtime, string spanDirectory)
    {
        try
        {
            return !EvidenceStore.HoldsUnsealedRows(spanDirectory)
                && JsonSerializer.Deserialize(File.ReadAllText(runtime.Store.LedgerPath), SidecarJsonContext.Default.SidecarLedger) is { } ledger
                && ledger.Sidecars.Exists(s => s.SpanId == Path.GetFileName(spanDirectory));
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            return false;
        }
    }

    /// <summary>Whether a file the observer may still be appending to holds <paramref name="text"/>.</summary>
    private static bool Holds(string path, string text)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().Contains(text, StringComparison.Ordinal);
        }
        catch (IOException)
        {
            return false;
        }
    }

    /// <summary>The sidecars' IDs the contract's acknowledgement fixture names.</summary>
    private static List<string> AckFixtureIds()
    {
        var ack = JsonNode.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "fixtures", "rca-ack.json")))!;
        return [.. ack["documents"]!.AsArray().Select(d => d!["documentId"]!.GetValue<string>())];
    }

    /// <summary>The one index line a sidecar export printed, checked against the contract (transport.schema.json, sidecarIndex); its JSON.</summary>
    private static JsonNode Index(string output)
    {
        var line = Assert.Single(output.Split('\n', StringSplitOptions.RemoveEmptyEntries)).TrimEnd('\r');
        Assert.InRange(line.Length, 1, RcaContract.MaximumLineLength);
        Assert.StartsWith(SidecarParts.IndexMarker + " {", line, StringComparison.Ordinal);
        var json = line[(SidecarParts.IndexMarker.Length + 1)..];
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Transport, json));
        return JsonNode.Parse(json)!;
    }

    /// <summary>
    /// T1 observed by the real lane, on a clock only the test, the end's event session drop (3 s), and the Query Store
    /// blocks after it (4 s each) move: begun at 16:50, ticked at 16:52, then out of its session, or its host stopping (the
    /// lane cancelled). Returns its span record, its final export as printed, how many Query Store blocks ran at its end,
    /// the clock when its end began and once the span closed, and T1's interval end, last watermark, and the span's close.
    /// </summary>
    private static async Task<(string Span, string Export, int EndReads, DateTimeOffset ClockAtEnd, DateTimeOffset ClockAfterEnd, (DateTimeOffset?, DateTimeOffset?, DateTimeOffset?) Ends)> RunLaneAsync(string storeRoot, bool sidecar, bool hostStops)
    {
        var clock = new ManualTime(RcaSimulation.T1From);
        var connector = new TimedConnector(clock, RcaSimulation.T1(clock));
        var ending = new StrongBox<bool>();
        var dropped = new StrongBox<bool>();

        // The drop is the evidence's last block at its end, and only Query Store's end reads come after it: a tick's own
        // Query Store read, which may still run once the test begins the end, costs nothing.
        connector.EvidenceCost = (block, _) =>
        {
            if (block != "RCA-XE-05" || !Volatile.Read(ref ending.Value))
            {
                return TimeSpan.Zero;
            }

            Volatile.Write(ref dropped.Value, true);
            return TimeSpan.FromSeconds(3);
        };
        connector.Cost = _ => Volatile.Read(ref dropped.Value) ? TimeSpan.FromSeconds(4) : TimeSpan.Zero;
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
        var closed = store.Spans().Single().Span;
        var t1 = closed.Targets["T1"];
        var ends = (t1.Intervals[^1].To, t1.WatermarkUtc, closed.ClosedUtc);
        var span = File.ReadAllText(Path.Combine(store.Spans().Single().Directory, "span.json"));
        clock.Set(RcaSimulation.T1From.AddMinutes(10));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        var result = exporter.Export(Session, final: true, TimeSpan.Zero);
        var export = result.IndexLine() + string.Concat(result.Documents.SelectMany(d => Enumerable.Range(1, d.Parts).Select(i => "\n" + exporter.Part(d.DocumentId, i))));
        return (span, export, Calls(connector) - before, atEnd, afterEnd, ends);

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

    /// <summary>
    /// A span of T1 with four samples, closed 2 minutes after <paramref name="at"/>; its folder. With
    /// <paramref name="sidecar"/>, a Query Store read's rows too (two queries and the read's coverage), left unsealed.
    /// </summary>
    private static string ClosedSpan(EvidenceStore store, DateTimeOffset at, StoreSidecarSink? sidecar = null)
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

        if (sidecar is not null)
        {
            sidecar.Write(SidecarRig.Stats("T1", at.AddMinutes(-15), 412, 2400));
            sidecar.Write(SidecarRig.Stats("T1", at.AddMinutes(-15), 377, 350));
            sidecar.Write(SidecarRig.Coverage("T1", at.AddMinutes(-15), at.AddMinutes(2)));
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

    /// <summary>One target in a session from long before (T1 unless a test says), until the test takes it out.</summary>
    private sealed class Gate(DemoTarget target = DemoTarget.T1) : IObservationGate
    {
        private volatile bool active;

        public bool Active
        {
            get => active;
            set => active = value;
        }

        public bool IsActive(DemoTarget asked) => active && asked == target;

        public bool IsActiveAfter(DemoTarget target, DateTimeOffset end) => false;

        public bool HoldsAfter(DemoTarget target, DateTimeOffset end) => false;
    }

    /// <summary>
    /// T4's connections for the lane test: the evidence's blocks as <paramref name="evidence"/>'s connection answers them,
    /// at no cost; the sidecar's (RCA-PG-13 to 17) as <paramref name="quiet"/> answers them, or else <paramref name="evidence"/>,
    /// each moving the lane's clock by what <paramref name="cost"/> says once it has answered.
    /// </summary>
    private sealed class CostedConnector(ManualTime clock, ICaptureConnector evidence, Func<string, IReadOnlyList<CaptureValues>?> quiet, Func<string, TimeSpan> cost) : ICaptureConnector
    {
        private int charged;

        public ConcurrentQueue<(DateTimeOffset At, string BlockId)> Calls { get; } = new();

        /// <summary>How many sidecar blocks cost time.</summary>
        public int Charged => Volatile.Read(ref charged);

        public string Description => evidence.Description;

        public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken) => new Connection(this, await evidence.OpenAsync(cancellationToken));

        private static bool IsSidecarBlock(string blockId) => blockId is "RCA-PG-13" or "RCA-PG-14" or "RCA-PG-15" or "RCA-PG-16" or "RCA-PG-17";

        private async Task<IReadOnlyList<CaptureValues>> RunAsync(string blockId, Func<Task<IReadOnlyList<CaptureValues>>> query)
        {
            Calls.Enqueue((clock.Now, blockId));
            var rows = quiet(blockId) ?? await query();
            if (IsSidecarBlock(blockId) && cost(blockId) is var spent && spent > TimeSpan.Zero)
            {
                Interlocked.Increment(ref charged);
                clock.Advance(spent);
            }

            return rows;
        }

        private sealed class Connection(CostedConnector owner, ICaptureConnection inner) : ICaptureConnection
        {
            public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken) =>
                owner.RunAsync(blockId, () => inner.QueryAsync(blockId, text, parameter, timeout, cancellationToken));

            public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken) =>
                owner.RunAsync(blockId, () => inner.QueryAsync(blockId, text, parameters, timeout, cancellationToken));

            public ValueTask DisposeAsync() => inner.DisposeAsync();
        }
    }
}
