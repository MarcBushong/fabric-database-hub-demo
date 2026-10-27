using System.Data;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// End-to-end checks against a real SQL Server with Windows authentication: the T-SQL bounds, stop, reset, the
/// watchdog's session filter, and a short blocking run that leaves the data unchanged. Opt-in: set
/// CONTOSOCARE_TEST_SQL_SERVER to a disposable instance (for example a LocalDB instance created for the purpose,
/// "(localdb)\contosocare-test"); the tests create or reuse its ContosoCare database. CI doesn't set it.
/// </summary>
public sealed class SqlIntegrationTests
{
    private const string ServerVariable = "CONTOSOCARE_TEST_SQL_SERVER";
    private static readonly string? Server = Environment.GetEnvironmentVariable(ServerVariable);
    private static readonly SemaphoreSlim Prepared = new(1, 1);
    private static bool ready;

    private static TargetEndpoint Endpoint => TargetEndpoint.Create(DemoTarget.T2, Server, sqlLoginFromEnvironment: false, managedIdentityClientId: null);

    [Fact]
    public async Task BeginClampsAndLimitsRuns()
    {
        await PrepareAsync();
        await using var connection = await OpenAsync(SessionNames.ForControl("test"));
        var database = new DemoDatabase(connection);
        var token = TestContext.Current.CancellationToken;

        var first = await database.BeginRunAsync("it-clamp-" + Suffix(), "log-rate-pressure", DemoTarget.T2, 99999, 1, 5, "{}", "test", "test", null, token);
        var duplicate = await Assert.ThrowsAsync<SqlException>(() => database.BeginRunAsync("it-dup-" + Suffix(), "log-rate-pressure", DemoTarget.T2, 60, 1, 5, "{}", "test", "test", null, token));
        await database.StopAsync("scenario", null, "log-rate-pressure", "test", setProfileOff: false, token);

        Assert.Equal(900, first.EffectiveDurationSeconds);
        Assert.Equal(50108, duplicate.Number);
        var badId = await Assert.ThrowsAsync<SqlException>(() => database.BeginRunAsync("Bad Id", "cpu-pressure", DemoTarget.T2, 60, 1, 5, "{}", "test", "test", null, token));
        Assert.Equal(50101, badId.Number);
    }

    [Fact]
    public async Task SetupFindsTheProcedureOfEveryScenarioItRuns()
    {
        // Phase 25d: the scripts create every procedure the catalog names for a SQL Server target, and the check
        // reports a procedure that doesn't exist by name.
        await PrepareAsync();
        await using var connection = await OpenAsync(SessionNames.ForControl("test"));
        var token = TestContext.Current.CancellationToken;

        var missing = await SqlScripts.FindMissingProceduresAsync(connection, SqlScripts.ExpectedProcedures(ScenarioCatalog.Default, DemoTarget.T2), token);
        var unknown = await SqlScripts.FindMissingProceduresAsync(connection, ["demo.usp_scenario_chain_link", "demo.usp_scenario_no_such_scenario"], token);

        Assert.Empty(missing);
        Assert.Equal(["demo.usp_scenario_no_such_scenario"], unknown);
    }

    [Fact]
    public async Task ScenarioProceduresRefuseRunsTheyDoNotOwn()
    {
        await PrepareAsync();
        await using var connection = await OpenAsync(SessionNames.ForControl("test"));
        await using var command = connection.CreateCommand();
        command.CommandText = "EXEC demo.usp_scenario_cpu_pressure @run_id = 'it-no-such-run';";

        var error = await Assert.ThrowsAsync<SqlException>(() => command.ExecuteNonQueryAsync(TestContext.Current.CancellationToken));

        Assert.Equal(50110, error.Number);
    }

    [Fact]
    public async Task TheWatchdogKillsOnlyItsOwnSessions()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var runId = "it-kill-" + Suffix();
        await using var control = await OpenAsync(SessionNames.ForControl("test"));
        var database = new DemoDatabase(control);
        await database.BeginRunAsync(runId, "inefficient-query", DemoTarget.T2, 60, 1, 1, "{}", "test", "test", null, token);

        // A demo session of this run and an unrelated session, both idle with an open transaction.
        await using var demo = await OpenAsync(SessionNames.ForRun("inefficient-query", runId));
        await using var bystander = await OpenAsync("SomeOtherApplication");
        foreach (var connection in new[] { demo, bystander })
        {
            await using var open = connection.CreateCommand();
            open.CommandText = "BEGIN TRANSACTION; SELECT TOP (1) facility_id FROM care.facilities WITH (UPDLOCK, HOLDLOCK) WHERE facility_id = " + (connection == demo ? "1" : "2") + ";";
            await open.ExecuteNonQueryAsync(token);
        }

        var summary = await database.KillRunSessionsAsync(runId, pastDeadlineOnly: false, "test", token);

        Assert.True(summary.CanViewSessions);
        Assert.Equal(1, summary.Killed);
        Assert.Equal(0, summary.Failed);
        await using (var check = bystander.CreateCommand())
        {
            check.CommandText = "SELECT @@TRANCOUNT;";
            Assert.Equal(1, (int)(await check.ExecuteScalarAsync(token))!);
            check.CommandText = "ROLLBACK TRANSACTION;";
            await check.ExecuteNonQueryAsync(token);
        }

        await using (var dead = demo.CreateCommand())
        {
            dead.CommandText = "SELECT 1;";
            await Assert.ThrowsAnyAsync<Exception>(() => dead.ExecuteScalarAsync(token));
        }

        await database.EndRunAsync(runId, "Cancelled", "test", null, token);
    }

    [Fact]
    public async Task ABlockingRunBlocksStopsAtItsDeadlineAndLeavesTheDataAsSeeded()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var before = await ChecksumAsync(token);
        var scenario = ScenarioCatalog.Default.Get("locking-blocking");
        var request = new RunRequest
        {
            ScenarioId = scenario.Id,
            Target = DemoTarget.T2,
            Duration = TimeSpan.FromSeconds(35),
            Concurrency = 2,
            Parameters = new Dictionary<string, string> { ["holdSeconds"] = "12", ["pauseSeconds"] = "3", ["deadlock"] = "true", ["normalWorkers"] = "0" },
            RequestedBy = "integration-test",
        };
        var plan = RunBounds.Plan(scenario, request, DateTimeOffset.UtcNow);
        var started = DateTimeOffset.UtcNow;

        var result = await new ScenarioRunner(new SqlConnectionOpener(Endpoint, RunnerLog.Null), RunnerLog.Null, TimeProvider.System).RunAsync(plan, token);

        Assert.Equal("Completed", result.Status);
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(35) + RunLimits.Grace, "The run outlived its deadline plus the grace period.");
        var contenders = result.Workers.Where(w => w.Role == "contender").ToList();
        Assert.Equal(2, contenders.Count);
        Assert.True(contenders.Sum(c => Convert.ToInt64(c.Metrics["waited_ms"], System.Globalization.CultureInfo.InvariantCulture)) > 5000, "The contenders were never blocked.");
        Assert.Equal(1, result.Workers.Where(w => w.Role == "deadlock").Sum(w => Convert.ToInt32(w.Metrics["deadlock_victim"], System.Globalization.CultureInfo.InvariantCulture)));
        Assert.Contains(result.Checks, c => c.CheckId == "run-sessions-closed" && c.Status == "Pass");
        Assert.Equal(before, await ChecksumAsync(token));
    }

    [Fact]
    public async Task AStopRequestEndsARunWithinSeconds()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var scenario = ScenarioCatalog.Default.Get("cpu-pressure");
        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2, Duration = TimeSpan.FromSeconds(120), Concurrency = 1, Intensity = 1 }, DateTimeOffset.UtcNow);
        var run = new ScenarioRunner(new SqlConnectionOpener(Endpoint, RunnerLog.Null), RunnerLog.Null, TimeProvider.System).RunAsync(plan, token);

        await Task.Delay(TimeSpan.FromSeconds(8), token);
        await using (var control = await OpenAsync(SessionNames.ForControl("test")))
        {
            Assert.Equal(1, await new DemoDatabase(control).StopAsync("scenario", null, "cpu-pressure", "integration-test", setProfileOff: false, token));
        }

        var stoppedAt = DateTimeOffset.UtcNow;
        var result = await run;

        Assert.Equal("Cancelled", result.Status);
        Assert.True(DateTimeOffset.UtcNow - stoppedAt < TimeSpan.FromSeconds(15), "The run took too long to stop.");
    }

    [Fact]
    public async Task ResetReturnsAQuietState()
    {
        await PrepareAsync();
        await using var connection = await OpenAsync(SessionNames.ForControl("test"));

        var checks = await new DemoDatabase(connection).ResetAsync(new ResetOptions("integration-test", 10, KillSessions: true, KeepProfile: false, UndoRemediation: true, Reseed: false), TestContext.Current.CancellationToken);

        Assert.All(checks, c => Assert.True(c.Status is "Pass" or "Not selected", $"{c.CheckId}: {c.Status}: {c.Message}"));
        Assert.Contains(checks, c => c.CheckId == "no-open-demo-transactions" && c.Status == "Pass");
    }

    [Fact]
    public async Task ABlockingChainFormsItsLevelsEscalatesAndLeavesTheDataAsSeeded()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var before = await ChecksumAsync(token);
        var appointmentsBefore = await AppointmentsChecksumAsync(token);

        var result = await RunScenarioAsync(
            "blocking-chain",
            TimeSpan.FromSeconds(40),
            concurrency: 2,
            intensity: null,
            new Dictionary<string, string> { ["depth"] = "3", ["holdSeconds"] = "20", ["pauseSeconds"] = "3", ["escalationHoldSeconds"] = "5", ["escalationEverySeconds"] = "30", ["normalWorkers"] = "0" },
            token);

        Assert.Equal("Completed", result.Status);
        var links = result.Workers.Where(w => w.Role == "link").ToList();
        Assert.Equal(4, links.Count);
        Assert.All(links, l => Assert.Null(l.Error));
        // Level 3 waits behind level 2, which waits behind the head blocker: both levels are blocked for most of each hold.
        foreach (var level in new[] { 2, 3 })
        {
            Assert.All(
                links.Where(l => Number(l.Metrics["level"]) == level),
                l => Assert.True(Number(l.Metrics["waited_ms"]) > 5000, $"A level-{level} link was never blocked."));
        }

        var escalator = Assert.Single(result.Workers, w => w.Role == "escalator");
        Assert.Null(escalator.Error);
        Assert.Equal(1, Number(escalator.Metrics["table_locks"]));
        Assert.Contains(result.Checks, c => c.CheckId == "run-sessions-closed" && c.Status == "Pass");
        Assert.Equal(before, await ChecksumAsync(token));
        Assert.Equal(appointmentsBefore, await AppointmentsChecksumAsync(token));
    }

    [Fact]
    public async Task ADeadlockStormPicksTheLowPrioritySideAndChangesNothing()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var before = await ChecksumAsync(token);

        var result = await RunScenarioAsync("deadlock-storm", TimeSpan.FromSeconds(35), concurrency: 1, intensity: 10, new Dictionary<string, string> { ["maxRounds"] = "3", ["shape"] = "mixed" }, token);

        Assert.Equal("Completed", result.Status);
        Assert.Equal(0, result.Workers.Where(w => w.Role == "side1").Sum(w => Number(w.Metrics["deadlock_victim"])));
        Assert.True(result.Workers.Where(w => w.Role == "side2").Sum(w => Number(w.Metrics["deadlock_victim"])) >= 2, "Side 2 wasn't chosen as a deadlock victim.");
        Assert.Contains(result.Checks, c => c.CheckId == "run-sessions-closed" && c.Status == "Pass");
        Assert.Equal(before, await ChecksumAsync(token));
    }

    [Theory]
    [InlineData("tempdb-contention", "temp_tables", null)]
    [InlineData("memory-grant-pressure", "queries", null)]
    [InlineData("parallel-scans", "queries", null)]
    [InlineData("log-flush-waits", "commits", "maxRows=2000")]
    public async Task AWaitScenarioRunsWithinItsBounds(string id, string counter, string? parameter)
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var parameters = new Dictionary<string, string>();
        if (parameter is not null)
        {
            parameters[parameter.Split('=')[0]] = parameter.Split('=')[1];
        }

        var started = DateTimeOffset.UtcNow;
        var result = await RunScenarioAsync(id, TimeSpan.FromSeconds(30), concurrency: 2, intensity: null, parameters, token);

        Assert.Equal("Completed", result.Status);
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(30) + RunLimits.Grace, "The run outlived its deadline plus the grace period.");
        Assert.All(result.Workers, w => Assert.True(Number(w.Metrics[counter]) > 0, $"{w.Role} {w.Index} did no work."));
        Assert.Contains(result.Checks, c => c.CheckId == "run-sessions-closed" && c.Status == "Pass");
        Assert.Contains(result.Checks, c => c.CheckId == "auto-cleanup" && c.Status is "Pass" or "Not selected");
    }

    [Fact]
    public async Task ASlowConsumerReadsSlowlyAndCancelsAtTheDeadline()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;

        var result = await RunScenarioAsync("slow-consumer", TimeSpan.FromSeconds(30), concurrency: 2, intensity: 1, new Dictionary<string, string> { ["rowsPerQuery"] = "500000" }, token);

        Assert.Equal("Completed", result.Status);
        Assert.Equal(2, result.Workers.Count);
        Assert.All(result.Workers, w =>
        {
            Assert.Null(w.Error);
            // 25 rows every 100 ms for about 30 seconds: thousands of rows, far fewer than the query returns.
            Assert.InRange(Number(w.Metrics["rows_read"]), 1000, 20000);
            Assert.True(Number(w.Metrics["cancelled_queries"]) >= 1, "The query wasn't cancelled at the deadline.");
        });
        Assert.Contains(result.Checks, c => c.CheckId == "run-sessions-closed" && c.Status == "Pass");
    }

    [Fact]
    public async Task CapacityMaxRunsCpuAndIoSessionsAndEmptiesTheScratchSet()
    {
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;

        var result = await RunScenarioAsync("capacity-max", TimeSpan.FromSeconds(30), concurrency: 2, intensity: 10, new Dictionary<string, string> { ["ioWorkers"] = "1", ["scratchMb"] = "64" }, token);

        Assert.Equal("Completed", result.Status);
        Assert.Equal(2, result.Workers.Count(w => w.Role == "cpu"));
        Assert.All(result.Workers.Where(w => w.Role == "cpu"), w => Assert.True(Number(w.Metrics["queries"]) > 0));
        var io = Assert.Single(result.Workers, w => w.Role == "io");
        Assert.True(Number(io.Metrics["scans"]) > 0, "The IO session never scanned.");
        Assert.Contains(result.Checks, c => c.CheckId == "auto-cleanup" && c.Status == "Pass");
    }

    private static async Task<RunResult> RunScenarioAsync(string id, TimeSpan duration, int? concurrency, int? intensity, Dictionary<string, string> parameters, CancellationToken token)
    {
        var scenario = ScenarioCatalog.Default.Get(id);
        var request = new RunRequest
        {
            ScenarioId = scenario.Id,
            Target = DemoTarget.T2,
            Duration = duration,
            Concurrency = concurrency,
            Intensity = intensity,
            Parameters = parameters,
            RequestedBy = "integration-test",
        };
        var plan = RunBounds.Plan(scenario, request, DateTimeOffset.UtcNow);
        return await new ScenarioRunner(new SqlConnectionOpener(Endpoint, RunnerLog.Null), RunnerLog.Null, TimeProvider.System).RunAsync(plan, token);
    }

    private static long Number(object? value) => Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);

    private static async Task<long> AppointmentsChecksumAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(SessionNames.ForControl("checksum"));
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT CAST(ISNULL(CHECKSUM_AGG(CHECKSUM(appointment_id, duration_minutes, status)), 0) AS bigint) FROM care.appointments;";
        return Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture);
    }

    [Fact]
    public async Task OnlyProfileRunsThatAnEarlierHostLeftWithoutSessionsAreRecovered()
    {
        // Phase 25b: after a task restart, the killed host's runs stayed Running until their deadline and refused the
        // new host's runs of the same scenario (50108).
        await PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        await using var control = await OpenAsync(SessionNames.ForControl("test"));
        var database = new DemoDatabase(control);
        var suffix = Suffix();
        var orphan = "it-orphan-" + suffix;
        var foreign = "it-foreign-" + suffix;
        var foreground = "it-foreground-" + suffix;
        var live = "it-live-" + suffix;
        await database.BeginRunAsync(orphan, "missing-index", DemoTarget.T2, 600, 1, 1, "{}", "test", "profile:baseline", "baseline", token);
        await database.BeginRunAsync(foreign, "io-pressure", DemoTarget.T2, 600, 1, 1, "{}", "test", "profile:baseline", "baseline", token);
        await database.BeginRunAsync(foreground, "deadlock-storm", DemoTarget.T2, 600, 1, 1, "{}", "test", "runner", null, token);
        await database.BeginRunAsync(live, "cpu-pressure", DemoTarget.T2, 600, 1, 1, "{}", "test", "profile:incident:cpu-pressure", "incident:cpu-pressure", token);
        await using (var other = control.CreateCommand())
        {
            other.CommandText = "UPDATE demo.scenario_runs SET runner_host = N'another-machine' WHERE run_id = @run_id;";
            other.Parameters.Add(new SqlParameter("@run_id", SqlDbType.VarChar, 64) { Value = foreign });
            await other.ExecuteNonQueryAsync(token);
        }

        await using var session = await OpenAsync(SessionNames.ForRun("cpu-pressure", live));
        try
        {
            var none = await database.RecoverOrphanedProfileRunsAsync(Environment.MachineName, DateTimeOffset.UtcNow.AddHours(-1), token);
            var recovered = await database.RecoverOrphanedProfileRunsAsync(Environment.MachineName, DateTimeOffset.UtcNow.AddMinutes(1), token);

            Assert.Empty(none!);
            Assert.Equal(new[] { orphan }, recovered);
            var runs = (await database.GetRunsAsync(100, runningOnly: false, token)).ToDictionary(r => r.RunId, StringComparer.Ordinal);
            Assert.Equal("Cancelled", runs[orphan].Status);
            Assert.Contains("Recovered: the profile host that started it stopped", runs[orphan].Outcome, StringComparison.Ordinal);
            Assert.Equal("Running", runs[foreign].Status);
            Assert.Equal("Running", runs[foreground].Status);
            Assert.Equal("Running", runs[live].Status);
        }
        finally
        {
            foreach (var runId in new[] { foreign, foreground, live })
            {
                await database.EndRunAsync(runId, "Cancelled", "test", null, token);
            }
        }
    }

    private static async Task PrepareAsync()
    {
        Assert.SkipUnless(Server is not null, $"Set {ServerVariable} to a disposable SQL Server instance to run the integration tests.");
        await Prepared.WaitAsync(TestContext.Current.CancellationToken);
        try
        {
            if (ready)
            {
                return;
            }

            await using (var master = new SqlConnection(new SqlConnectionStringBuilder { DataSource = Server, InitialCatalog = "master", IntegratedSecurity = true, TrustServerCertificate = true, Pooling = false }.ConnectionString))
            {
                await master.OpenAsync(TestContext.Current.CancellationToken);
                await using var create = master.CreateCommand();
                create.CommandText = "IF DB_ID(N'ContosoCare') IS NULL CREATE DATABASE ContosoCare;";
                await create.ExecuteNonQueryAsync(TestContext.Current.CancellationToken);
            }

            await using var connection = await OpenAsync(SessionNames.ForControl("setup"));
            await using (var cap = connection.CreateCommand())
            {
                // The IO and log-rate scenarios refuse to grow an uncapped file, as on T1 and T2 (030-configure.sql).
                cap.CommandText =
                    """
                    DECLARE @sql nvarchar(max) = N'';
                    SELECT @sql += N'ALTER DATABASE CURRENT MODIFY FILE (NAME = ' + QUOTENAME(name) + N', MAXSIZE = 4096MB);'
                    FROM sys.database_files WHERE max_size = -1;
                    EXEC (@sql);
                    """;
                await cap.ExecuteNonQueryAsync(TestContext.Current.CancellationToken);
            }

            foreach (var script in SqlScripts.BaseSchema.Concat(SqlScripts.DemoObjects))
            {
                await SqlScripts.ApplyAsync(connection, script, RunnerLog.Null, TestContext.Current.CancellationToken);
            }

            await using var seed = connection.CreateCommand();
            // A clean slate: stop anything an earlier, interrupted test run left Running, then seed (a no-op when seeded).
            seed.CommandText = "EXEC demo.usp_stop @scope = 'all', @requested_by = N'integration-test', @return_results = 0; EXEC demo.usp_recover_stale_runs @grace_seconds = 0; EXEC demo.usp_seed_contosocare @scale = 1;";
            seed.CommandTimeout = 600;
            await seed.ExecuteNonQueryAsync(TestContext.Current.CancellationToken);
            ready = true;
        }
        finally
        {
            Prepared.Release();
        }
    }

    private static Task<SqlConnection> OpenAsync(string applicationName) =>
        new SqlConnectionOpener(Endpoint, RunnerLog.Null).OpenAsync(applicationName, TestContext.Current.CancellationToken);

    private static async Task<long> ChecksumAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(SessionNames.ForControl("checksum"));
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT CAST(ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(work_item_id, priority, status, assigned_to)) FROM care.work_queues), 0) AS bigint) * 7
                 + ISNULL((SELECT CHECKSUM_AGG(CHECKSUM(inventory_id, quantity_on_hand, updated_at)) FROM care.inventory), 0);
            """;
        return Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string Suffix() => Guid.NewGuid().ToString("N")[..8];
}
