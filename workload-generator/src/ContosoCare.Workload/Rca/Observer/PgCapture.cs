using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using Npgsql;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// T4 and its read replica: the runner's existing sign-in (T1's managed identity as contosocare_runner, or the local
/// test role), with the observer's own application name, a 1-second lock_timeout, and a 10-second statement_timeout.
/// Every block runs after pg_stat_clear_snapshot() in the same round trip, so no statistics view repeats an earlier
/// snapshot (rca/capture/postgresql.sql; https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-STATS-FUNCTIONS).
/// Every connection opens silently (<see cref="Startup"/>): its search_path, which names <see cref="ObserverSchema"/>,
/// and its limits come in its startup packet, and Npgsql loads no types for it (each block returns PostgreSQL's built-in
/// types only), so it sends nothing but the catalog's blocks and the snapshot clear before each. Query Store records each
/// statement's search_path (query_store.qs_view), and RCA-PG-14 leaves out the observer's own statements by it, and by
/// their text (rca/README.md, What the capture leaves out).
/// </summary>
internal sealed class PgCaptureConnector(PgEndpoint endpoint, RunnerLog log, PgSessionLimits? limits = null) : ICaptureConnector
{
    /// <summary>The observer never waits behind what it observes: a 1-second lock timeout, 10 seconds per statement.</summary>
    internal static readonly PgSessionLimits Limits = new(10_000, 1_000, 60_000);

    /// <summary>azure_sys's reads aggregate Query Store's intervals: 30 seconds per statement, still a 1-second lock timeout.</summary>
    internal static readonly PgSessionLimits QueryStoreLimits = new(30_000, 1_000, 60_000);

    /// <summary>The database where Query Store's views are (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store).</summary>
    public const string QueryStoreDatabase = "azure_sys";

    /// <summary>
    /// A schema that exists nowhere, last in the observer's search_path, so names resolve as before (PostgreSQL ignores a
    /// schema that doesn't exist: https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-SEARCH-PATH).
    /// </summary>
    public const string ObserverSchema = "dbhubdemo_rca_observer";

    /// <summary>
    /// The observer's search_path, a server option in its connections' startup packet, and only theirs (Npgsql's Options,
    /// libpq's options): the server's default, <c>"$user", public</c>, with <see cref="ObserverSchema"/> last. A space in a
    /// value is escaped with a backslash (https://www.postgresql.org/docs/18/libpq-connect.html#LIBPQ-CONNECT-OPTIONS).
    /// </summary>
    internal const string SearchPathOption = """-c search_path="$user",\ public,\ """ + ObserverSchema;

    /// <summary>How every observer connection opens: <see cref="SearchPathOption"/> and its limits in the startup packet, and no type loading.</summary>
    internal static readonly PgSilentStartup Startup = new(SearchPathOption);

    /// <summary>What every block runs after, in the same round trip, so no statistics view repeats an earlier snapshot.</summary>
    internal const string ClearSnapshot = "SELECT pg_stat_clear_snapshot()";

    // insufficient_privilege.
    private static readonly HashSet<string> PermissionStates = ["42501"];

    // query_canceled (statement_timeout) and lock_not_available (lock_timeout), as PostgreSQL's error codes name them:
    // https://www.postgresql.org/docs/18/errcodes-appendix.html and https://www.postgresql.org/docs/18/runtime-config-client.html
    private static readonly HashSet<string> TimeoutStates = ["57014", "55P03"];

    public string Description => endpoint.Describe();

    /// <summary>T4's azure_sys, for Query Store's reads (RCA-PG-14 and 15): the same server, sign-in, and application name.</summary>
    public static PgCaptureConnector QueryStore(PgEndpoint endpoint, RunnerLog log) =>
        new(endpoint with { Database = QueryStoreDatabase }, log, QueryStoreLimits);

    public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
    {
        try
        {
            // One attempt: the observer's own loop tries again later, so a replica that doesn't exist yet costs one connect.
            var connection = await new PgConnectionOpener(endpoint, log).OpenAsync(ApplicationNames.Observer, cancellationToken, limits ?? Limits, retry: false, Startup).ConfigureAwait(false);
            return new PgCaptureConnection(connection);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            throw Translate(ex, connecting: true);
        }
    }

    internal static CaptureException Translate(Exception exception, bool connecting) => exception switch
    {
        CaptureException capture => capture,
        PostgresException postgres when PermissionStates.Contains(postgres.SqlState) => new CaptureException(CaptureFailureKind.Permission, PgConnectionOpener.Describe(postgres), postgres),
        PostgresException postgres when !connecting && TimeoutStates.Contains(postgres.SqlState) => new CaptureException(CaptureFailureKind.Timeout, PgConnectionOpener.Describe(postgres), postgres),
        PostgresException postgres when connecting || postgres.SqlState.StartsWith("08", StringComparison.Ordinal) || PgConnectionOpener.IsTransient(postgres) =>
            new CaptureException(CaptureFailureKind.Connection, PgConnectionOpener.Describe(postgres), postgres),
        PostgresException postgres => new CaptureException(CaptureFailureKind.Other, PgConnectionOpener.Describe(postgres), postgres),
        NpgsqlException npgsql when !connecting && npgsql.InnerException is TimeoutException => new CaptureException(CaptureFailureKind.Timeout, PgConnectionOpener.Describe(npgsql), npgsql),
        NpgsqlException or TimeoutException or InvalidOperationException or IOException or System.Net.Sockets.SocketException =>
            new CaptureException(CaptureFailureKind.Connection, PgConnectionOpener.Describe(exception), exception),
        Azure.Identity.AuthenticationFailedException or Azure.Identity.CredentialUnavailableException => new CaptureException(CaptureFailureKind.Connection, PgConnectionOpener.Describe(exception), exception),
        OperationCanceledException => new CaptureException(CaptureFailureKind.Timeout, "The statement was cancelled at its timeout.", exception),
        _ => new CaptureException(CaptureFailureKind.Other, PgConnectionOpener.Describe(exception), exception),
    };

    private sealed class PgCaptureConnection(NpgsqlConnection connection) : ICaptureConnection
    {
        public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken) =>
            // RCA-PG-11's $1: a positional parameter, so the block runs exactly as the catalog has it.
            RunAsync(text, parameter is null ? CaptureParameters.None : CaptureParameters.Positional(parameter), timeout, cancellationToken);

        public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken) =>
            parameters.IsNamed
                ? throw new NotSupportedException($"{blockId} is PostgreSQL's, whose parameters are bound by position.")
                : RunAsync(text, parameters, timeout, cancellationToken);

        public ValueTask DisposeAsync() => connection.DisposeAsync();

        private async Task<IReadOnlyList<CaptureValues>> RunAsync(string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken)
        {
            try
            {
                await using var batch = new NpgsqlBatch(connection) { Timeout = Math.Max(1, (int)Math.Ceiling(timeout.TotalSeconds)) };
                batch.BatchCommands.Add(new NpgsqlBatchCommand(ClearSnapshot));
                var command = new NpgsqlBatchCommand(text);
                foreach (var parameter in parameters)
                {
                    command.Parameters.Add(new NpgsqlParameter { Value = parameter.Value is DateTimeOffset time ? time.ToUniversalTime() : parameter.Value ?? DBNull.Value });
                }

                batch.BatchCommands.Add(command);
                var rows = new List<CaptureValues>();
                await using var reader = await batch.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
                if (!await reader.NextResultAsync(cancellationToken).ConfigureAwait(false))
                {
                    return rows;
                }

                while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
                {
                    var values = new Dictionary<string, object?>(reader.FieldCount, StringComparer.OrdinalIgnoreCase);
                    for (var i = 0; i < reader.FieldCount; i++)
                    {
                        values[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                    }

                    rows.Add(new CaptureValues(values));
                }

                return rows;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                throw Translate(ex, connecting: false);
            }
        }
    }
}
