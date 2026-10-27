# Prerequisites

The demo needs **Contributor on an existing Azure subscription** and nothing more for the core deployment. Everything else is listed below. `scripts/preflight.ps1` checks each item and reports **Pass**, **Fail**, **Warning**, **Manual action required**, or **Not selected**.

## Checklist

1. **Azure:** Contributor on the subscription (P1), and quota for about 8 vCPUs of a nested-virtualization-capable size in the region, West US 3 by default (P3). Preflight registers the resource providers itself (P2).
2. **Fabric:** Database Hub enabled in the tenant, a Fabric Free license for each Hub user (P4), and a running F or Trial capacity with either a workspace you can use or the right to create one: the scripts find the workspace and its lakehouse by name, and create them when they're missing (P5, [configuration](configuration.md#fabric)).
3. **Microsoft Entra:** a security group you own, for the Azure SQL admin (P6). `./scripts/init.ps1 -CreateAdminGroup` creates it with you as its owner where your tenant allows it.
4. **Tools:** PowerShell 7.4, the Azure CLI with Bicep, and the pinned .NET SDK; or the repository's dev container (locally or in GitHub Codespaces), or Azure Cloud Shell ([tools](#tools)).
5. **Sign-in:** sign in to the demo's tenant yourself with `az login` (`--use-device-code` in a codespace or a container), unless you already are, and press Enter at the subscription selector for no changes. You don't need to change your Azure CLI default subscription; the scripts never sign in and never change it ([the subscription guard](#target-subscription-configuration-the-subscription-guard)). Then `./scripts/init.ps1` writes your configuration from that sign-in.
6. **Optional:** GitHub Actions (P7), presenter access (P8), the notebook's dispatch token (P9), a SQL Server product key for a fully unattended T2 (P10), for the Insights app, two tenant settings and a one-time Rayfin CLI sign-in (P12 to P14), and for the on-demand activity control, an Owner once (P15).

## Required

| # | Prerequisite | Who provides it | How to satisfy it |
|---|---|---|---|
| P1 | Contributor on the target subscription | Subscription Owner | Owner assigns Contributor to the deploying user |
| P2 | Registered resource providers: `Microsoft.Sql`, `Microsoft.SqlVirtualMachine`, `Microsoft.AzureArcData`, `Microsoft.HybridCompute`, `Microsoft.GuestConfiguration`, `Microsoft.HybridConnectivity`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Consumption`, `Microsoft.DevTestLab`, and `Microsoft.DBforPostgreSQL` for T4 (unless `t4Enabled` is false) | Preflight, automatically | `preflight.ps1` registers any that are missing (Contributor can) |
| P3 | Quota in the region: at least 8 vCPUs across the chosen VM families, plus one Standard public IP for on-demand Bastion | Subscription | Request a quota increase if preflight reports Fail; preflight suggests other sizes or regions |
| P4 | Database Hub tenant setting ("Users can access the Database hub (preview)") enabled; a Fabric Free license for each Hub user | Fabric administrator | Fabric admin portal → Tenant settings. `configure-fabric.ps1` reads it through the Fabric admin API only with `-FabricAdmin`; otherwise it reports **Manual action required** with these steps |
| P5 | A Fabric workspace for the demo's items, found by name (`fabric.workspaceName`), with its lakehouse (`fabric.lakehouseName`), on F or Trial capacity. **Either** Contributor or higher on a workspace that exists, **or** the right to create one: the Fabric tenant setting "Create workspaces" enabled for you, and a contributor or administrator role on the capacity named in `fabric.capacityName` ([ADR 0021](adr/0021-fabric-resources-by-name.md)) | You, or a workspace or capacity administrator | With `fabric.createIfMissing` (the default), `deploy.ps1` and `configure-fabric.ps1` create the workspace on that capacity and the lakehouse with lakehouse schemas, so there's no ID to look up. Otherwise a workspace administrator creates it and adds you (Workspace > Manage access). A paid F capacity must be **running** for creating, imports, and runs; it bills by the hour while it runs, outside the demo's cost ceiling, and its administrator resumes and pauses it; the scripts never do, unless `fabric.manageCapacity` is true for a capacity that's yours alone ([cost management](cost-management.md#microsoft-fabric-capacity)) |
| P6 | An Entra security group **owned by the deploying user**, used as the Azure SQL Entra admin. The deployment adds T1's managed identity to it. | The user (if group creation is allowed) or an Entra administrator | `./scripts/init.ps1 -CreateAdminGroup` finds the group by name or creates it with you as its owner, through Microsoft Graph, and writes its object ID as `t3AdminGroupObjectId`. Where only administrators may create groups, it prints their steps (**Manual action required**). Without P6, the deploying user becomes the T3 admin and runs the T-SQL step interactively. |

**P6 in practice (Phase 8):**

- The deployment adds T1's managed identity with `az ad group member add`, using the caller's rights as a group owner, before T1 first connects to T3. In GitHub Actions the GitHub identity must also own the group; otherwise the step reports **Manual action required** with the exact command for an owner.
- A new membership can take a while to apply to a managed identity. T1's first login to T3 is retried for up to 10 minutes; if it still fails, the step reports a **Warning** with the measured wait, and running it again later finishes the job ([ADR 0008](adr/0008-identity-rbac-abac.md#phase-8-addendum-t1-and-the-p6-group-as-built-2026-10-20)).
- The group's display name is recorded as T3's administrator login; T3 identifies the administrator by `t3AdminGroupObjectId`.
- **T4 (Phase 24):** the same group is T4's Microsoft Entra administrator, and its display name is the PostgreSQL role T1 signs in as to set T4 up, so keep it to 63 characters or fewer (PostgreSQL's limit for a role name). Nothing else is needed for T4: the runner's own role is created by T1's identity, and no role assignment is made ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)).

## Optional

| # | Prerequisite | Who provides it | Unlocks |
|---|---|---|---|
| P7 | GitHub one-click: `scripts/setup-github-oidc.ps1` creates the identity and federated credentials (Contributor can); with `-ConfigureGitHub`, it also creates the GitHub environment (you as required reviewer, the default branch only) and its secrets, as an administrator of the repository. An Owner, User Access Administrator, or Role Based Access Control Administrator then assigns **Contributor on the subscription** to the identity; the script prints the exact command. Once the repository is public, `scripts/setup-github-repo.ps1` applies its settings ([ADR 0022](adr/0022-public-repository-and-github-actions-hardening.md)). | One-time administrator action | `deploy.yml`, `demo-control.yml`, `destroy.yml`, and the scheduled workflows |
| P8 | Reader on the subscription for presenters or attendees who aren't Contributors, plus the Arc telemetry role on the demo resource group for T2 performance data | Owner, User Access Administrator, or Role Based Access Control Administrator | Hub visibility for those users; `configure-fabric.ps1` prints the commands, or assigns the roles when `assignRoles` is true |
| P9 | A GitHub fine-grained token (`actions: write` on this repo only) in a Key Vault secret that the notebook user can read | The user | Triggering activity profiles from the live-activity notebook |
| P10 | A SQL Server Standard product key | The customer's licensing | `t2SqlInstallMode = ProductKey` (fully unattended T2 with Hub Performance). Type it at `configure-arc.ps1 -ProductKey`, or store it as the Actions secret `DBHUB_SQL_PRODUCT_KEY` |
| P11 | Viewers of Power BI content on capacities smaller than F64 need Pro, PPU, or a trial; presenters sharing their screen are fine | Each viewer's license administrator, or a capacity administrator for a larger capacity | Viewers who open the history report themselves (Phase 19); plan the same for the Fabric app (Phase 19b), which reads the model as the viewer (TODO(verify)). The demo workspace's capacity is an F16 (2026-10-21). Database Hub and the Real-Time Dashboard aren't Power BI content, so a Fabric Free license is enough for them ([presentation](presentation.md#licensing-and-permissions)) |
| P12 | The Fabric tenant setting **Fabric Apps (preview)** enabled for the deploying user and every viewer of the Insights app ([Fabric Apps overview](https://learn.microsoft.com/fabric/apps/overview)) | Fabric administrator | The Insights app `APP_DatabaseHub_Insights` (Phase 19b): creating, updating, and opening the app item |
| P13 | The Fabric tenant setting **Dataset Execute Queries REST API** (Integration settings; newer portals say "Semantic Model") enabled ([Execute Queries](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group)) | Fabric administrator | The Insights app's connector, which runs DAX through that API as the signed-in user, and Phase 19's model data check |
| P14 | A one-time sign-in of the Rayfin CLI as the demo's Fabric user, on the machine that deploys: `./scripts/configure-fabric-app.ps1 -SignIn` runs it in your console when it's missing, or run `npx --yes --package=@microsoft/rayfin-cli@<version> -- rayfin login --tenant <tenantId>` yourself (the version is in `config/versions.json`, `fabricApp.cliVersion`); and Node.js 20, 22, or 24 | The operator | Unattended deploys of the Insights app with `configure-fabric-app.ps1`. The CLI's service principal sign-in is listed but not supported yet ([CLI reference](https://learn.microsoft.com/fabric/apps/cli-reference)), so there's no CI deploy, and `-SignIn` is **Not supported** in CI |
| P15 | The on-demand activity control ([ADR 0020](adr/0020-on-demand-activity-control.md)): `control.enabled` true, then `scripts/setup-activity-control.ps1` (Contributor; it registers `Microsoft.Automation` when needed), then an Owner, signed in with multifactor authentication, runs `setup-activity-control.ps1 -GrantRole` once, and again for A1 after each redeploy unless `assignRoles` is true. The Fabric capacity must be running when setup imports the notebook. Where a policy makes new vaults private, setup also creates the "DBHub Control" workspace on the same capacity, which needs the Fabric tenant setting that lets users create workspaces and a role on the capacity | You, then a subscription Owner | Starting a bounded, self-stopping run from the notebook `NB_DatabaseHub_Control`, with a live view. Without P15, `demo-control.ps1` does the same from your machine with Contributor |

**P11 in practice (Phase 18):** "On F SKUs smaller than F64, each user viewing Power BI content must have Pro, PPU, or an individual trial; on F64 or larger, users with only a Free license and a viewer role can view" ([Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses)). `preflight.ps1` and `configure-fabric.ps1` report `PREFLIGHT.FABRIC.VIEWERLICENSE`: **Pass** on F64 or larger and on P capacities, and a **Warning** with this rule below F64, on A or EM capacities, for a SKU it doesn't recognize, and when the SKU can't be read. It never fails, because P11 is optional, and it never changes the capacity, which runs at the owner's choice.

## How `configure-fabric.ps1` checks P4, P5, P8, and P11

The script runs only after the subscription guard passes, and uses documented interfaces only: Database Hub has no public API ([ADR 0012](adr/0012-validation-model.md#phase-9-database-hub-checks-2026-10-20)).

| Item | Check | Without the rights |
|---|---|---|
| P4 | With `-FabricAdmin`: the Fabric admin API [Tenants - List Tenant Settings](https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings), matched by the setting's title | **Manual action required** with the portal steps. Learn doesn't document a check for Fabric Free licenses, so the steps mention them. |
| P5 | First the workspace and the lakehouse by name ([ADR 0021](adr/0021-fabric-resources-by-name.md)): [List Workspaces](https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces), [List Capacities](https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities), and [List Lakehouses](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/list-lakehouses), and when they're missing, [Create Workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace) on `fabric.capacityName` and [Create Lakehouse](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse) (`FABRIC.RESOLVE.*`). Then [Get Workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace), List Workspaces filtered to Admin, Member, and Contributor, and List Capacities, with your Fabric token: `-FabricToken`, or one from the signed-in Azure CLI | **Manual action required** with the steps: the tenant setting "Create workspaces" or the capacity role for creating, a capacity that isn't running, or no role on an existing workspace. A capacity you can't see is a **Warning**; a non-F SKU (for example a Trial) is **Manual action required** until a live run confirms its SKU name. `preflight.ps1` only reads: a workspace that doesn't exist yet is a **Warning** that names the capacity `deploy.ps1` would create it on |
| P8 | Only when `assignRoles` is true: your right to create role assignments, then each role resolved by name and assigned to the presenters in `presenterObjectIds` | **Manual action required** with one `az role assignment create` command per presenter and role ([permissions](permissions.md#presenter-access)) |
| P11 | The SKU of the workspace's capacity, from the same List Capacities call as P5 (`PREFLIGHT.FABRIC.VIEWERLICENSE`); `preflight.ps1` reads it with Get Workspace and List Capacities | A **Warning** that states the viewer licensing rule |

## How `configure-fabric-app.ps1` checks P5, P12, P13, and P14

The Insights app's deploy step (Phase 19b, [its guide](../fabric/app/README.md)) runs the same P5 check, then deploys only on an **Active** capacity, because `rayfin up` can start a trial or assign a capacity for a workspace without one.

| Item | Check | Without the rights |
|---|---|---|
| P12, P13 | With `-FabricAdmin`: [Tenants - List Tenant Settings](https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings), matched by title (`FABRIC.APP.TENANTSETTING`, `FABRIC.APP.EXECUTEQUERIES`) | **Manual action required** with the portal steps, which turns into a **Pass** in the same run when the step each setting gates passes: the deploy for P12, the connector check for P13 |
| P14 | `rayfin login status --json` from the stage's pinned CLI, which never opens a browser (`FABRIC.APP.SIGNIN`), and `node --version` (`FABRIC.APP.NODE`). With `-SignIn`, a missing sign-in is run in your console first, then checked again | **Manual action required** with the exact login command; nothing is deployed until it passes. A newer Node.js is a **Warning** |

## Tenant policies (checked by preflight)

Preflight reads the Azure Policy assignments that apply to the subscription, including those inherited from management groups, and reports every conflict in one run (`PREFLIGHT.POLICY.*`, [ADR 0012](adr/0012-validation-model.md)). It only reads; it never changes or exempts a policy.

- **Read access:** Contributor can read the subscription's policy assignments. Definitions stored at a management group may need read access there (for example Reader). Without it, preflight reports a Warning that names what it couldn't read, and `networkMode` `auto` resolves to private.
- **Adaptive defaults:** with `networkMode` `auto`, the default, a policy that turns off or denies public network access on SQL servers makes T3 private ([ADR 0007](adr/0007-networking-modes-and-egress.md)).
- **Defender for Cloud:** policies that turn on Defender plans add cost. Preflight reads the plans and the cost estimate includes them ([ADR 0016](adr/0016-cost-profiles.md)).
- **MFA:** where Azure enforces multifactor authentication for resource writes and deletes, sign in as a user with MFA. Workload identities, such as managed identities and service principals, including the GitHub OIDC identity (P7), aren't affected ([mandatory Microsoft Entra MFA](https://learn.microsoft.com/entra/identity/authentication/concept-mandatory-multifactor-authentication)).
- **Time:** reading large policy sets takes a few minutes. `preflight.ps1 -SkipPolicyInventory` skips it; `auto` then resolves to private.

## Tools

- **Azure Cloud Shell:** has everything below except, possibly, the pinned .NET SDK. Without it, run `deploy.ps1 -SkipRunner`, which deploys without the workload runner (the activity profiles are then **Not selected**), or install the SDK.
- **Local machine:**
  - PowerShell 7.4 or later.
  - Azure CLI with Bicep (the Bicep version pinned in `config/versions.json`).
  - The .NET SDK pinned in `config/versions.json` (10.0), which `deploy.ps1` uses to build the workload runner.
  - *(Optional, the Insights app)* Node.js 20, 22, or 24 with npm, for `configure-fabric-app.ps1` and `fabric/app` (P14).
  - Git, and a clone of the repository. While the repository is private, cloning it needs GitHub access (`gh auth login`, risk R30).
  - *(Optional, GitHub path)* GitHub CLI, signed in with `gh auth login`: `setup-github-oidc.ps1 -ConfigureGitHub` and `setup-github-repo.ps1` use it, and without `-ConfigureGitHub` you run the `gh secret set` commands that `setup-github-oidc.ps1` prints.
- **Devcontainer:** the repo's `.devcontainer` provides the full toolchain at the versions `config/versions.json` pins: PowerShell 7.4, the Azure CLI with Bicep, the .NET SDK, Node.js 24, the GitHub CLI, and the test tools. Open it in VS Code, or in GitHub Codespaces with the README's **Open in GitHub Codespaces** button (a 4-core machine, which `hostRequirements` asks for). There's no browser in the container, so sign in with `az login --use-device-code` ([device code sign-in](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)). A codespace is usually in UTC, so give `init.ps1` your time zone for the VMs' auto-shutdown (`-TimeZone 'Eastern Standard Time'`). The Rayfin CLI's browser sign-in may not complete in a codespace; deploy the Insights app from your own machine if it doesn't.

## Target subscription configuration (the subscription guard)

`./scripts/init.ps1` writes `config/demo.config.json` (Git ignores it) from your sign-in: `subscriptionId`, `tenantId`, `azureAccount`, and the rest ([deployment](deployment.md#first-run-initps1)). Its one Azure CLI call before the guard is `az account list`, a local, read-only read of the subscriptions your sign-in cached, because the guard needs a subscription to check; it never runs `az account set` ([ADR 0023](adr/0023-first-run-automation.md)). Or copy `config/demo.config.example.json` to `config/demo.config.json` and set `subscriptionId` and `tenantId` yourself. Set `azureAccount` to the account you sign in with (your user principal name), or remove it: then the guard reports the account it finds with a **Warning** instead of failing on a different one.

**You don't need to change your default subscription, and the scripts never do.** The Azure CLI's default subscription belongs to the whole CLI profile, and other tools or sessions on the same machine can change it at any time, to another tenant included. So every script:

- passes `--subscription <subscriptionId>` explicitly on every Azure CLI call, and refuses `az account set`, `az login`, and anything else that would change the CLI context;
- never starts an interactive sign-in. Sign in once yourself with `az login --tenant <tenantId>` as the account that runs the demo, and press Enter at the subscription selector for no changes ([sign in at a command line](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively));
- runs the subscription guard (`Assert-DemoAzContext`, check `PREFLIGHT.GUARD.CONTEXT`) before anything is written, and stops with **Fail**, naming the failed check, unless:
  - `az account show --subscription <subscriptionId>` returns that subscription in `tenantId`, as `azureAccount` when it's set;
  - read-only canaries reach the subscription through every authentication path the scripts use: an Azure Resource Manager read, `az rest` on the subscription's fully qualified URL, and tokens for Azure Resource Manager, Microsoft Fabric, Kusto (Hub telemetry), and Microsoft Graph, each checked locally for the right tenant and caller (tokens are never printed).

The guard runs once per script run; it takes about half a minute. Sources: [az account](https://learn.microsoft.com/cli/azure/account), [az rest](https://learn.microsoft.com/cli/azure/reference-index#az-rest), [ADR 0011](adr/0011-control-surface-priority.md#guard-update-2026-10-21).

### Optional: a separate Azure CLI profile

On a machine whose Azure CLI profile is shared with other work, you can give the demo its own profile. This is a user action, and the scripts work without it.

```powershell
$env:AZURE_CONFIG_DIR = "$HOME/.azure-dbhub-demo"   # this PowerShell session only
az login --tenant <tenantId>                         # once, as the account that runs the demo
./scripts/status.ps1                                 # every script in this session uses that profile
```

- The Azure CLI keeps its configuration and token cache in `AZURE_CONFIG_DIR` (by default `%USERPROFILE%\.azure` on Windows and `$HOME/.azure` on Linux and macOS), so nothing else on the machine sees or changes this profile. Set the variable again in each new session. Sources: [Azure CLI configuration](https://learn.microsoft.com/cli/azure/azure-cli-configuration), [Concurrent execution](https://learn.microsoft.com/cli/azure/use-azure-cli-successfully-tips#concurrent-execution).
- It doesn't apply to Azure Cloud Shell, which signs you in for you and has its own profile.
- GitHub Actions doesn't need it: every job signs in on a fresh runner with OpenID Connect, and the workflows set `azureAccount` to the identity's client ID (`AZURE_CLIENT_ID`).

## Region

The default region is **West US 3**. It's in Database Hub's performance-monitoring region list and the SQL VM unified-inventory list. Bastion Developer isn't offered there, so scripts create Bastion Basic only on demand. Any region you choose must be in both lists; preflight checks it.
