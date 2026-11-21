// The time frame the ribbon and the replay share, so the playhead, the lanes, and the engines' charts line up.

import { formatDayUtc, formatTimeUtc } from "@/lib/format";
import { TELEMETRY_LAG_MINUTES, type FaultScore, type MeasuredEpisode, type Plan } from "@/lib/scoreboard";

const MIN = 60000;

/** A session in a picker: its label and its window. */
export function planOption(plan: Plan): string {
    return `${plan.label} · ${formatDayUtc(plan.start)} ${formatTimeUtc(plan.start)}–${formatTimeUtc(plan.end)} UTC`;
}

/** The moments' shapes, so no moment is told by color alone. */
export const MARKS = { injected: "▼", visible: "●", answered: "◆", recovered: "✓" } as const;

/** The plan's range: from its start (or its first fault) to the last moment any fault or episode reaches, with 3 minutes of room. */
export function ribbonRange(plan: Pick<Plan, "start" | "end">, scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[]): [number, number] {
    let from = plan.start.getTime();
    let to = plan.end.getTime();
    for (const s of scores) {
        from = Math.min(from, s.injectedAt.getTime());
        to = Math.max(to, s.injectedEnd.getTime(), (s.recoveredAt ?? (s.visibleAt ? new Date(s.injectedEnd.getTime() + TELEMETRY_LAG_MINUTES * MIN) : s.injectedEnd)).getTime());
    }
    for (const e of episodes) {
        from = Math.min(from, e.visibleAt.getTime());
        to = Math.max(to, (e.recoveredAt ?? e.endAt ?? e.visibleAt).getTime());
    }
    return [from - 3 * MIN, to + 3 * MIN];
}
