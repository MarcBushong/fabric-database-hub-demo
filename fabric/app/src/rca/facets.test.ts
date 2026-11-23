// The Root cause page's facets and the chat's filters (ADR 0031, section 7): each incident's category, its severity from its
// own measurements, and how the page filters, counts, groups, and sorts them.

import { describe, expect, it } from "vitest";

import { RULES } from "./detector";
import { RCA_CATEGORY_IDS, type RcaCategory, type RcaSeverity } from "./facet-ids";
import { categoryOf, facetArgs, facetCounts, groupIncidents, matches, severityOf, sortIncidents, type Measured } from "./facets";

const at = (hm: string) => new Date(`2026-11-20T${hm}:00Z`);
const MIN = 60_000;
const measured = (patch: Partial<Measured> & Pick<Measured, "unit" | "level" | "peak">): Measured => ({ start: at("14:02"), end: at("14:11"), last: at("14:10"), support: "sustained", farMs: 0, ...patch });

describe("an incident's category", () => {
    it("files every family the detector has, and each category holds one at least", () => {
        const filed = Object.keys(RULES).map((family) => [family, categoryOf(family)]);
        expect(Object.fromEntries(filed)).toEqual({
            blocking: "blocking",
            deadlock: "deadlocks",
            cpu: "cpu",
            io: "io",
            log_rate: "throttling",
            latch: "waits",
            memory: "waits",
            parallelism: "waits",
            tran_log: "io",
            network: "waits",
            errors: "errors",
            replica_lag: "replica_lag",
            connections: "connections",
            throttling: "throttling",
            ru: "throttling",
        });
        expect([...new Set(filed.map(([, c]) => c))].sort()).toEqual([...RCA_CATEGORY_IDS].sort());
    });
});

describe("an incident's severity, from its own measurements", () => {
    it("is High when it stayed at its far mark 5 minutes or more in all: four times its level, or 90 % of a capacity", () => {
        // The preview's T1 chain re-formed 5 times in 9 minutes, far over its level for 7 of them.
        expect(severityOf(measured({ unit: "processes", level: 0, peak: 7, farMs: 7 * MIN }))).toEqual({
            severity: "high",
            reason: "High: peak 7 processes, four times its level or more (it opens on any, so 4 or more), there for 7 minutes in all; over its level for 9 minutes, 5 or more; high confidence.",
        });
        expect(severityOf(measured({ unit: "%", level: 80, peak: 95.6, end: at("14:17"), farMs: 15 * MIN })).severity).toBe("high");
        // T5's normalized RU: its level is 100 %, the most it reads.
        expect(severityOf(measured({ unit: "%", level: 100, peak: 100, farMs: 9 * MIN }))).toEqual({
            severity: "high",
            reason: "High: peak 100 %, at its level of 100 %, the most it reads, there for 9 minutes in all; over its level for 9 minutes, 5 or more; high confidence.",
        });
    });

    it("is Medium when it was far only briefly, or over its level long but never far", () => {
        // B's connection surge at 15:26: at the limit for 4.6 minutes, which never reads as 5.
        expect(severityOf(measured({ unit: "%", level: 80, peak: 100, farMs: 4.65 * MIN }))).toEqual({
            severity: "medium",
            reason: "Medium: peak 100 %, 90 % or more of its capacity, there for 4.6 minutes in all, under 5; over its level for 9 minutes, 5 or more; high confidence.",
        });
        // B's replica stall: 177 s, nearly six times its 30 s level, but far for a minute.
        expect(severityOf(measured({ unit: "s", level: 30, peak: 177, end: at("14:05"), farMs: MIN })).severity).toBe("medium");
        // CPU over its baseline's level for 12 minutes, but under 90 %: busy, with capacity left.
        expect(severityOf(measured({ unit: "%", level: 36.2, peak: 83.9, end: at("14:14") }))).toEqual({ severity: "medium", reason: "Medium: peak 83.9 %, under 90 % of its capacity; over its level for 12 minutes, 5 or more; high confidence." });
    });

    it("is Low when it's neither, and a step lower when it was seen in one sample", () => {
        expect(severityOf(measured({ unit: "s", level: 30, peak: 38, end: at("14:02"), last: at("14:02") })).severity).toBe("low");
        // Far for 15 minutes in one 15-minute sample: one reading, so Medium.
        expect(severityOf(measured({ unit: "requests", level: 0, peak: 800, end: at("14:17"), last: at("14:02"), support: "single sample", farMs: 15 * MIN }))).toEqual({
            severity: "medium",
            reason: "Medium: peak 800 requests, four times its level or more (it opens on any, so 4 or more), there for 15 minutes in all; over its level for 15 minutes, 5 or more; low confidence: one sample, so a step lower.",
        });
        expect(severityOf(measured({ unit: "deadlocks", level: 0, peak: 1, end: at("14:03"), last: at("14:02"), support: "single sample" }))).toEqual({
            severity: "low",
            reason: "Low: peak 1 deadlock, under four times its level (it opens on any, so under 4); over its level for 1 minute, under 5; low confidence: one sample, so a step lower.",
        });
    });

    it("measures an incident whose end isn't known to its last sample at the level, and says so", () => {
        expect(severityOf(measured({ unit: "%", level: 14.3, peak: 96.2, end: null, last: at("14:08"), farMs: 7 * MIN }))).toEqual({
            severity: "high",
            reason: "High: peak 96.2 %, 90 % or more of its capacity, there for 7 minutes in all; over its level for at least 6 minutes, its end not known, 5 or more; high confidence.",
        });
        expect(severityOf(measured({ unit: "s", level: 30, peak: 34, end: null, last: at("14:02"), support: "single sample" })).reason).toBe("Low: peak 34 s, under four times its level of 30 s; over its level, its end not known; low confidence: one sample, so a step lower.");
    });
});

type Item = { key: string; target: string; category: RcaCategory; severity: RcaSeverity; start: string };
const item = (key: string, target: string, category: RcaCategory, severity: RcaSeverity, hm: string): Item => ({ key, target, category, severity, start: `2026-11-20T${hm}:00Z` });
const ITEMS: Item[] = [
    item("a", "T1", "blocking", "high", "14:02"),
    item("b", "T3", "cpu", "medium", "13:32"),
    item("c", "T5", "throttling", "high", "13:34"),
    item("d", "T4", "deadlocks", "low", "14:21"),
    item("e", "T1", "cpu", "medium", "13:53"),
    item("f", "T4-replica", "replica_lag", "low", "14:22"),
];

describe("filtering, counting, grouping, and sorting the list", () => {
    it("counts each facet's values with the other facets' filters as they are", () => {
        const counts = facetCounts(ITEMS, { categories: ["cpu"], targets: ["T1"] });
        // Severities see only T1's CPU; targets see only CPU; categories see only T1.
        expect(counts.severities).toEqual({ high: 0, medium: 1, low: 0 });
        expect(counts.targets).toEqual({ T1: 1, T2: 0, T3: 1, T4: 0, "T4-replica": 0, T5: 0 });
        expect(counts.categories).toMatchObject({ blocking: 1, cpu: 1, deadlocks: 0, throttling: 0 });
        expect(ITEMS.filter((i) => matches(i, { categories: ["cpu"], targets: ["T1"] })).map((i) => i.key)).toEqual(["e"]);
        // No filter is every value.
        expect(ITEMS.filter((i) => matches(i, {})).length).toBe(ITEMS.length);
    });

    it("sorts by severity, most severe first, then by its rank and time; or by time alone", () => {
        expect(sortIncidents(ITEMS, "severity").map((i) => i.key)).toEqual(["c", "a", "b", "e", "d", "f"]);
        // The page's rank (the richest evidence) comes before time within a severity.
        expect(sortIncidents(ITEMS, "severity", (i) => (i.key === "a" ? 1 : 0)).map((i) => i.key)).toEqual(["a", "c", "b", "e", "d", "f"]);
        expect(sortIncidents(ITEMS, "time").map((i) => i.key)).toEqual(["b", "c", "e", "a", "d", "f"]);
    });

    it("groups by category or by target in the facets' order, each group sorted, or not at all", () => {
        expect(groupIncidents(ITEMS, "category", "severity").map((g) => [g.id, g.items.map((i) => i.key)])).toEqual([
            ["blocking", ["a"]],
            ["deadlocks", ["d"]],
            ["cpu", ["b", "e"]],
            ["replica_lag", ["f"]],
            ["throttling", ["c"]],
        ]);
        expect(groupIncidents(ITEMS, "target", "time").map((g) => [g.id, g.items.map((i) => i.key)])).toEqual([
            ["T1", ["e", "a"]],
            ["T3", ["b"]],
            ["T4", ["d"]],
            ["T4-replica", ["f"]],
            ["T5", ["c"]],
        ]);
        expect(groupIncidents(ITEMS, "none", "time")).toEqual([{ id: "all", items: sortIncidents(ITEMS, "time") }]);
        expect(groupIncidents([], "category", "time")).toEqual([]);
    });
});

describe("the chat's filters", () => {
    it("reads categories, severities, and targets, in the facets' order, and refuses a value that isn't one", () => {
        expect(facetArgs({})).toBeNull();
        expect(facetArgs({ categories: [], severities: [], targets: [] })).toBeNull();
        expect(facetArgs({ severities: ["low", "high"], categories: ["io", "blocking"] })).toEqual({ categories: ["blocking", "io"], severities: ["high", "low"], targets: [] });
        expect(facetArgs({ severities: "high" })).toEqual({ categories: [], severities: ["high"], targets: [] });
        expect(facetArgs({ targets: ["T5", "T4-replica"] })).toEqual({ categories: [], severities: [], targets: ["T4-replica", "T5"] });
        expect(facetArgs({ categories: ["locking"] })).toBe('categories takes blocking, deadlocks, cpu, waits, errors, connections, replica_lag, throttling, io; ["locking"] isn\'t one of them.');
        expect(facetArgs({ severities: ["critical"] })).toBe('severities takes high, medium, low; ["critical"] isn\'t one of them.');
        expect(facetArgs({ targets: ["T9"] })).toBe('targets takes T1, T2, T3, T4, T4-replica, T5; ["T9"] isn\'t one of them.');
    });
});
