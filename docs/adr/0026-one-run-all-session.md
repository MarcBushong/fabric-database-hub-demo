# ADR 0026: One Run all for a whole demo session

- **Status:** Accepted for the user by the project's coordinator (2026-11-14), who reviews it with the user before anything merges; the user can reverse the grant, since without it Run all still runs a session without T4's read replica and says so. Live validation: [below](#validation).
- **Date:** 2026-11-14
- **Decision source:** User-directed (2026-11-14: "I just want to go to one notebook and execute one thing. It may execute many things though and that is okay"; the experience "as easy as possible for users to execute and show. One click, one deploy"; a demo session needs no GitHub Actions), with the control notebook in its own workspace "because of the network controls". The design, the grant, and this ADR's permissions were approved by the coordinator for the user.
- **Related:** [ADR 0012](0012-validation-model.md) (statuses), [ADR 0020](0020-on-demand-activity-control.md) (the control, its role, and its vault), [ADR 0024](0024-nightly-safety-stop.md) (the nightly stop and the busy marker), [ADR 0025](0025-t4-read-replica.md) (T4's read replica), [ADR 0010](0010-workload-generator-technology.md) (the showcase's replica slot), [permissions](../permissions.md)

## Context

- **Before:** a session took 4 or 5 actions across a PC and two notebooks: `start-demo.ps1` (or the control notebook's run, or the activity notebook with a GitHub token), `demo-control.ps1` for the replica beat, the activity notebook's Run all with its `CONFIRM` switch, finding Database Hub's pages and the Database Agent prompts, and `stop-demo.ps1 -SaveHistory`. The control (ADR 0020) was optional, and it never created T4's read replica, so a control run had no Read replica lag.
- **Fabric notebooks get no Azure Resource Manager token** (`notebookutils.credentials.getToken` offers storage, pbi, keyvault, and kusto), so whatever acts on Azure goes through the control's Azure Automation runbook, which the notebook starts through its webhook, read from the control vault.
- **The control notebook can't read a job's output, and the runbook can't reach a private vault's data plane** (the vault's managed private endpoint serves Fabric only). Azure Resource Manager's Secrets - Create Or Update isn't subject to a vault's network rules, and the webhook's own secret is written that way already (`infra/control/webhook.bicep`).
- **A deleted server's Azure Monitor metrics can't be read** (`ResourceNotFound`, live 2026-11-13), so the history needs the replica's metrics before the replica is deleted.

## Decision

### The session

The control notebook NB_DatabaseHub_Control, in its own workspace (with a private vault; a folder of the demo's workspace with a public one, [ADR 0020](0020-on-demand-activity-control.md)), is the one place a person runs a session: open it and select **Run all**. Nothing is edited first.

1. **The session request:** Run all sends `{"action":"session","sessionId":"<32 hex>"}` to the runbook DbHub-Control, which:
   - refuses while another run is active, with the reason;
   - plans the showcase on every target for the session's minutes (90 by default), ending before the VMs' next auto-shutdown, as a run always has: the VMs' profile hosts end their activity there. A shorter session ends after its last whole 30-minute showcase cycle, so no beat is cut off, and says when it ends and why; one with less than 30 minutes left is refused;
   - marks the demo busy (`DbHubBusyUntilUtc` and `DbHubBusyBy` `session`, [ADR 0024](0024-nightly-safety-stop.md#amendment-the-busy-marker-so-the-nightly-stop-doesnt-cut-off-a-run-2026-11-14)) until 15 minutes after its auto-stop, with the session's ID and start (`DbHubSessionId`, `DbHubSessionStartUtc`), so the nightly stop's passes leave the session to its own auto-stop;
   - creates the auto-stop and, 30 minutes later, a second one that runs only if the first one's job fails;
   - starts the VMs, T3 (with its first session), and T4, and dispatches each target's showcase as soon as it runs;
   - asks for T4's read replica as soon as T4 is Ready, at T4's size or the next documented size Azure accepts (never fewer vCores), asking again while T4 restarts or updates (`ReadReplicaServerInUnexpectedState`, live 2026-11-13), and waits for it; then sets its `max_standby_streaming_delay` and records its size;
   - writes its progress, each step in plain words with its fix, to the control vault's secret `dbhub-session-status`.
2. **The replica-lag beat:** the showcase runs `replica-lag` in T4's even cycles, from minute 20 (50 minutes after T4's profile is set), on T1's profile host when it has the replica configured ([ADR 0010](0010-workload-generator-technology.md)). The status gives the beat's windows, or why it won't run.
3. **The notebook** says before it sends anything when the session will end and why (the runbook's plan, which it computes the same way from `CATALOG_JSON`'s session rules: a session the auto-shutdown cuts short ends after its last whole 30-minute showcase cycle, so no beat stops midway, and none starts with less than 30 minutes left), reports the demo workspace's capacity (a paused one only gets a clear message: the notebook never resumes or pauses it, nor checks licenses), then follows the status, prints the presenter's guide (Database Hub's pages, the history report, the Insights app, each beat in the demo's clock from each target's dispatch time in the status, with when it shows, and the Database Agent prompts with this session's names and windows), and keeps a live view until the session's end. A Run all while a session runs follows that session instead of starting another.
4. **The end:** the notebook sends Stop now with the session's ID at the session's end (`WAIT_FOR_END`, the default). The runbook removes the auto-stops, saves T4's and the replica's Azure Monitor metrics to the secret `dbhub-session-metrics` first (`{"action":"capture"}` does the same on its own), deallocates the VMs, deletes the replica, then stops T4 and confirms its stop (Azure can refuse it for a minute after the replica's delete, so the runbook asks again), and clears the busy marker. About 15 minutes later, with everything stopped, once the SQL telemetry has arrived, the notebook runs `NB_DatabaseHub_LiveActivity` as a job in the demo workspace (Job Scheduler, as the presenter, with the `pbi` token) with `SESSION_ID`, `SESSION_PLAN` (the beats), the session's window, `POSTGRES_METRICS`, and the environment's names (`RESOURCE_GROUP` and the targets', which the activity notebook's own defaults give as the owner's environment). That notebook records the session and its beats in `scenario_runs` last, so a session already there isn't saved twice. When Run all stopped early, the session's auto-stop does the Azure part 10 minutes after its end, and the next Run all saves the earlier session's history first, while its own session starts. Run all keeps its Spark session for the whole session, about two hours for 90 minutes; `WAIT_FOR_END = False` ends it after the guide.
5. **No GitHub Actions in a session:** the activity notebook's simulation control through `demo-control.yml` (and its P9 token) is removed, with no default and no fallback; the notebook analyzes and saves only. Actions stay for CI and the repository's own deploy workflows. The scripts that run it still pass `CONFIRM` and `STOP_ACTIVITY` as false, which only a copy imported before 2026-11-14 reads.

### In every deployment

`deploy.ps1` sets the control up on every run, for a new environment and an existing one, with nothing to turn on:

- **No switch:** `control.enabled` is ignored. An older configuration's `"enabled": false`, which `init.ps1` wrote by default, gets one line (`DEPLOY.CONTROL.ON`). A control set up before 2026-11-14 is adopted as it is: the same names, so the same resources, updated in place.
- **Azure part:** the setup without Fabric (the vault's mode, the group, the template, the runbooks with this code, the T4 safety stop, the webhook, the session's secrets, and the roles) runs beside the nightly safety stop while the tracks run.
- **Fabric part:** the notebook goes into Fabric after the Fabric track, where the vault actually is (`publicNetworkAccess`). While the capacity isn't Active, nothing in Fabric changes: a Warning, and the next `deploy.ps1` does it. The capacity is never resumed or paused.
- **Never a Fail:** what doesn't work is a Warning with its fix ([ADR 0012](0012-validation-model.md)), never in DONE's way, as the nightly safety stop's problems are. The status page's **Session control** row and DONE's line say where Run all is, or what it still needs and who does it.
- **Preflight:** P2 also registers `Microsoft.Automation`, `Microsoft.KeyVault`, and `Microsoft.ManagedIdentity`. `Microsoft.Network` was already required; a private vault's managed private endpoint needs it, on any Fabric capacity, Trial included ([prerequisites](https://learn.microsoft.com/fabric/security/security-managed-private-endpoints-create#prerequisites)).
- **The control workspace's name:** the demo workspace's name followed by " Control", so two environments in one tenant never share a workspace. "DBHub Control", the earlier default, stays for a control set up before 2026-11-14.
- **Shared roles:** custom roles belong to the whole subscription, so environments in one subscription share them, and a `deploy.ps1` on newer code updates them for every environment there. `control.roleNameSuffix` gives an environment its own two roles, "DbHub Demo Activity Operator (*suffix*)" and "DbHub Demo Session Writer (*suffix*)", for an environment beside a demo on other code (the test environments use it). A role that already has exactly its approved actions isn't written again, so a Contributor's `deploy.ps1` has nothing to report about it.

### The permissions (one-time, by an Owner)

`deploy.ps1` grants them when the person running it may (Owner or User Access Administrator). Otherwise each missing one is a **Warning** with `./scripts/grant-safety-stop.ps1`, which an Owner runs once for the safety stop and the control together, as for the safety stop ([ADR 0024](0024-nightly-safety-stop.md)). Until then, Run all runs a session without what's missing and says so. Contributor stays the minimum for everything else ([ADR 0008](0008-identity-rbac-abac.md)).

**"DbHub Demo Activity Operator"** (A1 at the demo resource group, A2 at the control's Automation account) gains five actions:

| Action | What the session uses it for | What it could also touch, at the demo resource group |
|---|---|---|
| `Microsoft.DBforPostgreSQL/flexibleServers/write` | Creates T4's read replica | Could change T4; the runbook never does |
| `Microsoft.DBforPostgreSQL/flexibleServers/delete` | Deletes the replica after a session | Could delete T4; the runbook deletes only a server whose `replicationRole` says it's a read replica |
| `Microsoft.DBforPostgreSQL/flexibleServers/configurations/write` | Sets the replica's `max_standby_streaming_delay`, which the replica-lag beat needs | Could change any server parameter of T4 or the replica |
| `Microsoft.Insights/metrics/read` | Reads T4's and the replica's Azure Monitor metrics for the history | Read-only |
| `Microsoft.Resources/tags/write` | Marks the demo busy and records the session | Could change any tag in the demo resource group, `deploymentId` included |

No network join action: the replica's create names T4's delegated subnet and private DNS zone, and Azure created it for a role without `Microsoft.Network/virtualNetworks/subnets/join/action` and `Microsoft.Network/privateDnsZones/join/action` (live, 2026-11-14, 70 minutes after they were removed), so neither is granted. As first approved, the role had seven actions here, with those two.

Azure has no narrower action and no name condition for these: attribute-based conditions cover storage data actions only. A delete lock on T4 would block the identity's delete of T4, but `destroy.ps1` as a Contributor couldn't remove it, so there's none.

**"DbHub Demo Session Writer"** (A4, new), for the same identity at the control vault's two session secrets only, never at the demo resource group, whose optional vault it never reaches:

| Action | What the session uses it for | What it could also touch |
|---|---|---|
| `Microsoft.KeyVault/vaults/secrets/read` | Reads the session secrets' properties (Azure Resource Manager never returns a value) | Nothing else: those two secrets only |
| `Microsoft.KeyVault/vaults/secrets/write` | Writes the session's status and metrics | Could overwrite those two secrets' values, which the notebook reads as status and metrics, never as credentials |

**A3** (Key Vault Secrets User) extends from the webhook's secret to the two session secrets, for the signed-in owner and `control.notebookUserObjectIds`, so the notebook can read them.

**No DevTestLab action** (the coordinator's decision for the user, 2026-11-14: grant only what the runbook uses): the two that were pre-approved to move the VMs' auto-shutdown for a session aren't in the role. A session ends before the auto-shutdown instead, as a run always has, because the profile hosts on T1 and in T2's guest end their activity there (`--not-after`, set when they start); moving the auto-shutdown alone wouldn't keep a session's activity going. Running past it would need those hosts to take a later end too, a change on the VMs that the [implementation report](../implementation-report.md) lists as a follow-up.

## Consequences

- **Easier:** a session is one action, Run all, with nothing to edit, no script, and no GitHub; the replica beat and the history's PostgreSQL metrics come with it, and a session can't be cut off by the nightly stop.
- **Harder:**
  - The control identity can change or delete T4 and change tags in the demo resource group (above).
  - The runbook ports the replica's size order and its creation from the module, so two copies follow the same rules: tests run the same cases against both.
  - A session started late in the day is shorter (it ends before the VMs' auto-shutdown), and says so. Follow-up: let the VM-side profile hosts take a session's end, then move the auto-shutdown during a session as `deploy.ps1` does.
  - Run all takes longer to start in the control workspace (3 to 5 minutes for its managed network), and the replica's creation (about 9 minutes) runs while the VMs start.

## Validation

- **Static:** `tests/unit/Automation.Runbooks.Tests.ps1` (the session, capture, and stop paths against a fake Azure, the whole-cycle cap, and each target's dispatch time), `DbHubDemo.ActivityControl.Tests.ps1` (the roles, the grant plan, the setup, the deploy step, the workspace's name, the role names' suffix, and the backup auto-stop's removal by `start-demo.ps1` and `stop-demo.ps1`), the runner's `ProfileSchedulerTests` and `CatalogTests` (the replica slot), `Fabric.ControlNotebook.Tests.ps1` (every code cell of the imported notebook, run offline against stand-ins for the vault, the webhook and its runbook, the Fabric REST API, and a clock: a whole session, a paused capacity, a session that already runs, too late in the day, cut to whole cycles, an earlier session's history, Stop now, `check`, `WAIT_FOR_END = False`, and a refusal; the plan against the runbook's numbers, the beats against the runner's rules), and `Fabric.Notebooks.Tests.ps1` (the activity notebook's session cell, its once-only save, and no GitHub path).
- **Live, Azure only (2026-11-14, on a test environment beside the owner's demo; the Fabric capacity was paused):**
  - **Adoption:** a control set up with `main`'s `setup-activity-control.ps1` (no grant) was adopted by this branch's control setup with nothing removed: the same names, the runbooks republished with the session's code, the two session secrets created, and the environment's own suffixed roles (29 and 2 actions, with the two network join actions dropped since) created and assigned (A1, A2, A3 for three secrets, A4 for two). The owner's shared "DbHub Demo Activity Operator" stayed at 22 actions, unchanged since 2026-10-27, before and after.
  - **A session through the webhook:** accepted and running in 10 minutes from a stopped environment: the VMs and T4 started (T4 Ready in 2 minutes), every target's showcase dispatched, T4's read replica created at T4's size (`Standard_D4ds_v5`) once T4 was Ready and Ready about 7 minutes later, and the status secret moved through `starting`, `replica`, and `running`. It found one wrong line, fixed since: a run's "on-demand runs don't create it" note about the replica was logged in a session, which creates it.
  - **The busy marker:** with the session running, the nightly stop's two passes and the control's T4 stop each ended **Deferred** ("a demo session is running, busy until …"), and stopped nothing.
  - **The end:** the session's auto-stop, 10 minutes after its end, saved T4's and the replica's metrics first (8 series, 281 points, 9.2 KB, `replica` yes), deallocated the VMs, deleted the replica, removed both auto-stops, cleared the busy marker, and wrote `stopped` to the status. **One bug, fixed since:** T4's stop, sent when the replica's read returned 404 but about 20 seconds before its delete had finished, was accepted and then failed with `SourceReplicasStartStopOrder` ("an operation is in progress on its read replica"), so T4 stayed running. The runbook now confirms T4's stop after deleting its replica and asks again, up to 3 times in 10 minutes; otherwise it says T4 wasn't stopped and that the nightly safety stop stops it (two tests). The [implementation report](../implementation-report.md#run-all-the-control-notebook-runs-a-whole-session-2026-11-14) has the details.
  - **Stop now, and the race again (a second session, 09:31 to 10:00 UTC, with the fix published):** T4's read replica was created and Ready in 7 minutes for a role without the two network join actions, removed 70 minutes earlier, so the role no longer has them. Stop now with the session's ID saved the metrics (8 series, 159 points, `replica` yes), deallocated the VMs, and deleted the replica. Azure failed T4's first stop again (accepted at 09:56:42, the replica's delete finished at 09:56:59, the stop failed at 09:57:43); the runbook asked again at 09:59:26 and logged "stopping after 2 stops", and T4 was Stopped. The marker was cleared, both auto-stops removed, and nothing failed.
- **Pending the capacity's resume (only the user resumes it):** Run all itself in Fabric, the activity notebook's job through the `pbi` token, and the control's Fabric part (its workspace and notebook) on these environments.

## Sources

- Webhooks: <https://learn.microsoft.com/azure/automation/automation-webhooks>
- Secrets - Create Or Update (Azure Resource Manager): <https://learn.microsoft.com/rest/api/keyvault/keyvault/secrets/create-or-update>
- Tags - Update At Scope: <https://learn.microsoft.com/rest/api/resources/tags/update-at-scope>
- Servers - Create, Servers - Delete, Configurations - Put (Azure Database for PostgreSQL): <https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/create>, <https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/delete>, <https://learn.microsoft.com/rest/api/postgresql/flexibleserver/configurations/put>
- Read replicas: <https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas>, <https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica>
- Metrics - List: <https://learn.microsoft.com/rest/api/monitor/metrics/list>
- Azure permissions reference: <https://learn.microsoft.com/azure/role-based-access-control/permissions/databases>, <https://learn.microsoft.com/azure/role-based-access-control/permissions/networking>, <https://learn.microsoft.com/azure/role-based-access-control/permissions/security>
- Azure Automation's fair share (a cloud job runs at most 3 hours): <https://learn.microsoft.com/azure/automation/automation-runbook-execution#fair-share>
