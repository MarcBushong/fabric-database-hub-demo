// Builds what "Ask Copilot" and "Ask why" hand to the chat: the visual's title, its rows (bounded), the DAX behind
// them, where the data comes from, and the filter in force.

import { MAX_CONTEXT_ROWS, type AnomalyContext, type AskContext, type ContextColumn, type ContextRow, type DataProvenance } from "@/copilot/contract";
import type { Meta } from "@/data/model";
import type { ColumnSpec, Filters, QuerySpec } from "@/data/queries";
import { formatIsoDay } from "./format";
import { WINDOWS, type PageId, type WindowId } from "./view-state";

const UNIT: Partial<Record<string, string>> = { percent: "%", seconds: "s", minutes: "min", mb: "MB" };

/** Dates become ISO 8601 UTC text, so the rows are plain JSON. */
function plain(value: unknown): unknown {
    if (value instanceof Date) return Number.isFinite(value.getTime()) ? value.toISOString() : null;
    return value;
}

export function contextRows(rows: ReadonlyArray<Record<string, unknown>>, columns?: readonly ColumnSpec[]): ContextRow[] {
    const keys = columns?.map((c) => c.key);
    return rows.slice(0, MAX_CONTEXT_ROWS).map((row) => {
        const out: ContextRow = {};
        for (const key of keys ?? Object.keys(row)) out[key] = plain(row[key]);
        return out;
    });
}

export function contextColumns(columns: readonly ColumnSpec[]): ContextColumn[] {
    return columns.map((c) => ({ key: c.key, label: c.label, kind: c.kind, ...(UNIT[c.kind] ? { unit: UNIT[c.kind] } : {}) }));
}

/** Every query behind a visual, each after a "// title" line. */
export function joinDax(specs: ReadonlyArray<QuerySpec | null | undefined>): string | undefined {
    const shown = specs.filter((s): s is QuerySpec => Boolean(s));
    return shown.length > 0 ? shown.map((s) => `// ${s.title}\n${s.dax}`).join("\n\n") : undefined;
}

export interface AskInput {
    title: string;
    page: PageId;
    visualId: string;
    specs?: ReadonlyArray<QuerySpec | null | undefined>;
    rows?: ReadonlyArray<Record<string, unknown>>;
    columns?: readonly ColumnSpec[];
    prompt?: string;
    provenance: DataProvenance;
    meta: Meta | null;
    filters?: Filters;
    window?: WindowId;
    anomaly?: AnomalyContext;
    /** When the rows were read, for live data; history visuals take the newest snapshot's time from meta. */
    asOf?: string;
}

export function buildAskContext(input: AskInput): AskContext {
    const rows = input.rows ?? [];
    const ctx: AskContext = {
        title: input.title,
        page: input.page,
        visualId: input.visualId,
        source: input.provenance,
    };
    if (input.prompt) ctx.prompt = input.prompt;
    const dax = joinDax(input.specs ?? []);
    if (dax) ctx.dax = dax;
    if (input.rows) {
        ctx.rows = contextRows(rows, input.columns);
        ctx.totalRows = rows.length;
        ctx.truncated = rows.length > MAX_CONTEXT_ROWS;
    }
    if (input.columns) ctx.columns = contextColumns(input.columns);
    if (input.asOf) ctx.asOf = input.asOf;
    else if (input.meta?.latestCapture) ctx.asOf = input.meta.latestCapture.toISOString();
    if (input.filters) {
        ctx.filters = {
            targets: [...input.filters.targets],
            ...(input.window ? { period: WINDOWS.find((w) => w.id === input.window)?.label } : {}),
            ...(input.filters.window ? { from: formatIsoDay(input.filters.window.from), to: formatIsoDay(input.filters.window.to) } : {}),
        };
    }
    if (input.anomaly) ctx.anomaly = input.anomaly;
    return ctx;
}
