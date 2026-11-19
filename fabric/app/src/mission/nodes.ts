// The service map's nodes from the history: each target's health (the same as Overview's), its key number for the
// technical lens, and, for the business lens, the session's most lasting measured impact on its service.

import type { TargetHealth } from "@/lib/health";
import { stateAt, type FaultScore, type MeasuredEpisode } from "@/lib/scoreboard";
import type { Impact } from "@/lib/business";
import type { EstateTarget } from "@/lib/view-state";
import type { MapNode } from "./ServiceMap";

interface Felt {
    impact: Impact;
    minutes: number;
}

/** The impact a target's service felt longest in the session, or null when nothing showed. */
export function longestImpact(target: EstateTarget, scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[]): Impact | null {
    const felt: Felt[] = [
        ...scores.filter((s) => s.target === target && s.impact).map((s) => ({ impact: s.impact as Impact, minutes: s.visibleMin ?? 0 })),
        ...episodes.filter((e) => e.target === target).map((e) => ({ impact: e.impact, minutes: e.visibleMin ?? 0 })),
    ];
    return felt.sort((a, b) => b.minutes - a.minutes)[0]?.impact ?? null;
}

/** "under heavy load for 23 min", from "Scheduling: under heavy load for 23 min", as the map's line under the service's name. */
export function impactLine(impact: Impact | null): string | null {
    if (!impact) return null;
    const words = impact.headline.slice(impact.service.length).replace(/^:\s*/, "");
    return words.charAt(0).toUpperCase() + words.slice(1);
}

export function mapNodes(health: readonly TargetHealth[], scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[], at: Date | null = null): MapNode[] {
    const nodes: MapNode[] = [];
    for (const h of health) {
        const target = h.key;
        const impact = longestImpact(target, scores, episodes);
        const first = h.metrics[0];
        nodes.push({
            target,
            status: h.status,
            state: at ? stateAt(scores, episodes, target, at) : undefined,
            metric: first ? `${first.label} ${first.value}` : h.note,
            impact: impactLine(impact),
            evidence: impact?.evidence ?? null,
            events: scores.filter((s) => s.target === target).length + episodes.filter((e) => e.target === target).length,
        });
        if (target === "T4" && h.reporting) {
            const lag = longestImpact("T4-replica", scores, episodes);
            const replicaEpisodes = episodes.filter((e) => e.target === "T4-replica");
            const lagMetric = h.metrics.find((m) => m.label === "Replica lag");
            nodes.push({
                target: "T4-replica",
                status: replicaEpisodes.length > 0 ? "Warning" : "Pass",
                state: at ? stateAt(scores, episodes, "T4-replica", at) : undefined,
                metric: lagMetric ? `Replica lag ${lagMetric.value}` : "Replica lag",
                impact: impactLine(lag),
                evidence: lag?.evidence ?? null,
                events: replicaEpisodes.length,
            });
        }
    }
    return nodes;
}
