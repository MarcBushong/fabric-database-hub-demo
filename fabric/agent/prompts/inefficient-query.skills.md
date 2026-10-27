---
id: inefficient-query.skills
name: Find an inefficient query with Copilot CLI or VS Code
scenario: inefficient-query
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, sql-diagnostics-skills]
capability: Shows the resource-level cost on any target from the telemetry endpoint and, where a SQL connection exists, triages the expensive query with the microsoft-sql slow-query skill (volatile, blocked, regressed, or growing) and reads its stored plan, comparing the incident with the baseline.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. T-SQL prompts need line of sight and a database identity with VIEW DATABASE STATE on T3 (Microsoft Entra only), or VIEW SERVER PERFORMANCE STATE on T1 and T2 (Windows authentication on the VM or guest).
responseShape: The resource-level cost with the metric, UTC window, and value, then the query triage label with the Query Store figures behind it, then the plan facts, then the baseline-versus-incident comparison, then gaps and the KQL and T-SQL it ran.
previewLimitation: The telemetry has no query text or plans. The microsoft-sql slow-query and plan skills are documented for Azure SQL Database and can decline on SQL Server targets. Query Store in AUTO capture mode can skip infrequent queries.
fallback: Without an agent, run Learn telemetry sample queries 4, 7, and 9 in the Azure Data Explorer web UI, then the Query Store reports for ContosoCare in SSMS through Bastion.
actionPolicy: read-only
adrPrompts: [inefficient-queries, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql
  - https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store
reviewed: 2026-10-20
---

# Find an inefficient query with Copilot CLI or VS Code

The skills version of the [inefficient query](../../../scenarios/inefficient-query/README.md) incident. Run [session-setup.skills](session-setup.skills.md) first. Prompt 1 works on every target from anywhere; prompts 2 and 3 need a SQL connection ([line of sight](../README.md#part-4-line-of-sight-and-identities-for-t-sql-skills)).

## Prompts

### 1. The resource-level cost

```text
Using the telemetry agent instructions, for {target} in resource group {resourceGroup}, adapt sample query 4 to compare CPU in {baselineWindow} and {incidentWindow}, sample query 9 to compare Batch Requests/sec and SQL Compilations/sec, and sample query 7 to show the largest memory clerks during the incident. Don't change anything.
```

### 2. Triage the query, with the SQL diagnostics skill

```text
Use the diagnose-slow-query skill on the ContosoCare database of {target}, connected as me (Microsoft Entra on Azure SQL Database, Windows authentication on SQL Server), never with a SQL login or password. From Query Store, find the query whose cost rose most between {baselineWindow} and {incidentWindow}, and label it volatile, blocked, regressed, or growing, with the figures behind the label. Check the Query Store capture mode first. Don't change anything.
```

### 3. Read the plan

```text
Use the read-execution-plan skill to read the stored plan of that query from Query Store. Report operators that scan, estimated versus actual rows where the plan has them, warnings such as implicit conversions, and any missing-index hint. Don't change anything, and don't re-run the query.
```

## Signals to look for

| Target | Telemetry (prompt 1) | Query Store and plan (prompts 2 and 3) |
|---|---|---|
| T1 | CPU or reads up without a matching rise in batch requests; compilations up if the workload is ad hoc | Undocumented for the skills on SQL Server: they can decline. If they run, the scenario query shows more reads or duration per execution |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | The same against the tier's limits | Documented: the triage label, the Query Store figures, and the plan facts |

- Compilations above about a fifth of batch requests, or a growing ad hoc plan cache, point to unparameterized work (the Learn guidance for sample queries 7 and 9).

## How to judge the answer

- The triage label rests on Query Store figures for both windows, not on one sample.
- It checks the capture mode before saying a query isn't there.
- Plan facts come from a stored plan, and the answer says whether it's estimated or carries actual rows.
- When a skill declines on T1 or T2, it says so and stays with telemetry.

## Safety

- Reject plan forcing (`sp_query_store_force_plan`), Query Store setting changes, `SET STATISTICS XML`, and any re-run of the workload query. The skills' guides show some of these; this beat stays read-only.
- Approve only `SELECT` statements against `ContosoCare` and read calls to the telemetry endpoint.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries 4, 7, and 9 for both windows.
2. Through Bastion, show the Query Store reports for `ContosoCare` in SSMS: top resource-consuming and regressed queries. SSMS on the image is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
