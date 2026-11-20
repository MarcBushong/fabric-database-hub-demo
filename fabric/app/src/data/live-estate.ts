// Live estate data from Database Hub, read by the app's estate function (rayfin/functions, estateOverview) through the
// GA databasehub-cli skill's read-only routes, scoped to the demo's own resource groups. The chat session's module
// (src/copilot/estate.ts) owns the call: one per view, cached for 60 seconds and shared with the Copilot dock. The
// shapes are that function's own (estate-core.ts), so a change there fails this app's typecheck instead of a page. When
// the function isn't deployed, or can't be reached, pages say so and fall back to the history; while Database Hub
// refuses the app (R924), they hide their live parts, and Live views says why.

import { useCallback, useEffect, useState } from "react";

import type { EstateAnswer, EstateDataByView, EstateView, InventoryResource } from "@/copilot/estate";
import { sentence } from "@/lib/format";
import { LIVE_REFUSED } from "../../rayfin/functions/src/estate-core";

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

/** The routes of a view's answer that came back without data, and why each didn't answer (counted, never shown). */
export interface MissedAnswer {
    source: string[];
    errors: string[];
}

export interface LiveState<V extends EstateView> {
    /** The view's answer, when it has data. */
    answer: EstateAnswer<V> | null;
    loading: boolean;
    /** Why there's no live answer, in one plain sentence: Database Hub refused the app or didn't answer, or the app's function isn't deployed. */
    unavailable: string | null;
    /**
     * When the view's answer came back without data (R924): its routes, so a page that combines views counts them among
     * the calls that didn't answer, never as a view with nothing to report. Null while reading, with data, or without an answer.
     */
    missed: MissedAnswer | null;
    /**
     * The function's own sentence while this view's live data isn't available to the app (Database Hub refuses the app's
     * sign-in, or the function has no scope; R924), else null. Remembered in this browser, so that while the read runs a
     * page already knows. A page hides its live parts only when every view says so (liveOffOf).
     */
    off: string | null;
    refresh: () => void;
}

const LIVE_VIEWS = ["inventory", "health", "security"] as const;

// Each view's last "unavailable" sentence in this browser (R924), so that while Database Hub refuses the app, a page
// doesn't show its live parts reading and then drop them. A read with data forgets its view's.
const LIVE_OFF_KEY = "dbhub-insights.live-off.v1";

function rememberedLiveOff(): Partial<Record<EstateView, string>> {
    try {
        const saved: unknown = JSON.parse(window.localStorage.getItem(LIVE_OFF_KEY) ?? "{}");
        const out: Partial<Record<EstateView, string>> = {};
        for (const view of LIVE_VIEWS) {
            const reason = saved && typeof saved === "object" ? (saved as Record<string, unknown>)[view] : undefined;
            if (typeof reason === "string" && reason) out[view] = reason.slice(0, 300);
        }
        return out;
    } catch {
        // Storage can be unavailable in a locked-down frame: the page then waits for the read.
        return {};
    }
}

function rememberLiveOff(view: EstateView, reason: string | null): void {
    try {
        const saved = rememberedLiveOff();
        if (reason) saved[view] = reason;
        else delete saved[view];
        if (Object.keys(saved).length > 0) window.localStorage.setItem(LIVE_OFF_KEY, JSON.stringify(saved));
        else window.localStorage.removeItem(LIVE_OFF_KEY);
    } catch {
        // Storage can be unavailable in a locked-down frame.
    }
}

/**
 * Database Hub refuses the app as a whole (R924): every view's live data isn't available to it, by this read or the
 * last one in this browser. The function's sentence, or null; a view that doesn't answer alone gets the partial treatment.
 */
export function liveOffOf(states: ReadonlyArray<Pick<LiveState<EstateView>, "off">>): string | null {
    return states.length > 0 && states.every((s) => s.off) ? states[0].off : null;
}

/** liveOffOf for a page that doesn't read every view itself: it reads the other ones too, cached and shared. */
export function useLiveOff(): string | null {
    const inventory = useLiveEstate("inventory");
    const health = useLiveEstate("health");
    const security = useLiveEstate("security");
    return liveOffOf([inventory, health, security]);
}

/** Live views' one line while Database Hub's live view isn't available to the app (R924). */
export function liveOffText(reason: string): string {
    return reason === LIVE_REFUSED ? "Database Hub's live data isn't available to Fabric apps yet, and the app shows the history." : `${sentence(reason)} The app shows the history.`;
}

/** One view of the live estate for a page: a cold read takes 5 to 12 seconds, then it's cached for 60. */
export function useLiveEstate<V extends EstateView>(view: V, enabled = true): LiveState<V> {
    const [nonce, setNonce] = useState(0);
    const [remembered] = useState(rememberedLiveOff);
    const [settled, setSettled] = useState<{ view: V; n: number; answer: EstateAnswer<V> | null; unavailable: string | null; missed: MissedAnswer | null; off: string | null } | null>(null);
    useEffect(() => {
        if (!enabled) return;
        let alive = true;
        readLiveEstate(view, nonce > 0 ? { force: true } : undefined).then(
            (answer) => {
                if (!alive) return;
                // No data at all: the page says why in the function's one plain sentence, or that Database Hub didn't
                // answer just now, never a route's error (R924), and counts the view's routes as didn't answer.
                if (liveDataOf(answer) === null) {
                    const off = answer.unavailable || null;
                    if (off) rememberLiveOff(view, off);
                    setSettled({ view, n: nonce, answer: null, unavailable: off ?? LIVE_NO_ANSWER, missed: { source: [...answer.source], errors: [...answer.errors] }, off });
                } else {
                    rememberLiveOff(view, null);
                    setSettled({ view, n: nonce, answer, unavailable: null, missed: null, off: null });
                }
            },
            (error: unknown) => {
                if (alive) setSettled({ view, n: nonce, answer: null, unavailable: error instanceof Error ? error.message : String(error), missed: null, off: null });
            },
        );
        return () => {
            alive = false;
        };
    }, [view, enabled, nonce]);
    const refresh = useCallback(() => setNonce((n) => n + 1), []);
    if (!enabled) return { answer: null, loading: false, unavailable: null, missed: null, off: null, refresh };
    // While a refresh runs, the page keeps showing what it had; until the view's first read ends, the last one in this
    // browser says whether its live data is available to the app.
    const current = settled && settled.view === view ? settled : null;
    const done = current !== null && current.n === nonce;
    return { answer: current?.answer ?? null, loading: !done, unavailable: done ? current.unavailable : null, missed: current?.missed ?? null, off: current ? current.off : (remembered[view] ?? null), refresh };
}