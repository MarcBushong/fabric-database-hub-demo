import { afterEach, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import WebSocket from "ws";

import type { SessionHost, SessionLike } from "../src/bridge.js";
import type { RelayConfig } from "../src/config.js";
import { createRelay, RateLimiter } from "../src/server.js";

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

async function listen(calls: string[] = []) {
    const relay = createRelay(config, { host, fetch: githubFake(calls), log: () => undefined });
    await new Promise<void>((resolve) => relay.server.listen(0, "127.0.0.1", () => resolve()));
    stop = relay.close;
    const port = (relay.server.address() as AddressInfo).port;
    return { base: `http://127.0.0.1:${port}`, ws: `ws://127.0.0.1:${port}`, relay };
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
});

describe("RateLimiter", () => {
    it("allows the limit per window and then refuses", () => {
        let t = 0;
        const limiter = new RateLimiter(2, 1000, () => t);
        expect([limiter.allow("a"), limiter.allow("a"), limiter.allow("a"), limiter.allow("b")]).toEqual([true, true, false, true]);
        t = 1000;
        expect(limiter.allow("a")).toBe(true);
    });
});
