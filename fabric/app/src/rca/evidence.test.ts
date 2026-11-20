import { describe, expect, it, vi } from "vitest";
import { decodeEvidence, EvidenceFormatError } from "./evidence";
import { loadEvidence, rcaDax, RCA_PRESENCE_DAX, type DaxLog } from "./loader";
import { RCA_SPEC, PHASE_1_TABLES, type RcaTableKey } from "./spec";
import { fixtureEvidence, FIXTURES, namesAScenario, readContract } from "./testdata/contract";
import type { Evidence } from "./types";

const at = (hms: string) => new Date(`2026-11-20T${hms}Z`);

describe("the evidence documents (the contract's fixtures)", () => {
    it("reads T1's chain: the samples, the head blocker, the escalations, the lock timeouts, and the capture's episode", () => {
        const e = fixtureEvidence("t1");
        expect(e.sessions).toHaveLength(280);
        // A blocking sample is a capture time with at least one waiter: RCA-SQL-01 returns only sessions in a blocking edge.
        const times = [...new Set(e.sessions.map((s) => s.capturedAt.getTime()))].sort((a, b) => a - b);
        expect(times).toHaveLength(38);
        for (const t of times) expect(e.sessions.some((s) => s.capturedAt.getTime() === t && s.blockedBy.length > 0)).toBe(true);
        expect(new Date(times[0])).toEqual(at("16:52:30"));
        expect(new Date(times[times.length - 1])).toEqual(at("17:00:40"));
        const head = e.sessions.filter((s) => s.session === 63);
        expect(Math.max(...head.map((s) => s.idleMs ?? 0))).toBe(79_000);
        expect(head[0]).toMatchObject({ status: "sleeping", openTransactions: 1, login: "NT AUTHORITY\\SYSTEM", host: "SQLVM01", program: "ContosoCare.Demo", isDemo: true });
        expect(e.sessions.find((s) => s.session === 64)?.blockedBy).toEqual([63]);
        expect(e.events.filter((x) => x.kind === "escalation").map((x) => x.at.toISOString().slice(11, 19))).toEqual(["16:52:20", "16:54:20", "16:56:20", "16:58:20"]);
        const timeouts = e.events.filter((x) => x.kind === "error" && x.code === "1222");
        expect(timeouts.reduce((n, x) => n + x.count, 0)).toBe(30);
        expect(timeouts.every((x) => x.intercepted === true && x.severity === 16)).toBe(true);
        expect(e.events.filter((x) => x.kind === "capture").map((x) => [x.name, x.code, x.at])).toEqual([
            ["escalated", "T1-20261120T165230Z", at("16:52:30")],
            ["relaxed", "T1-20261120T165230Z", at("17:01:40")],
        ]);
        expect(e.coverage).toEqual([expect.objectContaining({ target: "T1", captured: true, gaps: [] })]);
        expect(e.coverage[0].sources).toContain("RCA-XE-01");
    });

    it("reads T4's replica: the stall's conflict, its holder, the peak, and that nothing was cancelled", () => {
        const e = fixtureEvidence("t4");
        const replica = e.replica.filter((r) => r.side === "replica");
        const peak = replica.reduce((best, r) => ((r.sinceLastReplayS ?? 0) > (best.sinceLastReplayS ?? 0) ? r : best));
        expect(peak).toMatchObject({ sinceLastReplayS: 175.4, receivedNotReplayedBytes: 178_500, conflictRelation: "demo.replica_lag_marks", conflictHolder: 41872, conflictHolderMode: "AccessShareLock", conflictWantedMode: "AccessExclusiveLock" });
        expect(peak.at).toEqual(at("17:14:10"));
        expect(peak.conflictWaitStart).toEqual(at("17:11:15"));
        expect(Math.max(...replica.map((r) => r.conflictsCancelled ?? 0))).toBe(0);
        const primary = e.replica.filter((r) => r.side === "primary");
        expect(Math.max(...primary.map((r) => r.writeLagS ?? 0))).toBeLessThanOrEqual(0.001);
        expect(Math.max(...primary.map((r) => r.flushLagS ?? 0))).toBeLessThanOrEqual(0.002);
    });

    it("keeps the decoded evidence blind: no scenario named anywhere in it", () => {
        const e = fixtureEvidence("t1", "t4");
        expect(namesAScenario(JSON.stringify(e))).toEqual([]);
    });

    it("refuses a document of another kind or version, rather than guess", () => {
        const doc = readContract<Record<string, unknown>>(FIXTURES.t1);
        expect(() => decodeEvidence({ ...doc, version: 2 })).toThrow(EvidenceFormatError);
        expect(() => decodeEvidence({ hello: "world" })).toThrow(EvidenceFormatError);
    });
});

/** A fixture's rows as DAX returns them: keyed by the model's columns, times as zoneless text. */
function asModelRows(evidence: Evidence, key: RcaTableKey): Array<Record<string, unknown>> {
    const fields = RCA_SPEC[key].fields as Record<string, { model: string; kind: string }>;
    return (evidence[key] as unknown as Array<Record<string, unknown>>).map((row) => {
        const out: Record<string, unknown> = {};
        for (const [name, field] of Object.entries(fields)) {
            let value = row[name];
            if (value instanceof Date) value = value.toISOString().replace("Z", "");
            if (name === "blockedBy") value = (value as number[]).length ? (value as number[]).join(",") : null;
            if (name === "sources") value = (value as string[]).join(",");
            if (name === "gaps") value = (value as string[]).join("\n") || null;
            out[field.model] = value ?? null;
        }
        return out;
    });
}

describe("the DAX loader", () => {
    it("asks one bounded query per table for the window and the targets, oldest first", () => {
        const dax = rcaDax("sessions", at("16:50:00"), at("17:05:00"), ["T1", "T3"]);
        expect(dax).toContain("'RCA Sessions'[Captured At UTC] >= DATE ( 2026, 11, 20 ) + TIME ( 16, 50, 0 )");
        expect(dax).toContain("'RCA Sessions'[Captured At UTC] <= DATE ( 2026, 11, 20 ) + TIME ( 17, 5, 0 )");
        expect(dax).toContain(`TREATAS ( { "T1", "T3" }, 'Target'[Target Key] )`);
        expect(dax).toMatch(/ORDER BY 'RCA Sessions'\[Captured At UTC\]$/);
        expect(RCA_PRESENCE_DAX).toContain("'RCA Coverage'");
    });

    it("reads the same evidence through DAX as from the documents", async () => {
        const expected = fixtureEvidence("t1", "t4");
        const runDax = vi.fn(async (query: string) => {
            const key = PHASE_1_TABLES.find((k) => query.includes(`'${RCA_SPEC[k].model}',`));
            return key ? asModelRows(expected, key) : [];
        });
        const got = await loadEvidence(runDax, at("16:50:00"), at("17:20:00"), ["T1", "T4", "T4-replica"]);
        expect(runDax).toHaveBeenCalledTimes(PHASE_1_TABLES.length);
        expect(got.sessions).toEqual(expected.sessions);
        expect(got.events).toEqual(expected.events);
        expect(got.resource).toEqual(expected.resource);
        expect(got.replica).toEqual(expected.replica);
        expect(got.coverage).toEqual(expected.coverage);
    });

    it("leaves a failing table empty and says so, and reads the others", async () => {
        const logs: DaxLog[] = [];
        const runDax = async (query: string) => {
            if (query.includes("'RCA Replica',")) throw new Error("The model rejected the query.");
            return [];
        };
        const got = await loadEvidence(runDax, at("17:00:00"), at("17:20:00"), ["T4-replica"], { onDax: (l) => logs.push(l) });
        expect(got.replica).toEqual([]);
        expect(logs.find((l) => l.table === "RCA Replica")?.error).toMatch(/rejected/);
        expect(logs.filter((l) => !l.error)).toHaveLength(PHASE_1_TABLES.length - 1);
    });

    it("never queries the answer key (rca/blind-detection.json)", async () => {
        const blind = readContract<{ answerKey: { modelTables: string[] } }>("blind-detection.json");
        const queries: string[] = [];
        await loadEvidence(async (q) => (queries.push(q), []), at("16:00:00"), at("17:00:00"), ["T1", "T2", "T3", "T4", "T4-replica", "T5"], { tables: Object.keys(RCA_SPEC) as RcaTableKey[] });
        for (const q of queries) for (const table of blind.answerKey.modelTables) expect(q).not.toContain(table);
    });
});
