// Pure data shaping for the custom visuals, kept apart from the components so it can be unit tested.

import type { Bin, Check, Incident, WaitBin } from "@/data/model";
import { worstStatus, type StatusMeta } from "@/lib/status";

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
