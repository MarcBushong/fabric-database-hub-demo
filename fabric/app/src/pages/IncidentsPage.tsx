import { useCallback, useMemo, useState } from "react";
import { Button, Link } from "@fluentui/react-components";
import { Bot16Regular, CheckmarkCircle16Regular, DataBarVertical16Regular, Flash16Regular, Wrench16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { AgentCard, AgentDialog } from "@/components/AgentPrompts";
import { AskWhy } from "@/components/AskWhy";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { Insights } from "@/components/Insights";
import { KpiTile } from "@/components/KpiTile";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { beatFor, FAMILY_LABEL, toAgentBeats, toBins, toIncidents, toSessions, toTargetNames, toWaitBins, toWaitFlows, type AgentBeat, type Incident, type SessionRun } from "@/data/model";
import { agentLoopQuery, incidentSeriesQuery, incidentsQuery, incidentWaitsQuery, sessionsQuery, targetNamesQuery, waitsQuery, type ColumnSpec } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { binMinutes, hubUrlOf, incidentPrompts, olderThanRetention, TELEMETRY_RETENTION_DAYS, windowPhrase, type AgentSurface } from "@/lib/agent-prompts";
import { TARGETS } from "@/lib/estate";
import { formatDateTimeUtc, formatDayUtc, formatDuration, formatNumber, formatTimeUtc } from "@/lib/format";
import { compareIncident, familySignal, incidentInsight, incidentPadMinutes, incidentsOverview, waitFamilyInsight, type IncidentComparison } from "@/lib/insights";
import { PageHeader } from "@/shell/PageHeader";
import { ChartView } from "@/visuals/ChartView";
import { IncidentReplay } from "@/visuals/IncidentReplay";
import { spotlightRows } from "@/visuals/layout";

const SPOTLIGHT_COLUMNS: ColumnSpec[] = [
    { key: "category", label: "Wait category", kind: "text" },
    { key: "Before", label: "Before the window (s per bin)", kind: "seconds" },
    { key: "During", label: "During the window (s per bin)", kind: "seconds" },
];

interface IncidentRow extends Record<string, unknown> {
    key: string;
    start: Date;
    target: string;
    signal: string;
    source: string;
    scenario: string;
    durationMin: number;
    peak: string;
    verdict: string;
}

const LIST_COLUMNS: GridColumn<IncidentRow>[] = [
    { key: "start", label: "Start (UTC)", render: (r) => formatDateTimeUtc(r.start), sortValue: (r) => r.start.getTime() },
    { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} /> },
    { key: "signal", label: "Signal" },
    { key: "source", label: "Source" },
    { key: "scenario", label: "Scenario" },
    { key: "durationMin", label: "Duration", render: (r) => formatDuration(r.durationMin), sortValue: (r) => r.durationMin, numeric: true },
    { key: "peak", label: "Peak", numeric: true },
    { key: "verdict", label: "Expected-signal verdict", kind: "status" },
];

/** The incident windows on one row per target, across the period. */
function Timeline({ incidents, selected, onSelect }: { incidents: Incident[]; selected: Incident | null; onSelect: (key: string) => void }) {
    const t0 = Math.min(...incidents.map((i) => i.start.getTime()));
    const t1 = Math.max(...incidents.map((i) => i.end.getTime()));
    const pad = Math.max((t1 - t0) * 0.02, 30 * 60000);
    const from = t0 - pad;
    const span = Math.max(t1 + pad - from, 1);
    const targets = [...new Set(incidents.map((i) => i.target))].sort();
    return (
        <div className="timeline">
            {targets.map((t) => (
                <div key={t} className="timeline-row">
                    <TargetChip target={t} />
                    <div className="timeline-track">
                        {incidents
                            .filter((i) => i.target === t)
                            .map((i) => (
                                <button
                                    key={i.key}
                                    type="button"
                                    className="timeline-bar"
                                    aria-pressed={selected?.key === i.key}
                                    aria-label={`${i.label}, ${formatDateTimeUtc(i.start)}, ${formatDuration(i.durationMin)}`}
                                    title={`${i.label} · ${formatDateTimeUtc(i.start)} · ${formatDuration(i.durationMin)}`}
                                    onClick={() => onSelect(i.key)}
                                    style={{ left: `${((i.start.getTime() - from) / span) * 100}%`, width: `${Math.max(((i.end.getTime() - i.start.getTime()) / span) * 100, 0.8)}%`, background: TARGETS[i.target].color }}
                                />
                            ))}
                    </div>
                </div>
            ))}
            <div className="timeline-axis" aria-hidden="true">
                <span />
                <div>
                    <span>{formatDateTimeUtc(new Date(from))}</span>
                    <span>{formatDateTimeUtc(new Date(from + span))}</span>
                </div>
            </div>
        </div>
    );
}

/** The session's record of the documented response to an incident: its plan's beat on the same target, overlapping the window. */
function responseFor(incident: Incident, sessions: readonly SessionRun[]): SessionRun | null {
    const start = incident.start.getTime();
    const end = incident.end.getTime();
    return (
        sessions.find((s) => {
            if (!/respond|response|forces? the last good plan/i.test(s.message)) return false;
            if (s.target !== incident.target && s.target !== "") return false;
            const from = s.windowStart?.getTime() ?? s.requestedAt?.getTime() ?? null;
            const to = s.windowEnd?.getTime() ?? from;
            return from !== null && to !== null && from < end && to >= start;
        }) ?? null
    );
}
/** Detect, evidence, respond, verify: the Database Agent loop as the history shows it. */
function AgentLoop(props: { incident: Incident; comparison: IncidentComparison | null; after: number | null; beat: AgentBeat | null; response: SessionRun | null; hubUrl?: string }) {
    const { incident, comparison, after, beat, response } = props;
    const signal = familySignal(incident.family);
    const recovered = after !== null && comparison?.baseline !== null && comparison?.baseline !== undefined ? after <= comparison.baseline * 1.25 : null;
    const respond = beat?.respondAt
        ? `${beat.regressAt ? `The plan regressed at ${formatTimeUtc(beat.regressAt)} UTC; t` : "T"}he run forced the last good plan through Query Store at ${formatTimeUtc(beat.respondAt)} UTC, the documented response.`
        : response
          ? response.message
          : "The agent proposes; the documented response is the last good plan through Query Store (in a session, T3's Database Agent beat applies it by itself).";
    const verify =
        beat && beat.cpuBefore !== null && beat.cpuAfter !== null
            ? `T3's CPU fell from ${formatNumber(beat.cpuBefore, "percent")} before the response to ${formatNumber(beat.cpuAfter, "percent")} after it.`
            : after === null
              ? "No bins after the window yet."
              : `${formatNumber(after, signal.kind)} per bin after the window${comparison?.baseline !== null && comparison?.baseline !== undefined ? `, against ${formatNumber(comparison.baseline, signal.kind)} before it` : ""}.`;
    return (
        <ol className="agent-loop" aria-label="The Database Agent loop">
            <li>
                <strong>
                    <Flash16Regular aria-hidden={true} /> 1 · Detect
                </strong>
                <span>{`${incident.target} ${signal.label} peaked at ${formatNumber(comparison?.peak ?? incident.peakValue, signal.kind)} at ${formatTimeUtc(comparison?.peakAt ?? incident.start)} UTC.`}</span>
                <StatusBadge status={incident.verdict || "Warning"} short />
            </li>
            <li>
                <strong>
                    <DataBarVertical16Regular aria-hidden={true} /> 2 · Evidence
                </strong>
                <span>
                    {comparison?.ratio
                        ? `${comparison.ratio >= 10 ? Math.round(comparison.ratio) : comparison.ratio.toFixed(1)} times its baseline during the window; the replay and the waits below show what moved.`
                        : "The replay and the waits below show what moved during the window."}
                </span>
                {props.hubUrl && incident.target === "T3" ? (
                    <Link href={props.hubUrl} target="_blank" rel="noopener noreferrer">
                        The agent's issue in Database Hub
                    </Link>
                ) : null}
            </li>
            <li>
                <strong>
                    <Wrench16Regular aria-hidden={true} /> 3 · Respond
                </strong>
                <span>{respond}</span>
                {beat?.respondAt ? <StatusBadge status="Pass" short /> : response?.status ? <StatusBadge status={response.status} short /> : null}
            </li>
            <li>
                <strong>
                    <CheckmarkCircle16Regular aria-hidden={true} /> 4 · Verify
                </strong>
                <span>{verify}</span>
                {beat ? <StatusBadge status={beat.status} short /> : recovered === null ? null : <StatusBadge status={recovered ? "Pass" : "Warning"} short />}
            </li>
        </ol>
    );
}
export default function IncidentsPage() {
    const { filters, view, setView, runtime } = useApp();
    const [agentOpen, setAgentOpen] = useState(false);
    const listSpec = useMemo(() => (filters.targets.length ? incidentsQuery(filters) : null), [filters]);
    const flowSpec = useMemo(() => (filters.targets.length ? waitsQuery(filters) : null), [filters]);
    const namesSpec = useMemo(() => targetNamesQuery(), []);
    const sessionsSpec = useMemo(() => sessionsQuery(filters), [filters]);
    const beatsSpec = useMemo(() => (filters.targets.includes("T3") ? agentLoopQuery(filters) : null), [filters]);
    const list = useQuery(listSpec);
    const flowsState = useQuery(flowSpec);
    const namesState = useQuery(namesSpec);
    const sessionsState = useQuery(sessionsSpec);
    const beatsState = useQuery(beatsSpec);
    const incidents = useMemo(() => toIncidents(list.data?.rows ?? []), [list.data]);
    const flows = useMemo(() => toWaitFlows(flowsState.data?.rows ?? []), [flowsState.data]);
    const names = useMemo(() => toTargetNames(namesState.data?.rows ?? []), [namesState.data]);
    const sessions = useMemo(() => toSessions(sessionsState.data?.rows ?? []), [sessionsState.data]);
    const beats = useMemo(() => toAgentBeats(beatsState.data?.rows ?? []), [beatsState.data]);
    const selected = incidents.find((i) => i.key === view.incident) ?? incidents[0] ?? null;

    const range = useMemo(() => {
        if (!selected) return null;
        const pad = incidentPadMinutes(selected) * 60000;
        return { target: selected.target, start: new Date(selected.start.getTime() - pad), end: new Date(selected.end.getTime() + pad) };
    }, [selected]);
    const seriesSpec = useMemo(() => (range ? incidentSeriesQuery(range) : null), [range]);
    const spotSpec = useMemo(() => (range ? incidentWaitsQuery(range) : null), [range]);
    const series = useQuery(seriesSpec);
    const spot = useQuery(spotSpec);
    const bins = useMemo(() => (selected ? toBins(series.data?.rows ?? [], selected.target) : []), [series.data, selected]);
    const spotRows = useMemo(() => (selected ? spotlightRows(selected, toWaitBins(spot.data?.rows ?? []), incidentPadMinutes(selected)) : []), [spot.data, selected]);
    const comparison = useMemo(() => (selected && bins.length ? compareIncident(selected, bins) : null), [selected, bins]);
    const after = useMemo(() => {
        if (!selected || bins.length === 0) return null;
        const field = familySignal(selected.family).field;
        const values = bins.filter((b) => b.at >= selected.end).map((b) => b[field] as number | null).filter((v): v is number => v !== null);
        return values.length ? values.reduce((a, v) => a + v, 0) / values.length : null;
    }, [selected, bins]);
    const response = selected ? responseFor(selected, sessions) : null;
    const beat = selected ? beatFor(selected, beats) : null;

    const insights = useMemo(
        () => [selected ? incidentInsight(selected, comparison) : null, incidentsOverview(incidents), waitFamilyInsight(flows)].filter((x): x is NonNullable<typeof x> => x !== null),
        [selected, comparison, incidents, flows],
    );
    const onIndex = useCallback((i: number) => setView({ replay: i }), [setView]);
    const select = useCallback((key: string) => setView({ incident: key, replay: null }), [setView]);

    const rows: IncidentRow[] = incidents.map((i) => ({
        key: i.key,
        start: i.start,
        target: i.target,
        signal: FAMILY_LABEL[i.family] ?? i.family,
        source: i.source,
        scenario: i.scenario,
        durationMin: i.durationMin,
        peak: `${formatNumber(i.peakValue, "decimal")} ${i.peakUnit}`.trim(),
        verdict: i.verdict,
    }));

    const bin = binMinutes(bins);
    const buildPrompts = (surface: AgentSurface) => (selected ? incidentPrompts(selected, comparison, { names, resourceGroup: runtime.resourceGroup, binMinutes: bin }, surface) : []);
    const agentSubtitle = selected ? `${selected.label} ${windowPhrase(selected.start, selected.end)}` : undefined;
    const agentLead = "Ready-made prompts built from this window's numbers. Copy one into Database Hub's Database Agent, or ask the in-app Copilot.";
    const agentWarning =
        selected && olderThanRetention(selected.end)
            ? `This window ended more than ${TELEMETRY_RETENTION_DAYS} days ago. Database Hub keeps ${TELEMETRY_RETENTION_DAYS} days of telemetry or less, so the agent may not see it any more; this app's history still has it.`
            : null;
    const signal = selected ? familySignal(selected.family) : null;
    const spotChartRows = spotRows.map((r) => ({ category: r.category.replace(" (PAGEIOLATCH)", ""), Before: r.before, During: r.during }));

    return (
        <div className="page">
            <PageHeader title="Incidents" description="Every incident window in the period: when it happened, what moved, why, and what to do next. Replay one bin by bin." />

            {!list.loading && incidents.length === 0 ? (
                <EmptyState title="No incident window in this period">
                    <p>Run all in NB_DatabaseHub_Control runs the showcase's incidents on every target; NB_DatabaseHub_LiveActivity also records the incidents it detects in the telemetry.</p>
                </EmptyState>
            ) : (
                <>
                    <VisualCard
                        id="incidents.timeline"
                        className="span-12"
                        title="Timeline"
                        subtitle="Incident windows per target across the period. Select one to replay it."
                        specs={[listSpec]}
                        loading={list.loading}
                        error={list.error}
                        empty={!list.loading && incidents.length === 0}
                        table={list.data && listSpec ? { columns: listSpec.columns, rows: list.data.rows, caption: "Incident windows" } : null}
                        summary={`${incidents.length} incident windows.`}
                        askPrompt="Walk me through these incidents: which are related, and which matters most?"
                    >
                        {incidents.length > 0 ? <Timeline incidents={incidents} selected={selected} onSelect={select} /> : null}
                    </VisualCard>

                    {selected ? (
                        <section className="kpis span-12" aria-label="The selected incident">
                            <KpiTile label="Incident" value={`${selected.target} · ${FAMILY_LABEL[selected.family] ?? selected.family}`} sub={`${formatDayUtc(selected.start)} ${formatTimeUtc(selected.start)}–${formatTimeUtc(selected.end)} UTC · ${selected.source}`} status={selected.verdict || "Warning"} />
                            <KpiTile
                                label={`Peak ${signal?.label ?? ""}`}
                                value={formatNumber(comparison?.peak ?? selected.peakValue, signal?.kind ?? "decimal")}
                                sub={comparison?.peakAt ? `at ${formatTimeUtc(comparison.peakAt)} UTC` : selected.peakUnit}
                                status="Warning"
                                actions={
                                    signal ? (
                                        <AskWhy
                                            title={`${selected.label} incident`}
                                            visualId="incidents.selected"
                                            prompt={`Why did ${selected.target}'s ${signal.label} reach ${formatNumber(comparison?.peak ?? selected.peakValue, signal.kind)} ${windowPhrase(selected.start, selected.end)}${comparison?.baseline ? `, against a baseline of ${formatNumber(comparison.baseline, signal.kind)}` : ""}? What caused it, which sessions and queries were involved, and what should I change?`}
                                            anomaly={{ metric: signal.label, target: selected.target, at: (comparison?.peakAt ?? selected.start).toISOString(), value: comparison?.peak ?? selected.peakValue ?? undefined, baseline: comparison?.baseline ?? undefined, incidentKey: selected.key }}
                                            specs={[seriesSpec, spotSpec]}
                                            rows={series.data?.rows}
                                            columns={seriesSpec?.columns}
                                        />
                                    ) : undefined
                                }
                            />
                            <KpiTile label="Against its baseline" value={comparison?.ratio ? `${comparison.ratio >= 10 ? Math.round(comparison.ratio) : comparison.ratio.toFixed(1)}×` : "–"} sub={comparison?.baseline !== null && comparison?.baseline !== undefined ? `baseline ${formatNumber(comparison.baseline, comparison.kind)} per bin` : "No bins before the window"} />
                            <KpiTile label="Duration" value={formatDuration(selected.durationMin)} sub={selected.scenario ? `scenario ${selected.scenario}` : "detected in the telemetry"} />
                        </section>
                    ) : null}

                    {selected ? (
                        <VisualCard
                            id="incidents.replay"
                            className="span-12"
                            title={`Replay: ${selected.label}`}
                            subtitle={`Every signal on ${selected.target} bin by bin, with the window, its baseline, and its peak.`}
                            specs={[seriesSpec]}
                            loading={series.loading}
                            error={series.error}
                            empty={!series.loading && bins.length === 0}
                            emptyText={`No telemetry bins on ${selected.target} around this window.`}
                            table={series.data && seriesSpec ? { columns: seriesSpec.columns, rows: series.data.rows, caption: `Every bin on ${selected.target} around the incident window` } : null}
                            summary={comparison ? `${selected.target} ${comparison.signal}: baseline ${comparison.baseline ?? "none"}, peak ${comparison.peak ?? "none"} per bin during the window.` : `Replay of ${selected.label}.`}
                            fetchedAt={series.data?.fetchedAt}
                            onRefresh={series.refetch}
                            askPrompt={`Replay this ${selected.target} incident for me: what happened first, what followed, and what caused it?`}
                            toolbar={
                                <Button size="small" appearance="subtle" icon={<Bot16Regular />} onClick={() => setAgentOpen(true)}>
                                    Ask the agent
                                </Button>
                            }
                        >
                            <IncidentReplay incident={selected} bins={bins} index={view.incident === selected.key ? view.replay : null} onIndex={onIndex} />
                        </VisualCard>
                    ) : null}

                    {selected ? (
                        <section className="panel span-12" aria-labelledby="loop-title">
                            <h3 id="loop-title">From signal to fix</h3>
                            <p className="panel-sub">The Database Agent's loop for this incident, from the history: what it detects, the evidence, the response a person applies, and whether it recovered.</p>
                            <AgentLoop incident={selected} comparison={comparison} after={after} beat={beat} response={response} hubUrl={hubUrlOf(runtime)} />
                        </section>
                    ) : null}

                    {selected ? (
                        <VisualCard
                            id="incidents.cause"
                            className="span-6"
                            title="What changed: waits before and during"
                            subtitle={`Wait seconds per bin by category on ${selected.target}, in the ${incidentPadMinutes(selected)} minutes before the window and inside it.`}
                            specs={[spotSpec]}
                            loading={spot.loading}
                            error={spot.error}
                            empty={!spot.loading && spotRows.length === 0}
                            emptyText="No wait categories around this window."
                            table={{ columns: SPOTLIGHT_COLUMNS, rows: spotChartRows, caption: "Wait seconds per bin, before and during the incident window" }}
                            summary={spotRows.map((r) => `${r.category}: ${r.before.toFixed(2)} s before, ${r.during.toFixed(2)} s during`).join("; ")}
                            askPrompt="Which wait category explains this incident, and what does it point to?"
                        >
                            <ChartView hideHeader height={240} spec={{ kind: "bar", title: "Waits before and during", rows: spotChartRows, x: "category", y: ["Before", "During"], unit: "s" }} colors={{ Before: "var(--colorNeutralStroke1)", During: TARGETS[selected.target].color }} />
                        </VisualCard>
                    ) : null}

                    <VisualCard
                        id="incidents.list"
                        className={selected ? "span-6" : "span-12"}
                        title="Every incident window"
                        subtitle="Sort, filter, and export; select a row to replay it."
                        specs={[listSpec]}
                        loading={list.loading}
                        error={list.error}
                        empty={!list.loading && rows.length === 0}
                        table={list.data && listSpec ? { columns: listSpec.columns, rows: list.data.rows, caption: "Incident windows" } : null}
                        summary={`${rows.length} incident windows.`}
                        quiet
                    >
                        <DataGrid columns={LIST_COLUMNS} rows={rows} caption="Incident windows" exportName="incident-windows" onRowClick={(r) => select(r.key)} rowLabel={(r) => `Replay ${r.target} ${r.signal}, ${formatDateTimeUtc(r.start)}`} />
                    </VisualCard>

                    {selected ? (
                        <AgentCard className="span-12" title="Investigate with the Database Agent" subtitle={agentSubtitle} lead={agentLead} warning={agentWarning} build={buildPrompts} visualId="incidents.agent" />
                    ) : null}

                    <Insights insights={insights} label="What the data says" page="incidents" />

                    <AgentDialog open={agentOpen && selected !== null} onClose={() => setAgentOpen(false)} title="Investigate with the Database Agent" subtitle={agentSubtitle} lead={agentLead} warning={agentWarning} build={buildPrompts} visualId="incidents.agent" />
                </>
            )}
        </div>
    );
}

