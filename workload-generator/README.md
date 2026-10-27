# Workload generator

`ContosoCare.Workload` is the .NET 10 LTS runner that drives the demo's bounded scenarios and activity profiles on T1, T2, and T3 ([ADR 0010](../docs/adr/0010-workload-generator-technology.md)). The scenario logic lives in T-SQL procedures in the `demo` schema ([database/common](../database/common/README.md)); the runner orchestrates sessions, timing, bounds, and records, and it reads its scenario catalog from [`scenarios/`](../scenarios/README.md), embedded at build time.

## What it guarantees

- **Only the `ContosoCare` database.** Every connection string has `Initial Catalog=ContosoCare`, and there's no option to change it.
- **Tagged sessions.** Every scenario session carries `Application Name=ContosoCare.Demo/<scenarioId>/<runId>`; bookkeeping sessions carry `ContosoCare.Demo/control/<id>`. The watchdog and reset touch only scenario sessions of this database, and the runner's watchdog only those of its own run.
- **Bounded runs, in three layers:**
  1. **T-SQL:** `demo.usp_run_begin` registers every run in `demo.scenario_runs` with a deadline clamped to the scenario's maximum (`demo.fn_scenario_catalog()`), any lower limit in `demo.scenario_control`, and a global 4-hour cap. Every procedure loops only while `SYSUTCDATETIME() < @deadline` and checks `demo.fn_run_should_stop` about once a second. At most one Running run per scenario and four per database.
  2. **Runner:** the duration is clamped again to the scenario maximum and to 2 minutes before `--not-after` (the next auto-shutdown); every command has a timeout; Ctrl+C and SIGTERM cancel cleanly (the run is marked Cancelled, open transactions roll back).
  3. **Watchdog:** 60 seconds after the deadline it cancels the run's commands; 15 seconds later it asks the server to `KILL` that run's sessions only (`demo.usp_kill_demo_sessions`), and the run is recorded as TimedOut.
- **No secrets.** T1 and T2 use Windows authentication to the local instance; T3 uses `Authentication=Active Directory Managed Identity` with the VM's identity. Connection strings never contain a password or token, and every log line goes through the same redaction rules as the PowerShell module.
- **Business data comes back.** Blocking and deadlock transactions always roll back; the baseline only toggles values within their seeded ranges; the IO and log-rate scenarios write only to `demo` scratch tables that auto-cleanup and reset empty.

## Commands

Run `ContosoCare.Workload <command> --help` for every option.

| Command | What it does |
|---|---|
| `scenarios [<id>] [--json]` | Lists the catalog, or one scenario's limits, parameters, expected Hub signals, and symptoms. |
| `run --target T1 --scenario locking-blocking [--duration 10m] [--concurrency 3] [--intensity 5] [--param holdSeconds=90] [--reset-before] [--no-auto-cleanup] [--not-after <time>]` | Runs one bounded scenario and waits for it to end. |
| `stop --target T1 (--run-id <id> \| --scenario <id> \| --all)` | Asks runs to stop; they end within a few seconds. `--all` also sets the activity profile to `off`. |
| `reset --target T1 [--wait-seconds 30] [--no-kill] [--keep-profile] [--undo-remediation] [--reseed]` | Stops everything, waits, kills leftover demo sessions, verifies that no demo transaction is open, and empties the scratch tables. Returns one ADR 0012 status per check. |
| `status --target T1 [--runs 10] [--json]` | The activity profile, recent runs, stop requests, live demo sessions (with blocking), and space headroom. |
| `profile get\|set --target T1 [--name incident:cpu-pressure ...]` | Reads or sets the activity profile: `off`, `baseline`, `business-day`, or `incident:<scenario>`. |
| `profile run --target T1 [--t3-server <name>] [--not-after <time>]` | The long-running, service-style host: applies each target's profile until Ctrl+C, SIGTERM, or `--not-after`. |
| `warmup --target T3 --server <name>` | Connects and runs a light query, retrying while a paused serverless database resumes (error 40613), and reports how long it took. |
| `setup --target T1 [--include-base-schema] [--seed-scale 1] [--grant-windows-login "NT SERVICE\ContosoCareWorkload"]` | Creates or updates the demo objects from the embedded scripts (idempotent; run it as an administrator). |
| `version` | Prints the version. |

Global options: `--log-format Text|Json` (standard error), `--log-file <path>` (redacted copy), `--verbose`. Results go to standard output; `--json` writes records in the [validation result](../scripts/modules/DbHubDemo/schemas/validation-result.schema.json) shape, with check IDs such as `WORKLOAD.T1.RESET.NO_OPEN_DEMO_TRANSACTIONS`.

**Exit codes:** `0` when every check passed (warnings included), `1` for a failure or a refused request, `2` when a manual action is required (for example, reset couldn't see other sessions).

`--not-after` takes an ISO 8601 time with an offset, such as `2026-10-20T19:00:00-07:00`; a run ends at least 2 minutes before it, and a run that wouldn't fit 30 seconds is refused.

## Targets and authentication

| Target | `--server` | Authentication | Where the activity profile lives |
|---|---|---|---|
| T1 `sqlvm01` | `.` (default; the local instance) | Windows (the runner's identity), `Encrypt=Mandatory` with the local instance's self-signed certificate trusted | `demo.activity_profile` in T1's `ContosoCare` |
| T2 `arcsql01` | `.` (default; runs inside the guest) | Windows | `demo.activity_profile` in T2's `ContosoCare` |
| T3 `azuresql01` | the logical server name (`.database.windows.net` is added) | `Active Directory Managed Identity` (T1's system-assigned identity, or `--managed-identity-client-id`), strict certificate validation | `C:\ProgramData\DbHubDemo\activity.json` on T1, so polling never wakes the serverless database |

T3 connections use a 60-second connect timeout and retry the documented transient errors (926, 4060, 4221, 40197, 40501, 40613, 49918–49920) for up to 3 minutes, which covers a serverless resume.

**Local containers only:** `--sql-login-from-environment` signs in with `CONTOSOCARE_SQL_USER` and `CONTOSOCARE_SQL_PASSWORD` from the environment (never from arguments), as a `SqlCredential`. It's refused for T3, and the demo targets never use it ([ADR 0009](../docs/adr/0009-secrets-handling.md)).

## Activity profiles

Defined in [`scenarios/activity-profiles.json`](../scenarios/activity-profiles.json) (schema: [`activity-profiles.schema.json`](../scenarios/activity-profiles.schema.json)):

- **`baseline`:** the healthy OLTP mix as back-to-back 30-minute runs (2 sessions at intensity 3; 1 at intensity 2 on T3).
- **`business-day`:** the baseline plus incidents at fixed minutes past each UTC hour: locking at :10 and :40 (the second with the bounded deadlock) on T1; CPU at :05, missing index at :20, IO at :35, and inefficient query at :50 on T2; the CPU cap at :15 and log-rate pressure at :45 on T3.
- **`incident:<scenario>`:** one bounded run of the scenario from the moment the profile is set, with the baseline beside it unless `--with-baseline false`.
- **`off`:** nothing; on T3 the runner opens no session, so the database can auto-pause.

A profile defaults to 8 hours and expires after at most 12 (an incident after its scenario's maximum), and `profile set --not-after` ends it before the next auto-shutdown. The host polls every 10 seconds, starts each window's run only when at least a minute of it is left, and stops runs the profile no longer wants. `--reset-before` on an incident resets the target once before its first run.

## Hosting on the VMs (contract for the delivery phases)

The runner is a **framework-dependent** build: the VM needs the .NET 10 runtime (Phase 6 downloads Microsoft's runtime zip and checks a pinned hash). A suggested layout, which Phase 6 and Phase 13 own:

1. Copy the published folder to, for example, `C:\ProgramData\DbHubDemo\workload\`, and run it as `dotnet ContosoCare.Workload.dll` (or set `DOTNET_ROOT` and use `ContosoCare.Workload.exe`).
2. As an administrator (SYSTEM through Run Command), run `setup --target T1` once per deployment; on T1 also `setup --target T3 --server <name>`. With a dedicated service identity, add `--grant-windows-login <account>`: the login gets only `contosocare_runner` membership in `ContosoCare` (data access to `care` and `demo`, `EXECUTE` on `demo`, `ALTER` on the two scratch tables) and no server-level permissions.
3. Host `profile run --target T1 --t3-server <name>` (T1) or `profile run --target T2` (inside the guest) at startup, for example as a scheduled task, so it survives reboots. It stops cleanly on Ctrl+C or SIGTERM; when the VM shuts down without a signal, SQL Server rolls back the open transactions, and the next start records the orphaned runs as TimedOut.
4. Control it with Run Command: `profile set`, `stop`, `reset`, and `status`. Run `reset` as an administrator: killing sessions and verifying open transactions need `ALTER ANY CONNECTION` and `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022, or `KILL DATABASE CONNECTION` and `VIEW DATABASE STATE` on Azure SQL Database. Without them reset reports **Manual action required** instead of Pass.

## Build, test, and publish

Run from this folder so `global.json` (SDK pin and Microsoft.Testing.Platform opt-in) applies:

```powershell
dotnet restore --locked-mode
dotnet build --no-restore --configuration Release
dotnet test --no-build --configuration Release
dotnet run --project src/ContosoCare.Workload -- scenarios
```

The integration tests in `SqlIntegrationTests` run only when `CONTOSOCARE_TEST_SQL_SERVER` names a disposable instance reached with Windows authentication, for example a LocalDB instance created for the purpose:

```powershell
sqllocaldb create contosocare-test -s
$env:CONTOSOCARE_TEST_SQL_SERVER = '(localdb)\contosocare-test'
dotnet test --configuration Release -- --filter-class ContosoCare.Workload.Tests.SqlIntegrationTests
```

Publish the small, framework-dependent Windows build that the VMs run:

```powershell
dotnet publish src/ContosoCare.Workload --configuration Release --runtime win-x64 --self-contained false --output out/runner-win-x64
```

`--runtime win-x64` keeps one native SNI library instead of four; English resources only (`SatelliteResourceLanguages`). The Microsoft Entra extension brings the Windows broker's native runtime for interactive sign-in, which the runner never uses, so publish leaves it out (`-p:KeepBrokerRuntime=true` keeps it). On 2026-10-20 the published folder was 8.9 MB, 3.2 MB zipped.

## Container (local testing)

[`compose.yaml`](compose.yaml) pairs the runner image with SQL Server 2022 Developer. Build from the repository root; the runner embeds `scenarios/` and `database/common/` ([`Dockerfile.dockerignore`](Dockerfile.dockerignore) limits the context):

```powershell
$env:MSSQL_SA_PASSWORD = '<a strong password you choose>'   # only in your shell; never commit it
docker compose --file workload-generator/compose.yaml up --detach sql
docker compose --file workload-generator/compose.yaml exec sql bash -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -P "$MSSQL_SA_PASSWORD" -Q "CREATE DATABASE ContosoCare"'
docker compose --file workload-generator/compose.yaml run --rm runner setup --target T2 --server sql --sql-login-from-environment --include-base-schema --seed-scale 1
docker compose --file workload-generator/compose.yaml run --rm runner run --target T2 --server sql --sql-login-from-environment --scenario locking-blocking --duration 2m
docker compose --file workload-generator/compose.yaml down
```

The runner never creates databases, so the one `CREATE DATABASE` runs with `sqlcmd` inside the SQL container, where the password stays in the container's environment. The container's files are uncapped, so the IO and log-rate scenarios refuse to run there until you cap them (`ALTER DATABASE ContosoCare MODIFY FILE (NAME = ..., MAXSIZE = ...)`), as `030-configure.sql` does on T1 and T2.

## Layout

| Path | Contents |
|---|---|
| `src/ContosoCare.Workload/Cli/` | The command line (System.CommandLine 2.0) |
| `src/ContosoCare.Workload/Catalog/` | Scenario catalog, parameters, activity profiles, and the profile scheduler |
| `src/ContosoCare.Workload/Runs/` | Run bounds and the scenario runner with its watchdog |
| `src/ContosoCare.Workload/Profiles/` | Profile stores (database and file) and the long-running profile host |
| `src/ContosoCare.Workload/Sql/` | Connection strings, retries, the demo procedures, and the embedded scripts |
| `src/ContosoCare.Workload/Diagnostics/` | Structured, redacted logging |
| `tests/ContosoCare.Workload.Tests/` | xUnit v3 tests on Microsoft.Testing.Platform, including the JSON schema and T-SQL safety checks |
| `Directory.Packages.props` | Central package versions; lock files keep restores reproducible |
| `Dockerfile`, `Dockerfile.dockerignore`, `compose.yaml` | Local container runs |

## Sources (checked 2026-10-20)

- Microsoft Entra authentication with Microsoft.Data.SqlClient: <https://learn.microsoft.com/sql/connect/ado-net/sql/azure-active-directory-authentication>
- Transient errors: <https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues>
- Serverless auto-pause and resume: <https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume>
- `KILL` permissions: <https://learn.microsoft.com/sql/t-sql/language-elements/kill-transact-sql>
- `sys.dm_exec_sessions` permissions: <https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-sessions-transact-sql>
- Connection pooling (why the runner turns it off): <https://learn.microsoft.com/sql/connect/ado-net/sql-server-connection-pooling>
- Globalization settings (SqlClient needs culture data): <https://learn.microsoft.com/dotnet/core/runtime-config/globalization>
- Framework-dependent deployment and `dotnet publish`: <https://learn.microsoft.com/dotnet/core/deploying/>, <https://learn.microsoft.com/dotnet/core/tools/dotnet-publish>
- SQL Server Linux containers: <https://learn.microsoft.com/sql/linux/quickstart-install-connect-docker>
- Dockerfile-specific ignore files: <https://docs.docker.com/build/concepts/context/>
