using System.Data;
using System.Globalization;
using ContosoCare.Workload.Catalog;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Sql;

internal sealed record RunRegistration(DateTimeOffset DeadlineAt, int EffectiveDurationSeconds);

internal sealed record RunEvent(DateTimeOffset At, string Name, int? SessionId, string? Detail);

internal sealed record ResetOptions(string RequestedBy, int WaitSeconds, bool KillSessions, bool KeepProfile, bool UndoRemediation, bool Reseed);

/// <summary>One row from demo.usp_reset or a runner check, with an ADR 0012 status.</summary>
internal sealed record CheckRecord(string CheckId, string Status, string Message);

internal sealed record KillSummary(bool CanViewSessions, int Killed, int Failed);

internal sealed record RunRecord(
    string RunId,
    string ScenarioId,
    string Target,
    string Status,
    DateTimeOffset StartedAt,
    DateTimeOffset DeadlineAt,
    DateTimeOffset? StoppedAt,
    int MaxDurationSeconds,
    int Concurrency,
    int Intensity,
    string? Outcome,
    string? ProfileName,
    string? RequestedBy);

internal sealed record DemoSession(int SessionId, string ProgramName, string Status, int OpenTransactions, int? BlockingSessionId, string? WaitType);

internal sealed record SpaceHeadroom(int? DataHeadroomMb, int? LogHeadroomMb);

internal sealed record StopFlag(string ScenarioId, DateTimeOffset? RequestedAt, string? RequestedBy);

/// <summary>Typed calls to the demo schema's control procedures (database/common/110-demo-control.sql).</summary>
internal sealed class DemoDatabase(SqlConnection connection)
{
    private const int ControlTimeoutSeconds = 60;

    public SqlConnection Connection => connection;

    public async Task<RunRegistration> BeginRunAsync(
        string runId,
        string scenarioId,
        DemoTarget target,
        int durationSeconds,
        int concurrency,
        int intensity,
        string parametersJson,
        string expectedSymptoms,
        string requestedBy,
        string? profileName,
        CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_run_begin");
        Add(command, "@run_id", SqlDbType.VarChar, runId, 64);
        Add(command, "@scenario_id", SqlDbType.VarChar, scenarioId, 64);
        Add(command, "@target", SqlDbType.VarChar, target.ToString(), 8);
        Add(command, "@duration_seconds", SqlDbType.Int, durationSeconds);
        Add(command, "@concurrency", SqlDbType.Int, concurrency);
        Add(command, "@intensity", SqlDbType.TinyInt, (byte)intensity);
        Add(command, "@parameters", SqlDbType.NVarChar, Truncate(parametersJson, 2000), 2000);
        Add(command, "@expected_symptoms", SqlDbType.NVarChar, Truncate(expectedSymptoms, 400), 400);
        Add(command, "@requested_by", SqlDbType.NVarChar, Truncate(requestedBy, 128), 128);
        Add(command, "@runner_host", SqlDbType.NVarChar, Truncate(Environment.MachineName, 128), 128);
        Add(command, "@profile_name", SqlDbType.VarChar, (object?)profileName ?? DBNull.Value, 64);
        var deadline = Output(command, "@deadline_at", SqlDbType.DateTime2);
        deadline.Scale = 3;
        var effective = Output(command, "@effective_duration_seconds", SqlDbType.Int);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        return new RunRegistration(AsUtc((DateTime)deadline.Value), (int)effective.Value);
    }

    public async Task RecordEventAsync(string runId, RunEvent runEvent, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_run_event");
        Add(command, "@run_id", SqlDbType.VarChar, runId, 64);
        Add(command, "@event_name", SqlDbType.VarChar, Truncate(runEvent.Name, 40), 40);
        Add(command, "@session_id", SqlDbType.Int, (object?)runEvent.SessionId ?? DBNull.Value);
        Add(command, "@detail", SqlDbType.NVarChar, NullableText(runEvent.Detail, 400), 400);
        var at = Add(command, "@event_time", SqlDbType.DateTime2, runEvent.At.UtcDateTime);
        at.Scale = 3;
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task EndRunAsync(string runId, string status, string? outcome, string? sessionIds, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_run_end");
        Add(command, "@run_id", SqlDbType.VarChar, runId, 64);
        Add(command, "@status", SqlDbType.VarChar, status, 20);
        Add(command, "@outcome", SqlDbType.NVarChar, NullableText(outcome, 1000), 1000);
        Add(command, "@session_ids", SqlDbType.VarChar, NullableText(sessionIds, 400), 400);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> IsStopRequestedAsync(string runId, CancellationToken cancellationToken)
    {
        await using var command = Text("SELECT demo.fn_run_stop_requested(@run_id);");
        Add(command, "@run_id", SqlDbType.VarChar, runId, 64);
        var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
        return value is bool flag && flag;
    }

    /// <summary>demo.usp_stop: scope <c>run</c>, <c>scenario</c>, or <c>all</c>. Returns how many Running runs were marked Cancelled.</summary>
    public async Task<int> StopAsync(string scope, string? runId, string? scenarioId, string requestedBy, bool setProfileOff, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_stop");
        Add(command, "@scope", SqlDbType.VarChar, scope, 10);
        Add(command, "@run_id", SqlDbType.VarChar, (object?)runId ?? DBNull.Value, 64);
        Add(command, "@scenario_id", SqlDbType.VarChar, (object?)scenarioId ?? DBNull.Value, 64);
        Add(command, "@requested_by", SqlDbType.NVarChar, Truncate(requestedBy, 128), 128);
        Add(command, "@set_profile_off", SqlDbType.Bit, setProfileOff);
        Add(command, "@return_results", SqlDbType.Bit, false);
        var cancelled = Output(command, "@runs_cancelled", SqlDbType.Int);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        return cancelled.Value is int count ? count : 0;
    }

    public async Task<IReadOnlyList<CheckRecord>> ResetAsync(ResetOptions options, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_reset");
        command.CommandTimeout = (options.WaitSeconds * 3) + 600;
        Add(command, "@requested_by", SqlDbType.NVarChar, Truncate(options.RequestedBy, 128), 128);
        Add(command, "@wait_seconds", SqlDbType.Int, options.WaitSeconds);
        Add(command, "@kill_sessions", SqlDbType.Bit, options.KillSessions);
        Add(command, "@keep_profile", SqlDbType.Bit, options.KeepProfile);
        Add(command, "@undo_remediation", SqlDbType.Bit, options.UndoRemediation);
        Add(command, "@reseed", SqlDbType.Bit, options.Reseed);
        var checks = new List<CheckRecord>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            checks.Add(new CheckRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2)));
        }

        return checks;
    }

    /// <summary>The server-side watchdog backstop: KILL for this run's ContosoCare.Demo/ sessions only (demo.usp_kill_demo_sessions).</summary>
    public async Task<KillSummary> KillRunSessionsAsync(string? runId, bool pastDeadlineOnly, string requestedBy, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_kill_demo_sessions");
        Add(command, "@run_id", SqlDbType.VarChar, (object?)runId ?? DBNull.Value, 64);
        Add(command, "@past_deadline_only", SqlDbType.Bit, pastDeadlineOnly);
        Add(command, "@requested_by", SqlDbType.NVarChar, Truncate(requestedBy, 128), 128);
        Add(command, "@return_results", SqlDbType.Bit, false);
        var killed = Output(command, "@killed", SqlDbType.Int);
        var failed = Output(command, "@failed", SqlDbType.Int);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        var canView = failed.Value is not DBNull;
        return new KillSummary(canView, killed.Value is int k ? k : 0, failed.Value is int f ? f : 0);
    }

    public async Task<ProfileState> GetProfileAsync(CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_profile_get");
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            return ProfileState.Off(DateTimeOffset.UtcNow);
        }

        var parameters = reader.IsDBNull(4) ? null : ProfileParametersJson.Parse(reader.GetString(4));
        return new ProfileState(
            reader.GetString(0),
            AsUtc(reader.GetDateTime(1)),
            reader.GetString(2),
            reader.IsDBNull(3) ? null : AsUtc(reader.GetDateTime(3)),
            parameters);
    }

    public async Task SetProfileAsync(string profileName, string setBy, DateTimeOffset? expiresAt, ProfileParameters? parameters, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_profile_set");
        Add(command, "@profile_name", SqlDbType.VarChar, profileName, 64);
        Add(command, "@set_by", SqlDbType.NVarChar, Truncate(setBy, 128), 128);
        var expires = Add(command, "@expires_at", SqlDbType.DateTime2, expiresAt is { } at ? at.UtcDateTime : (object)DBNull.Value);
        expires.Scale = 3;
        Add(command, "@parameters", SqlDbType.NVarChar, parameters is null ? DBNull.Value : (object)Truncate(ProfileParametersJson.Serialize(parameters), 2000), 2000);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<RunRecord>> GetRunsAsync(int count, bool runningOnly, CancellationToken cancellationToken)
    {
        await using var command = Text(
            """
            SELECT TOP (@count) run_id, scenario_id, target, status, started_at, deadline_at, stopped_at, max_duration_seconds,
                concurrency, intensity, outcome, profile_name, requested_by
            FROM demo.scenario_runs
            WHERE @running_only = 0 OR status = 'Running'
            ORDER BY started_at DESC;
            """);
        Add(command, "@count", SqlDbType.Int, count);
        Add(command, "@running_only", SqlDbType.Bit, runningOnly);
        var runs = new List<RunRecord>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            runs.Add(new RunRecord(
                reader.GetString(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetString(3),
                AsUtc(reader.GetDateTime(4)),
                AsUtc(reader.GetDateTime(5)),
                reader.IsDBNull(6) ? null : AsUtc(reader.GetDateTime(6)),
                reader.GetInt32(7),
                reader.GetInt32(8),
                reader.GetByte(9),
                reader.IsDBNull(10) ? null : reader.GetString(10),
                reader.IsDBNull(11) ? null : reader.GetString(11),
                reader.IsDBNull(12) ? null : reader.GetString(12)));
        }

        return runs;
    }

    /// <summary>Live demo sessions in ContosoCare (all runs, or one), or null when the caller can't see other sessions.</summary>
    public async Task<IReadOnlyList<DemoSession>?> GetDemoSessionsAsync(string? runId, CancellationToken cancellationToken)
    {
        await using (var check = Text("SELECT demo.fn_can_view_sessions();"))
        {
            if (await check.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is not true)
            {
                return null;
            }
        }

        await using var command = Text(
            """
            SELECT session_id, program_name, status, open_transaction_count, blocking_session_id, wait_type
            FROM demo.fn_demo_sessions(@run_id)
            ORDER BY session_id;
            """);
        Add(command, "@run_id", SqlDbType.VarChar, (object?)runId ?? DBNull.Value, 64);
        var sessions = new List<DemoSession>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            sessions.Add(new DemoSession(
                reader.GetInt16(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetInt32(3),
                reader.IsDBNull(4) ? null : reader.GetInt16(4),
                reader.IsDBNull(5) ? null : reader.GetString(5)));
        }

        return sessions;
    }

    public async Task<IReadOnlyList<StopFlag>> GetStopFlagsAsync(CancellationToken cancellationToken)
    {
        await using var command = Text("SELECT scenario_id, stop_requested_at, stop_requested_by FROM demo.scenario_control WHERE stop_requested = 1 ORDER BY scenario_id;");
        var flags = new List<StopFlag>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            flags.Add(new StopFlag(reader.GetString(0), reader.IsDBNull(1) ? null : AsUtc(reader.GetDateTime(1)), reader.IsDBNull(2) ? null : reader.GetString(2)));
        }

        return flags;
    }

    public async Task<SpaceHeadroom> GetSpaceAsync(CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_check_space");
        Add(command, "@raise", SqlDbType.Bit, false);
        var data = Output(command, "@data_headroom_mb", SqlDbType.Int);
        var log = Output(command, "@log_headroom_mb", SqlDbType.Int);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        return new SpaceHeadroom(data.Value as int?, log.Value as int?);
    }

    /// <summary>Paths of ContosoCare's files (catalog view sys.database_files, visible to any database user).</summary>
    public async Task<IReadOnlyList<string>> GetFilePathsAsync(CancellationToken cancellationToken)
    {
        await using var command = Text("SELECT physical_name FROM sys.database_files WHERE type IN (0, 1);");
        var paths = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            paths.Add(reader.GetString(0));
        }

        return paths;
    }

    /// <summary>demo.usp_cleanup_scenario: empties the scenario's scratch data after a run (auto-cleanup).</summary>
    public async Task<CheckRecord> CleanupScenarioAsync(string scenarioId, CancellationToken cancellationToken)
    {
        await using var command = Procedure("demo.usp_cleanup_scenario");
        Add(command, "@scenario_id", SqlDbType.VarChar, scenarioId, 64);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
            ? new CheckRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2))
            : new CheckRecord("auto-cleanup", "Not selected", "Nothing to clean up.");
    }

    /// <summary>
    /// Ends the runs that an earlier profile host on this machine started and left Running when it was stopped (a task
    /// restart, a redeploy), so their scenarios can run again at once instead of after their deadline (Phase 25b; Phase
    /// 25a's 50108 refusals right after host restarts). Only runs that a profile requested, that this machine registered,
    /// that started before <paramref name="startedBefore"/>, and that have no live session. Returns their run IDs, or
    /// null without touching anything when the caller can't see other sessions.
    /// </summary>
    public async Task<IReadOnlyList<string>?> RecoverOrphanedProfileRunsAsync(string runnerHost, DateTimeOffset startedBefore, CancellationToken cancellationToken)
    {
        await using (var check = Text("SELECT demo.fn_can_view_sessions();"))
        {
            if (await check.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is not true)
            {
                return null;
            }
        }

        var orphans = new List<string>();
        await using (var command = Text(
            """
            SELECT r.run_id
            FROM demo.scenario_runs AS r
            WHERE r.status = 'Running'
              AND r.runner_host = @runner_host
              AND r.requested_by LIKE N'profile:%'
              AND r.started_at < @started_before
              AND NOT EXISTS (SELECT 1 FROM demo.fn_demo_sessions(r.run_id))
            ORDER BY r.started_at;
            """))
        {
            Add(command, "@runner_host", SqlDbType.NVarChar, Truncate(runnerHost, 128), 128);
            var before = Add(command, "@started_before", SqlDbType.DateTime2, startedBefore.UtcDateTime);
            before.Scale = 3;
            await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                orphans.Add(reader.GetString(0));
            }
        }

        foreach (var runId in orphans)
        {
            await EndRunAsync(runId, "Cancelled", "Recovered: the profile host that started it stopped (a task restart or a redeploy) before it recorded the end, and none of its sessions remain.", null, cancellationToken).ConfigureAwait(false);
        }

        return orphans;
    }

    internal static DateTimeOffset AsUtc(DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));

    private SqlCommand Procedure(string name)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = name;
        command.CommandTimeout = ControlTimeoutSeconds;
        return command;
    }

    private SqlCommand Text(string sql)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.Text;
        command.CommandText = sql;
        command.CommandTimeout = ControlTimeoutSeconds;
        return command;
    }

    private static SqlParameter Add(SqlCommand command, string name, SqlDbType type, object value, int size = 0)
    {
        var parameter = command.Parameters.Add(name, type);
        if (size > 0)
        {
            parameter.Size = size;
        }

        parameter.Value = value;
        return parameter;
    }

    private static SqlParameter Output(SqlCommand command, string name, SqlDbType type)
    {
        var parameter = command.Parameters.Add(name, type);
        parameter.Direction = ParameterDirection.Output;
        return parameter;
    }

    internal static string Truncate(string value, int length) => value.Length <= length ? value : value[..length];

    internal static object NullableText(string? value, int length) => value is null ? DBNull.Value : (object)Truncate(value, length);

    internal static string Format(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);
}
