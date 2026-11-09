# ADR 0024: The nightly safety stop

- **Status:** Accepted (the owner approved the design, its stop-only role, and the role's assignment by default on 2026-11-05). Amended 2026-11-09 ([below](#amendment-link-scopes-read-one-by-one-and-t4-at-the-t3-check-2026-11-09)). It ran live from 2026-11-06 in the owner's test environment, where every job completed; the 2026-11-09 changes are unit-tested only ([validation](#validation)).
- **Date:** 2026-11-05
- **Decision source:** User-directed (2026-11-05: the safety stop for every database at the nightly shutdown time, the role, and its assignment by default as an exception to [ADR 0008](0008-identity-rbac-abac.md)), with engineering detail
- **Related:** [ADR 0008](0008-identity-rbac-abac.md) (the exception), [ADR 0012](0012-validation-model.md) (statuses), [ADR 0016](0016-cost-profiles.md) (T4's restart worst case), [ADR 0019](0019-t4-postgresql-flexible-server.md) (T4), [ADR 0020](0020-on-demand-activity-control.md) (the runbook code and the control's own T4 safety stop), [what stops or pauses on its own](../../README.md#what-stops-or-pauses-on-its-own), [cost management](../cost-management.md#dated-example-the-nightly-safety-stop-2026-11-05), [permissions](../permissions.md), [troubleshooting](../troubleshooting.md)

## Context

- **The owner's words (2026-11-05):** "Can we have safety stops for all the databases?" Then, asked whether every deployment should get a daily safety stop at the nightly shutdown time that deallocates both VMs, stops T4, and confirms that T3 paused, with its permission granted by the deployment when the person who deploys is an Owner and one command printed for an Owner otherwise: "Yes, at the nightly shutdown time". Then, asked whether that role assignment by default should be an exception to ADR 0008 or wait for `assignRoles`: "Assign it by default when the deployer can, as an owner-approved exception to ADR 0008, recorded in the new ADR". Not wanted: a 2 AM catch-up stop, and PostgreSQL's own scheduled stop task.
- **What stopped the databases before:**
  - T1 and T2's host: the VMs' DevTest Labs auto-shutdown at `autoShutdownTime` in `autoShutdownTimeZone` (19:00 Pacific by default), which a person can turn off on the VM; the T2 guest shuts down with its host.
  - T3: serverless auto-pause, `t3AutoPauseMinutes` (15 by default) after its last session; Azure has no "pause now" operation ([auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume)).
  - T4: only `stop-demo.ps1`, and the optional control's daily T4 safety stop (off by default). Azure starts a stopped flexible server again on its own after 7 days ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)), so the cost estimate counted the rest of the month for T4 after a restart: 720 hours of a 730-hour month ([ADR 0016](0016-cost-profiles.md#2026-11-04-user-directed-the-4-vcore-t4-default-and-a-375-ceiling)).
- **T3's status can be read without waking it:** the auto-resume triggers are a login, and listed features such as auditing, data masking, Query Store settings, sensitivity labels, and changes to tags, vCores, or the auto-pause delay; reading the database's properties isn't one of them, and Learn monitors the pause status with exactly that read (`az sql db show --query status`, [monitor the serverless tier](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-monitor#monitor-pause-and-resume-status); both checked 2026-11-05).
- **A flexible server stops only when it's Ready:** otherwise Azure answers ServerIsNotReady, or SeverBusyWithOtherOperation while another operation runs ([stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)).
- **Azure Automation:** a daily schedule runs in a time zone ([schedules](https://learn.microsoft.com/azure/automation/shared-resources/schedules)); a runbook gets a user-assigned identity's token from the sandbox ([user-assigned identity](https://learn.microsoft.com/azure/automation/add-user-assigned-identity)); with local authentication off, only webhooks, Desired State Configuration, and agent-based hybrid workers stop working ([disable local authentication](https://learn.microsoft.com/azure/automation/disable-local-authentication)); jobs bill per minute after the first 500 minutes a month, which are included ([pricing](https://azure.microsoft.com/pricing/details/automation/), checked 2026-11-05: "Free units included (per month)", not for rate plans with a flat discount or a fixed monthly credit).
- **Roles:** Contributor can't create role definitions or role assignments. Owner and User Access Administrator can do both; Role Based Access Control Administrator can assign roles but not define them ([privileged built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged), checked 2026-11-05).
- **The rules it touches:** [ADR 0008](0008-identity-rbac-abac.md)'s default creates no role assignments unless `assignRoles` is true. [ADR 0020](0020-on-demand-activity-control.md)'s role "DbHub Demo Activity Operator" and its assignments A1-A3 don't change without the owner, and that role can also start VMs and run commands.

## Decision drivers

1. Every deployment has it, without the optional on-demand activity control, its notebook, its webhook, or `setup-activity-control.ps1`.
2. It never starts anything, never connects to a database, and never uses Run Command ([ADR 0020](0020-on-demand-activity-control.md)'s rule for the stop path).
3. Least privilege: a role that can only read and stop, at the demo resource group only.
4. A Contributor's deployment still ends **DONE**: the missing role is a **Warning** with one command for an Owner, and DONE says what isn't covered until then.
5. Within the included job minutes; no hard-coded prices ([ADR 0016](0016-cost-profiles.md)).
6. Its results show in `status.ps1` and in the Automation account's job history.

## Considered options

| Option | How | Outcome |
|---|---|---|
| S1 | Its own identity and Automation account in the demo resource group, the existing `DbHub-Stop` runbook with two new scopes, and a new stop-only custom role | **Chosen** |
| S2 | The control's account, identity, and role | Rejected: the control is optional and off by default, and its role can start VMs and run commands as SYSTEM; widening its use changes A1-A3, which only the owner changes |
| S3 | PostgreSQL's own scheduled stop task | Rejected by the owner: it's created with a sign-in in the portal and acts with the deployer's account |
| S4 | A second, catch-up stop at 02:00 | Not selected by the owner |
| S5 | One job that waits 30 minutes for T3 | Rejected: about 31 job minutes a night, more than the included 500 a month |
| S6 | The role only with `assignRoles` true | Rejected by the owner (2026-11-05): an Owner would get the Owner's command anyway |

## Decision

### What it does

| When (in `autoShutdownTimeZone`) | Job | What it does |
|---|---|---|
| `autoShutdownTime` (19:00 by default) | `DbHub-Stop -Scope Nightly`, schedule `dbhub-safety-stop` | Deallocates `sqlvm01` and T2's VM (`archost01`, or `arcsql01` in the evaluation-only mode) unless they're deallocated or deallocating; a VM stopped from inside its guest still bills its compute, so it's deallocated too. Stops T4 when it's Ready; one that's starting (its 7-day restart), updating, restarting, or provisioning is read again every 30 seconds for up to 10 minutes, then stopped when it's Ready. The T2 guest shuts down with its host |
| 30 minutes later, or T3's auto-pause delay plus 15 minutes when that's longer (at most 345) | `DbHub-Stop -Scope T3Check`, schedule `dbhub-safety-t3check` | Reads T3's status and auto-pause delay through Azure Resource Manager only (Databases - Get) and says what it found: Paused, Pausing, Missing (`stop-demo.ps1 -RemoveT3`), AutoPauseOff (`t3AutoPauseMinutes` -1), TooEarly (online before the delay since the stop, plus 10 minutes, has passed), Awake (online after it: a session or a feature keeps it awake), or Unread. *(2026-11-09: then stops T4 when it runs, as the stop does, [below](#amendment-link-scopes-read-one-by-one-and-t4-at-the-t3-check-2026-11-09).)* |

- **Its DevTest Labs twin runs at the same minute:** when a VM's deallocation is refused with 409 Conflict, the VM's state is read again; deallocating or deallocated counts as done, and otherwise the request goes again, three times at most, 30 seconds apart.
- **Never more:** no start, no Run Command, no schedule of the control's, no database connection. The identity's role can't do more either ([below](#the-role-dbhub-demo-safety-stop)).
- **Its output** is the job's log and one result line, `DBHUB-STOP <json>`: `stop-nightly` with what happened to each VM and to T4, or `check-t3` with T3's status, its delay, and the minutes since the stop. A Nightly or T3Check job that couldn't do its work (`Partial`, or `NotGranted` when its identity can't read the demo resource group because its role isn't assigned) fails after that line, so the job history shows it.

### Its resources

| Resource | Settings |
|---|---|
| `id-<prefix>-<environment>-safetystop` | User-assigned identity; the runbook's only identity |
| `aa-<prefix>-<environment>-safetystop` | Automation account, Basic; only that identity; local authentication off (nothing starts it with a webhook); public network access on, as the control's account, which ran its cloud jobs live |
| `DbHub-Stop` | Windows PowerShell 5.1: `automation/runbooks/DbHub-Stop.ps1` with `DbHubControl.Common.ps1` and its own settings baked in (`purpose` `safety-stop`); published again only when the published content differs (Runbook - Get Content) |
| `dbhub-safety-stop` | Daily at `autoShutdownTime`, linked to `DbHub-Stop` with Scope `Nightly` |
| `dbhub-safety-t3check` | Daily at the check's time, linked to `DbHub-Stop` with Scope `T3Check` |

- `infra/safetystop/safetystop.bicep` deploys the identity and the account (resource group deployment `dbhub-safetystop`), with the demo's own tags (`solution`, `environment`, `owner`, `purpose`, `costCenter`, `autoShutdown`, `deploymentId`, `expiresOn`) and `component` = `safety-stop`, never deploy.ps1's state tags. The runbook, the schedules, and the role go through documented REST calls. All of it is in the demo resource group, so `destroy.ps1` deletes it with the group, and the residual check covers the identity and its assignment.
- A schedule that's disabled, at another time, or not linked once with its scope is created again, so the next `deploy.ps1` turns a disabled one on again and moves both when `autoShutdownTime` or `t3AutoPauseMinutes` changes. *(2026-11-09: each link's scope is read from the link itself, so a schedule that's right is kept, [below](#amendment-link-scopes-read-one-by-one-and-t4-at-the-t3-check-2026-11-09).)*

### The role: DbHub Demo Safety Stop

One custom role, assignable only in the configured subscription, with exactly these actions (owner-approved, 2026-11-05; they don't change without the owner):

- `Microsoft.Resources/subscriptions/resourceGroups/read`
- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/instanceView/read`
- `Microsoft.Compute/virtualMachines/deallocate/action`
- `Microsoft.Sql/servers/databases/read`
- `Microsoft.DBforPostgreSQL/flexibleServers/read`
- `Microsoft.DBforPostgreSQL/flexibleServers/stop/action`

It has no `NotActions` and no data actions. It can't start, create, change, or delete anything, has no Run Command, and has no Automation, Key Vault, Fabric, or role permission. All seven are also in [ADR 0020](0020-on-demand-activity-control.md)'s role, which adds the start, Run Command, and Automation actions this one leaves out ([permissions reference](https://learn.microsoft.com/azure/role-based-access-control/permissions/compute)). Its one assignment is to `id-<prefix>-<environment>-safetystop`, at `rg-<prefix>-<environment>` only. `tests/unit/DbHubDemo.SafetyStop.Tests.ps1` fails if the module's list and this one differ.

### Who assigns it: the owner's exception to ADR 0008 (2026-11-05)

- **`deploy.ps1`, on every run:** it creates or updates the role when the person who runs it has `Microsoft.Authorization/roleDefinitions/write` in the subscription (an Owner or a User Access Administrator), and assigns it when they have `Microsoft.Authorization/roleAssignments/write` on the demo resource group (also a Role Based Access Control Administrator once the role exists), with the principal type set, so a new identity needn't have replicated ([create a role assignment](https://learn.microsoft.com/rest/api/authorization/role-assignments/create)). This is the one role assignment the default path makes; it doesn't depend on `assignRoles`.
- **Otherwise:** `SAFETYSTOP.ROLE` is a **Warning**, never a **Fail**, with the exact command, and the run still ends **DONE**; DONE and the status page say that T4 isn't stopped after its 7-day restart until then, and that the VMs' nightly auto-shutdown and T3's auto-pause still apply. An Owner runs `./scripts/grant-safety-stop.ps1` once (`Invoke-DemoSafetyStopSetup -GrantRole`: the subscription guard, then the role and its assignment only).
- **After `destroy.ps1`:** the identity and its assignment go with the group; the role definition stays, unassigned and free (`DESTROY.SAFETYSTOP.ROLE` says so, with the `az role definition delete` command for an Owner who wants it gone), and the next deployment assigns it to its new identity.
- `validate.ps1 -Area Security` accepts this role at exactly the demo resource group (`SECURITY.RBAC.ROLEASSIGNMENTS`).

### Where it runs

- **`deploy.ps1`** sets it up on every run after the template (`Invoke-DemoSafetyStopSetup`): in the parallel path after the tracks get the template's handoff, so no track waits for it, a resumed run included; with `-StopAfter Infrastructure` before the run ends; and in `-Sequential` after the Infrastructure stage. Each step is idempotent, and every problem is a **Warning** (`SAFETYSTOP.RESOURCES`, `SAFETYSTOP.RUNBOOK`, `SAFETYSTOP.SCHEDULE`, `SAFETYSTOP.ROLE`).
- **`status.ps1`** (`STATUS.SAFETYSTOP`) and **`validate.ps1`**'s Cost area (`COST.SAFETYSTOP`) show its times, whether its role is assigned, what its last run stopped, and what its last T3 check found, from each job's result line (Job - List By Automation Account, Job - Get Output); a **Warning** names the fix when it isn't set up, can't act, didn't finish, or found T3 online past its delay.
- **`stop-demo.ps1`** (`STOP.T4.STOP`) and **`status.ps1`** (`STATUS.T4`) say that the nightly safety stop stops a restarted T4 again at the next auto-shutdown time, or what's missing (`Get-DemoT4RestartStopState`). *(2026-11-09: they name the run that stops it, its T3 check or its stop, with its time.)*
- **The job history:** `aa-<prefix>-<environment>-safetystop` > Process Automation > Jobs in the Azure portal.

### Cost

- **T4's restart worst case** ([ADR 0016](0016-cost-profiles.md)'s rule): with the nightly safety stop fully in place (its schedule, its role, and a last run that didn't fail), each 7-day restart counts as about a day, at most 4 a month, about 96 hours; otherwise the rest of the month, unless the control's own T4 safety stop is fully in place. On a first deployment the safety stop doesn't exist when preflight runs, so that run's preflight still counts the rest of the month (a **Warning** that says the run sets it up); the next preflight, `start-demo.ps1`, and `status.ps1` count it.
- **Job minutes:** two short jobs a night, about 2 to 4 minutes, more on a night it waits for a starting T4; the estimate counts a ceiling of 120 minutes a month at the meter's first tier, which is $0 while the subscription stays within the included 500.

### What stays the same

- The VMs' DevTest Labs auto-shutdown stays; the safety stop backs it up and covers T4.
- The control and its own daily T4 safety stop (`dbhub-t4-safety-stop`, 15 minutes after the shutdown) are unchanged. With both, the second finds T4 stopped. `CONTROL.SAFETYSTOP` passes without the control's schedule while the nightly one is in place.
- The Fabric capacity is never touched.
- **Skipping one night:** disable `dbhub-safety-stop` (and the VMs' auto-shutdown) in the portal; the next `deploy.ps1` turns it on again. *(2026-11-09: disable `dbhub-safety-t3check` too, which now stops T4.)*

## Consequences

- **Easier:** every deployment stops every database's compute each night with no person and no optional part; a forgotten T4 bills about a day after its restart instead of the rest of the month; the T3 check tells whether something keeps T3 awake overnight.
- **Harder:** a deployer who can't assign roles needs an Owner once per environment (and again after a destroy and redeploy); the subscription keeps one more custom role.
- **Accepted risks:**
  - A schedule can start its job a few minutes late, and the DevTest Labs shutdown races it; the 409 handling makes the race harmless.
  - The T3 check reports; it can't pause T3.
  - A restarted T4 bills until the next nightly stop, up to about a day. *(2026-11-09: until the T3 check when it starts between the stop and the check; one that starts just after the check still waits for the next evening's stop.)*
  - A subscription without the included job minutes (some rate plans) bills them at the meter's price, which the estimate reads at run time.

## Amendment: link scopes read one by one, and T4 at the T3 check (2026-11-09)

**Decision source:** user-directed (2026-11-09: "Yes, fix the status check and add the T4 re-stop (Recommended)"), after the live evidence below; engineering detail.

**Why (live, 2026-11-09, the owner's test environment `rg-dbhublt-demo`):**

- **The list has no parameters.** [Job Schedule - List By Automation Account](https://learn.microsoft.com/rest/api/automation/job-schedule/list-by-automation-account) returned `"parameters": null` for both links, as Learn's own sample answer does, while [Job Schedule - Get](https://learn.microsoft.com/rest/api/automation/job-schedule/get) of each link returned `{"Scope":"Nightly"}` and `{"Scope":"T3Check"}`, and the jobs ran with them.
- **The safety stop ran.** All six jobs of 2026-11-06, 07, and 08, at 19:00 and 19:30 Eastern, completed. The first stop said "sqlvm01 already deallocating, archost01 already deallocating, T4 stopped (was Ready)", and its T3 check found T3 Paused.
- **The module read the scope from the list.** So `STATUS.SAFETYSTOP` warned that the safety stop wasn't in place ("isn't linked to DbHub-Stop -Scope Nightly"), `STATUS.T4` said nothing stops a restarted T4, and the setup never matched a link: every `deploy.ps1` deleted and created both schedules and both links again, which the activity log showed at each of the four runs on 2026-11-06. The same read made the cost estimate count T4's restart for the rest of the month, and `CONTROL.SAFETYSTOP` miss the nightly safety stop.
- **The 7-day restart came just after the stop.** The stop of 2026-11-07 00:01Z had T4 stopped at 00:03Z, so Azure starts it again about 2026-11-14 00:03Z, 3 minutes after that evening's stop, which finds it stopped. T4 would then bill until the next evening, about a day (about 0.356 USD an hour for `Standard_D4ds_v5`, a dated example at list price on 2026-11-09), and the same each idle week, because the stop's own time sets the next restart.

**Decision:**

1. **Each link's scope comes from the link** (`Get-DemoSafetyStopLink`): the list gives the links of `dbhub-safety-stop` and `dbhub-safety-t3check`, and each one to `DbHub-Stop` is read again by its ID. The setup (`SAFETYSTOP.SCHEDULE`) keeps the schedules that are right, and `STATUS.SAFETYSTOP`, `COST.SAFETYSTOP`, `STATUS.T4`, `STOP.T4.STOP`, the cost estimate, and `CONTROL.SAFETYSTOP` read the safety stop as in place. A link that can't be read is a **Warning** in the setup, which then changes no schedule, and `Unknown` in the state; it's never taken as unlinked. Nothing else reads a link's parameters: the control's daily T4 safety stop and its state (`Set-DemoActivityControlSafetyStop`, `Get-DemoT4SafetyStopState`), and the auto-stop's cleanup in the module and in the runbook (`Clear-DbHubAutoStop`), match links by their schedule's and runbook's names only.
2. **The T3 check stops T4 when it runs** (`Invoke-DbHubT3Check`), after it reads T3, exactly as the stop does (`Invoke-DbHubT4NightlyStop`): a Ready T4 is stopped; one that's starting, updating, restarting, or provisioning is read again every 30 seconds for up to 10 minutes; one that's stopped, stopping, missing, disabled, or dropping is left alone. Its result line adds `t4` and `failed`, and its message ends with what happened to T4, as the stop's does ("T4 stopped (was Ready)", "T4 already stopped"). A T4 it couldn't stop makes it `Partial`, so its job fails after the line, and `STATUS.SAFETYSTOP` says "its last T3 check couldn't stop T4".
3. **Still stop-only:** no start, no Run Command, no database connection, and T3 is only read through Azure Resource Manager (Databases - Get), which never wakes it. The role doesn't change: the stop already uses `Microsoft.DBforPostgreSQL/flexibleServers/read` and `Microsoft.DBforPostgreSQL/flexibleServers/stop/action`, and the check needs nothing more.
4. **The texts name the run** that stops a restarted T4 (`Get-DemoSafetyStopRunAfter`, `Format-DemoT4RestartText`): its T3 check that evening when the restart comes between the stop and the check, otherwise the next evening's stop, with its time in UTC and in `autoShutdownTimeZone`. Without the restart's time they name both.

**What it doesn't close:** whichever run stops T4 sets its next restart, a week later and a minute or two after that run's time. After the T3 check's stop, the next restart comes just after the next week's check, so T4 runs until the following evening's stop, about 23.5 hours. So an idle T4 alternates: about half an hour one week, about a day the next, or about 12 hours a week on average instead of about 24. Closing it would take a run at the restart's own time, which this role can neither schedule nor find out (it has no Automation and no activity log permission), so it would need the owner's approval. The cost estimate's worst case stays about a day per restart.

**The schedules' start time:** Azure Automation wants a schedule's start at least five minutes ahead ([New-AzAutomationSchedule](https://learn.microsoft.com/powershell/module/az.automation/new-azautomationschedule)). `Get-DemoSafetyStopTime` gives the next time at least 10 minutes ahead, so creating a schedule never fails on it, but one created in the 10 minutes before its time first runs the next day. Before this amendment every `deploy.ps1` created both again, so a run that reached the safety stop's step in those 10 minutes skipped that evening's stop or check; now only a schedule that's wrong is created again.

**Also:**

- **The runtime** is still Windows PowerShell 5.1 (`runbookType` `PowerShell`), and the new code uses 5.1 syntax only; a unit test dot-sources the shared code in `powershell.exe` 5.1.
- **Skipping one night** takes both schedules turned off now, or the T3 check stops T4.
- **An evening session started after the shutdown time** loses T4 at the check's time, as it does at the control's daily T4 safety stop ([ADR 0020](0020-on-demand-activity-control.md)): the check can't tell who started T4.
- **Until `deploy.ps1` publishes the new `DbHub-Stop`** (`SAFETYSTOP.RUNBOOK` says "now"), the T3 check doesn't stop T4, though `STATUS.T4` already says it does.

## Validation

- **Static (2026-11-05):** `tests/unit/Automation.Runbooks.Tests.ps1` (the Nightly scope: running VMs deallocated and T4 stopped through Azure Resource Manager only, deallocated and deallocating VMs and a stopped T4 left alone, a guest-stopped VM deallocated, a 409 while the auto-shutdown deallocates counted as done, a 409 that lasts tried three times then reported, a starting T4 waited for and stopped, one still starting after 10 minutes reported and never started, NotGranted without the role; the T3Check scope: each verdict from one Databases - Get and nothing else; the published content and its settings), `tests/unit/DbHubDemo.SafetyStop.Tests.ps1` (names, the role against this ADR, the times, the setup as an Owner, a Contributor, and a Role Based Access Control Administrator, a rerun that writes nothing but the template, a disabled schedule, a changed runbook or role, a failed template, `-WhatIf`, `-GrantRole`, the state, the last runs and the status, `Get-DemoT4RestartStopState`, a DONE with only the role missing, and `grant-safety-stop.ps1`), `tests/unit/DbHubDemo.T4.Tests.ps1` and `DbHubDemo.Cost.Tests.ps1` (the restart worst case and the texts), and the template's build and lint in `./tests/Invoke-StaticValidation.ps1`.
- **Static (2026-11-09):** the fake Azure in `tests/unit/DbHubDemo.SafetyStop.Tests.ps1` answers as live: its list of job schedules returns `"parameters": null`, and only Job Schedule - Get returns a link's scope. Tests: a rerun keeps both schedules with one read per link and writes nothing; a correct schedule is kept minutes before its time; a link with another scope is created again; a link that can't be read is a **Warning** that changes no schedule, and `Unknown` in the state; the status shows what the T3 check did to T4 and warns when it couldn't stop it; `Get-DemoT4RestartStopState`'s `CheckStopsT4`; and `Get-DemoSafetyStopRunAfter` (the live case, a restart just after the check, without the check, a check after midnight, and across daylight saving time). `tests/unit/Automation.Runbooks.Tests.ps1`: the T3 check reads T3, then T4; stops a Ready T4 through Azure Resource Manager only; waits for a starting one; leaves a stopped, stopping, or disabled one alone; and reports one it couldn't stop as `Partial`, never starting anything. `tests/unit/DbHubDemo.T4.Tests.ps1`, `.Lifecycle`, and `.T4Fallback`: the texts that name the run.
- **Live (2026-11-06 to 2026-11-08, the owner's test environment):** all six jobs, the stops and T3 checks of three evenings, ran and completed; the first stop stopped a Ready T4, and its check found T3 Paused. The same check found the list's missing parameters ([above](#amendment-link-scopes-read-one-by-one-and-t4-at-the-t3-check-2026-11-09)).
- **Live, still to do:** after the 2026-11-09 changes, the safety stop's setup alone on an existing environment (see the implementation report's [still to verify](../implementation-report.md#still-to-verify)), with `SAFETYSTOP.SCHEDULE` keeping both schedules (no `jobSchedules/delete` or `schedules/write` in the activity log) and `SAFETYSTOP.RUNBOOK` publishing; then `STATUS.SAFETYSTOP` **Pass** and `STATUS.T4` naming the run; and a T3 check's job output with its T4 line. Not yet run at all: the same `deploy.ps1` as a Contributor (DONE with the Warning and the note), then `./scripts/grant-safety-stop.ps1` as an Owner; and `destroy.ps1` with `DESTROY.SAFETYSTOP.ROLE` and a clean residual check.

## Sources

Checked 2026-11-05; the job schedules' and schedules' start entries on 2026-11-09.

- Azure SQL Database: [serverless auto-pause and auto-resume](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume), [monitor pause and resume status](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-monitor#monitor-pause-and-resume-status)
- PostgreSQL flexible server: [stop a server](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server)
- Compute: [Virtual Machines - Deallocate](https://learn.microsoft.com/rest/api/compute/virtual-machines/deallocate), [auto-shutdown a VM](https://learn.microsoft.com/azure/virtual-machines/auto-shutdown-vm)
- Azure Automation: [schedules](https://learn.microsoft.com/azure/automation/shared-resources/schedules), [user-assigned identity](https://learn.microsoft.com/azure/automation/add-user-assigned-identity), [disable local authentication](https://learn.microsoft.com/azure/automation/disable-local-authentication), [pricing](https://azure.microsoft.com/pricing/details/automation/), REST: [Runbook - Get Content](https://learn.microsoft.com/rest/api/automation/runbook/get-content), [Runbook Draft - Replace Content](https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content), [Runbook - Publish](https://learn.microsoft.com/rest/api/automation/runbook/publish), [Schedule - Create Or Update](https://learn.microsoft.com/rest/api/automation/schedule/create-or-update), [Job Schedule - Create](https://learn.microsoft.com/rest/api/automation/job-schedule/create), [Job Schedule - List By Automation Account](https://learn.microsoft.com/rest/api/automation/job-schedule/list-by-automation-account), [Job Schedule - Get](https://learn.microsoft.com/rest/api/automation/job-schedule/get), [Job - List By Automation Account](https://learn.microsoft.com/rest/api/automation/job/list-by-automation-account), [Job - Get Output](https://learn.microsoft.com/rest/api/automation/job/get-output); a schedule's start at least five minutes ahead: [New-AzAutomationSchedule](https://learn.microsoft.com/powershell/module/az.automation/new-azautomationschedule)
- Roles: [privileged built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged), [permissions reference](https://learn.microsoft.com/azure/role-based-access-control/permissions/compute), [create or update a role definition](https://learn.microsoft.com/rest/api/authorization/role-definitions/create-or-update), [create a role assignment](https://learn.microsoft.com/rest/api/authorization/role-assignments/create), [delete a custom role](https://learn.microsoft.com/azure/role-based-access-control/custom-roles-cli#delete-a-custom-role)
