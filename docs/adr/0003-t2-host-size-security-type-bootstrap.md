# ADR 0003: T2 host size, security type, and bootstrap state machine

- **Status:** Accepted. Validated live on 2026-10-20 and 2026-10-21: chunk delivery, a host restart that resumed the state machine, the guest build, and the `PaygWizard` step order (Arc first, then the wizard). One live test of a Trusted Launch host is still open, so the host stays `Standard`.
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** Engineering (approved plan §3.1, §4.2, §4.3, §9.2, §9.4)
- **Related:** [ADR 0004](0004-guest-imds-isolation.md), [ADR 0005](0005-arc-onboarding-authentication.md), [ADR 0006](0006-sql-editions-and-licensing.md), [ADR 0010](0010-workload-generator-technology.md), [architecture](../architecture.md)

## Context

- **Nested virtualization:** the Dsv5, Dasv5, Dsv6, Esv5, and Esv6 size pages list it as supported; the B-series (Bsv2) pages list it as not supported. A host plus one SQL Server guest needs about 16 GiB of memory.
- **Trusted Launch:** the plan found no documented restriction. A re-check on 2026-10-19 found the opposite: search results citing the Trusted Launch page, plus Microsoft Q&A answers, say nested virtualization isn't supported with Trusted Launch even on sizes that support it. A direct read of the page wasn't possible in this session, so this must be re-verified before Phase 6.
- **Reboots:** installing the Hyper-V role needs a reboot. The Custom Script Extension forbids reboots inside its scripts. Managed Run Command supports asynchronous execution and protected parameters, but its behavior across a reboot isn't documented, and no inline-script size limit is documented.
- **Configuration tooling:** Azure Automation State Configuration retires on 2027-09-30. Azure Machine Configuration needs packaged configurations, hosting, and policy assignments, which is heavy for a one-time orchestration with reboots.
- **Install modes:** `t2SqlInstallMode` is `PaygWizard` (default), `ProductKey`, or `Developer` (ADR 0006). Only `PaygWizard` has a manual step. The setup wizard needs a desktop, so the guest is Windows Server with Desktop Experience in every mode, which keeps one guest image.
- **Artifacts (revised 2026-10-20):** the bootstrap bundle travels in SHA-256-checked Run Command chunks, and media downloads directly from pinned Microsoft URLs with SHA-256 checks (ADR 0001; Phase 6 implements both). The artifact cache that used to hold them was dropped (ADR 0016, C9). The T2 build runs in parallel with T1 and T3 configuration (plan §9.6).

## Decision drivers

1. Lowest cost that still runs one SQL Server guest well.
2. A bootstrap that survives reboots and re-runs, and never fails an extension on purpose.
3. No dependency on retiring services.
4. Secure by default without breaking nested virtualization.

## Considered options

- **Sizes:** E2s_v5, D4as_v5, D8as_v5, Dsv6 or Esv6 equivalents, and B-series (rejected: not supported).
- **Bootstrap mechanism:**
  1. Custom Script Extension with a reboot workaround (rejected: reboots are forbidden).
  2. DSC extension or Automation State Configuration (rejected: retiring).
  3. Azure Machine Configuration (rejected for v1: needs packaging, hosting, and policy).
  4. **Managed Run Command that installs a resumable SYSTEM scheduled-task state machine.**

## Decision

### Sizes, disks, and pricing options

| Profile | Host size | Guest | Disks |
|---|---|---|---|
| `lowest-cost` | `Standard_E2s_v5` (2 vCPU, 16 GiB) | 2 vCPU, 8 GiB static | OS on Standard SSD (E10); no separate data disk since 2026-10-20 (ADR 0016) |
| `demo-day` | `Standard_D4as_v5` (4 vCPU, 16 GiB) | 2 vCPU, 8 GiB static | OS and data on Standard SSD; data on Premium SSD v2 with a zone (ADR 0016) |
| `enhanced-performance` | `Standard_D8as_v5` (8 vCPU, 32 GiB) | 4 vCPU, 16 GiB static | Premium SSD |

- The size is a parameter restricted to the documented nested-capable families. `preflight.ps1` checks availability, restrictions, and quota in the region, and suggests alternatives when a check fails.
- The data disk (128 GiB by default) holds the downloaded media and the guest VHDX (64 GB, dynamically expanding). Premium SSD v2 is evaluated in Phase 5 (ADR 0016, C10). Without a data disk (`lowest-cost`, or `dataDiskSku` `None`), they go under `C:\DbHubDemo` on the 128 GiB OS disk, after a free-space check (Phase 6 notes).
- **Spot:** opt-in with `hostPriority = Spot` and eviction policy `Deallocate` (ADR 0016, C5). The eviction risk is documented.
- **Park T2:** `stop-demo.ps1 -ParkT2` shuts the guest down and deallocates only the host (ADR 0016, C4).

### Security type

- `securityType` is a parameter on both VMs.
- **T2 host:** defaults to `Standard`, because nested virtualization is the host's only purpose. `TrustedLaunch` can be selected, but preflight warns that it's reported as incompatible with nested virtualization.
- **T1:** defaults to `TrustedLaunch` only when the Marketplace image advertises Trusted Launch support in its image features, which preflight checks with `az vm image show`. Otherwise it uses `Standard` and reports a Warning.

### Bootstrap

1. A managed Run Command (`Microsoft.Compute/virtualMachines/runCommands`, `asyncExecution: true`) runs the bootstrap loader (ADR 0001). The loader assembles the versioned script bundle from SHA-256-checked Run Command chunks, checks the bundle's SHA-256, and unpacks it to `C:\ProgramData\DbHubDemo\`, which only SYSTEM and Administrators can access.
2. The loader registers the scheduled task `DbHubDemo-HostBootstrap`. It runs as SYSTEM at startup and every 5 minutes, and a lock file prevents concurrent runs. The loader starts the task and returns, so the extension never waits on a reboot.
3. The task runs `Invoke-HostBootstrap.ps1`, a resumable state machine. State lives in `C:\ProgramData\DbHubDemo\state.json` (step, attempts, timestamps, last error, overall status). Each step is idempotent and checks before it acts. A step that needs a reboot records `pendingReboot` and restarts the computer from the task, never from an extension.
4. **Steps:**
   1. Check that nested virtualization is available. If it isn't, report **Fail** and point to the evaluation-only fallback (ADR 0006).
   2. Install the Hyper-V role and tools, then reboot.
   3. Create the internal switch and NAT (`192.168.200.0/24`, host `192.168.200.1`) and the host DNS forwarder (ADR 0004). The DNS forwarder step waits until the new gateway address is usable and confirms that the DNS Server listens on it, because a DNS Server restarted while the address is still tentative can't bind it (Phase 16 live finding, 2026-10-21).
   4. Initialize the data disk, or, without one, check that the OS disk has room for the guest.
   5. Download the Windows Server evaluation media directly from its pinned Microsoft URL, with retries that resume the download, and verify its SHA-256. A mismatch fails closed.
   6. Build the VHDX with DISM from the Datacenter (Desktop Experience) image, using an unattend file. The guest password is generated on the host (ADR 0009).
   7. Create the Generation 2 guest `arcsql01` with automatic start and a `ShutDown` stop action, then wait until PowerShell Direct works.
   8. Harden the guest: block IMDS and the wire server, apply the host-enforced port ACLs, point the guest's DNS at the host, and set the computer name (ADR 0004).
   9. Copy the SQL Server 2022 media into the guest and verify its SHA-256. In `PaygWizard` mode, also install the WebView2 runtime in the guest from Microsoft's signed standalone installer over HTTPS, because the wizard's Azure Login needs it and Windows Server 2022 doesn't include it (Phase 7 live finding).
   10. Install SQL Server according to the install mode:
       - **`ProductKey` or `Developer`:** unattended command-line install. Then report `Waiting for Arc onboarding` so the orchestrator onboards with the caller's token (ADR 0005).
       - **`PaygWizard`:** report `Waiting for Arc onboarding` first. After onboarding, report **Manual action required** with the exact wizard steps and an on-demand Bastion link (ADR 0006). The machine is already Arc-connected, so the wizard's Azure Extension page is filled in from that connection; it still needs the operator's own Azure Login (validated live 2026-10-21, ADR 0005). Then poll until the instance is detected and resume automatically.
   11. Configure SQL Server (Query Store, file growth caps), seed the `ContosoCare` database, and install the workload runner, delivered as ADR 0010 describes.
   12. Write `health.json`, including guest state read over PowerShell Direct.

### Supporting files

- **`vm/dsc/`** holds declarative desired-state data files (`host.psd1`, `guest.psd1`) that the state machine converges to, plus a README that points to this ADR for why the DSC extension and Machine Configuration aren't used.
- **T1** uses the same loader and state-machine pattern without Hyper-V: data disk (when the profile has one), SQL Server configuration, seed, runner, and `health.json`.

## Consequences

- **Positive:** reboots are handled by the OS, not by an extension. Re-running a stage converges. The state file makes progress visible to the validator through Run Command.
- **Negative:** the first deploy is long (about 60–90 minutes for T2, to be measured). The state machine is custom code that needs tests. Desktop Experience makes the guest image larger. With no artifact cache (dropped 2026-10-20), every guest build downloads its media from Microsoft again, and a changed download URL or hash fails closed until the pin is updated.
- **Risks accepted:** inline Run Command scripts are kept small because no size limit is documented. If Trusted Launch turns out to support nested virtualization, a superseding ADR can change the host default.

## Phase 6 implementation notes (2026-10-19)

**Bootstrap delivery (revised 2026-10-20: Run Command chunks; the artifact cache and its SAS are gone).**

- **Bundle:** `New-DemoBootstrapBundle` builds a deterministic zip of `vm/` and `database/` (no Markdown), with `bundle-manifest.json` listing every file's SHA-256 and the media pins. About 70 KB today, so one chunk at the default size. It holds no secrets.
- **Chunks:** `New-DemoBootstrapChunk` is pure. It splits the zip into 512 KiB pieces by default (1–512 KiB; 512 KiB is the largest size proven live) and turns each into an ASCII-only Windows PowerShell 5.1 script with the Base64 data and the expected hashes inlined; the scripts take no Run Command parameters. Each writes `C:\ProgramData\DbHubDemo\downloads\<sha12>\chunk-<nnn>.bin` and `.sha256` atomically after it checks the chunk's SHA-256 (exit 1 on a mismatch, writing nothing), restricts `C:\ProgramData\DbHubDemo` to SYSTEM and Administrators when it creates it, and exits 0 without writing when the chunk is already there. It refuses content that contains a registered secret or matches the module's redaction patterns.
- **Delivery:** `Send-DemoBootstrapBundle` sends one VM's chunks in order through `Invoke-DemoAz rest`: PUT the managed Run Command `DbHubDemo-Chunk-<sha12>-<nnn>` (body from a temporary file, `--body @<file>`, because cmd.exe can't pass large or quoted values to `az.cmd`; `asyncExecution: false`, `treatFailureAsDeploymentFailure: false`, `timeoutInSeconds`), poll `GET ...?$expand=instanceView` until the execution state is `Succeeded`, `Failed`, `TimedOut`, or `Canceled`, require exit code 0, then DELETE it and wait until it's gone before the next chunk.
  - **Hygiene:** a VM holds at most one chunk Run Command at a time; Azure allows 25 managed Run Commands per VM. Leftover `DbHubDemo-Chunk-*` Run Commands are deleted before the first chunk and in a `finally` block. A 409 Conflict on the PUT is retried with backoff (10, 20, 40, 80, 120 seconds), because tenant policies install the Guest Configuration and Defender for SQL extensions after a deployment (ADR 0012, `PREFLIGHT.POLICY.EXTENSIONS`).
  - **Documented limits (checked 2026-10-20):** 25 managed Run Commands per VM; the instance view keeps the last 4 KB of output and error; an ARM request is at most 4,194,304 bytes, and a template resource definition at most 1 MB. Learn documents no size limit for an inline script or its parameters.
  - **Live check (2026-10-20, West US 3):** 48, 192, and 512 KiB chunks all worked. Each took about 60–80 seconds whatever its size (PUT, agent pickup, polling, and delete), so the default is 512 KiB.
  - **Live finding: folder permissions.** Running `icacls <folder> /inheritance:r /grant:r SID:(OI)(CI)F /T` left every file with an empty ACL that even SYSTEM couldn't read, and the first loader run failed with "access denied". The loader, the VM module, and the chunk writer now set the ACL on the folder only and run `icacls <folder>\* /reset /T` so children inherit it. A convention test forbids `/grant` with `/T`.
- **Template:** `infra/modules/bootstrap.bicep` adds the managed Run Command `DbHubDemo-Bootstrap` to `sqlvm01` and `archost01` only when `bootstrapBundleSha256` is set. It uses `asyncExecution: true` and `treatFailureAsDeploymentFailure: false`, and its script is the loader, embedded with `loadTextContent()` (about 18 KB; a test keeps it under the 96 KB limit). `parameters` carries `BundleSha256`, `ChunkCount`, `Role` (`SqlVm` or `ArcHost`), and `SettingsJson`; there are no protected parameters. `SettingsJson` is Base64-encoded, because Run Command passes parameters to a Windows script as `-Name value` arguments, where JSON quotes don't survive.
- **Order (`deploy.ps1`, Phase 13):** deploy the VMs, run `Send-DemoBootstrapBundle` for each VM, deploy again with `bootstrapBundleSha256` and `bootstrapChunkCount` (`Get-DemoDeploymentParameter -BootstrapBundleSha256 -BootstrapChunkCount`), then run `Wait-DemoBootstrapLoader`. Because the deployment doesn't fail when the loader fails, `Wait-DemoBootstrapLoader` reads the loader's instance view and reports `INFRA.BOOTSTRAP.LOADER_<VM>`: **Pass** for exit code 0, **Fail** with the loader's error otherwise, and **Warning** while it's still running.
- **Re-runs:** a new bundle hash, chunk count, or settings change the Run Command, so ARM runs the loader again. An unchanged one doesn't run again, and the scheduled task keeps converging on its own.
- **Deploy to Azure button:** the portal can't send the chunks, so `bootstrapBundleSha256` stays empty. The button provisions the infrastructure only, and the bootstraps start on `deploy.ps1 -Resume`. This replaces ADR 0001's loader that waits for the cache: no loader polls for an artifact that may never arrive.

**Loader and task.**

- **Critical fix (review finding, 2026-10-20):** the first loader passed `bundle-<sha12>.zip.partial` to `Expand-Archive`, which Windows PowerShell 5.1 rejects for any extension other than `.zip` (".partial is not a supported archive file format"), so neither VM would have bootstrapped, and `treatFailureAsDeploymentFailure: false` would have hidden it. The loader now renames the verified file to `bundle-<sha12>.zip` and extracts it with `[System.IO.Compression.ZipFile]::ExtractToDirectory`, and a Windows-only Pester test runs the assembly and extraction in `powershell.exe` 5.1 with a real zip.
- **Assembly:** when `bundle\<sha12>\.complete` exists, the loader skips straight to registering the task. Otherwise it re-verifies every chunk against its `.sha256` file and names any missing or bad index, joins the chunks into `bundle-<sha12>.zip.partial`, and verifies the whole bundle's SHA-256. A mismatch fails closed: the joined file and the chunk folder are deleted and nothing is installed. It extracts into a staging folder, moves it to `C:\ProgramData\DbHubDemo\bundle\<sha12>`, writes `.complete`, deletes the zip and the chunks, and restricts `C:\ProgramData\DbHubDemo` to SYSTEM and Administrators.
- The task is named `DbHubDemo-Bootstrap` on both VMs, not `DbHubDemo-HostBootstrap`. It runs as SYSTEM at startup and every 5 minutes, ignores new instances while one runs, and stops after 6 hours. It runs `Invoke-HostBootstrap.ps1` on the host and `Invoke-SqlVmBootstrap.ps1` on T1.
- **Generations:** each loader run starts a generation, `<hash prefix>-<UTC time>`. A new generation re-checks every step and retries failed ones. Within a generation, a failed step stays failed instead of retrying every 5 minutes.
- **Locking and reboots:** `bootstrap.lock` is opened exclusively, so a second run exits. A step that needs a restart records `pendingReboot`, writes `health.json` (`RebootPending`), and restarts from the task. A per-step cap stops reboot loops.

**Security type.** The Trusted Launch page (re-read 2026-10-19; updated 2026-09-25) doesn't list nested virtualization among unsupported features, but Microsoft Q&A answers say it isn't supported. The host default stays `Standard` until the live test. Trusted Launch is the default for new Generation 2 VMs from Compute API `2025-11-01`, so the template always sets `securityProfile.securityType`, including `Standard`. `preflight.ps1` resolves `securityType.t1 = Auto` from `az vm image show`: `TrustedLaunch` when the image is `V2`, its `SecurityType` feature contains `TrustedLaunch`, and the size doesn't report `TrustedLaunchDisabled`; otherwise `Standard` with a Warning.

**T1.**

- **No SQL VM storage configuration:** automated storage configuration is documented for Premium SSD only, with separate data and log disks. When T1 has its one data disk (Standard SSD, Premium SSD v2, or the P10 opt-in), the bootstrap formats LUN 0 (NTFS, 64 KB clusters) and puts the `ContosoCare` data and log files in `F:\SQLData` and `F:\SQLLog`.
- **No data disk (`lowest-cost`, 2026-10-20):** the template creates no data disk, the `DataDisk` step is **Not selected**, and `ContosoCare` goes in SQL Server's default data and log folders on the OS disk (`SERVERPROPERTY('InstanceDefaultDataPath')` and `'InstanceDefaultLogPath'`). Its files stay capped at 16 GB of data and 8 GB of log.
- **Least-privilege SQL IaaS Agent:** SYSTEM isn't guaranteed to be sysadmin. If it isn't, the bootstrap uses the documented recovery (start in single-user mode for `SQLCMD`, then add `BUILTIN\Administrators` to sysadmin) and reports a Warning.
- The workload-runner step reported **Not selected** until Phase 13, which made it real (see the Phase 13 notes below).

**T2 host and guest.**

- **Nested-virtualization check:** the processor flags from `Win32_Processor` are only a fast path. When they don't show support, the step installs the Hyper-V role, and the role's prerequisite failure ("The processor does not have required virtualization capabilities") is the final **Fail** that points to the evaluation-only fallback. Other install errors are retried.
- **Media (revised 2026-10-20):** the host downloads the guest media from the URLs pinned in `config/versions.json`, carried in the bundle manifest, and verifies each SHA-256; a mismatch fails closed. There's no artifact cache. A download is retried up to 5 times with exponential backoff (15, 30, 60, and 120 seconds), and each retry resumes from the bytes already in `<file>.partial` with an HTTP Range request: on 206 the host appends, on 200 it starts over, and the `.partial` file is kept between attempts and between runs. A `.partial` file left by a different URL is discarded. A pin with a null `sha256` is trusted on first use: the first hash is recorded in `media-hashes.json`, and health reports a Warning.
- **Rebuild time (estimate, not measured):** a guest build downloads about 6.2 GB from Microsoft: the Windows Server 2022 evaluation ISO (5,044,094,976 bytes, about 4.7 GiB) and one SQL Server 2022 ISO (1,163,051,008 bytes for the Evaluation media, 1,163,053,056 for Developer), as pinned in `config/versions.json`. At an assumed 20–100 MB/s from the Microsoft download hosts that's about 1–5 minutes, plus a few minutes to hash 6.2 GB on Standard SSD, so a rebuild without a cache costs minutes, not hours, of the 60–90 minute T2 build. The measured time is a live check pending go-ahead.
- **No data disk (`lowest-cost`, 2026-10-20):** the media and the guest VHDX go under `C:\DbHubDemo\media` and `C:\DbHubDemo\vms` on the host's 128 GiB OS disk. Before it creates them, the `DataDisk` step checks the free space on `C:` and fails with a clear message when it's below the VHDX's maximum size (64 GB), plus the two ISOs for the install mode (sizes from the manifest), plus a 10 GB margin, about 80 GB in all. The remedy is `dataDiskSku` `E10`.
- **SQL media by mode:** `PaygWizard` and `ProductKey` use the SQL Server 2022 Evaluation ISO; `ProductKey` adds `/PID`. `Developer` uses the Developer ISO, whose product key is predefined, so it passes no `/PID`; Learn documents no Developer key.
- **Product-key hook (Phase 7):** the orchestrator runs `vm/bootstrap/Set-DemoSqlProductKey.ps1` in a managed Run Command with the key in `protectedParameters`. The script stores it with DPAPI (LocalMachine) in `protected\sql-product-key.bin` and starts the task. The install step reports `WaitingForProductKey` until the file exists and deletes it after setup succeeds. Logs redact `/PID` values and key patterns.
- **Arc marker (Phase 7):** after `azcmagent connect` succeeds, the orchestrator writes `C:\ProgramData\DbHubDemo\arc-onboarded.json` on the host: `{ "schemaVersion": 1, "machineName": "arcsql01", "status": "Connected", "resourceId": "...", "connectedUtc": "..." }`. The host reports `WaitingForArcOnboarding` until `status` is `Connected` for `arcsql01`.
- **`PaygWizard` order:** wait for the Arc marker, then report **Manual action required** with the wizard steps in `health.json`, then poll over PowerShell Direct until `MSSQLSERVER` runs Standard edition. Configuration and seeding follow on their own.
- **Guest password:** generated on the host with a cryptographic random generator and stored with DPAPI (LocalMachine) in `protected\guest-administrator.bin`. It's written into `unattend.xml` only inside the mounted VHDX during the build, and the guest hardening step deletes the unattend files after first boot. `Copy-GuestCredential.ps1` copies it to the clipboard for the wizard step and never prints it.
- **Guest network:** static `192.168.200.10/24`, gateway and DNS `192.168.200.1`. The host's DNS Server listens only on `192.168.200.1` and forwards to `168.63.129.16` without root hints (ADR 0004).
- **License terms:** the unattended paths accept the Windows Server evaluation terms (the unattend file hides the license page) and the SQL Server terms (`/IACCEPTSQLSERVERLICENSETERMS`) on the operator's behalf. Deploying the demo means accepting them.

## Phase 13 notes: the workload runner steps (2026-10-20)

- **Real steps:** T1's and the host's `WorkloadRunner` steps install the runner and start its activity host ([ADR 0010](0010-workload-generator-technology.md#phase-13-delivery-and-hosting-as-built-2026-10-20)). When a deployment carries no runner (`workloadRunnerSha256` empty, as with the Deploy to Azure button), they report **Not selected**.
- **Order:** deploy, then send the runner's chunks (`Send-DemoWorkloadRunner`) and the bundle's chunks (`Send-DemoBootstrapBundle`). Deploy again with both SHA-256 values and chunk counts, then wait for the loader. The loader removes only its own bundle's chunks, so the runner's chunks stay in `downloads\<sha12>` until the step assembles them. If they arrive late, the step waits (`WaitingForInput`) and continues on a later run.
- **New wait state `WaitingForGuestSql`** (`vm/health/health.schema.json`): the host's step waits until the guest runs and its SQL Server is installed and running. In `PaygWizard` mode, that means it waits for the manual wizard step. The step runs last, after `SeedDatabase`. It doesn't change the Arc or wizard steps.
- **T3:** T1's step sets up T3 only after `Enable-DemoT3Workload` has recorded that T1 reaches T3 (ADR 0008's token-cache order).

## Phase 20 notes: the T2 source, `golden` or `build` (2026-10-22)

- **`t2Source`** (configuration, optional): `auto` (the default) restores a new `archost01` from the newest usable golden snapshot and builds it from the image otherwise; `golden` requires a snapshot (**Fail** without one); `build` always builds ([ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md)). Preflight reports the choice as `PREFLIGHT.T2.SOURCE`. An existing host keeps its disk.
- **Golden:** the template creates `archost01-osdisk` from the snapshot (`createOption` `Copy`) and attaches it to a VM without an `osProfile`, under the same names; the security type stays Standard, and the profile must keep the host without a data disk, because the guest's VHDX lives on the OS disk. The bootstrap state machine then runs a new generation on the restored host: every step is checked again, so a changed bundle or runner converges as on a fresh build.
- **The golden T2 track:** host password (RID 500), the release of the air gap with the local Arc reset and the guest password rotation (`vm/bootstrap/Invoke-DemoGoldenGuest.ps1 -Action Release`), the artifacts, the loader, then `configure-arc` with `-Force`.
- **Live (2026-10-22):** a copy in quarantine booted with its guest off, no automatic start, and the adapter disconnected; SQL Server ran Standard edition; the guest's SQL Server has a delayed automatic start that a cold-booted nested guest reached only after about ten minutes, so Release starts it at once.

## Phase 28 amendment: chunk hygiene that doesn't stall (2026-10-29)

**Why:** a colleague's first run on 2026-10-29 reported "T1: Blocked because seven Azure managed Run Commands remain stuck in `Deleting`; bootstrap and monitoring have not started", and took more than 2 hours. The Phase 6 hygiene above, which waited for each chunk's delete before the next (and, since Phase 20, up to 180 seconds per chunk delete in `Send-DemoChunkSet`), cost up to 24 minutes for 8 stuck deletes, and the loader then queued behind the same blocked extension work. The likely cause is the one R49 and R336 record: Azure Policy installs or updates extensions (`MDE.Windows`, Guest Configuration, Defender for SQL, the Azure Monitor agent) on a new VM, and until they finish, the VM agent doesn't process Run Command changes; deallocating and starting a VM once cleared a long block (R336, ADR 0020's 654-second Pending).

**What changed** (the managed Run Command limit of 25 per VM makes it safe to leave deletes to Azure; [managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)):

1. **Chunk deletes aren't waited for.** Each chunk's delete is sent and the next chunk goes on. One bounded cleanup at the end of the chunk set (and the leftover cleanup at the next run, before the first chunk) reports Run Commands that Azure is still deleting as a **Warning** (`DEPLOY.ARTIFACTS.CLEANUP_<VM>`); they don't block the loader. A VM that's no longer running skips the end cleanup.
2. **Extensions settle first.** Before a VM's artifacts, and before its loader, the track reads the VM's instance view ([az vm get-instance-view](https://learn.microsoft.com/cli/azure/vm#az-vm-get-instance-view)) and waits, at most 20 minutes, until no extension is creating, updating, or deleting (the Run Command handler itself, and Run Commands Azure is still deleting, don't count). The log and the status page name each one as an Azure-side wait: "Azure is finishing `<extension>` on `<VM>` (installed by a policy in your tenant); no action needed".
3. **A watchdog.** When that wait, a chunk set, or the loader stays non-terminal past about 15 to 20 minutes, it saves the VM's instance view (agent and extension statuses, redacted) to `out/diagnostics` for `collect-diagnostics.ps1`, restarts that VM once per run ([az vm restart](https://learn.microsoft.com/cli/azure/vm#az-vm-restart), within Contributor; never the T2 host while the guided stop's time limit is open, because its guest may be in the middle of setup; and, since the review fix of 2026-10-29, never while the golden Release runs on it or its guest build runs: its health reads `InProgress` or `RebootPending`, or can't be read once its bootstrap ran. While the Release runs, `archost01`'s artifacts go without the wait or the watchdog, and the Artifacts step sends what's left after it), and continues (`DEPLOY.WATCHDOG_<VM>` **Warning**, with the cause and the restart's time on the status page). Still stuck after the restart: the run ends **NOT DONE** with `DEPLOY.EXTENSIONS_<VM>` **Fail**, naming the extension and the next step (wait 15 to 30 minutes, then `./scripts/deploy.ps1` again).
4. **Sequential after a stall.** When no chunk finishes for 5 minutes while several run, the rest go one at a time (`DEPLOY.ARTIFACTS.STALL_<VM>` **Warning**), and the retry after the watchdog sends them with `Parallelism` 1.

What doesn't change: the chunk scripts, their names and SHA-256 checks, the 409 retries, the stale-result check, and the loader. Unit-tested (`tests/unit/DbHubDemo.Bundle.Tests.ps1`, `tests/unit/DbHubDemo.Tracks.Tests.ps1`, `tests/unit/DbHubDemo.OneCommand.Tests.ps1`): the non-blocking delete, the settle wait, the one restart, the sequential fallback, and the **NOT DONE** text. Not yet run live.

Sources (checked 2026-10-29): [az vm get-instance-view](https://learn.microsoft.com/cli/azure/vm#az-vm-get-instance-view), [az vm restart](https://learn.microsoft.com/cli/azure/vm#az-vm-restart), [managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed), [VM extensions and their states](https://learn.microsoft.com/azure/virtual-machines/extensions/overview).

## Validation

- **Phase 4 (static):** Pester tests for state transitions, resume after a simulated reboot, lock handling, and install-mode branching; PSScriptAnalyzer.
- **Phase 6 (static):** Pester tests for the step runner, state store, lock, reboot resume, and health file (validated against `vm/health/health.schema.json`); the chunk scripts (their data joins back into the bundle byte for byte, they're ASCII-only 5.1 scripts, and secrets are refused); `Send-DemoBootstrapBundle` with a mocked Azure CLI (the PUT, GET, and DELETE sequence, 409 retries, a non-zero exit code, leftover cleanup, and `-WhatIf`); the loader's assembly, its fail-closed hash checks, and a missing chunk; a Windows-only run of the chunk scripts and the loader's assembly and extraction in `powershell.exe` 5.1; media retries and resume with a mocked network call; storage without a data disk; the host plan's order and each install mode, including the `PaygWizard` sequence; and PSScriptAnalyzer with Windows PowerShell 5.1 syntax rules for `vm/`.
- **Phase 6 (live, pending go-ahead):**
  - Chunk delivery end to end, and the largest chunk size that works (48, 192, and 512 KiB).
  - A fresh deploy reaches the guest-ready state in each install mode.
  - A re-run converges without rebuilding.
  - The guest comes back after a host reboot with no lost state.
  - Media download and rebuild times.
  - A `TrustedLaunch` host is tested once, and the result is recorded here.
  - The `PaygWizard` order (Arc first, then the wizard) is confirmed.

## Sources (checked 2026-10-19)

- Nested virtualization: <https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/nested-virtualization>
- Size-series pages (Dsv5, Dasv5, Dsv6, Esv5, Esv6, Bsv2): <https://learn.microsoft.com/azure/virtual-machines/sizes/>
- Trusted Launch: <https://learn.microsoft.com/azure/virtual-machines/trusted-launch> (re-read 2026-10-19; see the Phase 6 notes) and the FAQ: <https://learn.microsoft.com/azure/virtual-machines/trusted-launch-faq>
- Managed Run Command: <https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed> (re-read 2026-10-20: parameters reach a Windows script as `-Name value` arguments; the instance view keeps the last 4 KB of output and error)
- Run Command overview, at most 25 managed Run Commands per VM (checked 2026-10-20): <https://learn.microsoft.com/azure/virtual-machines/run-command-overview>
- Run Command REST reference, `ExecutionState` values (checked 2026-10-20): <https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/get-by-virtual-machine>
- Azure Resource Manager limits, request size (checked 2026-10-20): <https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits>
- `ZipFile.ExtractToDirectory`: <https://learn.microsoft.com/dotnet/api/system.io.compression.zipfile.extracttodirectory>
- `HttpWebRequest.AddRange`: <https://learn.microsoft.com/dotnet/api/system.net.httpwebrequest.addrange>
- `SERVERPROPERTY` (`InstanceDefaultDataPath`, `InstanceDefaultLogPath`): <https://learn.microsoft.com/sql/t-sql/functions/serverproperty-transact-sql>
- SQL Server VM storage configuration: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/storage-configuration>
- SQL IaaS Agent extension least-privilege mode: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-server-iaas-agent-extension-automate-management>
- Connect to SQL Server when system administrators are locked out: <https://learn.microsoft.com/sql/database-engine/configure-windows/connect-to-sql-server-when-system-administrators-are-locked-out>
- Hyper-V NAT networking: <https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/setup-nat-network>
- `Add-VMNetworkAdapterAcl`: <https://learn.microsoft.com/powershell/module/hyper-v/add-vmnetworkadapteracl>
- Custom Script Extension: <https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-windows>
- Azure Automation State Configuration retirement: <https://learn.microsoft.com/azure/automation/automation-dsc-overview>
- Azure Machine Configuration: <https://learn.microsoft.com/azure/governance/machine-configuration/overview>
- Spot VMs: <https://learn.microsoft.com/azure/virtual-machines/spot-vms>
- SQL Server setup from the command prompt: <https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt>
