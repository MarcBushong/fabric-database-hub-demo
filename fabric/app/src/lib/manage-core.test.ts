// @vitest-environment node
// The Manage function's checks (rayfin/functions/src/manage-core.ts, ADR 0029), run with Node's Web Crypto: a token
// signed with a key of the test's own, its JWKS served by a stand-in for the app's API.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { answerAccess, answerJob, answerRequest, checkRequest, isOperator, jobParameters, requestedByOf, SCENARIO_RULES, SESSION_BOUNDS, verifyCaller, type ManageRequest, type ManageSettings, type VerifiedCaller } from "../../rayfin/functions/src/manage-core";
import { notebookParameters, type ControlRequest } from "./control";
import { functionsManageApi, manageAccessOf } from "./manage-client";
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
        expect(checkRequest({ action: "reset", targets: ["T5"] })).toEqual({ ok: true, request: { action: "reset", targets: ["T5"] } });
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

describe("the Manage function's answers", () => {
    const SETTINGS: ManageSettings = { apiUrl: API, controlWorkspaceId: ZERO, controlNotebookId: ZERO, operators: [{ objectId: ZERO, names: ["ops@contoso.example"] }] };
    const JOBS = `https://api.fabric.microsoft.com/v1/workspaces/${ZERO}/items/${ZERO}/jobs/instances`;
    const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    const accepted = () => new Response(null, { status: 202, headers: { location: `${JOBS}/${ZERO}` } });
    // A viewer with no object ID in their token, so only their name could make them an operator.
    const viewer = { email: "viewer@contoso.example", oid: undefined };

    /** A stand-in for the app's API (its keys) and Fabric's job API; it records every Fabric call. */
    async function world(run: () => Response | Promise<Response> = accepted) {
        const { jwk, sign } = await signer();
        const fabric: Array<{ url: string; init?: RequestInit }> = [];
        const fetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
            const u = String(url);
            if (u.startsWith(API)) return json({ keys: [jwk] }, u.endsWith("/.well-known/jwks.json") && !u.includes("/api/auth/") ? 200 : 404);
            fabric.push({ url: u, init });
            if (u === `${JOBS}?jobType=RunNotebook`) return run();
            if (u === JOBS) return json({ value: [{ id: ZERO, status: "Completed" }, { id: ZERO, status: "InProgress", invokeType: "Manual", startTimeUtc: "2026-11-18T11:30:00.1234567" }] });
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
        expect(answer).toEqual({ started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example" });
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
        expect(await answerRequest({ action: "stop", requestedBy: "app/someone-else" }, await w.call(), SETTINGS, w.deps)).toMatchObject({ started: false, reason: "Unknown fields: requestedBy." });
        expect(w.fabric).toHaveLength(1);
    });

    it("refuses a forged or expired token, and a viewer who isn't an operator, before any Fabric call", async () => {
        const w = await world();
        const good = await w.call();
        const [h, , s] = good.token.split(".");
        const forged = { ...good, token: `${h}.${b64url(JSON.stringify(claims({ email: "intruder@contoso.example" })))}.${s}` };
        expect(await answerRequest({ action: "stop" }, forged, SETTINGS, w.deps)).toEqual({ started: false, jobInstance: "", reason: "Manage couldn't confirm who you are: the caller's token isn't signed by the app.", requestedBy: "" });
        expect(await answerRequest({ action: "stop" }, await w.call({ exp: NOW / 1000 - 1 }), SETTINGS, w.deps)).toMatchObject({ started: false, reason: "Manage couldn't confirm who you are: the caller's token has expired." });
        const notOperator = await answerRequest({ action: "stop" }, await w.call(viewer), SETTINGS, w.deps);
        expect(notOperator).toMatchObject({ started: false, reason: expect.stringMatching(/^Only the demo's operators send actions from the app/) });
        expect(await answerAccess(await w.call(viewer), SETTINGS, w.deps)).toEqual({ configured: true, operator: false, reason: notOperator.reason, who: "viewer@contoso.example", running: null });
        expect(await answerJob(ZERO, forged, SETTINGS, w.deps)).toMatchObject({ status: "Unknown", failureReason: expect.stringMatching(/^Manage couldn't confirm who you are/) });
        expect(w.fabric).toHaveLength(0);
        expect(w.fabricToken).not.toHaveBeenCalled();
    });

    it("refuses an action or a value outside the control's allow-lists and caps, before any Fabric call", async () => {
        const w = await world();
        const call = await w.call();
        const refused = async (request: unknown) => (await answerRequest(request, call, SETTINGS, w.deps)).reason;
        expect(await refused({ action: "deploy" })).toBe("The action must be session, run, stop, or reset.");
        expect(await refused({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 31 })).toBe("cpu-pressure runs 5 to 30 minutes.");
        expect(await refused({ action: "run", scenario: "ru-storm", target: "T1" })).toBe("ru-storm runs on T5.");
        expect(await refused({ action: "session", durationMinutes: 240 })).toBe("A session runs 30 to 120 minutes.");
        expect(await refused({ action: "reset", targets: ["T6"] })).toBe("Reset applies to T1, T2, T3, T4, and T5.");
        expect(w.fabric).toHaveLength(0);
    });

    it("says why when the job API refuses the run, can't be reached, or the runtime gave no Fabric token", async () => {
        const stop = { action: "stop" };
        let w = await world(() => json({ errorCode: "InsufficientPrivileges", message: "The caller does not have  permission." }, 403));
        expect(await answerRequest(stop, await w.call(), SETTINGS, w.deps)).toEqual({ started: false, jobInstance: "", reason: "Fabric didn't start NB_DatabaseHub_Control (HTTP 403, InsufficientPrivileges: The caller does not have permission).", requestedBy: "app/ops@contoso.example" });
        w = await world(() => new Response("upstream timeout", { status: 504 }));
        expect((await answerRequest(stop, await w.call(), SETTINGS, w.deps)).reason).toBe("Fabric didn't start NB_DatabaseHub_Control (HTTP 504).");
        w = await world(() => Promise.reject(new TypeError("fetch failed")));
        expect((await answerRequest(stop, await w.call(), SETTINGS, w.deps)).reason).toBe("NB_DatabaseHub_Control wasn't started: fetch failed.");
        w = await world();
        w.fabricToken.mockImplementation(() => {
            throw new Error("No token was minted for the audience Fabric.");
        });
        expect(await answerRequest(stop, await w.call(), SETTINGS, w.deps)).toMatchObject({ started: false, reason: "NB_DatabaseHub_Control wasn't started: No token was minted for the audience Fabric." });
        expect(w.fabric).toHaveLength(0);
    });

    it("reads the control's run in progress for an operator, and one run's outcome, in UTC", async () => {
        const w = await world();
        expect(await answerAccess(await w.call(), SETTINGS, w.deps)).toEqual({ configured: true, operator: true, reason: "", who: "ops@contoso.example", running: { startedAt: "2026-11-18T11:30:00.1234567Z", invokeType: "Manual" } });
        expect(await answerJob(ZERO, await w.call(), SETTINGS, w.deps)).toEqual({ status: "Failed", startedAt: "2026-11-18T11:30:00Z", endedAt: "2026-11-18T11:31:00Z", failureReason: "NotebookFailed: The webhook refused it." });
        expect(await answerJob("../../items", await w.call(), SETTINGS, w.deps)).toEqual({ status: "Unknown", startedAt: null, endedAt: null, failureReason: "That isn't a job instance ID." });
        expect(w.fabric.map((c) => c.url)).toEqual([JOBS, `${JOBS}/${ZERO}`]);
    });

    it("tells the app to copy requests for Run all when this deployment's function isn't set up", async () => {
        const w = await world();
        const access = await answerAccess(await w.call(), { ...SETTINGS, apiUrl: "" }, w.deps);
        expect(access).toEqual({ configured: false, operator: false, reason: "This deployment's Manage function isn't set up (it has no pinned API to check callers with), so each action copies its request for NB_DatabaseHub_Control, where Run all sends it.", who: "", running: null });
        expect(await answerRequest({ action: "stop" }, await w.call(), { ...SETTINGS, controlNotebookId: "" }, w.deps)).toMatchObject({ started: false, reason: "This deployment's Manage function isn't set up: NB_DatabaseHub_Control wasn't found when the app was deployed." });
        expect(await answerRequest({ action: "stop" }, await w.call(), { ...SETTINGS, operators: [] }, w.deps)).toMatchObject({ started: false, reason: "This deployment's Manage function isn't set up: it has no operators." });
        expect(w.deps.fetch).not.toHaveBeenCalled();

        const api = { request: vi.fn(async () => ({ started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example" })) };
        expect(manageAccessOf(access, api)).toMatchObject({ mode: "copy", canRun: false, reason: access.reason });
        const operator = manageAccessOf({ configured: true, operator: true, reason: "", who: "ops@contoso.example", running: null }, api);
        expect(operator).toMatchObject({ mode: "run", canRun: true, who: "ops@contoso.example" });
        await operator.send?.({ action: "stop" });
        expect(api.request).toHaveBeenCalledWith({ action: "stop" });
        expect(manageAccessOf({ configured: true, operator: false, reason: "Read-only.", who: "viewer@contoso.example", running: null }, api)).toMatchObject({ mode: "run", canRun: false, reason: "Read-only." });
    });

    it("reaches the functions through the app's Rayfin client, and rejects when this deployment has none", async () => {
        await expect(functionsManageApi({}).access()).rejects.toThrow("This deployment has no Manage function.");
        const invoke = vi.fn(async (input?: unknown) => JSON.stringify(input === undefined ? { configured: true, operator: true, reason: "", who: "ops@contoso.example", running: null } : { started: true, jobInstance: ZERO, reason: "", requestedBy: "app/ops@contoso.example" }));
        const api = functionsManageApi({ functions: { manageAccess: { invoke }, manageRequest: { invoke } } });
        expect(await api.access()).toMatchObject({ operator: true });
        expect(await api.request({ action: "reset", targets: ["T5"] })).toMatchObject({ started: true });
        expect(invoke).toHaveBeenLastCalledWith({ request: { action: "reset", targets: ["T5"] } }, { timeoutMs: 60_000 });
        await expect(api.job(ZERO)).rejects.toThrow("This deployment has no Manage function.");
    });
});