// Typed views of the query results. Every value is checked, because a blank measure arrives as null.

import { isTargetKey, SQL_TARGETS, type TargetKey } from "../lib/dax";
import { isNumber, toDate } from "../lib/format";
import type { FindingsTab } from "../lib/view-state";
import { finestPerInterval, HOURLY_METRICS, pointKey } from "./finest-per-interval";
import type { Row } from "./query-client";

export const TARGET_INFO: Record<TargetKey, { name: string; short: string; platform: string; resource: string }> = {
    T1: { name: "T1 · SQL Server on an Azure VM", short: "T1", platform: "SQL Server 2022 on an Azure VM", resource: "virtual machine" },
    T2: { name: "T2 · Arc-enabled SQL Server", short: "T2", platform: "Arc-enabled SQL Server in a nested Hyper-V guest", resource: "Arc machine" },
    T3: { name: "T3 · Azure SQL Database", short: "T3", platform: "Azure SQL Database", resource: "logical server database" },
};

export const FAMILY_LABEL: Record<string, string> = {
    io: "IO pressure",
    cpu: "CPU pressure",
    blocking: "Blocking",
    log_rate: "Log-rate pressure",
};

const num = (v: unknown): number | null => (isNumber(v) ? v : null);
const text = (v: unknown): string => (typeof v === "string" ? v : v === null || v === undefined ? "" : String(v));

export interface Meta {
    latestCapture: Date | null;
    latestDay: Date | null;
    earliestDay: Date | null;
    hoursSince: number | null;
    freshness: string;
    notebookRuns: number;
    scenarioRequests: number;
    incidents: number;
    hasBins: boolean;
}

export function toMeta(rows: readonly Row[]): Meta | null {
    const r = rows[0];
    if (!r) return null;
    return {
        latestCapture: toDate(r.LatestCapture),
        latestDay: toDate(r.LatestDay),
        earliestDay: toDate(r.EarliestDay),
        hoursSince: num(r.HoursSince),
        freshness: text(r.Freshness),
        notebookRuns: num(r.NotebookRuns) ?? 0,
        scenarioRequests: num(r.ScenarioRequests) ?? 0,
        incidents: num(r.Incidents) ?? 0,
        hasBins: r.HasBins === 1,
    };
}

export interface TargetSummary {
    key: TargetKey;
    name: string;
    platform: string;
    cpuAvg: number | null;
    cpuPeak: number | null;
    blockedPeak: number | null;
    lockWaitS: number | null;
    bufferIoS: number | null;
    logRateS: number | null;
    waitS: number | null;
    ioMb: number | null;
    batch: number | null;
    sessionsPeak: number | null;
    deadlocks: number | null;
    findingsAttention: number;
    worstFindingSort: number | null;
    lagMin: number | null;
    coverageTables: number | null;
    coverageAgeMin: number | null;
    incidents: number;
    bins: number;
}

export function toTargets(rows: readonly Row[]): TargetSummary[] {
    return rows
        .filter((r) => isTargetKey(r["Target Key"]))
        .map((r) => {
            const key = r["Target Key"] as TargetKey;
            return {
                key,
                name: text(r.Target) || TARGET_INFO[key].name,
                platform: text(r.Platform) || TARGET_INFO[key].platform,
                cpuAvg: num(r.CpuAvg),
                cpuPeak: num(r.CpuPeak),
                blockedPeak: num(r.BlockedPeak),
                lockWaitS: num(r.LockWaitS),
                bufferIoS: num(r.BufferIoS),
                logRateS: num(r.LogRateS),
                waitS: num(r.WaitS),
                ioMb: num(r.IoMb),
                batch: num(r.BatchRequests),
                sessionsPeak: num(r.SessionsPeak),
                deadlocks: num(r.Deadlocks),
                findingsAttention: num(r.FindingsAttention) ?? 0,
                worstFindingSort: num(r.WorstFindingSort),
                lagMin: num(r.LagMin),
                coverageTables: num(r.CoverageTables),
                coverageAgeMin: num(r.CoverageAgeMin),
                incidents: num(r.Incidents) ?? 0,
                bins: num(r.Bins) ?? 0,
            };
        });
}

export interface Finding {
    id: string;
    analysisKey: string;
    analysis: string;
    /** The model's Analysis Group: Estate, CPU, Locks and blocking, Waits, IO, Memory, Storage, Readiness, Incidents, PostgreSQL. */
    group: string;
    target: string;
    status: string;
    statusSort: number;
    text: string;
    capturedAt: Date | null;
}

export function toFindings(rows: readonly Row[]): Finding[] {
    return rows.map((r) => ({
        id: text(r.FindingId),
        analysisKey: text(r.AnalysisKey),
        analysis: text(r.Analysis) || text(r.AnalysisKey).replace(/_/g, " "),
        group: text(r.AnalysisGroup),
        target: text(r.TargetKey),
        status: text(r.Status),
        statusSort: num(r.StatusSort) ?? 6,
        text: text(r.Finding),
        capturedAt: toDate(r.CapturedAt),
    }));
}

/** What a finding is about, for the Findings page's tabs. */
/** The categories a finding files under: the Findings page's tabs. */
export type FindingCategory = FindingsTab;

export const FINDING_CATEGORIES: ReadonlyArray<{ id: FindingCategory; label: string; description: string }> = [
    { id: "performance", label: "Performance", description: "CPU, waits, blocking, IO, and memory" },
    { id: "availability", label: "Availability", description: "Replicas, connections, and throttling" },
    { id: "security", label: "Security", description: "Authentication, auditing, and encryption posture" },
    { id: "optimization", label: "Optimization", description: "Migration readiness, licensing, and sizing" },
    { id: "capacity", label: "Capacity", description: "Storage growth and capacity use" },
    { id: "readiness", label: "Telemetry and readiness", description: "What Database Hub can see" },
];

const GROUP_CATEGORY: Record<string, FindingCategory> = {
    CPU: "performance",
    "Locks and blocking": "performance",
    Throughput: "performance",
    Waits: "performance",
    IO: "performance",
    Memory: "performance",
    "CPU and waits": "capacity",
    Storage: "capacity",
    Readiness: "readiness",
    Estate: "readiness",
    Incidents: "performance",
};

/** The category of a finding from its analysis: security, optimization, and migration analyses by key. */
export function findingCategory(f: Pick<Finding, "analysisKey" | "group" | "id">): FindingCategory {
    const key = `${f.analysisKey} ${f.id}`.toLowerCase();
    if (/security|auth|audit|encrypt|cmk|tde|firewall|defender|vulnerab/.test(key)) return "security";
    if (/optimi|migration|assessment|license|licensing|rightsiz|sizing|payg/.test(key)) return "optimization";
    if (/lag|replica|connection|throttl|429|availability|failover/.test(key)) return "availability";
    if (f.group === "PostgreSQL" || f.analysisKey === "postgresql") return "performance";
    return GROUP_CATEGORY[f.group] ?? "performance";
}

/** One activity request the notebooks recorded: a session's plan or one incident request. */
export interface SessionRun {
    requestId: string;
    requestedAt: Date | null;
    target: string;
    profile: string;
    durationMin: number | null;
    status: string;
    message: string;
    windowStart: Date | null;
    windowEnd: Date | null;
    dispatch: string;
}

export function toSessions(rows: readonly Row[]): SessionRun[] {
    return rows
        .map((r) => ({
            requestId: text(r.RequestId),
            requestedAt: toDate(r.RequestedAt),
            target: text(r.TargetKey),
            profile: text(r.Profile),
            durationMin: num(r.DurationMin),
            status: text(r.Status),
            message: text(r.Message),
            windowStart: toDate(r.WindowStart),
            windowEnd: toDate(r.WindowEnd),
            dispatch: text(r.Dispatch),
        }))
        .sort((a, b) => (b.requestedAt?.getTime() ?? 0) - (a.requestedAt?.getTime() ?? 0));
}

/** T3's Database Agent beat: the regression, the documented response the run applied, and whether CPU recovered. */
export interface AgentBeat {
    id: string;
    target: string;
    status: string;
    text: string;
    requestId: string;
    windowStart: Date | null;
    windowEnd: Date | null;
    regressAt: Date | null;
    respondAt: Date | null;
    cpuBefore: number | null;
    cpuAfter: number | null;
}

export function toAgentBeats(rows: readonly Row[]): AgentBeat[] {
    return rows
        .map((r) => {
            const evidence = evidenceOf(r.Evidence) ?? {};
            return {
                id: text(r.FindingId),
                target: text(r.TargetKey),
                status: text(r.Status),
                text: text(r.Finding),
                requestId: text(r.RequestId),
                windowStart: toDate(r.WindowStart),
                windowEnd: toDate(r.WindowEnd),
                regressAt: toDate(evidence.regressUtc),
                respondAt: toDate(evidence.respondUtc),
                cpuBefore: num(evidence.cpuBeforePercent),
                cpuAfter: num(evidence.cpuAfterPercent),
            };
        })
        .filter((b) => b.id !== "")
        .sort((a, b) => (b.windowStart?.getTime() ?? 0) - (a.windowStart?.getTime() ?? 0));
}

/** The beat whose window overlaps the incident's, on the same target. */
export function beatFor(incident: Pick<Incident, "target" | "start" | "end">, beats: readonly AgentBeat[]): AgentBeat | null {
    return (
        beats.find(
            (b) => b.target === incident.target && b.windowStart !== null && b.windowEnd !== null && b.windowStart.getTime() < incident.end.getTime() && b.windowEnd.getTime() > incident.start.getTime(),
        ) ?? null
    );
}

/** One UTC day of one SQL target. */
export interface DayRow {
    day: Date;
    target: TargetKey;
    cpuAvg: number | null;
    cpuPeak: number | null;
    waitS: number | null;
    bufferIoS: number | null;
    lockWaitS: number | null;
    batch: number | null;
    sessionsPeak: number | null;
    incidents: number;
}

export function toDays(rows: readonly Row[]): DayRow[] {
    const out: DayRow[] = [];
    for (const r of rows) {
        const day = toDate(r.Date);
        const target = r["Target Key"];
        if (!day || !isTargetKey(target)) continue;
        out.push({
            day,
            target,
            cpuAvg: num(r.CpuAvg),
            cpuPeak: num(r.CpuPeak),
            waitS: num(r.WaitS),
            bufferIoS: num(r.BufferIoS),
            lockWaitS: num(r.LockWaitS),
            batch: num(r.Batch),
            sessionsPeak: num(r.SessionsPeak),
            incidents: num(r.Incidents) ?? 0,
        });
    }
    return out.sort((a, b) => a.day.getTime() - b.day.getTime() || a.target.localeCompare(b.target));
}

export interface Bin {
    at: Date;
    target: TargetKey;
    cpu: number | null;
    blocked: number | null;
    lockWaitS: number | null;
    bufferIoS: number | null;
    logRateS: number | null;
    waitS: number | null;
    ioMb: number | null;
    batch: number | null;
    sessions: number | null;
    /** The bin's wait seconds per category, when the incident's waits query read them (withCategoryWaits). */
    waits?: Readonly<Record<string, number>>;
}

export function toBins(rows: readonly Row[], target?: TargetKey): Bin[] {
    const out: Bin[] = [];
    for (const r of rows) {
        const at = toDate(r["Bucket UTC"]);
        const key = target ?? r["Target Key"];
        if (!at || !isTargetKey(key)) continue;
        out.push({
            at,
            target: key,
            cpu: num(r.Cpu),
            blocked: num(r.Blocked),
            lockWaitS: num(r.LockWaitS),
            bufferIoS: num(r.BufferIoS),
            logRateS: num(r.LogRateS),
            waitS: num(r.WaitS),
            ioMb: num(r.IoMb),
            batch: num(r.Batch),
            sessions: num(r.Sessions),
        });
    }
    return out.sort((a, b) => a.at.getTime() - b.at.getTime());
}

export interface WaitFlow {
    category: string;
    target: TargetKey;
    seconds: number;
}

export function toWaitFlows(rows: readonly Row[]): WaitFlow[] {
    return rows
        .map((r) => ({ category: text(r.Metric), target: r["Target Key"], seconds: num(r.WaitS) ?? 0 }))
        .filter((w): w is WaitFlow => w.category !== "" && isTargetKey(w.target) && w.seconds > 0);
}

export interface WaitBin {
    at: Date;
    category: string;
    seconds: number;
}

export function toWaitBins(rows: readonly Row[]): WaitBin[] {
    const out: WaitBin[] = [];
    for (const r of rows) {
        const at = toDate(r["Bucket UTC"]);
        const seconds = num(r.WaitS);
        if (at && seconds !== null && text(r.Metric)) out.push({ at, category: text(r.Metric), seconds });
    }
    return out;
}

/** The bins with their waits per category from the same window's waits query, so a wait family's own series (Tran Log
 *  IO, Buffer Latch, Network IO...) can be read bin by bin. A bin that query has no row for keeps none. */
export function withCategoryWaits(bins: readonly Bin[], waits: readonly WaitBin[]): Bin[] {
    const byAt = new Map<number, Record<string, number>>();
    for (const w of waits) {
        const categories = byAt.get(w.at.getTime()) ?? {};
        categories[w.category] = (categories[w.category] ?? 0) + w.seconds;
        byAt.set(w.at.getTime(), categories);
    }
    if (byAt.size === 0) return [...bins];
    return bins.map((b) => {
        const categories = byAt.get(b.at.getTime());
        return categories ? { ...b, waits: categories } : b;
    });
}

export interface Incident {
    key: string;
    label: string;
    source: string;
    target: TargetKey;
    scenario: string;
    family: string;
    start: Date;
    end: Date;
    durationMin: number;
    peakValue: number | null;
    peakUnit: string;
    verdict: string;
}

export function toIncidents(rows: readonly Row[]): Incident[] {
    const out: Incident[] = [];
    for (const r of rows) {
        const start = toDate(r.Start);
        const end = toDate(r.End);
        if (!start || !end || !isTargetKey(r.TargetKey)) continue;
        out.push({
            key: text(r.Key),
            label: text(r.Label),
            source: text(r.Source),
            target: r.TargetKey,
            scenario: text(r.Scenario),
            family: text(r.Family),
            start,
            end,
            durationMin: num(r.DurationMin) ?? (end.getTime() - start.getTime()) / 60000,
            peakValue: num(r.PeakValue),
            peakUnit: text(r.PeakUnit),
            verdict: text(r.Verdict),
        });
    }
    return out.sort((a, b) => b.start.getTime() - a.start.getTime());
}

export interface Check {
    runId: string;
    checkId: string;
    area: string;
    target: string;
    status: string;
    statusSort: number;
    message: string;
    remediation: string;
    docUrl: string;
    evaluationOnly: boolean;
    checkedAt: Date | null;
}

export function toChecks(rows: readonly Row[]): Check[] {
    return rows.map((r) => ({
        runId: text(r.RunId),
        checkId: text(r.CheckId),
        area: text(r.Area),
        target: text(r.TargetKey),
        status: text(r.Status),
        statusSort: num(r.StatusSort) ?? 6,
        message: text(r.Message),
        remediation: text(r.Remediation),
        docUrl: /^https:\/\//i.test(text(r.DocUrl)) ? text(r.DocUrl) : "",
        evaluationOnly: r.EvaluationOnly === true,
        checkedAt: toDate(r.CheckedAt),
    }));
}

export interface ReadinessSummary {
    checks: number;
    failed: number;
    manual: number;
    warnings: number;
    passed: number;
    notSupported: number;
    notSelected: number;
    readiness: number | null;
    runLabel: string;
}

export function toReadinessSummary(rows: readonly Row[]): ReadinessSummary | null {
    const r = rows[0];
    if (!r) return null;
    return {
        checks: num(r.Checks) ?? 0,
        failed: num(r.Failed) ?? 0,
        manual: num(r.Manual) ?? 0,
        warnings: num(r.Warnings) ?? 0,
        passed: num(r.Passed) ?? 0,
        notSupported: num(r.NotSupported) ?? 0,
        notSelected: num(r.NotSelected) ?? 0,
        readiness: num(r.Readiness),
        runLabel: text(r.RunLabel),
    };
}

export interface Coverage {
    target: TargetKey;
    tables: number | null;
    ageMin: number | null;
    attention: string;
}

export function toCoverage(rows: readonly Row[]): Coverage[] {
    return rows
        .filter((r) => isTargetKey(r["Target Key"]))
        .map((r) => ({ target: r["Target Key"] as TargetKey, tables: num(r.Tables), ageMin: num(r.AgeMin), attention: text(r.Attention) }));
}

/** What the telemetry calls a target: its Azure resource, SQL instance, and demo database. */
export interface TargetName {
    resource: string | null;
    resourceType: string | null;
    instance: string | null;
    database: string | null;
}

export type TargetNames = Partial<Record<TargetKey, TargetName>>;

const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._()/\\-]{0,127}$/;

function safeName(value: unknown): string | null {
    const name = text(value).trim();
    return SAFE_NAME.test(name) ? name : null;
}

/** One set of names per SQL target from the distinct name rows: the row with a resource type names the Azure resource. */
export function toTargetNames(rows: readonly Row[]): TargetNames {
    const out: TargetNames = {};
    for (const key of SQL_TARGETS) {
        const mine = rows.filter((r) => r.TargetKey === key);
        if (mine.length === 0) continue;
        const named = mine.filter((r) => safeName(r.ResourceName) !== null);
        const best = named.find((r) => safeName(r.ResourceType) !== null) ?? named[0];
        const databases = mine.map((r) => safeName(r.DatabaseName)).filter((d): d is string => d !== null);
        out[key] = {
            resource: best ? safeName(best.ResourceName) : null,
            resourceType: best ? safeName(best.ResourceType) : null,
            instance: mine.map((r) => safeName(r.InstanceName)).find((n): n is string => n !== null) ?? null,
            database: databases.find((d) => d === "ContosoCare") ?? databases[0] ?? null,
        };
    }
    return out;
}

/** Wait categories grouped into families for the flow and the sunburst. */
export function waitFamily(category: string): string {
    if (/PAGEIOLATCH|Other Disk IO|Tran Log IO|Buffer IO/i.test(category)) return "Storage IO";
    if (/^(CPU|Worker Thread|Parallelism)$/i.test(category)) return "CPU and scheduling";
    if (/Lock|Latch/i.test(category)) return "Locks and latches";
    if (/Network IO/i.test(category)) return "Network";
    if (/Memory/i.test(category)) return "Memory";
    if (/Log Rate Governor/i.test(category)) return "Resource governance";
    return "Other";
}

// ---- T4: the PostgreSQL flexible server and its read replica (2026-11-13, ADR 0025) ----------------------------------

/** The history's targets for T4: the primary (pgflex01-<deploymentId>) and its read replica (pgreplica01-<deploymentId>). */
export type PostgresTarget = "T4" | "T4-replica";

export const POSTGRES_TARGET_INFO: Record<PostgresTarget, { name: string; short: string; role: string; color: string }> = {
    T4: { name: "T4 · Azure Database for PostgreSQL", short: "T4", role: "flexible server", color: "var(--accent)" },
    "T4-replica": { name: "T4's read replica", short: "Read replica", role: "same-region read replica", color: "var(--accent-2)" },
};

export function isPostgresTarget(value: unknown): value is PostgresTarget {
    return value === "T4" || value === "T4-replica";
}

/** The Azure Monitor metrics the notebook keeps for T4 (analysis postgresql), by what they show. */
export const POSTGRES_METRICS = {
    /** Read Replica Lag, Database Hub's Read replica lag chart; on the replica only. */
    lag: "physical_replication_delay_in_seconds",
    /** Max Physical Replication Lag; on the primary only. */
    lagBytes: "physical_replication_delay_in_bytes",
    cpu: "cpu_percent",
    memory: "memory_percent",
    connections: "active_connections",
    /** Failed connections in each interval (a total, not a maximum). */
    failed: "connections_failed",
} as const;

export interface PostgresPoint {
    at: Date;
    target: PostgresTarget;
    server: string;
    metric: string;
    value: number;
    /** Its span in minutes, when known (F35): what it covers, its save's step or less where a window or a finer save cuts it. */
    minutes?: number;
    /** Its save's step in minutes, when known (F35): Azure Monitor's interval, to step runs by and name. */
    grain?: number;
    /** The coarser point it's a piece of (F35), by pointKey: the pieces of one source are one reading. */
    source?: string;
    /** A peak given to each of its source's uncovered stretches (F35): an upper bound for each. */
    upperBound?: boolean;
}

/**
 * The latest PostgreSQL capture's window, servers, and step, with its points, oldest first. For the app's views,
 * latestPostgresCapture puts every save's points in that window into it, one per interval (F35).
 */
export interface PostgresCapture {
    capturedAt: Date | null;
    windowStart: Date | null;
    windowEnd: Date | null;
    /** Minutes between consecutive points of one of the latest capture's series, or null with single points only. */
    intervalMinutes: number | null;
    /** Each target's server name. */
    servers: Partial<Record<PostgresTarget, string>>;
    points: PostgresPoint[];
    /** How many saves its points come from (F35); one when absent. */
    saves?: number;
}

/** A point's span in minutes (F35), or the capture's step when the point doesn't say: for its end, sums, and rates. */
export function spanMinutes(point: { minutes?: number }, fallback: number): number {
    return point.minutes !== undefined && point.minutes > 0 ? point.minutes : fallback;
}

/** A point's save's step in minutes (F35), or the capture's step when the point doesn't say: to step runs by and name. */
export function grainMinutes(point: { grain?: number }, fallback: number): number {
    return point.grain !== undefined && point.grain > 0 ? point.grain : fallback;
}

/**
 * A total's points per minute of their span (F35), for a capture whose points come from saves at different intervals:
 * there a 15-minute total beside 1-minute ones would read as a spike. A capture from one save keeps each interval's own.
 */
export function perMinute<P extends { value: number; minutes?: number }>(points: readonly P[], capture: { intervalMinutes: number | null; saves?: number } | null): P[] {
    if (!capture || (capture.saves ?? 1) <= 1) return [...points];
    return points.map((p) => ({ ...p, value: p.value / spanMinutes(p, capture.intervalMinutes ?? 1) }));
}

/**
 * A series' points with each reading once (F35): of the pieces a coarser point left in several uncovered stretches, only
 * the first, so a run or an episode doesn't count one reading twice. Charts and totals keep every piece.
 */
export function oneReadingEach<P extends { source?: string }>(points: readonly P[]): P[] {
    const seen = new Set<string>();
    return points.filter((p) => {
        if (p.source === undefined) return true;
        if (seen.has(p.source)) return false;
        seen.add(p.source);
        return true;
    });
}

const METRIC_NAME = /^[a-z0-9_]{1,64}$/;

function intervalOf(points: ReadonlyArray<{ at: Date; metric: string; target?: string }>): number | null {
    const previous = new Map<string, number>();
    let best: number | null = null;
    for (const p of points) {
        const key = `${p.target ?? ""}|${p.metric}`;
        const before = previous.get(key);
        const time = p.at.getTime();
        if (before !== undefined && time > before) {
            const gap = (time - before) / 60000;
            if (best === null || gap < best) best = gap;
        }
        previous.set(key, time);
    }
    return best;
}

/** What finestPerInterval returns beside its kept rows (F35), by pointKey. */
export type PointMarks = Pick<ReturnType<typeof finestPerInterval>, "intervals" | "grains" | "sources" | "upperBounds">;

/** What a decoder takes beside merged rows (F35): finestPerInterval's marks, the latest capture's own rows, and its step. */
export interface MergedSaves {
    marks: PointMarks;
    /** The newest capture's rows, as read: its window, its resources, and its step without marks. */
    latest: readonly Row[];
    /** The newest capture's own step in minutes (its kept points' grain, hourly metrics aside), or null when it has none. */
    step: number | null;
}

/** A decoded point with its span, grain, and marks from finestPerInterval, by its key (F35). */
function marked<P extends { at: Date; metric: string; minutes?: number; grain?: number; source?: string; upperBound?: boolean }>(point: P, target: string, marks: PointMarks | undefined): P {
    if (!marks) return point;
    const key = pointKey(target, point.metric, point.at);
    const span = marks.intervals.get(key);
    const grain = marks.grains.get(key);
    const source = marks.sources.get(key);
    if (span !== undefined) point.minutes = span / 60000;
    if (grain !== undefined) point.grain = grain / 60000;
    if (source !== undefined) point.source = source;
    if (marks.upperBounds.has(key)) point.upperBound = true;
    return point;
}

const capturedOf = (r: Row) => toDate(r.CapturedAt)?.getTime() ?? null;

function newestOf(rows: readonly Row[]): Row[] {
    let newest: number | null = null;
    for (const r of rows) {
        const captured = capturedOf(r);
        if (captured !== null && (newest === null || captured > newest)) newest = captured;
    }
    return rows.filter((r) => capturedOf(r) === newest);
}

/**
 * Every save's rows in the latest capture's window, each interval's finest (F35), for the app's T4 and T5 views: the newest
 * capture (Captured At) gives the window and the resources, and finestPerInterval merges the saves. Rows of another
 * resource than the newest capture's for the same target (an environment deployed again since) are left out, and so are
 * other saves' points outside its window (the query reads a day before it, for their steps). Its own points all stay.
 */
export function latestWindowSaves(rows: readonly Row[]): { rows: Row[]; merged: MergedSaves } {
    const latest = newestOf(rows);
    const newest = latest[0] ? capturedOf(latest[0]) : null;
    const resources = new Map<string, string>();
    for (const r of latest) {
        const name = safeName(r.ResourceName);
        if (name && !resources.has(text(r.TargetKey))) resources.set(text(r.TargetKey), name);
    }
    const same = rows.filter((r) => {
        const want = resources.get(text(r.TargetKey));
        return !want || safeName(r.ResourceName) === want;
    });
    const { kept, intervals, grains, sources, upperBounds } = finestPerInterval(same);
    const from = latest[0] ? (toDate(latest[0].WindowStart)?.getTime() ?? null) : null;
    const to = latest[0] ? (toDate(latest[0].WindowEnd)?.getTime() ?? null) : null;
    const out: Row[] = [];
    let step: number | null = null;
    for (const row of kept) {
        const at = toDate(row.Bucket);
        if (!at) continue;
        const key = pointKey(text(row.TargetKey), text(row.Metric), at);
        const span = intervals.get(key);
        const grain = grains.get(key);
        const start = at.getTime();
        const inWindow = (to === null || start < to) && (from === null || start + (span ?? 0) > from || start >= from);
        const own = capturedOf(row) === newest;
        if (!own && !inWindow) continue;
        if (own && grain !== undefined && !HOURLY_METRICS.has(text(row.Metric))) step = Math.min(step ?? Infinity, grain / 60000);
        out.push(row);
    }
    return { rows: out, merged: { marks: { intervals, grains, sources, upperBounds }, latest, step } };
}

const isPostgresRow = (r: Row) => toDate(r.Bucket) !== null && num(r.Value) !== null && isPostgresTarget(r.TargetKey) && METRIC_NAME.test(text(r.Metric));

/**
 * The postgres-series rows as one capture, as given, or null without a valid row (no capture yet). With `merged`
 * (latestPostgresCapture's), each point also has its span, its save's grain, and its marks, and the capture takes the
 * latest capture's window and step from it. Without it, the newest capture among the rows gives them.
 */
export function toPostgresCapture(rows: readonly Row[], merged?: MergedSaves): PostgresCapture | null {
    const valid = rows.filter(isPostgresRow);
    if (valid.length === 0) return null;
    const latest = merged ? merged.latest.filter(isPostgresRow) : newestOf(valid);
    const toPoint = (r: Row): PostgresPoint => ({ at: toDate(r.Bucket) as Date, target: r.TargetKey as PostgresTarget, server: safeName(r.ResourceName) ?? "", metric: text(r.Metric), value: num(r.Value) as number });
    const servers: Partial<Record<PostgresTarget, string>> = {};
    for (const r of [...latest, ...valid]) {
        const server = safeName(r.ResourceName);
        if (server && !servers[r.TargetKey as PostgresTarget]) servers[r.TargetKey as PostgresTarget] = server;
    }
    const points = valid.map((r) => marked(toPoint(r), text(r.TargetKey), merged?.marks)).sort((a, b) => a.at.getTime() - b.at.getTime());
    const first = latest[0] ?? valid[0];
    const intervalMinutes = merged?.step ?? intervalOf(latest.map(toPoint).sort((a, b) => a.at.getTime() - b.at.getTime()));
    return { capturedAt: toDate(first.CapturedAt), windowStart: toDate(first.WindowStart), windowEnd: toDate(first.WindowEnd), intervalMinutes, servers, points, saves: new Set(valid.map(capturedOf)).size };
}

/** The app's T4 capture (F35): every save's postgres-series points in the latest capture's window, each interval's finest. */
export function latestPostgresCapture(rows: readonly Row[]): PostgresCapture | null {
    const { rows: kept, merged } = latestWindowSaves(rows.filter(isPostgresRow));
    return toPostgresCapture(kept, merged);
}
/** One series of the capture, oldest first; empty without a capture or without that series. */
export function postgresSeries(capture: PostgresCapture | null, target: PostgresTarget, metric: string): PostgresPoint[] {
    return capture ? capture.points.filter((p) => p.target === target && p.metric === metric) : [];
}

export interface PostgresPeak {
    value: number;
    at: Date;
}

/** The highest point of a series (the earliest of equal ones), or null for an empty one. */
export function postgresPeak(points: ReadonlyArray<{ at: Date; value: number }>): PostgresPeak | null {
    let peak: PostgresPeak | null = null;
    for (const p of points) {
        if (!peak || p.value > peak.value) peak = { value: p.value, at: p.at };
    }
    return peak;
}

/** Read replica lag right after a gap of at least this many minutes in its series: see replicaCatchUp (the notebook's REPLICA_RESTART_GAP_MINUTES). */
export const REPLICA_RESTART_GAP_MINUTES = 10;

/**
 * The read replica's lag points that are its catch-up after a restart, not replication lag, as the notebook leaves them
 * out of its lag finding (2026-11-16): Azure Monitor reports the time since the replica last replayed a transaction, so a
 * replica that was stopped reports at least the time since then until T4 writes again (live, 2026-11-13: 1,380 s, before
 * the scenario's 219 s). After a gap of REPLICA_RESTART_GAP_MINUTES (and two intervals) or more in the series, or after the
 * window's start, the leading points that reach half the time since the last point before the gap are that catch-up.
 */
export function replicaCatchUp(capture: PostgresCapture | null, lag: readonly PostgresPoint[]): PostgresPoint[] {
    if (!capture || lag.length === 0) return [];
    const fallback = capture.intervalMinutes ?? 5;
    let anchor = (capture.windowStart ?? lag[0].at).getTime();
    let resumed: number | null = null;
    const caught: PostgresPoint[] = [];
    for (const p of lag) {
        const at = p.at.getTime();
        const intervalMs = spanMinutes(p, fallback) * 60000;
        const gapMs = Math.max(REPLICA_RESTART_GAP_MINUTES * 60000, 2 * grainMinutes(p, fallback) * 60000);
        if (at - anchor >= gapMs) resumed = anchor;
        if (resumed !== null && p.value >= (0.5 * (at + intervalMs - resumed)) / 1000) caught.push(p);
        else resumed = null;
        anchor = at + intervalMs;
    }
    return caught;
}

export interface PostgresFinding {
    id: string;
    target: string;
    status: string;
    statusSort: number;
    text: string;
    capturedAt: Date | null;
    evidence: Record<string, unknown> | null;
}

function evidenceOf(value: unknown): Record<string, unknown> | null {
    if (typeof value !== "string" || !value.trim().startsWith("{")) return null;
    try {
        const parsed: unknown = JSON.parse(value);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
    } catch {
        return null;
    }
}

/** A capture's findings (T4's or T5's), worst first. */
export function toPostgresFindings(rows: readonly Row[]): PostgresFinding[] {
    return rows
        .map((r) => ({
            id: text(r.FindingId),
            target: text(r.TargetKey),
            status: text(r.Status),
            statusSort: num(r.StatusSort) ?? 6,
            text: text(r.Finding),
            capturedAt: toDate(r.CapturedAt),
            evidence: evidenceOf(r.Evidence),
        }))
        .filter((f) => f.id !== "")
        .sort((a, b) => a.statusSort - b.statusSort || a.id.localeCompare(b.id));
}

/** T5's Azure Monitor metrics (analysis cosmosdb), by what they show. */
export const COSMOS_METRICS = {
    /** Normalized RU consumption, the highest in each interval: 100 % is throttling. */
    normalizedRu: "NormalizedRUConsumption",
    /** Request units consumed in each interval. */
    ru: "TotalRequestUnits",
    /** Requests in each interval, the 429s included. */
    requests: "TotalRequests",
    /** Requests answered 429 in each interval: 0 at every interval with requests and none throttled. */
    throttled: "ThrottledRequests",
    /** Server-side latency through the gateway, the average in each interval (ms). */
    latency: "ServerSideLatencyGateway",
    /** Provisioned throughput, hourly (RU/s). */
    provisioned: "ProvisionedThroughput",
    /** Service availability, hourly (%): 429s aren't availability errors. */
    availability: "ServiceAvailability",
} as const;

export interface CosmosPoint {
    at: Date;
    metric: string;
    value: number;
    /** Its span in minutes, when known (F35): what it covers, its save's step or less where a window or a finer save cuts it. */
    minutes?: number;
    /** Its save's step in minutes, when known (F35): Azure Monitor's interval, to step runs by and name. */
    grain?: number;
    /** The coarser point it's a piece of (F35), by pointKey: the pieces of one source are one reading. */
    source?: string;
    /** A peak given to each of its source's uncovered stretches (F35): an upper bound for each. */
    upperBound?: boolean;
}

/**
 * The latest Cosmos DB capture's account, window, and step, with its points, oldest first. For the app's views,
 * latestCosmosCapture puts every save's points in that window into it, one per interval (F35), as for T4.
 */
export interface CosmosCapture {
    account: string;
    capturedAt: Date | null;
    windowStart: Date | null;
    windowEnd: Date | null;
    /** Minutes between consecutive points of the latest capture's per-interval series, or null with single points only. */
    intervalMinutes: number | null;
    points: CosmosPoint[];
    /** How many saves its points come from (F35); one when absent. */
    saves?: number;
}

const COSMOS_METRIC = /^[A-Za-z0-9_]{1,64}$/;

const isCosmosRow = (r: Row) => toDate(r.Bucket) !== null && num(r.Value) !== null && COSMOS_METRIC.test(text(r.Metric));

/**
 * The cosmos-series rows as one capture, as given, or null without a valid row (no capture yet, or T5 is off). With
 * `merged` (latestCosmosCapture's), each point also has its span, its save's grain, and its marks, as for T4.
 */
export function toCosmosCapture(rows: readonly Row[], merged?: MergedSaves): CosmosCapture | null {
    const valid = rows.filter(isCosmosRow);
    if (valid.length === 0) return null;
    const latest = merged ? merged.latest.filter(isCosmosRow) : newestOf(valid);
    const toPoint = (r: Row): CosmosPoint => ({ at: toDate(r.Bucket) as Date, metric: text(r.Metric), value: num(r.Value) as number });
    const points = valid.map((r) => marked(toPoint(r), "T5", merged?.marks)).sort((a, b) => a.at.getTime() - b.at.getTime());
    const series = latest
        .map(toPoint)
        .filter((p) => p.metric === COSMOS_METRICS.normalizedRu)
        .sort((a, b) => a.at.getTime() - b.at.getTime());
    const gaps = series.slice(1).map((p, i) => (p.at.getTime() - series[i].at.getTime()) / 60000).filter((g) => g > 0);
    const first = latest[0] ?? valid[0];
    const account = [...latest, ...valid].map((r) => safeName(r.ResourceName)).find((name) => name !== null) ?? "";
    const intervalMinutes = merged?.step ?? (gaps.length > 0 ? Math.min(...gaps) : null);
    return { account, capturedAt: toDate(first.CapturedAt), windowStart: toDate(first.WindowStart), windowEnd: toDate(first.WindowEnd), intervalMinutes, points, saves: new Set(valid.map(capturedOf)).size };
}

/** The app's T5 capture (F35): every save's cosmos-series points in the latest capture's window, each interval's finest. */
export function latestCosmosCapture(rows: readonly Row[]): CosmosCapture | null {
    const t5 = rows.filter(isCosmosRow).map((r) => (r.TargetKey === undefined || r.TargetKey === null ? { ...r, TargetKey: "T5" } : r));
    const { rows: kept, merged } = latestWindowSaves(t5);
    return toCosmosCapture(kept, merged);
}
/** One metric of the capture, oldest first. */
export function cosmosSeries(capture: CosmosCapture | null, metric: string): CosmosPoint[] {
    return capture ? capture.points.filter((p) => p.metric === metric) : [];
}

/**
 * The runs of intervals that throttled: a 429 in the interval, or normalized RU at 100 %, each to its own span's end, and a
 * reading split across stretches once (F35: oneReadingEach).
 */
export function throttledRuns(capture: CosmosCapture | null): Array<{ from: Date; to: Date }> {
    if (!capture) return [];
    const fallback = capture.intervalMinutes ?? 1;
    const hot = new Map<number, number>();
    const mark = (p: CosmosPoint) => {
        const at = p.at.getTime();
        hot.set(at, Math.max(hot.get(at) ?? at, at + spanMinutes(p, fallback) * 60000));
    };
    for (const p of oneReadingEach(cosmosSeries(capture, COSMOS_METRICS.throttled))) if (p.value > 0) mark(p);
    for (const p of oneReadingEach(cosmosSeries(capture, COSMOS_METRICS.normalizedRu))) if (p.value >= 100) mark(p);
    const runs: Array<{ from: Date; to: Date }> = [];
    for (const [at, end] of [...hot].sort((a, b) => a[0] - b[0])) {
        const last = runs[runs.length - 1];
        if (last && at <= last.to.getTime()) {
            if (end > last.to.getTime()) last.to = new Date(end);
        } else runs.push({ from: new Date(at), to: new Date(end) });
    }
    return runs;
}

export interface ThrottleEpisode {
    id: string;
    start: Date | null;
    end: Date | null;
    status: string;
    text: string;
}

/** The capture's throttling episodes (cosmosdb.T5.throttle.<yyyymmddThhmm>), oldest first. */
export function throttleEpisodes(rows: readonly Row[]): ThrottleEpisode[] {
    return rows
        .filter((r) => text(r.FindingId).startsWith("cosmosdb.T5.throttle."))
        .map((r) => ({ id: text(r.FindingId), start: toDate(r.WindowStart), end: toDate(r.WindowEnd), status: text(r.Status), text: text(r.Finding) }))
        .sort((a, b) => (a.start?.getTime() ?? 0) - (b.start?.getTime() ?? 0));
}
/** T5's capture findings have the same shape as T4's. */
export const toCaptureFindings = toPostgresFindings;

const SKU = /^[A-Za-z0-9_]{1,64}$/;

/** Each server's compute size, from the capture finding's evidence (servers: role and sku). */
export function postgresSkus(findings: readonly PostgresFinding[]): Partial<Record<PostgresTarget, string>> {
    const out: Partial<Record<PostgresTarget, string>> = {};
    const servers = findings.find((f) => f.id === "postgresql.T4.capture")?.evidence?.servers;
    if (!Array.isArray(servers)) return out;
    for (const server of servers as unknown[]) {
        if (!server || typeof server !== "object") continue;
        const { role, sku } = server as Record<string, unknown>;
        const target: PostgresTarget | null = role === "primary" ? "T4" : role === "replica" ? "T4-replica" : null;
        if (target && typeof sku === "string" && SKU.test(sku)) out[target] = sku;
    }
    return out;
}
