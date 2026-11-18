import { useMemo } from "react";
import { Button, Link } from "@fluentui/react-components";
import { ArrowRight16Regular, Open16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { AgentCard } from "@/components/AgentPrompts";
import { AskWhy } from "@/components/AskWhy";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { HealthTile } from "@/components/HealthTile";
import { KpiTile } from "@/components/KpiTile";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import {
    FAMILY_LABEL,
    POSTGRES_METRICS,
    postgresPeak,
    postgresSeries,
    postgresSkus,
    replicaCatchUp,
    toBins,
    toFindings,
    toIncidents,
    toPostgresCapture,
    toPostgresFindings,
    toTargetNames,
    toTargets,
    toWaitFlows,
    type PostgresCapture,
    type PostgresTarget,
} from "@/data/model";
import { estateQuery, findingsQuery, incidentsQuery, postgresFindingsQuery, postgresSeriesQuery, seriesQuery, targetNamesQuery, waitsQuery, type ColumnSpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { useQuery } from "@/data/use-query";
import { hubUrlOf, libraryPrompts, type AgentSurface } from "@/lib/agent-prompts";
import type { TargetKey } from "@/lib/dax";
import { ENGINES, engineOf, TARGETS } from "@/lib/estate";
import { formatAgo, formatDateTimeUtc, formatDuration, formatNumber } from "@/lib/format";
import { postgresHealth, sqlHealth, type TargetHealth } from "@/lib/health";
import { POSTGRES_CPU_WARNING_PERCENT, REPLICA_LAG_WARNING_SECONDS } from "@/lib/insights";
import type { EstateTarget } from "@/lib/view-state";
import { PageHeader } from "@/shell/PageHeader";
import { ChartView } from "@/visuals/ChartView";

const iso = (d: Date | null | undefined) => (d ? d.toISOString() : null);

interface InventoryRow extends Record<string, unknown> {
    target: EstateTarget;
    engine: string;
    platform: string;
    hosting: string;
    resource: string;
    status: string;
    cpuAvg: number | null;
    cpuPeak: number | null;
    waitS: number | null;
    sessionsPeak: number | null;
    incidents: number;
    attention: number;
    freshness: string;
}

const INVENTORY_COLUMNS: GridColumn<InventoryRow>[] = [
    { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} full /> },
    { key: "engine", label: "Engine" },
    { key: "hosting", label: "Runs on" },
    { key: "resource", label: "Resource" },
    { key: "status", label: "Status", kind: "status" },
    { key: "cpuAvg", label: "CPU avg", kind: "percent" },
    { key: "cpuPeak", label: "CPU peak", kind: "percent" },
    { key: "waitS", label: "Wait time", kind: "seconds" },
    { key: "sessionsPeak", label: "Sessions peak", kind: "int" },
    { key: "incidents", label: "Incidents", kind: "int" },
    { key: "attention", label: "Findings to review", kind: "int" },
    { key: "freshness", label: "Data" },
];

export default function EstatePage() {
    const { view } = useApp();
    return view.target ? <TargetDetail target={view.target} /> : <Inventory />;
}

function useEstateData() {
    const { filters, view } = useApp();
    const estateSpec = useMemo(() => (filters.targets.length ? estateQuery(filters) : null), [filters]);
    const seriesSpec = useMemo(() => (filters.targets.length ? seriesQuery(filters) : null), [filters]);
    const findingsSpec = useMemo(() => findingsQuery(filters), [filters]);
    const namesSpec = useMemo(() => targetNamesQuery(), []);
    const pgSeriesSpec = useMemo(() => (view.targets.includes("T4") ? postgresSeriesQuery() : null), [view.targets]);
    const pgFindingsSpec = useMemo(() => (view.targets.includes("T4") ? postgresFindingsQuery() : null), [view.targets]);
    const estate = useQuery(estateSpec);
    const series = useQuery(seriesSpec);
    const findingsState = useQuery(findingsSpec);
    const namesState = useQuery(namesSpec);
    const pgSeries = useQuery(pgSeriesSpec);
    const pgFindings = useQuery(pgFindingsSpec);
    const targets = useMemo(() => toTargets(estate.data?.rows ?? []), [estate.data]);
    const bins = useMemo(() => toBins(series.data?.rows ?? []), [series.data]);
    const findings = useMemo(() => toFindings(findingsState.data?.rows ?? []), [findingsState.data]);
    const names = useMemo(() => toTargetNames(namesState.data?.rows ?? []), [namesState.data]);
    const capture = useMemo(() => toPostgresCapture(pgSeries.data?.rows ?? []), [pgSeries.data]);
    const pgFindingRows = useMemo(() => toPostgresFindings(pgFindings.data?.rows ?? []), [pgFindings.data]);
    return { estateSpec, seriesSpec, findingsSpec, pgSeriesSpec, pgFindingsSpec, estate, series, findingsState, pgSeries, pgFindings, targets, bins, findings, names, capture, pgFindingRows };
}

function Inventory() {
    const { view, navigate } = useApp();
    const d = useEstateData();
    const health = useMemo(() => {
        const out: TargetHealth[] = sqlHealth(d.targets, d.findings, d.bins, view.targets);
        if (view.targets.includes("T4")) out.push(postgresHealth(d.capture, d.pgFindingRows));
        return out;
    }, [d.targets, d.findings, d.bins, view.targets, d.capture, d.pgFindingRows]);

    const rows: InventoryRow[] = useMemo(() => {
        const out: InventoryRow[] = [];
        for (const h of health) {
            const info = TARGETS[h.key];
            const t = d.targets.find((x) => x.key === h.key);
            const names = d.names[h.key as TargetKey];
            out.push({
                target: h.key,
                engine: engineOf(h.key).label,
                platform: info.platform,
                hosting: info.hosting,
                resource: h.key === "T4" ? (d.capture?.servers.T4 ?? "–") : (names?.resource ?? "–"),
                status: h.status ?? "",
                cpuAvg: t?.cpuAvg ?? null,
                cpuPeak: t?.cpuPeak ?? (h.key === "T4" ? postgresPeak(postgresSeries(d.capture, "T4", POSTGRES_METRICS.cpu))?.value ?? null : null),
                waitS: t?.waitS ?? null,
                sessionsPeak: t?.sessionsPeak ?? null,
                incidents: h.incidents,
                attention: h.attention,
                freshness: h.reporting ? "History" : "No data yet",
            });
            if (h.key === "T4" && d.capture?.servers["T4-replica"]) {
                const replica = TARGETS["T4-replica"];
                out.push({
                    target: "T4-replica",
                    engine: engineOf("T4-replica").label,
                    platform: replica.platform,
                    hosting: replica.hosting,
                    resource: d.capture.servers["T4-replica"] ?? "–",
                    status: d.pgFindingRows.find((f) => f.target === "T4-replica")?.status ?? "Pass",
                    cpuAvg: null,
                    cpuPeak: postgresPeak(postgresSeries(d.capture, "T4-replica", POSTGRES_METRICS.cpu))?.value ?? null,
                    waitS: null,
                    sessionsPeak: null,
                    incidents: 0,
                    attention: d.pgFindingRows.filter((f) => f.target === "T4-replica" && f.statusSort <= 3).length,
                    freshness: "History",
                });
            }
        }
        return out;
    }, [health, d.targets, d.names, d.capture, d.pgFindingRows]);

    const loading = d.estate.loading || d.pgSeries.loading;

    return (
        <div className="page">
            <PageHeader title="Estate" description="Every engine and target the demo runs: SQL Server on an Azure VM and through Azure Arc, Azure SQL Database, PostgreSQL with its read replica, and Azure Cosmos DB when present." />

            {ENGINES.map((engine) => {
                const tiles = health.filter((h) => engine.targets.includes(h.key));
                if (engine.id === "cosmosdb") {
                    return view.targets.includes("T5") ? (
                        <section key={engine.id} className="span-12" aria-label={engine.label}>
                            <h2 className="section-title">{engine.label}</h2>
                            <EmptyState compact title="T5 isn't in this estate's history yet">
                                <p>When the demo deploys Azure Cosmos DB as T5, its normalized RU consumption, throttled requests (429), and availability show here, saved like T4's metrics.</p>
                            </EmptyState>
                        </section>
                    ) : null;
                }
                if (tiles.length === 0) return null;
                return (
                    <section key={engine.id} className="span-12" aria-label={engine.label}>
                        <h2 className="section-title">{engine.label}</h2>
                        <div className="health">
                            {tiles.map((h) => (
                                <HealthTile key={h.key} health={h} onOpen={() => navigate("estate", { target: h.key })} />
                            ))}
                        </div>
                    </section>
                );
            })}

            <VisualCard
                id="estate.inventory"
                title="Inventory"
                subtitle="Every target with its engine, resource, status, and key numbers in the period. Select a row for its details."
                specs={[d.estateSpec, d.pgSeriesSpec]}
                loading={loading}
                error={d.estate.error}
                empty={!loading && rows.length === 0}
                emptyText="No target in this selection."
                table={{ columns: INVENTORY_COLUMNS.map((c) => ({ key: c.key, label: c.label, kind: c.kind ?? "text" })) as ColumnSpec[], rows: rows as unknown as Row[], caption: "Estate inventory" }}
                summary={`${rows.length} targets.`}
                askPrompt="Summarize the estate: which target is busiest, which needs attention, and why?"
            >
                <DataGrid columns={INVENTORY_COLUMNS} rows={rows} caption="Estate inventory" exportName="estate-inventory" onRowClick={(r) => navigate("estate", { target: r.target })} rowLabel={(r) => `Open ${r.target}`} filterable={false} />
            </VisualCard>
        </div>
    );
}

function TargetDetail({ target }: { target: EstateTarget }) {
    const { navigate } = useApp();
    const info = TARGETS[target];
    const engine = engineOf(target);
    const crumbs = [{ label: "Estate", onClick: () => navigate("estate") }, { label: engine.label, onClick: () => navigate("estate") }, { label: `${info.short} · ${info.name}` }];
    if (target === "T4" || target === "T4-replica") return <PostgresDetail crumbs={crumbs} focus={target} />;
    if (target === "T5") {
        return (
            <div className="page">
                <PageHeader title={`${info.short} · ${info.name}`} description={info.platform} crumbs={crumbs} filter={false} />
                <EmptyState title="No Cosmos DB history yet">
                    <p>When the demo deploys Azure Cosmos DB as T5, its normalized RU consumption, throttled requests (429), and availability show here.</p>
                </EmptyState>
            </div>
        );
    }
    return <SqlTargetDetail target={target} crumbs={crumbs} />;
}

function SqlTargetDetail({ target, crumbs }: { target: TargetKey; crumbs: Array<{ label: string; onClick?: () => void }> }) {
    const { navigate, filters, runtime, meta, view } = useApp();
    const info = TARGETS[target];
    const d = useEstateData();
    const incidentsSpec = useMemo(() => incidentsQuery({ ...filters, targets: [target] }), [filters, target]);
    const waitsSpec = useMemo(() => waitsQuery(filters), [filters]);
    const incidentsState = useQuery(incidentsSpec);
    const waitsState = useQuery(waitsSpec);
    const incidents = useMemo(() => toIncidents(incidentsState.data?.rows ?? []), [incidentsState.data]);
    const flows = useMemo(() => toWaitFlows(waitsState.data?.rows ?? []).filter((w) => w.target === target), [waitsState.data, target]);
    const t = d.targets.find((x) => x.key === target) ?? null;
    const mine = useMemo(() => d.bins.filter((b) => b.target === target), [d.bins, target]);
    const findings = d.findings.filter((f) => f.target === target);
    const names = d.names[target];
    const notSelected = !filters.targets.includes(target);

    const cpuRows = useMemo(() => mine.map((b) => ({ at: iso(b.at), CPU: b.cpu })), [mine]);
    const loadRows = useMemo(() => mine.map((b) => ({ at: iso(b.at), "Active sessions": b.sessions, "Blocked processes": b.blocked })), [mine]);
    const batchRows = useMemo(() => mine.map((b) => ({ at: iso(b.at), "Batch requests": b.batch })), [mine]);
    const waitRows = useMemo(() => [...flows].sort((a, b) => b.seconds - a.seconds).map((w) => ({ category: w.category, "Wait time": w.seconds })), [flows]);
    const bands = incidents.map((i) => ({ from: i.start, to: i.end, label: FAMILY_LABEL[i.family] ?? "Incident" }));
    const peak = mine.reduce<{ at: Date; value: number } | null>((p, b) => (b.cpu !== null && (!p || b.cpu > p.value) ? { at: b.at, value: b.cpu } : p), null);
    const median = (() => {
        const v = mine.map((b) => b.cpu).filter((x): x is number => x !== null).sort((a, b) => a - b);
        return v.length ? v[Math.floor(v.length / 2)] : null;
    })();

    if (notSelected) {
        return (
            <div className="page">
                <PageHeader title={`${info.short} · ${info.name}`} crumbs={crumbs} />
                <EmptyState title={`${target} isn't in the filter`} actions={<Button onClick={() => navigate("estate", { target, targets: [...new Set([...view.targets, target])] })}>Add {target} to the filter</Button>} />
            </div>
        );
    }

    return (
        <div className="page">
            <PageHeader
                title={`${info.short} · ${info.name}`}
                description={`${info.platform} · ${info.hosting}${names?.resource ? ` · ${names.resource}` : ""}${names?.database ? ` · database ${names.database}` : ""}`}
                crumbs={crumbs}
                actions={
                    <Button as="a" href={hubUrlOf(runtime)} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                        Database Hub, live
                    </Button>
                }
            />

            <section className="kpis" aria-label={`${target} at a glance`}>
                <KpiTile label="CPU, average · peak" value={`${formatNumber(t?.cpuAvg ?? null, "percent")}`} sub={`peak ${formatNumber(t?.cpuPeak ?? null, "percent")}${peak ? ` at ${formatDateTimeUtc(peak.at)}` : ""}`} status={t && (t.cpuPeak ?? 0) >= 80 ? "Warning" : t ? "Pass" : null} actions={
                    peak && median && peak.value >= 2 * median ? (
                        <AskWhy
                            title={`${target} CPU`}
                            visualId="estate.target.cpu"
                            prompt={`Why did ${target}'s CPU reach ${formatNumber(peak.value, "percent")} at ${formatDateTimeUtc(peak.at)} when its median in the period was ${formatNumber(median, "percent")}? Which queries drove it, and what should I change?`}
                            anomaly={{ metric: "CPU", target, at: peak.at.toISOString(), value: peak.value, baseline: median, unit: "%" }}
                            specs={[d.seriesSpec]}
                            rows={cpuRows}
                        />
                    ) : undefined
                } />
                <KpiTile label="Wait time" value={formatNumber(t?.waitS ?? null, "seconds")} sub={`Buffer IO ${formatNumber(t?.bufferIoS ?? null, "seconds")} · locks ${formatNumber(t?.lockWaitS ?? null, "seconds")}`} />
                <KpiTile label="Batch requests" value={formatNumber(t?.batch ?? null, "compact")} sub={`IO ${formatNumber(t?.ioMb ?? null, "mb")}`} />
                <KpiTile label="Active sessions, peak" value={formatNumber(t?.sessionsPeak ?? null, "int")} sub={`blocked peak ${formatNumber(t?.blockedPeak ?? null, "int")} · deadlocks ${formatNumber(t?.deadlocks ?? null, "int")}`} status={t && (t.blockedPeak ?? 0) > 0 ? "Warning" : null} />
                <KpiTile label="Incident windows" value={formatNumber(incidents.length, "int")} status={incidents.length > 0 ? "Warning" : "Pass"} onOpen={() => navigate("incidents", incidents[0] ? { incident: incidents[0].key } : {})} openLabel="Open its incidents" />
                <KpiTile label="Telemetry" value={t?.lagMin !== null && t?.lagMin !== undefined ? `${formatNumber(t.lagMin, "minutes")}` : "–"} sub={`${formatNumber(t?.coverageTables ?? null, "int")} tables · newest snapshot ${formatAgo(meta?.latestCapture ?? null)}`} />
            </section>

            <VisualCard
                id="estate.target.cpu"
                className="span-8"
                title="CPU"
                subtitle="Average CPU per bin over the period; shaded windows are the target's incidents."
                specs={[d.seriesSpec]}
                loading={d.series.loading}
                error={d.series.error}
                empty={!d.series.loading && mine.length === 0}
                emptyText={`No telemetry bins on ${target} in this period.`}
                table={d.seriesSpec && d.series.data ? { columns: d.seriesSpec.columns, rows: d.series.data.rows.filter((r) => r["Target Key"] === target), caption: `${target}'s bins` } : null}
                summary={`CPU on ${target}; peak ${formatNumber(peak?.value ?? null, "percent")}.`}
                askPrompt={`Explain ${target}'s CPU over this period: what drove the peaks, and is anything abnormal?`}
            >
                <ChartView
                    hideHeader
                    spec={{ kind: "area", title: `${target} CPU`, rows: cpuRows, x: "at", y: "CPU", unit: "%" }}
                    colors={{ CPU: info.color }}
                    annotations={{ bands, thresholds: [{ value: 80, label: "80 %", tone: "warning" }], markers: peak ? [{ x: peak.at, y: peak.value, label: `peak ${formatNumber(peak.value, "percent")}` }] : [] }}
                />
            </VisualCard>

            <VisualCard
                id="estate.target.waits"
                className="span-4"
                title="Where the wait time went"
                subtitle={`${target}'s wait time by category over the period.`}
                specs={[waitsSpec]}
                loading={waitsState.loading}
                error={waitsState.error}
                empty={!waitsState.loading && waitRows.length === 0}
                table={{ columns: [{ key: "category", label: "Wait category", kind: "text" }, { key: "Wait time", label: "Wait time (s)", kind: "seconds" }], rows: waitRows, caption: `${target}'s waits by category` }}
                summary={waitRows.slice(0, 3).map((w) => `${w.category} ${formatNumber(w["Wait time"], "seconds")}`).join("; ")}
                askPrompt={`What does ${target}'s wait profile say about its bottleneck, and what should I tune?`}
            >
                <ChartView hideHeader height={240} spec={{ kind: "bar", title: "Waits by category", rows: waitRows.slice(0, 8), x: "category", y: "Wait time", unit: "s" }} colors={{ "Wait time": info.color }} />
            </VisualCard>

            <VisualCard
                id="estate.target.sessions"
                className="span-6"
                title="Sessions and blocking"
                subtitle="Peak active sessions and blocked processes per bin."
                specs={[d.seriesSpec]}
                loading={d.series.loading}
                error={d.series.error}
                empty={!d.series.loading && mine.length === 0}
                table={{ columns: [{ key: "at", label: "Bin (UTC)", kind: "datetime" }, { key: "Active sessions", label: "Active sessions", kind: "int" }, { key: "Blocked processes", label: "Blocked processes", kind: "int" }], rows: loadRows, caption: `${target}'s sessions` }}
                summary={`Sessions and blocking on ${target}.`}
            >
                <ChartView hideHeader height={200} spec={{ kind: "line", title: "Sessions and blocking", rows: loadRows, x: "at", y: ["Active sessions", "Blocked processes"], unit: "count" }} annotations={{ bands }} />
            </VisualCard>

            <VisualCard
                id="estate.target.batch"
                className="span-6"
                title="Throughput"
                subtitle="Batch requests per bin."
                specs={[d.seriesSpec]}
                loading={d.series.loading}
                error={d.series.error}
                empty={!d.series.loading && mine.length === 0}
                table={{ columns: [{ key: "at", label: "Bin (UTC)", kind: "datetime" }, { key: "Batch requests", label: "Batch requests", kind: "int" }], rows: batchRows, caption: `${target}'s batch requests` }}
                summary={`Batch requests on ${target}.`}
            >
                <ChartView hideHeader height={200} spec={{ kind: "area", title: "Batch requests", rows: batchRows, x: "at", y: "Batch requests", unit: "count" }} colors={{ "Batch requests": info.color }} annotations={{ bands }} />
            </VisualCard>

            <VisualCard
                id="estate.target.incidents"
                className="span-6"
                title="Incidents"
                subtitle={`${target}'s incident windows in the period.`}
                specs={[incidentsSpec]}
                loading={incidentsState.loading}
                error={incidentsState.error}
                empty={!incidentsState.loading && incidents.length === 0}
                emptyText={`No incident window on ${target} in this period.`}
                table={incidentsState.data ? { columns: incidentsSpec.columns, rows: incidentsState.data.rows, caption: `${target}'s incident windows` } : null}
                summary={`${incidents.length} incidents.`}
                quiet
            >
                <ol className="feed">
                    {incidents.map((i) => (
                        <li key={i.key}>
                            <StatusBadge status={i.verdict || "Warning"} short />
                            <span>{formatDuration(i.durationMin)}</span>
                            <span className="feed-text">
                                <Link as="button" onClick={() => navigate("incidents", { incident: i.key })}>
                                    {FAMILY_LABEL[i.family] ?? i.label}
                                </Link>{" "}
                                <span className="muted">{i.source}</span>
                            </span>
                            <time>{formatDateTimeUtc(i.start)}</time>
                        </li>
                    ))}
                </ol>
            </VisualCard>

            <VisualCard
                id="estate.target.findings"
                className="span-6"
                title="Findings"
                subtitle={`What the notebooks found on ${target}, worst first.`}
                specs={[d.findingsSpec]}
                loading={d.findingsState.loading}
                error={d.findingsState.error}
                empty={!d.findingsState.loading && findings.length === 0}
                emptyText={`No finding on ${target} in this period.`}
                table={d.findingsState.data ? { columns: d.findingsSpec.columns, rows: d.findingsState.data.rows.filter((r) => r.TargetKey === target), caption: `${target}'s findings` } : null}
                summary={`${findings.length} findings.`}
                quiet
            >
                <ol className="feed">
                    {findings.map((f) => (
                        <li key={f.id}>
                            <StatusBadge status={f.status} short />
                            <span className="muted">{f.analysis}</span>
                            <span className="feed-text">{f.text}</span>
                            <time>{formatDateTimeUtc(f.capturedAt)}</time>
                        </li>
                    ))}
                </ol>
                <Button appearance="transparent" icon={<ArrowRight16Regular />} iconPosition="after" onClick={() => navigate("findings")}>
                    All findings
                </Button>
            </VisualCard>

            <AgentCard
                className="span-12"
                title="Ask the Database Agent"
                subtitle={`Prompts about ${target} with the names the telemetry reported.`}
                lead={`For ${target}, ${filters.window ? "in the selected period" : "over all history"}.`}
                visualId="estate.target.agent"
                build={(surface: AgentSurface) => libraryPrompts({ names: d.names, resourceGroup: runtime.resourceGroup, targets: [target], period: filters.window, latestDay: meta?.latestDay ?? null }, surface)}
            />
        </div>
    );
}

function lineRows(capture: PostgresCapture | null, series: Array<[PostgresTarget, string, string]>): Row[] {
    const out: Row[] = [];
    for (const [target, metric, label] of series) {
        for (const p of postgresSeries(capture, target, metric)) out.push({ at: iso(p.at), series: label, value: p.value });
    }
    return out.sort((a, b) => String(a.at).localeCompare(String(b.at)));
}

function PostgresDetail({ crumbs, focus }: { crumbs: Array<{ label: string; onClick?: () => void }>; focus: EstateTarget }) {
    const { runtime } = useApp();
    const d = useEstateData();
    const capture = d.capture;
    const lagSeries = postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag);
    const caught = replicaCatchUp(capture, lagSeries);
    const lagPeak = postgresPeak(lagSeries.filter((p) => !caught.includes(p)));
    const cpuPeak = postgresPeak(postgresSeries(capture, "T4", POSTGRES_METRICS.cpu));
    const failed = postgresSeries(capture, "T4", POSTGRES_METRICS.failed);
    const failedTotal = failed.reduce((a, p) => a + p.value, 0);
    const skus = postgresSkus(d.pgFindingRows);
    const lagRows = lagSeries.map((p) => ({ at: iso(p.at), "T4-replica": p.value }));
    const cpuRows = lineRows(capture, [
        ["T4", POSTGRES_METRICS.cpu, "T4"],
        ["T4-replica", POSTGRES_METRICS.cpu, "T4-replica"],
    ]);
    const connRows = lineRows(capture, [
        ["T4", POSTGRES_METRICS.connections, "T4"],
        ["T4-replica", POSTGRES_METRICS.connections, "T4-replica"],
        ["T4", POSTGRES_METRICS.failed, "T4, failed"],
    ]);
    const loading = d.pgSeries.loading || d.pgFindings.loading;
    const none = !loading && !d.pgSeries.error && !capture && d.pgFindingRows.length === 0;
    const title = focus === "T4-replica" ? "T4's read replica" : "T4 · Azure Database for PostgreSQL";

    return (
        <div className="page">
            <PageHeader
                title={title}
                description={capture ? `The latest capture of Azure Monitor metrics, ${formatDateTimeUtc(capture.windowStart)} to ${formatDateTimeUtc(capture.windowEnd)}, captured ${formatAgo(capture.capturedAt)}.` : "T4, the PostgreSQL flexible server, and its read replica, from Azure Monitor metrics the demo captures at a session's end."}
                crumbs={crumbs}
                filter={false}
                actions={
                    <Button as="a" href={hubUrlOf(runtime)} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                        Database Hub, live
                    </Button>
                }
            />

            {none ? (
                <EmptyState title="No PostgreSQL history yet">
                    <p>A session's end saves T4's and its read replica's Azure Monitor metrics to the history: Run all in NB_DatabaseHub_Control does it, and so do ./scripts/stop-demo.ps1 -SaveHistory and ./scripts/deploy.ps1 at its end.</p>
                    <p className="muted">The read replica exists only during a session. For T4 live, open Database Hub's PostgreSQL dashboard.</p>
                </EmptyState>
            ) : (
                <>
                    <section className="kpis" aria-label="T4 at a glance">
                        <KpiTile label="T4 server" value={capture?.servers.T4 ?? "–"} sub={skus.T4 ?? ""} />
                        <KpiTile label="Read replica" value={capture?.servers["T4-replica"] ?? "Not in this capture"} sub={skus["T4-replica"] ?? "It exists only during a session"} />
                        <KpiTile
                            label="Read replica lag, peak"
                            value={lagPeak ? formatNumber(lagPeak.value, "seconds") : "–"}
                            status={lagPeak ? (lagPeak.value >= REPLICA_LAG_WARNING_SECONDS ? "Warning" : "Pass") : null}
                            sub={lagPeak ? `at ${formatDateTimeUtc(lagPeak.at)} · warning at ${REPLICA_LAG_WARNING_SECONDS} s` : "No lag in this capture"}
                            actions={
                                lagPeak && lagPeak.value >= REPLICA_LAG_WARNING_SECONDS ? (
                                    <AskWhy
                                        title="Read replica lag"
                                        visualId="estate.t4.lag"
                                        prompt={`Why did T4's read replica lag reach ${formatNumber(lagPeak.value, "seconds")} at ${formatDateTimeUtc(lagPeak.at)}? What load on T4 caused it, and how do I keep the replica close?`}
                                        anomaly={{ metric: "Read replica lag", target: "T4-replica", at: lagPeak.at.toISOString(), value: lagPeak.value, unit: "s" }}
                                        specs={[d.pgSeriesSpec]}
                                        rows={lagRows}
                                    />
                                ) : undefined
                            }
                        />
                        <KpiTile label="T4 CPU, peak" value={formatNumber(cpuPeak?.value ?? null, "percent")} status={cpuPeak ? (cpuPeak.value >= POSTGRES_CPU_WARNING_PERCENT ? "Warning" : "Pass") : null} sub={cpuPeak ? `at ${formatDateTimeUtc(cpuPeak.at)}` : ""} />
                        <KpiTile label="Failed connections" value={formatNumber(failedTotal, "int")} status={failedTotal > 0 ? "Warning" : "Pass"} sub="On T4 in the capture" />
                    </section>

                    <VisualCard
                        id="estate.t4.lag"
                        className="span-12"
                        title="Read replica lag"
                        subtitle={`Database Hub's Read replica lag (physical_replication_delay_in_seconds), the highest value in each interval. ${REPLICA_LAG_WARNING_SECONDS} s or more is a warning.`}
                        specs={[d.pgSeriesSpec]}
                        loading={d.pgSeries.loading}
                        error={d.pgSeries.error}
                        empty={!d.pgSeries.loading && lagRows.length === 0}
                        emptyText="No Read replica lag in this capture: T4's read replica exists only during a session."
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "T4-replica", label: "Read replica lag (s)", kind: "seconds" }], rows: lagRows, caption: "Read replica lag per interval" }}
                        summary={lagPeak ? `Read replica lag peaked at ${formatNumber(lagPeak.value, "seconds")}.` : "No lag."}
                        askPrompt="Explain the read replica's lag in this capture: what caused the peak, and is it a problem?"
                    >
                        <ChartView
                            hideHeader
                            spec={{ kind: "area", title: "Read replica lag", rows: lagRows, x: "at", y: "T4-replica", unit: "s" }}
                            annotations={{ thresholds: [{ value: REPLICA_LAG_WARNING_SECONDS, label: `${REPLICA_LAG_WARNING_SECONDS} s: warning`, tone: "warning" }], markers: lagPeak ? [{ x: lagPeak.at, y: lagPeak.value, label: `peak ${formatNumber(lagPeak.value, "seconds")}` }] : [] }}
                        />
                    </VisualCard>

                    <VisualCard
                        id="estate.t4.cpu"
                        className="span-6"
                        title="CPU"
                        subtitle={`cpu_percent on T4 and its read replica. ${POSTGRES_CPU_WARNING_PERCENT} % or more on T4 is a warning.`}
                        specs={[d.pgSeriesSpec]}
                        loading={d.pgSeries.loading}
                        error={d.pgSeries.error}
                        empty={!d.pgSeries.loading && cpuRows.length === 0}
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "series", label: "Server", kind: "text" }, { key: "value", label: "CPU (%)", kind: "percent" }], rows: cpuRows, caption: "CPU per interval" }}
                        summary={`T4's CPU peaked at ${formatNumber(cpuPeak?.value ?? null, "percent")}.`}
                    >
                        <ChartView hideHeader height={200} spec={{ kind: "line", title: "CPU", rows: cpuRows, x: "at", y: "value", series: "series", unit: "%" }} annotations={{ thresholds: [{ value: POSTGRES_CPU_WARNING_PERCENT, label: `${POSTGRES_CPU_WARNING_PERCENT} %`, tone: "warning" }] }} />
                    </VisualCard>

                    <VisualCard
                        id="estate.t4.connections"
                        className="span-6"
                        title="Connections"
                        subtitle="Active connections on T4 and its read replica, and T4's failed connections (dashed)."
                        specs={[d.pgSeriesSpec]}
                        loading={d.pgSeries.loading}
                        error={d.pgSeries.error}
                        empty={!d.pgSeries.loading && connRows.length === 0}
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "series", label: "Series", kind: "text" }, { key: "value", label: "Connections", kind: "int" }], rows: connRows, caption: "Connections per interval" }}
                        summary={`${failedTotal} failed connections on T4.`}
                    >
                        <ChartView hideHeader height={200} spec={{ kind: "line", title: "Connections", rows: connRows, x: "at", y: "value", series: "series", unit: "count" }} colors={{ "T4, failed": "var(--status-fail)" }} dashed={["T4, failed"]} />
                    </VisualCard>

                    <VisualCard
                        id="estate.t4.findings"
                        className="span-12"
                        title="What the notebook found"
                        subtitle="The findings of the latest PostgreSQL capture, worst first."
                        specs={[d.pgFindingsSpec]}
                        loading={d.pgFindings.loading}
                        error={d.pgFindings.error}
                        empty={!d.pgFindings.loading && d.pgFindingRows.length === 0}
                        table={d.pgFindings.data && d.pgFindingsSpec ? { columns: d.pgFindingsSpec.columns, rows: d.pgFindings.data.rows, caption: "Findings of the latest PostgreSQL capture" } : null}
                        summary={`${d.pgFindingRows.length} findings.`}
                        quiet
                    >
                        <ol className="feed">
                            {d.pgFindingRows.map((f) => (
                                <li key={f.id}>
                                    <StatusBadge status={f.status} short />
                                    <TargetChip target={f.target} />
                                    <span className="feed-text">{f.text}</span>
                                    <time>{formatDateTimeUtc(f.capturedAt)}</time>
                                </li>
                            ))}
                        </ol>
                    </VisualCard>
                </>
            )}
        </div>
    );
}
