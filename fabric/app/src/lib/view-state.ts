// The app's view state: the page, the drill-down (a target, an incident, the replay position), and the global filter.
// Inside the Fabric portal the app runs in a frame without its own address bar, so the state lives in the app (and in
// the frame's hash for reloads), and the last view is remembered per browser.

import { DEFAULT_RCA_FILTERS, isReadableWindow, RCA_CATEGORY_IDS, RCA_FACET_TARGETS, RCA_GROUPS, RCA_NEWEST_MINUTES, RCA_SEVERITY_IDS, RCA_SORTS, type RcaFilters, type RcaNewest, type RcaWindow } from "../rca/facet-ids";
import type { DateWindow } from "./dax";

export type PageId = "mission" | "overview" | "estate" | "performance" | "incidents" | "rca" | "scoreboard" | "replay" | "findings" | "readiness" | "trends" | "manage" | "links" | "kiosk";
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
    /** The Root cause page's filters (ADR 0031, section 7): its facets, the minutes it reads, and its grouping and order; null for its defaults. */
    rcaFilters: RcaFilters | null;
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
    // Shown only when the history model has the Incident RCA's tables (ADR 0031): AppShell asks the app context.
    { id: "rca", label: "Root cause", description: "Why it happened: the blind investigation of an incident, head blocker first" },
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
    rcaFilters: null,
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

const STAMP = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;
const stamp = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
const fromStamp = (text: string): Date | null => {
    const m = STAMP.exec(text);
    if (!m) return null;
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
    return Number.isFinite(d.getTime()) ? d : null;
};
/** The Root cause page's windows in its address: the newest minutes ("90m", "6h", "24h"), or two times ("20261117T140000Z.20261117T153000Z"). */
const NEWEST_PARAM: Record<RcaNewest, string> = { 90: "90m", 360: "6h", 1440: "24h" };

function windowParam(w: RcaWindow): string {
    return "newest" in w ? NEWEST_PARAM[w.newest] : `${stamp(w.from)}.${stamp(w.to)}`;
}

function parseWindow(text: string | null): RcaWindow | undefined {
    if (!text) return undefined;
    const newest = RCA_NEWEST_MINUTES.find((n) => NEWEST_PARAM[n] === text);
    if (newest) return { newest };
    const [a, b, rest] = text.split(".");
    const from = a ? fromStamp(a) : null;
    const to = b ? fromStamp(b) : null;
    // At most the page's MAX_WINDOW_HOURS: a longer one isn't the page's to read (the review of 90e9d914).
    return rest === undefined && from && to && isReadableWindow(from, to) ? { from, to } : undefined;
}

/** Reads the Root cause page's filters from its address's query (cat, sev, tg, win, group, sort), or null without any. */
function parseRcaFilters(params: URLSearchParams): RcaFilters | null {
    const list = <T extends string>(key: string, allowed: readonly T[]): T[] | undefined => {
        if (!params.has(key)) return undefined;
        const given = (params.get(key) ?? "").split(",");
        return allowed.filter((v) => given.includes(v));
    };
    const parsed: Partial<RcaFilters> = {};
    const categories = list("cat", RCA_CATEGORY_IDS);
    if (categories) parsed.categories = categories;
    const severities = list("sev", RCA_SEVERITY_IDS);
    if (severities) parsed.severities = severities;
    const targets = list("tg", RCA_FACET_TARGETS);
    if (targets) parsed.targets = targets;
    const window = parseWindow(params.get("win"));
    if (window) parsed.window = window;
    const group = pick(params.get("group"), new Set(RCA_GROUPS));
    if (group) parsed.group = group;
    const sort = pick(params.get("sort"), new Set(RCA_SORTS));
    if (sort) parsed.sort = sort;
    return Object.keys(parsed).length ? { ...DEFAULT_RCA_FILTERS, ...parsed } : null;
}

/** Writes the Root cause page's filters that aren't its defaults. */
function writeRcaFilters(params: URLSearchParams, f: RcaFilters): void {
    if (f.categories.length) params.set("cat", f.categories.join(","));
    if (f.severities.length) params.set("sev", f.severities.join(","));
    if (f.targets.length) params.set("tg", f.targets.join(","));
    const window = windowParam(f.window);
    if (window !== windowParam(DEFAULT_RCA_FILTERS.window)) params.set("win", window);
    if (f.group !== DEFAULT_RCA_FILTERS.group) params.set("group", f.group);
    if (f.sort !== DEFAULT_RCA_FILTERS.sort) params.set("sort", f.sort);
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
    if ((page === "incidents" || page === "rca") && INCIDENT_KEY.test(sub)) out.incident = sub;
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
    if (page === "rca") {
        const rcaFilters = parseRcaFilters(params);
        if (rcaFilters) out.rcaFilters = rcaFilters;
    }
    return out;
}

export function toHash(state: ViewState): string {
    const params = new URLSearchParams();
    if (state.targets.length !== FILTER_TARGETS.length) params.set("t", state.targets.join(","));
    if (state.window !== DEFAULT_VIEW.window) params.set("w", state.window);
    let path: string = state.page;
    if (state.page === "estate" && state.target) path += `/${encodeURIComponent(state.target)}`;
    else if ((state.page === "incidents" || state.page === "rca") && state.incident) path += `/${encodeURIComponent(state.incident)}`;
    else if (state.page === "findings" && state.category) path += `/${state.category}`;
    else if (state.incident) params.set("i", state.incident);
    if (state.session) params.set("s", state.session);
    if (state.replay !== null) params.set("r", String(state.replay));
    if (state.page === "rca" && state.rcaFilters) writeRcaFilters(params, state.rcaFilters);
    const query = params.toString();
    return `#/${path}${query ? `?${query}` : ""}`;
}

export function mergeView(...parts: Array<Partial<ViewState>>): ViewState {
    return Object.assign({}, DEFAULT_VIEW, ...parts) as ViewState;
}

/**
 * The view the app opens with: the browser's saved view under the address's. The Root cause page's filters and incident
 * come from its address alone, so a link without them opens with the page's defaults and no incident, as whoever shared
 * it saw. The recipient's last filters could hide what it shares (the review of 90e9d914); their last incident would
 * replace it, and a saved older window key ("T1.<from>.<to>") would become their filters (the re-check of 62e5a18f).
 */
export function openView(saved: Partial<ViewState>, fromHash: Partial<ViewState>): ViewState {
    return mergeView(saved, fromHash, fromHash.page === "rca" ? { rcaFilters: fromHash.rcaFilters ?? null, incident: fromHash.incident ?? null } : {});
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
