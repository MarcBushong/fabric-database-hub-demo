// The Copilot dock's investigation tools (ADR 0031). Like run_dax, each runs in the viewer's browser as the viewer: it
// reads the RCA evidence and the telemetry through the history connector (DAX, executeQuery only), finds the window's
// incidents with the blind detector, applies the deterministic rules, and returns facts with their times, a root cause
// with its confidence, the catalog's recommendations, next steps, and what wasn't captured. Blind: nothing here reads
// what anyone planned or ran. The relay forwards at most 16 tools (ask-relay/src/protocol.ts): the dock's 4 and these 7.

import { COSMOS_METRICS, cosmosSeries, POSTGRES_METRICS, postgresSeries, type Bin, type CosmosCapture, type PostgresCapture } from "@/data/model";
import { analyzeConnections } from "./connections";
import { describeEpisode, findEpisodes, SOURCES } from "./detector";
import { analyzeErrorsResult, AZURE_MONITOR } from "./errors";
import { EXPLAIN_QUERIES, EXPLAIN_QUERIES_DESCRIPTION, EXPLAIN_QUERIES_PROPS, explainQueries, incidentQueries, LOCK_WAIT_TABLES, queryArgs, queryReadWindow, readFailure, unexplainedWords, type SidecarRead } from "./explain-queries";
import { RCA_CATEGORY_IDS, RCA_SEVERITY_IDS, type RcaCategory, type RcaSeverity } from "./facet-ids";
import { categoryOf, facetArgs, FAR_PERCENT, FAR_TIMES, LONG_MINUTES, matches, severityOf } from "./facets";
import { isPagedTable, MONITOR_PAGES, MONITOR_ROW_LIMIT, RcaReadError } from "./loader";
import { analyzeLocking, type ChainNode } from "./locking";
import { analyzeQueries, coverageGapLines, queryStoreOf, type QueryStoreAnalysis } from "./queries";
import { queryStoreNextStep, queryStoreNote, queryStoreQuery, unexplainedByQuery, type QueryStoreQuery } from "./query-store";
import type { ConnectionGroup } from "./sidecar";
import { analyzeReplicaLag, LAG_METRIC } from "./replica";
import { RCA_SPEC } from "./spec";
import { analyzeThroughput } from "./throughput";
import { bothTimes, resolveTime, windowAround } from "./time";
import { triageWindow } from "./triage";
import { asWholeReadings, dateTime, emptyEvidence, fromTo, hhmmss, iso, metricIn, NEWEST_MINUTES, plural, pointKey, RCA_TARGETS, readStoppedAt, sameSecond, sameUtcDay, spanEnds, type Confidence, type Episode, type EventRow, type Evidence, type Finding, type InvestigationResult, type MetricPoint, type RcaTarget, type SessionSample, type WholeReading } from "./types";

/** The relay's ToolSpec shape (ask-relay/src/protocol.ts). */
export interface ToolSpec {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
}

const TIME = {
    type: "string",
    description:
        "A time as the viewer said it: 'HH:MM' (the viewer's time zone) or 'HH:MM UTC', which is the latest such time up to the history's newest data, or a date and time, taken as written: '2026-11-17T13:30:00Z' or '2026-11-17 13:30 UTC'.",
};
const TARGETS = { type: "array", items: { type: "string", enum: RCA_TARGETS }, description: "The targets to look at; all of them when omitted." };
const WINDOW_PROPS = {
    at: { ...TIME, description: `${TIME.description} Without at, or from and to: the history's newest ${NEWEST_MINUTES} minutes.` },
    from: { ...TIME, description: "The window's start, instead of at." },
    to: { ...TIME, description: "The window's end, with from." },
    minutesBefore: { type: "integer", minimum: 0, maximum: 120, description: "With at: minutes before it (default 5)." },
    minutesAfter: { type: "integer", minimum: 0, maximum: 120, description: "With at: minutes after it (default 5)." },
    targets: TARGETS,
};
const COMMON =
    " It reads the demo's saved history (what the capture recorded, and the telemetry from Database Hub and Azure Monitor), never the live estate, as the signed-in viewer. " +
    "It returns JSON: window (UTC and the viewer's local time), episodes (what the detector found, each with its support and source), findings with evidence rows (table, target, time), " +
    "rootCause with its confidence, recommendations (each with its Microsoft Learn page), nextSteps, and notCaptured. Quote its facts and times; don't add causes it doesn't give.";
/** The Root cause page's facets, as find_incidents and triage_window take them (facets.ts): targets among them, which narrow the list, never the read. */
const FACET_PROPS = {
    targets: { ...TARGETS, description: "Only incidents on these targets. The window is read on every target all the same, so nothingAbnormal and quiet stay the whole window's. All of them when omitted." },
    categories: {
        type: "array",
        items: { type: "string", enum: RCA_CATEGORY_IDS },
        description:
            "Only incidents of these categories, by the family of their signal: blocking; deadlocks; cpu; waits (buffer latch, memory, parallelism, network); errors; connections (T4's against the limit); replica_lag; throttling (T5's 429s and normalized RU at 100 %, and T3's log rate governor); io (PAGEIOLATCH and transaction log IO). All of them when omitted.",
    },
    severities: {
        type: "array",
        items: { type: "string", enum: RCA_SEVERITY_IDS },
        description: `Only incidents of these severities, from each one's own measurements, where far is ${FAR_TIMES} times its level, or ${FAR_PERCENT} % of a capacity: high (at or over far for ${LONG_MINUTES} minutes or more in all), medium (far at its peak, or over its level ${LONG_MINUTES} minutes or more), low (neither); a step lower when it was seen in one sample. All of them when omitted.`,
    },
};
const FACETS_NOTE =
    " Each episode has its category, its severity (high, medium, or low), and severityReason, the measurements behind it; details.servers names the servers the telemetry reported. " +
    "With targets, categories, or severities, details.filters says which, and details.leftOut what they left out, on every target: episodes, hypotheses, and lines of notCaptured about other targets, by category and target. The window is read on every target, so nothingAbnormal and quiet stay about every incident in it.";

export const INVESTIGATION_TOOL_SPECS: ToolSpec[] = [
    {
        name: "find_incidents",
        description: "Lists the incidents around a time or in a window, per target: the episodes the detector finds in the capture and the telemetry (blocking, deadlocks, CPU, wait classes, error bursts, read replica lag, T4's connections, T5's throttling), each with its key, how it was seen, and whether the capture covered it. Use it when the viewer asks what happened, or to find an incident's key. Narrow it by targets, categories, and severities, as the Root cause page does." + FACETS_NOTE + COMMON,
        parameters: { type: "object", properties: { ...WINDOW_PROPS, ...FACET_PROPS }, additionalProperties: false },
    },
    {
        name: "triage_window",
        description: "First-line triage for a time or window: what was abnormal on each target (blocking, deadlocks, CPU, wait classes, errors, T4's connections against the limit, T5 throttling and RU, read replica lag), ranked, each with the tool that explains it. Call it first for 'why was it slow at ...' questions; it also says when nothing was abnormal. Narrow it by targets, categories, and severities." + FACETS_NOTE + COMMON,
        parameters: { type: "object", properties: { ...WINDOW_PROPS, ...FACET_PROPS }, additionalProperties: false },
    },
    {
        name: "explain_incident",
        description: "The full root cause analysis of one incident: its episodeKey from find_incidents or triage_window (or a target with from and to). It runs the investigations that fit its signal, ranks the causes it finds in those minutes by confidence, and returns one combined answer. The RCA view's 'Explain this incident' and the postmortem's Cause use it." + COMMON,
        parameters: {
            type: "object",
            properties: { episodeKey: { type: "string", description: "The episode's key." }, target: { type: "string", enum: RCA_TARGETS, description: "Instead of a key: the target, with from and to." }, from: WINDOW_PROPS.from, to: WINDOW_PROPS.to },
            additionalProperties: false,
        },
    },
    {
        name: "explain_locking",
        description: "Blocking and locks in a window: each blocking chain as a tree with its head blocker first (its module or statement, program, login, host, status, open transaction, how long it was idle, the lock it held and on what), how many sessions it blocked, the chain's depth and width, the longest wait; lock escalations to table locks; and deadlocks (victim, resources, both statements, the pattern). SQL Server, Azure SQL Database (optimized locking), and PostgreSQL." + COMMON,
        parameters: { type: "object", properties: WINDOW_PROPS, additionalProperties: false },
    },
    {
        name: "explain_errors",
        description: "The errors in a window by class, with counts, first and last times, targets, and who hit them: deadlock victims, lock timeouts, timeouts and cancels (attentions), refused connections and failed logins (T4's failed connections from Azure Monitor), resource governance, replica queries cancelled by replay, PostgreSQL SQLSTATE classes, and T5's 429s; each with its usual cause and the tool that explains it." + COMMON,
        parameters: { type: "object", properties: WINDOW_PROPS, additionalProperties: false },
    },
    {
        name: "explain_replica_lag",
        description: "Why T4's read replica lagged around a time: the lag's rise, peak, and recovery (Read Replica Lag, or the replica's own replay samples), and the reason: catch-up after a restart, replay standing still behind a lock a replica query held (hot standby conflict), slow replay, WAL not shipped, or an idle primary; with the replica query, the relation, both lock modes, the WAL rate, and max_standby_streaming_delay." + COMMON,
        parameters: { type: "object", properties: { at: TIME, minutesBefore: WINDOW_PROPS.minutesBefore, minutesAfter: WINDOW_PROPS.minutesAfter }, required: ["at"], additionalProperties: false },
    },
    {
        name: EXPLAIN_QUERIES,
        description: EXPLAIN_QUERIES_DESCRIPTION + COMMON,
        parameters: {
            type: "object",
            properties: { ...EXPLAIN_QUERIES_PROPS, at: WINDOW_PROPS.at, from: WINDOW_PROPS.from, to: WINDOW_PROPS.to, minutesBefore: WINDOW_PROPS.minutesBefore, minutesAfter: WINDOW_PROPS.minutesAfter },
            required: ["target"],
            additionalProperties: false,
        },
    },
];

export const INVESTIGATION_TOOL_NAMES: readonly string[] = INVESTIGATION_TOOL_SPECS.map((s) => s.name);

/** The telemetry the detector reads beside the capture: Database Hub's bins (T1 to T3) and Azure Monitor's captures (T4, T5). */
export interface Telemetry {
    bins?: readonly Bin[];
    postgres?: PostgresCapture | null;
    cosmos?: CosmosCapture | null;
    /** Each Azure Monitor point's span, by pointKey (the shared finestPerInterval's intervals): what it covers, for coverage, ends, and sums. */
    intervals?: ReadonlyMap<string, number>;
    /** Each point's save's step, by pointKey (its grains): what its value is the highest or the total of, to step runs by and name. */
    grains?: ReadonlyMap<string, number>;
    /** The coarser point each piece came from, and the pieces that are upper bounds of one reading, by pointKey (its sources and upperBounds). */
    sources?: ReadonlyMap<string, string>;
    upperBounds?: ReadonlySet<string>;
    /** Each piece of a point split into two or more, by pointKey: the one whole reading it's part of (sources.ts's wholeReadings). */
    wholes?: ReadonlyMap<string, WholeReading>;
    /** The points whose interval isn't known in these minutes, by pointKey (sources.ts's unknownIntervals). */
    unknownIntervals?: ReadonlySet<string>;
    /** The coarsest interval of the history's points at each time, before one point per interval is kept (sources.ts's coarsestIntervals): a key's own point. */
    keyIntervals?: ReadonlyMap<string, number>;
    /** The reads that had more rows than they take, by table: what they hold from `until` on wasn't read (sources.ts's paged Azure Monitor read). */
    cut?: ReadonlyArray<{ table: string; until: Date }>;
}

export interface InvestigationDeps {
    /** The RCA evidence of a window (production: loader.ts's DAX through the history connector; tests: the fixtures). */
    load: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Evidence>;
    /** The telemetry of a window, when the app has it. */
    telemetry?: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Telemetry>;
    timeZone: string;
    /** The history's newest day in the viewer's time zone, from which bare times are read. */
    latestDay: Date;
    /** The history's newest telemetry time: without a time, a window is the NEWEST_MINUTES before it. */
    latest?: Date;
    /**
     * The viewer's clock, for how old an incident's minutes are now, which is what a target's Query Store retention counts
     * (query-store.ts); the current time by default. Not the history's newest time, which stays put while the demo is stopped.
     */
    now?: () => Date;
    /**
     * Query Store's evidence of a window, what the capture saved of it (the sidecar: loader.ts's loadSidecar through the
     * history connector). With it, explain_queries answers, and CPU, the wait classes, and a blocking chain's statements are
     * explained from it; without it, explain_queries says so, and the others say what query-store.ts says.
     */
    sidecar?: SidecarRead;
}

const RESULT_CHARS = 60_000;
const MIN = 60_000;
/** The detector's baselines read the minutes before a window. */
const LEAD_MINUTES = 30;
/**
 * A key's minutes are read from this much earlier than its time, besides LEAD_MINUTES: the episodes before it then have
 * baselines of their own, as in the list that gave the key, and the detector leaves them out of its baseline. Read from
 * the key's own time, a CPU incident on T2 that the day's list gave from 16:19 started a sample later, at 16:20, so its
 * key had none (Final tests' check of ddebd4c3, F1).
 */
const KEY_LEAD_MINUTES = 30;
/** One sample of the telemetry: Database Hub's bins are a minute, and the capture's samples are finer. */
const ONE_SAMPLE_MS = 60_000;
/** How many more times the replica's lag is read while its rise runs past the minutes read, and how far past their end an unrecovered rise is read each time: at most 4 reads, 45 minutes past the first. */
const REPLICA_REREADS = 3;
const REPLICA_STEP_MINUTES = 15;
/** Azure Monitor's ProvisionedThroughput is hourly: a point stands for its hour. */
const HOUR = 60 * MIN;
/** Each Azure Monitor family's own metric, whose point at a key's time gives the key's first interval. */
const FAMILY_METRIC: Readonly<Record<string, string>> = { replica_lag: LAG_METRIC, cpu: POSTGRES_METRICS.cpu, throttling: COSMOS_METRICS.throttled, ru: COSMOS_METRICS.normalizedRu };

function windowOf(args: Record<string, unknown>, deps: InvestigationDeps): { from: Date; to: Date; at?: Date } | string {
    const str = (k: string) => (typeof args[k] === "string" ? (args[k] as string) : undefined);
    const num = (k: string, d: number) => (typeof args[k] === "number" && Number.isFinite(args[k]) ? Math.max(0, Math.min(120, args[k] as number)) : d);
    if (str("from") && str("to")) {
        const from = resolveTime(str("from")!, deps.latestDay, deps.timeZone, deps.latest);
        const to = resolveTime(str("to")!, deps.latestDay, deps.timeZone, deps.latest);
        if (!from || !to || to <= from) return "from and to must be times, with from before to.";
        return { from, to };
    }
    const at = str("at") ? resolveTime(str("at")!, deps.latestDay, deps.timeZone, deps.latest) : null;
    if (!at && !str("at") && deps.latest) return { from: new Date(deps.latest.getTime() - NEWEST_MINUTES * MIN), to: deps.latest };
    if (!at) return "Give at (a time), or from and to.";
    return { ...windowAround(at, num("minutesBefore", 5), num("minutesAfter", 5)), at };
}

function targetsOf(args: Record<string, unknown>): RcaTarget[] {
    const list = Array.isArray(args.targets) ? args.targets.filter((t): t is RcaTarget => RCA_TARGETS.includes(t as RcaTarget)) : [];
    return list.length ? list : [...RCA_TARGETS];
}

/** The Azure Monitor series the investigations read, as metric points, each with its interval: the replica's lag, T4's failed connections and CPU, T5's 429s, RU, requests, and its hourly provisioned throughput. */
export function monitorMetrics(telemetry: Telemetry): MetricPoint[] {
    const out: MetricPoint[] = [];
    // Each point's own span and its save's step where the history says them (the shared finestPerInterval's intervals and
    // grains), its capture's smallest interval otherwise (the review of 803f2b1a). A point whose interval the read can't
    // tell gets none (the review of c4c63abe), and a piece of a split point carries its whole reading.
    const own = (target: RcaTarget, metric: string, at: Date, fallback: number | undefined) => {
        const key = pointKey(target, metric, at);
        const whole = telemetry.wholes?.get(key);
        if (telemetry.unknownIntervals?.has(key)) return { intervalMs: undefined, grainMs: undefined, intervalUnknown: true, ...(whole ? { whole } : {}) };
        const intervalMs = telemetry.intervals?.get(key) ?? fallback;
        return { intervalMs, grainMs: telemetry.grains?.get(key) ?? intervalMs, ...(whole ? { whole } : {}) };
    };
    const pg = telemetry.postgres ?? null;
    const pgInterval = pg?.intervalMinutes ? pg.intervalMinutes * MIN : undefined;
    for (const p of postgresSeries(pg, "T4-replica", POSTGRES_METRICS.lag)) out.push({ target: "T4-replica", at: p.at, metric: LAG_METRIC, value: p.value, ...own("T4-replica", POSTGRES_METRICS.lag, p.at, pgInterval) });
    for (const target of ["T4", "T4-replica"] as const) {
        for (const p of postgresSeries(pg, target, POSTGRES_METRICS.failed)) out.push({ target, at: p.at, metric: POSTGRES_METRICS.failed, value: p.value, ...own(target, POSTGRES_METRICS.failed, p.at, pgInterval) });
        for (const p of postgresSeries(pg, target, POSTGRES_METRICS.cpu)) out.push({ target, at: p.at, metric: POSTGRES_METRICS.cpu, value: p.value, ...own(target, POSTGRES_METRICS.cpu, p.at, pgInterval) });
    }
    const cosmos = telemetry.cosmos ?? null;
    const cosmosInterval = cosmos?.intervalMinutes ? cosmos.intervalMinutes * MIN : undefined;
    for (const metric of [COSMOS_METRICS.throttled, COSMOS_METRICS.normalizedRu, COSMOS_METRICS.requests]) for (const p of cosmosSeries(cosmos, metric)) out.push({ target: "T5", at: p.at, metric, value: p.value, ...own("T5", metric, p.at, cosmosInterval) });
    for (const p of cosmosSeries(cosmos, COSMOS_METRICS.provisioned)) out.push({ target: "T5", at: p.at, metric: COSMOS_METRICS.provisioned, value: p.value, intervalMs: HOUR, grainMs: HOUR });
    return out.sort((a, b) => a.at.getTime() - b.at.getTime());
}

/** Error counts the telemetry and the capture's counters hold, as events: T4's failed connections and deadlocks, T5's 429s. An Azure Monitor count stands for its whole interval, and a split point's pieces for its one whole count. */
function countedErrors(evidence: Evidence, from: Date, to: Date, targets: readonly RcaTarget[]): EventRow[] {
    const inside = (at: Date) => at >= from && at <= to;
    const out: EventRow[] = [];
    // A count that's part of a whole reading, in words: the save's whole interval, and what the finer saves hold of it.
    const of = (m: MetricPoint) => {
        const w = m.whole;
        if (w) {
            const covered = w.covered.map((c) => `${hhmmss(c.from).slice(0, 5)} to ${hhmmss(c.to).slice(0, 5)}`).join(" and ");
            return `in the ${Math.round(w.intervalMs / MIN)} minutes from ${hhmmss(w.at).slice(0, 5)} UTC (Azure Monitor${w.finer !== null && covered ? `; a finer save holds ${w.finer === 0 ? "none" : w.finer} of them, in ${covered}` : ""})`;
        }
        return m.intervalUnknown ? `in the interval from ${hhmmss(m.at).slice(0, 5)} UTC, whose length isn't known in these minutes (Azure Monitor)` : "in the interval (Azure Monitor)";
    };
    // The window's points first: a window inside a finer save's stretch reads that save, not the coarser point around it.
    for (const m of asWholeReadings(evidence.metrics.filter((m) => targets.includes(m.target) && metricIn(m, from, to)))) {
        if (m.value === null || m.value <= 0) continue;
        if (m.metric === POSTGRES_METRICS.failed) out.push({ target: m.target, at: m.at, kind: "error", name: AZURE_MONITOR, code: "connections_failed", count: m.value, intervalMs: m.intervalMs, ...(m.intervalUnknown ? { intervalUnknown: true } : {}), program: `${m.target}'s clients`, detail: `${plural(m.value, "failed connection")} ${of(m)}` });
        if (m.metric === COSMOS_METRICS.throttled) out.push({ target: m.target, at: m.at, kind: "error", name: AZURE_MONITOR, code: "429", count: m.value, intervalMs: m.intervalMs, ...(m.intervalUnknown ? { intervalUnknown: true } : {}), program: "the container's clients", detail: `${plural(m.value, "throttled request")} (429) ${of(m)}` });
    }
    // PostgreSQL logs a deadlock's graph only to its server log; the capture counts them (pg_stat_database.deadlocks).
    for (const r of evidence.resource) {
        if (r.metric === "deadlocks" && r.source.startsWith("RCA-PG") && r.value > 0 && targets.includes(r.target) && inside(r.at)) {
            out.push({ target: r.target, at: r.at, kind: "error", name: "pg_stat_database.deadlocks", code: "40P01", count: r.value, detail: `pg_stat_database.deadlocks rose by ${r.value}` });
        }
    }
    return out;
}

interface Gathered {
    evidence: Evidence;
    episodes: Episode[];
    keyIntervals?: ReadonlyMap<string, number>;
    /** The servers the window's Azure Monitor metrics name: T4's, its replica's, and T5's account. */
    servers?: Partial<Record<RcaTarget, string>>;
}

const episodeView = (e: Episode) => {
    const s = severityOf(e);
    return {
        key: e.key,
        target: e.target,
        family: e.family,
        signal: e.signal,
        support: e.support,
        source: e.source,
        start: iso(e.start),
        end: e.end ? iso(e.end) : null,
        peak: `${Math.round(e.peak * 10) / 10}${e.unit === "%" ? " %" : ` ${e.unit}`}`,
        category: categoryOf(e.family),
        severity: s.severity,
        severityReason: s.reason,
    };
};

/** A triage finding's severity, from its incident's (facets.ts): High is critical, Medium a warning, Low information. */
const FINDING_SEVERITY: Readonly<Record<RcaSeverity, "critical" | "warning" | "info">> = { high: "critical", medium: "warning", low: "info" };

/**
 * The note for a target with no capture in a window, and whether a line is one: an incident says it once. A line is one in
 * either form: none recorded, or a coverage row marked not captured, as T5's are in B's model ("no RCA evidence for"), which
 * a part reading wider minutes said again for a span after the storm had ended (Final tests' check of ddebd4c3, F2). Each
 * says one instant "at" it, never as a range of it (F5: "no RCA capture recorded for 16:57:00-16:57:00 UTC"), and a span
 * across two UTC days with its dates, "from … to …" (the review of 921d3097: a day's minutes read "at 17:00:00 UTC").
 */
const forSpan = (from: Date, to: Date) => (sameSecond(from, to) ? `at ${hhmmss(from)}` : sameUtcDay(from, to) ? `for ${hhmmss(from)}-${hhmmss(to)}` : `from ${dateTime(from)} to ${dateTime(to)}`);
const noCaptureNote = (t: RcaTarget, from: Date, to: Date) => `${t}: no RCA capture recorded ${forSpan(from, to)} UTC; only the telemetry (Telemetry Snapshots) is known`;
const isNoCaptureNote = (t: RcaTarget, line: string) => {
    if (!line.startsWith(`${t}: `)) return false;
    const rest = line.slice(t.length + 2);
    return /^no RCA capture recorded (?:for|at|from) .*; only the telemetry \(Telemetry Snapshots\) is known$/.test(rest) || /^no RCA evidence (?:for|at|from) /.test(rest);
};

function envelope(tool: string, from: Date, to: Date, targets: readonly RcaTarget[], deps: InvestigationDeps, g: Gathered, at?: Date): InvestigationResult {
    const coverage = g.evidence.coverage.filter((c) => targets.includes(c.target) && c.to >= from && c.from <= to);
    // No coverage row at all: the capture didn't run then (history saved before the environment had it, or T5, which has no observer).
    const unknown = targets
        .filter((t) => !coverage.some((c) => c.target === t))
        .map((t) => noCaptureNote(t, from, to));
    const notCaptured = [
        ...coverage.flatMap((c) => (c.captured ? c.gaps.map((gap) => `${c.target}: ${gap}`) : [`${c.target}: no RCA evidence ${forSpan(c.from, c.to)} UTC${c.gaps.length ? ` (${c.gaps.join("; ")})` : ""}`])),
        ...unknown,
        ...(g.evidence.cut ?? []).map((c) => `${c.table}: the window holds more rows than ${isPagedTable(c.table) ? `its ${MONITOR_PAGES} reads of ${MONITOR_ROW_LIMIT} return` : "one query returns"}, so what it holds from ${hhmmss(c.until)} UTC on wasn't read; ask about a narrower window`),
    ];
    return {
        tool,
        version: 1,
        window: { fromUtc: iso(from), toUtc: iso(to), local: `${bothTimes(from, deps.timeZone)} to ${bothTimes(to, deps.timeZone)}`, ...(at ? { asked: bothTimes(at, deps.timeZone) } : {}) },
        targets: [...targets],
        episodes: g.episodes.filter((e) => targets.includes(e.target) && e.start <= to && (e.end ?? e.last) >= from).map(episodeView),
        findings: [],
        rootCause: null,
        recommendations: [],
        nextSteps: [],
        notCaptured,
    };
}

/** What a result's details keep however it's cut: the verdicts, where a read stopped, the servers, and the filters with what they left out. */
const KEPT_DETAILS = ["nothingAbnormal", "nothingAbnormalUpTo", "quiet", "quietUpTo", "readStoppedAt", "servers", "filters", "leftOut"] as const;

const SEVERITY_ORDER: Readonly<Record<string, number>> = { high: 0, medium: 1, low: 2 };

/** A list without each item's severityReason: its episode's, which explain_incident gives with its key. */
function withoutReasons(list: unknown): unknown {
    if (!Array.isArray(list)) return list;
    return list.map((item: unknown) => {
        if (!item || typeof item !== "object" || !("severityReason" in item)) return item;
        const rest: Record<string, unknown> = { ...(item as Record<string, unknown>) };
        delete rest.severityReason;
        return rest;
    });
}

/**
 * A result as the text Copilot reads: within `limit` characters, and always JSON that parses (the review of 90e9d914: a
 * 24-hour list ended " [cut]", invalid, with notCaptured and nextSteps gone, yet answered ok). Past the limit it leaves out,
 * in turn: each episode's severityReason; the details but the verdicts, the servers, and the filters with what they left
 * out (KEPT_DETAILS) and triage's hypotheses; then the least severe episodes, and the last findings and hypotheses, saying
 * how many more there were. notCaptured, nextSteps, and the root cause are always kept.
 */
export function bounded(result: InvestigationResult, limit = RESULT_CHARS): string {
    const fit = (r: unknown) => {
        const text = JSON.stringify(r);
        return text.length <= limit ? text : null;
    };
    const whole = fit(result);
    if (whole) return whole;
    const details = (result.details ?? {}) as Record<string, unknown>;
    const reasons = "Each episode's severityReason is left out to fit: explain_incident with its key gives it.";
    const lean: InvestigationResult = {
        ...result,
        episodes: withoutReasons(result.episodes) as InvestigationResult["episodes"],
        details: { ...details, ...("hypotheses" in details ? { hypotheses: withoutReasons(details.hypotheses) } : {}), ...("episodes" in details ? { episodes: withoutReasons(details.episodes) } : {}), cut: reasons },
    };
    const leanText = fit(lean);
    if (leanText) return leanText;
    const kept: Record<string, unknown> = Object.fromEntries(KEPT_DETAILS.filter((k) => k in details).map((k) => [k, details[k]]));
    const hypotheses = Array.isArray(lean.details?.hypotheses) ? (lean.details.hypotheses as unknown[]) : null;
    const findings = result.findings.map((f) => ({ ...f, evidence: f.evidence.slice(0, 3) }));
    // The most severe episodes first, in their order otherwise.
    const episodes = lean.episodes.map((e, i) => ({ e, i })).sort((a, b) => (SEVERITY_ORDER[a.e.severity] ?? 3) - (SEVERITY_ORDER[b.e.severity] ?? 3) || a.i - b.i);
    const shaped = (n: number): InvestigationResult => {
        const keep = episodes.slice(0, n).sort((a, b) => a.i - b.i).map((x) => x.e);
        const more = { episodes: lean.episodes.length - keep.length, findings: Math.max(0, findings.length - n), hypotheses: hypotheses ? Math.max(0, hypotheses.length - n) : 0 };
        const left = Object.entries(more).filter(([, count]) => count > 0);
        const note = left.length
            ? `Cut to fit: ${left.map(([what, count]) => `${count} more ${what}`).join(", ")}, the least severe and the last, are left out. Ask about a narrower window, or filter find_incidents and triage_window by targets, categories, or severities.`
            : "Details cut to fit; ask a narrower question.";
        return {
            ...lean,
            episodes: keep,
            findings: findings.slice(0, n),
            details: { ...kept, ...(hypotheses ? { hypotheses: hypotheses.slice(0, n) } : {}), cut: `${reasons} ${note}`, ...(left.length ? { more: Object.fromEntries(left) } : {}) },
        };
    };
    // The most of each list that fits, at most each list's length.
    let lo = 0;
    let hi = Math.max(lean.episodes.length, findings.length, hypotheses?.length ?? 0);
    while (lo < hi) {
        const mid = Math.ceil((lo + hi) / 2);
        if (fit(shaped(mid))) lo = mid;
        else hi = mid - 1;
    }
    const best = fit(shaped(lo));
    if (best) return best;
    // Not even without every list (never seen): as many of what wasn't captured's lines as fit, still as JSON.
    const bare = shaped(0);
    for (let n = bare.notCaptured.length - 1; n >= 0; n--) {
        const text = fit({ ...bare, notCaptured: [...bare.notCaptured.slice(0, n), `${bare.notCaptured.length - n} more lines of what wasn't captured are left out to fit.`] });
        if (text) return text;
    }
    return JSON.stringify({ tool: result.tool, version: result.version, window: result.window, targets: result.targets, episodes: [], findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: ["The result is too large to return: ask about a narrower window."] });
}

const RANK: Record<Confidence, number> = { high: 3, medium: 2, low: 1 };

/** The episodes a part explains with a cause from the capture or the metrics; the others (CPU, the wait classes) from Query Store's evidence when this history holds it, else from the telemetry alone. */
export const EXPLAINED_FAMILIES: readonly string[] = ["blocking", "deadlock", "replica_lag", "errors", "connections", "throttling", "ru"];

/** One session of a chain, head first, with what a DBA reads off it: what it ran, who ran it, its wait, and its lock. */
export interface ChainNodeView {
    session: number;
    level: number;
    status?: string;
    module?: string;
    statement?: string;
    inputBuffer?: string;
    program?: string;
    login?: string;
    host?: string;
    waitType?: string;
    waitS?: number;
    idleS?: number;
    openTransactions?: number;
    lock?: { type?: string; object?: string; index?: string; held?: string; wanted?: string };
    children: ChainNodeView[];
}

/** Blocked sessions per capture sample and target, oldest first: the view's timeline. */
function blockedSeries(sessions: readonly SessionSample[]): Array<{ target: RcaTarget; at: string; blocked: number }> {
    const out = new Map<string, { target: RcaTarget; at: string; blocked: number }>();
    for (const s of sessions) {
        const key = `${s.target}|${s.capturedAt.getTime()}`;
        const point = out.get(key) ?? { target: s.target, at: iso(s.capturedAt), blocked: 0 };
        if (s.blockedBy.length > 0) point.blocked += 1;
        out.set(key, point);
    }
    return [...out.values()].sort((a, b) => a.at.localeCompare(b.at) || a.target.localeCompare(b.target));
}

function nodeView(node: ChainNode): ChainNodeView {
    const r = node.row;
    const s = (ms: number | undefined) => (ms === undefined ? undefined : Math.round(ms / 100) / 10);
    const lock = r && (r.lockObject || r.lockResourceType) ? { type: r.lockResourceType, object: r.lockObject, index: r.lockIndex, held: r.lockModeHeld, wanted: r.lockModeWanted } : undefined;
    return {
        session: node.session,
        level: node.level,
        ...(r
            ? {
                  status: r.status,
                  module: r.module,
                  statement: r.statement,
                  inputBuffer: r.inputBuffer,
                  program: r.program,
                  login: r.login,
                  host: r.host,
                  waitType: r.waitType,
                  waitS: s(r.waitMs),
                  idleS: s(r.idleMs),
                  openTransactions: r.openTransactions,
              }
            : {}),
        ...(lock ? { lock } : {}),
        children: node.children.map(nodeView),
    };
}
const KEY = /^(T1|T2|T3|T4|T4-replica|T5)-([a-z_]+)-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;

export function createInvestigationTools(deps: InvestigationDeps) {
    /** The window's evidence (from LEAD_MINUTES before it, for the baselines), its telemetry, and its episodes. */
    async function gather(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Gathered> {
        const lead = new Date(from.getTime() - LEAD_MINUTES * MIN);
        const [loaded, telemetry] = await Promise.all([deps.load(lead, to, targets), deps.telemetry ? deps.telemetry(lead, to, targets) : Promise.resolve<Telemetry>({})]);
        // A read at its limit, the RCA tables' or Azure Monitor's, is said in what wasn't captured, never used silently.
        const cut = [...(loaded.cut ?? []), ...(telemetry.cut ?? [])];
        const evidence: Evidence = { ...emptyEvidence(), ...loaded, metrics: [...loaded.metrics, ...monitorMetrics(telemetry)], ...(cut.length ? { cut } : {}) };
        const episodes = findEpisodes({ evidence, bins: telemetry.bins, postgres: telemetry.postgres, cosmos: telemetry.cosmos, intervals: telemetry.intervals, grains: telemetry.grains, sources: telemetry.sources, upperBounds: telemetry.upperBounds, wholes: telemetry.wholes }, from, to).filter((e) => targets.includes(e.target));
        const named: Partial<Record<RcaTarget, string>> = { ...(telemetry.postgres?.servers ?? {}), ...(telemetry.cosmos?.account ? { T5: telemetry.cosmos.account } : {}) };
        const servers = Object.fromEntries(Object.entries(named).filter(([t, name]) => name && targets.includes(t as RcaTarget))) as Partial<Record<RcaTarget, string>>;
        return { evidence, episodes, keyIntervals: telemetry.keyIntervals, servers };
    }

    /**
     * Query Store's lock waits in the chains' minutes, per target whose Query Store records them (QS-LOCK-WAITS: the queries
     * that waited on locks in those intervals, with their longest execution), and any read that failed, which is said and
     * concludes nothing. Without the sidecar, none.
     */
    async function lockWaitsOf(chains: ReadonlyArray<{ target: RcaTarget; first: Date; last: Date }>): Promise<{ findings: Finding[]; notCaptured: string[] }> {
        const read = deps.sidecar;
        if (!read) return { findings: [], notCaptured: [] };
        const spans = new Map<RcaTarget, { from: Date; to: Date }>();
        for (const c of chains) {
            const kind = queryStoreOf(c.target);
            if (kind !== "sql" && kind !== "postgresql") continue;
            const s = spans.get(c.target);
            spans.set(c.target, s ? { from: c.first < s.from ? c.first : s.from, to: c.last > s.to ? c.last : s.to } : { from: c.first, to: c.last });
        }
        const now = (deps.now ?? (() => new Date()))();
        const found = await Promise.all(
            [...spans].map(async ([target, { from, to }]) => {
                const w = queryReadWindow(from, to);
                try {
                    const sidecar = await read(w.from, w.to, [target], LOCK_WAIT_TABLES);
                    const a = analyzeQueries({ target, from, to, sidecar, incident: { family: "blocking", start: from, end: to, last: to }, now });
                    return { findings: a.findings.filter((f) => f.ruleId === "QS-LOCK-WAITS"), notCaptured: [] };
                } catch (err) {
                    return { findings: [], notCaptured: [readFailure(target, from, to, err)] };
                }
            }),
        );
        return { findings: found.flatMap((f) => f.findings), notCaptured: found.flatMap((f) => f.notCaptured) };
    }

    async function locking(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        const targets = targetsOf(args);
        const g = await gather(w.from, w.to, targets);
        const inside = (at: Date) => at >= w.from && at <= w.to;
        const sessions = g.evidence.sessions.filter((s) => targets.includes(s.target) && inside(s.capturedAt));
        const events = [...g.evidence.events.filter((e) => targets.includes(e.target) && inside(e.at)), ...countedErrors(g.evidence, w.from, w.to, targets).filter((e) => e.code === "40P01")];
        const a = analyzeLocking(sessions, events, w.at);
        const base = envelope("explain_locking", w.from, w.to, targets, deps, g, w.at);
        // Blocked processes the detector saw, on a target the capture covered, with no chain in its samples: say why there's
        // none, rather than leave the cause blank (live, 2026-11-21's audit). The sentinel saw them only when the episode is
        // the capture's or its own minutes were captured; Database Hub's telemetry can see blocking before the capture runs
        // (the re-review of bb70161f).
        const pg = (t: RcaTarget) => t === "T4" || t === "T4-replica";
        const covered = (t: RcaTarget, from: Date, to: Date) => g.evidence.coverage.some((c) => c.target === t && c.captured && c.from <= to && c.to >= from);
        // The chains read only up to where the RCA Sessions read stopped: no chain is claimed for the minutes after it (the
        // review of eb89acbb).
        const sessionsStop = readStoppedAt(g.evidence, (table) => table === RCA_SPEC.sessions.model);
        const chainsTo = sessionsStop && sessionsStop < w.to ? sessionsStop : w.to;
        const stoppedNote = chainsTo < w.to ? ", where the RCA Sessions read stopped," : "";
        const noChain = targets.flatMap((t) => {
            const seen = g.episodes.filter((e) => e.target === t && e.family === "blocking" && e.start <= w.to && (e.end ?? e.last) >= w.from);
            if (seen.length === 0 || a.episodes.some((e) => e.target === t) || !covered(t, w.from, w.to)) return [];
            if (seen.some((e) => e.source === SOURCES.capture || covered(t, e.start, e.end ?? e.last))) {
                if (chainsTo <= w.from || !seen.some((e) => e.start <= chainsTo)) return [];
                return [
                    `${t}: the blocked processes ${fromTo(w.from, chainsTo)} UTC${stoppedNote} left no blocking chain in the capture: its 30-s sentinel saw ${pg(t) ? "a client waiting on a lock" : "a blocked process"}, and the capture samples the chain (${pg(t) ? "RCA-PG-01 and RCA-PG-02" : "RCA-SQL-01"}) every 10 s from then on, so the blocking ended before its next chain sample, and neither the head blocker nor its statement is known.`,
                ];
            }
            const from = new Date(Math.min(...seen.map((e) => e.start.getTime())));
            const to = new Date(Math.max(...seen.map((e) => (e.end ?? e.last).getTime())));
            return [`${t}: the blocked processes ${fromTo(from, to)} UTC are in Database Hub's telemetry only: the capture wasn't running then, so it has no blocking chain for them, and neither the head blocker nor its statement is known.`];
        });
        // The statements behind the chains, from Query Store's evidence of their minutes (QS-LOCK-WAITS), beside the chains
        // the capture sampled; a read that failed is said, and the chains stand.
        const lockWaits = await lockWaitsOf(a.episodes);
        return {
            ...base,
            findings: [...a.findings, ...lockWaits.findings],
            rootCause: a.rootCause,
            recommendations: a.recommendations,
            nextSteps: a.nextSteps,
            notCaptured: [...base.notCaptured, ...noChain, ...lockWaits.notCaptured],
            details: {
                chain: a.chainLines,
                chains: a.episodes.map((e) => ({ target: e.target, head: e.headSession, kind: e.headKind, blocked: e.peak.blocked, depth: e.peak.depth, width: e.peak.width, formations: e.cycles, first: iso(e.first), last: iso(e.last), activeAtAskedTime: !!w.at && e.first.getTime() - 15000 <= w.at.getTime() && w.at.getTime() <= e.last.getTime() + 15000 })),
                deadlocks: a.deadlocks.map((d) => ({ target: d.findings[0]?.target, count: d.count, byPattern: d.byPattern, victims: d.victims })),
                trees: a.episodes.map((e) => ({ target: e.target, kind: e.headKind, at: iso(e.peak.at), blocked: e.peak.blocked, depth: e.peak.depth, width: e.peak.width, root: nodeView(e.peak.head) })),
                series: blockedSeries(sessions),
            },
        };
    }

    async function errors(args: Record<string, unknown>, outerStop?: Date): Promise<InvestigationResult | string> {
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        const targets = targetsOf(args);
        const g = await gather(w.from, w.to, targets);
        const events = [...g.evidence.events.filter((e) => targets.includes(e.target) && e.at >= w.from && e.at <= w.to), ...countedErrors(g.evidence, w.from, w.to, targets)];
        const base = envelope("explain_errors", w.from, w.to, targets, deps, g, w.at);
        // A read that stopped short holds only what came before: what it didn't find, and what it counted, only up to there
        // (the review of d431edb4: a read cut at 11:16 said no errors were recorded, beside 300,000 429s after it). An
        // incident's part reads only its episode's minutes, so its incident's read says where it stopped (outerStop).
        const own = readStoppedAt(g.evidence);
        const stop = own && outerStop ? (own < outerStop ? own : outerStop) : (own ?? outerStop ?? null);
        const a = analyzeErrorsResult(events, stop ?? undefined);
        const none = stop
            ? `No errors, cancels, failed connections, or 429s were recorded up to ${hhmmss(stop)} UTC, where the read stopped; what came after it wasn't read.`
            : "No errors, cancels, failed connections, or 429s were recorded in the window.";
        return { ...base, ...a, notCaptured: events.length === 0 ? [...base.notCaptured, none] : base.notCaptured };
    }

    async function replica(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const w = windowOf({ minutesBefore: 10, minutesAfter: 5, ...args }, deps);
        if (typeof w === "string" || !w.at) return typeof w === "string" ? w : "Give at.";
        return replicaAt(w.at, w.from, w.to);
    }

    /**
     * The replica's lag at `at`, for explain_replica_lag and for an incident alike: the rise around it, whole, and its cause
     * from the rise's own minutes. When the rise or its cause runs past the minutes read (a stall that began before them,
     * or hadn't recovered by their end), they're read again with those minutes, up to REPLICA_REREADS more times, so every
     * question about one rise gets the same answer from the same rows (live, 2026-11-21: the RCA view and the chat explained
     * one stall two ways; the review of 4e2c65ed: one more read left a 14-minute stall unrecovered when asked about its
     * first minute). A rise that the history still shows unrecovered after them is reported as it stands.
     */
    async function replicaAt(at: Date, from: Date, to: Date, askedTo?: Date): Promise<InvestigationResult> {
        const targets: RcaTarget[] = ["T4", "T4-replica"];
        const analyze = async (w: { from: Date; to: Date }) => {
            const g = await gather(w.from, w.to, targets);
            const a = analyzeReplicaLag({ at, metrics: g.evidence.metrics.filter((m) => metricIn(m, w.from, w.to)), samples: g.evidence.replica.filter((r) => r.at >= w.from && r.at <= w.to), events: g.evidence.events, askedTo });
            return { w, g, a };
        };
        let r = await analyze({ from, to });
        for (let again = 0; again < REPLICA_REREADS; again++) {
            const { a, w: read } = r;
            if (!a.reads || !a.rise) break;
            // Unrecovered at the end of the minutes read: its end is their last point's.
            const open = !a.rise.recovered && a.rise.end.getTime() >= read.to.getTime() - 2 * MIN;
            if (a.reads.from >= read.from && a.reads.to <= read.to && !open) break;
            const before = a.rise.end.getTime();
            r = await analyze({
                from: new Date(Math.min(read.from.getTime(), a.reads.from.getTime() - 3 * MIN)),
                to: new Date(Math.max(read.to.getTime(), a.reads.to.getTime() + 3 * MIN, open ? read.to.getTime() + REPLICA_STEP_MINUTES * MIN : 0)),
            });
            // The history has nothing past where the rise stood: reading further finds no more.
            if (open && r.a.rise && !r.a.rise.recovered && r.a.rise.end.getTime() <= before) break;
        }
        const { w, g, a } = r;
        const base = envelope("explain_replica_lag", w.from, w.to, targets, deps, g, at);
        return {
            ...base,
            findings: a.findings,
            rootCause: a.rootCause,
            recommendations: a.recommendations,
            nextSteps: a.nextSteps,
            notCaptured: [...base.notCaptured, ...a.notCaptured],
            details: a.rise
                ? {
                      source: a.rise.source,
                      lag: a.rise.points.map((p) => ({ at: iso(p.at), seconds: Math.round(p.value * 10) / 10, source: p.source, ...(p.intervalMs ? { intervalMinutes: Math.round(p.intervalMs / MIN) } : {}) })),
                      slopeSPerS: a.rise.slope,
                      peak: { at: iso(a.rise.peak.at), seconds: Math.round(a.rise.peak.value * 10) / 10 },
                      // From the capture's own samples only; Azure Monitor's intervals bound it from below (the review of 4e2c65ed).
                      ...(a.rise.lastReplay ? { lastReplay: iso(a.rise.lastReplay) } : { lastReplayNoEarlierThan: iso(a.rise.stalledSince) }),
                      recovered: !!a.rise.recovered,
                  }
                : {},
        };
    }

    /** T4's connections against the limit, explained by what held them (connections.ts). An episode its capture cut off (openEnded) says so, and one still on where the minutes read end (readEnd) says that. */
    async function connectionsAt(target: RcaTarget, from: Date, to: Date, openEnded = false, readEnd?: Date, readStopped?: boolean): Promise<InvestigationResult> {
        const [g, held] = await Promise.all([gather(from, to, [target]), holdersIn(target, from, to)]);
        const a = analyzeConnections({ target, from, to, resource: g.evidence.resource, sessions: g.evidence.sessions, metrics: g.evidence.metrics, openEnded, readEnd, readStopped, holders: held.groups, holdersNote: held.note });
        const base = envelope("explain_connections", from, to, [target], deps, g);
        return { ...base, findings: a.findings, rootCause: a.rootCause, recommendations: a.recommendations, nextSteps: a.nextSteps, notCaptured: [...base.notCaptured, ...a.notCaptured, ...held.gaps], details: a.details };
    }

    /**
     * Who held a target's connections in some minutes, from the sidecar's RCA Connections, with its Query Store coverage; or
     * why there's no count of them, said as such: a model without the tables, a read that failed, or Query Store's evidence
     * of those minutes that holds none, with its gaps. With no coverage row either, connections.ts says decision C's words.
     */
    async function holdersIn(target: RcaTarget, from: Date, to: Date): Promise<{ groups: ConnectionGroup[]; note?: string; gaps: string[] }> {
        if (!deps.sidecar) return { groups: [], gaps: [] };
        try {
            const s = await deps.sidecar(from, to, [target], ["connections", "queryCoverage"]);
            if (s.missing.length) return { groups: [], note: `${target}: who held the connections isn't in this history: its model doesn't have ${s.missing.join(", ")} yet; ./scripts/deploy.ps1 updates the model.`, gaps: [] };
            const groups = s.connections.filter((c) => c.target === target);
            if (groups.length) return { groups, gaps: [] };
            const rows = s.coverage.filter((c) => c.target === target);
            if (!rows.length) return { groups: [], gaps: [] };
            return { groups: [], note: `${target}: Query Store's evidence in this history holds no count of who held the connections ${fromTo(from, to)} UTC.`, gaps: coverageGapLines(target, rows, from, to) };
        } catch (err) {
            return { groups: [], note: `${target}: who held the connections ${fromTo(from, to)} UTC couldn't be read, so they aren't named: ${err instanceof Error ? err.message : String(err)}`, gaps: [] };
        }
    }

    /**
     * T5's normalized RU consumption at 100 %, explained from Azure Monitor's counts (throughput.ts). It's read from at
     * most 30 minutes into the window's hour, so the hour's provisioned throughput, an hourly point stamped with the hour's
     * start, is in it (the re-review of bb70161f: a window from 15:45 read from 15:15 and missed 15:00's).
     */
    async function throughputAt(from: Date, to: Date): Promise<InvestigationResult> {
        const hour = Math.floor(from.getTime() / HOUR) * HOUR;
        const g = await gather(new Date(Math.min(from.getTime(), hour + LEAD_MINUTES * MIN)), to, ["T5"]);
        const a = analyzeThroughput({ from, to, metrics: g.evidence.metrics });
        const base = envelope("explain_throughput", from, to, ["T5"], deps, g);
        return { ...base, findings: a.findings, rootCause: a.rootCause, recommendations: a.recommendations, nextSteps: a.nextSteps, notCaptured: [...base.notCaptured, ...a.notCaptured], details: a.details };
    }

    async function triage(args: Record<string, unknown>, tool = "triage_window"): Promise<InvestigationResult | string> {
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        // The Root cause page's facets (facets.ts), targets among them: the window is read on every target, as the page reads
        // it, so the verdicts (nothingAbnormal, quiet) are the whole window's, and what the facets leave out is counted on
        // every target (the review of 90e9d914: targets narrowed the read, so a triage of the replica's high incidents said
        // nothing abnormal, and none left out, beside 10 incidents on other targets).
        const facets = facetArgs(args);
        if (typeof facets === "string") return facets;
        const targets = [...RCA_TARGETS];
        const g = await gather(w.from, w.to, targets);
        const stop = readStoppedAt(g.evidence);
        const t = triageWindow(g, w.from, w.to, targets, stop ?? undefined);
        const base = envelope(tool, w.from, w.to, targets, deps, g, w.at);
        // Quiet, or nothing abnormal, only up to where a read stopped short (the review of d431edb4).
        const upTo = stop ? { readStoppedAt: iso(stop), quietUpTo: iso(stop), ...(t.hypotheses.length === 0 ? { nothingAbnormalUpTo: iso(stop) } : {}) } : {};
        const hypotheses = facets ? t.hypotheses.filter((h) => matches(h, facets)) : t.hypotheses;
        const episodes = facets ? base.episodes.filter((e) => matches(e, facets)) : base.episodes;
        const leftOut = base.episodes.filter((e) => !episodes.includes(e));
        const byCategory: Partial<Record<RcaCategory, number>> = {};
        const byTarget: Partial<Record<RcaTarget, number>> = {};
        for (const e of leftOut) {
            byCategory[e.category] = (byCategory[e.category] ?? 0) + 1;
            byTarget[e.target] = (byTarget[e.target] ?? 0) + 1;
        }
        // The servers of the targets asked about; every target's without them (the page names each facet value).
        const servers = Object.fromEntries(Object.entries(g.servers ?? {}).filter(([target]) => !facets?.targets.length || facets.targets.includes(target)));
        // What wasn't captured on the targets asked about, and what's about no one target (a read cut short); the rest is counted.
        const asked = facets?.targets.length ? facets.targets : null;
        const otherTarget = (line: string) => !!asked && RCA_TARGETS.some((target) => !asked.includes(target) && line.startsWith(`${target}: `));
        const notCaptured = base.notCaptured.filter((line) => !otherTarget(line));
        return {
            ...base,
            episodes,
            notCaptured,
            findings: hypotheses.map((h) => ({ ruleId: `TRIAGE-${h.family.toUpperCase()}`, target: h.target, severity: FINDING_SEVERITY[h.severity], title: h.summary, detail: `Next: ${h.nextTool}${h.episodeKey ? ` (episodeKey ${h.episodeKey})` : ""}.`, evidence: [] })),
            rootCause: null,
            nextSteps: hypotheses.slice(0, 3).map((h) => `${h.nextTool} for ${h.target}${h.episodeKey ? ` (episode ${h.episodeKey})` : ""}`),
            details: {
                // An episode's severityReason is in the episode list once: a hypothesis with its key doesn't repeat it (the
                // review of 90e9d914: each reason twice pushed results past what one answer holds).
                hypotheses: hypotheses.map(({ severityReason, ...h }) => (h.episodeKey ? h : { ...h, severityReason })),
                quiet: t.quiet,
                nothingAbnormal: t.hypotheses.length === 0 && !stop,
                ...upTo,
                ...(Object.keys(servers).length ? { servers } : {}),
                ...(facets ? { filters: facets, leftOut: { episodes: leftOut.length, hypotheses: t.hypotheses.length - hypotheses.length, notCaptured: base.notCaptured.length - notCaptured.length, byCategory, byTarget } } : {}),
            },
        };
    }

    /**
     * One episode's investigation, by its family: each family that EXPLAINED_FAMILIES lists has its own here. CPU and the
     * wait classes have none: incident() explains them from Query Store's evidence. A replica's lag is read from its own
     * minutes, from before replay last advanced (its peak less its lag) to past its end, and explained as explain_replica_lag
     * explains any time in it.
     */
    async function explainEpisode(e: Episode, stop?: Date | null): Promise<InvestigationResult | string | null> {
        const end = e.end ?? e.last;
        // An episode still on where the minutes read end is read to there, so its part tells the same end as its episode
        // (the review of 97fdf5ba: one answer said two).
        const until = e.readEnd && e.readEnd > e.start ? e.readEnd : new Date(end.getTime() + MIN);
        const span = { from: e.start.toISOString(), to: until.toISOString(), targets: [e.target] };
        if (e.family === "blocking" || e.family === "deadlock") return locking(span);
        // Its rise is read whole, past the minutes asked about when it ran on after them, which it says (the review of 2e19adfc).
        if (e.family === "replica_lag") return replicaAt(e.peakAt, new Date(Math.min(e.start.getTime(), e.peakAt.getTime() - e.peak * 1000) - 5 * MIN), new Date(end.getTime() + 10 * MIN), e.readEnd);
        if (e.family === "connections") return connectionsAt(e.target, e.start, until, !e.end && !e.readEnd, e.readEnd, e.readStopped);
        if (e.family === "ru") return throughputAt(e.start, new Date(end.getTime() + MIN));
        // An episode with no end where its incident's read stopped is counted at least, through there (the review of eb89acbb:
        // a 429 storm the read cut at 11:16 read "48000, 09:40:00 to 11:16:00", as if it had ended there).
        if (e.family === "errors" || e.family === "throttling") return errors(span, stop && !e.end && stop > e.start ? stop : undefined);
        return null;
    }

    async function incident(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const key = typeof args.episodeKey === "string" ? args.episodeKey.trim() : "";
        let from: Date;
        let to: Date;
        let targets: RcaTarget[];
        let family = "";
        if (key) {
            const m = KEY.exec(key);
            if (!m) return `No episode ${JSON.stringify(key)}: call find_incidents for the keys.`;
            from = new Date(Date.UTC(+m[3], +m[4] - 1, +m[5], +m[6], +m[7], +m[8]));
            to = new Date(from.getTime() + 120 * MIN);
            targets = [m[1] as RcaTarget];
            family = m[2];
        } else {
            const w = windowOf(args, deps);
            const target = RCA_TARGETS.includes(args.target as RcaTarget) ? (args.target as RcaTarget) : null;
            if (typeof w === "string" || !target) return "Give episodeKey, or target with from and to.";
            ({ from, to } = w);
            targets = [target];
        }
        const g = await gather(key ? new Date(from.getTime() - KEY_LEAD_MINUTES * MIN) : from, to, targets);
        let chosen = key ? g.episodes.filter((e) => e.key === key) : g.episodes.filter((e) => e.start <= to && (e.end ?? e.last) >= from);
        // A key listed over other minutes can read differently in its own (Final tests' live check of 4e2c65ed: T5's 12:15
        // and 12:30 read as one episode from 12:15, so 12:30's key had none). The episode of its target and signal that holds
        // the key's time is the same incident; or one that starts later, but within the interval of the key's own point,
        // as the capture's stall from 16:17:12 does within Azure Monitor's 5 minutes from 16:15, or within a sample of its
        // time, where a baseline read otherwise first saw it (Final tests' check of ddebd4c3, F1). Never a later incident of
        // its own: a key with nothing in its minutes read as a storm 10 minutes later (the review of 803f2b1a). Which one,
        // details.readAs says, and so does what wasn't captured.
        const same = key && chosen.length === 0 ? g.episodes.filter((e) => e.target === targets[0] && e.family === family) : [];
        const holds = same.filter((e) => e.start <= from && (e.end ?? e.last) >= from);
        // The key's own point is the coarsest the history holds at its time, before one point per interval is kept: a key an
        // earlier list made from the day-long save's 15 minutes at 15:30 reads as the storm from 15:31 in them, though the
        // point kept at 15:30 is a minute (the review of 97fdf5ba).
        const metric = FAMILY_METRIC[family];
        const keyInterval = metric
            ? Math.max(0, g.keyIntervals?.get(pointKey(targets[0], metric, from)) ?? 0, ...g.evidence.metrics.filter((m) => m.target === targets[0] && m.metric === metric && m.at.getTime() === from.getTime()).map((m) => m.intervalMs ?? 0))
            : 0;
        const withinPoint = (e: Episode) => e.start.getTime() < from.getTime() + keyInterval;
        const readAs = holds.length ? holds : same.filter((e) => e.start > from && (withinPoint(e) || e.start.getTime() <= from.getTime() + ONE_SAMPLE_MS)).slice(0, 1);
        if (readAs.length) chosen = readAs;
        if (key && chosen.length === 0) return `No episode ${JSON.stringify(key)}: call find_incidents for the keys.`;
        const readNote = readAs.length
            ? [`${key}: in its own minutes, the history has no incident with this key; it reads as ${readAs.map((e) => e.key).join(" and ")}, which ${holds.length ? "holds its time" : withinPoint(readAs[0]) ? "starts within the interval of its own point" : "starts a sample after its time"}, so this report is that one's.`]
            : [];
        const span = chosen.length ? { from: new Date(Math.min(...chosen.map((e) => e.start.getTime()))), to: new Date(Math.max(...chosen.map((e) => (e.end ?? e.readEnd ?? e.last).getTime()))) } : { from, to };
        const base = envelope("explain_incident", span.from, span.to, targets, deps, g);
        if (chosen.length === 0) {
            // Nothing abnormal only up to where a read stopped short (the review of d431edb4).
            const stop = readStoppedAt(g.evidence);
            const nothing = stop
                ? `Nothing abnormal on ${targets.join(", ")} from ${spanEnds(from, stop).join(" up to ")} UTC, where the read stopped: the detector found no episode there, and what came after it wasn't read.`
                : `Nothing abnormal on ${targets.join(", ")} ${fromTo(from, to)} UTC: the detector found no episode there.`;
            return { ...base, notCaptured: [...base.notCaptured, nothing], details: stop ? { nothingAbnormal: false, nothingAbnormalUpTo: iso(stop), readStoppedAt: iso(stop) } : { nothingAbnormal: true } };
        }
        const stopped = readStoppedAt(g.evidence);
        const parts = (await Promise.all(chosen.map((e) => explainEpisode(e, stopped)))).filter((p): p is InvestigationResult => !!p && typeof p !== "string");
        // A signal no part investigates (CPU, the wait classes): the episode is the fact, and Query Store's evidence, what the
        // capture saved of it (the sidecar), names the queries behind it when this history holds them (explain-queries.ts).
        // Otherwise it says why, about this history, never the target: live, the chat read "isn't captured yet" as "T1
        // doesn't have Query Store" (the owner, 2026-11-23). Without the sidecar, query-store.ts's words.
        const telemetryOnly = chosen.filter((e) => !EXPLAINED_FAMILIES.includes(e.family));
        // Whether the target's Query Store still keeps those minutes is judged now, by the viewer's clock (the review of 319b3ae1).
        const now = (deps.now ?? (() => new Date()))();
        const read = deps.sidecar;
        const byQuery = read ? await Promise.all(telemetryOnly.map((e) => incidentQueries(e, read, g.evidence.resource, now))) : telemetryOnly.map(() => null);
        const analysisOf = (i: number): QueryStoreAnalysis | null => {
            const q = byQuery[i];
            return q && "analysis" in q ? q.analysis : null;
        };
        const evidenced = (i: number) => analysisOf(i)?.details.recorded === "yes";
        const causes = [
            ...parts.filter((p) => p.rootCause).map((p) => p.rootCause!),
            ...telemetryOnly.map((e, i) => {
                const evidence = [{ table: e.source === "the RCA capture" ? "RCA Resource" : "Telemetry Snapshots", at: iso(e.peakAt), target: e.target, text: `${e.signal} ${Math.round(e.peak * 10) / 10} ${e.unit} (peak)` }];
                const found = analysisOf(i)?.rootCause;
                if (found) return { statement: `${describeEpisode(e)} ${found.statement}`, confidence: found.confidence, ruleIds: found.ruleIds, evidence: [...evidence, ...found.evidence] };
                return { statement: `${describeEpisode(e)} ${byQuery[i] ? unexplainedWords(e, analysisOf(i)) : unexplainedByQuery(e)}`, confidence: "low" as Confidence, ruleIds: ["TELEMETRY-ONLY"], evidence };
            }),
        ].sort((a, b) => RANK[b.confidence] - RANK[a.confidence]);
        const [rootCause, ...others] = causes;
        // Each part reads its own minutes, a little wider than the incident's, so its envelope said the incident's "no RCA
        // capture" note again with other times: two such lines for one T5 storm (the coordinator's note on 803f2b1a). The
        // incident's own note says it once.
        const partNotes = parts.flatMap((p) => p.notCaptured).filter((line) => !RCA_TARGETS.some((t) => isNoCaptureNote(t, line) && base.notCaptured.some((b) => isNoCaptureNote(t, b))));
        // The ready-to-run query of the target's own Query Store, and the next step that names it, for the minutes this
        // history holds no evidence of; where it does, its rules' next steps.
        const queryStoreQueries = telemetryOnly.map((e, i) => (evidenced(i) ? null : queryStoreQuery(e, now))).filter((q): q is QueryStoreQuery => q !== null);
        const queryNotes = telemetryOnly.flatMap((e, i) => {
            const q = byQuery[i];
            return q === null ? [queryStoreNote(e, now)] : "failed" in q ? [q.failed] : q.analysis.notCaptured;
        });
        const querySteps = telemetryOnly.flatMap((e, i) => (evidenced(i) ? analysisOf(i)!.nextSteps : [queryStoreNextStep(e, now)].filter((s): s is string => s !== null)));
        const analyses = telemetryOnly.map((_, i) => analysisOf(i)).filter((a): a is QueryStoreAnalysis => a !== null);
        const notCaptured = [...new Set([...readNote, ...base.notCaptured, ...partNotes, ...queryNotes])];
        // Never a blank cause: with none found and nothing else to say, say which episode the evidence doesn't explain.
        if (!rootCause && notCaptured.length === 0) notCaptured.push(...chosen.map((e) => `${e.target}: nothing the capture or the telemetry recorded ${fromTo(e.start, e.end ?? e.last)} UTC explains the ${e.signal}.`));
        return {
            ...base,
            findings: [...parts.flatMap((p) => p.findings), ...analyses.flatMap((a) => a.findings)],
            rootCause: rootCause ?? null,
            recommendations: [...new Map([...parts.flatMap((p) => p.recommendations), ...analyses.flatMap((a) => a.recommendations)].map((r) => [r.id, r])).values()],
            nextSteps: [...new Set([...parts.flatMap((p) => p.nextSteps), ...querySteps])],
            notCaptured,
            details: {
                episodes: chosen.map((e) => ({ ...episodeView(e), text: describeEpisode(e) })),
                ...(readAs.length ? { readAs: { key, as: readAs.map((e) => e.key) } } : {}),
                // Each next step's ready-to-run, read-only query of the target's own Query Store for those minutes, while it keeps
                // them (query-store.ts): built from the episode's target, family, and times only.
                ...(queryStoreQueries.length ? { queryStoreQueries } : {}),
                // Query Store's evidence of those minutes in this history, as explain_queries gives it (queries.ts's views).
                ...(analyses.length ? { queryStore: analyses.map((a) => a.details) } : {}),
                alsoInTheseMinutes: others.map((c) => c.statement),
                parts: parts.map((p) => ({ tool: p.tool, details: p.details })),
            },
        };
    }

    /** explain_queries: Query Store's evidence for one target's window, from the sidecar, on the investigations' envelope. */
    async function queries(args: Record<string, unknown>): Promise<InvestigationResult | string> {
        const q = queryArgs(args);
        if (typeof q === "string") return q;
        const w = windowOf(args, deps);
        if (typeof w === "string") return w;
        if (!deps.sidecar) return "This app doesn't read Query Store's evidence: explain_incident and run_dax on the telemetry are what it has.";
        const g = await gather(w.from, w.to, [q.target]);
        const base = envelope(EXPLAIN_QUERIES, w.from, w.to, [q.target], deps, g, w.at);
        return explainQueries({ args: q, from: w.from, to: w.to, base, sidecar: deps.sidecar, episodes: g.episodes, resource: g.evidence.resource, now: (deps.now ?? (() => new Date()))() });
    }

    const handlers: Record<string, (args: Record<string, unknown>) => Promise<InvestigationResult | string>> = {
        find_incidents: (a) => triage(a, "find_incidents"),
        triage_window: (a) => triage(a),
        explain_incident: incident,
        explain_locking: locking,
        explain_errors: errors,
        explain_replica_lag: replica,
        [EXPLAIN_QUERIES]: queries,
    };

    return {
        specs: INVESTIGATION_TOOL_SPECS,
        /** The window's episodes, for the RCA view's list. */
        episodes: async (from: Date, to: Date, targets: readonly RcaTarget[] = RCA_TARGETS) => (await gather(from, to, targets)).episodes,
        /** Structured, for the RCA view and the tests. */
        async investigate(name: string, args: Record<string, unknown>): Promise<InvestigationResult | string> {
            const handler = handlers[name];
            return handler ? handler(args) : `There's no tool named ${name}.`;
        },
        /** As the dock's tool runner returns it: ok and the text Copilot reads. A read that failed is said as such, never
         *  as an empty or quiet window (RcaReadError). */
        async run(name: string, args: unknown): Promise<{ ok: boolean; text: string }> {
            const input = typeof args === "object" && args !== null && !Array.isArray(args) ? (args as Record<string, unknown>) : {};
            try {
                const result = await this.investigate(name, input);
                return typeof result === "string" ? { ok: false, text: result } : { ok: true, text: bounded(result) };
            } catch (err) {
                if (err instanceof RcaReadError) return { ok: false, text: err.message };
                return { ok: false, text: `The investigation failed: ${err instanceof Error ? err.message : String(err)}` };
            }
        },
    };
}

export type InvestigationTools = ReturnType<typeof createInvestigationTools>;
