# Report Spec

Phase 19, step 1: the locked report spec for the Power BI history report, its Direct Lake semantic model, and the Fabric app. This step builds nothing and makes no Fabric calls. The owner approves this spec first; the build follows the `powerbi-report-planning` workflow after approval.

> **Scope change (2026-10-22, the user's decision):** the org app is dropped. Everything below about the org app, `APP_DatabaseHub_Demo`, its template, and its `FABRIC.ORGAPP.*` records is superseded, and Phase 19 creates no app. The demo's Fabric app is a separate item: a Fabric Apps (preview) item built with the Rayfin SDK and CLI over `SM_DatabaseHub_History` (Phase 19b). The report and the semantic model are unchanged. Build deviations are listed in the report's [known limits](../README.md#known-limits) and the [generator's guide](../generator/README.md).

The report is **history**: it reads the lakehouse snapshots that the notebooks write. The live view stays Database Hub plus Phase 18's Real-Time Dashboard. Every page says so in its subtitle.

## Report identity

- Report name: `RPT_DatabaseHub_History`, shown to viewers as "Database Hub demo history".
- Semantic model: `SM_DatabaseHub_History`, a new Direct Lake on OneLake model over lakehouse `LH_DatabaseHub`, schema `dbo`.
- Audience:
  - Primary: a presenter who shows a customer what happened in the demo, as history beyond Database Hub's live views, usually on a shared screen.
  - Secondary: the demo owner, who checks readiness before a demo.
- Primary purpose: one governed, shareable story of the estate, its incidents, and its readiness.
- Delivery target: the existing Fabric workspace "Database Hub Demo" (F16 capacity). The model and the report are created by script through documented Fabric item definitions (TMDL and PBIR). An org app item packages the report, Phase 18's Real-Time Dashboard, and a link to Database Hub.

## User decisions and constraints

- Scope: four pages of history over the lakehouse tables. Nothing live: no DirectQuery, no auto page refresh, no telemetry endpoint access from the report.
- Page count: four, in the user's order: estate at a glance, the incident minute by minute, a signal explorer, and readiness checks.
- Interactivity: one history-period slicer on the estate page; one incident picker and Prev/Next buttons on the incident page; a four-slicer rail with a reset button on the explorer; a run and an area slicer on the readiness page; drillthrough from any target to the incident page.
- Design direction (user's choice, verbatim): "Operations cockpit: a dark canvas, high-contrast numbers, and color only where something needs attention". That is the design skill's Industrial Cockpit tone.
- Publishing: after approval, the build creates the semantic model, the report, and the org app item in the workspace through documented REST APIs. Sharing the app with viewers stays a manual, documented portal step.
- Tooling: see the dependency status below.
- Model edit permissions: the model is new. The lakehouse changes only through the notebook changes listed in this spec, which write lakehouse data only.
- Accessibility: WCAG 2.1 AA contrast on every text and mark, color never the only signal, alt text on every visual, and tab order that matches reading order.
- Data caveats:
  - The live-activity notebook hasn't run yet, and no incident scenario has run live; only the healthy baseline has. Today only the deployment notebook's rows exist: 12 `validation_results` rows and 54 `telemetry_coverage` rows in `telemetry_snapshots`. Pages 1 to 3 therefore open on explicit empty states until the live-activity notebook runs.
  - `scenario_runs` holds only notebook-dispatched requests. Runs started from PowerShell (`demo-control.ps1`), GitHub Actions, or the `business-day` profile are recorded in SQL (`demo.scenario_runs` in `ContosoCare`), which Fabric can't reach. The model gets incident windows from a new table that the live-activity notebook derives; see "Incident windows".
  - The telemetry endpoint keeps 7 days; the lakehouse keeps history beyond that.
  - Overlapping notebook runs store the same bins more than once; the measures keep only the most recent capture of each bin.
  - `scenario_runs` and `analysis_findings` don't exist yet, and `incident_windows` is new. Direct Lake can't frame a model whose source tables are missing, so the notebook changes create them first.
  - The Phase 19 branch base (`52890c8`) predates the Phase 12 tip (`0d8b4a6`); the build merges it before changing the notebooks.
  - Statuses follow ADR 0012: Pass, Fail, Warning, Manual action required, Not supported, and Not selected.

### Planning rounds recorded

- The user's request (verbatim): "Can we do the RTI dashboard as code, plus the hubs template wizard as a demo moment, and a pbi report, and a fabric app? I want to show how robust the presentation can be". Phase 18 owns the Real-Time Dashboard and the wizard moment; Phase 19 owns the Power BI report and the Fabric app.
- Round 1, audience and job: inferred, as recorded in the report identity.
- Round 2, model inventory: inspected from the Phase 12 notebook writers, `fabric/README.md`, and the read-only sample of the first live run. No real ID from the sample appears in this spec.
- Round 3, report shape (user's choice): the four pages above.
- Round 4, feel (user's choice): the operations cockpit above. Delivery: inferred, as recorded in the report identity.
- Coordinator constraints on the owner's behalf: no documented API publishes a workspace app, so app publishing stays manual unless a documented org-app item API exists (it does; see "App"); viewers on F16 need Pro or PPU; the report is labeled as history.

### Dependency status

| Dependency | Status | Used for |
|---|---|---|
| Semantic model | None yet. New `SM_DatabaseHub_History`; two of its five source tables exist today | All pages |
| PBIP and PBIR project | None yet. New under `fabric/powerbi/` | Report authoring |
| Power BI Desktop | 2.159 (Microsoft Store) installed. The Desktop bridge needs Desktop's report-authoring preview feature | Reload and screenshot loop |
| `powerbi-modeling-mcp` | Registered in this environment; not used in this step | Model authoring and DAX validation |
| `powerbi-report-authoring` skill and `powerbi-report-author` CLI | Skill available; the npm CLIs are installed and pinned during the build | PBIR generation and validation |
| `powerbi-report-management` skill | Available | Report create and update through Fabric REST |
| Fabric publishing | The signed-in user's Fabric token through `Invoke-DemoAz`; the F16 capacity must be running | Create Semantic Model, Create Report, Create Org App |
| Node.js | 26 available; the CLIs need 20 or later | Deterministic PBIR generator |

## Narrative

- Core story: the estate ran; something happened on one target; the telemetry caught it minute by minute; the evidence explains it; and the demo is ready to show it again.
- Audience promise: "one governed, shareable story of the estate, its incidents, and its readiness".
- Key questions answered:
  - Estate at a glance: which targets reported in this period, which findings still need attention, and when did each target run hot?
  - The incident, minute by minute: when did the signal rise, how high did it peak against its baseline, how long did it last, and did the expected signal appear?
  - Signal explorer: how did any signal move on each target, what moved with load, and where did the wait time go?
  - Readiness checks: did the latest validation run pass, what needs a manual step, is each target still sending telemetry, and how has readiness changed across runs?

## Design identity (from `powerbi-report-design` Step 1)

- Tone: Industrial Cockpit, dark. A near-black graphite canvas (`#0E0E10`), graphite containers (`#17171C`), white Segoe UI numbers (`#F2F2F5`), and greyscale data ink. Color appears only where something needs attention.
- Signature: attention-lit status rails. Every status-bearing element (the target tiles, the readiness and history tiles, the verdict tile, and every row of the two queues) sits on graphite with a 4 px left rail and a glyph. The rail and the glyph light up only for Fail (red `#FF4D5A`, ✕), Manual action required (cyan `#8CEEEE`, ⚑), or Warning (amber `#FFB020`, ▲). Pass (✓), Not supported (⊘), and Not selected (○) stay graphite. The one non-status color is an indigo band (`#5772D9`) that marks incident windows.
- Brownfield delta: not applicable; greenfield.

## Page plan (archetypes from `powerbi-report-design` Step 3)

The composition is the design skill's "Ops + Detail" pattern in the user's order: an operational landing, a narrative incident page, an analytical explorer, and an operational exception view. Three archetypes; the two Operational Monitor pages use different variants.

1. Estate at a glance
   - Archetype: Operational Monitor.
   - Layout variant (A/B/C): A, 4-Up Status. Desk viewing on a shared screen with per-target status, a shared time axis, and an exception queue is the 4-Up signal; the geo or topology zone becomes a target health matrix, because three demo targets have no meaningful geography.
   - Purpose: show, for a chosen history period, which targets reported, when each ran hot, and which findings still need attention.
   - Visuals: five attention-lit tiles (T1, T2, T3, readiness, history freshness); a CPU timeline as small multiples by target, with incident windows drawn in indigo and an 80 % attention line; the open-findings queue, worst first; a target health matrix.
   - Fields/measures: `CPU (%)`, `CPU Peak (%)`, `CPU In Incident Window`, `Blocked Processes (peak)`, `Buffer IO Wait (s)`, `Log Rate Governor Wait (s)`, `Batch Requests`, `Findings Needing Attention`, `Target Tile Context`, `Target Rail Color`, `Checks Needing Attention (selected run)`, `Readiness (%)`, `Hours Since Latest Capture`, `History Freshness Label`, `Estate Headline`; `Status`, `Target`, `Analysis`, and `Date` attributes.
   - Slicers/interactions: one history-period slicer (between, `Date[Date]`), synced with the explorer; tiles filter; the other visuals highlight; drillthrough on `Target[Target]` (the timeline panels and the health matrix rows) to the incident page.
   - Empty state: the title reads "No telemetry history yet: run NB_DatabaseHub_LiveActivity to start the estate's history"; the readiness tile still shows the deployment notebook's run.
2. The incident, minute by minute
   - Archetype: Narrative Story.
   - Layout variant (A/B/C): C, Annotated-Hero. One timeline's shape is the whole argument: the rise, the peak, and the recovery around a shaded window.
   - Purpose: tell one incident as a thesis sentence, prove it with the minute-by-minute signal, and hand the presenter the exact Database Agent prompt to continue live in the Hub.
   - Visuals: a dynamic thesis title; the annotated timeline (signal line, shaded window band, one labeled peak marker, a threshold line where the signal has one); a narrative callout; a verdict tile; a compact evidence table; Prev and Next buttons.
   - Fields/measures: `Incident Windows[Incident]`; `Focus Signal Value`, `Focus Window Band`, `Focus Peak Point`, `Focus Threshold`, `Incident Headline`, `Incident Narrative`, `Focus Verdict`, `Focus Peak Delta Label`, `Focus Duration (min)`, `Finding In Focus Window`, `Incident Timeline Alt Text`.
   - Slicers/interactions: one single-select incident picker, newest first. With no selection the page shows the latest incident, or the drilled-through target's latest incident. No other slicers and no cross-filtering: the author controls the story.
   - Empty state: with no incident window the title reads "No incident captured yet: the estate's baseline, minute by minute", the timeline shows batch requests for the latest analysis window, and the callout gives the exact steps to capture an incident.
3. Signal explorer
   - Archetype: Analytical Canvas.
   - Layout variant (A/B/C): A, Filter-Rail. Four slicers plus a reset button fill more than half of a two-column rail, which is the rail threshold; the hero still keeps ten columns.
   - Purpose: let the presenter or owner pick any of eleven signals and see how it moved on each target, what it moved with, and where the wait time went.
   - Visuals: the selected signal as small multiples by target with incident windows in indigo and the signal's attention threshold; a scatter of the signal against batch requests per bin; a ranked bar of wait time by category; a findings detail table.
   - Fields/measures: `Signal[Signal]`, `Signal Value`, `Signal Value In Incident Window`, `Signal Threshold`, `Batch Requests`, `Wait Time (s)`, `Wait Bar Color`, `Explorer Headline`, `Active Filters Summary`; finding columns.
   - Slicers/interactions: history period (synced), target tiles, signal dropdown (single select), and finding status (filters only the detail table); a reset button bound to the "Explorer reset" bookmark; cross-highlight between visuals; drillthrough to the incident page; personalized visuals on.
   - Empty state: the title reads "CPU, average per bin: no telemetry bins in this selection".
4. Readiness checks
   - Archetype: Operational Monitor.
   - Layout variant (A/B/C): C, Incident-First. The owner works the exception queue, so the queue is the working surface and the status tiles shrink to a strip.
   - Purpose: answer "is the demo ready?" from the selected validation run, worst first, with the exact remediation for each check.
   - Visuals: four strip tiles (failed, manual step, warnings, readiness); the check queue; a heat strip of the worst status per area across the latest six runs; telemetry coverage per target from the same run.
   - Fields/measures: `Checks (selected run)` and its per-status variants, `Readiness (%)`, `Validation Run Label`, `Readiness Headline`, `Is Selected Validation Run`, `Worst Check Status Glyph`, `Worst Check Status Color`, `Coverage Tables (selected run)`, `Coverage Last Sample Age (min)`, `Coverage Attention`; check columns.
   - Slicers/interactions: validation run (single select, newest first; none selected means the latest run) and area (multi-select); the heat strip ignores the run slicer so it always shows the latest six runs.
   - Scope note in the subtitle: these are the Fabric-side checks from `NB_DatabaseHub_Deployment`; the Azure-side catalog stays in `./scripts/validate.ps1`.

## Design system summary

- Theme name + base palette: "DbHub Cockpit Dark", adapted from the design skill's `assets/base.json` with its per-type safeguards kept. Page `#0E0E10`, containers `#17171C`, raised surfaces and table headers `#1F1F26`, borders `#2A2A3A` (1 px, radius 4), dotted gridlines `#3A3A4A`, text `#F2F2F5`, `#B4B4C2`, and `#8C8C9C`.
- Color semantics: data ink is neutral (`#E6E6EE` for primary series, `#B4B4C2` for bars). Status colors come only from the Status dimension and only for statuses that need attention: Fail `#FF4D5A`, Manual action required `#8CEEEE`, Warning `#FFB020`. Pass, Not supported, and Not selected are graphite `#8C8C9C`; an unlit rail is `#2A2A3A`. Indigo `#5772D9` marks incident windows and nothing else. Targets are told apart by position, labels, lightness (`#E6E6EE`, `#A0A0B0`, `#6C6C80`), and marker shape, never by hue.
- Typography pairing: Segoe UI throughout, on a 1.333 ramp: 24 pt Semibold page titles, 13 pt Semibold visual titles, 32 pt Bold KPI values, and 10 pt body and labels. Four sizes per page at most. Numbers are right-aligned in tables.
- Layout pattern: FHD 1920 × 1080, 12 × 12 grid, 32 px margins, 24 px gutters, 8 px snap. Row 1 is the reserved title and slicer band on every page; the explorer adds a two-column filter rail.
- Accessibility commitments: measured contrast on `#17171C`: text 16.0:1, 8.7:1, and 5.4:1; Fail 5.5:1, Warning 9.8:1, Manual action required 13.3:1; the indigo band 4.1:1 as a non-text mark. Status chips use dark text `#0E0E10` on attention fills (5.9:1 or better). Every status pairs color with a glyph and the status word. Alt text on every visual; the incident timeline's alt text is a DAX measure. Tab order follows reading order.

## Model requirements

- Existing measures: none; the model is new.
- New measures: the catalog below. Measure names are the display names; visuals rename nothing except where the design contract sets a label.
- New calculated columns: none. Direct Lake on OneLake tables take derived columns from the lakehouse (`report_date_utc`, `incident_label`, `incident_sort`), which the notebook changes write.
- Relationship/sort requirements: sixteen single-direction, many-to-one relationships to four dimensions (Target, Status, Analysis, and Date; Signal is disconnected); sort-by columns on Status (severity), Target (fixed T1 to T3 order), Signal, Analysis, Date months, and the incident picker (newest first).

### Data inspected

Read from the Phase 12 tip (`origin/marcbushong-phase-12-notebooks`, `0d8b4a6`): the writers' `TABLE_COLUMNS`, `write_delta`, `add_snapshot`, and `add_finding` in both notebooks, `fabric/README.md`, and the first live run's Delta logs. All tables are managed Delta tables in `LH_DatabaseHub`, schema `dbo`, unpartitioned, with deletion vectors on. Timestamps are Spark `timestamp` values (UTC instants); `value` is a `double`.

| Table | Written by | Grain | Notes |
|---|---|---|---|
| `validation_results` | `NB_DatabaseHub_Deployment` | One check per validation run (`run_id` × `check_id`) | 12 columns; 12 rows today (7 Pass, 2 Warning, 2 Manual action required, 1 Not supported) |
| `scenario_runs` | `NB_DatabaseHub_LiveActivity` | One notebook-dispatched request | 19 columns; doesn't exist yet |
| `telemetry_snapshots` | Both notebooks | One value per run × analysis × target × resource × instance × database × metric × bin | 15 columns; 54 `telemetry_coverage` rows today |
| `analysis_findings` | `NB_DatabaseHub_LiveActivity` | One finding per run (`run_id` × `finding_id`) | 12 columns; doesn't exist yet |
| `incident_windows` | `NB_DatabaseHub_LiveActivity` (new) | One incident window | 18 columns; added by Phase 19 |

The live-activity notebook's bin is automatic: 1 minute for windows up to 2 hours (the default 60-minute window), 5 minutes up to 12 hours, and 15 minutes beyond; `BIN_MINUTES` overrides it. The analyses it writes to `telemetry_snapshots`, and what `bucket_utc` means for each:

| Analysis | Metrics (`metric`) | `bucket_utc` |
|---|---|---|
| `cpu` | `AvgCPU`, `MaxCPU` (percent; T3 is a percentage of the tier limit) | Bin |
| `gauges` | `Processes blocked`, `Active Transactions`, `User Connections` (maximum per bin) | Bin |
| `counter_deltas` | `Batch Requests/sec`, `Transactions/sec`, `Number of Deadlocks/sec`, `Log Bytes Flushed/sec` (per-bin deltas, so counts per bin) | Bin |
| `sessions` | `MaxSessions`, `AvgSessions`, `MaxRunning` | Bin |
| `wait_deltas` | Wait category, plus a `(PAGEIOLATCH)` suffix after a space for Buffer IO page latches; value in milliseconds per bin | Bin |
| `storage_io` | `ReadMB`, `WriteMB`, `Reads`, `Writes` (data and log files, not distinguished) | Bin |
| `estate_pulse` | `Rows`, `Tables`, `LastSampleAgeMinutes` | Empty: one row per analysis window |
| `wait_profile` | Wait category; value in seconds over the window | Empty: one row per analysis window |
| `memory_clerks` | Clerk type; value in MB | Latest sample time |
| `database_growth` | `StartUsedMB`, `EndUsedMB`, `GrowthMB`, `LogUsedMB`, `VersionStoreMB` | Latest sample time |
| `telemetry_coverage` (deployment notebook) | `<Table>.rows`, `<Table>.instances` | Latest sample time per telemetry table |

`analysis_findings` holds the analyses `telemetry_access`, `estate_pulse`, `blocking` (one finding per blocking incident with its window, plus a `deadlocks` summary), `consumption` (CPU and log-rate findings per target), `correlation` (one per recorded scenario window), and `real_time_dashboard`. Re-running a notebook cell replaces that run's rows, but two runs with overlapping windows store the same bins twice.

### Storage mode, framing, and refresh

- Mode: **Direct Lake on OneLake**. Learn: "Direct Lake on OneLake runs exclusively in DirectLakeOnly mode and doesn't support DirectQuery fallback. For new semantic models, it's the recommended Direct Lake option" ([How Direct Lake works](https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works)). It reads the Delta tables through OneLake without the SQL analytics endpoint, needs no views, and can hold calculated tables that don't reference Direct Lake tables ([Direct Lake overview](https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview)).
- Connection: one shared expression with `AzureStorage.DataLake` over `https://onelake.dfs.fabric.microsoft.com/{workspaceId}/{lakehouseId}`, and an `EntityPartitionSource` partition in `directLake` mode per table (`schemaName: dbo`). Git holds an all-zero placeholder; the deploy script substitutes the configured IDs in memory.
- Framing: a refresh frames the model to the latest Delta version of each table. "Keep your Direct Lake data up to date" stays on (the default), so a notebook write reframes only the changed tables. Tables created through the API start unprocessed, so the build refreshes once after creating the model. If a refresh fails, automatic updates pause until an on-demand refresh succeeds; the deploy script's refresh step is that recovery ([How Direct Lake works](https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works)).
- Guardrails on F16: 1,000 Parquet files and 1,000 row groups per table, 300 million rows, 20 GB. A table over a guardrail stops the whole Direct Lake on OneLake model from refreshing ([Direct Lake overview](https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview)). Today's writer appends about eight files per write, so the notebook changes write one file per write and compact large tables.
- Security: default SSO. Direct Lake on OneLake needs the querying user, and the model owner for framing, to have Read and ReadAll on `LH_DatabaseHub`; workspace Contributors and above have both ([Integrate Direct Lake security](https://learn.microsoft.com/fabric/fundamentals/direct-lake-security-integration)). App viewers are covered in "App". No row-level security.

### Time zone handling

- Every DateTime column holds a UTC instant written by Spark; Direct Lake surfaces it as a DateTime without conversion, and the model never converts. Every label, axis title, and subtitle says UTC.
- `Date` is the UTC calendar date of each row's primary time (`report_date_utc`), so a midnight-spanning incident falls on its start date.
- Ages use `UTCNOW()`, never `NOW()`.
- The build verifies the mapping once with a DAX query against a known row: the first deployment run's checks are timestamped about 17:25 UTC on 21 October 2026.

### Tables

Five Direct Lake fact tables over the Delta tables and five calculated dimension tables defined in TMDL. Columns get business names; keys, foreign keys, and aggregated numerics are hidden; `summarizeBy: none` on every numeric column; `discourageImplicitMeasures: true`. `value` stays `double`: Direct Lake maps the Delta type as is, and every aggregation goes through measures with explicit format strings.

| Table | Storage | Source | Grain or rows |
|---|---|---|---|
| Validation Results | Direct Lake | `dbo.validation_results` | One check per validation run |
| Scenario Runs | Direct Lake | `dbo.scenario_runs` | One notebook-dispatched request |
| Telemetry Snapshots | Direct Lake | `dbo.telemetry_snapshots` | One value per run, analysis, target, resource, instance, database, metric, and bin |
| Analysis Findings | Direct Lake | `dbo.analysis_findings` | One finding per run |
| Incident Windows | Direct Lake | `dbo.incident_windows` | One incident window; also the incident picker |
| Target | Calculated (`DATATABLE`) | TMDL | 9 rows: T1, T2, T3, all, fabric, subscription, tenant, github, repo |
| Status | Calculated (`DATATABLE`) | TMDL | 6 rows: the ADR 0012 statuses |
| Analysis | Calculated (`DATATABLE`) | TMDL | 16 rows: every analysis key in snapshots and findings |
| Signal | Calculated (`DATATABLE`), disconnected | TMDL | 11 rows: the explorer's signals |
| Date | Calculated (`CALENDAR`) | TMDL | One row per UTC date, 2026-01-01 to 2030-12-31; marked as the date table |

Fact columns (source column, then model column; H = hidden):

| Table | Columns |
|---|---|
| Validation Results | `run_id` Run ID; `source_notebook` Source Notebook (H); `check_id` Check ID; `area` Area; `target` Target Key (H); `status` Status Key (H); `message` Message; `evidence` Evidence; `remediation` Remediation; `doc_url` Documentation (web URL); `evaluation_only` Evaluation Only; `timestamp_utc` Checked At UTC; `report_date_utc` Report Date UTC (H) |
| Scenario Runs | `request_id` Request ID; `run_id` Run ID (H); `source_notebook` Source Notebook (H); `requested_at_utc` Requested At UTC; `environment` Environment (H); `target` Target Key (H); `profile` Profile; `duration_minutes` Duration (min); `concurrency` Concurrency; `intensity` Intensity; `reset_before` Reset Before; `auto_cleanup` Auto Cleanup; `dispatch_mode` Dispatch Mode; `status` Status Key (H); `message` Message; `github_run_id` GitHub Run ID (H); `github_run_url` GitHub Run (web URL); `window_start_utc` Window Start UTC; `window_end_utc` Window End UTC; `report_date_utc` Report Date UTC (H) |
| Telemetry Snapshots | `run_id` Run ID (H); `source_notebook` Source Notebook (H); `captured_at_utc` Captured At UTC (H); `analysis` Analysis Key (H); `target` Target Key (H); `resource_type` Resource Type; `resource_name` Resource Name; `instance_name` Instance Name; `database_name` Database Name; `metric` Metric; `bucket_utc` Bucket UTC; `value` Value (H); `unit` Unit; `window_start_utc` Window Start UTC (H); `window_end_utc` Window End UTC (H); `report_date_utc` Report Date UTC (H) |
| Analysis Findings | `run_id` Run ID (H); `finding_id` Finding ID; `source_notebook` Source Notebook (H); `captured_at_utc` Captured At UTC; `analysis` Analysis Key (H); `target` Target Key (H); `status` Status Key (H); `finding` Finding; `evidence` Evidence; `request_id` Request ID (H); `window_start_utc` Window Start UTC; `window_end_utc` Window End UTC; `report_date_utc` Report Date UTC (H) |
| Incident Windows | `incident_key` Incident Key (H); `incident_label` Incident (sorted by Incident Sort); `incident_sort` Incident Sort (H); `source` Source; `target` Target Key (H); `scenario` Scenario; `signal_family` Signal Family; `request_id` Request ID (H); `window_start_utc` Window Start UTC; `window_end_utc` Window End UTC; `duration_minutes` Duration (min); `peak_value` Peak Value (H); `peak_unit` Peak Unit (H); `correlation_status` Correlation Status Key (H); `correlation_evidence` Correlation Evidence; `run_id` Run ID (H); `captured_at_utc` Captured At UTC (H); `report_date_utc` Report Date UTC (H) |

Types: Delta `string` maps to String, `timestamp` and `date` to DateTime, `integer` and `long` to Int64, `boolean` to Boolean, and `double` to Double.

The calculated dimensions, as TMDL partition expressions:

```dax
Target =
DATATABLE (
    "Target Key", STRING, "Target", STRING, "Target Short", STRING,
    "Target Kind", STRING, "Platform", STRING, "Target Sort", INTEGER,
    {
        { "T1", "T1 · SQL Server on Azure VM", "T1", "SQL target", "SQL Server 2022 on an Azure VM", 1 },
        { "T2", "T2 · Arc-enabled SQL Server", "T2", "SQL target", "Arc-enabled SQL Server in a nested Hyper-V guest", 2 },
        { "T3", "T3 · Azure SQL Database", "T3", "SQL target", "Azure SQL Database", 3 },
        { "all", "All targets", "All", "All targets", "Every SQL target", 4 },
        { "fabric", "Fabric workspace", "Fabric", "Platform scope", "Fabric workspace and lakehouse", 5 },
        { "subscription", "Azure subscription", "Subscription", "Platform scope", "Azure subscription and resource group", 6 },
        { "tenant", "Fabric tenant", "Tenant", "Platform scope", "Tenant settings", 7 },
        { "github", "GitHub", "GitHub", "Platform scope", "GitHub repository and Actions", 8 },
        { "repo", "Repository", "Repo", "Platform scope", "Static checks", 9 }
    }
)

Status =
DATATABLE (
    "Status", STRING, "Status Short", STRING, "Status Sort", INTEGER,
    "Needs Attention", STRING, "Needs Attention Flag", INTEGER,
    "Status Glyph", STRING, "Status Color", STRING, "Status Meaning", STRING,
    {
        { "Fail", "Fail", 1, "Yes", 1, "✕", "#FF4D5A", "A selected capability is broken, or a prerequisite is missing" },
        { "Manual action required", "Manual", 2, "Yes", 1, "⚑", "#8CEEEE", "A documented manual step is pending" },
        { "Warning", "Warning", 3, "Yes", 1, "▲", "#FFB020", "It works, but with a risk to address" },
        { "Pass", "Pass", 4, "No", 0, "✓", "#8C8C9C", "Functionally verified" },
        { "Not supported", "Not supported", 5, "No", 0, "⊘", "#8C8C9C", "The docs say the capability doesn't apply" },
        { "Not selected", "Not selected", 6, "No", 0, "○", "#8C8C9C", "The operator turned the capability off" }
    }
)

Analysis =
DATATABLE (
    "Analysis Key", STRING, "Analysis", STRING, "Analysis Group", STRING, "Grain", STRING, "Analysis Sort", INTEGER,
    {
        { "estate_pulse", "Estate pulse", "Estate", "Per analysis window", 1 },
        { "cpu", "CPU", "CPU", "Per bin", 2 },
        { "gauges", "Blocking and transaction gauges", "Locks and blocking", "Per bin", 3 },
        { "sessions", "Active sessions", "Locks and blocking", "Per bin", 4 },
        { "counter_deltas", "Throughput and deadlock counters", "Throughput", "Per bin", 5 },
        { "wait_deltas", "Wait deltas", "Waits", "Per bin", 6 },
        { "wait_profile", "Wait profile", "Waits", "Per analysis window", 7 },
        { "storage_io", "Storage IO", "IO", "Per bin", 8 },
        { "memory_clerks", "Memory clerks", "Memory", "Latest sample", 9 },
        { "database_growth", "Database growth", "Storage", "Latest sample", 10 },
        { "telemetry_coverage", "Telemetry coverage", "Readiness", "Latest sample per table", 11 },
        { "telemetry_access", "Telemetry access", "Readiness", "Per run", 12 },
        { "blocking", "Blocking", "Locks and blocking", "Per incident", 13 },
        { "consumption", "Consumption", "CPU and waits", "Per analysis window", 14 },
        { "correlation", "Scenario correlation", "Incidents", "Per scenario window", 15 },
        { "real_time_dashboard", "Real-Time Dashboard", "Readiness", "Per run", 16 }
    }
)

Signal =
DATATABLE (
    "Signal Key", STRING, "Signal", STRING, "Unit", STRING, "Signal Family", STRING,
    "Format String", STRING, "Attention Threshold", DOUBLE, "Signal Sort", INTEGER,
    {
        { "cpu", "CPU, average per bin", "%", "cpu", "#,0.0"" %""", 80, 1 },
        { "cpu_peak", "CPU, peak per bin", "%", "cpu", "#,0.0"" %""", 80, 2 },
        { "blocked", "Blocked processes, peak per bin", "processes", "blocking", "#,0", 1, 3 },
        { "lock_wait", "Lock waits per bin", "s", "blocking", "#,0.0", 1, 4 },
        { "deadlocks", "Deadlocks per bin", "deadlocks", "blocking", "#,0", 1, 5 },
        { "transactions", "Active transactions, peak per bin", "transactions", "blocking", "#,0", 0, 6 },
        { "buffer_io_wait", "Buffer IO (PAGEIOLATCH) waits per bin", "s", "io", "#,0.0", 1, 7 },
        { "io_mb", "Data and log IO per bin", "MB", "io", "#,0.0", 0, 8 },
        { "log_rate_wait", "Log Rate Governor waits per bin", "s", "log_rate", "#,0.0", 0.1, 9 },
        { "batch_requests", "Batch requests per bin", "requests", "activity", "#,0", 0, 10 },
        { "sessions", "Active sessions in ContosoCare, peak per bin", "sessions", "activity", "#,0", 0, 11 }
    }
)

Date =
ADDCOLUMNS (
    CALENDAR ( DATE ( 2026, 1, 1 ), DATE ( 2030, 12, 31 ) ),
    "Year", YEAR ( [Date] ),
    "Month Key", YEAR ( [Date] ) * 100 + MONTH ( [Date] ),
    "Month", FORMAT ( [Date], "mmm yyyy" ),
    "Day", DAY ( [Date] ),
    "Date Label", FORMAT ( [Date], "d mmm yyyy" )
)
```

Sort-by columns: `Status[Status]`, `Status[Status Short]`, and `Status[Status Glyph]` by `Status Sort` (severity: Fail, Manual action required, Warning, Pass, Not supported, Not selected); `Target[Target]` and `Target[Target Short]` by `Target Sort`; `Analysis[Analysis]` by `Analysis Sort`; `Signal[Signal]` by `Signal Sort`; `Date[Month]` by `Month Key`; `Incident Windows[Incident]` by `Incident Sort` (negative start time, so ascending is newest first). An attention threshold of 0 means "no threshold line".

### Relationships

All many-to-one, single direction, active, with matching data types. No bidirectional or many-to-many relationships.

| From (many) | To (one) |
|---|---|
| `Validation Results[Target Key]` | `Target[Target Key]` |
| `Validation Results[Status Key]` | `Status[Status]` |
| `Validation Results[Report Date UTC]` | `Date[Date]` |
| `Scenario Runs[Target Key]` | `Target[Target Key]` |
| `Scenario Runs[Status Key]` | `Status[Status]` |
| `Scenario Runs[Report Date UTC]` | `Date[Date]` |
| `Telemetry Snapshots[Target Key]` | `Target[Target Key]` |
| `Telemetry Snapshots[Analysis Key]` | `Analysis[Analysis Key]` |
| `Telemetry Snapshots[Report Date UTC]` | `Date[Date]` |
| `Analysis Findings[Target Key]` | `Target[Target Key]` |
| `Analysis Findings[Status Key]` | `Status[Status]` |
| `Analysis Findings[Analysis Key]` | `Analysis[Analysis Key]` |
| `Analysis Findings[Report Date UTC]` | `Date[Date]` |
| `Incident Windows[Target Key]` | `Target[Target Key]` |
| `Incident Windows[Correlation Status Key]` | `Status[Status]` |
| `Incident Windows[Report Date UTC]` | `Date[Date]` |

`Signal` is disconnected on purpose: it only selects which measure `Signal Value` returns.

### Measures

Every numeric and date measure has a format string, every measure has a description in TMDL (`///`), and each lives on the table it summarizes, in a display folder; text measures return text that is already formatted. Helper measures that return colors, flags, or keys are hidden. Two patterns carry most of the logic:

- **Latest capture wins.** Overlapping notebook runs store the same bin more than once. `Snapshot Value` keeps, per target, analysis, metric, and bin, only the most recent capture, then sums across instances and files inside that capture. Every telemetry measure builds on it.
- **Bins first, then aggregate.** Per-bin signals are evaluated per target and bin, then averaged (CPU), maximized (peaks), or summed (waits, requests, IO) over the selection.

Summary (format strings in backticks; "dynamic" means a dynamic format string):

| Table, folder | Visible measures and formats |
|---|---|
| Telemetry Snapshots, CPU | CPU (%) `#,0.0" %"`; CPU Peak (%) `#,0.0" %"`; CPU In Incident Window `#,0.0" %"` |
| Telemetry Snapshots, Locks and blocking | Blocked Processes (peak) `#,0`; Active Transactions (peak) `#,0`; Active Sessions (peak) `#,0`; Lock Wait (s) `#,0.0`; Deadlocks `#,0` |
| Telemetry Snapshots, Waits and IO | Buffer IO Wait (s) `#,0.0`; Log Rate Governor Wait (s) `#,0.0`; Wait Time (s) `#,0.0`; Data and Log IO (MB) `#,0.0`; Batch Requests `#,0` |
| Telemetry Snapshots, Explorer | Signal Value (dynamic); Signal Value In Incident Window (dynamic); Signal Threshold `#,0.#`; Explorer Headline (text); Active Filters Summary (text) |
| Telemetry Snapshots, Estate | Targets Reporting `#,0`; Telemetry Lag at Capture (min) `#,0.0`; Target Tile Context (text); Target Attention Signals (text) |
| Telemetry Snapshots, Freshness | Latest Capture UTC `yyyy-mm-dd hh:nn`; Hours Since Latest Capture `#,0.0`; History Freshness Status (text); History Freshness Label (text); Notebook Runs Captured `#,0` |
| Telemetry Snapshots, Coverage | Coverage Tables (selected run) `#,0`; Coverage Last Sample Age (min) `#,0.0`; Coverage Attention (text) |
| Analysis Findings | Findings `#,0`; Findings Needing Attention `#,0`; Blocking Incidents `#,0`; Estate Headline (text) |
| Validation Results | Checks (selected run) `#,0`; Checks Failed (selected run) `#,0`; Checks Needing a Manual Step (selected run) `#,0`; Checks With Warnings (selected run) `#,0`; Checks Passed (selected run) `#,0`; Checks Not Supported (selected run) `#,0`; Checks Not Selected (selected run) `#,0`; Checks Needing Attention (selected run) `#,0`; Checks Context (text); Readiness (%) `0%`; Readiness Headline (text); Validation Run Label (text); Worst Check Status Glyph (text); Run Start UTC `yyyy-mm-dd hh:nn` |
| Scenario Runs | Scenario Requests `#,0` |
| Incident Windows | Incidents `#,0`; Focus Signal Value (dynamic); Focus Window Band (dynamic); Focus Peak Point (dynamic); Focus Peak (dynamic); Focus Baseline (dynamic); Focus Threshold `#,0.#`; Focus Duration (min) `#,0`; Focus Window Start UTC and Focus Window End UTC `yyyy-mm-dd hh:nn`; Focus Verdict, Focus Peak Delta Label, Incident Headline, Incident Narrative, Incident Timeline Alt Text (text) |

Hidden helpers: Snapshot Value `#,0.##`, Signal Peak, Wait Bar Color, the four health-matrix font colors, Coverage Font Color, History Freshness Rail Color, Has Telemetry Bins, Worst Finding Status Sort, Target Rail Color, Is Latest Finding Capture, Finding In Focus Window, Selected Validation Run, Is Selected Validation Run, the three strip rail colors, Readiness Rail Color, Worst Check Status Sort, Worst Check Status Color, Has Incident, In Incident Window, Focus Incident Key, Focus Target Key, Focus Range Start UTC, Focus Range End UTC, Focus Signal Family, Focus Source, Focus Scenario, Focus Correlation Status, Focus Signal Raw, Focus Range Peak, Focus Signal Label, Focus Peak Label, Focus Resource Name, Focus Evidence Sentence, Focus Verdict Rail Color.

Telemetry Snapshots:

```dax
// Base (hidden). Format #,0.##. Latest capture wins per target, analysis, metric, and bin.
Snapshot Value =
SUMX (
    SUMMARIZE (
        'Telemetry Snapshots',
        'Telemetry Snapshots'[Target Key],
        'Telemetry Snapshots'[Analysis Key],
        'Telemetry Snapshots'[Metric],
        'Telemetry Snapshots'[Bucket UTC]
    ),
    VAR LatestCapture = CALCULATE ( MAX ( 'Telemetry Snapshots'[Captured At UTC] ) )
    RETURN
        CALCULATE ( SUM ( 'Telemetry Snapshots'[Value] ), 'Telemetry Snapshots'[Captured At UTC] = LatestCapture )
)

// CPU. Format #,0.0" %". On T3 the value is a percentage of the service tier's limit.
CPU (%) =
CALCULATE (
    AVERAGEX ( SUMMARIZE ( 'Telemetry Snapshots', 'Telemetry Snapshots'[Target Key], 'Telemetry Snapshots'[Bucket UTC] ), [Snapshot Value] ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "cpu" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "AvgCPU" )
)

CPU Peak (%) =
CALCULATE (
    MAXX ( SUMMARIZE ( 'Telemetry Snapshots', 'Telemetry Snapshots'[Target Key], 'Telemetry Snapshots'[Bucket UTC] ), [Snapshot Value] ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "cpu" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "MaxCPU" )
)

CPU In Incident Window = IF ( [In Incident Window], [CPU (%)] )

// Locks and blocking. Format #,0 unless noted.
Blocked Processes (peak) =
CALCULATE (
    MAXX ( SUMMARIZE ( 'Telemetry Snapshots', 'Telemetry Snapshots'[Target Key], 'Telemetry Snapshots'[Bucket UTC] ), [Snapshot Value] ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "gauges" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "Processes blocked" )
)

Active Transactions (peak) =
CALCULATE (
    MAXX ( SUMMARIZE ( 'Telemetry Snapshots', 'Telemetry Snapshots'[Target Key], 'Telemetry Snapshots'[Bucket UTC] ), [Snapshot Value] ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "gauges" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "Active Transactions" )
)

Active Sessions (peak) =
CALCULATE (
    MAXX ( SUMMARIZE ( 'Telemetry Snapshots', 'Telemetry Snapshots'[Target Key], 'Telemetry Snapshots'[Bucket UTC] ), [Snapshot Value] ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "sessions" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "MaxSessions" )
)

// Format #,0.0. Wait deltas are stored in milliseconds per bin.
Lock Wait (s) =
DIVIDE (
    CALCULATE (
        [Snapshot Value],
        KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "wait_deltas" ),
        KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "Lock" )
    ),
    1000
)

Deadlocks =
CALCULATE (
    [Snapshot Value],
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "counter_deltas" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "Number of Deadlocks/sec" )
)

// Waits and IO. Format #,0.0 unless noted.
Buffer IO Wait (s) =
DIVIDE (
    CALCULATE (
        [Snapshot Value],
        KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "wait_deltas" ),
        KEEPFILTERS ( FILTER ( ALL ( 'Telemetry Snapshots'[Metric] ), CONTAINSSTRING ( 'Telemetry Snapshots'[Metric], "(PAGEIOLATCH)" ) ) )
    ),
    1000
)

Log Rate Governor Wait (s) =
DIVIDE (
    CALCULATE (
        [Snapshot Value],
        KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "wait_deltas" ),
        KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "Log Rate Governor" )
    ),
    1000
)

Wait Time (s) =
DIVIDE ( CALCULATE ( [Snapshot Value], KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "wait_deltas" ) ), 1000 )

// Hidden. Bar fill: a signature category above 10 % of the wait time needs attention.
Wait Bar Color =
VAR Category = SELECTEDVALUE ( 'Telemetry Snapshots'[Metric] )
VAR Share = DIVIDE ( [Wait Time (s)], CALCULATE ( [Wait Time (s)], REMOVEFILTERS ( 'Telemetry Snapshots'[Metric] ) ) )
VAR IsSignature = Category IN { "Lock", "Log Rate Governor" } || CONTAINSSTRING ( Category, "(PAGEIOLATCH)" )
RETURN IF ( IsSignature && Share >= 0.1, "#FFB020", "#B4B4C2" )

Data and Log IO (MB) =
CALCULATE (
    [Snapshot Value],
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "storage_io" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] IN { "ReadMB", "WriteMB" } )
)

// Format #,0. A per-bin delta of the cumulative counter: requests in the bin.
Batch Requests =
CALCULATE (
    [Snapshot Value],
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "counter_deltas" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "Batch Requests/sec" )
)

// Explorer. Format string definition: SELECTEDVALUE ( 'Signal'[Format String], "#,0.0" ).
Signal Value =
SWITCH (
    SELECTEDVALUE ( 'Signal'[Signal Key], "cpu" ),
    "cpu", [CPU (%)],
    "cpu_peak", [CPU Peak (%)],
    "blocked", [Blocked Processes (peak)],
    "lock_wait", [Lock Wait (s)],
    "deadlocks", [Deadlocks],
    "transactions", [Active Transactions (peak)],
    "buffer_io_wait", [Buffer IO Wait (s)],
    "io_mb", [Data and Log IO (MB)],
    "log_rate_wait", [Log Rate Governor Wait (s)],
    "batch_requests", [Batch Requests],
    "sessions", [Active Sessions (peak)]
)

Signal Value In Incident Window = IF ( [In Incident Window], [Signal Value] )

Signal Threshold =
VAR T = SELECTEDVALUE ( 'Signal'[Attention Threshold] )
RETURN IF ( T > 0, T )

// Hidden.
Signal Peak =
MAXX ( SUMMARIZE ( 'Telemetry Snapshots', 'Telemetry Snapshots'[Target Key], 'Telemetry Snapshots'[Bucket UTC] ), [Signal Value] )

Explorer Headline =
VAR SignalName = SELECTEDVALUE ( 'Signal'[Signal], "CPU, average per bin" )
VAR Unit = SELECTEDVALUE ( 'Signal'[Unit], "%" )
VAR Candidates =
    FILTER (
        CALCULATETABLE ( VALUES ( 'Target'[Target Short] ), 'Target'[Target Kind] = "SQL target" ),
        NOT ISBLANK ( [Signal Peak] )
    )
VAR Best = TOPN ( 1, Candidates, [Signal Peak], DESC )
VAR BestTarget = MAXX ( Best, 'Target'[Target Short] )
VAR BestPeak = MAXX ( Best, [Signal Peak] )
RETURN
    IF (
        ISBLANK ( BestTarget ),
        SignalName & ": no telemetry bins in this selection",
        SignalName & " by target: the highest bin was " & FORMAT ( BestPeak, "#,0.#" ) & " " & Unit & " on " & BestTarget
    )

Active Filters Summary =
VAR Targets =
    CONCATENATEX (
        CALCULATETABLE ( VALUES ( 'Target'[Target Short] ), 'Target'[Target Kind] = "SQL target" ),
        'Target'[Target Short], ", ", 'Target'[Target Short], ASC
    )
VAR FirstDay = CALCULATE ( MIN ( 'Telemetry Snapshots'[Report Date UTC] ) )
VAR LastDay = CALCULATE ( MAX ( 'Telemetry Snapshots'[Report Date UTC] ) )
RETURN
    "Signal: " & SELECTEDVALUE ( 'Signal'[Signal], "CPU, average per bin" )
        & "  ·  Targets: " & Targets
        & IF ( NOT ISBLANK ( FirstDay ), "  ·  Data from " & FORMAT ( FirstDay, "d mmm yyyy" ) & " to " & FORMAT ( LastDay, "d mmm yyyy" ) & " UTC" )

// Estate.
Targets Reporting =
COUNTROWS (
    FILTER (
        CALCULATETABLE ( VALUES ( 'Target'[Target Key] ), 'Target'[Target Kind] = "SQL target" ),
        NOT ISBLANK ( [CPU (%)] )
    )
)

Telemetry Lag at Capture (min) =
CALCULATE (
    MAXX ( VALUES ( 'Telemetry Snapshots'[Target Key] ), [Snapshot Value] ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "estate_pulse" ),
    KEEPFILTERS ( 'Telemetry Snapshots'[Metric] = "LastSampleAgeMinutes" )
)

Target Tile Context =
IF (
    ISBLANK ( [CPU (%)] ),
    "No telemetry bins in this period",
    "Peak CPU " & FORMAT ( [CPU Peak (%)], "0" ) & " %  ·  "
        & FORMAT ( [Blocking Incidents] + 0, "0" ) & " blocking incident(s)  ·  telemetry lag "
        & FORMAT ( [Telemetry Lag at Capture (min)], "0" ) & " min"
)

// Hidden font colors for the health matrix: amber only past the detection thresholds.
CPU Peak Font Color = IF ( [CPU Peak (%)] >= 80, "#FFB020", "#F2F2F5" )
Blocked Font Color = IF ( [Blocked Processes (peak)] > 0, "#FFB020", "#F2F2F5" )
Buffer IO Font Color = IF ( [Buffer IO Wait (s)] >= 1, "#FFB020", "#F2F2F5" )
Log Rate Font Color = IF ( [Log Rate Governor Wait (s)] > 0, "#FFB020", "#F2F2F5" )

// The text twin of those colors, so color is never the only signal.
Target Attention Signals =
VAR Parts =
    {
        IF ( [CPU Peak (%)] >= 80, "▲ CPU" ),
        IF ( [Blocked Processes (peak)] > 0, "▲ Blocking" ),
        IF ( [Buffer IO Wait (s)] >= 1, "▲ Buffer IO" ),
        IF ( [Log Rate Governor Wait (s)] > 0, "▲ Log rate" )
    }
VAR Result = CONCATENATEX ( FILTER ( Parts, NOT ISBLANK ( [Value] ) ), [Value], "  " )
RETURN IF ( Result = "", "None", Result )

// Freshness. The history tile ignores the period slicer.
Latest Capture UTC =
CALCULATE (
    MAX (
        MAX ( 'Telemetry Snapshots'[Captured At UTC] ),
        MAX ( MAX ( 'Analysis Findings'[Captured At UTC] ), MAX ( 'Validation Results'[Checked At UTC] ) )
    ),
    REMOVEFILTERS ( 'Date' )
)

Hours Since Latest Capture =
VAR Latest = [Latest Capture UTC]
RETURN IF ( NOT ISBLANK ( Latest ), DIVIDE ( DATEDIFF ( Latest, UTCNOW (), MINUTE ), 60 ) )

History Freshness Status =
VAR Hours = [Hours Since Latest Capture]
RETURN SWITCH ( TRUE (), ISBLANK ( Hours ), "Manual action required", Hours > 24, "Warning", "Pass" )

History Freshness Rail Color =
SWITCH ( [History Freshness Status], "Manual action required", "#8CEEEE", "Warning", "#FFB020", "#2A2A3A" )

History Freshness Label =
IF (
    ISBLANK ( [Latest Capture UTC] ),
    "No snapshot yet: run NB_DatabaseHub_LiveActivity",
    "Latest snapshot " & FORMAT ( [Latest Capture UTC], "yyyy-mm-dd hh:nn" ) & " UTC  ·  "
        & FORMAT ( [Hours Since Latest Capture], "0.0" ) & " h ago"
)

Notebook Runs Captured = CALCULATE ( DISTINCTCOUNT ( 'Telemetry Snapshots'[Run ID] ), REMOVEFILTERS ( 'Date' ) )

// Hidden. Drives every empty state.
Has Telemetry Bins =
IF (
    CALCULATE (
        COUNTROWS ( 'Telemetry Snapshots' ),
        REMOVEFILTERS (),
        'Telemetry Snapshots'[Analysis Key] IN { "cpu", "gauges", "wait_deltas", "counter_deltas", "sessions", "storage_io" }
    ) > 0,
    1,
    0
)

// Coverage from the deployment notebook's run that the readiness page selects.
Coverage Tables (selected run) =
VAR RunId = [Selected Validation Run]
RETURN
    CALCULATE (
        DISTINCTCOUNT ( 'Telemetry Snapshots'[Metric] ),
        KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "telemetry_coverage" ),
        KEEPFILTERS ( RIGHT ( 'Telemetry Snapshots'[Metric], 5 ) = ".rows" ),
        TREATAS ( { RunId }, 'Telemetry Snapshots'[Run ID] ),
        REMOVEFILTERS ( 'Date' )
    )

Coverage Last Sample Age (min) =
VAR RunId = [Selected Validation Run]
VAR Scope =
    CALCULATETABLE (
        'Telemetry Snapshots',
        KEEPFILTERS ( 'Telemetry Snapshots'[Analysis Key] = "telemetry_coverage" ),
        TREATAS ( { RunId }, 'Telemetry Snapshots'[Run ID] ),
        REMOVEFILTERS ( 'Date' )
    )
VAR LastSample = MAXX ( Scope, 'Telemetry Snapshots'[Bucket UTC] )
VAR WindowEnd = MAXX ( Scope, 'Telemetry Snapshots'[Window End UTC] )
RETURN IF ( NOT ISBLANK ( LastSample ), DATEDIFF ( LastSample, WindowEnd, SECOND ) / 60 )

// 15 minutes matches the deployment notebook's freshness rule for HUB.TELEMETRY checks.
Coverage Attention =
VAR Age = [Coverage Last Sample Age (min)]
RETURN SWITCH ( TRUE (), ISBLANK ( Age ), "○ Not captured", Age > 15, "▲ Stale", "✓ Fresh" )

Coverage Font Color = IF ( [Coverage Last Sample Age (min)] > 15, "#FFB020", "#8C8C9C" )
```

Analysis Findings, Validation Results, and Scenario Runs:

```dax
// Analysis Findings. Format #,0 unless noted.
Findings = COUNTROWS ( 'Analysis Findings' )

// Counts finding IDs whose most recent capture has a status that needs attention.
Findings Needing Attention =
SUMX (
    VALUES ( 'Analysis Findings'[Finding ID] ),
    VAR LatestCapture = CALCULATE ( MAX ( 'Analysis Findings'[Captured At UTC] ) )
    RETURN
        MAXX (
            CALCULATETABLE ( 'Analysis Findings', 'Analysis Findings'[Captured At UTC] = LatestCapture ),
            RELATED ( 'Status'[Needs Attention Flag] )
        )
)

// Hidden. 1 = Fail, 2 = Manual action required, 3 = Warning, 4 to 6 need no attention.
Worst Finding Status Sort =
MINX (
    VALUES ( 'Analysis Findings'[Finding ID] ),
    VAR LatestCapture = CALCULATE ( MAX ( 'Analysis Findings'[Captured At UTC] ) )
    RETURN
        MINX (
            CALCULATETABLE ( 'Analysis Findings', 'Analysis Findings'[Captured At UTC] = LatestCapture ),
            RELATED ( 'Status'[Status Sort] )
        )
)

// Hidden. The signature: a rail lights up only for attention statuses.
Target Rail Color =
SWITCH ( [Worst Finding Status Sort], 1, "#FF4D5A", 2, "#8CEEEE", 3, "#FFB020", "#2A2A3A" )

// Hidden. Visual filter for the open-findings queue: 1 when the row is its finding's latest capture.
Is Latest Finding Capture =
VAR ThisCapture = MAX ( 'Analysis Findings'[Captured At UTC] )
VAR LatestForIds =
    MAXX (
        VALUES ( 'Analysis Findings'[Finding ID] ),
        CALCULATE (
            MAX ( 'Analysis Findings'[Captured At UTC] ),
            ALLEXCEPT ( 'Analysis Findings', 'Analysis Findings'[Finding ID], 'Date'[Date] )
        )
    )
RETURN IF ( ThisCapture = LatestForIds, 1, 0 )

// Hidden. Visual filter for the incident page's evidence table.
Finding In Focus Window =
VAR TargetKey = [Focus Target Key]
VAR RangeStart = [Focus Range Start UTC]
VAR RangeEnd = [Focus Range End UTC]
RETURN
    IF (
        CALCULATE (
            COUNTROWS ( 'Analysis Findings' ),
            KEEPFILTERS ( 'Analysis Findings'[Target Key] = TargetKey ),
            KEEPFILTERS ( 'Analysis Findings'[Window Start UTC] <= RangeEnd ),
            KEEPFILTERS ( 'Analysis Findings'[Window End UTC] >= RangeStart )
        ) > 0,
        1,
        0
    )

Blocking Incidents =
CALCULATE (
    DISTINCTCOUNT ( 'Analysis Findings'[Finding ID] ),
    KEEPFILTERS ( 'Analysis Findings'[Analysis Key] = "blocking" ),
    KEEPFILTERS ( NOT CONTAINSSTRING ( 'Analysis Findings'[Finding ID], ".deadlocks" ) )
)

Estate Headline =
VAR Reporting = [Targets Reporting]
VAR Attention = [Findings Needing Attention] + 0
RETURN
    IF (
        [Has Telemetry Bins] = 0,
        "No telemetry history yet: run NB_DatabaseHub_LiveActivity to start the estate's history",
        FORMAT ( Reporting, "0" ) & " of 3 SQL targets sent telemetry in this period; "
            & FORMAT ( Attention, "0" ) & IF ( Attention = 1, " finding needs", " findings need" ) & " attention"
    )

// Validation Results. Run IDs start with the run's UTC start (yyyymmddThhmmssZ), so MAX is the latest run.
// Hidden.
Selected Validation Run =
CALCULATE ( MAX ( 'Validation Results'[Run ID] ), REMOVEFILTERS ( 'Status' ), REMOVEFILTERS ( 'Target' ) )

// Hidden. Visual filter for the check queue.
Is Selected Validation Run =
VAR SelectedRun = CALCULATE ( [Selected Validation Run], ALLSELECTED ( 'Validation Results' ) )
RETURN
    IF ( CALCULATE ( COUNTROWS ( 'Validation Results' ), KEEPFILTERS ( 'Validation Results'[Run ID] = SelectedRun ) ) > 0, 1, 0 )

Checks (selected run) =
VAR SelectedRun = [Selected Validation Run]
RETURN CALCULATE ( COUNTROWS ( 'Validation Results' ), 'Validation Results'[Run ID] = SelectedRun )

Checks Failed (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Status] = "Fail" ) )
Checks Needing a Manual Step (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Status] = "Manual action required" ) )
Checks With Warnings (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Status] = "Warning" ) )
Checks Passed (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Status] = "Pass" ) )
Checks Not Supported (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Status] = "Not supported" ) )
Checks Not Selected (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Status] = "Not selected" ) )
Checks Needing Attention (selected run) = CALCULATE ( [Checks (selected run)], KEEPFILTERS ( 'Status'[Needs Attention] = "Yes" ) )

Checks Context = "of " & FORMAT ( [Checks (selected run)] + 0, "0" ) & " checks in the selected run"

// Format 0%. Pass share of the checks that apply and were selected.
Readiness (%) =
DIVIDE (
    [Checks Passed (selected run)],
    [Checks (selected run)] - [Checks Not Supported (selected run)] - [Checks Not Selected (selected run)]
)

// Hidden rail colors for the readiness strip and the estate's readiness tile.
Fail Rail Color = IF ( [Checks Failed (selected run)] > 0, "#FF4D5A", "#2A2A3A" )
Manual Rail Color = IF ( [Checks Needing a Manual Step (selected run)] > 0, "#8CEEEE", "#2A2A3A" )
Warning Rail Color = IF ( [Checks With Warnings (selected run)] > 0, "#FFB020", "#2A2A3A" )
Readiness Rail Color =
SWITCH (
    TRUE (),
    [Checks Failed (selected run)] > 0, "#FF4D5A",
    [Checks Needing a Manual Step (selected run)] > 0, "#8CEEEE",
    [Checks With Warnings (selected run)] > 0, "#FFB020",
    "#2A2A3A"
)

Readiness Headline =
IF (
    [Checks (selected run)] + 0 = 0,
    "No validation run in the lakehouse yet: run NB_DatabaseHub_Deployment",
    FORMAT ( [Checks (selected run)], "0" ) & " checks: "
        & FORMAT ( [Checks Failed (selected run)] + 0, "0" ) & " failed, "
        & FORMAT ( [Checks Needing a Manual Step (selected run)] + 0, "0" ) & " manual steps, "
        & FORMAT ( [Checks With Warnings (selected run)] + 0, "0" ) & " warnings"
)

Validation Run Label =
VAR SelectedRun = [Selected Validation Run]
VAR Started = CALCULATE ( MIN ( 'Validation Results'[Checked At UTC] ), 'Validation Results'[Run ID] = SelectedRun )
RETURN IF ( NOT ISBLANK ( Started ), "Run started " & FORMAT ( Started, "yyyy-mm-dd hh:nn" ) & " UTC" )

// Heat strip: worst status per area and run.
Worst Check Status Sort = MINX ( 'Validation Results', RELATED ( 'Status'[Status Sort] ) )

Worst Check Status Glyph =
VAR S = [Worst Check Status Sort]
RETURN
    IF (
        NOT ISBLANK ( S ),
        LOOKUPVALUE ( 'Status'[Status Glyph], 'Status'[Status Sort], S ) & " "
            & LOOKUPVALUE ( 'Status'[Status Short], 'Status'[Status Sort], S )
    )

Worst Check Status Color = SWITCH ( [Worst Check Status Sort], 1, "#FF4D5A", 2, "#8CEEEE", 3, "#FFB020", "#8C8C9C" )

// Top-N helper for the heat strip's latest six runs.
Run Start UTC = MIN ( 'Validation Results'[Checked At UTC] )

// Scenario Runs.
Scenario Requests = CALCULATE ( COUNTROWS ( 'Scenario Runs' ), REMOVEFILTERS ( 'Date' ) )
```

Incident Windows (the incident page; "focus" is the selected incident, or the latest one in context):

```dax
Incidents = COUNTROWS ( 'Incident Windows' )

// Hidden. TRUE when the bin in context lies inside an incident window of the targets in context.
In Incident Window =
VAR B = SELECTEDVALUE ( 'Telemetry Snapshots'[Bucket UTC] )
RETURN
    NOT ISBLANK ( B )
        && CALCULATE (
            COUNTROWS ( 'Incident Windows' ),
            'Incident Windows'[Window Start UTC] <= B,
            'Incident Windows'[Window End UTC] > B
        ) > 0

// Hidden. The picker's selection, or the latest window in context (a drillthrough target narrows it).
Focus Incident Key =
IF (
    HASONEVALUE ( 'Incident Windows'[Incident Key] ),
    SELECTEDVALUE ( 'Incident Windows'[Incident Key] ),
    MAXX (
        TOPN ( 1, 'Incident Windows', 'Incident Windows'[Window Start UTC], DESC, 'Incident Windows'[Incident Key], DESC ),
        'Incident Windows'[Incident Key]
    )
)

Has Incident = IF ( NOT ISBLANK ( [Focus Incident Key] ), 1, 0 )

// Hidden lookups of the focus incident. The same pattern returns Window Start UTC, Window End UTC,
// Signal Family, Source, Scenario, and Correlation Status Key as Focus Window Start UTC, Focus Window End UTC,
// Focus Signal Family, Focus Source, Focus Scenario, and Focus Correlation Status.
Focus Target Key =
VAR K = [Focus Incident Key]
RETURN CALCULATE ( MAX ( 'Incident Windows'[Target Key] ), REMOVEFILTERS ( 'Incident Windows' ), 'Incident Windows'[Incident Key] = K )

// Hidden. The window padded by 15 minutes (TELEMETRY_LAG_MINUTES), or the latest analysis window without an incident.
Focus Range Start UTC =
IF (
    [Has Incident] = 1,
    [Focus Window Start UTC] - 15 / 1440,
    CALCULATE ( MAX ( 'Telemetry Snapshots'[Window Start UTC] ), REMOVEFILTERS (), 'Telemetry Snapshots'[Analysis Key] = "cpu" )
)

Focus Range End UTC =
IF (
    [Has Incident] = 1,
    [Focus Window End UTC] + 15 / 1440,
    CALCULATE ( MAX ( 'Telemetry Snapshots'[Window End UTC] ), REMOVEFILTERS (), 'Telemetry Snapshots'[Analysis Key] = "cpu" )
)

// Hidden. The incident's own signal; batch requests stand in when there's no incident.
Focus Signal Raw =
SWITCH (
    [Focus Signal Family],
    "blocking", [Blocked Processes (peak)],
    "cpu", [CPU (%)],
    "io", [Buffer IO Wait (s)],
    "log_rate", [Log Rate Governor Wait (s)],
    [Batch Requests]
)

// Format string definition: SWITCH ( [Focus Signal Family], "cpu", "#,0.0"" %""", "blocking", "#,0", "io", "#,0.0", "log_rate", "#,0.0", "#,0" )
Focus Signal Value =
VAR TargetKey = [Focus Target Key]
VAR RangeStart = [Focus Range Start UTC]
VAR RangeEnd = [Focus Range End UTC]
RETURN
    IF (
        ISBLANK ( TargetKey ),
        CALCULATE (
            [Focus Signal Raw],
            KEEPFILTERS ( 'Telemetry Snapshots'[Bucket UTC] >= RangeStart ),
            KEEPFILTERS ( 'Telemetry Snapshots'[Bucket UTC] <= RangeEnd )
        ),
        CALCULATE (
            [Focus Signal Raw],
            KEEPFILTERS ( TREATAS ( { TargetKey }, 'Target'[Target Key] ) ),
            KEEPFILTERS ( 'Telemetry Snapshots'[Bucket UTC] >= RangeStart ),
            KEEPFILTERS ( 'Telemetry Snapshots'[Bucket UTC] <= RangeEnd )
        )
    )

// Hidden. Height of the shaded band: the highest point in the padded range.
Focus Range Peak =
VAR RangeStart = [Focus Range Start UTC]
VAR RangeEnd = [Focus Range End UTC]
RETURN
    CALCULATE (
        MAXX ( VALUES ( 'Telemetry Snapshots'[Bucket UTC] ), [Focus Signal Value] ),
        REMOVEFILTERS ( 'Telemetry Snapshots'[Bucket UTC] ),
        'Telemetry Snapshots'[Bucket UTC] >= RangeStart,
        'Telemetry Snapshots'[Bucket UTC] <= RangeEnd
    )

Focus Window Band =
VAR B = SELECTEDVALUE ( 'Telemetry Snapshots'[Bucket UTC] )
RETURN
    IF ( NOT ISBLANK ( B ) && B >= [Focus Window Start UTC] && B < [Focus Window End UTC], [Focus Range Peak] )

Focus Peak =
VAR WindowStart = [Focus Window Start UTC]
VAR WindowEnd = [Focus Window End UTC]
RETURN
    CALCULATE (
        MAXX ( VALUES ( 'Telemetry Snapshots'[Bucket UTC] ), [Focus Signal Value] ),
        REMOVEFILTERS ( 'Telemetry Snapshots'[Bucket UTC] ),
        'Telemetry Snapshots'[Bucket UTC] >= WindowStart,
        'Telemetry Snapshots'[Bucket UTC] < WindowEnd
    )

// A markers-only series: one labeled point at the peak.
Focus Peak Point =
VAR B = SELECTEDVALUE ( 'Telemetry Snapshots'[Bucket UTC] )
VAR V = [Focus Signal Value]
RETURN
    IF (
        NOT ISBLANK ( B ) && NOT ISBLANK ( V ) && V = [Focus Peak]
            && B >= [Focus Window Start UTC] && B < [Focus Window End UTC],
        V
    )

// Average of the 15 minutes before the window.
Focus Baseline =
VAR WindowStart = [Focus Window Start UTC]
RETURN
    IF (
        NOT ISBLANK ( WindowStart ),
        CALCULATE (
            AVERAGEX (
                FILTER ( VALUES ( 'Telemetry Snapshots'[Bucket UTC] ), NOT ISBLANK ( [Focus Signal Value] ) ),
                [Focus Signal Value]
            ),
            REMOVEFILTERS ( 'Telemetry Snapshots'[Bucket UTC] ),
            'Telemetry Snapshots'[Bucket UTC] >= WindowStart - 15 / 1440,
            'Telemetry Snapshots'[Bucket UTC] < WindowStart
        )
    )

Focus Threshold = IF ( [Focus Signal Family] = "cpu", 80 )

Focus Duration (min) = DATEDIFF ( [Focus Window Start UTC], [Focus Window End UTC], MINUTE )

// Hidden text helpers.
Focus Signal Label =
IF (
    [Has Incident] = 0,
    "Batch requests",
    SWITCH ( [Focus Signal Family], "blocking", "Blocking", "cpu", "CPU pressure", "io", "IO pressure", "log_rate", "Log-rate pressure", "Activity" )
)

Focus Peak Label =
VAR P = [Focus Peak]
RETURN
    SWITCH (
        [Focus Signal Family],
        "blocking", FORMAT ( P, "0" ) & " blocked processes",
        "cpu", FORMAT ( P, "0.0" ) & " % CPU",
        "io", FORMAT ( P, "0.0" ) & " s of Buffer IO waits per bin",
        "log_rate", FORMAT ( P, "0.0" ) & " s of Log Rate Governor waits per bin",
        FORMAT ( P, "#,0" ) & " batch requests per bin"
    )

Focus Resource Name =
VAR TargetKey = [Focus Target Key]
RETURN
    CALCULATE (
        MAX ( 'Telemetry Snapshots'[Resource Name] ),
        REMOVEFILTERS (),
        'Telemetry Snapshots'[Target Key] = TargetKey,
        'Telemetry Snapshots'[Analysis Key] = "cpu"
    )

Focus Evidence Sentence =
SWITCH (
    [Focus Source],
    "Recorded request",
        "The notebook requested this run (" & [Focus Scenario] & "), and the expected-signal check says " & [Focus Correlation Status] & ".",
    "Detected signal",
        "The telemetry itself shows this window; no notebook request covers it, so it likely came from PowerShell, GitHub Actions, or the business-day profile.",
    ""
)

// Verdict tile.
Focus Verdict = IF ( [Has Incident] = 0, "Not selected", [Focus Correlation Status] )

Focus Verdict Rail Color =
SWITCH ( [Focus Verdict], "Fail", "#FF4D5A", "Manual action required", "#8CEEEE", "Warning", "#FFB020", "#2A2A3A" )

Focus Peak Delta Label =
VAR Peak = [Focus Peak]
RETURN IF ( NOT ISBLANK ( Peak ), FORMAT ( Peak - [Focus Baseline], "+#,0.0;-#,0.0;0" ) & " vs the 15 minutes before" )

// Page title, callout, and alt text.
Incident Headline =
SWITCH (
    TRUE (),
    [Has Telemetry Bins] = 0, "No telemetry history yet: run NB_DatabaseHub_LiveActivity to capture an analysis window",
    [Has Incident] = 0, "No incident captured yet: the estate's baseline, minute by minute",
    [Focus Signal Label] & " on " & [Focus Target Key] & " peaked at " & [Focus Peak Label] & ", "
        & FORMAT ( [Focus Window Start UTC], "d mmm hh:nn" ) & "–" & FORMAT ( [Focus Window End UTC], "hh:nn" ) & " UTC"
)

Incident Narrative =
SWITCH (
    TRUE (),
    [Has Telemetry Bins] = 0,
        "Run NB_DatabaseHub_LiveActivity (Run all is safe). It saves telemetry snapshots and incident windows to LH_DatabaseHub, and this page reads them. The live views stay in Database Hub and the Real-Time Dashboard.",
    [Has Incident] = 0,
        "No incident window is in the lakehouse yet. Start one, for example ./scripts/demo-control.ps1 -Target T1 -Scenario incident:locking-blocking -Duration 15, wait 15 minutes for the telemetry, then run NB_DatabaseHub_LiveActivity. Until then, this chart shows the latest healthy baseline.",
    "What happened: " & [Focus Signal Label] & " on " & [Focus Target Key] & " rose from " & FORMAT ( [Focus Baseline], "#,0.#" )
        & " in the 15 minutes before to " & [Focus Peak Label] & ", for " & FORMAT ( [Focus Duration (min)], "0" ) & " minutes. "
        & "Evidence: " & [Focus Evidence Sentence] & " "
        & "Next: in Database Hub, ask the Database Agent ""Investigate what happened on " & [Focus Resource Name] & " between "
        & FORMAT ( [Focus Window Start UTC], "hh:nn" ) & " and " & FORMAT ( [Focus Window End UTC], "hh:nn" ) & " UTC."""
)

Incident Timeline Alt Text =
IF (
    [Has Incident] = 0,
    "Line chart of batch requests per bin for the latest analysis window; no incident window is recorded yet.",
    "Line chart of " & [Focus Signal Label] & " per bin on " & [Focus Target Key] & " from " & FORMAT ( [Focus Range Start UTC], "hh:nn" )
        & " to " & FORMAT ( [Focus Range End UTC], "hh:nn" ) & " UTC. The shaded band is the incident window; the peak is " & [Focus Peak Label] & "."
)
```

### Incident windows

The incident page needs one row per incident window. Lakehouse `scenario_runs` holds only notebook-dispatched requests, and Fabric can't reach SQL `demo.scenario_runs` on the private targets. The options:

| Option | How | Covers | Verdict |
|---|---|---|---|
| A. Derive in the live-activity notebook | Recorded requests from `scenario_runs`, plus detected signal episodes from the frames the notebook already queries, merged into a new `incident_windows` table | Every target and every start path, whenever the incident's signal appears | **Recommended.** A small notebook change; no new interface, no new KQL |
| B. Copy the runner's records | An operator-side step exports `demo.scenario_runs` (`ContosoCare.Workload status --json --runs 100`, which `status.ps1` already runs through Run Command) and uploads it to `LH_DatabaseHub/Files/run-records/` through OneLake's ADLS Gen2-compatible API ([How do I connect to OneLake?](https://learn.microsoft.com/fabric/onelake/onelake-access-api)); the notebook merges it | Exact start, deadline, stop, and outcome on all three targets, including runs whose signal never appeared | Optional later; see open decision 3. Adds a OneLake write path from PowerShell and a step after each demo |
| C. Recorded requests only | No change | Notebook-dispatched runs only | Rejected: most demos start incidents from PowerShell, so the page would stay empty |
| D. Runner sessions in telemetry | `SqlServerClientConnections.ProgramName` carries the runner's `ContosoCare.Demo/<scenario>/<run>` tag | T1 and T2 only | Rejected: the table is an hourly sample of current sessions, so a run whose sessions closed before the sample never appears, and Azure SQL Database isn't collected ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)) |

Notebook changes for option A (Phase 19 implements them):

1. **Base.** Merge the Phase 12 tip (`0d8b4a6`) into the Phase 19 branch before editing the notebooks.
2. **Report date (both notebooks).** Add `("report_date_utc", "date")` to every `TABLE_COLUMNS` entry, map `"date"` to `DateType()` in `_struct()`, and set the value in `write_delta()` from the first non-null primary time below. Write with `frame.coalesce(1)`, one Parquet file per write.

   ```python
   REPORT_DATE_SOURCES = {
       "validation_results": ("timestamp_utc",),
       "scenario_runs": ("window_start_utc", "requested_at_utc"),
       "telemetry_snapshots": ("bucket_utc", "window_end_utc", "captured_at_utc"),
       "analysis_findings": ("window_start_utc", "captured_at_utc"),
       "incident_windows": ("window_start_utc",),
   }


   def _utc_date(value):
       """UTC calendar date of a timestamp; naive values are already UTC."""
       if value is None:
           return None
       stamp = pd.Timestamp(value)
       return (stamp.tz_convert("UTC") if stamp.tzinfo is not None else stamp).date()
   ```

3. **Report tables (live-activity notebook).** A new helper, `prepare_report_tables()` in helpers part 3, runs from the section 11 persist cell after the two `write_delta` calls, only when `SAVE_RESULTS = True`. It changes lakehouse data only:
   - `CREATE TABLE IF NOT EXISTS` for all five tables with their `TABLE_COLUMNS` schemas, so the model can frame before the first incident.
   - For any table without `report_date_utc`: `ALTER TABLE <table> ADD COLUMNS (report_date_utc DATE)`, then a one-time backfill, `UPDATE <table> SET report_date_utc = to_date(coalesce(<sources>)) WHERE report_date_utc IS NULL`, over the same source columns.
   - Builds and merges incident windows (step 4).
   - `OPTIMIZE` any of the five tables whose `DESCRIBE DETAIL` reports more than 200 files, far below the F16 guardrail of 1,000.
4. **Incident windows.** A new Delta table `incident_windows` with 18 columns: `incident_key`, `incident_label`, `incident_sort` (long), `source`, `target`, `scenario`, `signal_family`, `request_id`, `window_start_utc`, `window_end_utc`, `duration_minutes` (double), `peak_value` (double), `peak_unit`, `correlation_status`, `correlation_evidence` (JSON, redacted), `run_id`, `captured_at_utc`, and `report_date_utc`.
   - **Recorded request:** each `scenario_windows()` row whose profile starts with `incident:` and whose status isn't Fail. Key `request:<request_id>`; `signal_family` is the first of `expected_signals(profile)`; `correlation_status` and `correlation_evidence` come from that window's section 8 correlation finding. Merged on `incident_key`.
   - **Detected signal:** a new helper, `signal_episodes(series, threshold, bin_minutes, min_bins)`, generalizes `blocking_incidents()` (consecutive bins above a threshold, per target) and runs over the frames already in `FRAMES`: blocked processes above 0 (one bin), CPU at or above `EPISODE_CPU_PERCENT` (80, two bins; T3 is a percentage of the tier limit), Buffer IO (`PAGEIOLATCH`) waits at or above `EPISODE_PAGEIOLATCH_SECONDS` (1 s per bin, two bins), and Log Rate Governor waits above 0 (one bin). The constants go in the parameters cell, with `EPISODE_MIN_BINS = 2`. An episode that overlaps a recorded window on the same target, within `TELEMETRY_LAG_MINUTES`, and matches one of its expected signals becomes evidence for that window instead of a row. Otherwise it's a row with key `detected:<target>:<family>:<yyyymmddThhmm>` and `correlation_status` Pass, because the signal is what was observed. Before merging, the helper reads stored detected rows that overlap the analysis window and unions overlapping or touching intervals per target and family, keeping the earliest stored key, so a re-run never duplicates an episode. Merged on `incident_key`.
   - `incident_label` reads like `2026-10-21 14:05 UTC · T1 · Blocking (detected)` or `2026-10-21 14:05 UTC · T1 · Blocking (locking-blocking, requested)`, and `incident_sort` is the negative epoch minute of the start, so the picker lists the newest first. Thresholds are presenter heuristics, not product behavior, as in ADR 0014.
5. **Scenario catalog.** Add `resource-governance` (signal `cpu`) and `log-rate-pressure` (signal `log_rate`), both defaulting to T3, to `KNOWN_SCENARIOS`, `SCENARIO_SIGNALS`, and `SCENARIO_DEFAULT_TARGET`, matching `scenarios/` and the business-day profile.
6. **Cleanup.** The deployment notebook's purge cell adds `incident_windows` to `DEMO_TABLES` and prints that the semantic model can't refresh until the live-activity notebook recreates the tables.
7. **Tests and docs.** `tests/unit/Fabric.Notebooks.Tests.ps1` asserts the new table, the `report_date_utc` column in every schema, single-file writes, and the detection defaults; `fabric/README.md` lists the fifth table and the column.

### Creation path

- Semantic model: [Items - Create Semantic Model](https://learn.microsoft.com/rest/api/fabric/semanticmodel/items/create-semantic-model), `POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/semanticModels`, with a TMDL definition as described in [SemanticModel definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/semantic-model-definition): `definition.pbism` plus `definition/` (`database.tmdl`, `model.tmdl`, `expressions.tmdl`, `relationships.tmdl`, `tables/*.tmdl`). Contributor role; a [long-running operation](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation). Later changes use Update Semantic Model Definition with every part.
- First refresh: [Datasets - Refresh Dataset In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group), polled to completion; Direct Lake tables created through the API stay unprocessed until then.
- Measure validation: [Datasets - Execute Queries In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group) with `EVALUATE` queries per measure and `INFO.MEASURES()` for errors.
- Report: [Items - Create Report](https://learn.microsoft.com/rest/api/fabric/report/items/create-report), `POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/reports`, with a PBIR definition as described in [Report definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/report-definition): `definition.pbir` (`byConnection`, `semanticmodelid=`), `definition/` parts, and the registered theme under `StaticResources/`.
- IDs: the script resolves the workspace, lakehouse, model, report, and dashboard IDs at run time ([Items - List Items](https://learn.microsoft.com/rest/api/fabric/core/items/list-items)) or reads them from the Git-ignored `config/demo.config.json`; no real ID is committed.

## Canonical design contract

The block below is the design contract from `powerbi-report-design`. It's authoritative for implementation; the surrounding prose is context.

```yaml
Design Brief:
  generated_by: powerbi-report-design
  contract_version: 1
  mode: greenfield
  report: RPT_DatabaseHub_History
  semantic_model: SM_DatabaseHub_History
  design_identity:
    tone: "Industrial Cockpit, dark: near-black graphite canvas, white Segoe UI numbers, greyscale data ink, and color only where something needs attention"
    signature: "Attention-lit status rails: every status-bearing element sits on graphite with a 4 px left rail and a glyph that light up only for Fail (red ✕), Manual action required (cyan ⚑), or Warning (amber ▲); Pass, Not supported, and Not selected stay graphite, and one indigo band marks incident windows"
    tone_downstream:
      surface: "#0E0E10 page, #17171C visual containers, #1F1F26 raised surfaces and table headers"
      typography: "Segoe UI Semibold 24 pt page titles, Segoe UI Semibold 13 pt visual titles, Segoe UI Bold 32 pt KPI values, Segoe UI 10 pt body; ratio 1.333"
      density: "Perfect Fourth ramp, 24 px gutters, 8 px snap, dense lower rows"
      gridlines: "Dotted #3A3A4A on value axes only"
      borders: "1 px #2A2A3A, radius 4; group with background fill, not boxes"
      iconography: "Filled geometric status glyphs: ✕ ⚑ ▲ ✓ ⊘ ○"
  archetype: Operational Monitor
  composition: "Ops + Detail: Operational Monitor A landing, Narrative Story C incident, Analytical Canvas A explorer, Operational Monitor C readiness"
  history_label: "Every page subtitle states that the report is history from lakehouse snapshots and that the live view is Database Hub plus the Real-Time Dashboard"
  color_map:
    - measure: "'Telemetry Snapshots'[CPU (%)]"
      color: "#E6E6EE"
      tint: "#3A3A48"
      role: "Neutral data ink for CPU on every page"
    - measure: "'Telemetry Snapshots'[CPU In Incident Window]"
      color: "#5772D9"
      tint: "#232A45"
      role: "The same CPU series, drawn only inside incident windows"
    - measure: "'Telemetry Snapshots'[Signal Value]"
      color: "#E6E6EE"
      tint: "#3A3A48"
      role: "Neutral data ink for the explorer's selected signal"
    - measure: "'Telemetry Snapshots'[Signal Value In Incident Window]"
      color: "#5772D9"
      tint: "#232A45"
      role: "The selected signal inside incident windows"
    - measure: "'Incident Windows'[Focus Signal Value]"
      color: "#E6E6EE"
      tint: "#3A3A48"
      role: "The incident's signal, minute by minute"
    - measure: "'Incident Windows'[Focus Window Band]"
      color: "#5772D9"
      tint: "#232A45"
      role: "Shaded incident window at 70 % transparency"
    - measure: "'Incident Windows'[Focus Peak Point]"
      color: "#F2F2F5"
      tint: "#F2F2F5"
      role: "One labeled peak marker"
    - measure: "'Telemetry Snapshots'[Wait Time (s)]"
      color: "#B4B4C2"
      tint: "#4A4A58"
      role: "Neutral bars; a signature category above 10 % of wait time switches to Warning amber"
    - measure: "'Telemetry Snapshots'[Batch Requests]"
      color: "#B4B4C2"
      tint: "#4A4A58"
      role: "Scatter x-axis; points take their target's lightness"
    - measure: "'Validation Results'[Checks Failed (selected run)]"
      color: "#FF4D5A"
      tint: "#2A2A3A"
      role: "Rail lit only when the count is above zero"
    - measure: "'Validation Results'[Checks Needing a Manual Step (selected run)]"
      color: "#8CEEEE"
      tint: "#2A2A3A"
      role: "Rail lit only when the count is above zero"
    - measure: "'Validation Results'[Checks With Warnings (selected run)]"
      color: "#FFB020"
      tint: "#2A2A3A"
      role: "Rail lit only when the count is above zero"
    - measure: "'Validation Results'[Readiness (%)]"
      color: "#F2F2F5"
      tint: "#2A2A3A"
      role: "Neutral: readiness never turns green"
  status_colors:
    source: "'Status'[Status Color] and 'Status'[Status Glyph]"
    Fail: { color: "#FF4D5A", glyph: "✕", rail: lit }
    Manual action required: { color: "#8CEEEE", glyph: "⚑", rail: lit }
    Warning: { color: "#FFB020", glyph: "▲", rail: lit }
    Pass: { color: "#8C8C9C", glyph: "✓", rail: unlit }
    Not supported: { color: "#8C8C9C", glyph: "⊘", rail: unlit }
    Not selected: { color: "#8C8C9C", glyph: "○", rail: unlit }
    unlit_rail: "#2A2A3A"
    chip_text: "#0E0E10 on attention fills"
  target_identity: "Position (fixed T1, T2, T3 order and small-multiple panels), labels, lightness #E6E6EE, #A0A0B0, and #6C6C80, and marker shape circle, square, and triangle; never hue"
  pages:
    - name: "Estate at a glance"
      display_name: "1 · Estate at a glance"
      role: landing
      archetype: Operational
      archetype_name: Operational Monitor
      layout_variant: A
      variant_rationale: "Desk viewing on a shared screen with per-target status, one shared time axis, and an exception queue is the 4-Up Status signal; the geo or topology zone becomes a target health matrix because the three targets have no meaningful geography."
      page_background: "#0E0E10"
      layout_summary: "Title and history period in the header band; five attention-lit tiles; CPU per target over time with incident windows in indigo; the open-findings queue and the target health matrix side by side."
      layout_contract:
        canvas: { width: 1920, height: 1080, margin: 32, gutter: 24, snap: 8 }
        grid:
          columns: 12
          rows: 12
          regions:
            header: [1, 1, 10, 2]
            filters: [10, 1, 13, 2]
            kpis: [1, 2, 13, 4]
            hero: [1, 4, 13, 8]
            queue: [1, 8, 7, 13]
            matrix: [7, 8, 13, 13]
        placements:
          - id: page_title
            region: header
            kind: textbox
            text: "Three SQL targets, one history: what each reported and what needs attention"
            text_binding: "'Analysis Findings'[Estate Headline]"
            subtitle: "History from lakehouse snapshots written by the notebooks. Live view: Database Hub and the Real-Time Dashboard. All times UTC."
            purpose: "State the estate's headline before any chart."
          - id: period_slicer
            region: filters
            kind: slicer
            slicer_type: between
            field_bindings: "'Date'[Date]"
            header_text: "History period (UTC)"
            sync_group: history_period
            insight_basis: "Demos span hours to days, so presenters pick an arbitrary date range."
            slot: 1
            of: 1
          - id: tile_t1
            region: kpis
            kind: cardVisual
            slot: 1
            of: 5
            purpose: "Is T1 healthy in this period?"
            label_text: "T1 · SQL Server on Azure VM"
            field_bindings:
              Data: ["'Telemetry Snapshots'[CPU (%)]", "'Telemetry Snapshots'[Blocked Processes (peak)]", "'Analysis Findings'[Findings Needing Attention]"]
              ReferenceLabel: "'Telemetry Snapshots'[Target Tile Context]"
            visual_filters: ["'Target'[Target Key] is T1"]
            accent_bar: "'Analysis Findings'[Target Rail Color]"
            color_strategy: semantic
            insight_basis: "Composite tile: the rail is T1's worst latest finding status and lights only for attention; the values pair average CPU with peak blocking and open findings; the reference label adds peak CPU, blocking incidents, and telemetry lag."
            alt_text: "T1 status for the selected period: average CPU, peak blocked processes, and findings that need attention."
          - id: tile_t2
            region: kpis
            kind: cardVisual
            slot: 2
            of: 5
            purpose: "Is T2 healthy in this period?"
            label_text: "T2 · Arc-enabled SQL Server"
            field_bindings:
              Data: ["'Telemetry Snapshots'[CPU (%)]", "'Telemetry Snapshots'[Blocked Processes (peak)]", "'Analysis Findings'[Findings Needing Attention]"]
              ReferenceLabel: "'Telemetry Snapshots'[Target Tile Context]"
            visual_filters: ["'Target'[Target Key] is T2"]
            accent_bar: "'Analysis Findings'[Target Rail Color]"
            color_strategy: semantic
            insight_basis: "Composite tile: T2's worst latest finding status, average CPU, peak blocking, open findings, and telemetry lag."
            alt_text: "T2 status for the selected period: average CPU, peak blocked processes, and findings that need attention."
          - id: tile_t3
            region: kpis
            kind: cardVisual
            slot: 3
            of: 5
            purpose: "Is T3 healthy in this period?"
            label_text: "T3 · Azure SQL Database"
            field_bindings:
              Data: ["'Telemetry Snapshots'[CPU (%)]", "'Telemetry Snapshots'[Blocked Processes (peak)]", "'Analysis Findings'[Findings Needing Attention]"]
              ReferenceLabel: "'Telemetry Snapshots'[Target Tile Context]"
            visual_filters: ["'Target'[Target Key] is T3"]
            accent_bar: "'Analysis Findings'[Target Rail Color]"
            color_strategy: semantic
            insight_basis: "Composite tile: T3's worst latest finding status, average CPU as a percentage of the tier limit, peak blocking, open findings, and telemetry lag."
            alt_text: "T3 status for the selected period: average CPU as a percentage of the tier limit, peak blocked processes, and findings that need attention."
          - id: tile_readiness
            region: kpis
            kind: cardVisual
            slot: 4
            of: 5
            purpose: "Is the demo ready, according to the latest validation run in this period?"
            label_text: "Readiness"
            field_bindings:
              Data: ["'Validation Results'[Checks Needing Attention (selected run)]", "'Validation Results'[Checks (selected run)]", "'Validation Results'[Readiness (%)]"]
              ReferenceLabel: "'Validation Results'[Validation Run Label]"
            accent_bar: "'Validation Results'[Readiness Rail Color]"
            color_strategy: semantic
            insight_basis: "Composite tile: checks needing attention against all checks, the pass share of applicable checks, and the run's start time; the rail takes the worst attention status."
            alt_text: "Readiness of the latest validation run: checks that need attention, all checks, and the readiness percentage."
            drillthrough_hint: "Readiness checks page holds the detail"
          - id: tile_history
            region: kpis
            kind: cardVisual
            slot: 5
            of: 5
            purpose: "How fresh and how deep is the history?"
            label_text: "History"
            field_bindings:
              Data: ["'Telemetry Snapshots'[Hours Since Latest Capture]", "'Telemetry Snapshots'[Notebook Runs Captured]", "'Scenario Runs'[Scenario Requests]"]
              ReferenceLabel: "'Telemetry Snapshots'[History Freshness Label]"
            accent_bar: "'Telemetry Snapshots'[History Freshness Rail Color]"
            color_strategy: semantic
            insight_basis: "Freshness threshold: the rail turns amber when the latest snapshot is more than 24 hours old, and cyan when there is none; ignores the period slicer."
            alt_text: "History freshness: hours since the latest lakehouse snapshot, notebook runs captured, and scenario requests recorded."
          - id: cpu_by_target
            region: hero
            kind: lineChart
            purpose: "When did each target run hot, and was it inside an incident window?"
            field_bindings:
              Category: "'Telemetry Snapshots'[Bucket UTC]"
              Y: ["'Telemetry Snapshots'[CPU (%)]", "'Telemetry Snapshots'[CPU In Incident Window]"]
              SmallMultiples: "'Target'[Target]"
            visual_filters: ["'Target'[Target Kind] is SQL target"]
            axes: "Continuous UTC time on x; y fixed from 0 to 100 and shared across the three panels"
            reference_lines: ["y = 80, Warning amber #FFB020, dashed, labeled '80 % attention threshold'"]
            series_styles: "CPU (%) 2 px #E6E6EE; CPU In Incident Window 3 px #5772D9; markers off; data labels off"
            sort_policy: natural_order
            color_strategy: measure_match
            drillthrough: "Right-click a panel to drill through on 'Target'[Target] to The incident, minute by minute"
            alt_text: "Line charts of average CPU per bin for T1, T2, and T3 over the selected period, with incident windows highlighted and an 80 % threshold."
          - id: open_findings
            region: queue
            kind: tableEx
            purpose: "Which findings still need attention, worst first?"
            field_bindings: ["'Status'[Status Glyph]", "'Status'[Status]", "'Target'[Target Short]", "'Analysis'[Analysis]", "'Analysis Findings'[Finding]", "'Analysis Findings'[Captured At UTC]"]
            visual_filters: ["'Status'[Needs Attention] is Yes", "'Analysis Findings'[Is Latest Finding Capture] is 1"]
            sort_policy: "value_asc on 'Status'[Status] (sorted by severity), then 'Analysis Findings'[Captured At UTC] descending"
            color_strategy: semantic
            conditional_formatting: "Font color of 'Status'[Status Glyph] from 'Status'[Status Color]; rows stay graphite"
            empty_state: "No finding needs attention in this period."
            alt_text: "Table of findings that need attention, worst status first, with target, analysis, finding, and capture time."
          - id: target_health
            region: matrix
            kind: pivotTable
            purpose: "Which target crossed which attention threshold in this period?"
            field_bindings:
              Rows: "'Target'[Target]"
              Values: ["'Telemetry Snapshots'[CPU (%)]", "'Telemetry Snapshots'[CPU Peak (%)]", "'Telemetry Snapshots'[Blocked Processes (peak)]", "'Telemetry Snapshots'[Buffer IO Wait (s)]", "'Telemetry Snapshots'[Log Rate Governor Wait (s)]", "'Telemetry Snapshots'[Batch Requests]", "'Telemetry Snapshots'[Target Attention Signals]"]
            visual_filters: ["'Target'[Target Kind] is SQL target"]
            sort_policy: "natural_order by 'Target'[Target Sort]"
            color_strategy: semantic
            conditional_formatting: "Font color from CPU Peak Font Color, Blocked Font Color, Buffer IO Font Color, and Log Rate Font Color; Target Attention Signals names every breached threshold in text"
            alt_text: "Matrix of T1, T2, and T3 with average and peak CPU, peak blocking, Buffer IO and Log Rate Governor waits, batch requests, and the thresholds each crossed."
        space_audit:
          content_cell_count: 132
          placed_cell_count: 132
          empty_cell_pct: 0
          unplaced_regions: []
          largest_region: { name: hero, pct_of_content: 36 }
          balance_rationale: "The tile strip takes two rows so each tile shows values plus context; the CPU timeline is the page's hero at 36 % of the content; the queue and the matrix split the lower five rows evenly so both read at full height with no dead band."
    - name: "The incident, minute by minute"
      display_name: "2 · The incident, minute by minute"
      role: detail
      archetype: Narrative
      archetype_name: Narrative Story
      layout_variant: C
      variant_rationale: "One timeline's shape is the whole argument (rise, peak, recovery around the window), so the Annotated-Hero variant carries the story on the chart; the single incident picker is a chapter selector, not exploration, and defaults to the latest incident."
      page_background: "#0E0E10"
      layout_summary: "A thesis title with the incident picker; the annotated timeline across the page; the narrative callout and the verdict tile; the evidence table and Prev/Next buttons."
      drillthrough_fields: ["'Target'[Target]"]
      keep_all_filters: false
      layout_contract:
        canvas: { width: 1920, height: 1080, margin: 32, gutter: 24, snap: 8 }
        grid:
          columns: 12
          rows: 12
          regions:
            header: [1, 1, 10, 2]
            filters: [10, 1, 13, 2]
            hero: [1, 2, 13, 9]
            callout: [1, 9, 8, 11]
            verdict: [8, 9, 13, 11]
            evidence: [1, 11, 11, 13]
            nav: [11, 11, 13, 13]
        placements:
          - id: page_title
            region: header
            kind: textbox
            text: "No incident captured yet: the estate's baseline, minute by minute"
            text_binding: "'Incident Windows'[Incident Headline]"
            subtitle: "History from lakehouse snapshots. The shaded band is the incident window, padded by 15 minutes on each side. Live view: Database Hub and the Real-Time Dashboard. All times UTC."
            purpose: "Give the page's thesis: which signal, which target, how high, and when."
          - id: incident_picker
            region: filters
            kind: slicer
            slicer_type: dropdown
            field_bindings: "'Incident Windows'[Incident]"
            header_text: "Incident (newest first)"
            selection: "Single select; no default selection, which means the latest incident"
            insight_basis: "A chapter selector: the incident list is short and sorted newest first."
            slot: 1
            of: 1
          - id: incident_timeline
            region: hero
            kind: lineClusteredColumnComboChart
            purpose: "When did the incident's signal rise, peak, and recover around its window?"
            field_bindings:
              Category: "'Telemetry Snapshots'[Bucket UTC]"
              ColumnY: "'Incident Windows'[Focus Window Band]"
              LineY: ["'Incident Windows'[Focus Signal Value]", "'Incident Windows'[Focus Peak Point]"]
            axes: "Continuous UTC time on x; one shared y-axis for the band and the lines (secondary axis off), starting at 0"
            series_styles: "Band columns #5772D9 at 70 % transparency, no gap; Focus Signal Value 3 px #E6E6EE; Focus Peak Point markers only, #F2F2F5, with its data label"
            reference_lines: ["y = 'Incident Windows'[Focus Threshold], Warning amber dashed, when the signal has a threshold", "x = 'Incident Windows'[Focus Window Start UTC] and 'Incident Windows'[Focus Window End UTC], #7B93F0 dotted, when the axis accepts measure-bound constant lines"]
            sort_policy: natural_order
            color_strategy: measure_match
            alt_text_binding: "'Incident Windows'[Incident Timeline Alt Text]"
            insight_basis: "Annotation carries the argument: the shaded window, the single labeled peak, and the threshold line."
          - id: incident_narrative
            region: callout
            kind: textbox
            text: "No incident window is in the lakehouse yet. Start one, wait 15 minutes for the telemetry, then run NB_DatabaseHub_LiveActivity."
            text_binding: "'Incident Windows'[Incident Narrative]"
            purpose: "Explain what happened, why it matters, and what to ask the Database Agent next."
            insight_basis: "Dynamic narrative: baseline-to-peak change, duration, the window's source, the expected-signal verdict, and the exact Database Agent prompt for the live Hub."
          - id: incident_verdict
            region: verdict
            kind: cardVisual
            purpose: "Did the expected signal appear, and how far above its baseline did it go?"
            label_text: "Verdict"
            field_bindings:
              Data: ["'Incident Windows'[Focus Verdict]", "'Incident Windows'[Focus Peak Delta Label]", "'Incident Windows'[Focus Duration (min)]"]
            accent_bar: "'Incident Windows'[Focus Verdict Rail Color]"
            color_strategy: semantic
            callout_value_basis: "The correlation verdict (an ADR 0012 status), the peak's change against the 15 minutes before the window, and the window's duration; none of these is plotted as such on the timeline."
            alt_text: "Verdict for the incident: expected-signal status, change of the peak against the baseline, and duration in minutes."
          - id: incident_evidence
            region: evidence
            kind: tableEx
            purpose: "Which findings did the notebook record for this target in this window?"
            field_bindings: ["'Status'[Status Glyph]", "'Status'[Status]", "'Analysis'[Analysis]", "'Analysis Findings'[Finding]", "'Analysis Findings'[Captured At UTC]"]
            visual_filters: ["'Analysis Findings'[Finding In Focus Window] is 1", "Top 4 by 'Analysis Findings'[Captured At UTC]"]
            sort_policy: "value_asc on 'Status'[Status] (severity), then 'Analysis Findings'[Captured At UTC] descending"
            color_strategy: semantic
            conditional_formatting: "Font color of 'Status'[Status Glyph] from 'Status'[Status Color]"
            empty_state: "No finding overlaps this window."
            alt_text: "Up to four findings for the incident's target that overlap its window, worst status first."
          - id: nav_previous
            region: nav
            kind: actionButton
            slot: 1
            of: 2
            text: "← 1 · Estate at a glance"
            action: "Page navigation to Estate at a glance"
            alt_text: "Previous page: Estate at a glance."
          - id: nav_next
            region: nav
            kind: actionButton
            slot: 2
            of: 2
            text: "3 · Signal explorer →"
            action: "Page navigation to Signal explorer"
            alt_text: "Next page: Signal explorer."
        space_audit:
          content_cell_count: 132
          placed_cell_count: 132
          empty_cell_pct: 0
          unplaced_regions: []
          largest_region: { name: hero, pct_of_content: 64 }
          balance_rationale: "Annotated-Hero is a dominant-hero variant: the timeline is the argument, so it takes 64 % of the content; the callout, the verdict, and the four-row evidence spotlight stay readable in the two lower bands, and the navigation buttons fill the last corner with no empty band."
    - name: "Signal explorer"
      display_name: "3 · Signal explorer"
      role: detail
      archetype: Analytical
      archetype_name: Analytical Canvas
      layout_variant: A
      variant_rationale: "Four slicers plus a reset button fill more than half of a two-column rail, which is the rail threshold, while the hero keeps ten columns for three small multiples."
      page_background: "#0E0E10"
      layout_summary: "A title with the active-filter summary; the filter rail on the left; the selected signal per target across the top; the signal-versus-load scatter and the wait ranking side by side; the findings detail at the bottom."
      layout_contract:
        canvas: { width: 1920, height: 1080, margin: 32, gutter: 24, snap: 8 }
        grid:
          columns: 12
          rows: 12
          regions:
            header: [1, 1, 9, 2]
            breadcrumb: [9, 1, 13, 2]
            rail: [1, 2, 3, 13]
            hero: [3, 2, 13, 6]
            scatter: [3, 6, 8, 9]
            waits: [8, 6, 13, 9]
            detail: [3, 9, 13, 13]
        placements:
          - id: page_title
            region: header
            kind: textbox
            text: "How each signal moved on each target, and what moved with it"
            text_binding: "'Telemetry Snapshots'[Explorer Headline]"
            subtitle: "History from lakehouse snapshots. Live view: Database Hub and the Real-Time Dashboard. All times UTC."
            purpose: "Name the selected signal and the target with the highest bin."
          - id: filter_summary
            region: breadcrumb
            kind: textbox
            text: "Signal: CPU, average per bin"
            text_binding: "'Telemetry Snapshots'[Active Filters Summary]"
            purpose: "Keep the active signal, targets, and data range visible."
          - id: period_slicer
            region: rail
            kind: slicer
            slicer_type: between
            field_bindings: "'Date'[Date]"
            header_text: "History period (UTC)"
            sync_group: history_period
            slot: 1
            of: 5
          - id: target_slicer
            region: rail
            kind: advancedSlicerVisual
            slicer_type: tile
            field_bindings: "'Target'[Target Short]"
            visual_filters: ["'Target'[Target Kind] is SQL target"]
            header_text: "Targets"
            selection: "Multi-select; none selected means all three"
            slot: 2
            of: 5
          - id: signal_slicer
            region: rail
            kind: slicer
            slicer_type: dropdown
            field_bindings: "'Signal'[Signal]"
            header_text: "Signal"
            selection: "Single select; none selected means CPU, average per bin"
            slot: 3
            of: 5
          - id: status_slicer
            region: rail
            kind: listSlicer
            slicer_type: list
            field_bindings: "'Status'[Status]"
            header_text: "Finding status (detail table)"
            selection: "Multi-select; filters only the findings detail"
            slot: 4
            of: 5
          - id: reset_button
            region: rail
            kind: actionButton
            text: "Reset filters"
            action: "Bookmark: Explorer reset"
            alt_text: "Reset the explorer's filters."
            slot: 5
            of: 5
          - id: signal_by_target
            region: hero
            kind: lineChart
            purpose: "How did the selected signal move on each target, and where did incident windows fall?"
            field_bindings:
              Category: "'Telemetry Snapshots'[Bucket UTC]"
              Y: ["'Telemetry Snapshots'[Signal Value]", "'Telemetry Snapshots'[Signal Value In Incident Window]"]
              SmallMultiples: "'Target'[Target]"
            visual_filters: ["'Target'[Target Kind] is SQL target"]
            axes: "Continuous UTC time on x; one y-axis shared across panels, starting at 0"
            reference_lines: ["y = 'Telemetry Snapshots'[Signal Threshold], Warning amber dashed, labeled 'attention threshold'"]
            series_styles: "Signal Value 2 px #E6E6EE; Signal Value In Incident Window 3 px #5772D9"
            sort_policy: natural_order
            color_strategy: measure_match
            drillthrough: "Right-click a panel to drill through on 'Target'[Target] to The incident, minute by minute"
            alt_text: "Line charts of the selected signal per bin for each selected target, with incident windows highlighted and the signal's attention threshold."
          - id: signal_vs_load
            region: scatter
            kind: scatterChart
            purpose: "Does the selected signal rise with load?"
            field_bindings:
              X: "'Telemetry Snapshots'[Batch Requests]"
              Y: "'Telemetry Snapshots'[Signal Value]"
              Details: "'Telemetry Snapshots'[Bucket UTC]"
              Legend: "'Target'[Target Short]"
            series_styles: "T1 circle #E6E6EE, T2 square #A0A0B0, T3 triangle #6C6C80; size 5; no data labels"
            color_strategy: "none: identity by lightness and shape, per target_identity"
            alt_text: "Scatter of the selected signal against batch requests per bin, one marker shape per target."
          - id: waits_by_category
            region: waits
            kind: barChart
            purpose: "Where did the wait time go?"
            field_bindings:
              Category: "'Telemetry Snapshots'[Metric]"
              Y: "'Telemetry Snapshots'[Wait Time (s)]"
            visual_filters: ["'Analysis'[Analysis Key] is wait_deltas", "Top 8 by 'Telemetry Snapshots'[Wait Time (s)]"]
            sort_policy: value_desc
            color_strategy: gradient
            conditional_formatting: "Bar fill from 'Telemetry Snapshots'[Wait Bar Color]: Warning amber for Lock, Buffer IO (PAGEIOLATCH), or Log Rate Governor above 10 % of wait time; otherwise neutral"
            data_labels: "On, outside end, #F2F2F5"
            alt_text: "Bar chart of wait seconds by category, top eight, largest first."
          - id: findings_detail
            region: detail
            kind: tableEx
            purpose: "Which findings did the notebooks record for these targets and statuses?"
            field_bindings: ["'Status'[Status Glyph]", "'Status'[Status]", "'Target'[Target Short]", "'Analysis'[Analysis]", "'Analysis Findings'[Finding]", "'Analysis Findings'[Captured At UTC]", "'Analysis Findings'[Evidence]"]
            sort_policy: "'Analysis Findings'[Captured At UTC] descending"
            color_strategy: semantic
            conditional_formatting: "Font color of 'Status'[Status Glyph] from 'Status'[Status Color]"
            empty_state: "No finding matches these filters."
            alt_text: "Table of findings for the selected targets, statuses, and period, newest first."
        space_audit:
          content_cell_count: 110
          placed_cell_count: 110
          empty_cell_pct: 0
          unplaced_regions: []
          largest_region: { name: hero, pct_of_content: 36 }
          balance_rationale: "The rail is excluded from content cells; the hero and the detail table each take 36 % of the content and the two supporting charts 14 % each, so no region swallows the page and every chart keeps at least five columns by three rows."
    - name: "Readiness checks"
      display_name: "4 · Readiness checks"
      role: detail
      archetype: Operational
      archetype_name: Operational Monitor
      layout_variant: C
      variant_rationale: "The owner works the exception queue before a demo, so the queue is the working surface (Incident-First) and the status tiles shrink to a strip; this rotates away from the estate page's variant A."
      page_background: "#0E0E10"
      layout_summary: "A readiness headline with the run and area slicers; four strip tiles; the full-width check queue, worst first; the readiness heat strip across runs and the telemetry coverage of the selected run."
      layout_contract:
        canvas: { width: 1920, height: 1080, margin: 32, gutter: 24, snap: 8 }
        grid:
          columns: 12
          rows: 12
          regions:
            header: [1, 1, 8, 2]
            filters: [8, 1, 13, 2]
            strip: [1, 2, 13, 4]
            queue: [1, 4, 13, 10]
            history: [1, 10, 8, 13]
            coverage: [8, 10, 13, 13]
        placements:
          - id: page_title
            region: header
            kind: textbox
            text: "Is the demo ready? Every check from the latest validation run, worst first"
            text_binding: "'Validation Results'[Readiness Headline]"
            subtitle: "History: Fabric-side checks from NB_DatabaseHub_Deployment (Azure-side checks: ./scripts/validate.ps1). All times UTC."
            purpose: "Say how many checks failed, need a manual step, or carry warnings."
          - id: run_slicer
            region: filters
            kind: slicer
            slicer_type: dropdown
            field_bindings: "'Validation Results'[Run ID]"
            header_text: "Validation run (UTC start)"
            selection: "Single select, sorted descending; none selected means the latest run"
            slot: 1
            of: 2
          - id: area_slicer
            region: filters
            kind: slicer
            slicer_type: dropdown
            field_bindings: "'Validation Results'[Area]"
            header_text: "Area"
            selection: "Multi-select; none selected means every area"
            slot: 2
            of: 2
          - id: tile_failed
            region: strip
            kind: cardVisual
            slot: 1
            of: 4
            purpose: "How many checks failed?"
            label_text: "✕ Failed"
            field_bindings:
              Data: ["'Validation Results'[Checks Failed (selected run)]"]
              ReferenceLabel: "'Validation Results'[Checks Context]"
            accent_bar: "'Validation Results'[Fail Rail Color]"
            color_strategy: semantic
            insight_basis: "Threshold: the rail lights red only when the count is above zero; the reference label sets it against all checks in the run."
            alt_text: "Failed checks in the selected validation run, out of all its checks."
          - id: tile_manual
            region: strip
            kind: cardVisual
            slot: 2
            of: 4
            purpose: "How many checks need a manual step?"
            label_text: "⚑ Manual action required"
            field_bindings:
              Data: ["'Validation Results'[Checks Needing a Manual Step (selected run)]"]
              ReferenceLabel: "'Validation Results'[Checks Context]"
            accent_bar: "'Validation Results'[Manual Rail Color]"
            color_strategy: semantic
            insight_basis: "Threshold: the rail lights cyan only when the count is above zero."
            alt_text: "Checks that need a manual step in the selected validation run, out of all its checks."
          - id: tile_warning
            region: strip
            kind: cardVisual
            slot: 3
            of: 4
            purpose: "How many checks carry a warning?"
            label_text: "▲ Warnings"
            field_bindings:
              Data: ["'Validation Results'[Checks With Warnings (selected run)]"]
              ReferenceLabel: "'Validation Results'[Checks Context]"
            accent_bar: "'Validation Results'[Warning Rail Color]"
            color_strategy: semantic
            insight_basis: "Threshold: the rail lights amber only when the count is above zero."
            alt_text: "Checks with warnings in the selected validation run, out of all its checks."
          - id: tile_readiness
            region: strip
            kind: cardVisual
            slot: 4
            of: 4
            purpose: "What share of the applicable checks passed?"
            label_text: "Readiness"
            field_bindings:
              Data: ["'Validation Results'[Readiness (%)]"]
              ReferenceLabel: "'Validation Results'[Validation Run Label]"
            accent_bar: "'Validation Results'[Readiness Rail Color]"
            color_strategy: semantic
            insight_basis: "Pass share of checks that apply and were selected, with the run's start time; the rail takes the worst attention status, never green."
            alt_text: "Readiness percentage of the selected validation run and its start time."
          - id: check_queue
            region: queue
            kind: tableEx
            purpose: "Which checks need attention, and what exactly fixes each one?"
            field_bindings: ["'Status'[Status Glyph]", "'Status'[Status]", "'Validation Results'[Check ID]", "'Target'[Target Short]", "'Validation Results'[Message]", "'Validation Results'[Remediation]", "'Validation Results'[Documentation]"]
            visual_filters: ["'Validation Results'[Is Selected Validation Run] is 1"]
            sort_policy: "value_asc on 'Status'[Status] (severity: Fail, Manual action required, Warning, Pass, Not supported, Not selected), then 'Validation Results'[Check ID] ascending"
            color_strategy: semantic
            conditional_formatting: "Font color of 'Status'[Status Glyph] from 'Status'[Status Color]; Documentation renders as a link icon; messages keep the EVALUATION ONLY prefix that ADR 0012 requires"
            alt_text: "Table of every check in the selected validation run, worst status first, with its target, message, remediation, and documentation link."
          - id: readiness_history
            region: history
            kind: pivotTable
            purpose: "Has readiness changed across the latest runs?"
            field_bindings:
              Rows: "'Validation Results'[Area]"
              Columns: "'Validation Results'[Run ID]"
              Values: ["'Validation Results'[Worst Check Status Glyph]"]
            visual_filters: ["Top 6 'Validation Results'[Run ID] by 'Validation Results'[Run Start UTC]"]
            sort_policy: "Columns by Run ID descending; rows by Area ascending"
            color_strategy: semantic
            conditional_formatting: "Font color from 'Validation Results'[Worst Check Status Color]"
            interactions: "Ignores the run slicer, so it always shows the latest six runs; follows the area slicer"
            alt_text: "Heat strip of the worst check status per area across the latest six validation runs."
          - id: telemetry_coverage
            region: coverage
            kind: pivotTable
            purpose: "Is each target still sending its telemetry tables?"
            field_bindings:
              Rows: "'Target'[Target Short]"
              Values: ["'Telemetry Snapshots'[Coverage Tables (selected run)]", "'Telemetry Snapshots'[Coverage Last Sample Age (min)]", "'Telemetry Snapshots'[Coverage Attention]"]
            visual_filters: ["'Target'[Target Kind] is SQL target"]
            sort_policy: "natural_order by 'Target'[Target Sort]"
            color_strategy: semantic
            conditional_formatting: "Font color of Coverage Last Sample Age (min) and Coverage Attention from 'Telemetry Snapshots'[Coverage Font Color]"
            insight_basis: "Staleness threshold of 15 minutes, the deployment notebook's freshness rule, plus the count of telemetry tables each target sent in the same run."
            alt_text: "Telemetry tables per target in the selected run, minutes since each target's last sample, and whether it is fresh."
        space_audit:
          content_cell_count: 132
          placed_cell_count: 132
          empty_cell_pct: 0
          unplaced_regions: []
          largest_region: { name: queue, pct_of_content: 55 }
          balance_rationale: "Incident-First makes the exception queue the working surface, so it takes 55 % of the content; the strip keeps two rows for values plus context, and the heat strip and the three-row coverage spotlight share the last three rows."
  interaction_pattern:
    drill_targets: ["The incident, minute by minute: drillthrough field 'Target'[Target], used by the timeline panels and the health matrix, keep all filters off"]
    cross_filter_rules:
      - "Estate at a glance: the period slicer filters every visual except the history tile; tiles use Filter; the timeline, queue, and matrix highlight each other."
      - "The incident, minute by minute: the picker filters the page; every visual-to-visual interaction is None."
      - "Signal explorer: period, target, and signal slicers filter the hero, scatter, waits, and detail; the status slicer filters only the detail table (None elsewhere); the charts cross-highlight."
      - "Readiness checks: run and area slicers filter the strip, queue, and coverage; the heat strip ignores the run slicer (None) and follows the area slicer."
    sync_slicers: ["'Date'[Date] between slicer synced on Estate at a glance and Signal explorer, group history_period"]
    bookmarks: ["Explorer reset: clears the explorer's rail slicers to their defaults"]
    navigation: "Page tabs in the service, the org app's page navigation, Prev and Next on the incident page, and drillthrough to the incident page"
    personalize_visuals: "On for Signal explorer only"
  accessibility:
    alt_text_strategy: "Headline plus trend for timelines, comparison framing for tiles and matrices, data-as-table fallback for queues; the incident timeline's alt text is the DAX measure Incident Timeline Alt Text"
    contrast_notes: "On #17171C: text #F2F2F5 16.0:1, #B4B4C2 8.7:1, #8C8C9C 5.4:1; Fail #FF4D5A 5.5:1; Warning #FFB020 9.8:1; Manual action required #8CEEEE 13.3:1; indigo band #5772D9 4.1:1 as a non-text mark; status chips use #0E0E10 text on attention fills, 5.9:1 or better"
    color_redundancy: "Every status pairs color with a glyph and the status word; targets are told apart by position, labels, lightness, and marker shape; incident windows are also stated in titles, subtitles, and the narrative"
    tab_order: "Title, slicers, tiles left to right, hero, then the lower row left to right; the Selection pane order matches"
    minimum_text: "10 pt"
    glyph_fallback: "If a status glyph doesn't render in the Desktop screenshot loop, use X, M, !, OK, NS, and NA"
  theme:
    base: "assets/base.json adapted as DbHubCockpitDark.json, registered under StaticResources/RegisteredResources"
    name: "DbHub Cockpit Dark"
    background: "#0E0E10"
    foreground: "#F2F2F5"
    secondary_foreground: "#B4B4C2"
    table_accent: "#2A2A3A"
    data_colors: ["#E6E6EE", "#B4B4C2", "#8C8C9C", "#6C6C80", "#5772D9", "#FFB020", "#FF4D5A", "#8CEEEE"]
    sentiment: { good: "#8C8C9C", neutral: "#FFB020", bad: "#FF4D5A" }
    text_classes: { title: "Segoe UI Semibold 24 #F2F2F5", largeTitle: "Segoe UI Semibold 13 #F2F2F5", callout: "Segoe UI Bold 32 #F2F2F5", label: "Segoe UI 10 #B4B4C2" }
    visual_containers: "Background #17171C, border 1 px #2A2A3A radius 4, padding 8, drop shadows off, visual headers hidden"
    gridlines: "Dotted #3A3A4A, value axis only"
    tables: "Style preset None; header #1F1F26 with #F2F2F5 text; rows #17171C and #1B1B22 with #F2F2F5 text; grow-to-fit columns"
    safeguards_preserved: ["textbox zero padding, no background, no border", "cardVisual zero padding and card spacing", "tableEx and pivotTable grow-to-fit and explicit row colors", "hidden visual headers", "bar, column, and line chart defaults"]
    per_visual: ["cardVisual accentBar 4 px left, color bound to each tile's rail measure", "cardVisual outline off", "slicer padding 2 so a dropdown fits the 64 px header band", "page background #0E0E10 with transparency 0"]
    user_overrides: "None: greenfield"
```

## Implementation notes

- Model changes:
  - Notebook changes first (see "Incident windows"), imported with `./scripts/configure-fabric.ps1` and run once, so all five tables and `report_date_utc` exist before the model is created.
  - Author the model with `powerbi-modeling-mcp` against the local PBIP folder (the skill's Tier 1 path), then serialize TMDL into `fabric/powerbi/SM_DatabaseHub_History.SemanticModel/definition/`: `database.tmdl` (compatibility level 1702), `model.tmdl` (culture en-US, `discourageImplicitMeasures`), `expressions.tmdl` (the Direct Lake expression with an all-zero placeholder URL), `relationships.tmdl`, and `tables/*.tmdl` (Direct Lake partitions with `entityName`, `schemaName: dbo`, and `expressionSource`; calculated partitions for the five dimensions). Spaces, not tabs, if anything is hand-edited; descriptions with `///`.
  - Deploy from files with Create Semantic Model (first time) or Update Semantic Model Definition (every part), refresh once, then validate every measure with `EVALUATE` and `INFO.MEASURES()` through Execute Queries.
- PBIR/report authoring:
  - A deterministic Node.js generator (`fabric/powerbi/generator/`, Node 26) reads this spec's `Design Brief:` block and writes `RPT_DatabaseHub_History.Report/definition/` (`report.json`, `version.json`, `pages/pages.json`, one folder per page, one `visual.json` per placement) and the theme under `StaticResources/RegisteredResources/`. Region-to-pixel conversion: 32 px margins, 24 px gutters, column width 132.67 px, row height 62.67 px, every coordinate snapped to 8.
  - Roles, formatting objects, selectors, and enum values come from `powerbi-report-author catalog describe` and `formatting describe-object`, never from memory; the generator follows the authoring skill's dark-mode checklist (style preset None on tables, explicit cell colors, id selectors for card accent bars).
  - Pin `@microsoft/powerbi-report-authoring-cli` and `@microsoft/powerbi-desktop-bridge-cli` in `config/versions.json`.
- Validation:
  - `powerbi-report-author validate fabric/powerbi/RPT_DatabaseHub_History.Report` after every generator run; JSON parses; page and visual counts match this contract (4 pages with 10, 8, 11, and 10 placements).
  - Pester: TMDL conventions (every measure has a format string and a description; no real GUID; every Direct Lake `entityName` is one of the five tables), the notebook changes, and the PBIR folder shape. `./tests/Invoke-StaticValidation.ps1` before the pull request.
  - DAX checks against the deployed model: `Snapshot Value` returns one value per bin even after two overlapping runs; `Selected Validation Run` returns the newest run; the empty-state measures return their messages on today's data.
- Desktop screenshot verification:
  - Power BI Desktop 2.159 (Microsoft Store) with the report-authoring preview feature on. For local preview, `definition.pbir` uses the full `byConnection` form against the deployed model, because Desktop can't host a local Direct Lake on OneLake model offline.
  - `powerbi-desktop open`, `status`, `reload --pid`, and `screenshot-all`, serially per process; review each page against the pre-flight checklist (squint test, sibling test, no clipped slicers or scrollbars, glyphs render, color map honored), and loop until clean. Screenshots stay in `out/`.
  - Dynamic titles must stay on one line at 24 pt in their header width: check the longest variant of each (for example a log-rate incident on T3) and shorten its measure text rather than shrinking the font.
- Publishing boundary:
  - Scripted and documented: the semantic model, its first refresh, the report (Create Report with the minimal `byConnection` form), and the org app item and its definition, all through `scripts/configure-powerbi.ps1`: `-WhatIf` plan first, the subscription guard and `Invoke-DemoAz` for tokens, `New-DemoResult` records in `out/configure-powerbi.jsonl`, one Fabric create per item (never a retried create after HTTP 202), and forward-slash part paths.
  - Manual and documented: sharing the app, granting viewer data access, and the workspace-app fallback; see "App".
- Risks:
  - Direct Lake framing fails if a source table or column is missing; the notebook changes create them, and the build runs the notebook before the model.
  - The F16 guardrail of 1,000 Parquet files per table; mitigated by single-file writes and `OPTIMIZE`.
  - Detected windows are heuristics: an incident without its signal isn't listed, and a busy baseline can produce a detected window. Both are labeled by source.
  - Calculated tables in a Direct Lake on OneLake model: supported when they don't reference Direct Lake tables, per Learn; if the first deploy rejects them, the fallback is lakehouse dimension tables written by the same notebook helper.
  - The org app definition's `folderObjectId` isn't documented for items at the workspace root; the fallback is adding content in the portal once and capturing the definition (see "App").
  - Preview surfaces: the telemetry schema can change; the model reads the notebooks' Delta columns, so a telemetry change surfaces as a notebook change, not a model change.
  - A paused F16 capacity answers 404 `CapacityNotActive`. The capacity is shared and runs at the owner's choice: the build never pauses, resumes, or scales it, and reports **Manual action required** when it's paused.
  - The branch base predates the Phase 12 tip; merge it first.

Repository layout after the build:

```text
fabric/powerbi/
  _brief/report-spec.md                     this spec
  DbHubHistory.pbip                         project entry point
  SM_DatabaseHub_History.SemanticModel/     definition.pbism, definition/ (TMDL)
  RPT_DatabaseHub_History.Report/           definition.pbir, definition/ (PBIR), StaticResources/
  generator/                                Node.js PBIR generator and its tests
  orgapp/definition.template.json           org app definition with run-time tokens
scripts/configure-powerbi.ps1               deploy, refresh, validate, publish; -WhatIf
```

## App

### What the app packages

Recommended: an **org app item** named `APP_DatabaseHub_Demo`. Learn: "Org apps are a newer evolution of workspace apps, implemented as Fabric items. Org apps are generally available and can coexist with workspace apps." They can include Power BI reports, paginated reports, Fabric notebooks, Fabric Apps (preview), maps, and real-time dashboards, and a workspace can hold several ([Get started with org apps](https://learn.microsoft.com/power-bi/explore-reports/org-app-items)). So the app can carry Phase 18's Real-Time Dashboard next to the report; the workspace-app article covers Power BI dashboards and reports and lists no Real-Time Dashboards ([Publish an app in Power BI](https://learn.microsoft.com/power-bi/collaborate-share/service-create-distribute-apps)).

| Element | Content |
|---|---|
| Overview, "Start here" | Title "Database Hub demo"; body: the report is history from lakehouse snapshots, the live view is Database Hub and the Real-Time Dashboard, and all times are UTC |
| Section "History" | `RPT_DatabaseHub_History`, with its four pages listed in the navigation |
| Section "Live" | Phase 18's Real-Time Dashboard (`KQLDashboard`) when it exists at build time, and a new-tab link to Database Hub, `https://powerbi.com/workloads/fdh/databaseHub` |
| Settings | Theme from the cockpit palette (`#17171C` background, `#F2F2F5` foreground, `#1F1F26` hover, `#2A2A3A` selected, `#3A3A4A` pressed); navigation pane expanded; report pages listed independently; audience tabs hidden (one audience) |

"Fabric app" here means this packaging. Fabric Apps (preview) is a different item, a TypeScript developer platform ([What is Fabric Apps (Preview)?](https://learn.microsoft.com/fabric/apps/overview)); it's out of scope, and an org app could include one later.

### Audience and access

- The presenter is a workspace member and sees everything. A customer watching a shared screen needs no access and no license.
- The demo owner checks readiness in the app or the workspace.
- A colleague outside the workspace who opens the app needs four things, all granted by hand:
  1. Access to the org app, which grants Read on the report and its semantic model.
  2. Data access for Direct Lake. With SSO (the default), Read plus "Read all with Apache Spark" on `LH_DatabaseHub` ([Lakehouse sharing](https://learn.microsoft.com/fabric/data-engineering/lakehouse-sharing)); workspace Viewers lack OneLake read too. Or a fixed-identity cloud connection with SSO off, so viewers need no lakehouse access ([Integrate Direct Lake security](https://learn.microsoft.com/fabric/fundamentals/direct-lake-security-integration)). See open decision 2.
  3. A Pro, PPU, or individual trial license (see "Licensing").
  4. For the Real-Time Dashboard's tiles, Reader on the demo subscription: the telemetry endpoint returns rows only for resources the viewer's account can access ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)).

### Creation and update path

- Create: [Items - Create Org App](https://learn.microsoft.com/rest/api/fabric/orgapp/items/create-org-app), `POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/orgApps`: Contributor role, scope `Item.ReadWrite.All`, a long-running operation. Its definition follows [Org app item definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/orgapp-definition): a `definition.json` part with `$schema`, `settings`, and `elements`.
- Update and read back: [Update Org App Definition](https://learn.microsoft.com/rest/api/fabric/orgapp/items/update-org-app-definition), [Get Org App Definition](https://learn.microsoft.com/rest/api/fabric/orgapp/items/get-org-app-definition), and [List Org Apps](https://learn.microsoft.com/rest/api/fabric/orgapp/items/list-org-apps).
- Item elements need `itemId` plus `folderObjectId`, or `itemLogicalId` from Git integration. The article doesn't say what `folderObjectId` is for an item at the workspace root. So the first build creates the app with its overview and link elements by script, adds the report and the dashboard in the portal once (Manual action required), and captures the definition with Get Org App Definition. From then on, `fabric/powerbi/orgapp/definition.template.json` holds it with run-time tokens for every ID, and the script updates it.
- Adding or removing included items changes access management, which needs write and reshare permissions on the items and the semantic model, in practice workspace Admin or Member ([Get started with org apps](https://learn.microsoft.com/power-bi/explore-reports/org-app-items)). With Contributor only, that step reports Manual action required.
- Sharing has no step in the script: it grants permissions, so it stays manual.

```json
{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/orgapp/definition/orgAppDefinition/2.0.0/schema.json",
  "settings": {
    "theme": { "background": "#17171C", "foreground": "#F2F2F5", "backgroundHover": "#1F1F26", "backgroundSelected": "#2A2A3A", "backgroundPressed": "#3A3A4A" },
    "experienceSettings": { "navigationPane": { "isHidden": false, "isCollapsed": false, "independentPageNavigation": true } },
    "itemTypeSettings": { "report": { "hidePagePane": false } },
    "audienceSettings": { "hideAudienceTabs": true, "hideAllTab": true }
  },
  "elements": [
    { "elementType": "overview", "elementId": "{{overview-element-id}}", "displayName": "Start here",
      "header": { "title": "Database Hub demo", "body": "History from lakehouse snapshots. The live view is Database Hub and the Real-Time Dashboard. All times UTC.", "showTheme": true } },
    { "elementType": "section", "elementId": "{{history-section-id}}", "displayName": "History", "elements": [
      { "elementType": "item", "elementId": "{{report-element-id}}", "itemId": "{{report-item-id}}", "folderObjectId": "{{report-folder-object-id}}", "itemType": "Report", "displayName": "Demo history" } ] },
    { "elementType": "section", "elementId": "{{live-section-id}}", "displayName": "Live", "elements": [
      { "elementType": "item", "elementId": "{{dashboard-element-id}}", "itemId": "{{dashboard-item-id}}", "folderObjectId": "{{dashboard-folder-object-id}}", "itemType": "KQLDashboard", "displayName": "Real-Time Dashboard" },
      { "elementType": "link", "elementId": "{{hub-link-element-id}}", "url": "https://powerbi.com/workloads/fdh/databaseHub", "linkType": "newtab", "displayName": "Database Hub (live)" } ] }
  ]
}
```

The double-brace tokens are resolved at run time; element IDs are generated once and kept stable; the `itemType` value for a Real-Time Dashboard is confirmed from Get Org App Definition after the first portal add.

### Manual steps

Org app (recommended), per [Get started with org apps](https://learn.microsoft.com/power-bi/explore-reports/org-app-items):

1. In workspace "Database Hub Demo", open `APP_DatabaseHub_Demo` and select **Edit**.
2. First build only: select **Add content**, choose `RPT_DatabaseHub_History` and the Real-Time Dashboard, select **Add to app**, and use **Move to section** to place them under History and Live.
3. Select **Preview app**, then **Save**.
4. Select **Share**, then **Add person or group**; add the viewers and leave reshare off. **Manage access** lists them later.
5. Viewer data access, per open decision 2: either open `LH_DatabaseHub`, select **Share**, add the viewers with **Read all with Apache Spark**, and select **Grant**; or bind the semantic model's Direct Lake source to an OAuth 2.0 cloud connection with SSO off (semantic model **Settings**, **Gateway and cloud connections**), or with [Items - Bind Semantic Model Connection](https://learn.microsoft.com/rest/api/fabric/semanticmodel/items/bind-semantic-model-connection).
6. Confirm each viewer's Pro, PPU, or trial license, and Reader on the demo subscription for live tiles.

Workspace app (fallback, only if org apps are unavailable in the tenant), per [Publish an app in Power BI](https://learn.microsoft.com/power-bi/collaborate-share/service-create-distribute-apps):

1. In workspace "Database Hub Demo", select **Create app**.
2. **Setup**: name "Database Hub Demo", the history description, and the theme color.
3. **Content**: add `RPT_DatabaseHub_History` and a link to Database Hub.
4. **Audience**: add the viewers.
5. Select **Publish app** and copy the link. Later changes use **Update app**; viewers see them only after the update.

### Validation

- Org app: [List Org Apps](https://learn.microsoft.com/rest/api/fabric/orgapp/items/list-org-apps) returns `APP_DatabaseHub_Demo`, and [Get Org App Definition](https://learn.microsoft.com/rest/api/fabric/orgapp/items/get-org-app-definition) references the report's item ID, and the dashboard's when included: **Pass**. Missing app or content: **Fail** with the remediation. Sharing and viewer data access: **Manual action required**, every run.
- Workspace app (fallback): after publishing, [Apps - Get Apps](https://learn.microsoft.com/rest/api/power-bi/apps/get-apps) (`GET https://api.powerbi.com/v1.0/myorg/apps`, scope `App.Read.All`, a user token; service principals aren't supported) lists the app, and [Apps - Get Reports](https://learn.microsoft.com/rest/api/power-bi/apps/get-reports) lists the report: **Pass**. The Apps group has only Get operations ([Apps](https://learn.microsoft.com/rest/api/power-bi/apps)), which is why publishing stays manual.
- Get Apps returns installed apps, and org apps aren't installed, so for the org app it's informational only.
- Records: `FABRIC.ORGAPP.EXISTS`, `FABRIC.ORGAPP.CONTENT`, `FABRIC.ORGAPP.SHARE`, `FABRIC.ORGAPP.VIEWERDATA`, and, in the fallback, `FABRIC.WORKSPACEAPP.LISTED`.

### Licensing

"On F SKUs smaller than F64, each user viewing Power BI content must have Pro, PPU, or an individual trial. On F64 or larger, users with only a Free license and a viewer role can view Power BI content" ([Microsoft Fabric license types](https://learn.microsoft.com/fabric/enterprise/licenses)). The demo's capacity is F16, so every app viewer of the report needs Pro, PPU, or an individual trial. A presenter sharing their screen is fine. Creating the model, the report, and the org app needs the creator's appropriate license, per each Create API's limitations.

## Open decisions

Each has a recommended default; the build uses the default unless the owner says otherwise at approval.

| # | Decision | Options | Recommended default |
|---|---|---|---|
| 1 | App type | Org app item (scripted shell and definition, can include the Real-Time Dashboard), or workspace app (manual publish, Power BI content only) | Org app item; the workspace app only if the tenant blocks org apps |
| 2 | Viewer data access for Direct Lake | SSO plus per-viewer lakehouse share (Read and "Read all with Apache Spark"), or a fixed-identity OAuth 2.0 cloud connection with SSO off | SSO now, since only the presenter and workspace members use it; switch to the fixed identity before the app is shared outside the workspace, so viewers never get raw lakehouse access |
| 3 | Incident windows | A: derive in the notebook (recorded requests plus detected signals); B: also copy the runner's SQL records through OneLake | A now; B later only if T3 run identity or runs without a signal must appear |
| 4 | Readiness scope | Notebook checks only, or also the `validate.ps1` catalog uploaded through the same OneLake path as 3B | Notebook checks only, labeled as such in the page subtitle |
| 5 | Time zone | UTC everywhere, or presenter-local display | UTC everywhere, matching Database Hub telemetry, the notebooks, and the agent prompts |
| 6 | Where the dimensions live | DAX calculated tables in TMDL, or lakehouse tables written by the notebook | Calculated tables (Date fixed to 2026 to 2030); lakehouse tables only if the first deploy rejects them |
| 7 | Detection thresholds | Any values | Blocked processes above 0; CPU at or above 80 % for 2 bins; Buffer IO waits at or above 1 s per bin for 2 bins; Log Rate Governor waits above 0. Presenter heuristics, like ADR 0014's correlation thresholds |
| 8 | History freshness warning | Any age | Warning after 24 hours, Manual action required with no snapshot |
| 9 | Real-Time Dashboard in the app | Include it, or link only | Include it when Phase 18's dashboard exists at build time; otherwise the Hub link only |
| 10 | Meaning of "a Fabric app" | Org app packaging, or Fabric Apps (preview), the TypeScript developer platform | Org app packaging; Fabric Apps (preview) is out of scope |
| 11 | Item names | Any | `SM_DatabaseHub_History`, `RPT_DatabaseHub_History`, `APP_DatabaseHub_Demo`, following `NB_` and `LH_` |
| 12 | Canvas | FHD or 1280 × 720 | FHD 1920 × 1080, the design skill's greenfield default |

## Sources

Microsoft Learn, read on 2026-10-21:

- Direct Lake: [Direct Lake overview](https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview) (modes, capabilities, F16 guardrails, limitations), [How Direct Lake works](https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works) (framing, automatic updates, no fallback on OneLake), [Integrate Direct Lake security](https://learn.microsoft.com/fabric/fundamentals/direct-lake-security-integration) (SSO, fixed identity, Read and ReadAll), [Lakehouse sharing](https://learn.microsoft.com/fabric/data-engineering/lakehouse-sharing), [Optimize Delta Lake tables with V-Order](https://learn.microsoft.com/fabric/data-engineering/delta-optimization-and-v-order).
- Item definitions and REST: [SemanticModel definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/semantic-model-definition), [Report definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/report-definition), [Org app item definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/orgapp-definition), [Create Semantic Model](https://learn.microsoft.com/rest/api/fabric/semanticmodel/items/create-semantic-model), [Create Report](https://learn.microsoft.com/rest/api/fabric/report/items/create-report), [Create Org App](https://learn.microsoft.com/rest/api/fabric/orgapp/items/create-org-app), [Bind Semantic Model Connection](https://learn.microsoft.com/rest/api/fabric/semanticmodel/items/bind-semantic-model-connection), [List Items](https://learn.microsoft.com/rest/api/fabric/core/items/list-items), [Long-running operations](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation), [Refresh Dataset In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group), [Execute Queries In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group).
- Apps and licensing: [Get started with org apps](https://learn.microsoft.com/power-bi/explore-reports/org-app-items), [Publish an app in Power BI](https://learn.microsoft.com/power-bi/collaborate-share/service-create-distribute-apps), [Power BI REST Apps](https://learn.microsoft.com/rest/api/power-bi/apps), [What is Fabric Apps (Preview)?](https://learn.microsoft.com/fabric/apps/overview), [Microsoft Fabric license types](https://learn.microsoft.com/fabric/enterprise/licenses).
- Telemetry and projects: [Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry), [How do I connect to OneLake?](https://learn.microsoft.com/fabric/onelake/onelake-access-api), [Create dynamic format strings for measures](https://learn.microsoft.com/power-bi/create-reports/desktop-dynamic-format-strings), [Power BI Desktop project report folder](https://learn.microsoft.com/power-bi/developer/projects/projects-report), [Power BI Desktop project semantic model folder](https://learn.microsoft.com/power-bi/developer/projects/projects-dataset).

Repository: [ADR 0012](../../../docs/adr/0012-validation-model.md) (statuses, evaluation-only labeling), [ADR 0014](../../../docs/adr/0014-notebook-role-and-capacity.md) (notebooks, Delta tables, heuristics), [ADR 0008](../../../docs/adr/0008-identity-rbac-abac.md) (Contributor minimum), [`fabric/README.md`](../../README.md), and [`scenarios/activity-profiles.json`](../../../scenarios/activity-profiles.json) (the business-day schedule).

Skills: `powerbi-report-planning`, `powerbi-report-design` (with its references and `assets/base.json`), `semantic-model-authoring`, `powerbi-report-authoring`, and `powerbi-report-management`.

## Acceptance checks

The planning skill's "Required acceptance checks before approval", run on 2026-10-21 against this file. A local script parsed the `Design Brief:` block, recomputed every page's space audit from its grid, and checked bounds and overlaps (83 checks, all Pass); markdownlint and the repository's relative-link test ran on the file.

| Check | Result | Evidence |
|---|---|---|
| The block begins with `Design Brief:` | Pass | Exactly one fenced `yaml` block in the file, and it begins with `Design Brief:` |
| It includes `generated_by: powerbi-report-design` and `contract_version` | Pass | `generated_by: powerbi-report-design`, `contract_version: 1` |
| Every Markdown page has a matching `pages[]` entry | Pass | The page plan and `pages[]` list the same four names in the same order |
| Every page has `layout_contract.canvas`, `grid.regions`, and `placements` | Pass | All four pages: FHD 1920 × 1080 canvas, 6 or 7 regions, 8 to 11 placements; every region inside the 12 × 12 grid, none overlapping, every placement in a defined region |
| Every page has `space_audit` with empty `unplaced_regions` and a balance rationale | Pass | Recomputed: estate 132 of 132 content cells placed, largest hero 36 %; incident 132 of 132, hero 64 % (Annotated-Hero); explorer 110 of 110 after the rail, hero 36 %; readiness 132 of 132, queue 55 % (Incident-First); empty space 0 % everywhere |
| Every page has a `page_title` textbox with non-empty title text | Pass | Each title has a static insight sentence plus a headline measure binding |
| Slicers sit in a top-right `filters` region or a justified rail; no data visual starts under the band | Pass | Filters regions start in row 1 and end at column 13 on pages 1, 2, and 4; the explorer's rail holds four slicers plus a reset button at the left edge, below the band; every data visual starts in row 2 or lower |
| No bare single-value `cardVisual` is the largest region | Pass | Largest regions: a line chart, a combo chart, a line chart, and the check queue table; every card sits in a two-row strip, and the single-value strip cards carry reference labels |
| No ellipses, unresolved placeholders, or promised-but-missing pages or visuals | Pass | No `...`, `…`, angle-bracket placeholders, TBD, or TODO in the YAML; every visual named in the page plan has a placement |
| Design-brief validation checklist: purpose and bindings, sort policies, color strategies, alt text | Pass | Every data visual has `purpose`, `field_bindings`, `color_strategy`, and alt text; every bar, line, and table visual has `sort_policy` |
| No real IDs | Pass | No GUID-like string and none of the sample's workspace, lakehouse, capacity, or run IDs anywhere in the file |
| `./tests/Invoke-StaticValidation.ps1 -Check Markdown` | Pass | markdownlint-cli2 0.23.3: no issues in 84 files |
| Relative links resolve (`Repo.Conventions.Tests.ps1`, Markdown) | Pass | Pester 5.9.1: 1 passed, 0 failed |

Approval gate: the build starts only after the owner approves this spec. The planning skill's choices are: approve and start building; revise audience or purpose; revise scope or the page plan; or revise design or delivery.
