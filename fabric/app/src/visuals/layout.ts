// Pure data shaping for the custom visuals, kept apart from the components so it can be unit tested.

import { waitFamily, type Bin, type Check, type Incident, type TargetSummary, type WaitBin, type WaitFlow } from "@/data/model";
import type { TargetKey } from "@/lib/dax";
import { formatNumber, type NumberKind } from "@/lib/format";
import { quantile } from "@/lib/stats";
import { statusBySort, worstStatus, type StatusMeta } from "@/lib/status";
import type { ClockMetric, SignalId } from "@/lib/view-state";

// ---------- Activity clock ----------

export const CLOCK_METRICS: Record<ClockMetric, { label: string; field: "batch" | "waitS" | "sessions"; kind: "int" | "seconds"; combine: "sum" | "max" }> = {
    waits: { label: "Wait time", field: "waitS", kind: "seconds", combine: "sum" },
    batch: { label: "Batch requests", field: "batch", kind: "int", combine: "sum" },
    sessions: { label: "Sessions, peak", field: "sessions", kind: "int", combine: "max" },
};

export interface ClockCell {
    target: TargetKey;
    hour: number;
    value: number;
    bins: number;
}

/** Folds every bin into 24 UTC hours per target. */
export function clockCells(bins: readonly Bin[], metric: ClockMetric, targets: readonly TargetKey[]): ClockCell[] {
    const { field, combine } = CLOCK_METRICS[metric];
    const cells = new Map<string, ClockCell>();
    for (const t of targets) for (let h = 0; h < 24; h++) cells.set(`${t}:${h}`, { target: t, hour: h, value: 0, bins: 0 });
    for (const b of bins) {
        const cell = cells.get(`${b.target}:${b.at.getUTCHours()}`);
        const v = b[field];
        if (!cell || v === null) continue;
        cell.value = combine === "sum" ? cell.value + v : Math.max(cell.value, v);
        cell.bins += 1;
    }
    return [...cells.values()];
}

// ---------- Constellation ----------

export function constellationSummary(targets: readonly TargetSummary[]): string {
    if (targets.length === 0) return "No target sent telemetry in this period.";
    return targets
        .map((t) => {
            const status = statusBySort(t.worstFindingSort);
            const worst = status ? `worst finding ${status.name}` : "no findings";
            return `${t.key}: ${worst}, ${formatNumber(t.waitS, "seconds")} of waits, CPU peak ${formatNumber(t.cpuPeak, "percent")}, telemetry lag ${formatNumber(t.lagMin, "minutes")}`;
        })
        .join(". ");
}

// ---------- Readiness rings ----------

export interface AreaRing {
    area: string;
    checks: Check[];
    worst: StatusMeta | null;
    history: Array<{ runId: string; worst: StatusMeta | null }>;
}

/** Groups the latest run's checks by area, with the worst status of the same area in the earlier runs. */
export function areaRings(checks: readonly Check[]): { latestRun: string; runs: string[]; areas: AreaRing[] } {
    const runs = [...new Set(checks.map((c) => c.runId))].sort().reverse();
    const latestRun = runs[0] ?? "";
    const latest = checks.filter((c) => c.runId === latestRun);
    const areas = [...new Set(latest.map((c) => c.area))].sort();
    return {
        latestRun,
        runs,
        areas: areas.map((area) => ({
            area,
            checks: latest.filter((c) => c.area === area).sort((a, b) => a.statusSort - b.statusSort),
            worst: worstStatus(latest.filter((c) => c.area === area).map((c) => c.status)),
            history: runs.slice(1).map((runId) => ({ runId, worst: worstStatus(checks.filter((c) => c.runId === runId && c.area === area).map((c) => c.status)) })),
        })),
    };
}

export interface DialSegment {
    meta: StatusMeta;
    count: number;
    startAngle: number;
    endAngle: number;
}

/** Splits the dial's sweep into one arc per status, in status order, sized by its count. */
export function dialSegments(counts: ReadonlyArray<{ meta: StatusMeta; count: number }>, start: number, sweep: number): DialSegment[] {
    const shown = counts.filter((x) => x.count > 0);
    const total = Math.max(
        1,
        shown.reduce((a, x) => a + x.count, 0),
    );
    const out: DialSegment[] = [];
    let cursor = start;
    for (const x of shown) {
        const end = cursor + (sweep * x.count) / total;
        out.push({ meta: x.meta, count: x.count, startAngle: cursor, endAngle: end });
        cursor = end;
    }
    return out;
}

// ---------- Incident replay ----------

/** Minutes between consecutive bins: 1, 5, or 15 depending on how long the notebook's analysis window was. */
export function binMinutes(bins: readonly Bin[]): number {
    const gaps: number[] = [];
    for (let i = 1; i < bins.length; i++) gaps.push((bins[i].at.getTime() - bins[i - 1].at.getTime()) / 60000);
    gaps.sort((a, b) => a - b);
    return gaps.length ? Math.max(1, gaps[Math.floor(gaps.length / 2)]) : 15;
}

export function phaseOf(incident: Incident, at: Date): "before" | "during" | "after" {
    if (at < incident.start) return "before";
    return at < incident.end ? "during" : "after";
}

// ---------- Spotlight ----------

export interface SpotlightRow {
    category: string;
    before: number;
    during: number;
}

/** Mean wait seconds per bin and category, in the padding before the window and inside it. */
export function spotlightRows(incident: Incident, waits: readonly WaitBin[], padMinutes: number, top = 8): SpotlightRow[] {
    const beforeStart = incident.start.getTime() - padMinutes * 60000;
    const beforeBins = new Set<number>();
    const duringBins = new Set<number>();
    const sums = new Map<string, { before: number; during: number }>();
    for (const w of waits) {
        const t = w.at.getTime();
        const phase = t >= beforeStart && t < incident.start.getTime() ? "before" : t >= incident.start.getTime() && t < incident.end.getTime() ? "during" : null;
        if (!phase) continue;
        (phase === "before" ? beforeBins : duringBins).add(t);
        const entry = sums.get(w.category) ?? { before: 0, during: 0 };
        entry[phase] += w.seconds;
        sums.set(w.category, entry);
    }
    return [...sums.entries()]
        .map(([category, s]) => ({ category, before: beforeBins.size ? s.before / beforeBins.size : 0, during: duringBins.size ? s.during / duringBins.size : 0 }))
        .sort((a, b) => Math.max(b.before, b.during) - Math.max(a.before, a.during))
        .slice(0, top);
}

// ---------- Wait flow ----------

/** Categories under 1 % of the wait time fold into "Other categories" so the flow stays readable. */
export function foldFlows(flows: readonly WaitFlow[]): WaitFlow[] {
    const total = flows.reduce((a, f) => a + f.seconds, 0);
    const byCategory = new Map<string, number>();
    for (const f of flows) byCategory.set(f.category, (byCategory.get(f.category) ?? 0) + f.seconds);
    const small = new Set([...byCategory.entries()].filter(([, s]) => s < total * 0.01).map(([c]) => c));
    const out = new Map<string, WaitFlow>();
    for (const f of flows) {
        const category = small.has(f.category) ? "Other categories" : f.category;
        const key = `${category}|${f.target}`;
        const prev = out.get(key);
        out.set(key, { category, target: f.target, seconds: (prev?.seconds ?? 0) + f.seconds });
    }
    return [...out.values()];
}

export function familyOf(category: string): string {
    return category === "Other categories" ? "Other" : waitFamily(category);
}

/** Wait families in order of first appearance; the palette index follows this order. */
export function familiesOf(flows: readonly WaitFlow[]): string[] {
    return [...new Set(flows.map((f) => familyOf(f.category)))];
}

// ---------- Ridgeline ----------

export const RIDGE_SIGNALS: Record<SignalId, { label: string; field: keyof Bin; kind: NumberKind }> = {
    waits: { label: "Wait time per bin", field: "waitS", kind: "seconds" },
    bufferIo: { label: "Buffer IO waits per bin", field: "bufferIoS", kind: "seconds" },
    cpu: { label: "CPU per bin", field: "cpu", kind: "percent" },
    sessions: { label: "Active sessions per bin", field: "sessions", kind: "int" },
    batch: { label: "Batch requests per bin", field: "batch", kind: "int" },
};

export interface Ridge {
    target: TargetKey;
    values: number[];
    median: number | null;
    p95: number | null;
}

export function ridges(bins: readonly Bin[], signal: SignalId, targets: readonly TargetKey[]): Ridge[] {
    const field = RIDGE_SIGNALS[signal].field;
    return targets.map((target) => {
        const values = bins.filter((b) => b.target === target).map((b) => b[field] as number | null).filter((v): v is number => v !== null);
        return { target, values, median: quantile(values, 0.5), p95: quantile(values, 0.95) };
    });
}
