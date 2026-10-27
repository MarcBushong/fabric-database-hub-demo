---
id: io-pressure.in-hub
name: Investigate storage IO pressure in Database Hub
scenario: io-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds storage IO pressure on the chosen target, separates reads from writes and data files from the log, and shows what moved with it (memory, CPU, waits, sessions), with its evidence.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict naming the target and whether reads or writes dominate, then a table of signals with the metric, UTC window, and value, then what moved at the same time, then gaps.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Per-file IO latency from the telemetry isn't supported for Azure SQL Database in this preview, and T2's storage sits behind a nested host disk.
fallback: Run io-pressure.skills in Copilot CLI. Without an agent, show the target's IO on the Performance page and run Learn telemetry sample queries 5 and 8 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/fabric/database/hub/faq
reviewed: 2026-10-20
---

# Investigate storage IO pressure in Database Hub

The incident beat for [IO pressure](../../../scenarios/io-pressure/README.md): bounded reads and writes over seeded data, with growth capped. It runs on T2 by default and on any target on request.

**Where to type it:** open the target on the Performance page, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. Investigate the IO pressure

```text
Is {target} under storage IO pressure? Which database and which files, data or log, since when, and is it mostly reads or writes? Name each signal you used. Don't change anything.
```

### 2. What moved with it

```text
For {incidentWindow} on {target}, did memory, CPU, waits, or active sessions change at the same time as the IO? Keep coincidence apart from cause. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Signals | Notes |
|---|---|---|
| T1 | Read and write volume and IO stalls on `ContosoCare` files; Buffer IO waits (`PAGEIOLATCH_*`); Tran Log IO waits (`WRITELOG`) for write bursts; page reads per second up and page life expectancy down | In `lowest-cost`, the data files sit on the OS disk |
| T2 (default) | The same as T1 | The guest's virtual disk lives on the host's disk, so stalls include the nested layer |
| T3 | Read and write volume; queued IO stalls, which come from IO resource governance | Per-file latency from the telemetry isn't supported for Azure SQL Database; Learn points to `sys.dm_io_virtual_file_stats` on the database |

- The scenario checks free space first and caps growth, so database size should rise only within its cap.

## How to judge the answer

- It names the database and says whether data files or the log carry the load.
- IO counters are deltas over the window, never sums of samples.
- On T3, it doesn't quote a per-file latency from the telemetry.
- It doesn't recommend bigger disks or a higher tier without evidence that the cap, not the workload, is the limit.

## Safety

- If the agent proposes moving files, growing disks, or scaling T3, read it out and cancel it. Each of those changes cost or the demo's known state.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [io-pressure.skills](io-pressure.skills.md) in Copilot CLI.
2. Without an agent: show the target's IO on the Performance page, then run the Learn telemetry sample queries 5 and 8 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
