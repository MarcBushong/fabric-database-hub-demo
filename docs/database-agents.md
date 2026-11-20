# Database Agents for T3: the one-time setup

**Required once for the Database Agent beat; everything else works without it.** The beat is the walkthrough's [Database Agent loop on T3](demo-walkthrough.md#the-database-agent-loop-on-t3): in every Run all session, T3's plan regresses, Database Agents raises an issue on it, Copilot explains the issue, and Run all makes the manual response. Database Agents (preview) has no API, so no script can select T3 for it: **DONE** and the status page list this step under **Please confirm** (`HUB.AGENT.T3`), with Database Hub's link in your tenant and T3's exact name, `azuresql01-<deploymentId>/ContosoCare`. It takes a minute or two. Without it, T3's regression, the response, and T3's CPU drop still run in every session, but Database Agents raises no issue.

Database Agents in Database Hub covers Azure SQL Database, so T3 only: not T1 or T2 (SQL Server on an Azure VM, and SQL Server enabled by Azure Arc), not T4 (Database Agents for PostgreSQL is a limited preview in Visual Studio Code only), and not T5 (Learn lists no Azure Cosmos DB support) ([supported databases and servers](https://learn.microsoft.com/fabric/database/hub/database-agents#supported-databases-and-servers)).

What's marked "observed" was seen in the owner's tenant on 2026-11-20; the rest is from Microsoft Learn.

## Before you start

- **Your access:** a **Save** checks your Azure write access on every selected database (`Microsoft.Sql/servers/databases/write`) and fails as a whole when one fails ([enable Database Agents](https://learn.microsoft.com/fabric/database/hub/enable-database-agents#prerequisites)). The account that deployed the demo has it on T3; `./scripts/validate.ps1 -Area T3` checks yours (`T3.AGENT`).
- **T3's region:** it must be your Fabric tenant's home region, which Fabric shows under **?** > **About Fabric**; `HUB.AGENT.T3` names T3's region ([another region](https://learn.microsoft.com/fabric/database/hub/database-agents-known-limitations#a-database-or-server-is-in-another-region)).
- **Right after a first `deploy.ps1`:** T3 joins the list about 15 minutes after its performance monitoring is turned on, which `deploy.ps1` does ([enable and activate](https://learn.microsoft.com/fabric/database/hub/enable-database-agents#enable-and-activate-database-agents)).
- **T3 can be paused:** paused serverless databases saved fine (observed), so you can do this with the demo stopped. The agent evaluates T3 only while it's awake, so its issues come during a session.
- **Who else uses Database Agents in your tenant?** The selection is saved for the whole tenant, so step 3 has two cases: a demo or lab tenant that only you use, and a tenant others use too.

## Step by step

1. **Open the settings:** Database Hub, from the link `HUB.AGENT.T3` gives, then **Agent (preview)**, then **Manage agents** (upper left), then **Database agent settings**.
2. **Turn Enabled on.** The panel says "All databases are included by default" and "Your saved configuration is reflected in the table" (observed): every database you can see starts selected, and the table shows what's saved for the tenant. Its rows show only each database's name, `ContosoCare` for every environment's T3, with no server and an empty **Owner** column (observed).
3. **Select T3, for your tenant's case:**
   - **Only you use Database Agents in this tenant** (a demo or lab tenant):
     1. **Reset:** clear the selection, and select **Save** with nothing selected. A save with "0 of 19 selected" succeeded (observed).
     2. **One `ContosoCare` row:** that's T3. Check it and select **Save**.
     3. **Several `ContosoCare` rows:** check one and select **Save**; keep it when the save succeeds, and uncheck it again when it fails. Do the same with the next row. A row whose database no longer exists fails, and one that exists saves: 3 of 19 saved, the 3 that still existed (observed). Every `ContosoCare` database that exists stays selected, another environment's included; Database Agents doesn't change a database without your action, so there it only raises issues ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents#4-track-issue-status)).
   - **Others use Database Agents in your tenant:** don't clear or uncheck their databases: unchecking one stops the agent watching it for whoever selected it. Check T3 in addition, and select **Save**. If the save fails because of a database you can't write to, ask whoever manages Database Agents in your tenant to add T3, rather than removing theirs.
4. **Agent policy:** open **Agent policy** for T3 (the gear on its row), and under **Enabled** turn on **Flag long-running queries** and **Force last known good plans** (Query performance) and **Flag high CPU** (Resource pressure and contention). Select **Apply**, then **Save**. In a demo or lab tenant, give each `ContosoCare` row you kept the same policy. These are UI labels: turning one on doesn't authorize or run a database change ([enable and activate](https://learn.microsoft.com/fabric/database/hub/enable-database-agents#enable-and-activate-database-agents)).

## Check it

- **The save completed without an error:** that's what says T3 is enrolled.
- **Database agent settings shows the green "Database agent is active":** that's about the agent, not about T3; it isn't a status for each database ([verify the outcome](https://learn.microsoft.com/fabric/database/hub/enable-database-agents#verify-the-outcome)).
- **A save that's "temporarily limited"** (observed, after saves in quick succession): wait a few seconds, then select **Save** again.

## In a session

- **The issue:** Database Agents raises one about 15 minutes after a condition starts on an enrolled database with the matching policy option ([a new issue doesn't appear](https://learn.microsoft.com/fabric/database/hub/database-agents-known-limitations#a-new-issue-doesnt-appear)): about 15 minutes after T3's plan regresses, a new one each session. T3 is awake then, as it is through a session.
- **Explain why and Analyze slow query** use Copilot: they need administrator-assigned Copilot capacity and Copilot's tenant and capacity settings for your user ([investigate with contextual AI](https://learn.microsoft.com/fabric/database/hub/review-performance-issue#investigate-with-contextual-ai); P17 in [prerequisites](prerequisites.md#optional)). Without them, the issue and its evidence still show.
- **Its close:** an issue closes after the manual response, or once monitoring determines that the condition cleared. **Closed** is its final status, and it stays in the history; a condition that comes back opens a new issue ([issue history and recurrence](https://learn.microsoft.com/fabric/database/hub/database-agents#5-review-issue-history-and-recurrence)). Run all makes the response at 85% of the beat, and T3's CPU falls a minute later ([the loop](demo-walkthrough.md#the-database-agent-loop-on-t3)).

## When to do it again

- **Once per deployment:** the selection stays through sessions, stops, starts, and updates (`./scripts/deploy.ps1` on an existing environment).
- **After T3 is recreated:** `./scripts/stop-demo.ps1 -RemoveT3`, then `./scripts/start-demo.ps1`, which creates T3 again; or a new deployment after `./scripts/destroy.ps1`, whose T3 has a new name. `HUB.AGENT.T3` names it.
- **When you delete the demo:** uncheck only your T3 and select **Save**, before or after `./scripts/destroy.ps1`, which reminds you before it asks and at its end (`DESTROY.HUB.AGENT.T3`). Deleted databases can stay in the list for a while (observed: 19 `ContosoCare` rows, of which 3 still existed), and while one is selected, every save there fails, anyone's in your tenant ([cleanup](cleanup.md#what-stays-and-how-to-remove-it)).

## When something goes wrong

[Troubleshooting](troubleshooting.md#database-agent-settings) has each case: the save error "Database agent changes couldn't be saved", look-alike `ContosoCare` rows, a save that's "temporarily limited", no PostgreSQL or Cosmos DB in the list, and no issue on T3.
