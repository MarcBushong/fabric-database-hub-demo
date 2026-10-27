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
| `lowest-cost` | `Standard_D2s_v5` | `Standard_E2s_v5`; guest 2 vCPU, 8 GiB | GP serverless Gen5, 0.5–1 vCore, auto-pause 15 min | Standard SSD (E10) OS disks; no separate data disks (2026-10-20) |
| `demo-day` | `Standard_D4as_v5` | `Standard_D4as_v5`; guest 2 vCPU, 8 GiB | GP serverless Gen5, 0.5–2 vCore, auto-pause 60 min | Standard SSD (E10) OS and data; Premium SSD v2 data with a zone; Premium SSD (P10) data only as a `dataDiskSku` opt-in |
| `enhanced-performance` | `Standard_D8as_v5` | `Standard_D8as_v5`; guest 4 vCPU, 16 GiB | GP serverless Gen5, 0.5–4 vCore | Premium SSD |

Every value is a parameter, and the profile only sets defaults.

### Ceilings

- `monthlyCeilingUsd` defaults to 250 and `sessionCeilingUsd` to 15 (monthly default revised 2026-10-20; see below).
- The monthly ceiling is **hard**: `preflight.ps1` and `estimate-cost.ps1` report **Fail** when the light-use monthly estimate is above it. A session estimate above `sessionCeilingUsd` is a **Warning**. `status.ps1` and `start-demo.ps1` follow the same rules.
- The Azure budget amount is `monthlyCeilingUsd`, with alerts at 50%, 80%, and 100% (C2).
- Every default stays the cheapest working option, whatever the ceiling.

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

- **T3 stays awake while a profile runs.** Serverless auto-pause needs zero sessions and no user CPU for the whole delay. While the runner's activity host runs a T3 profile (`activityProfile`, `baseline` by default), its sessions keep T3 from pausing, so T3 compute bills for every hour the VMs run.
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
