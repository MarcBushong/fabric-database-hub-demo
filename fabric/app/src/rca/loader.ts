// The production loader: one bounded DAX query per RCA table for a window and its targets, as the signed-in viewer,
// through the history connector's executeQuery (as run_dax does), mapped to evidence rows by the model's columns.
// Detection reads only the detection tables and the telemetry: never the answer key (rca/blind-detection.json).

import { isMissingInModel, retryHint } from "@/data/retry";
import { ROW_MAPPERS } from "./rows";
import { PHASE_1_TABLES, RCA_SPEC, TARGET_KEY, type RcaTableKey } from "./spec";
import { emptyEvidence, type Evidence, type RcaTarget } from "./types";

/** Rows of one DAX query, keyed by the model's column names (src/data/query-client.ts normalizes them). */
export type RunDax = (query: string, rowLimit: number) => Promise<Array<Record<string, unknown>>>;

/**
 * Reads of the history that failed, after the retries a throttled or failed read gets (src/data/retry.ts): what the
 * window holds isn't known, so nothing is concluded from it, and nothing reads as "not captured" or "nothing abnormal"
 * (live, 2026-11-21: Power BI's Execute Queries answered 429 to the app's reads).
 */
export class RcaReadError extends Error {
    /** The tables, or telemetry, that couldn't be read. */
    readonly tables: string[];

    constructor(failures: ReadonlyArray<{ table: string; error: unknown }>) {
        const byText = new Map<string, string[]>();
        for (const { table, error } of failures) {
            const text = error instanceof Error ? error.message : String(error);
            byText.set(text, [...(byText.get(text) ?? []), table]);
        }
        const what = [...byText].map(([text, tables]) => `${[...new Set(tables)].join(", ")}: ${text}`).join("; ");
        const hint = retryHint(failures.map((f) => f.error));
        super(`The history couldn't be read, so nothing is concluded from it (${what}).${hint ? ` ${hint}` : ""}`);
        this.name = "RcaReadError";
        this.tables = [...new Set(failures.map((f) => f.table))];
    }
}

/** The most rows one table returns per 30 minutes of window; a 30-minute window of 10-second chains is about 1,000. */
export const RCA_ROW_LIMIT = 2000;

/** The most rows one table returns for any window, whatever its length. */
export const RCA_MAX_ROWS = 20000;

/** One table's row limit for a window: RCA_ROW_LIMIT per 30 minutes, at most RCA_MAX_ROWS. */
export function rcaRowLimit(from: Date, to: Date): number {
    const halfHours = Math.max(1, Math.ceil((to.getTime() - from.getTime()) / 1_800_000));
    return Math.min(RCA_MAX_ROWS, halfHours * RCA_ROW_LIMIT);
}

export interface DaxLog {
    table: string;
    query: string;
    rows: number;
    error?: string;
    ms?: number;
}

const daxTime = (d: Date) =>
    `DATE ( ${d.getUTCFullYear()}, ${d.getUTCMonth() + 1}, ${d.getUTCDate()} ) + TIME ( ${d.getUTCHours()}, ${d.getUTCMinutes()}, ${d.getUTCSeconds()} )`;

/** One table's rows for the window and targets, oldest first. A table of intervals (RCA Coverage, RCA Waits) keeps every
 *  interval that overlaps the window: a session exported once has one coverage row from its start to its end. */
export function rcaDax(key: RcaTableKey, from: Date, to: Date, targets: readonly RcaTarget[]): string {
    const spec = RCA_SPEC[key];
    const fields = spec.fields as Record<string, { model: string }>;
    const time = fields[spec.time].model;
    const t = `'${spec.model}'[${time}]`;
    const end = spec.time === "from" && fields.to ? `'${spec.model}'[${fields.to.model}]` : null;
    const list = targets.map((target) => `"${target}"`).join(", ");
    return [
        "EVALUATE",
        "CALCULATETABLE (",
        `    '${spec.model}',`,
        end ? `    ${end} >= ${daxTime(from)},` : `    ${t} >= ${daxTime(from)},`,
        `    ${t} <= ${daxTime(to)},`,
        `    TREATAS ( { ${list} }, '${TARGET_KEY.table}'[${TARGET_KEY.column}] )`,
        ")",
        `ORDER BY ${t}`,
    ].join("\n");
}

/** Whether the model has the RCA tables: the app offers the RCA view and its tools only when it does. */
export const RCA_PRESENCE_DAX = `EVALUATE ROW ( "Rows", COUNTROWS ( '${RCA_SPEC.coverage.model}' ) )`;

/** The Azure Monitor targets: T4, its read replica, and T5, whose metrics the history keeps as analyses postgresql and cosmosdb. */
export const MONITOR_TARGETS = ["T4", "T4-replica", "T5"] as const satisfies readonly RcaTarget[];

/** The most Azure Monitor rows one window returns: a 1-minute grain, about ten metrics, and overlapping captures. */
export const MONITOR_ROW_LIMIT = 5000;

/**
 * Every capture's Azure Monitor metrics for the window's T4, replica, and T5 (Telemetry Snapshots only), oldest first, or
 * null when the window has none of them. Captures can overlap: sources.ts keeps the newest of each bin, as the measures do.
 */
export function rcaMonitorDax(from: Date, to: Date, targets: readonly RcaTarget[]): string | null {
    const keys = MONITOR_TARGETS.filter((t) => targets.includes(t));
    if (keys.length === 0) return null;
    const col = (name: string) => `'Telemetry Snapshots'[${name}]`;
    return [
        "EVALUATE",
        "SELECTCOLUMNS (",
        "    CALCULATETABLE (",
        "        'Telemetry Snapshots',",
        "        REMOVEFILTERS (),",
        `        ${col("Analysis Key")} IN { "postgresql", "cosmosdb" },`,
        `        ${col("Target Key")} IN { ${keys.map((k) => `"${k}"`).join(", ")} },`,
        `        ${col("Bucket UTC")} >= ${daxTime(from)},`,
        `        ${col("Bucket UTC")} <= ${daxTime(to)}`,
        "    ),",
        `    "Bucket", ${col("Bucket UTC")},`,
        `    "TargetKey", ${col("Target Key")},`,
        `    "ResourceName", ${col("Resource Name")},`,
        `    "Metric", ${col("Metric")},`,
        `    "Value", ${col("Value")},`,
        `    "Unit", ${col("Unit")},`,
        `    "WindowStart", ${col("Window Start UTC")},`,
        `    "WindowEnd", ${col("Window End UTC")},`,
        `    "CapturedAt", ${col("Captured At UTC")}`,
        ")",
        "ORDER BY [Bucket] ASC, [TargetKey] ASC, [Metric] ASC",
    ].join("\n");
}

export interface LoadOptions {
    tables?: readonly RcaTableKey[];
    onDax?: (log: DaxLog) => void;
}

/**
 * The window's evidence from the history model. A table the model doesn't have (an older model, Phase 2's waits) is left
 * empty and logged, so it never hides the rest; the coverage rows say what was captured. Any other read that fails is
 * logged too, and then fails the load (RcaReadError), because an empty table there would read as nothing captured.
 */
export async function loadEvidence(runDax: RunDax, from: Date, to: Date, targets: readonly RcaTarget[], options: LoadOptions = {}): Promise<Evidence> {
    const evidence = emptyEvidence();
    const tables = options.tables ?? PHASE_1_TABLES;
    const limit = rcaRowLimit(from, to);
    const failed: Array<{ table: string; error: unknown }> = [];
    await Promise.all(
        tables.map(async (key) => {
            const spec = RCA_SPEC[key];
            const fields = spec.fields as Record<string, { model: string }>;
            const query = rcaDax(key, from, to, targets);
            const started = Date.now();
            try {
                const rows = await runDax(query, limit);
                const map = ROW_MAPPERS[key] as (get: (field: string) => unknown) => unknown;
                const mapped = rows.map((row) => map((field) => (fields[field] ? row[fields[field].model] : undefined))).filter((r) => r !== null);
                (evidence[key] as unknown[]).push(...mapped);
                if (rows.length >= limit) (evidence.cut ??= []).push(spec.model);
                options.onDax?.({ table: spec.model, query, rows: rows.length, ms: Date.now() - started });
            } catch (err) {
                options.onDax?.({ table: spec.model, query, rows: 0, error: err instanceof Error ? err.message : String(err), ms: Date.now() - started });
                if (!isMissingInModel(err)) failed.push({ table: spec.model, error: err });
            }
        }),
    );
    if (failed.length > 0) throw new RcaReadError(failed);
    return evidence;
}
