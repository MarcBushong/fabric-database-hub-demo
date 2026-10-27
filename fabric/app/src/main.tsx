import { createRoot } from "react-dom/client";
import { ErrorBoundary } from "react-error-boundary";
import "@fontsource-variable/space-grotesk";
import "@fontsource-variable/jetbrains-mono";

import App from "./App.tsx";
import { ErrorFallback } from "./ErrorFallback";
import { AuthGate } from "./components/auth-gate.component";
import { QueryClientContext } from "./data/use-query";
import { createQueryClient, type Execute } from "./data/query-client";
import { AuthProvider } from "./hooks/use-auth";
import { createRayfinClient } from "./lib/rayfin-client";
import { loadAppRuntime } from "./lib/runtime-config";
import { createAuthService } from "./services/rayfin-auth.service";
import { applyTheme, loadTheme } from "./theme/themes";

import "./styles/app.css";

// Paint the saved theme before anything else, so sign-in already looks like the app.
applyTheme(loadTheme(window.localStorage, window.matchMedia?.("(prefers-contrast: more)").matches ?? false, window.matchMedia?.("(prefers-color-scheme: light)").matches ?? false));

const root = createRoot(document.getElementById("root")!);

loadAppRuntime()
    .then((runtime) => {
        const client = createRayfinClient(runtime);
        const authService = createAuthService(client, runtime);
        // The read-only connector: executeQuery only, delegated to the signed-in user (rayfin.yml).
        const execute: Execute = (input) => client.connectors.history.executeQuery(input) as ReturnType<Execute>;
        const queryClient = createQueryClient(execute);
        root.render(
            <ErrorBoundary FallbackComponent={ErrorFallback}>
                <AuthProvider rayfinAuthService={authService}>
                    <AuthGate runtime={runtime}>
                        <QueryClientContext.Provider value={queryClient}>
                            <App runtime={runtime} />
                        </QueryClientContext.Provider>
                    </AuthGate>
                </AuthProvider>
            </ErrorBoundary>,
        );
    })
    .catch((err: unknown) => {
        root.render(<ErrorFallback error={err} resetErrorBoundary={() => window.location.reload()} />);
    });
