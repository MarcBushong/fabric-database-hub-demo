import { describe, expect, it, vi } from "vitest";

import { probeQuery } from "./queries";
import { createQueryClient, describeFailure, normalizeColumnName, QueryFailure, type ConnectorResult } from "./query-client";

const success = (rows: unknown[][] = [[12, 2293, 4]]): ConnectorResult => ({
    status: "success",
    requestId: "req-1",
    table: {
        columns: [
            { name: "[ValidationRows]", dataType: "Int64" },
            { name: "[SnapshotRows]", dataType: "Int64" },
            { name: "[Incidents]", dataType: "Int64" },
        ],
        rows,
    },
});

describe("query client", () => {
    it("normalizes Table[Column] and [Alias] names", () => {
        expect(normalizeColumnName("Target[Target Key]")).toBe("Target Key");
        expect(normalizeColumnName("[CpuAvg]")).toBe("CpuAvg");
        expect(normalizeColumnName("Plain")).toBe("Plain");
    });

    it("maps rows to objects and sends the row bound", async () => {
        const execute = vi.fn(async () => success());
        const client = createQueryClient(execute);
        const result = await client.run(probeQuery());
        expect(result.rows).toEqual([{ ValidationRows: 12, SnapshotRows: 2293, Incidents: 4 }]);
        expect(execute).toHaveBeenCalledWith({ query: probeQuery().dax, resultSetRowCountLimit: 1 });
    });

    it("serves repeats from the cache and shares a request in flight", async () => {
        const execute = vi.fn(async () => success());
        const client = createQueryClient(execute);
        await Promise.all([client.run(probeQuery()), client.run(probeQuery())]);
        await client.run(probeQuery());
        expect(execute).toHaveBeenCalledTimes(1);
        await client.run(probeQuery(), { force: true });
        expect(execute).toHaveBeenCalledTimes(2);
    });

    it("expires entries after the TTL and evicts the least recently used", async () => {
        let now = 0;
        const execute = vi.fn(async () => success());
        const client = createQueryClient(execute, { ttlMs: 1000, maxEntries: 2, now: () => now });
        const a = { ...probeQuery(), id: "a" };
        const b = { ...probeQuery(), id: "b" };
        const c = { ...probeQuery(), id: "c" };
        await client.run(a);
        now = 2000;
        expect(client.peek(a)).toBeUndefined();
        await client.run(a);
        await client.run(b);
        client.peek(a);
        await client.run(c);
        expect(client.peek(a)).toBeDefined();
        expect(client.peek(b)).toBeUndefined();
        expect(client.peek(c)).toBeDefined();
    });

    it("turns connector errors into plain-language failures and caches nothing", async () => {
        const execute = vi.fn(
            async (): Promise<ConnectorResult> => ({ status: "error", requestId: "req-2", error: { category: "overflow", message: "too many rows", code: "x" } }),
        );
        const client = createQueryClient(execute);
        const failure = await client.run(probeQuery()).catch((e: unknown) => e);
        expect(failure).toBeInstanceOf(QueryFailure);
        expect((failure as QueryFailure).message).toMatch(/more rows than the app allows/);
        expect((failure as QueryFailure).requestId).toBe("req-2");
        expect(client.peek(probeQuery())).toBeUndefined();
    });

    it("explains permission failures with the model's name", () => {
        expect(describeFailure("api", "403 Forbidden")).toMatch(/Build and Read on SM_DatabaseHub_History/);
        expect(describeFailure("query", "bad column")).toBe("The model rejected the query: bad column");
        expect(describeFailure("network", "")).toMatch(/couldn't reach Fabric/);
    });
});
