// Times in questions: "11:56" means the viewer's wall-clock time on the history's newest day, in the viewer's time zone
// (the browser's, Intl), and answers say both. The history is UTC.

/** The time zone's offset from UTC at an instant, in milliseconds (positive east of UTC). */
export function offsetMs(at: Date, timeZone: string): number {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }).formatToParts(at);
    const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
    const wall = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
    return wall - Math.floor(at.getTime() / 1000) * 1000;
}

/**
 * The UTC instant of a time the viewer typed: "11:56", "11:56:30", "12:14 UTC", or an ISO timestamp. Bare times are on
 * `day` (the newest day in the history, as the system message anchors "today") in `timeZone`.
 */
export function resolveTime(text: string, day: Date, timeZone: string): Date | null {
    const t = text.trim();
    if (/^\d{4}-\d{2}-\d{2}T/.test(t)) {
        const d = new Date(t);
        return Number.isNaN(d.getTime()) ? null : d;
    }
    const m = /^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?\s*(utc|z)?$/i.exec(t);
    if (!m) return null;
    let hour = Number(m[1]);
    const minute = Number(m[2]);
    const second = Number(m[3] ?? 0);
    if (m[4]) hour = (hour % 12) + (m[4].toLowerCase() === "pm" ? 12 : 0);
    if (hour > 23 || minute > 59 || second > 59) return null;
    const guess = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate(), hour, minute, second);
    if (m[5]) return new Date(guess);
    // Two passes settle the offset across a daylight-saving change.
    let at = guess - offsetMs(new Date(guess), timeZone);
    at = guess - offsetMs(new Date(at), timeZone);
    return new Date(at);
}

/** "12:14 EST (17:14 UTC)": how answers state a time. */
export function bothTimes(at: Date, timeZone: string): string {
    const local = new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZoneName: "short" }).format(at);
    return `${local} (${at.toISOString().slice(11, 16)} UTC)`;
}

export function windowAround(at: Date, minutesBefore = 5, minutesAfter = 5): { from: Date; to: Date } {
    return { from: new Date(at.getTime() - minutesBefore * 60000), to: new Date(at.getTime() + minutesAfter * 60000) };
}
