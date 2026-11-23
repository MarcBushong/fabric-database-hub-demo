using System.Globalization;
using System.Text;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Runs one capture block for the Query Store reader through its observer, which handles a refusal, a timeout, or a lost
/// connection as for every block: null when the block failed, after the observer noted why in RCA Coverage (and, for a
/// permission, the RCA.CAPTURE.&lt;target&gt; Warning with its fix). A <paramref name="heavy"/> read takes the long
/// statement timeout.
/// </summary>
internal delegate Task<IReadOnlyList<CaptureValues>?> QueryStoreRun(string blockId, DateTimeOffset now, CaptureParameters parameters, bool heavy, CancellationToken cancellationToken);

/// <summary>The Query Store reader's timings and bounds (rca/README.md, Query Store). Tests shorten the look-back.</summary>
internal sealed record SqlQueryStoreOptions
{
    /// <summary>2 minutes after each interval ends, and the 2 hours before the observer's start.</summary>
    public QueryStoreSchedule Schedule { get; init; } = QueryStoreSchedule.Default;

    /// <summary>RCA-SQL-15, Query Store's state and forced plans.</summary>
    public TimeSpan StateEvery { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>RCA-AZ-03 and 04, T3's automatic tuning.</summary>
    public TimeSpan TuningEvery { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>How soon a read that failed is tried again, at the latest by the next scheduled read.</summary>
    public TimeSpan Retry { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>RCA-SQL-10's TOP: a read that returns this many rows may have been cut, so the next page reads on.</summary>
    public int RowCap { get; init; } = 600;

    /// <summary>Pages of RCA-SQL-10 one read takes before it leaves the rest to the next read.</summary>
    public int MaximumPages { get; init; } = 4;

    /// <summary>Plans whose showplan one read fetches: forced plans first, then by their CPU in the read.</summary>
    public int PlansWithXml { get; init; } = 40;

    /// <summary>IDs carried to the next read when RCA-SQL-14 failed.</summary>
    public int MaximumCarried { get; init; } = 2000;
}

/// <summary>
/// Query Store's evidence on T1, T2, and T3 (rca/README.md, The sidecar and Query Store), read by the target's observer
/// on its one connection and written to the sidecar's sink, never to the evidence document's store:
/// <list type="bullet">
/// <item>RCA-SQL-15 every 60 s: Query Store's state, and a plan forced or unforced (RCA Query Events);</item>
/// <item>on T3, RCA-AZ-03 and 04 every 30 s: automatic tuning's options and recommendations (RCA Query Events);</item>
/// <item>RCA-SQL-10, 11, and 14 at the observer's first tick for the 2 hours before its start, then 2 minutes after each
/// interval ends for the intervals that ended since, and at its end with the interval still open: each interval's top
/// queries (RCA Query Stats), their plans' three largest wait categories (RCA Query Waits), and their plans (RCA Query
/// Plans), each plan's showplan reduced once per observation;</item>
/// <item>after each of those reads and at the end, one RCA Query Coverage row for the time since the previous one: the
/// state and capture mode as last read, the intervals read, the blocks that returned rows, and the gaps. The sidecar's
/// export makes one row a target of a sidecar's rows: the earliest start and latest end, the latest state, capture mode,
/// and interval, the first interval read and the last, every source, and every gap in time order.</item>
/// </list>
/// The capture leaves out its own statements and the harness's by the blocks' two fixed rules (rca/README.md, What the
/// capture leaves out), and nothing else; the reader takes no list from anywhere to leave something out.
/// </summary>
internal sealed class SqlQueryStoreReader(string target, bool automaticTuning, ISidecarSink sink, QueryStoreRun run, SqlQueryStoreOptions? options = null)
{
    private static readonly string[] SourceOrder =
    [
        SqlQueryStoreRows.StatsBlock, SqlQueryStoreRows.WaitsBlock, SqlQueryStoreRows.PlansBlock, SqlQueryStoreRows.StateBlock,
        SqlAutomaticTuning.OptionsBlock, SqlAutomaticTuning.RecommendationsBlock,
    ];

    private readonly SqlQueryStoreOptions settings = options ?? new SqlQueryStoreOptions();
    private readonly SqlAutomaticTuning tuning = new(target);
    private readonly Dictionary<long, SentPlan> sent = [];
    private readonly Dictionary<long, PlanShape?> reduced = [];
    private readonly HashSet<long> carriedQueries = [];
    private readonly HashSet<long> carriedPlans = [];
    private readonly HashSet<string> sources = new(StringComparer.Ordinal);
    private readonly List<string> gaps = [];
    private readonly Dictionary<string, DateTimeOffset> noted = new(StringComparer.Ordinal);
    private QueryStoreSchedule schedule = QueryStoreSchedule.Default;
    private SqlQueryStoreState? state;
    private DateTimeOffset since;
    private DateTimeOffset nextState;
    private DateTimeOffset nextTuning;
    private DateTimeOffset nextRead;
    private DateTimeOffset coverageFrom;
    private DateTimeOffset? readFrom;
    private DateTimeOffset? readTo;

    /// <summary>When the reader next has work.</summary>
    public DateTimeOffset NextDue => new[] { nextState, automaticTuning ? nextTuning : DateTimeOffset.MaxValue, nextRead }.Min();

    /// <summary>The end of the last interval read: the next read asks for the intervals that ended after it.</summary>
    public DateTimeOffset Since => since;

    /// <summary>A new observation: nothing read yet, and every read due at the first tick.</summary>
    public void Begin(DateTimeOffset now)
    {
        schedule = settings.Schedule;
        state = null;
        tuning.Reset();
        sent.Clear();
        reduced.Clear();
        carriedQueries.Clear();
        carriedPlans.Clear();
        sources.Clear();
        gaps.Clear();
        noted.Clear();
        since = schedule.FirstSince(now);
        nextState = now;
        nextTuning = now;
        nextRead = now;
        coverageFrom = now;
        readFrom = null;
        readTo = null;
    }

    /// <summary>Runs the reads that are due; returns when the next is.</summary>
    public async Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (now >= nextState)
        {
            await ReadStateAsync(now, cancellationToken).ConfigureAwait(false);
            nextState = now + settings.StateEvery;
        }

        if (automaticTuning && now >= nextTuning)
        {
            await ReadTuningAsync(now, cancellationToken).ConfigureAwait(false);
            nextTuning = now + settings.TuningEvery;
        }

        if (now >= nextRead)
        {
            var complete = await ReadIntervalsAsync(now, final: false, cancellationToken).ConfigureAwait(false);
            var scheduled = schedule.NextRead(now);
            nextRead = complete || now + settings.Retry >= scheduled ? scheduled : now + settings.Retry;
        }

        return NextDue;
    }

    /// <summary>The observer's end: the state, T3's tuning, and the intervals since the last read with the one still open.</summary>
    public async Task EndAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        await ReadStateAsync(now, cancellationToken).ConfigureAwait(false);
        if (automaticTuning)
        {
            await ReadTuningAsync(now, cancellationToken).ConfigureAwait(false);
        }

        await ReadIntervalsAsync(now, final: true, cancellationToken).ConfigureAwait(false);
    }

    private async Task ReadStateAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var rows = await run(SqlQueryStoreRows.StateBlock, now, CaptureParameters.None, false, cancellationToken).ConfigureAwait(false);
        if (rows is null)
        {
            GapOnce(now, "state", $"Query Store's state (RCA-SQL-15) wasn't read on {target}: the read failed, and RCA Coverage says why.");
            return;
        }

        if (SqlQueryStoreState.From(rows, now) is not { } current)
        {
            GapOnce(now, "state-empty", $"Query Store's state (RCA-SQL-15) returned no row on {target}.");
            return;
        }

        sources.Add(SqlQueryStoreRows.StateBlock);
        var previous = state;
        if (previous is not null)
        {
            foreach (var change in current.Changes(previous, target))
            {
                sink.Write(change);
            }
        }

        if (!current.IsReadWrite && (previous is null || !string.Equals(previous.ActualState, current.ActualState, StringComparison.OrdinalIgnoreCase) || previous.ReadOnlyReason != current.ReadOnlyReason))
        {
            Gap(now, current.Describe(target));
        }

        if (string.Equals(current.CaptureMode, "NONE", StringComparison.OrdinalIgnoreCase) && !string.Equals(previous?.CaptureMode, current.CaptureMode, StringComparison.OrdinalIgnoreCase))
        {
            Gap(now, string.Create(CultureInfo.InvariantCulture, $"Query Store's capture mode on {target} was NONE at {current.At:HH:mm:ss} UTC, so it captured no new queries."));
        }

        if (current.IntervalMinutes is { } minutes)
        {
            schedule = schedule.WithInterval(TimeSpan.FromMinutes(minutes));
        }

        state = current;
    }

    private async Task ReadTuningAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var options = await run(SqlAutomaticTuning.OptionsBlock, now, CaptureParameters.None, false, cancellationToken).ConfigureAwait(false);
        if (options is null)
        {
            GapOnce(now, "tuning-options", $"Automatic tuning's options (RCA-AZ-03) weren't read on {target}: the read failed, and RCA Coverage says why.");
        }
        else
        {
            Returned(SqlAutomaticTuning.OptionsBlock, options);
            tuning.Options(options, now).ForEach(sink.Write);
        }

        var recommendations = await run(SqlAutomaticTuning.RecommendationsBlock, now, CaptureParameters.None, false, cancellationToken).ConfigureAwait(false);
        if (recommendations is null)
        {
            GapOnce(now, "tuning-recommendations", $"Automatic tuning's recommendations (RCA-AZ-04) weren't read on {target}: the read failed, and RCA Coverage says why.");
        }
        else
        {
            Returned(SqlAutomaticTuning.RecommendationsBlock, recommendations);
            tuning.Recommendations(recommendations, now).ForEach(sink.Write);
        }
    }

    /// <summary>RCA-SQL-10 (in pages, when a read hits its cap) and RCA-SQL-11, then RCA-SQL-14, then a coverage row. False when a read failed.</summary>
    private async Task<bool> ReadIntervalsAsync(DateTimeOffset now, bool final, CancellationToken cancellationToken)
    {
        var queries = new HashSet<long>(carriedQueries);
        var plans = new HashSet<long>(carriedPlans);
        var cpu = new Dictionary<long, double>();
        var complete = true;
        for (var page = 1; ; page++)
        {
            var from = since;
            var rows = await run(SqlQueryStoreRows.StatsBlock, now, CaptureParameters.Named(("@since", from), ("@final", final)), true, cancellationToken).ConfigureAwait(false);
            if (rows is null)
            {
                Gap(now, string.Create(CultureInfo.InvariantCulture, $"Query Store's statistics (RCA-SQL-10) weren't read on {target}: the read failed, and RCA Coverage says why. {(final ? "The next observation's first read takes those of its intervals that ended in its look-back" : "The next read takes the intervals that ended after " + from.ToString("HH:mm", CultureInfo.InvariantCulture) + " UTC")}."));
                complete = false;
                break;
            }

            Returned(SqlQueryStoreRows.StatsBlock, rows);
            var kept = rows.Select(r => SqlQueryStoreRows.Stats(target, r, now)).OfType<CaptureRow>().ToList();
            var intervals = kept.Select(SqlQueryStoreRows.Interval).Distinct().OrderBy(i => i.Start).ToList();
            var capped = rows.Count >= settings.RowCap;
            if (capped && intervals.Count > 1)
            {
                // The block returns the oldest intervals first: its last one may have been cut, so the next page reads it whole.
                var cut = intervals[^1];
                kept.RemoveAll(r => SqlQueryStoreRows.Interval(r) == cut);
                intervals.RemoveAt(intervals.Count - 1);
            }
            else if (capped && intervals.Count == 1)
            {
                Gap(now, string.Create(CultureInfo.InvariantCulture, $"Query Store's interval from {intervals[0].Start:HH:mm} to {intervals[0].End:HH:mm} UTC on {target} had more than {settings.RowCap} rows in its top lists; the observer kept the {settings.RowCap} that used the most CPU."));
            }

            if (kept.Count == 0)
            {
                break;
            }

            foreach (var row in kept)
            {
                sink.Write(row);
                var plan = (long)row.Get("plan_id")!;
                queries.Add((long)row.Get("query_id")!);
                plans.Add(plan);
                cpu[plan] = cpu.GetValueOrDefault(plan) + (row.Get("cpu_ms") as double? ?? 0);
            }

            readFrom = readFrom is { } first && first <= intervals[0].Start ? first : intervals[0].Start;
            var newest = intervals.Max(i => i.End);
            readTo = readTo is { } last && last >= newest ? last : newest;
            await ReadWaitsAsync(now, from, final, kept, cancellationToken).ConfigureAwait(false);
            since = newest > since ? newest : since;
            if (!capped)
            {
                break;
            }

            if (page >= settings.MaximumPages)
            {
                Gap(now, string.Create(CultureInfo.InvariantCulture, $"Query Store on {target} had more top-list rows than {settings.MaximumPages} pages of {settings.RowCap} take; {(final ? "the next observation's first read takes those that ended in its look-back" : "the next read takes the intervals that ended after " + since.ToString("HH:mm", CultureInfo.InvariantCulture) + " UTC")}."));
                break;
            }
        }

        await ReadPlansAsync(now, queries, plans, cpu, cancellationToken).ConfigureAwait(false);
        WriteCoverage(now);
        return complete;
    }

    /// <summary>RCA-SQL-11 for the plans one page returned: only the waits of the intervals and plans the page kept.</summary>
    private async Task ReadWaitsAsync(DateTimeOffset now, DateTimeOffset from, bool final, List<CaptureRow> kept, CancellationToken cancellationToken)
    {
        var pairs = kept.Select(r => (SqlQueryStoreRows.Interval(r).Start, (long)r.Get("plan_id")!)).ToHashSet();
        var parameters = CaptureParameters.Named(("@since", from), ("@final", final), ("@plans", SqlQueryStoreRows.Ids(pairs.Select(p => p.Item2))));
        var rows = await run(SqlQueryStoreRows.WaitsBlock, now, parameters, true, cancellationToken).ConfigureAwait(false);
        if (rows is null)
        {
            Gap(now, $"Query Store's waits (RCA-SQL-11) weren't read on {target}: the read failed, and RCA Coverage says why; the statistics' wait_ms holds each plan's total.");
            return;
        }

        Returned(SqlQueryStoreRows.WaitsBlock, rows);
        foreach (var row in rows)
        {
            if (SqlQueryStoreRows.Wait(target, row, now) is { } wait && pairs.Contains((SqlQueryStoreRows.Interval(wait).Start, (long)wait.Get("plan_id")!)))
            {
                sink.Write(wait);
            }
        }
    }

    /// <summary>
    /// RCA-SQL-14 for the read's queries and plans: a plan's row when it wasn't written in this observation, or when its
    /// forcing, its forcing failures, or its last compile changed, or its summary is new. A plan's showplan is fetched
    /// once per observation, at most <see cref="SqlQueryStoreOptions.PlansWithXml"/> a read.
    /// </summary>
    private async Task ReadPlansAsync(DateTimeOffset now, HashSet<long> queries, HashSet<long> plans, Dictionary<long, double> cpu, CancellationToken cancellationToken)
    {
        var forced = state?.Forced.Keys.Select(k => k.Plan).ToHashSet() ?? [];
        var unsentForcing = forced.Any(p => !sent.TryGetValue(p, out var s) || s.Forced != true);
        if (queries.Count == 0 && plans.Count == 0 && !unsentForcing)
        {
            return;
        }

        var withPlan = plans.Union(forced)
            .Where(p => !reduced.ContainsKey(p))
            .OrderByDescending(forced.Contains)
            .ThenByDescending(p => cpu.GetValueOrDefault(p))
            .ThenBy(p => p)
            .Take(settings.PlansWithXml)
            .ToList();
        var parameters = CaptureParameters.Named(("@queries", SqlQueryStoreRows.Ids(queries)), ("@plans", SqlQueryStoreRows.Ids(plans)), ("@with_plan", SqlQueryStoreRows.Ids(withPlan)));
        var rows = await run(SqlQueryStoreRows.PlansBlock, now, parameters, true, cancellationToken).ConfigureAwait(false);
        if (rows is null)
        {
            Carry(carriedQueries, queries);
            Carry(carriedPlans, plans);
            Gap(now, $"Query Store's plans (RCA-SQL-14) weren't read on {target}: the read failed, and RCA Coverage says why; the next read asks for them again.");
            return;
        }

        Returned(SqlQueryStoreRows.PlansBlock, rows);
        carriedQueries.Clear();
        carriedPlans.Clear();
        foreach (var plan in withPlan)
        {
            reduced.TryAdd(plan, null);
        }

        foreach (var row in rows)
        {
            if (row.Long("plan_id") is not { } plan)
            {
                continue;
            }

            if (row.Text("query_plan") is { Length: > 0 } xml)
            {
                reduced[plan] = PlanSummary.Reduce(xml, out var problem);
                if (problem is not null)
                {
                    Gap(now, string.Create(CultureInfo.InvariantCulture, $"Plan {plan} on {target} has no summary: {problem}."));
                }
            }

            var shape = reduced.GetValueOrDefault(plan);
            var key = new SentPlan(row.Bool("is_forced_plan"), row.Text("forcing_type"), row.Long("force_failures"), row.Time("last_compiled_utc"), shape is not null);
            if (sent.TryGetValue(plan, out var before) && before == key)
            {
                continue;
            }

            if (SqlQueryStoreRows.Plan(target, row, now, shape) is { } mapped)
            {
                sink.Write(mapped);
                sent[plan] = key;
            }
        }
    }

    /// <summary>One RCA Query Coverage row for the time since the previous one; the next row starts where it ends.</summary>
    private void WriteCoverage(DateTimeOffset now)
    {
        sink.Write(new CaptureRow(RcaContract.QueryCoverage, target, now, SqlQueryStoreRows.StateBlock)
            .Set("target", target)
            .Set("window_start_utc", coverageFrom)
            .Set("window_end_utc", now)
            .Set("state", state?.ActualState)
            .Set("capture_mode", state?.CaptureMode)
            .Set("interval_minutes", state?.IntervalMinutes)
            .Set("read_from_utc", readFrom)
            .Set("read_to_utc", readTo)
            .Set("backfill", false)
            .Set("sources", sources.Count == 0 ? null : string.Join(',', SourceOrder.Where(sources.Contains)))
            .Set("gaps", gaps.Count == 0 ? null : Lines(gaps)));
        coverageFrom = now;
        readFrom = null;
        readTo = null;
        sources.Clear();
        gaps.Clear();
    }

    private void Returned(string block, IReadOnlyList<CaptureValues> rows)
    {
        if (rows.Count > 0)
        {
            sources.Add(block);
        }
    }

    private void Gap(DateTimeOffset at, string text) =>
        gaps.Add(string.Create(CultureInfo.InvariantCulture, $"{at:HH:mm:ss} UTC: {TextNormalizer.Detail(text) ?? "A gap the observer couldn't describe."}"));

    /// <summary>A gap at most once every 10 minutes for the same key, so a failure that lasts doesn't fill the coverage.</summary>
    private void GapOnce(DateTimeOffset at, string key, string text)
    {
        if (noted.TryGetValue(key, out var last) && at - last < TimeSpan.FromMinutes(10))
        {
            return;
        }

        noted[key] = at;
        Gap(at, text);
    }

    private void Carry(HashSet<long> carried, HashSet<long> ids)
    {
        foreach (var id in ids.Take(Math.Max(0, settings.MaximumCarried - carried.Count)))
        {
            carried.Add(id);
        }
    }

    /// <summary>Gaps one per line, as RCA Coverage's are, within a string's 4,000 characters.</summary>
    private static string Lines(List<string> lines)
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

    /// <summary>What a plan's last written row said: a change to any of it writes the plan again.</summary>
    private sealed record SentPlan(bool? Forced, string? ForcingType, long? Failures, DateTimeOffset? LastCompiled, bool Summarized);
}
