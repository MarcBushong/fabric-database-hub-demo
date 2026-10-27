import { describe, expect, it } from "vitest";

import { args, bucketRange, dateFilter, daxDate, daxDateTime, daxString, isTargetKey, targetFilter, tokenizeDax } from "./dax";

describe("dax builders", () => {
    it("doubles quotes in string literals", () => {
        expect(daxString('say "hi"')).toBe('"say ""hi"""');
    });

    it("writes UTC dates and instants", () => {
        const at = new Date(Date.UTC(2026, 9, 21, 17, 5, 9));
        expect(daxDate(at)).toBe("DATE ( 2026, 10, 21 )");
        expect(daxDateTime(at)).toBe("DATE ( 2026, 10, 21 ) + TIME ( 17, 5, 9 )");
    });

    it("rejects invalid dates instead of writing them into DAX", () => {
        expect(() => daxDate(new Date("not a date"))).toThrow(/valid date/);
    });

    it("keeps only allow-listed targets, in order, and falls back to all three", () => {
        expect(targetFilter(["T3", "T1"])).toBe(`TREATAS ( { "T1", "T3" }, 'Target'[Target Key] )`);
        expect(targetFilter([])).toBe(`TREATAS ( { "T1", "T2", "T3" }, 'Target'[Target Key] )`);
        expect(isTargetKey("T2")).toBe(true);
        expect(isTargetKey("T4")).toBe(false);
        expect(isTargetKey("T1' ) EVALUATE")).toBe(false);
    });

    it("filters dates only when a window is set", () => {
        expect(dateFilter(null)).toBeNull();
        const window = { from: new Date(Date.UTC(2026, 9, 15)), to: new Date(Date.UTC(2026, 9, 21)) };
        expect(dateFilter(window)).toBe("DATESBETWEEN ( 'Date'[Date], DATE ( 2026, 10, 15 ), DATE ( 2026, 10, 21 ) )");
    });

    it("bounds bins inclusively or exclusively", () => {
        const start = new Date(Date.UTC(2026, 9, 21, 10));
        const end = new Date(Date.UTC(2026, 9, 21, 12));
        expect(bucketRange(start, end)).toContain("<= DATE ( 2026, 10, 21 ) + TIME ( 12, 0, 0 )");
        expect(bucketRange(start, end, true)).toContain("< DATE ( 2026, 10, 21 ) + TIME ( 12, 0, 0 )");
    });

    it("joins arguments and skips empty ones", () => {
        expect(args(["a", null, "", false, undefined, "b"], "")).toBe("a,\nb");
    });
});

describe("tokenizeDax", () => {
    it("splits keywords, strings, column and measure references", () => {
        const tokens = tokenizeDax(`EVALUATE ROW ( "N", [Checks], "T", MAX ( 'Date'[Date] ) )`);
        const kinds = tokens.filter((t) => t.text.trim()).map((t) => `${t.kind}:${t.text}`);
        expect(kinds).toEqual(["k:EVALUATE", "k:ROW", "p:(", 's:"N"', "p:,", "m:[Checks]", "p:,", 's:"T"', "p:,", "k:MAX", "p:(", "t:'Date'[Date]", "p:)", "p:)"]);
    });

    it("round-trips the text exactly", () => {
        const dax = `EVALUATE\nFILTER ( ALL ( 'Telemetry Snapshots'[Bucket UTC] ), 1 = 1 ) -- "quoted ""x"""`;
        expect(
            tokenizeDax(dax)
                .map((t) => t.text)
                .join(""),
        ).toBe(dax);
    });
});
