// The shared blind detector (ADR 0031, "The shared blind detector"). It finds incidents in what a DBA's tools show (the
// RCA capture, Database Hub's telemetry, Azure Monitor's metrics) and in nothing else: no plan, no list of what ran.
// The RCA view, the chat's find_incidents and triage_window, and the postmortem's Cause all use it.
//
// One rule for every series:
// - a sample without a value is unknown, never "under the level";
// - a run continues across up to MAX_UNKNOWN unknown samples between samples at the level;
// - an episode opens on its rule's samples at the level in a run (2 for a gauge, 1 for a count), or on one sample far
//   over it (twice the level and severePoints over its baseline, for a percentage);
// - it ends at the first of RECOVERED_SAMPLES valued samples in a row back under the level; when the data ends or breaks
//   off first, its end isn't known.
// Where the observer captured a target, its own episodes (escalated, relaxed) are the blocking, replay, and connection
// episodes; the densest source of a signal comes first (T3's 15-second resource rows before Database Hub's bins).

import { COSMOS_METRICS, cosmosSeries, POSTGRES_METRICS, postgresSeries, replicaCatchUp, type Bin, type CosmosCapture, type PostgresCapture } from "@/data/model";
import { pointKey, type Confidence, type Episode, type Evidence, type EventRow, type RcaTarget, type Support } from "./types";

export interface Sample {
    at: Date;
    value: number | null;
}

export type LevelMode = "fixed" | "cpu" | "relative" | "burst";

export interface SignalRule {
    family: string;
    signal: string;
    unit: string;
    /** The level without a baseline (the notebook's episode level). */
    floor: number;
    /** Strictly above the level, rather than at it. */
    strict: boolean;
    /** Samples at the level, in one run, that open an episode. */
    minRun: number;
    /**
     * fixed: the floor. cpu: 1.5 times and 10 points over the baseline when that's under the floor. relative: 1.5 times
     * the baseline when that's over the floor. burst: 3 times the baseline when that's over the floor.
     */
    mode: LevelMode;
    /** For a percentage: one sample at twice the level and this many points over its baseline opens an episode by itself. */
    severePoints?: number;
    /** Minutes of baseline before a sample (BASELINE_MINUTES by default). */
    baselineMinutes?: number;
}

export const MAX_UNKNOWN = 2;
export const RECOVERED_SAMPLES = 2;
export const BASELINE_MINUTES = 30;
export const BASELINE_MIN_SAMPLES = 5;
const MIN = 60_000;

/** The notebook's episode levels (so the numbers stay comparable with Wave 1's), and the RCA's own signals. */
export const RULES = {
    blocking: { family: "blocking", signal: "blocked processes", unit: "processes", floor: 0, strict: true, minRun: 1, mode: "fixed" },
    deadlock: { family: "deadlock", signal: "deadlocks", unit: "deadlocks", floor: 0, strict: true, minRun: 1, mode: "fixed" },
    cpu: { family: "cpu", signal: "CPU", unit: "%", floor: 80, strict: false, minRun: 2, mode: "cpu", severePoints: 30 },
    io: { family: "io", signal: "Buffer IO (PAGEIOLATCH) waits", unit: "s", floor: 1, strict: false, minRun: 2, mode: "relative" },
    log_rate: { family: "log_rate", signal: "log rate governor waits", unit: "s", floor: 0, strict: true, minRun: 1, mode: "fixed" },
    latch: { family: "latch", signal: "buffer latch waits", unit: "s", floor: 5, strict: false, minRun: 2, mode: "relative" },
    memory: { family: "memory", signal: "memory waits", unit: "s", floor: 5, strict: false, minRun: 2, mode: "relative" },
    parallelism: { family: "parallelism", signal: "parallelism waits", unit: "s", floor: 5, strict: false, minRun: 2, mode: "relative" },
    tran_log: { family: "tran_log", signal: "transaction log IO waits", unit: "s", floor: 5, strict: false, minRun: 2, mode: "relative" },
    network: { family: "network", signal: "network IO waits", unit: "s", floor: 5, strict: false, minRun: 2, mode: "relative" },
    errors: { family: "errors", signal: "errors a minute", unit: "errors", floor: 10, strict: false, minRun: 1, mode: "burst", baselineMinutes: 10 },
    replica_lag: { family: "replica_lag", signal: "read replica lag", unit: "s", floor: 30, strict: false, minRun: 1, mode: "fixed" },
    connections: { family: "connections", signal: "connections against the limit", unit: "%", floor: 80, strict: false, minRun: 1, mode: "fixed" },
    throttling: { family: "throttling", signal: "throttled requests (429)", unit: "requests", floor: 0, strict: true, minRun: 1, mode: "fixed" },
    ru: { family: "ru", signal: "normalized RU consumption", unit: "%", floor: 100, strict: false, minRun: 1, mode: "fixed" },
} as const satisfies Record<string, SignalRule>;

export type Family = keyof typeof RULES;

/** The wait categories of Database Hub's telemetry behind each wait family. */
export const WAIT_FAMILY_CATEGORIES: Readonly<Record<string, string>> = {
    latch: "Buffer Latch",
    memory: "Memory",
    parallelism: "Parallelism",
    tran_log: "Tran Log IO",
    network: "Network IO",
};

export const SOURCES = {
    capture: "the RCA capture",
    hub: "Database Hub's telemetry",
    monitor: "Azure Monitor",
} as const;

const median = (xs: readonly number[]) => {
    const s = [...xs].sort((a, b) => a - b);
    const mid = Math.floor(s.length / 2);
    return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

/** The level a sample must reach, from the rule and the baseline. */
export function levelOf(rule: SignalRule, baseline: number | null): number {
    if (baseline === null) return rule.floor;
    if (rule.mode === "cpu") {
        const relative = Math.max(baseline * 1.5, baseline + 10);
        return relative < rule.floor ? relative : rule.floor;
    }
    if (rule.mode === "relative") return Math.max(rule.floor, baseline * 1.5);
    if (rule.mode === "burst") return Math.max(rule.floor, baseline * 3);
    return rule.floor;
}

const meets = (value: number | null, level: number, strict: boolean) => value !== null && (strict ? value > level : value >= level);

function isSevere(rule: SignalRule, value: number, level: number, baseline: number | null): boolean {
    return rule.severePoints !== undefined && value >= 2 * level && value >= (baseline ?? 0) + rule.severePoints;
}

/** The samples with every missing step as an unknown sample (at most MAX_UNKNOWN + 1 per gap: enough to break a run). */
export function withGaps(samples: readonly Sample[], stepMs: number): Sample[] {
    const sorted = [...samples].sort((a, b) => a.at.getTime() - b.at.getTime());
    const out: Sample[] = [];
    for (const s of sorted) {
        const prev = out[out.length - 1];
        if (prev) {
            const gap = s.at.getTime() - prev.at.getTime();
            if (gap > stepMs * 1.5) {
                const missing = Math.min(MAX_UNKNOWN + 1, Math.round(gap / stepMs) - 1);
                for (let k = 1; k <= missing; k++) out.push({ at: new Date(prev.at.getTime() + k * stepMs), value: null });
            }
        }
        out.push(s);
    }
    return out;
}

const stamp = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");

function supportOf(atLevel: number, unknown: number): Support {
    if (atLevel <= 1) return "single sample";
    return unknown > 0 ? "sparse" : "sustained";
}

const CONFIDENCE: Record<Support, Confidence> = { sustained: "high", sparse: "medium", "single sample": "low" };

/** The baseline at sample i: the median of the valued samples of the minutes before it (BASELINE_MINUTES), outside earlier episodes. */
function baselineAt(samples: readonly Sample[], i: number, found: readonly Episode[], minutes: number): number | null {
    const start = samples[i].at.getTime();
    const from = start - minutes * MIN;
    const values: number[] = [];
    for (let k = i - 1; k >= 0; k--) {
        const t = samples[k].at.getTime();
        if (t < from) break;
        const v = samples[k].value;
        if (v === null) continue;
        if (found.some((e) => t >= e.start.getTime() && t <= (e.end ?? e.last).getTime())) continue;
        values.push(v);
    }
    return values.length >= BASELINE_MIN_SAMPLES ? median(values) : null;
}

/** A series' episodes by the rule (see the header). */
export function detect(target: RcaTarget, series: readonly Sample[], stepMs: number, rule: SignalRule, source: string): Episode[] {
    const samples = withGaps(series, stepMs);
    const found: Episode[] = [];
    let i = 0;
    while (i < samples.length) {
        const first = samples[i];
        const baseline = baselineAt(samples, i, found, rule.baselineMinutes ?? BASELINE_MINUTES);
        const level = levelOf(rule, baseline);
        if (first.value === null || !meets(first.value, level, rule.strict)) {
            i++;
            continue;
        }
        let opened = rule.minRun <= 1 || isSevere(rule, first.value, level, baseline);
        let atLevel = 1;
        let valued = 1;
        let unknown = 0;
        let pendingUnknown = 0;
        let pendingUnder = 0;
        let firstUnder = -1;
        let last = i;
        let peak = i;
        let endIndex: number | null = null;
        let j = i + 1;
        for (; j < samples.length; j++) {
            const x = samples[j];
            if (x.value === null) {
                pendingUnknown++;
                if (pendingUnknown > MAX_UNKNOWN) break;
                continue;
            }
            if (meets(x.value, level, rule.strict)) {
                unknown += pendingUnknown;
                valued += pendingUnder + 1;
                pendingUnknown = 0;
                pendingUnder = 0;
                firstUnder = -1;
                atLevel++;
                last = j;
                if (x.value > (samples[peak].value ?? -Infinity)) peak = j;
                if (!opened && (atLevel >= rule.minRun || isSevere(rule, x.value, level, baseline))) opened = true;
                continue;
            }
            // A valued sample under the level: before the episode opened, the run is over; after, it may be its end.
            if (!opened) break;
            pendingUnknown = 0;
            pendingUnder++;
            if (firstUnder < 0) firstUnder = j;
            if (pendingUnder >= RECOVERED_SAMPLES) {
                endIndex = firstUnder;
                break;
            }
        }
        if (!opened) {
            i++;
            continue;
        }
        const support = supportOf(atLevel, unknown);
        found.push({
            key: `${target}-${rule.family}-${stamp(first.at)}`,
            target,
            family: rule.family,
            signal: rule.signal,
            unit: rule.unit,
            start: first.at,
            end: endIndex === null ? null : samples[endIndex].at,
            last: samples[last].at,
            peak: samples[peak].value as number,
            peakAt: samples[peak].at,
            level,
            baseline,
            valued,
            unknown,
            atLevel,
            support,
            source,
            confidence: CONFIDENCE[support],
        });
        i = endIndex ?? Math.max(j, last + 1);
    }
    return found;
}

/** The smallest step between consecutive samples, or the fallback for a series of one. */
export function stepOf(samples: readonly Sample[], fallbackMs: number): number {
    const times = [...new Set(samples.map((s) => s.at.getTime()))].sort((a, b) => a - b);
    let best = Infinity;
    for (let k = 1; k < times.length; k++) best = Math.min(best, times[k] - times[k - 1]);
    return Number.isFinite(best) ? best : fallbackMs;
}

// ---- The sources -----------------------------------------------------------------------------------------------------

const BIN_FAMILIES: Array<[Family, (b: Bin) => number | null]> = [
    ["blocking", (b) => b.blocked],
    ["cpu", (b) => b.cpu],
    ["io", (b) => b.bufferIoS],
    ["log_rate", (b) => b.logRateS],
    ...Object.entries(WAIT_FAMILY_CATEGORIES).map(([family, category]): [Family, (b: Bin) => number | null] => [family as Family, (b) => (b.waits ? (b.waits[category] ?? 0) : null)]),
];

/** Database Hub's telemetry bins (T1 to T3), family by family; a wait family only when the bins carry categories. */
export function episodesFromBins(bins: readonly Bin[]): Episode[] {
    const out: Episode[] = [];
    const targets = [...new Set(bins.map((b) => b.target))] as RcaTarget[];
    for (const target of targets) {
        const own = bins.filter((b) => b.target === target);
        const step = stepOf(own.map((b) => ({ at: b.at, value: 0 })), 5 * MIN);
        for (const [family, read] of BIN_FAMILIES) {
            const series = own.map((b) => ({ at: b.at, value: read(b) }));
            if (series.every((s) => s.value === null)) continue;
            out.push(...detect(target, series, step, RULES[family], SOURCES.hub));
        }
    }
    return out;
}

/** The observer's own episodes (rca_events, kind capture): escalated, then relaxed, by the episode's ID. */
function captureEpisodes(evidence: Evidence): Array<{ id: string; target: RcaTarget; start: Date; end: Date | null; detail: string }> {
    const starts = evidence.events.filter((e) => e.kind === "capture" && e.name === "escalated" && e.code);
    return starts.map((s) => {
        const relaxed = evidence.events.find((e) => e.kind === "capture" && e.name === "relaxed" && e.code === s.code && e.at >= s.at);
        return { id: s.code as string, target: s.target, start: s.at, end: relaxed?.at ?? null, detail: s.detail };
    });
}

/** The signal a capture episode started on, from its detail ("processes_blocked 7 >= 1: ..."). */
function captureFamily(detail: string, target: RcaTarget): Family | null {
    if (/^(processes_blocked|connections_waiting_lock)\b/.test(detail)) return "blocking";
    if (/^since_last_replayed_s\b/.test(detail) || target === "T4-replica") return "replica_lag";
    if (/^client_connections|connections\b/.test(detail)) return "connections";
    if (/^errors\b/.test(detail)) return "errors";
    if (/^deadlocks\b/.test(detail)) return "deadlock";
    return null;
}

/** The samples of a capture episode's own signal, to measure its peak and how often it was seen. */
function episodeSamples(evidence: Evidence, target: RcaTarget, family: Family, from: Date, to: Date): Sample[] {
    const inside = (at: Date) => at >= from && at <= to;
    if (family === "blocking") {
        const sentinel = evidence.resource.filter((r) => r.target === target && (r.metric === "processes_blocked" || r.metric === "connections_waiting_lock") && inside(r.at));
        const fromSessions = [...new Set(evidence.sessions.filter((s) => s.target === target && inside(s.capturedAt)).map((s) => s.capturedAt.getTime()))].map((t) => ({
            at: new Date(t),
            value: evidence.sessions.filter((s) => s.target === target && s.capturedAt.getTime() === t && s.blockedBy.length > 0).length,
        }));
        return [...fromSessions, ...sentinel.map((r) => ({ at: r.at, value: r.value }))].sort((a, b) => a.at.getTime() - b.at.getTime());
    }
    if (family === "replica_lag") {
        return evidence.replica.filter((r) => r.target === target && r.side === "replica" && inside(r.at) && r.sinceLastReplayS !== undefined).map((r) => ({ at: r.at, value: r.sinceLastReplayS as number }));
    }
    if (family === "connections") return connectionShare(evidence, target).filter((s) => inside(s.at));
    return [];
}

/** T4's connections as a share of what clients can use (max_connections less the reserved slots), from the sentinel. */
function connectionShare(evidence: Evidence, target: RcaTarget): Sample[] {
    const rows = evidence.resource.filter((r) => r.target === target);
    const at = [...new Set(rows.filter((r) => r.metric === "connections_total").map((r) => r.at.getTime()))].sort((a, b) => a - b);
    return at.map((t) => {
        const read = (metric: string) => rows.find((r) => r.metric === metric && r.at.getTime() === t)?.value;
        const total = read("connections_total");
        const max = read("max_connections");
        const reserved = read("reserved_connections") ?? 0;
        return { at: new Date(t), value: total !== undefined && max !== undefined && max - reserved > 0 ? (100 * total) / (max - reserved) : null };
    });
}

/**
 * A capture episode's samples while its capture ran: from its first, up to a gap longer than CAPTURE_RUN_GAP_MS, where the
 * capture stopped (the session's stop, or the VMs'). An episode the capture never relaxed ends there, never across the gap
 * into a later session's samples (Final tests' live check of 4e2c65ed: a surge Stop now cut off read the next session's,
 * 37 minutes later, as its own).
 */
export const CAPTURE_RUN_GAP_MS = 90_000;
function untilGap(samples: readonly Sample[]): Sample[] {
    const out: Sample[] = [];
    for (const s of samples) {
        if (out.length && s.at.getTime() - out[out.length - 1].at.getTime() > CAPTURE_RUN_GAP_MS) break;
        out.push(s);
    }
    return out;
}

/**
 * The end of the capture's coverage that holds a time: its rows for the target (rca_coverage, one per export), each
 * starting no more than CAPTURE_RUN_GAP_MS after the one before, from the row that holds it, or ended at most that long
 * before it. Undefined when no row does.
 */
function coverageEnd(evidence: Evidence, target: RcaTarget, at: Date): Date | undefined {
    const rows = evidence.coverage.filter((c) => c.target === target && c.captured).sort((a, b) => a.from.getTime() - b.from.getTime());
    let end: number | undefined;
    for (const r of rows) {
        if (end === undefined) {
            if (r.from.getTime() <= at.getTime() && r.to.getTime() >= at.getTime() - CAPTURE_RUN_GAP_MS) end = r.to.getTime();
        } else if (r.from.getTime() <= end + CAPTURE_RUN_GAP_MS) {
            end = Math.max(end, r.to.getTime());
        }
    }
    return end === undefined ? undefined : new Date(end);
}

/**
 * Why a capture episode has no relaxed event in the minutes read (rca_events is read up to their end): its capture
 * stopped, when its samples broke off at a gap of more than CAPTURE_RUN_GAP_MS, or its coverage ended before the minutes
 * read do (without coverage, when its samples stopped more than that before their end); or else the minutes read end
 * first, while the capture still ran: it was still on then, and its end is after them (the review of 97fdf5ba: a window
 * ending mid-surge read as a surge Stop now cut off, with a fall and the capture's end).
 */
function captureEnding(evidence: Evidence, target: RcaTarget, last: Date, gapped: boolean, readTo: Date | undefined): { readEnd?: Date } {
    if (gapped || !readTo) return {};
    const ran = coverageEnd(evidence, target, last);
    const running = ran !== undefined ? ran.getTime() >= readTo.getTime() : readTo.getTime() - last.getTime() <= CAPTURE_RUN_GAP_MS;
    return running ? { readEnd: readTo } : {};
}

/** The capture's own episodes, measured from its samples. `readTo` is where the minutes read end. */
export function episodesFromCapture(evidence: Evidence, readTo?: Date): Episode[] {
    const out: Episode[] = [];
    for (const c of captureEpisodes(evidence)) {
        const family = captureFamily(c.detail, c.target);
        if (!family) continue;
        const rule: SignalRule = RULES[family];
        const read = episodeSamples(evidence, c.target, family, c.start, c.end ?? new Date(8.64e15)).filter((s) => s.value !== null);
        const samples = c.end ? read : untilGap(read);
        const level = rule.family === "replica_lag" ? rule.floor : levelOf(rule, null);
        const hits = samples.filter((s) => meets(s.value, level, rule.strict));
        const peak = samples.reduce<Sample | null>((best, s) => (best === null || (s.value ?? -Infinity) > (best.value ?? -Infinity) ? s : best), null);
        // A one-sample episode (a deadlock count that rose) can fall between the counter's samples: its escalation states the value.
        const stated = hits.length === 0 ? Number(/(?:rose by|^\S+) ([\d.]+)/.exec(c.detail)?.[1]) : NaN;
        const support = supportOf(Math.max(1, hits.length), 0);
        const ending = c.end ? {} : captureEnding(evidence, c.target, samples.length ? samples[samples.length - 1].at : c.start, samples.length < read.length, readTo);
        // An episode its capture cut off whose last samples are back under its level fell under by the first of them: a
        // surge cut off by Stop now read 32, 8, and 8 of 35 and wasn't "still on" (the review of 803f2b1a).
        const lastHit = hits[hits.length - 1];
        const after = !c.end && !ending.readEnd && lastHit ? samples.filter((s) => s.at > lastHit.at) : [];
        out.push({
            key: `${c.target}-${family}-${stamp(c.start)}`,
            target: c.target,
            family,
            signal: rule.signal,
            unit: rule.unit,
            start: c.start,
            end: c.end,
            last: hits.length ? hits[hits.length - 1].at : c.start,
            ...ending,
            ...(after.length ? { fellBy: after[0].at, captureEnd: after[after.length - 1].at } : {}),
            peak: Number.isFinite(stated) && stated > (peak?.value ?? 0) ? stated : (peak?.value ?? 0),
            peakAt: Number.isFinite(stated) && stated > (peak?.value ?? 0) ? c.start : (peak?.at ?? c.start),
            level,
            baseline: null,
            valued: samples.length,
            unknown: 0,
            atLevel: hits.length,
            support,
            source: SOURCES.capture,
            confidence: CONFIDENCE[support],
        });
    }
    return out;
}

/** T3's resource rows (RCA-AZ-01, every 15 s), its densest CPU. */
export function cpuFromResourceRows(evidence: Evidence): Episode[] {
    const out: Episode[] = [];
    const targets = [...new Set(evidence.resource.filter((r) => r.metric === "avg_cpu_percent").map((r) => r.target))];
    for (const target of targets) {
        const series = evidence.resource.filter((r) => r.target === target && r.metric === "avg_cpu_percent").map((r) => ({ at: r.at, value: r.value }));
        out.push(...detect(target, series, 15_000, RULES.cpu, SOURCES.capture));
    }
    return out;
}

/** Deadlocks and error bursts from the capture's events, a minute at a time. */
export function episodesFromEvents(evidence: Evidence): Episode[] {
    const out: Episode[] = [];
    const perMinute = (rows: readonly EventRow[]) => {
        const counts = new Map<number, number>();
        for (const e of rows) {
            const minute = Math.floor(e.at.getTime() / MIN) * MIN;
            counts.set(minute, (counts.get(minute) ?? 0) + e.count);
        }
        return counts;
    };
    const targets = [...new Set(evidence.events.map((e) => e.target))];
    for (const target of targets) {
        const own = evidence.events.filter((e) => e.target === target);
        // One deadlock can show as its graph and as its victim's error (1205, 40P01): count the graphs when the target has
        // any, as analyzeDeadlocks does, so a SQL Server deadlock counts once (the review of 34a9732).
        const graphs = own.filter((e) => e.kind === "deadlock");
        const deadlocks = perMinute(graphs.length > 0 ? graphs : own.filter((e) => e.code === "1205" || e.code === "40P01"));
        const errors = perMinute(own.filter((e) => e.kind === "error" || e.kind === "attention"));
        const minutes = [...new Set([...deadlocks.keys(), ...errors.keys()])].sort((a, b) => a - b);
        if (minutes.length === 0) continue;
        // Every minute from the first event to the last counts, so a quiet minute is 0, never unknown: the event session records every event.
        const all: number[] = [];
        for (let m = minutes[0] - BASELINE_MINUTES * MIN; m <= minutes[minutes.length - 1] + 2 * MIN; m += MIN) all.push(m);
        const series = (counts: Map<number, number>) => all.map((m) => ({ at: new Date(m), value: counts.get(m) ?? 0 }));
        if (deadlocks.size) out.push(...detect(target, series(deadlocks), MIN, RULES.deadlock, SOURCES.capture));
        if (errors.size) out.push(...detect(target, series(errors), MIN, RULES.errors, SOURCES.capture));
    }
    return out;
}

/**
 * A series' runs of one grain, oldest first, each with its step: each point's own interval where the history says it
 * (intervals, by pointKey), the capture's otherwise. A day-long save's 15-minute points read at the 1 minute of a
 * session's own save split one T5 storm in two, 12:15 and 12:30, in the day's list (the review of 803f2b1a).
 */
function byGrain<T extends { at: Date }>(points: readonly T[], intervalOf: (p: T) => number | undefined, fallback: number): Array<{ points: T[]; step: number }> {
    const out: Array<{ points: T[]; step: number }> = [];
    for (const p of points) {
        const step = intervalOf(p) ?? fallback;
        const run = out[out.length - 1];
        if (run && run.step === step) run.points.push(p);
        else out.push({ points: [p], step });
    }
    return out;
}

/** T4's, its replica's, and T5's Azure Monitor metrics; the replica's catch-up after a restart isn't lag. */
export function episodesFromMonitor(postgres: PostgresCapture | null, cosmos: CosmosCapture | null, intervals?: ReadonlyMap<string, number>): Episode[] {
    const out: Episode[] = [];
    if (postgres) {
        const step = (postgres.intervalMinutes ?? 1) * MIN;
        const lag = postgresSeries(postgres, "T4-replica", POSTGRES_METRICS.lag);
        const caught = new Set(replicaCatchUp(postgres, lag));
        for (const run of byGrain(lag, (p) => intervals?.get(pointKey("T4-replica", POSTGRES_METRICS.lag, p.at)), step)) {
            out.push(...detect("T4-replica", run.points.map((p) => ({ at: p.at, value: caught.has(p) ? null : p.value })), run.step, RULES.replica_lag, SOURCES.monitor));
        }
        for (const target of ["T4", "T4-replica"] as const) {
            const cpu = postgresSeries(postgres, target, POSTGRES_METRICS.cpu);
            for (const run of byGrain(cpu, (p) => intervals?.get(pointKey(target, POSTGRES_METRICS.cpu, p.at)), step)) {
                out.push(...detect(target, run.points.map((p) => ({ at: p.at, value: p.value })), run.step, RULES.cpu, SOURCES.monitor));
            }
        }
    }
    if (cosmos) {
        const step = (cosmos.intervalMinutes ?? 1) * MIN;
        for (const [metric, rule] of [[COSMOS_METRICS.throttled, RULES.throttling], [COSMOS_METRICS.normalizedRu, RULES.ru]] as const) {
            for (const run of byGrain(cosmosSeries(cosmos, metric), (p) => intervals?.get(pointKey("T5", metric, p.at)), step)) {
                out.push(...detect("T5", run.points.map((p) => ({ at: p.at, value: p.value })), run.step, rule, SOURCES.monitor));
            }
        }
    }
    return out;
}

export interface DetectorInput {
    evidence: Evidence;
    bins?: readonly Bin[];
    postgres?: PostgresCapture | null;
    cosmos?: CosmosCapture | null;
    /** Each Azure Monitor point's own interval, by pointKey (sources.ts's pointIntervals). */
    intervals?: ReadonlyMap<string, number>;
}

/** Whether the observer captured a target over these minutes (an rca_coverage row says so). */
function captured(evidence: Evidence, target: RcaTarget, from: Date, to: Date): boolean {
    return evidence.coverage.some((c) => c.target === target && c.captured && c.from <= to && c.to >= from);
}

/** Whether T3's 15-second resource rows (RCA-AZ-01) cover a target's minutes: then its CPU comes from them. */
function rowsCover(evidence: Evidence, target: RcaTarget, from: Date, to: Date): boolean {
    return evidence.resource.some((r) => r.target === target && r.metric === "avg_cpu_percent" && r.at >= from && r.at <= to);
}

/**
 * Every episode overlapping the window, oldest first. For each target and signal, the densest source that has it: the
 * capture's own episodes where the observer captured the target, T3's 15-second resource rows before Database Hub's
 * bins, Database Hub's bins otherwise, and Azure Monitor for T4, its replica, and T5. Each source gives way only for the
 * minutes a denser one covers, each episode's own (the review of 34a9732: a capture anywhere in the window hid Database
 * Hub's episodes everywhere in it).
 */
export function findEpisodes(input: DetectorInput, from: Date, to: Date): Episode[] {
    const { evidence } = input;
    const byCapture = episodesFromCapture(evidence, to);
    const byRows = cpuFromResourceRows(evidence);
    const byEvents = episodesFromEvents(evidence);
    const byBins = episodesFromBins(input.bins ?? []);
    const byMonitor = episodesFromMonitor(input.postgres ?? null, input.cosmos ?? null, input.intervals);
    const overlaps = (a: Episode, b: Episode) => a.target === b.target && a.family === b.family && a.start <= (b.end ?? b.last) && b.start <= (a.end ?? a.last);
    // The events count deadlocks and errors themselves: the capture's own episode for the same minutes would only repeat them.
    const chosen: Episode[] = [...byCapture.filter((c) => !byEvents.some((e) => overlaps(c, e))), ...byRows, ...byEvents];
    for (const e of byBins) {
        // The capture's blocking episodes replace Database Hub's in the minutes the observer captured; the CPU rows, the bins' in the minutes they cover.
        if (e.family === "blocking" && captured(evidence, e.target, e.start, e.end ?? e.last)) continue;
        if (e.family === "cpu" && rowsCover(evidence, e.target, e.start, e.end ?? e.last)) continue;
        chosen.push(e);
    }
    for (const e of byMonitor) {
        // An Azure Monitor point stands for its whole interval: the replica's lag at 16:15, Azure Monitor's 5 minutes, holds
        // the capture's stall from 16:17:12, which is the same stall, listed once as the capture's (the review of 803f2b1a).
        const step = e.family === "replica_lag" ? input.intervals?.get(pointKey(e.target, POSTGRES_METRICS.lag, e.last)) ?? (input.postgres?.intervalMinutes ?? 0) * MIN : 0;
        const reach = Math.max((e.end ?? e.last).getTime(), e.last.getTime() + step - 1);
        if (e.family === "replica_lag" && byCapture.some((c) => c.target === e.target && c.family === e.family && c.start.getTime() <= reach && e.start <= (c.end ?? c.last))) continue;
        chosen.push(e);
    }
    return chosen.filter((e) => e.start <= to && (e.end ?? e.last) >= from).sort((a, b) => a.start.getTime() - b.start.getTime() || a.target.localeCompare(b.target));
}

/** One episode in a sentence, with how it was seen: "CPU at 80 % or more ... 4 of its 10 samples had no value". */
export function describeEpisode(e: Episode): string {
    const t = (d: Date) => d.toISOString().slice(11, 19);
    const unit = e.unit === "%" ? " %" : ` ${e.unit}`;
    const round = (v: number) => (Math.abs(v) >= 100 ? Math.round(v) : Math.round(v * 10) / 10);
    const capture = e.source === SOURCES.capture;
    // An episode the capture had no samples of its own for (its errors, PostgreSQL's deadlock counts) can't say whether it
    // was still on (the review of 97fdf5ba).
    const own = e.valued > 0;
    const span = e.end
        ? `from ${t(e.start)} to ${t(e.end)} UTC`
        : capture
          ? e.readEnd
              ? own
                  ? `from ${t(e.start)} UTC (still on at ${t(e.readEnd)} UTC, where the minutes read end)`
                  : `from ${t(e.start)} UTC (the capture hadn't recorded its end by ${t(e.readEnd)} UTC, where the minutes read end)`
              : e.fellBy
                ? `from ${t(e.start)} UTC, under its level by ${t(e.fellBy)} UTC (the capture ended at ${t(e.captureEnd ?? e.fellBy)} UTC, before it could confirm the end)`
                : own
                  ? `from ${t(e.start)} UTC (the capture ended while it was still on, so its end isn't known)`
                  : `from ${t(e.start)} UTC (the capture ended before it recorded an end, and whether it was still on isn't known)`
          : `from ${t(e.start)} UTC (its end isn't known: the data ${e.last.getTime() === e.start.getTime() ? "has one sample" : "ends or breaks off first"})`;
    // The capture's samples between an episode's start and end aren't all at the level when it came in waves (the live
    // check of 4e2c65ed: four waves of a connection surge read as "32 samples in a row"), and neither are the telemetry's
    // with a dip (the review of 803f2b1a: T3's CPU at 95, 96, 60, and 97 % read as "3 samples in a row").
    const how =
        e.support === "single sample"
            ? "in one sample, far over its level: low confidence"
            : e.support === "sparse"
              ? `in ${e.atLevel} samples, ${e.unknown} of the samples between them without a value`
              : e.valued > e.atLevel
                ? `in ${e.atLevel} of its ${e.valued} samples`
                : `in ${e.atLevel} samples in a row`;
    return `${e.target}: ${e.signal} ${e.level === 0 ? "above zero" : `over ${round(e.level)}${unit}`} ${span}, peak ${round(e.peak)}${unit} at ${t(e.peakAt)} UTC, ${how} (${e.source}).`;
}
