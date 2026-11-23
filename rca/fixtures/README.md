# The contract's fixtures

Two evidence documents from one control session of the 2026-11-20 Run all (times UTC; the session ran 11:22 to 12:52 ET), shaped from the design spike's scenario fixtures, and the transport forms that carry them. Three sidecars (since 2026-11-23): two from the same session and one from a save the next morning, with their transport forms. Every component's tests read these files, so a change to them is a contract change ([versioning](../README.md#versioning)).

| File | What it is |
|---|---|
| [t1-blocking-chain.evidence.json](t1-blocking-chain.evidence.json) | sqlvm01's export 1: T1, 16:50 to 17:05. A blocking chain under an idle transaction, with lock escalations and lock timeouts |
| [t4-replica-lag.evidence.json](t4-replica-lag.evidence.json) | sqlvm01's export 2 (final): T4 and its replica, 17:00 to 17:20. A chain under a session idle in transaction, and a replay stall on the replica |
| [t1-blocking-chain.parts.txt](t1-blocking-chain.parts.txt), [t4-replica-lag.parts.txt](t4-replica-lag.parts.txt) | Each document as the runner prints it: part lines of its gzip, which decode back to the document |
| [export-index.json](export-index.json) | What `rca export` printed after `DBHUBDEMO-RCA-INDEX` |
| [metrics-bundle.json](metrics-bundle.json) | One earlier version of `dbhub-session-metrics`, as the runbook writes it |
| [metrics-rca-member.json](metrics-rca-member.json) | The `rca` member of the secret's final version (fake version IDs) |
| [rca-evidence.parameter.json](rca-evidence.parameter.json) | `RCA_EVIDENCE` for the session: every part line of both documents |
| [t3-plan-regression.sidecar.json](t3-plan-regression.sidecar.json) | sqlvm01's sidecar 1: T3's Query Store, 16:50 to 17:20. A lookup's plan regressed, and automatic plan correction forced its last good plan |
| [t4-query-store.sidecar.json](t4-query-store.sidecar.json) | sqlvm01's sidecar 2: T4's Query Store, 17:00 to 17:20, beside t4-replica-lag's chain; 17:15 to 17:20 pending publication |
| [t4-connection-surge.sidecar.json](t4-connection-surge.sidecar.json) | A save's sidecar outside a control session (no session ID), 2026-11-21 10:00 to 10:20: who held T4's connections during a surge |
| `*.sidecar-parts.txt` | Each sidecar in `DBHUBDEMO-RCAS` part lines of its gzip, the form the runner prints. The parts are illustrative: the runner's gzip level and number forms (`1980` where these have `1980.0`) give other bytes for the same document. So a test compares decoded documents, never parts' bytes, and the SHA-256s in sidecar-index.json and rca-sidecar.parameter.json are these parts' |
| [sidecar-index.json](sidecar-index.json) | What `rca sidecar-export` printed after `DBHUBDEMO-RCAS-INDEX` at a save on 2026-11-21 10:25: the surge's sidecar new, the session's two pending |
| [rca-sidecar.parameter.json](rca-sidecar.parameter.json) | The `RCA_SIDECAR_FILE` document that save staged: every part line of the three |
| [rca-ack.json](rca-ack.json) | The notebook's acknowledgement of that file: the first sidecar already written by an earlier run, the other two written |
| [sidecar-bundle.json](sidecar-bundle.json) | Run all's path: the stop's sidecar bundle for the 2026-11-20 session, an earlier version of `dbhub-session-metrics` holding T3's and T4's Query Store sidecars, three `DBHUBDEMO-RCAS` lines ([Run all's path](../README.md#run-alls-path-for-the-sidecars)) |
| [sidecar-bundle-index.json](sidecar-bundle-index.json) | Its sidecar bundle index, a version of its own: the bundle, and the two sidecars it holds whole |
| [metrics-rca-sidecars-member.json](metrics-rca-sidecars-member.json) | The metrics document's `rcaSidecars` pointer to that index, in the session's final version |
| [rca-ack-request.json](rca-ack-request.json) | The next start's `rcaAcks`: the two sidecars, once the save's `-runall-` acknowledgement says they're written |
| [rca-ack-result.json](rca-ack-result.json) | That start's status, `rcaAcks`: both acknowledged on sqlvm01 before its exports |

**Provenance.** The values are the scenarios' shapes, not a measurement: their parameters (the showcase's defaults), their procedures' own statements, and the 10-second, 5-second, and 30-second cadences of [the triggers](../README.md#capture-triggers). Where the owner measured the live session, the documents agree: T4's replica's Azure Monitor lag was 45, 106, and 166 s at 17:12, 17:13, and 17:14 UTC and 1 s at 17:15, and the replica's `since_last_replayed_s` here is 45.4, 105.4, and 165.4 s at those minutes and 0.4 s at 17:15. The session ID, the run IDs, and the secret version IDs are fakes.

**Blind.** The detection tables name no scenario and carry no run ID or workload-reported event: program names are `ContosoCare.Demo`, with a run token. The answer key, with its own string dictionary, holds the three runs and their events.

## What a blind RCA finds here

The app's tests assert these facts from the detection tables alone, and the grading tests match them against the answer key.

**T1 (t1-blocking-chain):**

- 42 blocking samples (capture times with a waiter) from 16:52:30 to 17:00:40; the peak is 7 blocked sessions at 16:52:30; the chain formed 5 times.
- The head blocker is session 63, sleeping with 1 open transaction, idle up to 79 s, holding X on a KEY of `[care].[work_queues]` (`pk_work_queues`); last call `demo.usp_scenario_chain_acquire;1`; login `NT AUTHORITY\SYSTEM`, host `SQLVM01`, program `ContosoCare.Demo`.
- Two branches, 4 levels deep (63, then 64 and 65, then 66 and 67, then 68 and 69), waiting `LCK_M_U`; the longest single wait is 58 s.
- Session 71 held an X lock on OBJECT `[care].[appointments]` at 16:52:30, 16:54:30, 16:56:30, and 16:58:30, with session 74 waiting `LCK_M_IS` behind it; `lock_escalation` events at 16:52:20, 16:54:20, 16:56:20, and 16:58:20 (6,248 locks to an X table lock).
- 30 lock timeouts (error 1222, severity 16, all intercepted), 6 a minute at 16:53, 16:54, 16:56, 16:58, and 17:00, in `[demo].[usp_scenario_chain_link]`.
- The capture episode `T1-20261120T165230Z` started at 16:52:30 (`processes_blocked` 7) and ended at 17:01:40.
- The answer key: blocking-chain 16:52 to 17:02 and log-flush-waits 16:54 to 17:02 (no detection table shows the log flushes: that's Phase 2's waits, and a grading test must count it as not yet investigated, not as a miss).

**T4 and its replica (t4-replica-lag):**

- T4: 45 blocking samples from 17:02:30 to 17:11:20; 4 formations; the head blocker is session 20432, `idle in transaction`, `Client:ClientRead`, idle up to 109.8 s, holding its transaction's locks on `care.work_queues`; 3 sessions (9772, 20584, 35660) wait on it with `Lock:transactionid`, up to 20 s each.
- The replica: replay stood still from 17:11:15 (the startup process's lock wait began then, by `conflict_wait_start_utc`), behind session 41872, which held `AccessShareLock` on `demo.replica_lag_marks`, while replay waited for `AccessExclusiveLock`; `since_last_replayed_s` peaked at 175.4 s at 17:14:10 with 178,500 bytes received and not replayed; replay resumed at 17:14:15. Nothing was cancelled (`conflicts_cancelled` 0 after the first sample; `max_standby_streaming_delay_s` 600, read when the episode started).
- The primary shipped normally: write lag at most 0.001 s and flush lag 0.002 s, at 1,020 bytes of WAL a second. So neither the network nor the write volume caused the lag.
- The replica's capture episode `T4-replica-20261120T171200Z` started at 17:12:00 (45.4 s, 45,900 bytes) and ended at 17:14:25; T4's `T4-20261120T170230Z` ran from 17:02:30 to 17:12:20.
- The answer key: locking-blocking 17:02 to 17:12 and replica-lag 17:11 to 17:15, with their events.

## What a blind RCA finds in the sidecars

The sidecars name no scenario: their statements are the procedures' own, normalized, and their program names `ContosoCare.Demo` with a run token. **Simplified here:** T3's first read looks back from 16:15, not 2 hours before 16:50, so the fixture holds 3 intervals of baseline. T4's top-level calls of the workload's functions are left out until the realistic names land.

**T3 (t3-plan-regression):**

- Query 412 is `[demo].[usp_visit_summary_lookup]`'s count of a patient range's appointments.
  - **Plan 31:** an Index Seek on `ix_appointments_patient` with a Key Lookup, estimated cost 0.0331. It ran 1,180 to 1,204 times per 15-minute interval from 16:15 to 17:00, at 2.1 ms of CPU each.
  - **Plan 58:** a parallel Clustered Index Scan of `pk_appointments` at DOP 4, estimated cost 38.6, compiled at 17:03:11; its first execution ended at 17:03:12.6. It ran 524 times, to 17:09:40.2, at 176 ms of CPU each (92,224 ms), with 4,100 logical reads each and 31,440 ms of waits: CPU 18,900, Parallelism 11,620, and Buffer IO 920.
- **The 17:00 interval is mixed:** plan 31 also ran 668 times in it (1,403 ms). Plan 58 used 96 % of the captured top queries' CPU in that interval (92,224 of 95,644 ms).
- **The response, as measured:**
  - automatic tuning's recommendation for query 412 appeared, Active, between 17:05:30 and 17:06:00: force plan 31 over plan 58, CPU time per execution 2.1 ms against 176 ms;
  - FORCE_LAST_GOOD_PLAN was Executing at 17:09:30;
  - plan 31 was forced (AUTO) between 17:09:00 and 17:10:00; its last compile was 17:09:41;
  - the recommendation was Verifying at 17:10:30;
  - from 17:15 (the interval still open at the final read, 17:20:10), plan 31 ran alone, at 2.1 ms each.
- **Other statements are evidence too:** query 377 (an ad hoc patient list), and query 902, another application's read of `sys.dm_exec_requests`, with its plan 40.
- **Plans:** a plan's row is written when a read first returns it, and again when it changes. So plan 31 has a row at 16:50 and one at 17:17, forced; plans 58 and 40 one each, at 17:17; and the final read writes none.
- **Coverage:** READ_WRITE, capture mode AUTO, 15-minute intervals, intervals read from 16:15 to 17:30.

**T4 (t4-query-store):**

- **17:00 to 17:15:** the chain's UPDATE of `care.work_queues` (query -6412873301142229951, role `contosocare_runner`) ran 214 times in 251,300 ms, the longest 20,050 ms. Its sampled waits were `Lock:transactionid` 2,480 times (about 248 s at 100 ms a sample) and `LWLock:LockManager` 6.
- **16:45 to 17:00, its baseline:** 220 calls in 61.6 ms, with no lock waits.
- **Beside it:**
  - the queue's claim (`FOR UPDATE`), 30 calls;
  - the replica's marks, 1,792 inserts with `IO:WALSync` 14;
  - another role's size check, with no login.
- **Query IDs are 64-bit hashes,** past what a JavaScript number holds exactly (2^53): readers take them as text.
- **Coverage:** 17:15 to 17:20 is pending publication. T4-replica records nothing in Query Store, which its coverage row says.

**T4's connection surge (t4-connection-surge; no session):**

- **The episode** ran from 10:06:00 to 10:11:50, with a sample every 10 s (36), and one at 10:12:00 when it ended.
- **Who held the slots:**
  - the run with token `7c3e91a05bd2` held 28 idle connections at 10:06:00, and 36 from 10:10:00 to 10:11:50; its oldest had been idle 40 s at the first sample and 390 s at the last;
  - beside it, 2 active connections of the run with token `2fa86c14e9b0`, and 3 idle ones of another application, which carry no program or login;
  - the peak is 41, from 10:10:00. At 10:12:00, the surge's idle connections were gone.
- **Query Store** holds one statement per connection, a patient lookup, 452 calls. 10:15 to 10:20 is pending publication.
