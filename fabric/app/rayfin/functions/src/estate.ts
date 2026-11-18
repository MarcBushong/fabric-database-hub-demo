// estateOverview: the live estate for the Copilot dock and the pages. It reads Database Hub's view of the demo's own
// resources as the app item's owner (ctx.Tokens.Fabric), read-only, through estate-core.ts, scoped to the resource
// group that configure-fabric-app.ps1 writes into the stage (scope.generated.ts).
import { AudienceType, type RayfinContext, type UserDataFunctions } from "@microsoft/fabric-user-data-functions";

import { readEstate, type EstateAnswer, type EstateView } from "./estate-core.js";
import { ESTATE_SCOPE } from "./scope.generated.js";

const VIEWS: readonly EstateView[] = ["inventory", "health", "security"];

export function registerEstate(udf: UserDataFunctions): void {
    udf.func(
        "estateOverview",
        async (view: string, ctx: RayfinContext<Record<string, never>, AudienceType.Fabric>): Promise<EstateAnswer> => {
            const v = (VIEWS as readonly string[]).includes(view) ? (view as EstateView) : "inventory";
            const answer = await readEstate(v, ESTATE_SCOPE, ctx.Tokens.Fabric, (url, init) => fetch(url, init));
            console.log(`estateOverview ${v}: ${answer.source.length} routes, ${answer.errors.length} errors`);
            return answer;
        },
        [],
    );
}
