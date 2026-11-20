// The stage's tokens (ADR 0030): the surfaces and accents that Mission Control, the scoreboard, the replay, and the
// kiosk draw on, in ContosoCare's palette, with the brand ramp in identity.ts. Kept apart from identity.ts, so only the
// pages that draw on the stage load them, and the app's main chunk doesn't grow.

import type { CSSProperties } from "react";

import type { ThemeChoice, ThemeId } from "./fluent";

/**
 * The stage's tokens per theme, as CSS custom properties on the stage element. `surfaces` are the solid colors text and
 * marks sit on; every `text` token reaches 4.5:1 on each (WCAG 2.1 AA), every `graphic` token 3:1 (WCAG 1.4.11), and so do
 * the app's own status, target, and chart tokens (src/lib/app.test.ts). `decor` carries no information.
 */
export interface StageTokens {
    surfaces: Record<string, string>;
    text: Record<string, string>;
    graphic: Record<string, string>;
    decor: Record<string, string>;
}

export const STAGE_TOKENS: Record<ThemeId, StageTokens> = {
    dark: {
        surfaces: { "--stage-bg": "#060D1F", "--stage-panel": "#0C1A36", "--stage-panel-2": "#12234A" },
        text: { "--stage-ink": "#EAF2FF", "--stage-ink-2": "#A9BCDD", "--stage-cyan-ink": "#4FE3FF", "--stage-magenta-ink": "#FF7AE0" },
        graphic: { "--stage-cyan": "#2FE0FF", "--stage-magenta": "#FF4FD8", "--stage-line": "#4C6FA8", "--stage-node": "#9DB6E0" },
        decor: { "--stage-grid": "rgba(79, 227, 255, 0.07)", "--stage-glow": "rgba(47, 224, 255, 0.22)", "--stage-glow-alert": "rgba(255, 79, 216, 0.28)" },
    },
    light: {
        surfaces: { "--stage-bg": "#F3F7FD", "--stage-panel": "#FFFFFF", "--stage-panel-2": "#E8EFFA" },
        text: { "--stage-ink": "#0A1A3A", "--stage-ink-2": "#3D4F70", "--stage-cyan-ink": "#00658A", "--stage-magenta-ink": "#A3127F" },
        graphic: { "--stage-cyan": "#00749C", "--stage-magenta": "#B8128F", "--stage-line": "#6F87B3", "--stage-node": "#4A5F86" },
        decor: { "--stage-grid": "rgba(26, 79, 174, 0.07)", "--stage-glow": "rgba(0, 116, 156, 0.16)", "--stage-glow-alert": "rgba(184, 18, 143, 0.18)" },
    },
    contrast: {
        surfaces: { "--stage-bg": "#000000", "--stage-panel": "#000000", "--stage-panel-2": "#000000" },
        text: { "--stage-ink": "#FFFFFF", "--stage-ink-2": "#FFFFFF", "--stage-cyan-ink": "#00FFFF", "--stage-magenta-ink": "#FF66FF" },
        graphic: { "--stage-cyan": "#00FFFF", "--stage-magenta": "#FF66FF", "--stage-line": "#C0C0FF", "--stage-node": "#FFFFFF" },
        decor: { "--stage-grid": "transparent", "--stage-glow": "transparent", "--stage-glow-alert": "transparent" },
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
export function stageStyle(stage: ThemeId, appTokens: { text: Record<string, string>; graphic: Record<string, string> }): CSSProperties {
    const tokens = STAGE_TOKENS[stage];
    return { ...tokens.surfaces, ...tokens.text, ...tokens.graphic, ...tokens.decor, ...appTokens.text, ...appTokens.graphic } as CSSProperties;
}
