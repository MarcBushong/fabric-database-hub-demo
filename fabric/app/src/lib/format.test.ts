import { describe, expect, it } from "vitest";

import { csvFileName, toCsv } from "./csv";
import { formatAgo, formatCell, formatDateTimeUtc, formatDuration, formatNumber, toDate } from "./format";

describe("formatNumber", () => {
    it("formats each kind with its unit", () => {
        expect(formatNumber(2293, "int")).toBe("2,293");
        expect(formatNumber(63.64, "percent")).toBe("63.6 %");
        expect(formatNumber(12.34, "seconds")).toBe("12.3 s");
        expect(formatNumber(420, "minutes")).toBe("420 min");
        expect(formatNumber(1500, "mb")).toBe("1,500 MB");
    });

    it("shows a dash for blanks and non-numbers", () => {
        expect(formatNumber(null)).toBe("–");
        expect(formatNumber("12")).toBe("–");
        expect(formatNumber(Number.NaN)).toBe("–");
    });
});

describe("toDate", () => {
    it("reads the connector's zone-less ISO text as UTC", () => {
        expect(toDate("2026-10-21T17:25:17")?.toISOString()).toBe("2026-10-21T17:25:17.000Z");
        expect(toDate("2026-10-21T17:25")?.toISOString()).toBe("2026-10-21T17:25:00.000Z");
    });

    it("keeps explicit zones and rejects junk", () => {
        expect(toDate("2026-10-21T17:25:17+02:00")?.toISOString()).toBe("2026-10-21T15:25:17.000Z");
        expect(toDate("tomorrow")).toBeNull();
        expect(toDate("")).toBeNull();
        expect(toDate(undefined)).toBeNull();
    });
});

describe("durations and times", () => {
    it("formats durations compactly", () => {
        expect(formatDuration(45)).toBe("45 min");
        expect(formatDuration(420)).toBe("7 h");
        expect(formatDuration(210)).toBe("3 h 30 min");
        expect(formatDuration(52 * 60)).toBe("2 d 4 h");
        expect(formatDuration(-1)).toBe("–");
    });

    it("formats UTC instants and relative times", () => {
        const at = new Date(Date.UTC(2026, 9, 21, 14, 5));
        expect(formatDateTimeUtc(at)).toBe("21 Oct 14:05 UTC");
        expect(formatAgo(at, new Date(Date.UTC(2026, 9, 22, 8, 5)))).toBe("18 h ago");
        expect(formatAgo(null)).toBe("never");
    });

    it("formats table cells by column kind", () => {
        expect(formatCell({ kind: "int" }, 12)).toBe("12");
        expect(formatCell({ kind: "datetime" }, "2026-10-21T14:05:00")).toBe("21 Oct 14:05 UTC");
        expect(formatCell({ kind: "text" }, "T3")).toBe("T3");
        expect(formatCell({ kind: "text" }, null)).toBe("–");
    });
});

describe("toCsv", () => {
    const columns = [
        { key: "a", label: "Name" },
        { key: "b", label: "Value, unit" },
    ];

    it("quotes separators, quotes, and line breaks (RFC 4180)", () => {
        const csv = toCsv(columns, [{ a: 'say "hi"', b: "x\ny" }]);
        expect(csv).toBe('Name,"Value, unit"\r\n"say ""hi""","x\ny"\r\n');
    });

    it("guards text a spreadsheet would run as a formula", () => {
        const csv = toCsv(columns, [{ a: "=HYPERLINK(1)", b: -5 }]);
        expect(csv.split("\r\n")[1]).toBe("'=HYPERLINK(1),-5");
    });

    it("writes dates as ISO and blanks as empty", () => {
        const csv = toCsv(columns, [{ a: new Date(Date.UTC(2026, 9, 21)), b: null }]);
        expect(csv.split("\r\n")[1]).toBe("2026-10-21T00:00:00.000Z,");
    });

    it("builds safe, stamped file names", () => {
        expect(csvFileName("Estate: key signals / target", new Date(Date.UTC(2026, 9, 21, 17, 5)))).toBe("dbhub-estate-key-signals-target-202610211705Z.csv");
        expect(csvFileName("***", new Date(Date.UTC(2026, 9, 21, 17, 5)))).toBe("dbhub-data-202610211705Z.csv");
    });
});
