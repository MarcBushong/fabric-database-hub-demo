// The kiosk (ADR 0030): a chrome-free, auto-rotating view of Mission Control, the scoreboard, and the replay for a booth
// or NOC screen. Space pauses it (WCAG 2.2.2), the arrows switch scenes, and Esc leaves it. It goes full screen when the
// frame allows it (Fullscreen API); inside a frame that doesn't, it says to press F11.

export type KioskScene = "mission" | "scoreboard" | "replay";

export const KIOSK_SCENES: readonly KioskScene[] = ["mission", "scoreboard", "replay"];

export const SCENE_LABEL: Record<KioskScene, string> = { mission: "Mission Control", scoreboard: "Did we catch it?", replay: "Session replay" };

/** How long each scene shows, in seconds: the replay plays the session through. */
export const SCENE_SECONDS: Record<KioskScene, number> = { mission: 20, scoreboard: 20, replay: 45 };

export interface KioskState {
    scene: KioskScene;
    paused: boolean;
    /** Seconds the scene has shown. */
    elapsed: number;
    /** Set when Esc asked to leave. */
    exit: boolean;
}

export type KioskAction = { type: "tick"; seconds: number } | { type: "key"; key: string } | { type: "toggle" } | { type: "go"; scene: KioskScene };

export const KIOSK_START: KioskState = { scene: "mission", paused: false, elapsed: 0, exit: false };

function step(scene: KioskScene, by: 1 | -1): KioskScene {
    const i = KIOSK_SCENES.indexOf(scene);
    return KIOSK_SCENES[(i + by + KIOSK_SCENES.length) % KIOSK_SCENES.length];
}

/** The kiosk's clock and keys: each scene for its seconds, then the next, round and round, unless paused. */
export function kioskReducer(state: KioskState, action: KioskAction): KioskState {
    switch (action.type) {
        case "tick": {
            if (state.paused || state.exit) return state;
            const elapsed = state.elapsed + action.seconds;
            return elapsed >= SCENE_SECONDS[state.scene] ? { ...state, scene: step(state.scene, 1), elapsed: 0 } : { ...state, elapsed };
        }
        case "toggle":
            return { ...state, paused: !state.paused };
        case "go":
            return { ...state, scene: action.scene, elapsed: 0 };
        case "key":
            switch (action.key) {
                case "Escape":
                    return { ...state, exit: true };
                case " ":
                case "Spacebar":
                    return { ...state, paused: !state.paused };
                case "ArrowRight":
                    return { ...state, scene: step(state.scene, 1), elapsed: 0 };
                case "ArrowLeft":
                    return { ...state, scene: step(state.scene, -1), elapsed: 0 };
                default:
                    return state;
            }
    }
}

/** Whether this page may go full screen: a frame without the fullscreen permission may not. */
export function fullscreenAllowed(doc: Document = document): boolean {
    return Boolean(doc.fullscreenEnabled && typeof doc.documentElement.requestFullscreen === "function");
}

/** Asks for full screen (it needs the viewer's click); says whether it could ask. */
export function enterFullscreen(element: HTMLElement, doc: Document = document): boolean {
    if (!fullscreenAllowed(doc) || doc.fullscreenElement) return false;
    element.requestFullscreen().catch(() => undefined);
    return true;
}

export function exitFullscreen(doc: Document = document): void {
    if (doc.fullscreenElement && typeof doc.exitFullscreen === "function") doc.exitFullscreen().catch(() => undefined);
}
