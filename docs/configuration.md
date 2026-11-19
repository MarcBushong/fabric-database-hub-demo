# Configuration

`config/demo.config.json` holds your settings. Git ignores it, and it holds no secrets. Start from `config/demo.config.example.json`; `config/environment.schema.json` is the source of truth for every setting, its default, and its rules, and every script validates the file against it before it does anything.

This page explains the settings whose behavior needs more than the schema's description. Each section belongs to the feature it configures.

## The settings you're most likely to change

`./scripts/init.ps1`, or `deploy.ps1`'s first run, writes the file. A change takes effect at the next `./scripts/deploy.ps1`.

| Setting | Default | What it does |
|---|---|---|
| `subscriptionId`, `tenantId` | Your sign-in's, from `init.ps1` | Where the demo deploys. The [subscription guard](prerequisites.md#target-subscription-configuration-the-subscription-guard) checks them before any Azure call |
| `location`, `prefix`, `environment` | `westus3`, `dbhub`, `demo` | The region, and the names: the demo resource group is `rg-<prefix>-<environment>` |
| `profile` | `lowest-cost` | The sizes, and so the cost ([ADR 0016](adr/0016-cost-profiles.md)) |
| `t4SkuName` | Not set: `Standard_D4ds_v5`, with a fallback when Azure refuses it | T4's size ([deployment](deployment.md#t4s-size-the-4-vcore-default-and-its-fallback-2026-11-04)) |
| `monthlyCeilingUsd`, `sessionCeilingUsd` | `415` for a new configuration, and `20` | [The cost ceilings](#the-cost-ceilings) |
| `t5Enabled`, `t5UseFreeTier` | `true`, and `true` | [T5, Azure Cosmos DB](#t5-azure-cosmos-db) |
| `autoShutdownTime`, `autoShutdownTimeZone`, `t3AutoPauseMinutes` | `1900`, `Pacific Standard Time`, and `15` | When the demo stops: [the nightly safety stop](#the-nightly-safety-stop) |
| `activityProfile` | `business-day` | The activity `deploy.ps1` and `start-demo.ps1` set on the targets; `baseline` for a quiet demo |
| `presenterObjectIds` | Empty | [Presenters](#presenters) |
| `fabric.*` | In its section | [Fabric](#fabric) |
| `control.*` | In its section | [The session control](#the-session-control) |
| `ask.*` | In its section | [Ask](#ask-the-copilot-chat-in-the-insights-app) |

## Fabric

The demo's Fabric items live in one workspace and its lakehouse, which you configure **by name**. The scripts resolve their IDs at run time and create them when they're missing ([ADR 0021](adr/0021-fabric-resources-by-name.md)); you never look up or store a Fabric ID.

```json
"fabric": {
  "workspaceName": "Database Hub Demo",
  "lakehouseName": "LH_DatabaseHub",
  "capacityName": "your-fabric-capacity",
  "createIfMissing": true,
  "importNotebooks": false,
  "manageCapacity": false,
  "saveHistoryOnStop": false
}
```

| Setting | Default | What it does |
|---|---|---|
| `workspaceName` | `Database Hub Demo` | The workspace that holds the notebooks, the lakehouse, the Real-Time Dashboard, the history model and report, and the Insights app. The scripts find the one workspace with this name among those you can access (personal workspaces are skipped). Each environment needs its own: two environments in one workspace overwrite each other's notebooks, and `deploy.ps1` says so in a **Warning** (`DEPLOY.FABRIC.SHARED`) |
| `lakehouseName` | `LH_DatabaseHub` | The lakehouse the notebooks write their history tables to, and the history model reads, in that workspace |
| `capacityName` | empty | The Fabric capacity to create the workspace on, or to assign it to when it has none. It must be an F or Trial capacity that you administer or contribute to, and it must be running. Not used when the workspace exists and has a capacity |
| `createIfMissing` | `true` | Create the workspace (on `capacityName`) and the lakehouse when they're missing |
| `importNotebooks` | `false` in the schema; `init.ps1` writes `true` for a workspace it will create | Whether `deploy.ps1` also updates the notebooks when they're already in the workspace. With `true`, it creates or updates them on every run, so an update republishes them. With `false`, it imports only the notebooks that are missing, so a new workspace or lakehouse gets them without asking, and edits you made in Fabric are kept. `init.ps1`, or `deploy.ps1`'s first run, writes `true` when the workspace doesn't exist yet, and, for an environment that's already deployed, when the workspace is that environment's own (`INIT.EXISTING` says which, and why); otherwise `false`. Running `configure-fabric.ps1` yourself always creates or updates them |
| `manageCapacity` | `false` | Opt-in, only for a capacity that's yours alone ([ADR 0023](adr/0023-first-run-automation.md)): `start-demo.ps1` resumes the capacity in `capacityName` when it's paused, and `stop-demo.ps1` and `destroy.ps1` pause only a capacity it resumed. It must be an F capacity in the configured subscription (Contributor on it is enough); a Trial capacity, or one in another subscription, is **Not supported**. Keep it `false` for a shared capacity |
| `saveHistoryOnStop` | `false` | With `true`, `stop-demo.ps1` also saves the session's history to the lakehouse once the VMs are stopped, as `stop-demo.ps1 -SaveHistory` does (at most 15 minutes), and before it pauses a capacity that `manageCapacity` let it resume |
| `workspaceId`, `lakehouseId` | not set | Optional overrides, not needed: an ID here is used as it is, and the name isn't looked up. They're kept for configurations written before ADR 0021; the all-zero ID counts as not set |

**What happens on a deploy** (`deploy.ps1`'s Fabric track, or `configure-fabric.ps1`):

1. The workspace is found by name. When it's missing and `createIfMissing` is true, it's created on `capacityName`; a workspace without a capacity is assigned to it.
2. The lakehouse is found by name in that workspace, or created with lakehouse schemas: the history model reads its tables from the `dbo` schema.
3. The notebooks are imported, bound to that lakehouse. The repository's notebooks hold no IDs: the import puts the resolved ones in the uploaded copy, and every scripted run passes them as parameters. When `github.repository` is set, and isn't the example's placeholder, the deployment notebook's links to the repository (`GITHUB_REPOSITORY`) point at it; otherwise they point at the public repository. No notebook starts GitHub Actions (since 2026-11-14).
4. When the live-activity notebook was just created, or the lakehouse was, the notebook runs once, so the history tables exist before the model's refresh. It writes only the lakehouse's tables.
5. The Real-Time Dashboard, the model and report, and the app go into the same workspace.

The control notebook `NB_DatabaseHub_Control` goes in with the session control's setup, also in `deploy.ps1`: into the demo workspace's folder "DBHub Control", or, where a policy makes new Key Vaults private, into its own workspace ([the session control](#the-session-control)).

**What the scripts never do:** create or scale a capacity. They resume or pause one only with `manageCapacity` `true`, for a capacity that's yours alone, and Run all never resumes it. A paused capacity is **Manual action required**, and you or its administrator resume it. Fabric doesn't list a paused capacity's lakehouses (HTTP 404 `CapacityNotActive`), and a list that didn't answer says nothing about whether an item exists, so no check calls one missing then (live finding, 2026-11-10); `status.ps1` looks the lakehouse up among the workspace's items instead. Scripts that only read (`preflight.ps1`, `status.ps1`, `validate.ps1`) never create anything; when the workspace or lakehouse doesn't exist yet, they report a **Warning** that names the step that creates it.

**What creating needs:** the Fabric tenant setting "Create workspaces" for you, and a contributor or administrator role on the capacity ([prerequisites](prerequisites.md), P5). Without them, the script reports **Manual action required** with the exact steps, and a workspace administrator can create the workspace and add you as Contributor or higher instead. Using an existing workspace needs only Contributor on it.

**Checks** (ADR 0012): `FABRIC.RESOLVE.WORKSPACE`, `FABRIC.RESOLVE.LAKEHOUSE`, and, when a capacity is assigned, `FABRIC.RESOLVE.CAPACITY`, in `configure-fabric.ps1`, `configure-powerbi.ps1`, `configure-fabric-app.ps1`, and `validate.ps1`; `PREFLIGHT.P5.WORKSPACE` in `preflight.ps1`; and `STATUS.FABRIC` in `status.ps1`. Messages name the workspace, the lakehouse, and the capacity, never their IDs.

## The cost ceilings

| Setting | Default | What it does |
|---|---|---|
| `monthlyCeilingUsd` | `415` for a new configuration | A hard ceiling for a month of idle and light use: preflight, `start-demo.ps1`, and `estimate-cost.ps1` fail when the estimate is above it (`PREFLIGHT.COST.MONTHLY`), and preflight names the amount to raise it to. The month's worst case counts T4's 7-day automatic restart: about a day per restart while a safety stop is fully in place, otherwise the rest of the month (`PREFLIGHT.COST.T4RESTART`). It's also the Azure budget's amount, with alerts at 50, 80, and 100 percent; `./scripts/deploy.ps1 -FromStage Infrastructure` updates the budget. No run changes the value in your configuration. A T4 size that `deploy.ps1`'s fallback chose, because Azure refused the one you asked for, never makes it a **Fail** by itself: that's a **Warning** |
| `sessionCeilingUsd` | `20` | The ceiling for one session: preflight, `start-demo.ps1`, and `estimate-cost.ps1` report a **Warning** above it, never a **Fail** (`PREFLIGHT.COST.SESSION`). A configuration with exactly `15`, the default before 2026-11-18, gets `20` with no edit, and `deploy.ps1` says so in one line; any other value stays |

`./scripts/estimate-cost.ps1` prices both from Azure's list prices at run time, with no sign-in. Outside every estimate: the Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan, which Ask uses ([cost management](cost-management.md#at-a-glance)).

## T5, Azure Cosmos DB

T5 is the Azure Cosmos DB for NoSQL account `cosmos01-<id>` ([ADR 0027](adr/0027-t5-cosmos-db.md)), in every deployment since 2026-11-18, an upgrade of an existing demo included. Its defaults need no edit.

| Setting | Default | What it does |
|---|---|---|
| `t5Enabled` | `true` | `false` leaves T5 out: `deploy.ps1` neither creates nor checks it and says so (`DEPLOY.T5.OFF`, **Not selected**), and Database Hub shows T1 to T4. Set it only when your subscription can't have an Azure Cosmos DB account, for example where a policy denies it (preflight's `PREFLIGHT.POLICY.RESOURCETYPES` says so). An account an earlier run created stays, and keeps billing, until `destroy.ps1` |
| `t5UseFreeTier` | `true` | T5 takes the subscription's free-tier account, which makes the first 1,000 RU/s and 25 GB of one Azure Cosmos DB account in a subscription free, when no other account in the subscription has it. Azure doesn't offer it to internal subscriptions, and sets it only when it creates an account, so an existing T5 keeps what it has. `deploy.ps1` names the account that has it when another does, and creates T5 without it when Azure refuses it (`DEPLOY.T5.FREETIER`). `false` never uses it |

T5's container, which holds its 400 RU/s, exists only during a session (since 2026-11-19) once the session control's role can create it again: the starts create it, and the stops delete it. Until then, it stays between sessions and bills all month. An Owner's `./scripts/deploy.ps1`, or an Owner's `./scripts/grant-safety-stop.ps1` once, gives that role, and `DEPLOY.T5.LIFECYCLE` says which applies ([cost management](cost-management.md#t5-azure-cosmos-db-2026-11-18)).

## Presenters

| Setting | Default | What it does |
|---|---|---|
| `presenterObjectIds` | Empty | The Microsoft Entra object IDs of users who present the demo but aren't Contributors. `deploy.ps1` adds them to the demo's Fabric workspace as Viewers, whatever `assignRoles` says (since 2026-11-18, `FABRIC.PRESENTER.VIEWER`), so they can open the Real-Time Dashboard, the history report, and the Insights app. With `assignRoles` `true`, they also get the Azure roles Database Hub needs: Reader on the subscription, and the Arc telemetry role on the demo resource group for T2's performance data (P8). Without `assignRoles`, `configure-fabric.ps1` prints the commands for someone who may assign roles ([presenter access](permissions.md#presenter-access)) |

On a capacity smaller than F64, each viewer of the history report needs Pro, PPU, or a trial; plan the same for the Insights app, which reads the same model (P11, [prerequisites](prerequisites.md#each-prerequisite-and-how-its-checked)).

## The nightly safety stop

The nightly safety stop ([ADR 0024](adr/0024-nightly-safety-stop.md)) is part of every deployment and has no setting of its own. It follows three settings, and the next `deploy.ps1` moves its schedules when one changes:

| Setting | Default | What it sets |
|---|---|---|
| `autoShutdownTime` | `1900` | The stop's daily time, the same as the VMs' auto-shutdown |
| `autoShutdownTimeZone` | `Pacific Standard Time` | The time zone of both its schedules |
| `t3AutoPauseMinutes` | `15` | The T3 check's time: 30 minutes after the stop, or this delay plus 15 minutes when that's longer, at most 345 minutes. With `-1` (auto-pause off), the check reports that T3 stays online |

To skip one night, turn off every schedule that [what stops or pauses on its own](../README.md#what-stops-or-pauses-on-its-own) lists, not only `dbhub-safety-stop`: its T3 check stops T4 too, and the VMs' own auto-shutdown deallocates them. The next `deploy.ps1` turns the safety stop on again. The control's daily T4 safety stop still stops a running T4 at its own time, `control.t4SafetyStopTime` ([the session control](#the-session-control)).

## The session control

The session control (formerly the on-demand activity control) runs a whole session from one Run all in `NB_DatabaseHub_Control` ([ADR 0026](adr/0026-one-run-all-session.md)). It's part of every deployment since 2026-11-14, and its defaults need no edit. Its roles are in [permissions](permissions.md#the-on-demand-activity-control).

| Setting | Default | What it does |
|---|---|---|
| `control.enabled` | `true` | Ignored since 2026-11-14. An older configuration's `false`, which `init.ps1` wrote, doesn't turn the control off (`DEPLOY.CONTROL.ON` says so); `true` marks a control set up before then, whose workspace name `deploy.ps1` keeps |
| `control.vaultNetworkMode` | `auto` | The control vault's network access. `auto` reads the tenant's policy assignments: public, with the control notebook in a folder of the demo's workspace, where new vaults can stay public; private, with the notebook in its own workspace and a managed private endpoint, where a policy makes them private. `public` and `private` choose a path; `public` is refused where a policy would make the vault private |
| `control.fabricFolderName` | `DBHub Control` | With a public vault: the folder of the demo's workspace that holds the control notebook |
| `control.fabricWorkspaceName` | Empty: the demo workspace's name followed by " Control" | With a private vault: the control notebook's own workspace, on the demo workspace's capacity. Like `fabric.workspaceName`, each environment needs its own (`DEPLOY.FABRIC.SHARED`). "DBHub Control", the earlier default, stays only with `"enabled": true`, a control set up before 2026-11-14 |
| `control.roleNameSuffix` | Empty: the shared roles | Gives this environment its own two custom roles, "DbHub Demo Activity Operator" and "DbHub Demo Session Writer" with the suffix in parentheses, for an environment that shares its subscription with a demo on other code: custom roles belong to the whole subscription |
| `control.notebookUserObjectIds` | Empty | More users who get Key Vault Secrets User on the control vault's three secrets (A3), which Run all reads: the webhook's URL, and the session's status and metrics. They're granted with the control's other roles |
| `control.t4SafetyStopTime` | Empty: 15 minutes after `autoShutdownTime` | The time of the control's daily T4 safety stop, as `HH:mm` in `autoShutdownTimeZone` |
| `control.webhookExpiryDays` | `90` | Days until a new webhook expires, 15 to 365. `./scripts/setup-activity-control.ps1 -RotateWebhook` replaces it, and `status.ps1` warns 14 days before |

## Ask, the Copilot chat in the Insights app

Ask ([ADR 0028](adr/0028-ask-copilot-in-the-insights-app.md)) is part of every deployment, and its defaults need no edit: `deploy.ps1` deploys its chat relay with the Insights app, and each viewer signs in to GitHub once per browser, on their own GitHub Copilot plan.

```json
"ask": {
  "enabled": true,
  "image": "",
  "githubClientId": ""
}
```

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `true` | `false`: no relay is deployed, and the app's Copilot dock says Ask isn't deployed. A relay deployed before stays, unused and scaled to zero, until `destroy.ps1` |
| `image` | empty: the public image that `config/versions.json` pins by digest (`askRelay.image`), which nobody who deploys builds | Your own relay image, a full reference pinned by digest (`<registry>/<repository>@sha256:<digest>`) that Azure Container Apps can pull without credentials, for example one you built from `ask-relay/` |
| `githubClientId` | empty: the shared OAuth App **Database Hub Insights Ask** (`askRelay.githubClientId`) | Your own GitHub OAuth App's client ID, with **Enable Device Flow** on and no client secret, for viewers to sign in through instead. Nobody needs one: the shared app works in any tenant, for any GitHub account |

The relay's size (1 vCPU, 2 GiB, 0 to 1 replica) and the Copilot SDK's version are pinned in `config/versions.json` (`askRelay`), not configured. **Checks:** `ASK.RELAY`, `ASK.RELAY.HEALTH`, `ASK.SIGNIN`, and `ASK.CSP`, in `configure-fabric-app.ps1` and so in `deploy.ps1`; each is a **Pass**, a **Warning**, or **Not selected**, never a **Fail** ([troubleshooting](troubleshooting.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)).
