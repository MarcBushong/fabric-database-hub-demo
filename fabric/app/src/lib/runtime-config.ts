import { resolveRayfinConfig } from "@microsoft/rayfin-client";

/** Links to the live surfaces, written at deploy time from IDs that are never committed. */
export interface AppLinks {
    databaseHub?: string;
    realTimeDashboard?: string;
    report?: string;
    workspace?: string;
    /** The control notebook NB_DatabaseHub_Control, in its own workspace: Run all runs a whole session. */
    controlNotebook?: string;
    /** T2's SQL Server instance enabled by Azure Arc in the Azure portal, from its resource ID: its migration assessment. */
    t2MigrationAssessment?: string;
}

/**
 * T2's migration assessment as Azure Resource Manager had it when configure-fabric-app.ps1 last deployed the app
 * (R924): properties.migration.assessment of T2's SQL Server instance enabled by Azure Arc, a documented read. The
 * migration card shows it, with its time, when Database Hub isn't read live.
 */
export interface DeployedMigration {
    /** T2's SQL Server instance resource (arcsql01). */
    resource: string;
    /** When the deploy read it. */
    readAt: string;
    enabled: boolean;
    /** When the instance last uploaded its assessment, or null. */
    uploadedAt: string | null;
    /** Readiness per Azure SQL target, with Azure's names and values (azureSqlManagedInstance: "Ready"). */
    targets: Record<string, string>;
    /** The recommended service tier and size per target, when the assessment names one ("GeneralPurpose, 4 vCores"). */
    recommended: Record<string, string>;
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
    /** T2's migration assessment, read from Azure at deploy time (R924). */
    t2Migration?: DeployedMigration;
}

interface DeployFile {
    expectedAccount?: unknown;
    expectedTenantId?: unknown;
    resourceGroup?: unknown;
    links?: Record<string, unknown>;
    t2Migration?: unknown;
}

const RESOURCE_GROUP = /^[\w.()-]{1,90}$/;
const ARC_INSTANCE = /^[A-Za-z0-9._-]{1,128}$/;
const TARGET_KEY = /^[A-Za-z]{1,64}$/;
const READINESS = /^[A-Za-z][A-Za-z ]{0,31}$/;
const RECOMMENDED = /^[\w][\w ,.()-]{0,63}$/;

function text(value: unknown): string | undefined {
    return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function isoTime(value: unknown): string | undefined {
    const t = text(value);
    return t && /^\d{4}-\d{2}-\d{2}T/.test(t) && !Number.isNaN(new Date(t).getTime()) ? t : undefined;
}

/** A bounded map of target names to short words, as the deploy wrote it; anything else is left out. */
function wordMap(value: unknown, pattern: RegExp): Record<string, string> {
    const out: Record<string, string> = {};
    if (!value || typeof value !== "object" || Array.isArray(value)) return out;
    for (const [key, raw] of Object.entries(value as Record<string, unknown>).slice(0, 8)) {
        const word = text(raw);
        if (TARGET_KEY.test(key) && word && pattern.test(word)) out[key] = word;
    }
    return out;
}

/** dbhub-app.json's t2Migration, checked field by field; undefined when it's absent or not what the deploy writes. */
export function parseDeployedMigration(value: unknown): DeployedMigration | undefined {
    if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
    const v = value as Record<string, unknown>;
    const resource = text(v.resource);
    const readAt = isoTime(v.readAt);
    if (!resource || !ARC_INSTANCE.test(resource) || !readAt) return undefined;
    return {
        resource,
        readAt,
        enabled: v.enabled === true,
        uploadedAt: isoTime(v.uploadedAt) ?? null,
        targets: wordMap(v.targets, READINESS),
        recommended: wordMap(v.recommended, RECOMMENDED),
    };
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
    for (const key of ["databaseHub", "realTimeDashboard", "report", "workspace", "controlNotebook"] as const) {
        const value = text(deploy?.links?.[key]);
        if (value && /^https:\/\//i.test(value)) links[key] = value;
    }
    const migration = text(deploy?.links?.t2MigrationAssessment);
    if (migration && /^https:\/\/portal\.azure\.com\/#@[\w.-]+\/resource\/subscriptions\//i.test(migration)) links.t2MigrationAssessment = migration;
    const resourceGroup = text(deploy?.resourceGroup);
    const t2Migration = parseDeployedMigration(deploy?.t2Migration);
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
        ...(t2Migration ? { t2Migration } : {}),
    };
}

/** The Fabric portal page of this app item: the entry point that signs users in without a pop-up. */
export function appItemUrl(portalUrl: string, workspaceId: string, itemId: string, tenantId?: string): string {
    const base = portalUrl.replace(/\/+$/, "");
    const url = `${base}/groups/${encodeURIComponent(workspaceId)}/appbackends/${encodeURIComponent(itemId)}`;
    return tenantId ? `${url}?ctid=${encodeURIComponent(tenantId)}` : url;
}
