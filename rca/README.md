# The Incident RCA evidence contract

What the runner's observer captures, how it reaches the history, and what the Insights app reads, for [ADR 0031](../docs/adr/0031-incident-rca.md). Three parts of Phase 1 build against it at once: the capture (the runner), the transport and history (the control's runbook, the scripts, the notebooks, the semantic model), and the app. The sidecar (since 2026-11-23, [below](#the-sidecar)) adds Query Store's evidence and T4's connection holders beside the evidence document, which stays as it was. Nothing here may change without a new version (below).

| File | What it is | Who reads it |
|---|---|---|
| [evidence.schema.json](evidence.schema.json) | JSON Schema (2020-12) of an evidence document, version 1, generated from history-tables.json | The runner's export tests, the notebook's tests, this contract's tests |
| [sidecar.schema.json](sidecar.schema.json) | JSON Schema (2020-12) of a sidecar document, version 1, generated from history-tables.json | The same, for the sidecar |
| [transport.schema.json](transport.schema.json) | JSON Schema of a bundle, the bundle index, and the `RCA_EVIDENCE` parameter; the part line's pattern; and the sidecar's own kinds: its index, part line, `RCA_SIDECAR_FILE` document, and the notebook's acknowledgement | The runbook's, the scripts', and the notebook's tests |
| [history-tables.json](history-tables.json) | The fourteen lakehouse tables: the evidence document's eight (seven for detection, one answer key) and the sidecar's six; columns, types, keys, model names, relationships, measures | The notebook, the model, and the app, and their tests |
| [blind-detection.json](blind-detection.json) | What detection may read, what is the answer key, and what detection code must never name | The app's and the runner's tests |
| [capture/](capture/README.md) | The capture query catalog (RCA-SQL, RCA-AZ, RCA-XE, RCA-PG), with each block's trigger, permission, and Learn page | The runner, which embeds the two .sql files |
| [fixtures/](fixtures/README.md) | Two evidence documents (T1's blocking chain, T4's chain and its replica's lag), their parts, a bundle, a bundle index, and an `RCA_EVIDENCE` value | Every component's tests |

`tests/unit/Rca.Contract.Tests.ps1` checks that the schemas, the tables, the fixtures, and the capture catalog agree.

## The flow

1. **Capture, on the VMs.** The observer lane of `ContosoCare.Workload profile run` (on T1 for T1, T3, T4, T4's replica; in T2's guest for T2) runs the sentinel every 30 s for the whole session, escalates to detail capture when a signal crosses its threshold ([below](#capture-triggers)), and keeps what it captures in `C:\ProgramData\DbHubDemo\rca\<session>\` (SYSTEM and Administrators only, at most 20 MB per target). It deletes what it captured at its first export or capture on that VM at least 7 days after the export that took all of it, or, when no export took any of it, 30 days after the capture started (`EvidenceStore.Cleanup`, from both); with no later export or capture there, it stays until `destroy.ps1` deletes the VMs. A T2 golden snapshot carries none of it: its capture stops T2's runner and deletes the store in the guest first.
2. **Export.** At the session's end (and at each 30-minute re-check), `ContosoCare.Workload rca export` reduces the capture into evidence documents and prints them as part lines ([transport](#transport)).
3. **Into the control vault.** The control's runbook runs the export through managed Run Commands, one part per command, writes the parts as earlier versions of the control vault's existing `dbhub-session-metrics` secret (bundles), and lists those versions in the `rca` member of the secret's final version, the metrics document the control notebook already reads.
4. **Into the history.** The control notebook reads the bundles, stages every part in the lakehouse as one `RCA_EVIDENCE` document, and passes its path to `NB_DatabaseHub_LiveActivity` as `RCA_EVIDENCE_FILE`; the notebook decodes the documents and writes the eight tables. `stop-demo.ps1 -SaveHistory` and `deploy.ps1`'s history snapshot run the same export with the operator's role and stage the same file ([`RCA_EVIDENCE_FILE`](#rca_evidence_file)).
5. **Read.** `SM_DatabaseHub_History` reads the tables (Direct Lake); the app's rules, investigation tools, RCA view, and chat read the seven detection tables through it, never the answer key.
6. **The sidecar, beside it.** Query Store's evidence on T1 to T4 and T4's connection holders travel in sidecar documents with their own commands, part lines, and notebook parameter, which a piece that knows only the evidence document never meets. The notebook acknowledges them by document ID, and the runner keeps a sidecar until it's acknowledged ([the sidecar](#the-sidecar)). The scripts' path (`stop-demo.ps1 -SaveHistory` and `deploy.ps1`'s snapshot) carries them first; Run all's path follows in a later release.

## Blind detection

The product is blind: the rules, the investigation tools, the RCA view, and the chat use only what a real DBA's tools would show: the observer's capture, Azure Monitor's metrics, and Database Hub's telemetry. Grading against what the workload injected exists for the tests and the evaluation set, and for the scoreboard's "Did we catch it?" trust moment, and nowhere else ([ADR 0031](../docs/adr/0031-incident-rca.md)).

- **The capture is blind:** the observer never reads the workload's plan, the scenario catalog, `demo.scenario_runs`, or `demo.scenario_run_events`, and its cadence follows what it sees, not what's scheduled. It records names only as [Names](#names) says, and leaves out only its own statements and the harness's, by fixed rules that never read the answer key ([what the capture leaves out](#what-the-capture-leaves-out)).
- **The answer key is separate:** the runner adds its own runs and their events to each document's `answerKey` section, with its own string dictionary. The notebook writes them only to `rca_answer_key`. No detection table carries a scenario name, a run ID, or a workload-reported event.
- **Enforced:** [blind-detection.json](blind-detection.json) lists the model tables and telemetry analyses detection may read, the answer key's tables, and the identifiers detection code must never contain (every scenario ID among them). The app's and the runner's tests fail when detection code names one; the dock's `run_dax` refuses DAX that names an answer-key table.

## Capture triggers

The sentinel runs on every target every 30 s for the whole session. A signal over its threshold starts an **episode** of detail capture; the episode ends when the signal stays below for the stated time. Each start and end is an `rca_events` row of kind `capture` (`event_name` `escalated` or `relaxed`, `code` the episode's ID `<target>-<yyyyMMddTHHmmssZ>`, `detail` the signal and its value).

| Signal (sentinel) | Starts an episode when | Detail capture | Ends after | Phase |
|---|---|---|---|---|
| `processes_blocked` (RCA-SQL-09; T1, T2, T3) | above 0 | RCA-SQL-01 and RCA-SQL-02 every 10 s | 60 s without a blocked process | 1 |
| `connections_waiting_lock` (RCA-PG-10; T4) | above 0 | RCA-PG-01, RCA-PG-02, and RCA-PG-11 every 10 s | 60 s without a waiter | 1 |
| Replay stalled (RCA-PG-06; the replica) | `since_last_replayed_s` at 30 s or more **and** `received_not_replayed_bytes` above 0 (an idle primary alone doesn't count) | RCA-PG-01, 02, 06, 07 every 5 s on the replica, RCA-PG-04 and 05 on T4, RCA-PG-09 once | `since_last_replayed_s` below 5 s for 3 samples | 1 |
| Connections near the limit (RCA-PG-10; T4) | `client_connections` at 80 % of `max_connections` minus the reserved slots | RCA-PG-10 every 10 s | 60 s below 70 % | 1 |
| Deadlocks, errors, attentions, escalations (RCA-XE-02 and 04; T1, T2, T3) | always recorded as they happen; an episode when errors in a minute reach 10 and 3 times the median of the 10 minutes before | one RCA-SQL-01 sample at the start; RCA-SQL-12 when a deadlock count rose with no graph | 5 minutes under the threshold | 1 |
| Deadlocks (RCA-PG-03; T4) | `deadlocks` rose | one RCA-PG-01 and RCA-PG-02 sample | at once | 1 |
| A wait category's rate (RCA-SQL-04, RCA-AZ-02) | at 3 times its median over the 15 minutes before, and at least 200 ms/s | RCA-SQL-03 every 15 s, RCA-SQL-08, then RCA-SQL-13 at its end | 2 minutes under 1.5 times the median | 2 |
| CPU (RCA-AZ-01 on T3; runnable tasks, RCA-SQL-07, on T1 and T2) | at 80 % or more, or runnable tasks at 1 per scheduler, for 2 samples | RCA-SQL-07 every 15 s | 2 minutes below | 2 |

T5 has no sentinel in the observer: its 429s and normalized RU are Azure Monitor metrics that the history saves already, which detection reads from Telemetry Snapshots. Query Store isn't an episode's capture: the sidecar reads it on its own cadence, whatever the sentinel sees ([Query Store](#query-store)).

**What a sample holds:** the columns of the queries that ran at that moment.

- **The replica's sentinel** reads RCA-PG-06, 07, and 08 every 30 s: `since_last_replayed_s`, `received_not_replayed_bytes`, and `conflicts_cancelled`. RCA-PG-08's receiver status only adds coverage gaps. Replay detail adds RCA-PG-01 and 02: `startup_wait` and the conflict's columns, on a sample that found the startup process waiting on a lock. RCA-PG-09 runs once when an episode starts, and its `max_standby_streaming_delay_s` stays on later samples.
- **T4's sentinel** also reads the primary's side (RCA-PG-04 and 05) every 30 s while T4 has a standby, and every 5 s during a replay episode.
- **Rates and deltas** between samples (`wal_bytes_per_s`, `conflicts_cancelled`) are null on a target's first sample, which has nothing before it.
- **A blocking sample** is a capture time with at least one waiting session. RCA-SQL-01, and RCA-PG-01 and 02, return only the sessions in a blocking edge (the waiters and those they wait on), so a chain's samples stop while nothing waits, and a formation ends where its samples stop for more than 1.5 sample intervals.
- **An escalation's login and host:** RCA-XE-01's `lock_escalation` event has no username or hostname action, so the observer takes them from the same session's blocking sample in the episode (the same session ID and run token), else leaves them null.
- **`rca_coverage.sources`** names every capture query that returned rows for the target in the window, sentinel and detail alike.

## Names

What the observer records about who ran a session, so the evidence names nothing the workload planned:

- **`program_name`:** a workload session's application name today is `ContosoCare.Demo/<scenario>/<run>`. The observer keeps only `ContosoCare.Demo`, and keeps any other session's name out entirely (it isn't the workload's). If the workload later uses per-service names ([ADR 0031, Names](../docs/adr/0031-incident-rca.md)), the observer keeps the service name and drops only the run segment. A scenario ID never reaches the evidence.
- **`run_token`:** the first 12 lowercase hex characters of SHA-256 over the UTF-8 bytes of `ContosoCare.RcaRunToken:<run>`, where `<run>` is the run segment. It groups one run's sessions and names nothing; the answer key carries the same token next to the run ID, so grading can check that a blind finding names the injected run's sessions.
- **`is_demo`:** true for the workload's own sessions, the baseline's and every fault's alike. It decides only whether text, login, and host are kept; rules never use it to tell a fault from the baseline.
- **Modules and statements** are what the DMVs return (a DBA sees them too). Rules never branch on a name; the blind-detection test checks that detection code contains no procedure-name pattern.
- **One helper:** in the runner, only `Rca/Observer/ApplicationNames.cs` may know the workload's application-name prefix ([blind-detection.json](blind-detection.json)).

## What the capture leaves out

Query Store records every statement a database runs, the capture's and the harness's among them. The capture leaves out exactly two kinds, by fixed rules in the demo's own code, and nothing else. It never reads [blind-detection.json](blind-detection.json) or any answer-key list, at build or run time, and never leaves out by schema: the scenario modules write the `demo` schema's scratch tables, and those writes are the measured workload.

1. **The capture's own statements.**
   - **SQL Server and Azure SQL Database:** every catalog statement carries the marker `/* dbhubdemo:rca-observer */` inside its text, which Query Store keeps ("Comments and spaces inside text aren't ignored", [sys.query_store_query_text](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-query-text-transact-sql)). RCA-SQL-10 and 14 leave out texts that carry it.
   - **PostgreSQL:** Query Store keeps one text per `query_id`, the first it saw, and `query_id` ignores comments, so a marker in the text isn't enough: T4 recorded the observer's statements before they carried one. So RCA-PG-14 has two rules:
     - **the `search_path`:** the observer's T4 connections set `search_path` to `"$user", public, dbhubdemo_rca_observer`, a schema that doesn't exist, so names resolve as before. `query_store.qs_view` records `search_path` per row, and RCA-PG-14 leaves out the rows that name it, and the texts that carry the marker;
     - **the catalog's own texts:** it also leaves out a row whose text equals one of the catalog's own PostgreSQL statements, today's or edd01c86's, once comments are stripped and white space is collapsed on both sides, prefix-matched where Query Store truncated the text (`pg_qs.max_query_text_length`). This covers the windows where an earlier runner's statements ran without the marker, which the first read after an update reaches. It also covers a `search_path` that Query Store kept from a query's first capture, which the live check L0c measures.
2. **The harness's bookkeeping and control modules,** which the demo marks where it defines them, so a rename carries the mark:
   - **SQL Server:** the extended property `dbhubdemo.role` = `harness` on every module `database/common/110-demo-control.sql` creates. RCA-SQL-10 and 14 leave out every statement whose `object_id` carries it.
   - **PostgreSQL:** `COMMENT ON FUNCTION ... IS 'dbhubdemo:harness'` on its control functions. Query Store records a statement nested in a function without its function (`pg_qs.query_capture_mode` `all`), so RCA-PG-16 reads, at the observer's start, the marked functions and the tables only marked functions write; RCA-PG-14 leaves out a call of a marked function, and a statement whose tables are all ones only the harness writes. A scenario function's own read of a run table is then left out too: it's bookkeeping.

Everything else is measured evidence, normalized as RCA Sessions' text is: the scenario modules' reads and writes, other applications' statements, and monitoring queries (Database Hub's among them). Modules keep their database names ([Names](#names)).

## The evidence document

One JSON document per host and export, UTF-8, no byte order mark. The schema says what it can; these rules complete it:

| Field | Rule |
|---|---|
| `kind`, `version` | `ContosoCare.RcaEvidence`, 1 |
| `documentId` | `<windowStartUtc as yyyyMMddTHHmmssZ>-<host>-<sequence, 4 digits>`, for example `20261120T165000Z-sqlvm01-0001`. Unique; the notebook writes a document once |
| `sessionId` | The control's session ID (32 lowercase hex, the resource group's `DbHubSessionId`), or null outside a control session |
| `producer` | `ContosoCare.Workload`, its version, the host (`sqlvm01` or `arcsql01`), lane `observer` |
| `windowStartUtc`, `windowEndUtc` | The slice of capture this document holds, start inclusive, end exclusive. One host's documents never overlap for a target: each export starts where the previous one ended. Like `epochUtc`, ISO 8601 UTC with milliseconds: `2026-11-20T16:50:00.000Z` |
| `sequence`, `final` | The export's number for the host and session, from 1; `final` on the session's last |
| `targets` | The targets covered; each has an `rca_coverage` row |
| `epochUtc` | The base of every time in the document |
| `strings` | The detection tables' string dictionary |
| `tables` | The detection tables present, by lakehouse name. A table with no rows is left out; `rca_coverage` never is |
| `answerKey` | `strings` (its own dictionary) and `tables.rca_answer_key` |

**A table** is `{ "rows": n, "columns": { "<column>": [ ... n values ... ] } }`:

- Every column array has exactly `rows` values, in row order. A column whose values are all null may be left out, unless it's required ([history-tables.json](history-tables.json) `required`); a required column has no nulls.
- **string:** an index into the section's `strings` (0 to its length minus 1), or null.
- **timestamp:** integer milliseconds after `epochUtc` (negative before it), or null. Times are UTC.
- **long, integer:** an integer (integer is 32-bit), or null. **double:** a number, or null. **boolean:** true, false, or null.
- Only the table's columns in [history-tables.json](history-tables.json); the notebook adds its `notebookColumns` (`run_id`, `document_id`, `report_date_utc`).
- Text is normalized before it's stored (string, number, date, binary, and GUID literals become `?`; IPv4 and IPv6 addresses `<ip>`; at most 2,000 characters for statements, 1,000 for details), passes the runner's redaction, and a value that still looks like a secret is dropped.
- **Limits:** at most 20,000 rows per table and 20,000 strings of at most 4,000 characters each.

### Resource metrics

`rca_resource` is long format. Gauges are readings; deltas are counts over the interval since the previous sample of the same metric, ending at `at_utc`.

| Source | Metric | Unit | Kind | Phase |
|---|---|---|---|---|
| RCA-SQL-09 | `processes_blocked`, `memory_grants_pending`, `memory_grants_outstanding`, `active_transactions`, `user_connections` | count | gauge | 1 |
| RCA-SQL-09 | `lock_timeouts`, `deadlocks`, `table_lock_escalations`, `attentions`, `log_flushes` | count | delta | 1 |
| RCA-SQL-09 | `log_flush_wait_ms` | ms | delta | 1 |
| RCA-PG-10 | `connections_total`, `connections_active`, `connections_idle`, `connections_idle_in_transaction`, `connections_waiting_lock`, `max_connections`, `reserved_connections` | count | gauge | 1 |
| RCA-PG-03 | `deadlocks`, `conflicts`, `xact_rollback`, `temp_files` | count | delta | 1 |
| RCA-SQL-07 | `runnable_tasks`, `work_queue`, `current_workers`, `max_workers` | count | gauge | 2 |
| RCA-AZ-01 | `avg_cpu_percent`, `avg_log_write_percent`, `avg_data_io_percent`, `max_worker_percent`, `max_session_percent` | percent | gauge | 1 |

RCA-AZ-01 isn't an episode's capture: the runner reads it every 30 minutes and at the session's end, and keeps every 15-second row it hasn't kept yet (by `end_time`), with no deadband, so a missing row means a missing sample. That's about 1,800 rows and 4.6 KB of gzip for a 90-minute session. It gives the blind detector T3's CPU at 15 seconds where Database Hub's bins are sparse ([ADR 0031](../docs/adr/0031-incident-rca.md#the-shared-blind-detector)).

RCA-PG-10's `connections_total` counts every client backend, the observer's own too, since each takes one of `max_connections`' slots. Its counts by state leave the observer out: `connections_active`, `connections_idle`, and `connections_idle_in_transaction` add up to at most one less than the total, and `connections_waiting_lock` is a part of `connections_active` (since 2026-11-21; before, the observer's own query was one of `connections_active` in every sample).

### Deadlocks

An `rca_events` row of kind `deadlock` from an Extended Events graph carries `deadlock_json`, the graph reduced to what the rules read (at most 4,000 characters):

```json
{ "victim": 82,
  "processes": [ { "session": 81, "program": "ContosoCare.Demo", "runToken": "de845fccbaba", "module": "[demo].[usp_x]", "statement": "UPDATE ...", "holds": "X", "wants": "U", "waitResource": "KEY: ..." } ],
  "resources": [ { "type": "KEY", "object": "[care].[inventory]", "index": "pk_inventory", "mode": "X", "holder": 81, "waiter": 82 } ] }
```

Names follow [Names](#names). PostgreSQL's deadlocks are a count (RCA-PG-03): its graphs are only in the server's log, which the observer doesn't read, so their `deadlock_json` is null.

## The sidecar

What the observer captures beyond the evidence document, in documents of their own kind, so the evidence document, its transport, and every piece that reads it stay exactly as they were ([sidecar.schema.json](sidecar.schema.json)).

| Field | Rule |
|---|---|
| `kind`, `version` | `ContosoCare.RcaSidecar`, 1 |
| `documentId` | The evidence document's form with `-sidecar` after it: `20261120T165000Z-sqlvm01-0001-sidecar`. Unique; the notebook writes a sidecar once |
| Everything else | As the evidence document's (`sessionId`, `producer`, the window, `sequence`, `final`, `targets`, `epochUtc`, `strings`, `tables`), with no `answerKey`. Each target has an `rca_query_coverage` row |

- **Its tables** ([history-tables.json](history-tables.json), document `sidecar`): `rca_query_stats`, `rca_query_waits`, `rca_query_plans`, `rca_query_events`, `rca_query_coverage`, and `rca_connections`, encoded as the evidence document's tables are. The evidence document never holds one, and a sidecar never holds an evidence table.
- **Where the rows wait:** the observer writes them to each span's own `sidecar-<target>.jsonl`, beside its evidence files, which the evidence export never reads.
- **Sealed outside the spans:** the runner seals a span's rows into the store's `sidecars\` folder:
  - at every export that reads the span, the evidence document's included, whose output doesn't change;
  - at the span's end;
  - at the observer's start, for a span left unsealed.

  It never keeps them in `exports\`, which an older runner's retention empties after 7 days. It doesn't delete a span whose rows aren't sealed. A sealed sidecar stays until it's acknowledged, or for 30 days after its sealing.
- **One per span per export:** `rca sidecar-export` makes one sidecar for each span with new rows, and offers a sidecar not yet acknowledged again (state `pending`) at every later call.
- **Its session:** a sidecar keeps its span's session, as the evidence document does, a backfill's included ([pending publication](#pending-publication)).
  - **Binding:** the first export of either kind that takes from a span binds it to its caller's session, as `rca export` does.
  - **Its run:** the notebook writes a sidecar's rows under that session's run, `session-<sessionId>`, whichever run reads it, and a sidecar with no session under the reading run's `RUN_ID`.
  - **On the scripts' path,** which fetches a Run all session's sidecars at a later save, the evidence lands with its session, never with the save.

### Query Store

- **What's read:** RCA-SQL-10, 11, 14, and 15 on T1 to T3, and RCA-AZ-03 and 04 for T3's automatic tuning; RCA-PG-13 to 16 on T4. T4's replica records nothing in Query Store ([Learn](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store)), which its coverage says.
- **When:**
  - every 15 minutes, 2 minutes after a Query Store interval ends. The intervals are 15 minutes on every target: `database/*/030-configure.sql`, and T4's `pg_qs.interval_length_minutes` default;
  - at the observer's start, the 2 hours before it (8 intervals), so a rule has a baseline;
  - at its end, with SQL Server's open interval: Query Store unifies its in-memory and on-disk data when it's read;
  - RCA-SQL-15 every 60 s; RCA-PG-13 with each read.
- **A row** is one interval's totals for a plan (on PostgreSQL, for a role's query and plan):
  - execution-weighted: each Query Store row's average times its executions, summed; the maximum of maxima;
  - `first_execution_utc` is when the plan's first execution in the interval ended, as Learn defines it, not the instant a plan changed.
- **The latest read wins.** An interval read twice (open, then closed; or by two sessions' baselines) is in both reads' rows. The notebook writes the latest read of each target, interval, login, query, and plan. The model's measures take the latest read too, so a history written otherwise still counts each interval once.
- **The top lists:**
  - each interval's top 10 by CPU (on T4, total time), and top 5 by duration, by logical reads (on T4, blocks), and by waits;
  - ranked after the leave-outs ([what the capture leaves out](#what-the-capture-leaves-out)); a plan is in a list only when it used what the list ranks, more than 0, and ties go to the lower `plan_id`, so two reads of an interval rank it alike;
  - with every plan of those queries that ran in it; at most 600 rows a read, the oldest intervals first, and the next read starts from the last whole interval it got.
  - A query missing from earlier top lists isn't necessarily new: a reader says "new" only when its plan's compile time (RCA-SQL-14) is in the window, and otherwise "not in the top lists before".
- **What a reader may claim,** at Query Store's 15-minute granularity, which every claim names:
  - before and after a plan change come from intervals wholly before or after the new plan's first execution; an interval with both plans is mixed, and named so;
  - a CPU share is of the captured top queries, or of the target's measured CPU (RCA Resource) when that's in the window;
  - a baseline is the same query's intervals in the 60 minutes before an incident, at least 2 with executions; otherwise the claim says there's none.
- **Plans:**
  - every plan the statistics rows name, so each row has its plan (RCA-SQL-14's `@plans`); at most the 5 that ran last per query besides; and every forced plan;
  - a plan's row is written when a read first returns it, and again when its forcing, compiles, or compile time change. So its `last_execution_utc` is as of that row's read;
  - a showplan's XML is read once and reduced to `plan_summary` and `estimated_cost`: its costliest operators with their objects and indexes, its warnings, and a missing index. It's never stored whole and never keeps a parameter's value;
  - T4 stores no plans (`pg_qs.store_query_plans` stays off).
- **Events:** `rca_query_events` records:
  - a plan forced or unforced;
  - Query Store's state changing, with READ_ONLY's reason in words;
  - automatic tuning's option, or a recommendation's state, from its first appearance (with no previous state).

  Each is timed within its read's period (`time_from_utc` to `event_time_utc`).
- **Coverage:** `rca_query_coverage` holds one row per target per sidecar: Query Store's state and capture mode as read, the intervals read, PostgreSQL's pending publication, and the gaps:
  - Query Store off or read-only, a permission, a timeout, an expired pending range, the sidecar's budget;
  - on a Burstable T4: Query Store is off, as Learn advises there;
  - on T2's kept PaygWizard guest: not captured, because its runner identity has no `VIEW DATABASE STATE`, with `RCA.CAPTURE.T2`'s fix.

### Pending publication

PostgreSQL shows an interval only once it ends and is persisted ("Data that the query store is still recording in memory for the currently active time window isn't visible until the time window ends", [Query Store](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store)). So T4's last 0 to 15 minutes are unreadable at a session's stop.

- **The watermark:** `rca\query-watermark\T4.json` in the store, outside the spans: the newest persisted interval end read, and the pending ranges, each with its session and span.
- **The backfill:** whenever the observer runs with T4 reachable (the next session's start, or a save's `rca sidecar-export` while T4 runs), it reads the pending ranges' intervals into a sidecar of the original session and span, with `rca_query_coverage.backfill` true.
- **Until then,** the coverage says "pending publication", never "not captured". A range older than T4's retention (`pg_qs.retention_period_in_days`, 7 by default) expires as a gap that says so.
- **A stop in the window:** the demo's stops stop T4 mid-window, and Learn doesn't say whether a stop keeps the window that's still in memory. So the observer records T4's start time (`pg_postmaster_start_time()`) with each read and pending range. A backfill that finds no rows for a range T4 restarted after says it was lost when T4 stopped, never pending or not captured.

### Who holds T4's connections

- **When:** during a connection episode (RCA-PG-10 at 80 % of the slots or more), RCA-PG-17 runs every 10 s, and once when the episode ends.
- **What it records:** T4's client connections counted by application, role, and state, idle ones included, with the lock waiters and the oldest state and connection ages, in `rca_connections`: counts, never sessions.
- **Names** follow [Names](#names): the workload's own connections keep their service name and run token, and any other application's name and role stay out (`is_demo` false).

### Acknowledgement

The notebook acknowledges every sidecar payload it reads, by document ID, in `Files/rca/acks/<the payload's name without .json>.ack.json` (transport.schema.json, `ack`; for the payload `Files/rca/inbox/sidecar-20261121T102531Z.json`, `Files/rca/acks/sidecar-20261121T102531Z.ack.json`). Each document is `written` (by this run), `already` (an earlier run wrote it), or `skipped`, with the reason.

- **Exactly once:**
  - the notebook writes a sidecar's rows table by table, replacing any rows of its `document_id` that an earlier run wrote, and its `rca_query_coverage` rows last;
  - a document is `already` only when its coverage rows are there, so a run that stopped halfway through a document is completed by the next, never skipped;
  - `written` and `already` both mean every table holds the document's rows.
- **The acknowledgement file** names its payload and lists exactly that payload's documents. The notebook writes it once every one of them is committed. A reader treats one whose payload or documents differ from what it staged as missing.
- **No acknowledgement** when the run doesn't save its results (`SAVE_RESULTS` false, outside `RCA_ONLY`), or can't read the payload: a missing acknowledgement, so everything in the payload stays pending.
- **It deletes a payload** only when every document in it is `written` or `already`. A payload that holds a skipped document stays until its documents are acknowledged, or for 30 days.
- **The scripts read the acknowledgement,** never the payload's disappearance. They run `rca ack` for the written documents on the VMs that hold them, and keep the rest pending with the reason.
- **When the VMs are already stopped:** `stop-demo.ps1 -SaveHistory` runs the notebook after the VMs deallocate. So it keeps the written IDs per VM in `out/history-pending/`, and the next export with that VM running sends `rca ack` first. `deploy.ps1`'s snapshot and `configure-fabric.ps1 -RunLiveActivity` run the notebook while the VMs run, and acknowledge at once.
- **The runner** keeps an unacknowledged sidecar, and offers it again, until it's acknowledged or 30 days have passed. A sidecar offered again after it was written is `already`, so nothing is written twice.
- **The evidence document** keeps today's transport: acknowledging it by ID is a later change, with its own proof.

## Transport

### Part lines

The export gzips each document's UTF-8 JSON (no whitespace needed), slices the gzip bytes into contiguous parts of at most 2,400 bytes, and prints each part as one line:

```text
DBHUBDEMO-RCA 1 <documentId> <index>/<count> <sha256> <base64>
```

- `1` is the part format; `<index>` counts from 1 to `<count>` (at most 99); `<sha256>` is the lowercase hex SHA-256 of the whole gzip stream, the same on every part; `<base64>` is the standard base64 (RFC 4648, with padding) of this part's slice. Single spaces; at most 3,400 characters; ASCII only.
- **Decoding:** group lines by documentId, check that indexes 1 to count are all there once, decode each part's base64 separately, concatenate in index order, check the SHA-256, then gunzip and parse. A document with a missing or bad part is skipped and reported, never written partly.
- **A sidecar's part lines** start with `DBHUBDEMO-RCAS` instead, with the same fields, and its documentId ends in `-sidecar` (transport.schema.json, `sidecarPartLine`). A piece that takes only lines starting with `DBHUBDEMO-RCA` and a space never takes one.

### The runner's commands

The runbook and the scripts call the runner through managed Run Commands, which keep the last 4 KB of output, so each call prints one line:

| Command | Prints |
|---|---|
| `ContosoCare.Workload rca export --session <sessionId or none> [--final]` | Reduces what's been captured since the previous export into documents and prints `DBHUBDEMO-RCA-INDEX <json>`: `{"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"...","parts":n,"sha256":"..."}],"status":"Pass","message":"..."}` (transport.schema.json), at most 3,400 characters. Status is ADR 0012's. Exit code 0, or 2 when there's nothing to export |
| `ContosoCare.Workload rca part --document <documentId> --part <index>` | That part's line, an evidence document's or a sidecar's. Exit code 0, or 1 when the document or part doesn't exist |
| `ContosoCare.Workload rca sidecar-export --session <sessionId or none> [--final] [--page <n>]` | Makes a sidecar for each span with new sidecar rows and prints `DBHUBDEMO-RCAS-INDEX <json>` (transport.schema.json, `sidecarIndex`): one page of at most 8 sidecars, new and pending, at most 3,400 characters. Exit code 0, or 2 when there's nothing to fetch |
| `ContosoCare.Workload rca ack --document <documentId>[,<documentId>...]` | Marks sidecars as written into the history, so the runner stops offering them and may delete them. Exit code 0 |

- **The sidecar's Run Command actions:** the VM's control script runs the two sidecar commands as `RcaSidecarExport` and `RcaAck`. An older VM bundle answers "Unknown action", the scripts' `OldBundle` outcome: a Warning naming `./scripts/deploy.ps1`, and the evidence document goes on as before.
- **On the T2 host, one Run Command at a time** (R871): the runbook starts the next only once Azure no longer lists the last, because parallel Run Commands' deletes failed there, and the host's next start didn't get its goal state. That holds across the runbooks' jobs too: an export sends its first Run Command there only once Azure lists no other of the control's export Run Commands there, less than an hour old, and none for up to 90 s while it lists older ones whose deletes the export has just asked for, and a session's re-check sends none once that session's stop has begun (live, 2026-11-21: a stop's export ran beside a re-check's last parts there). The stop checks the host only from 60 seconds after its mark, past a re-check's last requests (review of 242a3ef7).
- **The operator's scripts** (`stop-demo.ps1 -SaveHistory` and `deploy.ps1`'s snapshot) export with `--session none`. They list the documents a save didn't take by ID in `out/history-pending/rca-pending-<resource group>.json`, so the next save fetches them again while the runner keeps them (at least 7 days; `STOP.RCA.PENDING`). The runbook takes a document of its own session or of no session, as the notebook does ([`RCA_EVIDENCE`](#rca_evidence)).

### Bundles and the bundle index

- **A bundle** is one earlier version of `dbhub-session-metrics`: `{"kind":"ContosoCare.RcaBundle","version":1,"sessionId":...,"parts":[...]}` with at most 6 part lines and at most 24,000 bytes of UTF-8 ([fixture](fixtures/metrics-bundle.json)). The runbook writes the bundles first.
- **The bundle index** is the `rca` member of the metrics document in the secret's final version, which the runbook writes last: `{"kind":"ContosoCare.RcaBundleIndex","version":1,"sessionId":...,"bundles":["<version>"],"documents":[{"documentId","parts","sha256"}],"status":...,"message":...}` ([fixture](fixtures/metrics-rca-member.json)), at most 4,000 bytes, inside the metrics document's 24,000. The version IDs are Key Vault's (32 lowercase hex). The deployer's Secrets User grant on the secret covers every version, so nothing needs a new grant.
- **The final version, by its ID:** the stop's status names the version its metrics went into, `metrics.version` (from the write's `secretUriWithVersion`). Readers use that version, never the latest version of `dbhub-session-metrics`: a re-check that was still exporting can write a bundle after it, which is then the newest. A status from a runbook before this names no version, and Run all reads the latest, as before.
- **Only in the runbook's copy:** a stop marks itself begun with `stopBegunUtc`, and a re-check that ran during the stop hands what it found to the stop in `rcaHandoff`. Both live only in the status's copy, the Automation variable `DbHubSessionStatus`, never in the vault's `dbhub-session-status`. A re-check sends no Run Command and writes no bundle once the stop has begun; what it found goes into the stopped status as documents still to export, which the next session's start exports from every VM that holds one.
- **When a tenant's policy encrypts the copy:** some tenants re-create Automation variables encrypted, for example every night. The runbooks still read and write the copy (`Get-AutomationVariable` and `Set-AutomationVariable`), so nothing above changes, but the portal and Azure Resource Manager can't read its value then ([variables](https://learn.microsoft.com/azure/automation/shared-resources/variables)). `capture-t2-golden.ps1`, which reads the copy's lists through Azure Resource Manager before it deletes T2's capture, then captures nothing (`GOLDEN.CAPTURE.RCA`). Every `./scripts/deploy.ps1` re-creates the copy unencrypted and empty, so a start after an update no longer has the earlier status's lists ([ADR 0031's risks](../docs/adr/0031-incident-rca.md#risks)).

### `RCA_EVIDENCE`

`NB_DatabaseHub_LiveActivity`'s new parameter: compact JSON, `{"kind":"ContosoCare.RcaEvidenceParts","version":1,"sessionId":...,"parts":[...],"status":...,"message":...}` with every part line of the session's documents in any order, at most 64 ([fixture](fixtures/rca-evidence.parameter.json)). Empty means none was passed. The notebook:

- writes a document under its own `RUN_ID` when the document's `sessionId` equals `SESSION_ID`, or either is empty; it skips a document for another session;
- writes each document once (by `documentId`), the detection tables and `rca_answer_key` together, deleting the run's earlier rows first, as it writes the other tables;
- reports `RCA.EVIDENCE` with ADR 0012's statuses: **Pass** when every document was written, **Warning** with the reason when one was skipped (a missing part, a bad SHA-256, a newer version, another session), **Not selected** when none was passed.

### `RCA_EVIDENCE_FILE`

The notebook's other parameter, for any session: a path in the demo's lakehouse, `Files/rca/inbox/<name>.json` (transport.schema.json, `evidenceFile`), to a file that holds exactly one `RCA_EVIDENCE` document. Neither a notebook run's parameters nor a job's document a size limit, and a full session's 64 parts come to about 218 KB, so the parts travel as a file. The inline `RCA_EVIDENCE` stays supported.

- **Staging:** the control notebook writes the file with `notebookutils.fs.put` ([file system utilities](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-file-system)). `stop-demo.ps1 -SaveHistory` and `deploy.ps1`'s snapshot write it through OneLake's DFS API, the ADLS Gen2 API at `onelake.dfs.fabric.microsoft.com` ([OneLake access with APIs](https://learn.microsoft.com/fabric/onelake/onelake-access-api)), with the operator's existing workspace role. No new grant: a private control vault is reachable only from the control workspace, so the job's fallback can't read the bundles itself.
- **Reading:** the notebook reads the file with `notebookutils.fs.head(path, 262144)`, because `head` returns only the first 100 KB (102,400 bytes) by default ([`head`](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-file-system)). It applies every rule of `RCA_EVIDENCE` above, with the same `RCA.EVIDENCE` status. A file that's missing, larger than 262,144 bytes, or not one `RCA_EVIDENCE` document is a **Warning** with the reason, and nothing of it is written.
- **Both parameters:** the notebook merges their parts and still writes each document once (by `documentId`).
- **Cleanup:** the notebook deletes the file only once its evidence is in the history, written by that run or before, so a deleted file means written, for the control notebook and the scripts alike (the review of 37a546bc). One it wrote nothing from (unusable, unread, every document skipped, or a write that failed) stays; Run all and the scripts delete it once the run has ended, and otherwise a later run's sweep deletes staged files more than a day old; the next save stages a new file. The deployment notebook's purge removes `Files/rca/inbox` with the RCA tables (history-tables.json, `purgeFiles`).

### `RCA_SIDECAR_FILE`

`NB_DatabaseHub_LiveActivity`'s parameter for sidecars: a path in the demo's lakehouse, `Files/rca/inbox/sidecar-<yyyyMMddTHHmmssZ>[-<name>].json` (transport.schema.json, `sidecarFile`), to a file that holds exactly one `ContosoCare.RcaSidecarParts` document (`sidecarParameter`): every part line of the sidecars a save fetched, at most 64.

- **Staging:** the scripts write it as they write `RCA_EVIDENCE_FILE`, and only when the workspace's notebook declares the parameter (`Test-DemoFabricNotebookParameter`). For an older or edited notebook they stage none, leave the sidecars pending, and say so in a Warning with the fix. Its name starts with `sidecar-`, which the sweep of evidence files staged more than a day ago never matches: a sidecar payload goes by [acknowledgement](#acknowledgement).
- **Reading:** as `RCA_EVIDENCE_FILE` (`notebookutils.fs.head`, 262,144 bytes). It writes each sidecar once, by `documentId`, replacing that document's earlier rows, under its session's run ([the sidecar](#the-sidecar)), acknowledges the payload ([acknowledgement](#acknowledgement)), and reports `RCA.SIDECAR` with ADR 0012's statuses, as `RCA_EVIDENCE` reports `RCA.EVIDENCE`.
- **The deployment notebook's purge** removes the sidecar's six tables with the others, and `Files/rca/acks` with `Files/rca/inbox` (history-tables.json, `purge` and `purgeFiles`).

### Limits

| Limit | Value | Why |
|---|---|---|
| A part line | 3,400 characters (2,400 bytes of gzip) | A managed Run Command keeps the last 4 KB of output |
| A document | 64 KiB of gzip (at most 28 parts) | The reducer cuts in reverse priority and records each cut as a gap in `rca_coverage` |
| A session | 96 KiB of gzip across both hosts (at most 64 parts in `RCA_EVIDENCE`) | The reducer aims at 64 KiB; the fixtures measure about 3 KB of gzip for 15 minutes of 10-second blocking detail on one target |
| `RCA_EVIDENCE_FILE` | 262,144 bytes: one `RCA_EVIDENCE` document of 64 parts is about 218 KB | What the notebook passes to `notebookutils.fs.head`, whose default is 100 KB |
| A bundle | 6 parts, 24,000 bytes | The runbook's existing bound for the metrics secret |
| The bundle index | 16 bundles, 4,000 bytes | Inside the metrics document's 24,000 bytes |
| A sidecar | 64 KiB of gzip (at most 28 parts), as a document | The reducer cuts waits past each plan's first three, then plan summaries, then the lowest-ranked queries, each cut a gap in `rca_query_coverage` |
| A session's sidecars | 96 KiB of gzip, apart from the evidence documents': 64 KiB on T1's VM and 32 KiB in T2's guest, the evidence documents' split | A budget of their own, so Query Store never crowds out the evidence document. Each host's reducer cuts across its spans by priority |
| `RCA_SIDECAR_FILE` | 64 parts and 262,144 bytes, of whole documents | The rest waits on the VMs for the next save, which the save's line says |
| `rca sidecar-export`'s index | 8 sidecars a page, 3,400 characters | A managed Run Command keeps the last 4 KB of output |

## Versioning

- Every kind carries `version` 1: the evidence document's and the sidecar's alike, and each kind's version moves on its own. history-tables.json's own `version` (2 since the sidecar) is the file's: a consumer checks a document's kind and version, never the file's.
- Any change to a field, a column, a type, an encoding rule, or a limit is a new version of its kind, with a new schema beside this one.
- A consumer accepts only the versions it knows and reports any other as a **Warning** whose fix is `./scripts/deploy.ps1`, which updates the runner, the runbook, the notebooks, the model, and the app in one run.
- Older pieces degrade and say so: an older runner has no `rca` commands (`RCA.EXPORT` **Warning**); an older notebook ignores `RCA_EVIDENCE`; a session saved before the feature has no RCA rows, and the app says "no RCA capture recorded" for its windows.
- **A sidecar is invisible to the pieces that predate it:** its own command, part marker, and notebook parameter. They never reject or lose one; they leave it pending on the VM, where the runner keeps it until a newer piece acknowledges it.
- **An older runner installed over a newer one** isn't a supported path: `deploy.ps1` moves an environment forward ([updates from GitHub](../docs/deployment.md#updates-from-github-2026-11-09)). An older checkout that can't update itself can still install its runner. Then:
  - the older runner neither deletes nor offers the sealed sidecars, and a newer runner offers them again until 30 days after their sealing;
  - T4's pending ranges wait in `query-watermark\` within T4's retention;
  - **two losses are accepted limits** (the coordinator's decision for the owner, 2026-11-23): sidecars sealed more than 30 days before a newer runner returns, which it deletes unread; and the rows of a session whose runner was replaced mid-session, which go with their span.

  Before installing an older runner, a scripts' save with the VMs running takes every sealed sidecar into the history: `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity`, again while its line says sidecars still wait.

## Who builds what in Phase 1

| Step | Builds | Tests against this contract |
|---|---|---|
| 1.1 and 1.2, the capture | The observer lane, its triggers, normalization and names, the local store, `rca export` and `rca part` | Fixture documents round trip through its encoder and decoder; its documents validate against evidence.schema.json; the observer's code names nothing in blind-detection.json; the capture's T-SQL parses (as `SqlScriptTests`) |
| 1.3 to 1.5, the transport and the history | The runbook's export, bundles, and index; the staged `RCA_EVIDENCE_FILE` (and the inline `RCA_EVIDENCE`); the notebook's decoder and the eight tables; the deployment notebook's purge of them and of `Files/rca/inbox`; the model's tables, relationships, and measures | Bundles and the index validate against transport.schema.json; the fixtures' parts decode to the fixture documents; the notebook's tables and the model's TMDL match history-tables.json |
| 1.6, the app | The blind rules, the shared blind detector, the DAX loader, the six Phase 1 tools, the RCA view, the postmortem's Cause, the chat's blindness, the gating | Its loader's names match history-tables.json; its rules find the fixtures' facts ([fixtures](fixtures/README.md)); its detection code names nothing in blind-detection.json |

## Who builds what for the sidecar

The scripts' path first; Run all's path (the runbook's bundles and the control notebook) follows in a later release.

| Unit | Builds | Owns | Tests against this contract |
|---|---|---|---|
| A1, SQL Server's reads | RCA-SQL-10, 11, 14, and 15 (and RCA-AZ-03 and 04's events) on T1 to T3: the cadence, the plan summary, the events, the sidecar rows | Those blocks in `capture/sqlserver.sql`, their comments included; new files under `Rca/QueryStore/` (`Sql*.cs`, `PlanSummary.cs`); its wiring in `Rca/Observer/SqlTargetObserver.cs`, `SqlCapture.cs`, and the shared `TargetObserver.cs` seam that turns a failed Query Store read into a sidecar gap; their tests | Its rows type-check against history-tables.json; the catalog's blocks run as they are; the leave-out rules ([above](#what-the-capture-leaves-out)) |
| A2, PostgreSQL's reads and the holders | RCA-PG-13 to 17 on T4: the `azure_sys` connection and its `search_path`, the watermark and backfill, the holders | Those blocks in `capture/postgresql.sql`; new files under `Rca/QueryStore/` (`Pg*.cs`, `QueryWatermark.cs`, `ConnectionHolders.cs`); its wiring in `Rca/Observer/PgTargetObserver.cs` and `PgCapture.cs`; their tests | As A1's |
| H, the harness's marks | The extended property and the comments the leave-out reads | Its own block in `database/common/110-demo-control.sql` and the PostgreSQL control script, after the realistic names' changes there | Every control module carries the mark, and no other module does |
| T1a, the runner's sidecar store | The store in `sidecars\`, sealing, the reducer and its budgets, the page index and part lines, acknowledgement, retention; the evidence documents' pinned hashes | New files under `Rca/Sidecar/`, their tests | Its sidecars validate against sidecar.schema.json and round trip through the part lines; the evidence documents stay byte for byte |
| T1b, the runner's wiring | `rca sidecar-export`, `rca part` for sidecars, `rca ack`; sealing at each export, a span's end, and the observer's start | `Cli/CommandLine.Rca.cs`, `Rca/Export/Exporter.cs`, `Rca/Store/EvidenceStore.cs`, after the stop tail's changes land | As T1a's |
| T2a, the scripts' transport | The fetch, staging `RCA_SIDECAR_FILE`, reading the acknowledgement, `rca ack` at once or deferred, the PC's lists, and the golden capture's guard | `scripts/modules/DbHubDemo/Private/RcaExportHelpers.ps1`, the save paths, and the golden capture's files | The sidecar fixtures' parts and the acknowledgement fixture; the mixed-version combinations |
| T2b, the VM's control script | `RcaSidecarExport` and `RcaAck`, and the sidecar's part lines through T2's relay | `vm/bootstrap/Invoke-DemoWorkloadControl.ps1`, after the stop tail's changes land | As T2a's |
| B, the notebook and the model | The sidecar's decoder, its six tables, the latest read per interval, the acknowledgement file and the cleanup rule, `RCA.SIDECAR`; the model's six tables and measures | `NB_DatabaseHub_LiveActivity`'s RCA cells, the semantic model's RCA tables, `OneLakeHelpers.ps1`'s RCA functions | The notebook's tables and the model's TMDL match history-tables.json; the sidecar fixtures decode and write once |
| C, the app | The Query Store rules and claims, the tool for a window's top queries and a query's plans, "pending publication" | `fabric/app/src/rca/` (not the page, its view, or its CSS) | Its loader's names match history-tables.json; its rules find the sidecar fixtures' facts |
| D, the report | The Root cause report's Query Store sections | The report's components, after the reorganized page | The sidecar fixtures' facts as the report shows them |
