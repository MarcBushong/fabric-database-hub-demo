---
id: blocking-chain.skills
name: Investigate a deep blocking chain with Copilot CLI or VS Code
scenario: blocking-chain
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills, scenario-record]
capability: Confirms blocking on any target from the telemetry endpoint (processes blocked, Lock-category waits, active transactions, and throughput), then, where a SQL connection is possible, walks the whole chain level by level with the microsoft-sql blocking skill, finds the head blocker and any table-level lock, and lines both up with the scenario record and its lock-escalation events.
permission: Telemetry prompts need the Azure CLI signed in as you, Reader or higher on the subscription, and Microsoft.Sql registered. T-SQL prompts need network line of sight to the target and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: A verdict, then a table of signals with the metric, UTC window, and value, then the chain as a tree from the head blocker with each session's wait type and wait time when a SQL connection exists, then gaps, then the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews and have no session-level blocking detail. The microsoft-sql blocking skill is documented for Azure SQL Database; it doesn't treat SQL Server as the same product, so on T1 and T2 it can decline. Lock escalation counters are in the detailed counters table only if the target lists them.
fallback: Without an agent, run Learn telemetry sample queries 8, 5, and 9 in the Azure Data Explorer web UI for the incident window, then show the chain from sys.dm_exec_requests in SSMS or sqlcmd on the VM through Bastion.
actionPolicy: read-only
adrPrompts: [investigate-locking, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql
reviewed: 2026-10-23
---

# Investigate a deep blocking chain with Copilot CLI or VS Code

The skills version of the [deep blocking chain](../../../scenarios/blocking-chain/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompts 1 and 2 work on every target from anywhere. Prompts 3 and 4 need a SQL connection, which only a client inside the demo network has (see [line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. Blocking from the telemetry

```text
Using the telemetry agent instructions, check {target} in resource group {resourceGroup} for blocking during {incidentWindow}. Adapt sample query 8 to report the maximum processes blocked and active transactions in 1-minute bins, and sample query 5 to the target's ResourceID for Lock-category waits by wait type, with their task counts and average wait. Don't change anything.
```

### 2. Escalation and throughput

```text
For {incidentWindow} on {target}, adapt sample query 9 to report Batch Requests/sec as a rate in 1-minute bins. Then list the counters in SqlServerPerformanceCountersDetailed for {target} whose names mention lock escalation and, if there are any, report their deltas for the same window under the rule for cumulative counters. Say whether throughput dropped when escalations happened. Don't change anything.
```

### 3. The whole chain, with the SQL diagnostics skill

```text
Use the diagnose-blocking-and-deadlocks skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. Show the whole chain as a tree from the head blocker, with each session's blocking_session_id, wait type, wait time, and wait resource, and for the head blocker its status, open transaction count, program_name, and last statement. If {target} runs SQL Server, also read sys.dm_tran_locks for OBJECT locks in ContosoCare and say whether one session holds a table lock. Don't change anything: don't create tables or Extended Events sessions, don't grant permissions, don't KILL a session, and don't reproduce the block.
```

### 4. Line it up with the scenario record

```text
Read the latest blocking-chain row from demo.scenario_runs in ContosoCare on {target}: run_id, status, started_at, deadline_at, stopped_at, parameters, and expected_symptoms, and that run's lock-escalation events from demo.scenario_run_events. Compare the depth, branches, and escalation times in the record with what you found, and say whether every blocked session's program_name matches the run. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompts 1 and 2) | SQL diagnostics skill (prompts 3 and 4) |
|---|---|---|
| T1 (default) | `Processes blocked` near the number of waiting links; `LCK_M_U` waits with few tasks and long average waits, plus `LCK_M_IS` and `LCK_M_IX` behind an escalation; `Active Transactions` up; batch requests dip while the table lock is held | Undocumented on SQL Server: the skill can decline. If it runs, a tree under one head blocker whose `program_name` starts with `ContosoCare.Demo/blocking-chain/`, and an `OBJECT` lock in `X` mode during an escalation |
| T2 | The same as T1 | The same as T1 |
| T3 | `Processes blocked` and Lock waits on transaction-ID locks (`LCK_M_S_XACT_MODIFY`); no escalation | Documented: the tree, the head blocker (idle with an open transaction between its updates), and its last statement |

- Few long waits point to blocking; many short waits point to throughput pressure. The Learn page's guidance for sample query 5 explains the difference.
- Each link waits 60 seconds at most, so the chain can drop a level and rebuild while you watch.

## How to judge the answer

- Every number has a metric, a UTC window, and a resource; wait counts are deltas, not sums.
- The tree, when shown, ends at sessions tagged `ContosoCare.Demo/` in `ContosoCare`, and its window overlaps the scenario record.
- It reports a table lock only with a lock it saw or a `lock-escalation` event, and never on T3.
- When the blocking skill declines on T1 or T2, it says so instead of guessing, and the answer falls back to telemetry.

## Safety

- The blocking skill's own guide includes steps that change things: creating a test table to reproduce a block, and granting a server role or a database permission. Reject both; the prompt forbids them.
- T3 accepts Microsoft Entra authentication only. Reject any command that uses a SQL login or a password.
- Approve `sqlcmd` or `Invoke-Sqlcmd` commands only when they run `SELECT` statements against `ContosoCare`.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 8, 5, and 9 for the incident window.
2. On T1, through Bastion, show the chain from `sys.dm_exec_requests` (`blocking_session_id`) in SSMS or `sqlcmd`. Whether the image includes either is TODO(verify); the bootstrap itself uses neither.
3. Last resort: the screenshots recorded in the rehearsal.
