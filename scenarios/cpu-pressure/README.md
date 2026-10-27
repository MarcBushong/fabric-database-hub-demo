# CPU pressure

A bounded plan problem, not an infinite loop: a double-booking audit whose overlap test wraps both date columns in `DATEDIFF`, so each execution compares every pair of a provider's appointments instead of seeking `ix_appointments_provider`. Concurrent sessions run it back to back with a short pause. Default target T2; runs on any target.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 2 sessions; each intensity level adds 4 providers per execution).
- **Procedure:** `demo.usp_scenario_cpu_pressure`, `MAXDOP 1` per execution.
- **Before and after:** `--param variant=healthy` asks the same question with a range on `scheduled_start` and nested-loop seeks into the index; in the local tests that cut CPU per execution by more than an order of magnitude. Compare the two queries in Query Store.
- **Expected signals:** `SqlServerCPUUtilization` rising toward 100%, the CPU wait category (`SOS_SCHEDULER_YIELD`), and an expensive-query finding.
- **Reset:** read-only; stopping the run returns CPU to the baseline.

```powershell
ContosoCare.Workload run --target T2 --scenario cpu-pressure --concurrency 2
ContosoCare.Workload run --target T2 --scenario cpu-pressure --concurrency 2 --param variant=healthy
```
