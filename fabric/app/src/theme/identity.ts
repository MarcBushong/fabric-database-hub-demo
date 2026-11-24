// The Insights app's own identity (ADR 0030): earth tones on cream, as the owner chose on 2026-11-23 ("Instead of white do
// creams and do more earth tones", with softer contrast in both themes). A terracotta brand ramp (buttons, links, the
// current page); warm neutrals in place of Fluent's grays (ivory and cream in light, espresso in dark, and text in a soft
// espresso or cream rather than black or white); and earth-toned accents for each target's mark (the service map, its chip,
// its chart series) and the charts' categories, never a large fill. Swap the look here and in stage.ts, which holds the
// stage's accent and alert for Mission Control, the scoreboard, the replay, the kiosk, and Root cause.

import type { BrandVariants } from "@fluentui/react-components";

/** Terracotta (#99512D at 80): the light theme's buttons at 80 and links at 70, the dark theme's buttons at 70 and links at 120. */
export const TERRACOTTA_BRAND: BrandVariants = {
    10: "#250F09",
    20: "#37170E",
    30: "#4A2013",
    40: "#5B2817",
    50: "#6C321B",
    60: "#7D3C21",
    70: "#8B4626",
    80: "#99512D",
    90: "#AD633B",
    100: "#C0784F",
    110: "#D08F68",
    120: "#DAA17D",
    130: "#E4B495",
    140: "#ECC9B1",
    150: "#F5DECD",
    160: "#FBF0E8",
};

/** Fluent 2's web brand ramp, Microsoft blue (#0F6CBD at 80): the app's brand from 2026-11-20 to 2026-11-23, kept for a one-line swap back. */
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

/** The ramp the app's Fluent themes use. Microsoft blue above, and Fabric's teal (FABRIC_BRAND in fluent.ts), are the one-line swaps back. */
export const APP_BRAND: BrandVariants = TERRACOTTA_BRAND;

/** A warm ramp: [Fluent's gray level, 0 black to 255 white, the color it becomes], in ascending order. */
export type WarmRamp = ReadonlyArray<readonly [number, string]>;

/**
 * What each of Fluent's grays becomes (fluent.ts, warmTheme), interpolated between these anchors. Light: white (the cards)
 * becomes ivory, the page's gray a sand cream, the strokes a soft taupe, and near-black text a soft espresso, at about
 * 11:1 instead of 16:1. Dark: the near-black surfaces become espresso, a step lighter, and white text a cream, at about
 * 12:1 instead of 15:1. Every text gray keeps 4.5:1 on the surfaces it sits on (src/lib/app.test.ts).
 */
export const WARM_NEUTRALS: { light: WarmRamp; dark: WarmRamp } = {
    light: [
        [0, "#221812"],
        [36, "#3E322A"],
        [66, "#594C42"],
        [87, "#66594F"],
        [97, "#6C5F54"],
        [112, "#73655A"],
        [189, "#C5B9AA"],
        [209, "#D7CCBC"],
        [224, "#E4DBCB"],
        [235, "#ECE3D4"],
        [240, "#EFE7D7"],
        [245, "#F2EADB"],
        [250, "#F7F1E5"],
        [255, "#FCF7EE"],
    ],
    dark: [
        [0, "#150F0C"],
        [10, "#1F1814"],
        [20, "#221B17"],
        [31, "#2A221D"],
        [41, "#322924"],
        [51, "#3B312B"],
        [61, "#433A33"],
        [82, "#584D45"],
        [92, "#62574D"],
        [102, "#6C6056"],
        [153, "#A89C8E"],
        [173, "#B7AB9B"],
        [214, "#D7CDBD"],
        [255, "#F0E9D9"],
    ],
};

/** Fluent's shadows in a warm brown instead of black; in light, a fifth lighter as well. */
export const WARM_SHADOW: { light: { rgb: string; alpha: number }; dark: { rgb: string; alpha: number } } = {
    light: { rgb: "62, 44, 30", alpha: 0.8 },
    dark: { rgb: "12, 7, 4", alpha: 1 },
};

/**
 * The accents of one theme: slate, moss, ochre, and clay mark T1 to T4 and the charts' first four categories; plum and
 * verdigris mark T5 and T4's read replica; stone and rose are the charts' last two. Each is 3:1 or more on every surface
 * (WCAG 1.4.11), and T1 to T5 with the replica stay apart under protanopia, deuteranopia, and tritanopia too.
 */
export interface Accents {
    slate: string;
    moss: string;
    ochre: string;
    clay: string;
    verdigris: string;
    plum: string;
    stone: string;
    rose: string;
}

export const EARTH_ACCENTS: { light: Accents; dark: Accents } = {
    light: { slate: "#496794", moss: "#3A5018", ochre: "#A67E1B", clay: "#9F533F", verdigris: "#3E8E93", plum: "#683C5A", stone: "#877B66", rose: "#9A626E" },
    dark: { slate: "#7BA9D8", moss: "#B3B884", ochre: "#F6CD6F", clay: "#CE7749", verdigris: "#85D4D4", plum: "#9D7695", stone: "#A1968B", rose: "#D59CA7" },
};

/**
 * The ADR 0012 statuses, earth-toned: brick for Fail, ochre for Warning, pine for Pass, and slate for Manual action
 * required, each with its icon and word (StatusBadge). Text, so 4.5:1 on each surface, at rest and in a hovered or
 * pressed row, button, or menu item; and apart from each other under every color-vision deficiency the tests simulate,
 * by lightness as well as hue.
 */
export interface StatusColors {
    fail: string;
    warning: string;
    pass: string;
    manual: string;
}

export const EARTH_STATUS: { light: StatusColors; dark: StatusColors } = {
    light: { fail: "#7F211B", warning: "#925303", pass: "#3C715D", manual: "#314770" },
    dark: { fail: "#EE8C8B", warning: "#F1C364", pass: "#A1D9C2", manual: "#80ABD8" },
};

/** One of Fluent's status families (message bars, badges, field states), as fluent.ts maps it onto Fluent's tokens. */
export interface StatusFamily {
    background1: string;
    background2: string;
    background3: string;
    foreground1: string;
    foreground2: string;
    foreground3: string;
    foregroundInverted: string;
    borderActive: string;
    border1: string;
    border2: string;
}

/** Fluent's danger, warning, and success families in the same earth tones as the statuses. */
export const EARTH_STATUS_FAMILIES: { light: Record<"danger" | "warning" | "success", StatusFamily>; dark: Record<"danger" | "warning" | "success", StatusFamily> } = {
    light: {
        danger: { background1: "#FEF1EF", background2: "#F9CEC6", background3: "#9A3326", foreground1: "#932C23", foreground2: "#6E221C", foreground3: "#9A3326", foregroundInverted: "#EA8883", borderActive: "#9A3326", border1: "#F3C0B7", border2: "#9A3326" },
        warning: { background1: "#FBF3E7", background2: "#ECD6B5", background3: "#9C640F", foreground1: "#8C5007", foreground2: "#6D3D0A", foreground3: "#A06108", foregroundInverted: "#EEC474", borderActive: "#A06108", border1: "#E4CAA2", border2: "#A06108" },
        success: { background1: "#EBF8F0", background2: "#BEE4CE", background3: "#336A54", foreground1: "#336A54", foreground2: "#1E4C3A", foreground3: "#336A54", foregroundInverted: "#9DD2BA", borderActive: "#336A54", border1: "#ACDAC0", border2: "#336A54" },
    },
    dark: {
        danger: { background1: "#402624", background2: "#5C332F", background3: "#A04038", foreground1: "#EE8C8B", foreground2: "#F2B6B5", foreground3: "#EE8C8B", foregroundInverted: "#A04038", borderActive: "#EE8C8B", border1: "#824844", border2: "#EE8C8B" },
        warning: { background1: "#3A2B16", background2: "#523B18", background3: "#E2B75C", foreground1: "#F1C364", foreground2: "#F6DFAC", foreground3: "#F1C364", foregroundInverted: "#895618", borderActive: "#F1C364", border1: "#755421", border2: "#F1C364" },
        success: { background1: "#193429", background2: "#1B4A38", background3: "#397059", foreground1: "#A1D9C2", foreground2: "#C7EBDA", foreground3: "#A1D9C2", foregroundInverted: "#397059", borderActive: "#A1D9C2", border1: "#25694F", border2: "#A1D9C2" },
    },
};

/** Fluent's filled warning badge puts dark text on its yellow: a light ochre in both themes. */
export const OCHRE_FILL: { light: string; dark: string } = { light: "#E9C170", dark: "#E2B75C" };