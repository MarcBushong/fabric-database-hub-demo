import { describe, expect, it } from "vitest";
import type { Bin } from "@/data/model";
import { describeEpisode, detect, episodesFromBins, findEpisodes, levelOf, RULES, type Sample } from "./detector";
import { answerKeyOf, fixtureEvidence, namesAScenario } from "./testdata/contract";
import { emptyEvidence } from "./types";

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

    it("finds no error burst in T1's 6 lock timeouts a minute: that's under the 10 a minute that makes one", () => {
        expect(findEpisodes({ evidence: fixtureEvidence("t1") }, at("16:50:00"), at("17:05:00")).filter((e) => e.family === "errors")).toEqual([]);
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
