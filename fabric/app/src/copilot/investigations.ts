// The dock's investigation tools (ADR 0031): src/rca's six tools over the history model, run in the page as the signed-in
// viewer, like run_dax, and offered only when the model has the RCA tables. Loaded with the chat's other modules.

import type { QueryClient } from "@/data/query-client";
import { RCA_PRESENCE_DAX, type DaxLog } from "@/rca/loader";
import { toDate } from "@/rca/rows";
import { createRcaSources } from "@/rca/sources";
import { createInvestigationTools, type InvestigationTools } from "@/rca/tools";
import type { DaxRun, ToolOutcome } from "./tools";

/** The newest telemetry bin in the history: bare times ("11:56") are on its day, in the viewer's time zone. */
export const NEWEST_BIN_DAX = `EVALUATE ROW ( "Newest", CALCULATE ( MAX ( 'Telemetry Snapshots'[Bucket UTC] ), REMOVEFILTERS () ) )`;

/** Whether the history model has the RCA tables: false for a model from before the feature, or when the query fails. */
export async function hasRcaTables(client: QueryClient): Promise<boolean> {
    try {
        await client.run({ id: "copilot-has-rca", title: "Copilot: RCA history", dax: RCA_PRESENCE_DAX, rowLimit: 1, columns: [] });
        return true;
    } catch {
        return false;
    }
}

/** Midnight UTC of the day `at` falls on in `timeZone`, as src/rca/time.ts's resolveTime reads a day. */
export function dayIn(at: Date, timeZone: string): Date {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(at);
    const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
    return new Date(Date.UTC(get("year"), get("month") - 1, get("day")));
}

export interface InvestigationOptions {
    /** The viewer's time zone; the browser's by default. */
    timeZone?: string;
    /** Each query the investigations ran, for the dock's "Show the DAX". */
    onDax?: (run: DaxRun) => void;
    now?: () => Date;
}

export function createInvestigations(client: QueryClient, options: InvestigationOptions = {}) {
    const timeZone = options.timeZone ?? (Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC");
    const now = options.now ?? (() => new Date());
    let n = 0;
    const log = (entry: DaxLog) =>
        options.onDax?.({
            id: `i${++n}`,
            query: entry.query,
            purpose: `Investigation: ${entry.table}`,
            columns: [],
            rows: [],
            rowCount: entry.rows,
            error: entry.error,
            ms: entry.ms ?? 0,
            at: now(),
        });
    const sources = createRcaSources(async (spec) => (await client.run(spec)).rows, log);
    let tools: Promise<InvestigationTools> | null = null;
    const ready = () =>
        (tools ??= (async () => {
            let newest: Date | undefined;
            try {
                const result = await client.run({ id: "copilot-newest-bin", title: "Copilot: newest telemetry", dax: NEWEST_BIN_DAX, rowLimit: 1, columns: [] });
                newest = toDate(result.rows[0]?.Newest);
            } catch {
                newest = undefined;
            }
            return createInvestigationTools({ load: sources.load, telemetry: sources.telemetry, timeZone, latestDay: dayIn(newest ?? now(), timeZone), latest: newest });
        })());
    return {
        async run(name: string, args: unknown): Promise<ToolOutcome> {
            const investigations = await ready();
            return investigations.run(name, args);
        },
    };
}
