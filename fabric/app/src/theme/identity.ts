// The Insights app's own identity (ADR 0030): Microsoft's colors, as the owner chose on 2026-11-20: Fluent 2's Microsoft
// blue is the brand ramp (buttons, links, focus), and the Microsoft logo's four colors are the accents, tuned for contrast
// and used sparingly: each target's mark (the service map, its chip, its chart series) and the charts' first categories,
// never a large fill. Swap the look here and in stage.ts, which holds the surfaces Mission Control, the scoreboard, the
// replay, and the kiosk draw on.

import type { BrandVariants } from "@fluentui/react-components";

/** Fluent 2's web brand ramp, Microsoft blue (#0F6CBD at 80): the ramp Fluent's own web themes are made from. */
export const MICROSOFT_BRAND: BrandVariants = {
    10: "#061724",
    20: "#082338",
    30: "#0A2E4A",
    40: "#0C3B5E",
    50: "#0E4775",
    60: "#0F548C",
    70: "#115EA3",
    80: "#0F6CBD",
    90: "#2886DE",
    100: "#479EF5",
    110: "#62ABF5",
    120: "#77B7F7",
    130: "#96C6FA",
    140: "#B4D6FA",
    150: "#CFE4FA",
    160: "#EBF3FC",
};

/** The ramp the app's Fluent themes use. Fabric's teal (FABRIC_BRAND in fluent.ts) is the one-line swap back. */
export const APP_BRAND: BrandVariants = MICROSOFT_BRAND;

/** The Microsoft logo's four colors. */
export const MICROSOFT_LOGO = { red: "#F25022", green: "#7FBA00", blue: "#00A4EF", yellow: "#FFB900" } as const;

/** The accents of one theme: the logo's four hues, then Fluent's purple, teal, and gray for the categories past them. */
export interface Accents {
    blue: string;
    green: string;
    yellow: string;
    red: string;
    purple: string;
    teal: string;
    gray: string;
}

/**
 * The accents in dark and light. On dark surfaces, the logo's own colors, each 3:1 or more (WCAG 1.4.11); on light ones,
 * the same hues deepened until they reach it: Microsoft's blue (#0078D4) and green (#107C10), a deeper gold, and a deeper
 * orange-red. High contrast keeps its own palette (APP_TOKENS in fluent.ts).
 */
export const MICROSOFT_ACCENTS: { dark: Accents; light: Accents } = {
    dark: { ...MICROSOFT_LOGO, purple: "#B696E1", teal: "#4BC5C7", gray: "#ADADAD" },
    light: { blue: "#0078D4", green: "#107C10", yellow: "#A87A00", red: "#D83B01", purple: "#8764B8", teal: "#038387", gray: "#616161" },
};