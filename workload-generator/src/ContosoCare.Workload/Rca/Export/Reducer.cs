using System.Globalization;
using System.Text;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Export;

/// <summary>What one export took for one target: its window, rows, notes, and when it was observed.</summary>
internal sealed record TargetCapture(
    string Target,
    DateTimeOffset From,
    DateTimeOffset To,
    IReadOnlyList<CaptureRow> Rows,
    IReadOnlyList<CaptureNote> Notes,
    IReadOnlyList<(DateTimeOffset From, DateTimeOffset To)> Observed,
    int LateRows = 0,
    bool Unobserved = false);

/// <summary>The detection tables of one document, its coverage, and the capture problems the export reports.</summary>
internal sealed record ReducedCapture(Dictionary<string, List<CaptureRow>> Tables, IReadOnlyList<string> Warnings, IReadOnlyList<string> Cuts);

/// <summary>
/// The reducer (ADR 0031, the export): turns what the observer captured into a document's detection tables. Identical
/// events in a minute become one counted row; every target gets an RCA Coverage row with what was captured, from which
/// capture IDs, and what wasn't, with why. When the document's gzip is over its budget, it cuts in reverse priority
/// (blocking samples thinned inside each chain formation, keeping its first, peak, and last; secondary counters; the
/// sentinel's samples outside capture episodes; ...), and records each cut as a gap in RCA Coverage. It reads only the
/// capture: never what the workload planned or reports about itself.
/// </summary>
internal static class Reducer
{
    /// <summary>A sentinel interval this long without a sample means the sentinel didn't run (three 30-s samples, and a margin).</summary>
    public static readonly TimeSpan SentinelHole = TimeSpan.FromSeconds(95);

    private static readonly HashSet<string> SecondaryMetrics = new(StringComparer.Ordinal)
    {
        "user_connections", "active_transactions", "memory_grants_outstanding", "log_flushes", "log_flush_wait_ms",
        "connections_idle", "connections_active", "reserved_connections", "temp_files", "xact_rollback",
    };

    private static readonly string[] SentinelSources = ["RCA-SQL-09", "RCA-PG-10", "RCA-PG-03"];

    // Enough halvings to bring any count the store's 20 MB per target allows down to one row.
    private const int Halvings = 24;

    /// <param name="captures">Each target's capture for the document.</param>
    /// <param name="measure">The gzip size of a document with these detection tables.</param>
    /// <param name="budget">The most gzip the detection tables may take.</param>
    public static ReducedCapture Reduce(IReadOnlyList<TargetCapture> captures, Func<Dictionary<string, List<CaptureRow>>, int> measure, int budget)
    {
        var work = captures.Select(c => new Working(c)).ToList();
        var cuts = new List<string>();
        foreach (var step in Steps())
        {
            var tables = Assemble(work);

            // Past a document's 20,000 rows or strings is over budget too: the encoder refuses it, so it isn't measured.
            if (EvidenceDocument.WithinLimits(tables) && measure(tables) <= budget)
            {
                return new ReducedCapture(tables, Warnings(captures), cuts);
            }

            foreach (var target in work)
            {
                if (step(target) is { } line)
                {
                    target.Cuts.Add("export budget: " + line);
                    cuts.Add(target.Capture.Target + ": " + line);
                }
            }
        }

        return new ReducedCapture(Assemble(work), Warnings(captures), cuts);
    }

    /// <summary>Identical events in one minute (same kind, code, module, program, run token, and detail) become one row with their count.</summary>
    public static List<CaptureRow> Aggregate(IEnumerable<CaptureRow> events)
    {
        var result = new List<CaptureRow>();
        var groups = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal);
        foreach (var row in events)
        {
            var kind = row.Get("kind") as string;
            if (kind is "capture" or "deadlock")
            {
                result.Add(row);
                continue;
            }

            var key = string.Join('\u001f', Minute(row.At).ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture), Text(row, "target"), kind, Text(row, "event_name"), Text(row, "code"), Text(row, "severity"), Text(row, "intercepted"), Text(row, "program_name"), Text(row, "run_token"), Text(row, "login_name"), Text(row, "host_name"), Text(row, "module_name"), Text(row, "object_name"), Text(row, "lock_mode"), Text(row, "detail"));
            if (!groups.TryGetValue(key, out var group))
            {
                groups[key] = group = [];
            }

            group.Add(row);
        }

        foreach (var group in groups.Values)
        {
            if (group.Count == 1)
            {
                result.Add(group[0]);
                continue;
            }

            var first = group[0];
            var minute = Minute(first.At);
            var sessions = group.Select(r => r.Get("session_id")).Distinct().ToList();
            var merged = new CaptureRow(first.Table, first.Target, minute, first.Source);
            foreach (var (column, value) in first.Values)
            {
                merged.Set(column, value);
            }

            merged.Set("event_time_utc", minute)
                .Set("session_id", sessions.Count == 1 ? sessions[0] : null)
                .Set("event_count", group.Sum(r => r.Get("event_count") is long count ? count : 1L));
            result.Add(merged);
        }

        return [.. result.OrderBy(r => r.At)];
    }

    private static string Text(CaptureRow row, string column) => Convert.ToString(row.Get(column), CultureInfo.InvariantCulture) ?? string.Empty;

    private static DateTimeOffset Minute(DateTimeOffset at) => new(at.UtcDateTime.Ticks - (at.UtcDateTime.Ticks % TimeSpan.TicksPerMinute), TimeSpan.Zero);

    /// <summary>The cuts, in the order they're made: each returns what it cut for one target, or null when it cut nothing there.</summary>
    private static IEnumerable<Func<Working, string?>> Steps()
    {
        yield return _ => null;
        yield return w => ThinSessions(w, 2);
        yield return w => ThinSessions(w, 4);
        yield return DropSecondary;
        yield return w => ThinSessions(w, int.MaxValue);
        yield return w => ThinSentinel(w, RcaContract.Replica, 2);
        yield return w => ThinSentinel(w, RcaContract.Resource, 2);
        yield return w => ThinResourceStats(w, 2);
        yield return w => ThinSentinel(w, RcaContract.Resource, 4);
        yield return PeakOnly;
        yield return w => ThinResourceStats(w, 4);
        yield return DropSessions;
        yield return KeepEssentials;

        // Past even that (thousands of deadlocks, or days of episodes between exports): the deadlock graphs go, then the
        // deadlocks and the episodes are halved until the document fits. The coverage rows always stay.
        yield return DropDeadlockGraphs;
        for (var i = 0; i < Halvings; i++)
        {
            yield return HalveDeadlocks;
        }

        for (var i = 0; i < Halvings; i++)
        {
            yield return HalveEpisodes;
        }
    }

    private static string? ThinSessions(Working work, int stride)
    {
        var samples = work.Rows(RcaContract.Sessions).GroupBy(r => r.At).OrderBy(g => g.Key).Select(g => g.ToList()).ToList();
        if (samples.Count < 3)
        {
            return null;
        }

        var keep = new HashSet<DateTimeOffset>();
        foreach (var formation in Formations(samples))
        {
            keep.Add(formation[0][0].At);
            keep.Add(formation[^1][0].At);
            keep.Add(formation.OrderByDescending(s => s.Count(r => r.Get("blocked_by") is not null)).ThenBy(s => s[0].At).First()[0].At);
            if (stride != int.MaxValue)
            {
                for (var i = 0; i < formation.Count; i += stride)
                {
                    keep.Add(formation[i][0].At);
                }
            }
        }

        var before = samples.Sum(s => s.Count);
        var kept = work.Replace(RcaContract.Sessions, r => keep.Contains(r.At));
        if (kept == before)
        {
            return null;
        }

        return stride == int.MaxValue
            ? string.Create(CultureInfo.InvariantCulture, $"blocking samples cut to each chain formation's first, peak, and last ({kept} of {before} RCA Sessions rows kept).")
            : string.Create(CultureInfo.InvariantCulture, $"blocking samples thinned to 1 in {stride} inside each chain formation, its first, peak, and last kept ({kept} of {before} RCA Sessions rows kept).");
    }

    /// <summary>Chain formations: runs of blocking samples less than 1.5 times their usual interval apart.</summary>
    private static List<List<List<CaptureRow>>> Formations(List<List<CaptureRow>> samples)
    {
        var gaps = samples.Zip(samples.Skip(1), (a, b) => (b[0].At - a[0].At).TotalSeconds).Where(g => g > 0).Order().ToList();
        var usual = gaps.Count == 0 ? 10 : gaps[gaps.Count / 2];
        var formations = new List<List<List<CaptureRow>>>();
        foreach (var sample in samples)
        {
            if (formations.Count == 0 || (sample[0].At - formations[^1][^1][0].At).TotalSeconds > usual * 1.5)
            {
                formations.Add([]);
            }

            formations[^1].Add(sample);
        }

        return formations;
    }

    private static string? DropSecondary(Working work)
    {
        var before = work.Rows(RcaContract.Resource).Count;
        var kept = work.Replace(RcaContract.Resource, r => !SecondaryMetrics.Contains(r.Get("metric") as string ?? string.Empty));
        return kept == before ? null : string.Create(CultureInfo.InvariantCulture, $"secondary counters left out ({string.Join(", ", SecondaryMetrics.Order(StringComparer.Ordinal))}): {before - kept} RCA Resource rows.");
    }

    private static string? ThinSentinel(Working work, string table, int stride)
    {
        var episodes = work.Episodes();
        var times = work.Rows(table).Where(r => r.Sentinel && (table != RcaContract.Resource || SentinelSources.Contains(r.Source))).Select(r => r.At).Distinct().Order().ToList();
        var outside = times.Where(t => !episodes.Any(e => t >= e.From && t <= e.To)).ToList();
        if (outside.Count < 2)
        {
            return null;
        }

        var drop = outside.Where((_, i) => i % stride != 0).ToHashSet();
        var before = work.Rows(table).Count;
        var kept = work.Replace(table, r => !(r.Sentinel && drop.Contains(r.At)));
        return kept == before ? null : string.Create(CultureInfo.InvariantCulture, $"the sentinel's {(table == RcaContract.Replica ? "replay" : "counter")} samples outside capture episodes thinned to 1 in {stride}, so a missing sample there was cut, not missed ({before - kept} {(table == RcaContract.Replica ? "RCA Replica" : "RCA Resource")} rows).");
    }

    private static string? ThinResourceStats(Working work, int stride)
    {
        var times = work.Rows(RcaContract.Resource).Where(r => r.Source == "RCA-AZ-01").Select(r => r.At).Distinct().Order().ToList();
        if (times.Count < 2)
        {
            return null;
        }

        var drop = times.Where((_, i) => i % stride != 0).ToHashSet();
        var before = work.Rows(RcaContract.Resource).Count;
        var kept = work.Replace(RcaContract.Resource, r => !(r.Source == "RCA-AZ-01" && drop.Contains(r.At)));
        return kept == before ? null : string.Create(CultureInfo.InvariantCulture, $"the 15-second resource rows (RCA-AZ-01) thinned to 1 in {stride}, so a missing row was cut, not missed ({before - kept} rows).");
    }

    private static string? PeakOnly(Working work)
    {
        var samples = work.Rows(RcaContract.Sessions).GroupBy(r => r.At).OrderBy(g => g.Key).Select(g => g.ToList()).ToList();
        if (samples.Count < 2)
        {
            return null;
        }

        var episodes = work.Episodes();
        var keep = new HashSet<DateTimeOffset>();
        foreach (var group in samples.GroupBy(s => episodes.FindIndex(e => s[0].At >= e.From && s[0].At <= e.To)))
        {
            keep.Add(group.OrderByDescending(s => s.Count(r => r.Get("blocked_by") is not null)).ThenBy(s => s[0].At).First()[0].At);
        }

        var before = samples.Sum(s => s.Count);
        var kept = work.Replace(RcaContract.Sessions, r => keep.Contains(r.At));
        return kept == before ? null : string.Create(CultureInfo.InvariantCulture, $"blocking samples cut to each capture episode's peak ({kept} of {before} RCA Sessions rows kept).");
    }

    private static string? DropSessions(Working work)
    {
        var before = work.Rows(RcaContract.Sessions).Count;
        if (before == 0)
        {
            return null;
        }

        work.Replace(RcaContract.Sessions, _ => false);
        return string.Create(CultureInfo.InvariantCulture, $"every blocking sample left out ({before} RCA Sessions rows).");
    }

    private static string? KeepEssentials(Working work)
    {
        var before = work.Rows(RcaContract.Resource).Count + work.Rows(RcaContract.Replica).Count + work.Rows(RcaContract.Events).Count;
        var kept = work.Replace(RcaContract.Resource, _ => false)
            + work.Replace(RcaContract.Replica, _ => false)
            + work.Replace(RcaContract.Events, r => r.Get("kind") is "capture" or "deadlock");
        return kept == before ? null : "only capture episodes and deadlocks kept: the counters, replay samples, and other events left out.";
    }

    private static string? DropDeadlockGraphs(Working work)
    {
        var graphs = work.Rows(RcaContract.Events).Count(r => r.Get("deadlock_json") is not null);
        if (graphs == 0)
        {
            return null;
        }

        work.Map(RcaContract.Events, r => r.Get("deadlock_json") is null ? r : Copy(r).Set("deadlock_json", null));
        return string.Create(CultureInfo.InvariantCulture, $"the graphs of {graphs} deadlock(s) left out; each deadlock row keeps its victim, module, and first object.");
    }

    private static string? HalveDeadlocks(Working work)
    {
        var deadlocks = work.Rows(RcaContract.Events).Where(r => r.Get("kind") is "deadlock").ToList();
        if (deadlocks.Count < 2)
        {
            return null;
        }

        var keep = deadlocks.Where((_, i) => i % 2 == 0).ToHashSet();
        work.Replace(RcaContract.Events, r => r.Get("kind") is not "deadlock" || keep.Contains(r));
        return string.Create(CultureInfo.InvariantCulture, $"deadlock rows halved ({keep.Count} of {deadlocks.Count} kept).");
    }

    private static string? HalveEpisodes(Working work)
    {
        var episodes = work.Rows(RcaContract.Events).Where(r => r.Get("kind") is "capture").Select(r => r.Get("code") as string ?? string.Empty).Distinct(StringComparer.Ordinal).ToList();
        if (episodes.Count < 2)
        {
            return null;
        }

        var keep = episodes.Where((_, i) => i % 2 == 0).ToHashSet(StringComparer.Ordinal);
        work.Replace(RcaContract.Events, r => r.Get("kind") is not "capture" || keep.Contains(r.Get("code") as string ?? string.Empty));
        return string.Create(CultureInfo.InvariantCulture, $"capture episodes halved ({keep.Count} of {episodes.Count} kept, each with its start and end).");
    }

    private static CaptureRow Copy(CaptureRow row)
    {
        var copy = new CaptureRow(row.Table, row.Target, row.At, row.Source, row.Sentinel);
        foreach (var (column, value) in row.Values)
        {
            copy.Set(column, value);
        }

        return copy;
    }

    private static Dictionary<string, List<CaptureRow>> Assemble(List<Working> work)
    {
        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal);
        foreach (var table in RcaContract.Tables.Where(t => t.IsDetection && t.Name != RcaContract.Coverage))
        {
            var rows = work.SelectMany(w => w.Rows(table.Name)).OrderBy(r => r.At).ThenBy(r => r.Target, StringComparer.Ordinal).ToList();
            if (rows.Count > 0)
            {
                tables[table.Name] = rows;
            }
        }

        tables[RcaContract.Coverage] = [.. work.Select(w => w.Coverage())];
        return tables;
    }

    private static List<string> Warnings(IReadOnlyList<TargetCapture> captures) =>
        [.. captures.SelectMany(c => c.Notes.Where(n => n.Kind == NoteKind.Warning).Select(n => n.Text)).Distinct(StringComparer.Ordinal)];

    /// <summary>One target's rows while the reducer works on them.</summary>
    private sealed class Working
    {
        private readonly Dictionary<string, List<CaptureRow>> tables = new(StringComparer.Ordinal);

        public Working(TargetCapture capture)
        {
            Capture = capture;
            foreach (var group in capture.Rows.GroupBy(r => r.Table, StringComparer.Ordinal))
            {
                tables[group.Key] = group.Key == RcaContract.Events ? Aggregate(group) : [.. group.OrderBy(r => r.At)];
            }
        }

        public TargetCapture Capture { get; }

        public List<string> Cuts { get; } = [];

        public List<CaptureRow> Rows(string table) => tables.TryGetValue(table, out var rows) ? rows : [];

        public int Replace(string table, Func<CaptureRow, bool> keep)
        {
            if (!tables.TryGetValue(table, out var rows))
            {
                return 0;
            }

            tables[table] = [.. rows.Where(keep)];
            return tables[table].Count;
        }

        public void Map(string table, Func<CaptureRow, CaptureRow> map)
        {
            if (tables.TryGetValue(table, out var rows))
            {
                tables[table] = [.. rows.Select(map)];
            }
        }

        /// <summary>The capture episodes in the window, from their escalated and relaxed rows.</summary>
        public List<(DateTimeOffset From, DateTimeOffset To)> Episodes()
        {
            var episodes = new List<(DateTimeOffset, DateTimeOffset)>();
            var capture = Rows(RcaContract.Events).Where(r => r.Get("kind") is "capture").ToList();
            foreach (var code in capture.Select(r => r.Get("code") as string).Distinct())
            {
                var start = capture.Where(r => r.Get("code") as string == code && r.Get("event_name") is "escalated").Select(r => (DateTimeOffset?)r.At).FirstOrDefault() ?? Capture.From;
                var end = capture.Where(r => r.Get("code") as string == code && r.Get("event_name") is "relaxed").Select(r => (DateTimeOffset?)r.At).FirstOrDefault() ?? Capture.To;
                episodes.Add((start, end));
            }

            return episodes;
        }

        /// <summary>The target's RCA Coverage row: captured when the sentinel ran for the whole window; its sources; its gaps, one per line.</summary>
        public CaptureRow Coverage()
        {
            var capture = Capture;
            var gaps = new List<string>();
            var captured = !capture.Unobserved;
            foreach (var hole in Unobserved())
            {
                captured = false;
                gaps.Add(string.Create(CultureInfo.InvariantCulture, $"Not observed from {hole.From:HH:mm:ss} to {hole.To:HH:mm:ss} UTC."));
            }

            if (!capture.Unobserved)
            {
                foreach (var hole in SentinelHoles())
                {
                    captured = false;
                    gaps.Add(string.Create(CultureInfo.InvariantCulture, $"The sentinel didn't sample from {hole.From:HH:mm:ss} to {hole.To:HH:mm:ss} UTC."));
                }
            }

            foreach (var note in capture.Notes.Where(n => n.Kind is NoteKind.Gap or NoteKind.Warning).OrderBy(n => n.At))
            {
                gaps.Add(string.Create(CultureInfo.InvariantCulture, $"{note.At:HH:mm:ss} UTC: {note.Text}"));
            }

            if (capture.LateRows > 0)
            {
                gaps.Add(string.Create(CultureInfo.InvariantCulture, $"{capture.LateRows} row(s) arrived after their window was exported, so they were left out."));
            }

            gaps.AddRange(Cuts);
            var sources = capture.Rows.SelectMany(r => r.Source.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                .Concat(capture.Notes.Where(n => n.Kind == NoteKind.Source).Select(n => n.Text))
                .Where(s => s.StartsWith("RCA-", StringComparison.Ordinal))
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToList();
            return new CaptureRow(RcaContract.Coverage, capture.Target, capture.From, "coverage")
                .Set("target", capture.Target)
                .Set("window_start_utc", capture.From)
                .Set("window_end_utc", capture.To)
                .Set("captured", captured)
                .Set("sources", sources.Count == 0 ? null : string.Join(',', sources))
                .Set("gaps", gaps.Count == 0 ? null : Join(gaps));
        }

        private static string Join(List<string> lines)
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

        /// <summary>The parts of the window outside the target's observed intervals, beyond a minute's slack at either end.</summary>
        private IEnumerable<(DateTimeOffset From, DateTimeOffset To)> Unobserved()
        {
            var slack = TimeSpan.FromSeconds(60);
            var cursor = Capture.From;
            foreach (var (from, to) in Capture.Observed.Where(o => o.To > Capture.From && o.From < Capture.To).OrderBy(o => o.From))
            {
                if (from - cursor > slack)
                {
                    yield return (cursor, from);
                }

                if (to > cursor)
                {
                    cursor = to;
                }
            }

            if (Capture.To - cursor > slack)
            {
                yield return (cursor, Capture.To);
            }
        }

        /// <summary>Within each observed interval, a stretch longer than <see cref="SentinelHole"/> without a sentinel sample.</summary>
        private IEnumerable<(DateTimeOffset From, DateTimeOffset To)> SentinelHoles()
        {
            var samples = Capture.Rows.Where(r => r.Sentinel).Select(r => r.At).Distinct().Order().ToList();
            var observed = Capture.Observed.Count == 0 ? [(Capture.From, Capture.To)] : Capture.Observed;
            foreach (var (from, to) in observed.Select(o => (From: Max(Capture.From, o.From), To: Min(Capture.To, o.To))).Where(o => o.To > o.From).OrderBy(o => o.From))
            {
                var points = new List<DateTimeOffset> { from };
                points.AddRange(samples.Where(s => s >= from && s <= to));
                points.Add(to);
                for (var i = 1; i < points.Count; i++)
                {
                    if (points[i] - points[i - 1] > SentinelHole)
                    {
                        yield return (points[i - 1], points[i]);
                    }
                }
            }
        }

        private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

        private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;
    }
}
