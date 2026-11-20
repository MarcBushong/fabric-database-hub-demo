import { describe, expect, it, vi } from "vitest";

import { deviceStartOf, loadSession, renewSession, saveSession, SESSION_KEY, waitForDeviceToken, type GitHubSession, type LockManagerLike } from "./github-session";
import { isTransient, RelayError, type DevicePoll } from "./relay";

// Built at run time so secret scanners never see a token-shaped literal.
const token = (prefix: string, fill: string) => [prefix, fill.repeat(36)].join("_");
const HOUR = 60 * 60 * 1000;
const T0 = Date.UTC(2026, 10, 19, 8);

function memoryStorage(): Storage {
    const items = new Map<string, string>();
    return {
        get length() {
            return items.size;
        },
        clear: () => items.clear(),
        getItem: (key: string) => items.get(key) ?? null,
        key: (index: number) => [...items.keys()][index] ?? null,
        removeItem: (key: string) => void items.delete(key),
        setItem: (key: string, value: string) => void items.set(key, value),
    };
}

/** A device-flow sign-in at T0: an 8-hour token and a 6-month refresh token. */
const signedIn = (access = token("gho", "A"), refresh = token("ghr", "A")): GitHubSession => ({
    accessToken: access,
    expiresAt: T0 + 8 * HOUR,
    refreshToken: refresh,
    refreshExpiresAt: T0 + 180 * 24 * HOUR,
    login: "octo",
});

const renewedPoll = (access: string, refresh: string): DevicePoll => ({ status: "ok", accessToken: access, expiresIn: 8 * 3600, refreshToken: refresh, refreshTokenExpiresIn: 180 * 24 * 3600 });

describe("renewing the GitHub sign-in (security review, 2026-11-19)", () => {
    it("renews a token 9 hours after sign-in with the refresh token, and keeps it", async () => {
        const storage = memoryStorage();
        const current = signedIn();
        saveSession(storage, current);
        const refresh = vi.fn(async () => renewedPoll(token("gho", "B"), token("ghr", "B")));
        const outcome = await renewSession({ storage, current, refresh, now: () => T0 + 9 * HOUR, locks: null });
        expect(refresh).toHaveBeenCalledWith(current.refreshToken);
        expect(outcome).toMatchObject({ kind: "ok", session: { accessToken: token("gho", "B"), login: "octo" } });
        expect(loadSession(storage)?.accessToken).toBe(token("gho", "B"));
    });

    it("keeps the sign-in when the renewal fails on the way, so a later try can renew it", async () => {
        const storage = memoryStorage();
        const current = signedIn();
        saveSession(storage, current);
        const refresh = vi.fn(async () => {
            throw new RelayError("The chat relay answered HTTP 502.", 502);
        });
        const outcome = await renewSession({ storage, current, refresh, now: () => T0 + 9 * HOUR, locks: null });
        expect(outcome.kind).toBe("unavailable");
        expect(loadSession(storage)).toEqual(current);
    });

    it("takes the token another tab renewed instead of spending the used refresh token", async () => {
        const storage = memoryStorage();
        const mine = signedIn();
        const theirs = { ...signedIn(token("gho", "C"), token("ghr", "C")), expiresAt: T0 + 17 * HOUR };
        saveSession(storage, theirs);
        const refresh = vi.fn(async () => ({ status: "expired" }) as DevicePoll);
        const outcome = await renewSession({ storage, current: mine, refresh, now: () => T0 + 9 * HOUR, locks: null });
        expect(refresh).not.toHaveBeenCalled();
        expect(outcome).toMatchObject({ kind: "ok", session: { accessToken: token("gho", "C") } });
    });

    it("keeps the other tab's tokens when both renewed at once and GitHub refused this tab's", async () => {
        const storage = memoryStorage();
        const mine = signedIn();
        saveSession(storage, mine);
        const theirs = { ...signedIn(token("gho", "D"), token("ghr", "D")), expiresAt: T0 + 17 * HOUR };
        // The other tab saves its renewal while this tab's request is on its way; GitHub then refuses the used refresh token.
        const refresh = vi.fn(async () => {
            saveSession(storage, theirs);
            return { status: "expired" } as DevicePoll;
        });
        const outcome = await renewSession({ storage, current: mine, refresh, now: () => T0 + 9 * HOUR, locks: null });
        expect(outcome).toMatchObject({ kind: "ok", session: { accessToken: token("gho", "D") } });
        expect(loadSession(storage)?.accessToken).toBe(token("gho", "D"));
    });

    it("ends the sign-in only when GitHub refuses the refresh token itself", async () => {
        const storage = memoryStorage();
        const current = signedIn();
        saveSession(storage, current);
        const outcome = await renewSession({ storage, current, refresh: async () => ({ status: "expired" }), now: () => T0 + 9 * HOUR, locks: null });
        expect(outcome).toEqual({ kind: "expired" });
    });

    it("renews in one tab at a time, under the browser's lock", async () => {
        const storage = memoryStorage();
        const current = signedIn();
        saveSession(storage, current);
        const names: string[] = [];
        const locks: LockManagerLike = {
            request: (name, callback) => {
                names.push(name);
                return callback();
            },
        };
        await renewSession({ storage, current, refresh: async () => renewedPoll(token("gho", "E"), token("ghr", "E")), now: () => T0 + 9 * HOUR, locks });
        expect(names).toEqual(["dbhub-insights.github.renew"]);
        expect(SESSION_KEY).toBe("dbhub-insights.github.v1");
    });
});

describe("waiting for GitHub's device flow (security review, 2026-11-19)", () => {
    const run = (polls: Array<DevicePoll | Error>, expiresIn = 900) => {
        let t = T0;
        const waits: number[] = [];
        const poll = vi.fn(async () => {
            const next = polls.shift();
            if (!next) return { status: "pending", interval: 5 } as DevicePoll;
            if (next instanceof Error) throw next;
            return next;
        });
        const outcome = waitForDeviceToken({
            poll,
            sleep: async (ms) => {
                waits.push(ms / 1000);
                t += ms;
            },
            now: () => t,
            expiresAt: T0 + expiresIn * 1000,
            interval: 5,
            cancelled: () => false,
            isTransient,
        });
        return { outcome, waits, poll };
    };

    it("keeps polling through a relay that's waking or a network blip, waiting longer, until GitHub answers", async () => {
        const { outcome, waits } = run([new RelayError("The chat relay can't be reached from this page.", 0, "unreachable"), new RelayError("Bad gateway", 502), { status: "pending", interval: 5 }, renewedPoll(token("gho", "F"), token("ghr", "F"))]);
        expect(await outcome).toMatchObject({ status: "ok", accessToken: token("gho", "F") });
        expect(waits).toEqual([5, 10, 15, 15]);
    });

    it("stops at a refusal, and when the code expires", async () => {
        expect(await run([new RelayError("This relay serves only its own Insights app.", 403, "origin_not_allowed")]).outcome).toMatchObject({ status: "error" });
        expect(await run([{ status: "denied" }]).outcome).toEqual({ status: "denied" });
        const blips = Array.from({ length: 50 }, () => new RelayError("Bad gateway", 502));
        expect(await run(blips, 60).outcome).toEqual({ status: "expired" });
    });
});

describe("a device-flow start from the relay (the review of 1c94891, 2026-11-20)", () => {
    const start = { deviceCode: "d".repeat(40), userCode: "WDJB-MJHT", expiresIn: 900, interval: 5 };

    it("keeps GitHub's codes and timing, and nothing of the address the relay names", () => {
        for (const verificationUri of ["https://github.com/login/device", "https://github-login.example/device", "http://github.com/login/device", "https://github.com.evil.example/login/device", "https://user@github.com/login/device", "javascript:alert(1)", undefined, 42]) {
            expect(deviceStartOf({ ...start, verificationUri })).toEqual({ deviceCode: start.deviceCode, userCode: "WDJB-MJHT", expiresIn: 900, interval: 5 });
        }
    });

    it("has no code to show for an answer without GitHub's codes, and takes GitHub's defaults for its timing", () => {
        const noCode: unknown[] = [
            null,
            "WDJB-MJHT",
            {},
            { deviceCode: "d" },
            { userCode: "WDJB-MJHT" },
            { deviceCode: "d", userCode: "" },
            { deviceCode: "d", userCode: "Enter your GitHub password at github-login.example" },
            { deviceCode: "x".repeat(300), userCode: "WDJB-MJHT" },
        ];
        for (const answer of noCode) expect(deviceStartOf(answer)).toBeNull();
        expect(deviceStartOf({ deviceCode: "d", userCode: " WDJB-MJHT ", expiresIn: "soon", interval: -1 })).toEqual({ deviceCode: "d", userCode: "WDJB-MJHT", expiresIn: 900, interval: 5 });
        expect(deviceStartOf({ deviceCode: "d", userCode: "WDJB-MJHT", expiresIn: 86400, interval: 600 })).toMatchObject({ expiresIn: 1800, interval: 60 });
    });
});
