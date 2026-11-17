using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Npgsql;
using Xunit;
using CommandLineDefinition = ContosoCare.Workload.Cli.CommandLine;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// replica-lag (ADR 0025): T4's read replica as a second endpoint, the scenario's bounds and cycle timing, its refusal
/// without a replica, and the statements that only ever touch the demo's own sessions on the read-only replica. The
/// scenario itself needs a primary and a hot standby; its end-to-end test is opt-in.
/// </summary>
public sealed class ReplicaLagTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 13, 18, 0, 0, TimeSpan.Zero);

    [Fact]
    public void TheScenarioRunsOnT4OnlyWithinItsBounds()
    {
        var scenario = ScenarioCatalog.Default.Get(ReplicaLag.ScenarioId);

        Assert.Equal(["T4"], scenario.Targets.Applicable);
        Assert.Equal(["T4"], scenario.Targets.Default);
        Assert.Equal((600, 900), (scenario.Duration.DefaultSeconds, scenario.Duration.MaxSeconds));
        Assert.Equal((1, 1, 1), (scenario.Concurrency.Default, scenario.Concurrency.Min, scenario.Concurrency.Max));
        AssertParameter(scenario, "holdSeconds", 240, 30, 540);
        AssertParameter(scenario, "pauseSeconds", 60, 0, 300);
        AssertParameter(scenario, "markIntervalMs", 1000, 250, 10000);
        Assert.Equal(ReplicaLag.MinimumHoldSeconds, scenario.Parameters["holdSeconds"].Minimum);

        // The longest report, with its statement_timeout margin, ends before the replica's max_standby_streaming_delay
        // (10 minutes, ADR 0025), so recovery never has to cancel it.
        Assert.True(scenario.Parameters["holdSeconds"].Maximum + ReplicaLag.StatementMargin.TotalSeconds < 600);

        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T4, Duration = TimeSpan.FromHours(1), Concurrency = 4 }, Now);
        Assert.Equal(900, plan.DurationSeconds);
        Assert.Equal(1, plan.Concurrency);
        Assert.Throws<ScenarioRequestException>(() => RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T1 }, Now));
        Assert.Throws<ScenarioRequestException>(() => ScenarioCatalog.ResolveParameters(scenario, DemoTarget.T4, new Dictionary<string, string> { ["holdSeconds"] = "600" }));
    }

    [Fact]
    public async Task ARunWithoutTheReplicaIsRefusedBeforeItConnects()
    {
        // The endpoint names no real server: a refusal that tried to connect first would say "Can't connect".
        var runner = new PgScenarioRunner(new PgConnectionOpener(Endpoint(), RunnerLog.Null), RunnerLog.Null, TimeProvider.System);
        var scenario = ScenarioCatalog.Default.Get(ReplicaLag.ScenarioId);

        var result = await runner.RunAsync(RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T4 }, DateTimeOffset.UtcNow), TestContext.Current.CancellationToken);

        Assert.Equal("Refused", result.Status);
        Assert.Equal("Fail", result.Result);
        Assert.Equal("request", result.RefusalReason);
        Assert.False(result.CanRetryRefusal);
        Assert.Contains("start-demo.ps1 creates it", result.Outcome, StringComparison.Ordinal);
        Assert.Contains("deploy.ps1 sends T1 its name", result.Outcome, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(600, 240)]
    [InlineData(275, 240)]
    [InlineData(100, 65)]
    [InlineData(65, 30)]
    [InlineData(64, null)]
    [InlineData(10, null)]
    public void EachCycleEndsWithItsRecoveryBeforeTheDeadline(int secondsLeft, int? hold)
    {
        var cycle = ReplicaLag.CycleHold(240, Now, Now + TimeSpan.FromSeconds(secondsLeft));

        Assert.Equal(hold, cycle is { } value ? (int)value.TotalSeconds : null);
        if (cycle is { } held)
        {
            Assert.True(Now + ReplicaLag.StartMargin + held + ReplicaLag.RecoveryWindow <= Now + TimeSpan.FromSeconds(secondsLeft));
        }
    }

    [Fact]
    public void TheReportsTimeoutsEndBeforeTheHardDeadline()
    {
        var hold = TimeSpan.FromSeconds(240);

        var limits = ReplicaLag.ReportLimits(hold, TimeSpan.FromMinutes(10));
        Assert.Equal(270_000, limits.StatementTimeoutMs);
        Assert.Equal(15_000, limits.LockTimeoutMs);
        Assert.Equal(100_000, ReplicaLag.ReportLimits(hold, TimeSpan.FromSeconds(100)).StatementTimeoutMs);
        var late = ReplicaLag.ReportLimits(hold, TimeSpan.Zero);
        Assert.Equal(1_000, late.StatementTimeoutMs);
        Assert.Equal(1_000, late.LockTimeoutMs);
    }

    [Theory]
    [InlineData(600_000L, 239)]
    [InlineData(15_000L, 14)]
    [InlineData(-1L, 239)]
    [InlineData(null, 239)]
    public void TheLastLagReadComesJustBeforeTheReportEnds(long? standbyDelayMs, int secondsAfterLock)
    {
        // The report ends after its 240-second hold, or earlier when recovery cancels it max_standby_streaming_delay after
        // T4's lock (a local check, 2026-11-13: with 15 seconds, a read every 15 came too late to see the peak lag).
        var lockedAt = Now + TimeSpan.FromSeconds(1);

        Assert.Equal(lockedAt + TimeSpan.FromSeconds(secondsAfterLock), ReplicaLag.LastLagCheck(lockedAt + TimeSpan.FromSeconds(240), lockedAt, standbyDelayMs));
    }

    [Theory]
    [InlineData("None")]
    [InlineData("Cancel")]
    [InlineData("Terminate")]
    public void ReplicaSessionToolsTouchOnlyTheDemosSessionsInThisDatabase(string name)
    {
        var signal = Enum.Parse<ReplicaSignal>(name);
        var sql = PgReplicaSessions.Sql(signal);

        // demo.fn_demo_sessions' rule on T4, as direct SQL the read-only replica can run.
        Assert.Contains("a.datname = current_database()", sql, StringComparison.Ordinal);
        Assert.Contains("a.backend_type = 'client backend'", sql, StringComparison.Ordinal);
        Assert.Contains("a.pid <> pg_backend_pid()", sql, StringComparison.Ordinal);
        Assert.Contains("a.application_name LIKE 'ContosoCare.Demo/%'", sql, StringComparison.Ordinal);
        Assert.Contains("a.application_name NOT LIKE 'ContosoCare.Demo/control/%'", sql, StringComparison.Ordinal);
        Assert.Contains("a.application_name LIKE 'ContosoCare.Demo/%/' || @run_id::text", sql, StringComparison.Ordinal);
        Assert.Contains("a.application_name LIKE 'ContosoCare.Demo/' || @scenario_id::text || '/%'", sql, StringComparison.Ordinal);
        Assert.DoesNotMatch(@"(?i)\b(insert|update|delete|truncate)\b|demo\.usp_", sql);
        var signals = Regex.Count(sql, @"pg_(cancel|terminate)_backend\(");
        Assert.Equal(signal == ReplicaSignal.None ? 0 : 1, signals);
        Assert.Equal(signal != ReplicaSignal.None, sql.Contains("AND a.pid = @pid", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("run", "20261113180000-t4-a1b2c3", null, "20261113180000-t4-a1b2c3", null)]
    [InlineData("scenario", null, "replica-lag", null, "replica-lag")]
    [InlineData("all", null, null, null, null)]
    public void AStopEndsItsOwnScopeOnTheReplica(string scope, string? runId, string? scenarioId, string? expectedRun, string? expectedScenario)
    {
        var replicaScope = ReplicaSessionScope.ForStop(scope, runId, scenarioId);

        Assert.Equal(expectedRun, replicaScope.RunId);
        Assert.Equal(expectedScenario, replicaScope.ScenarioId);
        Assert.Throws<ArgumentException>(() => ReplicaSessionScope.Run("x%"));
        Assert.Throws<ArgumentException>(() => ReplicaSessionScope.Scenario("replica_lag"));
    }

    [Theory]
    [InlineData("pgreplica01-abc123", "pgreplica01-abc123.postgres.database.azure.com", 5432)]
    [InlineData("PGREPLICA01-abc123.postgres.database.azure.com", "pgreplica01-abc123.postgres.database.azure.com", 5432)]
    [InlineData("pgreplica01-abc123.postgres.database.azure.com:6432", "pgreplica01-abc123.postgres.database.azure.com", 6432)]
    public void TheReplicaSignsInAsT4sRunner(string server, string host, int port)
    {
        var primary = PgEndpoint.Create("pgflex01-abc123", null, passwordFromEnvironment: false, "11111111-2222-3333-4444-555555555555");

        var replica = primary.Replica(server)!;

        Assert.Equal(host, replica.Host);
        Assert.Equal(port, replica.Port);
        Assert.True(replica.IsReplica);
        Assert.Equal((primary.Database, primary.User, primary.Auth, primary.ManagedIdentityClientId), (replica.Database, replica.User, replica.Auth, replica.ManagedIdentityClientId));
        Assert.Equal(SslMode.VerifyFull, PgConnectionOpener.Build(replica, "ContosoCare.Demo/control/test", 30).SslMode);
        Assert.StartsWith("T4's read replica " + host, replica.Describe(), StringComparison.Ordinal);
        Assert.False(primary.IsReplica);
    }

    [Theory]
    [InlineData("pgflex01-abc123")]
    [InlineData("PGFLEX01-abc123.postgres.database.azure.com:5432")]
    [InlineData("bad host!")]
    public void TheReplicaIsNeitherT4ItselfNorABadName(string server) =>
        Assert.Throws<ScenarioRequestException>(() => PgEndpoint.Create("pgflex01-abc123", null, false, null).Replica(server));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("  ")]
    public void NoReplicaNameMeansNoReplica(string? server) =>
        Assert.Null(PgEndpoint.Create("pgflex01-abc123", null, false, null).Replica(server));

    [Theory]
    [InlineData("status", "--target", "T1", "--replica-server", "pgreplica01-abc123")]
    [InlineData("run", "--target", "T3", "--server", "azuresql01-abc123", "--scenario", "cpu-pressure", "--replica-server", "pgreplica01-abc123")]
    [InlineData("profile", "run", "--target", "T1", "--t4-replica-server", "pgreplica01-abc123")]
    public void TheReplicaOptionsAreForT4Only(params string[] args)
    {
        var (exitCode, _, error) = CliHarness.Invoke(args);

        Assert.Equal(1, exitCode);
        Assert.Matches("--replica-server is for T4|--t4-replica-server goes with --t4-server", error);
    }

    [Fact]
    public void TheStepTheRunnerCallsIsTheScenariosFunction()
    {
        var functions = PgScripts.Read("120-scenario-functions.sql");
        var function = functions[functions.IndexOf("CREATE OR REPLACE FUNCTION demo.usp_scenario_replica_lag(", StringComparison.Ordinal)..];
        function = function[..function.IndexOf("$$;", StringComparison.Ordinal)];

        Assert.Equal("demo.usp_scenario_replica_lag", ScenarioCatalog.Default.Get(ReplicaLag.ScenarioId).Procedure);
        Assert.Contains("demo.usp_scenario_replica_lag(@run_id, @take_lock)", ReplicaLag.StepSql, StringComparison.Ordinal);
        Assert.Contains("(p_run_id varchar, p_lock boolean)", function, StringComparison.Ordinal);
        Assert.Contains("RETURNS TABLE (marks_written integer, locks_taken integer, last_mark_id bigint)", function, StringComparison.Ordinal);
        Assert.StartsWith("SELECT marks_written, locks_taken, last_mark_id FROM", ReplicaLag.StepSql, StringComparison.Ordinal);

        // The run is checked before the lock, and T4 never waits long for it.
        Assert.True(function.IndexOf("demo.usp_run_assert_running(p_run_id)", StringComparison.Ordinal) < function.IndexOf("LOCK TABLE demo.replica_lag_marks IN ACCESS EXCLUSIVE MODE", StringComparison.Ordinal));
        Assert.Contains("SET lock_timeout = '5s'", function, StringComparison.Ordinal);
    }

    [Fact]
    public void TheMarksAreDeletedNeverTruncated()
    {
        // TRUNCATE takes an ACCESS EXCLUSIVE lock that the replica would have to replay, behind a report that holds the table.
        var control = PgScripts.Read("110-demo-control.sql");

        foreach (var name in new[] { "demo.usp_cleanup_scenario", "demo.usp_restore_seed" })
        {
            var function = control[control.IndexOf("CREATE OR REPLACE FUNCTION " + name + "(", StringComparison.Ordinal)..];
            function = function[..function.IndexOf("$$;", StringComparison.Ordinal)];
            Assert.Contains("DELETE FROM demo.replica_lag_marks", function, StringComparison.Ordinal);
        }

        Assert.DoesNotContain("TRUNCATE demo.replica_lag_marks", control, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TheStatusReplicaBlockLeavesTheTailsBlocksAlone()
    {
        // The operator side finds the "server" and "host" blocks by name in the tail a Run Command keeps
        // (ConvertFrom-DemoT4ServerJson, the WORKLOAD.T4.HOST check), so the replica's block names neither.
        var node = CommandLineDefinition.ReplicaNode(new PgReplicaView("pgreplica01-abc123.postgres.database.azure.com", false, null, null, null, null, "Its name doesn't resolve."));

        Assert.DoesNotContain("\"server\"", node.ToJsonString(), StringComparison.Ordinal);
        Assert.DoesNotContain("\"host\"", node.ToJsonString(), StringComparison.Ordinal);
        Assert.Equal("pgreplica01-abc123.postgres.database.azure.com", node["fqdn"]!.GetValue<string>());
    }

    // Opt-in end-to-end test --------------------------------------------------------------------------------------------

    private const string ServerVariable = "CONTOSOCARE_TEST_PG_SERVER";
    private const string ReplicaVariable = "CONTOSOCARE_TEST_PG_REPLICA";

    /// <summary>
    /// Against a disposable PostgreSQL primary (CONTOSOCARE_TEST_PG_SERVER, set up and seeded as in
    /// PostgresTests.SetupRunAndResetAgainstALocalServer) and its hot standby (CONTOSOCARE_TEST_PG_REPLICA), both reached
    /// with CONTOSOCARE_PG_USER and CONTOSOCARE_PG_PASSWORD: one 30-second cycle, whose report holds the replica's replay
    /// back, then a reset that ends the demo's sessions on the replica. CI doesn't set them.
    /// </summary>
    [Fact]
    public async Task OneCycleHoldsTheStandbysReplayBackAgainstALocalPair()
    {
        var server = Environment.GetEnvironmentVariable(ServerVariable);
        var standby = Environment.GetEnvironmentVariable(ReplicaVariable);
        Assert.SkipUnless(server is not null && standby is not null, $"Set {ServerVariable}, {ReplicaVariable}, {PgEndpoint.UserVariable}, and {PgEndpoint.PasswordVariable} to a disposable PostgreSQL primary and its hot standby to run this test.");
        var token = TestContext.Current.CancellationToken;
        var primary = PgEndpoint.Create(server, null, passwordFromEnvironment: true, managedIdentityClientId: null);
        var runner = new PgScenarioRunner(new PgConnectionOpener(primary, RunnerLog.Null), RunnerLog.Null, TimeProvider.System, new PgConnectionOpener(primary.Replica(standby)!, RunnerLog.Null));
        var scenario = ScenarioCatalog.Default.Get(ReplicaLag.ScenarioId);
        var parameters = new Dictionary<string, string> { ["holdSeconds"] = "30", ["pauseSeconds"] = "0", ["markIntervalMs"] = "500" };

        var result = await runner.RunAsync(RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T4, Duration = TimeSpan.FromSeconds(70), Parameters = parameters }, DateTimeOffset.UtcNow), token);

        Assert.True(result.Status == "Completed", result.Outcome);
        var writer = Assert.Single(result.Workers);
        Assert.Equal(1, writer.Metrics["cycles"]);
        Assert.Equal(1, writer.Metrics["locks_taken"]);
        Assert.True((long)writer.Metrics["longest_lag_ms"]! >= 20_000, result.Outcome);
        Assert.Contains(result.Checks, c => c.CheckId == "run-replica-sessions-closed" && c.Status == "Pass");

        var reset = await runner.ResetAsync(new ResetOptions("test", 5, KillSessions: true, KeepProfile: true, UndoRemediation: false, Reseed: false), token);
        Assert.Contains(reset, c => c.CheckId == "replica-sessions-ended" && c.Status == "Pass");
        Assert.Contains(reset, c => c.CheckId == "scratch-emptied" && c.Status == "Pass");
    }

    private static PgEndpoint Endpoint() => PgEndpoint.Create("pgflex01-abc123", null, passwordFromEnvironment: false, managedIdentityClientId: null);

    private static void AssertParameter(ScenarioDefinition scenario, string name, long value, long minimum, long maximum)
    {
        var parameter = scenario.Parameters[name];
        Assert.Equal(value, parameter.Default.GetInt64());
        Assert.Equal((minimum, maximum), (parameter.Minimum, parameter.Maximum));
    }
}
