# Deadlock storm

Repeated, bounded deadlocks for T1 (and any target): every pair of sessions deadlocks with itself, round after round (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 2 pairs by default, 8 at most).
- **Sessions:** two per pair, sides 1 and 2, tagged `ContosoCare.Demo/deadlock-storm/<run>`, each running `demo.usp_scenario_deadlock_storm`. Pair P uses inventory rows 100 + 2P - 1 and 100 + 2P (101 to 116), apart from `locking-blocking`'s rows 1 and 2.
- **Shapes** (`shape`):
  - `order`: side 1 locks row A, waits a second, then locks row B; side 2 does B then A.
  - `conversion`: both sides read row A with `HOLDLOCK` (a shared lock kept to the end of the transaction), wait a second, then both update row A.
  - `mixed` (default): alternates the two each round.
- **The victim:** side 2 runs at `DEADLOCK_PRIORITY LOW`, so the deadlock monitor picks it (error 1205). Every round rolls back.
- **Bounds:** at most `maxRounds` rounds per session (so at most `concurrency` x `maxRounds` deadlocks per run), a pause between rounds from the intensity (about 10 seconds at 1, 1 second at 10), and the run's deadline.
- **Evidence:** one `deadlock-victim` event per victim in `demo.scenario_run_events` (pair, shape, round, session ID; 500 events at most per run), and the deadlock graphs in the `system_health` session on SQL Server.
- **Expected signals:** `Number of Deadlocks/sec` above 0 (a cumulative counter, so per-bin deltas), Lock waits until each victim is picked, and `Errors/sec`.
- **By target:** the same on all three. Row versioning on Azure SQL Database doesn't prevent these deadlocks; with its optimized locking the graphs show transaction-ID (`xactlock`) resources.
- **Reset:** every round rolls back, so the inventory rows stay as seeded; `reset` kills leftover `ContosoCare.Demo/` sessions.

```powershell
ContosoCare.Workload run --target T1 --scenario deadlock-storm --duration 5m --concurrency 3 --intensity 8 --param shape=order
```
