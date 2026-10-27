import type { OpaqueSession } from "@microsoft/rayfin-auth";
import {
    ensureSignedInWithFabric,
    initEmbeddedAuth as sdkInitEmbeddedAuth,
    type FabricAuthOptions,
} from "@microsoft/rayfin-auth-provider-fabric";
import type { AppClient } from "@/lib/rayfin-client";
import type { AppRuntime } from "@/lib/runtime-config";

export interface IAuthService {
    /** The session the SDK restored from storage, for example after the protected-hosting gate signed the user in. */
    currentSession(): OpaqueSession | null;
    onSessionChange(callback: (session: OpaqueSession | null) => void): () => void;
    /** Embedded (Fabric portal iframe) sign-in without UI; null when the app isn't embedded. */
    initEmbeddedAuth(): Promise<OpaqueSession | null>;
    /** The documented Fabric sign-in waterfall. Call it from a click handler: it may open the Fabric pop-up. */
    signIn(): Promise<OpaqueSession>;
    signOut(): Promise<void>;
}

/** Fabric SSO through @microsoft/rayfin-auth-provider-fabric, as the data app template wires it. */
export function createAuthService(client: AppClient, runtime: AppRuntime): IAuthService {
    const fabricOptions: FabricAuthOptions = {
        workspaceId: runtime.workspaceId,
        projectId: runtime.itemId,
        fabricPortalUrl: runtime.portalUrl,
        returnOrigin: window.location.origin,
    };
    return {
        currentSession: () => {
            const session = client.auth.getSession();
            return session?.isAuthenticated ? session : null;
        },
        onSessionChange: (callback) => client.auth.onSessionChange(callback),
        initEmbeddedAuth: () => sdkInitEmbeddedAuth(client.auth, fabricOptions),
        signIn: () => ensureSignedInWithFabric(client.auth, fabricOptions),
        signOut: () => client.auth.signOut(),
    };
}

/** Plain-language help for Fabric sign-in failures, keyed by the SDK's AuthError codes. */
export function describeSignInError(err: unknown): string {
    const code = typeof err === "object" && err !== null && "code" in err ? String((err as { code: unknown }).code) : "";
    const message = err instanceof Error ? err.message : String(err);
    switch (code) {
        case "TAB_BLOCKED":
            return "The browser blocked the Fabric sign-in pop-up. Allow pop-ups for this site, then select Sign in again.";
        case "FABRIC_AUTH_TIMEOUT":
            return "Sign-in didn't finish within 5 minutes. Select Sign in again and finish in the pop-up.";
        default:
            return `Sign-in didn't finish: ${message} Open the app from its item in the Fabric workspace instead: there it signs in without a pop-up. Opening the hosted URL directly is a known preview limitation (the pop-up shows "Page not accessible directly").`;
    }
}
