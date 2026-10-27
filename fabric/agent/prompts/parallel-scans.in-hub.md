---
id: parallel-scans.in-hub
name: Investigate parallelism waits in Database Hub
scenario: parallel-scans
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds parallelism waits on the chosen target, tells parallel queries waiting on their slowest thread from too many queries for the CPUs, and says which workload drives it or where to look. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value, then the likely driver or the place to find it, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry has no plans or degree of parallelism per query, so the agent may not name a query.
fallback: Run parallel-scans.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 4, 5, and 9 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [inefficient-queries, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/database-engine/configure-windows/configure-the-max-degree-of-parallelism-server-configuration-option
  - https://learn.microsoft.com/sql/relational-databases/query-processing-architecture-guide
reviewed: 2026-10-23
---

# Investigate parallelism waits in Database Hub

The incident beat for [parallelism waits](../../../scenarios/parallel-scans/README.md): reporting queries that SQL Server runs with parallel plans by cost, grouped by a skewed key. It runs on T2 by default and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. What the target waits on

```text
Which waits dominate on {target} over the last 30 minutes, and what share is parallelism compared with CPU? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. Skew or too much work

```text
For {incidentWindow} on {target}, did CPU, batch requests, or active sessions move with the parallelism waits? Does it look like a few parallel queries waiting on their slowest thread, or like more work than the CPUs can run? Keep coincidence apart from cause. Don't change anything.
```

### 3. What drives it, and the evidence

```text
Which queries on {target} are most likely running with parallel plans? If Database Hub can't show query-level data, say so and tell me where I can see it. Then list your evidence: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 | Parallelism waits (`CXPACKET`, `CXCONSUMER`, `CXSYNC_PORT`); SQL Server process CPU (`SQLProcessCPUPercent`) high; CPU waits (`SOS_SCHEDULER_YIELD`) when sessions outnumber schedulers | 2 vCPUs, so plans run at DOP 2 |
| T2 (default) | The same as T1 | The guest has 2 vCPUs; nested-guest Performance support is validated live |
| T3 | CPU waits and CPU at the tier limit, without Parallelism waits | At 1 vCore or less there's no second scheduler, so the plans run serially |

- Parallelism waits show that parallel plans ran and some threads finished early; they're a symptom, not a cause by themselves.
- Plans and degree of parallelism live in Query Store and the plan cache, not in the telemetry.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It reads Parallelism waits together with CPU, not alone.
- On T3, it doesn't report Parallelism waits that aren't there.
- It says where to look next when it can't see plans: Query Store in SSMS or VS Code, or the skills version.

## Safety

- If the agent proposes changing MAXDOP, the cost threshold for parallelism, or a database scoped configuration, read it out as a proposal and cancel it. These change the instance or database, and the scenario sets its own degree of parallelism in a query hint.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [parallel-scans.skills](parallel-scans.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 4, 5, and 9 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
