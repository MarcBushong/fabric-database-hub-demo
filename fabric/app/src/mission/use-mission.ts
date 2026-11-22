// The data behind Mission Control, the scoreboard, the replay, the kiosk, and the postmortem: the period's sessions and
// faults (Scenario Runs), the telemetry bins, the Database Agent beats, T4's and T5's latest captures, and each target's
// health, all through the catalog's own read-only queries, so they share the cache with Overview, Performance, and
// Incidents. The one addition is each shown session's wait categories per bin (the Incidents page's waits query, for the
// session's range), which the scoreboard needs for the wait-family faults.

import { useCallback, useContext, useEffect, useMemo, useState } from "react";

import { useApp } from "@/app-context";
import {
    toAgentBeats,
    toBins,
    toCaptureFindings,
    toCosmosCapture,
    toFindings,
    toIncidents,
    toPostgresCapture,
    toPostgresFindings,
    toSessions,
    toTargets,
    toWaitBins,
    withCategoryWaits,
    type AgentBeat,
    type Bin,
    type CosmosCapture,
    type PostgresCapture,
    type WaitBin,
} from "@/data/model";
import {
    agentLoopQuery,
    cosmosFindingsQuery,
    cosmosSeriesQuery,
    estateQuery,
    findingsQuery,
    incidentsQuery,
    incidentWaitsQuery,
    postgresFindingsQuery,
    postgresSeriesQuery,
    seriesQuery,
    sessionsQuery,
    type QuerySpec,
} from "@/data/queries";
import type { QueryResult, Row } from "@/data/query-client";
import { QueryClientContext, useQuery, type QueryState } from "@/data/use-query";
import { filterTargetOf } from "@/lib/estate";
import { cosmosHealth, postgresHealth, sqlHealth, type TargetHealth } from "@/lib/health";
import { cosmosEpisodes, episodesIn, postgresEpisodes, scorePlan, toPlans, type FaultScore, type MeasuredEpisode, type Plan } from "@/lib/scoreboard";
import { isEstateTarget, type FilterTarget } from "@/lib/view-state";

const MIN = 60000;

interface ListState {
    /** Each query's result: fresh, or, while a refresh runs or after one failed, the last that loaded. */
    results: Array<QueryResult | undefined>;
    /** Each query's failure, from its last run. */
    errors: Array<Error | undefined>;
    loading: boolean;
    refetch: () => void;
}

const NO_ERRORS: Array<Error | undefined> = [];

/** Runs a list of catalog queries, from the cache when it can, and keeps showing the last results while they run again. */
export function useQueryList(specs: readonly QuerySpec[]): ListState {
    const client = useContext(QueryClientContext);
    const key = specs.map((s) => `${s.id}\n${s.dax}`).join("\u0000");
    const [attempt, setAttempt] = useState(0);
    const [settled, setSettled] = useState<{ key: string; attempt: number; results: Array<QueryResult | undefined>; errors: Array<Error | undefined> } | null>(null);
    // `key` stands for the specs: their IDs and exact DAX text; `attempt` reads the cache again after a refetch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    const cached = useMemo(() => specs.map((s) => (client ? client.peek(s) : undefined)), [key, client, attempt]);
    const allCached = cached.every((c) => c !== undefined);
    useEffect(() => {
        if (!client || allCached) return;
        let cancelled = false;
        const runs = specs.map((s) =>
            client.run(s).then(
                (result) => ({ result, error: undefined }),
                (error: unknown) => ({ result: undefined, error: error instanceof Error ? error : new Error(String(error)) }),
            ),
        );
        Promise.all(runs).then((outcomes) => {
            if (!cancelled) setSettled({ key, attempt, results: outcomes.map((o) => o.result), errors: outcomes.map((o) => o.error) });
        });
        return () => {
            cancelled = true;
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [key, client, allCached, attempt]);
    const refetch = useCallback(() => setAttempt((n) => n + 1), []);
    const current = settled !== null && settled.key === key && settled.attempt === attempt;
    const results = useMemo(() => {
        if (allCached) return cached;
        const previous = settled && settled.key === key ? settled.results : [];
        return specs.map((s, i) => previous[i] ?? client?.peekStale?.(s));
        // `key` stands for the specs.
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [allCached, cached, settled, key, client]);
    return { results, errors: !allCached && current && settled ? settled.errors : NO_ERRORS, loading: !allCached && !current, refetch };
}

export interface MissionData {
    /** The sessions and lone incident requests in the period, newest first. */
    plans: Plan[];
    /** The session in focus: the view's, or the newest. */
    plan: Plan | null;
    /** Its faults, scored. */
    scores: FaultScore[];
    /** Every scored plan's faults: the plan in focus, and the newest others the page asked for. */
    scored: Map<string, FaultScore[]>;
    /** T4's and T5's episodes in the plan's window. */
    episodes: MeasuredEpisode[];
    /** T4's and T5's episodes in their whole latest captures. */
    allEpisodes: MeasuredEpisode[];
    /** The Database Agent beat in the plan, when it had one. */
    beat: AgentBeat | null;
    bins: Bin[];
    health: TargetHealth[];
    cosmos: CosmosCapture | null;
    postgres: PostgresCapture | null;
    /** The queries behind it, for the DAX, Ask Copilot, and the postmortem. */
    specs: QuerySpec[];
    /**
     * Its measured queries only, with no answer-key table or measure, and waits for the session in focus only, never a lone
     * incident request's minutes: what Ask Copilot hands the chat (ADR 0031).
     */
    askSpecs: QuerySpec[];
    loading: boolean;
    /** The sessions query's failure, with no sessions loaded before: without it there's no plan. */
    error: Error | null;
    /** Every other query that failed, each named with its reason: the page says so beside what it still shows, and the kiosk tries again. */
    loadError: Error | null;
    /** The telemetry bins couldn't load, and none had before: no fault is scored, rather than every fault "not visible". */
    scoreError: Error | null;
    /** The session the address asks for when the period's sessions don't have it: no other session is shown in its place. */
    missingSession: string | null;
    /** Runs again each query that failed. */
    refetch: () => void;
}

const NO_ROWS: readonly Row[] = [];

/** A query's rows: its fresh result, or the last that loaded while it refreshes or after a refresh failed; one empty list for none, so the memos below hold. */
const rowsOf = (state: QueryState): readonly Row[] => (state.data ?? state.stale)?.rows ?? NO_ROWS;

function keepTarget(target: string, selected: readonly FilterTarget[]): boolean {
    return isEstateTarget(target) && selected.includes(filterTargetOf(target));
}

/** Waits per category and bin for every SQL target with faults in each plan, over the plan's range. */
function waitSpecsFor(plans: readonly Plan[], selected: readonly FilterTarget[]): QuerySpec[] {
    const out: QuerySpec[] = [];
    for (const plan of plans) {
        for (const target of ["T1", "T2", "T3"] as const) {
            if (!selected.includes(target) || !plan.faults.some((f) => f.target === target)) continue;
            out.push(incidentWaitsQuery({ target, start: new Date(plan.start.getTime() - 30 * MIN), end: new Date(plan.end.getTime() + 45 * MIN) }));
        }
    }
    return out;
}

/**
 * The waits Ask Copilot hands the chat (ADR 0031, decision 7): the session in focus, over its own minutes, on every SQL
 * target in the filter, whatever it injected where. Never a lone incident request's minutes, which are its fault's own, nor
 * the other plans the scoreboard shows for its aggregates.
 */
function askWaitSpecsFor(plan: Plan | null, selected: readonly FilterTarget[]): QuerySpec[] {
    if (plan?.kind !== "session") return [];
    const start = new Date(plan.start.getTime() - 30 * MIN);
    const end = new Date(plan.end.getTime() + 45 * MIN);
    return (["T1", "T2", "T3"] as const).filter((target) => selected.includes(target)).map((target) => incidentWaitsQuery({ target, start, end }));
}

/** Everything the Wave 1 pages show, for the plan in focus and, for the scoreboard's aggregates, the newest `others` plans. */
export function useMission(others = 0): MissionData {
    const { filters, view } = useApp();
    const sql = filters.targets.length > 0;
    const sessionsSpec = useMemo(() => sessionsQuery(filters), [filters]);
    const incidentsSpec = useMemo(() => (sql ? incidentsQuery(filters) : null), [filters, sql]);
    const beatsSpec = useMemo(() => (filters.targets.includes("T3") ? agentLoopQuery(filters) : null), [filters]);
    const seriesSpec = useMemo(() => (sql ? seriesQuery(filters) : null), [filters, sql]);
    const estateSpec = useMemo(() => (sql ? estateQuery(filters) : null), [filters, sql]);
    const findingsSpec = useMemo(() => findingsQuery(filters), [filters]);
    const pgSeriesSpec = useMemo(() => (view.targets.includes("T4") ? postgresSeriesQuery() : null), [view.targets]);
    const pgFindingsSpec = useMemo(() => (view.targets.includes("T4") ? postgresFindingsQuery() : null), [view.targets]);
    const cosmosSeriesSpec = useMemo(() => (view.targets.includes("T5") ? cosmosSeriesQuery() : null), [view.targets]);
    const cosmosFindingsSpec = useMemo(() => (view.targets.includes("T5") ? cosmosFindingsQuery() : null), [view.targets]);

    const sessions = useQuery(sessionsSpec);
    const incidentsState = useQuery(incidentsSpec);
    const beatsState = useQuery(beatsSpec);
    const series = useQuery(seriesSpec);
    const estate = useQuery(estateSpec);
    const findingsState = useQuery(findingsSpec);
    const pgSeries = useQuery(pgSeriesSpec);
    const pgFindings = useQuery(pgFindingsSpec);
    const cosmosSeriesState = useQuery(cosmosSeriesSpec);
    const cosmosFindingsState = useQuery(cosmosFindingsSpec);

    const sessionRows = rowsOf(sessions);
    const incidentRows = rowsOf(incidentsState);
    const beatRows = rowsOf(beatsState);
    const seriesRows = rowsOf(series);
    const estateRows = rowsOf(estate);
    const findingRows = rowsOf(findingsState);
    const pgSeriesRows = rowsOf(pgSeries);
    const pgFindingRows = rowsOf(pgFindings);
    const cosmosSeriesRows = rowsOf(cosmosSeriesState);
    const cosmosFindingRows = rowsOf(cosmosFindingsState);

    const runs = useMemo(() => toSessions(sessionRows).filter((r) => !r.profile.startsWith("incident:") || keepTarget(r.target, view.targets)), [sessionRows, view.targets]);
    const plans = useMemo(() => toPlans(runs), [runs]);
    const sessionsLoaded = Boolean(sessions.data ?? sessions.stale);
    const requested = view.session ? (plans.find((p) => p.key === view.session) ?? null) : null;
    // A session the address asks for that isn't in this period (or doesn't exist) shows as missing, never as another one.
    const plan = view.session ? requested : (plans[0] ?? null);
    const missingSession = view.session && sessionsLoaded && !requested ? view.session : null;
    const shown = useMemo(() => {
        const list = plan ? [plan] : [];
        for (const p of plans.slice(0, others)) if (!list.includes(p)) list.push(p);
        return list;
    }, [plan, plans, others]);
    const waitSpecs = useMemo(() => waitSpecsFor(shown, filters.targets), [shown, filters.targets]);
    const waits = useQueryList(waitSpecs);

    const incidents = useMemo(() => toIncidents(incidentRows), [incidentRows]);
    const beats = useMemo(() => toAgentBeats(beatRows), [beatRows]);
    const plainBins = useMemo(() => toBins(seriesRows), [seriesRows]);
    const bins = useMemo(() => {
        const byTarget = new Map<string, WaitBin[]>();
        const seen = new Set<string>();
        waitSpecs.forEach((spec, i) => {
            const target = spec.id.replace(/^spotlight-/, "");
            const list = byTarget.get(target) ?? [];
            for (const w of toWaitBins(waits.results[i]?.rows ?? [])) {
                const key = `${target}|${w.at.getTime()}|${w.category}`;
                if (seen.has(key)) continue;
                seen.add(key);
                list.push(w);
            }
            byTarget.set(target, list);
        });
        return (["T1", "T2", "T3"] as const).flatMap((t) => withCategoryWaits(plainBins.filter((b) => b.target === t), byTarget.get(t) ?? []));
    }, [plainBins, waitSpecs, waits.results]);

    // Every fault's signal is read from the telemetry: while it first loads, and when it failed with none loaded before,
    // nothing is scored (the page says why), rather than every fault "not visible" for want of its bins.
    const scoreError = series.error && !series.stale ? series.error : null;
    const seriesPending = series.loading && !series.data;
    const waitsSettled = waits.results.every((r, i) => r !== undefined || waits.errors[i] !== undefined);
    const scored = useMemo(() => {
        const map = new Map<string, FaultScore[]>();
        if (!waitsSettled || seriesPending || scoreError) return map;
        for (const p of shown) map.set(p.key, scorePlan(p, { bins, beats, runs, incidents }));
        return map;
    }, [shown, bins, beats, runs, incidents, waitsSettled, seriesPending, scoreError]);

    const postgres = useMemo(() => toPostgresCapture(pgSeriesRows), [pgSeriesRows]);
    const cosmos = useMemo(() => toCosmosCapture(cosmosSeriesRows), [cosmosSeriesRows]);
    const allEpisodes = useMemo(
        () =>
            [...(view.targets.includes("T5") ? cosmosEpisodes(cosmos, cosmosFindingRows) : []), ...(view.targets.includes("T4") ? postgresEpisodes(postgres) : [])].sort(
                (a, b) => a.visibleAt.getTime() - b.visibleAt.getTime(),
            ),
        [cosmos, cosmosFindingRows, postgres, view.targets],
    );
    const episodes = useMemo(() => (plan ? episodesIn(allEpisodes, plan) : []), [allEpisodes, plan]);
    const beat = useMemo(() => (plan ? (beats.find((b) => plan.faults.some((f) => f.requestId === b.requestId)) ?? null) : null), [beats, plan]);

    const health = useMemo(() => {
        const findings = toFindings(findingRows).filter((f) => !/^T\d/.test(f.target) || view.targets.some((t) => f.target === t || f.target.startsWith(`${t}-`)));
        const out = sqlHealth(toTargets(estateRows), findings, plainBins, view.targets);
        const cosmosRows = toCaptureFindings(cosmosFindingRows);
        if (view.targets.includes("T4")) out.push(postgresHealth(postgres, toPostgresFindings(pgFindingRows)));
        if (view.targets.includes("T5") && (cosmos || cosmosRows.length > 0)) out.push(cosmosHealth(cosmos, cosmosRows));
        return out;
    }, [findingRows, estateRows, plainBins, view.targets, postgres, pgFindingRows, cosmos, cosmosFindingRows]);

    const specs = useMemo(
        () => [sessionsSpec, seriesSpec, incidentsSpec, beatsSpec, ...waitSpecs, cosmosSeriesSpec, cosmosFindingsSpec, pgSeriesSpec].filter((s): s is QuerySpec => s !== null),
        [sessionsSpec, seriesSpec, incidentsSpec, beatsSpec, waitSpecs, cosmosSeriesSpec, cosmosFindingsSpec, pgSeriesSpec],
    );
    const pgSeriesAskSpec = useMemo(() => (view.targets.includes("T4") ? postgresSeriesQuery({ measured: true }) : null), [view.targets]);
    const cosmosSeriesAskSpec = useMemo(() => (view.targets.includes("T5") ? cosmosSeriesQuery({ measured: true }) : null), [view.targets]);
    const askWaitSpecs = useMemo(() => askWaitSpecsFor(plan, filters.targets), [plan, filters.targets]);
    const askSpecs = useMemo(
        () => [seriesSpec, ...askWaitSpecs, pgSeriesAskSpec, cosmosSeriesAskSpec].filter((s): s is QuerySpec => s !== null),
        [seriesSpec, askWaitSpecs, pgSeriesAskSpec, cosmosSeriesAskSpec],
    );

    // The sessions query's failure with nothing loaded before leaves no plan (the page's empty state says it); every other
    // failure is named in loadError, beside what the page still shows, and refetch runs those queries again.
    const error = sessions.error && !sessions.stale ? sessions.error : null;
    const { refetch: retrySessions } = sessions;
    const { refetch: retrySeries } = series;
    const { refetch: retryWaits, errors: waitErrors } = waits;
    const failures = useMemo(() => {
        const list: Array<{ title: string; error: Error; retry: () => void }> = [];
        const add = (spec: QuerySpec | null, state: { error: Error | undefined; refetch: () => void }) => {
            if (spec && state.error) list.push({ title: spec.title, error: state.error, retry: state.refetch });
        };
        if (!error) add(sessionsSpec, sessions);
        add(seriesSpec, series);
        waitSpecs.forEach((spec, i) => add(spec, { error: waitErrors[i], refetch: retryWaits }));
        add(beatsSpec, beatsState);
        add(incidentsSpec, incidentsState);
        add(estateSpec, estate);
        add(findingsSpec, findingsState);
        add(pgSeriesSpec, pgSeries);
        add(pgFindingsSpec, pgFindings);
        add(cosmosSeriesSpec, cosmosSeriesState);
        add(cosmosFindingsSpec, cosmosFindingsState);
        return list;
        // Each state stands for its error and its refetch, which change only with the query's spec.
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [
        error,
        sessions.error,
        series.error,
        waitErrors,
        beatsState.error,
        incidentsState.error,
        estate.error,
        findingsState.error,
        pgSeries.error,
        pgFindings.error,
        cosmosSeriesState.error,
        cosmosFindingsState.error,
        sessionsSpec,
        seriesSpec,
        waitSpecs,
        beatsSpec,
        incidentsSpec,
        estateSpec,
        findingsSpec,
        pgSeriesSpec,
        pgFindingsSpec,
        cosmosSeriesSpec,
        cosmosFindingsSpec,
    ]);
    const loadError = useMemo(
        () => (failures.length ? new Error(`Some of the history didn't load, so this view may be incomplete: ${failures.map((f) => `${f.title} (${f.error.message.replace(/\.$/, "")})`).join("; ")}.`) : null),
        [failures],
    );
    const refetch = useCallback(() => {
        const retries = new Set(failures.map((f) => f.retry));
        if (error) retries.add(retrySessions);
        if (retries.size === 0) {
            retrySessions();
            retrySeries();
            return;
        }
        for (const retry of retries) retry();
    }, [failures, error, retrySessions, retrySeries]);

    return {
        plans,
        plan,
        scores: plan ? (scored.get(plan.key) ?? []) : [],
        scored,
        episodes,
        allEpisodes,
        beat,
        bins,
        health,
        cosmos,
        postgres,
        specs,
        askSpecs,
        loading: sessions.loading || series.loading || beatsState.loading || waits.loading,
        error,
        loadError,
        scoreError,
        missingSession,
        refetch,
    };
}
