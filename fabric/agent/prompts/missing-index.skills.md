---
id: missing-index.skills
name: Find a missing index and propose a fix with Copilot CLI or VS Code
scenario: missing-index
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Shows the read-heavy resource symptom on any target from the telemetry endpoint and, where a SQL connection exists, reads the missing-index DMVs and the plan's missing-index hint, then drafts one index as unexecuted text with its risk, rollback, and before-and-after measure.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. T-SQL prompts need line of sight and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest). Creating the index would need ALTER on the table, which this beat never uses.
responseShape: The resource symptom with the metric, UTC window, and value, then the candidate index with the DMV figures behind it, then the drafted statement as text, its risk, rollback, and measure, then gaps and the KQL and T-SQL it ran.
previewLimitation: The telemetry has no query text or plans. The microsoft-sql plan skill is documented for Azure SQL Database and can decline on SQL Server targets. Missing-index suggestions are hints to combine with existing indexes, and they're kept only until the database engine restarts.
fallback: Without an agent, run Learn telemetry sample queries 4 and 5 in the Azure Data Explorer web UI, then show the missing-index hint in the scenario query's plan in SSMS through Bastion.
actionPolicy: propose-only
adrPrompts: [inefficient-queries, safest-next-action, actions-needing-approval]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-missing-index-details-transact-sql
reviewed: 2026-10-20
---

# Find a missing index and propose a fix with Copilot CLI or VS Code

The skills version of the [missing index](../../../scenarios/missing-index/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompt 1 works on every target from anywhere; prompts 2 to 4 need a SQL connection ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. The resource symptom

```text
Using the telemetry agent instructions, adapt sample query 5 to {target} for {incidentWindow} and show Buffer IO waits, and sample query 4 for CPU over the same window. Say whether the pattern fits large scans. Don't change anything.
```

### 2. Missing-index evidence

```text
On the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password, read sys.dm_db_missing_index_details, sys.dm_db_missing_index_groups, and sys.dm_db_missing_index_group_stats for tables in the care schema. Rank the suggestions by their estimated improvement and show the figures you used. Don't change anything.
```

### 3. Confirm it in the plan

```text
Use the read-execution-plan skill to find the Query Store query with the most logical reads in ContosoCare on {target} during {incidentWindow}, and read its plan from Query Store. Report scans, estimated versus actual rows if the plan has them, and any missing-index hint. Don't change anything, and don't re-run the query.
```

### 4. Draft the fix, without running it

```text
Draft one index for the top suggestion as a T-SQL statement shown as text. Explain the expected effect, the write and storage cost, how to roll it back, and how to measure before and after. List which steps need approval and from whom. Don't apply anything; propose only.
```

## Signals to look for

| Target | Telemetry (prompt 1) | Database evidence (prompts 2 and 3) |
|---|---|---|
| T1 | Buffer IO waits (`PAGEIOLATCH_*`) and CPU up during the run | Missing-index DMV rows for a `care` table; a missing-index hint in the plan. The plan skill can decline on SQL Server |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | The same against the tier's limits | Documented for the plan skill: the hint and the scan in the Query Store plan |

- Missing-index suggestions are hints: Learn says to combine them with each other and with existing indexes, and they're kept only until the database engine restarts.

## How to judge the answer

- The candidate index is tied to DMV figures or a plan hint, not guessed.
- The drafted statement appears only as text, with a rollback and a measure.
- It warns about write cost and overlapping indexes.
- It says when the plan skill declines on T1 or T2.

## Safety

- Reject every command that contains `CREATE`, `ALTER`, `DROP`, or `SET STATISTICS XML`. The plan skill's guide re-runs queries for actual plans; this prompt reads stored plans only.
- The fix is applied by a person, with the scenario's remediation script, after the approval beat (Phase 11). The agent never applies it.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 4 and 5 for the incident window.
2. Through Bastion, show the scenario query's plan and its missing-index hint in SSMS. SSMS on the image is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
