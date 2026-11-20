import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { DBHUB_BASE, LIVE_NO_SCOPE, LIVE_REFUSED, readEstate } from "../../rayfin/functions/src/estate-core";
import { MAX_CONTEXT_ROWS } from "@/copilot/contract";
import { estateQuery } from "@/data/queries";
import { liveDataOf, liveRouteLines, liveRoutes, type InventoryData } from "@/data/live-estate";
import { flagText, inventoryMix, isDown, liveMigrations, liveOptimizationRows, liveSecurityRows, migrationSentence, readinessText, savedMigration, targetOfResource, uniqueInventory } from "@/lib/live-findings";
import { parseDeployedMigration } from "@/lib/runtime-config";
import { sampleLiveAnswers } from "@/preview/sample-live";
import { buildAskContext } from "@/lib/ask";
import { describeRequest, notebookParameters, validateRequest } from "@/lib/control";
import { parameterCellText } from "@/lib/manage-client";
import { profileLabel, SCENARIOS } from "@/lib/scenarios";
import { weekOverWeek } from "@/lib/trends";
import { DEFAULT_VIEW, mergeView, parseHash, toHash } from "@/lib/view-state";
import { APP_TOKENS, contrastRatio, FABRIC_BRAND, FLUENT_THEMES, loadThemeChoice, resolveTheme, type ThemeId } from "@/theme/fluent";
import { APP_BRAND, CONTOSOCARE_BRAND } from "@/theme/identity";
import { STAGE_TOKENS, stageStyle, stageTheme } from "@/theme/stage";

describe("themes", () => {
    it("keeps every status color readable (4.5:1) and every target and chart color visible (3:1) on each surface", () => {
        for (const [id, tokens] of Object.entries(APP_TOKENS)) {
            for (const surface of tokens.surfaces) {
                for (const [name, color] of Object.entries(tokens.text)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
                for (const [name, color] of Object.entries(tokens.graphic)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
        }
    });

    it("keeps the brand's links readable on the light and dark themes' surfaces", () => {
        expect(contrastRatio(FLUENT_THEMES.light.colorBrandForeground1, "#FFFFFF")).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(FLUENT_THEMES.light.colorBrandForegroundLink, "#FFFFFF")).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(FLUENT_THEMES.dark.colorBrandForeground1, "#292929")).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(FLUENT_THEMES.dark.colorBrandForegroundLink, "#292929")).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio("#FFFFFF", FLUENT_THEMES.light.colorBrandBackground)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio("#FFFFFF", FLUENT_THEMES.dark.colorBrandBackground)).toBeGreaterThanOrEqual(4.5);
    });

    it("keeps the navigation's hovered and selected page readable in every theme, high contrast included", () => {
        // The token pairs styles/app.css applies, read from its rules: high contrast's selected and hover fill is cyan.
        const css = readFileSync(join(process.cwd(), "src", "styles", "app.css"), "utf8");
        const rule = (selector: string) => {
            const body = css.match(new RegExp(`^${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{([^}]*)\\}`, "m"))?.[1] ?? "";
            const token = (property: string) => body.match(new RegExp(`(?:^|[;\\s])${property}:\\s*var\\(--(\\w+)\\)`))?.[1] ?? "missing";
            return { color: token("color"), background: token("background") };
        };
        const hover = rule(".nav-item:hover");
        const selected = rule('.nav-item[aria-current="page"]');
        const bar = rule('.nav-item[aria-current="page"]::before');
        const icon = rule('.nav-item[aria-current="page"] .nav-icon');
        for (const [id, theme] of Object.entries(FLUENT_THEMES)) {
            const value = (token: string) => (theme as unknown as Record<string, string>)[token] ?? `no ${token}`;
            expect(contrastRatio(value(hover.color), value(hover.background)), `${id}: hovered page`).toBeGreaterThanOrEqual(4.5);
            expect(contrastRatio(value(selected.color), value(selected.background)), `${id}: selected page`).toBeGreaterThanOrEqual(4.5);
            expect(contrastRatio(value(icon.color), value(selected.background)), `${id}: selected page's icon`).toBeGreaterThanOrEqual(3);
            expect(contrastRatio(value(bar.background), value(selected.background)), `${id}: selected page's bar`).toBeGreaterThanOrEqual(3);
        }
    });

    it("uses ContosoCare's own brand ramp, not Fabric's teal, from one set of tokens (ADR 0030)", () => {
        expect(APP_BRAND).toBe(CONTOSOCARE_BRAND);
        expect(FLUENT_THEMES.light.colorBrandBackground).toBe(CONTOSOCARE_BRAND[80]);
        expect(FLUENT_THEMES.light.colorBrandBackground).not.toBe(FABRIC_BRAND[80]);
    });

    it("keeps the stage's text readable (4.5:1) and its marks visible (3:1), with the app's own tokens on it, in every theme", () => {
        for (const id of ["light", "dark", "contrast"] as const) {
            const stage = STAGE_TOKENS[id];
            const text = { ...stage.text, ...APP_TOKENS[id].text };
            const graphic = { ...stage.graphic, ...APP_TOKENS[id].graphic };
            for (const surface of Object.values(stage.surfaces)) {
                for (const [name, color] of Object.entries(text)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
                for (const [name, color] of Object.entries(graphic)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
        }
    });

    it("makes the stage dark until the viewer picks a theme, and keeps a picked theme and high contrast", () => {
        expect(stageTheme("system", "light")).toBe("dark");
        expect(stageTheme("system", "dark")).toBe("dark");
        expect(stageTheme("system", "contrast")).toBe("contrast");
        expect(stageTheme("light", "light")).toBe("light");
        expect(stageTheme("dark", "dark")).toBe("dark");
        expect(stageTheme("contrast", "contrast")).toBe("contrast");
        const style = stageStyle("dark", APP_TOKENS.dark) as Record<string, string>;
        expect(style["--stage-bg"]).toBe(STAGE_TOKENS.dark.surfaces["--stage-bg"]);
        expect(style["--status-fail"]).toBe(APP_TOKENS.dark.text["--status-fail"]);
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
        expect(toHash(DEFAULT_VIEW)).toBe("#/mission");
    });

    it("keeps the session in focus and the replay's moment in the address, and opens the kiosk from it", () => {
        const moment = mergeView({ page: "replay", session: "session:7f3a9c21", replay: 33 });
        expect(toHash(moment)).toBe("#/replay?s=session%3A7f3a9c21&r=33");
        expect(mergeView(parseHash(toHash(moment)))).toEqual(moment);
        expect(parseHash("#/kiosk")).toEqual({ page: "kiosk" });
        expect(parseHash("#/scoreboard?s=<script>").session).toBeUndefined();
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
        const inventory = liveDataOf(answers.inventory);
        const rows = liveSecurityRows(liveDataOf(answers.security), inventory);
        expect(rows.map((r) => `${r.attention}|${r.target}|${r.area}`)).toEqual([
            "Needs attention|T3|Auditing",
            "Needs attention|T3|Customer-managed keys",
            "Recommended|T3|Ledger",
            "Recommended|T4|Customer-managed keys",
            "Recommended|T4-replica|Customer-managed keys",
        ]);
        // Live, 2026-11-18: neither T1 nor T2 has a license finding, and a ready assessment isn't an issue.
        expect(liveOptimizationRows(inventory)).toEqual([]);
        expect(inventoryMix(inventory)).toBe("2 PostgreSQL · 1 Arc SQL · 1 Azure SQL · 1 SQL VM · 1 Cosmos DB");
        expect(inventoryMix(inventory, true)).toMatch(/^2 Azure Database for PostgreSQL, 1 Arc-enabled SQL Server, /);
        expect(liveSecurityRows(null, null)).toEqual([]);
        expect(flagText("hasUsageReportingIssue")).toBe("Usage reporting to Azure needs attention");
    });

    it("counts a SQL Server on an Azure VM once, though Database Hub lists its VM and its instance (live, 2026-11-18)", () => {
        const vm = { databaseType: "AzureSqlVM", name: "sqlvm01", resourceGroup: "rg-x", location: "westus3" };
        const inventory: InventoryData = {
            totalCount: 3,
            countByType: { AzureSqlVM: 2, AzureSql: 1 },
            complete: true,
            resources: [
                { ...vm, status: "Unknown", issues: { optimization: { hasPaygLicenseIssue: true, hasLowComputeUtilizationIssue: false } } },
                { ...vm, resourceGroup: "RG-X", status: "Connected", issues: { optimization: { hasLowComputeUtilizationIssue: true } } },
                { databaseType: "AzureSql", name: "ContosoCare", resourceGroup: "rg-x", location: "westus3", status: "Online" },
            ],
        };
        const unique = uniqueInventory(inventory);
        expect(unique.totalCount).toBe(2);
        expect(unique.countByType).toEqual({ AzureSqlVM: 1, AzureSql: 1 });
        expect(unique.resources[0]).toMatchObject({ status: "Connected", issues: { optimization: { hasPaygLicenseIssue: true, hasLowComputeUtilizationIssue: true } } });
        expect(liveOptimizationRows(inventory).map((r) => `${r.target}|${r.area}|${r.check}`)).toEqual(["T1|Licensing|Pay-as-you-go SQL Server license: a license-model opportunity", "T1|Sizing|Low compute use: it may be oversized"]);
        expect([isDown("Unknown"), isDown(undefined), isDown("Connected"), isDown("Stopped")]).toEqual([false, false, false, true]);
    });

    it("reads T2's migration assessment: readiness per Azure SQL target in Learn's words, ready ones named first", () => {
        const [t2] = liveMigrations(liveDataOf(sampleLiveAnswers("2026-10-21T21:00:00.000Z").inventory));
        expect(t2).toMatchObject({ resource: "arcsql01", target: "T2", type: "Arc-enabled SQL Server", enabled: true, dataStatus: "Available", hasResults: true });
        expect(t2.uploadedAt?.toISOString()).toBe("2026-10-21T18:00:00.000Z");
        expect(t2.rows.map((r) => `${r.azureTarget}: ${r.readiness}`)).toEqual(["Azure SQL Managed Instance: Ready", "SQL Server on Azure Virtual Machines: Ready", "Azure SQL Database: Not ready"]);
        expect(migrationSentence(t2)).toBe("Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database.");
        expect(migrationSentence({ ready: [], notReady: ["Azure SQL Database"] })).toBe("Not ready for Azure SQL Database.");
        expect([readinessText("NotReady"), readinessText("Unknown"), readinessText("ReadyWithConditions")]).toEqual(["Not ready", "Unknown", "Ready With Conditions"]);
        const none = liveMigrations({ totalCount: 1, countByType: {}, complete: true, resources: [{ databaseType: "ArcSqlServer", name: "arcsql01", resourceGroup: "rg-x", location: "westus3", status: "Connected", migrationAssessment: { enabled: true, uploadedAt: null, dataStatus: "Unavailable", targets: { azureSqlDatabase: "Unknown" }, readyTargets: [] } }] });
        expect(none[0]).toMatchObject({ hasResults: false, ready: [], uploadedAt: null });
    });

    it("reads T2's assessment saved at deploy: Azure's words, checked field by field, with the recommended tier and size (R924)", () => {
        const deployed = parseDeployedMigration({
            resource: "arcsql01",
            readAt: "2026-11-19T22:10:00Z",
            enabled: true,
            uploadedAt: "2026-11-17T23:05:00Z",
            targets: { azureSqlDatabase: "NotReady", azureSqlManagedInstance: "Ready", azureSqlVirtualMachine: "Ready", "bad key": "Ready", other: "<b>Ready</b>" },
            recommended: { azureSqlManagedInstance: "General Purpose, 4 vCores", azureSqlDatabase: "x".repeat(80) },
            extra: "left out",
        });
        expect(deployed).toEqual({
            resource: "arcsql01",
            readAt: "2026-11-19T22:10:00Z",
            enabled: true,
            uploadedAt: "2026-11-17T23:05:00Z",
            targets: { azureSqlDatabase: "NotReady", azureSqlManagedInstance: "Ready", azureSqlVirtualMachine: "Ready" },
            recommended: { azureSqlManagedInstance: "General Purpose, 4 vCores" },
        });
        if (!deployed) throw new Error("The deploy's shape parses.");
        const t2 = savedMigration(deployed);
        expect(t2).toMatchObject({ resource: "arcsql01", target: "T2", type: "Arc-enabled SQL Server", enabled: true, hasResults: true });
        expect(t2.uploadedAt?.toISOString()).toBe("2026-11-17T23:05:00.000Z");
        expect(t2.rows.map((r) => `${r.azureTarget}: ${r.readiness}${r.recommended ? ` (${r.recommended})` : ""}`)).toEqual([
            "Azure SQL Managed Instance: Ready (General Purpose, 4 vCores)",
            "SQL Server on Azure Virtual Machines: Ready",
            "Azure SQL Database: Not ready",
        ]);
        expect(migrationSentence(t2)).toBe("Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database.");
        expect(savedMigration({ ...deployed, targets: { azureSqlDatabase: "Unknown" } }).hasResults).toBe(false);
        expect([null, "arcsql01", { resource: "arcsql01" }, { resource: "../arcsql01", readAt: "2026-11-19T22:10:00Z" }, { resource: "arcsql01", readAt: "yesterday" }].map(parseDeployedMigration)).toEqual([undefined, undefined, undefined, undefined, undefined]);
    });
});

describe("the live estate when Database Hub refuses the app (R924)", () => {
    const scope = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-dbhub-demo"] };
    // Built at run time so secret scanners never see a token-shaped literal.
    const token = ["eyJ", "x".repeat(24)].join("");
    /** Database Hub answering each route with a status: its body for a refusal is the one it gave the app on 2026-11-19. */
    function dbHub(statusOf: (route: string) => number) {
        const routes: string[] = [];
        const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
            const route = `${init.method ?? "GET"} ${new URL(url).pathname.replace(new URL(DBHUB_BASE).pathname, "")}`;
            routes.push(route);
            const status = statusOf(route);
            if (status === 200) return new Response(JSON.stringify({ items: [], hasMore: false, resources: [] }), { status });
            return new Response(JSON.stringify({ code: "Unauthorized", subCode: 1, message: "Authentication failed for all authenticators", httpStatusCode: status }), { status });
        });
        return { routes, fetchImpl };
    }

    it("says in one plain sentence that Database Hub refused the app, keeps each route's reason for the log, and still calls every route", async () => {
        const { routes, fetchImpl } = dbHub((route) => (route === "GET /auditing/warnings" ? 403 : 401));
        const answers = await Promise.all((["inventory", "health", "security"] as const).map((view) => readEstate(view, scope, token, fetchImpl)));
        for (const answer of answers) {
            expect(answer.unavailable).toBe(LIVE_REFUSED);
            expect(answer.data).toEqual({});
            expect(liveDataOf(answer)).toBeNull();
            expect(answer.errors).toHaveLength(answer.source.length);
            expect(answer.errors.join(" ")).not.toContain(token);
        }
        expect(new Set(routes)).toEqual(new Set(["POST /savedView/resources/list", "POST /health/v2/filtered-summary", "POST /postgreSql/health/v2/summary", "POST /cosmosDb/health/summary", "GET /auth/warnings", "GET /auditing/warnings", "GET /cmk/warnings"]));
        expect(answers[0].errors[0]).toMatch(/^POST \/savedView\/resources\/list: HTTP 401 .*Authentication failed for all authenticators/);
        expect(answers[2].errors).toContainEqual(expect.stringMatching(/^GET \/auditing\/warnings: HTTP 403 /));
        expect(LIVE_REFUSED).not.toMatch(/40[13]|HTTP|token|authenticat/i);
    });

    it("leaves the sentence out when Database Hub didn't answer for another reason, and keeps a partial answer's data with its failed routes by name only", async () => {
        const down = await readEstate("health", scope, token, dbHub(() => 503).fetchImpl);
        expect(down.data).toEqual({});
        expect(down.unavailable).toBeUndefined();
        expect(down.errors[0]).toMatch(/^POST \/[\w/.-]+: HTTP 503 /);
        expect(await readEstate("security", scope, token, dbHub((route) => (route === "GET /auth/warnings" ? 401 : 500)).fetchImpl)).not.toHaveProperty("unavailable");
        expect((await readEstate("inventory", { subscriptionId: "", resourceGroups: [] }, token, dbHub(() => 200).fetchImpl)).unavailable).toBe(LIVE_NO_SCOPE);

        const partial = await readEstate("security", scope, token, dbHub((route) => (route === "GET /auth/warnings" ? 200 : 401)).fetchImpl);
        expect(partial.unavailable).toBeUndefined();
        expect(liveDataOf(partial)?.authentication).toMatchObject({ warningCount: 0, complete: true });
        expect(partial.errors).toHaveLength(2);
        expect(liveRoutes(partial.source, partial.errors)).toEqual({ called: ["GET /auth/warnings", "GET /auditing/warnings", "GET /cmk/warnings"], failed: ["GET /auditing/warnings", "GET /cmk/warnings"] });
        expect(liveRouteLines(partial.source, partial.errors)).toBe("GET /auth/warnings\nGET /auditing/warnings  (didn't answer)\nGET /cmk/warnings  (didn't answer)");
    });
});
