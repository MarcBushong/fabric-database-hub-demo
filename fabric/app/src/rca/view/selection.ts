// What the Root cause view opens (ADR 0031), kept in the app's address as its drill-down: a blind episode's key
// ("T1-blocking-20261120T165230Z"), or a target and a window ("T1.20261120T164500Z.20261120T171000Z") that another page
// links with. Never a fault's name: the links pass only a target and minutes.

import { RCA_TARGETS, type RcaTarget } from "../types";

export type RcaSelection = { kind: "episode"; key: string; target: RcaTarget } | { kind: "window"; target: RcaTarget; from: Date; to: Date };

const EPISODE = /^(T1|T2|T3|T4|T4-replica|T5)-([a-z_]+)-(\d{8}T\d{6}Z)$/;
const WINDOW = /^(T1|T2|T3|T4|T4-replica|T5)\.(\d{8}T\d{6}Z)\.(\d{8}T\d{6}Z)$/;

const compact = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
const fromCompact = (s: string) => new Date(`${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T${s.slice(9, 11)}:${s.slice(11, 13)}:${s.slice(13, 15)}Z`);

/** The drill-down for a target's minutes: what the Incidents page and the scoreboard link to the Root cause view with. */
export function windowKey(target: RcaTarget, from: Date, to: Date): string {
    return `${target}.${compact(from)}.${compact(to)}`;
}

export function parseSelection(text: string | null | undefined): RcaSelection | null {
    if (!text) return null;
    const episode = EPISODE.exec(text);
    if (episode) return { kind: "episode", key: text, target: episode[1] as RcaTarget };
    const window = WINDOW.exec(text);
    if (window && RCA_TARGETS.includes(window[1] as RcaTarget)) {
        const from = fromCompact(window[2]);
        const to = fromCompact(window[3]);
        if (Number.isFinite(from.getTime()) && Number.isFinite(to.getTime()) && to > from) return { kind: "window", target: window[1] as RcaTarget, from, to };
    }
    return null;
}
