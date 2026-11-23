using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The runner's own statements outside any module (rca/README.md, What the capture leaves out, 3): the forms in which the
/// runner sends them and Query Store keeps them match, a workload statement of the same shape elsewhere doesn't, and every
/// statement the runner's harness code sends is listed. Against a real engine, opt-in, every statement Query Store
/// recorded outside a module while only the runner's own ran is matched.
/// </summary>
public sealed partial class RcaHarnessStatementsTests
{
    /// <summary>The runner's harness code: its SQL Server statements outside any module are in these files.</summary>
    private static readonly string[] Sources =
    [
        "workload-generator/src/ContosoCare.Workload/Sql/DemoDatabase.cs",
        "workload-generator/src/ContosoCare.Workload/Sql/SqlScripts.cs",
        "workload-generator/src/ContosoCare.Workload/Cli/CommandLine.cs",
    ];

    [Theory]
    [InlineData("(@run_id varchar(64))SELECT demo.fn_x(@run_id);", "selectdemo.fn_x(?)")]
    [InlineData("/* a */ SELECT [a], b -- b\r\nFROM [dbo].[t] WHERE c = N'it''s' AND d = @p ORDER BY a ASC;", "selecta,bfromdbo.twherec=?andd=?orderbya")]
    [InlineData("(@a nvarchar(128),@b datetime2(3))SELECT @a;", "select?")]
    [InlineData("SELECT CAST(@v AS datetime2(3)), x1, 0x1F, 1.5, 2e3", "selectcast(?asdatetime2(?)),x1,?,?,?")]
    [InlineData("SELECT @@ROWCOUNT", "select@@rowcount")]
    [InlineData("SELECT /* a /* b */ c */ '--not a comment'", "select?")]
    [InlineData("  SELECT 1 ORDER BY x DESC  ;  ", "select?orderbyxdesc")]
    [InlineData("(@a int SELECT 1", "(?intselect?")]
    public void NormalizeDropsWhatTheEngineChangesAndKeepsWhatTheStatementIs(string text, string normalized) =>
        Assert.Equal(normalized, HarnessText.Normalize(text));

    [Fact]
    public void EachListedStatementMatchesInTheFormsTheRunnerAndQueryStoreGiveIt()
    {
        foreach (var statement in HarnessStatements.Statements)
        {
            // sp_executesql's: Query Store keeps the parameters' declaration before the statement, with or without its semicolon.
            var parameters = Parameter().Matches(statement).Select(m => m.Value).Distinct(StringComparer.Ordinal).ToList();
            var declaration = parameters.Count == 0 ? string.Empty : "(" + string.Join(',', parameters.Select(p => p + " nvarchar(128)")) + ")";
            var lf = statement.ReplaceLineEndings("\n");
            string[] forms =
            [
                statement,
                declaration + statement,
                declaration + statement.TrimEnd().TrimEnd(';'),
                lf.Replace("\n", "\r\n", StringComparison.Ordinal),
                lf,
                string.Join('\n', lf.Split('\n').Select(line => "            " + line)),
                Whitespace().Replace(lf, " "),
            ];
            Assert.All(forms, form => Assert.True(HarnessStatements.IsRunners(form), form));
        }
    }

    [Theory]
    [InlineData("(@1 tinyint)SELECT [scenario_id],[stop_requested_at],[stop_requested_by] FROM [demo].[scenario_control] WHERE [stop_requested]=@1 ORDER BY [scenario_id] ASC")]
    [InlineData("(@1 tinyint,@2 tinyint)SELECT [physical_name] FROM [sys].[database_files] WHERE [type] IN (@1,@2)")]
    public void SimpleParameterizationsRewrittenFormsMatch(string kept) => Assert.True(HarnessStatements.IsRunners(kept), kept);

    [Theory]
    [InlineData("SELECT scenario_id, stop_requested_at, stop_requested_by FROM demo.scenario_flags WHERE stop_requested = 1 ORDER BY scenario_id;")]
    [InlineData("(@1 tinyint,@2 tinyint)SELECT [physical_name] FROM [sys].[master_files] WHERE [type] IN (@1,@2)")]
    [InlineData("SELECT physical_name FROM sys.database_files WHERE type IN (0, 1, 2);")]
    [InlineData("(@1 tinyint)SELECT [physical_name] FROM [sys].[database_files] WHERE [type] IN (@1)")]
    [InlineData("SELECT COUNT_BIG(*) FROM care.appointments;")]
    [InlineData("(@run_id varchar(64))SELECT demo.fn_run_stop_requested(@run_id), 1;")]
    [InlineData("SELECT demo.fn_can_view_sessions() WHERE 1 = 0;")]
    public void AWorkloadStatementOfTheSameShapeElsewhereStaysEvidence(string workload) => Assert.False(HarnessStatements.IsRunners(workload), workload);

    [Fact]
    public void EachEntryIsOneQueryStatementAndNoneRepeats()
    {
        Assert.All(HarnessStatements.Statements, statement => Assert.Single(QueryStatements(statement)));
        Assert.Equal(HarnessStatements.Statements.Count, HarnessStatements.Statements.Select(HarnessText.Normalize).Distinct(StringComparer.Ordinal).Count());
    }

    [Fact]
    public void EveryStatementTheRunnersHarnessCodeSendsOutsideAModuleIsListed()
    {
        // Every Text(...) and CommandText = ... literal, parsed as T-SQL: each query statement in it, those within IF and
        // BEGIN included, must be listed. A statement added without its entry fails here.
        var found = new List<string>();
        foreach (var source in Sources)
        {
            var code = File.ReadAllText(RepositoryPaths.Combine(source.Split('/')));
            foreach (var literal in Literal().Matches(code).Cast<Match>())
            {
                var sql = literal.Groups["raw"].Success ? literal.Groups["raw"].Value : literal.Groups["text"].Value.Replace("\\\"", "\"", StringComparison.Ordinal);
                foreach (var statement in QueryStatements(sql))
                {
                    found.Add(statement);
                    Assert.True(HarnessStatements.IsRunners(statement), $"{source} sends a statement outside any module that Rca/QueryStore/HarnessStatements.cs doesn't list: {statement}");
                }
            }
        }

        // The stop check every run polls is among them, and at least the ten statements the list has had since edd01c86.
        Assert.Contains(found, s => s.Contains("fn_run_stop_requested", StringComparison.Ordinal));
        Assert.True(found.Select(HarnessText.Normalize).Distinct(StringComparer.Ordinal).Count() >= 10, string.Join('\n', found));
    }

    /// <summary>
    /// Against a disposable SQL Server (CONTOSOCARE_TEST_SQL_SERVER, Windows authentication, as SqlIntegrationTests), in a
    /// database of its own with Query Store capturing ALL: the runner's own statements run as the runner sends them (the
    /// stop check, the stop flags, sessions, space, runs, orphans, file paths, setup's procedure check, the warmup, and
    /// the release's Query Store state read), then RCA-SQL-16, and the match must take every statement Query Store
    /// recorded outside a module for the runner's, in whatever form the engine kept it (simple parameterization's
    /// included). CI doesn't set it; Final tests runs it at the rehearsal.
    /// </summary>
    [Fact]
    public async Task OnSqlServerEveryStatementTheRunnerSendsOutsideAModuleIsMatched()
    {
        Assert.SkipUnless(SqlIntegrationTests.Server is not null, $"Set {SqlIntegrationTests.ServerVariable} to a disposable SQL Server instance to run this test.");
        var token = TestContext.Current.CancellationToken;
        var database = "ContosoCareQs" + Guid.NewGuid().ToString("N")[..12];
        var master = new SqlConnectionStringBuilder { DataSource = SqlIntegrationTests.Server, InitialCatalog = "master", IntegratedSecurity = true, TrustServerCertificate = true, Pooling = false }.ConnectionString;
        await using (var create = new SqlConnection(master))
        {
            await create.OpenAsync(token);
            await RunAsync(create, $"CREATE DATABASE [{database}];", token);
        }

        try
        {
            var texts = new List<string>();
            await using (var connection = new SqlConnection(new SqlConnectionStringBuilder(master) { InitialCatalog = database }.ConnectionString))
            {
                await connection.OpenAsync(token);
                foreach (var script in SqlScripts.BaseSchema.Concat(SqlScripts.DemoObjects))
                {
                    await SqlScripts.ApplyAsync(connection, script, RunnerLog.Null, token);
                }

                await RunAsync(connection, "ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1); ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;", token);
                var since = DateTimeOffset.UtcNow.AddMinutes(-5);

                // The runner's own statements, each as its code sends it.
                var demo = new DemoDatabase(connection);
                await demo.IsStopRequestedAsync("it-qs-run", token);
                await demo.GetStopFlagsAsync(token);
                Assert.NotNull(await demo.GetDemoSessionsAsync("it-qs-run", token));
                await demo.GetSpaceAsync(token);
                await demo.GetRunsAsync(5, runningOnly: true, token);
                Assert.NotNull(await demo.RecoverOrphanedProfileRunsAsync(Environment.MachineName, DateTimeOffset.UtcNow, token));
                await demo.GetFilePathsAsync(token);
                await SqlScripts.FindMissingProceduresAsync(connection, ["demo.usp_reset"], token);
                await RunAsync(connection, string.Join(' ', HarnessStatements.Statements.Where(s => s.Contains("COUNT_BIG", StringComparison.Ordinal))), token);
                await RunAsync(connection, HarnessStatements.Statements.Single(s => s.Contains("database_query_store_options", StringComparison.Ordinal)), token);
                await RunAsync(connection, "EXEC sys.sp_query_store_flush_db;", token);

                // RCA-SQL-16 as the observer runs it.
                await using var read = Command(connection, CaptureCatalog.Get("RCA-SQL-16"));
                read.Parameters.Add(new SqlParameter("@since", SqlDbType.DateTimeOffset) { Value = since });
                read.Parameters.Add(new SqlParameter("@final", SqlDbType.Bit) { Value = true });
                await using var reader = await read.ExecuteReaderAsync(token);
                while (await reader.ReadAsync(token))
                {
                    texts.Add(reader.GetString(1));
                }
            }

            Assert.Contains(texts, t => t.Contains("fn_run_stop_requested", StringComparison.Ordinal));
            Assert.All(texts, t => Assert.True(HarnessStatements.IsRunners(t), $"Query Store kept a statement outside any module that the match doesn't take for the runner's: {t}"));
        }
        finally
        {
            await using var drop = new SqlConnection(master);
            await drop.OpenAsync(CancellationToken.None);
            await RunAsync(drop, string.Create(CultureInfo.InvariantCulture, $"ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{database}];"), CancellationToken.None);
        }
    }

    /// <summary>The query statements of a batch (SELECT, INSERT, UPDATE, DELETE, MERGE, those within IF and BEGIN included), each as its text.</summary>
    private static List<string> QueryStatements(string sql)
    {
        var script = new TSql160Parser(initialQuotedIdentifiers: true).Parse(new StringReader(sql), out var errors);
        Assert.True(errors.Count == 0, $"{sql}: {string.Join("; ", errors.Select(e => e.Message))}");
        var visitor = new QueryStatementVisitor();
        script.Accept(visitor);
        return [.. visitor.Found.Select(s => sql.Substring(s.StartOffset, s.FragmentLength))];
    }

    private static async Task RunAsync(SqlConnection connection, string sql, CancellationToken token)
    {
        await using var command = Command(connection, sql);
        await using var reader = await command.ExecuteReaderAsync(token);
        do
        {
            while (await reader.ReadAsync(token))
            {
            }
        }
        while (await reader.NextResultAsync(token));
    }

    private static SqlCommand Command(SqlConnection connection, string sql)
    {
        var command = connection.CreateCommand();
#pragma warning disable CA2100 // The test's own statements, the catalog's, and the runner's listed ones, on a disposable database it names itself.
        command.CommandText = sql;
#pragma warning restore CA2100
        command.CommandTimeout = 120;
        return command;
    }

    [GeneratedRegex("""(?s)(?:\bText\(\s*|\bCommandText\s*=\s*)(?:"{3}(?<raw>.*?)"{3}|"(?<text>(?:[^"\\]|\\.)*)")""")]
    private static partial Regex Literal();

    [GeneratedRegex(@"@\w+")]
    private static partial Regex Parameter();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    private sealed class QueryStatementVisitor : TSqlFragmentVisitor
    {
        public List<TSqlStatement> Found { get; } = [];

        public override void Visit(SelectStatement node) => Found.Add(node);

        public override void Visit(InsertStatement node) => Found.Add(node);

        public override void Visit(UpdateStatement node) => Found.Add(node);

        public override void Visit(DeleteStatement node) => Found.Add(node);

        public override void Visit(MergeStatement node) => Found.Add(node);
    }
}
