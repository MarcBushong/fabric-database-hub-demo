import { createContext, useContext } from "react";

import type { ThemeChoice, ThemeId } from "./fluent";

export interface ThemeContextValue {
    /** The theme in use. */
    theme: ThemeId;
    /** What the viewer picked; "system" follows the OS. */
    choice: ThemeChoice;
    setChoice: (choice: ThemeChoice) => void;
}

export const ThemeContext = createContext<ThemeContextValue | null>(null);

export function useTheme(): ThemeContextValue {
    return useContext(ThemeContext) ?? { theme: "light", choice: "system", setChoice: () => undefined };
}
