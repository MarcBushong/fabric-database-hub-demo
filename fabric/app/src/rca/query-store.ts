// What the RCA says about Query Store while the capture doesn't collect its statistics (ADR 0031): that this history
// doesn't hold them, which is the capture's limit, never that a target has no Query Store. Live, the chat read "the CPU's
// cause (Query Store's plans, waits per query) isn't captured yet" as "T1 doesn't have Query Store" (the owner,
// 2026-11-23), though the demo keeps Query Store on in ContosoCare on T1 to T3 (database/*/030-configure.sql) and, since
// then, on T4 at every size but Burstable (infra/modules/pgflex01.bicep). Whether it's on is validate.ps1's to say
// (<target>.QUERYSTORE), never this history's. Query Store doesn't record a read replica's queries, and T5, Azure Cosmos
// DB, has none.

import { fromTo, type Episode, type RcaTarget } from "./types";

/** Monitor performance by using the Query Store (SQL Server and Azure SQL Database): its reports and catalog views. */
export const SQL_QUERY_STORE_LEARN = "https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store";

/** Query Store in Azure Database for PostgreSQL flexible server: not on Burstable, and never recorded on a read replica. */
export const PG_QUERY_STORE_LEARN = "https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store";

/** Where a target's per-query statistics live: SQL Server's Query Store, PostgreSQL's (azure_sys), none on a replica, none on T5. */
export type QueryStoreKind = "sql" | "postgresql" | "replica" | "none";

export function queryStoreKind(target: RcaTarget): QueryStoreKind {
    if (target === "T1" || target === "T2" || target === "T3") return "sql";
    if (target === "T4") return "postgresql";
    return target === "T4-replica" ? "replica" : "none";
}

/** The wait category, as sys.query_store_wait_stats names it, behind each wait family of the detector. */
const WAIT_CATEGORY: Readonly<Record<string, string>> = {
    io: "Buffer IO",
    log_rate: "Log Rate Governor",
    latch: "Buffer Latch",
    memory: "Memory",
    parallelism: "Parallelism",
    tran_log: "Tran Log IO",
    network: "Network IO",
};

/** The last sentence of the cause of an episode no rule explains by query yet (TELEMETRY-ONLY). */
export function unexplainedByQuery(e: Pick<Episode, "target">): string {
    switch (queryStoreKind(e.target)) {
        case "sql":
        case "postgresql":
            return `Which queries drove it isn't in this history: the capture doesn't collect Query Store's per-query statistics yet, a limit of the capture, not of ${e.target}.`;
        case "replica":
            return "Which queries drove it is in neither this history nor Query Store, which doesn't record a read replica's queries.";
        default:
            return "Which requests drove it isn't in this history.";
    }
}

/** What wasn't captured, in words that say what this history lacks and never what the target lacks. */
export function queryStoreNote(e: Pick<Episode, "target" | "signal">): string {
    const t = e.target;
    const lacks = `${t}: which queries drove the ${e.signal} isn't in this history, because the capture doesn't collect Query Store's per-query statistics yet. That's the capture's limit, not ${t}'s:`;
    switch (queryStoreKind(t)) {
        case "sql":
            return `${lacks} Query Store on ${t} keeps those minutes' plans and per-query CPU, duration, and waits, and validate.ps1's ${t}.QUERYSTORE says whether it's on.`;
        case "postgresql":
            return `${lacks} at every size but Burstable, where Learn advises against it, Query Store on ${t} keeps those minutes' per-query statistics and wait samples in its azure_sys database, and validate.ps1's ${t}.QUERYSTORE says whether it's on.`;
        case "replica":
            return `${t}: which queries drove the ${e.signal} is in neither this history nor Query Store: Query Store doesn't record the queries a read replica runs (${PG_QUERY_STORE_LEARN}), and the capture samples the replica's sessions only while its replay stands still.`;
        default:
            return `${t}: which requests drove the ${e.signal} isn't in this history.`;
    }
}

/** Where a DBA reads which queries drove the episode: the target's own Query Store, for the episode's minutes. Null without one. */
export function queryStoreNextStep(e: Pick<Episode, "target" | "family" | "start" | "end" | "last" | "readEnd">): string | null {
    const minutes = `${fromTo(e.start, e.end ?? e.readEnd ?? e.last)} UTC`;
    const category = WAIT_CATEGORY[e.family];
    switch (queryStoreKind(e.target)) {
        case "sql":
            return category
                ? `Read Query Store on ${e.target} for the queries that waited on ${category} ${minutes}: its Query Wait Statistics report on ContosoCare in SQL Server Management Studio, or sys.query_store_wait_stats and sys.query_store_runtime_stats for the intervals that hold those minutes (${SQL_QUERY_STORE_LEARN}).`
                : `Read Query Store on ${e.target} for the queries and plans that used the CPU ${minutes}: its Top Resource Consuming Queries and Regressed Queries reports on ContosoCare in SQL Server Management Studio, or sys.query_store_runtime_stats for the intervals that hold those minutes (${SQL_QUERY_STORE_LEARN}).`;
        case "postgresql":
            return `Read Query Store on ${e.target} for the queries that took the most time ${minutes}, at every size but Burstable: query_store.qs_view in its azure_sys database, and query_store.pgms_wait_sampling_view for what they waited on, for the intervals that hold those minutes (${PG_QUERY_STORE_LEARN}).`;
        default:
            return null;
    }
}
