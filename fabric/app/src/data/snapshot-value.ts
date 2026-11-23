// F35's rule for the history model's overlapping saves, as one value per series and bin: each interval from its finest
// save, by the rows each save holds, as finestPerInterval keeps it. It's design (i)'s reference: when history is saved,
// fabric/history/kept_value.py reduces it to a kept value per row, which the model's kept form of 'Snapshot Value' reads
// per bin, and the shared cases (kept-value-cases.test.ts) hold the two to the same values. Taking the rule in the
// model's DAX, at query time, was too slow (ADR 0014's amendment of 2026-11-22). Not used by the app's views.

import { toDate } from "@/lib/format";
import { ADDITIVE_ANALYSES, ADDITIVE_METRICS, declaredGrain, finestPerInterval, gapsIn, HOURLY_METRICS, insert, OFF_GRID_ANALYSES, overlapping, shares, type Span } from "./finest-per-interval";

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

/** A finer save's row in a coarser point's interval: its span, its value, and its save's rank there. */
interface Piece {
    value: number;
    from: number;
    to: number;
    rank: number;
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
 * - Otherwise, the finer saves' rows in its interval, the part its window cuts off too, are taken in finestPerInterval's
 *   order (the finest save first, then the newest), each against the stretches that every earlier one kept: a row with
 *   none under it keeps its whole span; one they cover keeps nothing; and otherwise it keeps each stretch they leave
 *   uncovered, a total splitting what's left of it across them by length, in whole numbers when it's one (shares), and
 *   a maximum or an average its value on each. Then a point whose window's part those stretches cover is left out; a
 *   total stays as what's left of it after the stretches that overlap that part, and a maximum or an average only when
 *   it's higher than every one of them.
 * Totals add, and maxima and averages take the highest; a remainder shows at its own bin's start. Off the bin grid, the
 * newest capture. A row with no bin is a save only, a marker with its rows' extent in First, Last, and Count.
 *
 * A save's step is the grain its rows declare (declaredGrain). A save written before that keeps today's reading: a SQL
 * save's from its window (sqlGrain), and an Azure Monitor save's from its window and bins (monitorGrain). That's the one
 * known difference left from finestPerInterval, which reads such a capture's step from its bins: a SQL capture whose bins
 * don't show its step, with scattered activity for example, can read coarser there (the shared cases pin random 11).
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
        // A save's declared grain, from the first of its rows of the series that has one.
        const declared = new Map<number, number>();
        for (const r of list) {
            const captured = time(r.CapturedAt);
            const grain = declaredGrain(r);
            if (captured !== null && grain !== null && !declared.has(captured)) declared.set(captured, grain);
        }
        for (const r of list) {
            const captured = time(r.CapturedAt);
            const from = time(r.WindowStart);
            const to = time(r.WindowEnd);
            const extent = captured === null ? undefined : extents.get(captured);
            if (captured === null || from === null || to === null || !extent || saves.has(captured)) continue;
            const step = declared.get(captured) ?? (monitor ? monitorGrain(from, to, monitorBins.get(`${target}|${analysis}|${captured}`) ?? []) : sqlGrain(from, to));
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
                pieces.push({ value: v, from, to, rank: 1 + finer.filter((q) => finerThan(q, s)).length });
            }
            // What finestPerInterval keeps of each, against the stretches every earlier one kept: its whole span with
            // nothing under it, nothing when they cover it, and otherwise each stretch they leave uncovered, with a total's
            // remainder split across them by length and a maximum's or an average's value on each.
            pieces.sort((a, b) => a.rank - b.rank);
            const taken: Span[] = [];
            for (const p of pieces) {
                const under = overlapping(taken, p.from, p.to);
                if (under.length === 0) {
                    insert(taken, { start: p.from, end: p.to, value: p.value });
                    continue;
                }
                const gaps = gapsIn(under, p.from, p.to);
                if (gaps.length === 0) continue;
                if (adds) {
                    const left = Math.max(0, p.value - under.reduce((a, u) => a + (u.value ?? 0), 0));
                    const parts = shares(left, gaps.map(([from, to]) => to - from));
                    gaps.forEach(([from, to], i) => insert(taken, { start: from, end: to, value: parts[i] }));
                } else {
                    for (const [from, to] of gaps) insert(taken, { start: from, end: to, value: p.value });
                }
            }
            const under = overlapping(taken, start, end);
            if (under.length === 0) return value;
            if (gapsIn(under, start, end).length === 0) return null;
            if (adds) return Math.max(0, value - under.reduce((a, u) => a + (u.value ?? 0), 0));
            return value > Math.max(...under.map((u) => u.value ?? -Infinity)) ? value : null;
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
    /**
     * Each target's window measures: by this rule per bin (model) and by finestPerInterval (finest). Over a window
     * whose edges fall on every save's bin grid (whole hours, when no save in it is coarser than an hour), they agree
     * but for the known difference in snapshotValues' notes, an older save's step. An edge inside a coarser bin can set
     * them apart, and no build changes that: this rule shows a remainder at its own bin's start, as any per-bin model
     * does, and finestPerInterval at the start of each uncovered stretch.
     */
    measures: Record<string, Record<string, { model: number | null; finest: number | null }>>;
}

/**
 * F35's check from a history's rows, as the model holds them (one per save, series, and bin, and a marker per save and
 * series): the rule's per-bin values, and each target's window totals and peaks by the rule and by finestPerInterval.
 * Over a window whose edges fall on every save's bin grid (whole hours, when no save in it is coarser than an hour),
 * they agree but for the known difference in snapshotValues' notes; an edge inside a coarser bin can set them apart
 * (F35Check's measures). Bins in [from, to), by their own start, as a DAX filter takes them.
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
