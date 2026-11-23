import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { ADDITIVE_ANALYSES, ADDITIVE_METRICS, addsUp, finestPerInterval, HOURLY_METRICS, OFF_GRID_ANALYSES } from "./finest-per-interval";
import { monitorGrain, snapshotValues, sqlGrain } from "./snapshot-value";

// F35 design (i)'s shared cases (fabric/history/kept-value-cases.json): rows of the history, and each bin's value by
// snapshotValues, the TypeScript rule. fabric/history/kept_value.py's kept values, read per bin as the model would read
// them, must give the same values (tests/unit/Fabric.History.Tests.ps1). This test builds the file from the cases below
// and the rule, and fails while the committed file differs: after a change to either, run it with
// DBHUB_WRITE_KEPT_VALUE_CASES=1 to write the file, and review the difference. Most saves are written as before F35's
// declared grain, so the rules read their step as today; the cases named "declared grains" declare it, as the notebook
// now does with each save.

type Row = Record<string, unknown>;
/** target, analysis, metric, bin, capture, window start, window end, value, and the save's declared grain (minutes) if any; times in seconds after the cases' base. */
type CaseRow = [string, string, string, number | null, number, number, number, number | null, number?];
/** target, analysis, metric, bin (seconds after the base, or null), value. */
type CaseBin = [string, string, string, number | null, number];
interface Case {
    name: string;
    rows: CaseRow[];
}

const root = join(process.cwd(), "..", "..");
const FILE = join(root, "fabric", "history", "kept-value-cases.json");
const BASE = Date.UTC(2026, 10, 21);
const DAY = 86_400;

/** Seconds after the base: "15:30", or "15:30:20", on the base's day, or `day` days from it. */
const s = (hhmm: string, day = 0) => {
    const [h, m, sec] = hhmm.split(":").map(Number);
    return day * DAY + h * 3600 + m * 60 + (sec || 0);
};
interface Save {
    captured: number;
    start: number;
    end: number;
    /** The grain it declares, in minutes, as the notebook writes it in grain_minutes since F35; none for an older save. */
    grain?: number;
}
const save = (captured: string, start: string, end: string, startDay = 0, grain?: number): Save => ({ captured: s(captured), start: s(start, startDay), end: s(end), grain });
/** A day-long save, as deploy.ps1's history snapshot writes it at the end of an update. */
const daySave = (captured = "21:33:44") => save(captured, "21:26", "21:26", -1);
/** A save's rows of one series, every `step` minutes from `from`; a null skips that bin. */
const series = (sv: Save, target: string, analysis: string, metric: string, from: string, step: number, values: ReadonlyArray<number | null>): CaseRow[] =>
    values.flatMap((v, i): CaseRow[] => {
        if (v === null) return [];
        const at = s(from) + i * step * 60;
        return [sv.grain === undefined ? [target, analysis, metric, at, sv.captured, sv.start, sv.end, v] : [target, analysis, metric, at, sv.captured, sv.start, sv.end, v, sv.grain]];
    });
const repeat = (value: number, count: number) => Array.from({ length: count }, () => value);

const NAMED: Case[] = [
    {
        // The live test's double count (2026-11-21): the day save's 15-minute totals beside the session's own minutes.
        name: "a session's minutes and a day save's 15-minute totals: the day keeps only what the session doesn't hold",
        rows: [
            ...series(save("17:09:30.107", "15:14", "15:45"), "T5", "cosmosdb", "TotalRequests", "15:14", 1, Array.from({ length: 31 }, (_, i) => 800 + 10 * i)),
            ...series(daySave(), "T5", "cosmosdb", "TotalRequests", "14:45", 15, [9000, 12000, 15500, 14000, 9000]),
        ],
    },
    {
        // The replica's 34 s of lag from 16:57 to 17:00, after the session's window ended (2026-11-21).
        name: "a peak after the session's window: the day save's lag from 16:57 to 17:00 stays",
        rows: [
            ...series(save("17:05", "16:00", "16:57"), "T4-replica", "postgresql", "physical_replication_delay_in_seconds", "16:00", 5, [2, 3, 5, 4, 3, 2, 8, 6, 4, 3, 2, 1]),
            ...series(daySave("21:30"), "T4-replica", "postgresql", "physical_replication_delay_in_seconds", "16:00", 15, [5, 8, 4, 34]),
        ],
    },
    {
        // The review of 30392d79: a stop save whose last minutes have no rows yet, and a later day save that holds them.
        name: "a stop save whose last minutes have no rows: the later day save keeps them",
        rows: [
            ...series(save("18:07:30", "15:00", "18:07"), "T1", "counter_deltas", "Batch Requests/sec", "17:00", 5, repeat(300, 11)),
            ...series(daySave("21:30"), "T1", "counter_deltas", "Batch Requests/sec", "17:00", 15, repeat(900, 5)),
        ],
    },
    {
        // The same review's bound: partly arrived rows in a stop save's last bins replace the day save's complete ones.
        name: "partly arrived rows in a stop save's last bins: short by what hadn't arrived, at most one 15-minute bin",
        rows: [
            ...series(save("18:07:30", "15:00", "18:07"), "T1", "wait_deltas", "Lock", "17:00", 5, [...repeat(300, 11), 120, 60]),
            ...series(daySave("21:30"), "T1", "wait_deltas", "Lock", "17:00", 15, repeat(900, 5)),
        ],
    },
    {
        name: "three grains: a 1-minute session, a 5-minute stop save, and a 15-minute day save",
        rows: [
            ...series(save("16:31", "15:31", "16:31"), "T2", "wait_deltas", "Lock", "15:31", 1, repeat(10, 29)),
            ...series(save("17:00:30", "14:00", "17:00"), "T2", "wait_deltas", "Lock", "15:00", 5, repeat(60, 24)),
            ...series(daySave("21:30"), "T2", "wait_deltas", "Lock", "15:00", 15, repeat(180, 8)),
        ],
    },
    {
        name: "a peak lower than the finer points it overlaps is dropped",
        rows: [
            ...series(save("16:00", "15:00", "15:40"), "T2", "cpu", "MaxCPU", "15:00", 1, [...repeat(30, 10), 50, ...repeat(30, 29)]),
            ...series(daySave("21:30"), "T2", "cpu", "MaxCPU", "15:00", 15, [40, 45, 25, 60]),
        ],
    },
    {
        name: "a peak higher than the finer points it overlaps stays",
        rows: [
            ...series(save("16:00", "15:00", "15:40"), "T2", "cpu", "MaxCPU", "15:00", 1, [...repeat(30, 10), 50, ...repeat(30, 29)]),
            ...series(daySave("21:30"), "T2", "cpu", "MaxCPU", "15:00", 15, [40, 45, 70, 60]),
        ],
    },
    {
        name: "Azure Monitor: a day save of a T4 that ran a few hours keeps its 5-minute step",
        rows: [
            ...series(save("16:10", "15:30", "16:00"), "T4", "postgresql", "cpu_percent", "15:30", 1, repeat(30, 30)),
            ...series(daySave("21:30"), "T4", "postgresql", "cpu_percent", "15:00", 5, Array.from({ length: 24 }, (_, i) => 20 + (i % 7))),
        ],
    },
    {
        name: "an hourly metric: the newer save of the same hour wins",
        rows: [
            ...series(save("16:10", "15:14", "16:05"), "T5", "cosmosdb", "ProvisionedThroughput", "15:00", 60, [400, 400]),
            ...series(daySave("21:30"), "T5", "cosmosdb", "ProvisionedThroughput", "14:00", 60, [400, 1000, 1000, 400]),
        ],
    },
    {
        name: "off the bin grid: the newest capture",
        rows: [
            ["T1", "wait_profile", "LCK_M_X", null, s("16:00"), s("15:00"), s("15:40"), 100],
            ["T1", "wait_profile", "LCK_M_X", null, s("21:30"), s("21:26", -1), s("21:26"), 150],
            ["T1", "memory_clerks", "MEMORYCLERK_SQLBUFFERPOOL", s("15:59"), s("16:00"), s("15:00"), s("15:40"), 2048],
            ["T1", "memory_clerks", "MEMORYCLERK_SQLBUFFERPOOL", s("15:59"), s("21:30"), s("21:26", -1), s("21:26"), 4096],
        ],
    },
    {
        name: "the same grain: the newer save wins where they overlap",
        rows: [
            ...series(save("16:00", "15:00", "15:40"), "T3", "counter_deltas", "Batch Requests/sec", "15:00", 1, repeat(10, 40)),
            ...series(save("16:30", "15:20", "16:00"), "T3", "counter_deltas", "Batch Requests/sec", "15:20", 1, repeat(20, 40)),
        ],
    },
    {
        name: "a total over two files of one save: what's left is split by their values",
        rows: [
            ...series(save("16:00", "15:00", "15:40"), "T3", "storage_io", "ReadMB", "15:00", 1, repeat(10, 40)),
            ...series(daySave("21:30"), "T3", "storage_io", "ReadMB", "15:00", 15, [200, 200, 300, 120]),
            ...series(daySave("21:30"), "T3", "storage_io", "ReadMB", "15:00", 15, [100, 100, 150, 60]),
        ],
    },
    {
        name: "nothing finer: every row keeps its value",
        rows: series(daySave("21:30"), "T1", "sessions", "MaxSessions", "15:00", 15, [12, 15, 9, 20]),
    },
    {
        name: "a binned row without a value counts as 0, and a row with no bin is the newest capture's",
        rows: [
            ...series(save("16:00", "15:00", "15:40"), "T2", "gauges", "Processes blocked", "15:00", 1, [1, 0, 2]),
            ["T2", "gauges", "Processes blocked", s("15:03"), s("16:00"), s("15:00"), s("15:40"), null],
            ["T2", "gauges", "Processes blocked", null, s("16:00"), s("15:00"), s("15:40"), null],
            ["T2", "counter_deltas", "Number of Deadlocks/sec", null, s("16:00"), s("15:00"), s("15:40"), 3],
            ["T2", "counter_deltas", "Number of Deadlocks/sec", null, s("21:30"), s("21:26", -1), s("21:26"), 5],
        ],
    },
    {
        // 201a6666's review of 88ece0f9: no case reached a fourth finer save. Four 1-minute saves and a 5-minute one in the
        // day save's 15:15 interval, each taken against every earlier one, as finestPerInterval takes them (the review of
        // 79a35e57): the minutes hold all of the 5-minute save's two points, so it keeps nothing there.
        name: "five finer saves in one coarse interval: each against every earlier one",
        rows: [
            ...series(save("16:05", "15:15", "15:18"), "T1", "wait_deltas", "Lock", "15:15", 1, repeat(10, 3)),
            ...series(save("16:04", "15:16", "15:20"), "T1", "wait_deltas", "Lock", "15:16", 1, repeat(12, 4)),
            ...series(save("16:03", "15:18", "15:22"), "T1", "wait_deltas", "Lock", "15:18", 1, repeat(14, 4)),
            ...series(save("16:02", "15:20", "15:25"), "T1", "wait_deltas", "Lock", "15:20", 1, repeat(16, 5)),
            ...series(save("16:20", "14:00", "16:10"), "T1", "wait_deltas", "Lock", "15:15", 5, [70, 80]),
            ...series(daySave("21:30"), "T1", "wait_deltas", "Lock", "15:00", 15, repeat(900, 4)),
        ],
    },
    {
        // The review of 4944e22d: a finer save whose rows fall only in the part of a coarser interval that the coarser save's
        // window cuts off. Background load of 4 a minute; a session from 15:16 to 15:22 at 10 a minute, saved every minute;
        // stop-demo.ps1 -SaveHistory at 15:24, whose 15:20 bin is cut to 15:20 to 15:24; and the next day's update at 15:22,
        // whose day save's window starts at 15:22. The data hold 96 from 15:15 to 15:30.
        name: "a finer save only where a coarser save's window cuts its interval off",
        rows: [
            ...series(save("15:23", "15:16", "15:22"), "T1", "counter_deltas", "Batch Requests/sec", "15:16", 1, repeat(10, 6)),
            ...series(save("15:24:30", "03:24", "15:24"), "T1", "counter_deltas", "Batch Requests/sec", "15:15", 5, [44, 28]),
            ...series({ captured: s("15:33", 1), start: s("15:22"), end: s("15:22", 1) }, "T1", "counter_deltas", "Batch Requests/sec", "15:15", 15, [32, 60]),
        ],
    },
    {
        // The review of 67f08e7d: a finer row straddles a coarser save's window cut, and part of what's left of it is in the
        // part cut off. Both rules split it across the row's uncovered stretches by length, as finestPerInterval does, and
        // the coarser point takes only the stretches that overlap the part its window keeps (design (i)'s build; before it,
        // this rule counted all of it there). As the case above, but the session's Lock waits are quiet at 15:20, a bin
        // WAITS_KQL leaves out (WaitMs > 0): the stop save's 15:20 holds 18, 10 at 15:21 and 8 from 15:22 to 15:24. The
        // split gives the quiet 15:20 3 of the 8, by length, so 15:15 to 15:30 totals 89 where the data hold 86.
        name: "a quiet minute in a finer row that a coarser save's window cuts through",
        rows: [
            ...series(save("15:23", "15:16", "15:22"), "T1", "wait_deltas", "Lock", "15:16", 1, [10, 10, 10, 10, null, 10]),
            ...series(save("15:24:30", "03:24", "15:24"), "T1", "wait_deltas", "Lock", "15:15", 5, [44, 18]),
            ...series({ captured: s("15:33", 1), start: s("15:22"), end: s("15:22", 1) }, "T1", "wait_deltas", "Lock", "15:15", 15, [32, 60]),
        ],
    },
    {
        // The same cut the other way: a session from 15:21 to 15:23 at 10 a minute. The stop save's 15:20 holds 28, 8 of
        // it beside the session's minutes: 4 at 15:20, which the day's window cuts off, and 4 at 15:23. The split gives each
        // 4, so 15:15 to 15:30 totals 72, the data's answer; counting all 8 against the day's part gave 68.
        name: "what's left of a finer row on both sides of a coarser save's window cut",
        rows: [
            ...series(save("15:23:30", "15:21", "15:23"), "T1", "counter_deltas", "Batch Requests/sec", "15:21", 1, [10, 10]),
            ...series(save("15:24:30", "03:24", "15:24"), "T1", "counter_deltas", "Batch Requests/sec", "15:15", 5, [20, 28]),
            ...series({ captured: s("15:33", 1), start: s("15:22"), end: s("15:22", 1) }, "T1", "counter_deltas", "Batch Requests/sec", "15:15", 15, [38, 60]),
        ],
    },
    {
        // F35's declared grain: a save's step is the grain its rows declare. A notebook run with a hand-set BIN_MINUTES of 5
        // over an hour, which its window alone reads as 1-minute bins, holds all of the day save's 15:00 interval, 150 of
        // its 200: declared, the day's point is left out there, where read as 1-minute bins its rows left gaps and the day
        // kept 50 more.
        name: "declared grains: a hand-set 5-minute bin, which the window alone reads as 1",
        rows: [
            ...series(save("16:05", "15:00", "16:00", 0, 5), "T1", "counter_deltas", "Batch Requests/sec", "15:00", 5, [50, 50, 50, 40]),
            ...series({ ...daySave("21:30"), grain: 15 }, "T1", "counter_deltas", "Batch Requests/sec", "15:00", 15, [200, 160]),
        ],
    },
    {
        // random 11's shape, declared: a newer save of 900 minutes holds three rows of T2's sessions, 30 minutes apart, and
        // no other series. Its bins don't show its 15-minute step, so finestPerInterval read it as 30 and left its 43 out
        // at 15:30; declared, both rules take it as the finer save, and its 43 is the hour's peak.
        name: "declared grains: a save whose bins don't show its step",
        rows: [
            ...series(save("16:30", "01:30", "16:30", 0, 15), "T2", "sessions", "MaxSessions", "15:00", 15, [5, 7, 6, 4]),
            ...series(save("17:00", "02:00", "17:00", 0, 15), "T2", "sessions", "MaxSessions", "15:00", 30, [10, 43, 8]),
        ],
    },
];

/** A seeded generator (mulberry32), so the random cases are the same on every run. */
function generator(seed: number): () => number {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
    };
}

/**
 * Random SQL saves of one series around 16:00, at the notebook's grains, with gaps, windows that cut bins, and two files:
 * 2 to 4 saves a case by default, or `saveCount`'s range, so a coarse point can have a fourth finer save (rank 4 and later).
 */
function randomCases(count: number, seed: number, saveCount: readonly [number, number] = [2, 4], label = "random"): Case[] {
    const random = generator(seed);
    const int = (lo: number, hi: number) => lo + Math.floor(random() * (hi - lo + 1));
    const pick = <T>(items: readonly T[]): T => items[Math.floor(random() * items.length)];
    const kinds: ReadonlyArray<[string, string, string, number]> = [
        ["T1", "counter_deltas", "Batch Requests/sec", 400],
        ["T1", "wait_deltas", "Lock", 900],
        ["T2", "cpu", "MaxCPU", 100],
        ["T2", "sessions", "MaxSessions", 60],
        ["T3", "storage_io", "ReadMB", 250],
    ];
    const cases: Case[] = [];
    for (let n = 0; n < count; n++) {
        const [target, analysis, metric, top] = pick(kinds);
        const rows: CaseRow[] = [];
        const saves = int(saveCount[0], saveCount[1]);
        for (let k = 0; k < saves; k++) {
            const span = pick([20, 30, 45, 180, 400, 900, 1440]);
            const start = s("16:00") - int(1, span) * 60 + int(-20, 20) * 60 + (random() < 0.2 ? int(1, 59) : 0);
            const end = start + span * 60;
            const grain = span <= 120 ? 1 : span <= 720 ? 5 : 15;
            const captured = end + int(30, 900) + k;
            // Bins on the grain's grid from midnight, inside the save's window, and between 15:00 and 17:00.
            const first = Math.max(Math.floor(start / (grain * 60)) * grain * 60, s("15:00"));
            const last = Math.min(Math.floor((end - 1) / (grain * 60)) * grain * 60, s("17:00"));
            const files = analysis === "storage_io" && random() < 0.5 ? 2 : 1;
            for (let at = first; at <= last; at += grain * 60) {
                if (random() < 0.2) continue;
                for (let f = 0; f < files; f++) rows.push([target, analysis, metric, at, captured, start, end, int(0, top)]);
            }
        }
        cases.push({ name: `${label} ${n + 1}`, rows });
    }
    return cases;
}

// The first 20 as before; 10 more with 5 saves each, so random shapes reach rank 4 and later (201a6666's review of 88ece0f9).
const CASES: Case[] = [...NAMED, ...randomCases(20, 20_261_122), ...randomCases(10, 20_261_123, [5, 5], "random with 5 saves")];

const toRow = ([target, analysis, metric, bucket, captured, start, end, value, grain]: CaseRow): Row => ({
    TargetKey: target,
    AnalysisKey: analysis,
    Metric: metric,
    Bucket: bucket === null ? null : BASE + Math.round(bucket * 1000),
    CapturedAt: BASE + Math.round(captured * 1000),
    WindowStart: BASE + Math.round(start * 1000),
    WindowEnd: BASE + Math.round(end * 1000),
    Value: value,
    ...(grain === undefined ? {} : { GrainMinutes: grain }),
});

const MONITOR_ANALYSES = new Set(["postgresql", "cosmosdb"]);

/**
 * The rows as their saves would be written since F35, each declaring its grain: the one the rule reads today, the
 * notebook's from a SQL save's window and Azure Monitor's from a save's window and bins (an hourly metric's at least an
 * hour), which is what the notebook and the history helpers declare. A row off the bin grid declares none.
 */
function withDeclaredGrains(rows: readonly CaseRow[]): CaseRow[] {
    const ms = (seconds: number) => BASE + Math.round(seconds * 1000);
    const bins = new Map<string, number[]>();
    for (const [target, analysis, metric, bin, captured] of rows) {
        if (bin === null || HOURLY_METRICS.has(metric)) continue;
        const key = `${target}|${analysis}|${captured}`;
        bins.set(key, [...(bins.get(key) ?? []), ms(bin)]);
    }
    return rows.map((r): CaseRow => {
        const [target, analysis, metric, bin, captured, start, end, value, grain] = r;
        if (grain !== undefined || bin === null || OFF_GRID_ANALYSES.has(analysis)) return r;
        const step = MONITOR_ANALYSES.has(analysis) ? monitorGrain(ms(start), ms(end), bins.get(`${target}|${analysis}|${captured}`) ?? []) : sqlGrain(ms(start), ms(end));
        return [target, analysis, metric, bin, captured, start, end, value, HOURLY_METRICS.has(metric) ? Math.max(60, step) : step];
    });
}

/** Each bin's value by snapshotValues, in the rule's own order. */
function binsOf(rows: readonly CaseRow[]): CaseBin[] {
    const bins: CaseBin[] = [];
    for (const [key, value] of snapshotValues(rows.map(toRow))) {
        const [target, analysis, metric, binText] = key.split("|");
        bins.push([target, analysis, metric, binText === "" ? null : (Number(binText) - BASE) / 1000, value]);
    }
    return bins;
}

const HOUR = 3_600_000;

/**
 * Each series' total (a count, a total, or a delta) or peak in each hour, by `target|analysis|metric|hour`: from
 * snapshotValues' bins (model), and from finestPerInterval's kept points (finest), given the rows as f35Check gives them,
 * one per save, series, and bin. Off the bin grid, neither: finestPerInterval never sees those rows. An hour holds every
 * grain in the cases, so a remainder that the two rules place at different starts stays in its hour.
 */
function hourlyWindows(rows: readonly CaseRow[]): { model: Map<string, number>; finest: Map<string, number> } {
    const fold = (map: Map<string, number>, key: string, adds: boolean, value: number) => {
        const before = map.get(key);
        map.set(key, before === undefined ? value : adds ? before + value : Math.max(before, value));
    };
    const model = new Map<string, number>();
    for (const [key, value] of snapshotValues(rows.map(toRow))) {
        const [target, analysis, metric, binText] = key.split("|");
        if (binText === "" || OFF_GRID_ANALYSES.has(analysis)) continue;
        const hour = new Date(Math.floor(Number(binText) / HOUR) * HOUR).toISOString();
        fold(model, `${target}|${analysis}|${metric}|${hour}`, ADDITIVE_ANALYSES.has(analysis) || ADDITIVE_METRICS.has(metric), value);
    }
    const grouped = new Map<string, Row>();
    for (const row of rows.map(toRow)) {
        if (row.Bucket === null || OFF_GRID_ANALYSES.has(String(row.AnalysisKey))) continue;
        const key = `${String(row.TargetKey)}|${String(row.AnalysisKey)}|${String(row.Metric)}|${String(row.Bucket)}|${String(row.CapturedAt)}`;
        const before = grouped.get(key);
        grouped.set(key, before ? { ...before, Value: Number(before.Value) + Number(row.Value) } : { ...row, Value: Number(row.Value) });
    }
    const finest = new Map<string, number>();
    for (const row of finestPerInterval([...grouped.values()]).kept) {
        const hour = new Date(Math.floor(Number(row.Bucket) / HOUR) * HOUR).toISOString();
        fold(finest, `${String(row.TargetKey)}|${String(row.AnalysisKey)}|${String(row.Metric)}|${hour}`, addsUp(row), Number(row.Value));
    }
    return { model, finest };
}

/**
 * The file, one row or bin a line, so a change reads as a diff. Each case lists its series (target, analysis, metric)
 * and its saves (capture, window start, window end, and the grain it declares, when it does) once; a row is a series'
 * index, a bin, a save's index, and a value, and a bin is a series' index, a bin, and the rule's value.
 */
function fileText(): string {
    const lists = {
        additiveAnalyses: [...ADDITIVE_ANALYSES].sort(),
        additiveMetrics: [...ADDITIVE_METRICS].sort(),
        hourlyMetrics: [...HOURLY_METRICS].sort(),
        offGridAnalyses: [...OFF_GRID_ANALYSES].sort(),
    };
    const lines = [
        "{",
        `  "about": ${JSON.stringify("F35 design (i)'s shared cases, written from snapshotValues by fabric/app/src/data/kept-value-cases.test.ts: don't edit. Times are seconds after base. A case's series are target, analysis, metric; its saves are capture, window start, window end, and the grain in minutes that it declares (grain_minutes), when it does; a row is a series' index, a bin, a save's index, and a value; a bin is a series' index, a bin, and the rule's value.")},`,
        `  "base": ${JSON.stringify(new Date(BASE).toISOString())},`,
        `  "lists": ${JSON.stringify(lists)},`,
        '  "cases": [',
    ];
    const list = (name: string, items: readonly unknown[], last = false) => {
        lines.push(`      "${name}": [`);
        items.forEach((item, j) => lines.push(`        ${JSON.stringify(item)}${j < items.length - 1 ? "," : ""}`));
        lines.push(`      ]${last ? "" : ","}`);
    };
    CASES.forEach((c, i) => {
        const seriesKeys: string[] = [];
        const saveKeys: string[] = [];
        const indexOf = (keys: string[], key: string) => {
            if (!keys.includes(key)) keys.push(key);
            return keys.indexOf(key);
        };
        const rows = c.rows.map(([target, analysis, metric, bin, captured, start, end, value, grain]) => [
            indexOf(seriesKeys, JSON.stringify([target, analysis, metric])),
            bin,
            indexOf(saveKeys, JSON.stringify(grain === undefined ? [captured, start, end] : [captured, start, end, grain])),
            value,
        ]);
        const bins = binsOf(c.rows).map(([target, analysis, metric, bin, value]) => [indexOf(seriesKeys, JSON.stringify([target, analysis, metric])), bin, value]);
        lines.push("    {", `      "name": ${JSON.stringify(c.name)},`);
        list("series", seriesKeys.map((key) => JSON.parse(key) as unknown));
        list("saves", saveKeys.map((key) => JSON.parse(key) as unknown));
        list("rows", rows);
        list("bins", bins, true);
        lines.push(`    }${i < CASES.length - 1 ? "," : ""}`);
    });
    lines.push("  ]", "}", "");
    return lines.join("\n");
}
describe("F35 design (i)'s shared cases", () => {
    it("are the committed file, written from snapshotValues", () => {
        const text = fileText();
        if (process.env.DBHUB_WRITE_KEPT_VALUE_CASES === "1") writeFileSync(FILE, text);
        expect(readFileSync(FILE, "utf8").replace(/\r\n/g, "\n")).toBe(text);
    });

    // What the named cases pin, read from the rule, so the file can't hold a wrong answer that a review would miss.
    const valueAt = (name: string, at: string): number | undefined => {
        const c = NAMED.find((x) => x.name.startsWith(name));
        return binsOf(c?.rows ?? []).find((b) => b[3] === s(at))?.[4];
    };
    const totalOf = (name: string, from: string, to: string): number => {
        const c = NAMED.find((x) => x.name.startsWith(name));
        return binsOf(c?.rows ?? [])
            .filter((b) => b[3] !== null && b[3] >= s(from) && b[3] < s(to))
            .reduce((a, b) => a + b[4], 0);
    };

    it("keeps the session's minute and leaves the day save's total out where the session covers it", () => {
        expect(valueAt("a session's minutes", "15:15")).toBe(810);
    });

    it("keeps the day save's lag after the session's window, and the session's own where it covers the day's interval", () => {
        expect(valueAt("a peak after", "16:45")).toBe(34);
        expect(valueAt("a peak after", "16:30")).toBe(8);
    });

    it("counts a stop save's minutes without rows from the later day save: 4,500 from 17:00 to 18:15", () => {
        expect(totalOf("a stop save whose", "17:00", "18:15")).toBe(4500);
    });

    it("is short by what hadn't arrived in a stop save's last bin, at most one 15-minute bin: 4,320 of 4,500", () => {
        expect(totalOf("partly arrived", "17:00", "18:15")).toBe(4320);
    });

    it("drops a lower peak and keeps a higher one where the finer points leave a gap", () => {
        expect(valueAt("a peak lower", "15:30")).toBe(30);
        expect(valueAt("a peak higher", "15:30")).toBe(70);
    });

    it("takes each finer save against every earlier one, as finestPerInterval does: 900 from 15:15 to 15:30, the day's", () => {
        // The minutes hold 130 from 15:15 to 15:25 and all of the 5-minute save's two points, so the day's 15:15 keeps
        // 900 - 130 = 770 beside the newest minute's 10: 780. Against the first three only, the 5-minute save's 15:20 kept
        // 52 there, though the fourth save's minutes hold that time, and the bin was 728, 848 in all.
        expect(valueAt("five finer saves", "15:15")).toBe(780);
        expect(totalOf("five finer saves", "15:15", "15:30")).toBe(900);
    });

    it("ranks a finer save whose rows fall only where a coarser save's window cuts its interval off: 96 from 15:15 to 15:30", () => {
        // The stop save's 15:20 keeps 8 beside the session's minutes, so the day's 15:15 keeps 24 for 15:24 to 15:30: with
        // the stop save's 15:15, 4, its bin is 28. Without the session's save ranked there, it was 8, and 76 in all.
        expect(valueAt("a finer save only where", "15:15")).toBe(28);
        expect(totalOf("a finer save only where", "15:15", "15:30")).toBe(96);
    });

    it("splits a finer row that a window cuts through as finestPerInterval does, with a quiet minute in it: 89 from 15:15 to 15:30", () => {
        // The stop save's 15:20 keeps 8 beside the session's minutes, split by length across what they leave uncovered: 3
        // for the quiet 15:20 and 5 for 15:22 to 15:24. The day's part from 15:22 overlaps only the 5, so its 15:15 keeps 27
        // for 15:24 to 15:30: with the stop save's 15:15, 4, its bin is 31. The data hold 86, where the day keeps 24;
        // counting all 8 against the day's part gave that, before design (i)'s build aligned the split.
        expect(valueAt("a quiet minute in a finer row", "15:15")).toBe(31);
        expect(totalOf("a quiet minute in a finer row", "15:15", "15:30")).toBe(89);
    });

    it("splits what's left of a finer row on both sides of a window's cut: 72 from 15:15 to 15:30, the data's answer", () => {
        // The stop save's 15:20 keeps 8 beside the session's minutes: 4 at 15:20, which the day's window cuts off, and 4 at
        // 15:23, which the day's part from 15:22 overlaps. So the day keeps 24 of its 38, beside the stop save's 15:15, 20:
        // 44. Counting all 8 against the day's part gave 40, and 68.
        expect(valueAt("what's left of a finer row", "15:15")).toBe(44);
        expect(totalOf("what's left of a finer row", "15:15", "15:30")).toBe(72);
    });

    it("reads a save's step from the grain it declares: a hand-set 5-minute bin holds the day's interval, and a sparse save is the finer", () => {
        // Declared at 5 minutes, the session's four rows hold 15:00 to 15:20, so the day's 15:00 is left out and its 15:15
        // keeps 120 for 15:20 to 15:30. Read from its one-hour window, as before F35's declared grain, they're 1-minute bins
        // that leave gaps, and the day's 15:00 keeps the 50 they don't hold.
        expect(totalOf("declared grains: a hand-set", "15:00", "15:30")).toBe(310);
        const older = NAMED.find((x) => x.name.startsWith("declared grains: a hand-set"))?.rows.map((r) => r.slice(0, 8) as CaseRow) ?? [];
        expect(binsOf(older).filter((b) => b[3] !== null && b[3] < s("15:30")).reduce((a, b) => a + b[4], 0)).toBe(360);
        expect(valueAt("declared grains: a save whose bins", "15:30")).toBe(43);
    });

    // Each series' total or peak, hour by hour, by both rules: what differs, as "case, key: model and finest".
    const parity = (cases: readonly Case[]) => {
        const differ: string[] = [];
        let compared = 0;
        for (const c of cases) {
            const { model, finest } = hourlyWindows(c.rows);
            for (const key of new Set([...model.keys(), ...finest.keys()])) {
                const a = model.get(key);
                const b = finest.get(key);
                compared += 1;
                if (a === undefined || b === undefined || Math.abs(a - b) > 1e-9 * Math.max(1, Math.abs(a), Math.abs(b))) differ.push(`${c.name}, ${key}: ${a} and ${b}`);
            }
        }
        return { differ, compared };
    };

    it("gives every series the same totals and peaks, hour by hour, as finestPerInterval, but for an older save's step", () => {
        const { differ, compared } = parity(CASES);
        // One known difference, in a save written before F35's declared grain. random 11's newer 900-minute save holds 3
        // rows of T2's sessions, 30 minutes apart at their closest, and no other series. finestPerInterval reads a capture's
        // step from its bins, 30 minutes here, so the save is coarser than the older one and left out at 15:30, where the
        // older save's 7 is kept; snapshotValues reads the notebook's 15 from its window, so the newer save is the finer and
        // its 43 is kept. Each of the notebook's analyses is its own capture and shows its step through its own series, and
        // sessions and wait_deltas hold only bins with activity, so a save with scattered activity can read coarser, as this
        // one does. A save that declares its grain reads the same in both (the next test). Before design (i)'s build, the
        // two cases of a finer row that a window cuts through differed too: 146 and 149, and 128 and 132, from 15:00 to
        // 16:00; with the fourth and later saves against the first three, the five saves' case did: 3,548 and 3,600; and
        // with finer saves chosen by the part of an interval that a window keeps, the window-cut case did: 136 and 156.
        expect(differ).toEqual(["random 11, T2|sessions|MaxSessions|2026-11-21T15:00:00.000Z: 43 and 29"]);
        expect(compared).toBeGreaterThan(CASES.length);
    });

    it("gives every series the same totals and peaks as finestPerInterval when every save declares its grain, as the notebook's now do", () => {
        const declared = CASES.map((c) => ({ ...c, rows: withDeclaredGrains(c.rows) }));
        const { differ, compared } = parity(declared);
        expect(differ).toEqual([]);
        expect(compared).toBeGreaterThan(CASES.length);
        // The grains that the rule read are the ones declared, so its own values don't change.
        expect(declared.map((c) => binsOf(c.rows))).toEqual(CASES.map((c) => binsOf(c.rows)));
    });
});
