import { type ReactNode } from "react";
import { Button, MessageBar, MessageBarBody, Spinner } from "@fluentui/react-components";
import { Database20Filled } from "@fluentui/react-icons";

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
                <Spinner size="small" label="Connecting to Fabric..." />
            </div>
        );
    }

    if (!isAuthenticated) {
        return (
            <div className="gate">
                <section className="gate-card" aria-labelledby="gate-title">
                    <span className="brand-mark" aria-hidden="true">
                        <Database20Filled />
                    </span>
                    <h1 id="gate-title">Sign in to Database Hub Insights</h1>
                    <p>
                        Use your Fabric account in the demo's tenant
                        {runtime.expectedAccount ? <> (<strong>{runtime.expectedAccount}</strong>)</> : null}. The supported way in is the app's item in the Fabric workspace: open it
                        there and it signs you in by itself.
                    </p>
                    <div>
                        <Button appearance="primary" onClick={signIn} disabled={isSigningIn} aria-busy={isSigningIn}>
                            {isSigningIn ? "Signing in..." : "Sign in with Fabric"}
                        </Button>
                    </div>
                    {signInError ? (
                        <MessageBar intent="error">
                            <MessageBarBody>{signInError}</MessageBarBody>
                        </MessageBar>
                    ) : null}
                    <ul>
                        <li>In the Fabric portal, open the demo workspace and select the app item APP_DatabaseHub_Insights.</li>
                        <li>Opening the hosted URL directly is a known preview limitation: the sign-in pop-up can stop at "Page not accessible directly".</li>
                    </ul>
                </section>
            </div>
        );
    }

    return <>{children}</>;
}
