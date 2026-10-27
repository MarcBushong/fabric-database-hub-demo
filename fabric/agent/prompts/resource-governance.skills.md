---
id: resource-governance.skills
name: Investigate T3 resource governance and log-rate pressure with Copilot CLI or VS Code
scenario: resource-governance
producedBy: [resource-governance, cpu-pressure, inefficient-query]
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Finds governed limits on T3 from the telemetry endpoint (Log Rate Governor waits, CPU against the tier limit, queued IO stalls, sample gaps) and from sys.dm_db_resource_stats with the microsoft-sql resource pressure skill, and shows on T1 and T2 that the same signals are machine limits, not governance.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. The T-SQL prompt needs line of sight to T3 and a Microsoft Entra database identity with VIEW DATABASE STATE in ContosoCare.
responseShape: A verdict naming the limit or saying none was reached, then a table of signals with the metric, UTC window, and value, then the sys.dm_db_resource_stats columns that were high, then gaps and the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews; a paused serverless database sends no telemetry. The resource pressure skill is written for Azure SQL Database, so on T1 and T2 only the telemetry prompts apply. sys.dm_db_resource_stats keeps about an hour of 15-second rows.
fallback: Without an agent, chart the T3 database's Azure Monitor metrics (CPU percentage, Log IO percentage, Data IO percentage, Workers percentage) in the Azure portal, and run Learn telemetry sample queries 2 and 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume
  - https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics
reviewed: 2026-10-20
---

# Investigate T3 resource governance and log-rate pressure with Copilot CLI or VS Code

The skills version of the Azure SQL Database-specific incident, produced on T3 by the [resource governance](../../../scenarios/resource-governance/README.md) scenario (Phase 11) and by the [CPU pressure](../../../scenarios/cpu-pressure/README.md) and [inefficient query](../../../scenarios/inefficient-query/README.md) scenarios. Run [session-setup.skills](session-setup.skills.md) first, and warm T3 up so it isn't paused. Prompts 1 and 2 work on every target from anywhere; prompt 3 needs a SQL connection to T3 ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Governed waits and CPU from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} for {incidentWindow} and report Log Rate Governor and Tran Log IO waits with their task counts and average waits, then sample query 4 for CPU over the same window. Say whether CPU is a share of a service-tier limit or of the machine's logical CPUs for this resource type. Don't change anything.
```

### 2. Queued IO and gaps

```text
For {target} over {incidentWindow}, write a KQL query on SqlServerStorageIO that reports the delta of queued read and write stalls per file, following the rule for cumulative counters, then list any gaps longer than two minutes in the CPU samples and say whether they could be the database pausing. Don't change anything.
```

### 3. Which governed resource ran out, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. From sys.dm_db_resource_stats, report the highest avg_cpu_percent, avg_data_io_percent, avg_log_write_percent, max_worker_percent, and max_session_percent during {incidentWindow}, and name the exhausted resource. If {target} isn't an Azure SQL database, say that the skill doesn't apply. Don't change anything: no scaling and no configuration changes.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | Database (prompt 3) |
|---|---|---|
| T3 (default) | Log Rate Governor waits; `AvgCPUPercent` near the tier limit; queued stalls; gaps while paused | Documented: one column of `sys.dm_db_resource_stats` stands out, such as `avg_log_write_percent` |
| T1 | No Log Rate Governor waits; `WRITELOG` waits if the log is busy; CPU as a share of the VM's logical CPUs | Not applicable: the view is Azure SQL Database only |
| T2 | The same as T1 | Not applicable |

## How to judge the answer

- It names the exhausted resource from a specific column or wait, with a UTC window.
- It keeps T3's governed limits apart from T1 and T2's machine limits.
- It treats gaps as missing data and doesn't average across them.
- Waits and stalls are deltas, never sums of samples.

## Safety

- The resource pressure skill's guide shows a dedicated admin connection with a SQL login and a MAXDOP change. T3 accepts Microsoft Entra authentication only, and this beat is read-only: reject both.
- Reject any scaling or auto-pause change; they change cost (ADR 0016).

## Fallback demo

1. In the Azure portal, open the T3 database's metrics and chart CPU percentage, Log IO percentage, Data IO percentage, and Workers percentage for the incident window.
2. Run the Learn telemetry sample queries 2 and 5 for T3 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
