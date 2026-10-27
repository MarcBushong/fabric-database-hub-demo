import { type ReactNode } from "react";

import { useAuth } from "@/hooks/auth.context";
import type { AppRuntime } from "@/lib/runtime-config";

interface AuthGateProps {
    children: ReactNode;
    runtime: AppRuntime;
}

export function AuthGate({ children, runtime }: AuthGateProps) {
    const { isLoading, isAuthenticated, signIn, isSigningIn, signInError } = useAuth();

    if (isLoading) {
        return (
            <div className="gate" role="status">
                <p className="gate-muted">Connecting to Fabric...</p>
            </div>
        );
    }

    if (!isAuthenticated) {
        return (
            <div className="gate">
                <section className="glass gate-card" aria-labelledby="gate-title">
                    <p className="eyebrow">Database Hub Insights · preview</p>
                    <h1 id="gate-title">Sign in to open the demo's history</h1>
                    <p>
                        Use your Fabric account in the demo's tenant
                        {runtime.expectedAccount ? <> (<strong>{runtime.expectedAccount}</strong>)</> : null}. The supported way in is
                        the app's item in the Fabric workspace: open it there and it signs you in by itself.
                    </p>
                    <button type="button" className="btn-primary" onClick={signIn} disabled={isSigningIn} aria-busy={isSigningIn}>
                        {isSigningIn ? "Signing in..." : "Sign in with Fabric"}
                    </button>
                    {signInError && (
                        <p role="alert" className="gate-error">
                            {signInError}
                        </p>
                    )}
                    <ul className="gate-tips">
                        <li>In the Fabric portal, open the demo workspace and select the app item APP_DatabaseHub_Insights.</li>
                        <li>
                            Opening the hosted URL directly is a known preview limitation: the sign-in pop-up can stop at "Page not
                            accessible directly".
                        </li>
                    </ul>
                </section>
            </div>
        );
    }

    return <>{children}</>;
}
