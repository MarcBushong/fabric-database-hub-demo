# Workload generator

`ContosoCare.Workload` is the .NET 10 LTS runner that drives the demo's bounded scenarios and activity profiles on T1 to T5 ([ADR 0010](../docs/adr/0010-workload-generator-technology.md)). The scenario logic lives in T-SQL procedures named as a real application's, in the application schemas `billing`, `frontdesk`, `records`, `reporting`, `scheduling`, and `supply`, with the control plane in `demo` ([database/common](../database/common/README.md)), in PostgreSQL functions of the same names on T4 ([database/postgresql](../database/postgresql/README.md)), and in the runner's Cosmos DB REST client on T5 ([T5](#t5-azure-cosmos-db-for-nosql)); the runner orchestrates sessions, timing, bounds, and records, and it reads its scenario catalog from [`scenarios/`](../scenarios/README.md), embedded at build time.

## What it guarantees

- **Only the `ContosoCare` database.** Every connection string has `Initial Catalog=ContosoCare`, and there's no option to change it. On T5, every request's resource path is in `contosocare/patient-events`.
- **Tagged sessions.** Every scenario session carries `Application Name=ContosoCare.Demo/<service>/<runId>`: the client service its `scenario.json` names (`billing-worker`, `scheduling-service`, ...), which several scenarios share, and a run ID of 16 random lowercase hex characters, which `demo.scenario_runs` maps back to the scenario, target, and start, so the name doesn't name the fault (2026-11-23, [ADR 0031, decision 6](../docs/adr/0031-incident-rca.md#2-names)). Bookkeeping sessions carry `ContosoCare.Demo/control/<id>`. On T5, every request's User-Agent starts with the same tag. The watchdog and reset touch only scenario sessions of this database, and the runner's watchdog only those of its own run, which it finds by the run ID, so an older runner's names (`ContosoCare.Demo/<scenarioId>/<runId>`) match too.
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
| `run --target T1 --scenario locking-blocking [--duration 10m] [--concurrency 3] [--intensity 5] [--param holdSeconds=90] [--reset-before] [--no-auto-cleanup] [--not-after <time>]` | Runs one bounded scenario and waits for it to end. When the target's workload modules aren't set up for the runner yet (its scenario's entry procedure isn't there, or, on T4, the runner's role can't run it yet), the run is refused before anything starts (`out-of-step`, with `./scripts/deploy.ps1` as the fix), and the profile host tries it again. |
| `stop --target T1 (--run-id <id> \| --scenario <id> \| --all [--if-newer <time> --request-id <id>])` | Asks runs to stop; they end within a few seconds. `--all` also sets the activity profile to `off`. |
| `reset --target T1 [--wait-seconds 30] [--no-kill] [--keep-profile] [--undo-remediation] [--reseed] [--if-newer <time> --request-id <id>]` | Stops everything, waits, kills leftover demo sessions, verifies that no demo transaction is open, and empties the scratch tables. Returns one ADR 0012 status per check. |
| `status --target T1 [--runs 10] [--json]` | The activity profile, recent runs, stop requests, live demo sessions (with blocking), and space headroom. |
| `profile get\|set --target T1 [--name incident:cpu-pressure ...] [--tier Burstable\|GeneralPurpose] [--vcores <n>] [--if-newer <time> --request-id <id>]` | Reads or sets the activity profile: `off`, `baseline`, `business-day`, `showcase`, or `incident:<scenario>`. |
| `profile run --target T1 [--t3-server <name>] [--t4-server <fqdn>] [--t5-server <host>] [--not-after <time>]` | The long-running, service-style host: applies each target's profile until Ctrl+C, SIGTERM, or `--not-after`. |
| `warmup --target T3 --server <name>` | Connects and runs a light query, retrying while a paused serverless database resumes (error 40613), and reports how long it took. |
| `setup --target T1 [--include-base-schema] [--seed-scale 1] [--grant-windows-login "NT SERVICE\ContosoCareWorkload"]` | Creates or updates the demo objects from the embedded scripts (idempotent; run it as an administrator), and drops each workload module's earlier name in `demo` (`demo.usp_scenario_*` and its helpers) once every replacement exists. |
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
| T5 `cosmos01` | the account's host name, `cosmos01-<id>.documents.azure.com` (lowercase, nothing added) | A Microsoft Entra token from T1's managed identity (or `--managed-identity-client-id`) in each REST request; the account's local (key) authentication is off | `C:\ProgramData\DbHubDemo\activity-t5.json` on T1, and its runs in `t5-runs.json` beside it |

T3 connections use a 60-second connect timeout and retry the documented transient errors (926, 4060, 4221, 40197, 40501, 40613, 49918–49920) for up to 3 minutes, which covers a serverless resume.

**Local containers only:** `--sql-login-from-environment` signs in with `CONTOSOCARE_SQL_USER` and `CONTOSOCARE_SQL_PASSWORD` from the environment (never from arguments), as a `SqlCredential`. It's refused for T3, and the demo targets never use it ([ADR 0009](../docs/adr/0009-secrets-handling.md)).

**T4's read replica ([ADR 0025](../docs/adr/0025-t4-read-replica.md)):** T4 commands take `--replica-server <fqdn>`, the replica `pgreplica01-<id>` that `start-demo.ps1` creates for a session, signed in with the same role, token, and TLS checks as `--server`. `run` needs it for `replica-lag`, which is refused without it; `stop` and `reset` also end the demo's `ContosoCare.Demo/` sessions there (`pg_cancel_backend`, then `pg_terminate_backend`), and a replica that isn't there is **Not selected**, never a failure; `status` adds its replay lag. A T1 host that also drives T4 takes `profile run --t4-replica-server`. Other T4 commands ignore it, and the other targets refuse it.

## T5: Azure Cosmos DB for NoSQL

T5 is the account `cosmos01-<id>`, with local (key) authentication off. The runner works only in its database `contosocare` and container `patient-events` (partition key `/patientId`, 400 RU/s), whose data model is in [database/cosmosdb](../database/cosmosdb/README.md), and runs `healthy-baseline` and `ru-storm` there. The container exists only during a session, to cut T5's idle cost: it's created through Azure Resource Manager when a session starts (`./scripts/start-demo.ps1` or the control notebook's **Run all**) and deleted when it ends, and the account and the database stay. The runner never creates it; while it's missing, the commands below say so.

| Command | On T5 |
|---|---|
| `run --target T5 --server <host> --scenario ru-storm [--run-file <path>]` | Reads the container first: an account it can't reach, or a 401 or 403 while T1's data-plane role isn't effective yet, refuses the run for the profile host to try again. So does a container that doesn't exist now (a 404, refusal reason `request`): "T5's container contosocare/patient-events doesn't exist now: it exists only during a session, so ./scripts/start-demo.ps1 or the control notebook's Run all creates it first.", and the profile host tries it again every 30 seconds, bounded by the activity's window and 40 attempts, so a profile set just before its session creates the container starts once it exists. Then it registers the run in the run store and sends the scenario's requests until its deadline or a stop. A container deleted mid-run (a 404 with substatus 1003) ends the run as Failed, with the same reason. |
| `stop --target T5 (--run-id <id> \| --scenario <id> \| --all) [--run-file <path>]` | Marks Running runs Cancelled in the run store; their writers stop within a few seconds. `--all` also sets T5's profile file to off. It doesn't need `--server`. |
| `reset --target T5 --server <host> [--wait-seconds 30] [--keep-profile]` | Sets the profile off, stops every run, waits for them to end, checks that none is Running (`no-running-runs`), and deletes any ru-storm document left over (`storm-documents-removed`): a **Pass** with nothing to delete when the container doesn't exist now, "T5's container doesn't exist now (it exists only during a session), so no storm document is left." `--undo-remediation` and `--reseed` are **Not supported**: T5 has neither. |
| `status --target T5 --server <host> [--json]` | The profile, the runs and stop requests, the account (whether its container answers, and its partition key, or that the container doesn't exist now, which isn't an error), the live rates, and the profile host's lane. |
| `warmup --target T5 --server <host>` | A token, the container's definition, and an upsert and a point read of the warmup document: **Pass** with the time and the request units. A container that doesn't exist now fails it with the run's message. |
| `setup --target T5 --server <host> [--seed-scale <n>]` | Checks the container (`container`: it exists, partitioned on `/patientId`; a **Fail** when it doesn't exist now, which says it exists only during a session and that `./scripts/start-demo.ps1`, or `deploy.ps1`, creates it) and, with `--seed-scale` 1 to 50, upserts `n` x 100 patient profile documents (`seed`). It creates nothing else. |
| `profile get\|set --target T5` | T5's profile file, `activity-t5.json`; `--profile-file` names another. |
| `profile run --target T1 ... --t5-server <host> [--t5-managed-identity-client-id <id>] [--t5-profile-file <path>] [--t5-run-file <path>]` | Adds a T5 lane to T1's host. The `--t5-` options go only with a T1 host, and the other three only with `--t5-server`. |

`--managed-identity-client-id` works as on T3 and T4. The SQL and T4 options (`--user`, `--pg-password-from-environment`, `--replica-server`, `--sql-login-from-environment`, `--include-base-schema`, `--grant-windows-login`, `--grant-entra-object-id`, `--runner-role`) are refused on T5, and `--run-file` on the other targets. Check IDs are `WORKLOAD.T5.<COMMAND>.<CHECK>`.

- **`status --target T5 --json`:** `target`, `profile`, `runs`, `stopRequests` (each with its `scope` and `runId`), `account`, and `host`, in that order: the host block last, as on the other targets, for the tail a Run Command keeps. `account` has `endpoint`, `database`, `container`, `reachable` (the account answered), `containerExists` (`false` when the container doesn't exist now, `null` when the account didn't answer), `partitionKey` (the container's `paths`, `kind`, and `version`), `error` (redacted, when the account doesn't answer), `note` (when the container doesn't exist now: "T5's container doesn't exist now: it exists only during a session (./scripts/start-demo.ps1 or the control notebook's Run all creates it)."), and `live`: the Running runs' `requestsPerSecond`, `ruPerSecond`, `throttledPerSecond` (429s), `throttledLastMinute`, and `updatedAt`, summed. A run's rates count while it reports them, every 5 seconds. The run store is on T1, so `status` shows the runs while the account doesn't answer, and its exit code is 0 either way.
- **The REST client, and why:** the documented Cosmos DB REST API (Upsert, Get, Query, and Delete Document, and Get Collection) over HttpClient, with no Cosmos DB SDK: Azure.Identity was already a dependency, so the build and its lock files stay as they were. Every request goes over HTTPS on port 443 to the account's gateway, the only port T1's network security group lets out, with `Authorization: type=aad&ver=1.0&sig=<token>`, URL-encoded: a Microsoft Entra token from T1's managed identity for `https://<host>/.default`, or for `https://cosmos.azure.com/.default` when Microsoft Entra ID doesn't know the account's own resource (AADSTS500011), as the SDK does ([access control](https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources)). Tokens are reused until 5 minutes before they expire, and neither a token nor the header is ever logged. Every request's User-Agent starts with the run's tag, `ContosoCare.Demo/<service>/<run>`, then `ContosoCare.Workload/<version>`. The runner reads `x-ms-request-charge`, and on a 429, `x-ms-retry-after-ms`. One pooled HttpClient per runner, its connections recycled every 5 minutes, and 30 seconds per request.
- **The run store:** T5 has no control tables, so `t5-runs.json` on T1 (`--run-file`; by default next to the profile files, `C:\ProgramData\DbHubDemo\t5-runs.json`) does what `demo.usp_run_begin`, `demo.usp_stop`, and `demo.usp_run_end` do elsewhere. A run is refused while its scenario has a Running run (`running-run`) or four runs are Running (`run-limit`), which the profile host tries again, and a Running run past its deadline and the runner's 60-second grace is TimedOut first. A run reads its own status every 2 seconds, so a stop ends it within a few seconds, and records its counters and rates every 5. The store keeps the 50 most recent runs and the last 10 stop requests, under the same lock file and replace as the profile files. Each run records its machine and process, so a profile host that starts after an earlier one stopped ends that one's runs (`profile.orphans-recovered`), and deletes the documents of an ru-storm among them, and reset closes the record of a run whose runner's process is gone.
- **Bounds:** every write is an upsert to an ID from a fixed set, so the container's data can't grow from session to session. A request that fails for a reason that passes is tried again after a backoff of up to 5 seconds, and 20 failures in a row end a writer. ru-storm's writers send 100 requests a second at most, and after a 429 wait the server's retry-after (10 ms to 2 seconds). The deadline, the 60-second grace, and stop work as on the other targets; there are no sessions to kill.
- **Cleanup:** ru-storm deletes its storm documents when it ends, however it ends, before it records its end, paced to 200 RU/s: a few seconds by default, and 400 documents at most. When its process ended mid-storm (a deallocated VM), the next profile host deletes them as it recovers the run, and `reset --target T5` deletes any left over. A container that doesn't exist now (a 404 with substatus 1003, [not found](https://learn.microsoft.com/azure/cosmos-db/troubleshoot-not-found)) holds no storm document, so each of these cleanups is complete, a **Pass**. `healthy-baseline` keeps its fixed set of documents ([bounded by design](../database/cosmosdb/README.md#bounded-by-design)).

## Activity profiles

Defined in [`scenarios/activity-profiles.json`](../scenarios/activity-profiles.json) (schema: [`activity-profiles.schema.json`](../scenarios/activity-profiles.schema.json)):

- **`baseline`:** the healthy OLTP mix as back-to-back 30-minute runs (2 sessions at intensity 3; 1 at intensity 2 on T3, T4, and T5).
- **`business-day`:** the baseline plus incidents at fixed minutes past each UTC hour: locking at :10 and :40 (the second with the bounded deadlock) on T1; CPU at :05, missing index at :20, IO at :35, and inefficient query at :50 on T2; the CPU cap at :15 and log-rate pressure at :45 on T3; a connection surge at :08, idle-in-transaction blockers at :22, and CPU at :42 on T4; an RU storm at :25 on T5.
- **`showcase`:** the baseline plus a 30-minute cycle of incidents on every target, at most two at a time per target, 90 minutes by default and 120 at most; **Run all** in the control notebook sets it. Its cycle starts when the profile is set (`"anchor": "profileStart"`; `business-day` keeps `utcDay`), a slot's `cycles` (`all`, `odd`, `even`, or a list such as `1,3`) picks the cycles it runs in, and a T4 slot's `tier` picks Burstable or General Purpose: `profile set --tier` records T4's tier, and without one only the slots for Burstable run. `profile set --vcores` records T4's vCores, which scale its CPU-bound slots (`cpu-pressure`) to the same load per vCore as the size each slot was written for (one Burstable vCore, or two General Purpose vCores): `Standard_D4ds_v5` runs the General Purpose slot's 3 sessions as 6, never more than the scenario's maximum (16). The control's runbook passes both from T4's size. T5 storms twice in each cycle, from minute 3 for 10 minutes and from minute 18 for 8, with calm time between them. A slot's `recoveryMinutes` (0 to 30) makes it run only whole and with that many minutes left before the profile's end for its target to recover to its baseline: a slot that can't, near the profile's end, or one whose window began before the profile was set (`business-day`), is skipped rather than clipped. T5's ru-storm slots have 2 (normalized RU back under 100% and no 429s), so T5's profile can run its baseline to a session's end with no storm cut short; slots without it are clipped at the profile's end, as before. The schedule and what it fills are in the [README](../docs/database-hub-visuals.md#what-fills-each-database-hub-visual-and-when).
- **`incident:<scenario>`:** one bounded run of the scenario from the moment the profile is set, with the baseline beside it unless `--with-baseline false`.
- **`off`:** nothing; on T3 the runner opens no session, so the database can auto-pause, and on T5 it sends no request.

A profile defaults to 8 hours and expires after at most 12 (an incident after its scenario's maximum, and the showcase after 90 minutes by default and 120 at most), and `profile set --not-after` ends it before the next auto-shutdown. The host polls every 10 seconds, starts each window's run only when at least a minute of it is left, and stops runs the profile no longer wants. `--reset-before` on an incident resets the target once before its first run. `profile run` raises its own priority to above normal on Windows, so an incident's CPU on the same VM doesn't starve its other lanes, and records it in `host-lanes.json`.

**Request stamps (newest wins):** `profile set`, `stop --all`, and `reset` take `--if-newer <time>` with `--request-id <id>`, such as an Automation job's start time and ID. A stamped write applies only when the stored request is older (the time to the millisecond, then the ID by ordinal comparison); otherwise it reports **Pass** with "Not applied: a newer request ... is already set" and changes nothing: a refused `stop --all` or `reset` stops nothing either. The same request twice keeps the profile and its cycle. A write without a stamp always applies and keeps the stored stamp. `demo.usp_profile_set` makes the comparison atomic on T1 and T2, and a lock file (`activity.json.lock`) does on T1 for T3's and T4's file ([ADR 0010](../docs/adr/0010-workload-generator-technology.md#the-showcase-anchors-cycles-tiers-request-stamps-the-hosts-priority-and-plan-regression-2026-11-03)). No caller passes them yet (2026-11-04): the control refuses a second run while one is active.

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
| `src/ContosoCare.Workload/Cosmos/` | T5: the REST client and its tokens, the run store, the scenarios' workloads, the storm's cleanup, and the Cosmos DB runner |
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
- Azure Cosmos DB REST API and its Microsoft Entra access control (T5, checked 2026-11-18): <https://learn.microsoft.com/rest/api/cosmos-db/>, <https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources>
- Request rate too large (429) and normalized RU consumption (T5): <https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-request-rate-too-large>, <https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units>
