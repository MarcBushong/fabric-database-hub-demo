---
id: tempdb-contention.in-hub
name: Investigate tempdb latch contention in Database Hub
scenario: tempdb-contention
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds latch contention on the chosen target, tells waits on pages in memory from IO or lock waits, and correlates them with temporary table activity, recompilations, CPU, and sessions. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value, then what happened at the same time versus what caused it, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry reports wait types and counters for the whole instance, not the database or page a latch wait is on, so tying the waits to tempdb needs the temporary table counters or a query on the server.
fallback: Run tempdb-contention.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 5, 8, and 9 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/relational-databases/databases/tempdb-database
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/resolve-pagelatch-ex-contention
reviewed: 2026-10-23
---

# Investigate tempdb latch contention in Database Hub

The incident beat for [tempdb allocation contention](../../../scenarios/tempdb-contention/README.md): many sessions creating and dropping temporary tables at once. It runs on T2 by default and on any target on request. Start the scenario, wait for a few minutes of samples, then ask.

**Where to type it:** start from Overview or Performance, then open the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. What the target waits on

```text
Which waits dominate on {target} over the last 30 minutes? Are they latch waits on pages in memory, IO waits, or lock waits, and are they many short waits or a few long ones? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. What moved with the waits

```text
For {incidentWindow} on {target}, did temporary table activity, recompilations, CPU, or active sessions rise with the latch waits? Keep what happened at the same time apart from what caused it. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see, such as which database or page the waits were on. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 | Buffer Latch waits (`PAGELATCH_EX`, `PAGELATCH_SH`, `PAGELATCH_UP`) with many tasks and short average waits; `Temp Tables Creation Rate` and `Active Temp Tables` up; `SQL Re-Compilations/sec` and CPU rising | tempdb is on the VM's local temporary disk |
| T2 (default) | The same as T1 | tempdb is in the guest; nested-guest Performance support is validated live |
| T3 | Fewer latch waits and more CPU waits | The service manages tempdb, and at 1 vCore or less fewer sessions run at once |

- Buffer Latch (`PAGELATCH_*`) is contention for pages already in memory. Buffer IO (`PAGEIOLATCH_*`) is waiting for the disk; the two point to different fixes.
- The pages a latch wait is on aren't in the telemetry. The skills version reads them from the server.

## How to judge the answer

- It names the target and a UTC window that overlaps the scenario run.
- It doesn't call `PAGELATCH_*` waits disk IO, and it doesn't call them blocking.
- It ties the waits to tempdb only through a signal that points there, such as the temporary table counters, and says what it can't see.

## Safety

- If the agent proposes adding tempdb files, enabling memory-optimized tempdb metadata, a trace flag, or a restart, read it out as a proposal and cancel it. These change the instance, and the scenario ends at its own deadline.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [tempdb-contention.skills](tempdb-contention.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then run the Learn telemetry sample queries 5, 8, and 9 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
