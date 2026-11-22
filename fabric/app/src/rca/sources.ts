// Where the investigations read in the app, for the dock and the RCA view: the RCA tables (loader.ts), Database Hub's
// bins for T1 to T3 (the replay's own queries), and the Azure Monitor metrics of T4, its read replica, and T5, each a
// bounded DAX query on the history model as the signed-in viewer. Blind (ADR 0031): Telemetry Snapshots and the RCA
// tables only, over any session, not only the latest capture.

import { toBins, toCosmosCapture, toPostgresCapture, toWaitBins, withCategoryWaits } from "@/data/model";
import { incidentSeriesQuery, incidentWaitsQuery, type QuerySpec } from "@/data/queries";
import { isMissingInModel } from "@/data/retry";
import { SQL_TARGETS } from "@/lib/dax";
import { loadEvidence, MONITOR_ROW_LIMIT, RcaReadError, rcaMonitorDax, type DaxLog } from "./loader";
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

/**
 * Azure Monitor's points for the RCA, one per interval, with each point's own interval (by pointKey). The history keeps
 * every save, each at its own grain (1 to 1,440 minutes, the smallest that fits), so one minute can be in several: the
 * finest grain is kept first, and of equal grains the newest capture. A coarser point whose interval overlaps a kept one
 * is left out, so no minute counts twice. The model's measures keep the newest capture of each bin instead, which kept
 * B's day-long save at 15 minutes beside the session's own 1-minute points: T5's requests and 429s for 15:30 to 15:42
 * counted both, and the replica's lag at 16:15 read as 5 minutes at 178 s, the 15 minutes' highest (the review of
 * 803f2b1a). A point's grain is its series' step in its capture, or else its capture's smallest.
 */
export function finestPerInterval(rows: readonly Row[]): { kept: Row[]; intervals: Map<string, number> } {
    const captureOf = (row: Row) => `${String(row.CapturedAt)}|${row.TargetKey === "T5" ? "cosmos" : "postgres"}`;
    const seriesOf = (row: Row) => `${String(row.CapturedAt)}|${String(row.TargetKey)}|${String(row.Metric)}`;
    const times = new Map<string, { capture: string; at: number[] }>();
    for (const row of rows) {
        const at = toDate(row.Bucket);
        if (!at) continue;
        const series = times.get(seriesOf(row)) ?? { capture: captureOf(row), at: [] };
        series.at.push(at.getTime());
        times.set(seriesOf(row), series);
    }
    const seriesStep = new Map<string, number>();
    const captureStep = new Map<string, number>();
    for (const [key, series] of times) {
        const sorted = [...new Set(series.at)].sort((a, b) => a - b);
        const gaps = sorted.slice(1).map((t, i) => t - sorted[i]);
        if (gaps.length === 0) continue;
        const step = Math.min(...gaps);
        seriesStep.set(key, step);
        captureStep.set(series.capture, Math.min(captureStep.get(series.capture) ?? step, step));
    }
    const groups = new Map<string, Array<{ row: Row; at: number; step: number; captured: number }>>();
    for (const row of rows) {
        const at = toDate(row.Bucket);
        if (!at) continue;
        const key = `${String(row.TargetKey)}|${String(row.Metric)}`;
        const group = groups.get(key) ?? [];
        group.push({ row, at: at.getTime(), step: seriesStep.get(seriesOf(row)) ?? captureStep.get(captureOf(row)) ?? 0, captured: toDate(row.CapturedAt)?.getTime() ?? 0 });
        groups.set(key, group);
    }
    const kept: Row[] = [];
    const intervals = new Map<string, number>();
    for (const group of groups.values()) {
        // The finest grain first, a point of unknown grain last; of equal grains, the newest capture.
        group.sort((a, b) => (a.step || Infinity) - (b.step || Infinity) || b.captured - a.captured || a.at - b.at);
        const taken: Array<[number, number]> = [];
        for (const p of group) {
            const end = p.at + Math.max(p.step, 1);
            if (taken.some(([start, stop]) => p.at < stop && start < end)) continue;
            taken.push([p.at, end]);
            kept.push(p.row);
            if (p.step > 0) intervals.set(pointKey(String(p.row.TargetKey), String(p.row.Metric), new Date(p.at)), p.step);
        }
    }
    return { kept: kept.sort((a, b) => (toDate(a.Bucket)?.getTime() ?? 0) - (toDate(b.Bucket)?.getTime() ?? 0)), intervals };
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

    return {
        load: (from, to, targets) => loadEvidence((dax, rowLimit) => run(spec("RCA evidence", dax, rowLimit)), from, to, targets, { onDax }),
        async telemetry(from, to, targets) {
            const sql = SQL_TARGETS.filter((t) => targets.includes(t));
            const monitor = rcaMonitorDax(from, to, targets);
            const [bins, monitorRows] = await Promise.all([
                Promise.all(
                    sql.map(async (target) => {
                        const range = { target, start: from, end: to };
                        const [series, waits] = await Promise.all([read("Telemetry Snapshots", incidentSeriesQuery(range)), read("Telemetry Snapshots", incidentWaitsQuery(range))]);
                        return withCategoryWaits(toBins(series, target), toWaitBins(waits));
                    }),
                ),
                monitor ? read("Telemetry Snapshots (Azure Monitor)", spec("Azure Monitor metrics", monitor, MONITOR_ROW_LIMIT)) : Promise.resolve([]),
            ]);
            const { kept: rows, intervals } = finestPerInterval(monitorRows);
            return {
                bins: bins.flat(),
                postgres: toPostgresCapture(rows.filter((r) => r.TargetKey === "T4" || r.TargetKey === "T4-replica")),
                cosmos: toCosmosCapture(rows.filter((r) => r.TargetKey === "T5")),
                intervals,
            };
        },
    };
}
