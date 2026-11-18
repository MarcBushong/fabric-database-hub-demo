import { describe, expect, it } from "vitest";

import { parseOrigins } from "../src/config.js";
import { LIMITS, parseClientMessage, ProtocolError } from "../src/protocol.js";

// Built at run time so secret scanners never see a token-shaped literal.
const fakeToken = () => ["gho", "A".repeat(36)].join("_");
const tool = (name = "run_dax") => ({ name, description: "Runs DAX.", parameters: { type: "object", properties: { query: { type: "string" } } } });

describe("parseClientMessage", () => {
    it("accepts a start message with tools and a model", () => {
        const m = parseClientMessage(JSON.stringify({ type: "start", token: fakeToken(), systemMessage: "guide", tools: [tool(), tool("show_chart")], model: "gpt-5" }));
        expect(m).toMatchObject({ type: "start", model: "gpt-5" });
        expect(m.type === "start" && m.tools.map((t) => t.name)).toEqual(["run_dax", "show_chart"]);
    });

    it("refuses a token with unexpected characters", () => {
        expect(() => parseClientMessage(JSON.stringify({ type: "start", token: "not a token!", systemMessage: "", tools: [] }))).toThrow(/token/);
    });

    it("refuses duplicate, badly named, or schema-less tools", () => {
        const start = (tools: unknown[]) => JSON.stringify({ type: "start", token: fakeToken(), systemMessage: "", tools });
        expect(() => parseClientMessage(start([tool(), tool()]))).toThrow(/twice/);
        expect(() => parseClientMessage(start([tool("Run-Dax")]))).toThrow(/name/);
        expect(() => parseClientMessage(start([{ name: "x_y", description: "", parameters: { type: "string" } }]))).toThrow(/object/);
        expect(() => parseClientMessage(start(Array.from({ length: LIMITS.tools + 1 }, (_, i) => tool(`t${i}x`))))).toThrow(ProtocolError);
    });

    it("trims questions and refuses empty or oversized ones", () => {
        expect(parseClientMessage(JSON.stringify({ type: "user", text: "  hi  " }))).toEqual({ type: "user", text: "hi" });
        expect(() => parseClientMessage(JSON.stringify({ type: "user", text: "   " }))).toThrow(/empty/);
        expect(() => parseClientMessage(JSON.stringify({ type: "user", text: "x".repeat(LIMITS.userText + 1) }))).toThrow(/longer/);
    });

    it("cuts an oversized tool result instead of refusing it", () => {
        const m = parseClientMessage(JSON.stringify({ type: "tool_result", callId: "c1", ok: true, result: "y".repeat(LIMITS.toolResult + 50) }));
        expect(m.type === "tool_result" && m.result.endsWith("characters.]")).toBe(true);
    });

    it("refuses unknown types and non-JSON", () => {
        expect(() => parseClientMessage("{")).toThrow(/JSON/);
        expect(() => parseClientMessage(JSON.stringify({ type: "shell", command: "ls" }))).toThrow(/Unknown/);
    });
});

describe("parseOrigins", () => {
    it("keeps exact origins only, lowercased, without trailing slashes", () => {
        const origins = parseOrigins("https://App-westus3.webapp.fabricapps.net/, http://localhost:5173, https://*.example.com, https://a.example.com/path, ");
        expect([...origins]).toEqual(["https://app-westus3.webapp.fabricapps.net", "http://localhost:5173"]);
    });
});
