---
id: incident-wrap-up.in-hub
name: Wrap up any incident in Database Hub
scenario: any
incident: true
targets: [T1, T2, T3]
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Turns the investigation of any scenario on any target into a customer-friendly root cause, its evidence, a baseline-versus-incident comparison, the safest next action as an unapplied proposal, the approvals it needs, what to verify in the Azure portal, SSMS, or VS Code, and a short incident summary.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Approving a proposed action would need the permission for that action on the target, which this beat never uses. Agent-specific permissions aren't documented, TODO(verify).
responseShape: Seven short answers in order, which are a three-sentence root cause, an evidence list with metric, window, and value, a comparison table of baseline and incident, one proposal with rollback, an approval list, a verification checklist, and a five-bullet summary.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage, latency, and action catalog. Answers vary between runs, and agent findings and recommendations need operator review.
fallback: Run incident-wrap-up.skills in Copilot CLI. Without an agent, the presenter walks through the same seven points from the Performance page and the scenario record, using the verification table in this file.
actionPolicy: propose-only
adrPrompts: [customer-root-cause, supporting-evidence, baseline-vs-incident, safest-next-action, actions-needing-approval, what-to-verify, incident-summary]
sources:
  - https://learn.microsoft.com/fabric/database/hub/faq
  - https://learn.microsoft.com/fabric/database/hub/overview
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
reviewed: 2026-10-20
---

# Wrap up any incident in Database Hub

Use after any incident prompt, on any target: [locking and blocking](locking-blocking.in-hub.md), [CPU](cpu-pressure.in-hub.md), [IO](io-pressure.in-hub.md), [missing index](missing-index.in-hub.md), [inefficient query](inefficient-query.in-hub.md), or [resource governance](resource-governance.in-hub.md). It's the "evidence, root cause, recommended action, human approval" part of the walkthrough. The agent proposes; the presenter decides.

**Where to type it:** in the same agent or Copilot conversation as the investigation, so the context carries over.

## Prompts

### 1. Customer-friendly root cause

```text
Explain the root cause of the incident on {target} during {incidentWindow} in three sentences for someone who isn't a database administrator: what happened, what it affected, and how confident you are. Don't change anything.
```

### 2. Supporting evidence

```text
List the evidence for that explanation. For each item give the metric, the UTC window, and the value, then list the evidence you'd want but couldn't see. Don't change anything.
```

### 3. Baseline compared with the incident

```text
Compare {incidentWindow} with {baselineWindow} on {target}: which signals changed, by how much, and which stayed the same? Answer as a table. Don't change anything.
```

### 4. Safest next action

```text
What is the safest next action? Describe one proposal: what it changes, where, the expected effect, the risk, and how to roll it back. Don't apply anything; propose only.
```

### 5. Which actions need approval

```text
Which of the actions we discussed need approval, from whom, and with which permission? Which can't be undone? Don't apply anything; propose only.
```

### 6. What to verify before anyone acts

```text
What should I check in the Azure portal, in SSMS, or in VS Code to confirm your conclusion before anyone acts, and what would I see if your conclusion were wrong? Don't change anything.
```

### 7. Concise incident summary

```text
Write a concise incident summary for the application team in five bullets: impact, UTC window, cause, evidence, and the next step that is waiting for approval. Don't change anything.
```

## Signals to look for

- The root cause uses the signals the scenario's own prompt file lists for that target, and the window overlaps the scenario record (`demo.scenario_runs`).
- The comparison shows the incident's signals moving away from the baseline's ranges and the unrelated signals staying flat.
- The proposal addresses the mechanism the evidence shows, such as a held lock, a costly access path, or an IO or governed limit, rather than a generic fix such as a restart or a bigger tier.

### Where to verify, by target

| Target | Azure portal | SSMS or VS Code |
|---|---|---|
| T1 | The SQL virtual machine resource for `sqlvm01`, and the VM's CPU and disk metrics | Through Bastion on the VM: `sys.dm_exec_requests` for blocking, Query Store reports for `ContosoCare` |
| T2 | The Arc-enabled SQL Server instance `arcsql01` | Through Bastion on the host, then the guest's console: the same DMVs and Query Store reports |
| T3 | The database's metrics (CPU percentage, Log IO percentage, Data IO percentage, Workers percentage) and [Query Performance Insight](https://learn.microsoft.com/azure/azure-sql/database/query-performance-insight-use) | From a client inside the demo network: the MSSQL extension in VS Code with Microsoft Entra authentication, Query Store for `ContosoCare` |

## How to judge the answer

- The root cause is plain language, names a confidence level, and doesn't overstate.
- Every piece of evidence has a metric, a window, and a value; missing evidence is listed, not hidden.
- The proposal is one action with a rollback, and nothing is described as already done.
- The approval list names a role and a permission for each action.
- The summary has exactly five bullets and no recommendation presented as a decision.

## Safety

- The Database Hub FAQ says actions are explicit, approved by the user, and backed by an auditable proposal with no free-form execution. In this demo, don't approve the proposal in Database Hub. Say who would approve it and why, then use the demo's own controls: stop or reset the scenario (Phase 11), which act only on `ContosoCare.Demo/` sessions in `ContosoCare`.
- If the recommendation conflicts with the evidence, don't apply it (Database Hub monitoring troubleshooting).

## Fallback demo

1. Run [incident-wrap-up.skills](incident-wrap-up.skills.md) in Copilot CLI.
2. Without an agent: the presenter answers the same seven points from the Performance page, the scenario record, and the verification table above.
3. Last resort: the screenshots recorded in the rehearsal.
