# Fabric assets

Everything that lives in the Fabric workspace that holds the notebooks (prerequisite P5). The decisions are in [ADR 0014](../docs/adr/0014-notebook-role-and-capacity.md) and [ADR 0013](../docs/adr/0013-agent-experience.md).

| Folder | Contents | Phase |
|---|---|---|
| `notebooks/` | `NB_DatabaseHub_Deployment.ipynb`: deployment companion, validator, and presenter script, evolved from the supplied notebook. `NB_DatabaseHub_LiveActivity.ipynb`: simulates live activity and analyzes locks, blocking, and consumption. | 12 |
| `realtime/` | The Real-Time Dashboard as code: `RTD_DatabaseHub_LiveView`, the presenter's live view over the telemetry endpoint, generated from a layout spec and the notebook's own KQL ([its guide](realtime/README.md)) | 18 |
| `agent/` | Prompt pack for the in-Hub Database Agent and the documented skills fallback | 10 |
| `connections/` | Notes on Fabric connections (none needed) | 12 |
| `powerbi/` | The Power BI history report `RPT_DatabaseHub_History`, its Direct Lake semantic model `SM_DatabaseHub_History`, and the report's generator; see [`powerbi/README.md`](powerbi/README.md). The demo's Fabric app (Fabric Apps preview, Rayfin) is a separate item | 19 |
| `app/` | The demo's Fabric app, the Insights app `APP_DatabaseHub_Insights`: a read-only Fabric App (preview) over `SM_DatabaseHub_History`, with its own visuals, insight cards, and DAX and CSV export, deployed by `scripts/configure-fabric-app.ps1`; see [`app/README.md`](app/README.md) | 19b |
| `control/` | `NB_DatabaseHub_Control.ipynb`: the optional on-demand activity control's notebook, which starts a bounded run through an Azure Automation webhook and shows it live. `scripts/setup-activity-control.ps1` imports it into a folder of this workspace, or into its own "DBHub Control" workspace where the tenant makes vaults private; see [`control/README.md`](control/README.md) and [ADR 0020](../docs/adr/0020-on-demand-activity-control.md) | 25c |

## The notebooks

Both notebooks keep the supplied notebook's PySpark kernel (`synapse_pyspark`), its default lakehouse's name (`LH_DatabaseHub`), and its session and compute settings. They hold no Fabric IDs ([ADR 0021](../docs/adr/0021-fabric-resources-by-name.md)): `WORKSPACE_ID` and `LAKEHOUSE_ID` are empty in the parameters cell, the import binds the uploaded copy to the workspace and lakehouse that the scripts resolve by name, and every scripted run passes their IDs. An empty ID means the session's own workspace or default lakehouse, so a notebook you import by hand works once you attach `LH_DatabaseHub`. The supplied notebook held only Fabric's `1+1` template cell; its content was replaced, nothing else of it was kept or invented.

| | `NB_DatabaseHub_Deployment` | `NB_DatabaseHub_LiveActivity` |
|---|---|---|
| **Role** | Deployment companion, validator, presenter script, troubleshooting and cleanup guide, architecture explainer | A session's analysis of locks, blocking, and consumption, and its history; Hub and Database Agent prompts. `NB_DatabaseHub_Control` runs it as a job at each session's end ([ADR 0026](../docs/adr/0026-one-run-all-session.md)) |
| **Sections** | Parameters, overview and value, architecture, security, prerequisites check, cost reminders, deployment status, the three targets, Hub telemetry validation, per-target validation, agents, mirroring (deferred), scenarios, Hub and agent prompts, remediation, reset, start and stop, validation summary, troubleshooting, cleanup, limitations, references, next steps | Parameters, helpers, this session, telemetry access, estate pulse, locks and blocking, overall consumption and T4's PostgreSQL metrics, correlation of scenario windows with telemetry, "See it in the Hub", optional Real-Time Dashboard, persist |
| **Reads** | Fabric REST (`pbi` token): workspace, capacity, lakehouse, items. Telemetry endpoint (`kusto` token). | Telemetry endpoint (`kusto` token), Fabric REST (Real-Time Dashboard check), `scenario_runs`, and T4's Azure Monitor metrics in the `POSTGRES_METRICS` parameter, which the scripts pass ([below](#t4s-postgresql-metrics-in-the-history-2026-11-13)) |
| **Writes** | Delta tables `validation_results`, `telemetry_snapshots` | Delta tables `scenario_runs`, `telemetry_snapshots`, `analysis_findings`, `incident_windows`, and any of the five report tables that are missing (lakehouse data only); a session's row and its beats in `scenario_runs`, last |
| **Resource-changing cells** | Cleanup: drops the five Delta tables; needs `PURGE_DEMO_TABLES = True` (`False` by default) and `CONFIRM = True` | None since 2026-11-14: it changes no activity and uses no GitHub |

**Run all runs both** (since 2026-11-03, the owner's decision: no dry-run defaults).

- **`NB_DatabaseHub_Deployment`** runs every check and changes no Azure or Fabric resource; its cleanup also needs `PURGE_DEMO_TABLES = True`, which stays `False`, so **Run all** never drops a table.
- **`NB_DatabaseHub_LiveActivity`** analyzes and saves, and changes no activity since 2026-11-14 ([ADR 0026](../docs/adr/0026-one-run-all-session.md)): a demo session runs from `NB_DatabaseHub_Control`, whose Run all runs this notebook as a job at the session's end with the session's ID (`SESSION_ID`), its beats (`SESSION_PLAN`), its window, and T4's metrics. A session already in `scenario_runs` isn't saved twice. It has no `CONFIRM`, no stop cell, and no GitHub path (P9 is retired).
- **The scripts' own runs** of the live-activity notebook (`stop-demo.ps1 -SaveHistory`, `configure-fabric.ps1`'s first capture, and, since 2026-11-06, `deploy.ps1`'s snapshot at its end) pass the demo's resource group as `RESOURCE_GROUP`, which scopes the notebook's queries (`configure-fabric.ps1` too since 2026-11-06; before, its runs kept the default, `rg-dbhub-demo`), and still `CONFIRM` and `STOP_ACTIVITY` as `false` for a notebook imported before 2026-11-14, whose Run all sent an activity request. Since 2026-11-13, `stop-demo.ps1 -SaveHistory` and `deploy.ps1`'s snapshot also pass T4's Azure Monitor metrics as `POSTGRES_METRICS` ([below](#t4s-postgresql-metrics-in-the-history-2026-11-13)).

### What runs where

| Action | Where it runs | How |
|---|---|---|
| Deploy, start, stop, reset, destroy, validate Azure resources | PowerShell 7 (`scripts/*.ps1`) or GitHub Actions | Azure Resource Manager and managed Run Command. Notebooks can't: `notebookutils` has no Azure Resource Manager token audience. |
| Run a demo session from Fabric | `NB_DatabaseHub_Control`, in the control workspace or folder | One Run all: the control's Azure Automation webhook and runbook start, follow, and stop the session, and the live-activity notebook's job saves its history ([ADR 0026](../docs/adr/0026-one-run-all-session.md)); no GitHub Actions |
| Validate the Fabric workspace, capacity, lakehouse, and notebooks | Deployment notebook | Fabric REST API with the `pbi` token |
| Validate and analyze Hub telemetry | Both notebooks | Telemetry REST endpoint with the `kusto` token, or the printed KQL in the Azure Data Explorer web UI |
| Check that targets appear in Estate; use the Database Agent | Database Hub, by the presenter | UI only, by design: Hub has no public API |
| Import or update the notebooks | `scripts/configure-fabric.ps1` on your machine | Fabric REST API with your token |

### Tokens and the telemetry fallback

- Tokens come from `notebookutils.credentials.getToken`, which supports only the audience keys `storage`, `pbi`, `keyvault`, and `kusto` ([NotebookUtils credentials](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials)). The notebooks request only `pbi` (Fabric REST) and `kusto` (telemetry), use each token in one HTTP header, and never print or save it.
- The telemetry endpoint documents a Microsoft Entra token for `https://kusto.kusto.windows.net` ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). **Whether it accepts a notebook `kusto` token isn't documented.** The notebooks check it once per run (`HUB.TELEMETRY.TOKEN`); if it isn't accepted, every query prints its KQL with the documented Azure Data Explorer web UI steps instead, and `scripts/validate.ps1` runs the same checks with an Azure CLI token.
  - In this tenant it was accepted (**Pass**, 2026-10-21). Because the behavior is undocumented, the check and the fallback stay.
- The KQL follows the article's rules: filter on `SampleTimeUTC` first, take per-series deltas of cumulative counters and skip resets, branch on `CounterType`, and group by `ResourceID` and `SqlServerInstanceName`.

### Delta tables in `LH_DatabaseHub`

| Table | Written by | Key columns |
|---|---|---|
| `validation_results` | Deployment notebook | `run_id`, `check_id`, `area`, `target`, `status` (the six ADR 0012 statuses), `message`, `evidence` (JSON), `remediation`, `doc_url`, `timestamp_utc` |
| `scenario_runs` | Live-activity notebook | `request_id`, `profile`, `target`, `duration_minutes`, `dispatch_mode` (`workflow_dispatch` or `manual`), `status`, `github_run_url`, `window_start_utc`, `window_end_utc` |
| `telemetry_snapshots` | Both | `run_id`, `analysis`, `target`, `resource_name`, `metric`, `bucket_utc`, `value`, `unit`, analysis window; T4's rows have the analysis `postgresql` and the target `T4` or `T4-replica` ([below](#t4s-postgresql-metrics-in-the-history-2026-11-13)) |
| `analysis_findings` | Live-activity notebook | `finding_id`, `analysis`, `target`, `status`, `finding`, `evidence` (JSON), `request_id`, window; T4's are `postgresql.T4.capture`, `postgresql.T4-replica.lag`, `postgresql.T4.cpu`, and `postgresql.T4.connections_failed` |
| `incident_windows` | Live-activity notebook (Phase 19) | `incident_key`, `incident_label`, `source` (`Recorded request` or `Detected signal`), `target`, `scenario`, `signal_family`, window, `duration_minutes`, `peak_value`, `correlation_status`, `correlation_evidence` (JSON); 18 columns |

Every table also has `report_date_utc` (`date`): the UTC calendar date of the row's primary time, the first that isn't null of `timestamp_utc` (validation results), `window_start_utc` then `requested_at_utc` (scenario runs), `bucket_utc` then `window_end_utc` then `captured_at_utc` (snapshots), `window_start_utc` then `captured_at_utc` (findings), and `window_start_utc` (incident windows). The Power BI history report relates every table to its date table through it. Each write is one Parquet file, which keeps every table far below Direct Lake's limit of 1,000 files per table on F16.

The live-activity notebook's persist cell (section 11) also readies the tables for the report, lakehouse data only: `CREATE TABLE IF NOT EXISTS` for all five (Direct Lake can't frame a missing table), `report_date_utc` added and backfilled once on tables written before it existed, the incident windows merged on `incident_key`, and `OPTIMIZE` for any table with more than 200 files. An incident window is either a **recorded request** (each `incident:*` request in `scenario_runs` that wasn't a Fail, with section 8's expected-signal verdict) or a **detected signal** (consecutive bins with a blocked process, CPU at or above `EPISODE_CPU_PERCENT` (80) for `EPISODE_MIN_BINS` (2) bins, `PAGEIOLATCH` waits at or above `EPISODE_PAGEIOLATCH_SECONDS` (1 s) per bin for 2 bins, or any Log Rate Governor wait) that no request explains. A re-run unions overlapping detected episodes and keeps the earliest key, so nothing is duplicated. The thresholds are presenter heuristics, not product behavior (ADR 0014).

Re-running a cell in the same session replaces that run's rows, so nothing is duplicated. The tables keep demo history beyond the telemetry's 7-day retention. `LH_DatabaseHub` has lakehouse schemas, so the tables are in the `dbo` schema (`Tables/dbo/<table>` in OneLake).

### T4's PostgreSQL metrics in the history (2026-11-13)

The live-activity notebook can't read T4, the PostgreSQL flexible server, or its read replica: `notebookutils` has no Azure Resource Manager token audience, and Database Hub's PostgreSQL dashboard charts their Azure Monitor metrics, which aren't in the telemetry endpoint ([ADR 0025](../docs/adr/0025-t4-read-replica.md)). So the scripts read them on your machine and pass them in:

1. **Capture:** `Get-DemoPostgresHistoryParameter` (`scripts/modules/DbHubDemo/Private/PostgresHistoryHelpers.ps1`) reads the metrics with the Azure CLI ([Metrics - List](https://learn.microsoft.com/rest/api/monitor/metrics/list)) over the run's window, every 5 minutes, read-only:
   - On T4 (`pgflex01-<deploymentId>`): `cpu_percent`, `memory_percent`, `active_connections`, and `physical_replication_delay_in_bytes` (Max Physical Replication Lag), each its maximum in the interval, and `connections_failed`, the interval's total.
   - On the read replica (`pgreplica01-<deploymentId>`): `physical_replication_delay_in_seconds` (Read Replica Lag, Database Hub's **Read replica lag** chart), `cpu_percent`, and `active_connections`, each its maximum.
   - A server that doesn't exist, such as the replica between sessions, or that had no data is left out, with a note. Only points with a value are kept, and the document stays under about 24 KB: when it's larger, the intervals are combined into 15, 30, 60, or more minutes (the maximum of the maximums, the sum of the totals).
2. **Pass:** `./scripts/stop-demo.ps1 -SaveHistory` captures them before it deletes the replica, whose metrics go with it, and `./scripts/deploy.ps1`'s history snapshot at its end. Each sends them with the notebook's analyze-only run as the string parameter `POSTGRES_METRICS`: compact JSON, version 1, with the window (`capturedUtc`, `startUtc`, `endUtc`, `windowMinutes`, `intervalMinutes`), the servers (`role` `primary` or `replica`, `target`, `resourceName`, `sku`), and the series (`resourceName`, `role`, `metric`, `aggregation`, `unit`, and `points`, pairs of an interval's UTC start and its value). It holds names, sizes, times, and numbers, never an ID or a credential. Empty means none were passed.
3. **Save:** section 7's T4 cell checks the document, keeps only valid servers, series, and points, and adds them to the run's results, which the persist cell saves with the rest (a re-run replaces them):
   - `telemetry_snapshots`: one row per point, with `analysis` `postgresql`, `target` `T4` or `T4-replica`, `resource_type` `flexibleServers`, `resource_name` the server, `metric` the Azure Monitor metric, `bucket_utc` the interval's start, `value`, `unit` (`percent`, `connections`, `seconds`, or `bytes`), and the window the metrics cover. `report_date_utc` is the point's date.
   - `analysis_findings`, with `analysis` `postgresql`: `postgresql.T4.capture` (what was captured), `postgresql.T4-replica.lag` (the replica's peak lag: **Warning** at `REPLICA_LAG_WARNING_SECONDS`, 60, or more; **Not selected** when the capture has no replica), `postgresql.T4.cpu` (T4's peak CPU: **Warning** at `EPISODE_CPU_PERCENT`, 80, or more), and `postgresql.T4.connections_failed` (the total: **Warning** above 0). Each covers its series' time. A document the cell can't use is one **Fail** finding, `postgresql.T4.capture`, and adds no rows. The thresholds are presenter heuristics, not product behavior.
   - With `POSTGRES_METRICS` empty, as in a run by hand, the cell says so in one line and adds nothing.
4. **Show:** the Insights app's **PostgreSQL** page charts the latest capture: the replica's lag over time with its peak, T4's CPU and connections, its failed connections, and the findings ([the app](app/README.md)). The history model names `T4` and `T4-replica` in its Target dimension and `postgresql` in its Analysis dimension; the Power BI report's pages stay on the SQL targets ([the report](powerbi/README.md)).

## Prerequisites

| # | Prerequisite | Needed for |
|---|---|---|
| P4 | The Database Hub tenant setting **Users can access the Database hub (preview)** and a Fabric Free license per Hub user. No documented API reads the setting without Fabric administrator rights, so the deployment notebook reports it as **Manual action required**. | Database Hub and the Database Agent |
| P5 | Contributor or higher on the workspace, which is on F or Trial capacity. Database Hub is free; notebooks need capacity. A paid F capacity must be running: while it's paused, Fabric answers imports and runs with HTTP 404 `CapacityNotActive`, and the import reports **Manual action required** with the [resume steps](https://learn.microsoft.com/fabric/enterprise/pause-resume). Resuming also resumes billing, so pause it again after the demo. | Running and importing the notebooks |
| P9 *(retired 2026-11-14)* | Nothing: the live-activity notebook no longer triggers GitHub Actions ([ADR 0026](../docs/adr/0026-one-run-all-session.md)). A GitHub token stored for it earlier can be deleted. | Nothing |

## Import or update the notebooks

`scripts/configure-fabric.ps1` creates both notebooks in the workspace, or updates their definitions when notebooks with the same names exist, through the documented Fabric REST API:

1. It validates each `.ipynb` locally (nbformat 4, no outputs or execution counts).
2. It finds the notebook by display name with [Items - List Items](https://learn.microsoft.com/rest/api/fabric/core/items/list-items), then calls [Items - Create Item](https://learn.microsoft.com/rest/api/fabric/core/items/create-item) (type `Notebook`) or [Items - Update Item Definition](https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition) with the [ipynb notebook definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/notebook-definition): format `ipynb`, one part `notebook-content.ipynb`, `InlineBase64`.
3. It follows the [long-running operation](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation) pattern: on HTTP 202 it waits `Retry-After`, polls Get Operation State, and reads a created item from Get Operation Result.

```powershell
./scripts/configure-fabric.ps1 -SkipHubChecks -WhatIf   # validates the files and shows the plan; no token, no network call
./scripts/configure-fabric.ps1             # signed-in Azure CLI user's Fabric token
./scripts/configure-fabric.ps1 -FabricToken $token -WorkspaceId <workspace-id>   # a token you already have, as a SecureString
```

- **Token:** without `-FabricToken`, the script runs the subscription guard and then `az account get-access-token --resource https://api.fabric.microsoft.com` through `Invoke-DemoAz` ([user-delegated Fabric calls from the command line](https://learn.microsoft.com/fabric/graph/gql-query-api)). The token stays a SecureString, is registered for redaction, and is sent only to `https://api.fabric.microsoft.com/v1`.
- **Idempotent:** re-runs update the same notebooks. If two notebooks share a name, it stops with **Fail** instead of guessing.
- **Workspace and lakehouse by name:** the script first finds `fabric.workspaceName` and `fabric.lakehouseName`, and creates them when they're missing and `fabric.createIfMissing` is true ([configuration](../docs/configuration.md#fabric)). Only the uploaded copy of each notebook is bound to them; the files in Git don't change.
- **Results:** one **Pass**, **Warning**, **Fail**, or **Not selected** record per notebook, in `out/configure-fabric.jsonl`.
- `deploy.ps1` imports a notebook that isn't in the workspace yet without asking, and updates one that is only when `fabric.importNotebooks` is `true` (`-NewNotebooksOnly`); running the script yourself is the explicit request to create or update both. When the live-activity notebook was just created, or bound to a lakehouse that was just created, it runs once, so the history tables exist. That run comes before the targets send telemetry, so `deploy.ps1` runs the notebook once more at its end, analyze-only, once its telemetry checks pass, and refreshes the history model, so the report has the run's data (2026-11-06; [deployment](../docs/deployment.md#the-history-reports-snapshot-at-the-end-2026-11-06)).
- In GitHub Actions it would run only where the Fabric tenant lets service principals use Fabric APIs and the identity has a workspace role; the local path is the default.

## The Real-Time Dashboard

`realtime/` holds the live view as code: a Fabric Real-Time Dashboard (item type `KQLDashboard`) with three pages, Estate pulse, Incident, and Resources, over the documented telemetry endpoint, queried with each viewer's own identity. Its KQL is the live-activity notebook's own (`scripts/modules/DbHubDemo/Kql/Live.*.kql`, kept identical by a test), so the notebook, the dashboard, and the tests can't drift. `configure-fabric.ps1 -ImportDashboard` imports it and reads it back; details, permissions, and limitations are in [its guide](realtime/README.md). How it fits next to Database Hub, the Power BI report, and the Fabric app is in [presentation surfaces](../docs/presentation.md).

The live-activity notebook's section 10 lists the workspace's Real-Time Dashboards and still describes the two manual ways to build one: Database Hub's template wizard, or by hand.

## Rules for notebooks

- Keep the PySpark kernel and the `LH_DatabaseHub` lakehouse name. Never commit a workspace or lakehouse ID: export the notebook, then remove them (a test fails on any GUID-shaped value in a notebook).
- Keep `"language_info": {"name": "python"}` in the notebook metadata. Fabric's [Run On Demand Item Job](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job) rejects a notebook without it ("Not supported language"), and Fabric's own `.ipynb` export includes it.
- Commit notebooks **without outputs**. CI fails if a cell has outputs or an execution count (`tests/unit/Repo.Conventions.Tests.ps1`, `tests/unit/Fabric.Notebooks.Tests.ps1`), and the pre-commit `nbstripout` hook strips them. The committed files already use the sequential cell IDs that `nbstripout` writes, so the hook leaves them unchanged.
- No credentials, ever. Tokens come from `notebookutils.credentials` at run time and are never printed.
- Cells that change resources start with `# RESOURCE-CHANGING CELL:`, follow a markdown cell that flags them, and do nothing unless `CONFIRM = True`, the default since 2026-11-03. A cell that drops data needs its own switch too (`PURGE_DEMO_TABLES`), which stays `False`. Since 2026-11-14 the live-activity notebook has none.
- Use only documented interfaces: never call Database Hub private routes, and describe expected **signals** for Database Agent prompts, never expected answers.
- To edit a notebook, change it in Fabric, export it as `.ipynb`, run `nbstripout` (or let the pre-commit hook do it), and commit; or edit the JSON directly and run the Pester tests.
- Three notebook tests run the live-activity notebook's own code, its episode detection on fixture rows and its T4 cell on what `Get-DemoPostgresHistoryParameter` writes, and need Python 3 with pandas: set `DBHUB_TEST_PYTHON` to such an interpreter (a virtual environment's `python`), or they're skipped. One of them replays Phase 25a's CPU samples (T1 and T2 at 99 and 97 in `SQLProcessCPUPercent`, 0 in `AvgCPUPercent`) and checks that T1 and T2 get their CPU windows.

## Status

Phase 12 evolved `NB_DatabaseHub_Deployment` and added `NB_DatabaseHub_LiveActivity` and the import script.

**Done live (2026-10-21):**

- Both notebooks were imported into the workspace.
- `NB_DatabaseHub_Deployment` ran read-only end to end through the Job Scheduler, with `CONFIRM` and `PURGE_DEMO_TABLES` false, and no saved row contains a secret.
- The `kusto` token was accepted by the telemetry endpoint.

**Still pending:**

- A run of the live-activity notebook.
- A look at the run snapshot's printed outputs in the Monitor hub.

See `docs/implementation-report.md`.

Phase 18 added the Real-Time Dashboard (`realtime/`) and made the import generic (`Import-DemoFabricItem`, which the notebook import now uses). On 2026-10-21 it was imported, read back, and every tile got data (`Test-DemoRealTimeDashboardData`).
