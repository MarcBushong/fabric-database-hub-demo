using System.Globalization;
using System.Text;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>The Query Store reader's timings and bounds (rca/README.md, Query Store). Tests shorten or measure them.</summary>
internal sealed record SqlQueryStoreOptions
{
    /// <summary>2 minutes after each interval ends, and the 2 hours before the observer's start.</summary>
    public QueryStoreSchedule Schedule { get; init; } = QueryStoreSchedule.Default;

    /// <summary>RCA-SQL-15, Query Store's state and forced plans: every 60 s, times the self-throttling's factor.</summary>
    public TimeSpan StateEvery { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>RCA-AZ-03 and 04, T3's automatic tuning: every 30 s, times the self-throttling's factor.</summary>
    public TimeSpan TuningEvery { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>How soon an interval read that failed, or waited for a slowed observer, is tried again: at the latest, the next scheduled read.</summary>
    public TimeSpan Retry { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>The timeout of RCA-SQL-15 and of RCA-AZ-03 and 04, which read a few rows.</summary>
    public TimeSpan LightTimeout { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>The timeout of one block of an interval read: RCA-SQL-10, 11, or 14.</summary>
    public TimeSpan ReadTimeout { get; init; } = TimeSpan.FromSeconds(15);

    /// <summary>A block runs in a tick only when its timeout would end at least this long before the evidence capture's next work.</summary>
    public TimeSpan Margin { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>The observer's end: its Query Store reads together, each block's timeout cut to what's left of this.</summary>
    public TimeSpan EndBudget { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>RCA-SQL-10's TOP: a read that returns this many rows may have been cut, so the next page reads on.</summary>
    public int RowCap { get; init; } = 600;

    /// <summary>Pages of RCA-SQL-10 one read takes before it leaves the rest to the next read.</summary>
    public int MaximumPages { get; init; } = 4;

    /// <summary>Plans whose showplan one read fetches: forced plans first, then by their CPU in the read.</summary>
    public int PlansWithXml { get; init; } = 40;

    /// <summary>IDs carried to the next read when RCA-SQL-14 failed or didn't run.</summary>
    public int MaximumCarried { get; init; } = 2000;

    /// <summary>Measures how long a tick's work and the end's reads have taken: durations only, never the time of day.</summary>
    public TimeProvider Clock { get; init; } = TimeProvider.System;
}

/// <summary>
/// Query Store's evidence on T1, T2, and T3 (rca/README.md, The sidecar and Query Store), read on the target's observer
/// connection and written to the sidecar's sink, never to the evidence document's store:
/// <list type="bullet">
/// <item>RCA-SQL-15 every 60 s: Query Store's state, and a plan forced or unforced (RCA Query Events);</item>
/// <item>on T3, RCA-AZ-03 and 04 every 30 s: automatic tuning's options and recommendations (RCA Query Events);</item>
/// <item>an interval read of RCA-SQL-10, 11, and 14, at the observer's first tick for the 2 hours before its start, then
/// 2 minutes after each interval ends for the intervals that ended since, and at its end with the interval still open:
/// each interval's top queries (RCA Query Stats), their plans' three largest wait categories (RCA Query Waits), and their
/// plans (RCA Query Plans), each plan's showplan reduced once per observation;</item>
/// <item>after each interval read, one RCA Query Coverage row for the time since the previous one: the state and capture
/// mode as last read, the intervals read, the blocks that returned rows, and the gaps. The sidecar's export makes one row
/// a target of a sidecar's rows: the earliest start and latest end, the latest state, capture mode, and interval, the
/// first interval read and the last, every source, and every gap in time order.</item>
/// </list>
/// The reads leave the evidence document as it would be without them (<see cref="ISidecarAccess"/>): a failure is a
/// sidecar gap (a refusal's names the permission its block needs, and the fix: RCA-AZ-04's its own), and the rest of the
/// reads go on; they run last in a tick, a block only when its own timeout ends before the evidence capture's next work,
/// and at most one block of an interval read a tick; the state's and tuning's cadence is multiplied by the
/// self-throttling's factor, and while the observer is slowed or has stopped its detail capture, no interval read starts
/// or goes on (Query Store keeps the intervals, and the next read takes them); the end's reads come after the evidence's
/// own end (which the observer reports to the lane first) and together take at most <see cref="SqlQueryStoreOptions.EndBudget"/>.
/// The capture leaves out its own statements and the harness's by the blocks' two fixed rules (rca/README.md, What the
/// capture leaves out), and nothing else; the reader takes no list from anywhere to leave something out.
/// </summary>
internal sealed class SqlQueryStoreReader(ISidecarAccess access, bool automaticTuning, ISidecarSink sink, SqlQueryStoreOptions? options = null)
{
    private static readonly string[] SourceOrder =
    [
        SqlQueryStoreRows.StatsBlock, SqlQueryStoreRows.WaitsBlock, SqlQueryStoreRows.PlansBlock, SqlQueryStoreRows.StateBlock,
        SqlAutomaticTuning.OptionsBlock, SqlAutomaticTuning.RecommendationsBlock,
    ];

    /// <summary>
    /// RCA-AZ-04's fix. Azure SQL Database grants no permission at the server level: its fixed server roles hold them, and
    /// their members are logins in master, never contained database users; ##MS_ServerStateReader## holds VIEW SERVER
    /// PERFORMANCE STATE, and a login's role reaches a database through the login's user there
    /// (https://learn.microsoft.com/azure/azure-sql/database/security-server-roles). A managed identity's login is a
    /// Microsoft Entra server principal (https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-logins).
    /// T1's identity has the permission through T3's administrator group, the server's Microsoft Entra administrator, which
    /// ./scripts/deploy.ps1 adds it to (database/azuresql/README.md, Users; Add-DemoT1ToT3AdminGroup).
    /// </summary>
    private const string ServerPermissionFix =
        "The fix: a contained database user can't hold a server permission. T1's managed identity needs a login in master, in the ##MS_ServerStateReader## server role (which holds VIEW SERVER PERFORMANCE STATE on Azure SQL Database), and its user in ContosoCare made from that login; or ./scripts/deploy.ps1, which adds T1's managed identity to T3's administrator group again, the server's Microsoft Entra administrator.";

    private readonly string target = access.Target;
    private readonly SqlQueryStoreOptions settings = options ?? new SqlQueryStoreOptions();
    private readonly SqlAutomaticTuning tuning = new(access.Target);
    private readonly Dictionary<long, SentPlan> sent = [];
    private readonly Dictionary<long, PlanShape?> reduced = [];
    private readonly HashSet<long> carriedQueries = [];
    private readonly HashSet<long> carriedPlans = [];
    private readonly HashSet<string> sources = new(StringComparer.Ordinal);
    private readonly List<string> gaps = [];
    private readonly Dictionary<string, DateTimeOffset> noted = new(StringComparer.Ordinal);
    private QueryStoreSchedule schedule = QueryStoreSchedule.Default;
    private SqlQueryStoreState? state;
    private IntervalRead? read;
    private DateTimeOffset since;
    private DateTimeOffset nextState;
    private DateTimeOffset nextTuning;
    private bool recommendationsDue;
    private DateTimeOffset nextRead;
    private DateTimeOffset readResume;
    private DateTimeOffset coverageFrom;
    private DateTimeOffset? readFrom;
    private DateTimeOffset? readTo;

    private enum Phase
    {
        Stats,
        Waits,
        Plans,
        Done,
    }

    /// <summary>The end of the last interval read: the next read asks for the intervals that ended after it.</summary>
    public DateTimeOffset Since => since;

    /// <summary>A timestamp of the reader's clock, which the observer takes at its tick's start, so the tick's evidence work counts against the reads' room.</summary>
    public long Timestamp() => settings.Clock.GetTimestamp();

    /// <summary>A new observation: nothing read yet, and every read due at the first tick.</summary>
    public void Begin(DateTimeOffset now)
    {
        schedule = settings.Schedule;
        state = null;
        read = null;
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
        recommendationsDue = false;
        nextRead = now;
        readResume = now;
        coverageFrom = now;
        readFrom = null;
        readTo = null;
    }

    /// <summary>
    /// The reads that are due and fit before <paramref name="evidenceDue"/>, the evidence capture's next work, counting
    /// from <paramref name="tickStarted"/> (<see cref="Timestamp"/>): the state, T3's tuning (each of its two blocks when
    /// its own timeout fits, so a blocking episode's 10-s detail doesn't stop them), and one block of the interval read.
    /// While the observer is slowed or has stopped its detail capture, no interval read starts or goes on: one under way
    /// keeps its place and its since, and is looked at again after <see cref="SqlQueryStoreOptions.Retry"/>. Each read's
    /// next time is set before it runs, so one that fails or throws waits its turn. Returns when the reader next has work
    /// it could do.
    /// </summary>
    public async Task<DateTimeOffset> TickAsync(DateTimeOffset now, long tickStarted, DateTimeOffset evidenceDue, CancellationToken cancellationToken)
    {
        var room = evidenceDue - now;
        var light = settings.LightTimeout;
        bool Fits(TimeSpan timeout) => room - settings.Clock.GetElapsedTime(tickStarted) >= timeout + settings.Margin;

        if (now >= nextState && Fits(light))
        {
            nextState = now + Scaled(settings.StateEvery);
            await ReadStateAsync(now, () => light, cancellationToken).ConfigureAwait(false);
        }

        if (automaticTuning && now >= nextTuning && Fits(light))
        {
            nextTuning = now + Scaled(settings.TuningEvery);
            recommendationsDue = true;
            await ReadOptionsAsync(now, () => light, cancellationToken).ConfigureAwait(false);
        }

        if (recommendationsDue && Fits(light))
        {
            recommendationsDue = false;
            await ReadRecommendationsAsync(now, () => light, cancellationToken).ConfigureAwait(false);
        }

        var throttled = access.Factor > 1 || access.DetailStopped;
        if (read is null && now >= nextRead)
        {
            if (throttled)
            {
                Held(now);
                nextRead = now + settings.Retry;
            }
            else if (Fits(settings.ReadTimeout))
            {
                read = new IntervalRead(final: false, carriedQueries, carriedPlans);
                readResume = now;
            }
        }
        else if (read is not null && throttled && now >= readResume)
        {
            Held(now);
            readResume = now + settings.Retry;
        }

        if (read is { } current && !throttled && now >= readResume && Fits(settings.ReadTimeout))
        {
            try
            {
                await AdvanceAsync(current, now, () => settings.ReadTimeout, oneBlock: true, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                // It starts again later from the same since; the IDs it had read wait for the next read's plans.
                Abandon(current);
                nextRead = now + settings.Retry;
                throw;
            }
        }

        // A read that's due but doesn't fit runs once the evidence capture's next work is done.
        DateTimeOffset When(DateTimeOffset due, TimeSpan timeout) => due > now ? due : Fits(timeout) ? now : evidenceDue;
        var wake = When(nextState, light);
        if (automaticTuning)
        {
            wake = Earliest(wake, When(recommendationsDue ? now : nextTuning, light));
        }

        return Earliest(wake, When(read is null ? nextRead : readResume, settings.ReadTimeout));
    }

    /// <summary>
    /// The observer's end, after the evidence capture's own: the state, T3's tuning, and the intervals since the last read
    /// with the one still open, within <see cref="SqlQueryStoreOptions.EndBudget"/>. A read the end cut short, by its
    /// budget or the observer's cancellation, is a gap that says which intervals weren't read.
    /// </summary>
    public async Task EndAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var started = settings.Clock.GetTimestamp();
        TimeSpan? Left(TimeSpan own)
        {
            var left = settings.EndBudget - settings.Clock.GetElapsedTime(started);
            return left < TimeSpan.FromSeconds(1) ? null : left < own ? left : own;
        }

        if (read is { } open)
        {
            Abandon(open);
        }

        var final = read = new IntervalRead(final: true, carriedQueries, carriedPlans);
        try
        {
            await ReadStateAsync(now, () => Left(settings.LightTimeout), cancellationToken).ConfigureAwait(false);
            if (automaticTuning)
            {
                recommendationsDue = false;
                await ReadOptionsAsync(now, () => Left(settings.LightTimeout), cancellationToken).ConfigureAwait(false);
                await ReadRecommendationsAsync(now, () => Left(settings.LightTimeout), cancellationToken).ConfigureAwait(false);
            }

            await AdvanceAsync(final, now, () => Left(settings.ReadTimeout), oneBlock: false, cancellationToken).ConfigureAwait(false);
            if (final.Phase != Phase.Done)
            {
                Gap(now, string.Create(CultureInfo.InvariantCulture, $"The end's Query Store reads on {target} stopped at their bound of {settings.EndBudget.TotalSeconds:0} s, before {Unread(final)}."));
                Finish(final, now);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Gap(now, $"The end's Query Store reads on {target} were cut short with the observer's end, before {Unread(final)}.");
            if (final.Phase != Phase.Done)
            {
                Finish(final, now);
            }
        }
    }

    private static DateTimeOffset Earliest(DateTimeOffset first, DateTimeOffset second) => first <= second ? first : second;

    /// <summary>What an interval read cut short didn't reach.</summary>
    private string Unread(IntervalRead current) => current.Phase switch
    {
        Phase.Waits => "the waits of the last intervals they read",
        Phase.Plans => "the plans of the queries they read",
        _ => string.Create(CultureInfo.InvariantCulture, $"the intervals that ended after {since:HH:mm} UTC"),
    };

    /// <summary>The gap that says no interval read starts or goes on while the observer is slowed or has stopped its detail capture: Query Store keeps the intervals.</summary>
    private void Held(DateTimeOffset now)
    {
        var why = access.DetailStopped
            ? "the observer stopped its detail capture for the rest of the session, so the end's read takes them"
            : string.Create(CultureInfo.InvariantCulture, $"the observer's samples are slow (its cadence is {access.Factor} times longer), so a read takes them once they're quick again, or the end's read");
        GapOnce(now, "held", string.Create(CultureInfo.InvariantCulture, $"Query Store's interval reads on {target} wait from {now:HH:mm:ss} UTC: {why}. Query Store keeps the intervals that ended after {since:HH:mm} UTC."));
    }

    private TimeSpan Scaled(TimeSpan every) => every * Math.Max(1, access.Factor);

    private async Task ReadStateAsync(DateTimeOffset now, Func<TimeSpan?> timeout, CancellationToken cancellationToken)
    {
        if (timeout() is not { } limit)
        {
            Gap(now, $"Query Store's state (RCA-SQL-15) wasn't read on {target} at the end: the end's reads had no time left.");
            return;
        }

        var result = await access.RunAsync(SqlQueryStoreRows.StateBlock, now, CaptureParameters.None, limit, cancellationToken).ConfigureAwait(false);
        if (result.Rows is not { } rows)
        {
            GapOnce(now, "state", $"Query Store's state (RCA-SQL-15) wasn't read on {target}: {Why(SqlQueryStoreRows.StateBlock, result)}");
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

    /// <summary>RCA-AZ-03: automatic tuning's options, and an option whose state changed (RCA Query Events).</summary>
    private async Task ReadOptionsAsync(DateTimeOffset now, Func<TimeSpan?> timeout, CancellationToken cancellationToken)
    {
        if (timeout() is not { } limit)
        {
            Gap(now, $"Automatic tuning's options (RCA-AZ-03) weren't read on {target} at the end: the end's reads had no time left.");
            return;
        }

        var options = await access.RunAsync(SqlAutomaticTuning.OptionsBlock, now, CaptureParameters.None, limit, cancellationToken).ConfigureAwait(false);
        if (options.Rows is { } rows)
        {
            Returned(SqlAutomaticTuning.OptionsBlock, rows);
            tuning.Options(rows, now).ForEach(sink.Write);
        }
        else
        {
            GapOnce(now, "tuning-options", $"Automatic tuning's options (RCA-AZ-03) weren't read on {target}: {Why(SqlAutomaticTuning.OptionsBlock, options)}");
        }
    }

    /// <summary>RCA-AZ-04: the tuning recommendations, and one that appeared or whose state changed (RCA Query Events).</summary>
    private async Task ReadRecommendationsAsync(DateTimeOffset now, Func<TimeSpan?> timeout, CancellationToken cancellationToken)
    {
        if (timeout() is not { } limit)
        {
            Gap(now, $"Automatic tuning's recommendations (RCA-AZ-04) weren't read on {target} at the end: the end's reads had no time left.");
            return;
        }

        var recommendations = await access.RunAsync(SqlAutomaticTuning.RecommendationsBlock, now, CaptureParameters.None, limit, cancellationToken).ConfigureAwait(false);
        if (recommendations.Rows is { } rows)
        {
            Returned(SqlAutomaticTuning.RecommendationsBlock, rows);
            tuning.Recommendations(rows, now).ForEach(sink.Write);
        }
        else
        {
            GapOnce(now, "tuning-recommendations", $"Automatic tuning's recommendations (RCA-AZ-04) weren't read on {target}: {Why(SqlAutomaticTuning.RecommendationsBlock, recommendations)}");
        }
    }

    /// <summary>
    /// Runs the interval read's blocks in order, RCA-SQL-10 and 11 page by page, then RCA-SQL-14, then its coverage row:
    /// one block at most with <paramref name="oneBlock"/>, and none once <paramref name="timeout"/> has no time left. A step
    /// with no block to run, such as RCA-SQL-14 with nothing to ask, doesn't count.
    /// </summary>
    private async Task AdvanceAsync(IntervalRead current, DateTimeOffset now, Func<TimeSpan?> timeout, bool oneBlock, CancellationToken cancellationToken)
    {
        var blocks = 0;
        while (current.Phase != Phase.Done)
        {
            if (current.Phase == Phase.Plans && !HasPlansToRead(current))
            {
                Finish(current, now);
                return;
            }

            if ((oneBlock && blocks > 0) || timeout() is not { } limit)
            {
                return;
            }

            blocks++;
            switch (current.Phase)
            {
                case Phase.Stats:
                    await StatsAsync(current, now, limit, cancellationToken).ConfigureAwait(false);
                    break;
                case Phase.Waits:
                    await WaitsAsync(current, now, limit, cancellationToken).ConfigureAwait(false);
                    break;
                default:
                    await PlansAsync(current, now, limit, cancellationToken).ConfigureAwait(false);
                    Finish(current, now);
                    break;
            }
        }
    }

    /// <summary>One page of RCA-SQL-10: the intervals that ended after <see cref="since"/>, the oldest first.</summary>
    private async Task StatsAsync(IntervalRead current, DateTimeOffset now, TimeSpan timeout, CancellationToken cancellationToken)
    {
        current.From = since;
        current.Pages++;
        var result = await access.RunAsync(SqlQueryStoreRows.StatsBlock, now, CaptureParameters.Named(("@since", current.From), ("@final", current.Final)), timeout, cancellationToken).ConfigureAwait(false);
        if (result.Rows is not { } rows)
        {
            current.Complete = false;
            current.Phase = Phase.Plans;
            GapOnce(now, "stats", $"Query Store's statistics (RCA-SQL-10) weren't read on {target}: {Why(SqlQueryStoreRows.StatsBlock, result)} {Then(current.Final, current.From)}");
            return;
        }

        Returned(SqlQueryStoreRows.StatsBlock, rows);
        var kept = rows.Select(r => SqlQueryStoreRows.Stats(target, r, now)).OfType<CaptureRow>().ToList();
        var intervals = kept.Select(SqlQueryStoreRows.Interval).Distinct().OrderBy(i => i.Start).ToList();
        current.Capped = rows.Count >= settings.RowCap;
        if (current.Capped && intervals.Count > 1)
        {
            // The block returns the oldest intervals first: its last one may have been cut, so the next page reads it whole.
            var cut = intervals[^1];
            kept.RemoveAll(r => SqlQueryStoreRows.Interval(r) == cut);
            intervals.RemoveAt(intervals.Count - 1);
        }
        else if (current.Capped && intervals.Count == 1)
        {
            Gap(now, string.Create(CultureInfo.InvariantCulture, $"Query Store's interval from {intervals[0].Start:HH:mm} to {intervals[0].End:HH:mm} UTC on {target} had more than {settings.RowCap} rows in its top lists; the observer kept the {settings.RowCap} that used the most CPU."));
        }

        if (kept.Count == 0)
        {
            current.Phase = Phase.Plans;
            return;
        }

        foreach (var row in kept)
        {
            sink.Write(row);
            var plan = (long)row.Get("plan_id")!;
            current.Queries.Add((long)row.Get("query_id")!);
            current.Plans.Add(plan);
            current.Cpu[plan] = current.Cpu.GetValueOrDefault(plan) + (row.Get("cpu_ms") as double? ?? 0);
        }

        readFrom = readFrom is { } first && first <= intervals[0].Start ? first : intervals[0].Start;
        var newest = intervals.Max(i => i.End);
        readTo = readTo is { } last && last >= newest ? last : newest;
        current.Kept = kept;
        current.Phase = Phase.Waits;
    }

    /// <summary>RCA-SQL-11 for the plans the page kept: only the waits of the intervals and plans it kept. Then the next page, or the plans.</summary>
    private async Task WaitsAsync(IntervalRead current, DateTimeOffset now, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var kept = current.Kept;
        var pairs = kept.Select(r => (SqlQueryStoreRows.Interval(r).Start, (long)r.Get("plan_id")!)).ToHashSet();
        var parameters = CaptureParameters.Named(("@since", current.From), ("@final", current.Final), ("@plans", SqlQueryStoreRows.Ids(pairs.Select(p => p.Item2))));
        var result = await access.RunAsync(SqlQueryStoreRows.WaitsBlock, now, parameters, timeout, cancellationToken).ConfigureAwait(false);
        if (result.Rows is { } rows)
        {
            Returned(SqlQueryStoreRows.WaitsBlock, rows);
            foreach (var row in rows)
            {
                if (SqlQueryStoreRows.Wait(target, row, now) is { } wait && pairs.Contains((SqlQueryStoreRows.Interval(wait).Start, (long)wait.Get("plan_id")!)))
                {
                    sink.Write(wait);
                }
            }
        }
        else
        {
            GapOnce(now, "waits", $"Query Store's waits (RCA-SQL-11) weren't read on {target}: {Why(SqlQueryStoreRows.WaitsBlock, result)} The statistics' wait_ms holds each plan's total.");
        }

        var newest = kept.Max(r => SqlQueryStoreRows.Interval(r).End);
        since = newest > since ? newest : since;
        current.Kept = [];
        if (!current.Capped)
        {
            current.Phase = Phase.Plans;
        }
        else if (current.Pages >= settings.MaximumPages)
        {
            Gap(now, string.Create(CultureInfo.InvariantCulture, $"Query Store on {target} had more top-list rows than {settings.MaximumPages} pages of {settings.RowCap} take. {Then(current.Final, since)}"));
            current.Phase = Phase.Plans;
        }
        else
        {
            current.Phase = Phase.Stats;
        }
    }

    private bool HasPlansToRead(IntervalRead current) =>
        current.Queries.Count > 0 || current.Plans.Count > 0 || ForcedPlans().Any(p => !sent.TryGetValue(p, out var s) || s.Forced != true);

    private HashSet<long> ForcedPlans() => state?.Forced.Keys.Select(k => k.Plan).ToHashSet() ?? [];

    /// <summary>
    /// RCA-SQL-14 for the read's queries and plans: a plan's row when it wasn't written in this observation, or when its
    /// forcing, its forcing failures, or its last compile changed, or its summary is new. A plan's showplan is fetched
    /// once per observation, at most <see cref="SqlQueryStoreOptions.PlansWithXml"/> a read, and only up to
    /// <see cref="PlanSummary.MaximumXmlBytes"/>; one past that is a gap that says its size.
    /// </summary>
    private async Task PlansAsync(IntervalRead current, DateTimeOffset now, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var forced = ForcedPlans();
        var withPlan = current.Plans.Union(forced)
            .Where(p => !reduced.ContainsKey(p))
            .OrderByDescending(forced.Contains)
            .ThenByDescending(p => current.Cpu.GetValueOrDefault(p))
            .ThenBy(p => p)
            .Take(settings.PlansWithXml)
            .ToHashSet();
        var parameters = CaptureParameters.Named(("@queries", SqlQueryStoreRows.Ids(current.Queries)), ("@plans", SqlQueryStoreRows.Ids(current.Plans)), ("@with_plan", SqlQueryStoreRows.Ids(withPlan)));
        var result = await access.RunAsync(SqlQueryStoreRows.PlansBlock, now, parameters, timeout, cancellationToken).ConfigureAwait(false);
        if (result.Rows is not { } rows)
        {
            Carry(carriedQueries, current.Queries);
            Carry(carriedPlans, current.Plans);
            GapOnce(now, "plans", $"Query Store's plans (RCA-SQL-14) weren't read on {target}: {Why(SqlQueryStoreRows.PlansBlock, result)} The next read asks for them again.");
            return;
        }

        Returned(SqlQueryStoreRows.PlansBlock, rows);
        carriedQueries.Clear();
        carriedPlans.Clear();
        foreach (var row in rows)
        {
            if (row.Long("plan_id") is not { } plan)
            {
                continue;
            }

            if (withPlan.Contains(plan) && !reduced.ContainsKey(plan))
            {
                reduced[plan] = Summarize(row, plan, now);
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

        // A plan asked for with its showplan that the read didn't return isn't asked for again in this observation.
        foreach (var plan in withPlan)
        {
            reduced.TryAdd(plan, null);
        }
    }

    /// <summary>A plan's shape from the showplan RCA-SQL-14 returned, or null with a gap that says why it has none.</summary>
    private PlanShape? Summarize(CaptureValues row, long plan, DateTimeOffset now)
    {
        string? problem;
        PlanShape? shape = null;
        if (row.Text("query_plan") is { Length: > 0 } xml)
        {
            shape = PlanSummary.Reduce(xml, out problem);
        }
        else if (row.Long("query_plan_bytes") is { } bytes && bytes > PlanSummary.MaximumXmlBytes)
        {
            problem = string.Create(CultureInfo.InvariantCulture, $"its showplan has {bytes:N0} bytes, more than the {PlanSummary.MaximumXmlBytes:N0} the observer reads");
        }
        else
        {
            PlanSummary.Reduce(null, out problem);
        }

        if (problem is not null)
        {
            Gap(now, string.Create(CultureInfo.InvariantCulture, $"Plan {plan} on {target} has no summary: {problem}."));
        }

        return shape;
    }

    /// <summary>The read is done: its coverage row, and when the next one starts.</summary>
    private void Finish(IntervalRead current, DateTimeOffset now)
    {
        current.Phase = Phase.Done;
        WriteCoverage(now);
        if (!current.Final)
        {
            var scheduled = schedule.NextRead(now);
            nextRead = current.Complete || now + settings.Retry >= scheduled ? scheduled : now + settings.Retry;
        }

        read = null;
    }

    /// <summary>A read given up before its plans: the IDs it had read wait for the next read's.</summary>
    private void Abandon(IntervalRead current)
    {
        Carry(carriedQueries, current.Queries);
        Carry(carriedPlans, current.Plans);
        read = null;
    }

    /// <summary>
    /// Why a block returned nothing, for its gap. A refusal names the permission the block needs, whatever the server's
    /// message says, then the server's message and the fix: the observer's for the target (<see cref="ISidecarAccess"/>),
    /// or RCA-AZ-04's own, since the target's general fix doesn't give a server permission.
    /// </summary>
    private string Why(string block, QuietResult result)
    {
        if (result.Failure != CaptureFailureKind.Permission)
        {
            return result.Message ?? "the read returned no rows and no error.";
        }

        return block == SqlAutomaticTuning.RecommendationsBlock
            ? $"it needs {Permission(block)}, and {target} refused it: {result.Error ?? result.Message} {ServerPermissionFix}"
            : $"it needs {Permission(block)}, and {target} refused it: {result.Message}";
    }

    /// <summary>
    /// The permission a block needs, as Learn gives it for its view (rca/capture/README.md): Query Store's catalog views
    /// (https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-runtime-stats-transact-sql#permissions),
    /// sys.database_automatic_tuning_options, and sys.dm_db_tuning_recommendations
    /// (https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-tuning-recommendations-transact-sql#permissions).
    /// </summary>
    private static string Permission(string block) => block switch
    {
        SqlAutomaticTuning.OptionsBlock => "VIEW DATABASE STATE",
        SqlAutomaticTuning.RecommendationsBlock => "VIEW SERVER PERFORMANCE STATE, a server permission",
        _ => "VIEW DATABASE PERFORMANCE STATE, or VIEW DATABASE STATE, which includes it",
    };

    /// <summary>What happens to the intervals a failed read didn't take.</summary>
    private static string Then(bool final, DateTimeOffset from) => final
        ? "The next observation's first read takes those of them that ended in its look-back."
        : string.Create(CultureInfo.InvariantCulture, $"The next read takes the intervals that ended after {from:HH:mm} UTC.");

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

    /// <summary>One interval read: RCA-SQL-10 and 11 page by page, then RCA-SQL-14, then its coverage row.</summary>
    private sealed class IntervalRead(bool final, IEnumerable<long> queries, IEnumerable<long> plans)
    {
        public bool Final { get; } = final;

        public Phase Phase { get; set; } = Phase.Stats;

        public int Pages { get; set; }

        /// <summary>The since of the page being read.</summary>
        public DateTimeOffset From { get; set; }

        public bool Capped { get; set; }

        /// <summary>The page's statistics, whose waits come next.</summary>
        public List<CaptureRow> Kept { get; set; } = [];

        public HashSet<long> Queries { get; } = [.. queries];

        public HashSet<long> Plans { get; } = [.. plans];

        public Dictionary<long, double> Cpu { get; } = [];

        /// <summary>False once RCA-SQL-10 failed: the next read comes sooner.</summary>
        public bool Complete { get; set; } = true;
    }
}
