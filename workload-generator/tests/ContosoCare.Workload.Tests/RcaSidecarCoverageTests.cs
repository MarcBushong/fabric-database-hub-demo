using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Sidecar;
using Xunit;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The coverage merge (T1a's spec, section 4): one RCA Query Coverage row per target per sidecar from the rows each read
/// wrote. A1's T3 observation and A2's T4 observations, through the store-backed sink and the sealer, reproduce the
/// contract fixtures' coverage rows: t3-plan-regression, t4-query-store (T4 and its replica), and t4-connection-surge.
/// </summary>
public sealed class RcaSidecarCoverageTests : IDisposable
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 20, 17, 0, 0, TimeSpan.Zero);

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-sidecar-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void StateComesFromTheLatestReadThatHadItAndThePendingRangeFromTheLatestRead()
    {
        var first = Read(T0, T0.AddMinutes(15), gaps: null).Set("pending_from_utc", T0.AddMinutes(10)).Set("pending_to_utc", T0.AddMinutes(15));
        var failed = Read(T0.AddMinutes(15), T0.AddMinutes(30), gaps: "RCA-SQL-15 failed on T1: a timeout.").Set("state", null).Set("capture_mode", null).Set("interval_minutes", null).Set("read_from_utc", null).Set("read_to_utc", null);

        var merged = SidecarCoverage.Merge("T1", [failed, first], []).Row();

        Assert.Equal(("READ_WRITE", "AUTO", 15L), ((string?)merged.Get("state"), (string?)merged.Get("capture_mode"), (long?)merged.Get("interval_minutes")));
        Assert.Null(merged.Get("pending_from_utc"));
        Assert.Null(merged.Get("pending_to_utc"));
        Assert.Equal((T0, T0.AddMinutes(30)), ((DateTimeOffset)merged.Get("window_start_utc")!, (DateTimeOffset)merged.Get("window_end_utc")!));
        Assert.Equal("RCA-SQL-15 failed on T1: a timeout.", merged.Get("gaps"));
    }

    [Fact]
    public void TheIntervalsReadRunFromTheEarliestToTheLatestAndBackfillIsAnyReads()
    {
        var a = Read(T0, T0.AddMinutes(15)).Set("read_from_utc", T0.AddMinutes(-30)).Set("read_to_utc", T0);
        var b = Read(T0.AddMinutes(15), T0.AddMinutes(30)).Set("read_from_utc", T0).Set("read_to_utc", T0.AddMinutes(15)).Set("backfill", true);

        var merged = SidecarCoverage.Merge("T1", [a, b], []).Row();

        Assert.Equal((T0.AddMinutes(-30), T0.AddMinutes(15), true), ((DateTimeOffset)merged.Get("read_from_utc")!, (DateTimeOffset)merged.Get("read_to_utc")!, (bool)merged.Get("backfill")!));
    }

    [Fact]
    public void SourcesAreEveryReadsAndEveryRowsInCatalogOrder()
    {
        var reads = new[] { Read(T0, T0.AddMinutes(15), sources: "RCA-PG-16,RCA-PG-13"), Read(T0.AddMinutes(15), T0.AddMinutes(30), sources: "RCA-PG-14,RCA-XX-01") };
        var holders = new CaptureRow(RcaContract.Connections, "T4", T0.AddMinutes(5), "RCA-PG-17");
        var observer = new CaptureRow(RcaContract.QueryEvents, "T4", T0.AddMinutes(5), "observer");

        var merged = SidecarCoverage.Merge("T4", reads, [holders, observer]).Row();

        Assert.Equal("RCA-PG-13,RCA-PG-14,RCA-PG-16,RCA-PG-17,RCA-XX-01", merged.Get("sources"));
    }

    [Fact]
    public void GapsAreEachDistinctLineInTimeOrderWithinAStringsLength()
    {
        var later = Read(T0.AddMinutes(15), T0.AddMinutes(30), gaps: "17:20:00 UTC: B\n17:16:00 UTC: A");
        var earlier = Read(T0, T0.AddMinutes(15), gaps: "17:05:00 UTC: A0\n17:16:00 UTC: A");
        var many = Enumerable.Range(0, 200).Select(i => Read(T0.AddMinutes(i), T0.AddMinutes(i + 1), gaps: $"Gap {i:D3}: " + new string('x', 60))).ToList();

        Assert.Equal("17:05:00 UTC: A0\n17:16:00 UTC: A\n17:20:00 UTC: B", SidecarCoverage.Merge("T1", [later, earlier], []).Row().Get("gaps"));
        var capped = (string)SidecarCoverage.Merge("T1", many, []).Row().Get("gaps")!;
        Assert.True(capped.Length <= RcaContract.MaximumStringLength);
        Assert.StartsWith("Gap 000: ", capped, StringComparison.Ordinal);
        Assert.Matches(@"\n\.\.\. and \d+ more\.$", capped);
    }

    [Fact]
    public void MergeTakesOnlyATargetWithAQueryStoreRead()
    {
        var holders = new[] { new CaptureRow(RcaContract.Connections, "T4", T0.AddMinutes(3), "RCA-PG-17") };

        Assert.Throws<ArgumentException>(() => SidecarCoverage.Merge("T4", [], holders));
    }

    [Fact]
    public async Task A1sT3ObservationMergesToTheT3FixturesCoverageRow()
    {
        var rig = new SidecarRig(root, T3QueryStore.From);
        var store = new T3QueryStore(rig.Clock);
        var observer = new SqlTargetObserver("T3", DemoTarget.T3, store.Connector(), RcaSimulation.Options(), RunnerLog.Null, rig.Sink, T3QueryStore.Options);
        var span = rig.Open(T3QueryStore.From);

        await RcaSimulation.DriveAsync([observer], span, rig.Clock, T3QueryStore.From, T3QueryStore.To, TestContext.Current.CancellationToken);
        span.Close(T3QueryStore.To);

        AssertCoverage(store.Fixture, SealOne(rig));
    }

    [Fact]
    public async Task A2sT4AndReplicaObservationsMergeToTheT4QueryStoreFixturesCoverageRows()
    {
        var rig = new SidecarRig(root, RcaSimulation.T4From);
        var fixture = new SidecarView(RepositoryPaths.Combine("rca", "fixtures", "t4-query-store.sidecar.json"));
        var azureSys = AzureSys(rig.Clock, T4Statistics(), T4Waits());
        var link = new ReplicaLink();
        TargetObserver[] observers =
        [
            new PgPrimaryObserver(Primary(rig.Clock, busy: null), RcaSimulation.Options(), RunnerLog.Null, link, rig.Sink, new PgQueryStoreSource(azureSys, new QueryWatermark(root, "T4"), rig.Sink)),
            new PgReplicaObserver(new ScriptedConnector((block, _) => block == "RCA-PG-13" ? T4Settings(rig.Clock.Now, inRecovery: true) : []), RcaSimulation.Options(), RunnerLog.Null, link, rig.Sink),
        ];
        var span = rig.Open(RcaSimulation.T4From);

        await RcaSimulation.DriveAsync(observers, span, rig.Clock, RcaSimulation.T4From, RcaSimulation.T4To, TestContext.Current.CancellationToken);
        span.Close(RcaSimulation.T4To);

        AssertCoverage(fixture, SealOne(rig));
    }

    [Fact]
    public async Task A2sT4ObservationOfAConnectionSurgeMergesToItsFixturesCoverageRowWithTheHoldersSource()
    {
        var from = new DateTimeOffset(2026, 11, 21, 10, 0, 0, TimeSpan.Zero);
        var rig = new SidecarRig(root, from);
        var fixture = new SidecarView(RepositoryPaths.Combine("rca", "fixtures", "t4-connection-surge.sidecar.json"));
        var azureSys = AzureSys(rig.Clock, [StatsRow(from, 7001, "contosocare_runner", "SELECT p.patient_id FROM care.patients AS p WHERE p.patient_id = $1", 1200, 840, 4.1)], []);
        var observer = new PgPrimaryObserver(Primary(rig.Clock, busy: (from.AddMinutes(5), from.AddMinutes(12))), RcaSimulation.Options(), RunnerLog.Null, new ReplicaLink(), rig.Sink, new PgQueryStoreSource(azureSys, new QueryWatermark(root, "T4"), rig.Sink));
        var span = rig.Open(from);

        await RcaSimulation.DriveAsync([observer], span, rig.Clock, from, from.AddMinutes(20), TestContext.Current.CancellationToken);
        span.Close(from.AddMinutes(20));

        var draft = SealOne(rig);
        Assert.NotEmpty(draft.Tables[RcaContract.Connections]);
        AssertCoverage(fixture, draft);
    }

    /// <summary>A1's or A2's per-read coverage row, as their readers write them.</summary>
    private static CaptureRow Read(DateTimeOffset from, DateTimeOffset to, string? sources = "RCA-SQL-10,RCA-SQL-15", string? gaps = null) =>
        SidecarRig.Coverage("T1", from, to, sources, gaps);

    /// <summary>Seals the store's one span and returns the draft the reducer got.</summary>
    private static SidecarDraft SealOne(SidecarRig rig)
    {
        rig.Clock.Set(rig.Clock.Now.AddMinutes(1));
        Assert.Single(rig.Sealer.SealAll().Sealed);
        return Assert.Single(rig.Reducer.Calls).Draft;
    }

    /// <summary>Each fixture coverage row equals the draft's, column by column, and the draft has no other target.</summary>
    private static void AssertCoverage(SidecarView fixture, SidecarDraft draft)
    {
        var expected = fixture.Table(RcaContract.QueryCoverage);
        var actual = draft.Tables[RcaContract.QueryCoverage];
        Assert.Equal(expected.Select(r => (string?)r["target"]), actual.Select(r => r.Target));
        foreach (var (want, got) in expected.Zip(actual))
        {
            foreach (var column in RcaContract.Table(RcaContract.QueryCoverage).Columns.Select(c => c.Name))
            {
                var value = got.Get(column) is int number ? (long)number : got.Get(column);
                Assert.True(Equals(want[column], value), $"{got.Target}.{column}: expected {want[column] ?? "null"}, got {value ?? "null"}");
            }
        }

        Assert.Equal((fixture.Epoch, DateTimeOffset.Parse(fixture.Root["windowEndUtc"]!.GetValue<string>(), System.Globalization.CultureInfo.InvariantCulture)), (draft.WindowStartUtc, draft.WindowEndUtc));
    }

    /// <summary>T4's observer connection: quiet, or with its client connections near the limit from <paramref name="busy"/>'s start to its end; RCA-PG-13 and 16 for Query Store.</summary>
    private static ScriptedConnector Primary(ManualTime clock, (DateTimeOffset From, DateTimeOffset To)? busy) => new((block, _) => block switch
    {
        "RCA-PG-13" => T4Settings(clock.Now, inRecovery: false),
        "RCA-PG-16" => [Row(("captured_at", null), ("kind", "function"), ("name", "fn_harness_event")), Row(("captured_at", null), ("kind", "harness_table"), ("name", "harness_runs")), Row(("captured_at", null), ("kind", "table"), ("name", "patients"))],
        "RCA-PG-10" when busy is { } surge => [Row(("captured_at", clock.Now.UtcDateTime), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", clock.Now >= surge.From && clock.Now < surge.To ? 45L : 10L), ("waiting_lock", 0L))],
        "RCA-PG-17" => [Row(("captured_at", clock.Now.UtcDateTime), ("application_name", ApplicationNames.Program + "/svc-intake/20261121100500-t4-aa11bb"), ("usename", "contosocare_runner"), ("state", "idle"), ("connections", 40L), ("waiting_lock", 0L), ("oldest_state_s", 12.5m), ("oldest_connection_s", 300m))],
        _ => [],
    });

    /// <summary>T4's azure_sys: RCA-PG-14 and 15 answer from the intervals ended by the clock, within the block's bounds, as their SQL would.</summary>
    private static ScriptedConnector AzureSys(ManualTime clock, List<CaptureValues> statistics, List<CaptureValues> waits) => new((_, _) => [])
    {
        ParameterAnswer = (block, parameters) =>
        {
            var since = (DateTimeOffset)parameters[1].Value!;
            var until = (DateTimeOffset)parameters[block == "RCA-PG-14" ? 5 : 3].Value!;
            var now = clock.Now;
            bool Shown(CaptureValues row) => row.Time("interval_end_utc") > since && row.Time("interval_start_utc") < until && now >= row.Time("interval_end_utc");
            var rows = block switch
            {
                "RCA-PG-14" => statistics.Where(Shown),
                "RCA-PG-15" => waits.Where(Shown),
                _ => [],
            };
            return [.. rows.Select(r => new CaptureValues(r.Raw.ToDictionary(v => v.Key, v => v.Key == "captured_at" ? now.UtcDateTime : v.Value, StringComparer.OrdinalIgnoreCase)))];
        },
    };

    private static List<CaptureValues> T4Settings(DateTimeOffset now, bool inRecovery) =>
    [
        Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("name", "pg_qs.interval_length_minutes"), ("setting", "15"), ("unit", "min")),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("name", "pg_qs.query_capture_mode"), ("setting", "all"), ("unit", null)),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("name", "pg_qs.retention_period_in_days"), ("setting", "7"), ("unit", null)),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("name", "pg_qs.store_query_plans"), ("setting", "off"), ("unit", null)),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("name", "pgms_wait_sampling.history_period"), ("setting", "100"), ("unit", "ms")),
        Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("name", "pgms_wait_sampling.query_capture_mode"), ("setting", "all"), ("unit", null)),
    ];

    /// <summary>The 16:45 and 17:00 intervals behind the T4 fixture's statistics: what the merge reads of them is their span.</summary>
    private static List<CaptureValues> T4Statistics() =>
    [
        StatsRow(T0.AddMinutes(-15), 5001, "contosocare_runner", "UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_id = $2", 220, 61.6, 1.4),
        StatsRow(T0, 5001, "contosocare_runner", "UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_id = $2", 214, 251300, 20050),
    ];

    private static List<CaptureValues> T4Waits() =>
    [
        Row(("captured_at", null), ("interval_start_utc", T0.UtcDateTime), ("interval_end_utc", T0.AddMinutes(15).UtcDateTime), ("login_name", "contosocare_runner"), ("query_id", 5001L), ("plan_id", 0L), ("wait_category", "Lock"), ("wait_event", "transactionid"), ("samples", 2480L)),
    ];

    private static CaptureValues StatsRow(DateTimeOffset start, long query, string login, string text, long calls, double total, double max) =>
        Row(
            ("captured_at", null),
            ("interval_start_utc", start.UtcDateTime),
            ("interval_end_utc", start.AddMinutes(15).UtcDateTime),
            ("login_name", login),
            ("query_id", query),
            ("plan_id", 0L),
            ("query_sql_text", text),
            ("executions", calls),
            ("duration_ms", total),
            ("max_duration_ms", max),
            ("logical_reads", 100m),
            ("physical_reads", 0m),
            ("row_count", (decimal)calls),
            ("tempdb_kb", 0m),
            ("wait_samples", 0L));
}
