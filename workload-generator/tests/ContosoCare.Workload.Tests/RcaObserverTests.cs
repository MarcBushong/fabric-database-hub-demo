using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using Xunit;
using static ContosoCare.Workload.Tests.RcaSimulation;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The RCA observer on simulated targets (RcaSimulation): what it runs, when, and the rows it builds from what the
/// catalog's blocks return. No database: the blocks answer from a script, as T1's and T4's DMVs would.
/// </summary>
public sealed class RcaObserverTests
{
    [Fact]
    public async Task OnT1ItRunsOnlyTheCatalogsBlocksAndCreatesAndDropsItsEventSession()
    {
        var clock = new ManualTime(T1From);
        var connector = RcaSimulation.T1(clock);
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1To, TestContext.Current.CancellationToken);

        foreach (var (block, text, _) in connector.Calls)
        {
            Assert.Equal(CaptureCatalog.Get(block), text);
        }

        Assert.Equal(["RCA-XE-05", "RCA-XE-00", "RCA-XE-01"], connector.Calls.Take(3).Select(c => c.BlockId));
        Assert.Equal("RCA-XE-05", connector.Calls[^1].BlockId);
        Assert.Contains(sink.Notes, n => n.Kind == NoteKind.Source && n.Text == "RCA-XE-01");
        Assert.DoesNotContain(connector.Calls, c => c.BlockId is "RCA-SQL-12" or "RCA-AZ-01" or "RCA-XE-03" or "RCA-XE-04");
    }

    [Fact]
    public async Task TheSentinelRunsEvery30SecondsAndBlockingDetailEvery10DuringItsEpisode()
    {
        var clock = new ManualTime(T1From);
        var connector = RcaSimulation.T1(clock);
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1To, TestContext.Current.CancellationToken);

        var sentinel = sink.Table("rca_resource").Where(r => r.Sentinel).Select(r => r.At).Distinct().Order().ToList();
        Assert.Equal(30, sentinel.Count);
        Assert.All(sentinel.Zip(sentinel.Skip(1)), pair => Assert.Equal(TimeSpan.FromSeconds(30), pair.Second - pair.First));

        var escalated = Assert.Single(sink.Events("capture"), r => (string?)r.Get("event_name") == "escalated");
        Assert.Equal(At(16, 52, 30), escalated.At);
        Assert.Equal("T1-20261120T165230Z", escalated.Get("code"));
        Assert.Equal("processes_blocked 7 >= 1: blocking detail (RCA-SQL-01, RCA-SQL-02) every 10 s.", escalated.Get("detail"));
        var relaxed = Assert.Single(sink.Events("capture"), r => (string?)r.Get("event_name") == "relaxed");
        Assert.Equal(At(17, 1, 40), relaxed.At);
        Assert.Equal("processes_blocked 0 for 60 s: back to the 30-s sentinel.", relaxed.Get("detail"));

        // Detail only inside the episode, every 10 s: 42 samples found a chain.
        var detail = connector.Calls.Count(c => c.BlockId == "RCA-SQL-01");
        Assert.Equal(56, detail);
        var samples = sink.Table("rca_sessions").Where(r => r.Get("blocked_by") is not null && (string?)r.Get("lock_mode_wanted") == "U").Select(r => r.At).Distinct().ToList();
        Assert.Equal(42, samples.Count);
        Assert.Equal(At(16, 52, 30), samples.Min());
        Assert.Equal(At(17, 0, 40), samples.Max());
    }

    [Fact]
    public async Task TheHeadBlockerRowNamesItsLockItsLastCallAndWhoRanIt()
    {
        var clock = new ManualTime(T1From);
        var sink = new MemorySink();

        await DriveAsync([T1Observer(RcaSimulation.T1(clock))], sink, clock, T1From, T1To, TestContext.Current.CancellationToken);

        var first = sink.Table("rca_sessions").Where(r => r.At == At(16, 52, 30)).ToDictionary(r => (long)r.Get("session_id")!);
        var head = first[63];
        Assert.Null(head.Get("blocked_by"));
        Assert.Equal("sleeping", head.Get("status"));
        Assert.Equal("KEY", head.Get("lock_resource_type"));
        Assert.Equal("[care].[work_queues]", head.Get("lock_object"));
        Assert.Equal("pk_work_queues", head.Get("lock_index"));
        Assert.Equal("X", head.Get("lock_mode_held"));
        Assert.Null(head.Get("lock_mode_wanted"));
        Assert.Equal(1, head.Get("open_transactions"));
        Assert.Equal("demo.usp_scenario_chain_acquire;1", head.Get("input_buffer"));
        Assert.Equal("[demo].[usp_scenario_chain_acquire]", head.Get("module_name"));
        Assert.Equal("NT AUTHORITY\\SYSTEM", head.Get("login_name"));
        Assert.Equal("SQLVM01", head.Get("host_name"));
        Assert.Equal("ContosoCare.Demo", head.Get("program_name"));
        Assert.Equal("de845fccbaba", head.Get("run_token"));
        Assert.Equal(true, head.Get("is_demo"));

        var link = first[64];
        Assert.Equal("63", link.Get("blocked_by"));
        Assert.Equal("LCK_M_U", link.Get("wait_type"));
        Assert.Equal("U", link.Get("lock_mode_wanted"));
        Assert.Equal("X", link.Get("lock_mode_held"));
        Assert.Equal("UPDATE care.work_queues SET priority = CASE WHEN priority >= ? THEN ? ELSE priority + ? END WHERE work_item_id = @parent", link.Get("statement_text"));

        Assert.Equal("[care].[appointments]", first[71].Get("lock_object"));
        Assert.Equal("X", first[71].Get("lock_mode_held"));
        Assert.Equal("71", first[74].Get("blocked_by"));
        Assert.Equal("IS", first[74].Get("lock_mode_wanted"));
        Assert.Equal("OBJECT: 5:1205579333:0", first[74].Get("wait_resource"));
        Assert.Equal(ApplicationNames.RunToken("20261120160000-t1-0f0e0d"), first[74].Get("run_token"));
    }

    [Fact]
    public async Task EventsKeepTheirModuleAndCodeAndLeaveOutTheObserversOwn()
    {
        var clock = new ManualTime(T1From);
        var sink = new MemorySink();

        await DriveAsync([T1Observer(RcaSimulation.T1(clock))], sink, clock, T1From, T1To, TestContext.Current.CancellationToken);

        var escalations = sink.Events("escalation");
        Assert.Equal(Escalations, escalations.Select(e => e.At));
        Assert.All(escalations, e =>
        {
            Assert.Equal("[care].[appointments]", e.Get("object_name"));
            Assert.Equal("X", e.Get("lock_mode"));
            Assert.Equal(71L, e.Get("session_id"));
            Assert.Equal("[demo].[usp_scenario_chain_escalate]", e.Get("module_name"));
            Assert.Equal("Lock threshold: 6,248 locks escalated to an X lock on the table.", e.Get("detail"));
        });

        var errors = sink.Events("error");
        Assert.Equal(30, errors.Count);
        Assert.All(errors, e =>
        {
            Assert.Equal("1222", e.Get("code"));
            Assert.Equal(16, e.Get("severity"));
            Assert.Equal(true, e.Get("intercepted"));
            Assert.Equal("[demo].[usp_scenario_chain_link]", e.Get("module_name"));
            Assert.Equal("Lock request time out period exceeded.", e.Get("detail"));
            Assert.Equal("ContosoCare.Demo", e.Get("program_name"));
        });

        // The lock timeouts' counter agrees: its deltas add up to the 30 events.
        Assert.Equal(30, sink.Table("rca_resource").Where(r => (string?)r.Get("metric") == "lock_timeouts").Sum(r => (double)r.Get("value")!));
        Assert.DoesNotContain(sink.Table("rca_events"), r => r.At == At(16, 51, 0));
    }

    [Theory]
    [InlineData("T1")]
    [InlineData("T3")]
    public async Task InA90MinuteSessionEachEventIsWrittenOnceWhileTheRingBufferStillReturnsIt(string target)
    {
        // Review of 4e7817b (High): the observer forgot an event 20 minutes after it while the ring buffer, which keeps up
        // to 5,000 events, still returned it, and wrote it again at every sentinel after: at 45 minutes, T1's 30 lock
        // timeouts had become 1,113 rows and its 4 escalations 160. T3's database-scoped session (RCA-XE-04) too.
        var clock = new ManualTime(T1From);
        var t3 = target == "T3";
        IEnumerable<string> Deadlock(DateTimeOffset now) => now >= At(16, 55, 1) ? [DeadlockReport(At(16, 55, 0), t3 ? "database_xml_deadlock_report" : "xml_deadlock_report")] : [];
        var connector = t3 ? T1AsT3(clock, Deadlock) : RcaSimulation.T1(clock, Deadlock);
        var observer = new SqlTargetObserver(target, t3 ? DemoTarget.T3 : DemoTarget.T1, connector, Options(), RunnerLog.Null);
        var sink = new MemorySink();

        await DriveAsync([observer], sink, clock, T1From, T1From.AddMinutes(90), TestContext.Current.CancellationToken);

        Assert.Contains(connector.Calls, c => c.BlockId == (t3 ? "RCA-XE-04" : "RCA-XE-02") && c.Text == CaptureCatalog.Get(c.BlockId));
        Assert.Equal(TimeoutMinutes.SelectMany(m => Enumerable.Range(0, 6).Select(i => m.AddSeconds(5 + (i * 9)))), sink.Events("error").Select(e => e.At));
        Assert.Equal(Escalations, sink.Events("escalation").Select(e => e.At));
        Assert.Equal(At(16, 55, 0), Assert.Single(sink.Events("deadlock")).At);
    }

    [Fact]
    public async Task AnEventATruncatedReadLeftOutIsRememberedAndNeverWrittenAgain()
    {
        // A read of a ring buffer past 4 MB of XML leaves out what didn't fit, which the buffer may still hold (Learn:
        // ring_buffer target), here its oldest event: the observer remembers such an event for 20 minutes, and once it has
        // forgotten one, it never writes it again when a later read returns it.
        var clock = new ManualTime(T1From);
        var first = LockTimeout(T1From.AddSeconds(10), 64);
        var second = LockTimeout(T1From.AddSeconds(90), 65);
        var connector = RingBufferOnly(clock, now => now < T1From.AddMinutes(2) ? RingBuffer([first]) : now < T1From.AddMinutes(40) ? Truncated([second]) : RingBuffer([first, second]));
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(60), TestContext.Current.CancellationToken);

        Assert.Equal([T1From.AddSeconds(10), T1From.AddSeconds(90)], sink.Events("error").Select(e => e.At));

        // While reads stay truncated, each 10 minutes have their gap, so every export window that has them says so.
        Assert.Equal([At(16, 52, 0), At(17, 2, 0), At(17, 12, 0), At(17, 22, 0)], sink.Notes.Where(n => n.Kind == NoteKind.Gap && n.Text.Contains("4 MB of XML", StringComparison.Ordinal)).Select(n => n.At));
    }

    [Fact]
    public async Task ATruncatedReadThatCutsTheNewestEventsLosesNoneAndWritesNoneTwice()
    {
        // Which end a truncated read cuts isn't documented; here it's the newest. E2 is kept, then cut for more than 20
        // minutes, so it's forgotten while the buffer still holds it; E3 and E4 are cut from the start. Once a read is
        // complete again (E1 gone, oldest first), E2 isn't written again, and E3 and E4 are written once.
        var clock = new ManualTime(T1From);
        var e1 = LockTimeout(At(16, 50, 10), 64);
        var e2 = LockTimeout(At(16, 51, 30), 65);
        var e3 = LockTimeout(At(16, 58, 0), 66);
        var e4 = LockTimeout(At(17, 15, 0), 67);
        var connector = RingBufferOnly(clock, now =>
            now < At(16, 50, 11) ? RingBuffer([])
            : now < At(16, 51, 31) ? RingBuffer([e1])
            : now < At(16, 58, 1) ? RingBuffer([e1, e2])
            : now < At(17, 20, 0) ? Truncated([e1])
            : RingBuffer([e2, e3, e4]));
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(40), TestContext.Current.CancellationToken);

        Assert.Equal([(At(16, 50, 10), (long?)64), (At(16, 51, 30), (long?)65), (At(16, 58, 0), (long?)66), (At(17, 15, 0), (long?)67)], ErrorRows(sink));
    }

    [Fact]
    public async Task AnEventInTheMillisecondOfAForgottenOneIsStillWritten()
    {
        // Re-review of ce4a5e2: S and X in one millisecond. Truncated reads return only S for 25 minutes, then nothing, so S
        // is forgotten; then a complete read returns X. X was never seen, so it's new: S and X are each written once.
        var clock = new ManualTime(T1From);
        var s = LockTimeout(At(16, 50, 10), 64);
        var x = LockTimeout(At(16, 50, 10), 65);
        var connector = RingBufferOnly(clock, now =>
            now < At(16, 50, 11) ? RingBuffer([])
            : now < T1From.AddMinutes(25) ? Truncated([s])
            : now < T1From.AddMinutes(30) ? Truncated([])
            : RingBuffer([x]));
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(40), TestContext.Current.CancellationToken);

        Assert.Equal([(At(16, 50, 10), (long?)64), (At(16, 50, 10), (long?)65)], ErrorRows(sink));
    }

    [Fact]
    public async Task AnEventTheRingBufferStopsReturningIsForgottenAndTheEventsAfterItAreEachWrittenOnce()
    {
        // The main path (re-review of ce4a5e2): complete reads for 40 minutes while the ring buffer wraps. A complete read
        // that no longer returns an event means the buffer dropped it, oldest first, so it's forgotten: A at 5 minutes and
        // B at 12. C arrives at 6, and D, two sessions in one millisecond, at 11. Each is written once.
        var clock = new ManualTime(T1From);
        var events = new (DateTimeOffset At, int Session, DateTimeOffset Gone)[]
        {
            (At(16, 50, 5), 64, T1From.AddMinutes(5)),
            (At(16, 50, 15), 65, T1From.AddMinutes(12)),
            (At(16, 56, 0), 66, DateTimeOffset.MaxValue),
            (At(17, 1, 0, 250), 67, DateTimeOffset.MaxValue),
            (At(17, 1, 0, 250), 68, DateTimeOffset.MaxValue),
        };

        // An event is in the buffer from a second after it (its dispatch) until the buffer drops it.
        var connector = RingBufferOnly(clock, now => RingBuffer(events.Where(e => e.At.AddSeconds(1) <= now && now < e.Gone).Select(e => LockTimeout(e.At, e.Session))));
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(40), TestContext.Current.CancellationToken);

        Assert.Equal(events.Select(e => (e.At, (long?)e.Session)), ErrorRows(sink));
    }

    [Fact]
    public async Task AnotherSessionInAChainKeepsItsIdWaitsAndLocksOnly()
    {
        var clock = new ManualTime(T1From);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-SQL-09" => [Row(("captured_at_utc", clock.Now.UtcDateTime), ("counter_name", "Processes blocked"), ("instance_name", string.Empty), ("cntr_value", 1L))],
            "RCA-SQL-01" =>
            [
                Row(("captured_at_utc", clock.Now.UtcDateTime), ("session_id", 80), ("blocking_session_id", 0), ("session_status", "sleeping"), ("open_transaction_count", 1), ("idle_ms", 5000L), ("login_name", "CONTOSO\\dba"), ("host_name", "DBA-LAPTOP"), ("program_name", "Microsoft SQL Server Management Studio - Query"), ("module_name", "[care].[usp_report]"), ("input_buffer_type", "Language Event"), ("input_buffer", "BEGIN TRAN; UPDATE care.patients SET name = 'Someone' WHERE id = 7")),
                Row(("captured_at_utc", clock.Now.UtcDateTime), ("session_id", 81), ("blocking_session_id", 80), ("request_status", "suspended"), ("wait_type", "LCK_M_X"), ("wait_time_ms", 4000L), ("program_name", ChainApp), ("statement_text", "UPDATE care.patients SET name = @name WHERE id = @id")),
            ],
            _ => [],
        });
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddSeconds(15), TestContext.Current.CancellationToken);

        var others = sink.Table("rca_sessions").Where(r => (long)r.Get("session_id")! == 80).ToList();
        Assert.NotEmpty(others);
        foreach (var other in others)
        {
            Assert.Equal(false, other.Get("is_demo"));
            Assert.Equal("sleeping", other.Get("status"));
            foreach (var column in new[] { "login_name", "host_name", "program_name", "run_token", "module_name", "statement_text", "input_buffer" })
            {
                Assert.Null(other.Get(column));
            }
        }

        Assert.DoesNotContain(sink.Rows, r => r.Values.Values.OfType<string>().Any(v => v.Contains("Someone", StringComparison.Ordinal) || v.Contains("DBA-LAPTOP", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task APermissionRefusalIsAWarningWithItsFixAndIsntRetriedAtOnce()
    {
        var clock = new ManualTime(T1From);
        var connector = new ScriptedConnector((_, _) => []) { Failure = block => block == "RCA-SQL-09" ? new CaptureException(CaptureFailureKind.Permission, "SQL error 300: VIEW SERVER PERFORMANCE STATE permission was denied.") : null };
        var sink = new MemorySink();
        var observer = new SqlTargetObserver("T2", DemoTarget.T2, connector, Options(), RunnerLog.Null);

        await DriveAsync([observer], sink, clock, T1From, T1From.AddMinutes(5), TestContext.Current.CancellationToken);

        var warning = Assert.Single(sink.Notes, n => n.Kind == NoteKind.Warning);
        Assert.Contains("RCA-SQL-09 was refused a permission on T2", warning.Text, StringComparison.Ordinal);
        Assert.Contains("./scripts/deploy.ps1 rebuilds T2 from Arc Jumpstart's image", warning.Text, StringComparison.Ordinal);
        Assert.Single(connector.Calls, c => c.BlockId == "RCA-SQL-09");
    }

    [Fact]
    public async Task ThreeSlowSamplesInARowStopDetailCaptureWithAWarning()
    {
        var clock = new ManualTime(T1From);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-SQL-09" => [Row(("captured_at_utc", clock.Now.UtcDateTime), ("counter_name", "Processes blocked"), ("instance_name", string.Empty), ("cntr_value", 2L))],
            _ => [],
        }) { Delay = TimeSpan.FromMilliseconds(40) };
        var sink = new MemorySink();
        var observer = new SqlTargetObserver("T1", DemoTarget.T1, connector, Options() with { SlowSample = TimeSpan.FromMilliseconds(10) }, RunnerLog.Null);

        await DriveAsync([observer], sink, clock, T1From, T1From.AddMinutes(5), TestContext.Current.CancellationToken);

        var warning = Assert.Single(sink.Notes, n => n.Kind == NoteKind.Warning);
        Assert.Contains("stopped its detail capture", warning.Text, StringComparison.Ordinal);
        Assert.Contains(sink.Notes, n => n.Kind == NoteKind.Gap && n.Text.Contains("halved its cadence", StringComparison.Ordinal));

        // The sentinel goes on, every 120 s and then every 240 s; detail stopped after the third slow sample.
        var stoppedAt = warning.At;
        Assert.DoesNotContain(connector.Calls.Skip(connector.Calls.FindIndex(c => c.BlockId == "RCA-SQL-01") + 2), c => c.BlockId is "RCA-SQL-01" or "RCA-SQL-02");
        Assert.Equal([T1From, T1From.AddMinutes(2)], sink.Table("rca_resource").Select(r => r.At).Distinct().Order());
        Assert.Contains(sink.Table("rca_resource"), r => r.At > stoppedAt);
    }

    [Fact]
    public async Task OnT3ItUsesTheDatabaseScopedSessionAndKeepsEachResourceRowOnce()
    {
        var clock = new ManualTime(T1From);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-AZ-01" =>
            [
                .. Enumerable.Range(-140, 140 + ((int)(clock.Now - T1From).TotalSeconds / 15)).Select(i => Row(("end_time", T1From.AddSeconds(15 * i).UtcDateTime), ("avg_cpu_percent", 12.5m + i), ("avg_log_write_percent", 1.25m), ("avg_data_io_percent", 0.5m), ("max_worker_percent", 2m), ("max_session_percent", 1.1m))),
            ],
            "RCA-XE-04" => [Row(("target_data", RingBuffer([])))],
            _ => [],
        });
        var sink = new MemorySink();
        var observer = new SqlTargetObserver("T3", DemoTarget.T3, connector, Options() with { ResourceStats = TimeSpan.FromMinutes(10) }, RunnerLog.Null);

        await DriveAsync([observer], sink, clock, T1From, T1From.AddMinutes(25), TestContext.Current.CancellationToken);

        Assert.Contains(connector.Calls, c => c.BlockId == "RCA-XE-03");
        Assert.Contains(connector.Calls, c => c.BlockId == "RCA-XE-04");
        Assert.DoesNotContain(connector.Calls, c => c.BlockId is "RCA-XE-01" or "RCA-XE-02" or "RCA-SQL-12");
        var drops = connector.Calls.Where(c => c.BlockId == "RCA-XE-05").ToList();
        Assert.Equal(2, drops.Count);
        Assert.All(drops, d => Assert.Contains("ON DATABASE", d.Text, StringComparison.Ordinal));
        Assert.All(drops, d => Assert.DoesNotContain("ON SERVER", d.Text, StringComparison.Ordinal));

        // Every 15-second row from the observation's start to its last read, once, with no deadband.
        var cpu = sink.Table("rca_resource").Where(r => (string?)r.Get("metric") == "avg_cpu_percent").Select(r => r.At).ToList();
        Assert.Equal(cpu.Distinct().Count(), cpu.Count);
        Assert.Equal(99, cpu.Count);
        Assert.Equal(T1From.AddSeconds(15), cpu.Min());
        Assert.All(sink.Table("rca_resource").Where(r => (string?)r.Get("source") == "RCA-AZ-01"), r => Assert.Equal("percent", r.Get("unit")));
    }

    [Fact]
    public async Task ADeadlockGraphIsKeptOnlyWhenAProcessRanInContosoCare()
    {
        var clock = new ManualTime(T1From);
        static string Graph(string database, string app) =>
            "<deadlock><victim-list><victimProcess id=\"p2\"/></victim-list><process-list>" +
            $"<process id=\"p1\" spid=\"81\" lockMode=\"U\" waitresource=\"KEY: 5:72057594045071360 (aa11)\" clientapp=\"{app}\" hostname=\"SQLVM01\" loginname=\"NT AUTHORITY\\SYSTEM\" currentdb=\"5\" currentdbname=\"{database}\"><executionStack><frame procname=\"ContosoCare.demo.usp_transfer\" line=\"12\">UPDATE care.inventory SET qty = qty - 1 WHERE id = 42</frame></executionStack><inputbuf>Proc [Database Id = 5 Object Id = 1]</inputbuf></process>" +
            $"<process id=\"p2\" spid=\"82\" lockMode=\"U\" waitresource=\"KEY: 5:72057594045071360 (bb22)\" clientapp=\"SomeTool\" hostname=\"OTHERHOST\" loginname=\"someone\" currentdb=\"5\" currentdbname=\"{database}\"><executionStack><frame procname=\"adhoc\" line=\"1\">UPDATE care.inventory SET qty = 0 WHERE id = 43</frame></executionStack><inputbuf>UPDATE care.inventory SET qty = 0 WHERE id = 43</inputbuf></process>" +
            "</process-list><resource-list>" +
            "<keylock hobtid=\"1\" dbid=\"5\" objectname=\"ContosoCare.care.inventory\" indexname=\"pk_inventory\" mode=\"X\"><owner-list><owner id=\"p1\" mode=\"X\"/></owner-list><waiter-list><waiter id=\"p2\" mode=\"U\" requestType=\"wait\"/></waiter-list></keylock>" +
            "<keylock hobtid=\"1\" dbid=\"5\" objectname=\"ContosoCare.care.inventory\" indexname=\"pk_inventory\" mode=\"X\"><owner-list><owner id=\"p2\" mode=\"X\"/></owner-list><waiter-list><waiter id=\"p1\" mode=\"U\" requestType=\"wait\"/></waiter-list></keylock>" +
            "</resource-list></deadlock>";
        string Report(DateTimeOffset at, string database) => Event("xml_deadlock_report", at, [("xml_report", "__GRAPH__", null)], []).Replace("__GRAPH__", Graph(database, ChainApp), StringComparison.Ordinal);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-XE-00" => [Row(("event_name", "xml_deadlock_report"), ("column_name", "xml_report"))],
            "RCA-XE-02" => [Row(("target_data", RingBuffer(clock.Now >= T1From.AddSeconds(30) ? [Report(T1From.AddSeconds(20), "OtherDb"), Report(T1From.AddSeconds(25), "ContosoCare")] : [])))],
            _ => [],
        });
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(1), TestContext.Current.CancellationToken);

        var deadlock = Assert.Single(sink.Events("deadlock"));
        Assert.Equal(T1From.AddSeconds(25), deadlock.At);
        Assert.Equal(82L, deadlock.Get("session_id"));
        Assert.Null(deadlock.Get("program_name"));
        Assert.Equal("[care].[inventory]", deadlock.Get("object_name"));
        using var json = System.Text.Json.JsonDocument.Parse((string)deadlock.Get("deadlock_json")!);
        var root = json.RootElement;
        Assert.Equal(82, root.GetProperty("victim").GetInt64());
        var processes = root.GetProperty("processes").EnumerateArray().ToList();
        Assert.Equal("ContosoCare.Demo", processes[0].GetProperty("program").GetString());
        Assert.Equal("de845fccbaba", processes[0].GetProperty("runToken").GetString());
        Assert.Equal("[demo].[usp_transfer]", processes[0].GetProperty("module").GetString());
        Assert.Equal("UPDATE care.inventory SET qty = qty - ? WHERE id = ?", processes[0].GetProperty("statement").GetString());
        Assert.Equal("X", processes[0].GetProperty("holds").GetString());
        Assert.Equal("U", processes[0].GetProperty("wants").GetString());
        Assert.False(processes[1].TryGetProperty("statement", out _));
        Assert.False(processes[1].TryGetProperty("program", out _));
        var resource = root.GetProperty("resources")[0];
        Assert.Equal("KEY", resource.GetProperty("type").GetString());
        Assert.Equal("[care].[inventory]", resource.GetProperty("object").GetString());
        Assert.Equal(81, resource.GetProperty("holder").GetInt64());
        Assert.Equal(82, resource.GetProperty("waiter").GetInt64());
        Assert.True(((string)deadlock.Get("deadlock_json")!).Length <= ExtendedEvents.DeadlockJsonLength);
    }

    [Fact]
    public async Task ADeadlockCountThatRoseWithNoGraphReadsSystemHealthOnce()
    {
        var clock = new ManualTime(T1From);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-SQL-09" => [Row(("captured_at_utc", clock.Now.UtcDateTime), ("counter_name", "Number of Deadlocks/sec"), ("instance_name", "_Total"), ("cntr_value", clock.Now >= T1From.AddSeconds(60) ? 1L : 0L))],
            "RCA-XE-02" => [Row(("target_data", RingBuffer([])))],
            _ => [],
        });
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(3), TestContext.Current.CancellationToken);

        var read = Assert.Single(connector.Calls, c => c.BlockId == "RCA-SQL-12");
        Assert.Equal(CaptureCatalog.Get("RCA-SQL-12"), read.Text);
        Assert.Contains(sink.Notes, n => n.Kind == NoteKind.Gap && n.Text.Contains("neither its event session nor system_health had a graph", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AnErrorRateJumpStartsAnEpisodeWithOneBlockingSample()
    {
        var clock = new ManualTime(T1From);
        var burst = T1From.AddMinutes(4);
        IEnumerable<string> Errors(DateTimeOffset now) => Enumerable.Range(0, 12)
            .Select(i => burst.AddSeconds(i * 4))
            .Where(at => at.AddSeconds(1) <= now)
            .Select(at => Event("error_reported", at, [("error_number", "1205", null), ("severity", "13", null), ("is_intercepted", "false", null), ("message", "Transaction (Process ID 64) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.", null)], [("client_app_name", ChainApp), ("session_id", "64")]));
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-XE-02" => [Row(("target_data", RingBuffer(Errors(clock.Now))))],
            _ => [],
        });
        var sink = new MemorySink();

        await DriveAsync([T1Observer(connector)], sink, clock, T1From, T1From.AddMinutes(14), TestContext.Current.CancellationToken);

        var escalated = Assert.Single(sink.Events("capture"), r => (string?)r.Get("event_name") == "escalated");
        Assert.Equal(burst.AddMinutes(1), escalated.At);
        Assert.StartsWith("errors 12 in the minute from 16:54 UTC >= 10", (string)escalated.Get("detail")!, StringComparison.Ordinal);
        var relaxed = Assert.Single(sink.Events("capture"), r => (string?)r.Get("event_name") == "relaxed");
        Assert.Equal(burst.AddMinutes(6), relaxed.At);
        Assert.Single(connector.Calls, c => c.BlockId == "RCA-SQL-01");
        Assert.All(sink.Events("error"), e => Assert.Equal("Transaction (Process ID ?) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.", e.Get("detail")));
    }

    [Fact]
    public async Task OnT4ItCapturesTheChainUnderASessionIdleInTransaction()
    {
        var clock = new ManualTime(T4From);
        var primary = RcaSimulation.T4Primary(clock);
        var sink = new MemorySink();
        var link = new ReplicaLink();

        await DriveAsync([new PgPrimaryObserver(primary, Options(), RunnerLog.Null, link)], sink, clock, T4From, T4To, TestContext.Current.CancellationToken);

        foreach (var (block, text, _) in primary.Calls)
        {
            Assert.Equal(CaptureCatalog.Get(block), text);
        }

        var escalated = Assert.Single(sink.Events("capture"), r => (string?)r.Get("event_name") == "escalated");
        Assert.Equal("T4-20261120T170230Z", escalated.Get("code"));
        Assert.Equal("connections_waiting_lock 3 >= 1: blocking detail (RCA-PG-01, RCA-PG-02, RCA-PG-11) every 10 s.", escalated.Get("detail"));
        Assert.Equal(At(17, 12, 20), Assert.Single(sink.Events("capture"), r => (string?)r.Get("event_name") == "relaxed").At);

        var rows = sink.Table("rca_sessions");
        Assert.Equal(45, rows.Select(r => r.At).Distinct().Count());
        Assert.DoesNotContain(rows, r => (long)r.Get("session_id")! == 501);
        var head = rows.Where(r => (long)r.Get("session_id")! == 20432).ToList();
        Assert.All(head, r =>
        {
            Assert.Null(r.Get("blocked_by"));
            Assert.Equal("idle in transaction", r.Get("status"));
            Assert.Equal("Client:ClientRead", r.Get("wait_type"));
            Assert.Equal("transactionid", r.Get("lock_resource_type"));
            Assert.Equal("care.work_queues", r.Get("lock_object"));
            Assert.Equal("ExclusiveLock", r.Get("lock_mode_held"));
            Assert.Equal("demo.usp_scenario_locking_acquire", r.Get("module_name"));
            Assert.Equal("contosocare_runner", r.Get("login_name"));
            Assert.Equal("aefe56d6d1e0", r.Get("run_token"));
        });
        Assert.Equal(109_800L, head.Max(r => (long)r.Get("idle_ms")!));
        var waiters = rows.Where(r => (string?)r.Get("blocked_by") == "20432").ToList();
        Assert.Equal([9772L, 20584L, 35660L], waiters.Select(r => (long)r.Get("session_id")!).Distinct().Order());
        Assert.All(waiters, r => Assert.Equal("Lock:transactionid", r.Get("wait_type")));
        Assert.Equal(20_000L, waiters.Max(r => (long)r.Get("wait_ms")!));
        Assert.All(waiters, r => Assert.Equal("ShareLock", r.Get("lock_mode_wanted")));

        // The heads' tables (RCA-PG-11) take the head blockers' pids.
        Assert.All(primary.Calls.Where(c => c.BlockId == "RCA-PG-11"), c => Assert.Equal([20432], c.Parameter!));
    }

    [Fact]
    public async Task OnTheReplicaItCapturesTheReplayStallAndWhatReplayWaitsFor()
    {
        var clock = new ManualTime(T4From);
        var primary = RcaSimulation.T4Primary(clock);
        var replica = RcaSimulation.T4Replica(clock);
        var sink = new MemorySink();
        var link = new ReplicaLink();

        await DriveAsync([new PgPrimaryObserver(primary, Options(), RunnerLog.Null, link), new PgReplicaObserver(replica, Options(), RunnerLog.Null, link)], sink, clock, T4From, T4To, TestContext.Current.CancellationToken);

        var episode = sink.Events("capture").Where(r => ((string)r.Get("code")!).StartsWith("T4-replica-", StringComparison.Ordinal)).ToList();
        Assert.Equal("T4-replica-20261120T171200Z", episode[0].Get("code"));
        Assert.Equal(At(17, 12, 0), episode[0].At);
        Assert.Equal("since_last_replayed_s 45.4 >= 30 with 45,900 bytes received and not replayed: replay detail (RCA-PG-01, RCA-PG-02, RCA-PG-06, RCA-PG-07) every 5 s.", episode[0].Get("detail"));
        Assert.Equal(At(17, 14, 25), episode[1].At);
        Assert.Equal("relaxed", episode[1].Get("event_name"));

        var replay = sink.Table("rca_replica").Where(r => (string?)r.Get("side") == "replica").ToList();
        var peak = replay.MaxBy(r => (double?)r.Get("since_last_replayed_s"))!;
        Assert.Equal(At(17, 14, 10), peak.At);
        Assert.Equal(175.4, peak.Get("since_last_replayed_s"));
        Assert.Equal(178_500.0, peak.Get("received_not_replayed_bytes"));
        Assert.Equal("Lock:relation", peak.Get("startup_wait"));
        Assert.Equal("demo.replica_lag_marks", peak.Get("conflict_relation"));
        Assert.Equal("AccessExclusiveLock", peak.Get("conflict_wanted_mode"));
        Assert.Equal(StallFrom, peak.Get("conflict_wait_start_utc"));
        Assert.Equal(41872L, peak.Get("conflict_holder_session"));
        Assert.Equal("AccessShareLock", peak.Get("conflict_holder_mode"));
        Assert.Equal("ContosoCare.Demo", peak.Get("conflict_holder_program"));
        Assert.Equal("cb49b4c44561", peak.Get("conflict_holder_run_token"));
        Assert.Equal("SELECT r.marks_seen, r.last_mark FROM (SELECT count(*) AS marks_seen, max(m.marked_at) AS last_mark FROM demo.replica_lag_marks AS m) AS r CROSS JOIN pg_sleep(?) AS s", peak.Get("conflict_holder_statement"));
        Assert.Equal(0L, peak.Get("conflicts_cancelled"));
        Assert.Equal(600.0, peak.Get("max_standby_streaming_delay_s"));
        Assert.Equal(At(17, 14, 15), replay.Where(r => r.At > peak.At).OrderBy(r => r.At).First(r => (double)r.Get("since_last_replayed_s")! < 5).At);

        var startup = sink.Table("rca_sessions").Where(r => r.Target == "T4-replica" && (long)r.Get("session_id")! == 1180).ToList();
        Assert.NotEmpty(startup);
        Assert.All(startup, r =>
        {
            Assert.Equal("41872", r.Get("blocked_by"));
            Assert.Equal("startup", r.Get("backend_type"));
            Assert.Equal(false, r.Get("is_demo"));
            Assert.Null(r.Get("statement_text"));
        });

        // The primary shipped normally all along: write and flush lag near 0, about 1,020 bytes of WAL a second.
        var shipped = sink.Table("rca_replica").Where(r => (string?)r.Get("side") == "primary").ToList();
        Assert.All(shipped, r => Assert.Equal("t4-replica", r.Get("standby_name")));
        Assert.Equal(0.001, shipped.Max(r => (double)r.Get("write_lag_s")!));
        Assert.Equal(0.002, shipped.Max(r => (double)r.Get("flush_lag_s")!));
        Assert.All(shipped.Where(r => r.Get("wal_bytes_per_s") is not null), r => Assert.Equal(r.At > At(17, 10, 30) && r.At <= At(17, 14, 30) ? 1020.0 : 2400.0, (double)r.Get("wal_bytes_per_s")!, 1));
        Assert.Contains(primary.Calls, c => c.BlockId == "RCA-PG-05");
        Assert.Equal(CaptureCatalog.Get("RCA-PG-09"), Assert.Single(replica.Calls, c => c.BlockId == "RCA-PG-09").Text);
    }

    [Fact]
    public async Task APostgresDeadlockCountTakesOneBlockingSampleAndIsRecordedAsACount()
    {
        var clock = new ManualTime(T4From);
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-PG-03" => [Row(("captured_at", clock.Now.UtcDateTime), ("deadlocks", clock.Now >= T4From.AddSeconds(60) ? 2L : 0L), ("conflicts", 0L), ("xact_rollback", 0L), ("temp_files", 0L))],
            _ => [],
        });
        var sink = new MemorySink();

        await DriveAsync([new PgPrimaryObserver(connector, Options(), RunnerLog.Null, new ReplicaLink())], sink, clock, T4From, T4From.AddMinutes(2), TestContext.Current.CancellationToken);

        var deadlock = Assert.Single(sink.Events("deadlock"));
        Assert.Equal(2L, deadlock.Get("event_count"));
        Assert.Equal("pg_stat_database.deadlocks", deadlock.Get("event_name"));
        Assert.Null(deadlock.Get("deadlock_json"));
        Assert.Equal(2, sink.Events("capture").Count);
        Assert.Single(connector.Calls, c => c.BlockId == "RCA-PG-01");
    }

    [Fact]
    public async Task ConnectionsNearTheLimitStartConnectionDetailEvery10Seconds()
    {
        var clock = new ManualTime(T4From);
        var busy = (From: T4From.AddMinutes(1), To: T4From.AddMinutes(3));
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-PG-10" => [Row(("captured_at", clock.Now.UtcDateTime), ("max_connections", 50), ("reserved_connections", 3), ("client_connections", clock.Now >= busy.From && clock.Now < busy.To ? 45L : 10L), ("waiting_lock", 0L))],
            _ => [],
        });
        var sink = new MemorySink();

        await DriveAsync([new PgPrimaryObserver(connector, Options(), RunnerLog.Null, new ReplicaLink())], sink, clock, T4From, T4From.AddMinutes(6), TestContext.Current.CancellationToken);

        var capture = sink.Events("capture");
        Assert.Equal(busy.From, capture[0].At);
        Assert.Equal("client connections 45 >= 80 % of 47 (max_connections 50 minus 3 reserved): connection detail (RCA-PG-10) every 10 s.", capture[0].Get("detail"));

        // It ends 60 s after the last busy sample (17:02:50), and its samples are 10 s apart, none taken twice.
        Assert.Equal(busy.To.AddSeconds(50), capture[1].At);
        var samples = sink.Table("rca_resource").Where(r => (string?)r.Get("metric") == "connections_total" && r.At >= busy.From && r.At < busy.To).Select(r => r.At).ToList();
        Assert.Equal(12, samples.Count);
        Assert.Equal(samples.Count, samples.Distinct().Count());
    }

    /// <summary>
    /// RCA-PG-10's total counts the observer's own connection, which takes one of max_connections' slots like any other
    /// (verified on PostgreSQL 18: with the observer and 6 clients in 7 ordinary slots, the next client was refused, 53300).
    /// Its counts by state leave the observer out, whose session is always running this query (Final tests' live check of
    /// 4e2c65ed: "1 ran a query" in every sample).
    /// </summary>
    [Fact]
    public void TheConnectionCountsByStateLeaveOutTheObserverAndItsTotalKeepsIt()
    {
        var text = CaptureCatalog.Get("RCA-PG-10");
        string Count(string name) => Assert.Single(text.Split('\n'), line => line.TrimEnd().EndsWith($") AS {name},", StringComparison.Ordinal) || line.TrimEnd().EndsWith($") AS {name}", StringComparison.Ordinal));

        Assert.DoesNotContain("pg_backend_pid()", Count("client_connections"), StringComparison.Ordinal);
        foreach (var state in new[] { "active", "idle", "idle_in_transaction", "waiting_lock" })
        {
            Assert.Contains("a.pid <> pg_backend_pid()", Count(state), StringComparison.Ordinal);
            Assert.Contains("a.backend_type = 'client backend'", Count(state), StringComparison.Ordinal);
        }
    }

    /// <summary>A lock timeout (error 1222) of the chain's run, as the observer's event session reports it.</summary>
    private static string LockTimeout(DateTimeOffset at, int session) =>
        Event("error_reported", at, [("error_number", "1222", null), ("severity", "16", null), ("is_intercepted", "true", null), ("message", "Lock request time out period exceeded.", null)], [("client_app_name", ChainApp), ("session_id", session.ToString(CultureInfo.InvariantCulture))]);

    /// <summary>A read past 4 MB of XML: SQL Server sets truncated to 1 and leaves out what didn't fit.</summary>
    private static string Truncated(IEnumerable<string> events) => RingBuffer(events).Replace("truncated=\"0\"", "truncated=\"1\"", StringComparison.Ordinal);

    /// <summary>T1 with only its ring buffer scripted, by the simulated time; every other block returns nothing.</summary>
    private static ScriptedConnector RingBufferOnly(ManualTime clock, Func<DateTimeOffset, string> buffer) =>
        new((block, _) => block == "RCA-XE-02" ? [Row(("target_data", buffer(clock.Now)))] : []);

    /// <summary>The error rows the observer wrote, in order: their times and sessions.</summary>
    private static List<(DateTimeOffset At, long? Session)> ErrorRows(MemorySink sink) => [.. sink.Events("error").Select(e => (e.At, (long?)e.Get("session_id")))];
}
