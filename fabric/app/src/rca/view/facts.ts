// What the Root cause view reads off an investigation's result (ADR 0031), apart from its components.

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
