// The demo's answer key: what it injected and how Wave 1 graded it (ADR 0031, blind detection; rca/blind-detection.json).
// The chat never reads it. The model guide leaves out these tables, the measures that read them, and these analyses'
// rows, and run_dax refuses a query that names a table or one of those measures (DAX names a measure without its
// table), so Copilot investigates the way a DBA's tools would, from the telemetry and the capture. The tests check
// these lists against the contract's, and the measures against the model's TMDL.

export const ANSWER_KEY_TABLES = ["Scenario Runs", "Incident Windows", "RCA Answer Key", "Analysis Findings"] as const;

/** The analyses that grade the demo against what it injected: their rows describe the key, not the telemetry. */
export const ANSWER_KEY_ANALYSES = ["correlation", "database_agent", "blocking"] as const;

/** The answer-key table or measure a DAX query names, as the query wrote it, or null when it names none. */
export function answerKeyIn(dax: string, measures: readonly string[], tables: readonly string[] = ANSWER_KEY_TABLES): string | null {
    const flat = dax.replace(/\s+/g, " ").toLowerCase();
    const table = tables.find((t) => flat.includes(t.toLowerCase()));
    if (table) return table;
    // [ Injected Faults ] too: the check doesn't rely on DAX reading a bracketed name as written.
    const names = flat.replace(/\[ /g, "[").replace(/ \]/g, "]");
    const measure = measures.find((m) => names.includes(`[${m.toLowerCase()}]`));
    return measure ? `[${measure}]` : null;
}

const INSTEAD = "it investigates the way a DBA's tools would. The model guide lists every table, column, and measure you can query: name them instead";

/**
 * DAX functions that read the model without naming a table, so the name check can't see what they reach; run_dax refuses
 * each (the re-review of 817b81c). COLUMNSTATISTICS returns every column's minimum, maximum, and distinct count
 * (learn.microsoft.com/dax/columnstatistics-function-dax); the INFO functions return the model's metadata, descriptions and
 * expressions included (learn.microsoft.com/dax/info-functions-dax); CALENDARAUTO scans every date column
 * (learn.microsoft.com/dax/calendarauto-function-dax); EXTERNALMEASURE names a measure by a string
 * (learn.microsoft.com/dax/externalmeasure-function-dax). TABLEOF needs no entry: it reaches a table only through a column,
 * measure, or calendar the query names, every measure an answer-key table hosts is refused, and none of them has a calendar
 * (learn.microsoft.com/dax/tableof-function-dax; guide.test.ts pins both).
 */
export const WHOLE_MODEL_FUNCTIONS: readonly { name: string; called: RegExp; refusal: string }[] = [
    {
        name: "COLUMNSTATISTICS",
        called: /\bCOLUMNSTATISTICS\b/i,
        refusal: `COLUMNSTATISTICS returns the range of every column in every table, the demo's answer key included, which this chat doesn't read: ${INSTEAD}.`,
    },
    {
        name: "INFO",
        called: /\bINFO\s*\.\s*[A-Z]/i,
        refusal: `INFO functions return the model's metadata, the demo's answer key included, which this chat doesn't read: ${INSTEAD}.`,
    },
    {
        name: "CALENDARAUTO",
        called: /\bCALENDARAUTO\b/i,
        refusal: `CALENDARAUTO reads every date column in the model, the demo's answer key included, which this chat doesn't read. Use the 'Date' table, or CALENDAR with the dates you need.`,
    },
    {
        name: "EXTERNALMEASURE",
        called: /\bEXTERNALMEASURE\b/i,
        refusal: `EXTERNALMEASURE names a measure by a string, so it can't be checked against the demo's answer key, which this chat doesn't read. Name the measure as [Measure] instead.`,
    },
];

/** What run_dax says about the whole-model function a query calls, or null. `code` has its comments, strings, and names blanked. */
export function wholeModelRefusal(code: string): string | null {
    return WHOLE_MODEL_FUNCTIONS.find((f) => f.called.test(code))?.refusal ?? null;
}

/** What run_dax says when a query names the answer key: plain words, and what to use instead. */
export function answerKeyRefusal(name: string): string {
    const what = name.startsWith("[") ? `${name} reads the demo's answer key` : `${name} holds the demo's answer key`;
    return `${what} (what it injected and how it was graded), which this chat doesn't read: it investigates the way a DBA's tools would. Use 'Telemetry Snapshots' and its measures, or the investigation tools when they're offered. If ${name.startsWith("[") ? `${name} is a column your query names itself, give it another name` : "you meant another table, check its name in the model guide"}.`;
}
