# The Incident RCA evidence contract (version 1)

What the runner's observer captures, how it reaches the history, and what the Insights app reads, for [ADR 0031](../docs/adr/0031-incident-rca.md). Three parts of Phase 1 build against it at once: the capture (the runner), the transport and history (the control's runbook, the scripts, the notebooks, the semantic model), and the app. Nothing here may change without a new version (below).

| File | What it is | Who reads it |
|---|---|---|
| [evidence.schema.json](evidence.schema.json) | JSON Schema (2020-12) of an evidence document, generated from history-tables.json | The runner's export tests, the notebook's tests, this contract's tests |
| [transport.schema.json](transport.schema.json) | JSON Schema of a bundle, the bundle index, and the `RCA_EVIDENCE` parameter; the part line's pattern | The runbook's, the scripts', and the notebook's tests |
| [history-tables.json](history-tables.json) | The eight lakehouse tables (seven for detection, one answer key): columns, types, keys, model names, relationships, measures | The notebook, the model, and the app, and their tests |
| [blind-detection.json](blind-detection.json) | What detection may read, what is the answer key, and what detection code must never name | The app's and the runner's tests |
| [capture/](capture/README.md) | The capture query catalog (RCA-SQL, RCA-AZ, RCA-XE, RCA-PG), with each block's trigger, permission, and Learn page | The runner, which embeds the two .sql files |
| [fixtures/](fixtures/README.md) | Two evidence documents (T1's blocking chain, T4's chain and its replica's lag), their parts, a bundle, a bundle index, and an `RCA_EVIDENCE` value | Every component's tests |

`tests/unit/Rca.Contract.Tests.ps1` checks that the schemas, the tables, the fixtures, and the capture catalog agree.

## The flow

1. **Capture, on the VMs.** The observer lane of `ContosoCare.Workload profile run` (on T1 for T1, T3, T4, T4's replica; in T2's guest for T2) runs the sentinel every 30 s for the whole session, escalates to detail capture when a signal crosses its threshold ([below](#capture-triggers)), and keeps what it captures in `C:\ProgramData\DbHubDemo\rca\<session>\` (SYSTEM and Administrators only, at most 20 MB per target, deleted 7 days after its export).
2. **Export.** At the session's end (and at each 30-minute re-check), `ContosoCare.Workload rca export` reduces the capture into evidence documents and prints them as part lines ([transport](#transport)).
3. **Into the control vault.** The control's runbook runs the export through managed Run Commands, one part per command, writes the parts as earlier versions of the control vault's existing `dbhub-session-metrics` secret (bundles), and lists those versions in the `rca` member of the secret's final version, the metrics document the control notebook already reads.
4. **Into the history.** The control notebook reads the bundles, stages every part in the lakehouse as one `RCA_EVIDENCE` document, and passes its path to `NB_DatabaseHub_LiveActivity` as `RCA_EVIDENCE_FILE`; the notebook decodes the documents and writes the eight tables. `stop-demo.ps1 -SaveHistory` and `deploy.ps1`'s history snapshot run the same export with the operator's role and stage the same file ([`RCA_EVIDENCE_FILE`](#rca_evidence_file)).
5. **Read.** `SM_DatabaseHub_History` reads the tables (Direct Lake); the app's rules, investigation tools, RCA view, and chat read the seven detection tables through it, never the answer key.

## Blind detection

The product is blind: the rules, the investigation tools, the RCA view, and the chat use only what a real DBA's tools would show: the observer's capture, Azure Monitor's metrics, and Database Hub's telemetry. Grading against what the workload injected exists for the tests and the evaluation set, and for the scoreboard's "Did we catch it?" trust moment, and nowhere else ([ADR 0031](../docs/adr/0031-incident-rca.md)).

- **The capture is blind:** the observer never reads the workload's plan, the scenario catalog, `demo.scenario_runs`, or `demo.scenario_run_events`, and its cadence follows what it sees, not what's scheduled. It records names only as [Names](#names) says.
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
| A wait category's rate (RCA-SQL-04, RCA-AZ-02) | at 3 times its median over the 15 minutes before, and at least 200 ms/s | RCA-SQL-03 every 15 s, RCA-SQL-08, then Query Store (RCA-SQL-10, 11) and RCA-SQL-13 at its end | 2 minutes under 1.5 times the median | 2 |
| CPU (RCA-AZ-01 on T3; runnable tasks, RCA-SQL-07, on T1 and T2) | at 80 % or more, or runnable tasks at 1 per scheduler, for 2 samples | RCA-SQL-07 every 15 s; Query Store at its end | 2 minutes below | 2 |

T5 has no sentinel in the observer: its 429s and normalized RU are Azure Monitor metrics that the history saves already, which detection reads from Telemetry Snapshots.

## Names

What the observer records about who ran a session, so the evidence names nothing the workload planned:

- **`program_name`:** a workload session's application name today is `ContosoCare.Demo/<scenario>/<run>`. The observer keeps only `ContosoCare.Demo`, and keeps any other session's name out entirely (it isn't the workload's). If the workload later uses per-service names ([ADR 0031, Names](../docs/adr/0031-incident-rca.md)), the observer keeps the service name and drops only the run segment. A scenario ID never reaches the evidence.
- **`run_token`:** the first 12 lowercase hex characters of SHA-256 over the UTF-8 bytes of `ContosoCare.RcaRunToken:<run>`, where `<run>` is the run segment. It groups one run's sessions and names nothing; the answer key carries the same token next to the run ID, so grading can check that a blind finding names the injected run's sessions.
- **`is_demo`:** true for the workload's own sessions, the baseline's and every fault's alike. It decides only whether text, login, and host are kept; rules never use it to tell a fault from the baseline.
- **Modules and statements** are what the DMVs return (a DBA sees them too). Rules never branch on a name; the blind-detection test checks that detection code contains no procedure-name pattern.
- **One helper:** in the runner, only `Rca/Observer/ApplicationNames.cs` may know the workload's application-name prefix ([blind-detection.json](blind-detection.json)).

## The evidence document

One JSON document per host and export, UTF-8, no byte order mark. The schema says what it can; these rules complete it:

| Field | Rule |
|---|---|
| `kind`, `version` | `ContosoCare.RcaEvidence`, 1 |
| `documentId` | `<windowStartUtc as yyyyMMddTHHmmssZ>-<host>-<sequence, 4 digits>`, for example `20261120T165000Z-sqlvm01-0001`. Unique; the notebook writes a document once |
| `sessionId` | The control's session ID (32 lowercase hex, the resource group's `DbHubSessionId`), or null outside a control session |
| `producer` | `ContosoCare.Workload`, its version, the host (`sqlvm01` or `arcsql01`), lane `observer` |
| `windowStartUtc`, `windowEndUtc` | The slice of capture this document holds, start inclusive, end exclusive. One host's documents never overlap for a target: each export starts where the previous one ended |
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

### Deadlocks

An `rca_events` row of kind `deadlock` from an Extended Events graph carries `deadlock_json`, the graph reduced to what the rules read (at most 4,000 characters):

```json
{ "victim": 82,
  "processes": [ { "session": 81, "program": "ContosoCare.Demo", "runToken": "de845fccbaba", "module": "[demo].[usp_x]", "statement": "UPDATE ...", "holds": "X", "wants": "U", "waitResource": "KEY: ..." } ],
  "resources": [ { "type": "KEY", "object": "[care].[inventory]", "index": "pk_inventory", "mode": "X", "holder": 81, "waiter": 82 } ] }
```

Names follow [Names](#names). PostgreSQL's deadlocks are a count (RCA-PG-03): its graphs are only in the server's log, which the observer doesn't read, so their `deadlock_json` is null.

## Transport

### Part lines

The export gzips each document's UTF-8 JSON (no whitespace needed), slices the gzip bytes into contiguous parts of at most 2,400 bytes, and prints each part as one line:

```text
DBHUBDEMO-RCA 1 <documentId> <index>/<count> <sha256> <base64>
```

- `1` is the part format; `<index>` counts from 1 to `<count>` (at most 99); `<sha256>` is the lowercase hex SHA-256 of the whole gzip stream, the same on every part; `<base64>` is the standard base64 (RFC 4648, with padding) of this part's slice. Single spaces; at most 3,400 characters; ASCII only.
- **Decoding:** group lines by documentId, check that indexes 1 to count are all there once, decode each part's base64 separately, concatenate in index order, check the SHA-256, then gunzip and parse. A document with a missing or bad part is skipped and reported, never written partly.

### The runner's commands

The runbook and the scripts call the runner through managed Run Commands, which keep the last 4 KB of output, so each call prints one line:

| Command | Prints |
|---|---|
| `ContosoCare.Workload rca export --session <sessionId or none> [--final]` | Reduces what's been captured since the previous export into documents and prints `DBHUBDEMO-RCA-INDEX <json>`: `{"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"...","parts":n,"sha256":"..."}],"status":"Pass","message":"..."}` (transport.schema.json), at most 3,400 characters. Status is ADR 0012's. Exit code 0, or 2 when there's nothing to export |
| `ContosoCare.Workload rca part --document <documentId> --part <index>` | That part's line. Exit code 0, or 1 when the document or part doesn't exist |

### Bundles and the bundle index

- **A bundle** is one earlier version of `dbhub-session-metrics`: `{"kind":"ContosoCare.RcaBundle","version":1,"sessionId":...,"parts":[...]}` with at most 6 part lines and at most 24,000 bytes of UTF-8 ([fixture](fixtures/metrics-bundle.json)). The runbook writes the bundles first.
- **The bundle index** is the `rca` member of the metrics document in the secret's final version, which the runbook writes last: `{"kind":"ContosoCare.RcaBundleIndex","version":1,"sessionId":...,"bundles":["<version>"],"documents":[{"documentId","parts","sha256"}],"status":...,"message":...}` ([fixture](fixtures/metrics-rca-member.json)), at most 4,000 bytes, inside the metrics document's 24,000. The version IDs are Key Vault's (32 lowercase hex). The deployer's Secrets User grant on the secret covers every version, so nothing needs a new grant.

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
- **Cleanup:** the notebook deletes the file with `notebookutils.fs.rm` once the tables are written, and keeps it when the write fails, so the next run can write it. The deployment notebook's purge removes `Files/rca/inbox` with the eight tables (history-tables.json, `purgeFiles`).

### Limits

| Limit | Value | Why |
|---|---|---|
| A part line | 3,400 characters (2,400 bytes of gzip) | A managed Run Command keeps the last 4 KB of output |
| A document | 64 KiB of gzip (at most 28 parts) | The reducer cuts in reverse priority and records each cut as a gap in `rca_coverage` |
| A session | 96 KiB of gzip across both hosts (at most 64 parts in `RCA_EVIDENCE`) | The reducer aims at 64 KiB; the fixtures measure about 3 KB of gzip for 15 minutes of 10-second blocking detail on one target |
| `RCA_EVIDENCE_FILE` | 262,144 bytes: one `RCA_EVIDENCE` document of 64 parts is about 218 KB | What the notebook passes to `notebookutils.fs.head`, whose default is 100 KB |
| A bundle | 6 parts, 24,000 bytes | The runbook's existing bound for the metrics secret |
| The bundle index | 16 bundles, 4,000 bytes | Inside the metrics document's 24,000 bytes |

## Versioning

- Every kind carries `version` 1. Any change to a field, a column, a type, an encoding rule, or a limit is a new version, with a new schema beside this one.
- A consumer accepts only the versions it knows and reports any other as a **Warning** whose fix is `./scripts/deploy.ps1`, which updates the runner, the runbook, the notebooks, the model, and the app in one run.
- Older pieces degrade and say so: an older runner has no `rca` commands (`RCA.EXPORT` **Warning**); an older notebook ignores `RCA_EVIDENCE`; a session saved before the feature has no RCA rows, and the app says "no RCA capture recorded" for its windows.

## Who builds what in Phase 1

| Step | Builds | Tests against this contract |
|---|---|---|
| 1.1 and 1.2, the capture | The observer lane, its triggers, normalization and names, the local store, `rca export` and `rca part` | Fixture documents round trip through its encoder and decoder; its documents validate against evidence.schema.json; the observer's code names nothing in blind-detection.json; the capture's T-SQL parses (as `SqlScriptTests`) |
| 1.3 to 1.5, the transport and the history | The runbook's export, bundles, and index; the staged `RCA_EVIDENCE_FILE` (and the inline `RCA_EVIDENCE`); the notebook's decoder and the eight tables; the deployment notebook's purge of them and of `Files/rca/inbox`; the model's tables, relationships, and measures | Bundles and the index validate against transport.schema.json; the fixtures' parts decode to the fixture documents; the notebook's tables and the model's TMDL match history-tables.json |
| 1.6, the app | The blind rules, the shared blind detector, the DAX loader, the six Phase 1 tools, the RCA view, the postmortem's Cause, the chat's blindness, the gating | Its loader's names match history-tables.json; its rules find the fixtures' facts ([fixtures](fixtures/README.md)); its detection code names nothing in blind-detection.json |
