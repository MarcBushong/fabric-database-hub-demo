// The Copilot dock's place in the shell: a resizable panel on the right, or the whole app in full-screen mode. The
// chat (src/copilot) renders the panel itself; this owns its width, its mode, and the splitter.

import { useCallback, useEffect, useId, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";

import type { DockMode } from "@/copilot/contract";
import { CopilotDock } from "@/copilot/CopilotDock";
import { useCopilotDock } from "@/copilot/use-copilot";

const WIDTH_KEY = "dbhub-insights.dock-width.v1";
export const DOCK_MIN = 320;
export const DOCK_DEFAULT = 420;

function loadWidth(): number {
    try {
        const saved = Number(window.localStorage.getItem(WIDTH_KEY));
        if (Number.isFinite(saved) && saved >= DOCK_MIN) return saved;
    } catch {
        // Storage can be unavailable.
    }
    return DOCK_DEFAULT;
}

/** The widest the dock may get: 60 % of the window, and never less than the minimum. */
function maxDockWidth(viewport: number): number {
    return Math.max(DOCK_MIN, Math.round(viewport * 0.6));
}

export function DockRegion() {
    const dock = useCopilotDock();
    const headingId = useId();
    const [mode, setMode] = useState<DockMode>("docked");
    const [width, setWidth] = useState(loadWidth);
    const drag = useRef<{ x: number; width: number } | null>(null);
    const [viewport, setViewport] = useState(() => (typeof window !== "undefined" ? window.innerWidth : 1440));

    useEffect(() => {
        const onResize = () => setViewport(window.innerWidth);
        window.addEventListener("resize", onResize);
        return () => window.removeEventListener("resize", onResize);
    }, []);

    const save = useCallback((next: number) => {
        try {
            window.localStorage.setItem(WIDTH_KEY, String(next));
        } catch {
            // The width still applies to this session.
        }
    }, []);

    const max = maxDockWidth(viewport);
    const shown = Math.min(Math.max(width, DOCK_MIN), max);
    const close = useCallback(() => {
        setMode("docked");
        dock.setOpen(false);
    }, [dock]);

    useEffect(() => {
        if (!dock.isOpen || mode !== "fullscreen") return;
        const onKey = (event: globalThis.KeyboardEvent) => {
            if (event.key === "Escape") setMode("docked");
        };
        document.addEventListener("keydown", onKey);
        return () => document.removeEventListener("keydown", onKey);
    }, [dock.isOpen, mode]);

    if (!dock.isOpen) return null;

    const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
        drag.current = { x: event.clientX, width: shown };
        event.currentTarget.setPointerCapture(event.pointerId);
    };
    const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
        if (!drag.current) return;
        setWidth(Math.min(Math.max(drag.current.width + (drag.current.x - event.clientX), DOCK_MIN), max));
    };
    const onPointerUp = () => {
        if (drag.current) save(shown);
        drag.current = null;
    };
    const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
        const step = event.shiftKey ? 64 : 16;
        let next: number | null = null;
        if (event.key === "ArrowLeft") next = shown + step;
        else if (event.key === "ArrowRight") next = shown - step;
        else if (event.key === "Home") next = max;
        else if (event.key === "End") next = DOCK_MIN;
        if (next !== null) {
            event.preventDefault();
            const clamped = Math.min(Math.max(next, DOCK_MIN), max);
            setWidth(clamped);
            save(clamped);
        }
    };

    return (
        <aside className={`dock dock-${mode}`} style={mode === "docked" ? { width: shown } : undefined} aria-labelledby={headingId}>
            {mode === "docked" ? (
                <div
                    className="dock-splitter"
                    role="separator"
                    aria-orientation="vertical"
                    aria-label="Resize Copilot"
                    aria-valuemin={DOCK_MIN}
                    aria-valuemax={max}
                    aria-valuenow={shown}
                    tabIndex={0}
                    onPointerDown={onPointerDown}
                    onPointerMove={onPointerMove}
                    onPointerUp={onPointerUp}
                    onPointerCancel={onPointerUp}
                    onKeyDown={onKeyDown}
                    onDoubleClick={() => {
                        setWidth(DOCK_DEFAULT);
                        save(DOCK_DEFAULT);
                    }}
                />
            ) : null}
            <div className="dock-panel">
                <CopilotDock mode={mode} onModeChange={setMode} onClose={close} headingId={headingId} />
            </div>
        </aside>
    );
}
