// Wires the bridge to the GitHub Copilot SDK. "empty" mode is the SDK's multi-user server mode: no ambient tools,
// skills, plugins, or instructions; each session runs as its own viewer's GitHub token, and only the tools the
// page declared are available (custom:<name>). The session store and memory stay off.
// https://github.com/microsoft/copilot-sdk/blob/main/docs/setup/multi-tenancy.md

import { randomUUID } from "node:crypto";
import { CopilotClient, RuntimeConnection, type CopilotSession, type PermissionHandler, type Tool } from "@microsoft/copilot-sdk";

import type { RelayConfig } from "./config.js";
import { identityOf, type SessionHost, type SessionLike, type SessionRequest } from "./bridge.js";

/** Refuses every permission request: the page's tools skip permission, and nothing else exists to approve. */
export const refuseAll: PermissionHandler = () => ({ kind: "reject", feedback: "This assistant can only use the Insights app's read-only tools." });

export function sessionOptions(request: SessionRequest) {
    const definitions: Tool<unknown>[] = request.tools.map((tool) => ({
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        skipPermission: true,
        defer: "never",
        handler: (args: unknown, invocation: { toolCallId: string; signal?: AbortSignal }) => tool.handler(args, { toolCallId: invocation.toolCallId, signal: invocation.signal }),
    }));
    return {
        sessionId: request.sessionId,
        model: request.model,
        clientName: "dbhub-insights-ask",
        github: { token: request.token, interactiveUser: true },
        tools: {
            definitions,
            availableTools: request.tools.map((tool) => `custom:${tool.name}`),
        },
        agents: { includedBuiltinAgents: [] },
        skills: { enabled: false, includedBuiltinSkills: [] },
        instructions: { skipCustomInstructions: true },
        enableConfigDiscovery: false,
        // Append keeps the SDK's own guardrails; the page's text says what this assistant is for.
        systemMessage: { mode: "append" as const, content: request.systemMessage },
        events: { streaming: true },
        permissions: { onRequest: refuseAll },
        state: { enableCrossSessionStore: false },
    };
}

export interface CopilotHost extends SessionHost {
    start(): Promise<void>;
    stop(): Promise<void>;
}

export function createCopilotHost(config: Pick<RelayConfig, "copilotHome" | "sessionMaxMinutes">): CopilotHost {
    // A child process rather than the in-process host: a runtime failure can't take the server down, and the
    // in-process host's FFI package (koffi) needs an install script that npm 11 doesn't run unapproved.
    const client = new CopilotClient({
        mode: "empty",
        // Never an ambient credential (GH_TOKEN, COPILOT_GITHUB_TOKEN, a stored login): only each session's own token.
        github: { useLoggedInUser: false },
        runtime: RuntimeConnection.forSpawnedStdio({ baseDirectory: config.copilotHome, sessionIdleTimeoutSeconds: config.sessionMaxMinutes * 60 }),
    });
    return {
        start: () => client.start(),
        async stop() {
            await client.stop();
        },
        async create(request) {
            const session: CopilotSession = await client.createSession(sessionOptions(request) as Parameters<CopilotClient["createSession"]>[0]);
            return session as unknown as SessionLike;
        },
        remove: (sessionId) => client.deleteSession(sessionId),
        async probe(token) {
            // Creating a session resolves the token's GitHub identity and Copilot access; nothing is sent to a model.
            const session = (await client.createSession(
                sessionOptions({ sessionId: `probe-${randomUUID()}`, token, model: undefined, systemMessage: "", tools: [] }) as Parameters<CopilotClient["createSession"]>[0],
            )) as unknown as SessionLike;
            try {
                return await identityOf(session);
            } finally {
                await session.disconnect().catch(() => undefined);
                await client.deleteSession(session.sessionId).catch(() => undefined);
            }
        },
    };
}
