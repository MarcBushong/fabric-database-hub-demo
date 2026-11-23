using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.QueryStore;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// Whether the replica's replay is stalled now, and since when: its observer sets it, and T4's observer reads the
/// primary's side on the same 5-s marks then, so the two sides' rows line up.
/// </summary>
internal sealed class ReplicaLink
{
    // UTC ticks of the replay detail's start, 0 while replay isn't stalled.
    private long since;

    public bool Stalled => Interlocked.Read(ref since) != 0;

    public DateTimeOffset? StalledSince
    {
        get => Interlocked.Read(ref since) is var ticks and not 0 ? new DateTimeOffset(ticks, TimeSpan.Zero) : null;
        set => Interlocked.Exchange(ref since, value?.UtcTicks ?? 0);
    }
}

/// <summary>
/// T4 (PostgreSQL flexible server). The sentinel every 30 s for the whole session: connections by state and the clients
/// waiting on a lock (RCA-PG-10), the database's counters (RCA-PG-03), and, while it has a standby, the WAL it ships
/// (RCA-PG-04, 05). A client waiting on a lock starts blocking detail (RCA-PG-01, 02, 11 every 10 s) until 60 s
/// without a waiter; connections at 80 % of the limit start RCA-PG-10 every 10 s until 60 s under 70 %; a deadlock
/// count that rose takes one blocking sample; the replica's stalled replay reads the primary's side every 5 s.
/// With a sidecar sink and a Query Store source (rca/README.md, The sidecar), Query Store is read on its own schedule
/// (<see cref="PgQueryStoreCapture"/>), which changes nothing the evidence document captures.
/// </summary>
internal sealed class PgPrimaryObserver(ICaptureConnector connector, ObserverOptions options, RunnerLog log, ReplicaLink link, ISidecarSink? sidecar = null, PgQueryStoreSource? queryStore = null)
    : TargetObserver("T4", DemoTarget.T4, connector, options, log, "The fix: ./scripts/deploy.ps1 sets T4's runner role up again; T4's setup grants it pg_read_all_stats.")
{
    private readonly CounterDeltas deltas = new();
    private readonly PgQueryStoreCapture? queryStoreCapture = sidecar is not null && queryStore is not null ? new PgQueryStoreCapture("T4", queryStore, sidecar, options, log) : null;
    private EpisodeTrigger lockWaits = null!;
    private EpisodeTrigger connections = null!;
    private DateTimeOffset nextSentinel;
    private DateTimeOffset nextLockDetail;
    private DateTimeOffset nextConnectionDetail;
    private DateTimeOffset nextReplay;
    private DateTimeOffset? replayAnchor;
    private DateTimeOffset lastReplication;
    private double? lastWalBytes;
    private DateTimeOffset lastWalAt;

    public override async Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (now >= nextSentinel)
        {
            await SentinelAsync(now, cancellationToken).ConfigureAwait(false);
            nextSentinel = now + Every(Options.Sentinel);
        }

        var detail = !Cadence.DetailStopped;
        if (detail && lockWaits.Current is not null && now >= nextLockDetail)
        {
            await BlockingSampleAsync(now, detail: true, cancellationToken).ConfigureAwait(false);
            nextLockDetail = now + Every(Options.BlockingDetail);
        }

        if (detail && connections.Current is not null && now >= nextConnectionDetail)
        {
            var rows = await RunAsync("RCA-PG-10", now, cancellationToken).ConfigureAwait(false);
            if (rows is { Count: > 0 })
            {
                Connections(rows[0], now);
            }

            nextConnectionDetail = now + Every(Options.BlockingDetail);
        }

        if (detail && link.StalledSince is { } anchor)
        {
            if (replayAnchor != anchor)
            {
                replayAnchor = anchor;
                nextReplay = Aligned(anchor, lastReplication);
            }

            if (now >= nextReplay)
            {
                await ReplicationAsync(now, sentinel: false, cancellationToken).ConfigureAwait(false);
                nextReplay = Aligned(anchor, now);
            }
        }
        else
        {
            replayAnchor = null;
        }

        if (queryStoreCapture is { } queryStoreReads && now >= queryStoreReads.NextRead)
        {
            await SidecarAsync(() => queryStoreReads.ReadAsync(now, (block, token) => RunAsync(block, now, token, timed: false), cancellationToken)).ConfigureAwait(false);
        }

        Sink.Watermark(Target, now - Options.ClockSkew);
        return Earliest(
            nextSentinel,
            detail && lockWaits.Current is not null ? nextLockDetail : null,
            detail && connections.Current is not null ? nextConnectionDetail : null,
            replayAnchor is not null ? nextReplay : null,
            queryStoreCapture?.NextRead,
            now + Options.ReplayDetail);
    }

    protected override Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        lockWaits = new EpisodeTrigger(Ids, Options.QuietFor);
        connections = new EpisodeTrigger(Ids, Options.QuietFor);
        deltas.Clear();
        lastWalBytes = null;
        nextSentinel = now;
        nextLockDetail = now;
        nextConnectionDetail = now;
        nextReplay = now;
        replayAnchor = null;
        lastReplication = DateTimeOffset.MinValue;
        queryStoreCapture?.Begin(now);
        return Task.CompletedTask;
    }

    protected override async Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        Close(lockWaits, now);
        Close(connections, now);
        if (queryStoreCapture is { } queryStoreReads)
        {
            await SidecarAsync(() => queryStoreReads.EndAsync(now, (block, token) => RunAsync(block, now, token, timed: false), cancellationToken)).ConfigureAwait(false);
        }
    }

    private async Task SentinelAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var connectionRows = await RunAsync("RCA-PG-10", now, cancellationToken).ConfigureAwait(false);
        if (connectionRows is { Count: > 0 })
        {
            Connections(connectionRows[0], now);
        }

        var database = await RunAsync("RCA-PG-03", now, cancellationToken).ConfigureAwait(false);
        if (database is { Count: > 0 })
        {
            var at = database[0].Time("captured_at") ?? now;
            var deadlocks = DatabaseCounters(this, deltas, database[0], at);
            if (deadlocks > 0)
            {
                await DeadlockSampleAsync(at, deadlocks.Value, now, cancellationToken).ConfigureAwait(false);
            }
        }

        if (!link.Stalled)
        {
            await ReplicationAsync(now, sentinel: true, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>RCA-PG-03's counters as deltas (rca/README.md, Resource metrics); returns the deadlocks' delta.</summary>
    internal static double? DatabaseCounters(TargetObserver owner, CounterDeltas deltas, CaptureValues row, DateTimeOffset at)
    {
        double? deadlocks = null;
        foreach (var metric in new[] { "deadlocks", "conflicts", "xact_rollback", "temp_files" })
        {
            var delta = deltas.Next(metric, row.Double(metric));
            owner.Counter(at, "RCA-PG-03", metric, delta);
            if (metric == "deadlocks")
            {
                deadlocks = delta;
            }
        }

        return deadlocks;
    }

    /// <summary>
    /// One RCA-PG-10 sample, the sentinel's or the connection detail's (the same signal, more often; every one counts as
    /// the sentinel's for RCA Coverage). The next connection detail comes 10 s after the latest sample, so none repeats it.
    /// </summary>
    private void Connections(CaptureValues row, DateTimeOffset now)
    {
        const bool sentinel = true;
        var at = row.Time("captured_at") ?? now;
        var total = row.Double("client_connections") ?? 0;
        var waiting = row.Double("waiting_lock") ?? 0;
        var maximum = row.Double("max_connections");
        var reserved = row.Double("reserved_connections") ?? 0;
        Resource(at, "RCA-PG-10", "connections_total", total, "count", sentinel);
        Resource(at, "RCA-PG-10", "connections_active", row.Double("active"), "count", sentinel);
        Resource(at, "RCA-PG-10", "connections_idle", row.Double("idle"), "count", sentinel);
        Resource(at, "RCA-PG-10", "connections_idle_in_transaction", row.Double("idle_in_transaction"), "count", sentinel);
        Resource(at, "RCA-PG-10", "connections_waiting_lock", waiting, "count", sentinel);
        Resource(at, "RCA-PG-10", "max_connections", maximum, "count", sentinel);
        Resource(at, "RCA-PG-10", "reserved_connections", reserved, "count", sentinel);

        var lockChange = lockWaits.Observe(at, waiting > 0, waiting <= 0, () => string.Create(CultureInfo.InvariantCulture, $"connections_waiting_lock {waiting:0} >= 1: blocking detail (RCA-PG-01, RCA-PG-02, RCA-PG-11) every {Seconds(Every(Options.BlockingDetail))} s."));
        Report(lockWaits, lockChange, at, $"connections_waiting_lock 0 for {Duration(Options.QuietFor)}: {BackToSentinel}");
        if (lockChange == EpisodeChange.Started)
        {
            nextLockDetail = now;
        }

        if (maximum is { } max && max - reserved > 0)
        {
            var limit = max - reserved;
            var change = connections.Observe(at, total >= 0.8 * limit, total < 0.7 * limit, () => string.Create(CultureInfo.InvariantCulture, $"client connections {total:0} >= 80 % of {limit:0} (max_connections {max:0} minus {reserved:0} reserved): connection detail (RCA-PG-10) every {Seconds(Every(Options.BlockingDetail))} s."));
            Report(connections, change, at, string.Create(CultureInfo.InvariantCulture, $"client connections under 70 % of {limit:0} for {Duration(Options.QuietFor)}: {BackToSentinel}"));
        }

        nextConnectionDetail = now + Every(Options.BlockingDetail);
    }

    /// <summary>The sidecar's work, which never stops the evidence document's: a store that can't keep its rows is logged.</summary>
    private async Task SidecarAsync(Func<Task> work)
    {
        try
        {
            await work().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Warn("rca.sidecar-failed", "The sidecar couldn't keep T4's rows; the evidence document's capture goes on.", ("target", Target), ("error", Redactor.Redact(ex.Message)));
        }
    }

    /// <summary>RCA-PG-01, 02, and (in detail) 11: the chains, head blocker first.</summary>
    private async Task BlockingSampleAsync(DateTimeOffset now, bool detail, CancellationToken cancellationToken)
    {
        var activity = await RunAsync("RCA-PG-01", now, cancellationToken).ConfigureAwait(false);
        if (activity is null)
        {
            return;
        }

        var locks = await RunAsync("RCA-PG-02", now, cancellationToken).ConfigureAwait(false) ?? [];
        var heads = PgSessions.Heads(activity, locks);
        IReadOnlyList<CaptureValues> relations = [];
        if (detail && heads.Length > 0)
        {
            relations = await RunAsync("RCA-PG-11", now, cancellationToken, heads).ConfigureAwait(false) ?? [];
        }

        var at = activity.Select(r => r.Time("captured_at")).FirstOrDefault(t => t is not null) ?? now;
        foreach (var row in PgSessions.Build(Target, at, activity, locks, relations, detail ? "RCA-PG-01,RCA-PG-02,RCA-PG-11" : "RCA-PG-01,RCA-PG-02"))
        {
            Write(row);
        }

        if (detail)
        {
            var waiting = activity.Count(a => string.Equals(a.Text("backend_type"), "client backend", StringComparison.Ordinal) && string.Equals(a.Text("wait_event_type"), "Lock", StringComparison.Ordinal));
            var change = lockWaits.Observe(at, waiting > 0, waiting == 0 && locks.Count == 0, () => string.Empty, canStart: false);
            Report(lockWaits, change, at, $"connections_waiting_lock 0 for {Duration(Options.QuietFor)}: {BackToSentinel}");
        }
    }

    /// <summary>A deadlock count that rose: the count as a deadlock event, and one blocking sample (PostgreSQL's graphs are only in its log).</summary>
    private async Task DeadlockSampleAsync(DateTimeOffset at, double count, DateTimeOffset now, CancellationToken cancellationToken)
    {
        Write(new CaptureRow(RcaContract.Events, Target, at, "RCA-PG-03")
            .Set("event_time_utc", at)
            .Set("target", Target)
            .Set("kind", "deadlock")
            .Set("event_name", "pg_stat_database.deadlocks")
            .Set("event_count", (long)count)
            .Set("detail", string.Create(CultureInfo.InvariantCulture, $"{count:0} deadlock(s) in contosocare (pg_stat_database.deadlocks); PostgreSQL writes the graph only to its server log, which the observer doesn't read.")));
        var id = Ids.Next(at);
        EpisodeEvent(at, "escalated", id, string.Create(CultureInfo.InvariantCulture, $"deadlocks rose by {count:0} (RCA-PG-03): one blocking sample (RCA-PG-01, RCA-PG-02)."));
        if (!Cadence.DetailStopped)
        {
            await BlockingSampleAsync(now, detail: false, cancellationToken).ConfigureAwait(false);
        }

        EpisodeEvent(at, "relaxed", id, "One sample taken: " + BackToSentinel);
    }

    /// <summary>The first of the replay detail's marks (its start, then every replay-detail interval) after <paramref name="after"/>.</summary>
    private DateTimeOffset Aligned(DateTimeOffset anchor, DateTimeOffset after)
    {
        var every = Every(Options.ReplayDetail);
        if (after < anchor)
        {
            return anchor;
        }

        var steps = ((after - anchor).Ticks / every.Ticks) + 1;
        return anchor + TimeSpan.FromTicks(steps * every.Ticks);
    }

    /// <summary>The primary's side of replication (RCA-PG-05), with the WAL rate (RCA-PG-04) while it has a standby.</summary>
    private async Task ReplicationAsync(DateTimeOffset now, bool sentinel, CancellationToken cancellationToken)
    {
        lastReplication = now;
        var standbys = await RunAsync("RCA-PG-05", now, cancellationToken).ConfigureAwait(false);
        if (standbys is not { Count: > 0 })
        {
            return;
        }

        var wal = await RunAsync("RCA-PG-04", now, cancellationToken).ConfigureAwait(false);
        double? rate = null;
        if (wal is { Count: > 0 } && wal[0].Double("wal_bytes") is { } bytes)
        {
            var walAt = wal[0].Time("captured_at") ?? now;
            if (lastWalBytes is { } previous && bytes >= previous && walAt > lastWalAt)
            {
                rate = Math.Round((bytes - previous) / (walAt - lastWalAt).TotalSeconds, 1);
            }

            lastWalBytes = bytes;
            lastWalAt = walAt;
        }

        // One row per sample and side: the standby whose replay is furthest behind.
        var standby = standbys.OrderByDescending(s => s.Double("replay_lag_s") ?? -1).ThenByDescending(s => s.Double("replay_gap_bytes") ?? -1).First();
        var at = standby.Time("captured_at") ?? now;
        Write(new CaptureRow(RcaContract.Replica, Target, at, "RCA-PG-04,RCA-PG-05", sentinel)
            .Set("at_utc", at)
            .Set("target", Target)
            .Set("side", "primary")
            .Set("standby_name", TextNormalizer.Name(standby.Text("application_name")))
            .Set("replay_lag_s", standby.Double("replay_lag_s"))
            .Set("write_lag_s", standby.Double("write_lag_s"))
            .Set("flush_lag_s", standby.Double("flush_lag_s"))
            .Set("send_gap_bytes", standby.Double("send_gap_bytes"))
            .Set("wal_bytes_per_s", rate));
    }
}

/// <summary>
/// T4's read replica, which exists only during a session. The sentinel every 30 s: replay (RCA-PG-06, with 07 and 08)
/// and the database's counters (RCA-PG-03). Replay stalled, <c>since_last_replayed_s</c> at 30 s or more with WAL
/// received and not replayed (an idle primary alone doesn't count), starts replay detail every 5 s (RCA-PG-01, 02,
/// 06, 07, 08, and the standby settings, RCA-PG-09, once) until it's under 5 s for 3 samples. On a standby,
/// pg_blocking_pids returns nothing for the startup process, so replay's conflict comes from pg_locks. With a sidecar
/// sink, Query Store's settings (RCA-PG-13) on T4's schedule and at the end: its coverage says a replica records nothing.
/// </summary>
internal sealed class PgReplicaObserver(ICaptureConnector connector, ObserverOptions options, RunnerLog log, ReplicaLink link, ISidecarSink? sidecar = null, QueryStoreSchedule? schedule = null)
    : TargetObserver("T4-replica", DemoTarget.T4, connector, options, log, "The fix: ./scripts/deploy.ps1 sets T4's runner role up again; the replica copies T4's roles.")
{
    // RCA-PG-07's causes: a query the replica cancelled for any of them counts.
    private static readonly string[] ConflictColumns = ["confl_tablespace", "confl_lock", "confl_snapshot", "confl_bufferpin", "confl_deadlock", "confl_active_logicalslot"];

    private readonly CounterDeltas deltas = new();
    private readonly ISidecarSink? sidecarSink = sidecar;
    private readonly QueryStoreSchedule queryStoreSchedule = schedule ?? QueryStoreSchedule.Default;
    private EpisodeTrigger stall = null!;
    private ReplaySample? startSample;
    private DateTimeOffset nextSentinel;
    private DateTimeOffset nextDetail;
    private DateTimeOffset nextQueryStore;
    private DateTimeOffset lastQueryStore;
    private double? maximumDelay;
    private string? receiverStatus;

    /// <summary>The replica exists only during a session, created after it starts: its capture starts when it first answers.</summary>
    public override bool BeginsOnConnect => true;

    public override async Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (now >= nextSentinel)
        {
            await SentinelAsync(now, cancellationToken).ConfigureAwait(false);
            nextSentinel = now + Every(Options.Sentinel);
        }

        var detail = !Cadence.DetailStopped;
        if (detail && stall.Current is not null && now >= nextDetail)
        {
            await ReplayDetailAsync(now, cancellationToken).ConfigureAwait(false);
            nextDetail = now + Every(Options.ReplayDetail);
        }

        if (startSample is { } pending)
        {
            // Detail capture stopped in the meantime: the sentinel's sample is written as it is.
            WriteReplica(pending, conflict: null);
            startSample = null;
        }

        if (sidecarSink is not null && now >= nextQueryStore)
        {
            nextQueryStore = queryStoreSchedule.NextRead(now);
            await QueryStoreAsync(now, cancellationToken).ConfigureAwait(false);
        }

        link.StalledSince = detail ? stall.Current?.Start : null;
        Sink.Watermark(Target, now - Options.ClockSkew);
        return Earliest(nextSentinel, detail && stall.Current is not null ? nextDetail : null, sidecarSink is not null ? nextQueryStore : null);
    }

    protected override Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        stall = new EpisodeTrigger(Ids, quietFor: null, clearSamples: 3);
        startSample = null;
        deltas.Clear();
        maximumDelay = null;
        receiverStatus = null;
        nextSentinel = now;
        nextDetail = now;
        nextQueryStore = now;
        lastQueryStore = now;
        return Task.CompletedTask;
    }

    protected override async Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        Close(stall, now);
        link.StalledSince = null;
        if (sidecarSink is not null)
        {
            await QueryStoreAsync(now, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>RCA-PG-13 on the replica, untimed: its RCA Query Coverage row, which says a replica records nothing in Query Store.</summary>
    private async Task QueryStoreAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var rows = await RunAsync(PgQueryStoreRows.Settings, now, cancellationToken, timed: false).ConfigureAwait(false);
        try
        {
            sidecarSink!.Write(PgQueryStoreRows.ReplicaCoverage(Target, lastQueryStore, now, rows));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Warn("rca.sidecar-failed", "The sidecar couldn't keep the replica's coverage; the evidence document's capture goes on.", ("target", Target), ("error", Redactor.Redact(ex.Message)));
        }

        lastQueryStore = now;
    }

    private async Task SentinelAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        // While replay detail runs every 5 s, it takes the sentinel's replay sample too.
        var replay = stall.Current is not null && !Cadence.DetailStopped ? null : await ReplayAsync(now, receiver: true, cancellationToken).ConfigureAwait(false);
        if (replay is { } sample)
        {
            var change = stall.Observe(
                sample.At,
                sample.Since >= 30 && sample.Bytes > 0,
                sample.Since < 5,
                () => string.Create(CultureInfo.InvariantCulture, $"since_last_replayed_s {sample.Since:0.0} >= 30 with {sample.Bytes:N0} bytes received and not replayed: replay detail (RCA-PG-01, RCA-PG-02, RCA-PG-06, RCA-PG-07) every {Seconds(Every(Options.ReplayDetail))} s."));
            if (change == EpisodeChange.Started && !Cadence.DetailStopped)
            {
                // The episode's first detail sample, in this same tick, writes this sample with what replay waits for.
                startSample = sample;
            }
            else
            {
                WriteReplica(sample, conflict: null);
            }

            Report(stall, change, sample.At, "since_last_replayed_s below 5 for 3 samples: " + BackToSentinel);
            if (change == EpisodeChange.Started)
            {
                await SettingsAsync(now, cancellationToken).ConfigureAwait(false);
                nextDetail = now;
            }
        }

        var database = await RunAsync("RCA-PG-03", now, cancellationToken).ConfigureAwait(false);
        if (database is { Count: > 0 })
        {
            PgPrimaryObserver.DatabaseCounters(this, deltas, database[0], database[0].Time("captured_at") ?? now);
        }
    }

    private async Task ReplayDetailAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var activity = await RunAsync("RCA-PG-01", now, cancellationToken).ConfigureAwait(false);
        var locks = activity is null ? [] : await RunAsync("RCA-PG-02", now, cancellationToken).ConfigureAwait(false) ?? [];
        var replay = startSample ?? await ReplayAsync(now, receiver: false, cancellationToken).ConfigureAwait(false);
        startSample = null;
        ReplayConflict? conflict = null;
        if (activity is not null)
        {
            var at = activity.Select(r => r.Time("captured_at")).FirstOrDefault(t => t is not null) ?? now;
            foreach (var row in PgSessions.Build(Target, at, activity, locks, [], "RCA-PG-01,RCA-PG-02"))
            {
                Write(row);
            }

            conflict = PgSessions.Conflict(activity, locks);
        }

        if (replay is { } sample)
        {
            WriteReplica(sample, conflict);
            var change = stall.Observe(sample.At, false, sample.Since < 5, () => string.Empty, canStart: false);
            Report(stall, change, sample.At, "since_last_replayed_s below 5 for 3 samples: " + BackToSentinel);
        }
    }

    /// <summary>RCA-PG-06 with RCA-PG-07's cancelled queries (diffed), and, for the sentinel, RCA-PG-08's WAL receiver.</summary>
    private async Task<ReplaySample?> ReplayAsync(DateTimeOffset now, bool receiver, CancellationToken cancellationToken)
    {
        var rows = await RunAsync("RCA-PG-06", now, cancellationToken).ConfigureAwait(false);
        if (rows is not { Count: > 0 })
        {
            return null;
        }

        var row = rows[0];
        if (row.Bool("in_recovery") == false)
        {
            GapOnce(now, "not-in-recovery", $"{Target} isn't in recovery, so it has no replay to capture: it isn't a read replica now.");
            return null;
        }

        var source = "RCA-PG-06";
        var conflicts = await RunAsync("RCA-PG-07", now, cancellationToken).ConfigureAwait(false);
        double? cancelled = null;
        if (conflicts is { Count: > 0 })
        {
            var sum = ConflictColumns.Sum(c => conflicts[0].Double(c) ?? 0);
            cancelled = deltas.Next("conflicts_cancelled", sum);
            source += ",RCA-PG-07";
        }

        if (receiver)
        {
            var receivers = await RunAsync("RCA-PG-08", now, cancellationToken).ConfigureAwait(false);
            var status = receivers is { Count: > 0 } ? receivers[0].Text("status") : receivers is null ? receiverStatus : "none";
            source += receivers is { Count: > 0 } ? ",RCA-PG-08" : string.Empty;
            if (!string.Equals(status, receiverStatus, StringComparison.Ordinal))
            {
                if (status is not null && !string.Equals(status, "streaming", StringComparison.Ordinal))
                {
                    Gap(now, $"{Target}'s WAL receiver is {status}, not streaming, at {now:HH:mm:ss} UTC: WAL may not be arriving from T4.");
                }
                else if (receiverStatus is not null)
                {
                    Gap(now, $"{Target}'s WAL receiver is streaming again at {now:HH:mm:ss} UTC.");
                }

                receiverStatus = status;
            }
        }

        return new ReplaySample(row.Time("captured_at") ?? now, row.Double("since_last_replayed_xact_s"), row.Double("received_not_replayed_bytes"), cancelled, source);
    }

    /// <summary>RCA-PG-09, once when replay detail starts: max_standby_streaming_delay, in seconds.</summary>
    private async Task SettingsAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var settings = await RunAsync("RCA-PG-09", now, cancellationToken, timed: false).ConfigureAwait(false);
        var row = settings?.FirstOrDefault(s => string.Equals(s.Text("name"), "max_standby_streaming_delay", StringComparison.Ordinal));
        if (row?.Double("setting") is { } value)
        {
            maximumDelay = value < 0 ? -1 : (row.Text("unit") ?? "ms") switch
            {
                "ms" => value / 1000,
                "min" => value * 60,
                _ => value,
            };
        }
    }

    /// <summary>One replay sample on the replica's side: the sentinel's, or replay detail's (the same signal, more often).</summary>
    private void WriteReplica(ReplaySample sample, ReplayConflict? conflict)
    {
        var source = conflict is null ? sample.Source : "RCA-PG-01,RCA-PG-02," + sample.Source;
        if (maximumDelay is not null)
        {
            source += ",RCA-PG-09";
        }

        var row = new CaptureRow(RcaContract.Replica, Target, sample.At, source, sentinel: true)
            .Set("at_utc", sample.At)
            .Set("target", Target)
            .Set("side", "replica")
            .Set("since_last_replayed_s", sample.Since)
            .Set("received_not_replayed_bytes", sample.Bytes)
            .Set("conflicts_cancelled", sample.Cancelled is { } c ? (long)c : null)
            .Set("max_standby_streaming_delay_s", maximumDelay);
        if (conflict is not null)
        {
            row.Set("startup_wait", conflict.StartupWait)
                .Set("conflict_relation", conflict.Relation)
                .Set("conflict_wanted_mode", conflict.WantedMode)
                .Set("conflict_wait_start_utc", conflict.WaitStart)
                .Set("conflict_holder_session", conflict.Holder)
                .Set("conflict_holder_mode", conflict.HolderMode)
                .Set("conflict_holder_program", conflict.HolderName.Program)
                .Set("conflict_holder_run_token", conflict.HolderName.RunToken)
                .Set("conflict_holder_statement", conflict.HolderStatement);
        }

        Write(row);
    }

    private sealed record ReplaySample(DateTimeOffset At, double? Since, double? Bytes, double? Cancelled, string Source);
}
