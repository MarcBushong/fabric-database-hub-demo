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

    [Fact]
    public void EveryScenarioStepAssertsItsRunFirst()
    {
        var text = PgScripts.Read("120-scenario-functions.sql");
        var functions = FunctionPattern().Matches(text);

        Assert.True(functions.Count >= 12);
        foreach (Match function in functions)
        {
            var name = function.Groups["name"].Value;
            if (!name.StartsWith("usp_scenario_", StringComparison.Ordinal))
            {
                continue;
            }

            var body = function.Groups["body"].Value;
            Assert.True(body.Contains("demo.usp_run_assert_running(p_run_id)", StringComparison.Ordinal), $"demo.{name} doesn't check its run first.");
        }
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
        var runId = SessionNames.NewRunId(new DateTimeOffset(2026, 10, 23, 23, 59, 59, TimeSpan.Zero), DemoTarget.T4);

        foreach (var scenario in ScenarioCatalog.Default.All.Where(s => s.AppliesTo(DemoTarget.T4)))
        {
            Assert.True(SessionNames.ForRun(scenario.Id, runId).Length <= PgConnectionOpener.MaximumApplicationNameLength, scenario.Id);
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
        var missingIndex = ScenarioCatalog.Default.Get("missing-index");
        Assert.Throws<ScenarioRequestException>(() => RunBounds.Plan(missingIndex, new RunRequest { ScenarioId = missingIndex.Id, Target = DemoTarget.T4 }, DateTimeOffset.UtcNow));
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

    [GeneratedRegex(@"CREATE OR REPLACE FUNCTION demo\.(?<name>[a-z_]+)\((?<signature>[^)]*)\)(?<body>.*?)\$\$;", RegexOptions.Singleline)]
    private static partial Regex FunctionPattern();
}
