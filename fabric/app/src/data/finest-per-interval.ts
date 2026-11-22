// One point per interval from the history's overlapping saves (F35), shared by the app's T4 and T5 views and the RCA's
// investigations: the same code in both, so the two read the same numbers.

import { toDate } from "@/lib/format";

type Row = Record<string, unknown>;

const MINUTE = 60_000;

/** T5's metrics that Azure Monitor reports hourly at the finest (CosmosHistoryHelpers.ps1: Hourly). */
export const HOURLY_METRICS: ReadonlySet<string> = new Set(["ProvisionedThroughput", "ServiceAvailability"]);

/**
 * The series whose points add up over time: the notebook's per-bin deltas and sums, by analysis, and Azure Monitor's
 * Total and Count metrics, by name (PostgresHistoryHelpers.ps1 and CosmosHistoryHelpers.ps1). Every other series is a
 * maximum or an average. A test ties both lists to their producers.
 */
export const ADDITIVE_ANALYSES: ReadonlySet<string> = new Set(["wait_deltas", "counter_deltas", "storage_io"]);
export const ADDITIVE_METRICS: ReadonlySet<string> = new Set(["TotalRequests", "ThrottledRequests", "TotalRequestUnits", "connections_failed"]);

/**
 * The notebooks' analyses that aren't on the bin grid: no bin (wait_profile, estate_pulse), or a last sample's time
 * (memory_clerks, database_growth, telemetry_coverage). They're never passed to finestPerInterval, and the history's
 * measures keep their newest capture.
 */
export const OFF_GRID_ANALYSES: ReadonlySet<string> = new Set(["wait_profile", "estate_pulse", "memory_clerks", "database_growth", "telemetry_coverage"]);

/** One point's key, by its target, its metric as the history names it, and its interval's start. */
export const pointKey = (target: string, metric: string, at: Date) => `${target}|${metric}|${at.getTime()}`;

/** Whether a row's series adds up over time (a count, a total, or a delta); otherwise it's a maximum or an average. */
export function addsUp(row: Row): boolean {
    return ADDITIVE_ANALYSES.has(String(row.AnalysisKey ?? "")) || ADDITIVE_METRICS.has(String(row.Metric));
}

interface Span {
    start: number;
    end: number;
    value: number | null;
}

interface Point extends Span {
    row: Row;
    at: number;
    grain: number;
    captured: number;
}

function numberOf(value: unknown): number | null {
    if (typeof value === "number") return Number.isFinite(value) ? value : null;
    if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
    return null;
}

/** The spans that overlap [start, end), from spans sorted by start that don't overlap each other. */
function overlapping(spans: readonly Span[], start: number, end: number): Span[] {
    let lo = 0;
    let hi = spans.length;
    while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (spans[mid].end <= start) lo = mid + 1;
        else hi = mid;
    }
    const found: Span[] = [];
    for (let i = lo; i < spans.length && spans[i].start < end; i++) found.push(spans[i]);
    return found;
}

function insert(spans: Span[], span: Span): void {
    let lo = 0;
    let hi = spans.length;
    while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (spans[mid].start < span.start) lo = mid + 1;
        else hi = mid;
    }
    spans.splice(lo, 0, span);
}

/** The stretches of [start, end) that none of the (sorted) spans covers. */
function gapsIn(spans: readonly Span[], start: number, end: number): Array<[number, number]> {
    const gaps: Array<[number, number]> = [];
    let from = start;
    for (const span of spans) {
        if (span.start > from) gaps.push([from, Math.min(span.start, end)]);
        from = Math.max(from, span.end);
        if (from >= end) break;
    }
    if (from < end) gaps.push([from, end]);
    return gaps;
}

/** A total split across stretches by their length, in whole numbers when the total is one (largest remainders first). */
function shares(total: number, lengths: readonly number[]): number[] {
    if (lengths.length === 1) return [total];
    const all = lengths.reduce((a, b) => a + b, 0);
    const exact = lengths.map((length) => (total * length) / all);
    if (!Number.isInteger(total)) return exact;
    const whole = exact.map((x) => Math.floor(x));
    let left = total - whole.reduce((a, b) => a + b, 0);
    const order = exact.map((x, i) => ({ i, rest: x - whole[i] })).sort((a, b) => b.rest - a.rest || a.i - b.i);
    for (const { i } of order) {
        if (left <= 0) break;
        whole[i] += 1;
        left -= 1;
    }
    return whole;
}

/** A moved point's Bucket, in the kind and the format of the row's own. */
function bucketAt(original: unknown, ms: number): unknown {
    if (original instanceof Date) return new Date(ms);
    if (typeof original === "number") return ms;
    const text = String(original).trim();
    const iso = new Date(ms).toISOString();
    const core = /\.\d/.test(text) || ms % 1000 !== 0 ? iso.slice(0, 23) : iso.slice(0, 19);
    return /[zZ]$|[+-]\d\d:?\d\d$/.test(text) ? `${core}Z` : core;
}

/**
 * The history's binned points, one per interval: Azure Monitor's metrics of T4, its read replica, and T5, or the notebook's
 * SQL telemetry, with no off-grid analysis. The history keeps every save, each at its own grain (1 to 1,440 minutes), so
 * one minute can be in several. By pointKey, `intervals` holds each kept point's span (what it covers, for coverage and
 * sums) and `grains` its save's step (Azure Monitor's or the notebook's interval, to step runs by and name).
 *
 * - A point's grain is its save's step: the smallest gap in any of the save's series (T5's hourly metrics, at least an
 *   hour). Its data is its interval's inside its save's window, so a save that starts or ends inside an interval cuts it.
 * - The finest grain is kept first, and of equal grains the newest save.
 * - A coarser point is left out only where the kept points cover all of it. Otherwise it stays for the minutes they
 *   don't cover: a count or a total (addsUp) as its total less theirs, and a maximum or an average only when it's higher
 *   than every point it overlaps. Each uncovered stretch is a point of its own, at its start, with its own span and the
 *   coarser point's `SourceKey`; a total is split across stretches by their length. A peak over two or more stretches is
 *   given to each, marked `UpperBound`: it's one reading, from somewhere in them. A lower peak keeps no point, but still
 *   covers its stretches, so a yet coarser save's peak can't land where it says the value was lower.
 *
 * So no minute counts twice, and none is lost. In a live test's history (2026-11-21), the newest-per-bin rule kept a
 * day-long save's 15-minute totals beside the session's own 1-minute points, so T5's requests counted twice. Dropping
 * every coarser point that overlaps would have lost the replica's 34 s of lag from 16:57 to 17:00, after the session's
 * window ended. Assumes nested, aligned grids: each grain divides the next, counted from midnight UTC.
 */
export function finestPerInterval(rows: readonly Row[]): { kept: Row[]; intervals: Map<string, number>; grains: Map<string, number> } {
    const familyOf = (row: Row) => (row.TargetKey === "T5" ? "cosmos" : row.TargetKey === "T4" || row.TargetKey === "T4-replica" ? "postgres" : "sql");
    const captureOf = (row: Row) => `${String(row.CapturedAt)}|${familyOf(row)}`;
    const seriesOf = (row: Row) => `${String(row.TargetKey)}|${String(row.AnalysisKey ?? "")}|${String(row.Metric)}`;

    // One save reads every series at one interval, so a series with gaps (intervals without data) or a single point has
    // the save's step too.
    const times = new Map<string, { capture: string; at: Set<number> }>();
    for (const row of rows) {
        const at = toDate(row.Bucket);
        if (!at || HOURLY_METRICS.has(String(row.Metric))) continue;
        const key = `${String(row.CapturedAt)}|${seriesOf(row)}`;
        const series = times.get(key) ?? { capture: captureOf(row), at: new Set<number>() };
        series.at.add(at.getTime());
        times.set(key, series);
    }
    const captureStep = new Map<string, number>();
    for (const series of times.values()) {
        const sorted = [...series.at].sort((a, b) => a - b);
        for (let i = 1; i < sorted.length; i++) {
            const gap = sorted[i] - sorted[i - 1];
            const step = captureStep.get(series.capture);
            if (step === undefined || gap < step) captureStep.set(series.capture, gap);
        }
    }

    const groups = new Map<string, Point[]>();
    for (const row of rows) {
        const date = toDate(row.Bucket);
        if (!date) continue;
        const at = date.getTime();
        const step = captureStep.get(captureOf(row)) ?? 0;
        const grain = HOURLY_METRICS.has(String(row.Metric)) ? Math.max(60 * MINUTE, step) : step;
        let start = at;
        let end = at + Math.max(grain, 1);
        if (grain > 0) {
            const from = Math.max(start, toDate(row.WindowStart)?.getTime() ?? start);
            const to = Math.min(end, toDate(row.WindowEnd)?.getTime() ?? end);
            if (from < to) [start, end] = [from, to];
        }
        const group = groups.get(seriesOf(row)) ?? [];
        group.push({ row, at, grain, captured: toDate(row.CapturedAt)?.getTime() ?? 0, start, end, value: numberOf(row.Value) });
        groups.set(seriesOf(row), group);
    }

    const kept: Array<{ row: Row; at: number }> = [];
    const intervals = new Map<string, number>();
    const grains = new Map<string, number>();
    const keep = (p: Point, start: number, end: number, value: number | null, marks?: Row) => {
        const row = start === p.at && value === p.value && !marks ? p.row : { ...p.row, Bucket: bucketAt(p.row.Bucket, start), Value: value, ...marks };
        kept.push({ row, at: start });
        if (p.grain > 0) {
            const key = pointKey(String(p.row.TargetKey), String(p.row.Metric), new Date(start));
            intervals.set(key, end - start);
            grains.set(key, p.grain);
        }
    };
    for (const group of groups.values()) {
        // The finest grain first, a point of unknown grain last; of equal grains, the newest capture.
        group.sort((a, b) => (a.grain || Infinity) - (b.grain || Infinity) || b.captured - a.captured || a.at - b.at);
        const taken: Span[] = [];
        for (const p of group) {
            const under = overlapping(taken, p.start, p.end);
            if (under.length === 0) {
                keep(p, p.start, p.end, p.value);
                insert(taken, { start: p.start, end: p.end, value: p.value });
                continue;
            }
            const gaps = gapsIn(under, p.start, p.end);
            if (gaps.length === 0 || p.value === null || p.grain === 0) continue;
            const values = under.map((s) => s.value).filter((v): v is number => v !== null);
            const source = { SourceKey: pointKey(String(p.row.TargetKey), String(p.row.Metric), new Date(p.at)) };
            if (addsUp(p.row)) {
                const pieces = shares(Math.max(0, p.value - values.reduce((a, b) => a + b, 0)), gaps.map(([from, to]) => to - from));
                gaps.forEach(([from, to], i) => {
                    keep(p, from, to, pieces[i], source);
                    insert(taken, { start: from, end: to, value: pieces[i] });
                });
                continue;
            }
            const higher = values.length === 0 || p.value > Math.max(...values);
            for (const [from, to] of gaps) {
                if (higher) keep(p, from, to, p.value, gaps.length > 1 ? { ...source, UpperBound: true } : source);
                insert(taken, { start: from, end: to, value: p.value });
            }
        }
    }
    kept.sort((a, b) => a.at - b.at);
    return { kept: kept.map((k) => k.row), intervals, grains };
}
