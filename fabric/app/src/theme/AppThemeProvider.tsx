// The theme around everything, the sign-in screen included: Fluent 2's provider with the app's tokens on <html>.

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { FluentProvider } from "@fluentui/react-components";

import { useMediaQuery } from "@/lib/hooks";
import { applyAppTokens, FLUENT_THEMES, loadThemeChoice, resolveTheme, saveThemeChoice, type ThemeChoice } from "./fluent";
import { ThemeContext, type ThemeContextValue } from "./theme-context";

export function AppThemeProvider({ children, initialChoice }: { children: ReactNode; initialChoice?: ThemeChoice }) {
    const prefersDark = useMediaQuery("(prefers-color-scheme: dark)");
    const prefersContrast = useMediaQuery("(prefers-contrast: more), (forced-colors: active)");
    const [choice, setChoiceState] = useState<ThemeChoice>(() => initialChoice ?? loadThemeChoice(typeof window !== "undefined" ? window.localStorage : undefined));
    const theme = resolveTheme(choice, prefersDark, prefersContrast);

    useEffect(() => applyAppTokens(theme), [theme]);

    const setChoice = useCallback((next: ThemeChoice) => {
        setChoiceState(next);
        saveThemeChoice(window.localStorage, next);
    }, []);
    const value = useMemo<ThemeContextValue>(() => ({ theme, choice, setChoice }), [theme, choice, setChoice]);

    return (
        <ThemeContext.Provider value={value}>
            {/* Fluent copies the provider's class names to its portals, so the app's layout class sits on an inner element. */}
            <FluentProvider theme={FLUENT_THEMES[theme]} style={{ height: "100%" }}>
                <div className="app-root">{children}</div>
            </FluentProvider>
        </ThemeContext.Provider>
    );
}
