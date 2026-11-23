// The production loader: one bounded DAX query per RCA table for a window and its targets, as the signed-in viewer,
// through the history connector's executeQuery (as run_dax does), mapped to evidence rows by the model's columns.
// Detection reads only the detection tables and the telemetry: never the answer key (rca/blind-detection.json).

import { isMissingInModel, retryHint } from "@/data/retry";
import { ROW_MAPPERS, toDate, type Get } from "./rows";
import { emptySidecar, SIDECAR_MAPPERS, SIDECAR_MEMBER, type SidecarEvidence } from "./sidecar";
import { PHASE_1_TABLES, RCA_SPEC, SIDECAR_SPEC, SIDECAR_TABLES, TARGET_KEY, type RcaTableKey, type SidecarTableKey, type TableSpec } from "./spec";
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

/**
 * One table's rows for the window and targets, oldest first. A table of intervals (its spec's `end`: RCA Coverage, RCA
 * Waits, RCA Query Stats) keeps every interval that overlaps the window: a session exported once has one coverage row from
 * its start to its end; a table with more spans (RCA Query Coverage) keeps a row when any of them does. A table with
 * 64-bit IDs (spec.ts's id) returns them as text, converted in DAX ([CONVERT](https://learn.microsoft.com/dax/convert-function-dax)),
 * since the connector's JSON would round them to a JavaScript number.
 */
export function tableDax(spec: TableSpec, from: Date, to: Date, targets: readonly RcaTarget[]): string {
    const col = (field: string) => `'${spec.model}'[${spec.fields[field].model}]`;
    const t = col(spec.time);
    const list = targets.map((target) => `"${target}"`).join(", ");
    const overlaps = (start: string, end: string) => `( ${col(end)} >= ${daxTime(from)} && ${col(start)} <= ${daxTime(to)} )`;
    const bounds = spec.spans?.length
        ? [`    FILTER ( '${spec.model}', ${[[spec.time, spec.end ?? spec.time] as const, ...spec.spans].map(([start, end]) => overlaps(start, end)).join(" || ")} ),`]
        : [spec.end ? `    ${col(spec.end)} >= ${daxTime(from)},` : `    ${t} >= ${daxTime(from)},`, `    ${t} <= ${daxTime(to)},`];
    const table = ["CALCULATETABLE (", `    '${spec.model}',`, ...bounds, `    TREATAS ( { ${list} }, '${TARGET_KEY.table}'[${TARGET_KEY.column}] )`, ")"];
    const fields = Object.values(spec.fields);
    if (!fields.some((field) => field.kind === "id")) return ["EVALUATE", ...table, `ORDER BY ${t}`].join("\n");
    const columns = fields.map((field, i) => {
        const ref = `'${spec.model}'[${field.model}]`;
        return `    "${field.model}", ${field.kind === "id" ? `CONVERT ( ${ref}, STRING )` : ref}${i < fields.length - 1 ? "," : ""}`;
    });
    return ["EVALUATE", "SELECTCOLUMNS (", ...table.map((line, i) => `    ${line}${i === table.length - 1 ? "," : ""}`), ...columns, ")", `ORDER BY [${spec.fields[spec.time].model}]`].join("\n");
}

/** One RCA table's rows for the window and targets, oldest first (tableDax). */
export function rcaDax(key: RcaTableKey, from: Date, to: Date, targets: readonly RcaTarget[]): string {
    return tableDax(RCA_SPEC[key], from, to, targets);
}

/** One sidecar table's rows for the window and targets, oldest first (tableDax). */
export function sidecarDax(key: SidecarTableKey, from: Date, to: Date, targets: readonly RcaTarget[]): string {
    return tableDax(SIDECAR_SPEC[key], from, to, targets);
}

/** Whether the model has the RCA tables: the app offers the RCA view and its tools only when it does. */
export const RCA_PRESENCE_DAX = `EVALUATE ROW ( "Rows", COUNTROWS ( '${RCA_SPEC.coverage.model}' ) )`;

/**
 * Whether the model has the sidecar's tables, Query Store's evidence: the chat gets their guide only when it does. One query
 * names all six, so a model without one of them answers that it doesn't know it, which loadSidecar reads as missing.
 */
export const SIDECAR_PRESENCE_DAX = `EVALUATE ROW ( ${SIDECAR_TABLES.map((key) => `"${key}", COUNTROWS ( '${SIDECAR_SPEC[key].model}' )`).join(", ")} )`;

/** The Azure Monitor targets: T4, its read replica, and T5, whose metrics the history keeps as analyses postgresql and cosmosdb. */
export const MONITOR_TARGETS = ["T4", "T4-replica", "T5"] as const satisfies readonly RcaTarget[];

/** The most Azure Monitor rows one query returns: a 1-minute grain, about ten metrics, and overlapping captures. */
export const MONITOR_ROW_LIMIT = 5000;

/** The most queries, a page each, that one window's Azure Monitor read makes (sources.ts): as many rows as an RCA table's most. */
export const MONITOR_PAGES = 4;

/** The Azure Monitor read's name in the logs and in what wasn't captured. */
export const MONITOR_TABLE = "Telemetry Snapshots (Azure Monitor)";

/** Database Hub's bins of one target, and their waits by category, as their paged reads (sources.ts) are named in the logs and in what wasn't captured. */
export const binsTable = (target: RcaTarget) => `Telemetry Snapshots (${target}'s bins)`;
export const waitsTable = (target: RcaTarget) => `Telemetry Snapshots (${target}'s waits)`;

/** Whether a read is paged, MONITOR_PAGES queries of at most MONITOR_ROW_LIMIT rows (sources.ts): Azure Monitor's, and Database Hub's bins and waits. */
export const isPagedTable = (table: string) => table === MONITOR_TABLE || /^Telemetry Snapshots \(T[1-3]'s (bins|waits)\)$/.test(table);

/**
 * Every capture's Azure Monitor metrics for the window's T4, replica, and T5 (Telemetry Snapshots only), oldest first, or
 * null when the window has none of them. Captures can overlap: sources.ts keeps one point per interval, the finest.
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
                const map = ROW_MAPPERS[key] as (get: Get) => unknown;
                const mapped = rows.map((row) => map((field) => (fields[field] ? row[fields[field].model] : undefined))).filter((r) => r !== null);
                (evidence[key] as unknown[]).push(...mapped);
                // Rows come oldest first: one at the limit read up to its last row's time, whose rows may be only some of them
                // (the review of d431edb4: what it says it found holds only up to there).
                if (rows.length >= limit) (evidence.cut ??= []).push({ table: spec.model, until: toDate(rows[rows.length - 1][fields[spec.time].model]) ?? to });
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

/**
 * How long after a window its plans are read: RCA-SQL-14 reads the plans of the queries each read of RCA-SQL-10 returned,
 * at that read's time, which is up to an interval and 2 minutes after the interval it read (rca/README.md, Query Store).
 */
export const PLAN_LAG_MINUTES = 30;

export interface SidecarLoadOptions {
    tables?: readonly SidecarTableKey[];
    onDax?: (log: DaxLog) => void;
}

/**
 * The window's sidecar rows from the history model: Query Store's statistics and waits of every interval that overlaps the
 * window, its plans as the window's reads saw them (to PLAN_LAG_MINUTES past it), its events, the coverage rows whose
 * window, intervals read, or pending publication overlap it, and T4's connection groups. As loadEvidence: a table the
 * model doesn't have is left empty and named in `missing` (a model from before the sidecar, which is never "none"); any
 * other read that fails fails the load (RcaReadError).
 */
export async function loadSidecar(runDax: RunDax, from: Date, to: Date, targets: readonly RcaTarget[], options: SidecarLoadOptions = {}): Promise<SidecarEvidence> {
    const sidecar = emptySidecar();
    const failed: Array<{ table: string; error: unknown }> = [];
    await Promise.all(
        (options.tables ?? SIDECAR_TABLES).map(async (key) => {
            const spec = SIDECAR_SPEC[key];
            const end = key === "queryPlans" ? new Date(to.getTime() + PLAN_LAG_MINUTES * 60_000) : to;
            const limit = rcaRowLimit(from, end);
            const query = sidecarDax(key, from, end, targets);
            const fields = spec.fields as Record<string, { model: string }>;
            const started = Date.now();
            try {
                const rows = await runDax(query, limit);
                const map = SIDECAR_MAPPERS[key] as (get: Get) => unknown;
                const mapped = rows.map((row) => map((field) => (fields[field] ? row[fields[field].model] : undefined))).filter((r) => r !== null);
                (sidecar[SIDECAR_MEMBER[key]] as unknown[]).push(...mapped);
                if (rows.length >= limit) (sidecar.cut ??= []).push({ table: spec.model, until: toDate(rows[rows.length - 1][fields[spec.time].model]) ?? end });
                options.onDax?.({ table: spec.model, query, rows: rows.length, ms: Date.now() - started });
            } catch (err) {
                options.onDax?.({ table: spec.model, query, rows: 0, error: err instanceof Error ? err.message : String(err), ms: Date.now() - started });
                if (isMissingInModel(err)) sidecar.missing.push(spec.model);
                else failed.push({ table: spec.model, error: err });
            }
        }),
    );
    if (failed.length > 0) throw new RcaReadError(failed);
    sidecar.missing.sort();
    return sidecar;
}
