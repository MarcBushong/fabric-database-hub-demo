// The demo's estate: its engines and targets, how the app names them, and where each one's data comes from.

import type { EstateTarget, FilterTarget } from "./view-state";

export type Engine = "sqlserver" | "azuresql" | "postgresql" | "cosmosdb";

export interface TargetInfo {
    key: EstateTarget;
    short: string;
    name: string;
    engine: Engine;
    /** What runs it, in a few words. */
    platform: string;
    /** Where it runs. */
    hosting: string;
    color: string;
    /** The target a replica belongs to. */
    parent?: EstateTarget;
    /** How the history gets its data. */
    source: string;
}

export const TARGETS: Record<EstateTarget, TargetInfo> = {
    T1: {
        key: "T1",
        short: "T1",
        name: "SQL Server on an Azure VM",
        engine: "sqlserver",
        platform: "SQL Server 2022",
        hosting: "Azure virtual machine",
        color: "var(--target-t1)",
        source: "Database Hub's telemetry, saved by NB_DatabaseHub_LiveActivity",
    },
    T2: {
        key: "T2",
        short: "T2",
        name: "Arc-enabled SQL Server",
        engine: "sqlserver",
        platform: "SQL Server 2022",
        hosting: "On-premises guest, through Azure Arc",
        color: "var(--target-t2)",
        source: "Database Hub's telemetry, saved by NB_DatabaseHub_LiveActivity",
    },
    T3: {
        key: "T3",
        short: "T3",
        name: "Azure SQL Database",
        engine: "azuresql",
        platform: "Azure SQL Database",
        hosting: "Azure PaaS",
        color: "var(--target-t3)",
        source: "Database Hub's telemetry, saved by NB_DatabaseHub_LiveActivity",
    },
    T4: {
        key: "T4",
        short: "T4",
        name: "Azure Database for PostgreSQL",
        engine: "postgresql",
        platform: "PostgreSQL flexible server",
        hosting: "Azure PaaS",
        color: "var(--target-t4)",
        source: "Azure Monitor metrics, captured by the demo's scripts at a session's end",
    },
    "T4-replica": {
        key: "T4-replica",
        short: "T4 replica",
        name: "T4's read replica",
        engine: "postgresql",
        platform: "PostgreSQL read replica",
        hosting: "Azure PaaS, during a session",
        color: "var(--target-t4r)",
        parent: "T4",
        source: "Azure Monitor metrics, captured before the session deletes it",
    },
    T5: {
        key: "T5",
        short: "T5",
        name: "Azure Cosmos DB",
        engine: "cosmosdb",
        platform: "Azure Cosmos DB for NoSQL",
        hosting: "Azure PaaS",
        color: "var(--target-t5)",
        source: "Azure Monitor metrics, saved by the demo",
    },
};

export const ENGINES: ReadonlyArray<{ id: Engine; label: string; targets: EstateTarget[] }> = [
    { id: "sqlserver", label: "SQL Server", targets: ["T1", "T2"] },
    { id: "azuresql", label: "Azure SQL Database", targets: ["T3"] },
    { id: "postgresql", label: "PostgreSQL", targets: ["T4", "T4-replica"] },
    { id: "cosmosdb", label: "Azure Cosmos DB", targets: ["T5"] },
];

export function engineOf(target: EstateTarget): { id: Engine; label: string } {
    const engine = ENGINES.find((e) => e.targets.includes(target)) ?? ENGINES[0];
    return { id: engine.id, label: engine.label };
}

/** The filter target a target belongs to (the read replica belongs to T4). */
export function filterTargetOf(target: EstateTarget): FilterTarget {
    return target === "T4-replica" ? "T4" : target;
}

/** The SQL targets among the filter's: the ones the telemetry history covers. */
export function sqlTargets(targets: readonly FilterTarget[]): Array<"T1" | "T2" | "T3"> {
    return targets.filter((t): t is "T1" | "T2" | "T3" => t === "T1" || t === "T2" || t === "T3");
}
