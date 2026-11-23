import { describe, expect, it } from "vitest";
import { COSMOS_METRICS, POSTGRES_METRICS, type Bin, type PostgresCapture } from "@/data/model";
import { describeEpisode, detect, episodesFromBins, findEpisodes, levelOf, RULES, type Sample } from "./detector";
import { monitorTelemetry } from "./sources";
import { answerKeyOf, fixtureEvidence, namesAScenario } from "./testdata/contract";
import { emptyEvidence, pointKey } from "./types";

const MIN = 60_000;
const BASE = Date.parse("2026-11-20T13:30:00Z");
const m = (minute: number) => new Date(BASE + minute * MIN);
const at = (hms: string) => new Date(`2026-11-20T${hms}Z`);

/** T3's telemetry bins, one a minute for 56 minutes, with CPU from the function (null: the bin has no value). */
function cpuBins(cpu: (minute: number) => number | null): Bin[] {
    return Array.from({ length: 56 }, (_, i) => ({ at: m(i), target: "T3", cpu: cpu(i), blocked: 0, lockWaitS: 0, bufferIoS: 0, logRateS: 0, waitS: 0, ioMb: 0, batch: 0, sessions: 0 }));
}
const cpuOf = (bins: Bin[]) => episodesFromBins(bins).filter((e) => e.family === "cpu");

describe("the blind detector's rule", () => {
    it("finds the regression Wave 1 missed on dbhubfn's session 81446b84: bins at 65.95 % with empty bins between them", () => {
        // As found live: a baseline near 0 % (a level of 10 %), 65.95 % every third minute, and no value in the bins between.
        const [episode, ...rest] = cpuOf(cpuBins((i) => (i >= 30 && i < 40 ? (i % 3 === 0 ? 65.95 : null) : 0)));
        expect(rest).toEqual([]);
        expect(episode).toMatchObject({ target: "T3", family: "cpu", level: 10, baseline: 0, peak: 65.95, atLevel: 4, unknown: 6, valued: 4, support: "sparse", confidence: "medium" });
        expect(episode.start).toEqual(m(30));
        expect(episode.peakAt).toEqual(m(30));
        expect(episode.last).toEqual(m(39));
        expect(episode.end).toEqual(m(40));
        expect(describeEpisode(episode)).toBe("T3: CPU over 10 % from 14:00:00 to 14:10:00 UTC, peak 66 % at 14:00:00 UTC, in 4 samples, 6 of the samples between them without a value (Database Hub's telemetry).");
    });

    it("opens a single-sample episode on one bin far over its level, at low confidence, and none on one just over it", () => {
        const [spike] = cpuOf(cpuBins((i) => (i === 33 ? 66 : 0)));
        expect(spike).toMatchObject({ support: "single sample", confidence: "low", atLevel: 1, peak: 66 });
        expect(spike.end).toEqual(m(34));
        expect(cpuOf(cpuBins((i) => (i === 33 ? 12 : 0)))).toEqual([]);
    });

    // The review of c4c63abe: a rule that opens on one sample (the replica's lag, connections, 429s, RU) said "far over its
    // level" of any one sample, as of B's 34 s against its 30 s level.
    it("says a single sample was far over its level only when that's what opened its episode", () => {
        const [spike] = cpuOf(cpuBins((i) => (i === 33 ? 66 : 0)));
        expect(describeEpisode(spike)).toContain("in one sample, far over its level: low confidence");
        const lag: Sample[] = Array.from({ length: 40 }, (_, i) => ({ at: m(i), value: i === 35 ? 34 : 0.5 }));
        const [one] = detect("T4-replica", lag, MIN, RULES.replica_lag, "Azure Monitor");
        expect(one).toMatchObject({ support: "single sample", level: 30, peak: 34 });
        expect(describeEpisode(one)).toBe("T4-replica: read replica lag over 30 s from 14:05:00 to 14:06:00 UTC, peak 34 s at 14:05:00 UTC, in one sample: low confidence (Azure Monitor).");
    });

    it("needs two samples at the level for a gauge, across at most two unknown samples, and never counts an unknown sample as under", () => {
        // 15 % is over the 10 % level but not twice it: it needs a second sample in the same run.
        expect(cpuOf(cpuBins((i) => (i === 30 || i === 33 ? 15 : i > 30 && i < 33 ? null : 0)))).toHaveLength(1);
        // Three unknown samples between them break the run.
        expect(cpuOf(cpuBins((i) => (i === 30 || i === 34 ? 15 : i > 30 && i < 34 ? null : 0)))).toEqual([]);
        // A valued sample under the level between them breaks it too, before the episode opened.
        expect(cpuOf(cpuBins((i) => (i === 30 || i === 32 ? 15 : 0)))).toEqual([]);
    });

    it("reads a dense run as sustained, and leaves its end unknown when the data ends first", () => {
        const [dense] = cpuOf(cpuBins((i) => (i >= 20 && i < 28 ? 90 : 5)));
        expect(dense).toMatchObject({ support: "sustained", confidence: "high", atLevel: 8, unknown: 0 });
        expect(dense.end).toEqual(m(28));
        const [open] = cpuOf(cpuBins((i) => (i >= 50 ? 90 : 5)));
        expect(open.end).toBeNull();
        expect(describeEpisode(open)).toContain("its end isn't known");
    });

    it("sets the level from a blind baseline: the minutes before, never a planned window", () => {
        expect(levelOf(RULES.cpu, null)).toBe(80);
        expect(levelOf(RULES.cpu, 0)).toBe(10);
        expect(levelOf(RULES.cpu, 20)).toBe(30);
        expect(levelOf(RULES.cpu, 60)).toBe(80);
        expect(levelOf(RULES.io, 4)).toBe(6);
        const [e] = cpuOf(cpuBins((i) => (i >= 40 && i < 44 ? 35 : 20)));
        expect(e).toMatchObject({ baseline: 20, level: 30 });
    });

    it("ends an episode only after two valued samples back under, so one quiet sample doesn't split it", () => {
        const series: Sample[] = [0, 0, 0, 0, 0, 3, 0, 3, 3, 0, 0, 0].map((value, i) => ({ at: m(i), value }));
        const episodes = detect("T1", series, MIN, RULES.blocking, "test");
        expect(episodes.map((e) => [e.start, e.end])).toEqual([[m(5), m(9)]]);
        // The review of 803f2b1a: with its dip, it wasn't "3 samples in a row", and neither was T3's CPU at 95, 96, 60, 97 %.
        expect(describeEpisode(episodes[0])).toContain("in 3 of its 4 samples");
        const [dip] = cpuOf(cpuBins((i) => [95, 96, 60, 97][i - 40] ?? 60));
        expect(describeEpisode(dip)).toContain("in 3 of its 4 samples (Database Hub's telemetry)");
    });
});

describe("the blind detector on the contract's fixtures", () => {
    it("takes the observer's own episodes for T1's chain, T4's chain, and the replica's stall, measured from its samples", () => {
        const episodes = findEpisodes({ evidence: fixtureEvidence("t1", "t4") }, at("16:50:00"), at("17:20:00"));
        const view = episodes.map((e) => [e.target, e.family, e.start.toISOString().slice(11, 19), e.end?.toISOString().slice(11, 19), e.peak, e.source]);
        expect(view).toEqual([
            ["T1", "blocking", "16:52:30", "17:01:40", 7, "the RCA capture"],
            ["T4", "blocking", "17:02:30", "17:12:20", 3, "the RCA capture"],
            ["T4-replica", "replica_lag", "17:12:00", "17:14:25", 175.4, "the RCA capture"],
        ]);
        expect(episodes.every((e) => e.support === "sustained")).toBe(true);
        expect(episodes.find((e) => e.family === "replica_lag")?.peakAt).toEqual(at("17:14:10"));
    });

    // The review of 803f2b1a: Azure Monitor's one point for 17:10, a day-long save's 15 minutes, holds the capture's own
    // stall from 17:12, so the stall is listed once, as the capture's. Read at the capture's 1 minute, the point ended at
    // 17:10, before the stall, and the list had it twice.
    it("lists a stall once when one Azure Monitor point's interval holds the capture's own episode of it", () => {
        const point = (time: string, value: number) => ({ at: at(time), target: "T4-replica" as const, server: "", metric: POSTGRES_METRICS.lag, value });
        const postgres: PostgresCapture = { capturedAt: at("18:00:00"), windowStart: at("16:00:00"), windowEnd: at("18:00:00"), intervalMinutes: 1, servers: {}, points: [point("16:55:00", 1), point("17:10:00", 175)] };
        const intervals = new Map([["16:55:00", 15], ["17:10:00", 15]].map(([time, minutes]) => [pointKey("T4-replica", POSTGRES_METRICS.lag, at(time as string)), (minutes as number) * 60_000]));
        const lag = (withIntervals: boolean) =>
            findEpisodes({ evidence: fixtureEvidence("t4"), postgres, intervals: withIntervals ? intervals : undefined }, at("16:50:00"), at("17:30:00"))
                .filter((e) => e.family === "replica_lag")
                .map((e) => e.source)
                .sort();
        expect(lag(true)).toEqual(["the RCA capture"]);
        expect(lag(false)).toEqual(["Azure Monitor", "the RCA capture"]);
    });

    it("finds no error burst in T1's 6 lock timeouts a minute: that's under the 10 a minute that makes one", () => {
        expect(findEpisodes({ evidence: fixtureEvidence("t1") }, at("16:50:00"), at("17:05:00")).filter((e) => e.family === "errors")).toEqual([]);
    });

    // The real PostgreSQL run (2026-11-20): one deadlock, seen as an event and as a one-sample capture between the counter's samples.
    it("keeps one deadlock episode, with its count, when the capture's escalation and the event see the same deadlock", () => {
        const evidence = emptyEvidence();
        const t = at("22:30:00");
        evidence.events.push(
            { target: "T4", at: t, kind: "deadlock", name: "pg_stat_database.deadlocks", count: 1, detail: "1 deadlock(s) in contosocare (pg_stat_database.deadlocks)." },
            { target: "T4", at: t, kind: "capture", name: "escalated", code: "T4-20261120T223000Z", count: 1, detail: "deadlocks rose by 1 (RCA-PG-03): one blocking sample (RCA-PG-01, RCA-PG-02)." },
            { target: "T4", at: t, kind: "capture", name: "relaxed", code: "T4-20261120T223000Z", count: 1, detail: "One sample taken: back to the 30-s sentinel." },
        );
        const deadlocks = findEpisodes({ evidence }, at("22:25:00"), at("22:35:00")).filter((e) => e.family === "deadlock");
        expect(deadlocks).toHaveLength(1);
        expect(deadlocks[0].peak).toBe(1);
    });

    // The review of 34a9732: a SQL Server deadlock shows as its graph and as its victim's 1205, and both were counted.
    it("counts a SQL Server deadlock once, by its graph, never again by its victim's error", () => {
        const evidence = emptyEvidence();
        const t = at("16:55:00");
        evidence.events.push(
            { target: "T1", at: t, kind: "deadlock", name: "xml_deadlock_report", count: 1, detail: "A deadlock graph." },
            { target: "T1", at: t, kind: "error", name: "error_reported", code: "1205", count: 1, detail: "Transaction was deadlocked: chosen as the victim." },
        );
        const deadlocks = findEpisodes({ evidence }, at("16:50:00"), at("17:00:00")).filter((e) => e.family === "deadlock");
        expect(deadlocks).toHaveLength(1);
        expect(deadlocks[0].peak).toBe(1);
        // Without a graph, the victim's error stands for the deadlock.
        const errorsOnly = emptyEvidence();
        errorsOnly.events.push({ target: "T3", at: t, kind: "error", name: "error_reported", code: "1205", count: 1, detail: "Transaction was deadlocked." });
        expect(findEpisodes({ evidence: errorsOnly }, at("16:50:00"), at("17:00:00")).filter((e) => e.family === "deadlock").map((e) => e.peak)).toEqual([1]);
    });

    // The review of 34a9732: a capture anywhere in the window hid Database Hub's episodes everywhere in it.
    it("keeps Database Hub's blocking episodes outside the minutes the observer captured", () => {
        const evidence = emptyEvidence();
        evidence.coverage.push({ target: "T1", from: at("14:00:00"), to: at("14:10:00"), captured: true, sources: ["RCA-SQL-01"], gaps: [] });
        // T1's bins, a minute apart from 13:30: blocked at 14:03 to 14:07, inside the capture, and at 14:40 to 14:44, outside it.
        const bins: Bin[] = Array.from({ length: 90 }, (_, i) => ({ at: m(i), target: "T1", cpu: 5, blocked: (i >= 33 && i < 38) || (i >= 70 && i < 75) ? 3 : 0, lockWaitS: 0, bufferIoS: 0, logRateS: 0, waitS: 0, ioMb: 0, batch: 0, sessions: 0 }));
        expect(episodesFromBins(bins).filter((e) => e.family === "blocking")).toHaveLength(2);
        const blocking = findEpisodes({ evidence, bins }, at("13:30:00"), at("15:00:00")).filter((e) => e.family === "blocking");
        expect(blocking.map((e) => e.start.toISOString().slice(11, 16))).toEqual(["14:40"]);
    });

    it("prefers T3's 15-second resource rows to Database Hub's bins for its CPU", () => {
        const evidence = emptyEvidence();
        for (let s = 0; s < 40 * 4; s++) {
            const time = new Date(Date.parse("2026-11-20T16:40:00Z") + s * 15_000);
            const minute = s / 4;
            evidence.resource.push({ target: "T3", at: time, source: "RCA-AZ-01", metric: "avg_cpu_percent", value: minute >= 16 && minute < 37 ? 100 : 1, unit: "percent" });
        }
        // Database Hub's bins see the same regression (they'd open an episode of their own), but the denser rows win.
        const bins = cpuBins((i) => (i >= 26 && i < 47 ? 95 : 1)).map((b) => ({ ...b, at: new Date(b.at.getTime() + 3 * 60 * MIN) }));
        expect(episodesFromBins(bins).filter((e) => e.family === "cpu")).toHaveLength(1);
        const cpu = findEpisodes({ evidence, bins }, at("16:40:00"), at("17:30:00")).filter((e) => e.target === "T3" && e.family === "cpu");
        expect(cpu).toHaveLength(1);
        expect(cpu[0]).toMatchObject({ source: "the RCA capture", support: "sustained", peak: 100 });
        expect(cpu[0].start).toEqual(at("16:56:00"));
        expect(cpu[0].end).toEqual(at("17:17:00"));
    });

    it("stays blind, and its episodes are the ones the answer key says ran (graded here, never in the product)", () => {
        const episodes = findEpisodes({ evidence: fixtureEvidence("t1", "t4") }, at("16:50:00"), at("17:20:00"));
        expect(namesAScenario(JSON.stringify(episodes))).toEqual([]);
        const runs = [...answerKeyOf("t1"), ...answerKeyOf("t4")].filter((r) => r.kind === "run");
        // Each episode overlaps a run on its target; T1's second run is log flushes, Phase 2's waits, which nothing here reads.
        for (const e of episodes) {
            const target = e.target === "T4-replica" ? "T4" : e.target;
            expect(runs.some((r) => r.target === target && r.at <= (e.end ?? e.last) && (r.end ?? r.at) >= e.start)).toBe(true);
        }
    });
});

// The review of 97fdf5ba: RCA Events are read up to a window's end, so an episode that relaxed after it read as one its
// capture had cut off, with a fall and the capture's end.
describe("a capture episode with no relaxed event in the minutes read", () => {
    const surge = (coverageTo: string | null, totals: (s: number) => number = (s) => (s < 30 ? 30 : 10), until = 110) => {
        const evidence = emptyEvidence();
        evidence.events.push({ target: "T4", at: at("15:00:00"), kind: "capture", name: "escalated", code: "T4-20261120T150000Z", count: 1, detail: "client connections 30 >= 80 % of 35 (max_connections 50 minus 15 reserved)." });
        // 30 of 35 three times, then 10, every 10 s to 15:01:50 (or the totals given).
        for (let s = 0; s <= until; s += 10) {
            const time = new Date(at("15:00:00").getTime() + s * 1000);
            for (const [metric, value] of [["connections_total", totals(s)], ["max_connections", 50], ["reserved_connections", 15]] as const) evidence.resource.push({ target: "T4", at: time, source: "RCA-PG-10", metric, value });
        }
        if (coverageTo) evidence.coverage.push({ target: "T4", from: at("14:30:00"), to: at(coverageTo), captured: true, sources: ["RCA-PG-10"], gaps: [] });
        return evidence;
    };
    const read = (coverageTo: string | null, to: string, totals?: (s: number) => number) => findEpisodes({ evidence: surge(coverageTo, totals) }, at("14:55:00"), at(to)).filter((e) => e.family === "connections");

    it("says where it fell, and that the minutes read end before its capture confirmed the end, while its capture ran on", () => {
        const [e] = read("15:30:00", "15:02:00");
        expect(e.readEnd).toEqual(at("15:02:00"));
        expect(e.captureEnd).toBeUndefined();
        // The review of 858c50c2: its samples had fallen to 10 of 35, so it wasn't "still on".
        expect(describeEpisode(e)).toContain("from 15:00:00 UTC, under its level by 15:00:30 UTC (the minutes read end at 15:02:00 UTC, before its capture confirmed the end)");
        // Still on only when its last sample read was at its level.
        const [on] = read("15:30:00", "15:02:00", () => 30);
        expect(describeEpisode(on)).toContain("from 15:00:00 UTC (still on at 15:02:00 UTC, where the minutes read end)");
        // Without coverage, while its samples run to where the minutes read end.
        const [open] = read(null, "15:02:00");
        expect(open.readEnd).toEqual(at("15:02:00"));
    });

    it("says its capture cut it off when its coverage ends in the minutes read, or without coverage its samples do", () => {
        const [byCoverage] = read("15:01:55", "15:10:00");
        expect(byCoverage.readEnd).toBeUndefined();
        expect(describeEpisode(byCoverage)).toContain("from 15:00:00 UTC, under its level by 15:00:30 UTC (the capture ended at 15:01:50 UTC, before it could confirm the end)");
        const [bySamples] = read(null, "15:10:00");
        expect(bySamples.readEnd).toBeUndefined();
        expect(describeEpisode(bySamples)).toContain("under its level by 15:00:30 UTC");
    });

    // The review of eb89acbb: with RCA Events read only to 15:01:00, a surge read "the minutes read end at 15:20:00".
    it("ends the minutes read where a read of the capture's tables stopped short, not where the window ends", () => {
        const stopped = (totals: ((s: number) => number) | undefined, table = "RCA Events") => findEpisodes({ evidence: { ...surge("15:30:00", totals), cut: [{ table, until: at("15:01:00") }] } }, at("14:55:00"), at("15:20:00")).filter((e) => e.family === "connections");
        const [on] = stopped(() => 30);
        expect(on).toMatchObject({ readEnd: at("15:01:00"), readStopped: true });
        expect(describeEpisode(on)).toContain("from 15:00:00 UTC (still on at 15:01:00 UTC, where the read stopped)");
        const [fell] = stopped(undefined);
        expect(describeEpisode(fell)).toContain("from 15:00:00 UTC, under its level by 15:00:30 UTC (the read stopped at 15:01:00 UTC, before its capture confirmed the end)");
        // A read of the telemetry that stopped short isn't one of the capture's tables.
        const [telemetry] = stopped(() => 30, "Telemetry Snapshots (Azure Monitor)");
        expect(describeEpisode(telemetry)).toContain("(still on at 15:20:00 UTC, where the minutes read end)");
    });

    // The review of 4667459c: RCA Resource read whole beside RCA Events read to 15:00:30, with a surge on until 15:10, gave
    // one answer both "under its level by 15:10:00 UTC (the read stopped at 15:00:30 ...) ... in 60 of its 120 samples" and
    // "still on at 15:00:30, where the read stopped".
    it("reads a capture episode's own samples only up to where a read of the capture's tables stopped", () => {
        const evidence = { ...surge("15:30:00", (s) => (s < 600 ? 30 : 10), 700), cut: [{ table: "RCA Events", until: at("15:00:30") }] };
        const [e] = findEpisodes({ evidence }, at("14:55:00"), at("15:20:00")).filter((x) => x.family === "connections");
        expect(e).toMatchObject({ readEnd: at("15:00:30"), readStopped: true, valued: 4, atLevel: 4 });
        expect(e.fellBy).toBeUndefined();
        expect(describeEpisode(e)).toContain("from 15:00:00 UTC (still on at 15:00:30 UTC, where the read stopped), peak 85.7 % at 15:00:00 UTC, in 4 samples in a row");
    });

    // The review of 11b7c4b9: an episode its capture ended keeps every sample, whatever another table's read stopped at (a
    // surge to 35 of 35 at 15:05, ended at 15:10:40, read "peak 85.7 % at 15:00:00 ... in 4 samples in a row").
    it("keeps every sample of an episode its capture ended, whatever another table's read stopped at", () => {
        const evidence = surge("15:30:00", (s) => (s === 300 ? 35 : s < 640 ? 30 : 10), 640);
        evidence.events.push({ target: "T4", at: at("15:10:40"), kind: "capture", name: "relaxed", code: "T4-20261120T150000Z", count: 1, detail: "client connections 10 < 80 % of 35 for 30 s." });
        const [e] = findEpisodes({ evidence: { ...evidence, cut: [{ table: "RCA Sessions", until: at("15:00:30") }] } }, at("14:55:00"), at("15:20:00")).filter((x) => x.family === "connections");
        expect(e).toMatchObject({ end: at("15:10:40"), peak: 100, valued: 65, atLevel: 64 });
        expect(e.readStopped).toBeUndefined();
        expect(describeEpisode(e)).toContain("peak 100 % at 15:05:00 UTC, in 64 of its 65 samples");
    });

    // The capture's own error and deadlock episodes have no samples of their own: neither a fall nor "still on" can be told.
    it("says whether an episode with no samples of its own was still on isn't known", () => {
        const evidence = emptyEvidence();
        evidence.events.push({ target: "T1", at: at("16:55:00"), kind: "capture", name: "escalated", code: "T1-20261120T165500Z", count: 1, detail: "errors 12 in the minute from 16:54 UTC >= 10 and 3 times the median (0) of the minutes before: one blocking sample (RCA-SQL-01)." });
        evidence.coverage.push({ target: "T1", from: at("16:30:00"), to: at("16:56:00"), captured: true, sources: ["RCA-SQL-01"], gaps: [] });
        const [cut] = findEpisodes({ evidence }, at("16:50:00"), at("17:10:00")).filter((e) => e.family === "errors");
        expect(describeEpisode(cut)).toContain("from 16:55:00 UTC (the capture ended before it recorded an end, and whether it was still on isn't known)");
        evidence.coverage[0].to = at("17:30:00");
        const [open] = findEpisodes({ evidence }, at("16:50:00"), at("17:10:00")).filter((e) => e.family === "errors");
        expect(describeEpisode(open)).toContain("from 16:55:00 UTC (the capture hadn't recorded its end by 17:10:00 UTC, where the minutes read end)");
    });
});

// The shared finestPerInterval (a390db00): a coarser peak over two uncovered stretches of one interval is given to each,
// as upper bounds of one reading. It's one candidate, never two episodes.
describe("the pieces of one coarser peak", () => {
    it("open one episode, from the first piece, never a second from a later piece of the same reading", () => {
        const save = (capturedAt: string, from: string, to: string) => (bucket: string, value: number) => ({
            Bucket: `2026-11-20T${bucket}:00`,
            TargetKey: "T5",
            ResourceName: "cosmos01",
            Metric: COSMOS_METRICS.normalizedRu,
            Value: value,
            Unit: "Percent",
            CapturedAt: `2026-11-20T${capturedAt}:00`,
            WindowStart: `2026-11-20T${from}:00`,
            WindowEnd: `2026-11-20T${to}:00`,
        });
        const day = save("21:33", "00:00", "21:30");
        const session = save("17:09", "15:33", "15:38");
        const telemetry = monitorTelemetry([day("15:15", 11), day("15:30", 100), day("15:45", 40), ...[3, 5, 4, 4, 4].map((v, i) => session(`15:3${3 + i}`, v))]);
        expect([...(telemetry.upperBounds ?? [])].sort()).toEqual([pointKey("T5", COSMOS_METRICS.normalizedRu, at("15:30")), pointKey("T5", COSMOS_METRICS.normalizedRu, at("15:38"))].sort());
        const ru = findEpisodes({ evidence: emptyEvidence(), cosmos: telemetry.cosmos, intervals: telemetry.intervals, grains: telemetry.grains, sources: telemetry.sources, upperBounds: telemetry.upperBounds }, at("15:00"), at("16:00")).filter((e) => e.family === "ru");
        expect(ru.map((e) => e.key)).toEqual(["T5-ru-20261120T153000Z"]);
    });
});