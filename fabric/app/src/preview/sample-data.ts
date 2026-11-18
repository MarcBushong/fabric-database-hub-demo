// Made-up history for the local preview (npm run dev:sample) and for screenshots: a week of a hybrid estate with the
// demo's incidents, shaped exactly like the connector's results. No IDs, URLs, or accounts from a real deployment.

import type { QuerySpec } from "@/data/queries";
import type { Row } from "@/data/query-client";

/** The newest telemetry day: the sample's week ends here. */
export const SAMPLE_LATEST_DAY = Date.UTC(2026, 10, 17);
const DAYS = 7;
const BIN_MIN = 15;
const MIN = 60000;

function mulberry32(seed: number) {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

const iso = (ms: number) => new Date(ms).toISOString().slice(0, 19);
const round = (v: number, d = 1) => Math.round(v * 10 ** d) / 10 ** d;

export interface SampleIncident {
    key: string;
    label: string;
    source: string;
    target: "T1" | "T2" | "T3";
    scenario: string;
    family: "cpu" | "io" | "blocking" | "log_rate";
    start: number;
    end: number;
    peakValue: number;
    peakUnit: string;
    verdict: string;
}

const day = (d: number, h: number, m = 0) => SAMPLE_LATEST_DAY - (DAYS - 1 - d) * 86400000 + (h * 60 + m) * MIN;

export const SAMPLE_INCIDENTS: SampleIncident[] = [
    { key: "scenario:T3:cpu:7", label: "T3 CPU pressure", source: "Scenario request", target: "T3", scenario: "plan-regression", family: "cpu", start: day(6, 14, 0), end: day(6, 14, 30), peakValue: 97.5, peakUnit: "%", verdict: "Pass" },
    { key: "detected:T2:io:6", label: "T2 IO pressure", source: "Detected signal", target: "T2", scenario: "", family: "io", start: day(5, 20, 0), end: day(5, 20, 30), peakValue: 11.5, peakUnit: "s", verdict: "Warning" },
    { key: "scenario:T1:blocking:5", label: "T1 Blocking", source: "Scenario request", target: "T1", scenario: "blocking-chain", family: "blocking", start: day(4, 10, 0), end: day(4, 10, 30), peakValue: 12, peakUnit: "sessions", verdict: "Pass" },
    { key: "scenario:T3:log_rate:3", label: "T3 Log-rate pressure", source: "Scenario request", target: "T3", scenario: "log-rate", family: "log_rate", start: day(2, 16, 15), end: day(2, 16, 45), peakValue: 38.2, peakUnit: "s", verdict: "Pass" },
];

interface BinRow {
    at: number;
    target: "T1" | "T2" | "T3";
    cpu: number;
    blocked: number;
    lockWaitS: number;
    bufferIoS: number;
    logRateS: number;
    waitS: number;
    ioMb: number;
    batch: number;
    sessions: number;
}

const BASE = {
    T1: { cpu: 18, batch: 26000, sessions: 9, io: 0.8, mb: 140 },
    T2: { cpu: 12, batch: 14000, sessions: 6, io: 1.6, mb: 210 },
    T3: { cpu: 28, batch: 62000, sessions: 14, io: 0.5, mb: 95 },
} as const;

function inside(at: number, target: string, family: SampleIncident["family"]): number {
    for (const i of SAMPLE_INCIDENTS) {
        if (i.target === target && i.family === family && at >= i.start && at < i.end) {
            const mid = (i.start + i.end) / 2;
            return 1 - Math.abs(at - mid) / ((i.end - i.start) / 2 + BIN_MIN * MIN);
        }
    }
    return 0;
}

let cachedBins: BinRow[] | null = null;

/** Every 15-minute bin of the week for T1, T2, and T3. */
export function sampleBins(): BinRow[] {
    if (cachedBins) return cachedBins;
    const rand = mulberry32(17);
    const out: BinRow[] = [];
    const start = SAMPLE_LATEST_DAY - (DAYS - 1) * 86400000;
    for (let at = start; at < SAMPLE_LATEST_DAY + 86400000; at += BIN_MIN * MIN) {
        const hour = new Date(at).getUTCHours() + new Date(at).getUTCMinutes() / 60;
        const businessDay = 0.55 + 0.45 * Math.max(0, Math.sin(((hour - 7) / 12) * Math.PI));
        for (const target of ["T1", "T2", "T3"] as const) {
            const b = BASE[target];
            const noise = 0.85 + rand() * 0.3;
            const cpuSpike = inside(at, target, "cpu");
            const ioSpike = inside(at, target, "io");
            const blockSpike = inside(at, target, "blocking");
            const logSpike = inside(at, target, "log_rate");
            const cpu = Math.min(99, b.cpu * businessDay * noise + cpuSpike * 72 + logSpike * 18);
            const bufferIoS = b.io * businessDay * noise + ioSpike * 10.5;
            const lockWaitS = 0.05 * noise + blockSpike * 46;
            const logRateS = target === "T3" ? 0.1 * noise + logSpike * 36 : 0;
            const blocked = Math.round(blockSpike * 12);
            const waitS = cpu * 0.6 + bufferIoS * 3 + lockWaitS + logRateS + 2 * noise;
            out.push({
                at,
                target,
                cpu: round(cpu),
                blocked,
                lockWaitS: round(lockWaitS, 2),
                bufferIoS: round(bufferIoS, 2),
                logRateS: round(logRateS, 2),
                waitS: round(waitS, 2),
                ioMb: round(b.mb * businessDay * noise + ioSpike * 900 + logSpike * 400),
                batch: Math.round(b.batch * businessDay * noise * (1 + cpuSpike * 0.4)),
                sessions: Math.round(b.sessions * businessDay * noise + cpuSpike * 18 + blockSpike * 14),
            });
        }
    }
    cachedBins = out;
    return out;
}

function binRow(b: BinRow, withTarget: boolean): Row {
    return {
        "Bucket UTC": iso(b.at),
        ...(withTarget ? { "Target Key": b.target } : {}),
        Cpu: b.cpu,
        Blocked: b.blocked,
        LockWaitS: b.lockWaitS,
        BufferIoS: b.bufferIoS,
        LogRateS: b.logRateS,
        WaitS: b.waitS,
        IoMb: b.ioMb,
        Batch: b.batch,
        Sessions: b.sessions,
    };
}

const WAIT_SPLIT: Record<string, Array<[string, number]>> = {
    T1: [["CPU", 0.34], ["Lock", 0.22], ["Buffer IO (PAGEIOLATCH)", 0.14], ["Network IO", 0.1], ["Worker Thread", 0.08], ["Tran Log IO", 0.07], ["Memory", 0.05]],
    T2: [["Buffer IO (PAGEIOLATCH)", 0.38], ["CPU", 0.22], ["Other Disk IO", 0.14], ["Lock", 0.08], ["Tran Log IO", 0.08], ["Network IO", 0.06], ["Latch", 0.04]],
    T3: [["CPU", 0.41], ["Worker Thread", 0.14], ["Log Rate Governor", 0.12], ["Buffer IO (PAGEIOLATCH)", 0.11], ["Parallelism", 0.09], ["Lock", 0.07], ["Memory", 0.06]],
};

type Filtered = { targets: string[]; from: number | null; to: number | null };

function filtersOf(spec: QuerySpec): Filtered {
    const p = (spec.params ?? {}) as { targets?: string[]; from?: string; to?: string };
    return {
        targets: Array.isArray(p.targets) && p.targets.length > 0 ? p.targets : ["T1", "T2", "T3", "T4", "T4-replica", "T5"],
        from: p.from ? Date.parse(`${p.from}T00:00:00Z`) : null,
        to: p.to ? Date.parse(`${p.to}T00:00:00Z`) + 86400000 : null,
    };
}

const inWindow = (at: number, f: Filtered) => (f.from === null || at >= f.from) && (f.to === null || at < f.to);

function binsFor(spec: QuerySpec): BinRow[] {
    const f = filtersOf(spec);
    return sampleBins().filter((b) => f.targets.includes(b.target) && inWindow(b.at, f));
}

const FINDINGS: Array<[string, string, string, string, number, string, number]> = [
    ["cpu.T3.peak", "cpu", "CPU", "T3", 3, "CPU peaked at 97.5 % at 14:05 UTC, 3.4 times its 7-day median, during the plan-regression beat.", 6],
    ["blocking.T1.chain", "blocking", "Blocking", "T1", 3, "A blocking chain held 12 sessions for 18 minutes; the head blocker ran ContosoCare.Demo/blocking-chain.", 4],
    ["storage_io.T2.pageiolatch", "storage_io", "Storage IO", "T2", 3, "Buffer IO (PAGEIOLATCH) waits ran at 6.2 times their baseline for 30 minutes with no scenario running.", 5],
    ["postgresql.T4-replica.lag", "postgresql", "PostgreSQL", "T4-replica", 3, "Read replica lag on pgreplica01 peaked at 241.4 s at 17:05 UTC (a Warning at 60 s or more).", 6],
    ["telemetry_coverage.T2", "telemetry_coverage", "Telemetry coverage", "T2", 2, "T2 sent 8 of 9 telemetry tables; query store telemetry needs the Arc extension's monitoring setting.", 6],
    ["wait_profile.T3.governor", "wait_profile", "Wait profile", "T3", 4, "Log Rate Governor waits stayed under 2 % of T3's wait time outside the log-rate scenario.", 6],
    ["database_growth.T1", "database_growth", "Database growth", "T1", 4, "ContosoCare grew 1.2 GB in 7 days (2.1 % a day).", 6],
    ["memory_clerks.T2", "memory_clerks", "Memory", "T2", 4, "The buffer pool held 92 % of target memory; no memory grants waited.", 6],
    ["consumption.fabric", "consumption", "Capacity use", "fabric", 4, "The demo's notebooks used 3.1 % of the capacity's CU in the last 24 hours.", 6],
    ["real_time_dashboard.fabric", "real_time_dashboard", "Real-Time Dashboard", "fabric", 4, "RTD_DatabaseHub_LiveView returned rows for T1, T2, and T3.", 6],
    ["estate_pulse.all", "estate_pulse", "Estate pulse", "all", 4, "3 of 3 SQL targets reported in the last 15 minutes.", 6],
    ["counter_deltas.T3.batch", "counter_deltas", "Counters", "T3", 4, "Batch requests per second averaged 71 on T3 and peaked at 140 during the plan-regression beat.", 6],
];

let rowsById: Record<string, () => Row[]> | null = null;

function staticRows(): Record<string, () => Row[]> {
    if (rowsById) return rowsById;
    const bins = sampleBins();
    const latestCapture = SAMPLE_LATEST_DAY + (20 * 60 + 30) * MIN;
    rowsById = {
        "history-meta": () => [
            {
                LatestCapture: iso(latestCapture),
                LatestDay: iso(SAMPLE_LATEST_DAY),
                EarliestDay: iso(SAMPLE_LATEST_DAY - (DAYS - 1) * 86400000),
                HoursSince: 2,
                Freshness: "Pass",
                NotebookRuns: 42,
                ScenarioRequests: 9,
                Incidents: SAMPLE_INCIDENTS.length,
                HasBins: 1,
                T3IncidentStart: iso(SAMPLE_INCIDENTS[0].start),
                T3IncidentEnd: iso(SAMPLE_INCIDENTS[0].end),
                T3LatestBucket: iso(bins[bins.length - 1].at),
            },
        ],
        headlines: () => [{ EstateHeadline: "3 of 3 SQL targets sent telemetry in this period; 4 findings need attention", ReadinessHeadline: "24 checks: 0 failed, 1 manual step, 2 warnings", Freshness: "Pass" }],
        "findings-latest": () =>
            FINDINGS.map(([id, key, analysis, target, sort, text, d]) => ({
                FindingId: id,
                AnalysisKey: key,
                Analysis: analysis,
                TargetKey: target,
                Status: ["", "Fail", "Manual action required", "Warning", "Pass"][sort],
                StatusSort: sort,
                Finding: text,
                CapturedAt: iso(day(d, 20, 30)),
            })),
        "incident-windows": () =>
            SAMPLE_INCIDENTS.map((i) => ({
                Key: i.key,
                Label: i.label,
                Source: i.source,
                TargetKey: i.target,
                Scenario: i.scenario,
                Family: i.family,
                Start: iso(i.start),
                End: iso(i.end),
                DurationMin: (i.end - i.start) / MIN,
                PeakValue: i.peakValue,
                PeakUnit: i.peakUnit,
                Verdict: i.verdict,
            })),
        "readiness-summary": () => [{ Checks: 24, Failed: 0, Manual: 1, Warnings: 2, Passed: 19, NotSupported: 1, NotSelected: 1, Readiness: 0.864, RunLabel: "Run 20261117T203012Z" }],
        "readiness-checks": () => {
            const checks: Array<[string, string, string, number, string, string]> = [
                ["FABRIC.HUB.SETTING", "Fabric", "fabric", 2, "Database Hub's tenant setting can't be read without a Fabric administrator.", "Ask a Fabric administrator to confirm Database Hub is on for the presenter group."],
                ["T2.TELEMETRY.QUERYSTORE", "Telemetry", "T2", 3, "T2 sent 8 of 9 telemetry tables.", "Turn on query store monitoring in the Azure extension for SQL Server's settings."],
                ["T4.REPLICA", "PostgreSQL", "T4", 3, "T4's read replica doesn't exist between sessions.", "Run all in NB_DatabaseHub_Control creates it for the session."],
                ["T1.TELEMETRY", "Telemetry", "T1", 4, "T1 sent 9 telemetry tables; the newest sample is 4 minutes old.", ""],
                ["T3.TELEMETRY", "Telemetry", "T3", 4, "T3 sent 12 telemetry tables; the newest sample is 1 minute old.", ""],
                ["T3.AGENT.PREREQS", "Database Agent", "T3", 4, "Azure RBAC write, the region, and Microsoft SQL monitoring are in place for the Database Agent.", ""],
                ["FABRIC.RTD", "Fabric", "fabric", 4, "RTD_DatabaseHub_LiveView answered for T1, T2, and T3.", ""],
                ["FABRIC.MODEL", "Fabric", "fabric", 4, "SM_DatabaseHub_History refreshed with Direct Lake.", ""],
                ["CONTROL.RUNBOOKS", "Control", "fabric", 4, "DbHub-Control, DbHub-Stop, and DbHub-Monitor are published.", ""],
                ["FABRIC.MIRRORING", "Fabric", "fabric", 6, "Mirroring isn't selected (ADR 0015).", ""],
                ["T2.LICENSE", "Licensing", "T2", 5, "T2 is pay-as-you-go already, so Database Hub shows no license finding.", ""],
            ];
            return checks.map(([id, area, target, sort, message, remediation]) => ({
                RunId: "20261117T203012Z-a",
                CheckId: id,
                Area: area,
                TargetKey: target,
                Status: ["", "Fail", "Manual action required", "Warning", "Pass", "Not supported", "Not selected"][sort],
                StatusSort: sort,
                Message: message,
                Remediation: remediation,
                DocUrl: "https://learn.microsoft.com/fabric/database/hub/overview",
                EvaluationOnly: false,
                CheckedAt: iso(latestCapture),
            }));
        },
        "telemetry-coverage": () => [
            { "Target Key": "T1", Tables: 9, AgeMin: 4.2, Attention: "✓ fresh" },
            { "Target Key": "T2", Tables: 8, AgeMin: 6.8, Attention: "✓ fresh" },
            { "Target Key": "T3", Tables: 12, AgeMin: 1.1, Attention: "✓ fresh" },
        ],
        "connector-check": () => [{ ValidationRows: 264, SnapshotRows: bins.length * 9, Incidents: SAMPLE_INCIDENTS.length }],
        "target-names": () => [
            { TargetKey: "T1", ResourceType: "virtualMachines", ResourceName: "sqlvm01", InstanceName: "MSSQLSERVER", DatabaseName: "ContosoCare" },
            { TargetKey: "T2", ResourceType: "machines", ResourceName: "arcsql01", InstanceName: "MSSQLSERVER", DatabaseName: "ContosoCare" },
            { TargetKey: "T3", ResourceType: "servers/databases", ResourceName: "azuresql01-sample/ContosoCare", InstanceName: "azuresql01-sample", DatabaseName: "ContosoCare" },
        ],
        "postgres-series": () => {
            const out: Row[] = [];
            const start = day(6, 17, 0);
            const points = 13;
            const series: Array<[string, string, (i: number) => number]> = [
                ["T4-replica", "physical_replication_delay_in_seconds", (i) => (i === 1 ? 241.4 : i >= 2 && i <= 4 ? 80 - i * 15 : 2 + (i % 3))],
                ["T4", "cpu_percent", (i) => (i >= 1 && i <= 3 ? 70 + i * 7 : 38 + (i % 4) * 3)],
                ["T4-replica", "cpu_percent", (i) => 9 + (i % 3) * 2],
                ["T4", "memory_percent", (i) => 31 + (i % 2)],
                ["T4", "active_connections", (i) => (i >= 1 && i <= 3 ? 34 : 12 + (i % 3))],
                ["T4-replica", "active_connections", () => 1],
                ["T4", "connections_failed", (i) => (i === 1 ? 3 : i === 2 ? 1 : 0)],
            ];
            for (const [target, metric, f] of series) {
                for (let i = 0; i < points; i++) {
                    out.push({
                        Bucket: iso(start + i * 5 * MIN),
                        TargetKey: target,
                        ResourceName: target === "T4" ? "pgflex01-sample" : "pgreplica01-sample",
                        Metric: metric,
                        Value: round(f(i)),
                        Unit: "",
                        WindowStart: iso(start),
                        WindowEnd: iso(start + 62 * MIN),
                        CapturedAt: iso(start + 66 * MIN),
                    });
                }
            }
            return out;
        },
        "scenario-runs": () => [
            { RequestId: "session:7f3a9c21:05", RequestedAt: iso(day(6, 13, 30) + 1000), TargetKey: "T3", Profile: "incident:plan-regression", DurationMin: 30, Intensity: 5, Concurrency: 2, Dispatch: "webhook", Status: "Pass", Message: "Session 7f3a9c21's Database Agent beat: the plan regresses at 14:03 UTC; the run's response forces the last good plan at 14:26 UTC.", WindowStart: iso(day(6, 14, 0)), WindowEnd: iso(day(6, 14, 30)) },
            { RequestId: "s7", RequestedAt: iso(day(6, 13, 30)), TargetKey: "", Profile: "showcase", DurationMin: 90, Intensity: null, Concurrency: null, Dispatch: "webhook", Status: "Pass", Message: "Session on T1, T2, T3, and T4 with T4's read replica; history saved", WindowStart: iso(day(6, 13, 30)), WindowEnd: iso(day(6, 15, 0)) },
            { RequestId: "s6", RequestedAt: iso(day(5, 19, 30)), TargetKey: "", Profile: "showcase", DurationMin: 90, Intensity: null, Concurrency: null, Dispatch: "webhook", Status: "Pass", Message: "Session on T1, T2, T3, and T4; history saved", WindowStart: iso(day(5, 19, 30)), WindowEnd: iso(day(5, 21, 0)) },
            { RequestId: "s5", RequestedAt: iso(day(4, 9, 45)), TargetKey: "T1", Profile: "incident:blocking-chain", DurationMin: 30, Intensity: 5, Concurrency: 2, Dispatch: "webhook", Status: "Pass", Message: "Ran blocking-chain on T1 for 30 minutes", WindowStart: iso(day(4, 10, 0)), WindowEnd: iso(day(4, 10, 30)) },
            { RequestId: "s3", RequestedAt: iso(day(2, 16, 0)), TargetKey: "T3", Profile: "incident:log-rate-pressure", DurationMin: 30, Intensity: 5, Concurrency: 2, Dispatch: "webhook", Status: "Pass", Message: "Ran log-rate-pressure on T3 for 30 minutes", WindowStart: iso(day(2, 16, 15)), WindowEnd: iso(day(2, 16, 45)) },
            { RequestId: "s2", RequestedAt: iso(day(1, 15, 0)), TargetKey: "", Profile: "reset", DurationMin: null, Intensity: null, Concurrency: null, Dispatch: "webhook", Status: "Pass", Message: "Reset ContosoCare on T1, T2, and T3", WindowStart: iso(day(1, 15, 0)), WindowEnd: iso(day(1, 15, 2)) },
        ],
        "agent-loop": () => [
            {
                FindingId: "database_agent.T3.session:7f3a9c21:05",
                TargetKey: "T3",
                Status: "Pass",
                Finding: "Database Agent loop: the plan regressed at 14:03 UTC and the response forced the last good plan at 14:26 UTC; T3's CPU fell from 84% to 22%.",
                Evidence: JSON.stringify({
                    sessionId: "7f3a9c21",
                    regressUtc: iso(day(6, 14, 3)) + "Z",
                    respondUtc: iso(day(6, 14, 26)) + "Z",
                    cpuBeforePercent: 84,
                    cpuAfterPercent: 22,
                    before: { startUtc: iso(day(6, 14, 18)) + "Z", endUtc: iso(day(6, 14, 25)) + "Z" },
                    after: { startUtc: iso(day(6, 14, 27)) + "Z", endUtc: iso(day(6, 14, 32)) + "Z" },
                }),
                RequestId: "session:7f3a9c21:05",
                WindowStart: iso(day(6, 14, 0)),
                WindowEnd: iso(day(6, 14, 30)),
                CapturedAt: iso(day(6, 15, 5)),
            },
        ],
        "daily-trend": () => {
            const rand = mulberry32(5);
            const out: Row[] = [];
            for (let d = 29; d >= 0; d--) {
                const at = SAMPLE_LATEST_DAY - d * 86400000;
                const weekday = new Date(at).getUTCDay();
                const busy = weekday === 0 || weekday === 6 ? 0.6 : 1;
                for (const t of ["T1", "T2", "T3"] as const) {
                    const b = BASE[t];
                    const drift = t === "T3" ? 1 + (29 - d) * 0.012 : 1;
                    const incident = SAMPLE_INCIDENTS.some((i) => i.target === t && Math.floor((i.start - SAMPLE_LATEST_DAY) / 86400000) === -d) ? 1 : 0;
                    const cpu = b.cpu * 0.75 * busy * drift * (0.9 + rand() * 0.2);
                    out.push({
                        Date: iso(at),
                        "Target Key": t,
                        CpuAvg: round(cpu),
                        CpuPeak: round(Math.min(99, cpu * 2.1 + incident * 45)),
                        WaitS: round(cpu * 52 * (1 + incident * 0.6)),
                        BufferIoS: round(b.io * 60 * busy),
                        LockWaitS: round(t === "T1" ? 8 + incident * 40 : 2),
                        Batch: Math.round(b.batch * 70 * busy),
                        SessionsPeak: Math.round(b.sessions * 1.6 + incident * 14),
                        Incidents: incident,
                    });
                }
            }
            return out;
        },
        "postgres-findings": () => {
            const at = iso(day(6, 18, 6));
            return [
                {
                    FindingId: "postgresql.T4.capture",
                    TargetKey: "T4",
                    Status: "Pass",
                    StatusSort: 4,
                    Finding: "Azure Monitor metrics of T4 pgflex01-sample (Standard_D2ds_v5) and its read replica pgreplica01-sample (Standard_D2ds_v5) from 17 Nov 17:00 to 18:02 UTC, every 5 minutes.",
                    Evidence: '{"intervalMinutes": 5, "servers": [{"resourceName": "pgflex01-sample", "role": "primary", "sku": "Standard_D2ds_v5", "target": "T4"}, {"resourceName": "pgreplica01-sample", "role": "replica", "sku": "Standard_D2ds_v5", "target": "T4-replica"}]}',
                    CapturedAt: at,
                },
                { FindingId: "postgresql.T4-replica.lag", TargetKey: "T4-replica", Status: "Warning", StatusSort: 3, Finding: "Read replica lag on pgreplica01-sample peaked at 241.4 s at 17:05 UTC (a Warning at 60 s or more).", Evidence: '{"peakSeconds": 241.4}', CapturedAt: at },
                { FindingId: "postgresql.T4.connections_failed", TargetKey: "T4", Status: "Warning", StatusSort: 3, Finding: "Failed connections on T4 (pgflex01-sample): 4 from 17:00 to 17:15 UTC.", Evidence: '{"total": 4}', CapturedAt: at },
            ];
        },
    };
    return rowsById;
}

function estateRows(spec: QuerySpec): Row[] {
    const bins = binsFor(spec);
    const f = filtersOf(spec);
    const findings = staticRows()["findings-latest"]();
    return (["T1", "T2", "T3"] as const)
        .filter((t) => f.targets.includes(t))
        .map((t) => {
            const mine = bins.filter((b) => b.target === t);
            const sum = (k: keyof BinRow) => mine.reduce((a, b) => a + (b[k] as number), 0);
            const max = (k: keyof BinRow) => mine.reduce((a, b) => Math.max(a, b[k] as number), 0);
            const attention = findings.filter((r) => r.TargetKey === t && (r.StatusSort as number) <= 3);
            return {
                "Target Key": t,
                Target: { T1: "T1 · SQL Server on an Azure VM", T2: "T2 · Arc-enabled SQL Server", T3: "T3 · Azure SQL Database" }[t],
                Platform: { T1: "SQL Server 2022 on an Azure VM", T2: "Arc-enabled SQL Server", T3: "Azure SQL Database" }[t],
                CpuAvg: mine.length ? round(sum("cpu") / mine.length) : null,
                CpuPeak: mine.length ? max("cpu") : null,
                BlockedPeak: max("blocked"),
                LockWaitS: round(sum("lockWaitS")),
                BufferIoS: round(sum("bufferIoS")),
                LogRateS: round(sum("logRateS")),
                WaitS: round(sum("waitS")),
                IoMb: round(sum("ioMb")),
                BatchRequests: sum("batch"),
                SessionsPeak: max("sessions"),
                Deadlocks: t === "T1" ? 2 : 0,
                FindingsAttention: attention.length,
                WorstFindingSort: attention.length ? Math.min(...attention.map((r) => r.StatusSort as number)) : 4,
                LagMin: { T1: 4.2, T2: 6.8, T3: 1.1 }[t],
                CoverageTables: { T1: 9, T2: 8, T3: 12 }[t],
                CoverageAgeMin: { T1: 4.2, T2: 6.8, T3: 1.1 }[t],
                Incidents: SAMPLE_INCIDENTS.filter((i) => i.target === t && inWindow(i.start, f)).length,
                Bins: mine.length,
            };
        });
}

function waitRows(spec: QuerySpec): Row[] {
    const bins = binsFor(spec);
    const out: Row[] = [];
    for (const t of ["T1", "T2", "T3"]) {
        const total = bins.filter((b) => b.target === t).reduce((a, b) => a + b.waitS, 0);
        if (total <= 0) continue;
        for (const [metric, share] of WAIT_SPLIT[t]) out.push({ Metric: metric, "Target Key": t, WaitS: round(total * share) });
    }
    return out.sort((a, b) => (b.WaitS as number) - (a.WaitS as number));
}

function incidentFor(target: string): SampleIncident | undefined {
    return SAMPLE_INCIDENTS.find((i) => i.target === target);
}

function rangeOf(spec: QuerySpec, target: string): [number, number] {
    const p = (spec.params ?? {}) as { start?: string; end?: string };
    if (p.start && p.end) return [Date.parse(`${p.start}Z`), Date.parse(`${p.end}Z`)];
    const i = incidentFor(target);
    return i ? [i.start - 90 * MIN, i.end + 90 * MIN] : [0, Number.MAX_SAFE_INTEGER];
}

/** The sample's answer to a catalog query, by its ID and parameters. */
export function sampleRows(spec: QuerySpec): Row[] {
    const replay = /^replay-(T[123])$/.exec(spec.id);
    if (replay) {
        const [from, to] = rangeOf(spec, replay[1]);
        return sampleBins()
            .filter((b) => b.target === replay[1] && b.at >= from && b.at <= to)
            .map((b) => binRow(b, false));
    }
    const spot = /^spotlight-(T[123])$/.exec(spec.id);
    if (spot) {
        const [from, to] = rangeOf(spec, spot[1]);
        const out: Row[] = [];
        for (const b of sampleBins().filter((x) => x.target === spot[1] && x.at >= from && x.at <= to)) {
            for (const [metric, share] of WAIT_SPLIT[spot[1]]) out.push({ "Bucket UTC": iso(b.at), Metric: metric, WaitS: round(b.waitS * share, 2) });
        }
        return out;
    }
    switch (spec.id) {
        case "estate-targets":
            return estateRows(spec);
        case "signals-per-bin":
            return binsFor(spec).map((b) => binRow(b, true));
        case "waits-by-category":
            return waitRows(spec);
        case "daily-trend": {
            const f = filtersOf(spec);
            return staticRows()["daily-trend"]().filter((r) => f.targets.includes(String(r["Target Key"])) && inWindow(Date.parse(`${String(r.Date)}Z`), f));
        }
        case "incident-windows": {
            const f = filtersOf(spec);
            return staticRows()["incident-windows"]().filter((r) => f.targets.includes(String(r.TargetKey)) && inWindow(Date.parse(`${String(r.Start)}Z`), f));
        }
        case "agent-loop": {
            const f = filtersOf(spec);
            return staticRows()["agent-loop"]().filter((r) => f.targets.includes(String(r.TargetKey)) && inWindow(Date.parse(`${String(r.WindowStart)}Z`), f));
        }
        case "scenario-runs": {
            const f = filtersOf(spec);
            return staticRows()["scenario-runs"]().filter((r) => inWindow(Date.parse(`${String(r.RequestedAt)}Z`), f));
        }
        default: {
            const make = staticRows()[spec.id];
            return make ? make() : [];
        }
    }
}
