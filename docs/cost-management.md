# Cost management

The demo's own resources stay below a hard **$250 a month** for idle plus light use, and a demo-day session should stay below **$15**. Every default is the cheapest option that works. No price in this repo is hard-coded: estimates come from the Azure Retail Prices API at run time, and every figure in the docs is a dated example ([ADR 0016](adr/0016-cost-profiles.md)).

## Dated examples (2026-10-21)

From `estimate-cost.ps1` on 2026-10-21 (Phase 16's run): public list prices from the Retail Prices API, West US 3, the `lowest-cost` profile, private network mode, and the subscription's Defender for Cloud plans. They're examples, not quotes; run the estimate yourself for current figures.

| Scenario | Estimate | Of which Defender for Cloud | Ceiling | Status |
|---|---|---|---|---|
| One 5-hour demo-day session | $7.41 | $0.57 | $15 per session | **Pass** |
| A light-use month: idle, plus 10 running hours | $65.12 | $20.97 | $250 per month | **Pass** |
| Not documented: Defender for SQL billing for a disconnected Arc SQL instance | Up to $14.52 a month more (the hourly meter for every idle hour) | All of it | Reported, left out of the totals | **Warning** |

Even with that worst case added, a light-use month stays well below the ceiling. Earlier dated estimates are in the ADR 0016 addenda: [2026-10-20, after Phase 6](adr/0016-cost-profiles.md#phase-6-note-lowest-cost-without-data-disks-and-the-estimates-after-the-merge-2026-10-20), [2026-10-20, with Defender and private mode](adr/0016-cost-profiles.md#phase-5-addendum-microsoft-defender-for-cloud-and-private-mode-2026-10-20), and [2026-10-19](adr/0016-cost-profiles.md#phase-5-addendum-live-estimates-and-the-premium-ssd-v2-evaluation-2026-10-19).

## The T2 golden snapshot (Phase 20)

The fast redeploy keeps one incremental snapshot of the T2 host's OS disk in `rg-<prefix>-golden` ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)); there's no storage account. It bills every month it exists, whether the demo runs or not, until `destroy.ps1 -IncludeGolden` deletes it.

- **How it's priced:** incremental snapshots are stored as Standard HDD (LRS or ZRS) and billed for their used size, which only the usage report shows ([incremental snapshots](https://learn.microsoft.com/azure/virtual-machines/disks-incremental-snapshots)). `estimate-cost.ps1`, preflight's monthly check, and `start-demo.ps1`'s guardrail read the snapshot's meter from the Retail Prices API at run time and price the **provisioned** size, an upper bound, so the hard ceiling never underestimates; the component's name shows the used size. `status.ps1`'s month-to-date figure adds the golden group's actual cost.
- **Dated example (2026-10-22):** West US 3 listed Standard HDD LRS snapshots at $0.05 per GB-month. The owner's snapshot is 128 GiB provisioned, about 37 GiB used: at most about **$6.40 a month** in the estimate, about **$1.85 a month** billed for the used size.

## Microsoft Fabric capacity

The notebooks need the Fabric workspace on an F or Trial capacity (prerequisite P5), and so do the Real-Time Dashboard and the Power BI report of the presentation layer (Phases 18 and 19, in progress). Database Hub itself doesn't ([licenses](https://learn.microsoft.com/fabric/enterprise/licenses)).

- **Outside the demo's ceiling:** the capacity is a prerequisite that the workspace administrator owns, often shared with other workspaces. The demo's estimates, budget, and ceilings don't include it.
- **Dated example (2026-10-21):** the owner's workspace runs on an F16, 16 capacity units at the West US 3 list price of $0.18 per capacity-unit hour from the Retail Prices API: about **$2.88 an hour**, $69 for each day it runs, and about $2,100 for a month left running (730 hours).
- **Pause it when no workspace needs it.** Pausing saves its cost; at the pause, any remaining overages and smoothed operations are added to the bill, and "resuming your capacity also resumes billing" ([pause and resume](https://learn.microsoft.com/fabric/enterprise/pause-resume)). While it's paused, notebook imports and runs report **Manual action required** with the resume steps.
- **The demo never pauses, resumes, or scales it:** that's the capacity administrator's decision, here the owner's.
- **Power BI viewer licenses:** on F SKUs smaller than F64, such as the owner's F16, every viewer of Power BI content needs a Pro, Premium Per User, or individual trial license ([licenses](https://learn.microsoft.com/fabric/enterprise/licenses)). They're outside the demo's ceiling too; a presenter who shares their screen needs only their own.
- **The Insights app (Phase 19b):** "Fabric Apps services consume capacity units from the assigned capacity" ([Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview)). The app has no database, storage, or functions; it uses capacity when it's deployed, loaded, and queried (each visual's DAX runs on the model). That's outside the demo's ceiling, like the rest of the capacity, and `estimate-cost.ps1` doesn't include it.

## The on-demand activity control

Optional (`control.enabled`; [ADR 0020](adr/0020-on-demand-activity-control.md)). Its resources in `rg-<prefix>-control` outlive destroy, so they bill until `setup-activity-control.ps1 -Remove` deletes them:

- **Key Vault (Standard):** billed per 10,000 operations; a run reads the one secret once. The estimate adds one block of operations a month, from the vault's `Operations` meter.
- **Azure Automation (Basic):** billed per job minute after the first 500 a month, which are included; a run's jobs take a few minutes. The estimate prices 60 job minutes a month at the meter's first tier, so it's $0 while you stay under 500.
- **The webhook, the schedules, the identity, and role assignments** have no charge. Managed private endpoints and managed virtual networks in Fabric have no separate meter in the Retail Prices API (checked 2026-10-23); the control notebook uses the capacity's units while it runs, like any notebook.
- **What a run costs** is the demo's own running time, the VMs and T4 for the run's minutes, which the session estimate already covers; the auto-stop ends it 10 minutes after the run, and the daily safety stop catches a forgotten T4.
- `estimate-cost.ps1` reads both meters from the Retail Prices API at run time when `control.enabled` is true; no price is hard-coded.

## Run an estimate

```powershell
./scripts/estimate-cost.ps1 -AllProfiles -Detailed
./scripts/estimate-cost.ps1 -NetworkMode private   # the mode preflight resolved
```

- The Azure Retail Prices API is public, so the estimate itself needs no sign-in.
- **Defender for Cloud and the T3 free offer:** when the subscription guard passes (you're signed in to the configured tenant with access to the subscription), the script also reads the subscription's Defender plans (`az security pricing list`, read-only) and whether the free offer is available, and includes them. Otherwise it reports a Warning that the estimate excludes Defender and prices T3 as regular serverless. It never signs in.
- **Network mode:** pass `-NetworkMode` with the mode preflight resolved (the `effectiveNetworkMode` evidence of `PREFLIGHT.POLICY.SQLPUBLIC`). With `networkMode` `auto` and no `-NetworkMode`, the estimate assumes private, the more expensive mode, and says so.

## Summary

- **Ceilings:** a **hard** $250 a month for idle plus light use, and $15 per demo-day session ([ADR 0016](adr/0016-cost-profiles.md)). A light-use month above `monthlyCeilingUsd` is **Fail** in preflight and `estimate-cost.ps1`; pick a cheaper profile or options, or raise `monthlyCeilingUsd`. A session above `sessionCeilingUsd` is a **Warning**. *(User-directed on 2026-10-20; the ceiling was $75 before.)*
- **Defaults:** every default is the cheapest working option, starting with the `lowest-cost` profile, which has no separate data disks: the OS disks hold SQL Server data on T1 and the guest's VHDX and media on the T2 host (`dataDiskSku` `None`; set `E10` to add data disks).
- **Profiles:** `lowest-cost`, `demo-day`, and `enhanced-performance`. The T2 host size drives most of the compute cost.
- **Estimates:** `scripts/estimate-cost.ps1` prices every profile from the Azure Retail Prices API at run time. It includes the `Global` meters for SQL Server and Arc licenses, and for meters published only there (Defender for Cloud, the private endpoint, and the NAT gateway). Arc SQL Standard is billed per core-hour (example list price $0.10 per core-hour, 2026-10-19). Microsoft Learn documents a minimum of four cores per operating system environment (manage-license-billing, checked 2026-10-20), so the billable core count defaults to the larger of the guest's vCPU count and 4: the 2-vCPU guest is estimated at 4. The parameter `t2ArcBillableCores` overrides it, and `configure-arc.ps1` records the instance's cores as evidence (ADR 0006, Phase 7 notes). No price in this repo is hard-coded; figures in docs are labeled as dated examples.
- **What bills while stopped:** managed disks, Azure SQL storage, the private endpoint and private DNS zone in private mode, Defender for Azure SQL and Defender CSPM for the T3 server where those plans are on, the [T2 golden snapshot](#the-t2-golden-snapshot-phase-20) (also after destroy), and anything left on demand: Bastion and its public IP. Outside the ceiling, the [Fabric capacity](#microsoft-fabric-capacity) bills until it's paused.
- **Guardrails C1–C11:**
  - No Key Vault by default (C1); the [opt-in vault](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard) for the one-time host password needs `assignRoles`.
  - A budget with alerts at 50%, 80%, and 100% of `monthlyCeilingUsd`.
  - Scheduled start and stop windows with warm-up.
  - An expiry tag with scheduled destroy, and "park T2".
  - Opt-in Spot and Azure Hybrid Benefit.
  - T3 auto-pause at 15 minutes, and the Azure SQL Database free offer by default when preflight finds it available (otherwise regular serverless, with a Warning).
  - Automatic Bastion removal.
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

## Azure Database for PostgreSQL (T4, Phase 24)

T4 is the smallest flexible server that Azure will create in the region ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)): `t4SkuName` is `Standard_B1ms` by default; `Standard_B2s` is the documented fallback when Azure refuses B1ms with `SkuNotAvailable`, and `Standard_D2ds_v5` (General Purpose) the documented option the owner chose on 2026-10-26 after West US 3 refused both Burstable sizes. Since Phase 28, when `t4SkuName` isn't set, `deploy.ps1` moves from B1ms to B2s by itself, or leaves T4 out when both are refused, and records it (`DbHubT4Sku`); a General Purpose size is never set automatically. `estimate-cost.ps1`, preflight, and `start-demo.ps1`'s guardrail price the configured size from the Retail Prices API at run time; the figures below are a dated example (list prices, West US 3, 2026-10-23 and 2026-10-26), not a quote.

| Part | Billed | Example |
|---|---|---|
| Compute, Burstable B1ms (default) | Only while it runs (`start-demo.ps1` to `stop-demo.ps1`) | $0.017 an hour |
| Compute, Burstable B2s (the fallback) | Only while it runs | $0.068 an hour |
| Compute, General Purpose D2ds_v5 (the owner's option) | Only while it runs; 2 vCores at the vCore meter | $0.178 an hour (2 × $0.089) |
| Storage, 32 GiB | All month, stopped or not | $3.68 a month |
| Backup storage | Free up to the provisioned storage size (7-day retention, no geo-redundancy) | $0 |
| Its private DNS zone | All month | $0.50 a month |
| Defender for open-source relational databases (enabled by a tenant policy) | All month, stopped or not | $15 a month |
| Defender CSPM (enabled by a tenant policy) | All month, stopped or not | About $5.11 a month |

- **Fixed monthly cost:** about $24.30 while T4 exists, whatever it does and whatever its size (`T4FixedMonthly` in the estimate). The estimate's monthly message names it, and it's in the light-use total.
- **The 7-day restart:** a stopped flexible server starts on its own after seven days ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)) and bills compute until it's stopped again. The estimate counts the worst case, the rest of the month's compute at the configured size (`T4AutoRestartWorstCaseMonthly`: about $12 a month for B1ms, about $49 for B2s, and about $128 for D2ds_v5 at the example prices), against the hard monthly ceiling. Phase 25c's scheduled daily safety stop of T4 (approved 2026-10-26) caps that worst case at about a day of compute once it's live. `status.ps1` says when a stopped T4 starts again and warns a day before.
- **The size is never raised past the Burstable class on its own:** without `t4SkuName`, the fallback from B1ms to B2s (about four times the hourly list price) is the only automatic change, and the estimate prices the size that was recorded; `Standard_D2ds_v5` comes only from your configuration, with its price in `DEPLOY.T4.SKU` from the Retail Prices API. A size you set that Azure refuses is a **Fail** naming the fallback, and the estimate changes only once you change `t4SkuName`.
- **Turn it off:** `t4Enabled: false` leaves T4 out of the deployment and the estimate. To remove an existing T4, delete `pgflex01-<deploymentId>` and its private DNS zone, or run `destroy.ps1`. If T4 was ever attempted (as on 2026-10-26, when Azure refused its size), its private DNS zone and virtual network link stay in the group while T4 is off, about $0.50 a month that the estimate leaves out with T4; `destroy.ps1` removes them with the group ([cleanup](cleanup.md)).
- **Not added:** a Log Analytics workspace for a Real-Time Dashboard page ($0 to $2.30 a month after the free 5 GB, with a 2 to 10 minute delay) and a T4 history export are follow-ups, not part of the estimate.

## Disks switched to Standard HDD by the subscription's automation

The estimate prices each profile's disk tiers (E10 Standard SSD OS disks for `lowest-cost`). On 2026-10-24 an application identity that isn't the demo's switched both demo VMs' OS disks to Standard HDD while the VMs were deallocated. A Standard HDD disk lists for less than the same size of Standard SSD, so the invoice can come in under the estimate; the cost is performance: slower boots and IO, and IO-heavy scenarios that look worse. `deploy.ps1` keeps the current type (`DEPLOY.DISKS.DRIFT` **Warning**) and `status.ps1` reports it (`STATUS.DISKS`); changing a disk back is the subscription owner's call ([change a disk's type](https://learn.microsoft.com/azure/virtual-machines/disks-convert-types), R440).
