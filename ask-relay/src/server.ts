// The relay's HTTP and WebSocket server. Routes:
//   GET  /healthz       readiness, for the page's warm-up and the platform's probes
//   POST /auth/device   starts GitHub's device flow (the code the viewer types at github.com/login/device)
//   POST /auth/token    polls it; returns the viewer's token to the page, which keeps it
//   POST /auth/refresh  renews an expiring token (device-flow tokens refresh without a client secret)
//   GET  /auth/user     the GitHub account a token belongs to
//   GET  /auth/copilot  whether that account can use GitHub Copilot here, and its plan (no model call)
//   WS   /chat          one Copilot conversation (protocol.ts)
// Only the configured origins are served: CORS for HTTP, the Origin header for WebSocket. The relay stores nothing:
// no token, no question, no answer, and no tool data; it logs counts and durations only.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import { WebSocketServer, type WebSocket } from "ws";

import { AskBridge, describeSessionError, redact, type SessionHost } from "./bridge.js";
import { loadConfig, type RelayConfig } from "./config.js";
import { getUser, GitHubError, pollDeviceFlow, refreshToken, startDeviceFlow, type FetchLike } from "./github.js";
import { LIMITS, parseClientMessage, ProtocolError, type ServerMessage } from "./protocol.js";

export interface RelayDeps {
    host: SessionHost;
    fetch: FetchLike;
    log?: (event: string, fields?: Record<string, unknown>) => void;
    now?: () => number;
    /** How long a WebSocket may wait before its start (START_DEADLINE_MS); shorter in tests. */
    startDeadlineMs?: number;
}

const JSON_LIMIT = 16 * 1024;
const PING_MS = 25_000;
const IDLE_MS = 15 * 60_000;
/** A WebSocket that hasn't sent its start by then is closed: until it starts, it holds nothing for anyone. */
export const START_DEADLINE_MS = 10_000;
/** Open WebSockets per client address, started or not (a viewer's tabs). */
export const MAX_SOCKETS_PER_CLIENT = 4;
/** Copilot checks (/auth/copilot) running at once, in all and per client address: each one starts a session. */
export const MAX_PROBES = 4;
export const MAX_PROBES_PER_CLIENT = 1;
/** Client addresses a rate limiter counts at once. */
export const MAX_LIMITER_KEYS = 10_000;

/** A fixed-window counter per key (the client's address), so one client can't flood GitHub or the runtime. */
export class RateLimiter {
    private readonly hits = new Map<string, { start: number; count: number }>();
    constructor(
        private readonly limit: number,
        private readonly windowMs: number,
        private readonly now: () => number,
        private readonly maxKeys = MAX_LIMITER_KEYS,
    ) {}
    allow(key: string): boolean {
        const t = this.now();
        const hit = this.hits.get(key);
        if (hit && t - hit.start < this.windowMs) {
            hit.count += 1;
            return hit.count <= this.limit;
        }
        if (!hit && this.hits.size >= this.maxKeys) {
            // Only windows that ended are forgotten; while every counted window is live, a new client waits.
            for (const [k, h] of this.hits) if (t - h.start >= this.windowMs) this.hits.delete(k);
            if (this.hits.size >= this.maxKeys) return false;
        }
        this.hits.set(key, { start: t, count: 1 });
        return true;
    }
    get size(): number {
        return this.hits.size;
    }
}

/**
 * The client's address. Container Apps' ingress appends the address it saw as the last X-Forwarded-For entry;
 * entries to its left come from the client, which can write anything there.
 */
export function clientKey(req: Pick<IncomingMessage, "headers" | "socket">): string {
    const entries = String(req.headers["x-forwarded-for"] ?? "")
        .split(",")
        .map((entry) => entry.trim())
        .filter(Boolean);
    return entries[entries.length - 1] || req.socket.remoteAddress || "unknown";
}

/** The request's path without its query, as sent. new URL() throws on targets such as //x:a, and nothing here may throw. */
export function pathOf(target: string | undefined): string {
    const raw = target ?? "/";
    const query = raw.indexOf("?");
    return query >= 0 ? raw.slice(0, query) : raw;
}

function originOf(req: IncomingMessage): string | null {
    const origin = req.headers.origin;
    return typeof origin === "string" && origin ? origin.toLowerCase().replace(/\/+$/, "") : null;
}

function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
        let size = 0;
        const chunks: Buffer[] = [];
        req.on("data", (chunk: Buffer) => {
            size += chunk.length;
            if (size > JSON_LIMIT) {
                reject(new ProtocolError("too_large", "The request body is too large."));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on("end", () => {
            if (chunks.length === 0) return resolve({});
            try {
                const value = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
                resolve(typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {});
            } catch {
                reject(new ProtocolError("bad_message", "The request body isn't JSON."));
            }
        });
        req.on("error", reject);
    });
}

function bearer(req: IncomingMessage): string | null {
    const header = String(req.headers.authorization ?? "");
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    return match && LIMITS.token.test(match[1]) ? match[1] : null;
}

export function createRelay(config: RelayConfig, deps: RelayDeps): { server: Server; sessions: () => number; close: () => Promise<void> } {
    const log = deps.log ?? ((event: string, fields: Record<string, unknown> = {}) => console.log(JSON.stringify({ at: new Date().toISOString(), event, ...fields })));
    const now = deps.now ?? (() => Date.now());
    const authLimiter = new RateLimiter(40, 60_000, now);
    const chatLimiter = new RateLimiter(12, 60_000, now);
    /** Every open conversation socket's bridge, and the ones that started a session: only those count against maxSessions. */
    const bridges = new Set<AskBridge>();
    const started = new Set<AskBridge>();
    const socketsByClient = new Map<string, number>();
    const probesByClient = new Map<string, number>();
    let probesRunning = 0;
    const checks = new Map<string, { at: number; value: Promise<Record<string, unknown>> }>();
    const count = (map: Map<string, number>, key: string, delta: number) => {
        const next = (map.get(key) ?? 0) + delta;
        if (next > 0) map.set(key, next);
        else map.delete(key);
    };

    /**
     * Whether a token can use GitHub Copilot here, with its plan; cached for 10 minutes by the token's hash. Each new
     * check starts a session, so few run at once: null means the relay is busy checking others.
     */
    const copilotCheck = (token: string, client: string): Promise<Record<string, unknown>> | null => {
        const key = createHash("sha256").update(token).digest("hex");
        const hit = checks.get(key);
        if (hit && now() - hit.at < 10 * 60_000) return hit.value;
        if (probesRunning >= MAX_PROBES || (probesByClient.get(client) ?? 0) >= MAX_PROBES_PER_CLIENT) return null;
        probesRunning += 1;
        count(probesByClient, client, 1);
        const value = deps.host
            .probe(token)
            .then(
                (who) => ({ ok: true, login: who.login, plan: who.copilotPlan }),
                (err: unknown) => ({ ok: false, login: null, plan: null, message: describeSessionError(err) }),
            )
            .finally(() => {
                probesRunning -= 1;
                count(probesByClient, client, -1);
            });
        checks.set(key, { at: now(), value });
        if (checks.size > 1000) checks.delete(checks.keys().next().value as string);
        return value;
    };

    const send = (res: ServerResponse, status: number, body: unknown, origin: string | null) => {
        const headers: Record<string, string> = {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        };
        if (origin && config.allowedOrigins.has(origin)) {
            headers["Access-Control-Allow-Origin"] = origin;
            headers.Vary = "Origin";
        }
        res.writeHead(status, headers);
        res.end(JSON.stringify(body));
    };

    const handleHttp = (req: IncomingMessage, res: ServerResponse): void => {
        const origin = originOf(req);
        const route = `${req.method} ${pathOf(req.url)}`;
        if (req.method === "OPTIONS") {
            if (!origin || !config.allowedOrigins.has(origin)) {
                res.writeHead(403, { "Cache-Control": "no-store" });
                res.end();
                return;
            }
            res.writeHead(204, {
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Authorization, Content-Type",
                "Access-Control-Max-Age": "600",
                Vary: "Origin",
                "Cache-Control": "no-store",
            });
            res.end();
            return;
        }
        if (route === "GET /healthz") {
            send(res, 200, { ok: true, version: config.version, signIn: config.githubClientId ? "device" : "off", sessions: started.size, maxSessions: config.maxSessions }, origin);
            return;
        }
        // Every other route serves only the configured origins; a request without an Origin header isn't from the page.
        if (!origin || !config.allowedOrigins.has(origin)) {
            send(res, 403, { error: "origin_not_allowed", message: "This relay serves only its own Insights app." }, null);
            return;
        }
        if (!authLimiter.allow(clientKey(req))) {
            send(res, 429, { error: "rate_limited", message: "Too many requests. Wait a minute and try again." }, origin);
            return;
        }
        const handle = async () => {
            if (route === "POST /auth/device" || route === "POST /auth/token" || route === "POST /auth/refresh") {
                if (!config.githubClientId) {
                    send(res, 503, { error: "sign_in_off", message: "GitHub sign-in isn't set up on this relay (GITHUB_CLIENT_ID)." }, origin);
                    return;
                }
                const body = await readJson(req);
                if (route === "POST /auth/device") {
                    send(res, 200, await startDeviceFlow(deps.fetch, config.githubClientId, config.githubScopes), origin);
                    return;
                }
                if (route === "POST /auth/refresh") {
                    const refresh = typeof body.refreshToken === "string" && LIMITS.token.test(body.refreshToken) ? body.refreshToken : "";
                    if (!refresh) {
                        send(res, 400, { error: "bad_message", message: "refreshToken is missing." }, origin);
                        return;
                    }
                    const renewed = await refreshToken(deps.fetch, config.githubClientId, refresh);
                    log("auth.refresh", { status: renewed.status });
                    send(res, 200, renewed, origin);
                    return;
                }
                const deviceCode = typeof body.deviceCode === "string" && body.deviceCode.length <= 200 ? body.deviceCode : "";
                if (!deviceCode) {
                    send(res, 400, { error: "bad_message", message: "deviceCode is missing." }, origin);
                    return;
                }
                const result = await pollDeviceFlow(deps.fetch, config.githubClientId, deviceCode);
                log("auth.poll", { status: result.status });
                send(res, 200, result, origin);
                return;
            }
            if (route === "GET /auth/user") {
                const token = bearer(req);
                if (!token) {
                    send(res, 401, { error: "bad_token", message: "Sign in to GitHub first." }, origin);
                    return;
                }
                send(res, 200, await getUser(deps.fetch, token), origin);
                return;
            }
            if (route === "GET /auth/copilot") {
                const token = bearer(req);
                if (!token) {
                    send(res, 401, { error: "bad_token", message: "Sign in to GitHub first." }, origin);
                    return;
                }
                const check = copilotCheck(token, clientKey(req));
                if (!check) {
                    send(res, 503, { error: "busy", message: "The relay is checking other GitHub accounts. Try again in a few seconds." }, origin);
                    return;
                }
                send(res, 200, await check, origin);
                return;
            }
            send(res, 404, { error: "not_found", message: "No such route." }, origin);
        };
        handle().catch((err: unknown) => {
            if (err instanceof ProtocolError) {
                send(res, 400, { error: err.code, message: err.message }, origin);
            } else if (err instanceof GitHubError) {
                send(res, err.status >= 400 && err.status < 600 ? err.status : 502, { error: "github", message: err.message }, origin);
            } else {
                log("http.error", { route, message: redact(err instanceof Error ? err.message : String(err)) });
                send(res, 502, { error: "relay_error", message: "The relay couldn't reach GitHub. Try again." }, origin);
            }
        });
    };

    const server = createServer((req, res) => {
        try {
            handleHttp(req, res);
        } catch (err) {
            log("http.error", { message: redact(err instanceof Error ? err.message : String(err)) });
            if (!res.headersSent) send(res, 400, { error: "bad_request", message: "The relay couldn't read this request." }, null);
            else res.destroy();
        }
    });

    const wss = new WebSocketServer({ noServer: true, maxPayload: LIMITS.frame });

    server.on("upgrade", (req, socket, head) => {
        // Until ws takes it over, the socket has no error listener of its own, and an unhandled one stops the process.
        const onSocketError = () => socket.destroy();
        socket.on("error", onSocketError);
        const refuse = (status: number, reason: string) => {
            if (!socket.destroyed) socket.write(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
            socket.destroy();
        };
        try {
            const origin = originOf(req);
            const client = clientKey(req);
            if (pathOf(req.url) !== "/chat") return refuse(404, "Not Found");
            if (!origin || !config.allowedOrigins.has(origin)) return refuse(403, "Forbidden");
            if (!chatLimiter.allow(client)) return refuse(429, "Too Many Requests");
            if ((socketsByClient.get(client) ?? 0) >= MAX_SOCKETS_PER_CLIENT) return refuse(429, "Too Many Requests");
            if (started.size >= config.maxSessions) return refuse(503, "Service Unavailable");
            wss.handleUpgrade(req, socket, head, (ws) => {
                socket.removeListener("error", onSocketError);
                attach(ws, client);
            });
        } catch (err) {
            log("chat.upgrade_error", { message: redact(err instanceof Error ? err.message : String(err)) });
            refuse(400, "Bad Request");
        }
    });

    function attach(ws: WebSocket, client: string): void {
        const opened = now();
        let lastSeen = now();
        let alive = true;
        count(socketsByClient, client, 1);
        const out = (message: ServerMessage) => {
            // The conversation's own traffic is activity; pings and pongs aren't, so a socket that only pings goes idle.
            if (message.type !== "pong") lastSeen = now();
            if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message));
        };
        const bridge = new AskBridge(deps.host, config, out, () => randomUUID(), () => ws.close(4000, "expired"));
        bridges.add(bridge);
        log("chat.open", { sockets: bridges.size, sessions: started.size });

        // A socket counts against maxSessions only from its start; one that never starts is closed, so it holds no place.
        const deadline = setTimeout(() => {
            if (!started.has(bridge)) ws.close(4001, "no start");
        }, deps.startDeadlineMs ?? START_DEADLINE_MS);
        deadline.unref?.();

        const timer = setInterval(() => {
            if (!alive || now() - lastSeen > IDLE_MS) {
                ws.terminate();
                return;
            }
            alive = false;
            ws.ping();
        }, PING_MS);
        timer.unref?.();
        ws.on("pong", () => {
            alive = true;
        });

        ws.on("message", (data, isBinary) => {
            if (isBinary) {
                out({ type: "error", code: "bad_message", message: "Send text frames only.", fatal: false });
                return;
            }
            let message;
            try {
                message = parseClientMessage(data.toString());
            } catch (err) {
                const e = err instanceof ProtocolError ? err : new ProtocolError("bad_message", "The message couldn't be read.");
                out({ type: "error", code: e.code, message: e.message, fatal: false });
                return;
            }
            if (message.type !== "ping") lastSeen = now();
            if (message.type === "start" && !started.has(bridge)) {
                if (started.size >= config.maxSessions) {
                    out({ type: "error", code: "relay_busy", message: "The chat relay is at its limit of conversations. Try again in a minute.", fatal: true });
                    ws.close(4003, "relay busy");
                    return;
                }
                started.add(bridge);
                clearTimeout(deadline);
            }
            bridge.handle(message).catch((err: unknown) => {
                const e = err instanceof ProtocolError ? err : new ProtocolError("relay_error", redact(err instanceof Error ? err.message : String(err)));
                const fatal = message.type === "start" && e.code !== "already_started";
                if (fatal) {
                    started.delete(bridge);
                    log("chat.start_failed", { code: e.code });
                }
                out({ type: "error", code: e.code, message: e.message, fatal });
                // A conversation that couldn't start keeps nothing open: its socket closes, and its place is free.
                if (fatal) ws.close(4002, "start failed");
            });
            if (message.type === "user") log("chat.turn", {});
        });

        ws.on("close", () => {
            clearTimeout(deadline);
            clearInterval(timer);
            bridges.delete(bridge);
            started.delete(bridge);
            count(socketsByClient, client, -1);
            void bridge.close();
            log("chat.close", { seconds: Math.round((now() - opened) / 1000), sessions: started.size });
        });
        ws.on("error", () => ws.terminate());
    }

    const close = async () => {
        for (const client of wss.clients) client.close(1001, "relay stopping");
        await Promise.all([...bridges].map((b) => b.close()));
        await new Promise<void>((resolve) => server.close(() => resolve()));
    };

    return { server, sessions: () => started.size, close };
}

async function main(): Promise<void> {
    const config = loadConfig();
    // One bad request or a library's stray error must not drop every conversation: log it and keep serving.
    const survive = (event: string) => (err: unknown) =>
        console.error(JSON.stringify({ at: new Date().toISOString(), event, message: redact(err instanceof Error ? err.message : String(err)) }));
    process.on("uncaughtException", survive("relay.uncaught_exception"));
    process.on("unhandledRejection", survive("relay.unhandled_rejection"));
    const { createCopilotHost } = await import("./copilot.js");
    const host = createCopilotHost(config);
    await host.start();
    const relay = createRelay(config, { host, fetch: (input, init) => fetch(input, init) });
    relay.server.listen(config.port, () => {
        console.log(
            JSON.stringify({
                at: new Date().toISOString(),
                event: "relay.listening",
                port: config.port,
                version: config.version,
                origins: config.allowedOrigins.size,
                signIn: config.githubClientId ? "device" : "off",
            }),
        );
    });
    const stop = async () => {
        await relay.close();
        await host.stop().catch(() => undefined);
        process.exit(0);
    };
    process.once("SIGTERM", () => void stop());
    process.once("SIGINT", () => void stop());
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
    main().catch((err: unknown) => {
        console.error(JSON.stringify({ at: new Date().toISOString(), event: "relay.failed", message: redact(err instanceof Error ? err.message : String(err)) }));
        process.exit(1);
    });
}
