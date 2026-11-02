# ADR 0002: One demo resource group plus an optional control resource group

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** Engineering, building on user decisions Q4c (GitHub OIDC identity in `rg-<prefix>-control`) and plan §9.1 (Contributor on an existing subscription)
- **Related:** [ADR 0001](0001-iac-bicep-avm-compiled-arm.md), [ADR 0008](0008-identity-rbac-abac.md), [cleanup](../cleanup.md)

## Context

- The brief asks for every demo resource in one resource group and one deployment.
- The deploying identity holds Contributor on the subscription (plan §9.1). It can create and delete resource groups, so a subscription-scope deployment can own the resource group's whole lifecycle.
- The optional GitHub Actions identity (prerequisite P7) has to exist before a pipeline deploy and survive every destroy.
- SQL Server enabled by Azure Arc reads the license type for auto-deployed extensions from the resource-group tag `ArcSQLServerExtensionDeployment`. The demo sets it to `PAYG`.
- No cascade from `Microsoft.HybridCompute/machines` to `Microsoft.AzureArcData/sqlServerInstances` is documented. Both are created outside the template by Arc onboarding.
- Key Vault is no longer deployed (plan §9.1, ADR 0009), so soft-deleted vault names can't block a redeploy.

## Decision drivers

1. Zero residual resources after destroy, including Arc projections.
2. Repeatable deploy → destroy → deploy cycles with no manual cleanup.
3. Clear separation between demo resources and the long-lived GitHub identity.
4. Re-runs that resume where they stopped.

## Considered options

1. One resource group holding the demo and the GitHub identity.
2. **A demo resource group created by the subscription-scope deployment, plus an optional control resource group for the GitHub identity.**
3. A pre-created resource group with a resource-group-scope deployment.

## Decision

Option 2.

- **Demo resource group:** `rg-<prefix>-<env>` (default `rg-dbhub-demo`), created by `infra/main.bicep` at subscription scope. It holds every demo resource: network, VMs, Azure SQL, schedules, and budget. *(The artifact cache storage account was dropped on 2026-10-20; ADR 0016, C9.)*
- **Control resource group:** `rg-<prefix>-control` exists only when the GitHub path is used. `scripts/setup-github-oidc.ps1` creates it with the user-assigned identity and its federated credentials. `destroy` never touches it.
- **Tags:** the template sets the resource group's tags to `union(existingResourceGroupTags, requiredTags)`. `deploy.ps1` reads the group's current tags and passes them in, so tags added outside the template survive a re-run, and the required tags always win. The tags are `solution`, `environment`, `owner`, `purpose`, `costCenter`, `autoShutdown`, `deploymentId`, `ArcSQLServerExtensionDeployment=PAYG`, an optional `expiresOn`, and the orchestrator's progress tag `dbhubDeployStage`. *(Phase 5: this replaces the earlier `Microsoft.Resources/tags` design, which a subscription-scope resource-group resource would overwrite anyway.)*
- **`deploymentId`:** six lowercase alphanumeric characters, deterministic by default (`take(uniqueString(subscription().id, prefix, environment), 6)`), so every lifecycle of the same environment uses the same names. Globally unique names (the Azure SQL logical server) carry it as a suffix.
- **Resume:** after each stage succeeds, `deploy.ps1` records it in `dbhubDeployStage`. `-Resume` continues from the next stage. Every stage is idempotent, so a full re-run also converges.
- **Arc resources** are created with `azcmagent connect --tags` that include `deploymentId`, so the residual-resource check finds them.
- **Destroy order** (`scripts/destroy.ps1` and `destroy.yml`):
  1. Stop activity profiles and scenarios.
  2. Delete every `Microsoft.AzureArcData/sqlServerInstances` resource in the group.
  3. Delete `Microsoft.HybridCompute/machines/arcsql01`.
  4. Delete the resource group.
  5. Run an Azure Resource Graph query to confirm nothing tagged with this `deploymentId` remains, and report **Pass** or **Fail**.
- **Expiry:** an optional `expiresOn` tag drives a scheduled destroy workflow ([ADR 0016](0016-cost-profiles.md), C4).

## Consequences

- **Positive:** one command removes everything. No soft-deleted names linger. The GitHub identity survives destroy, so the pipeline can redeploy without an administrator.
- **Negative:** the deploying identity needs Contributor at subscription scope, not just on the resource group. This is the documented minimum (P1).
- **Risk accepted:** deterministic names mean a second environment in the same subscription needs a different `environment` or `prefix`. Preflight checks for collisions.

## Validation

- **Phase 5 (live, pending go-ahead):** deploy, redeploy, and confirm no changes; resource-group tags are merged, not replaced; `-Resume` skips completed stages.
- **Phase 16:** destroy leaves zero resources tagged with the `deploymentId`, including Arc resources; a later deploy of the same environment succeeds. Unit-tested; the live run is in the Phase 16 addendum.

## Phase 16 addendum: destroy as built and tested (2026-10-21)

**Destroy order as built** (`Remove-DemoEnvironment`, called by `destroy.ps1`, `destroy.yml`, and `expiry.yml`):

1. Record a manifest, read-only: the group's `deploymentId` tag (or, once the group is gone, the `deploymentId` output of the subscription deployment record), the Microsoft Entra principal IDs of every managed identity in the group, and the names the check needs. It's written to `out/destroy-manifest-<environment>.json`, names and IDs only; a run that finds the group already gone keeps the manifest recorded while it existed.
2. Delete every `Microsoft.AzureArcData/sqlServerInstances` resource in the group (T2's, and T1's unified-inventory instances), then every `Microsoft.HybridCompute/machines` resource.
3. Delete the resource group and wait until it's gone.
4. Delete the subscription deployment record `<prefix>-<environment>-main` (`dbhub-<environment>-main` before Phase 28, whatever the prefix), which outlives the group (`DESTROY.DEPLOYMENT`), and the budget at the group's scope, which outlives it too (`DESTROY.BUDGET`, live finding 2026-10-22).
5. Run the residual check (`Test-DemoTeardownResidue`, `TEARDOWN.RESIDUAL.*`), summed up in `DESTROY.RESIDUAL`.

**Changes from the decision above:**

- The original step 1, "stop activity profiles and scenarios", is dropped: they run on T1 and the T2 host, which the destroy deletes, and T3's workload comes from T1.
- The residual check covers more than resources tagged with the `deploymentId`: the group itself; everything carrying the environment's tags (the `deploymentId`, or `solution` with `environment`, so it still works without the manifest), except `rg-<prefix>-control`; Arc resources in the group, carrying those tags, or hosted by one of its machines or VMs; role assignments at or under the group and for the manifest's identities; the identities themselves and their membership in the P6 group; subscription deployment records; and the budget. Resources outside the group that still name it are a Warning (they may be shared), and the records Defender for Cloud, Azure Policy, and guest configuration keep about the deleted resources are evidence, not residue. The check names are aligned with Phase 14's read-only `TEARDOWN.RESIDUAL`.
- A destroy that stops halfway is finished by running it again: every step is idempotent, and steps 1, 4, and 5 also run when the group is already gone. A group still being deleted (`ResourceGroupBeingDeleted`) is waited for, and the identities an earlier run recorded are kept.
- Resource Graph and Microsoft Graph are read through `Invoke-DemoRestRequest` with tokens verified for the configured tenant and caller (ADR 0011, guard update), and only after a canary shows they answer for the configured subscription and tenant; otherwise their checks are Warnings, never a Pass (live, 2026-10-21: another tool had switched this machine's shared default subscription to another tenant, and `az rest` and `az ad` follow that default for those URLs).

**Live results** (2026-10-21 and 2026-10-22, in the disposable `rg-dbhub-test` with `t2SqlInstallMode` `Developer`; the shared `rg-dbhub-demo` is never destroyed without the owner's explicit go-ahead): destroy deleted the group in 4 minutes, the Arc machine and its SQL Server instance, the deployment record, and the four managed identities, and the residual check found nothing carrying the `deploymentId` and no Arc resource. Two findings: the budget at the group's scope outlives the group, so `destroy.ps1` now deletes it (`DESTROY.BUDGET`); and a role assignment that the tenant's governance automation gave one of the identities, outside the group, stays orphaned until someone with Owner or User Access Administrator removes it, and the residual check reports it. [Cleanup](../cleanup.md#tested-results) has the details. The redeploy of the same environment is tested in Phase 20, through the T2 snapshot restore.

## Phase 20 addendum: the golden group (2026-10-22)

- **A third resource group, `rg-<prefix>-golden`,** holds the T2 golden snapshots ([ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md)). It belongs to the prefix, not to one environment: its tags are `solution`, `purpose`, `owner`, `costCenter`, `dbhubPrefix`, and `environment` `golden`, with no `deploymentId` and no expiry, so an environment's residual check doesn't count it.
- **Destroy keeps it** (`DESTROY.GOLDEN` **Not selected**) unless `-IncludeGolden`, and before deleting a `PaygWizard` environment it requires a boot-verified snapshot there (`DESTROY.GOLDEN.GUARD`), unless `-WithoutGolden`.
- **The live destroy of `rg-dbhub-demo` (2026-10-22, Phase 20's G5)** left the budget at the group's scope behind, as Phase 16 found in `rg-dbhub-test` (R273); step 4's `DESTROY.BUDGET` now deletes it. It also showed that the explicit Arc deletes skipped every resource (a nested array; the group's delete removed the Arc resources instead); they now see every resource, with a test.
- The quarantine test uses its own disposable environment, `gtest` (`rg-<prefix>-gtest`), tagged `purpose` `t2-golden-boot-test` and deleted through the same destroy path.

## Phase 25c addendum: the on-demand activity control (2026-10-26)

- **`rg-<prefix>-control` also holds the optional on-demand activity control** ([ADR 0020](0020-on-demand-activity-control.md)): the identity `id-<prefix>-automation`, the Automation account `aa-<prefix>-control` with its runbooks, schedules, and webhook, and the vault `kv-<prefix>-ctl-<suffix>`. `scripts/setup-activity-control.ps1` creates the group when it doesn't exist (with the control's tags), and keeps the tags of a group that the GitHub path created.
- **Destroy still never touches the group**, and the control's resources carry no `environment` or `deploymentId` tag, so the residual check doesn't count them. `setup-activity-control.ps1 -Remove` deletes the control's resources one by one, and the group only when nothing else is left in it, because the GitHub OIDC identity may live there too ([cleanup](../cleanup.md#the-on-demand-activity-control)).
- **One role assignment reaches into the demo group:** A1, the control's custom role for its identity at `rg-<prefix>-<environment>`. The group's deletion removes it, and `deploy.ps1` grants it again after a redeploy when `assignRoles` and `control.enabled` are true; otherwise `DEPLOY.SUMMARY` reports Manual action required with the `-GrantRole` command.

## Sources (checked 2026-10-19)

- Subscription-scope deployments: <https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription>
- Apply tags with Bicep (`Microsoft.Resources/tags`): <https://learn.microsoft.com/azure/azure-resource-manager/management/tag-resources-bicep>
- Arc auto-deploy and the license-type tag: <https://learn.microsoft.com/sql/sql-server/azure-arc/manage-autodeploy>
- Delete SQL Server from Azure Arc: <https://learn.microsoft.com/sql/sql-server/azure-arc/delete-from-azure-arc>
- `azcmagent connect` (`--tags`): <https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-connect>
- OIDC from GitHub: <https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect>
- `az group delete` and `az deployment sub delete` (checked 2026-10-21): <https://learn.microsoft.com/cli/azure/group#az-group-delete>, <https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-delete>
- Delete Arc machines and SQL Server instances through REST (checked 2026-10-21): <https://learn.microsoft.com/rest/api/hybridcompute/machines/delete>, <https://learn.microsoft.com/rest/api/azurearcdata/sql-server-instances/delete>
- Azure Resource Graph tables for the residual check (checked 2026-10-21): <https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources>
