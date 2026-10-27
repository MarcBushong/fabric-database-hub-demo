---
id: deadlock-storm.skills
name: Investigate repeated deadlocks with Copilot CLI or VS Code
scenario: deadlock-storm
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills, scenario-record]
capability: Counts deadlocks per minute on any target from the telemetry endpoint, with errors, throughput, and Lock waits, then, where a SQL connection is possible, reads existing deadlock graphs with the microsoft-sql blocking skill and reconciles the count with the scenario's victim events.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict, then a table of deadlocks, errors, and batch requests per 1-minute bin over the UTC window, then up to three deadlock graphs summarized (victim, resources, lock modes, statements) when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews and hold no deadlock graphs. The microsoft-sql blocking skill is documented for Azure SQL Database, where Learn documents no built-in system_health session, so graphs exist there only if a database-scoped session already captures them; on T1 and T2 the skill can decline.
fallback: Without an agent, run Learn telemetry sample queries 9 and 5 in the Azure Data Explorer web UI for the incident window, then show the system_health deadlock reports in SSMS on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [investigate-locking, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/sql-server-deadlocks-guide
  - https://learn.microsoft.com/sql/relational-databases/extended-events/use-the-system-health-session
reviewed: 2026-10-23
---

# Investigate repeated deadlocks with Copilot CLI or VS Code

The skills version of the [deadlock storm](../../../scenarios/deadlock-storm/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompt 1 works on every target from anywhere. Prompts 2 and 3 need a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Deadlocks per minute from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 9 to {target} in resource group {resourceGroup} for {incidentWindow} in 1-minute bins, and report Number of Deadlocks/sec as a total per bin, with Errors/sec and Batch Requests/sec as rates. Then adapt sample query 5 for the same window and report Lock-category waits with their task counts and average wait. Don't change anything.
```

### 2. The deadlock graphs, with the SQL diagnostics skill

```text
Use the diagnose-blocking-and-deadlocks skill on {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Read the most recent deadlock graphs only from a session that already captures them: on SQL Server, the system_health session; on Azure SQL Database, an existing database-scoped Extended Events session. For up to three graphs from {incidentWindow}, give the victim, the resources and lock modes, and each side's statement, or say that nothing captured them. Don't change anything: don't create or alter an Extended Events session, don't grant permissions, don't KILL a session, and don't reproduce a deadlock.
```

### 3. Reconcile with the scenario record

```text
Read the latest deadlock-storm row from demo.scenario_runs in ContosoCare on {target}: run_id, status, started_at, deadline_at, stopped_at, and parameters. Count that run's deadlock-victim events in demo.scenario_run_events per minute, compare them with the telemetry's deadlock totals for the same window, and explain any difference. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompt 1) | Deadlock graphs (prompt 2) |
|---|---|---|
| T1 (default) | Deadlocks above 0 in most bins; `Errors/sec` moving with them; short `LCK_M_X` and `LCK_M_U` waits | `system_health` keeps deadlock reports by default. The skill is documented for Azure SQL Database and can decline on SQL Server |
| T2 | The same as T1 | The same as T1 |
| T3 | The same counters | No built-in `system_health` session: graphs exist only if a database-scoped session already captures them, and the demo creates none |

- Victims run at `DEADLOCK_PRIORITY LOW`, so one side of each pair is always picked; graphs show the inventory rows of the `ContosoCare` pair and sessions tagged `ContosoCare.Demo/deadlock-storm/`.
- `Number of Deadlocks/sec` is sampled every minute, so per-minute totals can lag the victim events by a bin.

## How to judge the answer

- Deadlock counts are deltas per bin, with resets skipped, never sums of the cumulative counter.
- The telemetry totals and the victim events agree within a bin, or the answer explains why not.
- When no graph exists, it says so instead of creating a session to capture one.

## Safety

- The blocking skill's own guide creates a database-scoped Extended Events session to capture deadlocks on Azure SQL Database. Reject it; the prompt forbids it, and the demo never changes server or database configuration.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 9 and 5 for the incident window.
2. On T1, through Bastion, open the `system_health` session's deadlock reports in SSMS. Whether the image includes SSMS is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
