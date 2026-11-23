// The app's themes: Fluent 2 (Fabric's own design system) in the app's own earth tones (src/theme/identity.ts, ADR 0030):
// the terracotta brand ramp, Fluent's grays warmed into cream and espresso, and Fluent's status families in the same earth
// tones, in light and dark; high contrast stays Fluent's own. The app's own tokens (status, targets, charts) live beside
// them, so the contrast tests read the same values the app applies.

import { createDarkTheme, createLightTheme, teamsHighContrastTheme, type BrandVariants, type Theme } from "@fluentui/react-components";

import { APP_BRAND, EARTH_ACCENTS, EARTH_STATUS, EARTH_STATUS_FAMILIES, OCHRE_FILL, WARM_NEUTRALS, WARM_SHADOW, type Accents, type StatusFamily, type WarmRamp } from "./identity";

export type ThemeId = "light" | "dark" | "contrast";
export type ThemeChoice = ThemeId | "system";

/** Fabric's teal, #117865 at 80: the app's brand until ADR 0030, kept for a one-line swap back (APP_BRAND). */
export const FABRIC_BRAND: BrandVariants = {
    10: "#030F0C",
    20: "#0A1D19",
    30: "#0C2C26",
    40: "#0D3A32",
    50: "#0D483E",
    60: "#0F574B",
    70: "#106758",
    80: "#117865",
    90: "#2E8775",
    100: "#479685",
    110: "#5EA595",
    120: "#75B4A6",
    130: "#8CC3B7",
    140: "#A4D2C8",
    150: "#BCE1D9",
    160: "#D5EFEA",
};

const channel = (hex: string, i: number) => parseInt(hex.slice(1 + 2 * i, 3 + 2 * i), 16);

/** The warm color for one of Fluent's gray levels (0 to 255), interpolated between the ramp's two nearest anchors. */
export function warmGray(level: number, ramp: WarmRamp): string {
    let i = 1;
    while (i < ramp.length - 1 && ramp[i][0] < level) i++;
    const [l0, c0] = ramp[i - 1];
    const [l1, c1] = ramp[i];
    const t = Math.min(1, Math.max(0, (level - l0) / (l1 - l0)));
    return `#${[0, 1, 2].map((k) => Math.round(channel(c0, k) + (channel(c1, k) - channel(c0, k)) * t).toString(16).padStart(2, "0")).join("").toUpperCase()}`;
}

const GRAY = /^#([0-9a-f]{2})\1\1$/i;
const GRAY_RGBA = /rgba\((\d{1,3}),\s*\1,\s*\1,\s*([\d.]+)\)/g;
const BLACK_RGBA = /rgba\(0,\s*0,\s*0,\s*([\d.]+)\)/g;

/**
 * A Fluent theme with its grays warmed: every pure gray token (#RRGGBB with equal channels, or a translucent one) takes
 * the ramp's color at its level, and every shadow a warm tint, so hover, pressed, selected, and disabled states keep
 * Fluent's steps between them. Colored tokens, the brand's and the palette's, are left as they are.
 */
export function warmTheme(theme: Theme, ramp: WarmRamp, shadow: { rgb: string; alpha: number }): Theme {
    const out: Record<string, unknown> = { ...theme };
    for (const [name, value] of Object.entries(theme)) {
        if (typeof value !== "string") continue;
        if (GRAY.test(value)) out[name] = warmGray(parseInt(value.slice(1, 3), 16), ramp);
        else if (name.startsWith("shadow") || name.startsWith("colorNeutralShadow")) {
            out[name] = value.replace(BLACK_RGBA, (_, a: string) => `rgba(${shadow.rgb}, ${+(Number(a) * shadow.alpha).toFixed(3)})`);
        } else {
            out[name] = value.replace(GRAY_RGBA, (_, level: string, a: string) => {
                const hex = warmGray(Number(level), ramp);
                return `rgba(${channel(hex, 0)}, ${channel(hex, 1)}, ${channel(hex, 2)}, ${a})`;
            });
        }
    }
    return out as unknown as Theme;
}

/** Fluent's status families (message bars, badges, field states) in the app's earth tones; only tokens Fluent has are set. */
function statusTokens(base: Theme, families: Record<"danger" | "warning" | "success", StatusFamily>, ochreFill: string): Partial<Theme> {
    const out: Record<string, string> = {};
    const put = (prefix: string, family: StatusFamily) => {
        for (const [role, color] of Object.entries(family)) {
            const name = `${prefix}${role[0].toUpperCase()}${role.slice(1)}`;
            if (name in base) out[name] = color;
        }
    };
    put("colorStatusDanger", families.danger);
    put("colorStatusWarning", families.warning);
    put("colorStatusSuccess", families.success);
    put("colorPaletteRed", families.danger);
    put("colorPaletteDarkOrange", families.danger);
    put("colorPaletteYellow", { ...families.warning, background3: ochreFill });
    put("colorPaletteGreen", families.success);
    return out as Partial<Theme>;
}

const lightBase = createLightTheme(APP_BRAND);
const light: Theme = {
    ...warmTheme(lightBase, WARM_NEUTRALS.light, WARM_SHADOW.light),
    ...statusTokens(lightBase, EARTH_STATUS_FAMILIES.light, OCHRE_FILL.light),
    // A danger button's hover and press: a deeper brick under the same cream text.
    colorStatusDangerBackground3Hover: "#87291F",
    colorStatusDangerBackground3Pressed: "#74221A",
};
const darkBase: Theme = {
    ...createDarkTheme(APP_BRAND),
    colorBrandForeground1: APP_BRAND[110],
    colorBrandForeground2: APP_BRAND[120],
    colorBrandForegroundLink: APP_BRAND[120],
    colorBrandForegroundLinkHover: APP_BRAND[130],
    colorCompoundBrandForeground1: APP_BRAND[110],
    colorCompoundBrandStroke: APP_BRAND[110],
    colorNeutralForeground2BrandHover: APP_BRAND[110],
    colorNeutralForeground2BrandSelected: APP_BRAND[110],
    colorSubtleBackgroundSelected: "#383838",
};
const dark: Theme = {
    ...warmTheme(darkBase, WARM_NEUTRALS.dark, WARM_SHADOW.dark),
    ...statusTokens(darkBase, EARTH_STATUS_FAMILIES.dark, OCHRE_FILL.dark),
    // A danger button's hover and press: a deeper brick under the same cream text.
    colorStatusDangerBackground3Hover: "#8C352E",
    colorStatusDangerBackground3Pressed: "#7A2D27",
};

export const FLUENT_THEMES: Record<ThemeId, Theme> = { light, dark, contrast: teamsHighContrastTheme };

export const THEME_LABELS: Record<ThemeChoice, string> = { system: "Use the system setting", light: "Light", dark: "Dark", contrast: "High contrast" };

/**
 * The app's tokens per theme, as CSS custom properties on <html data-theme>. `surfaces` are the solid colors text sits
 * on; every `text` token must reach 4.5:1 on each (WCAG 2.2 AA), and every `graphic` token 3:1 (WCAG 1.4.11). `decor`
 * carries no information on its own: the chart's incident band behind its label, and the Copilot mark's fill under its
 * glyph (`--copilot-mark-ink`, which the tests hold to 3:1 on both of the fill's stops).
 */
export interface AppTokens {
    surfaces: string[];
    text: Record<string, string>;
    graphic: Record<string, string>;
    decor: Record<string, string>;
}

/**
 * Each target's mark and the charts' categories, from one theme's accents: slate, moss, ochre, and clay on T1 to T4 and the
 * first four categories, plum and verdigris on T5 and T4's read replica, then stone and rose.
 */
function accentTokens(a: Accents): Record<string, string> {
    return {
        "--target-t1": a.slate,
        "--target-t2": a.moss,
        "--target-t3": a.ochre,
        "--target-t4": a.clay,
        "--target-t4r": a.verdigris,
        "--target-t5": a.plum,
        "--chart-1": a.slate,
        "--chart-2": a.moss,
        "--chart-3": a.ochre,
        "--chart-4": a.clay,
        "--chart-5": a.plum,
        "--chart-6": a.verdigris,
        "--chart-7": a.stone,
        "--chart-8": a.rose,
    };
}

const rgbOf = (hex: string) => `${channel(hex, 0)}, ${channel(hex, 1)}, ${channel(hex, 2)}`;
/** The Copilot mark's fill, terracotta into a deep plum, in both themes. */
const copilotMark = (from: string) => `linear-gradient(135deg, ${from} 0%, ${EARTH_ACCENTS.light.plum} 100%)`;

export const APP_TOKENS: Record<ThemeId, AppTokens> = {
    light: {
        surfaces: [light.colorNeutralBackground1, light.colorNeutralBackground2, light.colorNeutralBackground3],
        text: {
            "--status-fail": EARTH_STATUS.light.fail,
            "--status-manual": EARTH_STATUS.light.manual,
            "--status-warning": EARTH_STATUS.light.warning,
            "--status-pass": EARTH_STATUS.light.pass,
            "--status-muted": light.colorNeutralForeground3,
            "--chart-band-ink": EARTH_STATUS.light.fail,
        },
        graphic: accentTokens(EARTH_ACCENTS.light),
        decor: {
            "--chart-band": `rgba(${rgbOf(EARTH_STATUS_FAMILIES.light.danger.foreground3)}, 0.1)`,
            "--copilot-mark": copilotMark(APP_BRAND[80]),
            "--copilot-mark-ink": light.colorNeutralForegroundOnBrand,
        },
    },
    dark: {
        surfaces: [dark.colorNeutralBackground2, dark.colorNeutralBackground1, dark.colorNeutralBackground6],
        text: {
            "--status-fail": EARTH_STATUS.dark.fail,
            "--status-manual": EARTH_STATUS.dark.manual,
            "--status-warning": EARTH_STATUS.dark.warning,
            "--status-pass": EARTH_STATUS.dark.pass,
            "--status-muted": dark.colorNeutralForeground3,
            "--chart-band-ink": EARTH_STATUS.dark.fail,
        },
        graphic: accentTokens(EARTH_ACCENTS.dark),
        decor: {
            "--chart-band": `rgba(${rgbOf(EARTH_STATUS.dark.fail)}, 0.14)`,
            "--copilot-mark": copilotMark(APP_BRAND[70]),
            "--copilot-mark-ink": dark.colorNeutralForegroundOnBrand,
        },
    },
    contrast: {
        surfaces: ["#000000"],
        text: {
            "--status-fail": "#FF8C8C",
            "--status-manual": "#00FFFF",
            "--status-warning": "#FFFF00",
            "--status-pass": "#3FF23F",
            "--status-muted": "#FFFFFF",
            "--chart-band-ink": "#FFFF00",
        },
        graphic: {
            "--target-t1": "#FFFF00",
            "--target-t2": "#00FFFF",
            "--target-t3": "#FF99FF",
            "--target-t4": "#FFB366",
            "--target-t4r": "#C0C0FF",
            "--target-t5": "#3FF23F",
            "--chart-1": "#FFFF00",
            "--chart-2": "#00FFFF",
            "--chart-3": "#FF99FF",
            "--chart-4": "#FFB366",
            "--chart-5": "#3FF23F",
            "--chart-6": "#FFFFFF",
            "--chart-7": "#C0C0FF",
            "--chart-8": "#FF8C8C",
        },
        // High contrast keeps the look it had: Copilot's purple-to-blue mark with a white glyph.
        decor: {
            "--chart-band": "rgba(255, 255, 0, 0.18)",
            "--copilot-mark": "linear-gradient(135deg, #8A3FFC 0%, #0F6CBD 100%)",
            "--copilot-mark-ink": "#FFFFFF",
        },
    },
};
export function isThemeChoice(value: unknown): value is ThemeChoice {
    return value === "system" || value === "light" || value === "dark" || value === "contrast";
}

/** The theme a choice resolves to, given the system's preferences. */
export function resolveTheme(choice: ThemeChoice, prefersDark: boolean, prefersContrast: boolean): ThemeId {
    if (choice !== "system") return choice;
    if (prefersContrast) return "contrast";
    return prefersDark ? "dark" : "light";
}

/** Sets the app's tokens and the color scheme on <html>, so CSS and charts follow the theme. */
export function applyAppTokens(id: ThemeId, root: HTMLElement = document.documentElement): void {
    const tokens = APP_TOKENS[id];
    for (const [name, value] of Object.entries({ ...tokens.text, ...tokens.graphic, ...tokens.decor })) root.style.setProperty(name, value);
    root.dataset.theme = id;
    root.style.colorScheme = id === "light" ? "light" : "dark";
}

const THEME_KEY = "dbhub-insights.theme.v2";
const LEGACY_THEME_KEY = "dbhub-insights.theme.v1";
const LEGACY: Record<string, ThemeChoice> = { aurora: "dark", daybreak: "light", contrast: "contrast" };

/** The saved choice; an older app's choice (aurora, daybreak, contrast) carries over. */
export function loadThemeChoice(storage: Pick<Storage, "getItem"> | undefined): ThemeChoice {
    try {
        const saved = storage?.getItem(THEME_KEY);
        if (isThemeChoice(saved)) return saved;
        const legacy = storage?.getItem(LEGACY_THEME_KEY);
        if (legacy && LEGACY[legacy]) return LEGACY[legacy];
    } catch {
        // Storage can be unavailable in a locked-down frame.
    }
    return "system";
}

export function saveThemeChoice(storage: Pick<Storage, "setItem"> | undefined, choice: ThemeChoice): void {
    try {
        storage?.setItem(THEME_KEY, choice);
    } catch {
        // The choice still applies to this session.
    }
}

/** WCAG relative luminance of #RRGGBB. */
export function luminance(hex: string): number {
    const value = hex.replace("#", "");
    const channel = (i: number) => {
        const c = parseInt(value.slice(i, i + 2), 16) / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
}

export function contrastRatio(a: string, b: string): number {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}
