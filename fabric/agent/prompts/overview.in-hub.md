---
id: overview.in-hub
name: Open at Overview with Copilot's three starting questions
scenario: any
incident: true
targets: [T1, T2, T3]
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Answers the three starting questions Database Hub's general availability suggests for Copilot, across the whole estate. What changed recently, which resource to investigate next and why, and which security posture findings come first, each tied to what Overview, Estate, and Performance show.
permission: Reader or higher on the subscription (Contributors have it, others need P8) for Database Hub itself, which needs no Fabric capacity. Copilot in Database Hub also needs a Fabric capacity with Copilot enabled for your user by the tenant and capacity settings.
responseShape: For each question a short ranked list that names the resource, the signal or finding, its value or severity, and when it changed, then what the answer couldn't see.
previewLimitation: Copilot in Database Hub and Database Agents are previews, while Database Hub itself is generally available (2026-11-17). Answers depend on the signals Database Hub has collected, the newest minutes of telemetry can be missing, and T4 (PostgreSQL) shows metrics only.
fallback: Without Copilot, read the same answers from Overview's What needs attention and Recent signal changes, then Estate and its security findings, then run the showcase.in-hub prompts.
actionPolicy: read-only
adrPrompts: [estate-health-summary, target-most-pressure, safest-next-action]
sources:
  - https://learn.microsoft.com/fabric/database/hub/overview
  - https://learn.microsoft.com/fabric/database/hub/monitor
  - https://learn.microsoft.com/fabric/database/hub/database-agents
reviewed: 2026-11-18
---

# Open at Overview with Copilot's three starting questions

Use at the start of a demo, on Database Hub's **Overview**: these are the three prompts Database Hub's general availability suggests for Copilot (2026-11-17), each with the demo's read-only rule added. Copilot answers from what Database Hub already has: the inventory, the security, performance, and optimization findings, and the telemetry. Then go to Estate, Performance, and the [showcase tour](showcase.in-hub.md).

**Where to type it:** Copilot's pane in Database Hub. Database Hub itself needs no Fabric capacity; Copilot does.

## Prompts

### 1. What changed

```text
What changed in my databases? Don't change anything.
```

### 2. Where to look next

```text
Which resource should I investigate next? Don't change anything.
```

### 3. Security first

```text
Which security findings should I address first? Don't change anything.
```

## Signals to look for

| Question | Where Database Hub shows it | What the demo puts there |
|---|---|---|
| What changed | Overview's **Recent signal changes** and **What needs attention** | The showcase's beats in the last hour: CPU on T1 and T2, T3 at its service tier's limit, blocking and deadlocks; and T3's plan regression in the second cycle, the Database Agent loop |
| Investigate next | Overview's issues, ranked; Estate sorted by open issues | The target in the beat that's running now, and T3 while the Database Agent's issue is open |
| Security first | Estate's security findings: Microsoft Entra authentication, auditing, and customer-managed keys | T3 is Entra-only; findings on the other targets follow their own configuration |

- **Optimization** is a card in Overview's **What needs attention**, and an issue on a resource's row in Estate: license-model opportunities and SQL Servers that don't report usage. T2 (`arcsql01`) has its migration assessment ready, which isn't an issue, so look for it on T2 in Estate. T1 and T2 already use pay-as-you-go, so neither shows a license-model opportunity.

## How to judge the answer

- Each answer names resources the demo deployed, with a signal or finding Database Hub shows, not a generic checklist.
- "What changed" ties each change to a time, and a quiet target isn't read as healthy when its telemetry is missing.
- "Investigate next" gives a reason and a link to the evidence, and the security ranking says why its first finding comes first.

## Safety

- If Copilot offers to change anything, read it out and cancel it. The demo changes targets only through its own controls, and Database Agents never applies a change itself.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Read Overview's **What needs attention** and **Recent signal changes** aloud, then open the first resource.
2. In Estate, sort by open issues, then filter to security findings.
3. Run [showcase.in-hub](showcase.in-hub.md)'s prompts.
4. Last resort: the screenshots recorded in the rehearsal.
