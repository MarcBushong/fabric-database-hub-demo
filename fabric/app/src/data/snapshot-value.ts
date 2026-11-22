// The history model's 'Snapshot Value' (F35) in TypeScript: the same rule as the measure in Telemetry Snapshots.tmdl, for
// its tests and for the live checks against a deployed model (fabric/powerbi/checks/f35). Not used by the app's views.

import { toDate } from "@/lib/format";
import { ADDITIVE_ANALYSES, ADDITIVE_METRICS, finestPerInterval, HOURLY_METRICS, OFF_GRID_ANALYSES } from "./finest-per-interval";

type Row = Record<string, unknown>;

const MINUTE = 60_000;
const EPSILON = 1;
/** Azure Monitor's intervals, as the operator side's helpers choose them (PostgresHistoryHelpers.ps1, CosmosHistoryHelpers.ps1). */
const LADDER = [1, 5, 15, 30, 60, 180, 360, 720, 1440];
const MONITOR_ANALYSES = new Set(["postgresql", "cosmosdb"]);

interface Save {
    captured: number;
    from: number;
    to: number;
    grain: number;
}

const text = (value: unknown) => (value === null || value === undefined ? "" : String(value));
const time = (value: unknown) => toDate(value)?.getTime() ?? null;

/** A SQL save's bin, by the notebook's own rule from its window (NB_DatabaseHub_LiveActivity: 1, 5, or 15 minutes). */
export function sqlGrain(from: number, to: number): number {
    const span = (to - from) / MINUTE;
    return span <= 120 + 1e-6 ? 1 : span <= 720 + 1e-6 ? 5 : 15;
}

/**
 * An Azure Monitor save's step: the coarsest interval its window can hold its bins in, that each of its bins starts on
 * (counted from midnight UTC, as the history helpers bucket them), hourly metrics aside. Its bins' count alone would read
 * a day-long save of a T4 that ran a few hours of it as a coarse one.
 */
export function monitorGrain(from: number, to: number, bins: Iterable<number>): number {
    const minutes = [...new Set(bins)].map((at) => Math.round(at / MINUTE));
    if (minutes.length === 0) return 60;
    const start = Math.round(from / MINUTE);
    const end = Math.round(to / MINUTE);
    let best = 1;
    for (const step of LADDER) {
        const intervals = (Math.ceil(end / step) * step - Math.floor(start / step) * step) / step;
        if (intervals >= minutes.length && minutes.every((m) => m % step === 0)) best = step;
    }
    return best;
}

/**
 * The measure's value for each target, analysis, metric, and bin (its SUMMARIZE groups), by key `target|analysis|metric|bin`
 * (bin in epoch milliseconds, or "" for a row without one). Per bin, each save's point there:
 * - No finer save of the series overlaps its interval: it stays whole. A finer save is a finer grain, or the same grain and
 *   newer.
 * - One finer save's window covers all of its interval: it's left out.
 * - Otherwise, from the series' rows in its interval (the finest and newest row of each bin, and of nested ones the coarser):
 *   a total stays as what's left of it, and a maximum or an average only when it's higher than all of them.
 * Totals add, and maxima and averages take the highest; a remainder shows at its own bin's start. Off the bin grid, the
 * newest capture. A finer save's window stands for its rows (the model can't read every finer row in every visual's cell),
 * so this agrees with finestPerInterval wherever a finer save's rows add up to the coarser total.
 */
export function snapshotValues(rows: readonly Row[]): Map<string, number> {
    const bySeries = new Map<string, Row[]>();
    for (const r of rows) {
        const key = `${text(r.TargetKey)}|${text(r.AnalysisKey)}|${text(r.Metric)}`;
        const list = bySeries.get(key) ?? [];
        list.push(r);
        bySeries.set(key, list);
    }
    // Azure Monitor saves' bins, over every metric of their target and analysis but the hourly ones.
    const monitorBins = new Map<string, Set<number>>();
    for (const r of rows) {
        const at = time(r.Bucket);
        if (at === null || !MONITOR_ANALYSES.has(text(r.AnalysisKey)) || HOURLY_METRICS.has(text(r.Metric))) continue;
        const key = `${text(r.TargetKey)}|${text(r.AnalysisKey)}|${time(r.CapturedAt)}`;
        const set = monitorBins.get(key) ?? new Set<number>();
        set.add(at);
        monitorBins.set(key, set);
    }

    const out = new Map<string, number>();
    for (const [seriesKey, list] of bySeries) {
        const [target, analysis, metric] = seriesKey.split("|");
        const adds = ADDITIVE_ANALYSES.has(analysis) || ADDITIVE_METRICS.has(metric);
        const monitor = MONITOR_ANALYSES.has(analysis);
        const hourly = HOURLY_METRICS.has(metric);

        // Off the grid, and rows without a bin: the newest capture, summed.
        const offGrid = OFF_GRID_ANALYSES.has(analysis);
        const byBin = new Map<string, Row[]>();
        for (const r of list) {
            const at = time(r.Bucket);
            const binKey = at === null ? "" : String(at);
            const group = byBin.get(binKey) ?? [];
            group.push(r);
            byBin.set(binKey, group);
        }

        const saves = new Map<number, Save>();
        for (const r of list) {
            const captured = time(r.CapturedAt);
            const from = time(r.WindowStart);
            const to = time(r.WindowEnd);
            if (captured === null || from === null || to === null || saves.has(captured)) continue;
            const grain = monitor ? monitorGrain(from, to, monitorBins.get(`${target}|${analysis}|${captured}`) ?? []) : sqlGrain(from, to);
            saves.set(captured, { captured, from, to, grain: hourly ? Math.max(60, grain) : grain });
        }
        // Each bin's value per save.
        const point = new Map<string, number>();
        for (const r of list) {
            const at = time(r.Bucket);
            const captured = time(r.CapturedAt);
            if (at === null || captured === null) continue;
            const key = `${at}|${captured}`;
            point.set(key, (point.get(key) ?? 0) + Number(r.Value));
        }

        const ownOf = (bin: number, save: Save, value: number): number | null => {
            const length = save.grain * MINUTE;
            let start = Math.max(bin, save.from);
            let end = Math.min(bin + length, save.to);
            if (start >= end) [start, end] = [bin, bin + length];
            const finer = [...saves.values()].filter((s) => (s.grain < save.grain || (s.grain === save.grain && s.captured > save.captured)) && s.from < end && s.to > start);
            if (finer.length === 0) return value;
            if (finer.some((s) => s.from <= start + EPSILON && s.to >= end - EPSILON)) return null;
            // Partly covered: the series' rows in its interval, from finer saves, that overlap what it covers.
            const inside: Array<{ at: number; captured: number; grain: number; value: number }> = [];
            for (const [key, v] of point) {
                const [atText, capturedText] = key.split("|");
                const at = Number(atText);
                const s = saves.get(Number(capturedText));
                if (!s || at < bin || at >= bin + length) continue;
                if (!(s.grain < save.grain || (s.grain === save.grain && s.captured > save.captured))) continue;
                let from = Math.max(at, s.from);
                let to = Math.min(at + s.grain * MINUTE, s.to);
                if (from >= to) [from, to] = [at, at + s.grain * MINUTE];
                if (from < end && to > start) inside.push({ at, captured: s.captured, grain: s.grain, value: v });
            }
            const first = inside.filter((p) => !inside.some((q) => q.at === p.at && (q.grain < p.grain || (q.grain === p.grain && q.captured > p.captured))));
            const outer = first.filter((p) => !first.some((q) => q.grain > p.grain && q.at <= p.at && p.at < q.at + q.grain * MINUTE));
            if (adds) return Math.max(0, value - outer.reduce((a, p) => a + p.value, 0));
            return outer.length === 0 || value > Math.max(...outer.map((p) => p.value)) ? value : null;
        };

        for (const [binKey, group] of byBin) {
            if (binKey === "" || offGrid) {
                const newest = Math.max(...group.map((r) => time(r.CapturedAt) ?? -Infinity));
                out.set(`${seriesKey}|${binKey}`, group.filter((r) => time(r.CapturedAt) === newest).reduce((a, r) => a + Number(r.Value), 0));
                continue;
            }
            const bin = Number(binKey);
            const owns: number[] = [];
            for (const captured of new Set(group.map((r) => time(r.CapturedAt)))) {
                const save = captured === null ? undefined : saves.get(captured);
                if (!save) continue;
                const value = point.get(`${bin}|${captured}`) ?? 0;
                const own = ownOf(bin, save, value);
                if (own !== null) owns.push(own);
            }
            if (owns.length > 0) out.set(`${seriesKey}|${binKey}`, adds ? owns.reduce((a, b) => a + b, 0) : Math.max(...owns));
        }
    }
    return out;
}

/** The window measures window-f35.dax evaluates per target: an analysis, which metrics, and whether they add up or peak. */
export const WINDOW_MEASURES: Record<string, { analysis: string; metric: (name: string) => boolean; adds: boolean; scale?: number }> = {
    LockWaitS: { analysis: "wait_deltas", metric: (m) => m === "Lock", adds: true, scale: 1 / 1000 },
    WaitS: { analysis: "wait_deltas", metric: () => true, adds: true, scale: 1 / 1000 },
    BufferIoS: { analysis: "wait_deltas", metric: (m) => m.includes("(PAGEIOLATCH)"), adds: true, scale: 1 / 1000 },
    IoMb: { analysis: "storage_io", metric: (m) => m === "ReadMB" || m === "WriteMB", adds: true },
    Batch: { analysis: "counter_deltas", metric: (m) => m === "Batch Requests/sec", adds: true },
    Deadlocks: { analysis: "counter_deltas", metric: (m) => m === "Number of Deadlocks/sec", adds: true },
    CpuPeak: { analysis: "cpu", metric: (m) => m === "MaxCPU", adds: false },
    BlockedPeak: { analysis: "gauges", metric: (m) => m === "Processes blocked", adds: false },
    SessionsPeak: { analysis: "sessions", metric: (m) => m === "MaxSessions", adds: false },
    Requests: { analysis: "cosmosdb", metric: (m) => m === "TotalRequests", adds: true },
    Throttled: { analysis: "cosmosdb", metric: (m) => m === "ThrottledRequests", adds: true },
    RuConsumed: { analysis: "cosmosdb", metric: (m) => m === "TotalRequestUnits", adds: true },
    NormRuPeak: { analysis: "cosmosdb", metric: (m) => m === "NormalizedRUConsumption", adds: false },
};

export interface F35Check {
    /** The model rule's value per series and bin in the window, by `target|analysis|metric|bin`, bin in ISO UTC. */
    bins: Record<string, number>;
    /** Each target's window measures: by the model rule (what window-f35.dax must return) and by finestPerInterval. */
    measures: Record<string, Record<string, { model: number | null; finest: number | null }>>;
}

/**
 * F35's live check from rows.dax's rows: the model rule's per-bin values (snapshot-value-bins.dax's F35 column must equal
 * them), and each target's window totals and peaks by the model rule and by finestPerInterval, which must agree. Bins in
 * [from, to), by their own start, as the DAX filters them.
 */
export function f35Check(rows: readonly Row[], from: Date, to: Date): F35Check {
    const inWindow = (at: number) => at >= from.getTime() && at < to.getTime();
    const values = snapshotValues(rows);
    const bins: Record<string, number> = {};
    const model: Record<string, Record<string, number | null>> = {};
    for (const [key, value] of values) {
        const [target, analysis, metric, binText] = key.split("|");
        if (binText === "" || !inWindow(Number(binText))) continue;
        bins[`${target}|${analysis}|${metric}|${new Date(Number(binText)).toISOString()}`] = value;
        for (const [name, m] of Object.entries(WINDOW_MEASURES)) {
            if (m.analysis !== analysis || !m.metric(metric)) continue;
            const scaled = value * (m.scale ?? 1);
            const byTarget = (model[target] ??= {});
            const before = byTarget[name] ?? null;
            byTarget[name] = before === null ? scaled : m.adds ? before + scaled : Math.max(before, scaled);
        }
    }
    // finestPerInterval on the same rows, one row per save, series, and bin (summed across instances and files).
    const grouped = new Map<string, Row>();
    for (const r of rows) {
        const at = time(r.Bucket);
        if (at === null || OFF_GRID_ANALYSES.has(text(r.AnalysisKey))) continue;
        const key = `${text(r.TargetKey)}|${text(r.AnalysisKey)}|${text(r.Metric)}|${at}|${time(r.CapturedAt)}`;
        const before = grouped.get(key);
        grouped.set(key, before ? { ...before, Value: Number(before.Value) + Number(r.Value) } : { ...r, Value: Number(r.Value) });
    }
    const finest: Record<string, Record<string, number | null>> = {};
    for (const r of finestPerInterval([...grouped.values()]).kept) {
        const at = time(r.Bucket);
        if (at === null || !inWindow(at)) continue;
        for (const [name, m] of Object.entries(WINDOW_MEASURES)) {
            if (m.analysis !== text(r.AnalysisKey) || !m.metric(text(r.Metric))) continue;
            const scaled = Number(r.Value) * (m.scale ?? 1);
            const byTarget = (finest[text(r.TargetKey)] ??= {});
            const before = byTarget[name] ?? null;
            byTarget[name] = before === null ? scaled : m.adds ? before + scaled : Math.max(before, scaled);
        }
    }
    const measures: F35Check["measures"] = {};
    for (const target of new Set([...Object.keys(model), ...Object.keys(finest)])) {
        measures[target] = {};
        for (const name of Object.keys(WINDOW_MEASURES)) {
            const a = model[target]?.[name] ?? null;
            const b = finest[target]?.[name] ?? null;
            if (a !== null || b !== null) measures[target][name] = { model: a, finest: b };
        }
    }
    return { bins, measures };
}
