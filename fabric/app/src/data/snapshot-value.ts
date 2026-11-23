// F35's rule for the history model's overlapping saves, as one value per series and bin: each interval from its finest
// save, by the rows each save holds, as finestPerInterval keeps it. It's the reference for a fix of the model, with its
// tests: the model's 'Snapshot Value' still takes each bin from its newest save, because taking this rule in its DAX, at
// query time, was too slow (ADR 0014's amendment of 2026-11-22). Not used by the app's views.

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
    /** What its rows of the series cover: from its first row's start to its last row's end, cut to its window. */
    rowFrom: number;
    rowTo: number;
    /** A row in every interval from its first to its last, so its rows cover all of [rowFrom, rowTo). */
    dense: boolean;
}

/** A finer save's row in a coarser point's interval: its span, its save's rank there, and what it keeps and leaves taken. */
interface Piece {
    save: Save;
    value: number;
    from: number;
    to: number;
    rank: number;
    kept: number;
    taken: number | null;
}

/** The spans cover [from, to): no gap point, the start or a span's end inside it, lies outside every span. */
function covers(spans: ReadonlyArray<{ from: number; to: number }>, from: number, to: number): boolean {
    if (spans.length === 0) return false;
    const points = [from, ...spans.filter((s) => s.to < to - EPSILON).map((s) => s.to)];
    return points.every((x) => spans.some((s) => s.from <= x + EPSILON && s.to > x + EPSILON));
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
 * The value for each target, analysis, metric, and bin (the model's 'Snapshot Value' groups), by key `target|analysis|metric|bin`
 * (bin in epoch milliseconds, or "" for a row without one). Per bin, each save's point there, as finestPerInterval keeps it:
 * - No finer save's rows reach its interval: it stays whole. A finer save is a finer grain, or the same grain and newer.
 * - One finer save has a row in every one of its intervals across it: it's covered, and left out.
 * - Otherwise, from the finer saves whose rows reach any part of its interval, the part its window cuts off too, ranked
 *   by save (the finest first, then the newest), each of their rows in its interval keeps what the shared function keeps
 *   (all of it with nothing earlier under it, nothing when earlier rows cover it, or else what's left of it), against
 *   every earlier save's rows, as finestPerInterval takes each point against every one it kept before. Then a point that
 *   those rows cover where its window keeps it is left out; a total stays as what's left of it, and a maximum or an
 *   average only when it's higher than every one of them that wasn't covered itself.
 * Totals add, and maxima and averages take the highest; a remainder shows at its own bin's start. Off the bin grid, the
 * newest capture. A row with no bin is a save only, a marker with its rows' extent in First, Last, and Count.
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
        const offGrid = OFF_GRID_ANALYSES.has(analysis);

        const byBin = new Map<string, Row[]>();
        for (const r of list) {
            const at = time(r.Bucket);
            const binKey = at === null ? "" : String(at);
            const group = byBin.get(binKey) ?? [];
            group.push(r);
            byBin.set(binKey, group);
        }

        // Each save's rows of the series: their first and last bin and how many bins, from the rows, or from a marker.
        const extents = new Map<number, { first: number; last: number; count: number }>();
        const seen = new Map<number, Set<number>>();
        for (const r of list) {
            const at = time(r.Bucket);
            const captured = time(r.CapturedAt);
            if (at === null || captured === null) continue;
            const bins = seen.get(captured) ?? new Set<number>();
            bins.add(at);
            seen.set(captured, bins);
        }
        for (const [captured, bins] of seen) extents.set(captured, { first: Math.min(...bins), last: Math.max(...bins), count: bins.size });
        for (const r of list) {
            const captured = time(r.CapturedAt);
            const first = time(r.First);
            const last = time(r.Last);
            if (captured === null || first === null || last === null || r.Count === null || r.Count === undefined) continue;
            extents.set(captured, { first, last, count: Number(r.Count) });
        }

        const saves = new Map<number, Save>();
        for (const r of list) {
            const captured = time(r.CapturedAt);
            const from = time(r.WindowStart);
            const to = time(r.WindowEnd);
            const extent = captured === null ? undefined : extents.get(captured);
            if (captured === null || from === null || to === null || !extent || saves.has(captured)) continue;
            const step = monitor ? monitorGrain(from, to, monitorBins.get(`${target}|${analysis}|${captured}`) ?? []) : sqlGrain(from, to);
            const grain = hourly ? Math.max(60, step) : step;
            saves.set(captured, {
                captured,
                from,
                to,
                grain,
                rowFrom: Math.max(extent.first, from),
                rowTo: Math.min(extent.last + grain * MINUTE, to),
                dense: extent.count === Math.round((extent.last - extent.first) / (grain * MINUTE)) + 1,
            });
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

        const finerThan = (s: Save, than: Save) => s.grain < than.grain || (s.grain === than.grain && s.captured > than.captured);
        const ownOf = (bin: number, save: Save, value: number): number | null => {
            const length = save.grain * MINUTE;
            let start = Math.max(bin, save.from);
            let end = Math.min(bin + length, save.to);
            if (start >= end) [start, end] = [bin, bin + length];
            // The finer saves whose rows reach any part of its interval, the part its window cuts off too: a finer row
            // that straddles the cut is taken against every one of them, as finestPerInterval takes it (the review of
            // 4944e22d). The cover check and the point's own remainder stay on the part its window keeps.
            const finer = [...saves.values()].filter((s) => finerThan(s, save) && s.rowFrom < bin + length && s.rowTo > bin);
            if (finer.length === 0) return value;
            if (finer.some((s) => s.dense && s.rowFrom <= start + EPSILON && s.rowTo >= end - EPSILON)) return null;
            // The finer saves' rows in its interval, each ranked by its save: the finest first, then the newest.
            const pieces: Piece[] = [];
            for (const [key, v] of point) {
                const [atText, capturedText] = key.split("|");
                const at = Number(atText);
                const s = saves.get(Number(capturedText));
                if (!s || !finer.includes(s) || at < bin || at >= bin + length) continue;
                let from = Math.max(at, s.from);
                let to = Math.min(at + s.grain * MINUTE, s.to);
                if (from >= to) [from, to] = [at, at + s.grain * MINUTE];
                pieces.push({ save: s, value: v, from, to, rank: 1 + finer.filter((q) => finerThan(q, s)).length, kept: v, taken: v });
            }
            // The first save's rows keep all they hold; each later save's, what finestPerInterval keeps of them against
            // every earlier save's rows.
            let earlier = pieces.filter((p) => p.rank === 1);
            const levels = [...new Set(pieces.map((p) => p.rank))].filter((level) => level > 1).sort((a, b) => a - b);
            for (const level of levels) {
                const rows = pieces.filter((p) => p.rank === level);
                for (const r of rows) {
                    const under = earlier.filter((u) => u.from < r.to && u.to > r.from);
                    const covered = covers(under, r.from, r.to);
                    r.kept = under.length === 0 ? r.value : covered ? 0 : Math.max(0, r.value - under.reduce((a, u) => a + u.kept, 0));
                    r.taken = covered ? null : r.value;
                }
                earlier = [...earlier, ...rows];
            }
            const under = earlier.filter((u) => u.from < end && u.to > start);
            if (under.length === 0) return value;
            if (covers(under, start, end)) return null;
            if (adds) return Math.max(0, value - under.reduce((a, u) => a + u.kept, 0));
            const taken = under.map((u) => u.taken).filter((t): t is number => t !== null);
            return taken.length === 0 || value > Math.max(...taken) ? value : null;
        };

        for (const [binKey, group] of byBin) {
            if (binKey === "" || offGrid) {
                if (binKey === "" && !offGrid && group.every((r) => r.Value === null || r.Value === undefined)) continue;
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

/** Each target's window totals and peaks, after the model's telemetry measures: an analysis, which metrics, and whether they add up or peak. */
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
    ReplicaLagPeak: { analysis: "postgresql", metric: (m) => m === "physical_replication_delay_in_seconds", adds: false },
};

export interface F35Check {
    /** The model rule's value per series and bin in the window, by `target|analysis|metric|bin`, bin in ISO UTC. */
    bins: Record<string, number>;
    /** Each target's window measures: by this rule per bin (model) and by finestPerInterval (finest), which must agree. */
    measures: Record<string, Record<string, { model: number | null; finest: number | null }>>;
}

/**
 * F35's check from a history's rows, as the model holds them (one per save, series, and bin, and a marker per save and
 * series): the rule's per-bin values, and each target's window totals and peaks by the rule and by finestPerInterval,
 * which must agree. Bins in [from, to), by their own start, as a DAX filter takes them.
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
