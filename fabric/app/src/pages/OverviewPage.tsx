import { useMemo } from "react";
import { Button, Link } from "@fluentui/react-components";
import { ArrowRight16Regular, DatabaseSearch20Regular, Open16Regular, Sparkle16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import { EmptyState } from "@/components/EmptyState";
import { HealthTile } from "@/components/HealthTile";
import { Insights } from "@/components/Insights";
import { KpiTile } from "@/components/KpiTile";
import { LiveNow } from "@/components/LiveNow";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { FAMILY_LABEL, toBins, toCaptureFindings, toChecks, toCosmosCapture, toFindings, toIncidents, toPostgresCapture, toPostgresFindings, toReadinessSummary, toSessions, toTargets, toWaitFlows } from "@/data/model";
import {
    cosmosFindingsQuery,
    cosmosSeriesQuery,
    estateQuery,
    findingsQuery,
    incidentsQuery,
    postgresFindingsQuery,
    postgresSeriesQuery,
    readinessChecksQuery,
    readinessSummaryQuery,
    seriesQuery,
    sessionsQuery,
    waitsQuery,
} from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { buildAskContext, measuredFindings } from "@/lib/ask";
import { formatAgoShort, formatDateTimeUtc, formatDuration, formatNumber } from "@/lib/format";
import { cosmosHealth, postgresHealth, sqlHealth } from "@/lib/health";
import { coverageInsight, dominantWaitInsight, freshnessInsight, lagInsight } from "@/lib/insights";
import { worstStatus } from "@/lib/status";
import { PageHeader } from "@/shell/PageHeader";

export const OVERVIEW_PROMPT = "Which databases need attention this week, and why?";

/** The first run: no history yet, and the one action that fills it. */
export function FirstRun() {
    const { runtime } = useApp();
    return (
        <EmptyState
            icon={<DatabaseSearch20Regular />}
            title="No history yet"
            actions={
                runtime.links.workspace ? (
                    <Button appearance="primary" as="a" href={runtime.links.workspace} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                        Open the demo's workspace
                    </Button>
                ) : null
            }
        >
            <p>
                Run all in <strong>NB_DatabaseHub_Control</strong> fills it: one session starts every target, runs the showcase's incidents, and saves the
                history this app reads. Nothing to set up here.
            </p>
            <p className="muted">The app reads the lakehouse history through SM_DatabaseHub_History as you. Open it again after the session's end.</p>
        </EmptyState>
    );
}

export default function OverviewPage() {
    const { filters, view, navigate, meta, metaLoading, metaError, provenance } = useApp();
    const copilot = useCopilot();
    const estateSpec = useMemo(() => (filters.targets.length ? estateQuery(filters) : null), [filters]);
    const seriesSpec = useMemo(() => (filters.targets.length ? seriesQuery(filters) : null), [filters]);
    const findingsSpec = useMemo(() => findingsQuery(filters), [filters]);
    const incidentsSpec = useMemo(() => (filters.targets.length ? incidentsQuery(filters) : null), [filters]);
    const waitsSpec = useMemo(() => (filters.targets.length ? waitsQuery(filters) : null), [filters]);
    const summarySpec = useMemo(() => readinessSummaryQuery(), []);
    const checksSpec = useMemo(() => readinessChecksQuery(), []);
    const sessionsSpec = useMemo(() => sessionsQuery(filters), [filters]);
    const pgSeriesSpec = useMemo(() => (view.targets.includes("T4") ? postgresSeriesQuery() : null), [view.targets]);
    const pgFindingsSpec = useMemo(() => (view.targets.includes("T4") ? postgresFindingsQuery() : null), [view.targets]);
    const cosmosSeriesSpec = useMemo(() => (view.targets.includes("T5") ? cosmosSeriesQuery() : null), [view.targets]);
    const cosmosFindingsSpec = useMemo(() => (view.targets.includes("T5") ? cosmosFindingsQuery() : null), [view.targets]);

    const estate = useQuery(estateSpec);
    const series = useQuery(seriesSpec);
    const findingsState = useQuery(findingsSpec);
    const incidentsState = useQuery(incidentsSpec);
    const waits = useQuery(waitsSpec);
    const summaryState = useQuery(summarySpec);
    const checksState = useQuery(checksSpec);
    const sessionsState = useQuery(sessionsSpec);
    const pgSeries = useQuery(pgSeriesSpec);
    const pgFindings = useQuery(pgFindingsSpec);
    const cosmosSeriesState = useQuery(cosmosSeriesSpec);
    const cosmosFindingsState = useQuery(cosmosFindingsSpec);

    const targets = useMemo(() => toTargets(estate.data?.rows ?? []), [estate.data]);
    const bins = useMemo(() => toBins(series.data?.rows ?? []), [series.data]);
    const findings = useMemo(
        () => toFindings(findingsState.data?.rows ?? []).filter((f) => !/^T\d/.test(f.target) || view.targets.some((t) => f.target === t || f.target.startsWith(`${t}-`))),
        [findingsState.data, view.targets],
    );
    const incidents = useMemo(() => toIncidents(incidentsState.data?.rows ?? []), [incidentsState.data]);
    const flows = useMemo(() => toWaitFlows(waits.data?.rows ?? []), [waits.data]);
    const summary = useMemo(() => toReadinessSummary(summaryState.data?.rows ?? []), [summaryState.data]);
    const checks = useMemo(() => toChecks(checksState.data?.rows ?? []), [checksState.data]);
    const sessions = useMemo(() => toSessions(sessionsState.data?.rows ?? []), [sessionsState.data]);
    const capture = useMemo(() => toPostgresCapture(pgSeries.data?.rows ?? []), [pgSeries.data]);
    const pgFindingRows = useMemo(() => toPostgresFindings(pgFindings.data?.rows ?? []), [pgFindings.data]);
    const cosmos = useMemo(() => toCosmosCapture(cosmosSeriesState.data?.rows ?? []), [cosmosSeriesState.data]);
    const cosmosFindingRows = useMemo(() => toCaptureFindings(cosmosFindingsState.data?.rows ?? []), [cosmosFindingsState.data]);

    const health = useMemo(() => {
        const out = sqlHealth(targets, findings, bins, view.targets);
        if (view.targets.includes("T4")) out.push(postgresHealth(capture, pgFindingRows));
        if (view.targets.includes("T5") && (cosmos || cosmosFindingRows.length > 0)) out.push(cosmosHealth(cosmos, cosmosFindingRows));
        return out;
    }, [targets, findings, bins, view.targets, capture, pgFindingRows, cosmos, cosmosFindingRows]);

    const attention = findings.filter((f) => f.statusSort <= 3);
    const worstFinding = worstStatus(attention.map((f) => f.status));
    const latestRun = checks.reduce((a, c) => (c.runId > a ? c.runId : a), "");
    const openChecks = checks.filter((c) => c.runId === latestRun && c.statusSort <= 3).sort((a, b) => a.statusSort - b.statusSort);
    const readiness = summary?.readiness ?? null;
    // A validation run has at least one check: the summary's row of zeros isn't one.
    const hasRun = summary !== null && summary.checks > 0;
    const lastSession = sessions.find((s) => /showcase|session/i.test(s.profile)) ?? sessions[0] ?? null;
    const newest = incidents[0] ?? null;
    const needs = health.filter((h) => h.status === "Fail" || h.status === "Warning" || h.status === "Manual action required");

    const insights = useMemo(
        () => [coverageInsight(targets, filters.targets), lagInsight(targets), dominantWaitInsight(flows), freshnessInsight(meta)].filter((x): x is NonNullable<typeof x> => x !== null),
        [targets, filters.targets, flows, meta],
    );

    const noHistory = !metaLoading && !metaError && (!meta || (!meta.hasBins && meta.notebookRuns === 0));

    const askOverview = () =>
        copilot.ask(
            buildAskContext({
                title: "Overview: what needs attention",
                page: "overview",
                visualId: "overview.attention",
                // The measurements only (ADR 0031): each target's numbers and the telemetry behind them. Its status, incident
                // windows, and findings to review come from the answer key, so the chat judges from what was measured.
                specs: [filters.targets.length ? estateQuery(filters, { measured: true }) : null, view.targets.includes("T4") ? postgresSeriesQuery({ measured: true }) : null, view.targets.includes("T5") ? cosmosSeriesQuery({ measured: true }) : null],
                rows: [...health.map((h) => ({ target: h.key, ...Object.fromEntries(h.metrics.map((m) => [m.label, m.value])) }))],
                prompt: OVERVIEW_PROMPT,
                provenance,
                meta,
                filters,
                window: view.window,
            }),
        );

    return (
        <div className="page">
            <PageHeader
                title="Overview"
                description="What needs attention now across the estate: health per target, incidents, findings, readiness, and what changed."
                actions={
                    <Button appearance="primary" icon={<Sparkle16Filled />} onClick={askOverview}>
                        {OVERVIEW_PROMPT}
                    </Button>
                }
            />

            <LiveNow />

            {noHistory ? (
                <FirstRun />
            ) : (
                <>
                    <h2 className="section-title span-12">At a glance, from the history</h2>
                    <section className="kpis" aria-label="At a glance">
                        <KpiTile
                            label="Targets needing attention"
                            value={`${needs.length} of ${health.length}`}
                            status={needs.length > 0 ? (worstStatus(needs.map((h) => h.status))?.name ?? null) : "Pass"}
                            sub={needs.length > 0 ? needs.map((h) => h.key).join(", ") : "Every selected target is healthy"}
                            onOpen={() => navigate("estate")}
                            openLabel="Open the estate"
                        />
                        <KpiTile
                            label="Incident windows"
                            value={formatNumber(incidents.length, "int")}
                            status={incidents.length > 0 ? "Warning" : "Pass"}
                            sub={newest ? `Newest: ${newest.target} ${FAMILY_LABEL[newest.family] ?? newest.family}, ${formatAgoShort(newest.start)}` : "None in this period"}
                            onOpen={() => navigate("incidents")}
                            openLabel="Open the incidents"
                        />
                        <KpiTile
                            label="Findings to review"
                            value={formatNumber(attention.length, "int")}
                            status={worstFinding?.name ?? "Pass"}
                            sub={`${findings.length} findings in the period`}
                            onOpen={() => navigate("findings")}
                            openLabel="Open the findings"
                        />
                        <KpiTile
                            label="Demo readiness"
                            value={hasRun && readiness !== null ? `${Math.round(readiness * 100)} %` : "–"}
                            status={hasRun ? (summary.failed > 0 ? "Fail" : summary.manual > 0 ? "Manual action required" : summary.warnings > 0 ? "Warning" : "Pass") : null}
                            sub={hasRun ? `${summary.failed} failed · ${summary.manual} manual · ${summary.warnings} warnings` : "Run all in NB_DatabaseHub_Control fills this"}
                            onOpen={() => navigate("readiness")}
                            openLabel="Open readiness"
                        />
                        <KpiTile
                            label="Newest snapshot"
                            value={meta?.latestCapture ? formatAgoShort(meta.latestCapture) : "–"}
                            status={meta?.freshness || null}
                            sub={meta ? `${formatNumber(meta.notebookRuns, "int")} notebook runs saved` : ""}
                            onOpen={() => navigate("links")}
                            openLabel="How the history gets here"
                        />
                        <KpiTile
                            label="Last session"
                            value={lastSession?.requestedAt ? formatAgoShort(lastSession.requestedAt) : "None yet"}
                            status={lastSession?.status || null}
                            sub={lastSession ? `${lastSession.profile || "session"} · ${lastSession.target || "every target"}` : "Run all in NB_DatabaseHub_Control"}
                            onOpen={() => navigate("manage")}
                            openLabel="Open Manage"
                        />
                    </section>

                    <section className="span-12" aria-labelledby="health-title">
                        <h2 id="health-title" className="section-title">
                            Health per target
                        </h2>
                        <div className="health">
                            {health.map((h) => (
                                <HealthTile key={h.key} health={h} onOpen={() => navigate("estate", { target: h.key })} />
                            ))}
                        </div>
                    </section>

                    <VisualCard
                        id="overview.incidents"
                        className="span-6"
                        title="Incidents"
                        subtitle="The newest incident windows in the period: what happened, where, and how bad."
                        specs={[incidentsSpec]}
                        loading={incidentsState.loading}
                        error={incidentsState.error}
                        empty={!incidentsState.loading && incidents.length === 0}
                        emptyText="No incident window in this period."
                        table={incidentsState.data && incidentsSpec ? { columns: incidentsSpec.columns, rows: incidentsState.data.rows, caption: "Incident windows in the period" } : null}
                        summary={`${incidents.length} incident windows.`}
                        askPrompt="Which of these incidents matters most, what caused it, and is it resolved?"
                        // The incident windows are the demo's answer key, with nothing measured beside them here: no Ask (ADR 0031).
                        ask={false}
                        quiet
                    >
                        <ol className="feed">
                            {incidents.slice(0, 5).map((i) => (
                                <li key={i.key}>
                                    <TargetChip target={i.target} full={false} />
                                    <time>{formatDateTimeUtc(i.start)}</time>
                                    <span className="feed-text">
                                        <Link as="button" onClick={() => navigate("incidents", { incident: i.key })}>
                                            {FAMILY_LABEL[i.family] ?? i.label}
                                        </Link>{" "}
                                        <span className="muted">
                                            {formatDuration(i.durationMin)} · peak {formatNumber(i.peakValue, "decimal")} {i.peakUnit}
                                        </span>
                                    </span>
                                </li>
                            ))}
                        </ol>
                    </VisualCard>

                    <VisualCard
                        id="overview.findings"
                        className="span-6"
                        title="Findings to review"
                        subtitle="The worst findings in the period, from the notebooks' analyses."
                        specs={[findingsSpec]}
                        loading={findingsState.loading}
                        error={findingsState.error}
                        empty={!findingsState.loading && attention.length === 0}
                        emptyText="No finding needs attention in this period."
                        table={findingsState.data ? { columns: findingsSpec.columns, rows: findingsState.data.rows, caption: "Findings in the period" } : null}
                        summary={`${attention.length} findings need attention.`}
                        askPrompt="Which of these findings should I address first, and how?"
                        // The measured analyses' rows only, with no DAX: Analysis Findings also holds the grading analyses' (ADR 0031).
                        ask={{ specs: [], table: findingsState.data ? { columns: findingsSpec.columns, rows: measuredFindings(findingsState.data.rows), caption: "Findings in the period" } : null }}
                        quiet
                    >
                        <ol className="feed">
                            {attention.slice(0, 5).map((f) => (
                                <li key={f.id}>
                                    <TargetChip target={f.target} />
                                    <StatusBadge status={f.status} short />
                                    <span className="feed-text">
                                        <strong>{f.analysis}</strong>
                                        {f.text}
                                    </span>
                                    <time>{formatDateTimeUtc(f.capturedAt)}</time>
                                </li>
                            ))}
                        </ol>
                        {attention.length > 5 ? (
                            <Button appearance="transparent" icon={<ArrowRight16Regular />} iconPosition="after" onClick={() => navigate("findings")}>
                                {`All ${attention.length} findings`}
                            </Button>
                        ) : null}
                    </VisualCard>

                    <VisualCard
                        id="overview.readiness"
                        className="span-6"
                        title="Readiness"
                        subtitle={summary?.runLabel ? `The latest validation run, ${summary.runLabel}: what's open, worst first.` : "The latest validation run."}
                        specs={[summarySpec, checksSpec]}
                        loading={summaryState.loading || checksState.loading}
                        error={summaryState.error ?? checksState.error}
                        empty={!checksState.loading && checks.length === 0}
                        emptyText="No validation run yet: Run all in NB_DatabaseHub_Control fills this, or run NB_DatabaseHub_Deployment yourself."
                        table={checksState.data ? { columns: checksSpec.columns, rows: checksState.data.rows.filter((r) => r.RunId === latestRun), caption: "Checks of the latest validation run" } : null}
                        summary={summary ? `${summary.passed} of ${summary.checks} checks pass.` : "Readiness."}
                        askPrompt="Is the demo ready? What should I fix before presenting?"
                        quiet
                    >
                        <div className="readiness-bar" role="img" aria-label={summary ? `${summary.passed} passed, ${summary.warnings} warnings, ${summary.manual} manual, ${summary.failed} failed` : "No checks"}>
                            {summary
                                ? (
                                      [
                                          ["pass", summary.passed],
                                          ["warning", summary.warnings],
                                          ["manual", summary.manual],
                                          ["fail", summary.failed],
                                      ] as const
                                  ).map(([tone, count]) => (count > 0 ? <span key={tone} className={`seg seg-${tone}`} style={{ flexGrow: count }} /> : null))
                                : null}
                        </div>
                        <ul className="checks-mini">
                            {openChecks.slice(0, 4).map((c) => (
                                <li key={c.checkId}>
                                    <StatusBadge status={c.status} short />
                                    <span>
                                        <code>{c.checkId}</code> {c.remediation || c.message}
                                    </span>
                                </li>
                            ))}
                            {openChecks.length === 0 && checks.length > 0 ? <li className="muted">Every applicable check passes.</li> : null}
                        </ul>
                    </VisualCard>

                    <VisualCard
                        id="overview.sessions"
                        className="span-6"
                        title="Recent sessions"
                        subtitle="What the control ran: each session's plan and each incident request, newest first."
                        specs={[sessionsSpec]}
                        loading={sessionsState.loading}
                        error={sessionsState.error}
                        empty={!sessionsState.loading && sessions.length === 0}
                        emptyText="No session in this period. Run all in NB_DatabaseHub_Control starts one."
                        table={sessionsState.data ? { columns: sessionsSpec.columns, rows: sessionsState.data.rows, caption: "Sessions and activity requests" } : null}
                        summary={`${sessions.length} activity requests.`}
                        // What the control ran is the demo's plan, the answer key: no Ask (ADR 0031).
                        ask={false}
                        quiet
                    >
                        <ol className="feed">
                            {sessions.slice(0, 5).map((s) => (
                                <li key={s.requestId || `${s.requestedAt?.getTime()}-${s.target}`}>
                                    <TargetChip target={s.target || "all"} />
                                    <StatusBadge status={s.status} short />
                                    <span className="feed-text">
                                        <strong>{s.profile || "Session"}</strong>
                                        {s.message}
                                    </span>
                                    <time>{formatDateTimeUtc(s.requestedAt)}</time>
                                </li>
                            ))}
                        </ol>
                    </VisualCard>

                    <Insights insights={insights} label="What the data says" page="overview" />
                </>
            )}
        </div>
    );
}
