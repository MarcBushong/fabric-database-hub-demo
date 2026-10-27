# Deep blocking chain and lock escalation

The incident for T1 (and any target): a blocking chain several levels deep under one head blocker, plus a table lock from lock escalation (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 2 branches of depth 4 by default).
- **Sessions,** all tagged `ContosoCare.Demo/blocking-chain/<run>`, 26 at most:
  - **The head blocker** (`demo.usp_scenario_chain_acquire`) updates the first Scheduling work item in an open transaction, then sits idle for `holdSeconds`, never past the deadline. It always rolls back, pauses `pauseSeconds`, and repeats.
  - **Links** (`demo.usp_scenario_chain_link`): for each of the `concurrency` branches, one session per level from 2 to `depth`. Each link locks its own Scheduling work item and then waits for its parent's (level 2 waits for the head blocker), so the next level waits for it. Each wait lasts at most 60 seconds; every change rolls back. The levels start 2 seconds apart, so each finds its parent already holding.
  - **The escalator** (`escalation=true`, `demo.usp_scenario_chain_escalate`): 20 seconds in and then every `escalationEverySeconds`, it updates `escalationRows` consecutive appointments in one statement with row locks, so SQL Server escalates them to a table lock, which it holds for `escalationHoldSeconds` before it rolls back. SQL Server documents escalation past 5,000 locks; on SQL Server 2025 it was measured from about 6,200 rows, so the minimum is 7,000.
  - **Normal workers** (`normalWorkers`, default 1) run the healthy baseline beside the incident and queue behind the table lock.
- **Rows:** the first 21 Scheduling work items, apart from `locking-blocking`'s Billing rows, so the two can run together; any range of appointments for the escalation.
- **Evidence:** `demo.scenario_run_events` records holder-acquired, holder-rolled-back, and one `lock-escalation` event per escalation (rows updated, whether the table lock was taken, how long it was held).
- **Expected signals:** `Processes blocked` at the number of waiting sessions, Lock waits with long single waits (`LCK_M_U` for the links; `LCK_M_IS` and `LCK_M_IX` behind an escalation), `Active Transactions`, and lock escalation counters in `SqlServerPerformanceCountersDetailed` when the target lists them.
- **By target:** T1 and T2 (SQL Server 2022) escalate as described. Azure SQL Database (T3) always uses optimized locking: links wait on transaction-ID locks (`LCK_M_S_XACT_MODIFY`), and the escalator holds one transaction-ID lock instead of row locks, so it doesn't escalate there; its event says `table lock: no`.
- **Reset:** every transaction rolls back. `reset` stops the run, kills leftover `ContosoCare.Demo/` sessions in this database only, and verifies that no demo transaction is still open.

```powershell
ContosoCare.Workload run --target T1 --scenario blocking-chain --duration 10m --concurrency 3 --param depth=5
```
