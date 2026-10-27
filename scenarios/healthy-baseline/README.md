# Healthy baseline

A steady Contoso Care OLTP mix on any target: front-desk patient lookups, provider schedules, billing balances, check-ins, work-queue triage, supply updates, and audit events. It's the `baseline` activity profile, the "before" picture for every incident, and the optional normal workload next to the locking scenario.

- **Definition:** [`scenario.json`](scenario.json) (30 minutes by default, 4 hours at most; 2 sessions; intensity 3).
- **Procedure:** `demo.usp_scenario_healthy_baseline`: short, indexed statements; each session waits at most 10 seconds for a lock, so an incident beside it delays it without stalling it.
- **Expected signals:** steady `Batch Requests/sec` and `Transactions/sec`, low CPU, `Processes blocked` at 0, and no Database Agent finding.
- **Data:** check-ins toggle between Scheduled and CheckedIn, priorities stay within 1 to 5, stock stays above its reorder level, and the workload's audit rows are trimmed after an hour; auto-cleanup and reset remove them.
- **T3:** while it runs, the serverless database stays awake; the T3 baseline in the profiles uses one session at intensity 2.

```powershell
ContosoCare.Workload run --target T2 --scenario healthy-baseline --duration 15m
```
