using System.Globalization;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// T3's automatic tuning as a DBA follows it (rca/README.md, Query Store): RCA-AZ-03's options and RCA-AZ-04's
/// recommendations, read every 30 s. What changed between two reads is an RCA Query Events row of kind tuning, timed
/// within those 30 s: an option's state, a recommendation that appeared, or a recommendation's state. The first read of
/// an observation only learns what's there, as RCA-SQL-15's does.
/// https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-automatic-tuning-options-transact-sql,
/// https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-tuning-recommendations-transact-sql.
/// </summary>
internal sealed class SqlAutomaticTuning(string target)
{
    public const string OptionsBlock = "RCA-AZ-03";

    public const string RecommendationsBlock = "RCA-AZ-04";

    private readonly Dictionary<string, (string? Actual, string? Desired)> options = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string?> recommendations = new(StringComparer.Ordinal);
    private DateTimeOffset? optionsRead;
    private DateTimeOffset? recommendationsRead;

    public void Reset()
    {
        options.Clear();
        recommendations.Clear();
        optionsRead = null;
        recommendationsRead = null;
    }

    /// <summary>RCA-AZ-03's rows: an option whose actual or desired state changed since the last read.</summary>
    public List<CaptureRow> Options(IReadOnlyList<CaptureValues> rows, DateTimeOffset now)
    {
        var events = new List<CaptureRow>();
        var at = At(rows, now);
        foreach (var row in rows)
        {
            if (TextNormalizer.Name(row.Text("name")) is not { } name)
            {
                continue;
            }

            var actual = TextNormalizer.Name(row.Text("actual_state_desc"));
            var desired = TextNormalizer.Name(row.Text("desired_state_desc"));
            if (optionsRead is { } previous && options.TryGetValue(name, out var before) && (before.Actual != actual || before.Desired != desired))
            {
                var reason = TextNormalizer.Name(row.Text("reason_desc")) is { } why ? $"; {why}" : string.Empty;
                events.Add(Event(OptionsBlock, at, previous, null, null, actual, before.Actual, $"Automatic tuning's {name} went from {before.Actual ?? "unknown"} to {actual ?? "unknown"} (desired {desired ?? "unknown"}{reason})."));
            }

            options[name] = (actual, desired);
        }

        optionsRead = at;
        return events;
    }

    /// <summary>RCA-AZ-04's rows: a recommendation that appeared since the last read, or whose state changed.</summary>
    public List<CaptureRow> Recommendations(IReadOnlyList<CaptureValues> rows, DateTimeOffset now)
    {
        var events = new List<CaptureRow>();
        var at = At(rows, now);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (TextNormalizer.Name(row.Text("name")) is not { } name)
            {
                continue;
            }

            seen.Add(name);
            var state = TextNormalizer.Name(row.Text("state"));
            var known = recommendations.TryGetValue(name, out var before);
            if (recommendationsRead is { } previous && (!known || before != state))
            {
                events.Add(Event(RecommendationsBlock, at, previous, row.Long("query_id"), row.Long("recommended_plan_id"), state, known ? before : null, Describe(row, state, appeared: !known)));
            }

            recommendations[name] = state;
        }

        // The engine keeps recommendations only until it restarts (Learn): one it stopped returning is forgotten.
        foreach (var gone in recommendations.Keys.Where(k => !seen.Contains(k)).ToList())
        {
            recommendations.Remove(gone);
        }

        recommendationsRead = at;
        return events;
    }

    /// <summary>
    /// A recommendation in words: <c>FORCE_LAST_GOOD_PLAN for query 412: plan 31 over plan 58, CPU time per execution
    /// 2.1 ms against 176 ms; Executing, applied by System at 17:09:22 UTC.</c> RCA-AZ-04's CPU averages are Learn's
    /// microseconds (regressedPlanCpuTimeAverage), in milliseconds here.
    /// </summary>
    private static string Describe(CaptureValues row, string? state, bool appeared)
    {
        var type = TextNormalizer.Name(row.Text("type")) ?? "A tuning recommendation";
        var text = row.Long("query_id") is { } query ? string.Create(CultureInfo.InvariantCulture, $"{type} for query {query}") : type;
        if (row.Long("recommended_plan_id") is { } recommended)
        {
            text += string.Create(CultureInfo.InvariantCulture, $": plan {recommended}");
            if (row.Long("regressed_plan_id") is { } regressed)
            {
                text += string.Create(CultureInfo.InvariantCulture, $" over plan {regressed}");
            }
        }

        if (Milliseconds(row.Double("recommended_plan_cpu_ms")) is { } good && Milliseconds(row.Double("regressed_plan_cpu_ms")) is { } bad)
        {
            text += string.Create(CultureInfo.InvariantCulture, $", CPU time per execution {good:0.###} ms against {bad:0.###} ms");
        }

        text += "; " + (appeared ? $"recommended, {state ?? "state unknown"}" : state ?? "state unknown");
        if (TextNormalizer.Name(row.Text("state_reason")) is { } why)
        {
            text += $" ({why})";
        }

        if (!appeared && TextNormalizer.Name(row.Text("execute_action_initiated_by")) is { } by && row.Time("execute_action_initiated_time") is { } applied)
        {
            text += string.Create(CultureInfo.InvariantCulture, $", applied by {by} at {applied:HH:mm:ss} UTC");
        }

        if (appeared && TextNormalizer.Detail(row.Text("reason")) is { } reason)
        {
            text += ": " + reason.TrimEnd('.');
        }

        return text + ".";
    }

    private static double? Milliseconds(double? microseconds) => microseconds is { } value && double.IsFinite(value) ? Math.Round(value / 1000, 3) : null;

    private static DateTimeOffset At(IReadOnlyList<CaptureValues> rows, DateTimeOffset now) => rows.Select(r => r.Time("captured_at_utc")).FirstOrDefault(t => t is not null) ?? now;

    private CaptureRow Event(string block, DateTimeOffset at, DateTimeOffset from, long? query, long? plan, string? state, string? before, string detail) =>
        new CaptureRow(RcaContract.QueryEvents, target, at, block)
            .Set("event_time_utc", at)
            .Set("time_from_utc", from)
            .Set("target", target)
            .Set("kind", "tuning")
            .Set("query_id", query)
            .Set("plan_id", plan)
            .Set("state", state)
            .Set("previous_state", before)
            .Set("detail", TextNormalizer.Detail(detail));
}
