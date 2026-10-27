---
id: capacity-max.in-hub
name: Investigate a target at full capacity in Database Hub
scenario: capacity-max
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds the target with the most pressure across the estate, tells CPU saturation from storage saturation when both reach their limits at once, and correlates CPU, waits, memory, and storage IO. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict naming the target and which limits it reached, then a table of signals with the metric, UTC window, and value, then what to look at first and why, then gaps.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry is resource-level, so the agent may not name a query; CPU means different things on SQL Server and Azure SQL Database, and per-file latency isn't available for Azure SQL Database.
fallback: Run capacity-max.skills in Copilot CLI. Without an agent, show the Performance page for the target and run Learn telemetry sample queries 3, 4, and 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-high-cpu-usage-issues
  - https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases
reviewed: 2026-10-23
---

# Investigate a target at full capacity in Database Hub

The incident beat for [capacity maxed out](../../../scenarios/capacity-max/README.md): every scheduler busy and the storage at its cap at the same time, for 20 minutes at most. It runs on T1 by default and on any target on request; run it on two targets to compare them in the estate view. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Target with the most pressure

```text
Which SQL resource in resource group {resourceGroup} has had the most pressure over the last 30 minutes, and is it CPU, storage IO, or both? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. Which limit first

```text
On {target} during {incidentWindow}, is the CPU at its limit, is the storage at its limit, or both? Which would you look at first, and why? Keep coincidence apart from cause. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Signals | Notes |
|---|---|---|
| T1 (default) | SQL Server process CPU (`SQLProcessCPUPercent`) at or near 100; CPU waits (`SOS_SCHEDULER_YIELD`) with a high signal-wait share; Buffer IO waits (`PAGEIOLATCH_SH`) once the scratch set exceeds memory; IO stalls on the data file; `Page life expectancy` falling | Engine CPU as a share of the VM's logical CPUs; reads at the managed disk's caps |
| T2 | The same as T1 | The nested host's disk sits under the guest; nested-guest Performance support is validated live |
| T3 | CPU at the tier limit; reads queued by IO governance | Also the service-objective caps that the [resource governance](resource-governance.in-hub.md) prompts examine |

- A high maximum with little time above the threshold is a spike, not sustained pressure. The Learn page's guidance for sample query 3 explains the difference.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It reports CPU on the right scale for the target type and names CPU and IO signals separately.
- With both limits reached, it says so rather than picking one without a signal.

## Safety

- If the agent proposes resizing a VM, scaling T3, changing MAXDOP, or adding an index, read it out as a proposal and cancel it. Resizing and scaling change cost, and the scenario ends at its own deadline.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [capacity-max.skills](capacity-max.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 3, 4, and 5 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
