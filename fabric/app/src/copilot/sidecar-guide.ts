// The chat's compact guide to Query Store's evidence in the history model: the sidecar's six tables (rca/README.md, The
// sidecar), the columns the chat groups or filters by, their measures, and the rule that reads them. It's written from the
// contract, rca/history-tables.json, which the model's TMDL follows (Fabric.PowerBI checks every table and measure). The
// always-on guide leaves the six tables out (scripts/build-model-guide.ts), where they took about 20,000 of its
// characters; the chat gets this section only when the deployed model has them (CopilotProvider), and explain_queries and
// explain_incident carry what it needs from them.

export interface ContractColumn {
    name: string;
    type: string;
    model: { column: string; hidden?: boolean };
}

export interface ContractTable {
    name: string;
    model: string;
    document: string;
    columns: ContractColumn[];
}

export interface ContractMeasure {
    table: string;
    name: string;
    description: string;
}

/** What the guide reads of rca/history-tables.json. */
export interface HistoryContract {
    tables: ContractTable[];
    measures: ContractMeasure[];
}

interface GuideTable {
    model: string;
    /** What one row is. */
    row: string;
    /** The columns to group or filter by, each with what its name doesn't say. */
    columns: ReadonlyArray<readonly [column: string, note?: string]>;
}

/** Per sidecar table, what a row is and the columns the chat groups or filters by: no hidden column, and no number to sum. */
export const SIDECAR_GUIDE_TABLES: readonly GuideTable[] = [
    {
        model: "RCA Query Stats",
        row: "one plan's statistics over one interval",
        columns: [
            ["Interval Start UTC", "filter minutes on it"],
            ["Interval End UTC"],
            ["Query ID"],
            ["Plan ID", "0 on T4 when it keeps no plans"],
            ["Login", "PostgreSQL's role; blank on SQL Server"],
            ["Module", "[schema].[name]; blank for an ad hoc statement"],
            ["Statement", "normalized"],
        ],
    },
    {
        model: "RCA Query Waits",
        row: "one plan's wait category over one interval, its three largest; no measure: explain_queries totals them",
        columns: [
            ["Interval Start UTC"],
            ["Query ID"],
            ["Plan ID"],
            ["Wait Category", "SQL Server's: Lock, CPU, Buffer IO, Parallelism, ..."],
            ["Wait Event", "PostgreSQL's: transactionid, relation, ..."],
        ],
    },
    {
        model: "RCA Query Plans",
        row: "one plan as one read saw it, T1 to T3",
        columns: [["Query ID"], ["Plan ID"], ["Compiled UTC"], ["Is Forced Plan"], ["Forcing Type", "MANUAL, AUTO, or NONE"], ["Is Parallel"]],
    },
    {
        model: "RCA Query Events",
        row: "one change the capture saw",
        columns: [["Event Time UTC"], ["Kind", "forced, unforced, state, or tuning"], ["State", "after the change"], ["Query ID"], ["Plan ID"], ["Forcing Type"]],
    },
    {
        model: "RCA Query Coverage",
        row: "what the capture read of Query Store, and what it couldn't",
        columns: [
            ["Window Start UTC"],
            ["Window End UTC"],
            ["Query Store State"],
            ["Read From UTC"],
            ["Read To UTC"],
            ["Pending From UTC", "T4's minutes not yet published when read"],
            ["Pending To UTC"],
            ["Gaps", "one per line, each with why"],
        ],
    },
    {
        model: "RCA Connections",
        row: "one group of T4's connections in one sample",
        columns: [["Captured At UTC", "the sample"], ["Program"], ["Login"], ["State", "active, idle, idle in transaction, ..."]],
    },
];

/** The sidecar's tables by their model names: the contract's tables of the document "sidecar". */
export function sidecarModelTables(contract: Pick<HistoryContract, "tables">): string[] {
    return contract.tables.filter((t) => t.document === "sidecar").map((t) => t.model);
}

/** What in the contract the guide's tables and columns don't match: a table or column gone, renamed, or hidden. */
export function sidecarGuideProblems(contract: HistoryContract, guide: readonly GuideTable[] = SIDECAR_GUIDE_TABLES): string[] {
    const problems: string[] = [];
    const tables = contract.tables.filter((t) => t.document === "sidecar");
    for (const t of tables) if (!guide.some((g) => g.model === t.model)) problems.push(`'${t.model}' is a sidecar table the guide doesn't describe.`);
    for (const g of guide) {
        const table = tables.find((t) => t.model === g.model);
        if (!table) {
            problems.push(`'${g.model}' isn't a sidecar table in the contract.`);
            continue;
        }
        for (const [column] of g.columns) {
            const c = table.columns.find((x) => x.model.column === column);
            if (!c) problems.push(`'${g.model}'[${column}] isn't in the contract.`);
            else if (c.model.hidden) problems.push(`'${g.model}'[${column}] is hidden in the model.`);
        }
    }
    return problems;
}

/** The section the chat gets when the model has the sidecar's tables. It throws when the contract and the guide's tables differ. */
export function formatSidecarGuide(contract: HistoryContract, guide: readonly GuideTable[] = SIDECAR_GUIDE_TABLES): string {
    const problems = sidecarGuideProblems(contract, guide);
    if (problems.length > 0) throw new Error(`The sidecar's guide doesn't match rca/history-tables.json. Change src/copilot/sidecar-guide.ts:\n- ${problems.join("\n- ")}`);
    const tables = sidecarModelTables(contract);
    const measures = contract.measures.filter((m) => tables.includes(m.table));
    return [
        "## Query Store's evidence (the sidecar's tables)",
        "What the capture read of Query Store on T1 to T4, by Query Store's 15-minute intervals, and of T4's client connections in a connection episode: six tables, related to 'Target' and 'Date' as the others are. The capture reads an interval more than once, and two sessions can each read it, so a table holds several reads of one interval: use these measures, which take each interval's latest read, and never sum the tables' numeric columns. explain_queries reads them with its rules (the top queries, plan changes, forcings, and waits by category, against the hour before): call it first, and run_dax for what it doesn't answer. T4's query IDs are 64-bit, past what a number holds exactly: return them as text, CONVERT ( 'RCA Query Stats'[Query ID], STRING ).",
        "Measures:",
        ...measures.map((m) => `- [${m.name}] on '${m.table}': ${m.description}`),
        "An interval counts for some minutes when it overlaps them. T3's top queries by CPU in them:",
        `EVALUATE TOPN ( 10, SUMMARIZECOLUMNS ( 'RCA Query Stats'[Query ID], 'RCA Query Stats'[Module], TREATAS ( { "T3" }, 'Target'[Target Key] ), FILTER ( ALL ( 'RCA Query Stats'[Interval Start UTC], 'RCA Query Stats'[Interval End UTC] ), 'RCA Query Stats'[Interval Start UTC] < <to> && 'RCA Query Stats'[Interval End UTC] > <from> ), "CpuMs", [Query CPU (ms)], "Executions", [Query Executions] ), [CpuMs], DESC )`,
        "Columns to group or filter by:",
        ...guide.map((g) => `- '${g.model}', ${g.row}: ${g.columns.map(([c, note]) => `[${c}]${note ? ` (${note})` : ""}`).join(", ")}.`),
    ].join("\n");
}
