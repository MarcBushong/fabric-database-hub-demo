// Each target's health at a glance: its worst status, its key numbers, and its CPU over the period. Pure, so the
// Overview's and the Estate's tiles agree, and tests can check them.

import {
    COSMOS_METRICS,
    cosmosSeries,
    POSTGRES_METRICS,
    postgresPeak,
    postgresSeries,
    replicaCatchUp,
    type Bin,
    type CosmosCapture,
    type Finding,
    type PostgresCapture,
    type PostgresFinding,
    type TargetSummary,
} from "@/data/model";
import { formatAgo, formatBeside, formatNumber } from "./format";
import { POSTGRES_CPU_WARNING_PERCENT, REPLICA_LAG_WARNING_SECONDS } from "./insights";
import { statusBySort, worstStatus, type StatusName } from "./status";
import type { EstateTarget } from "./view-state";

export interface HealthMetric {
    label: string;
    value: string;
}

export interface TargetHealth {
    key: EstateTarget;
    /** The worst status of its findings in the period, or null when it has none (or no data). */
    status: StatusName | null;
    /** True when the history has data for it in the period. */
    reporting: boolean;
    metrics: HealthMetric[];
    /** One line: freshness, or why there's no data. */
    note: string;
    /** CPU per bin over the period, for the sparkline. */
    spark: Array<number | null>;
    incidents: number;
    attention: number;
}

/** The SQL targets' health from the estate rows, their findings, and their bins. */
export function sqlHealth(targets: readonly TargetSummary[], findings: readonly Finding[], bins: readonly Bin[], selected: readonly EstateTarget[]): TargetHealth[] {
    const out: TargetHealth[] = [];
    for (const key of ["T1", "T2", "T3"] as const) {
        if (!selected.includes(key)) continue;
        const t = targets.find((x) => x.key === key);
        const mine = findings.filter((f) => f.target === key && f.statusSort <= 3);
        const worst = t ? statusBySort(t.worstFindingSort) : null;
        const status = mine.length > 0 ? worstStatus(mine.map((f) => f.status))?.name ?? null : worst && worst.needsAttention ? worst.name : t && t.bins > 0 ? "Pass" : null;
        out.push({
            key,
            status,
            reporting: Boolean(t && t.bins > 0),
            metrics: t
                ? [
                      { label: "CPU peak", value: formatBeside(t.cpuPeak, "percent", 80) },
                      { label: "Waits", value: formatNumber(t.waitS, "seconds") },
                      { label: "Sessions", value: formatNumber(t.sessionsPeak, "int") },
                  ]
                : [],
            note: t ? (t.lagMin !== null ? `Telemetry ${formatNumber(t.lagMin, "minutes")} behind at capture` : `${t.bins} bins in the period`) : "No telemetry in this period",
            spark: bins.filter((b) => b.target === key).map((b) => b.cpu),
            incidents: t?.incidents ?? 0,
            attention: mine.length,
        });
    }
    return out;
}

/** T4's health (with its read replica's lag) from the latest PostgreSQL capture. */
export function postgresHealth(capture: PostgresCapture | null, findings: readonly PostgresFinding[]): TargetHealth {
    const attention = findings.filter((f) => f.statusSort <= 3);
    const worst = worstStatus(findings.map((f) => f.status));
    if (!capture) {
        return {
            key: "T4",
            status: null,
            reporting: false,
            metrics: [],
            note: "No capture yet: a session's end saves T4's metrics",
            spark: [],
            incidents: 0,
            attention: attention.length,
        };
    }
    const cpu = postgresSeries(capture, "T4", POSTGRES_METRICS.cpu);
    const lag = postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag);
    const caught = replicaCatchUp(capture, lag);
    const lagPeak = postgresPeak(lag.filter((p) => !caught.includes(p)));
    const failed = postgresSeries(capture, "T4", POSTGRES_METRICS.failed).reduce((a, p) => a + p.value, 0);
    return {
        key: "T4",
        status: worst?.name ?? "Pass",
        reporting: true,
        metrics: [
            { label: "CPU peak", value: formatBeside(postgresPeak(cpu)?.value ?? null, "percent", POSTGRES_CPU_WARNING_PERCENT) },
            { label: "Replica lag", value: lagPeak ? formatBeside(lagPeak.value, "seconds", REPLICA_LAG_WARNING_SECONDS) : "–" },
            { label: "Failed conn.", value: formatNumber(failed, "int") },
        ],
        note: `Captured ${formatAgo(capture.capturedAt)}${lagPeak && lagPeak.value >= REPLICA_LAG_WARNING_SECONDS ? "; the replica lagged" : ""}`,
        spark: cpu.map((p) => p.value),
        incidents: 0,
        attention: attention.length,
    };
}

/** T5's health from the latest Cosmos DB capture: its normalized RU peak, its 429s, and whether it recovered. */
export function cosmosHealth(capture: CosmosCapture | null, findings: readonly PostgresFinding[]): TargetHealth {
    const attention = findings.filter((f) => f.statusSort <= 3);
    const worst = worstStatus(findings.map((f) => f.status));
    if (!capture) {
        return { key: "T5", status: null, reporting: false, metrics: [], note: "No capture yet: a session's end saves T5's metrics", spark: [], incidents: 0, attention: attention.length };
    }
    const ru = cosmosSeries(capture, COSMOS_METRICS.normalizedRu);
    const throttled = cosmosSeries(capture, COSMOS_METRICS.throttled).reduce((a, p) => a + p.value, 0);
    const availability = cosmosSeries(capture, COSMOS_METRICS.availability).map((p) => p.value);
    const recovered = findings.find((f) => f.id === "cosmosdb.T5.recovery")?.status === "Pass";
    return {
        key: "T5",
        status: worst?.name ?? "Pass",
        reporting: true,
        metrics: [
            // Each beside the line T5's page judges it by (formatBeside): 100 % throttles, under 99.99 % availability warns.
            { label: "Norm. RU peak", value: formatBeside(postgresPeak(ru)?.value ?? null, "percent", 100) },
            { label: "429s", value: formatNumber(throttled, "int") },
            { label: "Availability", value: availability.length > 0 ? formatBeside(Math.min(...availability), "percent", 99.99) : "\u2013" },
        ],
        note: `Captured ${formatAgo(capture.capturedAt)}${throttled > 0 ? (recovered ? "; throttled, then recovered" : "; throttled") : ""}`,
        spark: ru.map((p) => p.value),
        incidents: 0,
        attention: attention.length,
    };
}
