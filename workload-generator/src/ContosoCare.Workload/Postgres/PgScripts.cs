using System.Globalization;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Sql;
using Npgsql;
using NpgsqlTypes;

namespace ContosoCare.Workload.Postgres;

/// <summary>
/// T4's PostgreSQL scripts, embedded in the runner at build time from database/postgresql, and the setup steps that
/// need more than a script: the runner's Microsoft Entra role and its grants. Setup runs as an administrator (the P6
/// group's role); the runner's own role has no DDL rights.
/// </summary>
internal static partial class PgScripts
{
    /// <summary>The schema and the seed function.</summary>
    public static readonly IReadOnlyList<string> BaseSchema = ["010-schema.sql", "020-seed.sql"];

    /// <summary>The control objects and the bounded scenario steps.</summary>
    public static readonly IReadOnlyList<string> DemoObjects = ["110-demo-control.sql", "120-scenario-functions.sql"];

    public static string Read(string fileName) => ScenarioCatalog.ReadResource(typeof(PgScripts).Assembly, "pgsql/" + fileName);

    /// <summary>Splits a script into batches on lines that hold only <c>-- @batch</c>. Empty batches are dropped.</summary>
    public static IReadOnlyList<string> SplitBatches(string script) =>
        [.. BatchSeparator().Split(script).Select(batch => batch.Trim()).Where(batch => batch.Length > 0 && !IsOnlyComments(batch))];

    public static async Task<int> ApplyAsync(NpgsqlConnection connection, string fileName, RunnerLog log, CancellationToken cancellationToken)
    {
        var batches = SplitBatches(Read(fileName));
        foreach (var batch in batches)
        {
            await using var command = connection.CreateCommand();
#pragma warning disable CA2100 // The text is one of the runner's own embedded scripts, never user input.
            command.CommandText = batch;
#pragma warning restore CA2100
            command.CommandTimeout = 1800;
            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        log.Info("setup.script", "Applied a script.", ("target", "T4"), ("script", fileName), ("batches", batches.Count));
        return batches.Count;
    }

    /// <summary>Runs the deterministic seed at a scale (1 to 50) unless that seed is already complete.</summary>
    public static async Task<CheckRecord> SeedAsync(NpgsqlConnection connection, int scale, bool force, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT check_id, status, message FROM demo.usp_seed_contosocare(@scale, @force);";
        command.CommandTimeout = 1800;
        command.Parameters.Add(new NpgsqlParameter<int>("scale", scale));
        command.Parameters.Add(new NpgsqlParameter<bool>("force", force));
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
            ? new CheckRecord(reader.GetString(0), reader.GetString(1), reader.GetString(2))
            : new CheckRecord("seed", "Fail", "The seed returned nothing.");
    }

    /// <summary>
    /// Creates the runner's PostgreSQL role mapped to a Microsoft Entra object (T1's managed identity) with
    /// pgaadauth_create_principal_with_oid, as a non-administrator, unless a role with that name already exists.
    /// Run it connected to the postgres database as a Microsoft Entra administrator.
    /// Source: https://learn.microsoft.com/azure/postgresql/security/security-manage-entra-users
    /// </summary>
    public static async Task<CheckRecord> EnsureEntraRoleAsync(NpgsqlConnection connection, string roleName, Guid objectId, CancellationToken cancellationToken)
    {
        if (!PgEndpoint.IsRoleName(roleName))
        {
            throw new ScenarioRequestException("--runner-role must be a PostgreSQL role name.");
        }

        await using (var exists = connection.CreateCommand())
        {
            exists.CommandText = "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = @role);";
            exists.Parameters.Add(new NpgsqlParameter<string>("role", roleName));
            if (await exists.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is true)
            {
                return new CheckRecord("runner-role", "Pass", $"The role {roleName} already exists (mapped to the runner's Microsoft Entra identity).");
            }
        }

        await using var create = connection.CreateCommand();
        create.CommandText = "SELECT * FROM pg_catalog.pgaadauth_create_principal_with_oid(@role, @oid, 'service', false, false);";
        create.Parameters.Add(new NpgsqlParameter<string>("role", roleName));
        create.Parameters.Add(new NpgsqlParameter<string>("oid", objectId.ToString("D", CultureInfo.InvariantCulture)));
        await create.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        return new CheckRecord("runner-role", "Pass", $"Created the role {roleName} for the runner's Microsoft Entra identity (a service principal, not an administrator).");
    }

    /// <summary>True when a role with this name exists on the server.</summary>
    public static async Task<bool> RoleExistsAsync(NpgsqlConnection connection, string roleName, CancellationToken cancellationToken)
    {
        await using var exists = connection.CreateCommand();
        exists.CommandText = "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = @role);";
        exists.Parameters.Add(new NpgsqlParameter<string>("role", roleName));
        return await exists.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is true;
    }

    /// <summary>
    /// Grants the runner's role what the scenarios need in contosocare, and nothing at the server level except the
    /// optional pg_read_all_stats (the live view of other roles' sessions). Run it connected to contosocare.
    /// </summary>
    public static async Task<IReadOnlyList<CheckRecord>> GrantRunnerAsync(NpgsqlConnection connection, string roleName, CancellationToken cancellationToken)
    {
        if (!PgEndpoint.IsRoleName(roleName))
        {
            throw new ScenarioRequestException("--runner-role must be a PostgreSQL role name.");
        }

        var role = QuoteIdentifier(roleName);
        var statements = new[]
        {
            $"GRANT CONNECT ON DATABASE {QuoteIdentifier(PgEndpoint.DatabaseName)} TO {role};",
            $"GRANT USAGE ON SCHEMA care, demo TO {role};",
            $"GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA care, demo TO {role};",
            $"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA care, demo TO {role};",
            $"GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA demo TO {role};",
        };
        foreach (var statement in statements)
        {
            await using var grant = connection.CreateCommand();
#pragma warning disable CA2100 // The role name is validated by IsRoleName and quoted as an identifier.
            grant.CommandText = statement;
#pragma warning restore CA2100
            await grant.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        var checks = new List<CheckRecord> { new("runner-grants", "Pass", $"{roleName} can read and write the care and demo tables and run the demo functions in contosocare, and nothing else.") };
        try
        {
            await using var stats = connection.CreateCommand();
#pragma warning disable CA2100 // As above.
            stats.CommandText = $"GRANT pg_read_all_stats TO {role};";
#pragma warning restore CA2100
            await stats.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            checks.Add(new CheckRecord("runner-stats", "Pass", $"{roleName} is a member of pg_read_all_stats, so 'status' shows every session's state and wait, not only the runner's own."));
        }
        catch (PostgresException ex)
        {
            checks.Add(new CheckRecord("runner-stats", "Warning", $"{roleName} couldn't be granted pg_read_all_stats ({ex.SqlState}), so 'status' shows full detail for the demo's own sessions only."));
        }

        return checks;
    }

    /// <summary>Checks that every T4 scenario in the catalog has its step function.</summary>
    public static async Task<CheckRecord> VerifyScenarioFunctionsAsync(NpgsqlConnection connection, IEnumerable<ScenarioDefinition> scenarios, CancellationToken cancellationToken)
    {
        var missing = new List<string>();
        foreach (var scenario in scenarios.Where(s => s.AppliesTo(DemoTarget.T4)))
        {
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace WHERE n.nspname = 'demo' AND p.proname = @name);";
            command.Parameters.Add(new NpgsqlParameter<string>("name", NpgsqlDbType.Text) { TypedValue = scenario.Procedure["demo.".Length..] });
            if (await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) is not true)
            {
                missing.Add(scenario.Procedure);
            }
        }

        return missing.Count == 0
            ? new CheckRecord("scenario-functions", "Pass", "Every T4 scenario in the catalog has its step function.")
            : new CheckRecord("scenario-functions", "Fail", string.Create(CultureInfo.InvariantCulture, $"{missing.Count} scenario function(s) are missing: {string.Join(", ", missing)}."));
    }

    internal static string QuoteIdentifier(string identifier) => "\"" + identifier.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";

    private static bool IsOnlyComments(string batch) =>
        batch.Split('\n').Select(line => line.Trim()).All(line => line.Length == 0 || line.StartsWith("--", StringComparison.Ordinal));

    [GeneratedRegex(@"(?m)^[ \t]*--[ \t]*@batch[ \t]*\r?$")]
    private static partial Regex BatchSeparator();
}
