// The stage's tokens (ADR 0030): the surfaces and accents that Mission Control, the scoreboard, the replay, the kiosk, and
// Root cause draw on: the app's warm neutrals and shadows (src/theme/fluent.ts), sage for the accent (calm: the healthy
// pulse, the answered incident, the current item) and brick for an alert (an incident the telemetry shows), apart from the
// terracotta brand on buttons and links. Kept apart from identity.ts, so only the pages that draw on the stage load these.

import type { CSSProperties } from "react";

import { FLUENT_THEMES, type ThemeChoice, type ThemeId } from "./fluent";

/**
 * The stage's tokens per theme, as CSS custom properties on the stage element. `surfaces` are the solid colors text and
 * marks sit on (the app's neutral backgrounds 3, 2, and 1 in dark, and 3, 1, and 4 in light: a panel sits a layer above
 * the stage); every `text` token reaches 4.5:1 on each (WCAG 2.2 AA), every `graphic` token 3:1 (WCAG 1.4.11), and so do
 * the app's own status, target, and chart tokens (src/lib/app.test.ts). `decor` carries no information: the wash at the
 * stage's top, and the theme's shadow under a panel.
 */
export interface StageTokens {
    surfaces: Record<string, string>;
    text: Record<string, string>;
    graphic: Record<string, string>;
    decor: Record<string, string>;
}

const { light, dark } = FLUENT_THEMES;

export const STAGE_TOKENS: Record<ThemeId, StageTokens> = {
    dark: {
        surfaces: { "--stage-bg": dark.colorNeutralBackground3, "--stage-panel": dark.colorNeutralBackground2, "--stage-panel-2": dark.colorNeutralBackground1 },
        text: { "--stage-ink": dark.colorNeutralForeground1, "--stage-ink-2": dark.colorNeutralForeground2, "--stage-accent-ink": "#A1CAA8", "--stage-alert-ink": "#EE8679" },
        graphic: { "--stage-accent": "#95C59E", "--stage-alert": "#DD6B5D", "--stage-line": "#8C7D6F", "--stage-node": "#B2A99D" },
        decor: {
            "--stage-grid": "transparent",
            "--stage-glow": "rgba(149, 197, 158, 0.12)",
            "--stage-glow-alert": "rgba(221, 107, 93, 0.24)",
            "--stage-shadow": dark.shadow8,
        },
    },
    light: {
        surfaces: { "--stage-bg": light.colorNeutralBackground3, "--stage-panel": light.colorNeutralBackground1, "--stage-panel-2": light.colorNeutralBackground4 },
        text: { "--stage-ink": light.colorNeutralForeground1, "--stage-ink-2": light.colorNeutralForeground2, "--stage-accent-ink": "#426449", "--stage-alert-ink": "#9A3322" },
        graphic: { "--stage-accent": "#5C8664", "--stage-alert": "#A83828", "--stage-line": "#8A7E70", "--stage-node": "#6B6157" },
        decor: {
            "--stage-grid": "transparent",
            "--stage-glow": "rgba(92, 134, 100, 0.10)",
            "--stage-glow-alert": "rgba(168, 56, 40, 0.14)",
            "--stage-shadow": light.shadow8,
        },
    },
    contrast: {
        surfaces: { "--stage-bg": "#000000", "--stage-panel": "#000000", "--stage-panel-2": "#000000" },
        text: { "--stage-ink": "#FFFFFF", "--stage-ink-2": "#FFFFFF", "--stage-accent-ink": "#00FFFF", "--stage-alert-ink": "#FF66FF" },
        graphic: { "--stage-accent": "#00FFFF", "--stage-alert": "#FF66FF", "--stage-line": "#C0C0FF", "--stage-node": "#FFFFFF" },
        decor: { "--stage-grid": "transparent", "--stage-glow": "transparent", "--stage-glow-alert": "transparent", "--stage-shadow": "none" },
    },
};

/**
 * The stage's theme: Mission Control and the kiosk are dark until the viewer picks a theme; a picked theme, and the
 * system's high contrast, win.
 */
export function stageTheme(choice: ThemeChoice, resolved: ThemeId): ThemeId {
    if (resolved === "contrast") return "contrast";
    return choice === "system" ? "dark" : resolved;
}

/** The stage's tokens and the app's own tokens for that theme, as inline CSS custom properties. */
export function stageStyle(stage: ThemeId, appTokens: { text: Record<string, string>; graphic: Record<string, string>; decor?: Record<string, string> }): CSSProperties {
    const tokens = STAGE_TOKENS[stage];
    return { ...tokens.surfaces, ...tokens.text, ...tokens.graphic, ...tokens.decor, ...appTokens.text, ...appTokens.graphic, ...appTokens.decor } as CSSProperties;
}