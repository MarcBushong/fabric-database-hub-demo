// DAX text builders for the history model. Only allow-listed values and validated dates reach a query:
// the app never interpolates free text into DAX.

export type TargetKey = "T1" | "T2" | "T3";

export const SQL_TARGETS: readonly TargetKey[] = ["T1", "T2", "T3"];

export function isTargetKey(value: unknown): value is TargetKey {
    return value === "T1" || value === "T2" || value === "T3";
}

/** A DAX string literal: quotes are doubled. */
export function daxString(value: string): string {
    return `"${value.replace(/"/g, '""')}"`;
}

function assertDate(value: Date, what: string): void {
    if (!(value instanceof Date) || !Number.isFinite(value.getTime())) {
        throw new Error(`${what} isn't a valid date.`);
    }
}

/** DATE ( y, m, d ) for the UTC calendar day of the instant. */
export function daxDate(value: Date): string {
    assertDate(value, "The date");
    return `DATE ( ${value.getUTCFullYear()}, ${value.getUTCMonth() + 1}, ${value.getUTCDate()} )`;
}

/** DATE ( y, m, d ) + TIME ( h, m, s ) for the UTC instant; the model stores UTC instants without a zone. */
export function daxDateTime(value: Date): string {
    assertDate(value, "The time");
    return `${daxDate(value)} + TIME ( ${value.getUTCHours()}, ${value.getUTCMinutes()}, ${value.getUTCSeconds()} )`;
}

/** TREATAS over the selected SQL targets; also keeps platform scopes (fabric, tenant, ...) out of target visuals. */
export function targetFilter(targets: readonly TargetKey[]): string {
    const keys = SQL_TARGETS.filter((t) => targets.includes(t));
    const list = (keys.length > 0 ? keys : SQL_TARGETS).map(daxString).join(", ");
    return `TREATAS ( { ${list} }, 'Target'[Target Key] )`;
}

/** Inclusive UTC date window on the model's Date table; null means all history. */
export interface DateWindow {
    from: Date;
    to: Date;
}

export function dateFilter(window: DateWindow | null): string | null {
    if (!window) return null;
    return `DATESBETWEEN ( 'Date'[Date], ${daxDate(window.from)}, ${daxDate(window.to)} )`;
}

/** Bins whose start lies in [start, end] (or [start, end) with exclusiveEnd). */
export function bucketRange(start: Date, end: Date, exclusiveEnd = false): string {
    const op = exclusiveEnd ? "<" : "<=";
    return (
        "FILTER ( ALL ( 'Telemetry Snapshots'[Bucket UTC] ), " +
        `'Telemetry Snapshots'[Bucket UTC] >= ${daxDateTime(start)} && 'Telemetry Snapshots'[Bucket UTC] ${op} ${daxDateTime(end)} )`
    );
}

/** Joins SUMMARIZECOLUMNS or CALCULATETABLE arguments, skipping empty ones. */
export function args(parts: ReadonlyArray<string | null | false | undefined>, indent = "    "): string {
    return parts.filter((p): p is string => typeof p === "string" && p.length > 0).join(`,\n${indent}`);
}

const DAX_KEYWORDS =
    /^(EVALUATE|DEFINE|VAR|RETURN|ORDER|BY|ASC|DESC|IN|ROW|SUMMARIZE|SUMMARIZECOLUMNS|SELECTCOLUMNS|ADDCOLUMNS|CALCULATETABLE|CALCULATE|FILTER|ALL|ALLEXCEPT|VALUES|TREATAS|DATESBETWEEN|TOPN|RELATED|REMOVEFILTERS|KEEPFILTERS|COUNTROWS|DISTINCTCOUNT|MAX|MAXX|MIN|DATE|TIME)$/;

export interface DaxToken {
    kind: "k" | "s" | "t" | "m" | "p";
    text: string;
}

/** Splits DAX into keywords, strings, 'Table'[Column] references, and [Measure] references for highlighting. */
export function tokenizeDax(dax: string): DaxToken[] {
    const tokens: DaxToken[] = [];
    const pattern = /("(?:[^"]|"")*")|('(?:[^']|'')*'\[[^\]]*\])|(\[[^\]]*\])|([A-Za-z_][A-Za-z0-9_]*)|([\s\S])/g;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(dax)) !== null) {
        if (match[1]) tokens.push({ kind: "s", text: match[1] });
        else if (match[2]) tokens.push({ kind: "t", text: match[2] });
        else if (match[3]) tokens.push({ kind: "m", text: match[3] });
        else if (match[4]) tokens.push({ kind: DAX_KEYWORDS.test(match[4]) ? "k" : "p", text: match[4] });
        else tokens.push({ kind: "p", text: match[5] });
    }
    return tokens;
}
