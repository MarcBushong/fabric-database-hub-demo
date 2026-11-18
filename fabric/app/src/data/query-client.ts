// Runs catalog queries through a data source, with a bounded, time-limited cache and in-flight de-duplication, so
// switching pages or themes never re-queries. Sources are pluggable: the history model through the read-only connector
// (the deployed app), the local preview's sample, and later a live source. Every result says which one answered.

import type { DataProvenance } from "@/copilot/contract";
import type { ColumnSpec, QuerySpec } from "./queries";

export type { DataProvenance };

export interface RawColumn {
    name: string;
    dataType: string;
}

/** The connector's normalized result (SemanticModelQueryResult from @microsoft/rayfin-connector-fabric-semanticmodel). */
export type ConnectorResult =
    | { status: "success"; table: { columns: RawColumn[]; rows: unknown[][] }; requestId: string }
    | { status: "error"; error: { category: string; message: string; code?: string }; requestId: string };

export type Execute = (input: { query: string; resultSetRowCountLimit?: number }) => Promise<ConnectorResult>;

export type Row = Record<string, unknown>;

export interface QueryResult {
    spec: QuerySpec;
    columns: ColumnSpec[];
    rows: Row[];
    requestId: string;
    fetchedAt: Date;
    /** Which source answered: the history model, a live source, or the preview's sample. */
    provenance: DataProvenance;
}

export class QueryFailure extends Error {
    readonly category: string;
    readonly code?: string;
    readonly requestId?: string;

    constructor(message: string, category: string, code?: string, requestId?: string) {
        super(message);
        this.name = "QueryFailure";
        this.category = category;
        this.code = code;
        this.requestId = requestId;
    }
}

/** "Target[Target Key]" and "[CpuAvg]" become "Target Key" and "CpuAvg". */
export function normalizeColumnName(name: string): string {
    const match = /\[([^\]]+)\]$/.exec(name);
    return match ? match[1] : name;
}

export function toRows(columns: readonly RawColumn[], rows: readonly unknown[][]): Row[] {
    const names = columns.map((c) => normalizeColumnName(c.name));
    return rows.map((values) => {
        const row: Row = {};
        names.forEach((name, i) => {
            row[name] = values[i];
        });
        return row;
    });
}

/** Plain-language text for a connector failure. */
export function describeFailure(category: string, message: string): string {
    switch (category) {
        case "overflow":
            return "This query returned more rows than the app allows. Choose a shorter time window or fewer targets.";
        case "network":
            return "The app couldn't reach Fabric. Check the connection and try again.";
        case "api":
            return /401|403|unauthori[sz]ed|forbidden|permission/i.test(message)
                ? "Fabric refused the query for this account. It needs Build and Read on SM_DatabaseHub_History in the demo's tenant."
                : `Fabric couldn't run the query: ${message}`;
        case "query":
            return `The model rejected the query: ${message}`;
        default:
            return message || "The query failed.";
    }
}

/**
 * Where rows come from. A source answers the catalog questions it can: the history model answers every query by its
 * DAX; a live source would answer the ones it has routes for, by the query's ID and params, and the history answers the
 * rest.
 */
export interface DataSource {
    provenance: DataProvenance;
    answers(spec: QuerySpec): boolean;
    fetch(spec: QuerySpec): Promise<{ rows: Row[]; requestId: string }>;
}

/** The history model through the read-only semantic model connector, as the signed-in user. */
export function historySource(execute: Execute): DataSource {
    return {
        provenance: "history",
        answers: () => true,
        async fetch(spec) {
            const result = await execute({ query: spec.dax, resultSetRowCountLimit: spec.rowLimit });
            if (result.status !== "success") {
                const { category, message, code } = result.error;
                throw new QueryFailure(describeFailure(category, message), category, code, result.requestId);
            }
            return { rows: toRows(result.table.columns, result.table.rows), requestId: result.requestId };
        },
    };
}

export interface QueryClient {
    run(spec: QuerySpec, options?: { force?: boolean }): Promise<QueryResult>;
    peek(spec: QuerySpec): QueryResult | undefined;
    clear(): void;
}

export interface ClientOptions {
    ttlMs?: number;
    maxEntries?: number;
    now?: () => number;
}

/** A client over sources, tried in order: the first that answers a query runs it. */
export function createSourceClient(sources: readonly DataSource[], options: ClientOptions = {}): QueryClient {
    const ttl = options.ttlMs ?? 5 * 60 * 1000;
    const max = options.maxEntries ?? 60;
    const now = options.now ?? (() => Date.now());
    const cache = new Map<string, { at: number; result: QueryResult }>();
    const inFlight = new Map<string, Promise<QueryResult>>();
    const keyOf = (spec: QuerySpec) => `${spec.id}\n${spec.rowLimit}\n${spec.dax}`;

    function fresh(key: string): QueryResult | undefined {
        const hit = cache.get(key);
        if (!hit) return undefined;
        if (now() - hit.at > ttl) {
            cache.delete(key);
            return undefined;
        }
        // Refresh recency for the LRU order.
        cache.delete(key);
        cache.set(key, hit);
        return hit.result;
    }

    return {
        peek: (spec) => fresh(keyOf(spec)),
        clear: () => cache.clear(),
        run(spec, runOptions) {
            const key = keyOf(spec);
            if (!runOptions?.force) {
                const hit = fresh(key);
                if (hit) return Promise.resolve(hit);
            }
            const pending = inFlight.get(key);
            if (pending) return pending;
            const source = sources.find((s) => s.answers(spec));
            if (!source) return Promise.reject(new QueryFailure(`No data source answers ${spec.id}.`, "source"));
            const request = source
                .fetch(spec)
                .then(({ rows, requestId }) => {
                    const value: QueryResult = { spec, columns: spec.columns, rows, requestId, fetchedAt: new Date(now()), provenance: source.provenance };
                    cache.set(key, { at: now(), result: value });
                    while (cache.size > max) {
                        const oldest = cache.keys().next().value;
                        if (oldest === undefined) break;
                        cache.delete(oldest);
                    }
                    return value;
                })
                .finally(() => inFlight.delete(key));
            inFlight.set(key, request);
            return request;
        },
    };
}

/** The deployed app's client: the history model through the connector. */
export function createQueryClient(execute: Execute, options: ClientOptions = {}): QueryClient {
    return createSourceClient([historySource(execute)], options);
}
