---
id: slow-consumer.skills
name: Investigate a slow client with Copilot CLI or VS Code
scenario: slow-consumer
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills, scenario-record]
capability: Measures Network IO waits, attentions, CPU, and throughput on any target from the telemetry endpoint, follows the scenario's sessions through the active sessions samples, and, where a SQL connection is possible, checks with the microsoft-sql resource pressure skill that no resource limit of the database is the constraint.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict on database versus client, then a table of waits, attentions, and CPU over the UTC window, then how long each scenario session stayed active, then the sessions' waits and resource use when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews; SqlServerActiveSessions has no program name or wait columns, so sessions are matched through the scenario record. The resource pressure skill is documented for Azure SQL Database only, so on T1 and T2 it can decline.
fallback: Without an agent, run Learn telemetry sample queries 5 and 9 in the Azure Data Explorer web UI for the incident window, then show sys.dm_exec_requests in SSMS on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-query-async-network-io
reviewed: 2026-10-23
---

# Investigate a slow client with Copilot CLI or VS Code

The skills version of the [slow consumer](../../../scenarios/slow-consumer/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompt 1 works on every target from anywhere. Prompts 2 and 3 need the scenario record or a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Network waits from the telemetry

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} in resource group {resourceGroup} for {incidentWindow} and report Network IO waits with their task counts and average wait next to the top three other wait categories. Then adapt sample query 9 to report SQL Attention rate and Batch Requests/sec as rates, and sample query 4 for CPU over the same window. Don't change anything.
```

### 2. How long the sessions stayed active

```text
Read the session_ids, started_at, and stopped_at of the latest slow-consumer row in demo.scenario_runs in ContosoCare on {target}. Then write a KQL query on SqlServerActiveSessions for {target} over {incidentWindow} that, for those session IDs in ContosoCare, reports the first and last sample each appears in and its SessionStatus over time. Don't change anything.
```

### 3. No resource limit, with the SQL diagnostics skill

```text
Use the diagnose-resource-pressure skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Read sys.dm_exec_requests and sys.dm_exec_sessions for sessions whose program_name starts with ContosoCare.Demo/slow-consumer: their wait type, wait time, CPU time, and reads, and the client's host_name. Tell me whether any resource limit of the database is the constraint, or say that the skill doesn't apply to {target}. Don't change anything: don't KILL a session or change any setting.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | SQL diagnostics skill (prompt 3) |
|---|---|---|
| T1 | `ASYNC_NETWORK_IO` with few tasks and long average waits; `SQL Attention rate` above 0; CPU flat; the sessions active for minutes | Undocumented on SQL Server: the skill can decline. If it runs, the sessions wait on `ASYNC_NETWORK_IO` with little CPU, and the host is the VM itself |
| T2 | The same as T1 | The same as T1, with the guest as the host |
| T3 (default) | The same wait and counter; CPU well below the tier limit | Documented: no governed limit near its ceiling, and the host is T1 |

- `SQL Attention rate` counts cancellations from the client, here the runner ending its slow reads at the deadline or on a stop request.

## How to judge the answer

- Every number has a metric, a UTC window, and a resource; waits and attentions are deltas or rates, not sums.
- It concludes on the client side only with the evidence that the database's own resources stayed below their limits.
- When the skill declines on T1 or T2, it says so, and the answer rests on the telemetry.

## Safety

- Reject any command that ends sessions, changes network or packet size settings, or scales the database.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 5 and 9 for the incident window.
2. On T1, through Bastion, show `sys.dm_exec_requests` for the scenario's sessions in SSMS or `sqlcmd`. Whether the image includes either is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
