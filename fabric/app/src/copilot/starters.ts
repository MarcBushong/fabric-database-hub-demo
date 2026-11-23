// The dock's starter questions: the DBA questions from the prompt pack (fabric/agent/prompts), phrased for this
// app's two sources, the live estate and the history. The same starters work in every session and every
// environment, so a demo can be rehearsed and repeated. They're blind (ADR 0031): none names what the demo injects.

import { INVESTIGATION_STARTERS } from "@/rca/starters";

export interface Starter {
    label: string;
    prompt: string;
    /** Needs the live estate function. */
    live?: boolean;
    /** Needs T5's (Azure Cosmos DB) history: shown only once the history model holds some. */
    cosmos?: boolean;
    /** True: needs the Incident RCA's tables in the history model. False: only without them, where the RCA starters take its place. */
    rca?: boolean;
}

/** One row: 1 when the lakehouse holds any T5 (Azure Cosmos DB) metric, whatever the filters, else 0. */
export const COSMOS_PROBE_DAX = 'EVALUATE ROW ( "HasCosmos", [Has Cosmos DB Bins] )';

export const STARTERS: readonly Starter[] = [
    { label: "How is my estate doing right now?", prompt: "How is my database estate doing right now? Check every engine, and tell me which database needs attention first.", live: true },
    { label: "Which security findings come first?", prompt: "Which security findings should I address first across my databases, and why?", live: true },
    { label: "Which servers can move to Azure?", prompt: "Which of my servers can move to Azure, and to what? Use each SQL Server instance's migration assessment, and say what isn't ready yet.", live: true },
    { label: "Which target worked hardest this week?", prompt: "Which target worked hardest over the last 7 days, and when? Show the CPU trend per target." },
    { label: "What happened in the latest incident?", prompt: "What was the latest abnormal period in the telemetry? Find it from the signals themselves (CPU, waits, blocked processes, deadlocks), show it against its baseline, name the likely cause with its evidence, and what I should check.", rca: false },
    ...INVESTIGATION_STARTERS.map((s) => ({ ...s, rca: true })),
    { label: "Where did the wait time go?", prompt: "Where did the wait time go in the last 24 hours, by target and wait category? Chart the top categories." },
    { label: "What changed since yesterday?", prompt: "What changed in my databases between the newest telemetry day and the day before? Lead with the biggest change." },
    { label: "Is the demo ready?", prompt: "Is the demo ready? Summarize the latest validation run and list anything that failed or needs a manual step, with its fix." },
    { label: "How is T4 (PostgreSQL) doing?", prompt: "How is T4, the PostgreSQL flexible server, doing in its latest capture: CPU, connections, and read replica lag?" },
    { label: "Was Cosmos DB throttled?", prompt: "Was T5, the Azure Cosmos DB account, throttled in its latest capture? Chart its peak normalized RU and its throttled requests (429s) over time, compare the RU it consumed with its provisioned RU/s, and tell me what to change.", cosmos: true },
];

/** The starters this environment can answer: the live ones with the estate function, T5's once its history exists, the investigations' with the RCA tables. */
export function startersFor(estate: boolean, cosmos = false, rca = false): Starter[] {
    return STARTERS.filter((s) => (estate || !s.live) && (cosmos || !s.cosmos) && (s.rca === undefined || s.rca === rca));
}
