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
import { MigrationCard } from "@/components/MigrationCard";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import {
    FAMILY_LABEL,
    COSMOS_METRICS,
    cosmosSeries,
    POSTGRES_METRICS,
    postgresPeak,
    postgresSeries,
    postgresSkus,
    replicaCatchUp,
    toBins,
    toFindings,
    toIncidents,
    throttledRuns,
    throttleEpisodes,
    toCaptureFindings,
    toCosmosCapture,
    toPostgresCapture,
    toPostgresFindings,
    toTargetNames,
    toTargets,
    toWaitFlows,
    type CosmosCapture,
    type PostgresCapture,
    type PostgresTarget,
} from "@/data/model";
import { cosmosFindingsQuery, cosmosSeriesQuery, estateQuery, findingsQuery, incidentsQuery, postgresFindingsQuery, postgresSeriesQuery, seriesQuery, targetNamesQuery, waitsQuery, type ColumnSpec } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { useQuery } from "@/data/use-query";
import { hubUrlOf, libraryPrompts, type AgentSurface } from "@/lib/agent-prompts";
import type { TargetKey } from "@/lib/dax";
import { ENGINES, engineOf, TARGETS } from "@/lib/estate";
import { formatAgo, formatBeside, formatDateTimeUtc, formatDuration, formatNumber, percent } from "@/lib/format";
import { cosmosHealth, postgresHealth, sqlHealth, type TargetHealth } from "@/lib/health";
import { FAILED_CONNECTIONS_CAVEAT, POSTGRES_CPU_WARNING_PERCENT, POSTGRES_USABLE_CONNECTIONS, REPLICA_LAG_WARNING_SECONDS, USABLE_SLOTS_TEXT } from "@/lib/insights";
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
    const cosmosSeriesSpec = useMemo(() => (view.targets.includes("T5") ? cosmosSeriesQuery() : null), [view.targets]);
    const cosmosFindingsSpec = useMemo(() => (view.targets.includes("T5") ? cosmosFindingsQuery() : null), [view.targets]);
    const cosmosSeriesState = useQuery(cosmosSeriesSpec);
    const cosmosFindingsState = useQuery(cosmosFindingsSpec);
    const targets = useMemo(() => toTargets(estate.data?.rows ?? []), [estate.data]);
    const bins = useMemo(() => toBins(series.data?.rows ?? []), [series.data]);
    const findings = useMemo(() => toFindings(findingsState.data?.rows ?? []), [findingsState.data]);
    const names = useMemo(() => toTargetNames(namesState.data?.rows ?? []), [namesState.data]);
    const capture = useMemo(() => toPostgresCapture(pgSeries.data?.rows ?? []), [pgSeries.data]);
    const pgFindingRows = useMemo(() => toPostgresFindings(pgFindings.data?.rows ?? []), [pgFindings.data]);
    const cosmos = useMemo(() => toCosmosCapture(cosmosSeriesState.data?.rows ?? []), [cosmosSeriesState.data]);
    const cosmosFindingRows = useMemo(() => toCaptureFindings(cosmosFindingsState.data?.rows ?? []), [cosmosFindingsState.data]);
    return {
        estateSpec,
        seriesSpec,
        findingsSpec,
        pgSeriesSpec,
        pgFindingsSpec,
        cosmosSeriesSpec,
        cosmosFindingsSpec,
        estate,
        series,
        findingsState,
        pgSeries,
        pgFindings,
        cosmosSeriesState,
        cosmosFindingsState,
        targets,
        bins,
        findings,
        names,
        capture,
        pgFindingRows,
        cosmos,
        cosmosFindingRows,
    };
}

function Inventory() {
    const { view, navigate } = useApp();
    const d = useEstateData();
    const health = useMemo(() => {
        const out: TargetHealth[] = sqlHealth(d.targets, d.findings, d.bins, view.targets);
        if (view.targets.includes("T4")) out.push(postgresHealth(d.capture, d.pgFindingRows));
        // T5 shows once it has history: a deployment without Cosmos DB (t5Enabled false) has none.
        if (view.targets.includes("T5") && (d.cosmos || d.cosmosFindingRows.length > 0)) out.push(cosmosHealth(d.cosmos, d.cosmosFindingRows));
        return out;
    }, [d.targets, d.findings, d.bins, view.targets, d.capture, d.pgFindingRows, d.cosmos, d.cosmosFindingRows]);

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
                resource: h.key === "T4" ? (d.capture?.servers.T4 ?? "–") : h.key === "T5" ? d.cosmos?.account || "–" : (names?.resource ?? "–"),
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
    }, [health, d.targets, d.names, d.capture, d.pgFindingRows, d.cosmos]);

    const loading = d.estate.loading || d.pgSeries.loading;

    return (
        <div className="page">
            <PageHeader title="Estate" description="Every engine and target the demo runs: SQL Server on an Azure VM and through Azure Arc, Azure SQL Database, PostgreSQL with its read replica, and Azure Cosmos DB when present." />

            {ENGINES.map((engine) => {
                const tiles = health.filter((h) => engine.targets.includes(h.key));
                if (engine.id === "cosmosdb" && tiles.length === 0) {
                    return view.targets.includes("T5") && !d.cosmosSeriesState.loading ? (
                        <section key={engine.id} className="span-12" aria-label={engine.label}>
                            <h2 className="section-title">{engine.label}</h2>
                            <EmptyState compact title="No T5 history yet">
                                <p>A session's end saves T5's Azure Monitor metrics: normalized RU, throttled requests (429), and availability. A deployment without Cosmos DB (t5Enabled off) has none.</p>
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
    if (target === "T5") return <CosmosDetail crumbs={crumbs} />;
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
                <KpiTile label="CPU, average · peak" value={`${formatNumber(t?.cpuAvg ?? null, "percent")}`} sub={`peak ${formatBeside(t?.cpuPeak ?? null, "percent", 80)}${peak ? ` at ${formatDateTimeUtc(peak.at)}` : ""}`} status={t && (t.cpuPeak ?? 0) >= 80 ? "Warning" : t ? "Pass" : null} actions={
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

            {target === "T2" ? <MigrationCard className="span-12" resourceName={names?.resource ?? "arcsql01"} /> : null}

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
                summary={`CPU on ${target}; peak ${formatBeside(peak?.value ?? null, "percent", 80)}.`}
                askPrompt={`Explain ${target}'s CPU over this period: what drove the peaks, and is anything abnormal?`}
            >
                <ChartView
                    hideHeader
                    spec={{ kind: "area", title: `${target} CPU`, rows: cpuRows, x: "at", y: "CPU", unit: "%" }}
                    colors={{ CPU: info.color }}
                    annotations={{ bands, thresholds: [{ value: 80, label: "80 %", tone: "warning" }], markers: peak ? [{ x: peak.at, y: peak.value, label: `peak ${formatBeside(peak.value, "percent", 80)}` }] : [] }}
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
    // connection-surge's measured signal (F34): T4's connections against the slots clients can use. Its refused attempts
    // aren't in failed connections, so those only show, dashed, with what they leave out.
    const connPeak = postgresPeak(postgresSeries(capture, "T4", POSTGRES_METRICS.connections));
    const atLimit = connPeak !== null && connPeak.value >= POSTGRES_USABLE_CONNECTIONS;
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
                            value={lagPeak ? formatBeside(lagPeak.value, "seconds", REPLICA_LAG_WARNING_SECONDS) : "–"}
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
                        <KpiTile label="T4 CPU, peak" value={formatBeside(cpuPeak?.value ?? null, "percent", POSTGRES_CPU_WARNING_PERCENT)} status={cpuPeak ? (cpuPeak.value >= POSTGRES_CPU_WARNING_PERCENT ? "Warning" : "Pass") : null} sub={cpuPeak ? `at ${formatDateTimeUtc(cpuPeak.at)}` : ""} />
                        <KpiTile
                            label="Connections, peak"
                            value={connPeak ? formatBeside(connPeak.value, "int", POSTGRES_USABLE_CONNECTIONS) : "–"}
                            status={connPeak ? (atLimit ? "Warning" : "Pass") : null}
                            sub={connPeak ? `at ${formatDateTimeUtc(connPeak.at)} · ${POSTGRES_USABLE_CONNECTIONS} slots for clients` : "No connections in this capture"}
                        />
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
                        summary={lagPeak ? `Read replica lag peaked at ${formatBeside(lagPeak.value, "seconds", REPLICA_LAG_WARNING_SECONDS)}.` : "No lag."}
                        askPrompt="Explain the read replica's lag in this capture: what caused the peak, and is it a problem?"
                    >
                        <ChartView
                            hideHeader
                            spec={{ kind: "area", title: "Read replica lag", rows: lagRows, x: "at", y: "T4-replica", unit: "s" }}
                            annotations={{ thresholds: [{ value: REPLICA_LAG_WARNING_SECONDS, label: `${REPLICA_LAG_WARNING_SECONDS} s: warning`, tone: "warning" }], markers: lagPeak ? [{ x: lagPeak.at, y: lagPeak.value, label: `peak ${formatBeside(lagPeak.value, "seconds", REPLICA_LAG_WARNING_SECONDS)}` }] : [] }}
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
                        summary={`T4's CPU peaked at ${formatBeside(cpuPeak?.value ?? null, "percent", POSTGRES_CPU_WARNING_PERCENT)}.`}
                    >
                        <ChartView hideHeader height={200} spec={{ kind: "line", title: "CPU", rows: cpuRows, x: "at", y: "value", series: "series", unit: "%" }} annotations={{ thresholds: [{ value: POSTGRES_CPU_WARNING_PERCENT, label: `${POSTGRES_CPU_WARNING_PERCENT} %`, tone: "warning" }] }} />
                    </VisualCard>

                    <VisualCard
                        id="estate.t4.connections"
                        className="span-6"
                        title="Connections"
                        subtitle={`Active connections on T4 and its read replica, as Database Hub's Connections chart shows them, and T4's failed connections (dashed). ${POSTGRES_USABLE_CONNECTIONS} or more on T4 is a warning: ${USABLE_SLOTS_TEXT}. ${FAILED_CONNECTIONS_CAVEAT}`}
                        specs={[d.pgSeriesSpec]}
                        loading={d.pgSeries.loading}
                        error={d.pgSeries.error}
                        empty={!d.pgSeries.loading && connRows.length === 0}
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "series", label: "Series", kind: "text" }, { key: "value", label: "Connections", kind: "int" }], rows: connRows, caption: "Connections per interval" }}
                        summary={`${
                            connPeak
                                ? `T4's active connections peaked at ${formatBeside(connPeak.value, "int", POSTGRES_USABLE_CONNECTIONS)} at ${formatDateTimeUtc(connPeak.at)}, ${atLimit ? "at or above" : "under"} the ${POSTGRES_USABLE_CONNECTIONS} slots clients can use.`
                                : "No active connections on T4 in this capture."
                        } Azure Monitor counted ${formatNumber(failedTotal, "int")} failed connection${failedTotal === 1 ? "" : "s"} on T4, which leave out a client refused at the connection limit.`}
                    >
                        <ChartView
                            hideHeader
                            height={200}
                            spec={{ kind: "line", title: "Connections", rows: connRows, x: "at", y: "value", series: "series", unit: "count" }}
                            colors={{ "T4, failed": "var(--status-fail)" }}
                            dashed={["T4, failed"]}
                            annotations={{ thresholds: [{ value: POSTGRES_USABLE_CONNECTIONS, label: `${POSTGRES_USABLE_CONNECTIONS}: the slots clients can use`, tone: "warning" }] }}
                        />
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

function cosmosRows(capture: CosmosCapture | null, series: Array<[string, string]>): Row[] {
    const out: Row[] = [];
    for (const [metric, label] of series) {
        for (const p of cosmosSeries(capture, metric)) out.push({ at: iso(p.at), series: label, value: p.value });
    }
    return out.sort((a, b) => String(a.at).localeCompare(String(b.at)));
}

/** T5, Azure Cosmos DB: the latest capture's normalized RU, its 429s, its throttling episodes, and its recovery. */
function CosmosDetail({ crumbs }: { crumbs: Array<{ label: string; onClick?: () => void }> }) {
    const { runtime } = useApp();
    const d = useEstateData();
    const capture = d.cosmos;
    const ru = cosmosSeries(capture, COSMOS_METRICS.normalizedRu);
    const ruPeak = postgresPeak(ru);
    const total = (metric: string) => cosmosSeries(capture, metric).reduce((a, p) => a + p.value, 0);
    const requests = total(COSMOS_METRICS.requests);
    const throttled = total(COSMOS_METRICS.throttled);
    const provisioned = postgresPeak(cosmosSeries(capture, COSMOS_METRICS.provisioned))?.value ?? null;
    const availability = cosmosSeries(capture, COSMOS_METRICS.availability).map((p) => p.value);
    const lowest = availability.length > 0 ? Math.min(...availability) : null;
    const latency = cosmosSeries(capture, COSMOS_METRICS.latency);
    const latencyAvg = latency.length > 0 ? latency.reduce((a, p) => a + p.value, 0) / latency.length : null;
    const latencyPeak = postgresPeak(latency);
    const episodes = throttleEpisodes(d.cosmosFindingsState.data?.rows ?? []);
    const recovery = d.cosmosFindingRows.find((f) => f.id === "cosmosdb.T5.recovery") ?? null;
    // The story in order: throttling, each episode, the recovery, then what was captured.
    const storyRank = (id: string) => (id === "cosmosdb.T5.throttling" ? 0 : id.startsWith("cosmosdb.T5.throttle.") ? 1 : id === "cosmosdb.T5.recovery" ? 2 : id === "cosmosdb.T5.capture" ? 4 : 3);
    const story = [...d.cosmosFindingRows].sort((a, b) => storyRank(a.id) - storyRank(b.id) || a.id.localeCompare(b.id));
    const ruRows = ru.map((p) => ({ at: iso(p.at), "Normalized RU": p.value }));
    const requestRows = cosmosRows(capture, [
        [COSMOS_METRICS.requests, "Requests"],
        [COSMOS_METRICS.throttled, "429s"],
    ]);
    const latencyRows = latency.map((p) => ({ at: iso(p.at), "Gateway latency": p.value }));
    const loading = d.cosmosSeriesState.loading || d.cosmosFindingsState.loading;
    const none = !loading && !d.cosmosSeriesState.error && !capture && d.cosmosFindingRows.length === 0;
    const interval = capture?.intervalMinutes ? `${formatNumber(capture.intervalMinutes, "int")}-minute intervals` : "intervals";

    return (
        <div className="page">
            <PageHeader
                title="T5 · Azure Cosmos DB"
                description={capture ? `${capture.account || "The account"}: the latest capture of Azure Monitor metrics, ${formatDateTimeUtc(capture.windowStart)} to ${formatDateTimeUtc(capture.windowEnd)} in ${interval}, captured ${formatAgo(capture.capturedAt)}.` : "T5, an Azure Cosmos DB for NoSQL account, from Azure Monitor metrics the demo captures at a session's end."}
                crumbs={crumbs}
                filter={false}
                actions={
                    <Button as="a" href={hubUrlOf(runtime)} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                        Database Hub, live
                    </Button>
                }
            />

            {none ? (
                <EmptyState title="No Cosmos DB history yet">
                    <p>A session's end saves T5's Azure Monitor metrics to the history: Run all in NB_DatabaseHub_Control does it, and so do ./scripts/stop-demo.ps1 -SaveHistory and ./scripts/deploy.ps1 at its end.</p>
                    <p className="muted">A deployment without Cosmos DB (t5Enabled off) has none. For T5 live, open Database Hub's Cosmos DB view.</p>
                </EmptyState>
            ) : (
                <>
                    <section className="kpis" aria-label="T5 at a glance">
                        <KpiTile label="Account" value={capture?.account || "\u2013"} sub={provisioned !== null ? `Azure Cosmos DB for NoSQL \u00b7 ${formatNumber(provisioned, "int")} RU/s provisioned` : "Azure Cosmos DB for NoSQL"} />
                        <KpiTile
                            label="Normalized RU, peak"
                            value={formatBeside(ruPeak?.value ?? null, "percent", 100)}
                            status={ruPeak ? (ruPeak.value >= 100 ? "Warning" : "Pass") : null}
                            sub={ruPeak ? `at ${formatDateTimeUtc(ruPeak.at)} \u00b7 100 % throttles` : ""}
                            actions={
                                ruPeak && ruPeak.value >= 100 ? (
                                    <AskWhy
                                        title="T5 normalized RU"
                                        visualId="estate.t5.ru"
                                        prompt={`Why did T5's normalized RU consumption reach ${formatNumber(ruPeak.value, "percent")} at ${formatDateTimeUtc(ruPeak.at)}, with ${formatNumber(throttled, "int")} requests throttled (429)? Should I raise the provisioned RU/s, switch to autoscale, or spread a hot partition key?`}
                                        anomaly={{ metric: "Normalized RU consumption", target: "T5", at: ruPeak.at.toISOString(), value: ruPeak.value, unit: "%" }}
                                        specs={[d.cosmosSeriesSpec]}
                                        rows={ruRows}
                                    />
                                ) : undefined
                            }
                        />
                        <KpiTile
                            label="Throttled requests (429)"
                            value={formatNumber(throttled, "int")}
                            status={capture ? (throttled > 0 ? "Warning" : "Pass") : null}
                            sub={requests > 0 ? `${percent(throttled / requests, 1)} of ${formatNumber(requests, "int")} requests` : "No requests in the capture"}
                        />
                        <KpiTile label="Recovery" value={recovery ? (recovery.status === "Pass" ? "Recovered" : "Not yet") : throttled > 0 ? "\u2013" : "No throttling"} status={recovery?.status ?? (throttled > 0 ? null : "Pass")} sub={recovery ? recovery.text : "Back at baseline before the capture ended"} />
                        <KpiTile label="Availability, lowest" value={lowest === null ? "\u2013" : formatBeside(lowest, "percent", 99.99)} status={lowest === null ? null : lowest < 99.99 ? "Warning" : "Pass"} sub="429s aren't availability errors" />
                        <KpiTile label="Gateway latency" value={latencyAvg === null ? "\u2013" : formatNumber(latencyAvg, "ms")} sub={latencyPeak ? `average \u00b7 peak ${formatNumber(latencyPeak.value, "ms")}` : "average"} />
                    </section>

                    <VisualCard
                        id="estate.t5.ru"
                        className="span-12"
                        title="Normalized RU, and when it throttled"
                        subtitle={`The highest normalized RU consumption in each interval: at 100 % the account throttles requests (429).${provisioned !== null ? ` Provisioned throughput stays at ${formatNumber(provisioned, "int")} RU/s.` : ""} Shaded: the intervals that throttled.`}
                        specs={[d.cosmosSeriesSpec, d.cosmosFindingsSpec]}
                        loading={d.cosmosSeriesState.loading}
                        error={d.cosmosSeriesState.error}
                        empty={!d.cosmosSeriesState.loading && ruRows.length === 0}
                        emptyText="No normalized RU in this capture."
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "Normalized RU", label: "Normalized RU (%)", kind: "percent" }], rows: ruRows, caption: "Normalized RU per interval" }}
                        summary={ruPeak ? `Normalized RU peaked at ${formatBeside(ruPeak.value, "percent", 100)}; ${throttledRuns(capture).length} throttled stretches in ${episodes.length} episodes.` : "No normalized RU."}
                        askPrompt="Explain T5's normalized RU in this capture: when did it throttle, why, and did it recover?"
                    >
                        <ChartView
                            hideHeader
                            spec={{ kind: "area", title: "Normalized RU", rows: ruRows, x: "at", y: "Normalized RU", unit: "%" }}
                            colors={{ "Normalized RU": TARGETS.T5.color }}
                            annotations={{
                                bands: throttledRuns(capture).map((r) => ({ from: r.from, to: r.to, tone: "incident" as const })),
                                thresholds: [{ value: 100, label: "100 %: throttling", tone: "warning" }],
                                markers: ruPeak && ruPeak.value < 100 ? [{ x: ruPeak.at, y: ruPeak.value, label: `peak ${formatBeside(ruPeak.value, "percent", 100)}` }] : [],
                            }}
                        />
                    </VisualCard>

                    <VisualCard
                        id="estate.t5.requests"
                        className="span-6"
                        title="Requests and 429s"
                        subtitle="Requests in each interval, and the ones Cosmos DB throttled (429)."
                        specs={[d.cosmosSeriesSpec]}
                        loading={d.cosmosSeriesState.loading}
                        error={d.cosmosSeriesState.error}
                        empty={!d.cosmosSeriesState.loading && requestRows.length === 0}
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "series", label: "Series", kind: "text" }, { key: "value", label: "Requests", kind: "int" }], rows: requestRows, caption: "Requests and 429s per interval" }}
                        summary={`${formatNumber(throttled, "int")} of ${formatNumber(requests, "int")} requests throttled.`}
                    >
                        <ChartView hideHeader height={200} spec={{ kind: "line", title: "Requests", rows: requestRows, x: "at", y: "value", series: "series", unit: "count" }} colors={{ Requests: TARGETS.T5.color, "429s": "var(--status-fail)" }} />
                    </VisualCard>

                    <VisualCard
                        id="estate.t5.latency"
                        className="span-6"
                        title="Gateway latency"
                        subtitle="Server-side latency through the gateway, the average in each interval."
                        specs={[d.cosmosSeriesSpec]}
                        loading={d.cosmosSeriesState.loading}
                        error={d.cosmosSeriesState.error}
                        empty={!d.cosmosSeriesState.loading && latencyRows.length === 0}
                        emptyText="No gateway latency in this capture."
                        table={{ columns: [{ key: "at", label: "Interval (UTC)", kind: "datetime" }, { key: "Gateway latency", label: "Gateway latency (ms)", kind: "decimal" }], rows: latencyRows, caption: "Gateway latency per interval" }}
                        summary={latencyAvg === null ? "No latency." : `Gateway latency averaged ${formatNumber(latencyAvg, "ms")}.`}
                    >
                        <ChartView hideHeader height={200} spec={{ kind: "line", title: "Gateway latency", rows: latencyRows, x: "at", y: "Gateway latency", unit: "ms" }} colors={{ "Gateway latency": TARGETS.T5.color }} />
                    </VisualCard>

                    <VisualCard
                        id="estate.t5.findings"
                        className="span-12"
                        title="What the notebook found"
                        subtitle="The findings of the latest Cosmos DB capture: the throttling, each episode, and the recovery."
                        specs={[d.cosmosFindingsSpec]}
                        loading={d.cosmosFindingsState.loading}
                        error={d.cosmosFindingsState.error}
                        empty={!d.cosmosFindingsState.loading && d.cosmosFindingRows.length === 0}
                        table={d.cosmosFindingsState.data && d.cosmosFindingsSpec ? { columns: d.cosmosFindingsSpec.columns, rows: d.cosmosFindingsState.data.rows, caption: "Findings of the latest Cosmos DB capture" } : null}
                        summary={`${d.cosmosFindingRows.length} findings.`}
                        quiet
                    >
                        <ol className="feed">
                            {story.map((f) => (
                                <li key={f.id}>
                                    <StatusBadge status={f.status} short />
                                    <TargetChip target={f.target || "T5"} />
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
