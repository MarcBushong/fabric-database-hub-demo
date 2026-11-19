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
import type { QueryResult } from "@/data/query-client";
import { QueryClientContext, useQuery } from "@/data/use-query";
import { filterTargetOf } from "@/lib/estate";
import { cosmosHealth, postgresHealth, sqlHealth, type TargetHealth } from "@/lib/health";
import { cosmosEpisodes, episodesIn, postgresEpisodes, scorePlan, toPlans, type FaultScore, type MeasuredEpisode, type Plan } from "@/lib/scoreboard";
import { isEstateTarget, type FilterTarget } from "@/lib/view-state";

const MIN = 60000;

interface ListState {
    results: Array<QueryResult | undefined>;
    loading: boolean;
}

/** Runs a list of catalog queries, from the cache when it can; a query that fails counts as no rows. */
export function useQueryList(specs: readonly QuerySpec[]): ListState {
    const client = useContext(QueryClientContext);
    const key = specs.map((s) => `${s.id}\n${s.dax}`).join("\u0000");
    const [settled, setSettled] = useState<{ key: string; results: Array<QueryResult | undefined> } | null>(null);
    // `key` stands for the specs: their IDs and exact DAX text.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    const cached = useMemo(() => specs.map((s) => (client ? client.peek(s) : undefined)), [key, client]);
    const allCached = cached.every((c) => c !== undefined);
    useEffect(() => {
        if (!client || allCached) return;
        let cancelled = false;
        Promise.all(specs.map((s) => client.run(s).catch(() => undefined))).then((results) => {
            if (!cancelled) setSettled({ key, results });
        });
        return () => {
            cancelled = true;
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [key, client, allCached]);
    if (allCached) return { results: cached, loading: false };
    if (settled && settled.key === key) return { results: settled.results, loading: false };
    return { results: specs.map(() => undefined), loading: true };
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
    loading: boolean;
    /** The sessions query's failure: without it there's no plan. */
    error: Error | null;
    refetch: () => void;
}

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

    const runs = useMemo(() => toSessions(sessions.data?.rows ?? []).filter((r) => !r.profile.startsWith("incident:") || keepTarget(r.target, view.targets)), [sessions.data, view.targets]);
    const plans = useMemo(() => toPlans(runs), [runs]);
    const plan = plans.find((p) => p.key === view.session) ?? plans[0] ?? null;
    const shown = useMemo(() => {
        const list = plan ? [plan] : [];
        for (const p of plans.slice(0, others)) if (!list.includes(p)) list.push(p);
        return list;
    }, [plan, plans, others]);
    const waitSpecs = useMemo(() => waitSpecsFor(shown, filters.targets), [shown, filters.targets]);
    const waits = useQueryList(waitSpecs);

    const incidents = useMemo(() => toIncidents(incidentsState.data?.rows ?? []), [incidentsState.data]);
    const beats = useMemo(() => toAgentBeats(beatsState.data?.rows ?? []), [beatsState.data]);
    const plainBins = useMemo(() => toBins(series.data?.rows ?? []), [series.data]);
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

    const scored = useMemo(() => {
        const map = new Map<string, FaultScore[]>();
        if (waits.loading) return map;
        for (const p of shown) map.set(p.key, scorePlan(p, { bins, beats, runs, incidents }));
        return map;
    }, [shown, bins, beats, runs, incidents, waits.loading]);

    const postgres = useMemo(() => toPostgresCapture(pgSeries.data?.rows ?? []), [pgSeries.data]);
    const cosmos = useMemo(() => toCosmosCapture(cosmosSeriesState.data?.rows ?? []), [cosmosSeriesState.data]);
    const allEpisodes = useMemo(
        () =>
            [...(view.targets.includes("T5") ? cosmosEpisodes(cosmos, cosmosFindingsState.data?.rows ?? []) : []), ...(view.targets.includes("T4") ? postgresEpisodes(postgres) : [])].sort(
                (a, b) => a.visibleAt.getTime() - b.visibleAt.getTime(),
            ),
        [cosmos, cosmosFindingsState.data, postgres, view.targets],
    );
    const episodes = useMemo(() => (plan ? episodesIn(allEpisodes, plan) : []), [allEpisodes, plan]);
    const beat = useMemo(() => (plan ? (beats.find((b) => plan.faults.some((f) => f.requestId === b.requestId)) ?? null) : null), [beats, plan]);

    const health = useMemo(() => {
        const findings = toFindings(findingsState.data?.rows ?? []).filter((f) => !/^T\d/.test(f.target) || view.targets.some((t) => f.target === t || f.target.startsWith(`${t}-`)));
        const out = sqlHealth(toTargets(estate.data?.rows ?? []), findings, plainBins, view.targets);
        const cosmosRows = toCaptureFindings(cosmosFindingsState.data?.rows ?? []);
        if (view.targets.includes("T4")) out.push(postgresHealth(postgres, toPostgresFindings(pgFindings.data?.rows ?? [])));
        if (view.targets.includes("T5") && (cosmos || cosmosRows.length > 0)) out.push(cosmosHealth(cosmos, cosmosRows));
        return out;
    }, [findingsState.data, estate.data, plainBins, view.targets, postgres, pgFindings.data, cosmos, cosmosFindingsState.data]);

    const specs = useMemo(
        () => [sessionsSpec, seriesSpec, incidentsSpec, beatsSpec, ...waitSpecs, cosmosSeriesSpec, cosmosFindingsSpec, pgSeriesSpec].filter((s): s is QuerySpec => s !== null),
        [sessionsSpec, seriesSpec, incidentsSpec, beatsSpec, waitSpecs, cosmosSeriesSpec, cosmosFindingsSpec, pgSeriesSpec],
    );
    const { refetch: refetchSessions } = sessions;
    const { refetch: refetchSeries } = series;
    const refetch = useCallback(() => {
        refetchSessions();
        refetchSeries();
    }, [refetchSessions, refetchSeries]);

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
        loading: sessions.loading || series.loading || beatsState.loading || waits.loading,
        error: sessions.error ?? null,
        refetch,
    };
}
