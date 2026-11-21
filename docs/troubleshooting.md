# Troubleshooting

Start here when a script reports anything other than **Pass**: find the check ID in the index, then its row. Each **Fail**, **Warning**, and **Manual action required** also prints its own fix. In front of an audience, use the walkthrough's [recovery playbook](demo-walkthrough.md#recovery-playbook) instead.

## Find your check ID

A more specific row wins over a prefix.

| Check ID, or what you see | Section |
|---|---|
| The subscription guard (`PREFLIGHT.GUARD.CONTEXT`) | [The guard stops a script](#the-guard-stops-a-script) |
| `INIT.*` | [First run](#first-run-the-configuration-init) |
| `PREFLIGHT.*`, `DEPLOY.DOTNETSDK` | [Preflight](#preflight) |
| `DEPLOY.SELFUPDATE` | [deploy.ps1's update from GitHub](#deployps1s-update-from-github-deployselfupdate-2026-11-09) |
| `DEPLOY.TEMPLATE`, `DEPLOY.TRACK.<track>`, `DEPLOY.DISKS.DRIFT`, `DEPLOY.ARTIFACTS.CHANGED*`, `DEPLOY.ARTIFACTS.BUILD`, `INFRA.BOOTSTRAP.LOADER_<VM>`, `DEPLOY.FABRIC.SHARED`, `SECURITY.SECRETSCAN.OUTPUT` | [Other deployment problems](#other-deployment-problems) |
| `DEPLOY.VMSTART`, `DEPLOY.T2.WAIT`, `DEPLOY.T2.GUIDEDLEFTOVER`; a slow run; "Stopped, not done" | [A first run that's slow or doesn't finish](#a-first-run-thats-slow-or-doesnt-finish) |
| `DEPLOY.WATCHDOG_<VM>`, `DEPLOY.EXTENSIONS_<VM>`, `DEPLOY.RUNCOMMAND.STUCK_<VM>`, `DEPLOY.ARTIFACTS.CLEANUP_<VM>`, `DEPLOY.ARTIFACTS.STALL_<VM>`, `STATUS.RUNCOMMANDS` | [Run Commands stuck in Deleting](#run-commands-stuck-in-deleting) |
| `DEPLOY.T2.HOSTREBUILD`, `DEPLOY.T2.HOSTMISSING`, `VMStartTimedOut`, a VM agent that isn't Ready | [A host's VM agent that isn't Ready](#a-hosts-vm-agent-that-isnt-ready) |
| `T1.*`, `DEPLOY.T1.*`, `START.T1.MONITORING`, `TELEMETRY.T1` | [T1](#t1) |
| `DEPLOY.T2.*`, `PREFLIGHT.T2.MODE`, `STATUS.T2.IMAGE`, `STATUS.T2.DISKSPACE`, a T2 host step (`GuestImage`, ...) | [T2: Arc Jumpstart's image](#t2-arc-jumpstarts-image-jumpstartimage) |
| `SECURITY.SIGNIN.<VM>`, `STATUS.T2.AUTOSIGNIN`, `GOLDEN.CAPTURE.SIGNIN`, `T2.ARC.SQLEXTENSION` | [T2: sign-in data and the Arc SQL extension](#t2-sign-in-data-and-the-arc-sql-extension) |
| Other `T2.*` results, `GOLDEN.*` | [T2: Arc and the guest](#t2-arc-and-the-guest) |
| `DEPLOY.T2.GUESTRETRY`, `DEPLOY.T2.GUESTRESTART`, "The Hyper-V socket target process has ended" | [PowerShell Direct into arcsql01 breaks](#powershell-direct-into-arcsql01-breaks) |
| `T3.*` | [T3](#t3) |
| `HUB.AGENT.T3`, `DESTROY.HUB.AGENT.T3`; anything in Database Hub's **Database agent settings**: "Database agent changes couldn't be saved", look-alike `ContosoCare` rows, "temporarily limited", no PostgreSQL or Cosmos DB, no issue on T3 | [Database agent settings](#database-agent-settings) |
| `DEPLOY.T4.*`, `PREFLIGHT.T4.*`, `T4.*`, `STATUS.T4.SIZE`, `METRICS.T4` | [T4](#t4) |
| Any `.T4.REPLICA` result, `CONTROL.T4`, `STOP.T4.HISTORY.PENDING`, `FABRIC.T4.HISTORY` | [T4's read replica](#t4s-read-replica) |
| Any T5 result (`T5.*`, `DEPLOY.T5*`, `START.T5*`, `STOP.T5*`, `METRICS.T5`, `WORKLOAD.T5.WARMUP`, ...) | [T5](#t5-azure-cosmos-db) |
| `TELEMETRY.<target>`, `HUB.*`, `FABRIC.P4.HUBSETTING`; Copilot or Database Agents | [Database Hub and telemetry](#database-hub-and-telemetry) |
| Other `FABRIC.*` results, `DEPLOY.FABRIC.HISTORY` | [Fabric notebooks](#fabric-notebooks) |
| `FABRIC.APP.*`, `DEPLOY.FABRIC.APPSIGNIN`, "Page not accessible directly" | [The Insights app](#the-insights-app-fabric-app) |
| `ASK.*`, or a message in the chat's dock | [Ask](#ask-the-copilot-chat-in-the-insights-app-2026-11-18) |
| `CONTROL.*`, `DEPLOY.CONTROL`, `START.CONTROL.*`, `STATUS.CONTROL`; Run all's output | [Run all and the session control](#the-on-demand-activity-control) |
| Other `START.*`, `STOP.*`, and `STATUS.*` results, `WORKLOAD.*` | [Workload and scenarios](#workload-and-scenarios) |
| `STATUS.BASTION`, `COST.BASTION`, `STOP.HOSTPASSWORD`, `DEPLOY.T2.HOSTPASSWORD`, `START.CLIPBOARD` | [Bastion, the host password, and Key Vault](#bastion-the-host-password-and-key-vault) |
| `SAFETYSTOP.*`, `STATUS.SAFETYSTOP`, `DEPLOY.COST.T4RESTART`, the `.NIGHTLYSTOP` results | [The nightly safety stop](#the-nightly-safety-stop) |
| `STATUS.COST`, `STATUS.T4`, `STOP.T4.STOP`; a budget alert | [Cost](#cost) |
| `DESTROY.*`, `TEARDOWN.RESIDUAL.*` | [Destroy and the residual check](#destroy-and-the-residual-check) |
| `DEPLOY.T3.SCALE`, `DEPLOY.T4.MISSING`, `DEPLOY.T5.MISSING`, `DEPLOY.CONTROL.ON` | **Pass** notes on what a run did in an existing environment: nothing to do ([update an existing environment](deployment.md#update-an-existing-environment)) |

## Read the result first

Every script prints one result per check and writes it as a JSON line to `out/<script>.jsonl` ([ADR 0012](adr/0012-validation-model.md)).

| Status | Meaning | What to do |
|---|---|---|
| **Pass** | A functional check proved it works; deployment success alone never counts | Nothing |
| **Fail** | Broken or missing | Fix what the message names, then run the same script again: every stage is idempotent |
| **Warning** | Works with a caveat, or can't be checked now, for example on a deallocated VM | Read the message; most clear after `start-demo.ps1` |
| **Manual action required** | No supported automation exists, or a person must decide | Do what the message says. An item that **DONE** lists under **Please confirm** needs nothing else; for any other, run the same script again, usually `./scripts/deploy.ps1` |
| **Not supported** | The chosen configuration can't do it | Pick another option only if you need it |
| **Not selected** | Turned off, or doesn't apply | Nothing |

- **`deploy.ps1` ends with one banner:** **DONE**, or **NOT DONE** with the next action and the exact command (with your `-ConfigPath`), usually `./scripts/deploy.ps1` again, which continues where it stopped; `DEPLOY.SUMMARY` lists every open manual item. What only a person can confirm never makes a run **NOT DONE**: **DONE** lists it under **Please confirm** (the Database Hub tenant setting when unread, a Trial capacity, presenters' roles, the Insights app's browser check, and selecting T3 for Database Agents, `HUB.AGENT.T3`). Nor does the Insights app: it shows as `Failed (doesn't block DONE)` with its fix ([below](#the-insights-app-fabric-app)).
- **A clean first deployment isn't all Pass:** **Warnings** such as `T4.MAXCONNECTIONS`, `DEPLOY.ARTIFACTS.CLEANUP_<VM>`, `PREFLIGHT.T3.FREEOFFER`, `T3.FREEOFFER`, `DEPLOY.T5.FREETIER`, and `FABRIC.SEMANTICMODEL.MEASURES` need nothing; for a Contributor, so are `SAFETYSTOP.ROLE`, `CONTROL.ROLE.*`, and `PREFLIGHT.COST.T4RESTART`, and **DONE** prints `./scripts/grant-safety-stop.ps1` for an Owner to run once ([what a clean first deployment shows](deployment.md#what-a-clean-first-deployment-shows-2026-11-06)).
- `./scripts/status.ps1` is read-only and shows every target; `-Watch` follows a deployment. `./scripts/validate.ps1` runs the whole catalog; `-Area` or `-Target` narrows it.
- **Exit codes:** 0 when nothing failed, 1 for any **Fail**; with `-TreatManualAsError`, **Manual action required** returns 2 (1 from `validate.ps1`). `deploy.ps1`: 0 for **DONE**, 1 for **NOT DONE** with a **Fail**, otherwise 2; in GitHub Actions it uses the other scripts' codes.
- **A run that doesn't finish:** `./scripts/collect-diagnostics.ps1` zips its results, progress, transcripts, and saved instance views, redacted, for a **Deployment problem** issue ([deployment](deployment.md#diagnostics-collect-diagnosticsps1)).

## Sign-in and the subscription guard

Every script runs the subscription guard (`Assert-DemoAzContext`, check `PREFLIGHT.GUARD.CONTEXT`) before anything is written. Every Azure CLI call, token requests included, names the configured subscription with `--subscription`, and the guard checks its tenant and account, so **you don't need to change your Azure CLI default subscription, and the scripts never change it**, or sign in or out for you ([prerequisites](prerequisites.md#target-subscription-configuration-the-subscription-guard)).

### The guard stops a script

Its message names the failed check ([deployment](deployment.md#before-you-start)):

| Check | Fix |
|---|---|
| `account`: no Azure CLI sign-in for the subscription, one in another tenant, or another account than `azureAccount` | `az login --tenant <tenantId>` yourself, as the account that runs the demo, and press Enter at the subscription selector for no changes ([sign in at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)); or correct `azureAccount` in `config/demo.config.json` |
| `canary.arm`, `canary.armRest`: Azure Resource Manager refused the subscription | Check the account's role: Contributor is the minimum (P1) |
| `canary.armToken`, `canary.fabricToken`, `canary.kustoToken`, `canary.graphToken`, `canary.graphOrganization`: no token without interaction, or one for another tenant or identity | `az login --tenant <tenantId>` again |
| A **Warning** naming a claims challenge (`graphChallenge`): Microsoft Graph refused the token under Continuous Access Evaluation; `PREFLIGHT.P6.GROUP` fails with it | `az login --tenant <tenantId>`, then the script again ([Continuous Access Evaluation](https://learn.microsoft.com/entra/identity-platform/app-resilience-continuous-access-evaluation)) |
| A **Warning**, not a **Fail**: `azureAccount` isn't set | Set it to the account the evidence names |
| Every script stopped at once while you changed nothing: another tool sharing your Azure CLI profile signed out or in | Sign in again; never work around the guard. On a shared machine, isolate the demo's sign-in (next) |

### Optional: isolate the demo's Azure CLI sign-in on a shared machine

The Azure CLI keeps its configuration and token cache in the folder `AZURE_CONFIG_DIR` names, `%USERPROFILE%\.azure` by default ([Azure CLI configuration](https://learn.microsoft.com/cli/azure/azure-cli-configuration)). Give the demo its own ([prerequisites](prerequisites.md#optional-a-separate-azure-cli-profile)):

```powershell
$env:AZURE_CONFIG_DIR = Join-Path $HOME '.azure-dbhub-demo'   # this PowerShell session only
az login --tenant <tenantId>                                  # once, as the account that runs the demo
./scripts/status.ps1
```

Set it in every session you use for the demo; the scripts never set it. It doesn't apply to Azure Cloud Shell or GitHub Actions, which sign in on their own.

## First run: the configuration (`INIT.*`)

With no configuration file, `deploy.ps1` writes one first, as `./scripts/init.ps1 -CreateAdminGroup` does ([first run](deployment.md#first-run-initps1)); an `INIT.*` check that needs you ends the run **NOT DONE** before anything is deployed.

| Result | Fix |
|---|---|
| `INIT.EXISTING` **Warning**: the environment "exists ..., and it's yours ..., so the configuration is written from what's deployed", listing the settings that got their defaults and whether the notebooks are republished (`fabric.importNotebooks`) | Set any listed setting your old configuration had, then `./scripts/deploy.ps1`; it changes nothing you didn't ask for |
| `INIT.EXISTING` **Warning**: it "isn't yours ... the configuration names a new environment, with the prefix ..." | Nothing, when that's what you want. If it's yours after all: `./scripts/destroy.ps1`, `./scripts/init.ps1 -Force -Prefix <prefix> -OwnerEmail <its budget address>`, then `./scripts/deploy.ps1` |
| `INIT.EXISTING` **Manual action required**: not yours, and "the prefixes after it are taken too" | `./scripts/init.ps1 -Prefix <an unused prefix>`, then `./scripts/deploy.ps1` |
| `INIT.EXISTING` **Fail**: it "couldn't be checked" | Again in a few minutes; then check that you can read resource groups, deployments, role assignments, and Microsoft Graph's groups |
| `INIT.P6.GROUP` **Manual action required**: no group to administer T3 and T4 could be created or taken | Usually `./scripts/init.ps1 -Force -CreateAdminGroup` (`-AdminGroupName <name>`), or `-AdminGroupObjectId <id>` for a group you own; where only administrators create groups, an Entra administrator creates one with you as its owner. Then `./scripts/deploy.ps1` |
| `INIT.FABRIC.CAPACITY` **Manual action required**: no F or Trial capacity you can assign, none with that name, or several and no way to ask | `./scripts/init.ps1 -Force -CapacityName <name>`, then `./scripts/deploy.ps1`; with none, a capacity administrator adds you, or start a Fabric trial (the scripts never create a capacity) |

## Preflight

| Result | Fix |
|---|---|
| `DEPLOY.DOTNETSDK` **Fail**: "The .NET SDK `<version>` that the workload runner needs couldn't be installed for you": on Windows `deploy.ps1` installs it into `%LOCALAPPDATA%\DbHubDemo\dotnet`, and the message says what stopped it (a blocked download from `builds.dotnet.microsoft.com`, a hash or signature mismatch, a full disk: it needs about 1.1 GB, another run's install); elsewhere it installs nothing | `./scripts/deploy.ps1` again; or install the SDK yourself (the remediation's `winget` command), or `-SkipRunner`, which builds no runner (activity profiles **Not selected**). `DBHUB_DOTNET_INSTALL_ROOT` picks another folder; deleting `%LOCALAPPDATA%\DbHubDemo\dotnet` removes it |
| `PREFLIGHT.TOOLS.DOTNETSDK`: **Pass** on Windows in `deploy.ps1`; a **Warning** from `preflight.ps1` alone; elsewhere a **Fail**: the `dotnet` first on `PATH` has only runtimes (often `C:\Program Files\dotnet`) or an SDK older than `workload-generator/global.json` accepts | On Windows, `./scripts/deploy.ps1` installs it. Or `winget install Microsoft.DotNet.SDK.10` (or `winget upgrade`), [the installer](https://dotnet.microsoft.com/download/dotnet/10.0), or the dev container; or put the folder the message names (`DOTNET_ROOT`, `%LOCALAPPDATA%\Microsoft\dotnet`, `~/.dotnet`) first on `PATH`; or `-SkipRunner` |
| `PREFLIGHT.P1.CONTRIBUTOR` **Fail** | A subscription Owner assigns you Contributor (P1) |
| `PREFLIGHT.P2.PROVIDERS`: a provider is still registering | Run it again in a few minutes; preflight registers them |
| `PREFLIGHT.P3.QUOTA`, `.REGION`, `.ZONE`, `.PREMIUMV2`: no quota, or a size or disk isn't offered | A size or region preflight suggests, or a quota increase |
| `PREFLIGHT.P3.SECURITYTYPE_T1`, `_T2HOST` **Warning** | Nothing: T1 uses Trusted Launch when its image can; the T2 host stays Standard ([ADR 0003](adr/0003-t2-host-size-security-type-bootstrap.md)) |
| `PREFLIGHT.POLICY.SQLPUBLIC`: a policy turns off SQL public access | `networkMode` `auto` makes T3 private; an explicit `public` fails, so use `auto` or `private` ([ADR 0007](adr/0007-networking-modes-and-egress.md)) |
| `PREFLIGHT.POLICY.INVENTORY` **Warning**: some definitions couldn't be read (or "... not read after the network error") | Management-group definitions may need Reader; `auto` then goes private. `-SkipPolicyInventory` skips the read (3–10 minutes in a large tenant); after a network error, run it again |
| `PREFLIGHT.POLICY.*` **Not selected** at the start (`private` runs the inventory beside the deployment) | Nothing: filled in at the end, or a **Warning** read again next run |
| `PREFLIGHT.POLICY.WHATIF` **Fail**: the what-if was denied | Change the option the named policy denies, or ask for an exemption; the demo never changes a policy |
| `PREFLIGHT.T4.CAPABILITY` or `PREFLIGHT.T4.SKU` **Warning** naming `Standard_D4ads_v5` or `Standard_D2ds_v5`: the region doesn't list T4's size (`az postgres flexible-server list-skus`), or Azure refused it before | Nothing: `deploy.ps1` falls back ([T4](#t4)) |
| `PREFLIGHT.T4.SKU` **Fail**: the region doesn't offer T4's size with its PostgreSQL version | Another region, or a `t4SkuName` the region offers |
| `PREFLIGHT.T4.FALLBACK` **Warning**: "would still create T4, ... though its cost check doesn't pass" (`Standard_D2ds_v5` all month over a ceiling) | Nothing unless Azure refuses the 4-vCore sizes; to stay within your ceilings then, raise the one named ([the cost check](cost-management.md#the-general-purpose-fallbacks-cost-check-phase-28-follow-up)) |
| `PREFLIGHT.T4.FALLBACK` **Warning** with `skipReason` `Price`: its price "couldn't be read" | Nothing: the other `PREFLIGHT.COST.*` results stand, and `deploy.ps1` prices it again before it creates anything |
| `PREFLIGHT.T3.FREEOFFER` **Warning**: no free offer (10 free databases already, or free ones in another region; [free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer)) | Nothing: T3 is regular serverless, priced so |
| `PREFLIGHT.P6.GROUP` **Warning**: you don't own T3's administrators' group; **Fail**: it's gone, or Graph refused your sign-in | Own it (P6), or the fallback in [permissions](permissions.md#t3-administration-options); a missing group needs a new `t3AdminGroupObjectId`; a refused sign-in, `az login` |
| `PREFLIGHT.COST.MONTHLY` **Fail**: a light-use month with T4's 7-day restart is above `monthlyCeilingUsd` | Raise the ceiling to the amount named, or a cheaper option ([cost management](cost-management.md#at-a-glance)); a Contributor's first deployment usually needs `PREFLIGHT.COST.T4RESTART`'s fix. A **Warning** when only a size you didn't choose puts it over: a fallback for your `t4SkuName`, or T4's default with a ceiling of exactly 250 (`init.ps1`'s value from 2026-10-27 to 2026-11-04), or when only T5's container, priced all month because nothing automatic deletes it (a Contributor's environment), puts it over: an Owner runs `./scripts/grant-safety-stop.ps1` once, or set `t5Enabled` to `false`, and run `./scripts/stop-demo.ps1` after each session until then. Keeping it is fine: the budget alerts, and `start-demo.ps1` stops starting the demo once the month's actual cost reaches it |
| `PREFLIGHT.COST.T4RESTART` or `START.COST.T4RESTART` **Warning**: no safety stop fully in place, "so the monthly ceiling counts it running for the rest of the month" | An Owner runs `./scripts/grant-safety-stop.ps1` once, or `./scripts/deploy.ps1` sets the stop up again; then each restart counts as about a day |
| `PREFLIGHT.COST.SESSION` **Warning**: a session is above `sessionCeilingUsd` | Shorter sessions, or `-ParkT2` |
| `PREFLIGHT.COST.DEFENDER` **Warning**: Defender plans unread (the guard didn't pass) | Sign in and run it again |
| `PREFLIGHT.FABRIC.APPSETTINGS` **Warning**: "Fabric Apps (preview)" (P12) or "Dataset Execute Queries REST API" (P13) is off, or unread | Nothing when they're on; otherwise a Fabric administrator turns them on. Until then the app isn't created or can't query, and the run still ends **DONE** |

## Deployment

`./scripts/deploy.ps1` is the one command, for a new environment and an existing one ([deployment](deployment.md#one-command-one-guided-stop-phase-28)). After **NOT DONE**, run the command its banner prints: it continues where it stopped, starts stopped VMs, and resends a changed bootstrap bundle or workload runner.

### deploy.ps1's update from GitHub (`DEPLOY.SELFUPDATE`, 2026-11-09)

First, `deploy.ps1` checks whether this copy is behind GitHub's `main`. A clean `main` that tracks `origin/main` fast-forwards, and the run restarts with the new code ([updates from GitHub](deployment.md#updates-from-github-2026-11-09)). Otherwise it's a **Warning**, and the run goes on with the code it has; to take the update, end the run (Ctrl+C), run the Warning's command, then `./scripts/deploy.ps1` again.

| The Warning says | Fix |
|---|---|
| "tracked files have local changes (...)" | `git stash; git pull --ff-only; git stash pop`, or commit first (`config/` and `out/` never count) |
| "on branch ..., not main" or "on a detached HEAD" | `git switch main; git pull --ff-only` |
| "its main tracks ..., not origin/main" | `git branch --set-upstream-to=origin/main main; git pull --ff-only` |
| "local commit(s) that GitHub's main doesn't" | `git merge origin/main` keeps yours; `git reset --hard origin/main` discards them |
| "GitHub couldn't be reached ..." (offline, a proxy, over 20 seconds, or a fork that needs a credential) | `git pull --ff-only` once GitHub can be reached |
| "Git isn't installed ..." in a git checkout | Install [Git](https://git-scm.com/downloads), then `git pull --ff-only` |
| "... this folder isn't a git checkout" (a zip) | `git clone https://github.com/MarcBushong/fabric-database-hub-demo.git`, then bring the configuration it names (or pass the same `-ConfigPath`) |
| "-WhatIf changes nothing, this checkout included" | A run without `-WhatIf` updates it |
| "the fast-forward failed (...)" | `git status`, move the untracked file in the way, then `git pull --ff-only` |

**Which git:** the one on `PATH`, else Git for Windows (`%ProgramFiles%\Git\cmd`, `%ProgramFiles(x86)%\Git\cmd`, `%LOCALAPPDATA%\Programs\Git\cmd`), GitHub Desktop's newest `%LOCALAPPDATA%\GitHubDesktop\app-*`, or Visual Studio's (via `vswhere`); elsewhere `/usr/bin/git`, `/usr/local/bin/git`, `/opt/homebrew/bin/git`. It never changes `PATH` and says "It used the git at ..., which isn't on PATH.". **Off:** `-NoSelfUpdate` or `DBHUB_NO_SELF_UPDATE=1`; CI skips it. After "This copy was updated, but deploy.ps1 couldn't start again", just run `./scripts/deploy.ps1` again.

### Other deployment problems

| Result | Fix |
|---|---|
| A template deployment is denied by a tenant policy, which the error names | Change the option it denies (preflight's what-if usually catches it) |
| `DEPLOY.TEMPLATE` **Fail**, naming the innermost error ([find error codes](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/find-error-code)) | Fix it, then `./scripts/deploy.ps1` |
| `DEPLOY.TRACK.<track>` **Fail**: a step's own result says why, or the track's process "ended without a summary", or "the subscription guard failed in its process, so nothing ran" | Fix what it names (for the guard, your Azure CLI sign-in), then `./scripts/deploy.ps1`: the track continues after its last finished step |
| `DEPLOY.TEMPLATE` **Fail**: "budgets `budget-<prefix>-<environment>`: 400: Start date of budgets cannot be updated" (a redeploy in a later month) | Delete the budget (**Cost Management** > **Budgets**, scope `rg-<prefix>-<environment>`, or [Budgets - Delete](https://learn.microsoft.com/rest/api/consumption/budgets/delete)); `./scripts/deploy.ps1` creates it again |
| `T3.FREEOFFER` **Warning** after Infrastructure: the free offer was rejected | Nothing: T3 is regular serverless |
| A Run Command waits with **Conflict**: a policy-installed extension (`MDE.Windows`, ...) holds the VM | Nothing: retried for about 12.5 minutes, and the watchdog restarts a stuck VM once ([below](#run-commands-stuck-in-deleting)); else `./scripts/deploy.ps1` later |
| `OperationNotAllowed` on a deallocated VM | `./scripts/start-demo.ps1`, then the stage again |
| `DEPLOY.DISKS.DRIFT` **Warning** (`STATUS.DISKS`), or "Managed disk storage account type change through Virtual Machine ... is not allowed": the subscription's automation changed a disk's type | Nothing: the disk keeps its type; change it back only if the subscription owner agrees ([disk types](https://learn.microsoft.com/azure/virtual-machines/disks-convert-types)) |
| A Run Command result is reported as stale | Handled (one retry, then fail closed); run the stage again |
| `INFRA.BOOTSTRAP.LOADER_<VM>` **Fail**: a hash mismatch, or a file it couldn't write | Read `C:\ProgramData\DbHubDemo\logs\loader.log` on the VM, fix the cause, `./scripts/deploy.ps1` (it resends a damaged bundle). A **Warning** right after a restart can be a loader still Pending |
| `INFRA.BOOTSTRAP.LOADER_<VM>` **Pass**: "It stopped bundle ...'s bootstrap run, which was still going" ([ADR 0003](adr/0003-t2-host-size-security-type-bootstrap.md#amendment-a-changed-bundle-takes-over-from-a-run-thats-still-going-2026-11-06)) | Nothing: the new bundle's run takes over within 5 minutes; downloads resume from `.partial` |
| `DEPLOY.ARTIFACTS.CHANGED_<VM>` **Pass**: "the bootstrap bundle changed since the last run ..." | Nothing: that VM's track runs again from Artifacts |
| `DEPLOY.ARTIFACTS.CHANGED` **Warning**: "couldn't be built" for the comparison | Install the pinned SDK (or `-SkipRunner`), then `./scripts/deploy.ps1` or `-FromStage Artifacts` |
| `DEPLOY.ARTIFACTS.BUILD` **Fail**: "dotnet publish failed with exit code -2147450725 ... A compatible .NET SDK was not found" (an earlier run can pass while its runner zip is reused) | As for `PREFLIGHT.TOOLS.DOTNETSDK` ([above](#preflight)), then `./scripts/deploy.ps1` |
| `DEPLOY.T1.READY` or `DEPLOY.T2.READY` **Fail** naming a step, or `Get-DemoVmHealth` shows a failed step (not retried within a bootstrap generation) | Read `Get-DemoVmHealth -View Full`, fix the cause, then `./scripts/deploy.ps1 -FromStage Artifacts` (a plain run does when your fix changed the bundle) |
| The T2 host's `DataDisk` step lacks free space: `lowest-cost` keeps the guest on the 128 GiB OS disk (about 64 GiB free needed for `JumpstartImage`, 80 GB for `ProductKey` and `Developer`) | `dataDiskSku` `E10`, then deploy again |
| A media download fails its SHA-256 check | Check the new file's source, then update the pin in `config/versions.json` |
| "The processor does not have required virtualization capabilities" | Another nested-capable size; or `t2Mode` `EvaluationOnlyAzureVm` (labeled evaluation only, [ADR 0006](adr/0006-sql-editions-and-licensing.md)) with `ProductKey` or `Developer` |
| `DEPLOY.FABRIC.SHARED` **Warning**: "Another environment uses the same Fabric workspace as this one ...", so each run overwrites the other's notebooks | Give each its own `fabric.workspaceName` (and `control.fabricWorkspaceName`), then `./scripts/deploy.ps1` for each; until then `destroy.ps1` keeps the workspace ([delete everything](../README.md#delete-everything)) |
| `DEPLOY.FABRIC.SHARED` **Fail** in preflight, and **NOT DONE**: "The Fabric workspace "`<name>`" (fabric.workspaceName) is the one `<group>` records as its own, not this environment's ..." (a configuration that an `init.ps1 -Prefix` wrote before 2026-11-19, or one edited by hand; nothing was created) | Set `fabric.workspaceName` to a name of its own (the message suggests "Database Hub Demo `<prefix>`"), or run the `./scripts/init.ps1 -Force -Prefix <prefix> -WorkspaceName` command it prints; then `./scripts/deploy.ps1` |
| **DONE** or **NOT DONE** says "From the earlier run at ..., since this run didn't check them again: ...", and lists something you've done already, such as `HUB.AGENT.T3` or the Insights app's state (`DEPLOY.CARRIED`, since 2026-11-19) | Nothing: a run that continues an earlier one shows what that run found and it didn't check again ([how a run behaves](deployment.md#one-command-one-guided-stop-phase-28)); a run that checks them again replaces them, and they never keep a run from **DONE**. To drop them all, delete `out/deploy-carry-<resource group>.json` |
| `SECURITY.SECRETSCAN.OUTPUT` **Fail** (`validate.ps1 -Area Security`): a secret pattern in the demo's output under `out/` or `-ScanPath` (dependency trees such as `node_modules` and `.venv` are skipped, `directoriesPruned`) | Delete the files, rotate any real credential, and find the script that wrote it; excerpts are redacted |
| `SECURITY.SECRETSCAN.OUTPUT` **Warning**: "folder(s) named like a dependency tree outside the Insights app's build weren't read" (such as `venv`, `.npm`, or `site-packages` outside `out/fabric-app`) | Read them: `./scripts/validate.ps1 -Area Security -ScanPath <the folder>` (the message names each one), which clears the Warning for that folder and the dependency trees inside it, or move your files out |

### A first run that's slow or doesn't finish

- **Normal:** about 1.5 hours for a first deployment in the default `JumpstartImage` mode, with nobody needed, mostly T2 (its host build about 27 minutes, Arc onboarding about 33); 1.5 to 2.5 hours in `ProductKey` or `Developer`; 30 to 45 minutes from a golden snapshot ([expected duration](deployment.md#expected-duration)).
- **Where it is:** the status page, `out/deploy-status.html`, or `./scripts/status.ps1 -Watch`. A **Running** step is progress; "Azure-side, no action needed" is Azure's work.
- **"Stopped, not done":** the window closed, the PC slept, or Ctrl+C (it stops within seconds, its track processes too): run `./scripts/deploy.ps1` again.
- **`DEPLOY.T2.WAIT` (Manual action required), a slow first build:** T2 didn't finish within `-T2WaitMinutes` (180) and goes on: `./scripts/deploy.ps1` (or `-FromStage T2`) waits again; when Run Commands stuck in Deleting blocked the host's health for 15 minutes, in about 30 minutes.
- **`DEPLOY.VMSTART` Fail:** start the VM in the portal, or `./scripts/start-demo.ps1`, then `./scripts/deploy.ps1`; when Azure is still starting it (up to about an hour, [below](#a-hosts-vm-agent-that-isnt-ready)), don't: run `./scripts/deploy.ps1` once that start ends. As a **Warning**, VMs it started run on because preflight failed: fix that, or `./scripts/stop-demo.ps1`.
- **`DEPLOY.T2.GUIDEDLEFTOVER` (NOT DONE):** an old guided stop's Bastion, or a host password a guided stop or `start-demo.ps1 -Interactive` handed over, is still open: `./scripts/stop-demo.ps1 -RemoveBastionOnly`, then `./scripts/deploy.ps1`.
- **The PC slept, or a codespace stopped:** a closed lid or shutdown stops `deploy.ps1` (it keeps Windows awake otherwise); a codespace stops after its idle timeout (30 minutes; up to 240 in **Settings** > **Codespaces** > **Default idle timeout**, [GitHub Docs](https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces)). Then run it again.
- **Preflight took 7 to 13 minutes:** the first policy inventory (`networkMode` `auto` or `public`); later runs reuse it (`-PolicyCacheHours`). A long wait before the bootstraps: policy extensions, or [stuck Run Commands](#run-commands-stuck-in-deleting).
- **"A network error reached api.powerbi.com; retrying in 5 s (attempt 2 of 4); no action needed."** (or HTTP 408, 429, 502, 503, 504): retried; if it lasts, **NOT DONE** says "A network error stopped it": run `./scripts/deploy.ps1` once the network works, and look for a proxy or TLS inspection in front of `api.fabric.microsoft.com`, `api.powerbi.com`, `management.azure.com`, and `graph.microsoft.com`.
- **The same NOT DONE again:** `./scripts/collect-diagnostics.ps1`, and a **Deployment problem** issue with the zip.

## Run Commands stuck in Deleting

| Result | Fix |
|---|---|
| "Azure is finishing `<extension>` on `<VM>` (installed by a policy in your tenant); no action needed" (Guest Configuration, Defender for SQL, `MDE.Windows`, the Azure Monitor agent) | Nothing: the track waits up to 20 minutes ([instance view](https://learn.microsoft.com/cli/azure/vm#az-vm-get-instance-view)) |
| `DEPLOY.WATCHDOG_<VM>` **Warning**: "was restarted automatically", or "deallocated and started": stuck for 15 to 20 minutes, so the VM was restarted once ([az vm restart](https://learn.microsoft.com/cli/azure/vm#az-vm-restart)), its instance view saved to `out/diagnostics`. The T2 host instead gets its chunks' deletes and a deallocate and start, and nothing during the golden Release or a guest build (`DbHubT2BuildUtc`, 180 minutes at most) | Nothing. On every run, a policy's extension may be failing: ask your Azure administrator |
| `DEPLOY.WATCHDOG_<VM>` **Fail**: "Azure didn't finish its restart in 15 minutes ..." | Wait 30 minutes, then `./scripts/deploy.ps1`; when the T2 host's agent wasn't Ready after "deallocated and started", run it now: it rebuilds the host |
| `DEPLOY.T2.HOSTREBUILD` **Warning**: "... so deploy.ps1 rebuilt T2's host" | Nothing: the failed attempt's **Fail** results became **Warnings** |
| `DEPLOY.T2.HOSTREBUILD` **Fail**: the template or values unread, a delete or create refused, or the new agent not Ready | The fix it names: `./scripts/deploy.ps1`, or `-FromStage Infrastructure`; if the new host's agent stays down, a support request with Azure |
| `DEPLOY.T2.HOSTMISSING`: "archost01, T2's host, doesn't exist ..." | Nothing: the run creates it and builds T2 (about an hour) |
| `DEPLOY.EXTENSIONS_<VM>` **Fail**: an extension still stuck, or "the VM agent's Run Command handling" | Wait 15 to 30 minutes, then `./scripts/deploy.ps1`; a stuck extension: your Azure administrator, with `./scripts/collect-diagnostics.ps1`'s zip. Still busy: `./scripts/stop-demo.ps1`, then `./scripts/deploy.ps1` |
| `DEPLOY.ARTIFACTS.CLEANUP_<VM>` **Warning**: chunk Run Commands still deleting 2 minutes after the send | `sqlvm01`: nothing (25 allowed, [managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)). T2 host, which a leftover can keep from starting: `deploy.ps1` clears them unless the host mustn't restart then; `stop-demo.ps1` deletes them before it deallocates. `az vm run-command list --resource-group <group> --vm-name <vm>` lists them ([az vm run-command](https://learn.microsoft.com/cli/azure/vm/run-command)) |
| "The Run Commands on `<VM>` could not be listed in 3 tries (az: ...)" **Warning** | Nothing; `STATUS.RUNCOMMANDS` shows any that stay. A sign-in error: `az login` |
| `DEPLOY.ARTIFACTS.STALL_<VM>` **Warning**: no chunk for 5 minutes, so one at a time | Nothing |
| `DEPLOY.RUNCOMMAND.STUCK_<VM>` **Warning**: "Azure kept `<name>` on `<VM>` in Deleting ..." (`InternalExecutionError`), "... used a fresh name" | Nothing: it runs as `<name>-yyyyMMddHHmmss`; `STATUS.RUNCOMMANDS` lists what stays, with the delete. At 24 or more on a VM (the limit is 25, [Run Command](https://learn.microsoft.com/azure/virtual-machines/run-command-overview)), or `DEPLOY.T2.WAIT` or `DEPLOY.T2.READY` about no room: `./scripts/deploy.ps1` in about 30 minutes |

### A host's VM agent that isn't Ready

**Symptoms:** a `Host` **Warning** in Run all's live view, "T2: archost01's VM agent wasn't Ready 15 minutes after T2's activity went out ..."; a start that ends `VMStartTimedOut` after about an hour; **NOT DONE** with `DEPLOY.WATCHDOG_ARCHOST01` or `DEPLOY.EXTENSIONS_ARCHOST01`; or `az vm get-instance-view --resource-group <group> --name archost01` shows the agent **Not Ready** ("VM status blob is found but not yet populated"), no agent status, or the host **updating** with no power state for hours.

**Why:** Azure never sends the agent its goal state. On the T2 host it came with chunk Run Commands (`DbHubDemo-Chunk-*`) whose deletes Azure ended with `InternalExecutionError`: they stay, marked for deletion, and Azure refuses the delete while the VM is deallocated; a pending delete completes when the VM deallocates ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)).

**What keeps it from happening again:** `deploy.ps1` sends the host's chunks one at a time, each deleted before the next, and nothing to a VM whose agent isn't Ready. When the agent isn't Ready, chunks are listed, or the host has no power state for 20 minutes, the watchdog deletes them and deallocates and starts it once; if that fails, `deploy.ps1` rebuilds the host once (`DEPLOY.T2.HOSTREBUILD`): it deletes `archost01`, its disks, and its network interface, creates it from the template with its recorded values, and builds and onboards T2 again (about an hour); nothing else is touched. `stop-demo.ps1` deletes a VM's chunks before it deallocates it, and `status.ps1` reports leftovers (`STATUS.RUNCOMMANDS`).

**What to do:** run `./scripts/deploy.ps1`, which recovers or rebuilds the host (an hour or two) and brings these fixes to an older demo ([update an existing environment](deployment.md#update-an-existing-environment); its `DEPLOY.SELFUPDATE` **Warning** gives the command when it can't update itself). When **NOT DONE** says, with `DEPLOY.VMSTART`, that Azure is still starting `archost01`, run it again once that start ends, at most about an hour later. Meanwhile the other targets go on: for T2, `STOP_NOW = True` and Run all, or `./scripts/stop-demo.ps1`. Don't start, deallocate, or clear the host's Run Commands by hand. When even a new host's agent stays down, open a support request with Azure.

## T1

| Result | Fix |
|---|---|
| `T1.SQLVM.MONITORING` **Fail** or **Warning** right after a template deployment (the SQL IaaS Agent extension says `Updating`) | Wait: the Monitoring stage waits up to 20 minutes (`-MonitoringWaitMinutes`) |
| `DEPLOY.T1.MONITORING`, or `T1.SQLVM.MONITORING` **Warning** `{"State":"NotRunning"}` | Nothing: the step restarts the SQL IaaS Agent after 3 minutes (5 after a flag merge); `start-demo.ps1` does too |
| `T1.SQLVM.MONITORING` **Fail**: "Monitoring runs on sqlvm01, but uploads fail: HTTP 403 ..." | Check `sqlvm01`'s system-assigned identity and outbound HTTPS to `telemetry.<region>.arcdataservices.com:443`, then `./scripts/deploy.ps1` |
| `T1.SQLVM.MONITORING` **Warning** that says to start the VM | `./scripts/start-demo.ps1` |
| `T1.SQLVM.MONITORING` **Fail**: "Azure couldn't be read for sqlvm01's monitoring" | `./scripts/deploy.ps1` once Azure answers |
| `T1.SQLVM.MONITORING` **Fail**: "The SqlIaasExtension on sqlvm01 is Failed ...", or `DEPLOY.T1.SQLIAAS.REPAIR` | `./scripts/deploy.ps1`: it repairs it (Azure's Redeploy, once per run) and resends the settings and monitoring flag; or the portal's Repair (SQL virtual machines > `sqlvm01` > SQL IaaS Agent Extension Settings), then `./scripts/deploy.ps1` |
| T1 missing in Database Hub after a cold start or a long run ("DatabaseMonitorArcPlugin reports 'NotRunning'", or Run all's T1 `profile set` failing on SQL error 2) | Run all looks after the plugin (a status counts only after the VM's start; up to 8 minutes, then one restart) and `DbHub-Monitor` checks every 30 minutes; its `monitoring` field says what it did. Now: wait, or `./scripts/start-demo.ps1`, which restarts it but takes over from the session (its auto-stop is replaced by the session's own, 4 hours after the start). `validate.ps1 -Area Telemetry -Target T1` confirms |
| **NOT DONE** on `TELEMETRY.T1`: "No performance telemetry from T1 (sqlvm01) in the last 60 minutes" | `./scripts/deploy.ps1` again (it restarts the plugin and checks again; `validate.ps1` never restarts it) |
| `START.T1.MONITORING` **Warning**: "still reports ... NotRunning 5 minutes after the SQL IaaS Agent service was restarted" | `./scripts/start-demo.ps1` again a few minutes later |
| `T1.SQLVM.ASSOCIATEDSERVICES` **Warning**: inventory still lists Analysis or Integration Services | Nothing: T1's `AssociatedServices` step removes them |
| A T1 health **Warning** about sysadmin | Handled: BUILTIN\Administrators was made a sysadmin |

## T2: Arc Jumpstart's image (`JumpstartImage`)

In the default mode, the T2 host downloads Arc Jumpstart's prebuilt SQL Server 2022 Standard guest disk, makes it `arcsql01` with nobody needed, and checks it before Arc onboarding; nothing falls back by itself ([deployment](deployment.md#t2-from-arc-jumpstarts-image-jumpstartimage)). Its messages are in `Get-DemoVmHealth -VmName archost01 -View Full` and `C:\ProgramData\DbHubDemo\logs` on `archost01`; a failed step is `DEPLOY.T2.HOST` **Fail**, "archost01 failed at step ...". A step retries at the host's next pass, about every 5 minutes (`GuestImage` 5 times, `GuestFirstBoot` 3), then stays failed until `./scripts/deploy.ps1 -FromStage Artifacts` starts a new bootstrap generation. Get the owner's approval before any destroy.

| Result | Fix |
|---|---|
| The banner says "t2SqlInstallMode PaygWizard in your configuration ... is ignored": `PaygWizard` runs as `JumpstartImage` | Nothing; set `t2SqlInstallMode` to `JumpstartImage` to drop the line |
| `DEPLOY.T2.REBUILD` **Warning**: "archost01's guest arcsql01 was built in PaygWizard mode, and its SQL Server setup was never finished" (an environment from before 2026-11-05): the guest is made again from the image, and its old Arc resources deleted when they're provably its own | Nothing: about 27 minutes, then about 33 for Arc. If the image wouldn't fit: `dataDiskSku` `E10` or free space, then `./scripts/deploy.ps1` ([an older demo](deployment.md#an-older-demo-a-plain-deployps1-upgrades-it-2026-11-09)) |
| `DEPLOY.T2.MODE` **Pass**: a finished guest kept in its own mode | Nothing; for the image instead, `./scripts/destroy.ps1`, then `./scripts/deploy.ps1` |
| `PREFLIGHT.T2.MODE` **Fail**: `JumpstartImage` (or a retired `PaygWizard`) "needs the nested Hyper-V host", with `t2Mode` `EvaluationOnlyAzureVm` | `t2SqlInstallMode` `ProductKey` (your key, P10) or `Developer` (Estate only), both unattended ([ADR 0006](adr/0006-sql-editions-and-licensing.md)); or `t2Mode` `Nested` on a nested-capable size |
| `GuestSource` fails: "... an existing guest never changes its source" (the install mode changed) | Set it back, then `./scripts/deploy.ps1 -FromStage Infrastructure`; or rebuild: `./scripts/destroy.ps1`, `./scripts/deploy.ps1` |
| `DataDisk` fails: "Not enough free space on C: ..., 64.1 GB needed ..." | Free space, then `-FromStage Artifacts`; or `dataDiskSku` `E10` and `-FromStage Infrastructure` |
| `GuestImage`: "... doesn't match the image's own Content-MD5 ..." or "The download has ... of ... bytes" | Nothing: the next pass resumes or downloads again; after 5 failures, check the outbound path (below), then `-FromStage Artifacts` |
| "The server ignored the range request ... (HTTP 200, not 206)": a proxy ignores [Range](https://learn.microsoft.com/rest/api/storageservices/specifying-the-range-header-for-blob-service-operations) | Nothing; if every resume starts over, let Range requests through to `jumpstartprodsg.blob.core.windows.net` |
| `GuestImage` fails: "... its Jumpstart image record (jumpstart-image.json) is missing ..." | Rebuild T2: `./scripts/destroy.ps1`, then `./scripts/deploy.ps1` |
| `STATUS.T2.IMAGE` **Warning**: "T2's guest came from a newer Arc Jumpstart image ... than the one this repository was tested with" | Nothing while T2 works; to record it as tested, update `media.jumpstartArcBoxSqlStd` in `config/versions.json` after a full deploy passes |
| `GuestFirstBoot` fails: "arcsql01 didn't accept Jumpstart's published credential within 15 minutes ..." | A slow boot retries (3 tries). A changed password: point `media.jumpstartArcBoxSqlStd.credentialSource`'s `url` at the raw `azure_jumpstart_arcbox/artifacts/ArcServersLogonScript.ps1` of the [`microsoft/azure_arc`](https://github.com/microsoft/azure_arc) commit that matches the image, with its `sha256` (`Get-FileHash`), and `userNamePattern` and `passwordPattern` if they differ; then `-FromStage Artifacts`. Never commit the password |
| `GuestFirstBoot` fails: "... doesn't match its SHA-256 ..." or "... match(es) for the password, not exactly one" (fail closed) | Check the outbound path, or `credentialSource`'s `url`, `sha256`, and patterns, then `-FromStage Artifacts` |
| A host **Warning**: "Uninstalling IS in arcsql01 didn't pass ..." | Nothing: Integration Services stays stopped and disabled |
| `JumpstartImageCheck` fails, **NOT DONE**: "T2 can't use this Jumpstart image: ..." (no default instance, not SQL Server 2022 Standard, or Administrator not a sysadmin) | `-FromStage Artifacts` to check again; when the image is the cause, `ProductKey` or `Developer`, then `./scripts/destroy.ps1` and `./scripts/deploy.ps1` |
| `JumpstartImageCheck` fails 3 times: "The Jumpstart guest isn't ready yet: C:\Jumpstart is still there." | `-FromStage Artifacts`: the cleanup runs again |
| `GuestImage` or `GuestFirstBoot` keeps failing on a time-out, refused connection, or TLS error | Allow outbound HTTPS from `archost01` to `jumpstartprodsg.blob.core.windows.net` and `raw.githubusercontent.com` ([ADR 0017](adr/0017-outbound-access.md)), then `-FromStage Artifacts` |
| `STATUS.T2.DISKSPACE` **Warning**: "archost01 has ... GiB free on C:, below 20 GiB ..." (the guest's disk grows to 100 GiB; a full drive pauses it, losing nothing) | Rebuild T2, or [expand the OS disk](https://learn.microsoft.com/azure/virtual-machines/windows/expand-os-disk) and extend `C:`; `dataDiskSku` `E10` gives the guest its own drive |

## T2: sign-in data and the Arc SQL extension

For every mode. The host's `GuestSignInCleanup` step removes sign-in data after Arc onboarding and verifies none remains, or the build fails. `./scripts/check-sign-in-data.ps1` checks any time (counts and locations only, never a value), and `-Clean` removes what it finds ([the security model](security-model.md)).

| Result | Fix |
|---|---|
| `STATUS.T2.AUTOSIGNIN` **Warning**: the guest's one automatic sign-in from an old guided stop is still armed | Nothing while `archost01` runs: within 5 minutes it's turned off and its secret deleted, and the password rotated. Or `check-sign-in-data.ps1 -Clean` |
| `SECURITY.SIGNIN.<VM>`, `T2.ARC.ONBOARDING`, or `DEPLOY.T1.READY` **Warning**: "Windows automatic sign-in was left armed ..., and the cleanup turned it off" (the guided stop's cleanup hadn't finished; the sign-in data sweep did it) | Nothing; if it happens again, scan with `check-sign-in-data.ps1 -VmName <VM>` and open an issue |
| `SECURITY.SIGNIN.<VM>` or `GOLDEN.CAPTURE.SIGNIN` **Fail** naming automatic sign-in, its LSA secret, or Winlogon's `DefaultUserName` or `DefaultPassword` (no golden snapshot) | `check-sign-in-data.ps1 -VmName archost01 -Clean` |
| A note that the cleanup deleted the LSA secret `DefaultPassword` Azure's provisioning leaves ([ADR 0009](adr/0009-secrets-handling.md)) | Nothing: the sweep after Arc onboarding and T1's `AutoLogonSecret` step delete it, and it stays a **Pass**; a scan without `-Clean` that finds it is a **Fail**: `-Clean` |
| `SECURITY.SIGNIN.<VM>`, `T2.ARC.ONBOARDING`, or `GOLDEN.CAPTURE.SIGNIN` **Manual action required**: "The Security log holds token-shaped value(s)" | Once your security team has it: `check-sign-in-data.ps1 -VmName <vm> -Clean -ClearSecurityLog`, or `wevtutil clear-log Security` (elevated) |
| `SECURITY.SIGNIN.<VM>` or `T2.ARC.ONBOARDING` **Warning**: "the cleanup cleared Windows PowerShell" (endpoint protection may report it) | Expected without the host identity: tell your security team, or use `assignRoles: true` |
| `T2.ARC.ONBOARDING` **Fail**: "arcsql01 is onboarded, but the onboarding token's traces couldn't be removed and verified: ... arcsql01 (guest) couldn't be reached (Running: ...)", with PowerShell Direct's own error in the brackets, or "... wasn't checked ...: archost01's own bootstrap pass held its lock for 30 minutes"; the status page's "Sign-in data cleanup" row says the same | `./scripts/deploy.ps1` again (since 2026-11-19): the check is owed until it passes (`DbHubArcSweepUtc`), so the run checks again by itself, after the host's own pass, with [the recovery below](#powershell-direct-into-arcsql01-breaks). In the evaluation-only mode nothing is owed, because that VM turns its Azure guest agent off after its onboarding: the result's fix is `./scripts/check-sign-in-data.ps1 -VmName arcsql01 -Clean -Force`, while that agent still runs. To look meanwhile: `./scripts/check-sign-in-data.ps1 -VmName archost01` (counts and locations only) |
| `./scripts/check-sign-in-data.ps1 -Clean` ends at once with `SECURITY.SIGNIN.CONFIRM` **Manual action required**: "Nothing was checked or cleaned: -Clean asks before it changes the VMs, and no one can answer here" (CI, redirected input, a launcher, or an assistant; since 2026-11-19) | Run the command in the result, the same with `-Force`, which cleans without asking; or run it without `-Force` in a terminal that can take input, and confirm there |
| `T2.ARC.SQLEXTENSION` **Warning**: Creating long after onboarding (downloads from `<region>.his.arc.azure.com` fail with "certificate verify failed", retried about every 6 minutes), or Updating (PAYG) | Wait, then `./scripts/deploy.ps1`: it converges the extension, license type, and monitoring |

## T2: Arc and the guest

| Result | Fix |
|---|---|
| `T2.ARC.CONNECTED` **Warning** (Disconnected) while the host is deallocated | Expected; it reconnects after `./scripts/start-demo.ps1` |
| `T2.GUEST.STATE` **Fail**, "arcsql01 is still air-gapped by a golden capture", `T2.ARC.CONNECTED` **Fail**, or Run all's "The virtual machine arcsql01 is not in running state": an interrupted capture | Run all, or `./scripts/start-demo.ps1`, releases it (`T2.GOLDEN.SOURCE`); never release a **copy** by hand: "a copy ... hasn't been reset yet" needs `./scripts/deploy.ps1` |
| Run all's T2 start fails, "A golden capture is in progress on archost01" (or its marker "can't be read"), with a `T2.GUEST.STATE` or `T2.GOLDEN.SOURCE` **Warning** (the marker holds T2 for 6 hours) | Let the capture finish; if none runs, `./scripts/capture-t2-golden.ps1` again releases the source, as do `start-demo.ps1` once its snapshot exists and Run all after the time given |
| `GOLDEN.CAPTURE.CONTROL` **Fail**: "An on-demand run is active until ..." or "is starting or stopping now" | Wait, or **Stop now** or `./scripts/stop-demo.ps1`, then capture again |
| `GOLDEN.CAPTURE.CONTROL` **Fail**: "A start-demo.ps1 session runs, and its auto-stop ... deallocates archost01" (since 2026-11-19): its auto-stop would deallocate `archost01` during the capture | `./scripts/stop-demo.ps1` first (it ends the session and removes the auto-stop; the capture starts `archost01` itself), then capture again |
| `T2.GUEST.STATE` **Fail**: the guest is Off, or not connected to `DbHubDemoNat` | Off: Run all starts it. Disconnected: `./scripts/deploy.ps1`; if it still says so, `./scripts/destroy.ps1 -KeepFabric`, then `./scripts/deploy.ps1`. The remediation's by-hand command (`Connect-VMNetworkAdapter` and `Start-VM` on `archost01`, through `az vm run-command invoke`) is the last resort |
| `GOLDEN.CAPTURE.SOURCE` **Fail** or **Warning**: the source wasn't fully returned | `./scripts/start-demo.ps1`, then `./scripts/validate.ps1 -Area T2`; the snapshot is fine (`GOLDEN.CAPTURE`) |
| `GOLDEN.TEST.SOURCE` **Warning**: "its host archost01 wasn't deallocated for the whole test" | Nothing; for the source's side too, `stop-demo.ps1` before `test-t2-golden.ps1` |
| `T2.ARC.DISCONNECTEDDAYS` **Warning** at 21 days, **Fail** above 30 (PAYG lapses; [Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq)) | Start the demo before day 30; after it, `./scripts/destroy.ps1` and `./scripts/deploy.ps1` (`reset-demo.ps1 -RebuildGuest` is **Not supported**) |
| `T2.ARC.NODUPLICATES` **Fail**, naming extra machines or instances | Delete the extra instance resources, then machines, in the portal or with `az resource delete` ([delete from Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc)), then `./scripts/deploy.ps1`; a stale `arcsql01` is replaced by itself |
| `T2.ARC.MIGRATIONASSESSMENT` **Warning**: assessment off, or none uploaded yet (optional, free) | `./scripts/deploy.ps1` turns it on and runs it (otherwise Sundays 23:00 guest time); update an old extension; ask for an exemption from a denying policy ([migration assessment](https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment)) |
| `T2.ARC.ONBOARDING` **Fail**: `azcmagent connect failed with exit code 26`, `lookup management.azure.com: no such host` (the host's DNS on `192.168.200.1` isn't listening) | `./scripts/stop-demo.ps1`, `./scripts/start-demo.ps1`, then `./scripts/deploy.ps1` |
| The guest's Windows Server evaluation nears 180 days (`ProductKey`, `Developer`, or a kept `PaygWizard` guest) | Usually nothing: with 30 or fewer days and a rearm left, the host runs `slmgr.vbs /rearm`, recorded in `guest-evaluation.json` ([Slmgr.vbs](https://learn.microsoft.com/windows-server/get-started/activation-slmgr-vbs-options)); `status.ps1 -Detail` shows the days left, and `slmgr /dlv` in the guest the expiry. With no rearm left, `destroy.ps1` and `deploy.ps1` before it ends |

### PowerShell Direct into arcsql01 breaks

`archost01` reaches its guest only over [PowerShell Direct](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct). After an update's new bundle, the host checks every step again, and a long session of its own can break the channel: "The Hyper-V socket target process has ended" while the guest's heartbeat is healthy. `deploy.ps1` waits for that pass before its T2 steps (a few minutes), and every PowerShell Direct step recovers by itself: three probes 10 seconds apart, then one clean restart of the guest ([Stop-VM](https://learn.microsoft.com/powershell/module/hyper-v/stop-vm)) per run (each `deploy.ps1` run, `-Sequential` included, and each `configure-arc.ps1`; once an hour from Run all), never during a golden capture or within 5 minutes of a start. Since 2026-11-19 that includes Arc onboarding's own probe, onboarding, and marker, and the sign-in data check right after it, a first deployment's too: each waits for the host's bootstrap pass and holds its lock (at most 30 minutes), so they never reach the guest at the same time as the host, and one that finds the guest unreachable, before it changed anything, tries again up to three more times, 10, 30, and 60 seconds apart, with this recovery first. T2's activity profile and Run all's T2 steps hold that lock too while their command runs in the guest, for at most 2 minutes, then run it as before. Restarts are recorded in `C:\ProgramData\DbHubDemo\guest-recovery.json`, and the host's health shows the last one (`guestRecovery`).

| Result | Fix |
|---|---|
| `DEPLOY.T2.GUESTRETRY` or `DEPLOY.T2.GUESTRESTART` **Warning**, or a Run all T2 step's **Warning** that it ran after a probe or restart | Nothing |
| `DEPLOY.T2.GUESTRESTART` **Fail**, or `T2.ARC.ONBOARDING`, `DEPLOY.PROFILE_T2`, or a Run all T2 step fails with "The Hyper-V socket target process has ended" and "... broke again", "... still didn't answer ...", or "this run already restarted the guest once" | `./scripts/deploy.ps1` again; then `./scripts/stop-demo.ps1` and `./scripts/deploy.ps1`, and an issue with `archost01`'s logs and `guest-recovery.json` |
| `T2.ARC.ONBOARDING` **Fail**: "arcsql01 didn't answer over PowerShell Direct on archost01 after 4 tries: ... It isn't onboarded to Azure Arc, so its configuration waits for it.", or "The probe of arcsql01 on archost01 failed: ... The host's own bootstrap pass held its lock (bootstrap.lock) for 1800 seconds ..."; `T2.ARC.CONFIGURATION` is **Not selected** (since 2026-11-19) | `./scripts/deploy.ps1` again: the probe waits for the host's pass and tries again, with the recovery above, then onboards and configures `arcsql01` once it answers. Nothing was changed. When it fails the same way, `./scripts/status.ps1 -Detail` shows the guest's state on `archost01`. For an Arc machine that's already Connected (an update), the same message is a **Warning**, and the configuration goes on |

## T3

| Result | Fix |
|---|---|
| T1 can't sign in to T3 during the T3 stage (its new P6 membership isn't applied; tokens cache up to about 24 hours) | After the stage's 10-minute retry and **Warning**, `./scripts/deploy.ps1 -FromStage T3` later |
| T3's checks say it was removed (`stop-demo.ps1 -RemoveT3`) | `./scripts/start-demo.ps1` recreates it; then select it for Database Agents again (`HUB.AGENT.T3`, [step by step](database-agents.md)) |
| A recreate fails because the name is taken | A few minutes later, `./scripts/start-demo.ps1` again |
| T3 doesn't auto-pause: a profile keeps sessions open | `./scripts/stop-demo.ps1` turns profiles off; it pauses `t3AutoPauseMinutes` later |
| A paused T3 bills compute after validation or `reset-demo.ps1` | Expected: they connect; it pauses again |
| T3 shows fresh telemetry while `Paused` | A sample doesn't prove it's awake; the readiness gate checks the extended property too |
| `T3.AGENT` **Warning**: "Database Agents can't monitor T3 yet: ...": one vCore serverless, an elastic pool, no write access for you (`Microsoft.Sql/servers/databases/write`), or monitoring off | `./scripts/deploy.ps1` scales T3 to 2 vCores online and turns monitoring on; sign in to Fabric as someone with Contributor or SQL DB Contributor on T3; take it out of the pool. "couldn't be read": `./scripts/validate.ps1 -Area T3` again |

### Database agent settings

Selecting T3 for Database Agents is required once for the Database Agent beat, and everything else works without it; [Database Agents for T3](database-agents.md) has every step. What's marked "observed" was seen in the owner's tenant on 2026-11-20; what's marked "inferred" is a conclusion from what was seen there, not itself seen.

| Result | Fix |
|---|---|
| `HUB.AGENT.T3` **Manual action required**, under **Please confirm**: Database Agents (preview) has no API, so a person selects T3 once | Once per deployment, with the link and database the message gives: [step by step](database-agents.md#step-by-step). It stays through sessions and updates; redo it after `stop-demo.ps1 -RemoveT3` or a new deployment. Saving works while T3 is paused (observed) |
| **Save** says "Database agent changes couldn't be saved. Your changes couldn't be applied. Review the selected databases and their settings, then try again." | One database that fails fails the whole save: "If any selected database fails that permission check, the entire save fails" ([enable Database Agents](https://learn.microsoft.com/fabric/database/hub/enable-database-agents#enable-and-activate-database-agents)). The list can hold databases a save fails on: deleted ones, which stay listed until their telemetry ages out, up to about 7 days after they stopped reporting (inferred from Database Hub's telemetry; [why](database-agents.md#when-to-do-it-again)), and ones you can't write to, that are outside your Fabric tenant's home region, one-vCore serverless, or in an elastic pool ([an agent can't be saved](https://learn.microsoft.com/fabric/database/hub/database-agents-known-limitations#an-agent-cant-be-saved-or-doesnt-become-active)). **Don't wait for the list to clear:** it wasn't observed whether a save works again once a deleted database drops off, so fix the selection now. **If only you use Database Agents in this tenant:** reset: clear the selection and **Save** with nothing selected, which saves (observed); then check one row at a time and **Save**, keeping each that saves ([step 3](database-agents.md#step-by-step)). **If others use it:** don't uncheck their databases, which would stop the agent watching them for whoever selected them; ask whoever manages Database Agents in your tenant to add T3, or to remove a deleted database. **When T3's own row still fails:** `./scripts/validate.ps1 -Area T3` (`T3.AGENT`) checks your write access and T3's size; T3's region must be the home region; and Learn asks for a serverless database to be awake, so try again during a session |
| Several rows named `ContosoCare`, with no server and an empty **Owner** column (observed) | Every environment's T3 has that name, the list shows only the database's name, and deleted ones stay listed until their telemetry ages out, up to about 7 days (inferred). `HUB.AGENT.T3` names yours. With several, check one at a time and **Save**: a deleted database's row fails, and one that exists saves (observed: 3 of 19 saved, the 3 that still existed) |
| **Save** is "temporarily limited" (observed, after saves in quick succession) | Wait a few seconds, then select **Save** again |
| **Database agent settings** shows PostgreSQL (0) and Cosmos DB (0) (observed) | Expected: Database Agents in Database Hub covers Azure SQL Database. For PostgreSQL it's a limited preview in Visual Studio Code only, and Learn lists no Azure Cosmos DB support ([supported databases and servers](https://learn.microsoft.com/fabric/database/hub/database-agents#supported-databases-and-servers)). T4 and T5 still show in Database Hub's monitoring |
| No issue on T3 about 20 minutes after its plan regresses | An issue appears about 15 minutes after a condition starts, only on an enrolled database with the matching policy option ([a new issue doesn't appear](https://learn.microsoft.com/fabric/database/hub/database-agents-known-limitations#a-new-issue-doesnt-appear)): check that T3's save completed, that its **Agent policy** has the three options, and that the green **Database agent is active** shows, which is about the agent, not T3. The agent evaluates T3 only while it's awake, as during a session. `./scripts/validate.ps1 -Area T3` (`T3.AGENT`) ([the loop](demo-walkthrough.md#the-database-agent-loop-on-t3)) |
| The list doesn't load at all | Learn: your identity can't access a database already saved for the tenant; retry with one that can ([the list](https://learn.microsoft.com/fabric/database/hub/database-agents-known-limitations#the-database-or-server-list-cant-be-loaded)) |
| `DESTROY.HUB.AGENT.T3` **Manual action required**: `destroy.ps1` can't remove T3 from **Database agent settings**, which has no API; a line before it asks says the same | If you selected T3 for Database Agents: Database Hub > **Agent (preview)** > **Manage agents** > **Database agent settings**, uncheck only `azuresql01-<deploymentId>/ContosoCare`, then **Save**, before or after `destroy.ps1`, and leave every other database as it is: the selection is saved for the tenant, and while a deleted T3 stays in it, everyone's **Save** there fails. Among look-alike `ContosoCare` rows, do it after `destroy.ps1`, when T3's row fails every **Save**: uncheck one row at a time and **Save**, check it again if **Save** still fails, and stop when a **Save** succeeds. Nothing to do if you never selected it, and `destroy.ps1`'s exit code doesn't count it ([when to do it again](database-agents.md#when-to-do-it-again)) |

## T4

`pgflex01-<deploymentId>`, the PostgreSQL flexible server, is in every deployment: `Standard_D4ds_v5` with autonomous tuning by default. When Azure refuses a size (`SkuNotAvailable`), the fallback tries another zone, then `Standard_D4ads_v5`, then `Standard_D2ds_v5` with tuning off; a `t4SkuName` size falls back too, first to sizes that cost as much or more ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)).

| Result | Fix |
|---|---|
| `DEPLOY.T4.SKU` or `PREFLIGHT.T4.SKU` **Warning**: `SkuNotAvailable` ("Specified SKU is not supported in this region"), then "this run creates T4 as ..." | Nothing: each step is a **Warning** with its price; `DEPLOY.T4.FALLBACK` says what T4 got |
| "Azure is removing the T4 server it refused ..., so the next attempt waits for it to go" (a `Dropping` shell), or `DEPLOY.T4.REMOVING` **Fail** after 15 minutes | Nothing while it waits; after the **Fail**, `./scripts/deploy.ps1` in a few minutes goes on with the next size (`DbHubT4Size`) |
| `DEPLOY.T4.FALLBACK`, `T4.SIZE`, or `STATUS.T4.SIZE` **Warning**: "T4 was created as `<size>` instead of `<size>`", with both prices; **DONE** says "T4 created as General Purpose ... because Azure refused ..." (on `Standard_D2ds_v5`, "so autonomous tuning is off") | Nothing: later runs keep the size (`DbHubT4Size`, `DbHubT4Refused`), and it bills the hourly list price given while it runs. For another size, set `t4SkuName` (moving restarts T4). **To move T4 to the refused size** once it's offered to you (a Region access request, [capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors)): set `t4SkuName` to T4's current size and run `./scripts/deploy.ps1`, which clears the record; then set the size you want and run it again |
| **NOT DONE**: "T4 isn't created yet: the fallback chose ..." (another error, which `DEPLOY.TEMPLATE` names, stopped it), or **NOT DONE** for another resource after T4 was created | Fix what `DEPLOY.TEMPLATE` names (a vCore quota, for example), then `./scripts/deploy.ps1`; a created server is kept |
| `DEPLOY.T4.SKU` and `DEPLOY.T4.OFF` **Fail**: "Azure refused every size T4's fallback tries" | A Region access request for Azure Database for PostgreSQL flexible server ([capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors)), or a `t4SkuName` offered to you; then `./scripts/deploy.ps1` |
| `DEPLOY.T4.RETRY` **Warning**: an earlier run left T4 out, so this one tries the default again | Nothing; `t4SkuName` chooses the size |
| The banner says "t4Enabled false in your configuration is ignored" | Nothing; remove `t4Enabled` to drop the line |
| `T4.MAXCONNECTIONS` **Warning**: "max_connections ... is set but waits for a restart" | Nothing: T4 restarts before T1 sets it up (`DEPLOY.T4.RESTART`). "is ..., not ...": `./scripts/deploy.ps1 -FromStage Infrastructure` |
| `METRICS.T4` **Warning**: T4 is stopped or starting, or no metrics "yet"; **Fail**: "couldn't be read" | `./scripts/start-demo.ps1` or Run all, then `validate.ps1 -Area T4` in a few minutes; the **Fail** needs Reader on the resource group |

## T4's read replica

`pgreplica01-<deploymentId>` exists only during a session: `start-demo.ps1` or Run all creates it, and `stop-demo.ps1` or the auto-stop deletes it; `deploy.ps1` creates it for its checks and deletes it at its end unless a session uses it ([ADR 0025](adr/0025-t4-read-replica.md); [in the deployment](deployment.md#t4s-read-replica-in-the-deployment-2026-11-13)). `status.ps1` shows it as `STATUS.T4.REPLICA`.

| Result | Fix |
|---|---|
| `STATUS.T4.REPLICA`, `START.T4.REPLICA`, `STOP.T4.REPLICA`, `METRICS.T4.REPLICA`, or `HUB.ESTATE.T4.REPLICA`: "T4's read replica isn't deployed yet: this environment was deployed before the replica existed" (before 2026-11-13) | `./scripts/deploy.ps1` adds it, about 9 minutes ([upgrading an existing demo](../README.md#upgrading-an-existing-demo)) |
| `DEPLOY.T4.REPLICA.END` **Pass**: "... was kept ...: a session ... uses it" | Nothing: the session's end deletes it |
| `DEPLOY.T4.REPLICA.END` **Warning**: kept because a session's use "couldn't be read", it's still being created, or it "couldn't be deleted" (it bills) | With no session running, `./scripts/stop-demo.ps1` or the next `./scripts/deploy.ps1` deletes it; the nightly safety stop stops it meanwhile |
| `PREFLIGHT.T4.REPLICA`, `DEPLOY.T4.REPLICA`, or `STATUS.T4.REPLICA` **Not supported**: "T4 runs on the Burstable size ..." (no replicas there, so **DONE** doesn't wait for one) | Remove `t4SkuName` or set `Standard_D2ds_v5`, then `./scripts/deploy.ps1` (`estimate-cost.ps1` shows the cost) |
| `DEPLOY.T4.REPLICA.FALLBACK` or `START.T4.REPLICA.FALLBACK` **Warning**: "T4's read replica was created as `<size>` ...", with both prices; or "Waiting for the refused replica's shell ... to go" | Nothing: the size is recorded (`DbHubT4ReplicaSize`); a shell goes within 15 minutes |
| `DEPLOY.T4.REPLICA` **Fail**: "Azure refused every size it can have" (`start-demo.ps1`: a **Warning**, and no replica) | A Region access request ([capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors)), then `./scripts/deploy.ps1` |
| `DEPLOY.T4.REPLICA` or `START.T4.REPLICA`: "couldn't be created as ...", with Azure's error, or `ReadReplicaServerInUnexpectedState` | Fix what it names, or wait for T4 to read Ready, then run the script again |
| `START.T4.REPLICA` **Warning**: "T4 isn't running ..." | `./scripts/start-demo.ps1` again once T4 runs |
| `STATUS.T4.REPLICA` **Warning**: "is stopped: a session ended without stop-demo.ps1 ..." (it bills its storage and Defender plans), or "is running while T4 is Stopped" | `./scripts/stop-demo.ps1` deletes it; a `start-demo.ps1` before that starts it before T4, as Azure requires |
| Starting T4 by hand fails with `SourceReplicasStartStopOrder` | `./scripts/start-demo.ps1` (replica first), or `./scripts/stop-demo.ps1` |
| `METRICS.T4.REPLICA` **Warning**: no lag "yet"; `HUB.ESTATE.T4.REPLICA` **Warning**: "... Azure Resource Graph doesn't list it yet" | `./scripts/validate.ps1 -Area T4` (or `-Area Hub`) again in a few minutes |
| `demo-control.ps1 -Target T4 -Scenario incident:replica-lag` gives `CONTROL.T4` **Warning**: "replica-lag wasn't sent" (T4 or its replica not **Ready**, or none this session: `-SkipT4Replica`, a refused size, or `MODE = "activities"`, whose runs never create one) | `./scripts/start-demo.ps1` (about 9 minutes), then send it again |
| `CONTROL.T4` **Warning**: "T1's runner settings don't name T4's read replica", the runner says "T4's read replica isn't known on T1", or **Not supported** on a Burstable T4 | `./scripts/deploy.ps1`, then `./scripts/start-demo.ps1`; on Burstable, the size it names first |
| T4's Estate page in the Insights app, or the history report, has no T4 rows: only a Run all end, `stop-demo.ps1 -SaveHistory`, `deploy.ps1`'s snapshot, or `configure-fabric.ps1 -RunLiveActivity` saves them, before the replica goes | End the next session with Run all or `./scripts/stop-demo.ps1 -SaveHistory` |
| `STOP.FABRIC.SAVEHISTORY` or `FABRIC.T4.HISTORY` **Warning**: "... NB_DatabaseHub_LiveActivity is from before T4's history ..." | `./scripts/deploy.ps1` (with `"importNotebooks": false`, `configure-fabric.ps1`), then the command `STOP.T4.HISTORY.PENDING` gives |
| `STOP.T4.HISTORY.PENDING` **Warning**: the history wasn't saved (usually a paused capacity); the metrics are kept in `./out/history-pending/postgres-metrics-<resource group>-<time>.json` | Once the capacity runs: `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath <file>`; the file then moves to `out/history-pending/saved` |

## T5: Azure Cosmos DB

`cosmos01-<deploymentId>`, Azure Cosmos DB for NoSQL ([ADR 0027](adr/0027-t5-cosmos-db.md); [in the deployment](deployment.md#t5-in-the-deployment-2026-11-18)). Its container, with its 400 RU/s, exists only during a session: the starts create it, the stops delete it. `status.ps1` shows `STATUS.T5`; `validate.ps1 -Area T5` checks it.

| Result | Fix |
|---|---|
| `STATUS.T5`, `START.T5`, `T5.ACCOUNT`, or `HUB.ESTATE.T5`: T5 "doesn't exist" (a demo from before 2026-11-18, or deleted) | `./scripts/deploy.ps1` creates it (`DEPLOY.T5.MISSING`) |
| `DEPLOY.T5.FREETIER` **Warning**: another account has the subscription's one free tier, it "isn't offered to this subscription" (internal), or "Azure refused T5's free tier" | Nothing: its 400 RU/s bill at list price only while the container exists ([cost management](cost-management.md#t5-azure-cosmos-db-2026-11-18)). For the free tier, delete the other account before T5 is created; an existing T5 keeps what it was created with |
| `DEPLOY.T5` **Warning**: "Azure didn't create T5's Azure Cosmos DB account (...) ..., so the template was deployed again without T5" (no capacity, or a policy); the run can end **DONE** | Nothing when temporary: the next template deployment tries again (a resume skips it, `DbHubT5Refused`). When it lasts, `"t5Enabled": false` or another region. An account that existed before the run is never left out: its failure is **NOT DONE**, and `DEPLOY.TEMPLATE`'s fix says how to deploy without T5 |
| `PREFLIGHT.POLICY.RESOURCETYPES` **Fail**: a policy "denies resource types the demo creates, all of them T5's" | `"t5Enabled": false` (`DEPLOY.T5.OFF`), then `./scripts/deploy.ps1`; or an exemption |
| `WORKLOAD.T5.WARMUP` **Fail**, 401 or 403 after 10 minutes: T1's data-plane role isn't effective or is missing (`T5.ACCESS`) | `./scripts/deploy.ps1`, which assigns Cosmos DB Built-in Data Contributor (Contributor can) |
| `WORKLOAD.T5.WARMUP`: "could not be resolved" or a time-out (`sqlvm01` doesn't resolve `cosmos01-<id>.documents.azure.com` to the private endpoint, or `snet-pe` doesn't allow TCP 443 from `snet-sqlvm`) | `validate.ps1 -Area T5` (`T5.NETWORK`), then `./scripts/deploy.ps1`, which sets the DNS zone group and `Allow-Cosmos-From-T1` |
| `T5.ENTRAONLY` or `T5.NETWORK` **Fail** (keys or public access back on), or `T5.CONTAINER` **Warning**: "has `<n>` RU/s, not 400" | `./scripts/deploy.ps1` sets them back; Database Hub's Security page shows the first two as Issues |
| `T5.CONTAINER` **Pass**: "isn't there now, because it exists only during a session" | Nothing |
| `T5.CONTAINER` **Warning**: "is there while the demo is stopped" (it bills) | `./scripts/stop-demo.ps1`; the nightly safety stop deletes it tonight |
| `T5.CONTAINER` **Warning**: "isn't there while sqlvm01 runs ..." | `./scripts/start-demo.ps1`, or a Run all session |
| `START.T5.CONTAINER`, `CONTROL.T5.CONTAINER`, or the **T5 container** step **Fail**: Azure refused it (`AuthorizationFailed`: the session control's role lacks `containers/write`) | `./scripts/start-demo.ps1` or `./scripts/deploy.ps1`; for the role, an Owner's `./scripts/grant-safety-stop.ps1` |
| `DEPLOY.T5.LIFECYCLE`, `T5.LIFECYCLE`, or `STOP.T5` **Warning**: "T5's container stays between sessions" (the control's role can't create it again yet, after an update by someone who isn't an Owner; it bills all month) | An Owner runs `./scripts/grant-safety-stop.ps1` once (or `deploy.ps1` as an Owner); a demo deployed before 2026-11-19 keeps its container until its next `./scripts/deploy.ps1`. A **Pass** on the free tier |
| `DEPLOY.T5.LIFECYCLE` or `T5.LIFECYCLE` **Warning**: "T5's container is deleted only when you run ./scripts/stop-demo.ps1" (a Contributor's deployment: the control has no role, so Run all can't start a session and the nightly safety stop can't delete it; preflight and `estimate-cost.ps1` price it all month; when only that puts the month over `monthlyCeilingUsd`, `PREFLIGHT.COST.MONTHLY` is a **Warning**, and the update and `start-demo.ps1` go on). `start-demo.ps1` still creates it with your rights | Run `./scripts/stop-demo.ps1` after each session. An Owner's `./scripts/grant-safety-stop.ps1`, once, gives Run all and the nightly safety stop their roles. A **Pass** on the free tier |
| `STOP.T5` **Warning**: "wasn't deleted" | `./scripts/stop-demo.ps1` again; the nightly safety stop deletes it too |
| `METRICS.T5` **Warning**: "no request metrics for T5 from the last 15 minutes" | `./scripts/start-demo.ps1` or Run all, then `validate.ps1 -Area T5` |
| `STOP.T5.HISTORY`, `DEPLOY.FABRIC.HISTORY.T5`, or `FABRIC.T5.HISTORY` **Warning**: "T5's metrics weren't captured for the history" | Nothing: Database Hub keeps them for Azure Monitor's retention; the next `./scripts/stop-demo.ps1 -SaveHistory` or `./scripts/configure-fabric.ps1 -RunLiveActivity` reads them again |
| `FABRIC.T5.HISTORY` or `STOP.FABRIC.SAVEHISTORY` **Warning**: "... NB_DatabaseHub_LiveActivity is from before T5's history" | `./scripts/deploy.ps1` (or `configure-fabric.ps1`), then `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity` |
| T5's **Avg Latency** chart is empty | Expected: it charts direct mode; the runner uses the gateway |
| `ru-storm` shows no 429s yet: the charts are hourly | Look at **Normalized RU Consumption** and **Throttled Requests** for that hour; `status.ps1` shows the last 15 minutes |
| Storm documents are left in `patient-events` | `./scripts/reset-demo.ps1 -Target T5`; the next storm cleans up too |

## Database Hub and telemetry

| Result | Fix |
|---|---|
| `TELEMETRY.<target>` **Warning**, no recent rows: telemetry arrives 3–15 minutes after the activity, and a deallocated VM or paused T3 sends none | Wait, or start the demo; `Test-DemoHubTelemetry -Target T1, T2, T3 -WaitMinutes 15` shows rows and lag |
| Database Hub doesn't load or shows nothing: P4 is off, it isn't in your tenant's region ([region availability](https://learn.microsoft.com/fabric/admin/region-availability)), or the user lacks Reader | A Fabric administrator checks P4 (their `deploy.ps1` reads it); presenters need Reader (P8) ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)) |
| `FABRIC.P4.HUBSETTING` or `PREFLIGHT.P4.HUBSETTING` **Manual action required**: "Couldn't check the Fabric tenant setting ... (needs a Fabric administrator; HTTP 403): please confirm it's enabled" ([List Tenant Settings](https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings)) | Nothing when Database Hub opens: a **Please confirm** reminder that never blocks **DONE**; its evidence (`checkedThroughApi`, `statusCode`, `settingRead`, `readError`) says what happened |
| `FABRIC.P4.HUBSETTING`: "is disabled (read through the Fabric admin API)" | A Fabric administrator enables **Users can access the Database hub (preview)** (admin portal > **Tenant settings**), then `./scripts/deploy.ps1`; the one P4 result that blocks **DONE** |
| `HUB.PRESENTER.*` **Manual action required**, under **Please confirm** (`assignRoles` is false) | An administrator runs the commands in the result |
| **Ask Copilot** is greyed out in Database Hub | Usually Copilot's tenant settings are off (P17). A Fabric administrator turns them on in the admin portal's **Tenant settings**, as [enable Copilot in Fabric](https://learn.microsoft.com/fabric/fundamentals/copilot-enable-fabric) names them: **Users can use Copilot and other features powered by Azure OpenAI**, **Users can use Copilot, AI Agents, and other AI experiences powered by OpenAI as a Microsoft subprocessor**, and their two companions for data processed outside your capacity's geographic region ([prerequisites](prerequisites.md#optional)); where they're delegated, a capacity administrator turns them on for the capacity too. It's the tenant administrator's decision, outside the demo: no script reads or changes them, and Database Hub's own views work without them |
| Copilot in Database Hub isn't there or declines a target (preview; coverage not documented) | The [fallback ladder](demo-walkthrough.md#the-ladder); note it in the [live coverage record](../fabric/agent/README.md#live-coverage-record) |
| Database Agents raises no issue on T3, or **Manage agents** doesn't list it: Azure SQL Database only, after `HUB.AGENT.T3`; a new issue takes about 15 minutes ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)) | [Database agent settings](#database-agent-settings); right after a first `deploy.ps1`, T3 joins the list about 15 minutes after its performance monitoring is turned on ([Database Agents for T3](database-agents.md#before-you-start)) |

## Fabric notebooks

The scripts never create or scale the Fabric capacity, and resume or pause it only with `fabric.manageCapacity` (for a capacity that's yours alone); otherwise you or its administrator resume it, which resumes its billing ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)).

| Result | Fix |
|---|---|
| HTTP 404 `CapacityNotActive` (**Manual action required**), or **NOT DONE** names `FABRIC.P5.CAPACITY`, "is Inactive", while the lakehouse "couldn't be listed" (`FABRIC.ITEMS.REQUIRED`, `FABRIC.RESOLVE.LAKEHOUSE`) | Resume the capacity (portal > **Microsoft Fabric** > **Resume**), then `./scripts/deploy.ps1`. HTTP 429 or 5xx is a **Warning**: again in a few minutes |
| `HUB.TELEMETRY.TOKEN` isn't **Pass**: the endpoint refused the notebook's `kusto` token (undocumented) | Each query prints its KQL for the Azure Data Explorer web UI; `validate.ps1` checks with an Azure CLI token |
| `FABRIC.P5.WORKSPACE` isn't **Pass**: no Contributor on the workspace (P5) | A workspace administrator adds you |
| After an upgrade, the notebooks, model, or Insights app are still older (no **PostgreSQL** page) | `./scripts/deploy.ps1` again: it republishes when `DbHubFabricSha256` differs |
| `FABRIC.SEMANTICMODEL.REFRESH` **Fail**, 0xC14700DF, "one or multiple source tables either do not exist ...": Direct Lake sees new tables after a while (it retries 30 minutes, `-RefreshRetryMinutes`) | `./scripts/configure-powerbi.ps1` again later; still failing: run `NB_DatabaseHub_LiveActivity` with `SAVE_RESULTS` true, then the script |
| "NB_DatabaseHub_LiveActivity is queued on the capacity (12 of at most 45 minutes)", or `FABRIC.SEMANTICMODEL.REFRESH` **Warning**: "has no tables to read yet" | Nothing: `deploy.ps1` waits (45 minutes, then 45 more) and the end-of-run snapshot retries. Still empty: `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity`, then `./scripts/configure-powerbi.ps1` |
| A Fabric step (`FABRIC.IMPORT.*`, for example) fails with HTTP 401 `TokenExpired`, or "Fabric rejected the token" (Power BI: 403 with `TokenExpired`), after a long wait | `./scripts/deploy.ps1` again; if it stays, `az login` yourself first |
| **History report's snapshot** is **Action needed** or **Failed**, "(doesn't block DONE)": `DEPLOY.FABRIC.HISTORY` **Warning** names a paused capacity, a job still running after 10 minutes, a run already in progress, a failed notebook, or the refresh | Do what it says, then `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity`, or `./scripts/stop-demo.ps1 -SaveHistory` at the session's end |
| **History report's snapshot** is **Skipped** (`DEPLOY.FABRIC.HISTORY` **Not selected**: `-SkipFabric`, `-WhatIf`, GitHub Actions, unpassed telemetry checks, or a missing item; [ADR 0014](adr/0014-notebook-role-and-capacity.md)) | A `deploy.ps1` that passes **DONE**'s checks takes it; or the `configure-fabric.ps1 ... -RunLiveActivity` command above |
| The incident measures are blank right after a deployment (`FABRIC.SEMANTICMODEL.MEASURES` **Warning**) | After incidents run: `./scripts/stop-demo.ps1 -SaveHistory`, then `./scripts/configure-powerbi.ps1 -CheckModelData` |

## The Insights app (Fabric App)

`APP_DatabaseHub_Insights` is in every deployment, and none of its results blocks **DONE** (in `deploy.ps1` a failure is **Manual action required** that doesn't block). More in [its guide](../fabric/app/README.md#troubleshooting).

| Result | Fix |
|---|---|
| The status page shows the app **Failed**, "(doesn't block DONE)", with the record that kept it out | Do what it says, then `./scripts/configure-fabric-app.ps1 -SignIn` (your Azure CLI sign-in; a browser only if Fabric refuses it) |
| `FABRIC.APP.NODE` **Fail**: "Node.js wasn't found on PATH", or too old | Install Node.js 24 LTS (20 and 22 work), then `./scripts/deploy.ps1`; newer is a **Warning** |
| `FABRIC.APP.DEPENDENCIES` **Fail**: "npm ci failed ... in the stage" (`out/fabric-app`) | Let npm reach your registry, then `./scripts/deploy.ps1` |
| `FABRIC.APP.TENANTSETTING` or `FABRIC.APP.EXECUTEQUERIES` **Manual action required**: confirm P12 or P13 (unread), or it "is disabled" | Nothing when the app deploys and queries (it becomes a **Pass**); otherwise a Fabric administrator enables it for the deployer and viewers |
| **Sign-in for the Insights app** is **Skipped**, "Not needed" (`DEPLOY.FABRIC.APPSIGNIN` **Not selected**) | Nothing |
| That row is a **Warning** (the browser sign-in closed, failed, or took over 15 minutes) or **Not supported** (no keyboard input); it starts only after Fabric refused the CLI token in an earlier run (`out/fabric-app-auth.json`) | `./scripts/configure-fabric-app.ps1 -SignIn` in a terminal, as the demo's Fabric user |
| `FABRIC.APP.TOKEN` **Warning**: Fabric refused the Azure CLI's token for `rayfin up` (401 or 403); the app used the CLI's own sign-in, or wasn't created (`signInNeeded`) | If it wasn't created, `./scripts/configure-fabric-app.ps1 -SignIn` once |
| No browser opens, or "The Rayfin CLI can't open its sign-in page with BROWSER" | Nothing: the sign-in drops a `BROWSER` with arguments for the CLI only. For the command `FABRIC.APP.SIGNIN` names, remove `BROWSER` first |
| A browser opens though the CLI is signed in (its read failed or took over 90 seconds) | Sign in again; `./out/fabric-app/node_modules/.bin/rayfin login status` reads it |
| "Page not accessible directly. This page must be opened from an application." (a preview limitation) | Open the app from its workspace item; keep `assetAccess: protected` ([the hosted URL](../fabric/app/README.md#known-limitation-the-hosted-url)) |
| `FABRIC.APP.SIGNIN`, or `FABRIC.APP.DEPLOY` about sign-in, **Manual action required**: the Rayfin CLI's own sign-in, needed after `FABRIC.APP.TOKEN` or with `-RayfinSignIn`, is missing, in another tenant, or lapsed (P14) | `./scripts/configure-fabric-app.ps1 -SignIn`, or the remediation's `./out/fabric-app/node_modules/.bin/rayfin login --tenant <tenantId>` (not `npx`) |
| `FABRIC.APP.DEPLOY` **Not selected**, naming `FABRIC.P5.CAPACITY` | Its administrator resumes the capacity |
| `FABRIC.APP.DEPLOY` fails after a destroy or deleted items: "reusing Rayfin item" | After a destroy, `./scripts/deploy.ps1` (`FABRIC.APP.STAGE` drops old records); otherwise delete `out/fabric-app/rayfin/.deployments.json` first |
| `FABRIC.APP.ITEMS` **Manual action required**: `SM_DatabaseHub_History` isn't deployed | `./scripts/configure-powerbi.ps1` |
| "Fabric refused the query for this account" | Read and Build on the model (a workspace administrator), and P13 on (a Fabric administrator) |
| `FABRIC.APP.QUERIES` **Warning**: empty queries | Run `NB_DatabaseHub_LiveActivity`, and a scenario for the incident visuals |
| `FABRIC.APP.CONNECTOR`: "passed through Power BI's Execute Queries ..." (the direct route refused the Azure CLI's token; [Execute Queries In Group](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group)) | Nothing; a query over its row bound fails as `overflow` |
| `FABRIC.APP.CONNECTOR` **Fail**: "failed on both routes" | 401: `az login --tenant <tenantId>`; 403: Read and Build and P13 for that user; 404: `./scripts/configure-powerbi.ps1`. Then `./scripts/configure-fabric-app.ps1 -CheckOnly` (`-CheckOnly -RayfinSignIn -SignIn` checks with the Rayfin CLI's own sign-in) |
| `FABRIC.APP.CONNECTOR` **Warning**: "The app's queries weren't checked" | `./scripts/configure-fabric-app.ps1 -CheckOnly` after `az login`, without `-FabricToken` |
| `FABRIC.APP.BROWSER` **Not selected**: "Not needed: the app is deployed ..." | Nothing |
| `FABRIC.APP.HOSTING` **Fail**: the assets answered anonymously | `staticHosting.assetAccess: protected` in `fabric/app/rayfin/rayfin.yml`, then deploy again |
| `FABRIC.APP.OPERATORS` **Warning**: "The admin group's members couldn't be read" (Manage is the deployer's only) | Make the deployer a group owner (P6), then `./scripts/deploy.ps1` |
| `FABRIC.APP.ACTIONS` **Warning**: "Manage's function is missing ..." (requests are copied for Run all; [Manage](../fabric/app/README.md#manage-bounded-confirmed-actions)) | `./scripts/deploy.ps1` again: since 2026-11-19 it deploys the app once more after it puts the control notebook in Fabric, a resume included, and `-Sequential` puts the notebook in Fabric first (before, a new environment's first run always left "missing NB_DatabaseHub_Control"; R926). `DEPLOY.CONTROL` says what a notebook that isn't in Fabric still needs |

### Ask, the Copilot chat in the Insights app (2026-11-18)

Ask never blocks **DONE**: its results are **Pass**, **Warning**, or **Not selected**, and the rest of the app works without it ([ADR 0028](adr/0028-ask-copilot-in-the-insights-app.md), [the security model](security-model.md#ask-the-copilot-chat-in-the-insights-app-2026-11-18)).

| Result | Fix |
|---|---|
| `ASK.RELAY` **Warning**: "no relay image is pinned yet" (`askRelay.image` in `config/versions.json` is empty in this copy) | Nothing: `./scripts/deploy.ps1`, which updates itself, deploys the pinned image; users never build it. Your own: `ask.image`, pinned by digest (`<registry>/<repository>@sha256:<digest>`), pullable anonymously |
| `ASK.RELAY` **Warning**: "couldn't pull its image ... without credentials" (a new GitHub Container Registry package can start private, GitHub's default, so a fork's may be; the pinned image's is public), or "its registry has no image with the pinned digest" | Make your `ask.image` public (its **Package settings** > **Change visibility** > **Public**; a public package can't be made private again) or fix its digest, or remove it; then `./scripts/deploy.ps1` |
| `ASK.RELAY` **Warning**: "the Microsoft.App resource provider isn't registered, and registering it failed" | Someone who may: `az provider register --namespace Microsoft.App --subscription <id>`, then `./scripts/deploy.ps1` |
| `ASK.RELAY` **Warning**: "couldn't be deployed", with Azure's error from `infra/ask/ask-relay.bicep` (a policy, a quota, an image Azure can't pull) | Fix it, then `./scripts/configure-fabric-app.ps1`; a policy against public endpoints leaves Ask out by design |
| `ASK.RELAY` **Not selected**: "ask.enabled is false" | Remove `"enabled": false` from `ask`, then `./scripts/deploy.ps1` |
| `ASK.RELAY.HEALTH` **Warning**: "didn't answer within", or "doesn't allow the Insights app's origin" | `./scripts/configure-fabric-app.ps1` again; else the log (`ca-<prefix>-<env>-ask` > Monitoring > Log stream) |
| `ASK.SIGNIN` **Warning**: "GitHub sign-in isn't set up": the relay has no GitHub OAuth App client ID, neither the shared one (`askRelay.githubClientId`) nor your `ask.githubClientId` | `./scripts/deploy.ps1` from this version, or your own OAuth App (device flow, no secret) in `ask.githubClientId` |
| `ASK.CSP` **Warning**: "Enforce a strict content security policy for static-hosted Fabric Apps (preview)" is on | A Fabric administrator turns it off; Ask can't work while it's on |
| `ASK.CSP` **Not selected**: "wasn't read" | Nothing while the dock connects |
| The dock: "Ask isn't deployed here" | Fix `ASK.RELAY`, then `./scripts/deploy.ps1` |
| The dock: "Waking the chat relay" (it scales to zero) | Nothing |
| The dock: "The chat relay didn't answer" (likely the strict policy) | **Try again**; `./scripts/configure-fabric-app.ps1 -CheckOnly` checks without changes |
| GitHub's device page names another region (the relay's) | Nothing: match the code, then **Authorize** |
| **Authorize** stays disabled | Give GitHub's window the focus |
| "This GitHub account can't use Copilot here" | **Switch account** to the one with your Copilot plan; it can differ from your Fabric account |
| The dock names an organization that blocks the app | An owner approves **Database Hub Insights Ask** (Organization settings > Third-party access > OAuth app policy), or authorize it for SAML |
| The sign-in "expired or was revoked" (6 months, revoked, or storage cleared) | **Sign in with GitHub** again |
| It "couldn't be renewed just now" | Ask again in a moment |
| The relay "is at its limit of conversations" (20 at once, `MAX_SESSIONS`; each ends 5 minutes after its last question) | Ask again in a minute |
| Sign-in asked again in another tab or browser | Expected: it's per browser, and the portal's frame is separate |
| An answer says the live estate isn't available: "Database Hub's live view isn't available to the app" (Database Hub refused the app's token, R924), or "didn't answer just now" (the routes timed out or changed) | Nothing: Copilot answers from the history and points to Database Hub's own pages. After "isn't available to the app", that conversation doesn't call the live view again; **New chat** tries again. While Database Hub refuses the app as a whole, a new conversation starts without the live view and the dock hides its live starters, until a page's live read answers. Copilot never gets the routes or their HTTP codes, which stay in the estate function's own log (R925). If it persists, Database Hub's routes may have changed ([ADR 0013's amendment](adr/0013-agent-experience.md#amendment-2026-11-18-the-ga-skill-and-one-narrow-exception)) |
| The dock says "Copilot didn't write an answer": Copilot ended the turn without text after its last query (R925) | **Retry** asks the same conversation to write it; if it happens again, **New chat**. The relay's `chat.turn.end` line for the turn has `finalTextChars` 0, the text after Copilot's last query, as the dock counts the answer ([its logs](../ask-relay/README.md#logs)): `az containerapp logs show --name ca-<prefix>-<environment>-ask --resource-group rg-<prefix>-<environment> --subscription <subscription ID>` |

## The on-demand activity control

Run all in `NB_DatabaseHub_Control`, and the session control behind it (formerly the on-demand activity control; [ADR 0026](adr/0026-one-run-all-session.md)). The job output in `aa-<prefix>-control` (**Jobs**) has the full log and a `DBHUB-CONTROL` line. Every `./scripts/deploy.ps1` republishes its runbooks and notebook, replaces an expired webhook, and grants its roles when you may.

| Result | Fix |
|---|---|
| `DEPLOY.CONTROL` or `CONTROL.ROLE.*` **Warning**; **DONE**: "Until its roles are granted, Run all runs a session without what they allow" (a Contributor's deployment) | An Owner runs `./scripts/grant-safety-stop.ps1` once, which also gives you, who deployed, the control vault's secrets (`CONTROL.ROLE.DEPLOYER`); meanwhile `start-demo.ps1` and `stop-demo.ps1` run sessions |
| "The webhook URL couldn't be read from Key Vault (`<ErrorType>`)": you lack Key Vault Secrets User on `dbhub-activity-webhook` | `./scripts/deploy.ps1` when you may assign roles, else an Owner's `./scripts/grant-safety-stop.ps1`, which covers the environment's deployer (`CONTROL.ROLE.DEPLOYER`) and `control.notebookUserObjectIds` too. A private vault answers only the control's own workspace ("&lt;workspace&gt; Control" by default) |
| `CONTROL.ROLE.DEPLOYER` **Warning** or **Not selected** after `grant-safety-stop.ps1`: the Owner's run couldn't tell who deployed, so only the Owner and `control.notebookUserObjectIds` got the vault's secrets (**Not selected**: a GitHub workflow deployed last; a **Warning**: the vault couldn't be read, or the sign-in name matched no user, or more than one) | The deployer runs `./scripts/deploy.ps1` once more, then the Owner runs `./scripts/grant-safety-stop.ps1` again; or the Owner adds the deployer's object ID to `control.notebookUserObjectIds` and runs it again |
| "HTTP 400: the webhook has expired or is disabled", or "HTTP 404: ... wasn't found" | `./scripts/deploy.ps1` |
| Refused: "Another DbHub-Control job ... is Running", or "A run is active until ..." | **Stop now** (`STOP_NOW = True`, Run all), or wait |
| Refused: "... too soon for a run of at least 5 minutes" (the VMs' auto-shutdown is under 7 minutes away), or naming a field (the request didn't come from the notebook, which checks the same rules first) | Send it from the notebook, at least 7 minutes before the auto-shutdown |
| NoEnvironment: no demo resource group, or A1 isn't granted (`CONTROL.ROLE.A1`) | Deploy it, or an Owner's `./scripts/grant-safety-stop.ps1` |
| Accepted, but no activity: VMs take minutes to start, then telemetry 3 to 15 minutes | Wait; the job's `skipped` list says which target didn't get its profile and why |
| T1 or T2 gets no showcase: `DbHubControl-<vm>-<time>` says "... error=547 ... CHECK constraint 'ck_activity_profile_name'" (an older `ContosoCare`) | `./scripts/stop-demo.ps1` (or Stop now, then wait for both VMs to deallocate), `./scripts/deploy.ps1 -FromStage Artifacts`, then Run all |
| `Host` **Warning**: "... workload runner is older than this session control and refused its activity" (`showcase`, `--tier`, or `--vcores`) | `STOP_NOW = True` and Run all, `./scripts/deploy.ps1`, then Run all |
| Failed: "No activity could be dispatched (...), so this run stopped what it started" | Stop the rest with `STOP_NOW = True` and Run all, or `./scripts/stop-demo.ps1` |
| "archost01 runs a copy restored from the golden snapshot ..., and its Arc identity hasn't been reset yet", or "T2 isn't set up yet" | `./scripts/deploy.ps1` |
| `CONTROL.SETUP` **Manual action required**: "DbHub-Monitor is Missing"; `CONTROL.RUNBOOKS` **Warning**: "`DbHub-Control`: couldn't publish: ..." | `./scripts/deploy.ps1` as someone who can write to `aa-<prefix>-control` |
| The private workspace's notebook is slow to start (no starter pools with a managed private endpoint) | Expected ([why](../fabric/control/README.md#why-it-may-need-a-second-workspace)) |
| `CONTROL.MODE` **Fail** (**Warning** in `deploy.ps1`): `vaultNetworkMode` `public` under a policy that makes vaults private | `auto` or `private`, then `./scripts/deploy.ps1` |
| `CONTROL.FABRIC.NOTEBOOK` **Warning**: capacity inactive, or no Fabric token | `./scripts/deploy.ps1` once the capacity runs |
| `CONTROL.FABRIC.ENDPOINT` **Warning**: the vault's private endpoint request isn't there yet, or "Fabric failed to provision" it | `./scripts/deploy.ps1` again, or approve it in the vault's **Networking** > **Private endpoint connections**; failing every time, delete it in the control workspace's **Network security** > **Managed private endpoints** first |
| `CONTROL.SAFETYSTOP` **Warning**: the daily T4 safety stop "couldn't be scheduled" or "couldn't be linked" | `./scripts/deploy.ps1`; meanwhile `stop-demo.ps1` stops T4 |
| The job API or a pipeline: "An activity can't have ..." or "ACTIVITIES must be a list" | Pass `ACTIVITIES` and `RESET_TARGETS` as JSON text: `[{"target": "T1", "scenario": "cpu-pressure"}]` |
| `skipped` has `T4 (pgflex01-<id> didn't accept the start)`, or Stop now leaves T4 running | `./scripts/stop-demo.ps1`; the message has Azure's reason |
| The VMs deallocated mid-session: an earlier auto-stop was pending (`START.CONTROL.AUTOSTOP`) or its job was still running (`START.CONTROL.STOPJOB`) | `./scripts/start-demo.ps1` once the job ends; to cancel a pending one, delete `dbhub-autostop` (**Shared resources** > **Schedules**); `STATUS.CONTROL` shows it |
| The demo stopped in the middle of a `start-demo.ps1` session: its auto-stop came, 4 hours after the start by default (since 2026-11-19; `START.CONTROL.AUTOSTOP` said when) | `./scripts/start-demo.ps1` again, with `-Hours` for a longer session; running it during a session starts the hours over |
| `START.CONTROL.AUTOSTOP` **Warning**: "The demo doesn't stop by itself after this session": the session control's identity doesn't hold its role at the demo resource group yet (A1), the control isn't set up, or its schedule couldn't be read or written; the start went on | An Owner runs `./scripts/grant-safety-stop.ps1` once (or `./scripts/deploy.ps1` sets the control up), then `./scripts/start-demo.ps1` again; until then, `./scripts/stop-demo.ps1` at the session's end, or the nightly stop |
| `STATUS.RUNCOMMANDS` **Warning**: "managed Run Command(s) are left on the demo VMs: sqlvm01/DbHubControl-sqlvm01-`<time>`" | Nothing: `start-demo.ps1` deletes them (`START.CONTROL.RUNCOMMANDS`, a **Warning** at worst); now: the remediation's `az vm run-command delete` ([az vm run-command delete](https://learn.microsoft.com/cli/azure/vm/run-command#az-vm-run-command-delete)). A `DbHubDemo-*` leftover (not `DbHubDemo-Bootstrap`) goes with its step's next run |
| A `Host` **Warning** in the live view: a deallocated host, "last operation failed (VMStartTimedOut)", an agent not Ready ([above](#a-hosts-vm-agent-that-isnt-ready)), or a failed Run Command; the other targets go on | `STOP_NOW = True` and Run all, then Run all again. "couldn't be kept for the monitoring re-checks": `./scripts/deploy.ps1`, which creates the variable `DbHubSessionStatus` |
| "NB_DatabaseHub_LiveActivity runs as a job in the demo workspace instead ...", then "The history job is queued" | Expected on a small capacity: the Monitor hub shows the job; if it fails, the next Run all saves the history first |

## Workload and scenarios

- **An incident didn't start or won't stop:** the [recovery playbook](demo-walkthrough.md#recovery-playbook); `./scripts/reset-demo.ps1` returns every target to a known state.
- **Reset is Manual action required:** the runner needs `ALTER ANY CONNECTION` and `VIEW SERVER PERFORMANCE STATE` on SQL Server, or `KILL DATABASE CONNECTION` and `VIEW DATABASE STATE` on Azure SQL.
- **Activity stops near the day's end:** every profile ends two minutes before the auto-shutdown.
- **`STATUS.PROFILE_<target>` couldn't read the profile:** the runner failed; the message has its error.
- **`STOP.PROFILE_T2`, `START.PROFILE_T2`, or `STATUS.PROFILE_T2` Not selected, "T2 isn't set up yet":** the next `./scripts/deploy.ps1` finishes T2.
- **"archost01 shows no power state (its last operation failed ...)", or `STOP.VM_ARCHOST01` notes it:** the stop deallocates it at once, since it may still bill ([states and billing](https://learn.microsoft.com/azure/virtual-machines/states-billing)).
- **`WORKLOAD.<target>.BOUNDS` Warning, "couldn't be parsed (a Run Command keeps only the last 4,096 bytes of output)":** `WORKLOAD.<target>.HOST` still reads the host; `Invoke-DemoWorkloadCommand -Target T1 -ArgumentList status, --runs, 3` shows the runs.
- **T4 had no baseline for a while after `deploy.ps1`, or while T1 ran `capacity-max`:** its refused start retries every 30 seconds; a run left Running blocks T4 until its deadline.

## Bastion, the host password, and Key Vault

| Result | Fix |
|---|---|
| `STATUS.BASTION` or `COST.BASTION` **Warning**: Bastion, or a leftover public IP, bills by the hour | `./scripts/stop-demo.ps1 -RemoveBastionOnly`; `COST.BASTION` prints the IP's delete |
| The password rotation is **Manual action required** (the host is deallocated) | Nothing: the next `start-demo.ps1` rotates it |
| `STOP.HOSTPASSWORD` or `DEPLOY.T2.HOSTPASSWORD` **Warning**: not rotated yet | The next `stop-demo.ps1` or `start-demo.ps1` retries; or `archost01` > **Help** > **Reset password** with a random value |
| `START.CLIPBOARD`: no clipboard (Codespaces, Cloud Shell, SSH, Linux without `xclip`, Actions) | **Reset password** in the portal ([reset](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp)); or the [Key Vault opt-in](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard) |
| The opt-in vault's first write is `Forbidden` (a new role takes minutes) | It retries 10 minutes; else run it again |

## The nightly safety stop

Every `deploy.ps1` sets it up. Each evening it deallocates the VMs, stops T4 and a leftover replica, and deletes T5's container ([ADR 0024](adr/0024-nightly-safety-stop.md); [what stops on its own](cost-management.md#what-stops-or-pauses-on-its-own)). `status.ps1` shows `STATUS.SAFETYSTOP`; each job's log is in `aa-<prefix>-<environment>-safetystop` > **Jobs**.

| Result | Fix |
|---|---|
| `SAFETYSTOP.ROLE` **Warning**: "isn't assigned ...", or "the custom role doesn't exist yet ..." | An Owner runs `./scripts/grant-safety-stop.ps1` once (`-ConfigPath` for another configuration); the schedules already exist |
| `SAFETYSTOP.ROLE` **Warning**: "doesn't have exactly its 9 approved actions" (the role is one definition for the whole subscription, and another environment's `deploy.ps1` on older code wrote it back) | An Owner runs `./scripts/grant-safety-stop.ps1` once, or `./scripts/deploy.ps1` as an Owner. Until then the nightly stop can't delete T5's container: run `./scripts/stop-demo.ps1` after each session |
| A job says `NotGranted`: its identity can't read the demo resource group yet | The same, then wait for the next evening |
| `DEPLOY.COST.T4RESTART` **Warning**: "Preflight counted the nightly safety stop ..., but it isn't fully in place ..., so T4's 7-day automatic restart counts the rest of the month again" | An Owner's `./scripts/grant-safety-stop.ps1`; or raise `monthlyCeilingUsd` to the amount named |
| `STATUS.SAFETYSTOP` **Warning**: "isn't in place" (before 2026-11-05, an unfinished run, or a schedule removed) | `./scripts/deploy.ps1` ([alone](#set-the-safety-stop-up-alone)) |
| `STATUS.SAFETYSTOP` **Warning**: "its last run didn't finish its work", or "its last T3 check couldn't stop T4" | The job's line says why; the next evening retries; `./scripts/stop-demo.ps1` stops it all now |
| `STATUS.SAFETYSTOP` **Warning**: "its last run couldn't read or delete T5's container" (its role lacks the container's actions; the VMs and T4 still stopped) | Run `./scripts/stop-demo.ps1` after each session, which deletes it with your rights. An Owner runs `./scripts/grant-safety-stop.ps1` once, or `./scripts/deploy.ps1` as an Owner, which writes the role back |
| A VM is "already deallocating (its auto-shutdown)" | Nothing |
| `STATUS.SAFETYSTOP` **Warning**: "T3 was still online past its auto-pause delay" | Its Resume Databases events say what woke it ([serverless](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-monitor)); `./scripts/stop-demo.ps1` turns profiles off |
| "T3's auto-pause is off" (`t3AutoPauseMinutes` `-1`) | 15 or more, then `./scripts/deploy.ps1 -FromStage Infrastructure` |
| You want the VMs running tonight | Turn off `dbhub-safety-stop` (and `dbhub-safety-deferred`) and the VMs' auto-shutdown; for T4 too, `dbhub-safety-t3check` and `dbhub-t4-safety-stop` in `aa-<prefix>-control` ([every schedule](cost-management.md#what-stops-or-pauses-on-its-own)). The next `deploy.ps1` turns them on again |
| `DEPLOY.NIGHTLYSTOP` **Warning**: "The nightly stop waited for this run ... The demo now stops at 21:35" | Nothing; `./scripts/start-demo.ps1` keeps it running tonight, until its session's auto-stop 4 hours later (`-Hours`), and `./scripts/stop-demo.ps1` stops it now |
| `DEPLOY.ENDSTOP` **Warning**: "The stop at the end of this update didn't stop all of what the run started" (since 2026-11-19): Azure refused part of the update's stop (a VM's deallocation, T4's stop, or T5's container), or it couldn't run; the run is still **DONE**, and tonight's nightly stop stays | `./scripts/stop-demo.ps1` stops what still runs, or the nightly stop does; the status page's **Stop at the end** row and `out/deploy.jsonl` name what failed |
| `DEPLOY.ENDSTOP` **Warning** after `STOP.SESSION`: "The stop at the end of this update ended there, before T2's guest and the VMs", or "But ... started while the stop ran": a session started while the update's stop ran | `./scripts/stop-demo.ps1`, then start the session again (Run all, or `./scripts/start-demo.ps1`) |
| `DEPLOY.ENDSTOP` **Warning**: "deploy.ps1 was stopped (Ctrl+C) during the stop at its end" or "while the stop at its end waited" | `./scripts/stop-demo.ps1` stops the rest now; to demo instead, `./scripts/start-demo.ps1` or Run all; otherwise the nightly stop does |
| After an update, the demo is stopped and you wanted to demo right away (`DEPLOY.ENDSTOP` **Pass**: an update that found the demo stopped leaves it so) | `./scripts/start-demo.ps1`, or Run all; next time, `./scripts/deploy.ps1 -KeepRunning` |
| The **Stop at the end** row says the run waited for T2's first migration assessment, or that it "hadn't uploaded" (the stop waits at most 15 minutes in all) | Nothing: the next `./scripts/deploy.ps1` or `./scripts/configure-arc.ps1` starts it again, and then it runs every week on its own |
| A job's result is `Deferred`: "deploy.ps1 is still running (busy until ...)" (`DbHubBusyUntilUtc`) | Nothing: it stops that night |
| The Nightly stop row: "no step of deploy.ps1 has changed for 60 minutes ..." (or "more than 6 hours") | If nothing moves, stop the run (Ctrl+C) and `./scripts/deploy.ps1` again |
| `STATUS.NIGHTLYSTOP` **Warning**: "The VMs' auto-shutdown is moved ... No run keeps it there" | `start-demo.ps1`, `stop-demo.ps1`, or `deploy.ps1` puts it back at `autoShutdownTime` |
| `START.NIGHTLYSTOP` or `STOP.NIGHTLYSTOP` **Warning**: "not all of it was put back" | Run the script again |

### Set the safety stop up alone

`./scripts/deploy.ps1` sets it up on every run; for just that part, `./scripts/deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure` deploys the template, then the safety stop (its identity, Automation account, `DbHub-Stop`, schedules, and role when you may) and the session control's Azure part. Without the right to assign roles, an Owner runs `./scripts/grant-safety-stop.ps1` once. `SAFETYSTOP.SCHEDULE`'s evidence lists the schedules; `./scripts/status.ps1` shows `STATUS.SAFETYSTOP`.

## Cost

- **Ceilings:** $20 a session (`sessionCeilingUsd`, a **Warning** above it) and $415 a month for a new configuration (`monthlyCeilingUsd`, a hard ceiling: preflight fails above it; a configuration keeps its own value); [cost management](cost-management.md#at-a-glance). `./scripts/estimate-cost.ps1` prices yours.
- **Outside every estimate:** the Fabric capacity ([cost management](cost-management.md#microsoft-fabric-capacity)), Fabric and Power BI licenses, and each viewer's GitHub Copilot plan.
- **A budget alert:** `./scripts/status.ps1` (`STATUS.COST`); usually a forgotten Bastion, an evening start left running, or a T3 profile left on.
- **Long breaks:** `stop-demo.ps1 -RemoveT3` stops T3's Defender and private-endpoint charges; the next start recreates it, and `HUB.AGENT.T3` is needed again.
- **T4 started by itself:** Azure restarts a stopped flexible server after seven days ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)). `STOP.T4.STOP` and `STATUS.T4` say when, what it bills, and what stops it: the nightly safety stop once in place, or the control's daily T4 safety stop. Without either, `./scripts/stop-demo.ps1`, or `./scripts/destroy.ps1` when idle, and fix what `STATUS.SAFETYSTOP` names.
- **T4's read replica, T5's container, Ask's relay** bill only while they're used: the replica and the container exist only during a session ([replica](cost-management.md#dated-example-t4s-read-replica-2026-11-13), [T5](cost-management.md#t5-azure-cosmos-db-2026-11-18)), and the relay scales to zero about 10 minutes after the last question (`"ask": { "enabled": false }` leaves it out). `STATUS.T4.REPLICA` and `T5.CONTAINER` are **Warnings** when one is left; `DEPLOY.T5.LIFECYCLE` says when the container stays.

## Destroy and the residual check

`./scripts/destroy.ps1` deletes what `deploy.ps1` created for this environment, each part only when it can tell it's this environment's; what stays is in [delete everything](../README.md#delete-everything). [Cleanup](cleanup.md#the-residual-check) explains each `TEARDOWN.RESIDUAL.*` check; `destroy.ps1 -ResidueOnly -ManifestPath <file>` runs it again, read-only ([check again later](cleanup.md#check-again-later-read-only)).

| Result | Fix |
|---|---|
| `DESTROY.CONTROL.ROLES` **Manual action required** ("... Failed: ..."), `DESTROY.CONTROL` **Warning**: deleting role assignments needs an Owner or User Access Administrator, with multifactor authentication | One of them runs `./scripts/destroy.ps1` again |
| `DESTROY.FABRIC.WORKSPACE` **Not selected**: "it holds what the demo didn't create: UserDataFunction APP_DatabaseHub_Insights" (a `destroy.ps1` from before 2026-11-19) | `git pull --ff-only`, then `./scripts/destroy.ps1`; or, once nothing uses it, remove the workspace in Fabric (**Workspace settings** > **Remove this workspace**) |
| `TEARDOWN.RESIDUAL.GROUPRESOURCES` or `.ARC` keeps listing rows, often `microsoft.azurearcdata/sqlserverinstances/databases`: Resource Graph lags | Nothing: rows Azure Resource Manager says are gone (404 `ResourceGroupNotFound`, `ResourceNotFound`, `ParentResourceNotFound`) are a **Pass** (`TEARDOWN.RESIDUAL.RECORDS`); a **Warning** after 25 reads: later ([lags](cleanup.md#resource-graph-lags-behind-deletes)) |
| `TEARDOWN.RESIDUAL.ROLEASSIGNMENTS` **Warning**, a scope outside the demo: a tenant policy's (`DeployIfNotExists`) assignment (**Identity not found**, [troubleshooting](https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#symptom---role-assignments-with-identity-not-found)) | That scope's Owner or User Access Administrator removes it ([remove](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-remove)); `destroy.ps1` never does ([tenant policy](cleanup.md#role-assignments-a-tenant-policy-made)) |
| `TEARDOWN.RESIDUAL.ROLEASSIGNMENTS` **Fail**: the demo's own, at the group or for its identities in `rg-<prefix>-control` or `rg-<prefix>-golden` | Someone who can delete role assignments removes it (**Access control (IAM)**) |
| `TEARDOWN.RESIDUAL.TAGGED` **Warning**: "the deploymentId is unknown" | `-ResidueOnly -ManifestPath ./out/destroy-manifest-<environment>.json` ([only this environment](cleanup.md#only-this-environment)) |
| `DESTROY.MANIFEST` **Fail** with `-ResidueOnly`: another environment's manifest (the default path is shared), or unreadable | The environment's own `-ConfigPath` and `-ManifestPath` |
| `validate.ps1 -Area Teardown` **Warning** after destroy (no `-DeploymentId`) | `-DeploymentId <id>` from the manifest, or `destroy.ps1 -ResidueOnly` |

## GitHub Actions

Optional, for maintainers: deploying, sessions, and deleting all run from PowerShell or the notebook. Setup and common problems (enable a fork's workflows; `azure/login`'s subject, `repo:<owner>/<repo>:environment:<name>` ([OpenID Connect from GitHub](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)), and the identity's Contributor; the T3 stage's P6 group ownership; schedules off unless `DBHUB_SCHEDULES_ENABLED` is `true`) are in [deployment](deployment.md#one-click-github-actions).

## Fallbacks at a glance

| Dependency | When it isn't available | Fallback |
|---|---|---|
| Copilot, Database Agents (previews) | Missing or declines; Database Agents covers T3 only ([T3](#t3)) | Ask, then the GA `databasehub-cli` and telemetry skills in GitHub Copilot CLI, the Azure Data Explorer web UI, rehearsal screenshots ([ADR 0013](adr/0013-agent-experience.md), [ADR 0028](adr/0028-ask-copilot-in-the-insights-app.md)) |
| Database Hub UI | Not reachable | Azure Resource Graph (`HUB.ESTATE.*`) and the telemetry endpoint (`TELEMETRY.*`) |
| Notebook `kusto` token | Refused | Printed KQL, and `validate.ps1` |
| Nested virtualization | Not available | The labeled evaluation-only Azure VM, with `ProductKey` or `Developer` |
| Arc Jumpstart's image | Not usable | No automatic fallback: **NOT DONE**; retry, or `ProductKey` or `Developer` ([T2](#t2-arc-jumpstarts-image-jumpstartimage)) |
| T4's size | Refused | Another zone, `Standard_D4ads_v5`, `Standard_D2ds_v5` ([T4](#t4)) |
| T4's read replica's size | Refused | Another zone, then a size with T4's vCores; `start-demo.ps1` runs without it ([replica](#t4s-read-replica)) |
| T5's free tier, T5's account | Taken or refused | List price; or the run without T5 (`DEPLOY.T5`), retried next time ([T5](#t5-azure-cosmos-db)) |
| Ask | No relay, or the strict content security policy | The rest of the app ([Ask](#ask-the-copilot-chat-in-the-insights-app-2026-11-18)) |
| The Insights app's tenant settings | Off | No app; the run still ends **DONE** |
| Azure SQL free offer | Not available | Regular serverless |
| Public SQL endpoint | Denied | Private mode |
| Clipboard for the host password | Codespaces, Cloud Shell, Actions | **Reset password**, or the Key Vault opt-in |
| The Insights app's hosted URL | "Page not accessible directly" | The workspace item |
