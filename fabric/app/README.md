# Database Hub Insights: the Fabric App (preview)

`APP_DatabaseHub_Insights` is the demo's DBA console: a [Fabric app](https://learn.microsoft.com/fabric/apps/overview) where a DBA sees what needs attention across the estate, drills from the estate to a target and an incident, asks Copilot about what's on screen, and acts through the demo's own session control ([ADR 0029](../../docs/adr/0029-insights-app-dba-console.md)). Fabric Apps is a **preview**.

It reads two sources and says which one every visual shows:

- **History:** the lakehouse history (`LH_DatabaseHub`), which `NB_DatabaseHub_LiveActivity` saves at each session's end, through the semantic model `SM_DatabaseHub_History` and the read-only `history` connector, as you. It keeps what Database Hub's 7 days of telemetry don't.
- **Live:** Database Hub's own view of the estate, which the app's functions item reads with the 8 read-only routes the GA Database Hub CLI skill (`databasehub-cli`) uses, as the app item's owner, scoped to the demo's resource group, and cached for a minute: the estate's resources, their health in the last 24 hours, and security warnings. Those routes aren't a public contract, so they're the repo's one exception to documented interfaces only ([ADR 0013](../../docs/adr/0013-agent-experience.md#amendment-2026-11-18-the-ga-skill-and-one-narrow-exception)). When the function isn't deployed, each page says why in one line and shows the history.
- **Not live yet (2026-11-19, R924):** Database Hub refuses the sign-in that Fabric gives the app's functions, so the app shows the history, and T2's migration readiness as Azure had it at the last deploy; Database Hub shows the live estate. Each live section says so in one line, never with an error code. The function still asks Database Hub on every read, so the live views come back by themselves once it accepts that sign-in. The status page's `FABRIC.APP.ESTATE` (**Not supported**) says the same.

## At a glance

- **What it is:** the item `APP_DatabaseHub_Insights` in the demo's Fabric workspace, with two user data functions beside it: its functions (the live estate and Manage) and its connector to the history model. Anyone with access opens it; operators also use **Manage** to start or stop a session, which bills like any session.
- **What deploys it:** `./scripts/deploy.ps1`, in its Fabric track (`configure-fabric-app.ps1`), on every run, with Ask's chat relay; there's nothing to set up in the app ([deploy](#deploy)). You never build the relay's image or run a GitHub Actions workflow: the image is public and pinned by digest in `config/versions.json` (`askRelay.image`), and the repository's workflows are optional, for maintainers ([the relay](../../ask-relay/README.md)).
- **What it costs:** the app runs on your Fabric capacity, and Ask's chat relay bills per second only while someone asks, then scales to zero about 10 minutes after the last question ([cost management](../../docs/cost-management.md#dated-example-asks-chat-relay-2026-11-18)). The Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan, which the chat runs on, are outside every estimate.
- **How a viewer signs in:** open it from its item in the workspace, which signs you in with your Fabric account ([open the app](#open-the-app)). For Ask, select **Sign in with GitHub** once per browser, enter the code on github.com, and authorize **Database Hub Insights Ask** with the GitHub account that has your Copilot plan ([the chat](#ask-copilot-the-chat-in-the-app)).
- **How to remove it:** `./scripts/destroy.ps1` deletes the demo's workspace with the app's three items, and the chat relay with the resource group ([update and delete](#update-and-delete)). Each viewer's GitHub authorization of **Database Hub Insights Ask** stays until they revoke it at <https://github.com/settings/applications> (**Authorized OAuth Apps**), and **Sign out of GitHub** in the chat's account menu clears a browser's sign-in.

## Demo it yourself

Anyone who deploys the demo demos it themselves, with nothing to set up in the app:

1. **Deploy:** `./scripts/deploy.ps1` deploys the app with everything else, and updates it in place on every run ([Deploy](#deploy)).
2. **Open it:** in the Fabric portal, open the demo's workspace and select `APP_DatabaseHub_Insights`. It signs you in with your Fabric account and opens on **Overview**.
3. **The first time,** before any session, Overview says **No history yet** and names the one action that fills it: **Run all** in `NB_DatabaseHub_Control`. Its **Live now** line says whether the app reads Database Hub live; today it doesn't (R924), and Database Hub itself has the live view.
4. **After a session,** every page shows it: the incidents, T3's Database Agent loop, T4's read replica lag, T5's throttling and recovery, the findings, and **Readiness**, which every Run all fills by running `NB_DatabaseHub_Deployment`'s read-only checks once its session runs. Each session adds to the history; reset (in Manage, or `RESET_NOW` in the control notebook) and the next Run all work the same way every time.
5. **Copilot:** select **Copilot** in the top bar, or **Ask Copilot** on any visual. The dock signs in to GitHub with your Copilot license the first time; its chip in the top bar shows your GitHub login and Copilot plan, next to your Fabric account.

**Accounts:** your Fabric account opens the app and runs its queries (it needs Read and Build on `SM_DatabaseHub_History`); your GitHub account, with a Copilot license, runs the chat. They're separate, and neither is stored in the app.

## Open the app

**Open it from its item in the Fabric workspace.** The app runs embedded in the item page and signs you in by itself with `initEmbeddedAuth` ([Fabric authentication](https://learn.microsoft.com/fabric/apps/fabric-authentication)). **Live views** shows **"✓ Connector check passed"** with the counts of validation checks, telemetry rows, and incident windows. That message proves sign-in, the connector, and your access to the model in one step.

Don't open the hosted URL directly. That's a known preview limitation: see [Known limitation: the hosted URL](#known-limitation-the-hosted-url).

Viewers need:

- Access to the app item (a workspace role, or the item shared with them).
- **Read** and **Build** on `SM_DatabaseHub_History`: the connector runs DAX as the signed-in user (delegated).
- The tenant settings **Fabric Apps (preview)** and **Dataset Execute Queries REST API** for them ([prerequisites](../../docs/prerequisites.md)).

## What's in it

A left navigation (it folds into a rail), a global filter (targets T1 to T5, and the period: latest day, 7 days, 30 days, all history, anchored to the newest telemetry day), and nine pages. All times are UTC.

| Page | What it answers | What's on it |
|---|---|---|
| **Overview** | What needs attention now | **Live now** from Database Hub, when the app can read it (not yet: R924, and it says so in one line): resources and any not up, high usage in the last 24 hours, security warnings, Cosmos DB's peak normalized RU and lowest availability. Then from the history: targets needing attention, incidents, findings, readiness, the newest snapshot and the last session, each target's health with its CPU sparkline, the newest incidents, and the worst findings |
| **Estate** | Every engine and target | Health tiles by engine, the inventory (sort, filter, CSV), and each target's page: T1 to T3 (CPU with incident bands and **Ask why** on its peak, waits, sessions, findings; on T2, **Ready to migrate**), T4 and its read replica (Read replica lag, CPU, connections), and T5 (normalized RU with the throttled intervals shaded and the 100 % line, requests and 429s, gateway latency, the recovery) |
| **Performance** | Where the time goes | A signal per target (CPU, waits, sessions, IO), wait categories, each target's distribution, and a heatmap of the UTC hours |
| **Incidents** | What happened, why, and what fixed it | The timeline, the replay (every signal bin by bin, with steps and speeds), what changed (waits before and during), **the Database Agent loop** on T3 (detect, evidence, respond, verify, from the session's `database_agent` finding: T3's CPU before and after the response), every incident window, and the Database Agent prompts |
| **Findings** | What the analyses found, by category | Performance, availability, security, optimization, capacity, and telemetry. **Security** and **Optimization** read Database Hub live when the app can (warnings first, then recommendations, each named with the demo's target); the history's findings stay beside them. **Ready to migrate** (2026-11-18): `arcsql01`'s readiness for Azure SQL Managed Instance, SQL Server on Azure Virtual Machines, and Azure SQL Database, with when it was assessed, and **Ask Copilot** with "Which of my servers can move to Azure, and to what?". It comes from Database Hub's inventory when the app reads it live; otherwise (today, R924) from the assessment as Azure had it at the last deploy, with that time and the recommended tier and size: `configure-fabric-app.ps1` reads `properties.migration.assessment` of `arcsql01`'s SQL Server instance resource, a documented Azure Resource Manager read, into `dbhub-app.json`, and every `./scripts/deploy.ps1` reads it again. Database Hub doesn't raise a ready assessment as an issue, so its issue lists don't show it. Before the first assessment uploads, the card links `arcsql01` in the Azure portal, whose **Migration**, **Assessments** page has it |
| **Readiness** | Is the demo ready, and what's next | The latest validation run worst first, with each check's next step and documentation. Every Run all fills it: once its session runs, `NB_DatabaseHub_Control` runs `NB_DatabaseHub_Deployment`'s read-only checks; before the first session, it says so |
| **Trends** | What changed past 7 days | The history per UTC day and target, week over week |
| **Manage** | Act on the demo | Start a session, run an incident on a target, stop now, reset: each bounded and confirmed ([Manage](#manage-bounded-confirmed-actions)) |
| **Live views** | Where the live view is | Database Hub, the real-time dashboards, and the history report, in new tabs; the connector check |

**T4's and T5's history:** the notebook can't read Azure Monitor, so `./scripts/stop-demo.ps1 -SaveHistory`, `./scripts/deploy.ps1` at its end, and Run all's session end pass their metrics to `NB_DatabaseHub_LiveActivity` (analyses `postgresql` and `cosmosdb`). Their pages read the latest capture, whatever the filters, and say how a capture gets there when there's none. A deployment without Cosmos DB (`t5Enabled` off) shows no T5.

### Ask Copilot, and take the data out

Every visual and table has:

- **Ask Copilot:** opens the Copilot dock with the visual's title, its rows (at most 200), and the DAX behind them, or, for a live visual, its time; an anomaly has **Ask why**, which adds what's unusual about it.
- **The data as a table**, with sort, filter, **Download CSV**, and **Copy as CSV** (spreadsheet formulas are neutralized).
- **Show the DAX** and **Copy the DAX**, or for a live visual **Show the Database Hub API calls**.
- **Focus mode** (the visual alone; Esc closes it) and **Run the query again**.

The view (page, filter, drill-down, replay position) is kept in the frame's address and remembered per browser, since the portal's frame has no address bar of its own.

### Copilot in the app

The Copilot chat sits in a dock on the right: it resizes, goes full screen, and keeps its width. **Copilot** in the top bar opens it, and so does every **Ask Copilot** and **Ask why**. It answers from what's on screen and the tools it has, and draws its charts in the app's own chart language (`ChartView`). [Ask Copilot: the chat in the app](#ask-copilot-the-chat-in-the-app) has what it can do, its sign-in, and its states.

### Look and feel

- **Fluent 2** (`@fluentui/react-components`), Fabric's design language, in Fabric teal: **light**, **dark**, and **high contrast**. The app follows the system until you pick one in the top bar. Every status, target, and chart color keeps its contrast on each surface (`src/lib/app.test.ts`).
- Keyboard and screen readers: every control, tile, row, and chart is reachable with Tab and Enter; charts read their values with the arrow keys and announce them; status is never shown by color alone (each status has a shape and a word, ADR 0012).
- It fits Fabric's frame on a laptop screen: cards stack and tables scroll sideways when the dock takes room, and chart labels rotate or shorten (with the full name as a tooltip).

### Ask the Database Agent

Database Hub's Database Agent (preview) works only in Database Hub's UI and has no API, so the app writes ready-made prompts from the data on screen: copy one, select **Open Database Hub**, and paste it into the agent, or select **Ask Copilot** to ask the in-app Copilot instead. Incidents has each window's prompts (what caused it, what moved with it, against the baseline, the evidence), with the target and its resource name, the UTC window, and the window's own numbers; Estate and Readiness have a prompt library. Every prompt ends with the [prompt pack's](../agent/prompts/README.md) safety sentence ("Don't apply anything; propose only."), the panels say **Preview**, **the agent proposes; you approve each action**, and **investigation only: this app never runs anything**, and the **Copilot CLI · VS Code** switch rewrites the prompts for the documented fallback, GitHub Copilot CLI or VS Code with the GA Database Hub skill (`databasehub-cli`, in the `fabric-skills` plugin) and the `microsoft-sql` plugin ([agent guide](../agent/README.md)). Database Hub keeps 7 days of telemetry or less; for an older window the panel says the agent may not see it any more.

## Manage: bounded, confirmed actions

Run all in `NB_DatabaseHub_Control` stays the demo's one action ([ADR 0026](../../docs/adr/0026-one-run-all-session.md)); Manage's actions come in addition to it and do the same things:

| Action | What it does | The control's parameters |
|---|---|---|
| **Start a session** | What Run all does: starts every target, runs the showcase's incidents and T3's Database Agent beat, and stops everything at its end (30 to 120 minutes, 90 by default) | `MODE = "session"`, `DURATION_MINUTES`, `WAIT_FOR_END = True` |
| **Run an incident** | One scenario from the catalog on one target it applies to, within the scenario's maximum minutes, with the baseline beside it | `MODE = "activities"`, `ACTIVITIES`, `DURATION_MINUTES` |
| **Stop now** | Ends the session as its end would: saves the history, deletes T4's read replica, deallocates the VMs, stops T4, and deletes T5's container when T5's lifecycle is Session (with AlwaysOn, it stays). With no session running, it stops whatever runs and saves the last session's history, in case its end was cut off | `STOP_NOW = True` |
| **Reset** | Returns ContosoCare to its seed state on the running targets, and removes what a cut-off RU storm left on T5 | `RESET_NOW = True`, `RESET_TARGETS` |

Every action says what it does and what bounds it, shows the control request, and asks for confirmation; a value outside the control's allow-lists and caps can't be confirmed. No secret reaches the browser: the control's webhook URL stays in Key Vault, read by the control notebook. Manage works one of two ways, which the app finds out by itself:

- **Sending from the app** (when the app's Manage function, `rayfin/functions/src/manage.ts`, is deployed and set up): the function takes who you are only from your Fabric sign-in, never from what the browser sends, and sends only for operators: the deployer and the members of the demo's admin group, which `deploy.ps1` writes into the app's settings at every deploy (a redeploy refreshes the list; when it can't read the group's members, the deployer only, with a **Warning**). It runs `NB_DatabaseHub_Control` through the Fabric job API with the request's parameters, and the control records who sent it (`REQUESTED_BY`, `app/<you>`). It knows you by your Microsoft Entra object ID; only when Fabric's token has none does it match Fabric's sign-in email for this app, the one name it trusts until the identity proof ([ADR 0029](../../docs/adr/0029-insights-app-dba-console.md)). Everyone else sees Manage read-only, with the reason. The control takes one request at a time and follows a session that's running instead of starting another, so while one of its runs is queued or in progress, the function refuses every action but Stop now, and the page reads that run again when an action opens and after each start. Stop now cancels that run first: on a small capacity (F2 or F4), the stop couldn't start until it ended. It then waits for that run to end and asks again while the capacity refuses the stop, for up to 150 seconds; if the stop still doesn't start, it says it cancelled the run and that nothing is stopping the session now, and copies the request. If the run it cancelled was ending a session, the stop saves that session's history. After each start, the page follows the run's real state from the Fabric job API, a failure included. Whenever the function can't send (it isn't set up, it can't confirm who you are, or Fabric refuses the run), the request is copied for Run all instead, with the reason. The deploy writes the function's settings (the app's API and IDs, the control notebook's IDs, the operators, and the control's own catalog, never a secret) and says which way Manage works (`FABRIC.APP.ACTIONS`); an app's first deploy deploys once more, about a minute, because only then does it know the app's API. On a new environment, `deploy.ps1` puts the control notebook in Fabric only after its tracks, so it then runs the app's step once more, a few minutes, with the notebook's IDs and the API both (since 2026-11-19; before then, every new environment's Manage copied its requests).
- **Copying for Run all** (otherwise): each action copies its request as lines for a new cell under the control notebook's parameters cell and opens the notebook, where Run all sends it with the same checks.

**What the control ran** lists every session plan and activity request the notebooks recorded, newest first.

### Ask Copilot: the chat in the app

**Ask Copilot** opens a chat docked on the right, on the viewer's own GitHub Copilot ([ADR 0028](../../docs/adr/0028-ask-copilot-in-the-insights-app.md)): conversational analytics on the demo's history and its live estate, with the app's own charts.

- **What it can do:** run read-only DAX on `SM_DatabaseHub_History` through the app's delegated connector, as the viewer (`run_dax`; `EVALUATE` only, bounded rows); draw the result with the app's own `ChartView` (`show_chart`); read the live estate from Database Hub through the app's function (`estate_overview`); and suggest follow-ups. Every tool runs in the page; the model gets a guide to the model's names, never data.
- **Every answer** shows its source (**Show the source**: the DAX, or the Database Hub routes), and can be copied; **Export** saves the conversation as Markdown with every query, and **New chat** starts over. The conversation stays for the browser session.
- **From any visual:** **Ask Copilot** and **Ask why** pass the visual's title, rows, and DAX to the chat (`useCopilot().ask`, `src/copilot/contract.ts`).
- **Sign-in:** **Sign in with GitHub**, once per browser: the device flow through the shared OAuth App **Database Hub Insights Ask**, which the relay runs because GitHub's endpoints don't allow browser calls. The account line shows `GitHub: <login> · Copilot <plan>`, with **Switch GitHub account** and **Sign out of GitHub**.
- **What it needs and costs:** each viewer's own GitHub Copilot plan, outside every estimate. The relay bills per second only while someone asks and scales to zero about 10 minutes after the last question ([cost management](../../docs/cost-management.md#dated-example-asks-chat-relay-2026-11-18)). Its image is public and pinned by digest; you never build it ([the relay](../../ask-relay/README.md)).
- **Where it connects:** `public/dbhub-app.json`'s `ask` block, which `configure-fabric-app.ps1` writes in the stage: `relayUrl` (the relay, `ca-<prefix>-<environment>-ask`) and `estate` (the function is deployed). Without a relay, the dock says Ask isn't deployed, and the rest of the app works as before.
- **Its states:** Ask not deployed; the relay starting from zero (a cold start takes about 15 seconds); GitHub sign-in not set up; the sign-in card with its code; an account without Copilot; an organization that blocks the app; a sign-in that expired; and a turn that ended without an answer, which says "Copilot didn't write an answer" with **Retry** (R925).

## How it's built

| Part | Choice |
|---|---|
| Template | The Fabric Apps data app template, `microsoft/fabric-apps-analytic-templates` at commit `239b2c7` (MIT), recorded in `config/versions.json` (`fabricApp.template`) |
| Runtime | React 19 and Vite, the Rayfin SDK 1.36.2 (`@microsoft/rayfin-client`, `-auth-provider-fabric`, `-connector-fabric-semanticmodel`) |
| Design system | Fluent UI React v9 (`@fluentui/react-components` 9.75.2, `@fluentui/react-icons` 2.0.346, MIT), with the app's Fabric-teal light, dark, and high-contrast themes ([ADR 0029](../../docs/adr/0029-insights-app-dba-console.md)) |
| Charts | One chart component, `ChartView`: hand-built SVG with d3-scale and d3-shape (line, area, bar, stacked bar, scatter, table, and KPI, with incident bands, thresholds, and markers), which the Copilot dock's charts use too; the incident replay, a heatmap, and sparklines. No charting library and no CDN |
| Fonts | Segoe UI from the system, like Fabric; no web fonts |
| Data | One connector, `history`: `fabric-semanticmodel`, `executeQuery` only, delegated ([connectors](https://learn.microsoft.com/fabric/apps/connectors)). Live data from the app's function (`src/copilot/estate.ts`), through `src/data/live-estate.ts` |
| Queries | `src/data/queries.ts`: 21 DAX queries, each with a row bound (`resultSetRowCountLimit`); results are cached for 5 minutes and shared between visuals. The ones a new environment has no rows for are marked `mayBeEmpty` (the readiness checks, the sessions, the agent loop, and T5), so the deploy-time check says so rather than warns |
| Hosting | `staticHosting.assetAccess: protected`, set explicitly in `rayfin/rayfin.yml` ([hosting](https://learn.microsoft.com/fabric/apps/hosting)) |
| Backend services | Auth; and the shared functions project (`rayfin/functions/`): `estateOverview`, the live estate for Ask and the pages, read-only (`estate.ts`), and Manage's `manageAccess`, `manageRequest`, and `manageJob` (`manage.ts`). No database or storage |

Every package is pinned to an exact version in `package.json` and `package-lock.json`, resolved from the public npm registry (`registry.npmjs.org`) with SHA-512 integrity: install new packages with `--registry=https://registry.npmjs.org/`, or fix the lock file's URLs after an install through a mirror. `npm run check:licenses` fails on a production dependency that isn't MIT, ISC, Apache-2.0, BSD, 0BSD, OFL-1.1, BlueOak-1.0.0, Unlicense, or CC0-1.0. The build writes `dist/THIRD_PARTY_NOTICES.txt`. The bundle is about 410 KB gzip in all, and pages load lazily.

```text
fabric/app/
  rayfin/rayfin.yml            backend config: placeholders only (${DBHUB_FABRIC_WORKSPACE_ID}, ${DBHUB_SEMANTIC_MODEL_ID})
  rayfin/connectors/history/   the connector's generated schema (no IDs)
  src/shell/                   the top bar, the left navigation, the global filter, the account chips, and the dock's region
  src/pages/                   Overview, Estate, Performance, Incidents, Findings, Readiness, Trends, Manage, and Live views
  src/components/              the visual card (Ask Copilot, the data, the DAX, focus), the data grid, KPI and health tiles, and badges
  src/visuals/                 ChartView and its chart kit, the incident replay, the heatmap, and sparklines
  src/data/                    the DAX catalog, the query client (sources, cache, bounds), typed parsers, and the live estate's loader
  src/lib/                     DAX builders, formatting, CSV, view state, health, insights, Ask Copilot's context, the control's
                               requests, the Manage client, the live findings, and the Database Agent prompts
  src/copilot/                 Ask: the Copilot dock and provider, its page-run tools, the relay client, and the model guide (the chat's code)
  rayfin/functions/            the functions: the live estate (estate.ts, estate-core.ts) and Manage (manage.ts, manage-core.ts); function_app.ts registers each feature's
  src/theme/                   the Fluent themes and their tokens
  src/preview/                 the local preview's sample data (npm run dev:sample); never built into the app
  src/test/                    the test setup and fixtures, and the tests of the npm overrides with Rayfin's code
  scripts/export-queries.ts    writes the catalog as connector payloads for the deploy-time check
  scripts/build-model-guide.ts writes src/copilot/model-guide.generated.ts from the model's TMDL (npm run guide:build)
  scripts/check-licenses.mjs   the production license check
```

### Overrides and known advisories

`package.json` has four npm overrides, for security advisories in packages that the pinned Rayfin packages and ESLint bring in. No release of those parents declares a fixed version yet, not even the newest Rayfin prerelease (checked 2026-10-28 for zod, and 2026-11-09 for `@azure/msal-node`, glob, and minimatch), so each override is outside its parent's declared range. The glob and minimatch overrides are scoped to the advisory's vulnerable range (`glob@>=9.0.0 <14.0.2`, `minimatch@>=7.0.0 <11.0.1`), so a parent that declares a range outside it keeps its version: `readdir-glob` 1.1.3, through `archiver`, keeps minimatch 5.1.9. `config/versions.json` (`fabricApp.overrides`) records them and why, and a Pester test keeps that record, `package.json`, and the lock file in sync (Phase 27).

| Package | Override | Advisory | Declared by | Proof |
|---|---|---|---|---|
| `@azure/msal-node` | 7.2.1 | [GHSA-xcx6-jx8p-x3h5](https://github.com/advisories/GHSA-xcx6-jx8p-x3h5) (high), fixed in 7.1.0 | `@microsoft/rayfin-cli` 1.36.2 (`^5.5.0`); `@azure/identity` 4.14.1, through `tedious` 19.2.2 (`^7.1.0`) | `src/test/overrides.test.ts` runs the CLI's own `rayfin login` and `rayfin login status` against a stand-in for Microsoft Entra ID and the browser (`src/test/rayfin-sign-in-harness.mjs`), offline: the browser sign-in with PKCE and `form_post`, the code redeemed alone, a response with another request's state refused (MSAL Node 5.6.0 took it), and the cached sign-in read and renewed. A sign-in cached by 5.6.0 reads with 7.2.1, and the other way round (checked by hand, 2026-11-09) |
| `glob` (in `>=9.0.0 <14.0.2`) | 14.0.3 | [GHSA-3g3m-2fjr-6pw4](https://github.com/advisories/GHSA-3g3m-2fjr-6pw4), fixed in 14.0.2 | `@microsoft/rayfin-cli` 1.36.2 (`^13.0.6`); `archiver-utils` 5.0.2, through the CLI's `archiver` 7.0.1 (`^10.0.0`) | `src/test/overrides.test.ts` runs the CLI's ZIP packaging for `rayfin up` (`packageStaticFolder`, which loads `archiver`, `archiver-utils`, and glob) and checks every entry's content and CRC-32, and runs the CLI's own glob call with its ignore patterns. On this app's built `dist`, the ZIP's 21 entries were identical, name and SHA-256, to the ones with glob 10.5.0 (checked by hand, 2026-11-09) |
| `minimatch` (in `>=7.0.0 <11.0.1`) | 11.0.4 | [GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249), fixed in 11.0.1 | `eslint` 10.10.0 (`^10.2.5`); `@eslint/config-array` 0.23.5 (`^10.2.4`); `@typescript-eslint/typescript-estree` 8.61.0 (`^10.2.2`); glob 13.0.6 and 10.5.0, which the glob override replaces with 14.0.3 (`^11.0.2`) | `npm run lint`, and `src/test/overrides.test.ts`, which checks ESLint's ignores, the configuration it picks for each file, and the files it finds for a pattern. minimatch 11 removed `makeRe()`, `Minimatch#regexp`, and the `debug` option, which none of these use |
| `zod` | 4.6.7 | [GHSA-mrhx-c7xc-m3w5](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5), fixed in 4.6.6 | `@microsoft/rayfin-tools-common` 1.36.2 (`~4.3.6`), through the SDK's connectors and the CLI; `eslint-plugin-react-hooks` (`^3.25.0 \|\| ^4.0.0`) | `src/test/overrides.test.ts` runs Rayfin's template manifest validation (`rayfin init`), its only use of zod: the same results as with 4.3.6, but for one message that now names the closest match. The app's browser bundle has no zod |

Remove an override once a pinned release of each parent depends on a fixed version: `@azure/msal-node` 7.1.0 or later, zod 4.6.6 or later, glob 14.0.2 or later, or minimatch 11.0.1 or later.

The `@azure/msal-node` override reaches everything installed from the lock file, so the stage's CLI. Since 2026-11-09 every Rayfin command the scripts run comes from it: `rayfin up`, the connector's queries, `configure-fabric-app.ps1 -SignIn`, and `deploy.ps1`'s browser sign-in. None of them runs the CLI through `npx`, which resolves the CLI's dependencies from the registry without this project's overrides (before, `deploy.ps1`'s browser sign-in and the one-time command in step 3 below did, and got MSAL Node 5.6.0). With the Azure CLI's tokens (`RAYFIN_TOKEN`, step 3), a deploy calls no MSAL at all. The advisory concerns apps that pass the authorization response to `acquireTokenByCode`, and the CLI never does: its browser sign-in goes through MSAL's `acquireTokenInteractive`, which passes only the code (the advisory's workaround) ([R540](../../docs/implementation-report.md#risk-register)). With the overrides, `npm audit` reports no vulnerabilities, and neither does `npm audit --omit=dev` (2026-11-09). glob, minimatch, and `archiver` are development dependencies, but the CLI's `archiver` packages the app for `rayfin up`, which runs the stage's CLI, installed from the lock file, so it gets these overrides.

## Deploy

```powershell
./scripts/configure-fabric-app.ps1
```

`./scripts/deploy.ps1` runs it in its Fabric track, after the history report, as part of every deployment (2026-11-05). Since 2026-11-09 it deploys with the deployer's Azure CLI sign-in (step 3), so no browser opens. Only when Fabric refused that token for the demo's tenant in an earlier run does `deploy.ps1` start the Rayfin CLI's own browser sign-in at the beginning of the run, in a session that can take keyboard input, and the rest of the run goes on; only this step waits for it, at most 15 minutes from the start. When the app can't be created, the deployment goes on and still ends **DONE**: the status page shows the app's step as **Failed**, with the actual error and the fix ([deployment](../../docs/deployment.md#the-insights-app-part-of-every-deployment-2026-11-05)).

The script is unattended and idempotent; it deploys to the item named `APP_DatabaseHub_Insights` and updates it in place on every run. It never deletes anything. It needs:

1. `SM_DatabaseHub_History` deployed (`./scripts/configure-powerbi.ps1`), and the workspace on an **Active** Fabric capacity: `rayfin up` can start a trial or assign a capacity when a workspace has none, so the script deploys only on an Active one.
2. Node.js 20, 22, or 24 (the CLI's supported versions; it also ran on 26 with npm's EBADENGINE warning).
3. **The sign-in the Rayfin CLI uses.** By default, your Azure CLI sign-in (`az login`, 2026-11-09): after its subscription guard, the script gets a token for each command's audience, the Fabric API for `rayfin up` and `rayfin up status` and the Power BI API for `rayfin connector invoke`, and gives it to that command alone as `RAYFIN_TOKEN`, which the pinned CLI uses instead of its own sign-in. That variable is read in the CLI's code; the [CLI reference](https://learn.microsoft.com/fabric/apps/cli-reference) doesn't document it. When Fabric refuses the token for `rayfin up`, `FABRIC.APP.TOKEN` is a **Warning** with the reason, and the CLI's own one-time sign-in, as the demo's Fabric user, deploys instead. When the connector's direct route refuses the Power BI token, as it did live on 2026-11-09 (HTTP 401 from Power BI's `executeDaxQueries`), the app's queries run through Power BI's [Execute Queries](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group) with the same token instead, so the checks need no Rayfin sign-in either. Make the CLI's own sign-in with `-SignIn` (below), or, once the stage exists, from the repository root:

   ```powershell
   ./out/fabric-app/node_modules/.bin/rayfin login --tenant <tenantId>
   ```

   It opens a browser once. The CLI keeps its own token cache and renews it silently; without `-SignIn`, the script only reads it (`rayfin login status --json`) and never signs in or out. Don't sign in through `npx`: it installs the CLI without this project's npm overrides. Service principal sign-in is listed in the [CLI reference](https://learn.microsoft.com/fabric/apps/cli-reference) but isn't supported yet. `-RayfinSignIn` uses only the CLI's own sign-in, as before 2026-11-09.

   Or run `./scripts/configure-fabric-app.ps1 -SignIn` (Phase 26b): when the CLI's own sign-in is needed and it isn't signed in to the demo's tenant, it runs that same sign-in in your console, checks it, and deploys. It runs only in an interactive session; in CI it's **Not supported**.

   If no browser opens, check your terminal's `BROWSER`: when it's set, the CLI opens its sign-in page with `"<BROWSER>" "<url>"` and doesn't check the result, so a command line such as `"<path>\msedge.exe" --inprivate %s`, set for `az login`, opens nothing. `-SignIn` and `deploy.ps1` remove such a value for the CLI's process only (2026-11-06); for the command above, remove it from that terminal first ([troubleshooting](../../docs/troubleshooting.md#the-insights-app-fabric-app)).

What it does, as ADR 0012 results in `out/configure-fabric-app.jsonl`:

| Step | Check IDs |
|---|---|
| Validate `fabric/app`: placeholders only, protected assets, the connector, and the pinned CLI | `FABRIC.APP.SOURCE` |
| The subscription guard, then the workspace role and an Active capacity | `PREFLIGHT.GUARD.CONTEXT`, `FABRIC.P5.WORKSPACE`, `FABRIC.P5.CAPACITY` |
| Find the model, the dashboard, and the report by name; build the new-tab links from their IDs | `FABRIC.APP.ITEMS` |
| Mirror `fabric/app` into the Git-ignored stage `out/fabric-app`, write `rayfin/.env` (connector IDs) and `public/dbhub-app.json` (links, the expected account, and the resource group name for the agent prompts), drop the CLI's records of other workspaces (since 2026-11-19), and run `npm ci` when the lock file changed | `FABRIC.APP.STAGE`, `FABRIC.APP.DEPENDENCIES` |
| Node.js, the sign-in the CLI uses (the Azure CLI's tokens, or its own sign-in to the demo's tenant), and the two tenant settings | `FABRIC.APP.NODE`, `.SIGNIN`, `.TENANTSETTING`, `.EXECUTEQUERIES` |
| `rayfin up --workspace-id <id> --item-name APP_DatabaseHub_Insights --tenant <id> --yes --json`, then `rayfin up status --json`; when Fabric refuses the Azure CLI's token, the CLI's own sign-in deploys instead | `FABRIC.APP.DEPLOY`, `FABRIC.APP.STATUS`, `FABRIC.APP.TOKEN` (only after a refusal) |
| Every query in the app's catalog, anchored to the newest telemetry day, under your identity: through the connector's direct route (`rayfin connector invoke`), or, when that route refuses the Azure CLI's token, through Execute Queries with the same token (one query per request, with the app's row bound compared here, since that API has none); `-RayfinSignIn` runs them through the connector with the CLI's own sign-in. Then the hosted app must refuse anonymous requests | `FABRIC.APP.CONNECTOR`, `.QUERIES` (evidence `route`, `auth`, `connectorRefusal`), `.HOSTING` |
| Ask: before the stage, deploy its chat relay (`infra/ask/ask-relay.bicep`, registering `Microsoft.App` when it isn't) and write its address into `dbhub-app.json`; after `rayfin up`, set the relay's origin to the app's, wake and check it, and read the strict-CSP tenant setting. Never a Fail: Pass, Warning, or Not selected | `ASK.RELAY`, `ASK.RELAY.HEALTH`, `ASK.SIGNIN`, `ASK.CSP` |
| The browser check: a note when the app is deployed and every query it runs returned its data (2026-11-09). The note says exactly that, and that the app's own route in the browser (its sign-in, then its backend, User Data Functions, and a delegated on-behalf-of call) can't be checked from a script, since neither route above crosses it. Otherwise only a person can do it | `FABRIC.APP.BROWSER` (**Not selected**, "Not needed"; otherwise **Manual action required**) |

Without `-FabricAdmin`, the tenant settings can't be read; a passing deploy proves **Fabric Apps (preview)** and a passing connector check proves **Dataset Execute Queries REST API** (the connector's runtime calls the Execute Queries API, and the check's other route is that API), so both become a **Pass**. With `-FabricAdmin`, they're read through the [admin API](https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings).

Options: `-WhatIf` validates the source and lists the plan with no token, network call, or write. `-DryRun` runs everything up to `rayfin up --dry-run`. `-CheckOnly` checks the deployed app without deploying. `-Queries Probe` runs only the connection check. `-TreatManualAsError` exits with code 2 while the browser check is pending. `-RayfinSignIn` uses only the Rayfin CLI's own sign-in, not the Azure CLI's tokens. With `-FabricToken`, the script runs no subscription guard, so it has no Power BI token, and the app's queries are checked only with `-RayfinSignIn` (otherwise `FABRIC.APP.CONNECTOR` is a **Warning** that says so).

The CLI's `connector invoke --transport deployed` needs an app session the CLI can't create yet (HTTP 401 in the live check), so the in-app path is the browser check: the CLI's own comment says a probe on the direct route "says nothing about whether the deployed app will work". Measured on 2026-10-22 (F16, West US 3): the first deploy of the item took 53 s; redeploys of the real app took 37 s and 57 s; the whole script took 175 s and 278 s (about 45 s of it the subscription guard, and about 2 minutes the 13 connector calls), and `-CheckOnly` took 124 s. With the Database Agent prompts (14 queries), the redeploy took 47 s and the whole script 265 s. On 2026-11-09, `rayfin up` with the Azure CLI's token took 162 s.

The CLI writes its deployment record (`rayfin/.deployments.json`, `rayfin/.env`, `.env.local`) in the stage. Those files hold the item ID, the hosting URL, and the app's publishable key, so they stay under `out/`, Git-ignored. The publishable key is public by design (the browser bundle carries it), but the script redacts it from every result and log anyway. The CLI finds its record by the workspace's name and reuses the item it names, whatever workspace that was, so since 2026-11-19 the stage drops the records of every other workspace before `rayfin up` (`FABRIC.APP.STAGE` names them): after `destroy.ps1`, a new workspace with the same name would otherwise get the deleted app's ID, and the deploy would fail.

### Update and delete

- **Update:** run `./scripts/deploy.ps1` again (or `./scripts/configure-fabric-app.ps1` for the app alone). It updates the item `APP_DatabaseHub_Insights` in place, keeps its history and its links, and refreshes Manage's operators list; the new version shows the next time the app opens. Upgrading an older demo is the same command ([deployment](../../docs/deployment.md#update-an-existing-environment)).
- **Delete:** `./scripts/destroy.ps1` deletes the demo's Fabric workspace, with the app's three items in it, when every item in it is one the demo creates; `-KeepFabric` keeps it. The app's items are the app, `AppBackend APP_DatabaseHub_Insights`, and the two user data functions its backend makes beside it: `APP_DatabaseHub_Insights_connector`, the connector's, and `APP_DatabaseHub_Insights`, the functions' (since 2026-11-18). To remove only the app, delete those three items in the workspace, and `out/fabric-app/rayfin/.deployments.json` on the PC that deploys it, because the CLI would otherwise reuse the deleted app's ID in the same workspace; the next deploy creates them again. `destroy.ps1` deletes Ask's chat relay with the demo resource group. On your PC, the stage and the CLI's sign-in stay, and on GitHub, each viewer's authorization of **Database Hub Insights Ask**, which they revoke in their settings ([cleanup](../../docs/cleanup.md), [delete everything](../../README.md#delete-everything)).
- **What you control:** who can open it (the workspace's roles, or the item shared), who reads the history (Read and Build on `SM_DatabaseHub_History`), and who sends Manage's actions (the demo's admin group). In the configuration: whether Ask runs (`ask.enabled`, on by default), and, rarely, your own GitHub OAuth App or relay image (`ask.githubClientId`, `ask.image`, pinned by digest).

## Known limitation: the hosted URL

Opening the hosted app's URL directly in a browser tab fails in this preview: the Fabric Apps host shows its own **Sign in required** page, and its **Sign in** opens a Fabric portal page in a pop-up that stops at **"Page not accessible directly. This page must be opened from an application."** The same happened in an InPrivate window signed in to Fabric as the demo's admin, so the account and tenant weren't the cause.

What the live check found (2026-10-22, anonymous requests only):

- The hosted URL is on the Fabric Apps host (`https://<name>-<region>.webapp.fabricapps.net`), not the `<app>-app.rayfin.windows.net` form [hosting](https://learn.microsoft.com/fabric/apps/hosting) shows. Without a session it returns HTTP 401 `{"error":"Authentication required."}` to `Accept: application/json` and the HTML **Sign in required** page to a browser.
- That page sends `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, and `Content-Security-Policy: frame-ancestors 'none'`. Its **Sign in** opens `https://app.fabric.microsoft.com/secureItemEmbed?...&extensionPath=/brokeredauth&ctid=<tenant>` in a pop-up, which hands the result back through the opener window ([Fabric authentication](https://learn.microsoft.com/fabric/apps/fabric-authentication)).
- No `Cross-Origin-Opener-Policy` header showed up on `secureItemEmbed`, the portal, or the sign-in pages, so what drops the opener is unconfirmed. It's a preview behavior outside the app's code.

**Workaround and supported entry point:** open the app from its workspace item. The app keeps `assetAccess: protected`; making the assets public wouldn't fix the hand-off and would expose the bundle without sign-in. To report it, use **Help & support** in the Fabric portal (or [Fabric Ideas](https://ideas.fabric.microsoft.com/)) with the steps above.

## Develop and test

```powershell
cd fabric/app
npm ci
npm run verify       # typecheck, lint, Vitest (unit, page, chart, theme-contrast, and override tests), license check, build
npm run dev:sample   # the local preview with sample data: no Fabric, no sign-in
```

`./tests/Invoke-StaticValidation.ps1 -Check FabricApp` runs the same in the repository's static validation, and the `Fabric App` CI job runs it on Node.js 24. The tests use fixture rows shaped like the connector's results; no test reaches Fabric.

**The preview** (`npm run dev:sample`, then `/preview.html`) runs the whole app on made-up history and live answers, labeled **Sample data**, for design work and screenshots. Its query parameters: `theme=light|dark|contrast`, `copilot=open`, `manage=operator|viewer|running` (without it, Manage's copy mode), `empty=1` (no history: the first run), and `live=off` (no live source). Vite builds only `index.html`, so none of it ships.

To run the app locally against the deployed backend, work in the stage (`out/fabric-app`, after a deploy): `npm run dev` writes `.env.local` from the deployment record and serves on `http://localhost:5173`, which `rayfin.yml` allows as a redirect URI. Local sign-in wasn't verified in this phase.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Page not accessible directly" | Open the app from its workspace item (see above) |
| `FABRIC.APP.SIGNIN` is Manual action required | The CLI's own sign-in is needed and missing: run `./scripts/configure-fabric-app.ps1 -SignIn`, or the stage's `rayfin login` command in the remediation, then the script again |
| `FABRIC.APP.TOKEN` is a Warning | Fabric refused the Azure CLI's token for `rayfin up`. When the app deployed with the CLI's own sign-in, nothing; otherwise run `./scripts/configure-fabric-app.ps1 -SignIn` |
| `FABRIC.APP.CONNECTOR` passed "through Power BI's Execute Queries" | Nothing: the connector's direct route refused the Azure CLI's Power BI token (live, 2026-11-09), and the same token ran the app's queries through Execute Queries. No browser opens because of it |
| `FABRIC.APP.CONNECTOR` failed "on both routes" | Do what its remediation says for Power BI's answer (401, 403, or 404), then run the script with `-CheckOnly` |
| `FABRIC.APP.DEPLOY` says not signed in or the token expired | The CLI's session lapsed; sign in again with the same command |
| `FABRIC.APP.ITEMS` is Manual action required | Deploy the model first: `./scripts/configure-powerbi.ps1` |
| A visual says Fabric refused the query | The viewer needs Read and Build on `SM_DatabaseHub_History`, and the Execute Queries tenant setting |
| `FABRIC.APP.QUERIES` warns that some queries returned no rows | Run all in `NB_DatabaseHub_Control` so the lakehouse has history for that window. Queries that a new environment has no rows for (the sessions, the agent loop, T4's and T5's captures) are said in the message, not warned about |
| T4's or T5's page says there's no history yet | A session's end (Run all), `./scripts/stop-demo.ps1 -SaveHistory`, or `./scripts/deploy.ps1` captures their Azure Monitor metrics and passes them to the notebook. A notebook you run by hand has none to pass; a deployment without Cosmos DB has no T5 |
| T4's page has no Read replica lag | The latest capture had no read replica: it exists only during a session, so capture before `stop-demo.ps1` deletes it (its `-SaveHistory` does) |
| A page says **Live · unavailable** | The line beside it says why. "Database Hub's live view isn't available to the app: Database Hub refuses the app's own sign-in" is R924 (2026-11-19): Database Hub answers HTTP 401 to the sign-in Fabric gives the app's functions, and nothing in the demo fixes that; `FABRIC.APP.ESTATE` is **Not supported**. Otherwise the app's live estate function isn't deployed, or Database Hub didn't answer. The page shows the history, **Ready to migrate** shows T2's assessment as Azure had it at the last deploy, and Database Hub has the live view |
| **Ready to migrate** links the Azure portal instead of showing T2's readiness | Azure had no assessment result for `arcsql01` when the app was last deployed (its first run uploads about 6 minutes after `deploy.ps1` starts it). `./scripts/deploy.ps1` again, after `T2.ARC.MIGRATIONASSESSMENT` is **Pass**, puts it in the app |
| Manage says each action copies its request | The app's Manage function isn't deployed, or it isn't set up, which the message says (`FABRIC.APP.ACTIONS` says why, for example when the session control's notebook wasn't found): paste the copied lines into a new cell under the control notebook's parameters cell, then Run all. With the function set up, operators send from the app. Before 2026-11-19, a new environment's first `deploy.ps1` always left it so ("missing NB_DatabaseHub_Control"): run `./scripts/deploy.ps1` again, which deploys the app once more once the notebook is in Fabric |
| Manage is read-only for you | You aren't one of the demo's operators: the deployer and the members of its admin group. Ask an operator, or one of them redeploys after adding you to the group (`./scripts/deploy.ps1` refreshes the list) |
| Manage says "Stop now cancelled the control's run, but the stop didn't start" | The capacity (an F2 or F4 runs one Spark session at a time) still refused the stop after 150 seconds, and nothing is stopping the session now. Paste the copied request into the control notebook and Run all, or run `./scripts/stop-demo.ps1 -SaveHistory` from a PC. The session's auto-stop still stops everything at its end, and the next Run all saves its history |
| Manage refuses an action: "... is in progress, and the control takes one request at a time" | One of `NB_DatabaseHub_Control`'s runs is queued or in progress: a session's Run all, or an earlier request. Wait for it to end (the page follows it), or use Stop now, which ends the session as its end would |
| The Copilot dock says Ask isn't deployed | `ASK.RELAY` says why, with the fix. No image pinned in your copy: the maintainers pin it in `config/versions.json`, so run `./scripts/deploy.ps1`, which first updates a clean checkout of `main` from GitHub; you never build the image. An image it can't pull, or a deployment that failed: fix what it names, then run `./scripts/deploy.ps1` again. `ask.enabled` false: Ask is off by your choice |
| The Copilot dock says it can't reach the relay | Wait about 15 seconds (it starts from zero); otherwise `ASK.RELAY.HEALTH` and `ASK.CSP` say why: the relay doesn't allow the app's origin yet, or the strict-CSP tenant setting is on |
| The Copilot dock says this GitHub account can't use Copilot | Sign in with the GitHub account that has your Copilot license (**Switch GitHub account**); an organization that restricts OAuth apps has an owner approve **Database Hub Insights Ask** |
| The Copilot dock says "Copilot didn't write an answer" | Copilot ended the turn without writing text after its last query. Select **Retry**, which asks the same conversation to write it; the relay's `chat.turn.end` log line has the turn's counts ([troubleshooting](../../docs/troubleshooting.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)) |
| A Copilot answer says Database Hub's live view isn't available | The estate function couldn't read Database Hub (`unavailable`): the rest of that conversation answers from the history and points to Database Hub's own pages; **New chat** tries the live view again |
| A Real-Time Dashboard link opens the wrong page | The portal path for dashboards isn't documented; use the workspace link and open `RTD_DatabaseHub_LiveView` |

More in [troubleshooting](../../docs/troubleshooting.md).
