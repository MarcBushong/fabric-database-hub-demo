// The Root cause page's facets (ADR 0031, section 7): their ids, labels, and order. No imports, so the app's address
// (lib/view-state.ts) reads them without loading the Incident RCA's code; facets.ts says what each one means.

/** An incident's category: the kind of signal it rose on, as a DBA groups them, in the order the page lists them. */
export const RCA_CATEGORIES = [
    { id: "blocking", label: "Blocking" },
    { id: "deadlocks", label: "Deadlocks" },
    { id: "cpu", label: "CPU" },
    { id: "waits", label: "Waits" },
    { id: "errors", label: "Errors" },
    { id: "connections", label: "Connections" },
    { id: "replica_lag", label: "Replica lag" },
    { id: "throttling", label: "Throttling" },
    { id: "io", label: "IO" },
] as const;

export type RcaCategory = (typeof RCA_CATEGORIES)[number]["id"];

export const RCA_CATEGORY_IDS: readonly RcaCategory[] = RCA_CATEGORIES.map((c) => c.id);

/** How severe an incident was, from its own measurements only (facets.ts, severityOf), most severe first. */
export const RCA_SEVERITIES = [
    { id: "high", label: "High" },
    { id: "medium", label: "Medium" },
    { id: "low", label: "Low" },
] as const;

export type RcaSeverity = (typeof RCA_SEVERITIES)[number]["id"];

export const RCA_SEVERITY_IDS: readonly RcaSeverity[] = RCA_SEVERITIES.map((s) => s.id);

/** The targets, each a server and its database: types.ts's RCA_TARGETS, repeated here without its imports. */
export const RCA_FACET_TARGETS = ["T1", "T2", "T3", "T4", "T4-replica", "T5"] as const;

export type RcaFacetTarget = (typeof RCA_FACET_TARGETS)[number];

/** How the list is grouped, and sorted within a group. */
export const RCA_GROUPS = ["category", "target", "none"] as const;
export type RcaGroup = (typeof RCA_GROUPS)[number];
export const RCA_SORTS = ["severity", "time"] as const;
export type RcaSort = (typeof RCA_SORTS)[number];

/** The windows the page reads without one of its own: the history's newest minutes. */
export const RCA_NEWEST_MINUTES = [90, 360, 1440] as const;
export type RcaNewest = (typeof RCA_NEWEST_MINUTES)[number];

/** The minutes the page reads: the history's newest ones, or a window of their own (a link's, or the viewer's). */
export type RcaWindow = { newest: RcaNewest } | { from: Date; to: Date };

/** The Root cause page's filters, as the app's address keeps them: an empty list is every value. */
export interface RcaFilters {
    categories: RcaCategory[];
    severities: RcaSeverity[];
    targets: RcaFacetTarget[];
    window: RcaWindow;
    group: RcaGroup;
    sort: RcaSort;
}

export const DEFAULT_RCA_FILTERS: RcaFilters = { categories: [], severities: [], targets: [], window: { newest: 90 }, group: "category", sort: "severity" };
