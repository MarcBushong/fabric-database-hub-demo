---
id: incident-wrap-up.skills
name: Wrap up any incident with Copilot CLI or VS Code
scenario: any
incident: true
targets: [T1, T2, T3]
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [telemetry-endpoint, scenario-record, learn-mcp]
capability: Turns the investigation of any scenario on any target into a customer-friendly root cause, its evidence, a baseline-versus-incident comparison from the telemetry, the safest next action as an unapplied proposal grounded in Microsoft Learn, the approvals it needs, what to verify, and a short incident summary.
permission: The Azure CLI signed in as you, with Reader or higher on the subscription and Microsoft.Sql registered. Reading the scenario record needs line of sight and a database identity that can read demo.scenario_runs in ContosoCare (Microsoft Entra on T3, Windows authentication on T1 and T2). The Learn MCP server needs no sign-in.
responseShape: Seven short answers in order, which are a three-sentence root cause, an evidence list with metric, window, and value, a comparison table of baseline and incident with the KQL behind it, one proposal with rollback and a Learn link, an approval list, a verification checklist, and a five-bullet summary.
previewLimitation: The telemetry endpoint and schema are previews with no query-level detail. Answers vary between runs, and skills-based recommendations need operator review like any other.
fallback: Without an agent, the presenter walks through the same seven points from the Learn telemetry sample queries in the Azure Data Explorer web UI, the scenario record, and the verification table in incident-wrap-up.in-hub.
actionPolicy: propose-only
adrPrompts: [customer-root-cause, supporting-evidence, baseline-vs-incident, safest-next-action, actions-needing-approval, what-to-verify, incident-summary]
sources:
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/training/support/mcp
  - https://learn.microsoft.com/fabric/database/hub/overview
reviewed: 2026-10-20
---

# Wrap up any incident with Copilot CLI or VS Code

Use after any skills incident prompt, on any target, in the same session so the context carries over. It's the "evidence, root cause, recommended action, human approval" part of the walkthrough. The agent proposes; the presenter decides.

## Prompts

### 1. Customer-friendly root cause

```text
Explain the root cause of the incident on {target} during {incidentWindow} in three sentences for someone who isn't a database administrator: what happened, what it affected, and how confident you are. Don't change anything.
```

### 2. Supporting evidence

```text
List the evidence for that explanation. For each item give the metric, the UTC window, the value, and the KQL or T-SQL it came from, then list the evidence you'd want but couldn't see. Don't change anything.
```

### 3. Baseline compared with the incident

```text
Using the telemetry agent instructions, compare {incidentWindow} with {baselineWindow} on {target} in resource group {resourceGroup}: CPU, the top wait categories, processes blocked, batch requests, and IO. Answer as a table with both windows, using deltas for cumulative counters, and show the KQL. Don't change anything.
```

### 4. Safest next action, grounded in Learn

```text
What is the safest next action? Describe one proposal: what it changes, where, the expected effect, the risk, and how to roll it back. Use the Microsoft Learn MCP server to cite the Learn page that supports it. Don't apply anything; propose only.
```

### 5. Which actions need approval

```text
Which of the actions we discussed need approval, from whom, and with which permission or role? Which can't be undone? Don't apply anything; propose only.
```

### 6. What to verify before anyone acts

```text
What should I check in the Azure portal, in SSMS, or in VS Code to confirm your conclusion before anyone acts, and what would I see if your conclusion were wrong? If I can reach ContosoCare on {target}, include a read-only query of demo.scenario_runs that shows the run's window. Don't change anything.
```

### 7. Concise incident summary

```text
Write a concise incident summary for the application team in five bullets: impact, UTC window, cause, evidence, and the next step that is waiting for approval. Don't change anything.
```

## Signals to look for

- The baseline-versus-incident table moves on the signals the scenario's prompt file lists for that target and stays flat elsewhere.
- The KQL follows the Learn rules: time filter first, deltas for cumulative counters, Idle and Unknown waits excluded.
- The proposal cites a Microsoft Learn page through the Learn MCP server, not a blog or memory.
- The verification steps match the target: see the table in [incident-wrap-up.in-hub](incident-wrap-up.in-hub.md#where-to-verify-by-target).

## How to judge the answer

- Every piece of evidence has a metric, a window, a value, and the query behind it.
- The proposal is one action with a rollback and a Learn citation, and nothing is described as done.
- The approval list names a role and a permission for each action.
- The summary has exactly five bullets and no recommendation presented as a decision.

## Safety

- Reject any command that changes something, even one the agent calls a test. This beat proposes; it never applies.
- Don't approve the proposal through the agent. Say who would approve it, then use the demo's own controls: stop or reset the scenario (Phase 11), which act only on `ContosoCare.Demo/` sessions in `ContosoCare`.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), run the Learn telemetry sample queries the scenario's prompt file names, for both windows.
2. Walk through the same seven points from those results, the scenario record, and the verification table in [incident-wrap-up.in-hub](incident-wrap-up.in-hub.md).
3. Last resort: the screenshots recorded in the rehearsal.
