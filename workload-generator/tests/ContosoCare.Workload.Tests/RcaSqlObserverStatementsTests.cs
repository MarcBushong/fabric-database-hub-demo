using System.Data;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using Microsoft.Data.SqlClient;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The observer's own SQL Server statements from before its marker (rca/README.md, What the capture leaves out, 1 and 3):
/// every statement Query Store may keep of the blocks the release's runner sends, as edd01c86 or a later release sent
/// them, is taken for the runner's, and a session option, or another statement of the same shape, isn't. The statements
/// are found with ScriptDom, which the runner doesn't ship, and the runner's splitter must find the same. Against a real
/// engine, opt-in, every statement Query Store recorded outside a module while only those blocks ran is matched.
/// </summary>
[Collection(SqlEventSessionSerial.Name)]
public sealed class RcaSqlObserverStatementsTests
{
    /// <summary>The SQL Server blocks the release's runner sends: on T3, RCA-XE-03 and 04 in place of 01 and 02.</summary>
    private static readonly string[] Sent =
    [
        "RCA-SQL-01", "RCA-SQL-02", "RCA-SQL-09", "RCA-SQL-12", "RCA-AZ-01",
        "RCA-XE-00", "RCA-XE-01", "RCA-XE-02", "RCA-XE-03", "RCA-XE-04", "RCA-XE-05",
    ];

    /// <summary>On SQL Server, the sent blocks in the observer's order: its start, its reads, and its end.</summary>
    private static readonly string[] EngineOrder = ["RCA-XE-05", "RCA-XE-00", "RCA-XE-01", "RCA-SQL-09", "RCA-SQL-01", "RCA-SQL-02", "RCA-XE-02", "RCA-SQL-12", "RCA-XE-05"];

    [Fact]
    public void EveryStatementOfTheBlocksEarlierRunnersSentIsTheRunners()
    {
        var unmatched = new List<string>();
        var statements = 0;
        foreach (var (where, batch) in Earlier())
        {
            Assert.DoesNotContain("dbhubdemo", batch, StringComparison.Ordinal);
            foreach (var statement in Kept(batch))
            {
                statements++;

                // As Query Store keeps it, and without its final semicolon, with CRLF, or on one line.
                string[] forms = [statement, statement.TrimEnd().TrimEnd(';'), statement.ReplaceLineEndings("\r\n"), string.Join(' ', statement.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))];
                unmatched.AddRange(forms.Where(form => !HarnessStatements.IsRunners(form)).Select(form => $"{where}: {form}"));
            }
        }

        Assert.True(unmatched.Count == 0, "Not taken for the runner's:" + Environment.NewLine + string.Join(Environment.NewLine, unmatched));

        // Nine queries, RCA-SQL-01's and 12's declarations, and three texts for each IF: two in each of RCA-XE-01, 03, and 05 and T3's 05.
        Assert.Equal(35, statements);
    }

    [Fact]
    public void RcaXe00sEarlierFormsAreListedByThemselvesAsTheRunnersSentThem()
    {
        string[] earlier = [CaptureCatalog.Parse(RcaSqlCatalogHistory.Edd01c86)["RCA-XE-00"], CaptureCatalog.Parse(RcaSqlCatalogHistory.F16b9cb9RcaXe00)["RCA-XE-00"]];
        Assert.Equal(earlier, SqlObserverStatements.EarlierRcaXe00.Select(form => form.ReplaceLineEndings("\n").Trim()));

        // Whatever today's catalog holds: each form's statement is matched by the earlier forms alone.
        var listed = SqlObserverStatements.EarlierRcaXe00.SelectMany(HarnessText.Statements).Select(HarnessText.Normalize).ToHashSet(StringComparer.Ordinal);
        Assert.All(earlier, form => Assert.Contains(HarnessText.Normalize(Assert.Single(Kept(form))), listed));
        Assert.NotEqual(HarnessText.Normalize(Kept(earlier[0])[0]), HarnessText.Normalize(Kept(earlier[1])[0]));
    }

    [Fact]
    public void TheRunnersSplitterFindsTheStatementsScriptDomFinds()
    {
        Assert.Equal(DatabaseScoped(CaptureCatalog.Get("RCA-XE-05")), CaptureCatalog.DatabaseScopedDrop());
        var today = Sent.Select(id => ($"today's {id}", CaptureCatalog.Get(id))).Append(("today's RCA-XE-05 (T3)", CaptureCatalog.DatabaseScopedDrop()));
        var earlierForms = SqlObserverStatements.EarlierRcaXe00.Select((form, i) => ($"EarlierRcaXe00[{i}]", form));
        foreach (var (where, batch) in Earlier().Concat(today).Concat(earlierForms))
        {
            var expected = Kept(batch).Select(HarnessText.Normalize).ToList();
            var split = HarnessText.Statements(batch).Select(HarnessText.Normalize).ToList();
            Assert.True(expected.SequenceEqual(split), $"{where}:{Environment.NewLine}{string.Join(Environment.NewLine, expected)}{Environment.NewLine}---{Environment.NewLine}{string.Join(Environment.NewLine, split)}");
        }
    }

    [Theory]
    [InlineData("SET NOCOUNT ON; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;\nSELECT 1 AS a; SET @x = (SELECT 2);", "SELECT 1 AS a", "SET @x = (SELECT 2)")]
    [InlineData("SELECT ';' AS a, [b;c], \"d;e\" FROM t /* ; */ -- ;\nWHERE f = 1", "SELECT ';' AS a, [b;c], \"d;e\" FROM t /* ; */ -- ;\nWHERE f = 1")]
    [InlineData("IF NOT EXISTS (SELECT 1 FROM t WHERE a = N'x')\n    CREATE TABLE x (a int);\nELSE\n    SELECT 2;", "IF NOT EXISTS (SELECT 1 FROM t WHERE a = N'x')", "CREATE TABLE x (a int)", "IF NOT EXISTS (SELECT 1 FROM t WHERE a = N'x')\n    CREATE TABLE x (a int)", "SELECT 2")]
    [InlineData("IF @a = 1 IF @b = 2 SELECT 3;", "IF @a = 1", "IF @b = 2", "SELECT 3", "IF @b = 2 SELECT 3", "IF @a = 1 IF @b = 2 SELECT 3")]
    public void TheSplitterGivesEachStatementQueryStoreMayKeep(string batch, params string[] statements) =>
        Assert.Equal(statements, HarnessText.Statements(batch));

    [Theory]
    [InlineData("SET NOCOUNT ON;")]
    [InlineData("SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;")]
    [InlineData("SET LOCK_TIMEOUT 1000;")]
    [InlineData("SET XACT_ABORT ON;")]
    [InlineData("DECLARE @db sysname;")]
    [InlineData("SELECT c.object_name, c.name FROM sys.dm_xe_object_columns AS c WHERE c.column_type = N'data' ORDER BY c.object_name, c.name;")]
    [InlineData("SELECT s.name FROM sys.server_event_sessions AS s;")]
    [InlineData("IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = N'x')")]
    public void ASessionOptionOrAnotherStatementOfTheSameShapeStaysEvidence(string statement) =>
        Assert.False(HarnessStatements.IsRunners(statement), statement);

    /// <summary>
    /// Against a disposable SQL Server (CONTOSOCARE_TEST_SQL_SERVER, Windows authentication, as SqlIntegrationTests), in a
    /// database of its own with Query Store capturing ALL: the blocks the release's runner sends to SQL Server, as edd01c86
    /// had them, in the observer's order (Azure SQL Database's RCA-AZ-01, RCA-XE-03, and RCA-XE-04 aside), and f16b9cb9's
    /// RCA-XE-00; then RCA-SQL-16. The match must take every statement Query Store recorded outside a module for the
    /// runner's, edd01c86's RCA-XE-00 among them, though its 10 s timeout may cut it short. CI doesn't set it; Final tests
    /// runs it at the rehearsal. It creates and drops the observer's server-scoped event session, as the observer does.
    /// </summary>
    [Fact]
    public async Task OnSqlServerEveryStatementTheEarlierObserverSentIsMatched()
    {
        Assert.SkipUnless(SqlIntegrationTests.Server is not null, $"Set {SqlIntegrationTests.ServerVariable} to a disposable SQL Server instance to run this test.");
        var token = TestContext.Current.CancellationToken;
        var edd01c86 = CaptureCatalog.Parse(RcaSqlCatalogHistory.Edd01c86);
        var database = "ContosoCareXe" + Guid.NewGuid().ToString("N")[..12];
        var master = new SqlConnectionStringBuilder { DataSource = SqlIntegrationTests.Server, InitialCatalog = "master", IntegratedSecurity = true, TrustServerCertificate = true, Pooling = false }.ConnectionString;
        await using (var create = new SqlConnection(master))
        {
            await create.OpenAsync(token);
            await RunAsync(create, $"CREATE DATABASE [{database}];", TimeSpan.FromMinutes(2), token);
        }

        var texts = new List<string>();
        try
        {
            await using var connection = new SqlConnection(new SqlConnectionStringBuilder(master) { InitialCatalog = database }.ConnectionString);
            await connection.OpenAsync(token);
            await RunAsync(connection, "ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1); ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;", TimeSpan.FromMinutes(2), token);
            var since = DateTimeOffset.UtcNow.AddMinutes(-5);
            string[] batches =
            [
                .. EngineOrder.Select(id => edd01c86[id]),
                CaptureCatalog.Parse(RcaSqlCatalogHistory.F16b9cb9RcaXe00)["RCA-XE-00"],
            ];
            foreach (var batch in batches)
            {
                try
                {
                    await RunAsync(connection, batch, TimeSpan.FromSeconds(10), token);
                }
                catch (SqlException)
                {
                    // Its timeout, as on T1 at each observer start, or what this server refuses: Query Store keeps what compiled.
                }
            }

            await RunAsync(connection, "EXEC sys.sp_query_store_flush_db;", TimeSpan.FromMinutes(2), token);
            await using var read = Command(connection, CaptureCatalog.Get("RCA-SQL-16"), TimeSpan.FromMinutes(2));
            read.Parameters.Add(new SqlParameter("@since", SqlDbType.DateTimeOffset) { Value = since });
            read.Parameters.Add(new SqlParameter("@final", SqlDbType.Bit) { Value = true });
            await using var reader = await read.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
            {
                texts.Add(reader.GetString(1));
            }
        }
        finally
        {
            await using var drop = new SqlConnection(master);
            await drop.OpenAsync(CancellationToken.None);
            await RunAsync(drop, edd01c86["RCA-XE-05"], TimeSpan.FromMinutes(2), CancellationToken.None);
            await RunAsync(drop, $"ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{database}];", TimeSpan.FromMinutes(2), CancellationToken.None);
        }

        Assert.Contains(texts, t => t.Contains("FROM sys.dm_xe_objects AS o", StringComparison.Ordinal));
        Assert.Contains(texts, t => t.Contains("event_name  = c.object_name", StringComparison.Ordinal));
        Assert.All(texts, t => Assert.True(HarnessStatements.IsRunners(t), $"Query Store kept a statement of the earlier observer's that the match doesn't take for the runner's: {t}"));
    }

    /// <summary>The blocks the release's runner sends, as edd01c86 has them, its T3 drop, and RCA-XE-00 as f16b9cb9 changed it.</summary>
    private static IEnumerable<(string Where, string Batch)> Earlier()
    {
        var edd01c86 = CaptureCatalog.Parse(RcaSqlCatalogHistory.Edd01c86);
        foreach (var id in Sent)
        {
            yield return ($"edd01c86's {id}", edd01c86[id]);
        }

        yield return ("edd01c86's RCA-XE-05 (T3)", DatabaseScoped(edd01c86["RCA-XE-05"]));
        yield return ("f16b9cb9's RCA-XE-00", CaptureCatalog.Parse(RcaSqlCatalogHistory.F16b9cb9RcaXe00)["RCA-XE-00"]);
    }

    /// <summary>RCA-XE-05 as T3's observer sends it: the replacements CaptureCatalog.DatabaseScopedDrop makes, which a test checks.</summary>
    private static string DatabaseScoped(string drop) => drop
        .Replace("sys.dm_xe_sessions", "sys.dm_xe_database_sessions", StringComparison.Ordinal)
        .Replace("sys.server_event_sessions", "sys.database_event_sessions", StringComparison.Ordinal)
        .Replace("ON SERVER", "ON DATABASE", StringComparison.Ordinal);

    /// <summary>
    /// What Query Store may keep of a batch, found with ScriptDom: each statement but a session option's SET; of an IF, its
    /// condition (from IF to its predicate's end), its branches' statements, and the whole; of a BEGIN ... END, its statements.
    /// </summary>
    private static List<string> Kept(string batch)
    {
        var script = (TSqlScript)new TSql160Parser(initialQuotedIdentifiers: true).Parse(new StringReader(batch), out var errors);
        Assert.True(errors.Count == 0, string.Join("; ", errors.Select(e => e.Message)));
        var kept = new List<string>();
        foreach (var statement in script.Batches.SelectMany(b => b.Statements))
        {
            Add(statement);
        }

        return kept;

        void Add(TSqlStatement statement)
        {
            switch (statement)
            {
                case IfStatement branch:
                    kept.Add(batch[branch.StartOffset..(branch.Predicate.StartOffset + branch.Predicate.FragmentLength)]);
                    Add(branch.ThenStatement);
                    if (branch.ElseStatement is { } otherwise)
                    {
                        Add(otherwise);
                    }

                    kept.Add(batch.Substring(branch.StartOffset, branch.FragmentLength));
                    break;
                case BeginEndBlockStatement block:
                    foreach (var inner in block.StatementList.Statements)
                    {
                        Add(inner);
                    }

                    break;
                case SetOnOffStatement or SetTransactionIsolationLevelStatement or SetCommandStatement or SetRowCountStatement or SetTextSizeStatement or SetErrorLevelStatement:
                    break;
                default:
                    kept.Add(batch.Substring(statement.StartOffset, statement.FragmentLength));
                    break;
            }
        }
    }

    private static async Task RunAsync(SqlConnection connection, string sql, TimeSpan timeout, CancellationToken token)
    {
        await using var command = Command(connection, sql, timeout);
        await using var reader = await command.ExecuteReaderAsync(token);
        do
        {
            while (await reader.ReadAsync(token))
            {
            }
        }
        while (await reader.NextResultAsync(token));
    }

    private static SqlCommand Command(SqlConnection connection, string sql, TimeSpan timeout)
    {
        var command = connection.CreateCommand();
#pragma warning disable CA2100 // The catalog's blocks, as earlier runners sent them, and the test's own, on a disposable database it names itself.
        command.CommandText = sql;
#pragma warning restore CA2100
        command.CommandTimeout = (int)timeout.TotalSeconds;
        return command;
    }
}

/// <summary>
/// The tests that create and drop the observer's server-scoped event session on a real SQL Server run by themselves, never
/// beside RcaIntegrationTests, which checks that session.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class SqlEventSessionSerial
{
    public const string Name = "SQL Server's event session";
}
