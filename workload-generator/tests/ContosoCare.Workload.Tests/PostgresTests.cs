using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Npgsql;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// T4 (Phase 24, ADR 0019): the PostgreSQL scripts against the demo's safety rules (ADR 0010), the endpoint and
/// connection settings (no secret in a connection string, TLS verified, application names PostgreSQL won't cut),
/// and the runner's bounds. The end-to-end tests need a disposable PostgreSQL server and are opt-in.
/// </summary>
public sealed partial class PostgresTests
{
    private static readonly string[] ScriptNames = ["010-schema.sql", "020-seed.sql", "110-demo-control.sql", "120-scenario-functions.sql"];

    public static TheoryData<string> Scripts()
    {
        var data = new TheoryData<string>();
        foreach (var name in ScriptNames)
        {
            data.Add(name);
        }

        return data;
    }

    [Fact]
    public void TheScriptsInTheFolderAreTheOnesTheRunnerEmbeds()
    {
        var files = Directory.GetFiles(RepositoryPaths.Combine("database", "postgresql"), "*.sql").Select(Path.GetFileName).Order(StringComparer.Ordinal);

        Assert.Equal(ScriptNames, files);
        Assert.Equal(ScriptNames, PgScripts.BaseSchema.Concat(PgScripts.DemoObjects));
        foreach (var name in ScriptNames)
        {
            Assert.Equal(File.ReadAllText(RepositoryPaths.Combine("database", "postgresql", name)).ReplaceLineEndings(), PgScripts.Read(name).ReplaceLineEndings());
        }
    }

    [Theory]
    [MemberData(nameof(Scripts))]
    public void EveryBatchIsOneStatementOrOneFunction(string name)
    {
        var batches = PgScripts.SplitBatches(PgScripts.Read(name));

        Assert.NotEmpty(batches);
        foreach (var batch in batches)
        {
            Assert.DoesNotContain(batch.Split('\n'), line => line.Trim() == "-- @batch");
            var dollarQuotes = Regex.Count(batch, @"\$\$");
            Assert.True(dollarQuotes % 2 == 0, $"{name}: a batch has an unclosed $$ body.");
            if (dollarQuotes == 0)
            {
                // Outside function bodies, a batch holds one statement: a semicolon only at its end.
                var body = string.Join('\n', batch.Split('\n').Where(line => !line.TrimStart().StartsWith("--", StringComparison.Ordinal)));
                Assert.True(body.TrimEnd().EndsWith(';') && body.TrimEnd()[..^1].IndexOf(';', StringComparison.Ordinal) < 0, $"{name}: a batch holds more than one statement: {body[..Math.Min(80, body.Length)]}");
            }
        }
    }

    [Theory]
    [MemberData(nameof(Scripts))]
    public void ScriptsStayInsideTheContosoCareDatabase(string name)
    {
        var text = PgScripts.Read(name);

        foreach (var forbidden in new[] { "CREATE DATABASE", "DROP DATABASE", "ALTER SYSTEM", "ALTER DATABASE", "CREATE ROLE", "DROP ROLE", "ALTER ROLE", "dblink", "COPY ", "\\c ", "pg_read_server_files", "lo_import" })
        {
            Assert.DoesNotContain(forbidden, text, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Theory]
    [InlineData(1, 0, "care.claims WHERE payer_code = @payer AND submitted_on >= @since", "payer", "FABRIKAM-PPO")]
    [InlineData(2, 4, "care.claims WHERE payer_code = @payer AND submitted_on >= @since", "payer", "TAILSPIN-INS")]
    [InlineData(1, 1, "care.appointments WHERE reason_code = @reason AND facility_id = @facility", "reason", "R008")]
    [InlineData(3, 7, "care.appointments WHERE reason_code = @reason AND facility_id = @facility", "reason", "R002")]
    public void T4sMissingIndexLookupsAreTopLevelParameterizedStatements(int worker, int turn, string predicate, string name, string value)
    {
        // 2026-11-04: Query Store (top) captures only top-level statements, and autonomous tuning recommends indexes for
        // the queries it captured, so the lookups are the runner's own parameterized statements on unindexed columns.
        var now = new DateTimeOffset(2026, 11, 4, 15, 0, 0, TimeSpan.Zero);
        var (sql, parameters) = PgScenarioRunner.MissingIndexLookup(worker, turn, now);

        Assert.StartsWith("SELECT count(*)::bigint AS rows_found FROM ", sql, StringComparison.Ordinal);
        Assert.Contains(predicate, sql, StringComparison.Ordinal);
        Assert.DoesNotContain("demo.", sql, StringComparison.Ordinal);
        Assert.Equal(value, parameters.Single(p => p.Name == name).Value);
        if (name == "payer")
        {
            Assert.Equal(new DateOnly(2026, 10, 5), parameters.Single(p => p.Name == "since").Value);
        }
        else
        {
            Assert.InRange((int)parameters.Single(p => p.Name == "facility").Value, 1, 20);
        }

        var schema = PgScripts.Read("010-schema.sql");
        Assert.DoesNotMatch(@"CREATE INDEX[^;]*\((payer_code|reason_code)", schema);
    }

    [Fact]
    public void EveryScenarioStepAssertsItsRunFirst()
    {
        var text = PgScripts.Read("120-scenario-functions.sql");
        var functions = FunctionPattern().Matches(text);

        Assert.True(functions.Count >= 12);
        foreach (Match function in functions)
        {
            var name = function.Groups["name"].Value;
            if (!name.StartsWith("usp_", StringComparison.Ordinal))
            {
                continue;
            }

            var body = function.Groups["body"].Value;
            Assert.True(body.Contains("demo.usp_run_assert_running(p_run_id)", StringComparison.Ordinal), $"{function.Groups["schema"].Value}.{name} doesn't check its run first.");
        }
    }

    [Fact]
    public void TheStepsHaveRealisticNamesAndTheAnswerKeyMapsEveryOne()
    {
        // ADR 0031, decision 6: every step lives in an application schema that the script creates and setup grants the
        // runner's role (PgScripts.ApplicationSchemas), and the answer key maps it and forbids it in detection code. demo
        // keeps only the seeding helper.
        var text = PgScripts.Read("120-scenario-functions.sql");
        var functions = FunctionPattern().Matches(text).Select(m => (Schema: m.Groups["schema"].Value, Name: m.Groups["name"].Value)).ToList();
        using var blind = System.Text.Json.JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "blind-detection.json")));
        var forbidden = blind.RootElement.GetProperty("forbiddenInDetectionCode").GetProperty("identifiers").EnumerateArray().Select(e => e.GetString()!).ToHashSet(StringComparer.Ordinal);
        var steps = functions.Where(f => f is not { Schema: "demo", Name: "fn_seed_scale" }).ToList();

        Assert.Equal(16, functions.Count);
        Assert.Equal(SqlScriptTests.WorkloadNames("postgresql").Keys.Order(StringComparer.Ordinal), steps.Select(f => f.Schema + "." + f.Name).Order(StringComparer.Ordinal));
        Assert.All(steps, step =>
        {
            Assert.Contains(step.Schema, PgScripts.ApplicationSchemas);
            Assert.DoesNotContain("scenario", step.Name, StringComparison.Ordinal);
            Assert.Contains(step.Name, forbidden);
        });
        Assert.Equal(PgScripts.ApplicationSchemas, Regex.Matches(text, @"(?m)^CREATE SCHEMA IF NOT EXISTS (?<schema>[a-z]+);$").Select(m => m.Groups["schema"].Value));
        Assert.True(text.IndexOf("CREATE SCHEMA IF NOT EXISTS", StringComparison.Ordinal) < text.IndexOf("CREATE OR REPLACE FUNCTION", StringComparison.Ordinal), "the schemas exist before the first function");
    }

    [Fact]
    public void NoStepBodyNamesAScenario()
    {
        // PostgreSQL stores a function's body, never the comments before it; what a DBA reads there names no scenario.
        var scenarioIds = Directory.GetDirectories(RepositoryPaths.Combine("scenarios")).Select(d => Path.GetFileName(d)!).Where(id => File.Exists(RepositoryPaths.Combine("scenarios", id, "scenario.json"))).ToList();

        foreach (Match function in FunctionPattern().Matches(PgScripts.Read("120-scenario-functions.sql")))
        {
            var body = function.Groups["body"].Value;
            Assert.DoesNotContain("scenario", body, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(scenarioIds, id => Regex.IsMatch(body, $@"(?<![A-Za-z0-9_./-]){Regex.Escape(id)}(?![A-Za-z0-9_./-])"));
        }
    }

    [Fact]
    public void TheRetiredStepsAreDroppedInDemoOnceEveryReplacementExists()
    {
        // The one-click upgrade (ADR 0031, decision 6): setup drops every function of demo that has one of the steps'
        // earlier names, whatever its argument list, after the last CREATE, and nothing else.
        var text = PgScripts.Read("120-scenario-functions.sql");
        var retire = text[text.LastIndexOf("DO $$", StringComparison.Ordinal)..];
        var names = Regex.Match(retire, @"AND p\.proname IN \((?<names>[^)]*)\)").Groups["names"].Value.Split(", ").Select(n => n.Trim('\'')).ToList();

        Assert.Equal(
            ["fn_idle_rows", "fn_locking_hot_rows", "usp_scenario_connection_surge", "usp_scenario_cpu_pressure", "usp_scenario_healthy_baseline", "usp_scenario_idle_in_transaction", "usp_scenario_idle_writer", "usp_scenario_io_pressure", "usp_scenario_io_pressure_grow", "usp_scenario_locking_acquire", "usp_scenario_locking_contend", "usp_scenario_locking_deadlock", "usp_scenario_locking_hold", "usp_scenario_missing_index", "usp_scenario_replica_lag"],
            names.Order(StringComparer.Ordinal));
        Assert.Contains("WHERE n.nspname = 'demo'", retire, StringComparison.Ordinal);
        Assert.Contains("EXECUTE format('DROP FUNCTION IF EXISTS %s', v_function);", retire, StringComparison.Ordinal);
        Assert.True(text.LastIndexOf("CREATE OR REPLACE FUNCTION", StringComparison.Ordinal) < text.LastIndexOf("DO $$", StringComparison.Ordinal));
        Assert.All(names, name => Assert.DoesNotContain("FUNCTION demo." + name + "(", text, StringComparison.Ordinal));
        Assert.Single(Regex.Matches(text, "DROP FUNCTION").Cast<Match>());
    }

    [Fact]
    public void EveryLoopIsBoundedByTimeOrAQuery()
    {
        foreach (var name in ScriptNames)
        {
            var text = PgScripts.Read(name);
            foreach (Match loop in Regex.Matches(text, @"(?m)^\s*WHILE (?<condition>[^\n]+) LOOP"))
            {
                Assert.Contains("clock_timestamp() < ", loop.Groups["condition"].Value, StringComparison.Ordinal);
            }

            // Every other loop iterates over a query's rows (FOR ... IN ... LOOP), which ends with the rows.
            var bareLoops = Regex.Count(text, @"(?m)^\s*LOOP\s*$");
            Assert.True(bareLoops <= Regex.Count(text, @"(?m)^\s*FOR \w+ IN\s*$"), $"{name} has a LOOP that isn't a FOR over a query or a time-bounded WHILE.");
        }
    }

    [Fact]
    public void SessionToolsTouchOnlyDemoSessionsInThisDatabase()
    {
        var text = PgScripts.Read("110-demo-control.sql");
        var sessions = text[text.IndexOf("CREATE OR REPLACE FUNCTION demo.fn_demo_sessions", StringComparison.Ordinal)..];
        sessions = sessions[..sessions.IndexOf("$$;", StringComparison.Ordinal)];

        Assert.Contains("a.datname = current_database()", sessions, StringComparison.Ordinal);
        Assert.Contains("a.application_name LIKE 'ContosoCare.Demo/%'", sessions, StringComparison.Ordinal);
        Assert.Contains("a.application_name NOT LIKE 'ContosoCare.Demo/control/%'", sessions, StringComparison.Ordinal);
        Assert.Contains("a.pid <> pg_backend_pid()", sessions, StringComparison.Ordinal);
        Assert.Contains("pg_stat_clear_snapshot()", sessions, StringComparison.Ordinal);

        // pg_terminate_backend appears once, in the kill function, which reads only fn_demo_sessions.
        Assert.Single(Regex.Matches(text, "pg_terminate_backend\\(").Cast<Match>());
        var kill = text[text.IndexOf("CREATE OR REPLACE FUNCTION demo.usp_kill_demo_sessions", StringComparison.Ordinal)..];
        kill = kill[..kill.IndexOf("$$;", StringComparison.Ordinal)];
        Assert.Contains("FROM demo.fn_demo_sessions(p_run_id)", kill, StringComparison.Ordinal);
        foreach (var name in ScriptNames.Where(n => n != "110-demo-control.sql"))
        {
            Assert.DoesNotContain("pg_terminate_backend", PgScripts.Read(name), StringComparison.Ordinal);
        }
    }

    [Fact]
    public void ScenarioChangesRollBackOrAreTagged()
    {
        var text = PgScripts.Read("120-scenario-functions.sql");

        // The steps never commit; the only rows they leave behind carry the run ID, which reset removes.
        Assert.DoesNotContain("COMMIT", text, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("touched_by_run = p_run_id", text, StringComparison.Ordinal);
        Assert.Contains("VALUES (clock_timestamp(), 'ContosoCare.Demo', 'patient', v_patient, 'view', p_run_id)", text, StringComparison.Ordinal);
        Assert.Contains("pg_database_size(current_database())", text, StringComparison.Ordinal);
    }

    [Fact]
    public void EveryT4ApplicationNameFitsInSixtyThreeCharacters()
    {
        var runId = SessionNames.NewRunId();

        foreach (var scenario in ScenarioCatalog.Default.All.Where(s => s.AppliesTo(DemoTarget.T4)))
        {
            Assert.True(SessionNames.ForRun(scenario.Service, runId).Length <= PgConnectionOpener.MaximumApplicationNameLength, scenario.Id);
        }

        Assert.True(SessionNames.ForControl(runId).Length <= PgConnectionOpener.MaximumApplicationNameLength);
        Assert.Throws<ArgumentException>(() => PgConnectionOpener.Build(Endpoint(), new string('x', 64), 30));
    }

    [Fact]
    public void TheConnectionStringHoldsNoSecretAndVerifiesTls()
    {
        var builder = PgConnectionOpener.Build(Endpoint(), "ContosoCare.Demo/control/test", 30);

        Assert.Null(builder.Password);
        Assert.Equal(SslMode.VerifyFull, builder.SslMode);
        Assert.False(builder.Pooling);
        Assert.Equal("contosocare", builder.Database);
        Assert.Equal("contosocare_runner", builder.Username);
        Assert.DoesNotContain("password", builder.ConnectionString, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("pgflex01-abc123", "pgflex01-abc123.postgres.database.azure.com", 5432)]
    [InlineData("PGFLEX01-ABC123.postgres.database.azure.com", "pgflex01-abc123.postgres.database.azure.com", 5432)]
    [InlineData("pgflex01-abc123.postgres.database.azure.com:6432", "pgflex01-abc123.postgres.database.azure.com", 6432)]
    public void TheEndpointCompletesTheServerName(string server, string host, int port)
    {
        var endpoint = PgEndpoint.Create(server, null, passwordFromEnvironment: false, managedIdentityClientId: null);

        Assert.Equal(host, endpoint.Host);
        Assert.Equal(port, endpoint.Port);
        Assert.Equal(PgEndpoint.RunnerRole, endpoint.User);
        Assert.Equal(PgAuthMode.ManagedIdentity, endpoint.Auth);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("bad host!")]
    [InlineData("-leading.example.com")]
    public void TheEndpointRefusesABadServer(string? server) =>
        Assert.Throws<ScenarioRequestException>(() => PgEndpoint.Create(server, null, false, null));

    [Theory]
    [InlineData("T3 SQL administrators (P6)", true)]
    [InlineData("contosocare_runner", true)]
    [InlineData("x\"; DROP TABLE care.claims; --", false)]
    [InlineData(" leading", false)]
    public void RoleNamesAreValidatedBeforeTheyAreQuoted(string role, bool valid)
    {
        Assert.Equal(valid, PgEndpoint.IsRoleName(role));
        Assert.Equal("\"a\"\"b\"", PgScripts.QuoteIdentifier("a\"b"));
    }

    [Fact]
    public void TheManagedIdentityClientIdMustBeAGuid() =>
        Assert.Throws<ScenarioRequestException>(() => PgEndpoint.Create("pgflex01-abc123", null, false, "not-a-guid"));

    [Fact]
    public void SessionLimitsEndBeforeTheHardDeadline()
    {
        Assert.Equal(30_000, PgSessionLimits.ForRun(TimeSpan.FromSeconds(5)).StatementTimeoutMs);
        Assert.Equal(600_000, PgSessionLimits.ForRun(TimeSpan.FromMinutes(10)).IdleInTransactionTimeoutMs);
        Assert.True(PgSessionLimits.ForRun(TimeSpan.FromDays(2)).LockTimeoutMs <= (RunLimits.GlobalMaximumSeconds * 1000L) + 120_000);
    }

    [Theory]
    [InlineData(1, 2000)]
    [InlineData(10, 100)]
    [InlineData(99, 100)]
    public void PausesFollowIntensity(int intensity, int milliseconds) =>
        Assert.Equal(TimeSpan.FromMilliseconds(milliseconds), PgScenarioRunner.Pause(intensity, 2000, 100)(1));

    [Fact]
    public void StepCountersAreSummedAndMaximaKept()
    {
        var totals = new SortedDictionary<string, object?>(StringComparer.Ordinal);

        PgScenarioRunner.Accumulate(totals, new Dictionary<string, object?> { ["rows_read"] = 10L, ["elapsed_ms"] = 30, ["run_id"] = "x" });
        PgScenarioRunner.Accumulate(totals, new Dictionary<string, object?> { ["rows_read"] = 5L, ["elapsed_ms"] = 20 });

        Assert.Equal(15m, totals["rows_read"]);
        Assert.Equal(30m, totals["elapsed_ms"]);
        Assert.False(totals.ContainsKey("run_id"));
    }

    [Fact]
    public void TheT4ProfileFileIsSeparateFromT3s()
    {
        Assert.EndsWith("activity-t4.json", FileProfileStore.DefaultPathFor(DemoTarget.T4), StringComparison.Ordinal);
        Assert.Equal(FileProfileStore.DefaultPath, FileProfileStore.DefaultPathFor(DemoTarget.T3));
    }

    [Fact]
    public void TheSqlEndpointRefusesT4() =>
        Assert.Throws<ScenarioRequestException>(() => TargetEndpoint.Create(DemoTarget.T4, "pgflex01-abc123", false, null));

    [Fact]
    public void T4ScenariosPlanWithinTheirBounds()
    {
        var surge = ScenarioCatalog.Default.Get("connection-surge");
        var plan = RunBounds.Plan(surge, new RunRequest { ScenarioId = surge.Id, Target = DemoTarget.T4, Duration = TimeSpan.FromHours(2) }, DateTimeOffset.UtcNow);

        Assert.Equal(900, plan.DurationSeconds);
        Assert.Throws<ScenarioRequestException>(() => RunBounds.Plan(surge, new RunRequest { ScenarioId = surge.Id, Target = DemoTarget.T1 }, DateTimeOffset.UtcNow));
        // A SQL Server scenario T4 has no step for (missing-index runs on T4 since 2026-11-04).
        var blockingChain = ScenarioCatalog.Default.Get("blocking-chain");
        Assert.Throws<ScenarioRequestException>(() => RunBounds.Plan(blockingChain, new RunRequest { ScenarioId = blockingChain.Id, Target = DemoTarget.T4 }, DateTimeOffset.UtcNow));
        Assert.Equal(1024, ScenarioCatalog.ResolveParameters(ScenarioCatalog.Default.Get("io-pressure"), DemoTarget.T4, new Dictionary<string, string>())["scratchMb"].Integer);
    }

    // Opt-in end-to-end tests ------------------------------------------------------------------------------------------

    private const string ServerVariable = "CONTOSOCARE_TEST_PG_SERVER";

    /// <summary>
    /// Against a disposable PostgreSQL server: set CONTOSOCARE_TEST_PG_SERVER (for example localhost:5432, a container
    /// from config/versions.json workloadRunner.localTestPostgresImage with a contosocare database) and
    /// CONTOSOCARE_PG_USER and CONTOSOCARE_PG_PASSWORD. Setup, a short baseline run, a stop, and a reset. CI doesn't set them.
    /// </summary>
    [Fact]
    public async Task SetupRunAndResetAgainstALocalServer()
    {
        var server = Environment.GetEnvironmentVariable(ServerVariable);
        Assert.SkipUnless(server is not null, $"Set {ServerVariable}, {PgEndpoint.UserVariable}, and {PgEndpoint.PasswordVariable} to a disposable PostgreSQL server to run this test.");
        var token = TestContext.Current.CancellationToken;
        var endpoint = PgEndpoint.Create(server, null, passwordFromEnvironment: true, managedIdentityClientId: null);
        var opener = new PgConnectionOpener(endpoint, RunnerLog.Null);

        await using (var setup = await opener.OpenAsync(SessionNames.ForControl("test-setup"), token, PgSessionLimits.Setup))
        {
            foreach (var script in PgScripts.BaseSchema.Concat(PgScripts.DemoObjects))
            {
                await PgScripts.ApplyAsync(setup, script, RunnerLog.Null, token);
            }

            Assert.Equal("Pass", (await PgScripts.SeedAsync(setup, 1, force: false, token)).Status);
            Assert.Equal("Pass", (await PgScripts.VerifyScenarioFunctionsAsync(setup, ScenarioCatalog.Default.All, token)).Status);
        }

        var runner = new PgScenarioRunner(opener, RunnerLog.Null, TimeProvider.System);
        var baseline = ScenarioCatalog.Default.Get("healthy-baseline");
        var result = await runner.RunAsync(RunBounds.Plan(baseline, new RunRequest { ScenarioId = baseline.Id, Target = DemoTarget.T4, Duration = TimeSpan.FromSeconds(30), Concurrency = 1, Intensity = 10 }, DateTimeOffset.UtcNow), token);
        Assert.Equal("Completed", result.Status);
        Assert.Contains(result.Checks, c => c.CheckId == "run-sessions-closed" && c.Status == "Pass");

        var reset = await runner.ResetAsync(new ResetOptions("test", 5, KillSessions: true, KeepProfile: true, UndoRemediation: false, Reseed: false), token);
        Assert.Contains(reset, c => c.CheckId == "no-open-demo-transactions" && c.Status == "Pass");
        Assert.Contains(reset, c => c.CheckId == "workload-rows-removed" && c.Status == "Pass");
    }

    /// <summary>
    /// The runner's check before a run (ADR 0031, decision 6) wants a step it can call, not one that only exists: setup
    /// creates the steps in their new schemas before it grants the runner's role USAGE on them, so a run in between is
    /// refused and tried again, never registered and failed at its first step. Against the same disposable server, whose
    /// user may create a role (a superuser, as in the local container).
    /// </summary>
    [Fact]
    public async Task TheRunnersCheckWantsAStepItCanCall()
    {
        var server = Environment.GetEnvironmentVariable(ServerVariable);
        Assert.SkipUnless(server is not null, $"Set {ServerVariable}, {PgEndpoint.UserVariable}, and {PgEndpoint.PasswordVariable} to a disposable PostgreSQL server to run this test.");
        var token = TestContext.Current.CancellationToken;
        var endpoint = PgEndpoint.Create(server, null, passwordFromEnvironment: true, managedIdentityClientId: null);
        await using var connection = await new PgConnectionOpener(endpoint, RunnerLog.Null).OpenAsync(SessionNames.ForControl("test-callable"), token, PgSessionLimits.Setup);

        async Task ExecuteAsync(string sql)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await command.ExecuteNonQueryAsync(token);
        }

        await ExecuteAsync("DROP SCHEMA IF EXISTS zz_callable_probe CASCADE; CREATE SCHEMA zz_callable_probe; CREATE FUNCTION zz_callable_probe.usp_probe() RETURNS integer LANGUAGE sql AS 'SELECT 1'; DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'zz_callable_probe_role') THEN CREATE ROLE zz_callable_probe_role NOLOGIN; END IF; END $$;");
        try
        {
            await ExecuteAsync("SET ROLE zz_callable_probe_role;");
            Assert.True(await PgScripts.FunctionExistsAsync(connection, "zz_callable_probe.usp_probe", token));
            Assert.False(await PgScripts.FunctionCallableAsync(connection, "zz_callable_probe.usp_probe", token));
            Assert.False(await PgScripts.FunctionCallableAsync(connection, "zz_callable_probe.usp_not_there", token));

            await ExecuteAsync("RESET ROLE; GRANT USAGE ON SCHEMA zz_callable_probe TO zz_callable_probe_role; SET ROLE zz_callable_probe_role;");
            Assert.True(await PgScripts.FunctionCallableAsync(connection, "zz_callable_probe.usp_probe", token));
        }
        finally
        {
            await ExecuteAsync("RESET ROLE; DROP SCHEMA IF EXISTS zz_callable_probe CASCADE; DROP ROLE IF EXISTS zz_callable_probe_role;");
        }
    }

    /// <summary>
    /// Unit 2's Query Store leave-out (ADR 0031): the control script marks every routine it creates, every overload and
    /// only those, with COMMENT ON ROUTINE ... IS 'dbhubdemo:harness'. Setup runs twice against the disposable server, the
    /// first adding a mark that's missing and the second setting the marks again; then they're read as RCA-PG-16 reads them.
    /// A typo in the comment, the schema, or the list leaves a routine out, or marks something else.
    /// </summary>
    [Fact]
    public async Task SetupMarksExactlyTheHarnessRoutinesAsTheRcaReadsThem()
    {
        var server = Environment.GetEnvironmentVariable(ServerVariable);
        Assert.SkipUnless(server is not null, $"Set {ServerVariable}, {PgEndpoint.UserVariable}, and {PgEndpoint.PasswordVariable} to a disposable PostgreSQL server to run this test.");
        var token = TestContext.Current.CancellationToken;
        var created = Regex.Matches(PgScripts.Read("110-demo-control.sql"), @"(?m)^CREATE OR REPLACE FUNCTION (?<name>demo\.[a-z_]+)\(")
            .Select(m => m.Groups["name"].Value).Distinct().Order(StringComparer.Ordinal).ToList();
        Assert.Equal(13, created.Count);

        var endpoint = PgEndpoint.Create(server, null, passwordFromEnvironment: true, managedIdentityClientId: null);
        await using var connection = await new PgConnectionOpener(endpoint, RunnerLog.Null).OpenAsync(SessionNames.ForControl("test-marks"), token, PgSessionLimits.Setup);

        async Task<List<string>> ReadAsync(string sql, string[]? names = null)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            if (names is not null)
            {
                command.Parameters.AddWithValue("names", names);
            }

            var rows = new List<string>();
            await using var reader = await command.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
            {
                rows.Add(reader.GetString(0));
            }

            return rows;
        }

        foreach (var script in PgScripts.BaseSchema.Concat(PgScripts.DemoObjects))
        {
            await PgScripts.ApplyAsync(connection, script, RunnerLog.Null, token);
        }

        await using (var unmark = connection.CreateCommand())
        {
            unmark.CommandText = "DO $$ DECLARE routine regprocedure; BEGIN FOR routine IN SELECT p.oid::regprocedure FROM pg_catalog.pg_proc AS p WHERE p.pronamespace = 'demo'::regnamespace AND p.proname = 'usp_restore_seed' LOOP EXECUTE format('COMMENT ON ROUTINE %s IS NULL', routine); END LOOP; END $$;";
            await unmark.ExecuteNonQueryAsync(token);
        }

        Assert.DoesNotContain("demo.usp_restore_seed", await ReadAsync("SELECT n.nspname || '.' || p.proname FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace WHERE obj_description(p.oid, 'pg_proc') = 'dbhubdemo:harness';"));
        for (var setup = 0; setup < 2; setup++)
        {
            foreach (var script in PgScripts.DemoObjects)
            {
                await PgScripts.ApplyAsync(connection, script, RunnerLog.Null, token);
            }
        }

        // RCA-PG-16's harness: the routines whose comment, by obj_description, is the mark.
        var marked = await ReadAsync("SELECT DISTINCT n.nspname || '.' || p.proname FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace WHERE obj_description(p.oid, 'pg_proc') = 'dbhubdemo:harness';");
        Assert.Equal(created, marked.Order(StringComparer.Ordinal));

        // Every overload of a listed routine, and nothing else: no other object, in this database or shared, has the comment.
        Assert.Empty(await ReadAsync("SELECT p.oid::regprocedure::text FROM pg_catalog.pg_proc AS p WHERE p.pronamespace = 'demo'::regnamespace AND p.proname = ANY (@names) AND obj_description(p.oid, 'pg_proc') IS DISTINCT FROM 'dbhubdemo:harness';", created.Select(name => name["demo.".Length..]).ToArray()));
        Assert.Empty(await ReadAsync("SELECT d.classoid::regclass::text FROM pg_catalog.pg_description AS d WHERE d.description = 'dbhubdemo:harness' AND d.classoid <> 'pg_catalog.pg_proc'::regclass UNION ALL SELECT s.classoid::regclass::text FROM pg_catalog.pg_shdescription AS s WHERE s.description = 'dbhubdemo:harness';"));
    }

    private static PgEndpoint Endpoint() => PgEndpoint.Create("pgflex01-abc123", null, passwordFromEnvironment: false, managedIdentityClientId: null);

    [Theory]
    [InlineData("CC002", "Scenario 'healthy-baseline' already has a Running run on T4. Stop it first (demo.usp_stop).", "running-run")]
    [InlineData("CC002", "Four runs are already Running on T4, the most the demo allows. Stop one first.", "run-limit")]
    [InlineData("22023", "Unknown scenario 'x' for T4. See demo.fn_scenario_catalog().", "sql")]
    public void RegistrationRefusalsGetTheTSqlRunnersReasons(string sqlState, string message, string reason)
    {
        // Phase 25d, live: T4's refused baseline wasn't tried again, because its refusals had no reason the host retries.
        var refusal = new PostgresException(message, "ERROR", "ERROR", sqlState);

        Assert.Equal(reason, PgScenarioRunner.RegistrationRefusalReason(refusal));
        var result = new RunResult { RunId = "r", ScenarioId = "healthy-baseline", Target = DemoTarget.T4, Status = "Refused", Result = "Fail", Outcome = message, RefusalReason = reason };
        Assert.Equal(reason != "sql", result.CanRetryRefusal);
    }

    [Fact]
    public async Task ARequestForAnotherTargetIsRefusedAndNotRetried()
    {
        var runner = new PgScenarioRunner(new PgConnectionOpener(Endpoint(), RunnerLog.Null), RunnerLog.Null, TimeProvider.System);
        var baseline = ScenarioCatalog.Default.Get("healthy-baseline");

        var result = await runner.RunAsync(RunBounds.Plan(baseline, new RunRequest { ScenarioId = baseline.Id, Target = DemoTarget.T1, Duration = TimeSpan.FromSeconds(30), Concurrency = 1, Intensity = 1 }, DateTimeOffset.UtcNow), TestContext.Current.CancellationToken);

        Assert.Equal("Refused", result.Status);
        Assert.Equal("request", result.RefusalReason);
        Assert.False(result.CanRetryRefusal);
    }

    [GeneratedRegex(@"CREATE OR REPLACE FUNCTION (?<schema>[a-z_]+)\.(?<name>[a-z_]+)\((?<signature>[^)]*)\)(?<body>.*?)\$\$;", RegexOptions.Singleline)]
    private static partial Regex FunctionPattern();
}
