---
id: resource-governance.in-hub
name: Investigate T3 resource governance and log-rate pressure in Database Hub
scenario: resource-governance
producedBy: [resource-governance, cpu-pressure, inefficient-query]
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Tells whether the chosen target is hitting a limit set by its service tier (CPU cap, log write rate, IO, workers, or sessions) or the capacity of its machine, finds log-rate throttling, and marks gaps that could be a serverless pause. T1 and T2 serve as controls with no governance.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and the performance monitoring extended property set on ContosoCare for T3. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict naming the limit, or saying there's none, then a table of signals with the metric, UTC window, and value, then gaps in the data and their likely reason, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency; Azure SQL Database is the most likely target, but that's unconfirmed. A paused serverless database sends no telemetry, and a newly created T3 can show findings late.
fallback: Run resource-governance.skills in Copilot CLI. Without an agent, show the Azure portal metrics for the T3 database (CPU percentage, Log IO percentage, Data IO percentage, Workers percentage) and run Learn telemetry sample query 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/fabric/database/hub/add-sql
  - https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume
  - https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics
reviewed: 2026-10-20
---

# Investigate T3 resource governance and log-rate pressure in Database Hub

The Azure SQL Database-specific incident: the service-objective CPU cap and log-rate governance on T3. The [resource governance](../../../scenarios/resource-governance/README.md) scenario (Phase 11) produces it, and so do the [CPU pressure](../../../scenarios/cpu-pressure/README.md) and [inefficient query](../../../scenarios/inefficient-query/README.md) scenarios when they run on T3. For log writes alone, use [log-rate-pressure.in-hub](log-rate-pressure.in-hub.md). On T1 and T2 the same prompts act as controls: those targets have no service-tier governance, so the answer should find machine limits instead.

Warm T3 up first, because a paused serverless database has no telemetry ([serverless auto-pause](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)).

**Where to type it:** open the T3 database from Estate or Performance, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Which limit

```text
Is {target} hitting a resource limit, and which one: CPU, data IO, log write, workers, or sessions? Tell me whether it's a limit set by the service tier or the capacity of the machine, and since when. Don't change anything.
```

### 2. Log-rate throttling

```text
For {incidentWindow} on {target}, is log write throughput being throttled? Which waits or rates show it, and how much of the window was affected? Don't change anything.
```

### 3. Gaps and pauses

```text
Mark any gaps in the data for {target} during {incidentWindow} and say whether they could be the database pausing or resuming. Don't change anything.
```

## Signals to look for

| Target | Signals | What they mean |
|---|---|---|
| T3 (default) | CPU near the service-tier limit; Log Rate Governor waits (`LOG_RATE_GOVERNOR`); queued IO stalls from IO governance; gaps while paused | Governed limits of the service objective, set by the tier, not by hardware |
| T1 | No Log Rate Governor waits; log pressure appears as Tran Log IO waits (`WRITELOG`); CPU as a share of the VM's logical CPUs | A control: a machine limit, not a governed one |
| T2 | The same as T1, inside the nested guest | A control |

- The Azure portal shows the same story for T3 as Azure Monitor metrics: CPU percentage, Log IO percentage, Data IO percentage, Workers percentage, and Sessions percentage. With the free offer, Free amount remaining shows the monthly allowance.

## How to judge the answer

- On T3, it names a governed limit, or says none was reached, with a metric and a UTC window.
- On T1 and T2, it doesn't report governance; it reports machine limits or none.
- It treats a gap as missing data, not as a healthy period.
- It doesn't recommend a bigger tier without naming the exhausted resource first.

## Safety

- If the agent proposes scaling T3 or changing its auto-pause delay, read it out and cancel it. Both change cost, and the demo's T3 settings are deliberate (ADR 0016).
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [resource-governance.skills](resource-governance.skills.md) in Copilot CLI.
2. Without an agent: in the Azure portal, open the T3 database's metrics and chart CPU percentage, Log IO percentage, Data IO percentage, and Workers percentage for the incident window.
3. Run the Learn telemetry sample query 5 for T3 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
4. Last resort: the screenshots recorded in the rehearsal.
