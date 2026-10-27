using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Sql;
using Npgsql;

namespace ContosoCare.Workload.Postgres;

/// <summary>Server-wide live counters for T4's status: what Database Hub's metrics show, read directly from the server.</summary>
internal sealed record PgServerView(
    int MaxConnections,
    int ReservedConnections,
    int ClientConnections,
    int Active,
    int Idle,
    int IdleInTransaction,
    int Blocked,
    decimal? LongestTransactionSeconds,
    decimal? LongestQuerySeconds,
    long Deadlocks,
    bool CanReadAllStats,
    IReadOnlyDictionary<string, int> ActiveByWaitEventType)
{
    /// <summary>Connections a non-administrator can still open before the server refuses them (SQLSTATE 53300).</summary>
    public int AvailableConnections => Math.Max(0, MaxConnections - ReservedConnections - ClientConnections);
}

/// <summary>Typed calls to T4's demo control functions (database/postgresql/110-demo-control.sql).</summary>
internal sealed class PgDemoDatabase(NpgsqlConnection connection)
{
    private const int ControlTimeoutSeconds = 60;

    public NpgsqlConnection Connection => connection;

    public async Task<RunRegistration> BeginRunAsync(
        string runId,
        string scenarioId,
        int durationSeconds,
        int concurrency,
        int intensity,
        string parametersJson,
        string expectedSymptoms,
        string requestedBy,
        string? profileName,
        CancellationToken cancellationToken)
    {
        await using var command = Command(
            "SELECT deadline_at, effective_duration_seconds FROM demo.usp_run_begin(@run_id, @scenario_id, 'T4', @duration_seconds, @concurrency, @intensity, @parameters, @expected_symptoms, @requested_by, @runner_host, @profile_name);");
        Add(command, "run_id", runId);
        Add(command, "scenario_id", scenarioId);
        Add(command, "duration_seconds", durationSeconds);
        Add(command, "concurrency", concurrency);
        Add(command, "intensity", intensity);
        Add(command, "parameters", DemoDatabase.Truncate(parametersJson, 2000));
        Add(command, "expected_symptoms", DemoDatabase.Truncate(expectedSymptoms, 400));
        Add(command, "requested_by", DemoDatabase.Truncate(requestedBy, 128));
        Add(command, "runner_host", DemoDatabase.Truncate(Environment.MachineName, 128));
        AddNullable(command, "profile_name", profileName);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            throw new InvalidOperationException("demo.usp_run_begin returned no row.");
        }

        return new RunRegistration(reader.GetFieldValue<DateTimeOffset>(0).ToUniversalTime(), reader.GetInt32(1));
    }

    public async Task RecordEventAsync(string runId, RunEvent runEvent, CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT demo.usp_run_event(@run_id, @event_name, @session_id, @detail, @event_time);");
        Add(command, "run_id", runId);
        Add(command, "event_name", DemoDatabase.Truncate(runEvent.Name, 40));
        AddNullable(command, "session_id", runEvent.SessionId);
        AddNullable(command, "detail", runEvent.Detail is null ? null : DemoDatabase.Truncate(runEvent.Detail, 400));
        command.Parameters.Add(new NpgsqlParameter<DateTimeOffset>("event_time", runEvent.At.ToUniversalTime()));
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task EndRunAsync(string runId, string status, string? outcome, string? sessionIds, CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT demo.usp_run_end(@run_id, @status, @outcome, @session_ids);");
        Add(command, "run_id", runId);
        Add(command, "status", status);
        AddNullable(command, "outcome", outcome is null ? null : DemoDatabase.Truncate(outcome, 1000));
        AddNullable(command, "session_ids", sessionIds is null ? null : DemoDatabase.Truncate(sessionIds, 400));
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> IsStopRequestedAsync(string runId, CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT demo.fn_run_stop_requested(@run_id);");
        Add(command, "run_id", runId);
        return await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is true;
    }

    /// <summary>demo.usp_stop: scope <c>run</c>, <c>scenario</c>, or <c>all</c>. Returns how many Running runs were marked Cancelled.</summary>
    public async Task<int> StopAsync(string scope, string? runId, string? scenarioId, string requestedBy, CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT demo.usp_stop(@scope, @run_id, @scenario_id, @requested_by);");
        Add(command, "scope", scope);
        AddNullable(command, "run_id", runId);
        AddNullable(command, "scenario_id", scenarioId);
        Add(command, "requested_by", DemoDatabase.Truncate(requestedBy, 128));
        return await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is int count ? count : 0;
    }

    /// <summary>The watchdog backstop and reset: pg_terminate_backend for this database's ContosoCare.Demo/ sessions only.</summary>
    public async Task<KillSummary> KillRunSessionsAsync(string? runId, bool pastDeadlineOnly, string requestedBy, CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT killed, failed FROM demo.usp_kill_demo_sessions(@run_id, @past_deadline_only, @requested_by);");
        AddNullable(command, "run_id", runId);
        Add(command, "past_deadline_only", pastDeadlineOnly);
        Add(command, "requested_by", DemoDatabase.Truncate(requestedBy, 128));
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
            ? new KillSummary(true, reader.GetInt32(0), reader.GetInt32(1))
            : new KillSummary(true, 0, 0);
    }

    /// <summary>Live demo sessions in contosocare (all runs, or one). The runner's role always sees its own sessions.</summary>
    public async Task<IReadOnlyList<PgDemoSession>> GetDemoSessionsAsync(string? runId, CancellationToken cancellationToken)
    {
        await using var command = Command(
            "SELECT pid, application_name, state, open_transaction, blocked_by, wait_event_type, wait_event, transaction_seconds, state_seconds FROM demo.fn_demo_sessions(@run_id) ORDER BY pid;");
        AddNullable(command, "run_id", runId);
        var sessions = new List<PgDemoSession>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            sessions.Add(new PgDemoSession(
                reader.GetInt32(0),
                reader.IsDBNull(1) ? string.Empty : reader.GetString(1),
                reader.IsDBNull(2) ? "unknown" : reader.GetString(2),
                !reader.IsDBNull(3) && reader.GetBoolean(3),
                reader.IsDBNull(4) ? null : reader.GetInt32(4),
                reader.IsDBNull(5) ? null : reader.GetString(5),
                reader.IsDBNull(6) ? null : reader.GetString(6),
                reader.IsDBNull(7) ? null : reader.GetDecimal(7),
                reader.IsDBNull(8) ? null : reader.GetDecimal(8)));
        }

        return sessions;
    }

    public async Task<IReadOnlyList<RunRecord>> GetRunsAsync(int count, bool runningOnly, CancellationToken cancellationToken)
    {
        await using var command = Command(
            """
            SELECT run_id, scenario_id, target, status, started_at, deadline_at, stopped_at, max_duration_seconds,
                concurrency, intensity, outcome, profile_name, requested_by
            FROM demo.scenario_runs
            WHERE NOT @running_only OR status = 'Running'
            ORDER BY started_at DESC
            LIMIT @count;
            """);
        Add(command, "count", count);
        Add(command, "running_only", runningOnly);
        var runs = new List<RunRecord>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            runs.Add(new RunRecord(
                reader.GetString(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetFieldValue<DateTimeOffset>(4).ToUniversalTime(),
                reader.GetFieldValue<DateTimeOffset>(5).ToUniversalTime(),
                reader.IsDBNull(6) ? null : reader.GetFieldValue<DateTimeOffset>(6).ToUniversalTime(),
                reader.GetInt32(7),
                reader.GetInt32(8),
                reader.GetInt16(9),
                reader.IsDBNull(10) ? null : reader.GetString(10),
                reader.IsDBNull(11) ? null : reader.GetString(11),
                reader.IsDBNull(12) ? null : reader.GetString(12)));
        }

        return runs;
    }

    public async Task<IReadOnlyList<StopFlag>> GetStopFlagsAsync(CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT scenario_id, stop_requested_at, stop_requested_by FROM demo.scenario_control WHERE stop_requested ORDER BY scenario_id;");
        var flags = new List<StopFlag>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            flags.Add(new StopFlag(reader.GetString(0), reader.IsDBNull(1) ? null : reader.GetFieldValue<DateTimeOffset>(1).ToUniversalTime(), reader.IsDBNull(2) ? null : reader.GetString(2)));
        }

        return flags;
    }

    /// <summary>demo.usp_cleanup_scenario: empties the scenario's scratch data after a run (auto-cleanup).</summary>
    public async Task<CheckRecord> CleanupScenarioAsync(string scenarioId, CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT check_id, status, message FROM demo.usp_cleanup_scenario(@scenario_id);");
        Add(command, "scenario_id", scenarioId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
            ? new CheckRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2))
            : new CheckRecord("auto-cleanup", "Not selected", "Nothing to clean up.");
    }

    /// <summary>
    /// Reset, the T4 way: the same steps and check IDs as demo.usp_reset on T1 to T3, but the waits happen here, in
    /// short statements, so reset never holds a long transaction open itself.
    /// </summary>
    public async Task<IReadOnlyList<CheckRecord>> ResetAsync(ResetOptions options, TimeProvider time, CancellationToken cancellationToken)
    {
        var checks = new List<CheckRecord>();
        var wait = TimeSpan.FromSeconds(Math.Clamp(options.WaitSeconds, 0, 300));

        // 1. Stop.
        var cancelled = await StopAsync("all", null, null, options.RequestedBy, cancellationToken).ConfigureAwait(false);
        checks.Add(new CheckRecord("runs-stopped", "Pass", string.Create(CultureInfo.InvariantCulture, $"Stop requested for every run; {cancelled} Running run(s) marked Cancelled.")));

        // 2. Wait for the steps to notice (they check before every unit of work).
        var until = time.GetUtcNow() + wait;
        var sessions = await GetDemoSessionsAsync(null, cancellationToken).ConfigureAwait(false);
        while (sessions.Count > 0 && time.GetUtcNow() < until)
        {
            await Task.Delay(TimeSpan.FromSeconds(1), time, cancellationToken).ConfigureAwait(false);
            sessions = await GetDemoSessionsAsync(null, cancellationToken).ConfigureAwait(false);
        }

        // 3. End what's left.
        if (sessions.Count == 0)
        {
            checks.Add(new CheckRecord("demo-sessions-ended", "Pass", "No demo sessions remain."));
        }
        else if (!options.KillSessions)
        {
            checks.Add(new CheckRecord("demo-sessions-ended", "Warning", string.Create(CultureInfo.InvariantCulture, $"{sessions.Count} demo session(s) remain, and --no-kill left them alone.")));
        }
        else
        {
            var kill = await KillRunSessionsAsync(null, pastDeadlineOnly: false, options.RequestedBy, cancellationToken).ConfigureAwait(false);
            checks.Add(new CheckRecord(
                "demo-sessions-ended",
                kill.Failed > 0 ? "Manual action required" : "Pass",
                string.Create(CultureInfo.InvariantCulture, $"{kill.Killed} demo session(s) ended with pg_terminate_backend, {kill.Failed} could not be{(kill.Failed > 0 ? " (another role owns them; run reset as an administrator)" : string.Empty)}.")));
            until = time.GetUtcNow() + wait;
            do
            {
                await Task.Delay(TimeSpan.FromSeconds(1), time, cancellationToken).ConfigureAwait(false);
                sessions = await GetDemoSessionsAsync(null, cancellationToken).ConfigureAwait(false);
            }
            while (sessions.Any(s => s.OpenTransaction) && time.GetUtcNow() < until);
        }

        // 4. Verify that no demo transaction is open.
        var open = sessions.Count(s => s.OpenTransaction);
        checks.Add(new CheckRecord(
            "no-open-demo-transactions",
            open == 0 ? "Pass" : "Fail",
            open == 0 ? "No demo session has an open transaction." : string.Create(CultureInfo.InvariantCulture, $"{open} demo session(s) still have an open transaction; run reset again as an administrator.")));

        // 5. Close run records whose runner didn't.
        await using (var recover = Command("SELECT demo.usp_recover_stale_runs(0); UPDATE demo.scenario_runs SET stopped_at = clock_timestamp() WHERE status <> 'Running' AND stopped_at IS NULL;"))
        {
            await recover.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        // 6 and 7. The scratch table and the rows the workload wrote.
        await using (var restore = Command("SELECT check_id, status, message FROM demo.usp_restore_seed();"))
        {
            await using var reader = await restore.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                checks.Add(new CheckRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2)));
            }
        }

        // 8. Optional steps. T4 has no missing-index scenario, so there's no remediation to undo.
        checks.Add(options.UndoRemediation
            ? new CheckRecord("remediation-undone", "Not supported", "T4 has no missing-index scenario, so there's no remediation to undo.")
            : new CheckRecord("remediation-undone", "Not selected", "The missing-index remediation applies to T1 to T3 only."));
        if (options.Reseed)
        {
            try
            {
                var scale = await GetSeedScaleAsync(cancellationToken).ConfigureAwait(false);
                checks.Add(scale is { } value
                    ? (await PgScripts.SeedAsync(connection, value, force: true, cancellationToken).ConfigureAwait(false)) with { CheckId = "reseeded" }
                    : new CheckRecord("reseeded", "Fail", "demo.seed_state has no completed seed to repeat; run setup --seed-scale as an administrator."));
            }
            catch (PostgresException ex)
            {
                checks.Add(new CheckRecord("reseeded", "Fail", "Reseed failed: " + PgConnectionOpener.Describe(ex)));
            }
        }
        else
        {
            checks.Add(new CheckRecord("reseeded", "Not selected", "Business data kept; scenarios roll back their own changes."));
        }

        return checks;
    }

    /// <summary>The live server view: connections against the limit, sessions by state and wait event type, blocking, the oldest transaction, and deadlocks.</summary>
    public async Task<PgServerView> GetServerViewAsync(CancellationToken cancellationToken)
    {
        await using (var clear = Command("SELECT pg_stat_clear_snapshot();"))
        {
            await clear.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        await using var command = Command(
            """
            SELECT current_setting('max_connections')::integer,
                   current_setting('superuser_reserved_connections')::integer + COALESCE(NULLIF(current_setting('reserved_connections', true), '')::integer, 0),
                   count(*) FILTER (WHERE a.backend_type = 'client backend'),
                   count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.state = 'active'),
                   count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.state = 'idle'),
                   count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.state LIKE 'idle in transaction%'),
                   count(*) FILTER (WHERE a.backend_type = 'client backend' AND cardinality(pg_blocking_pids(a.pid)) > 0),
                   round(max(EXTRACT(EPOCH FROM clock_timestamp() - a.xact_start)) FILTER (WHERE a.backend_type = 'client backend')::numeric, 1),
                   round(max(EXTRACT(EPOCH FROM clock_timestamp() - a.query_start)) FILTER (WHERE a.backend_type = 'client backend' AND a.state = 'active' AND a.pid <> pg_backend_pid())::numeric, 1),
                   (SELECT COALESCE(d.deadlocks, 0) FROM pg_stat_database AS d WHERE d.datname = current_database()),
                   pg_has_role(current_user, 'pg_read_all_stats', 'member')
            FROM pg_stat_activity AS a;
            """);
        PgServerView view;
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
        {
            await reader.ReadAsync(cancellationToken).ConfigureAwait(false);
            view = new PgServerView(
                reader.GetInt32(0),
                reader.GetInt32(1),
                (int)reader.GetInt64(2),
                (int)reader.GetInt64(3),
                (int)reader.GetInt64(4),
                (int)reader.GetInt64(5),
                (int)reader.GetInt64(6),
                reader.IsDBNull(7) ? null : reader.GetDecimal(7),
                reader.IsDBNull(8) ? null : reader.GetDecimal(8),
                reader.IsDBNull(9) ? 0 : reader.GetInt64(9),
                !reader.IsDBNull(10) && reader.GetBoolean(10),
                new Dictionary<string, int>(StringComparer.Ordinal));
        }

        await using var waits = Command(
            """
            SELECT COALESCE(a.wait_event_type, 'CPU'), count(*)
            FROM pg_stat_activity AS a
            WHERE a.backend_type = 'client backend' AND a.state = 'active' AND a.pid <> pg_backend_pid()
            GROUP BY 1
            ORDER BY 2 DESC, 1;
            """);
        var byWait = new Dictionary<string, int>(StringComparer.Ordinal);
        await using (var reader = await waits.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
        {
            while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                byWait[reader.GetString(0)] = (int)reader.GetInt64(1);
            }
        }

        return view with { ActiveByWaitEventType = byWait };
    }

    /// <summary>max_connections, the reserved slots, and the client connections open now: what connection-surge sizes itself by.</summary>
    public async Task<(int MaxConnections, int Reserved, int Open)> GetConnectionLimitsAsync(CancellationToken cancellationToken)
    {
        await using (var clear = Command("SELECT pg_stat_clear_snapshot();"))
        {
            await clear.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        await using var command = Command(
            """
            SELECT current_setting('max_connections')::integer,
                   current_setting('superuser_reserved_connections')::integer + COALESCE(NULLIF(current_setting('reserved_connections', true), '')::integer, 0),
                   (SELECT count(*) FROM pg_stat_activity AS a WHERE a.backend_type = 'client backend')::integer;
            """);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        await reader.ReadAsync(cancellationToken).ConfigureAwait(false);
        return (reader.GetInt32(0), reader.GetInt32(1), reader.GetInt32(2));
    }

    public async Task<int?> GetSeedScaleAsync(CancellationToken cancellationToken)
    {
        await using var command = Command("SELECT scale FROM demo.seed_state WHERE seed_state_id = 1 AND status = 'Completed';");
        return await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is int scale ? scale : null;
    }

    private NpgsqlCommand Command(string sql)
    {
        var command = connection.CreateCommand();
#pragma warning disable CA2100 // Every caller passes a constant; values travel as parameters.
        command.CommandText = sql;
#pragma warning restore CA2100
        command.CommandTimeout = ControlTimeoutSeconds;
        return command;
    }

    private static void Add<T>(NpgsqlCommand command, string name, T value) => command.Parameters.Add(new NpgsqlParameter<T>(name, value));

    private static void AddNullable(NpgsqlCommand command, string name, string? value) =>
        command.Parameters.Add(new NpgsqlParameter(name, NpgsqlTypes.NpgsqlDbType.Varchar) { Value = (object?)value ?? DBNull.Value });

    private static void AddNullable(NpgsqlCommand command, string name, int? value) =>
        command.Parameters.Add(new NpgsqlParameter(name, NpgsqlTypes.NpgsqlDbType.Integer) { Value = (object?)value ?? DBNull.Value });
}

/// <summary>One live demo session on T4, from pg_stat_activity.</summary>
internal sealed record PgDemoSession(
    int Pid,
    string ApplicationName,
    string State,
    bool OpenTransaction,
    int? BlockedBy,
    string? WaitEventType,
    string? WaitEvent,
    decimal? TransactionSeconds,
    decimal? StateSeconds);
