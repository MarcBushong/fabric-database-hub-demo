# Log-rate pressure

The Azure SQL Database-flavoured write incident (plan §9.3). Default target T3; runs on any target.

- **Definition:** [`scenario.json`](scenario.json) (5 minutes by default, 15 at most; 2 sessions; `maxLogMb` 2,048 by default, 1,024 on T2).
- **Procedure:** `demo.usp_scenario_log_rate_pressure`: batches of 3,000-byte rows into `demo.log_rate_scratch`, each deleted right after it commits, so data size stays flat while the log keeps working. The run asks for 2 MB of log per second per intensity level (10 MB/s at the default), unthrottled at 10.
- **Bounds:** each session stops after its share of `maxLogMb` (an estimate of the log it generated), at the deadline, or on a stop request. `demo.usp_check_space` checks the log headroom on SQL Server first, and the runner checks local free space on T1 and T2.
- **Expected signals:** on T3, the `Log Rate Governor` wait category (`LOG_RATE_GOVERNOR`) and `avg_log_write_percent` near 100; on T1 and T2 (simple recovery), `WRITELOG` waits and rising `Log Bytes Flushed/sec`.
- **Reset:** auto-cleanup and reset truncate `demo.log_rate_scratch`. On T3 the service backs up and truncates the log; on T1 and T2 checkpoints do.

```powershell
ContosoCare.Workload run --target T3 --server <logical server> --scenario log-rate-pressure --intensity 6
```
