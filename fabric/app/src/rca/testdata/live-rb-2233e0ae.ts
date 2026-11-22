// Session 2233e0ae on dbhubrb, 2026-11-21 (Final tests' live run at 94a17ff7): T4's read replica and its connections, as
// the investigations read them. The harness saved the tools' answers and their DAX, not the rows
// (evidence/rca-rb-94a17ff7-session90/rca-tools.json and rca-rb-94a17ff7-session90-view/rca-keys.json), so the rows are
// rebuilt from the answers. Every value an answer states is here as stated:
// - Azure Monitor's Read Replica Lag, the highest value in each 5-minute interval: 1 s from 16:10, 178 s from 16:15 and
//   from 16:20, 2 s from 16:25;
// - the capture's two replay stalls, as its escalated and relaxed events give them (16:17:12 to 16:20:03, peak 176.7 s;
//   16:21:42 to 16:24:03, peak 177.7 s);
// - the first stall's conflict: the startup process waiting for AccessExclusiveLock on demo.replica_lag_marks from
//   16:16:21, which session 5883's AccessShareLock held; 506,051,648 bytes received and not replayed at 16:17:12, at most
//   578,598,600; max_standby_streaming_delay 600 s, nothing cancelled;
// - the primary: write and flush lag at most 7.132 s, and its WAL rate's median, 548,651 bytes/s from 16:14 to 16:26
//   and 669 bytes/s from 16:14 to 16:16.
// Between them are the capture's own cadence (every 30 s; every 5 s while replay stood still) and the time since the
// last replay that a stall implies. 94a17ff7's code gives both live answers on these rows word for word (the
// implementation report). The connection surge's answers give no counts by state: its rows follow RCA-PG-10's shape
// with what they do give (15:26:41 to 15:35:11, 32 samples at 80 % of the limit or more, 100 % at 15:26:51), T4's
// limit on every size (max_connections 50 less 15 reserved: scenarios/connection-surge/README.md), and Azure Monitor's
// failed connections at 0 in every interval.

import type { PostgresCapture, PostgresPoint } from "@/data/model";
import { POSTGRES_METRICS } from "@/data/model";
import type { Telemetry } from "../tools";
import type { Coverage, EventRow, Evidence, RcaTarget, ReplicaSample, ResourcePoint } from "../types";

export const LIVE_DAY = "2026-11-21";
/** A UTC time on the live day: "16:17:12" or "16:17:12.3". */
export const live = (hms: string) => new Date(`${LIVE_DAY}T${hms}Z`);
const S = 1000;
const plus = (at: Date, ms: number) => new Date(at.getTime() + ms);
const round1 = (v: number) => Math.round(v * 10) / 10;

export const LIVE_KEYS = {
    replicaFirst: "T4-replica-replica_lag-20261121T161712Z",
    replicaSecond: "T4-replica-replica_lag-20261121T162142Z",
    connections: "T4-connections-20261121T152641Z",
} as const;

const HOLDER_STATEMENT = "SELECT r.marks_seen, r.last_mark FROM (SELECT count(*) AS marks_seen, max(m.marked_at) AS last_mark FROM demo.replica_lag_marks AS m) AS r CROSS JOIN pg_sleep($1) AS s";

interface Stall {
    /** When replay last advanced: the time since the last replay counts from here. */
    since: Date;
    escalated: Date;
    peakAt: Date;
    /** The samples back under 5 s, the last of them when the capture relaxed. */
    recovered: Date[];
    holder: number;
    waitStart: Date;
    backlogAtEscalation: number;
    backlogPeak: number;
}

const STALLS: Stall[] = [
    { since: live("16:16:20.6"), escalated: live("16:17:12"), peakAt: live("16:19:17.3"), recovered: [live("16:19:33"), live("16:19:48"), live("16:20:03")], holder: 5883, waitStart: live("16:16:21"), backlogAtEscalation: 506_051_648, backlogPeak: 578_598_600 },
    { since: live("16:20:50"), escalated: live("16:21:42"), peakAt: live("16:23:47.7"), recovered: [live("16:23:52"), live("16:23:57"), live("16:24:03")], holder: 6011, waitStart: live("16:20:50"), backlogAtEscalation: 196_402_118, backlogPeak: 265_013_004 },
];

/** The replica's and the primary's samples (RCA Replica): the sentinel every 30 s, every 5 s while replay stood still. */
function replicaRows(): ReplicaSample[] {
    const rows: ReplicaSample[] = [];
    const quiet = (at: Date, since: number, wal: number) => {
        rows.push({ target: "T4-replica", at, side: "replica", sinceLastReplayS: since, receivedNotReplayedBytes: 0, conflictsCancelled: 0 });
        rows.push({ target: "T4", at: plus(at, 100), side: "primary", standby: "pgreplica01", replayLagS: since, writeLagS: 0.001, flushLagS: 0.002, sendGapBytes: 0, walBytesPerS: wal });
    };
    // The sentinel before the first stall; from 16:14 to 16:16 the primary wrote about 669 bytes/s (the view's live answer).
    const before: Array<[string, number]> = [["16:14:12", 655], ["16:14:42", 669], ["16:15:12", 702], ["16:15:42", 669]];
    for (let t = live("16:00:12").getTime(); t < live("16:14:12").getTime(); t += 30 * S) quiet(new Date(t), 0.4, 640);
    for (const [hms, wal] of before) quiet(live(hms), 0.4, wal);
    quiet(live("16:16:12"), 0.4, 688);
    // The sentinel that saw the first stall begin: 21.4 s since the last replay, after a burst of WAL from the primary.
    rows.push({ target: "T4-replica", at: live("16:16:42"), side: "replica", sinceLastReplayS: 21.4, receivedNotReplayedBytes: 380_114_220, startupWait: "Lock:relation", conflictsCancelled: 0 });
    rows.push({ target: "T4", at: live("16:16:42.1"), side: "primary", standby: "pgreplica01", replayLagS: 21.4, writeLagS: 1.204, flushLagS: 1.31, sendGapBytes: 0, walBytesPerS: 12_670_474 });
    for (const [i, stall] of STALLS.entries()) {
        // The second stall's own sentinel samples before its escalation.
        if (i === 1) {
            quiet(live("16:20:12"), 0.4, 702);
            quiet(live("16:20:42"), 0.4, 688);
            rows.push({ target: "T4-replica", at: live("16:21:12"), side: "replica", sinceLastReplayS: 22, receivedNotReplayedBytes: 179_947_588, startupWait: "Lock:relation", conflictsCancelled: 0 });
            rows.push({ target: "T4", at: live("16:21:12.1"), side: "primary", standby: "pgreplica01", replayLagS: 22, writeLagS: 0.981, flushLagS: 1.02, sendGapBytes: 0, walBytesPerS: 8_179_436 });
        }
        const times: Date[] = [];
        for (let t = stall.escalated.getTime(); t < stall.peakAt.getTime() - 2 * S; t += 5 * S) times.push(new Date(t));
        times.push(stall.peakAt);
        for (const at of times) {
            const since = round1((at.getTime() - stall.since.getTime()) / 1000);
            const backlog = at.getTime() === stall.peakAt.getTime() ? stall.backlogPeak : stall.backlogAtEscalation + Math.round(548_651 * ((at.getTime() - stall.escalated.getTime()) / 1000));
            rows.push({
                target: "T4-replica", at, side: "replica", sinceLastReplayS: since, receivedNotReplayedBytes: backlog, startupWait: "Lock:relation",
                conflictRelation: "demo.replica_lag_marks", conflictWantedMode: "AccessExclusiveLock", conflictWaitStart: stall.waitStart, conflictHolder: stall.holder, conflictHolderMode: "AccessShareLock",
                conflictHolderProgram: "ContosoCare.Demo", conflictHolderRunToken: i === 0 ? "5d1c0b7e2a94" : "8e27f1c4a630", conflictHolderStatement: HOLDER_STATEMENT, conflictsCancelled: 0, maxStandbyStreamingDelayS: 600,
            });
            // The primary shipped normally: its write and flush lag stayed low (at most 7.132 s, once) and its WAL rate's median was 548,651 bytes/s.
            const writeLag = i === 0 && at.getTime() === live("16:18:02").getTime() ? 7.132 : 0.004;
            rows.push({ target: "T4", at: plus(at, 100), side: "primary", standby: "pgreplica01", replayLagS: since, writeLagS: writeLag, flushLagS: writeLag === 7.132 ? 6.981 : 0.006, sendGapBytes: 0, walBytesPerS: 548_651 });
        }
        for (const at of stall.recovered) {
            rows.push({ target: "T4-replica", at, side: "replica", sinceLastReplayS: at === stall.recovered[0] ? 0.9 : 0.4, receivedNotReplayedBytes: 0, conflictsCancelled: 0, maxStandbyStreamingDelayS: 600 });
            rows.push({ target: "T4", at: plus(at, 100), side: "primary", standby: "pgreplica01", replayLagS: 0.4, writeLagS: 0.002, flushLagS: 0.003, sendGapBytes: 0, walBytesPerS: 548_651 });
        }
    }
    for (let t = live("16:24:33").getTime(); t <= live("16:50:03").getTime(); t += 30 * S) quiet(new Date(t), 0.4, 671);
    return rows.sort((a, b) => a.at.getTime() - b.at.getTime());
}

/** T4's sentinel connection counts (RCA-PG-10): every 30 s, every 10 s while at 80 % of the 35 slots clients can use. */
function connectionRows(): ResourcePoint[] {
    const rows: ResourcePoint[] = [];
    // MODELED, NOT LIVE: the totals, their times, and the limit follow the live answers, but the split by state (active,
    // idle, idle in a transaction, waiting on a lock) is an assumption, since the harness kept no counts by state. Every
    // assertion about what held the slots (CONN-IDLE and its confidence in live-accuracy.test.ts) rests on this model
    // until Final tests' rows from B's model replace it (the review of 4e2c65ed).
    const sample = (at: Date, active: number, idle: number, idleInTransaction = 0, waiting = 0) => {
        const counts: Record<string, number> = {
            connections_total: active + idle + idleInTransaction,
            connections_active: active,
            connections_idle: idle,
            connections_idle_in_transaction: idleInTransaction,
            connections_waiting_lock: waiting,
            max_connections: 50,
            reserved_connections: 15,
        };
        for (const [metric, value] of Object.entries(counts)) rows.push({ target: "T4", at, source: "RCA-PG-10", metric, value, unit: "count" });
    };
    for (let t = live("15:20:11").getTime(); t <= live("15:26:31").getTime(); t += 30 * S) sample(new Date(t), 3, 9);
    // The surge: 30 at 15:26:41 (86 %, the capture escalated), all 35 at 15:26:51, then 33 to 35 for 32 samples in a row.
    sample(live("15:26:41"), 3, 27);
    sample(live("15:26:51"), 3, 32);
    for (let k = 2, t = live("15:27:01").getTime(); t <= live("15:31:51").getTime(); k++, t += 10 * S) sample(new Date(t), k % 3 === 0 ? 3 : 2, k % 4 === 0 ? 31 : 32 - (k % 2), k % 7 === 0 ? 1 : 0);
    // The wave closed: 26 and 25 (still 70 % or more) until 15:34:01, then the baseline; the capture relaxed at 15:35:11.
    for (let t = live("15:32:01").getTime(); t <= live("15:34:01").getTime(); t += 10 * S) sample(new Date(t), 2, t < live("15:33:01").getTime() ? 24 : 23);
    for (let t = live("15:34:11").getTime(); t <= live("15:35:11").getTime(); t += 10 * S) sample(new Date(t), 3, 9);
    for (let t = live("15:35:41").getTime(); t <= live("16:50:11").getTime(); t += 30 * S) sample(new Date(t), 3, 9);
    return rows;
}

function eventRows(): EventRow[] {
    const capture = (target: RcaTarget, at: Date, name: "escalated" | "relaxed", code: string, detail: string): EventRow => ({ target, at, kind: "capture", name, code, count: 1, detail });
    return [
        capture("T4", live("15:26:41"), "escalated", "T4-20261121T152641Z", "client connections 30 >= 80 % of 35 (max_connections 50 minus 15 reserved): connection detail (RCA-PG-10) every 10 s."),
        capture("T4", live("15:35:11"), "relaxed", "T4-20261121T152641Z", "client connections under 70 % of 35 for 60 s: back to the 30-s sentinel."),
        capture("T4-replica", live("16:17:12"), "escalated", "T4-replica-20261121T161712Z", "since_last_replayed_s 51.4 >= 30 with 506,051,648 bytes received and not replayed: replay detail (RCA-PG-01, RCA-PG-02, RCA-PG-06, RCA-PG-07) every 5 s."),
        capture("T4-replica", live("16:20:03"), "relaxed", "T4-replica-20261121T161712Z", "since_last_replayed_s below 5 for 3 samples: back to the 30-s sentinel."),
        capture("T4-replica", live("16:21:42"), "escalated", "T4-replica-20261121T162142Z", "since_last_replayed_s 52.0 >= 30 with 196,402,118 bytes received and not replayed: replay detail (RCA-PG-01, RCA-PG-02, RCA-PG-06, RCA-PG-07) every 5 s."),
        capture("T4-replica", live("16:24:03"), "relaxed", "T4-replica-20261121T162142Z", "since_last_replayed_s below 5 for 3 samples: back to the 30-s sentinel."),
    ];
}

const COVERAGE: Coverage[] = (["T4", "T4-replica"] as const).map((target) => ({
    target,
    from: live("15:20:00"),
    to: live("16:51:00"),
    captured: true,
    sources: target === "T4" ? ["RCA-PG-01", "RCA-PG-02", "RCA-PG-03", "RCA-PG-04", "RCA-PG-05", "RCA-PG-10", "RCA-PG-11"] : ["RCA-PG-01", "RCA-PG-02", "RCA-PG-03", "RCA-PG-06", "RCA-PG-07", "RCA-PG-08", "RCA-PG-09"],
    gaps: [],
}));

/** Azure Monitor's points, in 5-minute intervals: the replica's Read Replica Lag (Maximum) and T4's failed connections (Total). */
function monitorPoints(): PostgresPoint[] {
    const points: PostgresPoint[] = [];
    const lag: Record<string, number> = { "16:15:00": 178, "16:20:00": 178, "16:25:00": 2 };
    for (let t = live("15:00:00").getTime(); t <= live("16:45:00").getTime(); t += 5 * 60 * S) {
        const at = new Date(t);
        const hms = at.toISOString().slice(11, 19);
        if (t >= live("16:00:00").getTime()) points.push({ at, target: "T4-replica", server: "pgreplica01", metric: POSTGRES_METRICS.lag, value: lag[hms] ?? 1 });
        points.push({ at, target: "T4", server: "pgflex01", metric: POSTGRES_METRICS.failed, value: 0 });
    }
    return points;
}

const inside = (at: Date, from: Date, to: Date) => at >= from && at <= to;

/** The investigations' sources over these rows, as the loader and the telemetry queries filter them. */
export function liveSources(): { load: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Evidence>; telemetry: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<Telemetry> } {
    const replica = replicaRows();
    const resource = connectionRows();
    const events = eventRows();
    const points = monitorPoints();
    return {
        load: async (from, to, targets) => ({
            sessions: [],
            events: events.filter((e) => targets.includes(e.target) && inside(e.at, from, to)),
            resource: resource.filter((r) => targets.includes(r.target) && inside(r.at, from, to)),
            replica: replica.filter((r) => targets.includes(r.target) && inside(r.at, from, to)),
            waits: [],
            coverage: COVERAGE.filter((c) => targets.includes(c.target) && c.to >= from && c.from <= to),
            metrics: [],
        }),
        telemetry: async (from, to, targets) => {
            const kept = points.filter((p) => targets.includes(p.target) && inside(p.at, from, to));
            const postgres: PostgresCapture | null = kept.length ? { capturedAt: live("16:52:00"), windowStart: live("15:00:00"), windowEnd: live("16:50:00"), intervalMinutes: 5, servers: { T4: "pgflex01", "T4-replica": "pgreplica01" }, points: kept } : null;
            return { postgres };
        },
    };
}
