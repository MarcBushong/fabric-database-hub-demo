import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import App from "@/App";
import { CopilotProvider } from "@/copilot/CopilotProvider";
import { createSourceClient, type DataSource } from "@/data/query-client";
import { QueryClientContext } from "@/data/use-query";
import { AuthContext, type AuthContextValue } from "@/hooks/auth.context";
import type { AppRuntime } from "@/lib/runtime-config";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { AppThemeProvider } from "@/theme/AppThemeProvider";

// The review of 34a9732's test gap: the whole app, without the Incident RCA's tables and with them (ADR 0031's upgrade
// matrix): the presence check, the navigation, and the Root cause address.

const ZERO = "00000000-0000-0000-0000-000000000000";
const runtime: AppRuntime = {
    apiUrl: "https://example.invalid/api",
    publishableKey: "pk-sample",
    workspaceId: ZERO,
    itemId: ZERO,
    portalUrl: "https://app.fabric.microsoft.com",
    resourceGroup: "rg-dbhub-sample",
    expectedAccount: "presenter@contoso.example",
    links: {},
} as AppRuntime;

const auth = {
    session: { isAuthenticated: true, user: { email: "presenter@contoso.example" } },
    isAuthenticated: true,
    isLoading: false,
    signIn: () => undefined,
    signOut: () => undefined,
    isSigningIn: false,
    signInError: null,
} as unknown as AuthContextValue;

/** The app on the preview's sample history, with or without the RCA tables in the model, at an address. */
function renderApp(hash: string, rcaTables: boolean) {
    window.location.hash = hash;
    const fetch = vi.fn<DataSource["fetch"]>(async (spec) => {
        // Without the tables, the model refuses the presence query, as Direct Lake does for a table it doesn't have.
        if (!rcaTables && spec.id === "rca-presence") throw new Error("The table 'RCA Coverage' cannot be found.");
        return { rows: (rcaTables ? sampleRcaRows(spec) : null) ?? sampleRows(spec), requestId: "sample" };
    });
    const client = createSourceClient([{ provenance: "sample", answers: () => true, fetch }]);
    render(
        <AppThemeProvider initialChoice="light">
            <AuthContext.Provider value={auth}>
                <QueryClientContext.Provider value={client}>
                    <CopilotProvider>
                        <App runtime={runtime} provenance="sample" />
                    </CopilotProvider>
                </QueryClientContext.Provider>
            </AuthContext.Provider>
        </AppThemeProvider>,
    );
    return fetch;
}

afterEach(() => {
    cleanup();
    window.location.hash = "";
});

describe("the app with and without the Incident RCA's tables (ADR 0031)", () => {
    it("without them, asks once, leaves Root cause out of the navigation, and its address says no capture is recorded", async () => {
        const fetch = renderApp("#/rca", false);
        expect(await screen.findByText("No RCA capture is recorded yet", {}, { timeout: 10000 })).toBeInTheDocument();
        expect(fetch.mock.calls.filter(([spec]) => spec.id === "rca-presence")).toHaveLength(1);
        // No RCA table is queried past the presence check.
        expect(fetch.mock.calls.some(([spec]) => /'RCA /.test(spec.dax) && spec.id !== "rca-presence")).toBe(false);
        const nav = screen.getByRole("navigation", { name: "Pages" });
        expect(within(nav).getByRole("button", { name: /Overview/ })).toBeInTheDocument();
        expect(within(nav).queryByRole("button", { name: /Root cause/ })).toBeNull();
    }, 20000);

    it("with them, offers Root cause in the navigation", async () => {
        const fetch = renderApp("#/overview", true);
        const nav = await screen.findByRole("navigation", { name: "Pages" }, { timeout: 10000 });
        expect(await within(nav).findByRole("button", { name: /Root cause/ }, { timeout: 10000 })).toBeInTheDocument();
        await waitFor(() => expect(fetch.mock.calls.filter(([spec]) => spec.id === "rca-presence")).toHaveLength(1));
    }, 20000);
});
