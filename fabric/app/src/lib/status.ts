// The six ADR 0012 statuses. Color is never the only signal: each status has a glyph, a shape, and a word.

export type StatusName = "Fail" | "Manual action required" | "Warning" | "Pass" | "Not supported" | "Not selected";

export interface StatusMeta {
    name: StatusName;
    short: string;
    glyph: string;
    shape: "octagon" | "flag" | "triangle" | "circle" | "slash" | "ring";
    /** CSS custom property that holds the theme's color for this status. */
    token: string;
    sort: number;
    needsAttention: boolean;
    meaning: string;
}

export const STATUSES: readonly StatusMeta[] = [
    { name: "Fail", short: "Fail", glyph: "✕", shape: "octagon", token: "--status-fail", sort: 1, needsAttention: true, meaning: "A selected capability is broken, or a prerequisite is missing" },
    { name: "Manual action required", short: "Manual", glyph: "⚑", shape: "flag", token: "--status-manual", sort: 2, needsAttention: true, meaning: "A documented manual step is pending" },
    { name: "Warning", short: "Warning", glyph: "▲", shape: "triangle", token: "--status-warning", sort: 3, needsAttention: true, meaning: "It works, but with a risk to address" },
    { name: "Pass", short: "Pass", glyph: "✓", shape: "circle", token: "--status-pass", sort: 4, needsAttention: false, meaning: "Functionally verified" },
    { name: "Not supported", short: "Not supported", glyph: "⊘", shape: "slash", token: "--status-muted", sort: 5, needsAttention: false, meaning: "The docs say the capability doesn't apply" },
    { name: "Not selected", short: "Not selected", glyph: "○", shape: "ring", token: "--status-muted", sort: 6, needsAttention: false, meaning: "The operator turned the capability off" },
];

const BY_NAME = new Map(STATUSES.map((s) => [s.name.toLowerCase(), s]));
const BY_SORT = new Map(STATUSES.map((s) => [s.sort, s]));

export function statusMeta(name: unknown): StatusMeta {
    const found = typeof name === "string" ? BY_NAME.get(name.trim().toLowerCase()) : undefined;
    return found ?? STATUSES[5];
}

export function statusBySort(sort: unknown): StatusMeta | null {
    return typeof sort === "number" ? BY_SORT.get(sort) ?? null : null;
}

/** The worst status of a list (Fail first), or null for an empty list. */
export function worstStatus(names: readonly unknown[]): StatusMeta | null {
    let worst: StatusMeta | null = null;
    for (const name of names) {
        const meta = statusMeta(name);
        if (!worst || meta.sort < worst.sort) worst = meta;
    }
    return worst;
}

const STATUS_CLASS: Record<string, string> = {
    "--status-fail": "status-fail",
    "--status-manual": "status-manual",
    "--status-warning": "status-warning",
    "--status-pass": "status-pass",
    "--status-muted": "status-muted",
};

/** The CSS class that colors a status badge. */
export function statusClass(meta: StatusMeta): string {
    return STATUS_CLASS[meta.token] ?? "status-muted";
}

/** The status's theme color as a CSS value, for SVG fills. */
export function statusColor(meta: StatusMeta): string {
    return `var(${STATUS_CLASS[meta.token] ? meta.token : "--status-muted"})`;
}
