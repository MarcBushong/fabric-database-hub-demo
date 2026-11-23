import { useMemo } from "react";
import { Button, MessageBar, MessageBarBody } from "@fluentui/react-components";

import { useApp } from "@/app-context";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { toDays } from "@/data/model";
import { dailyTrendQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { withoutColumns } from "@/lib/ask";
import { formatNumber } from "@/lib/format";
import { change, pct, weekOverWeek, type ChangeRow } from "@/lib/trends";
import { PageHeader } from "@/shell/PageHeader";
import { ChartView } from "@/visuals/ChartView";

const CHANGE_COLUMNS: GridColumn<ChangeRow>[] = [
    { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} full /> },
    { key: "cpuNow", label: "CPU avg, this week", numeric: true, render: (r) => formatNumber(r.cpuNow, "percent") },
    { key: "cpuChange", label: "vs the week before", numeric: true, render: (r) => change(r.cpuNow, r.cpuBefore), sortValue: (r) => pct(r.cpuNow, r.cpuBefore) },
    { key: "waitNow", label: "Wait time, this week", numeric: true, render: (r) => formatNumber(r.waitNow, "seconds") },
    { key: "waitChange", label: "vs the week before", numeric: true, render: (r) => change(r.waitNow, r.waitBefore), sortValue: (r) => pct(r.waitNow, r.waitBefore) },
    { key: "incidentsNow", label: "Incidents, this week", kind: "int" },
    { key: "incidentsBefore", label: "The week before", kind: "int" },
];

export default function TrendsPage() {
    const { filters, view, setView } = useApp();
    const spec = useMemo(() => (filters.targets.length ? dailyTrendQuery(filters) : null), [filters]);
    // Ask Copilot hands the chat the measured columns only: the incident windows per day are the demo's answer key (ADR 0031).
    const measuredSpec = useMemo(() => (filters.targets.length ? dailyTrendQuery(filters, { incidents: false }) : null), [filters]);
    const state = useQuery(spec);
    const days = useMemo(() => toDays(state.data?.rows ?? []), [state.data]);
    const changes = useMemo(() => weekOverWeek(days), [days]);
    const iso = (d: Date) => d.toISOString();
    const cpuRows = days.map((d) => ({ day: iso(d.day), target: d.target, value: d.cpuAvg }));
    const peakRows = days.map((d) => ({ day: iso(d.day), target: d.target, value: d.cpuPeak }));
    const waitRows = days.map((d) => ({ day: iso(d.day), target: d.target, value: d.waitS }));
    const incidentRows = days.map((d) => ({ day: iso(d.day), target: d.target, value: d.incidents }));
    const shortWindow = view.window === "day" || view.window === "7d";
    const common = {
        specs: [spec],
        loading: state.loading,
        error: state.error,
        empty: !state.loading && days.length === 0,
        emptyText: "No history in this period.",
        table: spec && state.data ? { columns: spec.columns, rows: state.data.rows, caption: "Daily history per target" } : null,
        fetchedAt: state.data?.fetchedAt,
    };
    const askMeasured = { specs: [measuredSpec], table: withoutColumns(common.table, ["Incidents"]) };

    return (
        <div className="page">
            <PageHeader title="Trends" description="Day by day, past the telemetry's 7 days: Database Hub keeps a week; the lakehouse keeps every session's history." />

            {shortWindow ? (
                <MessageBar intent="info">
                    <MessageBarBody>
                        Trends read best over a longer period.{" "}
                        <Button size="small" appearance="transparent" onClick={() => setView({ window: "30d" })}>
                            Show 30 days
                        </Button>
                        <Button size="small" appearance="transparent" onClick={() => setView({ window: "all" })}>
                            Show all history
                        </Button>
                    </MessageBarBody>
                </MessageBar>
            ) : null}

            {filters.targets.length === 0 ? (
                <EmptyState title="No SQL target in the filter">
                    <p>The daily history covers T1, T2, and T3.</p>
                </EmptyState>
            ) : (
                <>
                    <VisualCard id="trends.cpu" className="span-6" title="CPU, daily average" subtitle="Each target's average CPU per UTC day." summary="Daily average CPU per target." askPrompt="How has CPU trended across the targets, and is anything drifting?" {...common} ask={askMeasured}>
                        <ChartView hideHeader height={220} spec={{ kind: "line", title: "CPU, daily average", rows: cpuRows, x: "day", y: "value", series: "target", unit: "%" }} />
                    </VisualCard>
                    <VisualCard id="trends.cpupeak" className="span-6" title="CPU, daily peak" subtitle="Each target's highest CPU bin per UTC day." summary="Daily peak CPU per target." askPrompt="Which days had CPU peaks, and what was running then?" quiet {...common} ask={askMeasured}>
                        <ChartView hideHeader height={220} spec={{ kind: "line", title: "CPU, daily peak", rows: peakRows, x: "day", y: "value", series: "target", unit: "%" }} annotations={{ thresholds: [{ value: 80, label: "80 %", tone: "warning" }] }} />
                    </VisualCard>
                    <VisualCard id="trends.waits" className="span-6" title="Wait time per day" subtitle="Total wait seconds per target and UTC day." summary="Daily wait time per target." askPrompt="Is wait time growing anywhere? What's behind it?" quiet {...common} ask={askMeasured}>
                        <ChartView hideHeader height={220} spec={{ kind: "stackedBar", title: "Wait time per day", rows: waitRows, x: "day", y: "value", series: "target", unit: "s" }} />
                    </VisualCard>
                    <VisualCard id="trends.incidents" className="span-6" title="Incidents per day" subtitle="Incident windows per target and UTC day." summary="Daily incidents per target." quiet {...common} ask={false}>
                        <ChartView hideHeader height={220} spec={{ kind: "stackedBar", title: "Incidents per day", rows: incidentRows, x: "day", y: "value", series: "target", unit: "count" }} />
                    </VisualCard>
                    <VisualCard
                        id="trends.weekoverweek"
                        title="Week over week"
                        subtitle="The newest week against the week before it."
                        summary={changes.map((c) => `${c.target}: CPU ${change(c.cpuNow, c.cpuBefore)}, waits ${change(c.waitNow, c.waitBefore)}`).join("; ")}
                        askPrompt="What changed in my databases this week compared with last week?"
                        {...common}
                        ask={{
                            specs: [measuredSpec],
                            table: {
                                columns: [
                                    { key: "target", label: "Target", kind: "text" },
                                    { key: "cpuNow", label: "CPU avg, this week (%)", kind: "percent" },
                                    { key: "cpuBefore", label: "CPU avg, the week before (%)", kind: "percent" },
                                    { key: "waitNow", label: "Wait time, this week (s)", kind: "seconds" },
                                    { key: "waitBefore", label: "Wait time, the week before (s)", kind: "seconds" },
                                ],
                                rows: changes.map((c) => ({ target: c.target, cpuNow: c.cpuNow, cpuBefore: c.cpuBefore, waitNow: c.waitNow, waitBefore: c.waitBefore })),
                                caption: "Week over week",
                            },
                        }}
                        table={{ columns: [
                            { key: "target", label: "Target", kind: "text" },
                            { key: "cpuNow", label: "CPU avg, this week (%)", kind: "percent" },
                            { key: "cpuBefore", label: "CPU avg, the week before (%)", kind: "percent" },
                            { key: "waitNow", label: "Wait time, this week (s)", kind: "seconds" },
                            { key: "waitBefore", label: "Wait time, the week before (s)", kind: "seconds" },
                            { key: "incidentsNow", label: "Incidents, this week", kind: "int" },
                            { key: "incidentsBefore", label: "Incidents, the week before", kind: "int" },
                        ], rows: changes, caption: "Week over week" }}
                    >
                        <DataGrid columns={CHANGE_COLUMNS} rows={changes} caption="Week over week" exportName="week-over-week" filterable={false} />
                    </VisualCard>
                </>
            )}
        </div>
    );
}
