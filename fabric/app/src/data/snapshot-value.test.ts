import { describe, expect, it } from "vitest";

import { f35Check, monitorGrain, snapshotValues, sqlGrain } from "./snapshot-value";

type Row = Record<string, unknown>;

const MIN = 60_000;
const at = (hhmm: string, day = 21) => new Date(`2026-11-${day}T${hhmm}:00Z`);
const key = (target: string, analysis: string, metric: string, hhmm: string, day = 21) => `${target}|${analysis}|${metric}|${at(hhmm, day).getTime()}`;
const minutes = (from: string, values: readonly number[]) => values.map((v, i) => [new Date(at(from).getTime() + i * MIN).toISOString().slice(11, 16), v] as const);
const every = (from: string, step: number, values: readonly number[]) => values.map((v, i) => [new Date(at(from).getTime() + i * step * MIN).toISOString().slice(11, 16), v] as const);

const save = (capturedAt: string, windowStart: string, windowEnd: string) => ({ CapturedAt: capturedAt, WindowStart: windowStart, WindowEnd: windowEnd });
const row = (s: Record<string, string>, target: string, analysis: string, metric: string) => ([bucket, value]: readonly [string, number]): Row => ({ Bucket: `2026-11-21T${bucket}:00`, TargetKey: target, AnalysisKey: analysis, Metric: metric, Value: value, ...s });
// A day-long Azure Monitor save holds a point for each of its 97 intervals, from 21:15 the day before; their count gives its step.
const fullDay = (s: Record<string, string>, target: string, analysis: string, metric: string): Row[] =>
    Array.from({ length: 97 }, (_, i) => ({ Bucket: new Date(Date.parse("2026-11-20T21:15:00Z") + i * 15 * MIN).toISOString(), TargetKey: target, AnalysisKey: analysis, Metric: metric, Value: 1, ...s }));

// A live test's saves (2026-11-21), real values under placeholder names: the session's own, and a day-long one four hours
// later. The session's T5 window is cut to 15:45 here, where its rows stop in the fixture, so its window stands for them.
const T5_SESSION = save("2026-11-21T17:09:30.107", "2026-11-21T15:14:00", "2026-11-21T15:45:00");
const T5_DAY = save("2026-11-21T21:33:44.05", "2026-11-20T21:26:00", "2026-11-21T21:26:00");
const DAY_BUCKETS = ["11:30", "11:45", "12:00", "12:15", "12:30", "12:45", "13:00", "13:15", "13:30", "15:15", "15:30", "15:45"];
const day = (metric: string, values: readonly number[]) => values.map((v, i) => [DAY_BUCKETS[i], v] as const).map(row(T5_DAY, "T5", "cosmosdb", metric));
const session = (metric: string, values: readonly number[]) => minutes("15:15", values).map(row(T5_SESSION, "T5", "cosmosdb", metric));
const T5_ROWS = [
    ...fullDay(T5_DAY, "T5", "cosmosdb", "DataUsage"),
    ...day("TotalRequests", [306, 1030, 930, 8955, 14118, 261, 0, 5, 965, 103, 27630, 23858]),
    ...day("ThrottledRequests", [0, 0, 0, 3860, 6522, 0, 0, 0, 0, 0, 14593, 13215]),
    ...day("NormalizedRUConsumption", [11, 5, 6, 100, 100, 7, 0, 11, 4, 11, 100, 100]),
    ...session("TotalRequests", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 36, 67, 66, 1356, 3837, 3905, 996, 957, 3436, 3922, 1481, 1469, 3932, 2006, 159, 66, 42]),
    ...session("ThrottledRequests", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 680, 2065, 2187, 565, 472, 1805, 2176, 789, 729, 2069, 1039, 17, 0, 0]),
    ...session("NormalizedRUConsumption", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 7, 4, 4, 100, 100, 100, 3, 100, 100, 100, 5, 100, 100, 100, 4, 4, 4]),
];

describe("Snapshot Value's rule in TypeScript, the model's reference (F35)", () => {
    it("takes a SQL save's bin from its window, as the notebook does, and an Azure Monitor save's from its bins", () => {
        const t = (iso: string) => new Date(iso).getTime();
        const bins = (from: string, step: number, count: number) => Array.from({ length: count }, (_, i) => t(from) + i * step * MIN);
        expect([120, 121, 720, 721, 1440].map((m) => sqlGrain(0, m * MIN))).toEqual([1, 5, 5, 15, 15]);
        expect(monitorGrain(t("2026-11-20T21:26:00Z"), t("2026-11-21T21:26:00Z"), bins("2026-11-20T21:15:00Z", 15, 97))).toBe(15);
        expect(monitorGrain(t("2026-11-21T15:14:00Z"), t("2026-11-21T16:57:00Z"), bins("2026-11-21T15:14:00Z", 1, 103))).toBe(1);
        expect(monitorGrain(t("2026-11-21T15:14:00Z"), t("2026-11-21T16:57:00Z"), bins("2026-11-21T15:10:00Z", 5, 22))).toBe(5);
        // A day-long save of a T4 that ran 2 of its hours: 8 bins every 15 minutes, which their count alone reads as 180.
        expect(monitorGrain(t("2026-11-20T21:25:00Z"), t("2026-11-21T21:26:00Z"), bins("2026-11-21T19:15:00Z", 15, 8))).toBe(15);
        expect(monitorGrain(0, 60 * MIN, [])).toBe(60);
    });

    it("drops the day-long save's covered 15-minute totals and keeps the session's own minutes, so T5's totals equal finestPerInterval's", () => {
        const values = snapshotValues(T5_ROWS);
        // The session's own minutes at 15:15 and 15:30, and not the day's 103 and 27,630 that hold them.
        expect(values.get(key("T5", "cosmosdb", "TotalRequests", "15:15"))).toBe(0);
        expect(values.get(key("T5", "cosmosdb", "TotalRequests", "15:30"))).toBe(66);
        expect(values.get(key("T5", "cosmosdb", "TotalRequests", "15:32"))).toBe(3837);
        expect(values.get(key("T5", "cosmosdb", "TotalRequests", "15:45"))).toBe(23858);
        const check = f35Check(T5_ROWS, at("15:00"), at("16:00"));
        // Today's newest-per-bin rule gives 79,258: it keeps the day's 103 and 27,630 beside the minutes they hold.
        expect(check.measures.T5.Requests).toEqual({ model: 51591, finest: 51591 });
        expect(check.measures.T5.Throttled).toEqual({ model: 27808, finest: 27808 });
        expect(check.measures.T5.NormRuPeak).toEqual({ model: 100, finest: 100 });
    });

    it("keeps the day's 34 s of replica lag at its own bin's start, 16:45, where finestPerInterval puts it at 16:57; the peak is the same", () => {
        const s = save("2026-11-21T17:09:30.083", "2026-11-21T15:14:00", "2026-11-21T16:57:00");
        const d = save("2026-11-21T21:33:42.797", "2026-11-20T21:25:00", "2026-11-21T21:26:00");
        const lag = (x: Record<string, string>) => row(x, "T4-replica", "postgresql", "physical_replication_delay_in_seconds");
        const rows = [
            ...every("15:40", 5, [1, 2, 1, 2, 2, 2, 1, 148, 178, 2, 2, 1, 1, 1, 1, 8]).map(lag(s)),
            ...every("15:45", 15, [2, 2, 178, 2, 34]).map(lag(d)),
            ...fullDay(d, "T4-replica", "postgresql", "cpu_percent"),
        ];
        const values = snapshotValues(rows);
        const lagAt = (hhmm: string) => values.get(key("T4-replica", "postgresql", "physical_replication_delay_in_seconds", hhmm));
        expect(["16:15", "16:20", "16:40", "16:45", "16:50", "16:55"].map(lagAt)).toEqual([148, 178, 1, 34, 1, 8]);
        expect(Math.max(...[...values.entries()].filter(([k]) => k.includes("physical_replication")).map(([, v]) => v))).toBe(178);
    });

    // A SQL save's window starts and ends inside its first and last minutes (the notebook's, to the second).
    const SQL_SESSION = save("2026-11-21T17:09:00", "2026-11-21T15:14:23", "2026-11-21T16:57:10");
    const SQL_DAY = save("2026-11-21T21:33:00", "2026-11-20T21:33:00", "2026-11-21T21:33:00");

    it("keeps a SQL total's remainder for the minutes before and after the session's window, so the window's total is finestPerInterval's", () => {
        const lock = (x: Record<string, string>) => row(x, "T1", "wait_deltas", "Lock");
        const rows = [
            ...([["15:14", 100], ["16:50", 100], ["16:56", 150]] as const).map(lock(SQL_SESSION)),
            ...([["14:45", 40], ["15:00", 300], ["16:45", 500], ["17:00", 70]] as const).map(lock(SQL_DAY)),
            // The session's CPU, every minute, gives it rows of its own beside the sparse lock waits.
            ...minutes("15:14", Array.from({ length: 104 }, () => 20)).map(row(SQL_SESSION, "T1", "cpu", "MaxCPU")),
        ];
        const values = snapshotValues(rows);
        const lockAt = (hhmm: string) => values.get(key("T1", "wait_deltas", "Lock", hhmm));
        // 15:00's 300 less the session's 100 from 15:14:23; 16:45's 500 less its 250 before 16:57:10.
        expect(["15:00", "15:14", "16:45", "16:50", "16:56", "17:00"].map(lockAt)).toEqual([200, 100, 250, 100, 150, 70]);
        const check = f35Check(rows, at("15:00"), at("17:15"));
        // 200 + 100 + 250 + 100 + 150 + 70 ms. Today's newest-per-bin rule gives 1.22 s: the session's 100 and 250 twice.
        expect(check.measures.T1.LockWaitS.model).toBeCloseTo(0.87, 9);
        expect(check.measures.T1.LockWaitS.finest).toBeCloseTo(0.87, 9);
    });

    it("keeps a coarser SQL peak for the minutes outside the session's window only when it's higher", () => {
        const cpu = (x: Record<string, string>) => row(x, "T1", "cpu", "MaxCPU");
        const rows = [...minutes("15:14", Array.from({ length: 104 }, () => 40)).map(cpu(SQL_SESSION)), ...([["14:45", 30], ["15:00", 90], ["16:45", 35], ["17:00", 50]] as const).map(cpu(SQL_DAY))];
        const values = snapshotValues(rows);
        const cpuAt = (hhmm: string) => values.get(key("T1", "cpu", "MaxCPU", hhmm));
        expect(["15:00", "15:14", "16:45", "16:57", "17:00"].map(cpuAt)).toEqual([90, 40, 40, 40, 50]);
        expect(f35Check(rows, at("15:00"), at("17:15")).measures.T1.CpuPeak).toEqual({ model: 90, finest: 90 });
    });

    it("keeps an older day-long save's total only for the minutes before a newer one's window starts", () => {
        const older = save("2026-11-21T14:07:00", "2026-11-20T14:00:00", "2026-11-21T14:00:00");
        const newer = save("2026-11-21T21:33:00", "2026-11-20T21:26:00", "2026-11-21T21:26:00");
        const lock = (x: Record<string, string>) => (bucket: string, value: number): Row => ({ ...row(x, "T2", "wait_deltas", "Lock")([bucket, value]), Bucket: `2026-11-20T${bucket}:00` });
        const rows = [lock(older)("21:00", 10), lock(older)("21:15", 90), lock(newer)("21:15", 30), lock(newer)("21:30", 50)];
        const values = snapshotValues(rows);
        // The newer save's 21:15 holds 21:26 to 21:30 (30), the older's the whole 15 minutes (90): 60 is from before 21:26.
        expect(values.get(key("T2", "wait_deltas", "Lock", "21:15", 20))).toBe(90);
        expect(values.get(key("T2", "wait_deltas", "Lock", "21:30", 20))).toBe(50);
    });

    it("keeps the newest capture of an analysis off the bin grid, as before", () => {
        const a = save("2026-11-21T17:09:00", "2026-11-21T15:14:00", "2026-11-21T16:57:00");
        const b = save("2026-11-21T21:33:00", "2026-11-20T21:33:00", "2026-11-21T21:33:00");
        const profile = (x: Record<string, string>, value: number): Row => ({ Bucket: null, TargetKey: "T3", AnalysisKey: "wait_profile", Metric: "Lock", Value: value, ...x });
        expect(snapshotValues([profile(a, 5), profile(b, 7), profile(b, 1)]).get("T3|wait_profile|Lock|")).toBe(8);
    });

    it("reads a row with no bin and no value as a save only, with its rows' extent, as rows-saves.dax exports one for each save near the session", () => {
        const older = save("2026-11-21T16:00:00", "2026-11-20T16:00:00", "2026-11-21T16:00:00");
        const newer = save("2026-11-21T21:33:00", "2026-11-20T21:33:00", "2026-11-21T21:33:00");
        const rows: Row[] = [row(older, "T1", "wait_deltas", "Lock")(["15:15", 60])];
        // The newer save's lock waits are all outside the rows exported; its marker says it has one in every 15 minutes from
        // 12:00 to 18:00, so they cover 15:15.
        const marker: Row = { Bucket: null, TargetKey: "T1", AnalysisKey: "wait_deltas", Metric: "Lock", Value: null, First: "2026-11-21T12:00:00", Last: "2026-11-21T18:00:00", Count: 25, ...newer };
        expect(snapshotValues(rows).get(key("T1", "wait_deltas", "Lock", "15:15"))).toBe(60);
        expect(snapshotValues([...rows, marker]).has(key("T1", "wait_deltas", "Lock", "15:15"))).toBe(false);
        expect(f35Check([...rows, marker], at("15:00"), at("17:15")).bins).toEqual({});
        // With an interval missing, its rows decide, and none of those exported is at 15:15.
        expect(snapshotValues([...rows, { ...marker, Count: 24 }]).get(key("T1", "wait_deltas", "Lock", "15:15"))).toBe(60);
    });

    // 602e18a1 on the live test's model: a finer save's window stood for its rows, so a coarser point inside it was left out
    // even where the finer rows didn't hold what it did. Now the rows decide, as in finestPerInterval.
    describe("coverage by rows, not by windows", () => {
        const session = save("2026-11-21T17:15:00", "2026-11-21T15:19:04", "2026-11-21T16:59:04");
        const day = save("2026-11-21T21:33:00", "2026-11-20T21:33:00", "2026-11-21T21:33:00");
        const expectWindow = (rows: Row[], target: string, seconds: number) => {
            const { model, finest } = f35Check(rows, at("15:00"), at("17:15")).measures[target].LockWaitS;
            expect(model).toBeCloseTo(seconds, 9);
            expect(finest).toBeCloseTo(seconds, 9);
        };

        it("keeps a coarser total where the session's rows start after its window does", () => {
            // The session's window starts at 15:19:04, its rows of T1 at 15:31: the day's 15:30 holds 1,204 ms more than they.
            const lock = (s: Record<string, string>) => row(s, "T1", "wait_deltas", "Lock");
            const rows = [...minutes("15:31", Array.from({ length: 88 }, () => 60)).map(lock(session)), ...every("15:00", 15, [900, 900, 2044, 900, 900, 900, 900, 900, 900]).map(lock(day))];
            const values = snapshotValues(rows);
            const lockAt = (hhmm: string) => values.get(key("T1", "wait_deltas", "Lock", hhmm));
            // Before its rows, the day's points stay whole; inside them, they're left out; at 16:45, 16:59 to 17:00 stays.
            expect(["15:15", "15:30", "15:45", "16:45", "17:00"].map(lockAt)).toEqual([900, 1204, 60, 120, 900]);
            expectWindow(rows, "T1", 9.244);
        });

        it("keeps a coarser total's remainder where a sparse finer series has minutes without a row", () => {
            // T2's lock waits in the session are sparse: the day's 15:45 holds 100 ms in minutes the session has no row for.
            const lock = (s: Record<string, string>) => row(s, "T2", "wait_deltas", "Lock");
            const rows = [
                ...(
                    [
                        ["15:47", 300],
                        ["15:52", 200],
                        ["16:10", 50],
                    ] as const
                ).map(lock(session)),
                ...(
                    [
                        ["15:45", 600],
                        ["16:00", 50],
                    ] as const
                ).map(lock(day)),
            ];
            const values = snapshotValues(rows);
            const lockAt = (hhmm: string) => values.get(key("T2", "wait_deltas", "Lock", hhmm));
            expect(["15:45", "15:47", "15:52", "16:00", "16:10"].map(lockAt)).toEqual([100, 300, 200, 0, 50]);
            expectWindow(rows, "T2", 0.65);
        });
    });

    // The review of 602e18a1: three saves at 1, 5, and 15 minutes, with T1's lock waits of 60 ms a minute in each. A bin's
    // finest row stood for its 5-minute row too, so the day's remainder at 16:45 left out the minutes that only the 5-minute
    // row held, and they counted twice: 1,080 ms for 16:45 to 17:00, and 10,980 for 15:00 to 18:00, where 900 and 10,800 are.
    describe("three saves at 1, 5, and 15 minutes", () => {
        const lock = (s: Record<string, string>, from: string, step: number, count: number, cut: Record<string, number> = {}) =>
            every(from, step, Array.from({ length: count }, () => 60 * step)).map(([bucket, value]) => row(s, "T1", "wait_deltas", "Lock")([bucket, cut[bucket] ?? value]));
        const day = lock(save("2026-11-21T21:33:00", "2026-11-20T21:33:00", "2026-11-21T21:33:00"), "14:00", 15, 20);
        const lockAt = (rows: Row[], hhmm: string) => snapshotValues(rows).get(key("T1", "wait_deltas", "Lock", hhmm));
        const expectWindow = (rows: Row[]) => {
            const { model, finest } = f35Check(rows, at("15:00"), at("18:00")).measures.T1.LockWaitS;
            expect(model).toBeCloseTo(10.8, 9);
            expect(finest).toBeCloseTo(10.8, 9);
        };

        it("counts each minute once after a Run all session, stop-demo.ps1 -SaveHistory, and an update", () => {
            const session = lock(save("2026-11-21T17:02:00", "2026-11-21T15:14:00", "2026-11-21T16:47:00"), "15:14", 1, 93);
            const stop = lock(save("2026-11-21T17:13:00", "2026-11-21T04:58:00", "2026-11-21T16:58:00"), "14:00", 5, 36, { "16:55": 180 });
            const rows = [...session, ...stop, ...day];
            // At 16:45: the session's 60, the 5-minute save's 180 for 16:47 to 16:50, and the day's 120 for 16:58 to 17:00.
            expect(lockAt(rows, "16:45")).toBe(360);
            expectWindow(rows);
        });

        it("counts each minute once after back-to-back sessions saved at 1 and 5 minutes, and an update", () => {
            const first = lock(save("2026-11-21T17:02:00", "2026-11-21T15:14:00", "2026-11-21T16:47:00"), "15:14", 1, 93);
            const second = lock(save("2026-11-21T20:13:00", "2026-11-21T16:47:00", "2026-11-21T19:58:00"), "16:45", 5, 39, { "16:45": 180, "19:55": 180 });
            const rows = [...first, ...second, ...day];
            // The sessions hold all of 16:45 to 17:00 between them, so the day adds nothing there: 60 and 180.
            expect(lockAt(rows, "16:45")).toBe(240);
            expectWindow(rows);
        });
    });
});
