using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>What one read of T4's Query Store returned: whole intervals only, and the first failure, if any.</summary>
/// <param name="Statistics">RCA-PG-14's rows, of whole intervals.</param>
/// <param name="Waits">RCA-PG-15's rows for those intervals, roles, and queries.</param>
/// <param name="Through">The end of the newest interval the statistics hold; null when they hold none.</param>
/// <param name="Complete">True when the read reached the end of the time it asked for, with no failure.</param>
/// <param name="Failure">Why a block failed, or null.</param>
/// <param name="FailedBlock">The block that failed, or null.</param>
internal sealed record PgQueryStoreRead(IReadOnlyList<CaptureValues> Statistics, IReadOnlyList<CaptureValues> Waits, DateTimeOffset? Through, bool Complete, CaptureException? Failure, string? FailedBlock);

/// <summary>
/// Reads T4's Query Store on a connection to azure_sys (RCA-PG-14 and RCA-PG-15): the intervals that end after a time and
/// start before another, earliest first, but the observer's own statements and the harness's. RCA-PG-14 returns at most
/// <see cref="PageRows"/> rows, so a read that gets that many keeps the intervals it got whole and reads on from the last
/// one's end, up to <see cref="MaximumPages"/> times; what's left, the next read takes.
/// </summary>
internal static class PgQueryStoreReader
{
    /// <summary>RCA-PG-14's LIMIT.</summary>
    public const int PageRows = 600;

    /// <summary>At most 20 rows an interval, so a page holds at least 30 intervals; 8 pages are 60 hours of them.</summary>
    public const int MaximumPages = 8;

    /// <summary>RCA-PG-14's $7: every statement the observer sends to contosocare.</summary>
    private static readonly string[] OwnStatements = [.. PgObserverStatements.All];

    public static async Task<PgQueryStoreRead> ReadAsync(ICaptureConnection connection, string database, DateTimeOffset since, DateTimeOffset until, PgHarness harness, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(harness);
        var statistics = new List<CaptureValues>();
        var from = since;
        var complete = false;
        for (var page = 0; page < MaximumPages; page++)
        {
            IReadOnlyList<CaptureValues> rows;
            try
            {
                rows = await connection.QueryAsync(
                    PgQueryStoreRows.Statistics,
                    CaptureCatalog.Get(PgQueryStoreRows.Statistics),
                    CaptureParameters.Positional(database, from, harness.Functions.ToArray(), harness.HarnessTables.ToArray(), harness.OtherTables.ToArray(), until, OwnStatements),
                    timeout,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (CaptureException ex)
            {
                // The pages before the failure hold whole intervals: they're kept, with their waits.
                var partial = new PgQueryStoreRead(statistics, [], Newest(statistics), false, ex, PgQueryStoreRows.Statistics);
                return await WithWaitsAsync(connection, database, since, until, partial, timeout, cancellationToken).ConfigureAwait(false);
            }

            var whole = rows.Where(r => r.Time("interval_start_utc") is not null && r.Time("interval_end_utc") is not null).ToList();
            if (rows.Count < PageRows)
            {
                statistics.AddRange(whole);
                complete = true;
                break;
            }

            // The page may have cut its last interval short: keep the intervals before it, and read on from their end.
            var last = whole.Max(r => r.Time("interval_start_utc")!.Value);
            var before = whole.Where(r => r.Time("interval_start_utc")!.Value < last).ToList();
            if (before.Count == 0)
            {
                statistics.AddRange(whole);
                break;
            }

            statistics.AddRange(before);
            from = before.Max(r => r.Time("interval_end_utc")!.Value);
        }

        return await WithWaitsAsync(connection, database, since, until, new PgQueryStoreRead(statistics, [], Newest(statistics), complete, null, null), timeout, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>RCA-PG-15 for the statistics' queries, keeping only the waits of the intervals, roles, and queries they hold.</summary>
    private static async Task<PgQueryStoreRead> WithWaitsAsync(ICaptureConnection connection, string database, DateTimeOffset since, DateTimeOffset until, PgQueryStoreRead read, TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (read.Statistics.Count == 0)
        {
            return read;
        }

        var queries = read.Statistics.Select(r => r.Long("query_id")).OfType<long>().Distinct().Order().ToArray();
        var keys = read.Statistics.Select(Key).ToHashSet();
        IReadOnlyList<CaptureValues> waits;
        try
        {
            waits = await connection.QueryAsync(
                PgQueryStoreRows.Waits,
                CaptureCatalog.Get(PgQueryStoreRows.Waits),
                CaptureParameters.Positional(database, since, queries, until),
                timeout,
                cancellationToken).ConfigureAwait(false);
        }
        catch (CaptureException ex)
        {
            return read with { Complete = false, Failure = read.Failure ?? ex, FailedBlock = read.FailedBlock ?? PgQueryStoreRows.Waits };
        }

        return read with { Waits = [.. waits.Where(w => keys.Contains(Key(w)))] };
    }

    private static (DateTimeOffset? Start, string? Login, long? Query) Key(CaptureValues row) => (row.Time("interval_start_utc"), row.Text("login_name"), row.Long("query_id"));

    private static DateTimeOffset? Newest(List<CaptureValues> rows) => rows.Count == 0 ? null : rows.Max(r => r.Time("interval_end_utc"));
}
