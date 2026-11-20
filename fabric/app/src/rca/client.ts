// The Incident RCA's client in the app (ADR 0031): whether the history model has the RCA tables, and the six
// investigations over it, as the signed-in viewer, for the Root cause view and the dock alike. Detection code: it reads
// the RCA tables and Telemetry Snapshots only (sources.ts).

import type { QueryClient } from "@/data/query-client";
import { RCA_PRESENCE_DAX, type DaxLog } from "./loader";
import { toDate } from "./rows";
import { createRcaSources } from "./sources";
import { createInvestigationTools, type InvestigationTools } from "./tools";

/** The newest telemetry bin in the history: bare times ("11:56") are on its day, in the viewer's time zone. */
export const NEWEST_BIN_DAX = `EVALUATE ROW ( "Newest", CALCULATE ( MAX ( 'Telemetry Snapshots'[Bucket UTC] ), REMOVEFILTERS () ) )`;

/** Whether the history model has the RCA tables: false for a model from before the feature, or when the check fails. Callers keep the answer. */
export function hasRcaTables(client: QueryClient): Promise<boolean> {
    return client.run({ id: "rca-presence", title: "Incident RCA: are its tables in the model?", dax: RCA_PRESENCE_DAX, rowLimit: 1, columns: [] }).then(
        () => true,
        () => false,
    );
}

/** Midnight UTC of the day `at` falls on in `timeZone`, as time.ts's resolveTime reads a day. */
export function dayIn(at: Date, timeZone: string): Date {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(at);
    const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
    return new Date(Date.UTC(get("year"), get("month") - 1, get("day")));
}

export function browserTimeZone(): string {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

export interface RcaClientOptions {
    /** The viewer's time zone; the browser's by default. */
    timeZone?: string;
    /** Each query the investigations ran: the view's and the dock's "Show the DAX". */
    onDax?: (log: DaxLog) => void;
    now?: () => Date;
}

export interface RcaClient {
    readonly timeZone: string;
    /** The investigations, once the history's newest time is known (asked once). */
    tools(): Promise<InvestigationTools>;
    /** The history's newest telemetry time, or null when it has none. */
    latest(): Promise<Date | null>;
    /** The queries run since the last call, oldest first: the view's "Show the DAX". */
    drainLogs(): DaxLog[];
}

export function createRcaClient(client: QueryClient, options: RcaClientOptions = {}): RcaClient {
    const timeZone = options.timeZone ?? browserTimeZone();
    const now = options.now ?? (() => new Date());
    let logs: DaxLog[] = [];
    const sources = createRcaSources(
        async (spec) => (await client.run(spec)).rows,
        (log) => {
            logs.push(log);
            options.onDax?.(log);
        },
    );
    let newest: Promise<Date | null> | null = null;
    let tools: Promise<InvestigationTools> | null = null;
    const latest = () =>
        (newest ??= client.run({ id: "rca-newest-bin", title: "Incident RCA: the newest telemetry", dax: NEWEST_BIN_DAX, rowLimit: 1, columns: [] }).then(
            (result) => toDate(result.rows[0]?.Newest) ?? null,
            () => null,
        ));
    return {
        timeZone,
        latest,
        drainLogs: () => {
            const out = logs;
            logs = [];
            return out;
        },
        tools: () =>
            (tools ??= latest().then((at) =>
                createInvestigationTools({ load: sources.load, telemetry: sources.telemetry, timeZone, latestDay: dayIn(at ?? now(), timeZone), latest: at ?? undefined }),
            )),
    };
}
