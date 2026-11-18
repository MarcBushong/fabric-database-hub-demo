// The demo's own resources, the only scope the estate function reads. scripts/configure-fabric-app.ps1 writes the
// real values into the deploy stage (out/fabric-app); Git holds this empty placeholder, so the function answers
// "no scope" until it's deployed.
import type { EstateScope } from "./estate-core.js";

export const ESTATE_SCOPE: EstateScope = { subscriptionId: "", resourceGroups: [] };
