---
id: showcase.skills
name: Tour the showcase across every target with Copilot CLI or VS Code
scenario: any
incident: true
targets: [T1, T2, T3]
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, scenario-record]
capability: Ranks the targets by pressure from the telemetry endpoint while the showcase runs, lists one target's incidents in order with their windows, and lines them up with the runs the scenario record holds, across T1, T2, and T3.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. Reading the scenario record needs line of sight to the target and a database identity with SELECT on the demo schema in ContosoCare.
responseShape: A ranked table of the targets with the dominant signal, its value, and the UTC window, then one target's incidents in time order next to the runs in the scenario record, then gaps and the KQL and T-SQL it ran.
previewLimitation: The telemetry endpoint and schema are previews. The showcase rotates incidents every few minutes and telemetry lags 3 to 15 minutes, so the newest slot can be missing. T4 (PostgreSQL) has no telemetry here; its metrics are in Azure Monitor.
fallback: Without an agent, run Learn telemetry sample queries 4 and 5 for each target in the Azure Data Explorer web UI, and read demo.scenario_runs through Bastion in SSMS.
actionPolicy: read-only
adrPrompts: [estate-health-summary, target-most-pressure, correlate-signals, baseline-vs-incident]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
reviewed: 2026-11-03
---

# Tour the showcase across every target with Copilot CLI or VS Code

The skills version of the showcase tour. Run [session-setup.skills](session-setup.skills.md) first, and start about 30 minutes after **Run all**, so the first cycle has reached the telemetry. Prompts 1 and 2 work on every target from anywhere; prompt 3 needs a SQL connection ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)). The schedule is in the [README](../../../README.md#what-fills-each-database-hub-visual-and-when).

## Prompts

### 1. Rank the targets

```text
Using the telemetry agent instructions, compare T1, T2, and T3 in {resourceGroup} for {incidentWindow}: CPU, waits by category, blocking, and deadlocks. Rank the targets by pressure in a table with the value and the UTC window, and compare with {baselineWindow}. Don't change anything.
```

### 2. One target's incidents in order

```text
For {target} during {incidentWindow}, use the telemetry to find each distinct incident in time order: the wait category or counter that marks it, its start and end, and its peak. Don't change anything.
```

### 3. Line them up with the runs

```text
On the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password, read demo.scenario_runs for {incidentWindow} and line each run up with the incidents you found. Say which runs left no signal yet. Don't change anything.
```

## Signals to look for

| Target | Wait categories and counters by slot |
|---|---|
| T1 | Lock and `Processes blocked` (blocking chain); Tran Log IO (log flushes); deadlocks; CPU |
| T2 | CPU; Memory; Buffer IO and IO stalls; Parallelism (odd cycles) or Buffer Latch (even cycles) |
| T3 | CPU against the tier; Lock or deadlocks; Network IO (cycle 1), reads (even cycles), or a plan regression's CPU step (cycle 3); Log Rate Governor |

- The scenario record's `started_at` and `deadline_at` give each run's window; telemetry follows 3 to 15 minutes later.

## How to judge the answer

- Every ranked value has a metric and a window, and the KQL it ran is shown.
- Each incident lines up with a run in the scenario record, and a run without a signal yet is called out, not invented.
- It treats the newest minutes as possibly missing, not as healthy.

## Safety

- Reject every command that changes anything; this beat only reads. The showcase stops by itself, and the control notebook's Stop now and Reset are the demo's own controls.
- Never connect with a SQL login or a password.

## Fallback demo

1. Without an agent: run Learn telemetry sample queries 4 and 5 for each target in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
2. Read `demo.scenario_runs` in SSMS through Bastion.
3. Last resort: the screenshots recorded in the rehearsal.
