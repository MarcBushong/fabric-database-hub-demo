-- Incident RCA capture for T1 (SQL Server 2022 on an Azure VM), T2 (Arc-enabled SQL Server 2022 in the nested guest),
-- and T3 (Azure SQL Database). The contract: rca/README.md; the design: docs/adr/0031-incident-rca.md. Each block is one
-- batch, named "-- name: <ID>"; rca/capture/README.md lists them with their permissions and documentation.
--
-- Who runs it: the runner's observer lane, connected to ContosoCare with Application Name ContosoCare.Demo/control/rca
-- (so demo.fn_demo_sessions and demo.usp_kill_demo_sessions never list or end it). T1 and T2: Windows authentication as
-- the runner's identity (SYSTEM, a sysadmin through BUILTIN\Administrators in the default JumpstartImage and T1 modes:
-- vm/hyperv-guest/GuestWorkload.ps1, vm/bootstrap/Invoke-SqlVmBootstrap.ps1). T3: T1's managed identity, dbo through
-- the P6 administrator group (database/azuresql/030-configure.sql). No new permission or role assignment.
-- Least privilege, if the owner wants a dedicated login later (rca/capture/README.md lists each block's permission).
-- SQL Server 2022: VIEW SERVER PERFORMANCE STATE covers the DMVs and Query Store's views below, and ALTER ANY EVENT
-- SESSION the XE session. Azure SQL Database: VIEW DATABASE STATE in ContosoCare covers them, and CREATE ANY DATABASE
-- EVENT SESSION the XE session; RCA-AZ-04 also needs VIEW SERVER PERFORMANCE STATE, which there comes only through the
-- ##MS_ServerStateReader## server role, for a login in master with its own user in ContosoCare. Both: VIEW DEFINITION
-- for the harness's mark (sys.extended_properties).
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
-- login, or host. Query Store's statements (RCA-SQL-10, 14) belong to no session: every one is kept, normalized the same
-- way, but the capture's own and the harness's, which every statement here marks or the demo marks
-- (rca/README.md, What the capture leaves out).

-- name: RCA-SQL-01
-- The blocking snapshot: one row per session in ContosoCare that waits on another session or that another session
-- waits on, with what it runs (or ran last, when idle) and who runs it. Every 10 s from the sentinel's first sample
-- with Processes blocked above 0 (RCA-SQL-09) until 60 s without one. T1, T2, T3.
-- blocking_session_id -2, -3, -4 (orphaned distributed transaction, deferred recovery, latch owner unknown) are kept.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
DECLARE @db int = DB_ID();
WITH /* dbhubdemo:rca-observer */ edges AS (
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
-- Query Store's top plans per interval (the sidecar): for each Query Store interval that ended after @since, the queries
-- among its top 10 plans by CPU, top 5 by duration, top 5 by logical reads, and top 5 by wait time (every wait category
-- but Idle and Unknown), with every plan of theirs that ran in the interval: its runtime statistics summed over the
-- interval's rows (execution-weighted: each row's average times its executions). Read every 15 minutes, 2 minutes after
-- an interval ends, for the intervals that ended since the previous read; at the observer's start for the 2 hours before
-- it; and at its end with @final = 1, which adds the interval still open (Query Store unifies its in-memory and on-disk
-- data when it's read). T1, T2, T3: Query Store is on in ContosoCare on each, at 15-minute intervals
-- (database/*/030-configure.sql). Parameters: @since datetimeoffset, the end of the last interval read; @final bit;
-- @left_out nvarchar(max), a JSON array of the query_ids RCA-SQL-16 found to be the runner's own.
-- Left out, by three fixed rules and nothing else (rca/README.md, What the capture leaves out): the capture's own
-- statements, which carry the marker dbhubdemo:rca-observer in their text, as this one does; every statement of a
-- module the demo marks as its harness (the extended property dbhubdemo.role = harness, which database/common's control
-- script sets on its own modules); and the runner's own ad hoc statements, @left_out. Everything else is measured
-- evidence: the scenario modules' reads and writes, other applications' statements, and monitoring queries alike. The
-- top lists are ranked after those leave-outs, a plan is in one only when it used what the list ranks (CPU, time,
-- reads, or waits above 0), and ties go to the lower plan_id, so two reads of an interval rank it alike. At most 600
-- rows, the oldest intervals first: the runner reads again from the last whole interval it got.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
WITH /* dbhubdemo:rca-observer */ harness AS (
    SELECT ep.major_id AS object_id
    FROM sys.extended_properties AS ep
    WHERE ep.class = 1
      AND ep.minor_id = 0
      AND ep.name = N'dbhubdemo.role'
      AND CAST(ep.value AS nvarchar(100)) = N'harness'
),
intervals AS (
    SELECT i.runtime_stats_interval_id, i.start_time, i.end_time
    FROM sys.query_store_runtime_stats_interval AS i
    WHERE i.end_time > @since
      AND (i.end_time <= SYSDATETIMEOFFSET() OR @final = 1)
),
plans AS (
    SELECT
        i.runtime_stats_interval_id,
        i.start_time,
        i.end_time,
        p.query_id,
        rs.plan_id,
        executions           = SUM(rs.count_executions),
        aborted_executions   = SUM(CASE WHEN rs.execution_type IN (3, 4) THEN rs.count_executions ELSE 0 END),
        cpu_ms               = SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0,
        duration_ms          = SUM(rs.avg_duration * rs.count_executions) / 1000.0,
        max_duration_ms      = MAX(rs.max_duration) / 1000.0,
        logical_reads        = SUM(rs.avg_logical_io_reads * rs.count_executions),
        physical_reads       = SUM(rs.avg_physical_io_reads * rs.count_executions),
        row_count            = SUM(rs.avg_rowcount * rs.count_executions),
        log_bytes            = SUM(rs.avg_log_bytes_used * rs.count_executions),
        tempdb_kb            = SUM(rs.avg_tempdb_space_used * rs.count_executions) * 8,
        max_used_memory_kb   = MAX(rs.max_query_max_used_memory) * 8,
        max_dop              = MAX(rs.max_dop),
        first_execution_time = MIN(rs.first_execution_time),
        last_execution_time  = MAX(rs.last_execution_time)
    FROM intervals AS i
    JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    GROUP BY i.runtime_stats_interval_id, i.start_time, i.end_time, p.query_id, rs.plan_id
),
waits AS (
    SELECT ws.runtime_stats_interval_id, ws.plan_id, wait_ms = SUM(ws.total_query_wait_time_ms)
    FROM sys.query_store_wait_stats AS ws
    WHERE ws.runtime_stats_interval_id IN (SELECT i.runtime_stats_interval_id FROM intervals AS i)
      AND ws.wait_category_desc NOT IN (N'Idle', N'Unknown')
    GROUP BY ws.runtime_stats_interval_id, ws.plan_id
),
kept AS (
    SELECT
        pl.runtime_stats_interval_id,
        pl.start_time,
        pl.end_time,
        pl.query_id,
        pl.plan_id,
        pl.executions,
        pl.aborted_executions,
        pl.cpu_ms,
        pl.duration_ms,
        pl.max_duration_ms,
        pl.logical_reads,
        pl.physical_reads,
        pl.row_count,
        pl.log_bytes,
        pl.tempdb_kb,
        pl.max_used_memory_kb,
        pl.max_dop,
        pl.first_execution_time,
        pl.last_execution_time,
        wait_ms       = w.wait_ms,
        q.query_hash,
        q.object_id,
        qt.query_sql_text,
        cpu_rank      = ROW_NUMBER() OVER (PARTITION BY pl.runtime_stats_interval_id ORDER BY pl.cpu_ms DESC, pl.plan_id),
        duration_rank = ROW_NUMBER() OVER (PARTITION BY pl.runtime_stats_interval_id ORDER BY pl.duration_ms DESC, pl.plan_id),
        reads_rank    = ROW_NUMBER() OVER (PARTITION BY pl.runtime_stats_interval_id ORDER BY pl.logical_reads DESC, pl.plan_id),
        wait_rank     = ROW_NUMBER() OVER (PARTITION BY pl.runtime_stats_interval_id ORDER BY ISNULL(w.wait_ms, 0) DESC, pl.plan_id)
    FROM plans AS pl
    JOIN sys.query_store_query AS q ON q.query_id = pl.query_id
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    LEFT JOIN waits AS w ON w.runtime_stats_interval_id = pl.runtime_stats_interval_id AND w.plan_id = pl.plan_id
    WHERE q.object_id NOT IN (SELECT h.object_id FROM harness AS h)
      AND qt.query_sql_text NOT LIKE N'%dbhubdemo:rca-observer%'
      AND q.query_id NOT IN (SELECT CAST(j.[value] AS bigint) FROM OPENJSON(@left_out) AS j)
),
chosen AS (
    SELECT DISTINCT k.runtime_stats_interval_id, k.query_id
    FROM kept AS k
    WHERE (k.cpu_rank <= 10 AND k.cpu_ms > 0)
       OR (k.duration_rank <= 5 AND k.duration_ms > 0)
       OR (k.reads_rank <= 5 AND k.logical_reads > 0)
       OR (k.wait_rank <= 5 AND k.wait_ms > 0)
)
SELECT TOP (600)
    captured_at_utc    = SYSUTCDATETIME(),
    interval_start_utc = k.start_time,
    interval_end_utc   = k.end_time,
    k.query_id,
    k.plan_id,
    k.query_hash,
    plan_hash          = p.query_plan_hash,
    module_name        = CASE WHEN k.object_id <> 0 THEN QUOTENAME(OBJECT_SCHEMA_NAME(k.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(k.object_id)) END,
    k.query_sql_text,
    k.executions,
    k.aborted_executions,
    k.cpu_ms,
    k.duration_ms,
    k.max_duration_ms,
    k.logical_reads,
    k.physical_reads,
    k.row_count,
    k.log_bytes,
    k.tempdb_kb,
    k.max_used_memory_kb,
    k.max_dop,
    k.wait_ms,
    first_execution_utc = k.first_execution_time,
    last_execution_utc  = k.last_execution_time
FROM kept AS k
JOIN chosen AS c ON c.runtime_stats_interval_id = k.runtime_stats_interval_id AND c.query_id = k.query_id
JOIN sys.query_store_plan AS p ON p.plan_id = k.plan_id
ORDER BY k.start_time, k.cpu_ms DESC, k.plan_id;

-- name: RCA-SQL-11
-- Query Store's waits by category (Lock, CPU, Buffer IO, Memory, Parallelism, Tran Log IO, Network IO, ...) for the plans
-- RCA-SQL-10 returned (the sidecar): each plan's three largest in each interval, Idle and Unknown left out. Read with
-- RCA-SQL-10, with its @since and @final, and @plans nvarchar(max): its plan_ids, comma-separated. T1, T2, T3.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
WITH /* dbhubdemo:rca-observer */ waits AS (
    SELECT
        i.start_time,
        i.end_time,
        p.query_id,
        ws.plan_id,
        ws.wait_category_desc,
        wait_ms     = SUM(ws.total_query_wait_time_ms),
        max_wait_ms = MAX(ws.max_query_wait_time_ms)
    FROM sys.query_store_wait_stats AS ws
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = ws.plan_id
    WHERE i.end_time > @since
      AND (i.end_time <= SYSDATETIMEOFFSET() OR @final = 1)
      AND ws.plan_id IN (SELECT TRY_CAST(v.value AS bigint) FROM STRING_SPLIT(@plans, N',') AS v)
      AND ws.wait_category_desc NOT IN (N'Idle', N'Unknown')
    GROUP BY i.start_time, i.end_time, p.query_id, ws.plan_id, ws.wait_category_desc
),
ranked AS (
    SELECT
        w.start_time,
        w.end_time,
        w.query_id,
        w.plan_id,
        w.wait_category_desc,
        w.wait_ms,
        w.max_wait_ms,
        wait_rank = ROW_NUMBER() OVER (PARTITION BY w.start_time, w.plan_id ORDER BY w.wait_ms DESC, w.wait_category_desc)
    FROM waits AS w
)
SELECT
    captured_at_utc    = SYSUTCDATETIME(),
    interval_start_utc = r.start_time,
    interval_end_utc   = r.end_time,
    r.query_id,
    r.plan_id,
    wait_category      = r.wait_category_desc,
    r.wait_ms,
    r.max_wait_ms
FROM ranked AS r
WHERE r.wait_rank <= 3
  AND r.wait_ms > 0
ORDER BY r.start_time, r.plan_id, r.wait_ms DESC, r.wait_category_desc;

-- name: RCA-SQL-12
-- Deadlock graphs from the always-on system_health session, when the ContosoCare_RCA session isn't there (an older
-- runner, or the owner turned it off): deadlocks since @since. SQL Server only (T1, T2).
SET NOCOUNT ON;
DECLARE @since datetime2(7) = DATEADD(minute, -15, SYSUTCDATETIME());
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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

-- name: RCA-SQL-14
-- Query Store's plans (the sidecar): the plans of the queries RCA-SQL-10 returned, at most the 5 of each query that ran
-- last, every plan RCA-SQL-10 returned (so each of its rows has its plan), and every forced plan: when each was compiled
-- and last ran, whether it's forced and how, and its forcing failures; and, for the plans named in @with_plan only, its
-- showplan XML, which the observer reduces to the plan's shape (its costliest operators with their objects and indexes,
-- its warnings, a missing index) and never keeps a parameter's value from. A showplan over 16,777,216 bytes (8,388,608
-- characters, the most the observer reduces) isn't returned: query_plan_bytes says its size, so the coverage says why
-- the plan has no summary. Read with RCA-SQL-10. Parameters: @queries nvarchar(max), RCA-SQL-10's query_ids,
-- comma-separated; @plans nvarchar(max), its plan_ids; @with_plan nvarchar(max), the plan_ids whose XML the observer
-- hasn't reduced yet; @left_out nvarchar(max), RCA-SQL-10's. It leaves out what RCA-SQL-10 leaves out, by the same three
-- rules, so a forced plan of the runner's own statements isn't returned either. T1, T2, T3.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
WITH /* dbhubdemo:rca-observer */ harness AS (
    SELECT ep.major_id AS object_id
    FROM sys.extended_properties AS ep
    WHERE ep.class = 1
      AND ep.minor_id = 0
      AND ep.name = N'dbhubdemo.role'
      AND CAST(ep.value AS nvarchar(100)) = N'harness'
),
recent AS (
    SELECT p.plan_id, last_rank = ROW_NUMBER() OVER (PARTITION BY p.query_id ORDER BY p.last_execution_time DESC, p.plan_id DESC)
    FROM sys.query_store_plan AS p
    WHERE p.query_id IN (SELECT TRY_CAST(v.value AS bigint) FROM STRING_SPLIT(@queries, N',') AS v)
),
chosen AS (
    SELECT r.plan_id FROM recent AS r WHERE r.last_rank <= 5
    UNION
    SELECT TRY_CAST(v.value AS bigint) FROM STRING_SPLIT(@plans, N',') AS v
    UNION
    SELECT p.plan_id FROM sys.query_store_plan AS p WHERE p.is_forced_plan = 1
)
SELECT
    captured_at_utc    = SYSUTCDATETIME(),
    p.query_id,
    p.plan_id,
    q.query_hash,
    plan_hash          = p.query_plan_hash,
    module_name        = CASE WHEN q.object_id <> 0 THEN QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(q.object_id)) END,
    qt.query_sql_text,
    compiled_utc       = p.initial_compile_start_time,
    last_compiled_utc  = p.last_compile_start_time,
    last_execution_utc = p.last_execution_time,
    compiles           = p.count_compiles,
    p.is_forced_plan,
    forcing_type       = p.plan_forcing_type_desc,
    force_failures     = p.force_failure_count,
    last_force_failure = CASE WHEN p.force_failure_count > 0 THEN p.last_force_failure_reason_desc END,
    plans_for_query    = (SELECT COUNT(*) FROM sys.query_store_plan AS p2 WHERE p2.query_id = p.query_id),
    is_parallel        = p.is_parallel_plan,
    query_plan         = CASE WHEN p.plan_id IN (SELECT TRY_CAST(v.value AS bigint) FROM STRING_SPLIT(@with_plan, N',') AS v)
                               AND DATALENGTH(p.query_plan) <= 16777216 THEN p.query_plan END,
    query_plan_bytes   = CASE WHEN p.plan_id IN (SELECT TRY_CAST(v.value AS bigint) FROM STRING_SPLIT(@with_plan, N',') AS v) THEN DATALENGTH(p.query_plan) END
FROM chosen AS c
JOIN sys.query_store_plan AS p ON p.plan_id = c.plan_id
JOIN sys.query_store_query AS q ON q.query_id = p.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE q.object_id NOT IN (SELECT h.object_id FROM harness AS h)
  AND qt.query_sql_text NOT LIKE N'%dbhubdemo:rca-observer%'
  AND q.query_id NOT IN (SELECT CAST(j.[value] AS bigint) FROM OPENJSON(@left_out) AS j)
ORDER BY p.query_id, p.plan_id;

-- name: RCA-SQL-15
-- Query Store's state as a DBA checks it, and its forced plans, in one row (the sidecar): the actual and desired state,
-- why it's read-only when it is (readonly_reason, Learn's codes), its capture mode, interval, and storage against its
-- limit; and every forced plan as query_id:plan_id:forcing type, semicolon-separated. Every 60 s on T1, T2, T3. A state
-- other than READ_WRITE is a coverage gap that says so, and a plan forced or unforced since the previous read is an RCA
-- Query Events row, timed within a minute.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
SELECT /* dbhubdemo:rca-observer */
    captured_at_utc    = SYSUTCDATETIME(),
    actual_state       = o.actual_state_desc,
    desired_state      = o.desired_state_desc,
    o.readonly_reason,
    query_capture_mode = o.query_capture_mode_desc,
    o.interval_length_minutes,
    o.current_storage_size_mb,
    o.max_storage_size_mb,
    forced_plans       = (SELECT STRING_AGG(CONCAT(CAST(f.query_id AS nvarchar(max)), N':', f.plan_id, N':', f.plan_forcing_type_desc), N';')
                                 WITHIN GROUP (ORDER BY f.query_id, f.plan_id)
                          FROM sys.query_store_plan AS f
                          WHERE f.is_forced_plan = 1)
FROM sys.database_query_store_options AS o;

-- name: RCA-SQL-16
-- The ad hoc statements (object_id 0) that ran in the intervals RCA-SQL-10 is about to read, with their text, so that the
-- runner leaves out its own (rca/README.md, What the capture leaves out, 3): it compares each text, normalized, with its
-- list of the statements it sends outside a module (Rca/QueryStore/HarnessStatements.cs) and of the observer's own as
-- earlier runners sent them, before the marker (Rca/QueryStore/SqlObserverStatements.cs; item 1), and passes the
-- query_ids that match to RCA-SQL-10 and 14 as @left_out. Read before each RCA-SQL-10 read, with its @since and @final.
-- Not returned: a text over 4,000 characters (the runner's are much shorter), a query the engine generated itself
-- (is_internal_query, such as an automatic statistics update), and the capture's own statements, which carry the
-- marker. At most 2,000 rows, the most executed first: the stop check every run polls is always near the top, and the
-- read's coverage says when the bound was hit. A statement of the runner's that this block doesn't return, past the
-- bound or in an interval that ended between this read and RCA-SQL-10's, is matched by the text RCA-SQL-10 and 14
-- return: the runner drops its rows and reads RCA-SQL-10's page again without it. The texts are only compared, never
-- kept. T1, T2, T3.
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;
WITH /* dbhubdemo:rca-observer */ intervals AS (
    SELECT i.runtime_stats_interval_id
    FROM sys.query_store_runtime_stats_interval AS i
    WHERE i.end_time > @since
      AND (i.end_time <= SYSDATETIMEOFFSET() OR @final = 1)
),
ran AS (
    SELECT p.query_id, executions = SUM(rs.count_executions)
    FROM intervals AS i
    JOIN sys.query_store_runtime_stats AS rs ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    GROUP BY p.query_id
)
SELECT TOP (2000)
    r.query_id,
    qt.query_sql_text
FROM ran AS r
JOIN sys.query_store_query AS q ON q.query_id = r.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE q.object_id = 0
  AND q.is_internal_query = 0
  AND LEN(qt.query_sql_text) <= 4000
  AND qt.query_sql_text NOT LIKE N'%dbhubdemo:rca-observer%'
ORDER BY r.executions DESC, r.query_id;

-- name: RCA-AZ-01
-- T3 only: resource governance, 15-second averages for the last hour (Azure SQL Database keeps them that long): CPU
-- against the service objective's cap, the log rate governor (avg_log_write_percent), workers, sessions, data I/O, and
-- memory. Every 30 minutes and at the session's end (Phase 1: T3's dense CPU, where Database Hub's bins are sparse); the
-- runner keeps every new row, with no deadband, so a missing row is a missing sample, never an unchanged one.
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */
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
SELECT /* dbhubdemo:rca-observer */
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
-- 30 s with the sentinel; a change of state is an RCA Query Events row of kind tuning (the sidecar).
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */
    captured_at_utc = SYSUTCDATETIME(),
    o.name,
    o.desired_state_desc,
    o.actual_state_desc,
    o.reason_desc
FROM sys.database_automatic_tuning_options AS o;

-- name: RCA-AZ-04
-- T3 only: the tuning recommendations with their state and plan IDs: the regressed and the recommended plan of each
-- query, when the recommendation was valid, and who forced it (system or user). A recommendation that appears, or whose
-- state changes, is an RCA Query Events row of kind tuning (the sidecar). The plans' CPU averages are Learn's
-- microseconds (regressedPlanCpuTimeAverage, recommendedPlanCpuTimeAverage), as the recommendation measured them when
-- it detected the regression; the observer writes them in milliseconds. Learn lists VIEW SERVER PERFORMANCE STATE for
-- this view on SQL Server 2022 and Azure SQL Database: a server permission, which a contained database user can't
-- hold. On Azure SQL Database, a login in master holds it through the ##MS_ServerStateReader## server role, in each
-- database where the login has a user, and the server's Microsoft Entra administrator holds every permission (Learn:
-- Server roles; Authorize server and database access). A refusal is a gap in the sidecar's coverage that names the
-- permission and that fix; the other reads go on.
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */
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
    regressed_plan_cpu_us      = JSON_VALUE(tr.details, N'$.planForceDetails.regressedPlanCpuTimeAverage'),
    recommended_plan_cpu_us    = JSON_VALUE(tr.details, N'$.planForceDetails.recommendedPlanCpuTimeAverage')
FROM sys.dm_db_tuning_recommendations AS tr;

-- name: RCA-AZ-05
-- T3 only: file I/O for ContosoCare's own files (Azure SQL Database has no sys.master_files), cumulative (diffed).
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */
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
-- runner reads only fields this lists, and records a missing one as "not captured" instead of failing. It reads
-- sys.dm_xe_object_columns alone, by the events' names and their data columns: its earlier join to sys.dm_xe_objects
-- returned the same fields, but its plan read sys.dm_xe_objects again for each column row: on SQL Server 2022 CU25 it
-- ran about 46 s when let finish, so the observer's 30-second timeout for a long statement cut it short at each start,
-- after about 30 s of CPU (2026-11-23).
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */
    event_name  = c.object_name,
    column_name = c.name,
    c.type_name,
    c.column_type
FROM sys.dm_xe_object_columns AS c
WHERE c.object_name IN (N'error_reported', N'attention', N'lock_escalation', N'xml_deadlock_report', N'database_xml_deadlock_report')
  AND c.column_type = N'data'
ORDER BY c.object_name, c.name;

-- name: RCA-XE-01
-- T1, T2: the observer's Extended Events session, created when the observer starts and dropped at the session's end
-- (RCA-XE-05), so errors and deadlocks are seen whenever they happen. Errors raised in ContosoCare (severity 11 and up,
-- including the ones a TRY...CATCH intercepts: is_intercepted), client attentions (cancels and timeouts), lock
-- escalations, and deadlock graphs. Events stay in memory (ring_buffer), at most 1,024 KB and 5,000 events, and losing one
-- under pressure is allowed: a read returns the target as one XML document of at most 4 MB, so Learn recommends a
-- ring_buffer MAX_MEMORY of 1,024 KB or less, and a full buffer is then never truncated on read
-- (https://learn.microsoft.com/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server#ring_buffer-target).
-- A session left behind by a runner that stopped is dropped by the next one's start.
IF NOT EXISTS (SELECT /* dbhubdemo:rca-observer */ 1 FROM sys.server_event_sessions WHERE name = N'ContosoCare_RCA')
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
IF NOT EXISTS (SELECT /* dbhubdemo:rca-observer */ 1 FROM sys.dm_xe_sessions WHERE name = N'ContosoCare_RCA')
    ALTER EVENT SESSION [ContosoCare_RCA] ON SERVER STATE = START;

-- name: RCA-XE-02
-- T1, T2: the session's events so far (the runner reads it every 30 s, keeps events newer than its last read, and
-- shreds the XML itself, so the server does no XML work beyond the cast). xml_deadlock_report has no database predicate
-- in RCA-XE-01, so the runner keeps a deadlock graph only when a process in it ran in ContosoCare (its currentdb is
-- ContosoCare's database ID) and drops any other graph unread.
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */ target_data = CAST(t.target_data AS xml)
FROM sys.dm_xe_session_targets AS t
JOIN sys.dm_xe_sessions AS s ON s.address = t.event_session_address
WHERE s.name = N'ContosoCare_RCA'
  AND t.target_name = N'ring_buffer';

-- name: RCA-XE-03
-- T3: the same session, database-scoped (Azure SQL Database has database-scoped sessions only, no system_health, and
-- Learn says not to read its built-in dl session). Deadlocks are database_xml_deadlock_report there. Needs CREATE ANY
-- DATABASE EVENT SESSION, which dbo holds through CONTROL.
IF NOT EXISTS (SELECT /* dbhubdemo:rca-observer */ 1 FROM sys.database_event_sessions WHERE name = N'ContosoCare_RCA')
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
IF NOT EXISTS (SELECT /* dbhubdemo:rca-observer */ 1 FROM sys.dm_xe_database_sessions WHERE name = N'ContosoCare_RCA')
    ALTER EVENT SESSION [ContosoCare_RCA] ON DATABASE STATE = START;

-- name: RCA-XE-04
-- T3: the database-scoped session's events so far.
SET NOCOUNT ON;
SELECT /* dbhubdemo:rca-observer */ target_data = CAST(t.target_data AS xml)
FROM sys.dm_xe_database_session_targets AS t
JOIN sys.dm_xe_database_sessions AS s ON s.address = t.event_session_address
WHERE s.name = N'ContosoCare_RCA'
  AND t.target_name = N'ring_buffer';

-- name: RCA-XE-05
-- T1, T2: the end. Stop and drop the session, so nothing of the observer stays on the instance. (T3: the same
-- statements with ON DATABASE and sys.database_event_sessions.) Run at the session's end, before RCA-XE-01 at the
-- observer's start (a session left behind by a runner that stopped), and by the runner's reset (ADR 0010's amendment).
IF EXISTS (SELECT /* dbhubdemo:rca-observer */ 1 FROM sys.dm_xe_sessions WHERE name = N'ContosoCare_RCA')
    ALTER EVENT SESSION [ContosoCare_RCA] ON SERVER STATE = STOP;
IF EXISTS (SELECT /* dbhubdemo:rca-observer */ 1 FROM sys.server_event_sessions WHERE name = N'ContosoCare_RCA')
    DROP EVENT SESSION [ContosoCare_RCA] ON SERVER;
