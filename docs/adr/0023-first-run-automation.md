# ADR 0023: First-run automation

- **Status:** Accepted
- **Date:** 2026-10-27
- **Decision source:** User-directed (2026-10-26: "automate as much as possible for other folks using the repo"; 2026-10-27: a colleague in another tenant tests the seamless first run), with the coordinator's decisions on the approved plan
- **Related:** [ADR 0008](0008-identity-rbac-abac.md), [ADR 0009](0009-secrets-handling.md), [ADR 0011](0011-control-surface-priority.md), [ADR 0012](0012-validation-model.md), [ADR 0014](0014-notebook-role-and-capacity.md), [deployment](../deployment.md#first-run-initps1), [prerequisites](../prerequisites.md)

## Context

- **A first run needed IDs typed by hand.** Before Phase 26, a new user copied the example configuration and looked up the subscription, tenant, account, P6 group, and Fabric IDs, created the group, ran the Rayfin CLI's sign-in command, and, every session, resumed and paused the capacity and ran the live-activity notebook by hand. Phase 26a removed the Fabric IDs (the workspace and lakehouse are found or created by name).
- **The rules stand:** no script signs in, signs out, or changes the Azure CLI context; every Azure CLI call goes through `Invoke-DemoAz` after the subscription guard; no app registrations, service principals, or client secrets; no Fabric tenant-setting changes; Contributor is the default path's maximum; documented interfaces only; ADR 0012 statuses.
- **The guard needs a subscription to check**, and a first run has no configuration yet.
- **`az ad` answers for the Azure CLI's default account**, which can be in another tenant, so `Invoke-DemoAz` refuses it; Microsoft Graph is called with a token the guard verified (`Invoke-DemoRestRequest`).
- **An administrator who creates a security group isn't made its owner automatically**; a member user who creates one is ([Create group](https://learn.microsoft.com/graph/api/group-post-groups)).
- **A Fabric capacity bills while it runs**, and is often shared. Fabric Capacities - Resume and Suspend are Azure Resource Manager operations on `Microsoft.Fabric/capacities`; a Trial capacity isn't an Azure resource.

## Decision drivers

1. A colleague in another tenant goes from a clone to a running demo with as few manual steps as the rules allow.
2. No rule above is weakened; any exception is narrow, read-only, documented, and tested.
3. Nothing the user doesn't own is changed: a shared capacity is never touched unless its owner opts in.

## Considered options

1. **`init.ps1` with one documented pre-guard read, and opt-ins for the rest (chosen).**
2. A fully interactive wizard that also signs in. Rejected: no script signs in.
3. Keep the manual configuration and document it better. Rejected: it's the slowest step, and it's where IDs go wrong.

## Decision

1. **`init.ps1` (`Initialize-DemoConfig`).**
   - **The one exception:** before the guard, the only Azure CLI call is `az account list --output json`, which reads the subscriptions the Azure CLI's own sign-in cached, locally and read-only (`Get-DemoAzProfileSubscription`). With more than one, it asks. It never runs `az account set`.
   - Then the guard, for the chosen subscription, its tenant, and its account. Everything after it goes through it: Microsoft Graph `/me` for the budget alerts' address and the owner tag (never `az ad signed-in-user show`), the P1 permissions read, Fabric List Capacities (F, Trial, and P only, since Premium Per User can't hold the workspace; it asks when there's more than one) and List Workspaces, and the P6 group.
   - A new workspace gets `fabric.importNotebooks` true. T2's mode is asked: `PaygWizard` (the default) or `Developer`.
   - It writes only a file Git ignores, validated against the schema; an existing one is replaced only with `-Force`, after a copy to `out/config-backup`. `fabric.manageCapacity` stays false unless `-ManageCapacity`. `-WhatIf` reads everything and writes nothing; the guard's context is still kept in memory, so the reads work. `-NonInteractive` never asks: an ambiguous choice is **Manual action required**.
2. **`init.ps1 -CreateAdminGroup` (opt-in).** A missing P6 group is created through Microsoft Graph with the guard's verified token: Create group with the caller in `owners@odata.bind`, then Add owners when the owners don't list the caller. These are the calls behind `az ad group create` and `az ad group owner add`, which aren't used because they answer for the default account. No other member is added. The default name is `<prefix>-<environment>-sql-admins`, at most 63 characters, because it's also T4's PostgreSQL role name. Where the tenant lets only administrators create groups: **Manual action required** with the steps and the `az ad` commands for an administrator.
3. **`configure-fabric-app.ps1 -SignIn` (opt-in).** When `rayfin login status --json` says the CLI isn't signed in to the demo's tenant, the stage's pinned CLI runs `rayfin login --tenant <tenantId>` attached to the console (`Connect-DemoRayfinCli`), then the status is read again. Only where a person can answer it: in CI or a non-interactive session, **Not supported**, and nothing deploys. The script never sees the token, and never adds `--encryption-fallback-enabled` (plain-text token storage).
4. **`fabric.manageCapacity` (opt-in, default false).** With false, which is the right setting for a shared capacity, no script calls the capacity. With true:
   - `start-demo.ps1` resumes the capacity in `fabric.capacityName` only when it's **Paused**, only when it's an F capacity in the configured subscription, and records `<resource group>/<name>` in the demo resource group's tag `DbHubFabricCapacityResumed` (with `DbHubFabricCapacityResumedUtc`) once Azure accepted the resume. An Active capacity isn't recorded.
   - `stop-demo.ps1` and `destroy.ps1` pause only the capacity that tag records, then clear the record; a record of a capacity that's already paused is stale and is cleared without a call. `destroy.ps1` pauses before the group, and the record, goes, or reports a **Warning**.
   - `status.ps1` shows the record and the state, read-only.
   - A Trial capacity or one in another subscription is **Not supported**.
   - **Why a resource group tag:** it works from any machine and from GitHub Actions, it goes away with the group, and Contributor can write it (`az tag update --operation Merge`, like the deployment state).
5. **`stop-demo.ps1 -SaveHistory`, or `fabric.saveHistoryOnStop` (opt-in).** `NB_DatabaseHub_LiveActivity` runs on demand after the VMs stop and before any capacity pause, at most 15 minutes, with `SAVE_RESULTS` true and `CONFIRM` and `STOP_ACTIVITY` false. A run still going after 15 minutes keeps the capacity running (**Warning**), so a pause never cancels it.
6. **The dev container** pins Node.js 24, PowerShell 7.4, the .NET SDK, and Bicep to `config/versions.json`, asks for a 4-core machine (`hostRequirements`), and opens in GitHub Codespaces; sign-in there is `az login --use-device-code`.

## Consequences

- **Positive:** the first run is `az login`, `./scripts/init.ps1 -CreateAdminGroup`, `./scripts/preflight.ps1`, and `./scripts/deploy.ps1`. The remaining manual steps are the ones the rules require: the sign-in, Contributor (P1), the Fabric tenant settings, the capacity itself, T2's setup wizard in `PaygWizard` mode, and the Rayfin CLI's browser sign-in, which `-SignIn` runs in one command.
- **The pre-guard read is an exception** to "the guard first". It's limited to a local read of the profile, and a unit test checks that nothing else runs before the guard.
- **`-CreateAdminGroup` creates a directory object outside the subscription.** `destroy.ps1` doesn't delete it; delete it in Microsoft Entra when you no longer need it.
- **`fabric.manageCapacity` can pause a capacity that someone started using after `start-demo.ps1` resumed it.** It's documented as only for a capacity that's yours alone, and it's off by default.
- **A codespace is usually in UTC**, so `init.ps1` says when the VMs' auto-shutdown time zone came out as UTC, and `-TimeZone` sets yours.

## Validation

- **Static (2026-10-27):** `tests/unit/DbHubDemo.FirstRun.Tests.ps1`, in the static validation.
- **Live, read-only (2026-10-27):** `init.ps1 -WhatIf -CreateAdminGroup` (50 s) and `init.ps1` into a temporary Git-ignored path (44 s) against the live subscription: every `INIT.*` check **Pass**, and the file passed `Get-DemoConfig`. They found two defects, fixed the same day: under `-WhatIf` the guard didn't keep its context, so the reads after it had no token; and List Capacities also returned a Premium Per User capacity (`PP3`). The Trial capacity's SKU read live as `FTL64`.
- **Pending, the coordinator's live check:** `init.ps1` with a new workspace name, then the Fabric track creates the workspace and lakehouse; `-CreateAdminGroup` only with `-WhatIf`. `fabric.manageCapacity` and `-SaveHistory` stay unproven live until a capacity that's the tester's alone is available: the owner's capacity is shared and is never touched.

## Sources

Checked 2026-10-27:

- [az account list](https://learn.microsoft.com/cli/azure/account#az-account-list) and [Sign in interactively, including with a device code](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)
- Microsoft Graph: [Get user (/me)](https://learn.microsoft.com/graph/api/user-get), [List groups](https://learn.microsoft.com/graph/api/group-list), [Create group](https://learn.microsoft.com/graph/api/group-post-groups), [Add owners](https://learn.microsoft.com/graph/api/group-post-owners), [List owners](https://learn.microsoft.com/graph/api/group-list-owners), and [self-service group management](https://learn.microsoft.com/entra/identity/users/groups-self-service-management)
- Fabric REST: [List Capacities](https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities), [List Workspaces](https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces), [Run On Demand Item Job](https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job)
- Azure Resource Manager, API version 2023-11-01: [Fabric Capacities - Resume](https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/resume), [Suspend](https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/suspend), [Get](https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/get), and [List By Subscription](https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/list-by-subscription); [pause and resume a capacity](https://learn.microsoft.com/fabric/enterprise/pause-resume)
- [Rayfin CLI reference](https://learn.microsoft.com/fabric/apps/cli-reference) (`rayfin login --tenant`, `rayfin login status`)
- [Start-Process -Environment](https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process) (PowerShell 7.4)
- Dev containers: [hostRequirements](https://containers.dev/implementors/json_reference/) and [GitHub Codespaces](https://docs.github.com/codespaces/setting-up-your-project-for-codespaces/adding-a-dev-container-configuration/introduction-to-dev-containers)
