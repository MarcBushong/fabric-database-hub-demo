---
id: plan-regression.in-hub
name: Find a plan regression and its automatic correction in Database Hub
scenario: plan-regression
incident: true
targets: [T1, T2, T3]
defaultTarget: T3
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds when the chosen target's CPU stepped up because one query's plan changed, tells a plan regression from more load, and says whether automatic tuning forced the last good plan on T3. T1 and T2 serve as controls, because SQL Server 2022 Standard has no automatic tuning.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and the performance monitoring extended property set on ContosoCare for T3. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict naming the change, regression or more load, with the UTC time of the step, then a table of signals with the metric, window, and value, then whether a plan was forced and when, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage; Database Hub's telemetry describes resources, not queries, so the plans themselves are in Query Store and sys.dm_db_tuning_recommendations. When automatic tuning forces a plan isn't documented.
fallback: Run plan-regression.skills in Copilot CLI. Without an agent, show the T3 database's automatic tuning page in the Azure portal, and Query Store's Regressed Queries report in SSMS.
actionPolicy: read-only
adrPrompts: [target-most-pressure, correlate-signals, inefficient-queries]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/relational-databases/automatic-tuning/automatic-tuning
  - https://learn.microsoft.com/azure/azure-sql/database/automatic-tuning-overview
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-tuning-recommendations-transact-sql
reviewed: 2026-11-03
---

# Find a plan regression and its automatic correction in Database Hub

The T3-only incident of the showcase: the [plan regression](../../../scenarios/plan-regression/README.md) scenario makes one query's plan regress, and Azure SQL Database's automatic tuning can force the last good plan within the session. On T1 and T2 the same prompts act as controls: those targets have no automatic tuning, and the scenario doesn't run there.

Warm T3 up first, because a paused serverless database has no telemetry ([serverless auto-pause](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)).

**Where to type it:** open the T3 database from Estate or Performance, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. What changed

```text
On {target} during {incidentWindow}, CPU stepped up partway through the window. Is that more load, or the same work getting more expensive? Give the UTC time of the step and the signals that tell the two apart. Don't change anything.
```

### 2. One query or many

```text
Did one query's plan change on {target} during {incidentWindow}, and did its cost per execution go up? Tell me what you can see and what would need Query Store. Don't change anything.
```

### 3. Was it corrected

```text
Has automatic tuning forced a better plan on {target} since {incidentWindow} began, and did CPU come back down afterward? If you can't see tuning actions, say so and where I'd look. Don't change anything.
```

## Signals to look for

| Target | Signals | What they mean |
|---|---|---|
| T3 (default) | CPU steps up at the switch with the same session count and request rate; it steps back down when the plan is forced | One query got more expensive per execution, not more load |
| T1 | No such step from this scenario; automatic tuning isn't available | A control |
| T2 | The same as T1 | A control |

- The proof is in Query Store and the tuning DMV, which Database Hub doesn't show: `sys.dm_db_tuning_recommendations` lists a `FORCE_LAST_GOOD_PLAN` recommendation with its estimated gain and state, and the Azure portal's automatic tuning page shows the same.

## How to judge the answer

- It tells a regression (cost per execution up, load flat) from more load (more requests or sessions).
- It doesn't claim a forced plan it can't see, and points to Query Store or the tuning DMV for the plans.
- On T1 and T2, it doesn't report automatic tuning.

## Safety

- If the agent proposes forcing or unforcing a plan, read it out and cancel it. The scenario's next run and its reset unforce only its own query's plan.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [plan-regression.skills](plan-regression.skills.md) in Copilot CLI.
2. Without an agent: in the Azure portal, open the T3 database's **Automatic tuning** page and its history.
3. In SSMS through Bastion, open Query Store's **Regressed Queries** and **Queries With Forced Plans** reports for `ContosoCare`.
4. Last resort: the screenshots recorded in the rehearsal.
