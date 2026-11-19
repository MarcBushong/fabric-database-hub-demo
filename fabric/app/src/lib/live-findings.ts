// Turns Database Hub's live answers into the app's rows: each security warning, and each check Database Hub flags on a
// resource (its issues need attention; its enhancements are recommendations), named with the demo's targets.

import type { FlagCategory, InventoryData, LiveResource, SecurityData } from "@/data/live-estate";

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

function flagRows(inventory: InventoryData | null | undefined, category: FlagCategory): LiveCheckRow[] {
    const rows: LiveCheckRow[] = [];
    for (const resource of inventory?.resources ?? []) {
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

/** "2 PostgreSQL · 1 Arc SQL · …", largest first; `long` spells each type out. */
export function inventoryMix(inventory: InventoryData | null | undefined, long = false): string {
    return Object.entries(inventory?.countByType ?? {})
        .filter(([, n]) => n > 0)
        .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
        .map(([type, n]) => `${n} ${long ? typeText(type) : (SHORT_TYPE[type] ?? typeText(type))}`)
        .join(long ? ", " : " \u00b7 ");
}
