---
id: log-flush-waits.skills
name: Investigate transaction log flush waits with Copilot CLI or VS Code
scenario: log-flush-waits
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills, scenario-record]
capability: Measures Tran Log IO and Log Rate Governor waits, commit and log flush rates, and log file writes on any target from the telemetry endpoint, following the Learn rules for cumulative counters, then, where a SQL connection is possible, reads log file stats and the log write percentage with the microsoft-sql resource pressure skill and lines them up with the scenario record.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict on commits versus storage versus a cap, then a table of waits and rates over the UTC window, then the log file's write deltas and average bytes per write, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews; there's no Learn sample query for SqlServerStorageIO, so the agent writes that KQL itself under the documented rules, and per-file latency isn't supported for Azure SQL Database. The resource pressure skill is documented for Azure SQL Database only.
fallback: Without an agent, run Learn telemetry sample queries 5 and 9 in the Azure Data Explorer web UI for the incident window, then show the target's IO on the Database Hub Performance page.
actionPolicy: read-only
adrPrompts: [correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-io-virtual-file-stats-transact-sql
reviewed: 2026-10-23
---

# Investigate transaction log flush waits with Copilot CLI or VS Code

The skills version of the [log flush waits](../../../scenarios/log-flush-waits/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 and 2 work on every target from anywhere. Prompts 3 and 4 need a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Log waits and commit rates from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} in resource group {resourceGroup} for {incidentWindow} and report Tran Log IO and Log Rate Governor waits with their task counts and average wait. Then adapt sample query 9 to report Transactions/sec, Write Transactions/sec, Log Flushes/sec, and Log Bytes Flushed/sec for the ContosoCare instance of each counter as rates; Log Flushes/sec exists on SQL Server only. Don't change anything.
```

### 2. Log file writes

```text
Write a KQL query on SqlServerStorageIO for {target} over {incidentWindow}, following the rule for cumulative counters, and report for the ContosoCare log file the delta of writes, bytes written, and write stall, and the average bytes per write. If {target} is an Azure SQL database, don't compute per-file latency. Don't change anything.
```

### 3. The limit, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Read sys.dm_io_virtual_file_stats for the log file and, if {target} is an Azure SQL database, avg_log_write_percent from sys.dm_db_resource_stats. Tell me whether log storage latency, the log rate limit, or the number of commits is the constraint, or say that the skill doesn't apply to {target}. Don't change anything: don't change durability, the recovery model, or any setting.
```

### 4. Line it up with the scenario record

```text
Read the latest log-flush-waits row from demo.scenario_runs in ContosoCare on {target}: run_id, status, started_at, deadline_at, stopped_at, and parameters, and the current row count of demo.commit_scratch. Compare that window with the waits you found. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | SQL diagnostics skill (prompt 3) |
|---|---|---|
| T1 (default) | `WRITELOG` with many tasks and a low average wait; `Log Flushes/sec` close to `Transactions/sec`; small average bytes per log write | Undocumented on SQL Server: the skill can decline. If it runs, many small log writes with a short average stall |
| T2 | The same as T1, with longer stalls from the nested host's disk | The same as T1 |
| T3 | `WRITELOG`, and Log Rate Governor past the service objective's log rate; no `Log Flushes/sec` | Documented: `avg_log_write_percent` against the tier's limit |

- Each commit writes about half a kilobyte of log, so the average bytes per write stays small; the [log rate pressure](log-rate-pressure.skills.md) scenario writes large batches instead.

## How to judge the answer

- Cumulative counters are deltas between adjacent samples, with resets skipped, never sums or last-minus-first.
- It separates commit frequency from storage latency with the task count, the average wait, and the bytes per write.
- When the skill declines on T1 or T2, it says so, and the answer rests on the telemetry.

## Safety

- Reject delayed durability, a recovery model change, moving or resizing the log, or a tier change, even as a test.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements against `ContosoCare`.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 5 and 9 for the incident window.
2. Show the target's IO on the Database Hub Performance page.
3. Last resort: the screenshots recorded in the rehearsal.
