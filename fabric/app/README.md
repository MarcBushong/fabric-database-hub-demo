# Database Hub Insights: the Fabric App (preview)

`APP_DatabaseHub_Insights` is a read-only [Fabric app](https://learn.microsoft.com/fabric/apps/overview) over the history semantic model `SM_DatabaseHub_History` (Phase 19). It shows the same lakehouse history as the Power BI report, in a different form: custom visuals, motion, themes, and ways to take the data out. Fabric Apps is a **preview**.

It's history, not live. `NB_DatabaseHub_LiveActivity` saves telemetry snapshots, findings, and incident windows to `LH_DatabaseHub`; the model reads them with Direct Lake; the app queries the model with DAX. For live data, use Database Hub and the Real-Time Dashboard ([presentation](../../docs/presentation.md)).

## Open the app

**Open it from its item in the Fabric workspace.** In the Fabric portal, open the demo workspace and select `APP_DatabaseHub_Insights`. The app runs embedded in the item page and signs you in by itself with `initEmbeddedAuth` ([Fabric authentication](https://learn.microsoft.com/fabric/apps/fabric-authentication)). The **Live links** page shows **"✓ Connector check passed"** with the counts of validation checks, telemetry rows, and incident windows. That message proves sign-in, the connector, and your access to the model in one step.

Don't open the hosted URL directly. That's a known preview limitation: see [Known limitation: the hosted URL](#known-limitation-the-hosted-url).

Viewers need:

- Access to the app item (a workspace role, or the item shared with them).
- **Read** and **Build** on `SM_DatabaseHub_History`: the connector runs DAX as the signed-in user (delegated).
- The tenant settings **Fabric Apps (preview)** and **Dataset Execute Queries REST API** for them ([prerequisites](../../docs/prerequisites.md)).

## What's in it

Four pages, designed for the portal's item frame (smaller than full screen) and responsive down to a phone width.

| Page | Visuals | What it answers |
|---|---|---|
| **Estate** | Estate constellation (targets orbit the estate; satellites are signals sized by value; a halo takes the worst finding's status), activity clock (24 UTC hours, one ring per target), signal ridgelines (per-bin distributions), the findings feed, and a Database Agent prompt library | Which target works hardest, when, and what changed |
| **Incidents** | Incident ribbon, replay (every signal bin by bin, with a scrubber, steps, speeds, the window, its baseline, and its peak), **Investigate with the Database Agent** (ready-made prompts for each window), before-and-after spotlight (a wait "rose" that morphs from the minutes before the window into the window), and the wait flow (Sankey or sunburst: wait family to category to target) | What an incident looked like, what changed during it, and what to ask next |
| **Readiness** | Readiness dial and area rings (the latest validation run; inner rings are earlier runs), telemetry coverage, a Database Agent prompt library that starts with telemetry coverage, and every check worst first with its next step and documentation | Is the demo ready, and what's the next step |
| **Live links** | New-tab links to Database Hub, the Real-Time Dashboard, and the Power BI report; how the history gets here; the connection check | Where the live view is |

Each page starts with **insight cards**: plain sentences computed by rules over the query results in the browser, such as "T3 Buffer IO (PAGEIOLATCH) waits ran at 6.0 times their baseline". No external AI service is called.

### Take the data out

Every visual's card has:

- **Show DAX**: the exact query the visual ran, highlighted, with **Copy DAX**.
- **Data table**: the visual's data as an accessible table (its text alternative).
- **Download CSV** and **Copy CSV** of exactly that data (spreadsheet formulas are neutralized).
- **Refresh** and **Focus** (the visual alone, full frame; Esc closes it).

Inside the portal the app has no address bar of its own, so the view (page, filters, incident, replay position, visual options) is kept in the app and remembered per browser. **Copy link** on Live links copies the app item's page in the Fabric portal; it opens the app's home page, not a specific view.

### Customize

- **Filters:** targets (T1, T2, T3) and the period (latest day, 7 days, 30 days, all history), anchored to the newest telemetry day, not to today.
- **Themes:** Aurora (the signature dark glass), Daybreak (light), and Contrast (high contrast). Every text color passes WCAG AA on every surface (`src/theme/themes.test.ts`). The app follows the system's light and high-contrast preferences until you pick one.
- **Motion:** the sparkle button turns animations off; the app also honors `prefers-reduced-motion`.
- Keyboard: every control and every target in the constellation is reachable with Tab and Enter; status is never shown by color alone (each status has a shape and a word, ADR 0012).

### Ask the Database Agent

Database Hub has a built-in Database Agent (preview). It works only in Database Hub's UI and has no API, so the app can't send it anything. Instead, the app writes ready-made prompts from the data on screen: you copy one, select **Open Database Hub**, and paste it into the Database Agent. It never runs anything itself.

- **Incidents, per window:** each window in the ribbon has an agent button (a robot icon), the replay has **Ask the agent**, and the **Investigate with the Database Agent** card under the replay shows the selected window's prompts. The prompts carry the window's own numbers: the target and its resource name, the UTC window, and the peak, baseline, and ratio of the window's signal from the replay. For example:

  > On T2 (Arc-enabled SQL Server arcsql01) between 14:05 and 14:35 UTC on 2026-10-22, Buffer IO (PAGEIOLATCH) waits peaked at 11.5 s per 5-minute bin and averaged about 4 times the baseline (2.9 s per 5-minute bin in the 30 minutes before). What caused it, which sessions and queries were involved, and what should I check or change? Name each signal you used. Don't apply anything; propose only.

  Each window gets four prompts: what caused it, what moved with it, against the baseline (the window against the minutes before it), and the evidence.
- **Estate and Readiness, a prompt library:** estate health, the top waits per target, blocking chains, and what changed since the baseline (the newest telemetry day against the day before), for the targets and period you selected. Readiness starts with telemetry coverage: which targets the agent has performance data for.
- **Copy** on each prompt, **Copy and open Database Hub** (copies the prompt and opens Database Hub in a new tab in one click), **Copy all**, and **Open Database Hub**. Database Hub opens in a new tab in the demo's tenant (the deploy-time link, with `ctid`).
- **Labels on every panel:** **Preview**; **the agent proposes; you approve each action** (the [Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq) says actions are "explicit and always approved by the end user"); and **investigation only: this app never runs anything**. In this demo, read a proposal aloud, then cancel it ([presenter rules](../agent/README.md#use-it-safely-approval-rules-for-presenters)).
- **The fallback format:** the **Copilot CLI · VS Code** switch rewrites the same questions for the documented fallback, GitHub Copilot CLI or VS Code with the `microsoft-sql-fdh` and `microsoft-sql` plugins ([agent guide](../agent/README.md)): KQL through the telemetry agent instructions on Microsoft Learn, the Database Hub skill, and the `microsoft-sql` diagnostics skills, connected as you and never with a SQL login. The choice is remembered per browser.
- Every prompt ends with the [prompt pack's](../agent/prompts/README.md) safety sentence, "Don't change anything." or "Don't apply anything; propose only.", so a copied prompt keeps it.
- The resource names come from the telemetry snapshots (query `target-names`); the resource group name comes from the deploy-time `dbhub-app.json`, never from Git.
- Database Hub keeps 7 days of telemetry or less ([telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). For an older window the panel warns that the agent may not see it any more; this app's history still does.

## How it's built

| Part | Choice |
|---|---|
| Template | The Fabric Apps data app template, `microsoft/fabric-apps-analytic-templates` at commit `239b2c7` (MIT), recorded in `config/versions.json` (`fabricApp.template`) |
| Runtime | React 19 and Vite, the Rayfin SDK 1.36.2 (`@microsoft/rayfin-client`, `-auth-provider-fabric`, `-connector-fabric-semanticmodel`) |
| Visuals | Hand-built SVG with d3 (shape, scale, hierarchy, sankey, interpolate) and Framer Motion; no charting library and no CDN |
| Fonts | Space Grotesk and JetBrains Mono (OFL), bundled |
| Data | One connector, `history`: `fabric-semanticmodel`, `executeQuery` only, delegated ([connectors](https://learn.microsoft.com/fabric/apps/connectors)) |
| Queries | `src/data/queries.ts`: 14 DAX queries, each with a row bound (`resultSetRowCountLimit`); results are cached for 5 minutes and shared between visuals |
| Hosting | `staticHosting.assetAccess: protected`, set explicitly in `rayfin/rayfin.yml` ([hosting](https://learn.microsoft.com/fabric/apps/hosting)) |
| Backend services | Auth only: no database, storage, or functions |

Every package is pinned to an exact version in `package.json` and `package-lock.json`, resolved from the public npm registry with SHA-512 integrity. `npm run check:licenses` fails on a production dependency that isn't MIT, ISC, Apache-2.0, BSD, 0BSD, OFL-1.1, BlueOak-1.0.0, Unlicense, or CC0-1.0. The build writes `dist/THIRD_PARTY_NOTICES.txt`.

```text
fabric/app/
  rayfin/rayfin.yml            backend config: placeholders only (${DBHUB_FABRIC_WORKSPACE_ID}, ${DBHUB_SEMANTIC_MODEL_ID})
  rayfin/connectors/history/   the connector's generated schema (no IDs)
  src/data/                    the DAX catalog, the query client (cache, bounds), and typed parsers
  src/lib/                     DAX builders, formatting, CSV, view state, statistics, the insight rules, and the Database Agent prompts
  src/visuals/                 the seven custom visuals and their pure layout code (layout.ts)
  src/pages/                   Estate, Incidents, Readiness, and Live links
  src/theme/                   the three themes and their contrast tests
  src/test/                    the test setup, and the test of the npm override with Rayfin's code
  scripts/export-queries.ts    writes the catalog as connector payloads for the deploy-time check
  scripts/check-licenses.mjs   the production license check
```

### Overrides and known advisories

`package.json` has one npm override, for a security advisory in a package that the pinned Rayfin packages bring in. No Rayfin release declares a fixed version yet, not even the newest prerelease (checked 2026-10-28), so the override is outside its parent's declared range. `config/versions.json` (`fabricApp.overrides`) records it and why, and a Pester test keeps that record, `package.json`, and the lock file in sync (Phase 27).

| Package | Override | Advisory | Declared by | Proof |
|---|---|---|---|---|
| `zod` | 4.6.7 | [GHSA-mrhx-c7xc-m3w5](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5), fixed in 4.6.6 | `@microsoft/rayfin-tools-common` 1.36.2 (`~4.3.6`), through the SDK's connectors and the CLI; `eslint-plugin-react-hooks` (`^3.25.0 \|\| ^4.0.0`) | `src/test/overrides.test.ts` runs Rayfin's template manifest validation (`rayfin init`), its only use of zod: the same results as with 4.3.6, but for one message that now names the closest match. The app's browser bundle has no zod |

Remove the override once a pinned Rayfin release depends on zod 4.6.6 or later.

**Not overridden:** [GHSA-xcx6-jx8p-x3h5](https://github.com/advisories/GHSA-xcx6-jx8p-x3h5) in `@azure/msal-node` (high), so `npm audit` still reports it, for `@azure/msal-node`, `@azure/identity`, and `@microsoft/rayfin-cli`. It's a dev dependency of the Rayfin CLI 1.36.2, which declares `^5.5.0` (and `^6.0.0` through `tedious` and `@azure/identity`), and it's fixed only in 7.1.0, two major versions on. The advisory concerns apps that pass the authorization response to `acquireTokenByCode`; its workaround is to pass only the authorization code. The CLI never calls `acquireTokenByCode`: its browser sign-in goes through MSAL's `acquireTokenInteractive`, which in the installed versions (5.6.0, and 6.0.1 under `@azure/identity`) passes only the code, and its silent, device code, and client credential sign-ins use no authorization code. So the vulnerable pattern isn't reached through the CLI's sign-in as installed. Nothing offline can prove the CLI's interactive sign-in with MSAL Node 7, so this waits for a Rayfin release that accepts MSAL Node 7.1 or later ([R540](../../docs/implementation-report.md#risk-register)). The production dependencies have no known advisory: `npm audit --omit=dev` reports none.

## Deploy

```powershell
./scripts/configure-fabric-app.ps1
```

The script is unattended and idempotent; it deploys to the item named `APP_DatabaseHub_Insights` and updates it in place on every run. It never deletes anything. It needs:

1. `SM_DatabaseHub_History` deployed (`./scripts/configure-powerbi.ps1`), and the workspace on an **Active** Fabric capacity: `rayfin up` can start a trial or assign a capacity when a workspace has none, so the script deploys only on an Active one.
2. Node.js 20, 22, or 24 (the CLI's supported versions; it also ran on 26 with npm's EBADENGINE warning).
3. **A one-time sign-in of the Rayfin CLI**, as the demo's Fabric user, in a terminal on the operator's machine:

   ```powershell
   npx --yes --package=@microsoft/rayfin-cli@1.36.2 -- rayfin login --tenant <tenantId>
   ```

   It opens a browser once. The CLI keeps its own token cache and renews it silently; without `-SignIn` (below), the script only reads it (`rayfin login status --json`) and never signs in or out. Service principal sign-in is listed in the [CLI reference](https://learn.microsoft.com/fabric/apps/cli-reference) but isn't supported yet, so there's no unattended CI deploy.

   Or run `./scripts/configure-fabric-app.ps1 -SignIn` (Phase 26b): when the CLI isn't signed in to the demo's tenant, it runs that same sign-in in your console, checks it, and deploys. It runs only in an interactive session; in CI it's **Not supported**, and nothing is deployed.

What it does, as ADR 0012 results in `out/configure-fabric-app.jsonl`:

| Step | Check IDs |
|---|---|
| Validate `fabric/app`: placeholders only, protected assets, the connector, and the pinned CLI | `FABRIC.APP.SOURCE` |
| The subscription guard, then the workspace role and an Active capacity | `PREFLIGHT.GUARD.CONTEXT`, `FABRIC.P5.WORKSPACE`, `FABRIC.P5.CAPACITY` |
| Find the model, the dashboard, and the report by name; build the new-tab links from their IDs | `FABRIC.APP.ITEMS` |
| Mirror `fabric/app` into the Git-ignored stage `out/fabric-app`, write `rayfin/.env` (connector IDs) and `public/dbhub-app.json` (links, the expected account, and the resource group name for the agent prompts), and run `npm ci` when the lock file changed | `FABRIC.APP.STAGE`, `FABRIC.APP.DEPENDENCIES` |
| Node.js, the CLI's sign-in to the demo's tenant, and the two tenant settings | `FABRIC.APP.NODE`, `.SIGNIN`, `.TENANTSETTING`, `.EXECUTEQUERIES` |
| `rayfin up --workspace-id <id> --item-name APP_DatabaseHub_Insights --tenant <id> --yes --json`, then `rayfin up status --json` | `FABRIC.APP.DEPLOY`, `FABRIC.APP.STATUS` |
| Every query in the app's catalog through the connector (`rayfin connector invoke`), anchored to the newest telemetry day; the hosted app refuses anonymous requests | `FABRIC.APP.CONNECTOR`, `.QUERIES`, `.HOSTING` |
| The browser check, which only a person can do | `FABRIC.APP.BROWSER` (**Manual action required**) |

Without `-FabricAdmin`, the tenant settings can't be read; a passing deploy proves **Fabric Apps (preview)** and a passing connector check proves **Dataset Execute Queries REST API** (the connector's runtime calls the [Execute Queries API](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group)), so both become a **Pass**. With `-FabricAdmin`, they're read through the [admin API](https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings).

Options: `-WhatIf` validates the source and lists the plan with no token, network call, or write. `-DryRun` runs everything up to `rayfin up --dry-run`. `-CheckOnly` checks the deployed app without deploying. `-Queries Probe` runs only the connection check. `-TreatManualAsError` exits with code 2 while the browser check is pending.

The CLI's `connector invoke --transport deployed` needs an app session the CLI can't create yet (HTTP 401 in the live check), so the in-app path is the browser check. Measured on 2026-10-22 (F16, West US 3): the first deploy of the item took 53 s; redeploys of the real app took 37 s and 57 s; the whole script took 175 s and 278 s (about 45 s of it the subscription guard, and about 2 minutes the 13 connector calls), and `-CheckOnly` took 124 s. With the Database Agent prompts (14 queries), the redeploy took 47 s and the whole script 265 s.

The CLI writes its deployment record (`rayfin/.deployments.json`, `rayfin/.env`, `.env.local`) in the stage. Those files hold the item ID, the hosting URL, and the app's publishable key, so they stay under `out/`, Git-ignored. The publishable key is public by design (the browser bundle carries it), but the script redacts it from every result and log anyway.

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
npm run verify   # typecheck, lint, Vitest (unit, page, theme-contrast, and override tests), license check, build
```

`./tests/Invoke-StaticValidation.ps1 -Check FabricApp` runs the same in the repository's static validation, and the `Fabric App` CI job runs it on Node.js 24. The tests use fixture rows shaped like the connector's results; no test reaches Fabric.

To run the app locally against the deployed backend, work in the stage (`out/fabric-app`, after a deploy): `npm run dev` writes `.env.local` from the deployment record and serves on `http://localhost:5173`, which `rayfin.yml` allows as a redirect URI. Local sign-in wasn't verified in this phase.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Page not accessible directly" | Open the app from its workspace item (see above) |
| `FABRIC.APP.SIGNIN` is Manual action required | Run the one-time `rayfin login` command in the remediation, then the script again |
| `FABRIC.APP.DEPLOY` says not signed in or the token expired | The CLI's session lapsed; sign in again with the same command |
| `FABRIC.APP.ITEMS` is Manual action required | Deploy the model first: `./scripts/configure-powerbi.ps1` |
| A visual says Fabric refused the query | The viewer needs Read and Build on `SM_DatabaseHub_History`, and the Execute Queries tenant setting |
| `FABRIC.APP.QUERIES` warns that some queries returned no rows | Run `NB_DatabaseHub_LiveActivity` (and a scenario) so the lakehouse has history for that window |
| A Real-Time Dashboard link opens the wrong page | The portal path for dashboards isn't documented; use the workspace link and open `RTD_DatabaseHub_LiveView` |

More in [troubleshooting](../../docs/troubleshooting.md).
