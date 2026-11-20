// Whether Database Hub refuses the app as a whole: every view of the live estate answered with `unavailable` (R924), as
// the pages read it. The pages and the dock read the live estate through one cache (estate.ts), which notes each answer
// here for the page's lifetime. While it's refused, a new conversation in the dock starts without the live view and
// hides its live starters; once any view answers, new conversations use the live view again. A single view's refusal
// isn't a whole one: that conversation stops calling the live view (tools.ts), and the others still try it.

import type { EstateView } from "../../rayfin/functions/src/estate-core";

const VIEWS: readonly EstateView[] = ["inventory", "health", "security"];
/** Each view's latest answer: its plain sentence when it was unavailable, null when it answered. */
const latest = new Map<EstateView, string | null>();
const listeners = new Set<() => void>();
let refused: string | null = null;

/**
 * Notes one view's answer. A view answered when it has data; an answer that has neither data nor `unavailable`
 * (Database Hub didn't answer just now: an outage, a timeout) changes nothing, as the next read may answer.
 */
export function noteLiveAnswer(view: EstateView, answer: { unavailable?: string; data?: unknown } | null | undefined): void {
    if (!answer) return;
    const sentence = typeof answer.unavailable === "string" && answer.unavailable.trim() ? answer.unavailable.trim() : null;
    const data = answer.data;
    const answered = typeof data === "object" && data !== null && Object.keys(data).length > 0;
    if (!sentence && !answered) return;
    latest.set(view, sentence);
    const next = VIEWS.every((v) => Boolean(latest.get(v))) ? (latest.get(VIEWS[0]) ?? null) : null;
    if (next === refused) return;
    refused = next;
    for (const listener of listeners) listener();
}

/** The function's plain sentence while Database Hub refuses the app as a whole (every view unavailable), else null. */
export function liveRefusedAsAWhole(): string | null {
    return refused;
}

export function onLiveRefusal(listener: () => void): () => void {
    listeners.add(listener);
    return () => {
        listeners.delete(listener);
    };
}

/** For tests: forgets every view's answer. */
export function forgetLiveAnswers(): void {
    latest.clear();
    if (refused === null) return;
    refused = null;
    for (const listener of listeners) listener();
}
