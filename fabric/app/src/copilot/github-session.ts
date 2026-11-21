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

/** The key the sign-in is kept under; a change to it from another tab arrives as a storage event. */
export const SESSION_KEY = "dbhub-insights.github.v1";
const KEY = SESSION_KEY;
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

/** What renewing a sign-in came to. Only "expired" means the viewer must sign in again. */
export type Renewal =
    | { kind: "ok"; session: GitHubSession }
    /** GitHub refused the refresh token (it's used, revoked, or past its 6 months), or there's none left. */
    | { kind: "expired" }
    /** Another tab signed out. */
    | { kind: "signed-out" }
    /** The relay or GitHub couldn't renew it just now; the sign-in stays, and a later try can renew it. */
    | { kind: "unavailable"; message: string };

export interface LockManagerLike {
    request<T>(name: string, callback: () => Promise<T>): Promise<T>;
}

export interface RenewOptions {
    storage: (Pick<Storage, "getItem" | "setItem">) | undefined;
    /** The sign-in this tab holds. */
    current: GitHubSession;
    refresh: (refreshToken: string) => Promise<DevicePoll>;
    now: () => number;
    /** Renew even a token that looks valid: GitHub just refused it. */
    force?: boolean;
    /** Serializes renewals across this browser's tabs; navigator.locks where the browser has it. */
    locks?: LockManagerLike | null;
}

const RENEW_LOCK = "dbhub-insights.github.renew";

function browserLocks(): LockManagerLike | null {
    const locks = typeof navigator !== "undefined" ? (navigator as Navigator & { locks?: LockManagerLike }).locks : undefined;
    return locks && typeof locks.request === "function" ? locks : null;
}

/**
 * Renews the viewer's GitHub sign-in through the relay, one tab at a time. A refresh token works once, so another tab
 * may have renewed since this one read storage: storage is read again first, and again after GitHub refuses a refresh
 * token. The sign-in ends only when GitHub refuses it for good.
 */
export async function renewSession(options: RenewOptions): Promise<Renewal> {
    const locks = options.locks === undefined ? browserLocks() : options.locks;
    return locks ? locks.request(RENEW_LOCK, () => renewNow(options)) : renewNow(options);
}

async function renewNow({ storage, current, refresh, now, force = false }: RenewOptions): Promise<Renewal> {
    // Without storage (a locked-down frame), this tab's own sign-in is the only one.
    const stored = storage ? loadSession(storage) : current;
    if (!stored) return { kind: "signed-out" };
    const t = now();
    if (stored.accessToken !== current.accessToken && sessionState(stored, t) === "valid") return { kind: "ok", session: stored };
    if (!force && sessionState(stored, t) === "valid") return { kind: "ok", session: stored };
    const refreshToken = stored.refreshToken && (stored.refreshExpiresAt === null || stored.refreshExpiresAt > t) ? stored.refreshToken : null;
    if (!refreshToken) return force || sessionState(stored, t) === "expired" ? { kind: "expired" } : { kind: "ok", session: stored };
    let renewed: DevicePoll;
    try {
        renewed = await refresh(refreshToken);
    } catch (err) {
        return { kind: "unavailable", message: err instanceof Error ? err.message : String(err) };
    }
    if (renewed.status === "ok") {
        const next = fromPoll(renewed, now(), stored.login);
        saveSession(storage, next);
        return { kind: "ok", session: next };
    }
    if (renewed.status === "expired") {
        const again = storage ? loadSession(storage) : null;
        if (again && again.accessToken !== stored.accessToken) return { kind: "ok", session: again };
        return { kind: "expired" };
    }
    return { kind: "unavailable", message: renewed.status === "error" ? renewed.message : renewed.status };
}

export type DeviceOutcome = Extract<DevicePoll, { status: "ok" | "denied" | "expired" | "error" }> | { status: "cancelled" };

/** GitHub's device page on github.com: the only page the sign-in sends a viewer to, whatever the relay's answer names. */
export const GITHUB_DEVICE_URL = "https://github.com/login/device";
/** The same page as the panel and the header name it. */
export const GITHUB_DEVICE_PAGE = "github.com/login/device";

/** A device-flow start as the page uses it: GitHub's two codes and its timing, with no address in it. */
export interface DeviceCode {
    deviceCode: string;
    userCode: string;
    /** Seconds until GitHub's codes expire. */
    expiresIn: number;
    /** Seconds between polls, as GitHub asked. */
    interval: number;
}

/** A sign-in code as GitHub shows one ("WDJB-MJHT"): letters, digits, and hyphens, never a sentence a viewer could follow. */
const USER_CODE = /^[A-Za-z0-9-]{4,16}$/;
const seconds = (value: unknown, fallback: number, max: number) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.min(value, max) : fallback);

/**
 * The relay's answer to a device-flow start, checked (the review of 1c94891, 2026-11-20): GitHub's two codes, with GitHub's
 * defaults for a missing expiry or interval, or null when it has no code to show. Its verification URI is never used: the
 * relay passes GitHub's on as a string it doesn't check, so a relay that's compromised or misconfigured could name a
 * lookalike page that asks for a GitHub password. The page sends viewers only to GITHUB_DEVICE_URL, the one address
 * GitHub's device flow uses for github.com.
 */
export function deviceStartOf(raw: unknown): DeviceCode | null {
    if (!raw || typeof raw !== "object") return null;
    const answer = raw as Record<string, unknown>;
    const deviceCode = typeof answer.deviceCode === "string" ? answer.deviceCode : "";
    const userCode = typeof answer.userCode === "string" ? answer.userCode.trim() : "";
    if (!deviceCode || deviceCode.length > 256 || !USER_CODE.test(userCode)) return null;
    return { deviceCode, userCode, expiresIn: seconds(answer.expiresIn, 900, 1800), interval: seconds(answer.interval, 5, 60) };
}

export interface DeviceWaitOptions {
    poll: () => Promise<DevicePoll>;
    sleep: (ms: number) => Promise<void>;
    now: () => number;
    /** When GitHub's code expires (epoch milliseconds). */
    expiresAt: number;
    /** Seconds between polls, as GitHub asked. */
    interval: number;
    cancelled: () => boolean;
    /** Whether a failed poll is worth trying again (the relay starting, a network blip), not a refusal. */
    isTransient: (err: unknown) => boolean;
}

/**
 * Polls GitHub's device flow until the viewer authorizes, refuses, or the code expires. A poll that fails on the way
 * counts as still pending, with a longer wait, so a blip doesn't end a sign-in the viewer is finishing.
 */
export async function waitForDeviceToken(options: DeviceWaitOptions): Promise<DeviceOutcome> {
    let interval = Math.max(5, options.interval);
    while (!options.cancelled() && options.now() < options.expiresAt) {
        await options.sleep(interval * 1000);
        if (options.cancelled()) return { status: "cancelled" };
        let poll: DevicePoll;
        try {
            poll = await options.poll();
        } catch (err) {
            if (!options.isTransient(err)) return { status: "error", message: err instanceof Error ? err.message : String(err) };
            interval = Math.min(interval + 5, 30);
            continue;
        }
        if (poll.status === "pending") continue;
        if (poll.status === "slow_down") {
            interval = Math.max(interval + 5, poll.interval);
            continue;
        }
        return poll;
    }
    return options.cancelled() ? { status: "cancelled" } : { status: "expired" };
}
