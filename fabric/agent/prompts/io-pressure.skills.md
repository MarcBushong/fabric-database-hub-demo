---
id: io-pressure.skills
name: Investigate storage IO pressure with Copilot CLI or VS Code
scenario: io-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Measures read and write volume, IO stalls, IO waits, memory pressure, and database growth on any target from the telemetry endpoint, following the Learn rules for cumulative counters, and on T3 reads file stats and governed IO from the database with the microsoft-sql resource pressure skill.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. T-SQL prompts need line of sight and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict on reads versus writes and data versus log, then a table per file with the delta of reads, writes, bytes, and stalls over the UTC window, then memory and growth, then gaps and the KQL and T-SQL it ran.
previewLimitation: There's no Learn sample query for SqlServerStorageIO, so the agent writes the KQL itself under the documented rules; per-file latency from the telemetry isn't supported for Azure SQL Database. The Database Hub skill doesn't report IO. The resource pressure skill is documented for Azure SQL Database only.
fallback: Without an agent, run Learn telemetry sample queries 5, 7, 8, and 10 in the Azure Data Explorer web UI, then show the target's IO on the Database Hub Performance page.
actionPolicy: read-only
adrPrompts: [correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-io-virtual-file-stats-transact-sql
reviewed: 2026-10-20
---

# Investigate storage IO pressure with Copilot CLI or VS Code

The skills version of the [IO pressure](../../../scenarios/io-pressure/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 to 3 work on every target from anywhere; prompt 4 needs a SQL connection ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)) and is documented for T3 only.

## Prompts

### 1. File-level IO from the telemetry

```text
Using the telemetry agent instructions, write a KQL query on SqlServerStorageIO for {target} in resource group {resourceGroup} over {incidentWindow}. Follow the rule for cumulative counters, and for each ContosoCare file report the delta of reads, writes, bytes read and written, read and write stalls, and queued stalls. If {target} is an Azure SQL database, don't compute per-file latency. Don't change anything.
```

### 2. IO waits and memory pressure

```text
For {incidentWindow} on {target}, adapt sample query 5 to show Buffer IO and Tran Log IO waits, sample query 8 for page life expectancy, and sample query 7 for the largest memory clerks. Say whether memory pressure is pushing reads to disk. Don't change anything.
```

### 3. Growth stays within the cap

```text
Adapt sample query 10 to {target} in resource group {resourceGroup} for the last day, and report used and allocated data and log space for ContosoCare at the start and end of {incidentWindow}. Don't change anything.
```

### 4. Governed IO, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Read sys.dm_io_virtual_file_stats, including the queued stall columns, and, if {target} is an Azure SQL database, avg_data_io_percent and avg_log_write_percent from sys.dm_db_resource_stats. Tell me whether IO governance or storage is the limit, or say that the skill doesn't apply to {target}. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompts 1 to 3) | SQL diagnostics skill (prompt 4) |
|---|---|---|
| T1 | Read or write deltas and stalls on `ContosoCare` files; `PAGEIOLATCH_*` or `WRITELOG` waits; page life expectancy down | Undocumented on SQL Server: the skill can decline |
| T2 (default) | The same as T1; stalls include the nested host disk | The same as T1 |
| T3 | Read and write deltas; queued stalls from IO governance; no per-file latency from telemetry | Documented: file stats with queued stalls, and data IO and log write percentages against the tier's limits |

## How to judge the answer

- Cumulative counters are deltas between adjacent samples, with resets skipped, never sums or last-minus-first.
- Each number names its file type (Data or Log), the window, and the resource.
- On T3 it uses database DMVs, not telemetry, for file latency.
- Growth stays inside the scenario's cap; if it doesn't, it says so as a finding.

## Safety

- Approve only read calls to the telemetry endpoint and `SELECT` statements against `ContosoCare`.
- Reject any file, disk, tier, or configuration change, even as a test.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 5, 7, 8, and 10 for the incident window.
2. Show the target's IO on the Database Hub Performance page.
3. Last resort: the screenshots recorded in the rehearsal.
