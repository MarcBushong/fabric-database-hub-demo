// The Root cause page's facets and the chat's find_incidents and triage_window filters (ADR 0031, section 7), one rule for
// both: an incident's category from the family of its signal, its severity from its own measurements, and its target.
// Blind: it reads only the detector's episodes, never what anyone planned or ran.

import type { Family } from "./detector";
import { RCA_CATEGORIES, RCA_CATEGORY_IDS, RCA_FACET_TARGETS, RCA_SEVERITIES, RCA_SEVERITY_IDS, type RcaCategory, type RcaGroup, type RcaSeverity, type RcaSort } from "./facet-ids";
import type { Episode } from "./types";

/**
 * Each detector family's category. The wait classes Database Hub's telemetry reports by category are waits, except IO's
 * (PAGEIOLATCH, and WRITELOG's transaction log IO); the log rate governor is Azure SQL Database's resource governance
 * throttling the log, as Wave 1 files it, beside T5's 429s and its normalized RU at 100 %.
 */
const CATEGORY_OF: Record<Family, RcaCategory> = {
    blocking: "blocking",
    deadlock: "deadlocks",
    cpu: "cpu",
    latch: "waits",
    memory: "waits",
    parallelism: "waits",
    network: "waits",
    errors: "errors",
    connections: "connections",
    replica_lag: "replica_lag",
    throttling: "throttling",
    ru: "throttling",
    log_rate: "throttling",
    io: "io",
    tran_log: "io",
};

/** An incident's category, by the family of its signal; a family the detector adds later reads as waits until it's filed. */
export function categoryOf(family: string): RcaCategory {
    return (CATEGORY_OF as Readonly<Record<string, RcaCategory>>)[family] ?? "waits";
}

export const categoryLabel = (id: RcaCategory) => RCA_CATEGORIES.find((c) => c.id === id)?.label ?? id;
export const severityLabel = (id: RcaSeverity) => RCA_SEVERITIES.find((s) => s.id === id)?.label ?? id;

/** An incident is long when its signal stayed over its level at least this many minutes. */
export const LONG_MINUTES = 5;
/** Far over its level: this many times its level, for a count or seconds. */
export const FAR_TIMES = 4;
/** Far, for a share of a capacity (CPU, T4's connections against the limit, T5's normalized RU): this share or more. */
export const FAR_PERCENT = 90;

/**
 * The far mark of a signal at a level: FAR_TIMES its level for a count or seconds (a level of zero, which any amount opens,
 * as 1); for a share of a capacity, FAR_PERCENT % or more, or its level when that's higher (T5's normalized RU at 100 %),
 * since a level the detector set from a low baseline says little about the capacity left.
 */
export function farMark(unit: string, level: number): number {
    return unit === "%" ? Math.max(FAR_PERCENT, level) : FAR_TIMES * Math.max(level, 1);
}

/** What severityOf reads: the episode's own measurements. */
export type Measured = Pick<Episode, "unit" | "level" | "peak" | "start" | "end" | "last" | "support" | "farMs">;

export interface SeverityOf {
    severity: RcaSeverity;
    /** Why, in words: how far, how long, and how sure, with the numbers. */
    reason: string;
}

const round = (v: number) => (Math.abs(v) >= 100 ? Math.round(v) : Math.round(v * 10) / 10);
const SINGULAR: Readonly<Record<string, string>> = { processes: "process", deadlocks: "deadlock", errors: "error", requests: "request" };
const amount = (value: number, unit: string) => (unit === "%" ? `${round(value)} %` : `${round(value)} ${round(value) === 1 ? (SINGULAR[unit] ?? unit) : unit}`);
/** Minutes floored to a tenth, so a time under a threshold never reads as the threshold ("4.6 minutes", never "5 minutes, under 5"). */
const minutesText = (minutes: number) => {
    const n = minutes >= 10 ? Math.floor(minutes) : Math.floor(minutes * 10) / 10;
    return `${n} minute${n === 1 ? "" : "s"}`;
};

/**
 * An incident's severity, from what its signal measured and nothing else (farMark for how far):
 * - High: at its far mark for LONG_MINUTES or more in all (Episode.farMs), so it was far over its level, and stayed there;
 *   a blocking chain that re-forms, or a surge in waves, counts each time it's there;
 * - Medium: far at its peak, or over its level for LONG_MINUTES or more, from its start to its end, or to its last sample at
 *   the level when its end isn't known;
 * - Low: neither.
 * Seen in one sample (low confidence), it's a step lower: one reading tells neither how long nor how sure.
 */
export function severityOf(e: Measured): SeverityOf {
    const percent = e.unit === "%";
    const far = e.peak >= farMark(e.unit, e.level);
    const farMinutes = (e.farMs ?? 0) / 60_000;
    const held = far && farMinutes >= LONG_MINUTES;
    const minutes = Math.max(0, ((e.end ?? e.last).getTime() - e.start.getTime()) / 60_000);
    const long = minutes >= LONG_MINUTES;
    const one = e.support === "single sample";
    const base: RcaSeverity = held ? "high" : far || long ? "medium" : "low";
    const severity: RcaSeverity = one ? (base === "high" ? "medium" : "low") : base;
    const level = amount(e.level, e.unit);
    const how = percent
        ? e.level > FAR_PERCENT
            ? `${far ? "at" : "under"} its level of ${level}, the most it reads`
            : `${far ? `${FAR_PERCENT} % or more` : `under ${FAR_PERCENT} %`} of its capacity`
        : e.level === 0
          ? `${far ? "four times its level or more" : "under four times its level"} (it opens on any, so ${far ? `${FAR_TIMES} or more` : `under ${FAR_TIMES}`})`
          : `${far ? "four times its level of" : "under four times its level of"} ${level}${far ? " or more" : ""}`;
    const stayed = far ? `, there ${farMinutes < 1 ? "under a minute" : `for ${minutesText(farMinutes)} in all`}${held ? "" : `, under ${LONG_MINUTES}`}` : "";
    const span = minutes < 1 ? "under a minute" : minutesText(minutes);
    const lasted = e.end ? `over its level for ${span}` : minutes < 1 ? "over its level, its end not known" : `over its level for at least ${span}, its end not known`;
    const length = long ? `, ${LONG_MINUTES} or more` : minutes < 1 ? "" : `, under ${LONG_MINUTES}`;
    const sure = e.support === "single sample" ? "low confidence: one sample, so a step lower" : e.support === "sparse" ? "medium confidence" : "high confidence";
    return { severity, reason: `${severityLabel(severity)}: peak ${amount(e.peak, e.unit)}, ${how}${stayed}; ${lasted}${length}; ${sure}.` };
}

/** Errors that no burst opened an episode for (triage counts them): under their level, so Low. */
export const COUNTED_ERRORS_SEVERITY: SeverityOf = { severity: "low", reason: "Low: errors counted, but no burst over their level, so no episode." };

/** What the facets read off an incident. */
export interface Faceted {
    target: string;
    category: RcaCategory;
    severity: RcaSeverity;
}

/** The filters as find_incidents and triage_window take them, and as the page applies them: an empty list is every value. */
export interface FacetFilter {
    categories?: readonly RcaCategory[];
    severities?: readonly RcaSeverity[];
    targets?: readonly string[];
}

type FacetName = "categories" | "severities" | "targets";

/** Whether an incident passes the filters, leaving one of them out (`except`): that facet's counts. */
export function matches(item: Faceted, f: FacetFilter, except?: FacetName): boolean {
    const passes = (name: FacetName, value: string) => except === name || !f[name]?.length || (f[name] as readonly string[]).includes(value);
    return passes("categories", item.category) && passes("severities", item.severity) && passes("targets", item.target);
}

export interface FacetCounts {
    categories: Record<RcaCategory, number>;
    severities: Record<RcaSeverity, number>;
    targets: Record<string, number>;
}

/** How many incidents each value of a facet would show, with the other facets' filters as they are. */
export function facetCounts(items: readonly Faceted[], f: FacetFilter): FacetCounts {
    const zero = <K extends string>(keys: readonly K[]) => Object.fromEntries(keys.map((k) => [k, 0])) as Record<K, number>;
    const out: FacetCounts = { categories: zero(RCA_CATEGORY_IDS), severities: zero(RCA_SEVERITY_IDS), targets: zero(RCA_FACET_TARGETS) };
    for (const item of items) {
        if (matches(item, f, "categories")) out.categories[item.category] += 1;
        if (matches(item, f, "severities")) out.severities[item.severity] += 1;
        if (matches(item, f, "targets")) out.targets[item.target] = (out.targets[item.target] ?? 0) + 1;
    }
    return out;
}

const SEVERITY_RANK: Readonly<Record<RcaSeverity, number>> = { high: 0, medium: 1, low: 2 };
const targetRank = (t: string) => {
    const i = (RCA_FACET_TARGETS as readonly string[]).indexOf(t);
    return i < 0 ? RCA_FACET_TARGETS.length : i;
};

/**
 * The incidents by severity, most severe first, or by time, oldest first. Of equal severity, `rank`'s higher first (the
 * page's: the richest evidence), then the earlier; of equal times, by target.
 */
export function sortIncidents<T extends Faceted & { start: string }>(items: readonly T[], sort: RcaSort, rank: (item: T) => number = () => 0): T[] {
    const byTime = (a: T, b: T) => a.start.localeCompare(b.start) || targetRank(a.target) - targetRank(b.target);
    return [...items].sort(sort === "severity" ? (a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] || rank(b) - rank(a) || byTime(a, b) : byTime);
}

export interface IncidentGroup<T> {
    /** The category's or the target's id; "all" without groups. */
    id: string;
    items: T[];
}

/** The sorted incidents in groups: by category or by target, in the facets' order, each group sorted; or one group. */
export function groupIncidents<T extends Faceted & { start: string }>(items: readonly T[], group: RcaGroup, sort: RcaSort, rank?: (item: T) => number): Array<IncidentGroup<T>> {
    const sorted = sortIncidents(items, sort, rank);
    if (group === "none") return sorted.length ? [{ id: "all", items: sorted }] : [];
    const order: readonly string[] = group === "category" ? RCA_CATEGORY_IDS : [...RCA_FACET_TARGETS, ...new Set(sorted.map((i) => i.target).filter((t) => !(RCA_FACET_TARGETS as readonly string[]).includes(t)))];
    return order.map((id) => ({ id, items: sorted.filter((i) => (group === "category" ? i.category : i.target) === id) })).filter((g) => g.items.length > 0);
}

/**
 * The categories and severities a tool's arguments ask for: null when they ask for neither, and a message when a value
 * isn't one of them, so the chat never takes an unfiltered list for a filtered one.
 */
export function facetArgs(args: Record<string, unknown>): { categories: RcaCategory[]; severities: RcaSeverity[] } | string | null {
    const read = <K extends string>(name: string, allowed: readonly K[]): K[] | string => {
        const value = args[name];
        if (value === undefined || value === null) return [];
        const given = Array.isArray(value) ? value : [value];
        const unknown = given.filter((v) => !(allowed as readonly unknown[]).includes(v));
        if (unknown.length) return `${name} takes ${allowed.join(", ")}; ${JSON.stringify(unknown)} isn't one of them.`;
        return allowed.filter((k) => given.includes(k));
    };
    const categories = read("categories", RCA_CATEGORY_IDS);
    if (typeof categories === "string") return categories;
    const severities = read("severities", RCA_SEVERITY_IDS);
    if (typeof severities === "string") return severities;
    return categories.length || severities.length ? { categories, severities } : null;
}
