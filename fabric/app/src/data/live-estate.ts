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
 * The answer's data, or null when there's none: the function answers with empty data when it read nothing (Database
 * Hub refused the app or didn't answer, or the deploy wrote no scope), with one plain sentence in unavailable.
 */
export function liveDataOf<V extends EstateView>(answer: EstateAnswer<V> | null | undefined): EstateDataByView[V] | null {
    const data = answer?.data;
    return data && typeof data === "object" && Object.keys(data).length > 0 ? (data as EstateDataByView[V]) : null;
}

const ROUTE = /^(GET|POST) \/[\w/.-]+(?=:)/;

/** What a page says when Database Hub didn't answer the app for a reason a later read may not meet (an outage, a timeout). */
export const LIVE_NO_ANSWER = "Database Hub's live view didn't answer the app just now";

/**
 * The Database Hub routes behind one or more answers, and the ones that didn't answer, by route only: each failure's
 * detail (its HTTP status and Database Hub's message) stays in the function's log, never on a page (R924).
 */
export function liveRoutes(source: readonly string[], errors: readonly string[]): { called: string[]; failed: string[] } {
    const called = new Set(source);
    const failed = new Set<string>();
    for (const e of errors) {
        const route = ROUTE.exec(e)?.[0];
        if (!route) continue;
        failed.add(route);
        called.add(route);
    }
    return { called: [...called], failed: [...failed] };
}

/** The routes as the "Database Hub API" panel lists them: each one, and "didn't answer" after a failed one. */
export function liveRouteLines(source: readonly string[], errors: readonly string[]): string {
    const { called, failed } = liveRoutes(source, errors);
    return called.map((route) => (failed.includes(route) ? `${route}  (didn't answer)` : route)).join("\n");
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
    /** Why there's no live answer, in one plain sentence: Database Hub refused the app or didn't answer, or the app's function isn't deployed. */
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
                // No data at all: the page says why in the function's one plain sentence, or that Database Hub didn't
                // answer just now, never a route's error (R924).
                if (liveDataOf(answer) === null) setSettled({ view, n: nonce, answer: null, unavailable: answer.unavailable ?? LIVE_NO_ANSWER });
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