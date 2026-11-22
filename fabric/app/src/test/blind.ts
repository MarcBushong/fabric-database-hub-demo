// What in an Ask context would hand the chat the demo's answer key (ADR 0031): an answer-key table or a measure that reads
// one, a scenario's name, or what was injected. The tests that check every Ask is blind share it.

import { answerKeyIn } from "@/copilot/answer-key";
import type { AskContext } from "@/copilot/contract";
import { ANSWER_KEY_MEASURES } from "@/copilot/model-guide.generated";
import { namesAScenario } from "@/rca/testdata/contract";

/** What in a context would hand the chat the answer key, or null when it's blind. */
export function answerKeyInContext(ctx: AskContext): string | null {
    for (const [field, value] of Object.entries(ctx)) {
        const text = JSON.stringify(value);
        const named = answerKeyIn(text, ANSWER_KEY_MEASURES);
        if (named) return `${named} (in ${field})`;
        const scenarios = namesAScenario(text);
        if (scenarios.length > 0) return `scenario ${scenarios.join(", ")} (in ${field})`;
        if (/\binject/i.test(text)) return `what was injected (in ${field})`;
    }
    return null;
}

/** A fault's own minutes, from Scenario Runs: a lone incident request's, which no Ask may aim the chat at. */
export interface FaultMinutes {
    target: string;
    start: Date;
    end: Date;
}

const DAX_TIME = /DATE \( (\d+), (\d+), (\d+) \) \+ TIME \( (\d+), (\d+), (\d+) \)/g;
const ISO_TIME = /\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/g;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
/** formatDayUtc's "20 Oct", with the year and a clock time, as the postmortem writes it, or with none, as formatDateTimeUtc does. */
const DAY_TIME = new RegExp(`\\b(\\d{1,2}) (${MONTHS.join("|")})(?: (\\d{4}))? (\\d{2}):(\\d{2})\\b`, "g");
/** agent-prompts' "between 15:00 and 15:30 UTC on 2026-10-20": the clock times before " UTC on" a day. */
const ON_DAY = / UTC on (\d{4})-(\d{2})-(\d{2})\b/g;
const CLOCK = /\b(\d{2}):(\d{2})(?::(\d{2}))?\b/g;
/** The padding the app's own reads put around a plan's minutes: 30 minutes before, 45 after (use-mission's waits). */
const BEFORE = 30 * 60_000;
const AFTER = 45 * 60_000;

/**
 * Every time a text names, in the forms the app writes: ISO ("2026-10-20T15:00:00Z", "2026-10-20 15:00"), formatDayUtc's
 * "20 Oct 2026 15:00" (read in each fault's year when it has none), and "15:00 and 15:30 UTC on 2026-10-20" (the
 * re-review of ab1d2d41: the ISO form alone missed the postmortem's draft and agent-prompts' windowPhrase).
 */
function timesIn(text: string, years: readonly number[]): number[] {
    const out: number[] = [];
    for (const m of text.matchAll(ISO_TIME)) out.push(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)));
    for (const m of text.matchAll(DAY_TIME)) for (const year of m[3] ? [+m[3]] : years) out.push(Date.UTC(year, MONTHS.indexOf(m[2]), +m[1], +m[4], +m[5]));
    for (const m of text.matchAll(ON_DAY)) {
        // The clause before it: back to its sentence's start, at most 60 characters.
        const clause = text.slice(Math.max(0, (m.index ?? 0) - 60), m.index).split(/[.;!?\n]/).pop() ?? "";
        for (const c of clause.matchAll(CLOCK)) out.push(Date.UTC(+m[1], +m[2] - 1, +m[3], +c[1], +c[2], +(c[3] ?? 0)));
    }
    return out;
}

/**
 * A fault's minutes in a context (the re-review of ff5753e2): a query in its DAX that reads the fault's target over minutes
 * that reach into the fault's, with the padding the app puts around them, or a time in those minutes in its prompt or
 * title. Names alone don't show it: the window is the answer key's too.
 */
export function faultMinutesInContext(ctx: AskContext, faults: readonly FaultMinutes[]): string | null {
    const within = (at: number, f: FaultMinutes) => at >= f.start.getTime() - BEFORE && at <= f.end.getTime() + AFTER;
    for (const query of (ctx.dax ?? "").split(/\n\n(?=\/\/ )/)) {
        const times = [...query.matchAll(DAX_TIME)].map((m) => Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
        if (times.length === 0) continue;
        const from = Math.min(...times);
        const to = Math.max(...times);
        const filtered = /TREATAS \( \{ ([^}]*) \}, 'Target'\[Target Key\] \)/.exec(query);
        const targets = filtered ? [...filtered[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]) : null;
        for (const f of faults) {
            const reads = targets === null || targets.includes(f.target);
            if (reads && from <= f.end.getTime() + AFTER && to >= f.start.getTime() - BEFORE) return `${f.target}'s fault minutes in the DAX: ${query.split("\n")[0]}`;
        }
    }
    const years = [...new Set(faults.map((f) => f.start.getUTCFullYear()))];
    for (const field of ["prompt", "title"] as const) {
        for (const at of timesIn(ctx[field] ?? "", years)) {
            const hit = faults.find((f) => within(at, f));
            if (hit) return `${hit.target}'s fault minutes in the ${field}: ${new Date(at).toISOString()}`;
        }
    }
    return null;
}
