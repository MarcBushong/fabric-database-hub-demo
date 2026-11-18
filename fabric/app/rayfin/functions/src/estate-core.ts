// The live estate for the Copilot dock and the app's pages: Database Hub's own view of the demo's resources, read
// with the routes and rules of the GA Database Hub CLI skill (microsoft/skills-for-fabric, skills/databasehub-cli,
// pinned in config/versions.json): read-only, allowlisted, the header x-ms-fabric-skill: databasehub-cli on every
// call, and every answer filtered to the demo's own subscription and resource group. Pure, so it's tested offline.

export interface EstateScope {
    subscriptionId: string;
    resourceGroups: string[];
}

export type EstateView = "inventory" | "health" | "security";

export interface EstateAnswer {
    view: EstateView;
    /** The Database Hub routes that answered, for the dock's "source" view. */
    source: string[];
    scope: { subscriptionId: string; resourceGroups: string[] };
    data: Record<string, unknown>;
    errors: string[];
    at: string;
}

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export const DBHUB_BASE = "https://api.fabric.microsoft.com/v1/databasehub/__private";
const TIMEOUT_MS = 30_000;
const METRICS: Record<string, string> = { "0": "cpu", "1": "storage", "2": "memory", cpu: "cpu", storage: "storage", memory: "memory" };

/** The only routes this function calls: the skill's allowlisted reads. A test keeps every call inside it. */
export const ALLOWED_ROUTES = [
    "POST /savedView/resources/list",
    "POST /health/v2/filtered-summary",
    "POST /health/v2/filtered-usage-details",
    "POST /postgreSql/health/v2/summary",
    "POST /cosmosDb/health/summary",
    "GET /auth/warnings",
    "GET /auditing/warnings",
    "GET /cmk/warnings",
] as const;

class Reader {
    readonly source: string[] = [];
    readonly errors: string[] = [];
    constructor(
        private readonly token: string,
        private readonly fetchImpl: FetchLike,
    ) {}

    async call(method: "GET" | "POST", route: string, body?: unknown, query?: Record<string, string>): Promise<Record<string, unknown> | null> {
        const label = `${method} ${route}`;
        if (!(ALLOWED_ROUTES as readonly string[]).includes(label)) throw new Error(`Route not allowed: ${label}`);
        if (!this.source.includes(label)) this.source.push(label);
        const url = `${DBHUB_BASE}${route}${query ? `?${new URLSearchParams(query).toString()}` : ""}`;
        try {
            const response = await this.fetchImpl(url, {
                method,
                headers: {
                    Authorization: `Bearer ${this.token}`,
                    "x-ms-fabric-skill": "databasehub-cli",
                    ...(body === undefined ? {} : { "Content-Type": "application/json" }),
                },
                body: body === undefined ? undefined : JSON.stringify(body),
                signal: AbortSignal.timeout(TIMEOUT_MS),
            });
            if (!response.ok) {
                const text = (await response.text().catch(() => "")).slice(0, 300).replace(/\s+/g, " ");
                this.errors.push(`${label}: HTTP ${response.status}${text ? ` ${text}` : ""}`);
                return null;
            }
            return (await response.json()) as Record<string, unknown>;
        } catch (err) {
            this.errors.push(`${label}: ${err instanceof Error ? err.message : String(err)}`);
            return null;
        }
    }
}

function filters(scope: EstateScope) {
    return { subscriptionIds: [scope.subscriptionId], resourceGroups: scope.resourceGroups };
}

const lower = (s: string) => s.toLowerCase();

/** True when an ARM resource ID is in the scope's subscription and one of its resource groups. */
export function inScope(resourceId: unknown, scope: EstateScope): boolean {
    if (typeof resourceId !== "string") return false;
    const id = lower(resourceId);
    return scope.resourceGroups.some((rg) => id.startsWith(`/subscriptions/${lower(scope.subscriptionId)}/resourcegroups/${lower(rg)}/`));
}

function window24h(now: Date) {
    const end = new Date(Math.floor(now.getTime() / 3600_000) * 3600_000);
    return { startTime: new Date(end.getTime() - 24 * 3600_000).toISOString(), endTime: end.toISOString() };
}

function usage(summary: Record<string, unknown> | null) {
    if (!summary) return null;
    const high: Record<string, number> = {};
    for (const u of Array.isArray(summary.usageCounts) ? (summary.usageCounts as Array<Record<string, unknown>>) : []) {
        const metric = METRICS[String(u.metricType).toLowerCase()] ?? String(u.metricType);
        if (typeof u.highCount === "number") high[metric] = u.highCount;
    }
    return {
        startTime: summary.startTime,
        endTime: summary.endTime,
        granularity: summary.granularity,
        totalDatabases: summary.totalDatabases,
        highUsage: high,
        performanceIssueSummary: summary.performanceIssueSummary ?? null,
        performanceEnhancementSummary: summary.performanceEnhancementSummary ?? null,
        coverage: summary.coverage ?? null,
        errors: summary.errors ?? [],
    };
}

async function inventory(r: Reader, scope: EstateScope) {
    const resources: Array<Record<string, unknown>> = [];
    let token: unknown = undefined;
    for (let page = 0; page < 5; page++) {
        const body: Record<string, unknown> = { pageSize: 200, overviewFilters: filters(scope) };
        if (token) body.continuationToken = token;
        const res = await r.call("POST", "/savedView/resources/list", body);
        if (!res) break;
        for (const row of Array.isArray(res.resources) ? (res.resources as Array<Record<string, unknown>>) : []) {
            resources.push({
                databaseType: row.databaseType ?? row.type,
                name: row.name,
                resourceGroup: row.resourceGroupName,
                location: row.location,
                sku: row.skuTier ?? row.sku,
                status: row.status,
                issues: row.issues ?? undefined,
                enhancements: row.enhancements ?? undefined,
            });
        }
        token = res.continuationToken;
        if (!token) break;
    }
    const byType: Record<string, number> = {};
    for (const row of resources) byType[String(row.databaseType ?? "unknown")] = (byType[String(row.databaseType ?? "unknown")] ?? 0) + 1;
    return { totalCount: resources.length, countByType: byType, resources, complete: !token };
}

async function health(r: Reader, scope: EstateScope, now: Date) {
    const w = window24h(now);
    const sqlBody = { ...w, granularity: "PT1H", aggregationType: "maximum", overviewFilters: filters(scope), pageSize: 300 };
    const [sql, postgres] = await Promise.all([r.call("POST", "/health/v2/filtered-summary", sqlBody), r.call("POST", "/postgreSql/health/v2/summary", sqlBody)]);
    const sqlUsage = usage(sql);
    const highNamed: Record<string, unknown> = {};
    for (const metric of ["Cpu", "Storage", "Memory"]) {
        if ((sqlUsage?.highUsage[lower(metric)] ?? 0) > 0) {
            const details = await r.call("POST", "/health/v2/filtered-usage-details", { ...w, granularity: "PT1H", aggregationType: "maximum", metricType: metric, usageLevel: "High", overviewFilters: filters(scope), pageSize: 20 });
            if (details) highNamed[lower(metric)] = details.databases ?? [];
        }
    }
    // Cosmos DB: every page, one pinned window; minimum availability and maximum normalized RU across pages.
    let processed = 0;
    let total: unknown = null;
    let withData = 0;
    let minAvailability: number | null = null;
    let maxRu: number | null = null;
    let token: unknown = undefined;
    let pages = 0;
    for (; pages < 10; ) {
        const body: Record<string, unknown> = { ...w, granularity: "PT1H", overviewFilters: filters(scope), pageSize: 300 };
        if (token) body.continuationToken = token;
        const page = await r.call("POST", "/cosmosDb/health/summary", body);
        if (!page) break;
        pages++;
        total = page.totalAccounts ?? total;
        processed += typeof page.processedAccounts === "number" ? page.processedAccounts : 0;
        withData += typeof page.resourcesWithData === "number" ? page.resourcesWithData : 0;
        for (const p of Array.isArray(page.serviceAvailability) ? (page.serviceAvailability as Array<{ value?: number }>) : []) {
            if (typeof p.value === "number") minAvailability = minAvailability === null ? p.value : Math.min(minAvailability, p.value);
        }
        for (const p of Array.isArray(page.normalizedRuConsumption) ? (page.normalizedRuConsumption as Array<{ value?: number }>) : []) {
            if (typeof p.value === "number") maxRu = maxRu === null ? p.value : Math.max(maxRu, p.value);
        }
        token = page.continuationToken;
        if (!token) break;
    }
    return {
        window: { ...w, granularity: "PT1H", aggregation: "maximum" },
        microsoftSql: sqlUsage ? { ...sqlUsage, highUsageResources: highNamed } : null,
        postgreSql: usage(postgres),
        cosmosDb: {
            totalAccounts: total,
            processedAccounts: processed,
            resourcesWithData: withData,
            minimumServiceAvailability: minAvailability,
            maximumNormalizedRu: maxRu,
            pages,
            complete: !token,
            note: "Cosmos DB reports availability and normalized RU only: no CPU, and normalized RU at 100 % shows saturation, not proven throttling.",
        },
    };
}

async function security(r: Reader, scope: EstateScope) {
    const out: Record<string, unknown> = {};
    for (const [area, route, scopeNote] of [
        ["authentication", "/auth/warnings", "Azure SQL + Arc SQL Server"],
        ["auditing", "/auditing/warnings", "Azure SQL only"],
        ["customerManagedKeys", "/cmk/warnings", "Azure SQL only"],
    ] as const) {
        const items: Array<Record<string, unknown>> = [];
        let token: unknown = undefined;
        let complete = false;
        for (let page = 0; page < 5; page++) {
            const query: Record<string, string> = { top: "200" };
            if (token) query.continuationToken = String(token);
            const res = await r.call("GET", route, undefined, query);
            if (!res) break;
            for (const item of Array.isArray(res.items) ? (res.items as Array<Record<string, unknown>>) : []) {
                if (inScope(item.resourceId, scope)) items.push({ name: item.name, type: item.type, serverName: item.serverName, state: item.state ?? item.status, reason: item.reason });
            }
            token = res.continuationToken;
            if (!res.hasMore || !token) {
                complete = true;
                break;
            }
        }
        out[area] = { scope: scopeNote, warnings: items, warningCount: items.length, complete };
    }
    return out;
}

/** One view of the live estate, as Database Hub sees it, filtered to the scope. Never throws: errors come back in `errors`. */
export async function readEstate(view: EstateView, scope: EstateScope, token: string, fetchImpl: FetchLike, now: Date = new Date()): Promise<EstateAnswer> {
    const r = new Reader(token, fetchImpl);
    const scopeOut = { subscriptionId: scope.subscriptionId, resourceGroups: scope.resourceGroups };
    if (!scope.subscriptionId || scope.resourceGroups.length === 0) {
        return { view, source: [], scope: scopeOut, data: {}, errors: ["The estate function has no scope: deploy the app with scripts/configure-fabric-app.ps1."], at: now.toISOString() };
    }
    let data: Record<string, unknown>;
    if (view === "health") data = await health(r, scope, now);
    else if (view === "security") data = await security(r, scope);
    else data = await inventory(r, scope);
    return { view, source: r.source.map((s) => s.replace(" /", ` /v1/databasehub/__private/`)), scope: scopeOut, data, errors: r.errors, at: now.toISOString() };
}
