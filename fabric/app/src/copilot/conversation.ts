// The dock's deploy-time settings, from /dbhub-app.json (written by configure-fabric-app.ps1), and the pure
// conversation model: turns, their parts, the Markdown export, and the recap a new Copilot session starts from.

import { loadDeployFile } from "@/lib/runtime-config";
import { MAX_CONTEXT_ROWS, type AskContext, type ChartSpec, type ContextRow } from "./contract";
import { relayBase } from "./relay";
import type { DaxRun, EstateCall } from "./tools";

export interface AskSettings {
    /** The chat relay's base URL; null when Ask isn't deployed in this environment. */
    relayUrl: string | null;
    /** True when the app's estate function is deployed. */
    estate: boolean;
    /** The demo's resource group: the scope of the live estate. */
    resourceGroup?: string;
}

export async function loadAskSettings(fetchImpl: typeof fetch = fetch): Promise<AskSettings> {
    const deploy = (await loadDeployFile(fetchImpl)) as (Record<string, unknown> & { ask?: Record<string, unknown> }) | null;
    const ask = deploy?.ask && typeof deploy.ask === "object" ? deploy.ask : {};
    const rg = typeof deploy?.resourceGroup === "string" && /^[\w.()-]{1,90}$/.test(deploy.resourceGroup) ? deploy.resourceGroup : undefined;
    return { relayUrl: relayBase(ask.relayUrl), estate: ask.estate === true, resourceGroup: rg };
}

export type Part =
    | { type: "text"; messageId: string; text: string }
    | { type: "dax"; run: DaxRun }
    | { type: "chart"; chart: ChartSpec; runId: string }
    | { type: "estate"; call: EstateCall };

export interface UserTurn {
    role: "user";
    id: string;
    text: string;
    /** Where the question came from: a visual's title and page, shown as a chip. */
    from?: { title?: string; page?: string };
    at: number;
}

export interface AssistantTurn {
    role: "assistant";
    id: string;
    parts: Part[];
    followups: string[];
    streaming: boolean;
    error?: string;
    model?: string | null;
    at: number;
}

export type Turn = UserTurn | AssistantTurn;

export type ConversationAction =
    | { type: "user"; id: string; text: string; from?: UserTurn["from"]; at: number }
    | { type: "assistant-start"; id: string; at: number }
    | { type: "delta"; messageId: string; text: string }
    | { type: "message"; messageId: string; text: string }
    | { type: "dax"; run: DaxRun }
    | { type: "chart"; chart: ChartSpec; runId: string }
    | { type: "estate"; call: EstateCall }
    | { type: "followups"; questions: string[] }
    | { type: "model"; model: string | null }
    | { type: "idle" }
    | { type: "resume" }
    | { type: "error"; message: string }
    | { type: "reset" }
    | { type: "restore"; turns: Turn[] };

function updateCurrent(turns: Turn[], update: (turn: AssistantTurn) => AssistantTurn): Turn[] {
    const last = turns[turns.length - 1];
    if (!last || last.role !== "assistant") return turns;
    return [...turns.slice(0, -1), update(last)];
}

export function reduceConversation(turns: Turn[], action: ConversationAction): Turn[] {
    switch (action.type) {
        case "reset":
            return [];
        case "restore":
            return action.turns;
        case "user":
            return [...turns, { role: "user", id: action.id, text: action.text, from: action.from, at: action.at }];
        case "assistant-start":
            return [...turns, { role: "assistant", id: action.id, parts: [], followups: [], streaming: true, at: action.at }];
        case "delta":
            return updateCurrent(turns, (t) => {
                const i = t.parts.findIndex((p) => p.type === "text" && p.messageId === action.messageId);
                if (i < 0) return { ...t, parts: [...t.parts, { type: "text", messageId: action.messageId, text: action.text }] };
                const part = t.parts[i] as Extract<Part, { type: "text" }>;
                const parts = [...t.parts];
                parts[i] = { ...part, text: part.text + action.text };
                return { ...t, parts };
            });
        case "message":
            return updateCurrent(turns, (t) => {
                const i = t.parts.findIndex((p) => p.type === "text" && p.messageId === action.messageId);
                if (i < 0) return { ...t, parts: [...t.parts, { type: "text", messageId: action.messageId, text: action.text }] };
                const parts = [...t.parts];
                parts[i] = { type: "text", messageId: action.messageId, text: action.text };
                return { ...t, parts };
            });
        case "dax":
            return updateCurrent(turns, (t) => ({ ...t, parts: [...t.parts, { type: "dax", run: action.run }] }));
        case "chart":
            return updateCurrent(turns, (t) => ({ ...t, parts: [...t.parts, { type: "chart", chart: action.chart, runId: action.runId }] }));
        case "estate":
            return updateCurrent(turns, (t) => ({ ...t, parts: [...t.parts, { type: "estate", call: action.call }] }));
        case "followups":
            return updateCurrent(turns, (t) => ({ ...t, followups: action.questions }));
        case "model":
            return updateCurrent(turns, (t) => ({ ...t, model: action.model }));
        case "idle":
            return updateCurrent(turns, (t) => ({ ...t, streaming: false }));
        case "resume":
            return updateCurrent(turns, (t) => ({ ...t, streaming: true, error: undefined }));
        case "error":
            return updateCurrent(turns, (t) => ({ ...t, streaming: false, error: action.message }));
    }
}

/** The dock's words for a turn that ended without an answer (R925): plain, for an audience. */
export const NO_ANSWER = "Copilot didn't write an answer";

/**
 * Whether Copilot wrote an answer: text after the turn's last query (its DAX or Database Hub source), or any text in a
 * turn with no query. Text before a query is Copilot saying what it will check, not the answer (R925).
 */
export function hasAnswer(turn: AssistantTurn): boolean {
    let lastSource = -1;
    turn.parts.forEach((p, i) => {
        if (p.type === "dax" || p.type === "estate") lastSource = i;
    });
    return turn.parts.slice(lastSource + 1).some((p) => p.type === "text" && p.text.trim().length > 0);
}

/** A finished turn that ended without an answer (and without an error that already says why): the dock offers Retry. */
export function endedWithoutAnswer(turn: AssistantTurn): boolean {
    return !turn.streaming && !turn.error && !hasAnswer(turn);
}

/** What the dock sends when the viewer selects Retry: the same conversation, asked to write the answer it didn't. */
export function retryPrompt(question: string): string {
    const q = question.trim().slice(0, 500);
    return `You didn't write an answer to my last question${q ? `: "${q}"` : ""}. Write the answer now as text, from the results you already have in this conversation; run a new query only if you need data you don't have. Then call suggest_followups.`;
}

const MAX_CONTEXT_CHARS = 5600;

function describeSource(ctx: AskContext): string | null {
    if (ctx.source === "live") return `live data${ctx.asOf ? `, read ${ctx.asOf}` : ""}`;
    if (ctx.source === "sample") return "the local preview's sample data (made up: say so, and don't draw conclusions about the estate)";
    if (ctx.source === "history") return `the lakehouse history (snapshots, not live)${ctx.asOf ? `, newest ${ctx.asOf}` : ""}`;
    return ctx.asOf ? `data as of ${ctx.asOf}` : null;
}

/** The text sent to Copilot for a question that comes from a visual: the question plus what the visual shows. */
export function contextPrompt(ctx: AskContext): string {
    const anomaly = ctx.anomaly;
    const fallback = anomaly
        ? `Why did ${anomaly.metric}${anomaly.target ? ` on ${anomaly.target}` : ""} move${anomaly.at ? ` at ${anomaly.at}` : ""}? Compare it with its baseline, name the likely cause, and what I should check.`
        : ctx.title
          ? `Explain what "${ctx.title}" shows, and what a DBA should do about it.`
          : "What should I look at first?";
    const question = ctx.prompt?.trim() || fallback;
    const lines: string[] = [question];
    const hasContext = Boolean(ctx.title || ctx.page || ctx.dax || ctx.rows?.length || anomaly);
    if (hasContext) {
        lines.push("", `Context from the app${ctx.page ? ` (page: ${ctx.page})` : ""}${ctx.title ? `, visual "${ctx.title}"` : ""}:`);
        const source = describeSource(ctx);
        if (source) lines.push(`Source: ${source}.`);
        const f = ctx.filters;
        if (f && (f.targets?.length || f.period || f.from || f.to)) {
            lines.push(`Filters: ${[f.targets?.length ? `targets ${f.targets.join(", ")}` : "", f.period ? `period ${f.period}` : "", f.from || f.to ? `${f.from ?? "…"} to ${f.to ?? "…"}` : ""].filter(Boolean).join("; ")}.`);
        }
        if (anomaly) {
            const unit = anomaly.unit ? ` ${anomaly.unit}` : "";
            lines.push(
                `Anomaly: ${anomaly.metric}${anomaly.target ? ` on ${anomaly.target}` : ""}${anomaly.at ? ` at ${anomaly.at}` : ""}${anomaly.value !== undefined ? `, value ${anomaly.value}${unit}` : ""}${anomaly.baseline !== undefined ? ` against a baseline of ${anomaly.baseline}${unit}` : ""}${anomaly.incidentKey ? ` (incident ${anomaly.incidentKey})` : ""}.`,
            );
        }
        if (ctx.dax) lines.push("The visual's DAX:", "```dax", ctx.dax.slice(0, 2500), "```");
        if (ctx.rows && ctx.rows.length > 0) {
            if (ctx.columns?.length) lines.push(`Columns: ${ctx.columns.map((c) => `${c.key} (${c.label}${c.unit ? `, ${c.unit}` : c.kind ? `, ${c.kind}` : ""})`).join("; ")}.`);
            let rows: ContextRow[] = ctx.rows.slice(0, Math.min(40, MAX_CONTEXT_ROWS));
            let json = JSON.stringify(rows);
            while (json.length > MAX_CONTEXT_CHARS - lines.join("\n").length - 200 && rows.length > 1) {
                rows = rows.slice(0, Math.floor(rows.length / 2));
                json = JSON.stringify(rows);
            }
            const total = ctx.totalRows ?? ctx.rows.length;
            lines.push(`Its rows (${rows.length} of ${total}${ctx.truncated ? ", trimmed by the app" : ""}):`, json);
        }
    }
    return lines.join("\n").slice(0, 7800);
}
function partToMarkdown(p: Part): string {
    switch (p.type) {
        case "text":
            return p.text;
        case "dax":
            return `<details><summary>Query: ${p.run.purpose} (${p.run.error ? `failed: ${p.run.error}` : `${p.run.rowCount} rows`})</summary>\n\n\`\`\`dax\n${p.run.query}\n\`\`\`\n</details>`;
        case "chart":
            return `_Chart: ${p.chart.title}${p.chart.subtitle ? ` (${p.chart.subtitle})` : ""}_`;
        case "estate":
            return p.call.error ? `_Live estate (${p.call.view}): ${p.call.error}_` : `_Live estate (${p.call.view}) from Database Hub: ${p.call.source.join(", ")}_`;
    }
}

/** The whole conversation as Markdown, with every query's DAX, for Export. */
export function toMarkdown(turns: Turn[], title = "Database Hub Insights: Copilot conversation"): string {
    const out = [`# ${title}`, "", `Exported ${new Date().toISOString().replace(/\.\d+Z$/, "Z")}. Answers come from GitHub Copilot over the demo's data; check them before acting.`, ""];
    for (const t of turns) {
        if (t.role === "user") {
            out.push(`## You${t.from?.title ? ` (from "${t.from.title}")` : ""}`, "", t.text, "");
        } else {
            out.push(`## Copilot${t.model ? ` (${t.model})` : ""}`, "");
            for (const p of t.parts) out.push(partToMarkdown(p), "");
            if (t.error) out.push(`> ${t.error}`, "");
            else if (endedWithoutAnswer(t)) out.push(`> ${NO_ANSWER}.`, "");
        }
    }
    return out.join("\n");
}

/** A short recap of the conversation so far, for a new Copilot session after the last one ended. */
export function recap(turns: Turn[], maxTurns = 8): string {
    const recent = turns.slice(-maxTurns);
    const lines: string[] = [];
    for (const t of recent) {
        if (t.role === "user") lines.push(`Viewer: ${t.text.slice(0, 500)}`);
        else {
            const text = t.parts
                .filter((p): p is Extract<Part, { type: "text" }> => p.type === "text")
                .map((p) => p.text)
                .join(" ");
            if (text) lines.push(`You: ${text.slice(0, 700)}`);
        }
    }
    return lines.join("\n");
}

const STORE_KEY = "dbhub-insights.copilot.conversation.v1";
const ROWS_KEPT = 300;

/** Keeps the conversation for this browser session, with each result's rows capped so storage stays small. */
export function saveConversation(storage: Pick<Storage, "setItem"> | undefined, turns: Turn[]): void {
    const slim = turns.map((t) =>
        t.role === "user"
            ? t
            : {
                  ...t,
                  streaming: false,
                  parts: t.parts.map((p) =>
                      p.type === "dax" ? { ...p, run: { ...p.run, rows: p.run.rows.slice(0, ROWS_KEPT) } } : p.type === "chart" ? { ...p, chart: { ...p.chart, rows: p.chart.rows.slice(0, 2000) } } : p,
                  ),
              },
    );
    try {
        storage?.setItem(STORE_KEY, JSON.stringify(slim));
    } catch {
        // Over the quota or unavailable: the conversation still lives in memory.
    }
}

export function loadConversation(storage: Pick<Storage, "getItem"> | undefined): Turn[] {
    try {
        const raw = storage?.getItem(STORE_KEY);
        if (!raw) return [];
        const value = JSON.parse(raw) as Turn[];
        if (!Array.isArray(value)) return [];
        return value
            .filter((t) => t && (t.role === "user" || t.role === "assistant"))
            .map((t) =>
                t.role === "assistant"
                    ? {
                          ...t,
                          streaming: false,
                          parts: t.parts.map((p) => (p.type === "dax" ? { ...p, run: { ...p.run, at: new Date(p.run.at) } } : p.type === "estate" ? { ...p, call: { ...p.call, at: new Date(p.call.at) } } : p)),
                      }
                    : t,
            );
    } catch {
        return [];
    }
}

export function clearConversation(storage: Pick<Storage, "removeItem"> | undefined): void {
    try {
        storage?.removeItem(STORE_KEY);
    } catch {
        // Nothing to clear.
    }
}
