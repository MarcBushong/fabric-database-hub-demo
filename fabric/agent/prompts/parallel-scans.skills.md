---
id: parallel-scans.skills
name: Investigate parallelism waits with Copilot CLI or VS Code
scenario: parallel-scans
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Measures Parallelism and CPU waits, CPU, and throughput on any target from the telemetry endpoint and compares them with the baseline, then, where a SQL connection is possible, reads the scenario statement's cached plan and the live degree of parallelism with the microsoft-sql plan skill.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict, then a table of waits, CPU, and batch requests for the baseline and incident windows, then the plan's parallelism and the sessions' live degree of parallelism when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews and have no plans. The plan skill is documented for Azure SQL Database, so on T1 and T2 it can decline, and on T3 at 1 vCore or less the plans are serial.
fallback: Without an agent, run Learn telemetry sample queries 4, 5, and 9 in the Azure Data Explorer web UI for both windows, then show the plan from Query Store in SSMS on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [inefficient-queries, correlate-signals, baseline-vs-incident, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/query-processing-architecture-guide
  - https://learn.microsoft.com/sql/database-engine/configure-windows/configure-the-max-degree-of-parallelism-server-configuration-option
reviewed: 2026-10-23
---

# Investigate parallelism waits with Copilot CLI or VS Code

The skills version of the [parallelism waits](../../../scenarios/parallel-scans/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 and 2 work on every target from anywhere. Prompt 3 needs a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Parallelism and CPU from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} in resource group {resourceGroup} for {incidentWindow} and report Parallelism and CPU waits by wait type with their task counts, average wait, and signal-wait share, and sample query 4 for CPU in 1-minute bins over the same window. Don't change anything.
```

### 2. Baseline compared with the incident

```text
Compare {baselineWindow} and {incidentWindow} on {target}: adapt sample query 9 for Batch Requests/sec as a rate, sample query 4 for average CPU, and sample query 5 for the share of Parallelism waits in each window. Say what changed and by how much. Don't change anything.
```

### 3. The plan, with the SQL diagnostics skill

```text
Use the read-execution-plan skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. For sessions whose program_name starts with ContosoCare.Demo/parallel-scans, read the dop column of sys.dm_exec_requests, then get their statement's cached plan from sys.dm_exec_query_plan or Query Store, without running it. Report whether the plan is parallel, its parallelism operators, its memory grant, and any warnings. Don't change anything: don't run the query, don't use SET STATISTICS XML, and don't change MAXDOP or any setting.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | Plan skill (prompt 3) |
|---|---|---|
| T1 | `CXPACKET`, `CXCONSUMER`, and `CXSYNC_PORT` waits; CPU high; `SOS_SCHEDULER_YIELD` with a high signal-wait share when sessions outnumber schedulers | Undocumented on SQL Server: the skill can decline. If it runs, a parallel plan with exchange operators, and `dop` 2 |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | CPU waits without Parallelism waits | Documented: a serial plan, because there's no second scheduler |

- No hint forces parallelism: the scenario's statement costs well above the default cost threshold for parallelism and carries only a `MAXDOP` hint, and it groups by a skewed key, so the threads get uneven work.

## How to judge the answer

- Waits are deltas over each window, and the baseline and incident windows have the same length.
- It reads Parallelism waits with CPU and throughput, and doesn't treat `CXCONSUMER` alone as a problem.
- When the plan skill declines on T1 or T2, it says so, and the answer rests on the telemetry.

## Safety

- Reject any change to MAXDOP, the cost threshold for parallelism, database scoped configurations, or the scenario's query, even as a test.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 4, 5, and 9 for both windows.
2. Through Bastion, show the statement's plan from Query Store in SSMS. Whether the image includes SSMS is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
