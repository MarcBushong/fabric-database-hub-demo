import { describe, expect, it, vi } from "vitest";

import { AskBridge, describeSessionError, HISTORY_READ_MS, redact, type SessionHost, type SessionLike, type SessionRequest, type TurnSummary } from "../src/bridge.js";
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

// R925 (2026-11-19): a live turn ended with tool rows and no answer. Every way the model's text can reach the relay is
// scripted here as the SDK emits it, and the page must end each turn with all of that text, and the relay log the turn.
describe("AskBridge: the end of a turn (R925)", () => {
    type HistoryEvent = { type: string; data?: Record<string, unknown>; agentId?: string };
    const ANSWER = "**T2** needs attention first: CPU above 90% for 14 minutes.";

    function scripted(history: HistoryEvent[] | (() => Promise<HistoryEvent[]>) = []) {
        const f = fakeHost();
        Object.assign(f.session, { getEvents: typeof history === "function" ? history : async () => history });
        const sent: ServerMessage[] = [];
        const ends: TurnSummary[] = [];
        const bridge = new AskBridge(f.host, { ...config, maxTurns: 5 }, (m) => sent.push(m), () => "id", undefined, (s) => ends.push(s));
        const idle = () => vi.waitFor(() => expect(sent.at(-1)?.type).toBe("idle"));
        const callTool = async (callId: string) => {
            const answer = f.requests[0].tools[0].handler({}, { toolCallId: callId });
            await bridge.handle({ type: "tool_result", callId, ok: true, result: "[[1]]" });
            return answer;
        };
        return { ...f, sent, ends, bridge, idle, callTool };
    }
    const textOf = (sent: ServerMessage[]) => sent.filter((m): m is Extract<ServerMessage, { type: "message" }> => m.type === "message");

    it("sends a final answer that comes as a new message after the tool calls, then idle, and logs the turn", async () => {
        const s = scripted([{ type: "user.message", data: { messageId: "m1" } }]);
        await s.bridge.handle(start);
        await s.bridge.handle({ type: "user", text: "q" });
        s.emit("assistant.message", { messageId: "a1", content: "", toolRequests: [{ name: "run_dax" }] });
        await s.callTool("c1");
        s.emit("assistant.turn_end", { turnId: "t1" });
        s.emit("assistant.message_delta", { messageId: "a2", deltaContent: "**T2** needs" });
        s.emit("assistant.message", { messageId: "a2", content: ANSWER });
        s.emit("session.idle", {});
        await s.idle();
        expect(s.sent.map((m) => m.type)).toEqual(["ready", "tool_call", "delta", "message", "idle"]);
        expect(s.ends).toHaveLength(1);
        expect(s.ends[0]).toMatchObject({ ended: "idle", tools: 1, failedTools: 0, messages: 2, textChars: ANSWER.length, finalTextChars: ANSWER.length, rounds: `0/1 ${ANSWER.length}/0`, fromHistory: 0 });
    });

    it("sends the full text of a message that came only as deltas, before idle", async () => {
        const s = scripted([
            { type: "user.message", data: { messageId: "m1" } },
            { type: "assistant.message", data: { messageId: "a1", content: "", toolRequests: [{ name: "run_dax" }] } },
            { type: "assistant.message", data: { messageId: "a2", content: ANSWER } },
        ]);
        await s.bridge.handle(start);
        await s.bridge.handle({ type: "user", text: "q" });
        s.emit("assistant.message", { messageId: "a1", content: "", toolRequests: [{ name: "run_dax" }] });
        await s.callTool("c1");
        s.emit("assistant.message_delta", { messageId: "a2", deltaContent: "**T2** needs attention" });
        s.emit("session.idle", {});
        await s.idle();
        expect(s.sent.map((m) => m.type)).toEqual(["ready", "tool_call", "delta", "message", "idle"]);
        expect(textOf(s.sent)).toEqual([{ type: "message", messageId: "a2", text: ANSWER }]);
        expect(s.ends[0]).toMatchObject({ finalTextChars: ANSWER.length, fromHistory: 1 });
    });

    it("sends the last message before idle when the live idle comes first, and never sends it twice", async () => {
        const s = scripted([
            { type: "user.message", data: { messageId: "m0" } },
            { type: "assistant.message", data: { messageId: "old", content: "An earlier turn's answer." } },
            { type: "user.message", data: { messageId: "m1" } },
            { type: "assistant.message", data: { messageId: "a1", content: "", toolRequests: [{ name: "run_dax" }] } },
            { type: "assistant.message", data: { messageId: "a2", content: ANSWER } },
        ]);
        await s.bridge.handle(start);
        await s.bridge.handle({ type: "user", text: "q" });
        s.emit("assistant.message", { messageId: "a1", content: "", toolRequests: [{ name: "run_dax" }] });
        await s.callTool("c1");
        s.emit("session.idle", {});
        await s.idle();
        s.emit("assistant.message", { messageId: "a2", content: ANSWER });
        expect(s.sent.map((m) => m.type)).toEqual(["ready", "tool_call", "message", "idle"]);
        expect(textOf(s.sent).map((m) => m.messageId)).toEqual(["a2"]);
    });

    it("ends a turn whose model wrote no text: idle for the page, and finalTextChars 0 in the log, with no content or token", async () => {
        const s = scripted([{ type: "user.message", data: { messageId: "m1" } }]);
        await s.bridge.handle(start);
        await s.bridge.handle({ type: "user", text: "How is my estate doing?" });
        s.emit("assistant.message", { messageId: "a1", content: "The live view isn't available, so I'll check the history.", toolRequests: [{ name: "run_dax" }] });
        await s.callTool("c1");
        s.emit("assistant.message", { messageId: "a2", content: "", toolRequests: [{ name: "suggest_followups" }] });
        await s.callTool("c2");
        s.emit("assistant.message", { messageId: "a3", content: "" });
        s.emit("session.idle", {});
        await s.idle();
        expect(s.ends[0]).toMatchObject({ ended: "idle", tools: 2, messages: 3, finalTextChars: 0, rounds: "57/1 0/1 0/0" });
        const logged = JSON.stringify(s.ends[0]);
        expect(logged).not.toMatch(/live view|check the|my estate/i);
        expect(logged).not.toContain(start.token);
    });

    // The review of cd58cd2: finalTextChars counts the answer as the dock does, so the live check can trust it.
    it("counts the final answer as the dock does: the text after the last query, whatever follow-ups and charts come after it", async () => {
        const s = scripted([{ type: "user.message", data: { messageId: "m1" } }]);
        await s.bridge.handle(start);
        await s.bridge.handle({ type: "user", text: "q" });
        s.emit("assistant.message", { messageId: "a1", content: "", toolRequests: [{ name: "run_dax" }] });
        await s.callTool("c1");
        s.emit("assistant.message", { messageId: "a2", content: ANSWER, toolRequests: [{ name: "suggest_followups" }] });
        await s.callTool("c2");
        s.emit("assistant.message", { messageId: "a3", content: "", toolRequests: [{ name: "show_chart" }] });
        await s.callTool("c3");
        s.emit("assistant.message", { messageId: "a4", content: "" });
        s.emit("session.idle", {});
        await s.idle();
        expect(s.ends[0]).toMatchObject({ messages: 4, finalTextChars: ANSWER.length, rounds: `0/1 ${ANSWER.length}/1 0/1 0/0` });

        // The reverse: text in the message that asks for a query says what Copilot will check; the dock shows no answer.
        await s.bridge.handle({ type: "user", text: "And the live view?" });
        s.emit("assistant.message", { messageId: "b1", content: "", toolRequests: [{ name: "run_dax" }] });
        await s.callTool("c4");
        s.emit("assistant.message", { messageId: "b2", content: "Let me also check the live view.", toolRequests: [{ name: "estate_overview" }] });
        await s.callTool("c5");
        s.emit("assistant.message", { messageId: "b3", content: "" });
        s.emit("session.idle", {});
        await vi.waitFor(() => expect(s.ends).toHaveLength(2));
        expect(s.ends[1]).toMatchObject({ messages: 3, textChars: 32, finalTextChars: 0, rounds: "0/1 32/1 0/0" });
    });

    it("still sends idle when the history can't be read, or doesn't answer in time", async () => {
        const failing = scripted(async () => {
            throw new Error("runtime gone");
        });
        await failing.bridge.handle(start);
        await failing.bridge.handle({ type: "user", text: "q" });
        failing.emit("session.idle", {});
        await failing.idle();
        expect(failing.ends[0]).toMatchObject({ ended: "idle", fromHistory: 0 });

        vi.useFakeTimers();
        try {
            const slow = scripted(() => new Promise<HistoryEvent[]>(() => undefined));
            await slow.bridge.handle(start);
            await slow.bridge.handle({ type: "user", text: "q" });
            slow.emit("session.idle", {});
            await vi.advanceTimersByTimeAsync(HISTORY_READ_MS + 1);
            expect(slow.sent.at(-1)?.type).toBe("idle");
        } finally {
            vi.useRealTimers();
        }
    });

    it("logs one turn end for an error, a failed tool, and a conversation closed mid-turn", async () => {
        const s = scripted();
        await s.bridge.handle(start);
        await s.bridge.handle({ type: "user", text: "q" });
        const answer = s.requests[0].tools[0].handler({}, { toolCallId: "c1" });
        await s.bridge.handle({ type: "tool_result", callId: "c1", ok: false, result: "The query failed." });
        await answer;
        s.emit("session.error", { errorType: "rate_limited", message: "Too many requests" });
        s.emit("session.idle", {});
        await s.idle();
        expect(s.ends).toHaveLength(1);
        expect(s.ends[0]).toMatchObject({ ended: "error", error: "rate_limited", tools: 1, failedTools: 1 });

        await s.bridge.handle({ type: "user", text: "again" });
        await s.bridge.close();
        expect(s.ends).toHaveLength(2);
        expect(s.ends[1]).toMatchObject({ ended: "closed", tools: 0 });
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
