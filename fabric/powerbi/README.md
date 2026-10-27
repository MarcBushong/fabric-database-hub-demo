# Power BI history report (Phase 19)

This folder holds the demo's history surface: a Direct Lake semantic model over the lakehouse and a four-page Power BI report. The report shows what the notebooks saved, not live data. For live data, use Database Hub and the [Real-Time Dashboard](../realtime/README.md); [presentation surfaces](../../docs/presentation.md) says when to use which.

| Item | What it is |
|---|---|
| `SM_DatabaseHub_History` | Semantic model, Direct Lake on OneLake, over the five Delta tables that the notebooks write to `LH_DatabaseHub`: `validation_results`, `scenario_runs`, `telemetry_snapshots`, `analysis_findings`, and `incident_windows`. It has five calculated dimensions (Target, Status, Analysis, Signal, Date), 16 relationships, and 103 measures. |
| `RPT_DatabaseHub_History` | Report with four pages: **Estate at a glance**, **The incident, minute by minute** (also the drillthrough target on a target), **Signal explorer**, and **Readiness checks**, in the dark "DbHub Cockpit Dark" theme. Every page says it's history and gives its times in UTC. |

The approved design is [`_brief/report-spec.md`](_brief/report-spec.md); its `Design Brief:` block is the contract that the report is generated from.

The demo's Fabric app is a separate item: a Fabric Apps (preview) item built with the Rayfin SDK and CLI, over `SM_DatabaseHub_History` through the semantic model connector (Phase 19b). This folder and `configure-powerbi.ps1` create no app. The model's table, column, and measure names are the app's contract, so they stay stable.

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

- The notebooks are imported, and `NB_DatabaseHub_LiveActivity` has run once with `SAVE_RESULTS` true, so all five tables exist with their `report_date_utc` column ([Fabric assets](../README.md)).
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
| 1. Semantic model | `Get-DemoFabricSemanticModelDefinition` (TMDL, lakehouse filled in), then `Import-DemoFabricItem`: List Items, then Create Item or Update Item Definition | `FABRIC.IMPORT.SM_DATABASEHUB_HISTORY` |
| 2. Refresh | `Invoke-DemoSemanticModelRefresh`: one enhanced refresh (Direct Lake framing), polled until it finishes. Tables that a notebook has just created in a new lakehouse take a while to reach Direct Lake (about 20 minutes on 2026-10-27), so a refresh that can't see some of them (0xC14700DF) is sent again every 2 minutes for up to 30 minutes (`-RefreshRetryMinutes`) | `FABRIC.SEMANTICMODEL.REFRESH` |
| 3. Data | `Test-DemoSemanticModelData`: row counts of the five tables, then every measure with `EVALUATE ROW(...)`, and `INFO.MEASURES()` | `FABRIC.SEMANTICMODEL.ROWS`, `.MEASURE.<TABLE>.<MEASURE>`, `.INFOMEASURES`, `.DATA` |
| 4. Report | `Get-DemoFabricReportDefinition` (the minimal `byConnection` form), `Import-DemoFabricItem`, then `Test-DemoPowerBIReport` | `FABRIC.IMPORT.RPT_DATABASEHUB_HISTORY`, `FABRIC.REPORT.BINDING`, `FABRIC.REPORT.PAGES` |

How to read the data check:

- A measure that returns a value is a **Pass**.
- A measure that raises a DAX error is a **Fail**.
- A measure that returns blank over the whole history is evaluated again per telemetry bin, incident, and signal, the context its visual sets (the incident band, the threshold lines). It's a **Pass** when it returns a value there.
- A measure that stays blank is a **Warning**. That's expected until a bounded scenario runs and the live-activity notebook records it, because the scenario and incident measures have nothing to show yet. Phase 20's end-to-end run checks them again.
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
