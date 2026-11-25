// The chat's explain_queries (ADR 0031; rca/README.md, Query Store): Query Store's evidence for one target and a time or
// window, from what the capture saved of it (the sidecar), with queries.ts's rules. tools.ts registers it beside the other
// investigations and gives it their window, episodes, and envelope; this file holds what's its own: its parameters, its
// arguments' checks, the minutes it reads (the hour before, for a baseline), and its answer.

import { BASELINE_MINUTES, QS_INTERVAL_MINUTES, QUERY_RANKS, analyzeQueries, notInHistoryYet, queryStoreOf, type QueryIncident, type QueryRank, type QueryStoreAnalysis, type QueryStoreDetails } from "./queries";
import { unexplainedByQuery } from "./query-store";
import { emptySidecar, type SidecarEvidence } from "./sidecar";
import type { SidecarTableKey } from "./spec";
import { dateTime, fromTo, hhmmss, isRcaTarget, RCA_TARGETS, type Episode, type InvestigationResult, type RcaTarget, type ResourcePoint } from "./types";

export const EXPLAIN_QUERIES = "explain_queries";

/** The sidecar's tables a Query Store answer reads: all but T4's connections. */
export const QUERY_STORE_TABLES: readonly SidecarTableKey[] = ["queryStats", "queryWaits", "queryPlans", "queryEvents", "queryCoverage"];

/** The ones a blocking chain's lock waits read (QS-LOCK-WAITS): the statistics, their waits, and the plans. */
export const LOCK_WAIT_TABLES: readonly SidecarTableKey[] = ["queryStats", "queryWaits", "queryPlans"];

/** The sidecar's rows of some minutes and targets, from the given tables (sources.ts's sidecar, through the history connector). */
export type SidecarRead = (from: Date, to: Date, targets: readonly RcaTarget[], tables?: readonly SidecarTableKey[]) => Promise<SidecarEvidence>;

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

/**
 * An incident's minutes for Query Store: from the sample before its first one at its level, since what raised it happened
 * after that sample (T3's new plan was compiled 49 s before its CPU incident's first busy minute), to its end.
 */
export function incidentMinutes(e: Pick<Episode, "start" | "end" | "readEnd" | "last">, sampleMs = 60_000): { from: Date; to: Date } {
    return { from: new Date(e.start.getTime() - sampleMs), to: e.end ?? e.readEnd ?? e.last };
}

/** A sidecar read that failed, said as such: never as no rows, which would read as a quiet Query Store. */
export function readFailure(target: RcaTarget, from: Date, to: Date, err: unknown): string {
    return `${target}: Query Store's evidence ${fromTo(from, to)} UTC couldn't be read, so nothing about those minutes' queries is concluded: ${err instanceof Error ? err.message : String(err)}`;
}

/**
 * Query Store's evidence for an incident the telemetry found (CPU, a wait class), from what the capture saved of it: queries.ts's
 * rules over the incident's minutes, with the incident itself; or why it couldn't be read. A read replica and T5 read nothing.
 */
export async function incidentQueries(e: Episode, read: SidecarRead, resource: readonly ResourcePoint[], now: Date): Promise<{ analysis: QueryStoreAnalysis } | { failed: string }> {
    const { from, to } = incidentMinutes(e);
    const kind = queryStoreOf(e.target);
    let sidecar = emptySidecar();
    if (kind === "sql" || kind === "postgresql") {
        const w = queryReadWindow(from, to);
        try {
            sidecar = await read(w.from, w.to, [e.target], QUERY_STORE_TABLES);
        } catch (err) {
            return { failed: readFailure(e.target, from, to, err) };
        }
    }
    return { analysis: analyzeQueries({ target: e.target, from, to, sidecar, resource, incident: { family: e.family, start: e.start, end: e.end, last: e.last }, now }) };
}

/** The last sentence of an incident's cause when Query Store's evidence names no query: why, about this history, never the target. */
export function unexplainedWords(e: Pick<Episode, "target">, a: QueryStoreAnalysis | null): string {
    if (!a) return "Which queries drove it isn't known: this history's Query Store evidence couldn't be read.";
    switch (a.details.recorded) {
        case "yes":
            return "Query Store's evidence in this history names no query behind it: explain_queries gives its top queries for those minutes.";
        case "pending":
            return "Which queries drove it isn't in this history yet: Query Store's minutes were pending publication when the capture read them.";
        case "no-rows":
            // No coverage row for those minutes: decision C (queries.ts's notInHistoryYet); with one, what it read held none.
            return a.details.state === null ? notInHistoryYet(e.target, "Which queries drove it") : "Which queries drove it isn't in this history: Query Store's evidence of those minutes holds no query.";
        case "model-missing":
            return "Which queries drove it isn't in this history: its model doesn't have Query Store's tables yet.";
        default:
            return unexplainedByQuery(e);
    }
}

export interface ExplainQueriesInput {
    args: QueryArgs;
    from: Date;
    to: Date;
    /** The investigations' envelope for the window and the target (tools.ts's): its window, episodes, and what wasn't captured. */
    base: InvestigationResult;
    /** The sidecar's rows of some minutes (loader.ts's loadSidecar, through the history connector). */
    sidecar: SidecarRead;
    /** The window's episodes and RCA Resource rows, which tools.ts gathered. */
    episodes: readonly Episode[];
    resource: readonly ResourcePoint[];
    now: Date;
}

/** explain_queries' answer: the envelope, with Query Store's findings, root cause, recommendations, next steps, and views (details). */
export async function explainQueries(input: ExplainQueriesInput): Promise<InvestigationResult & { details: QueryStoreDetails }> {
    const { args, from, to, base } = input;
    const read = queryReadWindow(from, to);
    const sidecar = await input.sidecar(read.from, read.to, [args.target], QUERY_STORE_TABLES);
    const a = analyzeQueries({ target: args.target, from, to, sidecar, resource: input.resource, incident: cpuIncidentIn(input.episodes, args.target, from, to), rankBy: args.rankBy, queryId: args.queryId, now: input.now });
    // A read at its limit holds only up to there, as the RCA tables' (tools.ts's envelope). The plans, read newest first in
    // reads of PLAN_QUERY_IDS queries, back to there: one line for them, from the latest such read's stop.
    const plansCut = (sidecar.cut ?? []).filter((c) => c.newestFirst);
    const cut = [
        ...(sidecar.cut ?? []).filter((c) => !c.newestFirst).map((c) => `${c.table}: the window holds more rows than one query returns, so what it holds from ${hhmmss(c.until)} UTC on wasn't read; ask about a narrower window`),
        ...(plansCut.length
            ? [`${plansCut[0].table}: these minutes' queries have more plan rows than one query returns, so ${plansCut.length > 1 ? "some of " : ""}the rows read before ${dateTime(new Date(Math.max(...plansCut.map((c) => c.until.getTime()))))} UTC weren't read; ask about a narrower window`]
            : []),
    ];
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
