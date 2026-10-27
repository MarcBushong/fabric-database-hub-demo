# ADR 0008: Identity and permissions: the Contributor-only model

- **Status:** Accepted
- **Date:** 2026-10-19 (revised the same day for plan §9, Revision 2; revised 2026-10-21 for the Key Vault opt-in, Phase 13)
- **Decision source:** Plan §9.1 (supersedes Q4a "Owner" and plan §4.4 where they conflict); user decision Q4d (Entra group as T3 admin); owner decision 2026-10-21 (user-directed) for the Key Vault opt-in
- **Related:** [ADR 0005](0005-arc-onboarding-authentication.md), [ADR 0009](0009-secrets-handling.md), [permissions](../permissions.md), [prerequisites](../prerequisites.md), [security model](../security-model.md)

## Context

- The user asked that the deploying identity need **at least Contributor on an existing subscription**, with every other prerequisite documented (plan §9.1).
- **What Contributor covers:**
  - creating the resource group and every resource, and registering resource providers;
  - managed Run Command, VMAccess password resets, and SQL IaaS extension updates;
  - Arc onboarding with the caller's own token, and deleting stale Arc resources;
  - Arc SQL property updates, setting the Azure SQL Entra admin, Azure budgets, and on-demand Bastion;
  - reading the Hub telemetry endpoint. Contributor includes subscription-scope Reader and `Microsoft.AzureArcData/sqlServerInstances/getTelemetry/action`.
- **What Contributor can't do:** create role assignments, change Entra directory roles, or change Fabric tenant settings.
- **T3 user creation:** creating Entra users in Azure SQL from a service principal or managed identity needs the server identity to have Microsoft Graph read permissions (for example, Directory Readers), which only a privileged administrator can grant.

## Decision drivers

1. Contributor alone deploys, operates, and destroys the whole demo.
2. Anything that needs more is optional, documented, and checked by preflight.
3. Least privilege where it's possible without administrators.

## Decision

### Default: no role assignments (`assignRoles = false`)

- The templates and scripts create **no role assignments** unless `assignRoles = true` and the caller has `Microsoft.Authorization/roleAssignments/write`. Preflight checks that permission before honoring the flag.
- No Key Vault is deployed (ADR 0009), so no data-plane role is needed. The Key Vault opt-in (`keyVault.enabled`, Phase 13) is the exception, and it requires `assignRoles = true` (below).

### Prerequisites

Preflight checks each prerequisite and reports it with a status ([ADR 0012](0012-validation-model.md)).

| # | Prerequisite | Provided by | Needed for |
|---|---|---|---|
| P1 | Contributor on the target subscription | Subscription Owner (assumed in place) | Everything |
| P2 | Registered providers: `Microsoft.Sql`, `Microsoft.SqlVirtualMachine`, `Microsoft.AzureArcData`, `Microsoft.HybridCompute`, `Microsoft.GuestConfiguration`, `Microsoft.HybridConnectivity`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Consumption`, `Microsoft.DevTestLab` | Preflight registers them (Contributor) | Everything |
| P3 | Quota in the region: at least 8 vCPUs across the chosen families, plus a Standard public IP for on-demand Bastion | Subscription | T1, T2 |
| P4 | Database Hub tenant setting enabled; a Fabric Free license for each Hub user | Fabric administrator (assumed in place) | Hub, Database Agent |
| P5 | Contributor or higher on the demo workspace (its ID is in the notebook metadata), on F or Trial capacity | Workspace administrator | Notebooks |
| P6 | An Entra security group **owned by the deploying user**, set as the Azure SQL Entra admin. The deployment adds the T1 runner identity to it. | The user (if group creation is allowed) or an Entra administrator | Fully automated T3 configuration |
| P7 | *(Optional)* GitHub one-click: `setup-github-oidc.ps1` creates the identity and federated credentials (Contributor can), and an Owner, User Access Administrator, or Role Based Access Control Administrator assigns **Contributor on the subscription** to it. The exact command is printed. | One-time administrator action | `deploy.yml`, `demo-control.yml`, `destroy.yml`, scheduled workflows |
| P8 | *(Optional)* Reader on the subscription for presenters or attendees who aren't Contributors | Owner, User Access Administrator, or Role Based Access Control Administrator | Hub visibility for those users |
| P9 | *(Optional)* A GitHub fine-grained token in a Key Vault secret readable by the notebook user | The user | Triggering scenarios from the live-activity notebook |
| P10 | *(Optional)* A SQL Server Standard product key | The customer's licensing | `t2SqlInstallMode = ProductKey` |

### Identities

| Identity | Rights | Notes |
|---|---|---|
| Deploying user | Contributor on the subscription (P1) | `deploy.ps1` from Cloud Shell or local PowerShell 7 |
| GitHub user-assigned identity `id-<prefix>-github` in `rg-<prefix>-control` | Contributor on the subscription, assigned once by an administrator (P7) | One federated credential per GitHub environment (`repo:<owner>/<repo>:environment:<name>`); no branch or pull-request subjects for deploy, control, or destroy |
| T1 system-assigned identity | Member of the P6 group, so it's a T3 admin | Required by SQL VM monitoring anyway. Runs T3 configuration and the T3 workload. |
| T2 host system-assigned identity | None | Exists for platform features; the guest can't reach it (ADR 0004) |
| `id-<prefix>-arc-onboard` (only with `assignRoles = true`) | Azure Connected Machine Onboarding on the demo resource group | Optional least-privilege onboarding (ADR 0005) |
| Presenter | Contributor (P1), or Reader on the subscription (P8) | Hub needs Reader at subscription scope and `Microsoft.Sql` registered |
| Read-only attendee | None, or Reader on the subscription (P8) to use Hub themselves | |
| DBA | Member of the P6 group for T3; Windows administrator on T1 and the T2 guest through Bastion | Break-glass through a one-time password set by Run Command (ADR 0009, revised in Phase 13) |
| Key Vault opt-in principals (only with `keyVault.enabled` and `assignRoles = true`) | Key Vault Secrets Officer (the caller, `keyVault.operatorObjectIds`) or Key Vault Secrets User (`keyVault.readerObjectIds`) on the opt-in vault only | Store, disable, or read the one-time host password (ADR 0009) |
| Fabric administrator | Fabric administrator role | Enables the Hub tenant setting (P4), once |

### T3 administration (P6)

- The T3 Entra admin is the P6 group (Q4d). `deploy.ps1` adds T1's system-assigned identity to that group through Microsoft Graph, using the caller's delegated rights as a group owner, with a token verified for the configured tenant ([ADR 0011](0011-control-surface-priority.md#guard-update-2026-10-21)): `az ad` would use the Azure CLI's default account. The step is idempotent and re-runs after T1 is re-created.
- T1 then configures T3 (schema, seed, extended property) in both network modes.
- **In GitHub Actions**, the GitHub identity must also be an owner of the P6 group. Otherwise the step reports **Manual action required** with the exact command.
- **Over-privilege (risk R26):** the T1 runner identity is a T3 administrator on a single-purpose demo server holding synthetic data. This is accepted and documented.
- **Hardened option** (tenants that allow it): grant the T3 server identity Directory Readers, keep the P6 group for humans only, and create a least-privilege contained user for T1 (`db_datareader`, `db_datawriter`, `EXECUTE` on the `demo` schema).
- **Fallback when P6 isn't possible (risk R27):** the deploying user becomes the T3 Entra admin, and runs the T-SQL interactively through the local path (ADR 0007).

### When `assignRoles = true`

Assignments are limited to:

- Reader on the subscription for listed presenter principals (P8), if the caller has rights at subscription scope;
- the Arc onboarding identity's Onboarding role;
- with the Key Vault opt-in (`keyVault.enabled`, owner decision 2026-10-21): **Key Vault Secrets Officer** for the signed-in caller and `keyVault.operatorObjectIds`, and **Key Vault Secrets User** for `keyVault.readerObjectIds`, each scoped to the opt-in vault only.

Administrators who delegate these assignments should use **Role Based Access Control Administrator with a condition** that limits assignable roles to Reader and Azure Connected Machine Onboarding (and, with the opt-in, Key Vault Secrets Officer and Key Vault Secrets User), rather than Owner or User Access Administrator.

## Consequences

- **Positive:** a Contributor can deploy, run, and destroy everything without an administrator. Administrator-only items are optional and visible in preflight.
- **Negative:**
  - The T1 identity is over-privileged on T3 (R26).
  - GitHub one-click needs a one-time administrator action (R28).
  - The default Arc onboarding token carries Contributor rights (ADR 0005).

## Phase 8 addendum: T1 and the P6 group, as built (2026-10-20)

- **Order matters.** The managed identity infrastructure caches tokens for each resource for up to about 24 hours, and Microsoft documents that a managed identity's new group membership can take hours to take effect. So T1 must join the P6 group **before** anything on T1 asks for an Azure SQL token. `Add-DemoT1ToT3AdminGroup` (`T3.ADMINGROUP`) runs right after T1 exists: it checks the membership, adds it when it's missing, waits until Microsoft Graph reports it, and then waits 60 seconds more. It retries an identity that Microsoft Graph doesn't know yet, and it's idempotent, so it runs again after T1 is recreated with a new identity.
- **When the caller can't add members** (not an owner, for example the GitHub identity in Actions), the result is **Manual action required** with the exact command for an owner, and the fallback is the interactive T-SQL step (ADR 0007).
- **The first login is measured.** The T1 runner (`Invoke-DemoT3SqlFromT1`) retries login failures for up to 10 minutes and reports how long the login took. If it never succeeds, the result is a **Warning** with the measured wait: run the step again later, or use the fallback.
- **No contained users by default.** T1 and the DBAs reach T3 through the group as `dbo` (risk R26). `database/azuresql/030-configure.sql` creates the `contosocare_runner` role for the hardened option.
- **The hardened option no longer needs Directory Readers.** Azure SQL Database documents creating a contained user for a Microsoft Entra principal without validating it in Microsoft Entra: `CREATE USER [name] WITH SID = <id>, TYPE = E`, where the ID is a managed identity's or service principal's client ID (`TYPE = X` with the object ID for a group). For T1: create the user from T1's client ID (`az ad sp show --id <principalId> --query appId`), add it to `contosocare_runner`, then take T1 out of the P6 group. The server identity needs no Microsoft Graph permission for this path.
- Sources (checked 2026-10-20):
  - Managed identity token caching: <https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations>
  - `az ad group member`: <https://learn.microsoft.com/cli/azure/ad/group/member>
  - CREATE USER, example K (contained user without validation): <https://learn.microsoft.com/sql/t-sql/statements/create-user-transact-sql>

## Phase 13 addendum: the Key Vault opt-in (2026-10-21)

- **Decision (owner, user-directed):** an opt-in Azure Key Vault holds the one-time T2 host password, so Bastion sessions need no clipboard on the machine that runs the scripts ([ADR 0009](0009-secrets-handling.md)). The default stays Contributor-only, with no vault and no role assignment.
- **Gate:** `keyVault.enabled` requires `assignRoles = true`; the configuration schema refuses it otherwise. `Initialize-DemoKeyVault` checks `Microsoft.Authorization/roleAssignments/write` on the resource group before it deploys a new vault, so it never leaves a vault nobody can use.
- **Roles, on the vault only, resolved by name at run time** (`az role definition list --name`; no role ID is pinned): **Key Vault Secrets Officer** ("perform any action on the secrets of a key vault, except manage permissions") for the caller, who writes and disables the password, and for `keyVault.operatorObjectIds`, for example the GitHub identity that runs the scheduled stop; **Key Vault Secrets User** ("read secret contents") for `keyVault.readerObjectIds`, who only copy the password in the portal. Principals that already hold the role at the vault or above are skipped. The caller's object ID and type come from the subscription guard's verified token (its `oid` and `idtyp` claims), and the configured principals' types from Microsoft Graph's `directoryObjects/getByIds` with a token verified for the configured tenant, so every assignment passes `--assignee-principal-type` and the Azure CLI never looks a principal up in its default account's tenant ([ADR 0011](0011-control-surface-priority.md#guard-update-2026-10-21), 2026-10-21). A configured principal whose type Graph doesn't return isn't assigned; the result gives the administrator's command. When the guard hasn't confirmed the caller, the configured principals still get their roles, with a **Warning**.
- **Not granted:** Key Vault Administrator, Key Vault Contributor, or any role at a wider scope. Readers also need Reader on the resource group or subscription to find the vault in the portal (presenters get that from P8).
- Sources (checked 2026-10-21):
  - Key Vault RBAC and the built-in data-plane roles: <https://learn.microsoft.com/azure/key-vault/general/rbac-guide>
  - `az role assignment create --assignee-object-id`: <https://learn.microsoft.com/cli/azure/role/assignment>

## Validation

- **Phase 5 (live, pending go-ahead):** a principal holding only Contributor completes preflight; with `assignRoles = true` but no assignment rights, preflight reports a clear Fail.
- **Phase 8 (live, pending go-ahead):** T1 configures T3 through group membership; the fallback path works.
- **Phase 14 (live, pending go-ahead):** a full Contributor-only deploy, operate, and destroy run.
  - *(Phase 14 as built, 2026-10-21.)* `validate.ps1 -Area Security` checks the footprint: `SECURITY.RBAC.ROLEASSIGNMENTS` (no role assignments at or below the demo resource group except Reader, the Arc telemetry role, with `assignRoles` Azure Connected Machine Onboarding, and with the Key Vault opt-in the two Key Vault secrets roles on its vault) and `SECURITY.SECRETS.KEYVAULT` (no Key Vault, or only the opt-in vault with Azure RBAC). Its evidence records whether the caller could create role assignments (`Microsoft.Authorization/roleAssignments/write` in the subscription's permissions).
  - *(Live, read-only, 2026-10-21.)* Both **Pass** on the deployed environment: nothing assigned and no vault. The operator's account could create role assignments, so that run doesn't prove the Contributor-only path; the run with a Contributor-only identity is still pending (risk R210). The final role matrix is in [permissions](../permissions.md).

## Sources (checked 2026-10-19)

- Azure built-in roles: <https://learn.microsoft.com/azure/role-based-access-control/built-in-roles>
- Delegate role assignments with conditions: <https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview>
- Register resource providers: <https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types>
- Database Hub monitoring (Reader, `Microsoft.Sql`): <https://learn.microsoft.com/fabric/database/hub/monitor-sql>
- Entra admin for Azure SQL (groups): <https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-configure>
- Entra service principals in Azure SQL: <https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-service-principal>
- Workload identity federation for GitHub: <https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity>
- Manage group owners: <https://learn.microsoft.com/entra/fundamentals/how-to-manage-groups>
