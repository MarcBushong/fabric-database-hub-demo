---
id: deadlock-storm.in-hub
name: Investigate repeated deadlocks in Database Hub
scenario: deadlock-storm
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds whether the chosen target has deadlocks, how many and since when, tells repeated deadlocks from a long blocking queue, and correlates them with errors, throughput, and Lock waits. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value (deadlocks as a count for the window), then what happened at the same time versus what caused it, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry counts deadlocks but holds no deadlock graphs, so it can't name the statements, the lock order, or the victims.
fallback: Run deadlock-storm.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 9 and 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [investigate-locking, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/relational-databases/sql-server-deadlocks-guide
reviewed: 2026-10-23
---

# Investigate repeated deadlocks in Database Hub

The incident beat for the [deadlock storm](../../../scenarios/deadlock-storm/README.md): pairs of sessions that deadlock round after round, with the same side picked as the victim each time. It runs on T1 by default and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** open the target from Estate or Performance, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Are there deadlocks

```text
Has {target} had deadlocks in the last 30 minutes? How many, since when, in which database, and is the rate steady or bursty? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. Deadlocks or a blocking queue

```text
For {incidentWindow} on {target}, tell repeated deadlocks apart from a long blocking queue: what do the deadlock counter, Lock waits, blocked processes, and errors show, and how would each look in the other case? Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see, such as the statements or the lock order. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 (default) | `Number of Deadlocks/sec` rising (a cumulative counter, so count the deltas over the window); `Errors/sec` with it; short Lock waits (`LCK_M_X`, `LCK_M_U`) that end when the deadlock monitor picks a victim | Each round lasts a few seconds, so `Processes blocked` rises only briefly |
| T2 | The same as T1 | Nested-guest Performance support is validated live |
| T3 | The same counters; Lock waits can be on transaction-ID resources | Optimized locking and read committed snapshot don't prevent these deadlocks |

- A run has at most the number of pairs times `maxRounds` deadlocks; each victim is a `deadlock-victim` event in `demo.scenario_run_events`.
- The deadlock graphs aren't in the telemetry. On SQL Server, the built-in `system_health` Extended Events session keeps them; the skills version reads them.

## How to judge the answer

- It counts deadlocks as deltas over a UTC window that overlaps the scenario run, not as a sum of the cumulative counter's samples.
- It names `ContosoCare` and doesn't invent statements, tables, or a lock order it can't see.
- It keeps the deadlocks apart from long blocking: short Lock waits that end, not a growing queue.

## Safety

- If the agent proposes ending sessions, changing an isolation level, or adding an index, read it out as a proposal and cancel it. Every round rolls back, and the scenario stops itself at its deadline or after `maxRounds`.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [deadlock-storm.skills](deadlock-storm.skills.md) in Copilot CLI.
2. Without an agent: open the target on the Performance page, then run the Learn telemetry sample queries 9 and 5 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
