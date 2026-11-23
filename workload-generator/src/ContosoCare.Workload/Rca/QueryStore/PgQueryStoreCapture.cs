using System.Globalization;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>Where T4's Query Store is read from, and where its unread time is kept: the observer's wiring.</summary>
/// <param name="QueryStore">Connections to T4's azure_sys (<see cref="PgCaptureConnector.QueryStore"/>), one per block.</param>
/// <param name="Watermark">The unread-interval watermark, in the evidence store's folder.</param>
/// <param name="Spans">The span store's side of a backfill; without it, nothing is recorded as pending or backfilled.</param>
/// <param name="Schedule">When to read; the interval Query Store reports replaces its interval.</param>
/// <param name="Database">The database whose statements are read.</param>
internal sealed record PgQueryStoreSource(ICaptureConnector QueryStore, QueryWatermark Watermark, ISidecarSpans? Spans = null, QueryStoreSchedule? Schedule = null, string Database = PgEndpoint.DatabaseName);

/// <summary>
/// T4's sidecar reads' timings and bounds (rca/README.md, The sidecar): Query Store's (RCA-PG-13 to 16) and who holds the
/// connections (RCA-PG-17). A block runs in the observer's tick only when its timeout ends before the evidence capture's
/// next work. Tests shorten or measure them.
/// </summary>
internal sealed record PgSidecarOptions
{
    /// <summary>RCA-PG-13, 16, and 17, which read a few rows on the observer's own connection.</summary>
    public TimeSpan LightTimeout { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>Opening a connection to azure_sys, which each RCA-PG-14 page and RCA-PG-15 opens for itself and closes after it.</summary>
    public TimeSpan OpenTimeout { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>One RCA-PG-14 page, or RCA-PG-15.</summary>
    public TimeSpan ReadTimeout { get; init; } = TimeSpan.FromSeconds(15);

    /// <summary>A block runs in a tick only when its timeout would end at least this long before the evidence capture's next work.</summary>
    public TimeSpan Margin { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>The observer's end: its Query Store reads together, each block's timeout cut to what's left of this.</summary>
    public TimeSpan EndBudget { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>How soon a read that threw, or waited for a slowed observer, is tried again.</summary>
    public TimeSpan Retry { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>Measures how long a tick's work and the end's reads took: durations only, never the time of day.</summary>
    public TimeProvider Clock { get; init; } = TimeProvider.System;

    /// <summary>A block on azure_sys: its connection's open, and the block.</summary>
    public TimeSpan StoreBlock => OpenTimeout + ReadTimeout;
}

/// <summary>
/// T4's Query Store in the sidecar (rca/README.md, Query Store and Pending publication), for the PostgreSQL observer. A
/// read takes Query Store's settings (RCA-PG-13) and the harness (RCA-PG-16) quietly on the observer's own connection
/// (<see cref="ISidecarAccess"/>), then, on connections to azure_sys of its own, earlier spans' unsettled time (the
/// backfill) and this observation's intervals (RCA-PG-14 and 15): the 2 hours before the observer's start first, then
/// 2 minutes after each interval ends, and at its end.
/// <para>
/// None of it changes the evidence document. A read runs last in the observer's tick, one block a tick, and a block only
/// when its timeout ends before the evidence capture's next work; each block on azure_sys opens its connection and closes
/// it, so none is open when the evidence counts T4's connections. A read under way asks for no tick of its own: it takes
/// the ticks the lane makes anyway. While the observer is slowed or has stopped its detail capture, no read starts (Query
/// Store keeps the intervals), and the end's read takes at most <see cref="PgSidecarOptions.EndBudget"/>. Every failure
/// is a gap in RCA Query Coverage, never one in RCA Coverage.
/// </para>
/// <para>
/// An interval is settled once a read took it at least <see cref="PublishedAfter"/> after it ended, when Query Store has
/// surely published all of it. Until then each read takes it again, and writes its rows again only when they changed, so
/// counts or waits that Query Store published late still reach the sidecar (the latest read of an interval wins). The time
/// still unsettled at the observer's end is kept in the watermark for this span, and the coverage says what Query Store
/// hadn't published yet, never that it wasn't captured. A later read that finds T4 started since then splits that time at
/// T4's start: what Query Store doesn't show before it is lost, and the rest waits as before.
/// </para>
/// Without the harness's list, nothing is read: its bookkeeping would be in it.
/// </summary>
internal sealed class PgQueryStoreCapture(ISidecarAccess access, PgQueryStoreSource source, ISidecarSink sidecar, PgSidecarOptions options, RunnerLog log)
{
    /// <summary>
    /// How long after an interval ends Query Store has surely published it: Learn allows "up to 20 minutes for the first
    /// batch of data to persist" (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store).
    /// </summary>
    public static readonly TimeSpan PublishedAfter = TimeSpan.FromMinutes(20);

    /// <summary>At most this many earlier ranges are backfilled in one read, so a read stays short.</summary>
    public const int BackfillsPerRead = 4;

    private static readonly string[] StatsColumns = ["login_name", "statement_text", "executions", "duration_ms", "max_duration_ms", "logical_reads", "physical_reads", "row_count", "tempdb_kb", "wait_ms"];

    private static readonly string[] WaitColumns = ["wait_category", "wait_event", "samples", "wait_ms"];

    // What was written of each unsettled interval, by sink (this observation's, or an earlier range's): a row is written
    // again only when a later read found it changed.
    private readonly Dictionary<string, Dictionary<string, Written>> written = new(StringComparer.Ordinal);

    // What another sidecar read of T4 (RCA-PG-17), a read that waited, or one that didn't finish leaves for the next row.
    private readonly SortedSet<string> carriedSources = new(StringComparer.Ordinal);
    private readonly List<string> carriedGaps = [];
    private QueryStoreSchedule schedule = source.Schedule ?? QueryStoreSchedule.Default;
    private DateTimeOffset observingSince;
    private DateTimeOffset lastRead;
    private DateTimeOffset? through;
    private DateTimeOffset? settled;
    private PgQueryStoreSettings? settings;
    private PgHarness? harness;
    private Cycle? cycle;
    private bool held;

    private enum Phase
    {
        Settings,
        Harness,
        Backfill,
        Current,
        Done,
    }

    /// <summary>When the next read is due: at the observer's start, then 2 minutes after each interval ends.</summary>
    public DateTimeOffset NextRead { get; private set; } = DateTimeOffset.MaxValue;

    /// <summary>The end of the newest interval this observation's reads found published.</summary>
    public DateTimeOffset? Through => through;

    /// <summary>Every interval that ends by this time is settled: a read took it once Query Store had surely published it.</summary>
    public DateTimeOffset? Settled => settled;

    /// <summary>True while a read is under way: it runs a block a tick until it's done.</summary>
    public bool Reading => cycle is not null;

    private string Target => access.Target;

    /// <summary>A timestamp of the reads' clock, which the observer takes at its tick's start, so the tick's evidence work counts against the reads' room.</summary>
    public long Timestamp() => options.Clock.GetTimestamp();

    public void Begin(DateTimeOffset now)
    {
        schedule = source.Schedule ?? QueryStoreSchedule.Default;
        observingSince = now;
        lastRead = now;
        through = null;
        settled = null;
        settings = null;
        harness = null;
        cycle = null;
        held = false;
        written.Clear();
        carriedSources.Clear();
        carriedGaps.Clear();
        NextRead = now;
    }

    /// <summary>What another sidecar read of T4 leaves for the next RCA Query Coverage row: a block that returned rows, or a gap.</summary>
    public void Note(string? returned, string? gap)
    {
        if (returned is not null)
        {
            carriedSources.Add(returned);
        }

        if (gap is not null)
        {
            carriedGaps.Add(gap);
        }
    }

    /// <summary>
    /// The read's next block, when one is due and fits before <paramref name="evidenceDue"/>, the evidence capture's next
    /// work, counting from <paramref name="tickStarted"/> (<see cref="Timestamp"/>). A read that throws is dropped and tried
    /// again <see cref="PgSidecarOptions.Retry"/> later. Returns when the reads next have work.
    /// </summary>
    public async Task<DateTimeOffset> TickAsync(DateTimeOffset now, long tickStarted, DateTimeOffset evidenceDue, CancellationToken cancellationToken)
    {
        bool Fits(TimeSpan timeout) => evidenceDue - now - options.Clock.GetElapsedTime(tickStarted) >= timeout + options.Margin;

        if (cycle is null && now >= NextRead)
        {
            if (Held(now))
            {
                NextRead = now + options.Retry;
            }
            else
            {
                NextRead = schedule.NextRead(now);
                cycle = new Cycle(now, final: false, lastRead);
            }
        }

        if (cycle is { } current)
        {
            try
            {
                if (Prepare(current, now) is { } need && Fits(need))
                {
                    await StepAsync(current, now, own => own, cancellationToken).ConfigureAwait(false);
                    Prepare(current, now);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                Abandon(current);
                NextRead = Earlier(NextRead, now + options.Retry);
                throw;
            }
        }

        // A read under way takes its next block at the lane's next tick, which comes within a second anyway: it asks for no
        // tick of its own, so the evidence's ticks, and its watermark, stay as they'd be without it.
        return cycle is null ? NextRead : evidenceDue;
    }

    /// <summary>
    /// The last read, at the observer's end, after the evidence capture's own: what's published, within
    /// <see cref="PgSidecarOptions.EndBudget"/>, and the rest kept as unsettled for a later read. A read cut short, by its
    /// bound or the observer's cancellation, says so in its coverage.
    /// </summary>
    public async Task EndAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var started = options.Clock.GetTimestamp();
        TimeSpan? Left(TimeSpan own)
        {
            var left = options.EndBudget - options.Clock.GetElapsedTime(started);
            return left < TimeSpan.FromSeconds(1) ? null : left < own ? left : own;
        }

        if (cycle is { } open)
        {
            Abandon(open);
        }

        NextRead = DateTimeOffset.MaxValue;
        var final = cycle = new Cycle(now, final: true, lastRead);
        try
        {
            while (Prepare(final, now) is not null)
            {
                if (!await StepAsync(final, now, Left, cancellationToken).ConfigureAwait(false))
                {
                    Cut(final, now, string.Create(CultureInfo.InvariantCulture, $"The end's Query Store reads on {Target} stopped at their bound of {options.EndBudget.TotalSeconds:0} s."));
                    break;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Cut(final, now, $"The end's Query Store reads on {Target} were cut short with the observer's end.");
        }
    }

    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;

    /// <summary>A row's key within its sink: its kind, interval, role, query, and plan.</summary>
    private static string Key(string kind, CaptureRow row, bool plan) => string.Create(
        CultureInfo.InvariantCulture,
        $"{kind}|{((DateTimeOffset)row.Get("interval_start_utc")!).UtcTicks}|{row.Get("login_name")}|{row.Get("query_id")}|{(plan ? row.Get("plan_id") : null)}");

    private static string Signature(CaptureRow row, string[] columns) =>
        string.Join('|', columns.Select(c => row.Get(c) is { } value ? "v" + Convert.ToString(value, CultureInfo.InvariantCulture) : "n"));

    /// <summary>While the observer is slowed or has stopped its detail capture, no read starts: Query Store keeps the intervals.</summary>
    private bool Held(DateTimeOffset now)
    {
        if (access.Factor <= 1 && !access.DetailStopped)
        {
            held = false;
            return false;
        }

        if (!held)
        {
            held = true;
            var why = access.DetailStopped
                ? "the observer stopped its detail capture for the rest of the session, so the end's read takes them"
                : string.Create(CultureInfo.InvariantCulture, $"the observer's samples are slow (its cadence is {access.Factor} times longer), so a read takes them once they're quick again, or the end's read");
            carriedGaps.Add(string.Create(CultureInfo.InvariantCulture, $"Query Store's reads on {Target} wait from {now:HH:mm:ss} UTC: {why}. Query Store keeps the intervals that ended after {settled ?? schedule.FirstSince(observingSince):HH:mm} UTC."));
        }

        return true;
    }

    /// <summary>
    /// Moves a read past what takes no block (a range read that's done, an earlier range that can't or needn't be read, the
    /// read's end), and returns the time its next block needs, or null once the read is finished.
    /// </summary>
    private TimeSpan? Prepare(Cycle current, DateTimeOffset now)
    {
        while (!current.Finished)
        {
            switch (current.Phase)
            {
                case Phase.Settings:
                case Phase.Harness:
                    return options.LightTimeout;
                case Phase.Backfill:
                    if (current.Reader is { } reading)
                    {
                        if (!reading.Done)
                        {
                            return options.StoreBlock;
                        }

                        if (!FinishBackfill(current, now))
                        {
                            current.Ranges!.Clear();
                        }

                        current.Reader = null;
                        continue;
                    }

                    current.Ranges ??= PendingRanges(current);
                    if (current.Ranges.Count > 0)
                    {
                        StartBackfill(current, current.Ranges.Dequeue(), now);
                        continue;
                    }

                    current.Phase = Phase.Current;
                    continue;
                case Phase.Current:
                    current.Reader ??= new PgQueryStoreReader(source.Database, settled ?? schedule.FirstSince(observingSince), current.At, harness!);
                    if (!current.Reader.Done)
                    {
                        return options.StoreBlock;
                    }

                    FinishCurrent(current, now);
                    current.Reader = null;
                    current.Phase = Phase.Done;
                    continue;
                default:
                    FinishCycle(current);
                    break;
            }
        }

        return null;
    }

    /// <summary>
    /// Runs a read's next block, its timeouts as <paramref name="limit"/> allows them (null: no time left, and the block
    /// doesn't run). Returns false when it didn't run.
    /// </summary>
    private async Task<bool> StepAsync(Cycle current, DateTimeOffset now, Func<TimeSpan, TimeSpan?> limit, CancellationToken cancellationToken)
    {
        switch (current.Phase)
        {
            case Phase.Settings:
            {
                if (limit(options.LightTimeout) is not { } timeout)
                {
                    return false;
                }

                TakeSettings(current, await access.RunAsync(PgQueryStoreRows.Settings, now, CaptureParameters.None, timeout, cancellationToken).ConfigureAwait(false), now);
                current.Phase = Phase.Harness;
                return true;
            }

            case Phase.Harness:
            {
                if (limit(options.LightTimeout) is not { } timeout)
                {
                    return false;
                }

                TakeHarness(current, await access.RunAsync(PgQueryStoreRows.Harness, now, CaptureParameters.None, timeout, cancellationToken).ConfigureAwait(false));
                current.Phase = harness is null || settings?.InRecovery == true ? Phase.Done : !current.Final && source.Spans is not null ? Phase.Backfill : Phase.Current;
                return true;
            }

            default:
                return current.Reader is not { Done: false } reader || await StoreBlockAsync(reader, limit, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>One block of a range's read, on a connection to azure_sys opened for it and closed after it.</summary>
    private async Task<bool> StoreBlockAsync(PgQueryStoreReader reader, Func<TimeSpan, TimeSpan?> limit, CancellationToken cancellationToken)
    {
        if (limit(options.OpenTimeout) is not { } openTimeout)
        {
            return false;
        }

        ICaptureConnection connection;
        using (var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            bounded.CancelAfter(openTimeout);
            try
            {
                connection = await source.QueryStore.OpenAsync(bounded.Token).ConfigureAwait(false);
            }
            catch (CaptureException ex)
            {
                reader.Fail(ex);
                return true;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                reader.Fail(new CaptureException(CaptureFailureKind.Timeout, string.Create(CultureInfo.InvariantCulture, $"a connection to azure_sys didn't open within {openTimeout.TotalSeconds:0.#} s.")));
                return true;
            }
        }

        await using (connection.ConfigureAwait(false))
        {
            if (limit(options.ReadTimeout) is not { } readTimeout)
            {
                return false;
            }

            await reader.StepAsync(connection, readTimeout, cancellationToken).ConfigureAwait(false);
            return true;
        }
    }

    private void TakeSettings(Cycle current, QuietResult result, DateTimeOffset now)
    {
        var coverage = current.Coverage;
        if (result.Rows is not { } rows)
        {
            coverage.Gaps.Add(string.Create(CultureInfo.InvariantCulture, $"{PgQueryStoreRows.Settings} couldn't be read on {Target} at {now:HH:mm} UTC, so Query Store's settings are as last read: {PgQueryStoreRows.Why(Target, PgQueryStoreRows.Settings, result)}"));
            return;
        }

        var read = PgQueryStoreSettings.Parse(rows, now);
        current.ServerStarted = read.ServerStarted;
        if (rows.Count > 0)
        {
            coverage.Sources.Add(PgQueryStoreRows.Settings);
        }

        if (settings is { } previous && PgQueryStoreRows.StateChange(Target, previous, read) is { } change)
        {
            sidecar.Write(change);
        }

        settings = read;
        coverage.Gaps.AddRange(read.Gaps(Target));
        if (read.Interval is { } interval && interval != schedule.Interval)
        {
            schedule = schedule.WithInterval(interval);
            if (!current.Final)
            {
                NextRead = schedule.NextRead(current.At);
            }
        }
    }

    private void TakeHarness(Cycle current, QuietResult result)
    {
        var coverage = current.Coverage;
        if (result.Rows is { } rows)
        {
            harness = PgHarness.Parse(rows);
            if (rows.Count > 0)
            {
                coverage.Sources.Add(PgQueryStoreRows.Harness);
            }

            if (harness.Functions.Count == 0)
            {
                coverage.Gaps.Add($"No function in {source.Database} is marked as the harness's (dbhubdemo:harness), so nothing is left out as the harness's.");
            }

            if (harness.UnsureGap(source.Database) is { } unsure)
            {
                coverage.Gaps.Add(unsure);
            }
        }
        else if (harness is null)
        {
            coverage.Gaps.Add($"{PgQueryStoreRows.Harness} couldn't be read on {Target}, so Query Store's statements weren't read: without the harness's functions, its bookkeeping would be among them. The next read tries again: {PgQueryStoreRows.Why(Target, PgQueryStoreRows.Harness, result)}");
        }
    }

    /// <summary>This observation's intervals, as read: written, and settled as far as the read surely took them.</summary>
    private void FinishCurrent(Cycle current, DateTimeOffset now)
    {
        var reader = current.Reader!;
        var read = reader.Result;
        Take(read, string.Empty, sidecar, current.Coverage, now);
        if (read.Failure is { } failure)
        {
            // Nothing settles: the next read takes the same intervals again.
            Failed(current.Coverage, read.FailedBlock ?? PgQueryStoreRows.Statistics, failure);
            return;
        }

        if (read.Through is { } newest && (through is null || newest > through))
        {
            through = newest;
        }

        // Every interval that ended PublishedAfter before this read was published, and this read took it.
        var surely = current.At - PublishedAfter;
        var reached = read.Complete ? surely : Earlier(surely, read.Through ?? reader.From);
        if (settled is null || reached > settled)
        {
            settled = reached;
            Forget(string.Empty, reached);
        }
    }

    /// <summary>A read's end: what's pending at the observer's end, the watermark, and the read's coverage row.</summary>
    private void FinishCycle(Cycle current)
    {
        current.Finished = true;
        if (cycle == current)
        {
            cycle = null;
        }

        var coverage = current.Coverage;
        coverage.Settings = settings;
        coverage.Sources.UnionWith(carriedSources);
        coverage.Gaps.AddRange(carriedGaps);
        carriedSources.Clear();
        carriedGaps.Clear();

        // Query Store off, or a server in recovery, publishes nothing later: nothing is pending then.
        var recording = settings is null || (settings.InRecovery != true && !string.Equals(settings.CaptureMode, "none", StringComparison.Ordinal));
        var unsettled = settled ?? schedule.FirstSince(observingSince);
        if (current.Final && recording)
        {
            // What Query Store hadn't published: after the newest interval it showed, or what's unsettled if that's later.
            var pending = through is { } shown && shown > unsettled ? shown : unsettled;
            if (pending < current.At)
            {
                coverage.Pending = (pending, current.At);
                coverage.Gaps.Add(PgQueryStoreRows.PendingGap(Target, pending, current.At));
            }
        }

        Record(current.At, unsettled, current.Final, recording, coverage);
        sidecar.Write(PgQueryStoreRows.Coverage(Target, coverage));
        lastRead = current.At;
    }

    /// <summary>Drops a read that didn't finish: what it had read waits for a later read, and its gaps for the next coverage row.</summary>
    private void Abandon(Cycle current)
    {
        current.Finished = true;
        if (cycle == current)
        {
            cycle = null;
        }

        carriedSources.UnionWith(current.Coverage.Sources);
        carriedGaps.AddRange(current.Coverage.Gaps);
    }

    /// <summary>Ends the end's read where it is: the range under way keeps what it read, and the rest is a gap.</summary>
    private void Cut(Cycle current, DateTimeOffset now, string why)
    {
        if (current.Finished)
        {
            return;
        }

        if (current.Phase == Phase.Current && current.Reader is { } reader)
        {
            if (!reader.Done)
            {
                reader.Fail(new CaptureException(CaptureFailureKind.Timeout, why));
            }

            FinishCurrent(current, now);
            current.Reader = null;
        }
        else
        {
            current.Coverage.Gaps.Add(why);
        }

        current.Phase = Phase.Done;
        FinishCycle(current);
    }

    /// <summary>Earlier observations' unsettled time, oldest first, at most <see cref="BackfillsPerRead"/> ranges.</summary>
    private Queue<PendingRange> PendingRanges(Cycle current)
    {
        var currentSpan = source.Spans?.CurrentSpan;
        try
        {
            return new Queue<PendingRange>(source.Watermark.Read().Pending
                .Where(p => !(string.Equals(p.SpanId, currentSpan, StringComparison.Ordinal) && p.ObservedFromUtc == observingSince))
                .OrderBy(p => p.FromUtc)
                .Take(BackfillsPerRead));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            current.Coverage.Gaps.Add($"The Query Store watermark couldn't be read on this host, so no earlier session's pending time was read: {Redactor.Redact(ex.Message)}");
            return new Queue<PendingRange>();
        }
    }

    /// <summary>
    /// Starts reading an earlier range again into the sidecar of the span it belongs to (backfill true), until the interval
    /// that holds its end has surely been published and a read took it then; a range older than Query Store's retention
    /// expires as a gap that says so, and one whose span the store no longer has is dropped.
    /// </summary>
    private void StartBackfill(Cycle current, PendingRange range, DateTimeOffset now)
    {
        var key = range.SpanId + "|" + range.ObservedFromUtc.UtcTicks.ToString(CultureInfo.InvariantCulture);
        if (source.Spans!.ForSpan(range.SpanId) is not { } sink)
        {
            log.Info("rca.querystore-forgotten", "An earlier span's pending Query Store time can't be backfilled: the store no longer has the span.", ("target", Target), ("span", range.SpanId));
            Remove(range, key);
            return;
        }

        // A range whose observer never ended (its process is gone) ends one interval after it was last recorded.
        var to = range.ToUtc ?? Earlier(now, range.RecordedUtc + schedule.Interval);
        var coverage = new QueryCoverage(range.FromUtc, to) { Settings = settings, Backfill = true };
        coverage.Sources.UnionWith(current.Coverage.Sources);
        var retention = settings?.Retention ?? PgQueryStoreSettings.DefaultRetention;
        var kept = now - retention;
        if (to <= kept)
        {
            coverage.Gaps.Add(Expired(range.FromUtc, to, retention));
            sink.Write(PgQueryStoreRows.Coverage(Target, coverage));
            Remove(range, key);
            return;
        }

        var from = range.FromUtc;
        if (from < kept)
        {
            coverage.Gaps.Add(Expired(from, kept, retention));
            from = kept;
        }

        current.Backfill = new BackfillRead(range, key, sink, coverage, to);
        current.Reader = new PgQueryStoreReader(source.Database, from, to, harness!);
    }

    /// <summary>An earlier range's read, into its span's sidecar; false when it failed with nothing read, which ends this read's backfill.</summary>
    private bool FinishBackfill(Cycle current, DateTimeOffset now)
    {
        var (range, key, sink, coverage, to) = current.Backfill!;
        var reader = current.Reader!;
        var read = reader.Result;
        current.Backfill = null;
        if (read.Failure is { } failure && read.Statistics.Count == 0)
        {
            current.Coverage.Gaps.Add($"Reading an earlier session's pending time failed on {Target}'s azure_sys; the next read tries again: {failure.Message}");
            return false;
        }

        Take(read, key, sink, coverage, now);
        if (read.Failure is { } partial)
        {
            Failed(coverage, read.FailedBlock ?? PgQueryStoreRows.Statistics, partial);
        }

        // T4's start as this read found it, against the range's (rca/README.md, A stop in the window). T4 started since the
        // range was recorded, so the range splits at that start: before it, what Query Store held in memory at the stop
        // shows by now or never will, so what this read doesn't show of it is lost, never pending; from it on, T4's new
        // lifetime recorded it, so it waits for publication as any range does. Neither part is decided until an interval
        // and the publication delay have passed after the start too, in case Query Store publishes a stopped window late
        // (the live check L0a). A range with a recorded start waits while this read couldn't read T4's.
        var started = current.ServerStarted;
        DateTimeOffset? restart = started is { } start && range.ServerStartedUtc is { } before && start > before ? start : null;
        var settledAt = (restart is { } after && after > to ? after : to) + schedule.Interval + PublishedAfter;
        var done = read.Failure is null && read.Complete && (started is not null || range.ServerStartedUtc is null) && now >= settledAt;
        var shown = read.Through is { } reached && reached > reader.From ? reached : reader.From;
        var lostUntil = restart is { } stop && stop < to ? stop : to;
        if (done && restart is not null && shown < lostUntil)
        {
            coverage.Gaps.Add(Lost(shown, lostUntil));
        }
        else if (!done && shown < to)
        {
            coverage.Pending = (shown, to);
            coverage.Gaps.Add(PgQueryStoreRows.PendingGap(Target, shown, to));
        }

        sink.Write(PgQueryStoreRows.Coverage(Target, coverage));
        if (done)
        {
            Remove(range, key);
        }

        return true;
    }
    /// <summary>
    /// Writes a read's statistics and waits to <paramref name="sink"/>: a row it wrote before for the same interval only
    /// when it changed, since a later read of an interval holds the same counts or more. The coverage takes every row read.
    /// </summary>
    private void Take(PgQueryStoreRead read, string key, ISidecarSink sink, QueryCoverage coverage, DateTimeOffset now)
    {
        if (!written.TryGetValue(key, out var seen))
        {
            written[key] = seen = new Dictionary<string, Written>(StringComparer.Ordinal);
        }

        var period = settings?.HistoryPeriod;
        foreach (var row in read.Statistics)
        {
            if (PgQueryStoreRows.Stats(Target, row, now, period) is not { } stats)
            {
                continue;
            }

            var end = (DateTimeOffset)stats.Get("interval_end_utc")!;
            coverage.Took((DateTimeOffset)stats.Get("interval_start_utc")!, end);
            coverage.Sources.Add(PgQueryStoreRows.Statistics);
            var id = Key("s", stats, plan: true);
            var signature = Signature(stats, StatsColumns);
            if (!seen.TryGetValue(id, out var before) || !string.Equals(before.Signature, signature, StringComparison.Ordinal))
            {
                sink.Write(stats);
                seen[id] = new Written(end, signature);
            }
        }

        var waits = read.Waits.Select(w => PgQueryStoreRows.Wait(Target, w, now, period)).OfType<CaptureRow>().ToList();
        foreach (var group in waits.GroupBy(w => Key("w", w, plan: false), StringComparer.Ordinal))
        {
            coverage.Sources.Add(PgQueryStoreRows.Waits);
            var rows = group.OrderBy(w => (string?)w.Get("wait_category"), StringComparer.Ordinal).ThenBy(w => (string?)w.Get("wait_event"), StringComparer.Ordinal).ToList();
            var signature = string.Join('\n', rows.Select(w => Signature(w, WaitColumns)));
            if (!seen.TryGetValue(group.Key, out var before) || !string.Equals(before.Signature, signature, StringComparison.Ordinal))
            {
                foreach (var row in rows)
                {
                    sink.Write(row);
                }

                seen[group.Key] = new Written((DateTimeOffset)rows[0].Get("interval_end_utc")!, signature);
            }
        }
    }

    /// <summary>Forgets what was written of the intervals that settled: no read takes them again.</summary>
    private void Forget(string key, DateTimeOffset settledBy)
    {
        if (written.TryGetValue(key, out var seen))
        {
            foreach (var id in seen.Where(s => s.Value.End <= settledBy).Select(s => s.Key).ToList())
            {
                seen.Remove(id);
            }
        }
    }

    /// <summary>Keeps this observation's unsettled time in the watermark: open while it runs, closed at its end.</summary>
    private void Record(DateTimeOffset now, DateTimeOffset unsettled, bool final, bool recording, QueryCoverage coverage)
    {
        var span = source.Spans?.CurrentSpan;
        try
        {
            source.Watermark.Update(state =>
            {
                if (through is { } newest && (state.ThroughUtc is null || newest > state.ThroughUtc))
                {
                    state.ThroughUtc = newest;
                }

                // T4's start as of this read, with the state and the range: a later backfill compares it with T4's then.
                var started = settings?.ServerStarted;
                if (started is not null)
                {
                    state.ServerStartedUtc = started;
                }

                if (span is null)
                {
                    return;
                }

                var mine = state.Pending.Find(p => string.Equals(p.SpanId, span, StringComparison.Ordinal) && p.ObservedFromUtc == observingSince);
                if (!recording || unsettled >= now)
                {
                    if (mine is not null)
                    {
                        state.Pending.Remove(mine);
                    }

                    return;
                }

                if (mine is null)
                {
                    mine = new PendingRange { SpanId = span, ObservedFromUtc = observingSince };
                    state.Pending.Add(mine);
                }

                mine.FromUtc = unsettled;
                mine.ToUtc = final ? now : null;
                mine.RecordedUtc = now;
                mine.ServerStartedUtc = started ?? mine.ServerStartedUtc;
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            coverage.Gaps.Add($"The Query Store watermark couldn't be written on this host, so the time still pending isn't kept for a later read: {Redactor.Redact(ex.Message)}");
            log.Warn("rca.querystore-watermark", "The Query Store watermark couldn't be written.", ("target", Target), ("error", Redactor.Redact(ex.Message)));
        }
    }

    /// <summary>Removes an earlier range from the watermark, and what was written of it.</summary>
    private void Remove(PendingRange range, string key)
    {
        written.Remove(key);
        try
        {
            source.Watermark.Update(state => state.Pending.RemoveAll(p => string.Equals(p.SpanId, range.SpanId, StringComparison.Ordinal) && p.ObservedFromUtc == range.ObservedFromUtc));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warn("rca.querystore-watermark", "The Query Store watermark couldn't be written.", ("target", Target), ("error", Redactor.Redact(ex.Message)));
        }
    }

    private void Failed(QueryCoverage coverage, string block, CaptureException failure)
    {
        var text = failure.Kind switch
        {
            CaptureFailureKind.Permission => $"{block} was refused a permission on {Target}'s azure_sys, so Query Store's statements weren't read: {failure.Message} The public role reads query_store's views (Learn); ./scripts/deploy.ps1 sets T4's runner role up again.",
            CaptureFailureKind.Connection => $"{Target}'s azure_sys didn't answer {block}, so the next read takes its intervals: {failure.Message}",
            CaptureFailureKind.Timeout => $"{block} timed out on {Target}'s azure_sys, so the next read takes its intervals: {failure.Message}",
            _ => $"{block} failed on {Target}'s azure_sys: {failure.Message}",
        };
        coverage.Gaps.Add(text);
        log.Warn("rca.querystore", text, ("target", Target));
    }

    private string Expired(DateTimeOffset from, DateTimeOffset to, TimeSpan retention) =>
        string.Create(CultureInfo.InvariantCulture, $"Pending publication expired: {Target}'s Query Store keeps {retention.TotalDays:0} days, so {from:yyyy-MM-dd HH:mm} to {to:yyyy-MM-dd HH:mm} UTC can't be read any more.");

    private string Lost(DateTimeOffset from, DateTimeOffset to) =>
        string.Create(CultureInfo.InvariantCulture, $"Lost when {Target} stopped: Query Store shows nothing of {from:yyyy-MM-dd HH:mm} to {to:yyyy-MM-dd HH:mm} UTC, which it still held in memory when {Target} stopped, and {Target} has started again since, so none of it will show.");

    /// <summary>What was written of one row or wait group: its interval's end, and its values.</summary>
    private sealed record Written(DateTimeOffset End, string Signature);

    /// <summary>An earlier range under way: where its rows and coverage go, and where it ends.</summary>
    private sealed record BackfillRead(PendingRange Range, string Key, ISidecarSink Sink, QueryCoverage Coverage, DateTimeOffset To);

    /// <summary>One read: its time (its intervals end by it), how far it got, and its coverage row.</summary>
    private sealed class Cycle(DateTimeOffset at, bool final, DateTimeOffset windowStart)
    {
        public DateTimeOffset At { get; } = at;

        public bool Final { get; } = final;

        public QueryCoverage Coverage { get; } = new(windowStart, at);

        public Phase Phase { get; set; } = Phase.Settings;

        public Queue<PendingRange>? Ranges { get; set; }

        /// <summary>T4's start, as this read's RCA-PG-13 found it; null when it couldn't read it.</summary>
        public DateTimeOffset? ServerStarted { get; set; }

        public BackfillRead? Backfill { get; set; }

        public PgQueryStoreReader? Reader { get; set; }

        public bool Finished { get; set; }
    }
}
