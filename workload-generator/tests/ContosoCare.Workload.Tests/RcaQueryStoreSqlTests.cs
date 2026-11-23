using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// Query Store's reads on T1, T2, and T3 (rca/README.md, The sidecar and Query Store): the catalog's T-SQL, the plan
/// summary, the reader's cadence, steps, and bounds, and the observer's wiring, on simulated targets. No database: the
/// blocks answer from a script, T3's from the contract's own sidecar fixture, so the reader round-trips to it. Whatever
/// Query Store does, fails, or costs, the evidence document is as it would be without a sidecar sink.
/// </summary>
public sealed class RcaQueryStoreSqlTests
{
    private const string Marker = "/* dbhubdemo:rca-observer */";

    private static readonly string[] SourceOrder = ["RCA-SQL-10", "RCA-SQL-11", "RCA-SQL-14", "RCA-SQL-15", "RCA-AZ-03", "RCA-AZ-04"];

    // The reader's words where the aligned fixture (27c14daa) still has the first, hand-written ones: its plan summaries
    // for plans 31, 58, and 12, and the details of the recommendation's Executing and Verifying events. The contract's
    // author takes these into the fixture; then they change nothing here, and go.
    private static readonly Dictionary<long, string> ReaderSummaries = new()
    {
        [31] = "Index Seek on [care].[appointments].[ix_appointments_patient] seeking patient_id (71 % of the cost); Key Lookup on [care].[appointments].[pk_appointments] for status and duration_minutes (27 %); Nested Loops (Inner Join) (2 %).",
        [58] = "Clustered Index Scan on [care].[appointments].[pk_appointments] filtering on patient_id and status (88 % of the cost); Parallelism (Gather Streams) (12 %).",
        [12] = "Index Scan on [care].[patients].[ix_patients_facility] (62 % of the cost); Sort (TopN Sort) by last_name and first_name (35 %); Top (3 %).",
    };

    private static readonly Dictionary<string, string> ReaderDetails = new(StringComparer.Ordinal)
    {
        ["Executing"] = "FORCE_LAST_GOOD_PLAN for query 412: plan 31 over plan 58, CPU time per execution 2.1 ms against 176 ms; Executing, applied by System at 17:09:15 UTC.",
        ["Verifying"] = "FORCE_LAST_GOOD_PLAN for query 412: plan 31 over plan 58, CPU time per execution 2.1 ms against 176 ms; Verifying, applied by System at 17:09:15 UTC.",
    };

    [Theory]
    [InlineData("RCA-SQL-10", "@final,@since")]
    [InlineData("RCA-SQL-11", "@final,@plans,@since")]
    [InlineData("RCA-SQL-14", "@plans,@queries,@with_plan")]
    [InlineData("RCA-SQL-15", "")]
    [InlineData("RCA-AZ-03", "")]
    [InlineData("RCA-AZ-04", "")]
    public void EachBlockParsesMarksItsStatementAfterTheFirstKeywordAndTakesTheReadersParameters(string id, string parameters)
    {
        var text = CaptureCatalog.Get(id);
        var script = Parse(text);

        var statement = Assert.Single(script.Batches.SelectMany(b => b.Statements), s => !s.GetType().Name.Contains("Set", StringComparison.Ordinal));
        var first = script.ScriptTokenStream[statement.FirstTokenIndex];
        Assert.True(first.TokenType is TSqlTokenType.With or TSqlTokenType.Select, $"{id} starts with {first.Text}");
        var body = text.Substring(statement.StartOffset, statement.FragmentLength);
        Assert.StartsWith(Marker, body[first.Text.Length..].TrimStart(), StringComparison.Ordinal);

        var variables = new VariableVisitor();
        script.Accept(variables);
        Assert.Equal(parameters, string.Join(',', variables.Names.Order(StringComparer.Ordinal)));
    }

    [Theory]
    [InlineData("RCA-SQL-10", "kept")]
    [InlineData("RCA-SQL-14", null)]
    public void TheyLeaveOutOnlyTheObserversStatementsAndTheHarnessesModulesBeforeTheTopLists(string id, string? leavingOut)
    {
        var text = CaptureCatalog.Get(id);
        var select = Assert.Single(Parse(text).Batches.SelectMany(b => b.Statements).OfType<SelectStatement>());
        var ctes = select.WithCtesAndXmlNamespaces.CommonTableExpressions;

        // The harness: the modules the demo marks, by the extended property's name and value, read from that view alone.
        var harness = Assert.Single(ctes, c => c.ExpressionName.Value == "harness");
        var tables = new TableVisitor();
        harness.Accept(tables);
        Assert.Equal(["sys.extended_properties"], tables.Names);
        Assert.Contains("ep.name = N'dbhubdemo.role'", Fragment(text, harness), StringComparison.Ordinal);
        Assert.Contains("= N'harness'", Fragment(text, harness), StringComparison.Ordinal);

        // Exactly two rules leave something out: no schema, no other statement, and nothing the workload reports.
        var query = (QuerySpecification)(leavingOut is null ? select.QueryExpression : Assert.Single(ctes, c => c.ExpressionName.Value == leavingOut).QueryExpression);
        var rules = Conjuncts(query.WhereClause.SearchCondition);
        Assert.Equal(2, rules.Count);
        var notMarked = Assert.IsType<InPredicate>(rules[0]);
        Assert.True(notMarked.NotDefined);
        Assert.Equal("q.object_id", Fragment(text, notMarked.Expression));
        Assert.Contains("FROM harness AS h", Fragment(text, notMarked.Subquery), StringComparison.Ordinal);
        var notObserver = Assert.IsType<LikePredicate>(rules[1]);
        Assert.True(notObserver.NotDefined);
        Assert.Equal("%dbhubdemo:rca-observer%", Assert.IsType<StringLiteral>(notObserver.SecondExpression).Value);

        if (leavingOut is not null)
        {
            // The top lists rank what's left, each only among plans that used what it ranks, with ties to the lower plan_id.
            Assert.Equal(4, Fragment(text, query).Split("ROW_NUMBER()").Length - 1);
            Assert.Equal(4, Fragment(text, query).Split(", pl.plan_id)").Length - 1);
            foreach (var list in new[] { "(k.cpu_rank <= 10 AND k.cpu_ms > 0)", "(k.duration_rank <= 5 AND k.duration_ms > 0)", "(k.reads_rank <= 5 AND k.logical_reads > 0)", "(k.wait_rank <= 5 AND k.wait_ms > 0)" })
            {
                Assert.Contains(list, text, StringComparison.Ordinal);
            }
        }
    }

    [Fact]
    public void TheCatalogBoundsTheShowplanItReturnsAndNamesTheUnitsOfWhatItReads()
    {
        // RCA-SQL-14 returns a showplan only up to what the observer reduces, and says the size of one past it.
        var plans = CaptureCatalog.Get("RCA-SQL-14");
        Assert.Contains(string.Create(CultureInfo.InvariantCulture, $"AND DATALENGTH(p.query_plan) <= {PlanSummary.MaximumXmlBytes} THEN p.query_plan END"), plans, StringComparison.Ordinal);
        Assert.Contains("query_plan_bytes   = CASE WHEN p.plan_id IN (SELECT TRY_CAST(v.value AS bigint) FROM STRING_SPLIT(@with_plan, N',') AS v) THEN DATALENGTH(p.query_plan) END", plans, StringComparison.Ordinal);
        Assert.Equal(PlanSummary.MaximumXmlLength * 2L, PlanSummary.MaximumXmlBytes);

        // RCA-AZ-04's CPU averages are microseconds, as Learn's details have them; nothing it reads isn't in Learn's schema.
        var recommendations = CaptureCatalog.Get("RCA-AZ-04");
        Assert.Contains("regressed_plan_cpu_us", recommendations, StringComparison.Ordinal);
        Assert.Contains("recommended_plan_cpu_us", recommendations, StringComparison.Ordinal);
        Assert.DoesNotContain("_cpu_ms", recommendations, StringComparison.Ordinal);
        Assert.DoesNotContain("estimatedGain", recommendations, StringComparison.Ordinal);
    }

    [Fact]
    public async Task T3sPlanRegressionRoundTripsToTheContractsSidecarFixture()
    {
        var clock = new ManualTime(T3QueryStore.From);
        var store = new T3QueryStore(clock);
        var connector = store.Connector();
        var sidecar = new MemorySidecarSink();
        var evidence = new MemorySink();
        var observer = new SqlTargetObserver("T3", DemoTarget.T3, connector, RcaSimulation.Options(), RunnerLog.Null, sidecar, T3QueryStore.Options);

        await RcaSimulation.DriveAsync([observer], evidence, clock, T3QueryStore.From, T3QueryStore.To, TestContext.Current.CancellationToken);

        AssertContractTypes(sidecar.Rows);
        Assert.DoesNotContain(evidence.Rows, r => RcaContract.Table(r.Table).IsSidecar);
        var fixture = store.Fixture;

        // Every table, row by row and column by column; the coverage as the sidecar's export makes it one row.
        foreach (var table in new[] { RcaContract.QueryStats, RcaContract.QueryWaits, RcaContract.QueryPlans, RcaContract.QueryEvents })
        {
            Assert.Equal(Canonical(WithReaderWords(table, fixture.Table(table))), Canonical(sidecar.Table(table)));
        }

        Assert.Equal(Canonical(fixture.Table(RcaContract.QueryCoverage)), Canonical([Coalesce(sidecar.Table(RcaContract.QueryCoverage))]));

        // Each showplan is read once; plan 40's is query 902's, another application's read.
        var withPlan = connector.ParameterCalls.Where(c => c.BlockId == "RCA-SQL-14").Select(c => (string)c.Parameters.Value("@with_plan")!).ToList();
        Assert.Equal(["12,31", string.Empty, "40,58", string.Empty], withPlan);
        Assert.Equal("Table-valued function (91 % of the cost); Filter (9 %).", sidecar.Table(RcaContract.QueryPlans).Single(p => (long)p.Get("plan_id")! == 40).Get("plan_summary"));

        // Its reads: the state every 60 s and the tuning every 30 s from the start, the intervals at 16:50, 17:02, and 17:17, then the final read.
        var reads = connector.ParameterCalls.Where(c => c.BlockId == "RCA-SQL-10").Select(c => ((DateTimeOffset)c.Parameters.Value("@since")!, (bool)c.Parameters.Value("@final")!)).ToList();
        Assert.Equal([(RcaSimulation.At(16, 15, 0), false), (RcaSimulation.At(16, 45, 0), false), (RcaSimulation.At(17, 0, 0), false), (RcaSimulation.At(17, 15, 0), true)], reads);
        Assert.Equal(31, connector.ParameterCalls.Count(c => c.BlockId == "RCA-SQL-15"));
        Assert.Equal(61, connector.ParameterCalls.Count(c => c.BlockId == "RCA-AZ-04"));
    }

    [Fact]
    public void APlanSummaryNamesItsShapeAndKeepsNoValueItRanWith()
    {
        var shape = PlanSummary.Reduce(Showplans.WithWarnings(), out var problem);

        Assert.Null(problem);
        Assert.NotNull(shape);
        Assert.Equal(12.5, shape.EstimatedCost);
        Assert.False(shape.Parallel);
        Assert.Equal(
            "Table Scan on [care].[#visit_batch] filtering on note (73 % of the cost); Clustered Index Scan on [care].[appointments].[pk_appointments] filtering on patient_id (23 %); Hash Match (Inner Join) (4 %). " +
            "Warnings: no join predicate, an implicit conversion affecting the seek plan, a spill to tempdb at Hash Match (Inner Join). " +
            "Missing index (impact 87 %) on [care].[appointments] ([patient_id]) including ([status]), and 1 more.",
            shape.Summary);
        Assert.DoesNotContain(Showplans.CompiledValue, shape.Summary, StringComparison.Ordinal);
        Assert.DoesNotContain("CONVERT_IMPLICIT", shape.Summary, StringComparison.Ordinal);
        Assert.DoesNotContain("@first_patient", shape.Summary, StringComparison.Ordinal);
    }

    [Fact]
    public void APlanSummaryRefusesWhatItCantReadSafely()
    {
        const string Entity = "<!DOCTYPE ShowPlanXML [<!ENTITY x \"expanded\">]><ShowPlanXML xmlns=\"http://schemas.microsoft.com/sqlserver/2004/07/showplan\">&x;</ShowPlanXML>";

        Assert.Null(PlanSummary.Reduce(Entity, out var dtd));
        Assert.StartsWith("its showplan isn't XML the observer can read", dtd, StringComparison.Ordinal);
        Assert.Null(PlanSummary.Reduce("<ShowPlanXML xmlns=\"urn:other\"/>", out var other));
        Assert.Equal("its showplan isn't a ShowPlanXML document", other);
        Assert.Null(PlanSummary.Reduce(new string(' ', 8) + "<a/>" + new string(' ', PlanSummary.MaximumXmlLength), out var large));
        Assert.EndsWith("characters, more than the 8,388,608 the observer reduces", large, StringComparison.Ordinal);
        Assert.Null(PlanSummary.Reduce(null, out var none));
        Assert.Equal("Query Store returned no showplan for it", none);
    }

    [Fact]
    public async Task AShowplanQueryStoreHoldsBackForItsSizeIsAGapThatSaysItsSize()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var access = new FakeSidecarAccess("T1", (block, _) => block switch
        {
            "RCA-SQL-10" => [StatRow(RcaSimulation.At(16, 30, 0), 7, cpu: 50)],
            "RCA-SQL-14" => [Row(("captured_at_utc", start.UtcDateTime), ("query_id", 1007L), ("plan_id", 7L), ("query_plan", null), ("query_plan_bytes", 20_000_000L), ("is_parallel", false))],
            _ => [],
        });
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader(access, automaticTuning: false, sink);
        reader.Begin(start);

        await TickAsync(reader, start, TimeSpan.FromSeconds(5));
        await reader.EndAsync(start.AddMinutes(1), TestContext.Current.CancellationToken);

        var plan = Assert.Single(sink.Table(RcaContract.QueryPlans));
        Assert.Null(plan.Get("plan_summary"));
        Assert.Contains("Plan 7 on T1 has no summary: its showplan has 20,000,000 bytes, more than the 16,777,216 the observer reads.", Gaps(sink), StringComparison.Ordinal);
        Assert.Equal(["7", string.Empty], access.Calls.Where(c => c.BlockId == "RCA-SQL-14").Select(c => (string)c.Parameters.Value("@with_plan")!));
    }

    [Fact]
    public async Task AReadAtItsCapReadsOnFromTheLastWholeIntervalAndKeepsAnIntervalOverItWithAGap()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var intervals = new[] { (RcaSimulation.At(16, 0, 0), 3), (RcaSimulation.At(16, 15, 0), 3), (RcaSimulation.At(16, 30, 0), 2), (RcaSimulation.At(16, 45, 0), 5) };
        var clock = new ManualTime(start);
        var access = new FakeSidecarAccess("T1", (block, parameters) => block switch
        {
            "RCA-SQL-10" => [.. intervals
                .Where(i => i.Item1.AddMinutes(15) > (DateTimeOffset)parameters.Value("@since")! && i.Item1.AddMinutes(15) <= clock.Now)
                .SelectMany(i => Enumerable.Range(1, i.Item2).Select(n => StatRow(i.Item1, (i.Item1.Minute * 10) + n, cpu: 100 - n)))
                .Take(4)],
            "RCA-SQL-15" => [StateRow(clock.Now, "READ_WRITE", 0, null)],
            _ => [],
        });
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader(access, automaticTuning: false, sink, new SqlQueryStoreOptions { RowCap = 4, Schedule = new QueryStoreSchedule(TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(2), TimeSpan.FromHours(1)) });

        reader.Begin(start);
        await TickAsync(reader, start, TimeSpan.FromSeconds(10), clock);
        await TickAsync(reader, RcaSimulation.At(17, 2, 0), TimeSpan.FromSeconds(10), clock);

        Assert.Equal(
            [RcaSimulation.At(15, 50, 0), RcaSimulation.At(16, 15, 0), RcaSimulation.At(16, 30, 0), RcaSimulation.At(16, 45, 0), RcaSimulation.At(17, 0, 0)],
            access.Calls.Where(c => c.BlockId == "RCA-SQL-10").Select(c => (DateTimeOffset)c.Parameters.Value("@since")!));
        var stats = sink.Table(RcaContract.QueryStats);
        Assert.Equal(12, stats.Count);
        Assert.Equal(12, stats.Select(s => s.Get("plan_id")).Distinct().Count());
        Assert.Equal(4, stats.Count(s => (DateTimeOffset)s.Get("interval_start_utc")! == RcaSimulation.At(16, 45, 0)));
        var coverage = sink.Table(RcaContract.QueryCoverage);
        Assert.Equal((RcaSimulation.At(16, 0, 0), RcaSimulation.At(16, 45, 0)), ((DateTimeOffset)coverage[0].Get("read_from_utc")!, (DateTimeOffset)coverage[0].Get("read_to_utc")!));
        Assert.Null(coverage[0].Get("gaps"));
        Assert.Equal("17:02:00 UTC: Query Store's interval from 16:45 to 17:00 UTC on T1 had more than 4 rows in its top lists; the observer kept the 4 that used the most CPU.", coverage[1].Get("gaps"));
        Assert.Equal(RcaSimulation.At(17, 0, 0), reader.Since);
    }

    [Fact]
    public async Task AFailedReadKeepsItsIntervalsForARetryTwoMinutesLater()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var failing = true;
        var access = new FakeSidecarAccess("T2", (block, parameters) =>
        {
            if (block == "RCA-SQL-10" && failing)
            {
                failing = false;
                return null;
            }

            return block == "RCA-SQL-15" ? [StateRow(start, "READ_WRITE", 0, null)] : [];
        });
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader(access, automaticTuning: false, sink);

        reader.Begin(start);
        for (var now = start; now <= start.AddMinutes(2); now = now.AddSeconds(1))
        {
            await reader.TickAsync(now, reader.Timestamp(), now.AddSeconds(30), TestContext.Current.CancellationToken);
        }

        Assert.Equal([(start, start.AddHours(-2)), (start.AddMinutes(2), start.AddHours(-2))], access.Calls.Where(c => c.BlockId == "RCA-SQL-10").Select(c => (c.At, (DateTimeOffset)c.Parameters.Value("@since")!)));
        Assert.Contains("Query Store's statistics (RCA-SQL-10) weren't read on T2: SQL error 50000: a test's failure. The next read takes the intervals that ended after 14:50 UTC.", Gaps(sink), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStateOtherThanReadWriteAndAnUnforcedPlanAreEventsAndTheStateIsAGapInWords()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var sink = new MemorySidecarSink();
        var reads = 0;
        var access = new FakeSidecarAccess("T1", (block, _) => block == "RCA-SQL-15"
            ? (reads++ == 0 ? [StateRow(start, "READ_WRITE", 0, "5:9:MANUAL")] : [StateRow(start.AddSeconds(60), "READ_ONLY", 65536, null)])
            : []);
        var reader = new SqlQueryStoreReader(access, automaticTuning: false, sink);

        reader.Begin(start);
        await reader.TickAsync(start, reader.Timestamp(), start.AddSeconds(30), TestContext.Current.CancellationToken);
        await reader.TickAsync(start.AddSeconds(60), reader.Timestamp(), start.AddSeconds(90), TestContext.Current.CancellationToken);
        await reader.EndAsync(start.AddSeconds(90), TestContext.Current.CancellationToken);

        var events = sink.Table(RcaContract.QueryEvents);
        Assert.Equal(
            ["state READ_ONLY READ_WRITE  Query Store went from READ_WRITE to READ_ONLY: Query Store reached its size limit (max_storage_size_mb).", "unforced not forced forced 9 Plan 9 of query 5 no longer forced; it was forced by hand (sys.sp_query_store_force_plan)."],
            events.Select(e => $"{e.Get("kind")} {e.Get("state")} {e.Get("previous_state")} {e.Get("plan_id")} {e.Get("detail")}"));
        Assert.All(events, e => Assert.Equal((start.AddSeconds(60), start), ((DateTimeOffset)e.Get("event_time_utc")!, (DateTimeOffset)e.Get("time_from_utc")!)));
        var last = sink.Table(RcaContract.QueryCoverage)[^1];
        Assert.Equal("READ_ONLY", last.Get("state"));
        Assert.Contains("16:51:00 UTC: Query Store on T1 was READ_ONLY at 16:51:00 UTC: Query Store reached its size limit (max_storage_size_mb), 1,000 of 1,000 MB, so it recorded no new statistics while it stayed so.", Gaps(sink), StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheReadsFollowTheObserversSelfThrottling()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var access = new FakeSidecarAccess("T3", (block, _) => block == "RCA-SQL-15" ? [StateRow(start, "READ_WRITE", 0, null)] : []) { Factor = 2 };
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader(access, automaticTuning: true, sink);
        int Count(string block, DateTimeOffset from, DateTimeOffset to) => access.Calls.Count(c => c.BlockId == block && c.At >= from && c.At < to);

        // Slowed twice over: the state every 120 s and the tuning every 60 s, and no interval read starts.
        reader.Begin(start);
        await TickAsync(reader, start, TimeSpan.FromMinutes(10));
        Assert.Equal(5, Count("RCA-SQL-15", start, start.AddMinutes(10)));
        Assert.Equal(10, Count("RCA-AZ-04", start, start.AddMinutes(10)));
        Assert.Equal(0, Count("RCA-SQL-10", start, start.AddMinutes(10)));

        // Quick again: the next read takes the intervals that ended after the first read's since, as if none had waited.
        access.Factor = 1;
        await TickAsync(reader, start.AddMinutes(10), TimeSpan.FromMinutes(3));
        var resumed = access.Calls.First(c => c.BlockId == "RCA-SQL-10");
        Assert.Equal((start.AddMinutes(10), start.AddHours(-2), false), (resumed.At, (DateTimeOffset)resumed.Parameters.Value("@since")!, (bool)resumed.Parameters.Value("@final")!));
        Assert.Equal(3, Count("RCA-SQL-15", start.AddMinutes(10), start.AddMinutes(13)));

        // Detail capture stopped for good: no read starts but the end's, from where the reads stood.
        access.DetailStopped = true;
        await TickAsync(reader, start.AddMinutes(13), TimeSpan.FromMinutes(20));
        Assert.Equal(0, Count("RCA-SQL-10", start.AddMinutes(13), start.AddMinutes(33)));
        await reader.EndAsync(start.AddMinutes(33), TestContext.Current.CancellationToken);
        var final = access.Calls.Last(c => c.BlockId == "RCA-SQL-10");
        Assert.Equal((start.AddHours(-2), true), ((DateTimeOffset)final.Parameters.Value("@since")!, (bool)final.Parameters.Value("@final")!));
        Assert.Contains("Query Store's interval reads on T3 wait from 16:50:00 UTC: the observer's samples are slow (its cadence is 2 times longer)", Gaps(sink), StringComparison.Ordinal);
        Assert.Contains("Query Store's interval reads on T3 wait from 17:17:00 UTC: the observer stopped its detail capture for the rest of the session, so the end's read takes them.", Gaps(sink), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AReadRunsOnlyWhenItsTimeoutEndsBeforeTheEvidencesNextWork()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var access = new FakeSidecarAccess("T1", (block, _) => block == "RCA-SQL-15" ? [StateRow(start, "READ_WRITE", 0, null)] : []);
        var reader = new SqlQueryStoreReader(access, automaticTuning: false, new MemorySidecarSink());
        reader.Begin(start);

        // 10 s before the next detail sample: the state's read (5 s and 1 s to spare) fits, the interval read's (15 s) doesn't.
        var wake = await reader.TickAsync(start, reader.Timestamp(), start.AddSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal(["RCA-SQL-15"], access.Calls.Select(c => c.BlockId));
        Assert.Equal(start.AddSeconds(10), wake);

        // 30 s before the next sentinel: the interval read runs, one block a tick; then the next state read is the next work.
        wake = await reader.TickAsync(start.AddSeconds(10), reader.Timestamp(), start.AddSeconds(40), TestContext.Current.CancellationToken);
        Assert.Equal(["RCA-SQL-15", "RCA-SQL-10"], access.Calls.Select(c => c.BlockId));
        Assert.Equal([TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15)], access.Calls.Select(c => c.Timeout));
        Assert.Equal(start.AddMinutes(1), wake);
    }

    [Fact]
    public async Task TheEndsReadsStayWithinTheirBudget()
    {
        var start = RcaSimulation.At(17, 5, 0);
        var clock = new ManualTime(start);
        var access = new FakeSidecarAccess("T1", (block, _) => block switch
        {
            "RCA-SQL-15" => [StateRow(start, "READ_WRITE", 0, null)],
            "RCA-SQL-10" => [StatRow(RcaSimulation.At(17, 0, 0), 7, cpu: 50)],
            _ => [],
        }) { Clock = clock, Cost = _ => TimeSpan.FromSeconds(4) };
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader(access, automaticTuning: false, sink, new SqlQueryStoreOptions { Clock = new SteppedClock(clock) });
        reader.Begin(start.AddMinutes(-5));

        await reader.EndAsync(start, TestContext.Current.CancellationToken);

        // 10 s in all: the state (4 s of its 5), the statistics (4 s of the 6 left), the waits (cut at the 2 s left), and no plans.
        Assert.Equal([("RCA-SQL-15", 5), ("RCA-SQL-10", 6), ("RCA-SQL-11", 2)], access.Calls.Select(c => (c.BlockId, (int)c.Timeout.TotalSeconds)));
        Assert.Equal(start.AddSeconds(10), clock.Now);
        var coverage = Assert.Single(sink.Table(RcaContract.QueryCoverage));
        Assert.Contains("17:05:00 UTC: The end's Query Store reads on T1 stopped at their bound of 10 s, before the plans of the queries they read.", (string?)coverage.Get("gaps"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheQuietPathNeverOpensAConnectionAndKeepsItsFailuresOutOfTheEvidence()
    {
        var start = RcaSimulation.At(17, 0, 0);
        var connector = new ScriptedConnector((_, _) => []) { Failure = block => block == "RCA-SQL-15" ? new CaptureException(CaptureFailureKind.Permission, "SQL error 300: VIEW DATABASE PERFORMANCE STATE permission was denied.") : null };
        var sink = new MemorySink();
        var observer = new QuietProbe(connector);
        await observer.BeginAsync(sink, start, TestContext.Current.CancellationToken);

        // No open connection: the evidence capture connects, and the read waits for it.
        var none = await observer.Access.RunAsync("RCA-SQL-15", start, CaptureParameters.None, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal(CaptureFailureKind.Connection, none.Failure);
        Assert.Equal(0, connector.Opens);

        // A refusal carries the fix, and that block waits; neither is in the evidence.
        await observer.Evidence("RCA-SQL-09", start);
        var refused = await observer.Access.RunAsync("RCA-SQL-15", start, CaptureParameters.None, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal(CaptureFailureKind.Permission, refused.Failure);
        Assert.Equal("SQL error 300: VIEW DATABASE PERFORMANCE STATE permission was denied. The fix: a test's.", refused.Message);
        var again = await observer.Access.RunAsync("RCA-SQL-15", start.AddMinutes(1), CaptureParameters.None, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal("it was refused a permission on T1, so it's tried again at 17:10:00 UTC. The fix: a test's.", again.Message);
        Assert.Equal(1, connector.Calls.Count(c => c.BlockId == "RCA-SQL-15"));
        Assert.Equal(1, connector.Opens);
        Assert.Empty(sink.Notes);
    }

    [Fact]
    public async Task WithoutASidecarSinkNothingReadsQueryStoreAndWithOneTheEvidenceStaysTheSame()
    {
        var without = await RunT1Async(sidecar: null);
        var sidecar = new MemorySidecarSink();
        var with = await RunT1Async(sidecar);

        Assert.DoesNotContain(without.Connector.Calls, c => TimedConnector.QueryStoreBlocks.Contains(c.BlockId));
        Assert.Equal(without.Evidence, with.Evidence);
        Assert.Equal(without.Watermarks, with.Watermarks);

        // Query Store's first read follows the first tick's sentinel, and its last read follows the event session's drop.
        var calls = with.Connector.Calls.Select(c => c.BlockId).ToList();
        Assert.True(calls.IndexOf("RCA-SQL-09") < calls.IndexOf("RCA-SQL-15"));
        Assert.True(calls.LastIndexOf("RCA-XE-05") < calls.LastIndexOf("RCA-SQL-10"));
        Assert.Equal("RCA-SQL-10", calls[^1]);
        Assert.Equal([(RcaSimulation.T1From.AddHours(-2), false), (RcaSimulation.T1From.AddHours(-2), false), (RcaSimulation.T1From.AddHours(-2), true)], Reads(with.Connector));
        Assert.All(sidecar.Rows, r => Assert.Equal(RcaContract.QueryCoverage, r.Table));
        Assert.Equal(3, sidecar.Rows.Count);
    }

    [Theory]
    [InlineData("timeout")]
    [InlineData("refused")]
    [InlineData("error")]
    [InlineData("throws")]
    public async Task AQueryStoreBlockThatFailsLeavesTheEvidenceAsWithoutASinkAndTheWatermarkAdvances(string failure)
    {
        var without = await RunT1Async(sidecar: null);
        var sidecar = new MemorySidecarSink();
        var with = await RunT1Async(sidecar, connector => connector.Failure = _ => failure switch
        {
            "timeout" => new CaptureException(CaptureFailureKind.Timeout, "SQL error -2: Execution Timeout Expired."),
            "refused" => new CaptureException(CaptureFailureKind.Permission, "SQL error 300: VIEW DATABASE PERFORMANCE STATE permission was denied."),
            "error" => new CaptureException(CaptureFailureKind.Other, "SQL error 8115: Arithmetic overflow error."),
            _ => new InvalidOperationException("The connection threw (a test's failure)."),
        });

        Assert.Equal(without.Evidence, with.Evidence);
        Assert.Equal(without.Watermarks, with.Watermarks);
        Assert.True(with.Watermarks.Count > 25, $"The watermark advanced {with.Watermarks.Count} times.");
        Assert.Contains(with.Connector.Failures, f => f.BlockId == "RCA-SQL-15");
        Assert.Contains("Query Store's state (RCA-SQL-15) wasn't read on T1: ", Gaps(sidecar), StringComparison.Ordinal);
        Assert.DoesNotContain(with.Evidence, e => SourceOrder.Any(b => e.Contains(b, StringComparison.Ordinal)));
    }

    [Fact]
    public async Task AConnectionAQueryStoreReadFindsLostIsNotedByTheEvidenceAsItWouldHaveBeen()
    {
        var lost = RcaSimulation.At(16, 55, 0);
        var without = await RunT1Async(sidecar: null, connector => connector.BreakAt = lost);
        var with = await RunT1Async(new MemorySidecarSink(), connector => connector.BreakAt = lost);

        // Without a sink, the next detail sample finds the connection lost; with one, Query Store's state read did, first.
        Assert.Equal((RcaSimulation.At(16, 55, 10), "RCA-SQL-01"), without.Connector.Failures[0]);
        Assert.Equal((lost, "RCA-SQL-15"), with.Connector.Failures[0]);
        Assert.Equal(without.Evidence, with.Evidence);
        Assert.Equal(without.Watermarks, with.Watermarks);
        Assert.Equal((2, 2), (without.Connector.Opens, with.Connector.Opens));
        Assert.Contains(with.Evidence, e => e.Contains($"16:55:10|T1 didn't answer RCA-SQL-01: {TimedConnector.TransportError}", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AReadThatThrowsIsLoggedAndWaitsItsTurnWhileTheEvidenceGoesOn()
    {
        var without = await RunT1Async(sidecar: null);
        var sink = new ThrowingSidecarSink();
        var with = await RunT1Async(sink);

        Assert.Equal(without.Evidence, with.Evidence);
        Assert.Equal(without.Watermarks, with.Watermarks);

        // Each interval read threw writing its coverage row: tried again 2 minutes later, never at every tick.
        var reads = with.Connector.Calls.Where(c => c.BlockId == "RCA-SQL-10" && c.At < RcaSimulation.T1To).Select(c => c.At).ToList();
        Assert.True(reads.Count >= 3 && sink.Attempts >= reads.Count, $"{reads.Count} reads, {sink.Attempts} rows tried.");
        Assert.All(reads.Zip(reads.Skip(1)), pair => Assert.True(pair.Second - pair.First >= TimeSpan.FromMinutes(2), $"{pair.First:HH:mm:ss} then {pair.Second:HH:mm:ss}"));
    }

    [Theory]
    [InlineData(4, 12)]
    [InlineData(75, 75)]
    public async Task ASlowReadNeverPushesBackTheSentinelOrTheDetailSamples(int lightSeconds, int heavySeconds)
    {
        var without = await RunT1Async(sidecar: null);
        var sidecar = new MemorySidecarSink();
        var with = await RunT1Async(sidecar, connector =>
        {
            // Light reads cost up to their 5-s timeout, or past it; the interval read's blocks up to their 15 s, or well past the sentinel's 30.
            connector.Cost = block => TimeSpan.FromSeconds(block == "RCA-SQL-15" ? lightSeconds : heavySeconds);
            var query = connector.QueryStore;
            connector.QueryStore = (block, parameters) => block == "RCA-SQL-10" ? [StatRow(RcaSimulation.At(16, 30, 0), 7, cpu: 50)] : query(block, parameters);
        });

        Assert.Equal(without.Evidence, with.Evidence);
        Assert.Equal(without.Watermarks, with.Watermarks);

        // The clock moved with Query Store's blocks; no interval read ran while the blocking episode's detail came every 10 s.
        var blocks = with.Connector.Calls.Where(c => TimedConnector.QueryStoreBlocks.Contains(c.BlockId)).ToList();
        if (heavySeconds <= 15)
        {
            Assert.Contains(blocks, c => c.BlockId == "RCA-SQL-14");
        }
        else
        {
            Assert.Contains(with.Connector.Failures, f => f.BlockId == "RCA-SQL-10");
        }

        Assert.DoesNotContain(blocks, c => c.BlockId is "RCA-SQL-10" or "RCA-SQL-11" or "RCA-SQL-14" && c.At > RcaSimulation.At(16, 52, 30) && c.At < RcaSimulation.At(17, 1, 40));
        Assert.All(blocks.Where(c => c.At < RcaSimulation.T1To), c => Assert.Equal(c.BlockId == "RCA-SQL-15" ? TimeSpan.FromSeconds(5) : TimeSpan.FromSeconds(15), c.Timeout));
    }

    /// <summary>The 10 s before each tick's next evidence work: ticks the reader every second for <paramref name="span"/>.</summary>
    private static async Task TickAsync(SqlQueryStoreReader reader, DateTimeOffset from, TimeSpan span, ManualTime? clock = null)
    {
        for (var now = from; now < from + span; now = now.AddSeconds(1))
        {
            clock?.Set(now);
            await reader.TickAsync(now, reader.Timestamp(), now.AddSeconds(30), TestContext.Current.CancellationToken);
        }
    }

    /// <summary>
    /// T1's simulated session (RcaSimulation's blocking chain), 16:50 to 17:05, driven as the lane drives it, through a
    /// TimedConnector whose Query Store blocks the test sets up: the evidence (rows and notes), the watermark's values in
    /// order, and the connector.
    /// </summary>
    private static async Task<T1Run> RunT1Async(ISidecarSink? sidecar, Action<TimedConnector>? setUp = null)
    {
        var clock = new ManualTime(RcaSimulation.T1From);
        var connector = new TimedConnector(clock, RcaSimulation.T1(clock)) { QueryStore = (block, _) => block == "RCA-SQL-15" ? [StateRow(clock.Now, "READ_WRITE", 0, null)] : [] };
        setUp?.Invoke(connector);
        var span = new WatermarkLog(new MemorySink());
        var observer = new SqlTargetObserver("T1", DemoTarget.T1, connector, RcaSimulation.Options(), RunnerLog.Null, sidecar, new SqlQueryStoreOptions { Clock = new SteppedClock(clock) });

        await LaneDriver.RunAsync(observer, span, clock, RcaSimulation.T1From, RcaSimulation.T1To, TestContext.Current.CancellationToken);

        var evidence = span.Inner.Rows.Select(r => string.Join('|', new[] { r.Table, r.Target, Norm(r.At), r.Source, r.Sentinel ? "sentinel" : string.Empty }.Concat(r.Values.OrderBy(v => v.Key, StringComparer.Ordinal).Select(v => $"{v.Key}={Norm(v.Value)}"))))
            .Concat(span.Inner.Notes.Select(n => string.Create(CultureInfo.InvariantCulture, $"note|{n.Kind}|{n.Target}|{n.At:HH:mm:ss}|{n.Text}")))
            .ToList();
        var watermarks = span.Marks.Where((m, i) => i == 0 || m != span.Marks[i - 1]).ToList();
        return new T1Run(evidence, watermarks, connector);
    }

    private static List<(DateTimeOffset Since, bool Final)> Reads(TimedConnector connector) =>
        [.. connector.Calls.Where(c => c.BlockId == "RCA-SQL-10").Select(c => ((DateTimeOffset)c.Parameters!.Value("@since")!, (bool)c.Parameters!.Value("@final")!))];

    private static string Gaps(MemorySidecarSink sink) => string.Join('\n', sink.Table(RcaContract.QueryCoverage).Select(r => (string?)r.Get("gaps")).OfType<string>());

    private static CaptureValues StatRow(DateTimeOffset interval, long plan, double cpu) => Row(
        ("captured_at_utc", interval.AddMinutes(17).UtcDateTime),
        ("interval_start_utc", interval),
        ("interval_end_utc", interval.AddMinutes(15)),
        ("query_id", plan + 1000),
        ("plan_id", plan),
        ("query_sql_text", "SELECT 1"),
        ("executions", 10L),
        ("cpu_ms", cpu));

    private static CaptureValues StateRow(DateTimeOffset now, string state, int reason, string? forced) => Row(
        ("captured_at_utc", now.UtcDateTime),
        ("actual_state", state),
        ("desired_state", "READ_WRITE"),
        ("readonly_reason", reason),
        ("query_capture_mode", "AUTO"),
        ("interval_length_minutes", 15L),
        ("current_storage_size_mb", 1000L),
        ("max_storage_size_mb", 1000L),
        ("forced_plans", forced));

    /// <summary>The fixture's rows with the reader's words where the fixture still has its first ones (<see cref="ReaderSummaries"/>).</summary>
    private static List<Dictionary<string, object?>> WithReaderWords(string table, List<Dictionary<string, object?>> rows)
    {
        foreach (var row in rows)
        {
            if (table == RcaContract.QueryPlans && ReaderSummaries.TryGetValue((long)row["plan_id"]!, out var summary))
            {
                row["plan_summary"] = summary;
            }
            else if (table == RcaContract.QueryEvents && (string?)row["kind"] == "tuning" && ReaderDetails.TryGetValue((string)row["state"]!, out var detail))
            {
                row["detail"] = detail;
            }
        }

        return rows;
    }

    /// <summary>The coverage rows of a sidecar made one, as its export makes them (SqlQueryStoreReader's remarks).</summary>
    private static Dictionary<string, object?> Coalesce(List<CaptureRow> rows)
    {
        var latest = rows.Where(r => r.Get("state") is not null).MaxBy(r => (DateTimeOffset)r.Get("window_end_utc")!);
        var read = rows.Where(r => r.Get("read_from_utc") is not null).ToList();
        var sources = rows.SelectMany(r => ((string?)r.Get("sources") ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries)).Distinct().OrderBy(s => Array.IndexOf(SourceOrder, s)).ToList();
        var gaps = rows.Select(r => (string?)r.Get("gaps")).OfType<string>().ToList();
        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["target"] = rows[0].Get("target"),
            ["window_start_utc"] = rows.Min(r => (DateTimeOffset)r.Get("window_start_utc")!),
            ["window_end_utc"] = rows.Max(r => (DateTimeOffset)r.Get("window_end_utc")!),
            ["state"] = latest?.Get("state"),
            ["capture_mode"] = latest?.Get("capture_mode"),
            ["interval_minutes"] = latest?.Get("interval_minutes"),
            ["read_from_utc"] = read.Count == 0 ? null : read.Min(r => (DateTimeOffset)r.Get("read_from_utc")!),
            ["read_to_utc"] = read.Count == 0 ? null : read.Max(r => (DateTimeOffset)r.Get("read_to_utc")!),
            ["pending_from_utc"] = null,
            ["pending_to_utc"] = null,
            ["backfill"] = rows.Any(r => r.Get("backfill") is true),
            ["sources"] = sources.Count == 0 ? null : string.Join(',', sources),
            ["gaps"] = gaps.Count == 0 ? null : string.Join('\n', gaps),
        };
    }

    /// <summary>Every row's columns are its sidecar table's, with the contract's types, and its required columns hold values.</summary>
    private static void AssertContractTypes(IEnumerable<CaptureRow> rows)
    {
        foreach (var row in rows)
        {
            var table = RcaContract.Table(row.Table);
            Assert.True(table.IsSidecar, row.Table);
            foreach (var (name, value) in row.Values)
            {
                var column = table.Column(name);
                Assert.True(column is not null, $"{row.Table} has no column {name}.");
                Assert.True(value is null || column.Type switch
                {
                    "timestamp" => value is DateTimeOffset,
                    "long" => value is long,
                    "integer" => value is int,
                    "double" => value is double,
                    "string" => value is string,
                    "boolean" => value is bool,
                    _ => false,
                }, $"{row.Table}.{name} holds a {value?.GetType().Name} for a {column.Type}.");
            }

            foreach (var required in table.Columns.Where(c => c.Required))
            {
                Assert.True(row.Get(required.Name) is not null, $"{row.Table}.{required.Name} is required.");
            }
        }
    }

    private static List<string> Canonical(IEnumerable<CaptureRow> rows) =>
        Canonical(rows.Select(r => RcaContract.Table(r.Table).Columns.ToDictionary(c => c.Name, c => r.Get(c.Name), StringComparer.Ordinal)));

    private static List<string> Canonical(IEnumerable<Dictionary<string, object?>> rows) =>
        [.. rows.Select(r => string.Join('|', r.OrderBy(v => v.Key, StringComparer.Ordinal).Select(v => $"{v.Key}={Norm(v.Value)}"))).Order(StringComparer.Ordinal)];

    private static string Norm(object? value) => value switch
    {
        null => "null",
        DateTimeOffset time => time.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture),
        int number => number.ToString(CultureInfo.InvariantCulture),
        long number => number.ToString(CultureInfo.InvariantCulture),
        double number => Math.Round(number, 6).ToString("R", CultureInfo.InvariantCulture),
        bool flag => flag ? "true" : "false",
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? string.Empty,
    };

    private static TSqlScript Parse(string text)
    {
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = new StringReader(text);
        var script = (TSqlScript)parser.Parse(reader, out var errors);
        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors.Select(e => $"({e.Line},{e.Column}): {e.Message}")));
        return script;
    }

    private static string Fragment(string text, TSqlFragment fragment) => text.Substring(fragment.StartOffset, fragment.FragmentLength);

    private static List<BooleanExpression> Conjuncts(BooleanExpression expression) => expression switch
    {
        BooleanBinaryExpression { BinaryExpressionType: BooleanBinaryExpressionType.And } and => [.. Conjuncts(and.FirstExpression), .. Conjuncts(and.SecondExpression)],
        BooleanParenthesisExpression parenthesis => Conjuncts(parenthesis.Expression),
        _ => [expression],
    };

    /// <summary>One simulated session: its evidence, its watermark's values in order, and its connector.</summary>
    private sealed record T1Run(List<string> Evidence, List<DateTimeOffset> Watermarks, TimedConnector Connector);

    /// <summary>The variables a block uses: the parameters the reader binds.</summary>
    private sealed class VariableVisitor : TSqlFragmentVisitor
    {
        public HashSet<string> Names { get; } = new(StringComparer.OrdinalIgnoreCase);

        public override void Visit(VariableReference node) => Names.Add(node.Name.ToLowerInvariant());
    }

    /// <summary>The objects a fragment reads.</summary>
    private sealed class TableVisitor : TSqlFragmentVisitor
    {
        public List<string> Names { get; } = [];

        public override void Visit(NamedTableReference node) => Names.Add(string.Join('.', node.SchemaObject.Identifiers.Select(i => i.Value)));
    }

    /// <summary>An observer that runs only what the test asks: an evidence block, or a sidecar read through its quiet path.</summary>
    private sealed class QuietProbe(ICaptureConnector connector) : TargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null, "The fix: a test's.")
    {
        public ISidecarAccess Access => SidecarAccess;

        public Task<IReadOnlyList<CaptureValues>?> Evidence(string blockId, DateTimeOffset now) => RunAsync(blockId, now, CancellationToken.None);

        public override Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken) => Task.FromResult(now);

        protected override Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken) => Task.CompletedTask;

        protected override Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
