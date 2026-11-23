using System.Globalization;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using static ContosoCare.Workload.Tests.RcaTestKit;

namespace ContosoCare.Workload.Tests;

/// <summary>Keeps every sidecar row the observer writes; refuses an evidence table's row, as every sidecar sink does.</summary>
internal sealed class MemorySidecarSink : ISidecarSink
{
    private readonly Lock gate = new();
    private readonly List<CaptureRow> rows = [];

    public List<CaptureRow> Rows
    {
        get
        {
            lock (gate)
            {
                return [.. rows];
            }
        }
    }

    public void Write(CaptureRow row)
    {
        NullSidecarSink.Instance.Write(row);
        lock (gate)
        {
            rows.Add(row);
        }
    }

    public List<CaptureRow> Table(string table) => [.. Rows.Where(r => r.Table == table)];
}

/// <summary>A sidecar fixture decoded for assertions: each table's rows with strings resolved, times as UTC, and integers as long.</summary>
internal sealed class SidecarView
{
    public SidecarView(string path)
    {
        Root = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Epoch = DateTimeOffset.Parse(Root["epochUtc"]!.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
        Strings = [.. Root["strings"]!.AsArray().Select(s => s!.GetValue<string>())];
    }

    public JsonObject Root { get; }

    public DateTimeOffset Epoch { get; }

    public List<string> Strings { get; }

    public List<Dictionary<string, object?>> Table(string name)
    {
        if (Root["tables"]![name]?.AsObject() is not { } table)
        {
            return [];
        }

        var types = RcaContract.Table(name).Columns.ToDictionary(c => c.Name, c => c.Type);
        var count = table["rows"]!.GetValue<int>();
        var rows = Enumerable.Range(0, count).Select(_ => types.Keys.ToDictionary(k => k, _ => (object?)null, StringComparer.Ordinal)).ToList();
        foreach (var (column, values) in table["columns"]!.AsObject())
        {
            var array = values!.AsArray();
            for (var i = 0; i < count; i++)
            {
                rows[i][column] = array[i] is not { } value ? null : types[column] switch
                {
                    "string" => Strings[value.GetValue<int>()],
                    "timestamp" => Epoch.AddMilliseconds(value.GetValue<long>()),
                    "long" or "integer" => value.GetValue<long>(),
                    "double" => value.GetValue<double>(),
                    "boolean" => value.GetValue<bool>(),
                    _ => value.ToJsonString(),
                };
            }
        }

        return rows;
    }
}

/// <summary>
/// T3's Query Store during the fixture's plan regression (rca/fixtures/t3-plan-regression.sidecar.json and its README),
/// as the catalog's blocks would return it at each simulated time: RCA-SQL-10 and 11 from the fixture's own statistics
/// and waits, RCA-SQL-14 from its plans as each read saw them, with showplans whose costs are the fixture's; RCA-SQL-15
/// with plan 31 forced at 17:09:41.12; RCA-AZ-03 with FORCE_LAST_GOOD_PLAN on; and RCA-AZ-04's recommendation for query
/// 412, Active from 17:06, Executing from 17:09:15, and Verifying from 17:10:15. The observer sees only these DMV-shaped
/// results.
/// </summary>
internal sealed class T3QueryStore
{
    public static readonly DateTimeOffset From = RcaSimulation.At(16, 50, 0);

    public static readonly DateTimeOffset To = RcaSimulation.At(17, 20, 0);

    /// <summary>The fixture's first read looks back from 16:15, not 2 hours (its README says so).</summary>
    public static readonly SqlQueryStoreOptions Options = new() { Schedule = new QueryStoreSchedule(TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(35)) };

    private static readonly DateTimeOffset Forced = RcaSimulation.At(17, 9, 41, 120);

    // The server's time of each Query Store read (the fixture's captured_at_utc), by the minute in which the observer
    // made it: an interval read's blocks run on consecutive ticks.
    private static readonly Dictionary<DateTimeOffset, DateTimeOffset> Stamps = new()
    {
        [RcaSimulation.At(16, 50, 0)] = RcaSimulation.At(16, 50, 5, 210),
        [RcaSimulation.At(17, 2, 0)] = RcaSimulation.At(17, 2, 5, 330),
        [RcaSimulation.At(17, 17, 0)] = RcaSimulation.At(17, 17, 5, 480),
        [RcaSimulation.At(17, 20, 0)] = RcaSimulation.At(17, 20, 10, 50),
    };

    private readonly ManualTime clock;
    private readonly List<Dictionary<string, object?>> stats;
    private readonly List<Dictionary<string, object?>> waits;
    private readonly List<Dictionary<string, object?>> plans;

    public T3QueryStore(ManualTime clock)
    {
        this.clock = clock;
        Fixture = new SidecarView(RepositoryPaths.Combine("rca", "fixtures", "t3-plan-regression.sidecar.json"));
        stats = Fixture.Table(RcaContract.QueryStats);
        waits = Fixture.Table(RcaContract.QueryWaits);
        plans = Fixture.Table(RcaContract.QueryPlans);
    }

    public SidecarView Fixture { get; }

    /// <summary>The blocks' text as RCA Query Stats keeps it, with the literals it had before the normalizer replaced them.</summary>
    public static string Raw(string? statement) => (statement ?? string.Empty)
        .Replace("a.status <> ?", "a.status <> N'cancelled' /* a comment the normalizer drops */", StringComparison.Ordinal)
        .Replace("TOP (?)", "TOP (50)", StringComparison.Ordinal);

    /// <summary>A connector whose Query Store blocks answer from this store, and whose other blocks return what a quiet T3 would.</summary>
    public ScriptedConnector Connector()
    {
        var connector = new ScriptedConnector((block, _) => block switch
        {
            "RCA-XE-04" => [Row(("target_data", RcaSimulation.RingBuffer([])))],
            _ => [],
        });
        connector.ParameterAnswer = Answer;
        return connector;
    }

    public IReadOnlyList<CaptureValues> Answer(string block, CaptureParameters parameters)
    {
        var now = clock.Now;
        var stamp = Stamps.Where(s => s.Key <= now && now < s.Key.AddMinutes(1)).Select(s => (DateTimeOffset?)s.Value).FirstOrDefault() ?? now;
        return block switch
        {
            "RCA-SQL-10" => [.. Intervals(stats, parameters, now).Select(s => StatsRow(s, stamp))],
            "RCA-SQL-11" => [.. Intervals(waits, parameters, now).Where(w => Ids(parameters, "@plans").Contains((long)w["plan_id"]!)).Select(w => WaitRow(w, stamp))],
            "RCA-SQL-14" => PlanRows(parameters, stamp),
            "RCA-SQL-15" => [Row(("captured_at_utc", now.UtcDateTime), ("actual_state", "READ_WRITE"), ("desired_state", "READ_WRITE"), ("readonly_reason", 0), ("query_capture_mode", "AUTO"), ("interval_length_minutes", 15L), ("current_storage_size_mb", 118L), ("max_storage_size_mb", 1000L), ("forced_plans", now >= Forced ? "412:31:AUTO" : null))],
            "RCA-AZ-03" => [Row(("captured_at_utc", now.UtcDateTime), ("name", "FORCE_LAST_GOOD_PLAN"), ("desired_state_desc", "ON"), ("actual_state_desc", "ON"), ("reason_desc", null))],
            "RCA-AZ-04" => Recommendation(now),
            _ => [],
        };
    }

    /// <summary>The rows of the intervals a read takes: those that ended after @since, and had ended by now unless @final.</summary>
    private static IEnumerable<Dictionary<string, object?>> Intervals(List<Dictionary<string, object?>> rows, CaptureParameters parameters, DateTimeOffset now)
    {
        var since = (DateTimeOffset)parameters.Value("@since")!;
        var final = (bool)parameters.Value("@final")!;
        return rows.Where(r => (DateTimeOffset)r["interval_end_utc"]! > since && ((DateTimeOffset)r["interval_end_utc"]! <= now || final));
    }

    private static HashSet<long> Ids(CaptureParameters parameters, string name) =>
        [.. ((string?)parameters.Value(name) ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries).Select(id => long.Parse(id, CultureInfo.InvariantCulture))];

    private static CaptureValues StatsRow(Dictionary<string, object?> s, DateTimeOffset stamp) => Row(
        ("captured_at_utc", stamp.UtcDateTime),
        ("interval_start_utc", s["interval_start_utc"]),
        ("interval_end_utc", s["interval_end_utc"]),
        ("query_id", s["query_id"]),
        ("plan_id", s["plan_id"]),
        ("query_hash", Bytes(s["query_hash"])),
        ("plan_hash", Bytes(s["plan_hash"])),
        ("module_name", s["module_name"]),
        ("query_sql_text", Raw((string?)s["statement_text"])),
        ("executions", s["executions"]),
        ("aborted_executions", s["aborted_executions"]),
        ("cpu_ms", s["cpu_ms"]),
        ("duration_ms", s["duration_ms"]),
        ("max_duration_ms", s["max_duration_ms"] is double max ? (decimal)max : null),
        ("logical_reads", s["logical_reads"]),
        ("physical_reads", s["physical_reads"]),
        ("row_count", s["row_count"]),
        ("log_bytes", s["log_bytes"]),
        ("tempdb_kb", s["tempdb_kb"]),
        ("max_used_memory_kb", s["max_used_memory_kb"]),
        ("max_dop", s["max_dop"]),
        ("wait_ms", s["wait_ms"]),
        ("first_execution_utc", s["first_execution_utc"]),
        ("last_execution_utc", s["last_execution_utc"]));

    private static CaptureValues WaitRow(Dictionary<string, object?> w, DateTimeOffset stamp) => Row(
        ("captured_at_utc", stamp.UtcDateTime),
        ("interval_start_utc", w["interval_start_utc"]),
        ("interval_end_utc", w["interval_end_utc"]),
        ("query_id", w["query_id"]),
        ("plan_id", w["plan_id"]),
        ("wait_category", w["wait_category"]),
        ("wait_ms", w["wait_ms"]),
        ("max_wait_ms", w["max_wait_ms"]));

    /// <summary>RCA-SQL-14: the 5 plans of each query that ran last, the plans asked for, and every forced plan, as of the read; XML for @with_plan only.</summary>
    private List<CaptureValues> PlanRows(CaptureParameters parameters, DateTimeOffset stamp)
    {
        var queries = Ids(parameters, "@queries");
        var asked = Ids(parameters, "@plans");
        var withPlan = Ids(parameters, "@with_plan");
        var rows = new List<CaptureValues>();
        foreach (var plan in plans.Select(p => (long)p["plan_id"]!).Distinct().Order())
        {
            // A plan as the latest of the fixture's reads up to this one saw it.
            var seen = plans.Where(p => (long)p["plan_id"]! == plan && (DateTimeOffset)p["captured_at_utc"]! <= stamp).MaxBy(p => (DateTimeOffset)p["captured_at_utc"]!);
            if (seen is null || !(queries.Contains((long)seen["query_id"]!) || asked.Contains(plan) || (bool)seen["is_forced_plan"]!))
            {
                continue;
            }

            rows.Add(Row(
                ("captured_at_utc", stamp.UtcDateTime),
                ("query_id", seen["query_id"]),
                ("plan_id", plan),
                ("query_hash", Bytes(seen["query_hash"])),
                ("plan_hash", Bytes(seen["plan_hash"])),
                ("module_name", seen.GetValueOrDefault("module_name")),
                ("query_sql_text", Raw((string?)seen["statement_text"])),
                ("compiled_utc", seen["compiled_utc"]),
                ("last_compiled_utc", seen["last_compiled_utc"]),
                ("last_execution_utc", seen["last_execution_utc"]),
                ("compiles", seen["compiles"]),
                ("is_forced_plan", seen["is_forced_plan"]),
                ("forcing_type", seen["forcing_type"]),
                ("force_failures", seen["force_failures"]),
                ("last_force_failure", null),
                ("plans_for_query", (int)(long)seen["plans_for_query"]!),
                ("is_parallel", seen["is_parallel"]),
                ("query_plan", withPlan.Contains(plan) ? Showplans.ForPlan(plan) : null),
                ("query_plan_bytes", withPlan.Contains(plan) ? (object)((long)Showplans.ForPlan(plan).Length * 2) : null)));
        }

        return rows;
    }

    private static IReadOnlyList<CaptureValues> Recommendation(DateTimeOffset now)
    {
        if (now < RcaSimulation.At(17, 6, 0))
        {
            return [];
        }

        var state = now < RcaSimulation.At(17, 9, 15) ? "Active" : now < RcaSimulation.At(17, 10, 15) ? "Executing" : "Verifying";
        return
        [
            Row(
                ("captured_at_utc", now.UtcDateTime),
                ("name", "PR_7"),
                ("type", "FORCE_LAST_GOOD_PLAN"),
                ("reason", "Average query CPU time changed from 2.1ms to 176ms"),
                ("valid_since", RcaSimulation.At(17, 5, 51).UtcDateTime),
                ("last_refresh", RcaSimulation.At(17, 5, 51).UtcDateTime),
                ("state", state),
                ("state_reason", null),
                ("execute_action_initiated_by", state == "Active" ? null : "System"),
                ("execute_action_initiated_time", state == "Active" ? null : RcaSimulation.At(17, 9, 15).UtcDateTime),
                ("score", 61),
                ("query_id", "412"),
                ("regressed_plan_id", "58"),
                ("recommended_plan_id", "31"),
                ("regressed_plan_cpu_us", "176000"),
                ("recommended_plan_cpu_us", "2100")),
        ];
    }

    private static byte[]? Bytes(object? hash) => hash is string text ? Convert.FromHexString(text[2..]) : null;
}

/// <summary>Showplans built at run time, with the shapes and costs the fixture states, and values a summary must never keep.</summary>
internal static class Showplans
{
    /// <summary>A value a plan was compiled for: no summary may hold it.</summary>
    public const string CompiledValue = "Patient-Range-Marker-7731";

    public static string ForPlan(long plan) => plan switch
    {
        31 => Plan(0.0331, 1, null, RelOp(0, "Stream Aggregate", "Aggregate", 0.0331, false,
              RelOp(1, "Nested Loops", "Inner Join", 0.0330, false,
                  RelOp(2, "Index Seek", "Index Seek", 0.0235, false, Seek("[ix_appointments_patient]", "[patient_id]")) +
                  RelOp(3, "Key Lookup", "Key Lookup", 0.0089, false, Lookup("[pk_appointments]"), "[status]", "[duration_minutes]")))),
        58 => Plan(38.6, 4, null, RelOp(0, "Stream Aggregate", "Aggregate", 38.6, false,
              RelOp(1, "Parallelism", "Gather Streams", 38.55, true,
                  RelOp(2, "Clustered Index Scan", "Clustered Index Scan", 33.97, true, Scan("[pk_appointments]", "[patient_id]", "[status]"))))),
        12 => Plan(0.2108, 1, "MaxDOPSetToOne", RelOp(0, "Top", "Top", 0.2108, false,
              RelOp(1, "Sort", "TopN Sort", 0.2045, false,
                  $"""<Sort Distinct="0"><OrderBy><OrderByColumn Ascending="1">{Column("[patients]", "[last_name]")}</OrderByColumn><OrderByColumn Ascending="1">{Column("[patients]", "[first_name]")}</OrderByColumn></OrderBy>""" +
                  RelOp(2, "Index Scan", "Index Scan", 0.1307, false, $"""<IndexScan Ordered="0"><Object Database="[ContosoCare]" Schema="[care]" Table="[patients]" Index="[ix_patients_facility]" IndexKind="NonClustered"/></IndexScan>""") +
                  "</Sort>"))),
        _ => Plan(0.0100, 1, null, RelOp(0, "Filter", "Filter", 0.0100, false, RelOp(1, "Table-valued function", "Table-valued function", 0.0091, false, string.Empty))),
    };

    /// <summary>A plan with the warnings, a missing index, and the values (a compiled parameter, literals in its text and predicates) a summary must leave out.</summary>
    public static string WithWarnings() => Plan(
        12.5,
        1,
        null,
        RelOp(0, "Hash Match", "Inner Join", 12.5, false,
            """<Warnings><SpillToTempDb SpillLevel="1" SpilledThreadCount="1"/></Warnings><Hash>""" +
            RelOp(1, "Table Scan", "Table Scan", 9.1, false, $"""<TableScan Ordered="0"><Object Database="[ContosoCare]" Schema="[care]" Table="[#visit_batch_____________________________________________________________________________________________________000000000012]"/><Predicate><ScalarOperator ScalarString="[ContosoCare].[care].[#visit_batch].[note]=N'{CompiledValue}'"><Compare CompareOp="EQ"><ScalarOperator>{Column("[#visit_batch]", "[note]")}</ScalarOperator><ScalarOperator><Const ConstValue="N'{CompiledValue}'"/></ScalarOperator></Compare></ScalarOperator></Predicate></TableScan>""") +
            RelOp(2, "Clustered Index Scan", "Clustered Index Scan", 2.9, false, Scan("[pk_appointments]", "[patient_id]")) +
            "</Hash>"),
        """<Warnings NoJoinPredicate="true"><PlanAffectingConvert ConvertIssue="Seek Plan" Expression="CONVERT_IMPLICIT(nvarchar(20),[a].[code],0)"/></Warnings>""",
        """<MissingIndexes><MissingIndexGroup Impact="87.4"><MissingIndex Database="[ContosoCare]" Schema="[care]" Table="[appointments]"><ColumnGroup Usage="EQUALITY"><Column Name="[patient_id]" ColumnId="2"/></ColumnGroup><ColumnGroup Usage="INCLUDE"><Column Name="[status]" ColumnId="5"/></ColumnGroup></MissingIndex></MissingIndexGroup><MissingIndexGroup Impact="12"><MissingIndex Database="[ContosoCare]" Schema="[care]" Table="[patients]"><ColumnGroup Usage="EQUALITY"><Column Name="[facility_id]" ColumnId="3"/></ColumnGroup></MissingIndex></MissingIndexGroup></MissingIndexes>""");

    private static string Plan(double cost, int dop, string? serialReason, string relOp, string warnings = "", string missing = "") =>
        $"""<?xml version="1.0" encoding="utf-16"?><ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4135.4"><BatchSequence><Batch><Statements><StmtSimple StatementText="SELECT @visits = COUNT(*) FROM care.appointments AS a WHERE a.code = N'{CompiledValue}'" StatementId="1" StatementCompId="3" StatementType="SELECT" StatementSubTreeCost="{cost.ToString(CultureInfo.InvariantCulture)}" StatementEstRows="1"><QueryPlan DegreeOfParallelism="{dop}" CachedPlanSize="40"{(serialReason is null ? string.Empty : $" NonParallelPlanReason=\"{serialReason}\"")}>{missing}{warnings}{relOp}<ParameterList><ColumnReference Column="@first_patient" ParameterDataType="nvarchar(40)" ParameterCompiledValue="N'{CompiledValue}'"/></ParameterList></QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>""";

    private static string RelOp(int node, string physical, string logical, double subtree, bool parallel, string inner, params string[] output) =>
        $"""<RelOp NodeId="{node}" PhysicalOp="{physical}" LogicalOp="{logical}" EstimateRows="1" EstimatedTotalSubtreeCost="{subtree.ToString(CultureInfo.InvariantCulture)}" Parallel="{(parallel ? 1 : 0)}"><OutputList>{string.Concat(output.Select(c => Column("[appointments]", c)))}</OutputList>{inner}</RelOp>""";

    private static string Column(string table, string column) => $"""<ColumnReference Database="[ContosoCare]" Schema="[care]" Table="{table}" Alias="[a]" Column="{column}"/>""";

    private static string Seek(string index, string column) =>
        $"""<IndexScan Ordered="1" ScanDirection="FORWARD"><Object Database="[ContosoCare]" Schema="[care]" Table="[appointments]" Index="{index}" IndexKind="NonClustered"/><SeekPredicates><SeekPredicateNew><SeekKeys><StartRange ScanType="GE"><RangeColumns>{Column("[appointments]", column)}</RangeColumns><RangeExpressions><ScalarOperator ScalarString="[@first_patient]"><Identifier><ColumnReference Column="@first_patient"/></Identifier></ScalarOperator></RangeExpressions></StartRange></SeekKeys></SeekPredicateNew></SeekPredicates></IndexScan>""";

    private static string Lookup(string index) =>
        $"""<IndexScan Lookup="1" Ordered="1" ScanDirection="FORWARD"><Object Database="[ContosoCare]" Schema="[care]" Table="[appointments]" Index="{index}" IndexKind="Clustered"/></IndexScan>""";

    private static string Scan(string index, params string[] columns) =>
        $"""<IndexScan Ordered="0"><Object Database="[ContosoCare]" Schema="[care]" Table="[appointments]" Index="{index}" IndexKind="Clustered"/><Predicate><ScalarOperator ScalarString="[a].[patient_id]&gt;=[@first_patient] AND [a].[status]&lt;&gt;N'{CompiledValue}'">{string.Concat(columns.Select(c => Column("[appointments]", c)))}<Const ConstValue="N'{CompiledValue}'"/></ScalarOperator></Predicate></IndexScan>""";
}

/// <summary>
/// A sidecar reader's access to a scripted observer: the blocks answer from <c>answer</c> (null is a failure), each moves
/// <see cref="Clock"/> by what <see cref="Cost"/> says, and a cost past its timeout fails as SqlClient's command timeout
/// does, after the timeout. The throttle's state is the test's to set.
/// </summary>
internal sealed class FakeSidecarAccess(string target, Func<string, CaptureParameters, IReadOnlyList<CaptureValues>?> answer) : ISidecarAccess
{
    public string Target { get; } = target;

    public int Factor { get; set; } = 1;

    public bool DetailStopped { get; set; }

    public ManualTime? Clock { get; init; }

    public Func<string, TimeSpan> Cost { get; set; } = _ => TimeSpan.Zero;

    public string FailureMessage { get; set; } = "SQL error 50000: a test's failure.";

    public List<(DateTimeOffset At, string BlockId, CaptureParameters Parameters, TimeSpan Timeout)> Calls { get; } = [];

    public Task<QuietResult> RunAsync(string blockId, DateTimeOffset now, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken)
    {
        Calls.Add((now, blockId, parameters, timeout));
        var cost = Cost(blockId);
        Clock?.Advance(cost > timeout ? timeout : cost);
        if (cost > timeout)
        {
            return Task.FromResult(QuietResult.Failed(CaptureFailureKind.Timeout, "The statement was cancelled at its timeout."));
        }

        return Task.FromResult(answer(blockId, parameters) is { } rows ? QuietResult.Of(rows) : QuietResult.Failed(CaptureFailureKind.Other, FailureMessage));
    }
}

/// <summary>A clock whose timestamps follow a <see cref="ManualTime"/>, so a reader measures what the test's blocks cost.</summary>
internal sealed class SteppedClock(ManualTime time) : TimeProvider
{
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override DateTimeOffset GetUtcNow() => time.GetUtcNow();

    public override long GetTimestamp() => time.GetUtcNow().UtcTicks;
}

/// <summary>
/// A target whose evidence blocks answer as <c>evidence</c>'s connection does (RcaSimulation's T1) and cost what
/// <see cref="EvidenceCost"/> says, by default nothing, and whose Query Store blocks can cost time (the clock moves by it;
/// past its timeout, by the timeout, and the block fails as SqlClient's command timeout does), fail, or throw. The
/// connection can break at a moment: a Query Store block at it, or any block after it, fails on the connection that was
/// open then, as does every later block on it; a connection opened after the break works.
/// </summary>
internal sealed class TimedConnector(ManualTime clock, ICaptureConnector evidence) : ICaptureConnector
{
    public const string TransportError = "SQL error 10054: A transport-level error has occurred when receiving results from the server.";

    public static readonly HashSet<string> QueryStoreBlocks = new(StringComparer.Ordinal) { "RCA-SQL-10", "RCA-SQL-11", "RCA-SQL-14", "RCA-SQL-15", "RCA-AZ-03", "RCA-AZ-04" };

    public List<(DateTimeOffset At, string BlockId, TimeSpan Timeout, CaptureParameters? Parameters)> Calls { get; } = [];

    public List<(DateTimeOffset At, string BlockId)> Failures { get; } = [];

    public int Opens { get; private set; }

    public Func<string, TimeSpan> Cost { get; set; } = _ => TimeSpan.Zero;

    /// <summary>What an evidence block costs, by its ID and when it ran: the clock moves by it once the block has answered.</summary>
    public Func<string, DateTimeOffset, TimeSpan> EvidenceCost { get; set; } = (_, _) => TimeSpan.Zero;

    public Func<string, Exception?> Failure { get; set; } = _ => null;

    public Func<string, CaptureParameters, IReadOnlyList<CaptureValues>> QueryStore { get; set; } = (_, _) => [];

    public DateTimeOffset? BreakAt { get; set; }

    public string Description => "timed";

    private ManualTime Time => clock;

    public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var inner = await evidence.OpenAsync(cancellationToken);
        Opens++;
        return new Connection(this, clock.Now, inner);
    }

    private sealed class Connection(TimedConnector owner, DateTimeOffset opened, ICaptureConnection inner) : ICaptureConnection
    {
        private bool broken;

        public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken) =>
            RunAsync(blockId, text, parameter, null, timeout, cancellationToken);

        public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken) =>
            RunAsync(blockId, text, null, parameters, timeout, cancellationToken);

        public ValueTask DisposeAsync() => inner.DisposeAsync();

        private async Task<IReadOnlyList<CaptureValues>> RunAsync(string blockId, string text, int[]? parameter, CaptureParameters? parameters, TimeSpan timeout, CancellationToken cancellationToken)
        {
            var at = owner.Time.Now;
            owner.Calls.Add((at, blockId, timeout, parameters));
            var sidecar = QueryStoreBlocks.Contains(blockId);
            if (owner.BreakAt is { } moment && opened <= moment && (at > moment || (at == moment && sidecar)))
            {
                broken = true;
            }

            if (broken)
            {
                owner.Failures.Add((at, blockId));
                throw new CaptureException(CaptureFailureKind.Connection, TransportError);
            }

            if (!sidecar)
            {
                var rows = parameters is null
                    ? await inner.QueryAsync(blockId, text, parameter, timeout, cancellationToken)
                    : await inner.QueryAsync(blockId, text, parameters, timeout, cancellationToken);
                owner.Time.Advance(owner.EvidenceCost(blockId, at));
                return rows;
            }

            var cost = owner.Cost(blockId);
            owner.Time.Advance(cost > timeout ? timeout : cost);
            if (cost > timeout)
            {
                owner.Failures.Add((at, blockId));
                throw new CaptureException(CaptureFailureKind.Timeout, "SQL error -2: Execution Timeout Expired.");
            }

            if (owner.Failure(blockId) is { } failure)
            {
                owner.Failures.Add((at, blockId));
                throw failure;
            }

            return owner.QueryStore(blockId, parameters ?? CaptureParameters.None);
        }
    }
}
/// <summary>A sidecar sink whose store refuses every row: what a reader that throws looks like to its observer.</summary>
internal sealed class ThrowingSidecarSink : ISidecarSink
{
    public int Attempts { get; private set; }

    public void Write(CaptureRow row)
    {
        Attempts++;
        throw new IOException("The sidecar's store refused the row (a test's failure).");
    }
}

/// <summary>
/// A span that keeps what a <see cref="MemorySink"/> keeps, every watermark in order, and every attempt to write one. From
/// <see cref="FailsAt"/>, a watermark's write fails, as SpanWriter's does when span.json can't be written after its retries.
/// </summary>
internal sealed class WatermarkLog(MemorySink inner) : ICaptureSpan
{
    public const string Failure = "span.json couldn't be written (a test's failure).";

    public MemorySink Inner => inner;

    public List<DateTimeOffset> Marks { get; } = [];

    public List<DateTimeOffset> Attempts { get; } = [];

    public DateTimeOffset? FailsAt { get; init; }

    public void Write(CaptureRow row) => inner.Write(row);

    public void Note(CaptureNote note) => inner.Note(note);

    public void Watermark(string target, DateTimeOffset complete)
    {
        Attempts.Add(complete);
        if (complete >= FailsAt)
        {
            throw new IOException(Failure);
        }

        Marks.Add(complete);
        inner.Watermark(target, complete);
    }

    public void Began(string target, DateTimeOffset at) => inner.Began(target, at);

    public void Ended(string target, DateTimeOffset at) => inner.Ended(target, at);

    public void Close(DateTimeOffset at) => inner.Close(at);
}

/// <summary>Drives one observer as the observer lane does, by a clock a slow block can move.</summary>
internal static class LaneDriver
{
    /// <summary>
    /// Begins the observer at <paramref name="from"/>; ticks it when it says, 50 ms to 1 s after the last tick ended, as
    /// ObserverLane does; ends it at <paramref name="to"/> with the end hook and the clock; and releases it, as the lane
    /// does with the hook wired, even when the end fails: at the evidence's end time the hook gets, or the clock's time once
    /// EndAsync returns. <paramref name="evidenceEnded"/>, the test's, runs in the hook after the lane has the time. The
    /// target is the span's only member, so its release closes the span.
    /// </summary>
    public static async Task RunAsync(TargetObserver observer, ICaptureSpan span, ManualTime clock, DateTimeOffset from, DateTimeOffset to, CancellationToken cancellationToken, Action<DateTimeOffset>? evidenceEnded = null)
    {
        clock.Set(from);
        span.Began(observer.Target, from);
        await observer.BeginAsync(span, from, cancellationToken);
        while (clock.Now < to)
        {
            var next = await observer.TickAsync(clock.Now, cancellationToken);
            var after = clock.Now;
            var delay = next - after;
            delay = delay < TimeSpan.FromMilliseconds(50) ? TimeSpan.FromMilliseconds(50) : delay > TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : delay;
            clock.Set(after + delay);
        }

        if (clock.Now < to)
        {
            clock.Set(to);
        }

        DateTimeOffset? ended = null;
        try
        {
            await observer.EndAsync(
                to,
                cancellationToken,
                at =>
                {
                    ended = at;
                    evidenceEnded?.Invoke(at);
                },
                clock);
        }
        finally
        {
            var released = ended ?? clock.Now;
            span.Ended(observer.Target, released);
            span.Close(released);
        }
    }
}
