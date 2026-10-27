---
id: session-setup.skills
name: Start a read-only investigation session with the telemetry agent instructions
scenario: setup
incident: false
targets: [T1, T2, T3]
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [learn-mcp, telemetry-endpoint]
capability: Reads the current agent instructions block from the Learn telemetry page through the Learn MCP server, adds the demo's read-only rules, and confirms the endpoint, the cumulative-counter rule, and token handling before any query runs.
permission: None to read Microsoft Learn. The telemetry prompts that follow need you signed in to the Azure CLI in the demo tenant, with Reader or higher on the subscription and Microsoft.Sql registered there.
responseShape: A confirmation in four parts covering the endpoint and database it will query, the rule for cumulative counters, what an empty result means, and how it gets a token without printing it. No query runs yet.
previewLimitation: The telemetry endpoint, its schema, and the agent instructions block are preview content that can change. The block is read from Learn at run time and never copied into this repo.
fallback: Copy the agent instructions block from the Learn page into AGENTS.md in a demo working folder outside this repo and start a new Copilot CLI session there, or paste it at the start of a VS Code chat.
actionPolicy: read-only
adrPrompts: []
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/training/support/mcp
  - https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools
  - https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions
reviewed: 2026-10-20
---

# Start a read-only investigation session

Run this first in every GitHub Copilot CLI or VS Code session that uses the skills prompts. It loads Microsoft's agent instructions block for the telemetry endpoint by reference, from Microsoft Learn, so this repo never copies it. It also sets the demo's own rules for the rest of the session.

## Before you start

- Install the plugins and the Learn MCP server: see [the install guide](../README.md#part-2-skills-in-github-copilot-cli).
- Sign in yourself with `az login --tenant <tenantId>` in the same terminal. The agent never signs in for you, and you never give it a password or a key.
- Start Copilot CLI from a demo working folder outside this repo, with file writes denied: `copilot --deny-tool=write`.

## Prompts

### 1. Load the instructions and the demo rules

```text
Use the Microsoft Learn MCP server to fetch https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry and read its "Instructions for AI agents" section, including the agent instructions block and the sample queries. Follow that block for the rest of this session, with these demo rules on top:
- Don't change anything. No file writes, no KILL, no CREATE, ALTER, DROP, or GRANT, no new Extended Events sessions, and no re-running workload queries.
- Scope every query to resource group {resourceGroup} and, for T-SQL, to the ContosoCare database. Say how many resources each answer covers.
- Never print, store, or repeat a token or an Authorization header, and never ask me for a password, key, or secret.
- Show the KQL or T-SQL you ran and the UTC time window it covered.
Don't run a query yet. Confirm the endpoint and database you'll query, the rule you'll follow for cumulative counters, what an empty result means, and how you'll get a token without printing it.
```

## Signals to look for

- It names the documented query endpoint and the `ArcSqlTelemetry` database from the Learn page.
- It restates the cumulative-counter rule: deltas between adjacent samples, skipping any interval that contains a reset, never a sum of raw samples.
- It says an empty result doesn't mean healthy, and that results cover only resources with monitoring enabled that you can read.
- It plans to get a token at run time from the Azure CLI and keep it out of the transcript.
- It runs no query, and it doesn't ask for a password, key, or secret.

## How to judge the answer

- It quotes or links the Learn page as the source of its rules.
- It accepts every demo rule, or says which one it can't follow, before you go on.
- It doesn't invent an endpoint, a table, or a column that isn't on the Learn page.

## Safety

- If a token ever appears in the transcript, stop the session, clear the terminal, and sign out and in again. Learn says tokens expire after about an hour; treat a printed token as exposed anyway.
- Approve each shell command once, after reading it. Don't choose to approve a tool for the rest of the session, and don't start Copilot CLI with `--allow-all-tools` or `--allow-all`.
- In VS Code, keep **Manual permissions**, the default, and don't switch the session to **Allow all** or **Autopilot**.

## Fallback demo

1. Open the [telemetry page](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry) and copy its agent instructions block.
2. Copilot CLI: paste it into `AGENTS.md` in your demo working folder, outside this repo, and start a new session from that folder. Copilot CLI reads `AGENTS.md` from the folder it starts in.
3. VS Code: paste it at the start of the chat, followed by the demo rules from prompt 1.
4. Don't commit that file anywhere. Copy it again before each rehearsal, because the block can change during the preview.
