import { createContext, useContext } from "react";

import type { DataProvenance } from "./copilot/contract";
import type { Meta } from "./data/model";
import type { Filters } from "./data/queries";
import type { AppRuntime } from "./lib/runtime-config";
import type { PageId, ViewState } from "./lib/view-state";

export type NotifyIntent = "success" | "info" | "warning" | "error";

/** Whether this viewer can run the control's actions from the app, and if not, why. */
export interface ManageAccess {
    canRun: boolean;
    /** One short sentence for viewers who see the actions read-only. */
    reason: string;
}

/** Until the app's own control path is approved and deployed, its actions are read-only (Run all stays the demo's action). */
export const MANAGE_READ_ONLY: ManageAccess = {
    canRun: false,
    reason: "Actions from the app aren't connected in this deployment. Run all in NB_DatabaseHub_Control runs a whole session.",
};

export interface AppContextValue {
    runtime: AppRuntime;
    embedded: boolean;
    view: ViewState;
    setView: (patch: Partial<ViewState>) => void;
    /** Opens a page; drill-downs that belong to another page are cleared unless the patch sets them. */
    navigate: (page: PageId, patch?: Partial<ViewState>) => void;
    /** The SQL targets of the global filter (the telemetry history's) and the period. */
    filters: Filters;
    meta: Meta | null;
    /** True while the history's freshness is loading; false once known, even when empty. */
    metaLoading: boolean;
    metaError: Error | null;
    /** Where the app's data comes from: the history model, or the preview's sample. */
    provenance: DataProvenance;
    reducedMotion: boolean;
    notify: (message: string, intent?: NotifyIntent) => void;
    manage: ManageAccess;
}

export const AppContext = createContext<AppContextValue | null>(null);

export function useApp(): AppContextValue {
    const value = useContext(AppContext);
    if (!value) throw new Error("useApp must be used inside the app shell.");
    return value;
}
