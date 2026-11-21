// The tools Copilot can use in the dock. Every one runs here, in the viewer's browser, as the viewer:
//   run_dax           read-only DAX through the app's delegated history connector (executeQuery only)
//   show_chart        draws a native app chart (ChartSpec) from a run_dax result
//   suggest_followups shows the next questions as one-click chips
//   estate_overview   the live estate, through the app's estate function (only when it's deployed)
//   find_incidents, triage_window, explain_*   the Incident RCA's investigations (src/rca/tools.ts), when the model has its tables
// Blind (ADR 0031): run_dax refuses a query that names the demo's answer key (./answer-key.ts).
// Copilot gets each tool's answer as text; the dock keeps the full results for charts, tables, and "Show the DAX".

import { INVESTIGATION_TOOL_NAMES, INVESTIGATION_TOOL_SPECS } from "@/rca/tools";
import { answerKeyIn, answerKeyRefusal, foldNames, wholeModelRefusal } from "./answer-key";
import { CHART_KINDS, MAX_CHART_ROWS, validateChartSpec, type ChartSpec, type ContextRow } from "./contract";
import { ANSWER_KEY_MEASURES } from "./model-guide.generated";
import type { ToolSpec } from "./relay";

export const DAX_ROW_LIMIT = 2000;
const ROWS_TO_MODEL = 120;
const RESULT_CHARS = 60_000;
const DAX_MAX = 20_000;

export interface DaxRun {
    id: string;
    query: string;
    purpose: string;
    columns: string[];
    rows: ContextRow[];
    rowCount: number;
    error?: string;
    ms: number;
    at: Date;
}

export interface EstateCall {
    id: string;
    view: string;
    /** Which Database Hub routes answered: the estate answer's source, shown like a query's DAX. */
    source: string[];
    result?: unknown;
    error?: string;
    ms: number;
    at: Date;
}

/** One view of the live estate, as the app's estate function answers it (EstateAnswer in rayfin/functions). */
export interface EstateToolAnswer {
    /** The Database Hub routes the function called: one that failed is listed too, with its reason in errors. */
    source: string[];
    data: unknown;
    /** One plain sentence when the live view isn't available to the app: no route answered, for an authentication reason. */
    unavailable?: string;
    /** Per-route reasons, for the function's own log: never passed to Copilot or shown in the dock. */
    errors?: string[];
    at?: string;
}

export interface AskToolDeps {
    /** Runs DAX through the history connector; resolves to rows keyed by column name, or throws a plain-language Error. */
    runDax: (query: string, rowLimit: number) => Promise<ContextRow[]>;
    /** The live estate function, when it's deployed. */
    estate?: (view: string) => Promise<EstateToolAnswer>;
    /** Why the live view is off for the rest of this conversation, once the estate function said it isn't available. */
    liveOff?: () => string | null;
    onLiveUnavailable?: (reason: string) => void;
    /** Whether Copilot has written answer text since its last query; suggest_followups reminds it when it hasn't (R925). */
    answered?: () => boolean;
    onDax?: (run: DaxRun) => void;
    onChart?: (chart: ChartSpec, run: DaxRun) => void;
    onFollowups?: (questions: string[]) => void;
    onEstate?: (call: EstateCall) => void;
    /** The Incident RCA's investigation tools, when the model has the RCA tables (src/rca/tools.ts). */
    investigations?: { run: (name: string, args: unknown) => Promise<ToolOutcome> };
    now?: () => number;
}

export interface ToolOutcome {
    ok: boolean;
    /** What Copilot reads. */
    text: string;
}

/** Plain words for a live view that didn't answer, for Copilot and the dock: never routes or HTTP codes (R925). */
export const LIVE_UNAVAILABLE = "Database Hub's live view isn't available to the app right now.";
export const LIVE_NO_ANSWER = "Database Hub's live view didn't answer just now.";
const FROM_HISTORY = "Answer from the history model (run_dax), and say in plain words that the live view didn't answer; never quote error codes or routes.";
const liveOffText = (reason: string) =>
    `${reason} Don't call estate_overview again in this conversation. Answer from the history model (run_dax), say in plain words that the live view isn't available, and point the viewer to Database Hub's own pages in the Fabric portal for the live state.`;
/** The function's sentence, unless it carries what an audience shouldn't see (an HTTP code or a route): then the dock's own. */
const plainReason = (text: string) => {
    if (/\bHTTP\b|\b(40[0-9]|429|5\d\d)\b|(^|\s)\/[A-Za-z]/.test(text)) return LIVE_UNAVAILABLE;
    const trimmed = text.trim().slice(0, 200);
    return /[.!?]$/.test(trimmed) ? trimmed : `${trimmed}.`;
};

// The parts of the live view, by the route that reads them, in plain words for an answer that came back in part.
const LIVE_PARTS: Array<[RegExp, string]> = [
    [/savedView\/resources/i, "the inventory"],
    [/health\/v2\/filtered-summary/i, "the SQL health summary"],
    [/health\/v2\/filtered-usage/i, "the SQL usage details"],
    [/postgreSql\/health/i, "the PostgreSQL health"],
    [/cosmosDb\/health/i, "the Cosmos DB health"],
    [/auth\/warnings/i, "the Microsoft Entra authentication findings"],
    [/auditing\/warnings/i, "the auditing findings"],
    [/cmk\/warnings/i, "the customer-managed key findings"],
];
const missingParts = (errors: string[]) => [...new Set(errors.map((e) => LIVE_PARTS.find(([part]) => part.test(e))?.[1] ?? "another part of the live view"))];

// The units ChartView reads (contract.ts), by the names the model picks from.
const UNITS: Record<string, string> = { percent: "%", seconds: "s", milliseconds: "ms", minutes: "min", mb: "MB", gb: "GB", count: "count", number: "" };
export const ESTATE_VIEWS = ["inventory", "health", "security"] as const;

export function toolSpecs(options: { estate: boolean; rca?: boolean }): ToolSpec[] {
    const specs: ToolSpec[] = [
        {
            name: "run_dax",
            description:
                "Runs ONE read-only DAX query against SM_DatabaseHub_History, the demo's history model, as the signed-in viewer. " +
                "The query must start with EVALUATE (or DEFINE ... EVALUATE). Use only the tables, columns, and measures in the model guide. " +
                `It returns a resultId, the column names, and up to ${ROWS_TO_MODEL} rows (the page keeps up to ${DAX_ROW_LIMIT}); aggregate with SUMMARIZECOLUMNS instead of listing raw rows. ` +
                "The viewer can open every query you run.",
            parameters: {
                type: "object",
                properties: {
                    query: { type: "string", description: "The DAX query, starting with EVALUATE or DEFINE." },
                    purpose: { type: "string", description: "One short sentence for the viewer: what this query checks." },
                },
                required: ["query", "purpose"],
                additionalProperties: false,
            },
        },
        {
            name: "show_chart",
            description:
                "Draws one of the app's native charts in the conversation from a result run_dax returned. " +
                "kind: line or area for a time series (x is a date/time column), bar or stackedBar for categories, scatter for two measures, table for a small result, kpi for one headline number. " +
                "y lists 1 to 6 numeric columns of that result; series optionally splits the data by a text column (for example the target).",
            parameters: {
                type: "object",
                properties: {
                    resultId: { type: "string", description: "The resultId from run_dax." },
                    kind: { type: "string", enum: [...CHART_KINDS] },
                    title: { type: "string", description: "A short title that states the finding, not just the measure." },
                    subtitle: { type: "string", description: "Optional: the period, targets, and unit." },
                    x: { type: "string", description: "The column for the x axis (not needed for kpi or table)." },
                    y: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 6, description: "Numeric columns to plot." },
                    series: { type: "string", description: "Optional text column that splits the rows into one series per value; then y is exactly one column." },
                    unit: { type: "string", enum: Object.keys(UNITS), description: "The unit of the y values." },
                },
                required: ["resultId", "kind", "title"],
                additionalProperties: false,
            },
        },
        {
            name: "suggest_followups",
            description:
                "Shows two to four short follow-up questions as buttons under your answer. Call it once, after you've written the answer itself as text: it adds buttons and never replaces the answer.",
            parameters: {
                type: "object",
                properties: { questions: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 4 } },
                required: ["questions"],
                additionalProperties: false,
            },
        },
    ];
    if (options.estate) {
        specs.push({
            name: "estate_overview",
            description:
                "Reads the LIVE Database Hub view of the demo's own resources (its resource group only), read-only. " +
                "view 'inventory': the databases by engine and type, Database Hub's findings for each, and each SQL Server instance's migration assessment (readiness for Azure SQL Database, SQL Managed Instance, and SQL Server on Azure VMs; use it for which servers can move to Azure, and to what). 'health': SQL and PostgreSQL CPU, storage, and memory high-usage counts, and Cosmos DB availability and normalized RU, for the last 24 hours. " +
                "'security': Microsoft Entra authentication, auditing, and customer-managed key posture, and the security findings. Use it for questions about now; use run_dax for history and trends.",
            parameters: {
                type: "object",
                properties: { view: { type: "string", enum: [...ESTATE_VIEWS] } },
                required: ["view"],
                additionalProperties: false,
            },
        });
    }
    if (options.rca) specs.push(...INVESTIGATION_TOOL_SPECS);
    return specs;
}

/**
 * Removes DAX comments (`//` and `--` to the line's end, and `/* … *\/`), so the statement check sees the first real keyword.
 * A comment marker inside a string ("…"), a quoted name ('…'), or a bracketed name ([…]) is text, not a comment: each is
 * read whole, with its doubled closing character as an escape, so no string can hide the rest of a query (the review of 34a9732).
 */
export function stripDaxComments(query: string): string {
    return scanDax(query, "nothing").trim();
}

/** The query's code alone: comments removed, and every string, quoted name, and bracketed name emptied, so a check for a function never matches text. */
export function daxCode(query: string): string {
    return scanDax(query, "strings and names");
}

/**
 * The text run_dax checks and sends: each CRLF, lone CR, and form feed as a line feed (the review of bfbbe2a). Where the
 * engine ends a `//` or `--` comment isn't documented, and both guesses about a lone CR let a query hide code from the
 * check: ending the comment there before fb964e7, and not ending it there after. With neither character in the text, the
 * check and the engine read every comment's end alike, whatever the engine does. A CR or form feed inside a string becomes
 * a line feed too, which a query never needs.
 */
export function normalizeDax(query: string): string {
    return query.replace(/\r\n?|\f/g, "\n");
}

/**
 * Where a line comment ends: at a line feed, where the engine ends it too, and at a vertical tab, U+0085, U+2028, or
 * U+2029, which Unicode also makes mandatory line breaks. Whether the engine ends a comment at one of those isn't
 * documented, so the comment ends there here, and the plain-ASCII rule then refuses that character as code: a query in
 * which one could end a comment is refused, whatever the engine does (the reviews of fb964e7 and bfbbe2a). No CR or form
 * feed gets here (normalizeDax).
 */
const LINE_BREAK = /[\n\v\u0085\u2028\u2029]/g;

/** Reads a query, normalized as run_dax sends it, without its comments, as stripDaxComments says, and empties its strings, or its names too, for checks that read code only. */
function scanDax(text: string, empty: "nothing" | "strings" | "strings and names"): string {
    const query = normalizeDax(text);
    let out = "";
    let i = 0;
    while (i < query.length) {
        const c = query[i];
        const next = query[i + 1];
        if (c === '"' || c === "'" || c === "[") {
            const close = c === "[" ? "]" : c;
            let j = i + 1;
            for (; j < query.length; j++) {
                if (query[j] !== close) continue;
                if (query[j + 1] === close) j++;
                else break;
            }
            const emptied = empty === "strings and names" || (empty === "strings" && c === '"');
            out += emptied ? c + close : query.slice(i, j + 1);
            i = j + 1;
        } else if (c === "/" && next === "*") {
            const end = query.indexOf("*/", i + 2);
            out += " ";
            i = end < 0 ? query.length : end + 2;
        } else if ((c === "/" && next === "/") || (c === "-" && next === "-")) {
            LINE_BREAK.lastIndex = i;
            i = LINE_BREAK.exec(query)?.index ?? query.length;
        } else {
            out += c;
            i++;
        }
    }
    return out;
}

/** What a query's code may hold outside its strings and comments: printable ASCII, spaces, tabs, and line feeds (no CR is left, normalizeDax). */
const NOT_PLAIN = /[^\t\n\x20-\x7E]/u;

/**
 * What run_dax says about a character outside plain ASCII in a query's code, outside its strings and comments, or null.
 * Every name in the model is plain ASCII (guide.test.ts pins it), so a name the chat may query never needs one. Any other
 * character, such as a compatibility form, an invisible character, a control, or one an older collation gives no weight,
 * could spell a name the engine resolves and the name check can't see (the coordinator's hardening of 9f3d35f).
 */
export function plainCodeRefusal(query: string): string | null {
    const char = NOT_PLAIN.exec(scanDax(query, "strings"))?.[0];
    if (!char) return null;
    const code = `U+${char.codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0")}`;
    const shown = /^[\p{L}\p{N}\p{P}\p{S}]$/u.test(char) ? ` (${char})` : "";
    return (
        `The query has the character ${code}${shown} outside a string. Every table, column, and measure in the model guide is named in plain ASCII: ` +
        "write names, keywords, and operators with plain letters, digits, spaces, and straight quotes, and give a column your query names itself a plain name. " +
        "Any other text can go in a string, in double quotes, or in a comment."
    );
}

/** Plain-language reason a query isn't accepted, or null when it is. It judges the query as run_dax sends it (normalizeDax). */
export function checkDax(query: unknown): string | null {
    if (typeof query !== "string" || !query.trim()) return "The query is empty.";
    const text = normalizeDax(query);
    if (text.length > DAX_MAX) return `The query is longer than ${DAX_MAX} characters.`;
    const body = stripDaxComments(text);
    if (!/^(DEFINE|EVALUATE)\b/i.test(body)) return "The query must start with EVALUATE (or DEFINE ... EVALUATE).";
    if (!/\bEVALUATE\b/i.test(body)) return "The query has no EVALUATE statement.";
    // A function that reads the whole model reaches the answer key without naming it (the re-review of 817b81c), however
    // its name is written: in the code, where a comment can split its name, and, like a key table's name, in the text as
    // written, strings and comments included, so no misreading of where a comment or a string ends can hide a call (the
    // review of bfbbe2a).
    const wholeModel = wholeModelRefusal(foldNames(daxCode(text)));
    if (wholeModel) return wholeModel;
    const named = wholeModelRefusal(foldNames(text));
    if (named) return `${named} Leave its name out of the query's strings, comments, and names too.`;
    // The text that runs is the query as written, so the answer key is looked for there too, comments and strings included,
    // with names folded as leniently as the engine's collation might compare them (foldNames): naming a table in a comment
    // or a string is refused with it, which never hides a real reference.
    const key = answerKeyIn(text, ANSWER_KEY_MEASURES) ?? answerKeyIn(body, ANSWER_KEY_MEASURES);
    if (key) return answerKeyRefusal(key);
    // Then plain ASCII outside strings and comments, so no character the fold doesn't know can spell a name.
    return plainCodeRefusal(text);
}

function compactValue(value: unknown): unknown {
    if (typeof value === "number") return Number.isInteger(value) ? value : Math.round(value * 10000) / 10000;
    if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value)) return value.replace(/\.\d+/, "").replace(/(Z|[+-]00:00)?$/, "Z");
    return value;
}

/** The text Copilot reads for a result: compact JSON, bounded in rows and characters. */
export function resultForModel(run: DaxRun): string {
    let rows = run.rows.slice(0, ROWS_TO_MODEL).map((r) => run.columns.map((c) => compactValue(r[c])));
    for (;;) {
        const text = JSON.stringify({ resultId: run.id, rowCount: run.rowCount, returnedRows: rows.length, truncated: rows.length < run.rowCount, columns: run.columns, rows });
        if (text.length <= RESULT_CHARS || rows.length <= 1) return text;
        rows = rows.slice(0, Math.floor(rows.length / 2));
    }
}

function str(value: unknown, max = 500): string {
    return typeof value === "string" ? value.trim().slice(0, max) : "";
}

export function createToolRunner(deps: AskToolDeps) {
    const results = new Map<string, DaxRun>();
    const now = deps.now ?? (() => Date.now());
    let n = 0;

    async function runDax(args: Record<string, unknown>): Promise<ToolOutcome> {
        // What's checked, sent to the history connector, and shown under "Show the sources" is one text: the query with a
        // line feed for each CR and form feed (normalizeDax), so the engine never reads one (the review of bfbbe2a).
        const query = typeof args.query === "string" ? normalizeDax(args.query).trim() : "";
        const purpose = str(args.purpose, 300) || "A query Copilot ran.";
        const id = `r${++n}`;
        const started = now();
        const problem = checkDax(query);
        if (problem) {
            deps.onDax?.({ id, query, purpose, columns: [], rows: [], rowCount: 0, error: problem, ms: 0, at: new Date(started) });
            return { ok: false, text: `Not run: ${problem}` };
        }
        try {
            const rows = await deps.runDax(query, DAX_ROW_LIMIT);
            const columns = rows.length > 0 ? Object.keys(rows[0]) : [];
            const run: DaxRun = { id, query, purpose, columns, rows, rowCount: rows.length, ms: now() - started, at: new Date(started) };
            results.set(id, run);
            deps.onDax?.(run);
            return { ok: true, text: resultForModel(run) };
        } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            deps.onDax?.({ id, query, purpose, columns: [], rows: [], rowCount: 0, error: message, ms: now() - started, at: new Date(started) });
            return { ok: false, text: `The query failed: ${message}` };
        }
    }

    function showChart(args: Record<string, unknown>): ToolOutcome {
        const resultId = str(args.resultId, 40);
        const run = results.get(resultId);
        if (!run) return { ok: false, text: `No result ${JSON.stringify(resultId)}: run run_dax first and use its resultId.` };
        const kind = CHART_KINDS.includes(args.kind as ChartSpec["kind"]) ? (args.kind as ChartSpec["kind"]) : "line";
        const x = str(args.x, 120) || undefined;
        const y = Array.isArray(args.y) ? args.y.map((v) => str(v, 120)).filter(Boolean).slice(0, 6) : [];
        const series = str(args.series, 120) || undefined;
        if (kind !== "kpi" && kind !== "table" && (!x || y.length === 0)) return { ok: false, text: `A ${kind} chart needs x and at least one y column.` };
        if (kind === "kpi" && y.length === 0) return { ok: false, text: "A kpi needs one y column." };
        const missing = [x, ...y, series].filter((c): c is string => typeof c === "string" && c.length > 0 && !run.columns.includes(c));
        if (missing.length > 0) return { ok: false, text: `Unknown column(s) ${missing.join(", ")}. The result has: ${run.columns.join(", ")}.` };
        const checked = validateChartSpec({
            kind,
            title: str(args.title, 140) || "Chart",
            subtitle: str(args.subtitle, 200) || undefined,
            rows: run.rows.slice(0, MAX_CHART_ROWS),
            x,
            y: y.length === 1 ? y[0] : y.length > 1 ? y : undefined,
            series,
            unit: Object.hasOwn(UNITS, str(args.unit)) ? UNITS[str(args.unit)] || undefined : undefined,
        });
        if (!checked.ok) return { ok: false, text: `Not drawn: ${checked.error}` };
        const chart: ChartSpec = checked.spec;
        deps.onChart?.(chart, run);
        return { ok: true, text: `The ${kind} chart "${chart.title}" is in the conversation (${run.rowCount} rows).` };
    }

    function suggestFollowups(args: Record<string, unknown>): ToolOutcome {
        const questions = Array.isArray(args.questions) ? args.questions.map((q) => str(q, 200)).filter(Boolean).slice(0, 4) : [];
        if (questions.length === 0) return { ok: false, text: "questions is empty." };
        deps.onFollowups?.(questions);
        // The live turn of 2026-11-19 ended here with no answer text (R925): when nothing's written since the last query, say so.
        if (deps.answered && !deps.answered()) {
            return { ok: true, text: "Shown under your answer. You haven't written the answer itself yet: write it now as text, from the results above." };
        }
        return { ok: true, text: "Shown under your answer." };
    }

    async function estateOverview(args: Record<string, unknown>): Promise<ToolOutcome> {
        if (!deps.estate) return { ok: false, text: "The live estate isn't available in this deployment. Answer from the history (run_dax) and say so." };
        // Once the function said the live view isn't available, the rest of the conversation doesn't call it again.
        const off = deps.liveOff?.();
        if (off) return { ok: false, text: liveOffText(off) };
        const view = (ESTATE_VIEWS as readonly string[]).includes(str(args.view)) ? str(args.view) : "inventory";
        const id = `e${++n}`;
        const started = now();
        let answer: EstateToolAnswer;
        try {
            answer = await deps.estate(view);
        } catch {
            deps.onEstate?.({ id, view, source: [], error: LIVE_NO_ANSWER, ms: now() - started, at: new Date(started) });
            return { ok: false, text: `${LIVE_NO_ANSWER} ${FROM_HISTORY}` };
        }
        const source = Array.isArray(answer?.source) ? answer.source.filter((s): s is string => typeof s === "string") : [];
        const errors = Array.isArray(answer?.errors) ? answer.errors.map(String) : [];
        // The function lists a route in source before it calls it, so a route answered only when none of its calls failed.
        const answered = source.filter((route) => !errors.some((e) => e.startsWith(`${route}:`)));
        // An answer without data has nothing to read, whatever its source says (R924's shape for a total failure: data {}).
        const data = answer?.data;
        const noData = typeof data !== "object" || data === null || Object.keys(data).length === 0;
        const unavailable = typeof answer?.unavailable === "string" && answer.unavailable.trim() ? plainReason(answer.unavailable) : null;
        // No route answered: Copilot gets one plain sentence, never the per-route reasons (they're for the function's log).
        // Only unavailable turns the live view off for the conversation; after any other failure the next question tries again.
        if (unavailable || answered.length === 0 || noData) {
            const reason = unavailable ?? LIVE_NO_ANSWER;
            if (unavailable) deps.onLiveUnavailable?.(unavailable);
            deps.onEstate?.({ id, view, source: [], error: reason, ms: now() - started, at: new Date(started) });
            return { ok: false, text: unavailable ? liveOffText(reason) : `${reason} ${FROM_HISTORY}` };
        }
        // The routes are the row's source, like a query's DAX; Copilot gets the data, never route names it could repeat.
        deps.onEstate?.({ id, view, source: answered, result: answer.data, ms: now() - started, at: new Date(started) });
        const missing = errors.length > 0 ? missingParts(errors) : [];
        const text = JSON.stringify({
            view,
            at: answer.at,
            data: answer.data,
            ...(missing.length > 0 ? { missing, note: `These parts of the live view didn't answer: ${missing.join("; ")}. Say which, in plain words.` } : {}),
        });
        return { ok: true, text: text.length > RESULT_CHARS ? `${text.slice(0, RESULT_CHARS)} [cut]` : text };
    }

    return {
        results,
        /** Whether a tool reads data: text Copilot wrote before it is what it will check, not the answer (R925). */
        isQuery(name: string): boolean {
            return name === "run_dax" || name === "estate_overview" || INVESTIGATION_TOOL_NAMES.includes(name);
        },
        async run(name: string, args: unknown): Promise<ToolOutcome> {
            const input = typeof args === "object" && args !== null && !Array.isArray(args) ? (args as Record<string, unknown>) : {};
            switch (name) {
                case "run_dax":
                    return runDax(input);
                case "show_chart":
                    return showChart(input);
                case "suggest_followups":
                    return suggestFollowups(input);
                case "estate_overview":
                    return estateOverview(input);
                default:
                    if (deps.investigations && INVESTIGATION_TOOL_NAMES.includes(name)) return deps.investigations.run(name, input);
                    return { ok: false, text: `There's no tool named ${name}.` };
            }
        },
    };
}

export type ToolRunner = ReturnType<typeof createToolRunner>;
