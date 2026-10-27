# Prompt index

Every prompt in the pack, by scenario and surface. The install steps, the safety rules, and the live coverage record are in the [agent guide](../README.md). The decision behind the pack is [ADR 0013](../../../docs/adr/0013-agent-experience.md).

## How to run a demo with the pack

1. **Skills surface only:** start each Copilot CLI or VS Code session with [session-setup.skills](session-setup.skills.md).
2. **Before:** run the healthy baseline prompts while the `baseline` profile runs.
3. **Incident:** start one scenario on one target, wait for a few minutes of samples, then run that scenario's prompts on the in-Hub surface first and the skills surface as the fallback.
4. **Wrap-up:** finish with the incident wrap-up prompts on the same surface.

Every incident prompt works on T1, T2, and T3, because the Database Agent's target coverage isn't documented. Each file says which signals to expect on each target and which data sources apply there.

## Placeholders

Replace these before you send a prompt. Nothing else in a prompt needs editing.

| Placeholder | Meaning | Example |
|---|---|---|
| `{target}` | The target as Database Hub and the telemetry name it: T1 `sqlvm01`, T2 `arcsql01`, T3 `azuresql01-<deploymentId>/ContosoCare` | `sqlvm01` |
| `{resourceGroup}` | The demo resource group, `rg-<prefix>-<env>` | `rg-dbhub-demo` |
| `{incidentWindow}` | The scenario run's UTC start and end, from the demo control output or `demo.scenario_runs` | `2026-10-20T15:00Z to 2026-10-20T15:20Z` |
| `{baselineWindow}` | A window of the same length before the incident, with the `baseline` profile running | `2026-10-20T14:30Z to 2026-10-20T14:50Z` |

## Prompt files

| Prompt file | Scenario | Surface | Targets | Default target | ADR 0013 prompts |
|---|---|---|---|---|---|
| [session-setup.skills](session-setup.skills.md) | setup | skills | T1, T2, T3 | | none (session rules) |
| [healthy-baseline.in-hub](healthy-baseline.in-hub.md) | healthy-baseline | in-Hub agent | T1, T2, T3 | | estate health summary; target with the most pressure; baseline |
| [healthy-baseline.skills](healthy-baseline.skills.md) | healthy-baseline | skills | T1, T2, T3 | | estate health summary; target with the most pressure; baseline |
| [locking-blocking.in-hub](locking-blocking.in-hub.md) | locking-blocking | in-Hub agent | T1, T2, T3 | T1 | investigate locking; correlate; evidence |
| [locking-blocking.skills](locking-blocking.skills.md) | locking-blocking | skills | T1, T2, T3 | T1 | investigate locking; correlate; evidence |
| [cpu-pressure.in-hub](cpu-pressure.in-hub.md) | cpu-pressure | in-Hub agent | T1, T2, T3 | T2 | target with the most pressure; correlate; inefficient queries; evidence |
| [cpu-pressure.skills](cpu-pressure.skills.md) | cpu-pressure | skills | T1, T2, T3 | T2 | target with the most pressure; correlate; inefficient queries; evidence |
| [io-pressure.in-hub](io-pressure.in-hub.md) | io-pressure | in-Hub agent | T1, T2, T3 | T2 | correlate; evidence |
| [io-pressure.skills](io-pressure.skills.md) | io-pressure | skills | T1, T2, T3 | T2 | correlate; evidence |
| [missing-index.in-hub](missing-index.in-hub.md) | missing-index | in-Hub agent | T1, T2, T3 | T2 | inefficient queries; safest next action; actions needing approval |
| [missing-index.skills](missing-index.skills.md) | missing-index | skills | T1, T2, T3 | T2 | inefficient queries; safest next action; actions needing approval |
| [inefficient-query.in-hub](inefficient-query.in-hub.md) | inefficient-query | in-Hub agent | T1, T2, T3 | T2 | inefficient queries; correlate; evidence |
| [inefficient-query.skills](inefficient-query.skills.md) | inefficient-query | skills | T1, T2, T3 | T2 | inefficient queries; correlate; evidence |
| [resource-governance.in-hub](resource-governance.in-hub.md) | resource-governance (T3) | in-Hub agent | T1, T2, T3 | T3 | target with the most pressure; correlate; evidence |
| [resource-governance.skills](resource-governance.skills.md) | resource-governance (T3) | skills | T1, T2, T3 | T3 | target with the most pressure; correlate; evidence |
| [log-rate-pressure.in-hub](log-rate-pressure.in-hub.md) | log-rate-pressure | in-Hub agent | T1, T2, T3 | T3 | target with the most pressure; correlate; evidence |
| [log-rate-pressure.skills](log-rate-pressure.skills.md) | log-rate-pressure | skills | T1, T2, T3 | T3 | target with the most pressure; correlate; evidence |
| [blocking-chain.in-hub](blocking-chain.in-hub.md) | blocking-chain | in-Hub agent | T1, T2, T3 | T1 | investigate locking; correlate; evidence |
| [blocking-chain.skills](blocking-chain.skills.md) | blocking-chain | skills | T1, T2, T3 | T1 | investigate locking; correlate; evidence |
| [deadlock-storm.in-hub](deadlock-storm.in-hub.md) | deadlock-storm | in-Hub agent | T1, T2, T3 | T1 | investigate locking; correlate; evidence |
| [deadlock-storm.skills](deadlock-storm.skills.md) | deadlock-storm | skills | T1, T2, T3 | T1 | investigate locking; correlate; evidence |
| [tempdb-contention.in-hub](tempdb-contention.in-hub.md) | tempdb-contention | in-Hub agent | T1, T2, T3 | T2 | target with the most pressure; correlate; evidence |
| [tempdb-contention.skills](tempdb-contention.skills.md) | tempdb-contention | skills | T1, T2, T3 | T2 | target with the most pressure; correlate; evidence |
| [memory-grant-pressure.in-hub](memory-grant-pressure.in-hub.md) | memory-grant-pressure | in-Hub agent | T1, T2, T3 | T2 | correlate; inefficient queries; evidence |
| [memory-grant-pressure.skills](memory-grant-pressure.skills.md) | memory-grant-pressure | skills | T1, T2, T3 | T2 | correlate; inefficient queries; evidence |
| [parallel-scans.in-hub](parallel-scans.in-hub.md) | parallel-scans | in-Hub agent | T1, T2, T3 | T2 | inefficient queries; correlate; evidence |
| [parallel-scans.skills](parallel-scans.skills.md) | parallel-scans | skills | T1, T2, T3 | T2 | inefficient queries; correlate; baseline compared with incident; evidence |
| [log-flush-waits.in-hub](log-flush-waits.in-hub.md) | log-flush-waits | in-Hub agent | T1, T2, T3 | T1 | correlate; evidence |
| [log-flush-waits.skills](log-flush-waits.skills.md) | log-flush-waits | skills | T1, T2, T3 | T1 | correlate; evidence |
| [slow-consumer.in-hub](slow-consumer.in-hub.md) | slow-consumer | in-Hub agent | T1, T2, T3 | T3 | correlate; evidence |
| [slow-consumer.skills](slow-consumer.skills.md) | slow-consumer | skills | T1, T2, T3 | T3 | correlate; evidence |
| [capacity-max.in-hub](capacity-max.in-hub.md) | capacity-max | in-Hub agent | T1, T2, T3 | T1 | target with the most pressure; correlate; evidence |
| [capacity-max.skills](capacity-max.skills.md) | capacity-max | skills | T1, T2, T3 | T1 | target with the most pressure; correlate; baseline compared with incident; evidence |
| [incident-wrap-up.in-hub](incident-wrap-up.in-hub.md) | any | in-Hub agent | T1, T2, T3 | | customer root cause; evidence; baseline compared with incident; safest next action; approvals; what to verify; incident summary |
| [incident-wrap-up.skills](incident-wrap-up.skills.md) | any | skills | T1, T2, T3 | | customer root cause; evidence; baseline compared with incident; safest next action; approvals; what to verify; incident summary |

Phase 11 added the `resource-governance` and `log-rate-pressure` scenario folders. The resource-governance prompts also apply when the `cpu-pressure` and `inefficient-query` scenarios run on T3, which produces the same pressure.

Phase 25b added eight scenarios, one per wait family, each with a prompt file on both surfaces: `blocking-chain` (Lock), `deadlock-storm` (deadlocks), `tempdb-contention` (Buffer Latch), `memory-grant-pressure` (Memory), `parallel-scans` (Parallelism), `log-flush-waits` (Tran Log IO), `slow-consumer` (Network IO), and `capacity-max` (CPU and Buffer IO together). The resource-governance prompts also apply when `capacity-max` runs on T3, and the log-rate-pressure prompts when `log-flush-waits` reaches the log-rate limit there.

## Front matter convention

Each prompt file starts with YAML front matter that [prompt.schema.json](prompt.schema.json) describes. `tests/unit/Agent.PromptPack.Tests.ps1` validates every file against it and checks the rules below.

| Field | Meaning |
|---|---|
| `id` | The file name without `.md`: `<name>.in-hub` or `<name>.skills` |
| `scenario` | A folder under `scenarios/`, or `any` or `setup` |
| `incident`, `targets`, `defaultTarget` | Incident prompts must list T1, T2, and T3 |
| `surface`, `hosts` | `in-hub-agent` on `database-hub`, or `skills` on `copilot-cli` and `vscode` |
| `dataSources` | Where the answer comes from: Database Hub, the Database Hub skill, the telemetry endpoint, the SQL diagnostics skills, the scenario record, or the Learn MCP server |
| `capability`, `permission`, `responseShape`, `previewLimitation`, `fallback` | The expected capability, the required permission, the shape the prompt asks for, the preview limitation, and the fallback demo |
| `actionPolicy` | `read-only`, or `propose-only` when the prompt asks for a proposal that's never applied |
| `adrPrompts` | The ADR 0013 prompt kinds the file covers. Both surfaces together cover all twelve |
| `sources`, `reviewed` | HTTPS links to Microsoft Learn, GitHub, or VS Code documentation, and the date they were checked |

Rules the tests enforce:

- Every prompt is a `text` code block that says "Don't change anything" or, for proposals, "Don't apply anything; propose only", so the rule travels with the prompt when you copy it alone.
- Prompts use only the four placeholders above.
- No file hard-codes an answer: files describe signals and how to judge an answer, never the answer itself.
- No secrets, no private Database Hub routes, and only `https://` links.
- This index lists every prompt file exactly once.
