import { describe, expect, it } from "vitest";
import { analyzeErrorsResult } from "./errors";
import { analyzeLocking } from "./locking";
import { analyzeReplicaLag, LAG_METRIC } from "./replica";
import { fixtureEvidence, namesAScenario } from "./testdata/contract";
import type { MetricPoint } from "./types";

const at = (hms: string) => new Date(`2026-11-20T${hms}Z`);

/** The owner's measured Read Replica Lag of 2026-11-20 (Azure Monitor, a point a minute), around the 12:14 EST spike. */
export const LIVE_LAG: MetricPoint[] = [
    ["17:09:00", 0.5],
    ["17:10:00", 0.6],
    ["17:11:00", 0.7],
    ["17:12:00", 45],
    ["17:13:00", 106],
    ["17:14:00", 166],
    ["17:15:00", 1],
    ["17:16:00", 0.8],
].map(([time, value]) => ({ target: "T4-replica", at: at(time as string), metric: LAG_METRIC, value: value as number }));

describe("blocking (INV-01) on T1's chain", () => {
    const e = fixtureEvidence("t1");
    const a = analyzeLocking(e.sessions, e.events);

    it("puts the head blocker first: the idle transaction, its procedure, who ran it, and its lock", () => {
        const chain = a.episodes.find((x) => x.headSession === 63)!;
        expect(chain).toMatchObject({ target: "T1", headSession: 63, headKind: "idle-open-transaction", cycles: 5 });
        expect(chain.peak).toMatchObject({ blocked: 6, depth: 4, width: 2 });
        expect(a.rootCause?.ruleIds).toEqual(["BLK-IDLE-HEAD"]);
        expect(a.rootCause?.confidence).toBe("high");
        const s = a.rootCause!.statement;
        for (const fact of ["[demo].[usp_scenario_chain_acquire]", "session 63", "NT AUTHORITY\\SYSTEM", "SQLVM01", "ContosoCare.Demo", "79 s", "[care].[work_queues]", "pk_work_queues", "6 sessions", "2 branches", "4 levels", "58 s", "5 times"]) expect(s).toContain(fact);
        expect(a.chainLines[0]).toMatch(/^HEAD session 63/);
    });

    it("names each lock escalation to a table lock", () => {
        const escalations = a.findings.filter((f) => f.ruleId === "BLK-ESCALATION");
        expect(escalations).toHaveLength(4);
        expect(escalations[0].detail).toMatch(/6,248 locks escalated to an X lock/);
        expect(a.recommendations.map((r) => r.id)).toEqual(expect.arrayContaining(["BLK-COMMIT", "ESC-BATCH"]));
    });

    it("says nothing the workload planned", () => {
        expect(namesAScenario(JSON.stringify(a))).toEqual([]);
    });
});

describe("blocking (INV-01) on T4's chain, PostgreSQL", () => {
    const e = fixtureEvidence("t4");
    const a = analyzeLocking(e.sessions.filter((s) => s.target === "T4"), e.events, at("17:05:00"));

    it("finds the session idle in transaction at the head, and its three waiters", () => {
        expect(a.rootCause?.ruleIds).toEqual(["BLK-PG-IDLE-IN-TRANSACTION"]);
        const s = a.rootCause!.statement;
        for (const fact of ["demo.usp_scenario_locking_acquire", "session 20432", "care.work_queues", "3 sessions", "4 times"]) expect(s).toContain(fact);
        expect(a.chainLines.join("\n")).toMatch(/HEAD session 20432[\s\S]*9772[\s\S]*20584[\s\S]*35660/);
        expect(a.recommendations.map((r) => r.id)).toEqual(expect.arrayContaining(["PG-IDLE-TIMEOUT", "PG-LOCK-TIMEOUT"]));
    });
});

describe("errors by class (INV-12) on T1", () => {
    it("counts the 30 lock timeouts, who hit them, and that their own TRY...CATCH caught every one", () => {
        const r = analyzeErrorsResult(fixtureEvidence("t1").events);
        expect(r.details).toMatchObject({ classes: [{ class: "lock-timeout", count: 30, intercepted: 30, top: "[demo].[usp_scenario_chain_link]", targets: ["T1"] }] });
        expect(r.rootCause?.statement).toMatch(/^Most errors were lock timeouts \(30, 16:53:00 to 17:00:00 UTC, mostly \[demo\]\.\[usp_scenario_chain_link\]\)/);
        expect(r.nextSteps[0]).toMatch(/^explain_locking for T1/);
    });
});

describe("read replica lag (INV-15) on T4's replica", () => {
    const e = fixtureEvidence("t4");

    it("explains the stall from the replica's own samples: a replay conflict, and not the network or the write volume", () => {
        const a = analyzeReplicaLag({ at: at("17:14:00"), metrics: [], samples: e.replica, events: e.events });
        expect(a.rise?.source).toBe("RCA Replica");
        expect(a.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-REPLAY-CONFLICT"] });
        const s = a.rootCause!.statement;
        for (const fact of ["175.4 s at 17:14:10 UTC", "demo.replica_lag_marks", "AccessExclusiveLock", "AccessShareLock", "session 41872", "from 17:11:15 UTC", "178500 bytes received but not replayed", "at most 0.002 s", "1020 bytes/s", "max_standby_streaming_delay (600 s)", "nothing was cancelled"]) expect(s).toContain(fact);
        expect(a.recommendations.map((r) => r.id)).toEqual(["RPL-SHORT-REPORTS", "RPL-STANDBY-DELAY", "RPL-NO-EXCLUSIVE"]);
    });

    it("reads the rise from Azure Monitor's lag when the history has it, with the owner's measured points", () => {
        const a = analyzeReplicaLag({ at: at("17:14:00"), metrics: LIVE_LAG, samples: e.replica, events: e.events });
        expect(a.rise?.source).toBe("Telemetry Snapshots");
        expect(a.rootCause?.statement).toMatch(/^Read Replica Lag rose from 17:12:00 to 166 s at 17:14:00 UTC \(0\.7 s, 45 s, 106 s, 166 s, 1 s\) and was back to 1 s at 17:15:00 UTC; it grew 1\.0\d s per second: replay stood still\./);
        expect(a.rootCause?.ruleIds).toEqual(["REPL-REPLAY-CONFLICT"]);
    });

    it("says 'nothing captured says why' when only the metric is left, at low confidence, and never guesses", () => {
        const a = analyzeReplicaLag({ at: at("17:14:00"), metrics: LIVE_LAG, samples: [], events: [] });
        expect(a.rootCause).toMatchObject({ confidence: "low", ruleIds: ["REPL-REPLAY-STALLED"] });
        expect(a.notCaptured.join(" ")).toMatch(/RCA Replica/);
    });

    it("reads a rise right after a gap as the replica's catch-up after a restart, not lag", () => {
        const restart: MetricPoint[] = [
            { target: "T4-replica", at: at("16:00:00"), metric: LAG_METRIC, value: 0.5 },
            { target: "T4-replica", at: at("16:30:00"), metric: LAG_METRIC, value: 1400 },
            { target: "T4-replica", at: at("16:31:00"), metric: LAG_METRIC, value: 2 },
        ];
        const a = analyzeReplicaLag({ at: at("16:30:00"), metrics: restart, samples: [], events: [] });
        expect(a.rootCause?.ruleIds).toEqual(["REPL-CATCHUP"]);
    });
});
