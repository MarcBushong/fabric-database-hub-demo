// How the Manage page reaches the demo's session control. A (decided 2026-11-18): the app's Manage function (rayfin/
// functions/src/manage.ts) verifies the caller, checks the operators list and the control's bounds, and runs
// NB_DatabaseHub_Control through the Fabric job API. C, the automatic fallback when that function isn't deployed: the
// app copies the request's parameters and opens the notebook, where Run all sends it. No secret reaches the browser in
// either: the control's webhook URL stays in Key Vault, read by the notebook.

import type { ControlRequest, NotebookParameter } from "./control";
import { notebookParameters } from "./control";

/** What the Manage function says about the signed-in viewer. */
export interface ManageAccessAnswer {
    /** True when the verified caller is an operator: the deployer or a member of the demo's admin group. */
    operator: boolean;
    /** Why not, in one sentence, when they aren't. */
    reason: string;
    /** The verified caller, as the control records them (REQUESTED_BY). */
    who: string;
    /** The control's run in progress, when there is one: a new session replaces it (the newest request wins). */
    running: { startedAt: string; invokeType?: string } | null;
}

export interface ManageRequestAnswer {
    started: boolean;
    /** The Fabric job instance of NB_DatabaseHub_Control, when it started. */
    jobInstance: string;
    reason: string;
    requestedBy: string;
}

export interface ManageJobAnswer {
    status: string;
    startedAt?: string | null;
    endedAt?: string | null;
    failureReason?: string | null;
}

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

interface FunctionClients {
    functions: { [K in keyof ManageFunctionsSchema]: { invoke(input?: ManageFunctionsSchema[K]["input"]): Promise<ManageFunctionsSchema[K]["output"]> } };
}

/** The Manage API over the app's Rayfin client; its calls reject when the function isn't deployed. */
export function functionsManageApi(client: unknown): ManageApi {
    const fns = (client as FunctionClients).functions;
    return {
        access: () => fns.manageAccess.invoke(),
        request: (request) => fns.manageRequest.invoke({ request }),
        job: (jobInstance) => fns.manageJob.invoke({ jobInstance }),
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
