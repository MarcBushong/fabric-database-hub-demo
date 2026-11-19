import { createRoot } from "react-dom/client";
import { ErrorBoundary } from "react-error-boundary";

import App from "./App.tsx";
import { ErrorFallback } from "./ErrorFallback";
import { AuthGate } from "./components/auth-gate.component";
import { CopilotProvider } from "./copilot/CopilotProvider";
import { QueryClientContext } from "./data/use-query";
import { createQueryClient, type Execute } from "./data/query-client";
import { AuthProvider } from "./hooks/use-auth";
import { createRayfinClient } from "./lib/rayfin-client";
import { loadAppRuntime } from "./lib/runtime-config";
import { createAuthService } from "./services/rayfin-auth.service";
import { AppThemeProvider } from "./theme/AppThemeProvider";

import "./styles/app.css";

const root = createRoot(document.getElementById("root")!);

loadAppRuntime()
    .then((runtime) => {
        const client = createRayfinClient(runtime);
        const authService = createAuthService(client, runtime);
        // The read-only connector: executeQuery only, delegated to the signed-in user (rayfin.yml).
        const execute: Execute = (input) => client.connectors.history.executeQuery(input) as ReturnType<Execute>;
        const queryClient = createQueryClient(execute);
        root.render(
            <AppThemeProvider>
                <ErrorBoundary FallbackComponent={ErrorFallback}>
                    <AuthProvider rayfinAuthService={authService}>
                        <AuthGate runtime={runtime}>
                            <QueryClientContext.Provider value={queryClient}>
                                <CopilotProvider>
                                    <App runtime={runtime} />
                                </CopilotProvider>
                            </QueryClientContext.Provider>
                        </AuthGate>
                    </AuthProvider>
                </ErrorBoundary>
            </AppThemeProvider>,
        );
    })
    .catch((err: unknown) => {
        root.render(
            <AppThemeProvider>
                <ErrorFallback error={err} resetErrorBoundary={() => window.location.reload()} />
            </AppThemeProvider>,
        );
    });
