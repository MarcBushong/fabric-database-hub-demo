---
id: missing-index.in-hub
name: Find a missing index and propose a fix in Database Hub
scenario: missing-index
incident: true
targets: [T1, T2, T3]
defaultTarget: T2
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Connects read-heavy pressure on the chosen target to an inefficient access path, proposes the safest next step as an unapplied proposal with its risk and before-and-after measure, and lists which actions need approval and how to roll them back.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Applying a proposal would need rights on the database itself, which this beat never uses. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A verdict on whether an index is likely missing, then the proposal as text (what, where, expected effect, risk, rollback), then an approval list with who approves and what permission each action needs, then gaps.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage, latency, and action catalog. Database Hub telemetry has no query text or plans, so the agent may only infer a missing index from resource signals.
fallback: Run missing-index.skills in Copilot CLI. Without an agent, show the target on the Performance page, then the missing-index hint in the plan of the scenario query in SSMS through Bastion.
actionPolicy: propose-only
adrPrompts: [inefficient-queries, safest-next-action, actions-needing-approval]
sources:
  - https://learn.microsoft.com/fabric/database/hub/faq
  - https://learn.microsoft.com/fabric/database/hub/overview
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
reviewed: 2026-10-20
---

# Find a missing index and propose a fix in Database Hub

The incident beat for [missing index](../../../scenarios/missing-index/README.md): before, recommendation, action, after. The agent proposes; a person applies the scenario's own remediation script after the approval beat, never the agent. It runs on T2 by default and on any target on request.

**Where to type it:** open the target from Estate or Performance, then the agent or Copilot pane where your tenant shows it. TODO(verify) the entry point and whether the tenant offers index actions at all.

## Prompts

### 1. Find the inefficient work

```text
Which workload on {target} does the most reading during {incidentWindow}, and is there a sign that an index is missing? If you can't see query-level data, say so and tell me where to look. Don't change anything.
```

### 2. Safest next step

```text
What's the safest next step for this problem on {target}? Describe it as a proposal: what it would change, the expected effect, the risk, how to roll it back, and how we'd measure before and after. Don't apply anything; propose only.
```

### 3. What needs approval

```text
Which of the actions you proposed need approval, from whom, with which permission, and in what order? Mark anything that can't be undone. Don't apply anything; propose only.
```

## Signals to look for

| Target | Resource signals | Query-level evidence, outside Database Hub |
|---|---|---|
| T1 | Buffer IO waits (`PAGEIOLATCH_*`) and page reads up; CPU up from scans | The scenario query's plan has a missing-index hint; Query Store shows high logical reads per execution |
| T2 (default) | The same as T1 | The same as T1 |
| T3 | The same signals against the tier's limits | The same, plus the Azure portal's performance recommendations for the database, which can need more workload history than a demo provides, TODO(verify) |

- The Database Hub FAQ describes supported agent-proposed recommendations as explicit actions, approved by the user, with no free-form execution.

## How to judge the answer

- The proposal names the table and columns it would index, or says it can't see them.
- It includes a rollback and a before-and-after measure, such as logical reads per execution.
- It separates actions that need approval from read-only checks.
- It doesn't present the proposal as done.

## Safety

- Don't approve an index action in Database Hub during a customer demo. Read the proposal and its approval prompt aloud, then cancel. The remediation is the scenario's script, applied by a person after the approval beat, and the scenario reset removes it again (Phase 11).
- An approval in Database Hub is subject to your permissions and existing change controls (Learn, Database Hub overview and FAQ). Never approve on a resource outside the demo resource group.

## Fallback demo

1. Run [missing-index.skills](missing-index.skills.md) in Copilot CLI.
2. Without an agent: show the target on the Performance page, then the missing-index hint in the scenario query's plan in SSMS through Bastion. SSMS on the image is TODO(verify).
3. Last resort: the screenshots recorded in the rehearsal.
