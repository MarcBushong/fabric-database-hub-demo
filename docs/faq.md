# FAQ

## Getting started

**What do I need?**
Contributor on an Azure subscription, a running F or Trial Fabric capacity, Database Hub turned on in your Fabric tenant (a Fabric administrator's setting), and the tools: PowerShell 7.4, the Azure CLI with Bicep, Node.js, and Git, which the repository's dev container has. `deploy.ps1`'s first run creates the security group that administers T3 and T4, with you as its owner, where your tenant lets you create groups. Recommended, once per environment: an Owner, who deploys or runs `./scripts/grant-safety-stop.ps1` once to grant the nightly safety stop's and the session control's roles together (P15, P16). Without them the deployment still ends **DONE**, but nothing stops T4 on its own after Azure's 7-day restart, and Run all can't start a session. For Ask, the Copilot chat in the Insights app, each viewer needs their own GitHub account with a GitHub Copilot plan. The full list, P1 to P16, with who provides each item, is in [prerequisites](prerequisites.md).

**Do I have to change my Azure CLI default subscription?**
No. If you aren't signed in to the demo's tenant, sign in yourself with `az login --tenant <tenantId>` and press Enter at the subscription selector for no changes. Every Azure call names the configured subscription, and the subscription guard checks that subscription's tenant and account before anything is written; the scripts never sign in or change your default. On a shared machine you can give the demo its own Azure CLI profile ([prerequisites](prerequisites.md#optional-a-separate-azure-cli-profile)).

**What's the one command?**
`./scripts/deploy.ps1`, after `az login`. It writes your configuration on its first run, deploys everything ([what's deployed](../README.md#whats-deployed-and-by-what)), waits for T2, which needs no person, deploys the Insights app with your `az login` (a browser sign-in only if Fabric refuses that token, which nothing but the app waits for), sets up the nightly safety stop and the session control, keeps your PC awake, shows a live status page, and ends **DONE** or **NOT DONE** with the exact next command. Run it again with no parameters to continue where it stopped. The same command updates an existing demo ([upgrading an existing demo](../README.md#upgrading-an-existing-demo)), and nothing in it needs GitHub Actions.

**How long does the first deployment take?**
About 1.5 hours in the default `JumpstartImage` mode: a clean first deployment took 91 minutes, measured on 2026-11-06, before T4's read replica, T5, and Ask joined the deployment. Most of it is T2, whose host downloads Arc Jumpstart's prebuilt SQL Server guest disk (34 GiB) and prepares it, about 27 minutes, then onboards it to Azure Arc, about 33, with no person needed. `ProductKey` and `Developer` take about 1.5 to 2.5 hours (an estimate from documented step times), mostly the T2 guest build, which downloads about 6.2 GB of media, with no person for T2 either. The Insights app deploys with your `az login` (since 2026-11-09); only if Fabric refuses that token does its browser sign-in take a person about a minute (an estimate). Later runs skip what's already in place, and a redeploy from an optional golden snapshot takes about 30 to 45 minutes (an estimate). The [deployment guide](deployment.md#expected-duration) records the measured durations.

**Is it safe to run `deploy.ps1` again?**
That's the design: every stage is idempotent, state lives in the resource group's tags, and Arc onboarding detects an existing machine instead of creating a duplicate (`T2.ARC.NODUPLICATES`). Reruns on the live environment converged with no duplicate Arc resources in Phases 20 and 22 ([acceptance checklist](implementation-report.md#acceptance-checklist)).

## Design choices

**Why Standard edition instead of Developer?**
Hub Performance needs Standard or Enterprise. On Developer, SQL VMs report only connection data, and Arc monitoring isn't supported ([ADR 0006](adr/0006-sql-editions-and-licensing.md)).

**Why a nested Hyper-V guest for the "on-premises" server?**
The Arc agent isn't supported on Azure VMs except for evaluation. A nested guest is a separate machine that can be Arc-enabled, and it worked live. The demo discloses it as a simulated on-premises server, never a real one.

**Is there a manual step on T2?**
Not in the default `JumpstartImage` mode: the T2 host downloads [Arc Jumpstart](https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md)'s prebuilt SQL Server 2022 Standard guest disk, makes it `arcsql01` at first boot while it has no network, checks it, and onboards it to Azure Arc with pay-as-you-go and monitoring, with no person, no product key, and no Bastion. Nor in any other mode since 2026-11-09, when `PaygWizard` was retired from the one-click deployment: in that mode a person chose pay-as-you-go in the setup wizard once per guest build, because pay-as-you-go SQL Server without a product key is documented only there. A configuration that says `PaygWizard` runs as `JumpstartImage`. `ProductKey` mode (P10) is fully unattended; `Developer` mode is unattended but gives T2 Estate only ([ADR 0006](adr/0006-sql-editions-and-licensing.md)).

**Can an AI assistant run the deployment for me?**
Yes: [AGENTS.md](../AGENTS.md) tells an assistant to run `./scripts/deploy.ps1`, never to assemble a setup by hand, and to report **DONE** or **NOT DONE** ([deployment](deployment.md#running-it-with-an-ai-assistant)). In the default `JumpstartImage` mode, T2 needs no person, and `ProductKey` mode is fully unattended too. Three steps stay with people: `az login`; selecting T3 for Database Agents once per deployment, which has no API; and each viewer's GitHub sign-in for Ask. The Insights app deploys with your `az login`. Only if Fabric refuses that token does the app need the Rayfin CLI's browser sign-in, which `deploy.ps1` doesn't start in a session that can't take keyboard input, so then run `./scripts/configure-fabric-app.ps1 -SignIn` yourself in a terminal; without it the run still ends **DONE**. When you aren't an Owner, **DONE** also prints `./scripts/grant-safety-stop.ps1` for an Owner to run once.

**Where are secrets kept?**
No VM password is stored: each is used once and discarded, and break-glass access is a VMAccess reset ([ADR 0009](adr/0009-secrets-handling.md)). Every deployment has the session control's Key Vault, `kv-<prefix>-ctl-<suffix>`, which holds the webhook's URL and the session's status and metrics, never a password. Contributor creates it; reading the webhook's secret from the control notebook needs a role, which `deploy.ps1` grants when you may assign roles, and otherwise an Owner's `./scripts/grant-safety-stop.ps1`. A separate vault for the T2 host's one-time password is opt-in and off by default (`keyVault.enabled`, with `assignRoles`; [deployment](deployment.md#opt-in-the-password-in-key-vault-instead-of-the-clipboard)).

**Why does `deploy.ps1` create role assignments when I'm an Owner?**
For the nightly safety stop and the session control, the owner-approved exceptions to the Contributor-only default. The safety stop's role, "DbHub Demo Safety Stop", can only read the demo's resources, deallocate its VMs, stop T4, and delete T5's container, at the demo resource group. The session control's roles, "DbHub Demo Activity Operator" and "DbHub Demo Session Writer", let Run all start, run, and stop a session. When you can't assign roles, nothing is assigned: the run still ends **DONE** and prints the one command for an Owner, `./scripts/grant-safety-stop.ps1`, which grants all of them ([ADR 0024](adr/0024-nightly-safety-stop.md), [ADR 0026](adr/0026-one-run-all-session.md), [permissions](permissions.md#the-nightly-safety-stop)).

**Can I use Fabric mirroring with this demo?**
Not in v1. Hub doesn't need it. A future optional add-on would need a running capacity and, depending on the source, vCore Azure SQL, a gateway, or SQL Server 2025 with Arc ([ADR 0015](adr/0015-mirroring-deferral.md)).

## Database Hub, Copilot, and Database Agents

**Does the repo automate Database Agents?**
Almost. Database Agents has no API, so once per deployment you select T3 in Database Hub's **Manage agents** > **Database agent settings**, about 30 seconds; **DONE** lists it under **Please confirm** (`HUB.AGENT.T3`), with the steps ([demo it yourself](../README.md#demo-it-yourself)). Then the agent raises issues on T3 by itself, Copilot explains them, and Run all makes the manual response during a session. The agent never changes a database itself: every response is a manual one. The repo produces the signals, validates the prerequisites, and provides prompts and fallbacks ([ADR 0013](adr/0013-agent-experience.md)).

**Which targets does Database Agents cover?**
Azure SQL Database, so T3 here, once it's selected ([the Database Agent loop](demo-walkthrough.md#the-database-agent-loop-on-t3)). For Azure Database for PostgreSQL (T4) it's a limited preview in Visual Studio Code, not in Database Hub, and it doesn't cover SQL Server on an Azure VM or enabled by Azure Arc (T1, T2), or Azure Cosmos DB (T5) ([Database Agents](https://learn.microsoft.com/fabric/database/hub/database-agents)). You investigate incidents on every target with Copilot in Database Hub, whose own target coverage isn't documented yet: the SQL incidents run on T1, T2, and T3, T4 has the replica-lag beat, and T5 the RU storm. The [live coverage record](../fabric/agent/README.md#live-coverage-record) captures what Copilot and the agent covered in your tenant, with dates.

**How long until a new target shows up in Hub?**
Performance telemetry arrives a few minutes after the activity: live, T3's first sample came 2.8 minutes after it was created, and T2's 7 minutes after monitoring was turned on. Allow up to 15 minutes, and use `validate.ps1` or the walkthrough's readiness gates before a session.

**Can the notebooks start or stop the demo?**
Not directly: Fabric notebooks can't get an Azure Resource Manager token. Since 2026-11-14 the session control notebook, `NB_DatabaseHub_Control`, runs a whole demo session through the control's Azure Automation webhook, with one Run all and no GitHub ([ADR 0026](adr/0026-one-run-all-session.md)).

**What does Ask, the Copilot chat in the Insights app, need?**
Each viewer's own GitHub account with a GitHub Copilot plan, signed in once per browser; there's nothing to install or register. Its chat relay, which `deploy.ps1` deploys with the Insights app, bills only while someone asks and scales to zero about 10 minutes after the last question. In some tenants, an owner of the GitHub organization that gives you Copilot approves **Database Hub Insights Ask** once, and the Fabric tenant setting "Enforce a strict content security policy for static-hosted Fabric Apps (preview)" must stay off, as it is by default ([the Copilot chat](../README.md#the-copilot-chat-in-the-insights-app)). `"ask": { "enabled": false }` in your configuration leaves it out.

## Cost and lifecycle

**What does it cost?**
`./scripts/estimate-cost.ps1` prices it from Azure's list prices at run time, with no sign-in. The ceilings are $20 a session (`sessionCeilingUsd`, a **Warning** above it) and $415 a month for a new configuration (`monthlyCeilingUsd`, a hard ceiling: preflight fails above it; a configuration keeps its own value); [cost management](cost-management.md#at-a-glance) has dated examples. Outside every estimate: the Fabric capacity, Fabric and Power BI licenses, and each viewer's GitHub Copilot plan.

**Do I need a Fabric capacity?**
Not for Database Hub's own views: each Hub user needs only a Fabric Free license (P4). Copilot in Database Hub, Run all, the notebooks, the Real-Time Dashboard, the Power BI report, and the Insights app need a workspace on a running F or Trial capacity (P5). You or its administrator resume it before Run all, which never resumes it, and pause it afterward: a paid capacity bills by the hour while it runs, outside every estimate ([cost management](cost-management.md#microsoft-fabric-capacity)).

**How do I stop paying between demos?**
`./scripts/stop-demo.ps1` deallocates the VMs, stops T4, deletes T4's read replica and T5's container, which the next session creates again, and lets T3 auto-pause; a Run all session does the same at its end. If you forget, the VMs' auto-shutdown and the nightly safety stop stop the demo every evening at `autoShutdownTime` ([what stops or pauses on its own](../README.md#what-stops-or-pauses-on-its-own)). `-ParkT2` stops only T2, and `-RemoveT3` deletes T3 until the next start, after which you select T3 for Database Agents again. Pause the Fabric capacity when no workspace needs it. `./scripts/destroy.ps1` removes everything ([delete everything](../README.md#delete-everything)).

**Why is T5's container gone between sessions?**
An Azure Cosmos DB account has no stop, so since 2026-11-19 T5's container, which holds its 400 RU/s, exists only during a session: `./scripts/start-demo.ps1` and Run all create it; `./scripts/stop-demo.ps1`, a session's auto-stop, and the nightly safety stop delete it, and so does the control's daily T4 safety stop when the VMs are stopped. Between sessions only T5's private endpoint and DNS zone bill. Until the session control's role can create the container again, it stays between sessions and bills all month: an Owner runs `./scripts/grant-safety-stop.ps1` once, or `./scripts/deploy.ps1` as an Owner ([cost management](cost-management.md#t5-azure-cosmos-db-2026-11-18)).

**How do I update an existing demo?**
Run `./scripts/deploy.ps1`. It first updates a clean checkout of `main` from GitHub, then upgrades what's deployed, with no edit to your configuration; nothing changes until you run it ([upgrading an existing demo](../README.md#upgrading-an-existing-demo)).

**How do I rebuild the T2 guest before its evaluation OS expires?**
Only the build modes (`ProductKey` and `Developer`, and a kept `PaygWizard` guest) use the Windows Server evaluation, which lasts 180 days; the default `JumpstartImage` guest's Windows Server 2022 Standard isn't an evaluation. Since 2026-11-05 the host rearms an evaluation guest by itself when 30 or fewer days are left and a rearm is left, and warns you to rebuild T2 when none is. `reset-demo.ps1 -RebuildGuest` isn't supported yet, so rebuild with `destroy.ps1`, then `deploy.ps1` ([limitations](limitations.md#targets-and-licensing)).

**How do I delete everything, and what stays?**
`./scripts/destroy.ps1` deletes everything `deploy.ps1` created for the environment in your configuration, each part only when it can tell it's this environment's. What stays: the Fabric capacity and your licenses; the golden snapshot group `rg-<prefix>-golden`, until `-IncludeGolden`; a security group you supplied; role assignments your tenant made; and each viewer's GitHub authorization of **Database Hub Insights Ask**, which each viewer revokes in GitHub's settings under **Applications** > **Authorized OAuth Apps** (**Sign out of GitHub** in the chat's account menu clears a browser's sign-in) ([delete everything](../README.md#delete-everything)).

**Can I run it without GitHub?**
Yes. Nothing needs GitHub Actions: deploying, sessions, and deleting all run from PowerShell or the control notebook. Only Ask, the Copilot chat in the Insights app, needs GitHub: each viewer signs in with their own account and Copilot plan, and everything else works without it. The workflows are optional, for maintainers. In a copy of this repository, the demo's schedules run only when the repository variable `DBHUB_SCHEDULES_ENABLED` is `true`, and the static checks and CodeQL run on a push or a pull request only when the repository is public or you set `STATIC_CHECKS_ENABLED` or `CODE_SCANNING_ENABLED`. A run by hand always runs.

**Where do I report a security problem?**
Privately, as [SECURITY.md](../SECURITY.md) describes. Never include secrets, tokens, or subscription or tenant IDs.
