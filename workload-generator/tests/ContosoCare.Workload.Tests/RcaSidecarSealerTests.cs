using System.Globalization;
using System.Text.Json;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Sidecar;
using ContosoCare.Workload.Rca.Store;
using Xunit;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The sidecar's sink and sealer (rca/README.md, The sidecar): rows into the open span's files, one sidecar per span with
/// new rows, nothing lost while the observer writes during a seal, the span's session from its export.json (or when it's
/// bound later), T4's backfill into a span whose folder is gone, the budget the reducer gets, and the same bytes for the
/// same rows.
/// </summary>
public sealed class RcaSidecarSealerTests : IDisposable
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 20, 16, 50, 0, TimeSpan.Zero);

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-sidecar-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void TheSinkWritesEachRowToItsTargetsFileInTheOpenSpanAndRefusesAnEvidenceTable()
    {
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1", "T3");

        rig.Sink.Write(SidecarRig.Stats("T1", T0, 412, 2400));
        rig.Sink.Write(SidecarRig.Stats("T1", T0, 377, 350));
        rig.Sink.Write(SidecarRig.Coverage("T3", T0, T0.AddMinutes(15)));
        var evidence = new CaptureRow(RcaContract.Resource, "T1", T0, "RCA-SQL-09").Set("at_utc", T0).Set("target", "T1").Set("metric", "processes_blocked").Set("value", 1.0).Set("unit", "count");

        Assert.Throws<InvalidOperationException>(() => rig.Sink.Write(evidence));
        Assert.Throws<InvalidOperationException>(() => rig.Sink.Write(SidecarRig.Stats("..\\T1", T0, 1, 1)));
        Assert.Equal(2, File.ReadAllLines(SidecarSealer.FileFor(span.Directory, "T1")).Length);
        Assert.Single(File.ReadAllLines(SidecarSealer.FileFor(span.Directory, "T3")));
        Assert.Equal(["sidecar-T1.rows", "sidecar-T3.rows"], Directory.GetFiles(span.Directory, "sidecar-*").Select(Path.GetFileName).Order(StringComparer.Ordinal));
        Assert.Equal(span.Id, rig.Sink.CurrentSpan);

        // No span open: the observer isn't capturing, and the row goes nowhere.
        span.Close(T0.AddMinutes(30));
        rig.Sink.Write(SidecarRig.Stats("T1", T0, 902, 10));
        Assert.Null(rig.Sink.CurrentSpan);
        Assert.Equal(2, File.ReadAllLines(SidecarSealer.FileFor(span.Directory, "T1")).Length);
    }

    [Fact]
    public void ASpanSealsIntoOneSidecarOfItsRowsAndLeavesNoSidecarFileBehind()
    {
        var rig = new SidecarRig(root, T0);
        var span = rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T3", "T1");

        var sealedSidecar = rig.Seal(span);

        var (draft, _) = Assert.Single(rig.Reducer.Calls);
        Assert.Equal(["T1", "T3"], draft.Targets);
        Assert.Equal((T0, T0.AddMinutes(30), true, T0.AddMinutes(31)), (draft.WindowStartUtc, draft.WindowEndUtc, draft.Final, draft.ExportedUtc));
        Assert.Equal((sealedSidecar.DocumentId, SidecarRig.Session, "sqlvm01", 1, "1.0.0"), (draft.DocumentId, draft.SessionId, draft.Host, draft.Sequence, draft.ProducerVersion));
        Assert.Equal(8, draft.Tables[RcaContract.QueryStats].Count);
        Assert.Equal(["T1", "T3"], draft.Tables[RcaContract.QueryCoverage].Select(r => r.Target));
        Assert.Equal([RcaContract.QueryStats, RcaContract.QueryCoverage], draft.Tables.Keys);
        Assert.Empty(Directory.GetFiles(span.Directory, "sidecar-*"));
        Assert.Empty(rig.Store.ReadLedger().Sealed);
        Assert.Null(rig.Sealer.SealSpan(rig.Span(span.Id)));
        Assert.Single(rig.Reducer.Calls);
    }

    [Fact]
    public void RowsTheObserverAppendsDuringASealGoToTheSpansNextSidecar()
    {
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1");
        rig.Sink.Write(SidecarRig.Stats("T1", T0, 412, 2400));
        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(15)));
        rig.Bind(rig.Span(span.Id), SidecarRig.Session);
        rig.Sealer.Rotated = _ =>
        {
            rig.Sink.Write(SidecarRig.Stats("T1", T0.AddMinutes(15), 412, 2300));
            rig.Sink.Write(SidecarRig.Coverage("T1", T0.AddMinutes(15), T0.AddMinutes(30)));
        };

        var first = rig.Seal(rig.Span(span.Id));
        rig.Sealer.Rotated = null;
        Assert.Single(Directory.GetFiles(span.Directory, "sidecar-*"));
        var second = rig.Seal(rig.Span(span.Id));

        Assert.NotEqual(first.DocumentId, second.DocumentId);
        Assert.Equal(
            [(T0, 2400.0), (T0.AddMinutes(15), 2300.0)],
            rig.Reducer.Calls.SelectMany(c => c.Draft.Tables[RcaContract.QueryStats]).Select(r => ((DateTimeOffset)r.Get("interval_start_utc")!, (double)r.Get("cpu_ms")!)));
        Assert.Empty(Directory.GetFiles(span.Directory, "sidecar-*"));
    }

    [Fact]
    public async Task AWriterThatHoldsItsFileWhenTheSealerTakesItAsideFinishesItsRowFirst()
    {
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1");
        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(15)));
        var late = SidecarRig.Stats("T1", T0, 412, 2400);
        using var aside = new ManualResetEventSlim();
        rig.Sealer.Rotated = _ => aside.Set();

        // The observer's append, as the sink makes it: opened before the file was taken aside, written after.
        var writer = new FileStream(SidecarSealer.FileFor(span.Directory, "T1"), FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        var seal = Task.Run(() => rig.Sealer.SealSpan(rig.Span(span.Id)), TestContext.Current.CancellationToken);
        Assert.True(aside.Wait(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken));
        writer.Write(StoredLines.Row(late));
        writer.Dispose();
        Assert.NotNull(await seal);

        var stats = Assert.Single(Assert.Single(rig.Reducer.Calls).Draft.Tables[RcaContract.QueryStats]);
        Assert.Equal(412L, stats.Get("query_id"));
        Assert.Empty(Directory.GetFiles(span.Directory, "sidecar-*"));
    }

    [Fact]
    public void ASidecarTakesTheSessionV1sExportBoundItsSpanToWhateverSessionTheLaterExportsSay()
    {
        // M6: the runbook's rca export binds the span to its session; a scripts' export with --session none after it,
        // and the sidecar's sealing, keep that session.
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1");
        span.Write(new CaptureRow(RcaContract.Resource, "T1", T0, "RCA-SQL-09", sentinel: true).Set("at_utc", T0).Set("target", "T1").Set("source", "RCA-SQL-09").Set("metric", "processes_blocked").Set("value", 0.0).Set("unit", "count"));
        rig.Sink.Write(SidecarRig.Stats("T1", T0, 412, 2400));
        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(30)));
        span.Ended("T1", T0.AddMinutes(30));
        span.Close(T0.AddMinutes(30));
        rig.Clock.Set(T0.AddMinutes(31));
        var exporter = new Exporter(rig.Evidence, RunnerLog.Null, "1.0.0");
        Assert.Single(exporter.Export(SidecarRig.Session, final: true, TimeSpan.Zero).Documents);
        exporter.Export(null, final: true, TimeSpan.Zero);

        var sealedSidecar = Assert.Single(rig.Sealer.SealAll().Sealed);

        Assert.Equal(SidecarRig.Session, sealedSidecar.SessionId);
        Assert.Equal(SidecarRig.Session, Assert.Single(rig.Reducer.Calls).Draft.SessionId);
        var entry = Assert.Single(rig.Store.ReadLedger().Sidecars);
        Assert.Equal((true, SidecarRig.Session), (entry.Bound, entry.Budget));
    }

    [Fact]
    public void ASidecarSealedBeforeItsSpanWasBoundTakesTheSessionWhenItIsByteForByte()
    {
        // At the span's end, before the stop's export binds it, the span is sealed with no session yet; the export's
        // binding then gives its sidecar the session, exactly as if it had been sealed bound.
        var rig = new SidecarRig(root, T0);
        var span = rig.Capture(T0, T0.AddMinutes(30), "T1", "T3");
        var provisional = rig.Seal(span);
        var unbound = Assert.Single(rig.Store.ReadLedger().Sidecars);
        Assert.Equal((false, (string?)null, SidecarSealer.MaximumDocumentBytes - SidecarSealer.ProvisionalMargin), (unbound.Bound, unbound.SessionId, rig.Reducer.Calls[0].Remaining));

        rig.Clock.Set(T0.AddHours(1));
        Assert.Null(rig.Sealer.SealSpan(rig.Bind(span, SidecarRig.Session)));

        var direct = new SidecarRig(Path.Combine(root, "direct"), T0);
        var expected = direct.Seal(direct.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1", "T3"));
        var bound = Assert.Single(rig.Store.Offerable());
        Assert.Equal(expected with { SpanId = provisional.SpanId }, bound);
        Assert.Equal(direct.Store.ReadGzip(expected.DocumentId), rig.Store.ReadGzip(bound.DocumentId));
        Assert.Equal(PartCodec.Sha256(rig.Store.ReadGzip(bound.DocumentId)!), bound.Sha256);
        var budgets = rig.Store.ReadLedger().Budgets;
        Assert.Equal(rig.Store.ReadGzip(bound.DocumentId)!.Length, budgets[SidecarRig.Session].Bytes);
        Assert.Equal(0, budgets["span:" + span.Id].Bytes);
    }

    [Fact]
    public void ASidecarStillUnboundWhenItsOfferedTakesItsSpansBindingOrNone()
    {
        var rig = new SidecarRig(root, T0);
        var gone = rig.Capture(T0, T0.AddMinutes(30), "T1");
        var bound = rig.Capture(T0.AddHours(1), T0.AddHours(2), "T1");
        rig.Sealer.SealAll();
        Directory.Delete(gone.Directory, recursive: true);
        rig.Bind(bound, SidecarRig.Session);

        var offered = rig.Store.Offerable();

        Assert.Equal([null, SidecarRig.Session], offered.Select(s => s.SessionId));
        Assert.All(rig.Store.ReadLedger().Sidecars, s => Assert.True(s.Bound));

        // Its bytes are final once offered: a later binding doesn't change them.
        var before = offered.Select(s => s.Sha256).ToList();
        rig.Sealer.SealAll();
        Assert.Equal(before, rig.Store.Offerable().Select(s => s.Sha256));
    }

    [Fact]
    public void ForSpanGivesTheOpenSpanItsOwnSinkAnEarlierSpanItsFolderAndAGoneSpanASealNowOrNone()
    {
        var rig = new SidecarRig(root, T0);
        var earlier = rig.Capture(T0, T0.AddMinutes(30), "T4");
        rig.Sealer.SealAll();
        var gone = rig.Bind(rig.Capture(T0.AddHours(1), T0.AddHours(2), "T4"), SidecarRig.Session);
        rig.Sealer.SealAll();
        Directory.Delete(gone.Directory, recursive: true);
        var open = rig.Open(T0.AddDays(8), "T4");

        Assert.Same(rig.Sink, rig.Sink.ForSpan(open.Id));
        Assert.Null(rig.Sink.ForSpan("20991231T000000Z"));
        Assert.Null(rig.Sink.ForSpan("..\\sidecars"));

        rig.Sink.ForSpan(earlier.Id)!.Write(SidecarRig.Stats("T4", T0.AddMinutes(30), 7, 1));
        Assert.Single(File.ReadAllLines(SidecarSealer.FileFor(earlier.Directory, "T4")));

        var backfill = rig.Sink.ForSpan(gone.Id)!;
        var calls = rig.Reducer.Calls.Count;
        backfill.Write(SidecarRig.Stats("T4", T0.AddHours(1).AddMinutes(45), 7, 5));
        Assert.Equal(calls, rig.Reducer.Calls.Count);
        backfill.Write(SidecarRig.Coverage("T4", T0.AddHours(1).AddMinutes(45), T0.AddHours(2), "RCA-PG-13,RCA-PG-14", backfill: true));

        var (draft, _) = rig.Reducer.Calls[^1];
        Assert.Equal((SidecarRig.Session, true), (draft.SessionId, draft.Final));
        Assert.Equal([7L], draft.Tables[RcaContract.QueryStats].Select(r => r.Get("query_id")));
        Assert.Equal(true, Assert.Single(draft.Tables[RcaContract.QueryCoverage]).Get("backfill"));
        var entry = rig.Store.ReadLedger().Sidecars[^1];
        Assert.Equal((gone.Id, SidecarRig.Session, true, true), (entry.SpanId, entry.SessionId, entry.Bound, entry.Backfill));
    }

    [Fact]
    public async Task T4sBackfillPastItsSpansRetentionWritesTheExpiredRangeIntoTheSpansSidecar()
    {
        // The coordinator's item 3 (A2's review): a span is in the ledger from its first sidecar row, so 8 days later,
        // with its folder gone, T4's backfill still has a sink for it and writes its range as expired, instead of the
        // range being forgotten with "pending publication" left forever.
        var rig = new SidecarRig(root, T0);
        var queryStore = new ScriptedConnector((_, _) => []) { ParameterAnswer = (_, _) => [] };
        var source = new PgQueryStoreSource(queryStore, new QueryWatermark(root, "T4"), rig.Sink);
        PgQueryStoreCapture.BlockRunner observer = (block, _) => Task.FromResult<IReadOnlyList<CaptureValues>?>(block switch
        {
            "RCA-PG-13" => T4Settings(rig.Clock.Now),
            "RCA-PG-16" => [Row(("captured_at", null), ("kind", "function"), ("name", "fn_harness_event"))],
            _ => null,
        });

        var first = rig.Open(T0, "T4");
        var capture = new PgQueryStoreCapture("T4", source, rig.Sink, RcaSimulation.Options(), RunnerLog.Null);
        capture.Begin(T0);
        await capture.ReadAsync(T0, observer, TestContext.Current.CancellationToken);
        rig.Clock.Set(T0.AddMinutes(20));
        await capture.EndAsync(T0.AddMinutes(20), observer, TestContext.Current.CancellationToken);
        first.Close(T0.AddMinutes(20));
        Assert.Equal(first.Id, Assert.Single(source.Watermark.Read().Pending).SpanId);
        Assert.True(rig.Store.ReadLedger().Spans.ContainsKey(first.Id));
        Directory.Delete(first.Directory, recursive: true);

        var later = T0.AddDays(8);
        rig.Open(later, "T4");
        var next = new PgQueryStoreCapture("T4", source, rig.Sink, RcaSimulation.Options(), RunnerLog.Null);
        next.Begin(later);
        await next.ReadAsync(later, observer, TestContext.Current.CancellationToken);

        Assert.DoesNotContain(source.Watermark.Read().Pending, p => p.SpanId == first.Id);
        var entry = Assert.Single(rig.Store.ReadLedger().Sidecars);
        Assert.Equal((first.Id, true), (entry.SpanId, entry.Backfill));
        var coverage = Assert.Single(Assert.Single(rig.Reducer.Calls).Draft.Tables[RcaContract.QueryCoverage]);
        Assert.Equal(true, coverage.Get("backfill"));
        Assert.Contains("Pending publication expired", (string?)coverage.Get("gaps"), StringComparison.Ordinal);
    }

    [Fact]
    public void TheReducerGetsWhatsLeftOfTheHostsSessionBudget()
    {
        var rig = new SidecarRig(root, T0);
        var first = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1", "T3", "T5"));
        rig.Seal(rig.Observe(T0.AddHours(1), T0.AddHours(2), SidecarRig.Session, "T1", "T3"));
        rig.Seal(rig.Observe(T0.AddHours(3), T0.AddHours(4), null, "T2", "T5"));
        rig.Seal(rig.Capture(T0.AddHours(5), T0.AddHours(6), "T2"));

        var firstBytes = rig.Store.ReadGzip(first.DocumentId)!.Length;
        Assert.Equal(
            [64 * 1024, (64 * 1024) - firstBytes, 32 * 1024, (32 * 1024) - SidecarSealer.ProvisionalMargin],
            rig.Reducer.Calls.Select(c => c.Remaining));
    }

    [Fact]
    public void TheSameRowsSealToTheSameBytes()
    {
        var one = new SidecarRig(Path.Combine(root, "one"), T0);
        var two = new SidecarRig(Path.Combine(root, "two"), T0);

        var a = one.Seal(one.Observe(T0, T0.AddMinutes(45), SidecarRig.Session, "T4", "T1", "T3"));
        var b = two.Seal(two.Observe(T0, T0.AddMinutes(45), SidecarRig.Session, "T4", "T1", "T3"));

        Assert.Equal(a with { SpanId = string.Empty }, b with { SpanId = string.Empty });
        Assert.Equal(one.Store.ReadGzip(a.DocumentId), two.Store.ReadGzip(b.DocumentId));
    }

    [Fact]
    public void PastTheStoresCapForATargetOnlyItsCoverageRowsGoOnAndSaySo()
    {
        var rig = new SidecarRig(root, T0, targetCap: 4096);
        var span = rig.Open(T0, "T1");
        for (var query = 1; query <= 40; query++)
        {
            rig.Sink.Write(SidecarRig.Stats("T1", T0, query, query));
        }

        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(15)));

        var lines = File.ReadAllLines(SidecarSealer.FileFor(span.Directory, "T1"));
        Assert.InRange(lines.Length, 2, 40);
        Assert.Contains(RcaContract.QueryCoverage, lines[^1], StringComparison.Ordinal);
        Assert.Contains("only its coverage rows were kept after that", lines[^1], StringComparison.Ordinal);
    }

    [Fact]
    public void ABindThatASealingFailureFollowsIsRecordedWithTheFilesHashAndSession()
    {
        // Review, High 1: a bind writes the document again before the rest of its sealing can fail; the ledger must record
        // it, or the sidecar is offered under a hash its file no longer has, and every save rejects it.
        var rig = new SidecarRig(root, T0);
        var span = rig.Capture(T0, T0.AddMinutes(30), "T1");
        var provisional = rig.Seal(span);
        rig.Sink.ForSpan(span.Id)!.Write(SidecarRig.Stats("T1", T0.AddMinutes(30), 902, 10));
        rig.Bind(rig.Span(span.Id), SidecarRig.Session);
        rig.Sealer.Rotated = _ => throw new InvalidOperationException("The test's failure after the bind.");

        Assert.Throws<InvalidOperationException>(() => rig.Sealer.SealSpan(rig.Span(span.Id)));

        var file = rig.Store.ReadGzip(provisional.DocumentId)!;
        var recorded = Assert.Single(ReadLedgerFile().Sidecars);
        Assert.Equal((PartCodec.Sha256(file), (string?)SidecarRig.Session, true), (recorded.Sha256, recorded.SessionId, recorded.Bound));
        rig.Sealer.Rotated = null;
        var offered = Assert.Single(rig.Store.Offerable());
        Assert.Equal((PartCodec.Sha256(file), (string?)SidecarRig.Session), (offered.Sha256, offered.SessionId));
    }

    [Fact]
    public void ABindTheLedgerNeverRecordedIsTakenFromTheFile()
    {
        // Review, High 1: a crash between a bind's document and its ledger leaves the file bound and the ledger not; the
        // next bind takes the hash, size, and parts from the file, and moves the budget.
        var rig = new SidecarRig(root, T0);
        var span = rig.Capture(T0, T0.AddMinutes(30), "T1");
        var provisional = rig.Seal(span);
        var ledgerPath = Path.Combine(root, "sidecars", "ledger.json");
        var before = File.ReadAllBytes(ledgerPath);
        Assert.Null(rig.Sealer.SealSpan(rig.Bind(span, SidecarRig.Session)));
        File.WriteAllBytes(ledgerPath, before);

        var offered = Assert.Single(rig.Store.Offerable());

        var file = rig.Store.ReadGzip(provisional.DocumentId)!;
        Assert.NotEqual(provisional.Sha256, offered.Sha256);
        Assert.Equal((PartCodec.Sha256(file), PartCodec.PartCount(file.Length), (string?)SidecarRig.Session), (offered.Sha256, offered.Parts, offered.SessionId));
        var budgets = ReadLedgerFile().Budgets;
        Assert.Equal((long)file.Length, budgets[SidecarRig.Session].Bytes);
        Assert.Equal(0, budgets["span:" + span.Id].Bytes);
    }

    [Fact]
    public void ABindTheLedgerNeverRecordedIsTakenFromTheFileOnceItsSpansFolderIsGone()
    {
        // Re-check, Low: the crash above, then v1's retention deletes the span's folder, its export.json with it, before
        // anything seals again. The file's session is all that's left of the span's binding: the sidecar and its span take
        // it with the file's hash, and the sidecar isn't offered with no session under a hash its file no longer has.
        var rig = new SidecarRig(root, T0);
        var span = rig.Capture(T0, T0.AddMinutes(30), "T1");
        var provisional = rig.Seal(span);
        var ledgerPath = Path.Combine(root, "sidecars", "ledger.json");
        var before = File.ReadAllBytes(ledgerPath);
        Assert.Null(rig.Sealer.SealSpan(rig.Bind(span, SidecarRig.Session)));
        File.WriteAllBytes(ledgerPath, before);
        Directory.Delete(span.Directory, recursive: true);

        var offered = Assert.Single(rig.Store.Offerable());

        var file = rig.Store.ReadGzip(provisional.DocumentId)!;
        Assert.Equal((PartCodec.Sha256(file), PartCodec.PartCount(file.Length), (string?)SidecarRig.Session), (offered.Sha256, offered.Parts, offered.SessionId));
        var ledger = ReadLedgerFile();
        Assert.Equal((long)file.Length, ledger.Budgets[SidecarRig.Session].Bytes);
        Assert.Equal(0, ledger.Budgets["span:" + span.Id].Bytes);
        Assert.Equal((true, (string?)SidecarRig.Session), (ledger.Spans[span.Id].Bound, ledger.Spans[span.Id].SessionId));
    }

    [Fact]
    public void ABindCutShortBetweenASpansDocumentsGivesThemAllItsSessionOnceTheSpansFolderIsGone()
    {
        // Re-check, Low: the crash comes between two of the span's documents, so the first names the session and the second
        // doesn't. With the span's folder gone, the first one's session is the span's binding: the second takes it too,
        // written as the bind would have written it, and the span keeps it for a backfill.
        var rig = new SidecarRig(root, T0);
        var span = rig.Capture(T0, T0.AddMinutes(30), "T1");
        var first = rig.Seal(span);
        rig.Sink.ForSpan(span.Id)!.Write(SidecarRig.Stats("T1", T0.AddMinutes(30), 902, 10));
        var second = rig.Seal(rig.Span(span.Id));
        var ledgerPath = Path.Combine(root, "sidecars", "ledger.json");
        var secondPath = rig.Store.DocumentPath(second.DocumentId)!;
        var before = File.ReadAllBytes(ledgerPath);
        var secondUnbound = File.ReadAllBytes(secondPath);
        Assert.Null(rig.Sealer.SealSpan(rig.Bind(rig.Span(span.Id), SidecarRig.Session)));
        var secondBound = File.ReadAllBytes(secondPath);
        Assert.NotEqual(secondUnbound, secondBound);
        File.WriteAllBytes(ledgerPath, before);
        File.WriteAllBytes(secondPath, secondUnbound);
        Directory.Delete(span.Directory, recursive: true);

        var offered = rig.Store.Offerable().ToDictionary(s => s.DocumentId, StringComparer.Ordinal);

        Assert.Equal([SidecarRig.Session, SidecarRig.Session], new[] { first, second }.Select(s => offered[s.DocumentId].SessionId));
        Assert.Equal(secondBound, rig.Store.ReadGzip(second.DocumentId));
        Assert.All(offered.Values, s => Assert.Equal(PartCodec.Sha256(rig.Store.ReadGzip(s.DocumentId)!), s.Sha256));
        var ledger = ReadLedgerFile();
        Assert.Equal(offered.Values.Sum(s => (long)rig.Store.ReadGzip(s.DocumentId)!.Length), ledger.Budgets[SidecarRig.Session].Bytes);
        Assert.Equal((true, (string?)SidecarRig.Session), (ledger.Spans[span.Id].Bound, ledger.Spans[span.Id].SessionId));
    }

    [Fact]
    public void AGoneSpansDocumentThatCantBeReadIsSettledWithNoSessionAndStopsNoOtherSidecar()
    {
        // Re-check, Low: looking for a session in a gone span's documents never fails the listing: a document that can't
        // be read names none, so its sidecar is settled with no session, as before, and the others are offered.
        var rig = new SidecarRig(root, T0);
        var gone = rig.Capture(T0, T0.AddMinutes(30), "T1");
        var bound = rig.Capture(T0.AddHours(1), T0.AddHours(2), "T1");
        rig.Sealer.SealAll();
        var broken = rig.Store.ReadLedger().Sidecars.Single(s => string.Equals(s.SpanId, gone.Id, StringComparison.Ordinal));
        File.WriteAllBytes(rig.Store.DocumentPath(broken.DocumentId)!, "not a gzip"u8.ToArray());
        Directory.Delete(gone.Directory, recursive: true);
        rig.Bind(bound, SidecarRig.Session);

        var offered = rig.Store.Offerable();

        Assert.Equal([null, SidecarRig.Session], offered.Select(s => s.SessionId));
    }

    [Fact]
    public void RowsSealedBeforeACrashThatKeptThemAreDeletedAndNeverSealedTwice()
    {
        // Review, Medium 3: a crash after the ledger's write and before the rows' deletion leaves the files the ledger lists
        // as sealed; the next sealing deletes them before it reads anything. Without DeleteSealed they'd be sealed again.
        var rig = new SidecarRig(root, T0);
        var span = rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1");
        var aside = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        rig.Sealer.Rotated = s =>
        {
            foreach (var file in Directory.GetFiles(s.Directory, "sidecar-*"))
            {
                aside[file] = File.ReadAllBytes(file);
            }
        };
        var sealedSidecar = rig.Seal(span);
        rig.Sealer.Rotated = null;
        Assert.NotEmpty(aside);
        using (rig.Store.Lock())
        {
            var ledger = rig.Store.ReadLedger();
            foreach (var (file, bytes) in aside)
            {
                File.WriteAllBytes(file, bytes);
                ledger.Sealed.Add(Path.GetRelativePath(rig.Evidence.Root, file));
            }

            rig.Store.WriteLedger(ledger);
        }

        Assert.Null(rig.Sealer.SealSpan(rig.Span(span.Id)));

        Assert.Single(rig.Reducer.Calls);
        Assert.Empty(Directory.GetFiles(span.Directory, "sidecar-*"));
        Assert.Empty(ReadLedgerFile().Sealed);
        Assert.Equal(sealedSidecar.DocumentId, Assert.Single(rig.Store.Offerable()).DocumentId);
    }

    [Fact]
    public void RowsSetAsideByAnInterruptedSealingAreSealedByTheNextWithTheRowsAfterThem()
    {
        // Review, Medium 3: a sealing that fails after it took the files aside leaves them; the next takes them first, then
        // what the observer wrote since, into one sidecar, and leaves no file behind.
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1");
        rig.Sink.Write(SidecarRig.Stats("T1", T0, 412, 2400));
        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(15)));
        rig.Bind(rig.Span(span.Id), SidecarRig.Session);
        rig.Sealer.Rotated = _ => throw new IOException("The test's failure after the files were taken aside.");
        Assert.Throws<IOException>(() => rig.Sealer.SealSpan(rig.Span(span.Id)));
        rig.Sealer.Rotated = null;
        Assert.Single(Directory.GetFiles(span.Directory, "sidecar-T1.*.rows"));
        rig.Sink.Write(SidecarRig.Stats("T1", T0.AddMinutes(15), 412, 2300));
        rig.Sink.Write(SidecarRig.Coverage("T1", T0.AddMinutes(15), T0.AddMinutes(30)));

        rig.Seal(rig.Span(span.Id));

        var draft = Assert.Single(rig.Reducer.Calls).Draft;
        Assert.Equal([2400.0, 2300.0], draft.Tables[RcaContract.QueryStats].Select(r => (double)r.Get("cpu_ms")!));
        Assert.Equal((T0, T0.AddMinutes(30)), (draft.WindowStartUtc, draft.WindowEndUtc));
        Assert.Empty(Directory.GetFiles(span.Directory, "sidecar-*"));
    }

    [Fact]
    public void ABindThatTakesTheSessionOverItsHostsBudgetSaysSoInTheSidecarsCoverageWithoutCuttingIt()
    {
        // Review, Medium 4 (a soft cap at bind): two spans sealed before the session's first export, then bound to it; the
        // second takes the session past this host's budget. It isn't cut again: its coverage says by how much, and the log
        // warns. The transport pages and keeps pending whatever doesn't fit.
        var budget = int.MaxValue;
        using var logText = new StringWriter(CultureInfo.InvariantCulture);
        using var log = new RunnerLog(logText);
        var rig = new SidecarRig(root, T0, budget: _ => budget, log: log);
        var first = rig.Capture(T0, T0.AddMinutes(30), "T2");
        var second = rig.Capture(T0.AddHours(1), T0.AddHours(2), "T2");
        rig.Sealer.SealAll();
        var provisional = ReadLedgerFile().Sidecars.ToDictionary(s => s.SpanId, s => s.Bytes);
        budget = (int)(provisional[first.Id] + (provisional[second.Id] / 2));

        rig.Bind(first, SidecarRig.Session);
        rig.Bind(second, SidecarRig.Session);
        rig.Sealer.SealAll();

        var ledger = ReadLedgerFile();
        var entries = ledger.Sidecars.ToDictionary(s => s.SpanId);
        var used = ledger.Budgets[SidecarRig.Session].Bytes;
        Assert.Equal(entries.Values.Sum(e => e.Bytes), used);
        Assert.True(used > budget);
        Assert.All(CapturingReducer.CoverageGaps(rig.Store.ReadGzip(entries[first.Id].DocumentId)!), g => Assert.Null(g.Gaps));
        var secondFile = rig.Store.ReadGzip(entries[second.Id].DocumentId)!;
        Assert.Equal(PartCodec.Sha256(secondFile), entries[second.Id].Sha256);
        Assert.All(CapturingReducer.CoverageGaps(secondFile), g => Assert.Equal(SidecarStore.OverBudgetLine(used - budget), g.Gaps));
        var sealedDraft = rig.Reducer.Calls.Single(c => c.Draft.WindowStartUtc == T0.AddHours(1)).Draft;
        Assert.Equal(sealedDraft.Tables[RcaContract.QueryStats].Count, CapturingReducer.Rows(secondFile, RcaContract.QueryStats));
        Assert.Contains("rca.sidecar-over-budget", logText.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void ASealedListNamingAnythingButAFileTakenAsideDeletesNothing()
    {
        // Review, Low 5: the ledger's list of sealed files can make the sealer delete only a file taken aside to be sealed.
        var rig = new SidecarRig(root, T0);
        var span = rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1");
        var export = Path.Combine(span.Directory, "export.json");
        var live = SidecarSealer.FileFor(span.Directory, "T1");
        using (rig.Store.Lock())
        {
            var ledger = rig.Store.ReadLedger();
            ledger.Sealed.Add(Path.GetRelativePath(rig.Evidence.Root, export));
            ledger.Sealed.Add(Path.GetRelativePath(rig.Evidence.Root, live));
            rig.Store.WriteLedger(ledger);
        }

        rig.Seal(rig.Span(span.Id));

        Assert.True(File.Exists(export));
        Assert.Equal(4, Assert.Single(rig.Reducer.Calls).Draft.Tables[RcaContract.QueryStats].Count);
        Assert.Empty(ReadLedgerFile().Sealed);
    }

    [Fact]
    public void SealingRecordsOnlySpansThatHaveSidecarRows()
    {
        var rig = new SidecarRig(root, T0);
        var evidenceOnly = rig.Open(T0, "T2");
        evidenceOnly.Write(new CaptureRow(RcaContract.Resource, "T2", T0, "RCA-SQL-09", sentinel: true).Set("at_utc", T0).Set("target", "T2").Set("source", "RCA-SQL-09").Set("metric", "processes_blocked").Set("value", 0.0).Set("unit", "count"));
        evidenceOnly.Close(T0.AddMinutes(10));
        var withRows = rig.Capture(T0.AddHours(1), T0.AddHours(2), "T2");

        rig.Sealer.SealAll();

        Assert.Equal([withRows.Id], rig.Store.ReadLedger().Spans.Keys);
    }

    [Fact]
    public void ABackfillsRowsTakeTheStoresTypesAsASpansRowsDo()
    {
        // A span's rows reach the reducer through the store's lines; a backfill's go there too, so the same rows seal to
        // the same bytes by either path: a decimal is a double, and an int a long, as the lines read them back.
        var rig = new SidecarRig(root, T0);
        var gone = rig.Bind(rig.Capture(T0, T0.AddMinutes(30), "T4"), SidecarRig.Session);
        rig.Sealer.SealAll();
        Directory.Delete(gone.Directory, recursive: true);
        rig.Open(T0.AddDays(8), "T4");
        var backfill = rig.Sink.ForSpan(gone.Id)!;

        backfill.Write(SidecarRig.Stats("T4", T0.AddMinutes(30), 7, 5).Set("logical_reads", 1250.5m));
        backfill.Write(SidecarRig.Coverage("T4", T0.AddMinutes(30), T0.AddMinutes(45), "RCA-PG-14", backfill: true));

        var draft = rig.Reducer.Calls[^1].Draft;
        Assert.IsType<double>(Assert.Single(draft.Tables[RcaContract.QueryStats]).Get("logical_reads"));
        Assert.IsType<long>(Assert.Single(draft.Tables[RcaContract.QueryCoverage]).Get("interval_minutes"));
    }

    [Fact]
    public void ATargetWithRowsAndNoQueryStoreReadIsLeftForTheReducersCoverageRow()
    {
        // T1c's reducer adds the row that says no read is recorded: the sealer adds none, so there's never a second one.
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1", "T4");
        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(15)));
        rig.Sink.Write(new CaptureRow(RcaContract.Connections, "T4", T0.AddMinutes(16), "RCA-PG-17").Set("captured_at_utc", T0.AddMinutes(16)).Set("target", "T4").Set("state", "idle").Set("connections", 40L).Set("is_demo", true));
        rig.Sink.Write(new CaptureRow(RcaContract.Connections, "T4", T0.AddMinutes(17), "RCA-PG-17").Set("captured_at_utc", T0.AddMinutes(17)).Set("target", "T4").Set("state", "idle").Set("connections", 41L).Set("is_demo", true));
        span.Close(T0.AddMinutes(20));

        rig.Seal(rig.Bind(rig.Span(span.Id), SidecarRig.Session));

        var draft = Assert.Single(rig.Reducer.Calls).Draft;
        Assert.Equal(["T1", "T4"], draft.Targets);
        Assert.Equal(["T1"], draft.Tables[RcaContract.QueryCoverage].Select(r => r.Target));
        Assert.Equal(2, draft.Tables[RcaContract.Connections].Count);
        Assert.Equal((T0, T0.AddMinutes(17).AddMilliseconds(1)), (draft.WindowStartUtc, draft.WindowEndUtc));
    }

    [Fact]
    public void SealAllReturnsTheIdsThisCallSealedAndNoEarlierOnes()
    {
        // The page index lists a sidecar this call sealed as new, and every other offerable one as pending.
        var rig = new SidecarRig(root, T0);
        rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1");
        var first = rig.Sealer.SealAll();
        rig.Observe(T0.AddHours(1), T0.AddHours(2), SidecarRig.Session, "T1");

        var second = rig.Sealer.SealAll();

        Assert.Equal([Assert.Single(first.Sealed).DocumentId], first.SealedIds);
        Assert.Equal([Assert.Single(second.Sealed).DocumentId], second.SealedIds);
        Assert.Equal(first.SealedIds.Concat(second.SealedIds), rig.Store.Offerable().Select(s => s.DocumentId));
    }

    /// <summary>The ledger as the file has it, read without the store, so nothing a read does can change what's checked.</summary>
    private SidecarLedger ReadLedgerFile() => JsonSerializer.Deserialize(File.ReadAllText(Path.Combine(root, "sidecars", "ledger.json")), SidecarJsonContext.Default.SidecarLedger)!;

    private static List<CaptureValues> T4Settings(DateTimeOffset now) =>
    [
        Row(("captured_at", now.UtcDateTime), ("in_recovery", false), ("name", "pg_qs.interval_length_minutes"), ("setting", "15"), ("unit", "min")),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", false), ("name", "pg_qs.query_capture_mode"), ("setting", "all"), ("unit", null)),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", false), ("name", "pg_qs.retention_period_in_days"), ("setting", "7"), ("unit", null)),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", false), ("name", "pg_qs.store_query_plans"), ("setting", "off"), ("unit", null)),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", false), ("name", "pgms_wait_sampling.history_period"), ("setting", "100"), ("unit", "ms")),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", false), ("name", "pgms_wait_sampling.query_capture_mode"), ("setting", "all"), ("unit", null)),
    ];
}
