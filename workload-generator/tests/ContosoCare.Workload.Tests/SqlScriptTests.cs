using System.Text.Json;
using System.Text.RegularExpressions;
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
        // ADR 0031, decision 6: the check names the calling module (@@PROCID), never a scenario, and
        // demo.fn_workload_procedures() says which scenario's runs may run it.
        var problems = new List<string>();
        var checkedModules = RunCheckedProcedures();
        foreach (var procedure in checkedModules)
        {
            if (!procedure.Text.Contains("EXEC demo.usp_run_assert_running @run_id = @run_id, @procid = @@PROCID, @deadline_at = @deadline OUTPUT", StringComparison.Ordinal))
            {
                problems.Add($"{procedure.Name} doesn't call demo.usp_run_assert_running with its own @@PROCID first.");
            }

            if (procedure.HasLoop && !procedure.Text.Contains("demo.fn_run_should_stop(@run_id)", StringComparison.Ordinal))
            {
                problems.Add($"{procedure.Name} loops without checking demo.fn_run_should_stop.");
            }
        }

        Assert.True(problems.Count == 0, string.Join(Environment.NewLine, problems));
        Assert.Equal(22, checkedModules.Count);
    }

    [Fact]
    public void EveryRunCheckedModuleIsMappedToTheScenariosThatRunIt()
    {
        // The T-SQL copy of the answer key's map: one row per module that checks its run, '*' only for the requests the
        // portal serves (the normal workload beside any scenario), and every row agrees with rca/blind-detection.json.
        var control = File.ReadAllText(RepositoryPaths.Combine("database", "common", "110-demo-control.sql")).Replace("\r\n", "\n", StringComparison.Ordinal);
        var function = control[control.IndexOf("CREATE OR ALTER FUNCTION demo.fn_workload_procedures ()", StringComparison.Ordinal)..];
        function = function[..function.IndexOf("\nGO", StringComparison.Ordinal)];
        var rows = Regex.Matches(function, @"\(N'(?<module>[a-z]+\.[a-z_]+)', '(?<scenario>[a-z*-]+)'\)").Select(m => (Module: m.Groups["module"].Value, Scenario: m.Groups["scenario"].Value)).ToList();
        var answerKey = WorkloadNames("tsql");

        Assert.Equal(RunCheckedProcedures().Select(p => p.Name).Order(StringComparer.Ordinal), rows.Select(r => r.Module).Order(StringComparer.Ordinal));
        Assert.Equal(["frontdesk.usp_process_requests"], rows.Where(r => r.Scenario == "*").Select(r => r.Module));
        Assert.All(rows.Where(r => r.Scenario != "*"), row => Assert.Contains(row.Scenario, answerKey[row.Module]));
        Assert.True(control.IndexOf("CREATE OR ALTER FUNCTION demo.fn_workload_procedures", StringComparison.Ordinal) < control.IndexOf("CREATE OR ALTER PROCEDURE demo.usp_run_assert_running", StringComparison.Ordinal));
    }

    [Fact]
    public void TheWorkloadModulesHaveRealisticNamesAndTheAnswerKeyMapsEveryOne()
    {
        // ADR 0031, decision 6: every module 120-scenario-procedures.sql creates lives in an application schema that the
        // script creates and lets the runner's role run, and the answer key maps it and forbids it in detection code.
        var text = Script("120-scenario-procedures.sql");
        var modules = Regex.Matches(text, @"(?m)^CREATE OR ALTER (?:PROCEDURE|FUNCTION) (?<schema>[a-z]+)\.(?<name>[a-z_]+)").Select(m => (Schema: m.Groups["schema"].Value, Name: m.Groups["name"].Value)).ToList();
        var forbidden = BlindDetection().RootElement.GetProperty("forbiddenInDetectionCode").GetProperty("identifiers").EnumerateArray().Select(e => e.GetString()!).ToHashSet(StringComparer.Ordinal);

        Assert.Equal(26, modules.Count);
        Assert.Equal(WorkloadNames("tsql").Keys.Order(StringComparer.Ordinal), modules.Select(m => m.Schema + "." + m.Name).Order(StringComparer.Ordinal));
        foreach (var schema in ApplicationSchemas)
        {
            Assert.Contains($"IF SCHEMA_ID(N'{schema}') IS NULL\n    EXEC (N'CREATE SCHEMA {schema} AUTHORIZATION dbo;');", text, StringComparison.Ordinal);
            Assert.Contains($"GRANT EXECUTE ON SCHEMA::{schema} TO contosocare_runner;", text, StringComparison.Ordinal);
        }

        Assert.All(modules, module =>
        {
            Assert.Contains(module.Schema, ApplicationSchemas);
            Assert.DoesNotContain("scenario", module.Name, StringComparison.Ordinal);
            Assert.Contains(module.Name, forbidden);
        });
    }

    [Fact]
    public void NoStoredModuleNamesAScenario()
    {
        // SQL Server stores a module's whole batch, comments before CREATE included, so each header comment is a batch of
        // its own and every module batch starts at its CREATE. What a DBA reads with sp_helptext names no scenario.
        var scenarioIds = Directory.GetDirectories(RepositoryPaths.Combine("scenarios")).Select(d => Path.GetFileName(d)!).Where(id => File.Exists(RepositoryPaths.Combine("scenarios", id, "scenario.json"))).ToList();
        var modules = Sql.SqlScripts.SplitBatches(Script("120-scenario-procedures.sql")).Where(b => Regex.IsMatch(b, @"(?m)^CREATE OR ALTER (PROCEDURE|FUNCTION) ")).ToList();

        Assert.Equal(26, modules.Count);
        Assert.All(modules, module =>
        {
            Assert.StartsWith("CREATE OR ALTER ", module, StringComparison.Ordinal);
            Assert.DoesNotContain("scenario", module, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(scenarioIds, id => Regex.IsMatch(module, $@"(?<![A-Za-z0-9_./-]){Regex.Escape(id)}(?![A-Za-z0-9_./-])"));
        });
    }

    [Fact]
    public void TheRetiredNamesAreDroppedOnceAfterEveryReplacementExists()
    {
        // The one-click upgrade (ADR 0031, decision 6): setup drops each earlier name, only those, after the last CREATE,
        // and first unforces any plan automatic tuning forced for the old lookup, so none stays forced for a dropped object.
        var text = Script("120-scenario-procedures.sql");
        var drops = Regex.Matches(text, @"(?m)^DROP (?<kind>PROCEDURE|FUNCTION) IF EXISTS (?<name>\S+);$").Select(m => m.Groups["kind"].Value + " " + m.Groups["name"].Value).ToList();

        Assert.Equal(RetiredTSqlNames.Order(StringComparer.Ordinal), drops.Order(StringComparer.Ordinal));
        Assert.True(text.LastIndexOf("CREATE OR ALTER ", StringComparison.Ordinal) < text.IndexOf("DROP PROCEDURE IF EXISTS", StringComparison.Ordinal), "every replacement exists before the first drop");

        // The unforce of the retired block itself, on Azure SQL Database only, in TRY, and before the first drop: the last
        // module (frontdesk.usp_refresh_visit_summaries) has an unforce of its own, which mustn't stand in for this one.
        var retiredStart = text.IndexOf("-- Retired names", StringComparison.Ordinal);
        Assert.True(retiredStart > text.LastIndexOf("CREATE OR ALTER ", StringComparison.Ordinal), "the retired names come after every module");
        var retiredBlock = text[retiredStart..text.IndexOf("DROP PROCEDURE IF EXISTS", StringComparison.Ordinal)];
        var unforce = retiredBlock.IndexOf("EXEC sys.sp_query_store_unforce_plan @query_id = @query_id, @plan_id = @plan_id;", StringComparison.Ordinal);
        Assert.True(unforce >= 0, "the old lookup's forced plans are unforced before it's dropped");
        Assert.Contains("IF CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 AND OBJECT_ID(N'demo.usp_visit_summary_lookup', N'P') IS NOT NULL", retiredBlock, StringComparison.Ordinal);
        Assert.Contains("WHERE q.object_id = OBJECT_ID(N'demo.usp_visit_summary_lookup', N'P') AND p.is_forced_plan = 1;", retiredBlock, StringComparison.Ordinal);
        Assert.True(retiredBlock.IndexOf("BEGIN TRY", StringComparison.Ordinal) is >= 0 and var tryStart && tryStart < unforce && unforce < retiredBlock.IndexOf("END TRY", StringComparison.Ordinal), "a failed unforce never stops setup");
        foreach (var (path, _, script) in DemoScripts.Value)
        {
            Assert.All(RetiredTSqlNames, retired => Assert.DoesNotContain("CREATE OR ALTER " + retired.Split(' ')[0] + " " + retired.Split(' ')[1], script, StringComparison.Ordinal));
            if (!path.EndsWith("120-scenario-procedures.sql", StringComparison.Ordinal))
            {
                Assert.DoesNotContain("DROP PROCEDURE", script, StringComparison.Ordinal);
            }
        }
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
        foreach (var procedure in WorkloadProcedures().Where(p => p.Name != "frontdesk.usp_process_requests"))
        {
            if (procedure.WritesCare && procedure.HasCommit)
            {
                problems.Add($"{procedure.Name} changes care.* tables and commits.");
            }
        }

        Assert.True(problems.Count == 0, string.Join(Environment.NewLine, problems));
        Assert.Equal(["billing.usp_import_remittances"], WorkloadProcedures().Where(p => p.HasCommit).Select(p => p.Name));
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
    public void OnlyTheDatabaseAgentBeatTouchesAutomaticTuningAndEveryWayBackPutsItBack()
    {
        // 2026-11-18 (ADR 0010): FORCE_LAST_GOOD_PLAN is the one database option a demo script changes. plan-regression's
        // worker 1 holds it off only after demo.auto_tuning_hold records how it was, and demo.usp_release_auto_tuning_hold
        // puts that back; the response, the run's end, auto-cleanup, a stale run's recovery, reset, and setup call it.
        var withAlter = Procedures().Where(p => p.Text.Contains("ALTER DATABASE", StringComparison.OrdinalIgnoreCase)).Select(p => p.Name).Order(StringComparer.Ordinal).ToList();
        Assert.Equal(["demo.usp_release_auto_tuning_hold", "frontdesk.usp_refresh_visit_summaries"], withAlter);

        var regression = ProcedureText("frontdesk.usp_refresh_visit_summaries");
        Assert.True(regression.IndexOf("INSERT INTO demo.auto_tuning_hold", StringComparison.Ordinal) < regression.IndexOf("FORCE_LAST_GOOD_PLAN = OFF", StringComparison.Ordinal), "the hold is recorded before the option goes off");
        Assert.Equal(1, CountOccurrences(regression, "ALTER DATABASE CURRENT SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = OFF)"));
        Assert.Equal(2, CountOccurrences(regression, "EXEC demo.usp_release_auto_tuning_hold @run_id = @run_id"));
        Assert.Contains("EXEC sys.sp_query_store_force_plan", regression, StringComparison.Ordinal);

        var release = ProcedureText("demo.usp_release_auto_tuning_hold");
        Assert.Contains("SERVERPROPERTY('EngineEdition') AS int) <> 5", release, StringComparison.Ordinal);
        foreach (var caller in new[] { "demo.usp_recover_stale_runs", "demo.usp_cleanup_scenario", "demo.usp_reset" })
        {
            Assert.Contains("EXEC demo.usp_release_auto_tuning_hold", ProcedureText(caller), StringComparison.Ordinal);
        }

        Assert.EndsWith("EXEC demo.usp_release_auto_tuning_hold @by = N'setup (deploy.ps1)';\nGO", File.ReadAllText(RepositoryPaths.Combine("database", "common", "110-demo-control.sql")).Replace("\r\n", "\n", StringComparison.Ordinal).TrimEnd(), StringComparison.Ordinal);
    }

    [Fact]
    public void SetupRaisesOnlyPlanRegressionsEarlierDefaultToItsCatalogLimit()
    {
        // 2026-11-18 (review): a T3 set up before the Database Agent beat keeps plan-regression at 1200 seconds, and
        // usp_run_begin clamps a run to it, so the beat's 30 minutes would end at 20. Setup raises exactly that earlier
        // default to the catalog's 1800 after its lowering pass; any other value an operator set stays.
        // SqlIntegrationTests.SetupRaisesPlanRegressionsEarlierDefaultAndKeepsALoweredLimit applies it to a database.
        var script = File.ReadAllText(RepositoryPaths.Combine("database", "common", "110-demo-control.sql")).Replace("\r\n", "\n", StringComparison.Ordinal);
        const string raise = "UPDATE demo.scenario_control\nSET max_duration_seconds = 1800, updated_at = SYSUTCDATETIME()\nWHERE scenario_id = 'plan-regression' AND max_duration_seconds = 1200;\nGO";
        Assert.Equal(1, CountOccurrences(script, raise));
        Assert.Contains("('plan-regression', 1800)", script, StringComparison.Ordinal);
        var lower = script.IndexOf("WHERE c.max_duration_seconds > s.max_duration_seconds;", StringComparison.Ordinal);
        var insert = script.IndexOf("INSERT INTO demo.scenario_control (scenario_id, stop_requested, max_duration_seconds, updated_at)\nSELECT", StringComparison.Ordinal);
        Assert.True(lower > 0 && lower < script.IndexOf(raise, StringComparison.Ordinal) && script.IndexOf(raise, StringComparison.Ordinal) < insert, "the raise runs after the lowering pass and before the insert of new rows");
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
    public void TheProfileSetIsACompareAndSetThatAllowsTheShowcase()
    {
        // The showcase's supersede guard (ADR 0020): a stamped set writes only when no newer request is stored, read and
        // written under one update lock; an unstamped set keeps the stamp.
        var sql = File.ReadAllText(RepositoryPaths.Combine("database", "common", "110-demo-control.sql"));
        var procedure = sql[sql.IndexOf("CREATE OR ALTER PROCEDURE demo.usp_profile_set", StringComparison.Ordinal)..];
        procedure = procedure[..procedure.IndexOf("\nGO", StringComparison.Ordinal)];

        Assert.Contains("'off', 'baseline', 'business-day', 'showcase'", procedure, StringComparison.Ordinal);
        Assert.Contains("WITH (UPDLOCK, HOLDLOCK)", procedure, StringComparison.Ordinal);
        Assert.Contains("IF @stored_at > @requested_at", procedure, StringComparison.Ordinal);
        Assert.Contains("@stored_id COLLATE Latin1_General_BIN2 > @request_id COLLATE Latin1_General_BIN2", procedure, StringComparison.Ordinal);
        Assert.Contains("requested_at = CASE WHEN @requested_at IS NULL THEN requested_at ELSE @requested_at END", procedure, StringComparison.Ordinal);
        Assert.Contains("THROW 50118", procedure, StringComparison.Ordinal);
        Assert.Contains("IF COL_LENGTH(N'demo.activity_profile', N'requested_at') IS NULL", sql, StringComparison.Ordinal);
        Assert.Contains("IF COL_LENGTH(N'demo.activity_profile', N'request_id') IS NULL", sql, StringComparison.Ordinal);
        var get = sql[sql.IndexOf("CREATE OR ALTER PROCEDURE demo.usp_profile_get", StringComparison.Ordinal)..];
        Assert.Matches(@"is_active = [^\n]+,\s+requested_at,\s+request_id\s", get[..get.IndexOf("\nGO", StringComparison.Ordinal)]);
    }

    [Fact]
    public void TheProfileCheckAllowsEveryProfileTheSetAccepts()
    {
        // The table's check must allow every name the procedure accepts, both in a new database (010-schema.sql) and in
        // one from before the showcase (110's migration): the live check of 2026-11-04 found the showcase refused with
        // error 547 on T1 and T2, where only the procedure had it. The profiles file holds what the control sends.
        static string[] Names(string list) => [.. Regex.Matches(list, "'([a-z-]+)'").Select(m => m.Groups[1].Value).Order(StringComparer.Ordinal)];

        var schema = File.ReadAllText(RepositoryPaths.Combine("database", "common", "010-schema.sql"));
        var control = File.ReadAllText(RepositoryPaths.Combine("database", "common", "110-demo-control.sql"));
        var created = Regex.Match(schema, @"CONSTRAINT ck_activity_profile_name CHECK \(profile_name IN \(([^)]*)\) OR profile_name LIKE 'incident:%'\)");
        var widened = Regex.Match(control, @"ADD CONSTRAINT ck_activity_profile_name\s+CHECK \(profile_name IN \(([^)]*)\) OR profile_name LIKE 'incident:%'\)");
        var accepted = Regex.Match(control, @"@profile_name NOT IN \(([^)]*)\)");
        Assert.True(created.Success, "010-schema.sql creates ck_activity_profile_name with a list of names.");
        Assert.True(widened.Success, "110-demo-control.sql widens ck_activity_profile_name with a list of names.");
        Assert.True(accepted.Success, "demo.usp_profile_set checks the name against a list.");

        var names = Names(accepted.Groups[1].Value);
        Assert.Contains("showcase", names);
        Assert.Equal(names, Names(created.Groups[1].Value));
        Assert.Equal(names, Names(widened.Groups[1].Value));

        // The migration replaces a check that lacks any of the names, so a second run changes nothing and a name added
        // later reaches a database that already ran it (the review of PR 29).
        var guard = Regex.Match(control, @"AND \(definition NOT LIKE N'%''[a-z-]+''%'(?:\s+OR definition NOT LIKE N'%''[a-z-]+''%')*\)");
        Assert.True(guard.Success, "The migration's guard checks the definition for each name.");
        Assert.Equal(names, Names(guard.Value));

        using var profiles = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("scenarios", "activity-profiles.json")));
        var sent = profiles.RootElement.GetProperty("profiles").EnumerateObject().Select(p => p.Name).Where(name => name != "incident").Append("off");
        Assert.All(sent, name => Assert.Contains(name, names));
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

    /// <summary>The application schemas that hold the workload's modules (ADR 0031, decision 6).</summary>
    private static readonly string[] ApplicationSchemas = ["billing", "frontdesk", "records", "reporting", "scheduling", "supply"];

    /// <summary>The modules' earlier names, which 120-scenario-procedures.sql drops once their replacements exist.</summary>
    private static readonly string[] RetiredTSqlNames =
    [
        "PROCEDURE demo.usp_scenario_healthy_baseline", "PROCEDURE demo.usp_scenario_locking_acquire", "PROCEDURE demo.usp_scenario_locking_hold",
        "PROCEDURE demo.usp_scenario_locking_contend", "PROCEDURE demo.usp_scenario_locking_deadlock", "PROCEDURE demo.usp_scenario_cpu_pressure",
        "PROCEDURE demo.usp_io_scratch_grow", "PROCEDURE demo.usp_scenario_io_pressure", "PROCEDURE demo.usp_scenario_missing_index",
        "PROCEDURE demo.usp_scenario_inefficient_query", "PROCEDURE demo.usp_scenario_resource_governance", "PROCEDURE demo.usp_scenario_log_rate_pressure",
        "PROCEDURE demo.usp_scenario_chain_acquire", "PROCEDURE demo.usp_scenario_chain_link", "PROCEDURE demo.usp_scenario_chain_escalate",
        "PROCEDURE demo.usp_scenario_deadlock_storm", "PROCEDURE demo.usp_scenario_tempdb_contention", "PROCEDURE demo.usp_scenario_memory_grants",
        "PROCEDURE demo.usp_scenario_parallel_scans", "PROCEDURE demo.usp_scenario_commit_flood", "PROCEDURE demo.usp_scenario_slow_consumer",
        "PROCEDURE demo.usp_scenario_capacity_max", "PROCEDURE demo.usp_visit_summary_lookup", "PROCEDURE demo.usp_scenario_plan_regression",
        "FUNCTION demo.fn_locking_hot_rows", "FUNCTION demo.fn_chain_rows",
    ];

    /// <summary>The procedures of 120-scenario-procedures.sql: the workload's modules.</summary>
    private static List<ProcedureInfo> WorkloadProcedures()
    {
        var (_, script, text) = DemoScripts.Value.Single(s => s.Path.EndsWith("120-scenario-procedures.sql", StringComparison.Ordinal));
        var visitor = new ProcedureVisitor(text);
        script.Accept(visitor);
        return visitor.Procedures;
    }

    /// <summary>The workload's modules that check their run: each takes @run_id and gets its own deadline (a helper takes its caller's, @deadline_at).</summary>
    private static List<ProcedureInfo> RunCheckedProcedures() =>
        [.. WorkloadProcedures().Where(p => p.Parameters.Contains("@run_id") && !p.Parameters.Contains("@deadline_at"))];

    private static string Script(string fileName) =>
        File.ReadAllText(RepositoryPaths.Combine("database", "common", fileName)).Replace("\r\n", "\n", StringComparison.Ordinal);

    private static JsonDocument BlindDetection() => JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "blind-detection.json")));

    /// <summary>rca/blind-detection.json's answerKey.workloadNames for one engine: each module and the scenarios it serves.</summary>
    internal static Dictionary<string, string[]> WorkloadNames(string engine)
    {
        using var blind = BlindDetection();
        return blind.RootElement.GetProperty("answerKey").GetProperty("workloadNames").GetProperty(engine).EnumerateObject()
            .ToDictionary(p => p.Name, p => p.Value.EnumerateArray().Select(s => s.GetString()!).ToArray(), StringComparer.Ordinal);
    }

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

        public override void Visit(AlterDatabaseStatement node)
        {
            // The one database option a demo script may change (2026-11-18, ADR 0010's Database Agent beat): ContosoCare's own
            // FORCE_LAST_GOOD_PLAN, on CURRENT, which plan-regression holds off and demo.usp_release_auto_tuning_hold puts back.
            if (IsForceLastGoodPlanOnCurrent(node))
            {
                return;
            }

            Findings.Add($"line {node.StartLine}: ALTER DATABASE");
        }

        internal static bool IsForceLastGoodPlanOnCurrent(AlterDatabaseStatement node) =>
            node is AlterDatabaseSetStatement { UseCurrent: true } set
            && set.Options.Count == 1
            && set.Options[0] is AutomaticTuningDatabaseOption tuning
            && tuning.Options.Count == 1
            && tuning.Options[0] is AutomaticTuningForceLastGoodPlanOption;

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
