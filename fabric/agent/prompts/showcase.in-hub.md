---
id: showcase.in-hub
name: Tour the showcase across every target in Database Hub
scenario: any
incident: true
targets: [T1, T2, T3]
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Summarizes the estate while the showcase runs, ranks the targets by pressure, names the incident each one is in now and the one before it, and compares an incident window with the baseline, across T1, T2, and T3 together.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for each target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A ranked table of the targets with the dominant signal, its value, and the UTC window, then for the chosen target the incidents in order with their windows, then a baseline-versus-incident comparison, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. The showcase rotates incidents every few minutes and telemetry lags 3 to 15 minutes, so the newest slot can be missing. T4 (PostgreSQL) is metrics only in Database Hub and outside the prompt pack.
fallback: Run showcase.skills in Copilot CLI. Without an agent, walk the Performance page target by target with the schedule in the README's table of what fills each visual, and use each scenario's own prompt file.
actionPolicy: read-only
adrPrompts: [estate-health-summary, target-most-pressure, correlate-signals, baseline-vs-incident]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/add-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
reviewed: 2026-11-03
---

# Tour the showcase across every target in Database Hub

Use while **Run all** in the control notebook runs the showcase: the baseline on every target plus a 30-minute rotation of incidents, at most two at a time per target (the [README](../../../README.md#what-fills-each-database-hub-visual-and-when) has the schedule). These prompts tour the estate; for a closer look at one incident, use its scenario's prompt file, and finish with [incident-wrap-up.in-hub](incident-wrap-up.in-hub.md).

Start about 30 minutes after Run all, so the first cycle has reached the telemetry.

**Where to type it:** the agent or Copilot pane on Database Hub's Overview or Performance page, where your tenant shows it. TODO(verify) the entry point in the live check.

## Prompts

### 1. The estate right now

```text
Across my SQL databases in {resourceGroup}, which are under the most pressure in {incidentWindow}, and what is the dominant signal on each: CPU, waits by category, blocking, deadlocks, log, or service-tier limits? Rank them in a table with the value and the UTC window. Don't change anything.
```

### 2. One target's incidents in order

```text
On {target}, list the distinct incidents in {incidentWindow} in time order: for each, the signal that marks it, when it started and ended, and its peak value. Don't change anything.
```

### 3. Against the baseline

```text
Compare {incidentWindow} with {baselineWindow} on {target}: which signals moved away from the baseline, by how much, and which stayed flat? Answer as a table. Don't change anything.
```

## Signals to look for

| Target | Incidents in each 30-minute cycle (minutes from the target's start) | Signals |
|---|---|---|
| T1 | Blocking chain 0-10, log flushes 2-10, deadlocks 11-21, CPU 22-29 | Processes blocked and Lock waits; `WRITELOG`; deadlocks; CPU waits |
| T2 | CPU 2-14, memory grants 10-18, IO 18-26, parallelism or tempdb 22-29 | CPU; Memory waits; IO stalls; Parallelism or Buffer Latch waits |
| T3 | CPU cap 1-13, blocking or deadlocks 13-25, network, missing index, or the plan regression 15-25, log rate 25-30 | CPU against the tier and **limited by service tier**; Lock waits or deadlocks; Network IO waits or reads; Log Rate Governor |

- Each target's cycle starts when its own activity starts, so the targets are a few minutes apart.

## How to judge the answer

- The ranking uses a metric and a window for each target, not impressions.
- It names incidents that overlap the schedule above, and treats a gap or the newest minutes as missing data, not as a healthy period.
- The comparison shows the incident's signals moving and the unrelated ones flat.

## Safety

- If the agent offers to change anything on a target, read it out and cancel it. The showcase stops by itself; the control notebook's Stop now and Reset are the demo's own controls.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [showcase.skills](showcase.skills.md) in Copilot CLI.
2. Without an agent: walk Database Hub's Performance page target by target with the schedule above.
3. Use each scenario's own prompt file for the incident in progress.
4. Last resort: the screenshots recorded in the rehearsal.
