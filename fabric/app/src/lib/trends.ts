// Week over week per target, from the daily history: the newest week against the week before it.

import type { DayRow } from "@/data/model";
import { formatNumber } from "./format";

export interface ChangeRow extends Record<string, unknown> {
    target: string;
    cpuNow: number | null;
    cpuBefore: number | null;
    waitNow: number | null;
    waitBefore: number | null;
    incidentsNow: number;
    incidentsBefore: number;
}

export const pct = (now: number | null, before: number | null) => (now === null || before === null || before === 0 ? null : ((now - before) / before) * 100);
export const change = (now: number | null, before: number | null) => {
    const p = pct(now, before);
    return p === null ? "–" : `${p >= 0 ? "+" : ""}${formatNumber(p, "decimal")} %`;
};

const mean = (values: Array<number | null>) => {
    const v = values.filter((x): x is number => x !== null);
    return v.length ? v.reduce((a, x) => a + x, 0) / v.length : null;
};
const sum = (values: Array<number | null>) => values.reduce<number>((a, x) => a + (x ?? 0), 0);

/** The newest week against the week before it, per target. */
export function weekOverWeek(days: readonly DayRow[]): ChangeRow[] {
    if (days.length === 0) return [];
    const newest = Math.max(...days.map((d) => d.day.getTime()));
    const weekStart = newest - 6 * 86400000;
    const priorStart = weekStart - 7 * 86400000;
    const targets = [...new Set(days.map((d) => d.target))].sort();
    return targets.map((t) => {
        const now = days.filter((d) => d.target === t && d.day.getTime() >= weekStart);
        const before = days.filter((d) => d.target === t && d.day.getTime() >= priorStart && d.day.getTime() < weekStart);
        return {
            target: t,
            cpuNow: mean(now.map((d) => d.cpuAvg)),
            cpuBefore: before.length ? mean(before.map((d) => d.cpuAvg)) : null,
            waitNow: sum(now.map((d) => d.waitS)),
            waitBefore: before.length ? sum(before.map((d) => d.waitS)) : null,
            incidentsNow: now.reduce((a, d) => a + d.incidents, 0),
            incidentsBefore: before.reduce((a, d) => a + d.incidents, 0),
        };
    });
}

