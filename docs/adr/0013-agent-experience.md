# ADR 0013: Agent experience: in-Hub Database Agent first, skills as fallback

- **Status:** Accepted, validation pending: the live coverage record waits for the owner's rehearsal
- **Date:** 2026-10-19
- **Decision source:** User-directed (Q3)
- **Related:** [ADR 0010](0010-workload-generator-technology.md), [ADR 0012](0012-validation-model.md), [ADR 0014](0014-notebook-role-and-capacity.md), `fabric/agent/`

## Context

- **In-Hub agents and Copilot:**
  - The Database Hub overview says agents help translate an operational question into a structured investigation.
  - The Hub FAQ says Copilot is the conversational interface and agents are the analytical and operational engines, backed by an explicit capability and an auditable proposal.
  - The monitoring doc says Estate findings can come from agents.
  - The in-Hub Database Agent is a preview that's enabled in the owner's tenant.
- **What isn't documented about the in-Hub agent:** supported targets, prerequisites, permissions, and latency. It has no public API.
- **The `microsoft-sql-fdh` plugin** (Database Hub agent skills) is read-only. It covers inventory, performance and health, and security posture. It works only with a delegated user identity, and it calls routes that aren't a public contract. It doesn't expose blocking, active sessions, query text, plans, or Query Store.
- **The `microsoft-sql` plugin** has diagnostics skills such as `diagnose-blocking-and-deadlocks` and `diagnose-slow-query`. They need network line of sight and database authentication.
- **The telemetry REST endpoint** is documented and needs subscription Reader. The plan records an agent-instructions block on that page; a 2026-10-19 search couldn't confirm it, so Phase 10 re-checks it.
- **The Fabric data agent** works over OneLake data, not Hub signals.

## Decision drivers

1. Showcase what the customer will see in Database Hub.
2. Never present an AI response as guaranteed.
3. Every demo beat has a scriptable fallback.
4. Use only documented interfaces.

## Decision

### Primary: the in-Hub Database Agent and Copilot

- **Presenter-driven, in the Hub UI.** Classification: Manual / Optional preview.
- **Any proposed action needs explicit human approval** before anything runs.
- **The repo never automates, scrapes, or calls the Hub.** It never calls `/v1/databasehub/__private` routes or any other undocumented route.
- **Any target:** every incident scenario can run on T1, T2, or T3 (ADR 0010), so the walkthrough uses whichever targets the agent supports in the tenant.
- **Phase 10 records** which targets the agent covered and the latency observed, with the date.

### Documented, scriptable fallback

| Piece | Role |
|---|---|
| GitHub Copilot CLI (primary host) and VS Code | Agent hosts |
| `microsoft-sql-fdh` plugin | Hub inventory, performance health, and security posture (read-only, delegated user) |
| `microsoft-sql` plugin | Blocking, deadlocks, resource pressure, slow queries, and plans, run on T1 or T3 through Bastion or an allowed client |
| Telemetry REST endpoint instructions | Investigation from Hub telemetry, with attribution to Learn |
| Learn MCP server (`https://learn.microsoft.com/api/mcp`) | Documentation grounding |

Plugin versions are pinned in `config/versions.json`, and their install steps are in `fabric/agent/README.md`.

### Out of scope

- The Fabric data agent.
- Any custom agent that calls private routes.

### Prompt pack (`fabric/agent/prompts/*.md`)

- **One file per prompt:** estate health summary; target with the most pressure; investigate locking on a chosen target; correlate with CPU, memory, IO, sessions, and recent changes; customer-friendly root cause; supporting evidence; safest next action, without applying it; baseline compared with the incident; inefficient queries; which actions need approval; what to verify in the portal, SSMS, or VS Code; and a concise incident summary.
- **Each prompt records:** surface (in-Hub agent or skills), data source, expected capability, required permission, response shape, preview limitation, and fallback demo.
- **Expected AI output is never hard-coded.** Prompts describe the signals to look for, not the answer.

## Consequences

- **Positive:** the demo shows the real product experience and stays honest about the preview. Every beat still works if the agent is unavailable.
- **Negative:** the primary showcase can't be tested automatically, and its behavior can change without notice (plan risk R23).

## Validation

Phase 10 (live, pending go-ahead):

- Run every prompt on the in-Hub agent and on the fallback path.
- Record coverage by target, latency, and limitations, with dates, in `fabric/agent/README.md`.
- Confirm that no repo code calls a private route (a static check in CI).

## Sources (checked 2026-10-19)

- Database Hub overview: <https://learn.microsoft.com/fabric/database/hub/overview>
- Database Hub FAQ: <https://learn.microsoft.com/fabric/database/hub/faq>
- Database Hub monitoring: <https://learn.microsoft.com/fabric/database/hub/monitor-sql>
- Telemetry REST endpoint: <https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry>
- `microsoft-sql-fdh` plugin: <https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql-fdh>
- `microsoft-sql` repository: <https://github.com/microsoft/microsoft-sql>
- Learn MCP server: <https://learn.microsoft.com/api/mcp>

## Implementation notes (Phase 10, 2026-10-20)

The prompt pack and install guide are in `fabric/agent/`. The static work is done; running the prompts against the live environment, and recording coverage and latency, is pending (see the live coverage record in `fabric/agent/README.md`).

### Prompt pack layout

- **One file per scenario and surface, not one file per prompt kind.** The Phase 10 brief asked for files by scenario, so the pack has a session setup, two files (in-Hub and skills) for each of seven scenarios (healthy baseline, locking and blocking, CPU, IO, missing index, inefficient query, and T3 resource governance), and an incident wrap-up per surface: 17 files. Each file's `adrPrompts` front matter maps it to the twelve prompt kinds above, and a test checks that each surface covers all twelve.
- **T3 resource governance** has no scenario folder: the CPU pressure and inefficient query scenarios produce it on T3, and on T1 and T2 the same prompts act as controls with no governance.
- **Front matter convention:** `fabric/agent/prompts/prompt.schema.json`, enforced by `tests/unit/Agent.PromptPack.Tests.ps1`. Incident prompts must target T1, T2, and T3. Every prompt block carries "Don't change anything" or "Don't apply anything; propose only" and uses only four placeholders. The tests also reject answer text, secrets, non-HTTPS or unofficial links, and private routes, and check that the index lists every file.

### Findings that refine the decision

- **The telemetry agent instructions block is confirmed.** The Learn telemetry page (updated 2026-10-17) has an "Instructions for AI agents" section with an "Agent instructions block". Its reuse terms aren't stated, so the repo links to it with attribution and never copies it; the session-setup prompt has the agent read it through the Learn MCP server. This closes the open item from the Phase 3 doc check.
- **Plugins and pins (checked 2026-10-20):** the marketplace is `microsoft/microsoft-sql` (name `microsoft-sql`) at commit `eeb1c6867c2d128763516a1aad41671c593cc189`, with `microsoft-sql-fdh` 1.0.0 (skill `databasehub-cli`), `microsoft-sql` 1.0.0, and `microsoft-sql-vscode` 1.0.0 for VS Code with the MSSQL extension. Copilot CLI pins it with `copilot plugin marketplace add microsoft/microsoft-sql#<commit>`, and VS Code with `owner/repo#<commit>` in `chat.plugins.marketplaces`. `config/versions.json` (`agentPlugins`) records the pin, and a test keeps the guide on the same commit. The plugins contain skills only, with no hooks or MCP servers.
- **The `microsoft-sql` diagnostics skills are written for Azure SQL Database.** The marketplace says they don't treat self-managed SQL Server as the same product, so on T1 and T2 they can decline. Their guides also use SQL authentication in examples and include changing steps (test tables, permission grants, MAXDOP changes, the dedicated admin connection); the prompts forbid those, and T3 is Microsoft Entra only.
- **The `microsoft-sql-fdh` skill** reports CPU, storage, and memory health but not IO, avoids the telemetry endpoint by design, and notes that its claims were verified against fixtures on 2026-09-22 with live execution pending. Its description lists Azure SQL and Arc-enabled SQL Server but not SQL Server on Azure VMs, so T1 coverage is a live check.
- **No demo SQL endpoint is reachable from outside the virtual network.** T-SQL skills therefore run only from inside it (T1 through Bastion), and they're optional and not selected by default; the telemetry prompts are the default fallback on every target.
- **Blocking looks different on T3.** Optimized locking and read committed snapshot are on in Azure SQL Database and not in SQL Server 2022, so the locking prompts describe per-target signals.
- **The Database Agent is still documented only at overview and FAQ level** (pages updated 2026-10-17), plus the 2026-09-29 announcement. Its entry point, target coverage, permissions, action catalog, and latency stay live checks.

### Presenter rules

- **Demo approval policy, refining "explicit human approval":** the presenter doesn't approve agent-proposed changes during a demo. The approval beat is reading the proposal, its scope, and its rollback aloud, naming who would approve it, cancelling it, and then using the demo's bounded scenario controls (Phase 11), because the scenario reset knows only the demo's own remediation.
- **Session hygiene for the skills fallback:** start Copilot CLI outside this repo, whose instructions are for coding it; deny file writes with `--deny-tool=write`; approve read commands one at a time; and keep VS Code at **Manual permissions**.

### Sources (checked 2026-10-20)

- Telemetry page and its agent instructions block: <https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry>
- Copilot CLI plugin reference (`owner/repo#ref` marketplaces): <https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference>
- VS Code agent plugins (commit-pinned marketplaces): <https://code.visualstudio.com/docs/agent-customization/agent-plugins>
- Learn MCP server: <https://learn.microsoft.com/training/support/mcp>
- Optimized locking: <https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking>
