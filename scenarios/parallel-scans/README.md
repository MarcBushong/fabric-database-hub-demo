# Parallelism waits

Parallel plans whose threads wait on one another, for T2 (and any target) (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 4 sessions by default, 8 at most).
- **Sessions:** `concurrency` sessions tagged `ContosoCare.Demo/parallel-scans/<run>`, each running `demo.usp_scenario_parallel_scans`: a reporting aggregate over appointments and their encounters (times 40, plus 20 per intensity level), grouped by status and facility, back to back.
- **The plan:** no hint forces parallelism. The report's estimated cost is well above the default [cost threshold for parallelism](https://learn.microsoft.com/sql/database-engine/configure-windows/configure-the-cost-threshold-for-parallelism-server-configuration-option) (5), so the optimizer picks a parallel plan by cost, at most at the `MAXDOP maxdop` query hint (validated, placed in the statement text because a hint needs a literal); SQL Server never uses more threads than it has schedulers. Each query's coordinating thread waits for its workers (`CXCONSUMER`), the workers wait at the exchanges (`CXPACKET`), and grouping by status, a skewed key, leaves them uneven work. The query uses every column it computes, so the optimizer can't skip the per-row work.
- **Expected signals:** Parallelism waits (`CXPACKET`, `CXCONSUMER`, `CXSYNC_PORT`), high CPU, and CPU waits (`SOS_SCHEDULER_YIELD`) when sessions outnumber schedulers.
- **By target:** T1 and the T2 guest have 2 vCPUs, so plans run at DOP 2. Azure SQL Database (T3) at 1 vCore or less has no second scheduler, so the plans run serially there: expect CPU waits, not Parallelism waits. SQL Server Express, such as the LocalDB the integration tests use, ran the same report serially, so the parallel plan is confirmed only on T1 and T2.
- **Reset:** read-only; nothing to undo.

```powershell
ContosoCare.Workload run --target T2 --scenario parallel-scans --duration 10m --concurrency 6 --param maxdop=2
```
