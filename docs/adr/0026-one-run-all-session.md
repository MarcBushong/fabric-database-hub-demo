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

The control notebook NB_DatabaseHub_Control, in its own workspace "DBHub Control", is the one place a person runs a session: open it and select **Run all**. Nothing is edited first.

1. **The session request:** Run all sends `{"action":"session","sessionId":"<32 hex>"}` to the runbook DbHub-Control, which:
   - refuses while another run is active, with the reason;
   - plans the showcase on every target for the session's minutes (90 by default), ending before the VMs' next auto-shutdown, as a run always has: the VMs' profile hosts end their activity there. A shorter session says when it ends and why; one with less than 30 minutes left is refused;
   - marks the demo busy (`DbHubBusyUntilUtc` and `DbHubBusyBy` `session`, [ADR 0024](0024-nightly-safety-stop.md#amendment-the-busy-marker-so-the-nightly-stop-doesnt-cut-off-a-run-2026-11-14)) until 15 minutes after its auto-stop, with the session's ID and start (`DbHubSessionId`, `DbHubSessionStartUtc`), so the nightly stop's passes leave the session to its own auto-stop;
   - creates the auto-stop and, 30 minutes later, a second one that runs only if the first one's job fails;
   - starts the VMs, T3 (with its first session), and T4, and dispatches each target's showcase as soon as it runs;
   - asks for T4's read replica as soon as T4 is Ready, at T4's size or the next documented size Azure accepts (never fewer vCores), asking again while T4 restarts or updates (`ReadReplicaServerInUnexpectedState`, live 2026-11-13), and waits for it; then sets its `max_standby_streaming_delay` and records its size;
   - writes its progress, each step in plain words with its fix, to the control vault's secret `dbhub-session-status`.
2. **The replica-lag beat:** the showcase runs `replica-lag` in T4's even cycles, from minute 20 (50 minutes after T4's profile is set), on T1's profile host when it has the replica configured ([ADR 0010](0010-workload-generator-technology.md)). The status gives the beat's windows, or why it won't run.
3. **The notebook** follows the status, prints the presenter's guide (Database Hub's pages, the Insights app, when each incident shows, and the Database Agent prompts with this session's names and windows), and runs the activity notebook as a job in the demo workspace.
4. **The end:** the runbook's auto-stop (and Stop now) saves T4's and the replica's Azure Monitor metrics to the secret `dbhub-session-metrics` (`{"action":"capture"}` does the same on its own), deletes the replica, then stops T4, deallocates the VMs, and clears the busy marker. The notebook's next run saves those metrics to the lakehouse history when it hasn't yet.
5. **No GitHub Actions in a session:** the activity notebook's simulation control through `demo-control.yml` is gone; Actions stay for CI and the repository's own deploy workflows.

### The permissions (one-time, by an Owner)

`deploy.ps1` grants them when the person running it may (Owner or User Access Administrator). Otherwise each missing one is a **Warning** with `./scripts/grant-safety-stop.ps1`, which an Owner runs once for the safety stop and the control together, as for the safety stop ([ADR 0024](0024-nightly-safety-stop.md)). Until then, Run all runs a session without what's missing and says so. Contributor stays the minimum for everything else ([ADR 0008](0008-identity-rbac-abac.md)).

**"DbHub Demo Activity Operator"** (A1 at the demo resource group, A2 at the control's Automation account) gains seven actions:

| Action | What the session uses it for | What it could also touch, at the demo resource group |
|---|---|---|
| `Microsoft.DBforPostgreSQL/flexibleServers/write` | Creates T4's read replica | Could change T4; the runbook never does |
| `Microsoft.DBforPostgreSQL/flexibleServers/delete` | Deletes the replica after a session | Could delete T4; the runbook deletes only a server whose `replicationRole` says it's a read replica |
| `Microsoft.DBforPostgreSQL/flexibleServers/configurations/write` | Sets the replica's `max_standby_streaming_delay`, which the replica-lag beat needs | Could change any server parameter of T4 or the replica |
| `Microsoft.Network/virtualNetworks/subnets/join/action` | Puts the replica in T4's delegated subnet | Could put another resource in the demo's subnets |
| `Microsoft.Network/privateDnsZones/join/action` | Registers the replica in T4's private DNS zone | Could register another resource there |
| `Microsoft.Insights/metrics/read` | Reads T4's and the replica's Azure Monitor metrics for the history | Read-only |
| `Microsoft.Resources/tags/write` | Marks the demo busy and records the session | Could change any tag in the demo resource group, `deploymentId` included |

Azure has no narrower action and no name condition for these: attribute-based conditions cover storage data actions only. A delete lock on T4 would block the identity's delete of T4, but `destroy.ps1` as a Contributor couldn't remove it, so there's none.

**"DbHub Demo Session Writer"** (A4, new), for the same identity at the control vault's two session secrets only, never at the demo resource group, whose optional vault it never reaches:

| Action | What the session uses it for | What it could also touch |
|---|---|---|
| `Microsoft.KeyVault/vaults/secrets/read` | Reads the session secrets' properties (Azure Resource Manager never returns a value) | Nothing else: those two secrets only |
| `Microsoft.KeyVault/vaults/secrets/write` | Writes the session's status and metrics | Could overwrite those two secrets' values, which the notebook reads as status and metrics, never as credentials |

**A3** (Key Vault Secrets User) extends from the webhook's secret to the two session secrets, for the signed-in owner and `control.notebookUserObjectIds`, so the notebook can read them.

**Not used:** the pre-approved `Microsoft.DevTestLab/schedules/read` and `/write`. A session ends before the VMs' auto-shutdown, as a run always has, because the profile hosts on T1 and in T2's guest end their activity there (`--not-after`, set when they start); moving the auto-shutdown alone wouldn't keep a session's activity going. A session that runs past it would need those hosts to take a later end too, a change on the VMs that's a [follow-up](#consequences).

## Consequences

- **Easier:** a session is one action, Run all, with nothing to edit, no script, and no GitHub; the replica beat and the history's PostgreSQL metrics come with it, and a session can't be cut off by the nightly stop.
- **Harder:**
  - The control identity can change or delete T4 and change tags in the demo resource group (above).
  - The runbook ports the replica's size order and its creation from the module, so two copies follow the same rules: tests run the same cases against both.
  - A session started late in the day is shorter (it ends before the VMs' auto-shutdown), and says so. Follow-up: let the VM-side profile hosts take a session's end, then move the auto-shutdown during a session as `deploy.ps1` does.
  - Run all takes longer to start in the control workspace (3 to 5 minutes for its managed network), and the replica's creation (about 9 minutes) runs while the VMs start.

## Validation

- **Static:** `tests/unit/Automation.Runbooks.Tests.ps1` (the session, capture, and stop paths against a fake Azure), `DbHubDemo.ActivityControl.Tests.ps1` (the roles, the grant plan, and the setup), the runner's `ProfileSchedulerTests` and `CatalogTests` (the replica slot).
- **Live:** pending.

## Sources

- Webhooks: <https://learn.microsoft.com/azure/automation/automation-webhooks>
- Secrets - Create Or Update (Azure Resource Manager): <https://learn.microsoft.com/rest/api/keyvault/keyvault/secrets/create-or-update>
- Tags - Update At Scope: <https://learn.microsoft.com/rest/api/resources/tags/update-at-scope>
- Servers - Create, Servers - Delete, Configurations - Put (Azure Database for PostgreSQL): <https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/create>, <https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/delete>, <https://learn.microsoft.com/rest/api/postgresql/flexibleserver/configurations/put>
- Read replicas: <https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas>, <https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica>
- Metrics - List: <https://learn.microsoft.com/rest/api/monitor/metrics/list>
- Azure permissions reference: <https://learn.microsoft.com/azure/role-based-access-control/permissions/databases>, <https://learn.microsoft.com/azure/role-based-access-control/permissions/networking>, <https://learn.microsoft.com/azure/role-based-access-control/permissions/security>
- Azure Automation's fair share (a cloud job runs at most 3 hours): <https://learn.microsoft.com/azure/automation/automation-runbook-execution#fair-share>
