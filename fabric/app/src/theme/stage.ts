// The stage's tokens (ADR 0030): the surfaces and accents that Mission Control, the scoreboard, the replay, and the
// kiosk draw on: Fluent 2's layered neutrals and shadows, Microsoft blue for the accent, and the logo's orange-red for an
// alert, with the brand ramp and the logo's colors in identity.ts. Kept apart from identity.ts, so only the pages that
// draw on the stage load them, and the app's main chunk doesn't grow.

import type { CSSProperties } from "react";

import type { ThemeChoice, ThemeId } from "./fluent";

/**
 * The stage's tokens per theme, as CSS custom properties on the stage element. `surfaces` are the solid colors text and
 * marks sit on (Fluent's neutral backgrounds 3, 2, and 1 in dark, and 3, 1, and 4 in light: a panel sits a layer above
 * the stage); every `text` token reaches 4.5:1 on each (WCAG 2.1 AA), every `graphic` token 3:1 (WCAG 1.4.11), and so do
 * the app's own status, target, and chart tokens (src/lib/app.test.ts). `decor` carries no information: the wash at the
 * stage's top, and Fluent's shadow under a panel.
 */
export interface StageTokens {
    surfaces: Record<string, string>;
    text: Record<string, string>;
    graphic: Record<string, string>;
    decor: Record<string, string>;
}

export const STAGE_TOKENS: Record<ThemeId, StageTokens> = {
    dark: {
        surfaces: { "--stage-bg": "#141414", "--stage-panel": "#1F1F1F", "--stage-panel-2": "#292929" },
        text: { "--stage-ink": "#FFFFFF", "--stage-ink-2": "#D6D6D6", "--stage-accent-ink": "#62ABF5", "--stage-alert-ink": "#FF7A5C" },
        graphic: { "--stage-accent": "#479EF5", "--stage-alert": "#F25022", "--stage-line": "#6E7C91", "--stage-node": "#ADADAD" },
        decor: {
            "--stage-grid": "transparent",
            "--stage-glow": "rgba(71, 158, 245, 0.16)",
            "--stage-glow-alert": "rgba(242, 80, 34, 0.26)",
            "--stage-shadow": "0 0 2px rgba(0,0,0,0.24), 0 4px 8px rgba(0,0,0,0.28)",
        },
    },
    light: {
        surfaces: { "--stage-bg": "#F5F5F5", "--stage-panel": "#FFFFFF", "--stage-panel-2": "#F0F0F0" },
        text: { "--stage-ink": "#242424", "--stage-ink-2": "#424242", "--stage-accent-ink": "#0F6CBD", "--stage-alert-ink": "#B7381B" },
        graphic: { "--stage-accent": "#0F6CBD", "--stage-alert": "#D83B01", "--stage-line": "#7A869A", "--stage-node": "#616161" },
        decor: {
            "--stage-grid": "transparent",
            "--stage-glow": "rgba(15, 108, 189, 0.10)",
            "--stage-glow-alert": "rgba(216, 59, 1, 0.16)",
            "--stage-shadow": "0 0 2px rgba(0,0,0,0.12), 0 4px 8px rgba(0,0,0,0.14)",
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
export function stageStyle(stage: ThemeId, appTokens: { text: Record<string, string>; graphic: Record<string, string> }): CSSProperties {
    const tokens = STAGE_TOKENS[stage];
    return { ...tokens.surfaces, ...tokens.text, ...tokens.graphic, ...tokens.decor, ...appTokens.text, ...appTokens.graphic } as CSSProperties;
}
