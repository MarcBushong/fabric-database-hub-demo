// The Manage function's checks and answers, pure, so the app's tests run them (ADR 0029): who the caller is, from their
// Rayfin token verified with the app's own keys and bound to this app; whether they're an operator; whether a request
// is one the session control accepts, by the control's own catalog; and NB_DatabaseHub_Control's runs through the
// Fabric job API. manage.ts registers them with the Rayfin runtime's context. No Node.js or SDK import: Web Crypto and
// fetch only.

/** The session control's own rules, as its runbook and NB_DatabaseHub_Control's CATALOG_JSON have them, written at deploy time. */
export interface ControlCatalog {
    /** The control's targets: T1 to T3, T4, and T5 only while it's on. */
    targets: readonly string[];
    /** The incidents it runs (scenarios/<id>/scenario.json without healthy-baseline, which it runs as "baseline"). */
    scenarios: Readonly<Record<string, { maxMinutes: number; maxConcurrency: number; targets: readonly string[] }>>;
    /** A run's minutes (MODE "activities"). */
    minDurationMinutes: number;
    maxDurationMinutes: number;
    /** A session's minutes (the showcase's). */
    session: { minMinutes: number; maxMinutes: number; defaultMinutes: number };
}

/** What configure-fabric-app.ps1 writes for the function (manage.generated.ts in the stage): IDs, names, and rules, never a secret. */
export interface ManageSettings {
    /** The app's own Rayfin API (its deployment record's fabricApiUrl), pinned at deploy time: its keys come only from here. */
    apiUrl: string;
    /** The app, from its deployment record: a caller's token must be for this tenant and this app. */
    tenantId: string;
    workspaceId: string;
    appId: string;
    /** The token's exact issuer and audience once the identity proof shows them; "" until then, when the IDs above bind it. */
    issuer: string;
    audience: string;
    /** NB_DatabaseHub_Control: the workspace and the item the Fabric job API runs. */
    controlWorkspaceId: string;
    controlNotebookId: string;
    /** The operators: the deployer and the demo admin group's users, with their object IDs and names, lowercased. */
    operators: ReadonlyArray<{ objectId: string; names: readonly string[] }>;
    /** The control's own rules; null when the deploy couldn't read them. */
    catalog: ControlCatalog | null;
}

export interface VerifiedCaller {
    verified: true;
    /** The caller's Microsoft Entra object ID (the token's oid), or "" when the token has none. */
    objectId: string;
    /** Their names in the token (email, upn, preferred_username, unique_name, or Fabric's rfn_email for this app), lowercased. */
    names: string[];
    /** How the control records them: their first name, or their object ID. */
    display: string;
}

export interface RejectedCaller {
    verified: false;
    reason: string;
}

export type Caller = VerifiedCaller | RejectedCaller;

/** What binds a caller's token to this app: the pinned API for its keys, and the app's IDs from the deployment record. */
export type TokenBinding = Pick<ManageSettings, "apiUrl" | "tenantId" | "workspaceId" | "appId" | "issuer" | "audience"> & { publishableKey: string };

type Claims = Record<string, unknown>;
type Jwk = Record<string, unknown> & { kid?: string; alg?: string };

const ALGORITHMS: Record<string, { name: string; hash: string; namedCurve?: string }> = {
    RS256: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    RS384: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-384" },
    RS512: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" },
    ES256: { name: "ECDSA", hash: "SHA-256", namedCurve: "P-256" },
    ES384: { name: "ECDSA", hash: "SHA-384", namedCurve: "P-384" },
};
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
const lower = (value: unknown): string => (typeof value === "string" ? value.trim().toLowerCase() : "");

/**
 * Why a verified token isn't for this app, or "". Its issuer and audience must equal the pinned ones once known; until
 * then, the deployment record's IDs bind it: its tenant (tid, or the tenant in Fabric's managed token's subject path)
 * and this app (an audience of the app's ID or API, Fabric's subject path for this app, or its xms_attr for this app).
 */
function bindingProblem(claims: Claims, binding: TokenBinding): string {
    const issuer = typeof claims.iss === "string" ? claims.iss : "";
    if (binding.issuer ? issuer !== binding.issuer : !/^https:\/\/\S+$/i.test(issuer)) return binding.issuer ? "the caller's token is from another issuer" : "the caller's token names no issuer";
    const audiences = (Array.isArray(claims.aud) ? claims.aud : [claims.aud]).filter((a): a is string => typeof a === "string");
    if (binding.audience && !audiences.includes(binding.audience)) return "the caller's token is for another audience";
    const tenant = lower(binding.tenantId);
    const app = lower(binding.appId);
    const workspace = lower(binding.workspaceId);
    const subject = lower(claims.sub);
    // Fabric's managed token names its tenant, workspace, and app in its subject path: when it does, they must be this app's.
    const path = (segment: string) => new RegExp(`/${segment}/([^/]+)/`).exec(subject)?.[1];
    const pathTenant = path("tenants");
    if (claims.tid !== undefined ? lower(claims.tid) !== tenant || (pathTenant !== undefined && pathTenant !== tenant) : pathTenant !== tenant) return "the caller's token is for another tenant";
    const pathWorkspace = path("workspaces");
    const pathApp = path("appbackends");
    if ((pathWorkspace !== undefined && pathWorkspace !== workspace) || (pathApp !== undefined && pathApp !== app)) return "the caller's token isn't for this app";
    if (binding.audience) return "";
    const api = lower(binding.apiUrl).replace(/\/+$/, "");
    const attributes = claims.xms_attr && typeof claims.xms_attr === "object" ? Object.keys(claims.xms_attr).map(lower) : [];
    const forApp =
        audiences.some((a) => {
            const audience = lower(a).replace(/\/+$/, "");
            return audience === app || audience === `api://${app}` || audience === api;
        }) ||
        subject.includes(`/workspaces/${workspace}/appbackends/${app}/users/`) ||
        attributes.includes(app);
    return forApp ? "" : "the caller's token isn't for this app";
}

/** Who the token names: its object ID (oid), and its names, Fabric's rfn_email for this app among them. */
function identityOf(claims: Claims, appId: string): { objectId: string; names: string[] } {
    const objectId = typeof claims.oid === "string" && GUID.test(claims.oid) ? claims.oid.toLowerCase() : "";
    const managed: unknown[] = [];
    if (claims.xms_attr && typeof claims.xms_attr === "object") {
        for (const [key, value] of Object.entries(claims.xms_attr as Record<string, unknown>)) {
            if (lower(key) === lower(appId) && value && typeof value === "object") managed.push((value as Record<string, unknown>).rfn_email);
        }
    }
    const names = [claims.email, claims.upn, claims.preferred_username, claims.unique_name, ...managed]
        .filter((n): n is string => typeof n === "string" && n.trim() !== "")
        .map((n) => n.trim().toLowerCase())
        .filter((n, i, all) => all.indexOf(n) === i);
    return { objectId, names };
}

/**
 * Verifies the caller's Rayfin token: its signature with the app's own JWKS, read only from the pinned API, its expiry,
 * subject, and audience, then that it's for this app (bindingProblem) and names someone (an object ID or a name). The
 * token comes from the Rayfin runtime (the function's context); nothing the browser sends names the caller.
 */
export async function verifyCaller(token: string, binding: TokenBinding, deps: { fetch: typeof fetch; now?: () => number }): Promise<Caller> {
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
    if (!/^https:\/\//i.test(binding.apiUrl)) return reject("the function has no pinned API to read its keys from");

    let keys: Jwk[] = [];
    try {
        const response = await deps.fetch(`${binding.apiUrl.replace(/\/+$/, "")}/.well-known/jwks.json`, { headers: { "X-Publishable-Key": binding.publishableKey } });
        const body = response.ok ? ((await response.json()) as { keys?: unknown }) : {};
        if (Array.isArray(body.keys)) keys = body.keys as Jwk[];
    } catch {
        // The reason below.
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

    const bound = bindingProblem(claims, binding);
    if (bound) return reject(bound);
    const { objectId, names } = identityOf(claims, binding.appId);
    if (!objectId && names.length === 0) return reject("the caller's token names no object ID or sign-in name");
    return { verified: true, objectId, names, display: names[0] ?? objectId };
}

/**
 * An operator is in the deploy-time list by object ID. Names can change, so they count only when the token has no
 * object ID (Microsoft identity platform: don't authorize on email or preferred_username).
 */
export function isOperator(caller: VerifiedCaller, settings: Pick<ManageSettings, "operators">): boolean {
    if (caller.objectId) return settings.operators.some((o) => o.objectId === caller.objectId);
    return settings.operators.some((o) => caller.names.some((n) => o.names.includes(n)));
}

/** The control's REQUESTED_BY: "app/" and the caller, in the characters its name rule allows (1 to 64). */
export function requestedByOf(caller: VerifiedCaller): string {
    return `app/${caller.display}`.replace(/[^A-Za-z0-9._@/-]/g, "-").slice(0, 64);
}

/** A checked request, in the control's own words: a run's scenario is "baseline" or one of the control's incidents. */
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
const list = (items: readonly string[]): string => (items.length < 3 ? items.join(" and ") : `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`);

/** The app's scenario as the control knows it: healthy-baseline is the control's "baseline". */
export function controlScenario(scenario: string): string {
    return scenario === "healthy-baseline" ? "baseline" : scenario;
}

/**
 * Accepts only the documented actions and values, within the control's own catalog (its targets, incidents, and minutes),
 * and nothing else: an unknown action, an unknown field, a target the control doesn't have (T5 while it's off), a scenario
 * on a target it doesn't run on, or minutes outside the control's bounds is refused.
 */
export function checkRequest(input: unknown, catalog: ControlCatalog): { ok: true; request: ManageRequest } | { ok: false; reason: string } {
    if (!input || typeof input !== "object" || Array.isArray(input)) return { ok: false, reason: "The request isn't an object." };
    const r = input as Record<string, unknown>;
    const action = r.action;
    if (action !== "session" && action !== "run" && action !== "stop" && action !== "reset") return { ok: false, reason: "The action must be session, run, stop, or reset." };
    const extra = Object.keys(r).filter((k) => !KEYS[action].includes(k));
    if (extra.length > 0) return { ok: false, reason: `Unknown fields: ${extra.join(", ")}.` };
    switch (action) {
        case "session": {
            const { minMinutes, maxMinutes, defaultMinutes } = catalog.session;
            const minutes = r.durationMinutes ?? defaultMinutes;
            if (!isInt(minutes) || minutes < minMinutes || minutes > maxMinutes) return { ok: false, reason: `A session runs ${minMinutes} to ${maxMinutes} minutes.` };
            return { ok: true, request: { action, durationMinutes: minutes } };
        }
        case "run": {
            if (typeof r.scenario !== "string") return { ok: false, reason: "The scenario isn't in the control's catalog." };
            const scenario = controlScenario(r.scenario);
            const rule = scenario === "baseline" ? null : catalog.scenarios[scenario];
            if (scenario !== "baseline" && !rule) return { ok: false, reason: "The scenario isn't in the control's catalog." };
            const targets = rule ? rule.targets.filter((t) => catalog.targets.includes(t)) : catalog.targets;
            if (typeof r.target !== "string" || !targets.includes(r.target)) return { ok: false, reason: targets.length > 0 ? `${r.scenario} runs on ${list(targets)} here.` : `${r.scenario} has no target here.` };
            const max = Math.min(catalog.maxDurationMinutes, rule ? rule.maxMinutes : catalog.maxDurationMinutes);
            const minutes = r.durationMinutes ?? Math.min(10, max);
            if (!isInt(minutes) || minutes < catalog.minDurationMinutes || minutes > max) return { ok: false, reason: `${r.scenario} runs ${catalog.minDurationMinutes} to ${max} minutes.` };
            if (r.intensity !== undefined && (!isInt(r.intensity) || r.intensity < 1 || r.intensity > 10)) return { ok: false, reason: "Intensity is 1 to 10." };
            return { ok: true, request: { action, scenario, target: r.target, durationMinutes: minutes, ...(r.intensity !== undefined ? { intensity: r.intensity as number } : {}) } };
        }
        case "stop":
            return { ok: true, request: { action } };
        case "reset": {
            const targets = r.targets ?? [];
            if (!Array.isArray(targets) || targets.some((t) => typeof t !== "string" || !catalog.targets.includes(t))) return { ok: false, reason: `Reset applies to ${list(catalog.targets)} here.` };
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
            const activity: Record<string, unknown> = { target: request.target, scenario: controlScenario(request.scenario) };
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

/** One run of NB_DatabaseHub_Control, as the job API has it. */
export interface ControlRun {
    id: string;
    /** The job API's status: NotStarted, InProgress, Completed, Failed, Cancelled, or Deduped. */
    status: string;
    startedAt: string | null;
    invokeType?: string;
}

/** What manageAccess says about the signed-in viewer (the app's src/lib/manage-client.ts reads it). */
export interface ManageAccessAnswer {
    /** False when this function can't send for anyone (it isn't set up, or it can't confirm who called): the app copies each request for Run all (C). */
    configured: boolean;
    /** True when the verified caller is an operator: the deployer or a member of the demo's admin group. */
    operator: boolean;
    /** Why not, in one sentence. */
    reason: string;
    /** The verified caller's name, or "" when they weren't verified. */
    who: string;
    /** The control's run that's queued or in progress, read for operators: a new session follows it, and Stop now cancels it first. */
    running: ControlRun | null;
    /** The control's targets, for operators: T5 only while it's on. */
    targets: string[];
}

export interface ManageRequestAnswer {
    started: boolean;
    /** The Fabric job instance of NB_DatabaseHub_Control, when it started. */
    jobInstance: string;
    reason: string;
    /** How the control records the caller (REQUESTED_BY), once they're verified. */
    requestedBy: string;
    /** True when the function couldn't send it, but Run all can: the app offers to copy it instead. */
    copy: boolean;
    /** Stop now: the control's runs it cancelled first, so it can start on a small capacity. */
    cancelled: string[];
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
const NOT_OPERATOR = "Only the demo's operators send actions from the app: the deployer and the members of its admin group. A redeploy refreshes the list.";
const COPY = "so each action copies its request for NB_DatabaseHub_Control, where Run all sends it";

/** Why this deployment's function can't send requests, or "" when its settings are complete. */
export function settingsProblem(settings: ManageSettings): string {
    if (!/^https:\/\//i.test(settings.apiUrl)) return "it has no pinned API to check callers with";
    if (![settings.tenantId, settings.workspaceId, settings.appId].every((id) => GUID.test(id))) return "it doesn't know the app's IDs";
    if (!GUID.test(settings.controlWorkspaceId) || !GUID.test(settings.controlNotebookId)) return "NB_DatabaseHub_Control wasn't found when the app was deployed";
    if (!settings.catalog || settings.catalog.targets.length === 0) return "it has no copy of the control's catalog";
    if (settings.operators.length === 0) return "it has no operators";
    return "";
}

/** An error's message as a clause: one line, at most 300 characters, without its closing period (the answer adds one). */
const clause = (text: string): string => text.replace(/\s+/g, " ").trim().slice(0, 300).replace(/[.\s]+$/, "");
const messageOf = (error: unknown): string => clause(error instanceof Error ? error.message : String(error));

/** Fabric's job times are UTC, often without a zone: one with no zone gets a Z, so browsers don't read it as local time. */
function utc(value: unknown): string | null {
    if (typeof value !== "string" || value === "") return null;
    return /^\d{4}-\d{2}-\d{2}T[\d:.]+$/.test(value) ? `${value}Z` : value;
}

/**
 * The verified operator behind a call, or why there's none. "copy" is true when the function can't send for anyone (it
 * isn't set up, or it couldn't confirm the caller): Run all still can. Nothing runs before this passes.
 */
type Gate = { ok: true; caller: VerifiedCaller; catalog: ControlCatalog } | { ok: false; copy: boolean; reason: string; caller?: VerifiedCaller };

async function gate(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<Gate> {
    const problem = settingsProblem(settings);
    if (problem) return { ok: false, copy: true, reason: `This deployment's Manage function isn't set up (${problem}), ${COPY}.` };
    const caller = await verifyCaller(call.token, { ...settings, publishableKey: call.publishableKey }, deps);
    if (!caller.verified) return { ok: false, copy: true, reason: `Manage couldn't confirm who you are (${caller.reason}), ${COPY}.` };
    if (!isOperator(caller, settings)) return { ok: false, copy: false, reason: NOT_OPERATOR, caller };
    return { ok: true, caller, catalog: settings.catalog as ControlCatalog };
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

/** NB_DatabaseHub_Control's runs that are queued or in progress, from the job API's list; none when it can't be read. */
async function activeRuns(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ControlRun[]> {
    try {
        const response = await fabric(call, deps, jobsPath(settings));
        if (!response.ok) return [];
        const body = (await response.json()) as { value?: unknown };
        const jobs = Array.isArray(body.value) ? (body.value as Array<Record<string, unknown>>) : [];
        return jobs
            .filter((j) => (j.status === "InProgress" || j.status === "NotStarted") && typeof j.id === "string" && GUID.test(j.id))
            .map((j) => ({ id: (j.id as string).toLowerCase(), status: j.status as string, startedAt: utc(j.startTimeUtc), ...(typeof j.invokeType === "string" ? { invokeType: j.invokeType } : {}) }));
    } catch {
        return [];
    }
}

/** manageAccess: whether the signed-in viewer can send actions from the app, the control's run in progress, and its targets. */
export async function answerAccess(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageAccessAnswer> {
    const g = await gate(call, settings, deps);
    if (!g.ok) return { configured: !g.copy, operator: false, reason: g.reason, who: g.caller?.display ?? "", running: null, targets: [] };
    const [running] = await activeRuns(call, settings, deps);
    return { configured: true, operator: true, reason: "", who: g.caller.display, running: running ?? null, targets: [...g.catalog.targets] };
}

/**
 * manageRequest: runs NB_DatabaseHub_Control through the Fabric job API (Run On Demand Item Job, jobType RunNotebook)
 * with a checked request's parameters, and REQUESTED_BY from the verified caller, never from the request. Stop now
 * first cancels the control's own runs in progress (Cancel Item Job Instance): on a small capacity, a run that follows a
 * session holds its Spark session, so the stop would wait for it. The session still ends as its end would.
 */
export async function answerRequest(input: unknown, call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageRequestAnswer> {
    const refuse = (reason: string, copy: boolean, requestedBy = "", cancelled: string[] = []): ManageRequestAnswer => ({ started: false, jobInstance: "", reason, requestedBy, copy, cancelled });
    const g = await gate(call, settings, deps);
    if (!g.ok) return refuse(g.reason, g.copy);
    const checked = checkRequest(input, g.catalog);
    if (!checked.ok) return refuse(checked.reason, false);
    const requestedBy = requestedByOf(g.caller);
    const cancelled: string[] = [];
    try {
        if (checked.request.action === "stop") {
            for (const run of await activeRuns(call, settings, deps)) {
                const answer = await fabric(call, deps, `${jobsPath(settings)}/${run.id}/cancel`, { method: "POST" });
                if (answer.ok) cancelled.push(run.id);
            }
        }
        const response = await fabric(call, deps, `${jobsPath(settings)}?jobType=RunNotebook`, {
            method: "POST",
            body: JSON.stringify({ executionData: { parameters: jobParameters(checked.request, requestedBy) } }),
        });
        if (!response.ok) return refuse(`Fabric didn't start NB_DatabaseHub_Control (${await refusal(response)}). Run all in the notebook sends the same request.`, true, requestedBy, cancelled);
        // 202 Accepted: the Location header is the new job instance's URL.
        const id = (response.headers.get("location") ?? "").replace(/\/+$/, "").split("/").pop() ?? "";
        return { started: true, jobInstance: GUID.test(id) ? id.toLowerCase() : "", reason: "", requestedBy, copy: false, cancelled };
    } catch (error) {
        return refuse(`NB_DatabaseHub_Control wasn't started (${messageOf(error)}). Run all in the notebook sends the same request.`, true, requestedBy, cancelled);
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
        return unknown(`The run couldn't be read (${messageOf(error)}).`);
    }
}