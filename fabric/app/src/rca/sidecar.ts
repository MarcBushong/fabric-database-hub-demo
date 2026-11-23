// The sidecar's rows (rca/README.md, The sidecar): Query Store's statistics, waits, plans, and events on T1 to T4, what
// the capture read of Query Store, and who held T4's connections, as the app reads them from SM_DatabaseHub_History
// (loader.ts's loadSidecar) or from a sidecar document (the contract's fixtures, here). Blind: Query Store records
// statements, never what the demo planned; a workload connection is known only by its program and an opaque run token.
// Every time is UTC.

import { readColumnarTable, type ColumnarTable } from "./evidence";
import { toBool, toDate, toNum, toStr, type Get } from "./rows";
import { SIDECAR_SPEC, type SidecarTableKey } from "./spec";
import { isRcaTarget, type RcaTarget } from "./types";

/** 'RCA Query Stats': one plan's runtime statistics over one Query Store interval, as one read saw them. Totals, execution-weighted by the capture. */
export interface QueryStat {
    target: RcaTarget;
    capturedAt: Date;
    intervalStart: Date;
    intervalEnd: Date;
    /** Query Store's query_id, as its exact digits: PostgreSQL's is a 64-bit hash. */
    queryId: string;
    /** Query Store's plan_id; "0" on PostgreSQL, which stores no plans here. */
    planId: string;
    /** PostgreSQL's role, the workload's own only; absent on SQL Server and for another role's rows. */
    login?: string;
    queryHash?: string;
    planHash?: string;
    module?: string;
    statement?: string;
    executions: number;
    abortedExecutions?: number;
    /** Total CPU in milliseconds; absent on PostgreSQL, whose Query Store records no CPU time. */
    cpuMs?: number;
    durationMs?: number;
    maxDurationMs?: number;
    logicalReads?: number;
    physicalReads?: number;
    rows?: number;
    logBytes?: number;
    tempdbKb?: number;
    maxMemoryKb?: number;
    maxDop?: number;
    waitMs?: number;
    /** When the plan's first execution in the interval ended (Learn's first_execution_time): not the instant a plan changed. */
    firstExecution?: Date;
    lastExecution?: Date;
}

/** 'RCA Query Waits': one wait category (SQL Server) or event (PostgreSQL) of one plan or query over one interval. */
export interface QueryWait {
    target: RcaTarget;
    capturedAt: Date;
    intervalStart: Date;
    intervalEnd: Date;
    queryId: string;
    planId: string;
    login?: string;
    /** SQL Server's wait_category_desc, PostgreSQL's wait_event_type. */
    category: string;
    /** PostgreSQL's wait_event; absent on SQL Server. */
    event?: string;
    /** Milliseconds: SQL Server's measured, PostgreSQL's its samples times the sampling period, an estimate. */
    waitMs: number;
    maxWaitMs?: number;
    /** PostgreSQL's samples; absent on SQL Server. */
    samples?: number;
}

/** 'RCA Query Plans': one plan as one read saw it. */
export interface QueryPlan {
    target: RcaTarget;
    capturedAt: Date;
    queryId: string;
    planId: string;
    queryHash?: string;
    planHash?: string;
    module?: string;
    statement?: string;
    compiled?: Date;
    lastCompiled?: Date;
    lastExecution?: Date;
    compiles?: number;
    isForced?: boolean;
    /** MANUAL, AUTO, or NONE. */
    forcingType?: string;
    forceFailures?: number;
    lastForceFailure?: string;
    plansForQuery?: number;
    estimatedCost?: number;
    isParallel?: boolean;
    /** The plan's shape in words: its costliest operators, warnings, a missing index; never a parameter's value. */
    summary?: string;
}

export type QueryEventKind = "forced" | "unforced" | "state" | "tuning";

const QUERY_EVENT_KINDS: readonly QueryEventKind[] = ["forced", "unforced", "state", "tuning"];

/** 'RCA Query Events': a change in Query Store or automatic tuning, timed within its read's period (from `from` to `at`). */
export interface QueryEvent {
    target: RcaTarget;
    /** When the capture first saw the change. */
    at: Date;
    /** The read before it: the change happened after this. */
    from?: Date;
    kind: QueryEventKind;
    queryId?: string;
    planId?: string;
    forcingType?: string;
    state?: string;
    previousState?: string;
    detail?: string;
}

/** 'RCA Query Coverage': what the capture read of Query Store for a target over one sidecar's window, and what it couldn't. */
export interface QueryCoverage {
    target: RcaTarget;
    from: Date;
    to: Date;
    /** Query Store's actual state (READ_WRITE, READ_ONLY, OFF, ERROR) or PostgreSQL's capture mode; absent when it couldn't be read. */
    state?: string;
    captureMode?: string;
    intervalMinutes?: number;
    readFrom?: Date;
    readTo?: Date;
    /** PostgreSQL only: the minutes its Query Store hadn't published yet when the window ended. */
    pendingFrom?: Date;
    pendingTo?: Date;
    /** It holds intervals read after their session, which Query Store published later. */
    backfill: boolean;
    sources: string[];
    gaps: string[];
}

/** 'RCA Connections': one group of T4's client connections in one sample of a connection episode, counted. */
export interface ConnectionGroup {
    target: RcaTarget;
    capturedAt: Date;
    /** The workload's own connections' program; absent for any other application's. */
    program?: string;
    runToken?: string;
    login?: string;
    /** pg_stat_activity.state: active, idle, idle in transaction, idle in transaction (aborted), or unknown. */
    state: string;
    connections: number;
    waitingLock?: number;
    oldestStateS?: number;
    oldestConnectionS?: number;
    isDemo: boolean;
}

/** Everything the sidecar's tables hold for one window. */
export interface SidecarEvidence {
    stats: QueryStat[];
    waits: QueryWait[];
    plans: QueryPlan[];
    events: QueryEvent[];
    coverage: QueryCoverage[];
    connections: ConnectionGroup[];
    /** The sidecar tables the history's model doesn't have (a model from before them): their rows aren't known, which is never none. */
    missing: string[];
    /**
     * The reads that returned as many rows as they may, by table: what they hold from `until` on wasn't read; for a read
     * newest first (RCA Query Plans), what they hold before `until`.
     */
    cut?: Array<{ table: string; until: Date; newestFirst?: boolean }>;
}

/**
 * How long after a window its plans are read: RCA-SQL-14 reads the plans of the queries each read of RCA-SQL-10 returned,
 * at that read's time, which is up to an interval and 2 minutes after the interval it read (rca/README.md, Query Store).
 */
export const PLAN_LAG_MINUTES = 30;

export const emptySidecar = (): SidecarEvidence => ({ stats: [], waits: [], plans: [], events: [], coverage: [], connections: [], missing: [] });

/** A 64-bit ID as its exact digits: text as it is, or a number only while it's exact (never a rounded one). */
export function toId(value: unknown): string | undefined {
    if (typeof value === "string") return /^-?\d+$/.test(value.trim()) ? value.trim() : undefined;
    if (typeof value === "number" && Number.isSafeInteger(value)) return String(value);
    return undefined;
}

const lines = (value: unknown, split: RegExp) =>
    (toStr(value) ?? "")
        .split(split)
        .map((s) => s.trim())
        .filter(Boolean);

/** Only the fields with a value, so optional fields stay absent rather than undefined. */
function clean<T extends object>(row: T): T {
    for (const key of Object.keys(row) as Array<keyof T>) if (row[key] === undefined) delete row[key];
    return row;
}

export function queryStatFrom(get: Get): QueryStat | null {
    const target = get("target");
    const capturedAt = toDate(get("capturedAt"));
    const intervalStart = toDate(get("intervalStart"));
    const intervalEnd = toDate(get("intervalEnd"));
    const queryId = toId(get("queryId"));
    const planId = toId(get("planId"));
    const executions = toNum(get("executions"));
    if (!isRcaTarget(target) || !capturedAt || !intervalStart || !intervalEnd || !queryId || !planId || executions === undefined) return null;
    return clean<QueryStat>({
        target,
        capturedAt,
        intervalStart,
        intervalEnd,
        queryId,
        planId,
        login: toStr(get("login")),
        queryHash: toStr(get("queryHash")),
        planHash: toStr(get("planHash")),
        module: toStr(get("module")),
        statement: toStr(get("statement")),
        executions,
        abortedExecutions: toNum(get("abortedExecutions")),
        cpuMs: toNum(get("cpuMs")),
        durationMs: toNum(get("durationMs")),
        maxDurationMs: toNum(get("maxDurationMs")),
        logicalReads: toNum(get("logicalReads")),
        physicalReads: toNum(get("physicalReads")),
        rows: toNum(get("rows")),
        logBytes: toNum(get("logBytes")),
        tempdbKb: toNum(get("tempdbKb")),
        maxMemoryKb: toNum(get("maxMemoryKb")),
        maxDop: toNum(get("maxDop")),
        waitMs: toNum(get("waitMs")),
        firstExecution: toDate(get("firstExecution")),
        lastExecution: toDate(get("lastExecution")),
    });
}

export function queryWaitFrom(get: Get): QueryWait | null {
    const target = get("target");
    const capturedAt = toDate(get("capturedAt"));
    const intervalStart = toDate(get("intervalStart"));
    const intervalEnd = toDate(get("intervalEnd"));
    const queryId = toId(get("queryId"));
    const planId = toId(get("planId"));
    const category = toStr(get("category"));
    const waitMs = toNum(get("waitMs"));
    if (!isRcaTarget(target) || !capturedAt || !intervalStart || !intervalEnd || !queryId || !planId || !category || waitMs === undefined) return null;
    return clean<QueryWait>({
        target,
        capturedAt,
        intervalStart,
        intervalEnd,
        queryId,
        planId,
        login: toStr(get("login")),
        category,
        event: toStr(get("event")),
        waitMs,
        maxWaitMs: toNum(get("maxWaitMs")),
        samples: toNum(get("samples")),
    });
}

export function queryPlanFrom(get: Get): QueryPlan | null {
    const target = get("target");
    const capturedAt = toDate(get("capturedAt"));
    const queryId = toId(get("queryId"));
    const planId = toId(get("planId"));
    if (!isRcaTarget(target) || !capturedAt || !queryId || !planId) return null;
    return clean<QueryPlan>({
        target,
        capturedAt,
        queryId,
        planId,
        queryHash: toStr(get("queryHash")),
        planHash: toStr(get("planHash")),
        module: toStr(get("module")),
        statement: toStr(get("statement")),
        compiled: toDate(get("compiled")),
        lastCompiled: toDate(get("lastCompiled")),
        lastExecution: toDate(get("lastExecution")),
        compiles: toNum(get("compiles")),
        isForced: toBool(get("isForced")),
        forcingType: toStr(get("forcingType")),
        forceFailures: toNum(get("forceFailures")),
        lastForceFailure: toStr(get("lastForceFailure")),
        plansForQuery: toNum(get("plansForQuery")),
        estimatedCost: toNum(get("estimatedCost")),
        isParallel: toBool(get("isParallel")),
        summary: toStr(get("summary")),
    });
}

export function queryEventFrom(get: Get): QueryEvent | null {
    const target = get("target");
    const at = toDate(get("at"));
    const kind = toStr(get("kind")) as QueryEventKind | undefined;
    if (!isRcaTarget(target) || !at || !kind || !QUERY_EVENT_KINDS.includes(kind)) return null;
    return clean<QueryEvent>({
        target,
        at,
        from: toDate(get("from")),
        kind,
        queryId: toId(get("queryId")),
        planId: toId(get("planId")),
        forcingType: toStr(get("forcingType")),
        state: toStr(get("state")),
        previousState: toStr(get("previousState")),
        detail: toStr(get("detail")),
    });
}

export function queryCoverageFrom(get: Get): QueryCoverage | null {
    const target = get("target");
    const from = toDate(get("from"));
    const to = toDate(get("to"));
    const backfill = toBool(get("backfill"));
    if (!isRcaTarget(target) || !from || !to || backfill === undefined) return null;
    return clean<QueryCoverage>({
        target,
        from,
        to,
        state: toStr(get("state")),
        captureMode: toStr(get("captureMode")),
        intervalMinutes: toNum(get("intervalMinutes")),
        readFrom: toDate(get("readFrom")),
        readTo: toDate(get("readTo")),
        pendingFrom: toDate(get("pendingFrom")),
        pendingTo: toDate(get("pendingTo")),
        backfill,
        sources: lines(get("sources"), /,/),
        gaps: lines(get("gaps"), /\r?\n/),
    });
}

export function connectionGroupFrom(get: Get): ConnectionGroup | null {
    const target = get("target");
    const capturedAt = toDate(get("capturedAt"));
    const state = toStr(get("state"));
    const connections = toNum(get("connections"));
    const isDemo = toBool(get("isDemo"));
    if (!isRcaTarget(target) || !capturedAt || !state || connections === undefined || isDemo === undefined) return null;
    return clean<ConnectionGroup>({
        target,
        capturedAt,
        program: toStr(get("program")),
        runToken: toStr(get("runToken")),
        login: toStr(get("login")),
        state,
        connections,
        waitingLock: toNum(get("waitingLock")),
        oldestStateS: toNum(get("oldestStateS")),
        oldestConnectionS: toNum(get("oldestConnectionS")),
        isDemo,
    });
}

export const SIDECAR_MAPPERS = {
    queryStats: queryStatFrom,
    queryWaits: queryWaitFrom,
    queryPlans: queryPlanFrom,
    queryEvents: queryEventFrom,
    queryCoverage: queryCoverageFrom,
    connections: connectionGroupFrom,
} as const satisfies Record<SidecarTableKey, (get: Get) => unknown>;

/** Which SidecarEvidence member each sidecar table fills. */
export const SIDECAR_MEMBER = {
    queryStats: "stats",
    queryWaits: "waits",
    queryPlans: "plans",
    queryEvents: "events",
    queryCoverage: "coverage",
    connections: "connections",
} as const satisfies Record<SidecarTableKey, keyof Omit<SidecarEvidence, "missing" | "cut">>;

/** One plan's interval, by target, interval, login, query, and plan: the unit a later read of the same interval replaces. */
const planInterval = (r: { target: RcaTarget; intervalStart: Date; login?: string; queryId: string; planId: string }) => `${r.target}|${r.intervalStart.getTime()}|${r.login ?? ""}|${r.queryId}|${r.planId}`;

/**
 * Query Store's statistics and waits as the latest read of each target, interval, login, query, and plan saw them
 * (rca/README.md, Query Store): an interval read twice (open at a capture's end, then closed; or by two sessions'
 * baselines) holds the same counts or more in the later read, so it counts once, with that read's. A plan's waits are its
 * latest read's own top three, never mixed with an earlier read's.
 */
export function latestReads<T extends { stats: readonly QueryStat[]; waits: readonly QueryWait[] }>(evidence: T): T {
    const latest = new Map<string, QueryStat>();
    for (const s of evidence.stats) {
        const key = planInterval(s);
        const kept = latest.get(key);
        if (!kept || s.capturedAt.getTime() >= kept.capturedAt.getTime()) latest.set(key, s);
    }
    const waitRead = new Map<string, number>();
    for (const w of evidence.waits) waitRead.set(planInterval(w), Math.max(waitRead.get(planInterval(w)) ?? -Infinity, w.capturedAt.getTime()));
    const byTime = (a: { intervalStart: Date }, b: { intervalStart: Date }) => a.intervalStart.getTime() - b.intervalStart.getTime();
    return {
        ...evidence,
        stats: [...latest.values()].sort(byTime),
        waits: evidence.waits.filter((w) => w.capturedAt.getTime() === waitRead.get(planInterval(w))).sort(byTime),
    };
}

export const SIDECAR_KIND = "ContosoCare.RcaSidecar";
export const SIDECAR_VERSION = 1;

/**
 * JSON.parse that keeps an integer past 2^53 as its exact digits, from its source text (JSON.parse's source text access):
 * a sidecar's PostgreSQL query IDs are 64-bit hashes, which a JavaScript number would round.
 */
export function parseExact(text: string): unknown {
    return JSON.parse(text, (_key: string, value: unknown, context?: { source?: string }) =>
        typeof value === "number" && Number.isInteger(value) && !Number.isSafeInteger(value) && context?.source ? context.source : value,
    );
}

export class SidecarFormatError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "SidecarFormatError";
    }
}

interface SidecarDocument {
    kind: string;
    version: number;
    documentId: string;
    sessionId: string | null;
    windowStartUtc: string;
    windowEndUtc: string;
    targets: string[];
    epochUtc: string;
    strings: string[];
    tables: Record<string, ColumnarTable>;
}

function isDocument(value: unknown): value is SidecarDocument {
    const doc = value as Partial<SidecarDocument> | null;
    return Boolean(doc && typeof doc === "object" && typeof doc.epochUtc === "string" && Array.isArray(doc.strings) && doc.tables && typeof doc.tables === "object");
}

/**
 * The rows of a sidecar document (rca/sidecar.schema.json, version 1), or a SidecarFormatError when it isn't one this app
 * reads. Parse it with parseExact, so its 64-bit IDs keep their digits. For the tests and the local preview: the app
 * reads the history through DAX.
 */
export function decodeSidecar(value: unknown): { documentId: string; sessionId: string | null; from: Date; to: Date; sidecar: SidecarEvidence } {
    if (!isDocument(value)) throw new SidecarFormatError("This isn't an RCA sidecar document.");
    if (value.kind !== SIDECAR_KIND || value.version !== SIDECAR_VERSION) throw new SidecarFormatError(`Sidecar ${String(value.kind)} version ${String(value.version)} isn't one this app reads (${SIDECAR_KIND} ${SIDECAR_VERSION}).`);
    const epoch = Date.parse(value.epochUtc);
    if (!Number.isFinite(epoch)) throw new SidecarFormatError("The document's epoch isn't a time.");
    const sidecar = emptySidecar();
    for (const key of Object.keys(SIDECAR_SPEC) as SidecarTableKey[]) {
        const rows = readColumnarTable(value, SIDECAR_SPEC[key], SIDECAR_MAPPERS[key] as (get: Get) => unknown, epoch);
        (sidecar[SIDECAR_MEMBER[key]] as unknown[]).push(...rows);
    }
    return { documentId: value.documentId, sessionId: value.sessionId, from: new Date(value.windowStartUtc), to: new Date(value.windowEndUtc), sidecar };
}

/** Several sidecars' rows, merged in time order: a session's sidecars, or both hosts'. */
export function mergeSidecars(parts: readonly SidecarEvidence[]): SidecarEvidence {
    const merged = emptySidecar();
    for (const part of parts) {
        merged.stats.push(...part.stats);
        merged.waits.push(...part.waits);
        merged.plans.push(...part.plans);
        merged.events.push(...part.events);
        merged.coverage.push(...part.coverage);
        merged.connections.push(...part.connections);
        merged.missing.push(...part.missing.filter((m) => !merged.missing.includes(m)));
        if (part.cut?.length) (merged.cut ??= []).push(...part.cut);
    }
    const byTime = <R>(at: (row: R) => Date) => (a: R, b: R) => at(a).getTime() - at(b).getTime();
    merged.stats.sort(byTime((r) => r.intervalStart));
    merged.waits.sort(byTime((r) => r.intervalStart));
    merged.plans.sort(byTime((r) => r.capturedAt));
    merged.events.sort(byTime((r) => r.at));
    merged.coverage.sort(byTime((r) => r.from));
    merged.connections.sort(byTime((r) => r.capturedAt));
    return merged;
}
