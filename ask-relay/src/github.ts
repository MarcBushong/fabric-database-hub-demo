// GitHub sign-in through the OAuth device flow, which needs only the app's public client ID: no client secret,
// so the relay holds no credential. GitHub's OAuth endpoints don't allow browser calls (no CORS), so the page
// asks the relay, which calls GitHub and hands the result back; it keeps nothing.
// https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

const DEVICE_CODE_URL = "https://github.com/login/device/code";
const TOKEN_URL = "https://github.com/login/oauth/access_token";
const USER_URL = "https://api.github.com/user";
const TIMEOUT_MS = 15000;

export interface DeviceStart {
    deviceCode: string;
    userCode: string;
    verificationUri: string;
    expiresIn: number;
    interval: number;
}

export type DevicePoll =
    | { status: "pending"; interval: number }
    | { status: "slow_down"; interval: number }
    | { status: "expired" }
    | { status: "denied" }
    | { status: "ok"; accessToken: string; expiresIn: number | null; refreshToken: string | null; refreshTokenExpiresIn: number | null }
    | { status: "error"; message: string };

export class GitHubError extends Error {
    readonly status: number;
    constructor(message: string, status: number) {
        super(message);
        this.name = "GitHubError";
        this.status = status;
    }
}

async function postForm(fetchImpl: FetchLike, url: string, body: Record<string, string>): Promise<Record<string, unknown>> {
    const response = await fetchImpl(url, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "dbhub-ask-relay" },
        body: new URLSearchParams(body).toString(),
        signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const value = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    if (!response.ok && typeof value.error !== "string") throw new GitHubError(`GitHub answered HTTP ${response.status}.`, response.status);
    return value;
}

const num = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);

export async function startDeviceFlow(fetchImpl: FetchLike, clientId: string, scopes: string): Promise<DeviceStart> {
    const body: Record<string, string> = { client_id: clientId };
    if (scopes) body.scope = scopes;
    const value = await postForm(fetchImpl, DEVICE_CODE_URL, body);
    if (typeof value.error === "string") {
        const hint = value.error === "device_flow_disabled" ? " Turn on Enable Device Flow in the GitHub app's settings." : "";
        throw new GitHubError(`GitHub refused the sign-in: ${value.error}.${hint}`, 400);
    }
    if (typeof value.device_code !== "string" || typeof value.user_code !== "string" || typeof value.verification_uri !== "string") {
        throw new GitHubError("GitHub's answer had no device code.", 502);
    }
    return {
        deviceCode: value.device_code,
        userCode: value.user_code,
        verificationUri: value.verification_uri,
        expiresIn: num(value.expires_in, 900),
        interval: num(value.interval, 5),
    };
}

function tokenResult(value: Record<string, unknown>): DevicePoll | null {
    if (typeof value.access_token !== "string" || !value.access_token) return null;
    return {
        status: "ok",
        accessToken: value.access_token,
        // Present when the app expires user tokens (8 hours, with a 6-month refresh token).
        expiresIn: typeof value.expires_in === "number" ? value.expires_in : null,
        refreshToken: typeof value.refresh_token === "string" && value.refresh_token ? value.refresh_token : null,
        refreshTokenExpiresIn: typeof value.refresh_token_expires_in === "number" ? value.refresh_token_expires_in : null,
    };
}

export async function pollDeviceFlow(fetchImpl: FetchLike, clientId: string, deviceCode: string): Promise<DevicePoll> {
    const value = await postForm(fetchImpl, TOKEN_URL, {
        client_id: clientId,
        device_code: deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    });
    const ok = tokenResult(value);
    if (ok) return ok;
    switch (value.error) {
        case "authorization_pending":
            return { status: "pending", interval: num(value.interval, 5) };
        case "slow_down":
            return { status: "slow_down", interval: num(value.interval, 10) };
        case "expired_token":
            return { status: "expired" };
        case "access_denied":
            return { status: "denied" };
        default:
            return { status: "error", message: typeof value.error === "string" ? value.error : "unknown" };
    }
}

/**
 * Renews an expiring user token. A token from the device flow refreshes without the client secret
 * (https://docs.github.com/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens).
 */
export async function refreshToken(fetchImpl: FetchLike, clientId: string, refresh: string): Promise<DevicePoll> {
    const value = await postForm(fetchImpl, TOKEN_URL, { client_id: clientId, grant_type: "refresh_token", refresh_token: refresh });
    const ok = tokenResult(value);
    if (ok) return ok;
    return value.error === "bad_refresh_token" ? { status: "expired" } : { status: "error", message: typeof value.error === "string" ? value.error : "unknown" };
}

export interface GitHubUser {
    login: string;
    name: string | null;
    avatarUrl: string | null;
}

/** Who the token belongs to; the relay uses it to show the viewer's GitHub account and never stores it. */
export async function getUser(fetchImpl: FetchLike, token: string): Promise<GitHubUser> {
    const response = await fetchImpl(USER_URL, {
        headers: { Accept: "application/vnd.github+json", Authorization: `Bearer ${token}`, "User-Agent": "dbhub-ask-relay", "X-GitHub-Api-Version": "2022-11-28" },
        signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (response.status === 401) throw new GitHubError("GitHub didn't accept the sign-in any more. Sign in to GitHub again.", 401);
    if (!response.ok) throw new GitHubError(`GitHub answered HTTP ${response.status}.`, response.status);
    const value = (await response.json()) as Record<string, unknown>;
    if (typeof value.login !== "string") throw new GitHubError("GitHub's answer had no login.", 502);
    return {
        login: value.login,
        name: typeof value.name === "string" ? value.name : null,
        avatarUrl: typeof value.avatar_url === "string" && value.avatar_url.startsWith("https://") ? value.avatar_url : null,
    };
}
