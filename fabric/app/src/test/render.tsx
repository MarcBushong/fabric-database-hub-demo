// Fixture rows shaped like the connector's real results (after column-name normalization), and a render helper
// that wires the app context and a fake query client. No IDs, URLs, or accounts from a real deployment.

import { render } from "@testing-library/react";
import type { ReactElement } from "react";
import { vi } from "vitest";

import { FluentProvider, webLightTheme } from "@fluentui/react-components";

import { AppContext, MANAGE_READ_ONLY, type AppContextValue, type ManageAccess } from "@/app-context";
import type { CopilotApi } from "@/copilot/contract";
import { CopilotContext } from "@/copilot/use-copilot";
import { setLiveEstateReader } from "@/data/live-estate";
import { toMeta } from "@/data/model";
import type { QuerySpec } from "@/data/queries";
import type { QueryClient, QueryResult, Row } from "@/data/query-client";
import { QueryClientContext } from "@/data/use-query";
import type { AppRuntime } from "@/lib/runtime-config";
import { sqlTargets } from "@/lib/estate";
import { DEFAULT_VIEW, type ViewState } from "@/lib/view-state";
import { sampleLiveReader } from "@/preview/sample-live";

const ZERO = "00000000-0000-0000-0000-000000000000";

export const RUNTIME: AppRuntime = {
    apiUrl: "https://example.invalid/api",
    publishableKey: "pk-test",
    workspaceId: ZERO,
    itemId: ZERO,
    portalUrl: "https://app.fabric.microsoft.com",
    resourceGroup: "rg-dbhub-test",
    links: { report: "https://app.fabric.microsoft.com/groups/x/reports/y" },
};

const bins = (target: "T1" | "T2" | "T3" | null, hours: number, base: number): Row[] =>
    Array.from({ length: hours * 4 }, (_, i) => {
        const at = new Date(Date.UTC(2026, 9, 21, 9) + i * 15 * 60000).toISOString().slice(0, 19);
        const spike = i >= 4 && i < 8 ? 6 : 1;
        return {
            "Bucket UTC": at,
            ...(target ? { "Target Key": target } : {}),
            Cpu: 20 * spike,
            Blocked: 0,
            LockWaitS: 0,
            BufferIoS: base * spike,
            LogRateS: 0,
            WaitS: base * spike * 2,
            IoMb: 100,
            Batch: 1000,
            Sessions: 5,
        };
    });

/** T4's latest PostgreSQL capture (ADR 0025): five-minute points from 17:00 UTC, as the postgres-series query returns them. */
const postgresPoints = (target: "T4" | "T4-replica", metric: string, values: number[]): Row[] =>
    values.map((value, i) => ({
        Bucket: new Date(Date.UTC(2026, 10, 13, 17, i * 5)).toISOString().slice(0, 19),
        TargetKey: target,
        ResourceName: target === "T4" ? "pgflex01-test01" : "pgreplica01-test01",
        Metric: metric,
        Value: value,
        Unit: "",
        WindowStart: "2026-11-13T17:00:00",
        WindowEnd: "2026-11-13T18:02:00",
        CapturedAt: "2026-11-13T18:06:00",
    }));

/** T5's capture: six minutes of an ru-storm wave, throttled at 100 % normalized RU, then back. */
function cosmosPoints(): Row[] {
    const series: Array<[string, string, number[]]> = [
        ["NormalizedRUConsumption", "percent", [10, 60, 100, 100, 30, 12]],
        ["TotalRequests", "requests", [300, 1500, 2400, 2300, 900, 310]],
        ["ThrottledRequests", "requests", [0, 0, 800, 760, 0, 0]],
        ["ServerSideLatencyGateway", "ms", [5, 7, 12, 11, 6, 5]],
    ];
    const rows: Row[] = [];
    const base = { ResourceName: "cosmos01-test01", WindowStart: "2026-11-13T17:00:00", WindowEnd: "2026-11-13T17:06:00", CapturedAt: "2026-11-13T17:10:00" };
    for (const [metric, unit, values] of series) values.forEach((value, i) => rows.push({ ...base, Bucket: `2026-11-13T17:0${i}:00`, Metric: metric, Value: value, Unit: unit }));
    rows.push({ ...base, Bucket: "2026-11-13T17:00:00", Metric: "ProvisionedThroughput", Value: 400, Unit: "RU/s" }, { ...base, Bucket: "2026-11-13T17:00:00", Metric: "ServiceAvailability", Value: 100, Unit: "percent" });
    return rows;
}

export const FIXTURES: Record<string, Row[]> = {    "history-meta": [
        { LatestCapture: "2026-10-21T20:30:00", LatestDay: "2026-10-21T00:00:00", EarliestDay: "2026-10-20T00:00:00", HoursSince: 2, Freshness: "Pass", NotebookRuns: 3, ScenarioRequests: 0, Incidents: 2, HasBins: 1 },
    ],
    "estate-targets": [
        { "Target Key": "T1", Target: "T1 · SQL Server on an Azure VM", Platform: "SQL Server", CpuAvg: 5, CpuPeak: 12, BufferIoS: 1, WaitS: 10, BatchRequests: 50, SessionsPeak: 3, FindingsAttention: 0, WorstFindingSort: null, LagMin: 220.7, CoverageTables: 9, Incidents: 0, Bins: 4 },
        { "Target Key": "T3", Target: "T3 · Azure SQL Database", Platform: "Azure SQL Database", CpuAvg: 40, CpuPeak: 97.5, BufferIoS: 900, WaitS: 4000, BatchRequests: 90000, SessionsPeak: 22, FindingsAttention: 2, WorstFindingSort: 3, LagMin: 0.2, CoverageTables: 12, Incidents: 2, Bins: 96 },
    ],
    headlines: [{ EstateHeadline: "3 of 3 SQL targets sent telemetry in this period; 3 findings need attention", ReadinessHeadline: "12 checks: 0 failed, 2 manual steps, 2 warnings", Freshness: "Pass" }],
    "findings-latest": [
        { FindingId: "f1", AnalysisKey: "storage_io", Status: "Warning", StatusSort: 3, TargetKey: "T3", Analysis: "IO pressure", AnalysisGroup: "IO", Finding: "Buffer IO waits rose sharply", CapturedAt: "2026-10-21T20:30:00" },
        { FindingId: "f2", AnalysisKey: "blocking", Status: "Pass", StatusSort: 4, TargetKey: "T1", Analysis: "Blocking", AnalysisGroup: "Locks and blocking", Finding: "No blocking chains", CapturedAt: "2026-10-21T20:30:00" },
        { FindingId: "sec.T2.audit", AnalysisKey: "security_posture", Status: "Warning", StatusSort: 3, TargetKey: "T2", Analysis: "", AnalysisGroup: "", Finding: "Auditing is off on arcsql01", CapturedAt: "2026-10-21T20:30:00" },
    ],
    "signals-per-bin": [...bins("T3", 3, 10), ...bins("T1", 1, 1)],
    "waits-by-category": [
        { Metric: "CPU", "Target Key": "T3", WaitS: 2500 },
        { Metric: "Buffer IO (PAGEIOLATCH)", "Target Key": "T3", WaitS: 900 },
        { Metric: "Worker Thread", "Target Key": "T3", WaitS: 600 },
        { Metric: "CPU", "Target Key": "T1", WaitS: 10 },
    ],
    "incident-windows": [
        { Key: "detected:T3:io:1", Label: "T3 IO pressure", Source: "Detected signal", TargetKey: "T3", Scenario: "", Family: "io", Start: "2026-10-21T10:00:00", End: "2026-10-21T11:00:00", DurationMin: 60, PeakValue: 60, PeakUnit: "s", Verdict: "Warning" },
        { Key: "detected:T2:io:1", Label: "T2 IO pressure", Source: "Detected signal", TargetKey: "T2", Scenario: "", Family: "io", Start: "2026-10-20T20:00:00", End: "2026-10-20T20:30:00", DurationMin: 30, PeakValue: 5, PeakUnit: "s", Verdict: "" },
    ],
    "replay-T3": bins(null, 3, 10),
    "spotlight-T3": [
        { "Bucket UTC": "2026-10-21T09:30:00", Metric: "CPU", WaitS: 10 },
        { "Bucket UTC": "2026-10-21T10:15:00", Metric: "CPU", WaitS: 40 },
        { "Bucket UTC": "2026-10-21T10:15:00", Metric: "Buffer IO (PAGEIOLATCH)", WaitS: 60 },
    ],
    "readiness-checks": [
        { RunId: "20261021T172517Z-a", CheckId: "fabric-hub-setting", Area: "Fabric", TargetKey: "fabric", Status: "Manual action required", StatusSort: 2, Message: "Turn on the tenant setting.", Remediation: "Ask a Fabric admin.", DocUrl: "https://learn.microsoft.com/fabric/", CheckedAt: "2026-10-21T17:25:17", EvaluationOnly: false },
        { RunId: "20261021T172517Z-a", CheckId: "t3-telemetry", Area: "Telemetry", TargetKey: "T3", Status: "Pass", StatusSort: 4, Message: "Fresh.", Remediation: "", DocUrl: "", CheckedAt: "2026-10-21T17:25:17", EvaluationOnly: false },
        { RunId: "20261021T172517Z-a", CheckId: "t1-telemetry", Area: "Telemetry", TargetKey: "T1", Status: "Warning", StatusSort: 3, Message: "Stale.", Remediation: "Start the VM.", DocUrl: "", CheckedAt: "2026-10-21T17:25:17", EvaluationOnly: false },
    ],
    "readiness-summary": [{ Checks: 3, Failed: 0, Manual: 1, Warnings: 1, Passed: 1, NotSupported: 0, NotSelected: 0, Readiness: 0.333, RunLabel: "Run 20261021T172517Z" }],
    "telemetry-coverage": [
        { "Target Key": "T1", Tables: 9, AgeMin: 220.7, Attention: "▲ stale" },
        { "Target Key": "T3", Tables: 12, AgeMin: 0.2, Attention: "✓ fresh" },
    ],
    "connector-check": [{ ValidationRows: 12, SnapshotRows: 2293, Incidents: 4 }],
    "target-names": [
        { TargetKey: "T1", ResourceType: null, ResourceName: "sqlvm01", InstanceName: "MSSQLSERVER", DatabaseName: "ContosoCare" },
        { TargetKey: "T1", ResourceType: "virtualMachines", ResourceName: "sqlvm01", InstanceName: null, DatabaseName: null },
        { TargetKey: "T2", ResourceType: null, ResourceName: null, InstanceName: null, DatabaseName: null },
        { TargetKey: "T2", ResourceType: "machines", ResourceName: "arcsql01", InstanceName: null, DatabaseName: null },
        { TargetKey: "T2", ResourceType: null, ResourceName: "arcsql01", InstanceName: "MSSQLSERVER", DatabaseName: "ContosoCare" },
        { TargetKey: "T3", ResourceType: null, ResourceName: null, InstanceName: "azuresql01-test01", DatabaseName: null },
        { TargetKey: "T3", ResourceType: "servers/databases", ResourceName: "azuresql01-test01/ContosoCare", InstanceName: null, DatabaseName: null },
        { TargetKey: "T3", ResourceType: null, ResourceName: "azuresql01-test01/ContosoCare", InstanceName: "azuresql01-test01", DatabaseName: "ContosoCare" },
    ],
    "postgres-series": [
        ...postgresPoints("T4-replica", "physical_replication_delay_in_seconds", [6, 241.4, 2]),
        ...postgresPoints("T4", "cpu_percent", [43.3, 91.3, 50]),
        ...postgresPoints("T4-replica", "cpu_percent", [10.3]),
        ...postgresPoints("T4", "memory_percent", [30.2]),
        ...postgresPoints("T4", "active_connections", [12, 34]),
        ...postgresPoints("T4-replica", "active_connections", [1]),
        ...postgresPoints("T4", "connections_failed", [0, 3, 1]),
        ...postgresPoints("T4", "physical_replication_delay_in_bytes", [184]),
    ],
    "scenario-runs": [
        { RequestId: "session:abcd1234:05", RequestedAt: "2026-10-21T09:00:01", TargetKey: "T3", Profile: "incident:plan-regression", DurationMin: 30, Intensity: 5, Concurrency: 2, Dispatch: "webhook", Status: "Pass", Message: "Session abcd1234's Database Agent beat: the plan regresses at 10:03 UTC; the run's response forces the last good plan at 10:26 UTC.", WindowStart: "2026-10-21T10:00:00", WindowEnd: "2026-10-21T10:30:00" },
        { RequestId: "r1", RequestedAt: "2026-10-21T09:00:00", TargetKey: "", Profile: "showcase", DurationMin: 90, Intensity: null, Concurrency: null, Dispatch: "webhook", Status: "Pass", Message: "Session started on T1, T2, T3, and T4", WindowStart: "2026-10-21T09:00:00", WindowEnd: "2026-10-21T10:30:00" },
    ],
    "agent-loop": [
        {
            FindingId: "database_agent.T3.session:abcd1234:05",
            TargetKey: "T3",
            Status: "Pass",
            Finding: "Database Agent loop: the plan regressed at 10:03 UTC and the response forced the last good plan at 10:26 UTC; T3's CPU fell from 84% to 22%.",
            Evidence: '{"sessionId": "abcd1234", "regressUtc": "2026-10-21T10:03:00Z", "respondUtc": "2026-10-21T10:26:00Z", "cpuBeforePercent": 84, "cpuAfterPercent": 22}',
            RequestId: "session:abcd1234:05",
            WindowStart: "2026-10-21T10:00:00",
            WindowEnd: "2026-10-21T10:30:00",
            CapturedAt: "2026-10-21T11:05:00",
        },
    ],
    "daily-trend": [
        { Date: "2026-10-20T00:00:00", "Target Key": "T1", CpuAvg: 10, CpuPeak: 20, WaitS: 100, BufferIoS: 5, LockWaitS: 1, Batch: 1000, SessionsPeak: 5, Incidents: 0 },
        { Date: "2026-10-21T00:00:00", "Target Key": "T1", CpuAvg: 12, CpuPeak: 30, WaitS: 120, BufferIoS: 6, LockWaitS: 2, Batch: 1100, SessionsPeak: 6, Incidents: 1 },
        { Date: "2026-10-21T00:00:00", "Target Key": "T3", CpuAvg: 40, CpuPeak: 97.5, WaitS: 4000, BufferIoS: 900, LockWaitS: 3, Batch: 90000, SessionsPeak: 22, Incidents: 2 },
    ],
    "cosmos-series": cosmosPoints(),
    "cosmos-findings": [
        { FindingId: "cosmosdb.T5.throttling", TargetKey: "T5", Status: "Warning", StatusSort: 3, Finding: "T5 throttled 1,560 of 7,710 requests (20.2 %).", Evidence: "{}", WindowStart: "2026-11-13T17:00:00", WindowEnd: "2026-11-13T17:06:00", CapturedAt: "2026-11-13T17:10:00" },
        { FindingId: "cosmosdb.T5.throttle.20261113T1702", TargetKey: "T5", Status: "Warning", StatusSort: 3, Finding: "Throttling episode from 17:02 to 17:04 UTC.", Evidence: "{}", WindowStart: "2026-11-13T17:02:00", WindowEnd: "2026-11-13T17:04:00", CapturedAt: "2026-11-13T17:10:00" },
        { FindingId: "cosmosdb.T5.recovery", TargetKey: "T5", Status: "Pass", StatusSort: 4, Finding: "T5 recovered: normalized RU was back at baseline by 17:05 UTC.", Evidence: "{}", WindowStart: "2026-11-13T17:04:00", WindowEnd: "2026-11-13T17:06:00", CapturedAt: "2026-11-13T17:10:00" },
        { FindingId: "cosmosdb.T5.capture", TargetKey: "T5", Status: "Pass", StatusSort: 4, Finding: "Azure Monitor metrics of T5 cosmos01-test01.", Evidence: "{}", WindowStart: "2026-11-13T17:00:00", WindowEnd: "2026-11-13T17:06:00", CapturedAt: "2026-11-13T17:10:00" },
    ],    "postgres-findings": [
        {
            FindingId: "postgresql.T4.capture",
            TargetKey: "T4",
            Status: "Pass",
            StatusSort: 4,
            Finding: "Azure Monitor metrics of T4 pgflex01-test01 (Standard_D4ds_v5) and its read replica pgreplica01-test01 (Standard_D4ds_v5) from 2026-11-13 17:00 to 2026-11-13 18:02 UTC, every 5 minutes: 8 series, 15 points.",
            Evidence: '{"intervalMinutes": 5, "servers": [{"resourceName": "pgflex01-test01", "role": "primary", "sku": "Standard_D4ds_v5", "target": "T4"}, {"resourceName": "pgreplica01-test01", "role": "replica", "sku": "Standard_D4ds_v5", "target": "T4-replica"}]}',
            CapturedAt: "2026-11-13T18:06:00",
        },
        {
            FindingId: "postgresql.T4-replica.lag",
            TargetKey: "T4-replica",
            Status: "Warning",
            StatusSort: 3,
            Finding: "Read replica lag on pgreplica01-test01 peaked at 241.4 s at 2026-11-13 17:05 UTC (a Warning at 60 s or more).",
            Evidence: '{"peakSeconds": 241.4, "thresholdSeconds": 60}',
            CapturedAt: "2026-11-13T18:06:00",
        },
        {
            FindingId: "postgresql.T4.connections_failed",
            TargetKey: "T4",
            Status: "Warning",
            StatusSort: 3,
            Finding: "Failed connections on T4 (pgflex01-test01): 4 from 2026-11-13 17:00 to 2026-11-13 17:15 UTC, at most 3 in one 5-minute interval (at 2026-11-13 17:05 UTC).",
            Evidence: '{"total": 4}',
            CapturedAt: "2026-11-13T18:06:00",
        },
    ],
};

export type FakeQueryClient = QueryClient & { ran: string[] };

/** A query client that answers from FIXTURES by query ID, and records what ran. */
export function fakeQueryClient(overrides: Record<string, Row[] | Error> = {}): FakeQueryClient {
    const ran: string[] = [];
    return {
        ran,
        peek: () => undefined,
        clear: () => undefined,
        run: vi.fn(async (spec: QuerySpec): Promise<QueryResult> => {
            ran.push(spec.id);
            const value = overrides[spec.id] ?? FIXTURES[spec.id] ?? [];
            if (value instanceof Error) throw value;
            return { spec, columns: spec.columns, rows: value, requestId: "test", fetchedAt: new Date(Date.UTC(2026, 9, 21, 21)), provenance: "history" };
        }),
    };
}

export interface RenderOptions {
    view?: Partial<ViewState>;
    client?: FakeQueryClient;
    embedded?: boolean;
    manage?: ManageAccess;
    /** No history yet: the first run. */
    metaEmpty?: boolean;
    /** Database Hub's live answers: the sample's, or none (the app's function isn't deployed), the default. */
    live?: "sample" | "off";
}

export function renderWithApp(ui: ReactElement, options: RenderOptions = {}) {
    setLiveEstateReader(sampleLiveReader({ at: "2026-10-21T21:00:00.000Z", off: options.live === "sample" ? undefined : "the live estate function isn't deployed in this app" }));
    const setView = vi.fn();
    const navigate = vi.fn();
    const notify = vi.fn();
    const view: ViewState = { ...DEFAULT_VIEW, ...options.view };
    const context: AppContextValue = {
        runtime: RUNTIME,
        embedded: options.embedded ?? true,
        view,
        setView,
        navigate,
        filters: { targets: sqlTargets(view.targets), window: null },
        meta: options.metaEmpty ? null : toMeta(FIXTURES["history-meta"]),
        metaLoading: false,
        metaError: null,
        provenance: "history",
        reducedMotion: true,
        notify,
        manage: options.manage ?? MANAGE_READ_ONLY,
    };
    const copilot: CopilotApi = { open: vi.fn(), ask: vi.fn() };
    const client = options.client ?? fakeQueryClient();
    const result = render(
        <FluentProvider theme={webLightTheme}>
            <QueryClientContext.Provider value={client}>
                <CopilotContext.Provider
                    value={{ api: copilot, dock: { isOpen: false, setOpen: vi.fn() }, account: { status: "unavailable", signIn: vi.fn(), signOut: vi.fn() }, attached: null }}
                >
                    <AppContext.Provider value={context}>{ui}</AppContext.Provider>
                </CopilotContext.Provider>
            </QueryClientContext.Provider>
        </FluentProvider>,
    );
    return { ...result, setView, navigate, notify, client, copilot };
}