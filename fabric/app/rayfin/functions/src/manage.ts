// Manage's functions (ADR 0028, A): manageAccess says whether the signed-in viewer can send actions from the app,
// manageRequest runs NB_DatabaseHub_Control with a checked request through the Fabric job API, and manageJob reads that
// run. The checks and answers are in manage-core.ts, the deploy-time settings in manage.generated.ts. The caller comes
// only from the Rayfin runtime (ctx.accessToken, which the app's backend checked, verified again with the app's own
// keys), and the job runs with the Fabric token the runtime mints for the function (ctx.Tokens.Fabric).
// https://learn.microsoft.com/fabric/apps/functions
// Each handler spells out RayfinContext<...>: the runtime finds the context parameter by that annotation's text.
import { AudienceType, type RayfinContext, type UserDataFunctions } from "@microsoft/fabric-user-data-functions";

import { answerAccess, answerJob, answerRequest, type ManageCall, type ManageDeps } from "./manage-core.js";
import { MANAGE_SETTINGS } from "./manage.generated.js";

const deps: ManageDeps = { fetch: (url, init) => fetch(url, init) };

function callOf(ctx: RayfinContext<Record<string, never>, AudienceType.Fabric>): ManageCall {
    return { token: ctx.accessToken, publishableKey: ctx.publishableKey, fabricToken: () => ctx.Tokens.Fabric };
}

export function registerManage(udf: UserDataFunctions): void {
    udf.func(
        "manageAccess",
        async (ctx: RayfinContext<Record<string, never>, AudienceType.Fabric>) => {
            const answer = await answerAccess(callOf(ctx), MANAGE_SETTINGS, deps);
            console.log(`manageAccess: ${answer.configured ? (answer.operator ? "operator" : "read-only") : "not set up"}`);
            return answer;
        },
        [],
    );
    udf.func(
        "manageRequest",
        async (request: unknown, ctx: RayfinContext<Record<string, never>, AudienceType.Fabric>) => {
            const answer = await answerRequest(request, callOf(ctx), MANAGE_SETTINGS, deps);
            const action = request && typeof request === "object" ? String((request as { action?: unknown }).action ?? "") : "";
            console.log(`manageRequest ${action.replace(/[^a-z]/g, "").slice(0, 16)}: ${answer.started ? `started ${answer.jobInstance}` : "not started"}`);
            return answer;
        },
        [],
    );
    udf.func(
        "manageJob",
        async (jobInstance: string, ctx: RayfinContext<Record<string, never>, AudienceType.Fabric>) => answerJob(jobInstance, callOf(ctx), MANAGE_SETTINGS, deps),
        [],
    );
}
