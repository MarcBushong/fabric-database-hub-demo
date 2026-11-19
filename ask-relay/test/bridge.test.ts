import { describe, expect, it, vi } from "vitest";

import { AskBridge, describeSessionError, redact, type SessionHost, type SessionLike, type SessionRequest } from "../src/bridge.js";
import type { ServerMessage } from "../src/protocol.js";

const fakeToken = () => ["gho", "B".repeat(36)].join("_");

function fakeHost() {
    const handlers = new Map<string, (event: { data: Record<string, unknown> }) => void>();
    const requests: SessionRequest[] = [];
    const removed: string[] = [];
    const session: SessionLike & { prompts: string[]; disconnected: boolean } = {
        sessionId: "ask-1",
        prompts: [],
        disconnected: false,
        on(type, handler) {
            handlers.set(type, handler);
            return () => handlers.delete(type);
        },
        async send({ prompt }) {
            session.prompts.push(prompt);
            return "m1";
        },
        async abort() {},
        async disconnect() {
            session.disconnected = true;
        },
    };
    const host: SessionHost = {
        async create(request) {
            requests.push(request);
            return session;
        },
        async remove(id) {
            removed.push(id);
        },
        probe: async () => ({ login: "octo", copilotPlan: "enterprise" }),
    };
    const emit = (type: string, data: Record<string, unknown>) => handlers.get(type)?.({ data });
    return { host, session, requests, removed, emit };
}

const config = { maxTurns: 2, sessionMaxMinutes: 60, toolTimeoutSeconds: 30, defaultModel: "" };
const start = { type: "start" as const, token: fakeToken(), systemMessage: "guide", tools: [{ name: "run_dax", description: "d", parameters: { type: "object" } }] };

describe("AskBridge", () => {
    it("creates one session with the page's tools and streams Copilot's events", async () => {
        const f = fakeHost();
        const sent: ServerMessage[] = [];
        const bridge = new AskBridge(f.host, config, (m) => sent.push(m), () => "id");
        await bridge.handle(start);
        expect(f.requests[0]).toMatchObject({ sessionId: "ask-id", systemMessage: "guide", model: undefined });
        expect(f.requests[0].tools.map((t) => t.name)).toEqual(["run_dax"]);
        await bridge.handle({ type: "user", text: "q" });
        f.emit("assistant.message_delta", { messageId: "m1", deltaContent: "Hel" });
        f.emit("assistant.message", { messageId: "m1", content: "Hello" });
        f.emit("assistant.message", { messageId: "m2", content: "  " });
        f.emit("session.idle", {});
        expect(sent.map((m) => m.type)).toEqual(["ready", "delta", "message", "idle"]);
        expect(f.session.prompts).toEqual(["q"]);
    });

    it("passes a tool call to the page and returns the page's answer", async () => {
        const f = fakeHost();
        const sent: ServerMessage[] = [];
        const bridge = new AskBridge(f.host, config, (m) => sent.push(m), () => "id");
        await bridge.handle(start);
        const answer = f.requests[0].tools[0].handler({ query: "EVALUATE ROW(\"a\", 1)" }, { toolCallId: "call-1" });
        expect(sent.at(-1)).toEqual({ type: "tool_call", callId: "call-1", name: "run_dax", arguments: { query: "EVALUATE ROW(\"a\", 1)" } });
        expect(bridge.pendingCalls).toBe(1);
        await bridge.handle({ type: "tool_result", callId: "call-1", ok: true, result: "[[1]]" });
        await expect(answer).resolves.toEqual({ textResultForLlm: "[[1]]", resultType: "success" });
        // A late duplicate answer is ignored.
        await bridge.handle({ type: "tool_result", callId: "call-1", ok: false, result: "late" });
        expect(bridge.pendingCalls).toBe(0);
    });

    it("times out a tool call the page never answers", async () => {
        vi.useFakeTimers();
        try {
            const f = fakeHost();
            const bridge = new AskBridge(f.host, { ...config, toolTimeoutSeconds: 10 }, () => undefined, () => "id");
            await bridge.handle(start);
            const answer = f.requests[0].tools[0].handler({}, { toolCallId: "call-2" });
            vi.advanceTimersByTime(10_001);
            await expect(answer).resolves.toMatchObject({ resultType: "timeout" });
        } finally {
            vi.useRealTimers();
        }
    });

    it("refuses a second question while busy and after the turn limit", async () => {
        const f = fakeHost();
        const bridge = new AskBridge(f.host, config, () => undefined, () => "id");
        await bridge.handle(start);
        await bridge.handle({ type: "user", text: "one" });
        await expect(bridge.handle({ type: "user", text: "two" })).rejects.toMatchObject({ code: "busy" });
        f.emit("session.idle", {});
        await bridge.handle({ type: "user", text: "two" });
        f.emit("session.idle", {});
        await expect(bridge.handle({ type: "user", text: "three" })).rejects.toMatchObject({ code: "turn_limit" });
    });

    it("closes: cancels pending calls, disconnects, and deletes the session's transcript", async () => {
        const f = fakeHost();
        const bridge = new AskBridge(f.host, config, () => undefined, () => "id");
        await bridge.handle(start);
        const answer = f.requests[0].tools[0].handler({}, { toolCallId: "call-3" });
        await bridge.close();
        await expect(answer).resolves.toMatchObject({ resultType: "failure" });
        expect(f.session.disconnected).toBe(true);
        expect(f.removed).toEqual(["ask-1"]);
        await expect(bridge.handle({ type: "user", text: "q" })).rejects.toMatchObject({ code: "not_started" });
    });

    it("refuses a second start", async () => {
        const f = fakeHost();
        const bridge = new AskBridge(f.host, config, () => undefined, () => "id");
        await bridge.handle(start);
        await expect(bridge.handle(start)).rejects.toMatchObject({ code: "already_started" });
    });
});

describe("error text", () => {
    it("never repeats a token", () => {
        const token = fakeToken();
        expect(redact(`bad credentials for ${token}`)).not.toContain(token);
        expect(describeSessionError(new Error(`401 Unauthorized ${token}`))).toMatch(/Sign in to GitHub again/);
        expect(describeSessionError(new Error(`403 copilot access not granted`))).toMatch(/Copilot license/);
    });
});
