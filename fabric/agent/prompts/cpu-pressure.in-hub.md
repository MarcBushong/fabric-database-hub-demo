---
id: cpu-pressure.in-hub
name: Investigate CPU pressure in Database Hub
scenario: cpu-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds the target with the most CPU pressure, tells a sustained load from a short spike, shows what moved with it (waits, sessions, memory, IO, throughput), and says whether it can see which workload drives the CPU or where to look instead.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict naming the target and whether the load is sustained, then a table of signals with the metric, UTC window, and value, then the likely driver or the place to find it, then gaps.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry is resource-level, so the agent may not name a query; CPU means different things on SQL Server and Azure SQL Database.
fallback: Run cpu-pressure.skills in Copilot CLI. Without an agent, show the Performance page for the target and run Learn telemetry sample queries 3, 4, and 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, inefficient-queries, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/fabric/database/hub/faq
reviewed: 2026-10-20
---

# Investigate CPU pressure in Database Hub

The incident beat for [CPU pressure](../../../scenarios/cpu-pressure/README.md): a bounded expensive query, run on T2 by default and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Target with the most pressure

```text
Which SQL resource in resource group {resourceGroup} has had the highest CPU over the last 30 minutes? Tell me whether it's a sustained load or a short spike, and how you can tell. Don't change anything.
```

### 2. What moved with the CPU

```text
On {target}, when did the CPU pressure start, is it still going, and what else moved at the same time: waits, active sessions, memory, storage IO, or throughput? Keep coincidence apart from cause. Don't change anything.
```

### 3. What drives it

```text
Which workload or queries on {target} are most likely driving the CPU? If Database Hub can't show query-level data, say so and tell me where I can see it. Don't change anything.
```

### 4. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | What CPU means | Signals |
|---|---|---|
| T1 | Engine CPU as a share of all logical CPUs on the VM | SQL Server process CPU (`SQLProcessCPUPercent`) sustained high; CPU-category waits with a high signal-wait share; batch requests per second |
| T2 (default) | Engine CPU as a share of the guest's logical CPUs; the nested host isn't visible | The same as T1. Nested-guest Performance support is validated live |
| T3 | `avg_cpu_percent` as a share of the service-tier limit, so a small serverless database reaches its ceiling quickly | High CPU against the tier limit; this is also the service-objective CPU cap that the [resource governance](resource-governance.in-hub.md) prompts examine |

- A high maximum with little time above the threshold is a spike, not sustained pressure. The Learn page's guidance for sample query 3 explains the difference.
- Query text and plans aren't in the telemetry. Learn points to Query Store on the database for them.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It reports CPU on the right scale for the target type.
- It doesn't name a specific query unless it shows where that came from.
- It says where to look next when it can't see query-level detail: Query Store in SSMS or VS Code, or the skills version.

## Safety

- If the agent proposes scaling T3, changing MAXDOP, or adding an index, read it out as a proposal and cancel it. Scaling changes cost, and the scenario ends at its own deadline.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [cpu-pressure.skills](cpu-pressure.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 3, 4, and 5 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
