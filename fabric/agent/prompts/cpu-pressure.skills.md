---
id: cpu-pressure.skills
name: Investigate CPU pressure with Copilot CLI or VS Code
scenario: cpu-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [databasehub-skill, telemetry-endpoint, sql-diagnostics-skills]
capability: Ranks the demo targets by CPU with the Database Hub skill, confirms the trend, waits, and throughput on the chosen target from the telemetry endpoint, and, where a SQL connection is possible, names the top CPU consumers with the microsoft-sql resource pressure skill.
permission: The Azure CLI signed in as you. The Database Hub skill needs a delegated user with Database Hub access (P4); the telemetry endpoint needs Reader or higher on the subscription and Microsoft.Sql registered; T-SQL prompts need line of sight and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A ranking of targets by CPU, then for the chosen target a table of signals with the metric, UTC window, and value, then the top CPU consumers when a SQL connection exists, then gaps and the KQL and T-SQL it ran.
previewLimitation: The Database Hub skill calls routes that aren't a public contract and reports CPU, storage, and memory only. The telemetry has no query text. The microsoft-sql resource pressure skill is documented for Azure SQL Database and can decline on SQL Server targets.
fallback: Without an agent, run Learn telemetry sample queries 3, 4, 5, and 9 in the Azure Data Explorer web UI, then show Query Store's top resource-consuming queries in SSMS on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, inefficient-queries, supporting-evidence]
sources:
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql-fdh
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
reviewed: 2026-10-20
---

# Investigate CPU pressure with Copilot CLI or VS Code

The skills version of the [CPU pressure](../../../scenarios/cpu-pressure/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 to 3 work on every target from anywhere; prompt 4 needs a SQL connection ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Rank the targets with the Database Hub skill

```text
Use the Database Hub skill to rank the SQL resources in resource group {resourceGroup} by CPU over the last hour. Include the timeframe, the aggregation, and the metric coverage, and flag partial results. Don't change anything.
```

### 2. Trend and waits from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 4 to show CPU on {target} in 5-minute bins over {incidentWindow}, and sample query 5 to list its top waits for the same window, with the signal-wait share. Say when the pressure started and whether it's sustained. Don't change anything.
```

### 3. Throughput and compilations

```text
For {incidentWindow} on {target}, adapt sample query 9 to report Batch Requests/sec, SQL Compilations/sec, and SQL Re-Compilations/sec as rates, and say whether compilations are a large share of batch requests. Don't change anything.
```

### 4. Top CPU consumers, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Tell me whether CPU is the exhausted resource, and list the top CPU consumers from Query Store or the plan cache with their execution counts. Don't change anything: no MAXDOP or configuration changes, no index changes, no scaling, and no re-running the workload.
```

## Signals to look for

| Target | Telemetry (prompts 2 and 3) | SQL diagnostics skill (prompt 4) |
|---|---|---|
| T1 | `SQLProcessCPUPercent` high as a share of the VM's logical CPUs (`AvgCPUPercent` stays at 0 for SQL Server in this preview); CPU-category waits (`SOS_SCHEDULER_YIELD`) with a high signal-wait share | Undocumented on SQL Server: the skill can decline |
| T2 (default) | The same as T1, as a share of the guest's logical CPUs | The same as T1 |
| T3 | `AvgCPUPercent` near the service-tier limit; serverless can scale up to its maximum vCores first | Documented: `avg_cpu_percent` in `sys.dm_db_resource_stats` and the top queries by worker time |

- The Database Hub skill doesn't report IO; the telemetry endpoint does.
- Compilations above about a fifth of batch requests point to ad hoc, unparameterized work (the Learn guidance for sample query 9).

## How to judge the answer

- CPU is reported on the right scale for each target type.
- Waits are deltas over the window, with Idle and Unknown excluded, as the Learn rules require.
- Query names, when shown, come from Query Store or the plan cache on the database, not from the telemetry.
- When the resource pressure skill declines on T1 or T2, the answer says so and stays with telemetry.

## Safety

- The resource pressure skill's guide shows changes such as `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP` and a dedicated admin connection. Reject them; T3 is Microsoft Entra only and the prompt is read-only.
- Approve only `SELECT` statements against `ContosoCare` and read calls to the telemetry endpoint and Database Hub routes.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 3, 4, 5, and 9 for the incident window.
2. Through Bastion, show Query Store's top resource-consuming queries for `ContosoCare` on the target. SSMS on the image is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
