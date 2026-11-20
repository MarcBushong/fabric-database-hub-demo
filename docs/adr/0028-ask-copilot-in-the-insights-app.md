# ADR 0028: Ask: GitHub Copilot chat in the Insights app

- **Status:** Accepted. Proven live on 2026-11-18: sign-in, the Copilot SDK on a viewer's Copilot Enterprise, the relay on Azure Container Apps with the app's origin, and the live-estate core. The in-browser check of the Fabric-hosted app waits for the owner's rehearsal.
- **Date:** 2026-11-18
- **Decision source:** User-directed, after Ignite 2026: "Create a new branch and do them all ... Since there is GitHub Copilot support that we can then use to put into the Fabric app as well as a chat interface in the Rayfin app vs going to the GHCP locally"; "The goal would be to get insights from the data and trends and perform conversational analytics directly in the rayfin app"; "github copilot license is what I meant to say that all users would have"; "The GitHub Copilot chat interface right in the App is a must and a gamechanger"; "Make sure to account for users signing in and demoing this themselves and repeatable. Simple and one click as possible". The coordinator's decisions 1 to 4 (2026-11-18) are below.
- **Related:** [ADR 0013](0013-agent-experience.md) (amended the same day), [ADR 0008](0008-identity-rbac-abac.md), [ADR 0012](0012-validation-model.md), [ADR 0016](0016-cost-profiles.md), [ADR 0022](0022-public-repository-and-github-actions-hardening.md), [ADR 0024](0024-nightly-safety-stop.md), `fabric/app/src/copilot/`, `fabric/app/rayfin/functions/`, `ask-relay/`, `infra/ask/`

## Context

- **Every demo user has a GitHub Copilot license,** and the GitHub Copilot SDK (`@microsoft/copilot-sdk`, GA) runs a Copilot session on a user's own GitHub token. It runs its Copilot runtime as a local process, so it can't run in a browser page.
- **GitHub's sign-in endpoints don't allow browser calls** (no CORS), and github.com can't be framed: a page signs a viewer in through a server, with the device flow in a new tab.
- **The Insights app is a Fabric App** (Fabric Apps, GA on 2026-11-17). Its code never sees an Entra token. Its semantic model connector runs DAX as the signed-in viewer (delegated), and its functions run server-side TypeScript as the app item's owner, with at most 240 seconds per call and no streaming.
- **Database Hub is GA, but has no public API** for the estate. Its GA CLI skill, `databasehub-cli`, reads inventory, health, and security posture through Database Hub's own routes, which its reference says aren't a public contract.

## Decision

### The dock, in the app (`fabric/app/src/copilot/`)

- Docked on the right, resizable, with a full-screen mode, on the app's contract (`contract.ts`): the shell calls only `useCopilot()`, `useCopilotDock()`, and `useCopilotAccount()`, and every visual and table has **Ask Copilot** and **Ask why** (`useCopilot().ask`), with its title, rows, and DAX.
- Streaming answers, with the app's own charts and tables in the conversation (`ChartView`), **Show the source** on every answer (the DAX it ran, or the Database Hub routes that answered), suggested follow-ups, the prompt pack's DBA questions as starters, copy and export (Markdown with every query), and the conversation kept for the browser session. **New chat** starts over, so every session is repeatable.
- Starters show only what the environment can answer: the live ones when the estate function is deployed, and T5's (Azure Cosmos DB) once the history holds its metrics, which one `[Has Cosmos DB Bins]` query checks when the dock first opens. The system message teaches T5's measures from its latest capture, because two captures of one period both count in sums, and that T5's container usually exists only during a session ([ADR 0027](0027-t5-cosmos-db.md)), so a T5 with no RU between sessions isn't a fault.
- The account line says `GitHub: <login> · Copilot <plan>`, with **Switch GitHub account** and **Sign out of GitHub**. Clear states for: Ask not deployed, the relay starting from zero, GitHub sign-in not set up, an account without Copilot, an organization that blocks the app (and what its owner approves), and an expired or revoked sign-in.

### Tools that run in the page, as the viewer

| Tool | What it does | Bounds |
|---|---|---|
| `run_dax` | One DAX query on `SM_DatabaseHub_History` through the app's delegated connector | `EVALUATE` only, 2,000 rows kept, 120 rows to the model |
| `show_chart` | Draws a native chart from a `run_dax` result | `validateChartSpec`, the app's units |
| `suggest_followups` | Follow-up questions as buttons | 4 at most |
| `estate_overview` | The live estate, through the app's estate function | Only when it's deployed |

The model gets a guide to the history model, generated from its TMDL (`model-guide.generated.ts`, `npm run guide:build`): table, column, and measure names, never data.

### The relay (`ask-relay/`)

- A Node.js service on the Copilot SDK, in an Azure Container App in the demo resource group (`infra/ask/ask-relay.bicep`): scale to zero, at most one replica, external HTTPS ingress with WebSocket.
- One Copilot session per WebSocket, on the viewer's own token, with the page's tools forwarded to the page and their answers sent back. The relay runs no tool itself and turns every built-in Copilot tool, agent, and skill off.
- GitHub's device flow (start, poll, and refresh) and the account checks, because GitHub's endpoints don't allow browser calls.
- **It holds no credential:** no Azure, Fabric, or GitHub secret, no registry credential, no managed identity, and no role. Its only settings are the OAuth App's public client ID and the one origin it serves, the app's hosting origin.
- Limits: the app's origin only (HTTP and WebSocket), rate limits per client, 20 sessions, 40 turns and 60 minutes per session, 150 seconds per tool call, and a 15-minute idle close. It logs event names and counts, never content or tokens.
- After the security review (2026-11-19): limits key on the address the ingress appends to `X-Forwarded-For`; a client holds at most 4 sockets and runs 1 new Copilot check at a time (4 in all); a socket must start within 10 seconds, only started conversations count against the 20, and a failed start closes its socket on both sides; request paths are read as text, and an unexpected error is logged, never fatal. The page renews the GitHub token before it's needed, one tab at a time, and ends a sign-in only when GitHub refuses the refresh token ([security model](../security-model.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)).

### Decision 1: GitHub sign-in

One GitHub OAuth App, **Database Hub Insights Ask**, owned by MarcBushong, with the device flow on and no client secret. Its client ID ships in `config/versions.json` (`askRelay.githubClientId`), so a deployer registers nothing; `ask.githubClientId` in `config/demo.config.json` overrides it. Tokens expire after 8 hours, and their refresh tokens (6 months) renew them through the relay without a secret, so a viewer signs in once per browser. Sign-in is per browser storage: the app in the Fabric portal's frame and the app at its own address are separate.

### Decision 2: the relay's image

A public image on GitHub Container Registry, built and published by this repository's own workflow (`.github/workflows/ask-relay-image.yml`) on a push to `main` or `ignite-updates` that changes `ask-relay/` or the workflow, or by hand on any branch; never on a pull request or in a fork. Tagged with the commit SHA and pinned by digest in `config/versions.json` (`askRelay.image`). The first publish from this public repository made the package public (2026-11-19), and the owner keeps it public and pinned: a public package can't be made private again, only deleted ([GitHub Docs](https://docs.github.com/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)). A fork's or a private copy's package can start private, GitHub's default for a new package, so its owner makes it public or sets `ask.image`. Both base images are Microsoft's Azure Linux Node.js images from MCR, pinned by digest; the runtime is distroless and non-root. Users never run a workflow: `deploy.ps1` pulls the pinned digest. `ask.image` lets an advanced user run their own image, pinned by digest and pullable without credentials. Without an image, Ask isn't deployed: a Warning, and DONE stays.

### Decision 3: the live estate

The app's function, `estateOverview` (`fabric/app/rayfin/functions/src/`), as the app identity (the app item's owner), reads the GA skill's 8 read-only routes (its inventory view also carries each SQL Server instance's migration assessment, readiness per Azure target, which Database Hub doesn't raise as an issue), under the narrow exception that [ADR 0013](0013-agent-experience.md#amendment-2026-11-18-the-ga-skill-and-one-narrow-exception) records: an exact allowlist, every query scoped to the demo's own subscription and resource group, its own User-Agent (`DbHubDemo-InsightsApp/<version>`), not the skill's telemetry header, 30 seconds per call and 90 per answer, and one answer shared for 60 seconds. Errors come back with their source; when the routes change, the dock and the pages say the live estate is unavailable, and every history answer keeps working. Pages use the same source and cache: `readEstate(view)` in `src/copilot/estate.ts`, which the pages' `useLiveEstate(view)` (`src/data/live-estate.ts`) loads.

### Decision 4: what a user does

- **A deployer:** nothing extra. `./scripts/deploy.ps1` sets up the relay with the app, and the client ID ships in the configuration.
- **A viewer:** opens the app, selects **Ask Copilot**, and signs in with GitHub once per browser (one button copies the code and opens github.com/login/device; the dock continues by itself).
- **Only when the tenant or organization asks for it:** an organization with OAuth app access restrictions has an owner approve **Database Hub Insights Ask** once (the dock says so); and the Fabric tenant setting "Enforce a strict content security policy for static-hosted Fabric Apps (preview)" stays off, as it is by default (`deploy.ps1` reports a Warning when it's on).

### One click, and never in the way

- **Deploy:** `configure-fabric-app.ps1`, the Insights app's step in `deploy.ps1`, sets up the relay before it stages the app (registering `Microsoft.App` when it isn't), sets the relay's origin once `rayfin up` has named it, wakes and checks the relay, and reads the strict-CSP setting. Its results, `ASK.RELAY`, `ASK.RELAY.HEALTH`, `ASK.SIGNIN`, and `ASK.CSP`, are Pass, Warning, or Not selected, never a Fail: the status page has its own row (**Copilot chat in the app**), and a Warning line that never blocks DONE.
- **Sessions:** `start-demo.ps1` wakes the relay, so the first question is fast.
- **Delete:** `destroy.ps1` deletes it with the demo resource group. **Turn off:** `"ask": { "enabled": false }`.
- **Cost:** Container Apps bills the relay per second only while its replica runs, that is while someone uses the chat; idle, it costs nothing (`estimate-cost.ps1` prices it from the Azure Retail Prices API).

### The presenter's fallback

The local GitHub Copilot CLI and VS Code path stays, with the GA `databasehub-cli` skill ([agent guide](../../fabric/agent/README.md)).

## What reaches GitHub Copilot

- **Sent:** the viewer's questions; the system message (the model guide: names only); the answers of the read-only tools the viewer's Copilot calls (at most 120 rows per query, and the live estate's resource names and findings, for the demo's resource group only); and, when the viewer selects **Ask Copilot** or **Ask why**, that visual's title, DAX, and at most 200 of its rows.
- **Never sent:** an Azure or Fabric token (the app never has one), a password or key, or anything outside the demo's own data.
- **The GitHub token** stays in the browser's storage for the app's origin, and goes only to the relay, over HTTPS, which uses it for the viewer's Copilot session and GitHub's account endpoints and keeps it only in that session's memory. **Sign out of GitHub** removes it from the browser; GitHub's settings revoke the app's tokens.

## Consequences

- **Positive:** conversational analytics in the app, on each viewer's own Copilot, with nothing to install; one click for the deployer and one sign-in per browser for a viewer; repeatable sessions; a relay that costs nothing idle and holds no credential.
- **Negative:** one more Azure resource (a Container App) and its image's release (the owner's workflow, then a pin). The first question after an idle period waits about 15 seconds for the relay to start, unless `start-demo.ps1` woke it. Sign-in is per browser storage. Database Hub's routes can change without notice. An organization's OAuth app policy or a tenant's strict CSP can block it, and the dock says so.

## Alternatives considered

- **The SDK in the browser:** it runs a local runtime process, and GitHub's endpoints don't allow browser calls.
- **Fabric Apps functions as the relay:** no streaming, no WebSocket, and 240 seconds per call.
- **Building the image at deploy time (an Azure Container Registry per environment):** a registry credential or a role assignment, about 0.17 USD a day, and a build on every deploy.
- **The viewer's own Entra token for the live estate:** Fabric Apps code never gets one. **The lakehouse's snapshot for "now":** no Cosmos DB and no security posture.
- **Each deployer registering their own OAuth App:** a manual step for every environment; it stays possible as an override.

## Validation (2026-11-18)

- **Live, Phase 0:** the device flow through the registered app, then a Copilot SDK session on Copilot Enterprise, a refresh without a secret, and a second session on the refreshed token. The relay on Azure Container Apps: about 14 seconds from zero, 1.4 seconds warm; the app's exact origin over HTTP, the CORS preflight, and WebSocket, and any other origin refused (HTTP 403). The Fabric-hosted app deployed with its function; the strict-CSP setting off. The live-estate core against Database Hub for the demo's resource group: inventory, health, and security, with no errors. The distroless image gets as far as the Copilot runtime's sign-in check.
- **Tests:** `ask-relay` (Vitest), `fabric/app/src/copilot` (Vitest), and `tests/unit/DbHubDemo.Ask.Tests.ps1` and the cost tests (Pester).
- **Pending, for the owner's rehearsal:** a real Copilot turn through the deployed relay on the pinned image, and the in-browser check in the Fabric portal (the GitHub tab from the portal's frame, the dock, and the deployed function's live call).

## Sources (checked 2026-11-18)

- GitHub Copilot SDK: <https://github.com/microsoft/copilot-sdk>
- GitHub OAuth apps, the device flow: <https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow>
- Azure Container Apps: <https://learn.microsoft.com/azure/container-apps/overview>, [scaling](https://learn.microsoft.com/azure/container-apps/scale-app), [ingress](https://learn.microsoft.com/azure/container-apps/ingress-overview), [template reference](https://learn.microsoft.com/azure/templates/microsoft.app/containerapps)
- Fabric Apps: [functions](https://learn.microsoft.com/fabric/apps/functions), [connectors](https://learn.microsoft.com/fabric/apps/connectors), [hosting](https://learn.microsoft.com/fabric/apps/hosting)
- Fabric admin API, Tenants - List Tenant Settings: <https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings>
- The GA Database Hub skill: <https://github.com/microsoft/skills-for-fabric/tree/main/skills/databasehub-cli>

## Amendment (2026-11-19): every turn ends with an answer, or says it has none (R925)

Live on 2026-11-19, a turn ended with its query rows and follow-ups and no answer, and Copilot told the owner "The live view returned 401 on every call". From the code, the relay and the dock lost no text the SDK delivered: Copilot ended the turn without writing one, after `suggest_followups`, and the dock had no state for that. The "401" was the estate tool's own answer to Copilot.

- **The relay reads the turn back before `idle`.** At `session.idle`, it reads the turn's assistant messages from the session's history (`CopilotSession.getEvents`, at most 5 seconds) and sends any text the page didn't get (a message that came only as deltas, or after idle), never twice. Then `idle`.
- **The relay logs each turn's end,** `chat.turn.end`, with counts and lengths only: duration, tool calls and failures, messages, text and final-answer lengths (the final answer as the dock counts it: the text after the last query), and each message's text length and tool requests.
- **The dock never finishes silently.** A turn has an answer when it has text after its last query. A finished turn without one, and without an error, says "Copilot didn't write an answer" with **Retry**, which asks the same conversation to write it, in the same turn.
- **The guidance:** Copilot writes the answer after its last query, then calls `suggest_followups`, which only adds buttons. When it calls `suggest_followups` with nothing written since its last query, the tool's answer reminds it. It never shows HTTP codes, error codes, routes, or raw errors: the viewer may be presenting.
- **The live view when it isn't available** (the coordinator's contract with the estate function, R924):
  - **What Copilot reads:** the function's answer gains `unavailable`, one plain sentence, when no route answered for an authentication reason. Copilot gets only that sentence, or the dock's own "Database Hub's live view didn't answer just now." when no route answered for another reason. A route answered only when none of its calls failed: the function lists each route it calls, the failed ones too. The per-route errors stay in the function's log, and Copilot never gets route names; the dock's row lists the routes that answered, like a query's DAX.
  - **For the rest of the conversation:** the dock doesn't call the live view again, and a new session in it doesn't offer it; the system message says to answer from the history and point to Database Hub's own pages. **New chat** tries again, even when a live call from the last conversation ends after it: what that call returns changes nothing in the new one. A session that the last conversation was still starting when **New chat** came is closed unused once it's ready, and its question is dropped quietly; the new conversation's first question starts its own session (the re-review, 2026-11-19).
  - **When Database Hub refuses the app as a whole** (the coordinator's decision for the owner's question 2): a new conversation starts without the live view, and the dock hides its live starters. The dock follows the pages' own signal (`src/data/live-estate.ts`): every view `unavailable`, by the latest read of each in this browser, whichever page or the dock read it (`liveOffNow`, which `onLiveOffChange` reports after each read). So it follows later reads while it stays open, and the dock and the pages agree. While the dock is open, it reads the three views itself too, as `useLiveOff` does, and again for each new conversation. One view's refusal isn't a whole one, and once any view's read has data, new conversations use the live view again.
