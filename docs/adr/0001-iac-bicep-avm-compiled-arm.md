# ADR 0001: Infrastructure as code with Bicep, Azure Verified Modules, and a compiled `azuredeploy.json`

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** Engineering (approved plan §4, §7, §9.2, §9.6)
- **Related:** [ADR 0002](0002-resource-group-topology.md), [ADR 0003](0003-t2-host-size-security-type-bootstrap.md), [ADR 0011](0011-control-surface-priority.md), [architecture](../architecture.md)

## Context

- The repo is greenfield. It has no Terraform, so the brief's rule ("Bicep unless the repo already uses Terraform") selects Bicep.
- The deploying user is assumed to hold only **Contributor on an existing subscription** (plan §9.1). Contributor can create resource groups, deploy at subscription scope, and register resource providers, but can't create role assignments.
- The primary one-click path is a single orchestrator, `scripts/deploy.ps1` locally or `deploy.yml` in GitHub Actions (ADR 0011). The **Deploy to Azure** button is secondary: it provisions infrastructure and starts the in-VM bootstraps (Phase 6 narrowed this to infrastructure only; see the Phase 6 addendum), then links to the one-command finish. ARM can't carry the caller's token for Arc onboarding, and the documented SQL VM monitoring feature flag is set with the Azure CLI only.
- The Deploy to Azure button takes an ARM JSON template from a publicly reachable URL. A template in a private location needs a SAS-secured storage URL.
- Bicep can embed text files at compile time with `loadTextContent()`. Each loaded file is limited to 96 KB, and a compiled ARM template is limited to 4 MB.
- Binaries (the workload runner) and large media (Windows Server and SQL Server installers) don't fit in a template and must not depend on the private repo being reachable from the VMs.
- Deployment stacks can manage a set of resources as one unit, including deleting resources that leave the template. Whether they fit this demo (Arc resources are created outside the template; Contributor-only rights) needs evaluation.

## Decision drivers

1. One source of truth for every path: script, Actions, and button.
2. Works with Contributor alone; no role assignments required.
3. Reviewable, pinned, lint-clean IaC whose re-runs converge.
4. No dependency on the private repo from inside Azure.

## Considered options

1. **Subscription-scope Bicep, AVM where it fits, compiled to a committed `azuredeploy.json`, plus an artifact cache for binaries and media** (the artifact cache was dropped on 2026-10-20; see below).
2. Resource-group-scope Bicep with the resource group created out of band.
3. Terraform (`azurerm` plus `azapi`).
4. ARM JSON written by hand.

## Decision

Option 1.

- **Layout:**
  - `infra/main.bicep` has `targetScope = 'subscription'`. It creates the demo resource group and deploys `infra/modules/demo.bicep` (resource-group scope) into it.
  - `infra/main.bicepparam` holds defaults.
  - `infra/modules/` has one module per concern: network, NSGs, budget, T1 VM, T2 host, T3 SQL, schedules, Bastion, tags, and the bootstrap loader.
- **Azure Verified Modules:** use AVM resource modules from the public Bicep registry (`br/public:avm/res/...:<exact version>`) when they expose every property we need, for example the virtual network, NSGs, and public IP. Use hand-written modules where AVM is missing or hides a property the demo depends on: `Microsoft.SqlVirtualMachine/sqlVirtualMachines`, managed Run Commands, `Microsoft.DevTestLab/schedules`, `Microsoft.Consumption/budgets`, and `Microsoft.Resources/tags`. Every module and API version is pinned in the Bicep files and listed in `config/versions.json`.
- **Compiled template:** `azuredeploy.json` at the repo root is generated with `bicep build infra/main.bicep --outfile azuredeploy.json`. Registry modules are inlined at build time. CI rebuilds it and fails when the committed file differs. `azuredeploy.parameters.json` holds non-secret defaults only.
- **Linting:** `bicepconfig.json` enables the core linter. Rules about secrets (`secure-secrets-in-params`, `outputs-should-not-contain-secrets`, `secure-parameter-default`) are errors. PSRule for Azure runs in CI as an additional Well-Architected check.
- **Parameters:** validated with decorators (`@allowed`, `@minLength`, `@maxLength`, `@minValue`, `@maxValue`, `@secure()`, `@description`) and user-defined types for profiles and install modes. Inputs are limited to what can't be discovered: subscription, region, prefix, environment, profile, network mode, T2 install mode, the P6 Entra group, owner email, and cost center.
- **Re-runs and VM passwords:** `osProfile.adminPassword` can't change on an existing VM. `deploy.ps1` looks up which VMs already exist (read-only) and passes that list in, and the template omits `osProfile` for those VMs. A generated password is used only when a VM is created (ADR 0009).
- **Artifact delivery (revised 2026-10-20):** the artifact cache, a storage account that held the runner build, the bootstrap script bundle, and pinned media behind short-lived SAS URLs, was dropped. The tenant's governance policies force storage accounts to disable shared-key and public network access, and Defender for Storage adds about $10 a month per account. The bootstrap bundle now travels in SHA-256-checked Run Command chunks, and media downloads directly from pinned Microsoft URLs with SHA-256 checks. Phase 6 implements both.
- **Bootstrap loader:** a small loader script is embedded with `loadTextContent()` in a managed Run Command so the button path can start the bootstraps. The loader waits until the one-command finish delivers the bootstrap bundle. On the script path, `deploy.ps1` delivers it first, so the loader proceeds immediately. CI checks every embedded file's size and warns when `azuredeploy.json` exceeds 3 MB. *(Refined in Phase 6: the loader never waits, and the button deploys no loader; see the Phase 6 addendum.)*
- **Outputs:** names, resource IDs, and non-secret endpoints only.
- **Locks:** `enableLocks` defaults to `false`. Removing a lock needs `Microsoft.Authorization/locks/*`, which Contributor doesn't have, so `destroy` refuses to run against a locked deployment and names the permission needed.
- **Idempotency:** names are deterministic from `prefix`, `environment`, and `deploymentId`. `newGuid()` and `utcNow()` are never used in names. Run Commands carry a content hash so they re-run only when their script changes.
- **What-if:** `deploy.ps1` runs `az deployment sub what-if` before it deploys, and stops after it with `-WhatIf`.
- **Deployment stacks:** evaluated in Phase 5 against plain deployments for drift-free re-runs and clean deletes. If adopted, the stack is created at subscription scope with deny settings off (Contributor can't create deny assignments). Arc resources created outside the template are always deleted explicitly by `destroy` (ADR 0002). The outcome is recorded in a superseding note on this ADR.
- **Deploy to Azure button:** it works only when the repo is public (raw URL of `azuredeploy.json`). While the repo is private, the README says so and points to `deploy.ps1` and `deploy.yml`.

## Consequences

- **Positive:** one template serves every path. Reviewers read Bicep while the button consumes ARM. VMs never need access to the private repo.
- **Negative:** the generated `azuredeploy.json` is large and noisy in diffs, so `.gitattributes` marks it as generated. AVM version bumps are manual because Dependabot has no Bicep-registry ecosystem; `CONTRIBUTING.md` documents the review cadence. Without the artifact cache (dropped 2026-10-20), a guest rebuild downloads its media from Microsoft again.
- **Risk accepted:** the button stays secondary and doesn't work until the repo is public.

## Validation

- **Phase 4 (static, CI):** `bicep build` and lint pass with no errors; PSRule passes or has documented exclusions; the `azuredeploy.json` sync check passes; embedded-file and template-size checks pass.
- **Phase 5 (live, pending go-ahead):** subscription what-if is clean; a deploy followed by a second deploy changes nothing beyond no-op updates; the deployment-stack evaluation is recorded.
- **Phase 16 (live, 2026-10-21):** the deployment-stack trial; see the Phase 16 addendum.

## Phase 5 addendum: deployment stacks evaluation (2026-10-19)

A desk evaluation; the live trial is pending go-ahead.

- **What stacks would add:** with `actionOnUnmanage` set to delete, removing an optional resource from the template (the NAT gateway, the T3 private endpoint) would also delete it in Azure. Plain incremental deployments leave it behind.
- **What they wouldn't fix:**
  - Arc resources are created outside the template, so `destroy` still deletes them explicitly (ADR 0002).
  - Contributor can't create deny assignments, so deny settings must stay off.
  - What-if support for stacks still needs confirming; preflight runs a plain subscription what-if regardless.
- **Decision for v1:** plain subscription deployments. `deploy.ps1` explicitly deletes optional resources that a configuration change turns off (ADR 0017), and `destroy` deletes the resource group.
- **Next step:** deployment stacks are tried live in Phase 16. If the trial shows clean create, update, and delete under Contributor, a superseding note switches to them.

## Phase 6 addendum: bootstrap loader delivery (2026-10-19, revised 2026-10-20)

The bootstrap loader decision is refined; details are in the [ADR 0003 Phase 6 notes](0003-t2-host-size-security-type-bootstrap.md#phase-6-implementation-notes-2026-10-19).

- **The bundle travels in Run Command chunks.** `Send-DemoBootstrapBundle` delivers the bundle to each VM in SHA-256-checked chunk Run Commands, one at a time, and deletes each after it succeeds. There's no storage account, SAS, or key.
- **The loader doesn't wait for anything.** `infra/modules/bootstrap.bicep` deploys the loader Run Commands only when `bootstrapBundleSha256` (with `bootstrapChunkCount`) is set, which `deploy.ps1` does after the chunks are delivered. The loader assembles the bundle from the chunks it finds, or fails closed and names the missing ones.
- **Deploy to Azure button: infrastructure only (documented deviation).** The portal can't send the chunks, so the button leaves `bootstrapBundleSha256` empty: it creates the network, the budget, both VMs, the SQL VM registration, and the schedules, and the bootstraps start on `deploy.ps1 -Resume`. It still works only once the repo is public.
- **Re-runs:** the Run Command's parameters carry the bundle's SHA-256 and chunk count, so a changed bundle re-runs the loader; an unchanged one doesn't run again, and the scheduled task keeps converging. `treatFailureAsDeploymentFailure` stays `false`, so `Wait-DemoBootstrapLoader` reads the loader's instance view and reports its exit code.
- **Size:** the loader is about 18 KB, and a Pester test keeps it under the 96 KB `loadTextContent()` limit. Each chunk script is about 700 KB at the default 512 KiB of data (Base64 with line breaks, plus the writer), below the 1 MB limit for a resource definition, and the request body below the 4,194,304-byte request limit; 512 KiB chunks worked live on 2026-10-20.

## Phase 16 addendum: the deployment-stack live trial (2026-10-21)

This supersedes the Phase 5 addendum's next step ("if the trial shows clean create, update, and delete under Contributor, a superseding note switches to them").

**The trial.** `tests/teardown/Invoke-DeploymentStackTrial.ps1` creates, updates, and deletes two small stacks of free user-assigned identities in a disposable resource group (`rg-<prefix>-stacktest`), records each step as a `TEARDOWN.STACK.*` result, and removes everything it made. Results are in [cleanup](../cleanup.md#deployment-stack-trial-rg-dbhub-stacktest-2026-10-21).

- **Create, update, and delete worked, twice:** a resource-group-scope stack was created in 57 s (53 s in the second run); an update with `actionOnUnmanage` `deleteResources` (147 s; 144 s) deleted the identity dropped from the template and left an identity created outside the stack alone, which is how the Arc resources that onboarding creates would be treated; `az stack group delete --action-on-unmanage deleteAll` (136 s; 128 s) deleted the managed identity and kept the group; a subscription-scope stack that owns its resource group, the shape `main.bicep` would take, was created in 78 s (53 s). The first run's client stopped after that create; the second run (20:59–21:15 UTC, after the subscription guard update) recorded the delete: `az stack sub delete --action-on-unmanage deleteAll` succeeded in 370 s with an identity created outside the stack in its resource group, the group was gone with everything in it 4 s later, and the cleanup check found no trial stack, resource group, or deny assignment.
- **Contributor:** the role allows every `Microsoft.Resources/deploymentStacks` action except `manageDenySetting/action`, which is one of its `notActions`, so deny settings other than `none` need Owner or Azure Deployment Stack Owner. The trial ran as the signed-in user, whose `denyDelete` applied in 58 s and blocked a direct delete. Learn notes that enforcement of `manageDenySetting` is still rolling out across regions, so a Contributor-only run must not rely on deny settings either way.
- **Learn's known issues (checked 2026-10-21):** what-if isn't available for stacks; a stack doesn't manage implicitly created resources; and the portal can't create a stack.

**Decision: plain subscription deployments stay for v1.** The trial met the functional bar, but under Contributor a stack adds nothing the demo lacks, and it takes away what-if:

1. Drift protection comes from deny settings, which a Contributor-only caller can't manage.
2. Optional resources that a configuration change turns off are already deleted explicitly by `deploy.ps1` ([ADR 0017](0017-outbound-access.md)), and `destroy.ps1` deletes the whole resource group, including what onboarding creates outside any template; a stack's `deleteAll` would delete the same group, no better.
3. `deploy.ps1 -WhatIf` and preflight's policy check (`PREFLIGHT.POLICY.WHATIF`) rely on what-if, which stacks don't support yet, and the Deploy to Azure button can't create a stack.

Revisit when what-if supports stacks, or if the demo moves to a role that can manage deny settings; the trial runs again in about 15 minutes and costs nothing.

## Sources (checked 2026-10-19)

- Bicep file functions and size limits: <https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-files>
- ARM template limits (4 MB): <https://learn.microsoft.com/azure/azure-resource-manager/templates/best-practices>
- Subscription-scope deployments: <https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription>
- Deployment stacks: <https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks>
- Deploy to Azure button: <https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-to-azure-button>
- Bicep linter: <https://learn.microsoft.com/azure/azure-resource-manager/bicep/linter>
- PSRule for Azure: <https://azure.github.io/PSRule.Rules.Azure/>
- Azure Verified Modules: <https://azure.github.io/Azure-Verified-Modules/>
- What-if: <https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-what-if>
- Defender for Storage, priced per storage account (checked 2026-10-20): <https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction>
- Managed Run Command (checked 2026-10-20): <https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed>
- Run Command overview, at most 25 managed Run Commands per VM (checked 2026-10-20): <https://learn.microsoft.com/azure/virtual-machines/run-command-overview>
- Azure Resource Manager limits, request size (checked 2026-10-20): <https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits>
- Deployment stacks known issues, including what-if (checked 2026-10-21): <https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks-known-issues>
- `az stack sub` and `az stack group` (checked 2026-10-21): <https://learn.microsoft.com/cli/azure/stack/sub>, <https://learn.microsoft.com/cli/azure/stack/group>
- Contributor's `notActions` (checked 2026-10-21): <https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/general#contributor>
