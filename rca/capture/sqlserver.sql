-- Incident RCA capture for T1 (SQL Server 2022 on an Azure VM), T2 (Arc-enabled SQL Server 2022 in the nested guest),
-- and T3 (Azure SQL Database). The contract: rca/README.md; the design: docs/adr/0031-incident-rca.md. Each block is one
-- batch, named "-- name: <ID>"; rca/capture/README.md lists them with their permissions and documentation.
--
-- Who runs it: the runner's observer lane, connected to ContosoCare with Application Name ContosoCare.Demo/control/rca
-- (so demo.fn_demo_sessions and demo.usp_kill_demo_sessions never list or end it). T1 and T2: Windows authentication as
-- the runner's identity (SYSTEM, a sysadmin through BUILTIN\Administrators in the default JumpstartImage and T1 modes:
-- vm/hyperv-guest/GuestWorkload.ps1, vm/bootstrap/Invoke-SqlVmBootstrap.ps1). T3: T1's managed identity, dbo through
-- the P6 administrator group (database/azuresql/030-configure.sql). No new permission or role assignment.
-- Least privilege, if the owner wants a dedicated login later: VIEW SERVER PERFORMANCE STATE covers the DMVs below on
-- SQL Server 2022, and ALTER ANY EVENT SESSION the XE session; VIEW DATABASE PERFORMANCE STATE on Azure SQL Database.
--
-- Blind (ADR 0031): the observer sees what a DBA's tools see. It never reads what the workload plans or injects, and
-- its cadence follows what it sees: the sentinel (RCA-SQL-09, RCA-XE-02) runs every 30 s for the whole session, and a
-- signal over its threshold starts detail capture (rca/README.md, Capture triggers).
--
-- Bounds (ADR 0010): every statement reads, under READ UNCOMMITTED and a 1-second lock timeout, so the observer never
-- waits behind what it observes. The XE session (RCA-XE-*) is the only object created; it's named ContosoCare_RCA,
-- holds events in memory only (ring_buffer), and is dropped at the session's end (ADR 0010, amendment of 2026-11-20).
--
-- Text: statement text, input buffers, and event SQL text are normalized in the runner before they're stored (string,
-- number, date, and binary literals become placeholders; RPC procedure names stay), and only for the workload's own
-- sessions. The application name is stored without its internal segments, with an opaque run token (rca/README.md,
-- Names). Any other session that appears in a chain is stored as its session ID, status, and waits, without text,
-- login, or host.

-- name: RCA-SQL-01
-- The blocking snapshot: one row per session in ContosoCare that waits on another session or that another session
-- waits on, with what it runs (or ran last, when idle) and who runs it. Every 10 s from the sentinel's first sample
-- with Processes blocked above 0 (RCA-SQL-09) until 60 s without one. T1, T2, T3.
-- blocking_session_id -2, -3, -4 (orphaned distributed transaction, deferred recovery, latch owner unknown) are kept.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
DECLARE @db int = DB_ID();
WITH edges AS (
    SELECT r.session_id, r.blocking_session_id
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
      AND r.database_id = @db
),
involved AS (
    SELECT e.session_id FROM edges AS e
    UNION
    SELECT e.blocking_session_id FROM edges AS e WHERE e.blocking_session_id > 0
)
SELECT
    captured_at_utc       = SYSUTCDATETIME(),
    s.session_id,
    blocking_session_id   = ISNULL(r.blocking_session_id, 0),
    session_status        = s.status,
    request_status        = r.status,
    r.command,
    r.wait_type,
    wait_time_ms          = r.wait_time,
    r.wait_resource,
    r.last_wait_type,
    s.open_transaction_count,
    transaction_age_ms    = DATEDIFF_BIG(millisecond, tx.transaction_begin_time, GETDATE()),
    idle_ms               = CASE WHEN r.session_id IS NULL THEN DATEDIFF_BIG(millisecond, s.last_request_end_time, GETDATE()) END,
    request_elapsed_ms    = r.total_elapsed_time,
    s.login_name,
    s.host_name,
    s.program_name,
    s.client_interface_name,
    r.cpu_time,
    r.logical_reads,
    r.reads,
    r.writes,
    r.granted_query_memory,
    r.dop,
    r.query_hash,
    r.query_plan_hash,
    module_name           = CASE WHEN st.objectid IS NOT NULL
                                 THEN QUOTENAME(OBJECT_SCHEMA_NAME(st.objectid, st.dbid)) + N'.' + QUOTENAME(OBJECT_NAME(st.objectid, st.dbid)) END,
    statement_text        = CASE WHEN r.session_id IS NOT NULL AND r.statement_start_offset IS NOT NULL
                                 THEN SUBSTRING(st.text, r.statement_start_offset / 2 + 1,
                                      (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(st.text) ELSE r.statement_end_offset END
                                       - r.statement_start_offset) / 2 + 1) END,
    input_buffer_type     = ib.event_type,
    input_buffer          = ib.event_info
FROM involved AS i
JOIN sys.dm_exec_sessions AS s ON s.session_id = i.session_id
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = s.session_id AND c.parent_connection_id IS NULL
OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) AS st
OUTER APPLY (SELECT b.event_type, b.event_info
             FROM sys.dm_exec_input_buffer(s.session_id, NULL) AS b
             WHERE r.session_id IS NULL) AS ib
OUTER APPLY (SELECT transaction_begin_time = MIN(atx.transaction_begin_time)
             FROM sys.dm_tran_session_transactions AS stx
             JOIN sys.dm_tran_active_transactions AS atx ON atx.transaction_id = stx.transaction_id
             WHERE stx.session_id = s.session_id) AS tx
ORDER BY s.session_id;

-- name: RCA-SQL-02
-- The lock resources behind the waits: every request that isn't granted (WAIT, CONVERT, and the LOW_PRIORITY states),
-- the granted requests on the same resources (the holders), and every granted table-level lock in a blocking mode (lock
-- escalation or TABLOCK). With RCA-SQL-01 it names the object, the index, and the modes of each edge. Same cadence as
-- RCA-SQL-01. T1, T2, T3. On T3, optimized locking (always on in Azure SQL Database, not available on SQL Server 2022)
-- makes the holder's lock an XACT resource with resource_associated_entity_id 0, and the waiter's resource_description
-- the XACT resource followed by the KEY or RID it wants, with the HoBt ID: the object then comes from the waiter's row.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    l.request_session_id,
    l.resource_type,
    l.resource_subtype,
    l.resource_description,
    l.resource_associated_entity_id,
    l.request_mode,
    l.request_status,
    l.request_owner_type,
    object_name     = CASE WHEN l.resource_type = N'OBJECT'
                           THEN QUOTENAME(OBJECT_SCHEMA_NAME(l.resource_associated_entity_id)) + N'.' + QUOTENAME(OBJECT_NAME(l.resource_associated_entity_id))
                           WHEN p.object_id IS NOT NULL
                           THEN QUOTENAME(OBJECT_SCHEMA_NAME(p.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(p.object_id)) END,
    index_name      = ix.name
FROM sys.dm_tran_locks AS l
LEFT JOIN sys.partitions AS p
  ON l.resource_type IN (N'KEY', N'PAGE', N'RID', N'HOBT') AND p.hobt_id = l.resource_associated_entity_id
LEFT JOIN sys.indexes AS ix ON ix.object_id = p.object_id AND ix.index_id = p.index_id
WHERE l.resource_database_id = DB_ID()
  AND (l.request_status <> N'GRANTED'
       OR (l.resource_type = N'OBJECT' AND l.request_mode IN (N'S', N'U', N'X', N'SIX'))
       OR EXISTS (SELECT 1
                  FROM sys.dm_tran_locks AS w
                  WHERE w.request_status <> N'GRANTED'
                    AND w.resource_database_id = l.resource_database_id
                    AND w.resource_type = l.resource_type
                    AND w.resource_associated_entity_id = l.resource_associated_entity_id
                    AND w.resource_description = l.resource_description))
ORDER BY l.resource_type, l.resource_associated_entity_id, l.request_status, l.request_session_id;

-- name: RCA-SQL-03
-- What every waiting task waits on, including the waits that aren't lock waits: PAGELATCH on tempdb's allocation pages
-- (2:1:1, 2:1:3), CXPACKET and CXCONSUMER (several tasks per request), RESOURCE_SEMAPHORE (memory grants), THREADPOOL
-- (no worker), ASYNC_NETWORK_IO (the client isn't reading), WRITELOG. Every 15 s during a waits episode (a wait
-- category's rise over its baseline, RCA-SQL-04). Sessions in ContosoCare only, plus tasks that have no session yet
-- (THREADPOOL). T1, T2 (on T3 the same DMV shows the database's own tasks only).
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    wt.session_id,
    wt.exec_context_id,
    wt.wait_type,
    wt.wait_duration_ms,
    wt.blocking_session_id,
    wt.blocking_exec_context_id,
    wt.resource_description,
    s.program_name
FROM sys.dm_os_waiting_tasks AS wt
LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = wt.session_id
WHERE wt.wait_type = N'THREADPOOL'
   OR s.database_id = DB_ID()
ORDER BY wt.session_id, wt.exec_context_id;

-- name: RCA-SQL-04
-- Wait statistics since the instance started, cumulative. The sentinel reads them every 30 s and keeps only the
-- per-category deltas in memory; a category that rises well over its own recent baseline starts a waits episode, and
-- the export keeps the episode's per-type deltas against the minutes before it (the categories are
-- sys.query_store_wait_stats' table, the ones Database Hub's SqlServerWaitStats uses). T1, T2.
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    ws.wait_type,
    ws.waiting_tasks_count,
    ws.wait_time_ms,
    ws.max_wait_time_ms,
    ws.signal_wait_time_ms
FROM sys.dm_os_wait_stats AS ws
WHERE ws.waiting_tasks_count > 0;

-- name: RCA-SQL-05
-- Memory grants: the granted and waiting grants of sessions in ContosoCare, and each resource semaphore's queue.
-- Every 15 s while the sentinel sees Memory Grants Pending above 0. T1, T2, T3.
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    mg.session_id,
    mg.request_time,
    mg.grant_time,
    mg.requested_memory_kb,
    mg.granted_memory_kb,
    mg.required_memory_kb,
    mg.used_memory_kb,
    mg.max_used_memory_kb,
    mg.ideal_memory_kb,
    mg.query_cost,
    mg.wait_time_ms,
    mg.queue_id,
    mg.wait_order,
    mg.is_next_candidate,
    mg.dop,
    mg.resource_semaphore_id,
    mg.pool_id,
    s.program_name
FROM sys.dm_exec_query_memory_grants AS mg
JOIN sys.dm_exec_sessions AS s ON s.session_id = mg.session_id
WHERE s.database_id = DB_ID();

-- name: RCA-SQL-06
-- The memory semaphores behind RCA-SQL-05: how much workspace memory there is, and how many queries wait for it.
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    rs.resource_semaphore_id,
    rs.pool_id,
    rs.target_memory_kb,
    rs.max_target_memory_kb,
    rs.total_memory_kb,
    rs.available_memory_kb,
    rs.granted_memory_kb,
    rs.used_memory_kb,
    rs.grantee_count,
    rs.waiter_count,
    rs.timeout_error_count,
    rs.forced_grant_count
FROM sys.dm_exec_query_resource_semaphores AS rs;

-- name: RCA-SQL-07
-- Schedulers and workers: runnable tasks (CPU queue), tasks waiting for a worker (work_queue_count), and the worker
-- limit. Every 15 s during a CPU or worker episode (CPU at or above 80 %, or a THREADPOOL wait rise). T1, T2.
SET NOCOUNT ON;
SELECT
    captured_at_utc  = SYSUTCDATETIME(),
    schedulers       = COUNT(*),
    runnable_tasks   = SUM(sc.runnable_tasks_count),
    current_tasks    = SUM(sc.current_tasks_count),
    current_workers  = SUM(sc.current_workers_count),
    active_workers   = SUM(sc.active_workers_count),
    work_queue       = SUM(sc.work_queue_count),
    pending_disk_io  = SUM(sc.pending_disk_io_count),
    max_workers      = MAX(si.max_workers_count)
FROM sys.dm_os_schedulers AS sc
CROSS JOIN sys.dm_os_sys_info AS si
WHERE sc.status = N'VISIBLE ONLINE';

-- name: RCA-SQL-08
-- File I/O, cumulative (diffed): reads, writes, bytes, and stall time for ContosoCare's files and tempdb's, during an
-- IO, log, or CPU episode. T1, T2. (T3: RCA-AZ-05.)
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    vfs.database_id,
    vfs.file_id,
    mf.type_desc,
    vfs.num_of_reads,
    vfs.num_of_bytes_read,
    vfs.io_stall_read_ms,
    vfs.num_of_writes,
    vfs.num_of_bytes_written,
    vfs.io_stall_write_ms,
    vfs.io_stall_queued_read_ms,
    vfs.io_stall_queued_write_ms,
    vfs.size_on_disk_bytes
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
WHERE vfs.database_id IN (DB_ID(N'ContosoCare'), 2);

-- name: RCA-SQL-09
-- The sentinel, every 30 s for the whole session, and the counters waits don't show: blocked processes, lock
-- escalations, lock timeouts, deadlocks, attentions (client cancels), log flushes, and pending memory grants. Per-second
-- counters are cumulative; the runner diffs them. A sample with Processes blocked above 0 starts the 10-s blocking
-- capture (RCA-SQL-01, 02), which stops after 60 s without one. T1, T2, T3 (Learn's page applies to Azure SQL
-- Database; the observer reads the counters this returns there, and records a missing one as not captured).
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    object_name     = RTRIM(pc.object_name),
    counter_name    = RTRIM(pc.counter_name),
    instance_name   = RTRIM(pc.instance_name),
    pc.cntr_value,
    pc.cntr_type
FROM sys.dm_os_performance_counters AS pc
WHERE pc.counter_name IN (N'Processes blocked', N'Table Lock Escalations/sec', N'Lock Timeouts/sec', N'Number of Deadlocks/sec',
                          N'SQL Attention rate', N'Log Flushes/sec', N'Log Flush Wait Time', N'Memory Grants Pending',
                          N'Memory Grants Outstanding', N'Active Transactions', N'User Connections')
  AND pc.instance_name IN (N'', N'_Total', N'ContosoCare');

-- name: RCA-SQL-10
-- Query Store: an episode's top queries by CPU, per plan, with their module and text. Once at the end of every CPU,
-- waits, or memory episode, and once for the same length of time before it (the baseline). T1, T2, T3 (Query Store is on
-- in ContosoCare on every SQL target: database/*/030-configure.sql). Intervals are 15 minutes long, so the window is
-- widened to whole intervals; the times are said with the result.
SET NOCOUNT ON;
DECLARE @from datetimeoffset(0) = TODATETIMEOFFSET(DATEADD(minute, -15, SYSUTCDATETIME()), 0);
DECLARE @to datetimeoffset(0) = TODATETIMEOFFSET(SYSUTCDATETIME(), 0);
WITH stats AS (
    SELECT
        p.query_id,
        rs.plan_id,
        interval_start     = MIN(i.start_time),
        interval_end       = MAX(i.end_time),
        executions         = SUM(rs.count_executions),
        cpu_ms             = SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0,
        duration_ms        = SUM(rs.avg_duration * rs.count_executions) / 1000.0,
        logical_reads      = SUM(rs.avg_logical_io_reads * rs.count_executions),
        physical_reads     = SUM(rs.avg_physical_io_reads * rs.count_executions),
        log_bytes          = SUM(rs.avg_log_bytes_used * rs.count_executions),
        max_used_memory_kb = MAX(rs.max_query_max_used_memory) * 8,
        max_dop            = MAX(rs.max_dop)
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE i.end_time > @from AND i.start_time < @to
    GROUP BY p.query_id, rs.plan_id
)
SELECT TOP (20)
    st.query_id,
    st.plan_id,
    st.interval_start,
    st.interval_end,
    st.executions,
    st.cpu_ms,
    st.duration_ms,
    st.logical_reads,
    st.physical_reads,
    st.log_bytes,
    st.max_used_memory_kb,
    st.max_dop,
    q.query_hash,
    module_name = CASE WHEN q.object_id <> 0 THEN QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(q.object_id)) END,
    qt.query_sql_text,
    p.is_forced_plan,
    p.plan_forcing_type_desc,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    p.count_compiles,
    p.last_compile_start_time,
    plans_for_query = (SELECT COUNT(*) FROM sys.query_store_plan AS p2 WHERE p2.query_id = st.query_id)
FROM stats AS st
JOIN sys.query_store_plan AS p ON p.plan_id = st.plan_id
JOIN sys.query_store_query AS q ON q.query_id = st.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
ORDER BY st.cpu_ms DESC;

-- name: RCA-SQL-11
-- Query Store's waits for the same top plans, by wait category (Lock, Buffer IO, Memory, Parallelism, CPU, ...).
SET NOCOUNT ON;
DECLARE @from datetimeoffset(0) = TODATETIMEOFFSET(DATEADD(minute, -15, SYSUTCDATETIME()), 0);
DECLARE @to datetimeoffset(0) = TODATETIMEOFFSET(SYSUTCDATETIME(), 0);
SELECT TOP (60)
    ws.plan_id,
    ws.wait_category_desc,
    total_wait_ms = SUM(ws.total_query_wait_time_ms),
    max_wait_ms   = MAX(ws.max_query_wait_time_ms)
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
WHERE i.end_time > @from AND i.start_time < @to
GROUP BY ws.plan_id, ws.wait_category_desc
ORDER BY total_wait_ms DESC;

-- name: RCA-SQL-12
-- Deadlock graphs from the always-on system_health session, when the ContosoCare_RCA session isn't there (an older
-- runner, or the owner turned it off): deadlocks since @since. SQL Server only (T1, T2).
SET NOCOUNT ON;
DECLARE @since datetime2(7) = DATEADD(minute, -15, SYSUTCDATETIME());
SELECT
    f.timestamp_utc,
    event_xml = CAST(f.event_data AS xml)
FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) AS f
WHERE f.object_name = N'xml_deadlock_report'
  AND f.timestamp_utc >= @since;

-- name: RCA-SQL-13
-- The optimizer's missing index suggestions for ContosoCare: the table, the columns, and how often and how much a
-- matching index would have helped since the instance started (diffed between the episode's start and end). Once at the
-- end of every CPU or IO episode. T1, T2, T3. Suggestions are evidence for a person's review, never applied by the
-- capture.
SET NOCOUNT ON;
SELECT
    captured_at_utc     = SYSUTCDATETIME(),
    d.index_handle,
    table_name          = d.statement,
    d.equality_columns,
    d.inequality_columns,
    d.included_columns,
    s.user_seeks,
    s.user_scans,
    s.last_user_seek,
    s.avg_total_user_cost,
    s.avg_user_impact
FROM sys.dm_db_missing_index_details AS d
JOIN sys.dm_db_missing_index_groups AS g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats AS s ON s.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID()
ORDER BY s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans) DESC;

-- name: RCA-AZ-01
-- T3 only: resource governance, 15-second averages for the last hour (Azure SQL Database keeps them that long): CPU
-- against the service objective's cap, the log rate governor (avg_log_write_percent), workers, sessions, data I/O, and
-- memory. Every 30 minutes and at the session's end (Phase 1: T3's dense CPU, where Database Hub's bins are sparse); the
-- runner keeps every new row, with no deadband, so a missing row is a missing sample, never an unchanged one.
SET NOCOUNT ON;
SELECT
    rs.end_time,
    rs.avg_cpu_percent,
    rs.avg_data_io_percent,
    rs.avg_log_write_percent,
    rs.avg_memory_usage_percent,
    rs.max_worker_percent,
    rs.max_session_percent,
    rs.avg_instance_cpu_percent,
    rs.avg_instance_memory_percent,
    rs.cpu_limit
FROM sys.dm_db_resource_stats AS rs
WHERE rs.end_time > DATEADD(minute, -35, SYSUTCDATETIME())
ORDER BY rs.end_time;

-- name: RCA-AZ-02
-- T3 only: the database's wait statistics, cumulative (diffed like RCA-SQL-04).
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    ws.wait_type,
    ws.waiting_tasks_count,
    ws.wait_time_ms,
    ws.max_wait_time_ms,
    ws.signal_wait_time_ms
FROM sys.dm_db_wait_stats AS ws
WHERE ws.waiting_tasks_count > 0;

-- name: RCA-AZ-03
-- T3 only: automatic plan correction: the option's desired and actual state and why, as a DBA would check it. Every
-- 30 s with the sentinel; a change of state is recorded as a tuning event (RCA Events).
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    o.name,
    o.desired_state_desc,
    o.actual_state_desc,
    o.reason_desc
FROM sys.database_automatic_tuning_options AS o;

-- name: RCA-AZ-04
-- T3 only: the tuning recommendations with their state and plan IDs: the regressed and the recommended plan of each
-- query, when the recommendation was valid, and who forced it (system or user).
SET NOCOUNT ON;
SELECT
    captured_at_utc            = SYSUTCDATETIME(),
    tr.name,
    tr.type,
    tr.reason,
    tr.valid_since,
    tr.last_refresh,
    state                      = JSON_VALUE(tr.state, N'$.currentValue'),
    state_reason               = JSON_VALUE(tr.state, N'$.reason'),
    tr.is_executable_action,
    tr.is_revertable_action,
    tr.execute_action_start_time,
    tr.execute_action_initiated_by,
    tr.execute_action_initiated_time,
    tr.score,
    query_id                   = JSON_VALUE(tr.details, N'$.planForceDetails.queryId'),
    regressed_plan_id          = JSON_VALUE(tr.details, N'$.planForceDetails.regressedPlanId'),
    recommended_plan_id        = JSON_VALUE(tr.details, N'$.planForceDetails.recommendedPlanId'),
    regressed_plan_cpu_ms      = JSON_VALUE(tr.details, N'$.planForceDetails.regressedPlanCpuTimeAverage'),
    recommended_plan_cpu_ms    = JSON_VALUE(tr.details, N'$.planForceDetails.recommendedPlanCpuTimeAverage'),
    estimated_gain             = JSON_VALUE(tr.details, N'$.estimatedGain')
FROM sys.dm_db_tuning_recommendations AS tr;

-- name: RCA-AZ-05
-- T3 only: file I/O for ContosoCare's own files (Azure SQL Database has no sys.master_files), cumulative (diffed).
SET NOCOUNT ON;
SELECT
    captured_at_utc = SYSUTCDATETIME(),
    vfs.file_id,
    df.type_desc,
    vfs.num_of_reads,
    vfs.num_of_bytes_read,
    vfs.io_stall_read_ms,
    vfs.num_of_writes,
    vfs.num_of_bytes_written,
    vfs.io_stall_write_ms
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS vfs
JOIN sys.database_files AS df ON df.file_id = vfs.file_id;

-- name: RCA-XE-00
-- Before RCA-XE-01 or RCA-XE-03: the fields each event carries, from the documented catalog (Learn's CREATE EVENT
-- SESSION page points to sys.dm_xe_object_columns for them; Learn has no field reference for error_reported). The
-- runner reads only fields this lists, and records a missing one as "not captured" instead of failing.
SET NOCOUNT ON;
SELECT
    event_name  = o.name,
    column_name = c.name,
    c.type_name,
    c.column_type
FROM sys.dm_xe_objects AS o
JOIN sys.dm_xe_object_columns AS c ON c.object_name = o.name AND c.object_package_guid = o.package_guid
WHERE o.object_type = N'event'
  AND o.name IN (N'error_reported', N'attention', N'lock_escalation', N'xml_deadlock_report', N'database_xml_deadlock_report')
  AND c.column_type = N'data'
ORDER BY o.name, c.name;

-- name: RCA-XE-01
-- T1, T2: the observer's Extended Events session, created when the observer starts and dropped at the session's end
-- (RCA-XE-05), so errors and deadlocks are seen whenever they happen. Errors raised in ContosoCare (severity 11 and up,
-- including the ones a TRY...CATCH intercepts: is_intercepted), client attentions (cancels and timeouts), lock
-- escalations, and deadlock graphs. Events stay in memory (ring_buffer), at most 1,024 KB and 5,000 events, and losing one
-- under pressure is allowed: a read returns the target as one XML document of at most 4 MB, so Learn recommends a
-- ring_buffer MAX_MEMORY of 1,024 KB or less, and a full buffer is then never truncated on read
-- (https://learn.microsoft.com/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server#ring_buffer-target).
-- A session left behind by a runner that stopped is dropped by the next one's start.
IF NOT EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'ContosoCare_RCA')
    CREATE EVENT SESSION [ContosoCare_RCA] ON SERVER
    ADD EVENT sqlserver.error_reported (
        ACTION (sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username, sqlserver.session_id, sqlserver.sql_text)
        WHERE ([severity] >= (11) AND [sqlserver].[database_name] = N'ContosoCare')),
    ADD EVENT sqlserver.attention (
        ACTION (sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username, sqlserver.session_id, sqlserver.sql_text)
        WHERE ([sqlserver].[database_name] = N'ContosoCare')),
    ADD EVENT sqlserver.lock_escalation (
        ACTION (sqlserver.client_app_name, sqlserver.session_id, sqlserver.sql_text)
        WHERE ([sqlserver].[database_name] = N'ContosoCare')),
    ADD EVENT sqlserver.xml_deadlock_report
    ADD TARGET package0.ring_buffer (SET max_events_limit = (5000), max_memory = (1024))
    WITH (MAX_MEMORY = 8 MB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY = 5 SECONDS,
          TRACK_CAUSALITY = OFF, STARTUP_STATE = OFF);
IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'ContosoCare_RCA')
    ALTER EVENT SESSION [ContosoCare_RCA] ON SERVER STATE = START;

-- name: RCA-XE-02
-- T1, T2: the session's events so far (the runner reads it every 30 s, keeps events newer than its last read, and
-- shreds the XML itself, so the server does no XML work beyond the cast). xml_deadlock_report has no database predicate
-- in RCA-XE-01, so the runner keeps a deadlock graph only when a process in it ran in ContosoCare (its currentdb is
-- ContosoCare's database ID) and drops any other graph unread.
SET NOCOUNT ON;
SELECT target_data = CAST(t.target_data AS xml)
FROM sys.dm_xe_session_targets AS t
JOIN sys.dm_xe_sessions AS s ON s.address = t.event_session_address
WHERE s.name = N'ContosoCare_RCA'
  AND t.target_name = N'ring_buffer';

-- name: RCA-XE-03
-- T3: the same session, database-scoped (Azure SQL Database has database-scoped sessions only, no system_health, and
-- Learn says not to read its built-in dl session). Deadlocks are database_xml_deadlock_report there. Needs CREATE ANY
-- DATABASE EVENT SESSION, which dbo holds through CONTROL.
IF NOT EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ContosoCare_RCA')
    CREATE EVENT SESSION [ContosoCare_RCA] ON DATABASE
    ADD EVENT sqlserver.error_reported (
        ACTION (sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username, sqlserver.session_id, sqlserver.sql_text)
        WHERE ([severity] >= (11))),
    ADD EVENT sqlserver.attention (
        ACTION (sqlserver.client_app_name, sqlserver.client_hostname, sqlserver.username, sqlserver.session_id, sqlserver.sql_text)),
    ADD EVENT sqlserver.lock_escalation (
        ACTION (sqlserver.client_app_name, sqlserver.session_id, sqlserver.sql_text)),
    ADD EVENT sqlserver.database_xml_deadlock_report
    ADD TARGET package0.ring_buffer (SET max_events_limit = (5000), max_memory = (1024))
    WITH (MAX_MEMORY = 8 MB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY = 5 SECONDS,
          TRACK_CAUSALITY = OFF, STARTUP_STATE = OFF);
IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = N'ContosoCare_RCA')
    ALTER EVENT SESSION [ContosoCare_RCA] ON DATABASE STATE = START;

-- name: RCA-XE-04
-- T3: the database-scoped session's events so far.
SET NOCOUNT ON;
SELECT target_data = CAST(t.target_data AS xml)
FROM sys.dm_xe_database_session_targets AS t
JOIN sys.dm_xe_database_sessions AS s ON s.address = t.event_session_address
WHERE s.name = N'ContosoCare_RCA'
  AND t.target_name = N'ring_buffer';

-- name: RCA-XE-05
-- T1, T2: the end. Stop and drop the session, so nothing of the observer stays on the instance. (T3: the same
-- statements with ON DATABASE and sys.database_event_sessions.) Run at the session's end, before RCA-XE-01 at the
-- observer's start (a session left behind by a runner that stopped), and by the runner's reset (ADR 0010's amendment).
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'ContosoCare_RCA')
    ALTER EVENT SESSION [ContosoCare_RCA] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'ContosoCare_RCA')
    DROP EVENT SESSION [ContosoCare_RCA] ON SERVER;
