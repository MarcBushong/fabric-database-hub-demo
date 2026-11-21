import { afterEach, describe, expect, it, vi, type Mock } from "vitest";

import { createInvestigations } from "@/copilot/investigations";
import { createQueryClient, type ConnectorResult, type Execute } from "@/data/query-client";
import { retryClock } from "@/data/retry";
import { checkRcaTables, createRcaClient, NEWEST_BIN_DAX } from "./client";
import { RCA_PRESENCE_DAX, RcaReadError } from "./loader";

// The connector's answers, as the deployed app gets them (live, 2026-11-21): Power BI's 429 past 120 queries a minute
// (Final tests on dbhubra at cb224b28), and Execute Queries' 400 on a model from before the Incident RCA (on dbhubrb at
// b059c91).
const THROTTLED: ConnectorResult = {
    status: "error",
    error: { category: "api", message: "You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds.", code: "429" },
    requestId: "r-429",
};
const UNAVAILABLE: ConnectorResult = { status: "error", error: { category: "api", message: "Service Unavailable", code: "503" }, requestId: "r-503" };
const NO_RCA: ConnectorResult = { status: "error", error: { category: "query", message: "Query (1, 32) Cannot find table '<oii>RCA Coverage</oii>'.", code: "DatasetExecuteQueriesError" }, requestId: "r-400" };
const NEWEST: ConnectorResult = { status: "success", table: { columns: [{ name: "[Newest]", dataType: "dateTime" }], rows: [["2026-11-20T17:20:00"]] }, requestId: "r-newest" };
const EMPTY: ConnectorResult = { status: "success", table: { columns: [], rows: [] }, requestId: "r-empty" };
const ONE: ConnectorResult = { status: "success", table: { columns: [{ name: "[Rows]", dataType: "int64" }], rows: [[643]] }, requestId: "r-one" };

const realClock = { ...retryClock };
let waits: number[] = [];
afterEach(() => {
    Object.assign(retryClock, realClock);
});
function fakeClock() {
    waits = [];
    retryClock.sleep = async (ms) => {
        waits.push(ms);
    };
    retryClock.random = () => 0;
}

const presence = (execute: Mock<Execute>) => execute.mock.calls.filter(([input]) => input.query === RCA_PRESENCE_DAX).length;

describe("whether the history model has the RCA tables", () => {
    it("is present when the presence query answers", async () => {
        const execute = vi.fn<Execute>(async () => ONE);
        expect(await checkRcaTables(createQueryClient(execute))).toEqual({ state: "present" });
    });

    it("is absent only when the model says it doesn't have RCA Coverage, asked once", async () => {
        fakeClock();
        const execute = vi.fn<Execute>(async () => NO_RCA);
        expect(await checkRcaTables(createQueryClient(execute))).toEqual({ state: "absent" });
        expect(presence(execute)).toBe(1);
        expect(waits).toEqual([]);
    });

    // Live, 2026-11-21: one throttled check made Root cause say that no RCA capture was recorded, on a model with 643 RCA
    // Sessions rows.
    it("waits out a 429 as Power BI asks, and then has the answer", async () => {
        fakeClock();
        const execute = vi.fn<Execute>().mockResolvedValueOnce(THROTTLED).mockResolvedValue(ONE);
        expect(await checkRcaTables(createQueryClient(execute))).toEqual({ state: "present" });
        expect(presence(execute)).toBe(2);
        expect(waits).toEqual([60_000]);
    });

    it("tries a 5xx again after a short backoff", async () => {
        fakeClock();
        const execute = vi.fn<Execute>().mockResolvedValueOnce(UNAVAILABLE).mockResolvedValue(ONE);
        expect(await checkRcaTables(createQueryClient(execute))).toEqual({ state: "present" });
        expect(waits).toEqual([1000]);
    });

    it("has failed, never absent, when the 429s outlast the retries, and says why and when to try again", async () => {
        fakeClock();
        const execute = vi.fn<Execute>(async () => THROTTLED);
        const check = await checkRcaTables(createQueryClient(execute));
        expect(check.state).toBe("failed");
        expect(check.state === "failed" ? check.error : "").toBe(
            "Fabric couldn't run the query: You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds. Try again in a minute: Power BI allows each viewer 120 queries a minute.",
        );
        expect(presence(execute)).toBe(2);
    });

    it("has failed, never absent, on a 5xx that lasts, after backing off within the budget", async () => {
        fakeClock();
        const execute = vi.fn<Execute>(async () => UNAVAILABLE);
        expect(await checkRcaTables(createQueryClient(execute))).toEqual({ state: "failed", error: "Fabric couldn't run the query: Service Unavailable Try again in a minute." });
        expect(waits).toEqual([1000, 2000, 4000]);
    });
});

describe("the RCA client's reads", () => {
    /** The history's newest time answers once `newest` says so; every other read is throttled. */
    function history(state: { newest: boolean }) {
        return vi.fn<Execute>(async ({ query }) => (query === NEWEST_BIN_DAX && state.newest ? NEWEST : THROTTLED));
    }

    it("doesn't keep a failed read of the newest time, which never reads as an empty history: the next call asks again", async () => {
        fakeClock();
        const state = { newest: false };
        const rca = createRcaClient(createQueryClient(history(state)), { timeZone: "UTC" });
        const first = rca.latest();
        await expect(first).rejects.toBeInstanceOf(RcaReadError);
        await expect(first).rejects.toThrow(/^The history couldn't be read, so nothing is concluded from it \(Telemetry Snapshots \(its newest time\): .*Retry in 60 seconds\.\)\. Try again in a minute/);
        state.newest = true;
        await expect(rca.latest()).resolves.toEqual(new Date("2026-11-20T17:20:00Z"));
    });

    it("builds no investigations on a made-up day while the newest time can't be read, and builds them once it can", async () => {
        fakeClock();
        const state = { newest: false };
        const rca = createRcaClient(createQueryClient(history(state)), { timeZone: "UTC" });
        await expect(rca.tools()).rejects.toBeInstanceOf(RcaReadError);
        state.newest = true;
        await expect(rca.tools()).resolves.toHaveProperty("investigate");
    });

    it("answers a throttled investigation as unread, for the view and for Copilot, never as a quiet window", async () => {
        fakeClock();
        const rca = createRcaClient(createQueryClient(history({ newest: true })), { timeZone: "UTC" });
        const tools = await rca.tools();
        const window = { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:20:00Z", targets: ["T1"] };
        await expect(tools.investigate("find_incidents", window)).rejects.toBeInstanceOf(RcaReadError);
        for (const name of ["find_incidents", "triage_window", "explain_locking", "explain_errors"]) {
            const answer = await tools.run(name, window);
            expect(answer.ok, name).toBe(false);
            expect(answer.text, name).toMatch(/^The history couldn't be read, so nothing is concluded from it \(.*Retry in 60 seconds.*\)\. Try again in a minute: Power BI allows each viewer 120 queries a minute\.$/);
            expect(answer.text, name).not.toMatch(/nothing (?:was )?abnormal|not captured/i);
        }
    });

    it("gives Copilot's tool call an answer when even the newest time can't be read, never a rejection that leaves it waiting", async () => {
        fakeClock();
        const investigations = createInvestigations(createQueryClient(history({ newest: false })), { timeZone: "UTC" });
        const answer = await investigations.run("triage_window", { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:20:00Z" });
        expect(answer.ok).toBe(false);
        expect(answer.text).toMatch(/^The history couldn't be read, so nothing is concluded from it \(Telemetry Snapshots \(its newest time\)/);
    });

    it("reads a model without one of the RCA tables as before: that table empty, the rest read", async () => {
        const noReplica: ConnectorResult = { ...NO_RCA, error: { ...NO_RCA.error, message: "Query (1, 101) Cannot find table '<oii>RCA Replica</oii>'." } } as ConnectorResult;
        const execute = vi.fn<Execute>(async ({ query }) => (query === NEWEST_BIN_DAX ? NEWEST : query.includes("'RCA Replica'") ? noReplica : EMPTY));
        const rca = createRcaClient(createQueryClient(execute), { timeZone: "UTC" });
        const tools = await rca.tools();
        const answer = await tools.run("triage_window", { from: "2026-11-20T17:00:00Z", to: "2026-11-20T17:20:00Z", targets: ["T4-replica"] });
        expect(answer.ok).toBe(true);
        expect(answer.text).not.toMatch(/couldn't be read/);
        expect(execute.mock.calls.some(([input]) => input.query.includes("'RCA Replica'"))).toBe(true);
    });
});
