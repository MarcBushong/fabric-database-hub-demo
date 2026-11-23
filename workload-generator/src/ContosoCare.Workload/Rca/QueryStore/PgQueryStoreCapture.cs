using System.Globalization;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>Where T4's Query Store is read from, and where its unread time is kept: the observer's wiring.</summary>
/// <param name="QueryStore">Connections to T4's azure_sys (<see cref="PgCaptureConnector.QueryStore"/>), one per read.</param>
/// <param name="Watermark">The unread-interval watermark, in the evidence store's folder.</param>
/// <param name="Spans">The span store's side of a backfill; without it, nothing is recorded as pending or backfilled.</param>
/// <param name="Schedule">When to read; the interval Query Store reports replaces its interval.</param>
/// <param name="Database">The database whose statements are read.</param>
internal sealed record PgQueryStoreSource(ICaptureConnector QueryStore, QueryWatermark Watermark, ISidecarSpans? Spans = null, QueryStoreSchedule? Schedule = null, string Database = PgEndpoint.DatabaseName);

/// <summary>
/// T4's Query Store in the sidecar (rca/README.md, Query Store and Pending publication), for the PostgreSQL observer. Each
/// read takes Query Store's settings (RCA-PG-13) and the harness (RCA-PG-16) on the observer's own connection, then, on a
/// connection to azure_sys of its own, earlier spans' pending time (the backfill) and the intervals published since the
/// last read (RCA-PG-14 and 15): the 2 hours before the observer's start first, then every 15 minutes, and at its end. The
/// time Query Store hadn't published is kept in the watermark for this span, and the coverage says it's pending
/// publication, never that it wasn't captured. Without the harness's list, nothing is read: its bookkeeping would be in it.
/// Every failure is a gap in RCA Query Coverage; none reaches the evidence document or the observer's own connection.
/// </summary>
internal sealed class PgQueryStoreCapture(string target, PgQueryStoreSource source, ISidecarSink sidecar, ObserverOptions options, RunnerLog log)
{
    /// <summary>
    /// How long after an interval ends Query Store has surely published it: Learn allows "up to 20 minutes for the first
    /// batch of data to persist" (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store).
    /// </summary>
    public static readonly TimeSpan PublishedAfter = TimeSpan.FromMinutes(20);

    /// <summary>At most this many earlier ranges are backfilled in one read, so a read stays short.</summary>
    public const int BackfillsPerRead = 4;

    private QueryStoreSchedule schedule = source.Schedule ?? QueryStoreSchedule.Default;
    private DateTimeOffset observingSince;
    private DateTimeOffset lastRead;
    private DateTimeOffset? through;
    private PgQueryStoreSettings? settings;
    private PgHarness? harness;

    /// <summary>Runs a catalog block on the observer's own connection, untimed; null when it failed (the observer noted why).</summary>
    public delegate Task<IReadOnlyList<CaptureValues>?> BlockRunner(string blockId, CancellationToken cancellationToken);

    /// <summary>When the next read is due: at the observer's start, then 2 minutes after each interval ends.</summary>
    public DateTimeOffset NextRead { get; private set; } = DateTimeOffset.MaxValue;

    /// <summary>The end of the newest interval this observation read, statistics and waits both.</summary>
    public DateTimeOffset? Through => through;

    public void Begin(DateTimeOffset now)
    {
        schedule = source.Schedule ?? QueryStoreSchedule.Default;
        observingSince = now;
        lastRead = now;
        through = null;
        settings = null;
        harness = null;
        NextRead = now;
    }

    /// <summary>A read on the schedule: earlier spans' pending time first, then the intervals published since the last read.</summary>
    public Task ReadAsync(DateTimeOffset now, BlockRunner run, CancellationToken cancellationToken) => ReadCoreAsync(now, run, final: false, cancellationToken);

    /// <summary>The last read, at the observer's end: what's published, and the rest recorded as pending publication.</summary>
    public Task EndAsync(DateTimeOffset now, BlockRunner run, CancellationToken cancellationToken) => ReadCoreAsync(now, run, final: true, cancellationToken);

    private async Task ReadCoreAsync(DateTimeOffset now, BlockRunner run, bool final, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(run);

        // Due again on the schedule whatever happens below, so a read that fails isn't repeated at every tick.
        NextRead = final ? DateTimeOffset.MaxValue : schedule.NextRead(now);
        var coverage = new QueryCoverage(lastRead, now);
        var settingsRows = await run(PgQueryStoreRows.Settings, cancellationToken).ConfigureAwait(false);
        if (settingsRows is null)
        {
            coverage.Gaps.Add(string.Create(CultureInfo.InvariantCulture, $"{PgQueryStoreRows.Settings} couldn't be read on {target} at {now:HH:mm} UTC, so Query Store's settings are as last read; RCA Coverage's gaps say why."));
        }
        else
        {
            var current = PgQueryStoreSettings.Parse(settingsRows, now);
            if (settingsRows.Count > 0)
            {
                coverage.Sources.Add(PgQueryStoreRows.Settings);
            }

            if (settings is { } previous && PgQueryStoreRows.StateChange(target, previous, current) is { } change)
            {
                sidecar.Write(change);
            }

            settings = current;
            coverage.Gaps.AddRange(current.Gaps(target));
            if (current.Interval is { } interval && interval != schedule.Interval)
            {
                schedule = schedule.WithInterval(interval);
                NextRead = final ? DateTimeOffset.MaxValue : schedule.NextRead(now);
            }
        }

        coverage.Settings = settings;
        var harnessRows = await run(PgQueryStoreRows.Harness, cancellationToken).ConfigureAwait(false);
        if (harnessRows is not null)
        {
            harness = PgHarness.Parse(harnessRows);
            if (harnessRows.Count > 0)
            {
                coverage.Sources.Add(PgQueryStoreRows.Harness);
            }

            if (harness.Functions.Count == 0)
            {
                coverage.Gaps.Add($"No function in {source.Database} is marked as the harness's (dbhubdemo:harness), so nothing is left out as the harness's.");
            }
        }
        else if (harness is null)
        {
            coverage.Gaps.Add($"{PgQueryStoreRows.Harness} couldn't be read on {target}, so Query Store's statements weren't read: without the harness's functions, its bookkeeping would be among them. The next read tries again.");
        }

        if (harness is { } leaveOut && settings?.InRecovery != true)
        {
            await ReadStoreAsync(now, final, leaveOut, coverage, cancellationToken).ConfigureAwait(false);
        }

        // Query Store off, or a server in recovery, publishes nothing later: nothing is pending then.
        var recording = settings is null || (settings.InRecovery != true && !string.Equals(settings.CaptureMode, "none", StringComparison.Ordinal));
        var unreadFrom = through ?? schedule.FirstSince(observingSince);
        if (final && recording && unreadFrom < now)
        {
            coverage.Pending = (unreadFrom, now);
            coverage.Gaps.Add(PgQueryStoreRows.PendingGap(target, unreadFrom, now));
        }

        Record(now, unreadFrom, final, recording, coverage);
        sidecar.Write(PgQueryStoreRows.Coverage(target, coverage));
        lastRead = now;
    }

    /// <summary>The reads on azure_sys: the backfill (except at the end), then this observation's own intervals.</summary>
    private async Task ReadStoreAsync(DateTimeOffset now, bool final, PgHarness leaveOut, QueryCoverage coverage, CancellationToken cancellationToken)
    {
        ICaptureConnection connection;
        try
        {
            connection = await source.QueryStore.OpenAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (CaptureException ex)
        {
            Failed(coverage, PgQueryStoreRows.Statistics, ex);
            return;
        }

        await using (connection.ConfigureAwait(false))
        {
            if (!final && source.Spans is { } spans)
            {
                await BackfillAsync(connection, spans, now, leaveOut, coverage, cancellationToken).ConfigureAwait(false);
            }

            var since = through ?? schedule.FirstSince(observingSince);
            var read = await PgQueryStoreReader.ReadAsync(connection, source.Database, since, now, leaveOut, options.LongStatementTimeout, cancellationToken).ConfigureAwait(false);
            Take(read, sidecar, coverage, now);
            if (read.Failure is { } failure)
            {
                Failed(coverage, read.FailedBlock ?? PgQueryStoreRows.Statistics, failure);
            }

            if (read.Through is { } newest && (through is null || newest > through))
            {
                through = newest;
            }
        }
    }

    /// <summary>
    /// Earlier observations' pending time, oldest first: read now that Query Store published it, into the sidecar of the
    /// span it belongs to (backfill true). A range is done once a read reaches its end, or the interval that holds its end
    /// has surely been published; one older than Query Store's retention expires as a gap that says so.
    /// </summary>
    private async Task BackfillAsync(ICaptureConnection connection, ISidecarSpans spans, DateTimeOffset now, PgHarness leaveOut, QueryCoverage current, CancellationToken cancellationToken)
    {
        var currentSpan = spans.CurrentSpan;
        List<PendingRange> ranges;
        try
        {
            ranges = [.. source.Watermark.Read().Pending
                .Where(p => !(string.Equals(p.SpanId, currentSpan, StringComparison.Ordinal) && p.ObservedFromUtc == observingSince))
                .OrderBy(p => p.FromUtc)
                .Take(BackfillsPerRead)];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            current.Gaps.Add($"The Query Store watermark couldn't be read on this host, so no earlier session's pending time was read: {Redactor.Redact(ex.Message)}");
            return;
        }

        var retention = settings?.Retention ?? PgQueryStoreSettings.DefaultRetention;
        var kept = now - retention;
        foreach (var range in ranges)
        {
            var sink = spans.ForSpan(range.SpanId);
            if (sink is null)
            {
                log.Info("rca.querystore-forgotten", "An earlier span's pending Query Store time can't be backfilled: the store no longer has the span.", ("target", target), ("span", range.SpanId));
                Settle(range, remove: true, from: null);
                continue;
            }

            // A range whose observer never ended (its process is gone) ends one interval after it was last recorded.
            var to = range.ToUtc ?? Earlier(now, range.RecordedUtc + schedule.Interval);
            var coverage = new QueryCoverage(range.FromUtc, to) { Settings = settings, Backfill = true };
            coverage.Sources.UnionWith(current.Sources);
            if (to <= kept)
            {
                coverage.Gaps.Add(Expired(range.FromUtc, to, retention));
                sink.Write(PgQueryStoreRows.Coverage(target, coverage));
                Settle(range, remove: true, from: null);
                continue;
            }

            var from = range.FromUtc;
            if (from < kept)
            {
                coverage.Gaps.Add(Expired(from, kept, retention));
                from = kept;
            }

            var read = await PgQueryStoreReader.ReadAsync(connection, source.Database, from, to, leaveOut, options.LongStatementTimeout, cancellationToken).ConfigureAwait(false);
            if (read.Failure is { } failure && read.Statistics.Count == 0)
            {
                current.Gaps.Add($"Reading an earlier session's pending time failed on {target}'s azure_sys; the next read tries again: {failure.Message}");
                return;
            }

            Take(read, sink, coverage, now);
            var newest = read.Through is { } reached && reached > from ? reached : from;
            var complete = read.Failure is null && (newest >= to || now >= to + schedule.Interval + PublishedAfter);
            if (read.Failure is { } partial)
            {
                Failed(coverage, read.FailedBlock ?? PgQueryStoreRows.Statistics, partial);
            }

            if (!complete)
            {
                coverage.Pending = (newest, to);
                coverage.Gaps.Add(PgQueryStoreRows.PendingGap(target, newest, to));
            }

            sink.Write(PgQueryStoreRows.Coverage(target, coverage));
            Settle(range, remove: complete, from: newest);
        }
    }

    /// <summary>Writes a read's statistics and waits to <paramref name="sink"/>, and what they covered.</summary>
    private void Take(PgQueryStoreRead read, ISidecarSink sink, QueryCoverage coverage, DateTimeOffset now)
    {
        var period = settings?.HistoryPeriod;
        foreach (var row in read.Statistics)
        {
            if (PgQueryStoreRows.Stats(target, row, now, period) is { } stats)
            {
                sink.Write(stats);
                coverage.Took((DateTimeOffset)stats.Get("interval_start_utc")!, (DateTimeOffset)stats.Get("interval_end_utc")!);
                coverage.Sources.Add(PgQueryStoreRows.Statistics);
            }
        }

        foreach (var row in read.Waits)
        {
            if (PgQueryStoreRows.Wait(target, row, now, period) is { } wait)
            {
                sink.Write(wait);
                coverage.Sources.Add(PgQueryStoreRows.Waits);
            }
        }
    }

    /// <summary>Keeps this observation's unread time in the watermark: open while it runs, closed at its end.</summary>
    private void Record(DateTimeOffset now, DateTimeOffset unreadFrom, bool final, bool recording, QueryCoverage coverage)
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

                if (span is null)
                {
                    return;
                }

                var mine = state.Pending.Find(p => string.Equals(p.SpanId, span, StringComparison.Ordinal) && p.ObservedFromUtc == observingSince);
                if (!recording || unreadFrom >= now)
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

                mine.FromUtc = unreadFrom;
                mine.ToUtc = final ? now : null;
                mine.RecordedUtc = now;
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            coverage.Gaps.Add($"The Query Store watermark couldn't be written on this host, so the time still pending isn't kept for a later read: {Redactor.Redact(ex.Message)}");
            log.Warn("rca.querystore-watermark", "The Query Store watermark couldn't be written.", ("target", target), ("error", Redactor.Redact(ex.Message)));
        }
    }

    /// <summary>Removes an earlier range, or moves its start on to what was read.</summary>
    private void Settle(PendingRange range, bool remove, DateTimeOffset? from)
    {
        try
        {
            source.Watermark.Update(state =>
            {
                var stored = state.Pending.Find(p => string.Equals(p.SpanId, range.SpanId, StringComparison.Ordinal) && p.ObservedFromUtc == range.ObservedFromUtc);
                if (stored is null)
                {
                    return;
                }

                if (remove)
                {
                    state.Pending.Remove(stored);
                }
                else if (from is { } start && start > stored.FromUtc)
                {
                    stored.FromUtc = start;
                }
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warn("rca.querystore-watermark", "The Query Store watermark couldn't be written.", ("target", target), ("error", Redactor.Redact(ex.Message)));
        }
    }

    private void Failed(QueryCoverage coverage, string block, CaptureException failure)
    {
        var text = failure.Kind switch
        {
            CaptureFailureKind.Permission => $"{block} was refused a permission on {target}'s azure_sys, so Query Store's statements weren't read: {failure.Message} The public role reads query_store's views (Learn); ./scripts/deploy.ps1 sets T4's runner role up again.",
            CaptureFailureKind.Connection => $"{target}'s azure_sys didn't answer {block}, so the next read takes its intervals: {failure.Message}",
            CaptureFailureKind.Timeout => $"{block} timed out on {target}'s azure_sys, so the next read takes its intervals: {failure.Message}",
            _ => $"{block} failed on {target}'s azure_sys: {failure.Message}",
        };
        coverage.Gaps.Add(text);
        log.Warn("rca.querystore", text, ("target", target));
    }

    private string Expired(DateTimeOffset from, DateTimeOffset to, TimeSpan retention) =>
        string.Create(CultureInfo.InvariantCulture, $"Pending publication expired: {target}'s Query Store keeps {retention.TotalDays:0} days, so {from:yyyy-MM-dd HH:mm} to {to:yyyy-MM-dd HH:mm} UTC can't be read any more.");

    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;
}
