// The app's view state: page, filters, the incident and replay position, and visual options.
// Inside the Fabric portal the app runs in a frame without its own address bar, so the state lives in the app
// (and in the frame's hash for reloads), and the last view is remembered per browser.

import { isTargetKey, SQL_TARGETS, type DateWindow, type TargetKey } from "./dax";

export type PageId = "estate" | "incidents" | "readiness" | "links";
export type WindowId = "day" | "7d" | "30d" | "all";
export type SignalId = "waits" | "cpu" | "sessions" | "batch" | "bufferIo";
export type ClockMetric = "batch" | "waits" | "sessions";
export type WaitsView = "sankey" | "sunburst";

export interface ViewState {
    page: PageId;
    targets: TargetKey[];
    window: WindowId;
    incident: string | null;
    replay: number | null;
    ridgeSignal: SignalId;
    clockMetric: ClockMetric;
    waitsView: WaitsView;
}

export const PAGES: ReadonlyArray<{ id: PageId; label: string }> = [
    { id: "estate", label: "Estate" },
    { id: "incidents", label: "Incidents" },
    { id: "readiness", label: "Readiness" },
    { id: "links", label: "Live links" },
];

export const WINDOWS: ReadonlyArray<{ id: WindowId; label: string; days: number | null }> = [
    { id: "day", label: "Latest day", days: 1 },
    { id: "7d", label: "7 days", days: 7 },
    { id: "30d", label: "30 days", days: 30 },
    { id: "all", label: "All history", days: null },
];

export const DEFAULT_VIEW: ViewState = {
    page: "estate",
    targets: [...SQL_TARGETS],
    window: "7d",
    incident: null,
    replay: null,
    ridgeSignal: "waits",
    clockMetric: "waits",
    waitsView: "sankey",
};

const PAGE_IDS = new Set<PageId>(["estate", "incidents", "readiness", "links"]);
const WINDOW_IDS = new Set<WindowId>(["day", "7d", "30d", "all"]);
const SIGNALS = new Set<SignalId>(["waits", "cpu", "sessions", "batch", "bufferIo"]);
const CLOCK = new Set<ClockMetric>(["batch", "waits", "sessions"]);
const WAITS = new Set<WaitsView>(["sankey", "sunburst"]);
const INCIDENT_KEY = /^[A-Za-z0-9:._-]{1,120}$/;

function pick<T extends string>(value: string | null, allowed: Set<T>): T | undefined {
    return value !== null && allowed.has(value as T) ? (value as T) : undefined;
}

/** Reads `#/incidents?t=T1,T3&w=30d&i=<key>&r=4&s=cpu&c=batch&v=sunburst`. Unknown or invalid values are dropped. */
export function parseHash(hash: string): Partial<ViewState> {
    const text = hash.replace(/^#\/?/, "");
    const [path, query = ""] = text.split("?");
    const params = new URLSearchParams(query);
    const out: Partial<ViewState> = {};
    const page = pick(path || null, PAGE_IDS);
    if (page) out.page = page;
    const targets = (params.get("t") ?? "").split(",").filter(isTargetKey);
    if (targets.length > 0) out.targets = SQL_TARGETS.filter((t) => targets.includes(t));
    const window = pick(params.get("w"), WINDOW_IDS);
    if (window) out.window = window;
    const incident = params.get("i");
    if (incident && INCIDENT_KEY.test(incident)) out.incident = incident;
    const replay = Number(params.get("r"));
    if (params.has("r") && Number.isInteger(replay) && replay >= 0 && replay < 10000) out.replay = replay;
    const signal = pick(params.get("s"), SIGNALS);
    if (signal) out.ridgeSignal = signal;
    const clock = pick(params.get("c"), CLOCK);
    if (clock) out.clockMetric = clock;
    const waits = pick(params.get("v"), WAITS);
    if (waits) out.waitsView = waits;
    return out;
}

export function toHash(state: ViewState): string {
    const params = new URLSearchParams();
    if (state.targets.length !== SQL_TARGETS.length) params.set("t", state.targets.join(","));
    if (state.window !== DEFAULT_VIEW.window) params.set("w", state.window);
    if (state.incident) params.set("i", state.incident);
    if (state.replay !== null) params.set("r", String(state.replay));
    if (state.ridgeSignal !== DEFAULT_VIEW.ridgeSignal) params.set("s", state.ridgeSignal);
    if (state.clockMetric !== DEFAULT_VIEW.clockMetric) params.set("c", state.clockMetric);
    if (state.waitsView !== DEFAULT_VIEW.waitsView) params.set("v", state.waitsView);
    const query = params.toString();
    return `#/${state.page}${query ? `?${query}` : ""}`;
}

export function mergeView(...parts: Array<Partial<ViewState>>): ViewState {
    return Object.assign({}, DEFAULT_VIEW, ...parts) as ViewState;
}

const STORAGE_KEY = "dbhub-insights.view.v1";

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
