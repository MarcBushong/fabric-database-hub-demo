// Turns Database Hub's live answers into the app's rows: each security warning, and each check Database Hub flags on a
// resource (its issues need attention; its enhancements are recommendations), named with the demo's targets.

import type { FlagCategory, FlagGroups, InventoryData, LiveResource, SecurityData } from "@/data/live-estate";

/** Database Hub's flag names, as a DBA reads them, and the area each belongs to. */
const FLAGS: Record<string, { text: string; area: string }> = {
    hasPublicNetworkAccessIssue: { text: "Public network access is on", area: "Network" },
    hasPrivateEndpointIssue: { text: "No private endpoint", area: "Network" },
    hasTdeIssue: { text: "Transparent data encryption is off", area: "Encryption" },
    hasMinimumTlsBelow12Issue: { text: "Minimum TLS version is below 1.2", area: "Encryption" },
    hasEntraAuthenticationIssue: { text: "Microsoft Entra authentication isn't set up", area: "Authentication" },
    hasEntraOnlyAuthenticationIssue: { text: "Not Microsoft Entra-only authentication", area: "Authentication" },
    hasCmkIssue: { text: "No customer-managed key", area: "Customer-managed keys" },
    hasLedgerIssue: { text: "Ledger is off", area: "Ledger" },
    hasPaygLicenseIssue: { text: "Pay-as-you-go SQL Server license: a license-model opportunity", area: "Licensing" },
    hasUsageReportingIssue: { text: "Usage reporting to Azure needs attention", area: "Licensing" },
    hasMigrationAssessmentIssue: { text: "The migration assessment needs attention", area: "Migration" },
    hasHighComputeUtilizationIssue: { text: "High compute use", area: "Sizing" },
    hasHighMemoryUtilizationIssue: { text: "High memory use", area: "Sizing" },
    hasHighStorageUtilizationIssue: { text: "High storage use", area: "Sizing" },
    hasLowComputeUtilizationIssue: { text: "Low compute use: it may be oversized", area: "Sizing" },
    hasLowMemoryUtilizationIssue: { text: "Low memory use", area: "Sizing" },
    hasLowStorageUtilizationIssue: { text: "Low storage use", area: "Sizing" },
};

const CATEGORY_AREA: Record<FlagCategory, string> = { security: "Security", performance: "Performance", optimization: "Optimization" };

const TYPE_TEXT: Record<string, string> = {
    AzureSql: "Azure SQL Database",
    AzureSqlVM: "SQL Server on an Azure VM",
    ArcSql: "Arc-enabled SQL Server",
    ArcSqlServer: "Arc-enabled SQL Server",
    SqlServerArc: "Arc-enabled SQL Server",
    PostgreSql: "Azure Database for PostgreSQL",
    CosmosDb: "Azure Cosmos DB",
};

export function flagText(flag: string): string {
    const known = FLAGS[flag]?.text;
    if (known) return known;
    const words = flag.replace(/^has/, "").replace(/Issue$/, "").replace(/([a-z0-9])([A-Z])/g, "$1 $2").trim().toLowerCase();
    return words ? words.charAt(0).toUpperCase() + words.slice(1) : flag;
}

export function typeText(type: string): string {
    return TYPE_TEXT[type] ?? type.replace(/([a-z])([A-Z])/g, "$1 $2");
}

/** The demo's target a live resource is, from the names deploy.ps1 gives them; "" for anything else. */
export function targetOfResource(resource: Pick<LiveResource, "name" | "databaseType">, serverName?: string): string {
    const name = `${serverName ?? ""} ${resource.name}`.toLowerCase();
    if (/\bpgreplica01/.test(name)) return "T4-replica";
    if (/\bpgflex01/.test(name)) return "T4";
    if (/\bcosmos01/.test(name)) return "T5";
    if (/\barcsql01/.test(name)) return "T2";
    if (/\bsqlvm01/.test(name)) return "T1";
    if (/\bazuresql01/.test(name) || resource.databaseType === "AzureSql") return "T3";
    return "";
}

export interface LiveCheckRow extends Record<string, unknown> {
    id: string;
    /** A security view's warning, a resource's issue, or one of its enhancements. */
    kind: "warning" | "issue" | "enhancement";
    attention: "Needs attention" | "Recommended";
    area: string;
    check: string;
    resource: string;
    type: string;
    target: string;
}

const SECURITY_AREAS = [
    ["authentication", "Authentication"],
    ["auditing", "Auditing"],
    ["customerManagedKeys", "Customer-managed keys"],
] as const;

const NO_STATUS = /^\s*(unknown)?\s*$/i;

function mergeFlags(a: FlagGroups | undefined, b: FlagGroups | undefined): FlagGroups | undefined {
    if (!a) return b;
    if (!b) return a;
    const out: FlagGroups = {};
    for (const category of new Set([...Object.keys(a), ...Object.keys(b)]) as Set<FlagCategory>) {
        const merged: Record<string, boolean> = { ...(a[category] ?? {}) };
        for (const [flag, on] of Object.entries(b[category] ?? {})) merged[flag] = merged[flag] === true || on === true;
        out[category] = merged;
    }
    return out;
}

/**
 * One row per resource. Database Hub's inventory lists a SQL Server on an Azure VM twice, as the SQL virtual machine and
 * as its SQL Server instance from unified inventory, with the same type and name (live, 2026-11-18): they're one
 * resource here, with the status that's known and every flag either row raises.
 */
export function uniqueResources(resources: readonly LiveResource[]): LiveResource[] {
    const byKey = new Map<string, LiveResource>();
    for (const r of resources) {
        const key = `${r.databaseType}|${(r.resourceGroup ?? "").toLowerCase()}|${r.name.toLowerCase()}`;
        const seen = byKey.get(key);
        if (!seen) {
            byKey.set(key, r);
            continue;
        }
        byKey.set(key, {
            ...seen,
            status: seen.status && !NO_STATUS.test(seen.status) ? seen.status : (r.status ?? seen.status),
            issues: mergeFlags(seen.issues, r.issues),
            enhancements: mergeFlags(seen.enhancements, r.enhancements),
            migrationAssessment: seen.migrationAssessment ?? r.migrationAssessment,
        });
    }
    return [...byKey.values()];
}

/** The inventory with one row per resource, and its counts from those rows. */
export function uniqueInventory(inventory: InventoryData): InventoryData {
    const resources = uniqueResources(inventory.resources);
    if (resources.length === inventory.resources.length) return inventory;
    const countByType: Record<string, number> = {};
    for (const r of resources) countByType[r.databaseType] = (countByType[r.databaseType] ?? 0) + 1;
    return { ...inventory, resources, countByType, totalCount: inventory.totalCount - (inventory.resources.length - resources.length) };
}

/** A status that says the resource isn't up. "Unknown", or none, says nothing either way. */
export function isDown(status: string | undefined): boolean {
    return !!status && !NO_STATUS.test(status) && !/^(online|ready|connected|running|succeeded|available)$/i.test(status);
}

function flagRows(inventory: InventoryData | null | undefined, category: FlagCategory): LiveCheckRow[] {
    const rows: LiveCheckRow[] = [];
    for (const resource of uniqueResources(inventory?.resources ?? [])) {
        for (const [kind, groups] of [["issue", resource.issues], ["enhancement", resource.enhancements]] as const) {
            for (const [flag, on] of Object.entries(groups?.[category] ?? {})) {
                if (on !== true) continue;
                rows.push({
                    id: `${kind}:${resource.databaseType}/${resource.name}:${flag}`,
                    kind,
                    attention: kind === "issue" ? "Needs attention" : "Recommended",
                    area: FLAGS[flag]?.area ?? CATEGORY_AREA[category],
                    check: flagText(flag),
                    resource: resource.name,
                    type: typeText(resource.databaseType),
                    target: targetOfResource(resource),
                });
            }
        }
    }
    return rows;
}

const byAttention = (a: LiveCheckRow, b: LiveCheckRow) =>
    (a.attention === b.attention ? 0 : a.attention === "Needs attention" ? -1 : 1) || a.target.localeCompare(b.target) || a.area.localeCompare(b.area) || a.check.localeCompare(b.check);

/**
 * Every live security check: the Security view's warnings (authentication, auditing, customer-managed keys), then the
 * inventory's security flags that don't repeat one of them for the same resource and area.
 */
export function liveSecurityRows(security: SecurityData | null | undefined, inventory: InventoryData | null | undefined): LiveCheckRow[] {
    const warnings: LiveCheckRow[] = [];
    for (const [key, area] of SECURITY_AREAS) {
        for (const w of security?.[key]?.warnings ?? []) {
            warnings.push({
                id: `warning:${key}:${w.serverName ?? ""}/${w.name}`,
                kind: "warning",
                attention: "Needs attention",
                area,
                check: w.reason || `${area} needs attention`,
                resource: w.serverName ? `${w.serverName}/${w.name}` : w.name,
                type: typeText(w.type),
                target: targetOfResource({ name: w.name, databaseType: w.type }, w.serverName),
            });
        }
    }
    const warned = new Set(warnings.map((w) => `${w.area}|${w.resource.split("/").pop()}`));
    const flags = flagRows(inventory, "security").filter((r) => !warned.has(`${r.area}|${r.resource}`));
    return [...warnings, ...flags].sort(byAttention);
}

/** The inventory's optimization flags: license-model opportunities and sizing. */
export function liveOptimizationRows(inventory: InventoryData | null | undefined): LiveCheckRow[] {
    return flagRows(inventory, "optimization").sort(byAttention);
}

const SHORT_TYPE: Record<string, string> = { AzureSql: "Azure SQL", AzureSqlVM: "SQL VM", ArcSql: "Arc SQL", ArcSqlServer: "Arc SQL", SqlServerArc: "Arc SQL", PostgreSql: "PostgreSQL", CosmosDb: "Cosmos DB" };

/** "2 PostgreSQL · 1 Arc SQL · …", largest first, one per resource; `long` spells each type out. */
export function inventoryMix(inventory: InventoryData | null | undefined, long = false): string {
    return Object.entries(inventory ? uniqueInventory(inventory).countByType : {})
        .filter(([, n]) => n > 0)
        .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
        .map(([type, n]) => `${n} ${long ? typeText(type) : (SHORT_TYPE[type] ?? typeText(type))}`)
        .join(long ? ", " : " \u00b7 ");
}

/** A migration assessment's Azure SQL targets, as Learn names them, in Learn's order (migration-assessment). */
const MIGRATION_TARGETS: ReadonlyArray<readonly [string, string]> = [
    ["azureSqlManagedInstance", "Azure SQL Managed Instance"],
    ["azureSqlVirtualMachine", "SQL Server on Azure Virtual Machines"],
    ["azureSqlDatabase", "Azure SQL Database"],
];

/** Learn's readiness words: Ready, Not ready, and Unknown. */
export function readinessText(value: string): string {
    const plain = value.replace(/[\s_-]/g, "").toLowerCase();
    if (plain === "ready") return "Ready";
    if (plain === "notready") return "Not ready";
    if (plain === "" || plain === "unknown") return "Unknown";
    return value.replace(/([a-z])([A-Z])/g, "$1 $2");
}

export interface MigrationTargetRow extends Record<string, unknown> {
    id: string;
    resource: string;
    target: string;
    azureTarget: string;
    readiness: string;
}

export interface LiveMigration {
    resource: string;
    /** The demo's target: T2 for arcsql01. */
    target: string;
    type: string;
    enabled: boolean;
    uploadedAt: Date | null;
    /** "Available", "Stale", or "Unavailable", as Database Hub says it. */
    dataStatus: string;
    /** Results to show: an available or stale assessment with a readiness for at least one target. */
    hasResults: boolean;
    rows: MigrationTargetRow[];
    ready: string[];
    notReady: string[];
}

function joinAnd(items: readonly string[]): string {
    if (items.length <= 1) return items.join("");
    if (items.length === 2) return `${items[0]} and ${items[1]}`;
    return `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`;
}

/** Every migration assessment in the inventory, T2's first: its readiness per Azure SQL target, in Learn's words. */
export function liveMigrations(inventory: InventoryData | null | undefined): LiveMigration[] {
    const out: LiveMigration[] = [];
    for (const r of uniqueResources(inventory?.resources ?? [])) {
        const a = r.migrationAssessment;
        if (!a) continue;
        const known = new Map(MIGRATION_TARGETS);
        const keys = [...MIGRATION_TARGETS.map(([key]) => key).filter((key) => key in (a.targets ?? {})), ...Object.keys(a.targets ?? {}).filter((key) => !known.has(key))];
        const target = targetOfResource(r);
        const rows = keys.map((key) => ({
            id: `${r.name}:${key}`,
            resource: r.name,
            target,
            azureTarget: known.get(key) ?? typeText(key.charAt(0).toUpperCase() + key.slice(1)),
            readiness: readinessText(String(a.targets[key] ?? "")),
        }));
        const uploaded = a.uploadedAt ? new Date(a.uploadedAt) : null;
        const status = a.dataStatus || "Unknown";
        out.push({
            resource: r.name,
            target,
            type: typeText(r.databaseType),
            enabled: a.enabled,
            uploadedAt: uploaded && !Number.isNaN(uploaded.getTime()) ? uploaded : null,
            dataStatus: status,
            hasResults: /^(available|stale)$/i.test(status) && rows.some((row) => row.readiness !== "Unknown"),
            rows,
            ready: rows.filter((row) => row.readiness === "Ready").map((row) => row.azureTarget),
            notReady: rows.filter((row) => row.readiness === "Not ready").map((row) => row.azureTarget),
        });
    }
    return out.sort((a, b) => Number(b.target === "T2") - Number(a.target === "T2") || a.resource.localeCompare(b.resource));
}

/** "Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database." */
export function migrationSentence(m: Pick<LiveMigration, "ready" | "notReady">): string {
    const parts = [m.ready.length ? `Ready for ${joinAnd(m.ready)}` : "", m.notReady.length ? `${m.ready.length ? "not" : "Not"} ready for ${joinAnd(m.notReady)}` : ""].filter(Boolean);
    return parts.length ? `${parts.join("; ")}.` : "No Azure SQL target's readiness is known yet.";
}
