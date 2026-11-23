// Query Store's evidence in the RCA (ADR 0031; rca/README.md, Query Store): the rules that read the sidecar's statistics,
// waits, plans, and events, and the views the chat's explain_queries and the Root cause report show. Blind: measured rows
// only; a rule never branches on a module's or a statement's text. Every claim says which of Query Store's intervals it
// rests on, at their granularity (15 minutes in the demo), and what it's measured against (rca/README.md, What a reader
// may claim):
//   QS-PLAN-REGRESSION      a query's plan that first ran in the minutes asked about, or the interval before them, at 3
//                           times or more the per-execution CPU (on PostgreSQL, time) of its plans before
//   QS-PLAN-FORCED          a plan forced or unforced (manually, or by automatic plan correction), with its figures after
//   QS-TOP-CPU              the top queries by CPU (on PostgreSQL, by time, all its Query Store records), each with its
//                           share of the captured top queries and its change against the 60 minutes before:
//   QS-MORE-CALLS             twice the executions an interval or more,
//   QS-NEW-QUERY              a query whose plans were all compiled in the minutes asked about,
//   QS-SAME-PLAN-COSTLIER     the same plan at twice its per-execution CPU (or time) or more,
//                           or "not in the top lists before", which is all an absence there shows
//   QS-WAITS                the top queries by a wait family's Query Store category or figure (physical reads, memory
//                           grant, DOP, log bytes)
//   QS-LOCK-WAITS           the queries that waited on locks, for a blocking chain

import { recommend } from "./catalog";
import { latestReads, PLAN_LAG_MINUTES, type QueryCoverage, type QueryEvent, type QueryPlan, type QueryStat, type QueryWait, type SidecarEvidence } from "./sidecar";
import { fromTo, hhmmss, iso, plural, spanEnds, type Confidence, type EvidenceRef, type Finding, type RcaTarget, type Recommendation, type ResourcePoint } from "./types";

/** Query Store's interval, in minutes, when the rows don't say: the demo's on every target (each database's 030-configure.sql; T4's default). */
export const QS_INTERVAL_MINUTES = 15;
/** A baseline is the same query's intervals in the 60 minutes before, at least 2 with executions (rca/README.md, Query Store). */
export const BASELINE_MINUTES = 60;
export const BASELINE_MIN_INTERVALS = 2;
/** A new plan at this many times its query's earlier per-execution CPU (or time) or more is a regression. */
export const REGRESSION_TIMES = 3;
/** Twice the executions an interval, or twice the same plan's per-execution CPU (or time), is a change worth saying. */
export const CHANGE_TIMES = 2;
/** How many top queries a view lists. */
export const TOP_QUERIES = 5;

/**
 * How long each target's Query Store keeps its data, past which only this history has those minutes: 14 days on T1 to T3
 * (STALE_QUERY_THRESHOLD_DAYS, each database's 030-configure.sql), sooner when it nears its size limit
 * (SIZE_BASED_CLEANUP_MODE = AUTO); 7 days on T4 (pg_qs.retention_period_in_days, its default).
 */
export const QS_RETENTION_DAYS: Readonly<Partial<Record<RcaTarget, number>>> = { T1: 14, T2: 14, T3: 14, T4: 7 };

const SQL_LEARN = "https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store";
const PG_LEARN = "https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store";
const PG_PARAMETERS_LEARN = "https://learn.microsoft.com/azure/postgresql/parameters/parameters-query-store";

/** What a target's Query Store records: SQL Server's per plan with CPU; PostgreSQL's per query, with time but no CPU; a read replica's nothing; T5 has none. */
export type QueryStoreOf = "sql" | "postgresql" | "replica" | "none";

export function queryStoreOf(target: RcaTarget): QueryStoreOf {
    if (target === "T1" || target === "T2" || target === "T3") return "sql";
    if (target === "T4") return "postgresql";
    return target === "T4-replica" ? "replica" : "none";
}

/** What a view ranks the queries by: CPU (on PostgreSQL, time), time, logical reads, waits, or executions. */
export type QueryRank = "cpu" | "duration" | "reads" | "waits" | "executions";
export const QUERY_RANKS: readonly QueryRank[] = ["cpu", "duration", "reads", "waits", "executions"];

/** One query's or plan's figures over some intervals: totals, the maxima of maxima, as Query Store's rows give them. */
export interface QueryFigures {
    executions: number;
    abortedExecutions?: number;
    cpuMs?: number;
    durationMs?: number;
    maxDurationMs?: number;
    logicalReads?: number;
    physicalReads?: number;
    logBytes?: number;
    tempdbKb?: number;
    maxMemoryKb?: number;
    maxDop?: number;
    waitMs?: number;
    rows?: number;
}

/** Per execution: totals over executions, so execution-weighted. */
export interface PerExecution {
    cpuMs?: number;
    durationMs?: number;
    logicalReads?: number;
}

/** One of Query Store's intervals of a query: its plans' figures, whether two or more plans ran in it, and whether it was still open when read. */
export interface IntervalView {
    start: string;
    end: string;
    plans: Array<{ planId: string; executions: number; cpuMs?: number; durationMs?: number }>;
    mixed: boolean;
    openWhenRead: boolean;
}

export type QueryChangeKind = "new-query" | "more-calls" | "costlier" | "plan-change" | "not-in-top-lists-before" | "steady" | "no-baseline";

/** One query of the minutes asked about, as the chat and the report show it. */
export interface QueryView {
    queryId: string;
    /** PostgreSQL's role, the workload's own only. */
    login?: string;
    module?: string;
    statement?: string;
    /** The plans that ran in the intervals read. */
    plans: string[];
    figures: QueryFigures;
    perExecution: PerExecution;
    /** Its share of the captured top queries' CPU (on PostgreSQL, time) in the same intervals: what Query Store's top lists hold, not the target's whole. */
    share: { percent: number; of: "the captured top queries' CPU" | "the captured top queries' time" } | null;
    /** The same query's intervals in the 60 minutes before, when at least 2 ran it. */
    baseline: { from: string; to: string; intervals: number; executionsPerInterval: number; perExecution: PerExecution } | null;
    /** Without a baseline, the one interval just before that ran it: stated, never compared. */
    earlier?: { from: string; to: string; executions: number; cpuMs?: number; durationMs?: number; lockWaitMs: number };
    change: { kind: QueryChangeKind; text: string };
    /** Its largest waits in the intervals read: SQL Server's categories, PostgreSQL's events (an estimate from samples). */
    waits: Array<{ category: string; event?: string; waitMs: number; samples?: number }>;
    intervals: IntervalView[];
}

/** One plan of a query, with its figures over the intervals it's measured in. */
export interface PlanView {
    planId: string;
    compiledUtc?: string;
    firstExecutionUtc?: string;
    lastExecutionUtc?: string;
    executions: number;
    perExecution: PerExecution;
    isParallel?: boolean;
    maxDop?: number;
    estimatedCost?: number;
    summary?: string;
    forcingType?: string;
}

/** A plan that first ran in the minutes asked about, or the interval before them, against its query's plans before it. */
export interface PlanChangeView {
    queryId: string;
    module?: string;
    statement?: string;
    newPlan: PlanView & { compiledInWindow: boolean };
    /** Its query's other plans in the intervals wholly before its first execution, and the 60 minutes before the minutes asked about. */
    before: Array<PlanView & { from: string; to: string; intervals: number }>;
    /** The interval that holds its first execution and another plan's executions too, which a before-and-after can't use. */
    mixed: { start: string; end: string; otherExecutions: number } | null;
    measure: "cpu" | "duration";
    /** Its per-execution measure over the plans' before; null without a baseline. */
    times: number | null;
    regression: boolean;
}

export interface ForcingView {
    at: string;
    from?: string;
    kind: "forced" | "unforced";
    queryId?: string;
    planId?: string;
    forcingType?: string;
    /** The forced plan's figures in the intervals that start after the forcing could have happened. */
    after: (PerExecution & { executions: number; from: string; to: string; openWhenRead: boolean }) | null;
}

export interface TuningView {
    at: string;
    from?: string;
    queryId?: string;
    planId?: string;
    state?: string;
    previousState?: string;
    detail?: string;
}

/** Query Store's state as the capture last read it in these minutes. */
export interface QueryStoreStateView {
    state?: string;
    captureMode?: string;
    intervalMinutes?: number;
    gaps: string[];
}

/** Minutes PostgreSQL's Query Store hadn't published when the capture read it; expired past its retention. */
export interface PendingView {
    from: string;
    to: string;
    expired: boolean;
}

/** Whether this history holds Query Store's evidence for the target and minutes, and if not, why. */
export type QueryStoreRecorded = "yes" | "no-rows" | "pending" | "model-missing" | "replica" | "none";

/** What explain_queries returns as details, and what the Root cause report shows (rca/README.md, Who builds what for the sidecar: D). */
export interface QueryStoreDetails {
    target: RcaTarget;
    recorded: QueryStoreRecorded;
    intervalMinutes: number;
    /** Query Store's intervals that overlap the minutes asked about, which every claim rests on. */
    intervals: { from: string; to: string } | null;
    baseline: { from: string; to: string };
    rankBy: QueryRank;
    top: QueryView[];
    planChanges: PlanChangeView[];
    forcings: ForcingView[];
    tuning: TuningView[];
    state: QueryStoreStateView | null;
    pending: PendingView[];
    retention: { days: number; past: boolean } | null;
    /** The target's measured CPU in those minutes (RCA Resource, T3's resource governance), beside the shares, which are of the top lists. */
    measuredCpu?: { averagePercent: number; peakPercent: number; samples: number };
}

export interface QueryStoreAnalysis {
    details: QueryStoreDetails;
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    notCaptured: string[];
}

/** The incident a rule reads Query Store for: its signal's family, its minutes, and when the signal rose. */
export interface QueryIncident {
    family: string;
    start: Date;
    end: Date | null;
    last: Date;
}

export interface QueryStoreInput {
    target: RcaTarget;
    /** The minutes asked about: an incident's, or a viewer's window. */
    from: Date;
    to: Date;
    sidecar: SidecarEvidence;
    /** The target's RCA Resource rows, for its measured CPU beside the shares. */
    resource?: readonly ResourcePoint[];
    incident?: QueryIncident;
    rankBy?: QueryRank;
    /** One query's plans over the minutes and the hour before them, instead of the top queries. */
    queryId?: string;
    /** Now, for Query Store's retention. */
    now: Date;
}

const MIN = 60_000;
const DAY = 24 * 60 * MIN;

const num = (v: number) => (Math.abs(v) >= 100 ? Math.round(v).toLocaleString("en-US") : String(Math.round(v * 10) / 10));
const ms = (v: number) => `${num(v)} ms`;
const count = (n: number) => Math.round(n).toLocaleString("en-US");
/** "83 times", "3.4 times": a ratio as a claim gives it. */
const timesWords = (v: number) => `${v >= 10 ? Math.round(v) : Math.round(v * 10) / 10} times`;
/** "96 %", or "under 1 %": a share as a claim gives it. */
const percentWords = (v: number) => (v < 1 ? "under 1 %" : `${Math.round(v)} %`);
/** Query Store's intervals, from the first's start to the last's end, as a claim names them. */
const intervalWords = (start: Date, end: Date, minutes: number, n: number) => `Query Store's ${minutes}-minute ${n === 1 ? "interval" : "intervals"} from ${spanEnds(start, end).map((t) => t.replace(/:00$/, "")).join(" to ")} UTC`;
const sum = <T>(rows: readonly T[], pick: (r: T) => number | undefined): number | undefined => {
    let total: number | undefined;
    for (const r of rows) {
        const v = pick(r);
        if (v !== undefined) total = (total ?? 0) + v;
    }
    return total;
};
const max = <T>(rows: readonly T[], pick: (r: T) => number | undefined): number | undefined => {
    let best: number | undefined;
    for (const r of rows) {
        const v = pick(r);
        if (v !== undefined && (best === undefined || v > best)) best = v;
    }
    return best;
};
/** Only the fields with a value. */
function clean<T extends object>(row: T): T {
    for (const key of Object.keys(row) as Array<keyof T>) if (row[key] === undefined) delete row[key];
    return row;
}

/** A query's or plan's figures over its rows: totals summed, maxima of maxima. */
export function figuresOf(rows: readonly QueryStat[]): QueryFigures {
    return clean<QueryFigures>({
        executions: sum(rows, (r) => r.executions) ?? 0,
        abortedExecutions: sum(rows, (r) => r.abortedExecutions),
        cpuMs: sum(rows, (r) => r.cpuMs),
        durationMs: sum(rows, (r) => r.durationMs),
        maxDurationMs: max(rows, (r) => r.maxDurationMs),
        logicalReads: sum(rows, (r) => r.logicalReads),
        physicalReads: sum(rows, (r) => r.physicalReads),
        logBytes: sum(rows, (r) => r.logBytes),
        tempdbKb: sum(rows, (r) => r.tempdbKb),
        maxMemoryKb: max(rows, (r) => r.maxMemoryKb),
        maxDop: max(rows, (r) => r.maxDop),
        waitMs: sum(rows, (r) => r.waitMs),
        rows: sum(rows, (r) => r.rows),
    });
}

/** Per execution, over the figures' executions: execution-weighted, as the totals are. */
export function perExecutionOf(f: QueryFigures): PerExecution {
    if (f.executions <= 0) return {};
    return clean<PerExecution>({
        cpuMs: f.cpuMs === undefined ? undefined : f.cpuMs / f.executions,
        durationMs: f.durationMs === undefined ? undefined : f.durationMs / f.executions,
        logicalReads: f.logicalReads === undefined ? undefined : f.logicalReads / f.executions,
    });
}

/** What a target's ranking by "cpu" measures: CPU on SQL Server; on PostgreSQL, whose Query Store records no CPU time, time. */
const cpuMeasure = (target: RcaTarget): "cpu" | "duration" => (queryStoreOf(target) === "postgresql" ? "duration" : "cpu");
const measureOf = (f: QueryFigures | PerExecution, measure: "cpu" | "duration") => (measure === "cpu" ? f.cpuMs : f.durationMs);
const rankValue = (f: QueryFigures, rank: QueryRank, target: RcaTarget): number => {
    switch (rank) {
        case "cpu":
            return measureOf(f, cpuMeasure(target)) ?? 0;
        case "duration":
            return f.durationMs ?? 0;
        case "reads":
            return f.logicalReads ?? 0;
        case "waits":
            return f.waitMs ?? 0;
        default:
            return f.executions;
    }
};

const statKey = (s: QueryStat) => `${s.login ?? ""}|${s.queryId}`;
const overlaps = (s: { intervalStart: Date; intervalEnd: Date }, from: Date, to: Date) => s.intervalEnd.getTime() > from.getTime() && s.intervalStart.getTime() < to.getTime();
const sameIntervals = (rows: readonly { intervalStart: Date }[]) => [...new Set(rows.map((r) => r.intervalStart.getTime()))].sort((a, b) => a - b);

/** The interval length the rows or the coverage say, or the demo's. */
function intervalMinutesOf(stats: readonly QueryStat[], coverage: readonly QueryCoverage[]): number {
    const fromRows = stats.map((s) => Math.round((s.intervalEnd.getTime() - s.intervalStart.getTime()) / MIN)).filter((m) => m > 0);
    if (fromRows.length) return Math.max(...fromRows);
    return coverage.find((c) => c.intervalMinutes)?.intervalMinutes ?? QS_INTERVAL_MINUTES;
}

/** A query's statement and module, from its rows or its plans. */
function describedBy(rows: readonly { module?: string; statement?: string; login?: string }[]) {
    const withText = rows.find((r) => r.statement || r.module);
    return clean({ login: rows.find((r) => r.login)?.login, module: withText?.module, statement: withText?.statement });
}

/** Each plan's latest read, with the newest summary and cost any read gave it (RCA-SQL-14 reduces a showplan once). */
function latestPlans(plans: readonly QueryPlan[], target: RcaTarget, until: Date): Map<string, QueryPlan> {
    const out = new Map<string, QueryPlan>();
    for (const p of [...plans].filter((p) => p.target === target && p.capturedAt.getTime() <= until.getTime()).sort((a, b) => a.capturedAt.getTime() - b.capturedAt.getTime())) {
        const key = `${p.queryId}|${p.planId}`;
        const kept = out.get(key);
        out.set(key, { ...kept, ...p, summary: p.summary ?? kept?.summary, estimatedCost: p.estimatedCost ?? kept?.estimatedCost });
    }
    return out;
}

function intervalViews(rows: readonly QueryStat[]): IntervalView[] {
    return sameIntervals(rows).map((start) => {
        const inIt = rows.filter((r) => r.intervalStart.getTime() === start);
        const end = inIt[0].intervalEnd;
        return {
            start: iso(new Date(start)),
            end: iso(end),
            plans: inIt.map((r) => clean({ planId: r.planId, executions: r.executions, cpuMs: r.cpuMs, durationMs: r.durationMs })),
            mixed: new Set(inIt.map((r) => r.planId)).size > 1,
            openWhenRead: inIt.some((r) => r.capturedAt.getTime() < r.intervalEnd.getTime()),
        };
    });
}

function waitsOf(waits: readonly QueryWait[], queryId: string, login: string | undefined, top = 3) {
    const byKind = new Map<string, { category: string; event?: string; waitMs: number; samples?: number }>();
    for (const w of waits) {
        if (w.queryId !== queryId || (w.login ?? undefined) !== login) continue;
        const key = `${w.category}|${w.event ?? ""}`;
        const kept = byKind.get(key) ?? clean({ category: w.category, event: w.event, waitMs: 0, samples: w.samples === undefined ? undefined : 0 });
        kept.waitMs += w.waitMs;
        if (w.samples !== undefined) kept.samples = (kept.samples ?? 0) + w.samples;
        byKind.set(key, kept);
    }
    return [...byKind.values()].sort((a, b) => b.waitMs - a.waitMs).slice(0, top);
}

/** "Lock:transactionid 2,480 times (about 248 s at 100 ms a sample)", or "CPU 18,900 ms". */
function waitWords(w: { category: string; event?: string; waitMs: number; samples?: number }): string {
    if (w.samples !== undefined) return `${w.category}${w.event ? `:${w.event}` : ""} ${count(w.samples)} ${w.samples === 1 ? "time" : "times"} (about ${num(w.waitMs / 1000)} s from its samples)`;
    return `${w.category} ${ms(w.waitMs)}`;
}

interface Windowed {
    target: RcaTarget;
    stats: QueryStat[];
    waits: QueryWait[];
    inWindow: QueryStat[];
    before: QueryStat[];
    baselineFrom: Date;
    minutes: number;
}

function windowed(input: QueryStoreInput): Windowed {
    const fresh = latestReads({ stats: input.sidecar.stats.filter((s) => s.target === input.target), waits: input.sidecar.waits.filter((w) => w.target === input.target) });
    const baselineFrom = new Date(input.from.getTime() - BASELINE_MINUTES * MIN);
    return {
        target: input.target,
        stats: fresh.stats,
        waits: fresh.waits,
        inWindow: fresh.stats.filter((s) => overlaps(s, input.from, input.to)),
        // Wholly before the minutes asked about, and starting within the hour before them.
        before: fresh.stats.filter((s) => s.intervalEnd.getTime() <= input.from.getTime() && s.intervalStart.getTime() >= baselineFrom.getTime()),
        baselineFrom,
        minutes: intervalMinutesOf(fresh.stats, input.sidecar.coverage.filter((c) => c.target === input.target)),
    };
}

/** The window's queries, as the chat and the report show them, ranked. */
function queryViews(w: Windowed, plans: Map<string, QueryPlan>, from: Date, to: Date, rank: QueryRank): QueryView[] {
    const measure = cpuMeasure(w.target);
    const byQuery = new Map<string, QueryStat[]>();
    for (const s of w.inWindow) byQuery.set(statKey(s), [...(byQuery.get(statKey(s)) ?? []), s]);
    const total = sum(w.inWindow, (s) => measureOf(s, measure)) ?? 0;
    const views = [...byQuery.values()].map((rows): QueryView => {
        const figures = figuresOf(rows);
        const queryId = rows[0].queryId;
        const login = rows[0].login;
        const before = w.before.filter((s) => s.queryId === queryId && (s.login ?? undefined) === login && s.executions > 0);
        const beforeIntervals = sameIntervals(before);
        const baseline =
            beforeIntervals.length >= BASELINE_MIN_INTERVALS
                ? {
                      from: iso(new Date(beforeIntervals[0])),
                      to: iso(new Date(Math.max(...before.map((s) => s.intervalEnd.getTime())))),
                      intervals: beforeIntervals.length,
                      executionsPerInterval: figuresOf(before).executions / beforeIntervals.length,
                      perExecution: perExecutionOf(figuresOf(before)),
                  }
                : null;
        const queryPlans = [...plans.values()].filter((p) => p.queryId === queryId);
        const own = measureOf(figures, measure);
        const share = total > 0 && own !== undefined ? { percent: (own / total) * 100, of: measure === "cpu" ? ("the captured top queries' CPU" as const) : ("the captured top queries' time" as const) } : null;
        const lastBefore = beforeIntervals.length > 0 && beforeIntervals.length < BASELINE_MIN_INTERVALS ? before.filter((s) => s.intervalStart.getTime() === beforeIntervals[beforeIntervals.length - 1]) : [];
        const earlier = lastBefore.length
            ? clean({
                  from: iso(lastBefore[0].intervalStart),
                  to: iso(lastBefore[0].intervalEnd),
                  executions: figuresOf(lastBefore).executions,
                  cpuMs: figuresOf(lastBefore).cpuMs,
                  durationMs: figuresOf(lastBefore).durationMs,
                  lockWaitMs: w.waits.filter((x) => x.queryId === queryId && (x.login ?? undefined) === login && x.category === "Lock" && x.intervalStart.getTime() === lastBefore[0].intervalStart.getTime()).reduce((n, x) => n + x.waitMs, 0),
              })
            : undefined;
        return clean({
            queryId,
            ...describedBy([...rows, ...queryPlans]),
            plans: [...new Set(rows.map((r) => r.planId))],
            figures,
            perExecution: perExecutionOf(figures),
            share,
            baseline,
            earlier,
            change: changeOf(rows, before, baseline, queryPlans, from, to, measure),
            waits: waitsOf(w.waits.filter((x) => overlaps(x, from, to)), queryId, login),
            intervals: intervalViews(rows),
        });
    });
    return views.sort((a, b) => rankValue(b.figures, rank, w.target) - rankValue(a.figures, rank, w.target) || a.queryId.localeCompare(b.queryId));
}

/** How a query changed against the hour before, in words a reader may claim (rca/README.md, What a reader may claim). */
function changeOf(rows: readonly QueryStat[], before: readonly QueryStat[], baseline: QueryView["baseline"], plans: readonly QueryPlan[], from: Date, to: Date, measure: "cpu" | "duration"): QueryView["change"] {
    const inside = (d: Date | undefined) => !!d && d.getTime() >= from.getTime() && d.getTime() <= to.getTime();
    const compiled = plans.filter((p) => p.compiled);
    if (before.length === 0) {
        if (compiled.length > 0 && compiled.every((p) => inside(p.compiled))) return { kind: "new-query", text: `new in these minutes: each of its plans was compiled in them, the first at ${hhmmss(new Date(Math.min(...compiled.map((p) => p.compiled!.getTime()))))} UTC` };
        return { kind: "not-in-top-lists-before", text: "not in the capture's top lists in the hour before, which doesn't mean it didn't run then" };
    }
    if (!baseline) return { kind: "no-baseline", text: `no baseline: Query Store's top lists hold it in ${plural(sameIntervals(before).length, "interval")} of the hour before, and a baseline needs ${BASELINE_MIN_INTERVALS}` };
    const newPlans = [...new Set(rows.map((r) => r.planId))].filter((id) => !before.some((b) => b.planId === id));
    if (newPlans.length) return { kind: "plan-change", text: `a plan it hadn't run in the hour before: ${newPlans.map((id) => `plan ${id}`).join(" and ")}` };
    const perInterval = figuresOf(rows).executions / Math.max(1, sameIntervals(rows).length);
    if (perInterval >= CHANGE_TIMES * baseline.executionsPerInterval && baseline.executionsPerInterval > 0)
        return { kind: "more-calls", text: `more executions: ${count(perInterval)} an interval, against ${count(baseline.executionsPerInterval)} in the hour before` };
    const now = measureOf(perExecutionOf(figuresOf(rows)), measure);
    const then = measureOf(baseline.perExecution, measure);
    if (now !== undefined && then !== undefined && then > 0 && now >= CHANGE_TIMES * then)
        return { kind: "costlier", text: `the same plan${new Set(rows.map((r) => r.planId)).size > 1 ? "s" : ""} costing more: ${ms(now)} of ${measure === "cpu" ? "CPU" : "time"} an execution, against ${ms(then)} in the hour before` };
    return { kind: "steady", text: "about as in the hour before" };
}

/** The plans that first ran in the minutes asked about, or the interval before them, each against its query's plans before it. */
function planChanges(w: Windowed, plans: Map<string, QueryPlan>, from: Date, to: Date): PlanChangeView[] {
    const measure = cpuMeasure(w.target);
    // PostgreSQL's Query Store here stores no plans: its rows carry plan 0, so a plan change can't be told.
    if (queryStoreOf(w.target) !== "sql") return [];
    const reach = new Date(from.getTime() - w.minutes * MIN);
    const out: PlanChangeView[] = [];
    for (const queryId of [...new Set(w.inWindow.map((s) => s.queryId))]) {
        const rows = w.stats.filter((s) => s.queryId === queryId);
        for (const planId of [...new Set(rows.filter((s) => overlaps(s, from, to)).map((s) => s.planId))]) {
            const own = rows.filter((s) => s.planId === planId);
            const firstRun = own.map((s) => s.firstExecution ?? s.intervalStart).sort((a, b) => a.getTime() - b.getTime())[0];
            // It first ran in the minutes asked about, or the interval before them, and never in an earlier interval read.
            if (firstRun.getTime() < reach.getTime() || firstRun.getTime() > to.getTime()) continue;
            const others = rows.filter((s) => s.planId !== planId);
            const wholeBefore = others.filter((s) => s.intervalEnd.getTime() <= firstRun.getTime() && s.intervalStart.getTime() >= w.baselineFrom.getTime() - w.minutes * MIN && s.executions > 0);
            if (wholeBefore.length === 0 && others.length === 0) continue;
            const plan = plans.get(`${queryId}|${planId}`);
            const ownFigures = figuresOf(own.filter((s) => s.intervalEnd.getTime() > from.getTime() - w.minutes * MIN));
            const newView = planView(planId, ownFigures, plan, own);
            const before = [...new Set(wholeBefore.map((s) => s.planId))].map((id) => {
                const theirs = wholeBefore.filter((s) => s.planId === id);
                const intervals = sameIntervals(theirs);
                return { ...planView(id, figuresOf(theirs), plans.get(`${queryId}|${id}`), theirs), from: iso(new Date(intervals[0])), to: iso(new Date(Math.max(...theirs.map((s) => s.intervalEnd.getTime())))), intervals: intervals.length };
            });
            const mixedRows = others.filter((s) => s.intervalStart.getTime() <= firstRun.getTime() && s.intervalEnd.getTime() > firstRun.getTime());
            const mixedInterval = mixedRows[0];
            const baselineIntervals = new Set(wholeBefore.map((s) => s.intervalStart.getTime())).size;
            const beforeMeasure = measureOf(perExecutionOf(figuresOf(wholeBefore)), measure);
            const nowMeasure = measureOf(newView.perExecution, measure);
            const times = baselineIntervals >= BASELINE_MIN_INTERVALS && beforeMeasure && nowMeasure !== undefined ? nowMeasure / beforeMeasure : null;
            out.push({
                queryId,
                ...describedBy([...own, ...(plan ? [plan] : [])]),
                newPlan: { ...newView, compiledInWindow: !!plan?.compiled && plan.compiled.getTime() >= reach.getTime() && plan.compiled.getTime() <= to.getTime() },
                before,
                mixed: mixedInterval ? { start: iso(mixedInterval.intervalStart), end: iso(mixedInterval.intervalEnd), otherExecutions: sum(mixedRows, (s) => s.executions) ?? 0 } : null,
                measure,
                times,
                regression: times !== null && times >= REGRESSION_TIMES,
            });
        }
    }
    return out.sort((a, b) => (b.times ?? 0) - (a.times ?? 0));
}

function planView(planId: string, figures: QueryFigures, plan: QueryPlan | undefined, rows: readonly QueryStat[]): PlanView {
    const firsts = rows.map((s) => s.firstExecution).filter((d): d is Date => !!d);
    const lasts = rows.map((s) => s.lastExecution).filter((d): d is Date => !!d);
    return clean<PlanView>({
        planId,
        compiledUtc: plan?.compiled ? iso(plan.compiled) : undefined,
        firstExecutionUtc: firsts.length ? iso(new Date(Math.min(...firsts.map((d) => d.getTime())))) : undefined,
        lastExecutionUtc: lasts.length ? iso(new Date(Math.max(...lasts.map((d) => d.getTime())))) : undefined,
        executions: figures.executions,
        perExecution: perExecutionOf(figures),
        isParallel: plan?.isParallel,
        maxDop: figures.maxDop,
        estimatedCost: plan?.estimatedCost,
        summary: plan?.summary,
        forcingType: plan?.forcingType,
    });
}

/** Forcings and unforcings in the minutes asked about and after them, each with the forced plan's figures after it. */
function forcingsOf(w: Windowed, events: readonly QueryEvent[], from: Date, to: Date): ForcingView[] {
    return events
        .filter((e) => e.target === w.target && (e.kind === "forced" || e.kind === "unforced") && e.at.getTime() >= from.getTime() - w.minutes * MIN && (e.from ?? e.at).getTime() <= to.getTime())
        .map((e) => {
            const since = e.from ?? e.at;
            const after = w.stats.filter((s) => s.queryId === e.queryId && s.planId === e.planId && s.intervalStart.getTime() >= since.getTime());
            const figures = figuresOf(after);
            const intervals = sameIntervals(after);
            return clean<ForcingView>({
                at: iso(e.at),
                from: e.from ? iso(e.from) : undefined,
                kind: e.kind as "forced" | "unforced",
                queryId: e.queryId,
                planId: e.planId,
                forcingType: e.forcingType,
                after: intervals.length
                    ? { ...perExecutionOf(figures), executions: figures.executions, from: iso(new Date(intervals[0])), to: iso(new Date(Math.max(...after.map((s) => s.intervalEnd.getTime())))), openWhenRead: after.some((s) => s.capturedAt.getTime() < s.intervalEnd.getTime()) }
                    : null,
            });
        });
}

function tuningOf(w: Windowed, events: readonly QueryEvent[], from: Date, to: Date): TuningView[] {
    return events
        .filter((e) => e.target === w.target && e.kind === "tuning" && e.at.getTime() >= from.getTime() - w.minutes * MIN && (e.from ?? e.at).getTime() <= to.getTime())
        .map((e) => clean<TuningView>({ at: iso(e.at), from: e.from ? iso(e.from) : undefined, queryId: e.queryId, planId: e.planId, state: e.state, previousState: e.previousState, detail: e.detail }));
}

/**
 * PostgreSQL's minutes its Query Store hadn't published when read, less what a later read took; expired past its retention.
 * A backfill (rca_query_coverage.backfill) reads a pending range again once Query Store has published it. One with no
 * pending range of its own finished the range: what it read is in the statistics, and what it couldn't, its gaps say
 * (gapLines: "Lost when T4 stopped", or the range expired; rca/README.md, Pending publication). One that still waits
 * takes the earlier range's place with its own, what's left of it.
 */
function pendingOf(target: RcaTarget, coverage: readonly QueryCoverage[], stats: readonly QueryStat[], from: Date, to: Date, now: Date): PendingView[] {
    if (queryStoreOf(target) !== "postgresql") return [];
    const read = (a: Date, b: Date) =>
        coverage.some((c) => c.target === target && c.readFrom && c.readTo && c.readFrom.getTime() <= a.getTime() && c.readTo.getTime() >= b.getTime()) ||
        stats.some((s) => s.target === target && s.intervalStart.getTime() <= a.getTime() && s.intervalEnd.getTime() >= b.getTime());
    const pendingIn = (c: QueryCoverage, a: Date, b: Date) => !!c.pendingFrom && !!c.pendingTo && c.pendingTo.getTime() > a.getTime() && c.pendingFrom.getTime() < b.getTime();
    const keeps = (QS_RETENTION_DAYS[target] ?? 7) * DAY;
    const out: PendingView[] = [];
    for (const c of coverage) {
        if (c.target !== target || !c.pendingFrom || !c.pendingTo) continue;
        if (c.pendingTo.getTime() <= from.getTime() || c.pendingFrom.getTime() >= to.getTime() || read(c.pendingFrom, c.pendingTo)) continue;
        const [a, b] = [c.pendingFrom, c.pendingTo];
        const backfills = coverage.filter((x) => x !== c && x.target === target && x.backfill && x.from.getTime() <= a.getTime() && x.to.getTime() >= b.getTime());
        if (backfills.some((x) => !pendingIn(x, a, b))) continue;
        if (!c.backfill && backfills.length) continue;
        if (out.some((p) => p.from === iso(a) && p.to === iso(b))) continue;
        out.push({ from: iso(a), to: iso(b), expired: now.getTime() - b.getTime() > keeps });
    }
    return out;
}

/** Whether a coverage row's own window overlaps the minutes asked about (an instant: holds it). */
const overlapsWindow = (c: QueryCoverage, from: Date, to: Date) =>
    from.getTime() === to.getTime() ? c.from.getTime() <= from.getTime() && c.to.getTime() >= to.getTime() : c.from.getTime() < to.getTime() && c.to.getTime() > from.getTime();

/**
 * The coverage rows' gaps for the minutes, each a line with its target: of every row whose own window overlaps them, also
 * when Query Store's rows are there (a cut of the sidecar's budget, a refused read, a timeout, T4's lost window), but for
 * the lines of publication still pending, which pendingOf words (the review of d441fe13). A line that starts with a target
 * already names it.
 */
export function coverageGapLines(target: RcaTarget, coverage: readonly QueryCoverage[], from: Date, to: Date): string[] {
    const lines: string[] = [];
    for (const c of coverage) {
        if (c.target !== target || !overlapsWindow(c, from, to)) continue;
        for (const gap of c.gaps) {
            if (/^Pending publication:/.test(gap)) continue;
            const line = /^(T[1-5])\b/.test(gap) ? gap : `${target}: ${gap}`;
            if (!lines.includes(line)) lines.push(line);
        }
    }
    return lines;
}

/**
 * Query Store's state as the rows of the minutes read it, when it's worth saying: on SQL Server, anything but READ_WRITE;
 * on PostgreSQL, whose state is its capture mode (top, all, or none), only none (the review of d441fe13: "all" read as
 * an abnormal state).
 */
function unusualState(target: RcaTarget, rows: readonly QueryCoverage[]): string | null {
    if (queryStoreOf(target) === "postgresql") return rows.some((c) => c.state === "none") ? "its capture mode was none" : null;
    const states = [...new Set(rows.map((c) => c.state).filter((s): s is string => !!s && s !== "READ_WRITE"))];
    return states.length ? `Query Store was ${states.join(", then ")} when the capture read it` : null;
}

/**
 * Where a Run all session's Query Store evidence waits, for how long, and what brings it into the history: the one sentence
 * of it, which every "isn't in this history yet" holds (notInHistoryYet), as T2a's troubleshooting rows and fix say it
 * (eea61a49, 8e2ada18). A Run all session leaves its sidecars on the VMs, whose runner keeps one until it's acknowledged,
 * or for 30 days after it sealed it (rca/README.md, The sidecar); a save from the scripts takes them, and exports only from
 * running VMs (Invoke-DemoRcaScriptExport); the update comes first, as decision C has it. T2c, Run all's own path, changes
 * this sentence, and only it, when it merges (the re-check of fc430a78).
 */
export const QS_EVIDENCE_FIX = "After a Run all session, that evidence waits on the VMs for 30 days for a save from the scripts to take it: ./scripts/deploy.ps1, then ./scripts/stop-demo.ps1 -SaveHistory with the VMs running (./scripts/start-demo.ps1 first when they're stopped).";

/**
 * Decision C (unit 2's integration plan, revision 2, section 0), the one place its words live: what the RCA says of minutes
 * for which this history holds no Query Store coverage row. After a Run all session the capture did read Query Store, and
 * its sidecars wait on the VMs for a save from the scripts (QS_EVIDENCE_FIX); or a part of the demo older than the sidecar
 * saved those minutes. So: not in this history yet, or saved by an older part, with where it waits and the fix, and nothing
 * about the target; never that it has no Query Store, or that its evidence wasn't captured (the review of d441fe13: "it
 * didn't read Query Store then" was false after a Run all session). `subject` names what isn't there: "Query Store's
 * evidence from ... UTC", "Which queries drove it", "who held the connections ...".
 */
export function notInHistoryYet(target: RcaTarget, subject: string): string {
    return `${subject} isn't in this history yet, or those minutes were saved by a part of the demo older than Query Store's evidence. ${QS_EVIDENCE_FIX} That says nothing about Query Store on ${target}.`;
}

/** The target's measured CPU in the minutes (RCA Resource: T3's resource governance, avg_cpu_percent of its cap). */
function measuredCpuOf(resource: readonly ResourcePoint[] | undefined, target: RcaTarget, from: Date, to: Date): QueryStoreDetails["measuredCpu"] {
    const points = (resource ?? []).filter((r) => r.target === target && r.metric === "avg_cpu_percent" && r.at.getTime() >= from.getTime() && r.at.getTime() <= to.getTime());
    if (points.length === 0) return undefined;
    return { averagePercent: points.reduce((n, r) => n + r.value, 0) / points.length, peakPercent: Math.max(...points.map((r) => r.value)), samples: points.length };
}

/** Why this history has no Query Store evidence for the target's minutes, in words that describe the history, never the target. */
function notRecordedWords(target: RcaTarget, recorded: QueryStoreRecorded, sidecar: SidecarEvidence, coverage: readonly QueryCoverage[], from: Date, to: Date): string[] {
    const minutes = `${fromTo(from, to)} UTC`;
    switch (recorded) {
        case "replica":
            return [`${target}: Query Store doesn't record a read replica's queries (${PG_LEARN}), so neither this history nor ${target} has them.`];
        case "none":
            return [`${target}: Azure Cosmos DB has no Query Store; its requests are in Azure Monitor's metrics.`];
        case "model-missing":
            return [`${target}: this history's model doesn't have Query Store's tables yet (${sidecar.missing.join(", ")}), so it holds no per-query statistics; ./scripts/deploy.ps1 updates the model.`];
        case "pending":
            return [];
        default: {
            // No coverage row for these minutes: decision C, never "no Query Store" or "not captured".
            if (coverage.length === 0) return [`${target}: ${notInHistoryYet(target, `Query Store's evidence ${minutes}`)}`];
            const state = unusualState(target, coverage.filter((c) => overlapsWindow(c, from, to)));
            return [`${target}: Query Store's evidence in this history holds no query ${minutes}${state ? `: ${state}` : ""}.`];
        }
    }
}

/** Where a DBA reads Query Store's own data for the minutes, unless it's past its retention, when this history is all that's left. */
function retentionStep(target: RcaTarget, from: Date, to: Date, now: Date, queryId?: string): { step: string | null; past: boolean; days: number } | null {
    const days = QS_RETENTION_DAYS[target];
    if (days === undefined) return null;
    const past = now.getTime() - to.getTime() > days * DAY;
    const minutes = `${fromTo(from, to)} UTC`;
    if (past) return { past, days, step: `Query Store on ${target} keeps ${days} days${queryStoreOf(target) === "sql" ? " (STALE_QUERY_THRESHOLD_DAYS), less when it nears its size limit" : ` (pg_qs.retention_period_in_days, ${PG_PARAMETERS_LEARN})`}, so it no longer holds ${minutes}: this history's rows are what's left of them.` };
    const what = queryId ? `query ${queryId}'s plans and runtime statistics` : "the queries and plans";
    return {
        past,
        days,
        step:
            queryStoreOf(target) === "sql"
                ? `Read ${what} in Query Store on ${target} for ${minutes} while it keeps them (${days} days): sys.query_store_runtime_stats and sys.query_store_plan, or its Regressed Queries and Tracked Queries reports (${SQL_LEARN}).`
                : `Read ${what} in Query Store on ${target} for ${minutes} while it keeps them (${days} days): query_store.qs_view in its azure_sys database (${PG_LEARN}).`,
    };
}

const WAIT_CATEGORIES: Readonly<Record<string, { category: string; figure?: keyof QueryFigures; words?: string; rec: string }>> = {
    io: { category: "Buffer IO", figure: "physicalReads", words: "physical reads", rec: "IO-READS" },
    memory: { category: "Memory", figure: "maxMemoryKb", words: "the largest memory grant (KB)", rec: "MEM-GRANTS" },
    parallelism: { category: "Parallelism", figure: "maxDop", words: "the highest degree of parallelism", rec: "PAR-MAXDOP" },
    tran_log: { category: "Tran Log IO", figure: "logBytes", words: "log bytes", rec: "LOG-BATCH" },
    log_rate: { category: "Log Rate Governor", figure: "logBytes", words: "log bytes", rec: "LOG-BATCH" },
    latch: { category: "Buffer Latch", rec: "TEMPDB-ALLOC" },
    network: { category: "Network IO", rec: "NET-CLIENT" },
};

const queryName = (v: { queryId: string; module?: string; statement?: string; login?: string }) => {
    const what = v.module ? ` (${v.module})` : v.statement ? ` ("${v.statement.length > 72 ? `${v.statement.slice(0, 72).trimEnd()}…` : v.statement}")` : "";
    return `query ${v.queryId}${what}${v.login ? `, run by ${v.login}` : ""}`;
};
const capitalized = (text: string) => `${text[0].toUpperCase()}${text.slice(1)}`;
/** A query's total in words: "93,627 ms of CPU", or on PostgreSQL "251,300 ms in all". */
const totalWords = (value: number, measure: "cpu" | "duration") => `${ms(value)} ${measure === "cpu" ? "of CPU" : "in all"}`;
/** A query's interval just before, when there's no baseline: stated, never compared (rca/README.md, What a reader may claim). */
function earlierWords(q: QueryView): string {
    const e = q.earlier;
    if (!e) return "";
    const value = e.cpuMs ?? e.durationMs;
    return ` In the interval before, from ${spanEnds(new Date(e.from), new Date(e.to)).map((t) => t.replace(/:00$/, "")).join(" to ")} UTC, it ran ${count(e.executions)} times${value === undefined ? "" : ` in ${ms(value)}${e.cpuMs !== undefined ? " of CPU" : ""}`}${e.lockWaitMs ? `, with ${ms(e.lockWaitMs)} of lock waits` : ", with no lock waits recorded"}.`;
}

/**
 * Query Store's evidence for a target's minutes: the top queries, plan changes and regressions, forcings and automatic
 * tuning, Query Store's state, and what this history doesn't hold, with findings, a root cause when a rule finds one,
 * recommendations, and next steps.
 */
export function analyzeQueries(input: QueryStoreInput): QueryStoreAnalysis {
    const { target, from, to } = input;
    const kind = queryStoreOf(target);
    const rankBy = input.rankBy ?? "cpu";
    const coverage = input.sidecar.coverage.filter((c) => c.target === target && ((c.to.getTime() >= from.getTime() && c.from.getTime() <= to.getTime()) || (!!c.readFrom && !!c.readTo && c.readTo.getTime() >= from.getTime() && c.readFrom.getTime() <= to.getTime())));
    const w = windowed(input);
    const plans = latestPlans(input.sidecar.plans, target, new Date(to.getTime() + PLAN_LAG_MINUTES * MIN));
    const intervalsFrom = w.inWindow.length ? new Date(Math.min(...w.inWindow.map((s) => s.intervalStart.getTime()))) : null;
    const intervalsTo = w.inWindow.length ? new Date(Math.max(...w.inWindow.map((s) => s.intervalEnd.getTime()))) : null;
    const pending = pendingOf(target, input.sidecar.coverage, w.stats, from, to, input.now);
    const recorded: QueryStoreRecorded =
        kind === "replica" ? "replica" : kind === "none" ? "none" : input.sidecar.missing.includes("RCA Query Stats") ? "model-missing" : w.inWindow.length ? "yes" : pending.length ? "pending" : "no-rows";
    const retention = retentionStep(target, from, to, input.now, input.queryId);
    const lastState = [...coverage].sort((a, b) => b.to.getTime() - a.to.getTime()).find((c) => c.state || c.captureMode || c.gaps.length);
    let top = recorded === "yes" ? queryViews(w, plans, from, to, rankBy) : [];
    if (input.queryId) top = top.filter((q) => q.queryId === input.queryId);
    const changes = recorded === "yes" ? planChanges(w, plans, from, to).filter((c) => !input.queryId || c.queryId === input.queryId) : [];
    const forcings = forcingsOf(w, input.sidecar.events, from, new Date(to.getTime() + w.minutes * MIN)).filter((f) => !input.queryId || f.queryId === input.queryId);
    const tuning = tuningOf(w, input.sidecar.events, from, new Date(to.getTime() + w.minutes * MIN)).filter((t) => !input.queryId || t.queryId === input.queryId);
    const details: QueryStoreDetails = clean({
        target,
        recorded,
        intervalMinutes: w.minutes,
        intervals: intervalsFrom && intervalsTo ? { from: iso(intervalsFrom), to: iso(intervalsTo) } : null,
        baseline: { from: iso(w.baselineFrom), to: iso(from) },
        rankBy,
        top: input.queryId ? top : top.slice(0, TOP_QUERIES),
        planChanges: changes,
        forcings,
        tuning,
        state: lastState ? clean({ state: lastState.state, captureMode: lastState.captureMode, intervalMinutes: lastState.intervalMinutes, gaps: lastState.gaps }) : null,
        pending,
        retention: retention ? { days: retention.days, past: retention.past } : null,
        measuredCpu: measuredCpuOf(input.resource, target, from, to),
    });
    const notCaptured = [
        ...(recorded === "yes" ? [] : notRecordedWords(target, recorded, input.sidecar, coverage, from, to)),
        // The rows' gaps, also beside Query Store's rows; a read replica's and T5's say only what the line above says.
        ...(kind === "sql" || kind === "postgresql" ? coverageGapLines(target, input.sidecar.coverage, from, to) : []),
    ];
    for (const p of pending) {
        notCaptured.push(
            p.expired
                ? `${target}: Query Store's minutes ${fromTo(new Date(p.from), new Date(p.to))} UTC were pending publication when the capture read them, and are past what T4's Query Store keeps (${QS_RETENTION_DAYS[target]} days, pg_qs.retention_period_in_days), so no later read can take them.`
                : `${target}: Query Store's minutes ${fromTo(new Date(p.from), new Date(p.to))} UTC are pending publication: PostgreSQL's Query Store shows an interval only once it ends (${PG_LEARN}), so the capture couldn't read them when it stopped. Its next start, with ${target} running, reads them into this history; until then, which queries ran in them isn't known.`,
        );
    }
    if (recorded === "yes" && kind === "postgresql") notCaptured.push(`${target}: PostgreSQL's Query Store records no CPU time, and here no plans (pg_qs.store_query_plans is off), so its queries are ranked by their time, and a plan change can't be told.`);
    const findings: Finding[] = [];
    const recommendations: Recommendation[] = [];
    const nextSteps: string[] = [];
    let rootCause: QueryStoreAnalysis["rootCause"] = null;
    const measure = cpuMeasure(target);
    const granularity = intervalsFrom && intervalsTo ? intervalWords(intervalsFrom, intervalsTo, w.minutes, sameIntervals(w.inWindow).length) : "";
    const ref = (at: Date, text: string, table = "RCA Query Stats"): EvidenceRef => ({ table, at: iso(at), target, text });

    // QS-PLAN-REGRESSION, with its forcing (QS-PLAN-FORCED) when the capture saw one.
    const regression = changes.find((c) => c.regression);
    if (regression) {
        const n = regression.newPlan;
        const b = regression.before.reduce<{ executions: number; total: number; from: string; to: string; intervals: number } | null>((acc, p) => {
            const value = (measureOf(p.perExecution, regression.measure) ?? 0) * p.executions;
            return acc ? { executions: acc.executions + p.executions, total: acc.total + value, from: p.from < acc.from ? p.from : acc.from, to: p.to > acc.to ? p.to : acc.to, intervals: Math.max(acc.intervals, p.intervals) } : { executions: p.executions, total: value, from: p.from, to: p.to, intervals: p.intervals };
        }, null);
        const word = regression.measure === "cpu" ? "of CPU" : "of time";
        const nowPer = measureOf(n.perExecution, regression.measure) ?? 0;
        const thenPer = b && b.executions ? b.total / b.executions : 0;
        const first = n.firstExecutionUtc ? new Date(n.firstExecutionUtc) : null;
        const last = n.lastExecutionUtc ? new Date(n.lastExecutionUtc) : null;
        const mixedRow = regression.mixed;
        const inMixed = mixedRow ? w.inWindow.filter((s) => s.intervalStart.getTime() === new Date(mixedRow.start).getTime()) : [];
        const mixedTotal = sum(inMixed, (s) => measureOf(s, regression.measure)) ?? 0;
        const newInMixed = sum(inMixed.filter((s) => s.planId === n.planId && s.queryId === regression.queryId), (s) => measureOf(s, regression.measure)) ?? 0;
        const tunedSame = tuning.some((t) => t.queryId === regression.queryId && (t.planId === n.planId || regression.before.some((p) => p.planId === t.planId)));
        const rose = input.incident && first ? input.incident.start.getTime() >= first.getTime() - MIN && input.incident.start.getTime() <= first.getTime() + 5 * MIN : false;
        const confidence: Confidence = tunedSame || rose ? "high" : "medium";
        const why = [rose && input.incident ? `the CPU rose at ${hhmmss(input.incident.start)} UTC, as the new plan first ran` : "", tunedSame ? "automatic tuning recommended forcing the earlier plan for the same query" : ""].filter(Boolean);
        const beforeNames = regression.before.map((p) => `plan ${p.planId}`).join(" and ");
        const which = regression.newPlan.compiledInWindow ? `a new plan: plan ${n.planId}, compiled at ${hhmmss(new Date(n.compiledUtc!))} UTC,` : `a plan it hadn't run in the hour before: plan ${n.planId}${n.compiledUtc ? `, compiled at ${hhmmss(new Date(n.compiledUtc))} UTC, before these minutes,` : ""}`;
        const shapes = [n.summary ? `Plan ${n.planId}'s shape, from its showplan: ${n.summary.replace(/\.$/, "")}.` : "", ...regression.before.filter((p) => p.summary).map((p) => `Plan ${p.planId}'s: ${p.summary!.replace(/\.$/, "")}.`)].filter(Boolean);
        const statement =
            `${capitalized(queryName(regression))} changed to ${which} ` +
            `which took ${ms(nowPer)} ${word} an execution over its ${count(n.executions)} executions${first && last ? ` ${fromTo(first, last)} UTC` : ""}, ` +
            `against ${ms(thenPer)} for ${beforeNames} in ${b ? intervalWords(new Date(b.from), new Date(b.to), w.minutes, b.intervals) : "the intervals before"}: ${timesWords(regression.times ?? 0)} as much.` +
            (mixedRow ? ` ${intervalWords(new Date(mixedRow.start), new Date(mixedRow.end), w.minutes, 1)} is mixed: ${beforeNames} also ran ${count(mixedRow.otherExecutions)} times in it` : "") +
            (mixedRow && mixedTotal > 0 ? `, and plan ${n.planId} used ${percentWords((newInMixed / mixedTotal) * 100)} of the captured top queries' ${regression.measure === "cpu" ? "CPU" : "time"} in it (${count(newInMixed)} of ${count(mixedTotal)} ms).` : mixedRow ? "." : "") +
            (why.length ? ` ${capitalized(why.join(", and "))}.` : "") +
            (shapes.length ? ` ${shapes.join(" ")}` : "");
        const evidence = [ref(first ?? from, `query ${regression.queryId}, plan ${n.planId}: ${count(n.executions)} executions, ${ms(nowPer)} ${word} each`), ...regression.before.map((p) => ref(new Date(p.from), `query ${regression.queryId}, plan ${p.planId}: ${count(p.executions)} executions, ${ms(measureOf(p.perExecution, regression.measure) ?? 0)} ${word} each`))];
        if (n.compiledUtc) evidence.push(ref(new Date(n.compiledUtc), `plan ${n.planId} compiled${n.summary ? `: ${n.summary}` : ""}`, "RCA Query Plans"));
        rootCause = { statement, confidence, ruleIds: ["QS-PLAN-REGRESSION"], evidence };
        findings.push({ ruleId: "QS-PLAN-REGRESSION", target, title: `Plan ${n.planId} of query ${regression.queryId}: ${ms(nowPer)} ${word} an execution, ${timesWords(regression.times ?? 0)} its earlier plan's`, detail: statement, severity: "critical", evidence });
        const forced = forcings.find((f) => f.kind === "forced" && f.queryId === regression.queryId && f.planId !== n.planId);
        if (forced) {
            const at = new Date(forced.at);
            const since = forced.from ? new Date(forced.from) : at;
            const how = forced.forcingType === "AUTO" ? "by automatic plan correction" : forced.forcingType === "MANUAL" ? "by hand (sys.sp_query_store_force_plan)" : "";
            const steps = tuning.filter((t) => t.queryId === regression.queryId).map((t) => `${t.state ?? "changed"} at ${hhmmss(new Date(t.at))} UTC`);
            const afterRows = w.stats.filter((s) => s.queryId === forced.queryId && s.intervalStart.getTime() >= since.getTime());
            const alone = afterRows.length > 0 && afterRows.every((s) => s.planId === forced.planId);
            const lastRead = afterRows.filter((s) => s.capturedAt.getTime() < s.intervalEnd.getTime()).map((s) => s.capturedAt.getTime());
            const recompiled = plans.get(`${forced.queryId}|${forced.planId}`)?.lastCompiled;
            const afterText = forced.after
                ? ` From ${intervalWords(new Date(forced.after.from), new Date(forced.after.to), w.minutes, sameIntervals(afterRows).length)}, plan ${forced.planId} ran ${alone ? "alone, " : ""}${count(forced.after.executions)} times at ${ms(measureOf(forced.after, regression.measure) ?? 0)} ${word} each${lastRead.length ? `; the last interval was still open when the capture last read it, at ${hhmmss(new Date(Math.max(...lastRead)))} UTC` : ""}.`
                : "";
            const recompiledText = recompiled && recompiled.getTime() >= since.getTime() ? ` It was compiled again at ${hhmmss(recompiled)} UTC.` : "";
            const lastNew = n.lastExecutionUtc ? ` Plan ${n.planId} last ran at ${hhmmss(new Date(n.lastExecutionUtc))} UTC.` : "";
            const text = `Plan ${forced.planId} of query ${forced.queryId} was forced ${how} between ${spanEnds(since, at).join(" and ")} UTC${steps.length ? ` (automatic tuning's recommendation: ${steps.join(", ")})` : ""}.${recompiledText}${lastNew}${afterText}`;
            findings.push({ ruleId: "QS-PLAN-FORCED", target, title: `Plan ${forced.planId} forced ${how}`.trim(), detail: text, severity: "info", evidence: [ref(at, text, "RCA Query Events")] });
            rootCause.statement += ` The response, as measured: ${text}`;
            rootCause.ruleIds.push("QS-PLAN-FORCED");
        }
        recommendations.push(...recommend("CPU-FORCE-PLAN", ...(target === "T3" && !forcings.some((f) => f.forcingType === "AUTO") ? ["CPU-AUTO-CORRECT"] : []), ...(n.summary && /isn't used|missing index/i.test(n.summary) ? ["CPU-MISSING-INDEX"] : [])));
    }

    // The top queries (QS-TOP-CPU and its changes), for a CPU incident, a window, or one query.
    const shown = details.top;
    if (shown.length && !input.incident?.family.match(/^(io|memory|parallelism|tran_log|log_rate|latch|network|blocking|deadlock)$/)) {
        const lines = shown.slice(0, 3).map((q) => {
            const value = measureOf(q.figures, measure);
            return `${queryName(q)}: ${count(q.figures.executions)} executions${value === undefined ? "" : `, ${totalWords(value, measure)}`}${q.share ? `, ${percentWords(q.share.percent)} of ${q.share.of}` : ""}; ${q.change.text}`;
        });
        const head = `${target}'s top queries by ${rankBy === "cpu" ? (measure === "cpu" ? "CPU" : "time") : rankBy} in ${granularity}`;
        findings.push({ ruleId: "QS-TOP-CPU", target, title: head, detail: `${head}: ${lines.join("; ")}.`, severity: "warning", evidence: shown.slice(0, 3).map((q) => ref(new Date(q.intervals[0]?.start ?? from), `${queryName(q)}: ${count(q.figures.executions)} executions`)) });
        for (const q of shown.slice(0, 3)) {
            const ruleId = q.change.kind === "more-calls" ? "QS-MORE-CALLS" : q.change.kind === "new-query" ? "QS-NEW-QUERY" : q.change.kind === "costlier" ? "QS-SAME-PLAN-COSTLIER" : null;
            if (ruleId) findings.push({ ruleId, target, title: `${queryName(q)}: ${q.change.text}`, detail: `${queryName(q)} in ${granularity}: ${q.change.text}.`, severity: "warning", evidence: [ref(new Date(q.intervals[0]?.start ?? from), `${queryName(q)}: ${q.change.text}`)] });
        }
        if (!rootCause && input.incident && (input.incident.family === "cpu" || input.incident.family === "connections")) {
            const q = shown[0];
            const value = measureOf(q.figures, measure);
            rootCause = {
                statement: `In ${granularity}, ${queryName(q)} used the most ${measure === "cpu" ? "CPU" : "time"} of the queries in Query Store's top lists: ${value === undefined ? "" : `${totalWords(value, measure)}, `}${q.share ? `${percentWords(q.share.percent)} of ${q.share.of}, ` : ""}over ${count(q.figures.executions)} executions; ${q.change.text}.${earlierWords(q)}`,
                confidence: q.change.kind === "more-calls" || q.change.kind === "costlier" || q.change.kind === "new-query" ? "medium" : "low",
                ruleIds: ["QS-TOP-CPU"],
                evidence: [ref(new Date(q.intervals[0]?.start ?? from), `${queryName(q)}: ${count(q.figures.executions)} executions`)],
            };
        }
        if (!regression) recommendations.push(...recommend(...(kind === "postgresql" ? ["PG-CPU"] : ["CPU-SARGABLE", "CPU-MISSING-INDEX"])));
    }

    // A wait family's queries (QS-WAITS): its Query Store category, and its figure.
    const family = input.incident?.family;
    const waitFamily = family ? WAIT_CATEGORIES[family] : undefined;
    if (waitFamily && recorded === "yes" && kind === "sql") {
        const byCategory = queryViews(w, plans, from, to, "waits")
            .map((q) => ({ q, waitMs: q.waits.filter((x) => x.category === waitFamily.category).reduce((n, x) => n + x.waitMs, 0) }))
            .filter((x) => x.waitMs > 0)
            .sort((a, b) => b.waitMs - a.waitMs)
            .slice(0, 3);
        const byFigure = waitFamily.figure
            ? [...queryViews(w, plans, from, to, "cpu")].filter((q) => (q.figures[waitFamily.figure!] ?? 0) > 0).sort((a, b) => (b.figures[waitFamily.figure!] ?? 0) - (a.figures[waitFamily.figure!] ?? 0)).slice(0, 3)
            : [];
        if (byCategory.length || byFigure.length) {
            const parts = [
                byCategory.length ? `by ${waitFamily.category} waits: ${byCategory.map((x) => `${queryName(x.q)} ${ms(x.waitMs)}`).join("; ")}` : `no query in Query Store's top lists recorded ${waitFamily.category} waits`,
                byFigure.length ? `by ${waitFamily.words}: ${byFigure.map((q) => `${queryName(q)} ${count(q.figures[waitFamily.figure!] ?? 0)}`).join("; ")}` : "",
            ].filter(Boolean);
            const text = `In ${granularity}, the queries ${parts.join("; and ")}.`;
            findings.push({ ruleId: "QS-WAITS", target, title: `${target}'s queries behind its ${waitFamily.category} waits`, detail: text, severity: "warning", evidence: (byCategory.length ? byCategory.map((x) => x.q) : byFigure).map((q) => ref(new Date(q.intervals[0]?.start ?? from), queryName(q), "RCA Query Waits")) });
            if (!rootCause && byCategory.length) rootCause = { statement: text, confidence: "medium", ruleIds: ["QS-WAITS"], evidence: [ref(new Date(byCategory[0].q.intervals[0]?.start ?? from), `${queryName(byCategory[0].q)}: ${waitFamily.category} ${ms(byCategory[0].waitMs)}`, "RCA Query Waits")] };
            recommendations.push(...recommend(waitFamily.rec));
        }
    }

    // A blocking chain's lock waits (QS-LOCK-WAITS): the queries that waited on locks in its intervals, with their longest execution.
    if ((family === "blocking" || family === "deadlock") && recorded === "yes") {
        const lockers = queryViews(w, plans, from, to, "waits")
            .map((q) => ({ q, lock: q.waits.filter((x) => x.category === "Lock") }))
            .filter((x) => x.lock.length)
            .slice(0, 3);
        if (lockers.length) {
            const text = `In ${granularity}, the queries that waited on locks: ${lockers
                .map(({ q, lock }) => {
                    const each = q.perExecution.durationMs;
                    return `${queryName(q)}, ${count(q.figures.executions)} executions${each === undefined ? "" : ` at ${ms(each)} each`}, the longest ${q.figures.maxDurationMs === undefined ? "not recorded" : ms(q.figures.maxDurationMs)}, waits ${lock.map(waitWords).join(", ")}${q.baseline ? ` (in the hour before: ${count(q.baseline.executionsPerInterval)} executions an interval at ${ms(q.baseline.perExecution.durationMs ?? 0)} each)` : ""}.${earlierWords(q)}`;
                })
                .join(" ")}`;
            findings.push({ ruleId: "QS-LOCK-WAITS", target, title: `${target}'s queries that waited on locks`, detail: text, severity: "warning", evidence: lockers.map(({ q }) => ref(new Date(q.intervals[0]?.start ?? from), queryName(q), "RCA Query Waits")) });
        }
    }

    if (retention?.step) nextSteps.push(retention.step);
    for (const c of changes.filter((c) => c.regression)) nextSteps.push(`Compare plan ${c.newPlan.planId} with ${c.before.map((p) => `plan ${p.planId}`).join(" and ")} of query ${c.queryId}: explain_queries with queryId ${c.queryId} gives both plans' shapes and figures.`);
    return { details, findings, rootCause, recommendations: [...new Map(recommendations.map((r) => [r.id, r])).values()], nextSteps, notCaptured };
}
