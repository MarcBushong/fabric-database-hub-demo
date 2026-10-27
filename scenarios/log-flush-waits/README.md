# Log flush waits

Commit-heavy singleton inserts for T1 (and any target): every commit waits for its own log flush (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 8 sessions by default, 16 at most).
- **Sessions:** `concurrency` sessions tagged `ContosoCare.Demo/log-flush-waits/<run>`, each running `demo.usp_scenario_commit_flood`: one 200-byte row per transaction into `demo.commit_scratch`, so every `INSERT` commits on its own and waits for its log flush (`WRITELOG`).
- **Bounds:** at most `maxRows` commits per session (about 0.5 KB of log each), the deadline, and a stop request. Each session deletes its rows every 1,000 inserts and when it ends, so the table stays small; the free-space check runs first. Business data is never touched.
- **How it differs from `log-rate-pressure`:** that scenario writes large batches to reach a log rate (Log Rate Governor on Azure SQL Database); this one maximizes the number of commits, so the signature is many short `WRITELOG` waits.
- **Expected signals:** Tran Log IO waits (`WRITELOG`) with a high waiting-task count and a low average wait; `Log Flushes/sec` (SQL Server only), `Log Bytes Flushed/sec`, `Transactions/sec`, and `Write Transactions/sec`; many small writes to the log file in `SqlServerStorageIO`.
- **By target:** T1 and T2 use simple recovery, so the log truncates at checkpoints and stays under its cap (8 GB on T1, 4 GB on T2). On Azure SQL Database (T3), commits wait on the remote log (`WRITELOG`), and past the service objective's log rate also on Log Rate Governor.
- **Reset:** auto-cleanup and `reset` truncate `demo.commit_scratch`.

```powershell
ContosoCare.Workload run --target T1 --scenario log-flush-waits --duration 10m --concurrency 12
```
