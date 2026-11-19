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
    /** The session's GitHub account, as the runtime resolved it (experimental in the SDK). */
    readonly rpc?: { gitHubAuth?: { getStatus?: () => Promise<{ login?: string; copilotPlan?: string }> } };
}

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

export type BridgeState = "new" | "starting" | "ready" | "closed";

export class AskBridge {
    private session: SessionLike | null = null;
    private readonly pending = new Map<string, PendingCall>();
    private readonly unsubscribe: Array<() => void> = [];
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
            if (typeof d.deltaContent === "string" && d.deltaContent) this.send({ type: "delta", messageId: String(d.messageId ?? ""), text: d.deltaContent });
        });
        on("assistant.message", (d) => {
            if (typeof d.content === "string" && d.content.trim()) this.send({ type: "message", messageId: String(d.messageId ?? ""), text: d.content });
        });
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
        on("session.error", (d) => {
            this.busy = false;
            this.send({ type: "error", code: typeof d.errorType === "string" ? d.errorType : "copilot_error", message: describeCopilotError(d), fatal: false });
        });
        on("session.idle", () => {
            this.busy = false;
            this.send({ type: "idle" });
        });
    }

    private async ask(text: string): Promise<void> {
        if (this.state !== "ready" || !this.session) throw new ProtocolError("not_started", "Start the conversation first.");
        if (this.busy) throw new ProtocolError("busy", "Copilot is still answering the last question. Wait for it, or stop it.");
        if (this.turns >= this.config.maxTurns) throw new ProtocolError("turn_limit", `This conversation reached its ${this.config.maxTurns}-question limit. Start a new one.`);
        this.turns += 1;
        this.busy = true;
        try {
            await this.session.send({ prompt: text });
        } catch (err) {
            this.busy = false;
            throw new ProtocolError("send_failed", describeSessionError(err));
        }
    }

    /** Passes one tool call to the page and waits for its answer, its timeout, or the end of the conversation. */
    private callPage(name: string, args: unknown, invocation: ToolHandlerInvocation): Promise<ToolAnswer> {
        const callId = invocation.toolCallId || this.newId();
        return new Promise<ToolAnswer>((resolve) => {
            const timer = setTimeout(() => {
                this.pending.delete(callId);
                resolve({ textResultForLlm: `The ${name} tool didn't answer within ${this.config.toolTimeoutSeconds} seconds.`, resultType: "timeout" });
            }, this.config.toolTimeoutSeconds * 1000);
            this.pending.set(callId, { resolve, timer });
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
