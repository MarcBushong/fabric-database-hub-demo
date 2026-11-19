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
    /**
     * Fabric's sign-in email for this app (xms_attr[appId].rfn_email), lowercased, read only once the token's audience or
     * subject path has tied it to this app; "" when there's none. Without an object ID, it's the one name an operator can
     * match on (ADR 0029), until the identity proof shows whether Fabric's managed token carries an object ID.
     */
    appEmail: string;
    /** Their names in the token (email, upn, preferred_username, unique_name, and the app email), lowercased: for the record only. */
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

const audiencesOf = (claims: Claims): string[] => (Array.isArray(claims.aud) ? claims.aud : [claims.aud]).filter((a): a is string => typeof a === "string");

/**
 * What ties a token to this app, or "": an audience naming the app (its ID, api://<its ID>, its API, or the pinned
 * audience when that names the app's ID), or Fabric's managed token's subject path through this app. Nothing else counts:
 * a key for the app among a token's attributes (xms_attr) doesn't, because a token for another app can carry one too.
 */
function appTie(claims: Claims, binding: TokenBinding): "audience" | "subject" | "" {
    const app = lower(binding.appId);
    if (!app) return "";
    const api = lower(binding.apiUrl).replace(/\/+$/, "");
    const pinned = lower(binding.audience).replace(/\/+$/, "");
    const named = audiencesOf(claims).some((a) => {
        const audience = lower(a).replace(/\/+$/, "");
        return audience === app || audience === `api://${app}` || audience === api || (pinned !== "" && audience === pinned && pinned.includes(app));
    });
    if (named) return "audience";
    return lower(claims.sub).includes(`/workspaces/${lower(binding.workspaceId)}/appbackends/${app}/users/`) ? "subject" : "";
}

/**
 * Why a verified token isn't for this app, or "". Its issuer and audience must equal the pinned ones once known (the
 * identity proof shows them); with or without them, the deployment record's IDs bind it: its tenant (tid, or the tenant
 * in Fabric's managed token's subject path), and this app (appTie).
 */
function bindingProblem(claims: Claims, binding: TokenBinding): string {
    const issuer = typeof claims.iss === "string" ? claims.iss : "";
    if (binding.issuer ? issuer !== binding.issuer : !/^https:\/\/\S+$/i.test(issuer)) return binding.issuer ? "the caller's token is from another issuer" : "the caller's token names no issuer";
    if (binding.audience && !audiencesOf(claims).includes(binding.audience)) return "the caller's token is for another audience";
    const tenant = lower(binding.tenantId);
    const subject = lower(claims.sub);
    // Fabric's managed token names its tenant, workspace, and app in its subject path: when it does, they must be this app's.
    const path = (segment: string) => new RegExp(`/${segment}/([^/]+)/`).exec(subject)?.[1];
    const pathTenant = path("tenants");
    if (claims.tid !== undefined ? lower(claims.tid) !== tenant || (pathTenant !== undefined && pathTenant !== tenant) : pathTenant !== tenant) return "the caller's token is for another tenant";
    const pathWorkspace = path("workspaces");
    const pathApp = path("appbackends");
    if ((pathWorkspace !== undefined && pathWorkspace !== lower(binding.workspaceId)) || (pathApp !== undefined && pathApp !== lower(binding.appId))) return "the caller's token isn't for this app";
    return appTie(claims, binding) ? "" : "the caller's token isn't for this app";
}

/**
 * Who the token names: its object ID (oid); Fabric's sign-in email for this app (xms_attr[appId].rfn_email), only when
 * the token is tied to this app; and its names, for the record.
 */
function identityOf(claims: Claims, appId: string, tied: boolean): { objectId: string; appEmail: string; names: string[] } {
    const objectId = typeof claims.oid === "string" && GUID.test(claims.oid) ? claims.oid.toLowerCase() : "";
    let appEmail = "";
    if (tied && claims.xms_attr && typeof claims.xms_attr === "object") {
        for (const [key, value] of Object.entries(claims.xms_attr as Record<string, unknown>)) {
            if (lower(key) === lower(appId) && value && typeof value === "object") appEmail = lower((value as Record<string, unknown>).rfn_email);
        }
    }
    const names = [claims.email, claims.upn, claims.preferred_username, claims.unique_name, appEmail]
        .filter((n): n is string => typeof n === "string" && n.trim() !== "")
        .map((n) => n.trim().toLowerCase())
        .filter((n, i, all) => all.indexOf(n) === i);
    return { objectId, appEmail, names };
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
    const { objectId, appEmail, names } = identityOf(claims, binding.appId, appTie(claims, binding) !== "");
    // Names can change, so they don't identify a caller: an object ID does, or, without one, Fabric's email for this app.
    if (!objectId && !appEmail) return reject("the caller's token names no object ID, and no sign-in email from Fabric for this app");
    return { verified: true, objectId, appEmail, names, display: names[0] ?? objectId };
}

/**
 * An operator is in the deploy-time list by object ID. Without one, Fabric's sign-in email for this app is the one name
 * that counts (ADR 0029: accepted until the identity proof); the token's other names never do (Microsoft identity
 * platform: don't authorize on email or preferred_username).
 */
export function isOperator(caller: VerifiedCaller, settings: Pick<ManageSettings, "operators">): boolean {
    if (caller.objectId) return settings.operators.some((o) => o.objectId === caller.objectId);
    return caller.appEmail !== "" && settings.operators.some((o) => o.names.includes(caller.appEmail));
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
    /** The control's run in progress that kept this request from starting: the control takes one request at a time. */
    running?: ControlRun;
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
    /** Waits between Fabric's answers (the tests pass a clock of their own). */
    sleep?: (ms: number) => Promise<void>;
}

/** The Fabric REST API's job scheduler (https://learn.microsoft.com/rest/api/fabric/core/job-scheduler). */
const FABRIC_API = "https://api.fabric.microsoft.com/v1";
const NOT_OPERATOR = "Only the demo's operators send actions from the app: the deployer and the members of its admin group. A redeploy refreshes the list.";
const COPY = "so each action copies its request for NB_DatabaseHub_Control, where Run all sends it";
/**
 * How long Stop now may wait, in all, for the runs it cancelled to end and for the capacity to take the stop: a function
 * runs at most 240 seconds (https://learn.microsoft.com/fabric/data-engineering/user-data-functions/user-data-functions-service-limits),
 * and the app waits 200 for its answer (src/lib/manage-client.ts).
 */
export const STOP_WAIT_MS = 150_000;
/** Between reads of a cancelled run, and between starts the capacity refused, when Fabric asks for no interval. */
const POLL_MS = 5_000;
const CAPACITY_RETRY_MS = 20_000;
/** Fabric's job states that end a run (ItemJobStatus); any other state is still running. */
const ENDED = new Set(["Completed", "Failed", "Cancelled", "Deduped"]);
const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

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

/** NB_DatabaseHub_Control's runs that are queued or in progress, from the job API's list, or why it couldn't be read. */
async function activeRuns(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<{ runs: ControlRun[] } | { error: string }> {
    try {
        const response = await fabric(call, deps, jobsPath(settings));
        if (!response.ok) return { error: await refusal(response) };
        const body = (await response.json()) as { value?: unknown };
        const jobs = Array.isArray(body.value) ? (body.value as Array<Record<string, unknown>>) : [];
        return {
            runs: jobs
                .filter((j) => (j.status === "InProgress" || j.status === "NotStarted") && typeof j.id === "string" && GUID.test(j.id))
                .map((j) => ({ id: (j.id as string).toLowerCase(), status: j.status as string, startedAt: utc(j.startTimeUtc), ...(typeof j.invokeType === "string" ? { invokeType: j.invokeType } : {}) })),
        };
    } catch (error) {
        return { error: messageOf(error) };
    }
}

/** manageAccess: whether the signed-in viewer can send actions from the app, the control's run in progress, and its targets. */
export async function answerAccess(call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageAccessAnswer> {
    const g = await gate(call, settings, deps);
    if (!g.ok) return { configured: !g.copy, operator: false, reason: g.reason, who: g.caller?.display ?? "", running: null, targets: [] };
    const active = await activeRuns(call, settings, deps);
    const running = "runs" in active ? (active.runs[0] ?? null) : null;
    return { configured: true, operator: true, reason: "", who: g.caller.display, running, targets: [...g.catalog.targets] };
}

/** How long Fabric asks to wait before the next call (Retry-After: seconds, or an HTTP date), in milliseconds, or the fallback. */
function retryAfterMs(response: Response, fallback: number, now: number): number {
    const value = (response.headers.get("retry-after") ?? "").trim();
    if (/^\d+$/.test(value)) return Math.max(1_000, Number(value) * 1_000);
    const at = Date.parse(value);
    return value && !Number.isNaN(at) ? Math.max(1_000, at - now) : fallback;
}

/** Whether Fabric refused a run because the capacity's Spark cores are all in use (HTTP 430, TooManyRequestsForCapacity), or throttled it (429). */
async function capacityRefused(response: Response): Promise<boolean> {
    if (response.status === 430 || response.status === 429) return true;
    if (response.ok) return false;
    try {
        return ((await response.clone().json()) as { errorCode?: unknown }).errorCode === "TooManyRequestsForCapacity";
    } catch {
        return false;
    }
}

/**
 * Waits for the runs Stop now cancelled to end: Fabric's cancel only asks (HTTP 202), and on a small capacity (F2, F4) the
 * stop can't start while a cancelled run still holds the Spark session. It reads each run no sooner than Fabric asks
 * (Retry-After), until the deadline. Returns the runs that hadn't ended by then.
 */
async function waitForEnd(ids: readonly string[], firstWait: number, call: ManageCall, settings: ManageSettings, deps: ManageDeps, deadline: number): Promise<string[]> {
    const now = deps.now ?? Date.now;
    const sleep = deps.sleep ?? pause;
    let waiting = [...ids];
    let wait = firstWait;
    while (waiting.length > 0 && now() + wait <= deadline) {
        await sleep(wait);
        const still: string[] = [];
        let next = POLL_MS;
        for (const id of waiting) {
            const response = await fabric(call, deps, `${jobsPath(settings)}/${id}`);
            // A run Fabric no longer has has ended.
            if (response.status === 404) continue;
            let status = "";
            if (response.ok) {
                try {
                    status = String(((await response.json()) as Record<string, unknown>).status ?? "");
                } catch {
                    status = "";
                }
            }
            if (!ENDED.has(status)) {
                still.push(id);
                next = Math.max(next, retryAfterMs(response, POLL_MS, now()));
            }
        }
        waiting = still;
        wait = next;
    }
    return waiting;
}

const shortIds = (ids: readonly string[]): string => list(ids.map((id) => id.slice(0, 8)));

/**
 * manageRequest: runs NB_DatabaseHub_Control through the Fabric job API (Run On Demand Item Job, jobType RunNotebook)
 * with a checked request's parameters, and REQUESTED_BY from the verified caller, never from the request. The control
 * takes one request at a time, so while one of its runs is queued or in progress, only Stop now is sent. Stop now first
 * cancels the control's runs in progress (Cancel Item Job Instance), waits for them to end, and asks again while the
 * capacity refuses it (HTTP 430), within STOP_WAIT_MS: on a small capacity, a run that follows a session holds its Spark
 * session, so the stop would wait for it. The session still ends as its end would; if the run cancelled was ending a
 * session, the stop saves that session's history (NB_DatabaseHub_Control's Stop now, 2026-11-19).
 */
export async function answerRequest(input: unknown, call: ManageCall, settings: ManageSettings, deps: ManageDeps): Promise<ManageRequestAnswer> {
    const refuse = (reason: string, copy: boolean, requestedBy = "", cancelled: string[] = []): ManageRequestAnswer => ({ started: false, jobInstance: "", reason, requestedBy, copy, cancelled });
    const g = await gate(call, settings, deps);
    if (!g.ok) return refuse(g.reason, g.copy);
    const checked = checkRequest(input, g.catalog);
    if (!checked.ok) return refuse(checked.reason, false);
    const requestedBy = requestedByOf(g.caller);
    const now = deps.now ?? Date.now;
    const sleep = deps.sleep ?? pause;
    const stop = checked.request.action === "stop";
    const cancelled: string[] = [];
    const notStopped = (why: string) =>
        refuse(
            `Stop now cancelled NB_DatabaseHub_Control's run ${shortIds(cancelled)}, but ${why}. Nothing is stopping the session now: Run all in the notebook sends the same request, or ./scripts/stop-demo.ps1 -SaveHistory stops it from a PC. Its auto-stop still stops everything at its end, and the next Run all saves its history.`,
            true,
            requestedBy,
            cancelled,
        );
    try {
        const active = await activeRuns(call, settings, deps);
        if (!stop) {
            if ("error" in active) return refuse(`Fabric didn't list NB_DatabaseHub_Control's runs (${active.error}), so the app can't tell whether one is in progress. Run all in the notebook sends the same request.`, true, requestedBy);
            const [running] = active.runs;
            if (running) {
                const state = running.status === "NotStarted" ? "queued" : "in progress";
                return { ...refuse(`NB_DatabaseHub_Control's run ${running.id.slice(0, 8)} is ${state}, and the control takes one request at a time: wait for it to end, or use Stop now, which ends the session as its end would.`, false, requestedBy), running };
            }
        }
        const deadline = now() + STOP_WAIT_MS;
        if (stop && "runs" in active) {
            let firstWait = POLL_MS;
            for (const run of active.runs) {
                const answer = await fabric(call, deps, `${jobsPath(settings)}/${run.id}/cancel`, { method: "POST" });
                // A run that ended meanwhile can't be cancelled: there's nothing to wait for.
                if (answer.ok) {
                    cancelled.push(run.id);
                    firstWait = Math.max(firstWait, retryAfterMs(answer, POLL_MS, now()));
                }
            }
            if (cancelled.length > 0) await waitForEnd(cancelled, firstWait, call, settings, deps, deadline);
        }
        const start = () => fabric(call, deps, `${jobsPath(settings)}?jobType=RunNotebook`, { method: "POST", body: JSON.stringify({ executionData: { parameters: jobParameters(checked.request, requestedBy) } }) });
        let response = await start();
        // Stop now asks again while the capacity refuses it, as the notebook's history job does.
        while (stop && (await capacityRefused(response))) {
            const wait = retryAfterMs(response, CAPACITY_RETRY_MS, now());
            if (now() + wait > deadline) break;
            await sleep(wait);
            response = await start();
        }
        if (!response.ok) {
            const why = await refusal(response);
            if (cancelled.length > 0) return notStopped(`Fabric didn't start the stop (${why})`);
            return refuse(`Fabric didn't start NB_DatabaseHub_Control (${why}). Run all in the notebook sends the same request.`, true, requestedBy, cancelled);
        }
        // 202 Accepted: the Location header is the new job instance's URL.
        const id = (response.headers.get("location") ?? "").replace(/\/+$/, "").split("/").pop() ?? "";
        return { started: true, jobInstance: GUID.test(id) ? id.toLowerCase() : "", reason: "", requestedBy, copy: false, cancelled };
    } catch (error) {
        if (cancelled.length > 0) return notStopped(`the stop wasn't started (${messageOf(error)})`);
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