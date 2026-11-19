// Sample live answers for the local preview and the tests, shaped like Database Hub's answers through the app's
// function (a real one is in the chat session's evidence). No IDs or names from a real deployment.

import type { EstateAnswer, EstateReader, EstateView } from "../data/live-estate";

const SCOPE = { subscriptionId: "00000000-0000-0000-0000-000000000000", resourceGroups: ["rg-dbhub-sample"] };

export function sampleLiveAnswers(at: string): { [V in EstateView]: EstateAnswer<V> } {
    return {
        inventory: {
            view: "inventory",
            source: ["POST /savedView/resources/list"],
            scope: SCOPE,
            errors: [],
            at,
            data: {
                // As the function counts them: sqlvm01 twice, its SQL virtual machine and its SQL Server instance from
                // unified inventory (live, 2026-11-18). The app shows one row per resource.
                totalCount: 7,
                countByType: { AzureSql: 1, AzureSqlVM: 2, ArcSqlServer: 1, PostgreSql: 2, CosmosDb: 1 },
                complete: true,
                resources: [
                    { databaseType: "AzureSql", name: "ContosoCare", resourceGroup: "rg-dbhub-sample", location: "westus3", status: "Online", issues: { security: { hasPublicNetworkAccessIssue: false, hasTdeIssue: false }, optimization: {} }, enhancements: { security: { hasLedgerIssue: true, hasCmkIssue: true }, optimization: {} } },
                    { databaseType: "AzureSqlVM", name: "sqlvm01", resourceGroup: "rg-dbhub-sample", location: "westus3", status: "Unknown", issues: { security: {}, optimization: { hasPaygLicenseIssue: false } } },
                    { databaseType: "AzureSqlVM", name: "sqlvm01", resourceGroup: "rg-dbhub-sample", location: "westus3", status: "Connected", issues: { security: {}, optimization: {} } },
                    {
                        databaseType: "ArcSqlServer",
                        name: "arcsql01",
                        resourceGroup: "rg-dbhub-sample",
                        location: "westus3",
                        status: "Connected",
                        issues: { security: {}, optimization: { hasMigrationAssessmentIssue: false, hasPaygLicenseIssue: false, hasUsageReportingIssue: false } },
                        // Ready to migrate: Database Hub carries it in the row, not as an issue (live on dbhubal, 2026-11-18).
                        migrationAssessment: {
                            enabled: true,
                            uploadedAt: new Date(Date.parse(at) - 3 * 3600000).toISOString(),
                            dataStatus: "Available",
                            targets: { azureSqlDatabase: "NotReady", azureSqlManagedInstance: "Ready", azureSqlVirtualMachine: "Ready" },
                            readyTargets: ["azureSqlManagedInstance", "azureSqlVirtualMachine"],
                            hasIssue: false,
                        },
                    },
                    { databaseType: "PostgreSql", name: "pgflex01-sample", resourceGroup: "rg-dbhub-sample", location: "westus3", status: "Ready", issues: { security: { hasEntraAuthenticationIssue: false } }, enhancements: { security: { hasCmkIssue: true } } },
                    { databaseType: "PostgreSql", name: "pgreplica01-sample", resourceGroup: "rg-dbhub-sample", location: "westus3", status: "Ready", enhancements: { security: { hasCmkIssue: true } } },
                    { databaseType: "CosmosDb", name: "cosmos01-sample", resourceGroup: "rg-dbhub-sample", location: "westus3", status: "Online" },
                ],
            },
        },
        health: {
            view: "health",
            source: ["POST /health/v2/filtered-summary", "POST /postgreSql/health/v2/summary", "POST /cosmosDb/health/summary"],
            scope: SCOPE,
            errors: [],
            at,
            data: {
                window: { startTime: "2026-11-17T21:00:00Z", endTime: "2026-11-18T21:00:00Z", granularity: "PT1H", aggregation: "maximum" },
                microsoftSql: { totalDatabases: 3, highUsage: { cpu: 1, storage: 0, memory: 0 } },
                postgreSql: { totalDatabases: 2, highUsage: { cpu: 0, storage: 0, memory: 0 } },
                cosmosDb: { totalAccounts: 1, minimumServiceAvailability: 100, maximumNormalizedRu: 100, note: "Cosmos DB reports availability and normalized RU only." },
            },
        },
        security: {
            view: "security",
            source: ["GET /auth/warnings", "GET /auditing/warnings", "GET /cmk/warnings"],
            scope: SCOPE,
            errors: [],
            at,
            data: {
                authentication: { scope: "Azure SQL + Arc SQL Server", warnings: [], warningCount: 0, complete: true },
                auditing: { scope: "Azure SQL only", warnings: [{ name: "ContosoCare", type: "AzureSql", serverName: "azuresql01-sample", reason: "Auditing is disabled" }], warningCount: 1, complete: true },
                customerManagedKeys: { scope: "Azure SQL only", warnings: [{ name: "ContosoCare", type: "AzureSql", serverName: "azuresql01-sample", reason: "CMK is not configured for TDE protector" }], warningCount: 1, complete: true },
            },
        },
    };
}

/** A reader that answers from the sample after a short pause, like the cached function; or rejects, like an app without it. */
export function sampleLiveReader(options: { at: string; delayMs?: number; off?: string }): EstateReader {
    const answers = sampleLiveAnswers(options.at);
    return (view) =>
        new Promise((resolve, reject) => {
            setTimeout(() => (options.off ? reject(new Error(options.off)) : resolve(answers[view] as never)), options.delayMs ?? 0);
        });
}
