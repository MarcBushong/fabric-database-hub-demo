import { createContext, useContext } from "react";

import type { DataProvenance } from "./copilot/contract";
import type { Meta } from "./data/model";
import type { Filters } from "./data/queries";
import type { ControlRequest } from "./lib/control";
import type { ManageAccessAnswer, ManageRequestAnswer } from "./lib/manage-client";
import type { AppRuntime } from "./lib/runtime-config";
import type { PageId, ViewState } from "./lib/view-state";

export type NotifyIntent = "success" | "info" | "warning" | "error";

/** Whether this viewer can run the control's actions from the app, and if not, why. */
/** How the Manage page sends actions here: the app's Manage function (A), or by copying them for Run all (C). */
export interface ManageAccess {
    /** "run": the app's Manage function sends confirmed requests; "copy": it isn't deployed, so each action copies its request for Run all. */
    mode: "run" | "copy";
    /** Run mode: the verified viewer is an operator (the deployer or a member of the demo's admin group). */
    canRun: boolean;
    /** One short sentence: why the viewer can't run actions, or how copy mode works. */
    reason: string;
    /** Run mode: the verified viewer, as the control records them. */
    who?: string;
    /** Run mode: the control's run in progress; a new session replaces it. */
    running?: ManageAccessAnswer["running"];
    /** Run mode: sends a confirmed request. */
    send?: (request: ControlRequest) => Promise<ManageRequestAnswer>;
    /** Still finding out which mode this deployment has. */
    checking?: boolean;
}

/** Copy mode (C): without the app's Manage function, each action copies its request for Run all in the control notebook. */
export const MANAGE_READ_ONLY: ManageAccess = {
    mode: "copy",
    canRun: false,
    reason: "This deployment has no Manage function, so each action copies its request for NB_DatabaseHub_Control, where Run all sends it.",
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
