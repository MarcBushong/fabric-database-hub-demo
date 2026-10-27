import { describe, expect, it } from "vitest";

import { DEFAULT_VIEW, isEmbedded, loadSavedView, mergeView, parseHash, saveView, toHash, windowRange } from "./view-state";

describe("view state", () => {
    it("round-trips every option through the hash", () => {
        const view = mergeView({ page: "incidents", targets: ["T1", "T3"], window: "30d", incident: "detected:T3:io:20261021T1015", replay: 4, ridgeSignal: "cpu", clockMetric: "batch", waitsView: "sunburst" });
        const hash = toHash(view);
        expect(hash).toBe("#/incidents?t=T1%2CT3&w=30d&i=detected%3AT3%3Aio%3A20261021T1015&r=4&s=cpu&c=batch&v=sunburst");
        expect(mergeView(parseHash(hash))).toEqual(view);
    });

    it("writes only what differs from the defaults", () => {
        expect(toHash(DEFAULT_VIEW)).toBe("#/estate");
    });

    it("drops unknown or unsafe values", () => {
        const parsed = parseHash("#/admin?t=T9,T2&w=1y&i=<script>&r=-3&s=memory&c=x&v=pie");
        expect(parsed).toEqual({ targets: ["T2"] });
    });

    it("anchors windows to the newest telemetry day, not to today", () => {
        const latest = new Date(Date.UTC(2026, 9, 21, 20, 15));
        expect(windowRange("day", latest)).toEqual({ from: new Date(Date.UTC(2026, 9, 21)), to: new Date(Date.UTC(2026, 9, 21)) });
        expect(windowRange("7d", latest)?.from).toEqual(new Date(Date.UTC(2026, 9, 15)));
        expect(windowRange("all", latest)).toBeNull();
        expect(windowRange("7d", null)).toBeNull();
    });

    it("remembers the view and survives storage that throws", () => {
        const store = new Map<string, string>();
        const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v) };
        saveView(storage, mergeView({ page: "readiness", window: "all" }));
        expect(loadSavedView(storage)).toEqual({ page: "readiness", window: "all" });
        const broken = {
            getItem: () => {
                throw new Error("blocked");
            },
            setItem: () => {
                throw new Error("blocked");
            },
        };
        expect(loadSavedView(broken)).toEqual({});
        expect(() => saveView(broken, DEFAULT_VIEW)).not.toThrow();
    });

    it("detects the portal frame", () => {
        const top = {} as Window;
        expect(isEmbedded({ self: top, top } as unknown as Window)).toBe(false);
        expect(isEmbedded({ self: {}, top } as unknown as Window)).toBe(true);
    });
});
