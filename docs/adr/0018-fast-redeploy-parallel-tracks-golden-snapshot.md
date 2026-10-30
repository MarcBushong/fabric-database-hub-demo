# ADR 0018: Fast redeploy: parallel tracks and a T2 golden snapshot

- **Status:** Accepted (the approach is user-directed). Measured live on 2026-10-22: **38.8 minutes end to end**; with Phase 22's overlaps on 2026-10-23: **63.7 minutes**, T1 and T3 ready 9.5 minutes sooner but T2 held back by the SQL Server extension's download (R72). **The 30-minute target wasn't met** ([amendments](#amendments-2026-10-22-live), [Phase 22](#amendments-2026-10-23-phase-22-the-follow-up-overlaps), [validation results](#validation-results-2026-10-22)). Amended on 2026-10-29 for Phase 28: one command, one guided stop, and a clock that includes T4 ([amendments](#amendments-2026-10-29-phase-28-one-command-one-guided-stop))
- **Date:** 2026-10-21
- **Decision source:** User-directed (2026-10-21: "deployed in less than 30 minutes end to end", and "Parallel deploy plus a T2 snapshot"), with guardrails 1-12 decided by the coordinator for the owner; engineering detail, revised after an independent design review the same day
- **Related:** [ADR 0002](0002-resource-group-topology.md), [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0004](0004-guest-imds-isolation.md), [ADR 0005](0005-arc-onboarding-authentication.md), [ADR 0006](0006-sql-editions-and-licensing.md), [ADR 0009](0009-secrets-handling.md), [ADR 0011](0011-control-surface-priority.md), [ADR 0012](0012-validation-model.md), [ADR 0016](0016-cost-profiles.md), [deployment](../deployment.md)

## Context

- **The owner's requirement (2026-10-21):** a repeatable deployment that finishes in 30 minutes or less end to end. Asked how, the owner chose parallel tracks (T1, T3, and Fabric at the same time) plus a golden snapshot of today's finished T2 host, restored on redeploy with Arc reconnected.
- **Where the time goes in the sequential pipeline** (measured live in West US 3; Phase 16's fresh deployment on 2026-10-21 and Phase 20's read-only preflight profile the same day):

  | Step | Measured |
  |---|---|
  | Subscription guard | 22-64 seconds |
  | Preflight, end to end | 11.8-12.5 minutes |
  | of which the two VM size checks (one `az vm list-skus` each) | 122 and 127 seconds |
  | of which the policy inventory (8 assignments, about 100 definitions read one at a time) | 5.4-7 minutes |
  | Template deployment, nothing existing | 7.4 minutes |
  | One Run Command chunk (PUT, agent pickup, polling, DELETE), whatever its size up to 512 KiB | About 60-80 seconds |
  | Runner (7 chunks) per VM, one Run Command at a time, one VM after the other | About 7.8 minutes per VM |
  | The second template deployment that adds the loaders, then the SQL IaaS extension `Updating` | About 3 minutes, then about 10 minutes |
  | Arc onboarding Run Command | 217 seconds |
  | T2 guest build to the setup-wizard step | 60-90 minutes (estimate; ADR 0003) |

- **The T2 wizard state can't be rebuilt by code.** Pay-as-you-go SQL Server without a product key is documented only in the setup wizard ([ADR 0006](0006-sql-editions-and-licensing.md)). The owner did it on 2026-10-21; that guest is the state to keep.
- **The T2 host has one disk** in `lowest-cost`: `archost01-osdisk` (128 GiB) holds Windows, Hyper-V, the media, and the guest's VHDX, so a copy of that disk is a copy of all of T2 (live inventory, 2026-10-21).
- **Managed disks:** an incremental snapshot's first copy is full; it's billed for its used size, which only the usage report shows; it's stored on Standard HDD (ZRS where the region has it); it can be used at once; and a disk created from it hydrates in the background ([incremental snapshots](https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots)). A VM can be created by attaching such a specialized OS disk, and it keeps the computer name ([attach an OS disk](https://learn.microsoft.com/azure/virtual-machines/attach-os-disk)). `NetworkAccessPolicy` `DenyAll` prevents export ([restrict import and export](https://learn.microsoft.com/azure/virtual-machines/disks-restrict-import-export-overview)).
- **A copy carries the guest's Arc identity and extensions.** Its agent would check in as the machine it was captured from. `azcmagent disconnect --force-local-only` resets only the local agent and never touches the Azure resource ([azcmagent disconnect](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-disconnect)). Extensions must be removed before a disconnect, because they "aren't recognized if you reconnect" ([uninstall the agent](https://learn.microsoft.com/azure/azure-arc/servers/uninstall-agent)); `azcmagent extension remove --all` does that locally, even disconnected, once the extension manager is stopped ([azcmagent extension](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-extension)).
- **Run Command works with all outbound traffic denied.** The VM agent reaches the WireServer `168.63.129.16` on ports 80 and 32526, which network security groups don't filter ([168.63.129.16](https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16)), and downloads extension packages through it ([extensions, network access](https://learn.microsoft.com/azure/virtual-machines/extensions/features-windows#network-access)). Managed Run Command supports "parallel execution of multiple scripts", at most 25 per VM ([managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed), [overview](https://learn.microsoft.com/azure/virtual-machines/run-command-overview)); whether several PUTs to one VM at the same time are accepted isn't documented.
- **Concurrent Azure CLI processes** can hit write conflicts on the shared MSAL token cache; Learn's remedy is a separate `AZURE_CONFIG_DIR` per script ([concurrent execution](https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-tips#concurrent-execution)), which needs its own sign-in.

## Decision drivers

1. Thirty minutes or less end to end, measured, repeatable, with no new manual step.
2. The owner's pay-as-you-go wizard state survives a destroy and redeploy.
3. A copy never acts as another machine's Arc identity, and what the snapshot holds stays protected.
4. Contributor only: no storage account, no role assignment, documented interfaces only.
5. Everything still works without a snapshot (forks, customers), and no time is claimed before it's measured.
6. Cost stays within the ceilings, priced from the Retail Prices API at run time.

## Considered options

1. **Only speed up the sequential pipeline.** Rejected alone: the guest build and the wizard remain.
2. **Parallel tracks plus an incremental managed-disk snapshot of the T2 host's OS disk** (chosen, user-directed).
3. **An Azure Compute Gallery image of the host.** A generalized image needs Sysprep, which resets the host's machine-scope DPAPI keys that protect the guest's password and breaks the nested guest; a specialized image adds a gallery, a definition, and replica storage for nothing a snapshot doesn't give. Rejected.
4. **Export the guest's VHDX to a storage account.** Needs a storage account (tenant policies, Defender for Storage; ADR 0016, C9) and a SAS export, which `DenyAll` forbids by design. Rejected.
5. **Automate the setup wizard.** No UI automation; only documented interfaces. Rejected.
6. **`ProductKey` or `Developer` instead of the wizard.** Both stay; neither keeps the owner's pay-as-you-go state.

## Decision

### 1. When the clock stops

"End to end" runs from the start of `deploy.ps1` until it writes `DEPLOY.SUMMARY` with every target ready: telemetry **Pass** for T1, T2, and T3; Hub Estate **Pass** for all three; T2 Standard, PAYG, and monitoring on; the Fabric artifacts imported. `DEPLOY.TIMING` records each track and the total. A run whose summary isn't ready doesn't count as a measurement.

*Amended 2026-10-29 (Phase 28), to include T4:* the clock stops when the run's **DONE** evidence is complete, the same list that **DONE** needs ([amendments](#amendments-2026-10-29-phase-28-one-command-one-guided-stop)): Hub Estate **Pass** for T1 to T4 (`HUB.ESTATE.T1`–`T4`); telemetry **Pass** for T1, T2, and T3 (`TELEMETRY.T1`–`T3`); T4's Azure Monitor metrics (`METRICS.T4`); in `PaygWizard` and `ProductKey` modes, T2's instance at Standard with PAYG (or Paid) and monitoring on (`T2.ARC.SQLINSTANCE`, `T2.ARC.MONITORING`); T1's inventory (`T1.SQLVM.ASSOCIATEDSERVICES`); and the required Fabric items (`FABRIC.ITEMS.REQUIRED`: the workspace, the lakehouse, the notebooks, the Real-Time Dashboard, and the history model and report), with every track finished. T4's two checks are left out when T4 is off (`t4Enabled: false`, or the Burstable fallback left it uncreated, ADR 0019), and T2's performance checks in `Developer` mode. The optional Insights app (`APP_DatabaseHub_Insights`) never holds the clock or **DONE** back.

### 2. Parallel tracks

| Phase | Runs in | What it does |
|---|---|---|
| Preflight (shared) | The parent | The guard, P1-P6, region, sizes, quota, policy, cost, and the T2 source |
| Infrastructure (shared) | The parent | The one subscription-scope template; ARM creates T1, the T2 host (golden disk or image), and T3 in parallel |
| Fabric track | Its own process, started right after Preflight | `configure-fabric.ps1 -SkipHubChecks`: P4, P5, the capacity, and the imports (notebooks; the dashboard and the Power BI model, report, and app shell once Phases 18 and 19 merge). It reads and writes no Azure state. |
| T1 track | Its own process | Bundle and runner chunks, the loader, T1 monitoring, T1 Ready, T1 telemetry |
| T3 track | Its own process | T1 in the P6 group, the T3 setup from T1, `Test-DemoT3`, T3 telemetry. It needs T1's VM and identity, not T1's bootstrap. |
| T2 track | Its own process | Golden: release and reset, passwords, bundle and runner, Arc, Ready checks, T2 telemetry. Build: bundle and runner and the loader; the host then builds on its own. |
| Join (shared) | The parent, once T1 and T3 are done | `Enable-DemoT3Workload`, the activity profiles on T1 and T3 |
| Validation (shared) | The parent | Hub Estate and telemetry for each ready target, the T3 readiness gate, the runner, `DEPLOY.TIMING`, `DEPLOY.SUMMARY` |

- **Processes:** each track is a background job (`Start-Job`) in its own `pwsh` process ([about_Jobs](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_jobs)) that imports the module and runs `Assert-DemoAzContext` itself, because the guard's validated context belongs to one process ([ADR 0011](0011-control-surface-priority.md#guard-update-2026-10-21)). The T1, T2, and T3 jobs start right after Preflight, a few seconds apart so their guards don't write the token cache at the same moment, run their guard during the Infrastructure stage, and wait for the parent's local signal that the template succeeded (they exit when it failed). `DBHUB_SQL_PRODUCT_KEY` is removed from the environment before any job starts and handed only to the T2 job. Jobs are stopped if the parent is cancelled. *Amended 2026-10-29 (Phase 28 live finding):* a Ctrl+C at the guided stop seemed to do nothing, because `Stop-Job` waited for the T2 track's own cleanup, minutes of Azure calls, in a `finally` block that a second Ctrl+C can't interrupt. Now each job reports its process ID first, with its start time, so a process that later gets the same ID is never ended (Phase 28 review); on a stop the parent writes a cancel marker into the handoff directory, so the tracks' slow Azure cleanups (a Run Command's delete, the chunks' cleanup, the guided stop's Bastion removal and password rotation) are left to the next run or `stop-demo.ps1`, asks each job to stop, and after about 3 seconds ends any that still runs with every process it started ([Process.Kill](https://learn.microsoft.com/dotnet/api/system.diagnostics.process.kill)). The tracks' private files live under the handoff directory, which the parent deletes. The parent records the Ctrl+C itself ([Console.CancelKeyPress](https://learn.microsoft.com/dotnet/api/system.console.cancelkeypress)), so its own `finally` blocks skip the same cleanups, and the run ends **Stopped, not done** within seconds. What a guided stop stopped this way leaves (its Bastion, the handed-over host password) is cleaned up by the next run's T2 step, whether or not setup finished meanwhile, and **DONE** waits for it (Phase 28 review).
- **Results:** each track writes its own JSON lines; the parent relays progress (each line names its track), merges the lines in a fixed order into `out/deploy.jsonl`, and reports `DEPLOY.TRACK.<name>` with its duration. A failed track stops itself and what depends on it; the others finish.
- **State:** the resource group's `DbHub*` tags remain the state store ([ADR 0002](0002-resource-group-topology.md)). No track writes a tag before the template has finished, so the template's tag merge can't overwrite one. Each VM's artifacts have their own keys (`DbHubBundleOn<vm>`, `DbHubRunnerOn<vm>`), so tracks never edit a shared list, and every read-modify-write still holds a local exclusive lock. Each track records its last finished step (`DbHubTrackT1`, `DbHubTrackT2`, `DbHubTrackT3`, `DbHubTrackFabric`), and `DbHubDeployStage` is derived: the last stage up to which every step of every track has finished, so it never passes an open step and keeps its meaning for `start-demo.ps1` and `status.ps1`.
- **`-Resume`, `-FromStage`, `-StopAfter`** keep their stage names. Each track step belongs to one stage (Artifacts, Bootstraps, T3, Activity, Monitoring, T2, Fabric), so the options select the same work as before, and `-Resume` continues each track after its own recorded step. `-StopAfter Infrastructure` still gives what the Deploy to Azure button gives.
- **Run Commands on one VM:** chunks go out in parallel only after a live check shows the VM accepts parallel PUTs (Phase 20 measures it); otherwise one at a time, as today. A 409 from an extension operation keeps the existing retry (R49).

### 3. The T2 source: `golden` or `build`

- **`t2Source`** (configuration, optional, default `auto`): `auto` restores from the newest boot-verified golden snapshot and builds otherwise; `golden` requires one (**Fail** without it); `build` always builds.
- **Only a new host chooses.** An existing `archost01` keeps its source: attached from a golden disk, it stays golden; built from the image, it stays built.
- **Usable snapshot:** in `rg-<prefix>-golden`, tagged boot-verified (section 6), in the configured region, the same install mode (`PaygWizard`), the nested mode, the Standard security type, a host without a data disk (the `lowest-cost` layout), and its guest's evaluation not yet over. Preflight reports the choice as `PREFLIGHT.T2.SOURCE`.

### 4. Capture: `scripts/capture-t2-golden.ps1`

1. **Preconditions,** each a result: the guard; `archost01` in the nested mode, `PaygWizard`, no data disk, health **Ready**, no SQL Server product key file on the host; in the guest, no sign-in data that setup leaves on the VM, and on the host and in the guest no sign-in data at all after the sweep (`GOLDEN.CAPTURE.SIGNIN`, ADR 0009, Phase 26d; with `-WipeFreeSpace`, free space overwritten with zeros, the guest's disk compacted, and both volumes trimmed), no sign-in cache from the wizard's Azure Login (WebView2 profile data and MSAL token caches under the guest administrator's profile are deleted, then checked again), and IE Enhanced Security Configuration on for administrators and users; the host administrator's password rotated now (a random value nobody keeps; `PasswordLastSet` is the evidence).
2. **Facts** read over PowerShell Direct: the guest's evaluation expiry, the SQL Server version, update level, and edition, the bundle and runner hashes, the used space on `C:`, the Arc agent's resource and machine ID, and the host's Azure VM ID.
3. **The air gap, written into the snapshot:** the guest's automatic start action becomes `Nothing`, and its network adapter is disconnected from the NAT switch (`Set-VM`, `Disconnect-VMNetworkAdapter`). The host records the capture in `C:\ProgramData\DbHubDemo\golden\capture.json` (the snapshot name, the source host's Azure VM ID, and the Arc identity).
4. **A clean stop:** every activity profile off, the guest shut down and confirmed off, the host deallocated.
5. **The snapshot:** `rg-<prefix>-golden` (created when missing with `solution`, `owner`, `costCenter`, `purpose` `t2-golden-snapshot`, and `environment` `golden`, but no `deploymentId`: the group serves every environment of the prefix and must not count as an environment's residue), then an incremental snapshot of `archost01-osdisk` with `DenyAll` and public network access off (`az snapshot create --incremental true`), tagged with the capture time, the guest's evaluation expiry, the bundle and runner hashes, the SQL Server version and update level, the install mode, the host size and security type, the used GiB, and the captured Arc identity.
6. **Disk check:** a disk created from it in the golden group (with `DenyAll`) must succeed, then it's deleted, and the snapshot is tagged disk-verified.
7. **Policy:** snapshots and disks are part of preflight's policy inventory, and the capture stops on a deny rule for them. `-WhatIf` runs only the read-only checks.
8. **Replacement:** older golden snapshots of the prefix are deleted only after the new one is boot-verified (section 6).
9. **The source afterwards:** the next `start-demo.ps1` or `deploy.ps1` on the source host releases the air gap (section 5): the host's own Azure VM ID matches the capture record, so it only reconnects the guest; its Arc identity is still its own.

### 5. Restore

- **Template:** with a golden source and no host yet, `archost01.bicep` creates `archost01-osdisk` from the snapshot (`createOption: Copy`, the profile's disk SKU, `osType` Windows, `hyperVGeneration` V2, the zone when set, `DenyAll`, public network access off) and the VM with the disk attached (no `osProfile`, no image), under the stable names. When the host exists, the template attaches the existing disk by ID and never declares its source again, so a later capture that deletes the old snapshot can't break a redeployment.
- **The guest boots air-gapped:** it doesn't start with the host, and when started it has no network, whatever network security group the host sits behind. Run Command still reaches the host.
- **The T2 track, in order:**
  1. **Release and reset** (`vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Release` through a Run Command): the host compares its Azure VM ID (IMDS) with the capture record. On the source host it only reconnects the guest. On a copy, while the guest's agent still reports the captured identity, it starts the guest offline, stops the extension manager, removes every Arc extension locally (`azcmagent extension remove --all`), runs `azcmagent disconnect --force-local-only`, checks that the agent names no resource, renames the host's Arc marker so the host waits for onboarding like a fresh build, and checks that SQL Server runs Standard edition. A second run finds no captured identity and skips the reset. Only then is the adapter reconnected and the automatic start restored.
  2. **Passwords first:** the host's administrator password (the built-in account, RID 500, because an attached disk has no `osProfile`), then the guest's `Administrator`: a new random value is stored with DPAPI as pending, set in the guest, proven with a new PowerShell Direct session, then promoted; if it can't sign in, the old one is set back. A run that died midway finds the pending value and finishes.
  3. **Drift:** the current bundle and runner, when their hashes differ from the host's, and the loader; the host's new bootstrap generation must report **Ready**: the same checks as a fresh build (guardrail 6).
  4. **Arc:** `Invoke-DemoArcOnboarding -Force` with the caller's short-lived token, started as soon as the guest is reconnected so the extensions' downloads overlap step 3. After the reset the decision table finds no local identity: **Onboard** when no machine exists. A machine of that name that's **Connected** is never deleted: the cleanup refuses it (a live original or another copy), so **CleanupStaleThenOnboard** applies only to a machine that isn't connected.
  5. **Ready only when verified** (guardrail 3): Standard edition, license type PAYG, and monitoring on through the same `configure-arc` checks as a fresh build (`T2.ARC.*`), then T2's telemetry and activity profile. Restoring a pay-as-you-go install isn't explicitly documented: it's validated empirically and disclosed in [limitations](../limitations.md).
- **Refreshing the snapshot after guest-side changes:** bundle and runner changes converge at every restore (step 3). A change that needs a new guest build, or a snapshot near its evaluation expiry, needs a fresh build (`t2Source build`), the wizard, and a new capture.

### 6. Proving a snapshot: `scripts/test-t2-golden.ps1`

Guardrail 8, as code. In a disposable `rg-<prefix>-goldentest` it deploys a minimal network whose host subnet's network security group denies all outbound traffic before first boot (`t2Quarantine`, used only here), restores a copy, connects the guest behind that rule, proves from the guest that the Arc endpoints are unreachable (`azcmagent check --location <region>` and direct TCP tests; any answer fails the test), runs the reset of section 5, sees SQL Server running Standard, and tags the snapshot boot-verified. With `-Onboard` it then deletes the deny rule, onboards the copy fresh in the test group, sees Standard, PAYG, and monitoring, and tags it onboard-verified. It reads the source's Arc machine before and after (`vmId`, `status`, `lastStatusChange`, which a source already Disconnected must keep, and the Activity Log, where only Administrative entries count as operations: Resource Health and other events are listed in the evidence), deletes the test group, and runs the zero-residue check. It checks vCPU quota for the extra host first.

`destroy.ps1` refuses an environment whose T2 holds a `PaygWizard` install when no boot-verified snapshot exists, unless `-WithoutGolden` accepts losing the wizard state; with `-IfExpired`, the expiry wins and it's a **Warning**.

### 7. Lifetime (guardrail 2)

The guest's evaluation clock runs inside the snapshot. Preflight (`PREFLIGHT.T2.SOURCE`), `status.ps1` (`STATUS.T2.GOLDEN`), and the capture report a **Warning** at 30 days or less, and at 7 days or less a **Warning** that says "re-capture now"; a **Warning** too when the evaluation ends before the environment's `expiresOn`. After the expiry, `auto` falls back to `build` with a **Warning**, and `golden` is a **Fail**.

### 8. Speed

- **Preflight:** the policy inventory and the VM size availability are cached per subscription and region (`preflightCacheHours`, default 24). The policy cache is valid only while the list of policy assignments and their versions is unchanged. The what-if, the backstop for denials, always runs.
- **Chunks** in parallel per VM (section 2), and the two VMs on different tracks.
- **Loaders:** `deploy.ps1` creates each VM's loader Run Command (`DbHubDemo-Bootstrap`) itself, with the same properties the template used, and only when they differ from the existing one, so there's no second template deployment and no SQL IaaS extension update after it. The template no longer deploys the loaders.
- **T1 monitoring** is merged right after T1's loader starts, so the plugin's start-up overlaps the bootstrap.
- **Health waits:** a watcher Run Command on the VM waits for its health state and exits; the orchestrator polls the instance view instead of running a health Run Command every five minutes.
- **Telemetry** is awaited inside each track, so the validation mostly confirms.
- **Re-runs:** when everything exists, the template's what-if runs first, and a what-if without changes skips the deployment.
- **`start-demo.ps1`:** both VMs start at once, T3 resumes alongside, and the warm-up runs in the background: the activity profile runs on the VMs until the next auto-shutdown, and the script returns once the profiles are set, with the time to run `validate.ps1`. `-WaitForWarmUp` keeps the old behavior for the scheduled workflow.
- Every change keeps the guard, the bounded workloads (ADR 0010), and the ADR 0012 statuses.

### 9. Without a snapshot (forks, customers)

T1, T3, and Fabric run in parallel exactly as above, and the T2 track sends the artifacts and starts the host's build. `deploy.ps1` then returns and reports `DEPLOY.T2.BACKGROUND` as **Manual action required**, with the host's current step and the command that continues it (`deploy.ps1 -Resume` once `status.ps1` shows the host waiting for onboarding, plus the wizard step in `PaygWizard` mode). `-WaitForT2` waits instead, up to `-T2WaitMinutes`. No document claims a time for this path until Phase 16's fresh build measures it.

*Superseded 2026-10-29 (Phase 28):* `deploy.ps1` now waits for T2 by default in every install mode, with the guided stop in `PaygWizard` mode, and finishes T2 in the same run; `-NoWaitForT2` (and CI without `-WaitForT2`) keeps the behavior above ([amendments](#amendments-2026-10-29-phase-28-one-command-one-guided-stop)).

### 10. Security (guardrail 5)

- **What the snapshot holds:** the host's and the guest's local password hashes, the host's DPAPI-protected guest password, the guest Arc agent's private key for the captured identity, the SQL Server instance with synthetic data, and setup's logs (redacted).
- **Controls:** `DenyAll` and public network access off (no SAS, so no export); the air gap and the reset before any egress; capture only after the sign-in cleanup, IE ESC, and the host password rotation; after a restore, both passwords rotated before anything else on the network.
- **Access, a deviation:** the guardrail asks to keep access to the deploying identity. With Contributor as the only permission and no role assignments (ADR 0008), the golden group can't be narrower than the subscription's existing roles: any Contributor can create a disk from the snapshot, as from any disk in the subscription. `DenyAll` still blocks export for everyone. Recorded for the owner.
- **The captured Arc identity** is valid while its Azure machine exists. Phase 20 destroys the source after capture; an owner who keeps a source running should re-onboard it (`azcmagent disconnect`, then `configure-arc.ps1`) or delete the snapshot.

### 11. Cost (guardrail 4)

- One incremental snapshot in `rg-<prefix>-golden` and no storage account. `destroy.ps1` keeps the group; `destroy.ps1 -IncludeGolden` deletes it.
- `estimate-cost.ps1` and preflight's monthly check price the snapshot per GB-month for its storage type (LRS or ZRS) from the Retail Prices API at run time, on the OS disk's provisioned size: the used size Azure bills appears only in the usage report, so the hard ceiling uses the upper bound, and the measured used size is evidence. `status.ps1`'s month-to-date figure includes the golden group.

## Consequences

- **Positive:** a redeploy keeps the owner's pay-as-you-go state with no manual step; the critical path is the slowest track, not the sum; a copy can't impersonate a live machine, whatever network it lands in; the build path still deploys everything.
- **Negative:**
  - The snapshot holds secrets (section 10) and costs a few dollars a month while it exists.
  - It ages: the guest's evaluation runs inside it, and guest-side code drifts; a re-capture needs a fresh build and the wizard.
  - The extensions are removed and reinstalled on every restore, so the SQL Server extension's download (once about 30 minutes, R72) is on T2's path.
  - Restoring a pay-as-you-go install is validated only empirically.
  - A disk created from a snapshot hydrates in the background, so the host's first minutes are slower.
  - Four processes instead of one: each runs its own guard, state writes take a lock, logs interleave, and concurrent CLI processes share one token cache (a separate `AZURE_CONFIG_DIR` remains the optional isolation, [prerequisites](../prerequisites.md)).
- **Risks:** R330-R349 in the [implementation report](../implementation-report.md).

## Validation

Phase 20, live, in this order (the destroy only after the coordinator's go-ahead):

1. Capture the snapshot from `archost01` after the preconditions; tag it.
2. Create a disk from it in a test resource group.
3. `test-t2-golden.ps1 -Onboard` in a disposable group (section 6), with timings, zero residue, and the live `arcsql01` unchanged.
4. Destroy `rg-dbhub-demo` (Arc resources first), redeploy with stable names, timed per track and in total (section 1).
5. Full validation, scenario behavior, then a second `deploy.ps1` that converges with no changes, and a Resource Graph query with exactly one `arcsql01` machine and only the expected SQL Server instances.
6. Stop, a timed repeat start, and stop.

## Amendments (2026-10-22, live)

Built differently from the decision above, or not built:

| Decision | As built | Why, or the follow-up |
|---|---|---|
| Four processes (T1, T2, T3, Fabric) | Three: T1 with T3, T2, and Fabric; no `DbHubTrackT3` | T3's setup and workload run through T1's runner, so T3 follows T1's bootstrap |
| Track jobs start right after Preflight and run their guard during the template deployment | They start after the template; each guard (about 70 seconds) is on the critical path | Follow-up (about 1.2 minutes); built in [Phase 22](#amendments-2026-10-23-phase-22-the-follow-up-overlaps) |
| Policy inventory and VM sizes cached (`preflightCacheHours`, 24) | Only the policy inventory is cached (`-PolicyCacheHours`, 168 in the scripts); the region's SKUs come from one Resource SKUs REST read (seconds, where each `az vm list-skus` took about 100) | Preflight measured 397 seconds cold and 158 warm |
| Chunks in parallel per VM | Built (up to 8 at once): the runner's 7 chunks took 193 seconds on `sqlvm01`, where Phase 16 measured 470–481 | The bundle and the runner still go one after the other on each VM; follow-up (about 1.7 minutes), built in [Phase 22](#amendments-2026-10-23-phase-22-the-follow-up-overlaps) |
| `deploy.ps1` runs the loaders; no second template deployment | Built | Found live: nothing restarted T1's SQL IaaS Agent after the `AssociatedServices` uninstall, so unified inventory kept listing Analysis Services and Integration Services for 46 to 72 minutes (the second deployment's extension update used to restart it). The step now restarts it; the validation fails while they're listed, and the clock needs `T1.SQLVM.ASSOCIATEDSERVICES` **Pass**. `validate.ps1`'s loader check reads the bundle from `health.json`, because the loader's Run Command is removed after it runs |
| T1 monitoring merged right after T1's loader starts | Not built: monitoring follows T3 and the activity profiles | Follow-up (about 2.8 minutes); built in [Phase 22](#amendments-2026-10-23-phase-22-the-follow-up-overlaps) |
| A watcher Run Command waits for health | Not built: the tracks read `health.json` with a Run Command every minute | |
| Re-runs skip the template when its what-if has no changes | Not built: a re-run deploys the template again, with no changes | |
| Arc onboarding overlaps the drift step | Not built: Restore, Artifacts, Bootstraps, then T2 | Follow-up: T2's artifacts during the Release (about 4.9 minutes); built in [Phase 22](#amendments-2026-10-23-phase-22-the-follow-up-overlaps) |
| Release, then passwords | The host password first (the built-in account, RID 500), then the Release, which rotates the guest password before the guest reconnects | |
| The Release reads the agent's identity once | It waits up to 5 minutes until `azcmagent show -j` reports a status, and stops with the guest still air-gapped otherwise | Found live: G6's Release read the agent right after the cold boot and skipped the reset that G3's copy of the same snapshot needed; the onboarding then found the captured identity and reset it (`DisconnectLocalThenOnboard`), which only worked because the captured Azure machine no longer existed. Unit-tested, not yet run live |
| The Fabric track runs `configure-fabric.ps1` | It runs `configure-fabric.ps1`, `configure-powerbi.ps1` (Phase 19), and `configure-fabric-app.ps1` when the checkout has it (Phase 19b), each in a separate session state | Found live: run from module code, the scripts' `Get-DemoConfig` couldn't read the module's `$script:RepoRoot`, and the track stopped at once; the fixed track passed in 141 seconds |
| `start-demo.ps1` starts both VMs at once | Built | Found live (G10): a VM whose instance view had no power state yet, right after its start request, counted as missing, and T1's profile was set before its SQL Server accepted connections. The start now waits for a power state and retries T1's profile as it does T2's; unit-tested. Found in G8: after the deallocation, T1's monitoring plugin stayed NotRunning, so T1 sent no telemetry; the start now restarts the SQL IaaS Agent when it does (`START.T1.MONITORING`) |
| The quarantine test group `rg-<prefix>-goldentest` | `rg-<prefix>-gtest` (environment `gtest`) | |

With those four overlaps (about 10.6 minutes off the measured tracks, unmeasured), the estimate is about 30–31 minutes end to end.

## Validation results (2026-10-22)

| Step | Result |
|---|---|
| 1. Capture | **Pass:** `snap-dbhub-t2golden-202610221306`, incremental, Standard HDD LRS, 128 GiB provisioned and about 37 GiB used, `DenyAll`, tagged. The first attempt stalled for 28 minutes behind an `MDE.Windows` update on the host; deallocating cleared it |
| 2. Disk test | **Pass:** disks from the snapshot in 5, 16, and 21 seconds |
| 3. Quarantine and onboarding | **Pass** on the third attempt (the first two found the NSG rule's priority, an ARM `if()` that evaluated both branches, and an empty identity name): 4,492 seconds in all. The copy booted air-gapped, 8 Arc endpoints didn't answer from the guest, the reset removed the captured identity, SQL Server ran Standard; the Release took 1,009 seconds with the isolation proof, the onboarding 2,690 seconds (the extension download, R72), and the teardown 396 seconds. The live `arcsql01` was untouched |
| 4. Destroy and redeploy | Destroy 1,102 seconds ([cleanup](../cleanup.md#tested-results)). Redeploy **38.8 minutes** end to end: T1 and T3 ready at +36.3 minutes, T2 (golden) at +37.7, Fabric about 2.4 minutes after a fix ([deployment](../deployment.md#parallel-tracks-phase-20)) |
| 5. Repeat runs | `deploy.ps1` on the deployed environment converged with no duplicate Arc resources: 25.9 minutes with changed code (G9) and 21.8 with the same code (G9b); both sent the bundle and the runner again because each checkout built them differently, which the runner's build no longer does. After G8, G9c (32.3 minutes) sent only the rebuilt runner and converged too, with the Fabric scripts and Phase 19b's app as their own step |
| 6. Stop and repeat start | `stop-demo.ps1` about 6 minutes; `start-demo.ps1` 391 seconds after two fixes to the parallel start (a VM with no power state yet counted as missing; T1's profile was set before its SQL Server accepted connections). With every fix, including the restart of T1's monitoring plugin that G8 showed was needed: `start-demo.ps1` **481 seconds**, every check **Pass**; `stop-demo.ps1` 338 and 371 seconds, both VMs deallocated |

## Amendments (2026-10-23, Phase 22: the follow-up overlaps)

The owner chose to build the overlaps that Phase 20 listed as a follow-up and to measure them with one more destroy and redeploy. As built:

| Phase 20 as built | Phase 22 | Why it's safe |
|---|---|---|
| The track processes start after the template, and each guard (about 70 seconds) is on the critical path | They start right after Preflight, 5 seconds apart, so the guards run while the template deploys, and each waits for the parent's word: a private handoff directory (`Initialize-DemoPrivateDirectory`) where the parent writes the template's result (`infrastructure`: success, the loader settings, T3's free-offer choice; nothing secret). A failed template is handed over too: the tracks stop, and what they finished before is reported | Each process still runs its own guard ([ADR 0011](0011-control-surface-priority.md)); the handoff is written once, under a temporary name and then renamed |
| The bundle and the runner are built while the template deploys | They're built while Preflight runs, in their own process, which hands them over the same way (`artifacts`, with the build's error when it fails, written whatever happens) | Local only; the same build |
| T2's track starts after the whole template | A T2 restored from a golden snapshot starts its Restore as soon as the template has deployed `archost01` (its own nested deployment `archost01` succeeded, with a timestamp after this run began). Every other step, and every other track, waits for the template | That nested deployment comes after the template's resource group update, so no tag the track writes can be overwritten; the template touches `archost01` no more |
| T2's artifacts go after the Release | They travel in their own chunk Run Commands while the Release runs (`Invoke-DemoVmRunCommand -WhileRunning`); the Artifacts step sends whatever didn't arrive. The Release is always awaited and deleted, whatever happens to the work beside it | The chunks put nothing on the network, the guest stays air-gapped until the Release reconnects it, and the host's password was rotated before; managed Run Commands run in parallel on one VM (Phase 20 measured it) |
| T1's bundle and runner go one after the other | One queue for both (`Send-DemoChunkSet`): 8 chunk Run Commands in one wave | The chunk names differ by SHA-256; two senders on one VM would delete each other's chunks, so there's only ever one |
| T1's monitoring follows T3 and the activity profiles | The documented feature-flag merge runs right after T1's loader started the bootstrap, while no Run Command runs on `sqlvm01`; the Monitoring step only confirms the plugin | The extension update never overlaps a Run Command on the same VM (an extension operation once held a Run Command for 28 minutes, G1) |
| T3 is set up after T1's bootstrap | T1 joins the T3 group while the template deploys (Microsoft Graph only), and a new first step, T3Setup (stage T3), runs T3's setup from T1 before T1's artifacts: T3's telemetry started about 10 minutes after its setup in G6, which put T3 on T1's critical path. The T3 step reports those results, or runs them again when they didn't pass (`DEPLOY.T3.EARLYSETUP` **Warning**) | The setup needs only T1's identity and IMDS (System.Data.SqlClient), not T1's bootstrap; `-StopAfter`, `-FromStage`, and `-Resume` keep their meaning, because T3Setup belongs to stage T3 |

Not changed: the Release's order (the host password first, then the Release, which rotates the guest's password before the guest reconnects), the template itself, and the health reads.

## Validation results (2026-10-23, Phase 22)

| Step | Result |
|---|---|
| Run 1: destroy and redeploy (`acffb48`) | **Not a measurement:** the machine that ran it went to sleep, which froze every local process for about 35 minutes. Up to then, T2 ran about 9.6 minutes ahead of G6 and T1 about 5. Functionally no check failed. It found the Release defect below |
| The Release's reset decision | **Fixed and proven live** (`c213e1d`): an air-gapped agent answered `status: failed` with no resource, which the Release took for "no identity" in run 1 (it reconnected the guest without the reset; safe only because the destroy had deleted the captured machine). It now resets unless the agent names another identity; in run 2 the reset ran while the guest was air-gapped, and the onboarding found no local identity (**Onboard**) |
| Run 2: destroy | 1,191 seconds; the Arc resources first, the golden group and the Fabric items kept; only Resource Graph's lag and the governance role assignment left |
| Run 2: redeploy (`c213e1d`, the machine kept awake) | **63.7 minutes** end to end, the clock stopped with no check **Fail**: T1 and T3 ready at +26.8 minutes (G6: +36.3), the Fabric track at +17.1 (on F4), T2 at +61.7 (G6: +37.7), held back by the SQL Server extension's download in the guest (R72, about 29.5 minutes) and a longer Release (1,007 seconds: the agent's answer, then the reset). **The 30-minute target wasn't met** ([deployment](../deployment.md#faster-redeploy-phase-22)) |
| Run 2: validation, convergence | `validate.ps1` (every area): 89 checks, 70 **Pass**, 10 **Warning**, 1 **Manual action required** (the Hub tenant setting), 7 **Not selected**, and 1 **Fail**, `SECURITY.SECRETSCAN.OUTPUT`: 77 of its 79 matches are in the Fabric App's third-party packages under `out/`, and the other 2 were in scratch files since deleted (a follow-up; the demo's own output scanned clean). Telemetry, the Hub Estate, T2's instance (Standard, PAYG) and monitoring, T1's associated services, `T2.ARC.NODUPLICATES`, and `T2.GUEST.ISOLATION` **Pass**. A second `deploy.ps1` converged in **19.2 minutes** with nothing to change (nothing sent again, `AlreadyConnected`); Resource Graph: exactly one `arcsql01` machine, and only the `sqlvm01` and `arcsql01` SQL Server instances. At the coordinator's request, the run ended without `stop-demo.ps1`, handed over running to the owner's incident program |

## Amendments (2026-10-29, Phase 28: one command, one guided stop)

**Why:** two colleagues' first runs took more than 2 hours and never finished. At about 30 minutes, neither VM's bootstrap had started, T1's monitoring wasn't on, and T2 wasn't onboarded. The causes: T2's build without a golden snapshot (60–90 minutes); preflight's first policy inventory (7–13 minutes) on the critical path, then the template and the Run Command chunks before any bootstrap; `deploy.ps1` returning with `DEPLOY.T2.BACKGROUND` and a second command to remember (section 9); a PC that slept; T4's default size refused with `SkuNotAvailable`; chunk Run Commands stuck in `Deleting`; and a codespace's idle timeout. The owner (2026-10-29): "I want the build to run and not give a template that is reliant on me. This whole thing should be one click independent for anyone." And: "Users report that the deployments never finished. How can we make sure that the user is prompted appropriately and that they can't mess it up". The T2 decision is in [ADR 0006](0006-sql-editions-and-licensing.md#amendment-one-command-one-guided-stop-phase-28-2026-10-29).

| Before | Phase 28 | Why it's safe |
|---|---|---|
| `init.ps1`, then `deploy.ps1` | `deploy.ps1` with no configuration runs the first-run setup itself (`Initialize-DemoFirstRun`: `Initialize-DemoConfig` with the same prompts and `-CreateAdminGroup`; `-NonInteractive` where nobody can answer), and stops **NOT DONE** with the fix when something needs a person | Never signs in or changes the CLI context ([ADR 0023](0023-first-run-automation.md)); `init.ps1` keeps working on its own |
| Without a snapshot, return with `DEPLOY.T2.BACKGROUND`, then `deploy.ps1 -FromStage T2` | Wait for T2 by default in every install mode, up to `-T2WaitMinutes` (180, from 120: the build plus at least 45 minutes for a person at the guided stop); `-NoWaitForT2` opts out; `-WaitForT2` stays accepted, and is needed only in CI. On a time-out: **NOT DONE** with the exact command | Bounded; a golden restore doesn't build or stop, so it stays as fast as before. GitHub Actions keeps its inputs, its exit codes, and `DEPLOY.T2.BACKGROUND` |
| The wizard step by hand, from the host's printed steps | The guided stop in the T2 track: the host's request with a time limit, on-demand Bastion in the background, Arc onboarding first, then the host prepares setup pre-filled from a configuration file and one automatic sign-in of the guest; one prompt (a banner, a beep, the console flashing, the portal page in the browser, the steps, the time limit, a reminder every 5 minutes, and a `HUMAN ACTION REQUIRED: DEPLOY.T2.GUIDEDSTOP` line); the host's check of the result; then onboarding's configuration, PAYG, monitoring, and telemetry by themselves; Bastion removed and the host password rotated in a `finally` | Documented mechanisms only, never the portal automated; the host password never shown, and without a clipboard nothing set ([ADR 0009](0009-secrets-handling.md#phase-28-amendment-the-guests-one-automatic-sign-in-and-the-portal-password-reset-2026-10-29)); `GuestSignInCleanup` unchanged; the watchdog never restarts the host while the guided stop's time limit is open |
| The machine had to be kept awake by hand | `Enter-DemoKeepAwake` for the whole run (`ES_SYSTEM_REQUIRED`, `ES_DISPLAY_REQUIRED`, `ES_CONTINUOUS`), released in a `finally`; nothing off Windows | Phase 25a's helpers, as the golden scripts use them |
| The policy inventory before the template | With `networkMode` `private`, in the parallel run: preflight defers it (`-DeferPolicyInventory`, its checks **Not selected** for the moment), and a background job runs it beside the template and the tracks; its results replace the placeholders at the end, a **Warning** when it didn't finish. With `auto` or `public`: unchanged | The inventory resolves nothing the template needs then; the what-if still catches a denial before anything is created. Not with `public` (review fix): a policy that modifies SQL public access isn't a denial, so preflight must stop that run first |
| T4's refused default size was a **Fail** that needed a configuration edit | The Burstable fallback when `t4SkuName` isn't set: B1ms, then B2s, then no T4, recorded in the tag `DbHubT4Sku` ([ADR 0019](0019-t4-postgresql-flexible-server.md#2026-10-29-the-burstable-fallback-phase-28)) | Never a General Purpose size on its own; a size the configuration sets never changes |
| Chunk deletes waited up to 180 seconds each | No waits on deletes, extensions settled first, a watchdog with one restart, sequential after a stall ([ADR 0003](0003-t2-host-size-security-type-bootstrap.md#phase-28-amendment-chunk-hygiene-that-doesnt-stall-2026-10-29)) | 25 managed Run Commands per VM; the restart is `az vm restart`, within Contributor |
| `DEPLOY.SUMMARY` and an exit code that was 0 with open manual items | One banner: **DONE** (Database Hub shows every target, with where to look; section 1's list) or **NOT DONE** (why, the single next action, the exact command, how to resume, and `collect-diagnostics.ps1`); the exit code is 0 only when **DONE** (1 with a **Fail**, 2 otherwise). A plain `./scripts/deploy.ps1` continues an unfinished deployment from the state tags (not in GitHub Actions). **DONE** says when T4 isn't deployed and why, says plainly in `Developer` mode that T2 has no performance data or agent findings, and lists the optional Insights app with how to add it later | `DEPLOY.SUMMARY` stays; **DONE** needs a **Pass** for every requirement, read-only checks fill in what a resumed run didn't see itself (`Invoke-DemoDoneGate`), so deployment success alone is never **DONE** ([ADR 0012](0012-validation-model.md)) |
| Progress only in the console | One progress model, `out/deploy-progress.json`, written atomically by `deploy.ps1` and every track process at each step transition; `out/deploy-status.html`, regenerated at least every 15 seconds (a meta refresh; no JavaScript or external resources; every message HTML-encoded and redacted), with one banner in four states (Deploying, no action needed; Waiting for you; Done; Stopped, not done), the steps per track, a stale warning, and Azure-side waits marked "no action needed"; `status.ps1 -Watch` shows the same in a console; `collect-diagnostics.ps1` bundles the model with the results, the transcripts, and the saved instance views, redacted again and secret-scanned | Git-ignored `out/`; the model holds no secret, and the bundle fails closed |
| No word for sessions that can't answer | A notice at the start for a session that can't take keyboard input (redirected input, CI, an automation shell, an assistant), with `-NoWaitForT2`, `ProductKey`, and `Developer` and what each gives; a GitHub Codespaces idle-timeout warning with the setting that raises it; and a `PLAN FOR A PERSON` line with when a person is needed | The run goes on; GitHub Actions keeps today's behavior |

**Estimates, not measurements** (from documented step times): a first run in `PaygWizard` mode takes about 2 to 3 hours, with a person needed about 60 to 90 minutes after the start for about 10 minutes, plus 10 to 15 while setup installs; about 1.5 to 2.5 hours in `ProductKey` or `Developer` mode; a golden redeploy about 30 to 45 minutes (38.8 and 63.7 measured). The first fresh build with the parallel tracks measures it.

**Deviations from the brief, recorded for the owner:** a session that can't take keyboard input gets a notice and the run goes on (the brief's "before spending anything" is met by printing it before preflight), because an assistant may relay the guided stop to a person; `-Sequential` keeps no guided stop; `status.ps1` stays read-only and reports the guest's automatic sign-in leftovers as a **Warning**, which the host's next pass removes; and the host password rotation's failure is a **Warning** everywhere, not only at the guided stop.

## Validation results (2026-10-29, Phase 28)

Static only: unit tests for the first run from `deploy.ps1`, the wait by default, the guided stop's prompt, credentials, time-out, and continuation, the keep-awake, the T4 fallback, the policy inventory's deferral, the progress model and its page, the banners and exit codes, the DONE requirements, the Run Command watchdog, and the diagnostics bundle (`tests/unit/DbHubDemo.OneCommand.Tests.ps1`, `DbHubDemo.Progress.Tests.ps1`, `DbHubDemo.Tracks.Tests.ps1`, `DbHubDemo.Bundle.Tests.ps1`, `DbHubDemo.Lifecycle.Tests.ps1`, `DbHubDemo.Preflight.Tests.ps1`, `Vm.GuidedSetup.Tests.ps1`, and `Repo.LifecycleScripts.Tests.ps1`). A live proof from scratch needs a person at the guided stop: a throwaway resource group with its own prefix, a temporary Fabric workspace, `rg-<prefix>-golden` and `rg-<prefix>-control` untouched, and everything removed afterward ([implementation report](../implementation-report.md#phase-28-one-command-one-guided-stop)).

## Sources (checked 2026-10-29, Phase 28)

- `SetThreadExecutionState` (the keep-awake flags): <https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate>
- Install SQL Server using a configuration file (`/ConfigurationFile`, `UIMODE`): <https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-using-a-configuration-file>
- Install SQL Server from the command prompt (`/PID` optional, Evaluation without it): <https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt>
- Connect to a Windows VM with Bastion (RDP): <https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows>
- Reset a VM's password in the portal (**Help**, **Reset password**): <https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/reset-rdp>
- `az postgres flexible-server list-skus`: <https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-list-skus>
- `az vm get-instance-view` and `az vm restart`: <https://learn.microsoft.com/cli/azure/vm>
- `FlashWindowEx` and `GetConsoleWindow` (drawing attention to the console): <https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-flashwindowex>, <https://learn.microsoft.com/windows/console/getconsolewindow>
- `Start-Transcript` (the console's log for the diagnostics bundle): <https://learn.microsoft.com/powershell/module/microsoft.powershell.host/start-transcript>
- `Compress-Archive`: <https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/compress-archive>
- `WebUtility.HtmlEncode`: <https://learn.microsoft.com/dotnet/api/system.net.webutility.htmlencode>
- GitHub Codespaces' idle timeout (30 minutes by default, up to 240): <https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces>; the codespace lifecycle: <https://docs.github.com/codespaces/about-codespaces/understanding-the-codespace-lifecycle>; forwarding a port: <https://docs.github.com/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace>

## Sources (checked 2026-10-23, Phase 22)

- `az deployment group show` (a VM module's nested deployment, read while the template still deploys): <https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-show>
- Deployments - Get (`properties.provisioningState` and `properties.timestamp`): <https://learn.microsoft.com/rest/api/resources/deployments/get>
- Enable performance monitoring for SQL Server on Azure VMs (the feature-flag merge and its prerequisites: the extension Succeeded, the system-assigned identity, `Microsoft.AzureArcData`): <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm>
- Managed Run Command (parallel execution of multiple scripts, 25 per VM): <https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed>, <https://learn.microsoft.com/azure/virtual-machines/run-command-overview>
- PSSerializer (the handoff's XML): <https://learn.microsoft.com/dotnet/api/system.management.automation.psserializer>

## Sources (checked 2026-10-21)

- Incremental snapshots (first copy full, billed on used size, Standard HDD with ZRS where available, usable at once, background copy): <https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots>
- Attach an existing OS disk to a new VM (computer name kept): <https://learn.microsoft.com/azure/virtual-machines/attach-os-disk>
- Restrict managed disk import and export (`NetworkAccessPolicy` prevents export): <https://learn.microsoft.com/azure/virtual-machines/disks-restrict-import-export-overview>
- `az snapshot create` (`--incremental`, `--network-access-policy`, `--public-network-access`): <https://learn.microsoft.com/cli/azure/snapshot#az-snapshot-create>
- Disks - Create Or Update (`creationData.createOption` `Copy`): <https://learn.microsoft.com/rest/api/compute/disks/create-or-update>
- `azcmagent disconnect --force-local-only`: <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-disconnect>
- Remove extensions before disconnecting ("aren't recognized if you reconnect"): <https://learn.microsoft.com/azure/azure-arc/servers/uninstall-agent>
- `azcmagent extension remove --all` (local, works disconnected, extension manager stopped): <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-extension>
- `azcmagent check`: <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-check>
- `azcmagent connect`: <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-connect>
- Azure Arc network requirements: <https://learn.microsoft.com/azure/azure-arc/servers/network-requirements>
- `Set-VM` (`-AutomaticStartAction`): <https://learn.microsoft.com/powershell/module/hyper-v/set-vm>
- `Disconnect-VMNetworkAdapter` and `Connect-VMNetworkAdapter`: <https://learn.microsoft.com/powershell/module/hyper-v/disconnect-vmnetworkadapter>, <https://learn.microsoft.com/powershell/module/hyper-v/connect-vmnetworkadapter>
- PowerShell Direct (works without a network connection): <https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct>
- Instance Metadata Service (`compute/vmId`): <https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service>
- IP address 168.63.129.16 (ports 80 and 32526 aren't subject to network security groups): <https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16>
- VM extensions, network access (HostGAPlugin): <https://learn.microsoft.com/azure/virtual-machines/extensions/features-windows#network-access>
- `az network nsg rule delete`: <https://learn.microsoft.com/cli/azure/network/nsg/rule#az-network-nsg-rule-delete>
- Managed Run Command (parallel execution of multiple scripts): <https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed>
- Run Command overview (25 managed Run Commands per VM): <https://learn.microsoft.com/azure/virtual-machines/run-command-overview>
- Azure CLI concurrent execution and `AZURE_CONFIG_DIR`: <https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-tips#concurrent-execution>
- PowerShell background jobs: <https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_jobs>
- Windows Server 2022 evaluation (180 days): the [Evaluation Center](https://www.microsoft.com/evalcenter/evaluate-windows-server-2022), as [ADR 0006](0006-sql-editions-and-licensing.md) records
- SQL Server enabled by Azure Arc, license types and billing: <https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing>
- Azure Retail Prices API: <https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices>
