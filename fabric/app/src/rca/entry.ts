// The chat's entry points that stand in for the Asks the blind rule removed (ADR 0031, decision 7). Each hands the chat a
// time window and its targets, never a row of the answer key, and asks it to investigate them the way a DBA would, with
// the investigation tools. The pages offer them only when the history model has the RCA tables, since the tools come
// with them; without the tables, those cards have no Ask, as decision 7 left them.

import { NEWEST_MINUTES } from "./types";

export interface BlindScope {
    /** The card's title, as the chat sees it: a time, never a fault's name. By default, the window. */
    title?: string;
    from?: Date | null;
    to?: Date | null;
    targets?: readonly string[];
}

/** What a page's card hands the chat instead: no rows and no DAX, only the window, the targets, and the question. */
export interface BlindAsk {
    title: string;
    prompt: string;
    specs: [];
    table: null;
}

const utc = (d: Date) => `${d.toISOString().slice(0, 16).replace("T", " ")} UTC`;
/** A time as the tools take it, with its date, so the chat passes it on as written (the re-review of 817b81c). */
const iso = (d: Date) => `${d.toISOString().slice(0, 19)}Z`;
const windowed = (s: BlindScope): s is BlindScope & { from: Date; to: Date } => Boolean(s.from && s.to && s.to > s.from);
const span = (s: BlindScope) => (windowed(s) ? `from ${utc(s.from)} to ${utc(s.to)}` : `in the history's newest ${NEWEST_MINUTES} minutes`);
const call = (tool: string, s: BlindScope) => (windowed(s) ? `call ${tool} with from ${iso(s.from)} and to ${iso(s.to)}` : `call ${tool} for those minutes`);
const on = (s: BlindScope) => (s.targets?.length ? ` on ${s.targets.join(", ")}` : "");
const titleOf = (s: BlindScope) => s.title ?? (windowed(s) ? `${utc(s.from)} to ${utc(s.to)}` : `The history's newest ${NEWEST_MINUTES} minutes`) + on(s);
const ANSWER = "each with its root cause, its evidence and times, the recommendations with who approves each, the next steps, and what wasn't captured.";

/** A session's minutes, or any short window: triage first, then explain. */
export function triageAsk(s: BlindScope): BlindAsk {
    return { title: titleOf(s), specs: [], table: null, prompt: `Triage ContosoCare's databases ${span(s)}${on(s)}: ${call("triage_window", s)}, then explain the top incidents it finds with the investigation tools, ${ANSWER}` };
}

/** The incidents of the latest minutes, found from the signals rather than read from any list. */
export function findIncidentsAsk(s: BlindScope = {}): BlindAsk {
    return { title: titleOf(s), specs: [], table: null, prompt: `Find the incidents in ContosoCare's databases ${span(s)}${on(s)} from the signals themselves: ${call("find_incidents", s)}, then explain the top ones with explain_incident, ${ANSWER}` };
}
