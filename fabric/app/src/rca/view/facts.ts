// What the Root cause view reads off an investigation's result (ADR 0031), apart from its components.

import { bothTimes } from "../time";
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
 * What an incident list with no episode says, from find_incidents' own words: nothing abnormal only when every read was
 * whole, up to where a read stopped short otherwise, and what the detector found besides episodes (errors it counted).
 * The review of eb89acbb: the view said "Nothing abnormal in these minutes" of a list whose read had stopped short.
 */
export function emptyListNote(found: InvestigationResult, timeZone: string): string {
    const details = found.details ?? {};
    if (details.nothingAbnormal === true) return "Nothing abnormal in these minutes: the detector found no episode.";
    const stop = typeof details.readStoppedAt === "string" ? bothTimes(new Date(details.readStoppedAt), timeZone) : null;
    const besides = found.findings.map((f) => f.title);
    if (besides.length === 0 && stop) return `Nothing abnormal up to ${stop}, where the read stopped: the detector found no episode there, and what came after it wasn't read.`;
    return `No episode ${stop ? `up to ${stop}, where the read stopped` : "in these minutes"}${besides.length ? `; besides episodes, the detector found: ${besides.join(" ")}` : "."}`;
}
