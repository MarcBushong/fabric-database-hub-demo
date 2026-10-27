---
id: locking-blocking.skills
name: Investigate locking and blocking with Copilot CLI or VS Code
scenario: locking-blocking
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills, scenario-record]
capability: Confirms blocking on any target from the telemetry endpoint (processes blocked, Lock-category waits, active transactions, deadlocks, and throughput), then, where a SQL connection is possible, reads the blocking chain and the head blocker with the microsoft-sql blocking skill and lines it up with the scenario record.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict, then a table of signals with the metric, UTC window, and value, then the blocking chain when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews and have no query-level detail. The microsoft-sql blocking skill is documented for Azure SQL Database; it doesn't treat SQL Server as the same product, so on T1 and T2 it can decline. The Database Hub skill doesn't cover blocking at all.
fallback: Without an agent, run Learn telemetry sample queries 8, 5, and 9 in the Azure Data Explorer web UI for the incident window, then show the blocking chain in SSMS or sqlcmd on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [investigate-locking, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking
reviewed: 2026-10-20
---

# Investigate locking and blocking with Copilot CLI or VS Code

The skills version of the [locking and blocking](../../../scenarios/locking-blocking/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 and 2 work on every target from anywhere. Prompts 3 and 4 need a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Blocking from the telemetry

```text
Using the telemetry agent instructions, check {target} in resource group {resourceGroup} for blocking during {incidentWindow}. Adapt sample query 8 to that window and resource group, then sample query 5 to the target's ResourceID. Report processes blocked, Lock-category waits with their task counts and average wait, and active transactions. Don't change anything.
```

### 2. Throughput, deadlocks, and CPU at the same time

```text
For {incidentWindow} on {target}, adapt sample query 9 to report Number of Deadlocks/sec as a total and Batch Requests/sec as a rate, and sample query 4 to show CPU over the same window. Say whether throughput, deadlocks, or CPU moved with the blocking, and keep coincidence apart from cause. Don't change anything.
```

### 3. The blocking chain, with the SQL diagnostics skill

```text
Use the diagnose-blocking-and-deadlocks skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Show who blocks whom, and for the head blocker its status, open transaction count, program_name, and last statement. Don't change anything: don't create tables or Extended Events sessions, don't grant permissions, don't KILL a session, and don't reproduce the block.
```

### 4. Line it up with the scenario record

```text
Read the latest locking-blocking rows from demo.scenario_runs in ContosoCare on {target}: run_id, target, status, started_at, deadline_at, stopped_at, and expected_symptoms. Compare that window with what you found, and say whether the blocking sessions' program_name matches the run. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | SQL diagnostics skill (prompt 3) |
|---|---|---|
| T1 (default) | `Processes blocked` above 0; `LCK_M_*` waits in the Lock category with few tasks and long average waits; `Active Transactions` up; deadlocks flat unless the optional deadlock runs | Undocumented on SQL Server: the skill can decline. If it runs, a chain whose head blocker's `program_name` starts with `ContosoCare.Demo/` |
| T2 | The same as T1 | The same as T1 |
| T3 | Lock-category waits and `Processes blocked`; optimized locking means writer-to-writer waits can be on `XACT` resources | Documented: the chain, the head blocker (possibly idle with an open transaction), and its last statement |

- Few long waits point to blocking; many short waits point to throughput pressure. The Learn page's guidance for query 5 explains the difference.
- `SqlServerClientConnections` (SQL Server only, hourly) can show the runner's program names on T1 and T2.

## How to judge the answer

- Every number has a metric, a UTC window, and a resource. Wait and deadlock counts are deltas, not sums.
- The chain, when shown, ends at a session tagged `ContosoCare.Demo/` in `ContosoCare`, and the window overlaps the scenario record.
- When the blocking skill declines on T1 or T2, it says so instead of guessing, and the answer falls back to telemetry.

## Safety

- The blocking skill's own guide includes steps that change things: creating a test table to reproduce a block, and granting a server role or a database permission. Reject both; the prompt forbids them.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements against `ContosoCare`.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 8, 5, and 9 for the incident window.
2. On T1, through Bastion, show the blocking chain from `sys.dm_exec_requests` in SSMS or `sqlcmd`. Whether the image includes either is TODO(verify); the bootstrap itself uses neither.
3. Last resort: the screenshots recorded in the rehearsal.
