---
id: log-rate-pressure.in-hub
name: Investigate log-rate pressure in Database Hub
scenario: log-rate-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Tells whether write throughput on the chosen target is capped, and by what. On T3 that's log-rate governance set by the service tier; on T1 and T2 it's the log disk and log flushes of the machine. It names the waits and log counters that show it and the UTC window.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and the performance monitoring extended property set on ContosoCare for T3. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict naming the cap on write throughput, or saying there's none, then a table of signals with the wait or counter, UTC window, and value, then gaps in the data and their likely reason, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency; Azure SQL Database is the most likely target, but that's unconfirmed. A paused serverless database sends no telemetry, and a newly created T3 can show findings late.
fallback: Run log-rate-pressure.skills in Copilot CLI. Without an agent, chart Log IO percentage for the T3 database in the Azure portal, and run Learn telemetry sample query 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server
  - https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume
  - https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics
reviewed: 2026-10-20
---

# Investigate log-rate pressure in Database Hub

The write-throughput incident from the [log-rate pressure](../../../scenarios/log-rate-pressure/README.md) scenario (Phase 11). It writes and deletes rows in batches, so the log keeps working while the data size stays flat. On T3 the service objective governs the log rate; on T1 and T2 the same workload shows log flushes and log waits of the machine instead.

Warm T3 up first, because a paused serverless database has no telemetry ([serverless auto-pause](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)).

**Where to type it:** open the target's database from Estate or Performance, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. What caps the writes

```text
During {incidentWindow}, is write throughput on {target} capped? Tell me whether the cap is log-rate governance set by the service tier or the log disk of the machine, and which waits or log counters show it. Don't change anything.
```

### 2. Compared with the baseline

```text
Compare log write activity on {target} between {baselineWindow} and {incidentWindow}: log waits, log flushes, and writes to the log file. What changed, and when did it start and stop? Don't change anything.
```

### 3. Gaps and pauses

```text
Mark any gaps in the data for {target} during {incidentWindow} and say whether they could be the database pausing or resuming. Don't change anything.
```

## Signals to look for

| Target | Signals | What they mean |
|---|---|---|
| T3 (default) | Log Rate Governor waits (`LOG_RATE_GOVERNOR`); write throughput flat at the tier's log rate; gaps while paused | Log-rate governance of the service objective, set by the tier, not by hardware |
| T1 | No Log Rate Governor waits; Tran Log IO waits (`WRITELOG`); Log Bytes Flushed/sec and Log Flushes/sec rising; writes on the log file | A control: the machine's log disk, not a governed limit |
| T2 | The same as T1, inside the nested guest | A control |

- The data size stays flat during the run, because every batch is deleted after it commits.
- The Azure portal shows the same story for T3 as the Log IO percentage metric.

## How to judge the answer

- On T3, it names log-rate governance, or says it wasn't reached, with a wait or metric and a UTC window.
- On T1 and T2, it doesn't report governance; it reports log waits and flushes of the machine, or none.
- It treats a gap as missing data, not as a quiet period.
- It doesn't recommend a bigger tier or another disk without naming the capped resource first.

## Safety

- If the agent proposes scaling T3, changing its auto-pause delay, or changing a recovery model, read it out and cancel it. Each changes cost or the demo's design (ADR 0016).
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [log-rate-pressure.skills](log-rate-pressure.skills.md) in Copilot CLI.
2. Without an agent: in the Azure portal, open the T3 database's metrics and chart Log IO percentage for the incident window.
3. Run the Learn telemetry sample query 5 for the target in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
4. Last resort: the screenshots recorded in the rehearsal.
