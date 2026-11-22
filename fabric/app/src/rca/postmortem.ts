// The postmortem's Cause from the blind investigation (ADR 0031, section 9): the incidents the detector finds in a
// session's minutes, in the Root cause view's order, and for each the root cause explain_incident gives, with its
// confidence and the rows it cites, or what wasn't captured, which says why it has none. Like the view, it reads only what
// the RCA capture, Database Hub's telemetry, and Azure Monitor recorded; the postmortem adds what the demo planned in a
// section of its own, labeled.

import type { RcaClient } from "./client";
import type { InvestigationTools } from "./tools";
import type { Confidence, InvestigationResult } from "./types";
import { emptyListText, incidentsByEvidence } from "./view/facts";

export interface BlindCause {
    key: string;
    target: string;
    signal: string;
    start: Date;
    /** Its end, confirmed; null when it was still on, or its data ended first. */
    end: Date | null;
    /** explain_incident's root cause; null when it has none, or couldn't be explained. */
    statement: string | null;
    confidence: Confidence | null;
    /** The rows its root cause cites, at most three: what, from which table, and when. */
    evidence: string[];
    /** The other causes in its minutes, at most two, as the view's "Also in these minutes". */
    also: string[];
    /** Without a root cause, what wasn't captured, which says why; with one, that its key read as another incident. */
    notes: string[];
    /** Why it couldn't be explained: a read that failed, never taken for no cause. */
    failed?: string;
}

export interface BlindCauses {
    /** The minutes investigated. */
    from: Date;
    to: Date;
    causes: BlindCause[];
    /** With no incident, what the list says instead: nothing abnormal, or only up to where a read stopped. */
    none?: string;
    /** The incidents past MAX_CAUSES, by target, which the postmortem leaves to the Root cause page. */
    more?: string;
    /** What wasn't captured in these minutes. */
    notCaptured: string[];
    /** The investigation's queries, each once: the postmortem lists them with its own. */
    queries: Array<{ title: string; dax: string }>;
    /** Why the investigation couldn't run at all. */
    error?: string;
}

type Listed = InvestigationResult["episodes"][number];

/** The most incidents a postmortem explains, in the view's order; the view lists them all. */
export const MAX_CAUSES = 6;

const message = (err: unknown) => (err instanceof Error ? err.message : String(err));
const utcTime = (iso: string) => `${iso.slice(11, 19)} UTC`;

/** One incident's cause, from explain_incident by its key. */
async function causeOf(tools: InvestigationTools, e: Listed): Promise<BlindCause> {
    const base: BlindCause = { key: e.key, target: e.target, signal: e.signal, start: new Date(e.start), end: e.end ? new Date(e.end) : null, statement: null, confidence: null, evidence: [], also: [], notes: [] };
    let answer: InvestigationResult | string;
    try {
        answer = await tools.investigate("explain_incident", { episodeKey: e.key });
    } catch (err) {
        return { ...base, failed: message(err) };
    }
    if (typeof answer === "string") return { ...base, failed: answer };
    const also = ((answer.details?.alsoInTheseMinutes as string[] | undefined) ?? []).slice(0, 2);
    const root = answer.rootCause;
    if (!root) return { ...base, also, notes: answer.notCaptured.slice(0, 4) };
    return {
        ...base,
        statement: root.statement,
        confidence: root.confidence,
        evidence: root.evidence.slice(0, 3).map((x) => `${x.text} (${x.table}${x.target === e.target ? "" : `, ${x.target}`}, ${utcTime(x.at)})`),
        also,
        // A key that reads as another incident in its own minutes says so (explain_incident's readAs).
        notes: answer.notCaptured.filter((line) => line.startsWith(`${e.key}:`)),
    };
}

/**
 * The incidents in the minutes from `from` to `to`, each with its blind root cause, in the Root cause view's order. A
 * read that failed is said as such, for one incident or for all, never as no cause or nothing abnormal. Once `signal`
 * aborts (the dialog closed), it explains no further incident, so it spends no more of the viewer's queries.
 */
export async function blindCauses(client: RcaClient, from: Date, to: Date, signal?: AbortSignal): Promise<BlindCauses> {
    client.drainLogs();
    const queries = () => {
        const seen = new Set<string>();
        const once = client.drainLogs().filter((log) => {
            if (seen.has(log.query)) return false;
            seen.add(log.query);
            return true;
        });
        return once.map((log) => ({ title: `Incident RCA: ${log.table}`, dax: log.query }));
    };
    let tools: InvestigationTools;
    let found: InvestigationResult | string;
    try {
        tools = await client.tools();
        found = await tools.investigate("find_incidents", { from: from.toISOString(), to: to.toISOString() });
    } catch (err) {
        return { from, to, causes: [], notCaptured: [], queries: queries(), error: message(err) };
    }
    if (typeof found === "string") return { from, to, causes: [], notCaptured: [], queries: queries(), error: found };
    const ordered = incidentsByEvidence(found.episodes);
    const top = ordered.slice(0, MAX_CAUSES);
    const causes: BlindCause[] = [];
    // One at a time: Execute Queries allows each viewer 120 queries a minute, and a throttled read is tried again.
    for (const e of top) {
        if (signal?.aborted) break;
        causes.push(await causeOf(tools, e));
    }
    const rest = ordered.slice(MAX_CAUSES);
    const byTarget = new Map<string, number>();
    for (const e of rest) byTarget.set(e.target, (byTarget.get(e.target) ?? 0) + 1);
    const counts = [...byTarget].sort(([a], [b]) => a.localeCompare(b)).map(([target, n]) => `${target} ${n}`);
    const more = rest.length > 0 ? `${rest.length} more incident${rest.length === 1 ? "" : "s"} in these minutes (${counts.join(", ")}), with less evidence: the Root cause page explains each.` : undefined;
    const none = ordered.length === 0 ? emptyListText(found, (at) => `${at.toISOString().slice(11, 16)} UTC`) : undefined;
    return { from, to, causes, ...(none ? { none } : {}), ...(more ? { more } : {}), notCaptured: [...new Set(found.notCaptured)], queries: queries() };
}
