// Fixture rows shaped like the connector's real results (after column-name normalization), and a render helper
// that wires the app context and a fake query client. No IDs, URLs, or accounts from a real deployment.

import { render } from "@testing-library/react";
import type { ReactElement } from "react";
import { vi } from "vitest";

import { AppContext, type AppContextValue } from "@/app-context";
import { toMeta } from "@/data/model";
import type { QuerySpec } from "@/data/queries";
import type { QueryClient, QueryResult, Row } from "@/data/query-client";
import { QueryClientContext } from "@/data/use-query";
import type { AppRuntime } from "@/lib/runtime-config";
import { DEFAULT_VIEW, type ViewState } from "@/lib/view-state";

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

export const FIXTURES: Record<string, Row[]> = {
    "history-meta": [
        { LatestCapture: "2026-10-21T20:30:00", LatestDay: "2026-10-21T00:00:00", EarliestDay: "2026-10-20T00:00:00", HoursSince: 2, Freshness: "Pass", NotebookRuns: 3, ScenarioRequests: 0, Incidents: 2, HasBins: 1 },
    ],
    "estate-targets": [
        { "Target Key": "T1", Target: "T1 · SQL Server on an Azure VM", Platform: "SQL Server", CpuAvg: 5, CpuPeak: 12, BufferIoS: 1, WaitS: 10, BatchRequests: 50, SessionsPeak: 3, FindingsAttention: 0, WorstFindingSort: null, LagMin: 220.7, CoverageTables: 9, Incidents: 0, Bins: 4 },
        { "Target Key": "T3", Target: "T3 · Azure SQL Database", Platform: "Azure SQL Database", CpuAvg: 40, CpuPeak: 97.5, BufferIoS: 900, WaitS: 4000, BatchRequests: 90000, SessionsPeak: 22, FindingsAttention: 2, WorstFindingSort: 3, LagMin: 0.2, CoverageTables: 12, Incidents: 2, Bins: 96 },
    ],
    headlines: [{ EstateHeadline: "3 of 3 SQL targets sent telemetry in this period; 3 findings need attention", ReadinessHeadline: "12 checks: 0 failed, 2 manual steps, 2 warnings", Freshness: "Pass" }],
    "findings-latest": [
        { FindingId: "f1", Status: "Warning", StatusSort: 3, TargetKey: "T3", Analysis: "IO pressure", Finding: "Buffer IO waits rose sharply", CapturedAt: "2026-10-21T20:30:00" },
        { FindingId: "f2", Status: "Pass", StatusSort: 4, TargetKey: "T1", Analysis: "Blocking", Finding: "No blocking chains", CapturedAt: "2026-10-21T20:30:00" },
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
            return { spec, columns: spec.columns, rows: value, requestId: "test", fetchedAt: new Date(Date.UTC(2026, 9, 21, 21)) };
        }),
    };
}

export function renderWithApp(ui: ReactElement, options: { view?: Partial<ViewState>; client?: FakeQueryClient; embedded?: boolean } = {}) {
    const setView = vi.fn();
    const notify = vi.fn();
    const view: ViewState = { ...DEFAULT_VIEW, ...options.view };
    const context: AppContextValue = {
        runtime: RUNTIME,
        embedded: options.embedded ?? true,
        view,
        setView,
        filters: { targets: view.targets, window: null },
        meta: toMeta(FIXTURES["history-meta"]),
        theme: "aurora",
        setTheme: vi.fn(),
        motion: "reduced",
        setMotion: vi.fn(),
        reducedMotion: true,
        notify,
    };
    const client = options.client ?? fakeQueryClient();
    const result = render(
        <QueryClientContext.Provider value={client}>
            <AppContext.Provider value={context}>{ui}</AppContext.Provider>
        </QueryClientContext.Provider>,
    );
    return { ...result, setView, notify, client };
}
