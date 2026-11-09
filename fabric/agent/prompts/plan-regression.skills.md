---
id: plan-regression.skills
name: Find a plan regression and its automatic correction with Copilot CLI or VS Code
scenario: plan-regression
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Shows the CPU step from the telemetry endpoint, then on T3 reads Query Store and sys.dm_db_tuning_recommendations to find the query whose plan regressed, the two plans, the estimated gain, and whether automatic tuning forced the last good plan. T1 and T2 serve as controls.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. The T-SQL prompts need line of sight to T3 and a Microsoft Entra database identity with VIEW DATABASE STATE in ContosoCare.
responseShape: The CPU step with the metric, UTC window, and value, then the regressed query with both plan IDs and their average CPU, then the tuning recommendation with its reason, estimated gain, and state, then gaps and the KQL and T-SQL it ran.
previewLimitation: The telemetry has no query text or plans. The tuning DMV is Azure SQL Database's on T3; SQL Server 2022 Standard on T1 and T2 has no automatic tuning. When the engine forces a plan isn't documented.
fallback: Without an agent, run Learn telemetry sample query 4 in the Azure Data Explorer web UI for the CPU step, then show the T3 database's automatic tuning page in the Azure portal and Query Store's Regressed Queries report in SSMS.
actionPolicy: read-only
adrPrompts: [target-most-pressure, inefficient-queries, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/automatic-tuning/automatic-tuning
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-tuning-recommendations-transact-sql
reviewed: 2026-11-03
---

# Find a plan regression and its automatic correction with Copilot CLI or VS Code

The skills version of the [plan regression](../../../scenarios/plan-regression/README.md) incident, which runs on T3 only. Run [session-setup.skills](session-setup.skills.md) first, and warm T3 up so it isn't paused. Prompt 1 works on every target from anywhere; prompts 2 and 3 need a SQL connection to T3 ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. The CPU step

```text
Using the telemetry agent instructions, adapt sample query 4 to {target} for {incidentWindow} and find when CPU stepped up and whether it came back down. Compare it with {baselineWindow}. Don't change anything.
```

### 2. The regressed query

```text
On the ContosoCare database of {target}, connected as me with Microsoft Entra authentication, never with a SQL login or password, read Query Store for {incidentWindow}: find the query whose average CPU per execution rose most between two plans, and show both plan IDs, their execution counts, and their average CPU. Don't change anything, and don't re-run the query.
```

### 3. The tuning recommendation

```text
On the same database, read sys.dm_db_tuning_recommendations and sys.database_automatic_tuning_options. For the query you found, show the recommendation's reason, estimated gain, state, and whether its plan is forced now, and the desired and actual state of FORCE_LAST_GOOD_PLAN. Don't change anything.
```

## Signals to look for

| Target | Telemetry (prompt 1) | Database evidence (prompts 2 and 3) |
|---|---|---|
| T1 | No step from this scenario | No automatic tuning; the tuning DMV doesn't apply |
| T2 | The same as T1 | The same as T1 |
| T3 (default) | CPU steps up at the switch, and down once the plan is forced | One query with two plans in Query Store, the later one far costlier per execution; a `FORCE_LAST_GOOD_PLAN` recommendation for it, with its state |

- Learn: with `FORCE_LAST_GOOD_PLAN` on, the engine forces a recommendation whose estimated CPU gain is over 10 seconds, then verifies that the forced plan is better.

## How to judge the answer

- It ties the CPU step to one query's plan change, with plan IDs and average CPU from Query Store.
- It reads the recommendation's state instead of assuming the plan was forced.
- It doesn't propose forcing or unforcing anything.

## Safety

- Reject every command that contains `sp_query_store_force_plan`, `sp_query_store_unforce_plan`, `ALTER DATABASE`, or `sp_recompile`. The scenario's own run and reset are the only things that recompile or unforce, and only for its lookup.
- Never connect with a SQL login or a password.

## Fallback demo

1. Without an agent: run Learn telemetry sample query 4 for T3 in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
2. In the Azure portal, open the T3 database's **Automatic tuning** page and its history.
3. In SSMS through Bastion, open Query Store's **Regressed Queries** and **Queries With Forced Plans** reports for `ContosoCare`.
4. Last resort: the screenshots recorded in the rehearsal.
