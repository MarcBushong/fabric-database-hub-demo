# Power BI history report (Phase 19)

This folder holds the demo's history surface: a Direct Lake semantic model over the lakehouse and a four-page Power BI report. The report shows what the notebooks saved, not live data. For live data, use Database Hub and the [Real-Time Dashboard](../realtime/README.md); [presentation surfaces](../../docs/presentation.md) says when to use which.

| Item | What it is |
|---|---|
| `SM_DatabaseHub_History` | Semantic model, Direct Lake on OneLake, over the thirteen Delta tables that the notebooks write to `LH_DatabaseHub`: `validation_results`, `scenario_runs`, `telemetry_snapshots`, `analysis_findings`, and `incident_windows`, and the Incident RCA's eight (`rca_*`, [below](#the-incident-rcas-tables-2026-11-20)). It has five calculated dimensions (Target, Status, Analysis, Signal, Date), 32 relationships, and 121 measures. |
| `RPT_DatabaseHub_History` | Report with four pages: **Estate at a glance**, **The incident, minute by minute** (also the drillthrough target on a target), **Signal explorer**, and **Readiness checks**, in the dark "DbHub Cockpit Dark" theme. Every page says it's history and gives its times in UTC. |

The approved design is [`_brief/report-spec.md`](_brief/report-spec.md); its `Design Brief:` block is the contract that the report is generated from.

The demo's Fabric app is a separate item: a Fabric Apps (preview) item built with the Rayfin SDK and CLI, over `SM_DatabaseHub_History` through the semantic model connector (Phase 19b). This folder and `configure-powerbi.ps1` create no app. The model's table, column, and measure names are the app's contract, so they stay stable.

T4, the PostgreSQL flexible server, and its read replica (ADR 0025) have rows too, when the scripts passed their Azure Monitor metrics to the live-activity notebook: `telemetry_snapshots` and `analysis_findings` with the analysis `postgresql` and the targets `T4` and `T4-replica`, which the Target dimension names as **PostgreSQL target** rows and the Analysis dimension as **PostgreSQL (Azure Monitor)**. The report's measures and pages stay on the three SQL targets; T4's findings appear in its findings tables, and the Insights app's **PostgreSQL** page charts its metrics.

T5, the Azure Cosmos DB account (ADR 0027), has rows the same way, when the control's Run all, `stop-demo.ps1 -SaveHistory`, `deploy.ps1`'s history snapshot, or `configure-fabric.ps1 -RunLiveActivity` passed its Azure Monitor metrics (`COSMOS_METRICS`): analysis `cosmosdb` (**Azure Cosmos DB (Azure Monitor)**, group **Cosmos DB**) and target `T5` (**T5 · Azure Cosmos DB**, a **Cosmos DB target** row).

- `telemetry_snapshots`: one row per interval, `resource_type` `databaseAccounts`, `resource_name` `cosmos01-<deploymentId>`, and `metric` with its `unit`: `NormalizedRUConsumption` (`percent`, maximum per interval), `TotalRequestUnits` (`RU`, total), `TotalRequests` (`requests`, count), `ThrottledRequests` (`requests`: TotalRequests with status code 429, count; 0 in an interval with requests and no 429s), `ServerSideLatencyGateway` (`ms`, average), and hourly `ProvisionedThroughput` (`RU/s`, maximum) and `ServiceAvailability` (`percent`, average).
- `analysis_findings`: `cosmosdb.T5.capture`, `cosmosdb.T5.throttling`, one `cosmosdb.T5.throttle.<yyyymmddThhmm>` per throttling episode, and `cosmosdb.T5.recovery` (whether T5 was back at its baseline, with no 429s, before the capture's end).
- Measures, folder **Cosmos DB** of Telemetry Snapshots: **Peak Norm RU (%)**, **Cosmos DB Requests**, **Throttled Requests (429s)**, **429 Rate (%)**, **RU Consumed**, **Provisioned RU/s**, **Cosmos DB Availability (%)**, **Cosmos DB Gateway Latency (ms)**, and **Cosmos DB Headline**, with the hidden **Has Cosmos DB Bins** for an empty state; and **Throttling Episodes** in Analysis Findings. Like the SQL sums, the sums count the latest capture of each bin, so two captures of one period at different intervals both count. The report's pages don't show T5.

## The Incident RCA's tables (2026-11-20)

The Incident RCA's eight tables ([ADR 0031](../../docs/adr/0031-incident-rca.md)) are in the model as **RCA Sessions**, **RCA Waits**, **RCA Events**, **RCA Queries**, **RCA Resource**, **RCA Replica**, **RCA Coverage**, and **RCA Answer Key**, with the columns, descriptions, and relationships (each to Target and Date) that [rca/history-tables.json](../../rca/history-tables.json) gives them, and seven measures: **Blocked Sessions (captured)** and **Head Blocker Idle (s)** in RCA Sessions; **Deadlocks (captured)**, **Errors (captured)**, and **Lock Escalations (captured)** in RCA Events; **Replica Replay Stall (s)** in RCA Replica; and **Injected Faults** in RCA Answer Key. The Insights app's detection, investigation tools, and chat read the first seven tables only; the answer key is for the tests and the scoreboard ([blind detection](../../rca/README.md#blind-detection)), so the app's model guide leaves it out. The report's pages don't show them.

Direct Lake can't read a table the lakehouse doesn't have, so `configure-powerbi.ps1` lists the lakehouse's tables first (OneLake's Path - List, with your workspace role: [OneLake access with APIs](https://learn.microsoft.com/fabric/onelake/onelake-access-api)) and leaves out of the model any RCA table that isn't there yet, with their measures and relationships (`FABRIC.SEMANTICMODEL.RCA`, a **Warning** that names them, or one when the list fails: then it leaves all eight out). The rest of the model deploys as before, and the data check skips what was left out. An environment from the release before the Incident RCA gets them in two steps: `deploy.ps1` updates `NB_DatabaseHub_LiveActivity` and runs it once, which creates them, and its model step, or the next one, reads them.

## History and live

| Question | History (this report) | Live (Database Hub, Real-Time Dashboard) |
|---|---|---|
| Source | Lakehouse snapshots that `NB_DatabaseHub_Deployment` and `NB_DatabaseHub_LiveActivity` saved | The telemetry endpoint, queried with each viewer's identity |
| Freshness | As of the last notebook run (the **History** tile shows the age) | A few minutes behind the activity |
| Reach | Every run the notebooks saved, past the telemetry's 7-day retention | 7 days or less |
| Incidents | `incident_windows`: requested scenario windows plus detected signal episodes, each labeled by source | Whatever is happening now |

## Layout

```text
fabric/powerbi/
  _brief/report-spec.md                     the approved spec and its Design Brief
  DbHubHistory.pbip                         project entry point (Power BI Desktop)
  SM_DatabaseHub_History.SemanticModel/     definition.pbism and definition/ (TMDL)
  RPT_DatabaseHub_History.Report/           definition.pbir (byPath), definition/ (PBIR), StaticResources/
  generator/                                Node.js generator for the report, and its tests
```

No real ID is in Git. The model's Direct Lake source is an all-zero OneLake URL that the deploy script fills in with the workspace and lakehouse it resolves by name ([ADR 0021](../../docs/adr/0021-fabric-resources-by-name.md)), and the report binds to the model by path until it's deployed.

## Deploy

Prerequisites:

- The notebooks are imported, and `NB_DatabaseHub_LiveActivity` has run once with `SAVE_RESULTS` true, so all its tables exist with their `report_date_utc` column ([Fabric assets](../README.md)); a missing RCA table is left out of the model ([above](#the-incident-rcas-tables-2026-11-20)).
- Contributor or higher on the workspace, which is on a running F capacity (P5). The scripts never pause, resume, or scale it. A paused capacity is reported as **Manual action required**.
- For the DAX check, the tenant setting **Dataset Execute Queries REST API** is on (Admin portal, **Tenant settings**, **Integration settings**).

```powershell
./scripts/configure-powerbi.ps1 -WhatIf    # builds and validates both definitions; plans every request; sends nothing
./scripts/configure-powerbi.ps1            # deploys the model and the report, refreshes, and checks the data
./scripts/configure-powerbi.ps1 -CheckModelData    # only the data check, against the deployed model
```

The script runs unattended: no prompts, and re-runs converge. It finds each item by name and updates it in place, and it deletes nothing. Before any request, the subscription guard (`Assert-DemoAzContext`) must pass. The Fabric and Power BI tokens then come from the Azure CLI with `--subscription`. Results go to the console and to `out/configure-powerbi.jsonl`, with the [ADR 0012](../../docs/adr/0012-validation-model.md) statuses. The exit code is 1 on a **Fail**, or 2 with `-TreatManualAsError` on a **Manual action required**. `deploy.ps1` can call it as a Fabric deploy step, next to `configure-fabric.ps1 -CheckDashboardData`.

| Step | What runs | Records |
|---|---|---|
| 1. Semantic model | `Get-DemoRcaModelTablePlan` (the RCA tables the lakehouse has, `FABRIC.SEMANTICMODEL.RCA`), then `Get-DemoFabricSemanticModelDefinition` (TMDL, lakehouse filled in, a missing RCA table left out), then `Import-DemoFabricItem`: List Items, then Create Item or Update Item Definition | `FABRIC.IMPORT.SM_DATABASEHUB_HISTORY` |
| 2. Refresh | `Invoke-DemoSemanticModelRefresh`: one enhanced refresh (Direct Lake framing), polled until it finishes. Tables that a notebook has just created in a new lakehouse take a while to reach Direct Lake (about 20 minutes on 2026-10-27), so a refresh that can't see some of them (0xC14700DF) is sent again every 2 minutes for up to 30 minutes (`-RefreshRetryMinutes`) | `FABRIC.SEMANTICMODEL.REFRESH` |
| 3. Data | `Test-DemoSemanticModelData`: row counts of the five tables and of the RCA tables the model has (one probe finds which), then every measure with `EVALUATE ROW(...)`, and `INFO.MEASURES()` | `FABRIC.SEMANTICMODEL.ROWS`, `.MEASURE.<TABLE>.<MEASURE>`, `.INFOMEASURES`, `.DATA` |
| 4. Report | `Get-DemoFabricReportDefinition` (the minimal `byConnection` form), `Import-DemoFabricItem`, then `Test-DemoPowerBIReport` | `FABRIC.IMPORT.RPT_DATABASEHUB_HISTORY`, `FABRIC.REPORT.BINDING`, `FABRIC.REPORT.PAGES` |

How to read the data check:

- A measure that returns a value is a **Pass**.
- A measure that raises a DAX error is a **Fail**.
- A measure that returns blank over the whole history is evaluated again per telemetry bin, incident, and signal, the context its visual sets (the incident band, the threshold lines). It's a **Pass** when it returns a value there.
- A measure that stays blank is a **Warning**. That's expected until a bounded scenario runs and the live-activity notebook records it, because the scenario and incident measures have nothing to show yet. Phase 20's end-to-end run checks them again.
- Right after a first deployment, while the history tables are still empty (`FABRIC.SEMANTICMODEL.ROWS` is a **Warning**), `deploy.ps1` reports those blank measures as one **Warning**, `FABRIC.SEMANTICMODEL.MEASURES`: the history report is empty until `NB_DatabaseHub_LiveActivity` saves its first snapshots (Phase 28 live finding, 2026-10-30). `configure-powerbi.ps1 -CheckModelData` still reports every measure. Since 2026-11-06, `deploy.ps1` takes those snapshots itself at its end, after this check, and refreshes the model (`DEPLOY.FABRIC.HISTORY`, [deployment](../../docs/deployment.md#the-history-reports-snapshot-at-the-end-2026-11-06)): the report then shows the run's data, but the incident measures, such as **Blocking Incidents**, stay blank until incidents have run and the notebook runs again (`./scripts/stop-demo.ps1 -SaveHistory`, or `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity`).
- Execute Queries doesn't run INFO functions, so `INFO.MEASURES()` is **Not supported** there, and the per-measure queries are the check.

The report is generated, not hand-edited: change the spec or the model, then run the [generator](generator/README.md). For a Power BI Desktop preview against the deployed model, the generator writes a copy outside Git with the full `byConnection` form.

## Sharing the report

The script deploys the report into the workspace and creates no app. Workspace members open `RPT_DatabaseHub_History` there. The demo's Fabric app (Fabric Apps preview, built with the Rayfin SDK and CLI) is a separate item; its own guide covers how viewers reach it.

To let someone outside the workspace open the report, two steps stay manual, because both grant permissions:

1. Open `RPT_DatabaseHub_History`, select **Share**, and add the viewers; leave reshare off. That gives them Read on the report and its semantic model ([Share and collaborate on Power BI reports and dashboards](https://learn.microsoft.com/power-bi/collaborate-share/service-share-dashboards)).
2. Give them data access for Direct Lake, in one of two ways (the spec's open decision 2):
   - Open `LH_DatabaseHub`, select **Share**, add the viewers with **Read all with Apache Spark**, and select **Grant**.
   - Or bind the semantic model's Direct Lake source to an OAuth 2.0 cloud connection with single sign-on off, in the semantic model's **Settings**, **Gateway and cloud connections**.

An org app shell, `APP_DatabaseHub_Demo`, is in the demo workspace from the first live run (2026-10-22), before the org app was dropped from this phase. Nothing deploys, reads, or updates it. If you don't want it, delete it in the portal; the scripts never delete it.

## Licensing and access

On F SKUs smaller than F64, each user viewing Power BI content needs Pro, PPU, or an individual trial ([Microsoft Fabric license types](https://learn.microsoft.com/fabric/enterprise/licenses)). The demo's capacity is an F16, so every viewer of the report needs one. A presenter who shares their screen needs only their own access.

| Viewer | License | Access to the report | Data access for Direct Lake |
|---|---|---|---|
| Presenter (workspace member) | Their own | A workspace role | Their own (single sign-on) |
| Customer watching a shared screen | None | None | None |
| Colleague outside the workspace | Pro, PPU, or a trial | Shared report (Read on the report and the model) | A lakehouse share with **Read all with Apache Spark**, or a fixed-identity connection ([Direct Lake security](https://learn.microsoft.com/fabric/fundamentals/direct-lake-security-integration)) |

The report needs no Azure access: it reads only the lakehouse. The Real-Time Dashboard's live tiles need Reader on the demo subscription.

## Known limits

- Detected incident windows are heuristics: an incident without its signal isn't listed, and a busy baseline can produce a window. The source column labels each one.
- On the incident page, the evidence table has no "Top 4" filter. A Top N subquery doesn't see the table's measure filter, so it would rank findings outside the window. The table's height shows about four rows instead.
- The readiness heat strip lists runs oldest first: a matrix sorts its columns by the column field.
- The tables have no empty-state text of their own. The page titles carry each page's empty state.
- From the Desktop render check (2026-10-22), all cosmetic: the estate tiles' context lines are clipped after their first line; the tables' long text columns (findings, messages, remediation) scroll sideways; and the incident band is drawn as columns centered on each bin's start, so it sits half a bin early, and a two-bin window shows two separate columns.

## Sources

- [SemanticModel definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/semantic-model-definition) and [Report definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/report-definition)
- [Items - Create Item](https://learn.microsoft.com/rest/api/fabric/core/items/create-item) and [Update Item Definition](https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition)
- [Refresh Dataset In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group), [Execute Queries In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group), and [Get Report In Group](https://learn.microsoft.com/rest/api/power-bi/reports/get-report-in-group)
- [Direct Lake overview](https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview) and [How Direct Lake works](https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works)
- [Share and collaborate on Power BI reports and dashboards](https://learn.microsoft.com/power-bi/collaborate-share/service-share-dashboards) and [Microsoft Fabric license types](https://learn.microsoft.com/fabric/enterprise/licenses)
