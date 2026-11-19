// How the Manage page reaches the demo's session control. A (decided 2026-11-18): the app's Manage function (rayfin/
// functions/src/manage.ts) verifies the caller, checks the operators list and the control's bounds, and runs
// NB_DatabaseHub_Control through the Fabric job API. C, the automatic fallback when that function isn't deployed or
// isn't set up: the app copies the request's parameters and opens the notebook, where Run all sends it. No secret
// reaches the browser in either: the control's webhook URL stays in Key Vault, read by the notebook.

import type { ControlRun, ManageAccessAnswer, ManageJobAnswer, ManageRequestAnswer } from "../../rayfin/functions/src/manage-core";
import { MANAGE_READ_ONLY, type ManageAccess } from "../app-context";
import type { ControlRequest, NotebookParameter } from "./control";
import { notebookParameters } from "./control";

// The Manage function's answers, defined once beside its checks.
export type { ControlRun, ManageAccessAnswer, ManageJobAnswer, ManageRequestAnswer };

/** The Manage function's schema, for `client.functions` (the shared functions project registers it in manage.ts). */
export type ManageFunctionsSchema = {
    manageAccess: { input: void; output: ManageAccessAnswer };
    manageRequest: { input: { request: ControlRequest }; output: ManageRequestAnswer };
    manageJob: { input: { jobInstance: string }; output: ManageJobAnswer };
};

export interface ManageApi {
    access(): Promise<ManageAccessAnswer>;
    request(request: ControlRequest): Promise<ManageRequestAnswer>;
    job(jobInstance: string): Promise<ManageJobAnswer>;
}

type Invoke = (input?: unknown, options?: { timeoutMs?: number }) => Promise<unknown>;

/** One of the app's functions, or null when this deployment doesn't have it. */
function functionOf(client: unknown, name: keyof ManageFunctionsSchema): Invoke | null {
    try {
        const fn = (client as { functions?: Record<string, { invoke?: Invoke } | undefined> }).functions?.[name];
        return fn && typeof fn.invoke === "function" ? fn.invoke.bind(fn) : null;
    } catch {
        return null;
    }
}

/** The Manage API over the app's Rayfin client; its calls reject when the function isn't deployed or can't be reached. */
export function functionsManageApi(client: unknown): ManageApi {
    const call = async <T>(name: keyof ManageFunctionsSchema, input?: unknown): Promise<T> => {
        const invoke = functionOf(client, name);
        if (!invoke) throw new Error("This deployment has no Manage function.");
        const raw = await invoke(input, { timeoutMs: 60_000 });
        const answer = typeof raw === "string" ? (JSON.parse(raw) as unknown) : raw;
        if (!answer || typeof answer !== "object") throw new Error("The Manage function returned an unexpected answer.");
        return answer as T;
    };
    return {
        access: () => call<ManageAccessAnswer>("manageAccess"),
        request: (request) => call<ManageRequestAnswer>("manageRequest", { request }),
        job: (jobInstance) => call<ManageJobAnswer>("manageJob", { jobInstance }),
    };
}

/**
 * Which way Manage sends actions, from the function's answer about the viewer: copy mode (C), with the function's reason,
 * when the function can't send for anyone (it isn't set up, or it couldn't confirm the caller); otherwise the app sends,
 * or it's read-only for a verified viewer who isn't an operator. `fallBack` switches to copy mode, for a request the
 * function couldn't send.
 */
export function manageAccessOf(answer: ManageAccessAnswer, api: Pick<ManageApi, "request" | "job">, fallBack?: (reason: string) => void): ManageAccess {
    if (answer.configured === false) return { ...MANAGE_READ_ONLY, reason: answer.reason || MANAGE_READ_ONLY.reason };
    return {
        mode: "run",
        canRun: answer.operator,
        reason: answer.operator ? "" : answer.reason,
        who: answer.who,
        running: answer.running,
        targets: Array.isArray(answer.targets) && answer.targets.length > 0 ? answer.targets : undefined,
        send: (r) => api.request(r),
        job: (id) => api.job(id),
        fallBack,
    };
}

function literal(name: string, p: NotebookParameter): string {
    if (p.type === "bool") return p.value ? "True" : "False";
    if (p.type === "int") return String(p.value);
    // ACTIVITIES and RESET_TARGETS are JSON text for the job API; pasted into the notebook, they're Python literals.
    if ((name === "ACTIVITIES" || name === "RESET_TARGETS") && typeof p.value === "string") return p.value;
    return JSON.stringify(p.value);
}

/**
 * The request as lines for a new cell under NB_DatabaseHub_Control's parameters cell (C): Run all then sends it, with
 * the same checks. The parameters cell keeps its environment values, so the lines go in a cell of their own.
 */
export function parameterCellText(request: ControlRequest): string {
    const params = notebookParameters(request);
    return [`# From the Insights app: ${request.action}. Paste into a new cell under the parameters cell, then Run all.`, ...Object.entries(params).map(([name, p]) => `${name} = ${literal(name, p)}`)].join("\n");
}
