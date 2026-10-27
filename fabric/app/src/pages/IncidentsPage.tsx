import { useCallback, useMemo, useState } from "react";
import { Bot } from "lucide-react";

import { useApp } from "@/app-context";
import { AgentCard, AgentDialog } from "@/components/AgentPrompts";
import { InsightCards } from "@/components/InsightCards";
import { StatusBadge } from "@/components/StatusBadge";
import { VisualCard } from "@/components/VisualCard";
import { FAMILY_LABEL, toBins, toIncidents, toTargetNames, toWaitBins, toWaitFlows, type Incident } from "@/data/model";
import { incidentSeriesQuery, incidentsQuery, incidentWaitsQuery, targetNamesQuery, waitsQuery, type ColumnSpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { useQuery } from "@/data/use-query";
import { binMinutes, incidentPrompts, olderThanRetention, TELEMETRY_RETENTION_DAYS, windowPhrase, type AgentSurface } from "@/lib/agent-prompts";
import { formatDayUtc, formatDuration, formatTimeUtc } from "@/lib/format";
import { compareIncident, incidentInsight, incidentPadMinutes, incidentsOverview, waitFamilyInsight } from "@/lib/insights";
import type { WaitsView } from "@/lib/view-state";
import { IncidentReplay } from "@/visuals/IncidentReplay";
import { Spotlight } from "@/visuals/Spotlight";
import { spotlightRows } from "@/visuals/layout";
import { WaitFlowChart } from "@/visuals/WaitFlow";

const SPOTLIGHT_COLUMNS: ColumnSpec[] = [
    { key: "category", label: "Wait category", kind: "text" },
    { key: "before", label: "Before the window (s per bin)", kind: "seconds" },
    { key: "during", label: "During the window (s per bin)", kind: "seconds" },
];

const TARGET_COLOR: Record<string, string> = { T1: "var(--t1)", T2: "var(--t2)", T3: "var(--t3)" };

function IncidentRibbon({ incidents, selected, onSelect, onAsk }: { incidents: Incident[]; selected: Incident | null; onSelect: (key: string) => void; onAsk: (key: string) => void }) {
    const t0 = Math.min(...incidents.map((i) => i.start.getTime()));
    const t1 = Math.max(...incidents.map((i) => i.end.getTime()));
    const span = Math.max(t1 - t0, 1);
    return (
        <div className="ribbon">
            <div className="ribbon-track" aria-hidden="true">
                {incidents.map((i) => (
                    <span
                        key={i.key}
                        className={`ribbon-bar${selected?.key === i.key ? " active" : ""}`}
                        style={{ left: `${((i.start.getTime() - t0) / span) * 100}%`, width: `${Math.max(((i.end.getTime() - i.start.getTime()) / span) * 100, 1.5)}%`, background: TARGET_COLOR[i.target] }}
                    />
                ))}
            </div>
            <div className="ribbon-list" role="group" aria-label="Incident windows, newest first">
                {incidents.map((i) => (
                    <span key={i.key} className="incident-item">
                        <button type="button" className="incident-pill" aria-pressed={selected?.key === i.key} onClick={() => onSelect(i.key)}>
                            <i style={{ background: TARGET_COLOR[i.target] }} aria-hidden="true" />
                            <strong>{i.target}</strong>
                            <span>{FAMILY_LABEL[i.family] ?? i.family}</span>
                            <span className="gate-muted">{`${formatDayUtc(i.start)} ${formatTimeUtc(i.start)} · ${formatDuration(i.durationMin)}`}</span>
                        </button>
                        <button
                            type="button"
                            className="incident-ask"
                            aria-label={`Ask the Database Agent about ${i.label}, ${formatDayUtc(i.start)} ${formatTimeUtc(i.start)} UTC`}
                            title="Investigate with the Database Agent"
                            onClick={() => onAsk(i.key)}
                        >
                            <Bot aria-hidden="true" />
                        </button>
                    </span>
                ))}
            </div>
        </div>
    );
}

export default function IncidentsPage() {
    const { filters, view, setView, runtime } = useApp();
    const [agentOpen, setAgentOpen] = useState(false);
    const listSpec = useMemo(() => incidentsQuery(filters), [filters]);
    const flowSpec = useMemo(() => waitsQuery(filters), [filters]);
    const namesSpec = useMemo(() => targetNamesQuery(), []);
    const list = useQuery(listSpec);
    const flowsQuery = useQuery(flowSpec);
    const namesQuery = useQuery(namesSpec);
    const incidents = useMemo(() => toIncidents(list.data?.rows ?? []), [list.data]);
    const flows = useMemo(() => toWaitFlows(flowsQuery.data?.rows ?? []), [flowsQuery.data]);
    const names = useMemo(() => toTargetNames(namesQuery.data?.rows ?? []), [namesQuery.data]);
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

    const insights = useMemo(
        () => [selected ? incidentInsight(selected, comparison) : null, incidentsOverview(incidents), waitFamilyInsight(flows)].filter((x): x is NonNullable<typeof x> => x !== null),
        [selected, comparison, incidents, flows],
    );

    const onIndex = useCallback((i: number) => setView({ replay: i }), [setView]);
    const closeAgent = useCallback(() => setAgentOpen(false), []);
    const askAgent = useCallback(
        (key: string) => {
            if (key !== selected?.key) setView({ incident: key, replay: null });
            setAgentOpen(true);
        },
        [selected, setView],
    );

    const bin = useMemo(() => binMinutes(bins), [bins]);
    const buildPrompts = (surface: AgentSurface) => (selected ? incidentPrompts(selected, comparison, { names, resourceGroup: runtime.resourceGroup, binMinutes: bin }, surface) : []);
    const agentSubtitle = selected ? `${selected.label} ${windowPhrase(selected.start, selected.end)}` : undefined;
    const agentLead = "Ready-made prompts built from this window's numbers. Copy one, open Database Hub, and paste it into the Database Agent.";
    const agentWarning =
        selected && olderThanRetention(selected.end)
            ? `This window ended more than ${TELEMETRY_RETENTION_DAYS} days ago. Database Hub keeps ${TELEMETRY_RETENTION_DAYS} days of telemetry or less, so the agent may not see it any more; this app's history still has it.`
            : null;

    return (
        <div className="page">
            <header className="page-head">
                <div>
                    <h2>
                        <span className="gradient-text">Incidents</span>, replayed
                    </h2>
                    <p>
                        {incidents.length > 0
                            ? `${incidents.length} incident window${incidents.length === 1 ? "" : "s"} in this period. Pick one and press Play: every signal moves bin by bin, with the window, its baseline, and its peak.`
                            : "No incident window in this period. NB_DatabaseHub_LiveActivity records them from scenario requests and from signals it detects."}
                    </p>
                </div>
            </header>

            {incidents.length > 0 ? (
                <section className="card glass span-12" aria-label="Choose an incident">
                    <IncidentRibbon incidents={incidents} selected={selected} onSelect={(key) => setView({ incident: key, replay: null })} onAsk={askAgent} />
                </section>
            ) : null}

            <InsightCards insights={insights} label="Incident insights" />

            {selected ? (
                <VisualCard
                    className="span-12"
                    title={`Replay: ${selected.label}`}
                    subtitle={`${selected.source}${selected.scenario ? ` (${selected.scenario})` : ""} · ${formatDuration(selected.durationMin)} window · expected-signal verdict ${selected.verdict || "not recorded"}`}
                    specs={[seriesSpec]}
                    loading={series.loading}
                    error={series.error}
                    empty={!series.loading && bins.length === 0}
                    emptyText={`No telemetry bins on ${selected.target} around this window.`}
                    table={series.data && seriesSpec ? { columns: seriesSpec.columns, rows: series.data.rows, caption: `Every bin on ${selected.target} around the incident window` } : null}
                    summary={comparison ? `${selected.target} ${comparison.signal}: baseline ${comparison.baseline ?? "none"}, peak ${comparison.peak ?? "none"} per bin during the window.` : `Replay of ${selected.label}.`}
                    fetchedAt={series.data?.fetchedAt}
                    onRefresh={series.refetch}
                    toolbar={
                        <>
                            <button type="button" className="icon-btn agent-ask" onClick={() => setAgentOpen(true)} title="Investigate this window with the Database Agent">
                                <Bot aria-hidden="true" />
                                Ask the agent
                            </button>
                            <StatusBadge status={selected.verdict} short />
                        </>
                    }
                >
                    <IncidentReplay incident={selected} bins={bins} index={view.incident === selected.key ? view.replay : null} onIndex={onIndex} />
                </VisualCard>
            ) : null}

            {selected ? (
                <AgentCard
                    className="span-12"
                    title="Investigate with the Database Agent"
                    subtitle={agentSubtitle}
                    lead={agentLead}
                    warning={agentWarning}
                    build={buildPrompts}
                />
            ) : null}

            {selected ? (
                <VisualCard
                    className="span-6"
                    title="Before-and-after spotlight"
                    subtitle={`Wait time per bin by category on ${selected.target}: drag from the ${incidentPadMinutes(selected)} minutes before the window into the window itself.`}
                    specs={[spotSpec]}
                    loading={spot.loading}
                    error={spot.error}
                    empty={!spot.loading && spotRows.length === 0}
                    emptyText="No wait categories around this window."
                    table={{ columns: SPOTLIGHT_COLUMNS, rows: spotRows as unknown as Row[], caption: "Wait seconds per bin, before and during the incident window" }}
                    summary={spotRows.map((r) => `${r.category}: ${r.before.toFixed(2)} s before, ${r.during.toFixed(2)} s during`).join("; ")}
                    fetchedAt={spot.data?.fetchedAt}
                >
                    <Spotlight rows={spotRows} />
                </VisualCard>
            ) : null}

            <VisualCard
                className={selected ? "span-6" : "span-12"}
                title="Where the wait time went"
                subtitle="Wait families flow into categories and on to the targets that waited, for the whole period."
                specs={[flowSpec]}
                loading={flowsQuery.loading}
                error={flowsQuery.error}
                empty={!flowsQuery.loading && flows.length === 0}
                emptyText="No wait time in this period."
                table={flowsQuery.data ? { columns: flowSpec.columns, rows: flowsQuery.data.rows, caption: "Wait seconds per category and target" } : null}
                summary={`${flows.length} category and target pairs; ${Math.round(flows.reduce((a, f) => a + f.seconds, 0))} seconds of waits.`}
                fetchedAt={flowsQuery.data?.fetchedAt}
                toolbar={
                    <div className="segmented" role="group" aria-label="Chart type">
                        {(["sankey", "sunburst"] as WaitsView[]).map((v) => (
                            <button key={v} type="button" aria-pressed={view.waitsView === v} onClick={() => setView({ waitsView: v })}>
                                {v === "sankey" ? "Flow" : "Sunburst"}
                            </button>
                        ))}
                    </div>
                }
            >
                <WaitFlowChart flows={flows} view={view.waitsView} />
            </VisualCard>

            <AgentDialog
                open={agentOpen && selected !== null}
                onClose={closeAgent}
                title="Investigate with the Database Agent"
                subtitle={agentSubtitle}
                lead={agentLead}
                warning={agentWarning}
                build={buildPrompts}
            />
        </div>
    );
}
