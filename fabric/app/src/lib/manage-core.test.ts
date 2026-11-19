// @vitest-environment node
// The Manage function's checks (rayfin/functions/src/manage-core.ts, ADR 0028), run with Node's Web Crypto: a token
// signed with a key of the test's own, its JWKS served by a stand-in for the app's API.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { checkRequest, isOperator, jobParameters, requestedByOf, SCENARIO_RULES, SESSION_BOUNDS, verifyCaller, type ManageRequest, type VerifiedCaller } from "../../rayfin/functions/src/manage-core";
import { notebookParameters, type ControlRequest } from "./control";
import { SESSION_MINUTES } from "./scenarios";

const API = "https://example.invalid/v1/workspaces/w/appbackends/a/BaaSService/";
const NOW = Date.UTC(2026, 10, 18, 12);
const ZERO = "00000000-0000-0000-0000-000000000000";
const b64url = (data: ArrayBuffer | string) => Buffer.from(typeof data === "string" ? data : new Uint8Array(data)).toString("base64url");

async function signer(kid = "k1") {
    const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
    const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, alg: "RS256" };
    const sign = async (claims: Record<string, unknown>, header: Record<string, unknown> = { alg: "RS256", kid, typ: "JWT" }) => {
        const h = b64url(JSON.stringify(header));
        const p = b64url(JSON.stringify(claims));
        const s = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(`${h}.${p}`));
        return `${h}.${p}.${b64url(s)}`;
    };
    return { jwk, sign };
}

const claims = (extra: Record<string, unknown> = {}) => ({ sub: "user-1", aud: "app", exp: NOW / 1000 + 600, email: "Ops@Contoso.example", oid: ZERO, ...extra });

function jwksAt(keys: object[], status = 200) {
    return vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        void init;
        return new Response(JSON.stringify({ keys }), { status: String(url).endsWith("/.well-known/jwks.json") && !String(url).includes("/api/auth/") ? status : 404, headers: { "content-type": "application/json" } });
    });
}

describe("the Manage function's caller", () => {
    it("verifies the caller's token with the app's own keys, read only from the pinned API", async () => {
        const { jwk, sign } = await signer();
        const fetch = jwksAt([jwk]);
        const caller = await verifyCaller(await sign(claims()), { apiUrl: API, publishableKey: "pk-test" }, { fetch, now: () => NOW });
        expect(caller).toEqual({ verified: true, objectId: ZERO, names: ["ops@contoso.example"], display: "ops@contoso.example" });
        expect(fetch).toHaveBeenCalledWith("https://example.invalid/v1/workspaces/w/appbackends/a/BaaSService/.well-known/jwks.json", { headers: { "X-Publishable-Key": "pk-test" } });
        expect(fetch.mock.calls.every(([url]) => String(url).startsWith("https://example.invalid/v1/workspaces/w/appbackends/a/BaaSService/"))).toBe(true);
    });

    it("refuses a tampered, expired, foreign, or unsigned token, and one whose keys it can't read", async () => {
        const { jwk, sign } = await signer();
        const deps = { fetch: jwksAt([jwk]), now: () => NOW };
        const settings = { apiUrl: API, publishableKey: "pk-test" };
        const token = await sign(claims());
        const [h, , s] = token.split(".");
        const forged = `${h}.${b64url(JSON.stringify(claims({ email: "intruder@contoso.example" })))}.${s}`;
        expect(await verifyCaller(forged, settings, deps)).toEqual({ verified: false, reason: "the caller's token isn't signed by the app" });
        expect(await verifyCaller(await sign(claims({ exp: NOW / 1000 - 1 })), settings, deps)).toMatchObject({ verified: false, reason: "the caller's token has expired" });
        const other = await signer("k2");
        expect(await verifyCaller(await other.sign(claims()), settings, deps)).toMatchObject({ verified: false, reason: "no key of the app's signs the caller's token" });
        expect(await verifyCaller(`${b64url(JSON.stringify({ alg: "none" }))}.${b64url(JSON.stringify(claims()))}.`, settings, deps)).toMatchObject({ verified: false });
        expect(await verifyCaller(token, { apiUrl: "", publishableKey: "pk-test" }, deps)).toMatchObject({ verified: false, reason: "the function has no pinned API to read its keys from" });
        expect(await verifyCaller(token, settings, { fetch: jwksAt([jwk], 401), now: () => NOW })).toMatchObject({ verified: false, reason: "the app's keys couldn't be read" });
        expect(await verifyCaller("not-a-token", settings, deps)).toMatchObject({ verified: false });
    });

    it("finds operators by object ID or by name, and records who sent a request in the control's characters", () => {
        const caller: VerifiedCaller = { verified: true, objectId: ZERO, names: ["ops@contoso.example"], display: "ops@contoso.example" };
        expect(isOperator(caller, { operators: [{ objectId: ZERO, names: [] }] })).toBe(true);
        expect(isOperator({ ...caller, objectId: "" }, { operators: [{ objectId: "x", names: ["ops@contoso.example"] }] })).toBe(true);
        expect(isOperator({ ...caller, objectId: "" }, { operators: [{ objectId: ZERO, names: ["dba@contoso.example"] }] })).toBe(false);
        expect(requestedByOf(caller)).toBe("app/ops@contoso.example");
        expect(requestedByOf({ ...caller, display: "Ops Person (DBA)" })).toBe("app/Ops-Person--DBA-");
        expect(requestedByOf({ ...caller, display: "x".repeat(100) })).toHaveLength(64);
    });
});

describe("the Manage function's requests", () => {
    it("accepts only the documented actions and values, within the control's caps", () => {
        expect(checkRequest({ action: "session" })).toEqual({ ok: true, request: { action: "session", durationMinutes: 90 } });
        expect(checkRequest({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10, intensity: 6 })).toMatchObject({ ok: true });
        expect(checkRequest({ action: "reset", targets: ["T1", "T1", "T3"] })).toEqual({ ok: true, request: { action: "reset", targets: ["T1", "T3"] } });
        for (const bad of [
            null,
            [],
            { action: "deploy" },
            { action: "stop", force: true },
            { action: "session", durationMinutes: 240 },
            { action: "session", durationMinutes: "90" },
            { action: "run", scenario: "replica-lag", target: "T1" },
            { action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 31 },
            { action: "run", scenario: "cpu-pressure", target: "T3", intensity: 11 },
            { action: "run", scenario: "drop-database", target: "T3" },
            { action: "reset", targets: ["T5"] },
        ]) {
            expect(checkRequest(bad)).toMatchObject({ ok: false });
        }
    });

    it("keeps the catalog's rules: scenarios/*/scenario.json and the session's bounds", () => {
        const root = join(process.cwd(), "..", "..", "scenarios");
        const fromRepo = readdirSync(root, { withFileTypes: true })
            .filter((d) => d.isDirectory())
            .map((d) => JSON.parse(readFileSync(join(root, d.name, "scenario.json"), "utf8")) as { id: string; duration: { defaultSeconds: number; maxSeconds: number }; targets: { applicable: string[] } })
            .map((s) => ({ id: s.id, targets: s.targets.applicable, defaultMinutes: Math.round(s.duration.defaultSeconds / 60), maxMinutes: Math.floor(s.duration.maxSeconds / 60) }))
            .sort((a, b) => a.id.localeCompare(b.id));
        expect(SCENARIO_RULES).toEqual(fromRepo);
        expect(SESSION_BOUNDS).toEqual(SESSION_MINUTES);
    });

    it("runs the control with the app's parameters, plus who sent it", () => {
        const requests: Array<ControlRequest & ManageRequest> = [
            { action: "session", durationMinutes: 60 },
            { action: "run", scenario: "io-pressure", target: "T2", durationMinutes: 15, intensity: 4 },
            { action: "stop" },
            { action: "reset", targets: ["T1"] },
        ];
        for (const request of requests) {
            const { REQUESTED_BY, ...rest } = jobParameters(request, "app/ops@contoso.example");
            expect(REQUESTED_BY).toEqual({ value: "app/ops@contoso.example", type: "string" });
            expect(rest).toEqual(notebookParameters(request));
        }
    });
});
