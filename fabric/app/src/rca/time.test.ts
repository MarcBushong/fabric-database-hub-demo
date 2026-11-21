import { describe, expect, it } from "vitest";
import { classOf } from "./errors";
import { resolveTime } from "./time";

// The review of 34a9732, its two Low findings in the investigations' inputs.
describe("times the viewer types", () => {
    it("puts an 'HH:MM UTC' time on the history's newest UTC day, though the viewer's own date is a day behind it", () => {
        // The newest bin at 02:00 UTC on 21 Nov is 21:00 on 20 Nov in New York, the day bare times are on.
        const newest = new Date("2026-11-21T02:00:00Z");
        const day = new Date("2026-11-20T00:00:00Z");
        expect(resolveTime("01:30 UTC", day, "America/New_York", newest)?.toISOString()).toBe("2026-11-21T01:30:00.000Z");
        // A bare time stays on the viewer's own day, in their time zone.
        expect(resolveTime("20:30", day, "America/New_York", newest)?.toISOString()).toBe("2026-11-21T01:30:00.000Z");
        // With no newest time, a UTC time falls back to the day.
        expect(resolveTime("01:30 UTC", day, "America/New_York")?.toISOString()).toBe("2026-11-20T01:30:00.000Z");
    });
});

describe("error classes", () => {
    it("gives SQLSTATE classes to PostgreSQL's errors only: on SQL Server, 40197 is an error number, not class 40", () => {
        const at = new Date("2026-11-20T17:00:00Z");
        const error = (target: "T3" | "T4" | "T4-replica", code: string) => classOf({ target, at, kind: "error", code, count: 1, detail: "" }).id;
        for (const code of ["40197", "40552", "40553"]) expect(error("T3", code), code).toBe("other");
        expect(error("T4", "42P01")).toBe("sqlstate-42");
        expect(error("T4-replica", "22012")).toBe("sqlstate-22");
    });
});
