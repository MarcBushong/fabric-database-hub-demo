namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// When the observer reads Query Store (rca/README.md, Query Store): 2 minutes after each interval ends, the intervals
/// that ended since the previous read; at its start, the 2 hours before it, so a rule has a baseline; and at its end. The
/// interval is Query Store's own (15 minutes on every target), which the observer reads with its state (RCA-SQL-15,
/// RCA-PG-13). Intervals are taken to start on whole multiples of their length from midnight UTC; a read asks for the
/// intervals that ended after the last one it read, so a different alignment changes only when it reads, never what.
/// </summary>
internal sealed class QueryStoreSchedule
{
    public QueryStoreSchedule(TimeSpan interval, TimeSpan delay, TimeSpan lookBack)
    {
        if (interval <= TimeSpan.Zero || delay < TimeSpan.Zero || delay >= interval || lookBack < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(interval), "Query Store's schedule needs a positive interval, a delay shorter than it, and a look-back of zero or more.");
        }

        Interval = interval;
        Delay = delay;
        LookBack = lookBack;
    }

    public static QueryStoreSchedule Default { get; } = new(TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(2), TimeSpan.FromHours(2));

    public TimeSpan Interval { get; }

    public TimeSpan Delay { get; }

    public TimeSpan LookBack { get; }

    /// <summary>The first read's since: the look-back before the observer's start.</summary>
    public DateTimeOffset FirstSince(DateTimeOffset start) => start.ToUniversalTime() - LookBack;

    /// <summary>The end of the interval that holds <paramref name="time"/>: the next whole multiple of the interval after it.</summary>
    public DateTimeOffset IntervalEnd(DateTimeOffset time) => new((time.UtcTicks / Interval.Ticks + 1) * Interval.Ticks, TimeSpan.Zero);

    /// <summary>The next read strictly after <paramref name="now"/>: an interval's end plus the delay.</summary>
    public DateTimeOffset NextRead(DateTimeOffset now) => IntervalEnd(now.ToUniversalTime() - Delay) + Delay;

    /// <summary>A copy for another interval length, as Query Store's state reports it, with the same look-back.</summary>
    public QueryStoreSchedule WithInterval(TimeSpan interval) => interval == Interval ? this : new QueryStoreSchedule(interval, Delay < interval ? Delay : TimeSpan.Zero, LookBack);
}
