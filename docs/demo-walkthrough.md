# Demo walkthrough

Presenter scripts for the Fabric Database Hub hybrid SQL demo: a 15-minute version and a 30-minute version, what to do before and after a session, a documented fallback for every agent beat, a cheat sheet for each incident scenario, and a recovery playbook. How the demo is built is in the [architecture](architecture.md); what's automated and what isn't is in the [automation support matrix](automation-support-matrix.md).

> **Preview disclosure:** Database Hub, its Database Agent and Copilot, SQL Server on Azure VM performance monitoring, the Arc SQL monitoring setting, and the SQL telemetry endpoint are previews ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)). Their behavior, coverage, and UI can change. This script never promises what an AI will answer: it names the signals to look for, and every beat that depends on a preview has a fallback.

**Status (2026-10-21, Phase 15):** aligned with Phase 13 Milestone B, whose `start-demo.ps1`, `stop-demo.ps1`, `status.ps1`, `reset-demo.ps1`, and `demo-control.ps1` this script uses: every command was checked against the scripts' parameters at this commit. It also reflects the [live state on 2026-10-21](#whats-ready-at-this-commit). The Microsoft Learn pages in [Sources](#sources-checked-2026-10-20) were checked on 2026-10-20 and 2026-10-21. **The live rehearsal is pending:** items marked *verify in rehearsal* say what to look for where the preview UI isn't documented. The rehearsal, with its screenshots and measured times, is the owner's, and it settles them.

**Phase 18 (2026-10-21):** the 30-minute script gained [beat 5](#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code): Database Hub's template wizard, run live, next to the Real-Time Dashboard as code. The other beats were re-timed to keep 30 minutes. Which surface suits which audience, and what each viewer needs, is in [presentation surfaces](presentation.md).

## How to use this script

- **Two versions:** [the 15-minute script](#the-15-minute-script) tells the story in four beats. [The 30-minute script](#the-30-minute-script) adds security and posture, an incident started live, a monitor from Database Hub's template next to the dashboard as code, Copilot, and the notebooks. Both share the [preparation](#before-the-session) and the [cleanup](#after-the-session).
- **Every step has** these nine fields, in both scripts; `tests/unit/Docs.Walkthrough.Tests.ps1` checks them:
  1. **Time:** the range in the step's heading, such as `(0:00–3:00)`.
  2. **Presenter action:** `Show:` or `Do:`.
  3. **Narration:** `Say:`.
  4. **Expected visual:** `Look for:`, what's on screen.
  5. **Expected signal:** `Look for:`, the Hub or telemetry signal by name, where there is one.
  6. **Preview fallback:** `If it isn't there:`.
  7. **Reset instruction:** `Reset:`, the exact command, or "Nothing to reset".
  8. **Screenshot placeholder:** `Screenshot:`, the planned image path to capture in rehearsal.
  9. **Why the customer should care:** `Why it matters:`, tied to one of the value themes: faster detection, less tool switching, a consistent hybrid inventory, shared context, a guided investigation, and human-controlled action.
- **Markers:**
  - *Verify in rehearsal:* Microsoft Learn doesn't document it. Check it in your tenant before an audience sees it.
  - **Evaluation only:** the T2 fallback that runs the Arc agent on an Azure VM. Say it every time that fallback is on screen.
- **Statuses** follow the repo's model ([ADR 0012](adr/0012-validation-model.md)): **Pass**, **Fail**, **Warning**, **Manual action required**, **Not supported**, and **Not selected**. A deployment that succeeded is never a **Pass** on its own.
- **No prices:** cost figures come from `scripts/estimate-cost.ps1` on the day. The dated examples are in [ADR 0016](adr/0016-cost-profiles.md).
- **No real IDs:** commands use placeholders such as `<tenantId>`. Don't put subscription, tenant, or object IDs on a shared screen.

## What's ready at this commit

| Piece | Status at this commit | Used for |
|---|---|---|
| `scripts/estimate-cost.ps1`, `scripts/preflight.ps1` | Implemented (Phase 5) | Cost before the session |
| `start-demo.ps1`, `stop-demo.ps1`, `status.ps1`, `reset-demo.ps1`, and `demo-control.ps1`, with the `warm-up`, `demo-control`, `bastion-cleanup`, and scheduled workflows | Implemented (Phase 13 Milestone B). The scheduled workflows run only when the repository variable `DBHUB_SCHEDULES_ENABLED` is `true` ([deployment](deployment.md)) | Start and warm-up, stop, status and cost, reset, and one-command control |
| `scripts/configure-fabric.ps1` | Implemented: the Database Hub checklist (Phase 9), the notebook import (Phase 12), and the Real-Time Dashboard import with `-ImportDashboard` (Phase 18) | Readiness gates; the notebook and dashboard imports, with the owner's go-ahead |
| `scripts/configure-monitoring.ps1`, `scripts/configure-arc.ps1` | Implemented (Phase 7), and run live on 2026-10-21 | Recovery: T1 and T2 monitoring, Arc |
| Module functions `Invoke-DemoWorkloadCommand`, `Invoke-DemoT3WarmUp`, `Test-DemoT3Readiness`, `Test-DemoHubTelemetry`, `Get-DemoHubTelemetryKql`, `Get-DemoVmHealth` | Implemented (Phases 6–13) | Runner options that `demo-control.ps1` doesn't take, gates, health, and telemetry without a notebook |
| The workload runner and activity profiles | Implemented (Phase 13 Milestone A). On `sqlvm01`, which drives T1 and T3, and in the T2 guest, whose host reported **Ready** on 2026-10-21 | The baseline and the incidents |
| `validate.ps1` | Implemented (Phase 14): the live validation catalog, read-only. `-Area Hub, Telemetry` checks Estate and telemetry per target in one run, and a deallocated VM gives a Warning, not a Fail | Full validation |
| Both notebooks | Imported into the workspace on 2026-10-21. `NB_DatabaseHub_Deployment` ran read-only end to end; `NB_DatabaseHub_LiveActivity` hasn't run live yet. They need the shared Fabric capacity, which runs at the owner's choice | The 30-minute notebook beat, which has a fallback |
| The Real-Time Dashboard as code, `RTD_DatabaseHub_LiveView` ([`fabric/realtime/`](../fabric/realtime/README.md)) | Implemented (Phase 18). Importing it into the workspace, and checking its tiles by eye, are pending the owner's go-ahead. It needs the shared Fabric capacity too | The 30-minute template-wizard beat, next to the wizard's own dashboard |
| The prompt pack and the fallback guide (`fabric/agent/`) | Implemented (Phase 10). The live coverage record is still empty | Every agent beat and its fallback |

**Live state on 2026-10-21** (the Phase 7 and Phase 12 entries of the [implementation report](implementation-report.md)):

- **T1 (`sqlvm01`):** the Database Hub estate shows only its database engine. T1's `AssociatedServices` bootstrap step removes the Analysis Services and Integration Services that the Marketplace image installs (owner decision), and `T1.SQLVM.ASSOCIATEDSERVICES` reports **Pass** when unified inventory lists only the engine ([unified inventory for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm)).
- **T2 (`arcsql01`):** SQL Server 2022 Standard, pay-as-you-go, enabled by Azure Arc, with monitoring on. Its telemetry reached the documented endpoint about 7 minutes after monitoring was turned on (`TELEMETRY.T2` **Pass**). The setup-wizard step is done for the current guest build, with **Use Azure Login**.
- **Fabric:** both notebooks are imported into the workspace, and `NB_DatabaseHub_Deployment` ran read-only end to end through the Job Scheduler, whose job status was Completed after 57 seconds. The notebook's `kusto` token worked against the telemetry endpoint (`HUB.TELEMETRY.TOKEN` **Pass**, risk R29 closed), so a notebook can validate Hub telemetry directly. `NB_DatabaseHub_LiveActivity` hasn't run live yet, so every beat that relies on it keeps its fallback.
- **The Fabric capacity** is shared and runs at the owner's choice, so check it before a session ([the day before](#the-day-before)). Database Hub itself needs no capacity ([Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq)); only the notebook and dashboard beats do.

## Plan the session

### Pick the targets for the agent beats

Microsoft documents the Database Agent only at overview level: agents "can help translate an operational question into a structured investigation", and their findings "require operator review" ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)). Which SQL targets the agent covers, how it's turned on, what it needs, and how long it takes aren't documented. Every incident scenario runs on T1, T2, or T3 ([scenarios](../scenarios/README.md)), so plan each agent beat per target:

| Target | Why it's in the story | Database Agent plan | If the agent declines it or shows nothing |
|---|---|---|---|
| T3 `azuresql01-<deploymentId>` / `ContosoCare`, Azure SQL Database | The PaaS path: native inventory, CPU as a percentage of the service tier's limit, log-rate governance, and the most Hub security assessments | **Plan A for every agent beat.** The repo's working assumption is that Azure SQL Database is the most likely agent target; it isn't documented | Run the same scenario's prompts on T1, if you staged it there too, or switch to the [fallback](#the-documented-scriptable-fallback). The `microsoft-sql` diagnostics skills are written for Azure SQL Database, so T3 also has the best query-level fallback |
| T1 `sqlvm01`, SQL Server on an Azure VM | The IaaS path through the SQL IaaS Agent extension; the default target for locking | **Plan B.** Same prompts | The telemetry prompts in GitHub Copilot CLI. The `microsoft-sql-fdh` skill's description doesn't list SQL Server on Azure VMs (*verify in rehearsal*) |
| T2 `arcsql01`, SQL Server enabled by Azure Arc in a nested Hyper-V guest, disclosed as a simulated on-premises server | The hybrid path; the default target for CPU, IO, and missing index | **Plan C.** Arc monitoring is documented for SQL Server enabled by Azure Arc in general, and nested guests aren't mentioned. T2's telemetry reached the documented endpoint on 2026-10-21; whether the Hub's **Performance** page and the agent cover it is a rehearsal check | The telemetry prompts, then the instance's **Performance Dashboard** in the Azure portal ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)) |

- **Before the live coverage record has entries,** stage the incident on two targets, T3 and T1, and investigate T3 first.
- **After a rehearsal,** use the targets that the [live coverage record](../fabric/agent/README.md#live-coverage-record) marks **Pass**, and record every session there: the date, the status per target, and the latency.

### Keep T3 between demos for agent-focused sessions

The coordinator's decision (2026-10-20, [ADR 0016](adr/0016-cost-profiles.md)):

- A newly created T3 can show Database Hub security and posture findings, and Database Agent findings, **late**.
- **Recommendation:** keep a persistent T3 for agent-focused demos and for multi-day baseline-versus-incident demos. That's the default: `stop-demo.ps1` doesn't delete T3, and serverless auto-pause stops its compute when it's idle ([serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)).
- Use `./scripts/stop-demo.ps1 -RemoveT3` only for long gaps between demos, when saving T3's standing costs matters more. The next `start-demo.ps1` recreates T3 under the same names, which takes about 10 more minutes, and its readiness gate reports a **Warning** with the measured lag until telemetry arrives.
- **Measured so far:** on 2026-10-20 the first telemetry sample arrived 2.8 minutes after T3 was created. The delay for posture and agent findings isn't measured yet (*verify in rehearsal*).
- Telemetry is keyed on the resource ID, and T3 keeps its names, so earlier sessions should stay queryable within the 7-day retention. A live recreate test is still pending.

### Know the cost before you start

- **Ceilings** ([ADR 0016](adr/0016-cost-profiles.md)): at most **$15 per demo-day session** (`sessionCeilingUsd`; above it is a **Warning**), and at most **$250 for a light-use month** (`monthlyCeilingUsd`, a hard ceiling; above it is a **Fail**). The Azure budget on the resource group alerts at 50%, 80%, and 100% of the monthly ceiling.
- **Estimate on the day:** `./scripts/estimate-cost.ps1 -NetworkMode private`, or `public`, whichever mode preflight resolved. When the subscription guard passes, it includes the subscription's Microsoft Defender for Cloud plans and the T3 free offer. It prices everything from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) when you run it, so this script quotes no prices.
- **The start checks it too:** `start-demo.ps1` runs the cost guardrail before it starts anything: the live estimate against both ceilings (`PREFLIGHT.COST.SESSION` and `PREFLIGHT.COST.MONTHLY`), and this month's actual cost plus one session against `monthlyCeilingUsd` (`START.COST.ACTUAL`). A **Fail** stops the start. `-SkipCostCheck` starts anyway (`START.COST` **Not selected**), so use it only right after a check.
- **What a session adds:** VM hours, the SQL Server licenses that bill while the VMs run (T1's image license, and Arc pay-as-you-go per core-hour for T2), T3 compute while an activity profile keeps it awake, Defender plans on running VMs, and Bastion with its public IP for every hour it exists. The shared Fabric capacity isn't in the estimate: it's outside the demo's resource group, and it bills while it runs, at the owner's choice.
- **Bastion only when needed:** for the T2 setup-wizard step, the optional T-SQL path, or a person running the missing-index fix. The 15-minute script never needs it, and the 30-minute script needs it only for the missing-index story. `./scripts/start-demo.ps1 -Interactive` creates Bastion Basic (about 8 minutes), tagged to expire after `bastionMaxHours` (4 by default) ([Bastion overview](https://learn.microsoft.com/azure/bastion/bastion-overview)). Remove it with `./scripts/stop-demo.ps1 -RemoveBastionOnly` as soon as you're done.

### Label T2 honestly

- **Default (`t2Mode = Nested`, `t2SqlInstallMode = PaygWizard`):** T2 is a nested Hyper-V guest on the Azure VM `archost01`, onboarded to Azure Arc, running SQL Server 2022 Standard with pay-as-you-go billing through Arc. Present it as a **simulated** on-premises server. Each guest build has one documented manual step, the SQL Server setup wizard; until it's done, T2's checks report **Manual action required**. On the wizard's **Azure Extension for SQL Server** page, select **Use Azure Login** and sign in with your own account; never enter a service principal secret. The host installs the WebView2 runtime that this sign-in needs first, in its `GuestWebView2` step, and afterward its `GuestSignInCleanup` step removes the sign-in data that setup leaves on the VM and verifies that none remains ([installation wizard for SQL Server 2022](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup?view=sql-server-ver16), [deployment](deployment.md)). The step is done for the current guest build (2026-10-21).
- **`ProductKey` mode** (prerequisite P10) is fully unattended. **`Developer` mode** shows T2 in Estate only: its Performance checks report **Not supported**, because Arc monitoring needs Standard or Enterprise edition ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)).
- **Evaluation only (`t2Mode = EvaluationOnlyAzureVm`):** when nested virtualization isn't available, T2 can be an Azure VM running the Arc agent under Microsoft's procedure for evaluation and testing purposes only ([Evaluate Azure Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)). Label it **evaluation only** on every slide and every time you mention it; every T2 result in that mode starts with "EVALUATION ONLY:". Never call it on-premises. That mode has no workload runner yet, so run every incident on T1 or T3.

## Before the session

### Prepare a PowerShell session

Every command in this script runs in PowerShell 7.4 from the repository root, after you sign in yourself. Scripts and module functions never sign in or change your Azure CLI context, and they target the configured subscription explicitly, so don't run `az account set` or change your default subscription for the demo.

```powershell
# Sign in only if you aren't signed in to the demo's tenant. At the subscription selector, press Enter for no changes.
az login --tenant <tenantId>
Import-Module ./scripts/modules/DbHubDemo/DbHubDemo.psd1
$config = Get-DemoConfig -Path ./config/demo.config.json
Assert-DemoAzContext -SubscriptionId $config.subscriptionId -TenantId $config.tenantId -Account $config.azureAccount
```

`Assert-DemoAzContext` is the subscription guard. It checks the Azure CLI's sign-in for the configured subscription (`az account show --subscription`) against the configured tenant and `azureAccount`. Then it runs read-only canaries through every authentication path the scripts use, and stops if any check fails. It never reads or changes your default subscription, so the demo works even when the default is in another tenant. Every module function then passes `--subscription` on each Azure CLI call. Pressing Enter at the `az login` subscription selector keeps your current default ([Sign in with Azure CLI at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)).

### The day before

1. **Rehearse** both versions against the live environment, and record the results in the [live coverage record](../fabric/agent/README.md#live-coverage-record).
2. **Estimate the session** (see [Know the cost before you start](#know-the-cost-before-you-start)). A session estimate above $15 is a **Warning**: shorten the session or the incident list.
3. **Check T2** while `archost01` runs: `(Get-DemoVmHealth -Config $config -VmName archost01).state`, or `./scripts/status.ps1 -Detail`, which also reads T2's activity profile.
   - `Ready`: go.
   - `ManualActionRequired` with the step `SqlSetupWizard`: the one manual setup-wizard step is pending for a new guest build. Do it now, never during a session, with the `PaygWizard` steps in [deployment](deployment.md): `./scripts/start-demo.ps1 -Interactive -ResetAdminPassword` creates Bastion and puts a one-time host password on your clipboard (or, with the Key Vault opt-in, in the vault). On the wizard's **Azure Extension for SQL Server** page, select **Use Azure Login** and sign in with your own account, never a service principal secret. The host's `GuestWebView2` step has already installed the WebView2 runtime that sign-in needs, and its `GuestSignInCleanup` step removes the sign-in data that setup leaves on the VM afterward, and verifies that none remains. Then run `./scripts/configure-arc.ps1` and `./scripts/configure-monitoring.ps1 -Target T2`, or `./scripts/deploy.ps1 -Resume`, whose T2 stage does both and sets T2's activity profile. Remove Bastion with `./scripts/stop-demo.ps1 -RemoveBastionOnly`. On 2026-10-21, T2's telemetry arrived about 7 minutes after monitoring was turned on.
   - Anything else: see the [recovery playbook](#recovery-playbook).
4. **Fabric (30-minute version only):**
   - **Check that the shared capacity is running:** `./scripts/configure-fabric.ps1 -SkipNotebookImport -SkipTelemetry` reports `FABRIC.P5.CAPACITY` **Pass** when the workspace's capacity is Active (P5). The capacity runs at the owner's choice: when that check is **Manual action required** because the capacity isn't Active, ask the owner to resume it in the Azure portal ([pause and resume your Fabric capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume)), or plan the fallbacks of [beat 5](#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code) and [beat 9](#beat-9-26002900-the-notebooks), which need no capacity. Resuming it also resumes its billing.
   - **The notebooks:** both are in the workspace (imported 2026-10-21), so don't import them again before a session. `NB_DatabaseHub_LiveActivity` hasn't run live yet: run it once in the rehearsal, with `CONFIRM = False`, before an audience sees it.
   - **The dashboard as code:** check that `RTD_DatabaseHub_LiveView` is in the workspace. If it isn't, import it with the owner's go-ahead: `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard -WhatIf`, then without `-WhatIf`; expect `FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW` and `FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW` **Pass** ([Real-Time Dashboard as code](../fabric/realtime/README.md#import-it)). Open it once with **Target** on a target that has telemetry, and check every tile by eye: the read-back proves the definition, not the tiles (**Manual action required** until a rehearsal does).
   - **The template wizard:** run **Create SQL monitors from template** once in the rehearsal, and note its templates, the metrics in each, and how long it takes; Learn documents its steps, not its templates (*verify in rehearsal*). Choose where its dashboard goes: the demo workspace, on the running capacity, as a new dashboard named for the session, or a new page in a scratch dashboard from the rehearsal ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)).
   - **Viewers:** if attendees will open either dashboard themselves, they need Reader on the subscription and access to the dashboard; a Fabric Free license is enough. A presenter who shares their screen needs nothing more ([presentation surfaces](presentation.md#licensing-and-permissions)).
   - The Database Hub tenant setting must be on (P4). Database Hub itself needs no capacity ([Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq)); the notebooks and the dashboards do.
5. **The fallback host:** install GitHub Copilot CLI, the pinned `microsoft-sql-fdh` and `microsoft-sql` plugins, and the Learn MCP server with the [agent guide](../fabric/agent/README.md). `copilot plugin list --json` should show version 1.0.0 for both plugins. Don't run `copilot plugin update` before a demo.
6. **Presenter access:** each presenter opens [Database Hub](https://powerbi.com/workloads/fdh/databaseHub) with their own account. They need Reader on the subscription (Contributors have it; others need P8), `Microsoft.Sql` registered, the tenant setting **Users can access the Database hub (preview)**, and My workspace on a capacity outside North Europe and West Europe ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)).
7. **The calendar:** end the session at least 15 minutes before the nightly auto-shutdown, which is `autoShutdownTime` in `autoShutdownTimeZone` (19:00 Eastern in the owner's environment) and deallocates both VMs ([auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm)). Activity profiles end 2 minutes before it by design.
8. **Screenshots:** capture each beat during the rehearsal. They're the last rung of every fallback.

### 60 minutes before: start and warm up

1. **Start the demo and warm it up:**

   ```powershell
   ./scripts/start-demo.ps1 -ActivityProfile baseline -WarmUpMinutes 30
   ```

   In order, it runs the cost guardrail (`PREFLIGHT.COST.SESSION`, `PREFLIGHT.COST.MONTHLY`, and `START.COST.ACTUAL`); starts `sqlvm01` and `archost01`, and the T2 guest starts with its host (`START.VM_*`); resumes T3, or recreates it if it was removed and runs its readiness gate; sets the `baseline` profile on T1, T3, and T2 (`START.PROFILE_T1`, `START.PROFILE_T3`, `START.PROFILE_T2`) for the profile's default 8 hours, and never past 2 minutes before the next auto-shutdown; lets it run for 30 minutes; and checks that telemetry arrives (`TELEMETRY.T1`–`T3`). Allow about 40 minutes, and about 10 more when T3 is recreated; the rehearsal measures it. Add `-Interactive -ResetAdminPassword` only when you need Bastion.
   - **T3's results:** `T3.WARMUP` **Pass** reports how long a paused T3 took to answer, and `T3.PROPERTY` **Pass** means the `MS_EnablePerformanceMonitoringPreview` extended property is set ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql)).
   - **From GitHub Actions instead:** run the **warm-up** workflow about 45 minutes before the session, with `minutes` `30` and `profile` `baseline`; it runs the same script ([deployment](deployment.md)).
   - **Start with the script, not from the Azure portal:** the VMs don't set an activity profile when they boot (`activityProfileOnBoot` is false by default), so a VM started some other way runs no workload, and doesn't keep T3 awake either ([ADR 0016](adr/0016-cost-profiles.md)).
2. **Let the baseline run:** the SYSTEM task `DbHubDemo-Workload` on each VM hosts the profile: T1 and T3 from `sqlvm01`, and T2 inside the guest. Give it at least 30 minutes before the session, so the Performance page has a "before" picture; `-WarmUpMinutes 30` does that.
3. **Check the runners:** `./scripts/status.ps1 -Detail` reports each target's active profile and its end (`STATUS.PROFILE_T1`–`T3`), with the VMs, T3, Bastion, the month-to-date cost, and the next auto-shutdown. For each target's runs:

   ```powershell
   foreach ($target in 'T1', 'T2', 'T3') {
       Invoke-DemoWorkloadCommand -Config $config -Target $target -ArgumentList 'status', '--json' |
           Select-Object -Property Target, Status, StdOut
   }
   ```

   Expect **Pass**, the `baseline` profile, and a running `healthy-baseline` run on each target. T1 and T3 commands run on `sqlvm01`, so T3 can't be driven while `sqlvm01` is deallocated. T2 commands go through `archost01` into the guest.

### 15 minutes before: the readiness gates

The Database Hub checklist in `configure-fabric.ps1` only reads, apart from presenter role assignments when `assignRoles` is true. With the T3 gate, T3 is ready only when it's in Azure Resource Graph, its extended property is set, and fresh telemetry rows arrive from the documented telemetry endpoint (`Test-DemoT3Readiness`, with telemetry from `Test-DemoHubTelemetry`). The property check below runs the T3 warm-up through T1, so it also resumes a paused T3:

```powershell
./scripts/configure-fabric.ps1 -SkipNotebookImport -WaitMinutes 15 -T3ReadinessGate -T3PerformanceMonitoringCheck {
    param($c)
    Invoke-DemoT3WarmUp -Config $c | Where-Object -Property checkId -EQ -Value 'T3.PROPERTY'
}
```

| Check | What it proves | Go | If it isn't a go |
|---|---|---|---|
| Subscription guard (`PREFLIGHT.GUARD.CONTEXT`) | The Azure CLI reaches the configured subscription in its tenant as `azureAccount`, through every authentication path the scripts use | **Pass** | **Warning:** set `azureAccount` to the account its evidence names. **Fail:** sign in again yourself as that account (`az login --tenant <tenantId>`), without changing your default subscription; nothing else runs until it passes |
| `HUB.ESTATE.T1`–`T3` | Each target is in Azure Resource Graph, the Hub's inventory source | **Pass** for every target you'll show | T2 is **Manual action required** while its setup-wizard step is pending: present T1 and T3, and say why |
| `TELEMETRY.T1`–`T3` | Rows arrived from the telemetry endpoint, and the newest is at most 15 minutes old | **Pass** for the incident target, and for every target you'll show on the Performance page | **Warning** (stale): the VM is stopped or T3 is paused; start or warm it up and run the gate again. **Fail** (no rows): check monitoring with `./scripts/configure-monitoring.ps1 -Target T1 -WaitMinutes 15` for T1, or `./scripts/configure-monitoring.ps1 -Target T2` for T2, or pick another target |
| `T3.READINESS.GATE` | T3 is in Resource Graph, its extended property is set, and fresh telemetry arrives | **Pass** | A **Warning** with the measured lag: T3 was just created or is paused. Use T1 for the agent beat today, and keep T3 next time |
| `FABRIC.P4.HUBSETTING` | The Hub tenant setting | **Pass** when a Fabric administrator runs it; otherwise **Manual action required**, "Couldn't check ... please confirm it's enabled", is expected | If Database Hub opens for the presenter, the setting is on |
| `FABRIC.P5.WORKSPACE`, `FABRIC.P5.CAPACITY` | Your role in the notebooks' workspace, and that its capacity is Active | **Pass** (30-minute version only) | `FABRIC.P5.CAPACITY` is **Manual action required** when the shared capacity is paused. It runs at the owner's choice: use the fallbacks of [beat 5](#beat-5-13001600-a-monitor-from-a-template-and-the-dashboard-as-code) and [beat 9](#beat-9-26002900-the-notebooks), and don't resume it yourself |
| `PREFLIGHT.FABRIC.VIEWERLICENSE` | Whether people who view Power BI content from this workspace need Pro or PPU (P11) | **Pass** on F64 or larger; a **Warning** below F64, which is expected on the demo's F16 | Present by sharing your screen. Database Hub and the Real-Time Dashboards aren't Power BI content ([presentation surfaces](presentation.md#licensing-and-permissions)) |
| `HUB.PRESENTER.*` | Reader for presenters who aren't Contributors, only when `assignRoles` is true | **Not selected** or **Pass** | **Manual action required** prints the `az role assignment create` command an administrator runs |

Then open Database Hub as the presenter and check by eye: Estate lists the targets you'll show, with only the database engine for `sqlvm01` (`./scripts/status.ps1` reports `T1.SQLVM.ASSOCIATEDSERVICES`), and the Performance page has data from the last 15 minutes for each of them.

**Go or no-go:** if the incident target's telemetry isn't **Pass** 10 minutes before you start, stage the incident on your next planned target.

### 10 minutes before: stage the incident (15-minute version)

Database Hub telemetry arrives a few minutes after the activity: most performance data within 3 to 5 minutes, some inventory-based data up to 15 ([Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)). A 15-minute slot can't wait for it, so start the incident before the audience arrives:

```powershell
./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
```

- `demo-control.ps1` is what the **demo-control** workflow runs. It sets the target's profile through Run Command, with `--not-after` at the next auto-shutdown, and reports `CONTROL.T3`.
- The run is bounded: it ends after 30 minutes (the scenario's maximum), or 2 minutes before the next auto-shutdown, whichever comes first. The baseline runs beside it for the incident's window only; after that, the target stays quiet until a profile is set again, which beat 4 does.
- **No live coverage record yet?** Run the same command with `-Target T1` too, and investigate T3 first.
- **Write down the windows** for the prompts: `{incidentWindow}` is the run's start and deadline, from the runner's `status --json` or `demo.scenario_runs`; `{baselineWindow}` is a window of the same length before it.

### 5 minutes before: open the tabs

- Database Hub: **Overview**; **Estate** with **View: Microsoft SQL** and the demo resource group selected; **Performance**.
- The agent or Copilot pane on the incident target. Where it sits isn't documented (*verify in rehearsal*).
- GitHub Copilot CLI, started outside this repo with `--deny-tool=write`, with [session-setup.skills](../fabric/agent/prompts/session-setup.skills.md) already run.
- The [Azure Data Explorer web UI](https://dataexplorer.azure.com), connected to the telemetry endpoint, with the Learn sample queries for your scenario ready ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)). A query that names a resource ID shows the subscription ID in it, so fill those in before you share the screen, and show the results.
- The PowerShell session from [Prepare a PowerShell session](#prepare-a-powershell-session), off the shared screen: it drives the demo controls and [beat 9](#beat-9-26002900-the-notebooks)'s fallback.
- For the 30-minute version, when the shared capacity is running: `NB_DatabaseHub_LiveActivity`, with its helper cells already run. It hasn't run live yet (2026-10-21), so use it only after a rehearsal run, and keep beat 9's fallback ready either way.
- For the 30-minute version's beat 5, when the shared capacity is running: `RTD_DatabaseHub_LiveView` on its **Incident** page, with **Time range** on the last hour and **Target** on the incident target, and the workspace where the wizard's dashboard will go.
- The rehearsal screenshots.
- Close anything that shows IDs, email addresses, or tokens. Never share a terminal that printed a token.

## The 15-minute script

The story in four beats: one estate of three SQL targets in Database Hub, then performance, then an incident, then the Database Agent with human approval. It needs the baseline running for at least 30 minutes and the incident staged 10 minutes before ([before the session](#before-the-session)). It uses no notebooks.

| Time | Beat | Where |
|---|---|---|
| 0:00–3:00 | 1. One estate | Database Hub **Overview**, then **Estate** |
| 3:00–6:00 | 2. Performance | **Performance** |
| 6:00–9:00 | 3. The incident | **Performance**, then the target in **Estate** |
| 9:00–14:00 | 4. The Database Agent, with human approval | The agent or Copilot pane, then one demo control |
| 14:00–15:00 | Close | Back to **Overview** |

### Beat 1 (0:00–3:00): one estate

- **Say:** "Contoso Care runs SQL in three places: SQL Server on an Azure VM, an on-premises SQL Server, and Azure SQL Database. Today each has its own portal, metrics, and tools, so every investigation starts with switching tools."
- **Show:** [Database Hub](https://powerbi.com/workloads/fdh/databaseHub) **Overview**, the **What needs attention?** section, then **Estate** with **View: Microsoft SQL** and the demo resource group selected ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)).
- **Say:** "One inventory across all three. Nothing moved: the databases stay in their subscriptions and on-premises, and Database Hub uses my own Microsoft Entra ID and Azure permissions. It's free with a Fabric Free license." ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview), [FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Say, about T2:** "This on-premises server is simulated: a Hyper-V guest inside an Azure VM, connected through Azure Arc the way a real one would be." With the **evaluation only** fallback, say instead: "This one is an Azure VM running the Arc agent for evaluation only."
- **Look for:** on screen, three resources in **Estate**: `sqlvm01` (SQL Server on an Azure VM, with its database engine only), `arcsql01` (SQL Server enabled by Azure Arc), and `ContosoCare` on `azuresql01-<deploymentId>` (Azure SQL Database), with issues as colored chips under a resource and suggestions as chips with a lightbulb. The signal behind the list is Azure Resource Graph, the Hub's inventory source, which the readiness gates checked as `HUB.ESTATE.T1`–`T3`; for T1, `T1.SQLVM.ASSOCIATEDSERVICES` **Pass** means unified inventory lists only the engine.
- **If it isn't there:** if T2 is missing because its setup-wizard step is pending (`HUB.ESTATE.T2` is **Manual action required**), say so and continue with T1 and T3. Never present a missing target as healthy. If T1 also shows Analysis Services or Integration Services (`T1.SQLVM.ASSOCIATEDSERVICES` is a **Warning**), say that the Marketplace image installs them, the demo removes them, and the story uses the database engine. Other causes are in the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the beat only reads.
- **Why it matters:** a consistent hybrid inventory: every SQL estate in one list, wherever it runs, seen through each person's own permissions.
- **Screenshot:** `docs/images/walkthrough/15-beat-1-estate.png` (planned): **Estate** with **View: Microsoft SQL** and the demo resource group, showing the three targets and their chips.

### Beat 2 (3:00–6:00): performance

- **Show:** **Performance**, the **Microsoft SQL** dashboard, with the last hour and the three servers selected. Point at **Recent signal changes**, then CPU, memory, and storage ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Over the last hour, this is the steady baseline: a front desk, billing, and scheduling workload on all three. On Azure SQL Database, CPU is a percentage of the service tier's limit."
- **Look for:** on screen, steady charts across most of the hour for each target. The staged incident may already show at the right edge for its target, and in **Recent signal changes**; leave it for beat 3. The signals behind the steady part: low, flat `SqlServerCPUUtilization`, steady `Batch Requests/sec` and `Transactions/sec`, and `Processes blocked` at 0 (the [healthy baseline](#healthy-baseline)). Check the resource selection before you treat a chart as the whole estate.
- **Say, if a target shows a gap:** "No data isn't zero and isn't healthy. This serverless database pauses when it's idle and sends nothing while it's paused." ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor), best practices)
- **Say (optional):** "On this page, **Create SQL monitors from template** turns this view into a Fabric Real-Time Dashboard the team can keep and share." ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)) Mention it only; running it needs a workspace on a running Fabric capacity, and the 30-minute version shows it with the dashboard as code.
- **If it isn't there:** if a target has no recent data, show the other two and say that telemetry arrives a few minutes behind the activity; resume a paused T3 with `Invoke-DemoT3WarmUp -Config $config` while you talk. If the page is empty, check the time range and the resource selection, then use the rehearsal screenshot ([recovery playbook](#recovery-playbook)).
- **Reset:** Nothing to reset. Keep the last hour selected for beat 3.
- **Why it matters:** less tool switching: one performance view across the VM, the on-premises server, and the PaaS database, instead of three portals.
- **Screenshot:** `docs/images/walkthrough/15-beat-2-performance.png` (planned): the **Microsoft SQL** dashboard over the last hour, with the three servers selected and a steady baseline.

### Beat 3 (6:00–9:00): the incident

- **Say:** "Before we started, a billing batch on this database began holding row locks in an open transaction, like an application that forgot to commit. The billing clerks are now blocked behind it."
- **Show:** **Performance** with the incident target selected; then **Estate**, the target's row, for any new issue. If an issue appears, open **Issue Details** and its **Summary** and **Recommended action** ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)). Whether a blocking issue appears, and when, isn't documented (*verify in rehearsal*).
- **Look for:** on screen, the incident target leaving its baseline on **Performance**, and possibly a new issue chip in **Estate**; which chart shows blocking isn't documented (*verify in rehearsal*). The signals in the telemetry behind it, from the [locking cheat sheet](#locking-and-blocking): `Processes blocked` above 0, Lock-category waits (`LCK_M_U`, `LCK_M_S`), `Active Transactions` held open, and `ContosoCare.Demo/locking-blocking` sessions waiting behind one head blocker. On T3, optimized locking and read committed snapshot are on, so readers don't wait on writers; the clerks' updates still block ([optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)).
- **If it isn't there:** say "telemetry arrives a few minutes after the activity", then switch to the other staged target, or run Learn sample queries 8 and 5 in the Azure Data Explorer web UI for the incident window. If the incident didn't start, see the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset before beat 4: the incident keeps running for the agent. To run the beat again, reset the target, stage the incident again, and wait a few minutes for telemetry:

  ```powershell
  ./scripts/reset-demo.ps1 -Target T3
  ./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
  ```

- **Why it matters:** faster detection: the blocking surfaces as a signal in one place, before anyone signs in to the server or a user calls.
- **Screenshot:** `docs/images/walkthrough/15-beat-3-incident.png` (planned): **Performance** for the incident target leaving its baseline, and any new issue chip in **Estate**.

### Beat 4 (9:00–14:00): the Database Agent, with human approval

- **Say:** "The Database Agent is a preview. It's presenter-driven, here in the UI, and it has no API. Microsoft doesn't document which SQL targets it covers yet, so I staged this incident on the target we checked in rehearsal."
- **Do:** open the agent or Copilot pane on the incident target (*verify in rehearsal*: its entry point and placement aren't documented). Fill the placeholders and ask, in order:
  1. [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md), prompt 1: investigate the blocking.
  2. Same file, prompt 3: the supporting evidence.
  3. [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md), prompt 4: the safest next action, proposed only.
  4. Same file, prompt 5: which actions need approval.
- **Look for:** on screen, the agent's answer, then its proposal and the approvals it needs. In the answer: the target, `ContosoCare`, and a UTC window that overlaps the run; at least one blocking signal by name, such as `Processes blocked` or Lock-category waits; and a plain statement of what the agent couldn't see, such as the statement text. Judge the answer with the prompt file's rubric, not against a scripted answer. After step 4 of the approval beat, `demo-control.ps1` reports `CONTROL.T3` **Pass**.
- **The approval beat:**
  1. Read the proposal aloud: what it changes, where, and how to roll it back.
  2. Say who approves it in production, for example the on-call DBA, and with which permission. "Actions in Database Hub are explicit and always approved by a user who holds the permission; Database Hub then hands the execution to the authoritative service. There's no free-form execution." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
  3. **Cancel it.** In this demo, never approve an agent-proposed change ([agent guide](../fabric/agent/README.md), approval rules).
  4. Use the demo's own bounded control instead, which acts only on `ContosoCare.Demo/` sessions in `ContosoCare`: it ends the incident and returns T3 to the baseline for up to 240 minutes, never past the auto-shutdown.

     ```powershell
     ./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240
     ```

- **Say:** "The agent did the investigation and proposed a fix. A person decided."
- **If it isn't there:** if the agent pane is missing, the agent declines the target, or it hasn't answered after about three minutes, say so plainly and move to the [fallback](#the-documented-scriptable-fallback): [locking-blocking.skills](../fabric/agent/prompts/locking-blocking.skills.md) prompts 1 and 2 in GitHub Copilot CLI, then [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) prompts 4 and 5. Keep the same approval beat.
- **Reset:** step 4 of the approval beat returns T3 to the baseline. If you staged the incident on T1 too, return it as well, and start a new agent conversation before a re-run:

  ```powershell
  ./scripts/demo-control.ps1 -Target T1 -Scenario baseline -Duration 240
  ```

- **Why it matters:** a guided investigation and human-controlled action: the agent gathers the evidence and proposes, and a person approves before anything changes.
- **Screenshot:** `docs/images/walkthrough/15-beat-4-agent-approval.png` (planned): the agent's answer with its evidence, and its proposal before you cancel it.

### Close (14:00–15:00)

- **Show:** back to **Overview**, the whole estate.
- **Say:** "Faster detection, less tool switching, one inventory across Azure, on-premises, and PaaS, a guided investigation, and a person in control of every action." ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview))
- **Say:** "Database Hub and its agents are in preview, so coverage and behavior can change."
- **Look for:** on screen, **Overview** with **What needs attention?** across the three targets. The incident target's issue, if one appeared, can stay open for a few minutes after the fix, because signals refresh behind the activity ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), troubleshooting).
- **If it isn't there:** if **Overview** shows nothing new, close on the **Estate** list from beat 1 or on the rehearsal screenshot; the value story doesn't depend on a live chart.
- **Reset:** Nothing to reset: beat 4 returned the targets to the baseline. For a back-to-back session, stage the incident again 10 minutes before it:

  ```powershell
  ./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 30
  ```

  After the last session, follow [after the session](#after-the-session).
- **Why it matters:** shared context: everyone leaves with the same picture of the estate, the evidence, and the decision, from faster detection and less tool switching to human-controlled action.
- **Screenshot:** `docs/images/walkthrough/15-close-overview.png` (planned): **Overview** at the end of the session, with **What needs attention?** across the three targets.
- **Afterward:** the blocking clears in the next telemetry samples, a few minutes after the slot. Show it to anyone who stays, then follow [after the session](#after-the-session).

## The 30-minute script

The deeper version: the same story, plus security and posture, an incident started live on a chosen target, a monitor from Database Hub's template next to the dashboard as code, the Database Agent's investigation, Copilot, and the notebooks. It needs the same preparation, minus the staged incident, plus the dashboards and the notebooks (P5), which need the shared Fabric capacity running; otherwise beats 5 and 9 use their fallbacks, which need no capacity.

| Time | Beat | Where |
|---|---|---|
| 0:00–3:00 | 1. Frame it, and start the incident live | Terminal, GitHub Actions, or the live-activity notebook |
| 3:00–6:00 | 2. One estate, three onboarding paths | **Overview**, **Estate**, resource details |
| 6:00–10:00 | 3. Security and posture | **Overview** security summary, **Issue Details** |
| 10:00–13:00 | 4. Performance, before and during | **Performance** |
| 13:00–16:00 | 5. A monitor from a template, and the dashboard as code | **Create SQL monitors from template**, then `RTD_DatabaseHub_LiveView` in Fabric |
| 16:00–21:00 | 6. The Database Agent investigates | **Issue Details**, the agent pane |
| 21:00–24:00 | 7. Human approval and a bounded fix | The agent pane, one demo control |
| 24:00–26:00 | 8. Copilot explains and summarizes | The Copilot pane |
| 26:00–29:00 | 9. The notebooks | `NB_DatabaseHub_LiveActivity` in Fabric, or its PowerShell fallback |
| 29:00–30:00 | Close: recovery and value | **Performance**, **Overview** |

### Choose the incident

Pick one row the day before, on a target your rehearsal showed the agent covers. Every scenario runs on T1, T2, or T3; details are in the [cheat sheet](#per-scenario-cheat-sheet). If the live coverage record is still empty, also stage the same scenario on T1 ten minutes before the session as plan B, with the [staging command](#10-minutes-before-stage-the-incident-15-minute-version) and `-Target T1`.

| Story | Scenario and target | Duration | The approval moment | The recovery to show |
|---|---|---|---|---|
| An application forgot to commit (default) | `locking-blocking` on T3, or T1 | 25 minutes (maximum 30) | Ending the head blocker's session, approved by a DBA | `Processes blocked` back to 0; Lock waits gone |
| A bad plan on the "on-premises" server | `cpu-pressure` on T2 | 25 minutes (maximum 30) | A query rewrite through change control; the demo switches to the scenario's healthy variant | CPU back to the baseline |
| Too much demand for the tier | `resource-governance` on T3 | 15 minutes (maximum 20) | Scaling up costs money, so a budget owner approves | CPU back under the tier limit |
| A write-heavy batch | `log-rate-pressure` on T3 | 15 minutes (maximum 15) | Rescheduling the batch or changing the tier | Log writes back to the baseline |
| A missing index | `missing-index` on T2 | 25 minutes (maximum 30) | A person reviews and runs the index script; never the agent | Reads drop after the index (needs Bastion and the T2 host's one-time password, so plan the extra time) |

The Phase 25b scenarios fit the same slot when the audience cares about one kind of wait: a deep blocking chain, a deadlock storm, tempdb contention, memory grants, parallelism, log flushes, a slow client, or a target at full capacity ([cheat sheet](#deep-blocking-chain)).

### Beat 1 (0:00–3:00): frame it, and start the incident live

- **Say:** "Three SQL estates, three sets of tools. Let me start a problem now, and we'll find it in Database Hub in about ten minutes, the way an operator would."
- **Do:** start the chosen incident on camera, with one of these:
  - **PowerShell:**

    ```powershell
    ./scripts/demo-control.ps1 -Target T3 -Scenario incident:locking-blocking -Duration 25
    ```

  - **GitHub Actions:** run **demo-control** with `environment` `demo`, `target` `T3`, `scenario` `incident:locking-blocking`, and `duration` `25`. Leave `concurrency` and `intensity` empty for the scenario's defaults. The workflow runs the same script.
  - **The live-activity notebook,** only after a rehearsal run and while the shared capacity is running ([what's ready](#whats-ready-at-this-commit)): section 3, Simulation control. The plan cell shows the request without sending it; the send cell triggers `demo-control.yml` with `CONFIRM = True`, which needs P9. Without P9, it prints the Actions link and the `gh` command.
- **Say:** "It's bounded: one database, only sessions tagged `ContosoCare.Demo/`, and a hard maximum duration enforced three times, in T-SQL, in the runner, and by a watchdog." ([ADR 0010](adr/0010-workload-generator-technology.md))
- **Look for:** on screen, the command's result: **Pass** for `CONTROL.T3`, or a successful **demo-control** run. The signal: within about 10 seconds, the runner's `status --json` on the target shows a running `locking-blocking` run with its start and deadline. Database Hub shows nothing yet; telemetry follows a few minutes later.
- **If it isn't there:** if the command fails or no run starts, read the runner's message and the [recovery playbook](#recovery-playbook), then switch to the incident staged on T1 as plan B, if you staged one, or to the `business-day` profile's next scheduled incident.
- **Reset:** to start over, for example on another target, return the target to a quiet state, then start the incident again with the command above:

  ```powershell
  ./scripts/reset-demo.ps1 -Target T3
  ```

- **Why it matters:** faster detection: the clock starts now, and nobody will sign in to the server to find the problem.
- **Screenshot:** `docs/images/walkthrough/30-beat-1-start-incident.png` (planned): the terminal or Actions run that started the incident, with no IDs or tokens on screen.
- **Write down** the run's start time for `{incidentWindow}`.

### Beat 2 (3:00–6:00): one estate, three onboarding paths

- **Show:** **Overview**, then **Estate** with **View: Microsoft SQL** and the demo resource group. Select each resource name to open its detail pane, which helps you identify, connect to, locate, and manage it ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Each target arrives through a documented path, and turning on performance monitoring costs nothing extra." ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql))
  - **T1:** the SQL IaaS Agent extension. Performance monitoring is the `DatabaseWatcheronAzureVM` feature flag in the extension's settings, which uploads with the VM's managed identity ([Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)). The estate shows its database engine only: the demo removes the Analysis Services and Integration Services that the image installs.
  - **T2:** Azure Arc, "the mechanism for connecting on-premises SQL Server instances to Azure" ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq)), with the instance's monitoring setting on ([Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring)). It's SQL Server 2022 Standard with pay-as-you-go billing through Arc, on a simulated on-premises server, or **evaluation only** in the fallback mode. In the live run on 2026-10-21, its telemetry arrived about 7 minutes after monitoring was turned on.
  - **T3:** native, through Azure Resource Graph, plus the `MS_EnablePerformanceMonitoringPreview` extended property, which the deployment sets from T1. The **Enable Performance Monitoring** option on the **Estate** page is the documented manual alternative ([Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql)).
- **Show (optional, when time allows):** save the filtered view with **View** > **Manage custom views** > **Save**, then **Share** > **Copy link**. "Sharing a view shares its filters, not access: each person sees only what their own permissions allow." ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor))
- **Look for:** on screen, each target's detail pane with its resource type: SQL Server on an Azure VM, SQL Server enabled by Azure Arc, and Azure SQL Database, and for `sqlvm01` the database engine only. The signals behind them: all three in Azure Resource Graph (`HUB.ESTATE.T1`–`T3`), monitoring on for each (`T1.SQLVM.MONITORING`, `T2.ARC.MONITORING`, and `T3.PROPERTY`), and `T1.SQLVM.ASSOCIATEDSERVICES` **Pass**.
- **If it isn't there:** if T2 is missing because its setup-wizard step is pending, present T1 and T3 and say why, as in the [15-minute version](#beat-1-000300-one-estate), which also covers T1 showing Analysis Services or Integration Services; other causes are in the [recovery playbook](#recovery-playbook).
- **Reset:** Nothing to reset: the beat only reads, and a saved view is yours to keep.
- **Why it matters:** a consistent hybrid inventory: three onboarding paths, one inventory, and no data moved.
- **Screenshot:** `docs/images/walkthrough/30-beat-2-estate-paths.png` (planned): **Estate** with one target's detail pane open, showing how it's identified and where to manage it.

### Beat 3 (6:00–10:00): security and posture

- **Show:** on **Overview**, the **Issues** and **Suggestions** summaries for **Security**. Select an issue type, or **See affected resources**, to open **Estate** with that filter. Expand a resource, select the finding, and open **Issue Details** ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "Database Hub surfaces health and compliance signals from Azure Resource Graph metadata and SQL performance signals, so it doesn't need public connectivity to the databases, even behind a private endpoint." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Look for:** on screen, the **Security** issue and suggestion counts on **Overview**, then an **Issue Details** pane with the assessment, the affected server, its **Summary**, and its **Recommended action**. The signals are the SQL security assessments that Learn lists for Database Hub ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)). The demo's own configuration suggests what you'll see; none of it is observed yet (*verify in rehearsal*):

  | Target | Assessments that apply | What the demo's configuration suggests |
  |---|---|---|
  | T3 | Microsoft Entra Authentication Enabled, Minimum TLS version 1.2 Required, Public Network Access Disabled, and Private Endpoint Enabled (issues); Auditing, Encryption at rest using Customer Managed Keys, Microsoft Entra Authentication Enforced, and SQL Ledger (suggestions) | Entra-only and TLS 1.2 by design. In private mode, public access is off and a private endpoint exists; in public mode, expect the two network issues. The server has no auditing, customer-managed key, or ledger, unless a tenant policy adds one, so suggestions for those are likely |
  | T2 | Microsoft Entra Authentication Enabled (issue), Microsoft Entra Authentication Enforced (suggestion) | The instance uses Windows authentication only, so an Entra authentication issue is likely |
  | T1 | Public Network Access Disabled (issue) | SQL connectivity is `LOCAL` and the VM has no public IP, so no issue is expected |

- **Say:** "These are real findings about this demo's configuration. Each one has a summary and a recommended action, and **Open in...** takes me to the Azure portal, where an approved change happens. Database Hub doesn't change it for me." Then select **Open in...** to show the target in the Azure portal, and change nothing.
- **If it isn't there:** a newly created T3 can show posture findings late (see [Keep T3 between demos](#keep-t3-between-demos-for-agent-focused-sessions)). Show T1 or T2 instead, or open the T3 server in the Azure portal. If no security summary appears at all, say the assessments vary by resource type during the preview, and move on.
- **Reset:** Nothing to reset: the beat changes nothing. Close the Azure portal tab that **Open in...** opened.
- **Why it matters:** shared context: security, platform, and database teams see the same posture findings, with the evidence, in one place.
- **Screenshot:** `docs/images/walkthrough/30-beat-3-security.png` (planned): the **Security** issues and suggestions on **Overview**, and one **Issue Details** pane with its **Summary** and **Recommended action**.

### Beat 4 (10:00–13:00): performance, before and during

- **Show:** **Performance** with a time range that covers the baseline and the last 15 minutes. Point at **Recent signal changes**, then select the incident target and compare it with the other two ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).
- **Say:** "The same telemetry is open to KQL, Power BI, notebooks, and agents, through a documented endpoint." ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry))
- **Look for:** on screen, the incident target leaving its baseline a few minutes after the run started, next to two steady targets; whether **Recent signal changes** lists it isn't documented (*verify in rehearsal*). The signals: the chosen scenario's, from the [cheat sheet](#per-scenario-cheat-sheet); for locking, `Processes blocked` above 0 and rising Lock-category waits.
- **If it isn't there:** if the incident isn't visible yet, show the baseline on the other targets, run the scenario's Learn sample queries in the Azure Data Explorer web UI for the minutes that have arrived, and come back to it in beat 5, whose dashboards show the same minutes.
- **Reset:** Nothing to reset: the incident keeps running for beats 5 and 6.
- **Why it matters:** less tool switching: before and during, side by side, for every target, without opening each server's own monitoring.
- **Screenshot:** `docs/images/walkthrough/30-beat-4-performance.png` (planned): **Performance** with **Recent signal changes**, and the incident target selected over a range that shows the baseline and the incident.

### Beat 5 (13:00–16:00): a monitor from a template, and the dashboard as code

- **Say:** "Database Hub can turn this view into a dashboard the on-call team keeps. Let me build one for the database in trouble, live."
- **Do:** on **Performance**, select **Create SQL monitors from template**, and follow its steps for the incident target ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql)):
  1. Choose a template with the metrics for the incident, and select **Next**. Learn doesn't list the templates or their metrics: pick the one you noted in rehearsal (*verify in rehearsal*).
  2. Select only the incident target's database, for example `ContosoCare` on T3, and select **Next**.
  3. Select the destination workspace you chose the day before, on the running Fabric capacity.
  4. Create a new dashboard named for this session, or add a page to the scratch dashboard from the rehearsal.
  5. Open the result, a Fabric Real-Time Dashboard, and set its time range to the last hour.
- **Show:** then `RTD_DatabaseHub_LiveView`, the dashboard as code, on its **Incident** page with **Target** set to the incident target and the same time range: processes blocked, waits by category, active sessions, batch requests, and CPU, side by side ([Real-Time Dashboard as code](../fabric/realtime/README.md)). Finish on its **Estate pulse** page: every target's freshness at a glance.
- **Say:** "The same telemetry, governed and versioned. The wizard is the fastest way to start. This one lives in Git: its layout and its KQL, the live-activity notebook's own, are reviewed and tested, and a script imports it through a documented Fabric API and reads it back. Both query the telemetry as the person looking at them, so sharing a dashboard doesn't share the data."
- **Look for:** on screen, the wizard's new dashboard with charts for the incident target, then the dashboard as code with the incident on the same minutes. Which charts each template includes isn't documented (*verify in rehearsal*). The signals, for locking: **Processes blocked, latest sample** above 0 in red, the Lock category rising in **Waits by category**, and **Active sessions in ContosoCare** climbing; on **Estate pulse**, **Freshness per target** green for every target whose newest sample is at most 15 minutes old.
- **If it isn't there:** if the wizard is missing, can't save to the workspace, or takes more than a minute, say so, then open the dashboard you made in rehearsal, or only the dashboard as code. If its tiles are empty, check **Target** and the time range; a viewer without Reader on the subscription sees empty tiles. If the shared capacity isn't running, neither dashboard opens: don't resume it on stage; give the three minutes to beat 6, and show **Performance** instead.
- **Reset:** Nothing to reset during the session: both dashboards only read. After the session, keep or delete the wizard's dashboard ([after the session](#after-the-session)). If someone changed the dashboard as code in the editor, import it again from Git, which replaces their changes:

  ```powershell
  ./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -ImportDashboard
  ```

- **Why it matters:** shared context: a dashboard the whole team can open, built from Database Hub in a few clicks or kept in Git and tested, over the same telemetry and each viewer's own permissions.
- **Screenshot:** `docs/images/walkthrough/30-beat-5-template-dashboard.png` (planned): the wizard's new dashboard next to the **Incident** page of `RTD_DatabaseHub_LiveView`, for the incident target.

### Beat 6 (16:00–21:00): the Database Agent investigates

- **Show:** if an issue appeared for the target, start from its **Issue Details**: "Findings can come from agents, alerts, resource metadata, or telemetry." ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)) Then open the agent pane on the target (*verify in rehearsal*: its entry point and placement).
- **Say:** "The Database Agent is a preview. It's presenter-driven, here in the UI, with no API, and every action it proposes needs explicit approval. Microsoft doesn't document which targets it supports, so this incident runs on the target we checked in rehearsal."
- **Do:** ask every prompt in the scenario's in-Hub file, in order, for example [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md) prompts 1 to 3. The [cheat sheet](#per-scenario-cheat-sheet) names the file for each scenario.
- **Look for:** on screen, the agent's answers in the pane, and **Issue Details** if a finding appeared. In the answers, the prompt file's rubric: the right target and database, a UTC window that overlaps the run, the scenario's signals by name (for locking, `Processes blocked` and Lock-category waits), no blame on signals that didn't move, and a plain list of what the agent couldn't see.
- **If it isn't there:** if the agent declines the target or shows nothing after about three minutes, say so, then switch to plan B or C from [Pick the targets](#pick-the-targets-for-the-agent-beats), or to the [fallback](#the-documented-scriptable-fallback) with the scenario's skills file. Record the result in the [live coverage record](../fabric/agent/README.md#live-coverage-record) afterward.
- **Reset:** Nothing to reset: the prompts are read-only. Keep the conversation open for beats 7 and 8, and start a new one for a re-run.
- **Why it matters:** a guided investigation: the agent turns an operational question into a structured investigation, and names its evidence.
- **Screenshot:** `docs/images/walkthrough/30-beat-6-agent.png` (planned): the agent's answer for the incident target, with its signals, its window, and what it couldn't see.

### Beat 7 (21:00–24:00): human approval and a bounded fix

- **Do:** ask [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompt 4 (the safest next action, proposed only) and prompt 5 (which actions need approval).
- **The approval beat:** read the proposal, its scope, and its rollback aloud; say who approves it in production and with which permission; then **cancel it**. Never approve an agent-proposed change in this demo. If a recommendation conflicts with the evidence, don't apply it ([Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql), troubleshooting).
- **Do:** use the scenario's own bounded control from the [cheat sheet](#per-scenario-cheat-sheet), which acts only on `ContosoCare.Demo/` sessions in `ContosoCare`. For locking, return the target to the baseline:

  ```powershell
  ./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240
  ```

- **Say:** "This is the step Database Hub keeps human: an explicit, auditable proposal, approved by someone with the permission, executed by the authoritative service." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Look for:** on screen, the proposal with its scope and rollback, the list of approvals it needs, and then `CONTROL.T3` **Pass** from the demo control. The signal: the runner's `status --json` shows the incident run ended and only the baseline running; Database Hub shows the recovery a few minutes later.
- **If it isn't there:** if the agent offers no proposal, ask the same prompts from [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) in GitHub Copilot CLI, or describe the proposal yourself from the scenario's cheat sheet entry; the approval beat stays the same. If the demo control fails, stop the run with `Invoke-DemoWorkloadCommand -Config $config -Target T3 -ArgumentList 'stop', '--scenario', 'locking-blocking'` and see the [recovery playbook](#recovery-playbook).
- **For the missing-index story only (T2):** a person reviews and runs [`remediation.sql`](../scenarios/missing-index/remediation.sql) in `ContosoCare` on T2. That needs a SQL session inside the virtual network: through Bastion to `archost01`, then into the guest, as in the `PaygWizard` steps in [deployment](deployment.md) (*verify in rehearsal*). So create Bastion when you start the demo, with `-Interactive -ResetAdminPassword` on the [start command](#60-minutes-before-start-and-warm-up); its one-time password is for `archost01` only. Don't run `start-demo.ps1` again mid-session: it sets every target's profile again, which ends the incident. Remove Bastion right after the fix with `./scripts/stop-demo.ps1 -RemoveBastionOnly`, which also rotates that password. Nothing in the repo applies the index automatically.
- **Reset:** the bounded control above is the reset for the incident. After a missing-index session, once it's over, drop the indexes on T2, so the scenario starts from "before" next time; this also turns T2's profile off:

  ```powershell
  ./scripts/reset-demo.ps1 -Target T2 -UndoRemediation
  ```

- **Why it matters:** human-controlled action: nothing changes without an explicit, auditable proposal that a person with the permission approves.
- **Screenshot:** `docs/images/walkthrough/30-beat-7-approval.png` (planned): the proposal and its approval list before you cancel it, next to the demo control's result.

### Beat 8 (24:00–26:00): Copilot explains and summarizes

- **Say:** "Copilot is the conversational interface; agents are the engines behind it. Copilot explains and summarizes from the same scoped data and agent findings you see in the UI, and when it recommends an action, that action is backed by an explicit agent capability and an auditable proposal." ([FAQ](https://learn.microsoft.com/fabric/database/hub/faq))
- **Do:** in the Copilot pane (*verify in rehearsal*: its entry point isn't documented), ask [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md) prompt 1 (a customer-friendly root cause), prompt 3 (the baseline compared with the incident), and prompt 7 (a five-bullet incident summary).
- **Look for:** on screen, Copilot's three answers. In them: plain language with a confidence level; a table of the signals that moved, such as `Processes blocked` and Lock-category waits for locking, and of those that stayed flat; and exactly five bullets, with nothing presented as decided.
- **If it isn't there:** if Copilot isn't available, run the same prompts from [incident-wrap-up.skills](../fabric/agent/prompts/incident-wrap-up.skills.md) in GitHub Copilot CLI, or answer them yourself from the **Performance** page and the scenario record.
- **Reset:** Nothing to reset: the prompts are read-only.
- **Why it matters:** shared context: one plain-language summary that the application team, the on-call engineer, and management read the same way.
- **Screenshot:** `docs/images/walkthrough/30-beat-8-copilot.png` (planned): Copilot's five-bullet incident summary.

### Beat 9 (26:00–29:00): the notebooks

- **Show:** `NB_DatabaseHub_LiveActivity` in the Fabric workspace ([Fabric assets](../fabric/README.md)), when the shared Fabric capacity is running and a rehearsal has run the notebook: it's imported (2026-10-21) but hasn't run live yet. Otherwise use the fallback below. Pick two of these sections:
  - Section 6, **Locks and blocking**, or section 7, **Overall consumption**, for the incident target.
  - Section 8, **Correlation**: did the recorded scenario window produce its expected signal?
  - Section 9, **See it in the Hub**: the agent prompts, filled in with this session's names and window.
  - Section 11, **Persist**: snapshots and findings in the lakehouse keep demo history beyond the telemetry's 7-day retention. The [history report](../fabric/powerbi/README.md) (Phase 19) reads them; show it after the session, not in this beat.
- **Say:** "Database Hub is free and needs no capacity. These notebooks run on a Fabric capacity and query the same telemetry endpoint for custom analysis; the dashboard in beat 5 is built from their KQL. **Run all** is safe: every cell that changes something needs `CONFIRM = True`."
- **Look for:** on screen, the chart with the scenario window shaded and the correlation table. The signal: the correlation cell's verdict for the window; for locking, `Processes blocked` and Lock-category wait deltas inside the window. Its thresholds are presenter heuristics, not product behavior ([ADR 0014](adr/0014-notebook-role-and-capacity.md)).
- **If it isn't there:** don't resume the capacity or import notebooks on stage. Show the same telemetry without Fabric, from the documented endpoint, with the incident target in `-Target` and in the check ID. Run it off the shared screen, then share only the tables, because the result's evidence holds resource IDs:

  ```powershell
  $telemetry = Test-DemoHubTelemetry -Config $config -Target T3 -LookbackMinutes 30 -Detail | Where-Object -Property checkId -EQ -Value 'TELEMETRY.T3'
  $telemetry.evidence.waitCategories | ForEach-Object -Process { [pscustomobject]$_ } | Format-Table
  $telemetry.evidence.gaugeCounters | ForEach-Object -Process { [pscustomobject]$_ } | Format-Table
  Get-DemoHubTelemetryKql -Name WaitCategoryDeltas -ResourceId $telemetry.evidence.resourceId -LookbackMinutes 30
  ```

  The tables show wait seconds per category and the blocking and load counters for the last 30 minutes. The last line prints the KQL to paste into the Azure Data Explorer web UI before you share that tab. The notebook's `kusto` token worked against the endpoint on 2026-10-21 (`HUB.TELEMETRY.TOKEN` **Pass**, R29 closed), but that path is undocumented: if the notebook's section 4, **Telemetry access**, reports **Manual action required**, every analysis cell prints its KQL; run it there too. Or give the three minutes to beat 6.
- **Reset:** Nothing to reset: the analysis cells and the fallback only read, and running **Persist** again replaces this run's rows. Keep `CONFIRM = False`, so no cell changes anything.
- **Why it matters:** shared context beyond the Hub: the same telemetry in a notebook or a query the team can share, with history past the 7-day retention for reviews and trends.
- **Screenshot:** `docs/images/walkthrough/30-beat-9-notebook.png` (planned): the live-activity notebook's correlation output, with the scenario window shaded on its chart, or the fallback's two tables when the notebooks aren't available.

### Close (29:00–30:00): recovery and value

- **Show:** **Performance** for the incident target: the signal returning to the baseline. Telemetry arrives a few minutes after the activity, so the recovery may still be arriving; say so.
- **Say:** "Faster detection, less tool switching, one hybrid inventory, shared context, a guided investigation, and human-controlled action. Database Hub and its agents are in preview."
- **Look for:** on screen, the incident target's chart heading back to its baseline after the fix. The signal, for locking: `Processes blocked` back at 0 and no new Lock-category waits in the latest samples.
- **If it isn't there:** if the recovery hasn't arrived yet, say it's a few minutes behind, then show the latest samples on the **Incident** page of `RTD_DatabaseHub_LiveView`, which refreshes every minute, or in the notebook or [beat 9](#beat-9-26002900-the-notebooks)'s fallback. Otherwise show the rehearsal screenshot, and close on the value.
- **Reset:** Nothing to reset: beat 7 returned the incident target to the baseline, so a back-to-back session can start at beat 1. After the last session, follow [after the session](#after-the-session).
- **Why it matters:** all six together: faster detection, less tool switching, a consistent hybrid inventory, shared context, a guided investigation, and human-controlled action.
- **Screenshot:** `docs/images/walkthrough/30-close-recovery.png` (planned): **Performance** for the incident target, back at its baseline after the bounded fix.
- **If asked about mirroring:** "Database Hub doesn't need it; it monitors the databases where they are. Fabric mirroring isn't part of this demo; it's a possible future add-on." ([ADR 0015](adr/0015-mirroring-deferral.md), [Mirroring in Fabric](https://learn.microsoft.com/fabric/mirroring/overview))

## The documented, scriptable fallback

Use it when the Database Agent or Copilot isn't visible in your tenant, declines the target, or doesn't answer within about three minutes. Every piece is documented, every prompt is read-only or asks only for a proposal, and the same prompts work on T1, T2, and T3. The decision is [ADR 0013](adr/0013-agent-experience.md); installation, pins, limitations, and safety rules are in the [agent guide](../fabric/agent/README.md).

### The ladder

1. **The Database Agent in Database Hub:** the showcase.
2. **The same scenario's skills prompts** (`<scenario>.skills.md`) in GitHub Copilot CLI, the primary host, or VS Code, after [session-setup.skills](../fabric/agent/prompts/session-setup.skills.md):
   - **The `microsoft-sql-fdh` plugin** (Database Hub agent skills, linked from the [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)): inventory, CPU, storage, and memory health, and security posture. It's read-only and runs as your delegated sign-in.
   - **The telemetry agent instructions block** on Learn ([Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry), "Agent instructions block"): the connection contract and the rules for querying the documented telemetry endpoint. The session-setup prompt has the agent read it through the Learn MCP server. The repo links to it and never copies it. It covers every incident on every target.
   - **The Microsoft Learn MCP server** at `https://learn.microsoft.com/api/mcp`, for grounding. It needs no sign-in ([Microsoft Learn MCP Server overview](https://learn.microsoft.com/training/support/mcp)).
   - **The `microsoft-sql` plugin's diagnostics skills** (blocking and deadlocks, resource pressure, slow queries, plans): optional, and **Not selected** by default. They need a SQL connection from inside the virtual network, through Bastion, and they're written for Azure SQL Database, so on T1 and T2 they can decline.
3. **No agent at all:** the Database Hub pages, plus the Learn sample queries that each prompt file names, in the [Azure Data Explorer web UI](https://dataexplorer.azure.com) ([Azure Data Explorer web UI query overview](https://learn.microsoft.com/azure/data-explorer/web-ui-query-overview)), or the telemetry tables from [beat 9](#beat-9-26002900-the-notebooks)'s fallback.
4. **Last resort:** the rehearsal screenshots.

### Run it in the session

```powershell
Set-Location -Path "$HOME\dbhub-agent-demo"
copilot --deny-tool=write
```

- **Start outside this repo:** its instructions are for coding it, not for demos.
- Paste the session-setup prompt first, then the scenario's skills prompts with the four placeholders filled in.
- **Approve one read command at a time,** after reading it. Reject `az login`, `az account set`, and anything that writes. Never start with `--allow-all-tools` or `--allow-all`.
- **Tokens:** never paste one into the chat. If one appears in the transcript, end the session, clear the terminal, and sign in again.
- **Say:** "Same telemetry, same permissions, another surface: the agent queries a documented, read-only endpoint as me, and it can't change anything."

### Out of scope

- **The Fabric data agent:** it works over OneLake data, not Database Hub signals.
- **Custom agents or scripts that call undocumented Database Hub routes, or automate the portal:** never.

## Per-scenario cheat sheet

Every scenario runs on T1, T2, and T3, within the `ContosoCare` database only, on sessions tagged `ContosoCare.Demo/<scenario>/<run>`, with a hard maximum duration ([scenarios](../scenarios/README.md), [ADR 0010](adr/0010-workload-generator-technology.md)). Telemetry shows a scenario a few minutes after it starts.

### Commands for every scenario

```powershell
# Start an incident on one target: one bounded run, with the baseline beside it for the incident's window.
./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25

# Change a scenario parameter (incidents only). demo-control.ps1 takes -Concurrency and -Intensity but not
# --param, so call the runner; '--concurrency' and '--intensity' work the same way here.
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'profile', 'set', '--name', 'incident:cpu-pressure', '--param', 'variant=healthy', '--not-after', '{{NEXT_SHUTDOWN}}'

# Stop the incident and keep the baseline, for up to 240 minutes and never past the auto-shutdown.
# The runner stops a run within about 10 seconds.
./scripts/demo-control.ps1 -Target T2 -Scenario baseline -Duration 240

# Stop one scenario now, or everything (which also sets the profile to off).
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'stop', '--scenario', 'cpu-pressure'
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'stop', '--all'

# What's running: the profile, recent runs with their windows, live demo sessions and blocking, space headroom.
Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'status', '--json'

# Back to a quiet, known state: profile off, leftover demo sessions killed, no open demo transaction, scratch tables emptied.
./scripts/reset-demo.ps1 -Target T2
```

- `{{NEXT_SHUTDOWN}}` becomes the VM's next auto-shutdown time, and every run ends at least 2 minutes before it. `demo-control.ps1` adds it for you.
- T1 and T3 commands run on `sqlvm01`; T2 commands run in the guest through `archost01`. The VM that carries the command must be running.
- The scenario entries below use the runner's own options, such as `--duration 25m`; with `demo-control.ps1`, that's `-Duration 25`. Their `reset` is the runner command that `reset-demo.ps1` runs on each target.
- **GitHub Actions:** **demo-control** takes `environment` (`demo` by default), `target` (`all`, `T1`, `T2`, or `T3`; an incident on `all` runs on the scenario's default target), `scenario` (`baseline`, `business-day`, `off`, or `incident:<scenario>`), `duration` in minutes (1 to 240), `concurrency` and `intensity` (empty keeps the scenario's defaults), `reset-before`, and `auto-cleanup`, and runs `demo-control.ps1` with them ([deployment](deployment.md), [ADR 0014](adr/0014-notebook-role-and-capacity.md)).
- **Backup:** with the `business-day` profile set before the session, each target runs bounded incidents at fixed minutes past every UTC hour, for example locking on T1 at :10 and :40 ([activity profiles](../scenarios/activity-profiles.json)), so a recent incident is in the telemetry even if a live start fails.

### Healthy baseline

- **Runs on:** T1, T2, and T3, all by default. It's the `baseline` activity profile and the "before" picture. On T3 it's one session at intensity 2, which keeps the serverless database awake while it runs.
- **Start and stop:** `start-demo.ps1` sets it on every target (the configured `activityProfile`, `baseline` by default) for the profile's default 8 hours, and never past 2 minutes before the next auto-shutdown; the VMs don't set it when they boot unless `activityProfileOnBoot` is true. On one target, set it with `./scripts/demo-control.ps1 -Target <T1, T2, or T3> -Scenario baseline -Duration 240`, and turn it off with `-Scenario off`.
- **Show in the Hub:** steady `Batch Requests/sec` and `Transactions/sec`, low and flat CPU, `Processes blocked` at 0, and a few `ContosoCare.Demo/healthy-baseline` sessions. No Database Agent finding is expected.
- **Prompts:** [healthy-baseline.in-hub](../fabric/agent/prompts/healthy-baseline.in-hub.md) 1 to 3; fallback [healthy-baseline.skills](../fabric/agent/prompts/healthy-baseline.skills.md).
- **Reset:** nothing to undo. Status changes toggle within their seeded values, and `reset` removes the workload's audit rows.

### Locking and blocking

- **Runs on:** T1 by default, T2, and T3. On T3, read committed snapshot isolation and optimized locking are on, so plain readers don't block; the clerks' updates and their `READCOMMITTEDLOCK` reads still do, and writer waits can be on transaction ID (`XACT`) resources ([optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)).
- **Bounds:** 10 minutes by default, 30 at most; 3 blocked sessions; the holder keeps its transaction open for `holdSeconds` (120) and always rolls back.
- **Start:** `incident:locking-blocking` with `--duration 25m`. Add `'--param', 'deadlock=true'` for a bounded deadlock.
- **Stop:** `profile set --name baseline`, or `stop --scenario locking-blocking`.
- **Show in the Hub:** `Processes blocked` above 0, Lock-category waits (`LCK_M_U`, `LCK_M_S`), `Active Transactions` held open, demo sessions waiting behind one head blocker, and, with the deadlock, `Number of Deadlocks/sec` above 0.
- **Prompts:** [locking-blocking.in-hub](../fabric/agent/prompts/locking-blocking.in-hub.md) 1 to 3, then [incident-wrap-up.in-hub](../fabric/agent/prompts/incident-wrap-up.in-hub.md); fallback [locking-blocking.skills](../fabric/agent/prompts/locking-blocking.skills.md).
- **Reset:** every transaction rolls back, so the work items stay as seeded. `reset` kills leftover demo sessions and verifies that no demo transaction is open.

### CPU pressure

- **Runs on:** T2 by default, T1, and T3. On T3, also use the resource-governance prompts.
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions; `variant` is `problem` (the default) or `healthy`.
- **Start:** `incident:cpu-pressure`. For the "after", set it again with `'--param', 'variant=healthy'`: the same question, answered with an index seek.
- **Stop:** `profile set --name baseline`, or `stop --scenario cpu-pressure`.
- **Show in the Hub:** `SqlServerCPUUtilization` rising toward 100%, the CPU wait category (`SOS_SCHEDULER_YIELD`), and `ContosoCare.Demo/cpu-pressure` sessions running.
- **Prompts:** [cpu-pressure.in-hub](../fabric/agent/prompts/cpu-pressure.in-hub.md) 1 to 4; fallback [cpu-pressure.skills](../fabric/agent/prompts/cpu-pressure.skills.md). Query-level evidence is in Query Store ([Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store)), not in the telemetry.
- **Reset:** read-only; nothing to undo.

### IO pressure

- **Runs on:** T2 by default, T1, and T3. The runner checks free space first.
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions; `scratchMb` 1,024 (256 on T3, 6,144 at most).
- **Start:** `incident:io-pressure`. Add `'--param', 'scratchMb=2048'` to make more reads physical, within the file caps.
- **Stop:** `profile set --name baseline`, or `stop --scenario io-pressure`.
- **Show in the Hub:** storage IO reads, writes, and stalls on the data file; `Page reads/sec` and `Page writes/sec`; `WRITELOG` while the scratch set grows; `PAGEIOLATCH` waits only once the scratch set exceeds the memory SQL Server can use. Per-file IO latency from the telemetry isn't available for Azure SQL Database.
- **Prompts:** [io-pressure.in-hub](../fabric/agent/prompts/io-pressure.in-hub.md) 1 to 3; fallback [io-pressure.skills](../fabric/agent/prompts/io-pressure.skills.md).
- **Reset:** auto-cleanup and `reset` empty the scratch table; the space stays allocated for the next run. Business data is never touched.

### Missing index

- **Runs on:** T2 by default, T1, and T3. On T3, Azure SQL Database can also raise its own index recommendation after enough executions.
- **Bounds:** 10 minutes by default, 30 at most; 2 sessions.
- **Start:** `incident:missing-index`.
- **Stop:** `profile set --name baseline`, or `stop --scenario missing-index`.
- **Show in the Hub:** CPU and logical reads above the baseline, and `ContosoCare.Demo/missing-index` sessions.
- **Prompts:** [missing-index.in-hub](../fabric/agent/prompts/missing-index.in-hub.md) 1 to 3, which only propose; fallback [missing-index.skills](../fabric/agent/prompts/missing-index.skills.md).
- **The human-approved action:** a person reviews and runs [`remediation.sql`](../scenarios/missing-index/remediation.sql) in `ContosoCare`, through a SQL session inside the virtual network. Never the agent, and never automatically.
- **Reset:** `./scripts/reset-demo.ps1 -Target <T1, T2, or T3> -UndoRemediation` (the runner's `reset --undo-remediation`) drops the two indexes, so the scenario starts again from "before".

### Inefficient query

- **Runs on:** T2 and T3 by default, and T1.
- **Bounds:** 10 minutes by default, 30 at most; 4 sessions; `variant` is `problem` or `healthy`.
- **Start:** `incident:inefficient-query`; the "after" is `'--param', 'variant=healthy'`.
- **Stop:** `profile set --name baseline`, or `stop --scenario inefficient-query`.
- **Show in the Hub:** CPU and `Batch Requests/sec` above the baseline, and many short `ContosoCare.Demo/inefficient-query` requests. The telemetry describes resources; the query itself is in Query Store.
- **Prompts:** [inefficient-query.in-hub](../fabric/agent/prompts/inefficient-query.in-hub.md) 1 to 3, and on T3 [resource-governance.in-hub](../fabric/agent/prompts/resource-governance.in-hub.md); fallback [inefficient-query.skills](../fabric/agent/prompts/inefficient-query.skills.md).
- **Reset:** read-only; nothing to undo.

### Resource governance

- **Runs on:** T3 by default, T1, and T2. On T1 and T2 it shows as plain CPU saturation of the VM, not a service-objective cap.
- **Bounds:** 5 minutes by default, 20 at most; 4 sessions.
- **Cost:** it uses serverless vCore seconds, and the free offer's monthly allowance, while it runs. Keep runs short.
- **Start:** `incident:resource-governance` with `--duration 15m`.
- **Stop:** `profile set --name baseline`, or `stop --scenario resource-governance`.
- **Show in the Hub:** CPU at the tier limit on T3, CPU waits with sound plans, and parallel `ContosoCare.Demo/resource-governance` sessions. In the Azure portal: the database's CPU percentage and Workers percentage metrics.
- **Prompts:** [resource-governance.in-hub](../fabric/agent/prompts/resource-governance.in-hub.md) 1 to 3; fallback [resource-governance.skills](../fabric/agent/prompts/resource-governance.skills.md).
- **Reset:** read-only. Once no session is open, T3 auto-pauses after its delay.

### Log-rate pressure

- **Runs on:** T3 by default, T1, and T2.
- **Bounds:** 5 minutes by default, 15 at most; 2 sessions; `maxLogMb` 2,048 (1,024 on T2).
- **Start:** `incident:log-rate-pressure` with `--duration 15m`.
- **Stop:** `profile set --name baseline`, or `stop --scenario log-rate-pressure`.
- **Show in the Hub:** on T3, the `Log Rate Governor` wait category ([transaction log rate governance](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server)), with `avg_log_write_percent` near 100 in [`sys.dm_db_resource_stats`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database) and Log IO percentage in the [Azure portal metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics). On T1 and T2: `WRITELOG` waits and rising `Log Bytes Flushed/sec`.
- **Prompts:** [log-rate-pressure.in-hub](../fabric/agent/prompts/log-rate-pressure.in-hub.md) 1 to 3; fallback [log-rate-pressure.skills](../fabric/agent/prompts/log-rate-pressure.skills.md).
- **Reset:** auto-cleanup and `reset` empty the scratch table; business data is never touched.

### Deep blocking chain

- **Runs on:** T1 by default, T2, and T3. On T3, optimized locking makes the links wait on transaction-ID locks, and there's no lock escalation.
- **Bounds:** 10 minutes by default, 30 at most; 2 branches (`concurrency`, 4 at most) of `depth` 4 (3 to 6), so 26 sessions at most; each link waits 60 seconds at most; an escalation of `escalationRows` 10,000 (7,000 to 20,000) every 120 seconds, held 15 seconds; everything rolls back.
- **Start:** `incident:blocking-chain`. Add `'--param', 'depth=6'` for a deeper chain, or `'--param', 'escalation=false'` for the chain alone.
- **Stop:** `profile set --name baseline`, or `stop --scenario blocking-chain`.
- **Show in the Hub:** `Processes blocked` well above the locking incident's, long Lock waits (`LCK_M_U`; `LCK_M_IS` and `LCK_M_IX` during an escalation), and `Active Transactions`. The chain's depth isn't in the telemetry: show it with the skills prompts or `sys.dm_exec_requests`.
- **Prompts:** [blocking-chain.in-hub](../fabric/agent/prompts/blocking-chain.in-hub.md) 1 to 3; fallback [blocking-chain.skills](../fabric/agent/prompts/blocking-chain.skills.md).
- **Reset:** every transaction rolls back. `reset` kills leftover demo sessions and verifies that no demo transaction is open.

### Deadlock storm

- **Runs on:** T1 by default, T2, and T3, the same on all three.
- **Bounds:** 10 minutes by default, 30 at most; 2 pairs (8 at most); `maxRounds` 60 per session (300 at most); `shape` `mixed` (the default), `order`, or `conversion`; every round rolls back.
- **Start:** `incident:deadlock-storm`. Add `'--param', 'shape=order'` for the classic lock-order deadlock only.
- **Stop:** `profile set --name baseline`, or `stop --scenario deadlock-storm`.
- **Show in the Hub:** `Number of Deadlocks/sec` above 0 bin after bin, `Errors/sec` with it, and short Lock waits. The graphs are in the `system_health` session on T1 and T2, not in the telemetry.
- **Prompts:** [deadlock-storm.in-hub](../fabric/agent/prompts/deadlock-storm.in-hub.md) 1 to 3; fallback [deadlock-storm.skills](../fabric/agent/prompts/deadlock-storm.skills.md).
- **Reset:** every round rolls back, so the inventory rows stay as seeded.

### tempdb contention

- **Runs on:** T2 by default, T1, and T3. On T3, at 1 vCore or less, expect fewer latch waits and more CPU waits.
- **Bounds:** 10 minutes by default, 30 at most; 16 sessions (32 at most); `rowsPerTable` 200 (10 to 2,000). Its temporary tables belong to its own sessions in tempdb and are dropped every iteration, the one place outside `ContosoCare` a scenario writes.
- **Start:** `incident:tempdb-contention`. Add `-Concurrency 24` for more contention.
- **Stop:** `profile set --name baseline`, or `stop --scenario tempdb-contention`.
- **Show in the Hub:** Buffer Latch waits (`PAGELATCH_EX`, `PAGELATCH_SH`, `PAGELATCH_UP`), `Temp Tables Creation Rate` and `Active Temp Tables`, and `SQL Re-Compilations/sec`.
- **Prompts:** [tempdb-contention.in-hub](../fabric/agent/prompts/tempdb-contention.in-hub.md) 1 to 3; fallback [tempdb-contention.skills](../fabric/agent/prompts/tempdb-contention.skills.md).
- **Reset:** nothing persists; SQL Server drops any temporary table left when its session closes.

### Memory grant pressure

- **Runs on:** T2 by default, T1, and T3.
- **Bounds:** 10 minutes by default, 30 at most; 8 sessions (16 at most); `grantPercent` 100 (10 to 100). Read-only, and no server setting changes.
- **Start:** `incident:memory-grant-pressure`.
- **Stop:** `profile set --name baseline`, or `stop --scenario memory-grant-pressure`.
- **Show in the Hub:** Memory waits (`RESOURCE_SEMAPHORE`), `Granted Workspace Memory (KB)` at its ceiling, a growing `MEMORYCLERK_SQLQERESERVATIONS`, and `Page life expectancy` falling.
- **Prompts:** [memory-grant-pressure.in-hub](../fabric/agent/prompts/memory-grant-pressure.in-hub.md) 1 to 3; fallback [memory-grant-pressure.skills](../fabric/agent/prompts/memory-grant-pressure.skills.md).
- **Reset:** read-only; grants are released when each query ends.

### Parallelism waits

- **Runs on:** T2 by default, T1, and T3. On T3, at 1 vCore or less, plans run serially: expect CPU waits, not Parallelism waits.
- **Bounds:** 10 minutes by default, 30 at most; 4 sessions (8 at most); `maxdop` 4 (2 to 8), and never more threads than the target has schedulers (2 on T1 and T2).
- **Start:** `incident:parallel-scans`.
- **Stop:** `profile set --name baseline`, or `stop --scenario parallel-scans`.
- **Show in the Hub:** Parallelism waits (`CXPACKET`, `CXCONSUMER`, `CXSYNC_PORT`) with high CPU.
- **Prompts:** [parallel-scans.in-hub](../fabric/agent/prompts/parallel-scans.in-hub.md) 1 to 3; fallback [parallel-scans.skills](../fabric/agent/prompts/parallel-scans.skills.md).
- **Reset:** read-only; nothing to undo.

### Log flush waits

- **Runs on:** T1 by default, T2, and T3.
- **Bounds:** 10 minutes by default, 30 at most; 8 sessions (16 at most); `maxRows` 200,000 commits per session (1,000 to 2,000,000), each session deleting its rows every 1,000.
- **Start:** `incident:log-flush-waits`.
- **Stop:** `profile set --name baseline`, or `stop --scenario log-flush-waits`.
- **Show in the Hub:** many short Tran Log IO waits (`WRITELOG`), with `Log Flushes/sec` (SQL Server only), `Log Bytes Flushed/sec`, and `Transactions/sec`; on T3 also `Log Rate Governor` past the log-rate limit.
- **Prompts:** [log-flush-waits.in-hub](../fabric/agent/prompts/log-flush-waits.in-hub.md) 1 to 3; fallback [log-flush-waits.skills](../fabric/agent/prompts/log-flush-waits.skills.md).
- **Reset:** auto-cleanup and `reset` empty `demo.commit_scratch`; business data is never touched.

### Slow consumer

- **Runs on:** T3 by default, with T1's runner as the client across the network, T1, and T2.
- **Bounds:** 10 minutes by default, 30 at most; 4 sessions (8 at most); `rowsPerQuery` 100,000 (1,000 to 500,000); the intensity sets the client's pause between reads. Read-only.
- **Start:** `incident:slow-consumer`.
- **Stop:** `profile set --name baseline`, or `stop --scenario slow-consumer`.
- **Show in the Hub:** Network IO waits (`ASYNC_NETWORK_IO`) while CPU and IO stay flat, and `SQL Attention rate` when the runner cancels.
- **Prompts:** [slow-consumer.in-hub](../fabric/agent/prompts/slow-consumer.in-hub.md) 1 to 3; fallback [slow-consumer.skills](../fabric/agent/prompts/slow-consumer.skills.md).
- **Reset:** read-only; the runner cancels its queries and closes its sessions.

### Capacity maxed out

- **Runs on:** T1 by default, T2, and T3. On T3, also use the resource-governance prompts.
- **Bounds:** 10 minutes by default, 20 at most; 8 CPU sessions (2 to 16) and `ioWorkers` 4 (0 to 8); `scratchMb` 6,144 on T1, 4,096 on T2, and 2,048 on T3, after a free-space check.
- **Cost:** on T3 it uses serverless vCore seconds at the maximum while it runs. Keep runs short.
- **Start:** `incident:capacity-max`.
- **Stop:** `profile set --name baseline`, or `stop --scenario capacity-max`.
- **Show in the Hub:** CPU at or near 100% (of the tier limit on T3), `SOS_SCHEDULER_YIELD` with signal waits, `PAGEIOLATCH_SH` once the scratch set exceeds memory, and IO stalls on the data file.
- **Prompts:** [capacity-max.in-hub](../fabric/agent/prompts/capacity-max.in-hub.md) 1 to 3; fallback [capacity-max.skills](../fabric/agent/prompts/capacity-max.skills.md).
- **Reset:** auto-cleanup and `reset` empty `demo.io_scratch` once no `io-pressure` or `capacity-max` run uses it; the space stays allocated for the next run.

## Recovery playbook

When something isn't visible, say so plainly, keep the story moving on another target or surface, and fix it after the session. Never present missing data as healthy: "missing telemetry isn't zero utilization or proof that a server is healthy" ([Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor)).

| What you see | Likely cause | During the session | Afterward |
|---|---|---|---|
| A target has no recent data on **Performance**, or `TELEMETRY.<target>` is a **Warning** | Telemetry lag: data arrives a few minutes after the activity ([Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm)) | Say "telemetry arrives a few minutes behind", show another target, or run the scenario's Learn sample queries in the Azure Data Explorer web UI for the minutes that have arrived. Come back later | `Test-DemoHubTelemetry -Config $config -Target T1, T2, T3 -WaitMinutes 15` reports rows, the newest sample, and the lag per target |
| T3 shows gaps or no data, or the agent says there's no data for it | Serverless auto-pause: no sessions for `t3AutoPauseMinutes` (15 by default), so it sends nothing while paused ([serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)) | `Invoke-DemoT3WarmUp -Config $config` resumes it and reports how long that took, or set T3's profile back to the baseline with `./scripts/demo-control.ps1 -Target T3 -Scenario baseline -Duration 240`. Both run from `sqlvm01`, which must be running. Telemetry follows a few minutes later | Start the baseline earlier next time, and keep its profile on until the session ends |
| T3 doesn't exist | It was removed with `stop-demo.ps1 -RemoveT3` | Use T1 for the agent beat, and say why | `./scripts/start-demo.ps1` recreates it (about 10 more minutes), and its readiness gate reports a **Warning** with the measured lag. Keep T3 between agent-focused demos |
| `sqlvm01` or `archost01` is deallocated, runner commands fail, and T1 or T2 telemetry is stale | The nightly auto-shutdown: `autoShutdownTime` in `autoShutdownTimeZone`, 19:00 Eastern in the owner's environment ([auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm)) | Start the demo again with `./scripts/start-demo.ps1`: it starts the VMs and sets the configured profile, because the VMs don't set one when they boot. It sets every target's profile, so stage a running incident again afterward. Telemetry follows a few minutes later; present the other targets meanwhile | VMs started after that day's shutdown time keep running, and keep T3 awake, until the next day's shutdown: always run the [after-the-session](#after-the-session) steps |
| T2 is missing from **Estate**; `HUB.ESTATE.T2` or `TELEMETRY.T2` is **Manual action required**; the host's state is `ManualActionRequired` with the step `SqlSetupWizard` | The one manual SQL Server setup-wizard step for a new guest build is still pending (`PaygWizard` mode) | Present T1 and T3, and disclose that T2 is waiting for its setup step | Create Bastion with `./scripts/start-demo.ps1 -Interactive -ResetAdminPassword` and follow the `PaygWizard` steps in [deployment](deployment.md): on the **Azure Extension for SQL Server** page, select **Use Azure Login** and sign in with your own account, never a service principal secret. The host's `GuestWebView2` step installs the WebView2 runtime it needs first, and its `GuestSignInCleanup` step removes the sign-in data that setup leaves on the VM afterward, and verifies that none remains. Then run `./scripts/configure-arc.ps1` and `./scripts/configure-monitoring.ps1 -Target T2`, or `./scripts/deploy.ps1 -Resume`, and remove Bastion with `./scripts/stop-demo.ps1 -RemoveBastionOnly` |
| T1 shows Analysis Services or Integration Services next to its database engine; `T1.SQLVM.ASSOCIATEDSERVICES` is a **Warning** | The Marketplace image installs them; T1's `AssociatedServices` bootstrap step removes them, and unified inventory dropped them about 6 minutes after a clean uninstall in the live run | Say the image installs them and the demo uses only the engine | On a VM whose bootstrap predates that step, `./scripts/deploy.ps1 -FromStage Artifacts` delivers the current bundle and starts a new bootstrap generation (`-Resume` only continues after the last recorded stage). Then `./scripts/status.ps1` reports the check again |
| `T2.ARC.DISCONNECTEDDAYS` is a **Warning** (21 days or more) or a **Fail** (more than 30) | The T2 host stayed deallocated for weeks | Present T1 and T3 | Start the host, run `./scripts/configure-arc.ps1`, and read the [Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq) on pay-as-you-go billing after more than 30 days offline |
| The agent or Copilot pane isn't there, the agent declines the target, or there's no answer after about three minutes | Preview coverage, enrollment, or latency, none of which is documented | Say so plainly, then use plan B or C from [Pick the targets](#pick-the-targets-for-the-agent-beats), or the [fallback ladder](#the-ladder) | Record the date, target, status, and latency in the [live coverage record](../fabric/agent/README.md#live-coverage-record) |
| The agent or Copilot proposes a change | Expected: that's the approval beat | Read it aloud, name the approver, cancel it, and use the demo's own control | Nothing; never approve during a demo |
| No issue or finding appears for the incident target | Findings can come from agents, alerts, resource metadata, or telemetry, and their timing isn't documented | Investigate from **Performance** and the agent pane instead of **Issue Details** | Note the observed delay in the coverage record (*verify in rehearsal*) |
| Security findings are missing for T3 | A newly created T3 shows posture findings late, or that assessment isn't available | Show the findings for T1 or T2, or open the T3 server in the Azure portal | Keep T3 between demos |
| **Open in SSMS** or a VS Code link doesn't connect | No SQL endpoint is reachable from outside the demo's virtual network | Stay in Database Hub and the telemetry | Use Bastion only if you need query-level evidence |
| An incident didn't start: `status --json` shows no run | A run of the same scenario is already running, the database already has four runs, the free-space check refused it, `--not-after` is too close, or the VM that carries the command is off | Use the `business-day` profile's next incident, or another target | Read the runner's message, run `./scripts/reset-demo.ps1 -Target <T1, T2, or T3>`, and start it again |
| An incident won't stop | A stop request is pending, or a session is stuck | The runner's `stop --all` on the target, as in the [commands for every scenario](#commands-for-every-scenario) (it also sets the profile to off), then `./scripts/reset-demo.ps1 -Target <T1, T2, or T3>` | Nothing: 60 seconds after its deadline the watchdog cancels the run, and 15 seconds later it kills that run's sessions only |
| Database Hub doesn't load, or shows nothing at all | The tenant setting is off, My workspace is on a capacity in North Europe or West Europe, the presenter lacks Reader, or the wrong account is signed in ([Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview)) | Switch to the presenter account you checked the day before, or to the fallback | `./scripts/configure-fabric.ps1 -SkipNotebookImport` run by a Fabric administrator (P4), and Reader for the presenter (P8) |
| The notebook won't open or run: the workspace's capacity is paused | The shared Fabric capacity runs at the owner's choice (`FABRIC.P5.CAPACITY` is **Manual action required**) | Use [beat 9](#beat-9-26002900-the-notebooks)'s fallback: `Test-DemoHubTelemetry -Detail` and the printed KQL. Don't resume the capacity or import anything on stage | The owner resumes the capacity in the Azure portal ([pause and resume your Fabric capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume)). Both notebooks are imported (2026-10-21); a missing one is imported again with `./scripts/configure-fabric.ps1 -SkipHubChecks -Notebook <name> -WhatIf`, then without `-WhatIf`, with the owner's go-ahead |
| **Create SQL monitors from template** is missing, or its dashboard can't be saved | A preview UI change; no workspace you can write to on a running capacity; or a paused capacity | Open the dashboard you made in rehearsal, or `RTD_DatabaseHub_LiveView`; say the wizard builds the same kind of dashboard. Without a capacity, show **Performance** and move on to beat 6 | Check `FABRIC.P5.WORKSPACE` and `FABRIC.P5.CAPACITY`, and note what the wizard showed in the rehearsal notes |
| `RTD_DatabaseHub_LiveView` shows empty tiles, or **No data** on **Estate pulse** | The time range has no telemetry for that target, the viewer lacks Reader on the subscription (the dashboard queries as the viewer), or the data source didn't accept the telemetry endpoint (*verify in rehearsal*) | Widen the range, set **Target** to all, or show **Performance** in Database Hub instead | Reader for the viewer (P8, `Set-DemoPresenterAccess`); `./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -CheckDashboardData` says which tiles are empty and why; `-ImportDashboard` instead of `-CheckDashboardData` restores the committed definition ([Real-Time Dashboard as code](../fabric/realtime/README.md#check-the-data)) |
| The notebook can't query telemetry: its **Telemetry access** check (`HUB.TELEMETRY.TOKEN` in the deployment notebook) is **Manual action required** | The endpoint didn't accept the notebook's `kusto` token. It did on 2026-10-21 (R29 closed), but that path is undocumented | Run the printed KQL in the Azure Data Explorer web UI | Record the result in [ADR 0014](adr/0014-notebook-role-and-capacity.md) |
| Activity stopped on its own near the end of the day | Profiles end 2 minutes before the next auto-shutdown, or earlier when their duration runs out: 8 hours for the baseline that `start-demo.ps1` sets, and `-Duration` for `demo-control.ps1` | Expected. To keep going, set the baseline again with `./scripts/demo-control.ps1 -Target <T1, T2, or T3> -Scenario baseline -Duration 240` | Schedule sessions to end at least 15 minutes before the auto-shutdown |
| Bastion is still there after the session | It was created for the wizard or the T-SQL path and not removed | Remove it: `./scripts/stop-demo.ps1 -RemoveBastionOnly` | `status.ps1` reports Bastion and its public IP as a **Warning** while either exists. With the schedules on (`DBHUB_SCHEDULES_ENABLED`), the hourly `bastion-cleanup.yml` removes it after `bastionMaxHours` (4 by default) |

## After the session

1. **Leave the targets clean, and turn the activity off,** while the VMs still run:

   ```powershell
   ./scripts/reset-demo.ps1
   ```

   On every target, it stops every scenario and profile, kills leftover `ContosoCare.Demo/` sessions, verifies that no demo transaction is open, empties the scratch tables, and sets the activity profile to `off` (`RESET.T1`, `RESET.T2`, and `RESET.T3`). Where someone applied the missing-index fix, add `-UndoRemediation`, for example `./scripts/reset-demo.ps1 -Target T2 -UndoRemediation`.
   - **Why off matters:** while an activity profile runs on T3, its sessions keep the serverless database awake, and its compute bills every hour ([ADR 0016](adr/0016-cost-profiles.md)). Resetting T3 resumes it if it was paused; with its profile off, it pauses again `t3AutoPauseMinutes` (15 by default) after its last session.
2. **Stop the demo,** unless another session follows soon: `./scripts/stop-demo.ps1`. It removes Bastion and its public IP, rotates the T2 host's one-time password if one was set, sets every activity profile to `off`, shuts the T2 guest down cleanly, and deallocates `archost01` and `sqlvm01`. T3 persists, and serverless auto-pause stops its compute.
   - `-ParkT2` stops only the T2 side, for sessions that use T1 and T3.
   - `-RemoveT3` also deletes T3 until the next start. Use it only between long gaps, never before an agent-focused or multi-day baseline-versus-incident demo ([Keep T3 between demos](#keep-t3-between-demos-for-agent-focused-sessions)).
   - With the schedules on (`DBHUB_SCHEDULES_ENABLED`), `schedule-stop.yml` runs the same stop every night, at 01:00 UTC unless you edit its cron for your time zone.
3. **Confirm Bastion is gone.** It's the easiest thing to forget, because the nightly auto-shutdown doesn't touch it. `./scripts/stop-demo.ps1 -RemoveBastionOnly` removes only Bastion and its public IP, and rotates the host password.
4. **Check the state and the cost:** `./scripts/status.ps1` reports the power states (`STATUS.VM_*`), Bastion and its public IP (`STATUS.BASTION`, a **Warning** while either exists), T3's state, the next auto-shutdown, and month-to-date spend from the [Cost Management query API](https://learn.microsoft.com/rest/api/cost-management/query/usage) against `monthlyCeilingUsd` (`STATUS.COST`). [Cost analysis](https://learn.microsoft.com/azure/cost-management-billing/costs/quick-acm-cost-analysis) in the Azure portal, scoped to the demo resource group, breaks the same spend down by resource.
   - The month must stay below $250, the hard ceiling; the budget alerts at 50%, 80%, and 100%.
   - If month-to-date spend grew by more than the session estimate, something ran longer than planned: usually Bastion, an evening start that ran until the next day's shutdown, or a T3 profile left on.
5. **Record what happened:** the date, the targets the agent covered, the latency, and any action it offered, in the [live coverage record](../fabric/agent/README.md#live-coverage-record); the beat timings; and every *verify in rehearsal* item you settled. When the shared capacity is running, run the live-activity notebook's **Persist** cell if you want the session's telemetry beyond its 7-day retention.
6. **The wizard's dashboard** (30-minute version): keep it for the next session, or delete it from the workspace yourself. It's a manual step: nothing in the repo created it, so nothing removes it. `RTD_DatabaseHub_LiveView` stays in the workspace between sessions. `destroy.ps1` doesn't touch Fabric items, so it removes neither dashboard, nor the notebooks.

## Sources (checked 2026-10-20)

Every page below was read on 2026-10-20, except the rows marked *checked 2026-10-21*, which were added when this walkthrough was aligned with Phase 13 Milestone B and the live state on 2026-10-21. The rows marked *checked again 2026-10-21* were read again then. "Updated" is the page's own update date on Microsoft Learn.

| Page | What this walkthrough relies on | Updated |
|---|---|---|
| [Database Hub overview](https://learn.microsoft.com/fabric/database/hub/overview) | Overview, Estate, and Performance; agents and the operator review of their findings; the agent skills and the Learn MCP server; supported services; the **Enable Performance Monitoring** option; North and West Europe capacities; Resource Graph discovery | 2026-10-17 |
| [Database Hub FAQ](https://learn.microsoft.com/fabric/database/hub/faq) | Actions are explicit and approved by the user; Copilot is the conversational interface and agents are the engines, with auditable proposals and no free-form execution; no capacity needed; posture and health signals for databases behind private endpoints; Azure Arc for on-premises SQL Server | 2026-10-17 |
| [Monitor databases in Database Hub](https://learn.microsoft.com/fabric/database/hub/monitor) | Issues and suggestions for Security, Performance, and Optimization; **Issue Details** with **Summary** and **Recommended action**; findings from agents, alerts, metadata, or telemetry; **Open in...**; saved and shared views; **Recent signal changes**; missing telemetry isn't zero | 2026-10-17 |
| [Monitor a Microsoft SQL database](https://learn.microsoft.com/fabric/database/hub/monitor-sql) | The tenant setting; **What needs attention?**; **View: Microsoft SQL**; the SQL security assessments; **Create SQL monitors from template** and its six steps, which create a Real-Time Dashboard or a page in an existing one (*checked again 2026-10-21*); the Azure Data Explorer connection; troubleshooting | 2026-10-17 |
| [Enable performance monitoring for Microsoft SQL](https://learn.microsoft.com/fabric/database/hub/add-sql) | No extra cost; `Microsoft.Sql` registration; the extended property for Azure SQL Database; the SQL IaaS Agent feature flag; supported regions | 2026-10-17 |
| [Query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry) | The endpoint, Reader access, the sample queries, the REST errors, and the agent instructions block | 2026-10-17 |
| [Enable performance monitoring for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm) | T1's feature flag and managed identity; Standard edition; how soon data arrives | 2026-10-05 |
| [Unified inventory for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm) | T1's SQL Server instance resources: each instance on the VM is its own resource, and the inventory follows instances that are added or removed (*checked again 2026-10-21*) | 2026-09-30 |
| [Monitor SQL Server enabled by Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring) | T2's monitoring prerequisites (Standard or Enterprise, pay-as-you-go or Software Assurance) and the Azure portal's Performance Dashboard | 2026-10-19 |
| [SQL Server enabled by Azure Arc FAQ](https://learn.microsoft.com/sql/sql-server/azure-arc/faq) | Pay-as-you-go billing after more than 30 days offline | 2026-10-19 |
| [Install SQL Server 2022 with the Installation Wizard](https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-installation-wizard-setup?view=sql-server-ver16) | T2's setup-wizard step: **Use pay-as-you-go billing through Microsoft Azure** on the **Edition** page, and **Use Azure Login** on the **Azure Extension for SQL Server** page, where an existing Arc connection fills in the subscription, resource group, and region (*checked 2026-10-21*) | 2026-10-19 |
| [Evaluate Azure Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine) | The **evaluation only** fallback: evaluation and testing purposes only | 2026-04-28 |
| [Serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume) | T3's auto-pause conditions and resume triggers | 2026-10-19 |
| [Azure SQL Database free offer](https://learn.microsoft.com/azure/azure-sql/database/free-offer) | The monthly allowance that resource-governance runs consume | 2026-10-19 |
| [Resource management in Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server), [`sys.dm_db_resource_stats`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-resource-stats-azure-sql-database), [Azure SQL Database metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics) | Log-rate governance, `avg_log_write_percent`, and the Log IO percentage metric | 2026-10-19, 2026-10-19, 2026-07-31 |
| [Optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking), [Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store) | Blocking on T3; query-level evidence | 2026-10-19 |
| [NotebookUtils credentials](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials), [Create a Real-Time Dashboard](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-real-time-create) | The notebooks' token audiences; SQL monitors from a template | 2026-09-23, 2026-10-07 |
| [Pause and resume your Fabric capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume) | Resuming a paused capacity in the Azure portal, which also resumes its billing (*checked 2026-10-21*) | 2026-08-14 |
| [Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions) | Beat 5: pass-through identity is the default, and sharing a dashboard doesn't grant access to its data (*checked 2026-10-21*) | 2026-08-31 |
| [Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses) | The viewer rule for Power BI content below F64 (P11); Real-Time Dashboards aren't in its list of Power BI items, so a Free license can view them on an F capacity (*checked 2026-10-21*) | 2026-08-05 |
| [Sign in with Azure CLI at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively) | The subscription selector at `az login`: Enter keeps the current default (*checked 2026-10-21*) | 2026-10-12 |
| [Microsoft Learn MCP Server overview](https://learn.microsoft.com/training/support/mcp), [Azure Data Explorer web UI query overview](https://learn.microsoft.com/azure/data-explorer/web-ui-query-overview) | The fallback's grounding and the no-agent rung | 2026-05-22, 2025-01-21 |
| [Auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm), [Bastion overview](https://learn.microsoft.com/azure/bastion/bastion-overview) | The nightly shutdown and on-demand Bastion | 2026-06-24, 2026-07-01 |
| [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices), [Cost Management query API](https://learn.microsoft.com/rest/api/cost-management/query/usage), [cost analysis quickstart](https://learn.microsoft.com/azure/cost-management-billing/costs/quick-acm-cost-analysis) | Live estimates, month-to-date spend, and the portal check | 2026-01-06, 2026-08-13, 2026-03-17 |
| [Mirroring in Fabric](https://learn.microsoft.com/fabric/mirroring/overview) | Mirroring, only as a future add-on | 2026-08-28 |

Also checked on 2026-10-20, outside Microsoft Learn: the announcement of Database Agents with the Database Hub estate view ([Azure SQL blog, 2026-09-29](https://devblogs.microsoft.com/azure-sql/whats-new-across-microsoft-sql-at-sqlcon-fabcon-europe-2026/)), and GitHub's docs for [Copilot CLI plugins](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference), [allowing and denying tools](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools), and [`workflow_dispatch`](https://docs.github.com/actions/using-workflows/events-that-trigger-workflows).
