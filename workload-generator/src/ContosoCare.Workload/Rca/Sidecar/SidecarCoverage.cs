using System.Globalization;
using System.Text;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// One target's RCA Query Coverage row in one sidecar, merged from the rows each read wrote (A1's and A2's): the window
/// from the earliest start to the latest end; Query Store's state, capture mode, and interval as the latest read that had
/// them; the pending range as the latest read; the intervals read from the earliest to the latest; backfill when any read
/// was; every capture ID that returned rows, in catalog order; and every distinct gap, in time order. The reducer adds its
/// cuts to the gaps.
/// </summary>
internal sealed class SidecarCoverage
{
    /// <summary>The sidecar's capture IDs in catalog order (rca/capture/README.md).</summary>
    public static readonly IReadOnlyList<string> SourceOrder = ["RCA-SQL-10", "RCA-SQL-11", "RCA-SQL-14", "RCA-SQL-15", "RCA-AZ-03", "RCA-AZ-04", "RCA-PG-13", "RCA-PG-14", "RCA-PG-15", "RCA-PG-16", "RCA-PG-17"];

    private SidecarCoverage(string target)
    {
        Target = target;
    }

    public string Target { get; }

    public DateTimeOffset WindowStart { get; private set; }

    public DateTimeOffset WindowEnd { get; private set; }

    public string? State { get; private set; }

    public string? CaptureMode { get; private set; }

    public long? IntervalMinutes { get; private set; }

    public DateTimeOffset? ReadFrom { get; private set; }

    public DateTimeOffset? ReadTo { get; private set; }

    public DateTimeOffset? PendingFrom { get; private set; }

    public DateTimeOffset? PendingTo { get; private set; }

    public bool Backfill { get; private set; }

    public IReadOnlyList<string> Sources { get; private set; } = [];

    /// <summary>The reads' gaps, one per line, each once, in time order.</summary>
    public IReadOnlyList<string> Gaps { get; private set; } = [];

    /// <summary>
    /// Merges one target's per-read coverage rows, in the order they were written, and takes the capture IDs of its other
    /// rows too (who held T4's connections has no coverage row of its own). A target needs at least one read: one with
    /// rows and none gets its coverage row from the reducer, which says no read is recorded.
    /// </summary>
    public static SidecarCoverage Merge(string target, IReadOnlyList<CaptureRow> coverage, IReadOnlyList<CaptureRow> rows)
    {
        ArgumentNullException.ThrowIfNull(coverage);
        ArgumentNullException.ThrowIfNull(rows);
        if (coverage.Count == 0)
        {
            throw new ArgumentException($"{target} has no Query Store read to merge; the reducer gives it its coverage row.", nameof(coverage));
        }

        var merged = new SidecarCoverage(target);
        var reads = coverage.Select((row, index) => (Row: row, Index: index))
            .OrderBy(r => Time(r.Row, "window_end_utc") ?? r.Row.At)
            .ThenBy(r => r.Index)
            .Select(r => r.Row)
            .ToList();
        var sources = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in reads.Concat(rows))
        {
            var ids = row.Table == RcaContract.QueryCoverage ? row.Get("sources") as string : row.Source;
            foreach (var id in (ids ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                if (id.StartsWith("RCA-", StringComparison.Ordinal))
                {
                    sources.Add(id);
                }
            }
        }

        merged.Sources = [.. SourceOrder.Where(sources.Contains), .. sources.Where(s => !SourceOrder.Contains(s)).Order(StringComparer.Ordinal)];
        merged.WindowStart = reads.Min(r => Time(r, "window_start_utc") ?? r.At);
        merged.WindowEnd = reads.Max(r => Time(r, "window_end_utc") ?? r.At);
        if (reads.LastOrDefault(r => r.Get("state") is not null || r.Get("capture_mode") is not null || r.Get("interval_minutes") is not null) is { } state)
        {
            merged.State = state.Get("state") as string;
            merged.CaptureMode = state.Get("capture_mode") as string;
            merged.IntervalMinutes = state.Get("interval_minutes") switch
            {
                long minutes => minutes,
                int minutes => minutes,
                _ => null,
            };
        }

        var latest = reads[^1];
        merged.PendingFrom = Time(latest, "pending_from_utc");
        merged.PendingTo = Time(latest, "pending_to_utc");
        var from = reads.Select(r => Time(r, "read_from_utc")).Where(t => t is not null).ToList();
        var to = reads.Select(r => Time(r, "read_to_utc")).Where(t => t is not null).ToList();
        merged.ReadFrom = from.Count == 0 ? null : from.Min();
        merged.ReadTo = to.Count == 0 ? null : to.Max();
        merged.Backfill = reads.Any(r => r.Get("backfill") is true);
        merged.Gaps = [.. reads
            .Select(r => r.Get("gaps") as string)
            .OfType<string>()
            .SelectMany(g => g.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            .Distinct(StringComparer.Ordinal)];
        return merged;
    }

    /// <summary>The merged coverage row, its gaps one per line within a string's 4,000 characters; the reducer adds its cuts after them.</summary>
    public CaptureRow Row()
    {
        return new CaptureRow(RcaContract.QueryCoverage, Target, WindowStart, "coverage")
            .Set("target", Target)
            .Set("window_start_utc", WindowStart)
            .Set("window_end_utc", WindowEnd)
            .Set("state", State)
            .Set("capture_mode", CaptureMode)
            .Set("interval_minutes", IntervalMinutes)
            .Set("read_from_utc", ReadFrom)
            .Set("read_to_utc", ReadTo)
            .Set("pending_from_utc", PendingFrom)
            .Set("pending_to_utc", PendingTo)
            .Set("backfill", Backfill)
            .Set("sources", Sources.Count == 0 ? null : string.Join(',', Sources))
            .Set("gaps", Gaps.Count == 0 ? null : Lines(Gaps));
    }

    /// <summary>Gaps one per line, as RCA Coverage's are, within a string's 4,000 characters.</summary>
    private static string Lines(IReadOnlyList<string> lines)
    {
        var builder = new StringBuilder();
        for (var i = 0; i < lines.Count; i++)
        {
            var line = (builder.Length == 0 ? string.Empty : "\n") + lines[i];
            if (builder.Length + line.Length > RcaContract.MaximumStringLength - 40)
            {
                builder.Append(CultureInfo.InvariantCulture, $"\n... and {lines.Count - i} more.");
                break;
            }

            builder.Append(line);
        }

        return builder.ToString();
    }

    private static DateTimeOffset? Time(CaptureRow row, string column) => row.Get(column) as DateTimeOffset?;
}
