// Why T4's read replica lagged at a given time. Azure Monitor's Read Replica Lag (physical_replication_delay_in_seconds)
// is the time since the replica last replayed a transaction (ADR 0025), so it grows by a second every second whenever
// replay doesn't advance, whatever the reason. The observer measures the same on the replica (since_last_replayed_s),
// every 30 s and every 5 s while replay stands still: its samples tell the rise wherever it took them, and Azure
// Monitor's, the highest value in each interval, the minutes it didn't. The rules separate the reasons:
//   REPL-CATCHUP          the replica's first points after a stop: catch-up, not lag (the app's replicaCatchUp)
//   REPL-REPLAY-CONFLICT  WAL arrives but replay waits on a lock a replica query holds (hot standby conflict)
//   REPL-REPLAY-SLOW      replay advances, slower than WAL arrives
//   REPL-SHIPPING         the WAL isn't reaching the replica (send gap, write or flush lag)
//   REPL-IDLE-PRIMARY     nothing to replay: the primary committed nothing, so "time since the last replay" grows
//   REPL-REPLAY-STALLED   replay stood still, and nothing captured says why
//   REPL-NO-LAG           the lag stayed under 5 s in the window: nothing to explain
// https://www.postgresql.org/docs/18/hot-standby.html#HOT-STANDBY-CONFLICT, https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas

import { recommend } from "./catalog";
import { hhmmss, iso, plural, type Confidence, type EventRow, type EvidenceRef, type Finding, type MetricPoint, type Recommendation, type ReplicaSample } from "./types";

export const LAG_METRIC = "physical_replication_delay_in_seconds";
export const RESTART_GAP_MINUTES = 10;
/** The capture's samples cover the minutes between two of them up to this far apart: its 30-s sentinel, three times. */
export const CAPTURE_GAP_MS = 90_000;

export type LagSource = "Telemetry Snapshots" | "RCA Replica";

export interface LagPoint {
    at: Date;
    value: number;
    /** The capture's own sample on the replica (an instant), or Azure Monitor's Read Replica Lag (Telemetry Snapshots). */
    source: LagSource;
    /** Azure Monitor's interval: the value is the highest from `at` to `at` plus this. Absent for the capture's samples. */
    intervalMs?: number;
}

export interface LagSeries {
    points: LagPoint[];
    /** Azure Monitor's points, each with its interval, also those the capture's samples stand for (Database Hub charts them). */
    monitor: LagPoint[];
}

export interface LagRise {
    start: Date;
    peak: LagPoint;
    recovered?: LagPoint;
    /** Seconds of lag added per second of clock while it rose: 1.0 means replay stood still. Null with fewer than two rising points, or from Azure Monitor's coarser intervals. */
    slope: number | null;
    points: LagPoint[];
    /** Where its peak comes from: the observer's own samples on the replica, or Azure Monitor's metric. */
    source: LagSource;
    /** When replay last advanced before it, at the earliest: a point's time less its lag, since the lag is the time since the last replay. An Azure Monitor point gives only a lower bound: its value was the highest at some time in its interval. */
    stalledSince: Date;
    /** When replay last advanced, from the capture's own samples in the rise; absent when none backs it (the review of 4e2c65ed). */
    lastReplay?: Date;
    /** When it ended: its recovery, or the end of its last point (an interval's end for Azure Monitor's) when it hadn't recovered in these minutes. */
    end: Date;
}

const round1 = (v: number) => Math.round(v * 10) / 10;
const endOf = (p: LagPoint) => p.at.getTime() + (p.intervalMs ?? 0);
/** Azure Monitor's interval in minutes, for the words: "5". */
const minutesOf = (p: LagPoint) => Math.round((p.intervalMs ?? 0) / 60_000);
/** Coarser than a minute: Azure Monitor's value is the interval's highest, not the lag at its start. */
const coarse = (p: LagPoint) => (p.intervalMs ?? 0) > 60_000;

/**
 * The lag series for the window: the capture's own samples on the replica (since_last_replayed_s: every 30 s, every 5 s
 * while replay stands still) wherever it took them, and Azure Monitor's Read Replica Lag (the highest value in each
 * interval, stamped with the interval's start) for the minutes it didn't, and for an interval whose rise the capture's
 * samples missed. Live, 2026-11-21: with Azure Monitor's 5-minute intervals first, a stall from 16:16:21 to 16:19:22
 * read as a rise "from 16:15:00 to 178 s at 16:15:00", and its cause was looked for from 16:14 to 16:16, before it began.
 */
export function lagSeries(metrics: readonly MetricPoint[], samples: readonly ReplicaSample[], floor = 5): LagSeries {
    const own: LagPoint[] = samples
        .filter((s): s is ReplicaSample & { sinceLastReplayS: number } => s.side === "replica" && s.sinceLastReplayS !== undefined)
        .map((s) => ({ at: s.at, value: s.sinceLastReplayS, source: "RCA Replica" as const }))
        .sort((a, b) => a.at.getTime() - b.at.getTime());
    const monitor = metrics
        .filter((m): m is MetricPoint & { value: number } => m.target === "T4-replica" && m.metric === LAG_METRIC && m.value !== null)
        .sort((a, b) => a.at.getTime() - b.at.getTime());
    const gaps = monitor.slice(1).map((m, i) => m.at.getTime() - monitor[i].at.getTime()).filter((g) => g > 0);
    const grain = gaps.length ? Math.min(...gaps) : 60_000;
    // The minutes the capture sampled: runs of its samples no more than CAPTURE_GAP_MS apart.
    const spans: Array<{ from: number; to: number }> = [];
    for (const p of own) {
        const t = p.at.getTime();
        const last = spans[spans.length - 1];
        if (last && t - last.to <= CAPTURE_GAP_MS) last.to = t;
        else spans.push({ from: t, to: t });
    }
    const all = monitor.map((m): LagPoint => ({ at: m.at, value: m.value, source: "Telemetry Snapshots", intervalMs: m.intervalMs ?? grain }));
    const missed: LagPoint[] = [];
    const kept = all.filter((point) => {
        const from = point.at.getTime();
        const to = endOf(point);
        if (!spans.some((s) => s.from < to && s.to >= from)) return true;
        // The capture sampled this interval: its samples stand, unless the interval rose to the floor and none of them did,
        // nor the capture's nearest samples on either side of it, when the stall fell between them and the interval stands
        // for its minutes. A stall that began after the interval's last sample, or ended before its first, shows in the
        // sample beside it (the review of 4e2c65ed: a stall from 16:19:50 read as a rise from 16:15:00 without that).
        if (point.value < floor) return false;
        if (own.some((p) => p.at.getTime() >= from && p.at.getTime() < to && p.value >= floor)) return false;
        const before = own.filter((p) => p.at.getTime() < from && from - p.at.getTime() <= CAPTURE_GAP_MS).pop();
        const after = own.find((p) => p.at.getTime() >= to && p.at.getTime() - to <= CAPTURE_GAP_MS);
        const between = (before === undefined || before.value < floor) && (after === undefined || after.value < floor);
        if (between) missed.push(point);
        return between;
    });
    const standsFor = (p: LagPoint) => missed.some((m) => p.at.getTime() >= m.at.getTime() && p.at.getTime() < endOf(m));
    return { points: [...own.filter((p) => !standsFor(p)), ...kept].sort((a, b) => a.at.getTime() - b.at.getTime()), monitor: all };
}

/**
 * The rise around `at`: back to where the lag was last under `floor`, forward to its peak and its recovery. When the lag at
 * `at` is under the floor, the rise is the last one in the series before it at the floor or above, else the first after
 * it; with none, there's no lag to explain, and this returns null (the review of 34a9732: it once called a 0.6 s point,
 * minutes after the real spike, a rise). An Azure Monitor point stands for its whole interval. A rise that hasn't
 * recovered in these minutes keeps every point it has (live, 2026-11-21: it once ended at its first peak).
 */
export function lagRise(series: LagSeries, at: Date, floor = 5): LagRise | null {
    const lag = series.points;
    if (lag.length === 0) return null;
    let i = lag.findIndex((p) => endOf(p) >= at.getTime() - 60_000);
    if (i < 0) i = lag.length - 1;
    if (lag[i].value < floor) {
        let before = i;
        while (before >= 0 && lag[before].value < floor) before--;
        const after = lag.findIndex((p, k) => k > i && p.value >= floor);
        if (before >= 0) i = before;
        else if (after >= 0) i = after;
        else return null;
    }
    let s = i;
    while (s > 0 && lag[s - 1].value >= floor) s--;
    let e = s;
    while (e + 1 < lag.length && lag[e + 1].value >= floor) e++;
    let p = s;
    for (let k = s; k <= e; k++) if (lag[k].value > lag[p].value) p = k;
    const recovered = e + 1 < lag.length ? lag[e + 1] : undefined;
    const points = lag.slice(Math.max(0, s - 1), recovered ? e + 2 : e + 1);
    // A rate needs two points that rise, read at their instants: one point, a flat run, or Azure Monitor's maximum over
    // intervals longer than a minute says nothing about how fast replay fell behind.
    const rising = lag.slice(s, p + 1).filter((q) => !coarse(q));
    const first = rising[0];
    const last = rising[rising.length - 1];
    const slope = rising.length >= 2 && last.value > first.value ? (last.value - first.value) / ((last.at.getTime() - first.at.getTime()) / 1000) : null;
    const run = lag.slice(s, e + 1);
    const sinceOf = (q: LagPoint) => q.at.getTime() - q.value * 1000;
    const sampled = run.filter((q) => q.source === "RCA Replica");
    return {
        start: lag[s].at,
        peak: lag[p],
        recovered,
        slope: slope === null ? null : Math.round(slope * 100) / 100,
        points,
        source: lag[p].source,
        stalledSince: new Date(Math.min(...run.map(sinceOf))),
        ...(sampled.length ? { lastReplay: new Date(Math.min(...sampled.map(sinceOf))) } : {}),
        end: recovered ? recovered.at : new Date(endOf(lag[e])),
    };
}

/** True when the rise starts right after a gap in the series (a stopped replica coming back), as replicaCatchUp decides. */
export function isRestartCatchUp(rise: LagRise, series: readonly LagPoint[]): boolean {
    const first = series.findIndex((p) => p.at.getTime() === rise.start.getTime());
    if (first <= 0) return false;
    const gapMin = (series[first].at.getTime() - series[first - 1].at.getTime()) / 60000;
    return gapMin >= RESTART_GAP_MINUTES && rise.peak.value >= 0.5 * gapMin * 60;
}

/** At most one point a minute (its highest), so a 5-second series reads like the metric's. */
function perMinute(points: readonly LagPoint[]): LagPoint[] {
    const out = new Map<number, LagPoint>();
    for (const p of points) {
        const minute = Math.floor(p.at.getTime() / 60000);
        const best = out.get(minute);
        if (!best || p.value > best.value) out.set(minute, p);
    }
    return [...out.values()].sort((a, b) => a.at.getTime() - b.at.getTime());
}

export interface ReplicaAnalysis {
    rise: LagRise | null;
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    notCaptured: string[];
    /**
     * The minutes the rise and its cause take: from a minute before replay last advanced to a minute after the rise ended.
     * Read whole, they give the same answer however the rise is asked about (the RCA view by its episode, the chat by a
     * time in it). Null without a rise.
     */
    reads: { from: Date; to: Date } | null;
}

/** What a point measures, in words. */
function nameOf(p: LagPoint): string {
    if (p.source === "RCA Replica") return "The replica's time since its last replay";
    return coarse(p) ? `Read Replica Lag (its highest value in each ${minutesOf(p)}-minute interval)` : "Read Replica Lag";
}

/** When a point's value was: at an instant, or somewhere in an Azure Monitor interval coarser than a minute. */
function when(p: LagPoint): string {
    return coarse(p) ? `in the ${minutesOf(p)} minutes from ${hhmmss(p.at)} UTC` : `at ${hhmmss(p.at)} UTC`;
}

/** A point as evidence: "Read Replica Lag 178 s, its highest from 16:15 to 16:20 UTC" for an interval. */
function refText(p: LagPoint): string {
    if (p.source === "RCA Replica") return `The replica's time since its last replay ${round1(p.value)} s`;
    return coarse(p) ? `Read Replica Lag ${round1(p.value)} s, its highest from ${hhmmss(p.at).slice(0, 5)} to ${hhmmss(new Date(endOf(p))).slice(0, 5)} UTC` : `Read Replica Lag ${round1(p.value)} s`;
}

export function analyzeReplicaLag(input: { at: Date; metrics: readonly MetricPoint[]; samples: readonly ReplicaSample[]; events: readonly EventRow[] }): ReplicaAnalysis {
    const notCaptured: string[] = [];
    const series = lagSeries(input.metrics, input.samples);
    if (series.points.length === 0) {
        return { rise: null, findings: [], rootCause: null, recommendations: [], nextSteps: ["Run the control notebook's Run all with the read replica (it's created for each session)."], notCaptured: ["Neither Read Replica Lag nor the replica's own samples are in the history for this time."], reads: null };
    }
    const ev = (table: string, at: Date, text: string): EvidenceRef => ({ table, at: iso(at), target: "T4-replica", text });
    const refOf = (p: LagPoint) => ev(p.source, p.at, refText(p));
    const rise = lagRise(series, input.at);
    if (!rise) {
        // Every point under the floor: the replica kept up, and there's no rise to explain.
        const top = series.points.reduce((a, b) => (b.value > a.value ? b : a));
        const refs = perMinute(series.points).map(refOf);
        const statement = `${nameOf(top)} stayed under 5 s in these minutes, at most ${round1(top.value)} s ${when(top)}: the replica kept up, so there's no lag to explain.`;
        return {
            rise: null,
            findings: [{ ruleId: "REPL-NO-LAG", target: "T4-replica", severity: "info", title: "No read replica lag", detail: statement, evidence: refs }],
            rootCause: { statement, confidence: "high", ruleIds: ["REPL-NO-LAG"], evidence: refs },
            recommendations: [],
            nextSteps: ["Ask about the minutes when Database Hub's Read replica lag chart rose, or widen the window."],
            notCaptured,
            reads: null,
        };
    }
    const shown = perMinute(rise.points);
    const lagRefs = shown.map(refOf);
    // Where the capture's own samples tell the rise, Azure Monitor's intervals that show it are cited too: Database Hub charts them.
    const charted = rise.source === "RCA Replica" ? series.monitor.filter((m) => m.value >= 5 && m.at.getTime() <= rise.end.getTime() && endOf(m) > rise.stalledSince.getTime()).map(refOf) : [];
    const values = shown.map((p) => `${round1(p.value)} s`).join(", ");
    const back = rise.recovered ? `${rise.source === "RCA Replica" ? "," : ""} and was back to ${round1(rise.recovered.value)} s ${when(rise.recovered)}` : "";
    const grew = rise.slope !== null ? `; it grew ${rise.slope} s per second` : "";
    const since = rise.source === "RCA Replica" && rise.lastReplay ? `, counting from its last replay at ${hhmmss(rise.lastReplay)} UTC` : "";
    const shape = coarse(rise.peak)
        ? `${nameOf(rise.peak)} reached ${round1(rise.peak.value)} s ${when(rise.peak)} (${values})${back}${grew}`
        : `${nameOf(rise.peak)} rose from ${hhmmss(rise.start)} to ${round1(rise.peak.value)} s ${when(rise.peak)} (${values})${since}${back}${grew}`;
    if (coarse(rise.peak)) notCaptured.push(`Azure Monitor's Read Replica Lag is in ${minutesOf(rise.peak)}-minute intervals here, the highest value in each, so when the lag rose and peaked is known to the interval only.`);
    const from = rise.stalledSince.getTime() - 60_000;
    const to = rise.end.getTime() + 60_000;
    const reads = { from: new Date(from), to: new Date(to) };

    if (isRestartCatchUp(rise, series.points)) {
        const statement = `${shape}, right after a gap in the series: the replica was stopped, and the metric counts the time since its last replayed transaction from before the stop. This is its catch-up, not replication lag.`;
        return { rise, findings: [{ ruleId: "REPL-CATCHUP", target: "T4-replica", severity: "info", title: "Catch-up after a restart", detail: statement, evidence: lagRefs }], rootCause: { statement, confidence: "high", ruleIds: ["REPL-CATCHUP"], evidence: lagRefs }, recommendations: [], nextSteps: ["Read the lag from the first points after the replica is back in recovery only."], notCaptured, reads };
    }

    const inWindow = input.samples.filter((s) => s.at.getTime() >= from && s.at.getTime() <= to);
    const replica = inWindow.filter((s) => s.side === "replica");
    const primary = inWindow.filter((s) => s.side === "primary");
    const conflicts = replica.filter((s) => s.conflictRelation && s.conflictHolder !== undefined);
    const conflict = conflicts[0];
    const waitStart = conflicts.find((s) => s.conflictWaitStart)?.conflictWaitStart;
    const backlog = Math.max(0, ...replica.map((s) => s.receivedNotReplayedBytes ?? 0));
    const maxWriteLag = Math.max(0, ...primary.map((s) => Math.max(s.writeLagS ?? 0, s.flushLagS ?? 0)));
    const maxSendGap = Math.max(0, ...primary.map((s) => s.sendGapBytes ?? 0));
    const walRate = primary.filter((s) => s.walBytesPerS !== undefined).map((s) => s.walBytesPerS as number);
    // The median, so a short burst (the primary taking its lock) doesn't stand for the rate the replica received.
    const avgWal = walRate.length ? Math.round([...walRate].sort((a, b) => a - b)[Math.floor(walRate.length / 2)]) : null;
    const cancels = Math.max(0, ...replica.map((s) => s.conflictsCancelled ?? 0));
    const delay = replica.find((s) => s.maxStandbyStreamingDelayS !== undefined)?.maxStandbyStreamingDelayS;
    // The observer's own episode for the stall, as evidence of when it watched closely; it never names a cause.
    const watched = input.events.filter((e) => e.kind === "capture" && e.target === "T4-replica" && e.at.getTime() >= from - 120_000 && e.at.getTime() <= to + 120_000);
    const watchedRefs = watched.slice(0, 2).map((e) => ({ table: "RCA Events", at: iso(e.at), target: e.target, text: `capture ${e.name}: ${e.detail}` }));

    if (replica.length === 0) notCaptured.push("The replica's replay state (RCA Replica) wasn't captured for these minutes: the explanation rests on the metric's shape alone.");

    let ruleId: string;
    let statement: string;
    let confidence: Confidence;
    let evidence: EvidenceRef[] = [...lagRefs, ...charted];
    let ids: string[] = [];
    if (conflict) {
        ruleId = "REPL-REPLAY-CONFLICT";
        const holder = `session ${conflict.conflictHolder}${conflict.conflictHolderProgram ? `, ${conflict.conflictHolderProgram}` : ""}${conflict.conflictHolderStatement ? `: ${conflict.conflictHolderStatement}` : ""}`;
        const since = waitStart ? ` from ${hhmmss(waitStart)} UTC` : "";
        statement =
            `${shape}: replay stood still. The replica kept receiving WAL (${backlog} bytes received but not replayed) while its startup process waited for ${conflict.conflictWantedMode ?? "a lock"} on ${conflict.conflictRelation}${since}, which a query on the replica held (${conflict.conflictHolderMode ?? "a lock"}; ${holder}). ` +
            `The primary shipped normally (write and flush lag at most ${maxWriteLag} s${avgWal !== null ? `, WAL about ${avgWal} bytes/s` : ""}), so neither the network nor the write volume caused it. ` +
            `Replay may wait up to max_standby_streaming_delay${delay !== undefined ? ` (${delay} s)` : ""}; ${cancels > 0 ? `recovery cancelled ${plural(cancels, "replica query", "replica queries")} (SQLSTATE 40001)` : "the query ended before that, so nothing was cancelled"}, and replay caught up.`;
        confidence = conflicts.length >= 2 ? "high" : "medium";
        evidence = [...lagRefs, ...charted, ev("RCA Replica", conflict.at, `startup waits ${conflict.conflictWantedMode} on ${conflict.conflictRelation}, held ${conflict.conflictHolderMode} by session ${conflict.conflictHolder}`), ...watchedRefs];
        ids = ["RPL-SHORT-REPORTS", "RPL-STANDBY-DELAY", "RPL-NO-EXCLUSIVE"];
    } else if (rise.source === "Telemetry Snapshots" && input.samples.some((s) => s.side === "replica" && s.sinceLastReplayS !== undefined && s.at >= rise.peak.at && s.at.getTime() < endOf(rise.peak))) {
        // Azure Monitor's interval rose and the capture's samples in it didn't: the stall fell between them, so they can't explain it.
        ruleId = "REPL-UNEXPLAINED";
        statement = `${shape}. The capture's own samples on the replica in that interval stayed under 5 s, so the stall fell between them, and nothing captured says why.`;
        confidence = "low";
    } else if (replica.length > 0 && (maxSendGap > 1_000_000 || maxWriteLag > 5)) {
        ruleId = "REPL-SHIPPING";
        statement = `${shape}: the WAL didn't reach the replica in time (send gap up to ${maxSendGap} bytes, write or flush lag up to ${maxWriteLag} s).`;
        confidence = "medium";
        ids = ["RPL-SHORT-REPORTS"];
    } else if (replica.length > 0 && backlog === 0 && (avgWal ?? 0) < 50) {
        ruleId = "REPL-IDLE-PRIMARY";
        statement = `${shape}, but the replica had nothing to replay: the primary committed nothing, and the metric counts the time since the last replayed transaction.`;
        confidence = "high";
    } else if (replica.length > 0) {
        ruleId = "REPL-REPLAY-SLOW";
        statement = `${shape}: replay advanced slower than WAL arrived (${backlog} bytes behind, WAL about ${avgWal ?? "?"} bytes/s).`;
        confidence = "medium";
        ids = ["RPL-SHORT-REPORTS"];
    } else {
        const stood = rise.slope !== null && rise.slope >= 0.8;
        ruleId = stood ? "REPL-REPLAY-STALLED" : "REPL-UNEXPLAINED";
        const unknown = coarse(rise.peak) ? `Azure Monitor's ${minutesOf(rise.peak)}-minute highest values can't say whether replay stood still or slowed` : "One point can't say whether replay stood still or slowed";
        statement = `${shape}. ${rise.slope === null ? unknown : stood ? "Replay stood still" : "Replay slowed"}, and nothing captured says why.`;
        confidence = "low";
    }
    return {
        rise,
        findings: [{ ruleId, target: "T4-replica", severity: rise.peak.value >= 60 ? "critical" : "warning", title: `Read replica lag ${round1(rise.peak.value)} s ${when(rise.peak)}`, detail: statement, evidence }],
        rootCause: { statement, confidence, ruleIds: [ruleId], evidence },
        recommendations: recommend(...ids),
        nextSteps:
            ruleId === "REPL-REPLAY-CONFLICT"
                ? ["Find the reporting queries that run on the replica while the primary takes ACCESS EXCLUSIVE locks (DDL, TRUNCATE, LOCK TABLE).", "Decide max_standby_streaming_delay: freshness (lower, cancels reports) or long reports (higher, more lag).", "Compare with Database Hub's Read replica lag chart for T4's replica."]
                : ["Compare with Database Hub's Read replica lag chart and the replica's CPU and IOPS for the same minutes."],
        notCaptured,
        reads,
    };
}
