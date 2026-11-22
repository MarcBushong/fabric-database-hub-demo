// Where the investigations read in the app, for the dock and the RCA view: the RCA tables (loader.ts), Database Hub's
// bins for T1 to T3 (the replay's own queries), and the Azure Monitor metrics of T4, its read replica, and T5, each a
// bounded DAX query on the history model as the signed-in viewer. Blind (ADR 0031): Telemetry Snapshots and the RCA
// tables only, over any session, not only the latest capture.

import { finestPerInterval, HOURLY_METRICS } from "@/data/finest-per-interval";
import { toBins, toCosmosCapture, toPostgresCapture, toWaitBins, withCategoryWaits } from "@/data/model";
import { incidentSeriesQuery, incidentWaitsQuery, type QuerySpec } from "@/data/queries";
import { isMissingInModel } from "@/data/retry";
import { SQL_TARGETS } from "@/lib/dax";
import { toDate as toInstant } from "@/lib/format";
import { loadEvidence, MONITOR_PAGES, MONITOR_ROW_LIMIT, MONITOR_TABLE, RcaReadError, rcaMonitorDax, type DaxLog } from "./loader";
import { toDate } from "./rows";
import type { Telemetry } from "./tools";
import { pointKey, type Evidence, type RcaTarget } from "./types";

type Row = Record<string, unknown>;

/** Runs one query on the history model as the viewer: the app's query client in production, fixtures in the tests. */
export type RunQuery = (spec: QuerySpec) => Promise<Row[]>;

export interface RcaSources {
    load(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Evidence>;
    telemetry(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Telemetry>;
}

// One point per interval, from the history's overlapping saves: the shared finestPerInterval (F35, from the release's
// follow-ups, src/data/finest-per-interval.ts), which the app's T4 and T5 views read through too. Its rows go once to
// the pure decoders (toPostgresCapture, toCosmosCapture): its output isn't valid input again. Re-exported for the tests.
export { finestPerInterval };

/**
 * The coarsest interval of the history's points at each time, by pointKey, read before finestPerInterval keeps one point
 * per interval: a key an earlier list made from a coarser save's point (B's day-long save, 15 minutes at 15:30) reads as
 * the incident in that point's interval, as it did then (the review of 97fdf5ba). A point's grain is the shared
 * function's: its save's step, the smallest gap in any of the save's series, and at least an hour for T5's hourly metrics.
 */
export function coarsestIntervals(rows: readonly Row[]): Map<string, number> {
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
    const out = new Map<string, number>();
    for (const row of rows) {
        const at = toInstant(row.Bucket);
        if (!at) continue;
        const step = captureStep.get(captureOf(row)) ?? 0;
        const grain = HOURLY_METRICS.has(String(row.Metric)) ? Math.max(60 * 60_000, step) : step;
        const key = pointKey(String(row.TargetKey), String(row.Metric), at);
        if (grain > (out.get(key) ?? 0)) out.set(key, grain);
    }
    return out;
}

/**
 * Azure Monitor's rows as the investigations read them, from one call of the shared finestPerInterval: one point per
 * interval with its span (intervals) and its save's step (grains), the source of each piece of a coarser point and which
 * pieces are upper bounds, and each time's coarsest point (keyIntervals).
 */
export function monitorTelemetry(rows: readonly Row[]): Pick<Telemetry, "postgres" | "cosmos" | "intervals" | "grains" | "sources" | "upperBounds" | "keyIntervals"> {
    const { kept, intervals, grains, sources, upperBounds } = finestPerInterval(rows);
    return {
        postgres: toPostgresCapture(kept.filter((r) => r.TargetKey === "T4" || r.TargetKey === "T4-replica")),
        cosmos: toCosmosCapture(kept.filter((r) => r.TargetKey === "T5")),
        intervals,
        grains,
        sources,
        upperBounds,
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
     * Azure Monitor's rows for a window, a page at a time. A query returns at most MONITOR_ROW_LIMIT rows, oldest first, so
     * one at the limit had lost its newest rows: the incident's own minutes (the coordinator's note on the shared
     * finestPerInterval). The next page reads on from the last bucket the page had, whole, in place of that bucket's rows.
     * After MONITOR_PAGES pages, the rest isn't read, and the window's investigations say so (cut).
     */
    async function readMonitor(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<{ rows: Row[]; cut: boolean }> {
        const rows: Row[] = [];
        let start = from;
        for (let page = 0; page < MONITOR_PAGES; page++) {
            const dax = rcaMonitorDax(start, to, targets);
            if (!dax) return { rows, cut: false };
            const got = await read(MONITOR_TABLE, spec("Azure Monitor metrics", dax, MONITOR_ROW_LIMIT));
            if (got.length < MONITOR_ROW_LIMIT) return { rows: [...rows, ...got], cut: false };
            const last = toDate(got[got.length - 1].Bucket);
            // A page all of one bucket can't read on.
            if (!last || last.getTime() <= start.getTime()) return { rows: [...rows, ...got], cut: true };
            for (const row of got) if ((toDate(row.Bucket)?.getTime() ?? 0) < last.getTime()) rows.push(row);
            start = last;
        }
        return { rows, cut: true };
    }

    return {
        load: (from, to, targets) => loadEvidence((dax, rowLimit) => run(spec("RCA evidence", dax, rowLimit)), from, to, targets, { onDax }),
        async telemetry(from, to, targets) {
            const sql = SQL_TARGETS.filter((t) => targets.includes(t));
            const [bins, monitor] = await Promise.all([
                Promise.all(
                    sql.map(async (target) => {
                        const range = { target, start: from, end: to };
                        const [series, waits] = await Promise.all([read("Telemetry Snapshots", incidentSeriesQuery(range)), read("Telemetry Snapshots", incidentWaitsQuery(range))]);
                        return withCategoryWaits(toBins(series, target), toWaitBins(waits));
                    }),
                ),
                readMonitor(from, to, targets),
            ]);
            return { bins: bins.flat(), ...monitorTelemetry(monitor.rows), ...(monitor.cut ? { cut: [MONITOR_TABLE] } : {}) };
        },
    };
}
