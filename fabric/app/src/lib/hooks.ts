import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type RefObject } from "react";

import type { AgentSurface } from "./agent-prompts";

/** Width and height of an element, kept current with ResizeObserver (the portal's item frame resizes often). */
export function useElementSize<T extends HTMLElement>(fallbackWidth = 640): [RefObject<T | null>, { width: number; height: number }] {
    const ref = useRef<T>(null);
    const [size, setSize] = useState({ width: fallbackWidth, height: 0 });
    useEffect(() => {
        const element = ref.current;
        if (!element || typeof ResizeObserver === "undefined") return;
        const observer = new ResizeObserver((entries) => {
            const box = entries[0]?.contentRect;
            if (box && box.width > 0) setSize({ width: Math.round(box.width), height: Math.round(box.height) });
        });
        observer.observe(element);
        return () => observer.disconnect();
    }, []);
    return [ref, size];
}

/** Tracks a CSS media query. */
export function useMediaQuery(query: string): boolean {
    const [matches, setMatches] = useState(() => typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(query).matches);
    useEffect(() => {
        if (typeof window.matchMedia !== "function") return;
        const list = window.matchMedia(query);
        const onChange = () => setMatches(list.matches);
        list.addEventListener("change", onChange);
        return () => list.removeEventListener("change", onChange);
    }, [query]);
    return matches;
}

const AGENT_SURFACE_KEY = "dbhub-insights.agent-surface.v1";
const agentSurfaceListeners = new Set<() => void>();
// Used only when the frame blocks storage, so the choice still holds for this session.
let agentSurfaceInMemory: AgentSurface = "hub";

function readAgentSurface(): AgentSurface {
    try {
        const saved = window.localStorage.getItem(AGENT_SURFACE_KEY);
        if (saved === "hub" || saved === "skills") return saved;
    } catch {
        // Fall back to the in-memory choice.
    }
    return agentSurfaceInMemory;
}

function subscribeAgentSurface(listener: () => void): () => void {
    agentSurfaceListeners.add(listener);
    return () => agentSurfaceListeners.delete(listener);
}

/** Where the user asks: Database Hub's Database Agent or the skills fallback. Shared by every prompt panel, remembered per browser. */
export function useAgentSurface(): [AgentSurface, (surface: AgentSurface) => void] {
    const surface = useSyncExternalStore(subscribeAgentSurface, readAgentSurface, () => "hub" as AgentSurface);
    const setSurface = useCallback((next: AgentSurface) => {
        try {
            window.localStorage.setItem(AGENT_SURFACE_KEY, next);
        } catch {
            agentSurfaceInMemory = next;
        }
        agentSurfaceListeners.forEach((listener) => listener());
    }, []);
    return [surface, setSurface];
}
