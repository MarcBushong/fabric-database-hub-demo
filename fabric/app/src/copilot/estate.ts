// The live estate: Database Hub's current view of the demo's own resources, read by the app's estate function
// (rayfin/functions, as the app item's owner, scoped to the demo's resource group). The dock's estate_overview
// tool and any page use the same source through this module: readEstate(view) or useLiveEstate(view).

import { useCallback, useEffect, useState } from "react";

import { getRayfinClient } from "@/lib/rayfin-client";
import type { EstateAnswer, EstateView } from "../../rayfin/functions/src/estate-core";

// The answer's shapes, one per view, for pages: inventory (resources by engine and their findings), health (SQL and
// PostgreSQL high-usage counts and named databases, Cosmos DB availability and normalized RU, last 24 hours), and
// security (Entra authentication, auditing, and customer-managed key findings).
export type {
    EstateAnswer,
    EstateDataByView,
    EstateView,
    HealthData,
    InventoryData,
    InventoryResource,
    SecurityArea,
    SecurityData,
    SecurityFinding,
    UsageSummary,
} from "../../rayfin/functions/src/estate-core";
type Invoke = (input: unknown, options?: { timeoutMs?: number }) => Promise<unknown>;

function estateFunction(): Invoke | null {
    try {
        const client = getRayfinClient() as unknown as { functions?: Record<string, { invoke?: Invoke } | undefined> };
        const fn = client.functions?.estateOverview;
        return fn && typeof fn.invoke === "function" ? fn.invoke.bind(fn) : null;
    } catch {
        return null;
    }
}

const cache = new Map<EstateView, { at: number; value: Promise<EstateAnswer> }>();
const TTL_MS = 60_000;

/**
 * Reads one view of the live estate, cached for a minute so the dock and the pages share one call. Resolves to the
 * function's answer: `errors` lists any route that failed (a partial answer keeps what it read), and `source` the
 * Database Hub routes that answered. Rejects only when the function isn't deployed or can't be reached.
 */
export function readEstate<V extends EstateView>(view: V, options: { force?: boolean } = {}): Promise<EstateAnswer<V>> {
    const hit = cache.get(view);
    if (hit && !options.force && Date.now() - hit.at < TTL_MS) return hit.value as Promise<EstateAnswer<V>>;
    const invoke = estateFunction();
    if (!invoke) return Promise.reject(new Error("The live estate function isn't deployed in this app."));
    const value = invoke({ view }, { timeoutMs: 120_000 }).then((raw) => {
        const answer = (typeof raw === "string" ? JSON.parse(raw) : raw) as EstateAnswer<V>;
        if (!answer || typeof answer !== "object" || !Array.isArray(answer.source)) throw new Error("The estate function returned an unexpected answer.");
        return answer;
    });
    cache.set(view, { at: Date.now(), value });
    value.catch(() => cache.delete(view));
    return value;
}

export interface LiveEstateState<V extends EstateView = EstateView> {
    data: EstateAnswer<V> | undefined;
    error: Error | undefined;
    loading: boolean;
    refetch: () => void;
}

/** The live estate for a page: the same source and cache as the dock's estate_overview tool. */
export function useLiveEstate<V extends EstateView>(view: V, enabled = true): LiveEstateState<V> {
    const [n, setN] = useState(0);
    const key = `${view}:${n}`;
    const [settled, setSettled] = useState<{ key: string; data?: EstateAnswer<V>; error?: Error } | null>(null);
    useEffect(() => {
        if (!enabled) return;
        let cancelled = false;
        readEstate(view, { force: n > 0 }).then(
            (data) => !cancelled && setSettled({ key: `${view}:${n}`, data }),
            (error: unknown) => !cancelled && setSettled({ key: `${view}:${n}`, error: error instanceof Error ? error : new Error(String(error)) }),
        );
        return () => {
            cancelled = true;
        };
    }, [view, enabled, n]);
    const refetch = useCallback(() => setN((v) => v + 1), []);
    const current = settled?.key === key ? settled : null;
    // While a refresh runs, keep showing what the page already had.
    return { data: current?.data ?? settled?.data, error: current?.error, loading: enabled && !current, refetch };
}