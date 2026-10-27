---
id: tempdb-contention.skills
name: Investigate tempdb latch contention with Copilot CLI or VS Code
scenario: tempdb-contention
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills, scenario-record]
capability: Measures Buffer Latch waits, temporary table activity, and recompilations on any target from the telemetry endpoint, then, where a SQL connection is possible, reads the wait resources of the scenario's sessions with the microsoft-sql resource pressure skill to tell allocation pages from system catalog pages in tempdb.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict, then a table of latch waits by wait type and of temporary table counters over the UTC window, then the wait resources grouped by page kind when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews and don't say which database or page a latch wait is on. The resource pressure skill is documented for Azure SQL Database only, so on T1 and T2 it can decline, and on T3 the service manages tempdb.
fallback: Without an agent, run Learn telemetry sample queries 5, 8, and 9 in the Azure Data Explorer web UI for the incident window, then show the waiting tasks in SSMS on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/databases/tempdb-database
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/resolve-pagelatch-ex-contention
reviewed: 2026-10-23
---

# Investigate tempdb latch contention with Copilot CLI or VS Code

The skills version of the [tempdb allocation contention](../../../scenarios/tempdb-contention/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 and 2 work on every target from anywhere. Prompts 3 and 4 need a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Latch waits from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} in resource group {resourceGroup} for {incidentWindow}, and report Buffer Latch waits by wait type with their task counts, average wait, and signal-wait share, next to the top three other wait categories. Don't change anything.
```

### 2. Temporary table activity

```text
For {incidentWindow} on {target}, adapt sample query 9 to report Temp Tables Creation Rate, SQL Compilations/sec, and SQL Re-Compilations/sec as rates, and sample query 8 to report the maximum Active Temp Tables and the minimum Free Space in tempdb (KB) as gauges. Say whether temporary table churn moved with the latch waits. Don't change anything.
```

### 3. Which pages, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Read sys.dm_os_waiting_tasks for sessions whose program_name starts with ContosoCare.Demo/tempdb-contention, and group their PAGELATCH waits by resource_description. Database 2 is tempdb; say whether the pages are allocation pages (PFS, GAM, SGAM) or system catalog pages, or that the skill doesn't apply to {target}. Don't change anything: don't add tempdb files, enable trace flags, or change any setting.
```

### 4. Line it up with the scenario record

```text
Read the latest tempdb-contention row from demo.scenario_runs in ContosoCare on {target}: run_id, status, started_at, deadline_at, stopped_at, and parameters. Compare its window and concurrency with the latch waits you found. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | SQL diagnostics skill (prompt 3) |
|---|---|---|
| T1 | `PAGELATCH_EX`, `PAGELATCH_SH`, and `PAGELATCH_UP` with many tasks and short average waits; `Temp Tables Creation Rate` up; `SQL Re-Compilations/sec` and CPU rising | Undocumented on SQL Server: the skill can decline. If it runs, resources that start with `2:` (tempdb) |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | Fewer latch waits, more CPU waits | Documented for the database's resources; tempdb's pages are the service's |

- In tempdb, page 1 of each file is PFS, page 2 is GAM, and page 3 is SGAM, and they repeat at fixed intervals. SQL Server 2022 relieves GAM and SGAM contention, so system catalog pages can dominate there.
- `PAGELATCH_*` is a latch on a page in memory; `PAGEIOLATCH_*` is a disk read and belongs to other scenarios.

## How to judge the answer

- Wait and counter values are deltas or rates over a UTC window that overlaps the scenario record.
- It separates Buffer Latch from Buffer IO and from Lock waits.
- When the skill declines on T1 or T2, it says so, and the answer rests on the telemetry.

## Safety

- Reject any change to tempdb files, trace flags, server configuration, or a restart, even as a test.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 5, 8, and 9 for the incident window.
2. On T2, through Bastion and the host, show `sys.dm_os_waiting_tasks` in SSMS or `sqlcmd` on the guest. Whether the image includes either is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
