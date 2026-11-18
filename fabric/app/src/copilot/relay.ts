// The Ask page's link to its chat relay: plain HTTP for GitHub sign-in (GitHub's own endpoints don't allow
// browser calls, so the relay makes them and keeps nothing), and one WebSocket per conversation. The relay
// never runs a tool: each tool call comes here, runs in this page, and its answer goes back.

export interface ToolSpec {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
}

export interface DeviceStart {
    deviceCode: string;
    userCode: string;
    verificationUri: string;
    expiresIn: number;
    interval: number;
}

export type DevicePoll =
    | { status: "pending"; interval: number }
    | { status: "slow_down"; interval: number }
    | { status: "expired" }
    | { status: "denied" }
    | { status: "ok"; accessToken: string; expiresIn: number | null; refreshToken: string | null; refreshTokenExpiresIn: number | null }
    | { status: "error"; message: string };

export interface GitHubUser {
    login: string;
    name: string | null;
    avatarUrl: string | null;
}

export interface CopilotCheck {
    ok: boolean;
    login: string | null;
    /** The runtime's plan key: individual, individual_pro, business, enterprise, ... */
    plan: string | null;
    message?: string;
}

export interface RelayHealth {
    ok: boolean;
    version: string;
    signIn: "device" | "off";
    sessions?: number;
}

/** What the relay sends on a conversation's WebSocket (ask-relay/src/protocol.ts). */
export type RelayEvent =
    | { type: "ready"; sessionId: string; model: string | null; login: string | null; plan: string | null }
    | { type: "delta"; messageId: string; text: string }
    | { type: "message"; messageId: string; text: string }
    | { type: "tool_call"; callId: string; name: string; arguments: unknown }
    | { type: "tool_done"; callId: string }
    | { type: "usage"; model: string | null; inputTokens: number | null; outputTokens: number | null }
    | { type: "idle" }
    | { type: "error"; code: string; message: string; fatal: boolean }
    | { type: "pong" }
    | { type: "closed"; code: number; reason: string };

export class RelayError extends Error {
    readonly status: number;
    readonly code: string;
    constructor(message: string, status: number, code = "relay") {
        super(message);
        this.name = "RelayError";
        this.status = status;
        this.code = code;
    }
}

const HTTPS = /^https:\/\/[a-z0-9.-]+(:\d{1,5})?$/i;
const LOCAL = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/i;

/** The relay's base URL from the deploy-time settings: https, or a local relay during development. */
export function relayBase(value: unknown): string | null {
    const url = (typeof value === "string" ? value : "").trim().replace(/\/+$/, "");
    return HTTPS.test(url) || LOCAL.test(url) ? url : null;
}

export class RelayClient {
    constructor(
        readonly base: string,
        private readonly fetchImpl: typeof fetch = (input, init) => fetch(input, init),
    ) {}

    private async call<T>(path: string, init: RequestInit = {}, timeoutMs = 20000): Promise<T> {
        let response: Response;
        try {
            response = await this.fetchImpl(`${this.base}${path}`, { ...init, cache: "no-store", credentials: "omit", signal: AbortSignal.timeout(timeoutMs) });
        } catch (err) {
            const blocked = err instanceof TypeError;
            throw new RelayError(
                blocked
                    ? "The chat relay can't be reached from this page. It may be starting (try again in a few seconds), or a content security policy may block it."
                    : `The chat relay didn't answer: ${err instanceof Error ? err.message : String(err)}`,
                0,
                blocked ? "unreachable" : "timeout",
            );
        }
        const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
        if (!response.ok) {
            throw new RelayError(typeof body.message === "string" ? body.message : `The chat relay answered HTTP ${response.status}.`, response.status, typeof body.error === "string" ? body.error : "relay");
        }
        return body as T;
    }

    /** Also wakes a relay that scaled to zero: the first answer can take several seconds. */
    health(): Promise<RelayHealth> {
        return this.call<RelayHealth>("/healthz", {}, 45000);
    }

    startDeviceFlow(): Promise<DeviceStart> {
        return this.call<DeviceStart>("/auth/device", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    }

    pollDeviceFlow(deviceCode: string): Promise<DevicePoll> {
        return this.call<DevicePoll>("/auth/token", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ deviceCode }) });
    }

    refresh(refreshToken: string): Promise<DevicePoll> {
        return this.call<DevicePoll>("/auth/refresh", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ refreshToken }) });
    }

    user(token: string): Promise<GitHubUser> {
        return this.call<GitHubUser>("/auth/user", { headers: { Authorization: `Bearer ${token}` } });
    }

    /** Whether the account can use GitHub Copilot here, and its plan: the relay starts and removes a session, with no model call. */
    copilot(token: string): Promise<CopilotCheck> {
        return this.call<CopilotCheck>("/auth/copilot", { headers: { Authorization: `Bearer ${token}` } }, 45000);
    }

    chatUrl(): string {
        return `${this.base.replace(/^http/i, "ws")}/chat`;
    }
}

export interface ChatStart {
    token: string;
    systemMessage: string;
    tools: ToolSpec[];
    model?: string;
}

export interface SocketLike {
    readonly readyState: number;
    send(data: string): void;
    close(code?: number, reason?: string): void;
    onopen: ((ev: Event) => unknown) | null;
    onmessage: ((ev: MessageEvent) => unknown) | null;
    onclose: ((ev: CloseEvent) => unknown) | null;
    onerror: ((ev: Event) => unknown) | null;
}

/** One conversation: opens the WebSocket, starts the Copilot session, and passes events to the page. */
export class ChatConnection {
    private socket: SocketLike | null = null;
    private ping: ReturnType<typeof setInterval> | null = null;

    constructor(
        private readonly url: string,
        private readonly onEvent: (event: RelayEvent) => void,
        private readonly createSocket: (url: string) => SocketLike = (u) => new WebSocket(u) as unknown as SocketLike,
    ) {}

    /** Resolves once the relay says the session is ready; rejects on a refusal or a closed connection. */
    open(start: ChatStart): Promise<{ sessionId: string; model: string | null; login: string | null; plan: string | null }> {
        return new Promise((resolve, reject) => {
            let settled = false;
            const socket = this.createSocket(this.url);
            this.socket = socket;
            socket.onopen = () => {
                socket.send(JSON.stringify({ type: "start", ...start }));
                this.ping = setInterval(() => this.send({ type: "ping" }), 20000);
            };
            socket.onmessage = (ev) => {
                let event: RelayEvent;
                try {
                    event = JSON.parse(String(ev.data)) as RelayEvent;
                } catch {
                    return;
                }
                if (!settled && event.type === "ready") {
                    settled = true;
                    resolve({ sessionId: event.sessionId, model: event.model, login: event.login, plan: event.plan });
                } else if (!settled && event.type === "error" && event.fatal) {
                    settled = true;
                    reject(new RelayError(event.message, 0, event.code));
                }
                if (event.type !== "pong") this.onEvent(event);
            };
            socket.onerror = () => undefined;
            socket.onclose = (ev) => {
                this.stopPing();
                if (!settled) {
                    settled = true;
                    reject(
                        new RelayError(
                            ev.code === 1006
                                ? "The chat relay refused or dropped the connection. It may be starting, at its limit, or blocked by a content security policy."
                                : `The chat relay closed the connection (${ev.code}${ev.reason ? `: ${ev.reason}` : ""}).`,
                            0,
                            "closed",
                        ),
                    );
                }
                this.onEvent({ type: "closed", code: ev.code, reason: ev.reason });
            };
        });
    }

    private send(message: Record<string, unknown>): boolean {
        if (!this.socket || this.socket.readyState !== 1) return false;
        this.socket.send(JSON.stringify(message));
        return true;
    }

    ask(text: string): boolean {
        return this.send({ type: "user", text });
    }

    toolResult(callId: string, ok: boolean, result: string): boolean {
        return this.send({ type: "tool_result", callId, ok, result });
    }

    abort(): boolean {
        return this.send({ type: "abort" });
    }

    private stopPing(): void {
        if (this.ping) clearInterval(this.ping);
        this.ping = null;
    }

    close(): void {
        this.stopPing();
        const socket = this.socket;
        this.socket = null;
        if (socket) {
            socket.onclose = null;
            socket.close(1000, "done");
        }
    }
}
