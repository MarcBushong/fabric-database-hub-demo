# VM bootstrap

The bootstrap loader and the resumable state machines for T1 (`sqlvm01`) and the T2 host (`archost01`) ([ADR 0003](../../docs/adr/0003-t2-host-size-security-type-bootstrap.md)). Everything here runs as SYSTEM on **Windows PowerShell 5.1** and is ASCII-only; `tests/PSScriptAnalyzerSettings.Vm.psd1` checks the syntax against 5.1.

## Flow

1. `deploy.ps1` builds the bundle (`vm/` and `database/` plus `bundle-manifest.json`) with `New-DemoBootstrapBundle` and sends it to each VM with `Send-DemoBootstrapBundle`: `New-DemoBootstrapChunk` turns it into SHA-256-checked chunk scripts (512 KiB of data each by default), and each runs in its own managed Run Command, `DbHubDemo-Chunk-<sha12>-<nnn>`, which writes `downloads\<sha12>\chunk-<nnn>.bin` and `.sha256` and is deleted once it succeeds. Nothing secret travels in a chunk.
2. `deploy.ps1` deploys again with the bundle's SHA-256 and chunk count. `infra/modules/bootstrap.bicep` then runs `Invoke-DemoBootstrapLoader.ps1` in the managed Run Command `DbHubDemo-Bootstrap`, with `-BundleSha256`, `-ChunkCount`, `-Role` (`SqlVm`, `ArcHost`, or `EvalArcVm` in the opt-in evaluation-only mode), and `-SettingsJson` (Base64).
3. The loader re-checks every chunk (naming any missing or bad one), joins them, verifies the whole bundle's SHA-256 (a mismatch deletes the joined file and the chunks and stops), extracts it with `ZipFile.ExtractToDirectory` to `C:\ProgramData\DbHubDemo\bundle\<hash prefix>`, writes `settings.json`, restricts the folder to SYSTEM and Administrators, registers the task `DbHubDemo-Bootstrap` (at startup and every 5 minutes), starts it, and returns. `Wait-DemoBootstrapLoader` reports its exit code.
4. The task runs `Invoke-SqlVmBootstrap.ps1`, `Invoke-HostBootstrap.ps1`, or `Invoke-EvalArcVmBootstrap.ps1`. Each run takes the lock, re-checks the steps, and acts only where a check fails.

## Files

| File | Purpose |
|---|---|
| `Invoke-DemoBootstrapLoader.ps1` | The loader embedded in the template. Self-contained and small (a test keeps it under the 96 KB `loadTextContent` limit). A Windows-only test runs its assembly and extraction in Windows PowerShell 5.1. |
| `DbHubDemo.Vm.psd1`, `DbHubDemo.Vm.psm1`, `lib/` | The VM-side module: redacting log, `state.json` store, lock file, step runner, `health.json` writer, verified downloads with retries and resume, DPAPI helpers, disk setup, and Windows-authentication SQL helpers. |
| `Invoke-SqlVmBootstrap.ps1` | T1 steps: `DataDisk` (**Not selected** without a data disk, in `lowest-cost`), `SqlService`, `AssociatedServices` (stops, disables, and uninstalls the image's Analysis Services and Integration Services; a failed uninstall is only a warning), `SqlAdminAccess`, `ConfigureSql`, `SeedDatabase`, `WorkloadRunner` (**Not selected** when the deployment carries no runner). |
| `Invoke-HostBootstrap.ps1`, `HostPlatform.ps1`, `HostSteps.ps1` | T2 host steps, in order: `NestedVirtualization`, `HyperVRole`, `DnsServerRole`, `NatNetwork`, `DnsForwarder`, `DataDisk` (without a data disk: a free-space check on `C:` and folders under `C:\DbHubDemo`), `GuestOsMedia`, `GuestVhdx`, `GuestVm`, `GuestOnline`, `GuestHardening`, `SqlMedia`, `GuestWebView2` (`PaygWizard` only), then by install mode `SqlUnattendedInstall` and `ArcOnboarding`, or `ArcOnboardingBeforeWizard`, `GuidedSetup` (Phase 28: the pre-filled SQL Server setup and its logon task in the guest, and Virtual Machine Connection at an administrator's sign-in to the host), `SqlSetupWizard` (while `deploy.ps1` waits for a person, the guest signs itself in once and opens the setup; the host checks the result and cleans up the automatic sign-in), and `GuestSignInCleanup` (every install mode: removes the sign-in data that setup leaves on the VM, verifies that none remains, and turns IE Enhanced Security Configuration back on); then `ConfigureSql`, `SeedDatabase`, and `WorkloadRunner`. |
| `Set-DemoGuidedSetupRequest.ps1` | Phase 28: `deploy.ps1`'s request on the host while it waits for a person at the `PaygWizard` guided stop (`guided-setup-request.json`: identifiers, the Azure extension's subscription, resource group, region, and tenant, and an expiry; never a secret), written or cleared in a managed Run Command. The host arms the guest's one automatic sign-in only while it's valid. |
| `Set-DemoSqlProductKey.ps1` | Phase 7 hook for `ProductKey` mode. `configure-arc.ps1` runs it in a managed Run Command with the key as a protected parameter; it stores the key with DPAPI (LocalMachine) for the install step. |
| `Invoke-DemoArcOnboard.ps1` | Phase 7 Arc onboarding, run by `configure-arc.ps1` in managed Run Commands on the host: `-Action Probe` (read-only: PowerShell Direct, IMDS and wire-server isolation, DNS, `azcmagent show -j`), `Onboard` (verified agent MSI, silent install in the guest, `azcmagent connect` with the token passed only as a script-block argument and to the agent in a protected config file that is zeroed and deleted right after; the host identity's token from IMDS whenever it's attached, with authorization refusals retried while its role assignment propagates; then the marker), and `WriteMarker`. Prints one JSON line (ADR 0005, ADR 0009). |
| `Invoke-DemoSignInResidue.ps1` | Phase 26d sign-in data sweep (ADR 0009), self-contained for Windows PowerShell 5.1: finds token-shaped values in setup's log folders, the temp folders, PowerShell history and transcripts, the Run Command handlers' and the Azure and Arc agents' folders, the demo's own files, and the PowerShell, Application, and Security event logs, plus the sign-in caches, on the VM and, over PowerShell Direct, in the T2 guest. Since Phase 28 it also reports Windows automatic sign-in left armed (AutoAdminLogon on or `AutoLogonCount`, the LSA `DefaultPassword` secret, the Winlogon `DefaultPassword` value, and in the guest the Winlogon `DefaultUserName` value), each a **Fail**. Prints counts and locations only. `Clean` removes what it found, turns automatic sign-in off, clears a PowerShell or Application log only when it holds a token-shaped value, and the Security log only on request; then it scans again. The host and evaluation VM steps dot-source it; `check-sign-in-data.ps1`, the Arc onboarding, and the golden capture and test run it in a Run Command. |
| `Invoke-EvalArcVmBootstrap.ps1` | **Evaluation only** (`t2Mode = EvaluationOnlyAzureVm`, ADR 0006). Steps on the Azure VM `arcsql01`: `ArcEvaluationPrep` (`MSFT_ARC_TEST`, the `BlockAzureIMDS` firewall rule), `SqlMedia`, the install-mode steps, `SqlAdminAccess`, `ConfigureSql`, `SeedDatabase`, `WorkloadRunner` (**Not selected** in this mode for now), and `DisableAzureGuestAgent` last. Reuses T1's SQL helpers and the guest's setup switches. |
| `lib/Workload.ps1` | Phase 13 runner install ([ADR 0010](../../docs/adr/0010-workload-generator-technology.md#phase-13-delivery-and-hosting-as-built-2026-10-20)): assembles and verifies the runner from its Run Command chunks, downloads the pinned .NET runtime (SHA-512), runs the runner's `setup`, writes `workload-install.json`, and registers the SYSTEM task `DbHubDemo-Workload`. |
| `Start-DemoWorkload.ps1` | The task's self-contained wrapper, copied next to the runner: sets the configured activity profile once after each install, and at a boot only when `activityProfileOnBoot` is true, then runs `profile run` until two minutes before the next auto-shutdown, for T1 (plus T3 once `Enable-DemoT3Workload` has run), or for T2 in the guest. |
| `Invoke-DemoWorkloadControl.ps1` | Run by `Enable-DemoT3Workload` and `Invoke-DemoWorkloadCommand` through action Run Command: `-Action EnableT3`, `Runner` (any runner command; on the host it's relayed into the guest over PowerShell Direct), or `StopGuest`. Prints one `DBHUBDEMO-WORKLOAD` JSON line. |

## Step runner

- A step has a `Test` and a `Set` script block. `Set` runs only when `Test` fails, so a re-run converges.
- A step can finish, ask for a reboot, wait (for Arc onboarding or a product key), or need manual action (the `PaygWizard` step). The runner stops at the first step that isn't done and reports that state.
- In `PaygWizard` mode, `Invoke-DemoHostGuidedSetupGuard` runs before every pass (Phase 28): it finishes a guest password rotation that stopped midway, and cleans up the guest's automatic sign-in whenever it's armed while no person is expected any more.
- Failed attempts are retried up to the step's limit. A step that still fails stays **Failed** until the next loader run starts a new generation.
- A reboot is recorded as `pendingReboot`, and the task restarts the computer. After startup the step is re-checked. A per-step cap stops reboot loops.

## Files on the VM (`C:\ProgramData\DbHubDemo`)

| Path | Contents |
|---|---|
| `settings.json` | Non-secret settings from the template, plus the role, bundle hash, and generation |
| `state.json` | Per-step status, attempts, timestamps, and last error |
| `health.json` | Summary for the validator; see `vm/health/` |
| `logs\` | Redacted logs: URL query strings, SAS signatures, tokens, passwords, and product keys are removed. The loader's `loader.log` isn't redacted, because none of its inputs (hash, chunk count, role, settings) is secret. |
| `downloads\<sha12>\` | Bundle chunks (`chunk-<nnn>.bin` and `.sha256`) until the loader installs the bundle and deletes them; the workload runner's chunks the same way, until the `WorkloadRunner` step assembles them |
| `bundle\<sha12>\` | The installed bundle, marked `.complete`; the previous one is kept for rollback |
| `runner\<sha12>\`, `runner\Start-DemoWorkload.ps1` | The installed workload runner (marked `.complete`) and the wrapper the task runs |
| `dotnet\` | The pinned .NET runtime, extracted from Microsoft's zip after its SHA-512 check |
| `workload-install.json`, `t3-workload.json`, `workload-boot.json`, `activity.json` | What the `WorkloadRunner` step installed (runner, runtime, targets, profile, shutdown schedule, setup results); T1's record that T3 is enabled; the wrapper's once-per-boot marker; the runner's T3 activity profile |
| `protected\` | DPAPI-protected guest password and, in `ProductKey` mode, the product key until setup succeeds |
| `guided-setup-request.json`, `guided-setup-armed.json`, `guided-setup-last.json`, `Open-GuestConsole.ps1`, `guided-setup-steps.txt` | Phase 28's guided stop: `deploy.ps1`'s request (with its expiry), the record of an armed automatic sign-in (written before the arm, removed only after a complete cleanup), the last cleanup's result (what it found, never a value), and the host's logon task's script and steps; the last two are removed once the step is done |
| `arc-onboarded.json` | Written by `Invoke-DemoArcOnboard.ps1` after `azcmagent connect` succeeds: `schemaVersion` 1, `machineName`, `status` `Connected`, `resourceId`, `connectedUtc`, plus `guestVmId` (a marker for an earlier build of the guest doesn't count), `agentVersion`, `tokenSource`, `correlationId`, and `evaluationOnly` |
| `media-hashes.json` | Hash cache for verified media, and the first hash of media pinned without one (trust on first use) |

## Run it by hand

From an elevated Windows PowerShell on the VM: `Start-ScheduledTask -TaskName DbHubDemo-Bootstrap`, then read `health.json` or run `vm\health\Get-DemoHealth.ps1` from the bundle folder.
