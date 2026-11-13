using System.Globalization;

namespace ContosoCare.Workload.Postgres;

/// <summary>
/// replica-lag's shape (ADR 0025): each cycle's hold, the report's session limits, and the statements the runner sends,
/// pure so the tests check them without a server. PgScenarioRunner.RunReplicaLagAsync runs the cycles.
/// Source: https://www.postgresql.org/docs/current/hot-standby.html#HOT-STANDBY-CONFLICT
/// </summary>
internal static class ReplicaLag
{
    public const string ScenarioId = "replica-lag";

    /// <summary>Why a run is refused without --replica-server.</summary>
    public const string NoReplicaReason = "replica-lag needs T4's read replica, and T4's read replica isn't known on T1: start-demo.ps1 creates it, and deploy.ps1 sends T1 its name (the runner's --replica-server).";

    /// <summary>SQLSTATE 40001 on a hot standby: "canceling statement due to conflict with recovery", here a relation lock held past max_standby_streaming_delay.</summary>
    public const string RecoveryConflictState = "40001";

    /// <summary>The shortest hold worth a cycle: holdSeconds' minimum in scenarios/replica-lag/scenario.json.</summary>
    public const int MinimumHoldSeconds = 30;

    /// <summary>The primary's step: one mark, and with @take_lock first the table's ACCESS EXCLUSIVE lock.</summary>
    public const string StepSql = "SELECT marks_written, locks_taken, last_mark_id FROM demo.usp_scenario_replica_lag(@run_id, @take_lock);";

    /// <summary>
    /// The report on the replica. Opening demo.replica_lag_marks takes its ACCESS SHARE lock, which lasts until the
    /// statement's transaction ends, so the table stays held while pg_sleep runs; the aggregate is always one row, so
    /// pg_sleep runs exactly once, whatever the table holds.
    /// </summary>
    public const string ReportSql = """
        SELECT r.marks_seen, r.last_mark
        FROM (SELECT count(*) AS marks_seen, max(m.marked_at) AS last_mark FROM demo.replica_lag_marks AS m) AS r
        CROSS JOIN pg_sleep(@hold_seconds) AS s;
        """;

    /// <summary>True once a session (@pid) holds demo.replica_lag_marks' ACCESS SHARE lock: pg_locks on the replica.</summary>
    public const string ReportHoldsSql = """
        SELECT EXISTS (
            SELECT 1
            FROM pg_locks AS l
            WHERE l.pid = @pid
              AND l.locktype = 'relation'
              AND l.relation = 'demo.replica_lag_marks'::regclass
              AND l.mode = 'AccessShareLock'
              AND l.granted) AS holding;
        """;

    /// <summary>
    /// The replica's state: in recovery, max_standby_streaming_delay in milliseconds (-1 waits forever), and the time
    /// since its last replayed transaction, which Azure Monitor's Read Replica Lag reports.
    /// </summary>
    public const string ReplicaStateSql = """
        SELECT pg_is_in_recovery() AS in_recovery,
               (SELECT s.setting::bigint FROM pg_settings AS s WHERE s.name = 'max_standby_streaming_delay') AS max_standby_streaming_delay_ms,
               round(EXTRACT(EPOCH FROM clock_timestamp() - pg_last_xact_replay_timestamp())::numeric, 1) AS replay_lag_seconds;
        """;

    /// <summary>How long the writer goes on after a report ends, so the replica's lag visibly drops before the pause.</summary>
    public static readonly TimeSpan RecoveryWindow = TimeSpan.FromSeconds(30);

    /// <summary>The report's statement_timeout beyond its hold.</summary>
    public static readonly TimeSpan StatementMargin = TimeSpan.FromSeconds(30);

    /// <summary>How long the runner waits for the report to hold the table before it skips the cycle; also the report's lock_timeout.</summary>
    public static readonly TimeSpan LockWait = TimeSpan.FromSeconds(15);

    /// <summary>Room for a cycle's start: the report's session, and its lock showing in pg_locks.</summary>
    public static readonly TimeSpan StartMargin = TimeSpan.FromSeconds(5);

    /// <summary>
    /// The hold of a cycle that starts at <paramref name="now"/>: holdSeconds, cut so the start, the hold, and the recovery
    /// window end before the run's deadline; null when less than <see cref="MinimumHoldSeconds"/> is left.
    /// </summary>
    public static TimeSpan? CycleHold(int holdSeconds, DateTimeOffset now, DateTimeOffset deadline)
    {
        var room = Math.Floor((deadline - now - StartMargin - RecoveryWindow).TotalSeconds);
        var hold = Math.Min(holdSeconds, room);
        return hold >= MinimumHoldSeconds ? TimeSpan.FromSeconds(hold) : null;
    }

    /// <summary>
    /// The report's session limits: statement_timeout the hold plus <see cref="StatementMargin"/>, never past the run's hard
    /// deadline (at least a second); lock_timeout <see cref="LockWait"/>, never above the statement_timeout.
    /// </summary>
    public static PgSessionLimits ReportLimits(TimeSpan hold, TimeSpan untilHardDeadline)
    {
        var statement = (long)Math.Max(1000, Math.Min((hold + StatementMargin).TotalMilliseconds, untilHardDeadline.TotalMilliseconds));
        return new PgSessionLimits(statement, Math.Min(statement, (long)LockWait.TotalMilliseconds), statement);
    }

    /// <summary>
    /// When a cycle reads the replica's lag for the last time: a second before its report ends, after the hold or when
    /// recovery cancels it, max_standby_streaming_delay after T4's lock (-1, or unknown: never).
    /// </summary>
    public static DateTimeOffset LastLagCheck(DateTimeOffset holdEnd, DateTimeOffset lockedAt, long? standbyDelayMs)
    {
        var end = standbyDelayMs is long delay && delay >= 0 && lockedAt + TimeSpan.FromMilliseconds(delay) < holdEnd
            ? lockedAt + TimeSpan.FromMilliseconds(delay)
            : holdEnd;
        return end - TimeSpan.FromSeconds(1);
    }

    /// <summary>max_standby_streaming_delay in a run event's words, from pg_settings (milliseconds; -1 waits forever).</summary>
    public static string DescribeDelay(long? milliseconds) => milliseconds switch
    {
        null => "unknown",
        < 0 => "-1 (replay waits for the report however long it runs)",
        _ => string.Create(CultureInfo.InvariantCulture, $"{milliseconds.Value / 1000.0:0.#} s"),
    };
}
