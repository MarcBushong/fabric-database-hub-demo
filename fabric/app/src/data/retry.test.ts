import { afterEach, describe, expect, it, vi } from "vitest";

import { QueryFailure } from "./query-client";
import { isMissingInModel, retryClock, retryHint, transientOf, withRetry } from "./retry";

// Power BI's answer past 120 queries a minute (live, 2026-11-21, Final tests on dbhubra at cb224b28), as the history
// source gives it to the app: describeFailure's "api" text, with the HTTP status as the code.
const THROTTLED_TEXT = "You have exceeded the amount of requests allowed in the current time frame and further requests will fail. Retry in 60 seconds.";
const throttled = () => new QueryFailure(`Fabric couldn't run the query: ${THROTTLED_TEXT}`, "api", "429");
const unavailable = () => new QueryFailure("Fabric couldn't run the query: Service Unavailable", "api", "503");
// A model from before the Incident RCA (live, 2026-11-21, Final tests on dbhubrb at b059c91).
const missing = () => new QueryFailure("The model rejected the query: Query (1, 101) Cannot find table '<oii>RCA Sessions</oii>'.", "query", "DatasetExecuteQueriesError");

const realClock = { ...retryClock };
afterEach(() => {
    Object.assign(retryClock, realClock);
});

/** The waits, recorded instead of slept, with no jitter unless a test asks for it. */
function fakeClock(random = 0) {
    const waits: number[] = [];
    retryClock.sleep = async (ms) => {
        waits.push(ms);
    };
    retryClock.random = () => random;
    return waits;
}

describe("which failures are worth trying again", () => {
    it("a 429, by its code or its text, with the wait Power BI asks for", () => {
        expect(transientOf(throttled())).toEqual({ kind: "throttled", retryAfterMs: 60_000 });
        expect(transientOf(new Error(`Execute Queries 429: {"message":"${THROTTLED_TEXT}"}`))).toEqual({ kind: "throttled", retryAfterMs: 60_000 });
        expect(transientOf(new QueryFailure("Fabric couldn't run the query: Too Many Requests", "api", "429"))).toEqual({ kind: "throttled", retryAfterMs: null });
    });

    it("a 5xx, by its code or its text, and a connection that failed", () => {
        expect(transientOf(unavailable())?.kind).toBe("server");
        expect(transientOf(new Error("HTTP 502 Bad Gateway"))?.kind).toBe("server");
        expect(transientOf(new QueryFailure("The app couldn't reach Fabric. Check the connection and try again.", "network"))?.kind).toBe("network");
    });

    it("not a refusal, a query the model rejected, or a table it doesn't have", () => {
        expect(transientOf(new QueryFailure("Fabric refused the query for this account.", "api", "403"))).toBeNull();
        expect(transientOf(new QueryFailure("The model rejected the query: syntax error", "query"))).toBeNull();
        expect(transientOf(missing())).toBeNull();
    });

    it("takes a table or a column the model doesn't have for missing, in the engine's wordings, and a failed read never", () => {
        expect(isMissingInModel(missing())).toBe(true);
        expect(isMissingInModel(new Error("Query (1, 25) Failed to resolve name 'RCA Coverage'. It is not a valid table, variable, or function name."))).toBe(true);
        expect(isMissingInModel(new Error("Column '<oii>Window End UTC</oii>' in table '<oii>RCA Coverage</oii>' cannot be found or may not be used in this expression."))).toBe(true);
        expect(isMissingInModel(throttled())).toBe(false);
        expect(isMissingInModel(unavailable())).toBe(false);
        expect(isMissingInModel(new QueryFailure("Fabric refused the query for this account.", "api", "403"))).toBe(false);
        // A failure that passes by itself is never taken for a missing table, whatever else its text says.
        expect(isMissingInModel(new QueryFailure("Cannot find table 'RCA Coverage': Service Unavailable", "api", "503"))).toBe(false);
    });

    it("says to try again in a minute only when each failure passes by itself, and why when Power BI throttled one", () => {
        expect(retryHint([throttled(), unavailable()])).toBe("Try again in a minute: Power BI allows each viewer 120 queries a minute.");
        expect(retryHint([unavailable()])).toBe("Try again in a minute.");
        expect(retryHint([throttled(), new QueryFailure("The model rejected the query: syntax error", "query")])).toBe("");
        expect(retryHint([])).toBe("");
    });
});

describe("trying a read again", () => {
    it("waits what a 429 asks for, then answers", async () => {
        const waits = fakeClock();
        const read = vi.fn<() => Promise<string>>().mockRejectedValueOnce(throttled()).mockResolvedValueOnce("rows");
        await expect(withRetry(read)).resolves.toBe("rows");
        expect(read).toHaveBeenCalledTimes(2);
        expect(waits).toEqual([60_000]);
    });

    it("backs off a 5xx, doubling each wait, with up to a second of jitter", async () => {
        const waits = fakeClock();
        const read = vi.fn<() => Promise<string>>().mockRejectedValueOnce(unavailable()).mockRejectedValueOnce(unavailable()).mockRejectedValueOnce(unavailable()).mockResolvedValueOnce("rows");
        await expect(withRetry(read)).resolves.toBe("rows");
        expect(waits).toEqual([1000, 2000, 4000]);
        const jittered = fakeClock(0.5);
        await expect(withRetry(vi.fn<() => Promise<string>>().mockRejectedValueOnce(unavailable()).mockResolvedValueOnce("rows"))).resolves.toBe("rows");
        expect(jittered).toEqual([1500]);
    });

    it("gives up with the last failure once the next wait would pass the budget, and never waits past the cap", async () => {
        const waits = fakeClock();
        const read = vi.fn(async (): Promise<string> => {
            throw throttled();
        });
        await expect(withRetry(read)).rejects.toThrow(/Retry in 60 seconds/);
        // 60 seconds, then another 60 would pass the 90-second budget.
        expect(read).toHaveBeenCalledTimes(2);
        expect(waits).toEqual([60_000]);
        const longer = fakeClock();
        const asked = vi.fn(async (): Promise<string> => {
            throw new QueryFailure("Fabric couldn't run the query: Retry in 600 seconds.", "api", "429");
        });
        await expect(withRetry(asked, { budgetMs: 200_000 })).rejects.toThrow(/600 seconds/);
        expect(asked).toHaveBeenCalledTimes(4);
        expect(longer).toEqual([60_000, 60_000, 60_000]);
    });

    it("fails at once on a failure that waiting won't pass", async () => {
        const waits = fakeClock();
        const failure = missing();
        const read = vi.fn(async (): Promise<string> => {
            throw failure;
        });
        await expect(withRetry(read)).rejects.toBe(failure);
        expect(read).toHaveBeenCalledTimes(1);
        expect(waits).toEqual([]);
    });
});
