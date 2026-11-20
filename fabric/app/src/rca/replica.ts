// Why T4's read replica lagged at a given time. Azure Monitor's Read Replica Lag (physical_replication_delay_in_seconds)
// is the time since the replica last replayed a transaction (ADR 0025), so it grows by a second every second whenever
// replay doesn't advance, whatever the reason. The observer measures the same on the replica (since_last_replayed_s), so
// either one shows the rise. The rules separate the reasons:
//   REPL-CATCHUP          the replica's first points after a stop: catch-up, not lag (the app's replicaCatchUp)
//   REPL-REPLAY-CONFLICT  WAL arrives but replay waits on a lock a replica query holds (hot standby conflict)
//   REPL-REPLAY-SLOW      replay advances, slower than WAL arrives
//   REPL-SHIPPING         the WAL isn't reaching the replica (send gap, write or flush lag)
//   REPL-IDLE-PRIMARY     nothing to replay: the primary committed nothing, so "time since the last replay" grows
//   REPL-REPLAY-STALLED   replay stood still, and nothing captured says why
// https://www.postgresql.org/docs/18/hot-standby.html#HOT-STANDBY-CONFLICT, https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas

import { recommend } from "./catalog";
import { hhmmss, iso, plural, type Confidence, type EventRow, type EvidenceRef, type Finding, type MetricPoint, type Recommendation, type ReplicaSample } from "./types";

export const LAG_METRIC = "physical_replication_delay_in_seconds";
export const RESTART_GAP_MINUTES = 10;

export interface LagPoint {
    at: Date;
    value: number;
}

export interface LagRise {
    start: Date;
    peak: LagPoint;
    recovered?: LagPoint;
    /** Seconds of lag added per second of clock while it rose: 1.0 means replay stood still. */
    slope: number;
    points: LagPoint[];
    /** Where the points come from: Azure Monitor's metric, or the observer's own samples on the replica. */
    source: "Telemetry Snapshots" | "RCA Replica";
}

const round1 = (v: number) => Math.round(v * 10) / 10;

/** The lag series for the window: Azure Monitor's Read Replica Lag when the history has it, else the replica's own samples. */
export function lagSeries(metrics: readonly MetricPoint[], samples: readonly ReplicaSample[]): { points: LagPoint[]; source: LagRise["source"] } {
    const monitor = metrics
        .filter((m): m is MetricPoint & { value: number } => m.target === "T4-replica" && m.metric === LAG_METRIC && m.value !== null)
        .map((m) => ({ at: m.at, value: m.value }))
        .sort((a, b) => a.at.getTime() - b.at.getTime());
    if (monitor.length > 0) return { points: monitor, source: "Telemetry Snapshots" };
    const own = samples
        .filter((s): s is ReplicaSample & { sinceLastReplayS: number } => s.side === "replica" && s.sinceLastReplayS !== undefined)
        .map((s) => ({ at: s.at, value: s.sinceLastReplayS }))
        .sort((a, b) => a.at.getTime() - b.at.getTime());
    return { points: own, source: "RCA Replica" };
}

/** The rise around `at`: back to where the lag was last under `floor`, forward to its peak and its recovery. */
export function lagRise(series: { points: LagPoint[]; source: LagRise["source"] }, at: Date, floor = 5): LagRise | null {
    const lag = series.points;
    if (lag.length === 0) return null;
    let i = lag.findIndex((p) => p.at.getTime() >= at.getTime() - 60_000);
    if (i < 0) i = lag.length - 1;
    let s = i;
    while (s > 0 && lag[s - 1].value >= floor) s--;
    let p = s;
    for (let k = s; k < lag.length && (lag[k].value >= floor || k <= i); k++) if (lag[k].value > lag[p].value) p = k;
    const recoveredIndex = lag.findIndex((pt, k) => k > p && pt.value < floor);
    const points = lag.slice(Math.max(0, s - 1), recoveredIndex >= 0 ? recoveredIndex + 1 : p + 1);
    const rising = lag.slice(s, p + 1);
    const slope = rising.length >= 2 ? (rising[rising.length - 1].value - rising[0].value) / ((rising[rising.length - 1].at.getTime() - rising[0].at.getTime()) / 1000) : 1;
    return {
        start: lag[s].at,
        peak: lag[p],
        recovered: recoveredIndex >= 0 ? lag[recoveredIndex] : undefined,
        slope: Math.round(slope * 100) / 100,
        points,
        source: series.source,
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
}

export function analyzeReplicaLag(input: { at: Date; metrics: readonly MetricPoint[]; samples: readonly ReplicaSample[]; events: readonly EventRow[] }): ReplicaAnalysis {
    const notCaptured: string[] = [];
    const series = lagSeries(input.metrics, input.samples);
    const rise = lagRise(series, input.at);
    if (!rise) {
        return { rise, findings: [], rootCause: null, recommendations: [], nextSteps: ["Run the control notebook's Run all with the read replica (it's created for each session)."], notCaptured: ["Neither Read Replica Lag nor the replica's own samples are in the history for this time."] };
    }
    const metricName = rise.source === "Telemetry Snapshots" ? "Read Replica Lag" : "The replica's time since its last replay";
    const ev = (table: string, at: Date, text: string): EvidenceRef => ({ table, at: iso(at), target: "T4-replica", text });
    const shown = perMinute(rise.points);
    const lagRefs = shown.map((p) => ev(rise.source, p.at, `${metricName} ${round1(p.value)} s`));
    const shape = `${metricName} rose from ${hhmmss(rise.start)} to ${round1(rise.peak.value)} s at ${hhmmss(rise.peak.at)} UTC (${shown.map((p) => `${round1(p.value)} s`).join(", ")})${rise.recovered ? ` and was back to ${round1(rise.recovered.value)} s at ${hhmmss(rise.recovered.at)} UTC` : ""}; it grew ${rise.slope} s per second`;

    if (isRestartCatchUp(rise, series.points)) {
        const statement = `${shape}, right after a gap in the series: the replica was stopped, and the metric counts the time since its last replayed transaction from before the stop. This is its catch-up, not replication lag.`;
        return { rise, findings: [{ ruleId: "REPL-CATCHUP", target: "T4-replica", severity: "info", title: "Catch-up after a restart", detail: statement, evidence: lagRefs }], rootCause: { statement, confidence: "high", ruleIds: ["REPL-CATCHUP"], evidence: lagRefs }, recommendations: [], nextSteps: ["Read the lag from the first points after the replica is back in recovery only."], notCaptured };
    }

    const from = rise.start.getTime() - 60_000;
    const to = (rise.recovered?.at ?? rise.peak.at).getTime() + 60_000;
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
    let evidence: EvidenceRef[] = [...lagRefs];
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
        evidence = [...lagRefs, ev("RCA Replica", conflict.at, `startup waits ${conflict.conflictWantedMode} on ${conflict.conflictRelation}, held ${conflict.conflictHolderMode} by session ${conflict.conflictHolder}`), ...watchedRefs];
        ids = ["RPL-SHORT-REPORTS", "RPL-STANDBY-DELAY", "RPL-NO-EXCLUSIVE"];
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
        ruleId = rise.slope >= 0.8 ? "REPL-REPLAY-STALLED" : "REPL-UNEXPLAINED";
        statement = `${shape}. ${rise.slope >= 0.8 ? "Replay stood still" : "Replay slowed"}, and nothing captured says why.`;
        confidence = "low";
    }
    return {
        rise,
        findings: [{ ruleId, target: "T4-replica", severity: rise.peak.value >= 60 ? "critical" : "warning", title: `Read replica lag ${round1(rise.peak.value)} s at ${hhmmss(rise.peak.at)} UTC`, detail: statement, evidence }],
        rootCause: { statement, confidence, ruleIds: [ruleId], evidence },
        recommendations: recommend(...ids),
        nextSteps:
            ruleId === "REPL-REPLAY-CONFLICT"
                ? ["Find the reporting queries that run on the replica while the primary takes ACCESS EXCLUSIVE locks (DDL, TRUNCATE, LOCK TABLE).", "Decide max_standby_streaming_delay: freshness (lower, cancels reports) or long reports (higher, more lag).", "Compare with Database Hub's Read replica lag chart for T4's replica."]
                : ["Compare with Database Hub's Read replica lag chart and the replica's CPU and IOPS for the same minutes."],
        notCaptured,
    };
}
