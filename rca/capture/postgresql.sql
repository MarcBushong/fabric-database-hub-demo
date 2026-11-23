-- Incident RCA capture for T4 (Azure Database for PostgreSQL flexible server) and T4-replica (its read replica).
-- The contract: rca/README.md; the design: docs/adr/0031-incident-rca.md. Each block below is one statement, named
-- "-- name: <ID>"; rca/capture/README.md lists them with their permissions and documentation. The runner's
-- observer lane runs them (T1's managed identity, signed in as contosocare_runner, a member of pg_read_all_stats
-- since T4's setup grants it), connected to contosocare with application_name ContosoCare.Demo/control/rca, so the
-- demo's session tools never list or end the observer. Every statement reads; none writes or locks a user table.
-- The runner calls pg_stat_clear_snapshot() before each sample (statistics views otherwise repeat the transaction's
-- first snapshot: database/postgresql/README.md), and diffs the cumulative counters itself.
--
-- Blind (ADR 0031): the observer sees what a DBA's tools see. It never reads what the workload plans or injects, and
-- its cadence follows what it sees: the sentinel (RCA-PG-03, RCA-PG-06, RCA-PG-10) runs every 30 s for the whole
-- session, and a signal over its threshold starts detail capture (rca/README.md, Capture triggers).
--
-- Sources (PostgreSQL 18 documentation, the engine T4 runs):
--   pg_stat_activity, pg_stat_replication, pg_stat_wal_receiver, pg_stat_database, pg_stat_database_conflicts,
--   pg_stat_wal: https://www.postgresql.org/docs/18/monitoring-stats.html
--   pg_blocking_pids, pg_is_in_recovery, pg_last_wal_receive_lsn, pg_last_wal_replay_lsn, pg_last_xact_replay_timestamp,
--   pg_get_wal_replay_pause_state, pg_current_wal_lsn, pg_wal_lsn_diff: https://www.postgresql.org/docs/18/functions-info.html
--   and https://www.postgresql.org/docs/18/functions-admin.html
--   pg_locks: https://www.postgresql.org/docs/18/view-pg-locks.html
--   Hot standby conflicts: https://www.postgresql.org/docs/18/hot-standby.html#HOT-STANDBY-CONFLICT
--   Azure: https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas (lag and its metrics)
--   Query Store (azure_sys: query_store.qs_view, pgms_wait_sampling_view), its parameters, and what it records:
--   https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store; pg_settings, pg_proc, obj_description:
--   https://www.postgresql.org/docs/18/view-pg-settings.html, https://www.postgresql.org/docs/18/catalog-pg-proc.html,
--   https://www.postgresql.org/docs/18/functions-info.html
--
-- Query Store's statements (RCA-PG-14) belong to no session: every one is kept, normalized as the sessions' text is, but
-- the capture's own and the harness's (rca/README.md, What the capture leaves out). The observer's connections set
-- search_path to "$user", public, dbhubdemo_rca_observer, which Query Store records with each statement.

-- name: RCA-PG-01
-- Sessions, waits, and blockers. Primary and replica. Every 10 s from the sentinel's first sample with a client
-- waiting on a lock (RCA-PG-10) until 60 s without one, and every 5 s on the replica while its replay is stalled
-- (RCA-PG-06). Client backends in contosocare that aren't idle, wait on another session, or hold up one;
-- plus the replication processes (startup, walreceiver, walsender), whose waits explain replay. pg_blocking_pids takes
-- the lock manager's shared state briefly, so it runs only in these samples, never in a loop
-- (https://www.postgresql.org/docs/18/functions-info.html, "Frequent calls to this function could have some impact").
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       a.pid,
       a.backend_type,
       a.usename,
       a.application_name,
       a.state,
       a.wait_event_type,
       a.wait_event,
       pg_blocking_pids(a.pid) AS blocked_by,
       round(EXTRACT(EPOCH FROM clock_timestamp() - a.xact_start)::numeric, 1) AS xact_age_s,
       round(EXTRACT(EPOCH FROM clock_timestamp() - a.query_start)::numeric, 1) AS query_age_s,
       round(EXTRACT(EPOCH FROM clock_timestamp() - a.state_change)::numeric, 1) AS state_age_s,
       a.backend_xid::text AS backend_xid,
       a.backend_xmin::text AS backend_xmin,
       a.query_id,
       left(a.query, 2000) AS query
FROM pg_stat_activity AS a
WHERE a.pid <> pg_backend_pid()
  AND (a.backend_type IN ('startup', 'walreceiver', 'walsender')
       OR (a.backend_type = 'client backend'
           AND a.datname = current_database()
           AND (a.state IS DISTINCT FROM 'idle' OR cardinality(pg_blocking_pids(a.pid)) > 0)))
ORDER BY a.pid;

-- name: RCA-PG-02
-- Lock waits and the sessions that hold the lock each one waits for (both sides of every edge). Primary and replica.
-- The relation is named only within contosocare (regclass); waitstart is when the wait began (PostgreSQL 14 and later).
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       w.pid AS waiting_pid,
       w.locktype,
       w.mode AS waiting_mode,
       w.waitstart,
       CASE WHEN w.relation IS NOT NULL AND w.database = (SELECT d.oid FROM pg_database AS d WHERE d.datname = current_database())
            THEN w.relation::regclass::text END AS relation,
       w.transactionid::text AS transactionid,
       w.page,
       w.tuple,
       h.pid AS holding_pid,
       h.mode AS held_mode
FROM pg_locks AS w
JOIN pg_locks AS h
  ON h.granted
 AND h.pid IS DISTINCT FROM w.pid
 AND h.locktype = w.locktype
 AND h.database IS NOT DISTINCT FROM w.database
 AND h.relation IS NOT DISTINCT FROM w.relation
 AND h.page IS NOT DISTINCT FROM w.page
 AND h.tuple IS NOT DISTINCT FROM w.tuple
 AND h.virtualxid IS NOT DISTINCT FROM w.virtualxid
 AND h.transactionid IS NOT DISTINCT FROM w.transactionid
 AND h.classid IS NOT DISTINCT FROM w.classid
 AND h.objid IS NOT DISTINCT FROM w.objid
 AND h.objsubid IS NOT DISTINCT FROM w.objsubid
WHERE NOT w.granted
ORDER BY w.pid, h.pid;

-- name: RCA-PG-03
-- Database counters, cumulative (the runner diffs consecutive samples): deadlocks, recovery-conflict cancels, rollbacks,
-- temporary files, read time, and sessions that ended abnormally (PostgreSQL 14 and later). Primary and replica.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       d.xact_commit,
       d.xact_rollback,
       d.deadlocks,
       d.conflicts,
       d.temp_files,
       d.temp_bytes,
       d.blks_read,
       d.blks_hit,
       d.blk_read_time,
       d.blk_write_time,
       d.tup_inserted,
       d.tup_updated,
       d.tup_deleted,
       d.sessions,
       d.sessions_abandoned,
       d.sessions_fatal,
       d.sessions_killed,
       d.active_time,
       d.idle_in_transaction_time
FROM pg_stat_database AS d
WHERE d.datname = current_database();

-- name: RCA-PG-04
-- WAL generation on the primary, cumulative (diffed): how much the primary wrote, the replica's input. Its LSN diff
-- between two samples is the WAL rate the replica has to replay.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       pg_current_wal_lsn()::text AS current_lsn,
       w.wal_records,
       w.wal_fpi,
       w.wal_bytes,
       w.wal_buffers_full,
       w.stats_reset
FROM pg_stat_wal AS w;

-- name: RCA-PG-05
-- Replication seen from the primary: one row per standby. send_gap_bytes is WAL not yet sent; replay_gap_bytes is WAL
-- the standby has but hasn't applied. write_lag and flush_lag stay small while replay_lag grows when replay itself
-- is held up (a conflict, or a busy replica), not shipping. Details need pg_read_all_stats.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       r.pid,
       r.application_name,
       r.state,
       r.sync_state,
       r.sent_lsn::text AS sent_lsn,
       r.write_lsn::text AS write_lsn,
       r.flush_lsn::text AS flush_lsn,
       r.replay_lsn::text AS replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.sent_lsn) AS send_gap_bytes,
       pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn) AS replay_gap_bytes,
       round(EXTRACT(EPOCH FROM r.write_lag)::numeric, 3) AS write_lag_s,
       round(EXTRACT(EPOCH FROM r.flush_lag)::numeric, 3) AS flush_lag_s,
       round(EXTRACT(EPOCH FROM r.replay_lag)::numeric, 3) AS replay_lag_s,
       r.reply_time
FROM pg_stat_replication AS r
ORDER BY r.pid;

-- name: RCA-PG-06
-- Replay on the replica: received versus replayed WAL, and the time since the last replayed transaction, which Azure
-- Monitor's Read Replica Lag (physical_replication_delay_in_seconds) reports (ADR 0025).
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn()::text AS receive_lsn,
       pg_last_wal_replay_lsn()::text AS replay_lsn,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS received_not_replayed_bytes,
       round(EXTRACT(EPOCH FROM clock_timestamp() - pg_last_xact_replay_timestamp())::numeric, 1) AS since_last_replayed_xact_s,
       pg_get_wal_replay_pause_state() AS replay_pause_state;

-- name: RCA-PG-07
-- Queries the replica cancelled because they conflicted with replay, by cause, cumulative (diffed). A lock conflict
-- that ended before max_standby_streaming_delay cancels nothing, so it shows in RCA-PG-01 (the startup process
-- waiting on Lock) and RCA-PG-06, not here.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       c.confl_tablespace,
       c.confl_lock,
       c.confl_snapshot,
       c.confl_bufferpin,
       c.confl_deadlock,
       c.confl_active_logicalslot
FROM pg_stat_database_conflicts AS c
WHERE c.datname = current_database();

-- name: RCA-PG-08
-- The replica's WAL receiver: whether it streams, and when it last heard from the primary.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       r.status,
       r.flushed_lsn::text AS flushed_lsn,
       r.latest_end_lsn::text AS latest_end_lsn,
       r.last_msg_send_time,
       r.last_msg_receipt_time,
       r.latest_end_time
FROM pg_stat_wal_receiver AS r;

-- name: RCA-PG-09
-- The settings that decide how long replay waits for a conflicting query: on the replica, when replay detail starts.
SELECT /* dbhubdemo:rca-observer */ s.name, s.setting, s.unit
FROM pg_settings AS s
WHERE s.name IN ('max_standby_streaming_delay', 'max_standby_archive_delay', 'hot_standby_feedback',
                 'wal_receiver_status_interval', 'recovery_min_apply_delay', 'max_connections',
                 'idle_in_transaction_session_timeout', 'deadlock_timeout', 'lock_timeout', 'statement_timeout')
ORDER BY s.name;

-- name: RCA-PG-11
-- The tables a head blocker holds locks on. A transactionid wait (Lock:transactionid) names no table: the waiters wait
-- for the holder's transaction, and its row locks aren't in pg_locks (they're on disk). The holder's relation locks are,
-- so they name the tables its open transaction changed. $1 is the head blockers' pids from RCA-PG-01.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       l.pid,
       l.relation::regclass::text AS relation,
       l.mode
FROM pg_locks AS l
WHERE l.granted
  AND l.locktype = 'relation'
  AND l.pid = ANY ($1::integer[])
  AND l.database = (SELECT d.oid FROM pg_database AS d WHERE d.datname = current_database())
  AND l.mode IN ('RowExclusiveLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock', 'RowShareLock')
ORDER BY l.pid, relation;

-- name: RCA-PG-12
-- Scans per table in contosocare, cumulative (diffed between an episode's start and end): a table with many sequential
-- scans and a large seq_tup_read is read without an index. Read at the start and end of every CPU or IO episode on T4
-- (Phase 2). T4's Query Store (azure_sys) and autonomous tuning hold the statements and the index recommendations; this
-- is what contosocare itself shows the runner's role.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       t.relid::regclass::text AS relation,
       t.seq_scan,
       t.seq_tup_read,
       t.idx_scan,
       t.idx_tup_fetch,
       t.n_tup_ins,
       t.n_tup_upd,
       t.n_tup_del,
       t.n_dead_tup
FROM pg_stat_user_tables AS t
WHERE t.schemaname IN ('care', 'demo')
ORDER BY t.seq_tup_read DESC;

-- name: RCA-PG-10
-- The sentinel's connection picture, every 30 s (every 10 s while connections are at 80 % of max_connections or more):
-- client connections against max_connections and the reserved slots, by state, and the clients waiting on a lock (the
-- blocking trigger), in one row.
-- client_connections counts every client backend, the observer's own too: each takes one of max_connections' slots, and
-- once the free slots are down to the reserved ones, PostgreSQL accepts only roles with their privileges
-- (https://www.postgresql.org/docs/18/runtime-config-connection.html#GUC-SUPERUSER-RESERVED-CONNECTIONS). The counts by
-- state leave the observer out: its session is always running this query, which read as a client running one in every
-- sample (Final tests' live check of 4e2c65ed). So active, idle, and idle_in_transaction add up to at most one less than
-- client_connections, and waiting_lock is a part of active.
-- Refused attempts (SQLSTATE 53300) never reach the server's views, and in this demo's live check Azure Monitor's
-- connections_failed counted none of them (2026-11-21: 48 refused attempts, none counted), so nothing here counts them.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       current_setting('max_connections')::integer AS max_connections,
       current_setting('superuser_reserved_connections')::integer
         + COALESCE(NULLIF(current_setting('reserved_connections', true), '')::integer, 0) AS reserved_connections,
       count(*) FILTER (WHERE a.backend_type = 'client backend') AS client_connections,
       count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.pid <> pg_backend_pid() AND a.state = 'active') AS active,
       count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.pid <> pg_backend_pid() AND a.state = 'idle') AS idle,
       count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.pid <> pg_backend_pid() AND a.state LIKE 'idle in transaction%') AS idle_in_transaction,
       count(*) FILTER (WHERE a.backend_type = 'client backend' AND a.pid <> pg_backend_pid() AND a.wait_event_type = 'Lock') AS waiting_lock
FROM pg_stat_activity AS a;

-- name: RCA-PG-13
-- Query Store's settings (the sidecar), as a DBA checks them: whether it records top-level statements (top), nested ones
-- too (all), or nothing (none: Burstable, where Learn advises against it, or a server whose owner turned it off);
-- whether wait sampling records, and how often it samples; the interval, retention, and plan storage. At the observer's
-- start and with each RCA-PG-14 read, on T4 and its replica: none, or a missing setting, is a coverage gap that says
-- which; a change between reads is an RCA Query Events row; and a replica (in_recovery) records nothing in Query Store
-- (https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store, Read-only mode).
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       pg_is_in_recovery() AS in_recovery,
       s.name,
       s.setting,
       s.unit
FROM pg_settings AS s
WHERE s.name IN ('pg_qs.query_capture_mode', 'pgms_wait_sampling.query_capture_mode', 'pgms_wait_sampling.history_period',
                 'pg_qs.interval_length_minutes', 'pg_qs.retention_period_in_days', 'pg_qs.store_query_plans',
                 'pg_qs.max_query_text_length', 'pg_qs.max_captured_queries')
ORDER BY s.name;

-- name: RCA-PG-14
-- Query Store's top queries per interval on T4 (the sidecar): for each interval persisted after $2, the queries among
-- its top 10 by total time, top 5 by shared blocks hit and read, and top 5 by sampled waits; one row per interval, role,
-- query, and plan, with the workload's own role named and every other role's rows summed under none. Read every 15
-- minutes, 2 minutes after an interval ends, for the intervals persisted since the previous read; at the observer's
-- start for the 2 hours before it; and at its end. An interval shows only once it ends, so the observer keeps a
-- watermark of the time still pending and reads it later for the same session (rca/README.md, Pending publication).
-- Connected to azure_sys, whose query_store views the public role reads. Parameters: $1 text, the database
-- (contosocare); $2 timestamptz, the end of the last interval read; $3 text[], the harness's functions; $4 text[], the
-- tables only the harness writes; $5 text[], every other table; $3 to $5 from RCA-PG-16, never from the answer key.
-- Left out, by two fixed rules and nothing else (rca/README.md, What the capture leaves out): the capture's own
-- statements, whose connections' search_path names dbhubdemo_rca_observer (qs_view records it per row) and whose text
-- carries the marker; and the harness's: a call of one of its functions, or a statement that references a table only
-- the harness writes and no other table, since Query Store records a statement nested in a function without its
-- function (pg_qs.query_capture_mode all). Everything else is measured evidence.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       r.start_time AT TIME ZONE 'UTC' AS interval_start_utc,
       r.end_time AT TIME ZONE 'UTC' AS interval_end_utc,
       r.login_name,
       r.query_id,
       r.plan_id,
       r.query_sql_text,
       r.calls AS executions,
       r.total_time AS duration_ms,
       r.max_time AS max_duration_ms,
       r.blocks AS logical_reads,
       r.blocks_read AS physical_reads,
       r.row_total AS row_count,
       r.temp_blocks_written * 8 AS tempdb_kb,
       r.wait_samples
FROM (SELECT s.start_time,
             s.end_time,
             s.login_name,
             s.query_id,
             s.plan_id,
             s.query_sql_text,
             s.calls,
             s.total_time,
             s.max_time,
             s.blocks,
             s.blocks_read,
             s.row_total,
             s.temp_blocks_written,
             COALESCE(w.samples, 0) AS wait_samples,
             row_number() OVER (PARTITION BY s.start_time ORDER BY s.total_time DESC) AS time_rank,
             row_number() OVER (PARTITION BY s.start_time ORDER BY s.blocks DESC) AS blocks_rank,
             row_number() OVER (PARTITION BY s.start_time ORDER BY COALESCE(w.samples, 0) DESC) AS wait_rank
      FROM (SELECT g.start_time,
                   g.end_time,
                   g.login_name,
                   g.query_id,
                   g.plan_id,
                   min(g.query_sql_text) AS query_sql_text,
                   sum(g.calls) AS calls,
                   sum(g.total_time) AS total_time,
                   max(g.max_time) AS max_time,
                   sum(g.shared_blks_hit + g.shared_blks_read) AS blocks,
                   sum(g.shared_blks_read) AS blocks_read,
                   sum(g.rows) AS row_total,
                   sum(g.temp_blks_written) AS temp_blocks_written
            FROM (SELECT q.start_time,
                         q.end_time,
                         CASE WHEN q.user_id = (SELECT a.oid FROM pg_roles AS a WHERE a.rolname = current_user) THEN current_user::text END AS login_name,
                         q.query_id,
                         q.plan_id,
                         q.query_sql_text,
                         q.calls,
                         q.total_time,
                         q.max_time,
                         q.shared_blks_hit,
                         q.shared_blks_read,
                         q.rows,
                         q.temp_blks_written
                  FROM query_store.qs_view AS q
                  WHERE q.db_id = (SELECT d.oid FROM pg_database AS d WHERE d.datname = $1)
                    AND q.end_time > ($2::timestamptz AT TIME ZONE 'UTC')
                    AND COALESCE(q.search_path, '') NOT LIKE '%dbhubdemo_rca_observer%'
                    AND q.query_sql_text NOT LIKE '%dbhubdemo:rca-observer%'
                    AND NOT (cardinality($3::text[]) > 0 AND q.query_sql_text ~* ('\m(' || array_to_string($3::text[], '|') || ')\s*\('))
                    AND NOT (cardinality($4::text[]) > 0
                             AND q.query_sql_text ~* ('\m(' || array_to_string($4::text[], '|') || ')\M')
                             AND NOT (cardinality($5::text[]) > 0 AND q.query_sql_text ~* ('\m(' || array_to_string($5::text[], '|') || ')\M')))) AS g
            GROUP BY g.start_time, g.end_time, g.login_name, g.query_id, g.plan_id) AS s
      LEFT JOIN (SELECT v.start_time, v.login_name, v.query_id, sum(v.calls) AS samples
                 FROM (SELECT ws.start_time,
                              CASE WHEN ws.user_id = (SELECT a.oid FROM pg_roles AS a WHERE a.rolname = current_user) THEN current_user::text END AS login_name,
                              ws.query_id,
                              ws.calls
                       FROM query_store.pgms_wait_sampling_view AS ws
                       WHERE ws.db_id = (SELECT d.oid FROM pg_database AS d WHERE d.datname = $1)
                         AND ws.end_time > ($2::timestamptz AT TIME ZONE 'UTC')) AS v
                 GROUP BY v.start_time, v.login_name, v.query_id) AS w
        ON w.start_time = s.start_time AND w.query_id = s.query_id AND w.login_name IS NOT DISTINCT FROM s.login_name) AS r
WHERE r.time_rank <= 10 OR r.blocks_rank <= 5 OR (r.wait_rank <= 5 AND r.wait_samples > 0)
ORDER BY r.start_time, r.total_time DESC
LIMIT 600;

-- name: RCA-PG-15
-- Query Store's sampled waits for the queries RCA-PG-14 returned (the sidecar): each role's query's three most sampled
-- waits in each interval, by event type and event. A sample is the query found waiting once, every
-- pgms_wait_sampling.history_period (RCA-PG-13), so samples times the period estimates the time waited. Read with
-- RCA-PG-14, connected to azure_sys. Parameters: $1 text, the database; $2 timestamptz, as RCA-PG-14's; $3 bigint[],
-- RCA-PG-14's query_ids.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       r.start_time AT TIME ZONE 'UTC' AS interval_start_utc,
       r.end_time AT TIME ZONE 'UTC' AS interval_end_utc,
       r.login_name,
       r.query_id,
       0::bigint AS plan_id,
       r.event_type AS wait_category,
       r.event AS wait_event,
       r.samples
FROM (SELECT g.start_time,
             g.end_time,
             g.login_name,
             g.query_id,
             g.event_type,
             g.event,
             sum(g.calls) AS samples,
             row_number() OVER (PARTITION BY g.start_time, g.login_name, g.query_id ORDER BY sum(g.calls) DESC) AS wait_rank
      FROM (SELECT ws.start_time,
                   ws.end_time,
                   CASE WHEN ws.user_id = (SELECT a.oid FROM pg_roles AS a WHERE a.rolname = current_user) THEN current_user::text END AS login_name,
                   ws.query_id,
                   ws.event_type,
                   ws.event,
                   ws.calls
            FROM query_store.pgms_wait_sampling_view AS ws
            WHERE ws.db_id = (SELECT d.oid FROM pg_database AS d WHERE d.datname = $1)
              AND ws.end_time > ($2::timestamptz AT TIME ZONE 'UTC')
              AND ws.query_id = ANY ($3::bigint[])) AS g
      GROUP BY g.start_time, g.end_time, g.login_name, g.query_id, g.event_type, g.event) AS r
WHERE r.wait_rank <= 3
ORDER BY r.start_time, r.query_id, r.samples DESC;

-- name: RCA-PG-16
-- The harness, for RCA-PG-14's leave-out (the sidecar): the functions the demo marks as its harness (COMMENT ON FUNCTION
-- ... IS 'dbhubdemo:harness', which database/postgresql sets on its own control functions), and every user table, as
-- harness_table when only marked functions write it and as table otherwise (the workload's scratch tables among them).
-- A function writes a table when its source inserts into, updates, deletes from, truncates, or merges into it. Once, at
-- the observer's start, in contosocare, on T4. It reads the database's own catalog and nothing the workload plans.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       x.kind,
       x.name
FROM (SELECT 'function' AS kind, p.proname::text AS name
      FROM pg_proc AS p
      WHERE obj_description(p.oid, 'pg_proc') = 'dbhubdemo:harness'
      UNION ALL
      SELECT CASE WHEN t.by_harness AND NOT t.by_other THEN 'harness_table' ELSE 'table' END AS kind, t.relname AS name
      FROM (SELECT c.relname::text AS relname,
                   COALESCE(bool_or(f.harness AND f.prosrc ~* ('(insert\s+into|update|delete\s+from|truncate(\s+table)?|merge\s+into)\s+(\w+[.])?' || c.relname || '\M')), false) AS by_harness,
                   COALESCE(bool_or(NOT f.harness AND f.prosrc ~* ('(insert\s+into|update|delete\s+from|truncate(\s+table)?|merge\s+into)\s+(\w+[.])?' || c.relname || '\M')), false) AS by_other
            FROM pg_class AS c
            JOIN pg_namespace AS n ON n.oid = c.relnamespace
            LEFT JOIN (SELECT p.prosrc, COALESCE(obj_description(p.oid, 'pg_proc') = 'dbhubdemo:harness', false) AS harness
                       FROM pg_proc AS p
                       JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
                       WHERE pn.nspname NOT IN ('pg_catalog', 'information_schema')
                         AND pn.nspname NOT LIKE 'pg\_%') AS f ON true
            WHERE c.relkind IN ('r', 'p')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg\_%'
            GROUP BY c.relname) AS t) AS x
ORDER BY x.kind, x.name;

-- name: RCA-PG-17
-- Who holds T4's client connections (the sidecar): client backends grouped by application, role, and state, counted,
-- the idle ones included, with how many wait on a lock, how long the group's longest-standing one has been in its
-- state, and how long its oldest has been connected. Every database's, since each connection takes one of
-- max_connections' slots. Every 10 s while connections are at 80 % of max_connections or more (RCA-PG-10's connection
-- detail), and once when that ends. The observer's own connection is left out, and the observer reduces application
-- names as rca/README.md, Names, says: another application's name and role never reach the evidence.
SELECT /* dbhubdemo:rca-observer */ clock_timestamp() AS captured_at,
       a.application_name,
       a.usename,
       COALESCE(a.state, 'unknown') AS state,
       count(*) AS connections,
       count(*) FILTER (WHERE a.wait_event_type = 'Lock') AS waiting_lock,
       round(max(EXTRACT(EPOCH FROM clock_timestamp() - a.state_change))::numeric, 1) AS oldest_state_s,
       round(max(EXTRACT(EPOCH FROM clock_timestamp() - a.backend_start))::numeric, 1) AS oldest_connection_s
FROM pg_stat_activity AS a
WHERE a.backend_type = 'client backend'
  AND a.pid <> pg_backend_pid()
GROUP BY a.application_name, a.usename, COALESCE(a.state, 'unknown')
ORDER BY connections DESC, a.application_name;
