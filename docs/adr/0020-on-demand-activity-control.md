# ADR 0020: On-demand activity control from a Fabric notebook

- **Status:** Accepted (the owner approved the design on 2026-10-26: the adaptive vault mode, and the custom role and A1-A3 exactly as below). Validated live on 2026-10-27 (Phase 25d, [validation](#validation)).
- **Date:** 2026-10-23 (proposed as a Phase 25b note), 2026-10-26 (decided; built in Phase 25c)
- **Decision source:** User-directed (2026-10-23: the notebook, the webhook, and the stop; 2026-10-26: the adaptive vault mode, the role and its assignments, and the README's "why"), with the coordinator's lifecycle for A1; engineering detail
- **Related:** [ADR 0002](0002-resource-group-topology.md) (the control resource group), [ADR 0008](0008-identity-rbac-abac.md) (role assignments only with approval), [ADR 0009](0009-secrets-handling.md) (secrets), [ADR 0010](0010-workload-generator-technology.md) (bounded workloads), [ADR 0011](0011-control-surface-priority.md) (the control surface), [ADR 0012](0012-validation-model.md) (statuses), [ADR 0014](0014-notebook-role-and-capacity.md) (notebooks and the capacity), [ADR 0016](0016-cost-profiles.md) (prices at run time), [permissions](../permissions.md), [security model](../security-model.md), [cleanup](../cleanup.md)

Placeholders: `<subscriptionId>` is the configured subscription, `<prefix>` the configured prefix (default `dbhub`), `<environment>` the configured environment (default `demo`), and `<suffix>` the first six hexadecimal characters of the SHA-256 of `<subscriptionId>|<prefix>|control`, which keeps the vault's global name stable.

## Context

- **The owner's words (2026-10-23):** "Can I just have a notebook that can be executed on demand to run the activity? I want to see live query data and metrics. History not as important." Chosen: "Notebook calls an Azure Automation webhook that starts the targets and runs the chosen scenarios; no weekday schedule and no hourly history". Then: "How would I stop it to ensure it runs only when I run it and stop it too".
- **This supersedes** the weekday program and the hourly notebook schedule in the Phase 25b brief: there's no recurring activity schedule anywhere. The GitHub schedules stay off (the repository variable `DBHUB_SCHEDULES_ENABLED` stays unset).
- **A notebook can't start an Azure job with its own identity:** `notebookutils.credentials.getToken` covers only `storage`, `pbi`, `keyvault`, and `kusto` ([credentials utilities](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials)), so there's no Azure Resource Manager token. An Azure Automation webhook starts a runbook with an HTTP POST and needs no token: its URL is the credential ([webhooks](https://learn.microsoft.com/azure/automation/automation-webhooks)).
- **Webhooks:**
  - A PowerShell 7 runbook receives the webhook's input as invalid JSON, so Learn recommends PowerShell 5.1 for them ([webhooks](https://learn.microsoft.com/azure/automation/automation-webhooks)).
  - The URL is shown once, when it's created, and can't be read again; a webhook has an expiry.
  - Automation records each request's body and headers as the job's input, so a request must carry no credential.
  - Webhooks stop working when the account's local authentication is turned off ([disable local authentication](https://learn.microsoft.com/azure/automation/disable-local-authentication)).
  - A runbook gets a user-assigned identity's token from the sandbox's identity endpoint, with no Az module ([user-assigned identity](https://learn.microsoft.com/azure/automation/add-user-assigned-identity)).
- **Run Command under load (Phase 25a, 2026-10-23):** on a CPU-saturated `sqlvm01`, one Run Command stayed `Pending` for 654 seconds, and deletes took more than 10 minutes. Managed Run Command can run asynchronously: Azure returns once it accepts the script ([managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)).
- **This tenant's policy (read-only checks, 2026-10-23):**
  - All 110 definitions in the 8 assignments that apply to the subscription were read. The only one that names Automation is "Automation account variables should be encrypted" (Audit), and the control creates no variables, so the Automation account and its webhook can stay public.
  - A tenant policy for Key Vaults (one that excludes resources a network security perimeter covers) is a Modify that sets `publicNetworkAccess` to `Disabled` on every vault, unless it's `SecuredByPerimeter` or carries the policy's exclusion tag on the vault or its group. Every new vault is private here.
- **A Fabric notebook reaches a private vault only through a managed private endpoint:**
  - Fabric isn't one of Key Vault's trusted services ([trusted services](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints#trusted-services)), and a network security perimeter can't admit Fabric's shared compute.
  - Azure Key Vault is a supported target of a managed private endpoint ([create managed private endpoints](https://learn.microsoft.com/fabric/security/security-managed-private-endpoints-create)).
  - **Network isolation in Fabric is per workspace.** A managed private endpoint creates a managed virtual network for the whole workspace, which turns off starter pools, so every Spark notebook in that workspace starts in 3 to 5 minutes ([managed virtual networks](https://learn.microsoft.com/fabric/security/security-managed-vnets-fabric-overview)). A folder can't have its own network.
  - No separate charge is documented, and the Azure Retail Prices API has no Fabric meter for managed private endpoints or managed virtual networks (203 Fabric meters in West US 3, checked 2026-10-23). Sessions use the capacity's units as usual.
  - Notebooks are blocked from public endpoints only when outbound access protection is on ([outbound access protection](https://learn.microsoft.com/fabric/security/workspace-outbound-access-protection-data-engineering)). It's off by default.
- **Fabric's Folders API** (Create Folder, and `folderId` on Create Item) is documented, as a preview ([Folders - Create Folder](https://learn.microsoft.com/rest/api/fabric/core/folders/create-folder)). The workspace, network communication policy, managed private endpoint, and item APIs are generally available.
- **The demo's subscription is shared:** it holds five more VMs that belong to other projects, plus AKS and Databricks resources.

## Decision drivers

1. It runs only when the presenter runs it, and every run has its own stop, independent of the notebook.
2. Least privilege: Contributor for everything but the one custom role and its three assignments, which need an Owner once ([ADR 0008](0008-identity-rbac-abac.md)).
3. Documented interfaces only, each with its Learn page.
4. The webhook URL is a secret everywhere: never printed, logged, returned, or committed.
5. A fast notebook start where the tenant allows a public vault; policy compliance where it doesn't. Never a governance exception by the script.
6. No hard-coded prices ([ADR 0016](0016-cost-profiles.md)).

## Considered options

| Option | How | Outcome |
|---|---|---|
| K1 | A private vault, and the notebook in a new "DBHub Control" workspace on the same capacity with a managed private endpoint to it | Chosen where a policy makes vaults private |
| K2 | The vault with the policy's exclusion tag, and the notebook in the shared workspace | Rejected: a governance exception. The script never adds the tag |
| K3 | A managed virtual network on the shared workspace | Rejected: every notebook in it would start in 3 to 5 minutes |
| K4 | No vault: the URL pasted into a masked input each session | Rejected: the URL handled by hand |
| Public | A public vault with Microsoft Entra RBAC per user, and the notebook in a folder of the existing workspace | Chosen where no policy makes vaults private |
| Role at subscription | The custom role once at `/subscriptions/<subscriptionId>` | Rejected: the identity could start, deallocate, and run commands as SYSTEM on every VM of the shared subscription |
| Stop through Run Command | End the sessions inside the VMs | Rejected for the stop path: Run Command waited more than 10 minutes under load |

## Decision

### The control

It's optional and off by default (`control.enabled`; [configuration](../../config/environment.schema.json)). `scripts/setup-activity-control.ps1` sets it up with Contributor, and an Owner runs `-GrantRole` once. Everything lives in `rg-<prefix>-control`, which `destroy.ps1` keeps ([ADR 0002](0002-resource-group-topology.md)):

| Resource | Settings |
|---|---|
| `id-<prefix>-automation` | User-assigned managed identity; the runbooks' only identity |
| `aa-<prefix>-control` | Automation account, Basic; public network access on, and local authentication on, because webhooks need it; no system-assigned identity |
| `DbHub-Control`, `DbHub-Stop` | Windows PowerShell 5.1 runbooks: `automation/runbooks/` with the settings and the shared code baked in at publish |
| `dbhub-activity-<yyyyMMddHHmm>` | The webhook for `DbHub-Control`; expires after `control.webhookExpiryDays` (90 by default, 15 to 365) |
| `kv-<prefix>-ctl-<suffix>` | Key Vault, Standard, Azure RBAC, 7-day soft delete, purge protection off so that `-Remove` can purge it, public network access by the mode below, no diagnostic settings |
| `dbhub-activity-webhook` | The vault's one secret: the webhook URL, expiring with the webhook |
| `dbhub-autostop` | One-time schedule per run, linked to `DbHub-Stop -Scope All` |
| `dbhub-t4-safety-stop` | Daily schedule, linked to `DbHub-Stop -Scope T4` |

The resources carry `component` = `activity-control` and the demo's `solution`, `purpose`, `owner`, and `costCenter` tags, without `environment` or `deploymentId`, so `destroy.ps1`'s residual check never matches them. `infra/control/control.bicep` deploys the identity, the account, and the vault; `infra/control/webhook.bicep` deploys the webhook and its secret.

### The vault's network mode: `control.vaultNetworkMode` (owner, 2026-10-26)

- **`auto`** (the default) reads the tenant's policy assignments with the same inventory as preflight's `PREFLIGHT.POLICY.*` checks. A rule forces a private vault when it modifies `publicNetworkAccess` on vaults to `Disabled` (or to a value it can't resolve), or denies a vault with public access. `auto` picks private when such a rule applies, or when the assignments can't all be read (a Warning: the private path works everywhere); public otherwise.
- **`public` and `private`** force a path. `public` where a rule would make the vault private is a **Fail**, and nothing is created. The result names the policy and its exclusion tag; the script never adds the tag, because opting out of a network control is a governance decision.
- **The public path:** a public vault, where access is granted per user through Entra roles (A3), and the notebook in the folder `control.fabricFolderName` ("DBHub Control") of the existing workspace, so its sessions start fast on the starter pool. The folder comes from Folders - Create Folder, a documented preview API; when that call fails, the notebook goes in the workspace's root with a Warning, and nothing depends on the folder.
- **The private path (K1):** a vault with public network access `Disabled`; the workspace `control.fabricWorkspaceName` ("DBHub Control") on the existing workspace's capacity, from Workspaces - Create Workspace; a managed private endpoint `mpe-<vault>` from it to the vault, from Create Workspace Managed Private Endpoint (target subresource `vault`); that endpoint's pending connection approved on the vault through Azure Resource Manager ([private endpoint connections](https://learn.microsoft.com/rest/api/keyvault/keyvault/private-endpoint-connections/put)), and only the one whose request message names this ADR; and the notebook in that workspace. Outbound access protection stays off: setup reads it ([Get Network Communication Policy](https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-network-communication-policy)) and reports a Fail if someone turned it on, without changing it.
- **The capacity** is never resumed, paused, or scaled. When it isn't usable, setup creates nothing in Fabric and reports Manual action required.

### The webhook's input and the runbooks

- **The body** is a JSON object of at most 4,096 bytes, and nothing else. Unknown fields, other values, free text, and anything that isn't a JSON object are refused:
  - `{"action": "run", "activities": [{"target": "T1", "scenario": "blocking-chain", "intensity": 5, "concurrency": 4}], "durationMinutes": 20}`: target-scenario pairs, at most one per target, because a target's activity profile holds one incident at a time. `scenario` is `baseline` or a catalog scenario that runs on that target (`scenarios/<id>/scenario.json`, `targets.applicable`; `healthy-baseline` runs as the baseline). `intensity` (1 to 10) and `concurrency` (1 to the scenario's maximum, incidents only) are optional. `durationMinutes` is 5 to 120.
  - `{"action": "stop"}`: Stop now.
  - `{"action": "reset", "targets": ["T1"]}`: the runner's reset; without `targets`, every target whose VM runs.
  - `requestedBy` is optional: 1 to 64 letters, digits, or `. _ @ / -`. It's recorded, never trusted.
- **The targets** are T1, T2, and T3, and T4 once the catalog lists it (Phase 24). T1's runner on `sqlvm01` drives T1, T3, and T4; `archost01` relays T2 into its guest.
- **`run`:**
  1. It refuses while a run is active: another `DbHub-Control` job that hasn't ended (of two that started together, the older goes on), or a pending auto-stop whose run hasn't ended yet. Anything it can't read counts as active.
  2. Each activity runs the requested minutes, capped at its scenario's maximum (120 minutes for the baseline) and so that it ends 2 minutes before the VMs' next auto-shutdown; with less than 5 minutes left, the run is refused.
  3. Before it starts anything, it creates `dbhub-autostop` at the run's end plus 10 minutes.
  4. It starts what's stopped (the VMs, and T4); T3 resumes when the runner connects. It restarts T1's monitoring plugin when the SQL IaaS Agent extension reports it isn't running, as `start-demo.ps1` does.
  5. It sets each target's activity profile through one asynchronous managed Run Command per VM: the module's workload-control template (`Get-DemoWorkloadControlTemplate`) once per target, so the VM-side request is exactly what `demo-control.ps1` sends. Each profile has its duration and the next shutdown as its end, so it stops by itself even if nothing else arrives. On `archost01` the script first waits, at most 12 minutes, for the guest's heartbeat.
  6. It exits. If nothing could be dispatched, it stops everything again at once.
- **`stop`** removes the auto-stop, deallocates both VMs, and stops T4, through Azure Resource Manager only: **the stop path never uses Run Command.** Deallocation ends every session on T1 and T2 (the T2 guest shuts down through the host's automatic stop action), T3's sessions end with T1's runner, and T3 auto-pauses after its delay. The stored profiles end at their own end; the profile host's leftover-run cleanup ends what a stopped run left when the VMs start again.
- **`reset`** sends the runner's reset to the requested targets whose VM runs; it starts nothing.
- **No environment:** when the demo resource group doesn't exist, or the identity can't read it (A1 missing after a redeploy), the runbook logs that and exits cleanly, with the `-GrantRole` hint.
- **The output** is the job's log and one result line, `DBHUB-CONTROL <json>` or `DBHUB-STOP <json>`. Nothing in it is secret: the runbook never sees the webhook URL, and a token lives only in one job's memory.

### Stop layers

Each layer stops the activity by itself:

1. Every scenario's hard maximum duration ([ADR 0010](0010-workload-generator-technology.md)), and each profile's end.
2. The per-run auto-stop: `DbHub-Stop -Scope All` at the run's end plus 10 minutes does exactly what Stop now does.
3. **Stop now** in the notebook; `stop-demo.ps1` locally, which also removes a pending auto-stop (`STOP.CONTROL.AUTOSTOP`), so it can't deallocate a later session's VMs. `start-demo.ps1` cancels a pending auto-stop too, before the VMs start, because a local session takes over from the run: a **Warning** (`START.CONTROL.AUTOSTOP`) says the VMs now run until `stop-demo.ps1` or the nightly auto-shutdown, at its time. When the auto-stop can't be cancelled, the start carries on and the Warning gives the pending stop's time and how to cancel it (delete the schedule `dbhub-autostop` in the portal, or run `start-demo.ps1` again). An auto-stop whose time has passed isn't cancelled, because removing a schedule that has fired doesn't stop its job. Instead, `start-demo.ps1` waits before anything starts: `DbHub-Stop` removes its schedule first and then deallocates the VMs, so while one of its jobs is queued or running (the runbooks' active statuses; the REST API calls a queued job New or Activating: [Job - List By Automation Account](https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account)), the start waits up to 10 minutes for it to finish, polling every 30 seconds (`START.CONTROL.STOPJOB`). When the job finishes, the start goes on normally (**Pass**, with an Info line); when it's still running after 10 minutes, or the jobs can't be read, a **Warning** says it may deallocate the VMs, and the start carries on. Nothing ever stops the job. Layer 4 still bounds the session.
4. The VMs' nightly auto-shutdown, T3's serverless auto-pause, and the **T4 daily safety stop**: `DbHub-Stop -Scope T4` at `control.t4SafetyStopTime`, or 15 minutes after the auto-shutdown, in the auto-shutdown's time zone. It stops T4 only when it's running, because a stopped flexible server starts itself after 7 days ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)); it never starts anything.

### The role: DbHub Demo Activity Operator

One custom role, assignable only in the configured subscription, with exactly these actions (owner-approved, 2026-10-26; they don't change without the owner):

- `Microsoft.Resources/subscriptions/resourceGroups/read`
- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/instanceView/read`
- `Microsoft.Compute/virtualMachines/start/action`
- `Microsoft.Compute/virtualMachines/deallocate/action`
- `Microsoft.Compute/virtualMachines/extensions/read`
- `Microsoft.Compute/virtualMachines/runCommands/read`
- `Microsoft.Compute/virtualMachines/runCommands/write`
- `Microsoft.Compute/virtualMachines/runCommands/delete`
- `Microsoft.Sql/servers/databases/read`
- `Microsoft.DBforPostgreSQL/flexibleServers/read`
- `Microsoft.DBforPostgreSQL/flexibleServers/start/action`
- `Microsoft.DBforPostgreSQL/flexibleServers/stop/action`
- `Microsoft.Automation/automationAccounts/read`
- `Microsoft.Automation/automationAccounts/runbooks/read`
- `Microsoft.Automation/automationAccounts/jobs/read`
- `Microsoft.Automation/automationAccounts/schedules/read`
- `Microsoft.Automation/automationAccounts/schedules/write`
- `Microsoft.Automation/automationAccounts/schedules/delete`
- `Microsoft.Automation/automationAccounts/jobSchedules/read`
- `Microsoft.Automation/automationAccounts/jobSchedules/write`
- `Microsoft.Automation/automationAccounts/jobSchedules/delete`

It has no `NotActions` and no data actions. It can't create or delete a VM, disk, network, or database; it has no action Run Command, and no Key Vault, Fabric, or role-assignment permission. Every name is from the Azure permissions reference: [Compute](https://learn.microsoft.com/azure/role-based-access-control/permissions/compute), [Databases](https://learn.microsoft.com/azure/role-based-access-control/permissions/databases), [Management and governance](https://learn.microsoft.com/azure/role-based-access-control/permissions/management-and-governance), and [General](https://learn.microsoft.com/azure/role-based-access-control/permissions/general). The runbooks poll resources rather than asynchronous operation URLs, so every call stays within the scopes below. `tests/unit/DbHubDemo.ActivityControl.Tests.ps1` fails if the module's list and this one differ.

### The assignments A1-A3

| # | Role | Principal | Scope | Lifetime |
|---|---|---|---|---|
| A1 | DbHub Demo Activity Operator | `id-<prefix>-automation` (ServicePrincipal) | `/subscriptions/<subscriptionId>/resourceGroups/rg-<prefix>-<environment>` | Deleted with the group by `destroy.ps1`. After a redeploy, `deploy.ps1` grants it again when `assignRoles` and `control.enabled` are both true |
| A2 | DbHub Demo Activity Operator | `id-<prefix>-automation` (ServicePrincipal) | `aa-<prefix>-control` | Persistent |
| A3 | Key Vault Secrets User ([built-in](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user)) | The Owner who runs `-GrantRole`, and `control.notebookUserObjectIds` | The one secret `dbhub-activity-webhook` | Persistent |

- **Only `setup-activity-control.ps1 -GrantRole`**, run by an Owner who signed in with multifactor authentication, creates the role and assigns A1-A3 ([create a role definition](https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update), [create a role assignment](https://learn.microsoft.com/rest/api/authorization/role-assignments/create)). It shows the identity's object ID before it assigns anything, and `-WhatIf` lists what it would do.
- **A1's lifecycle (approved 2026-10-26):** after the Infrastructure stage, `deploy.ps1` calls the same function as `-GrantRole` for A1 only, when `assignRoles` and `control.enabled` are true. Otherwise, or when that grant fails (no Owner rights, a sign-in that needs multifactor authentication, the role definition missing), it reports **Manual action required** with the exact `-GrantRole` command, and `DEPLOY.SUMMARY` lists it. `validate.ps1` reports a missing A1 the same way (`CONTROL.ROLE.A1`), and the Security area accepts the role at exactly the demo group.
- **The secret is written through Azure Resource Manager:** `Microsoft.KeyVault/vaults/secrets/write` is a control-plane action, and a vault's firewall applies only to its data plane, so setup writes the URL into a private vault with Contributor rights, and nobody needs Key Vault Secrets Officer.

### The webhook's secrecy and rotation

- Setup gets the URL from Webhook - Generate Uri ([generate URI](https://learn.microsoft.com/rest/api/automation/webhook/generate-uri)), registers it for redaction, and passes it to `infra/control/webhook.bicep` only as a secure parameter in a file in a private directory, which is deleted afterwards. A secure parameter's value isn't saved in the deployment history ([secure parameters](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameters#secure-parameters)), and the template has no output.
- The notebook reads the URL from the vault for each request (`notebookutils.credentials.getSecret`), posts the request, and forgets it. It prints the HTTP status and the job ID only; a failed request prints its error's type, never its text, which can hold the URL.
- The module's redaction rule `automation-webhook` and the gitleaks rule `azure-automation-webhook` catch the URL's shape in logs and in Git.
- **Rotation:** `-RotateWebhook` creates a new webhook, writes its URL as a new secret version, then deletes the control's older webhooks. `status.ps1` and `validate.ps1` warn 14 days before the expiry; an expired webhook is Manual action required.

### The notebook

`fabric/control/NB_DatabaseHub_Control.ipynb`, imported as `NB_DatabaseHub_Control` with its parameters filled (the vault URL, the demo's names, and the runbook's catalog). It sends nothing unless `CONFIRM = True`, and Stop now and Reset need their own switch too. Its live view queries the telemetry endpoint with its `kusto` token, with the same KQL as `scripts/modules/DbHubDemo/Kql/Live.*.kql`. It has no default lakehouse.

### Removal

`setup-activity-control.ps1 -Remove` (with `-WhatIf` first) deletes, in order: the Fabric notebook, its folder when empty, and the control workspace with its endpoint; A1-A3 and the custom role (an Owner); then the Automation account (with its runbooks, schedules, and webhook), the identity, and the vault, which it purges. It deletes `rg-<prefix>-control` only when nothing else is left in it, because the group may also hold the GitHub OIDC identity ([ADR 0002](0002-resource-group-topology.md)).

## Consequences

- **Easier:** a presenter starts a bounded, self-stopping run from Fabric with no local tools, and watches it live in the same notebook.
- **Harder:** an Owner is needed once, and again for A1 after each redeploy unless `assignRoles` is true. In tenants that make vaults private, the control notebook lives in a second workspace whose sessions take 3 to 5 minutes to start. The webhook needs a rotation every 90 days by default.
- **Accepted risks:**
  - Whoever has the webhook URL can start a bounded run, within the allow-lists and the caps, and only one at a time. The URL lives only in the vault, and A3 is per user.
  - The vault has no diagnostic settings, so reads of its secret aren't logged ([Key Vault logging](https://learn.microsoft.com/azure/key-vault/general/logging)); Automation's job history still shows every run.
  - Folders - Create Folder is a preview API; the root fallback keeps the control working without it.
  - Run Command latency under load means the activity can start several minutes after the request (one Run Command waited 654 seconds on a saturated `sqlvm01` in Phase 25a), and telemetry shows it 3 to 15 minutes after that.
  - The identity can run commands as SYSTEM on the demo's two VMs: A1 is limited to the demo group, and the runbooks validate everything they send.

## Validation

- **Static (Phase 25c):** `tests/unit/Automation.Runbooks.Tests.ps1` (request validation, run planning and caps, refusal while active, the stop path without Run Command, dispatch, and the same validation in Windows PowerShell 5.1), `tests/unit/DbHubDemo.ActivityControl.Tests.ps1` (names, the role's exact actions against this ADR, A1-A3 scopes, the vault modes, `-WhatIf`, the webhook's secrecy, `-Remove`, `deploy.ps1`'s A1 re-grant, validation, and status), `tests/unit/Fabric.ControlNotebook.Tests.ps1` (the notebook's form, its KQL, its requests checked by the runbook's validation, and that it never prints the URL), the cost estimate's block, and the gitleaks rule. Both templates build and lint in `./tests/Invoke-StaticValidation.ps1`.
- **Live (Phase 25d, 2026-10-27, with the capacity Active):** `setup-activity-control.ps1 -WhatIf`, then setup in 521 seconds: `auto` resolved to the private path, with the "DBHub Control" workspace and its approved managed private endpoint, and the daily T4 safety stop scheduled. The owner's `-GrantRole` created the role with exactly the 22 actions above, and A1-A3, in 79 seconds, with no further challenge. Requests from the notebook ran through the Fabric job API: each notebook run started in 107 to 166 seconds, its runbook 3 to 4 minutes after the request, and the activity within 2 minutes after that, and the scenarios' waits showed in the telemetry. A second request was refused while a run was active, both while its job ran and while its auto-stop was pending. **Stop now** removed the auto-stop, deallocated the VM, and stopped T4; an auto-stop deallocated the VM on its own; and `start-demo.ps1` cancelled a pending auto-stop with its **Warning**. Fixed live: T4's start and stop through the runbooks (a POST now always has a JSON body), a run no longer waits for a T4 that can't start, and a second run of setup keeps the safety stop linked. Not proven live: the safety stop's scheduled run, the public-vault path, `-RotateWebhook`, and `-Remove` ([limitations](../limitations.md)).

## Sources

Checked 2026-10-23 and 2026-10-26.

- Azure Automation: [webhooks](https://learn.microsoft.com/azure/automation/automation-webhooks), [user-assigned identity](https://learn.microsoft.com/azure/automation/add-user-assigned-identity), [disable local authentication](https://learn.microsoft.com/azure/automation/disable-local-authentication), [schedules](https://learn.microsoft.com/azure/automation/shared-resources/schedules), REST: [Runbook - Create Or Update](https://learn.microsoft.com/rest/api/automation/runbook/create-or-update), [Runbook Draft - Replace Content](https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content), [Runbook - Publish](https://learn.microsoft.com/rest/api/automation/runbook/publish), [Schedule - Create Or Update](https://learn.microsoft.com/rest/api/automation/schedule/create-or-update), [Job Schedule - Create](https://learn.microsoft.com/rest/api/automation/job-schedule/create), [Webhook - Generate Uri](https://learn.microsoft.com/rest/api/automation/webhook/generate-uri), and [schedule time zones](https://learn.microsoft.com/powershell/module/az.automation/new-azautomationschedule)
- Compute and databases: [managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed), [stop a PostgreSQL flexible server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)
- Roles: [permissions reference](https://learn.microsoft.com/azure/role-based-access-control/permissions/compute), [Key Vault Secrets User](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user), [role definitions](https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update), [role assignments](https://learn.microsoft.com/rest/api/authorization/role-assignments/create)
- Key Vault: [trusted services](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints#trusted-services), [soft delete](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview), [recovery and purge](https://learn.microsoft.com/azure/key-vault/general/key-vault-recovery), [logging](https://learn.microsoft.com/azure/key-vault/general/logging), [private endpoint connections](https://learn.microsoft.com/rest/api/keyvault/keyvault/private-endpoint-connections/put)
- Fabric: [managed virtual networks](https://learn.microsoft.com/fabric/security/security-managed-vnets-fabric-overview), [managed private endpoints](https://learn.microsoft.com/fabric/security/security-managed-private-endpoints-create), [outbound access protection](https://learn.microsoft.com/fabric/security/workspace-outbound-access-protection-data-engineering), [notebookutils credentials](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials), REST: [Folders - Create Folder](https://learn.microsoft.com/rest/api/fabric/core/folders/create-folder) (preview), [Workspaces - Create Workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace), [Get Network Communication Policy](https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-network-communication-policy), [Create Workspace Managed Private Endpoint](https://learn.microsoft.com/rest/api/fabric/core/managed-private-endpoints/create-workspace-managed-private-endpoint), [Items - Create Item](https://learn.microsoft.com/rest/api/fabric/core/items/create-item), and the Delete calls `-Remove` uses ([item](https://learn.microsoft.com/rest/api/fabric/core/items/delete-item), [folder](https://learn.microsoft.com/rest/api/fabric/core/folders/delete-folder), [managed private endpoint](https://learn.microsoft.com/rest/api/fabric/core/managed-private-endpoints/delete-workspace-managed-private-endpoint), [workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/delete-workspace))
- Azure Resource Manager: [secure parameters](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameters#secure-parameters)
