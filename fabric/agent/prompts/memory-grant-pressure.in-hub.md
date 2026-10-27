---
id: memory-grant-pressure.in-hub
name: Investigate memory grant pressure in Database Hub
scenario: memory-grant-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds queries waiting for memory on the chosen target, tells memory grant pressure from a short buffer pool or slow storage, and correlates it with workspace memory, memory clerks, page life expectancy, and CPU. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value, then the likely driver or the place to find it, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry shows memory waits, clerks, and counters, not which queries hold or wait for a grant or how large each grant is.
fallback: Run memory-grant-pressure.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 5, 7, and 8 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [correlate-signals, inefficient-queries, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues
reviewed: 2026-10-23
---

# Investigate memory grant pressure in Database Hub

The incident beat for [memory grant pressure](../../../scenarios/memory-grant-pressure/README.md): concurrent large sorts that each reserve a big memory grant, so the rest queue. It runs on T2 by default and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Is anything waiting for memory

```text
Is anything on {target} waiting for memory over the last 30 minutes? Which wait category, since when, how many tasks, and how long does each wait last? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. Grants or the buffer pool

```text
For {incidentWindow} on {target}, does the memory pressure come from query memory grants or from the buffer pool? Use the memory clerks, granted workspace memory, page life expectancy, and IO waits, and keep what happened at the same time apart from what caused it. Don't change anything.
```

### 3. What drives it, and the evidence

```text
Which workload or queries on {target} are most likely asking for the large grants? If Database Hub can't show query-level data, say so and tell me where I can see it. Then list your evidence: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 | Memory-category waits (`RESOURCE_SEMAPHORE`) with few tasks and long average waits; `Granted Workspace Memory (KB)` flat at its ceiling; the `MEMORYCLERK_SQLQERESERVATIONS` clerk growing; `Page life expectancy` falling | 8 GiB VM; `Memory Grants Pending` is a detailed counter, if the target lists it |
| T2 (default) | The same as T1 | The guest has 8 GiB; nested-guest Performance support is validated live |
| T3 | The same wait type and clerk | The queue forms sooner within the service objective's memory |

- The Learn guidance for sample query 7 says a growing `MEMORYCLERK_SQLQERESERVATIONS` indicates large memory grants.
- Which query holds a grant is in `sys.dm_exec_query_memory_grants` and Query Store, not in the telemetry.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It points to grant pressure from a Memory-category wait or the grant counters, not from Buffer IO waits alone.
- It doesn't blame the buffer pool's size unless page life expectancy and Buffer IO show it.
- It says where to see query-level grants when it can't see them.

## Safety

- If the agent proposes changing max server memory, Resource Governor, a query hint, or scaling T3, read it out as a proposal and cancel it. The scenario only reads data and ends at its own deadline.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [memory-grant-pressure.skills](memory-grant-pressure.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 5, 7, and 8 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
