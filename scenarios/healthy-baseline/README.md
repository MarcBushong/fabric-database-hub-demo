# Healthy baseline

A steady Contoso Care OLTP mix on any target: front-desk patient lookups, provider schedules, billing balances, check-ins, work-queue triage, supply updates, and audit events. It's the `baseline` activity profile, the "before" picture for every incident, and the optional normal workload next to the locking scenario.

- **Definition:** [`scenario.json`](scenario.json) (30 minutes by default, 4 hours at most; 2 sessions; intensity 3).
- **Procedure:** `demo.usp_scenario_healthy_baseline`: short, indexed statements; each session waits at most 10 seconds for a lock, so an incident beside it delays it without stalling it.
- **Expected signals:** steady `Batch Requests/sec` and `Transactions/sec`, low CPU, `Processes blocked` at 0, and no Database Agent finding.
- **Data:** check-ins toggle between Scheduled and CheckedIn, priorities stay within 1 to 5, stock stays above its reorder level, and the workload's audit rows are trimmed after an hour; auto-cleanup and reset remove them.
- **T3:** while it runs, the serverless database stays awake; the T3 baseline in the profiles uses one session at intensity 2.
- **T5 (Cosmos DB for NoSQL):** the runner's REST client sends 40% point reads, 40% upserts, and 20% single-partition queries (a patient's five latest documents) over 500 patients, `p-0001` to `p-0500`, in `contosocare/patient-events`, at the same pace. Upserts overwrite each patient's profile document (`patient`) and 20 events (`hb-ev-0` to `hb-ev-19`), 0.7 to 0.9 KB each, so the data never grows; nothing needs deleting ([data model](../../database/cosmosdb/README.md)). The T5 baseline in the profiles uses one session at intensity 2, a few RU/s against the container's 400.

```powershell
ContosoCare.Workload run --target T2 --scenario healthy-baseline --duration 15m
```
