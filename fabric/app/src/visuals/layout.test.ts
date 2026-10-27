import { describe, expect, it } from "vitest";

import type { Bin, Check, Incident, TargetSummary } from "@/data/model";
import { STATUSES } from "@/lib/status";
import { areaRings, binMinutes, clockCells, constellationSummary, dialSegments, familiesOf, foldFlows, phaseOf, ridges, spotlightRows } from "./layout";

const at = (h: number, m = 0) => new Date(Date.UTC(2026, 9, 21, h, m));
const bin = (target: "T1" | "T3", h: number, m: number, waitS: number | null, sessions: number | null = null): Bin => ({
    at: at(h, m),
    target,
    cpu: null,
    blocked: null,
    lockWaitS: null,
    bufferIoS: null,
    logRateS: null,
    waitS,
    ioMb: null,
    batch: null,
    sessions,
});
const check = (runId: string, checkId: string, area: string, status: string, statusSort: number): Check => ({
    runId,
    checkId,
    area,
    target: "fabric",
    status,
    statusSort,
    message: "",
    remediation: "",
    docUrl: "",
    evaluationOnly: false,
    checkedAt: null,
});

describe("visual layouts", () => {
    it("folds bins into 24 UTC hours per target, summing or taking the peak", () => {
        const bins = [bin("T3", 14, 0, 10, 3), bin("T3", 14, 15, 5, 7), bin("T1", 2, 0, null, 1)];
        const waits = clockCells(bins, "waits", ["T1", "T3"]);
        expect(waits).toHaveLength(48);
        expect(waits.find((c) => c.target === "T3" && c.hour === 14)).toMatchObject({ value: 15, bins: 2 });
        expect(waits.find((c) => c.target === "T1" && c.hour === 2)).toMatchObject({ value: 0, bins: 0 });
        expect(clockCells(bins, "sessions", ["T3"]).find((c) => c.hour === 14)?.value).toBe(7);
    });

    it("splits the dial into status arcs that fill the sweep", () => {
        const counts = STATUSES.map((meta) => ({ meta, count: meta.name === "Pass" ? 7 : meta.name === "Warning" ? 2 : meta.name === "Fail" ? 0 : 1 }));
        const segments = dialSegments(counts, -1, 3);
        expect(segments.map((s) => s.meta.name)).not.toContain("Fail");
        expect(segments[0].startAngle).toBe(-1);
        expect(segments[segments.length - 1].endAngle).toBeCloseTo(2, 10);
        for (let i = 1; i < segments.length; i++) expect(segments[i].startAngle).toBe(segments[i - 1].endAngle);
    });

    it("groups the latest run's checks by area with earlier runs as history", () => {
        const { latestRun, runs, areas } = areaRings([
            check("20261021T172517Z", "a", "Fabric", "Pass", 4),
            check("20261021T172517Z", "b", "Fabric", "Warning", 3),
            check("20261021T172517Z", "c", "Azure", "Pass", 4),
            check("20261020T090000Z", "a", "Fabric", "Fail", 1),
        ]);
        expect(latestRun).toBe("20261021T172517Z");
        expect(runs).toHaveLength(2);
        expect(areas.map((a) => a.area)).toEqual(["Azure", "Fabric"]);
        expect(areas[1].checks.map((c) => c.checkId)).toEqual(["b", "a"]);
        expect(areas[1].worst?.name).toBe("Warning");
        expect(areas[1].history[0].worst?.name).toBe("Fail");
    });

    it("finds the bin size and the replay phase", () => {
        expect(binMinutes([bin("T3", 1, 0, 1), bin("T3", 1, 15, 1), bin("T3", 1, 30, 1)])).toBe(15);
        expect(binMinutes([])).toBe(15);
        const incident = { start: at(10), end: at(11) } as Incident;
        expect(phaseOf(incident, at(9, 45))).toBe("before");
        expect(phaseOf(incident, at(10, 0))).toBe("during");
        expect(phaseOf(incident, at(11, 0))).toBe("after");
    });

    it("averages waits per bin before and during an incident", () => {
        const incident = { start: at(10), end: at(11) } as Incident;
        const rows = spotlightRows(
            incident,
            [
                { at: at(9, 30), category: "CPU", seconds: 4 },
                { at: at(9, 45), category: "CPU", seconds: 6 },
                { at: at(10, 0), category: "CPU", seconds: 30 },
                { at: at(10, 0), category: "Buffer IO (PAGEIOLATCH)", seconds: 50 },
                { at: at(8, 0), category: "CPU", seconds: 999 },
            ],
            30,
        );
        expect(rows[0]).toEqual({ category: "Buffer IO (PAGEIOLATCH)", before: 0, during: 50 });
        expect(rows[1]).toEqual({ category: "CPU", before: 5, during: 30 });
    });

    it("folds categories under 1 % into Other categories", () => {
        const folded = foldFlows([
            { category: "CPU", target: "T3", seconds: 990 },
            { category: "Network IO", target: "T3", seconds: 5 },
            { category: "Memory", target: "T3", seconds: 5 },
        ]);
        expect(folded).toEqual([
            { category: "CPU", target: "T3", seconds: 990 },
            { category: "Other categories", target: "T3", seconds: 10 },
        ]);
        expect(familiesOf(folded)).toEqual(["CPU and scheduling", "Other"]);
    });

    it("builds ridges with median and p95 per target", () => {
        const data = ridges([bin("T3", 1, 0, 1), bin("T3", 1, 15, 3), bin("T1", 1, 0, null)], "waits", ["T1", "T3"]);
        expect(data[0]).toEqual({ target: "T1", values: [], median: null, p95: null });
        expect(data[1].median).toBe(2);
    });

    it("summarizes the constellation for screen readers", () => {
        expect(constellationSummary([])).toBe("No target sent telemetry in this period.");
        const t = { key: "T3", worstFindingSort: null, waitS: 12, cpuPeak: 97.5, lagMin: 0.2 } as TargetSummary;
        expect(constellationSummary([t])).toBe("T3: no findings, 12.0 s of waits, CPU peak 97.5 %, telemetry lag 0.2 min");
    });
});
