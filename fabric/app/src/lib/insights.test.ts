import { describe, expect, it } from "vitest";

import type { Bin, Incident, PostgresCapture, PostgresPoint, TargetSummary, WaitFlow } from "@/data/model";
import {
    busiestHourInsight,
    compareIncident,
    coverageInsight,
    dominantWaitInsight,
    failedConnectionsInsight,
    freshnessInsight,
    incidentInsight,
    incidentPadMinutes,
    lagInsight,
    postgresCpuInsight,
    readinessInsight,
    replicaLagInsight,
} from "./insights";
import { mean, quantile, density } from "./stats";
import { statusBySort, statusClass, statusColor, statusMeta, worstStatus } from "./status";

const at = (h: number, m = 0) => new Date(Date.UTC(2026, 9, 21, h, m));
const bin = (h: number, m: number, bufferIoS: number, extra: Partial<Bin> = {}): Bin => ({
    at: at(h, m),
    target: "T3",
    cpu: null,
    blocked: null,
    lockWaitS: null,
    bufferIoS,
    logRateS: null,
    waitS: bufferIoS,
    ioMb: null,
    batch: null,
    sessions: null,
    ...extra,
});
const incident: Incident = {
    key: "detected:T3:io",
    label: "T3 IO pressure",
    source: "Detected signal",
    target: "T3",
    scenario: "",
    family: "io",
    start: at(10),
    end: at(11),
    durationMin: 60,
    peakValue: 90,
    peakUnit: "s",
    verdict: "",
};
const target = (key: "T1" | "T2" | "T3", patch: Partial<TargetSummary>): TargetSummary => ({
    key,
    name: key,
    platform: key,
    cpuAvg: null,
    cpuPeak: null,
    blockedPeak: null,
    lockWaitS: null,
    bufferIoS: null,
    logRateS: null,
    waitS: null,
    ioMb: null,
    batch: null,
    sessionsPeak: null,
    deadlocks: null,
    findingsAttention: 0,
    worstFindingSort: null,
    lagMin: null,
    coverageTables: null,
    coverageAgeMin: null,
    incidents: 0,
    bins: 0,
    ...patch,
});

describe("statuses", () => {
    it("knows the six ADR 0012 statuses and picks the worst", () => {
        expect(statusMeta("manual action required").short).toBe("Manual");
        expect(statusMeta("unknown").name).toBe("Not selected");
        expect(worstStatus(["Pass", "Warning", "Manual action required"])?.name).toBe("Manual action required");
        expect(worstStatus([])).toBeNull();
        expect(statusBySort(1)?.name).toBe("Fail");
        expect(statusBySort("1")).toBeNull();
        expect(statusClass(statusMeta("Pass"))).toBe("status-pass");
        expect(statusColor(statusMeta("Not supported"))).toBe("var(--status-muted)");
    });
});

describe("stats", () => {
    it("computes means, quantiles, and a peak-normalized density", () => {
        expect(mean([])).toBeNull();
        expect(mean([1, 2, 3])).toBe(2);
        expect(quantile([1, 2, 3, 4], 0.5)).toBe(2.5);
        expect(quantile([], 0.5)).toBeNull();
        const curve = density([1, 1, 2, 5], 0, 6, 32);
        expect(curve).toHaveLength(32);
        expect(Math.max(...curve.map(([, d]) => d))).toBeCloseTo(1, 6);
    });
});

describe("insights", () => {
    it("clamps the incident padding to 30 to 180 minutes", () => {
        expect(incidentPadMinutes({ durationMin: 20 })).toBe(30);
        expect(incidentPadMinutes({ durationMin: 120 })).toBe(60);
        expect(incidentPadMinutes({ durationMin: 420 })).toBe(180);
    });

    it("compares an incident's own signal with the padding before it", () => {
        const bins = [bin(9, 30, 10), bin(9, 45, 10), bin(10, 0, 40), bin(10, 15, 80), bin(11, 0, 5)];
        const c = compareIncident(incident, bins);
        expect(c.signal).toBe("Buffer IO (PAGEIOLATCH) waits");
        expect(c.baseline).toBe(10);
        expect(c.during).toBe(60);
        expect(c.ratio).toBe(6);
        expect(c.peak).toBe(80);
        expect(c.peakAt).toEqual(at(10, 15));
        const insight = incidentInsight(incident, c);
        expect(insight.metric).toBe("6.0×");
        expect(insight.status).toBe("Warning");
        expect(insight.incident).toBe(incident.key);
    });

    it("falls back to the incident's own peak without a baseline", () => {
        const insight = incidentInsight(incident, compareIncident(incident, [bin(10, 0, 40)]));
        expect(insight.status).toBeNull();
        expect(insight.title).toContain("lasted 1 h");
    });

    it("flags stale telemetry and passes fresh telemetry", () => {
        const stale = lagInsight([target("T1", { lagMin: 220.7 }), target("T3", { lagMin: 0.2 })]);
        expect(stale?.status).toBe("Warning");
        expect(stale?.title).toContain("T1 telemetry was up to 3 h 41 min old");
        expect(lagInsight([target("T3", { lagMin: 0.2 })])?.status).toBe("Pass");
        expect(lagInsight([target("T3", {})])).toBeNull();
    });

    it("flags targets that sent telemetry for only part of the period", () => {
        const thin = coverageInsight([target("T1", { bins: 4 }), target("T3", { bins: 96 })], ["T1", "T2", "T3"]);
        expect(thin?.status).toBe("Warning");
        expect(thin?.title).toContain("T1 and T2");
        expect(coverageInsight([target("T3", { bins: 96 })], ["T3"])?.status).toBe("Pass");
    });

    it("names the busiest target, its top wait, and the busiest hour", () => {
        const flows: WaitFlow[] = [
            { category: "CPU", target: "T3", seconds: 70 },
            { category: "Buffer IO (PAGEIOLATCH)", target: "T3", seconds: 20 },
            { category: "CPU", target: "T1", seconds: 10 },
        ];
        expect(dominantWaitInsight(flows)?.title).toBe("T3 carries 90 % of the estate's wait time; its biggest category is CPU.");
        expect(dominantWaitInsight([])).toBeNull();
        expect(busiestHourInsight([bin(9, 0, 5), bin(14, 0, 50), bin(14, 15, 50)])?.metric).toBe("14:00");
    });

    it("reports readiness with the worst status and the next step", () => {
        const insight = readinessInsight(
            { checks: 12, failed: 0, manual: 2, warnings: 2, passed: 7, notSupported: 1, notSelected: 0, readiness: 0.636, runLabel: "run" },
            [{ runId: "r", checkId: "hub-setting", area: "Fabric", target: "fabric", status: "Manual action required", statusSort: 2, message: "", remediation: "Turn it on.", docUrl: "", evaluationOnly: false, checkedAt: null }],
        );
        expect(insight?.status).toBe("Manual action required");
        expect(insight?.metric).toBe("64 %");
        expect(insight?.detail).toBe("Next step (hub-setting): Turn it on.");
    });

    it("asks for a notebook run when there is no snapshot, and warns when it's old", () => {
        const empty = { latestCapture: null, latestDay: null, earliestDay: null, hoursSince: null, freshness: "", notebookRuns: 0, scenarioRequests: 0, incidents: 0, hasBins: false };
        expect(freshnessInsight(empty)?.status).toBe("Manual action required");
        const old = freshnessInsight({ ...empty, latestCapture: at(0), notebookRuns: 1 }, new Date(Date.UTC(2026, 9, 23)));
        expect(old?.status).toBe("Warning");
        expect(old?.detail).toContain("Run NB_DatabaseHub_LiveActivity");
    });
});

describe("T4's insights (ADR 0025)", () => {
    const point = (target: PostgresPoint["target"], metric: string, minute: number, value: number): PostgresPoint => ({
        at: new Date(Date.UTC(2026, 10, 13, 17, minute)),
        target,
        server: target === "T4" ? "pgflex01-test01" : "pgreplica01-test01",
        metric,
        value,
    });
    const capture = (points: PostgresPoint[]): PostgresCapture => ({
        capturedAt: null,
        windowStart: null,
        windowEnd: null,
        intervalMinutes: 5,
        servers: Object.fromEntries(points.map((p) => [p.target, p.server])),
        points,
    });

    it("warns about Read replica lag at 60 s or more, and passes below it", () => {
        const lag = (peak: number) => capture([point("T4-replica", "physical_replication_delay_in_seconds", 0, 6), point("T4-replica", "physical_replication_delay_in_seconds", 5, peak)]);
        const high = replicaLagInsight(lag(241.4));
        expect(high?.status).toBe("Warning");
        expect(high?.title).toBe("Read replica lag peaked at 241 s at 17:05 UTC on 13 Nov.");
        expect(high?.detail).toBe("124 s on average over 2 intervals on pgreplica01-test01; 60 s or more is a warning.");
        expect(replicaLagInsight(lag(60))?.status).toBe("Warning");
        expect(replicaLagInsight(lag(59.9))?.status).toBe("Pass");
        expect(replicaLagInsight(null)).toBeNull();
    });

    it("says why a capture has no Read replica lag: the replica exists only during a session", () => {
        const insight = replicaLagInsight(capture([point("T4", "cpu_percent", 0, 40)]));
        expect(insight?.status).toBe("Not selected");
        expect(insight?.detail).toContain("exists only during a session");
    });

    it("warns about T4's CPU at 80 % or more, with its connections' peak", () => {
        const insight = postgresCpuInsight(capture([point("T4", "cpu_percent", 0, 43.3), point("T4", "cpu_percent", 5, 91.3), point("T4", "active_connections", 5, 34), point("T4-replica", "cpu_percent", 0, 99)]));
        expect(insight?.status).toBe("Warning");
        expect(insight?.title).toBe("T4's CPU peaked at 91.3 % at 17:05 UTC on 13 Nov.");
        expect(insight?.detail).toBe("67.3 % on average; active connections peaked at 34 at 17:05 UTC. 80 % or more is a warning.");
        expect(postgresCpuInsight(capture([point("T4", "cpu_percent", 0, 79.9)]))?.status).toBe("Pass");
        expect(postgresCpuInsight(capture([point("T4-replica", "cpu_percent", 0, 99)]))).toBeNull();
    });

    it("counts T4's failed connections: a warning above 0, a pass at 0", () => {
        const failed = failedConnectionsInsight(capture([point("T4", "connections_failed", 0, 0), point("T4", "connections_failed", 5, 3), point("T4", "connections_failed", 10, 1)]));
        expect(failed?.status).toBe("Warning");
        expect(failed?.metric).toBe("4");
        expect(failed?.title).toBe("4 failed connections on T4 in the latest capture.");
        expect(failed?.detail).toBe("At most 3 in one 5-minute interval, at 17:05 UTC on 13 Nov.");
        const none = failedConnectionsInsight(capture([point("T4", "connections_failed", 0, 0)]));
        expect(none?.status).toBe("Pass");
        expect(none?.title).toBe("No failed connections on T4 in the latest capture.");
        expect(failedConnectionsInsight(null)).toBeNull();
    });
});
