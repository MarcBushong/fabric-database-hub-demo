import { describe, expect, it } from "vitest";

import { replicaCatchUp, withCategoryWaits, type Bin, type Incident, type PostgresCapture, type PostgresPoint, type TargetSummary, type WaitFlow } from "@/data/model";
import {
    busiestHourInsight,
    compareIncident,
    coverageInsight,
    dominantWaitInsight,
    failedConnectionsInsight,
    familySignal,
    freshnessInsight,
    incidentInsight,
    incidentPadMinutes,
    lagInsight,
    postgresCpuInsight,
    readinessInsight,
    replicaLagInsight,
    signalValue,
    timesShort,
    timesText,
    baselineText,
    waitFamilyInsight,
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

    it("never writes a ratio just under the 2× Warning as 2.0 (the review of 29a7cb4)", () => {
        const base = compareIncident(incident, [bin(9, 30, 10), bin(10, 0, 40)]);
        const under = incidentInsight(incident, { ...base, during: 19.6, ratio: 1.96 });
        expect(under.status).toBeNull();
        expect(under.metric).toBe("1.96×");
        expect(under.title).toContain("ran at 1.96 times their baseline");
        const at2 = incidentInsight(incident, { ...base, during: 20, ratio: 2 });
        expect(at2.status).toBe("Warning");
        expect(at2.metric).toBe("2.0×");
        expect(at2.title).toContain("ran at 2.0 times their baseline");
        expect([timesShort(1.999), timesShort(3.42), timesText(9.96), timesShort(35.3)]).toEqual(["1.999×", "3.4×", "10.0 times", "35×"]);
    });

    it("measures a wait family by its own category, as the detector does, not by all waits (dbhubc5, 2026-11-18)", () => {
        // T3's detected log flush waits: Tran Log IO at about 0.4 s a bin, then 15.8 to 20.4 s, while all the waits fell.
        const logFlush: Incident = { ...incident, key: "detected:T3:tran_log", family: "tran_log", start: at(1, 52), end: at(1, 57), durationMin: 5, peakValue: 20.417 };
        const tranLog = [...Array<number>(30).fill(0.4), 15.8, 20.4, 16.8, 7.3, 5.5];
        const bins = tranLog.map((_, i) => bin(1, 22 + i, 0, { bufferIoS: null, waitS: i < 30 ? 168 : 142 }));
        const waits = tranLog.map((seconds, i) => ({ at: bins[i].at, category: "Tran Log IO", seconds }));
        const own = compareIncident(logFlush, withCategoryWaits(bins, [...waits, { at: at(1, 22), category: "Preemptive", seconds: 9 }]));
        expect(own.signal).toBe("Tran Log IO (log flush) waits");
        expect(own.peak).toBe(20.4);
        expect(own.peakAt).toEqual(at(1, 53));
        expect(own.baseline).toBeCloseTo(0.4, 6);
        expect(own.ratio).toBeCloseTo(32.9, 1);
        // A bin with categories but no Tran Log IO row waited 0 seconds; without the waits query, it's all the waits.
        expect(signalValue(familySignal("tran_log"), { ...bins[0], waits: { Preemptive: 9 } })).toBe(0);
        expect(signalValue(familySignal("tran_log"), bins[0])).toBeNull();
        const all = compareIncident(logFlush, bins);
        expect(all.signal).toBe("wait time");
        expect(all.ratio).toBeCloseTo(142 / 168, 6);
        // dbhubc5's tempdb latch window: 33.9 s against a baseline of 0.02 s is "more than 100 times", not 1610.
        expect([timesShort(3.42), timesShort(35.3), timesShort(1610)]).toEqual(["3.4×", "35×", ">100×"]);
        expect(timesText(1610)).toBe("more than 100 times");
        expect(baselineText(0.02, "seconds")).toBe("baseline near zero");
        expect(baselineText(0.4, "seconds")).toBe("baseline 0.4 s per bin");
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

    it("never rounds a share to 100 % or 0 % when it isn't exactly that", () => {
        const dominant = dominantWaitInsight([
            { category: "CPU", target: "T3", seconds: 996 },
            { category: "CPU", target: "T1", seconds: 4 },
        ]);
        expect(dominant?.metric).toBe("more than 99 %");
        expect(dominant?.title).toBe("T3 carries more than 99 % of the estate's wait time; its biggest category is CPU.");
        const summary = { checks: 300, failed: 0, manual: 0, warnings: 299, passed: 1, notSupported: 0, notSelected: 0, readiness: 0.003, runLabel: "run" };
        expect(readinessInsight(summary, [])?.metric).toBe("less than 1 %");
        expect(readinessInsight({ ...summary, warnings: 1, passed: 299 }, [])?.metric).toBe("more than 99 %");
        expect(readinessInsight({ ...summary, warnings: 0, passed: 300 }, [])?.metric).toBe("100 %");
    });

    it("never writes the largest wait family's or the busiest hour's share as 100 % when it isn't (2026-11-21)", () => {
        // 99.6 % of all wait time, which a whole percent alone writes as 100 %.
        const family = waitFamilyInsight([
            { category: "CPU", target: "T3", seconds: 996 },
            { category: "Buffer IO (PAGEIOLATCH)", target: "T3", seconds: 4 },
        ]);
        expect(family?.metric).toBe("more than 99 %");
        expect(family?.title).toBe("CPU and scheduling is the largest wait family: more than 99 % of all wait time.");
        expect(busiestHourInsight([bin(9, 0, 4), bin(14, 0, 996)])?.detail).toBe("996 s in that hour across the window, more than 99 % of the total.");
        expect(busiestHourInsight([bin(14, 0, 50), bin(14, 15, 50)])?.detail).toBe("100 s in that hour across the window, 100 % of the total.");
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

    it("leaves the replica's catch-up after a restart out of the lag's peak, with the Nov 13 data (2026-11-16)", () => {
        // Live, 2026-11-13: the replica stopped at 00:38:46Z and started again at 00:57Z; Azure Monitor read 1,380 s at 01:00,
        // the time since its last replay, before the replica-lag beat's 219 s.
        const lagAt = (hour: number, minute: number, value: number): PostgresPoint => ({
            at: new Date(Date.UTC(2026, 10, 14, hour, minute)),
            target: "T4-replica",
            server: "pgreplica01-rrpigs",
            metric: "physical_replication_delay_in_seconds",
            value,
        });
        const nov13 = [lagAt(0, 20, 3), lagAt(0, 25, 2), lagAt(0, 30, 4), lagAt(0, 35, 5), lagAt(1, 0, 1380), lagAt(1, 5, 67), lagAt(1, 10, 218), lagAt(1, 15, 219), lagAt(1, 20, 3)];
        const window = (points: PostgresPoint[], hour = 0, minute = 0): PostgresCapture => ({ ...capture(points), windowStart: new Date(Date.UTC(2026, 10, 14, hour, minute)) });
        expect(replicaCatchUp(window(nov13), nov13).map((p) => p.value)).toEqual([1380]);
        const insight = replicaLagInsight(window(nov13));
        expect(insight?.status).toBe("Warning");
        expect(insight?.title).toBe("Read replica lag peaked at 219 s at 01:15 UTC on 14 Nov.");
        expect(insight?.detail).toContain("Left out: 1,380 s at 01:00 UTC, the replica's catch-up after its restart, not lag.");
        // Only the catch-up: a Pass that says so.
        const only = [lagAt(1, 0, 3900)];
        const onlyInsight = replicaLagInsight(window(only));
        expect(onlyInsight?.status).toBe("Pass");
        expect(onlyInsight?.title).toBe("The latest capture's Read replica lag is only the replica's catch-up after its restart.");
        // A fresh replica's small first points, and a beat's 300 s right after a short gap, are lag.
        const fresh = [lagAt(0, 30, 0.4), lagAt(0, 35, 1), lagAt(0, 40, 120), lagAt(0, 45, 2), lagAt(1, 5, 300), lagAt(1, 10, 2)];
        expect(replicaCatchUp(window(fresh), fresh)).toEqual([]);
        expect(replicaLagInsight(window(fresh))?.title).toBe("Read replica lag peaked at 300 s at 01:05 UTC on 14 Nov.");
    });

    it("warns about T4's CPU at 80 % or more, with its connections' peak", () => {
        const insight = postgresCpuInsight(capture([point("T4", "cpu_percent", 0, 43.3), point("T4", "cpu_percent", 5, 91.3), point("T4", "active_connections", 5, 34), point("T4-replica", "cpu_percent", 0, 99)]));
        expect(insight?.status).toBe("Warning");
        expect(insight?.title).toBe("T4's CPU peaked at 91.3 % at 17:05 UTC on 13 Nov.");
        expect(insight?.detail).toBe("67.3 % on average; active connections peaked at 34 at 17:05 UTC. 80 % or more is a warning.");
        expect(postgresCpuInsight(capture([point("T4", "cpu_percent", 0, 79.9)]))?.status).toBe("Pass");
        expect(postgresCpuInsight(capture([point("T4-replica", "cpu_percent", 0, 99)]))).toBeNull();
    });

    it("never writes a peak just under its warning line as the line, beside a Pass (2026-11-21)", () => {
        // One decimal alone writes 79.996 % as 80.0 %, and 59.96 s as 60.0 s: the lines where they'd warn.
        const cpu = postgresCpuInsight(capture([point("T4", "cpu_percent", 0, 20), point("T4", "cpu_percent", 5, 79.996)]));
        expect(cpu?.status).toBe("Pass");
        expect(cpu?.metric).toBe("79.996 %");
        expect(cpu?.title).toBe("T4's CPU peaked at 79.996 % at 17:05 UTC on 13 Nov.");
        expect(postgresCpuInsight(capture([point("T4", "cpu_percent", 0, 80)]))?.metric).toBe("80.0 %");
        const lag = replicaLagInsight(capture([point("T4-replica", "physical_replication_delay_in_seconds", 0, 6), point("T4-replica", "physical_replication_delay_in_seconds", 5, 59.96)]));
        expect(lag?.status).toBe("Pass");
        expect(lag?.metric).toBe("59.96 s");
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
