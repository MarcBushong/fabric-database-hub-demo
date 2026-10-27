---
id: log-flush-waits.in-hub
name: Investigate transaction log flush waits in Database Hub
scenario: log-flush-waits
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds transaction log write waits on the chosen target, tells many short commit waits from slow log storage or a log-rate cap, and correlates them with transactions, log flushes, and log file writes. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value, then what happened at the same time versus what caused it, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry is resource-level, so it can't show which statements commit, and Log Flushes/sec exists for SQL Server only.
fallback: Run log-flush-waits.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 5 and 9 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance
  - https://learn.microsoft.com/sql/relational-databases/logs/the-transaction-log-sql-server
reviewed: 2026-10-23
---

# Investigate transaction log flush waits in Database Hub

The incident beat for [log flush waits](../../../scenarios/log-flush-waits/README.md): many sessions each committing one small row at a time, so every commit waits for its own log flush. It runs on T1 by default and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. What the target waits on

```text
What is {target} waiting on over the last 30 minutes? If it's the transaction log, are these many short waits or a few long ones, and since when? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. Storage, a cap, or the number of commits

```text
For {incidentWindow} on {target}, did transactions per second, log flushes, or writes to the log file rise with the log waits? Is the limit the log storage, a log-rate cap, or the number of commits? Keep coincidence apart from cause. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 (default) | Tran Log IO waits (`WRITELOG`) with many tasks and a low average wait; `Log Flushes/sec`, `Log Bytes Flushed/sec`, `Transactions/sec`, and `Write Transactions/sec` up; many small writes to the log file | Simple recovery, so the log truncates at checkpoints and stays under its cap |
| T2 | The same as T1 | The nested host's disk adds latency; nested-guest Performance support is validated live |
| T3 | `WRITELOG` waits, and Log Rate Governor waits past the service objective's log rate | `Log Flushes/sec` is SQL Server only; the [log rate pressure](log-rate-pressure.in-hub.md) prompts cover the governor |

- Many short `WRITELOG` waits mean many commits; a few long ones mean slow log storage. The Learn guidance for sample query 5 explains the difference.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It reads the `WRITELOG` task count and average wait together before it blames storage.
- On T1 and T2, it doesn't report Log Rate Governor waits that aren't there.

## Safety

- If the agent proposes delayed durability, a recovery model change, moving the log file, or scaling T3, read it out as a proposal and cancel it. The scenario writes only to `demo.commit_scratch`, which auto-cleanup empties.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [log-flush-waits.skills](log-flush-waits.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 5 and 9 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
