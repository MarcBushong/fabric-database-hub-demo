# Ask's chat relay

The relay connects the Insights app's Copilot dock (Ask) with each viewer's own GitHub Copilot. It's a small Node.js service on the [GitHub Copilot SDK](https://github.com/microsoft/copilot-sdk), which runs GitHub Copilot's runtime. `deploy.ps1` runs it as an Azure Container App in the demo's resource group ([ADR 0027](../docs/adr/0027-ask-copilot-in-the-insights-app.md)).

The relay holds no Azure, Fabric, or GitHub credential and runs no tool. The page sends the viewer's GitHub token at the start of a conversation, and the relay keeps it in memory for that conversation only. Copilot's tools are declared by the page, and each call goes back to the page to run there, with the viewer's own access: read-only DAX through the app's connector, the app's own charts, and the live estate through the app's function.

## How a question flows

1. **Sign-in, once per browser:** the dock asks the relay to start GitHub's [device flow](https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow) (`POST /auth/device`); the viewer enters the code on github.com and selects **Authorize**; the dock polls through the relay (`POST /auth/token`) and keeps the tokens in the browser's storage. GitHub's endpoints don't allow calls from a browser, so the relay makes them. There's no client secret: the OAuth App's client ID is public by design.
2. **A conversation:** the dock opens a WebSocket (`/chat`) and sends `start` with the viewer's token, the system message (the history model's guide), and its tool declarations. The relay starts a Copilot session for that token and answers `ready`.
3. **A question:** each `user` message streams back as `delta` and `message` events. When Copilot calls a tool, the relay sends `tool_call` to the page, waits for its `tool_result` (at most 150 seconds), and passes it to Copilot. `idle` ends the turn.
4. **Renewal:** GitHub's tokens expire after 8 hours; the dock renews them through the relay (`POST /auth/refresh`) with the 6-month refresh token.

## Routes

| Route | What it does |
|---|---|
| `GET /healthz` | Version, whether sign-in is on, and the open sessions. Any origin; `deploy.ps1`'s `ASK.RELAY.HEALTH` uses it, and it wakes the relay from zero |
| `POST /auth/device`, `POST /auth/token`, `POST /auth/refresh` | GitHub's device flow and token renewal, for the configured client ID only |
| `GET /auth/user`, `GET /auth/copilot` | The signed-in GitHub account, and whether it can use Copilot, with its plan |
| `GET /chat` (WebSocket) | One conversation: `start`, `user`, `tool_result`, `abort`, and `ping` from the page; `ready`, `delta`, `message`, `tool_call`, `tool_done`, `usage`, `idle`, `error`, and `pong` from the relay (`src/protocol.ts`) |

Every route but `/healthz` serves only the origins in `ALLOWED_ORIGINS`: the app's hosting origin, which `configure-fabric-app.ps1` sets after each deployment of the app. Requests are rate-limited per client, and messages, tools, and results have size limits.

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

A conversation also ends after 15 minutes without a message; the page closes an idle one after 5. Container Apps then scales the relay to zero.

## The image

`.github/workflows/ask-relay-image.yml` builds it on `main` when `ask-relay/**` changes, or when run by hand: it type-checks and tests the relay, then builds the `Dockerfile` and pushes `ghcr.io/<owner>/<repository>/ask-relay:<commit SHA>`, with the digest in the run's summary. The repository's owner makes the package public once and pins its digest in `config/versions.json` (`askRelay.image`); `deploy.ps1` runs exactly that digest. Deployers never run the workflow.

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
