// Times in questions: "11:56" means the viewer's wall-clock time, in the viewer's time zone (the browser's, Intl), at its
// latest occurrence up to the history's newest data; "11:56 UTC" likewise in UTC; a date and time is taken as written.
// Answers say both local and UTC. The history is UTC.

/**
 * A clock time up to this long after the history's newest data stays on that data's day: the capture can run past the
 * newest telemetry bin, and Database Hub's telemetry arrives minutes late.
 */
export const LATER_THAN_NEWEST_MS = 60 * 60_000;

/** The time zone's offset from UTC at an instant, in milliseconds (positive east of UTC). */
export function offsetMs(at: Date, timeZone: string): number {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }).formatToParts(at);
    const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
    const wall = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
    return wall - Math.floor(at.getTime() / 1000) * 1000;
}

/** The UTC instant of a wall-clock time on a date (month 1 to 12) in `timeZone`; two passes settle the offset across a daylight-saving change. */
function localToUtc(year: number, month: number, day: number, hour: number, minute: number, second: number, timeZone: string): Date {
    const guess = Date.UTC(year, month - 1, day, hour, minute, second);
    let at = guess - offsetMs(new Date(guess), timeZone);
    at = guess - offsetMs(new Date(at), timeZone);
    return new Date(at);
}

/**
 * The latest of a clock time on the day before, its day, and the day after that's no later than the newest data allows.
 * Across UTC midnight, "23:15 UTC" fell on the newest bin's day, 22 hours after it (the re-review of 817b81c).
 */
function latestUpTo(on: (days: number) => Date, newest?: Date): Date {
    if (!newest) return on(0);
    const limit = newest.getTime() + LATER_THAN_NEWEST_MS;
    return [on(1), on(0)].find((at) => at.getTime() <= limit) ?? on(-1);
}

const DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})(?:t|\s+)(\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d{1,9})?)?\s*(utc|z|[+-]\d{2}:?\d{2})?$/i;
const CLOCK = /^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?\s*(utc|z)?$/i;

/**
 * The UTC instant of a time the viewer typed. A date and time ("2026-11-17T13:30:00Z", "2026-11-17 13:30 UTC", or with an
 * offset; without a zone, the viewer's time zone) is taken as written. A clock time ("11:56", "11:56:30", "1:30 pm", or
 * "12:14 UTC") is the latest such time up to `newest`, the history's newest time, plus LATER_THAN_NEWEST_MS: bare times
 * in `timeZone` from `day` (the newest day in the history there, as the system message anchors "today"), UTC times from
 * newest's UTC day, since the viewer's own date can be a day off from it (the review of 34a9732).
 */
export function resolveTime(text: string, day: Date, timeZone: string, newest?: Date): Date | null {
    const t = text.trim();
    const full = DATE_TIME.exec(t);
    if (full) {
        const [year, month, date, hour, minute, second] = full.slice(1, 7).map((v) => Number(v ?? 0));
        if (month < 1 || month > 12 || date < 1 || hour > 23 || minute > 59 || second > 59) return null;
        if (new Date(Date.UTC(year, month - 1, date)).getUTCDate() !== date) return null;
        const zone = full[7];
        if (!zone) return localToUtc(year, month, date, hour, minute, second, timeZone);
        const offset = /^([+-])(\d{2}):?(\d{2})$/.exec(zone);
        const offsetMinutes = offset ? (offset[1] === "-" ? -1 : 1) * (Number(offset[2]) * 60 + Number(offset[3])) : 0;
        return new Date(Date.UTC(year, month - 1, date, hour, minute, second) - offsetMinutes * 60_000);
    }
    const m = CLOCK.exec(t);
    if (!m) return null;
    let hour = Number(m[1]);
    const minute = Number(m[2]);
    const second = Number(m[3] ?? 0);
    if (m[4]) hour = (hour % 12) + (m[4].toLowerCase() === "pm" ? 12 : 0);
    if (hour > 23 || minute > 59 || second > 59) return null;
    if (m[5]) {
        const d = newest ?? day;
        return latestUpTo((days) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + days, hour, minute, second)), newest);
    }
    return latestUpTo((days) => localToUtc(day.getUTCFullYear(), day.getUTCMonth() + 1, day.getUTCDate() + days, hour, minute, second, timeZone), newest);
}

/** "12:14 EST (17:14 UTC)": how answers state a time. */
export function bothTimes(at: Date, timeZone: string): string {
    const local = new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZoneName: "short" }).format(at);
    return `${local} (${at.toISOString().slice(11, 16)} UTC)`;
}

export function windowAround(at: Date, minutesBefore = 5, minutesAfter = 5): { from: Date; to: Date } {
    return { from: new Date(at.getTime() - minutesBefore * 60000), to: new Date(at.getTime() + minutesAfter * 60000) };
}
