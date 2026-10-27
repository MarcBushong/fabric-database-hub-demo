using System.Globalization;
using Azure.Core;
using Azure.Identity;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using Npgsql;

namespace ContosoCare.Workload.Postgres;

internal enum PgAuthMode
{
    /// <summary>T4: a Microsoft Entra access token from the VM's managed identity is the password (Phase 24, ADR 0019).</summary>
    ManagedIdentity,

    /// <summary>Local PostgreSQL tests only: user name and password come from environment variables, never from arguments.</summary>
    PasswordFromEnvironment,
}

/// <summary>
/// Where and how the runner connects to T4. Holds no secret: the managed identity's token is fetched when a connection
/// opens and lives only in that connection's settings, and the local-test password is read from the environment.
/// </summary>
internal sealed record PgEndpoint(string Host, string Database, string User, PgAuthMode Auth, string? ManagedIdentityClientId = null, int Port = 5432)
{
    /// <summary>The only database the runner ever connects to on T4 (role setup alone uses postgres).</summary>
    public const string DatabaseName = "contosocare";

    /// <summary>The PostgreSQL role mapped to T1's managed identity that runs the scenarios (config/versions.json postgresql.runnerRole).</summary>
    public const string RunnerRole = "contosocare_runner";

    /// <summary>The Microsoft Entra resource whose tokens Azure Database for PostgreSQL accepts.</summary>
    public const string TokenScope = "https://ossrdbms-aad.database.windows.net/.default";

    public const string UserVariable = "CONTOSOCARE_PG_USER";
    public const string PasswordVariable = "CONTOSOCARE_PG_PASSWORD";

    public static PgEndpoint Create(string? server, string? user, bool passwordFromEnvironment, string? managedIdentityClientId)
    {
        if (string.IsNullOrWhiteSpace(server))
        {
            throw new ScenarioRequestException("T4 needs --server, the flexible server's name or FQDN (for example pgflex01-abc123.postgres.database.azure.com).");
        }

        var text = server.Trim();
        var port = 5432;
        var separator = text.LastIndexOf(':');
        if (separator > 0 && int.TryParse(text[(separator + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) && parsed is > 0 and < 65536)
        {
            port = parsed;
            text = text[..separator];
        }

        if (!IsHostName(text))
        {
            throw new ScenarioRequestException("--server must be a host name such as pgflex01-abc123.postgres.database.azure.com.");
        }

        if (passwordFromEnvironment)
        {
            return new PgEndpoint(text, DatabaseName, string.Empty, PgAuthMode.PasswordFromEnvironment, null, port);
        }

        if (!text.Contains('.', StringComparison.Ordinal))
        {
            text += ".postgres.database.azure.com";
        }

        if (managedIdentityClientId is not null && !Guid.TryParse(managedIdentityClientId, out _))
        {
            throw new ScenarioRequestException("--managed-identity-client-id must be the client ID (a GUID) of a user-assigned identity.");
        }

        var role = string.IsNullOrWhiteSpace(user) ? RunnerRole : user.Trim();
        if (!IsRoleName(role))
        {
            throw new ScenarioRequestException("--user must be a PostgreSQL role name: up to 63 letters, digits, spaces, and ._()- characters.");
        }

        return new PgEndpoint(text.ToLowerInvariant(), DatabaseName, role, PgAuthMode.ManagedIdentity, managedIdentityClientId, port);
    }

    /// <summary>The same server and identity, signed in as another role or to another database (setup's admin and role steps).</summary>
    public PgEndpoint WithUser(string user, string? database = null) => this with { User = user, Database = database ?? Database };

    /// <summary>A description that's safe to log (no credentials exist in this record).</summary>
    public string Describe() => string.Create(CultureInfo.InvariantCulture, $"T4 {Host}/{Database} as {(User.Length > 0 ? User : "(environment)")} ({Auth})");

    internal static bool IsHostName(string value) =>
        value.Length is > 0 and <= 253
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-')
        && value[0] != '.' && value[0] != '-';

    /// <summary>Entra group display names can hold spaces and punctuation; the runner always quotes role names.</summary>
    internal static bool IsRoleName(string value) =>
        value.Length is > 0 and <= 63
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is ' ' or '_' or '-' or '.' or '(' or ')')
        && value.Trim().Length == value.Length;
}

/// <summary>
/// Managed identity tokens for Azure Database for PostgreSQL, reused until five minutes before they expire. Two
/// sessions that open at the same moment may each ask for one; the credential's own cache answers the second.
/// </summary>
internal sealed class PgTokenProvider(string? managedIdentityClientId)
{
    private readonly ManagedIdentityCredential credential = managedIdentityClientId is null
        ? new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)
        : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(managedIdentityClientId));

    private volatile CachedToken? cached;

    public async ValueTask<string> GetAsync(CancellationToken cancellationToken)
    {
        if (cached is { } current && current.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(5))
        {
            return current.Token;
        }

        var token = await credential.GetTokenAsync(new TokenRequestContext([PgEndpoint.TokenScope]), cancellationToken).ConfigureAwait(false);
        cached = new CachedToken(token.Token, token.ExpiresOn);
        return token.Token;
    }

    private sealed record CachedToken(string Token, DateTimeOffset ExpiresOn);
}

/// <summary>Per-session limits in milliseconds (0 means none). Every scenario session gets limits that end before its run's hard deadline.</summary>
internal sealed record PgSessionLimits(long StatementTimeoutMs, long LockTimeoutMs, long IdleInTransactionTimeoutMs)
{
    /// <summary>Control sessions: bookkeeping, status, reset. Short statements; reset's waits happen in the runner, not the server.</summary>
    public static readonly PgSessionLimits Control = new(120_000, 30_000, 60_000);

    /// <summary>Setup: the seed and DDL can take a few minutes on a Burstable server.</summary>
    public static readonly PgSessionLimits Setup = new(1_800_000, 120_000, 300_000);

    /// <summary>Scenario sessions: nothing outlives the run's hard deadline (the deadline plus the runner's grace).</summary>
    public static PgSessionLimits ForRun(TimeSpan untilHardDeadline)
    {
        var milliseconds = (long)Math.Clamp(untilHardDeadline.TotalMilliseconds, 30_000, (RunLimits.GlobalMaximumSeconds * 1000.0) + 120_000);
        return new PgSessionLimits(milliseconds, milliseconds, milliseconds);
    }
}

/// <summary>
/// Opens T4 connections: TLS with the server certificate and host name verified, no pooling (closing a connection
/// ends its session and rolls back anything open), the application name every demo session carries, and per-session
/// limits so no statement, lock wait, or idle transaction outlives the run that opened it. Transient errors (a server
/// starting, too many connections for a control session) are retried within a short window.
/// </summary>
internal sealed class PgConnectionOpener(PgEndpoint endpoint, RunnerLog log)
{
    /// <summary>PostgreSQL keeps NAMEDATALEN - 1 characters of an application name.</summary>
    public const int MaximumApplicationNameLength = 63;

    // too_many_connections, cannot_connect_now (starting up), admin_shutdown and crash_shutdown during a restart.
    private static readonly HashSet<string> TransientStates = ["53300", "57P03", "57P01", "57P02"];

    private readonly PgTokenProvider? tokens = endpoint.Auth == PgAuthMode.ManagedIdentity ? new PgTokenProvider(endpoint.ManagedIdentityClientId) : null;

    public PgEndpoint Endpoint => endpoint;

    public static int ConnectTimeoutSeconds => 30;

    public static TimeSpan RetryWindow => TimeSpan.FromSeconds(90);

    /// <summary>Opens a connection, retrying transient errors unless <paramref name="retry"/> is false. Session limits are applied right after it opens.</summary>
    public async Task<NpgsqlConnection> OpenAsync(string applicationName, CancellationToken cancellationToken, PgSessionLimits? limits = null, bool retry = true)
    {
        var started = DateTimeOffset.UtcNow;
        var delay = TimeSpan.FromSeconds(2);
        for (var attempt = 1; ; attempt++)
        {
            NpgsqlConnection? connection = null;
            try
            {
                connection = await CreateAsync(applicationName, cancellationToken).ConfigureAwait(false);
                await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
                await ApplyLimitsAsync(connection, limits ?? PgSessionLimits.Control, cancellationToken).ConfigureAwait(false);
                if (attempt > 1)
                {
                    log.Info("pg.connected", "Connected after retrying.", ("target", "T4"), ("attempts", attempt), ("elapsed", DateTimeOffset.UtcNow - started));
                }

                return connection;
            }
            catch (Exception ex) when (retry && IsTransient(ex) && DateTimeOffset.UtcNow - started + delay < RetryWindow && !cancellationToken.IsCancellationRequested)
            {
                if (connection is not null)
                {
                    await connection.DisposeAsync().ConfigureAwait(false);
                }

                log.Warn("pg.retry", "Transient connection error; retrying (the server may be starting or at its connection limit).", ("target", "T4"), ("error", Describe(ex)), ("attempt", attempt), ("delay", delay));
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 15));
            }
            catch
            {
                if (connection is not null)
                {
                    await connection.DisposeAsync().ConfigureAwait(false);
                }

                throw;
            }
        }
    }

    internal static bool IsTransient(Exception exception) => exception switch
    {
        PostgresException postgres => TransientStates.Contains(postgres.SqlState),
        NpgsqlException npgsql => npgsql.IsTransient,
        _ => false,
    };

    /// <summary>The SQLSTATE of a PostgreSQL error, or null for any other failure.</summary>
    internal static string? SqlState(Exception exception) => exception is PostgresException postgres ? postgres.SqlState : null;

    /// <summary>A safe, short description: the SQLSTATE and message, redacted.</summary>
    internal static string Describe(Exception exception) => Redactor.Redact(exception switch
    {
        PostgresException postgres => string.Create(CultureInfo.InvariantCulture, $"PostgreSQL error {postgres.SqlState}: {postgres.MessageText}"),
        _ => exception.Message,
    });

    /// <summary>Builds the connection string without any credential; <see cref="CreateAsync"/> adds the token for one connection.</summary>
    internal static NpgsqlConnectionStringBuilder Build(PgEndpoint endpoint, string applicationName, int connectTimeoutSeconds)
    {
        if (applicationName.Length > MaximumApplicationNameLength)
        {
            throw new ArgumentException("PostgreSQL keeps 63 characters of an application name; this one would be cut, and the session tools match the full name.", nameof(applicationName));
        }

        return new NpgsqlConnectionStringBuilder
        {
            Host = endpoint.Host,
            Port = endpoint.Port,
            Database = endpoint.Database,
            Username = endpoint.Auth == PgAuthMode.ManagedIdentity ? endpoint.User : null,
            ApplicationName = applicationName,
            Pooling = false,
            Timeout = connectTimeoutSeconds,
            CommandTimeout = 60,
            KeepAlive = 30,
            // Azure Database for PostgreSQL requires TLS; VerifyFull also checks the certificate's host name.
            SslMode = endpoint.Auth == PgAuthMode.ManagedIdentity ? SslMode.VerifyFull : SslMode.Prefer,
            PersistSecurityInfo = false,
        };
    }

    private async Task<NpgsqlConnection> CreateAsync(string applicationName, CancellationToken cancellationToken)
    {
        var builder = Build(endpoint, applicationName, ConnectTimeoutSeconds);
        if (endpoint.Auth == PgAuthMode.PasswordFromEnvironment)
        {
            var user = Environment.GetEnvironmentVariable(PgEndpoint.UserVariable);
            var password = Environment.GetEnvironmentVariable(PgEndpoint.PasswordVariable);
            if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(password))
            {
                throw new ScenarioRequestException($"Set {PgEndpoint.UserVariable} and {PgEndpoint.PasswordVariable} for --pg-password-from-environment.");
            }

            builder.Username = user;
            builder.Password = password;
            return new NpgsqlConnection(builder.ConnectionString);
        }

        // The token is the password (Learn: connect with managed identity). It's held only by this connection's
        // settings, which Npgsql drops from ConnectionString once the connection opens (Persist Security Info off).
        builder.Password = await tokens!.GetAsync(cancellationToken).ConfigureAwait(false);
        return new NpgsqlConnection(builder.ConnectionString);
    }

    private static async Task ApplyLimitsAsync(NpgsqlConnection connection, PgSessionLimits limits, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = string.Create(
            CultureInfo.InvariantCulture,
            $"SET statement_timeout = {limits.StatementTimeoutMs}; SET lock_timeout = {limits.LockTimeoutMs}; SET idle_in_transaction_session_timeout = {limits.IdleInTransactionTimeoutMs};");
        command.CommandTimeout = 30;
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
}
