// The WebSocket protocol between the Ask page and the relay. One connection is one Copilot session. The page
// declares its tools and the system message; the relay forwards each tool call to the page and returns the
// page's answer to Copilot. Every limit here bounds what one connection can make the relay do.

export const LIMITS = {
    tools: 16,
    toolName: /^[a-z][a-z0-9_]{1,47}$/,
    toolDescription: 4000,
    toolSchema: 16 * 1024,
    systemMessage: 96 * 1024,
    userText: 8000,
    toolResult: 200 * 1024,
    model: /^[A-Za-z0-9._:-]{1,64}$/,
    // A GitHub user token: gho_/ghu_/github_pat_ prefixes, or any opaque token of a sane size.
    token: /^[A-Za-z0-9_]{20,255}$/,
    frame: 512 * 1024,
} as const;

export interface ToolSpec {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
}

export type ClientMessage =
    | { type: "start"; token: string; systemMessage: string; tools: ToolSpec[]; model?: string }
    | { type: "user"; text: string }
    | { type: "tool_result"; callId: string; ok: boolean; result: string }
    | { type: "abort" }
    | { type: "ping" };

export type ServerMessage =
    | { type: "ready"; sessionId: string; model: string | null; login: string | null; plan: string | null }
    | { type: "delta"; messageId: string; text: string }
    | { type: "message"; messageId: string; text: string }
    | { type: "tool_call"; callId: string; name: string; arguments: unknown }
    | { type: "tool_done"; callId: string }
    | { type: "usage"; model: string | null; inputTokens: number | null; outputTokens: number | null }
    | { type: "idle" }
    | { type: "error"; code: string; message: string; fatal: boolean }
    | { type: "pong" };

export class ProtocolError extends Error {
    readonly code: string;
    constructor(code: string, message: string) {
        super(message);
        this.name = "ProtocolError";
        this.code = code;
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown, field: string, max: number): string {
    if (typeof value !== "string") throw new ProtocolError("bad_message", `${field} must be a string.`);
    if (value.length > max) throw new ProtocolError("too_large", `${field} is longer than ${max} characters.`);
    return value;
}

export function validateTools(value: unknown): ToolSpec[] {
    if (!Array.isArray(value)) throw new ProtocolError("bad_message", "tools must be an array.");
    if (value.length > LIMITS.tools) throw new ProtocolError("too_large", `At most ${LIMITS.tools} tools.`);
    const seen = new Set<string>();
    return value.map((tool, i) => {
        if (!isRecord(tool)) throw new ProtocolError("bad_message", `tools[${i}] must be an object.`);
        const name = text(tool.name, `tools[${i}].name`, 48);
        if (!LIMITS.toolName.test(name)) throw new ProtocolError("bad_message", `tools[${i}].name must match ${LIMITS.toolName}.`);
        if (seen.has(name)) throw new ProtocolError("bad_message", `Tool ${name} is declared twice.`);
        seen.add(name);
        const description = text(tool.description, `tools[${i}].description`, LIMITS.toolDescription);
        if (!isRecord(tool.parameters) || tool.parameters.type !== "object") {
            throw new ProtocolError("bad_message", `tools[${i}].parameters must be a JSON schema of type object.`);
        }
        if (JSON.stringify(tool.parameters).length > LIMITS.toolSchema) {
            throw new ProtocolError("too_large", `tools[${i}].parameters is larger than ${LIMITS.toolSchema} bytes.`);
        }
        return { name, description, parameters: tool.parameters };
    });
}

/** Parses and validates one frame from the page. Throws ProtocolError with a plain-language message. */
export function parseClientMessage(raw: string): ClientMessage {
    if (raw.length > LIMITS.frame) throw new ProtocolError("too_large", "The message is too large.");
    let value: unknown;
    try {
        value = JSON.parse(raw);
    } catch {
        throw new ProtocolError("bad_message", "The message isn't JSON.");
    }
    if (!isRecord(value) || typeof value.type !== "string") throw new ProtocolError("bad_message", "The message has no type.");
    switch (value.type) {
        case "start": {
            const token = text(value.token, "token", 255);
            if (!LIMITS.token.test(token)) throw new ProtocolError("bad_token", "The GitHub token has an unexpected format. Sign in to GitHub again.");
            const systemMessage = text(value.systemMessage, "systemMessage", LIMITS.systemMessage);
            const tools = validateTools(value.tools);
            let model: string | undefined;
            if (value.model !== undefined && value.model !== null && value.model !== "") {
                model = text(value.model, "model", 64);
                if (!LIMITS.model.test(model)) throw new ProtocolError("bad_message", "model has unexpected characters.");
            }
            return { type: "start", token, systemMessage, tools, model };
        }
        case "user": {
            const t = text(value.text, "text", LIMITS.userText).trim();
            if (!t) throw new ProtocolError("bad_message", "The question is empty.");
            return { type: "user", text: t };
        }
        case "tool_result": {
            const callId = text(value.callId, "callId", 200);
            if (typeof value.ok !== "boolean") throw new ProtocolError("bad_message", "ok must be true or false.");
            // An oversized result is cut rather than refused, so the model still gets an answer and a note.
            let result = typeof value.result === "string" ? value.result : JSON.stringify(value.result ?? null);
            if (result.length > LIMITS.toolResult) {
                result = `${result.slice(0, LIMITS.toolResult)}\n[The result was cut at ${LIMITS.toolResult} characters.]`;
            }
            return { type: "tool_result", callId, ok: value.ok, result };
        }
        case "abort":
            return { type: "abort" };
        case "ping":
            return { type: "ping" };
        default:
            throw new ProtocolError("bad_message", `Unknown message type ${JSON.stringify(String(value.type).slice(0, 40))}.`);
    }
}
