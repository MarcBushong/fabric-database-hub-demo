# Ask's chat relay

The relay connects the Insights app's Copilot dock (Ask, the Copilot chat in the Insights app) with each viewer's own GitHub Copilot. It's a small Node.js service on the [GitHub Copilot SDK](https://github.com/microsoft/copilot-sdk), which runs GitHub Copilot's runtime. `deploy.ps1` runs it as an Azure Container App in the demo's resource group ([ADR 0028](../docs/adr/0028-ask-copilot-in-the-insights-app.md)).

## At a glance

- **What deploys it:** `./scripts/deploy.ps1`, in its Fabric track, with the Insights app (`configure-fabric-app.ps1`): the Container Apps environment `cae-<prefix>-<environment>-ask` (Consumption, no Log Analytics workspace) and the relay `ca-<prefix>-<environment>-ask` (1 vCPU, 2 GiB, 0 to 1 replica) in the demo resource group. It registers the `Microsoft.App` resource provider first when the subscription hasn't. Its checks, `ASK.RELAY`, `ASK.RELAY.HEALTH`, `ASK.CSP`, and `ASK.SIGNIN`, are never a **Fail**: a **Pass**, a **Warning** with its fix, or **Not selected**, and **DONE** stays.
- **You never build it:** the image is public on GitHub Container Registry, `ghcr.io/marcbushong/fabric-database-hub-demo/ask-relay`, pinned by digest in `config/versions.json` (`askRelay.image`), and `deploy.ps1` pulls exactly that digest, with no credentials. You don't run any GitHub Actions workflow; building and publishing the image is for maintainers ([the image](#the-image)).
- **What it costs:** it bills per second, only while a replica runs: it starts with the first question and scales to zero about 10 minutes after the last one ([cost management](../docs/cost-management.md#dated-example-asks-chat-relay-2026-11-18)). The chat itself runs on each viewer's own GitHub Copilot plan. The Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan are outside every estimate.
- **How a viewer signs in:** in the Insights app, **Sign in with GitHub**, once per browser: GitHub's device flow with the OAuth App **Database Hub Insights Ask**, on the GitHub account that has the viewer's Copilot plan ([the app's guide](../fabric/app/README.md#ask-copilot-the-chat-in-the-app)). An organization that restricts OAuth apps has an owner approve it once, and the Fabric tenant setting "Enforce a strict content security policy for static-hosted Fabric Apps (preview)" must stay off.
- **To turn it off:** `"ask": { "enabled": false }` in `config/demo.config.json`, then `./scripts/deploy.ps1`. No relay is deployed, and the dock says Ask isn't deployed; a relay deployed before stays, scaled to zero, until `destroy.ps1`.
- **To remove it:** `./scripts/destroy.ps1` deletes both with the demo resource group. What stays with GitHub: each viewer's authorization of **Database Hub Insights Ask**, which they revoke at <https://github.com/settings/applications> (**Authorized OAuth Apps**), and a browser's sign-in, which **Sign out of GitHub** in the chat's account menu clears ([cleanup](../docs/cleanup.md)).

The rest of this page is for developers and maintainers.

## How it works

The relay holds no Azure, Fabric, or GitHub credential and runs no tool. The page sends the viewer's GitHub token at the start of a conversation, and the relay keeps it in memory for that conversation only. Copilot's tools are declared by the page, and each call goes back to the page to run there, with the viewer's own access: read-only DAX through the app's connector, the app's own charts, and the live estate through the app's function.

## How a question flows

1. **Sign-in, once per browser:** the dock asks the relay to start GitHub's [device flow](https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow) (`POST /auth/device`); the viewer enters the code on github.com and selects **Authorize**; the dock polls through the relay (`POST /auth/token`) and keeps the tokens in the browser's storage. GitHub's endpoints don't allow calls from a browser, so the relay makes them. There's no client secret: the OAuth App's client ID is public by design.
2. **A conversation:** the dock opens a WebSocket (`/chat`) and sends `start` with the viewer's token, the system message (the history model's guide), and its tool declarations. The relay starts a Copilot session for that token and answers `ready`.
3. **A question:** each `user` message streams back as `delta` and `message` events. When Copilot calls a tool, the relay sends `tool_call` to the page, waits for its `tool_result` (at most 150 seconds), and passes it to Copilot. `idle` ends the turn.
4. **Renewal:** GitHub's tokens expire after 8 hours; the dock renews them through the relay (`POST /auth/refresh`) with the 6-month refresh token. **Sign out of GitHub** in the chat's account menu clears them from the browser, and revoking **Database Hub Insights Ask** in the viewer's GitHub settings ends them all ([cleanup](../docs/cleanup.md)).

## Routes

| Route | What it does |
|---|---|
| `GET /healthz` | Version, whether sign-in is on, and the open sessions. Any origin; `deploy.ps1`'s `ASK.RELAY.HEALTH` uses it, and it wakes the relay from zero |
| `POST /auth/device`, `POST /auth/token`, `POST /auth/refresh` | GitHub's device flow and token renewal, for the configured client ID only |
| `GET /auth/user`, `GET /auth/copilot` | The signed-in GitHub account, and whether it can use Copilot, with its plan |
| `GET /chat` (WebSocket) | One conversation: `start`, `user`, `tool_result`, `abort`, and `ping` from the page; `ready`, `delta`, `message`, `tool_call`, `tool_done`, `usage`, `idle`, `error`, and `pong` from the relay (`src/protocol.ts`) |

Every route but `/healthz` serves only the origins in `ALLOWED_ORIGINS`: the app's hosting origin, which `configure-fabric-app.ps1` sets after each deployment of the app. Requests are rate-limited per client, and messages, tools, and results have size limits.

A client is the address Container Apps' ingress appends as the last `X-Forwarded-For` entry, never one the client wrote. It holds at most 4 sockets and runs one new Copilot check (`/auth/copilot`) at a time, 4 in all. A socket must send its `start` within 10 seconds; only started conversations count against `MAX_SESSIONS`, and a start that fails closes its socket. The relay reads request paths as text, and it logs an unexpected error instead of exiting (the security review, 2026-11-19).

## Settings

All from environment variables, and none is a secret. `infra/ask/ask-relay.bicep` sets the first two.

| Variable | Default | What it sets |
|---|---|---|
| `ALLOWED_ORIGINS` | none | Exact origins, comma-separated, without paths or wildcards |
| `GITHUB_CLIENT_ID` | none: sign-in off | The GitHub OAuth App for the device flow |
| `GITHUB_SCOPES` | empty | OAuth scopes the device flow requests; Copilot needs none |
| `MAX_SESSIONS` | 20 | Conversations this replica runs at once |
| `MAX_TURNS` | 40 | Questions in one conversation |
| `SESSION_MAX_MINUTES` | 60 | A conversation's longest life |
| `TOOL_TIMEOUT_SECONDS` | 150 | How long the relay waits for the page to answer one tool call |
| `COPILOT_HOME` | `/tmp/copilot` | The Copilot runtime's state, on the replica's own disk |
| `DEFAULT_MODEL` | empty | The model when the page names none; empty lets Copilot choose |
| `PORT` | 8080 | The HTTP port |

A conversation also ends after 15 minutes without a message from either side (pings don't count); the page closes an idle one after 5. Container Apps then scales the relay to zero.

## The image

You never build this image or run a workflow: `deploy.ps1` pulls the public `ghcr.io/marcbushong/fabric-database-hub-demo/ask-relay` at the digest `config/versions.json` pins (`askRelay.image`), without credentials. When none is pinned, or the image can't be pulled, the relay isn't deployed: `ASK.RELAY` is a **Warning** that says why, and **DONE** stays.

**For maintainers:** `.github/workflows/ask-relay-image.yml` builds it on a push to `main` or `ignite-updates` that changes `ask-relay/**` or the workflow (in a public repository, or with the repository variable `ASK_RELAY_IMAGE_ENABLED` set to `true`), or when run by hand; never on a pull request, and never in a fork. It type-checks and tests the relay, then builds the `Dockerfile` and pushes `ghcr.io/<owner>/<repository>/ask-relay:<commit SHA>`, with the digest in the run's summary and annotations. Its token can only read the repository; only the job that publishes can write packages. The first publish from this public repository makes the package public; a fork's or a private copy's package follows its own repository's visibility. A maintainer then pins the digest in `config/versions.json` (`askRelay.image`).

- **Base images:** Microsoft's Azure Linux Node.js images from `mcr.microsoft.com`, pinned by digest (`askRelay.buildImage` and `askRelay.runtimeImage`): the build stage has npm; the runtime is distroless, with no shell or package manager, and runs as a non-root user.
- **Dependencies:** `npm ci` from `package-lock.json`, with no install scripts; every version is exact.
- **Nothing secret** is in the image, its build, or its settings.
- **Your own image:** build `ask-relay/` with the same `Dockerfile`, push it to a registry Container Apps can pull from without credentials, and set `ask.image` in `config/demo.config.json` to its reference pinned by digest (`<registry>/<repository>@sha256:<digest>`).

## Develop and test

```powershell
cd ask-relay
npm ci
npm run verify   # typecheck, Vitest (protocol, bridge, and server tests with a stand-in Copilot), build
```

The tests never reach GitHub or Copilot. To run it locally, `npm run build`, then set `ALLOWED_ORIGINS=http://localhost:5173` and `GITHUB_CLIENT_ID` and run `npm start`.
