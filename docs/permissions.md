# Permissions

> **Status: final (Phase 14, 2026-10-21)**, from [ADR 0008](adr/0008-identity-rbac-abac.md). `validate.ps1 -Area Security` checks the footprint on a live environment ([verify it](#verify-the-footprint)).

## The model in one paragraph

The deploying identity needs **Contributor on the subscription** and nothing more. The default deployment creates **no role assignments** (`assignRoles = false`) and **no Key Vault**. Anything that needs more than Contributor is optional, gated by `assignRoles` or done once by an administrator, and listed in [prerequisites](prerequisites.md) as P7–P11 and P15. The opt-in Key Vault (`keyVault.enabled`, Phase 13) is the only feature that adds data-plane roles; it requires `assignRoles = true`, and `Initialize-DemoKeyVault` checks the permission before it deploys a vault, so none is left that nobody can use. The optional on-demand activity control (`control.enabled`, Phase 25c) adds one custom role and three assignments, which only an Owner creates, with `setup-activity-control.ps1 -GrantRole` ([below](#the-on-demand-activity-control)).

## What Contributor covers

- Creating the resource group and every resource; registering resource providers.
- Managed Run Command, VMAccess password resets, and SQL IaaS extension updates.
- Arc onboarding with the caller's own token, and deleting stale Arc resources.
- Arc SQL property updates, the Azure SQL Entra admin, Azure budgets, and on-demand Bastion.
- Reading the Hub telemetry endpoint and seeing every target in Hub. Contributor includes Reader at subscription scope and `Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action`.
- Reading the Azure Policy assignments that apply to the subscription and the Defender for Cloud plans (preflight, read-only). Policy definitions stored at a management group may need read access there; preflight reports a Warning, not a Fail, when it can't read them.
- Everything `validate.ps1` reads: role assignments, deployment history and operations, Run Command instance views, Resource Graph, budgets, and auto-shutdown schedules.

## What Contributor can't do (and the demo doesn't need)

- Create role assignments. Needed only for the optional P7, P8, P15, and `assignRoles = true`.
- Create custom roles. Needed only for the on-demand activity control's one role (P15).
- Assign Key Vault data-plane roles. Needed only for the opt-in Key Vault (`keyVault.enabled`), which is why that option requires `assignRoles = true`.
- Change Entra directory roles. Needed only for the hardened T3 option.
- Change Fabric tenant settings. P4 is assumed to be in place.

## Role matrix

| Persona or identity | Scope | Role or rights | Granted by | Default path | Why |
|---|---|---|---|---|---|
| Deployment operator | Subscription | Contributor (P1) | An administrator, once | Required | Deploy, operate, validate, destroy |
| GitHub identity `id-<prefix>-github` | Subscription | Contributor (P7) | An administrator, once | Optional (GitHub path) | One-click and scheduled workflows |
| T1 managed identity | T3 | Member of the P6 group, so a T3 administrator | `deploy.ps1`, as the group's owner (Microsoft Graph) | Default (P6) | Configures T3 and drives its workload (over-privileged by design, risk R26) |
| T2 host managed identity | none | No role assignments | — | — | Not reachable from the guest (ADR 0004) |
| Arc onboarding | Demo resource group | The caller's token | — | Default | ADR 0005; no role assignment |
| `id-<prefix>-<env>-arc-onboard` | Demo resource group | **Azure Connected Machine Onboarding** | The template, with `assignRoles = true` | Off | Least-privilege onboarding with `configure-arc.ps1 -UseHostIdentity` (ADR 0005) |
| Presenter who is a Contributor | Subscription | Contributor | — | Nothing to add | Already has everything Database Hub needs |
| Presenter who isn't a Contributor | Subscription | Reader (P8) | An administrator, or `configure-fabric.ps1` with `assignRoles = true` | Printed commands only | Hub discovery and performance data need subscription Reader |
| Presenter who isn't a Contributor | Demo resource group | **Azure Hybrid Database Administrator - Read Only Service Role** (P8), resolved by name | An administrator, or `configure-fabric.ps1` with `assignRoles = true` | Printed commands only | T2 performance data needs `Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action`, which Reader doesn't include; any role with that action works |
| Presenter in Fabric | Fabric workspace | Contributor or higher (P5) | The workspace's administrator | Required for the notebooks | Import and run the notebooks (`FABRIC.P5.WORKSPACE`) |
| Deployer whose workspace doesn't exist yet (Phase 26a) | Fabric tenant; the capacity in `fabric.capacityName` | The tenant setting "Create workspaces" for you, and a contributor or administrator role on the capacity; you become the new workspace's Admin | A Fabric administrator (the setting); the capacity's administrator (the role) | Only when the scripts create the workspace ([ADR 0021](adr/0021-fabric-resources-by-name.md)) | Create the workspace on that capacity and its lakehouse (`FABRIC.RESOLVE.*`). Assigning a capacity to an existing workspace needs its Admin role too. The scripts never create, resume, pause, or scale a capacity |
| DBA | T3; T1 and the T2 guest | P6 group member; Windows administrator through Bastion | The group's owner | As needed | Investigation and remediation |
| Key Vault opt-in principals | The opt-in vault `kv-<prefix><environment>-<deploymentId>` only | **Key Vault Secrets Officer** for the signed-in caller and `keyVault.operatorObjectIds` (for example the GitHub identity, so the scheduled stop can disable the secret); **Key Vault Secrets User** for `keyVault.readerObjectIds`; roles resolved by name | `deploy.ps1` (`Initialize-DemoKeyVault`), which needs `Microsoft.Authorization/roleAssignments/write` on the resource group (Owner, User Access Administrator, or Role Based Access Control Administrator) | Off: only with `keyVault.enabled` and `assignRoles = true` | Store, disable, and read the one-time T2 host password for Bastion sign-in without a clipboard ([ADR 0008](adr/0008-identity-rbac-abac.md), [ADR 0009](adr/0009-secrets-handling.md)) |
| Fabric administrator | Tenant | Fabric administrator | The tenant | Once (P4) | Enables the Hub tenant setting |
| On-demand activity control: `id-<prefix>-automation` (Phase 25c) | The demo resource group (A1) and `aa-<prefix>-control` (A2) only | **DbHub Demo Activity Operator**, a custom role with 22 actions ([ADR 0020](adr/0020-on-demand-activity-control.md#the-role-dbhub-demo-activity-operator)) | An Owner, with `setup-activity-control.ps1 -GrantRole`; after a redeploy, `deploy.ps1` for A1 when `assignRoles` and `control.enabled` are true | Off: only with `control.enabled` | The runbooks start and deallocate the demo's VMs, start and stop T4, set the activity profiles through managed Run Command, and manage their own stop schedules |
| On-demand activity control: notebook users (Phase 25c) | The one secret `dbhub-activity-webhook` (A3) | **Key Vault Secrets User** | An Owner, with `setup-activity-control.ps1 -GrantRole`: the Owner who runs it and `control.notebookUserObjectIds` | Off: only with `control.enabled` | The control notebook reads the webhook URL from that secret, and from nothing else |
| Viewer of the Real-Time Dashboard (Phase 18) | Subscription; demo resource group | Reader (P8), plus the Arc telemetry role for Reader-only viewers; a workspace role, or the dashboard shared | As for presenters (P8); the workspace's administrator shares the dashboard | Optional | The dashboard queries the telemetry endpoint as the viewer, which returns rows only for resources they can read |
| Viewer of the history report (Phase 19) | Workspace or report | A viewer role, or the report shared with them; Pro, PPU, or a trial while the capacity is smaller than F64 (P11) | The workspace's administrator; licenses are assigned outside Azure | Optional | Fabric's viewer rule for Power BI content |
| Deployer of the Insights app (Phase 19b) | Fabric workspace; the Rayfin CLI | Contributor or higher on the workspace (P5), and the CLI's one-time sign-in as that user (P14) | The workspace's administrator; the operator signs in once | Optional | `rayfin up` creates or updates the app item `APP_DatabaseHub_Insights` as the signed-in user; no role assignment and no service principal |
| Viewer of the Insights app (Phase 19b) | App item; semantic model | Run and interact with the app item (a workspace role, or the item shared); **Read** and **Build** on `SM_DatabaseHub_History`; the tenant settings P12 and P13 | The workspace's administrator | Optional | Protected hosting serves the app only to users with permission on the item; the connector runs DAX as the signed-in user (delegated), so it sees only what the viewer can read ([hosting](https://learn.microsoft.com/fabric/apps/hosting), [connectors](https://learn.microsoft.com/fabric/apps/connectors)) |
| Read-only attendee | none | None, or Reader (P8) to use Hub themselves | An administrator | — | |

## One-time administrator commands (optional)

The scripts print these with your values filled in. Shown here with placeholders:

```powershell
# P7: let the GitHub identity deploy (run by an Owner, User Access Administrator,
# or Role Based Access Control Administrator)
az role assignment create --subscription <subscriptionId> `
  --assignee-object-id <githubIdentityPrincipalId> --assignee-principal-type ServicePrincipal `
  --role Contributor --scope /subscriptions/<subscriptionId>

# P8: let a non-Contributor presenter use Hub
az role assignment create --subscription <subscriptionId> `
  --assignee-object-id <presenterObjectId> --assignee-principal-type User `
  --role Reader --scope /subscriptions/<subscriptionId>

# P8: let that presenter see T2 (Arc) performance data; the role is resolved by name
az role assignment create --subscription <subscriptionId> `
  --assignee-object-id <presenterObjectId> --assignee-principal-type User `
  --role "Azure Hybrid Database Administrator - Read Only Service Role" `
  --scope /subscriptions/<subscriptionId>/resourceGroups/rg-<prefix>-<env>

# Key Vault opt-in: give one more principal the one-time host password, on the vault only
# (<principalType>: User, Group, or ServicePrincipal, so the Azure CLI doesn't look the principal up)
az role assignment create --subscription <subscriptionId> `
  --assignee-object-id <objectId> --assignee-principal-type <principalType> `
  --role "Key Vault Secrets User" `
  --scope /subscriptions/<subscriptionId>/resourceGroups/rg-<prefix>-<env>/providers/Microsoft.KeyVault/vaults/kv-<prefix><env>-<deploymentId>
```

Administrators who delegate these assignments should prefer **Role Based Access Control Administrator with a condition** limited to the roles above, rather than Owner or User Access Administrator.

## The Key Vault opt-in

Off by default; the default path is unchanged (owner's decision, 2026-10-21; [ADR 0008](adr/0008-identity-rbac-abac.md) and [ADR 0009](adr/0009-secrets-handling.md) have the details). With `keyVault.enabled` (which the configuration schema allows only with `assignRoles = true`):

- `deploy.ps1` deploys `kv-<prefix><environment>-<deploymentId>` in the demo resource group with Azure RBAC authorization and soft delete (`keyVault.softDeleteRetentionDays`, 7 by default; purge protection only with `keyVault.purgeProtection`), and its firewall limited to `keyVault.allowedIpRanges` when that lists addresses.
- Access is a role assignment on the vault only, resolved by role name: **Key Vault Secrets Officer** ("perform any action on the secrets of a key vault, except manage permissions") for the caller and `keyVault.operatorObjectIds`, and **Key Vault Secrets User** ("read secret contents") for `keyVault.readerObjectIds` ([Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)). Without the right to create role assignments, no vault is deployed.
- The vault holds only the one-time T2 host password. Bastion's documented RDP sign-in methods are Microsoft Entra ID (preview), username and password, and Kerberos ([connect with RDP](https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows)), so the operator copies the value from the vault's page in the portal instead of from the clipboard of the machine that ran `start-demo.ps1`.
- `validate.ps1 -Area Security` expects exactly that vault and those two roles on it ([verify the footprint](#verify-the-footprint)).

## The on-demand activity control

Off by default (`control.enabled`); with it off, nothing here exists ([ADR 0020](adr/0020-on-demand-activity-control.md)).

- **Contributor sets it up:** `setup-activity-control.ps1` registers `Microsoft.Automation`, creates `rg-<prefix>-control` when it doesn't exist, deploys the identity, the Automation account, and the vault, publishes the runbooks, schedules the daily T4 safety stop, creates the webhook, and writes its URL into the vault through Azure Resource Manager (`Microsoft.KeyVault/vaults/secrets/write` is a control-plane action, so no data-plane role is needed for it). It also creates the Fabric items, with your Fabric rights.
- **`start-demo.ps1` and `stop-demo.ps1`** remove a run's pending auto-stop (the schedule `dbhub-autostop` and its job schedules), and `start-demo.ps1` reads the control account's jobs to wait for a stop job in flight. The operator's Contributor covers both, and neither ever stops a job.
- **An Owner grants once:** `./scripts/setup-activity-control.ps1 -ConfigPath ./config/demo.config.json -GrantRole`, signed in with multifactor authentication, creates the custom role **DbHub Demo Activity Operator** (assignable only in this subscription) and assigns:

  | # | Role | Principal | Scope |
  |---|---|---|---|
  | A1 | DbHub Demo Activity Operator | `id-<prefix>-automation` | `rg-<prefix>-<environment>` |
  | A2 | DbHub Demo Activity Operator | `id-<prefix>-automation` | `aa-<prefix>-control` |
  | A3 | Key Vault Secrets User | The Owner who runs it, and `control.notebookUserObjectIds` | The secret `dbhub-activity-webhook` only |

  It shows the identity's object ID before it assigns anything, and `-WhatIf` lists the role's exact actions and each assignment without creating them. The role's 22 actions are in [ADR 0020](adr/0020-on-demand-activity-control.md#the-role-dbhub-demo-activity-operator): no VM, disk, network, or database can be created or deleted with it, and it has no action Run Command and no Key Vault, Fabric, or role-assignment permission.
- **Why not one assignment at the subscription:** the subscription is shared, and at that scope the identity could start, deallocate, and run commands on every VM in it. A1 and A2 limit it to the demo's VMs, T4, and its own control account.
- **After a redeploy:** A1 is deleted with the demo resource group. `deploy.ps1` grants it again after the Infrastructure stage when `assignRoles` and `control.enabled` are true, with the same function as `-GrantRole` and nothing else. Otherwise, or when that grant fails (no Owner rights, a sign-in that needs multifactor authentication, the role definition missing), `DEPLOY.SUMMARY` reports **Manual action required** with the exact `-GrantRole` command, and `validate.ps1` reports a missing A1 the same way (`CONTROL.ROLE.A1`). Until A1 is back, the runbook can't read the demo group and does nothing.
- **Contributor-only deployers** don't need the control: `./scripts/demo-control.ps1` sets the same activity profiles from their machine.

## Presenter access

Contributors already have everything Database Hub needs, so list only presenters who aren't Contributors in `presenterObjectIds`. `configure-fabric.ps1` handles them with `Set-DemoPresenterAccess` (Phase 9):

- **`assignRoles` false (the default):** nothing is called. `HUB.PRESENTER.READER` and `HUB.PRESENTER.ARCTELEMETRY` report **Manual action required**, with one `az role assignment create` command per presenter, filled in with your values. The printed commands leave out `--assignee-principal-type`, so they also work when a presenter entry is a group.
- **`assignRoles` true:** the script checks that you can create role assignments at each scope, resolves each role **by name** at run time (`az role definition list --name`; no role ID is pinned), skips presenters who already hold it at that scope or above, and assigns the rest with `--assignee-object-id`, which needs no Microsoft Graph lookup. Without the rights, the result is **Fail** with the commands. `-WhatIf` assigns nothing.
- **Why two roles:** Hub discovery and performance data need Reader on the subscription ([monitor SQL](https://learn.microsoft.com/fabric/database/hub/monitor-sql)). Arc SQL performance data also needs `Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action`, which the built-in **Azure Hybrid Database Administrator - Read Only Service Role** includes ([add SQL](https://learn.microsoft.com/fabric/database/hub/add-sql)). The Azure RBAC built-in role catalog doesn't list that role, which is why it's resolved by name (risk R22).
- **Developer mode:** with `t2SqlInstallMode = Developer`, T2 sends no performance data, so the Arc role is **Not supported** and isn't assigned.

## Presentation surfaces and viewer licensing

Who can see what on each [presentation surface](presentation.md) (Phase 18):

- **Database Hub and the Real-Time Dashboard** use the viewer's own Azure access: Reader on the subscription, plus the Arc telemetry role on the demo resource group for viewers who are only Readers, exactly as for presenters above. The dashboard's data source is the documented telemetry proxy with pass-through identity, so sharing the dashboard doesn't share the data; a viewer without Reader sees empty tiles ([Real-Time Dashboard permissions](https://learn.microsoft.com/fabric/real-time-intelligence/dashboard-permissions)). Neither is Power BI content, so a Fabric Free license is enough.
- **The history report** (Phase 19) is Power BI content. "On F SKUs smaller than F64, each user viewing Power BI content must have Pro, PPU, or an individual trial; on F64 or larger, users with only a Free license and a viewer role can view" ([Fabric licenses](https://learn.microsoft.com/fabric/enterprise/licenses)). The demo workspace's capacity is an F16, so their viewers need Pro or PPU (optional prerequisite P11). A presenter who shares their screen needs nothing more.
- **The check:** `PREFLIGHT.FABRIC.VIEWERLICENSE` in `preflight.ps1` and `configure-fabric.ps1` reads the capacity's SKU and warns below F64. Licenses are assigned outside Azure, so no script assigns them.
- **The Insights app** (Phase 19b) isn't in Learn's list of Power BI items, but it reads the semantic model as the viewer, so plan for the same rule as the report until that's verified (TODO(verify)). Its viewers need access to the app item and Read and Build on `SM_DatabaseHub_History`; no Azure access ([the app's guide](../fabric/app/README.md#open-the-app)).

## GitHub (optional)

The GitHub side needs no Azure permission beyond the one Contributor assignment for the GitHub identity (P7), and the scripts act on GitHub only when you ask ([ADR 0022](adr/0022-public-repository-and-github-actions-hardening.md)):

- **`setup-github-oidc.ps1 -ConfigureGitHub`** and **`setup-github-repo.ps1`** use the GitHub CLI as the account you signed in with (`gh auth login`; the scripts never sign in), and need that account to be an **administrator of the repository**: only administrators create environments and change security settings. Each environment gets you as its required reviewer.
- **What GitHub refuses on a private repository** on GitHub Free, Pro, and Team (rulesets, required reviewers, private vulnerability reporting) is reported as **Manual action required**, to run again once the repository is public.
- **The workflows' own token** has `contents: read`, and `id-token: write` only on the job that signs in to Azure; no workflow writes to the repository.

## Verify the footprint

`./scripts/validate.ps1 -Area Security` reads the environment and changes nothing:

| Check | Pass when |
|---|---|
| `SECURITY.RBAC.ROLEASSIGNMENTS` | There are no role assignments at or below the demo resource group, or only Reader, the Arc telemetry role, with `assignRoles = true` Azure Connected Machine Onboarding, with `keyVault.enabled` Key Vault Secrets Officer and Key Vault Secrets User on the opt-in vault itself, and with `control.enabled` the activity control's custom role at exactly the group (A1). Any other assignment, including those roles at another scope, is a Warning that names it. The evidence (`callerCanAssignRoles`) says whether the caller could create role assignments: only a run where it's `false` proves the Contributor-only path. |
| `SECURITY.SECRETS.KEYVAULT` | There's no Key Vault in the demo resource group (ADR 0009); with `keyVault.enabled`, only the opt-in vault, with Azure RBAC authorization and soft delete. Its firewall, retention, and purge protection are in the evidence. |

Live result, 2026-10-21 (Key Vault opt-in off): no role assignments at or below the demo resource group and no Key Vault, so both **Pass**. The operator's account could also create role assignments, so the full Contributor-only run (deploy, operate, validate, destroy with an identity that holds only Contributor) is still pending (risk R210).

## T3 administration options

| Option | When | How |
|---|---|---|
| Default (P6) | You can own an Entra security group | The group is the T3 admin; T1's identity is added to it; T1 configures T3 |
| Hardened | An administrator can grant the T3 server identity Directory Readers | The P6 group stays humans-only; T1 gets a least-privilege contained user |
| Fallback | No P6 group is possible | You become the T3 admin and run the T-SQL step interactively |

## T4 administration (Phase 24)

T4, the PostgreSQL flexible server, needs nothing beyond P1 and P6 ([ADR 0019](adr/0019-t4-postgresql-flexible-server.md)): the template makes the P6 group T4's Microsoft Entra administrator (`flexibleServers/administrators`, a resource Contributor can write), T1's managed identity signs in through the group to create the runner's role, and no Azure role assignment is made. Database Hub discovers and monitors T4 with Reader on the subscription, which Contributor covers. To see T4's queries or sessions yourself, sign in to `contosocare` as a member of the P6 group from a demo VM (T4 has no public endpoint).
