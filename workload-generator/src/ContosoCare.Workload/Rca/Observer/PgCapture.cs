using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using Npgsql;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// T4 and its read replica: the runner's existing sign-in (T1's managed identity as contosocare_runner, or the local
/// test role), with the observer's own application name, a 1-second lock_timeout, and a 10-second statement_timeout.
/// Every block runs after pg_stat_clear_snapshot() in the same round trip, so no statistics view repeats an earlier
/// snapshot (rca/capture/postgresql.sql).
/// </summary>
internal sealed class PgCaptureConnector(PgEndpoint endpoint, RunnerLog log) : ICaptureConnector
{
    /// <summary>The observer never waits behind what it observes: a 1-second lock timeout, 10 seconds per statement.</summary>
    internal static readonly PgSessionLimits Limits = new(10_000, 1_000, 60_000);

    // insufficient_privilege.
    private static readonly HashSet<string> PermissionStates = ["42501"];

    // query_canceled (statement_timeout) and lock_not_available (lock_timeout).
    private static readonly HashSet<string> TimeoutStates = ["57014", "55P03"];

    public string Description => endpoint.Describe();

    public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
    {
        try
        {
            // One attempt: the observer's own loop tries again later, so a replica that doesn't exist yet costs one connect.
            var connection = await new PgConnectionOpener(endpoint, log).OpenAsync(ApplicationNames.Observer, cancellationToken, Limits, retry: false).ConfigureAwait(false);
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
        public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken)
        {
            try
            {
                await using var batch = new NpgsqlBatch(connection) { Timeout = Math.Max(1, (int)Math.Ceiling(timeout.TotalSeconds)) };
                batch.BatchCommands.Add(new NpgsqlBatchCommand("SELECT pg_stat_clear_snapshot()"));
                var command = new NpgsqlBatchCommand(text);
                if (parameter is not null)
                {
                    // RCA-PG-11's $1: a positional parameter, so the block runs exactly as the catalog has it.
                    command.Parameters.Add(new NpgsqlParameter { Value = parameter });
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

        public ValueTask DisposeAsync() => connection.DisposeAsync();
    }
}
