// Live estate data from Database Hub, read by the app's estate function (rayfin/functions, estateOverview) through the
// GA databasehub-cli skill's read-only routes, scoped to the demo's own resource groups. The chat session's module
// (src/copilot/estate.ts) owns the call: one per view, cached for 60 seconds and shared with the Copilot dock. The
// shapes are that function's own (estate-core.ts), so a change there fails this app's typecheck instead of a page. When
// the function isn't deployed, or can't be reached, pages say so and fall back to the history.

import { useCallback, useEffect, useState } from "react";

import type { EstateAnswer, EstateDataByView, EstateView, InventoryResource } from "@/copilot/estate";

export type {
    EstateAnswer,
    EstateDataByView,
    EstateView,
    HealthData,
    InventoryData,
    InventoryResource,
    MigrationAssessment,
    SecurityArea,
    SecurityData,
    SecurityFinding,
    UsageSummary,
} from "@/copilot/estate";

/** One inventory row, as the estate function passes it. */
export type LiveResource = InventoryResource;
export type FlagCategory = "security" | "performance" | "optimization";
/** Database Hub's flags by area; a true flag needs attention ("hasCmkIssue": true). */
export type FlagGroups = NonNullable<InventoryResource["issues"]>;

/**
 * The answer's data, or null when there's none: the function answers with empty data when it has no scope (the
 * deploy didn't write one), with the reason in errors.
 */
export function liveDataOf<V extends EstateView>(answer: EstateAnswer<V> | null | undefined): EstateDataByView[V] | null {
    const data = answer?.data;
    return data && typeof data === "object" && Object.keys(data).length > 0 ? (data as EstateDataByView[V]) : null;
}

export type EstateReader = <V extends EstateView>(view: V, options?: { force?: boolean }) => Promise<EstateAnswer<V>>;

let override: EstateReader | null = null;

/** The local preview and the tests answer with their own reader; null goes back to the app's function. */
export function setLiveEstateReader(reader: EstateReader | null): void {
    override = reader;
}

/** The live answer for one view; it rejects when the app has no live source (the function isn't deployed). */
export async function readLiveEstate<V extends EstateView>(view: V, options?: { force?: boolean }): Promise<EstateAnswer<V>> {
    if (override) return override(view, options);
    const { readEstate } = await import("@/copilot/estate");
    return readEstate(view, options);
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
                if (!alive) return;
                // No data at all (the function has no scope): the page says why, as when the function isn't deployed.
                if (liveDataOf(answer) === null) setSettled({ view, n: nonce, answer: null, unavailable: answer.errors[0] ?? "Database Hub returned no data for this view." });
                else setSettled({ view, n: nonce, answer, unavailable: null });
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