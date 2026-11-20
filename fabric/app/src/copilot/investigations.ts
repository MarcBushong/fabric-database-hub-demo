// The dock's investigation tools (ADR 0031): src/rca's six tools over the history model, run in the page as the signed-in
// viewer, like run_dax, and offered only when the model has the RCA tables. Loaded with the chat's other modules.

import type { QueryClient } from "@/data/query-client";
import { createRcaClient } from "@/rca/client";
import type { DaxRun, ToolOutcome } from "./tools";

export { dayIn, hasRcaTables, NEWEST_BIN_DAX } from "@/rca/client";

export interface InvestigationOptions {
    /** The viewer's time zone; the browser's by default. */
    timeZone?: string;
    /** Each query the investigations ran, for the dock's "Show the DAX". */
    onDax?: (run: DaxRun) => void;
    now?: () => Date;
}

export function createInvestigations(client: QueryClient, options: InvestigationOptions = {}) {
    const now = options.now ?? (() => new Date());
    let n = 0;
    const rca = createRcaClient(client, {
        timeZone: options.timeZone,
        now,
        onDax: (entry) =>
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
            }),
    });
    return {
        async run(name: string, args: unknown): Promise<ToolOutcome> {
            const tools = await rca.tools();
            return tools.run(name, args);
        },
    };
}
