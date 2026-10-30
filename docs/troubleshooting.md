# Troubleshooting

Start here when a script reports anything other than **Pass**. For problems in front of an audience, use the walkthrough's [recovery playbook](demo-walkthrough.md#recovery-playbook) instead: it keeps the story moving and defers the fix.

## Read the result first

Every script prints one result per check and writes it as a JSON line to `out/<script>.jsonl`. Every **Fail**, **Warning**, and **Manual action required** carries the exact next step ([ADR 0012](adr/0012-validation-model.md)).

| Status | Meaning | What to do |
|---|---|---|
| **Pass** | A functional check proved it works; deployment success alone never counts | Nothing |
| **Fail** | Broken or missing | Fix what the message names, then run the same script again: every stage is idempotent |
| **Warning** | Works with a caveat, or can't be checked right now, for example on a deallocated VM | Read the message; most clear after `start-demo.ps1` |
| **Manual action required** | No supported automation exists, or a person must decide | Follow the steps in the message, then `deploy.ps1 -Resume` |
| **Not supported** | The chosen configuration can't do it | Pick another option only if you need it |
| **Not selected** | Turned off, or doesn't apply | Nothing |

- `deploy.ps1` collects every open manual item, with its steps, in `DEPLOY.SUMMARY`, and since Phase 28 ends with one banner: **DONE**, or **NOT DONE** with the single next action and the exact command, usually `./scripts/deploy.ps1` again, which continues where it stopped and starts VMs that were stopped.
- `./scripts/status.ps1` is read-only and shows the state of every target; `./scripts/status.ps1 -Watch` shows a running deployment's live progress; `./scripts/validate.ps1` runs the whole catalog, and `-Area` or `-Target` narrows it.
- Exit codes: 0 when nothing failed, 1 for any **Fail**. With `-TreatManualAsError`, **Manual action required** returns 2 from most scripts and 1 from `validate.ps1` (R217). `deploy.ps1` (Phase 28): 0 when **DONE**, 1 when **NOT DONE** with a **Fail**, 2 when **NOT DONE** otherwise; in GitHub Actions it keeps the earlier codes.
- **When a run doesn't finish:** `./scripts/collect-diagnostics.ps1` zips the results, the progress model, the transcripts, and the saved instance views, redacted, for a **Deployment problem** issue ([deployment](deployment.md#diagnostics-collect-diagnosticsps1)).

## Sign-in and the subscription guard

Every script runs the subscription guard (`Assert-DemoAzContext`, check `PREFLIGHT.GUARD.CONTEXT`) before anything is written. Every Azure CLI call, token requests included, names the configured subscription with `--subscription`, and the guard checks that subscription's tenant and account, so **you don't need to change your Azure CLI default subscription, and the scripts never change it**. They also never sign in or out for you ([prerequisites](prerequisites.md#target-subscription-configuration-the-subscription-guard)).

### The guard stops a script

The guard's message names the failed check ([deployment](deployment.md#before-you-start)):

| Check | What it means | Fix |
|---|---|---|
| `account` | The Azure CLI has no sign-in for the configured subscription, has it in another tenant, or reaches it as another account than `azureAccount` | Sign in yourself as the account that runs the demo: `az login --tenant <tenantId>`, and press Enter at the subscription selector for no changes ([sign in at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)). Or correct `azureAccount` in `config/demo.config.json` |
| `canary.arm`, `canary.armRest` | Azure Resource Manager refused the configured subscription for that account | Check the account's role on the subscription: Contributor is the minimum (P1) |
| `canary.armToken`, `canary.fabricToken`, `canary.kustoToken`, `canary.graphToken` | No token without interaction (an expired sign-in or a new multifactor prompt), or a token for another tenant or identity | `az login --tenant <tenantId>` again, as the account that runs the demo |
| `canary.graphOrganization` | Microsoft Graph answered for another tenant | The same: the sign-in is mixed up with another tenant's |
| A **Warning** that names a claims challenge (`graphChallenge` in the evidence) | Microsoft Graph refused the Azure CLI's cached token under Continuous Access Evaluation, for example after a sign-in policy change, and the one fresh token the guard then got was refused too, or the Azure CLI handed back the same token | Nothing stops: the Microsoft Graph checks become **Warnings**. The Azure CLI replaces the token when it expires; to clear it sooner, sign in again yourself as the account that runs the demo, `az login --tenant <tenantId>` ([Continuous Access Evaluation](https://learn.microsoft.com/entra/identity-platform/app-resilience-continuous-access-evaluation)) |
| A **Warning**, not a **Fail** | `azureAccount` isn't set, so the guard can't tell whether the right account is signed in; the evidence names the account it found | Set `azureAccount` to that account |

- **On a shared machine,** a sign-in in the shared Azure CLI profile also changes what other tools and sessions see; prefer the demo's own profile (next section).
- **Every script stopped at once while you changed nothing:** another tool or session that shares your Azure CLI profile signed out, cleared its accounts, or signed in as someone else. (On 2026-10-21, before the guard update, another session's change of the default subscription was enough.) Sign in again as above. Never work around the guard.

### Optional: isolate the demo's Azure CLI sign-in on a shared machine

The Azure CLI keeps its configuration and token cache in the folder that `AZURE_CONFIG_DIR` names, `%USERPROFILE%\.azure` by default ([Azure CLI configuration](https://learn.microsoft.com/cli/azure/azure-cli-configuration)). When other tools or sessions share your user profile, give the demo its own profile, then sign in once in it ([prerequisites](prerequisites.md#optional-a-separate-azure-cli-profile)):

```powershell
$env:AZURE_CONFIG_DIR = Join-Path $HOME '.azure-dbhub-demo'   # this PowerShell session only
az login --tenant <tenantId>                                  # once, as the account that runs the demo
./scripts/status.ps1
```

- This is a user action. The scripts never set `AZURE_CONFIG_DIR` and never sign in.
- Set the same variable in every new session you use for the demo.
- It doesn't apply to Azure Cloud Shell, which signs you in and has its own profile, or to GitHub Actions, where every job signs in on a fresh runner with OpenID Connect.

## Preflight

| Check | Symptom | Fix |
|---|---|---|
| `PREFLIGHT.P1.CONTRIBUTOR` | **Fail**: the caller isn't Contributor on the subscription | A subscription Owner assigns Contributor (P1) |
| `PREFLIGHT.P2.PROVIDERS` | A provider is still registering | Preflight registers missing providers itself; run it again after a few minutes |
| `PREFLIGHT.P3.QUOTA`, `.REGION`, `.ZONE`, `.PREMIUMV2` | No quota, or a size or disk isn't offered | Use a size or region that preflight suggests, or request a quota increase |
| `PREFLIGHT.P3.SECURITYTYPE_T1`, `_T2HOST` | **Warning** | Informational: T1 uses Trusted Launch when its image supports it; the T2 host stays Standard ([ADR 0003](adr/0003-t2-host-size-security-type-bootstrap.md)) |
| `PREFLIGHT.POLICY.SQLPUBLIC` | A tenant policy turns off public access to SQL servers | With `networkMode` `auto`, T3 goes private on its own. An explicit `public` fails; use `auto` or `private` ([ADR 0007](adr/0007-networking-modes-and-egress.md)) |
| `PREFLIGHT.POLICY.INVENTORY` | **Warning**: some policy definitions couldn't be read | Management-group definitions may need Reader there. `auto` then resolves to private. `-SkipPolicyInventory` skips the read (it takes 3–10 minutes in a large tenant, R45c, R215) |
| `PREFLIGHT.POLICY.*` is **Not selected** at the start of a run, then filled in at the end | Phase 28: with `networkMode` `private`, `deploy.ps1` runs the policy inventory beside the deployment instead of before it | Nothing: its results replace the placeholders at the end; one that hasn't finished by then is a **Warning**, and the next run reads it again. The template's what-if still catches a policy denial before anything is created |
| `PREFLIGHT.T4.CAPABILITY` or `PREFLIGHT.T4.SKU` is a **Warning** that names `Standard_B2s` or "finishes without T4" | Phase 28: preflight reads `az postgres flexible-server list-skus` and the refusals on record before anything is created. The region doesn't list `Standard_B1ms` (or either Burstable size), or Azure refused it before | Nothing, when `t4SkuName` isn't set: the run starts with `Standard_B2s`, or finishes without T4 and **DONE** says so. When you set `t4SkuName` yourself, it's a **Fail**: pick a size the region offers, such as `Standard_D2ds_v5` |
| `PREFLIGHT.POLICY.WHATIF` | **Fail**: the template's what-if was denied | The message names the policy; change the option it denies, or ask for an exemption. The demo never changes or exempts a policy |
| `PREFLIGHT.T3.FREEOFFER` | **Warning**: the Azure SQL Database free offer isn't available | Expected when the subscription already has 10 free databases, or has free databases in another region: the first free database fixes the region ([free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer)). In the owner's subscription the free databases are in East US, so a West US 3 T3 uses regular serverless. Nothing to fix; the estimate prices T3 that way |
| `PREFLIGHT.P6.GROUP` | You don't own the T3 administrators group | Own the group (P6), or use the fallback in [permissions](permissions.md#t3-administration-options) |
| `PREFLIGHT.COST.MONTHLY` | **Fail**: a light-use month is above `monthlyCeilingUsd` | Pick a cheaper profile or option, or raise the ceiling on purpose ([cost management](cost-management.md)) |
| `PREFLIGHT.COST.SESSION` | **Warning**: a session is above `sessionCeilingUsd` | Shorter sessions, or `-ParkT2` for sessions that don't need T2 |
| `PREFLIGHT.COST.DEFENDER` | **Warning**: Defender for Cloud plans weren't read | The guard didn't pass, so the estimate excludes Defender; sign in and run it again |

## Deployment

| Symptom | Likely cause | Fix |
|---|---|---|
| A template deployment is denied | A tenant policy; the error names it | Change the option the policy denies. Preflight's what-if usually catches this first |
| `T3.FREEOFFER` **Warning** after the Infrastructure stage | Azure rejected the free offer at deployment | Nothing: `deploy.ps1` deployed T3 again as regular serverless |
| A Run Command waits with **Conflict** for several minutes | A policy-installed extension, such as an `MDE.Windows` update, holds the VM (R49) | The scripts retry for about 12.5 minutes and name the cause. Since Phase 28 the tracks also wait for the VM's extensions to settle first, and a watchdog restarts a stuck VM once ([Run Commands stuck in Deleting](#run-commands-stuck-in-deleting)). If it still fails, run `deploy.ps1` again later |
| `OperationNotAllowed` on a VM | The VM is deallocated, for example by the nightly auto-shutdown | `./scripts/start-demo.ps1`, then run the stage again |
| `OperationNotAllowed`: "Managed disk storage account type change through Virtual Machine ... is not allowed" (`DEPLOY.TEMPLATE`) | The subscription's automation switched the VM's OS disk to another type (Standard HDD, seen 2026-10-24) while it was deallocated, and a `deploy.ps1` from before Phase 24 asked for the profile's type | Phase 24's `deploy.ps1` keeps each drifted disk's current type and reports the `DEPLOY.DISKS.DRIFT` **Warning**; `status.ps1` shows it as `STATUS.DISKS`. Don't change the disk back unless the subscription owner agrees ([change a disk's type](https://learn.microsoft.com/azure/virtual-machines/disks-convert-types)) |
| `DEPLOY.T4.SKU` or `PREFLIGHT.T4.SKU` **Fail**: `SkuNotAvailable` ("Specified SKU is not supported in this region") for `pgflex01-<deploymentId>` | Azure won't create T4 at the configured size in the region now, even though the region's capability list includes it (seen for `Standard_B1ms` in West US 3, 2026-10-26) | **Since Phase 28, only a size you set is a Fail:** without `t4SkuName` in your configuration, the run moves to `Standard_B2s` by itself, and when that's refused too, it finishes without T4 (`DEPLOY.T4.SKU` **Warning**), and **DONE** says T4 isn't deployed and why ([deployment](deployment.md#t4s-size-the-burstable-fallback-phase-28)). For a size you set: set `t4SkuName` to `Standard_B2s`, the documented fallback (about four times B1ms's hourly list price; `estimate-cost.ps1` prices it), or set `t4AvailabilityZone` to another zone for one more try; then run `deploy.ps1` again. When B2s is refused too (as on 2026-10-26), `Standard_D2ds_v5` is the documented General Purpose option (about ten times B1ms's hourly price, with a 7-day restart worst case near $128 a month), or file a Region access request and set `t4Enabled: false` meanwhile ([capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors)) |
| A Run Command result is reported as stale | Azure returned the previous run's result for a recreated Run Command (R73) | Handled: the scripts retry once, then fail closed. Run the stage again |
| `INFRA.BOOTSTRAP.LOADER_<vm>` is a **Fail** | The bootstrap loader stopped: a chunk or bundle hash mismatch, or a file it couldn't write | Read the message, then `deploy.ps1 -FromStage Artifacts` sends the bundle again. A **Warning** right after a restart can be a loader that's still Pending (R219) |
| `Get-DemoVmHealth` shows a step that failed | The VM's state machine stops retrying a failed step within one generation | Read the logs (`Get-DemoVmHealth -View Full`), fix the cause, then run `deploy.ps1 -FromStage Artifacts`, which starts a new bootstrap generation that re-checks every step |
| `DEPLOY.T1.READY` or `DEPLOY.T2.READY` **Fail**: "Step WorkloadRunner failed ... setup --target T*n*: Fail. 3 scenario procedure(s) are missing." | A runner from before Phase 25d checked a naming convention instead of the procedure each scenario names, so three of Phase 25b's scenarios failed setup on every target, although their procedures existed (live, 2026-10-27) | Deploy this version (`deploy.ps1 -FromStage Artifacts`): its setup checks each scenario's own procedure and names any that's really missing. `DEPLOY.T2.READY` is new in Phase 25d: before it, the T2 track could pass while its host had failed this step |
| The T2 host's `DataDisk` step fails on free space | `lowest-cost` keeps the guest on the host's 128 GiB OS disk, which needs about 80 GB free (R51) | Set `dataDiskSku` to `E10` and deploy again |
| A media download fails its SHA-256 check | Microsoft changed the file behind a pinned URL (R53) | Update the pin in `config/versions.json` after you've checked the new file's source |
| The host reports "The processor does not have required virtualization capabilities" | Nested virtualization isn't available for that size or region | Pick another nested-capable size, or opt in to the labeled evaluation-only fallback (`t2Mode` `EvaluationOnlyAzureVm`, [ADR 0006](adr/0006-sql-editions-and-licensing.md)) |
| The first deployment runs much longer than later ones | Expected: most of it is the T2 guest build, including about 6.2 GB of media | See [a first run that's slow or doesn't finish](#a-first-run-thats-slow-or-doesnt-finish); `./scripts/deploy.ps1` continues after an interruption ([expected duration](deployment.md#expected-duration)) |

## A first run that's slow or doesn't finish

Two colleagues' first runs took more than 2 hours and never finished (2026-10-29). Phase 28 changed what caused it ([deployment](deployment.md#one-command-one-guided-stop-phase-28)); this is what to expect now, and what to do.

- **How long is normal:** about 2 to 3 hours for a first run in `PaygWizard` mode, an estimate from documented step times: the T2 guest build alone is 60 to 90 minutes, and a person is needed once, about 60 to 90 minutes in, for about 10 minutes. `ProductKey` and `Developer` need no person (about 1.5 to 2.5 hours). A redeploy from a golden snapshot takes about 30 to 45 minutes.
- **Where it is now:** the status page, `out/deploy-status.html`, or `./scripts/status.ps1 -Watch` in a second terminal. **Deploying, no action needed** with a step that's **Running** is progress, even when it's slow; a message that says "Azure-side, no action needed" is Azure's work, not yours.
- **The page says "Stopped, not done" and that `deploy.ps1` stopped updating it:** its window closed, or the PC slept or restarted. Run `./scripts/deploy.ps1` again; it continues where it stopped, from the resource group's state, with no flag.
- **A rerun failed with "...can't run, because the VM isn't running (deallocated or stopped)":** before the Phase 28 live finding's fix, `deploy.ps1` didn't start VMs that the nightly auto-shutdown or `./scripts/stop-demo.ps1` had deallocated. Now it starts them while preflight runs, and T4 when it's stopped ([deployment](deployment.md#one-command-one-guided-stop-phase-28)). When one still doesn't start, the run ends **NOT DONE** with `DEPLOY.VMSTART`: start it in the portal, or run `./scripts/start-demo.ps1`, then `./scripts/deploy.ps1` again. A VM started for a run whose preflight then failed keeps running until `./scripts/stop-demo.ps1` or the auto-shutdown, and `DEPLOY.VMSTART` says so.
- **Ctrl+C didn't stop it:** before the Phase 28 live finding's fix, a Ctrl+C at the guided stop waited, with nothing on the screen, for the T2 track's own cleanup (minutes of Azure calls), and a second Ctrl+C couldn't interrupt that. Now it stops within seconds, its track processes too, and ends **Stopped, not done** with the command that continues ([deployment](deployment.md#one-command-one-guided-stop-phase-28)). On a run started from an older checkout, end `deploy.ps1`'s process and its `pwsh -s -NoLogo -NoProfile` track processes by their process IDs (`Stop-Process -Id`), then run `./scripts/stop-demo.ps1` if it stopped at the guided stop, which removes Bastion and rotates the host password.
- **NOT DONE says the guided stop's on-demand Bastion, or the T2 host's password, is still open (`DEPLOY.T2.GUIDEDLEFTOVER`):** a guided stop's cleanup didn't finish, for example after a Ctrl+C at the guided stop, or a host password that a guided stop or `start-demo.ps1 -Interactive` handed over isn't rotated. The T2 step tries the cleanup itself, even when setup finished meanwhile; this appears when Bastion couldn't be removed or the password couldn't be rotated. Run `./scripts/stop-demo.ps1 -RemoveBastionOnly`, which removes Bastion and rotates the password and leaves the VMs running, then `./scripts/deploy.ps1` again to see **DONE**. Before the Phase 28 review's fix, a run after such a Ctrl+C could end **DONE** with Bastion still up and the password still valid.
- **The PC went to sleep:** `deploy.ps1` keeps a Windows PC awake while it runs, but a closed lid, a shutdown, or another operating system still stops it. Plug in, keep the lid open, then run it again.
- **A codespace stopped in the middle:** it stops after its idle timeout (30 minutes by default). Raise it in **Settings** > **Codespaces** > **Default idle timeout** (up to 240 minutes, for codespaces you create afterward; [GitHub Docs](https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces)), restart the codespace, and run `./scripts/deploy.ps1` again.
- **Preflight took 7 to 13 minutes:** its first policy inventory, with `networkMode` `auto`, which needs it before anything is created, or `public`, where a policy that turns SQL public access off must stop the run first. With `private`, `deploy.ps1` runs it beside the deployment instead; a later run reuses its cache (`-PolicyCacheHours`).
- **It waited a long time before the bootstraps:** Azure finishing extensions that your tenant's policies install on a new VM, or Run Commands stuck in `Deleting` ([below](#run-commands-stuck-in-deleting)).
- **It ended NOT DONE:** run the command in the banner. If the same thing happens again, run `./scripts/collect-diagnostics.ps1` and open a **Deployment problem** issue with the zip.

## Run Commands stuck in Deleting

| Symptom | Likely cause | Fix |
|---|---|---|
| The status page says "Azure is finishing `<extension>` on `<VM>` (installed by a policy in your tenant); no action needed" | On a new VM, Azure Policy installs or updates extensions (`MDE.Windows`, Guest Configuration, Defender for SQL, the Azure Monitor agent), and until they finish, the VM agent doesn't process Run Command changes (R49, R336) | Nothing: the track waits up to 20 minutes for them before the VM's artifacts and before its loader, reading the VM's instance view ([az vm get-instance-view](https://learn.microsoft.com/cli/azure/vm#az-vm-get-instance-view)) |
| `DEPLOY.WATCHDOG_<VM>` is a **Warning**: the VM "was restarted automatically" | That wait, the chunks, or the loader stayed stuck for about 15 to 20 minutes, so the watchdog saved the VM's instance view to `out/diagnostics` and restarted the VM once ([az vm restart](https://learn.microsoft.com/cli/azure/vm#az-vm-restart)); deallocating and starting a VM once cleared a long block (R336) | Nothing: the run went on. The T2 host isn't restarted while its guest may be in the guided stop, while the golden Release runs on it, or while its guest build may be running, which the deployment state shows without asking the host's agent (`DbHubT2BuildUtc`: its loader started a bootstrap generation that hasn't been seen to finish); the watchdog's **Warning** then says why. If it happens on every run, an extension that a policy installs may be failing on the VM: ask your Azure administrator |
| `DEPLOY.EXTENSIONS_<VM>` is a **Fail**, and the run ended **NOT DONE**, naming an extension | It was still stuck after the restart | Wait 15 to 30 minutes, then run `./scripts/deploy.ps1` again; it continues where it stopped. If the same extension stays stuck, ask your Azure administrator about it (often a policy installs it), and attach `./scripts/collect-diagnostics.ps1`'s zip, which holds the saved instance view |
| `DEPLOY.ARTIFACTS.CLEANUP_<VM>` is a **Warning**: Azure was still deleting chunk Run Commands | The chunks' deletes weren't waited for (Phase 28); Azure finishes them on its own | Nothing: they don't block the loader, since a VM allows 25 managed Run Commands ([managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)), and the next run's cleanup checks again. If they stay for hours, `az vm run-command list --resource-group <group> --vm-name <vm>` shows them, and `az vm run-command delete` removes one ([az vm run-command](https://learn.microsoft.com/cli/azure/vm/run-command)) |
| `DEPLOY.ARTIFACTS.STALL_<VM>` is a **Warning**: the rest went one at a time | No chunk finished for 5 minutes while several ran | Nothing: one at a time gets through a busy agent |
| A run from before Phase 28 sat for up to 24 minutes on chunk deletes, then on the loader | Each chunk's delete waited up to 3 minutes for Azure, 8 chunks at a time, and the loader queued behind the same blocked extension work | Update to this version and run `./scripts/deploy.ps1` again |

## T2: the setup-wizard step

In the default `PaygWizard` mode, the T2 host stops once per guest build at **Manual action required**, step `SqlSetupWizard`. That's by design: pay-as-you-go SQL Server without a product key is documented only in the setup wizard ([ADR 0006](adr/0006-sql-editions-and-licensing.md)). Since Phase 28, `deploy.ps1` guides it ([the guided stop](deployment.md#the-guided-stop-paygwizard)); [the `PaygWizard` manual step](deployment.md#the-paygwizard-manual-step-validated-live-2026-10-21) is the by-hand path.

| Symptom | Likely cause | Fix |
|---|---|---|
| The status page says **Waiting for you**, but the browser didn't open | GitHub Codespaces, `-NoBrowser`, or a session without a browser | Open the portal link from the console or the status page, or the Azure portal at `archost01`, then **Connect** > **Bastion** |
| You don't have the host's password | No working clipboard (GitHub Codespaces, Cloud Shell, an SSH session, or Linux without a desktop and `xclip`) and no Key Vault opt-in, so nothing was set or shown (`DEPLOY.T2.HOSTPASSWORD`) | In the Azure portal, open `archost01`, then **Help**, then **Reset password**, keep the user name, and type a password of your own choosing ([reset a password](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp)); then sign in through Bastion with it. It's rotated after the guided stop |
| Virtual Machine Connection to `arcsql01` didn't open after the Bastion sign-in | The host's logon task opens it at your sign-in; a sign-in that started before the task was ready misses it | Sign out of the host and in again, or open Hyper-V Manager and connect to `arcsql01` |
| The guest shows its sign-in screen instead of setup | The guest's automatic sign-in hasn't happened yet: it restarts first, about 2 minutes | Wait. After 3 tries the host stops arming it and its message says how to sign in by hand (`C:\ProgramData\DbHubDemo\Copy-GuestCredential.ps1` copies the password) and open the pre-filled setup (`C:\DbHubDemo\setup\Start-GuidedSetup.ps1`) |
| The host's message, on the console and the status page, says the setup check found a problem, with **Fix:** | Setup installed something other than pay-as-you-go Standard as the default instance with the Azure extension: Evaluation or Developer, a named instance, or no Azure extension | Follow the fix it gives (setup's documented [edition upgrade](https://learn.microsoft.com/sql/database-engine/install-windows/upgrade-downgrade-sql-server-edition-setup) to pay-as-you-go Standard, or [uninstall](https://learn.microsoft.com/sql/sql-server/install/uninstall-an-existing-instance-of-sql-server-setup) and install again). Nothing wrong is onboarded; the run keeps waiting and checks again |
| `DEPLOY.T2.GUIDEDSTOP` is **Manual action required**: nobody finished setup by the time limit | The run waits at least 45 minutes after it asks | Run `./scripts/deploy.ps1` again when you have about 15 minutes: it opens Bastion and guides you again. The guest's automatic sign-in was already turned off |
| `STATUS.T2.AUTOSIGNIN` is a **Warning** | The guest's one automatic sign-in is still armed while no guided stop waits, or its last cleanup didn't finish | Nothing while `archost01` runs: its next pass, within about 5 minutes, turns it off, deletes the LSA secret and the Winlogon values, rotates the guest password, and signs the console out. `./scripts/check-sign-in-data.ps1 -Clean` removes them too |
| `SECURITY.SIGNIN.<VM>` or `GOLDEN.CAPTURE.SIGNIN` is a **Fail** that names automatic sign-in | Automatic sign-in is on, or its LSA secret or the Winlogon `DefaultUserName` or `DefaultPassword` value is left in the guest (fail closed; no golden snapshot is captured) | `./scripts/check-sign-in-data.ps1 -VmName archost01 -Clean` turns it off and deletes them, then scans again |
| The **Use Azure Login** window is blank | The WebView2 runtime is missing in the guest; Windows Server 2022 doesn't include it | The host's `GuestWebView2` step installs it before the wizard. On a host whose bundle predates that step, install the standalone runtime by hand as the deployment guide describes |
| **Next** fails with "requires all input values for AZURESERVICEPRINCIPAL" | Pay-as-you-go keeps the Azure extension selected, and the page needs a sign-in | Select **Use Azure Login** and sign in with your own account. **Never enter a service principal secret** |
| Sign-in says "There was an issue looking up your account" | Seen once on the first attempt (2026-10-21) | Select **Next** again |
| `T2.ARC.SQLEXTENSION` stays **Warning** (Creating) long after setup | The guest's extension downloads from `<region>.his.arc.azure.com` fail intermittently with "certificate verify failed", and the agent retries about every 6 minutes (R72) | Wait, then run `./scripts/configure-arc.ps1` again; it converges the license type and monitoring |
| `T2.ARC.SQLEXTENSION` is a **Warning** (Updating) right after `configure-arc.ps1` | The extension is applying the PAYG license type | Run `configure-arc.ps1` again a few minutes later |
| You worry about sign-in data from setup's Azure Login | Setup's interactive sign-in can leave sign-in data on the VM (R74) | The host's `GuestSignInCleanup` step removes it right after the wizard and verifies that none remains; the build fails if any remains. Check any time with `./scripts/check-sign-in-data.ps1` (counts and locations only, never a value); `-Clean` removes what it finds. See the [security model](security-model.md) |
| `SECURITY.SIGNIN.<VM>`, `T2.ARC.ONBOARDING`, or `GOLDEN.CAPTURE.SIGNIN` is **Manual action required**: "The Security log holds token-shaped value(s)" | Process-creation auditing with command lines is on, and a command line held a token, such as the caller's Arc token on the host. The scripts never clear the Security log on their own, because that erases the audit trail | After your security team has what it needs, run the command in the result: `./scripts/check-sign-in-data.ps1 -VmName <vm> -Clean -ClearSecurityLog`, or `wevtutil clear-log Security` in an elevated prompt on the VM |
| `SECURITY.SIGNIN.<VM>` or `T2.ARC.ONBOARDING` is a **Warning**: "the cleanup cleared Windows PowerShell" | A PowerShell or Application event log held a token-shaped value, so the cleanup cleared that log. Endpoint protection may raise an alert for a cleared event log | Expected without the host identity: the Windows PowerShell log records the onboarding script's command line, which carries your token. Tell your security team, or onboard with the host identity (`assignRoles: true`) |

## T2: Arc and the guest

| Symptom | Likely cause | Fix |
|---|---|---|
| `T2.ARC.CONNECTED` is a **Warning** (Disconnected) | The host is deallocated, so the guest is off | Expected while stopped; it reconnects after `start-demo.ps1` |
| `T2.ARC.DISCONNECTEDDAYS` is a **Warning** at 21 days or a **Fail** above 30 | The host stayed off for weeks; pay-as-you-go lapses after more than 30 days disconnected ([Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq)) | Start the host and run `configure-arc.ps1` before day 30. After the lapse, rebuild T2 |
| `T2.ARC.NODUPLICATES` is a **Fail** | An Arc machine from an earlier guest build is still there | `configure-arc.ps1` deletes the stale SQL Server instance resources, then the machine, then onboards again (ADR 0005) |
| `T2.ARC.ONBOARDING` is a **Fail**: `azcmagent connect failed with exit code 26` and `lookup management.azure.com: no such host` | The guest's only DNS server, the host's DNS Server on `192.168.200.1`, isn't listening. Before the Phase 16 fix, the host could restart it while that new address was still tentative, and it never bound the address (DNS Server events 404, 407, and 408 on `archost01`) | Restart the host (`stop-demo.ps1`, then `start-demo.ps1`), then `deploy.ps1 -Resume`. With the fix, the `DnsForwarder` step waits for the address, confirms the listener, and fails instead of converging without it |
| The guest's Windows Server evaluation is near its 180-day end | The guest was built from evaluation media ([ADR 0006](adr/0006-sql-editions-and-licensing.md)) | `status.ps1 -Detail` shows the days left; in the guest, `slmgr /dlv` shows the expiry ([Slmgr.vbs options](https://learn.microsoft.com/windows-server/get-started/activation-slmgr-vbs-options)). Rebuild before it ends: `reset-demo.ps1 -RebuildGuest` reports **Not supported**, so the path is `destroy.ps1`, then `deploy.ps1`, then the wizard step again. Get the owner's approval before any destroy |

## T1

| Symptom | Likely cause | Fix |
|---|---|---|
| `T1.SQLVM.MONITORING` is a **Fail** or **Warning** right after a template deployment | The SQL IaaS Agent extension shows `Updating` for a while after a redeployment | Wait. The Monitoring stage of `deploy.ps1` waits up to 20 minutes; the monitoring flag survives the redeployment |
| `DEPLOY.T1.MONITORING` appears after the Monitoring step, or `T1.SQLVM.MONITORING` stays a **Warning** with `{"State":"NotRunning"}` after a deployment | The deployment's template run left the plugin NotRunning, and waiting doesn't bring it back (live, 2026-10-27: NotRunning from 14:11 to 14:45 UTC, no T1 telemetry) | Since Phase 25d, `deploy.ps1` restarts the SQL IaaS Agent service when the wait ends that way and reports `DEPLOY.T1.MONITORING` (live: Running with uploads OK 166 seconds after the restart). With an older module, `start-demo.ps1` or `./scripts/configure-monitoring.ps1 -WaitMinutes 15` does the same |
| `T1.SQLVM.MONITORING` is a **Warning** that says to start the VM | `sqlvm01` is deallocated, so its extension status is empty | `start-demo.ps1` |
| `START.T1.MONITORING` is a **Warning** ("still reports DatabaseMonitorArcPlugin: {"State":"NotRunning"} 5 minutes after the SQL IaaS Agent service was restarted"), then `TELEMETRY.T1` is a **Fail** | The plugin didn't come up after the restart. On 2026-10-26 the restart ran right after the guest booted, before the plugin had reported a status (R442); since Phase 25b, `start-demo.ps1` first waits up to 5 minutes for that status | Run `start-demo.ps1` again a few minutes later: it repeats the check and the restart (live: Running with uploads OK in 144 seconds, telemetry within a minute), or `./scripts/configure-monitoring.ps1 -WaitMinutes 15`; `validate.ps1 -Area Telemetry -Target T1` confirms |
| `METRICS.T4` or `DEPLOY.TRACK.T4` **Fail**: "An Azure CLI argument contains '"' or '%', which cmd.exe can't pass to az.cmd unchanged" | A module from before the fix put T4's Metrics - List query string, with encoded characters, on the az.cmd command line (live, 2026-10-26) | Update to this version: the query parameters go in a file (`az rest --url-parameters @<path>`) |
| `T1.SQLVM.ASSOCIATEDSERVICES` is a **Warning** | Unified inventory still lists the image's Analysis Services or Integration Services | T1's `AssociatedServices` step stops, disables, and uninstalls them. Inventory drops them a few minutes later, after a restart of the SQL IaaS Agent service |
| A T1 health **Warning** about sysadmin | SYSTEM wasn't a sysadmin on the image | Handled: the bootstrap used the documented recovery and made BUILTIN\Administrators a sysadmin |

## T3

| Symptom | Likely cause | Fix |
|---|---|---|
| T1 can't sign in to T3 during the T3 stage | T1's new membership in the P6 group hasn't applied yet; managed identity tokens are cached for up to about 24 hours (R80, R87) | The stage retries for 10 minutes, then reports a **Warning** with the measured wait. Run `deploy.ps1 -FromStage T3` later |
| T3 checks are **Warning** and say T3 was removed | `stop-demo.ps1 -RemoveT3` deleted it | `start-demo.ps1` recreates it under the same names |
| A recreate fails because the name is taken | A deleted server's name isn't released yet (R83) | Wait a few minutes and run `start-demo.ps1` again |
| T3 doesn't auto-pause | An activity profile keeps sessions open (R183) | `stop-demo.ps1` sets every profile to `off`; T3 pauses `t3AutoPauseMinutes` after its last session |
| A paused T3 started billing compute | Validation's T3 checks through T1 and `reset-demo.ps1` connect to T3, which resumes it (R222) | Expected; it auto-pauses again after `t3AutoPauseMinutes` |
| T3 shows fresh telemetry while it reports `Paused` | Seen live on 2026-10-21 (R213) | A fresh sample doesn't prove T3 is awake; the readiness gate also checks the extended property |

## Database Hub and telemetry

| Symptom | Likely cause | Fix |
|---|---|---|
| `TELEMETRY.<target>` is a **Warning** with no recent rows | Telemetry arrives 3–15 minutes after the activity; or the VM is deallocated, or T3 is paused | Wait, or start the demo. `Test-DemoHubTelemetry -Target T1, T2, T3 -WaitMinutes 15` reports rows, the newest sample, and the lag |
| `HUB.ESTATE.T2` or `TELEMETRY.T2` is **Manual action required** | The T2 setup-wizard step is still open | Do the wizard step, then `configure-arc.ps1` and `configure-monitoring.ps1 -Target T2` |
| Database Hub doesn't load, or shows nothing | The tenant setting (P4) is off, My workspace is on a capacity in North Europe or West Europe, or the user lacks Reader on the subscription | A Fabric administrator checks P4 (`configure-fabric.ps1 -FabricAdmin`); presenters need Reader (P8) ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)) |
| `FABRIC.P4.HUBSETTING` is **Manual action required** | No documented API reads the setting without Fabric administrator rights | Confirm the setting in the Fabric admin portal, or have an administrator run `configure-fabric.ps1 -FabricAdmin` |
| The Database Agent or Copilot pane isn't there, or declines a target | Preview: its coverage, entry point, and latency aren't documented | Use the [fallback ladder](demo-walkthrough.md#the-ladder), and record what you saw in the [live coverage record](../fabric/agent/README.md#live-coverage-record) |

## Fabric notebooks

| Symptom | Likely cause | Fix |
|---|---|---|
| The import or a run fails with HTTP 404 `CapacityNotActive`, and the result is **Manual action required** | The workspace's F capacity is paused | A capacity administrator resumes it ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)). Resuming also resumes billing, so pause it again when no workspace needs it. The demo never pauses, resumes, or scales the capacity |
| A notebook job is rejected with "Not supported language" | The notebook metadata lacks `language_info.name` | Fixed in Phase 12: import the notebooks from a branch that has the fix with `./scripts/configure-fabric.ps1` |
| `HUB.TELEMETRY.TOKEN` isn't **Pass** | The telemetry endpoint didn't accept the notebook's `kusto` token; that path is undocumented, though it passed on 2026-10-21 | Each query prints its KQL for the Azure Data Explorer web UI, and `validate.ps1` runs the same checks with an Azure CLI token |
| `FABRIC.P5.WORKSPACE` isn't **Pass** | You lack Contributor on the workspace (P5) | A workspace administrator adds you |
| `FABRIC.SEMANTICMODEL.REFRESH` is a **Fail** with 0xC14700DF, "one or multiple source tables either do not exist or access was denied", after a first deploy into a new lakehouse | Direct Lake doesn't see tables that a notebook has just created for a while: about 20 minutes in a new workspace on 2026-10-27, after which the same refresh passed. `configure-powerbi.ps1` already refreshes again every 2 minutes for 30 minutes (`-RefreshRetryMinutes`) | Wait a few minutes and run `./scripts/configure-powerbi.ps1` again. If it still fails, the tables it names are missing: run `NB_DatabaseHub_LiveActivity` with `SAVE_RESULTS` true, then the script |

## The Insights app (Fabric App)

The app's own guide has more ([fabric/app](../fabric/app/README.md#troubleshooting)).

| Symptom | Likely cause | Fix |
|---|---|---|
| `deploy.ps1`'s status page shows the Insights app **Skipped**, with a reason | The optional app wasn't added; the page names the first record that kept it out, such as `FABRIC.APP.SIGNIN`, and in `deploy.ps1` none of its records is ever a **Fail** (Phase 28 live finding: the page had shown a **Fail** with a generic word about tenant settings that were on, after the app's own lookup of a workspace created moments before failed) | Do what the reason says, then run `./scripts/configure-fabric-app.ps1 -SignIn`. The demo is **DONE** without the app. Since the fix, `deploy.ps1` gives the app the workspace its Fabric step resolved or created (`-WorkspaceId`), so the app doesn't look it up by name again |
| The browser shows "Page not accessible directly. This page must be opened from an application." | The hosted URL was opened directly: the Fabric Apps host's sign-in pop-up loses its link back to the tab (a preview limitation, seen on 2026-10-22 even in an InPrivate window signed in as the demo admin) | Open the app from its item in the Fabric workspace; it runs embedded and signs in by itself. Keep `assetAccess: protected` ([the evidence](../fabric/app/README.md#known-limitation-the-hosted-url)) |
| `FABRIC.APP.SIGNIN` is **Manual action required** | The Rayfin CLI isn't signed in, or is signed in to another tenant (P14) | Run the one-time command in the remediation, `npx --yes --package=@microsoft/rayfin-cli@<version> -- rayfin login --tenant <tenantId>`, as the demo's Fabric user, then run `configure-fabric-app.ps1` again |
| `FABRIC.APP.DEPLOY` is **Manual action required** and mentions sign-in | The CLI's cached session lapsed and couldn't renew silently | Sign in again with the same command |
| `FABRIC.APP.DEPLOY` is **Not selected** and names `FABRIC.P5.CAPACITY` | The workspace's capacity isn't Active; `rayfin up` would start a trial or assign one | The capacity administrator resumes it; the script never does |
| `FABRIC.APP.ITEMS` is **Manual action required** | `SM_DatabaseHub_History` isn't deployed | Run `./scripts/configure-powerbi.ps1` first |
| A visual says "Fabric refused the query for this account" | The viewer lacks Read and Build on the model, or the Execute Queries tenant setting (P13) | A workspace administrator grants the permissions; a Fabric administrator enables the setting |
| `FABRIC.APP.QUERIES` is a **Warning** naming empty queries | The lakehouse has no history for that window yet | Run `NB_DatabaseHub_LiveActivity`, and a scenario for the incident visuals |
| `FABRIC.APP.HOSTING` is a **Fail** | The hosted assets answered an anonymous request | Set `staticHosting.assetAccess: protected` in `fabric/app/rayfin/rayfin.yml` and redeploy |
| `SECURITY.SECRETSCAN.OUTPUT` is a **Fail** after the app's deployment, and `validate.ps1 -Area Security` takes 20 minutes or more | The output scan reads all of `out/`, including the app's deploy stage, `out/fabric-app`, whose `node_modules` holds tens of thousands of third-party files; some of them match the secret patterns, such as the example `Bearer` challenges in the Azure SDK's code comments and an account-key pattern in a package's `docker-compose.yml` (Phase 22, 2026-10-23) | Matches under `out/fabric-app/node_modules` are third-party code, not the demo's output. Scan everything else in `out/` after `Import-Module ./scripts/modules/DbHubDemo/DbHubDemo.psd1`: `(Find-DemoSecretLeak -Path (Get-ChildItem ./out -Recurse -File -Force).Where({ $_.FullName -notmatch 'node_modules' }).FullName).Findings`. A finding there is real: follow the result's remediation. Leaving the stage's packages out of the check is a follow-up |

## Bastion, the host password, and Key Vault

| Symptom | Likely cause | Fix |
|---|---|---|
| `STATUS.BASTION` or `COST.BASTION` is a **Warning** | Bastion, or a public IP that an interrupted delete left, still bills by the hour | `./scripts/stop-demo.ps1 -RemoveBastionOnly`; `COST.BASTION` also prints the delete command for a leftover IP |
| The host password rotation is **Manual action required** | The host is deallocated, so the Run Command can't run | Nothing now: the next `start-demo.ps1` rotates the leftover password |
| `STOP.HOSTPASSWORD` or `DEPLOY.T2.HOSTPASSWORD` is a **Warning**: the password couldn't be rotated yet | The Run Command failed on a running host (Phase 28 reports a **Warning**, not a **Fail**) | The record stays, so the next `stop-demo.ps1` or `start-demo.ps1` tries again; or in the Azure portal, open `archost01`, then **Help**, then **Reset password**, and set a random value you don't keep |
| `START.CLIPBOARD` says no clipboard is available, or the guided stop says to reset the password yourself | GitHub Codespaces, Cloud Shell, SSH sessions, Linux without a desktop and `xclip`, and GitHub Actions have none (`Set-Clipboard` doesn't fail there, so the scripts check for themselves) | Reset it in the portal: `archost01`, then **Help**, then **Reset password** ([reset a Windows VM's password](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp)); `stop-demo.ps1` rotates it afterward. Or use the [Key Vault opt-in](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard) |
| The first Key Vault write is refused (`Forbidden`) | A new role assignment takes minutes to reach Key Vault (R201) | The script retries for 10 minutes; run it again if it still fails |

## Workload and scenarios

- **An incident didn't start, or won't stop:** see the [recovery playbook](demo-walkthrough.md#recovery-playbook). `./scripts/reset-demo.ps1` returns every target to a known state without redeploying.
- **Reset reports Manual action required:** the runner's identity can't see or kill other sessions. It needs `ALTER ANY CONNECTION` and `VIEW SERVER PERFORMANCE STATE` on SQL Server, or `KILL DATABASE CONNECTION` and `VIEW DATABASE STATE` on Azure SQL (matrix row 73).
- **Activity stopped near the end of the day:** by design, every profile ends two minutes before the nightly auto-shutdown.
- **`STATUS.PROFILE_<target>` says the activity profile couldn't be read:** before Phase 25b, that was a module bug: it read the runner's `--json` records only from a JSON array, and `profile get --json` writes one object. Since Phase 25b, `Invoke-DemoWorkloadCommand` takes one object as one record. If the message still appears, the runner itself failed, and the message holds its error.
- **`STOP.PROFILE_T2` (or `START.PROFILE_T2`, `STATUS.PROFILE_T2`) is Not selected: "T2 isn't set up yet":** expected before T2's SQL Server setup, for example after a stop at the guided stop: the guest gets its demo module and workload runner after setup, so it has no activity to turn off. Before the Phase 28 live finding's fix, this was a **Warning** with the guest's error, "The specified module ... DbHubDemo.Vm.psd1 was not loaded because no valid module file was found". Nothing to do; the next `./scripts/deploy.ps1` finishes T2.
- **`WORKLOAD.<target>.BOUNDS` is a Warning: "The runner's status for T*n* couldn't be parsed (a Run Command keeps only the last 4,096 bytes of output)":** since Phase 25b, `status --json --runs 5` is longer than the 4,096 bytes an action Run Command returns (the runs' outcome texts, the demo sessions, and the `host` node at the end), so the check sees only the end of it (live, 2026-10-27, on every target). `WORKLOAD.<target>.HOST` still reads the host node, which is last. To check the bounds yourself, read the runs: `Invoke-DemoWorkloadCommand -Target T1 -ArgumentList status, --runs, 3`.
- **A `capacity-max` run on T2 ended Failed: "2 session(s) failed: TimeoutException: Timeout attempting to open the connection":** under the scenario's load, the guest's sessions waited too long to open their connections, because the client library opens only as many at once as there are processors (live, 2026-10-27). The run itself held CPU at its ceiling. Since Phase 25d, the runner tries such an open again within its connect window; deploy this version to get it.
- **T4 had no baseline activity for up to 30 minutes after `deploy.ps1` or while T1 ran `capacity-max`:** T4's start was refused, because a run that the earlier profile host left Running hadn't ended yet, or because `sqlvm01` was too busy to reach T4, and runners before Phase 25d didn't try T4's refused starts again (live, 2026-10-27). This version tries them every 30 seconds within the activity's window; a run left Running still blocks T4 until its deadline (R482).

## The on-demand activity control

What the notebook prints, and what to do ([ADR 0020](adr/0020-on-demand-activity-control.md)). The runbook's job output in the Automation account `aa-<prefix>-control` (**Jobs**) has the full log and one `DBHUB-CONTROL` result line.

- **"The webhook URL couldn't be read from Key Vault (`<ErrorType>`)":** you need Key Vault Secrets User on the secret `dbhub-activity-webhook`: an Owner adds you to `control.notebookUserObjectIds` and runs `setup-activity-control.ps1 -GrantRole`. A private vault is reachable only from the "DBHub Control" workspace: open the notebook there, not a copy in another workspace.
- **"HTTP 400: the webhook has expired or is disabled":** run `./scripts/setup-activity-control.ps1 -RotateWebhook`; the notebook reads the new URL at its next request.
- **"HTTP 404":** the webhook, its runbook, or the account doesn't exist; run `setup-activity-control.ps1`.
- **The job says Refused:**
  - "Another DbHub-Control job ... is Running", or "A run is active until ...": one run at a time. Use **Stop now** (section 4), or wait for the run's end.
  - "... too soon for a run of at least 5 minutes": the VMs' auto-shutdown is less than 7 minutes away.
  - Anything else names the field it refused: the notebook checks the same rules before it sends, so this means the request was sent some other way.
- **The job says NoEnvironment:** the demo resource group doesn't exist (deploy it), or the identity can't read it, because A1 is missing after a redeploy. Run `./scripts/setup-activity-control.ps1 -GrantRole` as an Owner; `validate.ps1` reports it as `CONTROL.ROLE.A1`.
- **Accepted, but no activity shows up:** the VMs take a few minutes to start, Run Command can take minutes more under load, and telemetry arrives 3 to 15 minutes after that. The job's `skipped` list says which target didn't get its profile and why (for example "isn't running yet"); `status.ps1` shows each target's active profile.
- **The private workspace's notebook takes minutes to start:** expected, because its managed private endpoint turns off starter pools for the whole workspace ([README](../README.md#why-it-may-need-a-second-workspace)).
- **Setup reports `CONTROL.MODE` Fail:** `vaultNetworkMode` is `public`, but a policy would make the vault private. Set it to `auto` or `private`; the script never adds the policy's exclusion tag.
- **Setup reports `CONTROL.FABRIC.NOTEBOOK` Manual action required:** the capacity isn't Active, or there's no Fabric token. Run setup again once its administrator has resumed it; `-SkipFabric` does everything else meanwhile.
- **Setup reports `CONTROL.FABRIC.ENDPOINT` Manual action required:** Fabric creates the managed private endpoint's request on the vault a few minutes after the call. Run setup again, or approve the pending connection in the vault's **Networking** > **Private endpoint connections** in the Azure portal.
- **Setup or `validate.ps1` reports `CONTROL.ROLE.A1`-`A3` "wasn't checked: An Azure CLI argument contains '"' or '%'":** a module from before Phase 25d put an encoded `$filter` on the `az rest` command line, which cmd.exe can't pass to az.cmd (live, 2026-10-27); `-GrantRole` fails the same way. Update to this version: the query parameters go in a file (`--url-parameters @<path>`).
- **A run through the Fabric job API or a pipeline is refused with "An activity can't have ..." or "ACTIVITIES must be a list":** pass `ACTIVITIES` and `RESET_TARGETS` as JSON text, for example `[{"target": "T1", "scenario": "cpu-pressure"}]`; a job parameter is a string, a number, or a bool. Notebooks imported before Phase 25d took lists only: run `setup-activity-control.ps1` again to import the current one.
- **The job's `skipped` list has `T4 (pgflex01-<id> didn't accept the start)`, or a Stop now leaves T4 running:** Azure refused the runbook's start or stop. Runbooks published before Phase 25d sent those requests in a form encoding that the PostgreSQL resource provider refuses ("Unsupported media type", live, 2026-10-27), and the run then waited 15 minutes for T4 before it started the others. Run `./scripts/setup-activity-control.ps1 -SkipFabric` to publish the current runbooks, then stop T4 with `stop-demo.ps1`. With the current runbooks, the message gives Azure's reason; a T4 that's still stopping is skipped as "T4 (stopping)".
- **Setup reports `CONTROL.SAFETYSTOP` Warning: "couldn't be linked to DbHub-Stop: ... A jobSchedule with same id already exists":** a module from before Phase 25d didn't recognize its own schedule on a second run, because Azure Automation names its time zone differently (`America/New_York` for `Eastern Standard Time`); it replaced the schedule and couldn't link it again, so the daily T4 safety stop wouldn't run (live, 2026-10-27). Run `./scripts/setup-activity-control.ps1 -SkipFabric` with this version: it links the schedule again, and keeps it on later runs. `validate.ps1` reports a missing link as `CONTROL.SAFETYSTOP`.
- **The VMs deallocated in the middle of a later session:** a notebook run's auto-stop was still pending and `start-demo.ps1` couldn't cancel it (`START.CONTROL.AUTOSTOP`), or its `DbHub-Stop` job was still running after start-demo's 10-minute wait, or the jobs couldn't be read (`START.CONTROL.STOPJOB`). The **Warning** says which, with the time. Run `start-demo.ps1` again once the job has finished (**Process automation > Jobs** in `aa-<prefix>-control`); to cancel a pending auto-stop by hand, delete the schedule `dbhub-autostop` there (**Shared resources > Schedules**). `status.ps1` shows a pending one (`STATUS.CONTROL`).

## Cost

- **A budget alert arrived:** run `./scripts/status.ps1` (`STATUS.COST`). The usual causes are a forgotten Bastion, an evening start that ran until the next day's shutdown, and a T3 profile left on.
- **Between long breaks:** `stop-demo.ps1 -RemoveT3` stops T3's monthly Defender and private-endpoint charges; the next start recreates it.
- **The Fabric capacity:** it bills while it runs and sits outside the demo's ceiling ([cost management](cost-management.md#microsoft-fabric-capacity)).

## GitHub Actions

| Symptom | Likely cause | Fix |
|---|---|---|
| Workflows don't run in a fork | GitHub doesn't run workflows on a fork until you enable them | Enable them on the fork's **Actions** tab |
| `azure/login` can't get a token | The run's environment doesn't match the federated credential's subject (`repo:<owner>/<repo>:environment:<name>`), or the identity lacks Contributor (P7) | Run in the environment you set up with `setup-github-oidc.ps1`, and have an administrator run the role command it printed ([OpenID Connect from GitHub](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)) |
| The T3 stage fails in Actions | The GitHub identity doesn't own the P6 group | Make it an owner, or run `deploy.ps1 -FromStage T3` locally once |
| Scheduled workflows never run | Schedules are off by default | Set the repository variable `DBHUB_SCHEDULES_ENABLED` to `true` |

## Fallbacks at a glance

| Dependency | When it isn't available | Fallback |
|---|---|---|
| In-Hub Database Agent (preview) | Missing, slow, or declines a target | The `microsoft-sql-fdh` and telemetry skills in GitHub Copilot CLI, then the Azure Data Explorer web UI, then rehearsal screenshots ([ADR 0013](adr/0013-agent-experience.md)) |
| Database Hub UI | Not reachable | Estate through Azure Resource Graph (`HUB.ESTATE.*`) and telemetry through the documented endpoint (`TELEMETRY.*`) |
| Notebook `kusto` token | Not accepted | Printed KQL for the Azure Data Explorer web UI, and `validate.ps1` |
| Nested virtualization | Not available | The opt-in evaluation-only Azure VM, labeled **evaluation only** everywhere |
| The `PaygWizard` step | Not wanted | `ProductKey` mode (P10), fully unattended; or `Developer` mode, unattended but Estate only |
| A person at the guided stop | Nobody there in time | The run ends **NOT DONE**; `./scripts/deploy.ps1` again guides the step. `-NoWaitForT2` finishes the rest first |
| T4's default size | Azure refuses `Standard_B1ms` (and `Standard_B2s`) | `Standard_B2s` by itself; without either, the run finishes without T4, and **DONE** says so (Phase 28) |
| The Insights app's tenant settings | Not on | Nothing: the app is optional, and **DONE** lists how to add it later |
| Azure SQL free offer | Not available | Regular General Purpose serverless, with a **Warning** |
| Public SQL endpoint | Denied by policy | Private mode with a private endpoint |
| Clipboard for the host password | GitHub Codespaces, Cloud Shell, or Actions | The portal's **Reset password**, then `stop-demo.ps1` rotates it; or the Key Vault opt-in |
| GitHub path (P7) | No administrator to assign the role | `deploy.ps1` and the other scripts locally |
| Deploy to Azure button | Private repository | `deploy.ps1` |
| The Insights app's hosted URL | "Page not accessible directly" in the preview | The app's item in the Fabric workspace (embedded) |
