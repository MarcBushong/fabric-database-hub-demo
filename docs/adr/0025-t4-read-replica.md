# ADR 0025: T4's read replica, created for each session

- **Status:** Accepted (the per-session design was approved on 2026-11-13 within the owner's delegated scope, with the session ceiling kept at $15 and T4's one-time size move evaluated without the replica's share). Live validation: [below](#validation).
- **Date:** 2026-11-13
- **Decision source:** User-directed (2026-11-13: "Postgres HA/DR": add the replica to the one-click deployment, account for its lag in the activity notebook and the Insights app, and keep it efficient and cost manageable, for new users and for those who deployed before), with the lifecycle, size, and lag scenario decided by the implementer from a live probe the same day
- **Related:** [ADR 0012](0012-validation-model.md) (statuses), [ADR 0016](0016-cost-profiles.md) (ceilings and the restart rule), [ADR 0019](0019-t4-postgresql-flexible-server.md) (T4 and its size fallback), [ADR 0020](0020-on-demand-activity-control.md) (the control), [ADR 0024](0024-nightly-safety-stop.md) (the safety stop and its role), [limitations](../limitations.md)

## Context

- **Database Hub's PostgreSQL dashboard has a Read replica lag chart** (`physical_replication_delay_in_seconds`: "Read replica delay in seconds; not HA standby or logical replication lag"), and Estate lists flexible servers, so a replica is a row of its own ([monitor PostgreSQL](https://learn.microsoft.com/fabric/database/hub/monitor-postgresql), updated 2026-10-17). T4 had no replica, so the chart stayed empty. The owner chose a same-region read replica of T4; Hyperscale, an HA standby, and Azure SQL geo-replication are out of scope.
- **What Learn says** ([read replicas](https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas) and [create a read replica](https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica), both updated 2026-07-16):
  - The Burstable tier isn't supported. The replica's compute size must have "the same or a higher number of vCores as the source server", and "compute on the primary must always be equal to or smaller than the compute on the smallest replica".
  - Each replica bills its provisioned compute and its storage. Same-region creation uses a snapshot, so its time doesn't depend on the data's size. Creating or deleting a replica puts the primary in an updating state, which blocks management operations but not connections.
  - Power operations: "Before stopping the read replicas, ensure the primary server is stopped first. When commencing operations, initiate the start action on the replica servers before starting the primary server." Delete the replicas before the primary.
  - Parameters are inherited when the replica is created and are independent afterwards; `max_connections` and four others must stay at or above the primary's. Authentication is inherited from the source.
  - **Read Replica Lag** is "the time since the last replayed transaction", on replicas only; the primary has **Max Physical Replication Lag** (bytes).
- **The live probe (2026-11-13, West US 3, two `Standard_D2ds_v5` servers in a delegated subnet with T4's network security group rules, about $1):**

  | What | Result |
  |---|---|
  | Replica created from a template (`createMode` `Replica`) | **460 to 525 seconds** over two creations; the primary showed Updating meanwhile and Ready after |
  | Inherited | Entra-only authentication, the subnet and private DNS zone, 32 GiB P4 without auto-grow, PostgreSQL 18, `max_connections` 50, enhanced metrics on |
  | `max_standby_streaming_delay`, `hot_standby_feedback` on the replica | Settable and dynamic (16 seconds each); `hot_standby` is read-only on |
  | The replica's template deployed again | **Fails**: `ReadReplicaAlreadyExistWithGivenName` |
  | T4's template deployed again with the replica there | Succeeds (252 seconds) and leaves the replica's parameters alone |
  | Replica stopped while the primary runs | **Refused**: `SourceReplicasStartStopOrder` ("Source server must be stopped before stopping its read replicas. Replicas must be started before starting their source server.") |
  | Primary started while the replica is stopped, or still Starting | **Refused**, the same code |
  | Each stop or start | About 125 seconds |
  | Replica deleted (primary stopped) | 97 seconds; the primary then started with no replica left |
  | Replica created while the primary is stopped | **Refused**: `ReadReplicaServerInUnexpectedState` |
  | Metrics with an idle primary | Read Replica Lag 2 to 6 seconds a minute; Max Physical Replication Lag 0 to 184 bytes |
  | A deleted replica's metrics | **Gone**: Azure Monitor answers `ResourceNotFound` for its resource ID, so a session's lag curve has to be read before the delete |

- **The cost rules** ([ADR 0016](0016-cost-profiles.md)): a first deployment's preflight counts T4's 7-day restart as running the rest of the month, because the nightly safety stop doesn't exist yet, and so does an older environment's preflight before `deploy.ps1` sets the safety stop up. The default configuration's month is then $312.21 (dated example, 2026-11-05), and the owner's kind of configuration (the tenant's Defender plans) $359.69, against the $375 ceiling.

## Decision drivers

1. One click, for a new deployment and for an existing one: `./scripts/deploy.ps1` adds the replica, and nothing asks for a person.
2. The default first deployment, and an older environment's upgrade, keep passing preflight at the default ceilings, with no change to the ceilings, the restart rule, or any role.
3. The replica follows T4's actual size, falls back on `SkuNotAvailable` the way T4 does, and is never left out silently.
4. Read replica lag shows something worth presenting, within the demo's bounds ([ADR 0010](0010-workload-generator-technology.md)).

## Considered options

| Option | How | Outcome |
|---|---|---|
| R1 | A replica for each session: `deploy.ps1` and `start-demo.ps1` create it, `stop-demo.ps1` deletes it | **Chosen** |
| R2 | A lasting replica, stopped and started with T4 | Rejected: it bills storage and its Defender plans all month, about $23.79 with this tenant's plans (storage $3.68, Defender for open-source relational databases about $15, Defender CSPM about $5.11), and its own 7-day restart counts like T4's: 96 hours where the safety stop holds ($34.18 at `Standard_D4ds_v5`), the rest of the month where it doesn't ($256.32). A first deployment would then come to about $576 against $375, and the owner's upgrade to about $643. Passing would need a higher ceiling or another restart rule, which only the owner changes. Azure's enforced power order would also apply to every session |
| R3 | R2, with the restart counted at 96 hours because `deploy.ps1` creates the replica only after the safety stop is in place | Rejected: still over $375 for the owner's kind of configuration (about $421), and a Contributor's deployment wouldn't get the replica until an Owner assigns the role |
| R4 | The replica only for the lag scenario, created by `demo-control.ps1` | Rejected: Database Hub's Estate and Read replica lag would be empty for most of a session, and DONE couldn't check it |

## Decision

### The replica

- **`pgreplica01-<deploymentId>`** in `rg-<prefix>-<environment>` (`config/versions.json` `postgresql.replica`), a same-region read replica of T4 from `infra/replica/pgreplica01.bicep`, a resource group deployment named `dbhub-t4-replica`, deployed only while the replica doesn't exist (a second deployment fails). It's in T4's delegated subnet `snet-pg` and private DNS zone, so the network security group's existing rule for port 5432 within the subnet covers replication, in both network modes. Authentication is T4's, Microsoft Entra only; T1's managed identity signs in as the same runner role, because roles replicate.
- **Its size is T4's actual size**, read from Azure when it's created, never a smaller one. Storage is T4's 32 GiB P4 without auto-grow.
- **A Burstable T4 has no replica:** `Not supported`, with the fix, a General Purpose size in `t4SkuName` or none (the default), in preflight, `deploy.ps1`, `start-demo.ps1`, and `status.ps1`. DONE doesn't wait for it then.
- **Its parameters:** `max_standby_streaming_delay` 600000 ms (10 minutes) for the lag scenario; the rest are inherited from T4 when it's created.

### The size fallback

Only Azure's `SkuNotAvailable` for the size an attempt sent, read from the deployment's operations, moves it on, as for T4 ([ADR 0019](0019-t4-postgresql-flexible-server.md#2026-11-09-user-directed-a-size-t4skuname-sets-falls-back-too-and-every-automatic-size-change-says-what-it-cost)):

1. The size the last replica used (`DbHubT4ReplicaSize`, `<size>@<zone or any>`), first when it's a documented General Purpose size with T4's vCores, so a size Azure refused isn't asked for at every session again.
2. T4's size with no zone preference, then once in another zone the region lists for it, the way T4's own fallback retries.
3. A recorded size with more vCores than T4's, which costs more, only after T4's own size, so each session asks for T4's size first. A recorded size with fewer vCores is ignored.
4. The other documented General Purpose sizes with the same vCores (for `Standard_D4ds_v5`, `Standard_D4ads_v5`), then the larger ones (a 2-vCore T4 tries the 4-vCore sizes). Never fewer vCores than T4's.

- A refused attempt leaves a `Dropping` shell for a few minutes (ADR 0019's 2026-11-09 finding); the next attempt waits until it's gone, at most 15 minutes.
- **The notice, `DEPLOY.T4.REPLICA.FALLBACK` or `START.T4.REPLICA.FALLBACK`** (a Warning that never blocks DONE), says the size asked for (T4's), each size and zone Azure refused, the size created, and the replica's hourly price at both, with the difference, from the Azure Retail Prices API. It's a console line, the status page's T4 row, and DONE's or NOT DONE's notes.
- **When Azure refuses every size,** the run deploys the rest and ends **NOT DONE** (`DEPLOY.T4.REPLICA`, a **Fail**), with the fix: a Region access request ([capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors)). `start-demo.ps1` starts the session without it, with a Warning.

### The lifecycle

| Script | What it does with the replica |
|---|---|
| `deploy.ps1` | Creates it when it's missing, after T4's `max_connections` restart, in the T4 track (`DEPLOY.T4.REPLICA`), then checks it (`T4.REPLICA`), its metrics (`METRICS.T4.REPLICA`), and Database Hub's Estate (`HUB.ESTATE.T4.REPLICA`), both required for DONE. DONE's gate creates it too when it's missing, for a run that resumes after the T4 track had finished. It records `DbHubT4Replica` `Session` on the resource group, which marks the environment as having the replica. Before T4 starts or scales, a stopped replica starts first, or is deleted when T4 would outgrow it |
| `start-demo.ps1` | A replica that's stopped starts first, then T4. One that's missing is created once T4 is Ready, about 9 minutes, within the 30-minute warm-up; the start waits for it at its end (`START.T4.REPLICA`). `-SkipT4Replica` leaves it out of a session, and says what that leaves out |
| `stop-demo.ps1` | With `-SaveHistory` (or `fabric.saveHistoryOnStop`), reads T4's and the replica's metrics first, because a deleted replica's metrics are gone. Then deletes the replica before T4 stops, about 2 minutes, in parallel with the VMs' deallocation (`STOP.T4.REPLICA`), so nothing bills between sessions and no 7-day restart applies to it. T4's stop after that is confirmed: Azure can accept it and refuse it a minute later while the replica's delete finishes (live in the control's runbook, 2026-11-14), so it's asked again, at most 3 times in 10 minutes, and a T4 still running is a **Fail** with the fix (2026-11-14, R843) |
| `status.ps1`, `validate.ps1` | Its state, size, lag, and health metrics (`STATUS.T4.REPLICA`); a replica that exists while T4 is stopped is a Warning whose fix is `stop-demo.ps1` |
| The nightly safety stop | A replica left running (a session that ended without `stop-demo.ps1`) is stopped after T4 is Stopped, in Azure's order, with the role it has ([ADR 0024](0024-nightly-safety-stop.md)); its job output says the replica was stopped, not deleted, and that `stop-demo.ps1` deletes it. The next `start-demo.ps1` starts it before T4, and the next `stop-demo.ps1` deletes it |
| The on-demand control | Starts a stopped replica before T4, and stops it after T4, with the role it has ([ADR 0020](0020-on-demand-activity-control.md)); it never creates or deletes one. A run it starts without a replica says so plainly: Read replica lag and the `replica-lag` beat aren't available until `start-demo.ps1` creates the replica |
| `reset-demo.ps1` | Ends the replica's `ContosoCare.Demo/` sessions with T4's reset |
| `destroy.ps1` | Deletes it before the resource group |

- **Before the upgrade:** in an environment `deploy.ps1` hasn't set up the replica in (no `DbHubT4Replica`), `start-demo.ps1`, `stop-demo.ps1`, `status.ps1`, and `validate.ps1` say "T4's read replica isn't deployed yet: run ./scripts/deploy.ps1, which adds it", as **Not selected** or a **Warning**, never a **Fail**, and change nothing.
- **The on-demand control's runbooks:** they carry the replica's power order, so when an environment has the control set up, `deploy.ps1` republishes its runbooks with the current code, as it does the safety stop's (`CONTROL.RUNBOOKS`). When it can't (permissions, for example), it's a **Warning** on the console, the status page, and DONE's or NOT DONE's notes, with the exact command (`./scripts/setup-activity-control.ps1`) and what fails until then: the control runs its older code, so a run can't start T4 while a replica a session left behind is stopped, a run doesn't say when the replica beat isn't there, and its stops leave such a replica running (the nightly safety stop still stops it).
- **No role changes:** the safety stop's role and the control's already have `Microsoft.DBforPostgreSQL/flexibleServers/read` and `/stop/action` (the control's also `/start/action`) at the demo resource group, which covers the replica.

### The history

- A deleted replica's Azure Monitor metrics can't be read (`ResourceNotFound`, live 2026-11-13), so the history reads them while it exists: `stop-demo.ps1 -SaveHistory` reads T4's and the replica's metrics (Read Replica Lag, CPU, connections, and T4's failed connections and replication bytes) before it deletes the replica, and passes them to the live-activity notebook's persist step as `POSTGRES_METRICS`.
- **When that run doesn't save them** (a paused Fabric capacity, which the owner manages, or a failed run), `stop-demo.ps1` keeps the captured document in `out/history-pending/postgres-metrics-<resource group>-<time>.json` and says so (`STOP.T4.HISTORY.PENDING`, a **Warning** with the replica's peak lag), with the command that adds it once the capacity runs: `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath <file>`, which moves the file to `out/history-pending/saved` after a run that passed. So a session's lag curve is never lost without a word. Without `-PostgresMetricsPath`, `configure-fabric.ps1 -RunLiveActivity` sends T4's and a running replica's metrics, as `deploy.ps1`'s history snapshot does.
- The notebook keeps them in `telemetry_snapshots` (analysis `postgresql`, targets `T4` and `T4-replica`) and `analysis_findings` (a lag of 60 seconds or more is a Warning), which the history's semantic model and the Insights app's PostgreSQL page read. `deploy.ps1`'s history snapshot passes them the same way. A notebook run started in Fabric can't read Azure Monitor (its tokens don't cover Azure Resource Manager), so it says in one line that T4's metrics weren't passed and saves the SQL targets' history as before.

### The lag scenario: `replica-lag`

- A bounded T4 scenario (default 10 minutes, at most 15): a `ContosoCare.Demo/replica-lag/<run>` reporting query on the replica reads `demo.replica_lag_marks` and holds its lock for `holdSeconds` (default 240, at most 540); the primary takes an `ACCESS EXCLUSIVE` lock on that table once, in a short transaction, and keeps committing small marks. Replaying the lock waits for the replica's query, up to `max_standby_streaming_delay`, so Read replica lag climbs to about `holdSeconds`, then drops when the query ends ([handling query conflicts](https://www.postgresql.org/docs/current/hot-standby.html#HOT-STANDBY-CONFLICT)).
- Only the demo's own table and sessions: the query has a `statement_timeout` before the run's hard deadline, and `stop` and `reset` end the replica's `ContosoCare.Demo/` sessions only. Without a replica, the run is refused with the fix.

### Cost

- **Per session:** the replica bills while it exists, so the estimate counts it like T4's compute, for the session's hours only: its compute at T4's size, its storage, and its Defender plans where they're on, prorated by the hour. No fixed monthly cost, and no 7-day restart in the plan (it's deleted, never left stopped), so the restart rule and the ceilings stay as they are.
- **Dated example (list prices, West US 3, 2026-11-13, `Standard_D4ds_v5`, from `./scripts/estimate-cost.ps1`):** $0.356 an hour of compute and $0.005 of storage, $0.361 in all, or $0.389 with this tenant's Defender plans.

  | Configuration | Without the replica | With it | Ceiling |
  |---|---|---|---|
  | `lowest-cost`, a 5-hour session | $10.61 | $12.42 | $15, Pass |
  | `lowest-cost`, a light-use month (10 running hours) | $55.89 | $59.50 | $375, Pass |
  | `lowest-cost`, a first deployment's month (T4's restart counted for the rest of the month) | $312.21 | $315.82 | $375, Pass |
  | `demo-day`, a 5-hour session | $14.75 | $16.56 | $15, a Warning |
  | The owner's kind of configuration (Defender plans, private network), a month with T4's restart | | $357.18; $363.58 with a golden snapshot's estimate | $375, Pass |

- **The session ceiling stays $15** (the owner's decision, 2026-11-13). `demo-day`'s session is then over it by the replica's share: `PREFLIGHT.COST.SESSION` is a **Warning** that names the share and `-SkipT4Replica`, as the session ceiling always was. **T4's one-time move to `Standard_D4ds_v5`** ([ADR 0019](0019-t4-postgresql-flexible-server.md)) is still decided on the session and month without the replica's share, so the replica never defers it for a configuration that had it before.
- **When a session isn't stopped,** the safety stop stops the replica that night; `status.ps1` then counts it like T4: storage and Defender while it's there, and its restart, until `stop-demo.ps1` deletes it.

## Consequences

- **Easier:** Database Hub's Read replica lag has data in every session, and the `replica-lag` beat makes it climb on purpose; nothing bills between sessions; existing users get the replica from `./scripts/deploy.ps1`.
- **Harder:** each `start-demo.ps1` waits about 9 minutes more for the replica, unless the warm-up covers it; a capacity refusal can come at a session's start; the replica's Azure Monitor history ends when it's deleted, so the history keeps what `stop-demo.ps1 -SaveHistory` captured first.
- **Accepted risks:** a session that ends without `stop-demo.ps1` and without the safety stop's role leaves the replica running until the next `stop-demo.ps1`, as it would T4; whether Azure's own 7-day start brings up a stopped replica before T4 isn't documented.

## Validation

- Static: Bicep build, Pester (`tests/unit/DbHubDemo.T4Replica.Tests.ps1` and the cost, preflight, lifecycle, tracks, safety stop, and control tests), and the runner's tests.
- **Live (West US 3, 2026-11-13 and 14):**
  - **New environment:** a new deployment ended DONE with the replica, which DONE's gate created at T4's `Standard_D4ds_v5` in 563 seconds.
  - **Older environment:** one that `main` deployed got the replica from `deploy.ps1`.
  - **A session:** `start-demo.ps1` started a stopped replica before T4, and `replica-lag` made Read Replica Lag climb to 218 seconds and drop, twice. `stop-demo.ps1 -SaveHistory` read the metrics before it deleted the replica, and the lakehouse history kept the climb.
  - **The safety stop:** its 19:30 pass stopped T4, then the replica.
- **Not yet live:** the replica's size fallback (Azure took every size asked), and the replica's own Estate row and Read replica lag chart on Database Hub's pages, which only a person sees.

## Sources

Checked 2026-11-13: [read replicas](https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas), [create a read replica](https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica), [stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server), [monitor PostgreSQL in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor-postgresql), [flexibleServers 2025-08-01 template reference](https://learn.microsoft.com/azure/templates/microsoft.dbforpostgresql/2025-08-01/flexibleservers), [capacity errors](https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-resolve-capacity-errors), [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), [hot standby](https://www.postgresql.org/docs/current/hot-standby.html).
