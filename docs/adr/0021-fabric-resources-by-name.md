# ADR 0021: Fabric resources by name, resolved at run time, and created when missing

- **Status:** Accepted. Built and unit-tested on 2026-10-27, and the lookup by name checked live, read-only; the create path's live check runs after the merge, in a test workspace
- **Date:** 2026-10-27
- **Decision source:** User-directed (2026-10-26: "parameterize the fabric IDs, do not store them. But we should be able to create them and automatically pick up the right IDs", and "automate as much as possible for other folks using the repo"), with the coordinator's decisions on 2026-10-27 (notebooks imported without asking when missing, and the rule for GUID-shaped values)
- **Related:** [ADR 0008](0008-identity-rbac-abac.md), [ADR 0012](0012-validation-model.md), [ADR 0014](0014-notebook-role-and-capacity.md), [ADR 0018](0018-fast-redeploy-parallel-tracks-golden-snapshot.md), [ADR 0020](0020-on-demand-activity-control.md), [configuration](../configuration.md#fabric), [prerequisites](../prerequisites.md)

## Context

- **The repository is being opened to other users.** Until now, each deployer looked up their workspace and lakehouse IDs and wrote them into `config/demo.config.json` (`fabric.workspaceId`, `fabric.lakehouseId`), and both notebooks carried the original workspace's and lakehouse's IDs in their metadata and parameters cell. The original spec kept the notebooks' kernel and lakehouse metadata exactly as supplied.
- **Fabric has documented APIs for every step:** List Workspaces returns every workspace you can access, with its type and capacity, but has no name filter, so the name is matched on the client ([List Workspaces](https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces)); Create Workspace takes a display name and a capacity ID, and needs the "Create workspaces" tenant setting for you and a contributor or administrator role on the capacity ([Create Workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace)); Assign To Capacity answers 202 and needs the workspace's Admin role and the capacity role ([Assign To Capacity](https://learn.microsoft.com/rest/api/fabric/core/workspaces/assign-to-capacity)); List Capacities lists only the capacities you administer or contribute to, with their state ([List Capacities](https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities)); List Lakehouses and Create Lakehouse need a viewer and a contributor role in the workspace, and Create Lakehouse can be a long-running operation and takes `creationPayload.enableSchemas` ([List Lakehouses](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/list-lakehouses), [Create Lakehouse](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse), [long-running operations](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation)). All checked on 2026-10-27.
- **The history model reads the `dbo` schema.** The demo's lakehouse has lakehouse schemas, so the notebooks' tables are in `dbo`, and every Direct Lake partition of `SM_DatabaseHub_History` names `schemaName: dbo`.
- **A notebook's default lakehouse is in its metadata** (`dependencies.lakehouse`), which Fabric's own Git integration keeps ([notebook source control](https://learn.microsoft.com/fabric/data-engineering/notebook-source-control-deployment)); the notebook definition article doesn't document those fields ([notebook definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/notebook-definition)).

## Decision

1. **Names in the configuration, no IDs.** `fabric.workspaceName` (default `Database Hub Demo`), `fabric.lakehouseName` (default `LH_DatabaseHub`), `fabric.capacityName` (used only to create the workspace or to assign one that has no capacity), and `fabric.createIfMissing` (default true). `fabric.workspaceId` and `fabric.lakehouseId` stay as optional overrides for configurations written before this decision; they aren't needed, and the all-zero placeholder counts as not set. The schema keeps `additionalProperties: false`.
2. **One resolver, `Resolve-DemoFabricConfig`.** It returns a copy of the configuration with the IDs filled in, so the code after it keeps reading `fabric.workspaceId` and `fabric.lakehouseId`:
   - **The workspace:** an override is used as it is (`FABRIC.RESOLVE.WORKSPACE` Not selected, no request); otherwise the one workspace with the name among those you can access, personal workspaces skipped, exact case first. Two matches are Manual action required.
   - **Created when missing,** only for callers that write to Fabric (`-Create`) and while `createIfMissing` is true: on the capacity named `capacityName`, which must be one you can assign and **Active**. A workspace found without a capacity is assigned to it. Both wait until Get Workspace reports the assignment as Completed.
   - **The lakehouse:** the same, in that workspace, and created **with lakehouse schemas**, following a 202 to the end and reading the new lakehouse back by name.
   - **Never a capacity:** the resolver doesn't create, resume, pause, or scale one. A paused capacity is Manual action required; resuming it is its administrator's job.
   - **Statuses (ADR 0012):** **Pass** when found by name, created, or assigned; **Not selected** for an override or a dry run; **Warning** when it's missing and the caller only reads (preflight, `status.ps1`, `validate.ps1`), which never create anything; **Manual action required**, with the exact steps, when `createIfMissing` is false, when `capacityName` isn't set, isn't one you can assign, or isn't Active, when you may not create workspaces or items, when a workspace you can't access already has the name, or without a Fabric token; **Fail** for any other error.
   - Messages name the workspace, the lakehouse, and the capacity, never their IDs. `-WhatIf` creates nothing, and sends nothing without a token.
3. **Every consumer resolves first:**
   - `configure-fabric.ps1` (its new step 0, only when a later step uses the workspace, and the lakehouse only for the notebooks); `configure-powerbi.ps1` (the Direct Lake model gets the resolved lakehouse); `configure-fabric-app.ps1` (the workspace only); so deploy.ps1's Fabric track, which runs those three scripts, does too;
   - preflight's `PREFLIGHT.P5.WORKSPACE`, read-only: your role and capacity for a workspace that exists, or a **Warning** naming the capacity that deploy would create it on, because no API reads the "Create workspaces" setting without Fabric administrator rights;
   - `status.ps1`'s new `STATUS.FABRIC`, read-only, with the capacity's state; `validate.ps1`'s Hub area, read-only;
   - `setup-activity-control.ps1` (the control notebook's folder or workspace, read-only for the demo's workspace) and `-Remove`;
   - every notebook run passes `WORKSPACE_ID` and `LAKEHOUSE_ID` from the resolved configuration (`Invoke-DemoFabricNotebookRun`);
   - the GitHub workflows need no Fabric ID in `DBHUB_CONFIG_JSON`: the names are enough.
4. **The notebooks hold no IDs.** Both keep their kernel, names, and `default_lakehouse_name`; the IDs are gone from the metadata and the parameters cell (`WORKSPACE_ID = ""`, `LAKEHOUSE_ID = ""`). The import binds the uploaded copy, never the file, to the resolved workspace and lakehouse: `default_lakehouse`, `default_lakehouse_workspace_id`, `known_lakehouses`, and the parameters cell. Without a resolved lakehouse, nothing is imported. An empty ID at run time is the session's own workspace or default lakehouse (`notebookutils.runtime.context`), so a notebook imported by hand works, and the Deployment notebook's checks pass in any tenant. In the same way, `GITHUB_REPOSITORY` defaults to the public repository, and the import sets it and `GITHUB_ENVIRONMENT` from `github.repository` and `github.environment` when the repository isn't the example configuration's placeholder, so a copy of the repository triggers its own workflow.
5. **Notebooks imported without asking when they're missing.** While `fabric.importNotebooks` is false (the default), deploy.ps1 passes `-NewNotebooksOnly`: a notebook that isn't in the workspace yet, as in a workspace or lakehouse that was just created, is imported, and one that is stays as it is (`FABRIC.IMPORT.*` Not selected, saying why). Updating existing notebooks stays opt-in: `importNotebooks` true, or running `configure-fabric.ps1` yourself. When the live-activity notebook was just created, or bound to a lakehouse that was just created, it runs once, so the history tables exist before the model's refresh. It writes only the lakehouse's tables.
6. **No Fabric ID in the repository, checked by tests** (`tests/unit/Repo.Conventions.Tests.ps1`):
   1. No notebook holds a GUID-shaped value.
   2. Under `fabric/`, a GUID is the all-zero placeholder, an obvious fake, or a generator's ID under its own key: the Real-Time Dashboard's version-5 UUIDs under `id`, `pageId`, `queryId`, and `dataSourceId`, and the report's `logicalId` and visual IDs. Both generators derive them from element names, not from a tenant (`ConvertTo-DemoStableGuid` and `fabric/powerbi/generator`), and a test checks that the dashboard file is exactly the exporter's output.
   3. Anywhere in the repository, a GUID in a Fabric ID context (workspace, lakehouse, or capacity keys, `WORKSPACE_ID`, `LAKEHOUSE_ID`, the `default_lakehouse` fields, `/workspaces/`, `/groups/`, `/lakehouses/`, `/capacities/` paths, and OneLake URLs) is the all-zero placeholder or an obvious fake: six distinct hex digits or fewer, or three or more of its five groups each one repeated character.
   4. In the tests, every GUID is the all-zero placeholder, an obvious fake, or on a short, commented list of public IDs (built-in role IDs, Windows component IDs, and one name-based dashboard ID).

## Deviation from the original spec

The original spec kept the supplied notebooks' kernel and lakehouse metadata exactly. This decision keeps the kernel and the lakehouse's name, and drops the workspace and lakehouse IDs, on the owner's instruction. The brief's literal rule, "no GUID-shaped value under `fabric/**` or in the tests", became rules 1 to 4 above (the coordinator's decision, 2026-10-27): removing the generators' name-based IDs would have meant reworking how the dashboard and the report are generated, and the tests' fixtures are documented fakes.

## Alternatives considered

- **Keep IDs in the configuration, and document how to look them up:** every new user would copy IDs from the portal's URLs. Rejected by the owner.
- **The all-zero placeholder in the notebooks' metadata:** an imported-by-hand notebook would point at a lakehouse that doesn't exist. Empty IDs with the session fallback work without the scripts.
- **Pick a capacity by itself when exactly one is visible:** a capacity can be shared and billed; the user names it. `scripts/init.ps1` (Phase 26b) discovers and offers them.
- **Create the lakehouse without schemas:** the history model's partitions read `dbo`. Rejected.

## Consequences

- A new user configures names only, and the first deploy creates the workspace and the lakehouse on the capacity they name, imports the notebooks, the dashboard, the model, the report, and the app, and creates the history tables.
- Creating needs more than workspace Contributor: the "Create workspaces" tenant setting for you, and a contributor or administrator role on the capacity ([prerequisites](../prerequisites.md), P5). Without them, the steps say what to ask for, and an administrator can create the workspace instead.
- Configurations with ID overrides behave as before, and send no request to look up names.
- Every Fabric script makes one more list call per run; a workspace that's just been created can take a moment to appear in List Workspaces, so a second run finds it by name.
- The old IDs remain in the repository's history; the public copy starts from one fresh commit.

## Validation

- Unit tests: `tests/unit/DbHubDemo.FabricResolve.Tests.ps1` (overrides, dry run, no token, found by name, duplicates, read-only Warning, created on an Active capacity, the lakehouse's long-running creation with schemas, capacity assignment, paused or unnamed capacity, the tenant setting, a name in use, preflight P5, and `STATUS.FABRIC`), `tests/unit/DbHubDemo.Fabric.Tests.ps1` (an import with names only binds the metadata and the parameters cell to the resolved IDs, and the notebook run gets them; `-NewNotebooksOnly`), `tests/unit/Fabric.Notebooks.Tests.ps1` (empty defaults, the session fallback run in Python), and `tests/unit/Repo.Conventions.Tests.ps1` (rules 1 to 4).
- Live, read-only (GET requests only), 2026-10-27: a copy of an existing configuration, with its ID overrides removed and only the names left, resolved to the same workspace and lakehouse (`FABRIC.RESOLVE.WORKSPACE` and `FABRIC.RESOLVE.LAKEHOUSE` **Pass**), and preflight's P5 and `STATUS.FABRIC` were **Pass**. An unknown workspace name was a **Warning**, from the resolver and from P5, naming the capacity and the tenant setting. The configuration with its overrides still validated against the new schema and sent no lookup (**Not selected**). Get Lakehouse reported `defaultSchema` `dbo`, so the lakehouse has schemas.
- Live, after the merge: run the Fabric track with names only; then create a uniquely named test workspace, let the resolver create its lakehouse, run the Fabric track into it, check the notebooks, the dashboard, the model, the report, and the app, and delete only that test workspace.

## Sources (checked 2026-10-27)

- [Workspaces - List Workspaces](https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces)
- [Workspaces - Create Workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace)
- [Workspaces - Get Workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace)
- [Workspaces - Assign To Capacity](https://learn.microsoft.com/rest/api/fabric/core/workspaces/assign-to-capacity)
- [Capacities - List Capacities](https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities)
- [Items - List Lakehouses](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/list-lakehouses)
- [Items - Create Lakehouse](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse)
- [Long-running operations](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation)
- [Pagination](https://learn.microsoft.com/rest/api/fabric/articles/pagination)
- [Workspace tenant settings: Create workspaces](https://learn.microsoft.com/fabric/admin/portal-workspace)
- [Capacity user permissions](https://learn.microsoft.com/power-bi/enterprise/service-admin-premium-manage#manage-user-permissions)
- [Notebook source control and deployment](https://learn.microsoft.com/fabric/data-engineering/notebook-source-control-deployment)
- [NotebookUtils runtime context](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-runtime)
