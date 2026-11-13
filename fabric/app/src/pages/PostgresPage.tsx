import { useMemo } from "react";
import { ExternalLink } from "lucide-react";

import { useApp } from "@/app-context";
import { InsightCards } from "@/components/InsightCards";
import { StatusBadge } from "@/components/StatusBadge";
import { VisualCard } from "@/components/VisualCard";
import {
    POSTGRES_METRICS,
    POSTGRES_TARGET_INFO,
    postgresPeak,
    postgresSeries,
    postgresSkus,
    toPostgresCapture,
    toPostgresFindings,
    type PostgresCapture,
    type PostgresTarget,
} from "@/data/model";
import { postgresFindingsQuery, postgresSeriesQuery } from "@/data/queries";
import type { Row } from "@/data/query-client";
import { useQuery } from "@/data/use-query";
import { formatAgo, formatDateTimeUtc, formatNumber } from "@/lib/format";
import { failedConnectionsInsight, POSTGRES_CPU_WARNING_PERCENT, postgresCpuInsight, REPLICA_LAG_WARNING_SECONDS, replicaLagInsight } from "@/lib/insights";
import { TimeLines, type TimeLine } from "@/visuals/TimeLines";

/** How T4's metrics reach the history (ADR 0025): the empty state's explanation. */
const HOW_IT_GETS_HERE =
    "NB_DatabaseHub_LiveActivity can't read Azure Monitor, so ./scripts/stop-demo.ps1 -SaveHistory (before it deletes the read replica, whose metrics go with it) and ./scripts/deploy.ps1 (at its end) capture T4's and its read replica's metrics and pass them to the notebook, which saves them to the lakehouse. The read replica exists only during a session: start-demo.ps1 creates it.";

const NO_REPLICA = "No Read replica lag in this capture: T4's read replica exists only during a session (start-demo.ps1 creates it; stop-demo.ps1 captures its metrics, then deletes it).";

function lineOf(capture: PostgresCapture | null, target: PostgresTarget, metric: string, label: string, color = POSTGRES_TARGET_INFO[target].color, dashed = false): TimeLine {
    return { id: `${target}-${metric}`, label, color, dashed, points: postgresSeries(capture, target, metric) };
}

export default function PostgresPage() {
    const { runtime } = useApp();
    const seriesSpec = useMemo(() => postgresSeriesQuery(), []);
    const findingsSpec = useMemo(() => postgresFindingsQuery(), []);
    const series = useQuery(seriesSpec);
    const findingsState = useQuery(findingsSpec);

    const rows = useMemo(() => series.data?.rows ?? [], [series.data]);
    const capture = useMemo(() => toPostgresCapture(rows), [rows]);
    const findings = useMemo(() => toPostgresFindings(findingsState.data?.rows ?? []), [findingsState.data]);
    const skus = useMemo(() => postgresSkus(findings), [findings]);
    const insights = useMemo(
        () => [replicaLagInsight(capture), postgresCpuInsight(capture), failedConnectionsInsight(capture)].filter((x): x is NonNullable<typeof x> => x !== null),
        [capture],
    );
    const rowsOf = (...metrics: string[]): Row[] => rows.filter((r) => metrics.includes(String(r.Metric)));

    const lag = lineOf(capture, "T4-replica", POSTGRES_METRICS.lag, "Read replica lag");
    const lagPeak = postgresPeak(postgresSeries(capture, "T4-replica", POSTGRES_METRICS.lag));
    const cpuPeak = postgresPeak(postgresSeries(capture, "T4", POSTGRES_METRICS.cpu));
    const failed = postgresSeries(capture, "T4", POSTGRES_METRICS.failed);
    const failedTotal = failed.reduce((sum, p) => sum + p.value, 0);
    const failedPeak = postgresPeak(failed);
    const loading = series.loading || findingsState.loading;
    const none = !loading && !series.error && !findingsState.error && !capture && findings.length === 0;
    const span = capture ? `${formatDateTimeUtc(capture.windowStart)} to ${formatDateTimeUtc(capture.windowEnd)}` : "";
    const every = capture?.intervalMinutes ? `every ${formatNumber(capture.intervalMinutes, "int")} minutes` : "";

    return (
        <div className="page">
            <header className="page-head">
                <div>
                    <h2>
                        T4 · <span className="gradient-text">PostgreSQL</span> and its read replica
                    </h2>
                    <p>
                        {capture
                            ? `The latest capture of their Azure Monitor metrics, ${span}${every ? `, ${every}` : ""}, captured ${formatAgo(capture.capturedAt)}. History, not live; all times UTC.`
                            : "T4, the PostgreSQL flexible server, and its read replica, from the Azure Monitor metrics the demo's scripts capture. History, not live."}
                    </p>
                </div>
            </header>

            <InsightCards insights={insights} label="PostgreSQL insights" />

            {none ? (
                <VisualCard
                    className="span-12"
                    title="No PostgreSQL history yet"
                    subtitle="T4's health and its read replica's lag show here once a capture is in the lakehouse."
                    specs={[seriesSpec, findingsSpec]}
                    loading={false}
                    empty
                    emptyText={`No T4 metrics in the history yet. ${HOW_IT_GETS_HERE} For T4 live, open Database Hub's PostgreSQL dashboard.`}
                    table={null}
                    summary="No PostgreSQL capture in the history yet."
                    onRefresh={() => {
                        series.refetch();
                        findingsState.refetch();
                    }}
                >
                    {null}
                </VisualCard>
            ) : (
                <>
                    <VisualCard
                        className="span-8"
                        title="Read replica lag"
                        subtitle={`Database Hub's Read replica lag (physical_replication_delay_in_seconds): the time since the replica replayed the primary's last transaction, its highest value in each interval. ${REPLICA_LAG_WARNING_SECONDS} s or more is a warning.`}
                        specs={[seriesSpec]}
                        loading={series.loading}
                        error={series.error}
                        empty={!series.loading && lag.points.length === 0}
                        emptyText={capture ? NO_REPLICA : `No metrics in the latest capture. ${HOW_IT_GETS_HERE}`}
                        table={series.data ? { columns: seriesSpec.columns, rows: rowsOf(POSTGRES_METRICS.lag), caption: "Read replica lag per interval" } : null}
                        summary={lagPeak ? `Read replica lag over time; it peaked at ${formatNumber(lagPeak.value, "seconds")} at ${formatDateTimeUtc(lagPeak.at)}.` : "No Read replica lag in the latest capture."}
                        fetchedAt={series.data?.fetchedAt}
                        onRefresh={series.refetch}
                    >
                        <TimeLines
                            lines={[lag]}
                            kind="seconds"
                            label="Read replica lag over the latest capture's window"
                            from={capture?.windowStart}
                            to={capture?.windowEnd}
                            threshold={{ value: REPLICA_LAG_WARNING_SECONDS, label: `${REPLICA_LAG_WARNING_SECONDS} s: warning` }}
                            peak={lagPeak ? { ...lagPeak, label: `peak ${formatNumber(lagPeak.value, "seconds")}` } : null}
                        />
                    </VisualCard>

                    <section className="card glass span-4 target-detail" aria-label="The servers">
                        <p className="eyebrow">The servers</p>
                        <h3>{POSTGRES_TARGET_INFO.T4.name}</h3>
                        <dl className="kv">
                            <dt>T4</dt>
                            <dd>{capture?.servers.T4 ?? "not in this capture"}</dd>
                            <dt>Its size</dt>
                            <dd>{skus.T4 ?? "–"}</dd>
                            <dt>Read replica</dt>
                            <dd>{capture?.servers["T4-replica"] ?? "not in this capture"}</dd>
                            <dt>Its size</dt>
                            <dd>{skus["T4-replica"] ?? "–"}</dd>
                            <dt>Window</dt>
                            <dd>{capture ? span : "–"}</dd>
                            <dt>Interval</dt>
                            <dd>{capture?.intervalMinutes ? `${formatNumber(capture.intervalMinutes, "int")} min` : "–"}</dd>
                            <dt>Captured</dt>
                            <dd>{capture ? formatDateTimeUtc(capture.capturedAt) : "–"}</dd>
                            <dt>Points</dt>
                            <dd>{formatNumber(capture?.points.length ?? 0, "int")}</dd>
                        </dl>
                        <p className="gate-muted">The read replica exists only during a session; between sessions the history keeps what stop-demo.ps1 captured before it deleted it.</p>
                        {runtime.links.databaseHub ? (
                            <a className="btn-primary pg-live" href={runtime.links.databaseHub} target="_blank" rel="noopener noreferrer">
                                Database Hub, live <ExternalLink aria-hidden="true" width={16} height={16} />
                            </a>
                        ) : null}
                    </section>

                    <VisualCard
                        className="span-6"
                        title="CPU"
                        subtitle={`cpu_percent on T4 and its read replica, the highest value in each interval. ${POSTGRES_CPU_WARNING_PERCENT} % or more on T4 is a warning.`}
                        specs={[seriesSpec]}
                        loading={series.loading}
                        error={series.error}
                        empty={!series.loading && postgresSeries(capture, "T4", POSTGRES_METRICS.cpu).length + postgresSeries(capture, "T4-replica", POSTGRES_METRICS.cpu).length === 0}
                        emptyText="No CPU metrics in the latest capture."
                        table={series.data ? { columns: seriesSpec.columns, rows: rowsOf(POSTGRES_METRICS.cpu), caption: "CPU per interval" } : null}
                        summary={cpuPeak ? `T4's CPU peaked at ${formatNumber(cpuPeak.value, "percent")} at ${formatDateTimeUtc(cpuPeak.at)}.` : "No CPU metrics for T4 in the latest capture."}
                        fetchedAt={series.data?.fetchedAt}
                    >
                        <TimeLines
                            lines={[lineOf(capture, "T4", POSTGRES_METRICS.cpu, "T4"), lineOf(capture, "T4-replica", POSTGRES_METRICS.cpu, "Read replica")]}
                            kind="percent"
                            label="CPU over the latest capture's window"
                            from={capture?.windowStart}
                            to={capture?.windowEnd}
                            threshold={{ value: POSTGRES_CPU_WARNING_PERCENT, label: `${POSTGRES_CPU_WARNING_PERCENT} %: warning` }}
                            peak={cpuPeak ? { ...cpuPeak, label: `T4 ${formatNumber(cpuPeak.value, "percent")}` } : null}
                        />
                    </VisualCard>

                    <VisualCard
                        className="span-6"
                        title="Connections"
                        subtitle="Active connections on T4 and its read replica (the highest in each interval), and T4's failed connections (the number in each interval, dashed)."
                        specs={[seriesSpec]}
                        loading={series.loading}
                        error={series.error}
                        empty={!series.loading && rowsOf(POSTGRES_METRICS.connections, POSTGRES_METRICS.failed).length === 0}
                        emptyText="No connection metrics in the latest capture."
                        table={series.data ? { columns: seriesSpec.columns, rows: rowsOf(POSTGRES_METRICS.connections, POSTGRES_METRICS.failed), caption: "Active and failed connections per interval" } : null}
                        summary={`Connections over time; ${formatNumber(failedTotal, "int")} failed connection${failedTotal === 1 ? "" : "s"} on T4${failedPeak && failedTotal > 0 ? `, at most ${formatNumber(failedPeak.value, "int")} at ${formatDateTimeUtc(failedPeak.at)}` : ""}.`}
                        fetchedAt={series.data?.fetchedAt}
                    >
                        <TimeLines
                            lines={[
                                lineOf(capture, "T4", POSTGRES_METRICS.connections, "T4, active"),
                                lineOf(capture, "T4-replica", POSTGRES_METRICS.connections, "Read replica, active"),
                                lineOf(capture, "T4", POSTGRES_METRICS.failed, "T4, failed", "var(--status-fail)", true),
                            ]}
                            kind="int"
                            label="Active and failed connections over the latest capture's window"
                            from={capture?.windowStart}
                            to={capture?.windowEnd}
                            peak={failedPeak && failedTotal > 0 ? { ...failedPeak, label: `${formatNumber(failedPeak.value, "int")} failed` } : null}
                        />
                    </VisualCard>

                    <VisualCard
                        className="span-12"
                        title="What the notebook found"
                        subtitle="The findings NB_DatabaseHub_LiveActivity wrote for the latest capture (analysis postgresql), worst first."
                        specs={[findingsSpec]}
                        loading={findingsState.loading}
                        error={findingsState.error}
                        empty={!findingsState.loading && findings.length === 0}
                        emptyText="No findings for the latest capture."
                        table={findingsState.data ? { columns: findingsSpec.columns, rows: findingsState.data.rows, caption: "Findings of the latest PostgreSQL capture" } : null}
                        summary={`${findings.length} findings; ${findings.filter((f) => f.statusSort <= 3).length} need attention.`}
                        fetchedAt={findingsState.data?.fetchedAt}
                        onRefresh={findingsState.refetch}
                    >
                        <ol className="feed">
                            {findings.map((f) => (
                                <li key={f.id} className={f.statusSort <= 3 ? "attention" : undefined}>
                                    <StatusBadge status={f.status} short />
                                    <span className="feed-target">{f.target}</span>
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
