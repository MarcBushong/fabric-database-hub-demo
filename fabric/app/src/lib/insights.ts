// Rule-based insights: plain sentences computed from the query results in the browser. No external AI service.

import { SQL_TARGETS, type TargetKey } from "./dax";
import { formatBeside, formatDateTimeUtc, formatDayUtc, formatDuration, formatNumber, formatTimeUtc, percent, type NumberKind } from "./format";
import { mean } from "./stats";
import type { StatusName } from "./status";
import type { EstateTarget, PageId } from "./view-state";
import {
    FAMILY_LABEL,
    POSTGRES_METRICS,
    postgresPeak,
    postgresSeries,
    replicaCatchUp,
    waitFamily,
    type Bin,
    type Check,
    type Incident,
    type Meta,
    type PostgresCapture,
    type ReadinessSummary,
    type TargetSummary,
    type WaitFlow,
} from "../data/model";

export interface Insight {
    id: string;
    /** An ADR 0012 status when the insight needs attention or confirms a pass; null for a neutral fact. */
    status: StatusName | null;
    /** The headline number, short. */
    metric: string;
    title: string;
    detail: string;
    page?: PageId;
    /** The target the page drills into. */
    target?: EstateTarget;
    incident?: string;
}

type BinField = "cpu" | "blocked" | "lockWaitS" | "bufferIoS" | "logRateS" | "waitS" | "ioMb" | "batch" | "sessions";

/** An incident family's own signal: a column of every bin, or one wait category, the one the analysis notebook's
 *  detector reads for that family (WAIT_FAMILY_CATEGORIES in NB_DatabaseHub_LiveActivity). */
export interface FamilySignal {
    label: string;
    kind: NumberKind;
    field?: BinField;
    category?: string;
}

/** The signal each incident family is about, with its unit for sentences. */
export const FAMILY_SIGNAL: Record<string, FamilySignal> = {
    io: { field: "bufferIoS", label: "Buffer IO (PAGEIOLATCH) waits", kind: "seconds" },
    cpu: { field: "cpu", label: "CPU", kind: "percent" },
    blocking: { field: "blocked", label: "blocked processes", kind: "int" },
    log_rate: { field: "logRateS", label: "Log Rate Governor waits", kind: "seconds" },
    tran_log: { category: "Tran Log IO", label: "Tran Log IO (log flush) waits", kind: "seconds" },
    latch: { category: "Buffer Latch", label: "Buffer Latch waits", kind: "seconds" },
    network: { category: "Network IO", label: "Network IO waits", kind: "seconds" },
    memory: { category: "Memory", label: "Memory waits", kind: "seconds" },
    parallelism: { category: "Parallelism", label: "Parallelism waits", kind: "seconds" },
};

const ALL_WAITS: FamilySignal = { field: "waitS", label: "wait time", kind: "seconds" };

/** The family's own signal. A wait category needs bins with their waits per category (withCategoryWaits): without
 *  them, it's all the waits, and says so, rather than a series that isn't there. */
export function familySignal(family: string, bins?: readonly Bin[]): FamilySignal {
    const signal = FAMILY_SIGNAL[family] ?? ALL_WAITS;
    if (signal.category && bins !== undefined && !bins.some((b) => b.waits)) return ALL_WAITS;
    return signal;
}

/** A bin's value of the signal. A category with no row in a bin that has categories waited 0 seconds; a bin without
 *  them is unknown. */
export function signalValue(signal: FamilySignal, b: Bin): number | null {
    if (signal.category) return b.waits ? (b.waits[signal.category] ?? 0) : null;
    return signal.field ? b[signal.field] : null;
}

function joinTargets(keys: readonly string[]): string {
    if (keys.length <= 1) return keys.join("");
    return `${keys.slice(0, -1).join(", ")} and ${keys[keys.length - 1]}`;
}

/** Padding around an incident window for the replay and the baseline: half its length, 30 to 180 minutes. */
export function incidentPadMinutes(incident: Pick<Incident, "durationMin">): number {
    return Math.min(Math.max(Math.round(incident.durationMin / 2), 30), 180);
}

export interface IncidentComparison {
    signal: string;
    kind: NumberKind;
    baseline: number | null;
    during: number | null;
    peak: number | null;
    peakAt: Date | null;
    ratio: number | null;
}

/** Twice its baseline or more is an incident insight's Warning. */
const INCIDENT_WARNING_RATIO = 2;

/** A ratio under 10 as formatBeside writes it against the Warning's 2×, so 1.96 reads "1.96", never "2.0" without the
 *  Warning; 10 and more, whole. */
function timesNumber(ratio: number): string {
    return ratio >= 10 ? String(Math.round(ratio)) : formatBeside(ratio, "decimal", INCIDENT_WARNING_RATIO);
}

/** A ratio against a baseline on a tile: "3.4×", "35×", and ">100×" beyond, where a baseline near zero makes the exact
 *  number noise (dbhubc5's tempdb latch: 1610× a baseline of 0.02 s). */
export function timesShort(ratio: number): string {
    return ratio >= 100 ? ">100×" : `${timesNumber(ratio)}×`;
}

/** The same ratio in a sentence: "3.4 times", "35 times", "more than 100 times". */
export function timesText(ratio: number): string {
    return ratio >= 100 ? "more than 100 times" : `${timesNumber(ratio)} times`;
}

/** "baseline 0.4 s per bin", or "baseline near zero" when it rounds to nothing at the signal's precision. */
export function baselineText(baseline: number, kind: NumberKind): string {
    const text = formatNumber(baseline, kind);
    return text === formatNumber(0, kind) ? "baseline near zero" : `baseline ${text} per bin`;
}

/** Mean of the incident's own signal in the padding before the window against the window itself. */
export function compareIncident(incident: Incident, bins: readonly Bin[]): IncidentComparison {
    const signal = familySignal(incident.family, bins);
    const { label, kind } = signal;
    const pad = incidentPadMinutes(incident) * 60000;
    const value = (b: Bin) => signalValue(signal, b);
    const before = bins.filter((b) => b.at >= new Date(incident.start.getTime() - pad) && b.at < incident.start).map(value);
    const inside = bins.filter((b) => b.at >= incident.start && b.at < incident.end);
    const during = inside.map(value).filter((v): v is number => v !== null);
    let peak: number | null = null;
    let peakAt: Date | null = null;
    for (const b of inside) {
        const v = value(b);
        if (v !== null && (peak === null || v > peak)) {
            peak = v;
            peakAt = b.at;
        }
    }
    const baseline = mean(before.filter((v): v is number => v !== null));
    const duringMean = mean(during);
    const ratio = baseline && baseline > 0 && duringMean !== null ? duringMean / baseline : null;
    return { signal: label, kind, baseline, during: duringMean, peak, peakAt, ratio };
}

export function incidentInsight(incident: Incident, comparison: IncidentComparison | null): Insight {
    const family = FAMILY_LABEL[incident.family] ?? "An incident";
    const span = `${formatTimeUtc(incident.start)} to ${formatTimeUtc(incident.end)} UTC on ${formatDayUtc(incident.start)}`;
    if (comparison && comparison.ratio !== null && comparison.during !== null) {
        return {
            id: `incident-ratio-${incident.key}`,
            status: comparison.ratio >= INCIDENT_WARNING_RATIO ? "Warning" : null,
            metric: timesShort(comparison.ratio),
            title: `${incident.target} ${comparison.signal} ran at ${timesText(comparison.ratio)} their baseline from ${span}.`,
            detail: `${formatNumber(comparison.during, comparison.kind)} per bin on average during the window, against ${formatNumber(comparison.baseline, comparison.kind)} in the ${formatDuration(incidentPadMinutes(incident))} before; peak ${formatNumber(comparison.peak, comparison.kind)} at ${formatTimeUtc(comparison.peakAt)} UTC.`,
            page: "incidents",
            incident: incident.key,
        };
    }
    const peak = comparison?.peak ?? incident.peakValue;
    return {
        id: `incident-${incident.key}`,
        status: null,
        metric: formatDuration(incident.durationMin),
        title: `${incident.target} ${family.toLowerCase()} lasted ${formatDuration(incident.durationMin)}, from ${span}.`,
        detail:
            peak !== null
                ? `It peaked at ${formatNumber(peak, comparison?.kind ?? "decimal")}${comparison ? "" : ` ${incident.peakUnit}`} per bin. ${incident.source === "Detected signal" ? "The notebook found it in the telemetry; no notebook request covers it." : `The notebook requested it (${incident.scenario}).`}`
                : `${incident.source}.`,
        page: "incidents",
        incident: incident.key,
    };
}

export function incidentsOverview(incidents: readonly Incident[]): Insight | null {
    if (incidents.length === 0) return null;
    const byTarget = new Map<string, number>();
    for (const i of incidents) byTarget.set(i.target, (byTarget.get(i.target) ?? 0) + 1);
    const [topTarget, topCount] = [...byTarget.entries()].sort((a, b) => b[1] - a[1])[0];
    const longest = [...incidents].sort((a, b) => b.durationMin - a.durationMin)[0];
    const families = new Set(incidents.map((i) => FAMILY_LABEL[i.family] ?? i.family));
    return {
        id: "incidents-overview",
        status: "Warning",
        metric: String(incidents.length),
        title: `${incidents.length} incident window${incidents.length === 1 ? "" : "s"} in this period, ${topCount} of them on ${topTarget}.`,
        detail: `${[...families].join(", ")}; the longest ran ${formatDuration(longest.durationMin)} on ${longest.target} from ${formatDateTimeUtc(longest.start)}.`,
        page: "incidents",
        incident: incidents[0].key,
    };
}

export function dominantWaitInsight(flows: readonly WaitFlow[]): Insight | null {
    const total = flows.reduce((a, f) => a + f.seconds, 0);
    if (total <= 0) return null;
    const byTarget = new Map<string, number>();
    for (const f of flows) byTarget.set(f.target, (byTarget.get(f.target) ?? 0) + f.seconds);
    const [busiest, busiestSeconds] = [...byTarget.entries()].sort((a, b) => b[1] - a[1])[0];
    const top = flows.filter((f) => f.target === busiest).sort((a, b) => b.seconds - a.seconds)[0];
    const share = busiestSeconds / total;
    return {
        id: "dominant-wait",
        status: null,
        metric: percent(share),
        title: `${busiest} carries ${percent(share)} of the estate's wait time; its biggest category is ${top.category}.`,
        detail: `${formatNumber(top.seconds, "seconds")} of ${top.category} out of ${formatNumber(busiestSeconds, "seconds")} on ${busiest}, and ${formatNumber(total, "seconds")} across the selected targets.`,
        page: "incidents",
    };
}

export function waitFamilyInsight(flows: readonly WaitFlow[]): Insight | null {
    const total = flows.reduce((a, f) => a + f.seconds, 0);
    if (total <= 0) return null;
    const byFamily = new Map<string, number>();
    for (const f of flows) byFamily.set(waitFamily(f.category), (byFamily.get(waitFamily(f.category)) ?? 0) + f.seconds);
    const [family, seconds] = [...byFamily.entries()].sort((a, b) => b[1] - a[1])[0];
    return {
        id: "wait-family",
        status: null,
        metric: percent(seconds / total),
        title: `${family} is the largest wait family: ${percent(seconds / total)} of all wait time.`,
        detail: `${formatNumber(seconds, "seconds")} of ${formatNumber(total, "seconds")} across ${byFamily.size} families.`,
        page: "incidents",
    };
}

export function busiestHourInsight(bins: readonly Bin[], field: "batch" | "waitS" | "sessions" = "waitS"): Insight | null {
    const byHour = new Array<number>(24).fill(0);
    let any = false;
    for (const b of bins) {
        const v = b[field];
        if (v !== null && v > 0) {
            byHour[b.at.getUTCHours()] += field === "sessions" ? Math.max(v, 0) : v;
            any = true;
        }
    }
    if (!any) return null;
    const hour = byHour.indexOf(Math.max(...byHour));
    const label = field === "batch" ? "batch requests" : field === "sessions" ? "session peaks" : "wait time";
    return {
        id: `busiest-hour-${field}`,
        status: null,
        metric: `${String(hour).padStart(2, "0")}:00`,
        title: `The estate's busiest hour for ${label} is ${String(hour).padStart(2, "0")}:00 to ${String((hour + 1) % 24).padStart(2, "0")}:00 UTC.`,
        detail: `${formatNumber(byHour[hour], field === "waitS" ? "seconds" : "int")} in that hour across the window, ${percent(byHour[hour] / byHour.reduce((a, v) => a + v, 0))} of the total.`,
        page: "estate",
    };
}

export function lagInsight(targets: readonly TargetSummary[]): Insight | null {
    const known = targets.filter((t) => t.lagMin !== null);
    if (known.length === 0) return null;
    const stale = known.filter((t) => (t.lagMin ?? 0) > 15);
    const fresh = known.filter((t) => (t.lagMin ?? 0) <= 15);
    if (stale.length === 0) {
        return {
            id: "telemetry-lag",
            status: "Pass",
            metric: formatNumber(Math.max(...known.map((t) => t.lagMin ?? 0)), "minutes"),
            title: "Every target's telemetry was fresh when the notebook captured it.",
            detail: known.map((t) => `${t.key} ${formatNumber(t.lagMin, "minutes")}`).join(", "),
            page: "readiness",
        };
    }
    const worst = Math.max(...stale.map((t) => t.lagMin ?? 0));
    return {
        id: "telemetry-lag",
        status: "Warning",
        metric: formatNumber(worst, "minutes"),
        title: `${joinTargets(stale.map((t) => t.key))} telemetry was up to ${formatDuration(worst)} old when the notebook captured it.`,
        detail: `${fresh.length ? `${joinTargets(fresh.map((t) => t.key))} was fresh (${fresh.map((t) => formatNumber(t.lagMin, "minutes")).join(", ")}). ` : ""}The telemetry endpoint keeps 7 days; a stale target may be stopped or deallocated.`,
        page: "readiness",
    };
}

export function coverageInsight(targets: readonly TargetSummary[], selected: readonly TargetKey[]): Insight | null {
    const shown = targets.filter((t) => selected.includes(t.key));
    if (shown.length === 0) return null;
    const most = Math.max(...shown.map((t) => t.bins));
    if (most <= 0) return null;
    const thin = shown.filter((t) => t.bins < most / 4);
    const missing = selected.filter((k) => !shown.some((t) => t.key === k && t.bins > 0));
    if (thin.length === 0 && missing.length === 0) {
        return {
            id: "bin-coverage",
            status: "Pass",
            metric: `${shown.length}/${selected.length}`,
            title: `All ${selected.length} selected targets sent telemetry bins for the whole period.`,
            detail: shown.map((t) => `${t.key}: ${formatNumber(t.bins, "int")} CPU bins`).join(", "),
            page: "estate",
        };
    }
    const quiet = SQL_TARGETS.filter((k) => missing.includes(k) || thin.some((t) => t.key === k));
    return {
        id: "bin-coverage",
        status: "Warning",
        metric: `${selected.length - missing.length}/${selected.length}`,
        title: `${joinTargets(quiet)} sent telemetry for only part of the period.`,
        detail: shown.map((t) => `${t.key}: ${formatNumber(t.bins, "int")} CPU bins`).join(", ") + ` (the busiest target sent ${formatNumber(most, "int")}).`,
        page: "estate",
    };
}

export function readinessInsight(summary: ReadinessSummary | null, checks: readonly Check[]): Insight | null {
    if (!summary || summary.checks === 0) return null;
    const applicable = summary.checks - summary.notSupported - summary.notSelected;
    const share = applicable > 0 ? summary.passed / applicable : 0;
    const next = checks.find((c) => c.statusSort <= 3 && c.remediation);
    const status: StatusName = summary.failed > 0 ? "Fail" : summary.manual > 0 ? "Manual action required" : summary.warnings > 0 ? "Warning" : "Pass";
    return {
        id: "readiness",
        status,
        metric: percent(share),
        title: `${summary.passed} of ${applicable} applicable checks pass; ${summary.failed} failed, ${summary.manual} need a manual step, and ${summary.warnings} carry warnings.`,
        detail: next ? `Next step (${next.checkId}): ${next.remediation}` : summary.runLabel,
        page: "readiness",
    };
}

export function freshnessInsight(meta: Meta | null, now: Date = new Date()): Insight | null {
    if (!meta) return null;
    if (!meta.latestCapture) {
        return {
            id: "freshness",
            status: "Manual action required",
            metric: "none",
            title: "No snapshot in the lakehouse yet.",
            detail: "Run NB_DatabaseHub_LiveActivity: it saves the telemetry snapshots, findings, and incident windows this app reads.",
            page: "links",
        };
    }
    const hours = (now.getTime() - meta.latestCapture.getTime()) / 3600000;
    return {
        id: "freshness",
        status: hours > 24 ? "Warning" : "Pass",
        metric: formatDuration(hours * 60).replace(" ago", ""),
        title: `The newest snapshot is from ${formatDateTimeUtc(meta.latestCapture)}, ${formatDuration(hours * 60)} ago.`,
        detail: `${formatNumber(meta.notebookRuns, "int")} notebook run${meta.notebookRuns === 1 ? "" : "s"} saved telemetry; history covers ${formatDayUtc(meta.earliestDay)} to ${formatDayUtc(meta.latestDay)}. ${hours > 24 ? "Run NB_DatabaseHub_LiveActivity to refresh it." : ""}`.trim(),
        page: "links",
    };
}

// ---- T4: the PostgreSQL flexible server and its read replica (2026-11-13, ADR 0025) ----------------------------------

/** The notebook's thresholds for T4's findings, presenter heuristics: Read replica lag of 60 s or more, CPU of 80 % or more. */
export const REPLICA_LAG_WARNING_SECONDS = 60;
export const POSTGRES_CPU_WARNING_PERCENT = 80;

/** T4's max_connections, which the template sets on every size (config/versions.json, postgresql.maxConnections). */
export const POSTGRES_MAX_CONNECTIONS = 50;
/** The slots Azure keeps for physical replication and monitoring: reserved_connections plus superuser_reserved_connections (Learn: limits). */
export const POSTGRES_RESERVED_CONNECTIONS = 15;
/**
 * The connection slots clients can use on T4, as the notebook counts them: connection-surge's measured signal is T4's
 * Connections (active_connections) at this many or more (F34). Azure Monitor counts the reserved slots' sessions too, so
 * a surge that fills the slots reads 35 or more (36 to 39 live, 2026-11-21). Its refused attempts aren't in Failed
 * connections (connections_failed), which stayed 0 in every interval then.
 */
export const POSTGRES_USABLE_CONNECTIONS = POSTGRES_MAX_CONNECTIONS - POSTGRES_RESERVED_CONNECTIONS;
/** The rule above, in words, for a sentence or a chart's line. */
export const USABLE_SLOTS_TEXT = `the ${POSTGRES_USABLE_CONNECTIONS} slots clients can use (max_connections ${POSTGRES_MAX_CONNECTIONS}, less ${POSTGRES_RESERVED_CONNECTIONS} reserved)`;
/** What Azure Monitor's failed connections leave out, wherever they're shown (F34). */
export const FAILED_CONNECTIONS_CAVEAT = "At the limit, PostgreSQL refuses a new client (too many connections), and Azure Monitor's failed connections don't count that refusal.";

/** The read replica's peak lag in the latest capture, or why there's none: the replica exists only during a session. Its catch-up after a restart isn't lag (replicaCatchUp). */
export function replicaLagInsight(capture: PostgresCapture | null): Insight | null {
    if (!capture) return null;
    const all = postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag);
    const caught = replicaCatchUp(capture, all);
    const lag = all.filter((p) => !caught.includes(p));
    const peak = postgresPeak(lag);
    const caughtPeak = postgresPeak(caught);
    const left = caughtPeak ? ` Left out: ${formatNumber(caughtPeak.value, "seconds")} at ${formatTimeUtc(caught[0].at)} UTC, the replica's catch-up after its restart, not lag.` : "";
    if (!peak) {
        if (caughtPeak) {
            return {
                id: "replica-lag",
                status: "Pass",
                metric: "catch-up",
                title: "The latest capture's Read replica lag is only the replica's catch-up after its restart.",
                detail: `Up to ${formatNumber(caughtPeak.value, "seconds")} from ${formatTimeUtc(caught[0].at)} UTC on ${formatDayUtc(caught[0].at)}: the time since its last replay until T4 wrote again, not replication lag.`,
                page: "estate",
                target: "T4",
            };
        }
        return {
            id: "replica-lag",
            status: "Not selected",
            metric: "none",
            title: "The latest capture has no Read replica lag.",
            detail: "T4's read replica exists only during a session: start-demo.ps1 creates it, and stop-demo.ps1 captures its metrics before it deletes it.",
            page: "estate",
            target: "T4",
        };
    }
    const replica = capture.servers["T4-replica"];
    return {
        id: "replica-lag",
        status: peak.value >= REPLICA_LAG_WARNING_SECONDS ? "Warning" : "Pass",
        metric: formatBeside(peak.value, "seconds", REPLICA_LAG_WARNING_SECONDS),
        title: `Read replica lag peaked at ${formatBeside(peak.value, "seconds", REPLICA_LAG_WARNING_SECONDS)} at ${formatTimeUtc(peak.at)} UTC on ${formatDayUtc(peak.at)}.`,
        detail: `${formatNumber(mean(lag.map((p) => p.value)), "seconds")} on average over ${lag.length} interval${lag.length === 1 ? "" : "s"}${replica ? ` on ${replica}` : ""}; ${REPLICA_LAG_WARNING_SECONDS} s or more is a warning.${left}`,
        page: "estate",
        target: "T4",
    };
}

/** T4's peak CPU in the latest capture, with its peak of active connections. */
export function postgresCpuInsight(capture: PostgresCapture | null): Insight | null {
    const cpu = postgresSeries(capture, "T4", POSTGRES_METRICS.cpu);
    const peak = postgresPeak(cpu);
    if (!peak) return null;
    const connections = postgresPeak(postgresSeries(capture, "T4", POSTGRES_METRICS.connections));
    return {
        id: "postgres-cpu",
        status: peak.value >= POSTGRES_CPU_WARNING_PERCENT ? "Warning" : "Pass",
        metric: formatBeside(peak.value, "percent", POSTGRES_CPU_WARNING_PERCENT),
        title: `T4's CPU peaked at ${formatBeside(peak.value, "percent", POSTGRES_CPU_WARNING_PERCENT)} at ${formatTimeUtc(peak.at)} UTC on ${formatDayUtc(peak.at)}.`,
        detail: `${formatNumber(mean(cpu.map((p) => p.value)), "percent")} on average${connections ? `; active connections peaked at ${formatNumber(connections.value, "int")} at ${formatTimeUtc(connections.at)} UTC` : ""}. ${POSTGRES_CPU_WARNING_PERCENT} % or more is a warning.`,
        page: "estate",
        target: "T4",
    };
}

/** T4's failed connections in the latest capture: their total, and the interval with the most. A client refused at the connection limit isn't among them (F34). */
export function failedConnectionsInsight(capture: PostgresCapture | null): Insight | null {
    const failed = postgresSeries(capture, "T4", POSTGRES_METRICS.failed);
    const peak = postgresPeak(failed);
    if (!peak) return null;
    const total = failed.reduce((sum, p) => sum + p.value, 0);
    if (total <= 0) {
        return {
            id: "postgres-failed",
            status: "Pass",
            metric: "0",
            title: "Azure Monitor counted no failed connections on T4 in the latest capture.",
            detail: `${failed.length} interval${failed.length === 1 ? "" : "s"} from ${formatDateTimeUtc(failed[0].at)} to ${formatDateTimeUtc(failed[failed.length - 1].at)}. ${FAILED_CONNECTIONS_CAVEAT}`,
            page: "estate",
            target: "T4",
        };
    }
    const top = failed.find((p) => p.at === peak.at);
    const interval = (capture?.saves ?? 1) > 1 ? (top?.grain ?? capture?.intervalMinutes) : capture?.intervalMinutes;
    return {
        id: "postgres-failed",
        status: "Warning",
        metric: formatNumber(total, "int"),
        title: `${formatNumber(total, "int")} failed connection${total === 1 ? "" : "s"} on T4 in the latest capture.`,
        detail: `At most ${formatNumber(peak.value, "int")} in one${interval ? ` ${formatNumber(interval, "int")}-minute` : ""} interval, at ${formatTimeUtc(peak.at)} UTC on ${formatDayUtc(peak.at)}. ${FAILED_CONNECTIONS_CAVEAT}`,
        page: "estate",
        target: "T4",
    };
}
