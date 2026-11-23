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
/// summary, the reader's cadence and paging, and the observer's wiring, on simulated targets. No database: the blocks
/// answer from a script, and T3's from the contract's own sidecar fixture, so the reader round-trips to it.
/// </summary>
public sealed class RcaQueryStoreSqlTests
{
    private const string Marker = "/* dbhubdemo:rca-observer */";

    private static readonly string[] SourceOrder = ["RCA-SQL-10", "RCA-SQL-11", "RCA-SQL-14", "RCA-SQL-15", "RCA-AZ-03", "RCA-AZ-04"];

    private static readonly string[] QueryStoreBlocks = [.. SourceOrder];

    // The plan columns a read's time doesn't change: the fixture wrote its plans at other reads than the reader does.
    private static readonly string[] StablePlanColumns =
        ["target", "query_id", "plan_id", "query_hash", "plan_hash", "module_name", "statement_text", "compiled_utc", "last_compiled_utc", "compiles", "is_forced_plan", "forcing_type", "force_failures", "last_force_failure", "plans_for_query", "estimated_cost", "is_parallel"];

    [Theory]
    [InlineData("RCA-SQL-10", "@final,@since")]
    [InlineData("RCA-SQL-11", "@final,@plans,@since")]
    [InlineData("RCA-SQL-14", "@plans,@queries,@with_plan")]
    [InlineData("RCA-SQL-15", "")]
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

        // Statistics and waits: every row and column the fixture has, and no other.
        Assert.Equal(Canonical(fixture.Table(RcaContract.QueryStats)), Canonical(sidecar.Table(RcaContract.QueryStats)));
        Assert.Equal(Canonical(fixture.Table(RcaContract.QueryWaits)), Canonical(sidecar.Table(RcaContract.QueryWaits)));

        // The response, as measured: the fixture's events, and the recommendation's appearance, which the fixture leaves out.
        var events = Canonical(sidecar.Table(RcaContract.QueryEvents), except: "detail");
        var expected = Canonical(fixture.Table(RcaContract.QueryEvents), except: "detail");
        Assert.Empty(expected.Except(events));
        var appeared = Assert.Single(sidecar.Table(RcaContract.QueryEvents), e => (string?)e.Get("previous_state") is null);
        Assert.Equal(("tuning", "Active", RcaSimulation.At(17, 6, 0), RcaSimulation.At(17, 5, 30)), ((string)appeared.Get("kind")!, (string)appeared.Get("state")!, (DateTimeOffset)appeared.Get("event_time_utc")!, (DateTimeOffset)appeared.Get("time_from_utc")!));
        Assert.Equal((412L, 31L), ((long)appeared.Get("query_id")!, (long)appeared.Get("plan_id")!));
        Assert.Equal(expected.Count + 1, events.Count);
        Assert.Contains("CPU time per execution 2.1 ms against 176 ms", (string?)appeared.Get("detail"), StringComparison.Ordinal);

        // Plans: each plan's latest row is the fixture's latest, but for when it was read; query 902's plan is written too.
        var plans = sidecar.Table(RcaContract.QueryPlans).GroupBy(p => (long)p.Get("plan_id")!).ToDictionary(g => g.Key, g => g.MaxBy(p => (DateTimeOffset)p.Get("captured_at_utc")!)!);
        foreach (var latest in fixture.Table(RcaContract.QueryPlans).GroupBy(p => (long)p["plan_id"]!).Select(g => g.MaxBy(p => (DateTimeOffset)p["captured_at_utc"]!)!))
        {
            Assert.Equal(Canonical([latest], only: StablePlanColumns), Canonical([plans[(long)latest["plan_id"]!]], only: StablePlanColumns));
        }

        Assert.Equal([12L, 31L, 40L, 58L], plans.Keys.Order());
        Assert.Contains("Index Seek on [care].[appointments].[ix_appointments_patient] seeking patient_id (71 % of the cost); Key Lookup on [care].[appointments].[pk_appointments] for status and duration_minutes (27 %)", Summary(plans[31]), StringComparison.Ordinal);
        Assert.StartsWith("Clustered Index Scan on [care].[appointments].[pk_appointments] filtering on patient_id and status (88 % of the cost); Parallelism (Gather Streams) (12 %)", Summary(plans[58]), StringComparison.Ordinal);
        Assert.Contains(". Parallel.", Summary(plans[58]), StringComparison.Ordinal);
        Assert.StartsWith("Index Scan on [care].[patients].[ix_patients_facility] (62 % of the cost); Sort (TopN Sort) by last_name and first_name (35 %)", Summary(plans[12]), StringComparison.Ordinal);
        Assert.Contains("Serial: max dop set to one.", Summary(plans[12]), StringComparison.Ordinal);

        // A plan is written when it's new, or its forcing or compile changed; each showplan is read once.
        Assert.Equal(["16:50:05 12", "16:50:05 31", "17:17:05 31", "17:17:05 40", "17:17:05 58"], sidecar.Table(RcaContract.QueryPlans).Select(p => string.Create(CultureInfo.InvariantCulture, $"{(DateTimeOffset)p.Get("captured_at_utc")!:HH:mm:ss} {p.Get("plan_id")}")).Order(StringComparer.Ordinal));
        var withPlan = connector.ParameterCalls.Where(c => c.BlockId == "RCA-SQL-14").Select(c => (string)c.Parameters.Value("@with_plan")!).ToList();
        Assert.Equal(["12,31", string.Empty, "40,58", string.Empty], withPlan);

        // Coverage: the observation's rows, made one as the sidecar's export makes them, are the fixture's row.
        Assert.Equal(Canonical(fixture.Table(RcaContract.QueryCoverage)), Canonical([Coalesce(sidecar.Table(RcaContract.QueryCoverage))]));

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
    public async Task AReadAtItsCapReadsOnFromTheLastWholeIntervalAndKeepsAnIntervalOverItWithAGap()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var intervals = new[] { (RcaSimulation.At(16, 0, 0), 3), (RcaSimulation.At(16, 15, 0), 3), (RcaSimulation.At(16, 30, 0), 2), (RcaSimulation.At(16, 45, 0), 5) };
        var calls = new List<(string Block, DateTimeOffset Now, CaptureParameters Parameters)>();
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader("T1", false, sink, (block, now, parameters, _, _) =>
        {
            calls.Add((block, now, parameters));
            IReadOnlyList<CaptureValues> rows = block switch
            {
                "RCA-SQL-10" => [.. intervals
                    .Where(i => i.Item1.AddMinutes(15) > (DateTimeOffset)parameters.Value("@since")! && i.Item1.AddMinutes(15) <= now)
                    .SelectMany(i => Enumerable.Range(1, i.Item2).Select(n => StatRow(i.Item1, (i.Item1.Minute * 10) + n, cpu: 100 - n)))
                    .Take(4)],
                "RCA-SQL-15" => [StateRow(now, "READ_WRITE", 0, null)],
                _ => [],
            };
            return Task.FromResult<IReadOnlyList<CaptureValues>?>(rows);
        }, new SqlQueryStoreOptions { RowCap = 4, Schedule = new QueryStoreSchedule(TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(2), TimeSpan.FromHours(1)) });

        reader.Begin(start);
        await reader.TickAsync(start, TestContext.Current.CancellationToken);
        await reader.TickAsync(RcaSimulation.At(17, 2, 0), TestContext.Current.CancellationToken);

        Assert.Equal(
            [RcaSimulation.At(15, 50, 0), RcaSimulation.At(16, 15, 0), RcaSimulation.At(16, 30, 0), RcaSimulation.At(16, 45, 0), RcaSimulation.At(17, 0, 0)],
            calls.Where(c => c.Block == "RCA-SQL-10").Select(c => (DateTimeOffset)c.Parameters.Value("@since")!));
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
        var since = new List<(DateTimeOffset Now, DateTimeOffset Since)>();
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader("T2", false, sink, (block, now, parameters, _, _) =>
        {
            if (block == "RCA-SQL-10")
            {
                since.Add((now, (DateTimeOffset)parameters.Value("@since")!));
                if (failing)
                {
                    failing = false;
                    return Task.FromResult<IReadOnlyList<CaptureValues>?>(null);
                }
            }

            return Task.FromResult<IReadOnlyList<CaptureValues>?>(block == "RCA-SQL-15" ? [StateRow(now, "READ_WRITE", 0, null)] : []);
        });

        reader.Begin(start);
        var next = await reader.TickAsync(start, TestContext.Current.CancellationToken);
        Assert.Equal(start.AddSeconds(60), next);
        for (var now = start.AddSeconds(60); now <= start.AddMinutes(2); now = now.AddSeconds(60))
        {
            await reader.TickAsync(now, TestContext.Current.CancellationToken);
        }

        Assert.Equal([(start, start.AddHours(-2)), (start.AddMinutes(2), start.AddHours(-2))], since);
        Assert.Contains("Query Store's statistics (RCA-SQL-10) weren't read on T2: the read failed, and RCA Coverage says why. The next read takes the intervals that ended after 14:50 UTC.", (string?)sink.Table(RcaContract.QueryCoverage)[0].Get("gaps"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AStateOtherThanReadWriteAndAnUnforcedPlanAreEventsAndTheStateIsAGapInWords()
    {
        var start = RcaSimulation.At(16, 50, 0);
        var sink = new MemorySidecarSink();
        var reader = new SqlQueryStoreReader("T1", false, sink, (block, now, _, _, _) =>
            Task.FromResult<IReadOnlyList<CaptureValues>?>(block == "RCA-SQL-15"
                ? (now == start ? [StateRow(now, "READ_WRITE", 0, "5:9:MANUAL")] : [StateRow(now, "READ_ONLY", 65536, null)])
                : []));

        reader.Begin(start);
        await reader.TickAsync(start, TestContext.Current.CancellationToken);
        await reader.TickAsync(start.AddSeconds(60), TestContext.Current.CancellationToken);
        await reader.EndAsync(start.AddSeconds(90), TestContext.Current.CancellationToken);

        var events = sink.Table(RcaContract.QueryEvents);
        Assert.Equal(
            ["state READ_ONLY READ_WRITE  Query Store went from READ_WRITE to READ_ONLY: Query Store reached its size limit (max_storage_size_mb).", "unforced not forced forced 9 Plan 9 of query 5 no longer forced; it was forced by hand (sys.sp_query_store_force_plan)."],
            events.Select(e => $"{e.Get("kind")} {e.Get("state")} {e.Get("previous_state")} {e.Get("plan_id")} {e.Get("detail")}"));
        Assert.All(events, e => Assert.Equal((start.AddSeconds(60), start), ((DateTimeOffset)e.Get("event_time_utc")!, (DateTimeOffset)e.Get("time_from_utc")!)));
        var last = sink.Table(RcaContract.QueryCoverage)[^1];
        Assert.Equal("READ_ONLY", last.Get("state"));
        Assert.Contains("16:51:00 UTC: Query Store on T1 was READ_ONLY at 16:51:00 UTC: Query Store reached its size limit (max_storage_size_mb), 1,000 of 1,000 MB, so it recorded no new statistics while it stayed so.", (string?)last.Get("gaps"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task WithoutASidecarSinkNothingReadsQueryStoreAndWithOneTheEvidenceStaysTheSame()
    {
        var (withoutCalls, withoutEvidence, _) = await RunT1Async(sidecar: null);
        var sidecar = new MemorySidecarSink();
        var (calls, evidence, connector) = await RunT1Async(sidecar);

        Assert.DoesNotContain(withoutCalls, c => QueryStoreBlocks.Contains(c));
        Assert.Equal(withoutEvidence, evidence);

        // Query Store's first read follows the first tick's sentinel, and its last read follows the event session's drop.
        Assert.True(calls.IndexOf("RCA-SQL-09") < calls.IndexOf("RCA-SQL-15"));
        Assert.True(calls.LastIndexOf("RCA-XE-05") < calls.LastIndexOf("RCA-SQL-10"));
        Assert.Equal("RCA-SQL-10", calls[^1]);
        var reads = connector.ParameterCalls.Where(c => c.BlockId == "RCA-SQL-10").Select(c => ((DateTimeOffset)c.Parameters.Value("@since")!, (bool)c.Parameters.Value("@final")!)).ToList();
        Assert.Equal([(RcaSimulation.T1From.AddHours(-2), false), (RcaSimulation.T1From.AddHours(-2), false), (RcaSimulation.T1From.AddHours(-2), true)], reads);
        Assert.All(sidecar.Rows, r => Assert.Equal(RcaContract.QueryCoverage, r.Table));
        Assert.Equal(3, sidecar.Rows.Count);
    }

    /// <summary>T1's simulated blocking chain, 16:50 to 17:05, observed with or without a sidecar sink: the calls in order and the evidence it wrote.</summary>
    private static async Task<(List<string> Calls, List<string> Evidence, ScriptedConnector Connector)> RunT1Async(MemorySidecarSink? sidecar)
    {
        var clock = new ManualTime(RcaSimulation.T1From);
        var connector = RcaSimulation.T1(clock);
        connector.ParameterAnswer = (block, _) => block == "RCA-SQL-15" ? [StateRow(clock.Now, "READ_WRITE", 0, null)] : [];
        var sink = new MemorySink();
        var observer = new SqlTargetObserver("T1", DemoTarget.T1, connector, RcaSimulation.Options(), RunnerLog.Null, sidecar);

        await RcaSimulation.DriveAsync([observer], sink, clock, RcaSimulation.T1From, RcaSimulation.T1To, TestContext.Current.CancellationToken);

        var evidence = sink.Rows.Select(r => string.Join('|', new[] { r.Table, r.Target, Norm(r.At), r.Source, r.Sentinel ? "sentinel" : string.Empty }.Concat(r.Values.OrderBy(v => v.Key, StringComparer.Ordinal).Select(v => $"{v.Key}={Norm(v.Value)}"))))
            .Concat(sink.Notes.Select(n => $"note|{n.Kind}|{n.Target}|{Norm(n.At)}|{n.Text}"))
            .ToList();
        return ([.. connector.Calls.Select(c => c.BlockId)], evidence, connector);
    }

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

    private static string? Summary(CaptureRow plan) => (string?)plan.Get("plan_summary");

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

    private static List<string> Canonical(IEnumerable<CaptureRow> rows, string? except = null) =>
        Canonical(rows.Select(r => RcaContract.Table(r.Table).Columns.ToDictionary(c => c.Name, c => r.Get(c.Name), StringComparer.Ordinal)), except: except);

    private static List<string> Canonical(IEnumerable<Dictionary<string, object?>> rows, string? except = null, string[]? only = null) =>
        [.. rows.Select(r => string.Join('|', r.Where(v => v.Key != except && (only is null || only.Contains(v.Key))).OrderBy(v => v.Key, StringComparer.Ordinal).Select(v => $"{v.Key}={Norm(v.Value)}"))).Order(StringComparer.Ordinal)];

    private static List<string> Canonical(IEnumerable<CaptureRow> rows, string[] only) =>
        Canonical(rows.Select(r => RcaContract.Table(r.Table).Columns.ToDictionary(c => c.Name, c => r.Get(c.Name), StringComparer.Ordinal)), only: only);

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
}
