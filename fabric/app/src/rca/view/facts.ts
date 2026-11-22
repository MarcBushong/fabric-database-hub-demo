// What the Root cause view reads off an investigation's result (ADR 0031), apart from its components.

import { bothTimes } from "../time";
import { EXPLAINED_FAMILIES } from "../tools";
import type { InvestigationResult } from "../types";

export interface EpisodeFacts {
    key: string;
    target: string;
    signal: string;
    support: string;
    source: string;
    start: string;
    end: string | null;
    peak: string;
    text?: string;
}

/** The incident explain_incident explained: the first of its episodes. */
export function episodeOf(result: InvestigationResult): EpisodeFacts | null {
    const list = result.details?.episodes as EpisodeFacts[] | undefined;
    return list?.[0] ?? null;
}

/**
 * The incidents with the richest evidence first, as the Root cause view lists them and the postmortem explains them: the
 * capture's own (a blocking chain, the replica's stall), then the others the investigations explain (errors, throttling),
 * then the telemetry-only ones, each group in time order.
 */
export function incidentsByEvidence<E extends { family: string; source: string; start: string }>(episodes: readonly E[]): E[] {
    const rank = (e: E) => (e.source === "the RCA capture" ? 2 : EXPLAINED_FAMILIES.includes(e.family) ? 1 : 0);
    return [...episodes].sort((a, b) => rank(b) - rank(a) || a.start.localeCompare(b.start));
}

/**
 * What an incident list with no episode says, from find_incidents' own words: nothing abnormal only when every read was
 * whole, up to where a read stopped short otherwise, and what the detector found besides episodes (errors it counted).
 * The review of eb89acbb: the view said "Nothing abnormal in these minutes" of a list whose read had stopped short.
 */
export function emptyListNote(found: InvestigationResult, timeZone: string): string {
    return emptyListText(found, (at) => bothTimes(at, timeZone));
}

/** emptyListNote's words, with each time as `when` writes it: the postmortem writes UTC alone. */
export function emptyListText(found: InvestigationResult, when: (at: Date) => string): string {
    const details = found.details ?? {};
    if (details.nothingAbnormal === true) return "Nothing abnormal in these minutes: the detector found no episode.";
    const stop = typeof details.readStoppedAt === "string" ? when(new Date(details.readStoppedAt)) : null;
    const besides = found.findings.map((f) => f.title);
    if (besides.length === 0 && stop) return `Nothing abnormal up to ${stop}, where the read stopped: the detector found no episode there, and what came after it wasn't read.`;
    return `No episode ${stop ? `up to ${stop}, where the read stopped` : "in these minutes"}${besides.length ? `; besides episodes, the detector found: ${besides.join(" ")}` : "."}`;
}

/** One class of explain_errors' details.classes, as errors.ts writes it. */
export interface ErrorClassRow {
    class: string;
    title: string;
    count: number;
    targets: string[];
    first: string;
    last: string;
    intercepted?: number;
    top?: string;
    /** Set when some of its counts are of an interval whose length isn't known in these minutes. */
    endUnknown?: boolean;
    inIntervalOfUnknownLength?: { count: number; from: string; intervals: number };
    /** Its known counts' total, and their span when it has any. */
    known?: number;
    knownFirst?: string;
    knownLast?: string;
}

/**
 * The errors table's count and time for a class (the re-review of 087e096a). A class with counts of an interval whose length
 * isn't known shows them apart from its known counts, from that interval's start with its length unknown, never as an
 * instant ("15:00 to 15:00") or under the larger count alone. Known counts that end before that interval begins can't be in
 * it, so the class's count adds them, as errors.ts does.
 */
export function errorClassCells(c: ErrorClassRow, timeZone: string): { count: string; when: string } {
    const n = (value: number) => value.toLocaleString("en-US");
    const at = (text: string) => bothTimes(new Date(text), timeZone);
    const open = c.endUnknown ? c.inIntervalOfUnknownLength : undefined;
    if (!open) return { count: n(c.count), when: `${at(c.first)} to ${at(c.last)}` };
    const unknown = `${n(open.count)} in ${open.intervals > 1 ? `${open.intervals} intervals` : "an interval"} of unknown length`;
    const from = `from ${at(open.from)}, length unknown`;
    if (!c.known || !c.knownFirst || !c.knownLast) return { count: unknown, when: from };
    const counted = c.knownFirst === c.knownLast ? `at ${at(c.knownFirst)}` : `${at(c.knownFirst)} to ${at(c.knownLast)}`;
    if (new Date(c.knownLast).getTime() <= new Date(open.from).getTime()) {
        return { count: `${n(c.count)}: ${n(c.known)} counted, then ${unknown}`, when: `${counted}, then ${from}` };
    }
    // Known counts from before that interval's start can't all be in it (the re-review of 8b43102e), as the tools say.
    const some = new Date(c.knownFirst).getTime() < new Date(open.from).getTime() ? "some of " : "";
    return { count: `${unknown}, which may hold ${some}the ${n(c.known)} counted`, when: `${from}; counted ${counted}` };
}
