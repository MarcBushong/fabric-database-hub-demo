// The Incident RCA's client in the app (ADR 0031): whether the history model has the RCA tables, and the six
// investigations over it, as the signed-in viewer, for the Root cause view and the dock alike. Detection code: it reads
// the RCA tables and Telemetry Snapshots only (sources.ts).

import type { QueryClient } from "@/data/query-client";
import type { QuerySpec } from "@/data/queries";
import { isMissingInModel, retryHint, withRetry, type RetryOptions } from "@/data/retry";
import { RCA_PRESENCE_DAX, RcaReadError, SIDECAR_PRESENCE_DAX, type DaxLog } from "./loader";
import { toDate } from "./rows";
import { createRcaSources } from "./sources";
import { createInvestigationTools, type InvestigationTools } from "./tools";

/** The newest telemetry bin in the history: bare times ("11:56") are on its day, in the viewer's time zone. */
export const NEWEST_BIN_DAX = `EVALUATE ROW ( "Newest", CALCULATE ( MAX ( 'Telemetry Snapshots'[Bucket UTC] ), REMOVEFILTERS () ) )`;

/** Whether the history model has the RCA tables, or why that isn't known. */
export type RcaCheck = { state: "present" } | { state: "absent" } | { state: "failed"; error: string };

/**
 * Whether the history model has the RCA tables: present; absent, when the model says it doesn't know RCA Coverage (a
 * model from before the feature); or failed. A check that fails, after the retries a throttled or failed read gets
 * (src/data/retry.ts), says nothing about the model, so it's never taken for absent (live, 2026-11-21: one throttled
 * check made Root cause say that no RCA capture was recorded, on a model with 643 RCA Sessions rows).
 */
export async function checkRcaTables(client: QueryClient, retry?: RetryOptions): Promise<RcaCheck> {
    return checkPresence(client, "rca-presence", "Incident RCA: are its tables in the model?", RCA_PRESENCE_DAX, retry);
}

/** Whether the history model has the sidecar's tables, Query Store's evidence, the same way: absent on a model from before them. */
export async function checkSidecarTables(client: QueryClient, retry?: RetryOptions): Promise<RcaCheck> {
    return checkPresence(client, "rca-sidecar-presence", "Incident RCA: are Query Store's tables in the model?", SIDECAR_PRESENCE_DAX, retry);
}

async function checkPresence(client: QueryClient, id: string, title: string, dax: string, retry?: RetryOptions): Promise<RcaCheck> {
    try {
        await withRetry(() => client.run({ id, title, dax, rowLimit: 1, columns: [] }), retry);
        return { state: "present" };
    } catch (err) {
        if (isMissingInModel(err)) return { state: "absent" };
        return { state: "failed", error: [err instanceof Error ? err.message : String(err), retryHint([err])].filter(Boolean).join(" ") };
    }
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
    /** How a throttled or failed read is tried again (src/data/retry.ts); its defaults otherwise. */
    retry?: RetryOptions;
}

export interface RcaClient {
    readonly timeZone: string;
    /** The investigations, once the history's newest time is known. A failed read isn't kept: the next call asks again. */
    tools(): Promise<InvestigationTools>;
    /** The history's newest telemetry time, or null when it has none; it rejects when that read fails. */
    latest(): Promise<Date | null>;
    /** The queries run since the last call, oldest first: the view's "Show the DAX". */
    drainLogs(): DaxLog[];
}

/** A promise kept for the next call, unless it fails: then the next call starts again. */
function keepUnlessFailed<T>(get: () => Promise<T> | null, set: (value: Promise<T> | null) => void, start: () => Promise<T>): Promise<T> {
    const kept = get();
    if (kept) return kept;
    const pending = start();
    set(pending);
    pending.catch(() => {
        if (get() === pending) set(null);
    });
    return pending;
}

export function createRcaClient(client: QueryClient, options: RcaClientOptions = {}): RcaClient {
    const timeZone = options.timeZone ?? browserTimeZone();
    const now = options.now ?? (() => new Date());
    let logs: DaxLog[] = [];
    // Every read, the presence check's way: tried again while it's throttled or failed, then failed for its caller.
    const read = (spec: QuerySpec) => withRetry(() => client.run(spec), options.retry);
    const sources = createRcaSources(
        async (spec) => (await read(spec)).rows,
        (log) => {
            logs.push(log);
            options.onDax?.(log);
        },
    );
    let newest: Promise<Date | null> | null = null;
    let tools: Promise<InvestigationTools> | null = null;
    // A failed read of the newest time isn't taken for an empty history: on today's date, bare times would land on the
    // wrong day, and a window without times would have no end.
    const latest = () =>
        keepUnlessFailed(
            () => newest,
            (value) => (newest = value),
            () =>
                read({ id: "rca-newest-bin", title: "Incident RCA: the newest telemetry", dax: NEWEST_BIN_DAX, rowLimit: 1, columns: [] }).then(
                    (result) => toDate(result.rows[0]?.Newest) ?? null,
                    (err: unknown) => {
                        throw new RcaReadError([{ table: "Telemetry Snapshots (its newest time)", error: err }]);
                    },
                ),
        );
    return {
        timeZone,
        latest,
        drainLogs: () => {
            const out = logs;
            logs = [];
            return out;
        },
        tools: () =>
            keepUnlessFailed(
                () => tools,
                (value) => (tools = value),
                () =>
                    latest().then((at) =>
                        createInvestigationTools({ load: sources.load, telemetry: sources.telemetry, sidecar: sources.sidecar, timeZone, latestDay: dayIn(at ?? now(), timeZone), latest: at ?? undefined, now }),
                    ),
            ),
    };
}
