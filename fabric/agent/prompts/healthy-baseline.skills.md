---
id: healthy-baseline.skills
name: Estate health summary and baseline with Copilot CLI or VS Code
scenario: healthy-baseline
incident: false
targets: [T1, T2, T3]
surface: skills
hosts: [copilot-cli, vscode]
dataSources: [databasehub-skill, telemetry-endpoint]
capability: Lists the demo targets that Database Hub and the telemetry endpoint can see, with resource type, last sample time, and available history, and summarizes CPU, memory, storage, and blocking over a baseline window so an incident can be compared with it later.
permission: Signed in to the Azure CLI as yourself in the demo tenant. The Database Hub skill needs a delegated user and the same Database Hub access as the in-Hub surface (P4); the telemetry endpoint needs Reader or higher on the subscription and Microsoft.Sql registered.
responseShape: A table with one row per resource (type, last sample time, days of history, and CPU, memory, and blocking ranges), followed by coverage gaps, partial results, and the KQL or skill calls it ran.
previewLimitation: The microsoft-sql-fdh plugin is read-only and calls Database Hub routes that its authors say aren't a public contract and can change; its health data covers CPU, storage, and memory, not IO. The telemetry endpoint and schema are previews with up to 7 days of retention.
fallback: Without an agent, run the Learn telemetry sample queries 1, 2, 3, and 8 in the Azure Data Explorer web UI against the documented connection and database, then show the Database Hub Performance page.
actionPolicy: read-only
adrPrompts: [estate-health-summary, target-most-pressure, baseline-vs-incident]
sources:
  - https://github.com/microsoft/microsoft-sql/tree/main/plugins/microsoft-sql-fdh
  - https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry
  - https://learn.microsoft.com/fabric/database/hub/monitor-sql
reviewed: 2026-10-20
---

# Estate health summary and baseline with Copilot CLI or VS Code

The skills version of the "before" beat. Run [session-setup.skills](session-setup.skills.md) first, then these prompts while the `baseline` activity profile is on ([healthy baseline](../../../scenarios/healthy-baseline/README.md)).

## Prompts

### 1. Estate inventory and health from Database Hub

```text
Use the Database Hub skill to show the SQL resources in resource group {resourceGroup}, grouped by engine and subscription, with CPU, storage, and memory health over the last hour. Report coverage, partial results, and anything you couldn't read. Don't change anything.
```

### 2. Who is reporting telemetry

```text
Using the telemetry agent instructions, adapt the Learn page's sample queries 1 and 2 to resource group {resourceGroup}. List each resource that reports, with its ResourceType, ResourceName, SqlServerInstanceName, last sample time, and the oldest sample available. Don't change anything.
```

### 3. Baseline ranges and the target with the most pressure

```text
For resource group {resourceGroup} over {baselineWindow}, adapt sample query 3 for CPU and sample query 8 for blocking and memory pressure. Give average, p95, and maximum CPU, the maximum processes blocked, and the minimum page life expectancy for each resource, then name the resource under the most pressure and the signal that shows it. Don't change anything.
```

## Signals to look for

| Target | `ResourceType` in telemetry | `ResourceName` | Baseline signals |
|---|---|---|---|
| T1 | `virtualMachines` (`Microsoft.Compute`) | `sqlvm01`, instance `MSSQLSERVER` | Low CPU as a share of all logical CPUs; `Processes blocked` at 0 |
| T2 | `machines` (`Microsoft.HybridCompute`) | `arcsql01`, instance `MSSQLSERVER` | As T1. Absent if T2 is in the `Developer` install mode, which has no Hub Performance |
| T3 | `servers/databases` (`Microsoft.Sql`) | `azuresql01-<deploymentId>/ContosoCare` | CPU as a share of the service-tier limit; gaps while the serverless database is paused |

- The Database Hub skill reports CPU, storage, and memory, not IO, and it says so when coverage is partial.
- A resource missing from the telemetry has monitoring off, or your identity can't read it. It isn't healthy by default.

## How to judge the answer

- Every number has a resource, a metric, and a UTC window.
- Cumulative counters are reported as deltas, never as sums of raw samples.
- It says how many resources the answer covers and which are missing.
- It shows the KQL it ran, and the skill names the routes it used without printing a token.

## Safety

- Approve only read commands: `az rest` GET or POST calls to the Database Hub routes the skill names, and POST calls to the telemetry query endpoint. Reject anything else.
- Don't let the agent sign in, register providers, or change settings for you.

## Fallback demo

1. In the [Azure Data Explorer web UI](https://dataexplorer.azure.com), add the connection from the [telemetry page](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry), then run its sample queries 1, 2, 3, and 8 with a resource group filter.
2. Show the Database Hub Performance page with the three targets selected.
3. Last resort: the screenshots recorded in the rehearsal.
