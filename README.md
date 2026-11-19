# Fabric Database Hub hybrid SQL demo

A low-cost, repeatable customer demo of **Microsoft Fabric Database Hub (preview)** and its in-Hub **Database Agent (preview)**, across three SQL targets and one PostgreSQL target, deployed with one command into your own Azure subscription and Fabric capacity.

**Start here:**

- [Deploy it](#quick-start)
- [What's deployed, and by what](#whats-deployed-and-by-what)
- [What bills, stopped and running](#what-bills-stopped-and-running)
- [What you control](#what-you-control)
- [Day to day](#day-to-day)
- [Demo it yourself: the Copilot chat in the Insights app](#demo-it-yourself-the-copilot-chat-in-the-insights-app)
- [Upgrading an existing demo](#upgrading-an-existing-demo)
- [Delete everything](#delete-everything)

**The story:** fragmented visibility before; one hybrid estate in Database Hub after; then a live incident (locking, CPU, IO, a missing index, an inefficient query, or a read replica that falls behind) that the presenter investigates with the Database Agent. Every action the agent proposes needs human approval.

> **Preview disclosure:** Database Hub, the Database Agent, SQL VM performance monitoring, unified inventory, the Arc SQL monitoring setting, the telemetry endpoint, and Fabric Apps are previews and can change. This repo uses only documented interfaces and says plainly what's manual, unsupported, or not yet proven ([limitations](docs/limitations.md)).

## What's deployed, and by what

Everything goes to two places, which the scripts find by name and create when they're missing, so you never look up an ID: in Azure, the resource group `rg-dbhub-demo`, in West US 3 by default (`prefix`, `environment`, and `location` in your configuration); in Fabric, the workspace **Database Hub Demo** on your capacity. `./scripts/deploy.ps1` creates everything below and keeps it up to date, and `./scripts/destroy.ps1` deletes all of it that it can tell is this environment's ([delete everything](#delete-everything)).

| Part | Where | Created and updated by | Deleted by |
|---|---|---|---|
| The demo resource group `rg-<prefix>-<environment>` with the four targets: **T1** `sqlvm01`, SQL Server 2022 Standard on an Azure VM; **T2** `arcsql01`, SQL Server 2022 Standard in a nested Hyper-V guest on the VM `archost01`, Arc-enabled and presented as a simulated on-premises server; **T3** `azuresql01-<id>`, the `ContosoCare` database on Azure SQL Database, serverless; and **T4** `pgflex01-<id>`, Azure Database for PostgreSQL flexible server. With them: the network (no VM has a public IP), the private endpoint and DNS zones, the VMs' auto-shutdown, the workload runner that drives each target's activity, and the nightly safety stop's Automation account `aa-<prefix>-<environment>-safetystop` | Azure | `deploy.ps1`: the template, then its parallel tracks. A T2 host whose VM agent stays dead is deleted and created again by `deploy.ps1`, once per run | `destroy.ps1` |
| T2's Arc resources: the machine `arcsql01` and its SQL Server instance | Azure, in the demo group | T2's Arc onboarding, in `deploy.ps1` | `destroy.ps1`, first |
| T4's read replica `pgreplica01-<id>`: a same-region read replica at T4's size, which fills Database Hub's **Read replica lag** | Azure, in the demo group | Each session: Run all or `start-demo.ps1`. `deploy.ps1` creates it for its checks | `stop-demo.ps1`, the session's auto-stop, the end of `deploy.ps1`, or `destroy.ps1` |
| The session control `rg-<prefix>-control`: the Automation account `aa-<prefix>-control` with the runbooks `DbHub-Control`, `DbHub-Stop`, and `DbHub-Monitor`, their schedules, and the webhook; the Key Vault `kv-<prefix>-ctl-<suffix>` with the webhook's URL and the session's status and metrics; the identity `id-<prefix>-automation` | Azure | `deploy.ps1` (or `./scripts/setup-activity-control.ps1`); a session's runbook adds its schedules and status | `destroy.ps1`, when its runbooks serve this environment; or `./scripts/setup-activity-control.ps1 -Remove` |
| Custom roles: "DbHub Demo Safety Stop", "DbHub Demo Activity Operator", and "DbHub Demo Session Writer" (the last two with `control.roleNameSuffix` when it's set) | The subscription | `deploy.ps1` when you're an Owner; otherwise an Owner runs `./scripts/grant-safety-stop.ps1` once | `destroy.ps1`, once no role assignment holds the role |
| The T3 and T4 administrators' group `<prefix>-<environment>-sql-admins` | Microsoft Entra ID | `./scripts/init.ps1 -CreateAdminGroup`, or `deploy.ps1`'s first run, which does the same | `destroy.ps1`, when `init.ps1` created it. A group you supplied stays |
| The budget and the deployment record `<prefix>-<environment>-main` | Azure | `deploy.ps1` | `destroy.ps1` |
| The T2 golden snapshot group `rg-<prefix>-golden` (optional: it only speeds up a redeploy) | Azure | `./scripts/capture-t2-golden.ps1` | `destroy.ps1 -IncludeGolden` |
| The demo's Fabric workspace (`fabric.workspaceName`): the lakehouse `LH_DatabaseHub`, the notebooks `NB_DatabaseHub_Deployment` and `NB_DatabaseHub_LiveActivity`, the Real-Time Dashboard `RTD_DatabaseHub_LiveView`, the model `SM_DatabaseHub_History`, the report `RPT_DatabaseHub_History`, and the Insights app `APP_DatabaseHub_Insights` with its connector and its live-estate function | Fabric | `deploy.ps1`'s Fabric track. Each Run all session adds its history to the lakehouse | `destroy.ps1`, when everything in it is the demo's and no other environment uses it; `-KeepFabric` keeps it |
| Ask, the Insights app's GitHub Copilot chat: the Container Apps environment `cae-<prefix>-<environment>-ask` and the chat relay `ca-<prefix>-<environment>-ask`, which scales to zero and holds no credential ([ADR 0027](docs/adr/0027-ask-copilot-in-the-insights-app.md)) | Azure, in the demo group | `deploy.ps1`, with the Insights app (`configure-fabric-app.ps1`); off with `"ask": { "enabled": false }` | `destroy.ps1`, with the group |
| The control notebook `NB_DatabaseHub_Control`: where a policy makes new Key Vaults private, in its own workspace ("&lt;workspace&gt; Control") with a managed private endpoint to the control's Key Vault; otherwise in the folder "DBHub Control" of the demo's workspace | Fabric | `deploy.ps1` | `destroy.ps1`: the workspace when its notebook serves this environment and no other environment uses it, the folder with the demo's workspace; `-KeepFabric` keeps them |

**Database Hub itself** is a Fabric portal page, with nothing to deploy: it finds the targets through Azure Resource Graph and charts their telemetry and metrics. The [architecture](docs/architecture.md#at-a-glance) has a diagram and each part's details.

**Not the demo's:** the Fabric capacity, your Fabric and Power BI licenses, and Database Hub's tenant setting. You and your administrators manage them, and no script deletes them. By default no script resumes or pauses the capacity either; `fabric.manageCapacity` opts in to that for a capacity that's yours alone ([automated vs manual](docs/automation-support-matrix.md#automated-vs-manual)).

## What bills, stopped and running

- **Between sessions, with everything stopped:** both VMs' disks, T3's and T4's storage, T3's private endpoint in private mode, the private DNS zones, and the Defender plans where your tenant turns them on. The VMs and T4 bill no compute, the replica is deleted, and T3 pauses by itself. A golden snapshot, when you keep one, bills every month, after `destroy.ps1` too.
- **During a session:** the VMs' compute and their pay-as-you-go SQL Server licenses (T1 by the hour, T2 per core-hour through Azure Arc), T3's compute while it's active, T4 and its read replica, and Bastion, when you started one for interactive access. Ask's chat relay bills per second only while someone uses the Copilot chat in the Insights app, about $0.11 an active hour at the 2026-11-18 list prices, and nothing while idle.
- **Close to nothing:** the two Automation accounts (their jobs fit in the 500 job minutes a month that Azure Automation includes), the Key Vault's operations, the identities, the role definitions, and the budget.
- **Outside the estimate:** the Fabric capacity, which bills while it runs, and licenses.
- **The ceilings:** $15 a session (`sessionCeilingUsd`), a **Warning** above it, and $375 a month (`monthlyCeilingUsd`), a hard ceiling that preflight fails above. The deployment adds a budget with alerts at 50%, 80%, and 100% of the monthly one.
- **The figures:** `./scripts/estimate-cost.ps1` prices it from Azure's list prices at run time, with no sign-in; [cost management](docs/cost-management.md#at-a-glance) has dated examples.

## Quick start

**Before you start** (once; [prerequisites](docs/prerequisites.md) has every item and who provides it):

- **Contributor** on an Azure subscription. Recommended, once per environment: an **Owner** for the nightly safety stop's and the session control's roles; without one, the run still ends **DONE** and prints the one command an Owner runs.
- An **F or Trial Fabric capacity** you can assign, **running** while you deploy.
- Fabric tenant settings, which a Fabric administrator turns on: **Users can access the Database hub (preview)**, and **Create workspaces** unless you already have a workspace; for the Insights app, **Fabric Apps (preview)** and **Dataset Execute Queries REST API**.
- Quota for about **8 vCPUs** of VM sizes with nested virtualization in the region; preflight checks it.
- PowerShell 7.4, the Azure CLI with Bicep, Node.js 24, and Git. The repository's [dev container](.devcontainer/devcontainer.json) has them all, locally or in GitHub Codespaces. On Windows, `deploy.ps1` installs the .NET SDK for you.

**Deploy:**

```powershell
git clone https://github.com/MarcBushong/fabric-database-hub-demo.git   # or "Use this template", or a codespace
cd fabric-database-hub-demo
az login                 # you sign in; in a codespace or a container: az login --use-device-code
./scripts/deploy.ps1     # everything else, in one command
```

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/MarcBushong/fabric-database-hub-demo?quickstart=1)

On its first run, `deploy.ps1` writes `config/demo.config.json` from your sign-in, asking only when there's a real choice (your subscription and your capacity), and creates the Microsoft Entra group that administers T3 and T4. Then it checks everything (preflight), deploys T1 with T3, T2, T4, and the Fabric items in parallel, and waits for T2, which needs nobody: the T2 host downloads [Arc Jumpstart](https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md)'s prebuilt SQL Server 2022 Standard guest and makes it `arcsql01`. It keeps a Windows PC awake and opens a live status page, `out/deploy-status.html`; `./scripts/status.ps1 -Watch` shows the same in a terminal. A first deployment took **91 minutes**, measured on 2026-11-06 from a fresh clone in West US 3 with the default `lowest-cost` profile, with nobody needed during the run. Before each run, it updates a clean checkout of `main` from GitHub; `-NoSelfUpdate` runs the code you have.

**How it ends,** with one banner:

- **DONE:** Database Hub shows every target. The banner says where to look, which activity runs, and where Run all is, and lists under **Please confirm** what only you can check, such as a tenant setting it couldn't read; none of that keeps it from **DONE**. When you aren't an Owner, it also prints `./scripts/grant-safety-stop.ps1` for an Owner to run once.
- **NOT DONE:** why, the single next action, and the exact command: usually `./scripts/deploy.ps1` again, which continues where it stopped. If the window closes or the PC restarts, run it again; you never need a flag to continue.
- **The Insights app** deploys with your `az login`. When it can't be created, the run still ends **DONE**, and the status page shows the app's step as **Failed**, with the error and the fix. A browser sign-in, `./scripts/configure-fabric-app.ps1 -SignIn`, is needed only if Fabric refuses your Azure CLI's token. Its GitHub Copilot chat (Ask) deploys with it; when its relay can't be, the status page says so in a **Warning**, and the run still ends **DONE**.

**See it:** open **Database Hub** in the Fabric portal and look at Estate and Performance. The default activity, `business-day`, runs bounded incidents at fixed minutes every hour, so Performance's problem panels fill within the hour. For one right now: `./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25`. Then investigate it with the Database Agent, approving or cancelling each action it proposes.

**More:** [deployment](docs/deployment.md#deploy-it-step-by-step) has every step, option, and command, and [how long each takes](docs/deployment.md#how-long-each-step-takes). An AI assistant can run it for you, but `az login` stays yours ([running it with an AI assistant](docs/deployment.md#running-it-with-an-ai-assistant), [AGENTS.md](AGENTS.md)).

## Day to day

- **Run a session:** open `NB_DatabaseHub_Control` where **DONE** says (its own workspace, or the folder "DBHub Control" of the demo's) and select **Run all**. With nothing to edit, it starts the VMs, T4, and T4's read replica, runs the 90-minute showcase of bounded incidents on all four targets, prints a presenter's guide with links and Database Agent prompts, shows a live view, then stops everything and saves the session's history for the report and the Insights app ([the notebook's guide](fabric/control/README.md)). Resume the capacity first: it runs the notebook, and Run all never resumes it. Start about 30 minutes before your audience: the first data reaches Database Hub 10 to 35 minutes after Run all ([what fills each visual, and when](docs/database-hub-visuals.md)).
- **Or from your PC:** `./scripts/start-demo.ps1` (about 8 minutes; it creates T4's read replica within its warm-up, about 9), then `./scripts/stop-demo.ps1 -SaveHistory`, which saves the session's history.
- **Stop now:** `./scripts/stop-demo.ps1`: it turns the activity off, shuts T2's guest down, deallocates both VMs, deletes T4's read replica, and stops T4. Or the notebook's **Stop now** cell, with `STOP_NOW = True`. If you forget, the [nightly stop](#what-stops-or-pauses-on-its-own) stops the demo that evening.
- **See where it stands:** `./scripts/status.ps1`, read-only; `-Detail` adds more.
- **An incident right now:** `./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25`. During a session, `-Target T4 -Scenario incident:replica-lag -Duration 10` makes T4's read replica fall about 4 minutes behind, then catch up. `./scripts/reset-demo.ps1` goes back to a known state without a redeploy.
- **`deploy.ps1` ended NOT DONE:** run the command its banner prints, usually `./scripts/deploy.ps1` again; it continues where it stopped. The banner and the status page, `out/deploy-status.html`, say why.
- **A sign-in error** (an expired token, "AADSTS", "TokenCreatedWithOutdatedPolicies", or Microsoft Graph refusing): run `az login --tenant <tenantId>` yourself (`az login --use-device-code` in a codespace), then the same command again. The scripts never sign in for you, and never change your default subscription ([your sign-in and tokens](docs/security-model.md#your-sign-in-and-tokens)).

**Where to show it:** **Database Hub**, live and the product itself, which needs no capacity; the Real-Time Dashboard `RTD_DatabaseHub_LiveView`, live, as code; the Power BI report `RPT_DatabaseHub_History`, the saved history; and the Insights app `APP_DatabaseHub_Insights`, the same history with ready-made Database Agent prompts and its own GitHub Copilot chat ([demo it yourself](#demo-it-yourself-the-copilot-chat-in-the-insights-app)), opened from its workspace item. [Presentation surfaces](docs/presentation.md) says what each viewer needs, and the [demo walkthrough](docs/demo-walkthrough.md) has 15- and 30-minute scripts.

## Demo it yourself: the Copilot chat in the Insights app

Ask questions about the estate in the Insights app itself, on your own GitHub Copilot: Copilot runs read-only queries on the demo's history and reads the live estate from Database Hub, answers with the app's own charts, and shows the query or the source behind every answer. Nothing to install, and nothing to register ([ADR 0027](docs/adr/0027-ask-copilot-in-the-insights-app.md)).

1. **Deploy** with `./scripts/deploy.ps1`; it sets up the chat with the app. Then **Run all** a session (or `./scripts/start-demo.ps1`, which also wakes the chat), so there's an incident to ask about.
2. **Open the Insights app** from its workspace item, and select **Ask Copilot**: the chat docks on the right; drag its edge, or make it full screen.
3. **Sign in with GitHub, once per browser:** select **Sign in with GitHub**. It copies a code and opens github.com/login/device in a new tab: paste the code, check that the app is **Database Hub Insights Ask**, and select **Authorize**. Use the GitHub account that has your Copilot license; it can differ from your Fabric account. The chat continues by itself and keeps you signed in on this browser for up to six months. GitHub may show the request coming from the chat's relay in Azure, not from where you are.
4. **Ask:** pick a starter, such as **Which target worked hardest this week?**, or type a question. Select **Ask why** on a chart, and **Show the source** under an answer to see its DAX or Database Hub routes. **New chat** starts over for the next audience; **Export** saves the conversation with every query.

**When it says it can't:** the chat says what's wrong and what to do. Only two things need someone else, and only in some tenants: an organization that restricts OAuth apps, whose owner approves **Database Hub Insights Ask** once for the account that gives you Copilot; and the Fabric tenant setting "Enforce a strict content security policy for static-hosted Fabric Apps (preview)", which must stay off, as it is by default (`deploy.ps1` reports a **Warning** when it's on). **What goes to GitHub Copilot:** your questions, a guide to the history model (names, not data), and the results of the read-only queries it runs, never a password or an Azure or Fabric token ([security model](docs/security-model.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)). **Sign out of GitHub** is in the chat's account menu, with **Switch GitHub account**.

## What you control

- **The configuration**, `config/demo.config.json`. `init.ps1` or `deploy.ps1`'s first run writes it, and `config/environment.schema.json` describes every setting. A change takes effect at the next `./scripts/deploy.ps1`. The ones you're most likely to change:
  - where: `subscriptionId`, `tenantId`, `location`, `prefix`, and `environment`;
  - size and cost: `profile` (`lowest-cost` by default), `t4SkuName`, `monthlyCeilingUsd`, and `sessionCeilingUsd`;
  - when the demo stops: `autoShutdownTime` and `autoShutdownTimeZone`, which the VMs' auto-shutdown and the nightly safety stop use, and `t3AutoPauseMinutes`;
  - the activity: `activityProfile` (`business-day` by default; `baseline` for a quiet demo);
  - Fabric: `fabric.workspaceName`, `fabric.capacityName`, and `fabric.lakehouseName`; and the control's `control.fabricWorkspaceName` and `control.roleNameSuffix`. Each environment needs its own `fabric.workspaceName`, and its own `control.fabricWorkspaceName` when its configuration sets one (by default it follows the workspace's name). Two environments in one workspace overwrite each other's notebooks: `deploy.ps1` says so in a **Warning** (`DEPLOY.FABRIC.SHARED`), and `destroy.ps1` keeps that workspace.
  - the Copilot chat in the Insights app: `ask.enabled` (on by default), and, rarely, `ask.githubClientId` for your own GitHub OAuth App or `ask.image` for your own relay image, pinned by digest.
- **`deploy.ps1`'s switches**, rarely needed: `-FromStage <stage>` runs again from a stage, `-StopAfter <stage>` stops after one, `-SkipFabric` leaves Fabric alone, `-NoSelfUpdate` runs the code you have, and `-WhatIf` changes nothing.
- **Run all's parameters,** in the control notebook's first cell; none needs editing: `DURATION_MINUTES` (90 by default, 30 to 120), `MODE` (`"check"` shows the plan and sends nothing), and `STOP_NOW = True` or `RESET_NOW = True` for its **Stop now** and **Reset** cells ([the switches](fabric/control/README.md#the-switches)).
- **A session's switches:** `start-demo.ps1 -ActivityProfile <name>` and `-SkipT4Replica`; `stop-demo.ps1 -SaveHistory`, `-ParkT2`, and `-RemoveT3`.
- **The nightly stop:** at `autoShutdownTime` every evening. To skip one night, turn its schedules off ([what stops or pauses on its own](#what-stops-or-pauses-on-its-own)); the next `./scripts/deploy.ps1` turns them on again.
- **What isn't yours to set here:** the Fabric capacity, which you or its administrator resume and pause, licenses, and Database Hub's tenant setting.

## What stops or pauses on its own

Nothing here needs you, and nothing here starts anything: only Azure starts a stopped T4 again, 7 days after its stop, and the nightly safety stop stops it again within a day. Times are the defaults: `autoShutdownTime` 19:00, in `autoShutdownTimeZone`.

| What | When | What it does |
|---|---|---|
| The VMs' auto-shutdown | Daily at `autoShutdownTime` | Deallocates `sqlvm01` and `archost01`; T2's guest stops with its host |
| The nightly safety stop | The same time, and its T3 check 30 minutes later | Deallocates a VM that still runs, stops T4, after Azure's 7-day restart too, and stops a read replica that a session left behind. It never starts or deletes anything. It waits for a `deploy.ps1` that's still running, then stops the demo 60 minutes after the run ends, and **DONE** says when |
| T3's auto-pause | `t3AutoPauseMinutes` (15) after its last session | Azure pauses the serverless database, which then bills only its storage |
| A Run all session's auto-stop | 10 minutes after the session's end | Deletes T4's read replica, stops T4, and deallocates the VMs |
| The control's daily T4 safety stop | 15 minutes after `autoShutdownTime` | Stops T4 when it runs, then a left-over read replica |

- **To skip one night:** turn off the schedules `dbhub-safety-stop` and `dbhub-safety-t3check` in `aa-<prefix>-<environment>-safetystop` (and `dbhub-safety-deferred` when a run left one), and the VMs' auto-shutdown in the Azure portal. The next `./scripts/deploy.ps1` turns the safety stop on again.
- **Where to see it:** `./scripts/status.ps1` (`STATUS.SAFETYSTOP` and `STATUS.NIGHTLYSTOP`). [Cost management](docs/cost-management.md#what-stops-or-pauses-on-its-own) lists every schedule, the optional GitHub schedules included.
- The Fabric capacity isn't on this list: you or its administrator pause it.

## Upgrading an existing demo

- **Nothing changes until you run `./scripts/deploy.ps1`.** The deployed environment never reads GitHub, and a newer copy of the scripts works with it: `status.ps1`, `start-demo.ps1`, and `stop-demo.ps1` say what isn't deployed yet, with `./scripts/deploy.ps1` as the fix, never as a **Fail**.
- **One command:** `./scripts/deploy.ps1`. It first updates a clean checkout of `main` from GitHub, then runs that code; `-NoSelfUpdate` runs the code you have. Your configuration file needs no edit.
- **Without your configuration file** (a fresh clone, another PC, a lost file; since 2026-11-18, [#60](https://github.com/MarcBushong/fabric-database-hub-demo/issues/60)): the same command's first run reads what this subscription already has before it writes one. When the environment is yours (its owner tag or budget address is your sign-in, or you own the group that administers its T3 and T4), the configuration is written from what's deployed: its administrators' group, network mode, region, sizes, schedule, ceilings, profile, Fabric workspaces, and the session control's own custom roles, so the update changes nothing you didn't ask for. It republishes the notebooks of the demo's own workspace: the one it records, one that holds only what the demo creates, or one the demo's notebooks are already in. Another workspace keeps its copies, and `INIT.EXISTING` says which, and why. Settings Azure doesn't record, such as `sessionCeilingUsd` and `activityProfile`, keep their defaults, and `INIT.EXISTING` lists them. When it isn't yours, or that can't be told, the run never updates it: it deploys a new environment with the next free prefix (`dbhub2`, ...), its own group, and its own workspace. The console and the status page say which. For an environment with another prefix, run `./scripts/init.ps1 -Prefix <prefix>` first ([deployment](docs/deployment.md#first-run-initps1)).
- **What that run changes,** with nothing to do by hand: it adds T4's read replica for each session and the session control behind Run all (a control you set up before is adopted as it is); republishes the runbooks, the notebooks, the history model, the Insights app, and the workload runner; keeps the lakehouse's history; and brings back a T2 host whose VM agent no longer starts, rebuilding only that VM, once, when nothing else works (about 70 minutes more). T4 keeps its size and its data.
- **When you aren't an Owner:** **DONE** prints `./scripts/grant-safety-stop.ps1` for an Owner to run once, for the nightly safety stop's and the session control's roles together.
- **`destroy.ps1` deletes more than it used to** (2026-11-17): also the session control, the Fabric workspaces with the history in the lakehouse, and the administrators' group that `init.ps1` created, each only when it's this environment's ([delete everything](#delete-everything)).
- **Ask, the Copilot chat in the Insights app** (since 2026-11-18): the same run deploys its chat relay with the app, registering the `Microsoft.App` resource provider when the subscription hasn't; nothing to set up, and each viewer signs in to GitHub once per browser ([demo it yourself](#demo-it-yourself-the-copilot-chat-in-the-insights-app)). When the relay can't be deployed, the status page shows a **Warning** with the fix, and the run still ends **DONE**.
- **Cost:** nothing new bills between sessions. The replica adds about $1.80 to a 5-hour session and under $0.50 to each `deploy.ps1` run, at the 2026-11-13 list prices. Ask's relay bills only while someone asks, at most about $0.11 an hour at the 2026-11-19 list prices, and scales to zero about 10 minutes after the last question.

[Deployment](docs/deployment.md#upgrading-from-before-the-read-replica-and-run-all-2026-11-13-to-2026-11-16) has each change in detail.

## Delete everything

`./scripts/destroy.ps1` deletes everything `deploy.ps1` created for the environment in your configuration. First it lists what it deletes and what it keeps, and asks you to confirm; `-Force` doesn't ask. Each part reports its own `DESTROY.*` result, and a part that fails doesn't stop the others.

**What it deletes, in this order,** each part only when it can tell it's this environment's:

1. **Fabric:** the control's workspace with its managed private endpoint, when its control notebook serves this environment, and the demo's workspace, when every item in it is one the demo creates, a control notebook in its folder "DBHub Control" included. A workspace that holds anything else stays whole, and its result names what isn't the demo's. Neither goes while another environment uses it, or might (below). `-KeepFabric` keeps both workspaces, with the history in the lakehouse. A Fabric administrator can restore a deleted workspace during your tenant's retention period, 7 days by default ([retention and recovery](https://learn.microsoft.com/fabric/admin/portal-workspaces#retention-and-recovery)).
2. **The session control** in `rg-<prefix>-control`, when its runbooks serve this environment's resource group: its role assignments, its custom roles once no other assignment holds them, the identity, the Key Vault (purged), and the Automation account with its runbooks, schedules, and webhook; then the group, once it's empty. Deleting role assignments needs Owner or User Access Administrator: for anyone else, `DESTROY.CONTROL.ROLES` is a **Warning** that says so, and the rest still goes.
3. **The T3 and T4 administrators' group,** when `init.ps1` created it for this environment.
4. **T2's Arc resources:** the SQL Server instances, then the machine.
5. **T4's read replica,** when a session left one (Azure deletes replicas before their primary).
6. **The resource group** and everything in it, then the deployment record and the group's budget, which outlive the group.
7. **The custom role "DbHub Demo Safety Stop",** once no role assignment holds it.

Then it checks that nothing of the environment is left (`DESTROY.RESIDUAL`, [cleanup](docs/cleanup.md)).

**What it keeps, and how to remove it:**

- **The Fabric capacity and your licenses:** you manage them, and no script deletes them.
- **`rg-<prefix>-golden`, when you captured a golden snapshot:** the next `deploy.ps1` restores T2 from it. It bills every month until `./scripts/destroy.ps1 -IncludeGolden` deletes it.
- **What another environment uses:** a custom role that another environment's role assignments hold, a session control whose runbooks serve another resource group, or a workspace with items that aren't the demo's. Each result names it and says why it stayed.
- **A Fabric workspace another environment might use:** each `deploy.ps1` records the workspaces its environment uses on its resource group (the tags `DbHubFabricWorkspaceId` and `DbHubControlWorkspaceId`, since 2026-11-17), and `destroy.ps1` reads the other demo environments in every subscription you can read, with one Azure Resource Graph query. It keeps a workspace that another environment records, and every workspace while an environment that hasn't had that `deploy.ps1` run exists, because it might use them, and also when Resource Graph can't be read. `DESTROY.FABRIC.WORKSPACE` or `DESTROY.FABRIC.CONTROL` is then a **Warning** that names the other environment, with the fix: run `destroy.ps1` again after that environment's next `deploy.ps1`, or its destroy; or delete the workspace in Fabric once nothing uses it. With one environment, the usual case, everything still goes in one command.
- **A security group you supplied** rather than `init.ps1 -CreateAdminGroup`: delete it in the Microsoft Entra admin center when nothing else uses it.
- **Your tenant's own role assignments:** your tenant's automation may give the demo's identities role assignments outside the demo. They stay behind, orphaned; they don't bill, the residual check reports them as a **Warning** that names the scope, and removing one needs Owner or User Access Administrator.

**How long:** about 20 minutes. Measured on 2026-11-17 in two test environments: 16 minutes with the resource group, 10.5 of them for the group's delete; the Fabric, control, and group parts took 3 to 5 minutes more in a second run. If it's interrupted, run it again: it finishes what's left, also once the resource group is gone.

**Only the session control:** `./scripts/setup-activity-control.ps1 -Remove` deletes it alone (`-WhatIf` shows what), and the next `deploy.ps1` sets it up again.

## Troubleshooting and help

- **A result that isn't Pass:** every check reports one of six statuses: **Pass**, **Fail**, **Warning**, **Manual action required**, **Not supported**, or **Not selected**, and a successful deployment alone is never **Pass**. Every **Fail**, **Warning**, and **Manual action required** comes with its remediation, and [troubleshooting](docs/troubleshooting.md) explains the common ones; the [FAQ](docs/faq.md) and [limitations](docs/limitations.md) cover what's out of scope. `./scripts/status.ps1` (read-only) shows where an environment stands.
- **A deployment that doesn't finish:** `deploy.ps1` ends **NOT DONE** with the next command; run it, and if the same thing happens again, run `./scripts/collect-diagnostics.ps1`. It writes a zip of the run's results, progress, and logs, redacted, with your IDs and account replaced, and refuses to write one that its secret scan doesn't pass. Open an issue with the **Deployment problem** template, which asks for the command, how the run ended, the results that aren't **Pass**, and the zip (read it before you attach it).
- **A bug in the code or the docs:** open an issue with the **Bug report** template. For an idea, use **Feature request**.
- **Replace your IDs first:** this repository is public. Before you paste output into an issue, replace subscription, tenant, object, client, and workspace IDs, the T3 and T4 server names' random suffix, and your account with placeholders such as `<subscriptionId>`, and never paste a token, a password, or a webhook URL.
- **A security problem:** report it privately, as [SECURITY.md](SECURITY.md) describes, never in an issue.
- **Questions about the products** (Database Hub, the Database Agent, Fabric, Azure Arc): see [Microsoft Learn](https://learn.microsoft.com/fabric/database/hub/overview) and the [official sources](docs/references.md); this repository is a demo, not a product support channel.

## Documentation

**Where the details are:**

- **Every step, option, and command,** with how long each takes, T2's install modes, GitHub Codespaces, GitHub Actions, and an AI assistant's part: [deployment](docs/deployment.md#deploy-it-step-by-step), and the [quick reference](docs/deployment.md#quick-reference-every-command).
- **What's automated, what's manual, and why:** [automated vs manual](docs/automation-support-matrix.md#automated-vs-manual) and the [automation support matrix](docs/automation-support-matrix.md).
- **Every prerequisite and how it's checked:** [prerequisites](docs/prerequisites.md#each-prerequisite-and-how-its-checked) and [permissions](docs/permissions.md).
- **The parts at a glance, with a diagram:** [architecture](docs/architecture.md#at-a-glance) and the [decisions (ADRs)](docs/adr/README.md).
- **What fills each Database Hub visual, when, and the baseline run:** [Database Hub's visuals](docs/database-hub-visuals.md).
- **Presenting:** [presentation surfaces](docs/presentation.md), with screenshots, and the [demo walkthrough](docs/demo-walkthrough.md).
- **Run all:** [the control notebook's guide](fabric/control/README.md) and its [runbooks](automation/README.md).
- **Cost, and everything that stops or pauses on its own:** [cost management](docs/cost-management.md).
- **Your sign-in and tokens:** [security model](docs/security-model.md#your-sign-in-and-tokens) and the [security policy](SECURITY.md).
- **Deleting:** [cleanup](docs/cleanup.md).
- **Problems:** [troubleshooting](docs/troubleshooting.md), the [FAQ](docs/faq.md), and [limitations](docs/limitations.md).
- **Sources and history:** [official sources](docs/references.md), the [implementation report](docs/implementation-report.md), and the [changelog](CHANGELOG.md).

Component guides: [Fabric notebooks](fabric/README.md), [the on-demand activity control notebook](fabric/control/README.md) and its [runbooks](automation/README.md), [Real-Time Dashboard](fabric/realtime/README.md), [Power BI history report](fabric/powerbi/README.md), [Fabric App](fabric/app/README.md), [Database Agent prompt pack](fabric/agent/README.md), [scenarios](scenarios/README.md), [workload generator](workload-generator/README.md), and [VM bootstrap](vm/bootstrap/README.md). To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
