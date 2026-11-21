import { describe, expect, it } from "vitest";
import { findIncidentsAsk, triageAsk } from "./entry";
import { classOf } from "./errors";
import { loadEvidence } from "./loader";
import { resolveTime } from "./time";
import { createInvestigationTools } from "./tools";

const iso = (d: Date | null) => d?.toISOString() ?? null;

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

    // The re-review of 817b81c: the entry points wrote "2026-11-17 13:30 UTC", which the tools refused.
    it("takes a date and time as written, whatever the newest data", () => {
        const newest = new Date("2026-11-20T17:20:00Z");
        const day = new Date("2026-11-20T00:00:00Z");
        for (const text of ["2026-11-17T13:30:00Z", "2026-11-17T13:30:00.000Z", "2026-11-17T13:30Z", "2026-11-17 13:30 UTC", "2026-11-17 13:30:00 utc", "2026-11-17T14:30:00+01:00", "2026-11-17T08:30:00-0500", "2026-11-17 08:30"]) {
            expect(iso(resolveTime(text, day, "America/New_York", newest)), text).toBe("2026-11-17T13:30:00.000Z");
        }
        for (const text of ["2026-02-30 10:00 UTC", "2026-11-17 24:00 UTC", "2026-13-01T10:00:00Z", "2026-11-17"]) expect(resolveTime(text, day, "UTC", newest), text).toBeNull();
    });

    // The re-review of 817b81c: with the newest bin at 00:40 UTC on 21 Nov, "23:15 UTC" resolved to 23:15 that day, 22.5 hours later.
    it("reads a clock time as the latest such time up to the newest data, across midnight either way", () => {
        const newest = new Date("2026-11-21T00:40:00Z");
        expect(iso(resolveTime("23:15 UTC", new Date("2026-11-20T00:00:00Z"), "America/New_York", newest))).toBe("2026-11-20T23:15:00.000Z");
        // Up to an hour past the newest data stays on its day: the capture can run past the newest bin.
        expect(iso(resolveTime("01:20 UTC", new Date("2026-11-20T00:00:00Z"), "America/New_York", newest))).toBe("2026-11-21T01:20:00.000Z");
        // A bare time in New York just after its midnight, and in Tokyo, 9 hours east of UTC.
        expect(iso(resolveTime("23:40", new Date("2026-11-21T00:00:00Z"), "America/New_York", new Date("2026-11-21T05:10:00Z")))).toBe("2026-11-21T04:40:00.000Z");
        expect(iso(resolveTime("23:50", new Date("2026-11-21T00:00:00Z"), "Asia/Tokyo", new Date("2026-11-20T15:10:00Z")))).toBe("2026-11-20T14:50:00.000Z");
        // Minutes after midnight, when the newest data is minutes before it: the next day's, not a day earlier.
        const late = new Date("2026-11-20T23:58:00Z");
        expect(iso(resolveTime("00:05 UTC", new Date("2026-11-20T00:00:00Z"), "UTC", late))).toBe("2026-11-21T00:05:00.000Z");
        expect(iso(resolveTime("00:05", new Date("2026-11-20T00:00:00Z"), "UTC", late))).toBe("2026-11-21T00:05:00.000Z");
    });

    // The re-review of 817b81c: the times an entry point hands the chat must be times the tools take, on the session's date.
    it("gives the entry points' times to triage_window and find_incidents as an older session's own minutes", async () => {
        const from = new Date("2026-11-17T13:30:00Z");
        const to = new Date("2026-11-17T15:00:00Z");
        const newest = new Date("2026-11-20T17:20:00Z");
        const tools = createInvestigationTools({ load: (f, t, targets) => loadEvidence(async () => [], f, t, targets), timeZone: "America/New_York", latestDay: new Date("2026-11-20T00:00:00Z"), latest: newest });
        for (const [ask, tool] of [
            [triageAsk({ from, to }), "triage_window"],
            [findIncidentsAsk({ from, to, targets: ["T1"] }), "find_incidents"],
        ] as const) {
            const times = /call \w+ with from (\S+) and to (\S+),/.exec(ask.prompt);
            expect(times, ask.prompt).not.toBeNull();
            const result = await tools.investigate(tool, { from: times![1], to: times![2] });
            expect(typeof result === "string" ? result : result.window, tool).toMatchObject({ fromUtc: "2026-11-17T13:30:00Z", toUtc: "2026-11-17T15:00:00Z" });
        }
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
