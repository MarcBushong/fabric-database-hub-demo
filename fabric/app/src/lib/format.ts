// Formatting for numbers, UTC times, and durations. Every time the app shows is UTC, like the model.

const integer = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const oneDecimal = new Intl.NumberFormat("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const compact = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });

export type NumberKind = "int" | "decimal" | "percent" | "seconds" | "minutes" | "mb" | "compact";

export function isNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value);
}

export function formatNumber(value: unknown, kind: NumberKind = "decimal"): string {
    if (!isNumber(value)) return "–";
    switch (kind) {
        case "int":
            return integer.format(value);
        case "percent":
            return `${oneDecimal.format(value)} %`;
        case "seconds":
            return `${value >= 100 ? integer.format(value) : oneDecimal.format(value)} s`;
        case "minutes":
            return `${value >= 100 ? integer.format(value) : oneDecimal.format(value)} min`;
        case "mb":
            return `${value >= 100 ? integer.format(value) : oneDecimal.format(value)} MB`;
        case "compact":
            return compact.format(value);
        default:
            return Math.abs(value) >= 100 ? integer.format(value) : oneDecimal.format(value);
    }
}

/** Parses the connector's DateTime values: ISO text without a zone (a UTC instant), epoch numbers, or Dates. */
export function toDate(value: unknown): Date | null {
    if (value instanceof Date) return Number.isFinite(value.getTime()) ? value : null;
    if (typeof value === "number" && Number.isFinite(value)) return new Date(value);
    if (typeof value === "string" && value.trim()) {
        const text = value.trim();
        const iso = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/.test(text) ? `${text}Z` : text;
        const parsed = new Date(iso);
        return Number.isFinite(parsed.getTime()) ? parsed : null;
    }
    return null;
}

const pad = (n: number) => String(n).padStart(2, "0");
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** 14:05 */
export function formatTimeUtc(date: Date | null): string {
    return date ? `${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}` : "–";
}

/** 21 Oct */
export function formatDayUtc(date: Date | null): string {
    return date ? `${date.getUTCDate()} ${MONTHS[date.getUTCMonth()]}` : "–";
}

/** 21 Oct 14:05 UTC */
export function formatDateTimeUtc(date: Date | null): string {
    return date ? `${formatDayUtc(date)} ${formatTimeUtc(date)} UTC` : "–";
}

/** 2026-10-21 */
export function formatIsoDay(date: Date | null): string {
    return date ? `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}` : "";
}

/** 45 min, 7 h, 3 h 30 min, 2 d 4 h */
export function formatDuration(minutes: unknown): string {
    if (!isNumber(minutes) || minutes < 0) return "–";
    const m = Math.round(minutes);
    if (m < 60) return `${m} min`;
    const hours = Math.floor(m / 60);
    const rest = m % 60;
    if (hours < 48) return rest ? `${hours} h ${rest} min` : `${hours} h`;
    const days = Math.floor(hours / 24);
    const h = hours % 24;
    return h ? `${days} d ${h} h` : `${days} d`;
}

/** "18 h ago" relative to now. */
export function formatAgo(date: Date | null, now: Date = new Date()): string {
    if (!date) return "never";
    const minutes = (now.getTime() - date.getTime()) / 60000;
    if (minutes < 1) return "just now";
    return `${formatDuration(minutes)} ago`;
}

/** A table cell as the visual's data table shows it, by the column's kind. */
export function formatCell(column: { kind: string }, value: unknown): string {
    if (value === null || value === undefined || value === "") return "–";
    switch (column.kind) {
        case "int":
        case "decimal":
        case "percent":
        case "seconds":
        case "minutes":
        case "mb":
            return formatNumber(value, column.kind);
        case "datetime":
            return formatDateTimeUtc(toDate(value));
        default:
            return String(value);
    }
}
