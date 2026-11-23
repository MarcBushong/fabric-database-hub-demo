// The app's view state: the page, the drill-down (a target, an incident, the replay position), and the global filter.
// Inside the Fabric portal the app runs in a frame without its own address bar, so the state lives in the app (and in
// the frame's hash for reloads), and the last view is remembered per browser.

import type { DateWindow } from "./dax";

export type PageId = "mission" | "overview" | "estate" | "performance" | "incidents" | "scoreboard" | "replay" | "findings" | "readiness" | "trends" | "manage" | "links" | "kiosk";
/** The pages in the navigation: every page but the kiosk, which runs without the app's frame. */
export type NavPageId = Exclude<PageId, "kiosk">;
export type WindowId = "day" | "7d" | "30d" | "all";

/** The global filter's targets: the SQL targets, T4 (with its read replica), and T5 when the estate has one. */
export type FilterTarget = "T1" | "T2" | "T3" | "T4" | "T5";
export const FILTER_TARGETS: readonly FilterTarget[] = ["T1", "T2", "T3", "T4", "T5"];

/** What a drill-down can open: a filter target or T4's read replica. */
export type EstateTarget = FilterTarget | "T4-replica";
export const ESTATE_TARGETS: readonly EstateTarget[] = ["T1", "T2", "T3", "T4", "T4-replica", "T5"];

/** The Findings page's categories, which Overview's tiles open directly (`#/findings/security`). */
export const FINDINGS_TABS = ["performance", "availability", "security", "optimization", "capacity", "readiness"] as const;
export type FindingsTab = (typeof FINDINGS_TABS)[number];

export interface ViewState {
    page: PageId;
    targets: FilterTarget[];
    window: WindowId;
    /** The target the Estate page drills into, or null for the inventory. */
    target: EstateTarget | null;
    incident: string | null;
    replay: number | null;
    /** The Findings page's category, or null for all of them. */
    category: FindingsTab | null;
    /** The session (or lone incident request) Mission Control, the scoreboard, the replay, and the kiosk are about, by its Scenario Runs request ID; null for the latest. */
    session: string | null;
}

export interface PageInfo {
    id: NavPageId;
    label: string;
    /** What the page answers, for its header and the navigation's tooltip. */
    description: string;
}

export const PAGES: readonly PageInfo[] = [
    { id: "mission", label: "Mission Control", description: "ContosoCare's services, the latest session, and what happened" },
    { id: "scoreboard", label: "Scoreboard", description: "Did we catch it? Every injected fault: its signal in its window, and its recovery" },
    { id: "replay", label: "Session replay", description: "Play a session back across every engine" },
    { id: "overview", label: "Overview", description: "What needs attention now" },
    { id: "estate", label: "Estate", description: "Every engine and target" },
    { id: "performance", label: "Performance", description: "CPU, waits, and throughput per target" },
    { id: "incidents", label: "Incidents", description: "Timeline, replay, and cause" },
    { id: "findings", label: "Findings", description: "Health, security, and optimization" },
    { id: "readiness", label: "Readiness", description: "Is the demo ready" },
    { id: "trends", label: "Trends", description: "History past the telemetry's 7 days" },
    { id: "manage", label: "Manage", description: "Sessions, incidents, and fixes" },
    { id: "links", label: "Live views", description: "Database Hub and the real-time dashboards" },
];

export const WINDOWS: ReadonlyArray<{ id: WindowId; label: string; days: number | null }> = [
    { id: "day", label: "Latest day", days: 1 },
    { id: "7d", label: "7 days", days: 7 },
    { id: "30d", label: "30 days", days: 30 },
    { id: "all", label: "All history", days: null },
];

export const DEFAULT_VIEW: ViewState = {
    page: "mission",
    targets: [...FILTER_TARGETS],
    window: "7d",
    target: null,
    incident: null,
    replay: null,
    category: null,
    session: null,
};

const PAGE_IDS = new Set<PageId>([...PAGES.map((p) => p.id), "kiosk"]);
const WINDOW_IDS = new Set<WindowId>(["day", "7d", "30d", "all"]);
const INCIDENT_KEY = /^[A-Za-z0-9:._-]{1,120}$/;
/** Hashes from the app before 2026-11-18: their pages and their drill-downs. */
const LEGACY_PAGES: Record<string, Partial<ViewState>> = { postgres: { page: "estate", target: "T4" } };

export function isFilterTarget(value: unknown): value is FilterTarget {
    return typeof value === "string" && (FILTER_TARGETS as readonly string[]).includes(value);
}

export function isEstateTarget(value: unknown): value is EstateTarget {
    return typeof value === "string" && (ESTATE_TARGETS as readonly string[]).includes(value);
}

function pick<T extends string>(value: string | null, allowed: Set<T>): T | undefined {
    return value !== null && allowed.has(value as T) ? (value as T) : undefined;
}

function decode(text: string): string {
    try {
        return decodeURIComponent(text);
    } catch {
        return "";
    }
}

/** Reads `#/estate/T3?t=T1,T3&w=30d` or `#/incidents/<key>?r=4`. Unknown or invalid values are dropped. */
export function parseHash(hash: string): Partial<ViewState> {
    const text = hash.replace(/^#\/?/, "");
    const [path, query = ""] = text.split("?");
    const [head, ...rest] = path.split("/");
    const sub = rest.length > 0 ? decode(rest.join("/")) : "";
    const params = new URLSearchParams(query);
    const out: Partial<ViewState> = {};
    const legacy = LEGACY_PAGES[head];
    if (legacy) Object.assign(out, legacy);
    const page = pick(head || null, PAGE_IDS);
    if (page) out.page = page;
    if (page === "estate" && isEstateTarget(sub)) out.target = sub;
    if (page === "incidents" && INCIDENT_KEY.test(sub)) out.incident = sub;
    if (page === "findings" && (FINDINGS_TABS as readonly string[]).includes(sub)) out.category = sub as FindingsTab;
    const targets = (params.get("t") ?? "").split(",").filter(isFilterTarget);
    if (targets.length > 0) out.targets = FILTER_TARGETS.filter((t) => targets.includes(t));
    const window = pick(params.get("w"), WINDOW_IDS);
    if (window) out.window = window;
    const incident = params.get("i");
    if (incident && INCIDENT_KEY.test(incident)) out.incident = incident;
    const session = params.get("s");
    if (session && INCIDENT_KEY.test(session)) out.session = session;
    const replay = Number(params.get("r"));
    if (params.has("r") && Number.isInteger(replay) && replay >= 0 && replay < 10000) out.replay = replay;
    return out;
}

export function toHash(state: ViewState): string {
    const params = new URLSearchParams();
    if (state.targets.length !== FILTER_TARGETS.length) params.set("t", state.targets.join(","));
    if (state.window !== DEFAULT_VIEW.window) params.set("w", state.window);
    let path: string = state.page;
    if (state.page === "estate" && state.target) path += `/${encodeURIComponent(state.target)}`;
    else if (state.page === "incidents" && state.incident) path += `/${encodeURIComponent(state.incident)}`;
    else if (state.page === "findings" && state.category) path += `/${state.category}`;
    else if (state.incident) params.set("i", state.incident);
    if (state.session) params.set("s", state.session);
    if (state.replay !== null) params.set("r", String(state.replay));
    const query = params.toString();
    return `#/${path}${query ? `?${query}` : ""}`;
}

export function mergeView(...parts: Array<Partial<ViewState>>): ViewState {
    return Object.assign({}, DEFAULT_VIEW, ...parts) as ViewState;
}

const STORAGE_KEY = "dbhub-insights.view.v2";

export function loadSavedView(storage: Pick<Storage, "getItem"> | undefined): Partial<ViewState> {
    try {
        const text = storage?.getItem(STORAGE_KEY);
        return text ? parseHash(text) : {};
    } catch {
        return {};
    }
}

export function saveView(storage: Pick<Storage, "setItem"> | undefined, state: ViewState): void {
    try {
        storage?.setItem(STORAGE_KEY, toHash(state));
    } catch {
        // Storage can be unavailable in a locked-down frame; the view still works in memory.
    }
}

/** The UTC date window for a window id, anchored to the newest day that has telemetry (not to today). */
export function windowRange(window: WindowId, latestDay: Date | null): DateWindow | null {
    const days = WINDOWS.find((w) => w.id === window)?.days ?? null;
    if (days === null || !latestDay) return null;
    const to = new Date(Date.UTC(latestDay.getUTCFullYear(), latestDay.getUTCMonth(), latestDay.getUTCDate()));
    const from = new Date(to.getTime() - (days - 1) * 86400000);
    return { from, to };
}

/** True when the app runs inside the Fabric portal's frame. */
export function isEmbedded(win: Window = window): boolean {
    try {
        return win.self !== win.top;
    } catch {
        return true;
    }
}

/**
 * Puts the view in the frame's address without a history entry. A browser can refuse: WebKit throws a SecurityError
 * after 100 calls in 10 seconds. The view then stays in memory and in storage, and the next change writes it again.
 */
export function replaceAddress(hash: string, win: Pick<Window, "location" | "history"> = window): void {
    try {
        if (win.location.hash !== hash) win.history.replaceState(null, "", hash);
    } catch {
        // Kept in memory; never an error for the viewer.
    }
}
