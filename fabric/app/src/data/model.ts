// Typed views of the query results. Every value is checked, because a blank measure arrives as null.

import { isTargetKey, SQL_TARGETS, type TargetKey } from "../lib/dax";
import { isNumber, toDate } from "../lib/format";
import type { FindingsTab } from "../lib/view-state";
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
}

/** The latest PostgreSQL capture: its window, its servers, and its points, oldest first. */
export interface PostgresCapture {
    capturedAt: Date | null;
    windowStart: Date | null;
    windowEnd: Date | null;
    /** Minutes between consecutive points of one series, or null with single points only. */
    intervalMinutes: number | null;
    /** Each target's server name. */
    servers: Partial<Record<PostgresTarget, string>>;
    points: PostgresPoint[];
}

const METRIC_NAME = /^[a-z0-9_]{1,64}$/;

function intervalOf(points: readonly PostgresPoint[]): number | null {
    const previous = new Map<string, number>();
    let best: number | null = null;
    for (const p of points) {
        const key = `${p.target}|${p.metric}`;
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

/** The postgres-series rows as one capture, or null without a valid row (no capture yet). */
export function toPostgresCapture(rows: readonly Row[]): PostgresCapture | null {
    const points: PostgresPoint[] = [];
    const servers: Partial<Record<PostgresTarget, string>> = {};
    let capturedAt: Date | null = null;
    let windowStart: Date | null = null;
    let windowEnd: Date | null = null;
    for (const r of rows) {
        const at = toDate(r.Bucket);
        const value = num(r.Value);
        const metric = text(r.Metric);
        const target = r.TargetKey;
        if (!at || value === null || !isPostgresTarget(target) || !METRIC_NAME.test(metric)) continue;
        const server = safeName(r.ResourceName) ?? "";
        points.push({ at, target, server, metric, value });
        if (server && !servers[target]) servers[target] = server;
        capturedAt ??= toDate(r.CapturedAt);
        windowStart ??= toDate(r.WindowStart);
        windowEnd ??= toDate(r.WindowEnd);
    }
    if (points.length === 0) return null;
    points.sort((a, b) => a.at.getTime() - b.at.getTime());
    return { capturedAt, windowStart, windowEnd, intervalMinutes: intervalOf(points), servers, points };
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
export function postgresPeak(points: readonly PostgresPoint[]): PostgresPeak | null {
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
    const intervalMs = (capture.intervalMinutes ?? 5) * 60000;
    const gapMs = Math.max(REPLICA_RESTART_GAP_MINUTES * 60000, 2 * intervalMs);
    let anchor = (capture.windowStart ?? lag[0].at).getTime();
    let resumed: number | null = null;
    const caught: PostgresPoint[] = [];
    for (const p of lag) {
        const at = p.at.getTime();
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

/** The latest capture's findings, worst first. */
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
