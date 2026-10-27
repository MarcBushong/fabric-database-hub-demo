using System.Text.Json;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Runs;
using Json.Schema;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>The scenario files against their JSON schemas, against the embedded catalog, and against the T-SQL.</summary>
public sealed partial class CatalogTests
{
    private static readonly Lazy<JsonSchema> ScenarioSchema = new(() => JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("scenarios", "scenario.schema.json"))));
    private static readonly Lazy<JsonSchema> ProfilesSchema = new(() => JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("scenarios", "activity-profiles.schema.json"))));

    public static TheoryData<string> ScenarioIds()
    {
        var data = new TheoryData<string>();
        foreach (var folder in RepositoryPaths.ScenarioFolders())
        {
            data.Add(Path.GetFileName(folder));
        }

        return data;
    }

    [Fact]
    public void TheCatalogHasTheBriefsScenariosAndTheAzureSqlOnes()
    {
        var ids = ScenarioCatalog.Default.All.Select(s => s.Id).ToList();

        Assert.Equal(
            [
                "blocking-chain", "capacity-max", "connection-surge", "cpu-pressure", "deadlock-storm", "healthy-baseline", "idle-in-transaction", "inefficient-query", "io-pressure",
                "locking-blocking", "log-flush-waits", "log-rate-pressure", "memory-grant-pressure", "missing-index", "parallel-scans", "resource-governance", "slow-consumer", "tempdb-contention",
            ],
            ids);
    }

    [Theory]
    [MemberData(nameof(ScenarioIds))]
    public void ScenarioFileMatchesTheSchema(string id)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("scenarios", id, "scenario.json")));

        var result = ScenarioSchema.Value.Evaluate(document.RootElement, new EvaluationOptions { OutputFormat = OutputFormat.List });

        Assert.True(result.IsValid, Describe(result));
    }

    [Theory]
    [MemberData(nameof(ScenarioIds))]
    public void ScenarioFolderNameIsItsId(string id)
    {
        var scenario = ScenarioCatalog.Parse(File.ReadAllText(RepositoryPaths.Combine("scenarios", id, "scenario.json")));

        Assert.Equal(id, scenario.Id);
        Assert.Equal(scenario.Duration, ScenarioCatalog.Default.Get(id).Duration);
    }

    [Theory]
    [MemberData(nameof(ScenarioIds))]
    public void EveryIncidentRunsOnEveryTarget(string id)
    {
        // The Database Agent's target coverage is undocumented (ADR 0013), so every SQL Server scenario runs on T1, T2,
        // and T3. T4 (PostgreSQL, ADR 0019) runs exactly the scenarios it has step functions for.
        var scenario = ScenarioCatalog.Default.Get(id);
        var sqlTargets = scenario.Targets.Applicable.Where(t => t != "T4").Order(StringComparer.Ordinal).ToList();

        Assert.True(sqlTargets.Count == 0 || sqlTargets.SequenceEqual(["T1", "T2", "T3"]), $"{id} runs on some SQL Server targets but not all.");
        Assert.Equal(PostgresScenarioIds.Contains(id), scenario.AppliesTo(DemoTarget.T4));
    }

    /// <summary>The scenarios T4 runs: database/postgresql/120-scenario-functions.sql has their steps.</summary>
    internal static readonly HashSet<string> PostgresScenarioIds = new(["connection-surge", "cpu-pressure", "healthy-baseline", "idle-in-transaction", "io-pressure", "locking-blocking"], StringComparer.Ordinal);

    [Fact]
    public void TheSchemaRejectsABadScenario()
    {
        using var document = JsonDocument.Parse("""{ "id": "Bad Id", "title": "x", "duration": { "defaultSeconds": 5, "maxSeconds": 99999 } }""");

        Assert.False(ScenarioSchema.Value.Evaluate(document.RootElement).IsValid);
    }

    [Fact]
    public void ActivityProfilesMatchTheirSchema()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("scenarios", "activity-profiles.json")));

        var result = ProfilesSchema.Value.Evaluate(document.RootElement, new EvaluationOptions { OutputFormat = OutputFormat.List });

        Assert.True(result.IsValid, Describe(result));
    }

    [Fact]
    public void BusinessDayIncidentsFitTheirScenariosAndNeverOverlap()
    {
        var profile = ActivityProfilesDefinition.Default.Profiles["business-day"];

        foreach (var group in profile.Incidents.GroupBy(i => i.Target, StringComparer.Ordinal))
        {
            var ordered = group.OrderBy(i => i.StartMinute).ToList();
            for (var i = 0; i < ordered.Count; i++)
            {
                var slot = ordered[i];
                var scenario = ScenarioCatalog.Default.Get(slot.Scenario);
                Assert.True(slot.DurationMinutes * 60 <= scenario.Duration.MaxSeconds, slot.Scenario);
                Assert.True(slot.StartMinute + slot.DurationMinutes <= profile.CycleMinutes, slot.Scenario);
                Assert.True(scenario.AppliesTo(Enum.Parse<DemoTarget>(slot.Target)), slot.Scenario);
                Assert.True(scenario.Targets.Default.Contains(slot.Target, StringComparer.Ordinal), $"{slot.Scenario} isn't a default scenario for {slot.Target}.");
                if (i > 0)
                {
                    Assert.True(ordered[i - 1].StartMinute + ordered[i - 1].DurationMinutes <= slot.StartMinute, $"{group.Key} incidents overlap at minute {slot.StartMinute}.");
                }

                // Every incident's parameters resolve against its scenario.
                ScenarioCatalog.ResolveParameters(scenario, Enum.Parse<DemoTarget>(slot.Target), slot.Parameters);
            }
        }
    }

    [Fact]
    public void TheSqlCatalogMirrorsTheScenarioMaximums()
    {
        var sql = File.ReadAllText(RepositoryPaths.Combine("database", "common", "110-demo-control.sql"));
        var function = sql[sql.IndexOf("CREATE OR ALTER FUNCTION demo.fn_scenario_catalog", StringComparison.Ordinal)..];
        function = function[..function.IndexOf("\nGO", StringComparison.Ordinal)];
        var rows = CatalogRow().Matches(function).ToDictionary(m => m.Groups[1].Value, m => int.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture), StringComparer.Ordinal);

        var sqlScenarios = ScenarioCatalog.Default.All.Where(s => s.AppliesTo(DemoTarget.T1)).ToList();
        Assert.Equal(sqlScenarios.Select(s => s.Id).Order(StringComparer.Ordinal), rows.Keys.Order(StringComparer.Ordinal));
        foreach (var scenario in sqlScenarios)
        {
            Assert.Equal(scenario.Duration.MaxSeconds, rows[scenario.Id]);
        }
    }

    [Fact]
    public void ThePostgresCatalogMirrorsTheT4Maximums()
    {
        var sql = File.ReadAllText(RepositoryPaths.Combine("database", "postgresql", "110-demo-control.sql"));
        var function = sql[sql.IndexOf("CREATE OR REPLACE FUNCTION demo.fn_scenario_catalog", StringComparison.Ordinal)..];
        function = function[..function.IndexOf("$$;", StringComparison.Ordinal)];
        var rows = CatalogRow().Matches(function).ToDictionary(m => m.Groups[1].Value, m => int.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture), StringComparer.Ordinal);
        var t4Scenarios = ScenarioCatalog.Default.All.Where(s => s.AppliesTo(DemoTarget.T4)).ToList();

        Assert.Equal(t4Scenarios.Select(s => s.Id).Order(StringComparer.Ordinal), rows.Keys.Order(StringComparer.Ordinal));
        foreach (var scenario in t4Scenarios)
        {
            Assert.Equal(scenario.Duration.MaxSeconds, rows[scenario.Id]);
        }
    }

    [Fact]
    public void EveryT4ScenarioHasItsStepFunction()
    {
        var sql = File.ReadAllText(RepositoryPaths.Combine("database", "postgresql", "120-scenario-functions.sql"));

        foreach (var scenario in ScenarioCatalog.Default.All.Where(s => s.AppliesTo(DemoTarget.T4)))
        {
            Assert.Contains("CREATE OR REPLACE FUNCTION " + scenario.Procedure + "(", sql, StringComparison.Ordinal);
        }
    }

    [Theory]
    [MemberData(nameof(ScenarioIds))]
    public void ProceduresAndTheirParametersExist(string id)
    {
        var scenario = ScenarioCatalog.Default.Get(id);
        if (!scenario.AppliesTo(DemoTarget.T1))
        {
            // A T4-only scenario: its step lives in database/postgresql (EveryT4ScenarioHasItsStepFunction).
            return;
        }

        var procedures = SqlScriptTests.ProcedureParameters();

        Assert.True(procedures.ContainsKey(scenario.Procedure), $"{scenario.Procedure} isn't defined in database/common.");
        if (scenario.Orchestration == "workers")
        {
            Assert.Subset(procedures[scenario.Procedure], new HashSet<string>(["@run_id", "@worker", "@intensity"], StringComparer.OrdinalIgnoreCase));
        }

        foreach (var (name, parameter) in scenario.Parameters)
        {
            if (parameter.SqlParameter is { } sqlName)
            {
                Assert.True(procedures[scenario.Procedure].Contains(sqlName), $"{scenario.Procedure} has no {sqlName} for parameter {name}.");
            }
        }
    }

    [Fact]
    public void LockingParametersTheRunnerReadsExist()
    {
        var parameters = ScenarioCatalog.Default.Get("locking-blocking").Parameters;

        Assert.All(["hotRows", "holdSeconds", "pauseSeconds", "holder", "normalWorkers", "deadlock", "deadlockRounds"], name => Assert.True(parameters.ContainsKey(name), name));
    }

    [Theory]
    [InlineData("T1")]
    [InlineData("T2")]
    [InlineData("T3")]
    public void SetupChecksTheProcedureEachScenarioNames(string targetName)
    {
        // Phase 25d, live: setup checked demo.usp_scenario_<id> for every row of demo.fn_scenario_catalog(), so
        // blocking-chain, memory-grant-pressure, and log-flush-waits, whose entry procedures have other names, failed
        // setup on T1, T2, and T3. It now checks the procedure each scenario that runs on the target names.
        var target = Enum.Parse<DemoTarget>(targetName);
        var expected = ContosoCare.Workload.Sql.SqlScripts.ExpectedProcedures(ScenarioCatalog.Default, target);
        var defined = SqlScriptTests.ProcedureParameters();

        Assert.Equal(ScenarioCatalog.Default.All.Where(s => s.AppliesTo(target)).Select(s => s.Procedure).Distinct(StringComparer.OrdinalIgnoreCase).Count(), expected.Count);
        Assert.All(expected, procedure => Assert.True(defined.ContainsKey(procedure), $"setup would report {procedure} missing on {target}: it isn't defined in database/common."));
        Assert.Contains("demo.usp_scenario_chain_link", expected);
        Assert.Contains("demo.usp_scenario_memory_grants", expected);
        Assert.Contains("demo.usp_scenario_commit_flood", expected);
        Assert.DoesNotContain("demo.usp_scenario_blocking_chain", expected);
        Assert.DoesNotContain(ScenarioCatalog.Default.Get("connection-surge").Procedure, expected);
    }

    [Theory]
    [InlineData("blocking-chain", "chain", new[] { "depth", "holdSeconds", "pauseSeconds", "escalation", "escalationRows", "escalationHoldSeconds", "escalationEverySeconds", "normalWorkers" })]
    [InlineData("deadlock-storm", "pairs", new[] { "shape", "maxRounds" })]
    [InlineData("slow-consumer", "slow-consumer", new[] { "rowsPerQuery" })]
    [InlineData("capacity-max", "capacity", new[] { "ioWorkers", "scratchMb" })]
    public void OrchestratedScenariosHaveTheParametersTheRunnerReads(string id, string orchestration, string[] names)
    {
        var scenario = ScenarioCatalog.Default.Get(id);

        Assert.Equal(orchestration, scenario.Orchestration);
        Assert.All(names, name => Assert.True(scenario.Parameters.ContainsKey(name), name));
    }

    [Theory]
    [InlineData("demo.usp_scenario_chain_acquire", new[] { "@run_id" })]
    [InlineData("demo.usp_scenario_chain_link", new[] { "@run_id", "@level", "@branch" })]
    [InlineData("demo.usp_scenario_chain_escalate", new[] { "@run_id", "@rows", "@hold_seconds", "@every_seconds" })]
    [InlineData("demo.usp_scenario_deadlock_storm", new[] { "@run_id", "@pair", "@side", "@intensity" })]
    [InlineData("demo.usp_scenario_capacity_max", new[] { "@run_id", "@worker", "@intensity", "@role" })]
    [InlineData("demo.usp_scenario_slow_consumer", new[] { "@run_id", "@worker", "@rows" })]
    public void TheProceduresTheRunnerCallsByNameTakeItsParameters(string procedure, string[] parameters)
    {
        var procedures = SqlScriptTests.ProcedureParameters();

        Assert.True(procedures.ContainsKey(procedure), $"{procedure} isn't defined in database/common.");
        Assert.Subset(procedures[procedure], new HashSet<string>(parameters, StringComparer.OrdinalIgnoreCase));
    }

    [Theory]
    [InlineData("blocking-chain", "escalationRows", "demo.usp_scenario_chain_escalate", "@rows")]
    [InlineData("blocking-chain", "escalationHoldSeconds", "demo.usp_scenario_chain_escalate", "@hold_seconds")]
    [InlineData("blocking-chain", "escalationEverySeconds", "demo.usp_scenario_chain_escalate", "@every_seconds")]
    [InlineData("deadlock-storm", "maxRounds", "demo.usp_scenario_deadlock_storm", "@max_rounds")]
    [InlineData("tempdb-contention", "rowsPerTable", "demo.usp_scenario_tempdb_contention", "@rows_per_table")]
    [InlineData("memory-grant-pressure", "grantPercent", "demo.usp_scenario_memory_grants", "@grant_percent")]
    [InlineData("parallel-scans", "maxdop", "demo.usp_scenario_parallel_scans", "@maxdop")]
    [InlineData("log-flush-waits", "maxRows", "demo.usp_scenario_commit_flood", "@max_rows")]
    [InlineData("slow-consumer", "rowsPerQuery", "demo.usp_scenario_slow_consumer", "@rows")]
    [InlineData("capacity-max", "scratchMb", "demo.usp_scenario_capacity_max", "@scratch_mb")]
    public void TheTSqlRangeMatchesTheScenarioRange(string id, string parameter, string procedure, string sqlParameter)
    {
        // The T-SQL refuses what the catalog refuses, so a run that bypasses the runner keeps the same bounds (ADR 0010).
        var definition = ScenarioCatalog.Default.Get(id).Parameters[parameter];
        var text = SqlScriptTests.ProcedureText(procedure);
        var check = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{sqlParameter} IS NULL OR {sqlParameter} NOT BETWEEN {definition.Minimum} AND {definition.Maximum}");

        Assert.Contains(check, text, StringComparison.Ordinal);
    }

    [Fact]
    public void TheChainNeverOpensMoreThan26Sessions()
    {
        var chain = ScenarioCatalog.Default.Get("blocking-chain");
        var sessions = 1 + ((chain.Parameters["depth"].Maximum!.Value - 1) * chain.Concurrency.Max) + 1 + chain.Parameters["normalWorkers"].Maximum!.Value;

        Assert.Equal(26, sessions);
        Assert.Equal(ChainTopology.MaximumDepth, chain.Parameters["depth"].Maximum);
        Assert.Equal(ChainTopology.MaximumBranches, chain.Concurrency.Max);
    }

    [Fact]
    public void TheEscalationIsLargeEnoughToEscalate()
    {
        // SQL Server documents escalation past 5,000 locks on one table in one statement; it was measured from about
        // 6,200 rows on SQL Server 2025, so the catalog's minimum leaves a margin.
        Assert.True(ScenarioCatalog.Default.Get("blocking-chain").Parameters["escalationRows"].Minimum >= 7000);
    }

    [Theory]
    [MemberData(nameof(ScenarioIds))]
    public void EveryScenarioHasAReadmeThatLinksItsDefinition(string id)
    {
        var readme = File.ReadAllText(RepositoryPaths.Combine("scenarios", id, "README.md"));

        Assert.Contains("scenario.json", readme, StringComparison.Ordinal);
    }

    [Fact]
    public void FreeSpaceParametersExist()
    {
        foreach (var scenario in ScenarioCatalog.Default.All.Where(s => s.FreeSpace?.DataMbFromParameter is not null))
        {
            Assert.True(scenario.Parameters.ContainsKey(scenario.FreeSpace!.DataMbFromParameter!), scenario.Id);
        }
    }

    private static string Describe(EvaluationResults result)
    {
        var errors = new List<string>();
        Collect(result, errors);
        return string.Join(Environment.NewLine, errors);
    }

    private static void Collect(EvaluationResults result, List<string> errors)
    {
        if (result.Errors is { Count: > 0 })
        {
            errors.AddRange(result.Errors.Select(e => $"{result.InstanceLocation}: {e.Key}: {e.Value}"));
        }

        foreach (var detail in result.Details ?? [])
        {
            Collect(detail, errors);
        }
    }

    [GeneratedRegex(@"\('([a-z-]+)',\s*(\d+)\)")]
    private static partial Regex CatalogRow();
}
