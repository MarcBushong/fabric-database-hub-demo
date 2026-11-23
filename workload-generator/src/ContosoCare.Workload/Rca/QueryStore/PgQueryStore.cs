using System.Globalization;
using System.Text;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Query Store's settings on a PostgreSQL server, as RCA-PG-13 read them from pg_settings
/// (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store): what it records, whether wait sampling
/// records and how often it samples, its interval and retention, and whether the server is in recovery, where Query Store
/// records nothing.
/// </summary>
internal sealed record PgQueryStoreSettings(
    DateTimeOffset At,
    bool? InRecovery,
    string? CaptureMode,
    string? WaitSamplingMode,
    TimeSpan? HistoryPeriod,
    TimeSpan? Interval,
    TimeSpan? Retention,
    IReadOnlyList<string> Missing)
{
    public const string CaptureModeSetting = "pg_qs.query_capture_mode";

    public const string WaitSamplingSetting = "pgms_wait_sampling.query_capture_mode";

    /// <summary>Wait sampling's default period, which RCA Query Waits' estimate uses when the setting isn't read.</summary>
    public static readonly TimeSpan DefaultHistoryPeriod = TimeSpan.FromMilliseconds(100);

    /// <summary>Query Store's default retention (pg_qs.retention_period_in_days).</summary>
    public static readonly TimeSpan DefaultRetention = TimeSpan.FromDays(7);

    private static readonly string[] Read = [CaptureModeSetting, WaitSamplingSetting, "pgms_wait_sampling.history_period", "pg_qs.interval_length_minutes", "pg_qs.retention_period_in_days"];

    /// <summary>Both modes, as RCA Query Coverage's capture_mode says them; null when neither was read.</summary>
    public string? Modes => CaptureMode is null && WaitSamplingMode is null
        ? null
        : $"{CaptureModeSetting} {CaptureMode ?? "missing"}; {WaitSamplingSetting} {WaitSamplingMode ?? "missing"}";

    public int? IntervalMinutes => Interval is { } interval ? (int)Math.Round(interval.TotalMinutes) : null;

    public static PgQueryStoreSettings Parse(IReadOnlyList<CaptureValues> rows, DateTimeOffset now)
    {
        var byName = new Dictionary<string, CaptureValues>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (row.Text("name") is { } name)
            {
                byName[name] = row;
            }
        }

        var at = rows.Select(r => r.Time("captured_at")).FirstOrDefault(t => t is not null) ?? now;
        return new PgQueryStoreSettings(
            at,
            rows.Select(r => r.Bool("in_recovery")).FirstOrDefault(r => r is not null),
            Mode(byName, CaptureModeSetting),
            Mode(byName, WaitSamplingSetting),
            Duration(byName, "pgms_wait_sampling.history_period", "ms"),
            Duration(byName, "pg_qs.interval_length_minutes", "min"),
            Duration(byName, "pg_qs.retention_period_in_days", "d"),
            [.. Read.Where(n => !byName.ContainsKey(n))]);
    }

    /// <summary>What these settings keep out of the capture, one gap per line (rca/README.md, Query Store).</summary>
    public IEnumerable<string> Gaps(string target)
    {
        if (InRecovery == true)
        {
            yield return $"{target} is in recovery, which records nothing in Query Store.";
            yield break;
        }

        if (Missing.Contains(CaptureModeSetting, StringComparer.Ordinal))
        {
            yield return $"{target} has no {CaptureModeSetting} setting, so Query Store isn't on this server.";
            yield break;
        }

        if (Missing.Count > 0)
        {
            yield return $"{target} reported no {string.Join(", ", Missing)}: the defaults are taken for them.";
        }

        switch (CaptureMode)
        {
            case "none":
                yield return $"{target}'s Query Store records nothing: {CaptureModeSetting} is none. Learn advises keeping it off on a Burstable size; on any other, ./scripts/deploy.ps1 turns it on.";
                break;
            case "top":
                yield return $"{target}'s Query Store records top-level statements only ({CaptureModeSetting} top): the statements that functions run aren't recorded.";
                break;
        }

        if (CaptureMode != "none" && !string.Equals(WaitSamplingMode, "all", StringComparison.Ordinal))
        {
            yield return $"{target}'s wait sampling is {WaitSamplingMode ?? "missing"} ({WaitSamplingSetting}), so Query Store holds no waits per query.";
        }
    }

    private static string? Mode(Dictionary<string, CaptureValues> byName, string name) =>
        byName.TryGetValue(name, out var row) ? row.Text("setting")?.Trim().ToLowerInvariant() : null;

    /// <summary>A setting in the unit pg_settings gives it, or in <paramref name="assumed"/> when it gives none.</summary>
    private static TimeSpan? Duration(Dictionary<string, CaptureValues> byName, string name, string assumed)
    {
        if (!byName.TryGetValue(name, out var row) || row.Double("setting") is not { } value || value <= 0)
        {
            return null;
        }

        return (string.IsNullOrEmpty(row.Text("unit")) ? assumed : row.Text("unit")) switch
        {
            "ms" => TimeSpan.FromMilliseconds(value),
            "s" => TimeSpan.FromSeconds(value),
            "min" => TimeSpan.FromMinutes(value),
            "h" => TimeSpan.FromHours(value),
            "d" => TimeSpan.FromDays(value),
            _ => null,
        };
    }
}

/// <summary>
/// The harness, as RCA-PG-16 read it from contosocare's own catalog: the functions the demo marks as its harness, the
/// tables only they write, and every other table, each as a regular-expression literal for RCA-PG-14's leave-out; and
/// why no table is the harness's alone, when RCA-PG-16 was unsure (an unmarked function that runs dynamic SQL, or keeps
/// no source in pg_proc). With no function marked, every list but the other tables is empty, and RCA-PG-14 leaves out
/// nothing as the harness's.
/// </summary>
internal sealed record PgHarness(IReadOnlyList<string> Functions, IReadOnlyList<string> HarnessTables, IReadOnlyList<string> OtherTables, IReadOnlyList<string> Unsure)
{
    public static PgHarness Parse(IReadOnlyList<CaptureValues> rows)
    {
        List<string> Names(string kind) =>
            [.. rows.Where(r => string.Equals(r.Text("kind"), kind, StringComparison.Ordinal)).Select(r => r.Text("name")).OfType<string>().Where(n => n.Length > 0).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)];

        var unsure = Names("unsure");
        return new PgHarness([.. Names("function").Select(Literal)], unsure.Count > 0 ? [] : [.. Names("harness_table").Select(Literal)], [.. Names("table").Select(Literal)], unsure);
    }

    /// <summary>What RCA-PG-16's unsure rows mean, in the coverage's words; null when it was sure.</summary>
    public string? UnsureGap(string database)
    {
        if (Unsure.Count == 0)
        {
            return null;
        }

        var why = Unsure.Select(u => u switch
        {
            "dynamic_sql" => "runs dynamic SQL (EXECUTE)",
            "no_source" => "keeps no source in pg_proc (a BEGIN ATOMIC body)",
            _ => "can't be read (" + u + ")",
        });
        return $"A function in {database} that isn't the harness's {string.Join(", and one ", why)}, so it could write any table: no table is left out as only the harness's, and the statements the harness's functions run stay in the evidence.";
    }

    /// <summary>
    /// A name as a literal in PostgreSQL's regular expressions: a backslash before every character that isn't a letter, a
    /// digit, or an underscore (https://www.postgresql.org/docs/18/functions-matching.html#POSIX-ESCAPE-SEQUENCES).
    /// </summary>
    public static string Literal(string name)
    {
        var text = new StringBuilder(name.Length);
        foreach (var c in name)
        {
            if (!char.IsLetterOrDigit(c) && c != '_')
            {
                text.Append('\\');
            }

            text.Append(c);
        }

        return text.ToString();
    }
}

/// <summary>
/// The sidecar's rows from T4's Query Store reads (rca/history-tables.json): RCA-PG-14's statistics, RCA-PG-15's sampled
/// waits, RCA-PG-13's state changes, and each read's coverage. Text is normalized as RCA Sessions' is; times are UTC.
/// </summary>
internal static class PgQueryStoreRows
{
    public const string Settings = "RCA-PG-13";

    public const string Statistics = "RCA-PG-14";

    public const string Waits = "RCA-PG-15";

    public const string Harness = "RCA-PG-16";

    /// <summary>One RCA Query Stats row, or null for a row without its interval or query.</summary>
    public static CaptureRow? Stats(string target, CaptureValues row, DateTimeOffset now, TimeSpan? historyPeriod)
    {
        if (row.Time("interval_start_utc") is not { } start || row.Time("interval_end_utc") is not { } end || row.Long("query_id") is not { } query)
        {
            return null;
        }

        var at = row.Time("captured_at") ?? now;
        var samples = row.Double("wait_samples") ?? 0;
        return new CaptureRow(RcaContract.QueryStats, target, at, Statistics)
            .Set("captured_at_utc", at)
            .Set("target", target)
            .Set("interval_start_utc", start)
            .Set("interval_end_utc", end)
            .Set("query_id", query)
            .Set("plan_id", row.Long("plan_id") ?? 0L)
            .Set("login_name", TextNormalizer.Name(row.Text("login_name")))
            .Set("statement_text", TextNormalizer.Statement(row.Text("query_sql_text")))
            .Set("executions", row.Long("executions") ?? 0L)
            .Set("duration_ms", row.Double("duration_ms"))
            .Set("max_duration_ms", row.Double("max_duration_ms"))
            .Set("logical_reads", row.Double("logical_reads"))
            .Set("physical_reads", row.Double("physical_reads"))
            .Set("row_count", row.Double("row_count"))
            .Set("tempdb_kb", row.Double("tempdb_kb"))
            .Set("wait_ms", samples > 0 ? samples * (historyPeriod ?? PgQueryStoreSettings.DefaultHistoryPeriod).TotalMilliseconds : null);
    }

    /// <summary>One RCA Query Waits row, or null for a row without its interval, query, or event type (a backend on CPU).</summary>
    public static CaptureRow? Wait(string target, CaptureValues row, DateTimeOffset now, TimeSpan? historyPeriod)
    {
        if (row.Time("interval_start_utc") is not { } start || row.Time("interval_end_utc") is not { } end || row.Long("query_id") is not { } query
            || TextNormalizer.Name(row.Text("wait_category")) is not { } category)
        {
            return null;
        }

        var at = row.Time("captured_at") ?? now;
        var samples = row.Long("samples") ?? 0;
        return new CaptureRow(RcaContract.QueryWaits, target, at, Waits)
            .Set("captured_at_utc", at)
            .Set("target", target)
            .Set("interval_start_utc", start)
            .Set("interval_end_utc", end)
            .Set("query_id", query)
            .Set("plan_id", row.Long("plan_id") ?? 0L)
            .Set("login_name", TextNormalizer.Name(row.Text("login_name")))
            .Set("wait_category", category)
            .Set("wait_event", TextNormalizer.Name(row.Text("wait_event")))
            .Set("wait_ms", samples * (historyPeriod ?? PgQueryStoreSettings.DefaultHistoryPeriod).TotalMilliseconds)
            .Set("samples", samples);
    }

    /// <summary>A change of Query Store's capture mode or wait sampling's between two reads: one RCA Query Events row.</summary>
    public static CaptureRow? StateChange(string target, PgQueryStoreSettings previous, PgQueryStoreSettings current)
    {
        var changes = new List<string>();
        if (!string.Equals(previous.CaptureMode, current.CaptureMode, StringComparison.Ordinal))
        {
            changes.Add($"{PgQueryStoreSettings.CaptureModeSetting} went from {previous.CaptureMode ?? "missing"} to {current.CaptureMode ?? "missing"}");
        }

        if (!string.Equals(previous.WaitSamplingMode, current.WaitSamplingMode, StringComparison.Ordinal))
        {
            changes.Add($"{PgQueryStoreSettings.WaitSamplingSetting} went from {previous.WaitSamplingMode ?? "missing"} to {current.WaitSamplingMode ?? "missing"}");
        }

        if (changes.Count == 0)
        {
            return null;
        }

        return new CaptureRow(RcaContract.QueryEvents, target, current.At, Settings)
            .Set("event_time_utc", current.At)
            .Set("time_from_utc", previous.At)
            .Set("target", target)
            .Set("kind", "state")
            .Set("state", current.CaptureMode)
            .Set("previous_state", previous.CaptureMode)
            .Set("detail", TextNormalizer.Detail(string.Create(CultureInfo.InvariantCulture, $"On {target}, {string.Join(", and ", changes)} between the reads at {previous.At:HH:mm:ss} and {current.At:HH:mm:ss} UTC.")));
    }

    /// <summary>
    /// One read's RCA Query Coverage row: its own window, Query Store's state as read, the intervals it returned, the time
    /// still pending publication, the blocks that returned rows, and its gaps. The sidecar's export merges a span's rows
    /// into one per target and sidecar.
    /// </summary>
    public static CaptureRow Coverage(string target, QueryCoverage coverage)
    {
        ArgumentNullException.ThrowIfNull(coverage);
        var gaps = coverage.Gaps.Select(TextNormalizer.Detail).OfType<string>().Distinct(StringComparer.Ordinal).ToList();
        var text = gaps.Count == 0 ? null : string.Join('\n', gaps);
        if (text is { Length: > RcaContract.MaximumStringLength })
        {
            text = text[..(RcaContract.MaximumStringLength - 3)] + "...";
        }

        var settings = coverage.Settings is { InRecovery: not true } read ? read : null;
        return new CaptureRow(RcaContract.QueryCoverage, target, coverage.WindowEnd, coverage.Sources.Count > 0 ? string.Join(',', coverage.Sources) : Settings)
            .Set("target", target)
            .Set("window_start_utc", coverage.WindowStart)
            .Set("window_end_utc", coverage.WindowEnd)
            .Set("state", settings?.CaptureMode)
            .Set("capture_mode", settings?.Modes)
            .Set("interval_minutes", settings?.IntervalMinutes)
            .Set("read_from_utc", coverage.ReadFrom)
            .Set("read_to_utc", coverage.ReadTo)
            .Set("pending_from_utc", coverage.Pending?.From)
            .Set("pending_to_utc", coverage.Pending?.To)
            .Set("backfill", coverage.Backfill)
            .Set("sources", coverage.Sources.Count > 0 ? string.Join(',', coverage.Sources.Order(StringComparer.Ordinal)) : null)
            .Set("gaps", text);
    }

    /// <summary>What the coverage says of time Query Store hadn't published (rca/README.md, Pending publication).</summary>
    public static string PendingGap(string target, DateTimeOffset from, DateTimeOffset to) =>
        string.Create(CultureInfo.InvariantCulture, $"Pending publication: Query Store shows an interval only once it ends, so {from:HH:mm} to {to:HH:mm} is read at the next start while {target} runs.");

    /// <summary>What a read replica's coverage says: Query Store records nothing there.</summary>
    public static string ReplicaGap(string target) => $"{target} is a read replica, which records nothing in Query Store.";

    /// <summary>
    /// T4's read replica's RCA Query Coverage row from RCA-PG-13 (null when it failed, and <paramref name="failure"/> says
    /// why): a server in recovery records nothing in Query Store, and the observer reads Query Store on T4 alone.
    /// </summary>
    public static CaptureRow ReplicaCoverage(string target, DateTimeOffset windowStart, DateTimeOffset now, IReadOnlyList<CaptureValues>? rows, string? failure = null)
    {
        var coverage = new QueryCoverage(windowStart, now);
        if (rows is null)
        {
            coverage.Gaps.Add(string.Create(CultureInfo.InvariantCulture, $"{Settings} couldn't be read on {target} at {now:HH:mm} UTC: {failure ?? "the block failed."}"));
            return Coverage(target, coverage);
        }

        var settings = PgQueryStoreSettings.Parse(rows, now);
        if (rows.Count > 0)
        {
            coverage.Sources.Add(Settings);
        }

        coverage.Settings = settings;
        coverage.Gaps.Add(settings.InRecovery == false
            ? $"{target} isn't in recovery, but the observer reads Query Store on T4 alone."
            : ReplicaGap(target));
        return Coverage(target, coverage);
    }
}

/// <summary>What one read covered, for its RCA Query Coverage row.</summary>
internal sealed class QueryCoverage(DateTimeOffset windowStart, DateTimeOffset windowEnd)
{
    public DateTimeOffset WindowStart { get; } = windowStart;

    public DateTimeOffset WindowEnd { get; } = windowEnd;

    public PgQueryStoreSettings? Settings { get; set; }

    public DateTimeOffset? ReadFrom { get; set; }

    public DateTimeOffset? ReadTo { get; set; }

    public (DateTimeOffset From, DateTimeOffset To)? Pending { get; set; }

    public bool Backfill { get; set; }

    public SortedSet<string> Sources { get; } = new(StringComparer.Ordinal);

    public List<string> Gaps { get; } = [];

    /// <summary>Widens the intervals read to take in a read's rows.</summary>
    public void Took(DateTimeOffset start, DateTimeOffset end)
    {
        ReadFrom = ReadFrom is { } from && from <= start ? from : start;
        ReadTo = ReadTo is { } to && to >= end ? to : end;
    }
}
