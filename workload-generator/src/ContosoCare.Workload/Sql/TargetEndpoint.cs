using System.Globalization;
using System.Security;
using System.Security.Cryptography;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Sql;

internal enum SqlAuthMode
{
    /// <summary>T1 and T2: the runner shares the machine with SQL Server and signs in with its Windows identity.</summary>
    Windows,

    /// <summary>T3: Microsoft Entra authentication with the VM's managed identity (Authentication=Active Directory Managed Identity).</summary>
    ManagedIdentity,

    /// <summary>Local container tests only: a SQL login whose name and password come from environment variables, never from arguments.</summary>
    SqlLoginFromEnvironment,
}

/// <summary>Where and how the runner connects. Never holds a secret: the only credential-bearing mode reads the environment at connect time.</summary>
internal sealed record TargetEndpoint(DemoTarget Target, string Server, SqlAuthMode Auth, string? ManagedIdentityClientId = null)
{
    public const string LocalServer = ".";
    public const string UserVariable = "CONTOSOCARE_SQL_USER";
    public const string PasswordVariable = "CONTOSOCARE_SQL_PASSWORD";

    public static TargetEndpoint Create(DemoTarget target, string? server, bool sqlLoginFromEnvironment, string? managedIdentityClientId)
    {
        if (target == DemoTarget.T4)
        {
            throw new ScenarioRequestException("T4 is Azure Database for PostgreSQL; its endpoint comes from PgEndpoint.Create.");
        }

        if (target == DemoTarget.T5)
        {
            throw new ScenarioRequestException("T5 is Azure Cosmos DB for NoSQL; its endpoint comes from CosmosEndpoint.Create.");
        }

        if (sqlLoginFromEnvironment)
        {
            if (target == DemoTarget.T3)
            {
                throw new ScenarioRequestException("T3 is Microsoft Entra only; --sql-login-from-environment is for local SQL Server containers.");
            }

            if (string.IsNullOrWhiteSpace(server))
            {
                throw new ScenarioRequestException("--sql-login-from-environment needs --server (for example localhost,1433).");
            }

            return new TargetEndpoint(target, server.Trim(), SqlAuthMode.SqlLoginFromEnvironment);
        }

        if (target == DemoTarget.T3)
        {
            if (string.IsNullOrWhiteSpace(server))
            {
                throw new ScenarioRequestException("T3 needs --server, the logical server's name (for example sql-contoso-demo.database.windows.net).");
            }

            var name = server.Trim();
            if (!name.Contains('.', StringComparison.Ordinal))
            {
                name += ".database.windows.net";
            }

            if (managedIdentityClientId is not null && !Guid.TryParse(managedIdentityClientId, out _))
            {
                throw new ScenarioRequestException("--managed-identity-client-id must be the client ID (a GUID) of a user-assigned identity.");
            }

            return new TargetEndpoint(target, name, SqlAuthMode.ManagedIdentity, managedIdentityClientId);
        }

        return new TargetEndpoint(target, string.IsNullOrWhiteSpace(server) ? LocalServer : server.Trim(), SqlAuthMode.Windows);
    }

    /// <summary>True when SQL Server runs on this machine, so local disk free space is meaningful.</summary>
    public bool IsLocal
    {
        get
        {
            if (Auth != SqlAuthMode.Windows)
            {
                return false;
            }

            var host = Server.Split(',', '\\')[0].Trim();
            if (host.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase) || host.StartsWith("np:", StringComparison.OrdinalIgnoreCase) || host.StartsWith("lpc:", StringComparison.OrdinalIgnoreCase))
            {
                host = host[(host.IndexOf(':', StringComparison.Ordinal) + 1)..];
            }

            return host is "." or "(local)" or "localhost" or "127.0.0.1" or "(localdb)"
                || string.Equals(host, Environment.MachineName, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>A description that's safe to log (no credentials exist in this record).</summary>
    public string Describe() => string.Create(CultureInfo.InvariantCulture, $"{Target} {Server} ({Auth})");
}

/// <summary>Application names and run IDs. Every connection the runner opens carries one of these names.</summary>
internal static class SessionNames
{
    public const string Prefix = "ContosoCare.Demo/";
    public const string ControlScenario = "control";

    /// <summary>The longest service name (scenario.schema.json's <c>service</c>).</summary>
    public const int MaximumServiceLength = 32;

    /// <summary>
    /// <c>ContosoCare.Demo/&lt;service&gt;/&lt;runId&gt;</c>: the sessions that do a run's work, named for the ContosoCare client
    /// service that runs its scenario (the catalog's <c>service</c>) and for the run, never for the scenario, so a session's
    /// name doesn't say which fault it plays (ADR 0031, decision 6). The session tools match a run's sessions by the run ID
    /// alone (<c>ContosoCare.Demo/%/&lt;runId&gt;</c>), so an older runner's <c>ContosoCare.Demo/&lt;scenario&gt;/&lt;runId&gt;</c> matches too.
    /// </summary>
    public static string ForRun(string service, string runId)
    {
        if (!IsValidService(service))
        {
            throw new ArgumentException($"Not a service name: lowercase words joined by hyphens, at most {MaximumServiceLength} characters, never '{ControlScenario}'.", nameof(service));
        }

        return IsValidRunId(runId) ? Checked($"{Prefix}{service}/{runId}") : throw new ArgumentException("Not a run ID.", nameof(runId));
    }

    /// <summary><c>ContosoCare.Demo/control/&lt;id&gt;</c>: bookkeeping sessions, which the session tools never kill.</summary>
    public static string ForControl(string id) => Checked($"{Prefix}{ControlScenario}/{id}");

    public static bool IsScenarioSession(string? applicationName) =>
        applicationName is not null
        && applicationName.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)
        && !applicationName.StartsWith(Prefix + ControlScenario + "/", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// A new run ID: 16 lowercase hex characters (64 random bits), which say nothing about the run; demo.scenario_runs (for T5,
    /// its run store) maps it to its scenario, target, and times. It fits <see cref="IsValidRunId"/>, demo.usp_run_begin's rule.
    /// </summary>
    public static string NewRunId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));

    /// <summary>
    /// demo.usp_run_begin's rule on both engines: 1 to 40 of a-z, 0-9, and '-', not starting with '-'. An older runner's run IDs
    /// (<c>20261120170200-t1-9b7c1d</c>: time, target, random hex) fit it too. Nothing that LIKE reads as a wildcard.
    /// </summary>
    public static bool IsValidRunId(string? runId) =>
        runId is { Length: > 0 and <= 40 }
        && runId.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-')
        && runId[0] != '-';

    /// <summary>A service name (scenario.schema.json's <c>service</c>): lowercase words joined by single hyphens, at most 32 characters, never <c>control</c>.</summary>
    public static bool IsValidService(string? service) =>
        service is { Length: > 0 and <= MaximumServiceLength }
        && service != ControlScenario
        && service[0] is >= 'a' and <= 'z'
        && service[^1] != '-'
        && !service.Contains("--", StringComparison.Ordinal)
        && service.All(c => c is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-');

    private static string Checked(string name)
    {
        // SqlClient accepts at most 128 characters.
        return name.Length <= 128 ? name : throw new ArgumentException("An application name would exceed 128 characters.", nameof(name));
    }
}

/// <summary>Builds connection strings. They never contain a password, an access token, or any other secret.</summary>
internal static class ConnectionStrings
{
    /// <summary>The only database the runner ever connects to.</summary>
    public const string DatabaseName = "ContosoCare";

    public static string Build(TargetEndpoint endpoint, string applicationName, int connectTimeoutSeconds)
    {
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = endpoint.Server,
            InitialCatalog = DatabaseName,
            ApplicationName = applicationName,
            // A dedicated physical connection per session: closing it ends the session and rolls back anything open.
            // With pooling, a closed connection would keep its session (and any open transaction) in the pool.
            Pooling = false,
            MultipleActiveResultSets = false,
            ConnectTimeout = connectTimeoutSeconds,
            Encrypt = SqlConnectionEncryptOption.Mandatory,
        };

        switch (endpoint.Auth)
        {
            case SqlAuthMode.Windows:
                builder.IntegratedSecurity = true;
                // Same-machine connection to the local instance, which has only its self-signed certificate.
                builder.TrustServerCertificate = true;
                break;
            case SqlAuthMode.ManagedIdentity:
                builder.Authentication = SqlAuthenticationMethod.ActiveDirectoryManagedIdentity;
                builder.TrustServerCertificate = false;
                if (endpoint.ManagedIdentityClientId is not null)
                {
                    builder.UserID = endpoint.ManagedIdentityClientId;
                }

                break;
            case SqlAuthMode.SqlLoginFromEnvironment:
                // The SQL Server container's self-signed certificate; the credential travels as a SqlCredential.
                builder.TrustServerCertificate = true;
                break;
        }

        return builder.ConnectionString;
    }
}

/// <summary>Opens connections, retrying transient errors such as a serverless database resuming (error 40613).</summary>
internal sealed class SqlConnectionOpener(TargetEndpoint endpoint, RunnerLog log)
{
    // Transient errors listed in "Troubleshoot transient connection errors" for Azure SQL Database, plus a client
    // timeout (-2) while a paused serverless database resumes.
    private static readonly HashSet<int> TransientErrors = [926, 4060, 4221, 40197, 40501, 40613, 49918, 49919, 49920, -2];

    public TargetEndpoint Endpoint => endpoint;

    /// <summary>T3 can take about a minute to resume from auto-pause, so it gets a longer connect timeout and window.</summary>
    public int ConnectTimeoutSeconds => endpoint.Target == DemoTarget.T3 ? 60 : 30;

    public TimeSpan RetryWindow => endpoint.Target == DemoTarget.T3 ? TimeSpan.FromMinutes(3) : TimeSpan.FromSeconds(45);

    public async Task<SqlConnection> OpenAsync(string applicationName, CancellationToken cancellationToken)
    {
        var connectionString = ConnectionStrings.Build(endpoint, applicationName, ConnectTimeoutSeconds);
        var started = DateTimeOffset.UtcNow;
        var delay = TimeSpan.FromSeconds(2);
        for (var attempt = 1; ; attempt++)
        {
            var connection = Create(connectionString);
            try
            {
                await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
                if (attempt > 1)
                {
                    log.Info("sql.connected", "Connected after retrying.", ("target", endpoint.Target), ("attempts", attempt), ("elapsed", DateTimeOffset.UtcNow - started));
                }

                return connection;
            }
            catch (Exception ex) when (IsRetryableOpenFailure(ex) && DateTimeOffset.UtcNow - started + delay < RetryWindow && !cancellationToken.IsCancellationRequested)
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                log.Warn("sql.retry", "Transient connection error; retrying (a serverless database may be resuming, or many sessions are opening at once).", ("target", endpoint.Target), ("error", ex is SqlException sql ? sql.Number.ToString(CultureInfo.InvariantCulture) : ex.GetType().Name), ("attempt", attempt), ("delay", delay));
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 30));
            }
            catch
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }
    }

    internal static bool IsTransient(SqlException exception) => exception.Errors.Cast<SqlError>().Any(e => TransientErrors.Contains(e.Number)) || TransientErrors.Contains(exception.Number);

    /// <summary>
    /// A transient SQL error, or SqlClient's TimeoutException for an open that waited too long behind other
    /// non-pooled opens (it runs only as many at once as there are processors), before anything was opened: under
    /// capacity-max on T2's 2-vCPU guest, 2 of 12 sessions failed that way (Phase 25d, live).
    /// </summary>
    internal static bool IsRetryableOpenFailure(Exception exception) => exception switch
    {
        SqlException sql => IsTransient(sql),
        TimeoutException => true,
        _ => false,
    };

    private SqlConnection Create(string connectionString)
    {
        if (endpoint.Auth != SqlAuthMode.SqlLoginFromEnvironment)
        {
            return new SqlConnection(connectionString);
        }

        var user = Environment.GetEnvironmentVariable(TargetEndpoint.UserVariable);
        var password = Environment.GetEnvironmentVariable(TargetEndpoint.PasswordVariable);
        if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(password))
        {
            throw new ScenarioRequestException($"Set {TargetEndpoint.UserVariable} and {TargetEndpoint.PasswordVariable} for --sql-login-from-environment.");
        }

        var secure = new SecureString();
        foreach (var character in password)
        {
            secure.AppendChar(character);
        }

        secure.MakeReadOnly();
        return new SqlConnection(connectionString, new SqlCredential(user, secure));
    }
}
