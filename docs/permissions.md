# Permissions

> **Status: final (Phase 14, 2026-10-21)**, from [ADR 0008](adr/0008-identity-rbac-abac.md). `validate.ps1 -Area Security` checks the footprint on a live environment ([verify it](#verify-the-footprint)).

## The model in one paragraph

The deploying identity needs **Contributor on the subscription** to deploy. The default deployment creates **no Key Vault in the demo resource group**, and role assignments only when the person who deploys may create them, each an owner-approved exception: the [nightly safety stop's](#the-nightly-safety-stop) stop-only custom role for its own identity, at the demo resource group (2026-11-05, [ADR 0024](adr/0024-nightly-safety-stop.md)), and since 2026-11-14 the [session control's](#the-on-demand-activity-control) two custom roles and its vault's secret readers ([ADR 0026](adr/0026-one-run-all-session.md)), whose vault is in `rg-<prefix>-control`. A Contributor's deployment still ends **DONE** without them, with the one command for an Owner (P16), `./scripts/grant-safety-stop.ps1`, which grants them all. Anything else that needs more than Contributor is optional, gated by `assignRoles` or done once by an administrator, and listed in [prerequisites](prerequisites.md) as P7–P11 and P15. The opt-in Key Vault (`keyVault.enabled`, Phase 13) is the only feature that adds data-plane roles in the demo resource group; it requires `assignRoles = true`, and `Initialize-DemoKeyVault` checks the permission before it deploys a vault, so none is left that nobody can use.

## What Contributor covers

- Creating the resource group and every resource; registering resource providers.
- Managed Run Command, VMAccess password resets, and SQL IaaS extension updates.
- Arc onboarding with the caller's own token, and deleting stale Arc resources.
- Arc SQL property updates, the Azure SQL Entra admin, Azure budgets, and on-demand Bastion.
- Reading the Hub telemetry endpoint and seeing every target in Hub. Contributor includes Reader at subscription scope and `Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action`.
- Reading the Azure Policy assignments that apply to the subscription and the Defender for Cloud plans (preflight, read-only). Policy definitions stored at a management group may need read access there; preflight reports a Warning, not a Fail, when it can't read them.
- Everything `validate.ps1` reads: role assignments, deployment history and operations, Run Command instance views, Resource Graph, budgets, and auto-shutdown schedules.
- The nightly safety stop's identity, Automation account, runbook, and schedules (`Microsoft.Automation` is registered when needed), and reading its jobs for `status.ps1`.

## What Contributor can't do (and the demo doesn't need)

- Create role assignments. Needed only for the nightly safety stop's role (P16, recommended), and for the optional P7, P8, P15, and `assignRoles = true`.
- Create custom roles. Needed only for the nightly safety stop's role (P16) and the on-demand activity control's (P15).
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
| Nightly safety stop: `id-<prefix>-<environment>-safetystop` (2026-11-05) | The demo resource group only | **DbHub Demo Safety Stop**, a custom role with 7 actions ([ADR 0024](adr/0024-nightly-safety-stop.md#the-role-dbhub-demo-safety-stop)) | `deploy.ps1`, when the person who runs it may create and assign roles; otherwise an Owner, with `./scripts/grant-safety-stop.ps1` (P16) | Default, when the deployer may | Its runbook deallocates the demo's VMs and stops T4 each night, and reads T3's status; it can't start, change, or delete anything |
| Session control: `id-<prefix>-automation` (Phase 25c; every deployment since 2026-11-14) | The demo resource group (A1) and `aa-<prefix>-control` (A2) only | **DbHub Demo Activity Operator**, a custom role with 27 actions ([below](#the-on-demand-activity-control)) | `deploy.ps1` when you may; otherwise an Owner, once, with `./scripts/grant-safety-stop.ps1` | On | The runbooks start and deallocate the demo's VMs, start and stop T4, create and delete its read replica for a session, read their metrics, mark the demo busy, set the activity profiles through managed Run Command, and manage their own stop schedules |
| Session control: `id-<prefix>-automation` (2026-11-14) | The secrets `dbhub-session-status` and `dbhub-session-metrics` only (A4) | **DbHub Demo Session Writer**, a custom role with 2 actions | As above | On | The runbook writes a session's status and its metrics for the notebook |
| Session control: notebook users (Phase 25c) | The secrets `dbhub-activity-webhook`, `dbhub-session-status`, and `dbhub-session-metrics` only (A3) | **Key Vault Secrets User** | As above: the Owner who grants, and `control.notebookUserObjectIds` | On | The control notebook reads the webhook URL, a session's status, and its metrics from those secrets, and from nothing else |
| Viewer of the Real-Time Dashboard (Phase 18) | Subscription; demo resource group | Reader (P8), plus the Arc telemetry role for Reader-only viewers; a workspace role, or the dashboard shared | As for presenters (P8); the workspace's administrator shares the dashboard | Optional | The dashboard queries the telemetry endpoint as the viewer, which returns rows only for resources they can read |
| Viewer of the history report (Phase 19) | Workspace or report | A viewer role, or the report shared with them; Pro, PPU, or a trial while the capacity is smaller than F64 (P11) | The workspace's administrator; licenses are assigned outside Azure | Optional | Fabric's viewer rule for Power BI content |
| Deployer of the Insights app (Phase 19b) | Fabric workspace; the Rayfin CLI | Contributor or higher on the workspace (P5), and the CLI's one-time sign-in as that user (P14), which `deploy.ps1` starts at the beginning of the run | The workspace's administrator; the operator signs in once | Every deployment since 2026-11-05; without the sign-in, the app isn't created and `deploy.ps1` still ends **DONE** | `rayfin up` creates or updates the app item `APP_DatabaseHub_Insights` as the signed-in user; no role assignment and no service principal |
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

The session control behind the control notebook's **Run all**, part of every deployment since 2026-11-14 ([ADR 0026](adr/0026-one-run-all-session.md); before then it was optional, [ADR 0020](adr/0020-on-demand-activity-control.md)).

- **Contributor sets it up, on every `deploy.ps1`:** it registers `Microsoft.Automation`, creates `rg-<prefix>-control` when it doesn't exist, deploys the identity, the Automation account, and the vault, publishes the runbooks, schedules the daily T4 safety stop, creates the webhook, writes its URL into the vault, and creates the session's two secrets, all through Azure Resource Manager (`Microsoft.KeyVault/vaults/secrets/write` is a control-plane action, so no data-plane role is needed for it). After the Fabric track it puts the notebook in Fabric, with your Fabric rights. `setup-activity-control.ps1` does the same on its own.
- **`start-demo.ps1` and `stop-demo.ps1`** remove a run's pending auto-stop (the schedules `dbhub-autostop` and, after a session, `dbhub-autostop-backup`, with their job schedules), and `start-demo.ps1` reads the control account's jobs to wait for a stop job in flight. The operator's Contributor covers both, and neither ever stops a job.
- **The roles, granted once:** `deploy.ps1` creates and assigns them when the person who runs it may (an Owner or a User Access Administrator). Otherwise each missing one is a **Warning**, never a **Fail**, with `./scripts/grant-safety-stop.ps1`, which an Owner runs once, signed in with multifactor authentication, for the safety stop's role and these together:

  | # | Role | Principal | Scope |
  |---|---|---|---|
  | A1 | DbHub Demo Activity Operator | `id-<prefix>-automation` | `rg-<prefix>-<environment>` |
  | A2 | DbHub Demo Activity Operator | `id-<prefix>-automation` | `aa-<prefix>-control` |
  | A3 | Key Vault Secrets User | The Owner who grants, and `control.notebookUserObjectIds` | The secrets `dbhub-activity-webhook`, `dbhub-session-status`, and `dbhub-session-metrics` only |
  | A4 | DbHub Demo Session Writer | `id-<prefix>-automation` | The secrets `dbhub-session-status` and `dbhub-session-metrics` only |

  Both custom roles are assignable only in this subscription. The grant shows the identity's object ID before it assigns anything, and `-WhatIf` lists each role's exact actions and each assignment without creating them. A role that already has exactly its approved actions isn't written again.
- **DbHub Demo Activity Operator, 27 actions:** the 22 of [ADR 0020](adr/0020-on-demand-activity-control.md#the-role-dbhub-demo-activity-operator) (start and deallocate the demo's VMs, set their activity through managed Run Command, start and stop T4, and manage the control's own one-time schedules) and, since 2026-11-14, five for a session:

  | Action | What a session uses it for | What it could also touch, at the demo resource group |
  |---|---|---|
  | `Microsoft.DBforPostgreSQL/flexibleServers/write` | Creates T4's read replica | Could change T4; the runbook never does |
  | `Microsoft.DBforPostgreSQL/flexibleServers/delete` | Deletes the replica after a session | Could delete T4; the runbook deletes only a server whose `replicationRole` says it's a read replica |
  | `Microsoft.DBforPostgreSQL/flexibleServers/configurations/write` | Sets the replica's `max_standby_streaming_delay` | Could change any server parameter of T4 or the replica |
  | `Microsoft.Insights/metrics/read` | Reads T4's and the replica's metrics for the history | Read-only |
  | `Microsoft.Resources/tags/write` | Marks the demo busy for the nightly stop, and records the session | Could change any tag in the demo resource group, `deploymentId` included |

  No network join action: the replica's create names T4's delegated subnet and private DNS zone, and Azure created it for a role without `Microsoft.Network/virtualNetworks/subnets/join/action` and `Microsoft.Network/privateDnsZones/join/action` (live, 2026-11-14, 70 minutes after they were removed), so neither is granted.

- **DbHub Demo Session Writer, 2 actions,** at the two session secrets only, never at the demo resource group, whose optional vault it never reaches:

  | Action | What a session uses it for | What it could also touch |
  |---|---|---|
  | `Microsoft.KeyVault/vaults/secrets/read` | Reads the session secrets' properties (Azure Resource Manager never returns a value) | Nothing else |
  | `Microsoft.KeyVault/vaults/secrets/write` | Writes the session's status and its metrics | Could overwrite those two secrets' values, which the notebook reads as status and metrics, never as credentials |

- **No DevTestLab action:** the role holds only what the runbook uses. A session ends before the VMs' auto-shutdown instead of moving it ([why](adr/0026-one-run-all-session.md#the-permissions-one-time-by-an-owner)).
- **Shared by the subscription:** custom roles belong to the whole subscription, so environments in one subscription share these two, and a `deploy.ps1` on newer code updates them for all of them. `control.roleNameSuffix` gives an environment its own, "DbHub Demo Activity Operator (*suffix*)" and "DbHub Demo Session Writer (*suffix*)", for one beside a demo on other code.
- **Why not one assignment at the subscription:** the subscription is shared, and at that scope the identity could start, deallocate, and run commands on every VM in it. A1 and A2 limit it to the demo's VMs, T4 and its replica, and its own control account.
- **After a redeploy:** A1 is deleted with the demo resource group. The next grant assigns it again (`deploy.ps1` when you may, otherwise `./scripts/grant-safety-stop.ps1`), and `validate.ps1` reports a missing one as a **Warning** (`CONTROL.ROLE.A1`). Until then, the runbook can't read the demo group and does nothing.
- **Without the roles:** Run all can't act on the demo's resources, and says so; `./scripts/start-demo.ps1` runs a session from a PC with Contributor, and `./scripts/demo-control.ps1` sets the same activity profiles.

## The nightly safety stop

Part of every deployment since 2026-11-05 ([ADR 0024](adr/0024-nightly-safety-stop.md); [what it does](../README.md#what-stops-or-pauses-on-its-own)). Contributor sets up everything except its role:

- **Contributor's part, on every `deploy.ps1`:** the identity `id-<prefix>-<environment>-safetystop` and the Automation account `aa-<prefix>-<environment>-safetystop` in the demo resource group (`infra/safetystop/safetystop.bicep`), the runbook `DbHub-Stop`, and its two daily schedules.
- **The role:** the custom role **DbHub Demo Safety Stop**, assignable only in this subscription, with exactly 7 actions: read the resource group, the VMs, their instance view, T3's database, and T4; deallocate a VM; and stop T4 ([the list](adr/0024-nightly-safety-stop.md#the-role-dbhub-demo-safety-stop)). It can't start, create, change, or delete anything, has no Run Command, and has no Automation, Key Vault, Fabric, or role permission. Its one assignment is to the safety stop's identity at `rg-<prefix>-<environment>`, with the principal type set.
- **Who creates it:** `deploy.ps1`, when the person who runs it has `Microsoft.Authorization/roleDefinitions/write` in the subscription (an Owner or a User Access Administrator) to create or update the role, and `Microsoft.Authorization/roleAssignments/write` on the demo resource group to assign it (also a Role Based Access Control Administrator, once the role exists). This one assignment doesn't depend on `assignRoles`: an owner-approved exception to [ADR 0008](adr/0008-identity-rbac-abac.md) (2026-11-05).
- **Otherwise:** `SAFETYSTOP.ROLE` is a **Warning**, never a **Fail**, and the run still ends **DONE**, which says that nothing stops T4 after its 7-day restart until an Owner runs, once, `./scripts/grant-safety-stop.ps1`; the VMs' nightly auto-shutdown and T3's auto-pause still apply. The script runs the subscription guard, then creates the role and its assignment only. A destroy deletes the assignment with the group, so a redeploy needs it again; the role definition stays, unassigned, and the next deployment uses it.
- **No Owner at all:** the safety stop's schedules still exist, and each job ends with `NotGranted` in its job history and in `status.ps1` (`STATUS.SAFETYSTOP`).

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
- **The check:** none since 2026-11-14: the viewers' licenses are assumed, so `PREFLIGHT.FABRIC.VIEWERLICENSE` is **Not selected** and reads nothing. Licenses are assigned outside Azure, so no script assigns them.
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
| `SECURITY.RBAC.ROLEASSIGNMENTS` | There are no role assignments at or below the demo resource group, or only the nightly safety stop's custom role at exactly the group (since 2026-11-05), Reader, the Arc telemetry role, with `assignRoles = true` Azure Connected Machine Onboarding, with `keyVault.enabled` Key Vault Secrets Officer and Key Vault Secrets User on the opt-in vault itself, and the session control's custom role at exactly the group (A1, under this environment's name with `control.roleNameSuffix`). Any other assignment, including those roles at another scope, is a Warning that names it. The evidence (`callerCanAssignRoles`) says whether the caller could create role assignments: only a run where it's `false` proves the Contributor-only path. |
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
