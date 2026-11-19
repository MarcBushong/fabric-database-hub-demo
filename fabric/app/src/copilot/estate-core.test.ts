import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { ALLOWED_ROUTES, BUDGET_MS, DBHUB_BASE, inScope, readEstate, USER_AGENT, type EstateScope } from "../../rayfin/functions/src/estate-core";

const scope: EstateScope = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-dbhub-demo"] };
const mine = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Sql/servers/s/databases/d";
const theirs = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-other/providers/Microsoft.Sql/servers/s/databases/d";
// Built at run time so secret scanners never see a token-shaped literal.
const token = ["eyJ", "x".repeat(24)].join("");

function fakeDbHub(handlers: Record<string, (body: Record<string, unknown> | null, url: URL) => unknown>) {
    const calls: Array<{ method: string; route: string; body: Record<string, unknown> | null; headers: Record<string, string> }> = [];
    const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
        const u = new URL(url);
        const route = u.pathname.replace(new URL(DBHUB_BASE).pathname, "");
        const body = typeof init.body === "string" ? (JSON.parse(init.body) as Record<string, unknown>) : null;
        calls.push({ method: init.method ?? "GET", route, body, headers: init.headers as Record<string, string> });
        const handler = handlers[`${init.method} ${route}`];
        if (!handler) return new Response("not here", { status: 404 });
        return new Response(JSON.stringify(handler(body, u)), { status: 200 });
    });
    return { calls, fetchImpl };
}

describe("the estate function", () => {
    it("reads the inventory as this app, not as the skill, filtered to the demo's resource group", async () => {
        const { calls, fetchImpl } = fakeDbHub({
            "POST /savedView/resources/list": () => ({ resources: [{ databaseType: "AzureSql", name: "ContosoCare", resourceGroupName: "rg-dbhub-demo" }, { databaseType: "PostgreSql", name: "pgflex01" }] }),
        });
        const answer = await readEstate("inventory", scope, token, fetchImpl, new Date("2026-11-18T12:34:00Z"));
        expect(answer.data).toMatchObject({ totalCount: 2, countByType: { AzureSql: 1, PostgreSql: 1 }, complete: true });
        expect(answer.source).toEqual(["POST /savedView/resources/list"]);
        expect(answer.source.every((s) => (ALLOWED_ROUTES as readonly string[]).includes(s))).toBe(true);
        expect(answer.source.join(" ")).not.toContain(new URL(DBHUB_BASE).pathname);
        expect(calls[0].headers).toMatchObject({ Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT });
        const appVersion = /^version:\s*(\S+)/m.exec(readFileSync(join(process.cwd(), "rayfin", "rayfin.yml"), "utf8"))?.[1];
        expect(USER_AGENT).toBe(`DbHubDemo-InsightsApp/${appVersion}`);
        expect(Object.keys(calls[0].headers).map((h) => h.toLowerCase())).not.toContain("x-ms-fabric-skill");
        expect(calls[0].body).toMatchObject({ overviewFilters: { subscriptionIds: [scope.subscriptionId], resourceGroups: ["rg-dbhub-demo"] } });
        expect(fetchImpl.mock.calls[0][0].startsWith(DBHUB_BASE)).toBe(true);
    });

    it("stops calling routes when the answer's time budget runs out, and says so", async () => {
        const { fetchImpl } = fakeDbHub({ "POST /savedView/resources/list": () => ({ resources: [] }) });
        let ticks = 0;
        const clock = () => (ticks++ === 0 ? 0 : BUDGET_MS);
        const answer = await readEstate("inventory", scope, token, fetchImpl, new Date(), clock);
        expect(fetchImpl).not.toHaveBeenCalled();
        expect(answer.errors[0]).toMatch(/budget ran out/);
    });

    it("reads health across engines in one pinned window, and pages Cosmos DB to the end", async () => {
        let cosmosPage = 0;
        const { calls, fetchImpl } = fakeDbHub({
            "POST /health/v2/filtered-summary": () => ({ totalDatabases: 3, usageCounts: [{ metricType: 0, highCount: 1, lowCount: 2 }, { metricType: 2, highCount: 0 }], series: [1, 2, 3] }),
            "POST /health/v2/filtered-usage-details": (body) => ({ databases: [{ name: "ContosoCare", metric: body?.metricType }] }),
            "POST /postgreSql/health/v2/summary": () => ({ totalDatabases: 1, usageCounts: [{ metricType: "Cpu", highCount: 0 }] }),
            "POST /cosmosDb/health/summary": () => {
                cosmosPage++;
                return cosmosPage === 1
                    ? { totalAccounts: 2, processedAccounts: 1, resourcesWithData: 1, serviceAvailability: [{ value: 99.9 }], normalizedRuConsumption: [{ value: 40 }], continuationToken: "next" }
                    : { totalAccounts: 2, processedAccounts: 1, resourcesWithData: 1, serviceAvailability: [{ value: 99.5 }], normalizedRuConsumption: [{ value: 100 }] };
            },
        });
        const answer = await readEstate("health", scope, token, fetchImpl, new Date("2026-11-18T12:34:00Z"));
        const data = answer.data as Record<string, Record<string, unknown>>;
        expect(data.microsoftSql).toMatchObject({ totalDatabases: 3, highUsage: { cpu: 1, memory: 0 }, highUsageResources: { cpu: [{ name: "ContosoCare", metric: "Cpu" }] } });
        expect(data.microsoftSql).not.toHaveProperty("series");
        expect(data.cosmosDb).toMatchObject({ totalAccounts: 2, processedAccounts: 2, minimumServiceAvailability: 99.5, maximumNormalizedRu: 100, pages: 2, complete: true });
        const windows = calls.map((c) => `${c.body?.startTime}|${c.body?.endTime}`);
        expect(new Set(windows).size).toBe(1);
        expect(windows[0]).toBe("2026-11-17T12:00:00.000Z|2026-11-18T12:00:00.000Z");
        expect(calls.filter((c) => c.route === "/cosmosDb/health/summary")[1].body).toMatchObject({ continuationToken: "next" });
    });

    it("keeps only the demo's own resources from tenant-wide posture warnings", async () => {
        const { fetchImpl } = fakeDbHub({
            "GET /auth/warnings": () => ({ items: [{ name: "mine", resourceId: mine, reason: "SQL authentication on" }, { name: "theirs", resourceId: theirs }], hasMore: false }),
            "GET /auditing/warnings": () => ({ items: [], hasMore: false }),
            "GET /cmk/warnings": () => ({ items: [{ name: "mine", resourceId: mine.toUpperCase().replace("/SUBSCRIPTIONS", "/subscriptions") }], hasMore: false }),
        });
        const answer = await readEstate("security", scope, token, fetchImpl);
        const data = answer.data as Record<string, { warnings: Array<{ name: string }>; scope: string }>;
        expect(data.authentication.warnings.map((w) => w.name)).toEqual(["mine"]);
        expect(data.authentication.scope).toBe("Azure SQL + Arc SQL Server");
        expect(data.customerManagedKeys.warnings).toHaveLength(1);
        expect(JSON.stringify(answer)).not.toContain("theirs");
    });

    it("reports a failing route as an error and still answers the rest", async () => {
        const { fetchImpl } = fakeDbHub({ "POST /savedView/resources/list": () => ({ resources: [] }) });
        const answer = await readEstate("health", scope, token, fetchImpl);
        expect(answer.errors.some((e) => e.includes("HTTP 404"))).toBe(true);
        expect(answer.errors.join(" ")).not.toContain(token);
    });

    it("calls only the skill's allowlisted read routes, and nothing without a scope", async () => {
        const { calls, fetchImpl } = fakeDbHub({});
        for (const view of ["inventory", "health", "security"] as const) await readEstate(view, scope, token, fetchImpl);
        for (const c of calls) expect(ALLOWED_ROUTES).toContain(`${c.method} ${c.route}`);
        const empty = await readEstate("inventory", { subscriptionId: "", resourceGroups: [] }, token, fetchImpl);
        expect(empty.errors[0]).toMatch(/no scope/);
        expect(inScope(theirs, scope)).toBe(false);
        expect(inScope(mine, scope)).toBe(true);
    });
});
