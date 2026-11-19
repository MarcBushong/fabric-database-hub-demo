// @vitest-environment node
// The Manage function's checks and answers (rayfin/functions/src/manage-core.ts, ADR 0029), run with Node's Web Crypto:
// a token signed with a key of the test's own, its JWKS served by a stand-in for the app's API, and a stand-in for
// Fabric's job API. The control's catalog is built from scenarios/ the way the deploy builds it for the function
// (Get-DemoActivityControlCatalog and the showcase profile).
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import {
    answerAccess,
    answerJob,
    answerRequest,
    checkRequest,
    isOperator,
    jobParameters,
    requestedByOf,
    verifyCaller,
    type ControlCatalog,
    type ManageSettings,
    type TokenBinding,
    type VerifiedCaller,
} from "../../rayfin/functions/src/manage-core";
import { notebookParameters, type ControlRequest } from "./control";
import { functionsManageApi, manageAccessOf } from "./manage-client";
import { SESSION_MINUTES } from "./scenarios";

const API = "https://example.invalid/v1/tenants/t/workspaces/w/appbackends/a/BaaSService/";
const NOW = Date.UTC(2026, 10, 18, 12);
const ZERO = "00000000-0000-0000-0000-000000000000";
const TENANT = "11111111-1111-1111-1111-111111111111";
const WORKSPACE = "22222222-2222-2222-2222-222222222222";
const APP = "33333333-3333-3333-3333-333333333333";
const OTHER = "44444444-4444-4444-4444-444444444444";
const ISSUER = "https://issuer.example.invalid/";
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

/** A token with Entra's identity claims, for this app (aud) and tenant (tid). */
const claims = (extra: Record<string, unknown> = {}) => ({ sub: "user-1", aud: APP, iss: ISSUER, tid: TENANT, exp: NOW / 1000 + 600, email: "Ops@Contoso.example", oid: ZERO, ...extra });
/** A token as the Rayfin client reads Fabric's managed hosting's: the app's user path as its subject, its email for the app in xms_attr. */
const managed = (extra: Record<string, unknown> = {}) => ({
    sub: `/tenants/${TENANT}/workspaces/${WORKSPACE}/appbackends/${APP}/users/u-1`,
    aud: "fabric-apps",
    iss: ISSUER,
    idtyp: "fmi",
    exp: NOW / 1000 + 600,
    xms_attr: { [APP]: { rfn_email: "Ops@Contoso.example" }, [OTHER]: { rfn_email: "someone@contoso.example" } },
    ...extra,
});
const BINDING: TokenBinding = { apiUrl: API, publishableKey: "pk-test", tenantId: TENANT, workspaceId: WORKSPACE, appId: APP, issuer: "", audience: "" };

function jwksAt(keys: object[], status = 200) {
    return vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        void init;
        return new Response(JSON.stringify({ keys }), { status: String(url).endsWith("/.well-known/jwks.json") ? status : 404, headers: { "content-type": "application/json" } });
    });
}

/** The control's catalog, as the deploy writes it for the function: T5 only while it's on. */
function controlCatalog(targets: string[] = ["T1", "T2", "T3", "T4", "T5"]): ControlCatalog {
    const root = join(process.cwd(), "..", "..", "scenarios");
    const scenarios: Record<string, { maxMinutes: number; maxConcurrency: number; targets: string[] }> = {};
    for (const entry of readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory() && e.name !== "healthy-baseline").sort((a, b) => a.name.localeCompare(b.name))) {
        const path = join(root, entry.name, "scenario.json");
        if (!existsSync(path)) continue;
        const s = JSON.parse(readFileSync(path, "utf8")) as { duration: { maxSeconds: number }; concurrency: { max: number }; targets: { applicable: string[] } };
        scenarios[entry.name] = { maxMinutes: Math.floor(s.duration.maxSeconds / 60), maxConcurrency: s.concurrency.max, targets: s.targets.applicable };
    }
    const showcase = (JSON.parse(readFileSync(join(root, "activity-profiles.json"), "utf8")) as { profiles: { showcase: { maxDurationMinutes: number; defaultDurationMinutes: number } } }).profiles.showcase;
    return { targets, scenarios, minDurationMinutes: 5, maxDurationMinutes: 120, session: { minMinutes: 30, maxMinutes: showcase.maxDurationMinutes, defaultMinutes: showcase.defaultDurationMinutes } };
}

describe("the Manage function's caller", () => {
    it("verifies the caller's token with the app's own keys, read only from the pinned API, and binds it to this app", async () => {
        const { jwk, sign } = await signer();
        const fetch = jwksAt([jwk]);
        const caller = await verifyCaller(await sign(claims()), BINDING, { fetch, now: () => NOW });
        expect(caller).toEqual({ verified: true, objectId: ZERO, names: ["ops@contoso.example"], display: "ops@contoso.example" });
        expect(fetch).toHaveBeenCalledWith("https://example.invalid/v1/tenants/t/workspaces/w/appbackends/a/BaaSService/.well-known/jwks.json", { headers: { "X-Publishable-Key": "pk-test" } });
        expect(fetch.mock.calls.every(([url]) => String(url).startsWith(API))).toBe(true);
    });

    it("refuses a tampered, expired, foreign, or unsigned token, and one whose keys it can't read", async () => {
        const { jwk, sign } = await signer();
        const deps = { fetch: jwksAt([jwk]), now: () => NOW };
        const token = await sign(claims());
        const [h, , s] = token.split(".");
        const forged = `${h}.${b64url(JSON.stringify(claims({ email: "intruder@contoso.example" })))}.${s}`;
        expect(await verifyCaller(forged, BINDING, deps)).toEqual({ verified: false, reason: "the caller's token isn't signed by the app" });
        expect(await verifyCaller(await sign(claims({ exp: NOW / 1000 - 1 })), BINDING, deps)).toMatchObject({ verified: false, reason: "the caller's token has expired" });
        const other = await signer("k2");
        expect(await verifyCaller(await other.sign(claims()), BINDING, deps)).toMatchObject({ verified: false, reason: "no key of the app's signs the caller's token" });
        expect(await verifyCaller(`${b64url(JSON.stringify({ alg: "none" }))}.${b64url(JSON.stringify(claims()))}.`, BINDING, deps)).toMatchObject({ verified: false });
        expect(await verifyCaller(await sign(claims(), { alg: "HS256", kid: "k1" }), BINDING, deps)).toMatchObject({ verified: false, reason: "the caller's token is signed with HS256, which the function doesn't accept" });
        expect(await verifyCaller(token, { ...BINDING, apiUrl: "" }, deps)).toMatchObject({ verified: false, reason: "the function has no pinned API to read its keys from" });
        expect(await verifyCaller(token, BINDING, { fetch: jwksAt([jwk], 401), now: () => NOW })).toMatchObject({ verified: false, reason: "the app's keys couldn't be read" });
        expect(await verifyCaller("not-a-token", BINDING, deps)).toMatchObject({ verified: false });
    });

    it("refuses a token for another tenant or another app, from another issuer or audience once they're pinned, or naming no one", async () => {
        const { jwk, sign } = await signer();
        const deps = { fetch: jwksAt([jwk]), now: () => NOW };
        const reason = async (c: Record<string, unknown>, binding = BINDING) => {
            const caller = await verifyCaller(await sign(c), binding, deps);
            return caller.verified ? "" : caller.reason;
        };
        expect(await reason(claims({ tid: OTHER }))).toBe("the caller's token is for another tenant");
        expect(await reason(claims({ aud: OTHER }))).toBe("the caller's token isn't for this app");
        expect(await reason(claims({ aud: [OTHER, `api://${APP}`] }))).toBe("");
        expect(await reason(claims({ iss: undefined }))).toBe("the caller's token names no issuer");
        expect(await reason(claims({ iss: "https://elsewhere.example.invalid/" }), { ...BINDING, issuer: ISSUER })).toBe("the caller's token is from another issuer");
        expect(await reason(claims(), { ...BINDING, audience: "api://dbhub-insights" })).toBe("the caller's token is for another audience");
        expect(await reason(claims({ aud: "api://dbhub-insights" }), { ...BINDING, issuer: ISSUER, audience: "api://dbhub-insights" })).toBe("");
        expect(await reason(claims({ oid: undefined, email: undefined }))).toBe("the caller's token names no object ID or sign-in name");
    });

    it("reads Fabric's managed token: this app's user path in this tenant, and its email for this app only", async () => {
        const { jwk, sign } = await signer();
        const deps = { fetch: jwksAt([jwk]), now: () => NOW };
        expect(await verifyCaller(await sign(managed()), BINDING, deps)).toEqual({ verified: true, objectId: "", names: ["ops@contoso.example"], display: "ops@contoso.example" });
        const elsewhere = await verifyCaller(await sign(managed({ sub: `/tenants/${TENANT}/workspaces/${WORKSPACE}/appbackends/${OTHER}/users/u-1` })), BINDING, deps);
        expect(elsewhere).toEqual({ verified: false, reason: "the caller's token isn't for this app" });
        const otherTenant = await verifyCaller(await sign(managed({ sub: `/tenants/${OTHER}/workspaces/${WORKSPACE}/appbackends/${APP}/users/u-1` })), BINDING, deps);
        expect(otherTenant).toEqual({ verified: false, reason: "the caller's token is for another tenant" });
    });

    it("finds operators by object ID only when the token has one, else by name, and records who sent a request in the control's characters", () => {
        const operators = { operators: [{ objectId: ZERO, names: ["ops@contoso.example"] }] };
        const caller: VerifiedCaller = { verified: true, objectId: ZERO, names: ["ops@contoso.example"], display: "ops@contoso.example" };
        expect(isOperator(caller, operators)).toBe(true);
        // Names can change: with an object ID that isn't an operator's, a matching name doesn't count.
        expect(isOperator({ ...caller, objectId: OTHER }, operators)).toBe(false);
        expect(isOperator({ ...caller, objectId: "" }, operators)).toBe(true);
        expect(isOperator({ ...caller, objectId: "", names: ["dba@contoso.example"] }, operators)).toBe(false);
        expect(requestedByOf(caller)).toBe("app/ops@contoso.example");
        expect(requestedByOf({ ...caller, display: "Ops Person (DBA)" })).toBe("app/Ops-Person--DBA-");
        expect(requestedByOf({ ...caller, display: "x".repeat(100) })).toHaveLength(64);
    });
});

describe("the Manage function's requests, by the control's own catalog", () => {
    it("keeps the app's session minutes equal to the control's showcase", () => {
        const { session } = controlCatalog();
        expect({ min: session.minMinutes, max: session.maxMinutes, default: session.defaultMinutes }).toEqual(SESSION_MINUTES);
    });

    it("accepts only the documented actions and values within the control's catalog, healthy-baseline as its baseline", () => {
        const catalog = controlCatalog();
        expect(checkRequest({ action: "session" }, catalog)).toEqual({ ok: true, request: { action: "session", durationMinutes: 90 } });
        expect(checkRequest({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10, intensity: 6 }, catalog)).toMatchObject({ ok: true });
        expect(checkRequest({ action: "run", scenario: "healthy-baseline", target: "T5", durationMinutes: 120 }, catalog)).toEqual({ ok: true, request: { action: "run", scenario: "baseline", target: "T5", durationMinutes: 120 } });
        expect(checkRequest({ action: "reset", targets: ["T1", "T1", "T5"] }, catalog)).toEqual({ ok: true, request: { action: "reset", targets: ["T1", "T5"] } });
        expect(checkRequest({ action: "run", scenario: "healthy-baseline", target: "T3", durationMinutes: 121 }, catalog)).toEqual({ ok: false, reason: "healthy-baseline runs 5 to 120 minutes." });
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
            { action: "reset", targets: ["T4-replica"] },
        ]) {
            expect(checkRequest(bad, catalog)).toMatchObject({ ok: false });
        }
    });

    it("refuses T5 while it's off, as the control does", () => {
        const catalog = controlCatalog(["T1", "T2", "T3", "T4"]);
        expect(checkRequest({ action: "run", scenario: "ru-storm", target: "T5", durationMinutes: 10 }, catalog)).toEqual({ ok: false, reason: "ru-storm has no target here." });
        expect(checkRequest({ action: "run", scenario: "healthy-baseline", target: "T5", durationMinutes: 30 }, catalog)).toEqual({ ok: false, reason: "healthy-baseline runs on T1, T2, T3, and T4 here." });
        expect(checkRequest({ action: "reset", targets: ["T5"] }, catalog)).toEqual({ ok: false, reason: "Reset applies to T1, T2, T3, and T4 here." });
    });

    it("runs the control with the app's own parameters, in the control's words, plus who sent it", () => {
        const catalog = controlCatalog();
        const requests: ControlRequest[] = [
            { action: "session", durationMinutes: 60 },
            { action: "run", scenario: "io-pressure", target: "T2", durationMinutes: 15, intensity: 4 },
            { action: "run", scenario: "healthy-baseline", target: "T3", durationMinutes: 30 },
            { action: "stop" },
            { action: "reset", targets: ["T1"] },
        ];
        for (const request of requests) {
            const checked = checkRequest(request, catalog);
            if (!checked.ok) throw new Error(checked.reason);
            const { REQUESTED_BY, ...rest } = jobParameters(checked.request, "app/ops@contoso.example");
            expect(REQUESTED_BY).toEqual({ value: "app/ops@contoso.example", type: "string" });
            expect(rest).toEqual(notebookParameters(request));
        }
        expect(notebookParameters({ action: "run", scenario: "healthy-baseline", target: "T3", durationMinutes: 30 }).ACTIVITIES.value).toBe('[{"target":"T3","scenario":"baseline"}]');
    });
});

describe("the Manage function's answers", () => {
    const SETTINGS: ManageSettings = {
        apiUrl: API,
        tenantId: TENANT,
        workspaceId: WORKSPACE,
        appId: APP,
        issuer: "",
        audience: "",
        controlWorkspaceId: ZERO,
        controlNotebookId: ZERO,
        operators: [{ objectId: ZERO, names: ["ops@contoso.example"] }],
        catalog: controlCatalog(),
    };
    const JOBS = `https://api.fabric.microsoft.com/v1/workspaces/${ZERO}/items/${ZERO}/jobs/instances`;
    const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    const accepted = () => new Response(null, { status: 202, headers: { location: `${JOBS}/${ZERO}` } });
    // A viewer whose token has another object ID: an operator's name wouldn't make them one.
    const viewer = { email: "ops@contoso.example", oid: OTHER };

    /** A stand-in for the app's API (its keys) and Fabric's job API; it records every Fabric call. */
    async function world(run: () => Response | Promise<Response> = accepted) {
        const { jwk, sign } = await signer();
        const fabric: Array<{ url: string; init?: RequestInit }> = [];
        const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
            const u = String(url);
            if (u.startsWith(API)) return json({ keys: [jwk] }, u.endsWith("/.well-known/jwks.json") ? 200 : 404);
            fabric.push({ url: u, init });
            if (u === `${JOBS}?jobType=RunNotebook`) return run();
            if (u === JOBS) return json({ value: [{ id: ZERO, status: "Completed" }, { id: ZERO, status: "InProgress", invokeType: "Manual", startTimeUtc: "2026-11-18T11:30:00.1234567" }] });
            if (u === `${JOBS}/${ZERO}/cancel`) return new Response(null, { status: 202 });
            if (u === `${JOBS}/${ZERO}`) return json({ id: ZERO, status: "Failed", startTimeUtc: "2026-11-18T11:30:00", endTimeUtc: "2026-11-18T11:31:00", failureReason: { errorCode: "NotebookFailed", message: "The webhook refused it." } });
            return json({}, 404);
        });
        const fabricToken = vi.fn(() => "fabric-token-from-the-runtime");
        const call = async (extra: Record<string, unknown> = {}) => ({ token: await sign(claims(extra)), publishableKey: "pk-test", fabricToken });
        return { fabric, fabricToken, call, sign, deps: { fetch, now: () => NOW } };
    }

    it("runs NB_DatabaseHub_Control for a verified operator, with REQUESTED_BY from the verified caller", async () => {
        const w = await world();
        const answer = await answerRequest({ action: "run", scenario: "ru-storm", target: "T5", durationMinutes: 10 }, await w.call(), SETTINGS, w.deps);
        expect(answer).toEqual({ started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example", copy: false, cancelled: [] });
        expect(w.fabric).toHaveLength(1);
        const [{ url, init }] = w.fabric;
        expect(url).toBe(`${JOBS}?jobType=RunNotebook`);
        expect(init?.method).toBe("POST");
        expect(init?.headers).toEqual({ Authorization: "Bearer fabric-token-from-the-runtime", "Content-Type": "application/json" });
        expect(JSON.parse(String(init?.body))).toEqual({
            executionData: {
                parameters: {
                    MODE: { value: "activities", type: "string" },
                    ACTIVITIES: { value: '[{"target":"T5","scenario":"ru-storm"}]', type: "string" },
                    DURATION_MINUTES: { value: 10, type: "int" },
                    WATCH_MINUTES: { value: 0, type: "int" },
                    REQUESTED_BY: { value: "app/ops@contoso.example", type: "string" },
                },
            },
        });
        // The browser can't name the caller: a request that tries is refused before anything runs.
        expect(await answerRequest({ action: "stop", requestedBy: "app/someone-else" }, await w.call(), SETTINGS, w.deps)).toMatchObject({ started: false, copy: false, reason: "Unknown fields: requestedBy." });
        expect(w.fabric).toHaveLength(1);
    });

    it("keeps Manage read-only for a verified viewer who isn't an operator, before any Fabric call", async () => {
        const w = await world();
        const refused = await answerRequest({ action: "stop" }, await w.call(viewer), SETTINGS, w.deps);
        expect(refused).toMatchObject({ started: false, copy: false, reason: expect.stringMatching(/^Only the demo's operators send actions from the app/) });
        expect(await answerAccess(await w.call(viewer), SETTINGS, w.deps)).toEqual({ configured: true, operator: false, reason: refused.reason, who: "ops@contoso.example", running: null, targets: [] });
        expect(w.fabric).toHaveLength(0);
        expect(w.fabricToken).not.toHaveBeenCalled();
    });

    it("hands over to copy mode when it can't confirm the caller: a forged or expired token, or one for another app", async () => {
        const w = await world();
        const good = await w.call();
        const [h, , s] = good.token.split(".");
        const forged = { ...good, token: `${h}.${b64url(JSON.stringify(claims({ email: "intruder@contoso.example" })))}.${s}` };
        expect(await answerRequest({ action: "stop" }, forged, SETTINGS, w.deps)).toEqual({
            started: false,
            jobInstance: "",
            reason: "Manage couldn't confirm who you are (the caller's token isn't signed by the app), so each action copies its request for NB_DatabaseHub_Control, where Run all sends it.",
            requestedBy: "",
            copy: true,
            cancelled: [],
        });
        expect(await answerAccess(await w.call({ exp: NOW / 1000 - 1 }), SETTINGS, w.deps)).toMatchObject({ configured: false, operator: false, reason: expect.stringMatching(/^Manage couldn't confirm who you are \(the caller's token has expired\), so each action copies/) });
        expect(await answerAccess(await w.call({ aud: OTHER }), SETTINGS, w.deps)).toMatchObject({ configured: false, reason: expect.stringMatching(/the caller's token isn't for this app/) });
        expect(await answerJob(ZERO, forged, SETTINGS, w.deps)).toMatchObject({ status: "Unknown", failureReason: expect.stringMatching(/^Manage couldn't confirm who you are/) });
        expect(w.fabric).toHaveLength(0);
        expect(w.fabricToken).not.toHaveBeenCalled();
    });

    it("refuses an action or a value outside the control's catalog, before any Fabric call", async () => {
        const w = await world();
        const call = await w.call();
        const refused = async (request: unknown) => answerRequest(request, call, SETTINGS, w.deps);
        expect(await refused({ action: "deploy" })).toMatchObject({ copy: false, reason: "The action must be session, run, stop, or reset." });
        expect((await refused({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 31 })).reason).toBe("cpu-pressure runs 5 to 30 minutes.");
        expect((await refused({ action: "run", scenario: "ru-storm", target: "T1" })).reason).toBe("ru-storm runs on T5 here.");
        expect((await refused({ action: "session", durationMinutes: 240 })).reason).toBe("A session runs 30 to 120 minutes.");
        expect((await answerRequest({ action: "reset", targets: ["T5"] }, call, { ...SETTINGS, catalog: controlCatalog(["T1", "T2", "T3", "T4"]) }, w.deps)).reason).toBe("Reset applies to T1, T2, T3, and T4 here.");
        expect(w.fabric).toHaveLength(0);
    });

    it("offers copy mode when the job API refuses the run, can't be reached, or the runtime gave no Fabric token", async () => {
        const run = { action: "run", scenario: "healthy-baseline", target: "T3", durationMinutes: 30 };
        let w = await world(() => json({ errorCode: "InsufficientPrivileges", message: "The caller does not have  permission." }, 403));
        expect(await answerRequest(run, await w.call(), SETTINGS, w.deps)).toEqual({
            started: false,
            jobInstance: "",
            reason: "Fabric didn't start NB_DatabaseHub_Control (HTTP 403, InsufficientPrivileges: The caller does not have permission). Run all in the notebook sends the same request.",
            requestedBy: "app/ops@contoso.example",
            copy: true,
            cancelled: [],
        });
        w = await world(() => new Response("upstream timeout", { status: 504 }));
        expect(await answerRequest(run, await w.call(), SETTINGS, w.deps)).toMatchObject({ copy: true, reason: "Fabric didn't start NB_DatabaseHub_Control (HTTP 504). Run all in the notebook sends the same request." });
        w = await world(() => Promise.reject(new TypeError("fetch failed")));
        expect(await answerRequest(run, await w.call(), SETTINGS, w.deps)).toMatchObject({ copy: true, reason: "NB_DatabaseHub_Control wasn't started (fetch failed). Run all in the notebook sends the same request." });
        w = await world();
        w.fabricToken.mockImplementation(() => {
            throw new Error("No token was minted for the audience Fabric.");
        });
        expect(await answerRequest(run, await w.call(), SETTINGS, w.deps)).toMatchObject({ started: false, copy: true, reason: "NB_DatabaseHub_Control wasn't started (No token was minted for the audience Fabric). Run all in the notebook sends the same request." });
        expect(w.fabric).toHaveLength(0);
    });

    it("cancels the control's run in progress before Stop now, so the stop can start on a small capacity", async () => {
        const w = await world();
        expect(await answerRequest({ action: "stop" }, await w.call(), SETTINGS, w.deps)).toEqual({ started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example", copy: false, cancelled: [ZERO] });
        expect(w.fabric.map((c) => `${c.init?.method ?? "GET"} ${c.url}`)).toEqual([`GET ${JOBS}`, `POST ${JOBS}/${ZERO}/cancel`, `POST ${JOBS}?jobType=RunNotebook`]);
        expect(JSON.parse(String(w.fabric[2].init?.body)).executionData.parameters.STOP_NOW).toEqual({ value: true, type: "bool" });
    });

    it("reads the control's run in progress for an operator, with its ID, the control's targets, and one run's outcome, in UTC", async () => {
        const w = await world();
        expect(await answerAccess(await w.call(), SETTINGS, w.deps)).toEqual({
            configured: true,
            operator: true,
            reason: "",
            who: "ops@contoso.example",
            running: { id: ZERO, status: "InProgress", startedAt: "2026-11-18T11:30:00.1234567Z", invokeType: "Manual" },
            targets: ["T1", "T2", "T3", "T4", "T5"],
        });
        expect(await answerJob(ZERO, await w.call(), SETTINGS, w.deps)).toEqual({ status: "Failed", startedAt: "2026-11-18T11:30:00Z", endedAt: "2026-11-18T11:31:00Z", failureReason: "NotebookFailed: The webhook refused it." });
        expect(await answerJob("../../items", await w.call(), SETTINGS, w.deps)).toEqual({ status: "Unknown", startedAt: null, endedAt: null, failureReason: "That isn't a job instance ID." });
        expect(w.fabric.map((c) => c.url)).toEqual([JOBS, `${JOBS}/${ZERO}`]);
    });

    it("hands over to copy mode when this deployment's function isn't set up, before reading anything", async () => {
        const w = await world();
        const reason = async (settings: ManageSettings) => (await answerAccess(await w.call(), settings, w.deps)).reason;
        expect(await answerAccess(await w.call(), { ...SETTINGS, apiUrl: "" }, w.deps)).toEqual({ configured: false, operator: false, reason: "This deployment's Manage function isn't set up (it has no pinned API to check callers with), so each action copies its request for NB_DatabaseHub_Control, where Run all sends it.", who: "", running: null, targets: [] });
        expect(await reason({ ...SETTINGS, appId: "" })).toMatch(/\(it doesn't know the app's IDs\)/);
        expect(await reason({ ...SETTINGS, controlNotebookId: "" })).toMatch(/\(NB_DatabaseHub_Control wasn't found when the app was deployed\)/);
        expect(await reason({ ...SETTINGS, catalog: null })).toMatch(/\(it has no copy of the control's catalog\)/);
        expect(await reason({ ...SETTINGS, operators: [] })).toMatch(/\(it has no operators\)/);
        expect(w.deps.fetch).not.toHaveBeenCalled();
    });
});

describe("the app's side of the Manage function", () => {
    it("copies requests when the function can't send for anyone, is read-only for a viewer who isn't an operator, and otherwise sends", async () => {
        const api = { request: vi.fn(async () => ({ started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example", copy: false, cancelled: [] })), job: vi.fn(async () => ({ status: "InProgress" })) };
        const fallBack = vi.fn();
        const copy = manageAccessOf({ configured: false, operator: false, reason: "Manage couldn't confirm who you are.", who: "", running: null, targets: [] }, api, fallBack);
        expect(copy).toMatchObject({ mode: "copy", canRun: false, reason: "Manage couldn't confirm who you are." });
        const operator = manageAccessOf({ configured: true, operator: true, reason: "", who: "ops@contoso.example", running: null, targets: ["T1", "T2", "T3", "T4"] }, api, fallBack);
        expect(operator).toMatchObject({ mode: "run", canRun: true, who: "ops@contoso.example", targets: ["T1", "T2", "T3", "T4"] });
        await operator.send?.({ action: "stop" });
        expect(api.request).toHaveBeenCalledWith({ action: "stop" });
        await operator.job?.(ZERO);
        expect(api.job).toHaveBeenCalledWith(ZERO);
        operator.fallBack?.("Fabric refused it.");
        expect(fallBack).toHaveBeenCalledWith("Fabric refused it.");
        expect(manageAccessOf({ configured: true, operator: false, reason: "Read-only.", who: "viewer@contoso.example", running: null, targets: [] }, api)).toMatchObject({ mode: "run", canRun: false, reason: "Read-only.", targets: undefined });
    });

    it("reaches the functions through the app's Rayfin client, and rejects when this deployment has none", async () => {
        await expect(functionsManageApi({}).access()).rejects.toThrow("This deployment has no Manage function.");
        const invoke = vi.fn(async (input?: unknown) => JSON.stringify(input === undefined ? { configured: true, operator: true, reason: "", who: "ops@contoso.example", running: null, targets: [] } : { started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example", copy: false, cancelled: [] }));
        const api = functionsManageApi({ functions: { manageAccess: { invoke }, manageRequest: { invoke } } });
        expect(await api.access()).toMatchObject({ operator: true });
        expect(await api.request({ action: "reset", targets: ["T5"] })).toMatchObject({ started: true });
        expect(invoke).toHaveBeenLastCalledWith({ request: { action: "reset", targets: ["T5"] } }, { timeoutMs: 60_000 });
        await expect(api.job(ZERO)).rejects.toThrow("This deployment has no Manage function.");
    });
});