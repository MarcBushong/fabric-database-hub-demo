import { describe, expect, it, vi } from "vitest";

import { ANSWER_KEY_TABLES } from "@/copilot/answer-key";
import { QueryFailure } from "@/data/query-client";
import type { QuerySpec } from "@/data/queries";
import { loadEvidence, MONITOR_PAGES, MONITOR_ROW_LIMIT, RCA_MAX_ROWS, RCA_ROW_LIMIT, RcaReadError, rcaDax, rcaMonitorDax, rcaRowLimit } from "./loader";
import { createRcaSources, finestPerInterval } from "./sources";
import { createInvestigationTools } from "./tools";
import { emptyEvidence, pointKey } from "./types";

const at = (hhmm: string) => new Date(`2026-11-20T${hhmm}:00Z`);
const lag = (bucket: string, value: number, capturedAt: string) => ({
    Bucket: `2026-11-20T${bucket}:00`,
    TargetKey: "T4-replica",
    ResourceName: "pg01-replica",
    Metric: "physical_replication_delay_in_seconds",
    Value: value,
    Unit: "Seconds",
    WindowStart: "2026-11-20T15:30:00",
    WindowEnd: "2026-11-20T17:30:00",
    CapturedAt: capturedAt,
});

describe("the investigations' sources", () => {
    it("read Azure Monitor's metrics for any window from Telemetry Snapshots alone, never the answer key", () => {
        expect(rcaMonitorDax(at("17:00"), at("17:20"), ["T1", "T2", "T3"])).toBeNull();
        const dax = rcaMonitorDax(at("17:00"), at("17:20"), ["T1", "T4-replica", "T5"])!;
        expect(dax).toContain(`'Telemetry Snapshots'[Target Key] IN { "T4-replica", "T5" }`);
        expect(dax).toContain("'Telemetry Snapshots'[Bucket UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 17, 0, 0 )");
        for (const table of ANSWER_KEY_TABLES) expect(dax).not.toContain(table);
    });

    // A session exported once has one coverage row from its start to its end: a window late in it must still find that row.
    it("find a coverage interval that overlaps the window, not only one that starts in it", () => {
        const dax = rcaDax("coverage", at("17:00"), at("17:20"), ["T1"]);
        expect(dax).toContain("'RCA Coverage'[Window End UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 17, 0, 0 )");
        expect(dax).toContain("'RCA Coverage'[Window Start UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 20, 0 )");
        expect(rcaDax("sessions", at("17:00"), at("17:20"), ["T1"])).toContain("'RCA Sessions'[Captured At UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 17, 0, 0 )");
    });

    it("keep the newest capture of each interval of one grain", () => {
        const { kept } = finestPerInterval([lag("17:13", 100, "2026-11-20T17:20:00"), lag("17:14", 166, "2026-11-20T17:20:00"), lag("17:13", 106, "2026-11-20T17:40:00"), lag("17:14", 170, "2026-11-20T17:40:00")]);
        expect(kept.map((r) => r.Value)).toEqual([106, 170]);
    });

    // The review of 803f2b1a: B's day-long save at 15 minutes, newer than the session's own at 1 minute, kept its total for
    // 15:30 to 15:45 beside the 1-minute points it holds, and T5's requests counted both; each point read the capture's
    // smallest interval.
    it("keep the finest grain of each minute, a coarser point only where no finer one is, each with its own interval", () => {
        const requests = (bucket: string, value: number, capturedAt: string) => ({ ...lag(bucket, value, capturedAt), TargetKey: "T5", Metric: "TotalRequests" });
        const { kept, intervals } = finestPerInterval([
            ...["15:30", "15:31", "15:32"].map((bucket, i) => requests(bucket, 100 + i, "2026-11-20T17:09:30")),
            requests("15:15", 50, "2026-11-20T21:33:44"),
            requests("15:30", 27630, "2026-11-20T21:33:44"),
            requests("15:45", 900, "2026-11-20T21:33:44"),
        ]);
        expect(kept.map((r) => [String(r.Bucket).slice(11, 16), r.Value])).toEqual([["15:15", 50], ["15:30", 100], ["15:31", 101], ["15:32", 102], ["15:45", 900]]);
        expect(intervals.get(pointKey("T5", "TotalRequests", at("15:31")))).toBe(60_000);
        expect(intervals.get(pointKey("T5", "TotalRequests", at("15:45")))).toBe(15 * 60_000);
    });

    it("give T4's replica lag from overlapping captures, and ask for T1's bins only when T1 is in scope", async () => {
        const run = vi.fn(async (spec: QuerySpec) =>
            spec.dax.includes('IN { "T4-replica" }') ? [lag("17:12", 45, "2026-11-20T17:30:00"), lag("17:12", 44, "2026-11-20T17:25:00"), lag("17:13", 106, "2026-11-20T17:30:00")] : [],
        );
        const sources = createRcaSources(run);
        const telemetry = await sources.telemetry(at("17:00"), at("17:20"), ["T4-replica"]);
        expect(telemetry.postgres?.points.map((p) => p.value)).toEqual([45, 106]);
        expect(telemetry.bins).toEqual([]);
        expect(run).toHaveBeenCalledTimes(1);
    });

    it("size each table's row limit to the window, and say when a table had more rows than it", async () => {
        expect(rcaRowLimit(at("17:00"), at("17:20"))).toBe(RCA_ROW_LIMIT);
        expect(rcaRowLimit(at("15:30"), at("17:30"))).toBe(4 * RCA_ROW_LIMIT);
        expect(rcaRowLimit(new Date("2026-11-19T17:00:00Z"), at("17:00"))).toBe(RCA_MAX_ROWS);
        const full = Array.from({ length: RCA_ROW_LIMIT }, () => ({}));
        const evidence = await loadEvidence(async (dax) => (dax.includes("'RCA Events'") ? full : []), at("17:00"), at("17:20"), ["T1"]);
        expect(evidence.cut).toEqual(["RCA Events"]);
        const tools = createInvestigationTools({ load: async () => evidence, timeZone: "UTC", latestDay: at("00:00"), latest: at("17:20") });
        const result = await tools.investigate("explain_errors", {});
        expect(typeof result === "string" ? result : result.window).toMatchObject({ fromUtc: "2026-11-20T15:50:00Z", toUtc: "2026-11-20T17:20:00Z" });
        expect(typeof result === "string" ? [] : result.notCaptured).toContain("RCA Events: the window holds more rows than one query returns, so its latest rows weren't read; ask about a narrower window");
    });

    // The coordinator's note on the shared finestPerInterval: the read stops at MONITOR_ROW_LIMIT rows, oldest first, so one
    // at the limit silently lost its newest rows, the incident's own minutes.
    it("read Azure Monitor's metrics a page at a time, each from the last bucket before it, and say when a window holds more than its pages", async () => {
        const metrics = ["NormalizedRUConsumption", "TotalRequests", "ThrottledRequests", "ProvisionedThroughput"];
        const start = Date.parse("2026-11-20T00:00:00Z");
        // A row a minute for each metric: 1,500 minutes, 6,000 rows in all, as the DAX orders them.
        const all = (minutes: number) =>
            Array.from({ length: minutes }, (_, m) =>
                metrics.map((Metric, i) => ({ Bucket: new Date(start + m * 60_000).toISOString().slice(0, 19), TargetKey: "T5", ResourceName: "cosmos01", Metric, Value: 10 + i, Unit: "Count", WindowStart: "2026-11-20T00:00:00", WindowEnd: "2026-11-21T02:00:00", CapturedAt: "2026-11-21T02:05:00" })),
            ).flat();
        const pages = (rows: ReturnType<typeof all>) =>
            vi.fn(async (spec: QuerySpec) => {
                const m = /\[Bucket UTC\] >= DATE \( (\d+), (\d+), (\d+) \) \+ TIME \( (\d+), (\d+), (\d+) \)/.exec(spec.dax);
                const from = m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : 0;
                return rows.filter((r) => Date.parse(`${r.Bucket}Z`) >= from).slice(0, spec.rowLimit);
            });
        const complete = pages(all(1500));
        const telemetry = await createRcaSources(complete).telemetry(new Date(start), new Date(start + 1500 * 60_000), ["T5"]);
        expect(complete).toHaveBeenCalledTimes(2);
        expect(telemetry.cosmos?.points.length).toBe(6000);
        expect(new Set(telemetry.cosmos?.points.map((p) => `${p.metric}|${p.at.getTime()}`)).size).toBe(6000);
        expect(telemetry.cut).toBeUndefined();
        // More than its pages hold: the rest isn't read, and the window's investigations say so.
        const endless = pages(all(6000));
        const sources = createRcaSources(endless);
        const tools = createInvestigationTools({ load: async () => emptyEvidence(), telemetry: sources.telemetry, timeZone: "UTC", latestDay: new Date(start), latest: new Date(start + 6000 * 60_000) });
        const result = await tools.investigate("explain_errors", { from: "2026-11-20T00:00:00Z", to: "2026-11-24T04:00:00Z", targets: ["T5"] });
        expect(endless).toHaveBeenCalledTimes(MONITOR_PAGES);
        expect(typeof result === "string" ? [] : result.notCaptured).toContain(`Telemetry Snapshots (Azure Monitor): the window holds more rows than its ${MONITOR_PAGES} reads of ${MONITOR_ROW_LIMIT} return, so its latest rows weren't read; ask about a narrower window`);
    });

    // Live, 2026-11-21: Power BI answered 429 to the app's reads. A telemetry read that failed left its part empty, so the
    // window could read as quiet.
    it("fail the window's telemetry when a read fails, never leaving it quiet, and leave out only what the model doesn't have", async () => {
        const throttled = new QueryFailure("Fabric couldn't run the query: You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds.", "api", "429");
        const failing = createRcaSources(async () => {
            throw throttled;
        });
        const read = failing.telemetry(at("17:00"), at("17:20"), ["T1", "T4-replica"]);
        await expect(read).rejects.toBeInstanceOf(RcaReadError);
        await expect(read).rejects.toThrow(/^The history couldn't be read, so nothing is concluded from it \(Telemetry Snapshots(?: \(Azure Monitor\))?: Fabric couldn't run the query: /);
        const older = createRcaSources(async () => {
            throw new QueryFailure("The model rejected the query: Query (1, 20) Column '<oii>Metric</oii>' in table '<oii>Telemetry Snapshots</oii>' cannot be found or may not be used in this expression.", "query");
        });
        await expect(older.telemetry(at("17:00"), at("17:20"), ["T4-replica"])).resolves.toMatchObject({ bins: [] });
    });
});
