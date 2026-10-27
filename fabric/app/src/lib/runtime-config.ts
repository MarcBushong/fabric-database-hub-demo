import { resolveRayfinConfig } from "@microsoft/rayfin-client";

/** Links to the live surfaces, written at deploy time from IDs that are never committed. */
export interface AppLinks {
    databaseHub?: string;
    realTimeDashboard?: string;
    report?: string;
    workspace?: string;
}

/** Everything the app needs at run time, from rayfin.config.json, the build's VITE_* values, and dbhub-app.json. */
export interface AppRuntime {
    apiUrl: string;
    publishableKey: string;
    workspaceId: string;
    itemId: string;
    portalUrl: string;
    tenantId?: string;
    expectedAccount?: string;
    expectedTenantId?: string;
    /** The demo's resource group, for the Database Agent prompts. */
    resourceGroup?: string;
    links: AppLinks;
}

interface DeployFile {
    expectedAccount?: unknown;
    expectedTenantId?: unknown;
    resourceGroup?: unknown;
    links?: Record<string, unknown>;
}

const RESOURCE_GROUP = /^[\w.()-]{1,90}$/;

function text(value: unknown): string | undefined {
    return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** Reads /dbhub-app.json, which configure-fabric-app.ps1 writes at deploy time; absent in local development. */
export async function loadDeployFile(fetchImpl: typeof fetch = fetch): Promise<DeployFile | null> {
    try {
        const response = await fetchImpl("/dbhub-app.json", { cache: "no-store", credentials: "same-origin" });
        const type = response.headers.get("content-type") ?? "";
        if (!response.ok || !type.includes("json")) return null;
        return (await response.json()) as DeployFile;
    } catch {
        return null;
    }
}

export async function loadAppRuntime(fetchImpl: typeof fetch = fetch): Promise<AppRuntime> {
    const env = import.meta.env;
    const resolved = await resolveRayfinConfig({
        apiUrl: env.VITE_RAYFIN_API_URL,
        publishableKey: env.VITE_RAYFIN_PUBLISHABLE_KEY,
        workspaceId: env.VITE_FABRIC_WORKSPACE_ID,
        itemId: env.VITE_FABRIC_ITEM_ID,
        portalUrl: env.VITE_FABRIC_PORTAL_URL,
        tenantId: env.VITE_FABRIC_TENANT_ID,
    });
    const rc = resolved.runtimeConfig;
    const apiUrl = resolved.baseUrl ?? rc.apiUrl;
    const publishableKey = resolved.publishableKey ?? rc.publishableKey;
    if (!apiUrl || !publishableKey || !rc.workspaceId || !rc.itemId || !rc.portalUrl) {
        throw new Error("This build has no Fabric app settings. Deploy it with scripts/configure-fabric-app.ps1 (npx rayfin up), which writes them.");
    }
    const deploy = await loadDeployFile(fetchImpl);
    const links: AppLinks = {};
    for (const key of ["databaseHub", "realTimeDashboard", "report", "workspace"] as const) {
        const value = text(deploy?.links?.[key]);
        if (value && /^https:\/\//i.test(value)) links[key] = value;
    }
    const resourceGroup = text(deploy?.resourceGroup);
    return {
        apiUrl,
        publishableKey,
        workspaceId: rc.workspaceId,
        itemId: rc.itemId,
        portalUrl: rc.portalUrl,
        tenantId: rc.tenantId,
        expectedAccount: text(deploy?.expectedAccount),
        expectedTenantId: text(deploy?.expectedTenantId) ?? rc.tenantId,
        resourceGroup: resourceGroup && RESOURCE_GROUP.test(resourceGroup) ? resourceGroup : undefined,
        links,
    };
}

/** The Fabric portal page of this app item: the entry point that signs users in without a pop-up. */
export function appItemUrl(portalUrl: string, workspaceId: string, itemId: string, tenantId?: string): string {
    const base = portalUrl.replace(/\/+$/, "");
    const url = `${base}/groups/${encodeURIComponent(workspaceId)}/appbackends/${encodeURIComponent(itemId)}`;
    return tenantId ? `${url}?ctid=${encodeURIComponent(tenantId)}` : url;
}
