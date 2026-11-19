# ADR 0016: Cost profiles, ceilings, and guardrails

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** User-directed (Q6: at most $75 a month for idle plus light use, and at most $15 per demo-day session; revised 2026-10-20: a hard monthly ceiling of $250, see below) and plan §9.4 (C1–C11)
- **Related:** [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0006](0006-sql-editions-and-licensing.md), [ADR 0007](0007-networking-modes-and-egress.md), [ADR 0011](0011-control-surface-priority.md), [cost management](../cost-management.md)

## Context

- The T2 nested host's size drives most compute cost. SQL Server licenses bill while VMs run: the T1 image license, and Arc PAYG per core-hour (example list price $0.10 per core-hour, Retail Prices API, 2026-10-19). The billable core count for a 2-vCPU guest is to be confirmed in Phase 7.
- **What bills while everything is stopped:** managed disks, Azure SQL storage, any Bastion or public IP left behind, a private endpoint and private DNS zone in private mode, and, where those Defender for Cloud plans are on, Defender for Azure SQL and Defender CSPM for the T3 server.
- Prices change and vary by region. The brief forbids fixed dollar figures unless they're computed from current regional prices or labeled as examples.
- The Azure Retail Prices API is public and needs no authentication. SQL Server license meters (`Virtual Machines Licenses`) and Arc SQL meters (`Azure Arc Enabled Databases`) are published under the `Global` region, not the deployment region.

## Decision

### Profiles

| Profile | T1 | T2 host and guest | T3 | Disks |
|---|---|---|---|---|
| `lowest-cost` | `Standard_D2s_v5` | `Standard_E2s_v5`; guest 2 vCPU, 8 GiB | GP serverless Gen5, 0.5–2 vCore (0.5–1 before 2026-11-18, [below](#amendment-2026-11-18-the-owners-decision-t3-at-2-vcores-in-lowest-cost-and-a-20-session-ceiling)), auto-pause 15 min | Standard SSD (E10) OS disks; no separate data disks (2026-10-20) |
| `demo-day` | `Standard_D4as_v5` | `Standard_D4as_v5`; guest 2 vCPU, 8 GiB | GP serverless Gen5, 0.5–2 vCore, auto-pause 60 min | Standard SSD (E10) OS and data; Premium SSD v2 data with a zone; Premium SSD (P10) data only as a `dataDiskSku` opt-in |
| `enhanced-performance` | `Standard_D8as_v5` | `Standard_D8as_v5`; guest 4 vCPU, 16 GiB | GP serverless Gen5, 0.5–4 vCore | Premium SSD |

Every value is a parameter, and the profile only sets defaults.

### Ceilings

- `monthlyCeilingUsd` defaults to 415 for a new configuration and `sessionCeilingUsd` to 20 (monthly default revised 2026-10-20, 2026-11-04, and 2026-11-19, session default 2026-11-18 from 15; see below).
- The monthly ceiling is **hard**: `preflight.ps1` and `estimate-cost.ps1` report **Fail** when the light-use monthly estimate is above it. A session estimate above `sessionCeilingUsd` is a **Warning**. `status.ps1` and `start-demo.ps1` follow the same rules.
- The Azure budget amount is `monthlyCeilingUsd`, with alerts at 50%, 80%, and 100% (C2).
- Every default stays the cheapest working option, whatever the ceiling, except T4's size since 2026-11-04 (user-directed; [below](#2026-11-04-user-directed-the-4-vcore-t4-default-and-a-375-ceiling)).

### Guardrails (plan §9.4)

| # | Guardrail | Mechanism |
|---|---|---|
| C1 | No Key Vault by default | ADR 0009 |
| C2 | Azure budget on the resource group: `monthlyCeilingUsd`, alerts at 50%, 80%, and 100% to `ownerEmail` | `Microsoft.Consumption/budgets` in Bicep (Contributor) |
| C3 | Scheduled start and stop windows with warm-up, alongside DevTest Labs auto-shutdown | `schedule-start.yml`, `schedule-stop.yml` (ADR 0011) |
| C4 | `expiresOn` tag with a scheduled destroy, plus "park T2" | `expiry.yml`, `stop-demo.ps1 -ParkT2` |
| C5 | Opt-in Spot for the T2 host, and for T1 in `lowest-cost`, with eviction set to Deallocate and the risk documented | `hostPriority`, `t1Priority` |
| C6 | Opt-in Azure Hybrid Benefit (Windows `licenseType`, SQL `AHUB`), each needing an entitlement attestation | ADR 0006 |
| C7 | T3 auto-pause at 15 minutes in `lowest-cost`; the Azure SQL Database free offer by default, with "continue using database for additional charges" so T3 never pauses for the limit, when preflight finds the offer available (revised 2026-10-20, see below) | `t3AutoPauseMinutes`, `t3FreeOffer` |
| C8 | On-demand Bastion removed automatically after `bastionMaxHours` | `bastion-cleanup.yml`, `status.ps1` |
| C9 | The artifact cache (Cool tier) holds pinned media and runner builds - **Dropped 2026-10-20.** The tenant's governance policies force storage accounts to disable shared-key and public network access, and Defender for Storage adds about $10 a month per account. The bundle now travels in Run Command chunks, and media downloads directly from Microsoft with SHA-256 checks. | ADR 0001 |
| C10 | Premium SSD v2 data disks evaluated in Phase 5 against Standard SSD and Premium SSD P10, using live prices, including the zonal-VM constraint | Phase 5 record |
| C11 | `estimate-cost.ps1` reports, per profile, hourly, daily-demo, and idle-monthly figures from live prices. `status.ps1` shows month-to-date spend through the Cost Management query API (Contributor). | Scripts |

### How estimates are computed

- `estimate-cost.ps1` queries the Retail Prices API for the chosen region and currency, plus the `Global` region for SQL license and Arc meters and for meters published only there (Defender for Cloud, the private endpoint, and the NAT gateway). It never uses a hard-coded price.
- **Billing quantities:**
  - Arc SQL Standard bills per core-hour. Learn documents a minimum of four cores per OSE (manage-license-billing, "Metering and reporting software usage", rechecked 2026-10-20), so the billable core count defaults to the larger of the guest's vCPU count and 4: the 2-vCPU guest is estimated at 4. The parameter `t2ArcBillableCores` overrides it, and `configure-arc.ps1` records the instance's actual cores as evidence ([ADR 0006](0006-sql-editions-and-licensing.md#phase-7-implementation-notes-2026-10-20)).
  - T3 bills vCore-seconds, with a configurable assumption for expected active hours.
  - Private mode adds the private endpoint (all month) and one private DNS zone (per zone per month). When `networkMode` is `auto` and unresolved, the estimate assumes private and says so.
  - Microsoft Defender for Cloud: see the 2026-10-20 addendum below.
- It prints the API query date with every figure.
- Prices quoted in docs are labeled **example** with their date and region.

## Consequences

- **Positive:** spend is bounded by design and visible at all times, and the guardrails need only Contributor.
- **Negative:**
  - Schedules (C3, C4, C8) need the GitHub path (P7). Without it, DevTest Labs auto-shutdown and `status.ps1` warnings are the guardrails.
  - Spot can evict the host during a demo.
  - While T3 exists, Defender for Azure SQL, Defender CSPM, and the private endpoint bill all month, even when T3 is paused. Removing T3 between demos stops them (see the T3 lifecycle below).

## Phase 5 addendum: live estimates and the Premium SSD v2 evaluation (2026-10-19)

**Estimates.** `estimate-cost.ps1 -AllProfiles` priced every component from the Retail Prices API, with no missing meters. These are example figures: list prices in USD for West US 3 on 2026-10-19, with a 5-hour session, 10 running hours a month, and 1 Bastion hour.

| Profile | Running per hour | Session | Idle per month | Light-use month | Against the ceilings |
|---|---|---|---|---|---|
| `lowest-cost` | 1.53 | 7.85 | 42.23 | 57.73 | Both within |
| `demo-day` | 2.36 | 12.00 | 58.87 | 82.67 | Session within; month over |
| `enhanced-performance` | 4.71 | 23.75 | 75.51 | 122.81 | Both over |

`demo-day` goes over the monthly ceiling because its Premium SSD (P10) data disks bill while idle.

The last column compares with the $75 monthly ceiling of the time. These figures include the artifact cache (about 0.15 USD a month), which was dropped on 2026-10-20, and exclude Defender for Cloud and private mode.

**C10 evaluation.** A 128 GiB Premium SSD v2 data disk lists at about 10.28 USD a month, with the baseline 3,000 IOPS and 125 MBps included. That compares with 17.92 for P10 and 9.60 for E10. Premium SSD v2 needs zonal VMs and can't be an OS disk.

- **Decision:** Phase 6 uses Premium SSD v2 for the data disks in `demo-day` and `enhanced-performance` when preflight confirms the size is available in a zone in the chosen region, and keeps Standard SSD (E10) otherwise.
- **Effect:** with that change, `demo-day`'s light-use month falls to about 67 USD at the same list prices, which is within the ceiling.

## Phase 6 note: Premium SSD v2 implementation (2026-10-19)

- Premium SSD v2 is used only when the configuration sets a `zone`, because it needs a zonal VM. Preflight then checks that both VM sizes and `PremiumV2_LRS` are offered in that zone for the subscription (`az vm list-skus`, including Zone restrictions).
- Without a zone, the data disks keep the profile's own tier: P10 for `demo-day` and `enhanced-performance`, as in Phase 5. This refines the decision above, which said E10, so that a profile's disk performance doesn't drop silently. `demo-day` without a zone stays over the monthly ceiling, and preflight's cost check warns (R42). *Superseded for `demo-day` by the decision below.*
- The disks are 128 GiB at the baseline 3,000 IOPS and 125 MBps, with host caching off; Premium SSD v2 supports no host caching. `estimate-cost.ps1` prices the capacity meter per GiB-hour and charges IOPS or throughput only above the free baseline.

## Phase 6 decision: data disks without a zone (2026-10-19)

- **Decision source:** the coordinating session, applying the user-directed monthly ceiling of 75 USD (Q6). It supersedes the second bullet of the Phase 6 note above for `demo-day`.
- **Decision for `demo-day`:**
  - **No zone:** the data disks default to Standard SSD (E10). The light-use month is about 66 USD at the Phase 5 list prices, within the ceiling.
  - **Zone available:** Premium SSD v2 at a small size, at the free baseline IOPS and throughput, when that's within the ceiling. At 128 GiB, the size evaluated in Phase 5, the light-use month is about 67 USD.
  - **Premium SSD P10:** only as an explicit opt-in, through a `dataDiskSku` override in the configuration.
  - **Warnings:** preflight and `estimate-cost.ps1` keep warning whenever a profile's estimate exceeds either ceiling, including when the override is used.
- **Scope (implementer's reading):** `lowest-cost` already uses E10. Choosing `enhanced-performance` is itself an explicit opt-in that exceeds both ceilings, so it keeps its premium disks and the warnings.
- **Status:** implemented on 2026-10-20.
  - `config/profiles.json` sets the `demo-day` regional data disk tier to E10.
  - `dataDiskSku` (`Auto`, `E10`, `P10`, or `PremiumV2`) is in the configuration schema, `infra/main.bicep`, and the deployment parameters. The schema rejects `PremiumV2` without a zone.
  - `Resolve-DemoDataDiskTier` gives the cost estimate and preflight the same rules as `infra/modules/demo.bicep`.
- **Estimates after the change** (example: list prices in USD, West US 3, 2026-10-20; same assumptions as the Phase 5 table):

| `demo-day` data disks | Session | Idle per month | Light-use month | Against the ceilings |
|---|---|---|---|---|
| No zone: E10 (default) | 12.00 | 42.23 | 66.03 | Both within |
| Zone set: Premium SSD v2, 128 GiB at baseline | 12.00 | 43.59 | 67.39 | Both within |
| `dataDiskSku = P10` (opt-in) | 12.00 | 58.87 | 82.67 | Session within; month over (Warning) |

## Revision: a hard monthly ceiling of $250 (2026-10-20, user-directed)

- **Context:** with the tenant's enforced Defender for Cloud plans and private mode, the lightest profile is estimated at about 87 USD a month (example below), above the original $75. The owner accepted that estimate.
- **Decision (user-directed, 2026-10-20):** the monthly ceiling is now **$250, and it's hard**: the demo must stay below it. `monthlyCeilingUsd` defaults to 250, which is also the budget amount; the alerts stay at 50%, 80%, and 100%. `sessionCeilingUsd` stays 15.
- **Status rules:** a light-use monthly estimate above `monthlyCeilingUsd` is **Fail**, and the remediation is to pick a cheaper profile or options, or to raise `monthlyCeilingUsd` in the configuration. A session estimate above `sessionCeilingUsd` stays a **Warning** (ADR 0012). Preflight and `estimate-cost.ps1` produce the same results.
- **Defaults stay minimal:** `lowest-cost` stays the default profile, and every other default stays the cheapest working option. The headroom isn't spent by default.

## Phase 5 addendum: Microsoft Defender for Cloud and private mode (2026-10-20)

Tenant policies can turn Defender plans on (`PREFLIGHT.POLICY.DEFENDER`, ADR 0012), so the estimate includes them. Preflight reads the plans once with `az security pricing list` (read-only). `estimate-cost.ps1` reads them only when the Azure CLI is already signed in to the configured subscription; it never signs in. Only plans on the Standard tier count. Without the plans, the estimate excludes Defender and reports a Warning (`PREFLIGHT.COST.DEFENDER`).

| Plan (name in `az security pricing list`) | Meter (Retail Prices API) | Demo resources and billing basis |
|---|---|---|
| Defender for Servers (`VirtualMachines`, P1 or P2) | Microsoft Defender for Servers / Standard P1 or P2 / Standard P1 or P2 Node, per hour | T1 and the T2 host while they run: Azure VMs aren't billed when deallocated, but are when stopped and still allocated. The Arc machine `arcsql01` only while it's Connected, which is while the T2 host runs. |
| Defender for SQL servers on machines (`SqlServerVirtualMachines`) | Microsoft Defender for SQL / Standard / Standard Instance, per hour | The T1 and Arc SQL instances while they run. Billing for a disconnected Arc SQL instance isn't documented: the worst case (billed all month) goes in the evidence and the monthly message, not in the totals. |
| Defender for Azure SQL (`SqlServers`) | Same meter | The T3 logical server, all month (730 hours) |
| Defender CSPM (`CloudPosture`) | Microsoft Defender CSPM / Standard / Standard Node, per hour | T1 and the T2 host while they aren't deallocated, and the T3 server all month. Arc machines aren't billable resources. |
| Defender for Storage (`StorageAccounts`) | None | Nothing: the deployment creates no storage accounts. |
| Defender for Resource Manager (`Arm`) and other subscription-wide plans | None | Excluded: not attributable to the demo |

- The regional meter is used when one exists, otherwise the `Global` one.
- **Meter change:** new Defender Workload Unit meters (product Microsoft Defender for Cloud) took effect on 2026-10-01. Microsoft doesn't publish how many units each plan uses, so the estimate keeps the per-plan meters, and the invoice may show the new meters instead.
- **Private mode** adds the T3 private endpoint (all month) and one `privatelink.database.windows.net` private DNS zone (per zone per month). Both meters, like the NAT gateway's, are published only under `Global`.

**Example figures:** list prices in USD for West US 3 on 2026-10-20, with a 5-hour session, 10 running hours a month, and 1 Bastion hour, and this tenant's Standard plans (Servers P2, SQL servers on machines, Azure SQL, CSPM, and Storage).

| Profile | Network mode | Session | Light-use month | Of which Defender | Arc SQL worst case |
|---|---|---|---|---|---|
| `lowest-cost` | private | 8.41 | 86.32 | 20.97 | +14.52 |
| `demo-day` | private | 12.54 | 111.24 | 20.97 | +14.52 |
| `enhanced-performance` | private | 24.32 (Warning: over the session ceiling) | 151.44 | 20.97 | +14.52 |

Every profile stays below the $250 hard ceiling. For comparison, `lowest-cost` in public mode without Defender is 57.55 a month.

## Revision: a lighter default, the T3 free offer, and the T3 lifecycle (2026-10-20)

**Context:** the owner asked to keep the demo "as lightweight and cheap as possible" within the $250 ceiling. In this tenant, T3 costs about 27 USD a month just by existing (Defender for Azure SQL, Defender CSPM, and the private endpoint that policy requires; example list prices, West US 3, 2026-10-20).

**Decisions:**

1. **Azure SQL Database free offer by default** (stated to the owner, no objection). `t3FreeOffer` is `auto` (default) or `off`, and replaces the opt-in `t3UseFreeOffer`.
   - With `auto`, T3 uses the free offer with "continue using database for additional charges". The database never pauses for the limit; usage above the allowance bills at General Purpose serverless rates.
   - The offer gives each database 100,000 vCore-seconds of compute, 32 GB of data, and 32 GB of backup storage a month. Microsoft allows up to 10 free databases per subscription, all in the region of the first one.
2. **Availability check** (coordinator, 2026-10-20). Preflight checks the offer read-only (`PREFLIGHT.T3.FREEOFFER`, ADR 0012) with `az sql server list` and `az sql db list`:
   - Ten or more other free databases, or free databases in another region: a **Warning**. T3 falls back to regular General Purpose serverless (minimum 0.5 vCore, auto-pause after 15 minutes), and the estimate prices it that way.
   - An existing T3 database keeps its setting, because an existing database can't be converted. That's a Warning when it isn't on the offer.
   - When not every server can be read: a Warning, and T3 tries the offer.
   - The deployment (Phases 8 and 13) falls back to regular serverless if Azure rejects the offer anyway, so a one-click deploy never fails on it.
3. **Estimates with the offer:** the light-use month subtracts the allowance (up to 100,000 vCore-seconds of T3 compute) and bills only data above 32 GB. The session figure stays at list price, as an upper bound. `estimate-cost.ps1` checks the offer only when the Azure CLI is already signed in; otherwise it prices T3 as regular serverless and says so.
4. **`lowest-cost` has no separate data disks** (stated to the owner, no objection; Phase 6 implements it). SQL Server data on T1 and the T2 guest's virtual disk and media on the host use the 127 GiB OS disks. That saves two E10 disks, about 19 USD a month (example). `demo-day` and `enhanced-performance` keep data disks under the 2026-10-19 disk decision, and `dataDiskSku` stays an explicit override.
5. **T3 lifecycle (user-directed, 2026-10-20):**
   - The initial deploy creates T3, and it persists between demos. `stop-demo.ps1` doesn't delete it; serverless auto-pause stops its compute.
   - `stop-demo.ps1 -RemoveT3` deletes T3 and its private endpoint only when the owner asks, which stops the 27 USD a month.
   - The next `start-demo.ps1` or warm-up recreates T3 if it's missing (about 10 more minutes). `destroy.ps1` removes everything as before.
6. **Recreating T3** (coordinator, 2026-10-20; Phases 9, 10, and 13):
   - **Readiness gate:** warm-up declares T3 ready only after it's visible in Azure Resource Graph, the extended property `MS_EnablePerformanceMonitoringPreview` is set, and telemetry rows arrive from the ADX endpoint. Otherwise it reports a **Warning** with the measured lag.
   - **Stable names:** the same server and database names every session. Telemetry is keyed on the resource ID, so earlier sessions should stay queryable within the 7-day retention; Phase 9 verifies this live.
   - **Lag:** a newly created T3 may show Hub security and posture findings, and Database Agent findings, late. Azure SQL Database is the most likely Database Agent target ("SQL … on Azure"). Phases 9–10 measure the lag. The walkthrough and the cost guide recommend a persistent T3 for agent-focused demos and for multi-day baseline-versus-incident demos.

**Example effect** (`lowest-cost`, 10 running hours a month, list prices 2026-10-20, approximate until re-estimated live): about 87 USD a month before these changes, about 58 with the free offer and no data disks, and about 32 in a month when T3 is removed between demos.

## Phase 6 note: `lowest-cost` without data disks, and the estimates after the merge (2026-10-20)

- **Implemented:** `dataDiskSku` gains `None`, the `lowest-cost` default (`config/profiles.json` sets both VMs' regional data disk tier to `None`). `windows-vm.bicep` creates and attaches the LUN 0 disk only when the tier isn't `None`, and `Resolve-DemoDataDiskTier` gives the estimate and preflight the same rule. The estimate prices no data disk for `None`. An explicit `dataDiskSku` (`E10`, `P10`, or `PremiumV2`) still adds one to any profile, and `None` removes it from `demo-day` or `enhanced-performance`.
- **On the VMs (ADR 0003):** T1 keeps `ContosoCare` in SQL Server's default folders on its OS disk. The T2 host puts the media and the guest VHDX under `C:\DbHubDemo` on its 128 GiB OS disk, after checking that it has room for the VHDX's maximum size, the media, and a 10 GB margin (about 80 GB); otherwise it fails with a message that points to `dataDiskSku` `E10`.
- **`demo-day` and `enhanced-performance`** keep the 2026-10-19 disk decision: E10 data disks without a zone, Premium SSD v2 with one, and P10 only through `dataDiskSku`.
- **Changing an existing deployment to `None`** detaches the old data disk (its `deleteOption` is `Detach`) but doesn't delete it, so it keeps billing until it's deleted by hand.
- **The artifact cache (C9) costs nothing any more:** the bundle travels in Run Command chunks and media comes from Microsoft, so there's no storage account to bill.

**Estimates** (example: list prices in USD for West US 3 on 2026-10-20, with a 5-hour session, 10 running hours a month, 1 Bastion hour, and private mode, which this tenant's policy requires). `estimate-cost.ps1 -AllProfiles -NetworkMode private` with the public Retail Prices API only, without signing in, so Defender is excluded and T3 is regular serverless:

| Profile | Running per hour | Session | Idle per month | Light-use month |
|---|---|---|---|---|
| `lowest-cost` | 1.53 | 7.83 | 30.68 | 46.15 |
| `demo-day` | 2.36 | 11.97 | 49.88 | 73.63 |
| `enhanced-performance` | 4.71 | 23.75 (Warning: over the session ceiling) | 83.16 | 130.46 |

With this tenant's Defender plans as read on 2026-10-20 (passed to `Get-DemoCostEstimate`; no new Azure call), the same prices give:

| Profile | Session | Light-use month, regular serverless | Of which Defender | Light-use month with the T3 free offer |
|---|---|---|---|---|
| `lowest-cost` | 8.41 | 67.12 | 20.97 | 58.23 |
| `demo-day` | 12.54 | 94.60 | 20.97 | 80.49 |
| `enhanced-performance` | 24.32 (Warning) | 151.44 | 20.97 | 133.26 |

- Every profile is below the $250 hard ceiling. If Defender for SQL also bills the disconnected Arc SQL instance, add up to 14.52 a month (not in the totals).
- `lowest-cost` with `dataDiskSku` `E10`, the earlier default, is 77.43 with Defender and the free offer: the two data disks cost 19.20 a month.
- `demo-day` is lower than in the Phase 5 addendum (111.24) because that table used P10 data disks, and Phase 6 uses E10 without a zone.

## Phase 13 note: the workload runner and T3 serverless compute (2026-10-20)

- **T3 stays awake while a profile runs.** Serverless auto-pause needs zero sessions and no user CPU for the whole delay. While the runner's activity host runs a T3 profile (`activityProfile`, `baseline` by default until 2026-11-03, `business-day` since), its sessions keep T3 from pausing, so T3 compute bills for every hour the VMs run.
  - The estimate already assumes this: `T3 compute (serverless)` is a running-hour component, the maximum vCores times `t3ActiveShareOfMaxVcores`.
- **Bounded by the schedule:** the host stops two minutes before the next auto-shutdown (`--not-after`), so T3 pauses `t3AutoPauseMinutes` after the VMs stop. If the VMs run past their schedule (auto-shutdown disabled, or started after that day's shutdown time), the runner keeps T3 awake until the next scheduled shutdown.
- **To keep T3 paused while the VMs run,** set `activityProfile` to `off`, or set only T3's profile to `off` (`Invoke-DemoWorkloadCommand -Target T3` with `profile set --name off`). T1 and T2 keep their profiles.

## Phase 13 revision: the boot behavior and the guardrails as built (2026-10-21, coordinator-directed)

- **Live finding:** the `DbHubDemo-Workload` task applied `baseline` to T1 and T3 at every start of `sqlvm01`, so any start (a manual one in the portal, a restart) kept T3's serverless database awake until the next auto-shutdown (R183).
- **Decision:** the boot behavior follows the configuration. `activityProfileOnBoot` (default `false`) decides whether the VMs set `activityProfile` at boot; they still apply it once after each runner install (a deployment). `deploy.ps1` (its Activity stage) and `start-demo.ps1` set the profile explicitly, and `stop-demo.ps1` and `schedule-stop.yml` set every profile to `off` before the VMs stop. The T3 profile is a file on T1, so turning it off never wakes T3. A VM that's already deallocated needs nothing: every profile ends two minutes before the auto-shutdown it was set for.
- **Guardrails as built:**
  - **C2, C11:** `status.ps1` and `start-demo.ps1` read the month-to-date actual cost with the Cost Management query API. `start-demo.ps1` fails before starting anything when the month already reached `monthlyCeilingUsd`, and warns when one more session would cross it; with the live estimate against both ceilings, that's the same check `deploy.ps1` runs in preflight. `-SkipCostCheck` overrides it.
  - **C3:** `schedule-start.yml` (with a 30-minute warm-up), `warm-up.yml` (by hand), and `schedule-stop.yml`, off until `DBHUB_SCHEDULES_ENABLED` is `true`.
  - **C4:** `expiry.yml` runs `destroy.ps1 -IfExpired`, which deletes nothing until the day after `expiresOn`; `stop-demo.ps1 -ParkT2` parks T2 by hand.
  - **C8:** on-demand Bastion is tagged with now plus `bastionMaxHours` (a longer request is capped). `stop-demo.ps1` and the hourly `bastion-cleanup.yml` delete the host and then its public IP, and delete at once a public IP that an interrupted delete left behind (live, 2026-10-20). `status.ps1` reports either as a **Warning** with its list price per hour from the Retail Prices API.

## Phase 16 note: cost of the teardown tests, and after destroy (2026-10-21)

- **Estimate for the disposable test environment** (`lowest-cost`, private mode, `estimate-cost.ps1` against the Retail Prices API on 2026-10-21): a 5-hour session 7.41 USD against the 15 USD session ceiling, and idle plus 10 hours a month 65.12 USD against the 250 USD ceiling, both **Pass**; Defender for Cloud adds 0.57 to the session and 20.97 to the month. Defender for SQL billing for a disconnected Arc SQL instance isn't documented, so up to 14.52 a month more is possible, as before. These are dated examples; the scripts always price live.
- **The teardown tests run in their own environment** (`environment` `test`, `rg-dbhub-test`, `t2SqlInstallMode` `Developer`), within the 15 USD session ceiling, and end with a destroy whatever happens; the deployment-stack trial uses free user-assigned identities only.
- **After destroy, nothing of the demo bills:** the resource group with every billable resource is gone, Defender plans bill only for protected resources that exist, and the opt-in Key Vault's soft delete holds only secrets, which don't bill ([cleanup](../cleanup.md#cost-after-destroy)).
- **Measured cost of the test cycle** (2026-10-21 and 2026-10-22): about 4.50 USD at list price for both days, under the 15 USD session ceiling: the VMs ran 1.8 hours on 2026-10-21 and `archost01` 3.2 more on 2026-10-22, T3 billed 1.26 vCore-hours, the disks, T3's storage, and the private endpoint existed for about 19 hours, and Defender for Cloud adds 0.90 of the total. These are measured hours times the Retail Prices API's list prices of 2026-10-21, not billed amounts.

## Activity profiles: business-day by default (2026-11-03)

- **Decision source:** the owner made `business-day` the default activity profile ([ADR 0010](0010-workload-generator-technology.md#activity-profiles-business-day-by-default-2026-11-03)); the coordinator asked that the same ceiling checks cover a configuration that doesn't set `activityProfile`, which now inherits it.
- **What it adds:** T3's bill follows the load. `business-day` runs two T3 incidents an hour (`resource-governance` and `log-rate-pressure`, 5 minutes each) at the maximum vCores, and serverless never bills more than the maximum. The estimate prices them as maximum × (1 - `t3ActiveShareOfMaxVcores`) × 10/60 vCore-hours per running hour, from the serverless vCore meter at run time, in both checks and in the free offer's allowance.
- **With the shipped share, 1.0, that's 0:** the estimate has priced T3 at its maximum for every running hour since Phase 13, so the default lowest-cost session and month, and both ceilings, are unchanged, and the checks say so. No ceiling changes. The VMs and a provisioned T4 cost the same whatever the load.
- **The check, a dated estimate (2026-11-03, West US 3, list prices from the Azure Retail Prices API; `lowest-cost`, private networking, all five attributed Defender plans on Standard):** the same figures for `baseline` and `business-day`: $9.49 a session and $105.82 for the month as the ceiling check counts it with T4 on `Standard_B1ms`, $10.30 and $223.35 on the `Standard_D2ds_v5` fallback, all **Pass** against $15 and $250. What no estimate counts, for any profile, is small: T3 between its minimum and maximum vCores for the incidents' minutes, and Standard SSD disk operations under `io-pressure`, at most $0.51 a session and $1.01 a light-use month together; T3's extra log backups stay within the free backup storage of the database's maximum size ([cost management](../cost-management.md#activity-profiles-business-day-phase-28-follow-up)).
- **Where:** preflight's `PREFLIGHT.COST.*`, `start-demo.ps1`'s `START.COST.*` (with its `-ActivityProfile`), and `estimate-cost.ps1`, each with the configured profile or the default; a configuration without `activityProfile` gets one notice, and no script writes the configuration ([cost management](../cost-management.md#activity-profiles-business-day-phase-28-follow-up)).

## 2026-11-04 (user-directed): the 4-vCore T4 default and a $375 ceiling

- **Decision source:** the owner, verbatim (2026-11-04 07:31): "Change the default to not deploy burstable but the 4 core"; then, on the ceiling this needs (about 07:45, asked through the coordinator): "Raise the default to $375, and count a restart as at most 1 day where the safety stop exists". The coordinator added when the safety stop counts, and that the docs and messages say how to stay cheap.
- **A deliberate departure from "every default stays the cheapest working option":** T4's default is General Purpose `Standard_D4ds_v5` (4 vCores) instead of Burstable `Standard_B1ms`, because autonomous tuning runs "on any currently supported compute SKU with at least 4 vCores" ([autonomous tuning](https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning), updated 2026-07-16), on Query Store, and "Don't enable query store on the Burstable pricing tier as it causes performance problems" ([Query Store](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store)); both checked 2026-11-04. The size, the switch `t4AutonomousTuning`, and the fallback are in [ADR 0019](0019-t4-postgresql-flexible-server.md#2026-11-04-user-directed-general-purpose-standard_d4ds_v5-by-default-with-autonomous-tuning). Every other default is unchanged.
- **`monthlyCeilingUsd` defaults to 375** (from 250), still hard: a light-use month above it is a **Fail**. `sessionCeilingUsd` stays 15. The reason is the worst case after T4 restarts itself: Azure starts a stopped flexible server again after seven days, and at $0.356 an hour (2026-11-03) the rest of a month is $256.32, more than the old ceiling's room. The Azure budget's amount follows `monthlyCeilingUsd`, with its alerts at 50%, 80%, and 100%; an existing environment gets the new budget at its next `deploy.ps1 -FromStage Infrastructure`, and a configuration that sets `monthlyCeilingUsd` keeps its value.
- **The restart counts as about a day where the safety stop holds:** when all three hold, the `dbhub-t4-safety-stop` schedule exists and is enabled, the control identity's A1 role is assigned on `rg-<prefix>-<environment>` (destroy deletes it, and only `assignRoles` or `-GrantRole` grants it again; without it the runbook can't stop T4), and the last `DbHub-Stop` job didn't fail, each 7-day restart counts as running until the next safety stop, about 24 hours: at most about 4 a month, about 96 hours (`Get-DemoT4RestartCoverage`, `Get-DemoT4RestartWorstCase`). Otherwise the rest of the month counts, with a **Warning** that names the missing piece and the exact fix: `setup-activity-control.ps1`, `-GrantRole`, or `deploy.ps1` with `assignRoles`. A read that fails counts as missing (fail safe). `PREFLIGHT.COST.MONTHLY`, `START.COST.*`, and `STATUS.*` say which assumption applies and why.
- **How to stay cheap,** in the docs and in the monthly check's message: set `t4SkuName` to `Standard_B1ms` (which turns autonomous tuning off), set `t4Enabled` to `false`, or lower `monthlyCeilingUsd`.
- **The check (dated: list prices, West US 3, the Azure Retail Prices API; light-use months of 10 running hours):** the example configuration (`lowest-cost`, private mode assumed, no Defender plans read; `estimate-cost.ps1` on 2026-11-04) is $55.89, $90.07 with the safety stop's 96 hours, and $312.21 with the rest of the month; the owner's kind of configuration (private mode, the tenant's Defender plans, T3 at list price, the golden snapshot; the 2026-11-03 basis at `Standard_D4ds_v5`) is $103.37, $137.55, and $359.69. All four totals pass $375; against $250, both pass with the safety stop and fail without it ([cost management](../cost-management.md#dated-example-the-4-vcore-t4-default-and-the-375-ceiling-2026-11-04)).
- **Validation:** unit-tested (`tests/unit/DbHubDemo.Cost.Tests.ps1`, `DbHubDemo.T4.Tests.ps1`, `DbHubDemo.Preflight.Tests.ps1`, `DbHubDemo.T4Fallback.Tests.ps1`: both restart assumptions, and each missing piece of the safety stop). Not run live.

## 2026-11-05 (user-directed): the nightly safety stop caps T4's restart by default

- **Decision source:** the owner, 2026-11-05: "Can we have safety stops for all the databases?", then a daily safety stop in every deployment at the nightly shutdown time ([ADR 0024](0024-nightly-safety-stop.md)).
- **The rule above stands; what satisfies it changes:** the safety stop that counts is first the nightly safety stop, which every `deploy.ps1` sets up: its schedule `dbhub-safety-stop` enabled and linked to `DbHub-Stop -Scope Nightly`, its role "DbHub Demo Safety Stop" assigned at the demo resource group, and its last run not failed (`Get-DemoT4RestartCoverage`, missing pieces `SafetyStop`, `Role`, or `StopJob`). The control's own daily T4 safety stop still counts when it's fully in place. Otherwise the rest of the month counts, with a **Warning** whose fix is `./scripts/deploy.ps1` or an Owner's `./scripts/grant-safety-stop.ps1`.
- **So a deployment with an Owner's role counts about 96 hours by default**, $34.18 at `Standard_D4ds_v5` (a dated example: list prices, West US 3, 2026-11-05, unchanged from 2026-11-04). The example configuration's light-use month with that worst case: $90.07 for `lowest-cost`, $117.55 for `demo-day`, and $172.39 for `enhanced-performance`; without it, $312.21, $339.69, and $394.53, the last above $375 ([cost management](../cost-management.md#dated-example-the-nightly-safety-stop-2026-11-05)). The ceiling stays $375.
- **A first deployment's preflight** runs before the safety stop exists, so that one preflight counts the rest of the month (fail safe, no prediction); later preflights, `start-demo.ps1`, and `status.ps1` read it. *(Since 2026-11-19 it counts the safety stop that the run sets up when the deployer can assign its role: [below](#2026-11-19-a-first-deployments-worst-case-and-a-415-default-for-a-new-configuration).)*
- **Its own cost:** two short Automation jobs a night; the estimate adds 120 job minutes a month at the Basic Runtime meter's first tier, from the Retail Prices API at run time ($0 within the 500 minutes a month Azure Automation includes).
- **Validation:** unit-tested (`tests/unit/DbHubDemo.SafetyStop.Tests.ps1`, `DbHubDemo.T4.Tests.ps1`, `DbHubDemo.Cost.Tests.ps1`, `DbHubDemo.Preflight.Tests.ps1`). Not run live.

## 2026-11-05 (user-directed): the JumpstartImage default's cost

Prices here are dated examples: list prices in USD for West US 3 from the Azure Retail Prices API on 2026-11-05, not quotes.

- **Decision source:** the owner's direction of 2026-11-05, which made `JumpstartImage` T2's default install mode ([ADR 0006](0006-sql-editions-and-licensing.md#2026-11-05-user-directed-jumpstartimage-arc-jumpstarts-sql-server-standard-image-by-default)). No profile, ceiling, guardrail, or default size changes, and `estimate-cost.ps1` is unchanged: it prices T2 as Arc SQL Server Standard PAYG in every mode but `Developer`, so this mode costs what `PaygWizard` does ($0.10 per core-hour at the four-core minimum).
- **No new Azure resource:** the guest's disk is a file on the T2 host's existing OS disk (`lowest-cost`: the E10 Standard SSD, $9.60 a month), or on its data disk in the larger profiles; no storage account, no new disk, and no new meter. The image's download into Azure is free ("Standard Data Transfer In", $0.00 per GB), and writing it is about 140,000 disk operations on the Standard SSD, about $0.03 at $0.002 per 10,000.
- **No Bastion to deploy (C8 unchanged):** only the opt-in `PaygWizard` guided stop needs Bastion, about an hour per guest build. In the default mode Bastion stays optional, for interactive access such as T2's missing-index fix. Bastion Basic is $0.19 an hour and its Standard public IP $0.005, about $0.20 an hour together, and `estimate-cost.ps1` still counts one Bastion hour per session (`bastionHoursPerSession` in `config/profiles.json`; none by default since 2026-11-19, [below](#2026-11-19-the-monthly-check-says-its-total-and-no-bastion-hour-by-default)).
- **The golden snapshot is optional:** in this mode it only speeds up a redeploy ([ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md#amendments-2026-11-05-golden-snapshots-in-jumpstartimage-mode)), and without one nothing bills. Standard HDD snapshots list at $0.05 per GB-month, and the estimate prices the 128 GiB provisioned size: at most about $6.40 a month. A `JumpstartImage` host's OS disk also holds the 34 GiB image, so the used size that Azure bills is an estimated 50 to 60 GiB, about $2.50 to $3 a month (not measured), where a `PaygWizard` host measured 37 GiB (2026-10-22, about $1.85 a month).
- **Disk space, not a data disk:** `lowest-cost` keeps its one OS disk. Instead of the build modes' 80 GB check, this mode needs about 64 GiB free (the image, 20 GiB for it to grow, and the 10 GiB margin), and `status.ps1` warns when less than 20 GiB is free ([ADR 0003](0003-t2-host-size-security-type-bootstrap.md#amendment-the-hosts-steps-for-jumpstartimage-2026-11-05)); `dataDiskSku` `E10` stays the remedy (the owner's decision: no disk shrink).
- **The check (`estimate-cost.ps1` on 2026-11-05; a 5-hour session, and a light-use month of 10 running hours):** with the example configuration (`lowest-cost`, now `JumpstartImage`; private mode assumed, no Defender plans read, T3 as regular serverless), $2.08 an hour running, $0.20 an hour of Bastion, **$10.61** for a session with one Bastion hour, and **$55.89** for a light-use month, the same light-use month as on 2026-11-04 and within both ceilings ($15 and $375).

## Amendment (2026-11-18, the owner's decision): T3 at 2 vCores in lowest-cost, and a $20 session ceiling

- **Decision source:** the owner, 2026-11-18, answering the coordinator's question.
- **Why:** Database Agents (preview) in Fabric Database Hub doesn't support one-vCore serverless databases ([Database Agents, Supported databases and servers](https://learn.microsoft.com/fabric/database/hub/database-agents), checked 2026-11-18: "Currently, Database Agents doesn't support: ... One-vCore serverless databases"). `lowest-cost`'s T3 was General Purpose serverless (`GP_S_Gen5`) at 0.5 to 1 vCore, so Database Agents couldn't use it in the default deployment.
- **T3 goes to 2 vCores in `lowest-cost`:** `maxVcores` is 2 in `config/profiles.json` (it was 1); `minVcores` stays 0.5, `demo-day` already had 2 and `enhanced-performance` 4, so every profile's T3 now has at least 2. "Every default stays the cheapest working option" still holds: 1 vCore no longer works for the Database Agents part of the demo, and 2 is the smallest maximum above it ([GP_S_Gen5_2](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases): 0.5 to 2 vCores).
- **An existing T3 is scaled online by the next `./scripts/deploy.ps1`, with no step for a person:** every run that deploys the template (`azuredeploy.json`, which compiles `config/profiles.json` in) updates the database's `capacity`. A paused database resumes for it ("Changing maximum vCores, minimum vCores, or auto-pause delay" is an auto-resume trigger: [auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)), the database stays online while it scales, and the switch at the end drops its connections, a brief interruption "generally for less than 30 seconds and often for only a few seconds" ([scale single database resources](https://learn.microsoft.com/azure/azure-sql/database/single-database-scale)). A free-offer T3 keeps the offer: preflight finds the existing database on it, so the template sends `useFreeLimit` and `BillOverUsage` again, and "**Continue using database for additional charges** allows paid overages and scaling within General Purpose, but doesn't disable the free tier" ([free tier FAQ](https://learn.microsoft.com/azure/azure-sql/database/free-tier-faq), updated 2026-11-11; only **Auto-pause the database until next month** limits the database to 4 vCores). A plain `deploy.ps1` after **DONE** starts over, so it deploys the template; one that would resume an unfinished deployment past the template starts from preflight instead when T3's maximum vCores aren't the profile's (`DEPLOY.T3.SCALE`, as `DEPLOY.T4.MISSING` does for a missing T4). Until then, `validate.ps1`'s `T3.DATABASE` is a **Warning** ("1 maximum vCores, not 2").
- **What it costs:** serverless bills the vCore-seconds used, never above the maximum ([serverless compute tier](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-overview)), and the estimate prices T3 at its maximum for every running hour (`t3ActiveShareOfMaxVcores` 1.0), so T3's running hour doubles: $1.04 instead of $0.52, at $0.521758 per vCore-hour. Dated example (list prices in USD for West US 3 from the Azure Retail Prices API on 2026-11-18; `estimate-cost.ps1 -AllProfiles` with the example configuration: private mode assumed, Defender for Cloud not read, T3 as regular serverless, T4's read replica in each session): `lowest-cost` is $2.97 an hour running (was $2.44), $15.03 a 5-hour session (was $12.42; $13.22 without the replica), and $64.75 a light-use month (was $59.53); with T4's restart worst case, $98.93 with the nightly safety stop and $321.07 without it, both within $375. The idle month doesn't change ($34.89), and neither do `demo-day` ($16.56, $87.01) and `enhanced-performance` ($27.34, $141.85).
- **The free offer:** its 100,000 vCore-seconds a month cover about 13.9 hours at 2 vCores (27.8 at 1), so a light-use month of 10 running hours, 72,000 vCore-seconds, still fits, and the estimate's light-use month with the offer is $50.63; the session stays at list price, an upper bound.
- **`sessionCeilingUsd` defaults to 20** (it was 15), still a **Warning** above it, never a **Fail**: `lowest-cost`'s session at $15.03 would have been over 15. `demo-day`'s $16.56, a **Warning** against 15 since the read replica (2026-11-13), is a **Pass** now; `enhanced-performance`'s $27.34 stays a **Warning**. `monthlyCeilingUsd` stays 375.
- **An existing configuration needs no edit:** `init.ps1` wrote 15 (from `config/demo.config.example.json`), so `Get-DemoConfig` gives a configuration with exactly 15 the new default, 20, and marks it `sessionCeilingUsdSource` `legacy`, which `ConvertTo-DemoConfigFileText` leaves out (the schema allows no unknown key). Every reader of the ceiling sees 20: preflight's and `estimate-cost.ps1`'s `PREFLIGHT.COST.SESSION`, `start-demo.ps1`'s guardrail, and T4's cost checks. `deploy.ps1` says so in one line at its start and on its status page, as for an older `PaygWizard`. Decided at run time: the file isn't rewritten. Any other value someone set stays as it is. Unlike `monthlyCeilingUsd`'s exactly-250 rule (2026-11-09), which keeps the value and only turns a T4 size the person didn't choose from a **Fail** into a **Warning**, the session ceiling is only ever a **Warning**, so the value itself moves.
- **Validation:** unit-tested (`tests/unit/DbHubDemo.Config.Tests.ps1`, `DbHubDemo.Cost.Tests.ps1`, `DbHubDemo.OneClick.Tests.ps1`, `DbHubDemo.OneCommand.Tests.ps1`, `DbHubDemo.Tracks.Tests.ps1`, `DbHubDemo.T3.Tests.ps1`, `DbHubDemo.T4Fallback.Tests.ps1`, `Infra.T3.Tests.ps1`). `azuredeploy.json` was rebuilt with the pinned Bicep 0.47.16. Not run live.

## 2026-11-19: T5's container for each session

- **Decision source:** [ADR 0027](0027-t5-cosmos-db.md), 2026-11-19: an Azure Cosmos DB account has no stop, and a container's provisioned throughput can't be taken away, only deleted with the container, so T5's container exists only during a session once the session control's role can create it again. No profile, ceiling, guardrail, or default changes.
- **What the estimate does** (`Get-DemoCostEstimate -T5ContainerLifecycle`, `Session` by default): T5's throughput, its storage (prorated by the hour, as T4's read replica's), and Defender for Azure Cosmos DB when its plan is on Standard are running costs, billed for the session hours and the light-use hours only. Its private endpoint and private DNS zone stay idle costs, all month. `AlwaysOn`, while the session control's role can't create the container, prices all of it all month, as on 2026-11-18. `T5FixedMonthly` is what T5 bills all month whatever the demo does, `T5RunningHourly` its running hour, and `T5AlwaysOnExtraMonthly` what `AlwaysOn` adds to the light-use month; `PREFLIGHT.COST.MONTHLY` says all three.
- **The check** (dated: list prices in USD for West US 3 from the Azure Retail Prices API on 2026-11-19, the same as on 2026-11-18; the example configuration, `lowest-cost`, private mode assumed, Defender for Cloud not read, T3 as regular serverless, T4's read replica in each session; 5-hour sessions and light-use months of 10 running hours): T5's month goes from $31.41 to $8.12 at list price, $7.80 all month for the private endpoint and DNS zone plus $0.032 an hour for its 400 RU/s while the demo runs, and stays $7.80 on the free tier. The demo's light-use month goes from $96.16 to $72.87 at list price and stays $72.55 on the free tier; with T4's restart and no safety stop, from $352.48 to $329.19 ($328.87 on the free tier), within $375. A session gains $0.16 at list price ($15.19, within $20). With Defender for Azure Cosmos DB, T5's month goes from $34.91 to $8.17 ($11.30 to $7.85 on the free tier). `AlwaysOn` adds $23.29 to the light-use month at list price, and nothing on the free tier ([cost management](../cost-management.md#t5-azure-cosmos-db-2026-11-18)).
- **Not counted:** Azure Cosmos DB bills each clock hour, or part of one, that the container exists ([understand your bill](https://learn.microsoft.com/azure/cosmos-db/understand-your-bill)), so a session bills every clock hour it touches: up to one hour more than its length, $0.032 at list price.
- **Validation:** unit-tested (`tests/unit/DbHubDemo.Cost.Tests.ps1`, `DbHubDemo.EstimateCost.Tests.ps1`). Not run live.

## 2026-11-19: a first deployment's worst case, and a $415 default for a new configuration

- **Decision source:** the coordinator, 2026-11-19, for option 2, the price of T5's container, and the fixes after the review of ab91ee5; the owner, 2026-11-19, for the default: "$415: a Contributor keeps about $17 of margin", chosen from the corrected numbers below. The trigger: a new deployment of the example configuration, run as an Owner at 52df9bd, ended **NOT DONE** at preflight (`PREFLIGHT.COST.MONTHLY` **Fail**, about $398 against $375). A first deployment's preflight runs before the nightly safety stop exists, so it counted T4's restart for the rest of the month (720 hours), and T5's container all month on top. A new deployment refused at preflight with the default settings breaks one click.
- **A safety stop that this run sets up counts (option 2):** a correction to the worst-case model, not a looser guard. Preflight reads, once, whether the deployer can create role assignments at the demo resource group (at the subscription before the group exists) and write custom roles in the subscription ([Permissions - List For Resource Group](https://learn.microsoft.com/rest/api/authorization/permissions/list-for-resource-group); `Get-DemoDeployerRolePermission`, read-only, fail safe). When the nightly safety stop isn't in place yet and `deploy.ps1` will set it up fully in this same run, because the deployer can assign its role and its role is current or can be written (`Get-DemoSafetyStopPlan`), each restart counts as about a day, as when it's in place: `PREFLIGHT.COST.T4RESTART` is a **Pass** that says so. Otherwise T4's restart counts the rest of the month, as before (a Contributor, the documented minimum).
- **If the setup then doesn't put it in place,** the run says so as soon as it knows (`DEPLOY.COST.T4RESTART`, a **Warning**, on the console, the Infrastructure row of the status page, and the run's results): the month's worst case without it, against `monthlyCeilingUsd`, with the fix (an Owner's `./scripts/grant-safety-stop.ps1`, and the ceiling to raise when it's over). `PREFLIGHT.COST.MONTHLY` keeps that figure (`monthlyWorstCaseWithoutSafetyStop`) and names it in its message.
- **T5's container is priced as this run will record it, and by what deletes it** (the coordinator's gap fix, and the review of ab91ee5; [ADR 0027](0027-t5-cosmos-db.md#2026-11-19-session-when-the-session-control-has-no-role-and-what-preflight-prices)): for a session's hours (`Session`) when the session control will be able to create it (its role has the container's actions, or the deployer can write them, and it holds the role, or the deployer can assign it), so its own stops delete it. With no role at all, for a session's hours only when the nightly safety stop is in place, or this run sets it up, with the container's read and delete actions, so it deletes the container every night. All month (`AlwaysOn`) otherwise: a role without those actions, no role and no such safety stop (a Contributor's new environment, where only `stop-demo.ps1` deletes it), or a read that fails. When the run then records otherwise, `DEPLOY.T5.LIFECYCLE` gives the month's worst case again, against the ceiling, as `DEPLOY.COST.T4RESTART` does for T4.
- **`monthlyCeilingUsd` defaults to 415 for a new configuration** (`init.ps1` and `config/demo.config.example.json`, the schema's default, and the template's): it was 375. A value already in a configuration never changes, so an existing environment keeps its ceiling, and its budget, until someone edits it. (The coordinator first proposed 390; after the review of ab91ee5, a Contributor's new deployment would have been $8.42 over it. It never reached `main`.)
- **The check** (`Get-DemoCostEstimate`, the module's own function, with the subscription's Defender plans read and list prices in USD for West US 3 from the Azure Retail Prices API on 2026-11-19; private mode, light-use months of 10 running hours; dated examples, not quotes):

| Case | T5's container | Worst case | Ceiling | Margin |
|---|---|---|---|---|
| The owner's update (their configuration, the safety stop in place), at 52df9bd | All month | $175.20; $151.59 on the free tier | $250 | +$74.80; +$98.41 |
| The same, now (an Owner's run updates the roles) | Each session | $149.34; $149.02 on the free tier | $250 | +$100.66; +$100.98 |
| The example configuration, a new deployment by an Owner, at 52df9bd | All month | $397.34; $373.73 on the free tier | $375 | −$22.34 (**Fail**); +$1.27 |
| The same, now (the safety stop counts: 96 hours) | Each session | $149.34; $149.02 on the free tier | $415 | +$265.66; +$265.98 |
| The example configuration, a new deployment by a Contributor, at 52df9bd | All month | $397.34; $373.73 on the free tier | $375 | −$22.34 (**Fail**); +$1.27 |
| The same, now (no session-control role and no safety stop, so nothing automatic deletes the container; the restart counts 720 hours) | All month | $398.23; $374.62 on the free tier | $415 | +$16.77; +$40.38 |

On the free tier, T5's 400 RU/s bill nothing, and only Defender for Azure Cosmos DB, where its plan is on Standard, bills all month: $3.46 more. If the safety stop that an Owner's first deployment counts isn't put in place after all, that run's worst case is $371.48 ($371.16 on the free tier), within $415, and the run says so (`DEPLOY.COST.T4RESTART`); if a policy refuses the Owner's role writes too, which the permissions read can't see, the session control ends with no role and T5's container is priced all month after the run: $398.23, within $415 (`DEPLOY.T5.LIFECYCLE`). The figures now include Ask's chat relay (ADR 0028, merged the same day) for the month's 10 running hours, about $1.08, and no Bastion hour ([below](#2026-11-19-the-monthly-check-says-its-total-and-no-bastion-hour-by-default)); the ones at 52df9bd have the Bastion hour and not the relay. The owner chose $415 from the Contributor's $398.42, with the Bastion hour.

- **Validation:** unit-tested (`tests/unit/DbHubDemo.SafetyStop.Tests.ps1`: the permissions an Owner, a Contributor, and a Role Based Access Control Administrator have, a group that doesn't exist yet, a read that fails, a role that's current or one action short, and `DEPLOY.COST.T4RESTART` over and within the ceiling; `DbHubDemo.Preflight.Tests.ps1`: an Owner's and a Contributor's first deployment; `DbHubDemo.Cost.Tests.ps1`: the planned case's figures and message; `DbHubDemo.T5.Tests.ps1`: T5's price for a new environment, an update from `main`, each deployer, and no role with and without a safety stop that deletes the container; `DbHubDemo.EstimateCost.Tests.ps1`; `DbHubDemo.Progress.Tests.ps1`; `DbHubDemo.Config.Tests.ps1`, `DbHubDemo.Validation.Tests.ps1`: the 415 default). `azuredeploy.json` was rebuilt with the pinned Bicep 0.47.16. Live: see the implementation report.

## 2026-11-19: the monthly check says its total, and no Bastion hour by default

- **Decision source:** the coordinator's docs audit, 2026-11-19 (S9 and the monthly check's text).
- **The monthly check says what it compares:** `PREFLIGHT.COST.MONTHLY`, which preflight, `start-demo.ps1`'s cost guardrail, and `estimate-cost.ps1` report, starts with the month's worst case, the total it compares with `monthlyCeilingUsd` (the light-use month plus T4's automatic restart), the ceiling, the margin under or over it, and what it counted: the light-use month, T4's restart hours and their cost, and T5's container, for the running hours (`Session`) or all month (`AlwaysOn`). Its evidence adds `monthlyCeiling` and `monthlyMargin`, the estimate's object `MonthlyWorstCase`, `MonthlyCeiling`, and `MonthlyMargin`, and `estimate-cost.ps1` prints the same for each profile in a table, "The monthly check". What decides **Pass** or **Fail** doesn't change.
- **No Bastion hour by default:** a default deployment has no Bastion, and neither has a default session: only `start-demo.ps1 -Interactive` deploys it, for interactive access such as T2's missing-index fix, and it goes after `bastionMaxHours` (C8). So `bastionHoursPerSession` in `config/profiles.json` is 0; it was 1. `start-demo.ps1 -Interactive`'s cost guardrail counts Bastion for its hours, at most `bastionMaxHours` (4 by default) and the session's length, and `estimate-cost.ps1 -BastionHours` prices such a session. The estimate still reads Bastion's hourly price and shows it.
- **The check** (dated: list prices in USD for West US 3 from the Azure Retail Prices API on 2026-11-19; the example configuration, `lowest-cost`, private mode assumed, Defender for Cloud not read, T3 as regular serverless, T4's read replica in each session; a 5-hour session and a light-use month of 10 running hours): a session goes from $15.73 to $15.53 and a light-use month from $73.95 to $73.76; with T4's restart for the rest of the month, the worst case is $330.08, $84.92 under $415. With the subscription's Defender plans and Ask's chat relay, each worst case in the section above is $0.19 or $0.20 lower than with the Bastion hour.
- **An environment that doesn't exist yet, in `estimate-cost.ps1`** (the final tests, 2026-11-19): an Owner who ran it before a first deployment saw T4's restart counted for the rest of the month, about $368, while `deploy.ps1`'s preflight then counted the nightly safety stop that its run sets up, $149.54. Signed in, the script now prices such an environment as that preflight will for the person who runs it, with the same functions and read-only probes: `Get-DemoDeployerRolePermission`, `Resolve-DemoT4RestartCoverage` (preflight's option 2, now one function that both call), and `Get-DemoT5CostLifecycle -ThisRunDeploys`. It says what it assumed, for example "T4's automatic restart: about a day each, counting the nightly safety stop that deploy.ps1 sets up in its first run, since you can assign its role", or, for a Contributor, the rest of the month with the grant command, and T5's container all month. An existing environment is priced by what's in place, as before, and your permissions are read only when there's no environment. Dated example (read-only, an internal subscription's Defender plans, 2026-11-19 list prices, the example configuration in private mode, as an Owner): $149.34, the figure preflight checks.
- **Validation:** unit-tested (`tests/unit/DbHubDemo.Cost.Tests.ps1`: the worst case, the margin, and what it counted, under and over the ceiling, and no Bastion hour by default; `DbHubDemo.EstimateCost.Tests.ps1`: the monthly check's table, `-BastionHours`, and an environment that doesn't exist yet for an Owner and for a Contributor; `DbHubDemo.Lifecycle.Tests.ps1`: `-Interactive` counts Bastion and a default start doesn't; `DbHubDemo.Preflight.Tests.ps1` for the shared function). Each test fails without its change. Live, read-only: `estimate-cost.ps1` signed in, for a prefix with no environment.

## Validation

- **Phase 4 (static):** Pester tests for `estimate-cost.ps1` against recorded API responses, including `Global` meters and the `t2ArcBillableCores` parameter.
- **Phase 5 (live, pending go-ahead):** the budget exists with three alerts; live estimates for each profile are recorded against the ceilings; the Premium SSD v2 evaluation (C10) is recorded.
- **Phase 16:** nothing billable remains after destroy: `TEARDOWN.RESIDUAL.*` checks every resource, tagged or in the group, Arc included (unit-tested). Live in the disposable test environment: after the destroy on 2026-10-22, nothing billable was left (the residual check and a subscription snapshot compared with the one before deploy). The budget that outlived the group, now deleted by `destroy.ps1`, and an orphaned role assignment from the tenant's governance don't bill (Phase 16 note above).

## Sources (checked 2026-10-19)

- Azure Retail Prices API: <https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices>
- Budgets in Bicep: <https://learn.microsoft.com/azure/templates/microsoft.consumption/budgets>
- Cost Management query API: <https://learn.microsoft.com/rest/api/cost-management/query/usage>
- Serverless auto-pause: <https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume>
- Azure SQL free offer (checked 2026-10-20): <https://learn.microsoft.com/azure/azure-sql/database/free-offer>
- Spot VMs: <https://learn.microsoft.com/azure/virtual-machines/spot-vms>
- Arc SQL billing: <https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing>
- SQL Server VM pricing guidance: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/pricing-guidance>
- Premium SSD v2: <https://learn.microsoft.com/azure/virtual-machines/disks-deploy-premium-v2>
- Defender for Servers billing by power state (checked 2026-10-20): <https://learn.microsoft.com/azure/defender-for-cloud/faq-defender-for-servers>
- Defender CSPM billable resources (checked 2026-10-20): <https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management>
- Defender for SQL (checked 2026-10-20): <https://learn.microsoft.com/azure/defender-for-cloud/defender-for-sql-introduction>
- Defender for Storage, priced per storage account (checked 2026-10-20): <https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction>
- `az security pricing list` (checked 2026-10-20): <https://learn.microsoft.com/cli/azure/security/pricing>
- Private endpoint DNS zones (checked 2026-10-20): <https://learn.microsoft.com/azure/private-link/private-endpoint-dns>
