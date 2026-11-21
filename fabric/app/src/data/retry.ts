// When a read of the history model is worth trying again, and how long to wait first. Power BI's Execute Queries allows
// each user 120 query requests a minute, whatever the model, and answers more with HTTP 429 and "Retry in N seconds"
// (https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries); a 5xx or a connection that failed passes by
// itself too. A read that still fails says nothing about the model, so it's never taken for an empty or older one (live,
// 2026-11-21: a throttled presence check made Root cause say that no RCA capture was recorded).

import { QueryFailure } from "./query-client";

export type TransientKind = "throttled" | "server" | "network";

export interface Transient {
    kind: TransientKind;
    /** What the service asked for ("Retry in 60 seconds"), when it said. */
    retryAfterMs: number | null;
}

const textOf = (err: unknown): string => (err instanceof Error ? err.message : String(err ?? ""));

const THROTTLED = /\b(?:HTTP|status(?: code)?)\s*429\b|too many requests|TooManyRequests|exceeded the amount of requests/i;
const SERVER = /\b(?:HTTP|status(?: code)?)\s*5\d\d\b|service unavailable|bad gateway|gateway time-?out|internal server error|temporarily unavailable/i;
const RETRY_AFTER = /retry (?:in|after) (\d+(?:\.\d+)?) ?s(?:ec(?:ond)?s?)?\b/i;

/** A failure worth trying again: throttled (429), a server error (5xx), or a connection that failed; null otherwise. */
export function transientOf(err: unknown): Transient | null {
    const text = textOf(err);
    const code = err instanceof QueryFailure ? (err.code ?? "") : "";
    const after = RETRY_AFTER.exec(text);
    const retryAfterMs = after ? Math.round(Number(after[1]) * 1000) : null;
    if (code === "429" || THROTTLED.test(text)) return { kind: "throttled", retryAfterMs };
    if (/^5\d\d$/.test(code) || SERVER.test(text)) return { kind: "server", retryAfterMs };
    if (err instanceof QueryFailure && err.category === "network") return { kind: "network", retryAfterMs: null };
    return null;
}

/**
 * The model answered that a table or a column the query names isn't in it: an older model, not a failed read. Live, on a
 * model from before the Incident RCA (2026-11-21): Execute Queries' 400 with "Query (1, 101) Cannot find table
 * '<oii>RCA Sessions</oii>'." The engine's other wordings for a name it doesn't know are matched too.
 */
export function isMissingInModel(err: unknown): boolean {
    if (transientOf(err)) return false;
    return /cannot find (?:table|column)|failed to resolve name|is not a valid table|(?:table|column) '[^']*'(?: in table '[^']*')? cannot be found/i.test(textOf(err));
}

/** What to tell the viewer after reads that failed, when each failure passes by itself: to try again in a minute, and
 *  why, when Power BI throttled one. Empty when one of them won't pass by waiting. */
export function retryHint(errors: readonly unknown[]): string {
    const kinds = errors.map(transientOf);
    if (kinds.length === 0 || kinds.some((k) => k === null)) return "";
    return kinds.some((k) => k?.kind === "throttled") ? "Try again in a minute: Power BI allows each viewer 120 queries a minute." : "Try again in a minute.";
}

export interface RetryOptions {
    /** Tries in all, the first one included. */
    attempts?: number;
    /** The first wait after a server error or a failed connection; each one after doubles it. */
    baseDelayMs?: number;
    /** The first wait after a 429 that doesn't say how long (Power BI's window is a minute); each one after doubles it. */
    throttleDelayMs?: number;
    /** The longest single wait, also when the service asks for longer. */
    maxDelayMs?: number;
    /** The most time spent waiting in all: a wait that would pass it isn't started, and the failure stands. */
    budgetMs?: number;
}

export const DEFAULT_RETRY: Required<RetryOptions> = { attempts: 4, baseDelayMs: 1000, throttleDelayMs: 10_000, maxDelayMs: 60_000, budgetMs: 90_000 };

/** The clock retries wait on; the tests replace it. */
export const retryClock = {
    sleep: (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms)),
    random: (): number => Math.random(),
};

/**
 * Runs a read, and again after a transient failure: after the time the service asked for, within maxDelayMs, or else
 * after a doubling backoff (from throttleDelayMs for a 429, baseDelayMs otherwise), each with up to a second of jitter,
 * so reads throttled together don't come back together. Gives up after `attempts` tries, or when the next wait would
 * pass `budgetMs`, with the last failure. A failure that isn't transient (the model refused the query, the viewer has no
 * access) fails at once.
 */
export async function withRetry<T>(read: () => Promise<T>, options: RetryOptions = {}): Promise<T> {
    const { attempts, baseDelayMs, throttleDelayMs, maxDelayMs, budgetMs } = { ...DEFAULT_RETRY, ...options };
    let waited = 0;
    for (let attempt = 1; ; attempt++) {
        try {
            return await read();
        } catch (err) {
            const transient = transientOf(err);
            if (!transient || attempt >= attempts) throw err;
            const first = transient.kind === "throttled" ? throttleDelayMs : baseDelayMs;
            const asked = transient.retryAfterMs ?? first * 2 ** (attempt - 1);
            const delay = Math.min(maxDelayMs, asked + Math.round(retryClock.random() * Math.min(1000, baseDelayMs)));
            if (waited + delay > budgetMs) throw err;
            await retryClock.sleep(delay);
            waited += delay;
        }
    }
}
