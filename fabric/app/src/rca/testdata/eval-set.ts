// The Incident RCA's evaluation set, Phase 1 (ADR 0031): questions a viewer might ask, the tool calls the investigation
// playbook leads to, the facts each answer must rest on, and the answer key each is graded against offline. Test-only: it
// names scenarios, which no blind question or output may. Phase 3 asks the same questions of the real model.
//
// The data: the contract's two fixtures (T1's blocking chain; T4's locking and its replica's stall, from a real local
// PostgreSQL primary and standby), and B's and A's live rows (dbhubrb's session 2233e0ae and dbhubra, 2026-11-21), each
// with its answer key. B's key file records only the connection surges, and not the one from 18:51, whose session Stop
// now cut off, so its other cases check facts, not the key.

/** Which data a case reads: a contract fixture, or an environment's live rows. */
export type EvalData = "t1" | "t4" | "rb" | "ra";

export interface EvalStep {
    tool: string;
    args: Record<string, unknown>;
}

export interface EvalCase {
    id: string;
    /** As a viewer would ask it: never a scenario's name, or what was injected. */
    question: string;
    data: EvalData;
    /** The tool calls the playbook leads to, with blind arguments: times, targets, and keys the tools themselves listed. */
    steps: EvalStep[];
    /** Regular expressions, each of which must match the steps' combined output. */
    mustContain: string[];
    /** Regular expressions none of which may match it: a wrong cause. */
    mustNotContain?: string[];
    /** The rule that must give the root cause of one of the steps. */
    rootCauseRule?: string;
    /** The answer key's run the answer is graded against; null when the data's key doesn't record one, with why. */
    key: { scenario: string; target: string } | null;
    note?: string;
}

/**
 * Each dataset's minutes, for the incident list the grading reads: the fixtures' own, and the whole day of B's and A's live
 * rows, so no run their keys record is left out (the review of b4370565: B's run from 19:30 was, and nothing said so).
 */
export const EVAL_WINDOWS: Record<EvalData, { from: string; to: string }> = {
    t1: { from: "2026-11-20T16:45:00Z", to: "2026-11-20T17:10:00Z" },
    t4: { from: "2026-11-20T16:55:00Z", to: "2026-11-20T17:25:00Z" },
    rb: { from: "2026-11-21T00:00:00Z", to: "2026-11-21T23:59:59Z" },
    ra: { from: "2026-11-21T00:00:00Z", to: "2026-11-21T23:59:59Z" },
};

/**
 * The families of T4's beats, with the target each shows on: the scoreboard doesn't grade them (a fault on T4 is Not
 * supported there), and the notebook's SCENARIO_SIGNALS doesn't map them. Every other scenario's families are the
 * scoreboard's (expectedFamilies), and so is the rest of the rule (ADR 0031): an episode of one of its families on its
 * target, in the bin that holds its start or later, before TELEMETRY_LAG_MINUTES after its end or the start of the next
 * fault on its target that raises the same signal, whichever comes first (inSearch, searchEndOf), or one still open at its
 * start, in the bin that holds that start. An episode has no values per bin, so a one-bin dip at the fault's start is in it,
 * and its level is the notebook's, not the scoreboard's bound over its baseline: eval.test.ts pins what that leaves apart.
 */
export const T4_BEATS: Record<string, { families: string[]; target?: string }> = {
    "replica-lag": { families: ["replica_lag"], target: "T4-replica" },
    "connection-surge": { families: ["connections", "errors"] },
};

/** Runs a dataset's key records that its data can't grade, with why: neither caught nor missed. */
export const NOT_GRADABLE: Partial<Record<EvalData, Record<string, string>>> = {
    t1: { "log-flush-waits": "its family, tran_log, comes from Database Hub's wait categories, and the t1 fixture's tools get no telemetry, only the capture" },
};

/** Episodes of a family the key grades that its file has no run for, though the demo ran one, with why: never a false alarm. */
export const NO_KEY_ROW: Partial<Record<EvalData, Record<string, string>>> = {
    rb: { "T4-connections-20261121T185152Z": "the surge from 18:51 ran in session ea2b7967, which Stop now cut off, so B's key file has no row for it" },
};

const t1 = { from: "2026-11-20T16:45:00Z", to: "2026-11-20T17:10:00Z" };
const t4 = { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:13:00Z" };

export const EVAL_SET: EvalCase[] = [
    {
        id: "P01-t1-blocking",
        question: "Who blocked whom on T1 between 16:45 and 17:10 UTC on 20 November, and what should we do?",
        data: "t1",
        steps: [{ tool: "explain_locking", args: { ...t1, targets: ["T1"] } }],
        mustContain: [
            "usp_assign_work_item",
            "sat idle with its transaction open",
            "2 branches, 4 levels deep",
            "X KEY lock on \\[care\\]\\.\\[work_queues\\]",
            "BLK-ESCALATION",
            "table lock on \\[care\\]\\.\\[appointments\\]",
            "BLK-COMMIT",
            "BLK-XACT-ABORT",
            "ESC-BATCH",
        ],
        rootCauseRule: "BLK-IDLE-HEAD",
        key: { scenario: "blocking-chain", target: "T1" },
    },
    {
        id: "P02-t1-errors",
        question: "What errors did the app hit on T1 in those minutes?",
        data: "t1",
        steps: [{ tool: "explain_errors", args: { ...t1, targets: ["T1"] } }],
        mustContain: ["Lock timeouts", "\\b30\\b", "usp_route_work_item", "behind a blocker", "BLK-LOCK-TIMEOUT"],
        mustNotContain: ["ERR-THROTTLED", "ERR-DEADLOCK"],
        rootCauseRule: "ERR-LOCK-TIMEOUT",
        key: { scenario: "blocking-chain", target: "T1" },
    },
    {
        id: "P03-t1-quiet",
        question: "Was anything wrong on T1 from 16:40 to 16:52 UTC on 20 November?",
        data: "t1",
        steps: [{ tool: "triage_window", args: { from: "2026-11-20T16:40:00Z", to: "2026-11-20T16:52:00Z", targets: ["T1"] } }],
        mustContain: ['"nothingAbnormal":true'],
        mustNotContain: ["TRIAGE-"],
        key: null,
        note: "The key's first run starts at 16:52, after these minutes: nothing found is the right answer.",
    },
    {
        id: "P04-t4-locking",
        question: "Who blocked whom on T4 between 17:00 and 17:13 UTC on 20 November, and what should we do?",
        data: "t4",
        steps: [{ tool: "explain_locking", args: { ...t4, targets: ["T4"] } }],
        mustContain: ["usp_reprioritize_queue", "sat idle with its transaction open", "row locks on care\\.work_queues", "transaction ID", "BLK-COMMIT", "PG-IDLE-TIMEOUT", "PG-LOCK-TIMEOUT"],
        mustNotContain: ["BLK-IDLE-HEAD"],
        rootCauseRule: "BLK-PG-IDLE-IN-TRANSACTION",
        key: { scenario: "locking-blocking", target: "T4" },
    },
    {
        id: "P05-t4-replica",
        question: "Why did the read replica fall behind at 17:14 UTC on 20 November?",
        data: "t4",
        steps: [{ tool: "explain_replica_lag", args: { at: "2026-11-20T17:14:00Z" } }],
        mustContain: [
            "replay stood still",
            "AccessExclusiveLock on demo\\.replica_lag_marks",
            "AccessShareLock",
            "neither the network nor the write volume caused it",
            "nothing was cancelled",
            "RPL-SHORT-REPORTS",
            "RPL-STANDBY-DELAY",
            "RPL-NO-EXCLUSIVE",
        ],
        mustNotContain: ["REPL-SHIPPING", "REPL-REPLAY-SLOW", "REPL-CATCHUP", "REPL-IDLE-PRIMARY", "REPL-UNEXPLAINED"],
        rootCauseRule: "REPL-REPLAY-CONFLICT",
        key: { scenario: "replica-lag", target: "T4" },
    },
    {
        id: "P06-t4-quiet",
        question: "Was anything wrong on T4 or its replica from 17:16 to 17:24 UTC on 20 November?",
        data: "t4",
        steps: [{ tool: "triage_window", args: { from: "2026-11-20T17:16:00Z", to: "2026-11-20T17:24:00Z", targets: ["T4", "T4-replica"] } }],
        mustContain: ['"nothingAbnormal":true'],
        mustNotContain: ["TRIAGE-"],
        key: null,
        note: "The key's runs end by 17:15, before these minutes.",
    },
    {
        id: "P07-rb-connections",
        question: "Why did T4 run out of connections at 15:27 UTC on 21 November?",
        data: "rb",
        steps: [
            { tool: "triage_window", args: { at: "2026-11-21T15:27:00Z" } },
            { tool: "explain_incident", args: { episodeKey: "T4-connections-20261121T152641Z" } },
        ],
        mustContain: ["T4-connections-20261121T152641Z", "35 of the 35 slots clients can use", "max_connections 50 less 15 reserved", "in 4 waves", "sat idle", "PG-POOL", "PG-IDLE-SESSION-TIMEOUT"],
        mustNotContain: ["CONN-ACTIVE", "CONN-LOCK-WAIT"],
        rootCauseRule: "CONN-IDLE",
        key: { scenario: "connection-surge", target: "T4" },
    },
    {
        id: "P08-ra-connections",
        question: "Why did T4's connections reach the limit at 13:08 UTC on 21 November?",
        data: "ra",
        steps: [
            { tool: "triage_window", args: { at: "2026-11-21T13:09:00Z" } },
            { tool: "explain_incident", args: { episodeKey: "T4-connections-20261121T130832Z" } },
        ],
        mustContain: ["T4-connections-20261121T130832Z", "34 of the 35 slots clients can use", "in 2 waves", "sat idle", "PG-POOL"],
        rootCauseRule: "CONN-IDLE",
        key: { scenario: "connection-surge", target: "T4" },
    },
    {
        id: "P09-rb-replica",
        question: "Why did the read replica fall behind at 16:19 UTC on 21 November?",
        data: "rb",
        steps: [{ tool: "explain_replica_lag", args: { at: "2026-11-21T16:19:00Z" } }],
        mustContain: ["replay stood still", "AccessExclusiveLock on demo\\.replica_lag_marks", "AccessShareLock", "back to 0\\.4 s at 16:19:27 UTC", "RPL-SHORT-REPORTS"],
        mustNotContain: ["REPL-SHIPPING", "REPL-REPLAY-SLOW", "REPL-UNEXPLAINED"],
        rootCauseRule: "REPL-REPLAY-CONFLICT",
        key: null,
        note: "B's key file records only the connection surges: the replica's stall is checked against its facts.",
    },
    {
        id: "P10-rb-errors",
        question: "What errors did the app hit from 15:20 to 17:00 UTC on 21 November?",
        data: "rb",
        steps: [{ tool: "explain_errors", args: { from: "2026-11-21T15:20:00Z", to: "2026-11-21T17:00:00Z" } }],
        mustContain: ["Throttled requests \\(429\\)", "27808", "the container's clients", "RU-RETRY"],
        rootCauseRule: "ERR-THROTTLED",
        key: null,
        note: "B's key file records only the connection surges: T5's storms are checked against their facts.",
    },
    {
        id: "P11-rb-throughput",
        question: "Why was T5 throttled from 15:31 UTC on 21 November?",
        data: "rb",
        steps: [
            { tool: "find_incidents", args: { from: "2026-11-21T15:25:00Z", to: "2026-11-21T15:45:00Z", targets: ["T5"] } },
            { tool: "explain_incident", args: { episodeKey: "T5-ru-20261121T153100Z" } },
        ],
        mustContain: ["T5-ru-20261121T153100Z", "reached 100 %", "throttled \\(429, 53\\.3 %\\)", "more than the 5 % of requests", "RU-RETRY", "RU-AUTOSCALE"],
        rootCauseRule: "RU-THROTTLED",
        key: null,
        note: "B's key file records only the connection surges: T5's storm is checked against its facts.",
    },
    {
        id: "P12-rb-quiet",
        question: "Was anything wrong on T4 from 17:05 to 17:20 UTC on 21 November?",
        data: "rb",
        steps: [{ tool: "triage_window", args: { from: "2026-11-21T17:05:00Z", to: "2026-11-21T17:20:00Z", targets: ["T4"] } }],
        mustContain: ['"nothingAbnormal":true'],
        mustNotContain: ["TRIAGE-"],
        key: null,
        note: "B's key has no surge run in these minutes: its third ends at 16:34:13 UTC, and its fourth starts at 19:30:04 UTC.",
    },
];
