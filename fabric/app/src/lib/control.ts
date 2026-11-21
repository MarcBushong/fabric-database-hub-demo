// The Manage page's actions as requests to the demo's own session control: each one maps to the control notebook's
// parameters (fabric/control/NB_DatabaseHub_Control.ipynb, its "parameters" cell), which the notebook checks and sends
// to the runbook, which checks every request again against its allow-lists and caps. Pure, so it's tested.

import { controlScenario } from "../../rayfin/functions/src/manage-core";
import { SCENARIOS, SESSION_MINUTES, type ScenarioInfo } from "./scenarios";
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

/** A run's bounds in the control (its runbook's minDurationMinutes and maxDurationMinutes), whatever the scenario. */
export const CONTROL_RUN_MINUTES = { min: 5, max: 120 } as const;

/** A scenario's minutes as the control runs it: its own maximum, within the control's bounds for a run. */
export function runMinutes(scenario: Pick<ScenarioInfo, "maxMinutes" | "defaultMinutes">): { min: number; max: number; default: number } {
    const max = Math.min(scenario.maxMinutes, CONTROL_RUN_MINUTES.max);
    return { min: CONTROL_RUN_MINUTES.min, max, default: Math.min(scenario.defaultMinutes, max) };
}

const sayTargets = (targets: readonly string[]) => (targets.length < 3 ? targets.join(" and ") : `${targets.slice(0, -1).join(", ")}, and ${targets[targets.length - 1]}`);

/**
 * Why the request is out of bounds, or null when it's within them. The runbook checks the same bounds again. With the
 * control's own targets (from the Manage function), a target the control doesn't have, T5 while it's off, is refused too.
 */
export function validateRequest(req: ControlRequest, controlTargets?: readonly string[]): string | null {
    switch (req.action) {
        case "session": {
            const minutes = req.durationMinutes ?? SESSION_MINUTES.default;
            if (!Number.isInteger(minutes) || minutes < SESSION_MINUTES.min || minutes > SESSION_MINUTES.max) return `A session runs ${SESSION_MINUTES.min} to ${SESSION_MINUTES.max} minutes.`;
            return null;
        }
        case "run": {
            const scenario = SCENARIOS.find((s) => s.id === req.scenario);
            if (!scenario) return "Pick a scenario from the catalog.";
            const targets = scenario.targets.filter((t) => !controlTargets || controlTargets.includes(t));
            if (!req.target || !targets.includes(req.target)) return targets.length > 0 ? `${scenario.title} runs on ${sayTargets(targets)}${controlTargets ? " here" : ""}.` : `${scenario.title} has no target in this demo.`;
            const bounds = runMinutes(scenario);
            const minutes = req.durationMinutes ?? bounds.default;
            if (!Number.isInteger(minutes) || minutes < bounds.min || minutes > bounds.max) return `${scenario.title} runs ${bounds.min} to ${bounds.max} minutes.`;
            if (req.intensity !== undefined && (!Number.isInteger(req.intensity) || req.intensity < 1 || req.intensity > 10)) return "Intensity is 1 to 10.";
            return null;
        }
        case "reset": {
            const targets = controlTargets ?? ["T1", "T2", "T3", "T4", "T5"];
            if (req.targets && req.targets.some((t) => !targets.includes(t))) return `Reset applies to ${sayTargets(targets)}${controlTargets ? " here" : ""}.`;
            return null;
        }

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
            // In the control's own words: healthy-baseline is its "baseline".
            const activity: Record<string, unknown> = { target: req.target, scenario: controlScenario(req.scenario ?? "") };
            if (req.intensity !== undefined) activity.intensity = req.intensity;
            return {
                MODE: { value: "activities", type: "string" },
                ACTIVITIES: { value: JSON.stringify([activity]), type: "string" },
                DURATION_MINUTES: { value: req.durationMinutes ?? (scenario ? runMinutes(scenario).default : 10), type: "int" },
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
                    "Starts T1's and T2's VMs, T3's database, and T4 with its read replica, if they're stopped, and creates T5's container when a stop deleted it.",
                    "Runs the showcase on every target: the baseline plus bounded incidents, at most two at a time per target.",
                    "Includes T3's Database Agent beat (minutes 30 to 60): the plan regresses, the agent raises its issue, and the run applies the documented response, forcing the last good plan through Query Store.",
                    `Ends after ${minutes} minutes: saves T4's metrics, and T5's when it's deployed, deletes the read replica, stops T4, deallocates the VMs, and saves the session's history. T5's account has no stop: its activity ends with T1's VM, and its container is deleted when T5's lifecycle is Session; with AlwaysOn, the container stays.`,
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
                bounds: [`At most ${scenario ? runMinutes(scenario).max : CONTROL_RUN_MINUTES.max} minutes for this scenario; the runbook checks the catalog again.`, "Inside ContosoCare only, on sessions tagged ContosoCare.Demo/."],
            };
        case "stop":
            return {
                title: "Stop now",
                effects: [
                    "Stops every running activity.",
                    "Ends the session as its end would: saves T4's, its replica's, and T5's metrics, deletes the replica, stops T4, deallocates the VMs, and deletes T5's container when T5's lifecycle is Session. With AlwaysOn, the container stays; T5's account has no stop.",
                    "Saves the session's history once the telemetry arrives, about 15 minutes later.",
                ],
                bounds: ["Without a session, it stops whatever runs.", "The same as STOP_NOW in NB_DatabaseHub_Control."],
            };
        case "reset":
            return {
                title: `Reset ${req.targets && req.targets.length > 0 ? req.targets.join(", ") : "every running target"}`,
                effects: [
                    "Stops the scenarios and returns ContosoCare to its seed state on the targets whose VM runs.",
                    "On T5, deletes any RU-storm documents a cut-off run left; the baseline's documents stay.",
                    "Ends only sessions tagged ContosoCare.Demo/; nothing outside ContosoCare changes.",
                ],
                bounds: ["No infrastructure is redeployed.", "The same as RESET_NOW in NB_DatabaseHub_Control."],
            };
    }
}
