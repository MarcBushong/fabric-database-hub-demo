import { createContext, useContext } from "react";

import type { Filters } from "./data/queries";
import type { Meta } from "./data/model";
import type { AppRuntime } from "./lib/runtime-config";
import type { ViewState } from "./lib/view-state";
import type { ThemeId } from "./theme/themes";

export type MotionPreference = "system" | "reduced" | "full";

export interface AppContextValue {
    runtime: AppRuntime;
    embedded: boolean;
    view: ViewState;
    setView: (patch: Partial<ViewState>) => void;
    filters: Filters;
    meta: Meta | null;
    theme: ThemeId;
    setTheme: (id: ThemeId) => void;
    motion: MotionPreference;
    setMotion: (value: MotionPreference) => void;
    /** True when animations should stop: the OS asks for reduced motion, or the user switched motion off. */
    reducedMotion: boolean;
    notify: (message: string) => void;
}

export const AppContext = createContext<AppContextValue | null>(null);

export function useApp(): AppContextValue {
    const value = useContext(AppContext);
    if (!value) throw new Error("useApp must be used inside the app shell.");
    return value;
}
