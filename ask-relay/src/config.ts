// The relay's settings, from environment variables only. None of them is a secret: the relay holds no Azure,
// Fabric, or GitHub credential. GITHUB_CLIENT_ID identifies a GitHub app for the device flow, which needs no
// client secret (https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow).

export interface RelayConfig {
    port: number;
    /** Exact origins allowed to call the relay (the Insights app's hosting origin, and localhost for development). */
    allowedOrigins: ReadonlySet<string>;
    /** The GitHub app's client ID for the device flow; null turns sign-in off. */
    githubClientId: string | null;
    /** OAuth scopes the device flow requests; empty by default (Copilot needs none). */
    githubScopes: string;
    /** Sessions this replica runs at once. */
    maxSessions: number;
    /** User messages per session. */
    maxTurns: number;
    /** A session's longest life, in minutes. */
    sessionMaxMinutes: number;
    /** How long the relay waits for the page to answer one tool call. */
    toolTimeoutSeconds: number;
    /** The Copilot runtime's state folder (COPILOT_HOME): the container's own disk, removed with the replica. */
    copilotHome: string;
    /** The model when the page names none; empty lets the runtime choose. */
    defaultModel: string;
    version: string;
}

const ORIGIN = /^https?:\/\/[a-z0-9.-]+(:\d{1,5})?$/i;
const CLIENT_ID = /^[A-Za-z0-9._-]{8,64}$/;

function int(value: string | undefined, fallback: number, min: number, max: number): number {
    const n = Number.parseInt(value ?? "", 10);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(max, Math.max(min, n));
}

/** Parses ALLOWED_ORIGINS: a comma-separated list of exact origins, without paths or wildcards. */
export function parseOrigins(value: string | undefined): Set<string> {
    const origins = new Set<string>();
    for (const part of (value ?? "").split(",")) {
        const origin = part.trim().replace(/\/+$/, "").toLowerCase();
        if (origin && ORIGIN.test(origin)) origins.add(origin);
    }
    return origins;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): RelayConfig {
    const clientId = (env.GITHUB_CLIENT_ID ?? "").trim();
    return {
        port: int(env.PORT, 8080, 1, 65535),
        allowedOrigins: parseOrigins(env.ALLOWED_ORIGINS),
        githubClientId: CLIENT_ID.test(clientId) ? clientId : null,
        githubScopes: (env.GITHUB_SCOPES ?? "").trim(),
        maxSessions: int(env.MAX_SESSIONS, 20, 1, 200),
        maxTurns: int(env.MAX_TURNS, 40, 1, 500),
        sessionMaxMinutes: int(env.SESSION_MAX_MINUTES, 60, 5, 24 * 60),
        toolTimeoutSeconds: int(env.TOOL_TIMEOUT_SECONDS, 150, 10, 600),
        copilotHome: (env.COPILOT_HOME ?? "/tmp/copilot").trim() || "/tmp/copilot",
        defaultModel: (env.DEFAULT_MODEL ?? "").trim(),
        version: (env.RELAY_VERSION ?? "0.1.0").trim(),
    };
}
