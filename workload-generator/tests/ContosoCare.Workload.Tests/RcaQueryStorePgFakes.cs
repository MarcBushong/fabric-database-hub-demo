using System.Globalization;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using Xunit;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

// T4's Query Store and connection holders, scripted (rca/README.md, The sidecar), for the tests that drive T4's reader:
// RcaQueryStorePgTests, and the sidecar's store, sealer, and coverage merge.

/// <summary>
/// The rows behind the T4 fixtures (rca/fixtures/t4-query-store.sidecar.json and t4-connection-surge.sidecar.json), as
/// RCA-PG-13 to 17 return them, and the builders of others.
/// </summary>
internal static class T4Fixtures
{
    public const string Runner = "contosocare_runner";

    public const string SpanA = "20261120T170000Z";

    public const string SpanB = "20261120T180000Z";

    /// <summary>The chain's UPDATE: 64-bit query IDs, negative ones included, as qs_view has them.</summary>
    public const long Update = -6412873301142229951;

    public const long Claim = 2871345566190021453;

    public const long Marks = 8164251097732651127;

    /// <summary>Another role's query, which the read sums under none (a null login).</summary>
    public const long SizeCheck = -1129384756610293847;

    public static DateTimeOffset At(int hour, int minute, int milliseconds = 0) => new DateTimeOffset(2026, 11, 20, hour, minute, 0, TimeSpan.Zero).AddMilliseconds(milliseconds);

    /// <summary>When T4 started before the fixtures' sessions (pg_postmaster_start_time()).</summary>
    public static readonly DateTimeOffset ServerStart = new(2026, 11, 20, 8, 0, 0, TimeSpan.Zero);

    /// <summary>A harness of one marked function and no table only it writes.</summary>
    public static PgHarness Harness() => PgHarness.Parse([Row(("kind", "function"), ("name", "fn_harness_event"))]);

    /// <summary>RCA-PG-13's rows: Query Store on T4 as the demo sets it (capture mode all, 15-minute intervals, 7 days).</summary>
    public static List<CaptureValues> Settings(DateTimeOffset now, bool inRecovery, string captureMode = "all", DateTimeOffset? started = null) =>
    [
        .. new (string Name, string Setting, string? Unit)[]
        {
            ("pg_qs.interval_length_minutes", "15", "min"),
            ("pg_qs.query_capture_mode", captureMode, null),
            ("pg_qs.retention_period_in_days", "7", null),
            ("pg_qs.store_query_plans", "off", null),
            ("pgms_wait_sampling.history_period", "100", "ms"),
            ("pgms_wait_sampling.query_capture_mode", "all", null),
        }.Select(s => Row(("captured_at", now.UtcDateTime), ("in_recovery", inRecovery), ("server_started", (started ?? ServerStart).UtcDateTime), ("name", s.Name), ("setting", s.Setting), ("unit", s.Unit))),
    ];

    /// <summary>RCA-PG-14's rows behind the T4 fixture: what qs_view returns for 16:45 and 17:00, the leave-outs applied.</summary>
    public static List<CaptureValues> T4Statistics() =>
    [
        StatsRow(At(16, 45), Update, Runner, "UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_id = $2", 220, 61.6, 1.4, 1760, 0, 220, 0, 0),
        StatsRow(At(16, 45), Marks, Runner, "INSERT INTO demo.replica_lag_marks (marked_at, payload) VALUES (now(), $1) -- one mark", 1800, 1980, 9.7, 5400, 12, 1800, 0, 12),
        StatsRow(At(16, 45), SizeCheck, null, "SELECT d.datname, pg_database_size(d.oid) FROM pg_database AS d", 15, 141, 12.2, 90, 0, 75, 0, 0),
        StatsRow(At(17, 0), Update, Runner, "UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_id = $2", 214, 251300, 20050, 2140, 0, 214, 0, 2486),
        StatsRow(At(17, 0), Claim, Runner, "SELECT q.queue_id FROM care.work_queues AS q WHERE q.status = $1 ORDER BY q.priority, q.queue_id LIMIT $2 FOR UPDATE", 30, 45, 3.1, 600, 0, 30, 0, 0),
        StatsRow(At(17, 0), Marks, Runner, "INSERT INTO demo.replica_lag_marks (marked_at, payload) VALUES (now(), $1)", 1792, 2102, 11.3, 5376, 9, 1792, 0, 14),
        StatsRow(At(17, 0), SizeCheck, null, "SELECT d.datname, pg_database_size(d.oid) FROM pg_database AS d", 15, 139, 11.8, 90, 0, 75, 0, 0),
    ];

    /// <summary>RCA-PG-15's rows: the fixture's, plus one of a query the statistics don't hold and one with no event.</summary>
    public static List<CaptureValues> T4Waits() =>
    [
        WaitRow(At(16, 45), Marks, Runner, "IO", "WALSync", 12),
        WaitRow(At(16, 45), Marks, null, "Lock", "relation", 3),
        WaitRow(At(17, 0), Update, Runner, "Lock", "transactionid", 2480),
        WaitRow(At(17, 0), Update, Runner, "LWLock", "LockManager", 6),
        WaitRow(At(17, 0), Update, Runner, null, null, 900),
        WaitRow(At(17, 0), Marks, Runner, "IO", "WALSync", 14),
    ];

    /// <summary>The 17:15 interval, published after the first session ended.</summary>
    public static List<CaptureValues> Later() =>
    [
        StatsRow(At(17, 15), Update, Runner, "UPDATE care.work_queues SET status = $1, claimed_at = now() WHERE queue_id = $2", 31, 9.1, 0.6, 310, 0, 31, 0, 0),
        StatsRow(At(17, 15), Marks, Runner, "INSERT INTO demo.replica_lag_marks (marked_at, payload) VALUES (now(), $1)", 420, 470, 8.8, 1260, 2, 420, 0, 0),
    ];

    /// <summary>One RCA-PG-14 row of a 15-minute interval.</summary>
    public static CaptureValues StatsRow(DateTimeOffset start, long query, string? login, string text, long calls, double total, double max, decimal blocks, decimal read, decimal rows, decimal tempKb, long samples) =>
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
            ("logical_reads", blocks),
            ("physical_reads", read),
            ("row_count", rows),
            ("tempdb_kb", tempKb),
            ("wait_samples", samples));

    /// <summary>One RCA-PG-15 row of a 15-minute interval; a null event is a backend on CPU.</summary>
    public static CaptureValues WaitRow(DateTimeOffset start, long query, string? login, string? category, string? waitEvent, long samples) =>
        Row(
            ("captured_at", null),
            ("interval_start_utc", start.UtcDateTime),
            ("interval_end_utc", start.AddMinutes(15).UtcDateTime),
            ("login_name", login),
            ("query_id", query),
            ("plan_id", 0L),
            ("wait_category", category),
            ("wait_event", waitEvent),
            ("samples", samples));

    /// <summary>One RCA-PG-17 row: a group of client connections by application, role, and state.</summary>
    public static CaptureValues HolderRow(DateTimeOffset at, string application, string role, string state, long connections, long waitingLock, double oldestState, double oldestConnection) =>
        Row(
            ("captured_at", at.UtcDateTime),
            ("application_name", application),
            ("usename", role),
            ("state", state),
            ("connections", connections),
            ("waiting_lock", waitingLock),
            ("oldest_state_s", (decimal)oldestState),
            ("oldest_connection_s", (decimal)oldestConnection));
}

/// <summary>
/// T4's Query Store, scripted. On azure_sys (<see cref="Connector"/>), RCA-PG-14 and 15 answer from the rows of the
/// intervals published by the clock (an interval's statistics show <see cref="PublishedAfter"/> after it ends, its waits
/// <see cref="WaitsPublishedAfter"/> after), within the block's bounds, as the blocks' SQL would: RCA-PG-14's
/// wait_samples counts the waits shown, events only. The observer's own connection answers RCA-PG-13 and 16
/// (<see cref="ObserverAnswer"/>), quietly for the reader (<see cref="Access"/>).
/// </summary>
internal sealed class T4QueryStore
{
    private readonly List<CaptureValues> statistics;
    private readonly List<CaptureValues> waits;
    private ManualTime? following;
    private DateTimeOffset clock;

    public T4QueryStore(List<CaptureValues> statistics, List<CaptureValues> waits)
    {
        this.statistics = statistics;
        this.waits = waits;
        Connector = new ScriptedConnector((_, _) => []) { ParameterAnswer = Answer };
        Access = new T4Access(this);
    }

    /// <summary>Connections to azure_sys.</summary>
    public ScriptedConnector Connector { get; }

    /// <summary>The observer's quiet path, as T4's reader uses it.</summary>
    public T4Access Access { get; }

    public DateTimeOffset Clock
    {
        get => following?.Now ?? clock;
        set => clock = value;
    }

    public TimeSpan PublishedAfter { get; set; }

    /// <summary>When an interval's waits show; as its statistics when null.</summary>
    public TimeSpan? WaitsPublishedAfter { get; set; }

    public string CaptureMode { get; set; } = "all";

    /// <summary>When T4 last started (pg_postmaster_start_time()), as RCA-PG-13 returns it.</summary>
    public DateTimeOffset ServerStarted { get; set; } = T4Fixtures.ServerStart;

    public bool HarnessFails { get; set; }

    public List<CaptureValues> Harness { get; set; } =
    [
        Row(("captured_at", null), ("kind", "function"), ("name", "fn$harness_begin")),
        Row(("captured_at", null), ("kind", "function"), ("name", "fn_harness_event")),
        Row(("captured_at", null), ("kind", "harness_table"), ("name", "harness_runs")),
        Row(("captured_at", null), ("kind", "table"), ("name", "work_queues")),
        Row(("captured_at", null), ("kind", "table"), ("name", "patients")),
    ];

    /// <summary>Answers by the simulation's clock instead of <see cref="Clock"/>.</summary>
    public void Follow(ManualTime time) => following = time;

    /// <summary>What the observer's own connection returns for RCA-PG-13 and 16 at the store's clock; null for a block it doesn't answer, or a harness that fails.</summary>
    public IReadOnlyList<CaptureValues>? ObserverAnswer(string block) => block switch
    {
        "RCA-PG-13" => T4Fixtures.Settings(Clock, inRecovery: false, CaptureMode, ServerStarted),
        "RCA-PG-16" => HarnessFails ? null : Harness,
        _ => null,
    };

    private static CaptureValues With(CaptureValues row, string column, object? value)
    {
        var values = row.Raw.ToDictionary(v => v.Key, v => v.Value, StringComparer.OrdinalIgnoreCase);
        values[column] = value;
        return new CaptureValues(values);
    }

    private static bool Same(CaptureValues a, CaptureValues b) =>
        a.Time("interval_start_utc") == b.Time("interval_start_utc") && a.Long("query_id") == b.Long("query_id") && string.Equals(a.Text("login_name"), b.Text("login_name"), StringComparison.Ordinal);

    private List<CaptureValues> Answer(string block, CaptureParameters parameters)
    {
        var since = (DateTimeOffset)parameters[1].Value!;
        var until = (DateTimeOffset)parameters[block == "RCA-PG-14" ? 5 : 3].Value!;
        var now = Clock;
        bool Shown(CaptureValues row, TimeSpan after) => row.Time("interval_end_utc") > since && row.Time("interval_start_utc") < until && now >= row.Time("interval_end_utc") + after;
        var shownWaits = waits.Where(w => Shown(w, WaitsPublishedAfter ?? PublishedAfter)).ToList();
        var rows = block switch
        {
            "RCA-PG-14" => statistics.Where(s => Shown(s, PublishedAfter)).Select(s => With(s, "wait_samples", shownWaits.Where(w => Same(w, s) && w.Text("wait_category") is not null).Sum(w => w.Long("samples") ?? 0))),
            "RCA-PG-15" => shownWaits.Where(w => ((long[])parameters[2].Value!).Contains(w.Long("query_id")!.Value)),
            _ => Enumerable.Empty<CaptureValues>(),
        };

        // captured_at is clock_timestamp() at the read.
        return [.. rows.Select(r => With(r, "captured_at", now.UtcDateTime))];
    }
}

/// <summary>
/// The observer's quiet path (<see cref="ISidecarAccess"/>) as T4's reader sees it, scripted: RCA-PG-13 and 16 as the
/// store answers them, the self-throttling's state as the test sets it, and a block's failure when the test says.
/// </summary>
internal sealed class T4Access(T4QueryStore store) : ISidecarAccess
{
    public string Target => "T4";

    public int Factor { get; set; } = 1;

    public bool DetailStopped { get; set; }

    /// <summary>Every block run, with its timeout.</summary>
    public List<(string BlockId, TimeSpan Timeout)> Calls { get; } = [];

    /// <summary>When set, a block fails with what it returns, or runs normally for null.</summary>
    public Func<string, QuietResult?>? Failure { get; set; }

    public Task<QuietResult> RunAsync(string blockId, DateTimeOffset now, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken)
    {
        Calls.Add((blockId, timeout));
        if (Failure?.Invoke(blockId) is { } failed)
        {
            return Task.FromResult(failed);
        }

        return Task.FromResult(store.ObserverAnswer(blockId) is { } rows
            ? QuietResult.Of(rows)
            : QuietResult.Failed(CaptureFailureKind.Other, $"PostgreSQL error XX000: {blockId} failed (a test's failure)."));
    }
}

/// <summary>A sidecar sink that keeps what it gets, refusing an evidence table's row as the default sink does.</summary>
internal sealed class MemorySidecar : ISidecarSink
{
    private readonly List<CaptureRow> rows = [];

    public void Write(CaptureRow row)
    {
        NullSidecarSink.Instance.Write(row);
        lock (rows)
        {
            rows.Add(row);
        }
    }

    public List<CaptureRow> Table(string name)
    {
        lock (rows)
        {
            return [.. rows.Where(r => r.Table == name)];
        }
    }
}

/// <summary>The span store's side of a backfill: a sink per span that the test adds.</summary>
internal sealed class MemorySpans : ISidecarSpans
{
    private readonly Dictionary<string, MemorySidecar> sinks = new(StringComparer.Ordinal);

    public string? CurrentSpan { get; set; }

    public MemorySidecar Add(string span) => sinks[span] = new MemorySidecar();

    public ISidecarSink? ForSpan(string spanId) => sinks.GetValueOrDefault(spanId);
}

/// <summary>A sidecar fixture decoded for assertions: each table's rows with strings resolved and times as UTC.</summary>
internal sealed class SidecarFixture
{
    private readonly JsonObject root;
    private readonly DateTimeOffset epoch;
    private readonly List<string> strings;

    public SidecarFixture(string name)
    {
        root = JsonNode.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "fixtures", name)))!.AsObject();
        Assert.Equal(RcaContract.SidecarKind, root["kind"]!.GetValue<string>());
        epoch = DateTimeOffset.Parse(root["epochUtc"]!.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
        strings = [.. root["strings"]!.AsArray().Select(s => s!.GetValue<string>())];
    }

    public List<Dictionary<string, object?>> Table(string name)
    {
        if (root["tables"]![name]?.AsObject() is not { } table)
        {
            return [];
        }

        var types = RcaContract.Table(name).Columns.ToDictionary(c => c.Name, c => c.Type);
        var count = table["rows"]!.GetValue<int>();
        var rows = Enumerable.Range(0, count).Select(_ => new Dictionary<string, object?>(StringComparer.Ordinal)).ToList();
        foreach (var (column, values) in table["columns"]!.AsObject())
        {
            var array = values!.AsArray();
            for (var i = 0; i < count; i++)
            {
                rows[i][column] = array[i] is not { } value ? null : types[column] switch
                {
                    "string" => strings[value.GetValue<int>()],
                    "timestamp" => epoch.AddMilliseconds(value.GetValue<long>()),
                    "long" or "integer" => value.GetValue<long>(),
                    "double" => value.GetValue<double>(),
                    "boolean" => value.GetValue<bool>(),
                    _ => value.ToJsonString(),
                };
            }
        }

        return rows;
    }
}
