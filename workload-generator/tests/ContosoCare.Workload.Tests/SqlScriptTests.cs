using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// SQL lint. Every T-SQL script under database/ and scenarios/ must parse with the SQL Server 2022 grammar
/// (TSql160Parser); bootstrap tokens such as {{DATA_DIRECTORY}} appear only inside string literals. The demo scripts
/// (database/common/1*.sql) also follow the safety rules of ADR 0010: bounded loops that check the deadline and stop
/// flag, nothing outside the ContosoCare database, and KILL only for ContosoCare.Demo/ sessions.
/// </summary>
public sealed class SqlScriptTests
{
    private static readonly Lazy<IReadOnlyList<(string Path, TSqlScript Script, string Text)>> DemoScripts = new(() =>
        [.. Directory.GetFiles(RepositoryPaths.Combine("database", "common"), "1*.sql").Order(StringComparer.Ordinal).Select(path => (path, Parse(path), File.ReadAllText(path)))]);

    public static TheoryData<string> SqlScripts()
    {
        var data = new TheoryData<string>();
        foreach (var path in EnumerateSqlScripts())
        {
            data.Add(RepositoryPaths.Relative(path));
        }

        return data;
    }

    [Fact]
    public void DatabaseFolderHasScripts()
    {
        Assert.NotEmpty(EnumerateSqlScripts());
        Assert.Equal(["110-demo-control.sql", "120-scenario-procedures.sql"], DemoScripts.Value.Select(s => Path.GetFileName(s.Path)));
    }

    [Theory]
    [MemberData(nameof(SqlScripts))]
    public void ScriptParsesWithoutErrors(string relativePath)
    {
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = File.OpenText(Path.Combine(RepositoryPaths.Root, relativePath));

        parser.Parse(reader, out var errors);

        var messages = errors.Select(error => $"{relativePath}({error.Line},{error.Column}): {error.Message}");
        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, messages));
    }

    [Fact]
    public void DemoScriptsStayInsideTheContosoCareDatabase()
    {
        var findings = new List<string>();
        foreach (var (path, script, _) in DemoScripts.Value)
        {
            var visitor = new SafetyVisitor();
            script.Accept(visitor);
            findings.AddRange(visitor.Findings.Select(f => $"{Path.GetFileName(path)}: {f}"));
        }

        Assert.True(findings.Count == 0, string.Join(Environment.NewLine, findings));
    }

    [Fact]
    public void EveryLoopIsBoundedByTimeOrACounter()
    {
        var unbounded = new List<string>();
        foreach (var (path, script, text) in DemoScripts.Value)
        {
            var visitor = new WhileVisitor();
            script.Accept(visitor);
            foreach (var loop in visitor.Loops)
            {
                var predicate = Slice(text, loop.Predicate);
                if (!predicate.Contains("@deadline", StringComparison.OrdinalIgnoreCase)
                    && !predicate.Contains("_until", StringComparison.OrdinalIgnoreCase)
                    && !predicate.Contains("@remaining", StringComparison.OrdinalIgnoreCase))
                {
                    unbounded.Add($"{Path.GetFileName(path)}({loop.StartLine}): WHILE {predicate}");
                }
            }
        }

        Assert.True(unbounded.Count == 0, "Loops must test a deadline (@deadline, @*_until) or a decreasing @remaining counter:" + Environment.NewLine + string.Join(Environment.NewLine, unbounded));
    }

    [Fact]
    public void EveryScenarioProcedureChecksItsRunAndStopFlag()
    {
        var problems = new List<string>();
        foreach (var procedure in Procedures().Where(p => p.Name.StartsWith("demo.usp_scenario_", StringComparison.Ordinal)))
        {
            if (!procedure.Text.Contains("EXEC demo.usp_run_assert_running", StringComparison.Ordinal))
            {
                problems.Add($"{procedure.Name} doesn't call demo.usp_run_assert_running first.");
            }

            if (procedure.HasLoop && !procedure.Text.Contains("demo.fn_run_should_stop(@run_id)", StringComparison.Ordinal))
            {
                problems.Add($"{procedure.Name} loops without checking demo.fn_run_should_stop.");
            }
        }

        Assert.True(problems.Count == 0, string.Join(Environment.NewLine, problems));
        Assert.True(Procedures().Count(p => p.Name.StartsWith("demo.usp_scenario_", StringComparison.Ordinal)) >= 11);
    }

    [Fact]
    public void KillOnlyTargetsDemoSessionsInThisDatabase()
    {
        var withKill = Procedures().Where(p => p.Text.Contains("N'KILL '", StringComparison.Ordinal) || p.Text.Contains("KILL @", StringComparison.OrdinalIgnoreCase)).ToList();

        var procedure = Assert.Single(withKill);
        Assert.Equal("demo.usp_kill_demo_sessions", procedure.Name);
        Assert.Contains("demo.fn_demo_sessions(@run_id)", procedure.Text, StringComparison.Ordinal);
        Assert.Contains("s.program_name LIKE 'ContosoCare.Demo/%'", procedure.Text, StringComparison.Ordinal);
        Assert.Contains("s.program_name NOT LIKE 'ContosoCare.Demo/control/%'", procedure.Text, StringComparison.Ordinal);
        Assert.Contains("s.database_id = DB_ID()", procedure.Text, StringComparison.Ordinal);
        Assert.Contains("s.login_time = @login", procedure.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void SessionQueriesFilterOnTheDemoPrefix()
    {
        foreach (var (path, _, text) in DemoScripts.Value)
        {
            foreach (var module in Modules(text).Where(m => m.Contains("sys.dm_exec_sessions", StringComparison.Ordinal)))
            {
                Assert.True(module.Contains("LIKE 'ContosoCare.Demo/%'", StringComparison.Ordinal), $"{Path.GetFileName(path)}: a module reads sys.dm_exec_sessions without the ContosoCare.Demo/ filter.");
                Assert.True(module.Contains("DB_ID()", StringComparison.Ordinal), $"{Path.GetFileName(path)}: a module reads sys.dm_exec_sessions without the database filter.");
            }
        }
    }

    [Fact]
    public void ScenariosNeverCommitChangesToBusinessData()
    {
        var problems = new List<string>();
        foreach (var procedure in Procedures().Where(p => p.Name.StartsWith("demo.usp_scenario_", StringComparison.Ordinal) && p.Name != "demo.usp_scenario_healthy_baseline"))
        {
            if (procedure.WritesCare && procedure.HasCommit)
            {
                problems.Add($"{procedure.Name} changes care.* tables and commits.");
            }
        }

        Assert.True(problems.Count == 0, string.Join(Environment.NewLine, problems));
        Assert.Equal(["demo.usp_scenario_log_rate_pressure"], Procedures().Where(p => p.HasCommit && p.Name.StartsWith("demo.usp_scenario_", StringComparison.Ordinal)).Select(p => p.Name));
    }

    [Fact]
    public void TheRunnerCannotApplyTheRemediation()
    {
        var project = File.ReadAllText(RepositoryPaths.Combine("workload-generator", "src", "ContosoCare.Workload", "ContosoCare.Workload.csproj"));
        var sources = Directory.GetFiles(RepositoryPaths.Combine("workload-generator", "src"), "*.cs", SearchOption.AllDirectories).Select(File.ReadAllText).ToList();

        Assert.DoesNotContain("remediation", string.Join("\n", project.Split('\n').Where(l => l.Contains("EmbeddedResource", StringComparison.Ordinal))), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(@"scenarios\**\*.sql", project, StringComparison.OrdinalIgnoreCase);
        Assert.All(sources, source => Assert.DoesNotContain("CREATE INDEX", source, StringComparison.OrdinalIgnoreCase));
        Assert.Contains("CREATE INDEX ix_claims_payer_submitted", File.ReadAllText(RepositoryPaths.Combine("scenarios", "missing-index", "remediation.sql")), StringComparison.Ordinal);
    }

    [Fact]
    public void TheUndoDropsExactlyTheRemediationIndexes()
    {
        var remediation = File.ReadAllText(RepositoryPaths.Combine("scenarios", "missing-index", "remediation.sql"));
        var undo = Procedures().Single(p => p.Name == "demo.usp_undo_missing_index_remediation").Text;

        foreach (var index in new[] { "ix_claims_payer_submitted", "ix_appointments_reason" })
        {
            Assert.Contains("CREATE INDEX " + index, remediation, StringComparison.Ordinal);
            Assert.Contains("DROP INDEX " + index, undo, StringComparison.Ordinal);
        }

        Assert.Equal(2, CountOccurrences(undo, "DROP INDEX "));
    }

    [Fact]
    public void TheDemoScriptsEmbedInTheRunner()
    {
        var assembly = typeof(Program).Assembly;
        foreach (var (path, _, text) in DemoScripts.Value)
        {
            Assert.Equal(text.ReplaceLineEndings(), Sql.SqlScripts.Read(Path.GetFileName(path)).ReplaceLineEndings());
        }

        Assert.Contains("sql/010-schema.sql", assembly.GetManifestResourceNames());
        Assert.DoesNotContain("sql/900-status.sql", assembly.GetManifestResourceNames());
    }

    [Fact]
    public void BatchesSplitOnGoLines()
    {
        var batches = Sql.SqlScripts.SplitBatches("SELECT 1;\nGO\n\nSELECT 'GO';\n  go  -- comment\nSELECT 2;\nGO\n");

        Assert.Equal(["SELECT 1;", "SELECT 'GO';", "SELECT 2;"], batches);
    }

    /// <summary>Procedure name to its parameter names, for every procedure in database/common/1*.sql.</summary>
    public static Dictionary<string, HashSet<string>> ProcedureParameters() =>
        Procedures().ToDictionary(p => p.Name, p => p.Parameters, StringComparer.Ordinal);

    /// <summary>The text of one procedure in database/common/1*.sql.</summary>
    public static string ProcedureText(string name) => Procedures().Single(p => p.Name == name).Text;

    private static List<ProcedureInfo> Procedures()
    {
        var procedures = new List<ProcedureInfo>();
        foreach (var (_, script, text) in DemoScripts.Value)
        {
            var visitor = new ProcedureVisitor(text);
            script.Accept(visitor);
            procedures.AddRange(visitor.Procedures);
        }

        return procedures;
    }

    private static TSqlScript Parse(string path)
    {
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = File.OpenText(path);
        var fragment = parser.Parse(reader, out var errors);
        Assert.True(errors.Count == 0, $"{path} doesn't parse.");
        return (TSqlScript)fragment;
    }

    // T4's PostgreSQL scripts (database/postgresql) have their own tests (PostgresScriptTests); the T-SQL grammar
    // doesn't apply to them.
    private static string[] EnumerateSqlScripts() =>
    [
        .. Directory.GetFiles(RepositoryPaths.Combine("database"), "*.sql", SearchOption.AllDirectories)
            .Where(path => !RepositoryPaths.Relative(path).StartsWith("database/postgresql/", StringComparison.Ordinal))
            .Concat(Directory.GetFiles(RepositoryPaths.Combine("scenarios"), "*.sql", SearchOption.AllDirectories))
            .Order(StringComparer.Ordinal),
    ];

    private static string Slice(string text, TSqlFragment fragment) => text.Substring(fragment.StartOffset, fragment.FragmentLength);

    private static string[] Modules(string text) => text.Split("\nGO", StringSplitOptions.RemoveEmptyEntries);

    private static int CountOccurrences(string text, string value)
    {
        var count = 0;
        for (var index = text.IndexOf(value, StringComparison.Ordinal); index >= 0; index = text.IndexOf(value, index + value.Length, StringComparison.Ordinal))
        {
            count++;
        }

        return count;
    }

    private sealed record ProcedureInfo(string Name, HashSet<string> Parameters, string Text, bool HasLoop, bool HasCommit, bool WritesCare);

    private sealed class ProcedureVisitor(string text) : TSqlFragmentVisitor
    {
        public List<ProcedureInfo> Procedures { get; } = [];

        public override void Visit(CreateOrAlterProcedureStatement node)
        {
            var name = $"{node.ProcedureReference.Name.SchemaIdentifier?.Value}.{node.ProcedureReference.Name.BaseIdentifier.Value}";
            var parameters = node.Parameters.Select(p => p.VariableName.Value).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var inner = new BodyVisitor();
            node.Accept(inner);
            Procedures.Add(new ProcedureInfo(name, parameters, text.Substring(node.StartOffset, node.FragmentLength), inner.HasLoop, inner.HasCommit, inner.WritesCare));
        }
    }

    private sealed class BodyVisitor : TSqlFragmentVisitor
    {
        public bool HasLoop { get; private set; }

        public bool HasCommit { get; private set; }

        public bool WritesCare { get; private set; }

        public override void Visit(WhileStatement node) => HasLoop = true;

        public override void Visit(CommitTransactionStatement node) => HasCommit = true;

        public override void Visit(UpdateSpecification node) => WritesCare |= Targets(node.Target, node.FromClause);

        public override void Visit(InsertSpecification node) => WritesCare |= Targets(node.Target, null);

        public override void Visit(DeleteSpecification node) => WritesCare |= Targets(node.Target, node.FromClause);

        // A care.* target, directly or through an alias defined in the FROM clause (UPDATE w ... FROM care.work_queues AS w).
        private static bool Targets(TableReference? target, FromClause? from)
        {
            if (target is not NamedTableReference named)
            {
                return false;
            }

            if (IsCare(named.SchemaObject))
            {
                return true;
            }

            if (named.SchemaObject.SchemaIdentifier is not null || from is null)
            {
                return false;
            }

            var tables = new TableCollector();
            from.Accept(tables);
            return tables.Tables.Any(t => string.Equals(t.Alias?.Value, named.SchemaObject.BaseIdentifier.Value, StringComparison.OrdinalIgnoreCase) && IsCare(t.SchemaObject));
        }

        private static bool IsCare(SchemaObjectName name) => string.Equals(name.SchemaIdentifier?.Value, "care", StringComparison.OrdinalIgnoreCase);
    }

    private sealed class TableCollector : TSqlFragmentVisitor
    {
        public List<NamedTableReference> Tables { get; } = [];

        public override void Visit(NamedTableReference node) => Tables.Add(node);
    }
    private sealed class WhileVisitor : TSqlFragmentVisitor
    {
        public List<(BooleanExpression Predicate, int StartLine)> Loops { get; } = [];

        public override void Visit(WhileStatement node) => Loops.Add((node.Predicate, node.StartLine));
    }

    private sealed class SafetyVisitor : TSqlFragmentVisitor
    {
        private static readonly string[] ForbiddenProcedures = ["xp_", "sp_configure", "sp_addsrvrolemember", "sp_addlinkedserver"];

        public List<string> Findings { get; } = [];

        public override void Visit(UseStatement node) => Findings.Add($"line {node.StartLine}: USE");

        public override void Visit(DbccStatement node) => Findings.Add($"line {node.StartLine}: DBCC");

        public override void Visit(ShutdownStatement node) => Findings.Add($"line {node.StartLine}: SHUTDOWN");

        public override void Visit(AlterDatabaseStatement node) => Findings.Add($"line {node.StartLine}: ALTER DATABASE");

        public override void Visit(CreateDatabaseStatement node) => Findings.Add($"line {node.StartLine}: CREATE DATABASE");

        public override void Visit(DropDatabaseStatement node) => Findings.Add($"line {node.StartLine}: DROP DATABASE");

        public override void Visit(CreateLoginStatement node) => Findings.Add($"line {node.StartLine}: CREATE LOGIN");

        public override void Visit(AlterLoginStatement node) => Findings.Add($"line {node.StartLine}: ALTER LOGIN");

        public override void Visit(BackupStatement node) => Findings.Add($"line {node.StartLine}: BACKUP");

        public override void Visit(RestoreStatement node) => Findings.Add($"line {node.StartLine}: RESTORE");

        public override void Visit(KillStatement node) => Findings.Add($"line {node.StartLine}: a literal KILL (only demo.usp_kill_demo_sessions may kill, after filtering)");

        public override void Visit(SchemaObjectName node)
        {
            if (node.DatabaseIdentifier is not null || node.ServerIdentifier is not null)
            {
                Findings.Add($"line {node.StartLine}: a three- or four-part name ({string.Join(".", node.Identifiers.Select(i => i.Value))})");
            }
        }

        public override void Visit(ExecutableProcedureReference node)
        {
            var name = node.ProcedureReference?.ProcedureReference?.Name?.BaseIdentifier?.Value ?? string.Empty;
            if (ForbiddenProcedures.Any(f => name.StartsWith(f, StringComparison.OrdinalIgnoreCase)))
            {
                Findings.Add($"line {node.StartLine}: EXEC {name}");
            }
        }
    }
}
