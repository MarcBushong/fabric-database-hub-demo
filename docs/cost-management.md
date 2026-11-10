# Cost management

The demo's own resources stay below a hard **$375 a month** for idle plus light use ($250 before 2026-11-04), and a demo-day session should stay below **$15**. Every default is the cheapest option that works, except T4's size: since 2026-11-04 it's General Purpose `Standard_D4ds_v5`, for autonomous tuning, at the owner's direction ([below](#dated-example-the-4-vcore-t4-default-and-the-375-ceiling-2026-11-04)). No price in this repo is hard-coded: estimates come from the Azure Retail Prices API at run time, and every figure in the docs is a dated example ([ADR 0016](adr/0016-cost-profiles.md)). The current figures are the [default deployment's dated example](#dated-example-the-default-deployment-2026-11-05); the README lists [what stops or pauses on its own](../README.md#what-stops-or-pauses-on-its-own), with times.

## Dated example: the default deployment (2026-11-05)

Since 2026-11-05, three changes reach a default deployment's cost: T2 is made from Arc Jumpstart's image (`JumpstartImage`) and needs no Bastion to deploy, the T2 golden snapshot is optional, and every deployment sets up the [nightly safety stop](#dated-example-the-nightly-safety-stop-2026-11-05), which caps T4's 7-day restart at about a day. The figures below are `./scripts/estimate-cost.ps1 -AllProfiles` with the example configuration (`config/demo.config.example.json`: T2 in `JumpstartImage` mode, T4 on `Standard_D4ds_v5`, private mode assumed, Defender for Cloud not read, T3 as regular serverless, no golden snapshot), 5-hour sessions, and light-use months of 10 running hours. List prices in USD for West US 3 from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) on 2026-11-05, read again once the three changes were combined, with the same results; the estimate reads them without sign-in. Dated examples, not quotes. The Fabric capacity is in none of them: you manage it.

| Profile | Running, per hour | Session | Light-use month | With T4's restart, the nightly safety stop in place (96 hours, $34.18) | With T4's restart, no safety stop (720 hours, $256.32) | Against $375 |
|---|---|---|---|---|---|---|
| `lowest-cost` (the default) | $2.08 | $10.61 | $55.89 | **$90.07** | $312.21 | **Pass** both ways |
| `demo-day` | $2.91 | $14.75 | $83.37 | **$117.55** | $339.69 | **Pass** both ways |
| `enhanced-performance` | $5.07 | $25.53, a **Warning** above $15 | $138.21 | **$172.39** | $394.53 | **Pass** with the safety stop, **Fail** without |

- **No Bastion to deploy:** only the opt-in `PaygWizard` guided stop needs it. The estimate still counts one hour of Bastion and its public IP ($0.195 an hour) in each session and each light-use month (`bastionHoursPerSession` in `config/profiles.json`), for optional interactive access such as T2's missing-index fix; without that hour, `lowest-cost` is $10.42 a session and $55.70 a month.
- **No golden snapshot in these figures:** it's optional in the default mode. Keeping one adds at most about $6.40 a month in the estimate, which prices its 128 GiB provisioned size, and an estimated $2.50 to $3 billed for a `JumpstartImage` host's used size ([the snapshot](#the-t2-golden-snapshot-phase-20)).
- **The nightly safety stop costs nothing more here:** its 120 job minutes a month are within the 500 that Azure Automation includes. Signed in, the estimate and preflight read whether it's in place: its schedule, its role, and its last run. Without sign-in, as here, and in a first deployment's preflight, which runs before it exists, they count the rest of the month, so `enhanced-performance` fails a first preflight against $375 (R668): pick a cheaper profile, set `t4SkuName`, or raise `monthlyCeilingUsd` for that first run.
- **Defender for Cloud and the T3 free offer:** signed in, the estimate reads both and includes them; the owner's kind of configuration with Defender is in the [2026-11-04 example](#dated-example-the-4-vcore-t4-default-and-the-375-ceiling-2026-11-04).

## Dated example: the nightly safety stop (2026-11-05)

Since 2026-11-05, every deployment sets up the nightly safety stop ([ADR 0024](adr/0024-nightly-safety-stop.md)): at the VMs' auto-shutdown time it deallocates both VMs and stops T4 if they run, so a T4 that Azure starts again 7 days after a stop bills at most until that evening. With it in place, the estimate counts T4's restart worst case as about a day per restart, at most 4 a month, 96 hours, instead of the rest of the month ([the rule](#dated-example-the-4-vcore-t4-default-and-the-375-ceiling-2026-11-04)). List prices in USD for West US 3 from `estimate-cost.ps1` on 2026-11-05, unchanged from 2026-11-04; the example configuration, private mode assumed, Defender for Cloud not read, T3 without the free offer, and 10 running hours a month. Dated examples, not quotes:

| Profile | Light-use month | With T4's restart, the nightly safety stop in place (96 hours, $34.18) | With T4's restart, no safety stop (720 hours, $256.32) | Against $375 |
|---|---|---|---|---|
| `lowest-cost` | $55.89 | **$90.07** | $312.21 | **Pass** both ways |
| `demo-day` | $83.37 | **$117.55** | $339.69 | **Pass** both ways |
| `enhanced-performance` | $138.21 | **$172.39** | $394.53 | **Pass** with the safety stop, **Fail** without |

- **What counts as in place:** the schedule `dbhub-safety-stop` enabled and linked to `DbHub-Stop` with Scope `Nightly`, its role "DbHub Demo Safety Stop" assigned on `rg-<prefix>-<env>`, and its last run not failed (`Get-DemoT4RestartCoverage`, read-only). On a first deployment, preflight runs before the safety stop exists, so that one preflight counts the rest of the month, with a **Warning** that says the run sets it up; later preflights, `start-demo.ps1`, and `status.ps1` count it. When an Owner hasn't assigned its role yet, they count the rest of the month, and the fix is `./scripts/grant-safety-stop.ps1`.
- **What it costs itself:** two short Automation jobs a night (the stop, and its T3 check) in `aa-<prefix>-<env>-safetystop`, about 2 to 4 job minutes, more on a night it waits for a starting T4. The estimate counts up to 120 job minutes a month at the Basic Runtime meter's first tier, $0 within the 500 job minutes a month that Azure Automation includes ([pricing](https://azure.microsoft.com/pricing/details/automation/), checked 2026-11-05; rate plans with a flat discount or a fixed monthly credit don't include them). Its user-assigned identity, its Automation account, its schedules, and its custom role have no charge.
- **The control's own daily T4 safety stop** ([below](#the-on-demand-activity-control)) still counts when it's fully in place; with both, the second finds T4 already stopped.

## Dated example: the 4-vCore T4 default and the $375 ceiling (2026-11-04)

Two user-directed changes of 2026-11-04 ([ADR 0016](adr/0016-cost-profiles.md#2026-11-04-user-directed-the-4-vcore-t4-default-and-a-375-ceiling), [ADR 0019](adr/0019-t4-postgresql-flexible-server.md#2026-11-04-user-directed-general-purpose-standard_d4ds_v5-by-default-with-autonomous-tuning)). The figures are dated examples, list prices in USD for West US 3 from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), not quotes; the scripts price live.

- **T4's default size is `Standard_D4ds_v5`** (General Purpose, 4 vCores), with autonomous tuning on (`t4AutonomousTuning`): it runs "on any currently supported compute SKU with at least 4 vCores" ([autonomous tuning](https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning), updated 2026-07-16), on Query Store, and "Don't enable query store on the Burstable pricing tier as it causes performance problems" ([Query Store](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store)). Both pages were checked on 2026-11-04.
- **Its price:** $0.356 an hour while T4 runs (4 vCores at the Ddsv5 vCore meter, $0.089; 2026-11-03), against $0.017 for `Standard_B1ms` and $0.178 for `Standard_D2ds_v5`. Against `Standard_B1ms`, that's **+$0.339 an hour**: about +$3.39 a month at the 10 light-use hours of `config/profiles.json`, or about +$21 at 61 hours (2 hours each weekday plus 4 hours a week). `Standard_D4ads_v5`, the next 4-vCore step of the fallback, is at the same vCore price ($0.089, Dadsv5).
- **T4's 7-day restart:** Azure starts a stopped flexible server again after seven days, and it bills until it's stopped again. The estimate counts that worst case against `monthlyCeilingUsd`:
  - **With a safety stop fully in place**, each restart runs at most until the next safety stop, about a day: at most about 4 restarts a month, about **96 hours**, **$34.18** at `Standard_D4ds_v5`. Since 2026-11-05 that's the [nightly safety stop](#dated-example-the-nightly-safety-stop-2026-11-05) in every deployment: its schedule `dbhub-safety-stop` enabled, its role assigned on `rg-<prefix>-<env>`, and its last run not failed. The on-demand control's daily T4 safety stop counts too, when the `dbhub-t4-safety-stop` schedule exists and is enabled, the control identity's A1 role is assigned on `rg-<prefix>-<env>`, and the last `DbHub-Stop` job didn't fail (on 2026-11-04 it was the only one).
  - **Otherwise** the rest of the month: **720 hours, $256.32** at the 10 light-use hours, with a **Warning** that names the missing piece and its fix (`./scripts/deploy.ps1`, which sets the nightly safety stop up, or an Owner's `./scripts/grant-safety-stop.ps1`). A read that fails counts as missing. `PREFLIGHT.COST.MONTHLY`, `START.COST.*`, and `STATUS.*` say which assumption applies and why.
- **So the default ceiling is $375** (still hard, a **Fail** above it); `sessionCeilingUsd` stays $15. The budget's amount follows `monthlyCeilingUsd`, with its alerts at 50%, 80%, and 100%. An existing environment gets the new budget at its next `./scripts/deploy.ps1 -FromStage Infrastructure` ([update an existing environment](deployment.md#update-an-existing-environment)); a configuration that sets `monthlyCeilingUsd` keeps its value.

The cost check for each case, a light-use month of 10 running hours:

| Case | Light-use month | With T4's restart, the safety stop in place (96 hours) | With T4's restart, no safety stop (720 hours) | Against $375 | Against $250 |
|---|---|---|---|---|---|
| The example configuration (`lowest-cost`, private mode assumed, no Defender plans read, T3 as regular serverless; `estimate-cost.ps1` on 2026-11-04) | $55.89 | $90.07 | $312.21 | **Pass** both ways | **Pass** with the safety stop, **Fail** without |
| The owner's kind of configuration (private mode, the tenant's Defender for Cloud plans, T3 at list price, the T2 golden snapshot; the 2026-11-03 basis [above](#dated-example-business-hours-and-two-optional-upgrades-2026-11-03) at `Standard_D4ds_v5`) | $103.37 | $137.55 | $359.69 | **Pass** both ways | **Pass** with the safety stop, **Fail** without |
| The same at 61.33 running hours a month (2 hours each weekday plus 4 hours a week; 668.67 hours of restart without the safety stop) | $216.24 | $250.42 | $454.29 | **Pass** with the safety stop, **Fail** without | **Fail** both ways |

- **How far $375 goes:** with the safety stop in place, the worst running rate ($2.20 an hour with the 4-vCore T4, T3 at list price, and the Defender plans) leaves about 118 running hours a month: about 59 showcases of 2 billed hours, or about 34 with a day-before baseline each. Without the safety stop, about 18 hours.
- **To stay cheap:** set `t4SkuName` to `Standard_B1ms` (which turns autonomous tuning off: $0.017 an hour, and a restart worst case of about $12 a month), or lower `monthlyCeilingUsd`, and stop the demo between sessions. T4 is part of every deployment since 2026-11-09, so `t4Enabled: false` no longer leaves it out.

## Dated examples (2026-10-21)

From `estimate-cost.ps1` on 2026-10-21 (Phase 16's run): public list prices from the Retail Prices API, West US 3, the `lowest-cost` profile, private network mode, and the subscription's Defender for Cloud plans. They're examples, not quotes; run the estimate yourself for current figures.

| Scenario | Estimate | Of which Defender for Cloud | Ceiling | Status |
|---|---|---|---|---|
| One 5-hour demo-day session | $7.41 | $0.57 | $15 per session | **Pass** |
| A light-use month: idle, plus 10 running hours | $65.12 | $20.97 | $250 per month | **Pass** |
| Not documented: Defender for SQL billing for a disconnected Arc SQL instance | Up to $14.52 a month more (the hourly meter for every idle hour) | All of it | Reported, left out of the totals | **Warning** |

Even with that worst case added, a light-use month stays well below the ceiling. Earlier dated estimates are in the ADR 0016 addenda: [2026-10-20, after Phase 6](adr/0016-cost-profiles.md#phase-6-note-lowest-cost-without-data-disks-and-the-estimates-after-the-merge-2026-10-20), [2026-10-20, with Defender and private mode](adr/0016-cost-profiles.md#phase-5-addendum-microsoft-defender-for-cloud-and-private-mode-2026-10-20), and [2026-10-19](adr/0016-cost-profiles.md#phase-5-addendum-live-estimates-and-the-premium-ssd-v2-evaluation-2026-10-19).

## Dated example: business hours, and two optional upgrades (2026-11-03)

A dated example, not a proposal: no default changes ([ADR 0016](adr/0016-cost-profiles.md)). List prices in USD for West US 3, from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) on 2026-11-03. Run the estimate yourself for current figures.

**The assumption: the demo runs 9 to 5 on weekdays,** 8 hours a day on 22 weekdays, so **176 hours a month**, and it's stopped the rest of the time (the VMs deallocated, T4 stopped, T3 paused).

**The base: $436.98 a month.** That's `./scripts/estimate-cost.ps1 -LightUseHoursPerMonth 176` on the `lowest-cost` profile in private mode, with the subscription's Defender for Cloud plans, T4 on `Standard_D2ds_v5`, and T3 as regular serverless, without the free offer: $2.02 an hour while it runs, times 176 hours, plus $81.23 a month that bills whether it runs or not.

| Component | A month at 176 hours |
|---|---|
| T1: the `Standard_D2s_v5` VM, plus the SQL Server Standard license | About $33 + $70 |
| T2: the `Standard_E2s_v5` host, plus Arc SQL Standard pay-as-you-go (the 4-core minimum) | About $38 + $70 |
| T3: serverless at its 1-vCore maximum while it's awake (the worst case) | About $92 |
| T4: `Standard_D2ds_v5` compute | About $31 |
| Defender for Cloud: its hourly and its monthly plans | About $60 |
| Fixed costs without Defender: the OS disks, T3's and T4's storage, the T2 golden snapshot, the private endpoint, the private DNS zones, and the activity control's Key Vault | About $41 |
| **Total** | **$436.98** |

**Two optional upgrades, on top of the base at 176 hours:**

- **PostgreSQL autonomous tuning (T4):** it runs "on any currently supported compute SKU with at least 4 vCores", on any tier, and analyzes "the workload tracked by query store" ([autonomous tuning](https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning), updated 2026-07-16). The [Query Store page](https://learn.microsoft.com/azure/postgresql/monitor/concepts-query-store) (updated 2026-07-16) says "Don't enable query store on the Burstable pricing tier". So the practical minimum is `Standard_D4ds_v5`: $0.356 an hour against $0.178 for `Standard_D2ds_v5`, **+$31.33 a month**. `Standard_B4ms` is $0.272 an hour, but it's Burstable, so it isn't recommended.
- **SQL Server Enterprise (T1 and T2):** automatic tuning, which includes plan correction, is Enterprise-only in SQL Server 2022 ([editions](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022), updated 2026-10-19).
  - T1: the "SQL Server Enterprise / 1-4 vCPU VM License" meter is $1.50 an hour, against $0.40 for Standard.
  - T2: Arc's "Ent edition - PAYG" is $0.375 a core-hour, against $0.100, times the 4-core minimum: $1.50 an hour against $0.40.
  - Together, **+$387.20 a month**. It would also need T1's Enterprise Marketplace image and Enterprise in T2's guest setup; the demo installs Standard on both.
- **Both upgrades:** about **$855.51 a month**.

**Above the hard ceiling, even without the upgrades.** The **$250** monthly ceiling assumes idle plus light use, 10 running hours a month (`config/profiles.json`). A business-hours schedule needs `monthlyCeilingUsd` raised to about **$450**, or about **$875** with both upgrades, and the budget with it (`deploy.ps1 -FromStage Infrastructure`). Otherwise:

- the monthly check fails when it counts those hours (`estimate-cost.ps1 -LightUseHoursPerMonth 176` reports `PREFLIGHT.COST.MONTHLY` as a **Fail**); preflight's own run counts the 10-hour light-use month;
- the budget's alerts fire at 50%, 80%, and 100% of the ceiling;
- once the month's actual cost reaches the ceiling, `start-demo.ps1` stops starting the demo (`START.COST.ACTUAL` **Fail**) until the next month, unless you raise the ceiling or pass `-SkipCostCheck`.

**Neither upgrade adds a Database Hub visual:** PostgreSQL's tuning recommendations show in the Azure portal, and SQL Server's plan correction in its DMVs (`sys.dm_db_tuning_recommendations`) and SSMS.

## Dated example: one showcase session (2026-11-03)

**Run all** in the control notebook runs the showcase on all four targets, 90 minutes by default and 120 at most ([what fills each Database Hub visual](../README.md#what-fills-each-database-hub-visual-and-when)). List prices in USD for West US 3, from the Azure Retail Prices API on 2026-11-03: examples, not quotes, and no default depends on them ([ADR 0016](adr/0016-cost-profiles.md)).

**Billed time:** a 90-minute run bills about **2 hours**. The VMs start a few minutes after the request, the run lasts 90 minutes, and the run's auto-stop comes 10 minutes after its end, then the VMs deallocate and T4 stops. T3 bills while it's awake, from its first connection to `t3AutoPauseMinutes` (15) after its last session.

| Case | Per running hour | 90-minute showcase (2 hours) | 120-minute showcase (2.5 hours) | Against $15 a session |
|---|---|---|---|---|
| Worst: T4 on `Standard_D2ds_v5`, T3 at list price, the Defender for Cloud plans of the test subscription (Servers P2, SQL servers on machines, CSPM) | $2.02 | **$4.04** | $5.05 | **Pass** |
| T4 on `Standard_D2ds_v5`, T3 within the free offer's allowance, the same Defender plans | $1.50 | $3.00 | $3.75 | **Pass** |
| T4 on `Standard_B1ms`, T3 at list price, the same Defender plans | $1.86 | $3.72 | $4.65 | **Pass** |
| Lowest: T4 on `Standard_B1ms`, T3 within the free allowance, no Defender plans | $1.22 | **$2.45** | $3.06 | **Pass** |

- **T3:** at most about 1.8 hours awake at no more than 1 vCore, so at most about 6,500 vCore-seconds a session, 6.5% of the [free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer)'s 100,000 a month: about 15 sessions fit in it when nothing else wakes T3. Past the allowance, T3 bills at list price and stays available (`BillOverUsage`).
- **Azure Automation:** a run's `DbHub-Control` job takes 2 to 20 minutes with its waits, and `DbHub-Stop` 1 to 3, inside the first 500 job minutes a month, which are included: about 25 to 50 sessions a month. Past them, about $0.04 a session.
- **Three back-to-back 120-minute runs:** about 6.5 billed hours, $13.13 at worst, still under $15.
- **A day-before baseline** of 60 minutes, for Database Hub's **CPU spikes** ([the baseline run](../README.md#the-baseline-run-why-it-matters-and-when-it-doesnt)): about 1.4 billed hours, $1.71 to $2.83.
- **The month:** with T4 on `Standard_D2ds_v5`, the demo bills about $81 a month whether it runs or not ([above](#dated-example-business-hours-and-two-optional-upgrades-2026-11-03)), so the **$250** hard ceiling covers about 83 running hours at the worst rate: about 40 showcases a month, or about 24 with a day-before baseline each.
- **Outside the ceilings:** the control notebook and its live view use the Fabric capacity's units ([below](#microsoft-fabric-capacity)); Database Hub itself needs no capacity, except for alert rules.

## The T2 golden snapshot (Phase 20)

The fast redeploy keeps one incremental snapshot of the T2 host's OS disk in `rg-<prefix>-golden` ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)); there's no storage account. It bills every month it exists, whether the demo runs or not, until `destroy.ps1 -IncludeGolden` deletes it. Since 2026-11-05 it's optional in the default `JumpstartImage` mode, where it only speeds up a redeploy ([below](#t2s-jumpstartimage-mode-2026-11-05)).

- **How it's priced:** incremental snapshots are stored as Standard HDD (LRS or ZRS) and billed for their used size, which only the usage report shows ([incremental snapshots](https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots)). `estimate-cost.ps1`, preflight's monthly check, and `start-demo.ps1`'s guardrail read the snapshot's meter from the Retail Prices API at run time and price the **provisioned** size, an upper bound, so the hard ceiling never underestimates; the component's name shows the used size. `status.ps1`'s month-to-date figure adds the golden group's actual cost.
- **Dated example (2026-10-22):** West US 3 listed Standard HDD LRS snapshots at $0.05 per GB-month. The owner's snapshot is 128 GiB provisioned, about 37 GiB used: at most about **$6.40 a month** in the estimate, about **$1.85 a month** billed for the used size. That was a `PaygWizard` host.
- **A `JumpstartImage` host (an estimate, not measured):** its OS disk also holds the Jumpstart image (34 GiB when it's downloaded, and the guest grows it), so its snapshot uses more: an estimated 50 to 60 GiB, about **$2.50 to $3 a month** at the same $0.05 per GB-month (the list price on 2026-11-05 too). The estimate still prices the 128 GiB provisioned size, at most about $6.40.

## T2's JumpstartImage mode (2026-11-05)

The default `t2SqlInstallMode` since 2026-11-05 makes T2's guest from Arc Jumpstart's prebuilt SQL Server 2022 Standard image instead of building it ([ADR 0006](adr/0006-sql-editions-and-licensing.md)). Its effect on cost, in dated examples: list prices in USD for West US 3 from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) on 2026-11-05, not quotes.

- **No new Azure resource:** the guest's disk is a file on the T2 host's existing OS disk (`lowest-cost`: the E10 Standard SSD, $9.60 a month, which T2 had before), or on its data disk in the larger profiles. There's no storage account, and no new meter.
- **The download is free:** the image is about 34 GiB, and data transfer into Azure is $0.00 per GB ("Standard Data Transfer In"). Writing it is about 140,000 disk operations on the Standard SSD, about **$0.03** at $0.002 per 10,000.
- **SQL Server is billed as before:** Arc pay-as-you-go Standard, $0.10 per core-hour at the 4-core minimum ($0.40 an hour while T2 runs), as in `PaygWizard` mode; `estimate-cost.ps1` prices both modes the same. Arc Jumpstart's own automation sets license type Paid (Software Assurance); this demo sets PAYG, which needs no entitlement.
- **No Bastion to deploy:** Bastion Basic is $0.19 an hour and its Standard public IP $0.005 an hour, about **$0.20 an hour** together. A `PaygWizard` guest build used it for about an hour at the guided stop; `JumpstartImage` doesn't. `estimate-cost.ps1` still counts one Bastion hour per session (`bastionHoursPerSession` in `config/profiles.json`) for optional interactive access, such as T2's missing-index fix.
- **The golden snapshot is optional** ([above](#the-t2-golden-snapshot-phase-20)): skip it, and a redeploy downloads and prepares the image again in T2's host build, which took about 27 minutes on 2026-11-06, with no person needed.
- **The estimate with the example configuration** (now `JumpstartImage`; `lowest-cost`, private mode assumed, no Defender plans read, T3 as regular serverless; `estimate-cost.ps1` on 2026-11-05): $2.08 an hour while it runs, $0.20 an hour for Bastion, **$10.61** for a 5-hour session with one Bastion hour, and **$55.89** for a light-use month, the same as on 2026-11-04 ([every profile, with T4's restart](#dated-example-the-default-deployment-2026-11-05)).

## Microsoft Fabric capacity

The notebooks need the Fabric workspace on an F or Trial capacity (prerequisite P5), and so do the Real-Time Dashboard and the Power BI report of the presentation layer (Phases 18 and 19, in progress). Database Hub itself doesn't ([licenses](https://learn.microsoft.com/fabric/enterprise/licenses)).

- **Outside the demo's ceiling:** the capacity is a prerequisite that the workspace administrator owns, often shared with other workspaces. The demo's estimates, budget, and ceilings don't include it.
- **Dated example (2026-10-21):** the owner's workspace runs on an F16, 16 capacity units at the West US 3 list price of $0.18 per capacity-unit hour from the Retail Prices API: about **$2.88 an hour**, $69 for each day it runs, and about $2,100 for a month left running (730 hours).
- **Pause it when no workspace needs it.** Pausing saves its cost; at the pause, any remaining overages and smoothed operations are added to the bill, and "resuming your capacity also resumes billing" ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)). While it's paused, notebook imports and runs report **Manual action required** with the resume steps.
- **The demo never pauses, resumes, or scales it:** that's the capacity administrator's decision, here the owner's.
- **Power BI viewer licenses:** on F SKUs smaller than F64, such as the owner's F16, every viewer of Power BI content needs a Pro, Premium Per User, or individual trial license ([licenses](https://learn.microsoft.com/fabric/enterprise/licenses)). They're outside the demo's ceiling too; a presenter who shares their screen needs only their own.
- **The Insights app (Phase 19b):** "Fabric Apps services consume capacity units from the assigned capacity" ([Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview)). The app has no database, storage, or functions; it uses capacity when it's deployed, loaded, and queried (each visual's DAX runs on the model). Since 2026-11-05 every `deploy.ps1` deploys and checks it, so each deployment uses some of the capacity's units for it. That's outside the demo's ceiling, like the rest of the capacity, which you manage, and `estimate-cost.ps1` doesn't include it.
- **The history report's snapshot (2026-11-06):** every `deploy.ps1` that passes **DONE**'s checks runs `NB_DatabaseHub_LiveActivity` once more at its end, analyze-only, and refreshes the history model once ([deployment](deployment.md#the-history-reports-snapshot-at-the-end-2026-11-06)). That's a Spark session and the analysis, about 2 to 5 minutes and at most 10, plus one refresh, so each deployment uses some more of the capacity's units, outside the demo's ceiling, and `estimate-cost.ps1` doesn't include it. A paused capacity isn't resumed for it: the snapshot is a **Warning** that says so, and the run still ends **DONE**.

## The on-demand activity control

Optional (`control.enabled`; [ADR 0020](adr/0020-on-demand-activity-control.md)). Its resources in `rg-<prefix>-control` outlive destroy, so they bill until `setup-activity-control.ps1 -Remove` deletes them:

- **Key Vault (Standard):** billed per 10,000 operations; a run reads the one secret once. The estimate adds one block of operations a month, from the vault's `Operations` meter.
- **Azure Automation (Basic):** billed per job minute after the first 500 a month, which are included; a run's jobs take a few minutes. The estimate prices 60 job minutes a month at the meter's first tier, so it's $0 while you stay under 500.
- **The webhook, the schedules, the identity, and role assignments** have no charge. Managed private endpoints and managed virtual networks in Fabric have no separate meter in the Retail Prices API (checked 2026-10-23); the control notebook uses the capacity's units while it runs, like any notebook.
- **What a run costs** is the demo's own running time, the VMs and T4 for the run's minutes, which the session estimate already covers; the auto-stop ends it 10 minutes after the run, and the nightly safety stop, in every deployment, and the control's daily T4 safety stop catch a forgotten T4.
- `estimate-cost.ps1` reads both meters from the Retail Prices API at run time when `control.enabled` is true; no price is hard-coded.

## Run an estimate

```powershell
./scripts/estimate-cost.ps1 -AllProfiles -Detailed
./scripts/estimate-cost.ps1 -NetworkMode private   # the mode preflight resolved
```

- The Azure Retail Prices API is public, so the estimate itself needs no sign-in.
- **Defender for Cloud and the T3 free offer:** when the subscription guard passes (you're signed in to the configured tenant with access to the subscription), the script also reads the subscription's Defender plans (`az security pricing list`, read-only) and whether the free offer is available, and includes them. Otherwise it reports a Warning that the estimate excludes Defender and prices T3 as regular serverless. It never signs in.
- **Network mode:** pass `-NetworkMode` with the mode preflight resolved (the `effectiveNetworkMode` evidence of `PREFLIGHT.POLICY.SQLPUBLIC`). With `networkMode` `auto` and no `-NetworkMode`, the estimate assumes private, the more expensive mode, and says so.
- **T4's size:** the script prices the configuration as written: `t4SkuName`, or `Standard_D4ds_v5` (the default since 2026-11-04) when it isn't set. It doesn't read what T4's fallback recorded in the resource group. `deploy.ps1` (its preflight's `PREFLIGHT.T4.FALLBACK` and `PREFLIGHT.COST.*`, and its template step) and `start-demo.ps1`'s guardrail price the size the fallback chose; a standalone `./scripts/preflight.ps1` doesn't read the record either, so it prices an existing server's own size, or the configuration with the General Purpose step ahead. To see another size's price here, run it with a copy of the configuration that sets `t4SkuName` to that size, for example `Standard_D2ds_v5` or `Standard_B1ms`.

## Summary

- **Ceilings:** a **hard** $375 a month for idle plus light use, and $15 per demo-day session ([ADR 0016](adr/0016-cost-profiles.md)). A light-use month above `monthlyCeilingUsd`, with T4's restart worst case, is **Fail** in preflight and `estimate-cost.ps1`; pick a cheaper profile or options, or raise `monthlyCeilingUsd`. A session above `sessionCeilingUsd` is a **Warning**. *(User-directed on 2026-10-20, from $75 to $250, and on 2026-11-04, from $250 to $375, for the 4-vCore T4 default and its restart worst case.)*
- **Defaults:** every default is the cheapest working option except T4's size (`Standard_D4ds_v5`, user-directed on 2026-11-04 for autonomous tuning), starting with the `lowest-cost` profile, which has no separate data disks: the OS disks hold SQL Server data on T1 and, on the T2 host, the guest's disk (in the default `JumpstartImage` mode Arc Jumpstart's image, about 34 GiB when downloaded; in the build modes a VHDX and the installation media) (`dataDiskSku` `None`; set `E10` to add data disks).
- **Profiles:** `lowest-cost`, `demo-day`, and `enhanced-performance`. The T2 host size drives most of the compute cost.
- **Estimates:** `scripts/estimate-cost.ps1` prices every profile from the Azure Retail Prices API at run time. It includes the `Global` meters for SQL Server and Arc licenses, and for meters published only there (Defender for Cloud, the private endpoint, and the NAT gateway). Arc SQL Standard is billed per core-hour (example list price $0.10 per core-hour, 2026-10-19). Microsoft Learn documents a minimum of four cores per operating system environment (manage-license-billing, checked 2026-10-20), so the billable core count defaults to the larger of the guest's vCPU count and 4: the 2-vCPU guest is estimated at 4. The parameter `t2ArcBillableCores` overrides it, and `configure-arc.ps1` records the instance's cores as evidence (ADR 0006, Phase 7 notes). No price in this repo is hard-coded; figures in docs are labeled as dated examples.
- **What bills while stopped:** managed disks, Azure SQL storage, the private endpoint and private DNS zone in private mode, Defender for Azure SQL and Defender CSPM for the T3 server where those plans are on, the optional [T2 golden snapshot](#the-t2-golden-snapshot-phase-20) when you keep one (also after destroy), and anything left on demand: Bastion and its public IP. Outside the ceiling, the [Fabric capacity](#microsoft-fabric-capacity) bills until it's paused.
- **Guardrails C1–C11:**
  - No Key Vault by default (C1); the [opt-in vault](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard) for the one-time host password needs `assignRoles`.
  - A budget with alerts at 50%, 80%, and 100% of `monthlyCeilingUsd`.
  - Scheduled start and stop windows with warm-up.
  - An expiry tag with scheduled destroy, and "park T2".
  - Opt-in Spot and Azure Hybrid Benefit.
  - T3 auto-pause at 15 minutes, and the Azure SQL Database free offer by default when preflight finds it available (otherwise regular serverless, with a Warning).
  - Automatic Bastion removal.
  - The nightly safety stop in every deployment (since 2026-11-05, [ADR 0024](adr/0024-nightly-safety-stop.md)): at the VMs' auto-shutdown time it deallocates both VMs and stops T4, and then checks that T3 paused ([what stops or pauses on its own](../README.md#what-stops-or-pauses-on-its-own)).
  - C9, the Cool-tier artifact cache, was dropped on 2026-10-20 (tenant policies and Defender for Storage cost); there's no storage account.
  - Premium SSD v2 data disks for `demo-day` and `enhanced-performance` when `zone` is set (C10). Without a zone they use Standard SSD (E10); Premium SSD P10 is only an explicit `dataDiskSku` opt-in. `estimate-cost.ps1` prices the same tiers as the template.
  - Month-to-date spend in `status.ps1`.

## Microsoft Defender for Cloud

Tenant policies can turn Defender plans on; preflight reports that as `PREFLIGHT.POLICY.DEFENDER`. Only plans on the Standard tier count. The billing basis comes from Microsoft's documentation:

| Plan | Demo resources | Billed |
|---|---|---|
| Defender for Servers (P1 or P2) | T1, the T2 host, and the Arc machine `arcsql01` | Azure VMs while they aren't deallocated; Arc machines only while Connected ([Defender for Servers FAQ](https://learn.microsoft.com/azure/defender-for-cloud/faq-defender-for-servers)) |
| Defender for SQL servers on machines | The T1 and Arc SQL instances | While they run. Billing for a disconnected Arc SQL instance isn't documented, so the worst case is reported but left out of the totals. |
| Defender for Azure SQL | The T3 server | All month |
| Defender CSPM | T1 and the T2 host, the T3 server, and the T4 server | VMs while not deallocated, database servers all month (a stopped T4 too); Arc machines aren't billable ([Defender CSPM](https://learn.microsoft.com/azure/defender-for-cloud/concept-cloud-security-posture-management)) |
| Defender for open-source relational databases | The T4 server (PostgreSQL) | Per server per month, stopped or not ([Defender for open-source relational databases](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-databases-introduction)) |
| Defender for Storage | None | Nothing: the deployment creates no storage accounts ([Defender for Storage](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction)) |
| Defender for Resource Manager and other subscription-wide plans | Not attributed to the demo | Excluded |

New Defender Workload Unit meters took effect on 2026-10-01. Microsoft doesn't publish how many units each plan uses, so the estimate uses the per-plan meters, and the invoice may show the new meters instead.

## Azure SQL (T3): free offer and lifecycle

- **Free offer:** by default (`t3FreeOffer: auto`), T3 uses the [Azure SQL Database free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer) with "continue using database for additional charges", so it never pauses for the limit. Preflight checks that the offer is available (`PREFLIGHT.T3.FREEOFFER`). When it isn't, T3 uses regular General Purpose serverless and the estimate prices it that way. In the owner's subscription it isn't available in West US 3, because the subscription's free databases are in East US and the first free database fixes the region, so T3 runs as regular serverless there (live, 2026-10-20 and 2026-10-21).
- **While T3 exists**, Defender for Azure SQL, Defender CSPM, and the private endpoint bill all month, even when T3 is paused: about 27 USD a month in this tenant (example list prices, West US 3, 2026-10-20).
- **To stop that charge** between demos, run `stop-demo.ps1 -RemoveT3`. The next `start-demo.ps1` or warm-up recreates T3 with the same names, and warm-up checks that its telemetry arrives before it reports T3 ready.
- **Keep T3** for agent-focused demos and for multi-day baseline-versus-incident demos. A newly created T3 may show Hub posture findings and Database Agent findings late, and Azure SQL Database is the most likely Database Agent target. The owner's rehearsal measures that lag (ADR 0016).

## Activity profiles: business-day (Phase 28 follow-up)

`business-day` is the default activity profile since 2026-11-03 ([ADR 0010](adr/0010-workload-generator-technology.md#activity-profiles-business-day-by-default-2026-11-03)). What that changes in the estimate:

- **T3 is the resource whose bill follows the load.** Its two incidents an hour, `resource-governance` at :15 and `log-rate-pressure` at :45, 5 minutes each, drive the serverless database to its maximum vCores. Serverless bills each second for the larger of the CPU and the memory used, never above the maximum vCores ([serverless compute tier](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-overview)). The VMs, their SQL Server licenses, Arc's per-core billing, Defender for Cloud, and a provisioned T4 bill by the running hour, whatever the load. Two small amounts follow the load too and are in no estimate, for any profile: Standard SSD disk operations and T3's backup storage (below).
- **How the estimate counts it:** T3's running hour is priced at its maximum vCores times `t3ActiveShareOfMaxVcores` (`config/profiles.json`). With `business-day`, the estimate adds the incidents' minutes, 10 of every 60 from `scenarios/activity-profiles.json`, at the maximum for the part of the hour that share leaves out: maximum × (1 - share) × 10/60 vCore-hours per running hour, at the serverless vCore meter that the Retail Prices API gives at run time. The shipped share is 1.0, so the estimate already prices T3 at its maximum for every running hour: the increment is 0, and the session and month estimates and both ceiling checks are unchanged. `PREFLIGHT.COST.SESSION` and `PREFLIGHT.COST.MONTHLY` say so ("they add nothing"), with `activityProfile`, its source, and the increment in their evidence. With a lower share, a component "T3 compute, business-day incidents" adds the increment to both checks.
- **The free offer's allowance:** the incidents use the 100,000 vCore-seconds a month faster ([free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer)); the estimate already counts T3 at its maximum against it. A light-use month, 10 running hours at the `lowest-cost` maximum of 1 vCore, uses 36,000 vCore-seconds.
- **Where it's checked:** preflight (`PREFLIGHT.COST.*`, which `deploy.ps1` runs), `start-demo.ps1`'s guardrail (`START.COST.*`, unless `-SkipCostCheck`) with its `-ActivityProfile`, and `estimate-cost.ps1`, each with the configured profile, or `business-day` for a configuration without `activityProfile`, which the run says once (`*.ACTIVITYPROFILE`) without changing the configuration.
- **Dated examples, unchanged by an increment of 0:** a 5-hour `lowest-cost` session at $7.41 and a light-use month at $65.12 ([2026-10-21](#dated-examples-2026-10-21)); with T4 on `Standard_D2ds_v5`, the live preflight of 2026-11-02 found $10.30 for a session against $15, and $223.38 for the month against $250, both **Pass** ([implementation report](implementation-report.md)). They're examples; the scripts always price live.
- **The check for the new default (a dated estimate: 2026-11-03, West US 3, list prices from the Azure Retail Prices API):** `Get-DemoCostEstimate`, for `lowest-cost` with private networking, T3 as regular serverless, and all five Defender for Cloud plans the estimate attributes on Standard (a worst case), gives the same figures for `baseline` and `business-day`:

  | T4 size | Session (5 hours) | Light-use month (10 hours) | Month as the ceiling check counts it (with T4's 7-day restart) |
  |---|---|---|---|
  | `Standard_B1ms` (the default) | $9.49 | $93.58 | $105.82 |
  | `Standard_D2ds_v5` (the fallback) | $10.30 | $95.19 | $223.35 |

  Both are **Pass** against $15 and $250. Without Defender plans, `Standard_B1ms` gives $8.92 and $52.50 ($64.74 with T4's restart).
- **What no estimate counts, at most (the same dated estimate: 2026-11-03, West US 3, Azure Retail Prices API):** T3 between its 0.5-vCore minimum and its 1-vCore maximum for the incidents' 10 minutes an hour is 0.0833 vCore-hours an hour at $0.521758, about $0.04 an hour; T2's E10 OS disk under `io-pressure`, 8 minutes an hour at the disk's 600-IOPS burst limit, is 288,000 operations at $0.002 per 10,000, about $0.06 an hour, an upper bound because Standard SSD transactions are billed up to an hourly cap ([Standard SSD transactions](https://learn.microsoft.com/azure/virtual-machines/disks-types#standard-ssd-transactions)); and T3's backups add nothing, because `log-rate-pressure` writes at most 2,048 MB of log an hour (its `maxLogMb`) and backup storage up to the database's 32 GB maximum size is free ([backup storage costs](https://learn.microsoft.com/azure/azure-sql/database/automated-backups-overview#backup-storage-costs)). Together at most $0.51 a session and $1.01 a light-use month, so the worst case above stays within both ceilings: $10.81 of $15 and $224.36 of $250.
- **Bounded by the schedule:** the incidents run only while a profile runs, which ends 2 minutes before the next auto-shutdown; `stop-demo.ps1` turns every profile off and deallocates the VMs, and T3 then auto-pauses `t3AutoPauseMinutes` after its last session.

## Azure Database for PostgreSQL (T4, Phase 24)

Since 2026-11-04, T4's default is General Purpose `Standard_D4ds_v5` (4 vCores), the smallest size that autonomous tuning supports, at the owner's direction ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md); [the dated example](#dated-example-the-4-vcore-t4-default-and-the-375-ceiling-2026-11-04)). When `t4SkuName` isn't set and Azure refuses it with `SkuNotAvailable`, `deploy.ps1` retries in another zone, then tries `Standard_D4ads_v5` (4 vCores), then `Standard_D2ds_v5` with autonomous tuning off, after [its cost check](#the-general-purpose-fallbacks-cost-check-phase-28-follow-up), which only reports since 2026-11-09; it records the size (`DbHubT4Size`). Since 2026-11-09 (user-directed) a `t4SkuName` you set that Azure refuses falls back too, to the next size Azure accepts, cheapest first, and the notice (`DEPLOY.T4.FALLBACK`, then `STATUS.T4.SIZE`) gives T4's monthly estimate at the size asked for and at the size created, light use and worst case, with the difference. An existing server whose size the configuration doesn't set, and no record keeps, moves to the default at the next `deploy.ps1`, which restarts it (`DEPLOY.T4.SIZE`), once the move's own cost check at that size passes: over either ceiling, or without a price, it keeps its size, and the check names the ceiling to raise. A larger `t4SkuName` you set on an existing server is priced the same way first. `Standard_B1ms` and `Standard_B2s` (Burstable), the defaults before, are still valid sizes to set, with autonomous tuning off. Before 2026-11-04, `t4SkuName` was `Standard_B1ms` by default, with `Standard_B2s` and then `Standard_D2ds_v5` as the fallbacks when Azure refused it, as West US 3 did from 2026-10-26 on. `estimate-cost.ps1`, preflight, and `start-demo.ps1`'s guardrail price the configured or recorded size from the Retail Prices API at run time; the figures below are a dated example (list prices, West US 3, 2026-10-23 and 2026-10-26), not a quote.

| Part | Billed | Example |
|---|---|---|
| Compute, General Purpose D4ds_v5 (the default since 2026-11-04) | Only while it runs (`start-demo.ps1` to `stop-demo.ps1`); 4 vCores at the vCore meter | $0.356 an hour (4 × $0.089, 2026-11-03) |
| Compute, General Purpose D4ads_v5 (the 4-vCore fallback) | Only while it runs; 4 vCores at the Dadsv5 vCore meter | $0.356 an hour (4 × $0.089, 2026-11-03) |
| Compute, General Purpose D2ds_v5 (the last fallback, tuning off) | Only while it runs; 2 vCores at the vCore meter | $0.178 an hour (2 × $0.089) |
| Compute, Burstable B1ms (set it to stay cheap; tuning off) | Only while it runs | $0.017 an hour |
| Compute, Burstable B2s (tuning off) | Only while it runs | $0.068 an hour |
| Storage, 32 GiB | All month, stopped or not | $3.68 a month |
| Backup storage | Free up to the provisioned storage size (7-day retention, no geo-redundancy) | $0 |
| Its private DNS zone | All month | $0.50 a month |
| Defender for open-source relational databases (enabled by a tenant policy) | All month, stopped or not | $15 a month |
| Defender CSPM (enabled by a tenant policy) | All month, stopped or not | About $5.11 a month |

- **Fixed monthly cost:** about $24.30 while T4 exists, whatever it does and whatever its size (`T4FixedMonthly` in the estimate). The estimate's monthly message names it, and it's in the light-use total.
- **The 7-day restart:** a stopped flexible server starts on its own after seven days ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server): "Server will be automatically started after 7 days"; the [overview](https://learn.microsoft.com/azure/postgresql/overview): "The server remains stopped for seven days unless you restart it sooner") and bills compute until it's stopped again. The estimate counts the worst case at the configured size against the hard monthly ceiling (`T4AutoRestartWorstCaseMonthly`). Since 2026-11-04, when a safety stop is fully in place, each restart counts as about a day, until the next safety stop: at most about 4 a month, 96 hours ($34.18 for D4ds_v5 at the example prices). Since 2026-11-05 that's the [nightly safety stop](#dated-example-the-nightly-safety-stop-2026-11-05) in every deployment (its schedule enabled, its role on `rg-<prefix>-<env>`, and its last run not failed), or the on-demand control's daily T4 safety stop (Phase 25c, approved 2026-10-26: its schedule enabled, the control identity's A1 role on `rg-<prefix>-<env>`, and the last `DbHub-Stop` job not failed). Otherwise it counts the rest of the month, 720 hours at 10 light-use hours ($256.32 for D4ds_v5, about $128 for D2ds_v5, and about $12 for B1ms), with a **Warning** that names the missing piece and its fix; a read that fails counts as missing ([the dated example](#dated-example-the-4-vcore-t4-default-and-the-375-ceiling-2026-11-04)). `stop-demo.ps1` (`STOP.T4.STOP`) and `status.ps1` (`STATUS.T4`) give the date and time Azure starts it again, the stop time plus seven days, with what it then bills at its size from the Retail Prices API, and what stops it again (`Get-DemoT4RestartStopState`): the nightly safety stop when it's in place, at its first run after the restart, which since 2026-11-09 can be its T3 check that evening (when the restart comes between the stop and the check) or else the next evening's stop, named with its time ([ADR 0024](adr/0024-nightly-safety-stop.md#amendment-link-scopes-read-one-by-one-and-t4-at-the-t3-check-2026-11-09)); otherwise the control's daily safety stop, read from its schedule as `CONTROL.SAFETYSTOP` reads it; otherwise nothing, so they say what's missing (its role, with `./scripts/grant-safety-stop.ps1`, or `./scripts/deploy.ps1`) and to run `stop-demo.ps1` again once it has started (Phase 28 follow-up). `status.ps1` warns a day before. The worst case stays about a day per restart: the T3 check's own stop sets the next restart just after the next week's check, which then waits for the following evening's stop.
- **The size changes on its own only when Azure refuses it, or once for a server that predates the 4-vCore default:** without `t4SkuName`, the fallback moves from `Standard_D4ds_v5` to another zone, then to `Standard_D4ads_v5` (the same price), then to `Standard_D2ds_v5` (half) with autonomous tuning off, after [its cost check](#the-general-purpose-fallbacks-cost-check-phase-28-follow-up), and the estimate prices the size that was recorded. An existing server that the configuration doesn't size, and no record keeps, moves to `Standard_D4ds_v5` at the next `deploy.ps1` (a restart, `DEPLOY.T4.SIZE`), and `PREFLIGHT.T4.SIZE` says so first. A size you set that Azure refuses falls back too since 2026-11-09, and the estimate then prices the size the fallback created; when only that size puts the month over `monthlyCeilingUsd`, and the month would fit at the size you set, `PREFLIGHT.COST.MONTHLY` is a **Warning** that names the amount instead of a **Fail**, and so is `monthlyCeilingUsd` at exactly 250 (`init.ps1`'s default from 2026-10-27 to 2026-11-04) when only T4's default puts the month over it and `Standard_B1ms` would fit. The budget keeps alerting at the configured value, and `start-demo.ps1` stops starting the demo once the month's actual cost reaches it.
- **Not optional (2026-11-09, user-directed):** T4 is part of every deployment and of the estimate; `t4Enabled: false` is ignored, with a note. To remove an existing T4, delete `pgflex01-<deploymentId>` and its private DNS zone, or run `destroy.ps1`. If T4 was ever attempted (as on 2026-10-26, when Azure refused its size), its private DNS zone and virtual network link stay in the group while T4 is off, about $0.50 a month that the estimate leaves out with T4; `destroy.ps1` removes them with the group ([cleanup](cleanup.md)).
- **Not added:** a Log Analytics workspace for a Real-Time Dashboard page ($0 to $2.30 a month after the free 5 GB, with a 2 to 10 minute delay) and a T4 history export are follow-ups, not part of the estimate.

### The General Purpose fallback's cost check (Phase 28 follow-up)

When `t4SkuName` isn't set and Azure refuses both 4-vCore sizes with `SkuNotAvailable` (`Standard_D4ds_v5`, in another zone too, and `Standard_D4ads_v5`; both Burstable sizes before 2026-11-04), `deploy.ps1` prices `Standard_D2ds_v5`, with autonomous tuning off, right before it would create it, and creates it only when both ceilings hold ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md#2026-11-02-the-general-purpose-fallback-phase-28-follow-up)):

- **The price:** the demo's estimate with T4 at `Standard_D2ds_v5`, from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) at that moment (the same estimate as `estimate-cost.ps1`), never a number in the code (ADR 0016).
- **The month:** the worst case after Azure starts a stopped server again after seven days: about a day per restart when a safety stop is fully in place (the nightly safety stop since 2026-11-05, or the control's daily T4 safety stop), otherwise T4 running for the rest of the month (since 2026-11-04; every hour of the month before), plus its storage, its private DNS zone, and, where the subscription's Defender plans are on Standard (what a tenant policy enforces, `PREFLIGHT.POLICY.DEFENDER`), Defender for open-source relational databases and Defender CSPM. With the rest of the demo's light-use month, it must be within `monthlyCeilingUsd` ($375 by default since 2026-11-04).
- **The session:** a demo-day session with T4 at that size must be within `sessionCeilingUsd` ($15 by default).
- **What isn't priced:** anything the API has no price for is named in the result and left out of the totals; so are the Defender plans when they couldn't be read. Without a compute price, nothing is created.
- **Over a ceiling, or no price:** since 2026-11-09 T4 is created anyway, because it's part of every deployment, and `DEPLOY.T4.SKU` is a **Warning** that names the ceiling and the value to raise it to.
- **Within both:** T4 is created as `Standard_D2ds_v5`, and the console, the status page, and **DONE** say so: `T4 created as General Purpose Standard_D2ds_v5 (2 vCores) because Azure refused the 4-vCore sizes here, so autonomous tuning is off (it needs 4 vCores); about <price> USD an hour while running ...`, with the price the check read. **DONE** and **NOT DONE** say "created" only once the server exists; when its creation failed for another reason, they say the fallback chose `Standard_D2ds_v5` but T4 isn't created yet, and the next `deploy.ps1` prices it again before it creates it.
- **After the T3 free offer is rejected:** the check counted the free offer's allowance, so it runs again without it before T4 is created. When the rejected attempt has already created the server (it depends only on the network), it isn't priced again: it exists and bills, so it keeps its size and the record, and `DEPLOY.T4.SKU` says its check counted the free offer's allowance.
- **Preflight:** `deploy.ps1`'s preflight prices the same step ahead (`PREFLIGHT.T4.FALLBACK`): a **Pass** when it would fit, otherwise a **Warning** that T4 would be left out and why. When the fallback already starts there (a record, which only `deploy.ps1`'s preflight reads, or a region that lists neither Burstable size), its estimate is the run's own `PREFLIGHT.COST.*`, without T4 when it doesn't fit. When the fallback's own estimate can't be read (the API throttled it, for example), `PREFLIGHT.T4.FALLBACK` is a **Warning** (`skipReason` `Price`) and the run's own `PREFLIGHT.COST.*` stand, a monthly-ceiling **Fail** included.

Dated example (list prices, West US 3, 2026-10-26): with `Standard_D2ds_v5`, a 5-hour session came to $10.30 and the light-use month, its worst case included, to $229.75, within the default ceilings, so the check would pass with those prices. Preflight's check in West US 3, with prices read live on 2026-11-02, came to about $0.178 an hour for T4, $154.23 for T4's worst-case month, $223.38 for the demo's month against $250, and $10.30 for a session against $15: a **Pass**. Your region's and your day's prices decide.

## Disks switched to Standard HDD by the subscription's automation

The estimate prices each profile's disk tiers (E10 Standard SSD OS disks for `lowest-cost`). On 2026-10-24 an application identity that isn't the demo's switched both demo VMs' OS disks to Standard HDD while the VMs were deallocated. A Standard HDD disk lists for less than the same size of Standard SSD, so the invoice can come in under the estimate; the cost is performance: slower boots and IO, and IO-heavy scenarios that look worse. `deploy.ps1` keeps the current type (`DEPLOY.DISKS.DRIFT` **Warning**) and `status.ps1` reports it (`STATUS.DISKS`); changing a disk back is the subscription owner's call ([change a disk's type](https://learn.microsoft.com/azure/virtual-machines/disks-convert-types), R440).
