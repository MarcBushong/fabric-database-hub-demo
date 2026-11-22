// Incident RCA (ADR 0031): the evidence rows as the app reads them from SM_DatabaseHub_History, one interface per
// detection table of the contract (rca/history-tables.json), and the shapes the investigations return. Blind: no row
// carries what the demo planned or ran; a workload session is known only by its program and an opaque run token.
// Every time is UTC. Text fields hold normalized text only, and only for the workload's own sessions.

export type RcaTarget = "T1" | "T2" | "T3" | "T4" | "T4-replica" | "T5";

export const RCA_TARGETS: readonly RcaTarget[] = ["T1", "T2", "T3", "T4", "T4-replica", "T5"];

export const isRcaTarget = (value: unknown): value is RcaTarget => typeof value === "string" && (RCA_TARGETS as readonly string[]).includes(value);

/** Without a time, an investigation reads the history's newest minutes: a session's length. */
export const NEWEST_MINUTES = 90;

/** 'RCA Sessions': one session in one blocking sample. SQL Server and PostgreSQL share it. */
export interface SessionSample {
    target: RcaTarget;
    capturedAt: Date;
    session: number;
    /** Who this session waits on: one session on SQL Server (negative values are the documented special owners), every pid of pg_blocking_pids or pg_locks on PostgreSQL; empty when it isn't blocked. */
    blockedBy: number[];
    /** The request's status (running, runnable, suspended) or the session's (sleeping); PostgreSQL's state (active, idle in transaction). */
    status: string;
    /** SQL Server wait_type, or PostgreSQL "wait_event_type:wait_event". */
    waitType?: string;
    waitMs?: number;
    waitResource?: string;
    /** KEY, PAGE, RID, OBJECT, XACT; or PostgreSQL's locktype (transactionid, relation, tuple). */
    lockResourceType?: string;
    lockObject?: string;
    lockIndex?: string;
    /** The mode this session waits for. */
    lockModeWanted?: string;
    /** The mode this session holds on the resource others wait for. */
    lockModeHeld?: string;
    openTransactions: number;
    transactionAgeMs?: number;
    /** How long an idle session (sleeping, or idle in transaction) has been idle. */
    idleMs?: number;
    login?: string;
    host?: string;
    program?: string;
    /** An opaque token that groups one workload run's sessions; it names nothing. */
    runToken?: string;
    /** The module the statement belongs to, [schema].[name], or the PostgreSQL function the statement calls. */
    module?: string;
    statement?: string;
    inputBuffer?: string;
    backendType?: string;
    /** The workload's own session: only these keep text, login, and host. Rules never use it to tell one cause from another. */
    isDemo: boolean;
}

export type EventKind = "error" | "attention" | "deadlock" | "escalation" | "tuning" | "capture";

/** A deadlock graph reduced to what the rules read (rca/README.md, Deadlocks). */
export interface DeadlockSummary {
    victim: number;
    processes: Array<{ session: number; program?: string; runToken?: string; module?: string; statement?: string; holds?: string; wants?: string; waitResource?: string }>;
    resources: Array<{ type: string; object?: string; index?: string; mode?: string; holder?: number; waiter?: number }>;
}

/** 'RCA Events': errors, attentions, deadlocks, escalations, tuning changes, and the capture's own episodes. */
export interface EventRow {
    target: RcaTarget;
    at: Date;
    kind: EventKind;
    /** The source event (error_reported, lock_escalation, ...), or for a capture episode: escalated or relaxed. */
    name?: string;
    session?: number;
    program?: string;
    runToken?: string;
    login?: string;
    host?: string;
    module?: string;
    /** SQL Server error number or PostgreSQL SQLSTATE; for a capture episode, its ID. */
    code?: string;
    severity?: number;
    intercepted?: boolean;
    count: number;
    /** An Azure Monitor count's interval (countedErrors): the count is for `at` up to `at` plus this. Absent for an event. */
    intervalMs?: number;
    object?: string;
    mode?: string;
    detail: string;
    deadlock?: DeadlockSummary;
}

/** 'RCA Waits' (Phase 2): one wait type's delta over an episode or its baseline. */
export interface WaitDelta {
    target: RcaTarget;
    episodeId?: string;
    phase: "baseline" | "episode";
    from: Date;
    to: Date;
    waitType: string;
    category?: string;
    waitMs: number;
    waitingTasks?: number;
    signalMs?: number;
    maxWaitMs?: number;
}

/** 'RCA Resource': long-format samples: the sentinel's counters, connections, and T3's resource rows (RCA-AZ-01). */
export interface ResourcePoint {
    target: RcaTarget;
    at: Date;
    /** The capture ID that read it. */
    source: string;
    metric: string;
    value: number;
    unit?: string;
}

/** 'RCA Replica': replay state and conflicts, from the replica's and the primary's side. */
export interface ReplicaSample {
    target: RcaTarget;
    at: Date;
    side: "primary" | "replica";
    standby?: string;
    sinceLastReplayS?: number;
    receivedNotReplayedBytes?: number;
    replayLagS?: number;
    writeLagS?: number;
    flushLagS?: number;
    sendGapBytes?: number;
    walBytesPerS?: number;
    startupWait?: string;
    conflictRelation?: string;
    conflictWantedMode?: string;
    conflictWaitStart?: Date;
    conflictHolder?: number;
    conflictHolderMode?: string;
    conflictHolderProgram?: string;
    conflictHolderRunToken?: string;
    conflictHolderStatement?: string;
    conflictsCancelled?: number;
    maxStandbyStreamingDelayS?: number;
}

/** 'RCA Coverage': what was captured for a target and window, and why anything wasn't. */
export interface Coverage {
    target: RcaTarget;
    from: Date;
    to: Date;
    captured: boolean;
    sources: string[];
    gaps: string[];
}

/** A metric point the history saves from Database Hub's telemetry or Azure Monitor (Telemetry Snapshots). */
export interface MetricPoint {
    target: RcaTarget;
    at: Date;
    metric: string;
    value: number | null;
    /** Azure Monitor's interval: the value is the interval's highest (or its total) from `at` to `at` plus this. */
    intervalMs?: number;
    /** The interval of the save it comes from, which a remainder of a coarser point spans only part of (the shared finestPerInterval's grains): what its value is the highest or the total of. */
    grainMs?: number;
    /** A piece of a coarser point split across two or more stretches: the one reading it's part of (sources.ts's wholeReadings). */
    whole?: WholeReading;
    /** Its interval isn't known in these minutes: the read held too few of its save's points to tell its step. */
    intervalUnknown?: boolean;
}

/**
 * A coarser point's whole reading, which the shared finestPerInterval split into two or more pieces: its raw value over
 * its interval (cut to its save's window, as the shared function cuts it), from `at` for `intervalMs`, of its save's step
 * (grainMs); for a total, how much the finer saves hold of it (finer: null for a peak, or when that isn't known), in the
 * minutes they cover (covered).
 */
export interface WholeReading {
    key: string;
    at: Date;
    intervalMs: number;
    grainMs: number;
    value: number;
    finer: number | null;
    covered: Array<{ from: Date; to: Date }>;
}

/**
 * Whether a metric point falls in a window. An Azure Monitor point stands for its whole interval, from `at` up to its end:
 * one that started before the window but runs into it does, and one that starts at the window's end doesn't (the review of
 * 4e2c65ed: two adjacent windows both counted it). An instant at the window's end does.
 */
export const metricIn = (m: MetricPoint, from: Date, to: Date) => {
    const start = m.at.getTime();
    const span = m.intervalMs ?? 0;
    // A point whose interval isn't known still stands for minutes from its start, never an instant there (the review of c4c63abe).
    return (span > 0 || m.intervalUnknown ? start < to.getTime() : start <= to.getTime()) && start + Math.max(0, span - 1) >= from.getTime();
};

/** One Azure Monitor point's key, by its target, its metric as the history names it, and its interval's start: the shared finestPerInterval's. */
export { pointKey } from "@/data/finest-per-interval";

/**
 * A window's points with each split coarser point's pieces as its one whole reading (MetricPoint.whole): its raw value at
 * its start, over its save's whole interval, and the same metric's points inside that interval left out, since the reading
 * counts them (the review of c4c63abe: its shares by length read as Azure Monitor's counts, each for its own stretch).
 */
export function asWholeReadings(points: readonly MetricPoint[]): MetricPoint[] {
    const byTime = (a: MetricPoint, b: MetricPoint) => a.at.getTime() - b.at.getTime();
    const wholes = new Map<string, MetricPoint>();
    for (const p of points) if (p.whole && !wholes.has(`${p.target}|${p.metric}|${p.whole.key}`)) wholes.set(`${p.target}|${p.metric}|${p.whole.key}`, { ...p, at: p.whole.at, value: p.whole.value, intervalMs: p.whole.intervalMs, grainMs: p.whole.grainMs });
    if (wholes.size === 0) return [...points].sort(byTime);
    const inside = (p: MetricPoint) =>
        [...wholes.values()].some((w) => w.target === p.target && w.metric === p.metric && p.at.getTime() >= w.at.getTime() && p.at.getTime() < w.at.getTime() + (w.intervalMs ?? 0));
    return [...points.filter((p) => !p.whole && !inside(p)), ...wholes.values()].sort(byTime);
}

/** Everything the investigations read for one window: the RCA tables and the telemetry. Nothing else. */
export interface Evidence {
    sessions: SessionSample[];
    events: EventRow[];
    resource: ResourcePoint[];
    replica: ReplicaSample[];
    waits: WaitDelta[];
    coverage: Coverage[];
    metrics: MetricPoint[];
    /** The reads that returned as many rows as they may, by table: what they hold from `until` on wasn't read (loader.ts, sources.ts). */
    cut?: Array<{ table: string; until: Date }>;
}

export const emptyEvidence = (): Evidence => ({ sessions: [], events: [], resource: [], replica: [], waits: [], coverage: [], metrics: [] });

/** Where the evidence's reads stopped, the earliest of its cut reads (of those `which` names): nothing from then on was read. Null when every read was whole. */
export const readStoppedAt = (evidence: Evidence, which: (table: string) => boolean = () => true): Date | null => {
    const cut = (evidence.cut ?? []).filter((c) => which(c.table));
    return cut.length ? new Date(Math.min(...cut.map((c) => c.until.getTime()))) : null;
};

/** The capture's own tables (RCA Sessions, RCA Events, RCA Resource...), as the loader names their reads. */
export const isRcaTable = (table: string) => table.startsWith("RCA ");

/** One fact a conclusion rests on: the table, the time, and what it says. The chat cites these. */
export interface EvidenceRef {
    table: string;
    at: string;
    target: RcaTarget;
    text: string;
}

export type Confidence = "high" | "medium" | "low";

export type Approver = "Application owner" | "DBA" | "DBA and application owner" | "Service owner (cost)";

export interface Recommendation {
    id: string;
    title: string;
    why: string;
    risk: string;
    /** Who approves it: the app and Copilot only recommend. */
    approver: Approver;
    learn: { title: string; url: string };
}

export interface Finding {
    ruleId: string;
    target: RcaTarget;
    title: string;
    detail: string;
    severity: "critical" | "warning" | "info";
    evidence: EvidenceRef[];
}

/** How an episode was found: in two or more valued samples in a row, across unknown samples, or in one sample (a rule of one sample, or one far over its level). */
export type Support = "sustained" | "sparse" | "single sample";

/** One incident the blind detector found: a signal over its level on a target, for a while. */
export interface Episode {
    /** Stable for its target, family, and start: "<target>-<family>-<yyyyMMddTHHmmssZ>". */
    key: string;
    target: RcaTarget;
    family: string;
    /** What the signal is, in words: "CPU", "blocked processes", "read replica lag". */
    signal: string;
    unit: string;
    start: Date;
    /** The first sample back under the level, confirmed; null when the data ends or breaks off first. */
    end: Date | null;
    /** The last sample at the level. */
    last: Date;
    /** A capture episode with no end whose samples are back under its level after `last`: the first of them, and, when its capture cut it off, the capture's last sample. */
    fellBy?: Date;
    captureEnd?: Date;
    /** A capture episode not relaxed when the minutes read end, while its capture still ran: where they end. Its end is after them. */
    readEnd?: Date;
    peak: number;
    peakAt: Date;
    level: number;
    baseline: number | null;
    /** Samples in its span with a value, and without one. */
    valued: number;
    unknown: number;
    atLevel: number;
    support: Support;
    /** Its readEnd is where a read of the capture's tables stopped short, not where the minutes read end (the review of eb89acbb). */
    readStopped?: boolean;
    /** A single sample that opened it by being far over its level (twice the level, and the rule's points over its baseline), where its rule asks for more than one. */
    severe?: boolean;
    /** Where it was seen: the RCA capture, Database Hub's telemetry, or Azure Monitor. */
    source: string;
    confidence: Confidence;
}

/** What every investigation tool returns: facts first, then the conclusion, then what to do, and what's missing. */
export interface InvestigationResult {
    tool: string;
    version: 1;
    window: { fromUtc: string; toUtc: string; local?: string; asked?: string };
    targets: RcaTarget[];
    /** The blind detector's episodes in the window. */
    episodes: Array<Pick<Episode, "key" | "target" | "family" | "signal" | "support" | "source"> & { start: string; end: string | null; peak: string }>;
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    notCaptured: string[];
    /** Tool-specific structure: the chain tree, the error classes, the lag points. */
    details?: Record<string, unknown>;
}

/** "6 sessions", "1 session": a count with its noun. */
export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

export const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
export const hhmmss = (d: Date) => d.toISOString().slice(11, 19);
/** "between 16:52:10 and 17:00:40" for a range, "at 16:53:10" for one point in time (UTC; the caller adds "UTC"). */
export const during = (first: Date, last: Date) => (first.getTime() === last.getTime() ? `at ${hhmmss(first)}` : `between ${hhmmss(first)} and ${hhmmss(last)}`);
