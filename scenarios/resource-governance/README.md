# Resource governance (CPU cap)

The Azure SQL Database-flavoured CPU incident (plan §9.3): sound plans, too much demand. Default target T3; runs on any target.

- **Definition:** [`scenario.json`](scenario.json) (5 minutes by default, 20 at most; 4 sessions, more than the serverless database's vCores).
- **Procedure:** `demo.usp_scenario_resource_governance`: a full utilization rollup with a per-row scoring hash, parallelism allowed. Intensity sets the hashing passes and shortens the pause.
- **What it shows:** on T3, CPU at the service objective's limit (`SqlServerCPUUtilization` at the tier limit, `avg_cpu_percent` near 100 in `sys.dm_db_resource_stats`); on T1 and T2, plain CPU saturation. Unlike [cpu-pressure](../cpu-pressure/README.md), the fix is capacity or scheduling, not a rewrite.
- **Cost:** it consumes serverless vCore seconds (and the free offer's monthly allowance) while it runs; keep runs short on T3.
- **Reset:** read-only; once no session is open, T3 auto-pauses after its delay.

```powershell
ContosoCare.Workload run --target T3 --server <logical server> --scenario resource-governance --duration 5m
```
