---
id: capacity-max.skills
name: Investigate a target at full capacity with Copilot CLI or VS Code
scenario: capacity-max
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Ranks the estate by CPU and wait profile from the telemetry endpoint, measures CPU, waits, and data file IO on one target against its baseline, and, where a SQL connection is possible, asks the microsoft-sql resource pressure skill which governed limit is reached.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict naming the limits reached, then a table of CPU, the top waits, and data file reads and stalls for the baseline and incident windows, then the limit the skill names when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews; there's no Learn sample query for SqlServerStorageIO, so the agent writes that KQL itself under the documented rules, and per-file latency isn't supported for Azure SQL Database. The resource pressure skill is documented for Azure SQL Database only.
fallback: Without an agent, run Learn telemetry sample queries 3, 4, 5, and 6 in the Azure Data Explorer web UI for both windows, then show the target on the Database Hub Performance page.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, baseline-vs-incident, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance
  - https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases
reviewed: 2026-10-23
---

# Investigate a target at full capacity with Copilot CLI or VS Code

The skills version of the [capacity maxed out](../../../scenarios/capacity-max/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 to 3 work on every target from anywhere. Prompt 4 needs a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. The estate

```text
Using the telemetry agent instructions, adapt sample query 3 to resource group {resourceGroup} for {incidentWindow}, and sample query 6 for the wait profile over the same window. Say which resource has the most CPU pressure and which wait categories dominate where. Don't change anything.
```

### 2. One target, CPU and storage

```text
For {incidentWindow} on {target}, adapt sample query 4 for CPU in 1-minute bins and sample query 5 for the top waits with their signal-wait share. Then write a KQL query on SqlServerStorageIO, following the rule for cumulative counters, for the ContosoCare data file's read and write deltas, stalls, and queued read stalls. If {target} is an Azure SQL database, don't compute per-file latency. Don't change anything.
```

### 3. Baseline compared with the incident

```text
Compare {baselineWindow} and {incidentWindow} on {target} for average CPU, the top three wait categories, and the ContosoCare data file's reads and read stalls, and say how far each moved. Don't change anything.
```

### 4. The limit reached, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Tell me which limit is reached: CPU, data IO, log IO, memory, or workers and sessions, with the DMV and the values behind each, or say that the skill doesn't apply to {target}. Don't change anything: don't scale, change a setting, or KILL a session.
```

## Signals to look for

| Target | Telemetry (prompts 1 to 3) | SQL diagnostics skill (prompt 4) |
|---|---|---|
| T1 (default) | `SQLProcessCPUPercent` at or near 100; `SOS_SCHEDULER_YIELD` with a high signal-wait share; `PAGEIOLATCH_SH` once the scratch set exceeds memory; read deltas and stalls on the data file | Undocumented on SQL Server: the skill can decline |
| T2 | The same as T1, with stalls that include the nested host's disk | The same as T1 |
| T3 | CPU at the tier limit; `IOStallQueuedReadMs` from IO governance; no per-file latency from telemetry | Documented: CPU and data IO percentages against the service objective's limits |

- On SQL Server (T1, T2), read `SQLProcessCPUPercent`, the SQL Server process's share of the machine's logical CPUs: `AvgCPUPercent`, which the telemetry article calls the primary signal, stayed at 0 for SQL Server in this preview (2026-10-23). On Azure SQL Database (T3), `AvgCPUPercent` is a share of the service-tier limit.

## How to judge the answer

- Cumulative counters are deltas between adjacent samples, with resets skipped, never sums or last-minus-first.
- The baseline and incident windows have the same length, and every number names its window and resource.
- It names CPU and IO limits separately; when the skill declines on T1 or T2, it says so, and the answer rests on the telemetry.

## Safety

- Reject resizing a VM, scaling T3, or changing MAXDOP, memory, or file settings, even as a test.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 3, 4, 5, and 6 for both windows.
2. Show the target on the Database Hub Performance page.
3. Last resort: the screenshots recorded in the rehearsal.
