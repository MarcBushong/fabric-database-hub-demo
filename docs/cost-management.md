# Cost management

The demo's Azure resources cost about $3 an hour while they run and about $43 a month while they're stopped, at list prices before your subscription's Defender for Cloud plans, and preflight holds the month under a hard ceiling, `monthlyCeilingUsd` ($415 for a new configuration; a configuration keeps its own value), and warns above `sessionCeilingUsd` ($20 a session). No price is hard-coded: `./scripts/estimate-cost.ps1`, preflight, and `start-demo.ps1` price everything at run time from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), so every figure here is a dated example ([ADR 0016](adr/0016-cost-profiles.md)).

## At a glance

Dated example: list prices in USD for West US 3 on 2026-11-19, for the example configuration (`lowest-cost`, private mode), before any free offer or free tier. It's the estimator's own breakdown, which `./scripts/estimate-cost.ps1 -Detailed` prints.

### What each part costs

Without Defender for Cloud:

| Part | While it runs, an hour | While it's stopped, a month |
|---|---|---|
| T1 `sqlvm01`: the VM and its SQL Server Standard license | $0.59 | $9.60, its disk |
| T2 `archost01`: the host VM, and SQL Server Standard pay-as-you-go through Azure Arc (4 cores) | $0.62 | $9.60, its disk |
| T3: Azure SQL Database serverless, priced at its maximum 2 vCores | $1.04 | $11.48: storage, and in private mode its private endpoint and DNS zone |
| T4: Azure Database for PostgreSQL flexible server, `Standard_D4ds_v5` | $0.36 | $4.18: storage and its DNS zone |
| T4's read replica, during a session only | $0.36 | Nothing: it's deleted |
| T5's container (400 RU/s), during a session only | $0.03 | $7.80: the account's private endpoint and DNS zone |
| Ask's chat relay, only while someone uses the chat | $0.11 | Nothing: it scales to zero |
| The session control and the nightly safety stop | Nothing | $0.03 in vault operations (their job minutes fit in the 500 free) |
| **Total** | **$3.11** | **$42.69** |
| Bastion, only with `start-demo.ps1 -Interactive` | $0.20 | Nothing: `stop-demo.ps1` removes it |

The estimate counts T3 at its maximum and Ask's relay for every running hour, so the running hour is an upper bound.

**Defender for Cloud is outside the demo's control:** the plans your subscription has bill for the demo's resources whether you want them or not, and nothing in the demo turns them on or off. Signed in, `estimate-cost.ps1` and preflight add the ones your subscription has ([Defender for Cloud](#microsoft-defender-for-cloud)). For example, an internal subscription's six plans (Defender for Servers P2, SQL servers on machines, Azure SQL, open-source relational databases, CSPM, and Azure Cosmos DB) add $39.94 a month whether the demo runs or not, plus about $0.15 a running hour.

### Sessions and months to quote

| Case | Without Defender for Cloud | With an internal subscription's six Defender plans |
|---|---|---|
| Running, an hour | $3.11 | $3.25 |
| A Run all session: 90 minutes, about 2 billed hours | $6.21 | $6.51 |
| A `start-demo.ps1` session left running until its auto-stop, 4 hours by default (`-Hours`) | $12.43 | $13.01 |
| The 5-hour session preflight checks against `sessionCeilingUsd` | $15.53 | $16.27 |
| A light-use month: stopped, plus 10 running hours | $73.76 | $115.16 |
| A month stopped | $42.69 | $82.63 |

A Run all session bills about 2 hours: the VMs start a few minutes after the request, the showcase runs 90 minutes by default (`DURATION_MINUTES`, 30 to 120), and its auto-stop comes 10 minutes after its end. T3 bills from its first connection until it pauses, `t3AutoPauseMinutes` (15) after its last session. A 60-minute baseline run the day before, for Database Hub's **CPU spikes** ([the baseline run](database-hub-visuals.md#the-baseline-run-why-it-matters-and-when-it-doesnt)), bills about 1.4 hours.

**The two automatic stops** (since 2026-11-19; [what stops](#what-stops-or-pauses-on-its-own)): an update that found the demo stopped stops what it started at its end, where it used to bill until the 19:00 nightly stop, about $21 for an update that ended at 11:00 (8 hours at $2.64, the hour an update leaves running, without T4's read replica and Ask's relay); and a forgotten `start-demo.ps1` session stops after 4 hours, $12.43, where it used to run until 19:00, up to about $31. A new deployment keeps running, so you can look at it, and **DONE** says what it bills an hour and until when. `deploy.ps1 -KeepRunning` and `start-demo.ps1 -Hours` change them (dated example: list prices in USD for West US 3 on 2026-11-19, without Defender for Cloud).

### How long each part runs, and what stops it

| Part | Runs | Stopped or deleted by |
|---|---|---|
| T1, T2, and T4 | During a session (a Run all session's 90 minutes or so, a `start-demo.ps1` session's 4 hours by default) and a `deploy.ps1` run | The session's auto-stop, `stop-demo.ps1`, and each evening at `autoShutdownTime` (19:00): the VMs' auto-shutdown (T1 and T2) and the nightly safety stop (all three) |
| T3 | While the demo's activity keeps it awake | Azure pauses it `t3AutoPauseMinutes` (15) after its last session |
| T4, after a stop | Azure starts it again 7 days after a stop | The nightly safety stop, within a day |
| T4's read replica | Only during a session, and during a `deploy.ps1` run for its checks | The session's auto-stop, `stop-demo.ps1`, and the end of `deploy.ps1` delete it; the nightly safety stop stops a left-over one |
| T5's container | During a session or a `deploy.ps1` run: `start-demo.ps1`, Run all, and `deploy.ps1` create it | The session's auto-stop, `stop-demo.ps1`, and the nightly safety stop delete it, once its lifecycle is Session ([T5](#t5-azure-cosmos-db-2026-11-18)) |
| Ask's chat relay | While someone uses the chat | It scales to zero about 10 minutes after the last question |
| An update | `deploy.ps1` starts what it needs | When the demo was stopped as the run began, it stops again what the run started once **DONE**'s checks are done (`DEPLOY.ENDSTOP`; `-KeepRunning` keeps it running) |

[What stops or pauses on its own](#what-stops-or-pauses-on-its-own) lists every schedule, with its time.

### The month's worst case

Preflight compares the light-use month plus T4's 7-day automatic restart with `monthlyCeilingUsd`, and prints the total ([the monthly check](#ceilings-and-the-monthly-check)). With an internal subscription's six Defender plans:

| Deployment | Worst case | Against its ceiling | Why |
|---|---|---|---|
| An Owner's new deployment | $149.34 | $265.66 under $415 | It sets up the nightly safety stop, so each of T4's restarts counts about a day, and T5's container only the running hours |
| A Contributor's new deployment | $398.23 | $16.77 under $415 | Until an Owner runs `./scripts/grant-safety-stop.ps1` once, T4's restart counts the rest of the month, and T5's container all month, because only `stop-demo.ps1` deletes it |
| An Owner's update of a demo whose ceiling is $250 | $149.34 | $100.66 under $250 | As an Owner's new deployment |

Without Defender for Cloud, the same new deployments come to $107.94 (an Owner's) and $353.36 (a Contributor's).

### Not included

- **Your Fabric capacity,** which runs the notebooks, Run all, the dashboards, the report, and the Insights app. You or its administrator resume and pause it ([Fabric capacity](#microsoft-fabric-capacity)). Database Hub itself needs none.
- **Fabric and Power BI licenses,** such as viewers' Pro or PPU licenses for Power BI content on a capacity smaller than F64 (P11).
- **Each viewer's GitHub Copilot plan,** which Ask's questions use.
- **Your subscription's Defender for Cloud plans,** except where `estimate-cost.ps1` and preflight read them (above).
- **A T2 golden snapshot,** only if you capture one to speed up a redeploy: it bills every month, after `destroy.ps1` too, until `destroy.ps1 -IncludeGolden` deletes it ([the golden snapshot](#the-t2-golden-snapshot-phase-20)).
- **Taxes, support plans, and your agreement's discounts or credits:** these are list prices.
- **GitHub:** nothing. You never run GitHub Actions; the image Ask's relay runs is public and pinned by digest.

## Run an estimate

```powershell
./scripts/estimate-cost.ps1 -AllProfiles -Detailed
./scripts/estimate-cost.ps1 -NetworkMode private   # the mode preflight resolved
```

Without switches it prices the configured profile from `config/demo.config.json` (the example configuration when there's none), and it changes nothing. It prints the running hour, a session, the idle month, and the light-use month, then "The monthly check": the worst case, the ceiling, the margin, and what it counted. A worst case above `monthlyCeilingUsd` is a **Fail**, and it exits with code 1.

- **Not signed in,** it needs nothing (the Retail Prices API is public), but it can't read your Defender plans (`PREFLIGHT.COST.DEFENDER` is a **Warning**), the T3 free offer, T5's free tier, or the nightly safety stop: it prices T3 as regular serverless and T5 at list price, and counts T4's restart for the rest of the month. Dated example (2026-11-19, the example configuration, so without Defender for Cloud): $15.53 a session, $73.76 a light-use month, and a worst case of $330.08.
- **Signed in** to the configured subscription (you run `az login`; it never signs in), it reads them too (`az security pricing list`, read-only), and prices an environment that doesn't exist yet as `deploy.ps1`'s preflight will price your first run, from read-only reads of your permissions, saying what it assumed. Dated example (2026-11-19, an internal subscription's six Defender plans, as an Owner with no environment yet): $16.27 a session (of which Defender $0.73), $115.16 a light-use month (of which Defender $41.40), and a worst case of $149.34, the figure preflight then checks.
- **Switches:** `-AllProfiles` or `-ProfileName`; `-DemoHours` and `-LightUseHoursPerMonth` (5 and 10, from `config/profiles.json`); `-BastionHours` (0: only `start-demo.ps1 -Interactive` deploys Bastion); `-NetworkMode` `public` or `private`, the `effectiveNetworkMode` evidence of `PREFLIGHT.POLICY.SQLPUBLIC` (with `networkMode` `auto` and no `-NetworkMode`, it assumes private, the more expensive mode); `-T5ContainerLifecycle` `Session` or `AlwaysOn`; `-Detailed`; `-ConfigPath`; and `-OutputPath`. It prices `t4SkuName`, or `Standard_D4ds_v5`, not the size T4's fallback recorded, which `deploy.ps1`'s preflight and `start-demo.ps1`'s guardrail price; to price another size, use a copy of the configuration that sets `t4SkuName`.

## Ceilings and the monthly check

- **`monthlyCeilingUsd` is hard:** preflight, `start-demo.ps1`'s guardrail, and `estimate-cost.ps1` compare the month's worst case, the light-use month plus T4's 7-day automatic restart, with it, and above it is a **Fail** (`PREFLIGHT.COST.MONTHLY`, `START.COST.*`). The message gives the total, the ceiling, the margin, and what it counted: T4's restart hours, and T5's container for the running hours (`Session`) or all month (`AlwaysOn`); no Bastion hour, except the Bastion that `start-demo.ps1 -Interactive` deploys. `init.ps1` writes 415 for a new configuration, and a value already in a configuration never changes. The Azure budget follows it, with alerts at 50%, 80%, and 100%; `./scripts/deploy.ps1 -FromStage Infrastructure` updates the budget after a change.
- **`sessionCeilingUsd`, $20 by default, is a Warning** (`PREFLIGHT.COST.SESSION`), never a **Fail**. A configuration that still says 15 gets 20, and `deploy.ps1` says so in one line.
- **T4's restart:** Azure starts a stopped flexible server again after 7 days. With a safety stop [fully in place](#dated-example-the-nightly-safety-stop-2026-11-05), each restart counts as about a day: at most 4 a month, 96 hours, $34.18 at `Standard_D4ds_v5`. Otherwise it's the rest of the month, 720 hours, $256.32 (compute at 2026-11-19 list prices, West US 3; no Defender plan bills it by the hour), with a **Warning** that names the missing piece and its fix, `./scripts/deploy.ps1` or an Owner's `./scripts/grant-safety-stop.ps1`; a read that fails counts as missing. A first deployment's preflight counts the safety stop that the run sets up when you can assign its role (an Owner: `PREFLIGHT.COST.T4RESTART` is a **Pass** that says so); if the run then doesn't put it in place, `DEPLOY.COST.T4RESTART` is a **Warning** with the worst case without it and the fix. T5's container is priced as the run will record it ([T5](#t5-azure-cosmos-db-2026-11-18)).
- **Once the month's actual cost reaches the ceiling,** `start-demo.ps1` stops starting the demo (`START.COST.ACTUAL` **Fail**) until the next month, unless you raise the ceiling or pass `-SkipCostCheck`; `status.ps1` shows the month-to-date spend.
- **To clear a monthly Fail:** raise `monthlyCeilingUsd` to the amount it names, choose a cheaper profile, or set a smaller `t4SkuName`, such as Burstable `Standard_B1ms`, which has no autonomous tuning ($0.017 an hour, and a restart worst case of about $12 a month, at 2026-11-04 list prices). Only a T4 size you didn't choose makes it a **Warning** instead: one the fallback chose because Azure refused your `t4SkuName`, when your size would fit; or T4's default with `monthlyCeilingUsd` at exactly 250 (`init.ps1`'s default from 2026-10-27 to 2026-11-04), when `Standard_B1ms` would fit. The budget keeps alerting at the configured value.
- **To stay cheap,** stop the demo between sessions (`./scripts/stop-demo.ps1`). Every default is the cheapest option that works, except T4's size, for autonomous tuning ([T4](#azure-database-for-postgresql-t4)).

## What stops or pauses on its own

Everything below runs with no person and no command. Times are the defaults: `autoShutdownTime` 19:00 in `autoShutdownTimeZone`, Pacific Standard Time.

| What | When | What it does | Set up by |
|---|---|---|---|
| The VMs' auto-shutdown (DevTest Labs schedules `shutdown-computevm-<vm>`) | Daily at `autoShutdownTime`: 19:00 | Shuts down and deallocates `sqlvm01` (T1) and `archost01` (T2's host); the T2 guest stops with its host | The template (`deploy.ps1`); `validate.ps1` checks it (`COST.AUTOSHUTDOWN`) |
| The nightly safety stop (schedule `dbhub-safety-stop`, `DbHub-Stop -Scope Nightly`) | Daily at the same time: 19:00 | Backs up the auto-shutdown: deallocates each VM that isn't deallocated or deallocating, including one kept running or stopped only from inside, and stops T4 when it runs (after Azure's 7-day restart too), waiting up to 10 minutes for one that's starting. Then it stops a read replica a session left behind (after T4, as Azure requires) and deletes T5's container when a session's stop didn't and its lifecycle is Session. It never starts anything, deletes nothing else, never connects to a database, and never uses Run Command | `deploy.ps1`, on every run ([ADR 0024](adr/0024-nightly-safety-stop.md)); it acts once its role is assigned (P16) |
| Its T3 check (schedule `dbhub-safety-t3check`, `-Scope T3Check`) | Daily 30 minutes later, 19:30, or T3's auto-pause delay plus 15 minutes when that's longer | Reads T3's status through Azure Resource Manager, which doesn't wake it, and reports in `status.ps1` when it isn't paused (Azure has no "pause now" for serverless). Then it stops T4 and a left-over replica when T4 runs, so a T4 that Azure restarted just after the stop doesn't run until the next evening | The same |
| A run's deferred stop (schedule `dbhub-safety-deferred`, `-Scope Nightly`), only on a night the stop waited for a `deploy.ps1` | Hourly from 65 minutes after the run ended until the next morning | Stops the demo as the nightly stop does, once no run keeps it busy; the VMs' auto-shutdown is set to its first time for that night | `deploy.ps1` |
| T3's auto-pause | `t3AutoPauseMinutes` after its last session: 15 minutes by default | Azure pauses the serverless database, which then bills only its storage; the first connection resumes it | The template |
| The activity profiles and incidents | Each profile ends 2 minutes before the next auto-shutdown; each incident at its hard maximum | The workload stops, so T3 can pause | `deploy.ps1`, `start-demo.ps1`, `demo-control.ps1` |
| A notebook run's auto-stop (schedule `dbhub-autostop`; the session control) | The run's end plus 10 minutes; for a Run all session, a backup (`dbhub-autostop-backup`) 30 minutes later, which runs only when the first one's job failed | Saves a session's metrics, deallocates the VMs, deletes T4's read replica and, when its lifecycle is Session, T5's container, and stops T4, as **Stop now** does | The control's runbook, for each run |
| A `start-demo.ps1` session's auto-stop (the same `dbhub-autostop`, marked `[start-demo.ps1]`, with its backup; since 2026-11-19) | 4 hours after `start-demo.ps1` (`-Hours`, 0.5 to 24), or after the warm-up it waits for; running it again starts the hours over | The same as a notebook run's. A later Run all or the Insights app's **Start** replaces it with its own plan, `stop-demo.ps1` removes it, and it moves past a `deploy.ps1` that's still running. Without the session control's role at the demo resource group (A1) it isn't scheduled: `START.CONTROL.AUTOSTOP` is a **Warning** with the grant, and the nightly stop is the limit | `start-demo.ps1`, for each session (`Register-DemoActivityControlAutoStop`) |
| The control's daily T4 safety stop (schedule `dbhub-t4-safety-stop`) | Daily 15 minutes after `autoShutdownTime`, 19:15, or at `control.t4SafetyStopTime` | Stops T4 when it runs, then a left-over read replica; while `sqlvm01` doesn't run, it also deletes T5's container when its lifecycle is Session, a fallback for a night the nightly safety stop couldn't | `deploy.ps1`, with the session control, on every run |
| The end of a `deploy.ps1` update (since 2026-11-19) | Once **DONE**'s checks and the history snapshot are done | When the demo was stopped as the run began, stops again what the run started, through `stop-demo.ps1`'s stop without the history save or the capacity pause (`DEPLOY.ENDSTOP`, the status page's **Stop at the end** row). A new deployment, a demo that was running, a session that uses it, and `-KeepRunning` keep it running, and **DONE** says what bills an hour and until when | `deploy.ps1` (`Invoke-DemoUpdateEndStop`) |
| On-demand Bastion | Removed by every `stop-demo.ps1`, and by `deploy.ps1` when an earlier session left it; otherwise `bastionMaxHours` (4) after it was created, but only with the `bastion-cleanup` workflow below | Deletes Bastion and its public IP, and rotates the T2 host's password | `stop-demo.ps1`, `deploy.ps1` |
| Optional GitHub schedules, off unless the repository variable `DBHUB_SCHEDULES_ENABLED` is `true` (cron in UTC; edit it for your time zone) | `schedule-stop` daily at 01:00 UTC; `bastion-cleanup` hourly at :10; `expiry` daily at 06:30 UTC | `schedule-stop` runs `stop-demo.ps1` (Bastion, the profiles, the guest, both VMs, and T4); `bastion-cleanup` removes an expired Bastion; `expiry` runs `destroy.ps1` once the resource group's `expiresOn` has passed | The workflows in `.github/workflows` |

- **Nothing in this list starts anything.** Only Azure starts a stopped T4 again, 7 days after a stop, and the nightly safety stop stops it within a day: its T3 check that evening, or else the next evening's stop. The optional `schedule-start` workflow starts a session (weekdays at 15:15 UTC, when enabled), which its auto-stop then ends 4 hours after its warm-up.
- **A `deploy.ps1` that's still running isn't cut off:** it marks the demo resource group busy (`DbHubBusyUntilUtc`, at most 3 hours ahead, moved on every 10 minutes), so the nightly stops change nothing, and the VMs' auto-shutdown moves past the run. When the run ends after the stop's time, the demo stops 60 minutes later, and **DONE** and the status page say when (`DEPLOY.NIGHTLYSTOP`): `./scripts/start-demo.ps1` keeps it running that night, and `./scripts/stop-demo.ps1` stops it at once. An abandoned run stops being marked within an hour, so the demo is still stopped that night ([ADR 0024](adr/0024-nightly-safety-stop.md#amendment-the-busy-marker-so-the-nightly-stop-doesnt-cut-off-a-run-2026-11-14)). A `start-demo.ps1` session isn't marked: one still going at the stop's time is stopped, though since 2026-11-19 it stops by itself after its hours anyway.
- **To skip one night:** turn off the `dbhub-safety-stop` and `dbhub-safety-t3check` schedules (the T3 check stops T4 too) in `aa-<prefix>-<env>-safetystop` (Shared Resources > Schedules), `dbhub-safety-deferred` when a run left one, and the VMs' auto-shutdown in the Azure portal. The next `./scripts/deploy.ps1` turns the safety stop on again.
- **Where to see it:** `./scripts/status.ps1` (`STATUS.SAFETYSTOP`: its times, role, last stop, and last T3 check; `STATUS.NIGHTLYSTOP`: a run it waits for, the deferred stop, and a moved auto-shutdown) and the jobs in `aa-<prefix>-<env>-safetystop` > Process Automation > Jobs. The Fabric capacity isn't in this list: you or its administrator pause it.

## Azure SQL (T3): free offer and lifecycle

- **Two vCores:** `lowest-cost`'s T3 is serverless at 0.5 to 2 vCores, because Database Agents doesn't support one-vCore serverless databases ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents#supported-databases-and-servers)). Serverless bills the vCore-seconds it uses, never above the maximum ([serverless compute tier](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-overview)), and the estimate prices the maximum for every running hour. A T3 that still has 1 vCore gets 2 online at the next `./scripts/deploy.ps1`, which drops its connections for a few seconds; until then `validate.ps1`'s `T3.DATABASE` is a **Warning**, and Database Agents can't use T3.
- **Free offer:** by default (`t3FreeOffer: auto`), T3 uses the [Azure SQL Database free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer) with "continue using database for additional charges", so it never pauses for the limit and keeps the offer when it scales within General Purpose ([free tier FAQ](https://learn.microsoft.com/azure/azure-sql/database/free-tier-faq)). Preflight checks that it's available (`PREFLIGHT.T3.FREEOFFER`); when it isn't, for example because the subscription's first free database fixed the offer in another region, T3 is regular serverless. Its 100,000 vCore-seconds a month cover about 14 hours at 2 vCores: a light-use month uses 72,000 and a Run all session about 13,000. Past them, T3 bills at the serverless rate and stays available (`BillOverUsage`).
- **While T3 exists,** its storage, and in private mode its private endpoint and DNS zone, bill all month, paused or not, and so do Defender for Azure SQL and Defender CSPM where they're on. `./scripts/stop-demo.ps1 -RemoveT3` stops that between demos; the next `start-demo.ps1` or warm-up creates T3 again with the same names and checks its telemetry first. Keep T3 for Database Agents and multi-day demos: a new T3 can show Database Hub's posture findings and Database Agents' findings late.

## Activity profiles: business-day (Phase 28 follow-up)

`business-day`, the default activity profile ([ADR 0010](adr/0010-workload-generator-technology.md#activity-profiles-business-day-by-default-2026-11-03)), adds nothing to the estimate. Only T3's bill follows the load: its two incidents an hour, `resource-governance` at :15 and `log-rate-pressure` at :45, 5 minutes each, drive it to its maximum vCores, which the estimate already prices for every running hour (`t3ActiveShareOfMaxVcores` 1.0 in `config/profiles.json`). Everything else bills by the running hour, whatever the load.

- **The checks say so:** `PREFLIGHT.COST.SESSION` and `PREFLIGHT.COST.MONTHLY` ("they add nothing", with `activityProfile`, its source, and the increment in their evidence), `start-demo.ps1`'s `START.COST.*` (with its `-ActivityProfile`), and `estimate-cost.ps1` use the configured profile, or `business-day` for a configuration without `activityProfile`, which the run says once (`*.ACTIVITYPROFILE`). With a lower share, a component "T3 compute, business-day incidents" adds the incidents' 10 minutes an hour at the maximum, for the part of the hour the share leaves out.
- **What no estimate counts:** T3 between its minimum and maximum vCores, T2's Standard SSD disk operations under `io-pressure`, billed up to an hourly cap ([Standard SSD transactions](https://learn.microsoft.com/azure/virtual-machines/disks-types#standard-ssd-transactions)), and T3's log backups, within the free backup storage of its 32 GB maximum size ([backup storage costs](https://learn.microsoft.com/azure/azure-sql/database/automated-backups-overview#backup-storage-costs)): at most $0.94 a session and $1.88 a light-use month with the 2-vCore T3 (list prices, West US 3, 2026-11-03; no Defender plan bills them). A profile ends 2 minutes before the next auto-shutdown, and `stop-demo.ps1` turns every profile off, so T3 can pause.

## Azure Database for PostgreSQL (T4)

T4 is General Purpose `Standard_D4ds_v5` (4 vCores) by default, the smallest size for autonomous tuning, in every deployment (`t4Enabled: false` is ignored); its sizes and fallback are in [deployment](deployment.md#t4s-size-the-4-vcore-default-and-its-fallback-2026-11-04) ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)). `estimate-cost.ps1`, preflight, and `start-demo.ps1`'s guardrail price the configured or recorded size at run time. Dated examples, list prices in USD for West US 3:

| Part | Billed | Example |
|---|---|---|
| Compute, `Standard_D4ds_v5` (the default) or `Standard_D4ads_v5` (the 4-vCore fallback) | Only while it runs | $0.356 an hour, 4 vCores at $0.089 (2026-11-19; the fallback's on 2026-11-03) |
| Compute, `Standard_D2ds_v5` (the last fallback, tuning off) | Only while it runs | $0.178 an hour (2026-11-03) |
| Compute, `Standard_B1ms` or `Standard_B2s` (Burstable, set with `t4SkuName`; tuning off) | Only while it runs | $0.017 and $0.068 an hour (2026-10-26) |
| Storage (32 GiB) and its private DNS zone | All month, stopped or not | $3.68 and $0.50 a month (2026-11-19) |
| Backup storage | Free up to the provisioned size (7-day retention, no geo-redundancy) | $0 |
| Defender for open-source relational databases and Defender CSPM, where they're on | All month, stopped or not | $15 and $5.11 a month (2026-11-19) |

- **The 7-day restart:** a stopped flexible server starts on its own after seven days ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server): "Server will be automatically started after 7 days"; the [overview](https://learn.microsoft.com/azure/postgresql/overview)) and bills compute until it's stopped again, which [the monthly check](#ceilings-and-the-monthly-check) counts. `stop-demo.ps1` (`STOP.T4.STOP`) and `status.ps1` (`STATUS.T4`, which warns a day ahead) say when it starts, what it then bills, and what stops it: the nightly safety stop, else the control's daily safety stop (`CONTROL.SAFETYSTOP`), else nothing, with the fix (its role, through `./scripts/grant-safety-stop.ps1`, or `./scripts/deploy.ps1`) and `stop-demo.ps1` again once it has started.
- **Every automatic size change is priced first:** the fallback when Azure refuses T4's size ([its cost check](#the-general-purpose-fallbacks-cost-check-phase-28-follow-up); `DEPLOY.T4.FALLBACK` and `STATUS.T4.SIZE` give the monthly estimate at both sizes, with the difference), an older server's one move to the default (`PREFLIGHT.T4.SIZE`, `DEPLOY.T4.SIZE`), a larger `t4SkuName` on an existing server, and T4's creation on a run that skips preflight (`deploy.ps1 -FromStage Infrastructure`, or a resume). Over a ceiling, or without a price, `DEPLOY.T4.SIZE` is a **Warning** that names the ceiling to raise and the next cheaper `t4SkuName`; an existing server keeps its size, and a new one is created anyway.
- **A server deleted by hand comes back** at the next `deploy.ps1`; only `destroy.ps1` removes T4, with the group. When Azure refuses every size, the run ends **NOT DONE**, and T4's private DNS zone and virtual network link stay, about $0.50 a month, until T4 is created or the group is deleted ([cleanup](cleanup.md)).

### The General Purpose fallback's cost check (Phase 28 follow-up)

When `t4SkuName` isn't set and Azure refuses both 4-vCore sizes (`Standard_D4ds_v5`, in another zone too, and `Standard_D4ads_v5`), `deploy.ps1` prices `Standard_D2ds_v5`, with autonomous tuning off, right before it creates it, from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) at that moment ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md#2026-11-02-the-general-purpose-fallback-phase-28-follow-up)):

- **What it checks:** the month at that size, with T4's restart worst case, storage, DNS zone, and, where they're on Standard (`PREFLIGHT.POLICY.DEFENDER`), its Defender plans, against `monthlyCeilingUsd`, and a session against `sessionCeilingUsd`. What has no price, and Defender plans that couldn't be read, are named and left out.
- **Over a ceiling, or no price,** T4 is created anyway, as part of every deployment, and `DEPLOY.T4.SKU` is a **Warning** that names the ceiling and the value to raise it to. Within both, the console, the status page, and **DONE** say T4 is `Standard_D2ds_v5`, with autonomous tuning off, and give its hourly price; they say "created" only once the server exists. After a rejected T3 free offer, the check runs again without the offer's allowance, and a server the rejected attempt already created keeps its size.
- **Preflight prices it ahead** (`PREFLIGHT.T4.FALLBACK`): a **Pass** when it would fit, otherwise a **Warning** that the fallback would still create T4. When the fallback starts there (a record, which only `deploy.ps1`'s preflight reads, or a region that lists neither 4-vCore size, `PREFLIGHT.T4.CAPABILITY`), the run's own `PREFLIGHT.COST.*` price T4 at that size; when its price can't be read, it's a **Warning** (`skipReason` `Price`), and the run's own `PREFLIGHT.COST.*` stand, a monthly **Fail** included.

## Dated example: T4's read replica (2026-11-13)

T4's read replica, `pgreplica01-<deploymentId>`, exists only during a session and a `deploy.ps1` run ([ADR 0025](adr/0025-t4-read-replica.md); [in the deployment](deployment.md#t4s-read-replica-in-the-deployment-2026-11-13)): the session's auto-stop, `stop-demo.ps1`, and the end of `deploy.ps1` (`DEPLOY.T4.REPLICA.END`) delete it, so it bills nothing between sessions and has no 7-day restart.

- **In the estimate,** it's in the running hours: compute at T4's size, its 32 GiB of storage by the hour, and, where they're on, Defender for open-source relational databases and Defender CSPM by the hour: $0.36 a running hour without Defender for Cloud (2026-11-19, [At a glance](#at-a-glance)). `estimate-cost.ps1`'s **Replica session** column and `PREFLIGHT.COST.SESSION` give its share, and `./scripts/start-demo.ps1 -SkipT4Replica` starts a session without it; T4's own size decisions leave its share out. On a larger size, `START.T4.REPLICA.FALLBACK` or `DEPLOY.T4.REPLICA.FALLBACK` gives both hourly prices.
- **A session that isn't stopped:** the nightly safety stop stops the replica after T4 but can't delete it, so it bills its storage and Defender plans until `./scripts/stop-demo.ps1` or `./scripts/deploy.ps1` deletes it, which the estimate doesn't count; `status.ps1` reports it as a **Warning** with that command. A Burstable T4 has no replica (`DEPLOY.T4.REPLICA` is **Not supported**). [ADR 0025](adr/0025-t4-read-replica.md#considered-options) has the 2026-11-13 figures and the persistent replica the design rejected.

## T5: Azure Cosmos DB (2026-11-18)

T5, the Azure Cosmos DB for NoSQL account `cosmos01-<deploymentId>` ([ADR 0027](adr/0027-t5-cosmos-db.md)), can't be stopped or paused, and a container's provisioned throughput can't be taken away, only deleted with the container. So its container, `patient-events` in the database `contosocare`, exists only during a session: `start-demo.ps1` and Run all create it, and `stop-demo.ps1`, the session's auto-stop, and the nightly safety stop delete it. The account, the database (no throughput of its own), the private endpoint, and the DNS zone stay, so Database Hub keeps T5 in its estate; `validate.ps1 -Area Cost` prices T5 too. List prices in USD for West US 3 on 2026-11-19:

| Part | Billed | Example |
|---|---|---|
| Throughput, 400 RU/s manual (`Azure Cosmos DB / RUs / 100 RU/s`) | Each clock hour, or part of one, that the container exists ([understand your bill](https://learn.microsoft.com/azure/cosmos-db/understand-your-bill)) | $0.008 per 100 RU/s an hour: **$0.032 an hour**; **$0 on the free tier** |
| Storage, about 1 GB of bounded documents, which go with the container | By the hour, while the container exists | $0.25 a GB-month; $0 on the free tier, up to 25 GB |
| The private endpoint (both network modes) and its DNS zone `privatelink.documents.azure.com` | All month | $7.30 and $0.50 a month |
| Defender for Azure Cosmos DB, where a tenant policy turns it on (`CosmosDbs` on Standard) | Per 100 RU/s an hour while the container exists, free tier or not | $0.0012 per 100 RU/s an hour: $0.0048 an hour |

So T5 costs **$7.80 a month while the demo is stopped**, free tier or not, with Defender for Cloud or without (Defender CSPM doesn't bill Azure Cosmos DB accounts, and periodic backup's two copies are free), and $0.032 a running hour at list price, plus $0.0048 with Defender for Azure Cosmos DB. The estimate counts the first in the idle month (`T5FixedMonthly`) and the second in the running hours (`T5RunningHourly`), not the extra clock hour a session can touch. Throttling costs nothing extra: `ru-storm` uses the 400 RU/s it has, and requests rate-limited with 429 aren't billed beyond it.

- **The container's lifecycle,** on the demo resource group's `DbHubT5Container` tag (`DEPLOY.T5.LIFECYCLE` says which, and why):
  - **Session** once the session control's role can create the container: an Owner's `./scripts/deploy.ps1` gives it that, or an Owner's `./scripts/grant-safety-stop.ps1` once. Also while the session control has no role at all (a Contributor's deployment): Run all can't start a session then, `start-demo.ps1` creates the container with your own rights, and only `stop-demo.ps1` deletes it unless the nightly safety stop's role has the container's actions, so the estimate prices it all month, and `DEPLOY.T5.LIFECYCLE` is a **Warning** that says to run `stop-demo.ps1` after each session.
  - **AlwaysOn** while the session control holds a role without the container's actions (an update by someone who isn't an Owner): no stop deletes the container, and it bills all month. An environment deployed before 2026-11-19 keeps its container until its next `./scripts/deploy.ps1`.
  - Preflight prices what its run will record, and `PREFLIGHT.COST.MONTHLY` says what the other would add (`T5AlwaysOnExtraMonthly`); when the run records AlwaysOn after all, `DEPLOY.T5.LIFECYCLE` gives the worst case again. `estimate-cost.ps1 -T5ContainerLifecycle AlwaysOn` prices the other case.
- **The free tier:** the first 1000 RU/s and 25 GB of one account per subscription, free while the account exists ([free tier](https://learn.microsoft.com/azure/cosmos-db/free-tier)). Azure sets it only when an account is created, and not for internal subscriptions ("Free tier is not supported for Internal subscriptions"), so `deploy.ps1` gives a new account the free tier when the subscription isn't internal and Azure Resource Graph lists no other account in it with the free tier (`DEPLOY.T5.FREETIER`); an existing account keeps what it has. Not signed in, the estimate prices list price, and says so.
- **To stop paying for it,** `./scripts/destroy.ps1` removes it all with the resource group. `t5Enabled: false` leaves T5 out of the next deployments, but an account an earlier run created bills until it's deleted. [ADR 0016](adr/0016-cost-profiles.md#2026-11-19-t5s-container-for-each-session) has the 2026-11-19 figures before and after the container's lifecycle.

## Dated example: Ask's chat relay (2026-11-18)

Ask, the Copilot chat in the Insights app, runs its relay in an Azure Container App in the demo resource group (`ca-<prefix>-<env>-ask`, in `cae-<prefix>-<env>-ask`): the Consumption plan, 1 vCPU and 2 GiB, 0 to 1 replica, with no dedicated profile, private endpoint, Log Analytics workspace, or Azure Container Registry ([ADR 0028](adr/0028-ask-copilot-in-the-insights-app.md)). The viewers' questions use their own GitHub Copilot plans.

- **It bills per second, only while a replica runs** ([billing](https://learn.microsoft.com/azure/container-apps/billing)): while a page has a conversation open (the page closes an idle one after 5 minutes, and the relay one with no message after 15), plus Container Apps' default 300-second cooldown, so until about 10 minutes after the last question. At $0.000024 per vCPU-second and $0.000003 per GiB-second (list prices, West US 3, 2026-11-19), that's **$0.108 an hour**, with no Defender plan; requests are $0.40 per million, which a demo doesn't reach.
- **The estimate** counts it for every running hour, an upper bound, and not in T4's restart worst case. It leaves out Container Apps' monthly free grant per subscription (the first 180,000 vCPU-seconds, 360,000 GiB-seconds, and 2 million requests, about 50 hours of the relay), which other apps may use.
- **To leave it out:** `"ask": { "enabled": false }` in `config/demo.config.json`, and the next `./scripts/deploy.ps1` doesn't deploy it. A relay deployed before stays scaled to zero, billing nothing, until `destroy.ps1` deletes it with the resource group.

## The session control

The session control behind **Run all** is part of every deployment ([ADR 0026](adr/0026-one-run-all-session.md)); `control.enabled: false` doesn't turn it off. Its resources in `rg-<prefix>-control` bill until `destroy.ps1` deletes them, or `setup-activity-control.ps1 -Remove` deletes the control alone. List prices in USD for West US 3, with no Defender plan counted:

- **Key Vault (Standard),** per 10,000 operations, for the webhook's URL and the session's status and metrics: one block a month in the estimate, $0.03 (2026-11-19).
- **Azure Automation (Basic),** per job minute after the 500 a month that are included. A session's `DbHub-Control` job takes 2 to 20 minutes and `DbHub-Stop` 1 to 3, so about 25 to 50 sessions a month fit; past them, about $0.04 a session (2026-11-03). The estimate prices 60 job minutes, $0.
- **No charge:** the webhook, the schedules, the identity, and the role assignments. Fabric's managed private endpoints and virtual networks have no separate meter; the control notebook uses the Fabric capacity like any notebook.

## Dated example: the nightly safety stop (2026-11-05)

The nightly safety stop, in every deployment ([ADR 0024](adr/0024-nightly-safety-stop.md)), deallocates both VMs and stops T4 at the VMs' auto-shutdown time, so a T4 that Azure starts again 7 days after a stop bills at most until that evening, and [the monthly check](#ceilings-and-the-monthly-check) counts each restart as about a day instead of the rest of the month.

- **Fully in place** means its schedule `dbhub-safety-stop` is enabled and linked to `DbHub-Stop` with Scope `Nightly`, its role "DbHub Demo Safety Stop" is assigned at `rg-<prefix>-<env>` (P16; the fix is `./scripts/grant-safety-stop.ps1`), and its last run didn't fail (`Get-DemoT4RestartCoverage`, read-only). The control's daily T4 safety stop counts too when its schedule `dbhub-t4-safety-stop` is enabled, the control identity's A1 role is assigned, and its last `DbHub-Stop` job didn't fail, as its own result line says: a job that ended `Partial` because Azure refused T4's stop doesn't count.
- **Its own cost:** two short Automation jobs a night, the stop and its T3 check, in `aa-<prefix>-<env>-safetystop`, about 2 to 4 job minutes. The estimate counts up to 120 job minutes a month, $0 within the 500 a month that Azure Automation includes ([pricing](https://azure.microsoft.com/pricing/details/automation/); rate plans with a flat discount or a fixed monthly credit don't include them). Its identity, account, schedules, and role have no charge. [ADR 0016](adr/0016-cost-profiles.md#2026-11-05-user-directed-the-nightly-safety-stop-caps-t4s-restart-by-default) has the 2026-11-05 figures for each profile, with it and without it.

## T2's JumpstartImage mode (2026-11-05)

T2's guest comes from Arc Jumpstart's prebuilt SQL Server 2022 Standard image by default ([ADR 0006](adr/0006-sql-editions-and-licensing.md)), with no new resource or meter (list prices in USD for West US 3, 2026-11-05). Its disk is a file on the T2 host's OS disk (`lowest-cost`: the E10 Standard SSD, $9.60 a month), or on its data disk in the larger profiles; the 34 GiB download is free ("Standard Data Transfer In", $0.00 per GB), and writing it is about 140,000 disk operations, about $0.03. SQL Server is Arc pay-as-you-go Standard in every mode but `Developer`: $0.10 per core-hour, with a minimum of four cores per operating system environment ([license billing](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing)), so $0.40 an hour for the 2-vCPU guest (`t2ArcBillableCores` overrides the count). The demo sets license type PAYG, which needs no entitlement, where Jumpstart's own automation sets Paid (Software Assurance). No deployment needs Bastion (Basic, $0.19 an hour, and its public IP, $0.005), which only `start-demo.ps1 -Interactive` deploys, for interactive access such as T2's missing-index fix; without a golden snapshot, a redeploy prepares the image again in about 27 minutes, with no person needed.

## The T2 golden snapshot (Phase 20)

Optional: one incremental snapshot of the T2 host's OS disk in `rg-<prefix>-golden`, which only speeds up a redeploy ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)). It bills every month it exists, also after `destroy.ps1`, until `destroy.ps1 -IncludeGolden` deletes it. Incremental snapshots are Standard HDD, billed for their used size ([incremental snapshots](https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots)), which only the usage report shows, so the estimate and the guardrails price the provisioned 128 GiB, an upper bound: at most about $6.40 a month at $0.05 per GB-month (list price, West US 3, 2026-11-05). A `JumpstartImage` host's snapshot also holds the image, an estimated 50 to 60 GiB used, about $2.50 to $3 a month (not measured). `status.ps1`'s month-to-date figure adds the golden group's actual cost.

## Microsoft Fabric capacity

The notebooks, Run all, the Real-Time Dashboard, the history report, and the Insights app need the workspace on an F or Trial capacity (P5); Database Hub itself doesn't ([licenses](https://learn.microsoft.com/fabric/enterprise/licenses)). The capacity is yours or its administrator's, often shared, and outside every estimate, budget, and ceiling. Dated example: an F16, 16 capacity units at $0.18 per capacity-unit hour (list price, West US 3, 2026-10-21), is about $2.88 an hour, about $2,100 for a month left running.

- **Resume it before a session, and pause it after:** at the pause, remaining overages and smoothed operations are billed, and "resuming your capacity also resumes billing" ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)). Run all never resumes it. With `fabric.manageCapacity`, for a capacity that's yours alone, `start-demo.ps1` resumes it and `stop-demo.ps1` pauses it; otherwise no script resumes, pauses, or scales one. While it's paused, notebook imports and runs report **Manual action required**.
- **What uses it:** the control notebook and its live view; every `deploy.ps1`, which checks the Insights app and, once **DONE**'s checks pass, runs `NB_DatabaseHub_LiveActivity` once, analyze-only, and refreshes the history model ([the snapshot](deployment.md#the-history-reports-snapshot-at-the-end-2026-11-06): 2 to 5 minutes of Spark, at most 10; on a paused capacity it's a **Warning**, and the run still ends **DONE**); and the Insights app, which has no database or storage: "Fabric Apps services consume capacity units from the assigned capacity" ([Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview)) while it's loaded and queried, Ask's queries included, when its live-estate function runs (its answer is kept 60 seconds), and when an operator uses Manage, whose sessions run `NB_DatabaseHub_Control` as Run all does.
- **Viewer licenses:** on F SKUs smaller than F64, every viewer of Power BI content needs Pro, Premium Per User, or an individual trial ([licenses](https://learn.microsoft.com/fabric/enterprise/licenses)); a presenter who shares their screen needs only their own ([permissions](permissions.md#presentation-surfaces-and-viewer-licensing)).

## Microsoft Defender for Cloud

Tenant policies can turn plans on; preflight reports that as `PREFLIGHT.POLICY.DEFENDER`, and [At a glance](#at-a-glance) has an internal subscription's total. Signed in, the estimate reads the plans and counts those on the Standard tier, on the billing basis Microsoft documents:

| Plan | Demo resources | Billed |
|---|---|---|
| Defender for Servers (P1 or P2) | T1, the T2 host, and the Arc machine `arcsql01` | Azure VMs while they aren't deallocated; Arc machines only while Connected ([Defender for Servers FAQ](https://learn.microsoft.com/azure/defender-for-cloud/faq-defender-for-servers)) |
| Defender for SQL servers on machines | The T1 and Arc SQL instances | While they run. Billing for a disconnected Arc SQL instance isn't documented, so its worst case is reported but left out of the totals |
| Defender for Azure SQL | The T3 server | All month |
| Defender CSPM | T1 and the T2 host, the T3 server, the T4 server, and T4's read replica | VMs while not deallocated, database servers all month (a stopped T4 too), and the read replica while it exists; Arc machines aren't billable ([Defender CSPM](https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management)) |
| Defender for open-source relational databases | The T4 server (PostgreSQL), and T4's read replica | Per server per month, stopped or not; the replica's month prorated by the hours it exists ([Defender for open-source relational databases](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-databases-introduction)) |
| Defender for Azure Cosmos DB | T5 | Per 100 RU/s of provisioned throughput an hour, free tier or not, while T5's container exists ([Defender for Cloud pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/)). Defender CSPM doesn't bill Azure Cosmos DB accounts |
| Defender for Storage | None | Nothing: the deployment creates no storage accounts ([Defender for Storage](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction)) |
| Defender for Resource Manager and other subscription-wide plans | Not attributed to the demo | Excluded |

New Defender Workload Unit meters took effect on 2026-10-01. Microsoft doesn't publish how many units each plan uses, so the estimate uses the per-plan meters, and the invoice may show the new meters instead.

## Profiles, guardrails, and what bills while stopped

- **Profiles:** `lowest-cost` (the default), `demo-day`, and `enhanced-performance` ([ADR 0016](adr/0016-cost-profiles.md#profiles)); the T2 host's size drives most of the compute cost. `lowest-cost` has no separate data disks (`dataDiskSku` `None`; `E10` adds them). The larger profiles use Premium SSD v2 data disks when `zone` is set and Standard SSD (E10) without one; Premium SSD P10 is only an explicit `dataDiskSku`. The estimate prices the same tiers as the template.
- **While the demo is stopped,** what bills is in [At a glance](#at-a-glance), plus the Defender plans that bill per server or per month, a golden snapshot you keep (also after destroy), anything left on demand, such as Bastion, and, outside the estimates, the Fabric capacity until it's paused.
- **Guardrails** ([ADR 0016's C1 to C11](adr/0016-cost-profiles.md#guardrails-plan-94)): the budget and its alerts; scheduled start and stop windows with warm-up; an expiry tag with a scheduled destroy, and "park T2" (`stop-demo.ps1 -ParkT2`); opt-in Spot and Azure Hybrid Benefit; T3's auto-pause and free offer; Bastion's automatic removal; the nightly safety stop; the session-only replica and T5 container; and month-to-date spend in `status.ps1`. There's no storage account, and by default no Key Vault in the demo resource group: the session control's vault is in `rg-<prefix>-control`, and the [opt-in vault](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard) for the one-time host password needs `assignRoles`.

## Disks switched to Standard HDD by the subscription's automation

A subscription's own automation can switch the demo VMs' OS disks from Standard SSD (E10 in `lowest-cost`) to Standard HDD while they're deallocated, as an application identity that isn't the demo's did on 2026-10-24. Standard HDD lists for less, so the invoice can come in under the estimate; the cost is slower boots and IO. `deploy.ps1` keeps the current type (`DEPLOY.DISKS.DRIFT` **Warning**) and `status.ps1` reports it (`STATUS.DISKS`); changing a disk back is the subscription owner's call ([change a disk's type](https://learn.microsoft.com/azure/virtual-machines/disks-convert-types)).

## Dated example: the 4-vCore T4 default and the $375 ceiling (2026-11-04)

Since 2026-11-04, T4's default is `Standard_D4ds_v5`, for autonomous tuning, and the monthly ceiling allows for its 7-day restart: $375 then, and $415 for a new configuration since 2026-11-19 ([ADR 0016](adr/0016-cost-profiles.md#2026-11-04-user-directed-the-4-vcore-t4-default-and-a-375-ceiling), [ADR 0019](adr/0019-t4-postgresql-flexible-server.md#2026-11-04-user-directed-general-purpose-standard_d4ds_v5-by-default-with-autonomous-tuning)). Against `Standard_B1ms`, it costs $0.339 more a running hour (compute at list prices, West US 3, 2026-11-03, with no Defender plan by the hour). Today's figures: [T4](#azure-database-for-postgresql-t4) and [the monthly check](#ceilings-and-the-monthly-check).

## Dated example: the default deployment (2026-11-05)

Since 2026-11-05 a default deployment makes T2 from Arc Jumpstart's image with no Bastion, keeps no golden snapshot, and sets up the nightly safety stop. Its figures at 2026-11-19 list prices are [At a glance](#at-a-glance); `./scripts/estimate-cost.ps1 -AllProfiles` prices the other profiles, and [ADR 0016](adr/0016-cost-profiles.md#2026-11-05-user-directed-the-nightly-safety-stop-caps-t4s-restart-by-default) and [History](#history) have the 2026-11-05 figures.

## Dated example: business hours, and two optional upgrades (2026-11-03)

Not a proposal: no default changes. List prices in USD for West US 3 on 2026-11-03, with the subscription's Defender for Cloud plans, T4 on `Standard_D2ds_v5`, and T3 as regular serverless at 1 vCore, its maximum then ([implementation report](implementation-report.md)).

- **Business hours,** 9 to 5 on weekdays, are 176 running hours a month: `./scripts/estimate-cost.ps1 -LightUseHoursPerMonth 176` came to $436.98 a month, about $528.81 with the 2-vCore T3, over every default ceiling, so raise `monthlyCeilingUsd` and the budget (`deploy.ps1 -FromStage Infrastructure`) first.
- **Two upgrades:** PostgreSQL autonomous tuning needs 4 vCores, T4's default since 2026-11-04 ($0.356 an hour against $0.178, +$31.33 a month at 176 hours). SQL Server Enterprise on T1 and T2, for automatic tuning with plan correction, Enterprise-only in SQL Server 2022 ([editions](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022)), is $1.50 an hour on each against $0.40 for Standard, +$387.20 a month, about $855.51 with both; the demo installs Standard. Neither adds a Database Hub visual: tuning recommendations show in the Azure portal, and plan correction in `sys.dm_db_tuning_recommendations` and SSMS.

## History

[ADR 0016](adr/0016-cost-profiles.md) has the decisions behind these figures and most of their dated estimates: the monthly ceiling's $250 (2026-10-20), $375 (2026-11-04), and $415 for a new configuration (2026-11-19), the session ceiling's $20 and T3's second vCore (2026-11-18), the nightly safety stop's 96 hours, T5's container for each session, and the Bastion hour the estimate dropped; its Phase 16 note has the 2026-10-21 estimates and the test cycle's measured cost. [ADR 0025](adr/0025-t4-read-replica.md) has the read replica's 2026-11-13 figures, and the [implementation report](implementation-report.md) the business-hours example and the live fallback checks. Superseded figures recorded nowhere else (list prices in USD, West US 3, without Defender for Cloud unless noted): on 2026-11-05, `demo-day` came to $14.75 a session and $83.37 a light-use month, and `enhanced-performance` to $25.53 and $138.21; on 2026-11-18, with T4's restart, `demo-day`'s month was $121.19 with the safety stop and $343.33 without, and `enhanced-performance`'s $176.03 and $398.17; on 2026-11-19, T5's container for each session took `demo-day`'s light-use month from $118.42 to $95.13.
