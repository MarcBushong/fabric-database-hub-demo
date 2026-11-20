// The demo's answer key: what it injected and how Wave 1 graded it (ADR 0031, blind detection; rca/blind-detection.json).
// The chat never reads it. The model guide leaves out these tables, the measures that read them, and these analyses'
// rows, and run_dax refuses a query that names a table or one of those measures (DAX names a measure without its
// table), so Copilot investigates the way a DBA's tools would, from the telemetry and the capture. The tests check
// these lists against the contract's, and the measures against the model's TMDL.

export const ANSWER_KEY_TABLES = ["Scenario Runs", "Incident Windows", "RCA Answer Key", "Analysis Findings"] as const;

/** The analyses that grade the demo against what it injected: their rows describe the key, not the telemetry. */
export const ANSWER_KEY_ANALYSES = ["correlation", "database_agent", "blocking"] as const;

/** The answer-key table or measure a DAX query names, as the query wrote it, or null when it names none. */
export function answerKeyIn(dax: string, measures: readonly string[]): string | null {
    const flat = dax.replace(/\s+/g, " ").toLowerCase();
    const table = ANSWER_KEY_TABLES.find((t) => flat.includes(t.toLowerCase()));
    if (table) return table;
    const measure = measures.find((m) => flat.includes(`[${m.toLowerCase()}]`));
    return measure ? `[${measure}]` : null;
}

/** What run_dax says when a query names the answer key: plain words, and what to use instead. */
export function answerKeyRefusal(name: string): string {
    const what = name.startsWith("[") ? `${name} reads the demo's answer key` : `${name} holds the demo's answer key`;
    return `${what} (what it injected and how it was graded), which this chat doesn't read: it investigates the way a DBA's tools would. Use 'Telemetry Snapshots' and its measures, or the investigation tools when they're offered. If ${name.startsWith("[") ? `${name} is a column your query names itself, give it another name` : "you meant another table, check its name in the model guide"}.`;
}
