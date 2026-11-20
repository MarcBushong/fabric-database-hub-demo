using System.Data;
using System.Globalization;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// T1, T2, and T3: the runner's existing sign-in (Windows authentication on T1 and T2, T1's managed identity on T3),
/// with the observer's own application name, so demo.fn_demo_sessions and the kill tools never list or end it.
/// </summary>
internal sealed class SqlCaptureConnector(TargetEndpoint endpoint, RunnerLog log) : ICaptureConnector
{
    // Permission denied on a server or database permission, an object, or a DMV (VIEW SERVER PERFORMANCE STATE,
    // VIEW DATABASE STATE, CREATE or ALTER ANY EVENT SESSION): 297, 300, 262, 229, 230, 15151, 15247, 916.
    private static readonly HashSet<int> PermissionErrors = [297, 300, 262, 229, 230, 15151, 15247, 916];

    // The client's command timeout (-2) and a lock timeout (1222, LOCK_TIMEOUT 1000).
    private static readonly HashSet<int> TimeoutErrors = [-2, 1222];

    public string Description => endpoint.Describe();

    public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
    {
        try
        {
            var connection = await new SqlConnectionOpener(endpoint, log).OpenAsync(ApplicationNames.Observer, cancellationToken).ConfigureAwait(false);
            return new SqlCaptureConnection(connection);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            throw Translate(ex, connecting: true);
        }
    }

    internal static CaptureException Translate(Exception exception, bool connecting) => exception switch
    {
        CaptureException capture => capture,
        SqlException sql when sql.Errors.Cast<SqlError>().Any(e => PermissionErrors.Contains(e.Number)) || PermissionErrors.Contains(sql.Number) =>
            new CaptureException(CaptureFailureKind.Permission, Describe(sql), sql),
        SqlException sql when !connecting && TimeoutErrors.Contains(sql.Number) =>
            new CaptureException(CaptureFailureKind.Timeout, Describe(sql), sql),
        SqlException sql when connecting || sql.Class >= 20 || SqlConnectionOpener.IsTransient(sql) =>
            new CaptureException(CaptureFailureKind.Connection, Describe(sql), sql),
        SqlException sql => new CaptureException(CaptureFailureKind.Other, Describe(sql), sql),
        TimeoutException or InvalidOperationException or IOException => new CaptureException(CaptureFailureKind.Connection, Redactor.Redact(exception.GetType().Name + ": " + exception.Message), exception),
        Azure.Identity.AuthenticationFailedException or Azure.Identity.CredentialUnavailableException => new CaptureException(CaptureFailureKind.Connection, Redactor.Redact(exception.GetType().Name + ": " + exception.Message), exception),
        OperationCanceledException => new CaptureException(CaptureFailureKind.Timeout, "The statement was cancelled at its timeout.", exception),
        _ => new CaptureException(CaptureFailureKind.Other, Redactor.Redact(exception.GetType().Name + ": " + exception.Message), exception),
    };

    private static string Describe(SqlException exception) => Redactor.Redact(string.Create(CultureInfo.InvariantCulture, $"SQL error {exception.Number}: {exception.Message}"));

    private sealed class SqlCaptureConnection(SqlConnection connection) : ICaptureConnection
    {
        public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken)
        {
            try
            {
                await using var command = connection.CreateCommand();
                command.CommandType = CommandType.Text;
#pragma warning disable CA2100 // The text is a block of the runner's embedded capture catalog (rca/capture), never user input.
                command.CommandText = text;
#pragma warning restore CA2100
                command.CommandTimeout = Math.Max(1, (int)Math.Ceiling(timeout.TotalSeconds));
                var rows = new List<CaptureValues>();
                await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
                do
                {
                    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
                    {
                        var values = new Dictionary<string, object?>(reader.FieldCount, StringComparer.OrdinalIgnoreCase);
                        for (var i = 0; i < reader.FieldCount; i++)
                        {
                            values[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                        }

                        rows.Add(new CaptureValues(values));
                    }
                }
                while (await reader.NextResultAsync(cancellationToken).ConfigureAwait(false));
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
