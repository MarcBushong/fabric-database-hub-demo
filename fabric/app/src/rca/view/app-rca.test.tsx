import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import App from "@/App";
import { CopilotProvider } from "@/copilot/CopilotProvider";
import { createSourceClient, describeFailure, QueryFailure, type DataSource } from "@/data/query-client";
import { retryClock } from "@/data/retry";
import { QueryClientContext } from "@/data/use-query";
import { AuthContext, type AuthContextValue } from "@/hooks/auth.context";
import type { AppRuntime } from "@/lib/runtime-config";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { AppThemeProvider } from "@/theme/AppThemeProvider";

// The review of 34a9732's test gap: the whole app, without the Incident RCA's tables and with them (ADR 0031's upgrade
// matrix): the presence check, the navigation, and the Root cause address; and a check that a throttled or failed read
// interrupted.

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

/** The app on the preview's sample history, with or without the RCA tables in the model, at an address; the presence
 *  check fails with each of `presenceFailures` first, in order. */
function renderApp(hash: string, rcaTables: boolean, presenceFailures: Error[] = []) {
    window.location.hash = hash;
    const fetch = vi.fn<DataSource["fetch"]>(async (spec) => {
        if (spec.id === "rca-presence") {
            const failure = presenceFailures.shift();
            if (failure) throw failure;
            // Without the tables, Execute Queries refuses the presence query (live, 2026-11-21, on a model from before the
            // Incident RCA), as the history source reports it.
            if (!rcaTables) throw new QueryFailure(describeFailure("api", "Query (1, 32) Cannot find table '<oii>RCA Coverage</oii>'."), "api", "400");
        }
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

// Power BI's answers to a fast reader (live, 2026-11-21, Final tests on dbhubra at cb224b28), as the history source
// reports them. The retries' waits pass at once here: what they wait for is src/data/retry.test.ts's.
const throttled = () => new QueryFailure(describeFailure("api", "You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds."), "api", "429");
const unavailable = () => new QueryFailure(describeFailure("api", "Service Unavailable"), "api", "503");
const realClock = { ...retryClock };
beforeEach(() => {
    retryClock.sleep = async () => undefined;
});

afterEach(() => {
    cleanup();
    window.location.hash = "";
    Object.assign(retryClock, realClock);
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

    // Live, 2026-11-21: one throttled check made Root cause say that no RCA capture was recorded, on a model with 643 RCA
    // Sessions rows, until a reload.
    it("waits out a check that a 5xx and then a 429 failed, and shows the incidents, never that no capture is recorded", async () => {
        const fetch = renderApp("#/rca", true, [unavailable(), throttled()]);
        expect(await screen.findByRole("heading", { name: "Incidents the detector found" }, { timeout: 10000 })).toBeInTheDocument();
        expect(fetch.mock.calls.filter(([spec]) => spec.id === "rca-presence")).toHaveLength(3);
        expect(screen.queryByText("No RCA capture is recorded yet")).toBeNull();
        expect(within(screen.getByRole("navigation", { name: "Pages" })).getByRole("button", { name: /Root cause/ })).toBeInTheDocument();
    }, 20000);

    it("says the history couldn't be read when the check stays throttled, keeps Root cause reachable, and finds the tables on Try again", async () => {
        const fetch = renderApp("#/rca", true, [throttled(), throttled()]);
        expect(await screen.findByText("The history couldn't be read", {}, { timeout: 10000 })).toBeInTheDocument();
        expect(screen.getByText(/Retry in 60 seconds\. Try again in a minute: Power BI allows each viewer 120 queries a minute\.$/)).toBeInTheDocument();
        expect(screen.queryByText("No RCA capture is recorded yet")).toBeNull();
        const nav = screen.getByRole("navigation", { name: "Pages" });
        expect(within(nav).getByRole("button", { name: /Root cause/ })).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Try again" }));
        expect(await screen.findByRole("heading", { name: "Incidents the detector found" }, { timeout: 10000 })).toBeInTheDocument();
        expect(fetch.mock.calls.filter(([spec]) => spec.id === "rca-presence")).toHaveLength(3);
        expect(screen.queryByText("The history couldn't be read")).toBeNull();
        expect(within(nav).getByRole("button", { name: /Root cause/ })).toBeInTheDocument();
    }, 20000);
});
