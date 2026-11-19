// Live estate data from Database Hub, read by the app's function through the GA databasehub-cli skill's read-only
// routes, scoped to the demo's own resource groups. The chat session's module (src/copilot/estate.ts) owns the call:
// one per view, cached for 60 seconds and shared with the Copilot dock. Until that module is in the build, or when the
// app's function isn't deployed, pages say so and fall back to the history.

import { useCallback, useEffect, useState } from "react";

export type EstateView = "inventory" | "health" | "security";

export type FlagCategory = "security" | "performance" | "optimization";
/** A true flag needs attention ("hasCmkIssue": true). */
export type FlagGroups = Partial<Record<FlagCategory, Record<string, boolean>>>;

export interface LiveResource {
    databaseType: string;
    name: string;
    resourceGroup?: string;
    location?: string;
    sku?: string;
    status?: string;
    /** Database Hub's issues: what needs attention. */
    issues?: FlagGroups;
    /** Database Hub's enhancements: what it recommends. */
    enhancements?: FlagGroups;
    /** A SQL Server instance's migration assessment (SQL Server enabled by Azure Arc), when Database Hub's row carries one. */
    migrationAssessment?: MigrationAssessment;
}

/**
 * Database Hub's migration assessment of a SQL Server instance: its inventory row's properties.migrationAssessment, as
 * the app's function passes it (the chat session's estate types). Database Hub doesn't raise a ready assessment as an
 * issue, so this is where "which servers can move to Azure, and to what" comes from.
 */
export interface MigrationAssessment {
    enabled: boolean;
    /** When the instance last uploaded its assessment, or null. */
    uploadedAt: string | null;
    /** "Available" with results, "Stale", or "Unavailable". */
    dataStatus: string;
    /** Readiness per Azure SQL target, with Database Hub's names and values, for example azureSqlManagedInstance: "Ready". */
    targets: Record<string, string>;
    readyTargets?: string[];
    /** Database Hub's own flag (issues.optimization.hasMigrationAssessmentIssue), when the row has it. */
    hasIssue?: boolean;
}

export interface InventoryData {
    totalCount: number;
    countByType: Record<string, number>;
    resources: LiveResource[];
    complete: boolean;
}

export interface UsageCounts {
    cpu: number;
    storage: number;
    memory: number;
}

export interface EngineHealth {
    totalDatabases: number;
    highUsage: UsageCounts | null;
}

export interface CosmosHealth {
    totalAccounts: number;
    minimumServiceAvailability: number | null;
    maximumNormalizedRu: number | null;
    note?: string;
}

export interface HealthData {
    window: { startTime: string; endTime: string; granularity?: string; aggregation?: string };
    microsoftSql: EngineHealth | null;
    postgreSql: EngineHealth | null;
    cosmosDb: CosmosHealth | null;
}

export interface SecurityWarning {
    name: string;
    type: string;
    serverName?: string;
    reason?: string;
}

export interface SecurityArea {
    scope: string;
    warnings: SecurityWarning[];
    warningCount: number;
    complete: boolean;
}

export interface SecurityData {
    authentication?: SecurityArea;
    auditing?: SecurityArea;
    customerManagedKeys?: SecurityArea;
}

export interface EstateDataByView {
    inventory: InventoryData;
    health: HealthData;
    security: SecurityData;
}

export interface EstateAnswer<V extends EstateView = EstateView> {
    view: V;
    /** The Database Hub API calls that answered, "<METHOD> /<route>" relative to the API: what the visual shows instead of DAX. */
    source: string[];
    scope: { subscriptionId: string; resourceGroups: string[] };
    data: EstateDataByView[V];
    /** The API calls that failed; a partial answer keeps what it read. */
    errors: string[];
    /** When the answer was read (ISO 8601). */
    at: string;
}

export type EstateReader = <V extends EstateView>(view: V, options?: { force?: boolean }) => Promise<EstateAnswer<V>>;

interface EstateModule {
    readEstate?: EstateReader;
}

const modules = import.meta.glob<EstateModule>("../copilot/estate.ts");
let override: EstateReader | null = null;

/** The local preview and the tests answer with their own reader; null goes back to the app's function. */
export function setLiveEstateReader(reader: EstateReader | null): void {
    override = reader;
}

/** The live answer for one view; it rejects when the app has no live source (the function isn't deployed). */
export async function readLiveEstate<V extends EstateView>(view: V, options?: { force?: boolean }): Promise<EstateAnswer<V>> {
    if (override) return override(view, options);
    const load = Object.values(modules)[0];
    const module = load ? await load() : null;
    if (!module?.readEstate) throw new Error("This build of the app has no live estate source.");
    return module.readEstate(view, options);
}

export interface LiveState<V extends EstateView> {
    answer: EstateAnswer<V> | null;
    loading: boolean;
    /** Why there's no live answer: the app's function isn't deployed, or this build has none. */
    unavailable: string | null;
    refresh: () => void;
}

/** One view of the live estate for a page: a cold read takes 5 to 12 seconds, then it's cached for 60. */
export function useLiveEstate<V extends EstateView>(view: V, enabled = true): LiveState<V> {
    const [nonce, setNonce] = useState(0);
    const [settled, setSettled] = useState<{ view: V; n: number; answer: EstateAnswer<V> | null; unavailable: string | null } | null>(null);
    useEffect(() => {
        if (!enabled) return;
        let alive = true;
        readLiveEstate(view, nonce > 0 ? { force: true } : undefined).then(
            (answer) => {
                if (alive) setSettled({ view, n: nonce, answer, unavailable: null });
            },
            (error: unknown) => {
                if (alive) setSettled({ view, n: nonce, answer: null, unavailable: error instanceof Error ? error.message : String(error) });
            },
        );
        return () => {
            alive = false;
        };
    }, [view, enabled, nonce]);
    const refresh = useCallback(() => setNonce((n) => n + 1), []);
    if (!enabled) return { answer: null, loading: false, unavailable: null, refresh };
    // While a refresh runs, the page keeps showing the answer it had.
    const current = settled && settled.view === view ? settled : null;
    const done = current !== null && current.n === nonce;
    return { answer: current?.answer ?? null, loading: !done, unavailable: done ? current.unavailable : null, refresh };
}