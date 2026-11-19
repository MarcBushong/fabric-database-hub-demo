// The app's themes: Fluent 2 (Fabric's own design system) with the app's own brand ramp (ContosoCare's navy and cyan,
// src/theme/identity.ts, ADR 0030), in light, dark, and high contrast. The app's own tokens (status, targets, charts)
// live beside them, so the contrast tests read the same values the app applies.

import { createDarkTheme, createLightTheme, teamsHighContrastTheme, type BrandVariants, type Theme } from "@fluentui/react-components";

import { APP_BRAND } from "./identity";

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

const light: Theme = { ...createLightTheme(APP_BRAND) };
const dark: Theme = {
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

export const FLUENT_THEMES: Record<ThemeId, Theme> = { light, dark, contrast: teamsHighContrastTheme };

export const THEME_LABELS: Record<ThemeChoice, string> = { system: "Use the system setting", light: "Light", dark: "Dark", contrast: "High contrast" };

/**
 * The app's tokens per theme, as CSS custom properties on <html data-theme>. `surfaces` are the solid colors text sits
 * on; every `text` token must reach 4.5:1 on each (WCAG 2.1 AA), and every `graphic` token 3:1 (WCAG 1.4.11).
 */
export interface AppTokens {
    surfaces: string[];
    text: Record<string, string>;
    graphic: Record<string, string>;
}

export const APP_TOKENS: Record<ThemeId, AppTokens> = {
    light: {
        surfaces: ["#FFFFFF", "#FAFAFA", "#F5F5F5"],
        text: {
            "--status-fail": "#B10E1C",
            "--status-manual": "#0F5AA6",
            "--status-warning": "#8A3707",
            "--status-pass": "#0E700E",
            "--status-muted": "#5C5C5C",
        },
        graphic: {
            "--target-t1": "#0F6CBD",
            "--target-t2": "#038387",
            "--target-t3": "#8764B8",
            "--target-t4": "#CA5010",
            "--target-t4r": "#986F0B",
            "--target-t5": "#498205",
            "--chart-1": "#0F6CBD",
            "--chart-2": "#038387",
            "--chart-3": "#8764B8",
            "--chart-4": "#CA5010",
            "--chart-5": "#498205",
            "--chart-6": "#C239B3",
            "--chart-7": "#986F0B",
            "--chart-8": "#4F6BED",
        },
    },
    dark: {
        surfaces: ["#1F1F1F", "#292929", "#333333"],
        text: {
            "--status-fail": "#F58A93",
            "--status-manual": "#62ABF5",
            "--status-warning": "#F9A86B",
            "--status-pass": "#5EC75E",
            "--status-muted": "#B8B8B8",
        },
        graphic: {
            "--target-t1": "#479EF5",
            "--target-t2": "#4BC5C7",
            "--target-t3": "#B696E1",
            "--target-t4": "#F7894A",
            "--target-t4r": "#E8B83A",
            "--target-t5": "#8FD14F",
            "--chart-1": "#479EF5",
            "--chart-2": "#4BC5C7",
            "--chart-3": "#B696E1",
            "--chart-4": "#F7894A",
            "--chart-5": "#8FD14F",
            "--chart-6": "#E879D9",
            "--chart-7": "#E8B83A",
            "--chart-8": "#93A4F4",
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
    for (const [name, value] of Object.entries({ ...tokens.text, ...tokens.graphic })) root.style.setProperty(name, value);
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
