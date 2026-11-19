import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { MAX_CONTEXT_ROWS } from "@/copilot/contract";
import { estateQuery } from "@/data/queries";
import { flagText, inventoryMix, liveOptimizationRows, liveSecurityRows, targetOfResource } from "@/lib/live-findings";
import { sampleLiveAnswers } from "@/preview/sample-live";
import { buildAskContext } from "@/lib/ask";
import { describeRequest, notebookParameters, validateRequest } from "@/lib/control";
import { parameterCellText } from "@/lib/manage-client";
import { profileLabel, SCENARIOS } from "@/lib/scenarios";
import { weekOverWeek } from "@/lib/trends";
import { DEFAULT_VIEW, mergeView, parseHash, toHash } from "@/lib/view-state";
import { APP_TOKENS, contrastRatio, FLUENT_THEMES, loadThemeChoice, resolveTheme, type ThemeId } from "@/theme/fluent";

describe("themes", () => {
    it("keeps every status color readable (4.5:1) and every target and chart color visible (3:1) on each surface", () => {
        for (const [id, tokens] of Object.entries(APP_TOKENS)) {
            for (const surface of tokens.surfaces) {
                for (const [name, color] of Object.entries(tokens.text)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
                for (const [name, color] of Object.entries(tokens.graphic)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
        }
    });

    it("keeps Fabric teal links readable on the light and dark themes' surfaces", () => {
        expect(contrastRatio(FLUENT_THEMES.light.colorBrandForeground1, "#FFFFFF")).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(FLUENT_THEMES.dark.colorBrandForeground1, "#292929")).toBeGreaterThanOrEqual(4.5);
    });

    it("follows the system until the viewer picks, and carries over the older app's choice", () => {
        expect(resolveTheme("system", true, false)).toBe("dark");
        expect(resolveTheme("system", false, true)).toBe("contrast");
        expect(resolveTheme("light", true, true)).toBe("light");
        const store = (values: Record<string, string>) => ({ getItem: (k: string) => values[k] ?? null });
        expect(loadThemeChoice(store({ "dbhub-insights.theme.v1": "aurora" }))).toBe("dark");
        expect(loadThemeChoice(store({ "dbhub-insights.theme.v2": "contrast", "dbhub-insights.theme.v1": "daybreak" }))).toBe("contrast");
        expect(loadThemeChoice(undefined)).toBe("system");
        const ids: ThemeId[] = ["light", "dark", "contrast"];
        expect(Object.keys(FLUENT_THEMES).sort()).toEqual([...ids].sort());
    });
});

describe("view state", () => {
    it("round-trips drill-downs and the filter through the hash", () => {
        const view = mergeView({ page: "estate", target: "T3", targets: ["T1", "T3"], window: "30d" });
        expect(toHash(view)).toBe("#/estate/T3?t=T1%2CT3&w=30d");
        expect(mergeView(parseHash(toHash(view)))).toEqual(view);
        const incident = mergeView({ page: "incidents", incident: "scenario:T3:cpu:7", replay: 4 });
        expect(toHash(incident)).toBe("#/incidents/scenario%3AT3%3Acpu%3A7?r=4");
        expect(mergeView(parseHash(toHash(incident)))).toEqual(incident);
        expect(toHash(DEFAULT_VIEW)).toBe("#/overview");
    });

    it("opens a Findings category from the address, and drops an unknown one", () => {
        expect(parseHash("#/findings/security")).toMatchObject({ page: "findings", category: "security" });
        expect(parseHash("#/findings/bogus").category).toBeUndefined();
        expect(toHash(mergeView({ page: "findings", category: "optimization" }))).toBe("#/findings/optimization");
    });
    it("opens an older app's PostgreSQL page as T4's drill-down, and drops unknown or unsafe values", () => {
        expect(parseHash("#/postgres")).toEqual({ page: "estate", target: "T4" });
        expect(parseHash("#/admin?t=T9,T2&w=1y&i=<script>&r=-3")).toEqual({ targets: ["T2"] });
        expect(parseHash("#/estate/T9")).toEqual({ page: "estate" });
        expect(parseHash("#/incidents/%E0%A4%A")).toEqual({ page: "incidents" });
    });
});

describe("Ask Copilot's context", () => {
    it("bounds the rows, makes dates plain text, and joins the DAX behind them", () => {
        const spec = estateQuery({ targets: ["T3"], window: null });
        const rows = Array.from({ length: MAX_CONTEXT_ROWS + 5 }, (_, i) => ({ at: new Date(Date.UTC(2026, 10, 17, 0, i)), cpu: i }));
        const ctx = buildAskContext({ title: "CPU", page: "estate", visualId: "estate.target.cpu", specs: [spec, null], rows, provenance: "history", meta: null, prompt: "Why?" });
        expect(ctx.rows).toHaveLength(MAX_CONTEXT_ROWS);
        expect(ctx).toMatchObject({ totalRows: MAX_CONTEXT_ROWS + 5, truncated: true, prompt: "Why?", source: "history" });
        expect(ctx.rows?.[1]).toEqual({ at: "2026-11-17T00:01:00.000Z", cpu: 1 });
        expect(ctx.dax).toBe(`// ${spec.title}\n${spec.dax}`);
    });
});

describe("the control's requests", () => {
    it("maps each action to the control notebook's parameters", () => {
        expect(notebookParameters({ action: "session", durationMinutes: 60 })).toEqual({
            MODE: { value: "session", type: "string" },
            DURATION_MINUTES: { value: 60, type: "int" },
            WAIT_FOR_END: { value: true, type: "bool" },
        });
        expect(notebookParameters({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10, intensity: 7 })).toMatchObject({
            MODE: { value: "activities" },
            ACTIVITIES: { value: '[{"target":"T3","scenario":"cpu-pressure","intensity":7}]', type: "string" },
        });
        expect(notebookParameters({ action: "stop" })).toEqual({ STOP_NOW: { value: true, type: "bool" } });
        expect(notebookParameters({ action: "reset", targets: ["T1", "T3"] })).toEqual({ RESET_NOW: { value: true, type: "bool" }, RESET_TARGETS: { value: '["T1","T3"]', type: "string" } });
    });

    it("rejects what the control's allow-lists and caps would", () => {
        expect(validateRequest({ action: "session", durationMinutes: 200 })).toBe("A session runs 30 to 120 minutes.");
        expect(validateRequest({ action: "run", scenario: "replica-lag", target: "T3" })).toBe("Read replica lag runs on T4.");
        expect(validateRequest({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 45 })).toBe("CPU pressure runs 5 to 30 minutes.");
        expect(validateRequest({ action: "run", scenario: "drop-database", target: "T3" })).toBe("Pick a scenario from the catalog.");
        expect(validateRequest({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10 })).toBeNull();
        expect(describeRequest({ action: "stop" }).effects[0]).toBe("Stops every running activity.");
        expect(describeRequest({ action: "session" }).effects[2]).toMatch(/^Includes T3's Database Agent beat/);
    });

    it("copies a request as Python lines for a new cell under the control notebook's parameters cell", () => {
        expect(parameterCellText({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10, intensity: 6 }).split("\n").slice(1)).toEqual([
            'MODE = "activities"',
            'ACTIVITIES = [{"target":"T3","scenario":"cpu-pressure","intensity":6}]',
            "DURATION_MINUTES = 10",
            "WATCH_MINUTES = 0",
        ]);
        expect(parameterCellText({ action: "reset", targets: ["T1", "T3"] })).toMatch(/\nRESET_NOW = True\nRESET_TARGETS = \["T1","T3"\]$/);
        expect(parameterCellText({ action: "stop" })).toMatch(/^# From the Insights app: stop\. .+\nSTOP_NOW = True$/);
    });
    it("offers exactly the scenarios in scenarios/*/scenario.json, with their targets and bounds", () => {
        const root = join(process.cwd(), "..", "..", "scenarios");
        const fromRepo = readdirSync(root, { withFileTypes: true })
            .filter((d) => d.isDirectory())
            .map((d) => JSON.parse(readFileSync(join(root, d.name, "scenario.json"), "utf8")) as { id: string; title: string; duration: { defaultSeconds: number; maxSeconds: number }; targets: { applicable: string[] } })
            .map((s) => ({ id: s.id, title: s.title, targets: s.targets.applicable, defaultMinutes: Math.round(s.duration.defaultSeconds / 60), maxMinutes: Math.floor(s.duration.maxSeconds / 60) }))
            .sort((a, b) => a.id.localeCompare(b.id));
        expect(SCENARIOS).toEqual(fromRepo);
    });

    it("names each recorded profile: a session, an incident by its scenario's title, a reset", () => {
        expect(["showcase", "incident:plan-regression", "incident:not-in-catalog", "reset", ""].map(profileLabel)).toEqual(["Session", "Plan regression (automatic plan correction)", "not-in-catalog", "Reset", "Session"]);
    });
});

describe("trends", () => {
    it("compares the newest week with the week before, per target", () => {
        const day = (d: number) => new Date(Date.UTC(2026, 10, 1 + d));
        const days = [
            ...Array.from({ length: 14 }, (_, d) => ({ day: day(d), target: "T1" as const, cpuAvg: d < 7 ? 10 : 20, cpuPeak: null, waitS: 1, bufferIoS: null, lockWaitS: null, batch: null, sessionsPeak: null, incidents: d === 13 ? 1 : 0 })),
        ];
        const [t1] = weekOverWeek(days);
        expect(t1).toMatchObject({ target: "T1", cpuNow: 20, cpuBefore: 10, waitNow: 7, waitBefore: 7, incidentsNow: 1, incidentsBefore: 0 });
        expect(weekOverWeek([])).toEqual([]);
    });
});

describe("live findings", () => {
    it("names the demo's targets, reads Database Hub's flags, and keeps each warning once", () => {
        const answers = sampleLiveAnswers("2026-10-21T21:00:00.000Z");
        expect(targetOfResource({ name: "pgreplica01-x", databaseType: "PostgreSql" })).toBe("T4-replica");
        expect(targetOfResource({ name: "ContosoCare", databaseType: "AzureSql" }, "azuresql01-x")).toBe("T3");
        expect(targetOfResource({ name: "elsewhere", databaseType: "PostgreSql" })).toBe("");
        expect(flagText("hasSomethingNewIssue")).toBe("Something new");
        const rows = liveSecurityRows(answers.security.data, answers.inventory.data);
        expect(rows.map((r) => `${r.attention}|${r.target}|${r.area}`)).toEqual([
            "Needs attention|T3|Auditing",
            "Needs attention|T3|Customer-managed keys",
            "Recommended|T3|Ledger",
            "Recommended|T4|Customer-managed keys",
            "Recommended|T4-replica|Customer-managed keys",
        ]);
        expect(liveOptimizationRows(answers.inventory.data)).toMatchObject([{ target: "T1", attention: "Needs attention", area: "Licensing" }]);
        expect(inventoryMix(answers.inventory.data)).toBe("2 PostgreSQL · 1 Arc SQL · 1 Azure SQL · 1 SQL VM · 1 Cosmos DB");
        expect(inventoryMix(answers.inventory.data, true)).toMatch(/^2 Azure Database for PostgreSQL, 1 Arc-enabled SQL Server, /);
        expect(liveSecurityRows(null, null)).toEqual([]);
    });
});
