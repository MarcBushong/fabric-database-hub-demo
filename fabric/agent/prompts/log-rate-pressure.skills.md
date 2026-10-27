---
id: log-rate-pressure.skills
name: Investigate log-rate pressure with Copilot CLI or VS Code
scenario: log-rate-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Finds a cap on write throughput from the telemetry endpoint (Log Rate Governor and Tran Log IO waits, log flush counters, log file writes) and, on T3, from sys.dm_db_resource_stats with the microsoft-sql resource pressure skill, and keeps T3's governed log rate apart from the log disk of T1 and T2.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. The T-SQL prompt needs line of sight to T3 and a Microsoft Entra database identity with VIEW DATABASE STATE in ContosoCare.
responseShape: A verdict naming the cap on write throughput or saying there's none, then a table of signals with the wait or counter, UTC window, and value, then the sys.dm_db_resource_stats columns that were high, then gaps and the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews; a paused serverless database sends no telemetry. The resource pressure skill is written for Azure SQL Database, so on T1 and T2 only the telemetry prompts apply. sys.dm_db_resource_stats keeps about an hour of 15-second rows.
fallback: Without an agent, chart Log IO percentage for the T3 database in the Azure portal, and run Learn telemetry sample query 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server
  - https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume
reviewed: 2026-10-20
---

# Investigate log-rate pressure with Copilot CLI or VS Code

The skills version of the [log-rate pressure](../../../scenarios/log-rate-pressure/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first, and warm T3 up so it isn't paused. Prompts 1 and 2 work on every target from anywhere; prompt 3 needs a SQL connection to T3 ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Log waits from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} for {incidentWindow} and report Log Rate Governor and Tran Log IO waits with their task counts and average waits, as deltas of the cumulative counters. Say whether the waits point to log-rate governance by the service tier or to the log disk of the machine. Don't change anything.
```

### 2. Log flushes and log file writes against the baseline

```text
For {target}, write KQL queries that compare {baselineWindow} with {incidentWindow}: the per-second rate of Log Bytes Flushed/sec and Log Flushes/sec from SqlServerPerformanceCountersCommon, and the delta of writes and write stalls on the log file from SqlServerStorageIO, following the rule for cumulative counters. List any gaps longer than two minutes. Don't change anything.
```

### 3. The governed log rate, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. From sys.dm_db_resource_stats, report the highest avg_log_write_percent during {incidentWindow} and how long it stayed near its limit. If {target} isn't an Azure SQL database, say that the skill doesn't apply. Don't change anything: no scaling and no configuration changes.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | Database (prompt 3) |
|---|---|---|
| T3 (default) | Log Rate Governor waits; writes flat at the tier's log rate; gaps while paused | Documented: `avg_log_write_percent` stands out in `sys.dm_db_resource_stats` |
| T1 | No Log Rate Governor waits; `WRITELOG` waits; Log Bytes Flushed/sec and Log Flushes/sec rising; log file writes | Not applicable: the view is Azure SQL Database only |
| T2 | The same as T1 | Not applicable |

## How to judge the answer

- It names the cap from a specific wait, counter, or column, with a UTC window.
- It keeps T3's governed log rate apart from T1 and T2's log disk.
- Waits, flushes, and stalls are deltas or rates, never sums of samples.
- It treats gaps as missing data and doesn't average across them.

## Safety

- The resource pressure skill's guide shows a dedicated admin connection with a SQL login and configuration changes. T3 accepts Microsoft Entra authentication only, and this beat is read-only: reject both.
- Reject any scaling, auto-pause, or recovery-model change; they change cost or the demo's design (ADR 0016).

## Fallback demo

1. In the Azure portal, open the T3 database's metrics and chart Log IO percentage for the incident window.
2. Run the Learn telemetry sample query 5 for the target in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
