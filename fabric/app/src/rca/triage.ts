// First-line triage: for a window, what was abnormal on each target, ranked, with the investigation that explains each.
// It answers "why was ContosoCare slow at 11:56?" before any deep dive, and says "nothing abnormal" when nothing was.
// Blind: its hypotheses are the detector's episodes and the errors and deadlocks the capture recorded.

import { describeEpisode } from "./detector";
import { AZURE_MONITOR } from "./errors";
import { asWholeReadings, hhmmss, metricIn, openSpan, plural, unknownFromOf, type Episode, type Evidence, type RcaTarget } from "./types";

export interface Hypothesis {
    target: RcaTarget;
    family: string;
    score: number;
    summary: string;
    /** The tool that explains it; run_dax on the telemetry for a signal Phase 1 doesn't investigate yet. */
    nextTool: string;
    episodeKey?: string;
}

export interface Triage {
    hypotheses: Hypothesis[];
    episodes: Episode[];
    quiet: RcaTarget[];
}

const NEXT_TOOL: Record<string, string> = {
    blocking: "explain_locking",
    deadlock: "explain_locking",
    replica_lag: "explain_replica_lag",
    errors: "explain_errors",
    // explain_incident with the episode's key explains these by what held the connections and the RU, beside any errors.
    connections: "explain_incident",
    throttling: "explain_errors",
    ru: "explain_incident",
};

function score(e: Episode): number {
    switch (e.family) {
        case "blocking":
            return 10 + Math.min(e.peak, 20) / 2;
        case "deadlock":
            return 8 + Math.min(e.peak, 10) / 2;
        case "cpu":
            return e.peak >= 90 ? 9 : 6;
        case "replica_lag":
            return 7 + Math.min(3, e.peak / 60);
        case "throttling":
        case "ru":
            return 8;
        case "connections":
            return 6;
        case "errors":
            return 4 + Math.min(4, Math.log10(e.peak + 1));
        default:
            return 3 + Math.min(5, e.peak);
    }
}

const inWindow = (at: Date, from: Date, to: Date) => at >= from && at <= to;

export function triageWindow(input: { evidence: Evidence; episodes: readonly Episode[] }, from: Date, to: Date, targets: readonly RcaTarget[], stoppedAt?: Date): Triage {
    const episodes = input.episodes.filter((e) => targets.includes(e.target) && e.start <= to && (e.end ?? e.last) >= from);
    const hypotheses: Hypothesis[] = episodes.map((e) => ({
        target: e.target,
        family: e.family,
        score: Math.round(score(e) * 10) / 10,
        summary: describeEpisode(e),
        nextTool: NEXT_TOOL[e.family] ?? "run_dax",
        episodeKey: e.key,
    }));
    // T5's 429s and its normalized RU at 100 % are one incident to a DBA: the throttling, with its RU in the same words.
    for (const ru of hypotheses.filter((h) => h.family === "ru")) {
        const episode = episodes.find((e) => e.key === ru.episodeKey);
        const throttling = hypotheses.find((h) => h.family === "throttling" && h.target === ru.target && episodes.some((e) => e.key === h.episodeKey && episode && e.start <= (episode.end ?? episode.last) && (e.end ?? e.last) >= episode.start));
        if (!throttling || !episode) continue;
        throttling.summary = `${throttling.summary} Normalized RU consumption was at ${Math.round(episode.peak)} % in the same minutes.`;
        hypotheses.splice(hypotheses.indexOf(ru), 1);
    }
    // Errors that no burst opened an episode for still count: a DBA reads every class of them (429s are the throttling's).
    for (const target of targets) {
        if (hypotheses.some((h) => h.target === target && h.family === "errors")) continue;
        const events = input.evidence.events.filter((e) => e.target === target && (e.kind === "error" || e.kind === "attention") && inWindow(e.at, from, to));
        const throttled = hypotheses.some((h) => h.target === target && h.family === "throttling");
        // A split point's pieces count as its one whole count (the review of c4c63abe).
        const counted = asWholeReadings(input.evidence.metrics.filter((m) => m.target === target && (m.metric === "connections_failed" || (m.metric === "ThrottledRequests" && !throttled)) && metricIn(m, from, to))).filter((m) => m.value !== null && m.value > 0);
        const n = events.reduce((sum, e) => sum + e.count, 0) + counted.reduce((sum, m) => sum + (m.value ?? 0), 0);
        if (n === 0) continue;
        // An Azure Monitor count stands for its whole interval, as in errors.ts (the review of 858c50c2: one 5-minute count of
        // failed connections read "from 15:30:00 to 15:30:00").
        const first = new Date(Math.min(...events.map((e) => e.at.getTime()), ...counted.map((m) => m.at.getTime())));
        const last = new Date(Math.max(...events.map((e) => e.at.getTime()), ...counted.map((m) => m.at.getTime() + (m.intervalMs ?? 0))));
        // A count whose interval isn't known ends in it, no one knows where (the review of 4667459c).
        const unknownFrom = unknownFromOf(counted);
        const where = counted.length > 0 ? ` (${AZURE_MONITOR} counts included)` : "";
        // A read that stopped short counted them only up to there (the review of d431edb4).
        const span = stoppedAt ? `at least ${plural(n, "error or cancel", "errors and cancels")} from ${hhmmss(first)} UTC through ${hhmmss(stoppedAt)} UTC, where the read stopped` : `${plural(n, "error or cancel", "errors and cancels")} ${unknownFrom ? openSpan(first, unknownFrom) : `${first.getTime() === last.getTime() ? `at ${hhmmss(first)}` : `from ${hhmmss(first)} to ${hhmmss(last)}`} UTC`}`;
        hypotheses.push({ target, family: "errors", score: Math.round((4 + Math.min(4, Math.log10(n + 1))) * 10) / 10, summary: `${target}: ${span}${where}.`, nextTool: "explain_errors" });
    }
    hypotheses.sort((a, b) => b.score - a.score);
    const flagged = new Set(hypotheses.map((h) => h.target));
    return { hypotheses, episodes, quiet: targets.filter((t) => !flagged.has(t)) };
}
