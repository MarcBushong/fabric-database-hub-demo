# Capacity maxed out

Every scheduler busy and the storage at its cap at the same time, on every target (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 20 at most; 8 CPU sessions and 4 IO sessions by default).
- **Sessions:** tagged `ContosoCare.Demo/capacity-max/<run>`, all running `demo.usp_scenario_capacity_max`:
  - **CPU sessions** (`concurrency`, role `cpu`): back-to-back CPU-heavy reports (a hash per appointment) at `MAXDOP 1`, one scheduler each. T1 and the T2 guest have 2 vCPUs and T3 at most 1 vCore, so 8 sessions keep every scheduler busy with several runnable tasks each.
  - **IO sessions** (`ioWorkers`, role `io`): range scans of up to 256 MB and 16 MB updates over `demo.io_scratch`. The first one grows it to `scratchMb` after the runner's free-space check and the T-SQL check against the file caps (`demo.usp_io_scratch_grow`, under the same application lock as `io-pressure`, which shares the table). Once the scratch set is bigger than the memory SQL Server can use, reads miss the buffer pool and hit the disk's caps.
- **Defaults by target:** `scratchMb` is 6 GB on T1 (16 GB data cap), 4 GB on T2 (8 GB data cap, 512 MB margin), and 2 GB on T3.
- **Bounds:** 20 minutes at most; business data is only read; the scratch set never grows past `scratchMb` or the file caps.
- **Expected signals:** CPU at or near 100 in `SqlServerCPUUtilization` (`SQLProcessCPUPercent` on SQL Server; `AvgCPUPercent`, of the vCore limit, on Azure SQL Database), CPU waits (`SOS_SCHEDULER_YIELD`) and signal waits, Buffer IO waits (`PAGEIOLATCH_SH`) once the scratch set exceeds memory, and IO stalls on the data file in `SqlServerStorageIO` (on Azure SQL Database, `IOStallQueuedReadMs` from IO governance).
- **Reset:** auto-cleanup and `reset` truncate `demo.io_scratch` when no `io-pressure` or `capacity-max` run still uses it; its space stays allocated in the data file for the next run.

```powershell
ContosoCare.Workload run --target T2 --scenario capacity-max --duration 10m --concurrency 8 --param ioWorkers=4
```
