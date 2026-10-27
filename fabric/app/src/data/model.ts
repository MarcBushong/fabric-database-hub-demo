// Typed views of the query results. Every value is checked, because a blank measure arrives as null.

import { isTargetKey, SQL_TARGETS, type TargetKey } from "../lib/dax";
import { isNumber, toDate } from "../lib/format";
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
    analysis: string;
    target: string;
    status: string;
    statusSort: number;
    text: string;
    capturedAt: Date | null;
}

export function toFindings(rows: readonly Row[]): Finding[] {
    return rows.map((r) => ({
        id: text(r.FindingId),
        analysis: text(r.Analysis) || text(r.AnalysisKey).replace(/_/g, " "),
        target: text(r.TargetKey),
        status: text(r.Status),
        statusSort: num(r.StatusSort) ?? 6,
        text: text(r.Finding),
        capturedAt: toDate(r.CapturedAt),
    }));
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
