// The Manage function's checks and answers, pure, so the app's tests run them (ADR 0029): who the caller is, from their
// Rayfin token verified with the app's own keys; whether they're an operator; whether a request is one the session
// control accepts; and NB_DatabaseHub_Control's run through the Fabric job API. manage.ts registers them with the
// Rayfin runtime's context. No Node.js or SDK import: Web Crypto and fetch only.

/** What configure-fabric-app.ps1 writes for the function (manage.generated.ts in the stage): IDs and names, never a secret. */
export interface ManageSettings {
    /** The app's own Rayfin API (its deployment record's fabricApiUrl), pinned at deploy time: its keys come only from here. */
    apiUrl: string;
    /** NB_DatabaseHub_Control: the workspace and the item the Fabric job API runs. */
    controlWorkspaceId: string;
    controlNotebookId: string;
    /** The operators: the deployer and the demo admin group's users, with their object IDs and names, lowercased. */
    operators: ReadonlyArray<{ objectId: string; names: readonly string[] }>;
}

export interface VerifiedCaller {
    verified: true;
    /** The caller's Microsoft Entra object ID (the token's oid), or "" when the token has none. */
    objectId: string;
    /** Their names in the token (email, upn, preferred_username, unique_name), lowercased. */
    names: string[];
    /** How the control records them: their first name, or the token's subject. */
    display: string;
}

export interface RejectedCaller {
    verified: false;
    reason: string;
}

export type Caller = VerifiedCaller | RejectedCaller;

type Claims = Record<string, unknown>;
type Jwk = Record<string, unknown> & { kid?: string; alg?: string };

const ALGORITHMS: Record<string, { name: string; hash: string; namedCurve?: string }> = {
    RS256: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    RS384: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-384" },
    RS512: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" },
    ES256: { name: "ECDSA", hash: "SHA-256", namedCurve: "P-256" },
    ES384: { name: "ECDSA", hash: "SHA-384", namedCurve: "P-384" },
};

function bytes(part: string): Uint8Array {
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    const text = atob(base64);
    const out = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i);
    return out;
}

function json(part: string): Claims | null {
    try {
        const value: unknown = JSON.parse(new TextDecoder().decode(bytes(part)));
        return value && typeof value === "object" && !Array.isArray(value) ? (value as Claims) : null;
    } catch {
        return null;
    }
}

const reject = (reason: string): RejectedCaller => ({ verified: false, reason });

/**
 * Verifies the caller's Rayfin token: its signature with the app's own JWKS, read from the pinned API (the backend's
 * public `.well-known/jwks.json`, or the auth service's), then its expiry, subject, and audience. The token comes from the
 * Rayfin runtime (the function's context); nothing the browser sends names the caller.
 */
export async function verifyCaller(token: string, settings: { apiUrl: string; publishableKey: string }, deps: { fetch: typeof fetch; now?: () => number }): Promise<Caller> {
    const parts = token.split(".");
    if (parts.length !== 3) return reject("the caller's token isn't a JWT");
    const header = json(parts[0]);
    const claims = json(parts[1]);
    if (!header || !claims) return reject("the caller's token can't be read");
    const alg = String(header.alg ?? "");
    const params = ALGORITHMS[alg];
    if (!params) return reject(`the caller's token is signed with ${alg || "no algorithm"}, which the function doesn't accept`);
    const now = Math.floor((deps.now ?? Date.now)() / 1000);
    if (typeof claims.exp !== "number" || claims.exp <= now) return reject("the caller's token has expired");
    if (typeof claims.sub !== "string" || !claims.sub || claims.aud === undefined) return reject("the caller's token has no subject or audience");
    if (!/^https:\/\//i.test(settings.apiUrl)) return reject("the function has no pinned API to read its keys from");

    const root = settings.apiUrl.replace(/\/+$/, "");
    let keys: Jwk[] = [];
    for (const url of [`${root}/.well-known/jwks.json`, `${root}/api/auth/v1/.well-known/jwks.json`]) {
        try {
            const response = await deps.fetch(url, { headers: { "X-Publishable-Key": settings.publishableKey } });
            if (!response.ok) continue;
            const body = (await response.json()) as { keys?: unknown };
            if (Array.isArray(body.keys)) {
                keys = body.keys as Jwk[];
                break;
            }
        } catch {
            // The next URL, then the reason below.
        }
    }
    if (keys.length === 0) return reject("the app's keys couldn't be read");
    const jwk = keys.find((k) => k.kid === header.kid && (!k.alg || k.alg === alg));
    if (!jwk) return reject("no key of the app's signs the caller's token");

    try {
        const importParams = params.name === "ECDSA" ? { name: params.name, namedCurve: params.namedCurve } : { name: params.name, hash: params.hash };
        const key = await crypto.subtle.importKey("jwk", jwk as never, importParams as never, false, ["verify"]);
        const verifyParams = params.name === "ECDSA" ? { name: params.name, hash: params.hash } : { name: params.name };
        const signed = await crypto.subtle.verify(verifyParams as never, key, bytes(parts[2]) as never, new TextEncoder().encode(`${parts[0]}.${parts[1]}`) as never);
        if (!signed) return reject("the caller's token isn't signed by the app");
    } catch {
        return reject("the caller's token's signature can't be checked");
    }

    const names = [claims.email, claims.upn, claims.preferred_username, claims.unique_name]
        .filter((n): n is string => typeof n === "string" && n.trim() !== "")
        .map((n) => n.trim().toLowerCase())
        .filter((n, i, all) => all.indexOf(n) === i);
    const objectId = typeof claims.oid === "string" ? claims.oid.toLowerCase() : "";
    return { verified: true, objectId, names, display: names[0] ?? claims.sub };
}

/** An operator is in the deploy-time list by object ID, or by a name in the token. */
export function isOperator(caller: VerifiedCaller, settings: Pick<ManageSettings, "operators">): boolean {
    return settings.operators.some((o) => (caller.objectId !== "" && o.objectId === caller.objectId) || caller.names.some((n) => o.names.includes(n)));
}

/** The control's REQUESTED_BY: "app/" and the caller, in the characters its name rule allows (1 to 64). */
export function requestedByOf(caller: VerifiedCaller): string {
    return `app/${caller.display}`.replace(/[^A-Za-z0-9._@/-]/g, "-").slice(0, 64);
}

/** The session control's bounds (CATALOG_JSON's rules): the app's tests keep them equal to each scenario's scenario.json. */
export const SESSION_BOUNDS = { min: 30, max: 120, default: 90 } as const;

export const SCENARIO_RULES: ReadonlyArray<{ id: string; targets: readonly string[]; defaultMinutes: number; maxMinutes: number }> = [
    { id: "blocking-chain", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "capacity-max", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 20 },
    { id: "connection-surge", targets: ["T4"], defaultMinutes: 5, maxMinutes: 15 },
    { id: "cpu-pressure", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "deadlock-storm", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "healthy-baseline", targets: ["T1", "T2", "T3", "T4", "T5"], defaultMinutes: 30, maxMinutes: 240 },
    { id: "idle-in-transaction", targets: ["T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "inefficient-query", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "io-pressure", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "locking-blocking", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "log-flush-waits", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "log-rate-pressure", targets: ["T1", "T2", "T3"], defaultMinutes: 5, maxMinutes: 15 },
    { id: "memory-grant-pressure", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "missing-index", targets: ["T1", "T2", "T3", "T4"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "parallel-scans", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "plan-regression", targets: ["T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "replica-lag", targets: ["T4"], defaultMinutes: 10, maxMinutes: 15 },
    { id: "resource-governance", targets: ["T1", "T2", "T3"], defaultMinutes: 5, maxMinutes: 20 },
    { id: "ru-storm", targets: ["T5"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "slow-consumer", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
    { id: "tempdb-contention", targets: ["T1", "T2", "T3"], defaultMinutes: 10, maxMinutes: 30 },
];

const RESET_TARGETS = ["T1", "T2", "T3", "T4", "T5"];

export type ManageRequest =
    | { action: "session"; durationMinutes: number }
    | { action: "run"; scenario: string; target: string; durationMinutes: number; intensity?: number }
    | { action: "stop" }
    | { action: "reset"; targets: string[] };

const KEYS: Record<ManageRequest["action"], readonly string[]> = {
    session: ["action", "durationMinutes"],
    run: ["action", "scenario", "target", "durationMinutes", "intensity"],
    stop: ["action"],
    reset: ["action", "targets"],
};

const isInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v);

/**
 * Accepts only the documented actions and values, within the control's allow-lists and caps, and nothing else: an
 * unknown action, an unknown field, a scenario on a target it doesn't apply to, or minutes past its cap is refused.
 */
export function checkRequest(input: unknown): { ok: true; request: ManageRequest } | { ok: false; reason: string } {
    if (!input || typeof input !== "object" || Array.isArray(input)) return { ok: false, reason: "The request isn't an object." };
    const r = input as Record<string, unknown>;
    const action = r.action;
    if (action !== "session" && action !== "run" && action !== "stop" && action !== "reset") return { ok: false, reason: "The action must be session, run, stop, or reset." };
    const extra = Object.keys(r).filter((k) => !KEYS[action].includes(k));
    if (extra.length > 0) return { ok: false, reason: `Unknown fields: ${extra.join(", ")}.` };
    switch (action) {
        case "session": {
            const minutes = r.durationMinutes ?? SESSION_BOUNDS.default;
            if (!isInt(minutes) || minutes < SESSION_BOUNDS.min || minutes > SESSION_BOUNDS.max) return { ok: false, reason: `A session runs ${SESSION_BOUNDS.min} to ${SESSION_BOUNDS.max} minutes.` };
            return { ok: true, request: { action, durationMinutes: minutes } };
        }
        case "run": {
            const rule = SCENARIO_RULES.find((s) => s.id === r.scenario);
            if (!rule) return { ok: false, reason: "The scenario isn't in the catalog." };
            if (typeof r.target !== "string" || !rule.targets.includes(r.target)) return { ok: false, reason: `${rule.id} runs on ${rule.targets.join(", ")}.` };
            const minutes = r.durationMinutes ?? rule.defaultMinutes;
            if (!isInt(minutes) || minutes < 5 || minutes > rule.maxMinutes) return { ok: false, reason: `${rule.id} runs 5 to ${rule.maxMinutes} minutes.` };
            if (r.intensity !== undefined && (!isInt(r.intensity) || r.intensity < 1 || r.intensity > 10)) return { ok: false, reason: "Intensity is 1 to 10." };
            return { ok: true, request: { action, scenario: rule.id, target: r.target, durationMinutes: minutes, ...(r.intensity !== undefined ? { intensity: r.intensity as number } : {}) } };
        }
        case "stop":
            return { ok: true, request: { action } };
        case "reset": {
            const targets = r.targets ?? [];
            if (!Array.isArray(targets) || targets.some((t) => typeof t !== "string" || !RESET_TARGETS.includes(t))) return { ok: false, reason: "Reset applies to T1, T2, T3, T4, and T5." };
            return { ok: true, request: { action, targets: [...new Set(targets as string[])] } };
        }
    }
}

export interface JobParameter {
    value: string | number | boolean;
    type: "string" | "int" | "bool";
}

/** NB_DatabaseHub_Control's parameters for a checked request, as the Fabric job API takes them, with who sent it. */
export function jobParameters(request: ManageRequest, requestedBy: string): Record<string, JobParameter> {
    const who: Record<string, JobParameter> = { REQUESTED_BY: { value: requestedBy, type: "string" } };
    switch (request.action) {
        case "session":
            return { MODE: { value: "session", type: "string" }, DURATION_MINUTES: { value: request.durationMinutes, type: "int" }, WAIT_FOR_END: { value: true, type: "bool" }, ...who };
        case "run": {
            const activity: Record<string, unknown> = { target: request.target, scenario: request.scenario };
            if (request.intensity !== undefined) activity.intensity = request.intensity;
            return {
                MODE: { value: "activities", type: "string" },
                ACTIVITIES: { value: JSON.stringify([activity]), type: "string" },
                DURATION_MINUTES: { value: request.durationMinutes, type: "int" },
                WATCH_MINUTES: { value: 0, type: "int" },
                ...who,
            };
        }
        case "stop":
            return { STOP_NOW: { value: true, type: "bool" }, ...who };
        case "reset":
            return { RESET_NOW: { value: true, type: "bool" }, RESET_TARGETS: { value: JSON.stringify(request.targets), type: "string" }, ...who };
    }
}

/** What manageAccess says about the signed-in viewer (the app's src/lib/manage-client.ts reads it). */
export interface ManageAccessAnswer {
    /** False when this deployment's function has no settings: the app copies each request for Run all instead (C). */
    configured: boolean;
    /** True when the verified caller is an operator: the deployer or a member of the demo's admin group. */
    operator: boolean;
    /** Why not, in one sentence, when they aren't, or when the function isn't set up. */
    reason: string;
    /** The verified caller's name, or "" when they weren't verified. */
    who: string;
    /** The control's run in progress, read for operators: a new session replaces it (the control follows the newest request). */
    running: { startedAt: string; invokeType?: string } | null;
}

export interface ManageRequestAnswer {
    started: boolean;
    /** The Fabric job instance of NB_DatabaseHub_Control, when it started. */
    jobInstance: string;
    reason: string;
    /** How the control records the caller (REQUESTED_BY), once they're verified. */
    requestedBy: string;
}

export interface ManageJobAnswer {
    /** The job API's status (NotStarted, InProgress, Completed, Failed, Cancelled, or Deduped), or Unknown when it can't be read. */
    status: string;
    startedAt?: string | null;
    endedAt?: string | null;
    failureReason?: string | null;
}

/** What a call brings from the function's Rayfin context: never anything the browser names. */
export interface ManageCall {
    /** The caller's Rayfin token (ctx.accessToken), which the app's backend checked before the function ran. */
    token: string;
    /** The app's publishable key (ctx.publishableKey), which the app's API asks for with its keys. */
    publishableKey: string;
    /** The Fabric token the runtime minted for the function (ctx.Tokens.Fabric), read only to call the job API; it throws when there's none. */
    fabricToken: () => string;
}

export interface ManageDeps {
    fetch: typeof fetch;
    now?: () => number;
}

/** The Fabric REST API's job scheduler (https://learn.microsoft.com/rest/api/fabric/core/job-scheduler). */
const FABRIC_API = "https://api.fabric.microsoft.com/v1";
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NOT_OPERATOR = "Only the demo's operators send actions from the app: the deployer and the members of its admin group. A redeploy refreshes the list.";

/** Why this deployment's function can't send requests, or "" when its settings are complete. */
export function settingsProblem(settings: ManageSettings): string {
    if (!/^https:\/\//i.test(settings.apiUrl)) return "it has no pinned API to check callers with";
    if (!GUID.test(settings.controlWorkspaceId) || !GUID.test(settings.controlNotebookId)) return "NB_DatabaseHub_Control wasn't found when the app was deployed";
    if (settings.operators.length === 0) return "it has no operators";
    return "";
}

/** An error's message as a clause: one line, at most 300 characters, without its closing period (the answer adds one). */
const messageOf = (error: unknown): string => clause(error instanceof Error ? error.message : String(error));
const clause = (text: string): string => text.replace(/\s+/g, " ").trim().slice(0, 300).replace(/[.\s]+$/, "");

/** Fabric's job times are UTC, often without a zone: one with no zone gets a Z, so browsers don't read it as local time. */
function utc(value: unknown): string | null {
    if (typeof value !== "string" || value === "") return null;
    return /^\d{4}-\d{2}-\d{2}T[\d:.]+$/.test(value) ? `${value}Z` : value;
}

type Gate = { ok: true; caller: VerifiedCaller } | { ok: false; reason: string; caller?: VerifiedCaller };

/** The verified operator behind a call, or why there's none. Nothing runs before this passes. */
async function gate(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<Gate> {
    const problem = settingsProblem(settings);
    if (problem) return { ok: false, reason: `This deployment's Manage function isn't set up: ${problem}.` };
    const caller = await verifyCaller(call.token, { apiUrl: settings.apiUrl, publishableKey: call.publishableKey }, deps);
    if (!caller.verified) return { ok: false, reason: `Manage couldn't confirm who you are: ${caller.reason}.` };
    if (!isOperator(caller, settings)) return { ok: false, reason: NOT_OPERATOR, caller };
    return { ok: true, caller };
}

const jobsPath = (settings: ManageSettings) => `/workspaces/${settings.controlWorkspaceId.toLowerCase()}/items/${settings.controlNotebookId.toLowerCase()}/jobs/instances`;

function fabric(call: ManageCall, deps: ManageDeps, path: string, init: { method?: string; body?: string } = {}): Promise<Response> {
    const headers: Record<string, string> = { Authorization: `Bearer ${call.fabricToken()}` };
    if (init.body !== undefined) headers["Content-Type"] = "application/json";
    return deps.fetch(`${FABRIC_API}${path}`, { ...init, headers });
}

/** The job API's refusal in one line: its status, and its errorCode and message when it sent them. */
async function refusal(response: Response): Promise<string> {
    let detail = "";
    try {
        const body = (await response.json()) as { errorCode?: unknown; message?: unknown };
        detail = [body.errorCode, body.message].filter((v): v is string => typeof v === "string" && v.trim() !== "").join(": ");
    } catch {
        // No JSON body: the status says it.
    }
    return `HTTP ${response.status}${detail ? `, ${clause(detail)}` : ""}`;
}

/** NB_DatabaseHub_Control's run that's queued or in progress, from the job API's list; null when there's none or it can't be read. */
async function runningJob(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageAccessAnswer["running"]> {
    try {
        const response = await fabric(call, deps, jobsPath(settings));
        if (!response.ok) return null;
        const body = (await response.json()) as { value?: unknown };
        const jobs = Array.isArray(body.value) ? (body.value as Array<Record<string, unknown>>) : [];
        const job = jobs.find((j) => j.status === "InProgress" || j.status === "NotStarted");
        if (!job) return null;
        return { startedAt: utc(job.startTimeUtc) ?? new Date((deps.now ?? Date.now)()).toISOString(), ...(typeof job.invokeType === "string" ? { invokeType: job.invokeType } : {}) };
    } catch {
        return null;
    }
}

/** manageAccess: whether the signed-in viewer can send actions from the app, and the control's run in progress. */
export async function answerAccess(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageAccessAnswer> {
    const problem = settingsProblem(settings);
    if (problem) return { configured: false, operator: false, reason: `This deployment's Manage function isn't set up (${problem}), so each action copies its request for NB_DatabaseHub_Control, where Run all sends it.`, who: "", running: null };
    const g = await gate(call, settings, deps);
    if (!g.ok) return { configured: true, operator: false, reason: g.reason, who: g.caller?.display ?? "", running: null };
    return { configured: true, operator: true, reason: "", who: g.caller.display, running: await runningJob(call, settings, deps) };
}

/**
 * manageRequest: runs NB_DatabaseHub_Control through the Fabric job API (Run On Demand Item Job, jobType RunNotebook)
 * with a checked request's parameters, and REQUESTED_BY from the verified caller, never from the request.
 */
export async function answerRequest(input: unknown, call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageRequestAnswer> {
    const refuse = (reason: string, requestedBy = ""): ManageRequestAnswer => ({ started: false, jobInstance: "", reason, requestedBy });
    const g = await gate(call, settings, deps);
    if (!g.ok) return refuse(g.reason);
    const checked = checkRequest(input);
    if (!checked.ok) return refuse(checked.reason);
    const requestedBy = requestedByOf(g.caller);
    try {
        const response = await fabric(call, deps, `${jobsPath(settings)}?jobType=RunNotebook`, {
            method: "POST",
            body: JSON.stringify({ executionData: { parameters: jobParameters(checked.request, requestedBy) } }),
        });
        if (!response.ok) return refuse(`Fabric didn't start NB_DatabaseHub_Control (${await refusal(response)}).`, requestedBy);
        // 202 Accepted: the Location header is the new job instance's URL.
        const id = (response.headers.get("location") ?? "").replace(/\/+$/, "").split("/").pop() ?? "";
        return { started: true, jobInstance: GUID.test(id) ? id.toLowerCase() : "", reason: "", requestedBy };
    } catch (error) {
        return refuse(`NB_DatabaseHub_Control wasn't started: ${messageOf(error)}.`, requestedBy);
    }
}

/** manageJob: one run of NB_DatabaseHub_Control, as the job API has it (Get Item Job Instance). */
export async function answerJob(jobInstance: unknown, call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageJobAnswer> {
    const unknown = (reason: string): ManageJobAnswer => ({ status: "Unknown", startedAt: null, endedAt: null, failureReason: reason });
    const g = await gate(call, settings, deps);
    if (!g.ok) return unknown(g.reason);
    if (typeof jobInstance !== "string" || !GUID.test(jobInstance)) return unknown("That isn't a job instance ID.");
    try {
        const response = await fabric(call, deps, `${jobsPath(settings)}/${jobInstance.toLowerCase()}`);
        if (!response.ok) return unknown(`Fabric didn't return the run (${await refusal(response)}).`);
        const body = (await response.json()) as Record<string, unknown>;
        const failure = body.failureReason && typeof body.failureReason === "object" ? (body.failureReason as Record<string, unknown>) : null;
        const failureText = failure ? [failure.errorCode, failure.message].filter((v): v is string => typeof v === "string" && v.trim() !== "").join(": ") : "";
        return { status: typeof body.status === "string" ? body.status : "Unknown", startedAt: utc(body.startTimeUtc), endedAt: utc(body.endTimeUtc), failureReason: failureText || null };
    } catch (error) {
        return unknown(`The run couldn't be read: ${messageOf(error)}.`);
    }
}