// The stage that Mission Control, the scoreboard's banner, the replay, and the kiosk draw on: the app's own identity
// (ADR 0030), dark until the viewer picks a theme, with the app's status, target, and chart tokens for the stage's theme.

import type { ReactNode } from "react";
import { FluentProvider } from "@fluentui/react-components";

import { APP_TOKENS, FLUENT_THEMES } from "@/theme/fluent";
import { stageStyle, stageTheme } from "@/theme/stage";
import { useTheme } from "@/theme/theme-context";

export function Stage({ children, className, label }: { children: ReactNode; className?: string; label?: string }) {
    const { theme, choice } = useTheme();
    const stage = stageTheme(choice, theme);
    return (
        <FluentProvider
            theme={FLUENT_THEMES[stage]}
            className={`stage stage-${stage}${className ? ` ${className}` : ""}`}
            style={stageStyle(stage, APP_TOKENS[stage])}
            data-stage={stage}
            role={label ? "region" : undefined}
            aria-label={label}
        >
            {children}
        </FluentProvider>
    );
}
