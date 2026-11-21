// One Ask conversation: a Copilot session that runs as the viewer (their own GitHub token and Copilot plan),
// with only the page's tools. Copilot asks for a tool; the relay passes the call to the page and waits for its
// answer. The relay runs nothing itself, and the session has no built-in tools: no shell, no files, no web.
// https://github.com/microsoft/copilot-sdk/blob/main/docs/setup/multi-tenancy.md

import type { RelayConfig } from "./config.js";
import { ProtocolError, type ClientMessage, type ServerMessage, type ToolSpec } from "./protocol.js";

/** The part of a Copilot SDK session the bridge uses (CopilotSession in @microsoft/copilot-sdk). */
export interface SessionLike {
    readonly sessionId: string;
    on(eventType: string, handler: (event: { data: Record<string, unknown> }) => void): () => void;
    send(options: { prompt: string }): Promise<string>;
    abort(): Promise<void>;
    disconnect(): Promise<void>;
    /** The session's persisted history (CopilotSession.getEvents): read when a turn ends, so none of its text is lost. */
    getEvents?(): Promise<Array<{ type: string; data?: Record<string, unknown>; agentId?: string }>>;
    /** The session's GitHub account, as the runtime resolved it (experimental in the SDK). */
    readonly rpc?: { gitHubAuth?: { getStatus?: () => Promise<{ login?: string; copilotPlan?: string }> } };
}

/** What the relay logs when a turn ends (chat.turn.end): counts and lengths only, never content or tokens. */
export interface TurnSummary {
    ms: number;
    ended: "idle" | "error" | "closed";
    aborted: boolean;
    /** Tool calls passed to the page, and how many of them failed or timed out. */
    tools: number;
    failedTools: number;
    /** Assistant messages, and the characters of text they hold. */
    messages: number;
    textChars: number;
    /** The text of the model's final answer, as the dock counts it: after its last message that asked for a query (all text when none did). */
    finalTextChars: number;
    /** Per assistant message, in order, "<text characters>/<tool requests>" (the last 30). */
    rounds: string;
    /** Messages whose full text the page got from the session's history at the turn's end, not from the live events. */
    fromHistory: number;
    error?: string;
}

/** How long the end of a turn waits for the session's history; the page gets idle either way. */
export const HISTORY_READ_MS = 5000;

/**
 * The page's tools that add to an answer instead of querying: any other tool request is a query. The dock counts as the
 * answer only the text after a turn's last query, and text in the message that asks for a query comes before its rows.
 */
const ANSWER_TOOLS = new Set(["suggest_followups", "show_chart"]);

/** Who a token belongs to and its Copilot plan, as Copilot itself resolves them. */
export interface CopilotIdentity {
    login: string | null;
    copilotPlan: string | null;
}

/** The session's account, or nulls when the runtime doesn't say. */
export async function identityOf(session: SessionLike): Promise<CopilotIdentity> {
    try {
        const status = await session.rpc?.gitHubAuth?.getStatus?.();
        return { login: status?.login ?? null, copilotPlan: status?.copilotPlan ?? null };
    } catch {
        return { login: null, copilotPlan: null };
    }
}

export interface ToolHandlerInvocation {
    toolCallId: string;
    signal?: AbortSignal;
}

export interface SessionRequest {
    sessionId: string;
    token: string;
    model: string | undefined;
    systemMessage: string;
    tools: Array<ToolSpec & { handler: (args: unknown, invocation: ToolHandlerInvocation) => Promise<ToolAnswer> }>;
}

export interface ToolAnswer {
    textResultForLlm: string;
    resultType: "success" | "failure" | "timeout";
    error?: string;
}

/** Creates SDK sessions; the server wires it to CopilotClient, and the tests to a fake. */
export interface SessionHost {
    create(request: SessionRequest): Promise<SessionLike>;
    remove(sessionId: string): Promise<void>;
    /** Checks that a token can use GitHub Copilot, with no model call: a session with no tools, created and removed. */
    probe(token: string): Promise<CopilotIdentity>;
}

interface PendingCall {
    resolve: (answer: ToolAnswer) => void;
    timer: NodeJS.Timeout;
}

interface Round {
    text: number;
    streamed: number;
    tools: number;
    /** Tool requests that query (any tool but ANSWER_TOOLS). */
    queries: number;
}

interface TurnState {
    started: number;
    userMessageId: string | null;
    rounds: Map<string, Round>;
    tools: number;
    failedTools: number;
    aborted: boolean;
    fromHistory: number;
    ending: boolean;
}

export type BridgeState = "new" | "starting" | "ready" | "closed";

export class AskBridge {
    private session: SessionLike | null = null;
    private readonly pending = new Map<string, PendingCall>();
    private readonly unsubscribe: Array<() => void> = [];
    /** Each assistant message's text as the page last got it, so no text is sent twice. */
    private readonly forwarded = new Map<string, number>();
    private turn: TurnState | null = null;
    private turns = 0;
    private busy = false;
    private expiry: NodeJS.Timeout | null = null;
    state: BridgeState = "new";

    constructor(
        private readonly host: SessionHost,
        private readonly config: Pick<RelayConfig, "maxTurns" | "sessionMaxMinutes" | "toolTimeoutSeconds" | "defaultModel">,
        private readonly send: (message: ServerMessage) => void,
        private readonly newId: () => string,
        private readonly onExpire: () => void = () => undefined,
        private readonly onTurnEnd: (summary: TurnSummary) => void = () => undefined,
    ) {}

    async handle(message: ClientMessage): Promise<void> {
        switch (message.type) {
            case "ping":
                this.send({ type: "pong" });
                return;
            case "start":
                return this.start(message);
            case "user":
                return this.ask(message.text);
            case "tool_result":
                this.answer(message.callId, message.ok, message.result);
                return;
            case "abort":
                if (this.session) await this.session.abort();
                return;
        }
    }

    private async start(message: Extract<ClientMessage, { type: "start" }>): Promise<void> {
        if (this.state !== "new") throw new ProtocolError("already_started", "This conversation has already started.");
        this.state = "starting";
        const model = message.model ?? (this.config.defaultModel || undefined);
        const tools = message.tools.map((tool) => ({
            ...tool,
            handler: (args: unknown, invocation: ToolHandlerInvocation) => this.callPage(tool.name, args, invocation),
        }));
        let session: SessionLike;
        try {
            session = await this.host.create({ sessionId: `ask-${this.newId()}`, token: message.token, model, systemMessage: message.systemMessage, tools });
        } catch (err) {
            this.state = "new";
            throw new ProtocolError("session_failed", describeSessionError(err));
        }
        if (this.state !== "starting") {
            // The page went away while the session was being created.
            await session.disconnect().catch(() => undefined);
            await this.host.remove(session.sessionId).catch(() => undefined);
            return;
        }
        this.session = session;
        this.subscribe(session);
        this.state = "ready";
        this.expiry = setTimeout(() => {
            this.send({ type: "error", code: "session_expired", message: `This conversation reached its ${this.config.sessionMaxMinutes}-minute limit. Start a new one.`, fatal: true });
            this.onExpire();
        }, this.config.sessionMaxMinutes * 60_000);
        this.expiry.unref?.();
        const who = await identityOf(session);
        this.send({ type: "ready", sessionId: session.sessionId, model: model ?? null, login: who.login, plan: who.copilotPlan });
    }

    private subscribe(session: SessionLike): void {
        const on = (type: string, handler: (data: Record<string, unknown>) => void) => this.unsubscribe.push(session.on(type, (event) => handler(event.data ?? {})));
        on("assistant.message_delta", (d) => {
            if (typeof d.deltaContent === "string" && d.deltaContent) {
                const messageId = String(d.messageId ?? "");
                const round = this.round(messageId);
                if (round) round.streamed += d.deltaContent.length;
                this.send({ type: "delta", messageId, text: d.deltaContent });
            }
        });
        on("assistant.message", (d) => this.message(d));
        on("tool.execution_complete", (d) => {
            if (typeof d.toolCallId === "string") this.send({ type: "tool_done", callId: d.toolCallId });
        });
        on("assistant.usage", (d) => {
            this.send({
                type: "usage",
                model: typeof d.model === "string" ? d.model : null,
                inputTokens: typeof d.inputTokens === "number" ? d.inputTokens : null,
                outputTokens: typeof d.outputTokens === "number" ? d.outputTokens : null,
            });
        });
        on("assistant.idle", (d) => {
            if (this.turn && d.aborted === true) this.turn.aborted = true;
        });
        on("session.error", (d) => {
            const code = typeof d.errorType === "string" ? d.errorType : "copilot_error";
            this.finishTurn("error", code);
            this.busy = false;
            this.send({ type: "error", code, message: describeCopilotError(d), fatal: false });
        });
        on("session.idle", () => {
            void this.endTurn();
        });
    }

    /** One assistant message: counted for the turn, and its text sent to the page unless the page has it already. */
    private message(d: Record<string, unknown>): boolean {
        const messageId = String(d.messageId ?? "");
        const content = typeof d.content === "string" ? d.content : "";
        const round = this.round(messageId);
        if (round) {
            const requests: unknown[] = Array.isArray(d.toolRequests) ? d.toolRequests : [];
            round.text = content.trim().length;
            round.tools = requests.length;
            round.queries = requests.filter((r) => !ANSWER_TOOLS.has(String((r as { name?: unknown } | null)?.name ?? ""))).length;
        }
        if (!content.trim() || this.forwarded.get(messageId) === content.length) return false;
        this.forwarded.set(messageId, content.length);
        this.send({ type: "message", messageId, text: content });
        return true;
    }

    private round(messageId: string): Round | null {
        const turn = this.turn;
        if (!turn) return null;
        let round = turn.rounds.get(messageId);
        if (!round) {
            round = { text: 0, streamed: 0, tools: 0, queries: 0 };
            turn.rounds.set(messageId, round);
        }
        return round;
    }

    /**
     * The end of a turn (session.idle). Before the page hears it, every assistant message of the turn is read back from
     * the session's history and any text the live events didn't deliver (a message that came only as deltas, or after
     * idle) is sent, so the page always ends a turn with all of the model's text. Bounded: idle follows either way.
     */
    private async endTurn(): Promise<void> {
        const turn = this.turn;
        if (turn?.ending) return;
        if (turn && this.session?.getEvents) {
            turn.ending = true;
            turn.fromHistory = await this.fromHistory(turn, this.session);
        }
        if (this.state === "closed") return;
        if (turn && this.turn === turn) this.finishTurn("idle");
        this.busy = false;
        this.send({ type: "idle" });
    }

    private async fromHistory(turn: TurnState, session: SessionLike): Promise<number> {
        let timer: NodeJS.Timeout | undefined;
        try {
            const events = await Promise.race([
                session.getEvents!(),
                new Promise<never>((_, reject) => {
                    timer = setTimeout(() => reject(new Error("history timeout")), HISTORY_READ_MS);
                    timer.unref?.();
                }),
            ]);
            if (this.state === "closed" || this.turn !== turn) return 0;
            // This turn starts at the user message that asked it (the last one, when the runtime doesn't say which).
            let from = -1;
            for (let i = events.length - 1; i >= 0; i--) {
                if (events[i].type !== "user.message") continue;
                if (from < 0) from = i;
                if (turn.userMessageId && events[i].data?.messageId === turn.userMessageId) {
                    from = i;
                    break;
                }
            }
            let sent = 0;
            for (const event of events.slice(from + 1)) {
                const d = event.data ?? {};
                if (event.type !== "assistant.message" || event.agentId) continue;
                if (turn.userMessageId && typeof d.originatingMessageId === "string" && d.originatingMessageId !== turn.userMessageId) continue;
                if (this.message(d)) sent += 1;
            }
            return sent;
        } catch {
            return 0;
        } finally {
            if (timer) clearTimeout(timer);
        }
    }

    private finishTurn(ended: TurnSummary["ended"], error?: string): void {
        const turn = this.turn;
        if (!turn) return;
        this.turn = null;
        const rounds = [...turn.rounds.values()];
        const chars = (r: Round) => r.text || r.streamed;
        // The answer is the text after the last message that asked for a query, as the dock counts it (ANSWER_TOOLS).
        let lastQuery = -1;
        rounds.forEach((r, i) => {
            if (r.queries > 0) lastQuery = i;
        });
        const summary: TurnSummary = {
            ms: Date.now() - turn.started,
            ended,
            aborted: turn.aborted,
            tools: turn.tools,
            failedTools: turn.failedTools,
            messages: rounds.length,
            textChars: rounds.reduce((n, r) => n + chars(r), 0),
            finalTextChars: rounds.slice(lastQuery + 1).reduce((n, r) => n + chars(r), 0),
            rounds: rounds
                .slice(-30)
                .map((r) => `${chars(r)}/${r.tools}`)
                .join(" "),
            fromHistory: turn.fromHistory,
            ...(error ? { error } : {}),
        };
        try {
            this.onTurnEnd(summary);
        } catch {
            // Logging never breaks a conversation.
        }
    }

    private async ask(text: string): Promise<void> {
        if (this.state !== "ready" || !this.session) throw new ProtocolError("not_started", "Start the conversation first.");
        if (this.busy) throw new ProtocolError("busy", "Copilot is still answering the last question. Wait for it, or stop it.");
        if (this.turns >= this.config.maxTurns) throw new ProtocolError("turn_limit", `This conversation reached its ${this.config.maxTurns}-question limit. Start a new one.`);
        this.turns += 1;
        this.busy = true;
        const turn: TurnState = { started: Date.now(), userMessageId: null, rounds: new Map(), tools: 0, failedTools: 0, aborted: false, fromHistory: 0, ending: false };
        this.turn = turn;
        try {
            const messageId = await this.session.send({ prompt: text });
            if (typeof messageId === "string" && messageId) turn.userMessageId = messageId;
        } catch (err) {
            this.finishTurn("error", "send_failed");
            this.busy = false;
            throw new ProtocolError("send_failed", describeSessionError(err));
        }
    }

    /** Passes one tool call to the page and waits for its answer, its timeout, or the end of the conversation. */
    private callPage(name: string, args: unknown, invocation: ToolHandlerInvocation): Promise<ToolAnswer> {
        const callId = invocation.toolCallId || this.newId();
        const turn = this.turn;
        if (turn) turn.tools += 1;
        return new Promise<ToolAnswer>((resolve) => {
            const timer = setTimeout(() => {
                this.pending.delete(callId);
                if (turn) turn.failedTools += 1;
                resolve({ textResultForLlm: `The ${name} tool didn't answer within ${this.config.toolTimeoutSeconds} seconds.`, resultType: "timeout" });
            }, this.config.toolTimeoutSeconds * 1000);
            this.pending.set(callId, {
                resolve: (answer) => {
                    if (turn && answer.resultType !== "success") turn.failedTools += 1;
                    resolve(answer);
                },
                timer,
            });
            invocation.signal?.addEventListener("abort", () => this.settle(callId, { textResultForLlm: "The tool call was cancelled.", resultType: "failure" }), { once: true });
            this.send({ type: "tool_call", callId, name, arguments: args ?? {} });
        });
    }

    private settle(callId: string, answer: ToolAnswer): boolean {
        const call = this.pending.get(callId);
        if (!call) return false;
        clearTimeout(call.timer);
        this.pending.delete(callId);
        call.resolve(answer);
        return true;
    }

    private answer(callId: string, ok: boolean, result: string): void {
        // A late or unknown answer is ignored: its call already timed out or was cancelled.
        this.settle(callId, ok ? { textResultForLlm: result, resultType: "success" } : { textResultForLlm: result, resultType: "failure", error: result.slice(0, 500) });
    }

    get pendingCalls(): number {
        return this.pending.size;
    }

    async close(): Promise<void> {
        if (this.state === "closed") return;
        this.state = "closed";
        if (this.expiry) clearTimeout(this.expiry);
        this.finishTurn("closed");
        for (const id of [...this.pending.keys()]) this.settle(id, { textResultForLlm: "The page closed the conversation.", resultType: "failure" });
        for (const off of this.unsubscribe.splice(0)) off();
        const session = this.session;
        this.session = null;
        if (session) {
            await session.disconnect().catch(() => undefined);
            // The transcript holds the conversation's data: delete it with the conversation.
            await this.host.remove(session.sessionId).catch(() => undefined);
        }
    }
}

/** Plain-language text for a failure to create or use a session; never includes the token. */
export function describeSessionError(err: unknown): string {
    const message = err instanceof Error ? err.message : String(err);
    if (/401|unauthori[sz]ed|bad credentials|token/i.test(message)) {
        return "GitHub Copilot didn't accept this GitHub sign-in. Sign in to GitHub again, with the account that has your Copilot license.";
    }
    if (/403|forbidden|not (been )?(granted|enabled)|copilot.*(access|seat|subscription|policy)/i.test(message)) {
        return "This GitHub account can't use GitHub Copilot here. It needs a Copilot license, and an organization's policy may need to allow it.";
    }
    if (/model/i.test(message)) return `Copilot couldn't use the requested model: ${redact(message)}`;
    return `Copilot couldn't start: ${redact(message)}`;
}

function describeCopilotError(data: Record<string, unknown>): string {
    const message = typeof data.message === "string" ? data.message : "Copilot reported an error.";
    return redact(message);
}

/** Removes anything shaped like a GitHub token from text the relay sends or logs. */
export function redact(text: string): string {
    return text.replace(/\b(gh[oupsr]_[A-Za-z0-9_]{10,}|github_pat_[A-Za-z0-9_]{10,})\b/g, "[redacted]").slice(0, 600);
}
