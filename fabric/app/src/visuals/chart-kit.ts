// The chart kit's pure part: it turns a ChartSpec's rows into series, picks the axes, and formats values. ChartView
// draws what this returns; the app's own visuals and Copilot's show_chart go through the same code.

import { extent } from "d3-array";

import { MAX_CHART_ROWS, type ChartSpec, type ContextRow } from "@/copilot/contract";
import { formatDateTimeUtc, formatDayUtc, formatTimeUtc, toDate } from "@/lib/format";

export type XKind = "time" | "number" | "category" | "index";

export interface ChartPoint {
    /** Epoch milliseconds for time, the number for number, the category's text, or the row's position. */
    x: number | string;
    y: number | null;
    row: ContextRow;
}

export interface ChartSeries {
    key: string;
    label: string;
    points: ChartPoint[];
}

export interface ChartModel {
    xKind: XKind;
    xField: string | null;
    /** The x values in order: sorted times or numbers, or categories in the order they first appear. */
    xs: Array<number | string>;
    series: ChartSeries[];
    yFields: string[];
    unit?: string;
    rowCount: number;
    truncated: boolean;
}

const ISO_TIME = /^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$/;

/** Epoch milliseconds for a Date or an ISO 8601 text (zone-less text is UTC, as the model stores it); otherwise null. */
export function timeOf(value: unknown): number | null {
    if (value instanceof Date) return Number.isFinite(value.getTime()) ? value.getTime() : null;
    if (typeof value === "string" && ISO_TIME.test(value.trim())) {
        const text = value.trim();
        const date = /^\d{4}-\d{2}-\d{2}$/.test(text) ? toDate(`${text}T00:00:00`) : toDate(text.replace(" ", "T"));
        return date ? date.getTime() : null;
    }
    return null;
}

export function numberOf(value: unknown): number | null {
    if (typeof value === "number") return Number.isFinite(value) ? value : null;
    if (typeof value === "string" && value.trim() !== "" && /^-?\d+(\.\d+)?(e[+-]?\d+)?$/i.test(value.trim())) return Number(value);
    if (typeof value === "boolean") return value ? 1 : 0;
    return null;
}

/** What kind of x axis the field's values make: times, numbers, or categories. */
export function detectXKind(rows: readonly ContextRow[], field: string | undefined): XKind {
    if (!field) return "index";
    const values = rows.map((r) => r[field]).filter((v) => v !== null && v !== undefined && v !== "");
    if (values.length === 0) return "category";
    if (values.every((v) => timeOf(v) !== null)) return "time";
    if (values.every((v) => typeof v === "number" && Number.isFinite(v))) return "number";
    return "category";
}

/** The measure fields: the spec's y, or every numeric field of the rows except x and series. */
export function yFieldsOf(spec: ChartSpec): string[] {
    if (Array.isArray(spec.y)) return spec.y;
    if (typeof spec.y === "string") return [spec.y];
    const skip = new Set([spec.x, spec.series].filter((f): f is string => typeof f === "string"));
    const fields: string[] = [];
    for (const row of spec.rows.slice(0, 50)) {
        for (const [key, value] of Object.entries(row)) {
            if (!skip.has(key) && !fields.includes(key) && typeof value === "number") fields.push(key);
        }
    }
    return fields;
}

function xOf(row: ContextRow, index: number, kind: XKind, field: string | null): number | string | null {
    if (kind === "index" || !field) return index;
    const value = row[field];
    if (kind === "time") return timeOf(value);
    if (kind === "number") return numberOf(value);
    return value === null || value === undefined ? null : String(value);
}

/** The spec as series over one x axis; rows past MAX_CHART_ROWS are left out and the model says so. */
export function buildChartModel(spec: ChartSpec, maxRows = MAX_CHART_ROWS): ChartModel {
    const rows = spec.rows.slice(0, maxRows);
    const xKind = detectXKind(rows, spec.x);
    const xField = spec.x ?? null;
    const yFields = yFieldsOf(spec);
    const series: ChartSeries[] = [];
    const seen = new Map<number | string, true>();

    const add = (target: ChartSeries, row: ContextRow, index: number, field: string) => {
        const x = xOf(row, index, xKind, xField);
        if (x === null) return;
        seen.set(x, true);
        target.points.push({ x, y: numberOf(row[field]), row });
    };

    if (spec.series && yFields.length > 0) {
        const field = yFields[0];
        const groups = new Map<string, ChartSeries>();
        rows.forEach((row, index) => {
            const raw = row[spec.series as string];
            const key = raw === null || raw === undefined || raw === "" ? "(blank)" : String(raw);
            let group = groups.get(key);
            if (!group) {
                group = { key, label: key, points: [] };
                groups.set(key, group);
            }
            add(group, row, index, field);
        });
        series.push(...groups.values());
    } else {
        for (const field of yFields) {
            const one: ChartSeries = { key: field, label: field, points: [] };
            rows.forEach((row, index) => add(one, row, index, field));
            series.push(one);
        }
    }

    let xs = [...seen.keys()];
    if (xKind === "time" || xKind === "number" || xKind === "index") {
        xs = (xs as number[]).sort((a, b) => a - b);
        for (const s of series) s.points.sort((a, b) => (a.x as number) - (b.x as number));
    }
    return { xKind, xField, xs, series, yFields, unit: spec.unit, rowCount: spec.rows.length, truncated: spec.rows.length > rows.length };
}

const integer = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const oneDecimal = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
const twoDecimals = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });
const compact = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });

function plain(value: number): string {
    const abs = Math.abs(value);
    if (abs >= 10000) return compact.format(value);
    if (abs >= 100) return integer.format(value);
    if (abs >= 1) return oneDecimal.format(value);
    return twoDecimals.format(value);
}

/** A value with its unit, as the app writes numbers: "97.5 %", "241 s", "1.2K", "3.4 MB". */
export function formatValue(value: number | null | undefined, unit?: string): string {
    if (value === null || value === undefined || !Number.isFinite(value)) return "–";
    const text = plain(value);
    switch ((unit ?? "").trim()) {
        case "":
        case "count":
            return text;
        case "%":
            return `${text} %`;
        default:
            return `${text} ${unit!.trim()}`;
    }
}

/** An axis tick: compact numbers, the unit only on percentages. */
export function formatTick(value: number, unit?: string): string {
    const text = Math.abs(value) >= 1000 ? compact.format(value) : plain(value);
    return unit?.trim() === "%" ? `${text}%` : text;
}

/** An x value as the axis or the tooltip shows it. Times are UTC: the time of day over short spans, the day over long ones. */
export function formatX(x: number | string, kind: XKind, spanMs = 0, long = false): string {
    if (kind === "time" && typeof x === "number") {
        const date = new Date(x);
        if (long) return formatDateTimeUtc(date);
        return spanMs <= 2 * 86400000 ? formatTimeUtc(date) : formatDayUtc(date);
    }
    if (kind === "number" && typeof x === "number") return plain(x);
    if (kind === "index" && typeof x === "number") return `#${x + 1}`;
    return String(x);
}

/** The y extent of the visible series; stacked adds the series at each x. Percentages stay within 0 to 100 when they fit. */
export function yDomain(model: ChartModel, visible: readonly ChartSeries[], stacked: boolean): [number, number] {
    let lo = 0;
    let hi = 0;
    if (stacked) {
        const totals = new Map<number | string, { pos: number; neg: number }>();
        for (const s of visible) {
            for (const p of s.points) {
                if (p.y === null) continue;
                const t = totals.get(p.x) ?? { pos: 0, neg: 0 };
                if (p.y >= 0) t.pos += p.y;
                else t.neg += p.y;
                totals.set(p.x, t);
            }
        }
        for (const t of totals.values()) {
            hi = Math.max(hi, t.pos);
            lo = Math.min(lo, t.neg);
        }
    } else {
        const values = visible.flatMap((s) => s.points.map((p) => p.y)).filter((v): v is number => v !== null);
        const [min, max] = extent(values);
        lo = Math.min(0, min ?? 0);
        hi = Math.max(0, max ?? 0);
    }
    if (model.unit?.trim() === "%" && lo >= 0 && hi <= 100 && hi > 0) return [0, 100];
    if (hi === lo) return [lo, lo + 1];
    return [lo, hi + (hi - lo) * 0.06];
}

/** The index in sorted numbers closest to the target. */
export function nearestIndex(sorted: readonly number[], target: number): number {
    if (sorted.length === 0) return -1;
    let lo = 0;
    let hi = sorted.length - 1;
    while (hi - lo > 1) {
        const mid = (lo + hi) >> 1;
        if (sorted[mid] <= target) lo = mid;
        else hi = mid;
    }
    return Math.abs(sorted[lo] - target) <= Math.abs(sorted[hi] - target) ? lo : hi;
}

/** One sentence per series for screen readers: its range and its last value. */
export function describeModel(model: ChartModel, title: string): string {
    if (model.series.length === 0 || model.xs.length === 0) return `${title}: no data.`;
    const parts = model.series.map((s) => {
        const values = s.points.map((p) => p.y).filter((v): v is number => v !== null);
        if (values.length === 0) return `${s.label}: no values`;
        const [min, max] = extent(values) as [number, number];
        return `${s.label}: from ${formatValue(min, model.unit)} to ${formatValue(max, model.unit)}, last ${formatValue(values[values.length - 1], model.unit)}`;
    });
    const span = model.xKind === "time" ? ` from ${formatX(model.xs[0], "time", 0, true)} to ${formatX(model.xs[model.xs.length - 1], "time", 0, true)}` : "";
    return `${title}${span}. ${parts.join("; ")}.`;
}

/** Fixed colors for the estate's targets, so a target looks the same in every chart, Copilot's included. */
export const TARGET_COLORS: Record<string, string> = {
    T1: "var(--target-t1)",
    T2: "var(--target-t2)",
    T3: "var(--target-t3)",
    T4: "var(--target-t4)",
    "T4-replica": "var(--target-t4r)",
    T5: "var(--target-t5)",
};

export function seriesColor(key: string, index: number, colors?: Record<string, string>): string {
    return colors?.[key] ?? TARGET_COLORS[key] ?? `var(--chart-${(index % 8) + 1})`;
}
