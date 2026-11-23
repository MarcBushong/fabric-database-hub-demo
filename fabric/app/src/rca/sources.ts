// Where the investigations read in the app, for the dock and the RCA view: the RCA tables (loader.ts), Database Hub's
// bins for T1 to T3 (the replay's own queries), and the Azure Monitor metrics of T4, its read replica, and T5, each a
// bounded DAX query on the history model as the signed-in viewer. Blind (ADR 0031): Telemetry Snapshots and the RCA
// tables only, over any session, not only the latest capture.

import { addsUp, finestPerInterval, HOURLY_METRICS } from "@/data/finest-per-interval";
import { toBins, toCosmosCapture, toPostgresCapture, toWaitBins, withCategoryWaits } from "@/data/model";
import { incidentSeriesQuery, incidentWaitsQuery, type QuerySpec } from "@/data/queries";
import { isMissingInModel } from "@/data/retry";
import { SQL_TARGETS } from "@/lib/dax";
import { toDate as toInstant } from "@/lib/format";
import { binsTable, loadEvidence, loadSidecar, MONITOR_PAGES, MONITOR_ROW_LIMIT, MONITOR_TABLE, RcaReadError, rcaMonitorDax, waitsTable, type DaxLog } from "./loader";
import { toDate } from "./rows";
import type { SidecarEvidence } from "./sidecar";
import type { Telemetry } from "./tools";
import { pointKey, type Evidence, type RcaTarget, type WholeReading } from "./types";

type Row = Record<string, unknown>;

/** Runs one query on the history model as the viewer: the app's query client in production, fixtures in the tests. */
export type RunQuery = (spec: QuerySpec) => Promise<Row[]>;

export interface RcaSources {
    load(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Evidence>;
    telemetry(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Telemetry>;
    /** The sidecar's rows of a window: Query Store's evidence on T1 to T4 and who held T4's connections (loader.ts's loadSidecar). */
    sidecar(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<SidecarEvidence>;
}

// One point per interval, from the history's overlapping saves: the shared finestPerInterval (F35, from the release's
// follow-ups, src/data/finest-per-interval.ts), which the app's T4 and T5 views read through too. Its rows go once to
// the pure decoders (toPostgresCapture, toCosmosCapture): its output isn't valid input again. Re-exported for the tests.
export { finestPerInterval };

/** Each raw row's grain, by the shared function's rule: its save's step, the smallest gap in any of the save's series, and at least an hour for T5's hourly metrics; 0 when the rows hold no step of its save. */
function rawGrains(rows: readonly Row[]): (row: Row) => number {
    const familyOf = (row: Row) => (row.TargetKey === "T5" ? "cosmos" : row.TargetKey === "T4" || row.TargetKey === "T4-replica" ? "postgres" : "sql");
    const captureOf = (row: Row) => `${String(row.CapturedAt)}|${familyOf(row)}`;
    const seriesOf = (row: Row) => `${String(row.CapturedAt)}|${String(row.TargetKey)}|${String(row.AnalysisKey ?? "")}|${String(row.Metric)}`;
    const times = new Map<string, { capture: string; at: Set<number> }>();
    for (const row of rows) {
        const at = toInstant(row.Bucket);
        if (!at || HOURLY_METRICS.has(String(row.Metric))) continue;
        const series = times.get(seriesOf(row)) ?? { capture: captureOf(row), at: new Set<number>() };
        series.at.add(at.getTime());
        times.set(seriesOf(row), series);
    }
    const captureStep = new Map<string, number>();
    for (const series of times.values()) {
        const sorted = [...series.at].sort((a, b) => a - b);
        for (let i = 1; i < sorted.length; i++) {
            const gap = sorted[i] - sorted[i - 1];
            const step = captureStep.get(series.capture);
            if (step === undefined || gap < step) captureStep.set(series.capture, gap);
        }
    }
    return (row: Row) => {
        const step = captureStep.get(captureOf(row)) ?? 0;
        return HOURLY_METRICS.has(String(row.Metric)) ? Math.max(60 * 60_000, step) : step;
    };
}

/**
 * The coarsest interval of the history's points at each time, by pointKey, read before finestPerInterval keeps one point
 * per interval: a key an earlier list made from a coarser save's point (B's day-long save, 15 minutes at 15:30) reads as
 * the incident in that point's interval, as it did then (the review of 97fdf5ba). A point's grain is the shared
 * function's.
 */
export function coarsestIntervals(rows: readonly Row[]): Map<string, number> {
    const grainOf = rawGrains(rows);
    const out = new Map<string, number>();
    for (const row of rows) {
        const at = toInstant(row.Bucket);
        if (!at) continue;
        const grain = grainOf(row);
        const key = pointKey(String(row.TargetKey), String(row.Metric), at);
        if (grain > (out.get(key) ?? 0)) out.set(key, grain);
    }
    return out;
}

/**
 * The whole readings of the coarser points the shared function split into two or more pieces, by each piece's pointKey:
 * a total split across its stretches by their length, or a peak given to each as an upper bound, is one reading. It's
 * said as its raw row has it, over its save's whole interval, with what the finer saves hold of that interval (the review
 * of c4c63abe: one day point's 800 429s read as two incidents, and its shares by length as Azure Monitor's counts).
 */
export function wholeReadings(rows: readonly Row[], kept: readonly Row[], intervals: ReadonlyMap<string, number>, grains: ReadonlyMap<string, number>, sources: ReadonlyMap<string, string>): Map<string, WholeReading> {
    const pieces = new Map<string, string[]>();
    for (const [piece, source] of sources) pieces.set(source, [...(pieces.get(source) ?? []), piece]);
    const grainOf = rawGrains(rows);
    const keyOf = (row: Row) => {
        const at = toInstant(row.Bucket);
        return at ? pointKey(String(row.TargetKey), String(row.Metric), at) : "";
    };
    const seriesOf = (row: Row) => `${String(row.TargetKey)}|${String(row.AnalysisKey ?? "")}|${String(row.Metric)}`;
    const valueOf = (row: Row | undefined) => {
        const v = typeof row?.Value === "number" ? row.Value : Number(row?.Value);
        return row && row.Value !== null && row.Value !== "" && Number.isFinite(v) ? v : null;
    };
    const out = new Map<string, WholeReading>();
    for (const [source, keys] of pieces) {
        if (keys.length < 2) continue;
        const grain = grains.get(keys[0]) ?? 0;
        const at = Number(source.slice(source.lastIndexOf("|") + 1));
        // The raw row the pieces came from: the same point, at the pieces' grain, of the newest such save.
        const raw = rows
            .filter((row) => keyOf(row) === source && grainOf(row) === grain)
            .sort((x, y) => (toInstant(y.CapturedAt)?.getTime() ?? 0) - (toInstant(x.CapturedAt)?.getTime() ?? 0))[0];
        const value = valueOf(raw);
        if (!raw || value === null || grain <= 0) continue;
        // What the raw value is of: its interval, cut to its save's window, as the shared function cuts it.
        const cutFrom = Math.max(at, toInstant(raw.WindowStart)?.getTime() ?? at);
        const cutTo = Math.min(at + grain, toInstant(raw.WindowEnd)?.getTime() ?? at + grain);
        const [from, to] = cutFrom < cutTo ? [cutFrom, cutTo] : [at, at + grain];
        const own = new Set(keys);
        const stretches = keys.map((key) => ({ from: Number(key.slice(key.lastIndexOf("|") + 1)), to: Number(key.slice(key.lastIndexOf("|") + 1)) + (intervals.get(key) ?? 0) })).sort((x, y) => x.from - y.from);
        const covered: Array<{ from: Date; to: Date }> = [];
        let next = from;
        for (const s of stretches) {
            if (s.from > next) covered.push({ from: new Date(next), to: new Date(s.from) });
            next = Math.max(next, s.to);
        }
        if (next < to) covered.push({ from: new Date(next), to: new Date(to) });
        // What the finer saves hold of it: the same series' kept points over its interval, the ones its pieces are what's left of.
        const finer = kept.filter((row) => {
            const key = keyOf(row);
            if (own.has(key) || seriesOf(row) !== seriesOf(raw)) return false;
            const t = Number(key.slice(key.lastIndexOf("|") + 1));
            return t < to && t + Math.max(intervals.get(key) ?? 0, 1) > from;
        });
        const held = finer.map(valueOf);
        const whole: WholeReading = { key: source, at: new Date(from), intervalMs: to - from, grainMs: grain, value, finer: addsUp(raw) && held.length > 0 && held.every((v) => v !== null) ? held.reduce((n: number, v) => n + (v ?? 0), 0) : null, covered };
        for (const key of keys) out.set(key, whole);
    }
    return out;
}
/**
 * The kept points with no grain whose save's window is longer than the read: the read held too few of that save's points
 * to tell its step, so their interval isn't known in these minutes, and isn't an instant or a minute (the review of
 * c4c63abe: a 60-minute save's one point read "each 1-minute interval … from 15:00 to 15:00 UTC").
 */
function unknownIntervals(kept: readonly Row[], grains: ReadonlyMap<string, number>, read?: { from: Date; to: Date }): Set<string> {
    const out = new Set<string>();
    if (!read) return out;
    const span = read.to.getTime() - read.from.getTime();
    for (const row of kept) {
        const at = toInstant(row.Bucket);
        if (!at) continue;
        const key = pointKey(String(row.TargetKey), String(row.Metric), at);
        if ((grains.get(key) ?? 0) > 0) continue;
        const start = toInstant(row.WindowStart);
        const end = toInstant(row.WindowEnd);
        if (start && end && end.getTime() - start.getTime() > span) out.add(key);
    }
    return out;
}

/**
 * Azure Monitor's rows as the investigations read them, from one call of the shared finestPerInterval: one point per
 * interval with its span (intervals) and its save's step (grains), the source of each piece of a coarser point and which
 * pieces are upper bounds, each split point's whole reading (wholes), the points whose interval isn't known in a read
 * narrower than their save (unknownIntervals), and each time's coarsest point (keyIntervals).
 */
export function monitorTelemetry(rows: readonly Row[], read?: { from: Date; to: Date }): Pick<Telemetry, "postgres" | "cosmos" | "intervals" | "grains" | "sources" | "upperBounds" | "wholes" | "unknownIntervals" | "keyIntervals"> {
    const { kept, intervals, grains, sources, upperBounds } = finestPerInterval(rows);
    return {
        postgres: toPostgresCapture(kept.filter((r) => r.TargetKey === "T4" || r.TargetKey === "T4-replica")),
        cosmos: toCosmosCapture(kept.filter((r) => r.TargetKey === "T5")),
        intervals,
        grains,
        sources,
        upperBounds,
        wholes: wholeReadings(rows, kept, intervals, grains, sources),
        unknownIntervals: unknownIntervals(kept, grains, read),
        keyIntervals: coarsestIntervals(rows),
    };
}
function hash(text: string): string {
    let h = 5381;
    for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36);
}

export function createRcaSources(run: RunQuery, onDax?: (log: DaxLog) => void): RcaSources {
    const spec = (title: string, dax: string, rowLimit: number): QuerySpec => ({ id: `rca-${hash(dax)}`, title, dax, rowLimit, columns: [] });

    /** One telemetry query, logged. A read that fails (Telemetry Snapshots is in every model) fails the window's
     *  investigation (RcaReadError), so its part never reads as quiet. */
    async function read(table: string, query: QuerySpec): Promise<Row[]> {
        const started = Date.now();
        try {
            const rows = await run(query);
            onDax?.({ table, query: query.dax, rows: rows.length, ms: Date.now() - started });
            return rows;
        } catch (err) {
            onDax?.({ table, query: query.dax, rows: 0, error: err instanceof Error ? err.message : String(err), ms: Date.now() - started });
            if (isMissingInModel(err)) return [];
            throw new RcaReadError([{ table, error: err }]);
        }
    }

    /**
     * One read, a page at a time, oldest first by its time column. A query returns at most its row limit, so one at the
     * limit had lost its newest rows: the incident's own minutes (the coordinator's note on the shared finestPerInterval;
     * the review of eb89acbb: T1's Tran Log IO storm late in a long window was gone from its waits, with no note). The next
     * page reads on from the last time the page had, whole, in place of that time's rows. After MONITOR_PAGES pages, the
     * rest isn't read, and the window's investigations say so, from where it stopped (until).
     */
    async function readPaged(table: string, query: (start: Date) => QuerySpec | null, timeOf: (row: Row) => Date | null | undefined, from: Date): Promise<{ rows: Row[]; until: Date | null }> {
        const rows: Row[] = [];
        let start = from;
        for (let page = 0; page < MONITOR_PAGES; page++) {
            const q = query(start);
            if (!q) return { rows, until: null };
            const got = await read(table, q);
            if (got.length < q.rowLimit) return { rows: [...rows, ...got], until: null };
            const last = timeOf(got[got.length - 1]);
            // A page all of one time can't read on: what it has of that time may be only some of it.
            if (!last || last.getTime() <= start.getTime()) return { rows, until: start };
            for (const row of got) if ((timeOf(row)?.getTime() ?? 0) < last.getTime()) rows.push(row);
            start = last;
        }
        return { rows, until: start };
    }

    /** Azure Monitor's rows for a window, paged by their bucket. */
    const readMonitor = (from: Date, to: Date, targets: readonly RcaTarget[]) =>
        readPaged(
            MONITOR_TABLE,
            (start) => {
                const dax = rcaMonitorDax(start, to, targets);
                return dax ? spec("Azure Monitor metrics", dax, MONITOR_ROW_LIMIT) : null;
            },
            (row) => toDate(row.Bucket),
            from,
        );

    return {
        load: (from, to, targets) => loadEvidence((dax, rowLimit) => run(spec("RCA evidence", dax, rowLimit)), from, to, targets, { onDax }),
        sidecar: (from, to, targets) => loadSidecar((dax, rowLimit) => run(spec("RCA Query Store evidence", dax, rowLimit)), from, to, targets, { onDax }),
        async telemetry(from, to, targets) {
            const sql = SQL_TARGETS.filter((t) => targets.includes(t));
            const bucketOf = (row: Row) => toDate(row["Bucket UTC"]);
            const [bins, monitor] = await Promise.all([
                Promise.all(
                    sql.map(async (target) => {
                        // Database Hub's bins and their waits by category, each paged by its bin like Azure Monitor's rows.
                        const [series, waits] = await Promise.all([
                            readPaged(binsTable(target), (start) => incidentSeriesQuery({ target, start, end: to }), bucketOf, from),
                            readPaged(waitsTable(target), (start) => incidentWaitsQuery({ target, start, end: to }), bucketOf, from),
                        ]);
                        const cut = [...(series.until ? [{ table: binsTable(target), until: series.until }] : []), ...(waits.until ? [{ table: waitsTable(target), until: waits.until }] : [])];
                        return { bins: withCategoryWaits(toBins(series.rows, target), toWaitBins(waits.rows)), cut };
                    }),
                ),
                readMonitor(from, to, targets),
            ]);
            const cut = [...bins.flatMap((b) => b.cut), ...(monitor.until ? [{ table: MONITOR_TABLE, until: monitor.until }] : [])];
            return { bins: bins.flatMap((b) => b.bins), ...monitorTelemetry(monitor.rows, { from, to }), ...(cut.length ? { cut } : {}) };
        },
    };
}
