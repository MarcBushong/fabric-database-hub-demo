# Deployment

How to deploy the demo and run it day to day. The building blocks below ran live in West US 3 on 2026-10-20 and 2026-10-21. The scripts that chain them (`deploy.ps1`, `start-demo.ps1`, `stop-demo.ps1`, and `reset-demo.ps1`) ran end to end in Phase 20's live test on 2026-10-22: the measured times are [below](#parallel-tracks-phase-20), and the [implementation report](implementation-report.md#phase-20-fast-redeploy-parallel-tracks-and-a-t2-golden-snapshot) has the full results. When something isn't **Pass**, see [troubleshooting](troubleshooting.md).

## Before you start

1. Meet the prerequisites P1–P11 in [prerequisites.md](prerequisites.md). Contributor on the subscription is enough for the default path. Every tool is in the repository's [dev container](../.devcontainer/devcontainer.json), locally or in GitHub Codespaces.
2. Sign in yourself, once, as the account that runs the demo: `az login`, or `az login --use-device-code` in a codespace or a container without a browser ([sign in interactively](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)). The scripts never sign in, sign out, or change the Azure CLI context, and **you don't need to change your default subscription**: every Azure call carries the configured subscription, and the subscription guard checks the account and tenant that subscription's sign-in uses before anything is written ([prerequisites](prerequisites.md#target-subscription-configuration-the-subscription-guard)). On a machine whose Azure CLI profile is shared with other work, you can sign in under a separate `AZURE_CONFIG_DIR` instead ([optional isolation](prerequisites.md#optional-a-separate-azure-cli-profile)); in Cloud Shell, skip this step.
3. Write `config/demo.config.json` (Git ignores it) with `./scripts/init.ps1` ([below](#first-run-initps1)), or copy `config/demo.config.example.json` and fill it in by hand. `Get-DemoConfig` checks it against `config/environment.schema.json`. Since Phase 28 this step is optional: `./scripts/deploy.ps1` writes the file itself when it's missing, with the same prompts ([one command, one guided stop](#one-command-one-guided-stop-phase-28)).

```powershell
az login                               # once; leave the default subscription as it is
./scripts/init.ps1 -CreateAdminGroup   # optional: config/demo.config.json from your sign-in (deploy.ps1 runs it when the file is missing)
./scripts/preflight.ps1                # optional, read-only: guard, P1-P6, region, sizes, quota, policy, and the cost estimate
./scripts/estimate-cost.ps1            # optional: the live estimate against both ceilings
./scripts/deploy.ps1                   # everything else, with one guided stop in PaygWizard mode
```

If a script stops at `PREFLIGHT.GUARD.CONTEXT`, its message names the failed check:

| Check | What it means | Fix |
|---|---|---|
| `account` | The Azure CLI has no sign-in for the configured subscription, has it in another tenant, or reaches it as another account than `azureAccount` | `az login --tenant <tenantId>` as the right account, or correct `azureAccount` |
| `canary.arm`, `canary.armRest` | Azure Resource Manager refused the configured subscription for that account | Check the account's role on the subscription (P1) |
| `canary.armToken`, `canary.fabricToken`, `canary.kustoToken`, `canary.graphToken` | No token without interaction (an expired sign-in or a new MFA prompt), or a token for another tenant or identity | `az login --tenant <tenantId>` again |
| `canary.graphOrganization` | Microsoft Graph answered for another tenant | The same; the sign-in is mixed up with another tenant's |

A **Warning** on the guard means `azureAccount` isn't set: the evidence names the account the guard found, so you can set it.

### First run: `init.ps1`

`init.ps1` (Phase 26b, [ADR 0023](adr/0023-first-run-automation.md)) writes your configuration from your sign-in, so a first run needs no IDs looked up by hand. It took 44 seconds in a read-only run on 2026-10-27.

1. **Your subscriptions, before the guard:** `az account list --output json` reads the subscriptions the Azure CLI's own sign-in cached in its profile ([az account list](https://learn.microsoft.com/cli/azure/account#az-account-list)). It's read-only and local, and it's the one Azure CLI call the scripts make before the subscription guard, because the guard needs a subscription to check. With more than one, `init.ps1` asks (or takes `-SubscriptionId`); it never runs `az account set`. Not signed in: **Manual action required** with the `az login` command.
2. **The guard** runs for the chosen subscription, its tenant, and its account, and everything after it goes through it.
3. **You:** Microsoft Graph's [`/me`](https://learn.microsoft.com/graph/api/user-get), with the guard's verified token, gives the budget alerts' address (`ownerEmail`) and the owner tag. `az ad signed-in-user show` isn't used: it answers for the Azure CLI's default account, which can be in another tenant.
4. **P1** (`INIT.P1.CONTRIBUTOR`): your permissions on the subscription, as preflight reads them; without Contributor, **Manual action required** with the Owner's exact `az role assignment create` command.
5. **Fabric** (`INIT.FABRIC.CAPACITY`, `INIT.FABRIC.WORKSPACE`): the F, Trial, and P capacities you can assign ([List Capacities](https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities); Premium Per User isn't offered), and it asks when there's more than one; then whether the workspace `fabric.workspaceName` ("Database Hub Demo" by default) exists ([List Workspaces](https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces)). A workspace that doesn't exist yet gets `fabric.importNotebooks` true, and `deploy.ps1` creates it, its lakehouse, and the notebooks. Nothing is created in Fabric here. A paused capacity is a **Warning**: the Fabric track needs it running.
6. **P6** (`INIT.P6.GROUP`): the security group `-AdminGroupObjectId`, or the one named `-AdminGroupName` (by default `<prefix>-<environment>-sql-admins`), and whether you own it. With `-CreateAdminGroup`, a missing group is created with you as its owner, through Microsoft Graph's [Create group](https://learn.microsoft.com/graph/api/group-post-groups) with `owners@odata.bind`, then [Add owners](https://learn.microsoft.com/graph/api/group-post-owners) if the owners don't list you: an administrator who creates a security group isn't made its owner automatically. These are the calls behind `az ad group create` and `az ad group owner add`. Where the tenant lets only administrators create groups ([self-service group management](https://learn.microsoft.com/entra/identity/users/groups-self-service-management)), it's **Manual action required** with the steps for an administrator, and the configuration gets the all-zero placeholder until you run `init.ps1 -Force -AdminGroupObjectId <id>`.
7. **T2's mode:** `PaygWizard` (the default: Hub Performance on T2, after a one-time setup wizard of about an hour per guest build) or `Developer` (no wizard; T2 in Hub's Estate only). It asks unless `-T2SqlInstallMode` or `-NonInteractive`.
8. **The file** (`INIT.CONFIG`): the example configuration with these values, validated against the schema. A path Git would commit is refused (**Fail**). An existing file is replaced only with `-Force`, after a copy to `out/config-backup` (Git-ignored). `fabric.manageCapacity` stays false unless `-ManageCapacity`. The VMs' auto-shutdown time zone is this machine's (a codespace is usually in UTC; pass `-TimeZone 'Eastern Standard Time'` or your own).
9. **Next steps:** the exact commands, with `-ConfigPath` when you wrote another file.

`-WhatIf` reads everything and writes nothing: no file and no group. `-NonInteractive` never asks; an ambiguous choice is **Manual action required** with the parameter to pass.

**From `deploy.ps1` (Phase 28):** when the configuration file doesn't exist, `deploy.ps1` runs these same steps first (`Initialize-DemoFirstRun`, with `-CreateAdminGroup`, and with `-NonInteractive` when the session can't take keyboard input), then deploys with the file it wrote. When a step needs a person (no sign-in, a group that only an administrator may create, or a choice it can't ask about), it stops before anything is created and ends **NOT DONE** with that step's fix and the command to run next.

## One command: `deploy.ps1`

```powershell
./scripts/deploy.ps1
```

`deploy.ps1` runs Preflight, then Infrastructure while the tracks start, each in its own process (T1 with T3, T2, T4, and Fabric) with its own guard, then the validation ([parallel tracks](#parallel-tracks-phase-20), [ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)). The tracks do the same work as the stages below, which `-Sequential` runs one after another (`Invoke-DemoDeployment`). Each stage is idempotent, so a rerun converges. Since Phase 28 it's the whole deployment after `az login`, with one guided stop in `PaygWizard` mode and one ending, **DONE** or **NOT DONE** ([below](#one-command-one-guided-stop-phase-28)).

| Stage | What it does | A Fail here |
|---|---|---|
| Preflight | The subscription guard, P1–P6, region, sizes, quota, policy, and the cost estimate against both ceilings. It resolves the network mode, the T3 free offer, and the P6 group's name. | Stops before anything is deployed |
| Infrastructure | Deploys `azuredeploy.json` at subscription scope. If Azure rejects the T3 free offer, it deploys again with regular serverless and reports a **Warning** (`T3.FREEOFFER`). With the Key Vault opt-in, it then deploys the vault and your access to it ([below](#opt-in-the-password-in-key-vault-instead-of-the-clipboard)). With the on-demand activity control, it then grants A1 again ([below](#the-on-demand-activity-control-a1-after-a-redeploy)). | Stops (a vault **Fail** doesn't, nor does A1) |
| Artifacts | Builds the bootstrap bundle and the workload runner, then sends both to each VM in Run Command chunks. A VM that already has exactly these chunks is skipped. | Stops |
| Bootstraps | Deploys the template again with both SHA-256 hashes and chunk counts, which runs the loaders; waits for them, then for T1 to be Ready. | Stops |
| T3 | Adds T1 to the T3 administrators group (P6), runs the T3 setup from T1, enables the runner on T3, and checks T3, in the order that worked live. | Stops |
| Activity | Sets the configured `activityProfile` on T1 and T3 until the next auto-shutdown. | Never: a Warning |
| Monitoring | Turns on T1's performance monitoring, as `configure-monitoring.ps1 -Target T1` does. A template deployment keeps the SQL IaaS extension `Updating` for about 10 minutes; that's a wait, not a failure. | Stops |
| T2 | Arc onboarding and configuration (`configure-arc.ps1`), then T2's activity profile. | Stops |
| Fabric | The Database Hub checklist and, on request, the notebook import (`configure-fabric.ps1`). | Stops |
| Validation | Telemetry for each ready target, the runner's status, and a summary. | Reported |

- **Manual steps are never hidden.** **Manual action required** doesn't stop the run: the stage stays open, the later stages still run, and `DEPLOY.SUMMARY` lists every manual item with its exact steps. Fix it, then run `./scripts/deploy.ps1` again, which continues by itself since Phase 28 (`-Resume` does the same).
- **State lives in the resource group's tags** (`DbHub*`: the last stage that finished, the bundle and runner hashes, the VMs that have them, the network mode, the free-offer decision, the P6 group name, T4's size when the Burstable fallback chose it, the guided stop's time limit, and when the T2 host's loader started a bootstrap generation that nobody has seen finish), so a rerun or `-Resume` works from any machine and from GitHub Actions. The recorded stage never moves past an open stage.
- **Results** go to the console, to `out/deploy.jsonl` (one [ADR 0012](adr/0012-validation-model.md) result per line), and to the job summary in GitHub Actions, and the console's transcript goes to `out/logs/deploy-<time>.log` (not in GitHub Actions). Deployment success alone is never **Pass**. Exit codes (Phase 28): 0 when the run ends **DONE**, 1 when it ends **NOT DONE** with a **Fail**, and 2 when it ends **NOT DONE** otherwise; a `-WhatIf` run returns 0 unless a check failed. GitHub Actions keeps the earlier codes: 0 when nothing failed, 1 for any **Fail**, 2 for **Manual action required** with `-TreatManualAsError`.

| Option | Use |
|---|---|
| `-Resume` | Continue after the last stage that finished. Since Phase 28 a run without `-Resume` or `-FromStage` does this by itself when the last deployment didn't finish (not in GitHub Actions). |
| `-FromStage <stage>` / `-StopAfter <stage>` | Run a range of stages. `-StopAfter Infrastructure` gives what the Deploy to Azure button gives. |
| `-WhatIf` | Run the read-only preflight (without registering providers) and the template's what-if, then stop. Nothing is recorded. |
| `-SkipRunner` | Deploy without the workload runner (no .NET SDK needed); the activity profiles are **Not selected**. |
| `-SkipFabric`, `-ImportNotebooks` | Skip the Fabric stage, or also update both notebooks when they're already in the workspace (also `fabric.importNotebooks`). Without it, the stage imports only the notebooks that are missing, so a new workspace or lakehouse gets them without asking ([configuration](configuration.md#fabric)). |
| `-T1WaitMinutes`, `-T2WaitMinutes`, `-MonitoringWaitMinutes`, `-TelemetryWaitMinutes` | How long each wait lasts (45, 180, 20, and 15 by default). The T2 guest build takes about 60–90 minutes, and in `PaygWizard` mode the guided stop then waits at least 45 minutes for a person once it asks, so `-T2WaitMinutes` covers both (Phase 28; it was 120). |
| `-Sequential` | Run the stages one after another, as before Phase 20, instead of the parallel tracks. It has no guided stop. It's judged by the same DONE requirements: after its validation, with no stage open, it checks what DONE needs read-only, and it's **DONE** once the recorded stage is `Validation` and they pass; otherwise **NOT DONE** with `./scripts/deploy.ps1`, which continues after the last stage that finished. Its Fabric stage imports the Real-Time Dashboard and the history model and report, as the parallel Fabric track does; the optional Insights app is `./scripts/configure-fabric-app.ps1`'s. |
| `-NoWaitForT2` | Don't wait for T2's guest build (Phase 28): T1, T3, T4, and Fabric finish now, T2 keeps building in the background (`DEPLOY.T2.BACKGROUND`, **Manual action required**), and a later `./scripts/deploy.ps1` finishes it, with the guided stop in `PaygWizard` mode. |
| `-WaitForT2` | Wait for T2 in GitHub Actions or another CI system too. Elsewhere it's the default since Phase 28, so the switch is accepted but redundant. |
| `-NoStatusPage`, `-NoBrowser` | Write no progress model and no status page (the guided stop's prompt, reminders, and `HUMAN ACTION REQUIRED` line still come in the console, from the T2 track's process); or write them but open nothing in a browser (the page's path and the portal link are printed). |
| `-PolicyCacheHours` | Reuse preflight's last complete policy inventory while the policy assignments that apply are unchanged and it's at most this old (168 by default; the reused results say so). `0` reads every policy definition again (7–13 minutes measured). |

**The machine that runs `deploy.ps1` must stay awake.** Its tracks poll Azure from your machine; if it sleeps (Modern Standby included), every process freezes until it wakes, and the run takes that much longer (live, 2026-10-23: 35 minutes). Since Phase 28, `deploy.ps1` keeps a Windows PC and its display awake until it ends, and releases that in a `finally` ([SetThreadExecutionState](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate), with `ES_SYSTEM_REQUIRED`, `ES_DISPLAY_REQUIRED`, and `ES_CONTINUOUS`; Phase 25a found the display flag necessary). It can't stop a lid close or a shutdown, so plug a laptop in and leave it open. On macOS and Linux it changes nothing: keep the machine awake with its own settings.

### One command, one guided stop (Phase 28)

Two colleagues' first runs took more than 2 hours and never finished: preflight's first policy inventory and stuck Run Command deletes held the bootstraps back, `deploy.ps1` returned with T2 still building and a second command to remember, and a PC that went to sleep froze a run. Since Phase 28, `./scripts/deploy.ps1` is the one command after `az login`, in every install mode ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md#amendments-2026-10-29-phase-28-one-command-one-guided-stop)):

1. **No configuration yet:** it writes one first, as `init.ps1` does ([first run](#first-run-initps1)).
2. **At the start** it prints what to expect for this run, keeps the PC awake ([above](#one-command-deployps1)), writes the live status page and opens it ([below](#the-live-status-page-and-statusps1--watch)), and says when a person is needed. A session that can't take keyboard input (redirected input, CI, an automation shell, or an assistant) gets a notice before anything is spent: the guided stop needs a person at a browser for about 10 minutes, with `-NoWaitForT2`, `ProductKey`, or `Developer` as the alternatives and what each gives. The run then goes on. In GitHub Codespaces it warns that a codespace stops after 30 minutes without activity by default (terminal output counts as activity, and `deploy.ps1` prints progress at least every 5 minutes), and how to raise that: **Settings** > **Codespaces** > **Default idle timeout**, up to 240 minutes, for codespaces you create afterward, or `gh codespace create --idle-timeout 240m` ([GitHub Docs: idle timeout](https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces)). An organization's policy can set a lower maximum.
3. **It waits for T2 without a golden snapshot**, in every install mode, up to `-T2WaitMinutes` (180), printing the host's build phase and the elapsed time every few minutes, with an estimate of when the guided stop comes. On a time-out it ends **NOT DONE** with the exact command; `./scripts/deploy.ps1` waits again where it stopped. A golden restore doesn't build or stop, so it stays as fast as before.
4. **The guided stop (`PaygWizard`)** prepares everything a person needs, prompts once, and continues by itself afterward ([below](#the-guided-stop-paygwizard)).
5. **Run it again with no parameters**, and it continues an unfinished deployment from the resource group's state tags, as `-Resume` does. The start banner and every **NOT DONE** banner say so: "If this window closes or the PC restarts, run ./scripts/deploy.ps1 again; it continues where it stopped." It starts VMs that were stopped, for example by the nightly auto-shutdown or `./scripts/stop-demo.ps1` (Phase 28 live finding: a rerun after the auto-shutdown found the VMs deallocated, and its first Run Command failed). On an existing environment, `deploy.ps1` reads each VM's power state; a deallocated or stopped `sqlvm01` or `archost01` gets `az vm start --no-wait` ([az vm start](https://learn.microsoft.com/cli/azure/vm#az-vm-start)) before preflight, so it boots while preflight runs, and runs before the template or any track needs it (`DEPLOY.VMSTART`; one that doesn't start ends **NOT DONE** with the next action). A deployed T4 that's stopped starts too ([Servers - Start](https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/start)); T3 resumes on its own at its first connection. The T2 guest starts with its host, and a golden snapshot's source host gets its guest back, as `start-demo.ps1` does; when no T1 Monitoring step runs in that run, T1's monitoring plugin is checked and restarted if it's stuck (`DEPLOY.T1.MONITORING`), as `start-demo.ps1` does after a deallocation. Running VMs are only read, and activity profiles stay as the run's own steps set them. The status page shows it as **Start the VMs that were stopped**: "Starting the VMs that were stopped: no action needed".
6. **Ctrl+C stops it within seconds**, at any point, with its track processes (Phase 28 live finding: a Ctrl+C at the guided stop had seemed to do nothing, because the stop waited for the T2 track's own cleanup, minutes of Azure calls). The run notes the Ctrl+C ([Console.CancelKeyPress](https://learn.microsoft.com/dotnet/api/system.console.cancelkeypress)) and leaves a cancel marker for the track processes, so their slow Azure cleanups (a Run Command's delete, the chunks' cleanup, the guided stop's Bastion removal and password rotation) are left to the next run or `./scripts/stop-demo.ps1`; a track that doesn't end within about 3 seconds has its process ended, with everything it started ([Process.Kill](https://learn.microsoft.com/dotnet/api/system.diagnostics.process.kill)), and only the process with the start time the track reported ([Process.StartTime](https://learn.microsoft.com/dotnet/api/system.diagnostics.process.starttime)), so a reused process ID ends nothing else. Their private files go with the run's handoff directory. Then the PC may sleep again, and the console and the status page end at **NOT DONE**, **Stopped, not done**, with the command that continues; the steps that were running go back to **Pending**. PowerShell usually ends the script itself after Ctrl+C, so the exit code is PowerShell's own. Stopped at the guided stop, Bastion stays up and `archost01`'s password from the guided stop stays valid until the next run cleans them up when it gets to T2, whether or not setup finished meanwhile (Phase 28 review: before, a guided stop that setup had finished in the meantime wasn't needed, so nothing removed them, and the run ended **DONE**), or until `./scripts/stop-demo.ps1` does; the host's request expires on its own, which turns the guest's one-time sign-in off. If you're stopping for the day, run `./scripts/stop-demo.ps1`, which removes Bastion and rotates the password.
7. **It ends with one banner:** **DONE**, with what Database Hub shows and where to look, or **NOT DONE**, with why, the single next action, and the exact command (usually `./scripts/deploy.ps1` again), plus `./scripts/collect-diagnostics.ps1` for a **Deployment problem** issue. The exit code is nonzero unless it's **DONE**. `DEPLOY.SUMMARY` stays, for the details. **DONE** never comes while the deployment state records a guided stop whose cleanup didn't finish (its Bastion may be up) or a handed-over host password that isn't rotated: the T2 step cleans them up first (`DEPLOY.T2.GUIDEDLEFTOVER`), in the parallel tracks and in `-Sequential`, and what's still open after that is **NOT DONE** with `./scripts/stop-demo.ps1 -RemoveBastionOnly` as the command (Phase 28 review).
8. **At the end** it prints the run's time, and, after a build, "capture a golden snapshot with capture-t2-golden.ps1 to make future redeploys skip the build and the guided stop".

**What to expect** (estimates from documented step times, not a measured run; the first fresh build with the parallel tracks will measure it):

| Run | About |
|---|---|
| A first deployment in `PaygWizard` mode | 2 to 3 hours in all: preflight 2 to 13 minutes, the template 7 to 9, the artifacts and loaders about 5, the T2 guest build 60 to 90, the guided stop about 10 minutes of a person's time plus 10 to 15 while setup installs, then the sign-in cleanup, the database, Arc's PAYG and monitoring, and telemetry in about 30 to 45 |
| When a person is needed (`PaygWizard`) | About 60 to 90 minutes after the start, for about 10 minutes. It can come later, and the run waits for them |
| A first deployment in `ProductKey` or `Developer` mode | 1.5 to 2.5 hours, with no step for a person |
| A redeploy from a golden snapshot | About 30 to 45 minutes, with no build and no guided stop ([measured](#faster-redeploy-phase-22): 38.8 and 63.7 minutes) |

#### What DONE needs

**DONE** means Database Hub shows every target ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md#1-when-the-clock-stops), owner, 2026-10-29: "The whole point is to see all the activity and performance and monitoring in the Database Hub in Fabric"): every track this configuration has finished, no **Fail**, no **Manual action required** except the Hub tenant setting's reminder (`PREFLIGHT.P4.HUBSETTING`, which no API reads) and the optional parts below, and a **Pass** for each of these. The run checks the ones it didn't see pass itself (`Invoke-DemoDoneGate`, read-only), so a resumed run judges every target:

- `HUB.ESTATE.T1` to `HUB.ESTATE.T4`;
- `TELEMETRY.T1`, `TELEMETRY.T2`, and `TELEMETRY.T3`, and T4's Azure Monitor metrics, `METRICS.T4`;
- in `PaygWizard` and `ProductKey` modes, T2's instance at Standard with PAYG (or Paid) and monitoring on: `T2.ARC.SQLINSTANCE` and `T2.ARC.MONITORING`;
- T1's inventory, `T1.SQLVM.ASSOCIATEDSERVICES`;
- the required Fabric items, `FABRIC.ITEMS.REQUIRED`: the workspace, the lakehouse, the notebooks, the Real-Time Dashboard, and the history model and report (left out with `-SkipFabric`).

Two cases have their own words:

- **T4 off** (`t4Enabled: false`, or the [Burstable fallback](#t4s-size-the-burstable-fallback-phase-28) left it uncreated): `HUB.ESTATE.T4` and `METRICS.T4` aren't needed, and **DONE** says that T4 isn't deployed, and why.
- **`Developer` mode** (opt-in): `TELEMETRY.T2` and T2's PAYG and monitoring aren't needed, and **DONE** states plainly that T2 has no performance data or Database Agent findings.

**Optional, never blocking DONE** (brief item 15): the Insights app (`APP_DatabaseHub_Insights`: `FABRIC.APP.*`, `DEPLOY.FABRIC.APP`, and every other record its step reports) and the history report's DAX data check while the **Dataset Execute Queries REST API** setting is off (`FABRIC.SEMANTICMODEL.*` **Manual action required**). **DONE** lists each one that didn't finish, with the actual reason from its step's records and how to add it later: that record's own fix first; the tenant settings **Fabric Apps (preview)** and **Dataset Execute Queries REST API**, which a Fabric administrator turns on, when they're open; then `./scripts/configure-fabric-app.ps1 -SignIn`, whose browser sign-in only you can do (an assistant can't do it for you). In `deploy.ps1` the app's records are never a **Fail**: a failure there is **Manual action required**, marked optional, and the status page shows the app's step as **Skipped** with that reason (Phase 28 live finding: it showed a **Fail** with a generic word about tenant settings that were on). The Fabric track gives the app's step the workspace it has just resolved or created (`configure-fabric-app.ps1 -WorkspaceId`, an override), so the app doesn't look it up by name again; live, that second lookup right after the creation failed.

#### The live status page and `status.ps1 -Watch`

`deploy.ps1` and every track process write one progress model, `out/deploy-progress.json`, at each step's start and end, under a lock, through a temporary file and a rename, so a reader never sees half a file. From it, `deploy.ps1` writes `out/deploy-status.html` at least every 15 seconds while it runs (both Git-ignored):

- **One banner, in exactly one of four states:** **Deploying, no action needed** (you can step away; keep the PC on; with the estimate and what's running), **Waiting for you** (the guided stop: what to do now, the portal link, the steps, and a countdown to its time limit), **Done** (where to look in Database Hub, and the optional items), or **Stopped, not done** (why, and the exact command, usually `./scripts/deploy.ps1` again). When `deploy.ps1` stops updating the model for more than 3 minutes (its window closed, or the PC slept or restarted), the page says **Stopped, not done** with when that happened.
- **The steps, per track, in order:** Preflight; Infrastructure; T1 (artifacts, bootstrap, monitoring, telemetry); T3; T4; Fabric; T2 (the host's build phases, the guided stop, the setup check, the sign-in cleanup, Arc onboarding, monitoring, and telemetry); Validation. Each shows **Pending**, **Running**, **Done**, **Action needed**, **Failed**, or **Skipped** (mapped from the [ADR 0012](adr/0012-validation-model.md) statuses underneath), its elapsed time, and a one-line message. A wait that's Azure's, such as an extension that a policy installs, says "Azure-side, no action needed".
- **Freshness:** the last update's time, and a warning when no step changed for 20 minutes while nobody was asked for anything.
- **Safe by design:** the page refreshes itself with `<meta http-equiv="refresh">` and has no JavaScript and no external resources, so it works offline. Every message is HTML-encoded (`System.Net.WebUtility.HtmlEncode`) and passes through the module's redaction (`Protect-DemoText`) first; the model holds no secret, and portal links are the only links.
- **Opening it:** `deploy.ps1` opens it at the start with `Start-Process` on Windows, `open` on macOS, and `xdg-open` where it exists. In GitHub Codespaces it prints the path and how to preview it: `python3 -m http.server 8000 --directory out` in a second terminal, then the forwarded port 8000 in the **Ports** tab and `deploy-status.html`; a forwarded port is private to you unless you change its visibility ([GitHub Docs: forwarding ports](https://docs.github.com/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace)). Or use `./scripts/status.ps1 -Watch`.
- **In a second terminal, anywhere:** `./scripts/status.ps1 -Watch` shows the same banner and steps in the console every few seconds (`-IntervalSeconds`), until the run ends. Without a local model (another machine, or after a restart without a rerun), it shows what `status.ps1` reads from Azure.

#### The guided stop (`PaygWizard`)

Pay-as-you-go without a product key is documented only in SQL Server setup's wizard ([install from the command prompt](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt): `/PID` is optional and installs Evaluation without it, and no parameter selects pay-as-you-go), so a person makes that choice, once per guest build. Everything around it is automated with documented mechanisms ([ADR 0006](adr/0006-sql-editions-and-licensing.md#amendment-one-command-one-guided-stop-phase-28-2026-10-29)):

1. **Before the prompt** (about 10 to 15 minutes, nothing to do yet): when the host reaches the setup step, `deploy.ps1` writes the host's request, with its time limit, creates on-demand Bastion in the background, and onboards Arc when the host waits for it. The host prepares the guest: SQL Server setup pre-filled from a [configuration file](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-using-a-configuration-file) (`/ConfigurationFile`, `UIMODE="Normal"`) with the features, the default instance, the service accounts, the sysadmins, and the Azure extension's subscription, resource group, region, and tenant (the file holds no secret); a logon task in the guest that opens it; a logon task on the host that opens [Virtual Machine Connection](https://learn.microsoft.com/windows-server/virtualization/hyper-v/virtual-machine-connection) to `arcsql01` when you sign in; and one automatic sign-in of the guest ([below](#the-guests-one-automatic-sign-in)).
2. **The prompt:** a large banner, a beep, and on Windows the console window flashes ([FlashWindowEx](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-flashwindowex)). The browser opens `archost01`'s page in the Azure portal, and the link is printed too. The prompt says what to do, about how long it takes, and how long the run waits for it: at least 45 minutes after it asks, until a printed local time. A short reminder repeats every 5 minutes until it's done. The status page's banner turns **Waiting for you**, with the same steps and a countdown, and one plain line is printed for an assistant to relay: `HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP - ...` with the status page's path.
3. **What the person does** (about 10 minutes, then 10 to 15 while setup installs):
   1. In the portal, on `archost01`'s page, select **Connect**, then **Bastion**, and sign in as the VM's administrator ([Bastion RDP](https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows)). The password: with a working clipboard, a one-time password is already on it (never shown, logged, or stored); with the [Key Vault opt-in](#opt-in-the-password-in-key-vault-instead-of-the-clipboard), it's in the vault; with neither (GitHub Codespaces, Cloud Shell, or any session without a clipboard), nothing is set or shown, and the prompt gives the portal's own path instead: open `archost01`, then **Help**, then **Reset password**, keep the user name, and type a password of your own choosing ([reset a password in the portal](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp)). The demo never sees it, and it's rotated afterward.
   2. Virtual Machine Connection to `arcsql01` opens by itself. The guest is already signed in, and SQL Server setup is open and pre-filled.
   3. On the **Edition** page, select **Use pay-as-you-go billing through Microsoft Azure**, then **Standard**, and **Next**; accept the license terms.
   4. On the **Azure Extension for SQL Server** page, select **Use Azure Login** and sign in with your own Azure account. Never enter a service principal secret.
   5. Select **Next** on the pre-filled pages, then **Install**. When setup says it's complete, select **Close**, and close the Bastion tab.
4. **The check, and recovery:** the host checks what was installed: SQL Server Standard, the default instance `MSSQLSERVER`, and the Azure extension that setup installed, before anything is onboarded. A wrong install (Evaluation or Developer, a named instance, or no Azure extension) isn't onboarded: the console, the status page, and `health.json` say exactly how to fix it with setup's documented steps ([edition upgrade](https://learn.microsoft.com/sql/database-engine/install-windows/upgrade-downgrade-sql-server-edition-setup) to pay-as-you-go Standard, or [uninstall a named instance](https://learn.microsoft.com/sql/sql-server/install/uninstall-an-existing-instance-of-sql-server-setup) and install again), and the run keeps waiting and checks again.
5. **After it, on its own:** the guest's automatic sign-in is turned off and cleaned up, `GuestSignInCleanup` removes the sign-in data that setup leaves on the VM and verifies that none remains (unchanged), the database is seeded, Arc's license type is set to PAYG and monitoring turned on, and T2's telemetry is awaited. Bastion is removed, and the host password is rotated to a value nobody keeps (a **Warning** when it can't be yet: `stop-demo.ps1` rotates it, and so does the portal's **Reset password** with a random value).
6. **A time-out** ends **NOT DONE** with `./scripts/deploy.ps1`, which waits for the step again; the host's request expires on its own, and the host then cleans up the guest's automatic sign-in.

#### The guest's one automatic sign-in

A colleague's assistant reached the guest's console with nobody there to sign in to Windows, so the run sat waiting. Since Phase 28 (owner-approved, 2026-10-29), the guest signs itself in once, for the setup step only ([ADR 0009](adr/0009-secrets-handling.md#phase-28-amendment-the-guests-one-automatic-sign-in-and-the-portal-password-reset-2026-10-29)):

- **Armed only while the guided stop waits for a person:** the guest's Administrator gets a new random password through the existing rotation; Windows automatic sign-in is turned on with `AutoLogonCount` 1; and the password is kept only as the LSA `DefaultPassword` secret, through the documented `LsaStorePrivateData` API ([protecting the automatic logon password](https://learn.microsoft.com/windows/win32/secauthn/protecting-the-automatic-logon-password), [LsaStorePrivateData](https://learn.microsoft.com/windows/win32/api/ntsecapi/nf-ntsecapi-lsastoreprivatedata)), never as the plaintext Winlogon `DefaultPassword` value ([turn on automatic logon](https://learn.microsoft.com/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon)). Nothing is downloaded. The guest restarts, signs in, and its logon task opens the pre-filled setup.
- **Always cleaned up**, in a `finally` after success, failure, or a time-out, and again by the host's next pass whenever the request has expired or gone: the console session is signed out first (Windows records the last console user at a sign-in), then `AutoAdminLogon` is set to 0, the LSA secret and the Winlogon `DefaultUserName` and `DefaultPassword` values are deleted, the guest password is rotated again, and a final read checks that nothing is left. `GuestSignInCleanup` then runs as before.
- **Fail closed:** the sign-in data scan (`check-sign-in-data.ps1`, the golden capture's gate, and the golden test's sign-in check) fails on automatic sign-in that's on, the LSA secret, or the Winlogon values, so no golden snapshot is captured with any of them; `-Clean` removes them. `status.ps1` reports a leftover as a **Warning** (`STATUS.T2.AUTOSIGNIN`), which the host's next pass removes.

#### Off the critical path: the policy inventory

Preflight's first policy inventory took 7 to 13 minutes, on the critical path. With `networkMode` `private`, it resolves nothing the template needs, so the parallel run's preflight leaves it out (its checks are **Not selected** for the moment) and runs it in a background job beside the template and the tracks. Its results replace the placeholders at the end, and one that hasn't finished after the tracks is a **Warning**. The template's what-if still runs before anything is created, so a policy that denies part of the deployment still stops the run before it starts. With `networkMode` `auto` (the default), nothing changes: the inventory decides whether T3 goes private, so it runs first, and its cache (`-PolicyCacheHours`) keeps later runs fast. With `public` it runs first too: a policy that turns SQL public access off modifies instead of denying, so the what-if doesn't see it, and `PREFLIGHT.POLICY.SQLPUBLIC` must stop the run before T3 is created public and then cut off from T1. `-SkipPolicyInventory` still skips it.

#### T4's size: the Burstable fallback (Phase 28)

When `t4SkuName` isn't set in your configuration and Azure refuses `Standard_B1ms` in the region (`SkuNotAvailable`, seen in West US 3), `deploy.ps1` tries `Standard_B2s`, the same Burstable class, by itself. Preflight already looks for both in the region's capability list ([az postgres flexible-server list-skus](https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-list-skus)) and starts with B2s when B1ms is missing, and a refusal the list didn't predict is retried at deployment. What was used is recorded in the resource group's tag `DbHubT4Sku`, so later runs reuse it. When both are refused, the run finishes without T4 (`DEPLOY.T4.SKU` **Warning**; `t4Enabled` stays as configured): **DONE** says T4 isn't deployed and why, and names `t4SkuName: Standard_D2ds_v5`, the General Purpose option, with its hourly price from the Retail Prices API. The fallback never picks a General Purpose size by itself, and a `t4SkuName` you set is never changed: a refusal of it is still a **Fail** ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md#2026-10-29-the-burstable-fallback-phase-28)).

#### Run Commands that don't stall a run (Phase 28)

A colleague's run waited on seven chunk Run Commands stuck in `Deleting` on `sqlvm01`, and its bootstrap never started. Policy-installed extensions (`MDE.Windows`, Guest Configuration, Defender for SQL, the Azure Monitor agent) can keep a new VM's agent from processing Run Command changes for a while (R49, R336). Now ([ADR 0003](adr/0003-t2-host-size-security-type-bootstrap.md#phase-28-amendment-chunk-hygiene-that-doesnt-stall-2026-10-29)):

- **Chunk deletes aren't waited for:** each chunk's delete is sent and the next chunk goes; one bounded cleanup at the end, and another at the next run, reports what Azure is still deleting as a **Warning** (`DEPLOY.ARTIFACTS.CLEANUP_<VM>`). Leftovers don't block the loader: a VM allows 25 managed Run Commands ([managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)).
- **Extensions settle first:** before a VM's artifacts and before its loader, the track waits up to 20 minutes until the VM's instance view ([az vm get-instance-view](https://learn.microsoft.com/cli/azure/vm#az-vm-get-instance-view)) shows no extension creating, updating, or deleting, and names each one in the log and on the status page: "Azure is finishing `<extension>` on `<VM>` (installed by a policy in your tenant); no action needed".
- **A watchdog:** when that wait, the chunks, or the loader stay stuck for about 15 to 20 minutes, it saves the VM's instance view (agent and extension statuses, redacted) to `out/diagnostics` for the diagnostics bundle, restarts that VM once ([az vm restart](https://learn.microsoft.com/cli/azure/vm#az-vm-restart), which Contributor may do; T1 before its bootstrap; the T2 host never during the guided stop, the golden Release, or its guest build, which the deployment state shows without asking the host's agent (`DbHubT2BuildUtc`), and while the Release runs, `archost01`'s artifacts go without the wait or the watchdog), says so on the status page with the cause and the restart's time (`DEPLOY.WATCHDOG_<VM>` **Warning**), and goes on. Still stuck: the run ends **NOT DONE** with `DEPLOY.EXTENSIONS_<VM>` **Fail**, naming the extension and the next step.
- **Sequential after a stall:** when no chunk finishes for 5 minutes while several run, the rest go one at a time (`DEPLOY.ARTIFACTS.STALL_<VM>` **Warning**), and a retry after the watchdog sends them one at a time too.

#### Diagnostics: `collect-diagnostics.ps1`

When a run ends **NOT DONE** and the next step doesn't help, `./scripts/collect-diagnostics.ps1` zips what a **Deployment problem** issue needs into `out/diagnostics-<time>.zip`: the results (`out/*.jsonl`), the progress model, the console transcripts (`out/logs`), and the saved instance views (`out/diagnostics`). It redacts every line again (`Protect-DemoText`), replaces GUIDs, e-mail addresses, the servers' random suffix, your home folder, and your configuration's owner and account with placeholders, scans the result with the module's secret scanner, and writes nothing when the scan finds anything (`DIAG.BUNDLE` **Fail**). Read the zip before you attach it: the repository is public.

### Parallel tracks (Phase 20)

The three tracks start right after Preflight, each in its own PowerShell process with its own subscription guard, which runs while the template deploys; each then waits for `deploy.ps1`'s word that the template succeeded. The bootstrap bundle and the workload runner are built while Preflight runs.

| Track | Steps, in order | Ready when |
|---|---|---|
| T1 (with T3) | T3Setup (T1 joins the T3 group while the template deploys, then sets T3 up from T1, so T3's telemetry starts early), Artifacts (the bundle and the runner to `sqlvm01` together, one wave of chunks), Bootstraps (the loader; T1's monitoring merged while the bootstrap runs; then T1 **Ready**), T3 (T3's workload and checks), Activity, Monitoring (the plugin confirmed; a plugin still NotRunning after the wait gets the SQL IaaS Agent's restart, `DEPLOY.T1.MONITORING`, Phase 25d), Telemetry | `TELEMETRY.T1` and `TELEMETRY.T3` **Pass** |
| T2 | Restore (a golden host starts as soon as the template has deployed `archost01`: VM agent, host password, then the Release, with the bundle and the runner sent meanwhile), Artifacts (whatever didn't arrive), Bootstraps, T2 (`configure-arc`'s sequence, with `-Force` for a golden host; then the host's own verdict, `DEPLOY.T2.READY`, before T2's profile, Phase 25d), Telemetry | `T2.ARC.SQLINSTANCE` (Standard, PAYG) and `T2.ARC.MONITORING` **Pass**, then `TELEMETRY.T2` |
| Fabric | `configure-fabric.ps1` (notebooks and the Real-Time Dashboard), `configure-powerbi.ps1` (the history model, its refresh and data check, and the report), and `configure-fabric-app.ps1` when the checkout has it (Phase 19b; otherwise `DEPLOY.FABRIC.APP` **Not selected**) | The track passes |

- **Where T2 comes from (`t2Source`):** `auto` (the default) restores a new `archost01` from the newest boot-verified golden snapshot in `rg-<prefix>-golden`, which keeps the owner's pay-as-you-go setup-wizard step, and builds the guest from the image when there's none; `golden` requires a snapshot; `build` always builds. An existing host keeps its disk. Preflight reports the choice (`PREFLIGHT.T2.SOURCE`).
- **Without a snapshot** (forks, customers), the T2 track sends the artifacts and starts the guest build. Since Phase 28, `deploy.ps1` waits for it by default, in every install mode, with the [guided stop](#the-guided-stop-paygwizard) in `PaygWizard` mode, and finishes T2 in the same run. With `-NoWaitForT2` (or in CI without `-WaitForT2`) it returns once T1, T3, T4, and Fabric are ready, with `DEPLOY.T2.BACKGROUND` as **Manual action required**: a later `./scripts/deploy.ps1` continues T2.
- **The validation** then checks the Hub Estate, T1's unified inventory (`T1.SQLVM.ASSOCIATEDSERVICES`, a **Fail** when Analysis Services or Integration Services are still listed after up to 10 minutes), the runner, the T3 readiness gate, and the dashboard's tiles. `DEPLOY.TIMING` records each track's steps, each target's ready time, and the total.
- **The clock stops** when everything [DONE needs](#what-done-needs) has passed: the Hub Estate for T1 to T4, telemetry for T1, T2, and T3, T4's metrics, T2's instance (Standard, PAYG) and monitoring, T1's inventory, and the required Fabric items, with T4's checks left out when T4 is off and T2's performance checks in `Developer` mode ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md#1-when-the-clock-stops), amended in Phase 28 to include T4).

**Measured (live, 2026-10-22):** after `destroy.ps1` removed `rg-dbhub-demo`, `deploy.ps1` restored it with the same names, T2 from the golden snapshot. **The 30-minute target wasn't met:** 38.8 minutes end to end.

| Step | Phase 20, parallel (`rg-dbhub-demo`, `PaygWizard`, golden T2) | Phase 16, sequential (`rg-dbhub-test`, `Developer`, `-SkipFabric`, 2026-10-21) |
|---|---|---|
| Guard | 68 seconds | 1.2 minutes |
| Preflight | 215 seconds (policy inventory reused) | 12.5 minutes (policy inventory about 7) |
| Infrastructure | 428 seconds (template 6 minutes 32 seconds) | 7.4 minutes |
| T1 track: artifacts, bootstrap, T3, activity, monitoring, telemetry | 370, 296, 279, 85, 170, and 134 seconds (23.1 minutes) | Artifacts 19.2 minutes (both VMs, one after the other), bootstraps 10.7, T3 3.6, activity 1.3, monitoring 1.7 |
| T1 and T3 ready | **+36.3 minutes** | `TELEMETRY.T1` +58.5 minutes, `TELEMETRY.T3` +62.9 minutes |
| T2 track: restore (host password 97 seconds, Release 531), artifacts, loader, Arc, telemetry | 671, 291, 81, 379, and 3 seconds (24.5 minutes); the SQL Server extension arrived in about 5 minutes this time (R72) | Guest build about 35 minutes, then onboarding failed on the guest's DNS (21.9 minutes, **Fail**; fixed since) |
| T2 ready | **+37.7 minutes** | Not reached |
| Fabric track | About 2.4 minutes (141 seconds, after a fix; [below](#what-the-live-run-found)) | Skipped |
| Validation, end to end | 51 seconds; **38.8 minutes** | |

T2's track was the critical path. Phase 20 estimated about 30–31 minutes with four overlaps: T2's artifacts during the Release (about 4.9 minutes), each track's guard during the template deployment (about 1.2), T1's bundle and runner at once (about 1.7), and T1's monitoring alongside its bootstrap (about 2.8). Phase 22 built them, and two more; see [faster redeploy (Phase 22)](#faster-redeploy-phase-22). The repeat start is in [expected duration](#expected-duration).

#### What the live run found

- **The Fabric track stopped at once:** `configure-fabric.ps1`, run from module code, ran in the module's session state, so `Get-DemoConfig` couldn't read the module's `$script:RepoRoot`. The scripts now run in a separate session state, as an operator runs them; the fixed track passed in the `-Resume` run (141 seconds).
- **T1's unified inventory kept listing Analysis Services and Integration Services** for 46 to 72 minutes after the bootstrap uninstalled them: nothing restarted the SQL IaaS Agent, which the sequential path's second template deployment did, so they went only about an hour after the agent had started. The `AssociatedServices` step now restarts it, and the validation fails when they're still listed.
- **`validate.ps1` failed the loader check:** the parallel tracks run the loader in a Run Command and remove it. The check now reads the bundle from `health.json`.
- **Two checkouts of the same source built two workload runners,** so a deploy from the other checkout reinstalled the runner on both VMs: the build recorded the commit and the checkout's path. The build now leaves both out, and two checkouts build the same runner, byte for byte.
- **The repeat start called `sqlvm01` missing** while it was starting (its instance view had no power state right after the start request), and then **left T1's activity profile unset**, because T1's SQL Server wasn't accepting connections yet when both VMs booted at once. The start now waits for a power state and retries T1's profile as it does T2's.
- **T1 sent no Hub telemetry after those starts:** its monitoring plugin stayed NotRunning for more than 90 minutes after the deallocation, until the SQL IaaS Agent service was restarted. `start-demo.ps1` now restarts it when the plugin isn't running.
- **The golden Release read the guest's Arc agent before it was up** and took "no answer" for "no identity". It now waits up to 5 minutes for the agent and stops with the guest air-gapped if it can't tell ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md#amendments-2026-10-22-live)); unit-tested, not yet run live.

### Faster redeploy (Phase 22)

Phase 22 built Phase 20's follow-up overlaps, and two more that G6's timeline showed were needed ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md#amendments-2026-10-23-phase-22-the-follow-up-overlaps)):

| Overlap | What changed | Phase 20's estimate |
|---|---|---|
| T2's artifacts during the Release | The bundle and the runner travel in their own chunk Run Commands while the golden Release runs; the Artifacts step sends whatever didn't arrive | About 4.9 minutes |
| The guards during the template | The track processes start right after Preflight and wait for the template's result | About 1.2 minutes |
| T1's bundle and runner at once | One wave of 8 chunk Run Commands instead of two | About 1.7 minutes |
| T1's monitoring alongside its bootstrap | The feature-flag merge right after T1's loader, with no other Run Command on `sqlvm01`; the Monitoring step confirms the plugin | About 2.8 minutes |
| T2 before the template finishes | A golden T2 starts its Restore as soon as the template has deployed `archost01` | New |
| T3 first | T1 joins the T3 group during the template and sets T3 up before its own artifacts: T3's telemetry started about 10 minutes after its setup in G6 | New |

**Measured (live, 2026-10-23):** after `destroy.ps1` removed `rg-dbhub-demo` again, `deploy.ps1` restored it with the same names, T2 from the golden snapshot. A first run doesn't count, because the machine that ran it went to sleep in the middle of it. The second run, with the machine kept awake, measured **63.7 minutes** end to end ([implementation report](implementation-report.md#phase-22-faster-redeploy-the-follow-up-overlaps-and-one-timed-destroy-and-redeploy)): T1 and T3 were ready 9.5 minutes sooner than in Phase 20, but T2 waited about 29.5 minutes for the SQL Server extension's download in the guest (R72), so **the 30-minute target wasn't met**.

| Step (from the start of `deploy.ps1`) | Phase 20 (G6, 2026-10-22) | Phase 22 (run 2, 2026-10-23) |
|---|---|---|
| Guard, then preflight (policy inventory reused) | 68 and 215 seconds | 22 and 169 seconds |
| Template | 6 minutes 32 seconds | 6 minutes 58 seconds |
| Track processes and their guards | After the template; each guard about 70 seconds | Before the template; every guard done at +4.0 minutes |
| T2's Restore starts | +13.4 minutes | **+4.9 minutes** (`archost01` deployed 1.5 minutes into the template) |
| T2's Release | Starts at +15.7 minutes; 531 seconds | Starts at +7.2 minutes; **1,007 seconds**: 210 waiting for the air-gapped agent, then the reset |
| T2's bundle and runner | 291 seconds, after the Release | During the Release (908 seconds; each chunk's delete waited for the Release to end) |
| T1's first step | +13.3 minutes | +10.8 minutes: T3's setup first (106 seconds) |
| T1's artifacts, then its bootstrap | 370 seconds, then 296 | 223 (one wave of 8 chunks), then 372 (T1's monitoring merged inside) |
| T1's Monitoring step | 170 seconds | **18 seconds** |
| **T1 and T3 ready** | **+36.3 minutes** | **+26.8 minutes** |
| Fabric track | About 141 seconds, after a fix (F16) | 371 seconds, done at +17.1 minutes (F4: not comparable) |
| T2's Arc step: onboarding, then the SQL Server extension (R72), PAYG, and monitoring | 379 seconds (the extension arrived in about 5 minutes) | 2,148 seconds: onboarding done at +31.1 minutes, then about 29.5 minutes of failed downloads in the guest |
| **T2 ready** | **+37.7 minutes** | **+61.7 minutes** |
| Validation | 51 seconds | 112 seconds |
| **End to end** | **38.8 minutes** (the clock didn't stop: the Fabric track failed) | **63.7 minutes**: the clock stopped, and no check **Fail**; the same with or without the Fabric track |

- **What the overlaps gave:** T1 and T3 ready 9.5 minutes sooner, T2's Release started 8.5 minutes sooner, and the Monitoring step dropped from 170 seconds to 18.
- **What held T2 back:** the SQL Server extension's download (R72, about 29.5 minutes this time; about 5 in Phase 20 and about 2 in the first run), and the Release, which now resets the copy's identity whenever its agent doesn't name another one (1,007 seconds against 531). Without R72, an estimate puts the run at about 35.5 minutes; that isn't a measurement.
- **Then:** `validate.ps1`, every area: 89 checks, 70 **Pass**, 10 **Warning** (the F4 capacity's viewer licensing, four policy notes, T3 without the free offer in two checks, `INFRA.HEALTH.SQLVM01`, and T1's and T2's scenario bounds, whose runner status was longer than the 4,096 bytes a Run Command keeps), 1 **Manual action required** (the Hub tenant setting, P4), 7 **Not selected**, and 1 **Fail**: `SECURITY.SECRETSCAN.OUTPUT`, with 77 of its 79 pattern matches in the Fabric App's third-party packages under `out/` ([troubleshooting](troubleshooting.md#the-insights-app-fabric-app)). A second `deploy.ps1` converged in **19.2 minutes** with nothing to change: no bundle or runner sent again, T2's Arc machine already connected, and in Resource Graph exactly one `arcsql01` machine and only the `sqlvm01` and `arcsql01` SQL Server instances.
- **Follow-ups, not built:** the Release can reset without waiting for an answer it no longer needs (about 3.5 minutes); chunk deletes beside a long Run Command can be left to the final cleanup; R72 has no documented fix.

### T4 in the deployment (Phase 24)

T4, the PostgreSQL flexible server `pgflex01-<deploymentId>` ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)), comes with the template, on by default (`t4Enabled`):

- **Its size and zone:** `t4SkuName` is `Standard_B1ms` by default; `Standard_B2s` is the documented fallback when Azure refuses B1ms in the region, and `Standard_D2ds_v5` (General Purpose, 2 vCores, 8 GiB) the documented option the owner chose on 2026-10-26 after both were refused; the tier follows the size. `t4AvailabilityZone` (empty, `1`, `2`, or `3`) applies only when T4 is created, because a server keeps its zone. Since Phase 28, when `t4SkuName` isn't set, `deploy.ps1` moves from B1ms to B2s by itself, and finishes without T4 when both are refused ([the Burstable fallback](#t4s-size-the-burstable-fallback-phase-28)). A size you set is never changed: when Azure refuses it with `SkuNotAvailable`, the template fails and `DEPLOY.T4.SKU` is a **Fail** that names the next option, and the next preflight reports it again (`PREFLIGHT.T4.SKU`, a **Warning** instead for one more try in another zone) ([capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors)).
- **Before the template:** a stopped T4 is started first (`DEPLOY.T4.START`), because a stopped flexible server rejects every other management operation, the template's update included.
- **The T4 track** (its own process, like T1, T2, and Fabric): `Server` runs `Test-DemoT4` (`T4.SERVER`, `T4.CONFIG`, `T4.ENTRAONLY`, `T4.NETWORK`, `T4.ADMIN`, `T4.DATABASE`, `T4.ENHANCEDMETRICS`); `Telemetry` waits for its Azure Monitor metrics (`METRICS.T4`). The validation adds `HUB.ESTATE.T4`.
- **T1's track** gets a `T4` step after `T3`: `Enable-DemoT4Workload` (`WORKLOAD.T4.ENABLE`) has T1's managed identity, a member of the P6 group, sign in as the group's role, create the runner's role, apply and seed the schema, and add T4 to the activity host. A T4 failure is reported (and in `DEPLOY.SUMMARY`) but doesn't stop T1's track; `deploy.ps1 -FromStage T4` runs the T4 work again. The Activity step sets T4's profile with T1's and T3's.
- **The stage** `T4` sits between `T3` and `Activity` for `-FromStage`, `-StopAfter`, and `-Sequential`; `-Resume` continues the T4 track after `DbHubTrackT4`.

## Day to day

### Start: `start-demo.ps1`

```powershell
./scripts/start-demo.ps1 -WarmUpMinutes 30
```

1. **Cost guardrail:** the live estimate against `sessionCeilingUsd` and `monthlyCeilingUsd`, and this month's actual cost (Cost Management, which lags by up to a day) plus one session against `monthlyCeilingUsd`. A **Fail** stops the start before anything runs; `-SkipCostCheck` starts anyway. The estimate and the month-to-date figure include the golden snapshots in `rg-<prefix>-golden`.
2. Starts `sqlvm01` and the T2 VM at once (Phase 20). A VM that's still deallocating (for example during the nightly auto-shutdown) is waited for first. A golden snapshot's source host gets its air-gapped guest back (`T2.GOLDEN.SOURCE`). T1's monitoring plugin, which can stay NotRunning after a deallocation, gets the SQL IaaS Agent service restarted (`START.T1.MONITORING`), so T1 keeps sending Hub telemetry. Right after boot the agent reports no plugin status yet, and a restart then can leave the plugin NotRunning (live, 2026-10-26), so the step first waits up to 5 minutes for that status. It restarts the service only when the plugin isn't Running, or still has no status, and then waits up to 5 minutes for Running and uploads OK; a restart that doesn't help is a **Warning**. With the on-demand activity control, a notebook run's pending auto-stop is cancelled first, because this session takes over: a **Warning** (`START.CONTROL.AUTOSTOP`) says the VMs now run until `stop-demo.ps1` or the nightly auto-shutdown at its time. If it can't be cancelled, the start carries on and the Warning gives the pending stop's time and how to cancel it. A run's `DbHub-Stop` job that's already queued or running is waited for, up to 10 minutes, and never stopped (`START.CONTROL.STOPJOB`) ([ADR 0020](adr/0020-on-demand-activity-control.md#stop-layers)).
3. **T3** persists between demos by default and is resumed. After `stop-demo.ps1 -RemoveT3`, it's recreated under the same names from the recorded bundle and runner, configured from T1, and checked by the readiness gate, which reports a **Warning** with the measured lag until Resource Graph, the extended property, and fresh telemetry all agree. T1's monitoring is checked again after that template deployment.
4. **T4** (Phase 24): its start is requested with the VMs and confirmed before its profile is set (`START.T4.START`); `-SkipT4` leaves it stopped.
5. Sets the activity profile (`-ActivityProfile`, or the configured `activityProfile`) on T1, T3, T4, and T2 until the next auto-shutdown. T2's guest needs a few minutes after the host starts, and T1's SQL Server can still be starting because both VMs boot at once, so both profiles are retried.
6. `-WarmUpMinutes` lets the activity run in the background (`START.WARMUP`), so the script returns once the profiles are set; `-WaitForWarmUp`, which the scheduled start and warm-up workflows pass, waits that long and then checks that telemetry arrives, so Hub charts have history when the presenter joins.
7. **The Fabric capacity, opt-in** (`fabric.manageCapacity`, Phase 26b): by default the capacity isn't called, and `START.FABRIC.CAPACITY` is **Not selected**. With `fabric.manageCapacity` true, for an F capacity that's yours alone, in the configured subscription, and named in `fabric.capacityName`, a **Paused** capacity is resumed ([Fabric Capacities - Resume](https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/resume), before the VMs start) and recorded in the resource group's tag `DbHubFabricCapacityResumed` (`<resource group>/<name>`, with `DbHubFabricCapacityResumedUtc`), so `stop-demo.ps1` pauses only what the demo resumed. An Active capacity is left as it is and not recorded. A Trial capacity or one in another subscription isn't an Azure resource the scripts can reach: **Not supported**. Contributor on the capacity is enough. It bills while it runs, outside the demo's cost ceilings.

### Stop: `stop-demo.ps1`

```powershell
./scripts/stop-demo.ps1               # Bastion, the password, profiles off, the guest, then both VMs
./scripts/stop-demo.ps1 -SaveHistory  # the same, then the session's history saved to the lakehouse (opt-in)
./scripts/stop-demo.ps1 -ParkT2       # only the T2 side; T1 and T3 keep running for agent-focused demos
./scripts/stop-demo.ps1 -RemoveT3     # also delete T3; start-demo.ps1 recreates it under the same names
```

In order, it removes on-demand Bastion and then its public IP, rotates the T2 host's one-time password, sets every activity profile to `off`, shuts the guest down cleanly, and deallocates the VMs. Once Bastion is gone, it also clears the record of a guided stop whose cleanup didn't finish, as after a Ctrl+C at the guided stop, so `deploy.ps1`'s **DONE** no longer waits for it (Phase 28 review). Before T2's SQL Server setup, the guest has no demo module or workload runner yet, so T2's profile is **Not selected** ("T2 isn't set up yet"), not a **Warning** (Phase 28 live finding; `status.ps1 -Detail` and `start-demo.ps1` say the same). T3 stays: with its profile off it auto-pauses `t3AutoPauseMinutes` after the last session. Turning the T3 profile off doesn't wake T3, because the T3 profile is a file on T1. T4's profile goes off and T4 stops (`STOP.T4.STOP`); a stopped flexible server starts on its own after seven days, which `status.ps1` reports. A T4 that was never created is left alone (both **Not selected**); one whose state couldn't be read is still stopped. With the on-demand activity control, it also removes a pending auto-stop of a notebook run (`STOP.CONTROL.AUTOSTOP`), so it can't deallocate the VMs of a later session.

Phase 26b adds two opt-in steps at the end, both skipped with `-ParkT2`:

- **The session's history** (`-SaveHistory`, or `fabric.saveHistoryOnStop` true; `STOP.FABRIC.SAVEHISTORY`): `NB_DatabaseHub_LiveActivity` runs on demand ([Run On Demand Item Job](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job)) over the last `-SaveHistoryWindowMinutes` (720 by default, in 5-minute bins), at most 15 minutes, with `SAVE_RESULTS` true and `CONFIRM` and `STOP_ACTIVITY` false, so it writes only the lakehouse's history tables. The workspace and lakehouse are found by name, never created here. A capacity that isn't running is **Manual action required**. Overlapping runs are fine: the report keeps the newest capture of each bin.
- **The capacity the demo resumed** (`fabric.manageCapacity` true; `STOP.FABRIC.CAPACITY`): only the capacity that the tag `DbHubFabricCapacityResumed` records is paused ([Fabric Capacities - Suspend](https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/suspend)), after the history run, never while it's still going, and then the record is cleared. A record of a capacity that's already paused is stale and is cleared without a call. A capacity the demo didn't resume stays running. With the default (false), the capacity isn't called, and a record left from earlier is a **Warning**.

### Disks the subscription's automation switched (Phase 24)

On 2026-10-24 an application identity that isn't the demo's switched both VMs' OS disks to Standard HDD while they were deallocated, and the next template deployment failed: Azure doesn't change an OS disk's type through its VM (`OperationNotAllowed`). For an existing VM, `deploy.ps1` now reads each disk's current type (`Get-DemoVmDiskDrift`), passes each drifted disk's type to the template (`diskSkuOverrides`, OS and data disks on both VMs), and carries on with the `DEPLOY.DISKS.DRIFT` **Warning**; `status.ps1` reports the same drift (`STATUS.DISKS`). The demo never changes a disk back ([limitations](limitations.md#deployment-and-operations), R440).

### Status: `status.ps1`

`./scripts/status.ps1` is read-only. It reports health per target, the VMs' disks against the profile (`STATUS.DISKS`: a **Warning** names each disk whose type the subscription's automation switched), T1's SQL Server instances in unified inventory (`T1.SQLVM.ASSOCIATEDSERVICES`: **Pass** when only the engine is listed, a **Warning** while the image's Analysis Services or Integration Services still are; T1's `AssociatedServices` step stops, disables, and uninstalls them) and its monitoring, T3's state, T4's state with its live Azure Monitor metrics (CPU, memory, connections, CPU credits, sessions by state and by wait event type, the oldest transaction, deadlocks) or, when stopped, when it starts again (`STATUS.T4`), the active activity profile on T1, T3, and T4, Arc's connection and days disconnected, on-demand Bastion and its public IP with their hourly list price, the month-to-date cost against the monthly ceiling, the next auto-shutdown, and the expiry tag. `-Detail` adds the full health (the guest's evaluation days left, the runner), T2's profile, and T4's live view from T1's runner (`STATUS.T4.LIVE`: connections against `max_connections`, sessions by state, blockers, the oldest transaction); each is a Run Command of about 30–60 seconds. With `fabric.manageCapacity` true, or a `DbHubFabricCapacityResumed` record left from earlier, `STATUS.FABRIC.CAPACITY` shows the capacity's state and whether `start-demo.ps1` resumed it; it only reads, so a stale record stays for `stop-demo.ps1` to clear.

### Reset: `reset-demo.ps1`

`./scripts/reset-demo.ps1 [-Target T1] [-Reseed] [-UndoRemediation]` runs the runner's `reset` on each target: it stops every scenario and profile, kills leftover `ContosoCare.Demo/` sessions, checks that no demo transaction is open, empties the scratch tables, and sets the profile to `off` (unless `-KeepProfile`). Resetting T3 connects to it, which resumes a paused database. `-RebuildGuest` reports **Not supported** for now: run `destroy.ps1`, then `deploy.ps1`.

### Destroy: `destroy.ps1`

`./scripts/destroy.ps1` deletes the Arc SQL Server instances first, then the Arc machines, then the resource group with everything in it, and waits until it's gone. Then it deletes the subscription deployment record `<prefix>-<environment>-main` (`dbhub-demo-main` with the defaults) and runs the residual check (`TEARDOWN.RESIDUAL.*`, summed up in `DESTROY.RESIDUAL`): nothing carrying the environment's tags, no Arc resource, role assignment, managed identity, P6 membership, deployment record, or budget may be left. Before it deletes anything it writes `out/destroy-manifest-<environment>.json` (names and IDs only), which the check and the [teardown tests](../tests/teardown/README.md) need once the group is gone. It asks for confirmation unless `-Force`; `-SkipResidueCheck` and `-ResidueWaitMinutes` control the check. With `-IfExpired` (the expiry workflow), it does nothing until the day after the resource group's `expiresOn` tag. The GitHub identity's resource group, `rg-<prefix>-control`, stays, and so does `rg-<prefix>-golden` with the T2 golden snapshots unless `-IncludeGolden`; an environment whose T2 holds a `PaygWizard` install is refused (`DESTROY.GOLDEN.GUARD` **Fail**) without a boot-verified snapshot, unless `-WithoutGolden`. If it stops halfway, run it again. With `fabric.manageCapacity` true, a capacity that the tag `DbHubFabricCapacityResumed` records is paused before the group, and the record with it, goes (`DESTROY.FABRIC.CAPACITY`, a **Warning** when it can't be: then pause it yourself); with the default, the capacity isn't called. [Cleanup](cleanup.md) has the details, the tested results, and what to do after a partial failure; never destroy an environment someone else uses, such as one with a completed `PaygWizard` step, without their go-ahead.

## Activity profiles and boot behavior

- `deploy.ps1` (the Activity stage), `start-demo.ps1`, `demo-control.yml`, and the live-activity notebook set a profile: `off`, `baseline`, `business-day`, or `incident:<scenario>`. Every profile ends two minutes before the next auto-shutdown.
- **The VMs don't set a profile at boot by default** (`activityProfileOnBoot: false`). A VM that starts some other way (a manual start in the portal, a restart) serves only the profile someone set, and `stop-demo.ps1` sets every profile to `off`. Live, the task restarted `baseline` on T1 and T3 at every boot, which kept T3's serverless database awake ([ADR 0016](adr/0016-cost-profiles.md), R183).
- Set `activityProfileOnBoot: true` to have every boot start the configured profile again, for example for an unattended scheduled start without `start-demo.ps1`.
- After a runner install (a deployment), the VMs apply the configured profile once, whatever this setting.

## Bastion and the one-time host password

The T2 setup-wizard step (`PaygWizard` mode) needs the host's desktop. Bastion is on demand only. Since Phase 28, `deploy.ps1`'s [guided stop](#the-guided-stop-paygwizard) creates it, hands over the password the same way, and removes it afterward; by hand:

```powershell
./scripts/start-demo.ps1 -Interactive -ResetAdminPassword
```

- `-Interactive` deploys Azure Bastion Basic and its Standard public IP from `infra/modules/bastion.bicep` into the existing `AzureBastionSubnet` (about 8 minutes live). It's a template deployment, because the Azure CLI's `az network bastion` commands need an extension that prompts to install. It's tagged with an expiry of now plus `bastionMaxHours` (4 by default); a longer request is capped at it.
- `-ResetAdminPassword` sets a one-time password for the host's administrator with a Run Command (`Set-LocalUser`; the password travels only as a protected parameter) and copies it to your clipboard. It's never displayed, logged, or stored. Without a working clipboard (GitHub Codespaces, Cloud Shell, GitHub Actions) and without the Key Vault opt-in, nothing is set or shown: in the Azure portal, open `archost01`, then **Help**, then **Reset password**, keep the user name, and set a password of your own choosing, then sign in through Bastion with it ([reset a password in the portal](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp), which uses the VMAccess extension). The resource group records that a password was handed over (Phase 28), so `stop-demo.ps1` rotates yours afterward too.
- `stop-demo.ps1` deletes the Bastion host, then its public IP, and rotates the password to a value nobody keeps. The hourly `bastion-cleanup.yml` does the same after the expiry, and deletes at once a public IP that an interrupted Bastion delete left behind (a public IP bills by the hour on its own); `status.ps1` reports either as a **Warning** with its current hourly list price.
- A rotation needs the host running. When it's deallocated, the result is **Manual action required** with the steps; the next `start-demo.ps1` rotates a leftover one-time password for you. A rotation that fails on a running host is a **Warning** since Phase 28 (it was a **Fail**): the record stays, so the next stop or start tries again, and the portal's **Reset password** with a random value you don't keep does the same.

### Opt-in: the password in Key Vault instead of the clipboard

With `keyVault.enabled: true` (owner decision, 2026-10-21), the one-time password goes to an Azure Key Vault instead of your clipboard, so `start-demo.ps1 -Interactive -ResetAdminPassword` works from any session, including Cloud Shell. It's off by default: the default path stays Contributor-only, with no vault and no role assignment ([ADR 0008](adr/0008-identity-rbac-abac.md), [ADR 0009](adr/0009-secrets-handling.md)).

```json
"assignRoles": true,
"keyVault": { "enabled": true }
```

- **It requires `assignRoles: true`**, and the account that runs `deploy.ps1` needs `Microsoft.Authorization/roleAssignments/write` on the resource group (Owner, User Access Administrator, or Role Based Access Control Administrator). The schema refuses `keyVault.enabled` without `assignRoles`, and no vault is deployed when the permission is missing.
- **The vault:** `deploy.ps1`'s Infrastructure stage deploys `infra/modules/keyvault.bicep` as `kv-<prefix><environment>-<deploymentId>`: RBAC authorization, no access policies, soft delete (`keyVault.softDeleteRetentionDays`, 7 by default; Key Vault fixes it at creation), purge protection only with `keyVault.purgeProtection` (irreversible), and the firewall open to all networks unless `keyVault.allowedIpRanges` lists your public addresses. If a tenant policy requires purge protection or a firewall, set those; a denial names the policy. A vault **Fail** is reported but doesn't stop the deployment, because only `start-demo.ps1 -Interactive` needs it. Sources: [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide), [soft delete](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview).
- **Access, on the vault only, by role name:** you (the signed-in caller) and `keyVault.operatorObjectIds` get **Key Vault Secrets Officer**, to write and disable the password; `keyVault.readerObjectIds` get **Key Vault Secrets User**, to read it in the portal. Add the GitHub workflow identity to `keyVault.operatorObjectIds` so the scheduled stop can disable the secret. A new role assignment can take several minutes to reach Key Vault; the write retries for up to 10 minutes.
- **Start:** `start-demo.ps1 -Interactive -ResetAdminPassword` makes sure of the vault and your access, stores the password as the secret `<vm>-one-time-password` (content type `password`, the VM and user name as tags, the Bastion expiry as its expiry), and only then sets it on the VM. The value reaches the Azure CLI in a private temporary file, never on a command line, and the CLI returns only the secret's ID. Older versions are disabled. If the VM refuses the password, the new version is disabled at once.
- **Stop:** `stop-demo.ps1` (and the scheduled stop and `bastion-cleanup.yml`) rotates the host password and disables every enabled version of the secret (`STOP.KEYVAULT`), even when the host is deallocated and can't be rotated. Nothing is deleted. `status.ps1` reports a readable password past its expiry as a **Warning** (`STATUS.KEYVAULT`).
- **Destroy:** the vault goes into soft delete with the resource group (`DESTROY.KEYVAULT` says for how long). Its name stays taken until the retention ends, so a `deploy.ps1` within that time recovers it under the same name (`az keyvault recover`).

**Signing in with the stored password.** Bastion's RDP connection form offers **Microsoft Entra ID (Preview)**, **Username and password**, and **Kerberos**; it has no Key Vault option ([Connect to a Windows VM using RDP](https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows), checked 2026-10-21). Only Bastion's SSH forms still offer **Password from Azure Key Vault** ([SSH to a Windows VM](https://learn.microsoft.com/azure/bastion/bastion-connect-vm-ssh-windows)), and the setup wizard needs the desktop. So:

1. In the Azure portal, open the key vault named in `START.KEYVAULT`, then **Objects** > **Secrets** > `archost01-one-time-password`, and select the current version.
2. Copy the **Secret value** with the portal's copy button next to the field; you don't need to show it ([Key Vault quickstart, retrieve a secret](https://learn.microsoft.com/azure/key-vault/secrets/quick-create-portal) describes the page).
3. Open `archost01`, select **Connect** > **Bastion**, choose **Username and password**, enter the user name from `START.KEYVAULT`, paste the password, and select **Connect**.

The copy happens inside the portal, so the machine that ran `start-demo.ps1` needs no clipboard. **Future option:** Microsoft Entra ID sign-in through Bastion, which needs no password at all. It's in preview for RDP, works with Bastion Basic in the portal, and needs Windows Server 2022 or later, the `AADLoginForWindows` extension on the host, and the **Virtual Machine Administrator Login** role ([Bastion Microsoft Entra ID authentication](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication)). It isn't implemented: it would join the host to Microsoft Entra ID and add a role assignment.

## The on-demand activity control

Optional, off by default ([ADR 0020](adr/0020-on-demand-activity-control.md); why it may need a second workspace is in the [README](../README.md#why-it-may-need-a-second-workspace)). It's set up apart from `deploy.ps1`, once, and lives in `rg-<prefix>-control`, which destroy keeps:

```powershell
# 1. In config/demo.config.json: "control": { "enabled": true } (vaultNetworkMode auto by default)
./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -WhatIf   # what it would do
./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json           # Contributor
# 2. An Owner, signed in with multifactor authentication:
./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole
# Later: a new webhook before the old one expires
./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -RotateWebhook
```

- **Setup** reports `CONTROL.*` results: the vault's mode from the tenant's policy (`CONTROL.MODE`), the provider and the group, the identity, account, and vault (`CONTROL.RESOURCES`), both runbooks published with the current scenario catalog (`CONTROL.RUNBOOKS`; run setup again after a scenario changes), the daily T4 safety stop, the webhook and its secret, and the notebook in Fabric (`CONTROL.FABRIC.*`), then which roles an Owner still has to grant, summed up in `CONTROL.SUMMARY`. Every step is idempotent, and `-WhatIf` changes nothing. `-SkipFabric` leaves Fabric for later, for example while the capacity is paused; this script never resumes, pauses, or scales it.
- **Then, in Fabric:** open `NB_DatabaseHub_Control` (in the folder "DBHub Control" of the existing workspace, or in the "DBHub Control" workspace when the vault is private), set `ACTIVITIES` and `DURATION_MINUTES`, run it once as a dry run, then set `CONFIRM = True` and run section 3 ([the notebook's guide](../fabric/control/README.md)).
- **Check it** with `validate.ps1 -Area Workload` (`CONTROL.*`) and `status.ps1` (`STATUS.CONTROL`: an active run and its auto-stop, the webhook's expiry, and any role to grant again).

### The on-demand activity control: A1 after a redeploy

A1, the control's role for its identity at `rg-<prefix>-<environment>`, is deleted with the group, so after each redeploy:

- **With `assignRoles` and `control.enabled` true,** `deploy.ps1` grants A1 again right after the Infrastructure stage (`CONTROL.ROLE.A1`), with the same function as `-GrantRole`, for A1 only.
- **Otherwise, or when that grant fails** (no Owner rights, a sign-in that needs multifactor authentication, or the role definition missing), it reports **Manual action required** with the exact `-GrantRole` command, and `DEPLOY.SUMMARY` lists it. The deployment goes on: until A1 is back, a notebook request does nothing and its job says why.

## Cost guardrails

| Guardrail | Where |
|---|---|
| Estimate against both ceilings from live retail prices, with the subscription's Defender for Cloud plans | `preflight.ps1` and `deploy.ps1` (Preflight), `start-demo.ps1`, `estimate-cost.ps1` |
| This month's actual cost plus a session against `monthlyCeilingUsd` | `start-demo.ps1` (`START.COST.ACTUAL`), `status.ps1` (`STATUS.COST`) |
| Budget with alerts at `monthlyCeilingUsd` | The template |
| Nightly auto-shutdown of both VMs | The template (DevTest Labs schedules) |
| Scheduled stop, with every profile off | `schedule-stop.yml` |
| Bastion removed after `bastionMaxHours`, and a leftover public IP at once | `bastion-cleanup.yml`, `stop-demo.ps1` |
| Expiry: destroy after `expiresOn` | `expiry.yml` |
| T3 auto-pause, and `stop-demo.ps1 -RemoveT3` for long breaks | The template, `stop-demo.ps1` |
| Park T2 between agent-focused demos | `stop-demo.ps1 -ParkT2` |

No price is hard-coded: estimates and the hourly Bastion figures come from the Azure Retail Prices API at run time ([ADR 0016](adr/0016-cost-profiles.md)).

## One click: GitHub Actions

### Set up your fork (one time, prerequisite P7)

1. Fork the repository, or push it to your own. Workflows don't run on a fork until you enable them on its **Actions** tab.
2. Create the GitHub identity: `./scripts/setup-github-oidc.ps1 -Repository <owner>/<repo> -Environment demo -ConfigureGitHub` (sign in to the GitHub CLI first with `gh auth login`; without `-ConfigureGitHub` it writes nothing to GitHub and prints the commands). It creates `rg-<prefix>-control` (outside the demo's resource group, so `destroy.ps1` never deletes it), the user-assigned identity `id-<prefix>-github`, and a federated credential that trusts `repo:<owner>/<repo>:environment:demo` with the issuer `https://token.actions.githubusercontent.com` and the audience `api://AzureADTokenExchange`, so only that repository's `demo` environment gets a token: not a fork, not a pull request. No Azure secret is created.
3. **The one admin step:** Contributor can't assign roles, so the script prints the one command an Owner, User Access Administrator, or Role Based Access Control Administrator runs: Contributor on the subscription for the identity. With `assignRoles: true` (or `-AssignRole`) and the rights, the script assigns it itself.
4. **Optional, for the T3 stage in Actions:** the identity must own the P6 group to add T1 to it, as you do locally; the script prints that command too. Without it, run `deploy.ps1 -FromStage T3` locally once after the first Actions deployment.
   With the Key Vault opt-in, the script also asks you to add the identity's principal ID to `keyVault.operatorObjectIds` (`OIDC.KEYVAULT`), so the scheduled stop can disable the stored host password.
5. **The GitHub environment:** with `-ConfigureGitHub`, the script creates `demo` with you as its required reviewer and deployments from the default branch only, and sets its four **environment secrets**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and `DBHUB_CONFIG_JSON` (your `config/demo.config.json`). They're identifiers, not credentials; they're secrets so that GitHub masks them, because a public repository's Actions logs are public ([ADR 0022](adr/0022-public-repository-and-github-actions-hardening.md)). Variables aren't read any more. After you change your configuration, run the script again to update `DBHUB_CONFIG_JSON`. `ProductKey` mode also needs the secret `DBHUB_SQL_PRODUCT_KEY`.
6. **Optional, for the schedules:** `-ScheduleEnvironment` adds `demo-schedule`, with its own federated credential, the default branch only, and no reviewers, so a scheduled run doesn't wait for an approval; only scheduled runs use it. The schedules stay off until you set `DBHUB_SCHEDULES_ENABLED` yourself.
7. **Once the repository is public:** `./scripts/setup-github-repo.ps1 -WhatIf`, then without `-WhatIf`, as an administrator: a ruleset on the default branch (pull requests, no force-push, no deletion), secret scanning with push protection, private vulnerability reporting, and Dependabot alerts; `-Template` also makes it a template repository. A setting GitHub refuses on a private repository is reported as **Manual action required**.

### Workflows

| Workflow | Runs | Does |
|---|---|---|
| `deploy.yml` | By hand | `deploy.ps1`, with `-Resume` by default |
| `demo-control.yml` | By hand, or from the live-activity notebook | Sets a profile or one bounded incident; its inputs are the [ADR 0014](adr/0014-notebook-role-and-capacity.md) contract: `environment`, `target`, `scenario`, `duration`, `concurrency`, `intensity`, `reset-before`, and `auto-cleanup`, all strings |
| `warm-up.yml` | By hand | `start-demo.ps1 -WarmUpMinutes 30`, about 45 minutes before a session |
| `destroy.yml` | By hand, with the environment's name typed again | `destroy.ps1 -Force` |
| `validate.yml` | Every pull request; by hand with `live` | The static checks; with `live`, `validate.ps1 -ConfigPath config/demo.config.json -OutputPath out/validate.jsonl`, uploaded as an artifact, failing the job on a nonzero exit code |
| `schedule-start.yml` | Weekdays 15:15 UTC | `start-demo.ps1 -WarmUpMinutes 30` |
| `schedule-stop.yml` | Daily 01:00 UTC | `stop-demo.ps1` |
| `expiry.yml` | Daily 06:30 UTC | `destroy.ps1 -Force -IfExpired` |
| `bastion-cleanup.yml` | Hourly | `stop-demo.ps1 -RemoveBastionOnly -IfExpired` |

- Every demo workflow calls `reusable-demo-run.yml`, which masks every ID with `::add-mask::`, signs in with `azure/login` and OpenID Connect (pinned by full commit SHA in `config/versions.json`), writes and checks the configuration from the `DBHUB_CONFIG_JSON` secret, runs one allowed script with its parameters splatted from JSON, and uploads `out/*.jsonl`. In GitHub Actions, the scripts write IDs as `***` in the log, the job summary, and those results ([ADR 0022](adr/0022-public-repository-and-github-actions-hardening.md)).
- Runs for one environment share the concurrency group `dbhub-demo-<environment>` without cancellation, so a deployment, a control change, and a destroy never overlap.
- **Schedules are off** until you set the repository variable `DBHUB_SCHEDULES_ENABLED` to `true`; `DBHUB_SCHEDULE_ENVIRONMENT` picks the environment of a scheduled run (`demo` by default, where each scheduled run waits for a reviewer). A run by hand always uses `demo`, and the shared runner refuses the schedule environment outside a schedule. Cron times are UTC: edit them for your demo days.

### A public repository

- Anyone can read its Actions logs and download its artifacts. The live workflows run only by hand or on a schedule, in an environment with a required reviewer, and read their identifiers from environment secrets; every ID is masked before anything prints ([ADR 0022](adr/0022-public-repository-and-github-actions-hardening.md)).
- Pull requests from forks run the static checks only, with a read-only token and no secrets.

### Private repositories

- GitHub Actions minutes are billed for private repositories beyond the plan's allowance; a full deployment runs for up to six hours, mostly waiting.
- On a private repository, environment secrets need GitHub Pro, Team, or Enterprise, and required reviewers need GitHub Enterprise ([deployments and environments](https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments)); on GitHub Free, use a public repository.
- The Deploy to Azure button needs a public raw URL, so it doesn't work from a private repository.
- The live-activity notebook's dispatch needs a token that can run workflows in the repository (P9).

## Deploy to Azure button (secondary)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMarcBushong%2Ffabric-database-hub-demo%2Fmain%2Fazuredeploy.json)

The button deploys `azuredeploy.json` from `main`, the compiled subscription-scope template, so the portal creates the resource group itself ([Microsoft Learn](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-to-azure-button)). It provisions the infrastructure only: the network, the budget, both VMs, the SQL VM registration, T3, and the auto-shutdown schedules. The portal asks for `adminPassword`, which is used once to create the VMs and isn't stored. Nothing runs on the VMs yet: finish with `./scripts/deploy.ps1 -Resume`, which sends the bundle and the runner and runs the bootstraps ([ADR 0003](adr/0003-t2-host-size-security-type-bootstrap.md#phase-6-implementation-notes-2026-10-19)). The button needs a public repository ([ADR 0001](adr/0001-iac-bicep-avm-compiled-arm.md)); in a fork, replace the owner in the URL.

## How the VMs bootstrap

1. `deploy.ps1` builds the bootstrap bundle (`vm/` and `database/`) and sends it to each VM with `Send-DemoBootstrapBundle`: SHA-256-checked chunks of 512 KiB by default, one managed Run Command at a time, each deleted once it succeeds. Nothing secret travels in a chunk, and there's no storage account or SAS.
   - It also builds the workload runner with `Publish-DemoWorkloadRunner` (the .NET SDK pinned in `config/versions.json`), then sends it the same way with `Send-DemoWorkloadRunner`: about 3.2 MB, 7 chunks.
2. `deploy.ps1` deploys the template again with the bundle's SHA-256 and chunk count, and the runner's (`Get-DemoDeploymentParameter -BootstrapBundleSha256 -BootstrapChunkCount -WorkloadRunnerSha256 -WorkloadRunnerChunkCount`). That adds a managed Run Command on each VM that runs the loader. The loader checks every chunk and the whole bundle (a mismatch stops everything), unpacks it to `C:\ProgramData\DbHubDemo`, and registers the SYSTEM task `DbHubDemo-Bootstrap`. `Wait-DemoBootstrapLoader` then reports the loader's exit code.
3. The task runs at startup and every 5 minutes until the VM is ready. It survives reboots and records progress in `state.json` and `health.json` in `C:\ProgramData\DbHubDemo`; logs are in `logs\`.
4. T1 formats its data disk (or, in `lowest-cost`, uses SQL Server's default folders on its OS disk), configures SQL Server, and creates and seeds `ContosoCare`. The T2 host installs Hyper-V, downloads the media from Microsoft (with retries that resume), builds and hardens the guest `arcsql01` (on the OS disk in `lowest-cost`, after a free-space check), and installs SQL Server according to `t2SqlInstallMode`. It then waits for Arc onboarding (`configure-arc.ps1`, below) and, in `PaygWizard` mode, for the manual step below.
5. **Workload runner** ([ADR 0010](adr/0010-workload-generator-technology.md#phase-13-delivery-and-hosting-as-built-2026-10-20)). The last step on each VM installs the runner and starts its activity host:
   - **On T1:** it assembles and verifies the runner and downloads the pinned .NET runtime (SHA-512 checked). It applies the demo objects (`110-*.sql`, `120-*.sql`) to `ContosoCare` on T1 and starts the SYSTEM task `DbHubDemo-Workload`.
   - **For T3:** after T1 joins the T3 administrators group, `deploy.ps1` runs `Enable-DemoT3Workload`, which applies the same objects to T3 and adds T3 to the task.
   - **On the T2 host:** the step waits (`WaitingForGuestSql`) until the guest's SQL Server is ready. Then it copies the runner and the runtime into the guest over PowerShell Direct and starts the same task there for T2.
   - **Activity profile:** after the install, the task runs the configured `activityProfile` (`baseline` by default) until two minutes before the next auto-shutdown. At later boots it sets a profile only when `activityProfileOnBoot` is true ([Activity profiles and boot behavior](#activity-profiles-and-boot-behavior)). While a T3 profile runs, T3's serverless database stays awake, which bills compute ([ADR 0016](adr/0016-cost-profiles.md#phase-13-note-the-workload-runner-and-t3-serverless-compute-2026-10-20)). Set `off` to keep the targets idle.
   - **Check it:** `Invoke-DemoWorkloadCommand -Config $config -Target T1 -ArgumentList 'status', '--json'` runs any runner command on a target.

## Arc onboarding: `configure-arc.ps1`

Validated live on 2026-10-20 (onboarding, with the guest isolated from IMDS and the wire server) and 2026-10-21 (configuration after the wizard step, then a fourth run with every check **Pass** and nothing changed). `deploy.ps1` runs this stage for you; run it yourself to resume or repair. Sign in first: like every script, it stops at the subscription guard and never signs in.

```powershell
./scripts/configure-arc.ps1 -WaitForHostMinutes 120
```

1. It reads the T2 host's `health.json` through a read-only Run Command. With `-WaitForHostMinutes`, it reads it again every 5 minutes until the host waits for it, needs a manual step, is ready, or failed. Without it, it reads the state once and tells you to run it again later.
2. **`ProductKey` mode only (prerequisite P10):** when the host reports `WaitingForProductKey`, the script sends the key. Pass `-ProductKey` to type it at a hidden prompt; in GitHub Actions, the `DBHUB_SQL_PRODUCT_KEY` secret supplies it.
   - The key travels only as a protected Run Command parameter, and the script removes the environment variable as soon as it has read it.
   - The host stores the key with DPAPI and deletes it after setup.
   - A key is never sent to a host that isn't waiting for one.
3. When the host reports `WaitingForArcOnboarding`, the script onboards `arcsql01`: with the least-privilege host identity `id-<prefix>-<env>-arc-onboard` whenever it's attached to `archost01` (`assignRoles: true`), and otherwise with your short-lived Azure Resource Manager token, passed only as a protected parameter ([ADR 0005](adr/0005-arc-onboarding-authentication.md#phase-7-implementation-notes-2026-10-20)). Right after, a sweep removes what's left of the token on the host and in the guest and verifies that none is ([ADR 0009](adr/0009-secrets-handling.md)). Order of onboarding:
   - **`PaygWizard`:** onboarding comes right after the SQL Server media step, before the wizard.
   - **`ProductKey` and `Developer`:** onboarding comes after the unattended install.
   - If the guest is already connected, the script only confirms it. If an Arc machine from an earlier guest build exists, it deletes that machine's SQL Server instances, then the machine, and then onboards, so there are no duplicates.
4. It checks the Azure extension for SQL Server (1.1.2504.99 or later, license type PAYG), the SQL Server instance resource, and monitoring, and fixes what it can.
   - In `PaygWizard` mode, these checks report **Manual action required** until you finish the wizard step below. Run `configure-arc.ps1` again afterward.
5. It reports `T2.ARC.CONNECTED`, `T2.ARC.NODUPLICATES`, and `T2.ARC.DISCONNECTEDDAYS`, and writes every result to `out/configure-arc.jsonl`. `-WhatIf` runs only the guard.

Options:

- `-UseHostIdentity`: require the least-privilege host identity, and fail when it isn't attached (it needs `assignRoles: true`). It's used whenever it's attached anyway.
- `-UseCallerToken`: use your token even when the host identity is attached, for example while its role assignment is repaired.
- `-Force`: onboard again even when the host isn't waiting, to repair a broken connection.
- `-SkipConfiguration`: onboard only.

## Performance monitoring: `configure-monitoring.ps1`

Validated live: T1 on 2026-10-20 (`T1.SQLVM.MONITORING` **Pass**) and T2 on 2026-10-21 (`T2.ARC.MONITORING` **Pass**, with T2 telemetry about 7 minutes later).

```powershell
./scripts/configure-monitoring.ps1 -Target T1, T2 -WaitMinutes 15
```

- **T1:** merges the `DatabaseWatcheronAzureVM` feature flag into the SQL IaaS Agent extension's existing public settings and keeps every other setting. It then waits until the extension's status shows `DatabaseMonitorArcPlugin` with `"State":"Running"` and `"MetricsUploadStatus":"OK"`, which takes 3 to 15 minutes ([Microsoft Learn](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)).
  - After a template deployment, the extension shows `Updating` for about 10 minutes (Phase 13 live finding); with `-WaitMinutes` that's a wait, and without it a **Warning**, not a **Fail**. The monitoring flag survives the redeployment. `deploy.ps1` (the Monitoring stage) and `start-demo.ps1` (after recreating T3) run this check with a 20-minute wait.
  - A template run can also leave the plugin `NotRunning`, which waiting doesn't change (live, 2026-10-27). Since Phase 25d, when the Monitoring stage's wait ends with the extension Succeeded, the flag set, and the plugin not Running, `deploy.ps1` restarts the SQL IaaS Agent service, as `start-demo.ps1` does after a start, and reports `DEPLOY.T1.MONITORING` (live: Running with uploads OK 166 seconds after the restart).
  - It also reports `T1.SQLVM.ASSOCIATEDSERVICES`, read-only: **Pass** when unified inventory lists only the engine for T1, and a **Warning** while it still lists the image's Analysis Services or Integration Services as SQL Server instances. T1's `AssociatedServices` bootstrap step stops, disables, and uninstalls them (live, 2026-10-21); the demo uses the engine.
- **T2:** sets `monitoring.enabled` on the SQL Server instance resource. In `Developer` mode, it reports **Not supported**.
- **T3:** its monitoring setting is the database's extended property `MS_EnablePerformanceMonitoringPreview`, which the T3 stage of `deploy.ps1` sets from T1. `validate.ps1 -Area T3` checks it (`T3.PROPERTY`); this script reports **Not selected** for T3.

## The `PaygWizard` manual step (validated live 2026-10-21)

**Since Phase 28, `deploy.ps1` guides this step** ([the guided stop](#the-guided-stop-paygwizard)): it creates Bastion, hands over the host password, opens the portal page, and the guest signs itself in and opens setup pre-filled, so only the **Edition** page's two choices, **Use Azure Login**, and **Install** are left. The host's own message (in `health.json`, the console, and the status page) gives these steps. The steps below are the by-hand path, which still works: for example when the guest's automatic sign-in didn't open setup after 3 tries (the host then says to sign in as Administrator and run `C:\DbHubDemo\setup\Start-GuidedSetup.ps1`, which opens the same pre-filled setup), or on a host whose bundle predates Phase 28.

When T2 reports **Manual action required**, `health.json` on the host lists these steps, with the drive letter of the mounted SQL Server media:

1. Run `./scripts/start-demo.ps1 -Interactive -ResetAdminPassword` to create Bastion (about 8 minutes) and get a one-time host password on your clipboard (or, with the [Key Vault opt-in](#opt-in-the-password-in-key-vault-instead-of-the-clipboard), in the vault).
2. In the Azure portal, connect to `archost01` with Bastion.
3. On the host, in an elevated PowerShell window, run `C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1` to copy the guest password to the clipboard. It never displays the password; run it again with `-Clear` when you're done.
4. Open Hyper-V Manager and connect to `arcsql01`. At the sign-in screen, select **Clipboard** > **Type clipboard text** to enter the password for `Administrator`.
5. In the guest, run `setup.exe` from the SQL Server media drive. Select **Installation** > **New SQL Server standalone installation**.
6. On the **Edition** page, select **Use pay-as-you-go billing through Microsoft Azure**, then **Standard**.
7. On the **Azure Extension for SQL Server** page, select **Use Azure Login** and sign in with your own Azure account. Pay-as-you-go needs this page: the extension can't be cleared, and **Next** without a sign-in fails. The subscription, resource group, and region are filled in from the existing Arc connection and can't be changed. Never enter a service principal secret. If Windows asks you to add sites to the Trusted sites zone, follow your organization's rules ([installation wizard, Azure Extension for SQL Server](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup)).
   - If the sign-in window stays blank, the WebView2 runtime is missing in the guest. The host's `GuestWebView2` step installs it before this step; Windows Server 2022 doesn't include it.
   - To install it by hand, for example on a host whose bundle predates that step, use the Evergreen **standalone** x64 installer from `https://go.microsoft.com/fwlink/?linkid=2124701` (HTTPS): check that `Get-AuthenticodeSignature` reports `Valid` with a Microsoft Corporation signer, then run it with `/silent /install`. The Evergreen bootstrapper hangs here, because it downloads over HTTP (port 80), which the T2 network security group blocks ([WebView2 distribution](https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution)).
   - If sign-in says "There was an issue looking up your account", select **Next** to try again. It worked on the second try in the live run.
8. Select **Database Engine Services**, and leave **Azure Extension for SQL Server** selected. Keep the default instance (`MSSQLSERVER`).
9. Choose **Windows authentication mode**, select **Add Current User** as a SQL Server administrator, and install.
10. Close setup. The host detects the Standard instance within about 5 minutes and continues on its own:
    - Its `GuestSignInCleanup` step removes the sign-in data that setup leaves on the VM and verifies that none remains; the build stops if any remains. The step waits while setup or the Installation Center still runs, so close both.
    - It turns Internet Explorer Enhanced Security Configuration back on if you turned it off; leave it on, because the sign-in doesn't need it off.
    - Then Query Store, file growth caps, and the `ContosoCare` seed.
11. Run `./scripts/configure-arc.ps1` to converge the SQL Server extension (license type, monitoring) once Azure finishes creating it, then `./scripts/configure-monitoring.ps1 -Target T2`. Or run `./scripts/deploy.ps1 -Resume`: its T2 stage does the same, then sets T2's activity profile.
12. Run `./scripts/stop-demo.ps1 -RemoveBastionOnly`: it deletes Bastion and its public IP and rotates the host password. The hourly `bastion-cleanup.yml` does the same after `bastionMaxHours`.

The setup wizard deploys the `WindowsAgent.SqlServer` extension to `arcsql01` through Azure; in the live run it stayed in **Creating** long after setup finished, because its downloads failed intermittently inside the guest (R72). Run `configure-arc.ps1` again once it's there.

## The T2 golden snapshot: `capture-t2-golden.ps1` and `test-t2-golden.ps1`

The setup-wizard step for pay-as-you-go SQL Server can't be scripted, so Phase 20 keeps a finished T2 host as an incremental snapshot of `archost01-osdisk` in `rg-<prefix>-golden` ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)):

```powershell
./scripts/capture-t2-golden.ps1          # preconditions, the guest air-gapped, the host stopped, then the snapshot (DenyAll) and a disk check
./scripts/test-t2-golden.ps1 -Onboard    # a quarantined copy: no outbound traffic, the Arc identity reset, SQL Server Standard, then a fresh onboarding with PAYG and monitoring
```

- A snapshot is used only after `test-t2-golden.ps1` tags it boot-verified; older snapshots of the prefix are deleted only then.
- The guest's 180-day evaluation runs inside it: `status.ps1` (`STATUS.T2.GOLDEN`) and preflight (`PREFLIGHT.T2.SOURCE`) warn at 30 and at 7 days left. After that, capture again from a fresh build and the wizard step.
- It's priced from the Retail Prices API on the OS disk's provisioned size ([cost management](cost-management.md#the-t2-golden-snapshot-phase-20)); `destroy.ps1 -IncludeGolden` deletes it.
- Live (2026-10-22): captured from the finished host, proven in quarantine (4,492 seconds, the extension download included), and restored by the redeploy above.
- **Sign-in data (ADR 0009):** the capture removes the sign-in data left on the host and in the guest and captures nothing unless a fresh scan finds none (`GOLDEN.CAPTURE.SIGNIN`); the test scans each copy too (`GOLDEN.TEST.SIGNIN`). `capture-t2-golden.ps1 -WipeFreeSpace` also overwrites the guest's and the host's free space with zeros, compacts the guest's disk, and trims both volumes, so nothing deleted survives in free space and the snapshot keeps no zeroed block; it needs 45 GB free on the host's `C:` (`-MinHostFreeGB`) and adds about an hour. With `assignRoles: true`, `test-t2-golden.ps1 -Onboard` onboards with the test group's own host identity, not your token. Both scripts keep your PC and its display awake until they finish.

## Run Commands, policies, and deallocated VMs

Every VM-side action goes through Run Command, which has three limits that the scripts handle for you:

- **A policy-installed extension blocks it for a while.** Tenant policies install Guest Configuration and Defender for SQL after a deployment, and update `MDE.Windows` later; live, an `MDE.Windows` update blocked Run Commands on `archost01` for about 10 minutes (R49). A **Conflict** is retried with waits of 10, 20, 40, 80, and then 120 seconds, about 12.5 minutes in all, and the log names the likely cause.
- **It needs a running VM.** On a deallocated VM, Azure answers `OperationNotAllowed`, which isn't retried: the message says to start the VM first (`start-demo.ps1`). A password rotation then reports **Manual action required**, and a profile change on a VM that isn't running reports **Not selected**, because nothing runs there.
- **A Run Command created again right after it was deleted can report the previous run** instead of running its script (live, 2026-10-21). `Invoke-DemoVmRunCommand` ignores a result whose execution started before the request, tries once more after 60 seconds, and then reports it as stale, so it never counts as the new script's result (Phase 7).
- **Deletes that Azure doesn't finish don't hold a run up (Phase 28).** Chunk deletes aren't waited for, the VM's extensions settle before its artifacts and its loader, a watchdog restarts a stuck VM once, and a stall sends the rest one at a time ([Run Commands that don't stall a run](#run-commands-that-dont-stall-a-run-phase-28)).

## Expected duration

Measured on 2026-10-20 in `westus3`, unless marked as an estimate; the Phase 20 rows on 2026-10-22, and Phase 22's on 2026-10-23:

| Step | Duration |
|---|---|
| Template deployment (both VMs exist) | About 3 minutes (2 minutes 31 seconds in Phase 20's second deploy) |
| Bootstrap bundle (about 145 KB, 1 chunk) | About 40–60 seconds per VM (55–105 seconds on 2026-10-22) |
| Workload runner (about 3.2 MB, 7 chunks) | About 5 minutes per VM one chunk at a time (317 seconds on `sqlvm01`); 169–246 seconds with the chunks in parallel (Phase 20) |
| T1's `WorkloadRunner` step on a running T1, after the loader | About 20 minutes, including two retries while Defender scanned the extracted runtime (R189, since fixed) |
| SQL IaaS extension `Updating` after a redeployment | About 10 minutes |
| On-demand Bastion | About 8 minutes |
| First deployment end to end | About 2–3 hours in `PaygWizard` mode, with a person needed about 60 to 90 minutes after the start for about 10 minutes, and about 1.5–2.5 hours in `ProductKey` or `Developer` mode (Phase 28 estimates from documented step times; not measured yet): mostly the T2 guest build, including about 6.2 GB of media downloads ([what to expect](#one-command-one-guided-stop-phase-28)) |
| Redeploy after `destroy.ps1`, T2 from the golden snapshot (parallel tracks) | **63.7 minutes** end to end with Phase 22's overlaps (2026-10-23): T1 and T3 ready at +26.8 minutes, the Fabric track at +17.1 (on an F4), and T2 at +61.7, after about 29.5 minutes of the SQL Server extension's download (R72); about 35.5 minutes without R72, an estimate ([faster redeploy](#faster-redeploy-phase-22)). Before them, **38.8 minutes** (2026-10-22): T1 and T3 ready at +36.3 minutes, T2 at +37.7, the Fabric track about 2.4 minutes ([parallel tracks](#parallel-tracks-phase-20)) |
| A second `deploy.ps1` on a deployed environment | 19.2 minutes with nothing changed after Phase 22's redeploy (2026-10-23: nothing sent again, T2 already connected); 21.8 minutes with nothing changed (G9b, 2026-10-22), 25.9 minutes with changed code (G9), and 32.3 minutes when T1's monitoring plugin had to be restarted first (G9c). A run skips a bundle or runner that a VM already has (the deployment state records each SHA-256); G9 and G9b sent both again, about 4 to 5 minutes per VM, because each checkout built them differently (fixed for the runner; the bundle differed only by a working copy's line endings) |
| `destroy.ps1` | 1,102 seconds for `rg-dbhub-demo` (2026-10-22); 1,127 and 1,191 seconds (2026-10-23) |
| `stop-demo.ps1` | About 6 minutes (338 to 371 seconds in five runs on 2026-10-22): the guard, the three activity profiles off, the guest's clean shutdown (30 seconds), and both VMs deallocated (about 40–60 seconds) |
| `start-demo.ps1` (a repeat session) | **About 8 minutes** (481 seconds, 2026-10-22, with every fix): both VMs at once, T1's SQL IaaS Agent restarted because its monitoring plugin hadn't come back (about 2.5 minutes, `START.T1.MONITORING`), T3 resumed from its pause, the three activity profiles set, and the activity running in the background. Earlier attempts took 444 and 391 seconds but left `sqlvm01` reported missing, T1's profile unset, or T1 without telemetry |

Both VMs can receive chunks at the same time, but never send to the same VM twice at once: a send replaces that VM's chunk Run Commands. The tracks send a VM's bundle and runner in one call (`Send-DemoChunkSet`), one wave of chunks.
