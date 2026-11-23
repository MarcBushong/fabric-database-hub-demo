using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Store;
using Xunit;
using static ContosoCare.Workload.Tests.RcaTestKit;
using static ContosoCare.Workload.Tests.T4Fixtures;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// T4's sidecar (rca/README.md, The sidecar): Query Store's reads (RCA-PG-13 to 16), the unread-interval watermark and its
/// backfill, and who holds T4's connections (RCA-PG-17). azure_sys and pg_qs exist only on Azure, so a scripted Query
/// Store answers the blocks from the contract's fixtures; the leave-out rules are checked by evaluating the blocks' own
/// patterns, the harness's against database/postgresql's real sources; and what the observer's connections send is read
/// from a listener that speaks PostgreSQL's protocol.
/// </summary>
public sealed partial class RcaQueryStorePgTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-querystore-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    // ---- Query Store's reads -----------------------------------------------------------------------------------------

    [Fact]
    public async Task T4sQueryStoreReadsRoundTripTheFixture()
    {
        var fixture = new SidecarFixture("t4-query-store.sidecar.json");
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var (capture, sidecar, _) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 2, 5610));
        await ReadAtAsync(capture, store, At(17, 17, 5700));
        store.Clock = At(17, 20);
        await capture.EndAsync(store.Clock, TestContext.Current.CancellationToken);

        AssertSameRows(fixture.Table(RcaContract.QueryStats), sidecar.Table(RcaContract.QueryStats), "interval_start_utc", "query_id", "login_name");
        AssertSameRows(fixture.Table(RcaContract.QueryWaits), sidecar.Table(RcaContract.QueryWaits), "interval_start_utc", "query_id", "wait_category", "wait_event");

        // One coverage row a read; the export merges them per sidecar, which gives the fixture's row but for its window.
        var merged = Merge(sidecar.Table(RcaContract.QueryCoverage).Where(r => r.Target == "T4").ToList());
        var expected = fixture.Table(RcaContract.QueryCoverage).Single(r => (string?)r["target"] == "T4");
        foreach (var column in new[] { "state", "capture_mode", "interval_minutes", "read_from_utc", "read_to_utc", "pending_from_utc", "pending_to_utc", "backfill", "sources", "gaps" })
        {
            Assert.Equal(expected[column], merged[column]);
        }

        Assert.Equal(3, sidecar.Table(RcaContract.QueryCoverage).Count);
        Assert.Empty(sidecar.Table(RcaContract.QueryEvents));
    }

    [Fact]
    public async Task EachReadTakesTheUnsettledIntervalsOnAzureSysWithTheHarnessAndTheObserversStatements()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var (capture, _, _) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 2, 5610));
        await ReadAtAsync(capture, store, At(17, 17, 5700));

        // RCA-PG-13 and 16 quietly on the observer's own connection; RCA-PG-14 and 15 on azure_sys, with every parameter,
        // each on a connection of its own, opened and closed in its tick.
        Assert.Equal(["RCA-PG-13", "RCA-PG-16", "RCA-PG-13", "RCA-PG-16"], store.Access.Calls.Select(c => c.BlockId));
        Assert.All(store.Access.Calls, c => Assert.Equal(TimeSpan.FromSeconds(5), c.Timeout));
        Assert.Equal(["RCA-PG-14", "RCA-PG-15", "RCA-PG-14", "RCA-PG-15"], store.Connector.ParameterCalls.Select(c => c.BlockId));
        Assert.Equal(4, store.Connector.Opens);
        Assert.All(store.Connector.Calls, c => Assert.Equal(CaptureCatalog.Get(c.BlockId), c.Text));
        var first = store.Connector.ParameterCalls[0].Parameters;
        Assert.Equal(7, first.Count);
        Assert.Equal("contosocare", first[0].Value);
        Assert.Equal(At(17, 2, 5610).AddHours(-2), first[1].Value);
        Assert.Equal(["fn\\$harness_begin", "fn_harness_event"], (string[])first[2].Value!);
        Assert.Equal(["harness_runs"], (string[])first[3].Value!);
        Assert.Equal(["patients", "work_queues"], (string[])first[4].Value!);
        Assert.Equal(At(17, 2, 5610), first[5].Value);
        Assert.Equal(PgObserverStatements.All, (string[])first[6].Value!);
        var waits = store.Connector.ParameterCalls[1].Parameters;
        Assert.Equal(At(17, 2, 5610).AddHours(-2), waits[1].Value);
        Assert.Equal([Update, SizeCheck, Marks], (long[])waits[2].Value!);
        Assert.Equal(At(17, 2, 5610), waits[3].Value);

        // The second read starts where the first found every interval surely published, 20 minutes before it: the 16:45
        // interval, read 2 minutes after it ended, is read again.
        Assert.Equal(At(16, 42, 5610), store.Connector.ParameterCalls[2].Parameters[1].Value);
        Assert.Equal(At(17, 15), capture.Through);
        Assert.Equal(At(16, 57, 5700), capture.Settled);
        Assert.Equal(At(17, 32), capture.NextRead);
    }

    [Fact]
    public async Task CountsAndWaitsQueryStorePublishesLateAreReadOnceItDoes()
    {
        // Query Store shows each interval's statistics as soon as it ends, and its waits only 10 minutes later.
        var fixture = new SidecarFixture("t4-query-store.sidecar.json");
        var store = new T4QueryStore(T4Statistics(), T4Waits()) { WaitsPublishedAfter = TimeSpan.FromMinutes(10) };
        var (capture, sidecar, _) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 2, 5610));
        Assert.Empty(sidecar.Table(RcaContract.QueryWaits));
        await ReadAtAsync(capture, store, At(17, 17, 5700));
        await ReadAtAsync(capture, store, At(17, 32));

        // Every wait reached the sidecar, and each interval's latest statistics hold them, as the fixture's do.
        AssertSameRows(fixture.Table(RcaContract.QueryWaits), sidecar.Table(RcaContract.QueryWaits), ["captured_at_utc"], "interval_start_utc", "query_id", "wait_category", "wait_event");
        var latest = sidecar.Table(RcaContract.QueryStats)
            .GroupBy(r => ((DateTimeOffset)r.Get("interval_start_utc")!, (long)r.Get("query_id")!, (string?)r.Get("login_name")))
            .Select(g => g.OrderBy(r => (DateTimeOffset)r.Get("captured_at_utc")!).Last())
            .ToList();
        AssertSameRows(fixture.Table(RcaContract.QueryStats), latest, ["captured_at_utc"], "interval_start_utc", "query_id", "login_name");

        // A row is written again only when a later read found it changed: the size check, with no waits, once an interval;
        // the chain's UPDATE at 17:00 twice, before its waits were published and after.
        Assert.Equal(2, sidecar.Table(RcaContract.QueryStats).Count(r => (long)r.Get("query_id")! == SizeCheck));
        Assert.Equal(2, sidecar.Table(RcaContract.QueryStats).Count(r => (long)r.Get("query_id")! == Update && (DateTimeOffset)r.Get("interval_start_utc")! == At(17, 0)));
        Assert.Equal(At(17, 12), capture.Settled);
    }

    [Fact]
    public async Task WithNoFunctionMarkedTheReadLeavesOutNothingAsTheHarnessAndSaysSo()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits()) { Harness = [Row(("kind", "table"), ("name", "work_queues"))] };
        var (capture, sidecar, _) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 17, 5700));

        var parameters = store.Connector.ParameterCalls[0].Parameters;
        Assert.Empty((string[])parameters[2].Value!);
        Assert.Empty((string[])parameters[3].Value!);
        Assert.Contains("No function in contosocare is marked as the harness's (dbhubdemo:harness), so nothing is left out as the harness's.", Gaps(sidecar));
        Assert.Equal(7, sidecar.Table(RcaContract.QueryStats).Count);
    }

    [Fact]
    public async Task WithoutTheHarnessListNothingIsReadAndTheTimeStaysPending()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits()) { HarnessFails = true };
        var (capture, sidecar, watermark) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 2, 5610));
        store.Clock = At(17, 20);
        await capture.EndAsync(store.Clock, TestContext.Current.CancellationToken);

        Assert.Empty(store.Connector.Calls);
        Assert.Empty(sidecar.Table(RcaContract.QueryStats));
        Assert.Contains("RCA-PG-16 couldn't be read on T4, so Query Store's statements weren't read: without the harness's functions, its bookkeeping would be among them. The next read tries again: PostgreSQL error XX000: RCA-PG-16 failed (a test's failure).", Gaps(sidecar));
        var pending = Assert.Single(watermark.Read().Pending);
        Assert.Equal((SpanA, At(17, 2, 5610).AddHours(-2), At(17, 20)), (pending.SpanId, pending.FromUtc, pending.ToUtc!.Value));
    }

    [Fact]
    public async Task WaitsThatFailKeepTheNextReadOnTheSameIntervals()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        store.Connector.Failure = block => block == "RCA-PG-15" ? new CaptureException(CaptureFailureKind.Timeout, "PostgreSQL error 57014: canceling statement due to statement timeout") : null;
        var (capture, sidecar, _) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 17, 5700));

        Assert.Null(capture.Through);
        Assert.Contains("RCA-PG-15 timed out on T4's azure_sys, so the next read takes its intervals: PostgreSQL error 57014: canceling statement due to statement timeout", Gaps(sidecar));
        store.Connector.Failure = null;
        await ReadAtAsync(capture, store, At(17, 32));
        Assert.Equal(At(17, 17, 5700).AddHours(-2), store.Connector.ParameterCalls[^2].Parameters[1].Value);
        Assert.Equal(At(17, 15), capture.Through);
    }

    [Fact]
    public async Task APageOf600RowsIsReadOnFromItsLastWholeInterval()
    {
        // 31 intervals of 20 rows: the first page holds 30 of them, the last cut short.
        var start = At(9, 0);
        var all = new List<CaptureValues>();
        for (var interval = 0; interval < 31; interval++)
        {
            for (var query = 0; query < 20; query++)
            {
                all.Add(StatsRow(start.AddMinutes(15 * interval), interval * 100 + query, Runner, "SELECT p.patient_id FROM care.patients AS p WHERE p.patient_id = $1", 1, 1, 1, 1, 0, 1, 0, 0));
            }
        }

        var connector = new ScriptedConnector((_, _) => []);
        connector.ParameterAnswer = (block, parameters) => block == "RCA-PG-14"
            ? [.. all.Where(r => r.Time("interval_end_utc") > (DateTimeOffset)parameters[1].Value!).Take(PgQueryStoreReader.PageRows)]
            : [];
        await using var connection = await connector.OpenAsync(TestContext.Current.CancellationToken);
        var read = await PgQueryStoreReader.ReadAsync(connection, "contosocare", start.AddMinutes(-1), At(18, 0), Harness(), TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);

        Assert.Equal(620, read.Statistics.Count);
        Assert.Equal(620, read.Statistics.Select(r => (r.Time("interval_start_utc"), r.Long("query_id"))).Distinct().Count());
        Assert.Equal(start.AddMinutes(15 * 31), read.Through);
        Assert.True(read.Complete);
        Assert.Equal(["RCA-PG-14", "RCA-PG-14", "RCA-PG-15"], connector.ParameterCalls.Select(c => c.BlockId));
        Assert.Equal(start.AddMinutes(15 * 29), connector.ParameterCalls[1].Parameters[1].Value);
    }

    [Fact]
    public async Task ACaptureModeThatChangesBetweenReadsIsAQueryEventAndOffIsAGap()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var (capture, sidecar, watermark) = Capture(store, SpanA);

        await ReadAtAsync(capture, store, At(17, 2, 5610));
        store.CaptureMode = "none";
        await ReadAtAsync(capture, store, At(17, 17, 5700));
        store.Clock = At(17, 20);
        await capture.EndAsync(store.Clock, TestContext.Current.CancellationToken);

        var change = Assert.Single(sidecar.Table(RcaContract.QueryEvents));
        Assert.Equal("state", change.Get("kind"));
        Assert.Equal("none", change.Get("state"));
        Assert.Equal("all", change.Get("previous_state"));
        Assert.Equal(At(17, 17, 5700), change.Get("event_time_utc"));
        Assert.Equal(At(17, 2, 5610), change.Get("time_from_utc"));
        Assert.Equal("On T4, pg_qs.query_capture_mode went from all to none between the reads at 17:02:05 and 17:17:05 UTC.", change.Get("detail"));
        Assert.Contains("T4's Query Store records nothing: pg_qs.query_capture_mode is none. Learn advises keeping it off on a Burstable size; on any other, ./scripts/deploy.ps1 turns it on.", Gaps(sidecar));

        // Query Store off publishes nothing later: nothing is pending at the end.
        Assert.Empty(watermark.Read().Pending);
        Assert.Null(sidecar.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));
    }

    // ---- The watermark and the backfill ------------------------------------------------------------------------------

    [Fact]
    public async Task TheNextStartBackfillsTheLastWindowIntoTheSpanItBelongsTo()
    {
        var store = new T4QueryStore([.. T4Statistics(), .. Later()], T4Waits());
        var (first, sessionA, watermark) = Capture(store, SpanA);
        await ReadAtAsync(first, store, At(17, 2, 5610));
        await ReadAtAsync(first, store, At(17, 17, 5700));
        store.Clock = At(17, 20);
        await first.EndAsync(store.Clock, TestContext.Current.CancellationToken);

        // What's unsettled at the end is kept: from 17:00, where the reads found every interval surely published.
        var pending = Assert.Single(watermark.Read().Pending);
        Assert.Equal((SpanA, At(17, 0), At(17, 20)), (pending.SpanId, pending.FromUtc, pending.ToUtc!.Value));

        // The next session, in span B, at 18:00: the 17:15 interval is published now, and 17:00 surely whole.
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var sessionB = new MemorySidecar();
        var second = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), sessionB, new PgSidecarOptions(), RunnerLog.Null);
        await ReadAtAsync(second, store, At(18, 0));

        var rows = backfilled.Table(RcaContract.QueryStats);
        Assert.Equal([At(17, 0), At(17, 0), At(17, 0), At(17, 0), At(17, 15), At(17, 15)], rows.Select(r => (DateTimeOffset)r.Get("interval_start_utc")!).Order());
        Assert.All(rows, r => Assert.Equal(At(18, 0), r.Get("captured_at_utc")));
        Assert.Equal(3, backfilled.Table(RcaContract.QueryWaits).Count);
        var coverage = Assert.Single(backfilled.Table(RcaContract.QueryCoverage));
        Assert.True(coverage.Get("backfill") is true);
        Assert.Equal(At(17, 0), coverage.Get("window_start_utc"));
        Assert.Equal(At(17, 20), coverage.Get("window_end_utc"));
        Assert.Equal(At(17, 0), coverage.Get("read_from_utc"));
        Assert.Equal(At(17, 30), coverage.Get("read_to_utc"));
        Assert.Null(coverage.Get("pending_from_utc"));
        Assert.Null(coverage.Get("gaps"));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);

        // Span B's own read is its baseline: the 2 hours before 18:00, into its own sidecar.
        Assert.Equal([At(16, 45), At(17, 0), At(17, 15)], sessionB.Table(RcaContract.QueryStats).Select(r => (DateTimeOffset)r.Get("interval_start_utc")!).Distinct().Order());
        Assert.DoesNotContain(sessionA.Table(RcaContract.QueryStats), r => (DateTimeOffset)r.Get("interval_start_utc")! == At(17, 15));
    }

    [Fact]
    public async Task WhatT4StillHeldInMemoryWhenItStoppedIsLostNeverPending()
    {
        // Session A ends at 17:20 with 17:00 to 17:20 unsettled, and T4's start time recorded with it. The 17:15 interval
        // was still in memory at the end, and T4 never shows it.
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var (first, _, watermark) = Capture(store, SpanA);
        await ReadAtAsync(first, store, At(17, 2, 5610));
        await ReadAtAsync(first, store, At(17, 17, 5700));
        store.Clock = At(17, 20);
        await first.EndAsync(store.Clock, TestContext.Current.CancellationToken);
        Assert.Equal(ServerStart, Assert.Single(watermark.Read().Pending).ServerStartedUtc);
        Assert.Equal(ServerStart, watermark.Read().ServerStartedUtc);

        // T4 still up at 17:32 (the observer started again, T4 didn't): 17:15 isn't surely published yet, so it's pending.
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var second = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);
        await ReadAtAsync(second, store, At(17, 32));
        Assert.Equal(At(17, 15), backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));
        Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA);

        // T4 stopped and started again at 17:40: what it doesn't show of the time before then never will, unless Query Store
        // publishes a stopped window late (the live check L0a), so the backfill waits an interval and the publication delay
        // after the start too. Pending at 17:47; at 18:17, lost, not pending, and done.
        store.ServerStarted = At(17, 40);
        spans.CurrentSpan = "20261120T174500Z";
        var third = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);
        await ReadAtAsync(third, store, At(17, 47));
        Assert.Equal(At(17, 15), backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));
        Assert.DoesNotContain("Lost", (string?)backfilled.Table(RcaContract.QueryCoverage)[^1].Get("gaps"), StringComparison.Ordinal);
        Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA);

        // 18:02: the range's own end has settled (17:55), but not the time after T4's start (18:15).
        await ReadAtAsync(third, store, At(18, 2));
        Assert.Equal(At(17, 15), backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));
        Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA);

        await ReadAtAsync(third, store, At(18, 17));
        var coverage = backfilled.Table(RcaContract.QueryCoverage)[^1];
        Assert.Null(coverage.Get("pending_from_utc"));
        Assert.Equal("Lost when T4 stopped: Query Store shows nothing of 2026-11-20 17:15 to 2026-11-20 17:20 UTC, which it still held in memory when T4 stopped, and T4 has started again since, so none of it will show.", coverage.Get("gaps"));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
        Assert.Equal(At(17, 40), watermark.Read().ServerStartedUtc);
    }

    [Fact]
    public async Task WhatT4KeptAcrossItsRestartIsReadWithNothingLost()
    {
        // As above, but T4 kept the 17:15 interval: after its restart, the backfill reads it, and nothing is lost.
        var store = new T4QueryStore([.. T4Statistics(), .. Later()], T4Waits());
        var (first, _, watermark) = Capture(store, SpanA);
        await ReadAtAsync(first, store, At(17, 2, 5610));
        await ReadAtAsync(first, store, At(17, 17, 5700));
        store.Clock = At(17, 20);
        await first.EndAsync(store.Clock, TestContext.Current.CancellationToken);

        store.ServerStarted = At(17, 40);
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var second = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);
        await ReadAtAsync(second, store, At(17, 47));

        // Everything shows, so nothing is lost or pending, but the range is kept until an interval and the publication delay
        // have passed after T4's start, and a later read, which writes nothing again, removes it.
        var coverage = Assert.Single(backfilled.Table(RcaContract.QueryCoverage));
        Assert.Null(coverage.Get("pending_from_utc"));
        Assert.Null(coverage.Get("gaps"));
        Assert.Equal(2, backfilled.Table(RcaContract.QueryStats).Count(r => (DateTimeOffset)r.Get("interval_start_utc")! == At(17, 15)));
        Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA);

        await ReadAtAsync(second, store, At(18, 17));
        Assert.All(backfilled.Table(RcaContract.QueryCoverage), r => Assert.Null(r.Get("gaps")));
        Assert.Equal(2, backfilled.Table(RcaContract.QueryStats).Count(r => (DateTimeOffset)r.Get("interval_start_utc")! == At(17, 15)));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
    }

    [Fact]
    public async Task ARestartInsideTheRangeLeavesWhatCameAfterItToPublication()
    {
        // Session A's range, 17:00 to 17:20, kept T4's start as its last RCA-PG-13 found it: 08:00, but T4 started again at
        // 17:10 (that read was before the restart, or failed after it). From 17:10 on, T4's new lifetime recorded the time,
        // and Query Store publishes it as usual: 17:15's interval 10 minutes after it ends at 17:30.
        var store = new T4QueryStore([.. T4Statistics(), .. Later()], T4Waits()) { ServerStarted = At(17, 10), PublishedAfter = TimeSpan.FromMinutes(10) };
        var watermark = Watermark();
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(17, 0), FromUtc = At(17, 0), ToUtc = At(17, 20), RecordedUtc = At(17, 20), ServerStartedUtc = ServerStart }));
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);

        // 17:32: Query Store shows through 17:15. What's after it, 17:15 to 17:20, came after the restart: pending, not lost.
        await ReadAtAsync(capture, store, At(17, 32));
        var waiting = Assert.Single(backfilled.Table(RcaContract.QueryCoverage));
        Assert.Equal((At(17, 15), At(17, 20)), (waiting.Get("pending_from_utc"), waiting.Get("pending_to_utc")));
        Assert.DoesNotContain("Lost", (string?)waiting.Get("gaps"), StringComparison.Ordinal);
        Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA);

        // 18:02: 17:15's interval has been published and read, and nothing was lost.
        await ReadAtAsync(capture, store, At(18, 2));
        var done = backfilled.Table(RcaContract.QueryCoverage)[^1];
        Assert.Null(done.Get("pending_from_utc"));
        Assert.Null(done.Get("gaps"));
        Assert.Equal(2, backfilled.Table(RcaContract.QueryStats).Count(r => (DateTimeOffset)r.Get("interval_start_utc")! == At(17, 15)));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
    }

    [Fact]
    public async Task ARestartInsideTheRangeLosesOnlyWhatCameBeforeIt()
    {
        // As above, but Query Store shows nothing from 17:00 on: it lost 17:00 to 17:10, the old lifetime's last minutes,
        // and the new one recorded nothing.
        var store = new T4QueryStore([.. T4Statistics().Where(s => s.Time("interval_start_utc") < At(17, 0))], T4Waits()) { ServerStarted = At(17, 10) };
        var watermark = Watermark();
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(17, 0), FromUtc = At(17, 0), ToUtc = At(17, 20), RecordedUtc = At(17, 20), ServerStartedUtc = ServerStart }));
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);

        await ReadAtAsync(capture, store, At(17, 32));
        Assert.Equal(At(17, 0), backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));

        // 17:55 on, the whole range has settled: only what came before T4's start is lost.
        await ReadAtAsync(capture, store, At(18, 2));
        var coverage = backfilled.Table(RcaContract.QueryCoverage)[^1];
        Assert.Null(coverage.Get("pending_from_utc"));
        Assert.Equal("Lost when T4 stopped: Query Store shows nothing of 2026-11-20 17:00 to 2026-11-20 17:10 UTC, which it still held in memory when T4 stopped, and T4 has started again since, so none of it will show.", coverage.Get("gaps"));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
    }

    [Fact]
    public async Task ARangeWithAStartTimeWaitsWhileT4sCantBeRead()
    {
        // 17:32: T4 hasn't restarted, and session A's range waits for publication. T4 stops and starts again at 17:40, and
        // at 18:02 the observer's RCA-PG-13 fails (the evidence capture hasn't reconnected yet). The settings it last read
        // say T4 started at 08:00, but that's not what this read found, so a restart can't be told from none: the range
        // waits, though its own end has settled. At 18:17 T4's start is read, an interval and the publication delay have
        // passed after it, and the range is lost.
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var watermark = Watermark();
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(17, 0), FromUtc = At(17, 15), ToUtc = At(17, 20), RecordedUtc = At(17, 20), ServerStartedUtc = ServerStart }));
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);
        await ReadAtAsync(capture, store, At(17, 32));
        Assert.Equal(At(17, 15), backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));

        store.ServerStarted = At(17, 40);
        store.Access.Failure = b => b == "RCA-PG-13" ? QuietResult.Failed(CaptureFailureKind.Connection, "Exception while reading from stream (a test's).") : null;
        await ReadAtAsync(capture, store, At(18, 2));
        Assert.Equal(At(17, 15), backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));
        Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA);

        store.Access.Failure = null;
        await ReadAtAsync(capture, store, At(18, 17));
        Assert.Equal("Lost when T4 stopped: Query Store shows nothing of 2026-11-20 17:15 to 2026-11-20 17:20 UTC, which it still held in memory when T4 stopped, and T4 has started again since, so none of it will show.", backfilled.Table(RcaContract.QueryCoverage)[^1].Get("gaps"));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
    }

    [Fact]
    public async Task ARangeStaysPendingUntilItsIntervalIsSurelyPublished()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits()) { PublishedAfter = TimeSpan.FromHours(4) };
        var watermark = Watermark();
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(17, 0), FromUtc = At(17, 15), ToUtc = At(17, 20), RecordedUtc = At(17, 20) }));
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);

        // 17:47: nothing published for 17:15 yet, so it stays pending, and says so.
        await ReadAtAsync(capture, store, At(17, 47));
        var waiting = Assert.Single(backfilled.Table(RcaContract.QueryCoverage));
        Assert.Equal(At(17, 15), waiting.Get("pending_from_utc"));
        Assert.Equal(At(17, 20), waiting.Get("pending_to_utc"));
        Assert.Equal("Pending publication: Query Store shows an interval only once it ends, so 17:15 to 17:20 is read at the next start while T4 runs.", waiting.Get("gaps"));
        Assert.Equal(At(17, 15), Assert.Single(watermark.Read().Pending, p => p.SpanId == SpanA).FromUtc);

        // 17:55 on, the interval that holds 17:20 has surely been published: an empty read settles it.
        await ReadAtAsync(capture, store, At(18, 2));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
        Assert.Null(backfilled.Table(RcaContract.QueryCoverage)[^1].Get("pending_from_utc"));
    }

    [Fact]
    public async Task ARangeOlderThanQueryStoresRetentionExpiresAsAGapInTheSpanItBelongsTo()
    {
        // The span store still knows the span (T1's ledger keeps it past the span's folder): the range expires as a row.
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var watermark = Watermark();
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(17, 0).AddDays(-8), FromUtc = At(17, 15).AddDays(-8), ToUtc = At(17, 20).AddDays(-8), RecordedUtc = At(17, 20).AddDays(-8) }));
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var expired = spans.Add(SpanA);
        using var logText = new StringWriter(CultureInfo.InvariantCulture);
        using var log = new RunnerLog(logText);
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), log);

        await ReadAtAsync(capture, store, At(17, 47));

        var coverage = Assert.Single(expired.Table(RcaContract.QueryCoverage));
        Assert.True(coverage.Get("backfill") is true);
        Assert.Equal("Pending publication expired: T4's Query Store keeps 7 days, so 2026-11-12 17:15 to 2026-11-12 17:20 UTC can't be read any more.", coverage.Get("gaps"));
        Assert.Empty(expired.Table(RcaContract.QueryStats));
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
        Assert.DoesNotContain(store.Connector.ParameterCalls, c => (DateTimeOffset)c.Parameters[1].Value! == At(17, 15).AddDays(-8));
        Assert.DoesNotContain("rca.querystore-forgotten", logText.ToString(), StringComparison.Ordinal);

        // A span the store no longer knows at all can't take a row: its range is dropped with a log line instead.
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = "20261101T090000Z", ObservedFromUtc = At(9, 0).AddDays(-19), FromUtc = At(9, 15).AddDays(-19), ToUtc = At(9, 20).AddDays(-19), RecordedUtc = At(9, 20).AddDays(-19) }));
        await ReadAtAsync(capture, store, At(18, 2));
        Assert.Contains("rca.querystore-forgotten", logText.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == "20261101T090000Z");
        Assert.Single(expired.Table(RcaContract.QueryCoverage));
    }

    [Fact]
    public async Task ARangeWhoseObserverNeverEndedIsReadToOneIntervalAfterItWasRecorded()
    {
        var store = new T4QueryStore([.. T4Statistics(), .. Later()], T4Waits());
        var watermark = Watermark();
        watermark.Update(s => s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(16, 50), FromUtc = At(17, 15), RecordedUtc = At(17, 17, 5700) }));
        var spans = new MemorySpans { CurrentSpan = SpanB };
        var backfilled = spans.Add(SpanA);
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, spans), new MemorySidecar(), new PgSidecarOptions(), RunnerLog.Null);

        await ReadAtAsync(capture, store, At(18, 10));

        var backfill = store.Connector.ParameterCalls[0].Parameters;
        Assert.Equal(At(17, 15), backfill[1].Value);
        Assert.Equal(At(17, 32, 5700), backfill[5].Value);
        Assert.Equal(2, backfilled.Table(RcaContract.QueryStats).Count);
        Assert.DoesNotContain(watermark.Read().Pending, p => p.SpanId == SpanA);
    }

    [Fact]
    public void TheWatermarkKeepsItsStateAcrossInstancesAndTakesABadFileAsEmpty()
    {
        var watermark = Watermark();
        watermark.Update(s =>
        {
            s.ThroughUtc = At(17, 15);
            s.Pending.Add(new PendingRange { SpanId = SpanA, ObservedFromUtc = At(17, 0), FromUtc = At(17, 15), ToUtc = At(17, 20), RecordedUtc = At(17, 20) });
        });

        var again = new QueryWatermark(root, "T4").Read();
        Assert.Equal(At(17, 15), again.ThroughUtc);
        var pending = Assert.Single(again.Pending);
        Assert.Equal((SpanA, At(17, 0), At(17, 15), At(17, 20), At(17, 20)), (pending.SpanId, pending.ObservedFromUtc, pending.FromUtc, pending.ToUtc!.Value, pending.RecordedUtc));
        Assert.Equal(Path.Combine(root, "query-watermark", "T4.json"), watermark.FilePath);

        File.WriteAllText(watermark.FilePath, "{ not json");
        Assert.Empty(watermark.Read().Pending);
        watermark.Update(s => s.ThroughUtc = At(18, 0));
        Assert.Equal(At(18, 0), new QueryWatermark(root, "T4").Read().ThroughUtc);
        Assert.Throws<ArgumentException>(() => new QueryWatermark(root, "..\\T4"));

        // The store's own listing never takes the watermark's folder for a span, and its retention never deletes it.
        var evidence = new EvidenceStore(root);
        Assert.Empty(evidence.Spans());
        evidence.Cleanup(At(17, 20).AddDays(60), RunnerLog.Null);
        Assert.True(File.Exists(watermark.FilePath));
    }

    // ---- The replica -------------------------------------------------------------------------------------------------

    [Fact]
    public async Task TheReplicasCoverageSaysItRecordsNothingInQueryStore()
    {
        var fixture = new SidecarFixture("t4-query-store.sidecar.json");
        var clock = new ManualTime(RcaSimulation.T4From);
        var replica = new ScriptedConnector((block, _) => block == "RCA-PG-13" ? Settings(clock.Now, inRecovery: true) : []);
        var sidecar = new MemorySidecar();

        await RcaSimulation.DriveAsync([new PgReplicaObserver(replica, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar)], new MemorySink(), clock, RcaSimulation.T4From, RcaSimulation.T4To, TestContext.Current.CancellationToken);

        var rows = sidecar.Table(RcaContract.QueryCoverage);
        Assert.Equal([At(17, 0), At(17, 2), At(17, 17), At(17, 20)], rows.Select(r => r.At));
        var merged = Merge(rows);
        var expected = fixture.Table(RcaContract.QueryCoverage).Single(r => (string?)r["target"] == "T4-replica");
        foreach (var column in RcaContract.Table(RcaContract.QueryCoverage).Columns.Select(c => c.Name).Where(c => c is not ("window_start_utc" or "window_end_utc")))
        {
            Assert.Equal(expected.GetValueOrDefault(column), merged.GetValueOrDefault(column));
        }

        Assert.All(replica.Calls.Where(c => c.BlockId == "RCA-PG-13"), c => Assert.Equal(CaptureCatalog.Get("RCA-PG-13"), c.Text));
    }

    // ---- Who holds T4's connections ------------------------------------------------------------------------------------

    [Fact]
    public void TheHoldersOfASurgeRoundTripTheFixture()
    {
        var fixture = new SidecarFixture("t4-connection-surge.sidecar.json");
        var expected = fixture.Table(RcaContract.Connections);
        var runA = ApplicationNames.RunToken("20261121100500-t4-aa11bb");
        var runB = ApplicationNames.RunToken("20261121090000-t4-cc22dd");
        var tokens = new Dictionary<string, string>(StringComparer.Ordinal) { ["7c3e91a05bd2"] = runA, ["2fa86c14e9b0"] = runB };
        var actual = new List<CaptureRow>();
        foreach (var sample in expected.GroupBy(r => (DateTimeOffset)r["captured_at_utc"]!))
        {
            // The block's groups, as pg_stat_activity would give them: each fixture group split in two where it can be,
            // another application under two names and roles, and the observer's own connection.
            var raw = new List<CaptureValues>();
            foreach (var group in sample)
            {
                var count = (long)group["connections"]!;
                var state = (string)group["state"]!;
                var oldestState = (double)group["oldest_state_s"]!;
                var oldestConnection = (double)group["oldest_connection_s"]!;
                var name = group["run_token"] is string token
                    ? ApplicationNames.Program + "/svc-intake/" + (tokens[token] == runA ? "20261121100500-t4-aa11bb" : "20261121090000-t4-cc22dd")
                    : "psql";
                var role = group["is_demo"] is true ? Runner : "monitoring_reader";
                raw.Add(HolderRow(sample.Key, name, role, state, count - 1, 0, oldestState, oldestConnection));
                raw.Add(HolderRow(sample.Key, group["is_demo"] is true ? name.Replace("svc-intake", "svc-billing", StringComparison.Ordinal) : string.Empty, group["is_demo"] is true ? Runner : "another_role", state, 1, 0, oldestState / 2, oldestConnection / 2));
            }

            raw.Add(HolderRow(sample.Key, ApplicationNames.Observer, Runner, "active", 1, 0, 0, 900));
            actual.AddRange(ConnectionHolders.Rows("T4", raw, sample.Key.AddSeconds(3)));
        }

        Assert.Equal(expected.Count, actual.Count);
        for (var i = 0; i < expected.Count; i++)
        {
            var row = new Dictionary<string, object?>(expected[i], StringComparer.Ordinal);
            if (row["run_token"] is string token)
            {
                row["run_token"] = tokens[token];
            }

            AssertSameRow(row, actual[i], $"row {i}");
            Assert.Equal("RCA-PG-17", actual[i].Source);
        }

        // The fixture's facts, from the rows the observer built.
        Assert.Equal(37, actual.Select(r => r.At).Distinct().Count());
        var peak = actual.GroupBy(r => r.At).Select(g => (At: g.Key, Total: g.Sum(r => (long)r.Get("connections")!))).ToList();
        Assert.Equal(41, peak.Max(p => p.Total));
        Assert.Equal(new DateTimeOffset(2026, 11, 21, 10, 10, 0, TimeSpan.Zero), peak.First(p => p.Total == 41).At);
        Assert.DoesNotContain(actual, r => r.At == new DateTimeOffset(2026, 11, 21, 10, 12, 0, TimeSpan.Zero) && (string?)r.Get("run_token") == runA);
    }

    [Fact]
    public async Task AConnectionEpisodeCountsItsHoldersWithEverySampleAndOnceWhenItEnds()
    {
        var from = RcaSimulation.T4From;
        var busy = (From: from.AddMinutes(1), To: from.AddMinutes(3));
        var clock = new ManualTime(from);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-PG-10" => [Row(("captured_at", clock.Now.UtcDateTime), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", clock.Now >= busy.From && clock.Now < busy.To ? 45L : 10L), ("waiting_lock", 0L))],
            "RCA-PG-17" =>
            [
                HolderRow(clock.Now, ApplicationNames.Program + "/svc-intake/20261120170000-t4-0a0b0c", Runner, "idle", clock.Now >= busy.From && clock.Now < busy.To ? 40 : 5, 0, 12.5, 60),
                HolderRow(clock.Now, ApplicationNames.Observer, Runner, "active", 1, 0, 0, 600),
            ],
            _ => [],
        });
        var sidecar = new MemorySidecar();
        var evidence = new MemorySink();

        await RcaSimulation.DriveAsync([new PgPrimaryObserver(connector, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar)], evidence, clock, from, from.AddMinutes(6), TestContext.Current.CancellationToken);

        // From the sample that started the episode, every 10 s, to the one that ended it, 60 s after the last busy one.
        var samples = sidecar.Table(RcaContract.Connections).Select(r => r.At).ToList();
        Assert.Equal(Enumerable.Range(0, 18).Select(i => busy.From.AddSeconds(10 * i)), samples);
        Assert.Equal(busy.To.AddSeconds(50), samples[^1]);
        Assert.Equal(evidence.Events("capture")[1].At, samples[^1]);
        Assert.All(sidecar.Table(RcaContract.Connections), r => Assert.Equal(Runner, r.Get("login_name")));
        Assert.All(sidecar.Table(RcaContract.Connections), r => Assert.True(r.Get("is_demo") is true));

        // Without a sidecar the holders aren't read, and the evidence document's rows are the same either way.
        var plain = new MemorySink();
        var without = new ScriptedConnector((block, _) => block == "RCA-PG-10" ? [Row(("captured_at", clock.Now.UtcDateTime), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", clock.Now >= busy.From && clock.Now < busy.To ? 45L : 10L), ("waiting_lock", 0L))] : []);
        await RcaSimulation.DriveAsync([new PgPrimaryObserver(without, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink())], plain, clock, from, from.AddMinutes(6), TestContext.Current.CancellationToken);
        Assert.DoesNotContain(without.Calls, c => c.BlockId == "RCA-PG-17");
        Assert.Equal(Lines(plain), Lines(evidence));
    }

    [Fact]
    public async Task ASlowHolderReadLeavesTheEvidenceAsItWas()
    {
        // RCA-PG-17 takes longer than a slow sample, in real time: untimed, it changes neither T4's cadence nor its gaps.
        var options = RcaSimulation.Options() with { SlowSample = TimeSpan.FromSeconds(1), QuietFor = TimeSpan.FromSeconds(10) };
        var from = RcaSimulation.T4From;
        var busy = (From: from.AddSeconds(60), To: from.AddSeconds(70));
        var clock = new ManualTime(from);
        IReadOnlyList<CaptureValues> Answer(string block) => block switch
        {
            "RCA-PG-10" => [Row(("captured_at", clock.Now.UtcDateTime), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", clock.Now >= busy.From && clock.Now < busy.To ? 45L : 10L), ("waiting_lock", 0L))],
            "RCA-PG-17" => [HolderRow(clock.Now, "psql", "monitoring_reader", "idle", 40, 0, 1, 1)],
            _ => [],
        };
        var slow = new SlowBlockConnector(new ScriptedConnector((block, _) => Answer(block)), "RCA-PG-17", TimeSpan.FromSeconds(1.5));
        var sidecar = new MemorySidecar();
        var evidence = new MemorySink();
        await RcaSimulation.DriveAsync([new PgPrimaryObserver(slow, options, RunnerLog.Null, new ReplicaLink(), sidecar)], evidence, clock, from, from.AddMinutes(2), TestContext.Current.CancellationToken);
        var plain = new MemorySink();
        await RcaSimulation.DriveAsync([new PgPrimaryObserver(new ScriptedConnector((block, _) => Answer(block)), options, RunnerLog.Null, new ReplicaLink())], plain, clock, from, from.AddMinutes(2), TestContext.Current.CancellationToken);

        Assert.Equal(2, slow.Slow);
        Assert.Equal(2, sidecar.Table(RcaContract.Connections).Count);
        Assert.Equal(Lines(plain), Lines(evidence));
        Assert.Equal(plain.Notes, evidence.Notes);
    }

    // ---- Phase 1 stays as it was -------------------------------------------------------------------------------------

    [Fact]
    public async Task ASidecarThatCantKeepItsRowsNeverStopsTheEvidenceCapture()
    {
        var from = RcaSimulation.T4From;
        var busy = (From: from.AddMinutes(1), To: from.AddMinutes(3));
        var clock = new ManualTime(from);
        IReadOnlyList<CaptureValues> Answer(string block) => block switch
        {
            "RCA-PG-10" => [Row(("captured_at", clock.Now.UtcDateTime), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", clock.Now >= busy.From && clock.Now < busy.To ? 45L : 10L), ("waiting_lock", 0L))],
            "RCA-PG-17" => [HolderRow(clock.Now, "psql", "monitoring_reader", "idle", 40, 0, 1, 1)],
            _ => [],
        };
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        store.Follow(clock);
        var source = new PgQueryStoreSource(store.Connector, Watermark(), new MemorySpans { CurrentSpan = SpanA });

        var failing = new MemorySink();
        await RcaSimulation.DriveAsync([new PgPrimaryObserver(new ScriptedConnector((block, _) => Answer(block)), RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), new FailingSidecar(), source)], failing, clock, from, from.AddMinutes(6), TestContext.Current.CancellationToken);
        var plain = new MemorySink();
        await RcaSimulation.DriveAsync([new PgPrimaryObserver(new ScriptedConnector((block, _) => Answer(block)), RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink())], plain, clock, from, from.AddMinutes(6), TestContext.Current.CancellationToken);

        Assert.Equal(Lines(plain), Lines(failing));
        Assert.Equal(plain.Notes, failing.Notes);

        // The reads kept their schedule (17:00, 17:02, and the end) rather than running again at every tick.
        Assert.Equal(3, store.Connector.ParameterCalls.Count(c => c.BlockId == "RCA-PG-14"));
    }

    [Fact]
    public async Task TheSidecarChangesNothingTheEvidenceDocumentCaptures()
    {
        async Task<(MemorySink Evidence, MemorySidecar Sidecar, ScriptedConnector Primary)> RunAsync(bool sidecarOn)
        {
            var clock = new ManualTime(RcaSimulation.T4From);
            var link = new ReplicaLink();
            var sink = new MemorySink();
            var sidecar = new MemorySidecar();
            var store = new T4QueryStore(T4Statistics(), T4Waits());
            var primary = RcaSimulation.T4Primary(clock);
            var spans = new MemorySpans { CurrentSpan = SpanA };
            var source = new PgQueryStoreSource(store.Connector, new QueryWatermark(Path.Combine(root, sidecarOn ? "on" : "off"), "T4"), spans);
            List<TargetObserver> observers = sidecarOn
                ? [new PgPrimaryObserver(primary, RcaSimulation.Options(), RunnerLog.Null, link, sidecar, source), new PgReplicaObserver(RcaSimulation.T4Replica(clock), RcaSimulation.Options(), RunnerLog.Null, link, sidecar)]
                : [new PgPrimaryObserver(primary, RcaSimulation.Options(), RunnerLog.Null, link), new PgReplicaObserver(RcaSimulation.T4Replica(clock), RcaSimulation.Options(), RunnerLog.Null, link)];
            store.Follow(clock);
            await RcaSimulation.DriveAsync(observers, sink, clock, RcaSimulation.T4From, RcaSimulation.T4To, TestContext.Current.CancellationToken);
            return (sink, sidecar, primary);
        }

        var off = await RunAsync(sidecarOn: false);
        var on = await RunAsync(sidecarOn: true);

        Assert.Equal(Lines(off.Evidence), Lines(on.Evidence));
        Assert.Equal(off.Evidence.Notes, on.Evidence.Notes);
        Assert.NotEmpty(on.Sidecar.Table(RcaContract.QueryStats));
        Assert.Contains(on.Primary.Calls, c => c.BlockId == "RCA-PG-13");
        Assert.DoesNotContain(on.Primary.Calls, c => c.BlockId is "RCA-PG-14" or "RCA-PG-15");
        Assert.Equal(off.Primary.Calls.Count, on.Primary.Calls.Count(c => c.BlockId is not ("RCA-PG-13" or "RCA-PG-16")));
    }

    // ---- The evidence stays as it would be without a sink --------------------------------------------------------------

    [Theory]
    [InlineData("RCA-PG-13", "timeout")]
    [InlineData("RCA-PG-13", "refused")]
    [InlineData("RCA-PG-13", "error")]
    [InlineData("RCA-PG-13", "throws")]
    [InlineData("RCA-PG-16", "timeout")]
    [InlineData("RCA-PG-16", "refused")]
    [InlineData("RCA-PG-16", "error")]
    [InlineData("RCA-PG-16", "throws")]
    [InlineData("RCA-PG-17", "timeout")]
    [InlineData("RCA-PG-17", "refused")]
    [InlineData("RCA-PG-17", "error")]
    [InlineData("RCA-PG-17", "throws")]
    [InlineData("RCA-PG-14", "timeout")]
    [InlineData("RCA-PG-14", "refused")]
    [InlineData("RCA-PG-14", "error")]
    [InlineData("RCA-PG-14", "throws")]
    [InlineData("RCA-PG-15", "timeout")]
    [InlineData("RCA-PG-15", "refused")]
    [InlineData("RCA-PG-15", "error")]
    [InlineData("RCA-PG-15", "throws")]
    [InlineData("open", "refused")]
    [InlineData("open", "error")]
    [InlineData("open", "throws")]
    public async Task ASidecarBlockThatFailsLeavesTheEvidenceAndItsWatermarksAsWithoutASink(string block, string failure)
    {
        Exception Failure() => failure switch
        {
            "timeout" => new CaptureException(CaptureFailureKind.Timeout, "PostgreSQL error 57014: canceling statement due to statement timeout"),
            "refused" => new CaptureException(CaptureFailureKind.Permission, "PostgreSQL error 42501: permission denied for view qs_view"),
            "error" => new CaptureException(CaptureFailureKind.Other, "PostgreSQL error XX000: the block failed (a test's failure)"),
            _ => new InvalidOperationException("The connection threw (a test's failure)."),
        };
        var without = await RunT4Async(sink: false);
        var with = await RunT4Async(sink: true, (observer, azure) =>
        {
            observer.Failure = b => b == block ? Failure() : null;
            azure.Failure = b => b == block ? Failure() : null;
            azure.OpenFailure = block == "open" ? Failure() : null;
        });

        Assert.Equal(without.Rows, with.Rows);
        Assert.Equal(without.Notes, with.Notes);
        Assert.Equal(without.Marks, with.Marks);
        Assert.Equal(without.Final, with.Final);
        Assert.Contains(with.Observer.Failures.Concat(with.Store.Failures), f => f.BlockId == block);
        Assert.DoesNotContain(with.Notes, n => SidecarBlocks.Any(b => n.Contains(b, StringComparison.Ordinal)));
        if (block == "RCA-PG-17")
        {
            Assert.Empty(with.Sidecar!.Table(RcaContract.Connections));
            Assert.Contains(Gaps(with.Sidecar), g => g.StartsWith("Who holds T4's connections (RCA-PG-17) wasn't read during a connection episode: ", StringComparison.Ordinal));
        }
        else if (failure != "throws" || block is "RCA-PG-13" or "RCA-PG-16")
        {
            Assert.Contains(Gaps(with.Sidecar!), g => g.Contains(block == "open" ? "RCA-PG-14" : block, StringComparison.Ordinal));
        }

        // A refusal on the observer's connection names the block's own permission and fix, not the observer's.
        if (failure == "refused" && block is "RCA-PG-13" or "RCA-PG-16" or "RCA-PG-17")
        {
            Assert.Contains(Gaps(with.Sidecar!), g => g.EndsWith("permission denied for view qs_view " + PgQueryStoreRows.RefusalFix("T4", block), StringComparison.Ordinal));
            Assert.DoesNotContain(Gaps(with.Sidecar!), g => g.Contains("The fix: ", StringComparison.Ordinal));
        }

        Assert.Equal(without.Ended, with.Ended);
        Assert.Equal(without.Membership, with.Membership);
    }

    [Theory]
    [InlineData("RCA-PG-13", 4)]
    [InlineData("RCA-PG-13", 9)]
    [InlineData("RCA-PG-16", 4)]
    [InlineData("RCA-PG-14", 8)]
    [InlineData("RCA-PG-14", 40)]
    [InlineData("RCA-PG-15", 8)]
    [InlineData("open", 4)]
    public async Task SlowEndReadsLeaveTheSpansEndAndTheEvidenceAsWithoutASink(string block, int seconds)
    {
        // Only the end's reads are slow: they follow the evidence's end, whose time, watermark, and rows stay its own.
        var without = await RunT4Async(sink: false);
        var with = await RunT4Async(sink: true, (observer, azure) =>
        {
            TimeSpan Cost(string b) => b == block && observer.Now >= RcaSimulation.T4To ? TimeSpan.FromSeconds(seconds) : TimeSpan.Zero;
            observer.Cost = Cost;
            azure.Cost = Cost;
            azure.OpenCost = TimeSpan.Zero;
            azure.OpenCostAt = now => block == "open" && now >= RcaSimulation.T4To ? TimeSpan.FromSeconds(seconds) : TimeSpan.Zero;
        });

        Assert.Equal(RcaSimulation.T4To, without.Ended);
        Assert.Equal(without.Ended, with.Ended);
        Assert.Equal(without.Membership, with.Membership);
        Assert.Equal(without.Rows, with.Rows);
        Assert.Equal(without.Notes, with.Notes);
        Assert.Equal(without.Marks, with.Marks);
        Assert.Equal(without.Final, with.Final);

        // The end's reads did run, after the evidence's end, and took their time.
        Assert.True(with.Observer.Now >= RcaSimulation.T4To.AddSeconds(Math.Min(seconds, 4)), $"The clock stopped at {with.Observer.Now:HH:mm:ss.fff}.");
        Assert.Contains(with.Observer.Calls.Concat(with.Store.Calls), c => c.At >= RcaSimulation.T4To && c.BlockId is "RCA-PG-13" or "RCA-PG-14");
    }

    [Theory]
    [InlineData("RCA-PG-13", 4)]
    [InlineData("RCA-PG-13", 9)]
    [InlineData("RCA-PG-16", 4)]
    [InlineData("RCA-PG-16", 9)]
    [InlineData("RCA-PG-17", 4)]
    [InlineData("RCA-PG-17", 9)]
    [InlineData("RCA-PG-14", 12)]
    [InlineData("RCA-PG-14", 40)]
    [InlineData("RCA-PG-15", 12)]
    [InlineData("RCA-PG-15", 40)]
    [InlineData("open", 4)]
    [InlineData("open", 9)]
    public async Task ASlowSidecarBlockNeverMovesAnEvidenceSample(string block, int seconds)
    {
        // Up to its timeout (5 s for RCA-PG-13, 16, 17, and an open; 15 s for RCA-PG-14 and 15), or past it: the clock moves.
        var without = await RunT4Async(sink: false);
        var with = await RunT4Async(sink: true, (observer, azure) =>
        {
            observer.Cost = b => b == block ? TimeSpan.FromSeconds(seconds) : TimeSpan.Zero;
            azure.Cost = b => b == block ? TimeSpan.FromSeconds(seconds) : TimeSpan.Zero;
            azure.OpenCost = block == "open" ? TimeSpan.FromSeconds(seconds) : TimeSpan.Zero;
        });

        // Every sample at its time, with the same rows and notes, and the same watermark at the end. T4's watermark is the
        // tick's time, so the ticks a slow block took have no mark of their own.
        Assert.Equal(without.Rows, with.Rows);
        Assert.Equal(without.Notes, with.Notes);
        Assert.Equal(without.Final, with.Final);

        // Within its timeout it ran and returned; past it, it failed. The end's reads cut every timeout to their 10 s.
        var past = seconds > (block is "RCA-PG-14" or "RCA-PG-15" ? 15 : 5);
        Assert.Equal(past, with.Observer.Failures.Concat(with.Store.Failures).Any(f => f.BlockId == block && f.At < RcaSimulation.T4To));
        if (!past)
        {
            Assert.Contains(with.Observer.Calls.Select(c => c.BlockId).Concat(with.Store.Calls.Select(c => c.BlockId)), b => b == (block == "open" ? "RCA-PG-14" : block));
        }
    }

    [Fact]
    public async Task AConnectionAQuietBlockFindsLostIsNotedByTheEvidenceAsItWouldHaveBeen()
    {
        // RCA-PG-13 runs first at 17:00:00, after the sentinel's blocks: with a sink it finds the connection lost; without
        // one, the next sentinel does. Either way the sentinel notes the loss at 17:00:30 and reconnects a minute later.
        var lost = RcaSimulation.T4From;
        var without = await RunT4Async(sink: false, (observer, _) => observer.BreakAt = lost);
        var with = await RunT4Async(sink: true, (observer, _) => observer.BreakAt = lost);

        Assert.Equal((lost, "RCA-PG-13"), with.Observer.Failures[0]);
        Assert.Equal((lost.AddSeconds(30), "RCA-PG-10"), without.Observer.Failures[0]);
        Assert.Equal(without.Rows, with.Rows);
        Assert.Equal(without.Notes, with.Notes);
        Assert.Equal(without.Marks, with.Marks);
        Assert.Equal((2, 2), (without.Observer.Opens, with.Observer.Opens));
        Assert.Contains(with.Notes, n => n.Contains($"T4 didn't answer RCA-PG-10: {TimedT4.TransportError}", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("timeout", 0)]
    [InlineData("refused", 0)]
    [InlineData(null, 4)]
    [InlineData(null, 9)]
    public async Task TheReplicasQueryStoreBlockLeavesItsEvidenceAsWithoutASink(string? failure, int seconds)
    {
        async Task<(List<string> Rows, List<string> Notes, List<DateTimeOffset> Marks, DateTimeOffset Ended, TimedT4 Replica, MemorySidecar? Sidecar)> RunAsync(bool sink)
        {
            var clock = new ManualTime(RcaSimulation.T4From);
            var replica = new TimedT4(clock, RcaSimulation.T4Replica(clock), b => b == "RCA-PG-13" ? Settings(clock.Now, inRecovery: true) : null)
            {
                Cost = b => b == "RCA-PG-13" ? TimeSpan.FromSeconds(seconds) : TimeSpan.Zero,
                Failure = b => b != "RCA-PG-13" ? null : failure switch
                {
                    "timeout" => new CaptureException(CaptureFailureKind.Timeout, "PostgreSQL error 57014: canceling statement due to statement timeout"),
                    "refused" => new CaptureException(CaptureFailureKind.Permission, "PostgreSQL error 42501: permission denied for function pg_is_in_recovery"),
                    _ => null,
                },
            };
            var sidecar = sink ? new MemorySidecar() : null;
            var span = new MarkLog(new MemorySink());
            var ended = await LaneAsync(new PgReplicaObserver(replica, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar, null, new PgSidecarOptions { Clock = new TickClock(clock) }), span, clock, RcaSimulation.T4From, RcaSimulation.T4To);
            return (Lines(span.Inner), [.. span.Inner.Notes.Select(Note)], Distinct(span.Marks), ended, replica, sidecar);
        }

        var without = await RunAsync(sink: false);
        var with = await RunAsync(sink: true);

        // The replica's last read follows its evidence's end, which keeps its time: the span ends as without a sink.
        Assert.Equal(without.Ended, with.Ended);
        Assert.Equal(RcaSimulation.T4To, with.Ended);
        Assert.Equal(without.Rows, with.Rows);
        Assert.Equal(without.Notes, with.Notes);
        if (seconds == 0)
        {
            Assert.Equal(without.Marks, with.Marks);
        }

        Assert.Equal(without.Marks[^1], with.Marks[^1]);
        Assert.Contains(with.Replica.Calls, c => c.BlockId == "RCA-PG-13");
        Assert.DoesNotContain(without.Replica.Calls, c => c.BlockId == "RCA-PG-13");
        var rows = with.Sidecar!.Table(RcaContract.QueryCoverage);
        Assert.NotEmpty(rows);
        if (failure is not null || seconds > 5)
        {
            Assert.All(rows, r => Assert.StartsWith("RCA-PG-13 couldn't be read on T4-replica at ", (string?)r.Get("gaps"), StringComparison.Ordinal));
        }
    }

    [Theory]
    [InlineData("T4", "evidence")]
    [InlineData("T4", "watermark")]
    [InlineData("T4", "hook")]
    [InlineData("T4", "cancelled")]
    [InlineData("T4-replica", "watermark")]
    [InlineData("T4-replica", "hook")]
    [InlineData("T4-replica", "cancelled")]
    public async Task TheEndsQueryStoreReadsRunWhateverFailedBeforeThem(string target, string failure)
    {
        // The evidence's own end failed (its last episode's row, its last watermark, or the lane's hook threw), or the host's
        // stop cancelled the end (its 30-s limit). Query Store's end reads still run, after the evidence's end time was
        // taken, and the failure follows them; a cancelled end cuts them short, as their coverage says.
        var clock = new ManualTime(RcaSimulation.T4From);
        var to = RcaSimulation.T4To;
        var sidecar = new MemorySidecar();
        var span = new MarkLog(new MemorySink())
        {
            FailWritesFrom = failure == "evidence" ? to : null,
            FailWatermarksFrom = failure == "watermark" ? to : null,
        };
        TimedT4 connection;
        TimedStore? azure = null;
        TargetObserver observer;
        if (target == "T4")
        {
            var store = new T4QueryStore(T4Statistics(), T4Waits());
            store.Follow(clock);
            var timings = new PgSidecarOptions { Clock = new TickClock(clock) };
            connection = new TimedT4(clock, RcaSimulation.T4Primary(clock), block => block == "RCA-PG-17"
                ? [HolderRow(clock.Now, ApplicationNames.Program + "/svc-intake/20261120170000-t4-0a0b0c", Runner, "idle", 40, 0, 12.5, 60)]
                : store.ObserverAnswer(block))
            {
                // A connection episode still open at the end, so the evidence's end writes its close.
                Surge = (to.AddMinutes(-2), to.AddMinutes(1)),
            };
            azure = new TimedStore(clock, store.Connector, timings.OpenTimeout);
            var source = new PgQueryStoreSource(azure, new QueryWatermark(Path.Combine(root, Guid.NewGuid().ToString("N")), "T4"), new MemorySpans { CurrentSpan = SpanA });
            observer = new PgPrimaryObserver(connection, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar, source, timings);
        }
        else
        {
            connection = new TimedT4(clock, RcaSimulation.T4Replica(clock), b => b == "RCA-PG-13" ? Settings(clock.Now, inRecovery: true) : null);
            observer = new PgReplicaObserver(connection, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar, null, new PgSidecarOptions { Clock = new TickClock(clock) });
        }

        await RunUntilAsync(observer, span, clock, RcaSimulation.T4From, to);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        if (failure == "cancelled")
        {
            await stop.CancelAsync();
        }

        DateTimeOffset? ended = null;
        Task End() => observer.EndAsync(
            to,
            stop.Token,
            at =>
            {
                ended = at;
                if (failure == "hook")
                {
                    throw new InvalidOperationException("The lane's hook failed (a test's).");
                }
            },
            clock);
        if (failure == "cancelled")
        {
            await End();
        }
        else
        {
            var thrown = await Assert.ThrowsAnyAsync<Exception>(End);
            Assert.IsType(failure == "hook" ? typeof(InvalidOperationException) : typeof(IOException), thrown);
        }

        Assert.Equal(to, ended);
        var gaps = (string?)sidecar.Table(RcaContract.QueryCoverage)[^1].Get("gaps") ?? string.Empty;
        if (failure == "cancelled")
        {
            Assert.Contains(target == "T4" ? "The end's Query Store reads on T4 were cut short with the observer's end." : "RCA-PG-13 couldn't be read on T4-replica at 17:20 UTC: the end's read was cut short with the observer's end.", gaps, StringComparison.Ordinal);
            return;
        }

        // Every end read ran: Query Store's settings, and on T4 its statistics too, none cut short.
        Assert.Contains(connection.Calls, c => c.At >= to && c.BlockId == "RCA-PG-13");
        Assert.True(azure is null || azure.Calls.Any(c => c.At >= to && c.BlockId == "RCA-PG-14"));
        Assert.DoesNotContain("cut short", gaps, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("T4")]
    [InlineData("T4-replica")]
    public async Task AnEndCancelledInTheEvidencesOwnEndStillWritesQueryStoresCoverageWithItsGap(string target)
    {
        // The host stop's limit cancels the end while the evidence's own end writes its last watermark. T4's evidence end
        // waits on nothing, so it completes, with and without a sink alike, and its evidence is the same.
        async Task<(List<string> Rows, List<string> Notes, List<DateTimeOffset> Marks, DateTimeOffset Ended, MemorySidecar? Sidecar)> RunAsync(bool sink)
        {
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            void CancelAtTheEnd(MarkLog span) => span.OnWatermark = at =>
            {
                if (at >= RcaSimulation.T4To)
                {
                    stop.Cancel();
                }
            };

            if (target == "T4")
            {
                var run = await RunT4Async(sink, spanSetUp: CancelAtTheEnd, end: stop.Token);
                return (run.Rows, run.Notes, run.Marks, run.Ended, run.Sidecar);
            }

            var clock = new ManualTime(RcaSimulation.T4From);
            var replica = new TimedT4(clock, RcaSimulation.T4Replica(clock), b => b == "RCA-PG-13" ? Settings(clock.Now, inRecovery: true) : null);
            var sidecar = sink ? new MemorySidecar() : null;
            var span = new MarkLog(new MemorySink());
            CancelAtTheEnd(span);
            var ended = await LaneAsync(new PgReplicaObserver(replica, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar, null, new PgSidecarOptions { Clock = new TickClock(clock) }), span, clock, RcaSimulation.T4From, RcaSimulation.T4To, stop.Token);
            return (Lines(span.Inner), [.. span.Inner.Notes.Select(Note)], Distinct(span.Marks), ended, sidecar);
        }

        var without = await RunAsync(sink: false);
        var with = await RunAsync(sink: true);
        Assert.Equal(without.Rows, with.Rows);
        Assert.Equal(without.Notes, with.Notes);
        Assert.Equal(without.Marks, with.Marks);
        Assert.Equal(RcaSimulation.T4To, with.Marks[^1]);
        Assert.Equal((RcaSimulation.T4To, RcaSimulation.T4To), (without.Ended, with.Ended));

        // Query Store's end reads still ran, cancelled too, and wrote the sidecar's last coverage row with the gap that says so.
        var gaps = ((string?)with.Sidecar!.Table(RcaContract.QueryCoverage)[^1].Get("gaps") ?? string.Empty).Split('\n');
        Assert.Contains(target == "T4" ? "The end's Query Store reads on T4 were cut short with the observer's end." : "RCA-PG-13 couldn't be read on T4-replica at 17:20 UTC: the end's read was cut short with the observer's end.", gaps);
    }

    [Fact]
    public async Task NoReadStartsWhileTheObserverIsSlowedAndTheEndsReadStillRuns()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var (capture, sidecar, _) = Capture(store, SpanA);
        var token = TestContext.Current.CancellationToken;
        capture.Begin(At(17, 2, 5610));
        store.Clock = At(17, 2, 5610);

        // Slowed: the read waits 2 minutes, then runs once the observer is quick again, and its coverage says it waited.
        store.Access.Factor = 2;
        await capture.TickAsync(At(17, 2, 5610), capture.Timestamp(), At(17, 3), token);
        Assert.False(capture.Reading);
        Assert.Empty(store.Access.Calls);
        Assert.Equal(At(17, 4, 5610), capture.NextRead);
        store.Access.Factor = 1;
        await ReadAtAsync(capture, store, At(17, 4, 5610));
        Assert.Contains("Query Store's reads on T4 wait from 17:02:05 UTC: the observer's samples are slow (its cadence is 2 times longer), so a read takes them once they're quick again, or the end's read. Query Store keeps the intervals that ended after 15:02 UTC.", Gaps(sidecar));
        Assert.Single(store.Connector.ParameterCalls, c => c.BlockId == "RCA-PG-14");

        // Its detail stopped: no read starts for the rest of the observation, but the end's.
        store.Access.DetailStopped = true;
        store.Clock = At(17, 17, 5700);
        await capture.TickAsync(At(17, 17, 5700), capture.Timestamp(), At(17, 18), token);
        Assert.False(capture.Reading);
        Assert.Single(store.Connector.ParameterCalls, c => c.BlockId == "RCA-PG-14");
        store.Clock = At(17, 20);
        await capture.EndAsync(At(17, 20), token);
        Assert.Equal(2, store.Connector.ParameterCalls.Count(c => c.BlockId == "RCA-PG-14"));
        Assert.Contains("Query Store's reads on T4 wait from 17:17:05 UTC: the observer stopped its detail capture for the rest of the session, so the end's read takes them. Query Store keeps the intervals that ended after 16:44 UTC.", Gaps(sidecar));
    }

    [Fact]
    public async Task AReadsBlockRunsOnlyWhenItFitsBeforeTheEvidencesNextWork()
    {
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        var (capture, sidecar, _) = Capture(store, SpanA);
        var token = TestContext.Current.CancellationToken;
        var at = At(17, 2, 5610);
        capture.Begin(at);
        store.Clock = at;

        // 10 s to the evidence's next work: RCA-PG-13 and 16 fit (5 s and 1 s of margin), a block on azure_sys doesn't
        // (5 s to open and 15 s to read), and the read asks for no tick before that work.
        for (var tick = 0; tick < 4; tick++)
        {
            Assert.Equal(at.AddSeconds(10), await capture.TickAsync(at, capture.Timestamp(), at.AddSeconds(10), token));
        }

        Assert.Equal(["RCA-PG-13", "RCA-PG-16"], store.Access.Calls.Select(c => c.BlockId));
        Assert.Empty(store.Connector.Calls);
        Assert.True(capture.Reading);

        // 22 s: a block a tick, each on a connection of its own.
        await capture.TickAsync(at, capture.Timestamp(), at.AddSeconds(22), token);
        Assert.Equal(["RCA-PG-14"], store.Connector.Calls.Select(c => c.BlockId));
        Assert.Equal(1, store.Connector.Opens);
        Assert.Equal(At(17, 17), await capture.TickAsync(at, capture.Timestamp(), at.AddSeconds(22), token));
        Assert.Equal(["RCA-PG-14", "RCA-PG-15"], store.Connector.Calls.Select(c => c.BlockId));
        Assert.Equal(2, store.Connector.Opens);
        Assert.False(capture.Reading);
        Assert.Single(sidecar.Table(RcaContract.QueryCoverage));
    }

    [Fact]
    public async Task TheEndsReadsStayWithinTheirBudget()
    {
        var clock = new ManualTime(At(17, 20));
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        store.Follow(clock);
        var timings = new PgSidecarOptions { Clock = new TickClock(clock) };
        var azure = new TimedStore(clock, store.Connector, timings.OpenTimeout) { Cost = b => b == "RCA-PG-14" ? TimeSpan.FromSeconds(9.5) : TimeSpan.Zero };
        var sidecar = new MemorySidecar();
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(azure, Watermark(), new MemorySpans { CurrentSpan = SpanA }), sidecar, timings, RunnerLog.Null);
        capture.Begin(At(17, 2, 5610));

        await capture.EndAsync(At(17, 20), TestContext.Current.CancellationToken);

        // The page took 9.5 s of the 10: the waits didn't start, and the page's rows are kept unsettled for a later read.
        Assert.Equal(["RCA-PG-14"], azure.Calls.Select(c => c.BlockId));
        Assert.Equal(TimeSpan.FromSeconds(10), azure.Calls[0].Timeout);
        Assert.Equal(At(17, 20).AddSeconds(9.5), clock.Now);
        Assert.Contains("RCA-PG-15 timed out on T4's azure_sys, so the next read takes its intervals: The end's Query Store reads on T4 stopped at their bound of 10 s.", Gaps(sidecar));
        Assert.Equal(7, sidecar.Table(RcaContract.QueryStats).Count);
        Assert.Empty(sidecar.Table(RcaContract.QueryWaits));
        Assert.Null(capture.Settled);
    }

    // ---- The blocks' text --------------------------------------------------------------------------------------------

    [Fact]
    public void TheLeaveOutRuleLeavesOutTheCapturesAndTheHarnesssStatementsAndNothingElse()
    {
        var harness = PgHarness.Parse(
        [
            Row(("kind", "function"), ("name", "fn$harness_begin")),
            Row(("kind", "harness_table"), ("name", "harness_runs")),
            Row(("kind", "table"), ("name", "work_queues")),
            Row(("kind", "table"), ("name", "patients")),
        ]);
        var rule = LeaveOut.FromCatalog();

        Assert.True(rule.LeftOut("SELECT a.pid FROM pg_stat_activity AS a", "\"$user\", public, dbhubdemo_rca_observer", harness));
        Assert.True(rule.LeftOut("SELECT /* dbhubdemo:rca-observer */ clock_timestamp()", "\"$user\", public", harness));
        Assert.True(rule.LeftOut("SELECT demo.fn$harness_begin($1, $2)", null, harness));
        Assert.True(rule.LeftOut("INSERT INTO demo.harness_runs (run_id, started_at) VALUES ($1, now())", null, harness));
        Assert.True(rule.LeftOut("SELECT r.status FROM demo.harness_runs AS r WHERE r.run_id = $1 FOR UPDATE", null, harness));

        Assert.False(rule.LeftOut("UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_id = $2", "\"$user\", public", harness));
        Assert.False(rule.LeftOut("SELECT q.queue_id FROM care.work_queues AS q JOIN demo.harness_runs AS r ON r.run_id = q.run_id", null, harness));
        Assert.False(rule.LeftOut("SELECT pg_sleep($1)", null, harness));
        Assert.False(rule.LeftOut("SELECT demo.fn$harness_beginning($1)", null, harness));
        Assert.False(rule.LeftOut("SELECT p.patient_id FROM care.patients AS p WHERE p.patient_id = $1", null, harness));

        // With no function marked (the demo's marks come later), the harness's statements stay, and so does everything else.
        var none = PgHarness.Parse([Row(("kind", "table"), ("name", "harness_runs")), Row(("kind", "table"), ("name", "work_queues"))]);
        Assert.False(rule.LeftOut("SELECT demo.fn$harness_begin($1, $2)", null, none));
        Assert.False(rule.LeftOut("INSERT INTO demo.harness_runs (run_id, started_at) VALUES ($1, now())", null, none));
        Assert.True(rule.LeftOut("SELECT 1", "dbhubdemo_rca_observer", none));
    }

    [Fact]
    public void TheTextRuleLeavesOutEveryStatementTheObserverSendsTodayAndAtEdd01c86()
    {
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        var earlier = CaptureCatalog.Parse(RcaPgCatalogHistory.Edd01c86).Where(b => b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal)).ToList();
        Assert.Equal(12, earlier.Count);
        Assert.All(earlier, b => Assert.DoesNotContain("dbhubdemo", b.Value, StringComparison.Ordinal));
        foreach (var (id, text) in CaptureCatalog.All.Where(b => b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal)).Concat(earlier))
        {
            // As Query Store may keep it, under the workload's role and search_path: as sent, without its final semicolon,
            // or with a comment before it and its white space changed.
            foreach (var kept in new[] { text, text.TrimEnd(';'), "/* sent */ " + WhiteSpace().Replace(text, "\n    ") })
            {
                Assert.True(rule.LeftOut(kept, WorkloadPath, none), id);
            }
        }

        Assert.True(rule.LeftOut(PgCaptureConnector.ClearSnapshot, WorkloadPath, none));
    }

    [Fact]
    public void TheTextRuleKeepsAWorkloadStatementThatReadsTheSameViewsDifferently()
    {
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        var connections = CaptureCatalog.Parse(RcaPgCatalogHistory.Edd01c86)["RCA-PG-10"];
        Assert.True(rule.LeftOut(connections, WorkloadPath, none));
        foreach (var statement in new[]
        {
            "SELECT a.pid, a.state, a.query FROM pg_stat_activity AS a WHERE a.datname = current_database()",
            "SELECT count(*) FROM pg_stat_activity",
            "SELECT s.name, s.setting FROM pg_settings AS s WHERE s.name = 'max_connections'",
            connections.Replace("AS waiting_lock", "AS lock_waiters", StringComparison.Ordinal),
            connections.Replace("FROM pg_stat_activity AS a", "FROM pg_stat_activity AS a WHERE a.datname = current_database()", StringComparison.Ordinal),
            "SET statement_timeout = 120000",
            "SELECT pg_stat_clear_snapshot(), now()",
        })
        {
            Assert.False(rule.LeftOut(statement, WorkloadPath, none), statement);
        }
    }

    [Fact]
    public void WhatTheWorkloadSendsTooStaysEvidenceEvenThoughTheObserverOnceSentIt()
    {
        // Before its connections opened silently, the observer sent the session limits' SETs and Npgsql's type loading, as
        // the workload's connections still do, under the same role: Query Store keeps them in the workload's rows, so they
        // stay evidence, and $7 holds none of them.
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        foreach (var statement in new[]
        {
            Postgres.PgConnectionOpener.LimitsCommand(PgCaptureConnector.Limits),
            "SET statement_timeout = 10000",
            "SET statement_timeout = 30000",
            "SET lock_timeout = 1000",
            "SET idle_in_transaction_session_timeout = 60000",
            "SELECT version()",
        })
        {
            Assert.False(rule.LeftOut(statement, WorkloadPath, none), statement);
        }

        Assert.DoesNotContain(PgObserverStatements.All, s => s.StartsWith("SET ", StringComparison.Ordinal) || s.Contains("version()", StringComparison.Ordinal) || s.Contains("pg_type", StringComparison.Ordinal));
    }

    [Fact]
    public void AnObserversTextUnderAnotherRoleIsThatRolesEvidence()
    {
        // The text rule leaves out only the observer's own role's rows: another role that sends the same text keeps it.
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        var phase1 = CaptureCatalog.Parse(RcaPgCatalogHistory.Edd01c86)["RCA-PG-01"];

        Assert.True(rule.LeftOut(phase1, WorkloadPath, none));
        Assert.True(rule.LeftOut(phase1[..120], WorkloadPath, none, maxTextLength: 120));
        Assert.True(rule.LeftOut(PgCaptureConnector.ClearSnapshot, WorkloadPath, none));
        Assert.False(rule.LeftOut(phase1, WorkloadPath, none, ownRole: false));
        Assert.False(rule.LeftOut(phase1[..120], WorkloadPath, none, maxTextLength: 120, ownRole: false));
        Assert.False(rule.LeftOut(PgCaptureConnector.ClearSnapshot, WorkloadPath, none, ownRole: false));

        // The markers are the observer's alone, whatever the role.
        Assert.True(rule.LeftOut(phase1, "\"$user\", public, dbhubdemo_rca_observer", none, ownRole: false));
        Assert.True(rule.LeftOut(CaptureCatalog.Get("RCA-PG-01"), WorkloadPath, none, ownRole: false));
    }

    [Fact]
    public void ACutShortTextThatIsLittleButACommentOrACommonBeginningIsKept()
    {
        // At Query Store's limit, but under 64 characters once its comments are stripped: no telling it from the workload's.
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        var filler = new string('x', 300);
        foreach (var text in new[]
        {
            "-- " + filler,
            "/* " + new string('x', 85) + " */ SELECT clock_timestamp() AS captured_at, " + filler,
            "SELECT clock_timestamp() AS captured_at, -- " + filler,
            "SELECT /* " + new string('x', 60) + " */ clock_timestamp() AS captured_at, a.pid, " + filler,
        })
        {
            var cut = text[..100];
            Assert.True(rule.Normalize(cut).Length < rule.Minimum, cut);
            Assert.Contains(PgObserverStatements.All, s => rule.Normalize(s).StartsWith(rule.Normalize(cut), StringComparison.Ordinal));
            Assert.False(rule.LeftOut(cut, WorkloadPath, none, maxTextLength: 100), cut);
        }

        Assert.Equal(64, rule.Minimum);
    }

    [Fact]
    public void AnOwnStatementQueryStoreCutShortIsLeftOutByItsBeginning()
    {
        // edd01c86's blocks, which carry no marker, cut where Query Store cuts a text longer than pg_qs.max_query_text_length
        // (100 to 10,000; 6,000 by default).
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        var statements = CaptureCatalog.Parse(RcaPgCatalogHistory.Edd01c86)
            .Where(b => b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal))
            .Select(b => b.Value)
            .ToList();
        foreach (var max in new[] { 100, 1000 })
        {
            var longer = statements.Where(s => s.Length > max).ToList();
            Assert.NotEmpty(longer);
            foreach (var text in longer)
            {
                // At the limit, or one short of it (a C string keeps its terminator): one of ours, cut short.
                Assert.True(rule.LeftOut(text[..max], WorkloadPath, none, maxTextLength: max), text[..60]);
                Assert.True(rule.LeftOut(text[..(max - 1)], WorkloadPath, none, maxTextLength: max), text[..60]);

                // No limit read, or one the text doesn't reach: it's whole, so it's no statement of ours.
                Assert.False(rule.LeftOut(text[..max], WorkloadPath, none), text[..60]);
                Assert.False(rule.LeftOut(text[..max], WorkloadPath, none, maxTextLength: max + 2), text[..60]);
            }
        }
    }

    [Fact]
    public void AWorkloadTextThatBeginsLikeAnOwnStatementIsKept()
    {
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);

        // Shorter than the limit, a text is whole: the workload's, however its first words go.
        Assert.False(rule.LeftOut("SELECT clock_timestamp() AS captured_at", WorkloadPath, none, maxTextLength: 100));
        Assert.False(rule.LeftOut("SELECT a.pid, a.state FROM pg_stat_activity AS a", WorkloadPath, none, maxTextLength: 100));

        // As long as the limit, but how none of ours begins.
        var workload = "SELECT p.patient_id, p.family_name FROM care.patients AS p WHERE p.patient_id = $1 AND p.active ORDER BY p.family_name";
        Assert.False(rule.LeftOut(workload[..100], WorkloadPath, none, maxTextLength: 100));
    }

    [Fact]
    public void WhatTheObserverSentBeforeEitherMarkerIsLeftOutByItsTextAlone()
    {
        // Phase 1's statements carry neither marker: under the workload's role and search_path, only the text rule, read
        // from RCA-PG-14's own SQL with the reader's own $7, leaves them out.
        var rule = LeaveOut.FromCatalog();
        var none = PgHarness.Parse([]);
        var phase1 = CaptureCatalog.Parse(RcaPgCatalogHistory.Edd01c86)["RCA-PG-01"];

        Assert.True(rule.LeftOut(phase1, WorkloadPath, none));
        Assert.False(rule.LeftOut(phase1, WorkloadPath, none, ownStatements: []));
    }

    [Fact]
    public void TheHarnessTablesOfDatabasePostgresqlAreTheRunAndControlTables()
    {
        // H marks every function the control script creates; nothing else is marked.
        var (functions, tables) = RealSources();
        var derived = Derivation.FromCatalog().Derive(functions, tables);

        Assert.True(functions.Count(f => f.Marked) >= 10 && functions.Count(f => !f.Marked) >= 10, "database/postgresql's functions weren't all read.");
        Assert.Empty(derived.Unsure);
        Assert.Equal(["scenario_control", "scenario_run_events", "scenario_runs"], derived.HarnessTables);
        Assert.Contains("work_queues", derived.OtherTables);
        Assert.Contains("io_scratch", derived.OtherTables);
        Assert.Contains("replica_lag_marks", derived.OtherTables);
    }

    [Theory]
    [InlineData("UPDATE ONLY demo.scenario_control SET stop_requested = false WHERE scenario_id = p_id;", "scenario_control")]
    [InlineData("INSERT INTO demo.\"scenario_runs\" (run_id) VALUES (p_run);", "scenario_runs")]
    [InlineData("TRUNCATE demo.io_scratch, demo.scenario_run_events;", "scenario_run_events")]
    [InlineData("PERFORM 1 FROM demo.scenario_runs AS r WHERE r.run_id = p_run;", "scenario_runs")]
    public void ATableAnUnmarkedFunctionNamesAtAllIsTheWorkloads(string source, string table)
    {
        var (functions, tables) = RealSources();
        var before = Derivation.FromCatalog().Derive(functions, tables).HarnessTables;
        var after = Derivation.FromCatalog().Derive([.. functions, ("demo.fn_workload", false, source)], tables);

        Assert.Contains(table, before);
        Assert.DoesNotContain(table, after.HarnessTables);
        Assert.Contains(table, after.OtherTables);
        Assert.Equal(before.Where(t => t != table), after.HarnessTables);
    }

    [Theory]
    [InlineData("BEGIN EXECUTE format('DELETE FROM %I.%I', p_schema, p_table); END", "dynamic_sql", "runs dynamic SQL (EXECUTE)")]
    [InlineData("", "no_source", "keeps no source in pg_proc (a BEGIN ATOMIC body)")]
    public void DynamicSqlOrABodyWithoutSourceLeavesNoTableToTheHarness(string source, string kind, string why)
    {
        var (functions, tables) = RealSources();
        var derived = Derivation.FromCatalog().Derive([.. functions, ("demo.fn_workload", false, source)], tables);

        Assert.Empty(derived.HarnessTables);
        Assert.Equal([kind], derived.Unsure);
        var harness = PgHarness.Parse([Row(("kind", "function"), ("name", "usp_run_end")), Row(("kind", "harness_table"), ("name", "scenario_runs")), Row(("kind", "unsure"), ("name", kind))]);
        Assert.Empty(harness.HarnessTables);
        Assert.Equal($"A function in contosocare that isn't the harness's {why}, so it could write any table: no table is left out as only the harness's, and the statements the harness's functions run stay in the evidence.", harness.UnsureGap("contosocare"));
    }

    [Fact]
    public void OnlyTheHarnesssOwnCodeWritesAHarnessTableFromTheClient()
    {
        // A statement the runner sends itself is in no function, so RCA-PG-16 can't see it: none may write a harness table
        // but the harness's own typed calls.
        var (functions, tables) = RealSources();
        var harnessTables = Derivation.FromCatalog().Derive(functions, tables).HarnessTables;
        var writes = new Regex(@"(?i)\b(insert\s+into|update|delete\s+from|truncate(\s+table)?|merge\s+into)\s+(only\s+)?(""?\w+""?\.)?""?(" + string.Join('|', harnessTables) + @")\b");
        var t4 = Directory.GetFiles(RepositoryPaths.Combine("workload-generator", "src", "ContosoCare.Workload"), "*.cs", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal) && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .Where(f => f.Contains($"{Path.DirectorySeparatorChar}Postgres{Path.DirectorySeparatorChar}", StringComparison.Ordinal) || File.ReadAllText(f).Contains("Npgsql", StringComparison.Ordinal))
            .ToList();

        Assert.True(t4.Count >= 5, "The runner's T4 code wasn't found.");
        Assert.DoesNotContain(t4.Where(f => writes.IsMatch(File.ReadAllText(f))).Select(RepositoryPaths.Relative), f => f != "workload-generator/src/ContosoCare.Workload/Postgres/PgDemoDatabase.cs");
    }

    [Fact]
    public void TheReadsConvertQueryStoresTimesToUtcAndBoundEveryRead()
    {
        foreach (var (id, parameters) in new[] { ("RCA-PG-14", 7), ("RCA-PG-15", 4) })
        {
            var text = CaptureCatalog.Get(id);
            Assert.Equal(parameters, ParameterNumber().Matches(text).Select(m => int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)).Max());
            Assert.Contains("r.start_time AT TIME ZONE 'UTC' AS interval_start_utc", text, StringComparison.Ordinal);
            Assert.Contains("r.end_time AT TIME ZONE 'UTC' AS interval_end_utc", text, StringComparison.Ordinal);
            Assert.All(TimestampParameter().Matches(text), m => Assert.Equal(" AT TIME ZONE 'UTC'", m.Groups["after"].Value));
            Assert.Contains("event_type IS NOT NULL", text, StringComparison.Ordinal);
        }

        Assert.Equal(2, TimestampParameter().Count(CaptureCatalog.Get("RCA-PG-15")));
        Assert.Contains("LIMIT " + PgQueryStoreReader.PageRows.ToString(CultureInfo.InvariantCulture) + ";", CaptureCatalog.Get("RCA-PG-14"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task OnlyTheObserversConnectionsCarryTheMarkerAndTheirLimitsInTheirStartupPacket()
    {
        using var server = new ListeningPostgres();
        var endpoint = Postgres.PgEndpoint.Create("127.0.0.1:" + server.Port.ToString(CultureInfo.InvariantCulture), null, passwordFromEnvironment: true, managedIdentityClientId: null);
        using var credentials = new TestCredentials();
        foreach (var (connector, database, statementTimeout) in new[] { (new PgCaptureConnector(endpoint, RunnerLog.Null), "contosocare", 10_000), (PgCaptureConnector.QueryStore(endpoint, RunnerLog.Null), "azure_sys", 30_000) })
        {
            // A silent open sends nothing before its caller's first statement, so it opens on a server that answers nothing.
            var accepted = server.AcceptAsync(TestContext.Current.CancellationToken);
            var connection = await connector.OpenAsync(TestContext.Current.CancellationToken);
            await connection.DisposeAsync();
            var (startup, queries) = await accepted;

            Assert.Empty(queries);
            Assert.Equal(ApplicationNames.Observer, startup["application_name"]);
            Assert.Equal(database, startup["database"]);

            // As the server splits the options (a backslash escapes a space): the server's default search_path with the
            // marker last, then the session limits.
            Assert.Equal(
                ["-c", "search_path=\"$user\", public, dbhubdemo_rca_observer", "-c", $"statement_timeout={statementTimeout}", "-c", "lock_timeout=1000", "-c", "idle_in_transaction_session_timeout=60000"],
                SplitOptions(startup["options"]));
        }

        // Any other connection the runner opens carries no options and loads types: Npgsql's type loading comes first.
        var other = server.AcceptAsync(TestContext.Current.CancellationToken);
        await Assert.ThrowsAnyAsync<Exception>(() => new Postgres.PgConnectionOpener(endpoint, RunnerLog.Null).OpenAsync(ApplicationNames.Program + "/control/status", TestContext.Current.CancellationToken, retry: false));
        var (plain, sent) = await other;
        Assert.False(plain.ContainsKey("options"));
        Assert.DoesNotContain(PgCaptureConnector.ObserverSchema, plain.GetValueOrDefault("search_path") ?? string.Empty, StringComparison.Ordinal);
        Assert.Contains(sent, q => q.Contains("SELECT version()", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TheObserversConnectionsSendOnlyTheirOwnStatementsAndReadEveryTypeWithoutLoadingTypes()
    {
        // A column of each type the PostgreSQL blocks return (their SELECT lists: reg* values, LSNs, and xids come as text),
        // in binary, as Npgsql asks for it. With no type loading, Npgsql knows PostgreSQL's built-in types only.
        var at = new DateTimeOffset(2026, 11, 20, 17, 0, 1, 250, TimeSpan.Zero);
        var columns = new (string Name, uint Oid, byte[]? Value, object? Expected)[]
        {
            ("captured_at", 1184, Wire.Timestamp(at), at.UtcDateTime),
            ("interval_start_utc", 1114, Wire.Timestamp(at), at.UtcDateTime),
            ("pid", 23, Wire.Int32(20432), 20432),
            ("tuple", 21, Wire.Int16(7), (short)7),
            ("query_id", 20, Wire.Int64(-6412873301142229951), -6412873301142229951L),
            ("usename", 19, Wire.Text("contosocare_runner"), "contosocare_runner"),
            ("query", 25, Wire.Text("UPDATE care.work_queues SET status = $1"), "UPDATE care.work_queues SET status = $1"),
            ("xact_age_s", 1700, Wire.Numeric(weight: 0, scale: 1, 12, 5000), 12.5m),
            ("blk_read_time", 701, Wire.Float8(1.25), 1.25),
            ("in_recovery", 16, [1], true),
            ("blocked_by", 1007, Wire.Int32Array(9772, 20584), new[] { 9772, 20584 }),
            ("relation", 25, null, null),
        };
        using var server = new ListeningPostgres(query => query == PgCaptureConnector.ClearSnapshot
            ? [("pg_stat_clear_snapshot", 2278u, [])]
            : [.. columns.Select(c => (c.Name, c.Oid, c.Value))]);
        var endpoint = Postgres.PgEndpoint.Create("127.0.0.1:" + server.Port.ToString(CultureInfo.InvariantCulture), null, passwordFromEnvironment: true, managedIdentityClientId: null);
        using var credentials = new TestCredentials();
        var accepted = server.AcceptAsync(TestContext.Current.CancellationToken);

        // RCA-PG-14 with every kind of parameter the blocks take: text, timestamptz, text[], and the list of own statements.
        var connection = await new PgCaptureConnector(endpoint, RunnerLog.Null).OpenAsync(TestContext.Current.CancellationToken);
        IReadOnlyList<CaptureValues> rows;
        try
        {
            rows = await connection.QueryAsync(
                "RCA-PG-14",
                CaptureCatalog.Get("RCA-PG-14"),
                CaptureParameters.Positional("contosocare", at, MarkedFunction, Array.Empty<string>(), OtherTable, at.AddMinutes(15), PgObserverStatements.All.ToArray()),
                TimeSpan.FromSeconds(10),
                TestContext.Current.CancellationToken);
        }
        finally
        {
            await connection.DisposeAsync();
        }

        var (_, sent) = await accepted;
        var row = Assert.Single(rows);
        foreach (var (name, _, _, expected) in columns)
        {
            Assert.Equal(expected, row.Raw[name]);
        }

        Assert.Equal(DateTimeKind.Utc, ((DateTime)row.Raw["captured_at"]!).Kind);
        Assert.All(server.ResultFormats, f => Assert.Equal(new short[] { 1 }, f));

        // All it sent were its own statements, in $7: the snapshot clear and the block. No SET, and no type loading.
        Assert.Equal([PgCaptureConnector.ClearSnapshot, CaptureCatalog.Get("RCA-PG-14")], sent);
        Assert.All(sent, s => Assert.Contains(s, PgObserverStatements.All));
    }

    // ---- Helpers -----------------------------------------------------------------------------------------------------

    /// <summary>The workload's own search_path on T4: the server's default.</summary>
    private const string WorkloadPath = "\"$user\", public";

    /// <summary>RCA-PG-14's text[] parameters in the wire test: a marked function, and a table others write.</summary>
    private static readonly string[] MarkedFunction = ["fn_harness_event"];

    private static readonly string[] OtherTable = ["patients"];

    /// <summary>
    /// database/postgresql's functions and tables as RCA-PG-16 reads them from the catalog: each function's source (its
    /// dollar-quoted body, which pg_proc keeps as prosrc), marked when the control script creates it, as H will mark it.
    /// </summary>
    private static (List<(string Name, bool Marked, string Source)> Functions, List<string> Tables) RealSources()
    {
        var functions = new List<(string Name, bool Marked, string Source)>();
        var tables = new List<string>();
        foreach (var file in Directory.GetFiles(RepositoryPaths.Combine("database", "postgresql"), "*.sql").Order(StringComparer.Ordinal))
        {
            var text = File.ReadAllText(file).Replace("\r\n", "\n", StringComparison.Ordinal);
            var marked = string.Equals(Path.GetFileName(file), "110-demo-control.sql", StringComparison.Ordinal);
            foreach (Match header in FunctionHeader().Matches(text))
            {
                var body = DollarBody().Match(text, header.Index + header.Length);
                Assert.True(body.Success, $"{header.Groups["name"].Value} in {Path.GetFileName(file)} has no dollar-quoted body this test reads.");
                functions.Add((header.Groups["name"].Value, marked, body.Groups["body"].Value));
            }

            tables.AddRange(TableHeader().Matches(text).Select(m => m.Groups["name"].Value));
        }

        return (functions, tables);
    }

    /// <summary>A startup packet's options as the server splits them: at white space, a backslash escaping the next character.</summary>
    private static List<string> SplitOptions(string options)
    {
        var words = new List<string>();
        var word = new System.Text.StringBuilder();
        var escaped = false;
        var inWord = false;
        foreach (var c in options)
        {
            if (escaped)
            {
                word.Append(c);
                escaped = false;
            }
            else if (c == '\\')
            {
                escaped = true;
                inWord = true;
            }
            else if (char.IsWhiteSpace(c))
            {
                if (inWord)
                {
                    words.Add(word.ToString());
                    word.Clear();
                    inWord = false;
                }
            }
            else
            {
                word.Append(c);
                inWord = true;
            }
        }

        if (inWord)
        {
            words.Add(word.ToString());
        }

        return words;
    }

    [GeneratedRegex(@"^CREATE (?:OR REPLACE )?(?:FUNCTION|PROCEDURE) (?<name>[\w.]+)\s*\(", RegexOptions.Multiline)]
    private static partial Regex FunctionHeader();

    [GeneratedRegex(@"\bAS\s+\$(?<tag>\w*)\$(?<body>.*?)\$\k<tag>\$", RegexOptions.Singleline)]
    private static partial Regex DollarBody();

    [GeneratedRegex(@"^\s*CREATE (?:UNLOGGED )?TABLE (?:IF NOT EXISTS )?\w+\.(?<name>\w+)", RegexOptions.Multiline)]
    private static partial Regex TableHeader();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhiteSpace();

    private QueryWatermark Watermark() => new(root, "T4");

    private (PgQueryStoreCapture Capture, MemorySidecar Sidecar, QueryWatermark Watermark) Capture(T4QueryStore store, string span)
    {
        var sidecar = new MemorySidecar();
        var watermark = Watermark();
        var capture = new PgQueryStoreCapture(store.Access, new PgQueryStoreSource(store.Connector, watermark, new MemorySpans { CurrentSpan = span }), sidecar, new PgSidecarOptions(), RunnerLog.Null);
        return (capture, sidecar, watermark);
    }

    /// <summary>
    /// Begins the capture at its first read, and reads at <paramref name="at"/>, as the observer's ticks do: a block a tick,
    /// with the evidence's next work 30 s away, until the read is done.
    /// </summary>
    private static async Task ReadAtAsync(PgQueryStoreCapture capture, T4QueryStore store, DateTimeOffset at)
    {
        if (capture.NextRead == DateTimeOffset.MaxValue)
        {
            capture.Begin(at);
        }

        store.Clock = at;
        Assert.True(at >= capture.NextRead, $"No read is due at {at:HH:mm:ss.fff}; the next is at {capture.NextRead:HH:mm:ss.fff}.");
        do
        {
            await capture.TickAsync(at, capture.Timestamp(), at.AddSeconds(30), TestContext.Current.CancellationToken);
        }
        while (capture.Reading);
    }

    /// <summary>The gaps of every coverage row, one per line.</summary>
    private static List<string> Gaps(MemorySidecar sidecar) =>
        [.. sidecar.Table(RcaContract.QueryCoverage).Select(r => (string?)r.Get("gaps")).OfType<string>().SelectMany(g => g.Split('\n'))];

    /// <summary>
    /// What the sidecar's export makes of one target's coverage rows in a sidecar: Query Store's state as last read, the
    /// intervals read from the first to the last, the time still pending as the last row has it, every source and gap.
    /// </summary>
    private static Dictionary<string, object?> Merge(List<CaptureRow> rows)
    {
        var last = rows[^1];
        var read = rows.LastOrDefault(r => r.Get("capture_mode") is not null) ?? last;
        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["target"] = last.Target,
            ["state"] = read.Get("state"),
            ["capture_mode"] = read.Get("capture_mode"),
            ["interval_minutes"] = read.Get("interval_minutes") is int minutes ? (long)minutes : null,
            ["read_from_utc"] = rows.Select(r => (DateTimeOffset?)r.Get("read_from_utc")).Min(),
            ["read_to_utc"] = rows.Select(r => (DateTimeOffset?)r.Get("read_to_utc")).Max(),
            ["pending_from_utc"] = last.Get("pending_from_utc"),
            ["pending_to_utc"] = last.Get("pending_to_utc"),
            ["backfill"] = rows.Any(r => r.Get("backfill") is true),
            ["sources"] = string.Join(',', rows.Select(r => (string?)r.Get("sources")).OfType<string>().SelectMany(s => s.Split(',')).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)) is { Length: > 0 } sources ? sources : null,
            ["gaps"] = string.Join('\n', rows.Select(r => (string?)r.Get("gaps")).OfType<string>().SelectMany(g => g.Split('\n')).Distinct(StringComparer.Ordinal)) is { Length: > 0 } gaps ? gaps : null,
        };
    }

    private static void AssertSameRows(List<Dictionary<string, object?>> expected, List<CaptureRow> actual, params string[] key) => AssertSameRows(expected, actual, [], key);

    private static void AssertSameRows(List<Dictionary<string, object?>> expected, List<CaptureRow> actual, string[] ignore, params string[] key)
    {
        Assert.Equal(expected.Count, actual.Count);
        foreach (var row in expected)
        {
            var match = Assert.Single(actual, a => key.All(k => Equals(row.GetValueOrDefault(k), Normalize(a.Get(k)))));
            AssertSameRow(row, match, string.Join(", ", key.Select(k => row.GetValueOrDefault(k))), ignore);
        }
    }

    private static void AssertSameRow(Dictionary<string, object?> expected, CaptureRow actual, string because, params string[] ignore)
    {
        foreach (var column in RcaContract.Table(actual.Table).Columns.Select(c => c.Name).Except(ignore, StringComparer.Ordinal))
        {
            var want = expected.GetValueOrDefault(column);
            var got = Normalize(actual.Get(column));
            Assert.True(Equals(want, got), $"{because}: {column} is {got ?? "null"}, not {want ?? "null"}.");
        }
    }

    private static object? Normalize(object? value) => value switch
    {
        int number => (long)number,
        DateTimeOffset time => time.ToUniversalTime(),
        _ => value,
    };

    /// <summary>The evidence rows as the store writes them, byte for byte.</summary>
    private static List<string> Lines(MemorySink sink) => [.. sink.Rows.Select(r => System.Text.Encoding.UTF8.GetString(StoredLines.Row(r)))];

    /// <summary>The sidecar's blocks: none may reach the evidence document.</summary>
    private static readonly string[] SidecarBlocks = ["RCA-PG-13", "RCA-PG-14", "RCA-PG-15", "RCA-PG-16", "RCA-PG-17"];

    private static string Note(CaptureNote note) => string.Create(CultureInfo.InvariantCulture, $"{note.Kind}|{note.Target}|{note.At:O}|{note.Text}");

    /// <summary>The watermarks in order, each once while it stays the same.</summary>
    private static List<DateTimeOffset> Distinct(List<DateTimeOffset> marks) => [.. marks.Where((m, i) => i == 0 || m != marks[i - 1])];

    /// <summary>
    /// T4's simulated session (RcaSimulation's chain under an idle transaction, 17:00 to 17:20, with a connection surge from
    /// 17:16 to 17:17, whose episode holds the 17:17 read back until it ends at 17:18), driven as the lane drives it, by a
    /// clock the test's blocks move: the evidence as the store writes it,
    /// its notes, its watermarks, and the connectors. With a sink, Query Store is read too, and the surge's holders.
    /// </summary>
    private async Task<T4Run> RunT4Async(bool sink, Action<TimedT4, TimedStore>? setUp = null, Action<MarkLog>? spanSetUp = null, CancellationToken? end = null)
    {
        var clock = new ManualTime(RcaSimulation.T4From);
        var store = new T4QueryStore(T4Statistics(), T4Waits());
        store.Follow(clock);
        var timings = new PgSidecarOptions { Clock = new TickClock(clock) };
        var observer = new TimedT4(clock, RcaSimulation.T4Primary(clock), block => block == "RCA-PG-17"
            ? [HolderRow(clock.Now, ApplicationNames.Program + "/svc-intake/20261120170000-t4-0a0b0c", Runner, "idle", 40, 0, 12.5, 60)]
            : store.ObserverAnswer(block))
        {
            Surge = (At(17, 16), At(17, 17)),
        };
        var azure = new TimedStore(clock, store.Connector, timings.OpenTimeout);
        setUp?.Invoke(observer, azure);
        var span = new MarkLog(new MemorySink());
        spanSetUp?.Invoke(span);
        var sidecar = sink ? new MemorySidecar() : null;
        var source = new PgQueryStoreSource(azure, new QueryWatermark(Path.Combine(root, Guid.NewGuid().ToString("N")), "T4"), new MemorySpans { CurrentSpan = SpanA });
        var primary = sidecar is null
            ? new PgPrimaryObserver(observer, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink())
            : new PgPrimaryObserver(observer, RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), sidecar, source, timings);

        var ended = await LaneAsync(primary, span, clock, RcaSimulation.T4From, RcaSimulation.T4To, end);

        return new T4Run(Lines(span.Inner), [.. span.Inner.Notes.Select(Note)], Distinct(span.Marks), span.Inner.Watermarks["T4"], ended, span.Inner.Membership, observer, azure, sidecar);
    }

    /// <summary>
    /// Drives one observer as ObserverLane does, by a clock a slow block moves: begins it at <paramref name="from"/>, and ticks
    /// it when it says, 50 ms to 1 s after its last tick ended, until <paramref name="to"/>.
    /// </summary>
    private static async Task RunUntilAsync(TargetObserver observer, ICaptureSpan span, ManualTime clock, DateTimeOffset from, DateTimeOffset to)
    {
        var token = TestContext.Current.CancellationToken;
        clock.Set(from);
        span.Began(observer.Target, from);
        await observer.BeginAsync(span, from, token);
        while (clock.Now < to)
        {
            var next = await observer.TickAsync(clock.Now, token);
            var after = clock.Now;
            var delay = next - after;
            delay = delay < TimeSpan.FromMilliseconds(50) ? TimeSpan.FromMilliseconds(50) : delay > TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : delay;
            clock.Set(after + delay);
        }
    }

    /// <summary>
    /// <see cref="RunUntilAsync"/>, then ends the observer at <paramref name="to"/>, with its clock, as the lane does, and
    /// <paramref name="end"/> as the token when given. The span's end is the time EndAsync's hook gets: the clock's when the
    /// evidence's own end was done, as the lane takes it. Returns that time.
    /// </summary>
    private static async Task<DateTimeOffset> LaneAsync(TargetObserver observer, ICaptureSpan span, ManualTime clock, DateTimeOffset from, DateTimeOffset to, CancellationToken? end = null)
    {
        await RunUntilAsync(observer, span, clock, from, to);
        DateTimeOffset? ended = null;
        await observer.EndAsync(to, end ?? TestContext.Current.CancellationToken, at => ended = at, clock);
        Assert.NotNull(ended);
        span.Ended(observer.Target, ended.Value);
        return ended.Value;
    }

    private static CaptureValues With(CaptureValues row, string column, object? value)
    {
        var values = row.Raw.ToDictionary(v => v.Key, v => v.Value, StringComparer.OrdinalIgnoreCase);
        values[column] = value;
        return new CaptureValues(values);
    }

    /// <summary>
    /// PostgreSQL's regular expressions in .NET's: \m starts a word and \M ends one; [:alnum:] is a letter or a digit
    /// (https://www.postgresql.org/docs/18/functions-matching.html#POSIX-CONSTRAINT-ESCAPES-TABLE).
    /// </summary>
    private static string Pg(string pattern) => pattern
        .Replace("\\m", "\\b(?=\\w)", StringComparison.Ordinal)
        .Replace("\\M", "\\b(?<=\\w)", StringComparison.Ordinal)
        .Replace("[:alnum:]", "\\p{L}\\p{N}", StringComparison.Ordinal);

    [GeneratedRegex(@"\$(\d+)::")]
    private static partial Regex ParameterNumber();

    [GeneratedRegex(@"\$\d+::timestamptz\)?(?<after> AT TIME ZONE 'UTC')?")]
    private static partial Regex TimestampParameter();

    /// <summary>
    /// RCA-PG-14's leave-out, evaluated in .NET from the block's own patterns: the observer's search_path and marker; in a
    /// row of the observer's own role, its own statements by their text ($7, normalized as the block normalizes both sides),
    /// whole or, at Query Store's text limit and long enough, by their beginning; a call of a harness function ($3); and a
    /// statement that names a table only the harness writes ($4) and no other ($5).
    /// </summary>
    private sealed partial class LeaveOut(Dictionary<int, (string Before, string After)> patterns, string comment, string line, string space, int minimum)
    {
        public static LeaveOut FromCatalog()
        {
            var text = CaptureCatalog.Get("RCA-PG-14");
            Assert.Contains("COALESCE(q.search_path, '') NOT LIKE '%dbhubdemo_rca_observer%'", text, StringComparison.Ordinal);
            Assert.Contains("q.query_sql_text NOT LIKE '%dbhubdemo:rca-observer%'", text, StringComparison.Ordinal);
            var patterns = ArrayPattern().Matches(text).ToDictionary(m => int.Parse(m.Groups["n"].Value, CultureInfo.InvariantCulture), m => (m.Groups["before"].Value, m.Groups["after"].Value));
            Assert.Equal([3, 4, 5], patterns.Keys.Order());
            var normalized = NormalizedText().Match(text);
            Assert.True(normalized.Success, "RCA-PG-14 no longer normalizes Query Store's text once, in the form this test reads.");
            var rule = TextRule().Match(text);
            Assert.True(rule.Success, "RCA-PG-14 no longer compares Query Store's text with $7's, for the observer's own role, in the form this test reads.");
            Assert.Equal(
                (normalized.Groups["comment"].Value, normalized.Groups["line"].Value, normalized.Groups["space"].Value),
                (rule.Groups["comment"].Value, rule.Groups["line"].Value, rule.Groups["space"].Value));
            return new LeaveOut(patterns, rule.Groups["comment"].Value, rule.Groups["line"].Value, rule.Groups["space"].Value, int.Parse(rule.Groups["minimum"].Value, CultureInfo.InvariantCulture));
        }

        /// <summary>How long a cut-short text must be, normalized, to be taken for the beginning of one of $7's.</summary>
        public int Minimum => minimum;

        /// <summary>A text as RCA-PG-14 compares it: comments stripped, white space collapsed, a final semicolon dropped.</summary>
        public string Normalize(string text)
        {
            var result = Regex.Replace(text, comment, " ", RegexOptions.Singleline);
            result = Regex.Replace(result, line, " ");
            result = Regex.Replace(result, space, " ");
            return result.Trim(' ', ';');
        }

        /// <summary>
        /// Whether RCA-PG-14 leaves the text out. <paramref name="maxTextLength"/> is pg_qs.max_query_text_length as
        /// pg_settings has it, or null when it doesn't: a text within one byte of it was cut short. <paramref name="ownRole"/>
        /// is whether the row's role is the observer's own (current_user), as the workload's is.
        /// </summary>
        public bool LeftOut(string text, string? searchPath, PgHarness harness, IReadOnlyList<string>? ownStatements = null, int? maxTextLength = null, bool ownRole = true)
        {
            if ((searchPath ?? string.Empty).Contains("dbhubdemo_rca_observer", StringComparison.Ordinal) || text.Contains("dbhubdemo:rca-observer", StringComparison.Ordinal))
            {
                return true;
            }

            if (ownRole)
            {
                var normalized = Normalize(text);
                var own = (ownStatements ?? PgObserverStatements.All).Select(Normalize).ToList();
                if (own.Contains(normalized, StringComparer.Ordinal))
                {
                    return true;
                }

                if (normalized.Length >= minimum && maxTextLength is { } max && System.Text.Encoding.UTF8.GetByteCount(text) + 1 >= max && own.Any(o => o.StartsWith(normalized, StringComparison.Ordinal)))
                {
                    return true;
                }
            }

            return (harness.Functions.Count > 0 && Matches(3, harness.Functions, text))
                || (harness.HarnessTables.Count > 0 && Matches(4, harness.HarnessTables, text) && !(harness.OtherTables.Count > 0 && Matches(5, harness.OtherTables, text)));
        }

        private bool Matches(int parameter, IReadOnlyList<string> names, string text) =>
            Regex.IsMatch(text, Pg(patterns[parameter].Before + string.Join('|', names) + patterns[parameter].After), RegexOptions.IgnoreCase);

        [GeneratedRegex(@"~\* \('(?<before>[^']*)' \|\| array_to_string\(\$(?<n>\d)::text\[\], '\|'\) \|\| '(?<after>[^']*)'\)")]
        private static partial Regex ArrayPattern();

        [GeneratedRegex(@"FROM query_store\.qs_view AS q\s+CROSS JOIN LATERAL \(SELECT btrim\(regexp_replace\(regexp_replace\(regexp_replace\(COALESCE\(q\.query_sql_text, ''\), '(?<comment>[^']*)', ' ', 'g'\), '(?<line>[^']*)', ' ', 'g'\), '(?<space>[^']*)', ' ', 'g'\), ' ' \|\| chr\(59\)\) AS statement\) AS n\s+WHERE ")]
        private static partial Regex NormalizedText();

        [GeneratedRegex(@"AND NOT CASE WHEN NOT COALESCE\(q\.user_id = \(SELECT a\.oid FROM pg_roles AS a WHERE a\.rolname = current_user\), false\) THEN false\s+WHEN n\.statement IN \(SELECT btrim\(regexp_replace\(regexp_replace\(regexp_replace\(o\.statement, '(?<comment>[^']*)', ' ', 'g'\), '(?<line>[^']*)', ' ', 'g'\), '(?<space>[^']*)', ' ', 'g'\), ' ' \|\| chr\(59\)\)\s+FROM unnest\(\$7::text\[\]\) AS o\(statement\)\) THEN true\s+WHEN char_length\(n\.statement\) < (?<minimum>\d+)\s+OR octet_length\(COALESCE\(q\.query_sql_text, ''\)\) \+ 1\s+< COALESCE\(\(SELECT NULLIF\(m\.setting, ''\)::integer FROM pg_settings AS m WHERE m\.name = 'pg_qs\.max_query_text_length'\), 2147483647\) THEN false\s+ELSE EXISTS \(SELECT 1\s+FROM unnest\(\$7::text\[\]\) AS t\(statement\)\s+WHERE starts_with\(btrim\(regexp_replace\(regexp_replace\(regexp_replace\(t\.statement, '\k<comment>', ' ', 'g'\), '\k<line>', ' ', 'g'\), '\k<space>', ' ', 'g'\), ' ' \|\| chr\(59\)\), n\.statement\)\)\s+END")]
        private static partial Regex TextRule();
    }
    /// <summary>
    /// RCA-PG-16's derivation, evaluated in .NET from the block's own patterns: a marked function writes a table, an
    /// unmarked one names it at all, and an unmarked one that runs dynamic SQL or keeps no source makes it unsure.
    /// </summary>
    private sealed partial class Derivation(string writePrefix, string writeSuffix, string mentionPrefix, string mentionSuffix, string anything, string dynamic)
    {
        public static Derivation FromCatalog()
        {
            var block = CaptureCatalog.Get("RCA-PG-16");
            var write = WriteRule().Match(block);
            var mention = MentionRule().Match(block);
            var unsure = UnsureRule().Match(block);
            Assert.True(write.Success && mention.Success && unsure.Success, "RCA-PG-16 no longer has its three rules in the form this test reads.");
            Assert.Contains("CASE WHEN t.by_harness AND NOT t.by_other AND NOT t.unsure THEN 'harness_table' ELSE 'table' END", block, StringComparison.Ordinal);
            Assert.Contains("CASE WHEN u.prosrc !~ '" + unsure.Groups["anything"].Value + "' THEN 'no_source' ELSE 'dynamic_sql' END", block, StringComparison.Ordinal);
            return new Derivation(write.Groups["prefix"].Value, write.Groups["suffix"].Value, mention.Groups["prefix"].Value, mention.Groups["suffix"].Value, unsure.Groups["anything"].Value, unsure.Groups["dynamic"].Value);
        }

        /// <summary>What RCA-PG-16 returns for these functions and tables: its harness tables, other tables, and unsure kinds.</summary>
        public (List<string> HarnessTables, List<string> OtherTables, List<string> Unsure) Derive(IReadOnlyList<(string Name, bool Marked, string Source)> functions, IReadOnlyList<string> tables)
        {
            var unsure = functions
                .Where(f => !f.Marked && (!Regex.IsMatch(f.Source, Pg(anything)) || Regex.IsMatch(f.Source, Pg(dynamic), RegexOptions.IgnoreCase)))
                .Select(f => Regex.IsMatch(f.Source, Pg(anything)) ? "dynamic_sql" : "no_source")
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToList();
            var harness = new List<string>();
            var other = new List<string>();
            foreach (var table in tables.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
            {
                var byHarness = functions.Any(f => f.Marked && Regex.IsMatch(f.Source, Pg(writePrefix + PgHarness.Literal(table) + writeSuffix), RegexOptions.IgnoreCase));
                var byOther = functions.Any(f => !f.Marked && Regex.IsMatch(f.Source, Pg(mentionPrefix + PgHarness.Literal(table) + mentionSuffix), RegexOptions.IgnoreCase));
                (byHarness && !byOther && unsure.Count == 0 ? harness : other).Add(table);
            }

            return (harness, other, unsure);
        }

        [GeneratedRegex(@"bool_or\(f\.harness AND f\.prosrc ~\* \('(?<prefix>[^']*)' \|\| regexp_replace\(c\.relname, '\\W', '\\\\\\&', 'g'\) \|\| '(?<suffix>[^']*)'\)\)")]
        private static partial Regex WriteRule();

        [GeneratedRegex(@"bool_or\(NOT f\.harness AND f\.prosrc ~\* \('(?<prefix>[^']*)' \|\| regexp_replace\(c\.relname, '\\W', '\\\\\\&', 'g'\) \|\| '(?<suffix>[^']*)'\)\)")]
        private static partial Regex MentionRule();

        [GeneratedRegex(@"bool_or\(NOT f\.harness AND \(f\.prosrc !~ '(?<anything>[^']*)' OR f\.prosrc ~\* '(?<dynamic>[^']*)'\)\)")]
        private static partial Regex UnsureRule();
    }

    /// <summary>One identity run: the evidence as the store writes it, its notes and watermarks, the span's end, the connectors, and the sidecar.</summary>
    private sealed record T4Run(List<string> Rows, List<string> Notes, List<DateTimeOffset> Marks, DateTimeOffset Final, DateTimeOffset Ended, List<(string Target, DateTimeOffset At, bool Began)> Membership, TimedT4 Observer, TimedStore Store, MemorySidecar? Sidecar);

    /// <summary>A clock whose timestamps follow a <see cref="ManualTime"/>, so the sidecar's room and budget measure what the test's blocks cost.</summary>
    private sealed class TickClock(ManualTime time) : TimeProvider
    {
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;

        public override DateTimeOffset GetUtcNow() => time.GetUtcNow();

        public override long GetTimestamp() => time.GetUtcNow().UtcTicks;
    }

    /// <summary>A span that keeps what a <see cref="MemorySink"/> keeps, and every watermark in order; its writes can fail from a moment on.</summary>
    private sealed class MarkLog(MemorySink inner) : ICaptureSpan
    {
        public MemorySink Inner => inner;

        public List<DateTimeOffset> Marks { get; } = [];

        /// <summary>When set, a row or note at or after it throws, as an evidence store that failed would.</summary>
        public DateTimeOffset? FailWritesFrom { get; set; }

        /// <summary>When set, a watermark at or after it throws.</summary>
        public DateTimeOffset? FailWatermarksFrom { get; set; }

        /// <summary>Runs as each watermark is written, before it's kept: a test's moment in the evidence's own end.</summary>
        public Action<DateTimeOffset>? OnWatermark { get; set; }

        public void Write(CaptureRow row)
        {
            if (row.At >= FailWritesFrom)
            {
                throw new IOException("The evidence store failed (a test's).");
            }

            inner.Write(row);
        }

        public void Note(CaptureNote note)
        {
            if (note.At >= FailWritesFrom)
            {
                throw new IOException("The evidence store failed (a test's).");
            }

            inner.Note(note);
        }

        public void Watermark(string target, DateTimeOffset complete)
        {
            OnWatermark?.Invoke(complete);
            if (complete >= FailWatermarksFrom)
            {
                throw new IOException("The watermark couldn't be written (a test's).");
            }

            Marks.Add(complete);
            inner.Watermark(target, complete);
        }

        public void Began(string target, DateTimeOffset at) => inner.Began(target, at);

        public void Ended(string target, DateTimeOffset at) => inner.Ended(target, at);

        public void Close(DateTimeOffset at) => inner.Close(at);
    }

    /// <summary>
    /// T4's observer connection, or its replica's, for the identity runs: the evidence blocks as <c>evidence</c>'s connection
    /// answers them, with a connection surge on RCA-PG-10 when set; the sidecar's blocks (RCA-PG-13, 16, 17) as
    /// <c>sidecar</c> answers them. A sidecar block can cost time (the clock moves by it; past its timeout, by the timeout,
    /// and it fails as a statement timeout does), fail, or throw. The connection can break at a moment: a sidecar block at
    /// it, or any block after it, fails on the connection that was open then, as does every later block on it.
    /// </summary>
    private sealed class TimedT4(ManualTime clock, ICaptureConnector evidence, Func<string, IReadOnlyList<CaptureValues>?> sidecar) : ICaptureConnector
    {
        public const string TransportError = "Exception while reading from stream (a test's broken connection).";

        private static readonly HashSet<string> Quiet = new(StringComparer.Ordinal) { "RCA-PG-13", "RCA-PG-16", "RCA-PG-17" };

        public List<(DateTimeOffset At, string BlockId, TimeSpan Timeout)> Calls { get; } = [];

        public List<(DateTimeOffset At, string BlockId)> Failures { get; } = [];

        public int Opens { get; private set; }

        public Func<string, TimeSpan> Cost { get; set; } = _ => TimeSpan.Zero;

        public Func<string, Exception?> Failure { get; set; } = _ => null;

        public DateTimeOffset? BreakAt { get; set; }

        public (DateTimeOffset From, DateTimeOffset To)? Surge { get; set; }

        public string Description => "timed";

        /// <summary>The test's clock now, so a cost can start at a moment (the end's reads).</summary>
        public DateTimeOffset Now => clock.Now;

        public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
        {
            var inner = await evidence.OpenAsync(cancellationToken);
            Opens++;
            return new Connection(this, clock.Now, inner);
        }

        private sealed class Connection(TimedT4 owner, DateTimeOffset opened, ICaptureConnection inner) : ICaptureConnection
        {
            private bool broken;

            public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken) =>
                RunAsync(blockId, text, parameter, null, timeout, cancellationToken);

            public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken) =>
                RunAsync(blockId, text, null, parameters, timeout, cancellationToken);

            public ValueTask DisposeAsync() => inner.DisposeAsync();

            private async Task<IReadOnlyList<CaptureValues>> RunAsync(string blockId, string text, int[]? parameter, CaptureParameters? parameters, TimeSpan timeout, CancellationToken cancellationToken)
            {
                var at = owner.Clock.Now;
                owner.Calls.Add((at, blockId, timeout));
                cancellationToken.ThrowIfCancellationRequested();
                var quiet = Quiet.Contains(blockId);
                if (owner.BreakAt is { } moment && opened <= moment && (at > moment || (at == moment && quiet)))
                {
                    broken = true;
                }

                if (broken)
                {
                    owner.Failures.Add((at, blockId));
                    throw new CaptureException(CaptureFailureKind.Connection, TransportError);
                }

                if (!quiet)
                {
                    var rows = parameters is null
                        ? await inner.QueryAsync(blockId, text, parameter, timeout, cancellationToken)
                        : await inner.QueryAsync(blockId, text, parameters, timeout, cancellationToken);
                    return blockId == "RCA-PG-10" && owner.Surge is { } surge && at >= surge.From && at < surge.To ? [.. rows.Select(r => With(r, "client_connections", 45L))] : rows;
                }

                var cost = owner.Cost(blockId);
                owner.Clock.Advance(cost > timeout ? timeout : cost);
                if (cost > timeout)
                {
                    owner.Failures.Add((at, blockId));
                    throw new CaptureException(CaptureFailureKind.Timeout, "PostgreSQL error 57014: canceling statement due to statement timeout");
                }

                if (owner.Failure(blockId) is { } failure)
                {
                    owner.Failures.Add((at, blockId));
                    throw failure;
                }

                return owner.Answer(blockId) ?? [];
            }
        }

        private ManualTime Clock => clock;

        private IReadOnlyList<CaptureValues>? Answer(string blockId) => sidecar(blockId);
    }

    /// <summary>
    /// Connections to azure_sys whose opens and blocks (RCA-PG-14, 15) can cost time (past the timeout, the clock moves by
    /// the timeout and it fails as a timeout does), fail, or throw; otherwise <c>inner</c>'s connections answer.
    /// </summary>
    private sealed class TimedStore(ManualTime clock, ICaptureConnector inner, TimeSpan openTimeout) : ICaptureConnector
    {
        public List<(DateTimeOffset At, string BlockId, TimeSpan Timeout)> Calls { get; } = [];

        public List<(DateTimeOffset At, string BlockId)> Failures { get; } = [];

        public Func<string, TimeSpan> Cost { get; set; } = _ => TimeSpan.Zero;

        public Func<string, Exception?> Failure { get; set; } = _ => null;

        public TimeSpan OpenCost { get; set; }

        /// <summary>When set, an open's cost at the moment it starts, in place of <see cref="OpenCost"/>.</summary>
        public Func<DateTimeOffset, TimeSpan>? OpenCostAt { get; set; }

        public Exception? OpenFailure { get; set; }

        public string Description => "timed azure_sys";

        public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var at = clock.Now;
            var cost = OpenCostAt?.Invoke(at) ?? OpenCost;
            clock.Advance(cost > openTimeout ? openTimeout : cost);
            if (cost > openTimeout)
            {
                Failures.Add((at, "open"));
                throw new OperationCanceledException("The open's own bound ran out (a test's).");
            }

            if (OpenFailure is { } failure)
            {
                Failures.Add((at, "open"));
                throw failure;
            }

            return new Connection(this, await inner.OpenAsync(cancellationToken));
        }

        private sealed class Connection(TimedStore owner, ICaptureConnection connection) : ICaptureConnection
        {
            public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken) =>
                connection.QueryAsync(blockId, text, parameter, timeout, cancellationToken);

            public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken)
            {
                var at = owner.Time.Now;
                owner.Calls.Add((at, blockId, timeout));
                cancellationToken.ThrowIfCancellationRequested();
                var cost = owner.Cost(blockId);
                owner.Time.Advance(cost > timeout ? timeout : cost);
                if (cost > timeout)
                {
                    owner.Failures.Add((at, blockId));
                    throw new CaptureException(CaptureFailureKind.Timeout, "PostgreSQL error 57014: canceling statement due to statement timeout");
                }

                if (owner.Failure(blockId) is { } failure)
                {
                    owner.Failures.Add((at, blockId));
                    throw failure;
                }

                return await connection.QueryAsync(blockId, text, parameters, timeout, cancellationToken);
            }

            public ValueTask DisposeAsync() => connection.DisposeAsync();
        }

        private ManualTime Time => clock;
    }

    /// <summary>A sidecar sink whose store can't keep anything: every write fails as a full disk would.</summary>
    private sealed class FailingSidecar : ISidecarSink
    {
        public void Write(CaptureRow row) => throw new IOException("There is not enough space on the disk.");
    }

    /// <summary>A connector whose one block takes longer than a slow sample, in real time; every other block answers at once.</summary>
    private sealed class SlowBlockConnector(ICaptureConnector inner, string block, TimeSpan delay) : ICaptureConnector
    {
        private int slow;

        /// <summary>How many times the slow block ran.</summary>
        public int Slow => Volatile.Read(ref slow);

        public string Description => inner.Description;

        public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken) => new Connection(this, await inner.OpenAsync(cancellationToken));

        private sealed class Connection(SlowBlockConnector owner, ICaptureConnection connection) : ICaptureConnection
        {
            public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken)
            {
                if (string.Equals(blockId, owner.Block, StringComparison.Ordinal))
                {
                    Interlocked.Increment(ref owner.slow);
                    await Task.Delay(owner.Delay, cancellationToken);
                }

                return await connection.QueryAsync(blockId, text, parameter, timeout, cancellationToken);
            }

            public ValueTask DisposeAsync() => connection.DisposeAsync();
        }

        private string Block { get; } = block;

        private TimeSpan Delay { get; } = delay;
    }

    /// <summary>The local test sign-in's variables, for one test, when they aren't set already; the listener asks for no password.</summary>
    private sealed class TestCredentials : IDisposable
    {
        private readonly bool user = Environment.GetEnvironmentVariable(Postgres.PgEndpoint.UserVariable) is null;
        private readonly bool password = Environment.GetEnvironmentVariable(Postgres.PgEndpoint.PasswordVariable) is null;

        public TestCredentials()
        {
            if (user)
            {
                Environment.SetEnvironmentVariable(Postgres.PgEndpoint.UserVariable, "rca_observer_test");
            }

            if (password)
            {
                Environment.SetEnvironmentVariable(Postgres.PgEndpoint.PasswordVariable, FakeSecret(24));
            }
        }

        public void Dispose()
        {
            if (user)
            {
                Environment.SetEnvironmentVariable(Postgres.PgEndpoint.UserVariable, null);
            }

            if (password)
            {
                Environment.SetEnvironmentVariable(Postgres.PgEndpoint.PasswordVariable, null);
            }
        }
    }

    /// <summary>
    /// A PostgreSQL server that listens (protocol 3: https://www.postgresql.org/docs/18/protocol-flow.html). It refuses TLS
    /// and GSS encryption, lets the client in without a password, records the startup packet's parameters and every query
    /// the client sends, and closes the connection when the client terminates it or has been quiet a while: 2 seconds, or
    /// 10 when it answers, so a busy machine's pause isn't taken for the end. Without an answer it answers no query, so a
    /// client that sends one before its open completes fails to open; with one, it answers the extended protocol's
    /// statements at each Sync with the answer's columns and one row of their binary values, or none.
    /// </summary>
    private sealed class ListeningPostgres(Func<string, (string Name, uint Oid, byte[]? Value)[]?>? answer = null) : IDisposable
    {
        private static readonly (string Name, string Value)[] ServerParameters =
        [
            ("server_version", "18.1"), ("server_encoding", "UTF8"), ("client_encoding", "UTF8"), ("DateStyle", "ISO, MDY"),
            ("IntervalStyle", "postgres"), ("integer_datetimes", "on"), ("standard_conforming_strings", "on"), ("TimeZone", "UTC"),
        ];

        private readonly TcpListener listener = Started();

        public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

        /// <summary>The result formats each Bind asked for, in order (1 is binary).</summary>
        public List<short[]> ResultFormats { get; } = [];

        public void Dispose() => listener.Dispose();

        public async Task<(Dictionary<string, string> Startup, List<string> Queries)> AcceptAsync(CancellationToken cancellationToken)
        {
            using var client = await listener.AcceptTcpClientAsync(cancellationToken);
            await using var stream = client.GetStream();
            var startup = new Dictionary<string, string>(StringComparer.Ordinal);
            while (true)
            {
                var header = await ReadAsync(stream, 8, cancellationToken);
                var length = BinaryPrimitives.ReadInt32BigEndian(header);
                var code = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(4));
                if (code is 80877103 or 80877104)
                {
                    // SSLRequest or GSSENCRequest: neither is offered.
                    await stream.WriteAsync("N"u8.ToArray(), cancellationToken);
                    continue;
                }

                var fields = System.Text.Encoding.UTF8.GetString(await ReadAsync(stream, length - 8, cancellationToken)).Split('\0');
                for (var i = 0; i + 1 < fields.Length && fields[i].Length > 0; i += 2)
                {
                    startup[fields[i]] = fields[i + 1];
                }

                break;
            }

            await stream.WriteAsync(Message('R', Int32(0)), cancellationToken);
            foreach (var (name, value) in ServerParameters)
            {
                await stream.WriteAsync(Message('S', [.. CString(name), .. CString(value)]), cancellationToken);
            }

            await stream.WriteAsync(Message('K', [.. Int32(4242), .. Int32(7)]), cancellationToken);
            await stream.WriteAsync(Message('Z', "I"u8.ToArray()), cancellationToken);

            var queries = new List<string>();
            var steps = new List<(char Kind, string Query)>();
            var parsed = string.Empty;
            while (true)
            {
                byte[] head;
                using (var quiet = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
                {
                    quiet.CancelAfter(answer is null ? TimeSpan.FromSeconds(2) : TimeSpan.FromSeconds(10));
                    try
                    {
                        head = await ReadAsync(stream, 5, quiet.Token);
                    }
                    catch (Exception ex) when (ex is OperationCanceledException or EndOfStreamException or IOException)
                    {
                        break;
                    }
                }

                var payload = await ReadAsync(stream, BinaryPrimitives.ReadInt32BigEndian(head.AsSpan(1)) - 4, cancellationToken);
                var kind = (char)head[0];
                switch (kind)
                {
                    case 'Q':
                        queries.Add(CStringAt(payload, 0));
                        break;
                    case 'P':
                        parsed = CStringAt(payload, Array.IndexOf(payload, (byte)0) + 1);
                        queries.Add(parsed);
                        steps.Add((kind, parsed));
                        break;
                    case 'B':
                        ResultFormats.Add(BindResultFormats(payload));
                        steps.Add((kind, parsed));
                        break;
                    case 'D' or 'E':
                        steps.Add((kind, parsed));
                        break;
                    case 'S' when answer is not null:
                        foreach (var (step, query) in steps)
                        {
                            await stream.WriteAsync(Reply(step, answer(query)), cancellationToken);
                        }

                        steps.Clear();
                        await stream.WriteAsync(Message('Z', "I"u8.ToArray()), cancellationToken);
                        break;
                    case 'X':
                        return (startup, queries);
                }
            }

            return (startup, queries);
        }

        private static TcpListener Started()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            return listener;
        }

        /// <summary>The result format codes at a Bind message's end, after its portal, statement, parameter formats, and values.</summary>
        private static short[] BindResultFormats(byte[] payload)
        {
            var at = Array.IndexOf(payload, (byte)0) + 1;
            at = Array.IndexOf(payload, (byte)0, at) + 1;
            at += 2 + (2 * BinaryPrimitives.ReadInt16BigEndian(payload.AsSpan(at)));
            var values = BinaryPrimitives.ReadInt16BigEndian(payload.AsSpan(at));
            at += 2;
            for (var i = 0; i < values; i++)
            {
                at += 4 + Math.Max(0, BinaryPrimitives.ReadInt32BigEndian(payload.AsSpan(at)));
            }

            var count = BinaryPrimitives.ReadInt16BigEndian(payload.AsSpan(at));
            return [.. Enumerable.Range(0, count).Select(i => BinaryPrimitives.ReadInt16BigEndian(payload.AsSpan(at + 2 + (2 * i))))];
        }

        /// <summary>What a step of the extended protocol gets at Sync: Parse and Bind complete, the row's description, its row and completion.</summary>
        private static byte[] Reply(char step, (string Name, uint Oid, byte[]? Value)[]? columns)
        {
            switch (step)
            {
                case 'P':
                    return Message('1', []);
                case 'B':
                    return Message('2', []);
                case 'D' when columns is null:
                    return Message('n', []);
                case 'D':
                    var description = new List<byte>(Wire.Int16((short)columns.Length));
                    foreach (var (name, oid, _) in columns)
                    {
                        description.AddRange([.. CString(name), .. Int32(0), .. Wire.Int16(0), .. Int32((int)oid), .. Wire.Int16(-1), .. Int32(-1), .. Wire.Int16(1)]);
                    }

                    return Message('T', [.. description]);
                case 'E' when columns is null:
                    return Message('C', CString("SELECT 0"));
                default:
                    var row = new List<byte>(Wire.Int16((short)columns!.Length));
                    foreach (var (_, _, value) in columns)
                    {
                        row.AddRange(value is null ? Int32(-1) : [.. Int32(value.Length), .. value]);
                    }

                    return [.. Message('D', [.. row]), .. Message('C', CString("SELECT 1"))];
            }
        }

        private static async Task<byte[]> ReadAsync(NetworkStream stream, int count, CancellationToken cancellationToken)
        {
            var buffer = new byte[count];
            await stream.ReadExactlyAsync(buffer, cancellationToken);
            return buffer;
        }

        private static byte[] Message(char type, byte[] payload)
        {
            var message = new byte[payload.Length + 5];
            message[0] = (byte)type;
            BinaryPrimitives.WriteInt32BigEndian(message.AsSpan(1), payload.Length + 4);
            payload.CopyTo(message, 5);
            return message;
        }

        private static byte[] Int32(int value)
        {
            var bytes = new byte[4];
            BinaryPrimitives.WriteInt32BigEndian(bytes, value);
            return bytes;
        }

        private static byte[] CString(string text) => [.. System.Text.Encoding.UTF8.GetBytes(text), 0];

        private static string CStringAt(byte[] payload, int start)
        {
            var end = Array.IndexOf(payload, (byte)0, start);
            return System.Text.Encoding.UTF8.GetString(payload, start, (end < 0 ? payload.Length : end) - start);
        }
    }

    /// <summary>PostgreSQL's binary formats for the types the blocks return (https://www.postgresql.org/docs/18/protocol-overview.html).</summary>
    private static class Wire
    {
        public static byte[] Int16(short value)
        {
            var bytes = new byte[2];
            BinaryPrimitives.WriteInt16BigEndian(bytes, value);
            return bytes;
        }

        public static byte[] Int32(int value)
        {
            var bytes = new byte[4];
            BinaryPrimitives.WriteInt32BigEndian(bytes, value);
            return bytes;
        }

        public static byte[] Int64(long value)
        {
            var bytes = new byte[8];
            BinaryPrimitives.WriteInt64BigEndian(bytes, value);
            return bytes;
        }

        public static byte[] Float8(double value)
        {
            var bytes = new byte[8];
            BinaryPrimitives.WriteDoubleBigEndian(bytes, value);
            return bytes;
        }

        public static byte[] Text(string value) => System.Text.Encoding.UTF8.GetBytes(value);

        /// <summary>A timestamp: microseconds since 2000-01-01 00:00 UTC.</summary>
        public static byte[] Timestamp(DateTimeOffset value) => Int64((value.UtcTicks - new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc).Ticks) / 10);

        /// <summary>A non-negative numeric: base-10,000 digits, the first one's weight, and the scale shown.</summary>
        public static byte[] Numeric(short weight, short scale, params short[] digits) =>
            [.. Int16((short)digits.Length), .. Int16(weight), .. Int16(0), .. Int16(scale), .. digits.SelectMany(Int16)];

        /// <summary>A one-dimensional integer[] with no nulls.</summary>
        public static byte[] Int32Array(params int[] values) =>
            [.. Int32(1), .. Int32(0), .. Int32(23), .. Int32(values.Length), .. Int32(1), .. values.SelectMany(v => Int32(4).Concat(Int32(v)))];
    }
}