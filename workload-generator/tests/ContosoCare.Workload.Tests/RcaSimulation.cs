using System.Globalization;
using System.Text;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// Simulated targets for the RCA observer's tests: what the capture catalog's blocks return on T1 during a blocking
/// chain under an idle transaction (with lock escalations and lock timeouts), and on T4 and its replica during a chain
/// under a session idle in transaction and a replay stall: the shapes of the contract's fixtures (rca/fixtures), from
/// which the observer's own code builds its rows. The observer sees only these DMV-shaped results.
/// </summary>
internal static class RcaSimulation
{
    public static readonly DateTimeOffset T1From = new(2026, 11, 20, 16, 50, 0, TimeSpan.Zero);

    public static readonly DateTimeOffset T1To = new(2026, 11, 20, 17, 5, 0, TimeSpan.Zero);

    public static readonly DateTimeOffset T4From = new(2026, 11, 20, 17, 0, 0, TimeSpan.Zero);

    public static readonly DateTimeOffset T4To = new(2026, 11, 20, 17, 20, 0, TimeSpan.Zero);

    public const string ChainApp = "ContosoCare.Demo/blocking-chain/20261120165200-t1-a1b2c3";

    public const string BaselineApp = "ContosoCare.Demo/healthy-baseline/20261120160000-t1-0f0e0d";

    public const string LockingApp = "ContosoCare.Demo/locking-blocking/20261120170200-t4-9b7c1d";

    public const string ReplicaApp = "ContosoCare.Demo/replica-lag/20261120171100-t4-5e8f21";

    /// <summary>Fast options for tests: the same cadences, a short slow-sample threshold.</summary>
    public static ObserverOptions Options() => new() { SlowSample = TimeSpan.FromSeconds(2) };

    /// <summary>Begins the observers, ticks them every second from <paramref name="from"/> to <paramref name="to"/>, and ends them.</summary>
    public static async Task DriveAsync(IReadOnlyList<TargetObserver> observers, ICaptureSpan span, ManualTime clock, DateTimeOffset from, DateTimeOffset to, CancellationToken cancellationToken)
    {
        clock.Set(from);
        foreach (var observer in observers)
        {
            span.Began(observer.Target, from);
            await observer.BeginAsync(span, from, cancellationToken);
        }

        for (var now = from; now < to; now = now.AddSeconds(1))
        {
            clock.Set(now);
            foreach (var observer in observers)
            {
                await observer.TickAsync(now, cancellationToken);
            }
        }

        clock.Set(to);
        foreach (var observer in observers)
        {
            await observer.EndAsync(to, cancellationToken);
            span.Ended(observer.Target, to);
        }
    }

    // ---- T1: the blocking chain -------------------------------------------------------------------------------------

    /// <summary>Five formations of the chain from 16:52:30 to 17:00:40, 42 samples at 10 s, 20 s apart.</summary>
    public static readonly (DateTimeOffset From, DateTimeOffset To)[] ChainFormations =
    [
        (At(16, 52, 30), At(16, 53, 50)),
        (At(16, 54, 20), At(16, 55, 30)),
        (At(16, 56, 0), At(16, 57, 10)),
        (At(16, 57, 40), At(16, 58, 50)),
        (At(16, 59, 20), At(17, 0, 40)),
    ];

    /// <summary>The escalator's lock escalations, and the X table lock it holds for 15 s after each.</summary>
    public static readonly DateTimeOffset[] Escalations = [At(16, 52, 20, 800), At(16, 54, 20, 800), At(16, 56, 20, 800), At(16, 58, 20, 800)];

    /// <summary>Six lock timeouts in each of these minutes.</summary>
    public static readonly DateTimeOffset[] TimeoutMinutes = [At(16, 53, 0), At(16, 54, 0), At(16, 56, 0), At(16, 58, 0), At(17, 0, 0)];

    public static ScriptedConnector T1(ManualTime clock) => new((block, _) => T1Block(block, clock.Now));

    public static DateTimeOffset At(int hour, int minute, int second, int millisecond = 0) => new(2026, 11, 20, hour, minute, second, millisecond, TimeSpan.Zero);

    private static IReadOnlyList<CaptureValues> T1Block(string block, DateTimeOffset now) => block switch
    {
        "RCA-XE-00" => [.. new[] { ("error_reported", "error_number"), ("error_reported", "severity"), ("error_reported", "message"), ("error_reported", "is_intercepted"), ("lock_escalation", "escalation_cause"), ("lock_escalation", "escalated_lock_count"), ("lock_escalation", "mode"), ("lock_escalation", "object_id"), ("xml_deadlock_report", "xml_report") }.Select(f => Row(("event_name", f.Item1), ("column_name", f.Item2)))],
        "RCA-XE-01" or "RCA-XE-05" => [],
        "RCA-XE-02" => [Row(("target_data", RingBuffer(T1Events(now))))],
        "RCA-SQL-09" => Counters(now),
        "RCA-SQL-01" => ChainSessions(now),
        "RCA-SQL-02" => ChainLocks(now),
        _ => [],
    };

    private static bool InFormation(DateTimeOffset now, out DateTimeOffset start)
    {
        foreach (var (from, to) in ChainFormations)
        {
            if (now >= from && now <= to)
            {
                start = from;
                return true;
            }
        }

        start = default;
        return false;
    }

    private static bool EscalatorHolds(DateTimeOffset now) => Escalations.Any(e => now >= e && now < e.AddSeconds(15));

    private static IReadOnlyList<CaptureValues> Counters(DateTimeOffset now)
    {
        var blocked = (InFormation(now, out _) ? 6 : 0) + (EscalatorHolds(now) ? 1 : 0);
        var timeouts = TimeoutMinutes.Sum(m => Enumerable.Range(0, 6).Count(i => m.AddSeconds(5 + (i * 9)) <= now));
        var escalations = Escalations.Count(e => e <= now);
        var at = now.UtcDateTime;
        return
        [
            Counter(at, "Processes blocked", string.Empty, blocked),
            Counter(at, "Lock Timeouts/sec", "_Total", timeouts),
            Counter(at, "Number of Deadlocks/sec", "_Total", 0),
            Counter(at, "Table Lock Escalations/sec", string.Empty, escalations),
            Counter(at, "SQL Attention rate", string.Empty, 0),
            Counter(at, "Log Flushes/sec", "ContosoCare", 1000 + (long)(now - T1From).TotalSeconds),
            Counter(at, "Log Flush Wait Time", "ContosoCare", 50),
            Counter(at, "Memory Grants Pending", string.Empty, 0),
            Counter(at, "Memory Grants Outstanding", string.Empty, 0),
            Counter(at, "Active Transactions", "ContosoCare", 8),
            Counter(at, "User Connections", string.Empty, 14),
        ];
    }

    private static CaptureValues Counter(DateTime at, string name, string instance, long value) =>
        Row(("captured_at_utc", at), ("object_name", "SQLServer:General Statistics"), ("counter_name", name), ("instance_name", instance), ("cntr_value", value), ("cntr_type", 65792));

    private static List<CaptureValues> ChainSessions(DateTimeOffset now)
    {
        var rows = new List<CaptureValues>();
        var at = now.UtcDateTime;
        if (InFormation(now, out var start))
        {
            var elapsed = (long)(now - start).TotalMilliseconds;
            rows.Add(Row(("captured_at_utc", at), ("session_id", 63), ("blocking_session_id", 0), ("session_status", "sleeping"), ("request_status", null), ("open_transaction_count", 1), ("transaction_age_ms", elapsed + 1000), ("idle_ms", Math.Max(0, elapsed - 1000)), ("login_name", "NT AUTHORITY\\SYSTEM"), ("host_name", "SQLVM01"), ("program_name", ChainApp), ("module_name", "[demo].[usp_scenario_chain_acquire]"), ("statement_text", null), ("input_buffer_type", "RPC Event"), ("input_buffer", "demo.usp_scenario_chain_acquire;1")));
            foreach (var (session, blocker, key, depth) in new[] { (64, 63, "93162f043aad", 1), (65, 63, "93162f043aad", 1), (66, 64, "8cba823e2e93", 2), (67, 65, "8d45c50527d3", 2), (68, 66, "68f1c63b7f46", 3), (69, 67, "7178166c0443", 3) })
            {
                // A link times out after 60 s (its lock timeout, error 1222) and queues again: its wait starts over.
                var wait = ((elapsed + 28000) % 60000) - ((depth - 1) * 2000);
                rows.Add(Row(("captured_at_utc", at), ("session_id", session), ("blocking_session_id", blocker), ("session_status", "running"), ("request_status", "suspended"), ("wait_type", "LCK_M_U"), ("wait_time_ms", wait), ("wait_resource", $"KEY: 5:72057594045071360 ({key})"), ("open_transaction_count", 1), ("transaction_age_ms", wait + 40), ("login_name", "NT AUTHORITY\\SYSTEM"), ("host_name", "SQLVM01"), ("program_name", ChainApp), ("module_name", "[demo].[usp_scenario_chain_link]"), ("statement_text", "UPDATE care.work_queues SET priority = CASE WHEN priority >= 5 THEN 5 ELSE priority + 1 END WHERE work_item_id = @parent")));
            }
        }

        if (EscalatorHolds(now))
        {
            var held = (long)(now - Escalations.Last(e => e <= now)).TotalMilliseconds;
            rows.Add(Row(("captured_at_utc", at), ("session_id", 71), ("blocking_session_id", 0), ("session_status", "running"), ("request_status", "suspended"), ("wait_type", "WAITFOR"), ("wait_time_ms", 400), ("open_transaction_count", 1), ("transaction_age_ms", held + 1600), ("login_name", "NT AUTHORITY\\SYSTEM"), ("host_name", "SQLVM01"), ("program_name", ChainApp), ("module_name", "[demo].[usp_scenario_chain_escalate]"), ("statement_text", "WAITFOR DELAY '00:00:00.400'")));
            rows.Add(Row(("captured_at_utc", at), ("session_id", 74), ("blocking_session_id", 71), ("session_status", "running"), ("request_status", "suspended"), ("wait_type", "LCK_M_IS"), ("wait_time_ms", held), ("wait_resource", "OBJECT: 5:1205579333:0 "), ("open_transaction_count", 0), ("login_name", "NT AUTHORITY\\SYSTEM"), ("host_name", "SQLVM01"), ("program_name", BaselineApp), ("module_name", "[demo].[usp_scenario_healthy_baseline]"), ("statement_text", "SELECT @count = COUNT(*) FROM care.appointments WHERE provider_id = @id AND scheduled_start >= @day AND scheduled_start < DATEADD(day, 1, @day)")));
        }

        return rows;
    }

    private static List<CaptureValues> ChainLocks(DateTimeOffset now)
    {
        var rows = new List<CaptureValues>();
        var at = now.UtcDateTime;
        CaptureValues Key(int session, string key, string mode, string status) =>
            Row(("captured_at_utc", at), ("request_session_id", session), ("resource_type", "KEY"), ("resource_description", $"({key})"), ("resource_associated_entity_id", 72057594045071360L), ("request_mode", mode), ("request_status", status), ("object_name", "[care].[work_queues]"), ("index_name", "pk_work_queues"));
        if (InFormation(now, out _))
        {
            rows.Add(Key(63, "93162f043aad", "X", "GRANTED"));
            rows.Add(Key(64, "93162f043aad", "U", "WAIT"));
            rows.Add(Key(65, "93162f043aad", "U", "WAIT"));
            rows.Add(Key(64, "8cba823e2e93", "X", "GRANTED"));
            rows.Add(Key(66, "8cba823e2e93", "U", "WAIT"));
            rows.Add(Key(65, "8d45c50527d3", "X", "GRANTED"));
            rows.Add(Key(67, "8d45c50527d3", "U", "WAIT"));
            rows.Add(Key(66, "68f1c63b7f46", "X", "GRANTED"));
            rows.Add(Key(68, "68f1c63b7f46", "U", "WAIT"));
            rows.Add(Key(67, "7178166c0443", "X", "GRANTED"));
            rows.Add(Key(69, "7178166c0443", "U", "WAIT"));
        }

        if (EscalatorHolds(now))
        {
            rows.Add(Row(("captured_at_utc", at), ("request_session_id", 71), ("resource_type", "OBJECT"), ("resource_description", string.Empty), ("resource_associated_entity_id", 1205579333L), ("request_mode", "X"), ("request_status", "GRANTED"), ("object_name", "[care].[appointments]")));
            rows.Add(Row(("captured_at_utc", at), ("request_session_id", 74), ("resource_type", "OBJECT"), ("resource_description", string.Empty), ("resource_associated_entity_id", 1205579333L), ("request_mode", "IS"), ("request_status", "WAIT"), ("object_name", "[care].[appointments]")));
        }

        return rows;
    }

    /// <summary>The events the observer's session has by <paramref name="now"/> (dispatched a second after they happen).</summary>
    private static IEnumerable<string> T1Events(DateTimeOffset now)
    {
        foreach (var at in Escalations.Where(e => e.AddSeconds(1) <= now))
        {
            yield return Event("lock_escalation", at, [("escalation_cause", "1", "Lock threshold"), ("escalated_lock_count", "6248", null), ("mode", "5", "X"), ("object_id", "1205579333", null)], [("client_app_name", ChainApp), ("session_id", "71"), ("sql_text", "exec demo.usp_scenario_chain_escalate @run_id=@p0")]);
        }

        foreach (var minute in TimeoutMinutes)
        {
            for (var i = 0; i < 6; i++)
            {
                var at = minute.AddSeconds(5 + (i * 9));
                if (at.AddSeconds(1) <= now)
                {
                    yield return Event("error_reported", at, [("error_number", "1222", null), ("severity", "16", null), ("is_intercepted", "true", null), ("message", "Lock request time out period exceeded.", null)], [("client_app_name", ChainApp), ("session_id", (64 + (i % 6)).ToString(CultureInfo.InvariantCulture)), ("username", "NT AUTHORITY\\SYSTEM"), ("client_hostname", "SQLVM01"), ("sql_text", "exec demo.usp_scenario_chain_link @run_id=@p0")]);
                }
            }
        }

        // The observer's own lock timeout and another database's error: neither is the workload's capture.
        if (At(16, 51, 0).AddSeconds(1) <= now)
        {
            yield return Event("error_reported", At(16, 51, 0), [("error_number", "1222", null), ("severity", "16", null), ("is_intercepted", "false", null), ("message", "Lock request time out period exceeded.", null)], [("client_app_name", ApplicationNames.Observer), ("session_id", "90")]);
        }
    }

    public static string Event(string name, DateTimeOffset at, (string Name, string Value, string? Text)[] data, (string Name, string Value)[] actions)
    {
        var xml = new StringBuilder();
        xml.Append(CultureInfo.InvariantCulture, $"<event name=\"{name}\" package=\"sqlserver\" timestamp=\"{at.UtcDateTime:yyyy-MM-ddTHH:mm:ss.fffZ}\">");
        foreach (var (field, value, text) in data)
        {
            xml.Append(CultureInfo.InvariantCulture, $"<data name=\"{field}\"><type name=\"x\" package=\"package0\"></type><value>{System.Security.SecurityElement.Escape(value)}</value>{(text is null ? string.Empty : "<text>" + System.Security.SecurityElement.Escape(text) + "</text>")}</data>");
        }

        foreach (var (action, value) in actions)
        {
            xml.Append(CultureInfo.InvariantCulture, $"<action name=\"{action}\" package=\"sqlserver\"><type name=\"x\" package=\"package0\"></type><value>{System.Security.SecurityElement.Escape(value)}</value></action>");
        }

        return xml.Append("</event>").ToString();
    }

    public static string RingBuffer(IEnumerable<string> events)
    {
        var list = events.ToList();
        return string.Create(CultureInfo.InvariantCulture, $"<RingBufferTarget truncated=\"0\" processingTime=\"0\" totalEventsProcessed=\"{list.Count}\" eventCount=\"{list.Count}\" droppedCount=\"0\" memoryUsed=\"0\">{string.Concat(list)}</RingBufferTarget>");
    }

    public static SqlTargetObserver T1Observer(ScriptedConnector connector) => new("T1", DemoTarget.T1, connector, Options(), RunnerLog.Null);

    // ---- T4 and its replica: a chain under a session idle in transaction, and a replay stall ----------------------------

    /// <summary>Four formations from 17:02:30 to 17:11:20: 45 samples at 10 s, 30 s apart.</summary>
    public static readonly (DateTimeOffset From, DateTimeOffset To)[] LockFormations =
    [
        (At(17, 2, 30), At(17, 4, 20)),
        (At(17, 5, 0), At(17, 6, 50)),
        (At(17, 7, 30), At(17, 9, 10)),
        (At(17, 9, 50), At(17, 11, 20)),
    ];

    /// <summary>Replay waits from 17:11:15 behind the report on the replica, and resumes at 17:14:14.</summary>
    /// <summary>The sessions that wait on T4's head blocker, and what pg_blocking_pids returns for them.</summary>
    public static readonly int[] Waiters = [9772, 20584, 35660];

    private static readonly int[] HeadOnly = [20432];

    public static readonly DateTimeOffset StallFrom = At(17, 11, 15);

    public static readonly DateTimeOffset StallTo = At(17, 14, 14);

    /// <summary>The primary's WAL written since T4From: 2,400 bytes a second, 1,020 from 17:10:30 to 17:14:30.</summary>
    public static decimal WalBytes(DateTimeOffset now)
    {
        static decimal Span(DateTimeOffset from, DateTimeOffset to) => to <= from ? 0m : (decimal)(to - from).TotalSeconds;
        static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;
        var slowFrom = At(17, 10, 30);
        var slowTo = At(17, 14, 30);
        return 5_000_000m + (Span(T4From, Min(now, slowFrom)) * 2400m) + (Span(slowFrom, Min(now, slowTo)) * 1020m) + (Span(slowTo, now) * 2400m);
    }

    public static ScriptedConnector T4Primary(ManualTime clock) => new((block, parameter) => PrimaryBlock(block, parameter, clock.Now));

    public static ScriptedConnector T4Replica(ManualTime clock) => new((block, _) => ReplicaBlock(block, clock.Now));

    private static bool InLockFormation(DateTimeOffset now, out DateTimeOffset start)
    {
        foreach (var (from, to) in LockFormations)
        {
            if (now >= from && now <= to)
            {
                start = from;
                return true;
            }
        }

        start = default;
        return false;
    }

    private static double Since(DateTimeOffset now) => now >= StallFrom && now < StallTo ? Math.Round((now - StallFrom).TotalSeconds + 0.4, 1) : now >= StallTo && now < StallTo.AddSeconds(2) ? 0.9 : 0.4;

    private static double Pending(DateTimeOffset now) => now >= StallFrom && now < StallTo ? Math.Round((now - StallFrom).TotalSeconds) * 1020 : 0;

    private static List<CaptureValues> PrimaryBlock(string block, int[]? parameter, DateTimeOffset now)
    {
        var at = now.UtcDateTime;
        var locked = InLockFormation(now, out var start);
        switch (block)
        {
            case "RCA-PG-10":
                return [Row(("captured_at", at), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", 12L), ("active", 6L), ("idle", 4L), ("idle_in_transaction", locked ? 1L : 0L), ("waiting_lock", locked ? 3L : 0L))];
            case "RCA-PG-03":
                return [Row(("captured_at", at), ("deadlocks", 0L), ("conflicts", 0L), ("xact_rollback", 10L), ("temp_files", 0L))];
            case "RCA-PG-05":
                return [Row(("captured_at", at), ("pid", 501), ("application_name", "t4-replica"), ("state", "streaming"), ("write_lag_s", 0.001m), ("flush_lag_s", 0.002m), ("replay_lag_s", (decimal)Since(now)), ("send_gap_bytes", 0m), ("replay_gap_bytes", (decimal)Pending(now)))];
            case "RCA-PG-04":
                return [Row(("captured_at", at), ("wal_bytes", WalBytes(now)))];
            case "RCA-PG-01":
                var activity = new List<CaptureValues> { Row(("captured_at", at), ("pid", 501), ("backend_type", "walsender"), ("state", "active"), ("wait_event_type", "Activity"), ("wait_event", "WalSenderMain"), ("blocked_by", Array.Empty<int>())) };
                if (locked)
                {
                    var elapsed = (now - start).TotalSeconds;
                    activity.Add(Row(("captured_at", at), ("pid", 20432), ("backend_type", "client backend"), ("usename", "contosocare_runner"), ("application_name", LockingApp), ("state", "idle in transaction"), ("wait_event_type", "Client"), ("wait_event", "ClientRead"), ("blocked_by", Array.Empty<int>()), ("xact_age_s", (decimal)Math.Round(elapsed + 0.2, 1)), ("state_age_s", (decimal)Math.Round(Math.Max(0, elapsed - 0.2), 1)), ("query", "SELECT run_id, locked_rows FROM demo.usp_scenario_locking_acquire($1, $2)")));
                    foreach (var pid in Waiters)
                    {
                        activity.Add(Row(("captured_at", at), ("pid", pid), ("backend_type", "client backend"), ("usename", "contosocare_runner"), ("application_name", LockingApp), ("state", "active"), ("wait_event_type", "Lock"), ("wait_event", "transactionid"), ("blocked_by", HeadOnly), ("xact_age_s", (decimal)Math.Min(20.03, elapsed + 0.03)), ("state_age_s", (decimal)Math.Min(20, elapsed)), ("query", "SELECT updates, waited_ms FROM demo.usp_scenario_locking_contend($1, $2, $3)")));
                    }
                }

                return activity;
            case "RCA-PG-02":
                return locked
                    ? [.. Waiters.Select(pid => Row(("captured_at", at), ("waiting_pid", pid), ("locktype", "transactionid"), ("waiting_mode", "ShareLock"), ("waitstart", now.AddSeconds(-Math.Min(20, (now - start).TotalSeconds)).UtcDateTime), ("relation", null), ("transactionid", "48211"), ("holding_pid", 20432), ("held_mode", "ExclusiveLock")))]
                    : [];
            case "RCA-PG-11":
                return parameter is not null && parameter.Contains(20432)
                    ? [Row(("captured_at", at), ("pid", 20432), ("relation", "care.work_queues"), ("mode", "RowExclusiveLock")), Row(("captured_at", at), ("pid", 20432), ("relation", "demo.scenario_runs"), ("mode", "RowShareLock"))]
                    : [];
            default:
                return [];
        }
    }

    private static List<CaptureValues> ReplicaBlock(string block, DateTimeOffset now)
    {
        var at = now.UtcDateTime;
        var stalled = now >= StallFrom && now < StallTo;
        switch (block)
        {
            case "RCA-PG-06":
                return [Row(("captured_at", at), ("in_recovery", true), ("received_not_replayed_bytes", (decimal)Pending(now)), ("since_last_replayed_xact_s", (decimal)Since(now)), ("replay_pause_state", "not paused"))];
            case "RCA-PG-07":
                return [Row(("captured_at", at), ("confl_tablespace", 0L), ("confl_lock", 0L), ("confl_snapshot", 0L), ("confl_bufferpin", 0L), ("confl_deadlock", 0L), ("confl_active_logicalslot", 0L))];
            case "RCA-PG-08":
                return [Row(("captured_at", at), ("status", "streaming"))];
            case "RCA-PG-09":
                return [Row(("name", "hot_standby_feedback"), ("setting", "off"), ("unit", null)), Row(("name", "max_standby_streaming_delay"), ("setting", "600000"), ("unit", "ms"))];
            case "RCA-PG-03":
                return [Row(("captured_at", at), ("deadlocks", 0L), ("conflicts", 0L), ("xact_rollback", 0L), ("temp_files", 0L))];
            case "RCA-PG-01":
                var activity = new List<CaptureValues>
                {
                    Row(("captured_at", at), ("pid", 1180), ("backend_type", "startup"), ("state", null), ("wait_event_type", stalled ? "Lock" : "Activity"), ("wait_event", stalled ? "relation" : "RecoveryWalStream"), ("blocked_by", Array.Empty<int>())),
                    Row(("captured_at", at), ("pid", 1181), ("backend_type", "walreceiver"), ("state", null), ("wait_event_type", "Activity"), ("wait_event", "WalReceiverMain"), ("blocked_by", Array.Empty<int>())),
                };
                if (stalled)
                {
                    activity.Add(Row(("captured_at", at), ("pid", 41872), ("backend_type", "client backend"), ("usename", "contosocare_runner"), ("application_name", ReplicaApp), ("state", "active"), ("wait_event_type", "Timeout"), ("wait_event", "PgSleep"), ("blocked_by", Array.Empty<int>()), ("xact_age_s", (decimal)Math.Round((now - StallFrom).TotalSeconds + 1, 1)), ("query", "SELECT r.marks_seen, r.last_mark FROM (SELECT count(*) AS marks_seen, max(m.marked_at) AS last_mark FROM demo.replica_lag_marks AS m) AS r CROSS JOIN pg_sleep(180) AS s")));
                }

                return activity;
            case "RCA-PG-02":
                return stalled
                    ? [Row(("captured_at", at), ("waiting_pid", 1180), ("locktype", "relation"), ("waiting_mode", "AccessExclusiveLock"), ("waitstart", StallFrom.UtcDateTime), ("relation", "demo.replica_lag_marks"), ("holding_pid", 41872), ("held_mode", "AccessShareLock"))]
                    : [];
            default:
                return [];
        }
    }
}
