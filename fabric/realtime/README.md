# Real-Time Dashboard as code

`RTD_DatabaseHub_LiveView` is the presenter's live view of the demo: a Fabric Real-Time Dashboard over the same SQL telemetry that Database Hub shows, defined in this folder and versioned in Git. It's one of the four [presentation surfaces](../../docs/presentation.md), next to Database Hub itself. The design is an "operations cockpit": large status numbers, and color only for status.

> **Preview disclosure:** the telemetry endpoint and its schema are previews ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). Samples arrive a few minutes after the activity, and missing data isn't zero.

**Status (2026-10-21, Phase 18):** imported into the demo workspace and read back identical in content; every tile's query returns data for the last 24 hours (see [live results](#live-results-2026-10-21)). Built and validated against the published dashboard schema, and covered by unit tests.

## What's here

| Path | What it is |
|---|---|
| `dashboard.spec.psd1` | The layout: pages, parameters, tiles, and the KQL fragments each query is built from. Edit this file. |
| `RealTimeDashboard.json` | The generated definition (the `RealTimeDashboard.json` part of the item definition). Don't edit it by hand: run `Export-DemoRealTimeDashboard` and commit both files. |
| `scripts/modules/DbHubDemo/Kql/Live.*.kql` | The shared analysis KQL: the live-activity notebook's own queries, byte for byte, and `Live.Prelude.kql`, the window, the bin, and the target mapping |
| `scripts/modules/DbHubDemo/Kql/Dashboard.*.kql` | The dashboard's fragments: the Target filter, the heartbeat, and each tile's shape |

The module functions are `Export-DemoRealTimeDashboard` (build), `Get-DemoFabricDashboardDefinition` (render for one environment), and `Import-DemoFabricItem` (create or update, then read back). `scripts/configure-fabric.ps1 -ImportDashboard` runs the last two.

## The live view

| Page | Tiles | Answers |
|---|---|---|
| **Estate pulse** | A note on the data; **Freshness per target** (multi stat); **Reporting per target**: tables, rows, instances, and the newest sample (table); **Telemetry heartbeat**: CPU samples per bin (time chart) | Is every target reporting, and how fresh is its newest sample? A target with no data in the range shows as **No data**, never as a zero. |
| **Incident** | **Processes blocked, latest sample** (multi stat); processes blocked; waits by category in seconds per bin (Lock means blocking); active sessions in `ContosoCare`; batch requests per second; CPU % (time charts) | What changed during the incident, side by side? |
| **Resources** | **CPU, 95th percentile over the time range** (multi stat); CPU %; largest memory clerks; data and log IO (charts); storage IO over the range (table) | Where is the load: CPU, memory, or storage IO? |

- **Parameters:** **Time range** (the dashboard's `_startTime` and `_endTime`, the last hour by default) and **Target** (T1, T2, T3, or all of them; multiple selection, all by default) on every page. The bin follows the range the way the live-activity notebook chooses it: 1 minute up to 2 hours, 5 minutes up to 12 hours, then 15 minutes.
- **Auto-refresh:** every minute, and viewers can't choose a faster rate, which keeps the load on the shared telemetry endpoint small.
- **Status colors** (conditional formatting, the only color on the dashboard):

  | Tile | Green | Yellow | Red |
  |---|---|---|---|
  | Freshness, Reporting | Newest sample at most 15 minutes old, the threshold of `TELEMETRY.T1`–`T3` | Older | No data in the range |
  | Processes blocked, latest sample | 0 | | Above 0 |
  | CPU, 95th percentile | Under 70% | 70% or more | 80% or more |

  The thresholds are presenter heuristics, not product behavior. Charts use the default series colors and no fixed colors.
- **No theme:** the dashboard schema has no theme property and Learn documents no dashboard theme, so the dashboard follows the Fabric portal's appearance (**Not supported**: a dark theme can't be set in the definition).

## Data source and permissions

- **One data source:** the SQL ADX proxy that Learn documents for querying the telemetry, `https://adx.centralus.arcdataservices.com/kusto/`, database `ArcSqlTelemetry`, as an Azure Data Explorer data source ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), [Add a data source](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create#add-data-source)).
- **No stored credential:** the definition uses the default pass-through identity, so each viewer queries the proxy as themselves ([Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions)). Don't switch it to the editor's identity: that would show the editor's view of the telemetry to everyone with access to the dashboard.
- **What a viewer needs:**
  - access to the dashboard in the workspace (a workspace role, or the dashboard shared with them);
  - **Reader** on the demo subscription, because the telemetry endpoint returns rows only for resources the caller can read ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)); Contributors already have it;
  - for T2's data, the Arc telemetry role (**Azure Hybrid Database Administrator - Read Only Service Role**) on the demo resource group when they're only Readers ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql)). `Set-DemoPresenterAccess` assigns both, or prints the commands (P8, [permissions](../../docs/permissions.md#presenter-access));
  - a Fabric Free license is enough: a Real-Time Dashboard isn't Power BI content, so the F64 viewer rule (P11) doesn't apply to it ([Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses)).
- **Capacity:** a Real-Time Dashboard is a Fabric item, so the workspace needs a Fabric capacity ([Create a Real-Time Dashboard](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create#prerequisites)). The demo's shared capacity runs at the owner's choice and is outside the demo's monthly ceiling ([presentation](../../docs/presentation.md#cost)).

## Build it

```powershell
Import-Module ./scripts/modules/DbHubDemo/DbHubDemo.psd1
Export-DemoRealTimeDashboard               # writes fabric/realtime/RealTimeDashboard.json
Export-DemoRealTimeDashboard -WhatIf -PassThru   # the JSON, without writing it
```

- Each query is `Live.Prelude.kql`, rendered for the dashboard, followed by the fragments the spec lists for it. The `Live.*` bodies are identical to the live-activity notebook's queries, so the notebook, the dashboard, and the tests share one copy of the analysis KQL; `tests/unit/Fabric.Dashboard.Tests.ps1` fails if they drift, or if the committed JSON doesn't match a rebuild.
- The definition is validated before it's written: the published schema's rules the dashboard relies on, tiles inside the 24-column grid without overlaps, every used variable declared, and no ID the definition doesn't define.
- **No real IDs:** element IDs are name-based UUIDs (RFC 4122 version 5) of the spec's keys, so a rebuild changes nothing unless the layout does. The resource group stays a `{{ResourceGroup}}` placeholder until import.
- **KQL rules** from the telemetry article, checked by the tests on every query: filter on `SampleTimeUTC` first, then on the demo resource group; per-series deltas of cumulative counters that skip resets; branch on `CounterType`; group by `ResourceID` and `SqlServerInstanceName`; compare case-insensitively; leave out the `Idle` and `Unknown` wait categories; and limit rows.

## Import it

Changing the workspace needs the owner's go-ahead.

```powershell
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard -WhatIf   # validates and plans; no token, no call
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard           # imports, reads it back, checks every tile's data
```

1. `Get-DemoFabricDashboardDefinition` validates `RealTimeDashboard.json`, fills in the demo resource group (`rg-<prefix>-<environment>`) as a KQL string literal, validates the result, and builds the documented definition: one part, `RealTimeDashboard.json`, in `InlineBase64` ([KQL dashboard item definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition)).
2. `Import-DemoFabricItem` finds the item by display name ([List Items](https://learn.microsoft.com/rest/api/fabric/core/items/list-items), type `KQLDashboard`), then calls [Create Item](https://learn.microsoft.com/rest/api/fabric/core/items/create-item) or [Update Item Definition](https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition), following [long-running operations](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation). It's Phase 12's notebook import, made generic; the notebook import now runs on it too.
3. It reads the definition back with [Get Item Definition](https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition) and compares it with what it sent: `FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW` is **Pass** when every page, data source, parameter, query text, and tile came back (fields Fabric normalizes, such as a newer schema version, are listed in the evidence), **Fail** when any of them changed or is missing, and **Warning** when the read-back couldn't complete.
4. After a passing import and read-back, it checks every tile's data ([below](#check-the-data)); `-SkipDashboardDataCheck` skips that.

The token is your Fabric token, from `-FabricToken` or the signed-in Azure CLI after the subscription guard, sent only to `https://api.fabric.microsoft.com/v1`. Results go to `out/configure-fabric.jsonl`, which Git ignores; item IDs appear only there and on the console.

**Manual fallback:** `Get-DemoFabricDashboardDefinition -Config (Get-DemoConfig -Path ./config/demo.config.json) -OutFile ./out/RealTimeDashboard.json` writes the rendered file. Create an empty Real-Time Dashboard in the workspace, then use **Manage** > **Replace with file** and **Save** ([update a dashboard from a file](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create#update-or-restore-an-existing-dashboard-from-a-file)).

## Check the data

`Test-DemoRealTimeDashboardData` proves that the tiles populate, without a person: it runs each tile's KQL, read-only, against the telemetry endpoint, and reports one record per tile (`FABRIC.DASHBOARD.TILE.<PAGE>.<TILE>`) and a summary (`FABRIC.DASHBOARD.DATA`). It's the deploy step that `deploy.ps1`'s Fabric track can run unattended after the subscription guard, and `configure-fabric.ps1` runs it after an import, or alone:

```powershell
./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -CheckDashboardData   # no import, no workspace needed
```

- **The same queries the dashboard runs:** from the rendered definition, which the read-back proved identical to what Fabric stores, with the dashboard's parameters bound the way the dashboard binds them: the time range to the last 24 hours (`-LookbackHours`), and **Target** to "Select all". Each query runs once, through `Invoke-DemoHubTelemetryQuery`: the telemetry endpoint and `ArcSqlTelemetry`, with a Kusto token from `Get-DemoAccessToken` for the configured subscription's account ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)).
- **Pass:** the tile's query returns rows, with every column the tile shows: its x, y, series, and value columns, and the columns its conditional formatting reads. The status tiles also list each target's state, such as `T3 No data`.
- **Warning:** the query returns no rows, and neither does a probe of the tile's own source (its telemetry table with the tile's own filters and time window, for the demo's targets), so there was nothing to show. The message says when that's because the VMs aren't running right now, with each VM's power state and T3's status; Phase 20's end-to-end run checks those tiles again after a start. Also a **Warning:** the endpoint was throttled or unavailable after retries.
- **Fail:** a tile is empty although its source has rows in the window, it gets rows without a column it shows, or the endpoint rejected the query, the token, or the caller's access.
- **What it doesn't prove:** how Fabric draws a tile. No documented API renders one; the check covers the definition (the read-back) and the data (the queries).

## The Database Hub template wizard, for comparison

Database Hub's **Performance** page has **Create SQL monitors from template**, which builds a Real-Time Dashboard, or a page in an existing one, in a workspace you pick ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)). It's UI-only, with no API ([automation support matrix](../../docs/automation-support-matrix.md), row 34). The 30-minute walkthrough runs it live, then opens this dashboard: "the same telemetry, governed and versioned" ([walkthrough, beat 5](../../docs/demo-walkthrough.md#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code)). The two can live side by side; `destroy.ps1` removes neither, because it doesn't touch Fabric items.

## Live results (2026-10-21)

With the coordinator's go-ahead, after Phase 13's subscription guard (`PREFLIGHT.GUARD.CONTEXT` **Pass**), from 20:36 to 21:15 UTC:

| Step | Result |
|---|---|
| `-ImportDashboard -WhatIf` | `FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW` **Not selected**: four planned requests, none sent |
| `-ImportDashboard` | `FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW` **Pass**: created (52,477 bytes), in 35 seconds with the guard |
| Read-back | `FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW` **Pass**: the parts `RealTimeDashboard.json` and `.platform`, and every field identical to what was sent, including schema version 52. Fabric stores the JSON with CRLF line endings and no final newline, so only the bytes differ |
| Tile data, last 24 hours | `FABRIC.DASHBOARD.DATA` **Pass**: 14 of 14 tiles get rows (12 queries), with every column they show; the three targets had reported earlier that day |
| Tile data, an empty window (a diagnostic) | A window from before the deployment: 12 tiles **Warning**, each with its source probe empty and the live states (both VMs deallocated, T3 paused), and the 2 status tiles **Pass** with `No data` for every target |
| Viewer licensing (`-SkipNotebookImport -SkipTelemetry`) | `PREFLIGHT.FABRIC.VIEWERLICENSE` **Warning**: F16, smaller than F64 (from `FABRIC.P5.CAPACITY`) |
| `-CheckDashboardData`, the deploy-step path (21:14 UTC) | 16 **Pass**: the guard, the 14 tiles, and `FABRIC.DASHBOARD.DATA`, in 61 seconds |

The item ID is only in `out/`, which Git ignores. Phase 20's end-to-end run repeats the data check after a start.

## Limitations

- **Schema version:** the definition uses schema version 52, the version in Learn's KQL dashboard definition example. Newer versions exist (89 on 2026-10-21). Fabric accepted 52 on import and stores it unchanged (2026-10-21); saving in the editor can still upgrade the stored definition. Move the pin in `config/versions.json` only after an import and read-back.
- **Not checked by a program:** how Fabric draws the tiles, the data source's connection with each viewer's identity in the browser, and how Fabric applies `autoRefresh` next to its newer [live refresh](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-live-refresh). The data check runs the same queries against the same endpoint; no documented API renders a tile.
- **Refresh:** live refresh relies on ingestion detection, which may not apply to the proxy; the dashboard sets a fixed one-minute refresh instead. Telemetry still arrives a few minutes after the activity, and its retention is 7 days or less.
- **One instance per target:** the shared counter-delta body adds up the series of a target, so the batch-request rate is exact for one SQL Server instance per target, which is the demo's layout.
- **T3 storage latency** is empty: per-file IO latency from the telemetry isn't supported for Azure SQL Database.
- **Pass-through only:** a viewer without Reader on the subscription sees empty tiles, not an error; the Estate pulse page shows **No data**.

## Sources (checked 2026-10-21)

- [KQL dashboard item definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition): the `RealTimeDashboard.json` part, `InlineBase64`, and the schema version 52 payload example
- [Create a Real-Time Dashboard](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create): prerequisites, the Azure Data Explorer data source, pages, live refresh, the exported JSON and its `$schema`, and **Replace with file**
- The published dashboard JSON Schema for version 52: `https://dataexplorer.azure.com/static/d/schema/52/dashboard.json`, with `tile.json`, `query.json`, `parameter.json`, and `baseQuery.json` beside it (linked, not copied)
- [Use parameters in Real-Time Dashboard queries](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-parameters), [Customize Real-Time Dashboard visuals](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-visuals-customize), [Apply conditional formatting](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-conditional-formatting), [Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions), [Live refresh](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-live-refresh)
- [Items - Create KQL Dashboard](https://learn.microsoft.com/rest/api/fabric/kqldashboard/items/create-kql-dashboard), [Get KQL Dashboard Definition](https://learn.microsoft.com/rest/api/fabric/kqldashboard/items/get-kql-dashboard-definition), and the generic Items APIs above
- [Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql): **Create SQL monitors from template**, and the proxy connection URI; [Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)
- [Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry): the schema, the rules for correct results, and the sample queries
- [Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses): Real-Time Dashboards aren't in its list of Power BI items, so the F64 viewer rule doesn't apply to them
