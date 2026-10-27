---
id: inefficient-query.in-hub
name: Find an inefficient query in Database Hub
scenario: inefficient-query
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Points to the workload that got expensive on the chosen target, says when it changed and what changed with it, and separates what Database Hub can see from what needs Query Store on the database.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict on whether a specific workload regressed, then a table of signals with the metric, UTC window, and value, then when it changed and what changed with it, then where to confirm it at query level, then gaps.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry is resource-level, so the agent may not be able to name the query; Query Store on the database holds query text, plans, and per-query statistics.
fallback: Run inefficient-query.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 4, 7, and 9 in the Azure Data Explorer web UI, then Query Store reports in SSMS through Bastion.
actionPolicy: read-only
adrPrompts: [inefficient-queries, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store
reviewed: 2026-10-20
---

# Find an inefficient query in Database Hub

The incident beat for [inefficient query](../../../scenarios/inefficient-query/README.md): a repeatable plan problem for a before-and-after comparison. It runs on T2 by default, on T3 as the Azure SQL variant, and on any target on request. Log-rate pressure on T3 has its own prompts: [resource governance](resource-governance.in-hub.md).

**Where to type it:** open the target from Estate or Performance, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Find the expensive work

```text
Which work on {target} was the most expensive during {incidentWindow}, by CPU, duration, or reads, and did it get more expensive than before? If you can't see individual queries, say so and tell me where to look. Don't change anything.
```

### 2. When it changed, and what changed with it

```text
When did the extra cost on {target} start, and did anything else change at that time, such as a configuration setting, a plan, the workload volume, or compilations? Keep coincidence apart from cause. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Resource signals in Database Hub | Query-level evidence, outside Database Hub |
|---|---|---|
| T1 | CPU or reads up without a matching rise in batch requests; possibly more compilations | Query Store shows the scenario query with a worse plan or more reads per execution |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | The same against the tier's limits | The same in Query Store, which is on by default in Azure SQL Database |

- Database configuration changes show up in the telemetry's database properties, sampled every 10 minutes (Learn sample query 11).

## How to judge the answer

- It ties the extra cost to a window that overlaps the scenario run.
- It doesn't name a query or a plan unless it shows where that came from.
- It names Query Store, SSMS, or VS Code as the place to confirm query-level detail when it can't see it.
- It separates "got slower" from "runs more often".

## Safety

- If the agent proposes forcing a plan, changing a database setting, or adding an index, read it out and cancel it. The scenario resets to a known state on its own (Phase 11).
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [inefficient-query.skills](inefficient-query.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 4, 7, and 9 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Through Bastion, show the Query Store reports for `ContosoCare` in SSMS. SSMS on the image is TODO(verify).
4. Last resort: the screenshots recorded in the rehearsal.
