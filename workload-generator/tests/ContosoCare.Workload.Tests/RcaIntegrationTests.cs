using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.AnswerKey;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The RCA observer against real engines, opt-in like the runner's other end-to-end tests: the workload injects faults
/// with its own scenario runner, the observer captures blind (it's told only that T4 is in a session), and the export's
/// detection tables must find the injected runs' sessions by what the engine showed, with the answer key's run tokens.
/// </summary>
public sealed class RcaIntegrationTests : IDisposable
{
    private const string ServerVariable = "CONTOSOCARE_TEST_PG_SERVER";
    private const string ReplicaVariable = "CONTOSOCARE_TEST_PG_REPLICA";

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-integration-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    /// <summary>
    /// Against a disposable PostgreSQL primary (CONTOSOCARE_TEST_PG_SERVER) and its hot standby (CONTOSOCARE_TEST_PG_REPLICA,
    /// application_name t4-replica), both reached as CONTOSOCARE_PG_USER (a member of pg_read_all_stats, as T4's setup
    /// grants it) with CONTOSOCARE_PG_PASSWORD: locking-blocking with a deadlock round, and one replica-lag cycle, while
    /// the observer lane runs at shortened cadences. CI doesn't set them.
    /// </summary>
    [Fact]
    public async Task OnALocalPrimaryAndStandbyTheBlindCaptureFindsTheChainTheDeadlockAndTheReplayStall()
    {
        var server = Environment.GetEnvironmentVariable(ServerVariable);
        var standby = Environment.GetEnvironmentVariable(ReplicaVariable);
        Assert.SkipUnless(server is not null && standby is not null, $"Set {ServerVariable}, {ReplicaVariable}, {PgEndpoint.UserVariable}, and {PgEndpoint.PasswordVariable} to a disposable PostgreSQL primary and its hot standby to run this test.");
        var token = TestContext.Current.CancellationToken;
        var primary = PgEndpoint.Create(server, null, passwordFromEnvironment: true, managedIdentityClientId: null);
        var replica = primary.Replica(standby)!;
        var opener = new PgConnectionOpener(primary, RunnerLog.Null);
        await using (var setup = await opener.OpenAsync(SessionNames.ForControl("test-setup"), token, PgSessionLimits.Setup))
        {
            foreach (var script in PgScripts.BaseSchema.Concat(PgScripts.DemoObjects))
            {
                await PgScripts.ApplyAsync(setup, script, RunnerLog.Null, token);
            }

            Assert.Equal("Pass", (await PgScripts.SeedAsync(setup, 1, force: false, token)).Status);
        }

        var options = new ObserverOptions { Sentinel = TimeSpan.FromSeconds(5), BlockingDetail = TimeSpan.FromSeconds(2), ReplayDetail = TimeSpan.FromSeconds(2), QuietFor = TimeSpan.FromSeconds(10), SlowSample = TimeSpan.FromSeconds(5) };
        var link = new ReplicaLink();
        var store = new EvidenceStore(root, TimeProvider.System, host: "sqlvm01");
        var gate = new Gate();
        var lane = new ObserverLane(
            [new PgPrimaryObserver(new PgCaptureConnector(primary, RunnerLog.Null), options, RunnerLog.Null, link), new PgReplicaObserver(new PgCaptureConnector(replica, RunnerLog.Null), options, RunnerLog.Null, link)],
            [],
            gate,
            store,
            RunnerLog.Null,
            TimeProvider.System,
            options);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        var observing = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        await Task.Delay(TimeSpan.FromSeconds(8), token);

        var runner = new PgScenarioRunner(opener, RunnerLog.Null, TimeProvider.System, new PgConnectionOpener(replica, RunnerLog.Null));
        var locking = ScenarioCatalog.Default.Get("locking-blocking");
        var lag = ScenarioCatalog.Default.Get(ReplicaLag.ScenarioId);
        var results = await Task.WhenAll(
            runner.RunAsync(RunBounds.Plan(locking, new RunRequest { ScenarioId = locking.Id, Target = DemoTarget.T4, Duration = TimeSpan.FromSeconds(60), Concurrency = 3, Parameters = new Dictionary<string, string>(StringComparer.Ordinal) { ["holdSeconds"] = "25", ["pauseSeconds"] = "5", ["deadlock"] = "true" } }, DateTimeOffset.UtcNow), token),
            runner.RunAsync(RunBounds.Plan(lag, new RunRequest { ScenarioId = lag.Id, Target = DemoTarget.T4, Duration = TimeSpan.FromSeconds(75), Parameters = new Dictionary<string, string>(StringComparer.Ordinal) { ["holdSeconds"] = "45", ["pauseSeconds"] = "0", ["markIntervalMs"] = "500" } }, DateTimeOffset.UtcNow), token));
        var (lockRun, lagRun) = (results[0], results[1]);
        Assert.True(lockRun.Status == "Completed", lockRun.Outcome);
        Assert.True(lagRun.Status == "Completed", lagRun.Outcome);

        // The answer key, as the profile host records it: apart from the capture.
        foreach (var result in results)
        {
            foreach (var row in AnswerKeyRecorder.Rows(DemoTarget.T4, result, []))
            {
                Assert.True(store.AppendAnswerKey(row));
            }
        }

        await Task.Delay(TimeSpan.FromSeconds(15), token);
        gate.Active = false;
        await Task.Delay(TimeSpan.FromSeconds(3), token);
        await stop.CancelAsync();
        await observing.WaitAsync(TimeSpan.FromSeconds(60), token);

        var export = new Exporter(store, RunnerLog.Null, "1.0.0").Export("0123456789abcdef0123456789abcdef", final: true, TimeSpan.FromSeconds(10));
        var document = Assert.Single(export.Documents);
        var view = new EvidenceView(System.Text.Encoding.UTF8.GetString(PartCodec.Gunzip(store.ReadDocument(document.DocumentId)!)));
        if (Environment.GetEnvironmentVariable("CONTOSOCARE_TEST_RCA_DUMP") is { Length: > 0 } dump)
        {
            // A real capture's document and its part lines, for the app's and the notebook's own checks.
            File.WriteAllText(Path.Combine(dump, "pg-local.evidence.json"), view.Json);
            File.WriteAllLines(Path.Combine(dump, "pg-local.parts.txt"), Enumerable.Range(1, document.Parts).Select(i => PartCodec.Line(document.DocumentId, store.ReadDocument(document.DocumentId)!, i)));
            File.WriteAllText(Path.Combine(dump, "pg-local.index.txt"), export.IndexLine() + Environment.NewLine);
        }

        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));

        // Blind: the detection tables name no scenario and no run.
        foreach (var text in view.Strings)
        {
            Assert.DoesNotContain(lockRun.RunId, text, StringComparison.Ordinal);
            Assert.DoesNotContain(lagRun.RunId, text, StringComparison.Ordinal);
            Assert.DoesNotContain("locking-blocking", text, StringComparison.Ordinal);
            Assert.DoesNotContain("replica-lag", text, StringComparison.Ordinal);
            Assert.DoesNotContain("ContosoCare.Demo/", text, StringComparison.Ordinal);
        }

        var lockToken = ApplicationNames.RunToken(lockRun.RunId);
        var lagToken = ApplicationNames.RunToken(lagRun.RunId);
        var coverage = view.Table("rca_coverage").ToDictionary(r => (string)r["target"]!);
        Assert.True(coverage["T4"]["captured"] is true, coverage["T4"].GetValueOrDefault("gaps") as string);
        Assert.True(coverage["T4-replica"]["captured"] is true, coverage["T4-replica"].GetValueOrDefault("gaps") as string);
        var episodes = view.Table("rca_events").Where(e => (string?)e["kind"] == "capture").ToList();
        Assert.Contains(episodes, e => (string?)e["target"] == "T4" && (string?)e["event_name"] == "escalated");
        Assert.Contains(episodes, e => (string?)e["target"] == "T4-replica" && (string?)e["event_name"] == "escalated");
        Assert.Contains(episodes, e => (string?)e["target"] == "T4-replica" && (string?)e["event_name"] == "relaxed");

        // T4: the clerks wait on the holder's transaction, and the head blocker is the injected run's session, idle in
        // transaction, holding locks on a care table.
        var t4 = view.Table("rca_sessions").Where(r => (string?)r["target"] == "T4").ToList();
        var waiting = t4.Where(r => r.GetValueOrDefault("blocked_by") is not null && (string?)r.GetValueOrDefault("wait_type") == "Lock:transactionid").ToList();
        Assert.NotEmpty(waiting);
        var blockers = waiting.Select(r => (string)r["blocked_by"]!).ToHashSet(StringComparer.Ordinal);
        var heads = t4.Where(r => r.GetValueOrDefault("blocked_by") is null && blockers.Contains(r["session_id"]!.ToString()!)).ToList();
        Assert.NotEmpty(heads);
        Assert.Contains(heads, h => (string?)h.GetValueOrDefault("status") == "idle in transaction" && (string?)h.GetValueOrDefault("run_token") == lockToken && (string?)h.GetValueOrDefault("program_name") == "ContosoCare.Demo" && (h.GetValueOrDefault("lock_object") as string ?? string.Empty).StartsWith("care.", StringComparison.Ordinal));
        Assert.All(waiting, w => Assert.Equal(lockToken, w.GetValueOrDefault("run_token")));
        Assert.Contains(view.Table("rca_resource"), r => (string?)r["target"] == "T4" && (string?)r["metric"] == "deadlocks" && (double)r["value"]! >= 1);

        // The replica: replay stood still behind the injected report's AccessShareLock, while the primary shipped normally.
        var replay = view.Table("rca_replica").Where(r => (string?)r["target"] == "T4-replica").ToList();
        Assert.Contains(replay, r => (double?)r.GetValueOrDefault("since_last_replayed_s") >= 30 && (double?)r.GetValueOrDefault("received_not_replayed_bytes") > 0);
        var conflicts = replay.Where(r => r.GetValueOrDefault("conflict_relation") is not null).ToList();
        Assert.NotEmpty(conflicts);
        Assert.All(conflicts, c =>
        {
            Assert.Equal("demo.replica_lag_marks", c["conflict_relation"]);
            Assert.Equal("AccessExclusiveLock", c["conflict_wanted_mode"]);
            Assert.Equal("AccessShareLock", c["conflict_holder_mode"]);
            Assert.Equal(lagToken, c["conflict_holder_run_token"]);
            Assert.Equal("ContosoCare.Demo", c["conflict_holder_program"]);
            Assert.NotNull(c.GetValueOrDefault("conflict_wait_start_utc"));
        });
        Assert.Contains(replay, r => r.GetValueOrDefault("max_standby_streaming_delay_s") is not null);
        var shipped = view.Table("rca_replica").Where(r => (string?)r["target"] == "T4" && (string?)r["side"] == "primary").ToList();
        Assert.NotEmpty(shipped);
        Assert.All(shipped, s => Assert.Equal("t4-replica", s["standby_name"]));

        // The answer key names both runs with the same tokens, in its own section.
        var key = view.AnswerKey().Where(r => (string?)r["kind"] == "run").ToList();
        Assert.Contains(key, r => (string?)r["scenario"] == "locking-blocking" && (string?)r["run_token"] == lockToken);
        Assert.Contains(key, r => (string?)r["scenario"] == "replica-lag" && (string?)r["run_token"] == lagToken);
    }

    /// <summary>
    /// Against a disposable SQL Server (CONTOSOCARE_TEST_SQL_SERVER, Windows authentication, as SqlIntegrationTests):
    /// a blocking chain with its lock escalations and lock timeouts, and a deadlock storm, captured blind as T2. The event
    /// session exists only while the observer does. CI doesn't set it.
    /// </summary>
    [Fact]
    public async Task OnSqlServerTheBlindCaptureFindsTheChainItsErrorsAndTheDeadlocks()
    {
        await SqlIntegrationTests.PrepareAsync();
        var token = TestContext.Current.CancellationToken;
        var endpoint = SqlIntegrationTests.Endpoint;
        var options = new ObserverOptions { Sentinel = TimeSpan.FromSeconds(5), BlockingDetail = TimeSpan.FromSeconds(2), QuietFor = TimeSpan.FromSeconds(10), ErrorQuietFor = TimeSpan.FromSeconds(30), EventLatency = TimeSpan.FromSeconds(6), SlowSample = TimeSpan.FromSeconds(5) };
        var store = new EvidenceStore(root, TimeProvider.System, host: "arcsql01");
        var gate = new Gate(DemoTarget.T2);
        var lane = new ObserverLane([new SqlTargetObserver("T2", DemoTarget.T2, new SqlCaptureConnector(endpoint, RunnerLog.Null), options, RunnerLog.Null)], [], gate, store, RunnerLog.Null, TimeProvider.System, options);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        var observing = Task.Run(() => lane.RunAsync(stop.Token), CancellationToken.None);
        await Task.Delay(TimeSpan.FromSeconds(8), token);
        Assert.True(await EventSessionExistsAsync(endpoint, token), "The observer didn't create ContosoCare_RCA.");

        var runner = new ScenarioRunner(new SqlConnectionOpener(endpoint, RunnerLog.Null), RunnerLog.Null, TimeProvider.System);
        var chain = ScenarioCatalog.Default.Get("blocking-chain");
        var storm = ScenarioCatalog.Default.Get("deadlock-storm");
        var results = await Task.WhenAll(
            runner.RunAsync(RunBounds.Plan(chain, new RunRequest { ScenarioId = chain.Id, Target = DemoTarget.T2, Duration = TimeSpan.FromSeconds(90), Concurrency = 2, Parameters = new Dictionary<string, string>(StringComparer.Ordinal) { ["depth"] = "3", ["holdSeconds"] = "70", ["pauseSeconds"] = "0", ["escalationEverySeconds"] = "30", ["escalationHoldSeconds"] = "5", ["normalWorkers"] = "0" } }, DateTimeOffset.UtcNow), token),
            runner.RunAsync(RunBounds.Plan(storm, new RunRequest { ScenarioId = storm.Id, Target = DemoTarget.T2, Duration = TimeSpan.FromSeconds(40), Concurrency = 1, Parameters = new Dictionary<string, string>(StringComparer.Ordinal) { ["maxRounds"] = "3" } }, DateTimeOffset.UtcNow), token));
        var (chainRun, stormRun) = (results[0], results[1]);
        Assert.True(chainRun.Status == "Completed", chainRun.Outcome);
        Assert.True(stormRun.Status == "Completed", stormRun.Outcome);

        await Task.Delay(TimeSpan.FromSeconds(12), token);
        gate.Active = false;
        await Task.Delay(TimeSpan.FromSeconds(5), token);
        await stop.CancelAsync();
        await observing.WaitAsync(TimeSpan.FromSeconds(60), token);
        Assert.False(await EventSessionExistsAsync(endpoint, token), "The observer left ContosoCare_RCA behind.");

        var export = new Exporter(store, RunnerLog.Null, "1.0.0").Export(null, final: true, TimeSpan.FromSeconds(10));
        var document = Assert.Single(export.Documents);
        var view = new EvidenceView(System.Text.Encoding.UTF8.GetString(PartCodec.Gunzip(store.ReadDocument(document.DocumentId)!)));
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        foreach (var text in view.Strings)
        {
            Assert.DoesNotContain(chainRun.RunId, text, StringComparison.Ordinal);
            Assert.DoesNotContain(stormRun.RunId, text, StringComparison.Ordinal);
            Assert.DoesNotContain("blocking-chain", text, StringComparison.Ordinal);
            Assert.DoesNotContain("deadlock-storm", text, StringComparison.Ordinal);
        }

        var chainToken = ApplicationNames.RunToken(chainRun.RunId);
        var stormToken = ApplicationNames.RunToken(stormRun.RunId);
        var sessions = view.Table("rca_sessions");
        var waiting = sessions.Where(r => r.GetValueOrDefault("blocked_by") is not null && (string?)r.GetValueOrDefault("run_token") == chainToken).ToList();
        Assert.NotEmpty(waiting);
        var blockers = waiting.Select(r => (string)r["blocked_by"]!).ToHashSet(StringComparer.Ordinal);
        Assert.Contains(sessions, h => h.GetValueOrDefault("blocked_by") is null && blockers.Contains(h["session_id"]!.ToString()!) && (string?)h.GetValueOrDefault("run_token") == chainToken && h.GetValueOrDefault("module_name") is string && h.GetValueOrDefault("login_name") is string);
        Assert.Contains(waiting, w => ((string?)w.GetValueOrDefault("wait_type") ?? string.Empty).StartsWith("LCK_M_", StringComparison.Ordinal) && w.GetValueOrDefault("statement_text") is string);

        var events = view.Table("rca_events");
        Assert.Contains(events, e => (string?)e["kind"] == "capture" && (string?)e["event_name"] == "escalated");
        Assert.Contains(events, e => (string?)e["kind"] == "escalation" && (string?)e.GetValueOrDefault("run_token") == chainToken && (string?)e.GetValueOrDefault("object_name") == "[care].[appointments]");
        Assert.Contains(events, e => (string?)e["kind"] == "error" && (string?)e.GetValueOrDefault("code") == "1222" && (string?)e.GetValueOrDefault("run_token") == chainToken);
        var deadlocks = events.Where(e => (string?)e["kind"] == "deadlock").ToList();
        Assert.NotEmpty(deadlocks);
        Assert.Contains(deadlocks, d => (string?)d.GetValueOrDefault("run_token") == stormToken);
        Assert.Contains(events, e => (string?)e["kind"] == "error" && (string?)e.GetValueOrDefault("code") == "1205");
        Assert.True(view.Table("rca_coverage").Single()["captured"] is true, view.Table("rca_coverage").Single().GetValueOrDefault("gaps") as string);
    }

    private static async Task<bool> EventSessionExistsAsync(TargetEndpoint endpoint, CancellationToken token)
    {
        await using var connection = await new SqlConnectionOpener(endpoint, RunnerLog.Null).OpenAsync(SessionNames.ForControl("test"), token);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM sys.server_event_sessions WHERE name = N'ContosoCare_RCA';";
        return Convert.ToInt32(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) > 0;
    }

    private sealed class Gate(DemoTarget target = DemoTarget.T4) : IObservationGate
    {
        private volatile bool active = true;

        public bool Active
        {
            get => active;
            set => active = value;
        }

        public bool IsActive(DemoTarget asked) => asked == target && active;
    }
}
