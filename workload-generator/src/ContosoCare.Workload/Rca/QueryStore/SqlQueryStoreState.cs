using System.Globalization;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Query Store's state as RCA-SQL-15 reads it every 60 s on T1, T2, and T3, as a DBA checks it: the actual and desired
/// state, why it's read-only (readonly_reason, Learn's bit map), its capture mode, interval, and storage, and its forced
/// plans (https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql).
/// </summary>
internal sealed record SqlQueryStoreState(
    DateTimeOffset At,
    string? ActualState,
    string? DesiredState,
    long? ReadOnlyReason,
    string? CaptureMode,
    int? IntervalMinutes,
    long? StorageMb,
    long? MaxStorageMb,
    IReadOnlyDictionary<(long Query, long Plan), string> Forced)
{
    // readonly_reason's bits, as Learn lists them.
    private static readonly (long Bit, string Words)[] ReadOnlyBits =
    [
        (1, "the database is read-only"),
        (2, "the database is in single-user mode"),
        (4, "the database is in emergency mode"),
        (8, "the database is a secondary replica"),
        (65536, "Query Store reached its size limit (max_storage_size_mb)"),
        (131072, "the number of different statements reached Query Store's internal memory limit"),
        (262144, "what Query Store holds in memory to write to disk reached its internal memory limit, until it's written"),
        (524288, "the database reached its disk size limit"),
    ];

    public bool IsReadWrite => string.Equals(ActualState, "READ_WRITE", StringComparison.OrdinalIgnoreCase);

    /// <summary>RCA-SQL-15's one row, or null when it returned none.</summary>
    public static SqlQueryStoreState? From(IReadOnlyList<CaptureValues> rows, DateTimeOffset now)
    {
        if (rows.Count == 0)
        {
            return null;
        }

        var row = rows[0];
        return new SqlQueryStoreState(
            row.Time("captured_at_utc") ?? now,
            TextNormalizer.Name(row.Text("actual_state")),
            TextNormalizer.Name(row.Text("desired_state")),
            row.Long("readonly_reason"),
            TextNormalizer.Name(row.Text("query_capture_mode")),
            row.Long("interval_length_minutes") is { } minutes and > 0 and <= 1440 ? (int)minutes : null,
            row.Long("current_storage_size_mb"),
            row.Long("max_storage_size_mb"),
            ParseForced(row.Text("forced_plans")));
    }

    /// <summary>RCA-SQL-15's forced plans, <c>query_id:plan_id:forcing type</c>, semicolon-separated.</summary>
    public static Dictionary<(long Query, long Plan), string> ParseForced(string? text)
    {
        var forced = new Dictionary<(long, long), string>();
        foreach (var item in (text ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = item.Split(':');
            if (parts.Length >= 2
                && long.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var query)
                && long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var plan))
            {
                forced[(query, plan)] = parts.Length > 2 && parts[2].Length > 0 ? parts[2].ToUpperInvariant() : "MANUAL";
            }
        }

        return forced;
    }

    /// <summary>readonly_reason's bits in words; null when it has none.</summary>
    public static string? ReadOnlyWords(long? reason)
    {
        if (reason is not { } bits || bits == 0)
        {
            return null;
        }

        var words = ReadOnlyBits.Where(b => (bits & b.Bit) != 0).Select(b => b.Words).ToList();
        var known = ReadOnlyBits.Aggregate(0L, (all, b) => all | b.Bit);
        if ((bits & ~known) != 0)
        {
            words.Add(string.Create(CultureInfo.InvariantCulture, $"readonly_reason {bits & ~known}"));
        }

        return string.Join("; ", words);
    }

    /// <summary>The state in words, for a coverage gap: <c>Query Store on T1 was READ_ONLY at 12:01:00 UTC: Query Store reached its size limit (max_storage_size_mb), 1,000 of 1,000 MB.</c></summary>
    public string Describe(string target)
    {
        var text = string.Create(CultureInfo.InvariantCulture, $"Query Store on {target} was {ActualState ?? "unknown"} at {At:HH:mm:ss} UTC");
        if (ReadOnlyWords(ReadOnlyReason) is { } why)
        {
            text += ": " + why;
        }

        if (StorageMb is { } used && MaxStorageMb is { } limit)
        {
            text += string.Create(CultureInfo.InvariantCulture, $", {used:N0} of {limit:N0} MB");
        }

        return text + (IsReadWrite ? "." : ", so it recorded no new statistics while it stayed so.");
    }

    /// <summary>
    /// What changed since <paramref name="previous"/> as RCA Query Events rows, each timed within the 60 s between the
    /// two reads: Query Store's actual state or capture mode (kind state), and each plan forced or unforced.
    /// </summary>
    public IEnumerable<CaptureRow> Changes(SqlQueryStoreState previous, string target)
    {
        if (!string.Equals(previous.ActualState, ActualState, StringComparison.OrdinalIgnoreCase))
        {
            var detail = $"Query Store went from {previous.ActualState ?? "unknown"} to {ActualState ?? "unknown"}";
            if (ReadOnlyWords(ReadOnlyReason) is { } why)
            {
                detail += ": " + why;
            }

            yield return Event(previous, target, "state", null, null, null, ActualState, previous.ActualState, detail + ".");
        }

        if (!string.Equals(previous.CaptureMode, CaptureMode, StringComparison.OrdinalIgnoreCase))
        {
            yield return Event(previous, target, "state", null, null, null, CaptureMode, previous.CaptureMode, $"Query Store's capture mode went from {previous.CaptureMode ?? "unknown"} to {CaptureMode ?? "unknown"}.");
        }

        foreach (var ((query, plan), type) in Forced.OrderBy(f => f.Key))
        {
            if (!previous.Forced.TryGetValue((query, plan), out var before))
            {
                yield return Event(previous, target, "forced", query, plan, type, "forced", "not forced", string.Create(CultureInfo.InvariantCulture, $"Plan {plan} of query {query} forced {By(type)}."));
            }
            else if (!string.Equals(before, type, StringComparison.Ordinal))
            {
                yield return Event(previous, target, "forced", query, plan, type, "forced", "forced", string.Create(CultureInfo.InvariantCulture, $"Plan {plan} of query {query} forced {By(type)}, where it was forced {By(before)}."));
            }
        }

        foreach (var ((query, plan), type) in previous.Forced.OrderBy(f => f.Key))
        {
            if (!Forced.ContainsKey((query, plan)))
            {
                yield return Event(previous, target, "unforced", query, plan, type, "not forced", "forced", string.Create(CultureInfo.InvariantCulture, $"Plan {plan} of query {query} no longer forced; it was forced {By(type)}."));
            }
        }
    }

    private static string By(string type) => type switch
    {
        "AUTO" => "by automatic plan correction",
        "MANUAL" => "by hand (sys.sp_query_store_force_plan)",
        _ => $"({type})",
    };

    private CaptureRow Event(SqlQueryStoreState previous, string target, string kind, long? query, long? plan, string? forcingType, string? state, string? before, string detail) =>
        new CaptureRow(RcaContract.QueryEvents, target, At, SqlQueryStoreRows.StateBlock)
            .Set("event_time_utc", At)
            .Set("time_from_utc", previous.At)
            .Set("target", target)
            .Set("kind", kind)
            .Set("query_id", query)
            .Set("plan_id", plan)
            .Set("forcing_type", forcingType)
            .Set("state", state)
            .Set("previous_state", before)
            .Set("detail", TextNormalizer.Detail(detail));
}
