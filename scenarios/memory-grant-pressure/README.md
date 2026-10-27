# Memory grant pressure

Queries queuing for workspace memory on T2 (and any target): concurrent large sorts that each reserve a big memory grant (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 8 sessions by default, 16 at most).
- **Sessions:** `concurrency` sessions tagged `ContosoCare.Demo/memory-grant-pressure/<run>`, each running `demo.usp_scenario_memory_grants`: a row number over appointments times 8 per intensity level, in a scrambled order (a sort at `MAXDOP 1`), back to back.
- **The grant:** the documented `MIN_GRANT_PERCENT` query hint reserves `grantPercent` of the most one query may get, which is 25% of the workspace memory in the default workload group. At the default 100, about four grants fit at once and the other sessions wait in the `RESOURCE_SEMAPHORE` queue. The value is validated (10 to 100) and placed in the statement text, because a query hint needs a literal.
- **Bounds:** no server setting changes; SQL Server never grants more memory than it has, so the excess waits. Nothing is written.
- **Expected signals:** Memory waits (`RESOURCE_SEMAPHORE`), `Granted Workspace Memory (KB)` at its ceiling and `Page life expectancy` falling, and `Memory Grants Pending` in `SqlServerPerformanceCountersDetailed` when the target lists it.
- **By target:** T1 and T2 have 8 GiB of memory; Azure SQL Database (T3) honors the hint within the service objective's memory, so the queue forms sooner at 1 vCore.
- **Reset:** read-only; grants are released when each query ends or its session closes.

```powershell
ContosoCare.Workload run --target T2 --scenario memory-grant-pressure --duration 10m --concurrency 10
```
