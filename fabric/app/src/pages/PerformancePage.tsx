import { useMemo, useState } from "react";
import { Button, ToggleButton } from "@fluentui/react-components";
import { ArrowRight16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { Insights } from "@/components/Insights";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { FAMILY_LABEL, toBins, toIncidents, toWaitFlows, type Bin } from "@/data/model";
import { incidentsQuery, seriesQuery, waitsQuery, type ColumnSpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { useQuery } from "@/data/use-query";
import { TARGETS } from "@/lib/estate";
import { formatNumber, type NumberKind } from "@/lib/format";
import { busiestHourInsight, dominantWaitInsight, waitFamilyInsight } from "@/lib/insights";
import { quantile } from "@/lib/stats";
import { PageHeader } from "@/shell/PageHeader";
import { ChartView } from "@/visuals/ChartView";
import { Heatmap } from "@/visuals/Heatmap";

type SignalKey = "cpu" | "waitS" | "bufferIoS" | "lockWaitS" | "batch" | "sessions" | "blocked" | "ioMb";

const SIGNALS: Record<SignalKey, { label: string; unit: string; kind: NumberKind; combine: "sum" | "max" }> = {
    cpu: { label: "CPU", unit: "%", kind: "percent", combine: "max" },
    waitS: { label: "Wait time", unit: "s", kind: "seconds", combine: "sum" },
    bufferIoS: { label: "Buffer IO waits", unit: "s", kind: "seconds", combine: "sum" },
    lockWaitS: { label: "Lock waits", unit: "s", kind: "seconds", combine: "sum" },
    batch: { label: "Batch requests", unit: "count", kind: "int", combine: "sum" },
    sessions: { label: "Active sessions", unit: "count", kind: "int", combine: "max" },
    blocked: { label: "Blocked processes", unit: "count", kind: "int", combine: "max" },
    ioMb: { label: "Data and log IO", unit: "MB", kind: "mb", combine: "sum" },
};

interface DistRow extends Record<string, unknown> {
    target: string;
    bins: number;
    median: number | null;
    p95: number | null;
    max: number | null;
}

export default function PerformancePage() {
    const { filters, navigate, view } = useApp();
    const [signal, setSignal] = useState<SignalKey>("cpu");
    const info = SIGNALS[signal];
    const seriesSpec = useMemo(() => (filters.targets.length ? seriesQuery(filters) : null), [filters]);
    const waitsSpec = useMemo(() => (filters.targets.length ? waitsQuery(filters) : null), [filters]);
    const incidentsSpec = useMemo(() => (filters.targets.length ? incidentsQuery(filters) : null), [filters]);
    const series = useQuery(seriesSpec);
    const waits = useQuery(waitsSpec);
    const incidentsState = useQuery(incidentsSpec);
    const bins = useMemo(() => toBins(series.data?.rows ?? []), [series.data]);
    const flows = useMemo(() => toWaitFlows(waits.data?.rows ?? []), [waits.data]);
    const incidents = useMemo(() => toIncidents(incidentsState.data?.rows ?? []), [incidentsState.data]);

    const lineRows = useMemo(() => bins.map((b) => ({ at: b.at.toISOString(), target: b.target, value: b[signal as keyof Bin] as number | null })), [bins, signal]);
    const waitRows = useMemo(() => {
        const top = [...new Set([...flows].sort((a, b) => b.seconds - a.seconds).map((f) => f.category))].slice(0, 7);
        return flows.map((f) => ({ target: f.target, category: top.includes(f.category) ? f.category : "Other", seconds: f.seconds }));
    }, [flows]);
    const dist: DistRow[] = useMemo(
        () =>
            filters.targets.map((t) => {
                const values = bins
                    .filter((b) => b.target === t)
                    .map((b) => b[signal as keyof Bin] as number | null)
                    .filter((v): v is number => v !== null);
                return { target: t, bins: values.length, median: quantile(values, 0.5), p95: quantile(values, 0.95), max: values.length ? Math.max(...values) : null };
            }),
        [bins, signal, filters.targets],
    );
    const insights = useMemo(
        () => [dominantWaitInsight(flows), waitFamilyInsight(flows), busiestHourInsight(bins, signal === "batch" ? "batch" : signal === "sessions" ? "sessions" : "waitS")].filter((x): x is NonNullable<typeof x> => x !== null),
        [flows, bins, signal],
    );
    const bands = incidents.map((i) => ({ from: i.start, to: i.end, label: `${i.target} ${FAMILY_LABEL[i.family] ?? ""}`.trim() }));
    const distColumns: GridColumn<DistRow>[] = [
        { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} full /> },
        { key: "bins", label: "Bins", kind: "int" },
        { key: "median", label: "Median", numeric: true, render: (r) => formatNumber(r.median, info.kind) },
        { key: "p95", label: "95th percentile", numeric: true, render: (r) => formatNumber(r.p95, info.kind) },
        { key: "max", label: "Peak", numeric: true, render: (r) => formatNumber(r.max, info.kind) },
    ];

    if (filters.targets.length === 0) {
        return (
            <div className="page">
                <PageHeader title="Performance" description="CPU, waits, and throughput per SQL target over the period." />
                <EmptyState title="No SQL target in the filter">
                    <p>The telemetry history covers T1, T2, and T3. T4's PostgreSQL metrics are on its Estate page.</p>
                    <Button appearance="primary" icon={<ArrowRight16Regular />} iconPosition="after" onClick={() => navigate("estate", { target: "T4" })}>
                        T4 · PostgreSQL
                    </Button>
                </EmptyState>
            </div>
        );
    }

    return (
        <div className="page">
            <PageHeader title="Performance" description="CPU, waits, and throughput per SQL target over the period; incident windows are shaded. T4's PostgreSQL metrics are on its Estate page." />

            <div className="signal-picker" role="group" aria-label="Signal">
                {(Object.keys(SIGNALS) as SignalKey[]).map((s) => (
                    <ToggleButton key={s} size="small" appearance="subtle" checked={signal === s} onClick={() => setSignal(s)}>
                        {SIGNALS[s].label}
                    </ToggleButton>
                ))}
            </div>

            <VisualCard
                id={`performance.${signal}`}
                title={`${info.label} per target`}
                subtitle={`${info.label} per telemetry bin; shaded windows are incidents.`}
                specs={[seriesSpec, incidentsSpec]}
                loading={series.loading}
                error={series.error}
                empty={!series.loading && bins.length === 0}
                emptyText="No telemetry bins in this period."
                table={seriesSpec && series.data ? { columns: seriesSpec.columns, rows: series.data.rows, caption: "Signals per bin and target" } : null}
                summary={dist.map((d) => `${d.target}: median ${formatNumber(d.median, info.kind)}, peak ${formatNumber(d.max, info.kind)}`).join("; ")}
                fetchedAt={series.data?.fetchedAt}
                onRefresh={series.refetch}
                askPrompt={`Compare ${info.label.toLowerCase()} across the targets in this period: which one stands out, when, and why?`}
            >
                <ChartView hideHeader height={280} spec={{ kind: "line", title: `${info.label} per target`, rows: lineRows, x: "at", y: "value", series: "target", unit: info.unit }} annotations={{ bands }} />
            </VisualCard>

            <VisualCard
                id="performance.waits"
                className="span-7"
                title="Where the wait time went"
                subtitle="Wait seconds per target, split by the biggest categories."
                specs={[waitsSpec]}
                loading={waits.loading}
                error={waits.error}
                empty={!waits.loading && waitRows.length === 0}
                table={waitsSpec && waits.data ? { columns: waitsSpec.columns, rows: waits.data.rows, caption: "Wait seconds per category and target" } : null}
                summary={`${flows.length} category and target pairs.`}
                askPrompt="What does the wait profile say about each target's bottleneck, and what should I tune first?"
            >
                <ChartView hideHeader height={260} spec={{ kind: "stackedBar", title: "Waits per target", rows: waitRows, x: "target", y: "seconds", series: "category", unit: "s" }} />
            </VisualCard>

            <VisualCard
                id="performance.distribution"
                className="span-5"
                title="Distribution"
                subtitle={`Median, 95th percentile, and peak of ${info.label.toLowerCase()} per bin: a long tail is a spiky target.`}
                specs={[seriesSpec]}
                loading={series.loading}
                error={series.error}
                empty={!series.loading && bins.length === 0}
                table={{ columns: distColumns.map((c) => ({ key: c.key, label: c.label, kind: c.key === "target" ? "text" : c.key === "bins" ? "int" : "decimal" })) as ColumnSpec[], rows: dist as unknown as Row[], caption: `${info.label}: distribution per target` }}
                summary={`Distribution of ${info.label}.`}
                quiet
            >
                <DataGrid columns={distColumns} rows={dist} caption={`${info.label}: distribution per target`} exportName={`distribution-${signal}`} filterable={false} />
            </VisualCard>

            <VisualCard
                id="performance.heatmap"
                title="When the estate works"
                subtitle={`${info.label} by UTC hour of day and target over the period (${info.combine === "sum" ? "summed" : "peak"} per hour).`}
                specs={[seriesSpec]}
                loading={series.loading}
                error={series.error}
                empty={!series.loading && bins.length === 0}
                table={null}
                summary={`Heatmap of ${info.label} by hour.`}
                askPrompt="When is each target busiest, and does that match the expected workload?"
                quiet
            >
                <Heatmap bins={bins} targets={filters.targets} field={signal as keyof Bin} combine={info.combine} kind={info.kind} label={info.label} colors={Object.fromEntries(filters.targets.map((t) => [t, TARGETS[t].color]))} />
            </VisualCard>

            <Insights insights={insights} label="What the data says" page="performance" />
            {view.targets.includes("T4") ? (
                <section className="panel span-12">
                    <h3>PostgreSQL</h3>
                    <p className="panel-sub">T4's and its read replica's Azure Monitor metrics come from a session's capture, not from this telemetry.</p>
                    <div>
                        <Button icon={<ArrowRight16Regular />} iconPosition="after" onClick={() => navigate("estate", { target: "T4" })}>
                            T4 · PostgreSQL and its read replica
                        </Button>
                    </div>
                </section>
            ) : null}
        </div>
    );
}
