# ADR 0012: Validation model and status taxonomy

- **Status:** Accepted
- **Date:** 2026-10-19
- **Decision source:** Engineering (brief "Validation and testing"; approved plan §4.11, §9.2 stage 6)
- **Related:** [ADR 0006](0006-sql-editions-and-licensing.md), [ADR 0011](0011-control-surface-priority.md), [automation support matrix](../automation-support-matrix.md)

## Context

- The brief defines six statuses: **Pass**, **Fail**, **Warning**, **Manual action required**, **Not supported**, and **Not selected**.
- Success means every selected capability passes functional validation or is explicitly reported as manual. A successful ARM deployment alone isn't success.
- Several capabilities are previews whose APIs, schemas, and docs can change: Database Hub, the telemetry endpoint, SQL VM monitoring, and the Arc monitoring setting.
- Database Hub has no public API or ARM resource. What Hub shows is validated indirectly:
  - **Estate:** Azure Resource Graph, which is Hub's own inventory source.
  - **Performance:** the documented telemetry REST endpoint.
- The evaluation-only fallback must be labeled everywhere it appears (Q1b).

## Decision

### Result record

Every check emits one JSON record. The schema lives in `scripts/modules/DbHubDemo/schemas/validation-result.schema.json`.

| Field | Meaning |
|---|---|
| `checkId` | Stable ID, for example `T2.ARC.CONNECTED` |
| `area` | `static`, `preflight`, `infra`, `t1`, `t2`, `t3`, `hub`, `workload`, `teardown`, or `fabric`; Phase 14 adds `cost` and `security` |
| `target` | `T1`, `T2`, `T3`, `subscription`, `tenant`, `fabric`, `github`, or `repo` |
| `status` | One of the six statuses |
| `message` | One sentence a presenter can read aloud |
| `evidence` | Non-secret facts, for example extension version or row counts. Passed through the redacting logger. |
| `remediation` | Exact next step, including the command or portal path |
| `docUrl` | Official doc for the requirement |
| `evaluationOnly` | `true` when the evaluation-only fallback is in use |
| `timestamp` | UTC |

### Status rules

- **Pass:** functionally verified, never inferred from deployment success.
- **Fail:** a selected capability is broken, a prerequisite is missing with no documented workaround, or the light-use monthly cost estimate is above the hard monthly ceiling (`monthlyCeilingUsd`, ADR 0016).
- **Warning:** works, but with risk: a demo-day session estimate above the session ceiling, evaluation OS expiring, Arc disconnected for more than 21 days, Bastion still present, or a preview doc changed since it was pinned.
- **Manual action required:** a documented manual step is pending, for example the `PaygWizard` step or prerequisite P4. Always includes exact steps.
- **Not supported:** the docs say the capability doesn't apply, for example T2 Performance in `Developer` mode.
- **Not selected:** the operator turned the capability off.

### Exit codes (`validate.ps1`, `preflight.ps1`, `deploy.ps1`)

- `0`: no **Fail**. Warnings and manual items are printed in a summary.
- `1`: at least one **Fail**.
- `2`: no Fail but at least one **Manual action required**, when `-TreatManualAsError` is set (used by CI and scheduled warm-ups).
- *(As built, Phase 14.)* `validate.ps1` returns `1` in that last case too: its contract with the `validate.yml` workflow is "1 for a Fail, or for Manual action required with `-TreatManualAsError`; 0 otherwise". `Get-DemoExitCode` and the other scripts keep `2`.

### Output

- A console table.
- JSON lines in `out/validation-<timestamp>.jsonl` (ignored by Git). *(As built, Phase 14: `validate.ps1` writes `out/validate.jsonl` unless `-OutputPath` names another file.)*
- A GitHub job summary in Actions.
- Rows in the Delta table `validation_results` when written from the notebook.

### Preview tolerance

- Telemetry and Arc checks accept added fields and unknown counter names.
- A check reports **Warning**, not **Fail**, when a preview response shape changes but the essential signal is present.
- `config/versions.json` records the doc date each check was written against.

### Evaluation-only labeling

When `t2Mode = EvaluationOnlyAzureVm`, every T2 record has `evaluationOnly: true`, and its message starts with "EVALUATION ONLY:".

### Check catalog

The catalog is a data file, `tests/checks.catalog.json`, mapping each capability in the [automation support matrix](../automation-support-matrix.md) to its check IDs. *(As built, Phase 14: no separate data file. The catalog is the table in [Phase 14: the live catalog as built](#phase-14-the-live-catalog-as-built-2026-10-21) and the code that runs it, so the two can't drift apart.)* It covers:

- **Static:** Bicep build and lint, PSRule, PSScriptAnalyzer, JSON schema, gitleaks, notebook outputs.
- **Infrastructure:** provider registration, VM and extension health, nested virtualization, guest health.
- **T1:** SQL IaaS Agent status and `DatabaseMonitorArcPlugin` status `MetricsUploadStatus OK`.
- **T2:** Arc machine **Connected**; SQL extension version 1.1.2504.99 or later; edition, license type, and monitoring of the `sqlServerInstance`.
- **T3:** Entra-only authentication, network mode, and the extended property.
- **Hub:** Resource Graph visibility, and telemetry rows per target through the telemetry REST API.
- **Workload:** start, stop, reset, and maximum duration.
- **Teardown:** zero residual resources, including Arc.

### Preflight policy checks (Phase 5, 2026-10-20)

Preflight reads the Azure Policy assignments that apply to the subscription, read-only (`Get-DemoPolicyConstraint`). It expands policy sets, resolves each rule's effect through the assignment's parameters, the set member's parameters, the set's defaults, and the definition's defaults, and keeps rules with deny, modify, deployIfNotExists, append, or denyAction effects. Assignments with enforcement mode `DoNotEnforce` are listed and skipped. A read failure is a **Warning**, never a **Fail**. `-SkipPolicyInventory` skips it.

| Check | What it reports | Status |
|---|---|---|
| `PREFLIGHT.POLICY.INVENTORY` | Assignments read, rules kept, rules that don't concern the demo, `DoNotEnforce` assignments, and anything that couldn't be read | Pass, or Warning when something couldn't be read |
| `PREFLIGHT.POLICY.SQLPUBLIC` | A policy that turns off or denies public network access on SQL servers, and the effective `networkMode` (evidence `effectiveNetworkMode`) | Pass; Fail for an explicit `public`; Warning when the inventory is incomplete |
| `PREFLIGHT.POLICY.SQLENTRAONLY` | A deny on SQL servers without Entra-only authentication. T3 is Entra-only by design (ADR 0009). | Pass |
| `PREFLIGHT.POLICY.VMSIZE` | The profile's VM sizes against VM size deny rules, ignoring case, with unblocked profiles as alternatives | Pass, or Fail |
| `PREFLIGHT.POLICY.RESOURCETYPES` | Every resource type the demo creates, including those created at run time, against type deny rules | Pass, or Fail |
| `PREFLIGHT.POLICY.DEFENDER` | Policies that deploy Defender plans; the cost estimate includes them | Warning |
| `PREFLIGHT.POLICY.EXTENSIONS` | Policies that add VM or Arc machine extensions, and where; bootstraps must retry on Conflict | Warning |
| `PREFLIGHT.POLICY.PUBLICIP` | Append or modify rules on public IP addresses, such as IP tags on Bastion's public IP | Warning |
| `PREFLIGHT.POLICY.STORAGE` | Modify rules on storage accounts; the deployment creates none | Pass |
| `PREFLIGHT.POLICY.MFA` | Mandatory MFA for user writes and deletes; workload identities aren't affected | Pass |
| `PREFLIGHT.POLICY.OTHER` | Any other kept rule that can apply to a resource type the demo creates, so nothing is silently ignored | Warning |

It doesn't read policy exemptions or assignments scoped to resource groups, and it can't evaluate every condition; the what-if check (`PREFLIGHT.POLICY.WHATIF`) remains the backstop for denials.

### Preflight T3 free-offer check (Phase 5, 2026-10-20)

| Check | What it reports | Status |
|---|---|---|
| `PREFLIGHT.T3.FREEOFFER` | Whether T3 can use the Azure SQL Database free offer: other free databases in the subscription (at most 10, all in one region) and whether the demo's database already exists. The effective setting is in the evidence (`useFreeLimit`) for later stages (ADR 0016). | Pass; Warning and fallback to regular serverless when the offer isn't available; Warning when not every server could be read (T3 tries the offer, and the deployment falls back if Azure rejects it); Not selected when `t3FreeOffer` is `off` |

### Phase 9 Database Hub checks (2026-10-20)

Run by `scripts/configure-fabric.ps1` (`Invoke-DemoHubReadiness`) after the subscription guard, and available to `validate.ps1`, `deploy.ps1` stage 6, and warm-up. Database Hub has no public API, so every check uses a documented interface: Azure Resource Graph (the Hub's inventory source), the telemetry REST endpoint, Fabric REST, and the Azure CLI. Tokens are registered as secrets when they're issued and are sent only as SecureString bearer tokens (`-Authentication Bearer`). Fabric calls go through Phase 12's `Get-DemoFabricToken` and `Invoke-DemoFabricRequest`, which refuse any host but the Fabric API. KQL lives in `scripts/modules/DbHubDemo/Kql/` and follows the telemetry doc's rules: filter on `SampleTimeUTC` first, take deltas of cumulative counters, and branch on `CounterType`.

| Check | What it reports | Status |
|---|---|---|
| `FABRIC.P4.HUBSETTING` | The tenant setting "Users can access the Database hub (preview)" (P4), read through the Fabric admin API only with `-FabricAdmin` and matched by title until its `settingName` is recorded | Pass when enabled for the organization; Warning when enabled only for security groups; Manual action required when disabled, not found, not readable, without a Fabric token, without the Phase 12 Fabric REST helpers, or without `-FabricAdmin` |
| `FABRIC.P5.WORKSPACE` | Contributor or higher on `fabric.workspaceId` (P5), from Get Workspace and List Workspaces filtered by role | Pass; Manual action required for Viewer only, no access, no Fabric token, or without the Phase 12 Fabric REST helpers; Not selected without a workspace |
| `FABRIC.P5.CAPACITY` | The workspace's capacity: ID, assignment progress, region, and, when visible, SKU and state | Pass for an Active F SKU; Warning while the assignment is in progress or when the capacity isn't visible; Manual action required with no capacity, a failed assignment, a paused capacity, or an unverified SKU such as a Trial |
| `HUB.ESTATE.T1`, `HUB.ESTATE.T2`, `HUB.ESTATE.T3` | Each target in Azure Resource Graph: T1's SQL virtual machine resource, T2's Arc SQL Server instance, T3's database. Seeing it on the Estate page stays manual. | Pass; Fail when missing; for T2, Manual action required while the `PaygWizard` step is pending and Warning while the extension hasn't reported the instance; Not selected |
| `TELEMETRY.T1`, `TELEMETRY.T2`, `TELEMETRY.T3` | Rows per target from the telemetry REST endpoint, keyed by ResourceID: row count, first and newest sample, lag, and with `-Detail` the tables, wait seconds per category, and counters | Pass with rows and a newest sample at most `-FreshMinutes` (15) old; Warning for an older sample or a ResourceID mismatch; Fail without rows, or on HTTP 401 or 403; Manual action required on HTTP 400 or an unexpected response shape (the preview schema may have changed); Not supported for T2 in `Developer` mode; Not selected |
| `T3.READINESS.RESOURCEGRAPH`, `T3.READINESS.PERFPROPERTY`, `T3.READINESS.TELEMETRY`, `T3.READINESS.GATE` | The warm-up gate for a recreated T3 (coordinator decision, 2026-10-20): T3 is in Resource Graph, `MS_EnablePerformanceMonitoringPreview` is set (Phase 8's check, passed in), and fresh telemetry arrives. The gate's evidence has the measured lag from creation to the first sample, and the rows from earlier sessions under the same ResourceID. | The gate is Pass when all three hold and a Warning otherwise, with the lag so far; the parts are Pass, Warning, Fail (telemetry access denied), or Manual action required (no property check supplied) |
| `HUB.PRESENTER.READER`, `HUB.PRESENTER.ARCTELEMETRY` | Reader on the subscription and the Arc telemetry role on the resource group for the presenters in `presenterObjectIds` (P8) | Manual action required with the commands when `assignRoles` is false; Pass when assigned or already held; Fail without assignment rights or when a role isn't found by name; Not selected without presenters or with `-WhatIf`; the Arc role is Not supported in `Developer` mode |
| `FABRIC.NOTEBOOKS.IMPORT` | The notebook import step of `configure-fabric.ps1` when it can't run. When it runs, Phase 12's `Import-DemoFabricNotebook` reports each notebook instead (`FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT`, `FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY`) | Manual action required while the module doesn't include the Phase 12 import functions (import by hand); Not selected without a workspace (`fabric.workspaceId` or `-WorkspaceId`) |

### Phase 14: the live catalog as built (2026-10-21)

`scripts/validate.ps1` runs `Invoke-DemoValidation`. It runs the subscription guard first and stops there if the guard fails, then the selected areas, always in this order. Every area reuses the module's existing checks. Validation changes nothing in the demo: its only writes are Run Commands on running VMs (temporary managed Run Commands for the health read, T3's property query through T1, and the T2 isolation probe, each deleted when it finishes, and an action Run Command for the workload status), and T3's property query resumes a paused serverless database. With the VMs deallocated, it's read-only. To stay strictly read-only while another session runs a VM, leave that VM's target out with `-Target`: on 2026-10-21, a run stopped by hand while someone else had started `archost01` left its `DbHubDemo-HealthRead` Run Command behind (deleted by hand; the next health read would also have deleted it first).

**Contract with the `validate.yml` workflow (agreed with Phase 13):** `./scripts/validate.ps1 [-ConfigPath <path>] [-Area <string[]>] [-Target <string[]>] [-WaitMinutes <int>] [-OutputPath <path>] [-TreatManualAsError]`. Every result goes to `-OutputPath` (default `out/validate.jsonl`) as one JSON line, and a summary table with the count per status is printed. The exit code is `1` for a Fail, or for Manual action required with `-TreatManualAsError`; otherwise `0`. Optional parameters: `-ScanPath` (more files for the secret scan), `-DeploymentId` (for the teardown check after destroy), `-FabricAdmin`, and `-SkipPolicyInventory`.

| Area | Checks | How |
|---|---|---|
| Preflight | `PREFLIGHT.*` | `Invoke-DemoPreflight` with `-SkipProviderRegistration` and `-SkipWhatIf`, so it changes nothing (`PREFLIGHT.POLICY.WHATIF` is Not selected). Its network-mode and free-offer decisions feed the T3 and cost checks. When the Hub area runs, `FABRIC.P4.HUBSETTING` and `FABRIC.P5.*` replace preflight's manual reminders `PREFLIGHT.P4.HUBSETTING` and `PREFLIGHT.P5.WORKSPACE`. |
| Infrastructure | `INFRA.RESOURCEGROUP`, `INFRA.NETWORK`, `INFRA.VM.<vm>`, `INFRA.BOOTSTRAP.LOADER_<vm>`, `INFRA.HEALTH.<vm>`, `INFRA.GUEST.ARCSQL01` | The resource group and its required tags; the four subnets and their NSGs; each selected VM's power state (`az vm get-instance-view`); `Wait-DemoBootstrapLoader` with a 30-second wait; `health.json` through `Get-DemoVmHealth` (its own status, for example Manual action required at the T2 `SqlSetupWizard` step); the nested guest's state from the host's `health.json` |
| T1 | `T1.SQLVM.MONITORING`, `T1.SQLVM.ASSOCIATEDSERVICES` | `Test-DemoSqlVmMonitoring` and `Test-DemoSqlVmAssociatedService` (Phase 7). `T1.SQLVM.ASSOCIATEDSERVICES` reads unified inventory, which doesn't need the VM running: **Pass** when it lists only the database engine; **Warning** while it still lists the image's Analysis Services or Integration Services (T1's `AssociatedServices` bootstrap step stops, disables, and uninstalls them, owner's decision 2026-10-21), when it lists no engine, or when it can't be read |
| T2 | `T2.ARC.*`, `T2.GUEST.ISOLATION` | `Get-DemoArcCheck`; the read-only probe of `Invoke-DemoArcOnboard.ps1 -Action Probe` in a Run Command on the host, judged by the onboarding decision table (ADR 0004) |
| T3 | `T3.EXISTS`, `T3.ENTRAONLY`, `T3.NETWORK`, `T3.DATABASE`, `T3.FREEOFFER`, `T3.PROPERTY` | `Test-DemoT3`. For `networkMode` `auto`, the mode comes from the policy inventory when the Preflight area ran, otherwise from the deployed server's public network access. `T3.PROPERTY` runs its query through T1, which resumes a paused T3. |
| Hub | `FABRIC.P4.HUBSETTING`, `FABRIC.P5.*`, `HUB.ESTATE.*`, `HUB.PRESENTER.*` | `Test-DemoFabricHubSetting`, `Test-DemoFabricWorkspace`, `Test-DemoHubEstate`, and `Set-DemoPresenterAccess`, in what-if mode whenever it would assign a role; a pending assignment is then Manual action required |
| Telemetry | `TELEMETRY.T1`–`T3`, `T3.READINESS.*` | `Test-DemoHubTelemetry` over the 7-day retention window, so a target that stopped hours ago shows its last sample; `Test-DemoT3Readiness` with T3's property check |
| Workload | `WORKLOAD.<target>.COMMAND`, `WORKLOAD.<target>.BOUNDS`, `WORKLOAD.<target>.HOST` | `Invoke-DemoWorkloadCommand ... status --json --runs 5`, then the scenario bounds and the profile host lane from the runner's status (Phase 25b) |
| Cost | `PREFLIGHT.COST.*`, `COST.BUDGET`, `COST.AUTOSHUTDOWN`, `COST.BASTION` | The live-price estimate (reused from the Preflight area when it ran); the budget; the auto-shutdown schedules; Bastion or a public IP still billing |
| Security | `SECURITY.SECRETSCAN.OUTPUT`, `SECURITY.SECRETSCAN.RUNCOMMANDS`, `SECURITY.SECRETSCAN.DEPLOYMENTS`, `SECURITY.RBAC.ROLEASSIGNMENTS`, `SECURITY.SECRETS.KEYVAULT`, `SECURITY.NETWORK.NOPUBLICIP`, `SECURITY.NETWORK.INBOUND` | `Find-DemoSecretLeak` (ADR 0009) over `out/`, the Run Command instance views, and the ARM deployments; role assignments and Key Vaults (ADR 0008); NICs and NSGs (ADR 0007) |
| Teardown | `TEARDOWN.RESIDUAL` | A Resource Graph query (`Kql/ResourceGraph.Residual.kql`) for everything in the demo resource group or tagged for the environment (ADR 0002) |

The checks that are new in Phase 14:

| Check | What it reports | Status |
|---|---|---|
| `INFRA.RESOURCEGROUP` | The demo resource group exists with `solution`, `environment`, `owner`, `purpose`, `costCenter`, `autoShutdown`, `deploymentId`, and `ArcSQLServerExtensionDeployment=PAYG` | Pass; Warning for missing tags; Fail when it doesn't exist or can't be read |
| `INFRA.NETWORK` | `snet-sqlvm`, `snet-archost`, `snet-pe`, and `AzureBastionSubnet`, each with its NSG | Pass or Fail |
| `INFRA.VM.<vm>` | The VM's power state | Pass when running; Warning when deallocated, stopped, or changing state; Fail when missing |
| `INFRA.HEALTH.<vm>` | `health.json` (role, state, step, message) | The status `health.json` reports; Warning when it can't be read |
| `INFRA.GUEST.ARCSQL01` | The nested guest runs on the host, so nested virtualization works | Pass or Warning; Nested mode only |
| `T2.GUEST.ISOLATION` | From inside the guest, IMDS and the wire server are unreachable and names resolve through the host (ADR 0004) | Pass; Fail when the guest reaches IMDS or the wire server; Warning when the guest doesn't answer, DNS fails, or the probe can't run |
| `WORKLOAD.<target>.BOUNDS` | Every running scenario has a deadline within its maximum duration and isn't past it, and an activity profile other than `off` has an end time | Pass; Warning for a late run, a profile without an end time, or output that didn't parse; Fail for a run beyond its maximum |
| `COST.BUDGET` | `budget-<prefix>-<env>` is monthly at `monthlyCeilingUsd` | Pass; Warning for another amount; Fail when missing |
| `COST.AUTOSHUTDOWN` | The DevTest Labs schedules for the selected VMs are enabled at `autoShutdownTime` and `autoShutdownTimeZone` | Pass; Warning for a disabled or different schedule; Fail when missing |
| `COST.BASTION` | No Bastion, no Bastion public IP left by an interrupted delete, and no other unexpected public IP | Pass; Warning, with the delete command |
| `SECURITY.SECRETSCAN.OUTPUT` | `out/` and `-ScanPath`: no redaction-rule match and no value registered in the session, in UTF-8 or UTF-16 text (Windows PowerShell 5.1 and other Windows tools write UTF-16 logs) | Pass; Fail with the redacted findings; Not selected when there's nothing to scan |
| `SECURITY.SECRETSCAN.RUNCOMMANDS` | The Run Command resources on the running VMs, with their instance views (output and error) | Pass; Fail with findings; Warning while a VM is deallocated, because its instance views are empty |
| `SECURITY.SECRETSCAN.DEPLOYMENTS` | The parameters, outputs, errors, and operations of the 25 newest deployments in the resource group and the environment's subscription deployments | Pass; Fail with findings; Warning when some couldn't be read |
| `SECURITY.RBAC.ROLEASSIGNMENTS` | Role assignments at or below the resource group: none, or only Reader, the Arc telemetry role, with `assignRoles` Azure Connected Machine Onboarding, and with the Key Vault opt-in (`keyVault.enabled`, Phase 13) Key Vault Secrets Officer and Key Vault Secrets User on the opt-in vault itself; the evidence says whether the caller can assign roles, which a Contributor-only run can't | Pass or Warning |
| `SECURITY.SECRETS.KEYVAULT` | No Key Vault in the resource group (ADR 0009); with the Key Vault opt-in, only the opt-in vault, with Azure RBAC authorization and soft delete (its firewall, retention, and purge protection in the evidence) | Pass or Warning |
| `SECURITY.NETWORK.NOPUBLICIP` | No network interface has a public IP | Pass or Fail |
| `SECURITY.NETWORK.INBOUND` | No inbound allow from `*`, `Internet`, or `0.0.0.0/0` on the VM and private-endpoint NSGs (the Bastion NSG must allow HTTPS from the internet) | Pass or Fail |
| `TEARDOWN.RESIDUAL` | Deployed: nothing tagged for the environment is outside its resource group, which destroy deletes. Destroyed: nothing of the environment remains, Arc resources included. `rg-<prefix>-control` is kept by design. | Pass; Warning (deployed) or Fail (destroyed) with the resources |
| `VALIDATE.<AREA>`, `VALIDATE.DEPLOYMENT` | An area that stopped with an error (the other areas still run), or deployment checks without a resource group | Fail |

**Stopped resources are expected.** The nightly auto-shutdown deallocates the VMs, so every check that needs a running VM (a Run Command, an extension instance view, or the VM's telemetry) is a **Warning** while the VM is deallocated, with the command to start it, and a Fail only when the VM doesn't exist:

- `T1.SQLVM.MONITORING` reads what a deallocated VM still shows (the feature flag, the identity, the provider) and reports a Warning; a missing flag is still a Fail. Before Phase 14 the empty instance view made it a Fail on extension version `''`.
- A target without telemetry rows is a Warning when its VM is deallocated or T3 is paused or removed, and the manual step that `HUB.ESTATE.<target>` reports when one is pending.
- While T3 is removed between demos (`stop-demo.ps1 -RemoveT3`), every T3 Fail becomes a Warning that says so.
- The T3 readiness gate gets a property check that reports "not checked", not "not set", while T1 is deallocated.

**Live findings that shaped it (2026-10-20 and 2026-10-21):** a policy-driven `MDE.Windows` extension update held a VM's Run Commands for about 10 minutes; Run Commands fail with `OperationNotAllowed` on a deallocated VM; a managed Run Command created again soon after it was deleted can return the previous run's result without running (Phase 7: `Invoke-DemoVmRunCommand` detects it by start time, retries once, then fails closed, which validation reports as a Warning that names that cause instead of an extension update); an interrupted Bastion delete can leave its public IP; T1's unified inventory listed three instances (the engine, SSAS, and SSIS) until Phase 7 removed SSAS and SSIS, and it now lists only the engine; setup's interactive sign-in left sign-in data on the guest (R74: the scripts remove it right after the wizard and verify that none remains, and the secret scan's `jwt` rule finds a token in copied logs, UTF-16 included); T1's telemetry arrives under the Compute VM's ID and T3's under the database's; and **T3 keeps sending telemetry while its serverless database is paused** (newest sample 0.8 minutes old while the database reported `Paused`, 2026-10-21), so a fresh T3 sample doesn't prove the database is awake.

**Read-only plumbing:** `Invoke-DemoAzCli` pins `$WhatIfPreference` to `$false`. Under a caller's `-WhatIf`, the inherited preference had skipped the Azure CLI's stderr redirection and the deletion of its temporary file, so errors read as empty and a file was left in the temp folder (Phase 14 finding).

### Phase 18 presentation checks (2026-10-21)

Run by `scripts/configure-fabric.ps1` and, for P11, by `preflight.ps1` too. They use documented Fabric REST only, with the caller's Fabric token through Phase 12's helpers: Get Workspace, List Capacities, List Items, Create Item, Update Item Definition, Get Item Definition, and the long-running-operation APIs; the tile check reads the telemetry endpoint. The Real-Time Dashboard is checked in three layers: the import, the definition's round trip, and each tile's data. The notebook import keeps its Phase 12 check IDs; it now runs on the same generic `Import-DemoFabricItem`.

| Check | What it reports | Status |
|---|---|---|
| `PREFLIGHT.FABRIC.VIEWERLICENSE` | Optional prerequisite P11: the SKU of the workspace's capacity, from Get Workspace and List Capacities, or from `FABRIC.P5.CAPACITY` when `configure-fabric.ps1` has already read it; and the viewer licensing rule for Power BI content | Pass on F64 or larger and on P capacities; Warning below F64, on A or EM capacities, for a SKU it doesn't recognize (a Trial's SKU string isn't documented), and when the SKU can't be read; Not selected without a workspace. Never Fail, because P11 is optional |
| `FABRIC.IMPORT.RTD_DATABASEHUB_LIVEVIEW` | `configure-fabric.ps1 -ImportDashboard`: the Real-Time Dashboard created or updated by `Import-DemoFabricItem`, with its definition's SHA-256; the item ID goes only to `out/` | Pass; Fail when the workspace's items can't be listed, two items share the name, or the create or update fails; Warning when the long-running operation doesn't finish in time; Not selected with `-WhatIf` (the planned requests are in the evidence) or when skipped at the prompt |
| `FABRIC.READBACK.RTD_DATABASEHUB_LIVEVIEW` | The definition read back with Get Item Definition and compared with what was sent: every page, data source, parameter, query text, and tile; fields that Fabric normalizes, such as the schema version, are listed in the evidence | Pass when everything essential came back; Fail when anything is missing or changed; Warning when the read-back can't complete after a successful import |
| `FABRIC.DASHBOARD.IMPORT` | The dashboard step of `configure-fabric.ps1 -ImportDashboard` when it can't run | Not selected without a workspace or without the configuration file, which names the demo resource group |
| `FABRIC.DASHBOARD.TILE.<PAGE>.<TILE>` | `Test-DemoRealTimeDashboardData`, after a passing import and read-back, alone with `-CheckDashboardData`, or as a deploy step: one tile's KQL, read-only, against the telemetry endpoint for the last 24 hours, with the dashboard's parameters bound as the dashboard binds them and a Kusto token for the configured subscription's account. On an empty tile, a probe of its own source (its table, filters, and window) and the VMs' power states and T3's status | Pass with rows and every column the tile shows; Warning when the tile and its source are empty (the message names the VMs that aren't running right now, which Phase 20's end-to-end run checks again), or when the endpoint was throttled or unavailable after retries; Fail when the source has rows but the tile is empty, a shown column is missing, or the endpoint rejected the query, the token, or the access |
| `FABRIC.DASHBOARD.DATA` | The tile check's summary: the window, the counts, and the targets' states when a tile was empty | The worst tile status; Fail without a validated Azure CLI context (nothing is sent); Not selected under `-WhatIf`, after a failed guard, or when the import or read-back didn't pass |

How Fabric draws a tile isn't checked: no documented API renders one, so the checks cover the definition (the read-back) and the data (the tiles' own queries). A dark theme is **Not supported**: the dashboard schema has no theme property. Database Hub's template wizard (row 34) has no API, so nothing checks it.

### Phase 20: parallel deploy and golden snapshot checks (2026-10-22)

- **A T2 that builds in the background is Manual action required, never Pass:** without a golden snapshot, `deploy.ps1` returns once T1, T3, and Fabric are ready and reports `DEPLOY.T2.BACKGROUND` with how to follow it (`status.ps1`) and continue (`deploy.ps1 -FromStage T2`, after the setup-wizard step in `PaygWizard` mode); the T2 track's own result, `DEPLOY.TRACK.T2`, is Manual action required too. `-WaitForT2` waits for the build instead.
- **`DEPLOY.TIMING`** is evidence, not a verdict: each track's steps, each target's ready time, and the total. Its status is **Pass** only when the clock stopped, that is, when T1, T2, and T3 telemetry, the three Hub Estate checks, T2's Arc SQL instance and monitoring, T1's unified inventory (`T1.SQLVM.ASSOCIATEDSERVICES`), and the Fabric track all passed ([ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md)); otherwise **Warning**. Its evidence records whether the total was within 30 minutes (`withinThirtyMinutes`), so a slow run that finishes is still a Pass with an honest time.
- **`T1.SQLVM.ASSOCIATEDSERVICES`** is a **Fail** in `deploy.ps1`'s validation when unified inventory still lists Analysis Services or Integration Services after up to 10 minutes, because then T1's `AssociatedServices` step didn't converge (live, 2026-10-22); `validate.ps1`, `status.ps1`, and `configure-monitoring.ps1` keep reporting it as a **Warning**.
- **A reused result says so:** a policy inventory reused from the cache keeps its statuses, and every reused result carries `reusedFromUtc` in its evidence, with the inventory's age in `PREFLIGHT.POLICY.INVENTORY`'s message.
- **`GOLDEN.CAPTURE.*`, `GOLDEN.TEST.*`, `STATUS.T2.GOLDEN`, `T2.GOLDEN.SOURCE`, `DESTROY.GOLDEN`, and `DESTROY.GOLDEN.GUARD`** follow the same statuses: a snapshot isn't usable until it's boot-verified, its guest's evaluation is a **Warning** at 30 and 7 days, and a destroy that would lose a setup-wizard step without a verified snapshot is a **Fail** that deletes nothing.

### Phase 25b: the profile host lane (2026-10-26)

After Phase 25a's long program, where `sqlvm01`'s profile host stopped serving T1 without a trace while `status.ps1` still showed T1's profile as active ([ADR 0010](0010-workload-generator-technology.md#phase-25b-the-profile-hosts-lanes-and-supervisor-and-the-bounds-phase-25a-met-2026-10-26)), the host writes a heartbeat (`host-lanes.json`), and the runner's `status` and `profile get --json` turn it into a status for their target, in a `host` node written last so a Run Command's output tail keeps it.

| Check | What it reports | Status |
|---|---|---|
| `WORKLOAD.<target>.HOST` | The lane of the profile host (the `DbHubDemo-Workload` task) that serves the target, from `status --json`: the host's process and heartbeat, and the lane's state, generation, restarts in the last hour and their last reason, last finished poll, current operation, consecutive failures and last error (redacted), and running runs | **Pass** while the lane finishes its polls (also during a bounded reset before a profile), or when the host stopped cleanly and no profile is active. **Warning** while the lane is slow (no finished poll for 60 seconds or 3 polls), hasn't finished a poll for the stall limit (5 minutes; the supervisor then replaces it), is restarting, was restarted in the last hour, or failed its last polls; when the host stopped cleanly while a profile is active, or hasn't started since the machine booted; when it ended without a clean stop, or its heartbeat is stale, while no profile is active; when the heartbeat is missing or unreadable (no host, or a runner older than Phase 25b), or the output has no `host` node; and when the host doesn't serve the target while its profile is active. **Fail** while a profile is active and nothing runs it (the host ended without a clean stop, or its heartbeat is older than 3 heartbeats and at least 60 seconds), and when the lane keeps failing (3 restarts in an hour). **Not selected** when the host doesn't serve the target and its profile is off |

- **`STATUS.PROFILE_<target>`** (`status.ps1`) takes on the lane's Warning or Fail, with the lane's message after the profile's and the remediation; a `Pass` or `Not selected` lane leaves it a Pass. A runner older than Phase 25b has no `host` node, and `status.ps1` then reports the profile as before. It also reads `profile get --json`'s single JSON object when the output has no array of records.
- **The host replaces a stalled lane by itself**, so a Warning normally clears within about 5 minutes; a Fail that stays means restarting the task (`stop-demo.ps1`, then `start-demo.ps1`).

## Consequences

- **Positive:** a presenter can trust a green result. Every manual step is explicit and actionable. Results are machine-readable for the notebooks and CI.
- **Negative:** telemetry-based checks are slow (3–15 minutes of latency) and depend on preview services. Pre-demo validation therefore runs during warm-up.

## Validation

- **Phase 4:** Pester tests for status aggregation, exit codes, schema conformance, and redaction of `evidence`.
- **Phase 14 (static):** Pester tests for the area order and selection, the stopped-VM rule in every area, the T3 removal rule, the telemetry downgrades, the workload bounds, the cost, security, and teardown checks, and the script's contract (`tests/unit/DbHubDemo.Validation.Tests.ps1`). After Phase 7's follow-ups: the T1 area's `T1.SQLVM.ASSOCIATEDSERVICES` (Warning with SSAS and SSIS listed, Pass with only the engine, on a deallocated VM), a stale Run Command result named as such, and `COST.AUTOSHUTDOWN` reading the schedules by name rather than `--ids`.
- **Phase 14 (live, read-only, 2026-10-21):** every area ran against the deployed environment with its VMs deallocated (T2's checks in the morning runs, before the owner's setup-wizard session started `archost01`); the results are in the [implementation report](../implementation-report.md): no Fail. The checks that need running VMs reported Warnings as designed and are pending a running environment, as is the Contributor-only run (ADR 0008).

## Sources (checked 2026-10-19)

- Database Hub monitoring: <https://learn.microsoft.com/fabric/database/hub/monitor-sql>
- Telemetry REST endpoint: <https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry>
- Azure Resource Graph: <https://learn.microsoft.com/azure/governance/resource-graph/overview>
- SQL VM performance monitoring status: <https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm>
- Arc SQL monitoring: <https://learn.microsoft.com/sql/sql-server/azure-arc/sql-monitoring>
- Policy assignments that apply to a subscription (checked 2026-10-20): <https://learn.microsoft.com/rest/api/policy-authorization/policy-assignments/list>
- Policy definitions and policy set definitions, read by ID (checked 2026-10-20): <https://learn.microsoft.com/rest/api/policy-authorization/policy-definitions/get>, <https://learn.microsoft.com/rest/api/policy-authorization/policy-set-definitions/get>
- Policy rule structure, parameters, and effects (checked 2026-10-20): <https://learn.microsoft.com/azure/governance/policy/concepts/definition-structure-policy-rule>, <https://learn.microsoft.com/azure/governance/policy/concepts/definition-structure-parameters>, <https://learn.microsoft.com/azure/governance/policy/concepts/effect-basics>
- Assignment enforcement mode and overrides (checked 2026-10-20): <https://learn.microsoft.com/azure/governance/policy/concepts/assignment-structure>
- Telemetry endpoint contract, rules, and REST errors (checked 2026-10-20, page updated 2026-10-17): <https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry>
- Kusto query response, including partial query failures (checked 2026-10-20): <https://learn.microsoft.com/kusto/api/rest/response>
- Azure Resource Graph Resources API 2024-04-01 (checked 2026-10-20): <https://learn.microsoft.com/rest/api/azureresourcegraph/resourcegraph/resources/resources>
- Fabric REST: List Tenant Settings, Get Workspace, List Workspaces, List Capacities (checked 2026-10-20): <https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings>, <https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace>, <https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces>, <https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities>
- Fabric REST pagination, `continuationUri` and `continuationToken` (checked 2026-10-20): <https://learn.microsoft.com/rest/api/fabric/articles/pagination>
- The Hub tenant setting and the Arc telemetry role (checked 2026-10-20): <https://learn.microsoft.com/fabric/database/hub/monitor-sql>, <https://learn.microsoft.com/fabric/database/hub/add-sql>
- Phase 14 (checked 2026-10-21): VM power states and billing <https://learn.microsoft.com/azure/virtual-machines/states-billing>; deployment history and operations <https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-history>; `az role assignment list --all` <https://learn.microsoft.com/cli/azure/role/assignment>; `az consumption budget` <https://learn.microsoft.com/cli/azure/consumption/budget>; auto-shutdown <https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm>; Resource Graph `union` of `Resources` and `ResourceContainers` <https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language>; PSScriptAnalyzer compatibility rules and profiles <https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/usecompatibletypes>
- Viewer licensing for Power BI content, F64 and larger (checked 2026-10-21): <https://learn.microsoft.com/fabric/enterprise/licenses>
- Fabric REST: List Items, Create Item, Update Item Definition, Get Item Definition, and long-running operations (checked 2026-10-21): <https://learn.microsoft.com/rest/api/fabric/core/items/list-items>, <https://learn.microsoft.com/rest/api/fabric/core/items/create-item>, <https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition>, <https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition>, <https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation>
- KQL dashboard item definition (checked 2026-10-21): <https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/kql-dashboard-definition>
