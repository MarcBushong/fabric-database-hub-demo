import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { ADDITIVE_ANALYSES, ADDITIVE_METRICS, addsUp, finestPerInterval, HOURLY_METRICS, OFF_GRID_ANALYSES, pointKey } from "./finest-per-interval";

type Row = Record<string, unknown>;

const MIN = 60_000;
const at = (hhmm: string) => new Date(`2026-11-21T${hhmm}:00Z`);
const hhmm = (row: Row) => String(row.Bucket).slice(11, 16);
const total = (rows: readonly Row[]) => rows.reduce((sum, r) => sum + Number(r.Value), 0);

// A live test's saves (2026-11-21): the session's own at its end, and a day-long one four hours later.
const T5_SESSION = { CapturedAt: "2026-11-21T17:09:30.107", WindowStart: "2026-11-21T15:14:00", WindowEnd: "2026-11-21T16:57:00" };
const T5_DAY = { CapturedAt: "2026-11-21T21:33:44.05", WindowStart: "2026-11-20T21:26:00", WindowEnd: "2026-11-21T21:26:00" };
const T4_SESSION = { CapturedAt: "2026-11-21T17:09:30.083", WindowStart: "2026-11-21T15:14:00", WindowEnd: "2026-11-21T16:57:00" };
const T4_DAY = { CapturedAt: "2026-11-21T21:33:42.797", WindowStart: "2026-11-20T21:25:00", WindowEnd: "2026-11-21T21:26:00" };

const point =
    (save: Record<string, string>, target: string, resource: string, metric: string, unit: string) =>
    (bucket: string, value: number): Row => ({ Bucket: `2026-11-21T${bucket}:00`, TargetKey: target, ResourceName: resource, Metric: metric, Value: value, Unit: unit, ...save });
const minutes = (from: string, values: readonly number[]) => values.map((value, i) => [new Date(at(from).getTime() + i * MIN).toISOString().slice(11, 16), value] as const);

// T5's requests, every minute from 15:15 to 15:44 in the session's save: the real values.
const REQUESTS = minutes("15:15", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 36, 67, 66, 1356, 3837, 3905, 996, 957, 3436, 3922, 1481, 1469, 3932, 2006, 159, 66, 42]);
// T4's read replica's lag, every 5 minutes from 15:40 to 16:55 in the session's save: the real values.
const LAG = [1, 2, 1, 2, 2, 2, 1, 148, 178, 2, 2, 1, 1, 1, 1, 8].map((value, i) => [new Date(at("15:40").getTime() + i * 5 * MIN).toISOString().slice(11, 16), value] as const);

describe("finestPerInterval, the history's overlapping saves (F35)", () => {
    it("keeps the newest save of each interval of one grain", () => {
        const lag = (save: Record<string, string>) => point(save, "T4-replica", "pgreplica01", "physical_replication_delay_in_seconds", "Seconds");
        const older = { CapturedAt: "2026-11-20T17:20:00", WindowStart: "2026-11-20T15:30:00", WindowEnd: "2026-11-20T17:30:00" };
        const newer = { ...older, CapturedAt: "2026-11-20T17:40:00" };
        const { kept } = finestPerInterval([lag(older)("17:13", 100), lag(older)("17:14", 166), lag(newer)("17:13", 106), lag(newer)("17:14", 170)]);
        expect(kept.map((r) => r.Value)).toEqual([106, 170]);
    });

    it("passes one save through as it is, each point with its save's interval, cut where its window ends", () => {
        const rows = LAG.map(([bucket, value]) => point(T4_SESSION, "T4-replica", "pgreplica01", "physical_replication_delay_in_seconds", "Seconds")(bucket, value));
        const { kept, intervals } = finestPerInterval([...rows].reverse());
        expect(kept).toHaveLength(rows.length);
        kept.forEach((row, i) => expect(row).toBe(rows[i]));
        expect(intervals.get(pointKey("T4-replica", "physical_replication_delay_in_seconds", at("16:50")))).toBe(5 * MIN);
        // The session's window ended at 16:57, inside its last 5-minute interval.
        expect(intervals.get(pointKey("T4-replica", "physical_replication_delay_in_seconds", at("16:55")))).toBe(2 * MIN);
    });

    it("counts a minute once when a day-long save's 15-minute totals overlap the session's own minutes", () => {
        const session = point(T5_SESSION, "T5", "cosmos01", "TotalRequests", "Count");
        const day = point(T5_DAY, "T5", "cosmos01", "TotalRequests", "Count");
        // The session's minutes add up to each 15-minute total exactly: 103 from 15:15, 27,630 from 15:30.
        const { kept, intervals } = finestPerInterval([day("15:15", 103), day("15:30", 27630), ...REQUESTS.map(([bucket, value]) => session(bucket, value))]);
        expect(kept).toHaveLength(REQUESTS.length);
        expect(kept.every((r) => r.CapturedAt === T5_SESSION.CapturedAt)).toBe(true);
        expect(total(kept)).toBe(103 + 27630);
        expect(intervals.get(pointKey("T5", "TotalRequests", at("15:30")))).toBe(MIN);
    });

    it("keeps a coarser total for the minutes the finer points don't cover, less theirs", () => {
        const session = point({ ...T5_SESSION, WindowStart: "2026-11-21T15:31:00", WindowEnd: "2026-11-21T15:41:00" }, "T5", "cosmos01", "TotalRequests", "Count");
        const day = point(T5_DAY, "T5", "cosmos01", "TotalRequests", "Count");
        // A session that saved 15:31 to 15:41 only: the 15-minute total stays for 15:30 and for 15:41 to 15:45.
        const inside = REQUESTS.filter(([bucket]) => bucket >= "15:31" && bucket <= "15:40");
        const { kept, intervals } = finestPerInterval([day("15:15", 103), day("15:30", 27630), day("15:45", 23858), ...inside.map(([bucket, value]) => session(bucket, value))]);
        const quarter = (r: Row) => hhmm(r) >= "15:30" && hhmm(r) < "15:45";
        const rest = kept.filter((r) => r.CapturedAt === T5_DAY.CapturedAt && quarter(r));
        expect(rest.map(hhmm)).toEqual(["15:30", "15:41"]);
        expect(rest.map((r) => intervals.get(pointKey("T5", "TotalRequests", new Date(`${String(r.Bucket)}Z`))))).toEqual([MIN, 4 * MIN]);
        // 27,630 less the 25,291 saved: exactly what those five minutes really had (66, then 2,006, 159, 66, and 42).
        const uncovered = REQUESTS.filter(([bucket]) => bucket === "15:30" || bucket >= "15:41");
        expect(total(rest)).toBe(uncovered.reduce((sum, [, value]) => sum + value, 0));
        expect(rest.map((r) => r.Value)).toEqual([468, 1871]);
        expect(total(kept.filter(quarter))).toBe(27630);

        // Where only three of its minutes were saved, the same total isn't cut to those 303 requests.
        const three = point({ ...T5_SESSION, WindowStart: "2026-11-21T15:30:00", WindowEnd: "2026-11-21T15:33:00" }, "T5", "cosmos01", "TotalRequests", "Count");
        const { kept: some } = finestPerInterval([day("15:15", 103), day("15:30", 27630), day("15:45", 23858), three("15:30", 100), three("15:31", 101), three("15:32", 102)]);
        expect(some.map((r) => [hhmm(r), r.Value])).toEqual([["15:15", 103], ["15:30", 100], ["15:31", 101], ["15:32", 102], ["15:33", 27327], ["15:45", 23858]]);
    });

    it("keeps a coarser peak for the minutes after the session's window only when it's higher, at those minutes", () => {
        const session = point(T4_SESSION, "T4-replica", "pgreplica01", "physical_replication_delay_in_seconds", "Seconds");
        const day = point(T4_DAY, "T4-replica", "pgreplica01", "physical_replication_delay_in_seconds", "Seconds");
        const rows = [day("15:45", 2), day("16:00", 2), day("16:15", 178), day("16:30", 2), day("16:45", 34), ...LAG.map(([bucket, value]) => session(bucket, value))];
        const { kept, intervals } = finestPerInterval(rows);
        // The session's points 1, 1, and 8 s cover 16:45 to 16:57: the day's 34 s were in 16:57 to 17:00.
        const fromDay = kept.filter((r) => r.CapturedAt === T4_DAY.CapturedAt);
        expect(fromDay.map((r) => [hhmm(r), r.Value])).toEqual([["16:57", 34]]);
        expect(intervals.get(pointKey("T4-replica", "physical_replication_delay_in_seconds", at("16:57")))).toBe(3 * MIN);
        // The peak comes from the finest grain: 178 s at 16:20, not the day's 15 minutes from 16:15.
        const peak = kept.reduce((best, r) => (Number(r.Value) > Number(best.Value) ? r : best));
        expect([hhmm(peak), peak.Value, intervals.get(pointKey("T4-replica", "physical_replication_delay_in_seconds", at(hhmm(peak))))]).toEqual(["16:20", 178, 5 * MIN]);
        expect(kept.find((r) => hhmm(r) === "16:15")?.Value).toBe(148);

        // A coarser point that isn't higher than what it overlaps adds nothing.
        const { kept: lower } = finestPerInterval([day("16:30", 2), day("16:45", 8), ...LAG.map(([bucket, value]) => session(bucket, value))]);
        expect(lower.filter((r) => r.CapturedAt === T4_DAY.CapturedAt)).toEqual([]);
    });

    it("starts a point cut by its window's start there, so a coarser stretch before it has an interval of its own", () => {
        const session = point({ ...T4_SESSION, WindowStart: "2026-11-21T15:17:00", WindowEnd: "2026-11-21T15:30:00" }, "T4", "pgflex01", "connections_failed", "Count");
        const day = point(T4_DAY, "T4", "pgflex01", "connections_failed", "Count");
        const { kept, intervals } = finestPerInterval([day("15:15", 7), day("15:30", 4), session("15:15", 1), session("15:20", 2), session("15:25", 3)]);
        expect(kept.map((r) => [hhmm(r), r.Value, r.CapturedAt === T4_DAY.CapturedAt ? "day" : "session"])).toEqual([
            ["15:15", 1, "day"],
            ["15:17", 1, "session"],
            ["15:20", 2, "session"],
            ["15:25", 3, "session"],
            ["15:30", 4, "day"],
        ]);
        const interval = (hm: string) => intervals.get(pointKey("T4", "connections_failed", at(hm)));
        expect(["15:15", "15:17", "15:20", "15:25", "15:30"].map(interval)).toEqual([2 * MIN, 3 * MIN, 5 * MIN, 5 * MIN, 15 * MIN]);
        expect(total(kept.filter((r) => hhmm(r) < "15:30"))).toBe(7);
    });

    it("gives T5's hourly metrics an hour, even as the only point of their series in a save", () => {
        const save = { CapturedAt: "2026-11-21T16:01:00", WindowStart: "2026-11-21T15:00:00", WindowEnd: "2026-11-21T16:00:00" };
        const { intervals } = finestPerInterval([
            point(save, "T5", "cosmos01", "ProvisionedThroughput", "Count")("15:00", 400),
            point(save, "T5", "cosmos01", "TotalRequests", "Count")("15:00", 5),
            point(save, "T5", "cosmos01", "TotalRequests", "Count")("15:01", 6),
        ]);
        expect(intervals.get(pointKey("T5", "ProvisionedThroughput", at("15:00")))).toBe(60 * MIN);
        expect(intervals.get(pointKey("T5", "TotalRequests", at("15:00")))).toBe(MIN);
    });

    // A read narrower than two of a save's intervals can hold one point per series of it: its step isn't in the rows.
    it("treats a save without a step in the rows as instants, kept unless a kept point covers them", () => {
        const session = point(T5_SESSION, "T5", "cosmos01", "TotalRequests", "Count");
        const day = point(T5_DAY, "T5", "cosmos01", "TotalRequests", "Count");
        expect(finestPerInterval([day("15:30", 27630), session("15:30", 66), session("15:31", 1356)]).kept.map((r) => r.Value)).toEqual([66, 1356]);
        const { kept, intervals } = finestPerInterval([day("15:30", 27630), session("15:31", 1356), session("15:32", 3837)]);
        expect(kept.map((r) => r.Value)).toEqual([27630, 1356, 3837]);
        expect(intervals.has(pointKey("T5", "TotalRequests", at("15:30")))).toBe(false);
    });

    it("tells totals from peaks by the producers' own aggregations", () => {
        const root = join(process.cwd(), "..", "..");
        const cosmos = readFileSync(join(root, "scripts", "modules", "DbHubDemo", "Private", "CosmosHistoryHelpers.ps1"), "utf8");
        const postgres = readFileSync(join(root, "scripts", "modules", "DbHubDemo", "Private", "PostgresHistoryHelpers.ps1"), "utf8");
        const cosmosMetrics = [...cosmos.matchAll(/@\{ Metric = '(\w+)'; Name = '\w+'; Aggregation = '(\w+)'; Throttled = \$\w+; Hourly = \$(\w+) \}/g)];
        const postgresMetrics = [...postgres.matchAll(/@\{ Aggregation = '(\w+)'; Names = @\(([^)]*)\) \}/g)].flatMap((m) => [...m[2].matchAll(/'(\w+)'/g)].map((n) => [n[1], m[1]] as const));
        expect(cosmosMetrics.length).toBeGreaterThanOrEqual(7);
        expect(postgresMetrics.length).toBeGreaterThanOrEqual(8);
        const totals = new Set([...cosmosMetrics.filter((m) => m[2] === "Total" || m[2] === "Count").map((m) => m[1]), ...postgresMetrics.filter(([, a]) => a === "Total").map(([n]) => n)]);
        expect([...ADDITIVE_METRICS].sort()).toEqual([...totals].sort());
        expect([...HOURLY_METRICS].sort()).toEqual(cosmosMetrics.filter((m) => m[3] === "true").map((m) => m[1]).sort());
        for (const [name] of postgresMetrics) expect(addsUp({ Metric: name })).toBe(totals.has(name));

        // Every analysis the notebooks write is a total, a peak, or off the grid, and the lists name nothing else.
        const notebook = (name: string) => (JSON.parse(readFileSync(join(root, "fabric", "notebooks", name), "utf8")) as { cells: Array<{ source: string[] | string }> }).cells.map((c) => (Array.isArray(c.source) ? c.source.join("") : c.source)).join("\n");
        const written = new Set([...[...notebook("NB_DatabaseHub_LiveActivity.ipynb").matchAll(/add_snapshot\("(\w+)"/g)].map((m) => m[1]), ...[...notebook("NB_DatabaseHub_Deployment.ipynb").matchAll(/"analysis": "(\w+)"/g)].map((m) => m[1])]);
        const peaks = new Set(["cpu", "gauges", "sessions"]);
        for (const analysis of written) expect([ADDITIVE_ANALYSES.has(analysis), peaks.has(analysis), OFF_GRID_ANALYSES.has(analysis)].filter(Boolean)).toHaveLength(1);
        for (const analysis of [...ADDITIVE_ANALYSES, ...OFF_GRID_ANALYSES, ...peaks]) expect(written.has(analysis)).toBe(true);
        expect(addsUp({ AnalysisKey: "wait_deltas", Metric: "Lock" })).toBe(true);
        expect(addsUp({ AnalysisKey: "gauges", Metric: "Processes blocked" })).toBe(false);
    });
});
