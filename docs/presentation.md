# Presentation surfaces

How to present the demo, and to whom. Four surfaces show the same SQL estate: two live views, a history report, and a Fabric app. This page says what each one is, when to use it, and what a viewer needs. The scripts are in the [demo walkthrough](demo-walkthrough.md).

> **Preview disclosure:** Database Hub, its telemetry endpoint, and the Database Agent are previews ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)). The live views can change with them; the history report reads only what the demo saved.

**Status (2026-10-22, Phases 18 and 19):** Database Hub and the Real-Time Dashboard are ready: the dashboard is imported, read back, and every tile gets data ([its guide](../fabric/realtime/README.md#live-results-2026-10-21)). The Power BI report and its semantic model deploy by script with `configure-powerbi.ps1` ([the history report's guide](../fabric/powerbi/README.md)). The Fabric app is a separate item: a Fabric Apps (preview) item built with the Rayfin SDK and CLI (Phase 19b).

**Status (2026-10-22, Phase 19b):** the Insights app `APP_DatabaseHub_Insights`, a [Fabric App (preview)](https://learn.microsoft.com/fabric/apps/overview) over the same history model, deploys by script with `configure-fabric-app.ps1`, and every query it runs returned rows through its connector. Opened from its workspace item, the first build passed the owner's browser check ("Connector check passed"); the full app's browser check is the remaining manual step ([its guide](../fabric/app/README.md)).

## The four surfaces

| Surface | What it is | Needs |
|---|---|---|
| [Database Hub](https://powerbi.com/workloads/fdh/databaseHub) | The live view: a Fabric portal page, not a workspace item | A Fabric Free license, no capacity, Azure read access |
| [Real-Time Dashboard](../fabric/realtime/README.md) | The live view, as code, in the workspace | Capacity; viewers need Azure read access to the targets through the telemetry endpoint |
| [Power BI report](../fabric/powerbi/README.md) | History over lakehouse snapshots: `RPT_DatabaseHub_History`, four pages (Phase 19) | Viewers on F16 need Pro or PPU |
| [Fabric app](../fabric/app/README.md) | History again, as a custom app: the Insights app `APP_DatabaseHub_Insights`, a Fabric Apps (preview) item built with the Rayfin SDK and CLI over the report's semantic model, `SM_DatabaseHub_History`, with its own visuals, insight cards, DAX and CSV export on every visual, and ready-made Database Agent prompts (Phase 19b) | Access to the app item; Read and Build on the history model |

- **Live means the telemetry endpoint:** samples arrive a few minutes after the activity, and retention is 7 days or less ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). Database Hub and the Real-Time Dashboard query it with each viewer's own identity, so two viewers can see different resources.
- **History means the lakehouse:** the notebooks write the demo's history to five Delta tables in `LH_DatabaseHub`: validation results, scenario requests, telemetry snapshots, findings, and incident windows ([Fabric assets](../fabric/README.md#delta-tables-in-lh_databasehub)). These tables keep the history past the telemetry's retention. The Power BI report reads them through a Direct Lake semantic model, so it shows what the notebooks saved, not live data, and every page is labeled as history.

## When to use which

| Situation | Use | Why |
|---|---|---|
| A customer demo of the product | **Database Hub**, with the walkthrough's beats | It's what the customer will use, it's free, and it needs no capacity |
| Showing that monitoring can be governed and versioned | **The Real-Time Dashboard**, right after Database Hub's template wizard (the 30-minute walkthrough) | "The same telemetry, governed and versioned": the dashboard's definition and KQL live in Git, are tested, and are imported through a documented API |
| A cockpit on a second screen during an incident | **The Real-Time Dashboard**, Incident page, with **Target** set to the incident target | Status numbers, side-by-side charts, and a one-minute refresh |
| A review of earlier sessions, past the 7-day retention | **The Power BI report** (Phase 19) | It reads the lakehouse snapshots |
| An audience that explores on its own after the session | **The Power BI report**, shared with them (Phase 19), or **the Fabric app** (Phase 19b) | Mind the viewer licensing below |
| Showing what can be built on the same data, or taking the data out (the DAX, CSV) | **The Fabric app** (Phase 19b), opened from its workspace item | Custom visuals (constellation, incident replay, readiness rings), rule-based insights, and every visual's query and data one click away |
| The Fabric capacity isn't running | **Database Hub**, plus the walkthrough's PowerShell telemetry tables | Neither needs the capacity |

A presenter who shares their screen needs only their own access, whatever the audience's licenses.

## Licensing and permissions

The rule for Power BI content, from Microsoft Learn: "On F SKUs smaller than F64, each user viewing Power BI content must have Pro, PPU, or an individual trial. On F64 or larger, users with only a Free license and a viewer role can view Power BI content" ([Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses)). Learn lists the Power BI items: reports, semantic models, (Power BI) dashboards, paginated reports, scorecards, metric sets, dataflows, datamarts, org apps, and explorations; everything else, including notebooks, lakehouses, and Real-Time Dashboards, is a non-Power BI Fabric item, which a Free license can view and share on an F capacity. The capacity that the demo workspace uses is an F16 (2026-10-21), so viewers of the report need Pro or PPU (optional prerequisite [P11](prerequisites.md#optional)). The Fabric app (Phase 19b) has its own row below.

| Surface | License to view | Azure access | Fabric access | Capacity |
|---|---|---|---|---|
| Database Hub | Fabric Free | Reader on the subscription; for T2's performance data, Reader-only users also need the Arc telemetry role on the demo resource group (P8) | The tenant setting (P4), and My workspace on a capacity outside North Europe and West Europe | None |
| Real-Time Dashboard | Fabric Free: it isn't Power BI content | The same as Database Hub: the dashboard queries the telemetry endpoint as the viewer (pass-through) | A workspace role, or the dashboard shared with them | The workspace's Fabric capacity |
| Power BI report (Phase 19) | Pro, PPU, or an individual trial below F64; Fabric Free and a viewer role on F64 or larger | None: it reads the lakehouse | A workspace role, or the report shared with them | The workspace's Fabric capacity |
| Fabric app (Phase 19b) | Learn doesn't list a Fabric App item as Power BI content, but its data comes from the semantic model as the viewer; plan for the report's rule until that's verified, TODO(verify) | None: it reads the lakehouse through the model | Access to the app item; Read and Build on `SM_DatabaseHub_History`; the tenant settings Fabric Apps (preview) and Dataset Execute Queries REST API | The workspace's Fabric capacity |
| A presenter sharing their screen | Their own | Their own | Their own | As for the surface shown |

- **Azure access:** the telemetry endpoint returns rows only for resources the caller can read: Reader or higher on each subscription, and `Microsoft.Sql` registered ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). Contributors already have it. For others, `Set-DemoPresenterAccess` assigns Reader and the Arc telemetry role (**Azure Hybrid Database Administrator - Read Only Service Role**), or prints the commands ([permissions](permissions.md#presenter-access)).
- **Dashboard access isn't data access:** sharing the Real-Time Dashboard doesn't grant access to the telemetry; a viewer without Reader sees empty tiles ([Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions)).
- **The check:** `preflight.ps1` and `configure-fabric.ps1` report `PREFLIGHT.FABRIC.VIEWERLICENSE`: a **Warning** with this rule when the workspace's capacity is smaller than F64 or its SKU can't be read, and **Pass** on F64 or larger. It reads the SKU with Get Workspace and List Capacities, and never changes the capacity ([ADR 0012](adr/0012-validation-model.md#phase-18-presentation-checks-2026-10-21)).

## Cost

- **Database Hub** is free and needs no capacity ([Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq)).
- **The Real-Time Dashboard, the report, the app, and the notebooks** are Fabric items, so they need the workspace's capacity running. The shared capacity runs at the owner's choice, bills while it runs, and is outside the demo's resource group: it isn't in `estimate-cost.ps1`, and it's outside the demo's $250-a-month ceiling ([ADR 0016](adr/0016-cost-profiles.md)). Never pause or resize it for a demo; ask the owner.
- **Licenses** for viewers below F64 (Pro, PPU, or a trial) are per-user costs outside Azure. This page quotes no prices.
- **The Fabric app** (the Insights app, Phase 19b) runs as Fabric Apps services that consume the workspace capacity's units ([Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview)); it has no database, storage, or functions, so it uses capacity only while someone loads it and its queries run.

## The template wizard and the dashboard as code

Database Hub's **Performance** page has **Create SQL monitors from template**: it builds a Real-Time Dashboard, or a page in an existing one, in a workspace you pick, and you customize it there ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)). It's UI-only, with no API ([automation support matrix](automation-support-matrix.md), row 34). The repo's dashboard is the governed counterpart: the same telemetry, with its definition and KQL in Git, tested, and imported and read back through documented Fabric REST APIs. The 30-minute walkthrough shows both, one after the other ([beat 5](demo-walkthrough.md#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code)).

## The Fabric app (Phase 19b)

The demo's Fabric app is the Insights app, `APP_DatabaseHub_Insights`: a [Fabric Apps](https://learn.microsoft.com/fabric/apps/overview) (preview) item built with the Rayfin SDK and CLI. Fabric hosts it and signs users in to it, and its one read-only connector to `SM_DatabaseHub_History` runs DAX as the signed-in user. Phase 19 keeps the model's table, column, and measure names stable for it. It's history, like the report, but it looks and works differently: an estate constellation, an activity clock, ridgelines, an incident replay with a scrubber, a before-and-after spotlight, a wait flow, and readiness rings, with insight cards and a "show the DAX", data table, and CSV download on every visual ([its guide](../fabric/app/README.md)).

- **History versus live:** like the report, it shows what the notebooks saved; its Live links page opens Database Hub, the Real-Time Dashboard, and the report in a new tab.
- **From history to the Database Agent:** the Incidents page has **Investigate with the Database Agent** for every incident window (a robot button on each window and **Ask the agent** on the replay), and Estate and Readiness have a small prompt library (estate health, the top waits per target, blocking chains, and what changed since the baseline). Each prompt is written from the data on screen, for example "On T2 (Arc-enabled SQL Server arcsql01) between 14:05 and 14:35 UTC on 2026-10-22, Buffer IO (PAGEIOLATCH) waits peaked at 11.5 s per 5-minute bin and averaged about 4 times the baseline …". The agent is UI-only, so the presenter selects **Copy and open Database Hub** on a prompt (it copies the prompt and opens Database Hub in a new tab, in the demo's tenant) and pastes it into the Database Agent. The panels say what matters on stage: the agent is a preview; it proposes actions, and each one runs only after an explicit approval in Database Hub ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq)); and the app only investigates, it never runs anything. Follow the [presenter rules](../fabric/agent/README.md#use-it-safely-approval-rules-for-presenters): read a proposal aloud, then cancel it. A switch rewrites the same questions for the fallback, GitHub Copilot CLI or VS Code with the `microsoft-sql-fdh` and `microsoft-sql` plugins ([agent guide](../fabric/agent/README.md)).
- **Open it from its workspace item.** It runs embedded in the item page and signs in by itself. Opening its hosted URL directly is a known preview limitation (the sign-in pop-up stops at "Page not accessible directly"), so don't share that URL; share the workspace item.
- **How it's deployed:** `./scripts/configure-fabric-app.ps1`, after `configure-powerbi.ps1`, unattended and idempotent, with `npx rayfin up` from a Git-ignored stage. It needs a one-time sign-in of the Rayfin CLI by the operator (`rayfin login`; the CLI's service principal sign-in isn't supported yet), the workspace's capacity Active, and the tenant setting Fabric Apps (preview).
- **In the walkthrough:** use it after the report, to show that the same governed model feeds a custom experience, and to take a visual's DAX or data out live. During an incident beat, its prompts are a fast way into the Database Agent: pick the window, select **Copy and open Database Hub** on **What caused it**, and paste it into the Database Agent.

The org app that the report spec planned was dropped on 2026-10-22.

## Sources (checked 2026-10-21)

- [Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses): the F64 viewer rule, Power BI and non-Power BI items, and Trial and P capacities
- [Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql) and [Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor): the template wizard and the proxy connection
- [Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry): access, latency, and retention
- [Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions) and [Create a Real-Time Dashboard](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create)
- [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview) and [FAQ](https://learn.microsoft.com/fabric/database/hub/faq)
- [Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview), [connectors](https://learn.microsoft.com/fabric/apps/connectors), [hosting](https://learn.microsoft.com/fabric/apps/hosting), and [Fabric authentication](https://learn.microsoft.com/fabric/apps/fabric-authentication) (checked 2026-10-22)
