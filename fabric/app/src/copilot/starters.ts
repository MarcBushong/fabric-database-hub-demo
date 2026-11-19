// The dock's starter questions: the DBA questions from the prompt pack (fabric/agent/prompts), phrased for this
// app's two sources, the live estate and the history. The same starters work in every session and every
// environment, so a demo can be rehearsed and repeated.

export interface Starter {
    label: string;
    prompt: string;
    /** Needs the live estate function. */
    live?: boolean;
}

export const STARTERS: readonly Starter[] = [
    { label: "How is my estate doing right now?", prompt: "How is my database estate doing right now? Check every engine, and tell me which database needs attention first.", live: true },
    { label: "Which security findings come first?", prompt: "Which security findings should I address first across my databases, and why?", live: true },
    { label: "Which servers can move to Azure?", prompt: "Which of my servers can move to Azure, and to what? Use each SQL Server instance's migration assessment, and say what isn't ready yet.", live: true },
    { label: "Which target worked hardest this week?", prompt: "Which target worked hardest over the last 7 days, and when? Show the CPU trend per target." },
    { label: "What happened in the latest incident?", prompt: "What happened in the latest incident window? Show the signal against its baseline, name the likely cause, and what I should check." },
    { label: "Where did the wait time go?", prompt: "Where did the wait time go in the last 24 hours, by target and wait category? Chart the top categories." },
    { label: "What changed since yesterday?", prompt: "What changed in my databases between the newest telemetry day and the day before? Lead with the biggest change." },
    { label: "Is the demo ready?", prompt: "Is the demo ready? Summarize the latest validation run and list anything that failed or needs a manual step, with its fix." },
    { label: "How is T4 (PostgreSQL) doing?", prompt: "How is T4, the PostgreSQL flexible server, doing in its latest capture: CPU, connections, and read replica lag?" },
];

export function startersFor(estate: boolean): Starter[] {
    return STARTERS.filter((s) => estate || !s.live);
}
