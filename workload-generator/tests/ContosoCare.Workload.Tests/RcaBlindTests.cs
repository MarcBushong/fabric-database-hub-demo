using System.Text.Json;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Rca.Observer;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// Blind detection (ADR 0031, rca/blind-detection.json), the runner's side: the observer's code names nothing the
/// workload plans, injects, or reports about itself, only one file knows the workload's application-name prefix, and
/// the observer runs only the capture catalog's read-only statements.
/// </summary>
public sealed partial class RcaBlindTests
{
    // Types that carry what the workload plans or reports about itself: the observer must never reach for them.
    private static readonly string[] PlanTypes = ["ScenarioCatalog", "ScenarioDefinition", "RunPlan", "RunResult", "RunRequest", "ActivityProfile", "ProfileState", "ProfileScheduler", "IAnswerKeySink", "AnswerKeyRecorder", "Rca.AnswerKey", "RunEvent"];

    [Fact]
    public void DetectionCodeNamesNoAnswerKeyIdentifierAndNoScenario()
    {
        using var blind = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "blind-detection.json")));
        var identifiers = blind.RootElement.GetProperty("forbiddenInDetectionCode").GetProperty("identifiers").EnumerateArray().Select(e => e.GetString()!).ToList();
        var exceptions = blind.RootElement.GetProperty("detectionCode").GetProperty("exceptions").EnumerateArray()
            .Select(e => (Identifier: e.GetProperty("identifier").GetString()!, Files: e.GetProperty("files").EnumerateArray().Select(f => f.GetString()!).ToHashSet(StringComparer.Ordinal)))
            .ToList();
        var files = DetectionFiles(blind.RootElement.GetProperty("detectionCode").GetProperty("runner"));
        var scenarioIds = ScenarioIds();
        Assert.NotEmpty(files);
        Assert.Contains("workload-generator/src/ContosoCare.Workload/Rca/Observer/ApplicationNames.cs", files);
        Assert.True(scenarioIds.Count >= 20);

        var findings = new List<string>();
        foreach (var file in files.Append("workload-generator/src/ContosoCare.Workload/Rca/Export/Reducer.cs"))
        {
            var text = File.ReadAllText(Path.Combine(RepositoryPaths.Root, file));
            foreach (var identifier in identifiers.Where(i => text.Contains(i, StringComparison.Ordinal)))
            {
                if (!exceptions.Any(e => e.Identifier == identifier && e.Files.Contains(file)))
                {
                    findings.Add($"{file}: names '{identifier}'");
                }
            }

            foreach (var id in scenarioIds.Where(id => Regex.IsMatch(text, $@"(?<![A-Za-z0-9\-_./]){Regex.Escape(id)}(?![A-Za-z0-9\-_./])")))
            {
                findings.Add($"{file}: names the scenario '{id}'");
            }

            foreach (var type in PlanTypes.Where(t => Regex.IsMatch(text, $@"\b{Regex.Escape(t)}\b")))
            {
                findings.Add($"{file}: uses '{type}', which carries what the workload plans or reports");
            }
        }

        Assert.True(findings.Count == 0, string.Join(Environment.NewLine, findings));
    }

    [Fact]
    public void OnlyApplicationNamesKnowsTheWorkloadsApplicationNames()
    {
        var rca = RepositoryPaths.Combine("workload-generator", "src", "ContosoCare.Workload", "Rca");
        var files = Directory.GetFiles(rca, "*.cs", SearchOption.AllDirectories).Select(f => (Path: Path.GetRelativePath(RepositoryPaths.Root, f).Replace('\\', '/'), Text: File.ReadAllText(f))).ToList();

        var knowing = files.Where(f => f.Text.Contains("ContosoCare.Demo", StringComparison.Ordinal)).Select(f => f.Path).ToList();
        var naming = files.Where(f => f.Path.Contains("/Rca/Observer/", StringComparison.Ordinal) && f.Text.Contains("SessionNames", StringComparison.Ordinal)).Select(f => f.Path).ToList();

        Assert.Equal(["workload-generator/src/ContosoCare.Workload/Rca/Observer/ApplicationNames.cs"], knowing);
        Assert.Empty(naming);
    }

    [Fact]
    public void EveryTSqlBlockParsesAndOnlyReadsOrManagesItsOwnEventSession()
    {
        var blocks = CaptureCatalog.All.Where(b => !b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal)).ToList();
        Assert.Equal(24, blocks.Count);

        var findings = new List<string>();
        foreach (var (id, text) in blocks.Append(new("RCA-XE-05 (T3, database-scoped)", CaptureCatalog.DatabaseScopedDrop())))
        {
            var parser = new TSql160Parser(initialQuotedIdentifiers: true);
            using var reader = new StringReader(text);
            var script = parser.Parse(reader, out var errors);
            findings.AddRange(errors.Select(e => $"{id}({e.Line},{e.Column}): {e.Message}"));
            var visitor = new WriteVisitor();
            script.Accept(visitor);
            findings.AddRange(visitor.Writes.Select(w => $"{id}: {w}"));
            if (Regex.IsMatch(text, @"\bEVENT SESSION\b", RegexOptions.IgnoreCase) && !text.Contains("[ContosoCare_RCA]", StringComparison.Ordinal))
            {
                findings.Add($"{id}: an event session that isn't the observer's own");
            }
        }

        Assert.True(findings.Count == 0, string.Join(Environment.NewLine, findings));
        Assert.Contains("ON DATABASE", CaptureCatalog.DatabaseScopedDrop(), StringComparison.Ordinal);
        Assert.DoesNotContain("ON SERVER", CaptureCatalog.DatabaseScopedDrop(), StringComparison.Ordinal);
    }

    [Fact]
    public void EveryPostgresBlockOnlyReads()
    {
        var blocks = CaptureCatalog.All.Where(b => b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal)).ToList();
        Assert.Equal(12, blocks.Count);

        foreach (var (id, text) in blocks)
        {
            Assert.StartsWith("SELECT", text, StringComparison.Ordinal);
            Assert.False(WritingKeyword().IsMatch(Regex.Replace(text, "'[^']*'", "''")), $"{id} has a statement that writes or locks.");
            Assert.Equal(1, text.Count(c => c == ';'));
        }
    }

    private static List<string> DetectionFiles(JsonElement runner)
    {
        var files = new List<string>();
        foreach (var pattern in runner.GetProperty("include").EnumerateArray().Select(p => p.GetString()!))
        {
            // The contract's runner patterns are <folder>/**/<file pattern>.
            var split = pattern.Split("/**/");
            Assert.Equal(2, split.Length);
            var folder = Path.Combine(RepositoryPaths.Root, split[0].Replace('/', Path.DirectorySeparatorChar));
            files.AddRange(Directory.GetFiles(folder, split[1], SearchOption.AllDirectories).Select(f => Path.GetRelativePath(RepositoryPaths.Root, f).Replace('\\', '/')));
        }

        return [.. files.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)];
    }

    private static List<string> ScenarioIds() =>
        [.. Directory.GetDirectories(RepositoryPaths.Combine("scenarios"))
            .Select(d => Path.Combine(d, "scenario.json"))
            .Where(File.Exists)
            .Select(f =>
            {
                using var scenario = JsonDocument.Parse(File.ReadAllText(f));
                return scenario.RootElement.GetProperty("id").GetString()!;
            })];

    [GeneratedRegex(@"\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|ALTER|DROP|CREATE|GRANT|REVOKE|LOCK|VACUUM|ANALYZE|COPY|CALL|DO)\b", RegexOptions.IgnoreCase)]
    private static partial Regex WritingKeyword();

    /// <summary>Statements that would change data or schema: none but the observer's event session's own DDL.</summary>
    private sealed class WriteVisitor : TSqlFragmentVisitor
    {
        public List<string> Writes { get; } = [];

        public override void Visit(InsertStatement node) => Writes.Add("INSERT");

        public override void Visit(UpdateStatement node) => Writes.Add("UPDATE");

        public override void Visit(DeleteStatement node) => Writes.Add("DELETE");

        public override void Visit(MergeStatement node) => Writes.Add("MERGE");

        public override void Visit(TruncateTableStatement node) => Writes.Add("TRUNCATE");

        public override void Visit(KillStatement node) => Writes.Add("KILL");

        public override void Visit(CreateTableStatement node) => Writes.Add("CREATE TABLE");

        public override void Visit(AlterTableStatement node) => Writes.Add("ALTER TABLE");

        public override void Visit(DropTableStatement node) => Writes.Add("DROP TABLE");

        public override void Visit(ExecuteStatement node) => Writes.Add("EXECUTE");
    }
}
