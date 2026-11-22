import { describe, expect, it } from "vitest";
import { COSMOS_METRICS } from "@/data/model";
import { analyzeConnections } from "./connections";
import { analyzeErrorsResult } from "./errors";
import { analyzeLocking, blockingEpisodes, chainsOf } from "./locking";
import { analyzeReplicaLag, LAG_METRIC } from "./replica";
import { fixtureEvidence, namesAScenario } from "./testdata/contract";
import { analyzeThroughput } from "./throughput";
import type { MetricPoint, RcaTarget, ReplicaSample, ResourcePoint, SessionSample } from "./types";

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

/** A session in one blocking sample: what the chain needs, nothing else. */
const sample = (target: RcaTarget, capturedAt: Date, session: number, blockedBy: number[]): SessionSample => ({ target, capturedAt, session, blockedBy, status: blockedBy.length ? "suspended" : "sleeping", openTransactions: 1, isDemo: true });

describe("blocking chains, the review of 34a9732", () => {
    it("counts one formation per target when two targets block at once, with interleaved samples", () => {
        // T1 sampled every 10 s at :00, T4 every 10 s at :05: together, one sample every 5 s.
        const rows: SessionSample[] = [];
        for (let s = 0; s < 60; s += 10) {
            const t1 = new Date(Date.UTC(2026, 10, 20, 17, 0, s));
            const t4 = new Date(Date.UTC(2026, 10, 20, 17, 0, s + 5));
            rows.push(sample("T1", t1, 51, []), sample("T1", t1, 52, [51]), sample("T4", t4, 61, []), sample("T4", t4, 62, [61]));
        }
        const episodes = blockingEpisodes(rows);
        expect(episodes.map((e) => [e.target, e.cycles, e.samples])).toEqual(expect.arrayContaining([["T1", 1, 6], ["T4", 1, 6]]));
    });

    it("puts a session that waits on a special owner under it, never as a head of its own", () => {
        // Session 10 waits on -2 (an orphaned distributed transaction), and session 11 waits on 10.
        const t = at("17:00:00");
        const chains = chainsOf([sample("T1", t, 10, [-2]), sample("T1", t, 11, [10])]);
        expect(chains).toHaveLength(1);
        expect(chains[0]).toMatchObject({ headKind: "special", blocked: 2, depth: 3 });
        expect(chains[0].head.session).toBe(-2);
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

    // Live, 2026-11-21: Azure Monitor's 5-minute intervals stood for a stall the capture had sampled every 5 s, so its cause
    // was looked for before it began. The capture's own samples tell the rise now, and Azure Monitor's are cited beside them.
    it("reads the rise from the replica's own samples where the capture took them, and cites Azure Monitor's lag beside them", () => {
        const a = analyzeReplicaLag({ at: at("17:14:00"), metrics: LIVE_LAG, samples: e.replica, events: e.events });
        expect(a.rise?.source).toBe("RCA Replica");
        expect(a.rootCause?.statement).toMatch(
            /^The replica's time since its last replay rose from 17:11:30 to 175\.4 s at 17:14:10 UTC \(15\.4 s, 100\.4 s, 160\.4 s, 175\.4 s\), counting from its last replay at 17:11:14 UTC, and was back to 0\.9 s at 17:14:15 UTC; it grew 1 s per second: replay stood still\./,
        );
        expect(a.rootCause?.ruleIds).toEqual(["REPL-REPLAY-CONFLICT"]);
        expect(a.rootCause?.evidence.filter((x) => x.table === "Telemetry Snapshots").map((x) => x.text)).toEqual(["Read Replica Lag 45 s", "Read Replica Lag 106 s", "Read Replica Lag 166 s"]);
        expect(a.reads).toEqual({ from: new Date("2026-11-20T17:10:14.600Z"), to: at("17:15:15") });
    });

    it("reads Azure Monitor's 5-minute intervals as intervals where the capture didn't sample: each the highest in its minutes, never an instant", () => {
        const five: MetricPoint[] = ([["16:10:00", 1], ["16:15:00", 178], ["16:20:00", 178], ["16:25:00", 2]] as const).map(([t, v]) => ({ target: "T4-replica", at: at(t), metric: LAG_METRIC, value: v, intervalMs: 300_000 }));
        const a = analyzeReplicaLag({ at: at("16:17:12"), metrics: five, samples: [], events: [] });
        expect(a.rootCause?.statement).toBe(
            "Read Replica Lag (its highest value in each 5-minute interval) reached 178 s in the 5 minutes from 16:15:00 UTC (1 s, 178 s, 178 s, 2 s) and was back to 2 s in the 5 minutes from 16:25:00 UTC. Azure Monitor's 5-minute highest values can't say whether replay stood still or slowed, and nothing captured says why.",
        );
        expect(a.rise?.slope).toBeNull();
        // The stall began no earlier than the interval's start less its lag: the cause is looked for from then.
        expect(a.reads).toEqual({ from: at("16:11:02"), to: at("16:26:00") });
        expect(a.notCaptured.join(" ")).toMatch(/5-minute intervals here, the highest value in each, so when the lag rose and peaked is known to the interval only/);
    });

    it("lets an Azure Monitor interval stand for its minutes when its rise fell between the capture's samples, and says so", () => {
        const sentinel: ReplicaSample[] = Array.from({ length: 41 }, (_, i) => ({ target: "T4-replica", at: new Date(at("20:20:12").getTime() + i * 30_000), side: "replica", sinceLastReplayS: 0.4, receivedNotReplayedBytes: 0 }));
        const metrics: MetricPoint[] = ([["20:20:00", 1], ["20:25:00", 1], ["20:30:00", 31], ["20:35:00", 1]] as const).map(([t, v]) => ({ target: "T4-replica", at: at(t), metric: LAG_METRIC, value: v, intervalMs: 300_000 }));
        const a = analyzeReplicaLag({ at: at("20:30:00"), metrics, samples: sentinel, events: [] });
        expect(a.rise).toMatchObject({ source: "Telemetry Snapshots", peak: { value: 31 } });
        expect(a.rootCause).toMatchObject({ confidence: "low", ruleIds: ["REPL-UNEXPLAINED"] });
        expect(a.rootCause?.statement).toMatch(/^Read Replica Lag \(its highest value in each 5-minute interval\) reached 31 s in the 5 minutes from 20:30:00 UTC \(0\.4 s, 31 s, 0\.4 s\) and was back to 0\.4 s at 20:35:12 UTC\. The capture's own samples on the replica in that interval stayed under 5 s, so the stall fell between them/);
        // An interval the capture's samples explain gives way to them: 20:25's 1 s isn't in the series.
        expect(a.rise?.points.map((p) => p.source)).toEqual(["RCA Replica", "Telemetry Snapshots", "RCA Replica"]);
    });

    // The review of 4e2c65ed: a stall that began after an interval's last sentinel sample, or ended before the next
    // interval's first, made that interval stand for its minutes, so the rise read "from 16:15:00", counting from a last
    // replay at 16:14:51, and the recovery's own samples were dropped.
    it("keeps the capture's samples where the one beside an interval saw the stall: begun after its last sample, or over before its first", () => {
        const samples: ReplicaSample[] = [];
        const add = (t: number, s: number) => samples.push({ target: "T4-replica", at: new Date(t), side: "replica", sinceLastReplayS: Math.round(s * 10) / 10, receivedNotReplayedBytes: 0 });
        const since = at("16:19:50").getTime();
        for (let t = at("16:10:12").getTime(); t <= at("16:19:42").getTime(); t += 30_000) add(t, 0.4);
        add(at("16:20:12").getTime(), 22);
        for (let t = at("16:20:40").getTime(); t <= at("16:25:00").getTime(); t += 5_000) add(t, (t - since) / 1000);
        add(at("16:25:05").getTime(), 0.9);
        for (let t = at("16:25:10").getTime(); t <= at("16:25:15").getTime(); t += 5_000) add(t, 0.4);
        for (let t = at("16:25:42").getTime(); t <= at("16:34:42").getTime(); t += 30_000) add(t, 0.4);
        // Azure Monitor's highest in each 5 minutes: 10 s as 16:20 began, 310 s as 16:25 began, 312 s at the recovery.
        const metrics: MetricPoint[] = ([["16:10:00", 1], ["16:15:00", 10], ["16:20:00", 310], ["16:25:00", 312], ["16:30:00", 1]] as const).map(([t, v]) => ({ target: "T4-replica", at: at(t), metric: LAG_METRIC, value: v, intervalMs: 300_000 }));
        const a = analyzeReplicaLag({ at: at("16:22:00"), metrics, samples, events: [] });
        expect(a.rise?.source).toBe("RCA Replica");
        expect(a.rise?.points.every((p) => p.source === "RCA Replica")).toBe(true);
        expect(a.rise?.lastReplay).toEqual(at("16:19:50"));
        expect(a.rootCause?.statement).toMatch(/^The replica's time since its last replay rose from 16:20:12 to 310 s at 16:25:00 UTC \(.*\), counting from its last replay at 16:19:50 UTC, and was back to 0\.9 s at 16:25:05 UTC; it grew 1 s per second/);
        expect(a.reads).toEqual({ from: at("16:18:50"), to: at("16:26:05") });
    });

    // The re-review of bb70161f: with the capture from 16:16:12, partway through a stall from 16:13:00, the rise "rose
    // from 16:10:00", the start of Azure Monitor's interval before it, counting from a last replay at 16:13:00.
    it("starts a rise whose first point is one of Azure Monitor's intervals at the capture's first sample, or says that interval", () => {
        const since = at("16:13:00").getTime();
        const samples: ReplicaSample[] = [];
        for (let t = at("16:16:12").getTime(); t <= at("16:18:00").getTime(); t += 5_000) samples.push({ target: "T4-replica", at: new Date(t), side: "replica", sinceLastReplayS: (t - since) / 1000, receivedNotReplayedBytes: 0 });
        for (let t = at("16:18:05").getTime(); t <= at("16:24:35").getTime(); t += 30_000) samples.push({ target: "T4-replica", at: new Date(t), side: "replica", sinceLastReplayS: 0.4, receivedNotReplayedBytes: 0 });
        const fiveMinutes: MetricPoint[] = ([["16:10:00", 120], ["16:15:00", 300], ["16:20:00", 1]] as const).map(([t, v]) => ({ target: "T4-replica", at: at(t), metric: LAG_METRIC, value: v, intervalMs: 300_000 }));
        const a = analyzeReplicaLag({ at: at("16:17:00"), metrics: fiveMinutes, samples, events: [] });
        expect(a.rootCause?.statement).toMatch(/^The replica's time since its last replay rose from 16:16:12 to 297 s at 16:17:57 UTC \(.*\), counting from its last replay at 16:13:00 UTC/);
        // Azure Monitor alone, with a 5-minute interval before 1-minute ones: the interval, as an interval.
        const mixed: MetricPoint[] = [
            { target: "T4-replica", at: at("16:10:00"), metric: LAG_METRIC, value: 120, intervalMs: 300_000 },
            ...([["16:15:00", 180], ["16:16:00", 240], ["16:17:00", 0.5]] as const).map(([t, v]): MetricPoint => ({ target: "T4-replica", at: at(t), metric: LAG_METRIC, value: v, intervalMs: 60_000 })),
        ];
        const b = analyzeReplicaLag({ at: at("16:16:00"), metrics: mixed, samples: [], events: [] });
        expect(b.rootCause?.statement).toMatch(/^Read Replica Lag rose in the 5 minutes from 16:10:00 UTC to 240 s at 16:16:00 UTC/);
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

    // The review of 34a9732: asked about 12:20 with the 166 s spike at 12:14, it answered that the lag "rose … to 0.6 s"
    // and "grew 1 s per second", a rise that never happened.
    it("explains the window's rise before the asked minute, never a sub-floor point after it", () => {
        const a = analyzeReplicaLag({ at: at("17:20:00"), metrics: LIVE_LAG, samples: [], events: [] });
        expect(a.rootCause?.statement).toMatch(/^Read Replica Lag rose from 17:12:00 to 166 s at 17:14:00 UTC .* and was back to 1 s at 17:15:00 UTC; it grew 1\.0\d s per second\./);
        expect(a.rise?.peak.value).toBe(166);
    });

    it("says there's no lag when nothing in the window reached the floor", () => {
        const calm = LIVE_LAG.filter((p) => (p.value ?? 0) < 5);
        const a = analyzeReplicaLag({ at: at("17:16:00"), metrics: calm, samples: [], events: [] });
        expect(a.rise).toBeNull();
        expect(a.rootCause).toMatchObject({ confidence: "high", ruleIds: ["REPL-NO-LAG"] });
        expect(a.rootCause?.statement).toMatch(/^Read Replica Lag stayed under 5 s in these minutes, at most 1 s at 17:15:00 UTC/);
        expect(a.rootCause?.statement).not.toMatch(/rose|grew/);
    });

    it("gives a rate only from two rising points", () => {
        const one: MetricPoint[] = [
            { target: "T4-replica", at: at("16:59:00"), metric: LAG_METRIC, value: 0.5 },
            { target: "T4-replica", at: at("17:00:00"), metric: LAG_METRIC, value: 30 },
            { target: "T4-replica", at: at("17:01:00"), metric: LAG_METRIC, value: 0.7 },
        ];
        const a = analyzeReplicaLag({ at: at("17:00:00"), metrics: one, samples: [], events: [] });
        expect(a.rise?.slope).toBeNull();
        expect(a.rootCause?.statement).not.toMatch(/per second/);
        expect(a.rootCause).toMatchObject({ confidence: "low", ruleIds: ["REPL-UNEXPLAINED"] });
    });
});

// Live, 2026-11-21: a surge to T4's limit had no explanation at all, since only the errors were read for it, and none was
// refused. Each state that can hold the slots has its rule; RCA-PG-10 counts a client waiting on a lock as active too.
describe("T4's connections against the limit, by what held them", () => {
    // As RCA-PG-10 counts them since 3732317d: the total has the capture's own connection, which no state has.
    const counts = (when: Date, active: number, idle: number, idleInTransaction: number, waitingLock: number): ResourcePoint[] =>
        Object.entries({ connections_total: active + idle + idleInTransaction + 1, connections_active: active, connections_idle: idle, connections_idle_in_transaction: idleInTransaction, connections_waiting_lock: waitingLock, max_connections: 50, reserved_connections: 15 }).map(([metric, value]) => ({ target: "T4", at: when, source: "RCA-PG-10", metric, value }));
    const surge = (active: number, idle: number, idleInTransaction: number, waitingLock: number) => [0, 10, 20].flatMap((s) => counts(new Date(at("15:30:00").getTime() + s * 1000), active, idle, idleInTransaction, waitingLock));
    const failed = (value: number): MetricPoint[] => [{ target: "T4", at: at("15:30:00"), metric: "connections_failed", value, intervalMs: 300_000 }];
    const ask = (resource: ResourcePoint[], metrics: MetricPoint[] = failed(0)) => analyzeConnections({ target: "T4", from: at("15:30:00"), to: at("15:31:00"), resource, sessions: [], metrics });

    it.each([
        ["CONN-LOCK-WAIT", surge(29, 2, 3, 20), ["PG-LOCK-TIMEOUT", "PG-IDLE-TIMEOUT", "PG-POOL"], "20 of the 35 at the peak waited on a lock (9 ran a query, 2 sat idle, 3 sat idle in a transaction)"],
        ["CONN-IDLE-IN-TX", surge(4, 10, 20, 0), ["PG-IDLE-TIMEOUT", "PG-POOL"], "20 of the 35 at the peak sat idle in a transaction, and at least 20 in every sample (4 ran a query, 10 sat idle, none waited on a lock)"],
        ["CONN-IDLE", surge(2, 32, 0, 0), ["PG-POOL", "PG-IDLE-SESSION-TIMEOUT"], "Most of them sat idle: 32 of the 35 at the peak, and at least 32 in every sample (2 ran a query, none sat idle in a transaction, none waited on a lock)"],
        // Queries filled every slot: only then more slots (the live check of 4e2c65ed: failed connections, its old trigger, counted none of the refusals).
        ["CONN-ACTIVE", surge(29, 5, 0, 1), ["PG-POOL", "PG-CPU", "PG-MAXCONN"], "Most of them ran a query: 29 of the 35 at the peak, 1 of them waiting on a lock (5 sat idle, none sat idle in a transaction)"],
    ])("%s: says what held the slots, with its recommendations", (ruleId, resource, ids, held) => {
        const a = ask(resource);
        expect(a.rootCause).toMatchObject({ ruleIds: [ruleId], confidence: "high" });
        expect(a.rootCause?.statement).toContain("T4's client connections reached 35 of the 35 slots clients can use (max_connections 50 less 15 reserved; the capture's own connection among them) at 15:30:00 UTC");
        expect(a.rootCause?.statement).toContain(held);
        // Final tests' live check of 4e2c65ed: Azure Monitor's failed connections stayed at 0 through the workload's refused
        // attempts, so no refusal is inferred from them; every slot in use says a client connecting then was refused.
        expect(a.rootCause?.statement).toContain("Every usable slot was in use in 3 samples between 15:30:00 and 15:30:20 UTC (35 of 35), so a client connecting then would have been refused (SQLSTATE 53300, too many clients).");
        expect(a.rootCause?.statement).toContain("Azure Monitor's failed-connection count stayed at 0 in its interval from 15:30 to 15:35 UTC; in this demo's live check it counted none of the refusals at the connection limit, so the capture can't say how many there were.");
        expect(a.rootCause?.statement).not.toMatch(/No client was refused|no client asked/);
        expect(a.recommendations.map((r) => r.id)).toEqual(ids);
    });

    it("says what Azure Monitor's failed connections count, never the refusals at the limit, and whether one is known below it", () => {
        const a = ask(surge(2, 32, 0, 0), failed(6));
        expect(a.rootCause?.statement).toContain("Azure Monitor counted 6 failed connections in its interval from 15:30 to 15:35 UTC; in this demo's live check it counted none of the refusals at the connection limit, so these may have failed for another reason, and how many clients were refused isn't known.");
        expect(a.recommendations.map((r) => r.id)).toEqual(["PG-POOL", "PG-IDLE-SESSION-TIMEOUT"]);
        // Every sample under the limit: the slots may have filled between them (live: for 0.1 s, between two of 34 of 35).
        const below = ask(surge(2, 30, 0, 0));
        expect(below.rootCause?.statement).toContain("The capture's samples saw at most 33 of the 35 usable slots in use; between them the slots may have filled, so whether a client was refused isn't known.");
        expect(below.rootCause?.statement).toContain("Azure Monitor's failed-connection count stayed at 0 in its interval from 15:30 to 15:35 UTC; in this demo's live check it counted none of the refusals at the connection limit.");
    });

    // 3732317d's review: the states leave out the capture's own connection, and the total doesn't, so they add up to one
    // less; and "36 of the 35 slots" read as nonsense where connections that may use the reserved slots took one.
    it("says the total has the capture's own connection, and a total past the limit as such", () => {
        const a = ask(surge(1, 34, 0, 0));
        expect(a.rootCause?.statement).toMatch(
            /^T4's client connections reached 36, over the 35 slots clients can use \(max_connections 50 less 15 reserved, which only privileged roles can take; the capture's own connection among them\) at 15:30:00 UTC/,
        );
        expect(a.rootCause?.statement).toContain("Most of them sat idle: 34 of the 36 at the peak, and at least 34 in every sample (1 ran a query, none sat idle in a transaction, none waited on a lock).");
        expect(a.rootCause?.statement).toContain("(up to 36 connections, over the 35), so a client connecting then would have been refused");
        expect(a.rootCause?.evidence[0].text).toBe("36 client connections of 35 (103 %): 1 active, 34 idle, 0 idle in a transaction, 0 waiting on a lock, and the capture's own");
    });

    // Before 3732317d, the capture's own query was one of the active in every sample: a row whose states add up to its total.
    it("reads a row from before 3732317d with the capture's own query left out of the active", () => {
        const old = [0, 10, 20].flatMap((s) =>
            Object.entries({ connections_total: 35, connections_active: 1, connections_idle: 34, connections_idle_in_transaction: 0, connections_waiting_lock: 0, max_connections: 50, reserved_connections: 15 }).map(
                ([metric, value]): ResourcePoint => ({ target: "T4", at: new Date(at("15:30:00").getTime() + s * 1000), source: "RCA-PG-10", metric, value }),
            ),
        );
        const a = ask(old);
        expect(a.rootCause?.statement).toContain("Most of them sat idle: 34 of the 35 at the peak, and at least 34 in every sample (none ran a query, none sat idle in a transaction, none waited on a lock).");
        expect(a.rootCause?.evidence[0].text).toBe("35 client connections of 35 (100 %): 0 active, 34 idle, 0 idle in a transaction, 0 waiting on a lock, and the capture's own");
    });

    it("says exactly what isn't captured: who held the connections, how many were refused, and the states when only the total was counted", () => {
        const a = ask(surge(2, 32, 0, 0));
        expect(a.notCaptured).toEqual([
            "T4: how many clients were refused at the connection limit isn't captured: PostgreSQL refuses them before they reach a session, and in this demo's live check Azure Monitor's failed connections counted none of them.",
            "T4: who held the connections (their application, user, and client address) and how long each sat idle aren't captured for these minutes: RCA-PG-10 counts connections by state, and the capture samples sessions (RCA-PG-01) only while a client waits on a lock, which none did here.",
        ]);
        const totals = surge(2, 32, 0, 0).filter((r) => ["connections_total", "max_connections", "reserved_connections"].includes(r.metric));
        const b = ask(totals, []);
        expect(b.rootCause).toMatchObject({ ruleIds: ["CONN-STATES-UNKNOWN"], confidence: "low" });
        expect(b.notCaptured).toEqual(expect.arrayContaining([expect.stringMatching(/^T4: the connections' states .* weren't captured, only their total\.$/), "T4: Azure Monitor's failed connections aren't in the history for 15:30:00-15:31:00 UTC."]));
    });

    it("describes a surge in waves by their peaks and the troughs between them, and one the capture never ended by where it ended", () => {
        const sample = (s: number, total: number) => counts(new Date(at("15:30:00").getTime() + s * 1000), 0, total - 1, 0, 0);
        const waves = [35, 33, 9, 8, 34, 33, 8, 33, 14].flatMap((total, i) => sample(i * 10, total));
        const a = analyzeConnections({ target: "T4", from: at("15:30:00"), to: at("15:31:30"), resource: waves, sessions: [], metrics: failed(0), openEnded: true });
        expect(a.rootCause?.statement).toContain(
            "in 3 waves at 80 % of the limit or more between 15:30:00 and 15:31:10 UTC, with peaks of 35, 34, and 33 and the connections falling to 8 and 8 between them; 5 of the 9 samples from 15:30:00 to 15:31:20 UTC were at that level.",
        );
        // The review of 803f2b1a: its last sample, 14, was under the level, so it fell, and wasn't "still on".
        expect(a.rootCause?.statement).toContain("The connections fell under 80 % of the limit by 15:31:20 UTC; the capture ended at 15:31:20 UTC, before it could confirm the end.");
        expect(a.rootCause?.statement).not.toMatch(/still on/);
        expect(a.details).toMatchObject({ captureEnded: "2026-11-20T15:31:20Z", fellUnder: "2026-11-20T15:31:20Z", waves: [{ peak: 35, lowBefore: null }, { peak: 34, lowBefore: 8 }, { peak: 33, lowBefore: 8 }] });
        // Its last sample at the level: still on.
        const on = analyzeConnections({ target: "T4", from: at("15:30:00"), to: at("15:31:30"), resource: [35, 33, 9, 8, 34, 33, 8, 33].flatMap((total, i) => sample(i * 10, total)), sessions: [], metrics: failed(0), openEnded: true });
        expect(on.rootCause?.statement).toContain("The capture ended at 15:31:10 UTC while it was still on (it recorded no end), so what came after isn't known.");
        expect(on.details).toMatchObject({ fellUnder: null });
    });
});

// Found with the live findings (2026-11-21): an RU episode was explained only through its 429s, so one without any had no cause.
describe("T5's normalized RU consumption at 100 %", () => {
    const point = (metric: string, time: string, value: number, intervalMs = 60_000): MetricPoint => ({ target: "T5", at: at(time), metric, value, intervalMs });
    const minutes = (throttled: number[]) => [
        ...[100, 100, 60].map((v, i) => point(COSMOS_METRICS.normalizedRu, `17:0${i}:00`, v)),
        ...[1200, 1300, 900].map((v, i) => point(COSMOS_METRICS.requests, `17:0${i}:00`, v)),
        ...throttled.map((v, i) => point(COSMOS_METRICS.throttled, `17:0${i}:00`, v)),
    ];
    const provisioned = (ru: number) => point(COSMOS_METRICS.provisioned, "17:00:00", ru, 3_600_000);

    // The review of 4e2c65ed: the counts took in 17:02's interval, which the sentence doesn't name; 100 % read as the
    // container's whole throughput; and a new partition key and autoscale were recommended with nothing throttled.
    it("says what 100 % means, counts only the intervals it names, and recommends no change when none was throttled", () => {
        const a = analyzeThroughput({ from: at("17:00:00"), to: at("17:03:00"), metrics: minutes([0, 0, 0]) });
        expect(a.rootCause).toMatchObject({ ruleIds: ["RU-AT-LIMIT"], confidence: "medium" });
        expect(a.rootCause?.statement).toBe(
            "T5's normalized RU consumption (the busiest partition key range's share of its RU/s; Azure Monitor keeps the highest in each 1-minute interval) reached 100 % in at least one second of each of the 2 intervals from 17:00 to 17:02 UTC: in such a second, at least one partition key range used all of its share of the RU/s. Azure Monitor counted 2500 requests in those intervals, none of them throttled.",
        );
        expect(a.recommendations).toEqual([]);
        expect(a.notCaptured[0]).toMatch(/^T5: which partition key range was busiest.* Nor is its provisioned throughput for these minutes, so whether a new partition key could help isn't known/);
    });

    it.each([
        ["above 5 %: more throughput", [150, 50, 0], "200 of them throttled (429, 8 %)", "That's more than the 5 % of requests at which Learn recommends more throughput.", ["RU-RETRY", "RU-AUTOSCALE"]],
        ["up to 5 %: the clients' retries only", [60, 40, 0], "100 of them throttled (429, 4 %)", "Learn counts up to 5 % of requests throttled, with acceptable latency, as RU/s fully used, with no action needed.", ["RU-RETRY"]],
    ])("counts the throttled requests in the intervals it names, with their share, and recommends by Learn's 5 %, %s", (_, throttled, counted, guide, ids) => {
        const a = analyzeThroughput({ from: at("17:00:00"), to: at("17:03:00"), metrics: minutes(throttled as number[]) });
        expect(a.rootCause?.ruleIds).toEqual(["RU-THROTTLED"]);
        expect(a.rootCause?.statement).toContain(`Azure Monitor counted 2500 requests in those intervals, ${counted}`);
        expect(a.rootCause?.statement).toContain(guide as string);
        expect(a.recommendations.map((r) => r.id)).toEqual(ids);
    });

    it("says why a new partition key wouldn't help a container of one physical partition, and recommends one only with several", () => {
        const one = analyzeThroughput({ from: at("17:00:00"), to: at("17:03:00"), metrics: [...minutes([150, 50, 0]), provisioned(400)] });
        expect(one.rootCause?.statement).toContain(
            "At 400 RU/s, under the 10,000 RU/s one physical partition serves, the container needs only one physical partition unless it holds more than 50 GB, so all its requests share those 400 RU/s whatever their partition key: a new key wouldn't raise the limit.",
        );
        expect(one.recommendations.map((r) => r.id)).toEqual(["RU-RETRY", "RU-AUTOSCALE"]);
        expect(one.notCaptured[0]).not.toMatch(/Nor is its provisioned throughput/);
        const several = analyzeThroughput({ from: at("17:00:00"), to: at("17:03:00"), metrics: [...minutes([150, 50, 0]), provisioned(20_000)] });
        expect(several.rootCause?.statement).toContain("At 20000 RU/s, over the 10,000 RU/s one physical partition serves, the container has several physical partitions");
        expect(several.recommendations.map((r) => r.id)).toEqual(["RU-RETRY", "RU-AUTOSCALE", "RU-PARTITION"]);
    });
});
