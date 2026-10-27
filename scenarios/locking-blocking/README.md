# Locking and blocking

The incident for T1 (and any target): blocking from an application that forgot to commit, plus long transactions.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 3 blocked sessions by default).
- **Sessions:** at least two, all tagged `ContosoCare.Demo/locking-blocking/<run>`:
  - **The holder** updates the first `hotRows` Billing work items in an open transaction, then sits idle (status sleeping, one open transaction) for `holdSeconds`, never past the deadline. It always rolls back (the watchdog rollback), pauses `pauseSeconds`, and repeats. With `holder=active-wait`, `demo.usp_scenario_locking_hold` does the same inside one T-SQL call.
  - **Contenders** (`demo.usp_scenario_locking_contend`) keep trying to claim those items; each attempt waits at most 20 seconds for the lock and rolls back. Their UPDATEs block under row versioning too, and their READCOMMITTEDLOCK reads show a blocked reader.
  - **Normal workers** (`normalWorkers`, default 1) run the healthy baseline beside the incident.
  - **The optional deadlock** (`deadlock=true`, at most 3 rounds): two sessions lock two inventory rows in opposite order; the low-priority side is the victim (error 1205) and both roll back.
- **Evidence:** `demo.scenario_run_events` records holder-acquired and holder-rolled-back with session IDs and timestamps; `status` shows the blocking chain while it runs.
- **Expected signals:** `Processes blocked` above 0, Lock waits (`LCK_M_U`, `LCK_M_S`), `Active Transactions`, the head blocker in `SqlServerActiveSessions`, and `Number of Deadlocks/sec` with the deadlock option.
- **Reset:** `reset` stops the run, kills leftover `ContosoCare.Demo/` sessions in this database only, and verifies that no demo transaction is still open. It never touches other sessions.

```powershell
ContosoCare.Workload run --target T1 --scenario locking-blocking --duration 10m --param holdSeconds=120 --param deadlock=true
```
