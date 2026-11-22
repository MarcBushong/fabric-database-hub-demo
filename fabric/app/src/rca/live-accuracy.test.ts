import { describe, expect, it } from "vitest";

import { LIVE_KEYS, live, liveSources } from "./testdata/live-rb-2233e0ae";
import { createInvestigationTools } from "./tools";
import type { InvestigationResult } from "./types";

// Final tests' two live findings at 94a17ff7 (dbhubrb, session 2233e0ae, 2026-11-21), on that session's rows
// (testdata/live-rb-2233e0ae.ts: rebuilt from the live answers, and 94a17ff7's code gives those answers on them word for
// word). Finding 1: the RCA view explained the replica's first stall as slow replay at 16:15, from Azure Monitor's
// 5-minute intervals, while the chat's explain_replica_lag, asked at 16:17:12, found the replay conflict. Finding 2: the
// connection surge's report had no cause, no finding, and "see what wasn't captured below" with nothing below.

const tools = () => createInvestigationTools({ ...liveSources(), timeZone: "America/New_York", latestDay: live("00:00:00"), latest: live("21:33:15") });

async function ask(name: string, args: Record<string, unknown>): Promise<InvestigationResult> {
    const r = await tools().investigate(name, args);
    if (typeof r === "string") throw new Error(r);
    return r;
}

const part = (r: InvestigationResult, tool: string) => (r.details?.parts as Array<{ tool: string; details: Record<string, unknown> }>).find((p) => p.tool === tool)?.details;

describe("the replica's lag (finding 1)", () => {
    it("explains the first stall from its own minutes: replay stood still behind session 5883's lock, as the capture's samples tell it", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaFirst });
        expect(r.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-REPLAY-CONFLICT"] });
        expect(r.rootCause?.statement).toMatch(
            /^The replica's time since its last replay rose from 16:16:42 to 176\.7 s at 16:19:17 UTC \(21\.4 s, 96\.4 s, 156\.4 s, 176\.7 s\), counting from its last replay at 16:16:20 UTC, and was back to 0\.9 s at 16:19:33 UTC; it grew 1 s per second: replay stood still\. /,
        );
        for (const fact of [
            "waited for AccessExclusiveLock on demo.replica_lag_marks from 16:16:21 UTC",
            "(AccessShareLock; session 5883, ContosoCare.Demo: SELECT r.marks_seen",
            "578598600 bytes received but not replayed",
            "write and flush lag at most 7.132 s",
            "WAL about 548651 bytes/s",
            "the query ended before that, so nothing was cancelled",
        ]) {
            expect(r.rootCause?.statement).toContain(fact);
        }
        // Database Hub's chart, cited beside the samples: Azure Monitor's 5-minute interval that holds the stall.
        expect(r.rootCause?.evidence.map((e) => e.text)).toContain("Read Replica Lag 178 s, its highest from 16:15 to 16:20 UTC");
        // The timeline is the capture's own samples, from before the stall to its recovery, not two 5-minute intervals.
        const lag = part(r, "explain_replica_lag")?.lag as Array<{ at: string; seconds: number; source: string }>;
        expect(lag[0]).toMatchObject({ at: "2026-11-21T16:16:12Z", seconds: 0.4 });
        expect(lag[lag.length - 1]).toMatchObject({ at: "2026-11-21T16:19:33Z", seconds: 0.9 });
        expect(lag.length).toBeGreaterThan(20);
        expect(lag.every((p) => p.source === "RCA Replica")).toBe(true);
        expect(r.recommendations.map((x) => x.id)).toEqual(["RPL-SHORT-REPORTS", "RPL-STANDBY-DELAY", "RPL-NO-EXCLUSIVE"]);
    });

    it.each([
        ["the harness's live call", { at: "2026-11-21T16:17:12Z", minutesBefore: 5, minutesAfter: 15 }],
        ["the stall's escalation", { at: "2026-11-21T16:17:12Z" }],
        ["a local time in it", { at: "11:18" }],
        ["its peak", { at: "2026-11-21T16:19:17Z" }],
        ["a window that cuts off its start", { at: "2026-11-21T16:19:30Z", minutesBefore: 1, minutesAfter: 1 }],
    ])("gives the chat the RCA view's finding when asked at %s", async (_, args) => {
        const view = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaFirst });
        const chat = await ask("explain_replica_lag", args);
        expect(chat.rootCause).toEqual(view.rootCause);
        expect(chat.findings).toEqual(view.findings);
    });

    it("explains the second stall as its own, behind its own holder", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.replicaSecond });
        expect(r.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-REPLAY-CONFLICT"] });
        expect(r.rootCause?.statement).toMatch(/^The replica's time since its last replay rose from 16:21:12 to 177\.7 s at 16:23:47 UTC .*counting from its last replay at 16:20:50 UTC/);
        expect(r.rootCause?.statement).toContain("session 6011");
        expect(r.rootCause?.statement).not.toContain("session 5883");
    });
});

describe("T4's connection surge (finding 2)", () => {
    // CONN-IDLE and its high confidence rest on the fixture's modeled split by state (testdata/live-rb-2233e0ae.ts,
    // connectionRows): the live answers gave totals only. Final tests' rows from B's model replace it.
    it("explains it by what held the slots, says only what Azure Monitor counted, and says exactly what isn't captured", async () => {
        const r = await ask("explain_incident", { episodeKey: LIVE_KEYS.connections });
        expect(r.rootCause).toMatchObject({ ruleIds: ["CONN-IDLE"], confidence: "high" });
        expect(r.rootCause?.statement).toBe(
            "T4's client connections reached 35 of the 35 slots clients can use (max_connections 50 less 15 reserved) at 15:26:51 UTC, and stayed at 80 % of the limit or more in 32 samples between 15:26:41 and 15:31:51 UTC (5 min 10 s). " +
                "Most of them sat idle: 32 of the 35 at the peak, and at least 27 in every sample (3 ran a query, none sat idle in a transaction, none waited on a lock). Clients kept connections open without using them, so the slots filled with idle connections, not with work. " +
                "Azure Monitor counted no failed connection in any of its 3 intervals from 15:25 to 15:40 UTC.",
        );
        expect(r.findings).toHaveLength(1);
        expect(r.recommendations.map((x) => x.id)).toEqual(["PG-POOL", "PG-IDLE-SESSION-TIMEOUT"]);
        expect(r.nextSteps[0]).toMatch(/^While it happens, list who holds the idle connections: pg_stat_activity grouped by application_name, usename, client_addr, and state/);
        expect(r.notCaptured).toContain(
            "T4: who held the connections (their application, user, and client address) and how long each sat idle aren't captured for these minutes: RCA-PG-10 counts connections by state, and the capture samples sessions (RCA-PG-01) only while a client waits on a lock, which none did here.",
        );
        const details = part(r, "explain_connections");
        expect(details).toMatchObject({ limit: 35, maxConnections: 50, reserved: 15, refused: 0, peak: { at: "2026-11-21T15:26:51Z", total: 35, idle: 32 } });
    });

    it("is triage's to explain_incident, with its key, for the chat", async () => {
        const r = await ask("triage_window", { from: "2026-11-21T15:25:00Z", to: "2026-11-21T15:40:00Z", targets: ["T4"] });
        const hypotheses = r.details?.hypotheses as Array<{ family: string; nextTool: string; episodeKey?: string }>;
        expect(hypotheses.find((h) => h.family === "connections")).toMatchObject({ nextTool: "explain_incident", episodeKey: LIVE_KEYS.connections });
    });
});
