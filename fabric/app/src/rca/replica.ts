// Why T4's read replica lagged at a given time. Azure Monitor's Read Replica Lag (physical_replication_delay_in_seconds)
// is the time since the replica last replayed a transaction (ADR 0025), so it grows by a second every second whenever
// replay doesn't advance, whatever the reason. The observer measures the same on the replica (since_last_replayed_s),
// every 30 s and every 5 s while replay stands still: its samples tell the rise wherever it took them, and Azure
// Monitor's, the highest value in each interval, the minutes it didn't. The rules separate the reasons:
//   REPL-CATCHUP          the replica's first points after a stop: catch-up, not lag (the app's replicaCatchUp)
//   REPL-REPLAY-CONFLICT  WAL arrives but replay waits on a lock a replica query holds (hot standby conflict)
//   REPL-REPLAY-SLOW      replay advances, slower than WAL arrives: WAL received but not replayed, in the stall's samples
//   REPL-SHIPPING         the WAL isn't reaching the replica (send gap, write or flush lag)
//   REPL-IDLE-PRIMARY     nothing to replay: the primary committed nothing, so "time since the last replay" grows
//   REPL-REPLAY-STALLED   replay stood still, and nothing captured says why
//   REPL-NO-LAG           the lag stayed under 5 s in the window: nothing to explain
// The capture's replay state backs SLOW, SHIPPING, and IDLE-PRIMARY only from its own samples of the stall; a rise they're
// only beside reads from its shape (REPL-REPLAY-STALLED or REPL-UNEXPLAINED).
// https://www.postgresql.org/docs/18/hot-standby.html#HOT-STANDBY-CONFLICT, https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas

import { recommend } from "./catalog";
import { asWholeReadings, hhmmss, iso, plural, type Confidence, type EventRow, type EvidenceRef, type Finding, type MetricPoint, type Recommendation, type ReplicaSample } from "./types";

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
    /** Azure Monitor's span: the value is the highest from `at` to `at` plus this. Absent for the capture's samples. */
    intervalMs?: number;
    /** Its save's interval, which a remainder's span is only part of: what the value is the highest of (the shared finestPerInterval's grains). */
    grainMs?: number;
    /** An Azure Monitor point whose interval the read can't tell (MetricPoint.intervalUnknown): the highest of an interval from `at`, of a length not known here. */
    intervalUnknown?: boolean;
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
/** When replay last advanced, by a point: its time less its lag (for an Azure Monitor interval, the earliest it can be). */
const sinceOf = (p: LagPoint) => p.at.getTime() - p.value * 1000;
/** Azure Monitor's interval in minutes, for the words "its highest value in each 15-minute interval": its save's (the grain). */
const minutesOf = (p: LagPoint) => Math.round((p.grainMs ?? p.intervalMs ?? 0) / 60_000);
/** "in the 3 minutes from 16:57:00 UTC", or "in the interval from 15:00:00 UTC" when its length isn't known in these minutes (the review of c4c63abe). */
const minutesFrom = (p: LagPoint) => (p.intervalUnknown ? `in the interval from ${hhmmss(p.at)} UTC` : `in the ${spanOf(p)} minutes from ${hhmmss(p.at)} UTC`);
/** The minutes a point spans, for "in the 3 minutes from 16:57:00": a remainder of a coarser point spans only part of its interval. */
const spanOf = (p: LagPoint) => Math.round((p.intervalMs ?? 0) / 60_000);
/** Coarser than a minute: Azure Monitor's value is its interval's highest, not the lag at its start. */
const coarse = (p: LagPoint) => p.intervalUnknown === true || (p.grainMs ?? p.intervalMs ?? 0) > 60_000;
/**
 * Part of its save's interval: a remainder that finer points leave of it, or one its save's window cuts. Its value is the
 * highest in its own minutes, which its words give, never its save's interval (Final tests' check of ddebd4c3, F4: "its
 * highest value in each 15-minute interval … in the 3 minutes from 16:57:00").
 */
const partial = (p: LagPoint) => coarse(p) && !p.intervalUnknown && spanOf(p) < minutesOf(p);

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
    // A split point's pieces as its one whole reading, the highest over its save's whole interval: each piece's value is
    // only an upper bound of its own stretch (the review of c4c63abe).
    const monitor = asWholeReadings(metrics.filter((m) => m.target === "T4-replica" && m.metric === LAG_METRIC)).filter((m): m is MetricPoint & { value: number } => m.value !== null);
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
    // A point whose interval the read can't tell stands for no more than its start, never the series' step or a minute.
    const all = monitor.map((m): LagPoint => (m.intervalUnknown ? { at: m.at, value: m.value, source: "Telemetry Snapshots", intervalMs: 0, intervalUnknown: true } : { at: m.at, value: m.value, source: "Telemetry Snapshots", intervalMs: m.intervalMs ?? grain, grainMs: m.grainMs ?? m.intervalMs ?? grain }));
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
 * The rise around `at`, from the series' last point at or before it (an Azure Monitor point stands for its whole interval):
 * back to where the lag was last under `floor`, forward to its peak and its recovery. Under the floor there, `at` can still
 * be in a stall that began after that point: the next point at the floor is its rise when its last replay was at or
 * before `at` (the review of ebd1c6c3: asked at 16:21:00, within the second stall, it explained the blip before it, from
 * a sample at 16:20:42 of 0.3 s, though the next, 21.6 s at 16:21:12, counted from a last replay at 16:20:51). Otherwise
 * the rise is the last one before it at the floor or above, else the first after it; with none, there's no lag to
 * explain, and this returns null (the review of 34a9732: it once called a 0.6 s point, minutes after the real spike, a
 * rise). A rise that hasn't recovered in these minutes keeps every point it has (live, 2026-11-21: it once ended at its
 * first peak).
 */
export function lagRise(series: LagSeries, at: Date, floor = 5): LagRise | null {
    const lag = series.points;
    if (lag.length === 0) return null;
    const t = at.getTime();
    let i = 0;
    for (let k = 0; k < lag.length && lag[k].at.getTime() <= t; k++) i = k;
    if (lag[i].value < floor) {
        const after = lag.findIndex((p, k) => k > i && p.value >= floor);
        let before = i;
        while (before >= 0 && lag[before].value < floor) before--;
        if (after >= 0 && sinceOf(lag[after]) <= t) i = after;
        else if (before >= 0) i = before;
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
    if (p.intervalUnknown) return "Read Replica Lag (its highest value in each interval of its save, whose length isn't known in these minutes)";
    if (partial(p)) return "Read Replica Lag (its highest value in each interval)";
    return coarse(p) ? `Read Replica Lag (its highest value in each ${minutesOf(p)}-minute interval)` : "Read Replica Lag";
}

/** When a point's value was: at an instant, or somewhere in what an Azure Monitor point coarser than a minute spans. */
function when(p: LagPoint): string {
    return coarse(p) ? minutesFrom(p) : `at ${hhmmss(p.at)} UTC`;
}

/** A point as evidence: "Read Replica Lag 178 s, its highest from 16:15 to 16:20 UTC" for an interval. */
function refText(p: LagPoint): string {
    if (p.source === "RCA Replica") return `The replica's time since its last replay ${round1(p.value)} s`;
    if (p.intervalUnknown) return `Read Replica Lag ${round1(p.value)} s, its highest in the interval from ${hhmmss(p.at).slice(0, 5)} UTC, whose length isn't known in these minutes`;
    return coarse(p) ? `Read Replica Lag ${round1(p.value)} s, its highest from ${hhmmss(p.at).slice(0, 5)} to ${hhmmss(new Date(endOf(p))).slice(0, 5)} UTC` : `Read Replica Lag ${round1(p.value)} s`;
}

/** Where the capture's samples on the replica are, beside a rise that none of them is from (F4). */
function sampledBeside(replica: readonly ReplicaSample[], rise: LagRise): string {
    const before = replica.filter((s) => s.at < rise.start).reduce<ReplicaSample | null>((a, s) => (a && a.at >= s.at ? a : s), null);
    const after = replica.filter((s) => s.at >= rise.end).reduce<ReplicaSample | null>((a, s) => (a && a.at <= s.at ? a : s), null);
    const where =
        before && after
            ? `stop at ${hhmmss(before.at)} UTC, before this rise, and start again at ${hhmmss(after.at)} UTC, after it`
            : before
              ? `end at ${hhmmss(before.at)} UTC, before this rise`
              : after
                ? `start at ${hhmmss(after.at)} UTC, after this rise`
                : "in these minutes aren't from the stall itself";
    return `The capture's own samples on the replica (RCA Replica) ${where}, so its replay state during the rise wasn't captured: the explanation rests on the metric's shape alone.`;
}

export function analyzeReplicaLag(input: { at: Date; metrics: readonly MetricPoint[]; samples: readonly ReplicaSample[]; events: readonly EventRow[]; askedTo?: Date }): ReplicaAnalysis {
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
    // A rise whose first point is one of Azure Monitor's intervals (the capture started, or resumed, partway through the
    // stall) starts at the capture's first sample in it, or is said as that interval (the re-review of bb70161f: it once
    // "rose from 16:10:00", an interval's start, counting from a last replay at 16:13:00).
    const startPoint = rise.points.find((p) => p.at.getTime() === rise.start.getTime());
    const firstSample = rise.points.find((p) => p.source === "RCA Replica" && p.at >= rise.start && p.value >= 5);
    const rose = startPoint && coarse(startPoint) ? (firstSample ? `rose from ${hhmmss(firstSample.at)}` : `rose ${minutesFrom(startPoint)}`) : `rose from ${hhmmss(rise.start)}`;
    // The rise is read whole, past the minutes asked about when it runs on after them, and says so (the review of 2e19adfc:
    // asked about 16:10 to 16:18, its episode read "peak 96.6 s at 16:17:57", and its cause "176.7 s at 16:19:17").
    const past = input.askedTo && rise.end > input.askedTo ? ` (read past the minutes asked about, which end at ${hhmmss(input.askedTo)} UTC, to ${rise.recovered ? "its recovery at " : ""}${hhmmss(rise.end)} UTC)` : "";
    const shape = coarse(rise.peak)
        ? `${nameOf(rise.peak)} reached ${round1(rise.peak.value)} s ${when(rise.peak)} (${values})${back}${grew}${past}`
        : `${nameOf(rise.peak)} ${rose} to ${round1(rise.peak.value)} s ${when(rise.peak)} (${values})${since}${back}${grew}${past}`;
    if (coarse(rise.peak)) {
        notCaptured.push(
            rise.peak.intervalUnknown
                ? "Azure Monitor's Read Replica Lag is the highest value in each interval of its save here, and these minutes hold too few of its points to tell how long that is, so when the lag rose and peaked isn't known within it."
                : partial(rise.peak)
                  ? `Azure Monitor's Read Replica Lag here is its highest value ${minutesFrom(rise.peak)}, so when the lag rose and peaked is known to those ${spanOf(rise.peak)} minutes only.`
                  : `Azure Monitor's Read Replica Lag is in ${minutesOf(rise.peak)}-minute intervals here, the highest value in each, so when the lag rose and peaked is known to the interval only.`,
        );
    }
    const from = rise.stalledSince.getTime() - 60_000;
    const to = rise.end.getTime() + 60_000;
    const reads = { from: new Date(from), to: new Date(to) };

    if (isRestartCatchUp(rise, series.points)) {
        const statement = `${shape}, right after a gap in the series: the replica was stopped, and the metric counts the time since its last replayed transaction from before the stop. This is its catch-up, not replication lag.`;
        return { rise, findings: [{ ruleId: "REPL-CATCHUP", target: "T4-replica", severity: "info", title: "Catch-up after a restart", detail: statement, evidence: lagRefs }], rootCause: { statement, confidence: "high", ruleIds: ["REPL-CATCHUP"], evidence: lagRefs }, recommendations: [], nextSteps: ["Read the lag from the first points after the replica is back in recovery only."], notCaptured, reads };
    }

    const inWindow = input.samples.filter((s) => s.at.getTime() >= from && s.at.getTime() <= to);
    const replica = inWindow.filter((s) => s.side === "replica");
    // The capture's samples say what replay did only when they're from the stall itself (the rise's own samples, from its
    // last replay on). Final tests' check of ddebd4c3 (F4): Azure Monitor's 68 s from 18:54, after the capture's last sample
    // at 18:53:23 (0.1 s since a replay), read as replay slower than WAL, "0 bytes behind", from that sample's minutes.
    const sawStall = rise.lastReplay !== undefined;
    // The figures a cause rests on, then, are the stall's own too: from replay's last advance to its recovery, not the
    // recovery's sample, by which replay had resumed, or to its last point when it hadn't recovered (the review of 921d3097:
    // a sample a minute before the stall, with 512 bytes in flight from a busy primary, read as slow replay "512 bytes
    // behind, WAL about 0 bytes/s" for a stall whose own samples held 0 behind, from an idle primary).
    const beforeEnd = (s: { at: Date }) => (rise.recovered ? s.at < rise.end : s.at <= rise.end);
    const ofStall = (s: ReplicaSample) => s.at.getTime() >= rise.lastReplay!.getTime() && beforeEnd(s);
    const figures = sawStall ? inWindow.filter(ofStall) : inWindow;
    const figuresReplica = figures.filter((s) => s.side === "replica");
    const figuresPrimary = figures.filter((s) => s.side === "primary");
    // A conflict is this rise's only from when its replay stood still, since the minute before it can hold the last stall's
    // (the review of ebd1c6c3), and only up to its end, as its figures are, since the minute after it can hold the next
    // one's (the review of fb144473: a lock the replica took 16 s after this stall's recovery was named as its cause).
    const stoodFrom = (rise.lastReplay ?? rise.stalledSince).getTime();
    const conflicts = replica.filter((s) => s.conflictRelation && s.conflictHolder !== undefined && s.at.getTime() >= stoodFrom && beforeEnd(s));
    const conflict = conflicts[0];
    const waitStart = conflicts.find((s) => s.conflictWaitStart)?.conflictWaitStart;
    const backlog = Math.max(0, ...figuresReplica.map((s) => s.receivedNotReplayedBytes ?? 0));
    const maxWriteLag = Math.max(0, ...figuresPrimary.map((s) => Math.max(s.writeLagS ?? 0, s.flushLagS ?? 0)));
    const maxSendGap = Math.max(0, ...figuresPrimary.map((s) => s.sendGapBytes ?? 0));
    const walRate = figuresPrimary.filter((s) => s.walBytesPerS !== undefined).map((s) => s.walBytesPerS as number);
    // The median, so a short burst (the primary taking its lock) doesn't stand for the rate the replica received.
    const avgWal = walRate.length ? Math.round([...walRate].sort((a, b) => a - b)[Math.floor(walRate.length / 2)]) : null;
    // The queries recovery cancelled: pg_stat_database_conflicts' deltas since the reading before, so they add up. A stall's
    // cancel ends it, so the capture records it at or after the stall's recovery, and the next stall's only after it has
    // read that one at its level. So this stall's are those recorded after its own first reading at its level, which is
    // after its last replay too, through its recovery, up to the next rise's first point at its level, and within the
    // minutes read: never an earlier stall's, nor the next one's (the review of fb144473: a cancel recorded 20 s before
    // this stall's last replay read as this one's). From its last replay alone, B's blip at 16:19:37 would share the first
    // stall's reading at 16:19:32.827, since its own last replay was at 16:19:32.69.
    const nextRise = rise.recovered ? series.points.find((p) => p.at > rise.end && p.value >= 5) : undefined;
    const cancelsTo = nextRise ? Math.min(nextRise.at.getTime(), to) : rise.recovered ? to : rise.end.getTime();
    const cancelsAfter = Math.max(stoodFrom, rise.start.getTime());
    const cancelReadings = replica.filter((s) => s.conflictsCancelled !== undefined && s.at.getTime() > cancelsAfter && s.at.getTime() <= cancelsTo);
    const cancels = cancelReadings.reduce((n, s) => n + (s.conflictsCancelled ?? 0), 0);
    // Whether recovery cancelled the query is known only from a reading at or after the recovery, where that cancel is recorded.
    const cancelRead = !!rise.recovered && cancelReadings.some((s) => s.at >= rise.end);
    const delay = replica.find((s) => s.maxStandbyStreamingDelayS !== undefined)?.maxStandbyStreamingDelayS;
    // The capture's own episode for the stall, as evidence of when it watched closely; it never names a cause. Its own:
    // from the stall's first reading at its level, since the capture escalates no earlier, to the episode's relax at or
    // after its recovery (B's second stall, from 16:20:51, cited the first one's relax at 16:20:03).
    const captureEvents = input.events
        .filter((e) => e.kind === "capture" && e.target === "T4-replica" && e.at.getTime() >= from - 120_000 && e.at.getTime() <= to + 120_000)
        .sort((a, b) => a.at.getTime() - b.at.getTime());
    const relaxed = captureEvents.find((e) => e.name === "relaxed" && e.at >= rise.end);
    const watched = captureEvents.filter((e) => e.at >= rise.start && (!relaxed || e.at <= relaxed.at));
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
        // How the primary shipped, only from its own samples in these figures' minutes: with none, "at most 0 s" would rest
        // on no sample at all.
        const shipped =
            figuresPrimary.length > 0
                ? `The primary shipped normally (write and flush lag at most ${maxWriteLag} s${avgWal !== null ? `, WAL about ${avgWal} bytes/s` : ""}), so neither the network nor the write volume caused it. `
                : "The primary's side wasn't sampled during the stall, so whether it shipped normally isn't known. ";
        // How it ended, only as far as the capture's readings show it: a stall that hadn't recovered may still have its
        // query cancelled, and one the capture didn't read from its recovery on says nothing either way.
        const cancelled = plural(cancels, "replica query", "replica queries");
        const ended = !rise.recovered
            ? cancels > 0
                ? `recovery cancelled ${cancelled} (SQLSTATE 40001) during it, and replay hadn't caught up by the end of the minutes read`
                : "replay hadn't caught up by the end of the minutes read, so whether the query ended or recovery cancelled it isn't known"
            : !cancelRead
              ? "the capture has no reading of the replica's cancels from its recovery on, so whether recovery cancelled the query isn't known, and replay caught up"
              : cancels > 0
                ? `recovery cancelled ${cancelled} (SQLSTATE 40001), and replay caught up`
                : "the query ended before that, so nothing was cancelled, and replay caught up";
        statement =
            `${shape}: replay stood still. The replica kept receiving WAL (${backlog} bytes received but not replayed) while its startup process waited for ${conflict.conflictWantedMode ?? "a lock"} on ${conflict.conflictRelation}${since}, which a query on the replica held (${conflict.conflictHolderMode ?? "a lock"}; ${holder}). ` +
            shipped +
            `Replay may wait up to max_standby_streaming_delay${delay !== undefined ? ` (${delay} s)` : ""}; ${ended}.`;
        confidence = conflicts.length >= 2 ? "high" : "medium";
        evidence = [...lagRefs, ...charted, ev("RCA Replica", conflict.at, `startup waits ${conflict.conflictWantedMode} on ${conflict.conflictRelation}, held ${conflict.conflictHolderMode} by session ${conflict.conflictHolder}`), ...watchedRefs];
        ids = ["RPL-SHORT-REPORTS", "RPL-STANDBY-DELAY", "RPL-NO-EXCLUSIVE"];
    } else if (rise.source === "Telemetry Snapshots" && input.samples.some((s) => s.side === "replica" && s.sinceLastReplayS !== undefined && s.at >= rise.peak.at && s.at.getTime() < endOf(rise.peak))) {
        // Azure Monitor's interval rose and the capture's samples in it didn't: the stall fell between them, so they can't explain it.
        ruleId = "REPL-UNEXPLAINED";
        statement = `${shape}. The capture's own samples on the replica in that interval stayed under 5 s, so the stall fell between them, and nothing captured says why.`;
        confidence = "low";
    } else if (sawStall && (maxSendGap > 1_000_000 || maxWriteLag > 5)) {
        ruleId = "REPL-SHIPPING";
        statement = `${shape}: the WAL didn't reach the replica in time (send gap up to ${maxSendGap} bytes, write or flush lag up to ${maxWriteLag} s).`;
        confidence = "medium";
        ids = ["RPL-SHORT-REPORTS"];
    } else if (sawStall && backlog === 0 && avgWal !== null && avgWal < 50) {
        // Only from the primary's own samples in the stall: with none, what it committed then isn't known.
        ruleId = "REPL-IDLE-PRIMARY";
        statement = `${shape}, but the replica had nothing to replay: the primary committed nothing, and the metric counts the time since the last replayed transaction.`;
        confidence = "high";
    } else if (sawStall && backlog > 0) {
        // Replay fell behind only with WAL received but not replayed: with none, it had replayed all it received.
        ruleId = "REPL-REPLAY-SLOW";
        statement = `${shape}: replay advanced slower than WAL arrived (${backlog} bytes behind, WAL about ${avgWal ?? "?"} bytes/s).`;
        confidence = "medium";
        ids = ["RPL-SHORT-REPORTS"];
    } else {
        const stood = rise.slope !== null && rise.slope >= 0.8;
        ruleId = stood ? "REPL-REPLAY-STALLED" : "REPL-UNEXPLAINED";
        const unknown = !coarse(rise.peak)
            ? "One point can't say whether replay stood still or slowed"
            : partial(rise.peak)
              ? `Azure Monitor's highest value in those ${spanOf(rise.peak)} minutes can't say whether replay stood still or slowed`
              : `Azure Monitor's ${minutesOf(rise.peak)}-minute highest values can't say whether replay stood still or slowed`;
        statement = `${shape}. ${rise.slope === null ? unknown : stood ? "Replay stood still" : "Replay slowed"}, and nothing captured says why.`;
        confidence = "low";
        if (!sawStall && replica.length > 0) notCaptured.push(sampledBeside(replica, rise));
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
