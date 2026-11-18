// The tools Copilot can use in the dock. Every one runs here, in the viewer's browser, as the viewer:
//   run_dax           read-only DAX through the app's delegated history connector (executeQuery only)
//   show_chart        draws a native app chart (ChartSpec) from a run_dax result
//   suggest_followups shows the next questions as one-click chips
//   estate_overview   the live estate, through the app's estate function (only when it's deployed)
// Copilot gets each tool's answer as text; the dock keeps the full results for charts, tables, and "Show the DAX".

import { CHART_KINDS, MAX_CHART_ROWS, validateChartSpec, type ChartSpec, type ContextRow } from "./contract";
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

export interface AskToolDeps {
    /** Runs DAX through the history connector; resolves to rows keyed by column name, or throws a plain-language Error. */
    runDax: (query: string, rowLimit: number) => Promise<ContextRow[]>;
    /** The live estate function, when it's deployed. */
    estate?: (view: string) => Promise<{ source: string[]; data: unknown }>;
    onDax?: (run: DaxRun) => void;
    onChart?: (chart: ChartSpec, run: DaxRun) => void;
    onFollowups?: (questions: string[]) => void;
    onEstate?: (call: EstateCall) => void;
    now?: () => number;
}

export interface ToolOutcome {
    ok: boolean;
    /** What Copilot reads. */
    text: string;
}

// The units ChartView reads (contract.ts), by the names the model picks from.
const UNITS: Record<string, string> = { percent: "%", seconds: "s", milliseconds: "ms", minutes: "min", mb: "MB", gb: "GB", count: "count", number: "" };
export const ESTATE_VIEWS = ["inventory", "health", "security"] as const;

export function toolSpecs(options: { estate: boolean }): ToolSpec[] {
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
            description: "Shows two to four short follow-up questions as buttons the viewer can select. Call it once, at the end of every answer.",
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
                "view 'inventory': the databases by engine and type. 'health': SQL and PostgreSQL CPU, storage, and memory high-usage counts, and Cosmos DB availability and normalized RU, for the last 24 hours. " +
                "'security': Microsoft Entra authentication, auditing, and customer-managed key posture, and the security findings. Use it for questions about now; use run_dax for history and trends.",
            parameters: {
                type: "object",
                properties: { view: { type: "string", enum: [...ESTATE_VIEWS] } },
                required: ["view"],
                additionalProperties: false,
            },
        });
    }
    return specs;
}

/** Removes DAX comments, so the statement check sees the first real keyword. */
export function stripDaxComments(query: string): string {
    return query
        .replace(/\/\*[\s\S]*?\*\//g, " ")
        .replace(/(^|[^:])\/\/.*$/gm, "$1")
        .replace(/--.*$/gm, "")
        .trim();
}

/** Plain-language reason a query isn't accepted, or null when it is. */
export function checkDax(query: unknown): string | null {
    if (typeof query !== "string" || !query.trim()) return "The query is empty.";
    if (query.length > DAX_MAX) return `The query is longer than ${DAX_MAX} characters.`;
    const body = stripDaxComments(query);
    if (!/^(DEFINE|EVALUATE)\b/i.test(body)) return "The query must start with EVALUATE (or DEFINE ... EVALUATE).";
    if (!/\bEVALUATE\b/i.test(body)) return "The query has no EVALUATE statement.";
    return null;
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
        const query = typeof args.query === "string" ? args.query.trim() : "";
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
        return { ok: true, text: "Shown." };
    }

    async function estateOverview(args: Record<string, unknown>): Promise<ToolOutcome> {
        if (!deps.estate) return { ok: false, text: "The live estate isn't available in this deployment. Answer from the history (run_dax) and say so." };
        const view = (ESTATE_VIEWS as readonly string[]).includes(str(args.view)) ? str(args.view) : "inventory";
        const id = `e${++n}`;
        const started = now();
        try {
            const { source, data } = await deps.estate(view);
            deps.onEstate?.({ id, view, source, result: data, ms: now() - started, at: new Date(started) });
            const text = JSON.stringify({ view, source, data });
            return { ok: true, text: text.length > RESULT_CHARS ? `${text.slice(0, RESULT_CHARS)} [cut]` : text };
        } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            deps.onEstate?.({ id, view, source: [], error: message, ms: now() - started, at: new Date(started) });
            return { ok: false, text: `The live estate couldn't be read: ${message}` };
        }
    }

    return {
        results,
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
                    return { ok: false, text: `There's no tool named ${name}.` };
            }
        },
    };
}

export type ToolRunner = ReturnType<typeof createToolRunner>;
