# ADR 0010: Workload generator technology and delivery

- **Status:** Accepted
- **Date:** 2026-10-19
- **Decision source:** Engineering (approved plan §4.7: ".NET LTS service or CLI … to be confirmed in an ADR"; §9.3 activity profiles; §9.5 release artifacts)
- **Related:** [ADR 0001](0001-iac-bicep-avm-compiled-arm.md), [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0011](0011-control-surface-priority.md), [ADR 0014](0014-notebook-role-and-capacity.md)

## Context

- **Workload:** "Contoso Care Operations", a synthetic, healthcare-flavored OLTP schema with a deterministic seed. No customer data, PHI, PII, or copyrighted datasets.
- **Where it runs:** on T1 (driving T1 and T3) and inside the T2 guest (driving T2). The SQL Servers aren't reachable from outside the virtual network.
- **What it runs (plan §9.3):**
  - **Activity profiles:** `baseline`, `business-day`, `incident:<scenario>`, and `off`.
  - **Scenarios:** healthy baseline, locking and blocking, CPU pressure, IO pressure, inefficient query, and missing index, plus Azure SQL-specific pressure on T3.
- **Required properties of every scenario:**
  - bounded duration, concurrency, and resources, with an automatic timeout and clean cancel;
  - a recorded run ID, start and stop, and expected symptoms;
  - no uncontrolled loops, disk fills, or corruption;
  - a return to a known healthy state.
- **Locking specifics:** at least two sessions, a watchdog rollback, and never touching sessions outside the demo database and scenario ID.
- **Delivery (revised 2026-10-20):** the artifact cache that held versioned, checksummed artifacts behind short-lived SAS URLs was dropped (ADR 0001, ADR 0016 C9). How the runner reaches the VMs without it is decided in Phase 6; see the Phase 6 decision below. The runner is built once per release tag (plan §9.5).
- **.NET lifecycle:** .NET 8 (LTS) support ends 2026-11-10. .NET 10 (LTS) is supported until 2028-11-14.

## Decision drivers

1. Reliable concurrency, cancellation, and timeouts.
2. Entra authentication to T3 with T1's managed identity, without secrets.
3. Testable without Azure: unit tests plus a local SQL Server container.
4. Reproducible, immutable builds delivered without the private repo.

## Considered options

1. **.NET 10 LTS runner using Microsoft.Data.SqlClient.**
2. A PowerShell module using the in-box `System.Data.SqlClient`. Rejected: weaker cancellation and concurrency control, and a deprecated client.
3. SQL Server Agent jobs only. Rejected: not available on Azure SQL Database, and sessions can't carry a per-run application name.
4. Python with an ODBC driver. Rejected: needs a driver and runtime on every VM.

## Decision

Option 1.

### Runner

- **Project:** `workload-generator/src/ContosoCare.Workload`, a .NET 10 LTS console application.
  - **CLI mode:** `run`, `stop`, `status`, `reset`, and `profile set|get`.
  - **Windows service mode:** hosts the active activity profile, using the Microsoft.Extensions.Hosting Windows-service integration.
- **SQL access:** Microsoft.Data.SqlClient.
  - T1 and T2 connect locally with Windows authentication.
  - T1 connects to T3 with `Authentication=Active Directory Managed Identity`.
- **Tagging:** every connection sets `Application Name=ContosoCare.Demo/<scenarioId>/<runId>`.
- **Publishing:** framework-dependent `win-x64`, run with `dotnet.exe` from a .NET runtime that the VMs download from Microsoft against a pinned SHA-512 (Phase 6 decision below; it replaces the self-contained single-file plan). A `linux-x64` build is used for the container.

### Scenario logic

- Scenario logic lives in bounded T-SQL stored procedures in the `demo` schema (`database/common`, plus per-target folders). It's portable across T1, T2, and T3, so every incident can run on any target. That matters because the Database Agent's target coverage is undocumented (ADR 0013).
- The runner orchestrates sessions, concurrency, timing, and recording. Scenario definitions (`scenarios/<id>/scenario.json`) declare default and maximum duration, concurrency, intensity, target applicability, expected Hub signals, and expected symptoms. They're validated against a JSON schema.

### Bounds, enforced in three layers

1. **T-SQL:** procedures stop at their end time or when `demo.scenario_control` sets a stop flag.
2. **Runner:** a hard maximum duration (clamped to the scenario's maximum and to the next auto-shutdown), command timeouts, and cancellation tokens.
3. **Watchdog:** a separate loop kills only sessions whose application name starts with `ContosoCare.Demo/`, in the `ContosoCare` database, after the run's deadline plus a grace period. It marks the run `TimedOut`.

Every run is recorded in `demo.scenario_runs`. Reset verifies that no demo transaction is still open. IO scenarios check free space first, including the guest VHDX, and cap file growth.

### Activity profiles

- The service reads the desired profile from `demo.activity_profile` in the local database, or from `C:\ProgramData\DbHubDemo\activity.json` for T3 work driven from T1.
- `start-demo.ps1`, `demo-control.yml`, and the live-activity notebook (through `workflow_dispatch`) change it with Run Command.
- Profiles stop at their maximum duration or when the VM shuts down.

### Build and delivery

- A release workflow builds the runner on each version tag, publishes SHA-256 checksums, and attaches both to the GitHub release.
- `deploy.ps1` delivers the version pinned in `config/versions.json` to the VMs in Run Command chunks (Phase 6 decision below). It takes the version from the release, which needs `gh auth login` while the repo is private (risk R30), or builds it locally when the .NET 10 SDK is available.
- VMs check the runner's SHA-256 before they install it. On T2, the host copies it into the guest over PowerShell Direct.

### Tests

- xUnit unit tests: profile scheduling, bounds clamping, application-name tagging, watchdog session filter, and redaction.
- Integration tests against a SQL Server 2022 container through `workload-generator/Dockerfile` and a compose file.
- CI runs both on every pull request.

## Consequences

- **Positive:** strong cancellation and timeout control; secretless Entra access to T3; the same scenario logic on every target; reproducible binaries.
- **Negative:** a build pipeline and a release step are needed. A private-repo deploy needs `gh auth` or a local .NET SDK. Sending a few megabytes in Run Command chunks is slow until the largest working chunk size is known (Phase 6 decision below), and the runtime zip isn't serviced by Microsoft Update, so runtime security fixes arrive only by updating the pin.

## Phase 6 decision: runner delivery (2026-10-20)

- **Decision source:** the owner's direction (2026-10-20, approved), recorded by the implementer. It follows from dropping the artifact cache.
- **Runner:** a framework-dependent `dotnet publish` of `ContosoCare.Workload` for `win-x64`, built once per release tag in CI with SHA-256 checksums (Phase 11), and zipped.
- **Delivery to the VMs:** the same path as the bootstrap bundle (ADR 0003): `New-DemoBootstrapChunk` turns the zip into SHA-256-checked chunk scripts, and `Send-DemoBootstrapBundle` sends them one Run Command at a time and deletes each. The state machine's `WorkloadRunner` step assembles and verifies the zip as the loader does, and the T2 host copies it into the guest over PowerShell Direct (Phase 11).
- **.NET runtime:** the runtime zip, not the installer, downloaded on each VM from the official Microsoft URL pinned in `config/versions.json` (`dotnetRuntime`) and verified against the SHA-512 that Microsoft publishes in the release metadata, then extracted to `C:\ProgramData\DbHubDemo\dotnet` (SYSTEM and Administrators only). The runner runs as `C:\ProgramData\DbHubDemo\dotnet\dotnet.exe ContosoCare.Workload.dll`. The zip avoids a machine-wide install and a possible restart, and goes away with the folder. It uses the media download's retries and resume (Phase 11 adds SHA-512 to that check).
  - **Pin (2026-10-20):** .NET runtime 10.0.13, the runtime of SDK 10.0.402 (`tools.dotnetSdk`): `dotnet-runtime-10.0.13-win-x64.zip`, 36,970,749 bytes, from `builds.dotnet.microsoft.com`. Its SHA-512 is from `release-metadata/10.0/releases.json` and was confirmed by downloading the zip. A Pester test checks that the pin's `sdkVersion` matches `tools.dotnetSdk`.
- **Throughput risk (measured size, estimated time):** with an offline restore of a scratch console app (not the runner itself), a framework-dependent publish with Microsoft.Data.SqlClient 6.1.1 (which brings Azure.Identity and MSAL) and System.CommandLine was 5.3 MB zipped as a portable publish (67 files), or 3.1 MB with English resources only and only the Windows x64 native files (38 files).

  | Runner zip | 48 KiB chunks | 192 KiB | 512 KiB |
  |---|---|---|---|
  | 3.1 MB (trimmed) | 64 | 16 | 6 |
  | 5.3 MB (portable) | 109 | 28 | 11 |

  At the live per-chunk time of about 60–80 seconds whatever the size (measured 2026-10-20 for 48, 192, and 512 KiB), 64 chunks would take over an hour per VM, while 6–11 chunks at 512 KiB take about 6–15 minutes. Both VMs can receive chunks at the same time. So Phase 11 publishes `win-x64` with `SatelliteResourceLanguages=en`, and the chunk default is 512 KiB.
- **Alternative once the repo is public:** the VMs download the release asset from GitHub (`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`) and check it against a SHA-256 pinned in `config/versions.json`, like the media. That's one HTTPS download instead of dozens of Run Commands, and the NSGs already allow outbound 443. It needs no token only while the repo is public, so chunks stay the default.
- **Not chosen:** a self-contained single file (tens of megabytes, dozens of chunks even at 512 KiB); the runtime installer (a machine-wide install that can ask for a restart); and any storage account (tenant policy and Defender for Storage, ADR 0016 C9).

## Validation

- **Phase 4 (static, CI):** the build compiles; tests pass on Linux and Windows.
- **Phase 11 (live, pending go-ahead):**
  - Every scenario and profile starts, stops, and resets within bounds on each applicable target.
  - The watchdog never touches a session it doesn't own.
  - Signals appear in telemetry.
  - The runner arrives in chunks and the runtime from its pinned URL, both verified, and the delivery time is recorded here.

## Sources (checked 2026-10-19)

- .NET releases and support: <https://learn.microsoft.com/dotnet/core/releases-and-support>
- Microsoft.Data.SqlClient Entra authentication: <https://learn.microsoft.com/sql/connect/ado-net/sql/azure-active-directory-authentication>
- .NET Windows services: <https://learn.microsoft.com/dotnet/core/extensions/windows-service>
- Single-file deployment: <https://learn.microsoft.com/dotnet/core/deploying/single-file/overview>
- .NET application publishing, framework-dependent and self-contained: <https://learn.microsoft.com/dotnet/core/deploying/>
- Install .NET on Windows (installers are serviced by Microsoft Update): <https://learn.microsoft.com/dotnet/core/install/windows>
- .NET 10 release metadata, runtime files and SHA-512 hashes (checked 2026-10-20): <https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json>
- SQL Server Linux containers: <https://learn.microsoft.com/sql/linux/quickstart-install-connect-docker>
- Serverless auto-pause (open sessions block it): <https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume>

## Implementation notes (Phase 11, 2026-10-20)

What Phase 11 built, and where it differs from the decision above. The delivery section is Phase 6's and isn't changed here.

- **Built:** the runner in `workload-generator/src` ([README](../../workload-generator/README.md)); the demo objects in `database/common/110-demo-control.sql` and `120-scenario-procedures.sql`; eight scenario definitions plus `scenario.schema.json` and `activity-profiles.json` (with its schema) in [`scenarios/`](../../scenarios/README.md); xUnit v3 tests, including opt-in SQL Server integration tests.
- **Commands:** `run` (one bounded scenario, in the foreground), `stop`, `status`, `reset`, `profile get|set|run`, plus `scenarios`, `warmup` (serverless resume), and `setup` (applies the embedded demo scripts as an administrator, and can grant a service identity's login).
- **Publishing is framework-dependent, not self-contained single-file.** Phase 6 delivers the .NET runtime from Microsoft with a pinned hash, so the runner itself stays small enough to travel in Run Command chunks: `dotnet publish -r win-x64 --self-contained false`, English resources only, and without the Windows broker's native runtime (the runner uses only managed identity).
- **No Windows service integration.** `profile run` is a long-running, service-style console process that stops cleanly on Ctrl+C or SIGTERM and at `--not-after`. Leaving out Microsoft.Extensions.Hosting and its Windows-service package keeps the runner smaller and simpler. It can be hosted by a startup scheduled task, like the bootstraps, or by any service wrapper; the delivery phases choose.
- **Scenario catalog:** `scenarios/<id>/scenario.json` and `scenarios/activity-profiles.json` are embedded in the runner at build time, and `demo.fn_scenario_catalog()` holds the same maximum durations for the T-SQL layer; a test fails when they disagree.
- **Two more scenarios** for the T3 flavours of plan §9.3: `resource-governance` (CPU at the service objective's cap with sound plans) and `log-rate-pressure` (log-rate governance). Both run on every target.
- **Watchdog permissions:** the runner cancels and closes its own sessions without any special permission. The server-side backstop (`demo.usp_kill_demo_sessions`) and reset's open-transaction check need `ALTER ANY CONNECTION` and `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022, or `KILL DATABASE CONNECTION` and `VIEW DATABASE STATE` on Azure SQL Database, so a least-privileged service identity reports **Manual action required** there and an administrator runs reset. The `contosocare_runner` role stays database-only.
- **Session tagging:** scenario sessions use `ContosoCare.Demo/<scenarioId>/<runId>`; the runner's bookkeeping sessions use `ContosoCare.Demo/control/<id>`, which the kill and reset paths never touch. Connections aren't pooled, so closing one always ends its session and rolls back anything open.
- **Tests:** the integration tests run against any SQL Server reached with Windows authentication, opted in through `CONTOSOCARE_TEST_SQL_SERVER` (LocalDB locally); the container path (`Dockerfile` built from the repository root, `compose.yaml` with SQL Server 2022) is documented but wasn't built here, because the build machine has no Docker.
- **Globalization:** Microsoft.Data.SqlClient refuses to open connections in invariant globalization mode, so `InvariantGlobalization` is now `false`.

Sources for these notes (checked 2026-10-20):

- `KILL` permissions: <https://learn.microsoft.com/sql/t-sql/language-elements/kill-transact-sql>
- `sys.dm_exec_sessions` permissions: <https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-sessions-transact-sql>
- Connection pooling: <https://learn.microsoft.com/sql/connect/ado-net/sql-server-connection-pooling>
- Framework-dependent deployment: <https://learn.microsoft.com/dotnet/core/deploying/>
- Globalization settings: <https://learn.microsoft.com/dotnet/core/runtime-config/globalization>

## Phase 13: delivery and hosting as built (2026-10-20)

How the runner reaches the VMs and runs there. It follows the Phase 6 delivery decision; the differences are listed at the end.

- **Build:** `Publish-DemoWorkloadRunner` runs `dotnet publish` of `workload-generator/src/ContosoCare.Workload` with Phase 11's settings: Release, `win-x64`, framework-dependent, and locked-mode restore. It leaves out the `.pdb` files and zips the output deterministically: entries are sorted, timestamps are fixed, and `runner-manifest.json` lists every file's SHA-256.
  - The zip is named after a hash of the runner's inputs: `contosocare-workload-<version>-win-x64-<inputs12>.zip`. That keeps a rerun on the same SHA-256, so `deploy.ps1 -Resume` reuses the zip instead of building and sending it again.
  - Measured locally: 44 files, 3,229,169 bytes, so 7 chunks at 512 KiB. Two builds on the same machine produced the same SHA-256.
  - **Phase 20 (live, 2026-10-22):** two checkouts of the same source still built two runners, because the assembly recorded the commit (its informational version), the checkout's path (the regular-expression generator's file-local type names), and the program database's checksum (whose Source Link data holds both). `workload-generator/Directory.Build.props` now leaves the commit out and maps the checkout's path to `/_/` (`PathMap`), and the publish builds no program database (`-p:DebugType=none`, part of the input hash). Two checkouts at different paths built the same runner, byte for byte. Sources: [PathMap](https://learn.microsoft.com/dotnet/csharp/language-reference/compiler-options/advanced#pathmap) and [DebugType](https://learn.microsoft.com/dotnet/csharp/language-reference/compiler-options/code-generation#debugtype).
- **Delivery:** `Send-DemoWorkloadRunner` sends the zip through the bootstrap chunk path (`New-DemoBootstrapChunk`, `Send-DemoBootstrapBundle`) to `C:\ProgramData\DbHubDemo\downloads\<sha12>` on each VM. The loader cleans up only its own bundle's chunks, so the runner's chunks wait there for the `WorkloadRunner` step.
- **Settings:** `Get-DemoDeploymentParameter -WorkloadRunnerSha256 -WorkloadRunnerChunkCount` passes the runner to the template. Both bootstraps receive `settings.workload` with these fields: `runnerSha256`, `runnerChunkCount`, `activityProfile`, `autoShutdownTime`, and `autoShutdownTimeZone`. T1 also receives `t3` (server name, FQDN, and database) from the T3 module's outputs. A new runner changes the settings, which re-runs the loader. Without a runner, the steps report **Not selected**.
- **T1 `WorkloadRunner` step** (`Invoke-SqlVmBootstrap.ps1`, up to 3 attempts):
  1. It assembles and verifies the chunks like the loader does, and extracts them to `runner\<sha12>`. While chunks are missing, the step waits; it doesn't fail.
  2. It downloads the pinned .NET runtime zip with retries that resume, checks its SHA-512, and extracts it to `dotnet`.
  3. It runs the runner's `setup` on T1 with Windows authentication. SYSTEM is a sysadmin there (step `SqlAdminAccess`).
  4. It writes `workload-install.json` and copies `Start-DemoWorkload.ps1` next to the runner.
  5. It registers the SYSTEM task `DbHubDemo-Workload` (at startup, delayed two minutes), starts it, and removes older runners.
- **T3 from T1:** nothing on T1 asks for an Azure SQL token before T1 is in the P6 group, because managed identity tokens are cached for up to about 24 hours (ADR 0008, Phase 8). So after `Add-DemoT1ToT3AdminGroup` and `Invoke-DemoT3SqlFromT1 -Name Setup`, the orchestrator runs `Enable-DemoT3Workload`. It records `t3-workload.json`, runs `setup --target T3` with the managed identity, and restarts the task with T3 added. While that marker exists and T3's name resolves, later runner versions apply T3's demo objects themselves.
- **T2 host `WorkloadRunner` step** (`vm/hyperv-guest/GuestWorkload.ps1`):
  - It reports `WaitingForGuestSql` (Waiting, not Failed) until the guest is running and its SQL Server is installed and running. In `PaygWizard` mode, that's after the manual wizard step.
  - The host assembles the runner and downloads the runtime. Over PowerShell Direct (`Copy-Item -ToSession`), it copies both into the guest with the wrapper and the VM module, then runs setup for T2 with Windows authentication. In `PaygWizard` mode, the wizard makes only the guest administrator a sysadmin, so setup also maps `NT AUTHORITY\SYSTEM` (`--grant-windows-login`).
  - Inside the guest, it registers the same `DbHubDemo-Workload` task for T2.
- **Hosting:** the task runs `Start-DemoWorkload.ps1`, a self-contained Windows PowerShell 5.1 wrapper, under SYSTEM:
  - It computes the next auto-shutdown from the DevTest Labs schedule. It exits if that's less than 10 minutes away.
  - Once per boot, it sets each target's profile to `activityProfile` (`baseline` by default), ending at that shutdown. (Milestone B: at a boot only when `activityProfileOnBoot` is true; see the note at the end.)
  - Then it runs `dotnet.exe ContosoCare.Workload.dll profile run --target ... --not-after <shutdown>`.
  - A profile changed later in the same boot (`demo-control.yml`, `start-demo.ps1`) survives a restart of the task.
- **Control:** `Invoke-DemoWorkloadCommand -Target T1|T2|T3` runs any runner command through an action Run Command on `sqlvm01` (T1 and T3) or through `archost01` and PowerShell Direct (T2). It reads back one result line. `deploy.ps1`, `start-demo.ps1`, `stop-demo.ps1`, and `demo-control.yml` use it.
- **Health:** `health.json` reports the runner's SHA-256, the .NET version, the profile, setup results, whether T3 is enabled, and the task's state. On T1 that's `details.workload`; on the host, it's `details.guest.workload`.
- **Live (2026-10-20, T1 and T3):**
  - The runner's 7 chunks reached `sqlvm01` in 317 seconds, about 45 seconds each.
  - The step downloaded the runtime in under a second and checked its SHA-512.
  - Moving the extracted runtime out of its staging folder failed twice: "Access to the path ... is denied". Microsoft Defender real-time protection was scanning the 193 new files. The third attempt passed.
  - Since then, `Expand-DemoVmVerifiedZip` extracts in place, with retries while a file is held. The marker is removed first and written last, and no folder is renamed.
  - `Enable-DemoT3Workload` passed, and the `baseline` profile then ran on T1 and T3 until two minutes before the auto-shutdown.
- **Differences from the decision:** the zip is built where `deploy.ps1` runs (or in the GitHub workflow), not taken from a release. That needs the .NET SDK pinned in `config/versions.json`. The evaluation-only T2 mode (Phase 7) doesn't install a runner yet.

Sources for these notes (checked 2026-10-20):

- `dotnet publish`: <https://learn.microsoft.com/dotnet/core/tools/dotnet-publish>
- Managed identity token caching: <https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations>
- PowerShell Direct: <https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct>
- `Register-ScheduledTask`: <https://learn.microsoft.com/powershell/module/scheduledtasks/register-scheduledtask>
- Auto-shutdown for VMs: <https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm>

## Phase 13 Milestone B: profiles at boot, and the lifecycle (2026-10-21)

- **Boot behavior follows the configuration** (coordinator-directed after a live finding: the task restarted `baseline` on T1 and T3 at every start of `sqlvm01`, which kept T3 awake; R183). The wrapper still applies the configured profile once after each install, but at a boot only when `activityProfileOnBoot` is true (default `false`). The setting travels as `settings.workload.profileOnBoot`, and `workload-install.json` records it; a record without it means `false`.
- **Who sets the profile:** `deploy.ps1` (its Activity stage for T1 and T3, and its T2 stage for T2), `start-demo.ps1` (the configured profile, or `-ActivityProfile`), `demo-control.yml`, and the live-activity notebook. `stop-demo.ps1` and `schedule-stop.yml` set every profile to `off` before the VMs stop; for T3 that writes the profile file on T1, so it never wakes T3. `status.ps1` reads the active profile with `profile get --json` from T1.
- **Reset:** `reset-demo.ps1` runs the runner's `reset` on each target (`-Reseed`, `-UndoRemediation`, `-KeepProfile`). Rebuilding the T2 guest isn't supported yet: the host's state machine skips guest steps that succeeded, and resetting them safely is a follow-up.
- **Paths for another machine:** the T2 host computes the guest's paths (`C:\ProgramData\DbHubDemo\...`) as strings with `Join-DemoVmPath`, because `Join-Path` resolves the drive on the machine that runs it. That failed the Linux CI run and would fail on any host without the guest's drive letter.
- **Run Command limits:** an action Run Command that's busy (a policy updating `MDE.Windows` blocked them for about 10 minutes live, R49) is retried for about 12.5 minutes; on a deallocated VM it fails at once with a message to start the VM.

## Phase 25b: the profile host's lanes and supervisor, and the bounds Phase 25a met (2026-10-26)

- **Decision source:** Phase 25a's findings from the long incident program of 2026-10-23 (coordinator, 2026-10-23 and 2026-10-26), implemented by Phase 25b.
- **What happened (finding F4):** the profile host on `sqlvm01` (`profile run --target T1 --t3-server ...`, one process) stopped serving T1 after `20:06:08Z`, during deep blocking (16 contenders on one hot row) that overlapped CPU pressure (16 sessions). The two runs it had just started ran to their deadline and logged their end at `20:25:10Z`, but the T1 loop never recorded them and never read a later profile change. T3's loop in the same process kept working until the reset at `21:26:42Z`. Nothing was logged at all: no error, no warning, no Windows event. At `21:42Z` T1 had no `ContosoCare.Demo/control/` session, which reset and the watchdog never end, so the loop wasn't waiting inside a SQL call. Restarting the task cured it.
- **Cause, as far as the evidence goes:** each target ran one loop under `Task.WhenAll`. Its profile read caught only `SqlException`, `IOException`, `JsonException`, `InvalidOperationException`, and `ScenarioRequestException`, so any other exception from the read or from the rest of the poll (for example an `OperationCanceledException` that the client raised without the host's token, a `TimeoutException`, or a `SqlNullValueException`) ended that loop. `Task.WhenAll` observes the fault only when every loop has ended, that is, at shutdown, so the lane died without a trace while the process lived on. Several of its awaits also had no bound of their own: the reset before a profile, and cancelling a run, whose callbacks run SqlClient's cancellation on the loop's thread. The full host log of 2026-10-23, collected on 2026-10-26 before the runner was reinstalled, confirms it: from `20:00Z` to `21:50Z` it has only informational lines, none from T1's lane after `20:06:08Z`, and no exception anywhere; the Task Scheduler's operational log is disabled on the VM, so there's no task history either. The exception that ended the lane was never observed, so it can't be named; the changes below remove the whole class of failure.
- **Lanes and a supervisor** (`ProfileHost`):
  - Each target has a lane. Its state (the runs it started, the activities it started, the last profile it read, refusal retries) belongs to the lane, not to one generation of its loop, so a replaced loop's successor carries on with the same runs and never starts an activity twice.
  - A lane outlives any failure of one poll: it logs the failure (the first and every 30th in a row) and polls again. A failed profile read changes nothing that runs.
  - Every await is bounded: the profile read at 150 seconds (T1's and T2's connect retry window, one more connect timeout, and the 60-second command timeout, with margin), the reset before a profile at 780 seconds (a connect and `demo.usp_reset`'s 690-second command timeout). The bound's token asks the call to stop, and the wait itself ends 5 seconds later even if the call ignores it ([`Task.WaitAsync`](https://learn.microsoft.com/dotnet/api/system.threading.tasks.task.waitasync)).
  - Runs start on the thread pool, and stopping one cancels its token in the background, so no part of a run, its connection, or a blocking cancellation callback runs on the lane's poll. A run's token follows the host's, not the lane's: replacing a lane doesn't stop its runs.
  - The supervisor checks every lane every poll interval (10 seconds). A lane whose loop ended, or that hasn't finished a poll for 5 minutes outside a bounded reset, is retired (it can't touch the lane's state again) and restarted after a backoff of 10 seconds, doubling with each restart in the same hour, up to 5 minutes.
  - Logging can't end a lane or a run: a write to standard error or the log file that fails (a closed pipe, a full disk) loses the line.
- **The heartbeat:** the supervisor rewrites `C:\ProgramData\DbHubDemo\host-lanes.json` (next to T3's profile file; in the T2 guest, the guest's) every poll interval and once more when the host stops: the process, its heartbeat, and per lane its state (`Serving`, `Busy` during a bounded reset, `Restarting`, `Stopped`), generation, restarts in the last hour and their last reason, its last finished poll and what it's doing now, consecutive failures and the last error (redacted), the profile, and its running runs. The runner's `status` derives an ADR 0012 status from it for its target, with the process's liveness and the machine's boot time: a `host` node, written last in `status --json` and `profile get --json` so a Run Command's output tail keeps it, and a `Host:` line in the text. Validation reports it as `WORKLOAD.<target>.HOST`, and `status.ps1`'s `STATUS.PROFILE_<target>` takes on its Warning or Fail ([ADR 0012](0012-validation-model.md#phase-25b-the-profile-host-lane-2026-10-26)).
- **Runs an earlier host left Running (from the full host log):** the log's only errors are seven 50108 refusals of `healthy-baseline`, and five of them came within minutes of a task restart (`18:14Z` to `18:17Z`, and `19:31Z` to `19:34Z`, when Phase 22's deployment restarted the task). A killed host can't record its runs' end, so they stayed Running, without sessions, until `demo.usp_recover_stale_runs` closed them 2 minutes after their deadline (up to half an hour for a baseline chunk), and every start of the same scenario was refused meanwhile. Now, before a lane's first start and again after each 50108 refusal, the host ends this machine's runs that a profile requested, that started before the host did, and that have no live session (`Cancelled`, with "Recovered: the profile host that started it stopped ..."); it never touches a foreground `run`, another machine's run, or a run with a session, and does nothing when it can't see other sessions. On T3 it runs only when T3's profile wants a run, so it never wakes a paused database.
- **Starts that wait, and refusals that are tried again (finding F1):** `demo.usp_run_begin` allows one Running run per scenario in a database (error 50108) and four in all (50109), and a run that's ending stays Running until it's recorded. After a profile was set again, the host cancelled the old baseline and started the new one in the same poll, so the new one was refused and never tried again; `incident:<scenario>` set during a baseline lost the baseline beside it the same way, and a baseline chunk could race the previous chunk's end. Now:
  - an activity whose scenario still has a run in the lane (ending or not) waits until that run has ended (`profile.start-deferred`);
  - an activity refused with 50108, 50109, or a failed connection is started again 30 seconds later, at most 40 times and only while its window still allows a run of `minimumRunSeconds` (`profile.start-retry`, then `profile.start-gave-up`). Any other refusal isn't retried. The run's result carries the refusal's reason and SQL error number.
- **A run's outcome counts every session (Phase 25a):** runs that the host cancelled, or that reached their deadline, recorded "No sessions ran." when their sessions took longer than the runner waits to end (about a minute after the cancellation or the deadline) or when the orchestration failed, because the outcome came only from a completed orchestration. A run now tracks each session as it opens; its outcome counts the sessions still ending (`worker x16 (16 still ending)`), names a session that failed unexpectedly, and starts with "Stopped by its caller" when the profile host or Ctrl+C stopped it. "No sessions ran." stays for runs that opened none.
- **Bound kept: locking-blocking's 20-second lock timeout (finding 4).** Each contender waits at most 20 seconds for the hot rows ([`SET LOCK_TIMEOUT`](https://learn.microsoft.com/sql/t-sql/statements/set-lock-timeout-transact-sql); 5 seconds, then 1, near the deadline, so no wait outlives its run), then tries again at once. The blocked-process count therefore stays at the run's concurrency for the whole hold, and only the longest single wait is capped: Phase 25a measured 16 blocked sessions behind one head blocker, chain depth 2, and a longest wait of 20.1 seconds. It isn't raised: a longer timeout adds no wait category and no blocked session, and a contender in a lock wait notices a stop request only when its wait ends, so waits longer than the runner's 30-second graceful stop window (15 seconds when the profile host stops a run) would turn stops into cancelled commands. Longer single waits and deeper chains come from `blocking-chain`, whose links wait up to 60 seconds, stepping down near the deadline, and are cancelled by the runner when a stop arrives first; that's its design.
- **Also bounded, from Phase 25a:** one Running run per scenario and four per database (above), and T3's service objective, `GP_S_Gen5_1`, which allows 75 concurrent workers and 75 concurrent logins ([resource limits](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases)); the catalog has no T3-specific concurrency cap, so overlapping runs on T3 are kept to about 60 sessions in all ([limitations](../limitations.md#deployment-and-operations)).
- **Tests:** `ProfileHostTests` (runs an earlier host left Running are recovered before the first start and after a 50108; a lane survives a profile read that fails with `SqlNullValueException`, `TimeoutException`, `NullReferenceException`, or `TaskCanceledException`; a read that never returns is bounded; a stalled lane is replaced, keeps its run, and starts nothing twice; a run that's still ending defers the next run of its scenario; refusals that pass are retried and others aren't; the heartbeat and the stop; `--not-after`), `HostLaneStatusTests` (every status rule, the file's round trip, process liveness), `RunnerTests` (the session tracker and the outcome text), Pester tests for `WORKLOAD.<target>.HOST` and `STATUS.PROFILE_<target>`, and an opt-in SQL Server integration test (`SqlIntegrationTests`) that recovers only a profile run of this machine without sessions.

### The eight new scenarios and their bounds

The brief asked for more wait categories and for capacity at its ceiling. Each new scenario keeps the three layers of bounds above (the T-SQL end time and stop flag, the runner's maximum and command timeouts, and the watchdog), works only in `ContosoCare` except as noted, tags every session `ContosoCare.Demo/<scenario>/<run>`, and is covered by `reset`. They run for 10 minutes by default and 30 at most, except `capacity-max`.

| Scenario | What it does | Bounds and their safety reasons |
|---|---|---|
| `blocking-chain` | A head blocker (an idle open transaction) with 1 to 4 branches of links 3 to 6 sessions deep, each link holding its own row and waiting for its parent's; an optional escalator updates 7,000 to 20,000 appointments with row locks so SQL Server escalates to a table lock | 26 sessions at most (a head blocker, 4 branches of 5 links, the escalator, and 4 normal workers). Each link's lock wait lasts at most 60 seconds, then 20, 5, and 1 near the deadline, so no wait outlives the run, and every change rolls back; the head blocker holds for `holdSeconds` (never past the deadline), always rolls back, and pauses `pauseSeconds`. The escalator's minimum is 7,000 rows: Learn documents escalation from 5,000 locks on one table, and SQL Server 2025 (LocalDB) escalated from about 6,200 rows. Its table lock lasts `escalationHoldSeconds` (15 by default) every `escalationEverySeconds` (120). Under optimized locking (T3) it doesn't escalate |
| `deadlock-storm` | Pairs of sessions that deadlock with each other, round after round | At most `maxRounds` rounds per session, so at most `concurrency` times `maxRounds` deadlocks per run, with a pause between rounds (about 10 seconds at intensity 1, 1 at 10). Side 2 runs at `DEADLOCK_PRIORITY LOW`, so it's the victim; every round rolls back, so its inventory rows (101 to 116) stay as seeded; 500 victim events at most per run |
| `tempdb-contention` | Sessions create, fill, read, and drop a temporary table in a loop, so tempdb's allocation pages see `PAGELATCH` waits | The one exception to working only in `ContosoCare`: its temporary tables live in tempdb, belong to its own sessions, are dropped every iteration, and disappear when a session ends, so nothing is left behind; `rowsPerTable` rows of 400 bytes each. An index added after `CREATE TABLE` keeps SQL Server from caching the table, so every iteration allocates |
| `memory-grant-pressure` | Concurrent large sorts that ask for a large memory grant with the documented `MIN_GRANT_PERCENT` query hint, so later sessions wait (`RESOURCE_SEMAPHORE`) | No server setting changes, nothing is written, and SQL Server never grants more memory than it has |
| `parallel-scans` | A reporting aggregate at `OPTION (MAXDOP n)`, parallel by cost | Read-only. No hint forces parallelism: the report's cost is well above the default cost threshold for parallelism, so the optimizer picks a parallel plan by cost, at most at the `MAXDOP` hint (2 to 8, never more than the schedulers): DOP 2 on the 2-vCPU VMs, serial on T3 (1 vCore or less) and on SQL Server Express |
| `log-flush-waits` | Singleton inserts, each committed on its own (`WRITELOG`) | At most `maxRows` commits per session (about 0.5 KB of log each); each session deletes its rows every 1,000 inserts and when it ends; the free-space check runs first; T1 and T2 use simple recovery, so the log truncates at checkpoints |
| `slow-consumer` | A wide query whose result the runner reads slowly on purpose (`ASYNC_NETWORK_IO`) | Read-only; the runner cancels the query at the deadline or on a stop request |
| `capacity-max` | CPU sessions on every scheduler and IO sessions over `demo.io_scratch` at once | 20 minutes at most, against 30 for the others: it holds CPU and storage at their caps together, and Phase 25a measured Run Command waits of more than 10 minutes on a saturated `sqlvm01`. The scratch set never grows past `scratchMb` or the file caps, after the free-space check; business data is only read |

A sort and hash spill scenario (the `MAX_GRANT_PERCENT` hint, Other Disk IO) was considered and left for later (coordinator, 2026-10-26): the eight above already add three wait categories that Phase 25a's program didn't show (Memory, Parallelism, and Network IO), and live proof of them comes first.

Sources for this amendment (checked 2026-10-26):

- `Task.WaitAsync`: <https://learn.microsoft.com/dotnet/api/system.threading.tasks.task.waitasync>
- `SET LOCK_TIMEOUT`: <https://learn.microsoft.com/sql/t-sql/statements/set-lock-timeout-transact-sql>
- Single database vCore resource limits, `GP_S_Gen5_1`: <https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases>
- `Start-ScheduledTask`: <https://learn.microsoft.com/powershell/module/scheduledtasks/start-scheduledtask>
- Lock escalation thresholds (5,000 locks): <https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide>
- Optimized locking (no lock escalation): <https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking>
- `SET DEADLOCK_PRIORITY`: <https://learn.microsoft.com/sql/t-sql/statements/set-deadlock-priority-transact-sql>
- tempdb's temporary-table caching: <https://learn.microsoft.com/sql/relational-databases/databases/tempdb-database>
- Query hints (`MIN_GRANT_PERCENT`, `MAX_GRANT_PERCENT`, `MAXDOP`): <https://learn.microsoft.com/sql/t-sql/queries/hints-transact-sql-query>
- Cost threshold for parallelism: <https://learn.microsoft.com/sql/database-engine/configure-windows/configure-the-cost-threshold-for-parallelism-server-configuration-option>

## Phase 25d: the eight scenarios live, with the bounds unchanged (2026-10-27)

Each new scenario ran for 8 minutes on T1, T2, and T3 at once, with its default concurrency and intensity, and every run stayed within its bounds: no run outlived its deadline, every reset passed, and no demo session or open demo transaction was left. The telemetry showed each scenario's wait family ([implementation report](../implementation-report.md#phase-25d-phases-25b-and-25c-live)). The bounds stay as they are. What limited intensity:

- **T3 at 1 vCore:** `parallel-scans` ran serially there, with CPU waits and no parallelism waits, as the table above says; CPU reached 100 % under `tempdb-contention`, `memory-grant-pressure`, `parallel-scans`, and `capacity-max`.
- **`capacity-max` on T2:** 2 of its 12 sessions couldn't open their connections within the 30-second timeout, because the client library opens only as many connections at once as the machine has processors, so the run ended **Failed** while it held CPU at 98 %. The runner now retries such an open within its connect window. Its 4 GB scratch set also stayed in the guest's memory, so it showed no buffer IO waits there.
- **`capacity-max` on T1** saturates `sqlvm01`, where the runner also serves T3 and T4: a profile read took longer than its 150-second bound, and the lane carried on, and T4's baseline couldn't connect until the scenario ended. The runner now retries T4's refused starts as it does T1's to T3's.
