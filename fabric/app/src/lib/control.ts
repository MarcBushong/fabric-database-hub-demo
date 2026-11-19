// The Manage page's actions as requests to the demo's own session control: each one maps to the control notebook's
// parameters (fabric/control/NB_DatabaseHub_Control.ipynb, its "parameters" cell), which the notebook checks and sends
// to the runbook, which checks every request again against its allow-lists and caps. Pure, so it's tested.

import { SCENARIOS, SESSION_MINUTES } from "./scenarios";
import type { FilterTarget } from "./view-state";

export type ControlAction = "session" | "run" | "stop" | "reset";

export interface ControlRequest {
    action: ControlAction;
    durationMinutes?: number;
    target?: FilterTarget;
    scenario?: string;
    intensity?: number;
    targets?: FilterTarget[];
}

/** A notebook parameter as the Fabric job API takes it (executionData.parameters). */
export interface NotebookParameter {
    value: string | number | boolean;
    type: "string" | "int" | "bool";
}

/** Why the request is out of bounds, or null when it's within them. The runbook checks the same bounds again. */
export function validateRequest(req: ControlRequest): string | null {
    switch (req.action) {
        case "session": {
            const minutes = req.durationMinutes ?? SESSION_MINUTES.default;
            if (!Number.isInteger(minutes) || minutes < SESSION_MINUTES.min || minutes > SESSION_MINUTES.max) return `A session runs ${SESSION_MINUTES.min} to ${SESSION_MINUTES.max} minutes.`;
            return null;
        }
        case "run": {
            const scenario = SCENARIOS.find((s) => s.id === req.scenario);
            if (!scenario) return "Pick a scenario from the catalog.";
            if (!req.target || !scenario.targets.includes(req.target)) return `${scenario.title} runs on ${scenario.targets.join(", ")}.`;
            const minutes = req.durationMinutes ?? scenario.defaultMinutes;
            if (!Number.isInteger(minutes) || minutes < 5 || minutes > scenario.maxMinutes) return `${scenario.title} runs 5 to ${scenario.maxMinutes} minutes.`;
            if (req.intensity !== undefined && (!Number.isInteger(req.intensity) || req.intensity < 1 || req.intensity > 10)) return "Intensity is 1 to 10.";
            return null;
        }
        case "reset":
            if (req.targets && req.targets.some((t) => !["T1", "T2", "T3", "T4"].includes(t))) return "Reset applies to T1, T2, T3, and T4.";
            return null;

        case "stop":
            return null;
        default:
            return "Unknown action.";
    }
}

/** The control notebook's parameters for a request: what a Run all with these values does. */
export function notebookParameters(req: ControlRequest): Record<string, NotebookParameter> {
    switch (req.action) {
        case "session":
            return {
                MODE: { value: "session", type: "string" },
                DURATION_MINUTES: { value: req.durationMinutes ?? SESSION_MINUTES.default, type: "int" },
                WAIT_FOR_END: { value: true, type: "bool" },
            };
        case "run": {
            const scenario = SCENARIOS.find((s) => s.id === req.scenario);
            const activity: Record<string, unknown> = { target: req.target, scenario: req.scenario };
            if (req.intensity !== undefined) activity.intensity = req.intensity;
            return {
                MODE: { value: "activities", type: "string" },
                ACTIVITIES: { value: JSON.stringify([activity]), type: "string" },
                DURATION_MINUTES: { value: req.durationMinutes ?? scenario?.defaultMinutes ?? 10, type: "int" },
                WATCH_MINUTES: { value: 0, type: "int" },
            };
        }
        case "stop":
            return { STOP_NOW: { value: true, type: "bool" } };
        case "reset":
            return { RESET_NOW: { value: true, type: "bool" }, RESET_TARGETS: { value: JSON.stringify(req.targets ?? []), type: "string" } };

    }
}

export interface RequestSummary {
    title: string;
    /** What happens, in order, in plain words. */
    effects: string[];
    /** The bounds that hold whatever happens. */
    bounds: string[];
}

export function describeRequest(req: ControlRequest): RequestSummary {
    const scenario = SCENARIOS.find((s) => s.id === req.scenario);
    switch (req.action) {
        case "session": {
            const minutes = req.durationMinutes ?? SESSION_MINUTES.default;
            return {
                title: `Start a ${minutes}-minute session`,
                effects: [
                    "Starts T1's and T2's VMs, T3's database, and T4 with its read replica, if they're stopped.",
                    "Runs the showcase on every target: the baseline plus bounded incidents, at most two at a time per target.",
                    "Includes T3's Database Agent beat (minutes 30 to 60): the plan regresses, the agent raises its issue, and the run applies the documented response, forcing the last good plan through Query Store.",
                    `Ends after ${minutes} minutes: saves T4's metrics, deletes the read replica, stops T4, deallocates the VMs, and saves the session's history.`,
                ],
                bounds: [
                    "The same session as Run all in NB_DatabaseHub_Control; a Run all while it runs follows it.",
                    `${SESSION_MINUTES.min} to ${SESSION_MINUTES.max} minutes, always before the VMs' nightly auto-shutdown.`,
                    "The workload acts only inside ContosoCare, on sessions tagged ContosoCare.Demo/.",
                ],
            };
        }
        case "run":
            return {
                title: `Run ${scenario?.title ?? req.scenario} on ${req.target}`,
                effects: [
                    `Runs ${scenario?.title ?? req.scenario} on ${req.target} for ${req.durationMinutes ?? scenario?.defaultMinutes ?? 10} minutes${req.intensity ? ` at intensity ${req.intensity}` : ""}, with the baseline beside it.`,
                    "Stops by itself at the end; Stop now ends it sooner.",
                ],
                bounds: [`At most ${scenario?.maxMinutes ?? 30} minutes for this scenario; the runbook checks the catalog again.`, "Inside ContosoCare only, on sessions tagged ContosoCare.Demo/."],
            };
        case "stop":
            return {
                title: "Stop now",
                effects: [
                    "Stops every running activity.",
                    "Ends the session as its end would: saves T4's and its replica's metrics, deletes the replica, stops T4, and deallocates the VMs.",
                    "Saves the session's history once the telemetry arrives, about 15 minutes later.",
                ],
                bounds: ["Without a session, it stops whatever runs.", "The same as STOP_NOW in NB_DatabaseHub_Control."],
            };
        case "reset":
            return {
                title: `Reset ${req.targets && req.targets.length > 0 ? req.targets.join(", ") : "every running target"}`,
                effects: ["Stops the scenarios and returns ContosoCare to its seed state on the targets whose VM runs.", "Ends only sessions tagged ContosoCare.Demo/; nothing outside ContosoCare changes."],
                bounds: ["No infrastructure is redeployed.", "The same as RESET_NOW in NB_DatabaseHub_Control."],
            };
    }
}
