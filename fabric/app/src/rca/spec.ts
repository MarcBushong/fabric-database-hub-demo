// The detection tables as the contract names them (rca/history-tables.json): each field the app reads, by its lakehouse
// column (the evidence document's or the sidecar's) and its model column (what DAX returns). spec.test.ts checks every
// name here against the contract, so a renamed column fails the app's tests before it fails a query.

/**
 * How a field is read. An `id` is a 64-bit integer (the contract's long) read as its exact digits: PostgreSQL's Query
 * Store query_id is a hash past what a JavaScript number holds exactly (2^53), so the loader converts it to text in DAX
 * and the sidecar decoder keeps its source digits (rca/fixtures/README.md).
 */
export type FieldKind = "string" | "timestamp" | "number" | "boolean" | "id";

export interface FieldName {
    lake: string;
    model: string;
    kind: FieldKind;
}

/** One table as the app reads it: its names, its fields, and how a window bounds its rows. */
export interface TableSpec {
    readonly lake: string;
    readonly model: string;
    /** The field a read orders its rows by, oldest first; it bounds them too, unless the table has an `end`. */
    readonly time: string;
    /** An interval table's end field: a read keeps every row whose span overlaps the window, as RCA Coverage's one row of a session exported once. */
    readonly end?: string;
    /** More spans, start and end fields, any of which keeps a row when it overlaps the window: RCA Query Coverage's intervals read, and its pending publication. */
    readonly spans?: ReadonlyArray<readonly [string, string]>;
    readonly fields: Readonly<Record<string, FieldName>>;
}

const f = (lake: string, model: string, kind: FieldKind = "string"): FieldName => ({ lake, model, kind });

export const RCA_SPEC = {
    sessions: {
        lake: "rca_sessions",
        model: "RCA Sessions",
        time: "capturedAt",
        fields: {
            capturedAt: f("captured_at_utc", "Captured At UTC", "timestamp"),
            target: f("target", "Target Key"),
            session: f("session_id", "Session ID", "number"),
            blockedBy: f("blocked_by", "Blocked By"),
            status: f("status", "Status"),
            waitType: f("wait_type", "Wait Type"),
            waitMs: f("wait_ms", "Wait (ms)", "number"),
            waitResource: f("wait_resource", "Wait Resource"),
            lockResourceType: f("lock_resource_type", "Lock Resource Type"),
            lockObject: f("lock_object", "Lock Object"),
            lockIndex: f("lock_index", "Lock Index"),
            lockModeWanted: f("lock_mode_wanted", "Lock Mode Wanted"),
            lockModeHeld: f("lock_mode_held", "Lock Mode Held"),
            openTransactions: f("open_transactions", "Open Transactions", "number"),
            transactionAgeMs: f("transaction_age_ms", "Transaction Age (ms)", "number"),
            idleMs: f("idle_ms", "Idle (ms)", "number"),
            login: f("login_name", "Login"),
            host: f("host_name", "Host"),
            program: f("program_name", "Program"),
            runToken: f("run_token", "Run Token"),
            module: f("module_name", "Module"),
            statement: f("statement_text", "Statement"),
            inputBuffer: f("input_buffer", "Input Buffer"),
            backendType: f("backend_type", "Backend Type"),
            isDemo: f("is_demo", "Is Workload Session", "boolean"),
        },
    },
    events: {
        lake: "rca_events",
        model: "RCA Events",
        time: "at",
        fields: {
            at: f("event_time_utc", "Event Time UTC", "timestamp"),
            target: f("target", "Target Key"),
            kind: f("kind", "Kind"),
            name: f("event_name", "Event Name"),
            session: f("session_id", "Session ID", "number"),
            program: f("program_name", "Program"),
            runToken: f("run_token", "Run Token"),
            login: f("login_name", "Login"),
            host: f("host_name", "Host"),
            module: f("module_name", "Module"),
            code: f("code", "Code"),
            severity: f("severity", "Severity", "number"),
            intercepted: f("intercepted", "Intercepted", "boolean"),
            count: f("event_count", "Event Count", "number"),
            object: f("object_name", "Object"),
            mode: f("lock_mode", "Lock Mode"),
            detail: f("detail", "Detail"),
            deadlock: f("deadlock_json", "Deadlock JSON"),
        },
    },
    resource: {
        lake: "rca_resource",
        model: "RCA Resource",
        time: "at",
        fields: {
            at: f("at_utc", "At UTC", "timestamp"),
            target: f("target", "Target Key"),
            source: f("source", "Source"),
            metric: f("metric", "Metric"),
            value: f("value", "Value", "number"),
            unit: f("unit", "Unit"),
        },
    },
    replica: {
        lake: "rca_replica",
        model: "RCA Replica",
        time: "at",
        fields: {
            at: f("at_utc", "At UTC", "timestamp"),
            target: f("target", "Target Key"),
            side: f("side", "Side"),
            standby: f("standby_name", "Standby"),
            sinceLastReplayS: f("since_last_replayed_s", "Since Last Replayed (s)", "number"),
            receivedNotReplayedBytes: f("received_not_replayed_bytes", "Received Not Replayed (bytes)", "number"),
            replayLagS: f("replay_lag_s", "Replay Lag (s)", "number"),
            writeLagS: f("write_lag_s", "Write Lag (s)", "number"),
            flushLagS: f("flush_lag_s", "Flush Lag (s)", "number"),
            sendGapBytes: f("send_gap_bytes", "Send Gap (bytes)", "number"),
            walBytesPerS: f("wal_bytes_per_s", "WAL Bytes/s", "number"),
            startupWait: f("startup_wait", "Startup Wait"),
            conflictRelation: f("conflict_relation", "Conflict Relation"),
            conflictWantedMode: f("conflict_wanted_mode", "Conflict Wanted Mode"),
            conflictWaitStart: f("conflict_wait_start_utc", "Conflict Wait Start UTC", "timestamp"),
            conflictHolder: f("conflict_holder_session", "Conflict Holder Session", "number"),
            conflictHolderMode: f("conflict_holder_mode", "Conflict Holder Mode"),
            conflictHolderProgram: f("conflict_holder_program", "Conflict Holder Program"),
            conflictHolderRunToken: f("conflict_holder_run_token", "Conflict Holder Run Token"),
            conflictHolderStatement: f("conflict_holder_statement", "Conflict Holder Statement"),
            conflictsCancelled: f("conflicts_cancelled", "Conflicts Cancelled", "number"),
            maxStandbyStreamingDelayS: f("max_standby_streaming_delay_s", "Max Standby Streaming Delay (s)", "number"),
        },
    },
    coverage: {
        lake: "rca_coverage",
        model: "RCA Coverage",
        time: "from",
        end: "to",
        fields: {
            target: f("target", "Target Key"),
            from: f("window_start_utc", "Window Start UTC", "timestamp"),
            to: f("window_end_utc", "Window End UTC", "timestamp"),
            captured: f("captured", "Captured", "boolean"),
            sources: f("sources", "Sources"),
            gaps: f("gaps", "Gaps"),
        },
    },
    waits: {
        lake: "rca_waits",
        model: "RCA Waits",
        time: "from",
        end: "to",
        fields: {
            target: f("target", "Target Key"),
            episodeId: f("episode_id", "Episode ID"),
            phase: f("phase", "Phase"),
            from: f("window_start_utc", "Window Start UTC", "timestamp"),
            to: f("window_end_utc", "Window End UTC", "timestamp"),
            waitType: f("wait_type", "Wait Type"),
            category: f("wait_category", "Wait Category"),
            waitMs: f("wait_ms", "Wait (ms)", "number"),
            waitingTasks: f("waiting_tasks", "Waiting Tasks", "number"),
            signalMs: f("signal_ms", "Signal Wait (ms)", "number"),
            maxWaitMs: f("max_wait_ms", "Max Wait (ms)", "number"),
        },
    },
} as const satisfies Record<string, TableSpec>;

export type RcaTableKey = keyof typeof RCA_SPEC;

/**
 * The sidecar's tables (rca/README.md, The sidecar): Query Store's statistics, waits, plans, and events on T1 to T4, what
 * the capture read of Query Store, and who held T4's connections. Each is its own document's, never the evidence's.
 */
export const SIDECAR_SPEC = {
    queryStats: {
        lake: "rca_query_stats",
        model: "RCA Query Stats",
        time: "intervalStart",
        end: "intervalEnd",
        fields: {
            capturedAt: f("captured_at_utc", "Captured At UTC", "timestamp"),
            target: f("target", "Target Key"),
            intervalStart: f("interval_start_utc", "Interval Start UTC", "timestamp"),
            intervalEnd: f("interval_end_utc", "Interval End UTC", "timestamp"),
            queryId: f("query_id", "Query ID", "id"),
            planId: f("plan_id", "Plan ID", "id"),
            login: f("login_name", "Login"),
            queryHash: f("query_hash", "Query Hash"),
            planHash: f("plan_hash", "Plan Hash"),
            module: f("module_name", "Module"),
            statement: f("statement_text", "Statement"),
            executions: f("executions", "Executions", "number"),
            abortedExecutions: f("aborted_executions", "Aborted Executions", "number"),
            cpuMs: f("cpu_ms", "CPU (ms)", "number"),
            durationMs: f("duration_ms", "Duration (ms)", "number"),
            maxDurationMs: f("max_duration_ms", "Max Duration (ms)", "number"),
            logicalReads: f("logical_reads", "Logical Reads", "number"),
            physicalReads: f("physical_reads", "Physical Reads", "number"),
            rows: f("row_count", "Rows", "number"),
            logBytes: f("log_bytes", "Log Bytes", "number"),
            tempdbKb: f("tempdb_kb", "Tempdb (KB)", "number"),
            maxMemoryKb: f("max_used_memory_kb", "Max Memory Grant (KB)", "number"),
            maxDop: f("max_dop", "Max DOP", "number"),
            waitMs: f("wait_ms", "Wait (ms)", "number"),
            firstExecution: f("first_execution_utc", "First Execution UTC", "timestamp"),
            lastExecution: f("last_execution_utc", "Last Execution UTC", "timestamp"),
        },
    },
    queryWaits: {
        lake: "rca_query_waits",
        model: "RCA Query Waits",
        time: "intervalStart",
        end: "intervalEnd",
        fields: {
            capturedAt: f("captured_at_utc", "Captured At UTC", "timestamp"),
            target: f("target", "Target Key"),
            intervalStart: f("interval_start_utc", "Interval Start UTC", "timestamp"),
            intervalEnd: f("interval_end_utc", "Interval End UTC", "timestamp"),
            queryId: f("query_id", "Query ID", "id"),
            planId: f("plan_id", "Plan ID", "id"),
            login: f("login_name", "Login"),
            category: f("wait_category", "Wait Category"),
            event: f("wait_event", "Wait Event"),
            waitMs: f("wait_ms", "Wait (ms)", "number"),
            maxWaitMs: f("max_wait_ms", "Max Wait (ms)", "number"),
            samples: f("samples", "Samples", "number"),
        },
    },
    queryPlans: {
        lake: "rca_query_plans",
        model: "RCA Query Plans",
        time: "capturedAt",
        fields: {
            capturedAt: f("captured_at_utc", "Captured At UTC", "timestamp"),
            target: f("target", "Target Key"),
            queryId: f("query_id", "Query ID", "id"),
            planId: f("plan_id", "Plan ID", "id"),
            queryHash: f("query_hash", "Query Hash"),
            planHash: f("plan_hash", "Plan Hash"),
            module: f("module_name", "Module"),
            statement: f("statement_text", "Statement"),
            compiled: f("compiled_utc", "Compiled UTC", "timestamp"),
            lastCompiled: f("last_compiled_utc", "Last Compiled UTC", "timestamp"),
            lastExecution: f("last_execution_utc", "Last Execution UTC", "timestamp"),
            compiles: f("compiles", "Compiles", "number"),
            isForced: f("is_forced_plan", "Is Forced Plan", "boolean"),
            forcingType: f("forcing_type", "Forcing Type"),
            forceFailures: f("force_failures", "Force Failures", "number"),
            lastForceFailure: f("last_force_failure", "Last Force Failure"),
            plansForQuery: f("plans_for_query", "Plans For Query", "number"),
            estimatedCost: f("estimated_cost", "Estimated Cost", "number"),
            isParallel: f("is_parallel", "Is Parallel", "boolean"),
            summary: f("plan_summary", "Plan Summary"),
        },
    },
    queryEvents: {
        lake: "rca_query_events",
        model: "RCA Query Events",
        time: "at",
        fields: {
            at: f("event_time_utc", "Event Time UTC", "timestamp"),
            from: f("time_from_utc", "Time From UTC", "timestamp"),
            target: f("target", "Target Key"),
            kind: f("kind", "Kind"),
            queryId: f("query_id", "Query ID", "id"),
            planId: f("plan_id", "Plan ID", "id"),
            forcingType: f("forcing_type", "Forcing Type"),
            state: f("state", "State"),
            previousState: f("previous_state", "Previous State"),
            detail: f("detail", "Detail"),
        },
    },
    queryCoverage: {
        lake: "rca_query_coverage",
        model: "RCA Query Coverage",
        time: "from",
        end: "to",
        // A backfill's row can be a later sidecar's, whose window isn't the minutes it read (rca/README.md, Pending publication).
        spans: [
            ["readFrom", "readTo"],
            ["pendingFrom", "pendingTo"],
        ],
        fields: {
            target: f("target", "Target Key"),
            from: f("window_start_utc", "Window Start UTC", "timestamp"),
            to: f("window_end_utc", "Window End UTC", "timestamp"),
            state: f("state", "Query Store State"),
            captureMode: f("capture_mode", "Capture Mode"),
            intervalMinutes: f("interval_minutes", "Interval (min)", "number"),
            readFrom: f("read_from_utc", "Read From UTC", "timestamp"),
            readTo: f("read_to_utc", "Read To UTC", "timestamp"),
            pendingFrom: f("pending_from_utc", "Pending From UTC", "timestamp"),
            pendingTo: f("pending_to_utc", "Pending To UTC", "timestamp"),
            backfill: f("backfill", "Backfill", "boolean"),
            sources: f("sources", "Sources"),
            gaps: f("gaps", "Gaps"),
        },
    },
    connections: {
        lake: "rca_connections",
        model: "RCA Connections",
        time: "capturedAt",
        fields: {
            capturedAt: f("captured_at_utc", "Captured At UTC", "timestamp"),
            target: f("target", "Target Key"),
            program: f("program_name", "Program"),
            runToken: f("run_token", "Run Token"),
            login: f("login_name", "Login"),
            state: f("state", "State"),
            connections: f("connections", "Connections", "number"),
            waitingLock: f("waiting_lock", "Waiting On A Lock", "number"),
            oldestStateS: f("oldest_state_s", "Oldest State (s)", "number"),
            oldestConnectionS: f("oldest_connection_s", "Oldest Connection (s)", "number"),
            isDemo: f("is_demo", "Is Workload Session", "boolean"),
        },
    },
} as const satisfies Record<string, TableSpec>;

export type SidecarTableKey = keyof typeof SIDECAR_SPEC;

/** Every sidecar table, as the Query Store reads load them. */
export const SIDECAR_TABLES = Object.keys(SIDECAR_SPEC) as SidecarTableKey[];

/** The tables Phase 1 reads; RCA Waits comes with Phase 2's capture. */
export const PHASE_1_TABLES: readonly RcaTableKey[] = ["sessions", "events", "resource", "replica", "coverage"];

/** The model's target dimension, which every RCA table relates to. */
export const TARGET_KEY = { table: "Target", column: "Target Key" } as const;
