# Cleanup

> **Status:** Phase 16. The commands are covered by unit tests, and the results below come from a disposable test environment (`environment` `test`, `rg-dbhub-test`) and the deployment-stack trial. The shared demo environment, `rg-dbhub-demo`, was never destroyed.

`./scripts/destroy.ps1` (or the **destroy** workflow) removes everything the demo created ([ADR 0002](adr/0002-resource-group-topology.md)), then checks that nothing is left. Destroying the environment is the only cleanup the demo needs: compute stops with `stop-demo.ps1` between demos, and destroy deletes every billable resource.

## What `destroy.ps1` does

0. **Keeps the setup-wizard step safe** ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)): an environment whose nested T2 host holds a `PaygWizard` install needs a boot-verified golden snapshot in `rg-<prefix>-golden` whose guest's evaluation isn't over. Without one, nothing is deleted (`DESTROY.GOLDEN.GUARD` **Fail**) unless `-WithoutGolden` (or `-IncludeGolden`) accepts losing the wizard state (**Warning**); with `-IfExpired` the expiry wins (**Warning**).
1. **Records a manifest** before anything goes: `out/destroy-manifest-<environment>.json` holds the resource group's ID, its `deploymentId` tag, the Microsoft Entra principal IDs of the managed identities in the group (the VMs', the Arc machine's, the T3 server's, and any user-assigned identity), and the names the check needs. It holds names and IDs only, no secret. Once the group is gone, nothing else knows the identities. A run after an interruption that finds the group gone keeps the manifest recorded while it existed.
2. **Deletes the Arc resources**, which Arc onboarding creates outside the template: every `Microsoft.AzureArcData/sqlServerInstances` resource in the group first (T2's instance, and T1's unified-inventory instances), then every `Microsoft.HybridCompute/machines` resource. A machine's extensions, license profiles, and Run Commands are its child resources and go with it. No cascade from the machine to its SQL Server instances is documented, so that order is explicit ([Disconnect SQL Server instances from Azure Arc](https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc)).
3. **Deletes the resource group** with everything in it (`az group delete`): the VMs and their disks, network interfaces, Run Commands, and policy-added extensions; the virtual network, NSGs, private endpoint, private DNS zones and their virtual network links; T3's server and database; T4's flexible server `pgflex01-<deploymentId>`, stopped or not, with its database, its PostgreSQL roles, and its backups (Phase 24); the auto-shutdown schedules; on-demand Bastion and its public IP if they exist; and, with the Key Vault opt-in, the vault, which goes into soft delete (`DESTROY.KEYVAULT`). It waits until the group is gone (`-WaitMinutes`, 60 by default). The system-assigned identities go with their resources, and with them T1's membership in the P6 group.
4. **Deletes the subscription deployment record** `<prefix>-<environment>-main` (`dbhub-demo-main` with the defaults; before Phase 28 it was `dbhub-<environment>-main` whatever the prefix), which outlives the group and holds the template's parameters and outputs (`DESTROY.DEPLOYMENT`; [`az deployment sub delete`](https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-delete)), and **the budget** at the group's scope, which outlives the group too (`DESTROY.BUDGET`, live finding 2026-10-22; [Budgets - Delete](https://learn.microsoft.com/rest/api/consumption/budgets/delete)).
5. **Keeps the golden group** `rg-<prefix>-golden` with its T2 golden snapshots (`DESTROY.GOLDEN` **Not selected**), so the next `deploy.ps1` restores T2 from it. `-IncludeGolden` deletes it too (**Pass**); the next deploy then builds T2 and, in `PaygWizard` mode, waits for the setup-wizard step again.
6. **Runs the residual check** (`TEARDOWN.RESIDUAL.*`, below) and sums it up in `DESTROY.RESIDUAL`: **Pass** only when every check is clean; **Fail** when something is left, so `destroy.ps1` exits with 1; **Warning** when nothing was found but something couldn't be verified.

The Phase 3 outline started with "stop activity profiles and scenarios". Destroy doesn't need that step: profiles and scenarios run on T1 and the T2 host, which the destroy deletes, and T3's and T4's workloads come from T1. T4 has no managed identity, and its runner's role lives in the server, so nothing of T4 outlives the group; the residual check finds any leftover by the group, the environment's tags, or the deploymentId. That holds with `t4Enabled: false` too: a T4 that Azure refused to create (`SkuNotAvailable`, 2026-10-26) leaves its private DNS zone `<prefix>-<environment>.private.postgres.database.azure.com` and its virtual network link in the group, about $0.50 a month, until T4 is created or the group is deleted, and `snet-pg` with its NSG (free) are always part of the network; the group delete removes them all.

**What destroy leaves alone, by design:**

- `rg-<prefix>-control`, the GitHub identity's resource group, and the on-demand activity control's ([below](#the-on-demand-activity-control)). Remove the GitHub identity yourself if you no longer use the GitHub path.
- `rg-<prefix>-golden`, the T2 golden snapshots ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)), unless `-IncludeGolden`. It belongs to the prefix, not to one environment, and costs a few dollars a month ([cost management](cost-management.md)).
- Resource provider registrations, and Microsoft Defender for Cloud plans, which are subscription settings (in this tenant, Azure Policy enforces them).
- Shared resources that Azure creates once per subscription or region, outside the demo's group, such as Network Watcher (`NetworkWatcherRG`, [enabled automatically](https://learn.microsoft.com/azure/network-watcher/network-watcher-create) when a virtual network is created in a region) and a default Log Analytics workspace in `DefaultResourceGroup-<region>`. Other workloads use them; in this subscription both existed before the test environment.
- The Fabric workspace and its items: the notebooks and the Real-Time Dashboard `RTD_DatabaseHub_LiveView` that `configure-fabric.ps1` imported, the Delta tables in `LH_DatabaseHub`, and any dashboard made with Database Hub's template wizard. Delete them there yourself when you no longer need them. The shared capacity runs at the owner's choice ([presentation surfaces](presentation.md#cost)).

## Commands

| Command | What it does |
|---|---|
| `./scripts/destroy.ps1` | Asks, then runs the five steps above for the configured environment (`-ConfigPath`, default `config/demo.config.json`) |
| `./scripts/destroy.ps1 -Force` | The same without asking (the **destroy** workflow passes it after you type the environment's name again) |
| `./scripts/destroy.ps1 -WhatIf` | Reads only: nothing is deleted, and no manifest is written (`DESTROY.RESOURCEGROUP` is **Not selected**) |
| `./scripts/destroy.ps1 -IfExpired` | Deletes only after the day of the group's `expiresOn` tag (the **expiry** workflow) |
| `./scripts/destroy.ps1 -IncludeGolden` | Also deletes `rg-<prefix>-golden` and its T2 golden snapshots (the purge); the next deploy builds T2 and waits for the setup-wizard step again |
| `./scripts/destroy.ps1 -WithoutGolden` | Destroys a `PaygWizard` environment even though no boot-verified golden snapshot keeps its setup-wizard step |
| `-SkipResidueCheck`, `-ResidueWaitMinutes <n>` | Skip the residual check (`DESTROY.RESIDUAL` **Not selected**), or wait longer than 10 minutes for Azure Resource Graph and Microsoft Entra to catch up |
| `-ManifestPath <path>`, `-WaitMinutes <n>`, `-OutputPath <path>` | Where the manifest goes; how long to wait for the group's delete; where the results go (`out/destroy.jsonl`) |
| `./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath <path>` | Runs the residual check again later, read-only, as Pester tests ([tests/teardown](../tests/teardown/README.md)) |

`./scripts/validate.ps1 -Area Teardown` (Phase 14) adds a single read-only `TEARDOWN.RESIDUAL` check that also works while the environment is deployed. After destroy, pass `-DeploymentId <id>`, because the resource group that recorded it is gone.

## The residual check

`Test-DemoTeardownResidue` reads Azure Resource Graph, the subscription's deployments, the budget, and Microsoft Entra, and changes nothing. Resource Graph and Microsoft Entra lag behind a delete, so it polls for up to `-ResidueWaitMinutes` while something still shows up. A check it can't read is a **Warning**, never a **Pass** ([ADR 0012](adr/0012-validation-model.md)).

| Check | Clean when | Otherwise |
|---|---|---|
| `TEARDOWN.RESIDUAL.RESOURCEGROUP` | The resource group is gone | Fail |
| `TEARDOWN.RESIDUAL.TAGGED` | No resource or resource group in the subscription carries the environment's tags: its `deploymentId`, or `solution` `fabric-database-hub-demo` with its `environment`. `rg-<prefix>-control` isn't counted. | Fail |
| `TEARDOWN.RESIDUAL.GROUPRESOURCES` | Resource Graph lists nothing in the group | Fail |
| `TEARDOWN.RESIDUAL.ARC` | No Arc machine, machine extension, license profile, Run Command, SQL Server instance, or Arc SQL database in the group, carrying the environment's tags, or hosted by one of its machines or VMs | Fail |
| `TEARDOWN.RESIDUAL.ROLEASSIGNMENTS` | No role assignment at or under the group, and none for the manifest's identities anywhere in the subscription | Fail (removing one needs more than Contributor) |
| `TEARDOWN.RESIDUAL.IDENTITIES` | The manifest's identities are gone from Microsoft Entra, and none is still a member of the P6 group | Fail; Warning without a manifest, when the manifest didn't record the identities (it was taken after the group was gone), or when Microsoft Graph answers for another tenant |
| `TEARDOWN.RESIDUAL.DEPLOYMENTS` | No subscription deployment `<prefix>-<environment>-*` | Fail |
| `TEARDOWN.RESIDUAL.BUDGET` | The budget at the group's scope is gone | Fail |
| `TEARDOWN.RESIDUAL.REFERENCES` | No resource outside the group names it (a resource ID under it, or the group's own ID); `rg-<prefix>-golden` isn't counted, because a golden snapshot names its source group by design | Warning: such a resource may be shared, so it's reported, not deleted |
| `TEARDOWN.RESIDUAL.RECORDS` | Evidence only: what Defender for Cloud (assessments), Azure Policy (compliance states), and guest configuration still list for the deleted resources | Pass either way; Warning only when unreadable |
| `TEARDOWN.RESIDUAL.KEYVAULT` | With the Key Vault opt-in, the vault is neither active nor soft-deleted | Warning while it's soft-deleted ([ADR 0009](adr/0009-secrets-handling.md)); Not selected without the opt-in |

Every query is scoped to the configured subscription. The checks never pass `--ids`, `--resource-id`, or a `{subscriptionId}` placeholder to the Azure CLI, and a unit test keeps it that way.

**Resource Graph and Microsoft Graph are read with verified tokens, after canaries.** `az rest` takes its token for the subscription named in an Azure Resource Manager URL and from the Azure CLI's default account for any other URL, and `az ad` always uses the default account, which can be in another tenant ([`az rest`](https://learn.microsoft.com/cli/azure/reference-index#az-rest)). So the check reads Resource Graph and Microsoft Graph through `Invoke-DemoRestRequest`, with tokens that `Get-DemoAccessToken` verified for the configured tenant and caller ([ADR 0011](adr/0011-control-surface-priority.md), guard update), and each only after a canary. Resource Graph must list the configured subscription: it trims its answer to what the caller can read, so an empty answer could mean "can't read" rather than "nothing left". Microsoft Graph must answer for the configured tenant ([get organization](https://learn.microsoft.com/graph/api/organization-get)). The identities are then looked up in one request ([getByIds](https://learn.microsoft.com/graph/api/directoryobject-getbyids)), and the P6 membership of any that still exist with [checkMemberGroups](https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups). When a canary fails, the checks that depend on it are **Warnings** that say so, the check doesn't wait for them, and the manifest records that it couldn't list the identities (`IdentitiesRecorded` `false`).

## Tested results

### Shared demo environment (`rg-dbhub-demo`, `PaygWizard`), Phase 20, 2026-10-22

With the owner's go-ahead, after the T2 golden snapshot was captured and proven in quarantine ([ADR 0018](adr/0018-fast-redeploy-parallel-tracks-golden-snapshot.md)), `destroy.ps1 -Force` ran once against the demo environment (15:33-15:51 UTC, 1,102 seconds), then `deploy.ps1` restored it.

| Result | Outcome |
|---|---|
| `DESTROY.GOLDEN.GUARD` | **Pass:** the boot-verified snapshot keeps the setup-wizard step |
| `DESTROY.ARC.SQLINSTANCES`, `DESTROY.ARC.MACHINES` | **Pass**, but they reported "Deleted 0 of 1": a bug skipped the explicit deletes (the collection was nested in an array), so the Arc resources went with the group. Fixed the same day; a unit test now uses the collection as the real function returns it |
| `DESTROY.RESOURCEGROUP` | **Pass**, 5 minutes |
| `DESTROY.DEPLOYMENT` | **Pass** (`dbhub-demo-main`) |
| `DESTROY.GOLDEN` | **Not selected:** `rg-dbhub-golden` kept |
| `TEARDOWN.RESIDUAL.GROUPRESOURCES`, `.ARC` | **Fail:** 10 Resource Graph rows under the deleted group, the Arc SQL instance's child `databases` among them, still listed in a read-only recheck about 16 minutes after the group was gone. The group itself was gone (`TEARDOWN.RESIDUAL.RESOURCEGROUP` **Pass**), so these are stale index rows of resources the group delete removed; the fixed explicit delete removes the instance (and its databases) before the group |
| `TEARDOWN.RESIDUAL.BUDGET` | **Fail:** the budget `budget-dbhub-demo` at the group's scope was still readable after the group was gone, as Phase 16 found in `rg-dbhub-test` (R273); the destroy ran on code from before Phase 16's `DESTROY.BUDGET`. It wasn't deleted afterward: the redeploy's template (the group deployment `budget`, 16:03 UTC) wrote the same budget again for the new group, so it's the live environment's budget now, and the next destroy deletes it |
| `TEARDOWN.RESIDUAL.DEPLOYMENTS` | **Fail:** `dbhub-demo-foundation`, a deployment record from the 2026-10-20 foundation deployment, which no current script creates. Deleted by hand (history only) |
| `TEARDOWN.RESIDUAL.ROLEASSIGNMENTS` | **Fail:** one role assignment, **Storage Blob Data Contributor** on a storage account in another resource group of the subscription, which the tenant's governance automation created (2026-10-22, 08:37 UTC) for one of the demo's managed identities. The demo doesn't create it, and removing it needs Owner (or User Access Administrator, or Role Based Access Control Administrator; Contributor can't), so it's left untouched for the owner; it doesn't bill. Expect it after every destroy while that automation runs |
| `TEARDOWN.RESIDUAL.REFERENCES` | **Warning:** the golden snapshot names its source group (by design); the check now skips `rg-<prefix>-golden` |
| `TEARDOWN.RESIDUAL.IDENTITIES` | **Warning** in the run (Microsoft Graph refused the cached token with a claims challenge); **Pass** in a read-only rerun with Phase 16's claims-challenge retry |

### Test environment (`rg-dbhub-test`, `Developer`)

Run on 2026-10-21 and 2026-10-22 with `-SkipFabric`, never against `rg-dbhub-demo`, as the coordinator decided: a disposable environment with `t2SqlInstallMode` `Developer`, so no manual step is needed. The [implementation report](implementation-report.md#phase-16-cleanup-testing) has the timeline.

| Step | Result |
|---|---|
| Preflight (`PREFLIGHT.*`), 2026-10-21 | No Fail. `PREFLIGHT.P4.HUBSETTING` **Manual action required**; **Warning** for Defender plans enforced by policy, policy-added extensions, public IP tags, policies that add system-assigned identities to VMs (`PREFLIGHT.POLICY.OTHER`; the manifest records those identities too), and the T3 free offer (the subscription's free databases are in another region, so T3 falls back to regular serverless) |
| Cost estimate (`lowest-cost`, private mode), 2026-10-21 | **Pass:** a 5-hour session 7.41 USD (ceiling 15), idle plus 10 hours a month 65.12 USD (ceiling 250), of which Defender for Cloud 0.57 and 20.97 |
| Deploy, 2026-10-21 | T1 and T3 **Pass** (telemetry 58.5 and 62.9 minutes after the start); T2's Arc onboarding **Fail**: the guest resolved no name, because the host's DNS Server never bound the new NAT gateway address (fixed in Phase 16's follow-up) |
| T2 onboarding again, 2026-10-22 (`deploy.ps1 -FromStage T2`) | **Pass:** the Arc machine **Connected** after 7.1 minutes, the Arc SQL Server instance after 27.9 |
| `stop-demo.ps1`, 2026-10-22 | **Pass** in 4.2 minutes |
| Destroy and the residual check, 2026-10-22 (`Invoke-TeardownTest.ps1 -Destroy`: 24 minutes, with 10 minutes of polling and the 11 live teardown tests) | **Pass** for the group (deleted in 4 minutes), the Arc machine and its SQL Server instance, the deployment record, everything tagged with the `deploymentId`, and the 4 managed identities with their P6 membership. Two **Fail** results: the budget at the group's scope outlived the group (deleted by its URL; `destroy.ps1` now deletes it, `DESTROY.BUDGET`), and an orphaned role assignment that the tenant's governance automation, not the demo, gave one of the identities on a storage account in another resource group (removing it needs Owner, User Access Administrator, or Role Based Access Control Administrator; left for the owner) |
| Subscription snapshot after destroy, compared with the one before deploy | Nothing of the test environment in resources, resource groups, role assignments, policy assignments, deployment stacks, budgets, or diagnostic settings. The stack trial's two subscription deployment records were still there and were deleted; the trial now deletes them itself |
| Redeploy of the same environment | Not run here: Phase 20 tests the redeploy through the T2 snapshot restore |

### Deployment-stack trial (`rg-dbhub-stacktest`), 2026-10-21

`./tests/teardown/Invoke-DeploymentStackTrial.ps1` with free user-assigned identities only, run twice: before the subscription guard update (run 1, 17:23 UTC, stopped by a session restart after `SUB.CREATE`) and after it (run 2, 20:59–21:15 UTC, complete). The outcome is recorded in [ADR 0001](adr/0001-iac-bicep-avm-compiled-arm.md).

| Check | Run 1 | Run 2 |
|---|---|---|
| `TEARDOWN.STACK.CONTRIBUTOR` | **Pass** | **Pass:** Contributor can write, read, and delete deployment stacks; `Microsoft.Resources/deploymentStacks/manageDenySetting/action` is one of its `notActions`, so deny settings other than `none` need Owner or Azure Deployment Stack Owner |
| `TEARDOWN.STACK.GROUP.CREATE` | **Pass**, 57 s | **Pass**, 53 s |
| `TEARDOWN.STACK.GROUP.UNMANAGED` | **Pass** | **Pass:** an identity created outside the stack, like the Arc resources onboarding creates |
| `TEARDOWN.STACK.GROUP.UPDATE` | **Pass**, 147 s | **Pass**, 144 s: `deleteResources` deleted the identity dropped from the template and left the unmanaged one alone |
| `TEARDOWN.STACK.GROUP.DENY` | **Pass**, 58 s | **Pass**, 53 s: `denyDelete` applied as the signed-in user, and deleting a managed identity directly was denied |
| `TEARDOWN.STACK.GROUP.DELETE` | **Pass**, 136 s | **Pass**, 128 s: `deleteAll` with `denyDelete` still on; the resource group was kept |
| `TEARDOWN.STACK.SUB.CREATE` | **Pass**, 78 s | **Pass**, 53 s: the stack created the resource group and an identity |
| `TEARDOWN.STACK.SUB.DELETE` | Not recorded (the client stopped; a read-only check found everything gone) | **Pass**, 370 s: `az stack sub delete --action-on-unmanage deleteAll`, with an identity created outside the stack in its resource group; the group was gone, with everything in it, 4 s later |
| `TEARDOWN.STACK.CLEANUP` | Not recorded | **Pass:** no trial stack, no resource group, no deny assignment on it |

## When something fails partway

- **Interrupted destroy** (Ctrl+C, a sleeping laptop, an Actions timeout): run `destroy.ps1` again. It deletes what's left of the group, then the deployment record, then runs the residual check. A group that's still being deleted (`ResourceGroupBeingDeleted`) is waited for. The manifest the earlier run recorded is kept: when the group is gone, it replaces the new one, which can't know the identities; while the group still exists, the identities it recorded for the same `deploymentId` are added, because some of their resources may already be gone. Without any manifest, the `deploymentId` comes from the deployment record's output, and the identity check is a **Warning**.
- **`DESTROY.ARC.*` Fail:** an Arc resource couldn't be deleted, so nothing else was. Delete it in the portal (**Azure Arc**, then **SQL Server instances**, then **Machines**), then run `destroy.ps1` again. Learn notes that a deleted Arc SQL Server resource can stay visible in the portal for a while because of caching; Resource Graph is the reference, and it doesn't bill.
- **`DESTROY.RESOURCEGROUP` Fail:** a lock or a policy blocked the delete. Locks are off by default (`enableLocks`), and removing one needs more than Contributor ([ADR 0001](adr/0001-iac-bicep-avm-compiled-arm.md)).
- **`DESTROY.RESOURCEGROUP` Warning:** the group was still being deleted after `-WaitMinutes`. Run `destroy.ps1` again later; it finishes the cleanup and checks again.
- **`DESTROY.DEPLOYMENT` Warning:** delete the record yourself: `az deployment sub delete --name <prefix>-<environment>-main --subscription <subscriptionId>`.
- **`DESTROY.BUDGET` Warning:** delete the budget `budget-<prefix>-<environment>` in Cost Management under **Budgets**, with the resource group as the scope; it stays listed after the group is gone.
- **`DESTROY.RESIDUAL` Fail:** the failing `TEARDOWN.RESIDUAL.*` results list what's left in their evidence (`remaining`). Run `destroy.ps1` again for anything in the group; delete anything outside it by name in the portal, or with `az resource delete --resource-group <group> --name <name> --resource-type <type> --subscription <subscriptionId>`. A role assignment left behind (`Identity not found` in **Access control (IAM)**) needs Owner, User Access Administrator, or Role Based Access Control Administrator.
- **`DESTROY.RESIDUAL` Warning:** nothing was found, but some check couldn't be verified: Resource Graph didn't list the configured subscription, Microsoft Graph answered for another tenant, a read failed, or the check itself couldn't run after the deletes. Run `./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath <path>` later; it reads the manifest and checks again without deleting anything.
- **A deployment that failed halfway:** `destroy.ps1` handles a partial environment the same way; whatever wasn't created is skipped.

## The on-demand activity control

Destroy never touches `rg-<prefix>-control`, so the optional on-demand activity control ([ADR 0020](adr/0020-on-demand-activity-control.md)) survives every redeploy; only its A1 role assignment goes with the demo resource group. Its resources carry no `environment` or `deploymentId` tag, so the residual check doesn't count them. To remove it for good:

```powershell
./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -Remove -WhatIf   # what it would delete
./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -Remove          # asks before each step
```

In order, it deletes (`CONTROL.REMOVE.*`):

1. **Fabric:** `NB_DatabaseHub_Control` from the existing workspace, its folder "DBHub Control" when it's empty, and the "DBHub Control" workspace with its managed private endpoint, through the documented Fabric REST Delete calls. `-SkipFabric` leaves Fabric alone (for example while the capacity is paused); delete those items in Fabric yourself then.
2. **The role assignments and the role:** A1, A2, every Key Vault Secrets User assignment on the secret (A3), and the custom role DbHub Demo Activity Operator. This needs an Owner, as granting did; without one, it reports **Manual action required** and leaves the rest of the list to run.
3. **The Azure resources, one by one:** the Automation account (with its runbooks, schedules, and webhook), the identity `id-<prefix>-automation`, and the vault, which it then purges (purge protection is off for that reason, so the name is free at once), and the template deployment records.
4. **The group** `rg-<prefix>-control`, only when nothing else is left in it: it may also hold the GitHub OIDC identity ([ADR 0002](adr/0002-resource-group-topology.md)), which `-Remove` never deletes.

`-Force` skips the questions. Turn `control.enabled` off afterwards, so `validate.ps1` and `status.ps1` stop checking it.

## Arc cleanup

- **Order:** SQL Server instances (with their Arc SQL databases, which are child resources), then machines (with their extensions, license profiles, and Run Commands), then the resource group. `destroy.ps1` lists both types in the group through the documented REST APIs ([machines](https://learn.microsoft.com/rest/api/hybridcompute/machines/delete), [SQL Server instances](https://learn.microsoft.com/rest/api/azurearcdata/sql-server-instances/delete)) and waits until each read returns Not Found.
- **T1's instances:** SQL Server on Azure VMs appear in unified inventory as `sqlServerInstances` whose `containerResourceId` is the Compute VM; they're in the same group and go in the same step. The residual check also finds an instance hosted by a machine or VM of the group, wherever it is.
- **The guest's agent:** the Connected Machine agent and the Azure extension for SQL Server stay installed inside the guest, but the guest's disk is on the T2 host, which the destroy deletes. For a machine you keep, follow Learn instead: tag it `ArcSQLServerExtensionDeployment` `Disabled`, uninstall the extension, delete the instance resource, then disconnect the agent ([azcmagent disconnect](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-disconnect)).
- **Billing:** pay-as-you-go SQL Server bills while the instance reports usage; with the guest and its resources gone, nothing bills ([manage licensing and billing](https://learn.microsoft.com/sql/sql-server/azure-arc/manage-license-billing)).

## Defender for Cloud and Azure Policy remnants

- **Extensions that policy adds** (in this tenant `ConfigurationforWindows`, `AdvancedThreatProtection.Windows`, and Defender's agents; `PREFLIGHT.POLICY.EXTENSIONS`) are child resources of the VMs and the Arc machine and go with them.
- **Defender plans** are subscription settings that bill per protected resource ([ADR 0016](adr/0016-cost-profiles.md)), so they stop billing for the demo when its resources are gone. Destroy doesn't change them.
- **Records about deleted resources:** Defender for Cloud assessments, Azure Policy compliance states, and guest configuration assignments can still list the deleted resources for a while. They aren't resources, can't be deleted, don't bill, and the services remove them; `TEARDOWN.RESIDUAL.RECORDS` reports them as evidence.
- **Diagnostic settings** outlive the resource they belong to, and Learn warns that a recreated resource with the same name picks them up again ([diagnostic settings](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings)). The demo creates none, and the policy inventory found no rule in this tenant that adds one to the demo's resource types.
- **Shared resources:** a resource that Defender or a policy creates outside the group for the whole subscription is shared and stays; `TEARDOWN.RESIDUAL.REFERENCES` reports any resource outside the group that still names it, so you can decide.

## The shared demo environment

`rg-dbhub-demo` (environment `demo`) holds the owner's `PaygWizard` setup-wizard step: SQL Server 2022 Standard pay-as-you-go installed in the T2 guest through **Use Azure Login**, more than an hour of manual work that no script can redo. **Never destroy it without the owner's explicit go-ahead.** Since Phase 20, `destroy.ps1` itself refuses unless a boot-verified golden snapshot keeps that step (or `-WithoutGolden`), and the next `deploy.ps1` restores T2 from the snapshot. Run teardown tests in a disposable environment instead: its own `environment` name (so its own resource group) and `t2SqlInstallMode` `Developer`. `tests/teardown/Invoke-TeardownTest.ps1 -Destroy` refuses environment `demo` and any `PaygWizard` environment unless `-IncludeDemoEnvironment` records that go-ahead, and the **destroy** workflow needs the environment's name typed again. The **expiry** workflow deletes an environment the day after its `expiresOn` tag, on its schedule once `DBHUB_SCHEDULES_ENABLED` is `true` or when someone runs it; the demo environment has no `expiresOn`, so it never expires.

## The subscription guard and the default subscription

You don't need to change the Azure CLI's default subscription for any script, and no script changes it (`az account set`) or signs in (`az login`). Every script runs the subscription guard (`Assert-DemoAzContext`) before any Azure work ([ADR 0011](adr/0011-control-surface-priority.md), guard update). It checks `az account show --subscription <subscriptionId>`, the tenant, and the account (`azureAccount` in the configuration; without it, the guard is a **Warning**), then read-only canaries, and caches the validated context for the process. Every Azure CLI call names the configured subscription (`Invoke-DemoAz`), writes and token requests wait for the guard, and tokens come from `Get-DemoAccessToken` with their tenant and caller checked. Another tool or session can keep its own default. If the guard fails, nothing was read or deleted: sign in to the configured tenant (`az login --tenant <tenantId>`) and run the script again.

The residual check reads Resource Graph and Microsoft Graph with verified tokens and canaries ([above](#the-residual-check)). A **Warning** that names one of them means the deletes ran, but those checks couldn't be verified with this sign-in. Run `./tests/teardown/Invoke-TeardownTest.ps1` again later; it changes nothing.

**Optional, on a machine that several people or agents share** (also in [prerequisites](prerequisites.md)): the Azure CLI keeps its configuration, sign-ins, and default subscription in the folder `AZURE_CONFIG_DIR` names (by default `%USERPROFILE%\.azure` on Windows, `$HOME/.azure` elsewhere; [Azure CLI configuration](https://learn.microsoft.com/cli/azure/azure-cli-configuration)). Setting it to a folder of your own in your shell before `az login --tenant <tenantId>` keeps your sign-in and default apart from everyone else's, and theirs apart from yours:

```powershell
$env:AZURE_CONFIG_DIR = Join-Path -Path $HOME -ChildPath '.azure-dbhub'
az login --tenant <tenantId>
./scripts/destroy.ps1 -ConfigPath ./out/demo.config.test.json
```

## Cost after destroy

With the resource group gone, nothing of the demo bills: no compute, disks, public IPs, Bastion, SQL, or budget ([ADR 0016](adr/0016-cost-profiles.md)). The golden group, which destroy keeps, bills for its snapshot's used size until `-IncludeGolden` deletes it. Cost Management keeps showing the charges up to the delete for a day or two, because usage arrives late. A soft-deleted opt-in Key Vault holds only secrets and allows no operation but recover or purge, so it doesn't bill ([soft delete](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview)).
