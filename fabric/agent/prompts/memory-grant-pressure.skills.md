---
id: memory-grant-pressure.skills
name: Investigate memory grant pressure with Copilot CLI or VS Code
scenario: memory-grant-pressure
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Measures Memory-category waits, the grant clerk, granted workspace memory, and page life expectancy on any target from the telemetry endpoint, then, where a SQL connection is possible, lists granted and waiting grants with the microsoft-sql resource pressure skill and reads the cached plan's memory grant with the plan skill.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict, then a table of memory waits, clerks, and counters over the UTC window, then the grants (requested, granted, used, waiting) and the plan's memory grant when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews and have no query-level detail; Memory Grants Pending is in the detailed counters table only if the target lists it. The resource pressure and plan skills are documented for Azure SQL Database, so on T1 and T2 they can decline.
fallback: Without an agent, run Learn telemetry sample queries 5, 7, and 8 in the Azure Data Explorer web UI for the incident window, then show sys.dm_exec_query_memory_grants in SSMS on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [correlate-signals, inefficient-queries, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-memory-grants-transact-sql
reviewed: 2026-10-23
---

# Investigate memory grant pressure with Copilot CLI or VS Code

The skills version of the [memory grant pressure](../../../scenarios/memory-grant-pressure/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 and 2 work on every target from anywhere. Prompts 3 and 4 need a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Memory waits and clerks from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} in resource group {resourceGroup} for {incidentWindow} and report Memory-category waits by wait type with their task counts and average wait. Then adapt sample query 7 for the largest memory clerks near the start and the end of the window, and say whether MEMORYCLERK_SQLQERESERVATIONS grew. Don't change anything.
```

### 2. Workspace memory and page life expectancy

```text
For {incidentWindow} on {target}, adapt sample query 8 to report Granted Workspace Memory (KB) and Page life expectancy in 1-minute bins, and list the counters in SqlServerPerformanceCountersDetailed whose names mention memory grants, with their values for the same window. Don't change anything.
```

### 3. Grants now, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Read sys.dm_exec_query_memory_grants joined to sys.dm_exec_sessions for sessions whose program_name starts with ContosoCare.Demo/memory-grant-pressure, and report requested, granted, and used memory, and how many are still waiting for a grant and for how long. Tell me whether memory grants or another limit is the constraint, or that the skill doesn't apply to {target}. Don't change anything: don't change memory settings, Resource Governor, or query hints.
```

### 4. The plan's memory grant

```text
Use the read-execution-plan skill on the ContosoCare database of {target}, with the same connection rules. Get the cached plan of the statement those sessions run from sys.dm_exec_query_plan or Query Store, without running it, and report its memory grant, its sort operator, and any warnings. Don't change anything: don't run the query, and don't use SET STATISTICS XML.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | SQL diagnostics skills (prompts 3 and 4) |
|---|---|---|
| T1 | `RESOURCE_SEMAPHORE` waits with few tasks and long average waits; `MEMORYCLERK_SQLQERESERVATIONS` growing; `Granted Workspace Memory (KB)` flat at its ceiling; `Page life expectancy` falling | Undocumented on SQL Server: the skills can decline. If they run, a few sessions with large grants and the rest waiting (`grant_time` empty) |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | The same wait type and clerk, within the service objective's memory | Documented: grants and waiters, and the plan's memory grant |

- The scenario's statement asks for a share of the most one query may get through the documented `MIN_GRANT_PERCENT` hint, so the grant in the plan is large on purpose; the finding is the queue, not the hint.

## How to judge the answer

- Waits and counters are deltas or gauges over a UTC window, never sums of cumulative values.
- The grants it lists belong to sessions tagged `ContosoCare.Demo/memory-grant-pressure/`.
- When a skill declines on T1 or T2, it says so, and the answer rests on the telemetry.

## Safety

- Reject any change to memory settings, Resource Governor, the scenario's query, or the service objective, even as a test.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 5, 7, and 8 for the incident window.
2. Through Bastion, show `sys.dm_exec_query_memory_grants` in SSMS or `sqlcmd`. Whether the image includes either is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
