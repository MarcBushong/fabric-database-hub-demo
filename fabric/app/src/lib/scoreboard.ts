// "Did we catch it?" (ADR 0030): every fault the demo injected (Scenario Runs), when its signal first showed in the
// telemetry, when it was answered (the response step, where one exists), and when it recovered; and the times to detect
// and recover per engine and fault type, across sessions. Only the app can say this: it knows what was injected.
//
// "Signal visible in telemetry" is measured here from the history's bins, by their sample time, with the analysis
// notebook's own rules (NB_DatabaseHub_LiveActivity: SCENARIO_SIGNALS, EPISODE_RULES, the CPU correlation's 1.5 times
// and 10 points, TELEMETRY_LAG_MINUTES). It never claims what Database Hub detected: the app can't read that, and Database
// Hub shows the telemetry 3 to 15 minutes after its sample time. Pure, so the tests pin every number.

import type { AgentBeat, Bin, CosmosCapture, Incident, PostgresCapture, SessionRun } from "@/data/model";
import { COSMOS_METRICS, cosmosSeries, POSTGRES_METRICS, postgresSeries, replicaCatchUp, throttledRuns } from "@/data/model";
import type { Row } from "@/data/query-client";
import { impactOf, type Impact } from "./business";
import { engineOf } from "./estate";
import { formatNumber, formatTimeUtc, toDate, type NumberKind } from "./format";
import { FAMILY_SIGNAL, REPLICA_LAG_WARNING_SECONDS, signalValue } from "./insights";
import { SCENARIOS } from "./scenarios";
import { quantile } from "./stats";
import type { StatusName } from "./status";
import { isEstateTarget, type EstateTarget } from "./view-state";

/** The notebook's: telemetry arrives 3 to 15 minutes after the activity, so a fault's signal is looked for this long after its window. */
export const TELEMETRY_LAG_MINUTES = 15;
/** How long after a fault's window its recovery is looked for. */
export const RECOVERY_SLACK_MINUTES = 30;
/** Why a visible signal has no recovery, in a sentence and in a table's few words. */
const NO_RECOVERY = {
    ongoing: { note: "Still visible when the telemetry ends.", word: "Still visible" },
    next: { note: "The next fault with this signal began first.", word: "Next fault first" },
    late: { note: `Not back under its bound ${RECOVERY_SLACK_MINUTES} min after its window.`, word: `Not in ${RECOVERY_SLACK_MINUTES} min` },
} as const;
/** Bins under the detection bound, in a row, that make a recovery. */
export const RECOVERED_BINS = 2;
/** Bins outside every window that expects the signal, at the least, for a baseline; with fewer, the notebook's floor alone. */
export const BASELINE_MIN_BINS = 5;

const MIN = 60000;

/** The notebook's SCENARIO_SIGNALS: the signal families each scenario is built to raise. */
export const SCENARIO_SIGNALS: Readonly<Record<string, readonly string[]>> = {
    "locking-blocking": ["blocking"],
    "cpu-pressure": ["cpu"],
    "io-pressure": ["io"],
    "inefficient-query": ["cpu", "log_rate"],
    "missing-index": ["cpu", "io"],
    "resource-governance": ["cpu"],
    "log-rate-pressure": ["log_rate"],
    "blocking-chain": ["blocking"],
    "deadlock-storm": ["deadlock", "blocking"],
    "tempdb-contention": ["latch"],
    "memory-grant-pressure": ["memory"],
    "parallel-scans": ["parallelism", "cpu"],
    "log-flush-waits": ["tran_log"],
    "slow-consumer": ["network"],
    "capacity-max": ["cpu", "io"],
    "plan-regression": ["cpu"],
};

/** The families a scenario raises: the notebook's map, or its keywords for a scenario it doesn't list. */
export function expectedFamilies(scenario: string): string[] {
    const listed = SCENARIO_SIGNALS[scenario];
    if (listed) return [...listed];
    const words: Array<[string, string]> = [
        ["lock", "blocking"],
        ["block", "blocking"],
        ["cpu", "cpu"],
        ["io", "io"],
        ["log", "log_rate"],
        ["index", "cpu"],
    ];
    return [...new Set(words.filter(([word]) => scenario.includes(word)).map(([, family]) => family))].sort();
}

interface Rule {
    floor: number;
    strict: boolean;
    minBins: number;
}

/** The notebook's EPISODE_RULES: the level a bin reaches (strictly above it, or at it), for how many bins in a row. */
const RULES: Readonly<Record<string, Rule>> = {
    blocking: { floor: 0, strict: true, minBins: 1 },
    deadlock: { floor: 0, strict: true, minBins: 1 },
    cpu: { floor: 80, strict: false, minBins: 2 },
    io: { floor: 1, strict: false, minBins: 2 },
    log_rate: { floor: 0, strict: true, minBins: 1 },
    latch: { floor: 5, strict: false, minBins: 2 },
    memory: { floor: 5, strict: false, minBins: 2 },
    parallelism: { floor: 5, strict: false, minBins: 2 },
    tran_log: { floor: 5, strict: false, minBins: 2 },
    network: { floor: 5, strict: false, minBins: 2 },
};

export interface Bound {
    value: number;
    strict: boolean;
    minBins: number;
    /** How the bound was set, in words. */
    basis: string;
    /** The same, short, for a table cell: "its baseline of 24.2 %" or "episode level". */
    short: string;
}

/**
 * When a bin shows a family's signal. CPU: at the notebook's episode level (80 %), or at 1.5 times and 10 points above its
 * baseline when that's lower (its correlation rule). Every other family: at its episode floor, or 1.5 times its baseline
 * when that's higher. Without a baseline, the floor alone.
 */
export function detectionBound(family: string, baseline: number | null): Bound | null {
    const rule = RULES[family];
    if (!rule) return null;
    const episode = { basis: "the notebook's episode level", short: "episode level" };
    if (family === "cpu") {
        const relative = baseline === null ? null : Math.max(baseline * 1.5, baseline + 10);
        return relative !== null && relative < rule.floor
            ? { value: relative, strict: false, minBins: rule.minBins, basis: `1.5 times and 10 points above its baseline of ${formatNumber(baseline, "percent")}`, short: `baseline ${formatNumber(baseline, "percent")}` }
            : { value: rule.floor, strict: false, minBins: rule.minBins, ...episode };
    }
    const relative = baseline === null ? 0 : baseline * 1.5;
    if (relative > rule.floor) return { value: relative, strict: false, minBins: rule.minBins, basis: `1.5 times its baseline of ${formatNumber(baseline)}`, short: `baseline ${formatNumber(baseline)}` };
    return { value: rule.floor, strict: rule.strict, minBins: rule.minBins, ...episode };
}

function meets(value: number | null, bound: Bound): boolean {
    return value !== null && (bound.strict ? value > bound.value : value >= bound.value);
}

export function boundText(bound: Bound, kind: NumberKind): string {
    return `${bound.strict ? "above" : "at least"} ${formatNumber(bound.value, kind)}`;
}

/** A family's signal in a bin: its column, or its wait category (null when the bin has no categories). */
interface Signal {
    label: string;
    kind: NumberKind;
    read: (b: Bin) => number | null;
}

export function signalOf(family: string): Signal | null {
    const own = FAMILY_SIGNAL[family === "deadlock" ? "blocking" : family];
    if (!own) return null;
    return { label: family === "deadlock" ? "blocked processes (deadlocks)" : own.label, kind: own.kind, read: (b) => signalValue(own, b) };
}

// ---------- Plans: what the control ran ----------

/** A session's plan, as Scenario Runs recorded it at its end, or one incident request outside a session. */
export interface Plan {
    /** The session's request ID ("session:<id>"), or the request's own. */
    key: string;
    kind: "session" | "request";
    /** "Session 7f3a9c21", or the request's scenario and target. */
    label: string;
    start: Date;
    end: Date;
    requestedAt: Date | null;
    status: string;
    message: string;
    /** Its incident requests, by start. */
    faults: SessionRun[];
}

const SESSION_PROFILES = new Set(["session", "showcase"]);

/** The short session ID: the first 8 characters after "session:". */
export function shortSessionId(key: string): string {
    const match = /^session:([^:]+)$/.exec(key);
    return match ? match[1].slice(0, 8) : key;
}

/** A recorded request that injected a fault: an incident scenario other than the baseline, that didn't fail, with its window. */
export function isFault(run: SessionRun): boolean {
    return run.profile.startsWith("incident:") && run.profile !== "incident:healthy-baseline" && isEstateTarget(run.target) && run.status !== "Fail" && run.windowStart !== null && run.windowEnd !== null;
}

export function scenarioOf(run: Pick<SessionRun, "profile">): string {
    return run.profile.replace(/^incident:/, "");
}

export function scenarioTitle(scenario: string): string {
    return SCENARIOS.find((s) => s.id === scenario)?.title ?? scenario;
}

/** The sessions and lone incident requests in the runs, newest first, each with its faults. */
export function toPlans(runs: readonly SessionRun[]): Plan[] {
    const sessions: Plan[] = runs
        .filter((r) => SESSION_PROFILES.has(r.profile.trim()) && r.windowStart !== null && r.windowEnd !== null)
        .map((r) => ({
            key: r.requestId,
            kind: "session",
            label: `Session ${shortSessionId(r.requestId)}`,
            start: r.windowStart as Date,
            end: r.windowEnd as Date,
            requestedAt: r.requestedAt,
            status: r.status,
            message: r.message,
            faults: [],
        }));
    const lone: Plan[] = [];
    for (const run of runs.filter(isFault)) {
        const start = (run.windowStart as Date).getTime();
        const owner =
            sessions.find((s) => run.requestId.startsWith(`${s.key}:`)) ??
            sessions.find((s) => start >= s.start.getTime() && start < s.end.getTime() + MIN);
        if (owner) owner.faults.push(run);
        else
            lone.push({
                key: run.requestId,
                kind: "request",
                label: `${scenarioTitle(scenarioOf(run))} on ${run.target}`,
                start: run.windowStart as Date,
                end: run.windowEnd as Date,
                requestedAt: run.requestedAt,
                status: run.status,
                message: run.message,
                faults: [run],
            });
    }
    const all = [...sessions, ...lone];
    for (const plan of all) plan.faults.sort((a, b) => (a.windowStart?.getTime() ?? 0) - (b.windowStart?.getTime() ?? 0) || a.target.localeCompare(b.target));
    return all.sort((a, b) => b.start.getTime() - a.start.getTime());
}

// ---------- Scores ----------

export interface FaultScore {
    /** The request's ID. */
    key: string;
    planKey: string;
    target: EstateTarget;
    scenario: string;
    title: string;
    /** The family whose signal showed first, or the first one the scenario raises. */
    family: string;
    signal: string;
    kind: NumberKind;
    /** When it was injected: its window's start, or, for the Database Agent beat, when the plan regressed. */
    injectedAt: Date;
    injectedEnd: Date;
    baseline: number | null;
    bound: Bound | null;
    /** When its signal first showed in the telemetry (by sample time), or null. */
    visibleAt: Date | null;
    peak: number | null;
    peakAt: Date | null;
    /** The response step, where one exists: the Database Agent beat's documented response, or a reset. */
    answeredAt: Date | null;
    answer: string;
    recoveredAt: Date | null;
    /** True when the signal was still above its bound at the end of the telemetry. */
    ongoing: boolean;
    /** Injected to visible, in minutes. */
    ttdMin: number | null;
    /** Injected to recovered, in minutes. */
    ttrMin: number | null;
    /** Visible to recovered (or to the end of the telemetry when ongoing), in minutes: how long the service felt it. */
    visibleMin: number | null;
    /** Pass: its signal showed. Warning: it didn't, or no telemetry covers it. Not supported: the history has no signal for it. */
    status: StatusName;
    /** One line: how it was measured, or why it wasn't. */
    note: string;
    /** Why a visible signal has no recovery: still visible at the telemetry's end, or the next fault came first; empty otherwise. */
    recoveryNote: string;
    /** The same reason in two or three words, for a table's Recovered column; empty when it recovered or wasn't visible. */
    recoveryWord: string;
    binMinutes: number | null;
    /** The incident window the notebook recorded for it (Incidents' drill-down), when there is one. */
    incidentKey: string | null;
    /** The notebook's own expected-signal verdict for it, when it has one. */
    notebookVerdict: string;
    impact: Impact | null;
}

export interface ScoreContext {
    /** T1 to T3 bins, with their wait categories where the page loaded them (withCategoryWaits). */
    bins: readonly Bin[];
    beats: readonly AgentBeat[];
    /** Every recorded run in the period: the faults of other plans set the baselines' windows, and resets answer. */
    runs: readonly SessionRun[];
    incidents?: readonly Incident[];
}

/**
 * The bin size around a fault, in minutes: the median gap between the target's bins in the fault's own window, or, when
 * that holds fewer than two, in the hour around it. The history mixes bin sizes (the notebook bins a window of 120 minutes
 * or less by the minute, 720 by 5, and longer by 15: a session of about 110 minutes or more, `stop-demo -SaveHistory`, and
 * deploy's snapshot), so a fault is read in its own bins' step, never the smallest step anywhere in the period.
 */
function stepAround(bins: readonly Bin[], from: number, to: number): number | null {
    const gapsIn = (start: number, end: number) => {
        const gaps: number[] = [];
        let previous: number | null = null;
        for (const b of bins) {
            const t = b.at.getTime();
            if (t < start || t >= end) continue;
            if (previous !== null && t > previous) gaps.push((t - previous) / MIN);
            previous = t;
        }
        return gaps;
    };
    const own = gapsIn(from, to);
    const gaps = own.length ? own : gapsIn(from - 60 * MIN, to + 60 * MIN);
    return gaps.length ? median(gaps) : null;
}

/** Bins spaced like `step` (their nearer neighbor within half to one and a half steps): a different bin size sums its waits over a different time. */
function spacedLike(bins: readonly Bin[], step: number): Bin[] {
    return bins.filter((b, i) => {
        const before = i > 0 ? (b.at.getTime() - bins[i - 1].at.getTime()) / MIN : Number.POSITIVE_INFINITY;
        const after = i < bins.length - 1 ? (bins[i + 1].at.getTime() - b.at.getTime()) / MIN : Number.POSITIVE_INFINITY;
        const nearer = Math.min(before, after);
        return nearer >= step * 0.5 && nearer <= step * 1.5;
    });
}

function median(values: readonly number[]): number | null {
    return quantile(values, 0.5);
}

/** The measure a family's signal reads: a deadlock shows as blocked processes, like blocking. */
function signalKey(family: string): string {
    return family === "deadlock" ? "blocking" : family;
}

/** Whether a recorded fault is built to raise the signal a family reads. */
function raises(run: SessionRun, family: string): boolean {
    return expectedFamilies(scenarioOf(run)).some((f) => signalKey(f) === signalKey(family));
}

/** The beat of the Database Agent loop for the fault: its own finding, or, for a plan regression, the beat whose window overlaps it on the same target. */
function agentBeatOf(run: SessionRun, beats: readonly AgentBeat[]): AgentBeat | null {
    const own = beats.find((b) => b.requestId !== "" && b.requestId === run.requestId);
    if (own) return own;
    if (scenarioOf(run) !== "plan-regression") return null;
    const start = run.windowStart?.getTime() ?? 0;
    const end = run.windowEnd?.getTime() ?? 0;
    return beats.find((b) => b.target === run.target && b.windowStart !== null && b.windowEnd !== null && b.windowStart.getTime() < end && b.windowEnd.getTime() > start) ?? null;
}

/** How far around a fault its baseline is read: the analysis notebook reads it from its own window, a session's. */
const BASELINE_REACH_MINUTES = 120;

/** The baseline of a signal on a target: the median of its bins near the fault, outside every window (plus the telemetry's lag) of a fault that raises it. */
function baselineOf(signal: Signal, targetBins: readonly Bin[], hot: ReadonlyArray<{ from: number; to: number }>, near: { from: number; to: number }): number | null {
    const clean = targetBins
        .filter((b) => b.at.getTime() >= near.from && b.at.getTime() < near.to && !hot.some((w) => b.at.getTime() >= w.from && b.at.getTime() < w.to))
        .map(signal.read)
        .filter((v): v is number => v !== null);
    return clean.length >= BASELINE_MIN_BINS ? median(clean) : null;
}

interface Detection {
    family: string;
    signal: Signal;
    bound: Bound;
    baseline: number | null;
    at: Date;
    searchEnd: number;
}

/** The first run of `minBins` bins in a row (one bin apart at most) that meet the bound, from `from` to `to`. */
function firstRun(bins: readonly Bin[], signal: Signal, bound: Bound, from: number, to: number, stepMs: number): Date | null {
    let runStart: Bin | null = null;
    let count = 0;
    let previous: number | null = null;
    for (const b of bins) {
        const t = b.at.getTime();
        if (t + stepMs <= from || t >= to) continue;
        const contiguous = previous === null || t - previous <= stepMs * 1.5;
        if (meets(signal.read(b), bound)) {
            if (!runStart || !contiguous) {
                runStart = b;
                count = 0;
            }
            count++;
            if (count >= bound.minBins) return runStart.at;
        } else {
            runStart = null;
            count = 0;
        }
        previous = t;
    }
    return null;
}

/** The end of the telemetry that runs on from `from` without a gap of more than one and a half bins. */
function contiguousEnd(bins: readonly Bin[], from: number, stepMs: number): number {
    let end = from;
    for (const b of bins) {
        const t = b.at.getTime();
        if (t < from) continue;
        if (t - end > stepMs * 1.5) break;
        end = t + stepMs;
    }
    return end;
}

/**
 * The recovery after the signal showed: the first bin after its last bin at the bound (before `to`), with RECOVERED_BINS
 * bins under it in a row, with no gap. Null with `ongoing` when the telemetry ends (or breaks off) first.
 */
function recoveryOf(bins: readonly Bin[], signal: Signal, bound: Bound, visible: number, to: number, stepMs: number): { at: Date | null; ongoing: boolean } {
    const window = bins.filter((b) => b.at.getTime() >= visible && b.at.getTime() < to);
    let lastHot = visible;
    for (const b of window) if (meets(signal.read(b), bound)) lastHot = b.at.getTime();
    const under: Bin[] = [];
    let previous = lastHot;
    for (const b of bins) {
        const t = b.at.getTime();
        if (t <= lastHot) continue;
        if (t - previous > stepMs * 1.5 || signal.read(b) === null) return { at: null, ongoing: true };
        if (meets(signal.read(b), bound)) return { at: null, ongoing: false };
        under.push(b);
        previous = t;
        if (under.length >= RECOVERED_BINS) return { at: under[0].at, ongoing: false };
    }
    return { at: null, ongoing: true };
}

const minutesBetween = (a: Date | null, b: Date | null) => (a && b ? Math.max(0, (b.getTime() - a.getTime()) / MIN) : null);

/** Scores one injected fault on a SQL target (T1 to T3) from the bins. */
export function scoreFault(run: SessionRun, planKey: string, ctx: ScoreContext): FaultScore {
    const target = run.target as EstateTarget;
    const scenario = scenarioOf(run);
    const families = expectedFamilies(scenario);
    const beat = agentBeatOf(run, ctx.beats);
    const windowStart = run.windowStart as Date;
    const injectedEnd = run.windowEnd as Date;
    const injectedAt = beat?.regressAt && beat.regressAt >= windowStart && beat.regressAt < injectedEnd ? beat.regressAt : windowStart;
    const incident = ctx.incidents?.find((i) => i.key === `request:${run.requestId}` || i.key === `request:${run.requestId}:${target}`) ?? null;
    const base: Omit<FaultScore, "family" | "signal" | "kind" | "status" | "note"> = {
        key: run.requestId,
        planKey,
        target,
        scenario,
        title: scenarioTitle(scenario),
        injectedAt,
        injectedEnd,
        baseline: null,
        bound: null,
        visibleAt: null,
        peak: null,
        peakAt: null,
        answeredAt: null,
        answer: "",
        recoveredAt: null,
        ongoing: false,
        ttdMin: null,
        ttrMin: null,
        visibleMin: null,
        binMinutes: null,
        incidentKey: incident?.key ?? null,
        notebookVerdict: incident?.verdict ?? "",
        impact: null,
        recoveryNote: "",
        recoveryWord: "",
    };
    const first = signalOf(families[0] ?? "");
    const unmeasured = (status: StatusName, note: string): FaultScore => ({ ...base, family: families[0] ?? "", signal: first?.label ?? scenario, kind: first?.kind ?? "decimal", status, note });
    if (target !== "T1" && target !== "T2" && target !== "T3") return unmeasured("Not supported", `${target}'s beats show in its Azure Monitor metrics, which the history keeps per capture, not per request.`);

    const targetBins = ctx.bins.filter((b) => b.target === target).sort((a, b) => a.at.getTime() - b.at.getTime());
    const step = stepAround(targetBins, injectedAt.getTime(), injectedEnd.getTime());
    const stepMs = (step ?? 1) * MIN;
    const baselineBins = step === null ? targetBins : spacedLike(targetBins, step);
    const lagMs = TELEMETRY_LAG_MINUTES * MIN;
    const covered = targetBins.filter((b) => b.at.getTime() + stepMs > injectedAt.getTime() && b.at.getTime() < injectedEnd.getTime() + lagMs);
    if (covered.length === 0) {
        if (incident?.verdict === "Pass") return { ...unmeasured("Pass", "Visible by the notebook's own check of its window; its bins aren't in this view, so its times aren't measured here."), binMinutes: step };
        return { ...unmeasured("Warning", `No telemetry from ${target} covers it in the history: its target may have been stopped, or the history wasn't saved.`), binMinutes: step };
    }

    // Every fault on this target that raises the same signal sets its hot windows: the baseline comes from outside them.
    // Faults that raise it at the same time share its signal; the search stops where the next one after this window starts.
    const faultsHere = ctx.runs.filter((r) => isFault(r) && r.target === target);
    const successorOf = (family: string) =>
        faultsHere
            .filter((r) => r.requestId !== run.requestId && raises(r, family))
            .map((r) => (r.windowStart as Date).getTime())
            .filter((t) => t >= injectedEnd.getTime())
            .sort((a, b) => a - b)[0];
    const near = { from: injectedAt.getTime() - BASELINE_REACH_MINUTES * MIN, to: injectedEnd.getTime() + BASELINE_REACH_MINUTES * MIN };
    const detections: Detection[] = [];
    const measurable: string[] = [];
    for (const family of families) {
        const signal = signalOf(family);
        if (!signal || !covered.some((b) => signal.read(b) !== null)) continue;
        measurable.push(family);
        const hot = faultsHere.filter((r) => raises(r, family)).map((r) => ({ from: (r.windowStart as Date).getTime(), to: (r.windowEnd as Date).getTime() + lagMs }));
        const baseline = baselineOf(signal, baselineBins, hot, near);
        const bound = detectionBound(family, baseline);
        if (!bound) continue;
        const next = successorOf(family);
        const searchEnd = Math.min(injectedEnd.getTime() + lagMs, next ?? Number.POSITIVE_INFINITY);
        const at = firstRun(targetBins, signal, bound, injectedAt.getTime(), searchEnd, stepMs);
        if (at) detections.push({ family, signal, bound, baseline, at, searchEnd });
        else if (!detections.length && family === measurable[0]) detections.push({ family, signal, bound, baseline, at: new Date(Number.NaN), searchEnd });
    }
    const found = detections.filter((d) => Number.isFinite(d.at.getTime())).sort((a, b) => a.at.getTime() - b.at.getTime())[0];
    const chosen = found ?? detections[0];
    if (!chosen) {
        if (families.length === 0) return { ...unmeasured("Not supported", `The notebook doesn't map ${scenario} to a signal it measures.`), binMinutes: step };
        const label = families.map((f) => signalOf(f)?.label ?? f.replace(/_/g, " ")).join(" or ");
        return { ...unmeasured("Not supported", `Its signal (${label}) has no values in ${target}'s telemetry for this window in this view.`), binMinutes: step };
    }

    const { signal, bound, baseline } = chosen;
    let peak: number | null = null;
    let peakAt: Date | null = null;
    for (const b of targetBins) {
        const t = b.at.getTime();
        if (t + stepMs <= injectedAt.getTime() || t >= chosen.searchEnd) continue;
        const v = signal.read(b);
        if (v !== null && (peak === null || v > peak)) {
            peak = v;
            peakAt = b.at;
        }
    }

    // The response step, where one exists: the Database Agent beat's run forcing the last good plan, or a reset of the target.
    let answeredAt: Date | null = null;
    let answer = "";
    if (beat?.respondAt) {
        answeredAt = beat.respondAt;
        answer = "The run forced the last good plan (Query Store), the documented response";
    } else {
        const reset = ctx.runs.find((r) => r.profile === "reset" && r.requestedAt !== null && (r.target === target || r.target === "" || r.target === "all") && r.requestedAt >= injectedAt && r.requestedAt.getTime() <= injectedEnd.getTime() + lagMs);
        if (reset?.requestedAt) {
            answeredAt = reset.requestedAt;
            answer = "A reset returned ContosoCare to its seed state";
        }
    }

    const common = {
        ...base,
        family: chosen.family,
        signal: signal.label,
        kind: signal.kind,
        baseline,
        bound,
        peak,
        peakAt,
        answeredAt,
        answer,
        binMinutes: step,
    };
    if (!found) {
        const lastBin = covered[covered.length - 1].at.getTime() + stepMs;
        const stays = `${signal.label} stayed ${bound.strict ? "at or under" : "under"} ${formatNumber(bound.value, signal.kind)}`;
        const capped = chosen.searchEnd < injectedEnd.getTime() + lagMs;
        return {
            ...common,
            status: "Warning",
            note:
                lastBin < chosen.searchEnd
                    ? `Not visible yet: ${stays} until the telemetry ends, ${formatTimeUtc(new Date(lastBin))} UTC.`
                    : capped
                      ? `Not visible: ${stays} until the next fault that raises it began, at ${formatTimeUtc(new Date(chosen.searchEnd))} UTC.`
                      : `Not visible: ${stays} until ${formatTimeUtc(new Date(chosen.searchEnd))} UTC, ${TELEMETRY_LAG_MINUTES} minutes after its window.`,
        };
    }

    const nextRaising = successorOf(chosen.family);
    const recoveryEnd = Math.min(injectedEnd.getTime() + RECOVERY_SLACK_MINUTES * MIN, nextRaising ?? Number.POSITIVE_INFINITY);
    const recovery = recoveryOf(targetBins, signal, bound, found.at.getTime(), recoveryEnd, stepMs);
    const telemetryEnd = contiguousEnd(targetBins, found.at.getTime(), stepMs);
    const visibleMin = recovery.at ? minutesBetween(found.at, recovery.at) : recovery.ongoing ? minutesBetween(found.at, new Date(telemetryEnd)) : null;
    const how = `${signal.label} ${boundText(bound, signal.kind)} (${bound.basis})${bound.minBins > 1 ? ` for ${bound.minBins} bins in a row` : ""}`;
    const why: keyof typeof NO_RECOVERY | null = recovery.at
        ? null
        : recovery.ongoing
          ? "ongoing"
          : nextRaising !== undefined && nextRaising < injectedEnd.getTime() + RECOVERY_SLACK_MINUTES * MIN
            ? "next"
            : "late";
    return {
        ...common,
        visibleAt: found.at,
        recoveredAt: recovery.at,
        ongoing: recovery.ongoing,
        ttdMin: minutesBetween(injectedAt, found.at),
        ttrMin: recovery.at ? minutesBetween(injectedAt, recovery.at) : null,
        visibleMin,
        status: "Pass",
        note: `Visible: ${how}.${why ? ` ${NO_RECOVERY[why].note}` : ""}`,
        recoveryNote: why ? NO_RECOVERY[why].note : "",
        recoveryWord: why ? NO_RECOVERY[why].word : "",
        impact: impactOf({ target, family: chosen.family === "deadlock" ? "blocking" : chosen.family, durationMin: visibleMin, ongoing: recovery.ongoing, peak, baseline }),
    };
}

/** Scores every fault of a plan. */
export function scorePlan(plan: Plan, ctx: ScoreContext): FaultScore[] {
    return plan.faults.map((run) => scoreFault(run, plan.key, ctx));
}

// ---------- T4 and T5: what their Azure Monitor metrics show ----------

/** A signal episode in T4's or T5's captured metrics. The history doesn't record when their beats were injected. */
export interface MeasuredEpisode {
    key: string;
    target: EstateTarget;
    /** throttle (T5), replica_lag (T4's replica), cpu or connections (T4). */
    family: string;
    signal: string;
    kind: NumberKind;
    visibleAt: Date;
    /** When the signal stopped (T5: the last 429), or null. */
    endAt: Date | null;
    recoveredAt: Date | null;
    ongoing: boolean;
    peak: number | null;
    throttled: number | null;
    requests: number | null;
    visibleMin: number | null;
    note: string;
    impact: Impact;
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

function evidenceOf(value: unknown): Record<string, unknown> {
    if (typeof value !== "string" || !value.trim().startsWith("{")) return {};
    try {
        const parsed: unknown = JSON.parse(value);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {};
    } catch {
        return {};
    }
}

/**
 * T5's throttling episodes: the notebook's own (cosmosdb.T5.throttle.<time> findings, with their 429s, requests, and
 * recovery), or, without them, the capture's throttled intervals (a 429, or normalized RU at 100 %).
 */
export function cosmosEpisodes(capture: CosmosCapture | null, findingRows: readonly Row[]): MeasuredEpisode[] {
    const out: MeasuredEpisode[] = [];
    const lastPoint = capture?.points[capture.points.length - 1]?.at ?? null;
    const step = (capture?.intervalMinutes ?? 1) * MIN;
    for (const r of findingRows) {
        const id = typeof r.FindingId === "string" ? r.FindingId : "";
        if (!id.startsWith("cosmosdb.T5.throttle.")) continue;
        const start = toDate(r.WindowStart);
        if (!start) continue;
        const end = toDate(r.WindowEnd);
        const evidence = evidenceOf(r.Evidence);
        // Only the notebook's measured recovery counts: "stopped" says the 429s stopped, not that the account recovered.
        const recovered = toDate(evidence.recoveredAtUtc);
        const ongoing = !recovered && evidence.stopped !== true;
        const throttled = num(evidence.throttled);
        const requests = num(evidence.requests);
        const peak = num(evidence.peakNormalizedRuPercent);
        const until = recovered ?? (ongoing ? lastPoint : end);
        const visibleMin = until ? minutesBetween(start, until) : null;
        out.push({
            key: id,
            target: "T5",
            family: "throttle",
            signal: "normalized RU and 429s",
            kind: "percent",
            visibleAt: start,
            endAt: end,
            recoveredAt: recovered,
            ongoing,
            peak,
            throttled,
            requests,
            visibleMin,
            note: recovered ? `Recovered: normalized RU under 100 % with no 429s from ${formatTimeUtc(recovered)} UTC.` : ongoing ? "Still throttled at the capture's end." : "The 429s stopped; its recovery isn't in the capture.",
            impact: impactOf({ target: "T5", family: "throttle", durationMin: visibleMin, ongoing, peak, throttled, requests }),
        });
    }
    if (out.length > 0 || !capture) return out.sort((a, b) => a.visibleAt.getTime() - b.visibleAt.getTime());
    const sum = (metric: string, from: number, to: number) =>
        cosmosSeries(capture, metric)
            .filter((p) => p.at.getTime() >= from && p.at.getTime() < to)
            .reduce((a, p) => a + p.value, 0);
    for (const run of throttledRuns(capture)) {
        const from = run.from.getTime();
        const to = run.to.getTime();
        const peak = cosmosSeries(capture, COSMOS_METRICS.normalizedRu)
            .filter((p) => p.at.getTime() >= from && p.at.getTime() < to)
            .reduce<number | null>((a, p) => (a === null || p.value > a ? p.value : a), null);
        const ongoing = lastPoint !== null && to > lastPoint.getTime() + step / 2;
        const recovered = ongoing ? null : run.to;
        const visibleMin = minutesBetween(run.from, recovered ?? lastPoint);
        const throttled = sum(COSMOS_METRICS.throttled, from, to);
        const requests = sum(COSMOS_METRICS.requests, from, to);
        out.push({
            key: `cosmos:${run.from.toISOString()}`,
            target: "T5",
            family: "throttle",
            signal: "normalized RU and 429s",
            kind: "percent",
            visibleAt: run.from,
            endAt: run.to,
            recoveredAt: recovered,
            ongoing,
            peak,
            throttled,
            requests: requests || null,
            visibleMin,
            note: recovered ? `Recovered from ${formatTimeUtc(recovered)} UTC.` : "Still throttled at the capture's end.",
            impact: impactOf({ target: "T5", family: "throttle", durationMin: visibleMin, ongoing, peak, throttled, requests: requests || null }),
        });
    }
    return out;
}

interface LevelRun {
    from: Date;
    /** The first point back under the level: its recovery; null when the capture ends or breaks off first. */
    to: Date | null;
    /** Its last point at the level, plus one interval: where the run is known to end. */
    end: Date;
    /** True only when the capture ends while it's at the level; a run the metrics break off from has no known recovery. */
    ongoing: boolean;
    peak: number;
}

/** Runs of points at or above a level (one interval apart at most). */
function runsAtOrAbove(points: ReadonlyArray<{ at: Date; value: number }>, level: number, minPoints: number, stepMs: number): LevelRun[] {
    const out: LevelRun[] = [];
    let run: Array<{ at: Date; value: number }> = [];
    const close = (next: { at: Date } | null, ongoing: boolean) => {
        if (run.length >= minPoints) {
            const last = run[run.length - 1].at.getTime();
            out.push({ from: run[0].at, to: next ? next.at : null, end: next ? next.at : new Date(last + stepMs), ongoing, peak: Math.max(...run.map((p) => p.value)) });
        }
        run = [];
    };
    for (const p of points) {
        const gap = run.length > 0 && p.at.getTime() - run[run.length - 1].at.getTime() > stepMs * 1.5;
        if (gap) close(null, false);
        if (p.value >= level) run.push(p);
        else close(p, false);
    }
    close(null, true);
    return out;
}

/** T4's episodes: its read replica's lag at or above 60 s (its catch-up after a restart left out), and its CPU at 80 % or more for 2 intervals. */
export function postgresEpisodes(capture: PostgresCapture | null): MeasuredEpisode[] {
    if (!capture) return [];
    const stepMs = (capture.intervalMinutes ?? 5) * MIN;
    const out: MeasuredEpisode[] = [];
    const episode = (target: EstateTarget, family: string, signal: string, kind: NumberKind, level: string, run: LevelRun): MeasuredEpisode => {
        const visibleMin = minutesBetween(run.from, run.to ?? run.end);
        const brokeOff = `Its metrics break off after ${formatTimeUtc(new Date(run.end.getTime() - stepMs))} UTC, so its recovery isn't in the capture.`;
        return {
            key: `postgres:${family}:${run.from.toISOString()}`,
            target,
            family,
            signal,
            kind,
            visibleAt: run.from,
            endAt: run.to ?? (run.ongoing ? null : run.end),
            recoveredAt: run.to,
            ongoing: run.ongoing,
            peak: run.peak,
            throttled: null,
            requests: null,
            visibleMin,
            note: run.to ? `Back under ${level} at ${formatTimeUtc(run.to)} UTC.` : run.ongoing ? `Still at ${level} or more at the capture's end.` : brokeOff,
            impact: impactOf({ target, family, durationMin: visibleMin, ongoing: run.ongoing, peak: run.peak }),
        };
    };
    const lag = postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag);
    const caught = new Set(replicaCatchUp(capture, lag));
    const replayed = lag.filter((p) => !caught.has(p));
    for (const run of runsAtOrAbove(replayed, REPLICA_LAG_WARNING_SECONDS, 1, stepMs)) out.push(episode("T4-replica", "replica_lag", "read replica lag", "seconds", `${REPLICA_LAG_WARNING_SECONDS} s`, run));
    const cpu = postgresSeries(capture, "T4", POSTGRES_METRICS.cpu);
    for (const run of runsAtOrAbove(cpu, 80, 2, stepMs)) out.push(episode("T4", "cpu", "CPU", "percent", "80 %", run));
    return out.sort((a, b) => a.visibleAt.getTime() - b.visibleAt.getTime());
}

/** The episodes that overlap a plan's window (T4's and T5's captures cover the latest session they were saved with). */
export function episodesIn(episodes: readonly MeasuredEpisode[], plan: Pick<Plan, "start" | "end">): MeasuredEpisode[] {
    const from = plan.start.getTime();
    const to = plan.end.getTime() + TELEMETRY_LAG_MINUTES * MIN;
    return episodes.filter((e) => e.visibleAt.getTime() < to && (e.recoveredAt ?? e.endAt ?? e.visibleAt).getTime() >= from);
}

// ---------- Summaries and aggregates ----------

export interface PlanSummary {
    faults: number;
    visible: number;
    notVisible: number;
    unmeasured: number;
    answered: number;
    recovered: number;
    ttdMedian: number | null;
    ttrMedian: number | null;
}

export function summarize(scores: readonly FaultScore[]): PlanSummary {
    const ttd = scores.map((s) => s.ttdMin).filter((v): v is number => v !== null);
    const ttr = scores.map((s) => s.ttrMin).filter((v): v is number => v !== null);
    return {
        faults: scores.length,
        visible: scores.filter((s) => s.status === "Pass").length,
        notVisible: scores.filter((s) => s.status === "Warning").length,
        unmeasured: scores.filter((s) => s.status === "Not supported").length,
        answered: scores.filter((s) => s.answeredAt !== null).length,
        recovered: scores.filter((s) => s.recoveredAt !== null).length,
        ttdMedian: median(ttd),
        ttrMedian: median(ttr),
    };
}

export interface Aggregate {
    key: string;
    label: string;
    faults: number;
    visible: number;
    ttdMedian: number | null;
    ttdN: number;
    ttrMedian: number | null;
    ttrN: number;
}

/** Times to detect and recover per engine (SQL Server, Azure SQL Database, ...) or per fault type, with how many faults each median rests on. */
export function aggregate(scores: readonly FaultScore[], by: "engine" | "type"): Aggregate[] {
    const groups = new Map<string, { label: string; items: FaultScore[] }>();
    for (const s of scores) {
        const key = by === "engine" ? engineOf(s.target).id : s.scenario;
        const label = by === "engine" ? engineOf(s.target).label : s.title;
        const group = groups.get(key) ?? { label, items: [] };
        group.items.push(s);
        groups.set(key, group);
    }
    return [...groups.entries()]
        .map(([key, { label, items }]) => {
            const ttd = items.map((s) => s.ttdMin).filter((v): v is number => v !== null);
            const ttr = items.map((s) => s.ttrMin).filter((v): v is number => v !== null);
            return { key, label, faults: items.length, visible: items.filter((s) => s.status === "Pass").length, ttdMedian: median(ttd), ttdN: ttd.length, ttrMedian: median(ttr), ttrN: ttr.length };
        })
        .sort((a, b) => b.faults - a.faults || a.label.localeCompare(b.label));
}

// ---------- The plan's events, for the ribbon and the replay ----------

export type PlanEventKind = "injected" | "visible" | "answered" | "recovered";

export interface PlanEvent {
    at: Date;
    kind: PlanEventKind;
    target: EstateTarget;
    /** The fault's or episode's key. */
    ref: string;
    label: string;
}

export const EVENT_LABEL: Record<PlanEventKind, string> = { injected: "Injected", visible: "Signal visible", answered: "Answered", recovered: "Recovered" };

/** Every fault's and episode's moments, in time order. */
export function planEvents(scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[] = []): PlanEvent[] {
    const out: PlanEvent[] = [];
    for (const s of scores) {
        out.push({ at: s.injectedAt, kind: "injected", target: s.target, ref: s.key, label: `${s.title} on ${s.target}` });
        if (s.visibleAt) out.push({ at: s.visibleAt, kind: "visible", target: s.target, ref: s.key, label: `${s.target} ${s.signal}` });
        if (s.answeredAt) out.push({ at: s.answeredAt, kind: "answered", target: s.target, ref: s.key, label: s.answer });
        if (s.recoveredAt) out.push({ at: s.recoveredAt, kind: "recovered", target: s.target, ref: s.key, label: `${s.target} back under its bound` });
    }
    for (const e of episodes) {
        out.push({ at: e.visibleAt, kind: "visible", target: e.target, ref: e.key, label: `${e.target} ${e.signal}` });
        if (e.recoveredAt) out.push({ at: e.recoveredAt, kind: "recovered", target: e.target, ref: e.key, label: `${e.target} recovered` });
    }
    const order: Record<PlanEventKind, number> = { injected: 0, visible: 1, answered: 2, recovered: 3 };
    return out.sort((a, b) => a.at.getTime() - b.at.getTime() || order[a.kind] - order[b.kind]);
}

/** The next fault to be injected after `at`, and in how many minutes: the replay's countdown. */
export function nextInjection(scores: readonly FaultScore[], at: Date): { score: FaultScore; inMin: number } | null {
    const next = [...scores].filter((s) => s.injectedAt.getTime() > at.getTime()).sort((a, b) => a.injectedAt.getTime() - b.injectedAt.getTime())[0];
    return next ? { score: next, inMin: (next.injectedAt.getTime() - at.getTime()) / MIN } : null;
}

export type TargetState = "calm" | "injected" | "visible" | "answered";

/** What a target is going through at a moment: a fault running whose signal hasn't shown, a visible signal, or one answered and not yet recovered. */
export function stateAt(scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[], target: EstateTarget, at: Date): TargetState {
    const t = at.getTime();
    let state: TargetState = "calm";
    const rank: Record<TargetState, number> = { calm: 0, injected: 1, answered: 2, visible: 3 };
    const raise = (next: TargetState) => {
        if (rank[next] > rank[state]) state = next;
    };
    for (const s of scores) {
        if (s.target !== target) continue;
        const end = (s.recoveredAt ?? (s.visibleAt ? new Date(s.injectedEnd.getTime() + TELEMETRY_LAG_MINUTES * MIN) : s.injectedEnd)).getTime();
        if (t < s.injectedAt.getTime() || t >= end) continue;
        if (s.answeredAt && t >= s.answeredAt.getTime()) raise("answered");
        else if (s.visibleAt && t >= s.visibleAt.getTime()) raise("visible");
        else raise("injected");
    }
    for (const e of episodes) {
        if (e.target !== target) continue;
        const end = (e.recoveredAt ?? e.endAt ?? e.visibleAt).getTime();
        if (t >= e.visibleAt.getTime() && t < end) raise("visible");
    }
    return state;
}

/** A duration for a table cell: "≤ 1 min" inside the first bin, else whole minutes. */
export function minutesText(minutes: number | null, binMinutes: number | null = null): string {
    if (minutes === null) return "–";
    if (binMinutes !== null && minutes < binMinutes) return `≤ ${binMinutes} min`;
    if (minutes < 1) return "< 1 min";
    return `${Math.round(minutes)} min`;
}
