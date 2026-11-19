// estateOverview: the live estate for the Copilot dock and the pages. It reads Database Hub's view of the demo's own
// resources as the app item's owner (ctx.Tokens.Fabric), read-only, through estate-core.ts, scoped to the resource
// group that configure-fabric-app.ps1 writes into the stage (scope.generated.ts).
import { AudienceType, type RayfinContext, type UserDataFunctions } from "@microsoft/fabric-user-data-functions";

import { readEstate, type EstateAnswer, type EstateView } from "./estate-core.js";
import { ESTATE_SCOPE } from "./scope.generated.js";

const VIEWS: readonly EstateView[] = ["inventory", "health", "security"];
/** Every viewer gets the same scope, read as the app's owner, so a warm host shares one answer for a minute. */
const TTL_MS = 60_000;
const cache = new Map<EstateView, { at: number; answer: Promise<EstateAnswer> }>();

export function registerEstate(udf: UserDataFunctions): void {
    udf.func(
        "estateOverview",
        async (view: string, ctx: RayfinContext<Record<string, never>, AudienceType.Fabric>): Promise<EstateAnswer> => {
            const v = (VIEWS as readonly string[]).includes(view) ? (view as EstateView) : "inventory";
            const hit = cache.get(v);
            if (hit && Date.now() - hit.at < TTL_MS) return hit.answer;
            const answer = readEstate(v, ESTATE_SCOPE, ctx.Tokens.Fabric, (url, init) => fetch(url, init));
            cache.set(v, { at: Date.now(), answer });
            const done = await answer;
            // A partial answer isn't shared: the next call reads again.
            if (done.errors.length > 0) cache.delete(v);
            console.log(`estateOverview ${v}: ${done.source.length} routes, ${done.errors.length} errors`);
            return done;
        },
        [],
    );
}
