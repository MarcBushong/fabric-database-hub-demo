// The detection tables as the contract names them (rca/history-tables.json): each field the app reads, by its lakehouse
// column (the evidence document's) and its model column (what DAX returns). spec.test.ts checks every name here against
// the contract, so a renamed column fails the app's tests before it fails a query.

export type FieldKind = "string" | "timestamp" | "number" | "boolean";

export interface FieldName {
    lake: string;
    model: string;
    kind: FieldKind;
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
} as const;

export type RcaTableKey = keyof typeof RCA_SPEC;

/** The tables Phase 1 reads; RCA Waits comes with Phase 2's capture. */
export const PHASE_1_TABLES: readonly RcaTableKey[] = ["sessions", "events", "resource", "replica", "coverage"];

/** The model's target dimension, which every RCA table relates to. */
export const TARGET_KEY = { table: "Target", column: "Target Key" } as const;
