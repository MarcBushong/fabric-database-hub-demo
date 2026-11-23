using System.Data;
using System.Globalization;
using System.Text;
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
/// runner sends them and Query Store keeps them match, and a workload statement of the same shape elsewhere doesn't. Every
/// command the runner sends to SQL Server is listed, carries the observer's marker (the capture's own, and the answer
/// key's read), or calls a module. Against a real engine, opt-in, every statement Query Store recorded outside a module
/// while only the runner's own ran is matched.
/// </summary>
public sealed partial class RcaHarnessStatementsTests
{
    private const string Marker = "/* dbhubdemo:rca-observer */";

    /// <summary>The runner's source: the scan reads every file of it that uses SQL Server's client.</summary>
    private static readonly string SourceRoot = RepositoryPaths.Combine("workload-generator", "src", "ContosoCare.Workload");

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
    public void EveryCommandTheRunnerSendsToSqlServerIsListedMarkedOrAModuleCall()
    {
        // Every CommandText the runner's source sets for SQL Server, read where it's set, or where an indirection says.
        var sites = CommandSites();

        // PostgreSQL's (T4) have their own rules: in the files that use both clients, only the answer key's T4 read.
        Assert.Equal(["Rca/AnswerKey/AnswerKeyRecorder.cs"], sites.Where(s => s.Postgres).Select(s => s.File));

        var unread = new List<string>();
        var unlisted = new List<string>();
        var listed = new List<string>();
        var marked = new List<string>();
        foreach (var site in sites.Where(s => !s.Postgres))
        {
            var texts = site.Literal is { } literal ? [($"{site.File}:{site.Line}", literal)] : Indirect(site).ToList();
            foreach (var (where, text) in texts)
            {
                if (text is null)
                {
                    unread.Add(where);
                    continue;
                }

                // A module's name (CommandType.StoredProcedure): a module call, which Query Store records as the module's.
                if (ModuleName().IsMatch(text.Trim()))
                {
                    continue;
                }

                // Each query statement, those within IF and BEGIN included; a batch with none (EXEC, SET, DDL) is a module call or nothing Query Store records.
                foreach (var statement in QueryStatements(text))
                {
                    if (HarnessStatements.IsRunners(statement))
                    {
                        listed.Add(statement);
                    }
                    else if (statement.Contains(Marker, StringComparison.Ordinal))
                    {
                        marked.Add(where);
                    }
                    else
                    {
                        unlisted.Add($"{where}: {statement}");
                    }
                }
            }
        }

        Assert.True(unread.Count == 0, $"The scan can't read these command texts as literals; read them, or say where the test reads them instead (Indirect):\n{string.Join('\n', unread)}");
        Assert.True(unlisted.Count == 0, $"These statements the runner sends to SQL Server aren't on Rca/QueryStore/HarnessStatements.cs's list, don't carry the observer's marker after their first keyword, and don't call a module:\n{string.Join('\n', unlisted)}");

        // Today's: the stop check every run polls and the ten statements the list has had since edd01c86; the answer key's
        // read and the capture catalog's blocks carry the marker.
        Assert.Contains(listed, s => s.Contains("fn_run_stop_requested", StringComparison.Ordinal));
        Assert.True(listed.Select(HarnessText.Normalize).Distinct(StringComparer.Ordinal).Count() >= 10, string.Join('\n', listed));
        Assert.Contains(marked, m => m.StartsWith("Rca/AnswerKey/AnswerKeyRecorder.cs:", StringComparison.Ordinal));
        Assert.Contains("RCA-SQL-10", marked);
    }

    [Fact]
    public void TheAnswerKeysReadCarriesTheObserversMarkerSoQueryStoresReadsLeaveItOut()
    {
        // The answer key's read of a run's events on T1 to T3, after every run: the marker is inside its statement, after
        // its first keyword, so Query Store keeps it with the text.
        var site = Assert.Single(CommandSites(), s => s.File == "Rca/AnswerKey/AnswerKeyRecorder.cs" && !s.Postgres);
        var statement = Assert.Single(QueryStatements(Assert.IsType<string>(site.Literal)));
        Assert.Contains(Marker, statement, StringComparison.Ordinal);

        // As Query Store keeps it from sp_executesql, its parameter's declaration first: RCA-SQL-10, 14, and 16 each leave
        // out a text their rule on the observer's marker matches.
        var kept = "(@run_id varchar(64))" + statement;
        foreach (var id in new[] { "RCA-SQL-10", "RCA-SQL-14", "RCA-SQL-16" })
        {
            Assert.Matches(Like(MarkerRule(id)), kept);
        }
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

    /// <summary>
    /// Every CommandText set, and every SqlCommand or SqlBatchCommand made, in the runner's source files that use SQL
    /// Server's client. A site is PostgreSQL's when the client named nearest before it is Npgsql's: a file can use both.
    /// </summary>
    private static List<CommandSite> CommandSites()
    {
        var sites = new List<CommandSite>();
        foreach (var path in Directory.GetFiles(SourceRoot, "*.cs", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
        {
            var file = Path.GetRelativePath(SourceRoot, path).Replace('\\', '/');
            var code = File.ReadAllText(path);
            if (file.StartsWith("bin/", StringComparison.Ordinal) || file.StartsWith("obj/", StringComparison.Ordinal) || !SqlServerClient().IsMatch(code))
            {
                continue;
            }

            foreach (var site in CommandTextSite().Matches(code).Cast<Match>())
            {
                var before = code[..site.Index];
                var sqlServer = SqlServerClient().Matches(before).LastOrDefault()?.Index ?? -1;
                var postgres = PostgresClient().Matches(before).LastOrDefault()?.Index ?? -1;
                var made = before.LastIndexOf("CreateCommand()", StringComparison.Ordinal);
                var (literal, expression) = Assigned(code, site.Index + site.Length);
                sites.Add(new CommandSite(file, Line(code, site.Index), literal, expression, made < 0 ? string.Empty : before[made..], postgres > sqlServer));
            }
        }

        return sites;
    }

    /// <summary>
    /// Where the scan reads a command text that isn't a literal where it's set, and what it is; null for one it can't
    /// read. Any other expression fails the scan.
    /// </summary>
    private static IEnumerable<(string Where, string? Text)> Indirect(CommandSite site) => (site.File, site.Expression) switch
    {
        // DemoDatabase's helpers: Text("...") sends a statement and Procedure("...") calls a module, each with its literal.
        ("Sql/DemoDatabase.cs", "sql") => HelperCalls(site.File, "Text"),
        ("Sql/DemoDatabase.cs", "name") => HelperCalls(site.File, "Procedure"),

        // The embedded scripts' batches: setup's, at a deploy or a start (rca/README.md, What the capture leaves out, 3:
        // not on the list).
        ("Sql/SqlScripts.cs", "batch") => [],

        // The capture catalog's blocks, the observer's own: its event session's drop among them.
        ("Rca/Observer/SqlCapture.cs", "text") => CatalogBlocks(),
        ("Cli/CommandLine.Rca.cs", "target == DemoTarget.T3 ? CaptureCatalog.DatabaseScopedDrop() : CaptureCatalog.Get(\"RCA-XE-05\")") => CatalogBlocks(),

        // A scenario's module, named by the scenario catalog, called as a stored procedure.
        ("Runs/ScenarioRunner.cs", "plan.Scenario.Procedure" or "procedure") when site.Made.Contains("CommandType.StoredProcedure", StringComparison.Ordinal) => [],

        // The idle holders' batches, each a literal where its holder is made.
        ("Runs/ScenarioRunner.cs", "holder.AcquireSql") => HolderBatches(site.File),

        _ => [($"{site.File}:{site.Line}: CommandText = {site.Expression}", null)],
    };

    /// <summary>The text set at <paramref name="at"/>: a string literal's value when it's one alone (regular, verbatim, or raw), and the expression otherwise.</summary>
    private static (string? Literal, string Expression) Assigned(string code, int at)
    {
        var literal = StringLiteral().Match(code, at);
        if (literal.Success && code[(literal.Index + literal.Length)..].TrimStart() is [';' or ',' or ')', ..])
        {
            var value = literal.Groups["raw"].Success ? literal.Groups["raw"].Value
                : literal.Groups["verbatim"].Success ? literal.Groups["verbatim"].Value.Replace("\"\"", "\"", StringComparison.Ordinal)
                : literal.Groups["text"].Value.Replace("\\\"", "\"", StringComparison.Ordinal).Replace("\\\\", "\\", StringComparison.Ordinal);
            return (value, literal.Value);
        }

        var end = code.IndexOf(';', at);
        return (null, Whitespace().Replace(code[at..(end < 0 ? code.Length : end)], " ").Trim());
    }

    /// <summary>Each call of DemoDatabase's own helper, Text or Procedure, with its literal; null for one the scan can't read.</summary>
    private static IEnumerable<(string Where, string? Text)> HelperCalls(string file, string helper)
    {
        var code = File.ReadAllText(Path.Combine(SourceRoot, file));
        var calls = HelperCall().Matches(code).Where(m => m.Groups["helper"].Value == helper).ToList();
        if (calls.Count == 0)
        {
            return [($"{file}: no call of {helper}", null)];
        }

        return calls.Select(m => ($"{file}:{Line(code, m.Index)}", Assigned(code, m.Index + m.Length).Literal));
    }

    /// <summary>The batch each idle holder runs, the first argument where it's made; null for one the scan can't read.</summary>
    private static IEnumerable<(string Where, string? Text)> HolderBatches(string file)
    {
        var code = File.ReadAllText(Path.Combine(SourceRoot, file));
        var made = IdleHolderMade().Matches(code).ToList();
        if (made.Count == 0)
        {
            return [($"{file}: no idle holder made", null)];
        }

        return made.Select(m => ($"{file}:{Line(code, m.Index)}", Assigned(code, m.Index + m.Length).Literal));
    }

    /// <summary>The capture catalog's T-SQL blocks, RCA-XE-05's database-scoped form among them.</summary>
    private static IEnumerable<(string Where, string? Text)> CatalogBlocks() =>
        CaptureCatalog.All.Where(b => !b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal))
            .Select(b => (b.Key, (string?)b.Value))
            .Append(("RCA-XE-05 (T3, database-scoped)", CaptureCatalog.DatabaseScopedDrop()));

    private static int Line(string code, int index) => code.AsSpan(0, index).Count('\n') + 1;

    /// <summary>A block's rule on the observer's marker: the pattern of its qt.query_sql_text NOT LIKE.</summary>
    private static string MarkerRule(string id)
    {
        var text = CaptureCatalog.Get(id);
        var script = new TSql160Parser(initialQuotedIdentifiers: true).Parse(new StringReader(text), out var errors);
        Assert.Empty(errors);
        var likes = new LikeVisitor();
        script.Accept(likes);
        var rule = Assert.Single(likes.Found, l => l.NotDefined && text.Substring(l.FirstExpression.StartOffset, l.FirstExpression.FragmentLength) == "qt.query_sql_text");
        return Assert.IsType<StringLiteral>(rule.SecondExpression).Value;
    }

    /// <summary>A T-SQL LIKE pattern as a regular expression: % any text, _ one character, [...] a set; case ignored, as ContosoCare's collation does.</summary>
    private static Regex Like(string pattern)
    {
        var regex = new StringBuilder("^");
        for (var i = 0; i < pattern.Length; i++)
        {
            switch (pattern[i])
            {
                case '%':
                    regex.Append(".*");
                    break;
                case '_':
                    regex.Append('.');
                    break;
                case '[':
                    {
                        var end = pattern.IndexOf(']', i + 1);
                        regex.Append(pattern, i, end - i + 1);
                        i = end;
                        break;
                    }

                default:
                    regex.Append(Regex.Escape(pattern[i..(i + 1)]));
                    break;
            }
        }

        return new Regex(regex.Append('$').ToString(), RegexOptions.Singleline | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    [GeneratedRegex(@"\b(?:Microsoft\.Data\.SqlClient|SqlConnectionOpener|SqlConnection|SqlCommand|SqlCaptureConnector)\b")]
    private static partial Regex SqlServerClient();

    [GeneratedRegex(@"\b(?:Npgsql\w*|PgConnectionOpener|PgConnection)\b")]
    private static partial Regex PostgresClient();

    [GeneratedRegex(@"\bCommandText\s*=(?!=)\s*|\bnew\s+Sql(?:Batch)?Command\s*\(\s*")]
    private static partial Regex CommandTextSite();

    [GeneratedRegex("""\G(?:"{3}(?<raw>[\s\S]*?)"{3}|@"(?<verbatim>(?:[^"]|"")*)"|"(?<text>(?:[^"\\\r\n]|\\.)*)")""")]
    private static partial Regex StringLiteral();

    [GeneratedRegex(@"(?<![\w.]|SqlCommand\s)(?<helper>Text|Procedure)\(\s*")]
    private static partial Regex HelperCall();

    [GeneratedRegex(@"\bnew\s+IdleHolder\(\s*")]
    private static partial Regex IdleHolderMade();

    [GeneratedRegex(@"^\[?\w+\]?\.\[?\w+\]?$")]
    private static partial Regex ModuleName();

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

    private sealed class LikeVisitor : TSqlFragmentVisitor
    {
        public List<LikePredicate> Found { get; } = [];

        public override void Visit(LikePredicate node) => Found.Add(node);
    }

    /// <summary>
    /// A place the runner's source sets a SQL Server command's text: its file and line, the literal when it's one alone and
    /// the expression otherwise, what's done to the command since it was made (its CommandType), and whether it's
    /// PostgreSQL's.
    /// </summary>
    private sealed record CommandSite(string File, int Line, string? Literal, string Expression, string Made, bool Postgres);
}
