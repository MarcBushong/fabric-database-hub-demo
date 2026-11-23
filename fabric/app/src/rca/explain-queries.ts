// The chat's explain_queries (ADR 0031; rca/README.md, Query Store): Query Store's evidence for one target and a time or
// window, from what the capture saved of it (the sidecar), with queries.ts's rules. tools.ts registers it beside the other
// investigations and gives it their window, episodes, and envelope; this file holds what's its own: its parameters, its
// arguments' checks, the minutes it reads (the hour before, for a baseline), and its answer.

import { BASELINE_MINUTES, QS_INTERVAL_MINUTES, QUERY_RANKS, analyzeQueries, type QueryIncident, type QueryRank, type QueryStoreDetails } from "./queries";
import type { SidecarEvidence } from "./sidecar";
import { hhmmss, isRcaTarget, RCA_TARGETS, type Episode, type InvestigationResult, type RcaTarget, type ResourcePoint } from "./types";

export const EXPLAIN_QUERIES = "explain_queries";

/** Its description, before the investigations' common sentences (tools.ts adds them). */
export const EXPLAIN_QUERIES_DESCRIPTION =
    "Query Store's evidence for one target around a time or in a window, from what the capture saved of it in Query Store's 15-minute intervals: the top queries by CPU (on T4 by time: PostgreSQL's Query Store records no CPU time), duration, logical reads, waits, or executions, each with its share of the captured top queries and its change against the hour before; plan changes and regressions; plans forced by hand or by automatic plan correction, with their figures after; and Query Store's state. With queryId, that query's plans over the window and the hour before, with their shapes from their showplans. Every claim names its intervals; what the history doesn't hold says why (T4's last minutes pending publication, a read replica records nothing in Query Store, T5 has none), never that a target lacks Query Store. Call it for CPU and the wait classes, and for a blocking chain's statements.";

/** Its own parameters; tools.ts adds the window's (at, from, to, minutesBefore, minutesAfter). */
export const EXPLAIN_QUERIES_PROPS = {
    target: { type: "string", enum: RCA_TARGETS, description: "The target whose Query Store evidence to read." },
    queryId: { type: "string", pattern: "^-?[0-9]+$", description: "A query's Query Store ID, as a finding or an earlier answer gives it, in quotes: a 64-bit ID loses digits as a number. That query's plans and figures instead of the top queries." },
    rankBy: { type: "string", enum: QUERY_RANKS, description: "What the top queries are ranked by: cpu (the default; time on T4), duration, reads, waits, or executions." },
} as const;

export interface QueryArgs {
    target: RcaTarget;
    queryId?: string;
    rankBy: QueryRank;
}

/** Its arguments, or a message when one isn't what it takes, so the chat never reads a guess as an answer. */
export function queryArgs(args: Record<string, unknown>): QueryArgs | string {
    const target = args.target;
    if (!isRcaTarget(target)) return `target takes ${RCA_TARGETS.join(", ")}; ${JSON.stringify(target ?? null)} isn't one of them.`;
    let queryId: string | undefined;
    if (args.queryId !== undefined && args.queryId !== null) {
        if (typeof args.queryId === "string" && /^-?\d+$/.test(args.queryId.trim())) queryId = args.queryId.trim();
        else if (typeof args.queryId === "number" && Number.isSafeInteger(args.queryId)) queryId = String(args.queryId);
        else return `queryId takes a query's Query Store ID as its digits, in quotes; ${JSON.stringify(args.queryId)} isn't one (a 64-bit ID loses digits as a number).`;
    }
    const rankBy = (args.rankBy ?? "cpu") as QueryRank;
    if (!QUERY_RANKS.includes(rankBy)) return `rankBy takes ${QUERY_RANKS.join(", ")}; ${JSON.stringify(args.rankBy)} isn't one of them.`;
    return { target, ...(queryId ? { queryId } : {}), rankBy };
}

/** The minutes it reads for a window: the hour before and an interval more, for a baseline, and an interval after, for a forcing's figures after it. */
export function queryReadWindow(from: Date, to: Date, minutes = QS_INTERVAL_MINUTES): { from: Date; to: Date } {
    return { from: new Date(from.getTime() - (BASELINE_MINUTES + minutes) * 60_000), to: new Date(to.getTime() + minutes * 60_000) };
}

/** The CPU incident on the target in the window, earliest first: when its CPU rose times a new plan's first run (QS-PLAN-REGRESSION's confidence). */
export function cpuIncidentIn(episodes: readonly Episode[], target: RcaTarget, from: Date, to: Date): QueryIncident | undefined {
    const e = episodes.filter((x) => x.target === target && x.family === "cpu" && x.start <= to && (x.end ?? x.last) >= from).sort((a, b) => a.start.getTime() - b.start.getTime())[0];
    return e ? { family: e.family, start: e.start, end: e.end, last: e.last } : undefined;
}

export interface ExplainQueriesInput {
    args: QueryArgs;
    from: Date;
    to: Date;
    /** The investigations' envelope for the window and the target (tools.ts's): its window, episodes, and what wasn't captured. */
    base: InvestigationResult;
    /** The sidecar's rows of some minutes (loader.ts's loadSidecar, through the history connector). */
    sidecar: (from: Date, to: Date, targets: readonly RcaTarget[]) => Promise<SidecarEvidence>;
    /** The window's episodes and RCA Resource rows, which tools.ts gathered. */
    episodes: readonly Episode[];
    resource: readonly ResourcePoint[];
    now: Date;
}

/** explain_queries' answer: the envelope, with Query Store's findings, root cause, recommendations, next steps, and views (details). */
export async function explainQueries(input: ExplainQueriesInput): Promise<InvestigationResult & { details: QueryStoreDetails }> {
    const { args, from, to, base } = input;
    const read = queryReadWindow(from, to);
    const sidecar = await input.sidecar(read.from, read.to, [args.target]);
    const a = analyzeQueries({ target: args.target, from, to, sidecar, resource: input.resource, incident: cpuIncidentIn(input.episodes, args.target, from, to), rankBy: args.rankBy, queryId: args.queryId, now: input.now });
    // A read at its limit holds only up to there, as the RCA tables' (tools.ts's envelope).
    const cut = (sidecar.cut ?? []).map((c) => `${c.table}: the window holds more rows than one query returns, so what it holds from ${hhmmss(c.until)} UTC on wasn't read; ask about a narrower window`);
    const missingQuery = args.queryId && a.details.recorded === "yes" && a.details.top.length === 0 ? [`${args.target}: query ${args.queryId} isn't in Query Store's top lists in these minutes, as the capture read them.`] : [];
    return {
        ...base,
        tool: EXPLAIN_QUERIES,
        findings: a.findings,
        rootCause: a.rootCause,
        recommendations: a.recommendations,
        nextSteps: a.nextSteps,
        notCaptured: [...new Set([...base.notCaptured, ...a.notCaptured, ...missingQuery, ...cut])],
        // A literal's type has the index signature the envelope's details take, which an interface's doesn't.
        details: { ...a.details },
    };
}
