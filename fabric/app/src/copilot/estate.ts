// The live estate: Database Hub's current view of the demo's own resources, read by the app's estate function
// (rayfin/functions, as the app item's owner, scoped to the demo's resource group). The dock's estate_overview
// tool and any page use the same source through this module.

import { useCallback, useEffect, useState } from "react";

import { getRayfinClient } from "@/lib/rayfin-client";

export type EstateView = "inventory" | "health" | "security";

export interface EstateAnswer {
    view: EstateView;
    /** The Database Hub routes that answered, for the "source" view. */
    source: string[];
    /** The scope the function applied: the demo's subscription and resource group. */
    scope?: { resourceGroup?: string };
    data: unknown;
    /** Per-route errors: a partial answer still returns what it could read. */
    errors?: string[];
    at?: string;
}

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

/** Reads one view of the live estate, cached for a minute so the dock and the pages share one call. */
export function readEstate(view: EstateView, options: { force?: boolean } = {}): Promise<EstateAnswer> {
    const hit = cache.get(view);
    if (hit && !options.force && Date.now() - hit.at < TTL_MS) return hit.value;
    const invoke = estateFunction();
    if (!invoke) return Promise.reject(new Error("The live estate function isn't deployed in this app."));
    const value = invoke({ view }, { timeoutMs: 120_000 }).then((raw) => {
        const answer = (typeof raw === "string" ? JSON.parse(raw) : raw) as EstateAnswer;
        if (!answer || typeof answer !== "object" || !Array.isArray(answer.source)) throw new Error("The estate function returned an unexpected answer.");
        return answer;
    });
    cache.set(view, { at: Date.now(), value });
    value.catch(() => cache.delete(view));
    return value;
}

export interface LiveEstateState {
    data: EstateAnswer | undefined;
    error: Error | undefined;
    loading: boolean;
    refetch: () => void;
}

/** The live estate for a page: the same source and cache as the dock's estate_overview tool. */
export function useLiveEstate(view: EstateView, enabled = true): LiveEstateState {
    const [n, setN] = useState(0);
    const key = `${view}:${n}`;
    const [settled, setSettled] = useState<{ key: string; data?: EstateAnswer; error?: Error } | null>(null);
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
