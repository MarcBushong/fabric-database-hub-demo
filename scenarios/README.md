# Scenarios

Bounded, repeatable workloads for the Contoso Care demo ([ADR 0010](../docs/adr/0010-workload-generator-technology.md)). Each folder has a `scenario.json` (limits, parameters, target applicability, expected Hub signals, and expected symptoms) validated against [`scenario.schema.json`](scenario.schema.json); the T-SQL lives in [`database/common/120-scenario-procedures.sql`](../database/common/120-scenario-procedures.sql), and the runner in [`workload-generator`](../workload-generator/README.md) embeds these files at build time.

| Scenario | Default targets | Default / maximum | What it shows |
|---|---|---|---|
| [healthy-baseline](healthy-baseline/README.md) | T1, T2, T3 | 30 min / 4 h | The steady OLTP mix: the "before" picture and the `baseline` profile |
| [locking-blocking](locking-blocking/README.md) | T1 | 10 / 30 min | An idle head blocker with an open transaction, blocked clerks, an optional bounded deadlock |
| [cpu-pressure](cpu-pressure/README.md) | T2 | 10 / 30 min | A plan problem that burns CPU, with a healthy indexed variant for the "after" |
| [io-pressure](io-pressure/README.md) | T2 | 10 / 30 min | Bounded reads and writes over a capped scratch set, after a free-space check |
| [missing-index](missing-index/README.md) | T2 | 10 / 30 min | Before, recommendation, human-approved action, after |
| [inefficient-query](inefficient-query/README.md) | T2, T3 | 10 / 30 min | A frequent non-SARGable lookup, with a healthy variant for Query Store comparisons |
| [resource-governance](resource-governance/README.md) | T3 | 5 / 20 min | CPU at the service objective's cap with sound plans (Azure SQL Database flavour) |
| [log-rate-pressure](log-rate-pressure/README.md) | T3 | 5 / 15 min | Log-rate governance on Azure SQL Database, WRITELOG on SQL Server |
| [blocking-chain](blocking-chain/README.md) | T1 | 10 / 30 min | A blocking chain 3 to 6 sessions deep under one head blocker, plus a table lock from lock escalation |
| [deadlock-storm](deadlock-storm/README.md) | T1 | 10 / 30 min | Pairs that deadlock round after round (error 1205), bounded and recorded |
| [tempdb-contention](tempdb-contention/README.md) | T2 | 10 / 30 min | Many sessions creating and dropping temporary tables: PAGELATCH waits in tempdb |
| [memory-grant-pressure](memory-grant-pressure/README.md) | T2 | 10 / 30 min | Large sorts reserving big memory grants: RESOURCE_SEMAPHORE queueing |
| [parallel-scans](parallel-scans/README.md) | T2 | 10 / 30 min | Parallel reports, chosen by cost, over a skewed key: CXPACKET and CXCONSUMER waits |
| [log-flush-waits](log-flush-waits/README.md) | T1 | 10 / 30 min | One commit per row: many short WRITELOG waits |
| [slow-consumer](slow-consumer/README.md) | T3 | 10 / 30 min | A client that reads slowly: ASYNC_NETWORK_IO |
| [capacity-max](capacity-max/README.md) | T1, T2, T3 | 10 / 20 min | Every scheduler busy and the storage at its cap at the same time |
| [connection-surge](connection-surge/README.md) | T4 | 5 / 15 min | Connections climb to max_connections and past it (refused, bounded), the PostgreSQL capacity ceiling |
| [idle-in-transaction](idle-in-transaction/README.md) | T4 | 10 / 30 min | Sessions idle in an open transaction block writers and hold back vacuum |

Every SQL scenario runs on T1, T2, and T3, because the Database Agent's target coverage isn't documented ([ADR 0013](../docs/adr/0013-agent-experience.md)); the default targets follow the [architecture](../docs/architecture.md#data-and-workload).

**T4, the PostgreSQL flexible server** ([ADR 0019](../docs/adr/0019-t4-postgresql-flexible-server.md)), runs healthy-baseline, cpu-pressure, locking-blocking, io-pressure, connection-surge, and idle-in-transaction, with the same names, runner commands, and bounds; their PostgreSQL functions are in [database/postgresql](../database/postgresql/README.md). On T4, cpu-pressure saturates its one Burstable vCore, locking-blocking shows row-lock queues (Lock waits, idle in transaction holders, optional deadlocks), and io-pressure pushes the Burstable IOPS cap. On the larger sizes (`Standard_B2s`, or the General Purpose `Standard_D2ds_v5` with two vCores), cpu-pressure and io-pressure load the server less, and connection-surge stops at its `maxConnections` cap before the server's limit, so nothing is refused ([connection-surge](connection-surge/README.md)). Database Hub shows T4's Azure Monitor metrics only, so each scenario's T4 signals are metrics (sessions by state and by wait event type, the oldest transaction, deadlocks, connections), and ContosoCare.Workload status --target T4 shows the sessions behind them. [`activity-profiles.json`](activity-profiles.json) schedules them for the `baseline`, `business-day`, and `incident:<scenario>` profiles.

## Waits and signals by scenario and target (Phase 25b)

The wait categories are the `WaitCategory` values of `SqlServerWaitStats`, and the counters are in `SqlServerPerformanceCountersCommon`, as documented on Database Hub's [query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry) page (checked 2026-10-23). Counters marked *Detailed* are in `SqlServerPerformanceCountersDetailed` only if the target lists them (that page's Schema section has the query that lists them).

| Scenario | Wait categories (wait types) | Counters and other signals | T1 and T2 (SQL Server 2022) | T3 (Azure SQL Database, serverless, 1 vCore at most) |
|---|---|---|---|---|
| blocking-chain | Lock (`LCK_M_U`; `LCK_M_IS`, `LCK_M_IX` behind an escalation) | `Processes blocked`, `Active Transactions`; *Detailed:* lock escalations | Chains and table-lock escalation as designed | Optimized locking: links wait on transaction-ID locks (`LCK_M_S_XACT_MODIFY`); no escalation |
| deadlock-storm | Lock (`LCK_M_X`, `LCK_M_U`) until a victim is picked | `Number of Deadlocks/sec`, `Errors/sec` | As designed | As designed; deadlock graphs show `xactlock` resources |
| tempdb-contention | Buffer Latch (`PAGELATCH_EX`, `PAGELATCH_SH`, `PAGELATCH_UP`), Compilation | `Temp Tables Creation Rate`, `Active Temp Tables`, `Free Space in tempdb (KB)`, `SQL Re-Compilations/sec` | As designed | Fewer sessions run at once: fewer latch waits, more CPU waits |
| memory-grant-pressure | Memory (`RESOURCE_SEMAPHORE`) | `Granted Workspace Memory (KB)`, `Page life expectancy`; *Detailed:* `Memory Grants Pending` | As designed (8 GiB VMs) | The queue forms sooner within the service objective's memory |
| parallel-scans | Parallelism (`CXPACKET`, `CXCONSUMER`, `CXSYNC_PORT`), CPU | CPU in `SqlServerCPUUtilization` | DOP 2 (2 vCPUs) | No second scheduler: serial plans, CPU waits instead |
| log-flush-waits | Tran Log IO (`WRITELOG`) | `Log Flushes/sec` (SQL Server only), `Log Bytes Flushed/sec`, `Transactions/sec`, `Write Transactions/sec`; log-file writes in `SqlServerStorageIO` | As designed | `WRITELOG`, plus Log Rate Governor past the log-rate limit |
| slow-consumer | Network IO (`ASYNC_NETWORK_IO`) | `SQL Attention rate` | The client is the runner on the same machine | The client is T1's runner across the network |
| capacity-max | CPU (`SOS_SCHEDULER_YIELD`), Buffer IO (`PAGEIOLATCH_SH`) | CPU near 100 in `SqlServerCPUUtilization`, IO stalls in `SqlServerStorageIO` | Every scheduler busy, the disk's caps | CPU at the vCore limit, `IOStallQueuedReadMs` from IO governance |

Combine scenarios on one target for multi-wait profiles (at most four runs at once per database, one per scenario): for example `capacity-max` with `blocking-chain`, or `memory-grant-pressure` with `parallel-scans`. `SqlServerActiveSessions` lists sessions but not their waits or blockers, so chain depth shows in the DMVs (`sys.dm_exec_requests.blocking_session_id`) and in each run's events, not in the telemetry.

## Rules every scenario follows

- **Bounded:** a hard maximum duration (also enforced in T-SQL by `demo.usp_run_begin`), a concurrency range, and an intensity from 1 to 10. Loops end at the run's deadline or within about a second of a stop request.
- **Isolated:** only the `ContosoCare` database (`contosocare` on T4), only sessions named `ContosoCare.Demo/<scenario>/<run>`. The one exception is `tempdb-contention`'s temporary tables, which belong to its own sessions and are dropped every iteration, as any `#table` in tempdb.
- **Recorded:** `demo.scenario_runs` holds every run (ID, scenario, target, start, deadline, stop, parameters, expected symptoms, outcome, session IDs); `demo.scenario_run_events` holds session IDs and timestamps.
- **Recoverable:** business data comes back as seeded (transactions roll back, the baseline toggles values within their ranges), scratch data is capped and emptied by auto-cleanup and reset, and reset verifies that no demo transaction is still open.
- **Human-approved remediation:** the missing-index fix is a script a person runs ([`missing-index/remediation.sql`](missing-index/remediation.sql)); nothing applies it automatically.

## Run one

```powershell
ContosoCare.Workload scenarios locking-blocking
ContosoCare.Workload run --target T1 --scenario locking-blocking --duration 10m --param holdSeconds=120
ContosoCare.Workload stop --target T1 --scenario locking-blocking
ContosoCare.Workload reset --target T1
```

Without the runner (for example from SSMS), register a run first, then call the procedure:

```sql
DECLARE @deadline datetime2(3);
EXEC demo.usp_run_begin @run_id = 'manual-1', @scenario_id = 'locking-blocking', @target = 'T1',
    @duration_seconds = 300, @concurrency = 1, @intensity = 5, @deadline_at = @deadline OUTPUT;
EXEC demo.usp_scenario_locking_hold @run_id = 'manual-1', @hold_seconds = 120;     -- session 1: the head blocker
EXEC demo.usp_scenario_locking_contend @run_id = 'manual-1', @worker = 1;           -- session 2: blocked
EXEC demo.usp_run_end @run_id = 'manual-1', @status = 'Completed';
```
