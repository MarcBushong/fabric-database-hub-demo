import { afterEach, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import type { AddressInfo } from "node:net";
import { connect } from "node:net";
import WebSocket from "ws";

import type { SessionHost, SessionLike } from "../src/bridge.js";
import type { RelayConfig } from "../src/config.js";
import { clientKey, createRelay, MAX_SOCKETS_PER_CLIENT, RateLimiter } from "../src/server.js";

const APP = "https://dbhub-westus3.webapp.fabricapps.net";
const fakeToken = () => ["gho", "C".repeat(36)].join("_");

const config: RelayConfig = {
    port: 0,
    allowedOrigins: new Set([APP]),
    githubClientId: "Iv1.0123456789abcdef",
    githubScopes: "",
    maxSessions: 2,
    maxTurns: 5,
    sessionMaxMinutes: 60,
    toolTimeoutSeconds: 30,
    copilotHome: "/tmp/x",
    defaultModel: "",
    version: "test",
};

const host: SessionHost = {
    async create(request) {
        const session: SessionLike = {
            sessionId: request.sessionId,
            on: () => () => undefined,
            send: async () => "m",
            abort: async () => undefined,
            disconnect: async () => undefined,
        };
        return session;
    },
    remove: async () => undefined,
    probe: async () => ({ login: "octo", copilotPlan: "enterprise" }),
};

function githubFake(calls: string[]) {
    return async (url: string, init?: RequestInit) => {
        calls.push(`${init?.method ?? "GET"} ${url}`);
        if (url.endsWith("/login/device/code")) {
            return new Response(JSON.stringify({ device_code: "dc", user_code: "ABCD-1234", verification_uri: "https://github.com/login/device", expires_in: 900, interval: 5 }), { status: 200 });
        }
        if (url.endsWith("/login/oauth/access_token")) {
            const body = new URLSearchParams(String(init?.body));
            if (body.get("device_code") === "pending") return new Response(JSON.stringify({ error: "authorization_pending", interval: 5 }), { status: 200 });
            return new Response(JSON.stringify({ access_token: fakeToken(), token_type: "bearer", scope: "" }), { status: 200 });
        }
        if (url.endsWith("/user")) return new Response(JSON.stringify({ login: "octo", name: "Octo Cat", avatar_url: "https://avatars.example/octo" }), { status: 200 });
        return new Response("{}", { status: 404 });
    };
}

let stop: (() => Promise<void>) | null = null;
afterEach(async () => {
    await stop?.();
    stop = null;
});

async function listen(calls: string[] = [], options: { host?: SessionHost; startDeadlineMs?: number } = {}) {
    const relay = createRelay(config, { host: options.host ?? host, fetch: githubFake(calls), log: () => undefined, startDeadlineMs: options.startDeadlineMs });
    await new Promise<void>((resolve) => relay.server.listen(0, "127.0.0.1", () => resolve()));
    stop = relay.close;
    const port = (relay.server.address() as AddressInfo).port;
    return { base: `http://127.0.0.1:${port}`, ws: `ws://127.0.0.1:${port}`, relay, port };
}

/** Sends a request exactly as written (fetch would normalize the target) and returns the response's status line. */
function rawRequest(port: number, request: string): Promise<string> {
    return new Promise((resolve, reject) => {
        let data = "";
        const socket = connect(port, "127.0.0.1", () => socket.write(request));
        const done = () => {
            socket.destroy();
            resolve(data.split("\r\n")[0] ?? "");
        };
        socket.on("data", (chunk) => {
            data += chunk.toString();
            if (data.includes("\r\n")) done();
        });
        socket.on("close", done);
        socket.on("error", reject);
    });
}

describe("relay HTTP", () => {
    it("answers health checks from anywhere, with CORS only for the app", async () => {
        const { base } = await listen();
        const plain = await fetch(`${base}/healthz`);
        expect(plain.status).toBe(200);
        expect(plain.headers.get("access-control-allow-origin")).toBeNull();
        const fromApp = await fetch(`${base}/healthz`, { headers: { Origin: APP } });
        expect(fromApp.headers.get("access-control-allow-origin")).toBe(APP);
        expect(await fromApp.json()).toMatchObject({ ok: true, signIn: "device" });
    });

    it("refuses other origins and requests without one", async () => {
        const { base } = await listen();
        expect((await fetch(`${base}/auth/device`, { method: "POST", headers: { Origin: "https://evil.example" } })).status).toBe(403);
        expect((await fetch(`${base}/auth/device`, { method: "POST" })).status).toBe(403);
        expect((await fetch(`${base}/auth/device`, { method: "OPTIONS", headers: { Origin: "https://evil.example" } })).status).toBe(403);
        const preflight = await fetch(`${base}/auth/device`, { method: "OPTIONS", headers: { Origin: APP } });
        expect(preflight.status).toBe(204);
        expect(preflight.headers.get("access-control-allow-headers")).toContain("Authorization");
    });

    it("runs GitHub's device flow without a client secret", async () => {
        const calls: string[] = [];
        const { base } = await listen(calls);
        const start = await (await fetch(`${base}/auth/device`, { method: "POST", headers: { Origin: APP } })).json();
        expect(start).toMatchObject({ userCode: "ABCD-1234", deviceCode: "dc", interval: 5 });
        const pending = await (await fetch(`${base}/auth/token`, { method: "POST", headers: { Origin: APP, "Content-Type": "application/json" }, body: JSON.stringify({ deviceCode: "pending" }) })).json();
        expect(pending).toEqual({ status: "pending", interval: 5 });
        const ok = await (await fetch(`${base}/auth/token`, { method: "POST", headers: { Origin: APP, "Content-Type": "application/json" }, body: JSON.stringify({ deviceCode: "dc" }) })).json();
        expect(ok).toMatchObject({ status: "ok", accessToken: fakeToken() });
        expect(calls.every((c) => !/client_secret/.test(c))).toBe(true);
        const user = await (await fetch(`${base}/auth/user`, { headers: { Origin: APP, Authorization: `Bearer ${fakeToken()}` } })).json();
        expect(user).toEqual({ login: "octo", name: "Octo Cat", avatarUrl: "https://avatars.example/octo" });
        const copilot = await (await fetch(`${base}/auth/copilot`, { headers: { Origin: APP, Authorization: `Bearer ${fakeToken()}` } })).json();
        expect(copilot).toEqual({ ok: true, login: "octo", plan: "enterprise" });
    });

    it("answers request targets that new URL() can't read, and keeps serving (security review, 2026-11-19)", async () => {
        const { base, port } = await listen();
        for (const target of ["//x:a", "/\\x:a"]) {
            const status = await rawRequest(port, `GET ${target} HTTP/1.1\r\nHost: relay\r\nOrigin: ${APP}\r\nConnection: close\r\n\r\n`);
            expect(status).toMatch(/^HTTP\/1\.1 4\d\d /);
        }
        expect((await fetch(`${base}/healthz`)).status).toBe(200);
    });

    it("runs one new Copilot check per client at a time, and answers a second with busy (security review, 2026-11-19)", async () => {
        let finish: () => void = () => undefined;
        const slow: SessionHost = { ...host, probe: () => new Promise((resolve) => (finish = () => resolve({ login: "octo", copilotPlan: "enterprise" }))) };
        const { base } = await listen([], { host: slow });
        const check = (token: string) => fetch(`${base}/auth/copilot`, { headers: { Origin: APP, Authorization: `Bearer ${token}` } });
        const first = check(fakeToken());
        await new Promise((r) => setTimeout(r, 50));
        const second = await check(["gho", "D".repeat(36)].join("_"));
        expect(second.status).toBe(503);
        expect(await second.json()).toMatchObject({ error: "busy" });
        finish();
        expect((await first).status).toBe(200);
        // The client's place is free again: its next new check runs.
        const again = check(["gho", "D".repeat(36)].join("_"));
        await new Promise((r) => setTimeout(r, 50));
        finish();
        expect((await again).status).toBe(200);
    });
});

describe("relay WebSocket", () => {
    const open = (url: string, origin: string) =>
        new Promise<{ ws: WebSocket; status: number | null }>((resolve) => {
            const ws = new WebSocket(`${url}/chat`, { origin });
            ws.on("open", () => resolve({ ws, status: null }));
            ws.on("unexpected-response", (_req, res) => resolve({ ws, status: res.statusCode ?? 0 }));
        });

    it("refuses another origin's WebSocket", async () => {
        const { ws } = await listen();
        const result = await open(ws, "https://evil.example");
        expect(result.status).toBe(403);
    });

    it("starts a conversation and reports bad messages without closing", async () => {
        const { ws: url, relay } = await listen();
        const { ws } = await open(url, APP);
        const messages: Array<Record<string, unknown>> = [];
        const next = () => new Promise<Record<string, unknown>>((resolve) => ws.once("message", (data) => resolve(JSON.parse(String(data)))));
        ws.send(JSON.stringify({ type: "start", token: fakeToken(), systemMessage: "g", tools: [] }));
        messages.push(await next());
        ws.send("not json");
        messages.push(await next());
        expect(messages.map((m) => m.type)).toEqual(["ready", "error"]);
        expect(relay.sessions()).toBe(1);
        ws.close();
    });

    const startOn = (ws: WebSocket) =>
        new Promise<Record<string, unknown>>((resolve) => {
            ws.once("message", (data) => resolve(JSON.parse(String(data))));
            ws.send(JSON.stringify({ type: "start", token: fakeToken(), systemMessage: "g", tools: [] }));
        });
    const closeCode = (ws: WebSocket) => new Promise<number>((resolve) => ws.on("close", (code) => resolve(code)));

    it("refuses an upgrade whose target new URL() can't read, and keeps serving (security review, 2026-11-19)", async () => {
        const { base, port } = await listen();
        // A WebSocket key is any 16 random bytes in base64 (RFC 6455); built here so no key-shaped literal is in the source.
        const key = randomBytes(16).toString("base64");
        const status = await rawRequest(
            port,
            `GET /\\x:a HTTP/1.1\r\nHost: relay\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nOrigin: ${APP}\r\n\r\n`,
        );
        expect(status).toMatch(/^HTTP\/1\.1 4\d\d /);
        expect((await fetch(`${base}/healthz`)).status).toBe(200);
    });

    it("closes a socket that doesn't start in time, so it holds no place (security review, 2026-11-19)", async () => {
        const { ws: url } = await listen([], { startDeadlineMs: 100 });
        const { ws } = await open(url, APP);
        expect(await closeCode(ws)).toBe(4001);
    });

    it("closes the socket of a start that failed, and frees its place (security review, 2026-11-19)", async () => {
        const failing: SessionHost = {
            ...host,
            create: async () => {
                throw new Error("401 Unauthorized");
            },
        };
        const { ws: url, relay } = await listen([], { host: failing });
        const { ws } = await open(url, APP);
        const closed = closeCode(ws);
        expect(await startOn(ws)).toMatchObject({ type: "error", fatal: true });
        expect(await closed).toBe(4002);
        expect(relay.sessions()).toBe(0);
    });

    it("counts a conversation against the limit from its start, not from its socket (security review, 2026-11-19)", async () => {
        const { ws: url, relay } = await listen();
        const sockets = await Promise.all([open(url, APP), open(url, APP), open(url, APP)]);
        // Three sockets with maxSessions 2: none has started, so none is refused.
        expect(sockets.map((s) => s.status)).toEqual([null, null, null]);
        expect(await startOn(sockets[0].ws)).toMatchObject({ type: "ready" });
        expect(await startOn(sockets[1].ws)).toMatchObject({ type: "ready" });
        const closed = closeCode(sockets[2].ws);
        expect(await startOn(sockets[2].ws)).toMatchObject({ type: "error", code: "relay_busy", fatal: true });
        expect(await closed).toBe(4003);
        expect(relay.sessions()).toBe(2);
        for (const s of sockets) s.ws.close();
    });

    it("caps the sockets one client holds open (security review, 2026-11-19)", async () => {
        const { ws: url } = await listen();
        const held = await Promise.all(Array.from({ length: MAX_SOCKETS_PER_CLIENT }, () => open(url, APP)));
        expect(held.every((s) => s.status === null)).toBe(true);
        expect((await open(url, APP)).status).toBe(429);
        for (const s of held) s.ws.close();
    });
});

describe("clientKey", () => {
    it("takes the address Container Apps' ingress appended, not one the client wrote (security review, 2026-11-19)", () => {
        const req = (forwarded?: string) =>
            ({ headers: forwarded === undefined ? {} : { "x-forwarded-for": forwarded }, socket: { remoteAddress: "10.0.0.9" } }) as unknown as Parameters<typeof clientKey>[0];
        expect(clientKey(req("6.6.6.6, 203.0.113.7"))).toBe("203.0.113.7");
        expect(clientKey(req("203.0.113.7"))).toBe("203.0.113.7");
        expect(clientKey(req())).toBe("10.0.0.9");
    });
});

describe("RateLimiter", () => {
    it("allows the limit per window and then refuses", () => {
        let t = 0;
        const limiter = new RateLimiter(2, 1000, () => t);
        expect([limiter.allow("a"), limiter.allow("a"), limiter.allow("a"), limiter.allow("b")]).toEqual([true, true, false, true]);
        t = 1000;
        expect(limiter.allow("a")).toBe(true);
    });

    it("forgets only windows that ended when it's full, never every counter (security review, 2026-11-19)", () => {
        let t = 0;
        const limiter = new RateLimiter(1, 1000, () => t, 2);
        expect([limiter.allow("a"), limiter.allow("b")]).toEqual([true, true]);
        // Full of live windows: a new client waits, and a's count stays.
        expect(limiter.allow("c")).toBe(false);
        expect(limiter.allow("a")).toBe(false);
        t = 1000;
        expect(limiter.allow("c")).toBe(true);
        expect(limiter.size).toBe(1);
    });
});
