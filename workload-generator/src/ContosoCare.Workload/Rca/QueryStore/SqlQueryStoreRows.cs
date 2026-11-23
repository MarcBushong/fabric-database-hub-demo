using System.Globalization;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// The sidecar's rows from SQL Server's and Azure SQL Database's Query Store (rca/history-tables.json): RCA-SQL-10's
/// runtime statistics (RCA Query Stats), RCA-SQL-11's waits (RCA Query Waits), and RCA-SQL-14's plans (RCA Query Plans),
/// on T1, T2, and T3. The values are the blocks' own: interval totals the block already summed over Query Store's rows,
/// each average times its executions. Text is normalized as RCA Sessions' is, and times are UTC. A row without the keys
/// its table requires isn't written.
/// </summary>
internal static class SqlQueryStoreRows
{
    public const string StatsBlock = "RCA-SQL-10";

    public const string WaitsBlock = "RCA-SQL-11";

    public const string PlansBlock = "RCA-SQL-14";

    public const string StateBlock = "RCA-SQL-15";

    /// <summary>One plan's runtime statistics over one interval, as one read saw them.</summary>
    public static CaptureRow? Stats(string target, CaptureValues row, DateTimeOffset now)
    {
        if (Interval(row) is not { } interval || row.Long("query_id") is not { } query || row.Long("plan_id") is not { } plan || row.Long("executions") is not { } executions)
        {
            return null;
        }

        var at = row.Time("captured_at_utc") ?? now;
        return new CaptureRow(RcaContract.QueryStats, target, at, StatsBlock)
            .Set("captured_at_utc", at)
            .Set("target", target)
            .Set("interval_start_utc", interval.Start)
            .Set("interval_end_utc", interval.End)
            .Set("query_id", query)
            .Set("plan_id", plan)
            .Set("query_hash", Hash(row.Get("query_hash")))
            .Set("plan_hash", Hash(row.Get("plan_hash")))
            .Set("module_name", TextNormalizer.Name(row.Text("module_name")))
            .Set("statement_text", TextNormalizer.Statement(row.Text("query_sql_text")))
            .Set("executions", executions)
            .Set("aborted_executions", row.Long("aborted_executions"))
            .Set("cpu_ms", Milliseconds(row.Double("cpu_ms")))
            .Set("duration_ms", Milliseconds(row.Double("duration_ms")))
            .Set("max_duration_ms", Milliseconds(row.Double("max_duration_ms")))
            .Set("logical_reads", Whole(row.Double("logical_reads")))
            .Set("physical_reads", Whole(row.Double("physical_reads")))
            .Set("row_count", Whole(row.Double("row_count")))
            .Set("log_bytes", Whole(row.Double("log_bytes")))
            .Set("tempdb_kb", Whole(row.Double("tempdb_kb")))
            .Set("max_used_memory_kb", Whole(row.Double("max_used_memory_kb")))
            .Set("max_dop", row.Long("max_dop"))
            .Set("wait_ms", Milliseconds(row.Double("wait_ms")))
            .Set("first_execution_utc", row.Time("first_execution_utc"))
            .Set("last_execution_utc", row.Time("last_execution_utc"));
    }

    /// <summary>One wait category of one plan over one interval.</summary>
    public static CaptureRow? Wait(string target, CaptureValues row, DateTimeOffset now)
    {
        if (Interval(row) is not { } interval || row.Long("query_id") is not { } query || row.Long("plan_id") is not { } plan
            || TextNormalizer.Name(row.Text("wait_category")) is not { } category || Milliseconds(row.Double("wait_ms")) is not { } waited)
        {
            return null;
        }

        var at = row.Time("captured_at_utc") ?? now;
        return new CaptureRow(RcaContract.QueryWaits, target, at, WaitsBlock)
            .Set("captured_at_utc", at)
            .Set("target", target)
            .Set("interval_start_utc", interval.Start)
            .Set("interval_end_utc", interval.End)
            .Set("query_id", query)
            .Set("plan_id", plan)
            .Set("wait_category", category)
            .Set("wait_ms", waited)
            .Set("max_wait_ms", Milliseconds(row.Double("max_wait_ms")));
    }

    /// <summary>One plan as one read saw it, with its shape when the observer has reduced its showplan.</summary>
    public static CaptureRow? Plan(string target, CaptureValues row, DateTimeOffset now, PlanShape? shape)
    {
        if (row.Long("query_id") is not { } query || row.Long("plan_id") is not { } plan)
        {
            return null;
        }

        var at = row.Time("captured_at_utc") ?? now;
        return new CaptureRow(RcaContract.QueryPlans, target, at, PlansBlock)
            .Set("captured_at_utc", at)
            .Set("target", target)
            .Set("query_id", query)
            .Set("plan_id", plan)
            .Set("query_hash", Hash(row.Get("query_hash")))
            .Set("plan_hash", Hash(row.Get("plan_hash")))
            .Set("module_name", TextNormalizer.Name(row.Text("module_name")))
            .Set("statement_text", TextNormalizer.Statement(row.Text("query_sql_text")))
            .Set("compiled_utc", row.Time("compiled_utc"))
            .Set("last_compiled_utc", row.Time("last_compiled_utc"))
            .Set("last_execution_utc", row.Time("last_execution_utc"))
            .Set("compiles", row.Long("compiles"))
            .Set("is_forced_plan", row.Bool("is_forced_plan"))
            .Set("forcing_type", TextNormalizer.Name(row.Text("forcing_type")))
            .Set("force_failures", row.Long("force_failures"))
            .Set("last_force_failure", TextNormalizer.Name(row.Text("last_force_failure")))
            .Set("plans_for_query", row.Long("plans_for_query") is { } count ? (int?)Math.Clamp(count, 0, int.MaxValue) : null)
            .Set("estimated_cost", shape?.EstimatedCost)
            .Set("is_parallel", row.Bool("is_parallel") ?? shape?.Parallel)
            .Set("plan_summary", shape?.Summary);
    }

    /// <summary>A row's Query Store interval, the key of its statistics and waits.</summary>
    public static (DateTimeOffset Start, DateTimeOffset End)? Interval(CaptureValues row) =>
        row.Time("interval_start_utc") is { } start && row.Time("interval_end_utc") is { } end && end > start ? (start, end) : null;

    /// <summary>A written row's interval.</summary>
    public static (DateTimeOffset Start, DateTimeOffset End) Interval(CaptureRow row) =>
        ((DateTimeOffset)row.Get("interval_start_utc")!, (DateTimeOffset)row.Get("interval_end_utc")!);

    /// <summary>Query Store's binary(8) hashes as <c>0x</c> and 16 hexadecimal digits.</summary>
    public static string? Hash(object? value) => value switch
    {
        byte[] { Length: > 0 } bytes => "0x" + Convert.ToHexString(bytes),
        string text when text.StartsWith("0x", StringComparison.OrdinalIgnoreCase) && text.Length > 2 && text[2..].All(char.IsAsciiHexDigit) => "0x" + text[2..].ToUpperInvariant(),
        _ => null,
    };

    /// <summary>A list of IDs as a block's comma-separated parameter.</summary>
    public static string Ids(IEnumerable<long> ids) => string.Join(',', ids.Distinct().Order().Select(id => id.ToString(CultureInfo.InvariantCulture)));

    private static double? Milliseconds(double? value) => value is { } ms && double.IsFinite(ms) ? Math.Round(ms, 3) : null;

    private static double? Whole(double? value) => value is { } number && double.IsFinite(number) ? Math.Round(number) : null;
}
