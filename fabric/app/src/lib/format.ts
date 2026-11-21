// Formatting for numbers, UTC times, and durations. Every time the app shows is UTC, like the model.

const integer = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const oneDecimal = new Intl.NumberFormat("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const compact = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });

export type NumberKind = "int" | "decimal" | "percent" | "seconds" | "minutes" | "mb" | "ms" | "compact";

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
        case "ms":
            return `${value >= 100 ? integer.format(value) : oneDecimal.format(value)} ms`;
        case "compact":
            return compact.format(value);
        default:
            return Math.abs(value) >= 100 ? integer.format(value) : oneDecimal.format(value);
    }
}

/** The unit formatNumber writes after each kind's number. */
const UNIT: Partial<Record<NumberKind, string>> = { percent: " %", seconds: " s", minutes: " min", mb: " MB", ms: " ms" };

/** A value with exactly `digits` decimals and its kind's unit: to tell apart two values that formatNumber writes alike. */
export function formatNumberDigits(value: number, kind: NumberKind, digits: number): string {
    return `${new Intl.NumberFormat("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value)}${UNIT[kind] ?? ""}`;
}

/**
 * A level, a baseline, or a peak beside them, as text that reads true: a whole number as formatNumber writes it, any other
 * with its decimals (two, more under 0.1 for two significant digits, at most 4; trailing zeros dropped), whatever its
 * kind: "at least 0.45 (1.5 times its baseline of 0.3)", never "at least 0". A percentage under 100 is never written as
 * 100: a peak of 99.996 % gets more decimals, or reads "just under 100 %".
 */
export function formatLevel(value: unknown, kind: NumberKind): string {
    if (!isNumber(value)) return "–";
    if (Number.isInteger(value)) return formatNumber(value, kind);
    let digits = Math.min(4, Math.max(2, 1 - Math.floor(Math.log10(Math.abs(value)))));
    const withDigits = () => `${new Intl.NumberFormat("en-US", { minimumFractionDigits: 1, maximumFractionDigits: digits }).format(value)}${UNIT[kind] ?? ""}`;
    let text = withDigits();
    if (kind === "percent" && value < 100) {
        const hundred = formatNumber(100, kind);
        while (text === hundred && digits < 4) {
            digits++;
            text = withDigits();
        }
        if (text === hundred) return "just under 100 %";
    }
    return text;
}

/** The decimals formatNumber writes a value of a kind with (compact has none of its own: -1). */
function numberDigits(value: number, kind: NumberKind): number {
    switch (kind) {
        case "int":
            return 0;
        case "percent":
            return 1;
        case "compact":
            return -1;
        case "seconds":
        case "minutes":
        case "mb":
        case "ms":
            return value >= 100 ? 0 : 1;
        default:
            return Math.abs(value) >= 100 ? 0 : 1;
    }
}

/**
 * A value beside the status line it's judged by (a Warning at 80 % CPU or more, at 60 s of replica lag or more, under 99.99 %
 * availability), as formatNumber writes it, with more decimals, 4 at most, only while that text would put it on the line's
 * other side: 79.996 against 80 reads "79.996 %", never "80.0 %" beside a Pass, and 99.989 against 99.99 reads "99.989 %",
 * never "99.99 %" beside a Warning; a value at or over the line never reads under it. A percentage under 100 never reads
 * 100 either, as with formatLevel. Past 4 decimals, "just under 80 %".
 */
export function formatBeside(value: unknown, kind: NumberKind, line: number): string {
    if (!isNumber(value) || !Number.isFinite(line)) return formatNumber(value, kind);
    const start = numberDigits(value, kind);
    if (start < 0) return formatNumber(value, kind);
    const lines = kind === "percent" && line !== 100 ? [line, 100] : [line];
    const sideOf = (digits: number) => {
        const shown = Number(new Intl.NumberFormat("en-US", { maximumFractionDigits: digits, useGrouping: false }).format(value));
        return lines.find((l) => (value < l ? shown >= l : shown < l));
    };
    if (sideOf(start) === undefined) return formatNumber(value, kind);
    for (let digits = start + 1; digits <= 4; digits++) {
        if (sideOf(digits) === undefined) return formatNumberDigits(value, kind, digits);
    }
    const crossed = sideOf(4) as number;
    const lineText = `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 }).format(crossed)}${UNIT[kind] ?? ""}`;
    return value < crossed ? `just under ${lineText}` : `at least ${lineText}`;
}

/**
 * A share (0 to 1) in percent, whole or with `digits` decimals, that never rounds some to none, or nearly all to all:
 * "less than 1 %" ("less than 0.1 %" with one decimal), "more than 99 %" ("more than 99.9 %").
 */
export function percent(share: number, digits = 0): string {
    const p = share * 100;
    const fixed = new Intl.NumberFormat("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
    const text = fixed.format(p);
    if (p > 0 && text === fixed.format(0)) return `less than ${fixed.format(10 ** -digits)} %`;
    if (p < 100 && text === fixed.format(100)) return `more than ${fixed.format(100 - 10 ** -digits)} %`;
    return `${text} %`;
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

/** "26 h ago", "3 d ago": the age in its largest whole unit, for tiles. */
export function formatAgoShort(date: Date | null, now: Date = new Date()): string {
    if (!date) return "never";
    const minutes = (now.getTime() - date.getTime()) / 60000;
    if (minutes < 1) return "just now";
    if (minutes < 60) return `${Math.floor(minutes)} min ago`;
    if (minutes < 48 * 60) return `${Math.floor(minutes / 60)} h ago`;
    return `${Math.floor(minutes / 1440)} d ago`;
}

/** A message as a clause inside a sentence: one line, trimmed, without its closing periods. */
export function clause(text: string): string {
    return text.replace(/\s+/g, " ").trim().replace(/\.+$/, "");
}

/** A message as one sentence: capitalized, ending with exactly one period (or its own ? ! …). */
export function sentence(text: string): string {
    const body = clause(text);
    if (!body) return "";
    const capitalized = body.charAt(0).toUpperCase() + body.slice(1);
    return /[!?\u2026]$/.test(capitalized) ? capitalized : `${capitalized}.`;
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
