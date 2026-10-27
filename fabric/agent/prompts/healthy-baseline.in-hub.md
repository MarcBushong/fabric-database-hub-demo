---
id: healthy-baseline.in-hub
name: Estate health summary and baseline in Database Hub
scenario: healthy-baseline
incident: false
targets: [T1, T2, T3]
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Summarizes what Database Hub shows for the three demo targets (inventory, issues and suggestions, CPU, memory, storage, and IO), says which target is under the most pressure, and describes a normal range that an incident can be compared with later.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for each target. Agent-specific permissions aren't documented, so the live check records them, TODO(verify).
responseShape: A short estate summary, then one row per target with its resource type, whether it has performance data, its open issues and suggestions, and its CPU and memory range, then what the agent couldn't see.
previewLimitation: Database Hub, its Database Agent, and Copilot are previews. Supported targets, prerequisites, and latency of the agent aren't documented, and answers vary between runs. A newly created T3 can show findings late.
fallback: Run healthy-baseline.skills in Copilot CLI. Without an agent, show Overview and Estate filtered to the demo resource group, then the Performance page with the three targets selected.
actionPolicy: read-only
adrPrompts: [estate-health-summary, target-most-pressure, baseline-vs-incident]
sources:
  - https://learn.microsoft.com/fabric/database/hub/overview
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/faq
  - https://learn.microsoft.com/fabric/database/hub/add-sql
reviewed: 2026-10-20
---

# Estate health summary and baseline in Database Hub

The "before" beat: one hybrid estate in one place. Run it while the `baseline` activity profile is on ([healthy baseline](../../../scenarios/healthy-baseline/README.md)), ideally after at least 30 minutes of baseline traffic so the charts have history.

**Where to type it:** open [Database Hub](https://powerbi.com/workloads/fdh/databaseHub), filter Estate to the demo resource group, and open the agent or Copilot pane where your tenant shows it. The entry point's name and placement aren't documented, TODO(verify) in the live check.

## Prompts

### 1. Estate health summary

```text
Summarize the health of the SQL resources in resource group {resourceGroup}: a SQL Server on an Azure VM, an Arc-enabled SQL Server, and an Azure SQL database. For each one, say what kind of resource it is, whether Database Hub has performance data for it, and which issues or suggestions are open. Use the last hour. Don't change anything.
```

### 2. Target with the most pressure

```text
Of the SQL resources in resource group {resourceGroup}, which one is under the most pressure right now, by CPU, memory, storage, or IO? For each, name the metric, the time window, and the value you used, and say if a resource has no recent data. Don't change anything.
```

### 3. Baseline for later comparison

```text
Describe the normal range on {target} over {baselineWindow} for CPU, memory, waits, active sessions, and blocking. I'll compare an incident with it later, so give ranges rather than single numbers, and say which signals you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Appears in Estate as | Performance data | Baseline signals |
|---|---|---|---|
| T1 `sqlvm01` | SQL Server on an Azure VM, through the SQL IaaS Agent extension | Yes once monitoring is on (Phase 9) | Low, steady CPU; no blocked processes; steady sessions from the runner, tagged `ContosoCare.Demo/` |
| T2 `arcsql01` | SQL Server enabled by Azure Arc, disclosed as a simulated on-premises server | Only for Standard or Enterprise with pay-as-you-go or Software Assurance; the `Developer` install mode shows Estate only | As T1. Nested-guest Performance support is validated live |
| T3 `azuresql01-<deploymentId>` / `ContosoCare` | Azure SQL Database | Yes once the extended property is set | CPU as a percentage of the service-tier limit; gaps while the serverless database is paused |

Security findings can also appear, for example public network access or Microsoft Entra authentication. They're real findings about the demo's configuration, not part of the incident.

## How to judge the answer

- It names all three targets, or says why one is missing: permissions, monitoring not enabled, region, or the preview.
- It keeps "no data" apart from "healthy". The Database Hub FAQ says no data means neither.
- It states the time window behind every number.
- It proposes nothing during the baseline, or labels any suggestion as optional and unapplied.

## Safety

- The data is synthetic, but treat the transcript as customer-facing. Never paste secrets, tokens, or connection strings into the chat.
- If the agent offers an action, read it, then cancel it. The baseline beat never changes anything.

## Fallback demo

1. Run [healthy-baseline.skills](healthy-baseline.skills.md) in Copilot CLI.
2. Without an agent: show Overview, then Estate filtered to the demo resource group, then Performance with the three targets selected.
3. Last resort: the screenshots recorded in the rehearsal.
