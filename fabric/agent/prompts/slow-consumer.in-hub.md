---
id: slow-consumer.in-hub
name: Investigate a slow client in Database Hub
scenario: slow-consumer
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds network waits on the chosen target and tells a slow client from a slow database, that is, whether the server waits for the application to read its results rather than on CPU, IO, memory, or locks. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value, then who should look next and why, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry has no client-side view, so it can show that the server waits on the network but not why the client reads slowly.
fallback: Run slow-consumer.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 5 and 9 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-query-async-network-io
reviewed: 2026-10-23
---

# Investigate a slow client in Database Hub

The incident beat for the [slow consumer](../../../scenarios/slow-consumer/README.md): sessions whose client reads a wide result set a few rows at a time, so the server waits for it. It runs on T3 by default, with T1's runner as the client across the network, and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Is the database busy

```text
What is {target} waiting on over the last 30 minutes, and is the database itself busy? If most of the wait time falls outside CPU, IO, memory, and locks, say what that means. Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. The database or the application

```text
For {incidentWindow} on {target}, did network waits rise while CPU, IO, and blocking stayed flat? Should the database team or the application team look next, and why? Keep coincidence apart from cause. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see, such as the client side. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 | Network IO waits (`ASYNC_NETWORK_IO`) with few tasks and long average waits; CPU and IO flat; `SQL Attention rate` above 0 when the runner cancels | The client is the runner on the same machine |
| T2 | The same as T1 | The client is the runner in the guest |
| T3 (default) | The same wait and counter | The client is T1's runner across the network, the usual shape of a slow application against Azure SQL Database |

- The scenario's sessions stay active for minutes while using little CPU or IO.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It names Network IO (`ASYNC_NETWORK_IO`) and says the server waits for the client, not for its own resources.
- It doesn't recommend scaling the database, adding an index, or changing settings for this wait.

## Safety

- If the agent proposes ending sessions, scaling T3, or changing a setting, read it out as a proposal and cancel it. The runner cancels its own queries at the deadline or on a stop request.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [slow-consumer.skills](slow-consumer.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 5 and 9 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
