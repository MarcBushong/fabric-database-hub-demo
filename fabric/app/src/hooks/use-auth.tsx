import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { OpaqueSession } from "@microsoft/rayfin-auth";

import { describeSignInError, type IAuthService } from "@/services/rayfin-auth.service";
import { AuthContext, type AuthContextValue } from "./auth.context";

interface AuthProviderProps {
    children: ReactNode;
    rayfinAuthService: IAuthService;
}

/**
 * Resolves the session once on mount, as the Fabric SSO docs give it for page load:
 * 1. initEmbeddedAuth on every load: it returns an existing session first and, inside the
 *    Fabric portal's item frame, signs in without a pop-up;
 * 2. otherwise a session the SDK restored from storage.
 * Otherwise it settles unauthenticated and the AuthGate offers interactive sign-in from a click.
 */
export function AuthProvider({ children, rayfinAuthService }: AuthProviderProps) {
    const [session, setSession] = useState<OpaqueSession | null>(null);
    const [isLoading, setIsLoading] = useState(true);
    const [isSigningIn, setIsSigningIn] = useState(false);
    const [signInError, setSignInError] = useState<string | null>(null);
    const signInRequestRef = useRef<Promise<OpaqueSession> | null>(null);

    useEffect(() => {
        let cancelled = false;
        const unsubscribe = rayfinAuthService.onSessionChange((next) => {
            if (!cancelled) setSession(next?.isAuthenticated ? next : null);
        });
        (async () => {
            try {
                const embedded = await rayfinAuthService.initEmbeddedAuth();
                const resolved = embedded?.isAuthenticated ? embedded : rayfinAuthService.currentSession();
                if (!cancelled && resolved) setSession(resolved);
            } catch (err) {
                const restored = rayfinAuthService.currentSession();
                if (!cancelled && restored) {
                    setSession(restored);
                    return;
                }
                if (!cancelled) setSignInError(describeSignInError(err));
            } finally {
                if (!cancelled) setIsLoading(false);
            }
        })();
        return () => {
            cancelled = true;
            unsubscribe();
        };
    }, [rayfinAuthService]);

    const signIn = useCallback(() => {
        if (signInRequestRef.current) return;
        let request: Promise<OpaqueSession>;
        try {
            // Keep the SDK call in the synchronous click stack so its pop-up isn't blocked.
            request = rayfinAuthService.signIn();
        } catch (err) {
            setSignInError(describeSignInError(err));
            return;
        }
        signInRequestRef.current = request;
        setIsSigningIn(true);
        setSignInError(null);
        void request
            .then((next) => setSession(next?.isAuthenticated ? next : null))
            .catch((err: unknown) => setSignInError(describeSignInError(err)))
            .finally(() => {
                if (signInRequestRef.current === request) {
                    signInRequestRef.current = null;
                    setIsSigningIn(false);
                }
            });
    }, [rayfinAuthService]);

    const signOut = useCallback(() => {
        void rayfinAuthService.signOut().finally(() => setSession(null));
    }, [rayfinAuthService]);

    const value = useMemo<AuthContextValue>(
        () => ({
            session,
            isAuthenticated: session?.isAuthenticated ?? false,
            isLoading,
            signIn,
            signOut,
            isSigningIn,
            signInError,
        }),
        [session, isLoading, signIn, signOut, isSigningIn, signInError],
    );

    return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
