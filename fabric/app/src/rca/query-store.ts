// What the RCA says about Query Store where it reads none of Query Store's evidence (ADR 0031): tools made without the
// sidecar's reader, which the Insights app always passes (client.ts), so only tests reach those words; a read replica,
// whose queries Query Store doesn't record; and T5, Azure Cosmos DB, which has none. Where the history holds Query Store's
// evidence, explain-queries.ts and queries.ts say what it shows. Never that a target has no Query Store: live, the chat
// read "the CPU's cause (Query Store's plans, waits per query) isn't captured yet" as "T1 doesn't have Query Store" (the
// owner, 2026-11-23), though the demo keeps Query Store on in ContosoCare on T1 to T3 (database/*/030-configure.sql) and,
// since then, on T4 at every size but Burstable (infra/modules/pgflex01.bicep). Whether it's on is validate.ps1's to say
// (<target>.QUERYSTORE), never this history's.

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

/** The last sentence of a TELEMETRY-ONLY cause that reads no Query Store evidence: without the sidecar's reader, a read replica, or T5. */
export function unexplainedByQuery(e: Pick<Episode, "target">): string {
    switch (queryStoreKind(e.target)) {
        case "sql":
        case "postgresql":
            return `Which queries drove it isn't known here: this app doesn't read Query Store's evidence, a limit of the app, not of ${e.target}.`;
        case "replica":
            return "Which queries drove it is in neither this history nor Query Store, which doesn't record a read replica's queries.";
        default:
            return "Which requests drove it isn't in this history.";
    }
}

/**
 * How long a target's Query Store keeps an interval: T1 to T3's STALE_QUERY_THRESHOLD_DAYS (each 030-configure.sql in database/,
 * less when size-based cleanup runs first), T4's pg_qs.retention_period_in_days, its default, which the template doesn't
 * set (Learn). The review of 319b3ae1: past it, the next step sent the owner to an empty view, which reads as "Query Store
 * is off".
 */
export const QUERY_STORE_RETENTION_DAYS: Readonly<Record<"sql" | "postgresql", number>> = { sql: 14, postgresql: 7 };

const DAY_MS = 86_400_000;

/** Whether the target's Query Store still keeps the episode's minutes now, and how old they are, in whole days (rounded down). */
export function queryStoreAge(e: Pick<Episode, "target" | "end" | "last" | "readEnd">, now: Date): { kept: boolean; days: number; retentionDays: number } | null {
    const kind = queryStoreKind(e.target);
    if (kind !== "sql" && kind !== "postgresql") return null;
    const ageMs = now.getTime() - (e.end ?? e.readEnd ?? e.last).getTime();
    const retentionDays = QUERY_STORE_RETENTION_DAYS[kind];
    return { kept: ageMs <= retentionDays * DAY_MS, days: Math.max(0, Math.floor(ageMs / DAY_MS)), retentionDays };
}

/** What tools without the sidecar's reader don't read, in words that say so and never what the target lacks. */
export function queryStoreNote(e: Pick<Episode, "target" | "signal" | "end" | "last" | "readEnd">, now: Date): string {
    const t = e.target;
    const lacks = `${t}: which queries drove the ${e.signal} isn't known here, because this app doesn't read Query Store's evidence. That's the app's limit, not ${t}'s:`;
    const age = queryStoreAge(e, now);
    const gone = age && !age.kept ? ` Query Store on ${t} no longer keeps those minutes either: it keeps ${age.retentionDays} days${queryStoreKind(t) === "sql" ? " (less when it fills up)" : ""}, and they're more than ${age.retentionDays} days old.` : "";
    switch (queryStoreKind(t)) {
        case "sql":
            return gone
                ? `${lacks}${gone} validate.ps1's ${t}.QUERYSTORE says whether it's on.`
                : `${lacks} Query Store on ${t} keeps those minutes' plans and per-query CPU, duration, and waits for ${QUERY_STORE_RETENTION_DAYS.sql} days (less when it fills up), and validate.ps1's ${t}.QUERYSTORE says whether it's on.`;
        case "postgresql":
            return gone
                ? `${lacks}${gone} validate.ps1's ${t}.QUERYSTORE says whether it's on.`
                : `${lacks} at every size but Burstable, where Learn advises against it, Query Store on ${t} keeps those minutes' per-query statistics and wait samples in its azure_sys database for ${QUERY_STORE_RETENTION_DAYS.postgresql} days, and validate.ps1's ${t}.QUERYSTORE says whether it's on.`;
        case "replica":
            return `${t}: which queries drove the ${e.signal} is in neither this history nor Query Store: Query Store doesn't record the queries a read replica runs (${PG_QUERY_STORE_LEARN}), and the capture samples the replica's sessions only while its replay stands still.`;
        default:
            return `${t}: which requests drove the ${e.signal} isn't in this history.`;
    }
}

/**
 * Where a DBA reads which queries drove the episode: the target's own Query Store, for the episode's minutes, while it
 * still keeps them. Null without one, or once they're past its retention.
 */
export function queryStoreNextStep(e: Pick<Episode, "target" | "family" | "start" | "end" | "last" | "readEnd">, now: Date): string | null {
    const minutes = `${fromTo(e.start, e.end ?? e.readEnd ?? e.last)} UTC`;
    const category = WAIT_CATEGORY[e.family];
    const age = queryStoreAge(e, now);
    if (!age || !age.kept) return null;
    switch (queryStoreKind(e.target)) {
        case "sql":
            return category
                ? `Read Query Store on ${e.target} for the queries that waited on ${category} ${minutes}: its Query Wait Statistics report on ContosoCare in SQL Server Management Studio, or sys.query_store_wait_stats and sys.query_store_runtime_stats for the intervals that hold those minutes (${SQL_QUERY_STORE_LEARN}).`
                : `Read Query Store on ${e.target} for the queries and plans that used the CPU ${minutes}: its Top Resource Consuming Queries and Regressed Queries reports on ContosoCare in SQL Server Management Studio, or sys.query_store_runtime_stats for the intervals that hold those minutes (${SQL_QUERY_STORE_LEARN}).`;
        default:
            return `Read Query Store on ${e.target} for the queries that took the most time ${minutes}, at every size but Burstable: query_store.qs_view in its azure_sys database, and query_store.pgms_wait_sampling_view for what they waited on, for the intervals that hold those minutes (${PG_QUERY_STORE_LEARN}).`;
    }
}

/** A ready-to-run, read-only query of a target's Query Store for an incident's minutes, for the next step's copy button. */
export interface QueryStoreQuery {
    target: RcaTarget;
    /** T-SQL for T1 to T3, PostgreSQL for T4. */
    language: "tsql" | "postgresql";
    /** Where to run it: ContosoCare on T1 to T3, azure_sys on T4. */
    database: string;
    /** The minutes it reads, in UTC, as the incident's own. */
    fromUtc: string;
    toUtc: string;
    text: string;
}

/**
 * At most this many queries in one result, the root cause's first, with the others counted (the review of 0b922f37): each
 * is 2 to 3 KB, and a result cut to fit the chat's answer keeps them.
 */
export const QUERY_STORE_QUERIES_MAX = 3;

/** "2026-11-20T15:40:00+00:00": a T-SQL datetimeoffset literal, to the second, in UTC. */
const tsqlTime = (d: Date) => `${d.toISOString().slice(0, 19)}+00:00`;
/** "2026-11-20 15:40:00": a PostgreSQL timestamp literal, to the second, UTC, as qs_view's start_time and end_time hold it. */
const pgTime = (d: Date) => d.toISOString().slice(0, 19).replace("T", " ");

/**
 * The read-only query a DBA runs for the episode's minutes on its target's own Query Store, built only from the episode's
 * measured target, family, and times, never from what the demo planned: on T1 to T3, the top plans by CPU, then duration,
 * with their plan IDs, and for a wait class the top plans by their wait time in its category; on T4, in azure_sys, the top
 * queries by total time, then their sampled waits. Each starts with Query Store's state (T1 to T3) or capture modes (T4),
 * so an empty result reads right, and breaks its ties by IDs (the review of 0b922f37). An interval counts when it overlaps
 * the minutes, since Query Store keeps them by interval (15 minutes by default). Null where there's no Query Store to read
 * (a read replica, T5), or once the minutes are past its retention (queryStoreAge), as for the next step.
 * Sources: https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql,
 * https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-runtime-stats-transact-sql,
 * https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-wait-stats-transact-sql,
 * https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store, and current_setting's missing_ok:
 * https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SET
 */
export function queryStoreQuery(e: Pick<Episode, "target" | "family" | "start" | "end" | "last" | "readEnd">, now: Date): QueryStoreQuery | null {
    const age = queryStoreAge(e, now);
    if (!age || !age.kept) return null;
    const from = e.start;
    const to = e.end ?? e.readEnd ?? e.last;
    // An interval holds the minutes when it ends after their start and starts before their end. An episode's end is the
    // first sample back under its level, so the interval that starts there holds none of it (the review of 0b922f37: on
    // 15-minute points, every incident read an interval more). Its last sample at the level, and readEnd, where the
    // minutes read ended with it still on, are in it, so the interval that starts at either holds some of it.
    const before = e.end ? "<" : "<=";
    const span = `${fromTo(from, to)} UTC`;
    const fromUtc = from.toISOString().replace(".000Z", "Z");
    const toUtc = to.toISOString().replace(".000Z", "Z");
    if (queryStoreKind(e.target) === "sql") {
        const category = WAIT_CATEGORY[e.family];
        const overlap = `i.end_time > @from AND i.start_time ${before} @to`;
        const state = [
            "-- Its state first, so an empty result below reads right: READ_WRITE records; READ_ONLY doesn't, and readonly_reason says why.",
            "SELECT actual_state_desc, readonly_reason FROM sys.database_query_store_options;",
        ];
        const window = [`DECLARE @from datetimeoffset = '${tsqlTime(from)}', @to datetimeoffset = '${tsqlTime(to)}';`];
        const plans = [
            "SELECT TOP (20)",
            "    q.query_id,",
            "    p.plan_id,",
            "    OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id) AS module_name,",
            "    SUM(rs.count_executions) AS executions,",
            "    CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS decimal(18, 1)) AS cpu_ms,",
            "    CAST(SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS decimal(18, 1)) AS duration_ms,",
            "    MIN(i.start_time) AS first_interval_start_utc,",
            "    MAX(i.end_time) AS last_interval_end_utc,",
            "    LEFT(t.query_sql_text, 300) AS query_text",
            "FROM sys.query_store_runtime_stats AS rs",
            "JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id",
            "JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id",
            "JOIN sys.query_store_query AS q ON q.query_id = p.query_id",
            "JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id",
            `WHERE ${overlap}`,
            "GROUP BY q.query_id, p.plan_id, q.object_id, t.query_sql_text",
            "ORDER BY cpu_ms DESC, duration_ms DESC, p.plan_id;",
        ];
        const waits = category
            ? [
                  "",
                  `-- The top plans by their wait time in the ${category} category, in the same intervals.`,
                  "SELECT TOP (20)",
                  "    q.query_id,",
                  "    p.plan_id,",
                  "    ws.wait_category_desc,",
                  "    CAST(SUM(ws.total_query_wait_time_ms) AS decimal(18, 1)) AS wait_ms,",
                  "    LEFT(t.query_sql_text, 300) AS query_text",
                  "FROM sys.query_store_wait_stats AS ws",
                  "JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id",
                  "JOIN sys.query_store_plan AS p ON p.plan_id = ws.plan_id",
                  "JOIN sys.query_store_query AS q ON q.query_id = p.query_id",
                  "JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id",
                  `WHERE ${overlap} AND ws.wait_category_desc = N'${category}'`,
                  "GROUP BY q.query_id, p.plan_id, ws.wait_category_desc, t.query_sql_text",
                  "ORDER BY wait_ms DESC, p.plan_id;",
              ]
            : [];
        const text = [
            `-- Read-only: Query Store's top plans on ${e.target} ${span}, by CPU, then duration, with their plan IDs.`,
            "-- Run it in the ContosoCare database. Query Store keeps them by interval, so the intervals that overlap those minutes count.",
            ...state,
            ...window,
            ...plans,
            ...waits,
        ].join("\n");
        return { target: e.target, language: "tsql", database: "ContosoCare", fromUtc, toUtc, text };
    }
    const where = (view: "q" | "w") => `WHERE ${view}.end_time > '${pgTime(from)}' AND ${view}.start_time ${before} '${pgTime(to)}'`;
    const text = [
        `-- Read-only: Query Store's top queries on ${e.target} ${span}, by total time, then their sampled waits, at every size but Burstable.`,
        "-- Run it in the azure_sys database. Its times are the server's, UTC unless its TimeZone was changed, and an interval shows once it has ended.",
        "-- Its capture modes first, so an empty result below reads right: none records nothing.",
        "SELECT current_setting('pg_qs.query_capture_mode', true) AS query_capture_mode, current_setting('pgms_wait_sampling.query_capture_mode', true) AS wait_sampling_capture_mode;",
        "SELECT",
        "    q.query_id,",
        "    sum(q.calls) AS calls,",
        "    round(sum(q.total_time)::numeric, 1) AS total_time_ms,",
        "    round(max(q.max_time)::numeric, 1) AS max_time_ms,",
        "    sum(q.shared_blks_read) AS shared_blks_read,",
        "    min(q.start_time) AS first_interval_start,",
        "    max(q.end_time) AS last_interval_end,",
        "    left(min(q.query_sql_text), 300) AS query_text",
        "FROM query_store.qs_view AS q",
        where("q"),
        "  AND q.db_id = (SELECT oid FROM pg_database WHERE datname = 'contosocare')",
        "  AND NOT q.is_system_query",
        "GROUP BY q.query_id",
        "ORDER BY total_time_ms DESC, q.query_id",
        "LIMIT 20;",
        "",
        "-- Those minutes' sampled waits, by query.",
        "SELECT",
        "    w.query_id,",
        "    w.event_type,",
        "    w.event,",
        "    sum(w.calls) AS samples",
        "FROM query_store.pgms_wait_sampling_view AS w",
        where("w"),
        "  AND w.db_id = (SELECT oid FROM pg_database WHERE datname = 'contosocare')",
        "GROUP BY w.query_id, w.event_type, w.event",
        "ORDER BY samples DESC, w.query_id, w.event_type, w.event",
        "LIMIT 20;",
    ].join("\n");
    return { target: e.target, language: "postgresql", database: "azure_sys", fromUtc, toUtc, text };
}
