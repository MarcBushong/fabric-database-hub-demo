import { describe, expect, it } from "vitest";

import type { Bin, Check, Incident } from "@/data/model";
import { areaRings, binMinutes, phaseOf, spotlightRows } from "./layout";

const at = (h: number, m = 0) => new Date(Date.UTC(2026, 9, 21, h, m));
const bin = (target: "T1" | "T3", h: number, m: number, waitS: number | null): Bin => ({
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
    sessions: null,
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
});
