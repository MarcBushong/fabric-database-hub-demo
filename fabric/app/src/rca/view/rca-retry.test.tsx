import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createSourceClient, describeFailure, QueryFailure } from "@/data/query-client";
import { retryClock } from "@/data/retry";
import RcaPage from "@/pages/RcaPage";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { RcaReadError } from "@/rca/loader";
import { renderWithApp, type FakeQueryClient } from "@/test/render";

// The Root cause view when a read fails, also after its retries (live, 2026-11-21: Power BI's Execute Queries answered
// 429 to a fast harness, and one throttled presence check made the view say that no RCA capture was recorded, on a model
// with 643 RCA Sessions rows). Each failure says what failed and offers Try again; none reads as nothing recorded.

const THROTTLED = "You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds.";

// explain_incident fails while `failing.explain` counts down: the report's own failure, apart from the list's.
const failing = vi.hoisted(() => ({ explain: 0 }));
vi.mock("@/rca/client", async (importOriginal) => {
    const actual = await importOriginal<typeof import("@/rca/client")>();
    return {
        ...actual,
        createRcaClient: (...args: Parameters<typeof actual.createRcaClient>) => {
            const client = actual.createRcaClient(...args);
            return {
                ...client,
                tools: async () => {
                    const tools = await client.tools();
                    return {
                        ...tools,
                        investigate: async (...call: Parameters<typeof tools.investigate>) => {
                            if (call[0] === "explain_incident" && failing.explain > 0) {
                                failing.explain -= 1;
                                throw new RcaReadError([{ table: "RCA Sessions", error: new QueryFailure(describeFailure("api", "Service Unavailable"), "api", "503") }]);
                            }
                            return tools.investigate(...call);
                        },
                    };
                },
            };
        },
    };
});

/** The preview's history, throttled as Power BI throttles it while `state.throttled`. */
function historyClient(state: { throttled: boolean }): FakeQueryClient {
    const client = createSourceClient([
        {
            provenance: "sample",
            answers: () => true,
            fetch: async (spec) => {
                if (state.throttled) throw new QueryFailure(describeFailure("api", THROTTLED), "api", "429");
                return { rows: sampleRcaRows(spec) ?? sampleRows(spec), requestId: "sample" };
            },
        },
    ]);
    return Object.assign(client, { ran: [] as string[] });
}

const realClock = { ...retryClock };
beforeEach(() => {
    // The retries' waits pass at once: what they wait for is src/data/retry.test.ts's.
    retryClock.sleep = async () => undefined;
    failing.explain = 0;
});
afterEach(() => {
    cleanup();
    Object.assign(retryClock, realClock);
});

const SLOW = 20000;

describe("the Root cause view when the history can't be read (ADR 0031)", () => {
    it("says the check failed, with its reason, never that no capture is recorded, and checks again on Try again", () => {
        const retryRca = vi.fn();
        const error = `Fabric couldn't run the query: ${THROTTLED} Try again in a minute: Power BI allows each viewer 120 queries a minute.`;
        renderWithApp(<RcaPage />, { rca: null, rcaError: error, retryRca, client: historyClient({ throttled: false }), view: { page: "rca" } });
        expect(screen.getByText("The history couldn't be read")).toBeInTheDocument();
        expect(screen.getByText(error)).toBeInTheDocument();
        expect(screen.queryByText("No RCA capture is recorded yet")).toBeNull();
        fireEvent.click(screen.getByRole("button", { name: "Try again" }));
        expect(retryRca).toHaveBeenCalledTimes(1);
        cleanup();
        // While it checks again, the failure stays, and its button waits.
        renderWithApp(<RcaPage />, { rca: null, rcaError: error, rcaRetrying: true, retryRca, client: historyClient({ throttled: false }), view: { page: "rca" } });
        const waiting = screen.getByRole("button", { name: "Trying again" });
        expect(waiting).toHaveAttribute("aria-disabled", "true");
        fireEvent.click(waiting);
        expect(retryRca).toHaveBeenCalledTimes(1);
    });

    it(
        "says the incidents couldn't load while every read is throttled, with Power BI's reason, and loads them on Try again",
        async () => {
            const state = { throttled: true };
            renderWithApp(<RcaPage />, { rca: true, client: historyClient(state), view: { page: "rca" } });
            expect(await screen.findByText("The incidents couldn't load", {}, { timeout: 10000 })).toBeInTheDocument();
            expect(screen.getByText(/^The history couldn't be read, so nothing is concluded from it \(.*Retry in 60 seconds\.\)\. Try again in a minute: Power BI allows each viewer 120 queries a minute\.$/)).toBeInTheDocument();
            expect(screen.queryByText(/Nothing abnormal in these minutes/)).toBeNull();
            state.throttled = false;
            fireEvent.click(screen.getByRole("button", { name: "Try again" }));
            expect(await screen.findByRole("heading", { name: "Incidents the detector found" }, { timeout: 10000 })).toBeInTheDocument();
            expect(await screen.findAllByRole("tree", {}, { timeout: 10000 })).not.toHaveLength(0);
            expect(screen.queryByText("The incidents couldn't load")).toBeNull();
        },
        SLOW,
    );

    it(
        "says the incident couldn't be explained when its reads fail, and explains it on Try again",
        async () => {
            failing.explain = 1;
            renderWithApp(<RcaPage />, { rca: true, client: historyClient({ throttled: false }), view: { page: "rca" } });
            expect(await screen.findByText("This incident couldn't be explained", {}, { timeout: 10000 })).toBeInTheDocument();
            expect(screen.getByText(/^The history couldn't be read, so nothing is concluded from it \(RCA Sessions: Fabric couldn't run the query: Service Unavailable\)\. Try again in a minute\.$/)).toBeInTheDocument();
            fireEvent.click(screen.getByRole("button", { name: "Try again" }));
            expect(await screen.findAllByRole("tree", {}, { timeout: 10000 })).not.toHaveLength(0);
            await waitFor(() => expect(screen.queryByText("This incident couldn't be explained")).toBeNull());
        },
        SLOW,
    );
});
