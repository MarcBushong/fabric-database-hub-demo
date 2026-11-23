// Wait types to wait categories: Microsoft Learn's sys.query_store_wait_stats mapping table, verbatim and in its order
// (the categories Database Hub's SqlServerWaitStats uses too), and PostgreSQL's wait_event_type, so one investigation
// speaks about both engines in the same classes.
// https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-wait-stats-transact-sql#wait-categories-mapping-table

const like = (pattern: string) => new RegExp(`^${pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*")}$`, "i");

const MAPPING: Array<[string, string[], string[]?]> = [
    ["CPU", ["SOS_SCHEDULER_YIELD"]],
    ["Worker Thread", ["THREADPOOL"]],
    ["Lock", ["LCK_M_%"]],
    ["Latch", ["LATCH_%"]],
    ["Buffer Latch", ["PAGELATCH_%"]],
    ["Buffer IO", ["PAGEIOLATCH_%"]],
    ["Compilation", ["RESOURCE_SEMAPHORE_QUERY_COMPILE"]],
    ["SQL CLR", ["CLR%", "SQLCLR%"]],
    ["Mirroring", ["DBMIRROR%"]],
    ["Transaction", ["XACT%", "DTC%", "TRAN_MARKLATCH_%", "MSQL_XACT_%", "TRANSACTION_MUTEX"]],
    ["Idle", ["SLEEP_%", "LAZYWRITER_SLEEP", "SQLTRACE_BUFFER_FLUSH", "SQLTRACE_INCREMENTAL_FLUSH_SLEEP", "SQLTRACE_WAIT_ENTRIES", "FT_IFTS_SCHEDULER_IDLE_WAIT", "XE_DISPATCHER_WAIT", "REQUEST_FOR_DEADLOCK_SEARCH", "LOGMGR_QUEUE", "ONDEMAND_TASK_QUEUE", "CHECKPOINT_QUEUE", "XE_TIMER_EVENT"]],
    ["Preemptive", ["PREEMPTIVE_%"]],
    ["Service Broker", ["BROKER_%"], ["BROKER_RECEIVE_WAITFOR"]],
    ["Tran Log IO", ["LOGMGR", "LOGBUFFER", "LOGMGR_RESERVE_APPEND", "LOGMGR_FLUSH", "LOGMGR_PMM_LOG", "CHKPT", "WRITELOG"]],
    ["Network IO", ["ASYNC_NETWORK_IO", "NET_WAITFOR_PACKET", "PROXY_NETWORK_IO", "EXTERNAL_SCRIPT_NETWORK_IOF"]],
    ["Parallelism", ["CXCONSUMER", "CXPACKET", "CXSYNC_CONSUMER", "CXSYNC_PORT", "EXCHANGE", "HT%", "BMP%", "BP%"]],
    ["Memory", ["RESOURCE_SEMAPHORE", "CMEMTHREAD", "CMEMPARTITIONED", "EE_PMOLOCK", "MEMORY_ALLOCATION_EXT", "RESERVED_MEMORY_ALLOCATION_EXT", "MEMORY_GRANT_UPDATE"]],
    ["User Wait", ["WAITFOR", "WAIT_FOR_RESULTS", "BROKER_RECEIVE_WAITFOR"]],
    ["Tracing", ["TRACEWRITE", "SQLTRACE_LOCK", "SQLTRACE_FILE_BUFFER", "SQLTRACE_FILE_WRITE_IO_COMPLETION", "SQLTRACE_FILE_READ_IO_COMPLETION", "SQLTRACE_PENDING_BUFFER_WRITERS", "SQLTRACE_SHUTDOWN", "QUERY_TRACEOUT", "TRACE_EVTNOTIFF"]],
    ["Full Text Search", ["FT_RESTART_CRAWL", "FULLTEXT GATHERER", "MSSEARCH", "FT_METADATA_MUTEX", "FT_IFTSHC_MUTEX", "FT_IFTSISM_MUTEX", "FT_IFTS_RWLOCK", "FT_COMPROWSET_RWLOCK", "FT_MASTER_MERGE", "FT_PROPERTYLIST_CACHE", "FT_MASTER_MERGE_COORDINATOR", "PWAIT_RESOURCE_SEMAPHORE_FT_PARALLEL_QUERY_SYNC"]],
    ["Other Disk IO", ["ASYNC_IO_COMPLETION", "IO_COMPLETION", "BACKUPIO", "WRITE_COMPLETION", "IO_QUEUE_LIMIT", "IO_RETRY"]],
    ["Replication", ["SE_REPL_%", "REPL_%", "HADR_%", "PWAIT_HADR_%", "REPLICA_WRITES", "FCB_REPLICA_WRITE", "FCB_REPLICA_READ", "PWAIT_HADRSIM"], ["HADR_THROTTLE_LOG_RATE_GOVERNOR"]],
    ["Log Rate Governor", ["LOG_RATE_GOVERNOR", "POOL_LOG_RATE_GOVERNOR", "HADR_THROTTLE_LOG_RATE_GOVERNOR", "INSTANCE_LOG_RATE_GOVERNOR", "RBIO_RG_%"]],
];

const COMPILED = MAPPING.map(([category, include, exclude]) => ({ category, include: include.map(like), exclude: (exclude ?? []).map(like) }));

/** The documented wait category of a SQL Server or Azure SQL Database wait type ("Unknown" when the table doesn't list it). */
export function waitCategory(waitType: string): string {
    // HADR_THROTTLE_LOG_RATE_GOVERNOR is excluded from Replication and listed under Log Rate Governor: check that first.
    const governor = COMPILED.find((c) => c.category === "Log Rate Governor")!;
    if (governor.include.some((r) => r.test(waitType))) return "Log Rate Governor";
    for (const c of COMPILED) {
        if (c.include.some((r) => r.test(waitType)) && !c.exclude.some((r) => r.test(waitType))) return c.category;
    }
    return "Unknown";
}

/**
 * PostgreSQL's sampled wait ("wait_event_type:wait_event", from pg_stat_activity) in the same classes. An active session
 * with no wait event is on CPU (pg_stat_activity: "If the state is active and wait_event is non-null, it means that a query
 * is being executed, but is being blocked somewhere in the system").
 */
export function pgWaitCategory(wait: string | undefined, state?: string): string {
    if (!wait || wait === "null:null") return state === "active" ? "CPU" : state?.startsWith("idle in transaction") ? "Idle in transaction" : "Idle";
    const [type, event] = wait.split(":");
    switch (type) {
        case "Lock":
            return "Lock";
        case "LWLock":
            return /^(WALWrite|WALInsert)/.test(event ?? "") ? "Tran Log IO" : "Latch";
        case "IO":
            return /^WAL/.test(event ?? "") ? "Tran Log IO" : "Buffer IO";
        case "Client":
            return state?.startsWith("idle in transaction") ? "Idle in transaction" : "Network IO";
        case "Timeout":
            return "User Wait";
        case "IPC":
            return /Parallel|BgWorker|Execute/.test(event ?? "") ? "Parallelism" : "IPC";
        case "Activity":
        case "BufferPin":
            return type === "BufferPin" ? "Buffer Latch" : "Idle";
        default:
            return "Unknown";
    }
}

/** The categories a DBA reads as one family, for headlines ("Locks and latches", "Storage IO", ...), as the app's waitFamily does. */
export function waitFamily(category: string): string {
    if (/^(Buffer IO|Other Disk IO|Tran Log IO)$/.test(category)) return "Storage IO";
    if (/^(CPU|Worker Thread|Parallelism)$/.test(category)) return "CPU and scheduling";
    if (/^(Lock|Latch|Buffer Latch|Idle in transaction)$/.test(category)) return "Locks and latches";
    if (category === "Network IO") return "Network";
    if (/^(Memory|Compilation)$/.test(category)) return "Memory";
    if (category === "Log Rate Governor") return "Resource governance";
    return "Other";
}
