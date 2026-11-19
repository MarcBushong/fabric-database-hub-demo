// The local preview: the app with made-up history and no Fabric sign-in, for development and screenshots
// (npm run dev:sample opens /preview.html). Query parameters: theme=light|dark|contrast, copilot=open, manage=operator|viewer|running,
// empty=1 (no history: the first-run state), live=off (no live estate source). Vite builds only index.html, so none of
// this ships in the app.

import { createRoot } from "react-dom/client";

import App from "../App";
import { MANAGE_READ_ONLY, type ManageAccess } from "../app-context";
import { CopilotProvider } from "../copilot/CopilotProvider";
import { setLiveEstateReader } from "../data/live-estate";
import { createSourceClient, type DataSource } from "../data/query-client";
import { QueryClientContext } from "../data/use-query";
import { AuthContext, type AuthContextValue } from "../hooks/auth.context";
import type { AppRuntime } from "../lib/runtime-config";
import { isThemeChoice } from "../theme/fluent";
import { AppThemeProvider } from "../theme/AppThemeProvider";
import { sampleRows } from "./sample-data";
import { sampleLiveReader } from "./sample-live";

import "../styles/app.css";

const ZERO = "00000000-0000-0000-0000-000000000000";
const params = new URLSearchParams(window.location.search);

const runtime: AppRuntime = {
    apiUrl: "https://example.invalid/api",
    publishableKey: "pk-sample",
    workspaceId: ZERO,
    itemId: ZERO,
    portalUrl: "https://app.fabric.microsoft.com",
    resourceGroup: "rg-dbhub-sample",
    expectedAccount: "presenter@contoso.example",
    links: {
        databaseHub: "https://app.fabric.microsoft.com/workloads/fdh/databaseHub",
        realTimeDashboard: "https://app.fabric.microsoft.com/groups/me/kustodashboards/sample",
        report: "https://app.fabric.microsoft.com/groups/me/reports/sample",
        workspace: "https://app.fabric.microsoft.com/groups/me",
        controlNotebook: "https://app.fabric.microsoft.com/groups/me/synapsenotebooks/sample",
    },
};

const empty = params.get("empty") === "1";
setLiveEstateReader(sampleLiveReader({ at: new Date().toISOString(), delayMs: 900, off: params.get("live") === "off" ? "The live estate function isn't deployed in this app." : undefined }));
const sample: DataSource = {
    provenance: "sample",
    answers: () => true,
    fetch: async (spec) => {
        await new Promise((resolve) => setTimeout(resolve, 40));
        return { rows: empty ? [] : sampleRows(spec), requestId: "sample" };
    },
};

const auth = {
    session: { isAuthenticated: true, user: { email: "presenter@contoso.example" } },
    isAuthenticated: true,
    isLoading: false,
    signIn: () => undefined,
    signOut: () => undefined,
    isSigningIn: false,
    signInError: null,
} as unknown as AuthContextValue;

const theme = params.get("theme");
// manage=operator (or on): actions run from the app; manage=viewer: read-only with the reason; manage=running: an operator
// while a session runs; otherwise the copy mode of a deployment without the Manage function.
const manageParam = params.get("manage");
const sampleSend: ManageAccess["send"] = async (request) => ({ started: true, jobInstance: "00000000-0000-0000-0000-000000000000", reason: "", requestedBy: `app/presenter@contoso.example (${request.action})`.split(" ")[0] });
const manage: ManageAccess =
    manageParam === "operator" || manageParam === "on" || manageParam === "running"
        ? { mode: "run", canRun: true, reason: "", who: "presenter@contoso.example", running: manageParam === "running" ? { startedAt: new Date(Date.now() - 25 * 60000).toISOString() } : null, send: sampleSend }
        : manageParam === "viewer"
          ? { mode: "run", canRun: false, reason: "Only the demo's operators send actions from the app: the deployer and the members of its admin group. A redeploy refreshes the list.", who: "viewer@contoso.example", running: null }
          : MANAGE_READ_ONLY;

createRoot(document.getElementById("root")!).render(
    <AppThemeProvider initialChoice={isThemeChoice(theme) ? theme : undefined}>
        <AuthContext.Provider value={auth}>
            <QueryClientContext.Provider value={createSourceClient([sample])}>
                <CopilotProvider initialOpen={params.get("copilot") === "open"}>
                    <App runtime={runtime} provenance="sample" manage={manage} />
                </CopilotProvider>
            </QueryClientContext.Provider>
        </AuthContext.Provider>
    </AppThemeProvider>,
);
