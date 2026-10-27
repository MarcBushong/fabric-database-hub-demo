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
| **Role** | Deployment companion, validator, presenter script, troubleshooting and cleanup guide, architecture explainer | Simulation control, live analysis of locks, blocking, and consumption, Hub and Database Agent prompts |
| **Sections** | Parameters, overview and value, architecture, security, prerequisites check, cost reminders, deployment status, the three targets, Hub telemetry validation, per-target validation, agents, mirroring (deferred), scenarios, Hub and agent prompts, remediation, reset, start and stop, validation summary, troubleshooting, cleanup, limitations, references, next steps | Parameters, helpers, simulation control, telemetry access, estate pulse, locks and blocking, overall consumption, correlation of scenario windows with telemetry, "See it in the Hub", optional Real-Time Dashboard, persist, stop and clean up |
| **Reads** | Fabric REST (`pbi` token): workspace, capacity, lakehouse, items. Telemetry endpoint (`kusto` token). | Telemetry endpoint (`kusto` token), Fabric REST (Real-Time Dashboard check), `scenario_runs` |
| **Writes** | Delta tables `validation_results`, `telemetry_snapshots` | Delta tables `scenario_runs`, `telemetry_snapshots`, `analysis_findings`, `incident_windows`, and any of the five report tables that are missing (lakehouse data only); with P9 and `CONFIRM = True`, a `workflow_dispatch` of `demo-control.yml` |
| **Resource-changing cells** | Cleanup: drops the five Delta tables; needs `PURGE_DEMO_TABLES = True` and `CONFIRM = True` | Send a simulation request (`CONFIRM = True`); stop all activity (`CONFIRM = True` and `STOP_ACTIVITY = True`) |

**Run all is safe** in both: with the defaults, no cell changes Azure or Fabric resources, and every resource-changing cell prints a dry run.

### What runs where

| Action | Where it runs | How |
|---|---|---|
| Deploy, start, stop, reset, destroy, validate Azure resources | PowerShell 7 (`scripts/*.ps1`) or GitHub Actions | Azure Resource Manager and managed Run Command. Notebooks can't: `notebookutils` has no Azure Resource Manager token audience. |
| Change the activity profile from Fabric | `demo-control.yml` in GitHub Actions | The live-activity notebook sends `workflow_dispatch` with the P9 token; without P9 it prints the Actions link and the `gh workflow run` command |
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
| `telemetry_snapshots` | Both | `run_id`, `analysis`, `target`, `resource_name`, `metric`, `bucket_utc`, `value`, `unit`, analysis window |
| `analysis_findings` | Live-activity notebook | `finding_id`, `analysis`, `target`, `status`, `finding`, `evidence` (JSON), `request_id`, window |
| `incident_windows` | Live-activity notebook (Phase 19) | `incident_key`, `incident_label`, `source` (`Recorded request` or `Detected signal`), `target`, `scenario`, `signal_family`, window, `duration_minutes`, `peak_value`, `correlation_status`, `correlation_evidence` (JSON); 18 columns |

Every table also has `report_date_utc` (`date`): the UTC calendar date of the row's primary time, the first that isn't null of `timestamp_utc` (validation results), `window_start_utc` then `requested_at_utc` (scenario runs), `bucket_utc` then `window_end_utc` then `captured_at_utc` (snapshots), `window_start_utc` then `captured_at_utc` (findings), and `window_start_utc` (incident windows). The Power BI history report relates every table to its date table through it. Each write is one Parquet file, which keeps every table far below Direct Lake's limit of 1,000 files per table on F16.

The live-activity notebook's persist cell (section 11) also readies the tables for the report, lakehouse data only: `CREATE TABLE IF NOT EXISTS` for all five (Direct Lake can't frame a missing table), `report_date_utc` added and backfilled once on tables written before it existed, the incident windows merged on `incident_key`, and `OPTIMIZE` for any table with more than 200 files. An incident window is either a **recorded request** (each `incident:*` request in `scenario_runs` that wasn't a Fail, with section 8's expected-signal verdict) or a **detected signal** (consecutive bins with a blocked process, CPU at or above `EPISODE_CPU_PERCENT` (80) for `EPISODE_MIN_BINS` (2) bins, `PAGEIOLATCH` waits at or above `EPISODE_PAGEIOLATCH_SECONDS` (1 s) per bin for 2 bins, or any Log Rate Governor wait) that no request explains. A re-run unions overlapping detected episodes and keeps the earliest key, so nothing is duplicated. The thresholds are presenter heuristics, not product behavior (ADR 0014).

Re-running a cell in the same session replaces that run's rows, so nothing is duplicated. The tables keep demo history beyond the telemetry's 7-day retention. `LH_DatabaseHub` has lakehouse schemas, so the tables are in the `dbo` schema (`Tables/dbo/<table>` in OneLake).

## Prerequisites

| # | Prerequisite | Needed for |
|---|---|---|
| P4 | The Database Hub tenant setting **Users can access the Database hub (preview)** and a Fabric Free license per Hub user. No documented API reads the setting without Fabric administrator rights, so the deployment notebook reports it as **Manual action required**. | Database Hub and the Database Agent |
| P5 | Contributor or higher on the workspace, which is on F or Trial capacity. Database Hub is free; notebooks need capacity. A paid F capacity must be running: while it's paused, Fabric answers imports and runs with HTTP 404 `CapacityNotActive`, and the import reports **Manual action required** with the [resume steps](https://learn.microsoft.com/fabric/enterprise/pause-resume). Resuming also resumes billing, so pause it again after the demo. | Running and importing the notebooks |
| P9 *(optional)* | A GitHub fine-grained personal access token with **Actions: Read and write** on this repository only, stored as a Key Vault secret that the notebook user can read (Get permission, or the Key Vault Secrets User role). Set `KEY_VAULT_URL` and `GITHUB_TOKEN_SECRET_NAME` (the secret's name, default `github-demo-control`) in the live-activity notebook's parameters cell. `demo-control.yml` itself needs the GitHub path (P7). | Triggering activity profiles from the notebook |

**P9 caveats.** `notebookutils.credentials.getSecret` reads the secret as the notebook user, from Fabric, so the vault must be reachable from Fabric: tenant policies that turn off a key vault's public network access, which some enterprise tenants enforce, block it, and the notebook then falls back to printing the link and command. Without P9, nothing is lost but the one-click trigger. Never paste a token into a notebook cell or parameter.

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
- `deploy.ps1` imports a notebook that isn't in the workspace yet without asking, and updates one that is only when `fabric.importNotebooks` is `true` (`-NewNotebooksOnly`); running the script yourself is the explicit request to create or update both. When the live-activity notebook was just created, or bound to a lakehouse that was just created, it runs once, so the history tables exist.
- In GitHub Actions it would run only where the Fabric tenant lets service principals use Fabric APIs and the identity has a workspace role; the local path is the default.

## The Real-Time Dashboard

`realtime/` holds the live view as code: a Fabric Real-Time Dashboard (item type `KQLDashboard`) with three pages, Estate pulse, Incident, and Resources, over the documented telemetry endpoint, queried with each viewer's own identity. Its KQL is the live-activity notebook's own (`scripts/modules/DbHubDemo/Kql/Live.*.kql`, kept identical by a test), so the notebook, the dashboard, and the tests can't drift. `configure-fabric.ps1 -ImportDashboard` imports it and reads it back; details, permissions, and limitations are in [its guide](realtime/README.md). How it fits next to Database Hub, the Power BI report, and the Fabric app is in [presentation surfaces](../docs/presentation.md).

The live-activity notebook's section 10 lists the workspace's Real-Time Dashboards and still describes the two manual ways to build one: Database Hub's template wizard, or by hand.

## Rules for notebooks

- Keep the PySpark kernel and the `LH_DatabaseHub` lakehouse name. Never commit a workspace or lakehouse ID: export the notebook, then remove them (a test fails on any GUID-shaped value in a notebook).
- Keep `"language_info": {"name": "python"}` in the notebook metadata. Fabric's [Run On Demand Item Job](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job) rejects a notebook without it ("Not supported language"), and Fabric's own `.ipynb` export includes it.
- Commit notebooks **without outputs**. CI fails if a cell has outputs or an execution count (`tests/unit/Repo.Conventions.Tests.ps1`, `tests/unit/Fabric.Notebooks.Tests.ps1`), and the pre-commit `nbstripout` hook strips them. The committed files already use the sequential cell IDs that `nbstripout` writes, so the hook leaves them unchanged.
- No credentials, ever. Tokens come from `notebookutils.credentials` at run time and are never printed.
- Cells that change resources start with `# RESOURCE-CHANGING CELL:`, follow a markdown cell that flags them, and do nothing unless `CONFIRM = True`.
- Use only documented interfaces: never call Database Hub private routes, and describe expected **signals** for Database Agent prompts, never expected answers.
- To edit a notebook, change it in Fabric, export it as `.ipynb`, run `nbstripout` (or let the pre-commit hook do it), and commit; or edit the JSON directly and run the Pester tests.
- Two notebook tests run the live-activity notebook's own episode detection on fixture rows, and need Python 3 with pandas: set `DBHUB_TEST_PYTHON` to such an interpreter (a virtual environment's `python`), or they're skipped. One of them replays Phase 25a's CPU samples (T1 and T2 at 99 and 97 in `SQLProcessCPUPercent`, 0 in `AvgCPUPercent`) and checks that T1 and T2 get their CPU windows.

## Status

Phase 12 evolved `NB_DatabaseHub_Deployment` and added `NB_DatabaseHub_LiveActivity` and the import script.

**Done live (2026-10-21):**

- Both notebooks were imported into the workspace.
- `NB_DatabaseHub_Deployment` ran read-only end to end through the Job Scheduler, with `CONFIRM` and `PURGE_DEMO_TABLES` false, and no saved row contains a secret.
- The `kusto` token was accepted by the telemetry endpoint.

**Still pending:**

- A run of the live-activity notebook.
- A look at the run snapshot's printed outputs in the Monitor hub.
- The `workflow_dispatch` path with P9 once `demo-control.yml` exists (Phase 13).

See `docs/implementation-report.md`.

Phase 18 added the Real-Time Dashboard (`realtime/`) and made the import generic (`Import-DemoFabricItem`, which the notebook import now uses). On 2026-10-21 it was imported, read back, and every tile got data (`Test-DemoRealTimeDashboardData`).
