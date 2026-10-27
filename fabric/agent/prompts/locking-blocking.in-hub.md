---
id: locking-blocking.in-hub
name: Investigate locking and blocking in Database Hub
scenario: locking-blocking
incident: true
targets: [T1, T2, T3]
defaultTarget: T1
surface: in-hub-agent
hosts: [database-hub]
dataSources: [hub-estate, hub-performance]
capability: Finds whether sessions on the chosen target are blocked, when it started, and which database is affected, then correlates the blocking with CPU, memory, IO, sessions, and recent changes, and lists its evidence. Coverage per target isn't documented, so the live check records it.
permission: A Fabric Free license or higher, with the Database Hub tenant setting on (P4); Reader or higher on the subscription (Contributors have it, others need P8); Microsoft.Sql registered and performance monitoring enabled for the target. Agent-specific permissions aren't documented, TODO(verify).
responseShape: A one-sentence verdict, then a short table of signals with the metric, UTC window, and value, then what happened at the same time versus what caused it, then what the agent couldn't see.
previewLimitation: The Database Agent and Copilot in Database Hub are previews with undocumented target coverage and latency. Database Hub telemetry describes resources, not individual queries or blocking chains, and arrives a few minutes after the samples.
fallback: Run locking-blocking.skills in Copilot CLI. Without an agent, show the target on the Performance page and run Learn telemetry sample queries 8 and 5 in the Azure Data Explorer web UI.
actionPolicy: read-only
adrPrompts: [investigate-locking, correlate-signals, supporting-evidence]
sources:
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
  - https://learn.microsoft.com/fabric/database/hub/faq
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking
reviewed: 2026-10-20
---

# Investigate locking and blocking in Database Hub

The incident beat for [locking and blocking](../../../scenarios/locking-blocking/README.md). It runs on T1 by default and on any target on request. Start the scenario, wait for at least two telemetry samples (a few minutes), then ask.

**Where to type it:** open the target from Estate or Performance, then the agent or Copilot pane where your tenant shows it. If an issue already appears for the target, start from its issue details. TODO(verify) the entry point in the live check.

## Prompts

### 1. Investigate the blocking

```text
Is anything blocked on {target}? If so, which database is affected, since when, how many sessions are waiting, and what do you know about the session at the head of the chain? Use only what Database Hub shows, and name each signal you used. Don't change anything.
```

### 2. Correlate with other signals

```text
For {incidentWindow} on {target}, did CPU, memory, storage IO, active sessions, or any configuration change at the same time as the blocking? Keep what happened at the same time apart from what caused it. Don't change anything.
```

### 3. Supporting evidence

```text
List the evidence behind your conclusion about {target}: metric names, the UTC window, the values, and what you couldn't see. Don't change anything.
```

## Signals to look for

| Target | Telemetry signals Database Hub can draw on | Notes |
|---|---|---|
| T1 (default) | `Processes blocked` above 0; Lock-category waits (`LCK_M_*`) with few tasks and a long average wait; `Active Transactions` up; active sessions from `ContosoCare.Demo/` | SQL Server 2022 uses the classic lock manager |
| T2 | The same as T1 | Nested-guest Performance support is validated live |
| T3 | Lock-category waits and `Processes blocked`; `Number of Deadlocks/sec` stays flat unless the optional deadlock runs | Optimized locking and read committed snapshot are on, so readers don't wait on writers, and writer-to-writer waits can be on transaction ID (`XACT`) resources |

- The scenario window comes from the demo control output or `demo.scenario_runs` (`started_at`, `deadline_at`, `stopped_at`).
- Telemetry describes resources. Session IDs, statements, and lock resources need a query on the database (see the skills version).

## How to judge the answer

- It names the target, the database (`ContosoCare`), and a UTC window that overlaps the scenario run.
- It cites at least one blocking signal by name, such as `Processes blocked` or Lock-category waits.
- It doesn't blame CPU, memory, or IO for the blocking without evidence that they moved.
- It says plainly what it can't see, such as the blocking chain or the statement text.

## Safety

- If the agent proposes ending a session, don't approve it. The scenario's watchdog rolls the blocker back at its deadline, and the scenario stop control ends it early (Phase 11). Neither touches sessions outside `ContosoCare.Demo/`.
- Never approve an action on a resource outside the demo resource group.

## Fallback demo

1. Run [locking-blocking.skills](locking-blocking.skills.md) in Copilot CLI.
2. Without an agent: open the target on the Performance page, then run the Learn telemetry sample queries 8 and 5 for the incident window in the [Azure Data Explorer web UI](https://dataexplorer.azure.com).
3. Last resort: the screenshots recorded in the rehearsal.
