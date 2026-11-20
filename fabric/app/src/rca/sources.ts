// Where the investigations read in the app, for the dock and the RCA view: the RCA tables (loader.ts), Database Hub's
// bins for T1 to T3 (the replay's own queries), and the Azure Monitor metrics of T4, its read replica, and T5, each a
// bounded DAX query on the history model as the signed-in viewer. Blind (ADR 0031): Telemetry Snapshots and the RCA
// tables only, over any session, not only the latest capture.

import { toBins, toCosmosCapture, toPostgresCapture, toWaitBins, withCategoryWaits } from "@/data/model";
import { incidentSeriesQuery, incidentWaitsQuery, type QuerySpec } from "@/data/queries";
import { SQL_TARGETS } from "@/lib/dax";
import { loadEvidence, MONITOR_ROW_LIMIT, rcaMonitorDax, type DaxLog } from "./loader";
import { toDate } from "./rows";
import type { Telemetry } from "./tools";
import type { Evidence, RcaTarget } from "./types";

type Row = Record<string, unknown>;

/** Runs one query on the history model as the viewer: the app's query client in production, fixtures in the tests. */
export type RunQuery = (spec: QuerySpec) => Promise<Row[]>;

export interface RcaSources {
    load(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Evidence>;
    telemetry(from: Date, to: Date, targets: readonly RcaTarget[]): Promise<Telemetry>;
}

/** The newest capture of each target, metric, and bin, as the model's measures keep it: captures can overlap. */
export function newestCapturePerBin(rows: readonly Row[]): Row[] {
    const kept = new Map<string, Row>();
    for (const row of rows) {
        const at = toDate(row.Bucket);
        if (!at) continue;
        const key = `${String(row.TargetKey)}|${String(row.Metric)}|${at.getTime()}`;
        const prior = kept.get(key);
        if (!prior || (toDate(row.CapturedAt)?.getTime() ?? 0) > (toDate(prior.CapturedAt)?.getTime() ?? 0)) kept.set(key, row);
    }
    return [...kept.values()];
}

function hash(text: string): string {
    let h = 5381;
    for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36);
}

export function createRcaSources(run: RunQuery, onDax?: (log: DaxLog) => void): RcaSources {
    const spec = (title: string, dax: string, rowLimit: number): QuerySpec => ({ id: `rca-${hash(dax)}`, title, dax, rowLimit, columns: [] });

    /** One telemetry query, logged; a failure leaves its part empty, and the investigations say what they didn't have. */
    async function read(table: string, query: QuerySpec): Promise<Row[]> {
        const started = Date.now();
        try {
            const rows = await run(query);
            onDax?.({ table, query: query.dax, rows: rows.length, ms: Date.now() - started });
            return rows;
        } catch (err) {
            onDax?.({ table, query: query.dax, rows: 0, error: err instanceof Error ? err.message : String(err), ms: Date.now() - started });
            return [];
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
            const rows = newestCapturePerBin(monitorRows);
            return {
                bins: bins.flat(),
                postgres: toPostgresCapture(rows.filter((r) => r.TargetKey === "T4" || r.TargetKey === "T4-replica")),
                cosmos: toCosmosCapture(rows.filter((r) => r.TargetKey === "T5")),
            };
        },
    };
}
