# The contract's fixtures

Two evidence documents from one control session of the 2026-11-20 Run all (times UTC; the session ran 11:22 to 12:52 ET), shaped from the design spike's scenario fixtures, and the transport forms that carry them. Every component's tests read these files, so a change to them is a contract change ([versioning](../README.md#versioning)).

| File | What it is |
|---|---|
| [t1-blocking-chain.evidence.json](t1-blocking-chain.evidence.json) | sqlvm01's export 1: T1, 16:50 to 17:05. A blocking chain under an idle transaction, with lock escalations and lock timeouts |
| [t4-replica-lag.evidence.json](t4-replica-lag.evidence.json) | sqlvm01's export 2 (final): T4 and its replica, 17:00 to 17:20. A chain under a session idle in transaction, and a replay stall on the replica |
| [t1-blocking-chain.parts.txt](t1-blocking-chain.parts.txt), [t4-replica-lag.parts.txt](t4-replica-lag.parts.txt) | Each document as the runner prints it: part lines of its gzip, which decode back to the document |
| [export-index.json](export-index.json) | What `rca export` printed after `DBHUBDEMO-RCA-INDEX` |
| [metrics-bundle.json](metrics-bundle.json) | One earlier version of `dbhub-session-metrics`, as the runbook writes it |
| [metrics-rca-member.json](metrics-rca-member.json) | The `rca` member of the secret's final version (fake version IDs) |
| [rca-evidence.parameter.json](rca-evidence.parameter.json) | `RCA_EVIDENCE` for the session: every part line of both documents |

**Provenance.** The values are the scenarios' shapes, not a measurement: their parameters (the showcase's defaults), their procedures' own statements, and the 10-second, 5-second, and 30-second cadences of [the triggers](../README.md#capture-triggers). Where the owner measured the live session, the documents agree: T4's replica's Azure Monitor lag was 45, 106, and 166 s at 17:12, 17:13, and 17:14 UTC and 1 s at 17:15, and the replica's `since_last_replayed_s` here is 45.4, 105.4, and 165.4 s at those minutes and 0.4 s at 17:15. The session ID, the run IDs, and the secret version IDs are fakes. The module names are the workload's realistic ones since 2026-11-23 ([ADR 0031, decision 6](../../docs/adr/0031-incident-rca.md#2-names)); the run IDs keep the runner's earlier form, still a valid run ID, so the run tokens stay as they were.

**Blind.** The detection tables name no scenario and carry no run ID or workload-reported event: program names are `ContosoCare.Demo`, with a run token. The answer key, with its own string dictionary, holds the three runs and their events.

**Changing a document.** Edit its JSON, then run `./tests/Update-RcaFixtures.ps1`: it writes the part lines again for each document whose parts no longer decode to it, as the runner's `PartCodec` does, and puts the new lines and SHA-256 in every other fixture file. A second run changes nothing. With `-RenameWorkloadModules`, it first renames the workload's retired module names (`demo.usp_scenario_*` and its helpers) to their realistic ones, in every document here and in each file you pass with `-Path`, such as an app test that quotes one. `Rca.Contract.Tests.ps1` fails while a fixture, or an RCA test or its data, still names a retired module.

## What a blind RCA finds here

The app's tests assert these facts from the detection tables alone, and the grading tests match them against the answer key.

**T1 (t1-blocking-chain):**

- 42 blocking samples (capture times with a waiter) from 16:52:30 to 17:00:40; the peak is 7 blocked sessions at 16:52:30; the chain formed 5 times.
- The head blocker is session 63, sleeping with 1 open transaction, idle up to 79 s, holding X on a KEY of `[care].[work_queues]` (`pk_work_queues`); last call `scheduling.usp_assign_work_item;1`; login `NT AUTHORITY\SYSTEM`, host `SQLVM01`, program `ContosoCare.Demo`.
- Two branches, 4 levels deep (63, then 64 and 65, then 66 and 67, then 68 and 69), waiting `LCK_M_U`; the longest single wait is 58 s.
- Session 71 held an X lock on OBJECT `[care].[appointments]` at 16:52:30, 16:54:30, 16:56:30, and 16:58:30, with session 74 waiting `LCK_M_IS` behind it; `lock_escalation` events at 16:52:20, 16:54:20, 16:56:20, and 16:58:20 (6,248 locks to an X table lock).
- 30 lock timeouts (error 1222, severity 16, all intercepted), 6 a minute at 16:53, 16:54, 16:56, 16:58, and 17:00, in `[scheduling].[usp_route_work_item]`.
- The capture episode `T1-20261120T165230Z` started at 16:52:30 (`processes_blocked` 7) and ended at 17:01:40.
- The answer key: blocking-chain 16:52 to 17:02 and log-flush-waits 16:54 to 17:02 (no detection table shows the log flushes: that's Phase 2's waits, and a grading test must count it as not yet investigated, not as a miss).

**T4 and its replica (t4-replica-lag):**

- T4: 45 blocking samples from 17:02:30 to 17:11:20; 4 formations; the head blocker is session 20432, `idle in transaction`, `Client:ClientRead`, idle up to 109.8 s, holding its transaction's locks on `care.work_queues`; 3 sessions (9772, 20584, 35660) wait on it with `Lock:transactionid`, up to 20 s each.
- The replica: replay stood still from 17:11:15 (the startup process's lock wait began then, by `conflict_wait_start_utc`), behind session 41872, which held `AccessShareLock` on `demo.replica_lag_marks`, while replay waited for `AccessExclusiveLock`; `since_last_replayed_s` peaked at 175.4 s at 17:14:10 with 178,500 bytes received and not replayed; replay resumed at 17:14:15. Nothing was cancelled (`conflicts_cancelled` 0 after the first sample; `max_standby_streaming_delay_s` 600, read when the episode started).
- The primary shipped normally: write lag at most 0.001 s and flush lag 0.002 s, at 1,020 bytes of WAL a second. So neither the network nor the write volume caused the lag.
- The replica's capture episode `T4-replica-20261120T171200Z` started at 17:12:00 (45.4 s, 45,900 bytes) and ended at 17:14:25; T4's `T4-20261120T170230Z` ran from 17:02:30 to 17:12:20.
- The answer key: locking-blocking 17:02 to 17:12 and replica-lag 17:11 to 17:15, with their events.
