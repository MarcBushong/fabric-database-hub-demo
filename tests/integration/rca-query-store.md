# Unit 2's live probes: Query Store's evidence (ADR 0031's amendment of 2026-11-23)

For the live proof of the Incident RCA's Query Store sidecar. The rehearsal, then the final proof, run these against a session's window.

- They're the live proof's steps S7, S10, and S11, for [ADR 0031's amendment](../../docs/adr/0031-incident-rca.md#amendment-2026-11-23-query-stores-evidence-in-a-sidecar).
- [rca/README.md](../../rca/README.md#the-sidecar) is the contract they check.
- They run only with the owner's go-ahead, through the Final tests session's read paths.

**The rules:**

- Every probe only reads, except S10's scratch module, which it removes.
- A probe may know the workload's modules. It's a test, never the RCA, and nothing it reads reaches the history or Copilot.
- The report is counts and pass or fail only, never statement text. IDs are compared in memory.
- Times are UTC.

**The window** is the session's: its start to its end, rounded out to Query Store's 15-minute intervals.

## Blindness, by IDs (S7)

Query Store's own query IDs, sorted by who ran them, are compared with the IDs the history retained. The exported text can't show a marker, because the normalizer strips comments, and `search_path` isn't exported. So IDs from raw metadata are the proof.

### SQL Server: T1, T2's guest, and T3, in `ContosoCare`

```sql
DECLARE @from datetimeoffset = '<window start>', @to datetimeoffset = '<window end>';
WITH ran AS (
    SELECT DISTINCT p.query_id
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
    WHERE i.start_time >= @from AND i.start_time < @to
),
sorted AS (
    SELECT r.query_id,
           category = CASE
               WHEN t.query_sql_text LIKE N'%dbhubdemo:rca-observer%' THEN 'observer'
               WHEN EXISTS (SELECT 1 FROM sys.extended_properties AS ep
                            WHERE ep.class = 1 AND ep.major_id = q.object_id AND ep.minor_id = 0
                              AND ep.name = N'dbhubdemo.role' AND CAST(ep.value AS nvarchar(100)) = N'harness') THEN 'harness'
               WHEN q.object_id IN (SELECT OBJECT_ID(w.procedure_name) FROM demo.fn_workload_procedures() AS w) THEN 'workload'
               ELSE 'other' END
    FROM ran AS r
    JOIN sys.query_store_query AS q ON q.query_id = r.query_id
    JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id
)
SELECT category, n = COUNT(*), query_ids = STRING_AGG(CAST(query_id AS varchar(20)), ',') WITHIN GROUP (ORDER BY query_id)
FROM sorted
GROUP BY category;
```

The probe's own text carries the marker, so it counts itself as `observer`. That's harmless: it ran outside the capture.

### PostgreSQL: T4

1. **In `ContosoCare`, the harness's routines** (H's marks):

   ```sql
   SELECT p.proname
   FROM pg_catalog.pg_proc AS p
   JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
   WHERE obj_description(p.oid, 'pg_proc') = 'dbhubdemo:harness';
   ```

2. **In `azure_sys`,** with those names as `<harness routines>`, joined by `|`:

   ```sql
   WITH ran AS (
       SELECT DISTINCT v.query_id, v.search_path, v.query_sql_text
       FROM query_store.qs_view AS v
       WHERE v.start_time >= '<window start>' AND v.start_time < '<window end>'
   )
   SELECT CASE
              WHEN search_path LIKE '%dbhubdemo_rca_observer%' THEN 'observer'
              WHEN query_sql_text ~* '(pg_stat_activity|pg_locks|pg_stat_database|pg_stat_replication|query_store\.)' THEN 'observer-catalog'
              WHEN query_sql_text ~* 'demo\.(<harness routines>)\s*\(' THEN 'harness-call'
              WHEN query_sql_text ~* 'demo\.scenario_(runs|run_events|control)\M' AND query_sql_text !~* '\mcare\.' THEN 'harness-table'
              WHEN query_sql_text ~* '\mcare\.' THEN 'workload'
              ELSE 'other'
          END AS category,
          count(DISTINCT query_id) AS n,
          string_agg(DISTINCT query_id::text, ',') AS query_ids
   FROM ran
   GROUP BY 1;
   ```

The `observer-catalog` heuristic covers Phase 1's statements, which ran without the marker. It's a cross-check, independent of the capture's catalog-text rule.

### The history, through `Invoke-DemoDaxQuery`

```dax
EVALUATE
CALCULATETABLE(
    SUMMARIZE('RCA Query Stats', 'RCA Query Stats'[Target Key], 'RCA Query Stats'[Query ID]),
    'RCA Query Stats'[Interval Start UTC] >= <window start>,
    'RCA Query Stats'[Interval Start UTC] < <window end>
)
```

**Pass, per target:**

- **Nothing left out leaks in:** no `observer`, `observer-catalog`, `harness`, `harness-call`, or `harness-table` ID is retained.
- **The workload is kept:** each `workload` ID in the incident's top lists is retained, which the positive controls below check.
- **The log-rate scenario's writes stay:** writes to `demo`'s scratch tables (`billing.usp_import_remittances`, by the names) are retained on the targets it ran on. That's review High 1's case.
- **Each set is exercised:** every category is non-empty, or reported as "not exercised" with the reason. For example, Query Store's AUTO capture on SQL Server may not record the observer's cheap statements.

## Totals (S7): execution-weighted, against the source

For T3's regression query (the query with an AUTO forcing in the window), and T1's top query by CPU in its incident.

### SQL Server: closed intervals only

```sql
DECLARE @query bigint = <query_id>, @from datetimeoffset = '<window start>', @to datetimeoffset = '<window end>';
SELECT interval_start = i.start_time, rs.plan_id,
       executions    = SUM(rs.count_executions),
       cpu_ms        = SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0,
       duration_ms   = SUM(rs.avg_duration * rs.count_executions) / 1000.0,
       logical_reads = SUM(rs.avg_logical_io_reads * rs.count_executions)
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_runtime_stats_interval AS i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
WHERE p.query_id = @query AND i.start_time >= @from AND i.start_time < @to AND i.end_time <= SYSUTCDATETIME()
GROUP BY i.start_time, rs.plan_id
ORDER BY interval_start, rs.plan_id;
```

### The history: the model's measures, which take the latest read

```dax
EVALUATE
SUMMARIZECOLUMNS(
    'RCA Query Stats'[Interval Start UTC], 'RCA Query Stats'[Plan ID],
    TREATAS({ <query_id> }, 'RCA Query Stats'[Query ID]),
    TREATAS({ "<target>" }, 'RCA Query Stats'[Target Key]),
    "Executions", [Query Executions], "CPU", [Query CPU (ms)], "Duration", [Query Duration (ms)],
    "Reads", COUNTROWS('RCA Query Stats')
)
```

**Pass:**

- each closed interval and plan agrees: executions exactly, and milliseconds to within 0.01;
- an interval read open, then closed, has `Reads` of 2 or more, while its measures equal the closed read. The replay went through the notebook and DAX.

**T4:** `SUM(calls)` and `SUM(total_time)` from `query_store.qs_view`, per window, user, and query, against `Executions` and `Duration (ms)` in the same way.

## Waits (S7)

`RCA Query Waits`, always read at its latest read, as the contract says: the table has no measure, so its raw rows hold every read.

- **T2's blocking chain:** the blocked queries' intervals have the `Lock` category.
- **T4's lock waits:** `Lock:transactionid` or `Lock:tuple` events.

## The A1 review's live checks (S10)

1. **The reads' cost:** each Query Store read's duration, CPU, and logical reads, from the runner's log on T1, T2's guest, and T3. The first read covers 2 hours.
2. **RCA-SQL-14:** the showplan XML's size and the read's time.
3. **The marker:** the observer's statements carry `dbhubdemo:rca-observer` in Query Store's text. That's the blindness probe's `observer` set, non-empty on at least one target.
4. **The open interval:** the session's final read has rows for the open interval, and the next read's closed totals for it are at least as large.
5. **RCA-AZ-04's JSON:** one `details` value from T3, its keys kept and its values replaced by their types, against what the reader parses.
6. **`OBJECT_NAME` under the 1-second lock timeout:**
   - create a scratch procedure, `dbo.zz_rca_probe`, on T1, and run it until Query Store has it;
   - in another session, `BEGIN TRANSACTION`, then `ALTER PROCEDURE dbo.zz_rca_probe` (holding its schema lock) while the observer reads;
   - then `ROLLBACK`, and drop the procedure.

   **Pass:** the read returns within its timeout, with the name null or a gap. If AUTO capture never records the scratch procedure, the check isn't exercised, and the report says so.
7. **The harness rule:** the blindness probe's `harness` set, after H's marks.

## T4's live checks (S11)

1. **The `search_path`:** L0c's result, and the catalog-text rule. No `observer-catalog` ID is retained in the first read after the update.
2. **Waits against statistics:** whether a window shows in `pgms_wait_sampling_view` later than in `qs_view`, from when each first lists it.
3. **RCA-PG-14 and 15's latency** while T4's CPU is under pressure, from the runner's log.
4. **UTC:** A2's first-read log line: `now() AT TIME ZONE 'UTC'`, `TimeZone`, and the newest `end_time`. Windows end on the quarter hour, in UTC.
5. **The public role:** A2's connection line names the runner's role and `azure_sys`, with no grant beyond `public`'s.
6. **A NULL `event_type`:** how often it appears, and the waits around it.
7. **RCA-PG-16:** the routines it lists match H's 13; the harness tables are exactly `demo.scenario_control`, `demo.scenario_runs`, and `demo.scenario_run_events`; and there's **no `unsure` row** (`dynamic_sql`, `no_source`).
