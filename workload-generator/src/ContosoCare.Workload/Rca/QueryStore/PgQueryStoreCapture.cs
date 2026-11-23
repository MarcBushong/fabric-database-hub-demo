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
/// connection to azure_sys of its own, earlier spans' unsettled time (the backfill) and this observation's intervals
/// (RCA-PG-14 and 15): the 2 hours before the observer's start first, then every 15 minutes, and at its end.
/// <para>
/// An interval is settled once a read took it at least <see cref="PublishedAfter"/> after it ended, when Query Store has
/// surely published all of it. Until then each read takes it again, and writes its rows again only when they changed, so
/// counts or waits that Query Store published late still reach the sidecar (the latest read of an interval wins). The time
/// still unsettled at the observer's end is kept in the watermark for this span, and the coverage says what Query Store
/// hadn't published yet, never that it wasn't captured.
/// </para>
/// Without the harness's list, nothing is read: its bookkeeping would be in it. Every failure is a gap in RCA Query
/// Coverage; none reaches the evidence document or the observer's own connection.
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

    private static readonly string[] StatsColumns = ["login_name", "statement_text", "executions", "duration_ms", "max_duration_ms", "logical_reads", "physical_reads", "row_count", "tempdb_kb", "wait_ms"];

    private static readonly string[] WaitColumns = ["wait_category", "wait_event", "samples", "wait_ms"];

    // What was written of each unsettled interval, by sink (this observation's, or an earlier range's): a row is written
    // again only when a later read found it changed.
    private readonly Dictionary<string, Dictionary<string, Written>> written = new(StringComparer.Ordinal);
    private QueryStoreSchedule schedule = source.Schedule ?? QueryStoreSchedule.Default;
    private DateTimeOffset observingSince;
    private DateTimeOffset lastRead;
    private DateTimeOffset? through;
    private DateTimeOffset? settled;
    private PgQueryStoreSettings? settings;
    private PgHarness? harness;

    /// <summary>Runs a catalog block on the observer's own connection, untimed; null when it failed (the observer noted why).</summary>
    public delegate Task<IReadOnlyList<CaptureValues>?> BlockRunner(string blockId, CancellationToken cancellationToken);

    /// <summary>When the next read is due: at the observer's start, then 2 minutes after each interval ends.</summary>
    public DateTimeOffset NextRead { get; private set; } = DateTimeOffset.MaxValue;

    /// <summary>The end of the newest interval this observation's reads found published.</summary>
    public DateTimeOffset? Through => through;

    /// <summary>Every interval that ends by this time is settled: a read took it once Query Store had surely published it.</summary>
    public DateTimeOffset? Settled => settled;

    public void Begin(DateTimeOffset now)
    {
        schedule = source.Schedule ?? QueryStoreSchedule.Default;
        observingSince = now;
        lastRead = now;
        through = null;
        settled = null;
        settings = null;
        harness = null;
        written.Clear();
        NextRead = now;
    }

    /// <summary>A read on the schedule: earlier spans' unsettled time first, then this observation's.</summary>
    public Task ReadAsync(DateTimeOffset now, BlockRunner run, CancellationToken cancellationToken) => ReadCoreAsync(now, run, final: false, cancellationToken);

    /// <summary>The last read, at the observer's end: what's published, and the rest kept as unsettled for a later read.</summary>
    public Task EndAsync(DateTimeOffset now, BlockRunner run, CancellationToken cancellationToken) => ReadCoreAsync(now, run, final: true, cancellationToken);

    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;

    /// <summary>A row's key within its sink: its kind, interval, role, query, and plan.</summary>
    private static string Key(string kind, CaptureRow row, bool plan) => string.Create(
        CultureInfo.InvariantCulture,
        $"{kind}|{((DateTimeOffset)row.Get("interval_start_utc")!).UtcTicks}|{row.Get("login_name")}|{row.Get("query_id")}|{(plan ? row.Get("plan_id") : null)}");

    private static string Signature(CaptureRow row, string[] columns) =>
        string.Join('|', columns.Select(c => row.Get(c) is { } value ? "v" + Convert.ToString(value, CultureInfo.InvariantCulture) : "n"));

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

            if (harness.UnsureGap(source.Database) is { } unsure)
            {
                coverage.Gaps.Add(unsure);
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
        var unsettled = settled ?? schedule.FirstSince(observingSince);
        if (final && recording)
        {
            // What Query Store hadn't published: after the newest interval it showed, or what's unsettled if that's later.
            var pending = through is { } shown && shown > unsettled ? shown : unsettled;
            if (pending < now)
            {
                coverage.Pending = (pending, now);
                coverage.Gaps.Add(PgQueryStoreRows.PendingGap(target, pending, now));
            }
        }

        Record(now, unsettled, final, recording, coverage);
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

            var since = settled ?? schedule.FirstSince(observingSince);
            var read = await PgQueryStoreReader.ReadAsync(connection, source.Database, since, now, leaveOut, options.LongStatementTimeout, cancellationToken).ConfigureAwait(false);
            Take(read, string.Empty, sidecar, coverage, now);
            if (read.Failure is { } failure)
            {
                // Nothing settles: the next read takes the same intervals again.
                Failed(coverage, read.FailedBlock ?? PgQueryStoreRows.Statistics, failure);
                return;
            }

            if (read.Through is { } newest && (through is null || newest > through))
            {
                through = newest;
            }

            // Every interval that ended PublishedAfter before this read was published, and this read took it.
            var surely = now - PublishedAfter;
            var reached = read.Complete ? surely : Earlier(surely, read.Through ?? since);
            if (settled is null || reached > settled)
            {
                settled = reached;
                Forget(string.Empty, reached);
            }
        }
    }

    /// <summary>
    /// Earlier observations' unsettled time, oldest first: read again into the sidecar of the span it belongs to (backfill
    /// true), until the interval that holds its end has surely been published and a read took it then. A range older than
    /// Query Store's retention expires as a gap that says so.
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
            var key = range.SpanId + "|" + range.ObservedFromUtc.UtcTicks.ToString(CultureInfo.InvariantCulture);
            var sink = spans.ForSpan(range.SpanId);
            if (sink is null)
            {
                log.Info("rca.querystore-forgotten", "An earlier span's pending Query Store time can't be backfilled: the store no longer has the span.", ("target", target), ("span", range.SpanId));
                Remove(range, key);
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
                Remove(range, key);
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

            Take(read, key, sink, coverage, now);
            if (read.Failure is { } partial)
            {
                Failed(coverage, read.FailedBlock ?? PgQueryStoreRows.Statistics, partial);
            }

            var done = read.Failure is null && read.Complete && now >= to + schedule.Interval + PublishedAfter;
            var shown = read.Through is { } reached && reached > from ? reached : from;
            if (!done && shown < to)
            {
                coverage.Pending = (shown, to);
                coverage.Gaps.Add(PgQueryStoreRows.PendingGap(target, shown, to));
            }

            sink.Write(PgQueryStoreRows.Coverage(target, coverage));
            if (done)
            {
                Remove(range, key);
            }
        }
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
            if (PgQueryStoreRows.Stats(target, row, now, period) is not { } stats)
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

        var waits = read.Waits.Select(w => PgQueryStoreRows.Wait(target, w, now, period)).OfType<CaptureRow>().ToList();
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
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            coverage.Gaps.Add($"The Query Store watermark couldn't be written on this host, so the time still pending isn't kept for a later read: {Redactor.Redact(ex.Message)}");
            log.Warn("rca.querystore-watermark", "The Query Store watermark couldn't be written.", ("target", target), ("error", Redactor.Redact(ex.Message)));
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

    /// <summary>What was written of one row or wait group: its interval's end, and its values.</summary>
    private sealed record Written(DateTimeOffset End, string Signature);
}
