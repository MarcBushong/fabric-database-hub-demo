// Rule-based insights: plain sentences computed from the query results in the browser. No external AI service.

import { SQL_TARGETS, type TargetKey } from "./dax";
import { formatDateTimeUtc, formatDayUtc, formatDuration, formatNumber, formatTimeUtc, type NumberKind } from "./format";
import { mean } from "./stats";
import type { StatusName } from "./status";
import type { PageId } from "./view-state";
import {
    FAMILY_LABEL,
    POSTGRES_METRICS,
    postgresPeak,
    postgresSeries,
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
    incident?: string;
}

/** The signal each incident family is about, with its unit for sentences. */
export const FAMILY_SIGNAL: Record<string, { field: keyof Bin; label: string; kind: NumberKind }> = {
    io: { field: "bufferIoS", label: "Buffer IO (PAGEIOLATCH) waits", kind: "seconds" },
    cpu: { field: "cpu", label: "CPU", kind: "percent" },
    blocking: { field: "blocked", label: "blocked processes", kind: "int" },
    log_rate: { field: "logRateS", label: "Log Rate Governor waits", kind: "seconds" },
};

export function familySignal(family: string): { field: keyof Bin; label: string; kind: NumberKind } {
    return FAMILY_SIGNAL[family] ?? { field: "waitS", label: "wait time", kind: "seconds" };
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

/** Mean of the incident's own signal in the padding before the window against the window itself. */
export function compareIncident(incident: Incident, bins: readonly Bin[]): IncidentComparison {
    const { field, label, kind } = familySignal(incident.family);
    const pad = incidentPadMinutes(incident) * 60000;
    const value = (b: Bin) => b[field] as number | null;
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
        const times = comparison.ratio >= 10 ? Math.round(comparison.ratio).toString() : comparison.ratio.toFixed(1);
        return {
            id: `incident-ratio-${incident.key}`,
            status: comparison.ratio >= 2 ? "Warning" : null,
            metric: `${times}×`,
            title: `${incident.target} ${comparison.signal} ran at ${times} times their baseline from ${span}.`,
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
        metric: `${Math.round(share * 100)} %`,
        title: `${busiest} carries ${Math.round(share * 100)} % of the estate's wait time; its biggest category is ${top.category}.`,
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
        metric: `${Math.round((seconds / total) * 100)} %`,
        title: `${family} is the largest wait family: ${Math.round((seconds / total) * 100)} % of all wait time.`,
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
        detail: `${formatNumber(byHour[hour], field === "waitS" ? "seconds" : "int")} in that hour across the window, ${Math.round((byHour[hour] / byHour.reduce((a, v) => a + v, 0)) * 100)} % of the total.`,
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
        metric: `${Math.round(share * 100)} %`,
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

/** The read replica's peak lag in the latest capture, or why there's none: the replica exists only during a session. */
export function replicaLagInsight(capture: PostgresCapture | null): Insight | null {
    if (!capture) return null;
    const lag = postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag);
    const peak = postgresPeak(lag);
    if (!peak) {
        return {
            id: "replica-lag",
            status: "Not selected",
            metric: "none",
            title: "The latest capture has no Read replica lag.",
            detail: "T4's read replica exists only during a session: start-demo.ps1 creates it, and stop-demo.ps1 captures its metrics before it deletes it.",
            page: "postgres",
        };
    }
    const replica = capture.servers["T4-replica"];
    return {
        id: "replica-lag",
        status: peak.value >= REPLICA_LAG_WARNING_SECONDS ? "Warning" : "Pass",
        metric: formatNumber(peak.value, "seconds"),
        title: `Read replica lag peaked at ${formatNumber(peak.value, "seconds")} at ${formatTimeUtc(peak.at)} UTC on ${formatDayUtc(peak.at)}.`,
        detail: `${formatNumber(mean(lag.map((p) => p.value)), "seconds")} on average over ${lag.length} interval${lag.length === 1 ? "" : "s"}${replica ? ` on ${replica}` : ""}; ${REPLICA_LAG_WARNING_SECONDS} s or more is a warning.`,
        page: "postgres",
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
        metric: formatNumber(peak.value, "percent"),
        title: `T4's CPU peaked at ${formatNumber(peak.value, "percent")} at ${formatTimeUtc(peak.at)} UTC on ${formatDayUtc(peak.at)}.`,
        detail: `${formatNumber(mean(cpu.map((p) => p.value)), "percent")} on average${connections ? `; active connections peaked at ${formatNumber(connections.value, "int")} at ${formatTimeUtc(connections.at)} UTC` : ""}. ${POSTGRES_CPU_WARNING_PERCENT} % or more is a warning.`,
        page: "postgres",
    };
}

/** T4's failed connections in the latest capture: their total, and the interval with the most. */
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
            title: "No failed connections on T4 in the latest capture.",
            detail: `${failed.length} interval${failed.length === 1 ? "" : "s"} from ${formatDateTimeUtc(failed[0].at)} to ${formatDateTimeUtc(failed[failed.length - 1].at)}.`,
            page: "postgres",
        };
    }
    const interval = capture?.intervalMinutes;
    return {
        id: "postgres-failed",
        status: "Warning",
        metric: formatNumber(total, "int"),
        title: `${formatNumber(total, "int")} failed connection${total === 1 ? "" : "s"} on T4 in the latest capture.`,
        detail: `At most ${formatNumber(peak.value, "int")} in one${interval ? ` ${formatNumber(interval, "int")}-minute` : ""} interval, at ${formatTimeUtc(peak.at)} UTC on ${formatDayUtc(peak.at)}.`,
        page: "postgres",
    };
}
