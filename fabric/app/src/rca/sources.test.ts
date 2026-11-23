import { describe, expect, it, vi } from "vitest";

import { ANSWER_KEY_TABLES } from "@/copilot/answer-key";
import { QueryFailure } from "@/data/query-client";
import type { QuerySpec } from "@/data/queries";
import { loadEvidence, MONITOR_PAGES, MONITOR_ROW_LIMIT, RCA_MAX_ROWS, RCA_ROW_LIMIT, RcaReadError, rcaDax, rcaMonitorDax, rcaRowLimit } from "./loader";
import { createRcaSources, finestPerInterval, monitorTelemetry, type RunQuery } from "./sources";
import { emptyListNote } from "./view/facts";
import { createInvestigationTools } from "./tools";
import { emptyEvidence, pointKey, type InvestigationResult } from "./types";

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
    // smallest interval. With the shared finestPerInterval (a390db00), the rest of the 15 minutes stays as what the minutes
    // saved didn't hold (the review of ebd1c6c3: dropping it lost the replica's 34 s at 16:57).
    it("keep the finest grain of each minute, and of a coarser total what the finer points don't hold, each with its span and its grain", () => {
        const requests = (bucket: string, value: number, capturedAt: string) => ({ ...lag(bucket, value, capturedAt), TargetKey: "T5", Metric: "TotalRequests" });
        const { kept, intervals, grains } = finestPerInterval([
            ...["15:30", "15:31", "15:32"].map((bucket, i) => requests(bucket, 100 + i, "2026-11-20T17:09:30")),
            requests("15:15", 50, "2026-11-20T21:33:44"),
            requests("15:30", 27630, "2026-11-20T21:33:44"),
            requests("15:45", 900, "2026-11-20T21:33:44"),
        ]);
        expect(kept.map((r) => [String(r.Bucket).slice(11, 16), r.Value])).toEqual([["15:15", 50], ["15:30", 100], ["15:31", 101], ["15:32", 102], ["15:33", 27327], ["15:45", 900]]);
        expect(intervals.get(pointKey("T5", "TotalRequests", at("15:31")))).toBe(60_000);
        expect(intervals.get(pointKey("T5", "TotalRequests", at("15:45")))).toBe(15 * 60_000);
        expect([intervals.get(pointKey("T5", "TotalRequests", at("15:33"))), grains.get(pointKey("T5", "TotalRequests", at("15:33")))]).toEqual([12 * 60_000, 15 * 60_000]);
    });

    // The review of c4c63abe: a coarser point split around a finer save is one reading. Its raw value is of the minutes
    // its own save's window cuts it to, as the shared function cuts its span: here 15:37 to 15:45, not 15:30 to 15:45.
    it("give a split point's whole reading over the minutes its save's window cuts it to, with what the finer save holds", () => {
        const throttled = (capturedAt: string, from: string, to: string) => (bucket: string, value: number) => ({ ...lag(bucket, value, `2026-11-20T${capturedAt}:00`), TargetKey: "T5", ResourceName: "cosmos01", Metric: "ThrottledRequests", Unit: "Count", WindowStart: `2026-11-20T${from}:00`, WindowEnd: `2026-11-20T${to}:00` });
        const day = throttled("21:33", "15:37", "21:30");
        const session = throttled("17:09", "15:40", "15:42");
        const t = monitorTelemetry([day("15:30", 80), day("15:45", 0), day("16:00", 0), session("15:40", 10), session("15:41", 10)]);
        const whole = { key: pointKey("T5", "ThrottledRequests", at("15:30")), at: at("15:37"), intervalMs: 8 * 60_000, grainMs: 15 * 60_000, value: 80, finer: 20, covered: [{ from: at("15:40"), to: at("15:42") }] };
        expect(t.wholes?.get(pointKey("T5", "ThrottledRequests", at("15:37")))).toEqual(whole);
        expect(t.wholes?.get(pointKey("T5", "ThrottledRequests", at("15:42")))).toEqual(whole);
        expect(t.wholes?.size).toBe(2);
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

    it("size each table's row limit to the window, and say when a table had more rows than it, from where its read stopped", async () => {
        expect(rcaRowLimit(at("17:00"), at("17:20"))).toBe(RCA_ROW_LIMIT);
        expect(rcaRowLimit(at("15:30"), at("17:30"))).toBe(4 * RCA_ROW_LIMIT);
        expect(rcaRowLimit(new Date("2026-11-19T17:00:00Z"), at("17:00"))).toBe(RCA_MAX_ROWS);
        // Oldest first, as the DAX orders them: the read stopped at its last row's time, 17:12 (the review of d431edb4).
        const full = Array.from({ length: RCA_ROW_LIMIT }, (_, i) => ({ "Event Time UTC": `2026-11-20T17:${String(Math.floor((12 * i) / RCA_ROW_LIMIT)).padStart(2, "0")}:00` }));
        full[full.length - 1]["Event Time UTC"] = "2026-11-20T17:12:00";
        const evidence = await loadEvidence(async (dax) => (dax.includes("'RCA Events'") ? full : []), at("17:00"), at("17:20"), ["T1"]);
        expect(evidence.cut).toEqual([{ table: "RCA Events", until: at("17:12") }]);
        const tools = createInvestigationTools({ load: async () => evidence, timeZone: "UTC", latestDay: at("00:00"), latest: at("17:20") });
        const result = await tools.investigate("explain_errors", {});
        expect(typeof result === "string" ? result : result.window).toMatchObject({ fromUtc: "2026-11-20T15:50:00Z", toUtc: "2026-11-20T17:20:00Z" });
        expect(typeof result === "string" ? [] : result.notCaptured).toContain("RCA Events: the window holds more rows than one query returns, so what it holds from 17:12:00 UTC on wasn't read; ask about a narrower window");
    });

    // The coordinator's note on the shared finestPerInterval: the read stops at MONITOR_ROW_LIMIT rows, oldest first, so one
    // at the limit silently lost its newest rows, the incident's own minutes.
    it("read Azure Monitor's metrics a page at a time, each from the last bucket before it, and say when a window holds more than its pages", async () => {
        const metrics = ["NormalizedRUConsumption", "TotalRequests", "ThrottledRequests", "TotalRequestUnits"];
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
        // More than its pages hold: the rest isn't read, and the window's investigations say so, from where the read stopped.
        const endless = pages(all(6000));
        const sources = createRcaSources(endless);
        const tools = createInvestigationTools({ load: async () => emptyEvidence(), telemetry: sources.telemetry, timeZone: "UTC", latestDay: new Date(start), latest: new Date(start + 6000 * 60_000) });
        const result = await tools.investigate("explain_errors", { from: "2026-11-20T00:00:00Z", to: "2026-11-24T04:00:00Z", targets: ["T5"] });
        expect(endless).toHaveBeenCalledTimes(MONITOR_PAGES);
        expect(typeof result === "string" ? [] : result.notCaptured).toContain(`Telemetry Snapshots (Azure Monitor): the window holds more rows than its ${MONITOR_PAGES} reads of ${MONITOR_ROW_LIMIT} return, so what it holds from 11:16:00 UTC on wasn't read; ask about a narrower window`);
    });

    // The review of d431edb4: a read cut short still backed "nothing found" and its counts as if it had read the whole
    // window. The reviewer's probe: T5's 4 metrics a minute over 6,000 minutes, the read stopped by its pages at minute
    // 4,996 (11:16 on the fourth day), with 500 429s a minute only in the last 600 minutes, or from minute 4,900.
    it("say what a read cut short didn't find, and what it counted, only up to where it stopped", async () => {
        const start = Date.parse("2026-11-20T00:00:00Z");
        const rows = (throttledFrom: number) =>
            Array.from({ length: 6000 }, (_, m) =>
                (
                    [
                        ["NormalizedRUConsumption", 10],
                        ["ThrottledRequests", m >= throttledFrom ? 500 : 0],
                        ["TotalRequestUnits", 100],
                        ["TotalRequests", 1000],
                    ] as const
                ).map(([Metric, Value]) => ({ Bucket: new Date(start + m * 60_000).toISOString().slice(0, 19), TargetKey: "T5", ResourceName: "cosmos01", Metric, Value, Unit: "Count", WindowStart: "2026-11-20T00:00:00", WindowEnd: "2026-11-24T04:00:00", CapturedAt: "2026-11-24T04:05:00" })),
            ).flat();
        const pager = (all: ReturnType<typeof rows>) => async (spec: QuerySpec) => {
            // A history with T5's Azure Monitor metrics only: Database Hub's bins of T1 to T3 have nothing.
            if (!spec.dax.includes("'Telemetry Snapshots'[Analysis Key]")) return [];
            const m = /\[Bucket UTC\] >= DATE \( (\d+), (\d+), (\d+) \) \+ TIME \( (\d+), (\d+), (\d+) \)/.exec(spec.dax);
            const from = m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : 0;
            return all.filter((r) => Date.parse(`${r.Bucket}Z`) >= from).slice(0, spec.rowLimit);
        };
        const tools = (throttledFrom: number) => createInvestigationTools({ load: async () => emptyEvidence(), telemetry: createRcaSources(pager(rows(throttledFrom))).telemetry, timeZone: "UTC", latestDay: new Date(start), latest: new Date(start + 6000 * 60_000) });
        const window = { from: "2026-11-20T00:00:00Z", to: "2026-11-24T04:00:00Z", targets: ["T5"] };
        const late = tools(5400);
        const listed = (await late.investigate("find_incidents", window)) as InvestigationResult;
        // Quiet is the whole window's (the review of 90e9d914): every target, read on all of them, T5 asked about.
        expect(listed.details).toMatchObject({ nothingAbnormal: false, nothingAbnormalUpTo: "2026-11-23T11:16:00Z", quiet: ["T1", "T2", "T3", "T4", "T4-replica", "T5"], quietUpTo: "2026-11-23T11:16:00Z" });
        const errors = (await late.investigate("explain_errors", window)) as InvestigationResult;
        expect(errors.notCaptured).toContain("No errors, cancels, failed connections, or 429s were recorded up to 11:16:00 UTC, where the read stopped; what came after it wasn't read.");
        expect(errors.notCaptured.join(" ")).not.toMatch(/recorded in the window/);
        const incident = (await late.investigate("explain_incident", { target: "T5", from: window.from, to: window.to })) as InvestigationResult;
        // Across days with its dates (the review of 921d3097): it read "from 00:00:00 up to 11:16:00 UTC", three days apart.
        expect(incident.notCaptured).toContain("Nothing abnormal on T5 from 2026-11-20 00:00:00 up to 2026-11-23 11:16:00 UTC, where the read stopped: the detector found no episode there, and what came after it wasn't read.");
        expect(incident.details).toMatchObject({ nothingAbnormal: false, nothingAbnormalUpTo: "2026-11-23T11:16:00Z" });
        // Counted up to where it stopped: at least, never as if it ended there.
        const counted = (await tools(4900).investigate("explain_errors", window)) as InvestigationResult;
        expect(counted.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(at least 48000, 09:40:00 through 11:16:00 UTC, where the read stopped, mostly the container's clients\)/);
        expect(counted.findings[0].title).toBe("Throttled requests (429): at least 48000");
        // The review of eb89acbb: an incident's part reads only its episode's own minutes, whole, so it says where its
        // incident's read stopped; it read "(48000, 09:40:00 to 11:16:00 UTC ...)" beside its own cut note.
        const storm = (await tools(4900).investigate("explain_incident", { target: "T5", from: window.from, to: window.to })) as InvestigationResult;
        expect(storm.rootCause?.statement).toMatch(/^Most errors were throttled requests \(429\) \(at least 48000, 09:40:00 through 11:16:00 UTC, where the read stopped, mostly the container's clients\)/);
        // And the view says nothing abnormal only up to there (the review of eb89acbb: "Nothing abnormal in these minutes").
        expect(emptyListNote(listed, "America/New_York")).toBe("Nothing abnormal up to 06:16 EST (11:16 UTC), where the read stopped: the detector found no episode there, and what came after it wasn't read.");
        // Its 24,000 rows a read, five reads: 7 to 14 s alone on a loaded PC, past the 15 s default (the review of 90e9d914's run).
    }, 60_000);

    // The review of eb89acbb: T1 to T3's bins and their waits by category, at most 5,000 rows a query and oldest first, lost
    // their newest minutes with no note. The reviewer's probe: T1 with 10 wait categories a minute over 1,000 minutes, and
    // a Tran Log IO storm in minutes 700 to 800, which the first 5,000 rows don't hold.
    it("read Database Hub's bins and waits a page at a time, and say where a read too long for its pages stopped", async () => {
        const start = Date.parse("2026-11-20T00:00:00Z");
        const categories = ["Buffer Latch", "Memory", "Parallelism", "Tran Log IO", "Network IO", "Lock", "Buffer IO", "CPU", "Other", "Preemptive"];
        const bucket = (m: number) => new Date(start + m * 60_000).toISOString().slice(0, 19);
        const history = (minutes: number, stormFrom: number) => ({
            series: Array.from({ length: minutes }, (_, m) => ({ "Bucket UTC": bucket(m), Cpu: 5, Blocked: 0, LockWaitS: 0, BufferIoS: 0, LogRateS: 0, WaitS: 10, IoMb: 1, Batch: 50, Sessions: 8 })),
            waits: Array.from({ length: minutes }, (_, m) => categories.map((Metric) => ({ "Bucket UTC": bucket(m), Metric, WaitS: Metric === "Tran Log IO" && m >= stormFrom && m < stormFrom + 100 ? 40 : 0.5 }))).flat(),
        });
        const pager = (all: ReturnType<typeof history>) =>
            vi.fn(async (spec: QuerySpec) => {
                const m = /\[Bucket UTC\] >= DATE \( (\d+), (\d+), (\d+) \) \+ TIME \( (\d+), (\d+), (\d+) \)/.exec(spec.dax);
                const from = m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : 0;
                // A history with T1's bins and waits only.
                const rows: Array<Record<string, unknown>> = spec.id === "spotlight-T1" ? all.waits : spec.id === "replay-T1" ? all.series : [];
                return rows.filter((r) => Date.parse(`${String(r["Bucket UTC"])}Z`) >= from).slice(0, spec.rowLimit);
            });
        const tools = (run: RunQuery) => createInvestigationTools({ load: async () => emptyEvidence(), telemetry: createRcaSources(run).telemetry, timeZone: "UTC", latestDay: new Date(start), latest: new Date(start + 3000 * 60_000) });
        const whole = pager(history(1000, 700));
        const listed = (await tools(whole).investigate("find_incidents", { from: "2026-11-20T00:00:00Z", to: "2026-11-20T16:40:00Z", targets: ["T1"] })) as InvestigationResult;
        expect((listed.episodes ?? []).map((e) => e.key)).toContain("T1-tran_log-20261120T114000Z");
        expect(listed.details).toMatchObject({ nothingAbnormal: false });
        expect(listed.details?.readStoppedAt).toBeUndefined();
        expect(listed.notCaptured.join(" ")).not.toMatch(/wasn't read/);
        // The waits read three pages, each from the last minute the one before had, whole: 10,000 rows, none twice.
        expect(whole.mock.calls.filter(([spec]) => spec.id === "spotlight-T1")).toHaveLength(3);
        // Longer than its pages hold: what they didn't read is said, and nothing is called quiet past where they stopped.
        const long = (await tools(pager(history(3000, 2700))).investigate("find_incidents", { from: "2026-11-20T00:00:00Z", to: "2026-11-22T02:00:00Z", targets: ["T1"] })) as InvestigationResult;
        expect((long.episodes ?? []).map((e) => e.key)).not.toContain("T1-tran_log-20261121T210000Z");
        expect(long.details).toMatchObject({ nothingAbnormal: false, nothingAbnormalUpTo: "2026-11-21T09:16:00Z", quiet: ["T1", "T2", "T3", "T4", "T4-replica", "T5"], quietUpTo: "2026-11-21T09:16:00Z" });
        expect(long.notCaptured).toContain(`Telemetry Snapshots (T1's waits): the window holds more rows than its ${MONITOR_PAGES} reads of ${MONITOR_ROW_LIMIT} return, so what it holds from 09:16:00 UTC on wasn't read; ask about a narrower window`);
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
