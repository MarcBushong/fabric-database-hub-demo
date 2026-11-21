// The incident catalog the Manage page offers: the scenarios in scenarios/*/scenario.json, with the targets each one
// applies to and its duration bounds. The control's runbook checks every request against the same catalog again
// (automation/runbooks/DbHubControl.Common.ps1), so this list only shapes the form. scenarios.test.ts keeps it in sync.

import type { FilterTarget } from "./view-state";

export interface ScenarioInfo {
    id: string;
    title: string;
    targets: FilterTarget[];
    defaultMinutes: number;
    maxMinutes: number;
}

export const SCENARIOS: readonly ScenarioInfo[] = [
    { id: "blocking-chain", title: "Deep blocking chain and lock escalation", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "capacity-max", title: "Capacity maxed out", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 20 },
    { id: "connection-surge", title: "Connection surge (capacity maxed)", targets: ["T4"], defaultMinutes: 5, maxMinutes: 15 },
    { id: "cpu-pressure", title: "CPU pressure", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "deadlock-storm", title: "Deadlock storm", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "healthy-baseline", title: "Healthy baseline", targets: ["T1", "T2", "T3", "T4", "T5"], defaultMinutes: 30, maxMinutes: 240 },
    { id: "idle-in-transaction", title: "Idle in transaction", targets: ["T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "inefficient-query", title: "Inefficient query", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "io-pressure", title: "IO pressure", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "locking-blocking", title: "Locking and blocking", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "log-flush-waits", title: "Log flush waits", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "log-rate-pressure", title: "Log-rate pressure", targets: ["T1", "T2", "T3"], defaultMinutes: 5, maxMinutes: 15 },
    { id: "memory-grant-pressure", title: "Memory grant pressure", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "missing-index", title: "Missing index", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "parallel-scans", title: "Parallelism waits", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "plan-regression", title: "Plan regression (automatic plan correction)", targets: ["T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "replica-lag", title: "Read replica lag", targets: ["T4"], defaultMinutes: 10, maxMinutes: 15 },
    { id: "resource-governance", title: "Resource governance (CPU cap)", targets: ["T1", "T2", "T3"], defaultMinutes: 5, maxMinutes: 20 },
    { id: "ru-storm", title: "RU storm (request rate too large)", targets: ["T5"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "slow-consumer", title: "Slow consumer", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "tempdb-contention", title: "tempdb allocation contention", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
];

/** A session's bounds: the showcase profile's (scenarios/activity-profiles.json): 30 to 120 minutes, 90 by default. */
export const SESSION_MINUTES = { min: 30, max: 120, default: 90 } as const;

/** A readable name for a 'Scenario Runs' profile: a session's plan, "incident:<scenario>", a reset, or a stop. */
export function profileLabel(profile: string): string {
    const p = profile.trim();
    if (!p || p === "showcase" || p === "session") return "Session";
    if (p === "reset") return "Reset";
    if (p === "stop") return "Stop";
    const incident = /^incident:(.+)$/.exec(p);
    if (incident) return SCENARIOS.find((x) => x.id === incident[1])?.title ?? incident[1];
    return p;
}
