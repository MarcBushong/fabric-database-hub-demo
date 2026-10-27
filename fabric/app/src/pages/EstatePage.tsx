import { useMemo, useState } from "react";

import { useApp } from "@/app-context";
import { AgentCard } from "@/components/AgentPrompts";
import { InsightCards } from "@/components/InsightCards";
import { StatusBadge } from "@/components/StatusBadge";
import { VisualCard } from "@/components/VisualCard";
import { TARGET_INFO, toBins, toFindings, toTargetNames, toTargets, toWaitFlows } from "@/data/model";
import { estateQuery, findingsQuery, headlineQuery, seriesQuery, targetNamesQuery, waitsQuery, type ColumnSpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { useQuery } from "@/data/use-query";
import { libraryPrompts, type AgentSurface } from "@/lib/agent-prompts";
import type { TargetKey } from "@/lib/dax";
import { formatDateTimeUtc, formatNumber } from "@/lib/format";
import { busiestHourInsight, coverageInsight, dominantWaitInsight, freshnessInsight, lagInsight } from "@/lib/insights";
import { statusBySort } from "@/lib/status";
import type { ClockMetric, SignalId } from "@/lib/view-state";
import { ActivityClock } from "@/visuals/ActivityClock";
import { Constellation } from "@/visuals/Constellation";
import { CLOCK_METRICS, clockCells, constellationSummary, RIDGE_SIGNALS, ridges } from "@/visuals/layout";
import { Ridgeline } from "@/visuals/Ridgeline";

const CLOCK_COLUMNS: ColumnSpec[] = [
    { key: "target", label: "Target", kind: "text" },
    { key: "hour", label: "Hour (UTC)", kind: "int" },
    { key: "value", label: "Value", kind: "decimal" },
    { key: "bins", label: "Bins", kind: "int" },
];

const RIDGE_COLUMNS: ColumnSpec[] = [
    { key: "target", label: "Target", kind: "text" },
    { key: "bins", label: "Bins", kind: "int" },
    { key: "median", label: "Median", kind: "decimal" },
    { key: "p95", label: "95th percentile", kind: "decimal" },
];

export default function EstatePage() {
    const { filters, view, setView, meta, runtime } = useApp();
    const [selected, setSelected] = useState<TargetKey | null>(null);
    const estateSpec = useMemo(() => estateQuery(filters), [filters]);
    const seriesSpec = useMemo(() => seriesQuery(filters), [filters]);
    const findingsSpec = useMemo(() => findingsQuery(filters), [filters]);
    const waitsSpec = useMemo(() => waitsQuery(filters), [filters]);
    const headlineSpec = useMemo(() => headlineQuery(filters), [filters]);
    const namesSpec = useMemo(() => targetNamesQuery(), []);
    const estate = useQuery(estateSpec);
    const series = useQuery(seriesSpec);
    const findings = useQuery(findingsSpec);
    const waits = useQuery(waitsSpec);
    const headline = useQuery(headlineSpec);
    const namesQuery = useQuery(namesSpec);

    const targets = useMemo(() => toTargets(estate.data?.rows ?? []), [estate.data]);
    const bins = useMemo(() => toBins(series.data?.rows ?? []), [series.data]);
    const flows = useMemo(() => toWaitFlows(waits.data?.rows ?? []), [waits.data]);
    const names = useMemo(() => toTargetNames(namesQuery.data?.rows ?? []), [namesQuery.data]);
    const feed = useMemo(
        () => toFindings(findings.data?.rows ?? []).filter((f) => !/^T[123]$/.test(f.target) || filters.targets.includes(f.target as TargetKey)),
        [findings.data, filters.targets],
    );

    const insights = useMemo(
        () =>
            [coverageInsight(targets, filters.targets), lagInsight(targets), dominantWaitInsight(flows), busiestHourInsight(bins, CLOCK_METRICS[view.clockMetric].field), freshnessInsight(meta)].filter(
                (x): x is NonNullable<typeof x> => x !== null,
            ),
        [targets, filters.targets, flows, bins, view.clockMetric, meta],
    );

    const focusTarget = selected && targets.some((t) => t.key === selected) ? targets.find((t) => t.key === selected) ?? null : targets[0] ?? null;
    const focusWorst = focusTarget ? statusBySort(focusTarget.worstFindingSort) : null;
    const cells = useMemo(() => clockCells(bins, view.clockMetric, filters.targets), [bins, view.clockMetric, filters.targets]);
    const ridgeRows = useMemo(() => ridges(bins, view.ridgeSignal, filters.targets), [bins, view.ridgeSignal, filters.targets]);
    const headlineText = headline.data?.rows[0]?.EstateHeadline;

    return (
        <div className="page">
            <header className="page-head">
                <div>
                    <h2>
                        <span className="gradient-text">The estate</span>, at a glance
                    </h2>
                    <p>{typeof headlineText === "string" ? headlineText : "Three SQL targets, one history: what each reported and what needs attention."}</p>
                </div>
            </header>

            <InsightCards insights={insights} label="Estate insights" />

            <VisualCard
                className="span-8"
                title="Estate constellation"
                subtitle="Each target orbits the estate; satellites are its signals, sized by value. The halo takes the worst finding's status and pulses when it needs attention."
                specs={[estateSpec]}
                loading={estate.loading}
                error={estate.error}
                empty={!estate.loading && targets.length === 0}
                emptyText="No SQL target sent telemetry in this period. Choose a longer window or run NB_DatabaseHub_LiveActivity."
                table={estate.data ? { columns: estateSpec.columns, rows: estate.data.rows, caption: "Key signals per target in the selected period" } : null}
                summary={constellationSummary(targets)}
                fetchedAt={estate.data?.fetchedAt}
                onRefresh={estate.refetch}
            >
                <Constellation targets={targets} selected={focusTarget?.key ?? null} onSelect={setSelected} />
            </VisualCard>

            <section className="card glass span-4 target-detail" aria-live="polite" aria-label="Selected target">
                {focusTarget ? (
                    <>
                        <p className="eyebrow">Selected target</p>
                        <h3>{TARGET_INFO[focusTarget.key].name}</h3>
                        <p className="gate-muted">{focusTarget.platform}</p>
                        {focusWorst ? <StatusBadge status={focusWorst.name} /> : <span className="status status-muted">No findings in this period</span>}
                        <dl className="kv">
                            <dt>CPU, average · peak</dt>
                            <dd>{`${formatNumber(focusTarget.cpuAvg, "percent")} · ${formatNumber(focusTarget.cpuPeak, "percent")}`}</dd>
                            <dt>Wait time</dt>
                            <dd>{formatNumber(focusTarget.waitS, "seconds")}</dd>
                            <dt>Buffer IO waits</dt>
                            <dd>{formatNumber(focusTarget.bufferIoS, "seconds")}</dd>
                            <dt>Blocked processes, peak</dt>
                            <dd>{formatNumber(focusTarget.blockedPeak, "int")}</dd>
                            <dt>Active sessions, peak</dt>
                            <dd>{formatNumber(focusTarget.sessionsPeak, "int")}</dd>
                            <dt>Batch requests</dt>
                            <dd>{formatNumber(focusTarget.batch, "int")}</dd>
                            <dt>Telemetry lag at capture</dt>
                            <dd>{formatNumber(focusTarget.lagMin, "minutes")}</dd>
                            <dt>Telemetry tables (latest validation)</dt>
                            <dd>{formatNumber(focusTarget.coverageTables, "int")}</dd>
                            <dt>Incident windows</dt>
                            <dd>{formatNumber(focusTarget.incidents, "int")}</dd>
                        </dl>
                        {focusTarget.incidents > 0 ? (
                            <button type="button" className="btn-primary" onClick={() => setView({ page: "incidents", targets: [focusTarget.key], incident: null, replay: null })}>
                                Replay {focusTarget.key}'s incidents
                            </button>
                        ) : null}
                    </>
                ) : (
                    <p className="empty">Select a target in the constellation.</p>
                )}
            </section>

            <VisualCard
                className="span-5"
                title="Activity clock"
                subtitle="Twenty-four UTC hours around the dial, one ring per target: when the estate works, and who does the work."
                specs={[seriesSpec]}
                loading={series.loading}
                error={series.error}
                empty={!series.loading && bins.length === 0}
                emptyText="No telemetry bins in this period."
                table={{ columns: CLOCK_COLUMNS, rows: cells.filter((c) => c.bins > 0) as unknown as Row[], caption: `${CLOCK_METRICS[view.clockMetric].label} per target and UTC hour` }}
                summary={`Clock heatmap of ${CLOCK_METRICS[view.clockMetric].label.toLowerCase()} by UTC hour for ${filters.targets.join(", ")}.`}
                fetchedAt={series.data?.fetchedAt}
                toolbar={
                    <div className="segmented" role="group" aria-label="Clock measure">
                        {(Object.keys(CLOCK_METRICS) as ClockMetric[]).map((m) => (
                            <button key={m} type="button" aria-pressed={view.clockMetric === m} onClick={() => setView({ clockMetric: m })}>
                                {CLOCK_METRICS[m].label}
                            </button>
                        ))}
                    </div>
                }
            >
                <ActivityClock bins={bins} targets={filters.targets} metric={view.clockMetric} />
            </VisualCard>

            <VisualCard
                className="span-7"
                title="Signal distributions"
                subtitle="Ridgelines of every bin's value per target: a tall narrow ridge is a steady target, a long tail is a spiky one."
                specs={[seriesSpec]}
                loading={series.loading}
                error={series.error}
                empty={!series.loading && bins.length === 0}
                emptyText="No telemetry bins in this period."
                table={{ columns: RIDGE_COLUMNS, rows: ridgeRows.map((r) => ({ target: r.target, bins: r.values.length, median: r.median, p95: r.p95 })), caption: `${RIDGE_SIGNALS[view.ridgeSignal].label}: distribution per target` }}
                summary={ridgeRows.map((r) => `${r.target}: ${r.values.length} bins, median ${formatNumber(r.median, RIDGE_SIGNALS[view.ridgeSignal].kind)}`).join("; ")}
                fetchedAt={series.data?.fetchedAt}
                toolbar={
                    <label className="select">
                        <span className="sr-only">Signal</span>
                        <select value={view.ridgeSignal} onChange={(e) => setView({ ridgeSignal: e.target.value as SignalId })}>
                            {(Object.keys(RIDGE_SIGNALS) as SignalId[]).map((s) => (
                                <option key={s} value={s}>
                                    {RIDGE_SIGNALS[s].label}
                                </option>
                            ))}
                        </select>
                    </label>
                }
            >
                <Ridgeline bins={bins} targets={filters.targets} signal={view.ridgeSignal} />
            </VisualCard>

            <VisualCard
                className="span-12"
                title="What changed"
                subtitle="The latest capture of every finding in the period, worst first: the estate's change log from the notebooks."
                specs={[findingsSpec]}
                loading={findings.loading}
                error={findings.error}
                empty={!findings.loading && feed.length === 0}
                emptyText="No findings in this period."
                table={findings.data ? { columns: findingsSpec.columns, rows: findings.data.rows, caption: "Latest findings, worst first" } : null}
                summary={`${feed.length} findings; ${feed.filter((f) => f.statusSort <= 3).length} need attention.`}
                fetchedAt={findings.data?.fetchedAt}
                onRefresh={findings.refetch}
            >
                <ol className="feed">
                    {feed.map((f) => (
                        <li key={f.id} className={f.statusSort <= 3 ? "attention" : undefined}>
                            <StatusBadge status={f.status} short />
                            <span className="feed-target">{f.target}</span>
                            <span className="feed-text">
                                <strong>{f.analysis}</strong> {f.text}
                            </span>
                            <time>{formatDateTimeUtc(f.capturedAt)}</time>
                        </li>
                    ))}
                </ol>
            </VisualCard>

            <AgentCard
                className="span-12"
                title="Ask the Database Agent"
                subtitle="A prompt library for the estate: its health, the top waits per target, blocking chains, and what changed since the baseline."
                lead={`For ${filters.targets.join(", ")}, with the names the telemetry reported. Pick targets and a period above to change the prompts.`}
                build={(surface: AgentSurface) =>
                    libraryPrompts({ names, resourceGroup: runtime.resourceGroup, targets: filters.targets, period: filters.window, latestDay: meta?.latestDay ?? null }, surface)
                }
            />
        </div>
    );
}
