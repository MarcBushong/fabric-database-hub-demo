using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Sql;

/// <summary>
/// The T-SQL scripts embedded in the runner at build time from database/common, so <c>setup</c> can create or update
/// the demo objects with the identity that runs it (an administrator; the runner's service identity has no DDL rights).
/// </summary>
internal static partial class SqlScripts
{
    /// <summary>The ContosoCare schema and seed procedure (the bootstraps normally apply these).</summary>
    public static readonly IReadOnlyList<string> BaseSchema = ["010-schema.sql", "020-seed.sql"];

    /// <summary>The Phase 11 demo objects: control tables and procedures, and the bounded scenario procedures.</summary>
    public static readonly IReadOnlyList<string> DemoObjects = ["110-demo-control.sql", "120-scenario-procedures.sql"];

    public static string Read(string fileName)
    {
        var assembly = typeof(SqlScripts).Assembly;
        return ScenarioCatalog.ReadResource(assembly, "sql/" + fileName);
    }

    /// <summary>Splits a script into batches on lines that contain only GO, as sqlcmd does. Empty batches are dropped.</summary>
    public static IReadOnlyList<string> SplitBatches(string script)
    {
        return [.. GoSeparator().Split(script).Select(batch => batch.Trim()).Where(batch => batch.Length > 0)];
    }

    public static async Task<int> ApplyAsync(SqlConnection connection, string fileName, RunnerLog log, CancellationToken cancellationToken)
    {
        var batches = SplitBatches(Read(fileName));
        foreach (var batch in batches)
        {
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.Text;
#pragma warning disable CA2100 // The text is one of the runner's own embedded scripts, never user input.
            command.CommandText = batch;
#pragma warning restore CA2100
            command.CommandTimeout = 600;
            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        log.Info("setup.script", "Applied a script.", ("script", fileName), ("batches", batches.Count));
        return batches.Count;
    }

    /// <summary>
    /// Creates a Windows login for the runner's service identity (T1 and T2 only), its ContosoCare user, and adds
    /// the user to contosocare_runner. The name is passed as a parameter and quoted with QUOTENAME.
    /// </summary>
    public static async Task GrantWindowsLoginAsync(SqlConnection connection, string windowsAccount, CancellationToken cancellationToken)
    {
        if (!WindowsAccountPattern().IsMatch(windowsAccount))
        {
            throw new ScenarioRequestException("--grant-windows-login must look like DOMAIN\\name or NT SERVICE\\name.");
        }

        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.Text;
        command.CommandTimeout = 60;
        command.CommandText =
            """
            DECLARE @sql nvarchar(600);
            IF SUSER_ID(@account) IS NULL
            BEGIN
                SET @sql = N'CREATE LOGIN ' + QUOTENAME(@account) + N' FROM WINDOWS;';
                EXEC (@sql);
            END;
            IF DATABASE_PRINCIPAL_ID(@account) IS NULL
            BEGIN
                SET @sql = N'CREATE USER ' + QUOTENAME(@account) + N' FOR LOGIN ' + QUOTENAME(@account) + N';';
                EXEC (@sql);
            END;
            IF ISNULL(IS_ROLEMEMBER(N'contosocare_runner', @account), 0) = 0
            BEGIN
                SET @sql = N'ALTER ROLE contosocare_runner ADD MEMBER ' + QUOTENAME(@account) + N';';
                EXEC (@sql);
            END;
            """;
        command.Parameters.Add("@account", SqlDbType.NVarChar, 128).Value = windowsAccount;
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// The procedures <c>setup</c> checks on a SQL Server or Azure SQL target: the procedure that each catalog scenario
    /// running on the target names in its scenario.json. An orchestrated scenario names its entry procedure, for example
    /// demo.usp_scenario_chain_link for blocking-chain, so a naming convention can't stand in for the catalog (Phase 25d:
    /// blocking-chain, memory-grant-pressure, and log-flush-waits failed setup on every target that way).
    /// </summary>
    public static IReadOnlyList<string> ExpectedProcedures(ScenarioCatalog catalog, DemoTarget target) =>
        [.. catalog.All.Where(s => s.AppliesTo(target)).Select(s => s.Procedure).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.Ordinal)];

    /// <summary>The procedures of <paramref name="procedures"/> that don't exist in the connected database.</summary>
    public static async Task<IReadOnlyList<string>> FindMissingProceduresAsync(SqlConnection connection, IReadOnlyList<string> procedures, CancellationToken cancellationToken)
    {
        var missing = new List<string>();
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.Text;
        command.CommandTimeout = 60;
        command.CommandText = "SELECT CASE WHEN OBJECT_ID(@name, N'P') IS NULL THEN 1 ELSE 0 END;";
        var name = command.Parameters.Add("@name", SqlDbType.NVarChar, 256);
        foreach (var procedure in procedures)
        {
            name.Value = procedure;
            if (Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false), CultureInfo.InvariantCulture) == 1)
            {
                missing.Add(procedure);
            }
        }

        return missing;
    }

    [GeneratedRegex(@"(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?\r?$")]
    private static partial Regex GoSeparator();

    [GeneratedRegex(@"^[A-Za-z0-9 ._$-]{1,64}\\[A-Za-z0-9 ._$-]{1,63}$")]
    private static partial Regex WindowsAccountPattern();
}
