---
id: blocking-chain.in-hub
name: Investigate a deep blocking chain in Database Hub
scenario: blocking-chain
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds how many sessions on the chosen target are blocked and for how long, tells queued sessions from whole-table locking where the target shows it, and correlates the blocking with throughput, CPU, memory, and sessions. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a table of signals with the metric, UTC window, and value, then what the agent can and can't say about the shape of the blocking, then what happened at the same time versus what caused it, then gaps.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry is resource-level, so it counts blocked processes but doesn't show who blocks whom, how deep the chain is, or which lock resources are held.
fallback: Run blocking-chain.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 8, 5, and 9 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [investigate-locking, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide
  - https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking
reviewed: 2026-10-23
---

# Investigate a deep blocking chain in Database Hub

The incident beat for the [deep blocking chain](../../../scenarios/blocking-chain/README.md): one head blocker, branches of sessions that each wait on the one before, and a table lock from lock escalation every few minutes. It runs on T1 by default and on any target on request. Start the scenario, wait for at least two telemetry samples (a few minutes), then ask.

**Where to type it:** open the target from Estate or Performance, then the agent or Copilot pane where your tenant shows it. If an issue already appears for the target, start from its issue details. TODO(verify) the entry point in the live check.

## Prompts

### 1. How bad is the blocking

```text
Is anything blocked on {target}? How many sessions wait at the worst point, since when, in which database, and do the waits look like a few long waits or many short ones? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. A queue or a table lock

```text
On {target} during {incidentWindow}, does the blocking look like sessions queued one behind another, or like a whole-table lock that stops everything at once, or both? Say which signals tell them apart, and say plainly if Database Hub can't show the chain itself. Don't change anything.
```

### 3. What moved with it, and the evidence

```text
For {incidentWindow} on {target}, did throughput, CPU, memory, or active sessions change while sessions were blocked? Keep what happened at the same time apart from what caused it, then list your evidence: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 (default) | `Processes blocked` near the number of waiting links (20 at most), plus the normal workers queued behind an escalation; Lock-category waits (`LCK_M_U` for the links; `LCK_M_IS` and `LCK_M_IX` behind an escalation) with few tasks and long average waits; `Active Transactions` up; batch requests can dip while the table lock is held | SQL Server 2022 escalates a statement's row locks past about 5,000 locks on one table; lock escalation counters exist only in the detailed counters, if the target lists them |
| T2 | The same as T1 | Nested-guest Performance support is validated live |
| T3 | `Processes blocked` and Lock waits on transaction-ID locks (`LCK_M_S_XACT_MODIFY`) | Optimized locking is always on, so the chain forms but there's no escalation |

- The chain's depth and who blocks whom aren't in the telemetry; the skills version reads them from the database.
- The scenario window comes from the demo control output or `demo.scenario_runs`; each escalation is a `lock-escalation` event in `demo.scenario_run_events`.

## How to judge the answer

- It names the target, the database (`ContosoCare`), and a UTC window that overlaps the scenario run.
- It reports blocking from a blocking signal, such as `Processes blocked` or Lock-category waits, not from CPU or IO.
- It doesn't claim a chain depth, a head blocker, or a lock resource that Database Hub can't show; it says what it can't see.
- On T3, it doesn't report lock escalation.

## Safety

- If the agent proposes ending the head blocker or any other session, don't approve it. Each link waits 60 seconds at most, every change rolls back, and the scenario's watchdog and stop control end the run without touching sessions outside `ContosoCare.Demo/`.
- If it proposes disabling lock escalation, adding an index, or changing an isolation level, read it out as a proposal and cancel it.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [blocking-chain.skills](blocking-chain.skills.md) in Copilot CLI.
2. Without an agent: open the target on the Performance page, then run the Learn telemetry sample queries 8, 5, and 9 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
