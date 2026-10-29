# ADR 0011: One orchestrator and the demo control surface

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2)
- **Decision source:** Engineering (approved plan §4.8, §9.2, §9.4 C3, C4, C8, §9.5, §9.6)
- **Related:** [ADR 0001](0001-iac-bicep-avm-compiled-arm.md), [ADR 0002](0002-resource-group-topology.md), [ADR 0010](0010-workload-generator-technology.md), [ADR 0014](0014-notebook-role-and-capacity.md), [deployment](../deployment.md)

## Context

- The user asked for a one-click deployment that gets everything running and configured (plan §9.2).
- The brief's control-surface priority is GitHub Actions `workflow_dispatch`, then the Fabric notebook, then the PowerShell CLI, then an optional local web UI, used only if it adds clear value at negligible cost.
- The GitHub path needs a one-time administrator action (P7). The local path needs only Contributor.
- **Fabric notebooks** can't reach the private servers and can't get an Azure Resource Manager token. `notebookutils` supports only the `storage`, `pbi`, `keyvault`, and `kusto` audiences.
- **ARM templates** can't carry the caller's token for Arc onboarding. The SQL VM monitoring feature flag is documented only as an Azure CLI merge.
- **Stopping T2:** stopping the host has to shut the guest down cleanly first.

## Decision drivers

1. Exactly one implementation of each operation, used by every surface.
2. Works with Contributor alone; the GitHub path adds one-click and schedules.
3. Re-runs converge and can resume.

## Decision

### One orchestrator, two triggers

- `scripts/deploy.ps1` (Cloud Shell or local PowerShell 7) and `.github/workflows/deploy.yml` run **the same stages**.
- Both call the same module, `scripts/modules/DbHubDemo`. The workflow is a thin wrapper.
- **`-Resume`** continues from the stage after the last good one, which is recorded in the resource-group tag `dbhubDeployStage` (ADR 0002). Every stage is idempotent.

| Stage | What it does |
|---|---|
| 1 Preflight | P1–P6, region, sizes and quota, a read-only Azure Policy inventory that resolves `networkMode` `auto`, policy what-if, cost estimate (with Defender for Cloud) checked against the ceilings |
| 2 Infrastructure | Subscription-scope Bicep: resource group, tags, budget, network, VMs, Azure SQL, schedules |
| 3 Artifacts | Deliver the script bundle in SHA-256-checked Run Command chunks and the runner as ADR 0010 decides; media downloads directly from Microsoft with SHA-256 checks (revised 2026-10-20: the artifact cache was dropped; Phase 6) |
| 4 Bootstraps (parallel) | T1: SQL Server, seed, runner, P6 membership, then T3 configuration from T1. T2: the host state machine. |
| 5 Post-configuration | T1 monitoring feature-flag merge; Arc onboarding with the caller's token (ADR 0005); Arc SQL verification; start the activity profile (`baseline` by default) |
| 6 Validation | Wait up to 15 minutes for telemetry from every target; print statuses, Hub deep links, and remaining manual items |
| 7 Fabric | Import or update both notebooks (local path by default; in Actions only when the service-principal tenant setting and a workspace role allow it) |

- **`PaygWizard` mode:** the orchestrator finishes everything it can, prints **Manual action required** with the wizard steps and a Bastion link, and keeps polling for up to `-WaitForManualMinutes` (default 60). If the wait ends first, `deploy.ps1 -Resume` continues from the same point. The guest's state machine resumes on its own either way.
- **Deploy to Azure button:** secondary. It runs stage 2 and starts the bootstrap loaders, then points to `deploy.ps1 -Resume` (ADR 0001).

### Day-to-day control

**Priority 1: GitHub Actions** (when P7 is in place). Every workflow uses a per-environment concurrency group, so a deploy and a destroy never overlap.

| Workflow | Purpose |
|---|---|
| `demo-control.yml` | `workflow_dispatch` with inputs: environment, target, scenario or profile, duration, concurrency, intensity, reset-before, auto-cleanup |
| `schedule-start.yml` | Starts about 45 minutes before a scheduled demo: start the VMs, resume T3, run `baseline` for at least 30 minutes, validate telemetry (C3, warm-up) |
| `schedule-stop.yml` | Stops after the demo window. DevTest Labs auto-shutdown is the backstop. |
| `bastion-cleanup.yml` | Hourly: removes Bastion when it has existed longer than `bastionMaxHours` (C8) |
| `expiry.yml` | Daily: parks T2 or destroys the environment when `expiresOn` has passed (C4) |
| `destroy.yml` | Runs in the `<env>-destructive` environment with required reviewers where the plan supports them; otherwise needs a typed confirmation input |

**Priority 2: Fabric notebooks** (ADR 0014).

- `NB_DatabaseHub_Deployment` is the deployment companion, validator, and presenter script.
- `NB_DatabaseHub_LiveActivity` switches activity profiles through `workflow_dispatch` with the P9 token. Without P9, it prints the Actions link and the CLI command.

**Priority 3: PowerShell CLI.**

- `start-demo.ps1`, `stop-demo.ps1`, `reset-demo.ps1`, `status.ps1`, `validate.ps1`, `estimate-cost.ps1`, and `destroy.ps1`.
- They run the same module functions that the workflows call.

**No local web UI.** It adds no clear value over Actions plus the notebooks.

### Subscription guard

> **Superseded in part on 2026-10-21** (coordinator decision for the owner, after another session's workflow switched this machine's shared Azure CLI default subscription to one in another tenant and the guard then stopped every script): the third bullet below no longer applies. The guard no longer reads or needs the default subscription, and nobody needs to change it; see [Guard update (2026-10-21)](#guard-update-2026-10-21).

- Every script and workflow reads the target subscription and tenant from configuration: `config/demo.config.json`, which Git ignores, or the GitHub environment's secrets (environment variables until [ADR 0022](0022-public-repository-and-github-actions-hardening.md), 2026-10-27).
- Every Azure CLI call passes `--subscription <id>` explicitly. Nothing relies on the CLI's default subscription.
- ~~Before any Azure call, the shared module checks that `az account show` returns the configured subscription **and** tenant, and that `az account get-access-token --tenant <tenant>` succeeds without interaction. If either check fails, the script stops with **Fail** and the exact sign-in instructions.~~ Superseded on 2026-10-21; see below.
- Scripts never start an interactive sign-in.

### Guard update (2026-10-21)

**Rule.** The Azure CLI's default subscription belongs to the whole profile, so anything else that uses the profile can change it, to another tenant included. The tooling is therefore independent of it:

1. **No context changes.** No script, workflow, or module function runs `az account set` (or `az login`, `az logout`, `az account clear`, `az config set`, `az cloud set`); `Invoke-DemoAz` refuses them. Users don't need to change their default subscription.
2. **The guard, before any write** (`Assert-DemoAzContext`, check `PREFLIGHT.GUARD.CONTEXT`, the same ADR 0012 result shape):
   - **Account:** `az account show --subscription <id>`, the profile entry the CLI uses for that subscription, must return the configured subscription and tenant. When the configuration sets `azureAccount` (a user principal name, or the client ID of a service principal or managed identity), the entry's account must match it, or the guard fails; without it, the guard reports the signed-in account with a **Warning**.
   - **Read-only canaries**, each explicitly targeted and time-limited: an Azure Resource Manager read through a CLI command (`az group list --subscription <id>`); `az rest --subscription <id> --method get` on `https://management.azure.com/subscriptions/<id>`, whose `tenantId` must match; and tokens for Azure Resource Manager, Microsoft Fabric, the Hub telemetry endpoint's Kusto audience, and Microsoft Graph, each decoded locally (never logged) so its `tid` claim is the configured tenant and its `oid` claim the same caller. For a user, Microsoft Graph's `/organization` read must answer for the configured tenant.
   - **Fail closed:** any failed check throws with the check's name and nothing is written. The validated context is cached for the process, and `Invoke-DemoAz` refuses writes and token requests until it exists.
3. **Enforced in `Invoke-DemoAz`**, with unit tests: `--subscription <id>` on every command that accepts it, `az rest` and token requests included; no other subscription anywhere in the arguments; no `--ids`; `az rest` only on fully qualified `https://management.azure.com/subscriptions/<id>` URLs, never the `{subscriptionId}` placeholder; no `az ad`; role assignments only with `--assignee-object-id` and `--assignee-principal-type`, and lists only with `--fill-principal-name false`.
4. **Optional isolation**, a user action on a machine whose Azure CLI profile is shared: a separate `AZURE_CONFIG_DIR` and one `az login --tenant <tenantId>` in it ([prerequisites](../prerequisites.md#optional-a-separate-azure-cli-profile)). It doesn't apply to Cloud Shell.

**Two differences from the coordinator's wording, both from the Azure CLI's behavior** (azure-cli 2.91.0 source, confirmed live and read-only on 2026-10-21 while the default subscription was in another tenant and belonged to another user):

- **Tokens use `--subscription`, not `--tenant`.** `az account get-access-token --tenant <t>` takes the identity from the *default* account, so with a shared profile it asks for the wrong user; live, a `--tenant` request for this demo's tenant hung under the Web Account Manager until it was stopped after 60 seconds. `--subscription <id>` selects the configured subscription's account and tenant, and returned tokens with the right `tid` and caller in 3 to 9 seconds for every audience the scripts use. The CLI rejects the two options together ("Please specify only one of subscription and tenant, not both"). This is also the managed identity and Cloud Shell path Learn describes, where `--tenant` isn't available. Every token's `tid` and `oid` claims are checked.
- **Microsoft Graph doesn't go through `az rest`.** `az rest` takes its token's account from the subscription in an Azure Resource Manager URL and from the default account for every other URL, whatever `--subscription` says: live, `az rest --subscription <id>` on Graph's `/v1.0/organization` answered for the default account's tenant, and a Resource Graph query (an ARM URL without a subscription) was refused with `AccessDenied`. Graph calls (the P6 group checks and T1's membership), Resource Graph, and tenant-level policy definition reads go through `Invoke-DemoRestRequest`, which sends a token from the guard's verified path in the `Authorization` header only.

**Auth paths and how each is targeted:**

| Path | Used by | Targeting |
|---|---|---|
| Azure CLI management and data-plane commands (`az vm`, `az sql`, `az deployment`, `az keyvault secret`, and so on) | Every script | `--subscription <id>`; the CLI takes the account and tenant from that subscription |
| `az rest` on Resource Manager | Run Commands, Arc reads, permissions, budgets, cost, policy assignments | Fully qualified `https://management.azure.com/subscriptions/<id>/...` plus `--subscription <id>` |
| Resource Manager token | Arc onboarding (`Get-DemoArmAccessToken`) | `Get-DemoAccessToken`: `--subscription <id>`, `tid` and `oid` checked |
| Fabric token | `Get-DemoFabricToken` | Same |
| Kusto token | Hub telemetry (`Get-DemoHubToken`) | Same |
| Microsoft Graph | P6 checks, T1's group membership, principal types for role assignments | `Invoke-DemoRestRequest` with a verified Graph token |
| Resource Graph and tenant-level ARM reads | Estate and T3 readiness, built-in and management group policy definitions | `Invoke-DemoRestRequest` with a verified Resource Manager token |
| Role assignments | Presenters, the Key Vault opt-in, GitHub OIDC | `--assignee-object-id` with `--assignee-principal-type`; the caller's object ID comes from the verified token |
| GitHub Actions | Every workflow | `azure/login` with OpenID Connect; `demo-setup` sets `azureAccount` to `AZURE_CLIENT_ID` |

Azure SQL, Storage, and Key Vault tokens aren't requested by the scripts: T1 reaches T3 with its managed identity, there's no storage account, and `az keyvault secret` takes its token from `--subscription`.

### Lifecycle rules

- **T2 stop:** a Run Command on the host shuts the guest down (`Stop-VM`) and waits for it, and only then is the host deallocated.
- **T3:** stopping it means letting it auto-pause. The runner closes its sessions.
- **Activity profiles** stop at their maximum duration or at the next auto-shutdown, whichever comes first.

## Phase 13 implementation notes (2026-10-21)

As built, with the differences from the decision above:

- **Stages:** `Invoke-DemoDeployment` runs ten stages: Preflight, Infrastructure, Artifacts, Bootstraps, T3, Activity, Monitoring, T2, Fabric, and Validation. T1 and T3 are configured before T2 so they're ready while the guest builds, and the Fabric stage runs `configure-fabric.ps1`, the one implementation of the Hub checklist and the notebook import. The order inside the stages is the one that worked live: the template, the bundle to each VM, the template again with the hashes, the loaders, T1 in the P6 group, then the T3 setup from T1.
- **State:** the resource group's `DbHub*` tags (`DbHubDeployStage` and the bundle, runner, network-mode, free-offer, and P6-group values), written with `az tag update --operation Merge`. The template keeps them on every redeployment. The recorded stage never moves past an open stage, so `-Resume` can't skip a manual step.
- **`PaygWizard`:** no polling for the manual step. The T2 stage waits up to `-T2WaitMinutes` for the host to reach Arc onboarding, reports **Manual action required** with the steps, stays open, and lets the later stages run; `DEPLOY.SUMMARY` lists every manual item. `deploy.ps1 -Resume` continues after the step. *(Phase 28, 2026-10-29: the parallel `deploy.ps1` now guides the step in the same run and polls the host until it's done, within a time limit; the sequential path keeps this behavior. See [ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md#amendments-2026-10-29-phase-28-one-command-one-guided-stop).)*
- **Workflows:** every demo workflow calls `reusable-demo-run.yml`, which runs one allowlisted script (`deploy`, `start-demo`, `stop-demo`, `status`, `reset-demo`, `destroy`, `demo-control`, `validate`) with parameters splatted from JSON, in the job's GitHub environment, under the concurrency group `dbhub-demo-<environment>` without cancellation. The composite action `demo-setup` signs in with `azure/login` v3 and OpenID Connect (a user-assigned identity in `rg-<prefix>-control` with one federated credential per environment, `setup-github-oidc.ps1`), installs the pinned Bicep and .NET SDK when asked, and writes the configuration from `DBHUB_CONFIG_JSON`.
- **`demo-control.yml`:** the inputs are the [ADR 0014](0014-notebook-role-and-capacity.md) contract, all strings; `demo-control.ps1` validates them and calls `Invoke-DemoControl`. An incident on `all` runs on the scenario's default target.
- **Added:** `warm-up.yml` (start with a warm-up, by hand), and a `live` input on `validate.yml` that runs `validate.ps1 -ConfigPath config/demo.config.json -OutputPath out/validate.jsonl` and uploads the JSON lines. The schedules (`schedule-start.yml`, `schedule-stop.yml`, `expiry.yml`, `bastion-cleanup.yml`) are off until the repository variable `DBHUB_SCHEDULES_ENABLED` is `true`.
- **Changed:** `expiry.yml` destroys an expired environment (`destroy.ps1 -IfExpired`) rather than parking T2; `stop-demo.ps1 -ParkT2` parks it by hand. `destroy.yml` needs the environment's name typed again; required reviewers on a `<env>-destructive` environment remain an option for plans that support them.
- **Lifecycle:** `stop-demo.ps1` sets every activity profile to `off` before the VMs stop, and the VMs set a profile at boot only when `activityProfileOnBoot` is true ([ADR 0016](0016-cost-profiles.md)). On-demand Bastion is a template deployment (`infra/modules/bastion.bicep`), because `az network bastion` needs a CLI extension that prompts to install.

## Consequences

- **Positive:** one code path to test. The local path needs no administrator. Schedules keep compute running only around demos.
- **Negative:** the schedules, notebook triggering, and one-click Actions depend on the optional P7 and P9.

## Validation

- **Phase 4 (static):** actionlint and workflow schema checks; Pester tests for stage ordering and `-Resume`.
- **Phase 13 (live, pending go-ahead):**
  - `deploy.ps1` from a clean subscription reaches **Pass** or **Manual action required** only.
  - `-Resume` after an interrupted run converges.
  - `deploy.yml` produces the same result.
  - The schedules start and stop on time.

## Sources (checked 2026-10-19)

- `workflow_dispatch` and `schedule` events: <https://docs.github.com/actions/using-workflows/events-that-trigger-workflows>
- Reusable workflows: <https://docs.github.com/actions/using-workflows/reusing-workflows>
- Concurrency: <https://docs.github.com/actions/using-jobs/using-concurrency>
- Deployment environments: <https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment>
- `notebookutils` credentials: <https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials>
- SQL VM performance monitoring (CLI feature flag): <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm>
- DevTest Labs auto-shutdown schedules: <https://learn.microsoft.com/azure/templates/microsoft.devtestlab/schedules>

Guard update (checked 2026-10-21):

- `az account show` and `az account get-access-token` (`--subscription`, and `--tenant` "only available for user and service principal account, not for managed identity or Cloud Shell account"): <https://learn.microsoft.com/cli/azure/account>
- `az rest` (the `{subscriptionId}` token): <https://learn.microsoft.com/cli/azure/reference-index#az-rest>
- `az role assignment create` (`--assignee-principal-type`): <https://learn.microsoft.com/cli/azure/role/assignment#az-role-assignment-create>
- Subscriptions - Get: <https://learn.microsoft.com/rest/api/resources/subscriptions/get>
- Microsoft Graph: [Get organization](https://learn.microsoft.com/graph/api/organization-get), [Get group](https://learn.microsoft.com/graph/api/group-get), [List group owners](https://learn.microsoft.com/graph/api/group-list-owners), [checkMemberGroups](https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups), [Add members](https://learn.microsoft.com/graph/api/group-post-members), [getByIds](https://learn.microsoft.com/graph/api/directoryobject-getbyids)
- `AZURE_CONFIG_DIR`: <https://learn.microsoft.com/cli/azure/azure-cli-configuration> and <https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-tips#concurrent-execution>
- Web Account Manager as the default sign-in broker on Windows (Azure CLI 2.61.0 and later): <https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively>
- Azure CLI 2.91.0 source, `get_raw_token` (the default account for `--tenant`, and the rejection of both options) and `send_raw_request` (the token for `az rest`): <https://github.com/Azure/azure-cli/blob/azure-cli-2.91.0/src/azure-cli-core/azure/cli/core/_profile.py> and <https://github.com/Azure/azure-cli/blob/azure-cli-2.91.0/src/azure-cli-core/azure/cli/core/util.py>
