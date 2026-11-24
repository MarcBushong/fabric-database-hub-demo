// The contract between the Insights app (its shell, pages, and visuals) and the GitHub Copilot chat that docks in it.
// The app owns the shell, the entry points ("Ask Copilot", "Ask why"), and ChartView; the chat owns src/copilot/**
// and implements CopilotApi. Both sides build on these types only. Add optional fields; never repurpose one.

/** One row of data as a visual shows it: field names to plain values. Times are ISO 8601 UTC strings ("2026-11-17T14:05:00Z"). */
export type ContextRow = Record<string, unknown>;

/** A column of the rows: its field, its label, and how to read its values. */
export interface ContextColumn {
    key: string;
    label: string;
    /** text, int, decimal, percent, seconds, minutes, mb, datetime, status, or url (the app's column kinds). */
    kind?: string;
    /** The unit of a number, when the label doesn't say it: "%", "s", "min", "MB", "count". */
    unit?: string;
}

/**
 * Where data comes from. "history" is the lakehouse history through SM_DatabaseHub_History (snapshots, not live);
 * "live" is a live source, such as Database Hub's estate; "sample" is the local preview's made-up data.
 */
export type DataProvenance = "history" | "live" | "sample";

/** What makes a value an anomaly, for "Ask why". */
export interface AnomalyContext {
    /** What moved, in words: "CPU", "Buffer IO waits", "Read replica lag". */
    metric: string;
    target?: string;
    /** When it peaked or started (ISO 8601 UTC). */
    at?: string;
    value?: number;
    /** The value before it, for comparison. */
    baseline?: number;
    unit?: string;
}

/**
 * What a visual, a table, or an anomaly hands to Copilot. The first six fields are the core; the rest are optional
 * extras that the app fills in when it has them.
 */
export interface AskContext {
    /** The question. Without one, the chat asks a default question about the title and the rows. */
    prompt?: string;
    /** The visual's or table's title, as the page shows it. */
    title?: string;
    /** The page the ask came from: overview, estate, performance, incidents, findings, readiness, trends, manage, or links. */
    page?: string;
    /** A stable ID of the visual ("estate.targets", "incidents.replay"); the same visual always sends the same ID. */
    visualId?: string;
    /** The DAX behind the rows. Several queries are joined with a blank line, each after a "// <title>" comment line. */
    dax?: string;
    /** The rows the visual shows, at most MAX_CONTEXT_ROWS (the app trims them, and says so in `truncated`). */
    rows?: ContextRow[];

    columns?: ContextColumn[];
    /** How many rows the visual had before the app trimmed them to MAX_CONTEXT_ROWS. */
    totalRows?: number;
    truncated?: boolean;
    source?: DataProvenance;
    /** The newest data's time (ISO 8601 UTC): the newest history snapshot, or the live read. */
    asOf?: string;
    /** The page's global filter when the ask was made. */
    filters?: { targets?: string[]; period?: string; from?: string; to?: string };
    /** Set by "Ask why". */
    anomaly?: AnomalyContext;
}

/** What entry points call. `useCopilot()` returns it anywhere inside the app. */
export interface CopilotApi {
    /** Opens the dock. With a context, attaches it to the next question without sending anything. */
    open(ctx?: AskContext): void;
    /** Opens the dock and asks: sends `ctx.prompt` (or a default question about `ctx.title`) with the context attached. */
    ask(ctx: AskContext): void;
}

/** Docked beside the page, or over the whole app. */
export type DockMode = "docked" | "fullscreen";

/** What the shell reads to place the dock. The provider owns whether it's open; the shell owns its mode and width. */
export interface CopilotDockState {
    isOpen: boolean;
    setOpen(open: boolean): void;
}

/**
 * The GitHub account the chat signed in with, separate from the Fabric account. The shell shows it as a chip next to
 * the Fabric account; selecting the chip calls signIn() when signed out (the chat runs its own sign-in in the dock).
 */
export interface CopilotAccountState {
    /** "unavailable": the chat isn't connected in this build or deployment; the chip says so and offers nothing. */
    status: "signed-out" | "signing-in" | "signed-in" | "unavailable";
    /** The GitHub login, when signed in. */
    login?: string;
    /** The Copilot plan as GitHub names it ("Copilot Business", "Copilot Enterprise"), when known. */
    plan?: string;
    /** An https avatar URL from GitHub, when known. */
    avatarUrl?: string;
    /** A short reason for "unavailable" or a failed sign-in, for the chip's tooltip. */
    detail?: string;
    signIn(): void;
    signOut(): void;
}

/** The shell renders <CopilotDock {...props} /> in its right-hand region; the dock renders the whole panel, header included. */
export interface CopilotDockProps {
    mode: DockMode;
    onModeChange(mode: DockMode): void;
    onClose(): void;
    /** The ID the panel's heading must carry: the shell labels its region with it. */
    headingId: string;
}

export const CHART_KINDS = ["line", "area", "bar", "stackedBar", "scatter", "table", "kpi"] as const;
export type ChartKind = (typeof CHART_KINDS)[number];

/**
 * A chart in the app's own chart language: Copilot's show_chart tool returns one, and ChartView
 * (src/visuals/ChartView.tsx) draws it like the app's own visuals.
 *
 * - Wide rows: `y` lists the measure fields, one series each.
 * - Long rows: `series` names the field that splits the rows into series, and `y` is the one measure.
 * - `x` holds times (ISO strings), numbers, or categories; without `x`, rows are numbered.
 * - `kpi` shows each `y` of the first row as a tile (or, with `x`, one tile per row, labeled by `x`).
 * - `table` shows the `y` fields (or every field) as a sortable table.
 */
export interface ChartSpec {
    kind: ChartKind;
    title: string;
    subtitle?: string;
    rows: ContextRow[];
    x?: string;
    y?: string | string[];
    series?: string;
    /** The measure's unit: "%", "s", "ms", "min", "MB", "GB", "count", or a word. */
    unit?: string;
}

/** The most rows an AskContext carries. */
export const MAX_CONTEXT_ROWS = 200;
/** The most rows ChartView draws; validateChartSpec rejects more. */
export const MAX_CHART_ROWS = 5000;

const FIELD = /^[^\n\r]{1,128}$/;

function isField(value: unknown): value is string {
    return typeof value === "string" && FIELD.test(value);
}

/** Checks untrusted input (a model's tool call) and returns a ChartSpec, or the reason it isn't one. */
export function validateChartSpec(input: unknown): { ok: true; spec: ChartSpec } | { ok: false; error: string } {
    if (!input || typeof input !== "object" || Array.isArray(input)) return { ok: false, error: "A chart spec is an object." };
    const value = input as Record<string, unknown>;
    if (!CHART_KINDS.includes(value.kind as ChartKind)) return { ok: false, error: `kind must be one of ${CHART_KINDS.join(", ")}.` };
    if (typeof value.title !== "string" || !value.title.trim()) return { ok: false, error: "title is required." };
    if (value.subtitle !== undefined && typeof value.subtitle !== "string") return { ok: false, error: "subtitle must be text." };
    if (!Array.isArray(value.rows)) return { ok: false, error: "rows must be an array of objects." };
    if (value.rows.length > MAX_CHART_ROWS) return { ok: false, error: `rows can hold at most ${MAX_CHART_ROWS} rows.` };
    if (value.rows.some((r) => !r || typeof r !== "object" || Array.isArray(r))) return { ok: false, error: "Each row must be an object." };
    if (value.x !== undefined && !isField(value.x)) return { ok: false, error: "x must be a field name." };
    const y = value.y;
    if (y !== undefined && !isField(y) && !(Array.isArray(y) && y.length > 0 && y.length <= 12 && y.every(isField))) {
        return { ok: false, error: "y must be a field name or a list of 1 to 12 field names." };
    }
    if (value.series !== undefined && !isField(value.series)) return { ok: false, error: "series must be a field name." };
    if (value.series !== undefined && Array.isArray(y) && y.length > 1) return { ok: false, error: "With series, y is one field." };
    if (value.unit !== undefined && (typeof value.unit !== "string" || value.unit.length > 24)) return { ok: false, error: "unit must be short text." };
    return {
        ok: true,
        spec: {
            kind: value.kind as ChartKind,
            title: value.title.trim(),
            subtitle: typeof value.subtitle === "string" ? value.subtitle : undefined,
            rows: value.rows as ContextRow[],
            x: value.x as string | undefined,
            y: y as string | string[] | undefined,
            series: value.series as string | undefined,
            unit: value.unit as string | undefined,
        },
    };
}
