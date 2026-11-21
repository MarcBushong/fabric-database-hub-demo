# FAQ

Short answers, each with a link to the page that has the details.

## Getting started

**What do I need?**
Contributor on an Azure subscription, a running F or Trial Fabric capacity, Database Hub turned on in your Fabric tenant, and PowerShell 7.4, the Azure CLI with Bicep, Node.js, and Git, which the dev container has ([prerequisites](prerequisites.md)). Recommended: an Owner, once, for `./scripts/grant-safety-stop.ps1`; without it, nothing stops T4 after Azure's 7-day restart, and Run all can't start a session. For Ask, each viewer's own GitHub Copilot plan.

**What's the one command?**
`./scripts/deploy.ps1`, after `az login`. It writes your configuration on its first run, deploys everything ([what's deployed](../README.md#whats-deployed-and-by-what)), and ends **DONE** or **NOT DONE** with the next command. Run it again to continue, or to update and upgrade an existing demo ([upgrading](../README.md#upgrading-an-existing-demo)); every stage is idempotent.

**Do I have to change my Azure CLI default subscription?**
No: every call names the configured subscription, and the scripts never sign in or change your default ([the subscription guard](troubleshooting.md#sign-in-and-the-subscription-guard)).

**How long does the first deployment take?**
About 1.5 hours in the default mode, with nobody needed: 91 minutes, measured on 2026-11-06, before T4's read replica, T5, and Ask joined ([expected duration](deployment.md#expected-duration)).

**Can an AI assistant run it?**
Yes, as [AGENTS.md](../AGENTS.md) says ([deployment](deployment.md#running-it-with-an-ai-assistant)). People keep `az login`, the Database Agents selection (required once for the Database Agent beat; [step by step](database-agents.md)), each viewer's GitHub sign-in, an Owner's grant, and, only if Fabric refuses the Azure CLI's token, `./scripts/configure-fabric-app.ps1 -SignIn`.

## During a demo

**How do I run a session?**
Resume the Fabric capacity, open `NB_DatabaseHub_Control`, and select **Run all**: it starts everything, runs the 90-minute showcase, stops everything, and saves the history ([the session control notebook](../fabric/control/README.md)).

**Does the repo automate Database Agents?**
Almost: it has no API, so once per deployment you select T3 in Database Hub's **Manage agents**, a minute or two (`HUB.AGENT.T3`, under **Please confirm**). It's required for the Database Agent beat, and everything else works without it; the agent never changes a database, and Run all makes the manual response ([step by step](database-agents.md)).

**Which targets does Database Agents cover?**
Azure SQL Database, so T3 ([the loop](demo-walkthrough.md#the-database-agent-loop-on-t3)); PostgreSQL (T4) only in a Visual Studio Code preview, and not T1, T2, or T5 ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)). Copilot in Database Hub investigates every target's incidents ([live coverage](../fabric/agent/README.md#live-coverage-record)).

**How long until a target shows up in Database Hub?**
3 to 15 minutes after its activity starts; `./scripts/validate.ps1` confirms it.

**What does Ask, the Copilot chat in the Insights app, need?**
Each viewer's GitHub account with a Copilot plan, signed in once per browser; an organization that restricts OAuth apps approves **Database Hub Insights Ask** once; and the strict content security policy setting for Fabric Apps stays off. Its relay bills only while someone asks ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app)).

**Do I need a Fabric capacity?**
Not for Database Hub's own views (a Fabric Free license). Copilot, Run all, the notebooks, the dashboard, the report, and the Insights app need a running F or Trial capacity, which you resume and pause; it bills outside every estimate ([Fabric capacity](cost-management.md#microsoft-fabric-capacity)).

## Cost and lifecycle

**What does it cost?**
`./scripts/estimate-cost.ps1` prices it from Azure's list prices. Ceilings: $20 a session (`sessionCeilingUsd`, a **Warning** above it) and $415 or more a month for a new configuration, from its region's worst case (`monthlyCeilingUsd`, a hard ceiling: preflight fails above it; a configuration keeps its own value); [cost management](cost-management.md#at-a-glance). Not included: the Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan.

**How do I stop paying between demos?**
`./scripts/stop-demo.ps1` deallocates the VMs, stops T4, deletes T4's read replica and T5's container, and lets T3 auto-pause; Run all does it at a session's end, and the nightly safety stop every evening ([what stops on its own](../README.md#what-stops-or-pauses-on-its-own)). Pause the capacity too.

**Why is T5's container gone between sessions?**
Azure Cosmos DB can't stop, so the container, with its 400 RU/s, exists only during a session; until the session control's role can create it again (an Owner's grant), it stays and bills ([T5's cost](cost-management.md#t5-azure-cosmos-db-2026-11-18)).

**How do I delete everything, and what stays?**
`./scripts/destroy.ps1`. What stays: the capacity and licenses, `rg-<prefix>-golden` until `-IncludeGolden`, a group you supplied, tenant-made role assignments, and each viewer's GitHub authorization of **Database Hub Insights Ask**, revoked at <https://github.com/settings/applications> ([delete everything](../README.md#delete-everything)).

**Can I run it without GitHub?**
Yes: only Ask needs GitHub, for each viewer's sign-in. GitHub Actions is optional, for maintainers ([GitHub Actions](deployment.md#one-click-github-actions)).

## Design choices

**Why Standard edition instead of Developer?**
Database Hub's Performance views need Standard or Enterprise: on Developer, SQL VMs report only connection data, and Arc monitoring isn't supported ([ADR 0006](adr/0006-sql-editions-and-licensing.md)).

**Why a nested Hyper-V guest for the "on-premises" server?**
The Arc agent isn't supported on Azure VMs except for evaluation, and a nested guest can be Arc-enabled; the demo discloses it as simulated. It comes from [Arc Jumpstart](https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md)'s SQL Server 2022 Standard image, with no setup wizard.

**Where are secrets kept?**
No VM password is stored: each is used once ([ADR 0009](adr/0009-secrets-handling.md)). The session control's Key Vault holds its webhook's URL and the session's status, never a password. A vault for the T2 host's one-time password is opt-in ([deployment](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard)).

**Why does `deploy.ps1` create role assignments when I'm an Owner?**
For the nightly safety stop and the session control, the owner-approved exceptions to Contributor-only; without Owner, **DONE** prints `./scripts/grant-safety-stop.ps1` for one ([permissions](permissions.md#the-nightly-safety-stop)).

**Can I use Fabric mirroring with this demo?**
Not in v1; Database Hub doesn't need it. A future optional add-on would need a running capacity and, depending on the source, vCore Azure SQL, a gateway, or SQL Server 2025 with Arc ([ADR 0015](adr/0015-mirroring-deferral.md)).

**Where do I report a security problem?**
Privately, as [SECURITY.md](../SECURITY.md) describes, without secrets, tokens, or subscription or tenant IDs.
