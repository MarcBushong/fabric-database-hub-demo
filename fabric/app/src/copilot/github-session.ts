// The viewer's GitHub sign-in for Ask, kept in this browser only (the app's own storage), never sent anywhere
// but the chat relay, which uses it for the viewer's own Copilot session and keeps nothing. A token from the
// device flow may expire after 8 hours; its refresh token renews it without a client secret.

import type { DevicePoll } from "./relay";

export interface GitHubSession {
    accessToken: string;
    /** Epoch milliseconds; null when the app's tokens don't expire. */
    expiresAt: number | null;
    refreshToken: string | null;
    refreshExpiresAt: number | null;
    login: string | null;
}

const KEY = "dbhub-insights.github.v1";
const TOKEN = /^[A-Za-z0-9_]{20,255}$/;
/** Renew when less than this is left, so a conversation never starts on a token about to lapse. */
export const REFRESH_MARGIN_MS = 2 * 60 * 60 * 1000;

export function fromPoll(poll: Extract<DevicePoll, { status: "ok" }>, now: number, login: string | null = null): GitHubSession {
    return {
        accessToken: poll.accessToken,
        expiresAt: poll.expiresIn ? now + poll.expiresIn * 1000 : null,
        refreshToken: poll.refreshToken,
        refreshExpiresAt: poll.refreshTokenExpiresIn ? now + poll.refreshTokenExpiresIn * 1000 : null,
        login,
    };
}

export function loadSession(storage: Pick<Storage, "getItem"> | undefined): GitHubSession | null {
    try {
        const raw = storage?.getItem(KEY);
        if (!raw) return null;
        const value = JSON.parse(raw) as Partial<GitHubSession>;
        if (typeof value.accessToken !== "string" || !TOKEN.test(value.accessToken)) return null;
        return {
            accessToken: value.accessToken,
            expiresAt: typeof value.expiresAt === "number" ? value.expiresAt : null,
            refreshToken: typeof value.refreshToken === "string" && TOKEN.test(value.refreshToken) ? value.refreshToken : null,
            refreshExpiresAt: typeof value.refreshExpiresAt === "number" ? value.refreshExpiresAt : null,
            login: typeof value.login === "string" ? value.login : null,
        };
    } catch {
        return null;
    }
}

export function saveSession(storage: Pick<Storage, "setItem"> | undefined, session: GitHubSession): void {
    try {
        storage?.setItem(KEY, JSON.stringify(session));
    } catch {
        // Storage can be unavailable in a locked-down frame; the sign-in still works until the page reloads.
    }
}

export function clearSession(storage: Pick<Storage, "removeItem"> | undefined): void {
    try {
        storage?.removeItem(KEY);
    } catch {
        // Nothing to clear.
    }
}

export type SessionState = "valid" | "refresh" | "expired";

/** Whether the stored sign-in can start a conversation now, needs renewing first, or needs a new sign-in. */
export function sessionState(session: GitHubSession, now: number): SessionState {
    if (session.expiresAt === null || session.expiresAt - now > REFRESH_MARGIN_MS) return "valid";
    if (session.refreshToken && (session.refreshExpiresAt === null || session.refreshExpiresAt > now)) return "refresh";
    return session.expiresAt > now ? "valid" : "expired";
}
