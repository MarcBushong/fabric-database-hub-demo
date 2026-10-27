# ADR 0014: Notebooks, their roles, and the Fabric capacity dependency

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** User-directed (Q0: evolve the supplied notebook; Q7: reuse the demo workspace, whose ID is in the notebook metadata, with `LH_DatabaseHub`) and the user's Revision 2 request for a second, live-activity notebook (plan §9.3)
- **Related:** [ADR 0011](0011-control-surface-priority.md), [ADR 0012](0012-validation-model.md), [ADR 0013](0013-agent-experience.md), `fabric/README.md`

## Context

- The supplied notebook `NB_DatabaseHub_Deployment.ipynb` is Fabric's blank template: one `1+1` cell, the PySpark kernel (`synapse_pyspark`), and default lakehouse `LH_DatabaseHub` in the demo workspace (both IDs are in the notebook metadata). Its saved output contains Livy session IDs.
- Fabric notebooks need an F SKU or Trial capacity; Hub itself is free.
- `notebookutils.credentials.getToken` supports only the `storage`, `pbi`, `keyvault`, and `kusto` audiences. There's no Azure Resource Manager audience, so a notebook can't start VMs or run Run Command. The notebooks also can't reach the private SQL Servers.
- Using a `kusto` token against the telemetry REST endpoint isn't documented, so it has to be validated.
- Telemetry retention is 7 days or less.
- Fabric REST can create a notebook and update its definition. Changing the workspace needs the owner's go-ahead.

## Decision

### `fabric/notebooks/NB_DatabaseHub_Deployment.ipynb` (evolved, not replaced)

- **Keeps** its name, the PySpark kernel, the `LH_DatabaseHub` binding, the session timeout, and the compute setting. It replaces the template cell with real content and keeps nothing fabricated.
- **Roles:** deployment companion, validator, presenter script, troubleshooting and cleanup guide, and architecture explainer.
- **Sections** follow the brief: overview, value, architecture, prerequisites, security and permissions, cost, deployment, SQL Server and Arc, Azure SQL, Hub discovery, performance monitoring, agent skills, optional mirroring (deferred), data generation, scenarios, Hub and agent prompts, expected findings, remediation, reset, start and stop, validation, troubleshooting, cleanup, limitations and preview disclosures, and official references.
- It links to the live-activity notebook.

### `fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb` (new)

- **Purpose:** simulate live server activity and analyze locks, blocking, and overall consumption in Database Hub.
- **Same kernel and lakehouse binding** as the first notebook.
- **Sections** (plan §9.3):
  1. Parameters. Resource-changing cells need `CONFIRM = True`.
  2. Simulation control: start, stop, or switch activity profiles through `workflow_dispatch` with the P9 token. Without P9, the cell prints the Actions link and CLI command. Runs are recorded in `scenario_runs`.
  3. Live analysis through the telemetry REST endpoint with a `kusto` token, or a printed KQL fallback with an ADX link. Covers estate pulse, locks and blocking, overall consumption, and correlation of scenario windows with telemetry. Queries filter on time first, take deltas of cumulative counters, and branch on counter type.
  4. "See it in the Hub": deep links and Database Agent prompts. It describes signals, never expected AI output.
  5. Persist snapshots to `telemetry_snapshots` and `analysis_findings`, extending history past the retention window.
  6. Optional Real-Time Dashboard over the telemetry endpoint.
  7. Stop and clean up.

### Rules for both notebooks

- Markdown narration; parameterized environment values; no credentials; tokens never printed and token-like values redacted before display.
- Idempotent cells; dry-run by default where meaningful; resource-changing cells flagged and gated by `CONFIRM`.
- They never claim that a cell provisioned something a supported API didn't. Where automation isn't supported, a validation cell is paired with a short manual instruction.
- Results go to Delta tables in `LH_DatabaseHub`: `validation_results`, `scenario_runs`, `telemetry_snapshots`, and `analysis_findings`.
- Outputs are stripped before commit. CI fails if any cell has outputs or execution counts, and a pre-commit hook strips them locally.

### Import

- `configure-fabric.ps1` creates or updates both notebooks in the demo workspace (its ID is in the notebook metadata) through Fabric REST, using the user's Fabric token. It runs only on the local path by default; in Actions only when the service-principal tenant setting and a workspace role allow it.
- **Changing the workspace is pending the owner's go-ahead.**

## Consequences

- **Positive:** presenters get a guided script, a validator, and a live analysis surface in Fabric, with history beyond telemetry retention.
- **Negative:** the notebooks need capacity (P5) and can only control the demo through GitHub (P9). The notebook `kusto` token path is undocumented; it worked on 2026-10-21 (R29 closed), and the fallbacks stay in case it changes: printed KQL, a Real-Time Dashboard, or `validate.ps1`.

## Validation

- **Phase 4 (static):** notebook JSON validates against nbformat 4.5; kernel and lakehouse metadata match; no outputs.
- **Phase 12 (static, done):** `tests/unit/Fabric.Notebooks.Tests.ps1` (structure, exact metadata, nbstripout-canonical form, parameters cell, no secrets, token audiences, `CONFIRM` gating, KQL rules, Python 3.10 syntax) and `tests/unit/DbHubDemo.Fabric.Tests.ps1` (definition, request shapes, long-running operations, `-WhatIf` with no calls).
- **Phase 12 (live, 2026-10-21):** both notebooks were imported, and `NB_DatabaseHub_Deployment` ran read-only end to end through the Job Scheduler. `HUB.TELEMETRY.TOKEN` passed, which closes R29 (details below).
  - A first attempt the same morning was blocked because the workspace's capacity was paused.
  - Still pending: a run of the live-activity notebook, and the `workflow_dispatch` path with P9.

## Phase 12 implementation notes (2026-10-20)

- **Import:** `scripts/configure-fabric.ps1`, built on the module functions `Get-DemoFabricToken`, `Get-DemoFabricNotebookDefinition`, and `Import-DemoFabricNotebook`. It finds each notebook by display name and calls Items - Create Item (type `Notebook`) or Items - Update Item Definition with format `ipynb` and one part, `notebook-content.ipynb`, as in the Create Notebook ipynb example (the definition article's generic example names the part `artifact.content.ipynb`; on 2026-10-21 Fabric accepted `notebook-content.ipynb` for both create and update). HTTP 202 is polled with Get Operation State after `Retry-After`. The token is a SecureString sent only to `https://api.fabric.microsoft.com/v1`; `-WhatIf` sends nothing and needs no token. When the configured lakehouse differs from the notebooks' binding, only the uploaded copy is rebound.
- **Parameters cell:** cell metadata `tags: ["parameters"]`, the convention that Fabric's **Toggle parameter cell** writes to `.ipynb` (as in Synapse and papermill). It was confirmed live: a job's `executionData.parameters` replaced the cell's defaults. Booleans that arrive from a pipeline as strings count as true only for `true`, `1`, or `yes`.
- **Language:** the metadata also carries `"language_info": {"name": "python"}`. The supplied file lacked it; Fabric's own export has it, and Run On Demand Item Job rejects a notebook without it.
- **Two switches for cells that undo work:** dropping the Delta tables needs `PURGE_DEMO_TABLES` and `CONFIRM`; stopping all activity needs `STOP_ACTIVITY` and `CONFIRM`. **Run all** with `CONFIRM = True` therefore starts a scenario without stopping it at the end. An identical simulation request within 2 minutes is skipped.
- **`demo-control.yml` input contract** (Phase 13 declares it): `environment`, `target` (`all`, `T1`, `T2`, `T3`), `scenario` (`baseline`, `business-day`, `off`, or `incident:<scenario>`), `duration` (minutes), `concurrency` and `intensity` (omitted when 0, so the scenario's defaults apply), `reset-before`, and `auto-cleanup`, all as strings. A Pester test checks the names against the workflow once it declares inputs.
- **Telemetry:** the notebook `kusto` token is checked once (`HUB.TELEMETRY.TOKEN`); afterward each query either runs or prints its KQL with the Azure Data Explorer web UI steps. Per-bin timelines of cumulative counters keep the first and last sample of each series in each bin and sum the increases between adjacent samples, skipping resets: the article's pattern for queries that must scale, applied per bin.
- **Delta tables:** `validation_results`, `scenario_runs`, `telemetry_snapshots`, and `analysis_findings`, appended with `mergeSchema`; rows from the same run are replaced on re-run. Correlation thresholds (for example, CPU in a window at least 1.5 times and 10 points above the same target outside incident windows) are presenter heuristics, not product behavior.
- **Form in Git:** sequential cell IDs and no outputs, which is what the pre-commit `nbstripout` hook writes, so the hook leaves the files unchanged.

## Phase 12 live results (2026-10-21)

- **Authorized:** the import and one read-only run, with the backup first and nothing deleted.
- **Morning attempt, blocked:** the workspace's F capacity was paused; Fabric's List Capacities reported `Inactive`.
  - Get Workspace and List Items still worked, but Get Notebook Definition and Create Item returned HTTP 404 `CapacityNotActive`, marked not retriable. Nothing was backed up, imported, or run.
  - Resuming the capacity was left to its administrator, the owner: it's outside the demo's resource group and shared with other workspaces, and resuming it also resumes billing (ADR 0012 **Manual action required**). `Import-DemoFabricNotebook` now reports a paused capacity that way, with the resume steps.
- **After the owner resumed the capacity (about 17:13 UTC; left running at the owner's choice):**
  - **Backup:** the original notebook was saved outside every repo with Get Notebook Definition (`?format=ipynb`).
  - **Import:** both notebooks passed; the deployment notebook was updated and the live-activity notebook created. Reading them back showed the parts `notebook-content.ipynb` and `.platform`, the same kernel, lakehouse binding, and tagged parameters cell, and no outputs (R121 closed).
  - **Language defect, fixed:** the first Run On Demand Item Job was rejected in validation with "Not supported language: . Please set language name in metadata.language_info.name", and no session started. The notebooks now carry `"language_info": {"name": "python"}`, and both were imported again.
  - **The run:** one `RunNotebook` job of `NB_DatabaseHub_Deployment` only, with `executionData.parameters` set to `CONFIRM` false, `PURGE_DEMO_TABLES` false, `SAVE_RESULTS` true, and `TELEMETRY_LOOKBACK_MINUTES` 1440. It **Completed** in 57 seconds.
  - **Parameters cell (R122 closed):** the saved window spans the 1440 minutes passed, not the cell's default of 60, so the `parameters` tag works.
- **R29 closed:** `HUB.TELEMETRY.TOKEN` is **Pass**. The telemetry endpoint answered HTTP 200 to the notebook's `notebookutils.credentials.getToken('kusto')` token. Because this behavior isn't documented, the per-run check and the printed-KQL fallback stay.
- **Other checks:**
  - **Pass:** the Fabric session, capacity, lakehouse, and notebook checks.
  - **T3:** **Pass**, 7 tables, with the last sample under a minute old.
  - **T1 and T2:** **Warning**, as expected: both VMs were deallocated after a 16:24–16:50 UTC maintenance window, so their last samples were 36 minutes old. The query still found 10 tables for each within 24 hours.
  - **By design:** P4 and the Estate visual check are **Manual action required**, and Azure state is **Not supported**.
  - The results are in `dbo.validation_results` and `dbo.telemetry_snapshots` (the lakehouse has schemas), and no saved row contains a token-like string.

## Phase 18 notes (2026-10-21)

- **Section 6's optional Real-Time Dashboard is now code:** [`fabric/realtime/`](../../fabric/realtime/README.md) holds `RTD_DatabaseHub_LiveView`, generated from the live-activity notebook's own KQL. That KQL also lives in `scripts/modules/DbHubDemo/Kql/Live.*.kql`; the notebook keeps its inline copies unchanged, and `tests/unit/Fabric.Dashboard.Tests.ps1` fails if the two differ, so the notebook, the dashboard, and the tests share one version of the analysis.
- **Import:** `Import-DemoFabricItem` generalizes the notebook import (List Items by display name, Create Item or Update Item Definition, long-running-operation polling, and `-WhatIf` sending nothing) and adds a read-back with Get Item Definition. `Import-DemoFabricNotebook` now calls it, with the same check IDs and messages. `configure-fabric.ps1 -ImportDashboard` imports the dashboard after the notebooks.
- **Fallbacks:** the dashboard is the governed form of the "Real-Time Dashboard" fallback under Consequences. It queries the telemetry endpoint as each viewer through an Azure Data Explorer data source, so it doesn't depend on the notebook's `kusto` token.
- **Capacity and viewers:** the dashboard needs the same capacity as the notebooks (P5), and its viewers need Reader on the subscription. Viewers of Power BI content on a capacity smaller than F64 need Pro, PPU, or a trial (P11, `PREFLIGHT.FABRIC.VIEWERLICENSE`); see [presentation surfaces](../presentation.md).

## Sources (checked 2026-10-19; Phase 12 sources checked 2026-10-20, live-attempt sources 2026-10-21)

- Fabric licenses (capacity requirement): <https://learn.microsoft.com/fabric/enterprise/licenses>
- `notebookutils` credentials (the earlier `notebookutils-credentials` URL now returns 404): <https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials>
- `notebookutils` runtime context: <https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-runtime>
- Parameter cells: <https://learn.microsoft.com/fabric/data-engineering/author-execute-notebook>
- Items - Create Item: <https://learn.microsoft.com/rest/api/fabric/core/items/create-item>
- Items - Update Item Definition: <https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition>
- Items - List Items and pagination: <https://learn.microsoft.com/rest/api/fabric/core/items/list-items>, <https://learn.microsoft.com/rest/api/fabric/articles/pagination>
- Notebook - Create Notebook (ipynb example): <https://learn.microsoft.com/rest/api/fabric/notebook/items/create-notebook>
- Long-running operations: <https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation>
- Fabric token from the Azure CLI for user-delegated calls: <https://learn.microsoft.com/fabric/graph/gql-query-api>
- GitHub `workflow_dispatch` REST API: <https://docs.github.com/rest/actions/workflows#create-a-workflow-dispatch-event>
- Notebook REST definition: <https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/notebook-definition>
- Telemetry REST endpoint: <https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry>
- Real-Time Dashboards: <https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create>
- Notebook - Get Notebook Definition (`ipynb` format): <https://learn.microsoft.com/rest/api/fabric/notebook/items/get-notebook-definition>
- Job Scheduler - Run On Demand Item Job and Get Item Job Instance: <https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job>, <https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/get-item-job-instance>
- Notebook public APIs (run on demand, exit value): <https://learn.microsoft.com/fabric/data-engineering/notebook-public-api>
- Pause and resume a Fabric capacity: <https://learn.microsoft.com/fabric/enterprise/pause-resume>
- OneLake access with a Storage token: <https://learn.microsoft.com/fabric/onelake/onelake-access-api>
- KQL dashboard item definition and Items - Get Item Definition (checked 2026-10-21): <https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition>, <https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition>
