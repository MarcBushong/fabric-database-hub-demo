using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>What one range's read of T4's Query Store returned: whole intervals only, and the first failure, if any.</summary>
/// <param name="Statistics">RCA-PG-14's rows, of whole intervals.</param>
/// <param name="Waits">RCA-PG-15's rows for those intervals, roles, and queries.</param>
/// <param name="Through">The end of the newest interval the statistics hold; null when they hold none.</param>
/// <param name="Complete">True when the read reached the end of the time it asked for, with no failure.</param>
/// <param name="Failure">Why a block failed, or null.</param>
/// <param name="FailedBlock">The block that failed, or null.</param>
internal sealed record PgQueryStoreRead(IReadOnlyList<CaptureValues> Statistics, IReadOnlyList<CaptureValues> Waits, DateTimeOffset? Through, bool Complete, CaptureException? Failure, string? FailedBlock);

/// <summary>
/// One range's read of T4's Query Store on azure_sys (RCA-PG-14 and RCA-PG-15), a block at a time: the intervals that end
/// after <c>from</c> and start before <c>to</c>, earliest first, but the observer's own statements and the harness's.
/// RCA-PG-14 returns at most <see cref="PageRows"/> rows, so a page that gets that many keeps the intervals it got whole,
/// and the next page reads on from the last one's end, up to <see cref="MaximumPages"/> pages; what's left, the next read
/// takes. Then RCA-PG-15, once, for the statistics' queries. A failure ends the read: what it read stays, and a page that
/// failed still takes the waits of the pages before it.
/// </summary>
internal sealed class PgQueryStoreReader(string database, DateTimeOffset from, DateTimeOffset to, PgHarness harness)
{
    /// <summary>RCA-PG-14's LIMIT.</summary>
    public const int PageRows = 600;

    /// <summary>At most 20 rows an interval, so a page holds at least 30 intervals; 8 pages are 60 hours of them.</summary>
    public const int MaximumPages = 8;

    /// <summary>RCA-PG-14's $7: every statement the observer sends to contosocare.</summary>
    private static readonly string[] OwnStatements = [.. PgObserverStatements.All];

    private readonly List<CaptureValues> statistics = [];
    private readonly DateTimeOffset since = from;
    private List<CaptureValues> waits = [];
    private DateTimeOffset pageFrom = from;
    private int pages;
    private bool complete;
    private CaptureException? failure;
    private string? failedBlock;

    public DateTimeOffset From => since;

    public DateTimeOffset To => to;

    /// <summary>The block the read runs next (RCA-PG-14 or RCA-PG-15), or null once it's done.</summary>
    public string? NextBlock { get; private set; } = PgQueryStoreRows.Statistics;

    public bool Done => NextBlock is null;

    /// <summary>The read as it stands: whole intervals, and complete only when it reached its end with no failure.</summary>
    public PgQueryStoreRead Result => new(statistics, waits, statistics.Count == 0 ? null : statistics.Max(r => r.Time("interval_end_utc")), complete && failure is null, failure, failedBlock);

    /// <summary>Reads a range whole on one connection: every block in turn, each with <paramref name="timeout"/>.</summary>
    public static async Task<PgQueryStoreRead> ReadAsync(ICaptureConnection connection, string database, DateTimeOffset since, DateTimeOffset until, PgHarness harness, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        var read = new PgQueryStoreReader(database, since, until, harness);
        while (!read.Done)
        {
            await read.StepAsync(connection, timeout, cancellationToken).ConfigureAwait(false);
        }

        return read.Result;
    }

    /// <summary>Runs the read's next block on <paramref name="connection"/>, a connection to azure_sys; a failure is the read's.</summary>
    public async Task StepAsync(ICaptureConnection connection, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(harness);
        if (NextBlock == PgQueryStoreRows.Statistics)
        {
            await PageAsync(connection, timeout, cancellationToken).ConfigureAwait(false);
        }
        else if (NextBlock == PgQueryStoreRows.Waits)
        {
            await WaitsAsync(connection, timeout, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>Ends the read before its next block: the connection to azure_sys failed, or the time for it ran out.</summary>
    public void Fail(CaptureException exception)
    {
        failure ??= exception;
        failedBlock ??= NextBlock ?? PgQueryStoreRows.Statistics;
        complete = false;
        NextBlock = null;
    }

    private static (DateTimeOffset? Start, string? Login, long? Query) Key(CaptureValues row) => (row.Time("interval_start_utc"), row.Text("login_name"), row.Long("query_id"));

    /// <summary>One page of RCA-PG-14.</summary>
    private async Task PageAsync(ICaptureConnection connection, TimeSpan timeout, CancellationToken cancellationToken)
    {
        IReadOnlyList<CaptureValues> rows;
        try
        {
            rows = await connection.QueryAsync(
                PgQueryStoreRows.Statistics,
                CaptureCatalog.Get(PgQueryStoreRows.Statistics),
                CaptureParameters.Positional(database, pageFrom, harness.Functions.ToArray(), harness.HarnessTables.ToArray(), harness.OtherTables.ToArray(), to, OwnStatements),
                timeout,
                cancellationToken).ConfigureAwait(false);
        }
        catch (CaptureException ex)
        {
            // The pages before the failure hold whole intervals: they're kept, with their waits.
            failure = ex;
            failedBlock = PgQueryStoreRows.Statistics;
            NextBlock = statistics.Count > 0 ? PgQueryStoreRows.Waits : null;
            return;
        }

        pages++;
        var whole = rows.Where(r => r.Time("interval_start_utc") is not null && r.Time("interval_end_utc") is not null).ToList();
        if (rows.Count < PageRows)
        {
            statistics.AddRange(whole);
            complete = true;
            NextBlock = statistics.Count > 0 ? PgQueryStoreRows.Waits : null;
            return;
        }

        // The page may have cut its last interval short: keep the intervals before it, and read on from their end.
        var last = whole.Max(r => r.Time("interval_start_utc")!.Value);
        var before = whole.Where(r => r.Time("interval_start_utc")!.Value < last).ToList();
        if (before.Count == 0)
        {
            statistics.AddRange(whole);
            NextBlock = PgQueryStoreRows.Waits;
            return;
        }

        statistics.AddRange(before);
        pageFrom = before.Max(r => r.Time("interval_end_utc")!.Value);
        if (pages >= MaximumPages)
        {
            NextBlock = PgQueryStoreRows.Waits;
        }
    }

    /// <summary>RCA-PG-15 for the statistics' queries, keeping only the waits of the intervals, roles, and queries they hold.</summary>
    private async Task WaitsAsync(ICaptureConnection connection, TimeSpan timeout, CancellationToken cancellationToken)
    {
        NextBlock = null;
        var queries = statistics.Select(r => r.Long("query_id")).OfType<long>().Distinct().Order().ToArray();
        var keys = statistics.Select(Key).ToHashSet();
        try
        {
            var rows = await connection.QueryAsync(
                PgQueryStoreRows.Waits,
                CaptureCatalog.Get(PgQueryStoreRows.Waits),
                CaptureParameters.Positional(database, since, queries, to),
                timeout,
                cancellationToken).ConfigureAwait(false);
            waits = [.. rows.Where(w => keys.Contains(Key(w)))];
        }
        catch (CaptureException ex)
        {
            complete = false;
            failure ??= ex;
            failedBlock ??= PgQueryStoreRows.Waits;
        }
    }
}