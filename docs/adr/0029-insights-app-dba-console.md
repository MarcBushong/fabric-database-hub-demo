# ADR 0029: The Insights app as a DBA console

- **Status:** Proposed (2026-11-18). The design system, the information architecture, the live data, and Manage, both its copy mode and its sending mode (the function `manage.ts` and its deploy-time settings), are built and tested; Manage's sending mode is confirmed live once [the identity proof](#validation) passes.
- **Date:** 2026-11-18
- **Decision source:** User-directed (2026-11-18): "Adjust the Fabric Rayfin App to really be a DBA's dream app to manage and view their estate with the conversational analytics", "more professional, and functional and clean/modern", and "The GitHub Copilot chat interface right in the App is a must and a gamechanger"; "Make sure to account for users signing in and demoing this themselves and repeatable. Simple and one click as possible". The coordinator decided Manage's write path for the user: A, with C as the automatic fallback, under the conditions [below](#manage-bounded-confirmed-actions).
- **Related:** [ADR 0012](0012-validation-model.md) (statuses), [ADR 0020](0020-on-demand-activity-control.md) (the control), [ADR 0026](0026-one-run-all-session.md) (one Run all), [ADR 0025](0025-t4-read-replica.md) (T4's history), [ADR 0013](0013-agent-experience.md) (the Database Agent first), [the app's README](../../fabric/app/README.md)

## Context

- **Before:** the Insights app (Phase 19b, `APP_DatabaseHub_Insights`) was a read-only showcase over the history model: five pages under a top tab bar, a dark "glass" theme with web fonts, eight decorative d3 visuals with motion, and a label that said "History, not live". It answered "what does the history look like", not "what needs my attention, and what do I do about it".
- **Database Hub became generally available on 2026-11-17** ([overview](https://learn.microsoft.com/fabric/database/hub/overview)), with Overview, Optimization, the real-time dashboards, and the Database Agent loop, which the demo now shows in every Run all ([ADR 0026](0026-one-run-all-session.md), the agent loop's beat). The app had to sit next to that as a DBA's console, not a gallery.
- **The app runs inside Fabric's item frame** on a laptop screen, often with a chat panel beside it, and it's a [Fabric Apps (preview)](https://learn.microsoft.com/fabric/apps/overview) item: React and Vite on the Rayfin SDK, signed in through Fabric, with connectors and functions as its only backend.
- **Anyone who deploys the demo demos it themselves,** repeatably, with no per-user setup.

## Decision

### The design system: Fluent 2

The app uses [Fluent UI React v9](https://react.fluentui.dev/) (`@fluentui/react-components` 9.75.2 and `@fluentui/react-icons` 2.0.346, MIT, pinned exactly):

- **Why Fluent 2:** it's the design language of Microsoft Fabric and Microsoft 365, so the app reads as part of Fabric, not as a third-party site. It brings accessible components (tab lists, menus, dialogs, tables, tooltips, message bars, spin buttons) with keyboard support and ARIA built in, and light, dark, and high-contrast themes from tokens. It supports React 19, and its license passes `npm run check:licenses`.
- **Alternatives:** Material UI and Ant Design look foreign in Fabric. Tailwind with a headless kit (Radix, shadcn) would mean building accessibility and theming ourselves. Keeping the custom CSS would keep the "glass" look the user asked to replace.
- **Themes:** light, dark, and high contrast, from a Fabric-teal brand ramp (`#117865` at 80). The app follows the system until the viewer picks one, and every status, target, and chart color keeps 4.5:1 (text) or 3:1 (marks) on each surface (`src/lib/app.test.ts`).
- **One chart language:** `src/visuals/ChartView.tsx` draws every chart, the app's and the Copilot dock's `show_chart`, from a `ChartSpec`: line, area, bar, stacked bar, scatter, table, and KPI, with the app's annotations (incident bands, thresholds, markers), keyboard reading, and labels that fit a narrow frame. The decorative visuals (constellation, activity clock, ridgelines, Sankey, rings) are gone; the incident replay stays, restyled.
- **No web fonts:** Segoe UI from the system, like Fabric. Framer Motion, lucide, d3-sankey, and d3-hierarchy are removed.

### The information architecture: what a DBA asks, in order

Left navigation (with a rail mode), a global target and period filter, and drill-down from the estate to an engine, a target, and an incident:

| Page | What it answers |
|---|---|
| **Overview** | What needs attention now: Database Hub live (resources, high usage, security warnings, Cosmos DB), then the history (each target's health, incidents, findings, readiness, the last session). On the first run, the one action that fills it: Run all in NB_DatabaseHub_Control |
| **Estate** | Every engine and target: SQL Server on an Azure VM (T1), Arc-enabled SQL Server (T2), Azure SQL Database (T3), PostgreSQL (T4) with its read replica, and Azure Cosmos DB (T5) when present; each target's page |
| **Performance** | CPU, waits, throughput, and their distribution, per target and engine |
| **Incidents** | The timeline, the replay, what changed, the Database Agent loop on T3 (detect, evidence, respond, verify), and prompts for the agent |
| **Findings** | Performance, availability, security, optimization, capacity, and telemetry: security and optimization live from Database Hub, the history's findings beside them. **Ready to migrate** (2026-11-18, the coordinator's decision): T2's readiness per Azure SQL target from Database Hub's inventory, on Optimization and on T2's page, because Database Hub doesn't raise a ready assessment as an issue; without the live source, a link to T2's instance in the Azure portal, built at deploy time from its resource ID |
| **Readiness** | Is the demo ready, and the next step |
| **Trends** | The history past the telemetry's 7 days, week over week |
| **Manage** | Bounded, confirmed actions through the demo's own control |
| **Live views** | Database Hub, the real-time dashboards, and the history report |

Every visual and table has **Ask Copilot**, and every anomaly **Ask why**: both hand the in-app Copilot the title, the rows (at most 200), and the DAX or the Database Hub API calls behind them (`src/copilot/contract.ts`). The chat, its GitHub sign-in, and its tools are documented with their code ([the app's guide](../../fabric/app/README.md#copilot-in-the-app)).

### History and live, said everywhere

- **History** is the lakehouse through `SM_DatabaseHub_History` and the read-only `history` connector, as the viewer. **Live** is Database Hub's own read-only routes through the app's function (`src/copilot/estate.ts`, the chat session's), scoped to the demo's resource groups and cached for a minute.
- Every visual says which it shows: **History** with the newest snapshot's age, **Live, as of** a UTC time with its API calls, or **Sample data** in the local preview. When the live source isn't there, a page says why in one line and shows the history.
- The data layer (`src/data/query-client.ts`) takes any `DataSource`, so a live source plugs in without changing a page.

### Manage: bounded, confirmed actions

Run all in NB_DatabaseHub_Control stays the demo's one action ([ADR 0026](0026-one-run-all-session.md)); the app's actions come in addition to it and do the same things: start a session, run an incident on a target, stop now, and reset.

- **Every action** says what it does and what bounds it, shows the control request, and asks for confirmation. Values outside the control's allow-lists and caps can't be confirmed (`src/lib/control.ts`, tested against `scenarios/*/scenario.json`): healthy-baseline runs as the control's `baseline`, and a run lasts 5 to 120 minutes, at most its scenario's own maximum.
- **No secret in the browser:** the control's webhook URL stays in Key Vault, read by the control notebook. The app never sees it.
- **A, sending (decided by the coordinator, 2026-11-18):** the app's function `manage.ts`, in the shared functions project, runs NB_DatabaseHub_Control through the Fabric job API ([Run on demand Item Job](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job), `jobType=RunNotebook`, [notebook APIs](https://learn.microsoft.com/fabric/data-engineering/notebook-public-api)) with the request's parameters. Its conditions:
  1. The caller's identity comes only from the Rayfin runtime: the caller's Rayfin token, which the app backend checks before any function runs (no token: 403; a forged one: 401) and the function checks again against the app's own JWKS, at the app's API pinned at deploy time, and binds to this app: its tenant (`tid`, or the tenant in Fabric's managed token's subject path) and this app (an audience of the app's ID or API, or Fabric's subject path and `xms_attr` for this app), all from the deployment record, and its exact issuer and audience once the identity proof shows them. Nothing the browser sends names the caller.
  2. Operators are the deployer and the members of the demo's admin group, which `deploy.ps1` resolves into the app's settings at every deploy; when it can't read the members, the deployer only, with a **Warning**. A token with an object ID (`oid`) matches on it only; names, which can change, count only in a token without one. A verified viewer who isn't an operator sees Manage read-only, with the reason.
  3. Only the documented actions and values, checked against the control's own catalog, which the deploy writes from the same runbook settings as the notebook's `CATALOG_JSON` (its targets, T5 only while it's on, its incidents, and a run's and a session's minutes); REQUESTED_BY is the verified identity.
  4. Sessions run with `WAIT_FOR_END = True`, like Run all. The control takes one request at a time and follows a session that's running instead of starting another, so while one of its runs is in progress, Manage offers only Stop now, which cancels that run first ([Cancel Item Job Instance](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/cancel-item-job-instance)): on a small capacity, the stop couldn't start until that run ended. After each start, Manage follows the run's real state ([Get Item Job Instance](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/get-item-job-instance)), its failure included.
  5. Whenever the function can't send for anyone (it isn't set up, it can't confirm the caller, or the job API refuses or can't be reached), copy mode takes over, with the reason: Run all sends the same request.
- **How A is built (2026-11-18, the owner asked that everything be completed on the current assumptions):**
  - **The function:** `manage.ts` registers `manageAccess`, `manageRequest`, and `manageJob` with `registerManage(udf)` in the shared functions project; their checks and answers are in `manage-core.ts`, which the app's tests run. The caller's token is `ctx.accessToken`, verified again with the app's keys at the API pinned at deploy time; the job API call uses the Fabric token the runtime mints for the function (`ctx.Tokens.Fabric`, the app item's owner's, as the live estate function uses it). The job API's answer, a refusal included, comes back as a sentence; nothing is retried.
  - **Its settings:** `configure-fabric-app.ps1` writes `manage.generated.ts` into the deploy stage: the app's API and IDs (the deployment record's `fabricApiUrl`, `fabricTenantId`, `fabricWorkspaceId`, and `fabricItemId`), `NB_DatabaseHub_Control`'s IDs, the operators (`FABRIC.APP.OPERATORS`), and the control's catalog, never a secret. The record holds no issuer or audience (Rayfin keeps them "managed internally by the backend"), so those two pins stay empty until the identity proof shows them. The app's first `rayfin up` records its API, so a first deploy writes the settings again and deploys once more, about a minute, once. `FABRIC.APP.ACTIONS` says which way Manage works.
  - **The control:** `NB_DatabaseHub_Control` has a `REQUESTED_BY` parameter, `"notebook"` for Run all, which the job API sets to `app/<who>`; every request it builds carries it, within the runbook's name rule.
  - **Its fallback:** the function hands over to copy mode (C), with the reason, whenever it can't send for anyone; viewers it verified who aren't operators see Manage read-only. A request the job API refused stays in its dialog, now copied for Run all.
  - **Reviewed (2026-11-19):** an independent review of the server side found no way for an unverified caller or a non-operator to start a job, and asked for four fixes, all in: the token's binding to this app and `oid`-only matching; copy mode on the function's own failures; the control's own catalog, with healthy-baseline as `baseline`, and the run's real state; and Stop now cancelling the control's run first, with the wording about a session that's running corrected.
- **C, copying (the automatic fallback):** when the function isn't deployed, each action copies its request as lines for a new cell under the control notebook's parameters cell, and opens the notebook, where Run all sends it with the same checks.

## Consequences

- **Easier:** a DBA starts at what needs attention, drills from the estate to a target and an incident, asks Copilot about what's on screen, and acts from the same app, all inside Fabric's frame and in the theme they use.
- **Harder:** the app depends on Fluent's releases (pinned, with the license check), and the bundle grew: about 410 KB gzip in all, from about 245 KB, far under Fabric Apps' limits. Pages load lazily.
- **Accepted:** until the identity proof passes, Manage's sending mode rests on two assumptions: that a caller's Rayfin token names them by an Entra object ID or a sign-in name, and that `ctx.Tokens.Fabric` may run the control notebook. If either fails, only `manage.ts` and `manage-core.ts` change, and copy mode keeps working meanwhile.

## Validation

- **Built and tested (2026-11-18):** `npm run verify` (typecheck, lint, Vitest's unit, page, chart, and contrast tests, the license check, and the build); the deploy-time check runs every catalog query (`FABRIC.APP.QUERIES`); before-and-after screenshots of every page in light and dark from the sample-data preview.
- **The identity proof (pending):** a probe app with functions in a test workspace deployed and ran on the shared capacity: `rayfin up` with `services.functions` succeeded, and the backend refused an anonymous call (403) and a forged token (401). What a function sees of a signed-in caller needs one person in a browser, since no script can create an app session (the external Entra exchange refuses the Azure CLI's tokens). Until it passes, sending is built and tested but not seen live.
- **Manage's function, tested (2026-11-18):** Vitest runs `manage-core.ts`'s answers against a stand-in for the app's keys and the job API: a forged or expired token, a viewer who isn't an operator, and an action or value outside the caps are refused before any Fabric call; the job API's refusal, an unreachable API, and a missing Fabric token each come back as a reason; an incomplete deployment falls back to copy mode. `manage.ts` compiles with the SDK beside the live estate function, and the SDK's own parser registers its three functions with their context. Pester covers the settings writer, the first deploy's second `rayfin up`, and `REQUESTED_BY` in the control notebook.

## Sources

Checked 2026-11-18.

- [Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview), [hosting](https://learn.microsoft.com/fabric/apps/hosting), [connectors](https://learn.microsoft.com/fabric/apps/connectors), [Fabric authentication](https://learn.microsoft.com/fabric/apps/fabric-authentication)
- [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)
- [Manage and execute Fabric notebooks with public APIs](https://learn.microsoft.com/fabric/data-engineering/notebook-public-api) and [Job Scheduler - Run On Demand Item Job](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job)
- [Fluent UI React v9](https://react.fluentui.dev/)
