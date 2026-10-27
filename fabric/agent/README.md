# Database agent prompt pack and install guide

How to show the Database Agent in Database Hub (preview) safely, and how to install and use the documented, scriptable fallback: GitHub Copilot CLI (the primary host) or VS Code with the `microsoft-sql-fdh` and `microsoft-sql` plugins, the telemetry agent instructions on Microsoft Learn, and the Microsoft Learn MCP server. The decision is [ADR 0013](../../docs/adr/0013-agent-experience.md). The prompts are in [prompts/](prompts/README.md).

> **Preview disclosure:** Database Hub, its Database Agent and Copilot, the Database Hub agent skills, and the SQL telemetry endpoint are previews. Their behavior, coverage, and interfaces can change. This guide uses only documented interfaces, and it never hard-codes what an agent will answer: every prompt lists the signals to look for and how to judge the answer instead.

**Status (2026-10-20):** the prompt pack, the install steps, and the plugin pins are done and checked against the sources below. Running the prompts against the live environment, and recording the targets covered and the latency observed, is pending: see the [live coverage record](#live-coverage-record).

## What's here

| Path | Contents |
|---|---|
| [prompts/README.md](prompts/README.md) | The prompt index, the placeholders, and the front matter convention |
| `prompts/*.md` | 35 prompt files: a session setup, then one file per scenario and surface (16 scenarios since Phase 25b), plus an incident wrap-up per surface |
| [prompts/prompt.schema.json](prompts/prompt.schema.json) | The JSON Schema for prompt front matter. `tests/unit/Agent.PromptPack.Tests.ps1` enforces it and the rules the schema can't express |
| `config/versions.json` (`agentPlugins`) | The pinned marketplace commit and the plugin versions this guide was checked with |

## Surfaces at a glance

| Surface | Host | What it reaches | Can it change anything? | Role in the demo |
|---|---|---|---|---|
| Database Agent and Copilot in Database Hub | Database Hub in the Fabric portal | What Database Hub shows you: Estate, issues and suggestions, Performance telemetry | Only through an explicit proposal that you approve | The showcase: presenter-driven, UI only, no API |
| `microsoft-sql-fdh` plugin (skill `databasehub-cli`) | Copilot CLI, VS Code | Database Hub inventory; CPU, storage, and memory health; security posture | No, it's read-only by design | Fallback for estate and health questions |
| Telemetry agent instructions | Copilot CLI, VS Code | The documented telemetry endpoint for all three targets: CPU, waits, memory, performance counters including blocking, storage IO, and database properties | No, the endpoint is read-only | Fallback for every incident on every target |
| `microsoft-sql` plugin diagnostics skills | Copilot CLI, VS Code | DMVs, Query Store, and plans over a SQL connection | Only if you approve a changing command, which the prompts forbid | Query-level evidence, documented for Azure SQL Database (T3) |
| Microsoft Learn MCP server | Copilot CLI, VS Code | Microsoft Learn documentation | No | Grounding and citations |

The Fabric data agent is out of scope: it works over OneLake data, not Database Hub signals (ADR 0013).

**Fallback ladder, for every beat:** the Database Agent in Database Hub, then the same scenario's skills prompts in Copilot CLI, then the Database Hub pages and the Learn sample queries in the [Azure Data Explorer web UI](https://dataexplorer.azure.com) without any agent, then the screenshots recorded in the rehearsal.

## Part 1: The Database Agent in Database Hub

### What it is

- Database Hub's overview says agents "can help translate an operational question into a structured investigation, identify relevant Database Hub information, and guide the user toward an appropriate next step", and that "agent-generated findings and recommendations require operator review".
- The Database Hub FAQ says "Copilot is the conversational interface. Agents are the analytical and operational engines behind it", and that when Copilot recommends an action, "it is backed by an explicit agent capability and an auditable proposal. There is no free-form execution."
- Database Agents were announced alongside the Database Hub estate view in preview on 2026-09-29 ([Azure SQL blog](https://devblogs.microsoft.com/azure-sql/whats-new-across-microsoft-sql-at-sqlcon-fabcon-europe-2026/)).
- **Not documented:** which targets the agent covers, its prerequisites and permissions, where its entry point sits in the UI, which actions it can propose, and how long it takes to produce a finding. The demo therefore runs every incident on T1, T2, or T3, and the [live coverage record](#live-coverage-record) captures what the agent did in this tenant, with dates. TODO(verify) each of these in the live check.

### Prerequisites

| Requirement | Who provides it | Reference |
|---|---|---|
| The tenant setting **Users can access the Database hub (preview)** on, and a Fabric Free license or higher for each presenter (P4) | A Fabric administrator | [Monitor SQL](https://learn.microsoft.com/fabric/database/hub/monitor-sql) |
| My workspace not on a Fabric capacity in North Europe or West Europe | The presenter | [Overview](https://learn.microsoft.com/fabric/database/hub/overview) |
| Reader or higher on the subscription. Contributors have it; others need P8 | A subscription Owner or RBAC administrator | [Monitor SQL](https://learn.microsoft.com/fabric/database/hub/monitor-sql) |
| `Microsoft.Sql` registered (P2) and performance monitoring enabled on each target (Phase 9) | `preflight.ps1` and the deployment | [Add SQL](https://learn.microsoft.com/fabric/database/hub/add-sql) |
| The Database Agent experience available in the tenant | Preview enrollment; how it's turned on isn't documented, TODO(verify) | [FAQ](https://learn.microsoft.com/fabric/database/hub/faq) |

### Use it safely: approval rules for presenters

1. **Investigate before acting.** Learn's guidance is to "begin with investigation, summarization, and evidence gathering". Every prompt in this pack is read-only, or asks for a proposal that's never applied.
2. **Every action is a proposal you approve.** The FAQ says actions are "explicit and always approved by the end user", who must hold the permission for that action, and that Database Hub delegates execution to the authoritative service.
3. **Don't approve agent-proposed changes in this demo.** The "human approval" beat works like this: the agent proposes; you read the proposal, its scope, and its rollback aloud; you say who would approve it in production; then you cancel it and use the demo's own bounded controls, which stop or reset the scenario and touch only `ContosoCare.Demo/` sessions in `ContosoCare` (Phase 11, and `demo-control.yml` with environment approval in Phase 13). The scenario reset knows only the demo's own remediation, so an agent-applied change would leave the demo in an unknown state.
4. **If a recommendation conflicts with the evidence, don't apply it.** That's the Database Hub monitoring guidance too.
5. **Stay in scope.** Only resources in the demo resource group, only the `ContosoCare` database.
6. **Keep secrets out.** Never paste passwords, tokens, keys, or connection strings into the agent. The data is synthetic, but treat the transcript as customer-facing.
7. **Record what happened** in the [live coverage record](#live-coverage-record): the date, the targets covered, the latency, and any action the agent offered.

### Where to find it

Open [Database Hub](https://powerbi.com/workloads/fdh/databaseHub), then Overview (**What needs attention?**), Estate filtered to the demo resource group, or Performance. Agent findings and the conversation appear where your tenant shows them; their exact placement isn't documented, TODO(verify). Each in-Hub prompt file says where to start.

## Part 2: Skills in GitHub Copilot CLI

Copilot CLI is the primary host for the fallback. Everything below is a one-time setup per presenter machine, except step 5.

### Prerequisites

- A GitHub Copilot subscription that allows Copilot CLI, and PowerShell 6 or later on Windows.
- The Azure CLI, signed in by you. The agent never signs in for you.
- For the Database Hub skill: the same Database Hub access as Part 1, with a delegated user identity. Its authors say not to assume that service principals or managed identities work.
- For the telemetry prompts: Reader or higher on the subscription, and `Microsoft.Sql` registered.

### 1. Install Copilot CLI

```powershell
winget install GitHub.Copilot
# or, with Node.js 22 or later:
npm install -g @github/copilot
```

### 2. Add the marketplace at the pinned commit, then install the plugins

The marketplace is the `microsoft/microsoft-sql` repository, and its name is `microsoft-sql`. Pin it to the commit this guide was checked with, recorded in `config/versions.json` (`agentPlugins.marketplace.commit`):

```powershell
copilot plugin marketplace add microsoft/microsoft-sql#eeb1c6867c2d128763516a1aad41671c593cc189
copilot plugin install microsoft-sql-fdh@microsoft-sql
copilot plugin install microsoft-sql@microsoft-sql
copilot plugin list --json
```

- `copilot plugin list --json` should show version `1.0.0` for both plugins.
- If the marketplace is already registered without the pin, remove it first with `copilot plugin marketplace remove microsoft-sql --force`, which also uninstalls its plugins, then add it again with the pin.
- Don't run `copilot plugin update` before a demo. Move the pin on purpose: update `config/versions.json`, re-run the prompt pack in a rehearsal, and record the result.
- The plugins contain skills only: no hooks and no MCP servers.

### 3. Add the Learn MCP server

```powershell
copilot mcp add --transport http microsoft-learn https://learn.microsoft.com/api/mcp
```

The server needs no sign-in. Alternatively, in an interactive session, `/plugin install microsoftdocs/mcp` installs the `microsoft-docs` plugin, which bundles the same server with three skills (version recorded in `config/versions.json`).

### 4. Load the telemetry agent instructions, by reference

The agent instructions block is Microsoft's: it's published on Microsoft Learn in [Query performance monitoring telemetry (preview)](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry), section "Instructions for AI agents", under "Agent instructions block". It holds the connection contract, security rules, data model, and correctness rules for the telemetry endpoint. Its reuse terms aren't stated on the page, so this repo links to it and never copies it. Two ways to use it:

- **Recommended:** start each session with [session-setup.skills](prompts/session-setup.skills.md). The agent reads the current block from Learn through the Learn MCP server and adds the demo's read-only rules.
- **Offline alternative:** copy the block from Learn into `AGENTS.md` in your demo working folder (step 5), outside this repo, and copy it again before each rehearsal. Copilot CLI reads `AGENTS.md` from the folder it starts in.

The Database Hub skill is designed never to query the telemetry endpoint itself, so keep telemetry questions in their own prompts, as the pack does.

### 5. Start a safe session

```powershell
New-Item -ItemType Directory -Path "$HOME\dbhub-agent-demo" -Force | Out-Null
Set-Location -Path "$HOME\dbhub-agent-demo"
az login --tenant <tenantId>
copilot --deny-tool=write
```

- **Start outside this repo.** Copilot CLI loads custom instructions such as `.github/copilot-instructions.md` and `AGENTS.md` from the repository and working folder, and this repo's instructions are for coding it, not for demos.
- **`--deny-tool=write`** denies all file writing for the session. Deny rules win over any approval.
- **Approve each command once, after reading it.** Approve only read commands: `az rest` calls to the Database Hub routes the skill names, POST calls to the telemetry query endpoint, and `SELECT` statements against `ContosoCare`. Reject sign-in and context changes such as `az login` or `az account set`; do those yourself. Never choose to approve a tool for the rest of the session, and never start with `--allow-all-tools` or `--allow-all`.
- **Tokens:** if one appears in the transcript, end the session, clear the terminal, and sign out and in again.

## Part 3: Skills in VS Code

1. Turn on agent plugins and add the marketplace at the pinned commit in your user settings (`chat.plugins.marketplaces` is experimental):

   ```json
   {
     "chat.plugins.enabled": true,
     "chat.plugins.marketplaces": [
       "microsoft/microsoft-sql#eeb1c6867c2d128763516a1aad41671c593cc189"
     ]
   }
   ```

2. In the Extensions view, search for `@agentPlugins` and install `microsoft-sql-fdh` and `microsoft-sql`. If you use the MSSQL extension, install `microsoft-sql-vscode` instead of `microsoft-sql`, never both: it carries the same diagnostics skills for that extension. Plugins that you installed with Copilot CLI also appear in VS Code automatically.
3. Run **MCP: Add Server** from the Command Palette, choose **HTTP**, enter `https://learn.microsoft.com/api/mcp`, name it `microsoft-learn`, and store it globally.
4. Keep the chat's permission level at **Manual permissions**, the default. Never switch a demo session to **Allow all** or **Autopilot**.
5. Start each chat with [session-setup.skills](prompts/session-setup.skills.md), or paste the agent instructions block at the start of the chat.

## Part 4: Line of sight and identities for T-SQL skills

The telemetry and Database Hub prompts work from any machine. The `microsoft-sql` diagnostics skills need a SQL connection, and none of the demo's SQL endpoints are reachable from outside its virtual network:

| Target | How SQL is reachable | Where a T-SQL skill can run | Identity |
|---|---|---|---|
| T1 `sqlvm01` | SQL connectivity is `LOCAL`: only on the VM | On `sqlvm01`, through on-demand Bastion | Windows authentication on the VM; Microsoft Entra authentication for SQL Server on T1 isn't enabled (deferred) |
| T2 `arcsql01` | Inside the nested guest, behind the host's NAT | In the guest, from the host's console through Bastion | Windows authentication in the guest |
| T3 `azuresql01-<deploymentId>` | A virtual network rule for T1's subnet in public mode, or only the private endpoint in private mode | From `sqlvm01`, through Bastion | Microsoft Entra only. Your account needs a database user with `VIEW DATABASE STATE` in `ContosoCare`, or membership in the T3 admin group (P6), TODO(verify) for presenters |

- **This path is optional and not selected by default.** The telemetry prompts cover every incident on every target without a SQL connection.
- **If you use it:** connect through Bastion with the break-glass password reset (`start-demo.ps1 -Interactive -ResetAdminPassword`, Phase 13), sign in to Copilot CLI and the Azure CLI on the VM, and sign both out before you disconnect (`az logout` for the Azure CLI; the Copilot CLI sign-out command is TODO(verify)).
- On T1 and T2 the skills can decline, because they're documented for Azure SQL Database. The prompts tell the agent to say so instead of guessing.

## Limitations

### Database Agent and Copilot in Database Hub

- Documented only at overview, FAQ, and announcement level: target coverage, prerequisites, permissions, entry point, action catalog, and latency are unknown until the live check (plan risk R23).
- No API, so it can't be automated or tested; answers vary between runs.
- A newly created T3 can show findings late, and a paused serverless database sends no telemetry.

### `microsoft-sql-fdh` plugin

- Read-only, delegated user only.
- It calls Database Hub routes that its authors classify as not a public contract, which can change independently of the documented Fabric REST APIs. This repo's code never calls them; only the plugin does, as the signed-in presenter.
- It doesn't expose Query Store, active sessions, query text, plans, blocking, or DMVs, and its health contract covers CPU, storage, and memory, not IO.
- Its skill notes say its claims were verified against fixtures on 2026-09-22 and that live execution was still pending. TODO(verify) live.
- Its description lists Azure SQL and Arc-enabled SQL Server but doesn't mention SQL Server on Azure VMs, so T1 coverage is TODO(verify).

### Telemetry agent instructions

- The endpoint, schema, and block are previews and can change. Retention is up to 7 days, data arrives a few minutes after the samples, and there's no query-level detail.
- Per-file IO latency from the telemetry isn't supported for Azure SQL Database.
- Results cover only resources with monitoring enabled that the caller can read; an empty result doesn't mean healthy.

### `microsoft-sql` plugin diagnostics skills

- Written for Azure SQL Database. The marketplace README says they don't treat self-managed SQL Server as the same product, so on T1 and T2 they can decline.
- Their guides use SQL authentication in examples and include changing steps: test tables, permission grants, MAXDOP changes, and the dedicated admin connection. The prompts forbid all of them, and T3 is Microsoft Entra only.
- They need a SQL connection (Part 4).

### Plugin pins and hosts

- Copilot CLI pins a marketplace with `owner/repo#ref`, and VS Code with `owner/repo#<commit>`. `copilot plugin update`, or re-adding the marketplace without the pin, moves to the latest commit.
- VS Code's `chat.plugins.marketplaces` setting is experimental.
- The Learn MCP server serves public documentation only, and its knowledge service refreshes incrementally, with a full refresh once a day.

## Live coverage record

Pending: no prompt has run against the live environment yet. Each cell uses the six statuses of [ADR 0012](../../docs/adr/0012-validation-model.md):

- **Pass:** the answer used the expected signals for that target and cited its evidence.
- **Warning:** the answer was right but partial, for example missing coverage it should have reported.
- **Fail:** the answer invented evidence or contradicted the telemetry.
- **Not supported:** the surface declined the target or doesn't cover it.
- **Not selected:** not run, by choice.
- **Manual action required:** not run yet.

Latency, in minutes: for the in-Hub agent, from the scenario's `started_at` in `demo.scenario_runs` to the first agent finding or answer that mentions the incident; for prompts, from sending the prompt to a complete answer.

| Prompt file | T1 | T2 | T3 | Latency (minutes) | Checked (UTC) | Notes |
|---|---|---|---|---|---|---|
| healthy-baseline.in-hub | Manual action required | Manual action required | Manual action required | | | |
| healthy-baseline.skills | Manual action required | Manual action required | Manual action required | | | |
| locking-blocking.in-hub | Manual action required | Manual action required | Manual action required | | | |
| locking-blocking.skills | Manual action required | Manual action required | Manual action required | | | |
| cpu-pressure.in-hub | Manual action required | Manual action required | Manual action required | | | |
| cpu-pressure.skills | Manual action required | Manual action required | Manual action required | | | |
| io-pressure.in-hub | Manual action required | Manual action required | Manual action required | | | |
| io-pressure.skills | Manual action required | Manual action required | Manual action required | | | |
| missing-index.in-hub | Manual action required | Manual action required | Manual action required | | | |
| missing-index.skills | Manual action required | Manual action required | Manual action required | | | |
| inefficient-query.in-hub | Manual action required | Manual action required | Manual action required | | | |
| inefficient-query.skills | Manual action required | Manual action required | Manual action required | | | |
| resource-governance.in-hub | Manual action required | Manual action required | Manual action required | | | |
| resource-governance.skills | Manual action required | Manual action required | Manual action required | | | |
| log-rate-pressure.in-hub | Manual action required | Manual action required | Manual action required | | | |
| log-rate-pressure.skills | Manual action required | Manual action required | Manual action required | | | |
| blocking-chain.in-hub | Manual action required | Manual action required | Manual action required | | | |
| blocking-chain.skills | Manual action required | Manual action required | Manual action required | | | |
| deadlock-storm.in-hub | Manual action required | Manual action required | Manual action required | | | |
| deadlock-storm.skills | Manual action required | Manual action required | Manual action required | | | |
| tempdb-contention.in-hub | Manual action required | Manual action required | Manual action required | | | |
| tempdb-contention.skills | Manual action required | Manual action required | Manual action required | | | |
| memory-grant-pressure.in-hub | Manual action required | Manual action required | Manual action required | | | |
| memory-grant-pressure.skills | Manual action required | Manual action required | Manual action required | | | |
| parallel-scans.in-hub | Manual action required | Manual action required | Manual action required | | | |
| parallel-scans.skills | Manual action required | Manual action required | Manual action required | | | |
| log-flush-waits.in-hub | Manual action required | Manual action required | Manual action required | | | |
| log-flush-waits.skills | Manual action required | Manual action required | Manual action required | | | |
| slow-consumer.in-hub | Manual action required | Manual action required | Manual action required | | | |
| slow-consumer.skills | Manual action required | Manual action required | Manual action required | | | |
| capacity-max.in-hub | Manual action required | Manual action required | Manual action required | | | |
| capacity-max.skills | Manual action required | Manual action required | Manual action required | | | |
| incident-wrap-up.in-hub | Manual action required | Manual action required | Manual action required | | | |
| incident-wrap-up.skills | Manual action required | Manual action required | Manual action required | | | |

Record the agent's entry point, any action it offered, and any TODO(verify) item the run settles in the notes. The scenarios arrive in Phase 11, so the incident rows can run only after it.

## Sources (checked 2026-10-20)

- Database Hub: [overview](https://learn.microsoft.com/fabric/database/hub/overview), [FAQ](https://learn.microsoft.com/fabric/database/hub/faq), [monitor SQL](https://learn.microsoft.com/fabric/database/hub/monitor-sql), [enable performance monitoring](https://learn.microsoft.com/fabric/database/hub/add-sql), [query performance monitoring telemetry and its agent instructions block](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry) (all updated 2026-10-17)
- Agent skills: [the `microsoft/microsoft-sql` marketplace](https://github.com/microsoft/microsoft-sql), [`microsoft-sql-fdh`](https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql-fdh), [`microsoft-sql`](https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql) (commit `eeb1c6867c2d128763516a1aad41671c593cc189`, plugin version 1.0.0)
- GitHub Copilot CLI: [install](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli), [find and install plugins](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-finding-installing), [plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference), [use Copilot CLI and add MCP servers](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/overview), [allow and deny tools](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools), [custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
- VS Code: [agent plugins](https://code.visualstudio.com/docs/agent-customization/agent-plugins), [MCP servers](https://code.visualstudio.com/docs/agent-customization/mcp-servers), [approvals and permissions](https://code.visualstudio.com/docs/agents/run/approvals)
- Microsoft Learn MCP server: [overview](https://learn.microsoft.com/training/support/mcp), [get started](https://learn.microsoft.com/training/support/mcp-get-started), [`MicrosoftDocs/mcp`](https://github.com/MicrosoftDocs/mcp)
- SQL: [optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking), [`sys.dm_db_missing_index_details`](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-db-missing-index-details-transact-sql), [Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store), [serverless auto-pause](https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume), [Azure SQL Database metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-databases-metrics)
- Announcement: [What's new across Microsoft SQL at SQLCon/FabCon Europe 2026](https://devblogs.microsoft.com/azure-sql/whats-new-across-microsoft-sql-at-sqlcon-fabcon-europe-2026/) (2026-09-29)
