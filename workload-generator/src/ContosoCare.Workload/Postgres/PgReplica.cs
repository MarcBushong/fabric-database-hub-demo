using System.Globalization;
using System.Net.Sockets;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Sql;
using Npgsql;
using NpgsqlTypes;

namespace ContosoCare.Workload.Postgres;

/// <summary>What a statement over the demo's sessions on T4's read replica does (<see cref="PgReplicaSessions.Sql"/>).</summary>
internal enum ReplicaSignal
{
    /// <summary>Lists them.</summary>
    None,

    /// <summary>Cancels one session's statement (pg_cancel_backend).</summary>
    Cancel,

    /// <summary>Ends one session (pg_terminate_backend).</summary>
    Terminate,
}

/// <summary>Which of the demo's sessions on T4's read replica a stop, a reset, or a run's last check covers.</summary>
internal sealed record ReplicaSessionScope(string? RunId, string? ScenarioId, string Sessions, string NoneLeft)
{
    public static readonly ReplicaSessionScope All = new(null, null, "demo session(s)", "No demo sessions remain");

    public static ReplicaSessionScope Run(string runId) => SessionNames.IsValidRunId(runId)
        ? new(runId, null, "session(s) of run " + runId, "No session of run " + runId + " remains")
        : throw new ArgumentException("Not a run ID.", nameof(runId));

    public static ReplicaSessionScope Scenario(string scenarioId) => scenarioId.Length is > 0 and <= 64 && scenarioId.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-')
        ? new(null, scenarioId, scenarioId + " session(s)", "No " + scenarioId + " session remains")
        : throw new ArgumentException("Not a scenario ID.", nameof(scenarioId));

    /// <summary>A stop's scope: run, scenario, or all.</summary>
    public static ReplicaSessionScope ForStop(string scope, string? runId, string? scenarioId) => scope switch
    {
        "run" => Run(runId ?? string.Empty),
        "scenario" => Scenario(scenarioId ?? string.Empty),
        _ => All,
    };
}

/// <summary>T4's read replica in T4's status: whether it answered, whether it's in recovery, its replay lag, and the demo's sessions there.</summary>
internal sealed record PgReplicaView(string Fqdn, bool Reachable, bool? InRecovery, decimal? ReplayLagSeconds, long? MaxStandbyStreamingDelayMs, int? DemoSessionCount, string? Error);

/// <summary>
/// The demo's sessions on T4's read replica (ADR 0025). The replica is read-only, so the runner lists and signals them
/// with direct statements rather than T4's session functions, under the same rule as demo.fn_demo_sessions: this
/// database, tagged ContosoCare.Demo/ but never ContosoCare.Demo/control/, never the caller. It signals one session at a
/// time, each only while it still matches the rule.
/// Sources: https://www.postgresql.org/docs/current/hot-standby.html,
/// https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL
/// </summary>
internal static class PgReplicaSessions
{
    /// <summary>How long a stop or reset waits for cancelled sessions to close before it terminates them.</summary>
    public static readonly TimeSpan CancelWait = TimeSpan.FromSeconds(5);

    private const string Filter = """
        FROM pg_stat_activity AS a
        WHERE a.datname = current_database()
          AND a.backend_type = 'client backend'
          AND a.pid <> pg_backend_pid()
          AND a.application_name LIKE 'ContosoCare.Demo/%'
          AND a.application_name NOT LIKE 'ContosoCare.Demo/control/%'
          AND (@run_id::text IS NULL OR a.application_name LIKE 'ContosoCare.Demo/%/' || @run_id::text)
          AND (@scenario_id::text IS NULL OR a.application_name LIKE 'ContosoCare.Demo/' || @scenario_id::text || '/%')
        """;

    /// <summary>
    /// The statement for <paramref name="signal"/>: the demo's sessions on the replica (one run's with @run_id, one
    /// scenario's with @scenario_id), or one of them, @pid, signalled while it still matches. Pure.
    /// </summary>
    internal static string Sql(ReplicaSignal signal) => signal switch
    {
        ReplicaSignal.Cancel => "SELECT pg_cancel_backend(a.pid) AS signalled\n" + Filter + "\n  AND a.pid = @pid;",
        ReplicaSignal.Terminate => "SELECT pg_terminate_backend(a.pid) AS signalled\n" + Filter + "\n  AND a.pid = @pid;",
        _ => "SELECT a.pid\n" + Filter + "\nORDER BY a.pid;",
    };

    /// <summary>
    /// Ends the scope's sessions on the replica: each statement is cancelled first (pg_cancel_backend), and sessions still
    /// there after <see cref="CancelWait"/> are terminated (pg_terminate_backend). Never a Fail, and never an exception for
    /// a replica that doesn't answer: one whose name doesn't resolve (it exists only during a session) is Not selected; one
    /// that can't be reached, or a session it can't end, is a Warning, because each replica-lag report ends by its own
    /// statement_timeout before its run's deadline.
    /// </summary>
    public static async Task<CheckRecord> EndAsync(PgConnectionOpener replica, string checkId, ReplicaSessionScope scope, bool kill, TimeProvider time, CancellationToken cancellationToken)
    {
        var host = replica.Endpoint.Host;
        NpgsqlConnection connection;
        try
        {
            connection = await replica.OpenAsync(SessionNames.ForControl("replica"), cancellationToken, PgSessionLimits.Control, retry: false).ConfigureAwait(false);
        }
        catch (Exception ex) when (IsConnectFailure(ex) && !cancellationToken.IsCancellationRequested)
        {
            return IsHostNotFound(ex)
                ? new CheckRecord(checkId, "Not selected", $"T4's read replica ({host}) isn't there: its name doesn't resolve, so it has no {scope.Sessions} to end. It exists only during a session that start-demo.ps1 started with it.")
                : new CheckRecord(checkId, "Warning", $"T4's read replica ({host}) didn't answer, so its {scope.Sessions} weren't checked ({PgConnectionOpener.Describe(ex)}). Each replica-lag report ends by its own statement_timeout before its run's deadline.");
        }

        await using (connection.ConfigureAwait(false))
        {
            try
            {
                var sessions = await ListAsync(connection, scope, cancellationToken).ConfigureAwait(false);
                if (sessions.Count == 0)
                {
                    return new CheckRecord(checkId, "Pass", $"{scope.NoneLeft} on T4's read replica ({host}).");
                }

                if (!kill)
                {
                    return new CheckRecord(checkId, "Warning", string.Create(CultureInfo.InvariantCulture, $"{sessions.Count} {scope.Sessions} remain on T4's read replica ({host}), and --no-kill left them alone. Each replica-lag report ends by its own statement_timeout before its run's deadline."));
                }

                var (cancelled, cancelFailed) = await SignalAsync(connection, scope, sessions, ReplicaSignal.Cancel, cancellationToken).ConfigureAwait(false);
                var left = await WaitForEndAsync(connection, scope, CancelWait, time, cancellationToken).ConfigureAwait(false);
                var (terminated, terminateFailed) = (0, 0);
                if (left.Count > 0)
                {
                    (terminated, terminateFailed) = await SignalAsync(connection, scope, left, ReplicaSignal.Terminate, cancellationToken).ConfigureAwait(false);
                    left = await WaitForEndAsync(connection, scope, CancelWait, time, cancellationToken).ConfigureAwait(false);
                }

                var summary = cancelled + terminated == 0
                    ? "they closed on their own"
                    : string.Create(CultureInfo.InvariantCulture, $"{cancelled} statement(s) cancelled with pg_cancel_backend, then {terminated} session(s) ended with pg_terminate_backend");
                return left.Count == 0
                    ? new CheckRecord(checkId, "Pass", string.Create(CultureInfo.InvariantCulture, $"{sessions.Count} {scope.Sessions} on T4's read replica ({host}) ended: {summary}."))
                    : new CheckRecord(checkId, "Warning", string.Create(CultureInfo.InvariantCulture, $"{left.Count} of {sessions.Count} {scope.Sessions} on T4's read replica ({host}) are still there ({summary}; {Math.Max(cancelFailed, terminateFailed)} belong to another role). Each replica-lag report ends by its own statement_timeout before its run's deadline."));
            }
            catch (NpgsqlException ex) when (!cancellationToken.IsCancellationRequested)
            {
                return new CheckRecord(checkId, "Warning", $"T4's read replica ({host}) answered, but its {scope.Sessions} couldn't be checked ({PgConnectionOpener.Describe(ex)}). Each replica-lag report ends by its own statement_timeout before its run's deadline.");
            }
        }
    }

    /// <summary>The replica's block in T4's status: never an exception for a replica that doesn't answer.</summary>
    public static async Task<PgReplicaView> GetViewAsync(PgConnectionOpener replica, CancellationToken cancellationToken)
    {
        var host = replica.Endpoint.Host;
        var connected = false;
        try
        {
            await using var connection = await replica.OpenAsync(SessionNames.ForControl("status"), cancellationToken, PgSessionLimits.Control, retry: false).ConfigureAwait(false);
            connected = true;
            var state = await PgScenarioRunner.QueryRowAsync(connection, ReplicaLag.ReplicaStateSql, cancellationToken).ConfigureAwait(false);
            var sessions = await ListAsync(connection, ReplicaSessionScope.All, cancellationToken).ConfigureAwait(false);
            return new PgReplicaView(
                host,
                true,
                state.TryGetValue("in_recovery", out var recovering) ? recovering as bool? : null,
                state.TryGetValue("replay_lag_seconds", out var lag) ? lag as decimal? : null,
                state.TryGetValue("max_standby_streaming_delay_ms", out var delay) ? delay as long? : null,
                sessions.Count,
                null);
        }
        catch (Exception ex) when (IsConnectFailure(ex) && !cancellationToken.IsCancellationRequested)
        {
            var error = IsHostNotFound(ex) ? "Its name doesn't resolve: it exists only during a session that start-demo.ps1 started with it." : PgConnectionOpener.Describe(ex);
            return new PgReplicaView(host, connected, null, null, null, null, error);
        }
    }

    /// <summary>A failure to reach the replica or to read from it, as opposed to a cancellation or a bug.</summary>
    internal static bool IsConnectFailure(Exception exception) =>
        exception is NpgsqlException or SocketException or IOException or TimeoutException or InvalidOperationException or ScenarioRequestException or Azure.Identity.AuthenticationFailedException;

    /// <summary>True when the replica's name doesn't resolve: it's deleted between sessions (ADR 0025), or was never created.</summary>
    internal static bool IsHostNotFound(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current is SocketException { SocketErrorCode: SocketError.HostNotFound or SocketError.NoData })
            {
                return true;
            }
        }

        return false;
    }

    private static async Task<List<int>> ListAsync(NpgsqlConnection connection, ReplicaSessionScope scope, CancellationToken cancellationToken)
    {
        await using var command = Command(connection, ReplicaSignal.None, scope);
        var pids = new List<int>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            pids.Add(reader.GetInt32(0));
        }

        return pids;
    }

    private static async Task<(int Signalled, int Failed)> SignalAsync(NpgsqlConnection connection, ReplicaSessionScope scope, IEnumerable<int> pids, ReplicaSignal signal, CancellationToken cancellationToken)
    {
        var signalled = 0;
        var failed = 0;
        foreach (var pid in pids)
        {
            await using var command = Command(connection, signal, scope);
            command.Parameters.Add(new NpgsqlParameter<int>("pid", pid));
            try
            {
                if (await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is true)
                {
                    signalled++;
                }
            }
            catch (PostgresException ex) when (ex.SqlState == "42501")
            {
                // insufficient_privilege: another role's session, which only that role or pg_signal_backend can signal.
                failed++;
            }
        }

        return (signalled, failed);
    }

    private static async Task<List<int>> WaitForEndAsync(NpgsqlConnection connection, ReplicaSessionScope scope, TimeSpan wait, TimeProvider time, CancellationToken cancellationToken)
    {
        var until = time.GetUtcNow() + wait;
        List<int> left;
        do
        {
            await Task.Delay(TimeSpan.FromMilliseconds(500), time, cancellationToken).ConfigureAwait(false);
            left = await ListAsync(connection, scope, cancellationToken).ConfigureAwait(false);
        }
        while (left.Count > 0 && time.GetUtcNow() < until);

        return left;
    }

    private static NpgsqlCommand Command(NpgsqlConnection connection, ReplicaSignal signal, ReplicaSessionScope scope)
    {
        var command = connection.CreateCommand();
        command.CommandText = Sql(signal);
        command.CommandTimeout = 30;
        command.Parameters.Add(new NpgsqlParameter("run_id", NpgsqlDbType.Text) { Value = (object?)scope.RunId ?? DBNull.Value });
        command.Parameters.Add(new NpgsqlParameter("scenario_id", NpgsqlDbType.Text) { Value = (object?)scope.ScenarioId ?? DBNull.Value });
        return command;
    }
}
