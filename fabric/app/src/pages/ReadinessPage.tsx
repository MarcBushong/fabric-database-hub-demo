import { useMemo, useState } from "react";

import { useApp } from "@/app-context";
import { AgentCard } from "@/components/AgentPrompts";
import { InsightCards } from "@/components/InsightCards";
import { StatusBadge } from "@/components/StatusBadge";
import { VisualCard } from "@/components/VisualCard";
import { toChecks, toCoverage, toReadinessSummary, toTargetNames, toTargets } from "@/data/model";
import { coverageQuery, estateQuery, readinessChecksQuery, readinessSummaryQuery, targetNamesQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { coveragePrompt, libraryPrompts, type AgentSurface, type LibraryContext } from "@/lib/agent-prompts";
import { formatDateTimeUtc, formatNumber } from "@/lib/format";
import { lagInsight, readinessInsight } from "@/lib/insights";
import { STATUSES, statusMeta, type StatusName } from "@/lib/status";
import { areaRings } from "@/visuals/layout";
import { ReadinessRings } from "@/visuals/ReadinessRings";

export default function ReadinessPage() {
    const { filters, meta, runtime } = useApp();
    const [area, setArea] = useState<string | null>(null);
    const [status, setStatus] = useState<StatusName | null>(null);
    const checksSpec = useMemo(() => readinessChecksQuery(), []);
    const summarySpec = useMemo(() => readinessSummaryQuery(), []);
    const coverageSpec = useMemo(() => coverageQuery(), []);
    const estateSpec = useMemo(() => estateQuery(filters), [filters]);
    const namesSpec = useMemo(() => targetNamesQuery(), []);
    const checksQuery = useQuery(checksSpec);
    const summaryQuery = useQuery(summarySpec);
    const coverageQueryState = useQuery(coverageSpec);
    const estate = useQuery(estateSpec);
    const namesQuery = useQuery(namesSpec);

    const checks = useMemo(() => toChecks(checksQuery.data?.rows ?? []), [checksQuery.data]);
    const summary = useMemo(() => toReadinessSummary(summaryQuery.data?.rows ?? []), [summaryQuery.data]);
    const coverage = useMemo(() => toCoverage(coverageQueryState.data?.rows ?? []), [coverageQueryState.data]);
    const targets = useMemo(() => toTargets(estate.data?.rows ?? []), [estate.data]);
    const names = useMemo(() => toTargetNames(namesQuery.data?.rows ?? []), [namesQuery.data]);
    const latestRun = useMemo(() => areaRings(checks).latestRun, [checks]);
    const latest = useMemo(() => checks.filter((c) => c.runId === latestRun).sort((a, b) => a.statusSort - b.statusSort || a.checkId.localeCompare(b.checkId)), [checks, latestRun]);
    const shown = latest.filter((c) => (!area || c.area === area) && (!status || statusMeta(c.status).name === status));
    const insights = useMemo(() => [readinessInsight(summary, latest), lagInsight(targets)].filter((x): x is NonNullable<typeof x> => x !== null), [summary, latest, targets]);
    const maxTables = Math.max(1, ...coverage.map((c) => c.tables ?? 0));

    return (
        <div className="page">
            <header className="page-head">
                <div>
                    <h2>
                        Ready to <span className="gradient-text">demo</span>?
                    </h2>
                    <p>
                        {summary && summary.checks > 0
                            ? `${summary.runLabel}: the Fabric-side checks from NB_DatabaseHub_Deployment, worst first. The Azure-side catalog stays in ./scripts/validate.ps1.`
                            : "No validation run in the lakehouse yet: run NB_DatabaseHub_Deployment."}
                    </p>
                </div>
            </header>

            <InsightCards insights={insights} label="Readiness insights" />

            <VisualCard
                className="span-7"
                title="Readiness rings"
                subtitle="The dial is the pass share of the checks that apply. Each area's ring holds one segment per check; select an area to filter the list."
                specs={[summarySpec, checksSpec]}
                loading={checksQuery.loading || summaryQuery.loading}
                error={checksQuery.error ?? summaryQuery.error}
                empty={!checksQuery.loading && checks.length === 0}
                emptyText="No validation run in the lakehouse yet: run NB_DatabaseHub_Deployment."
                table={summaryQuery.data ? { columns: summarySpec.columns, rows: summaryQuery.data.rows, caption: "Readiness of the latest validation run (model measures)" } : null}
                summary={summary ? `${summary.passed} of ${summary.checks - summary.notSupported - summary.notSelected} applicable checks pass; ${summary.failed} failed, ${summary.manual} manual, ${summary.warnings} warnings.` : "Readiness rings."}
                fetchedAt={summaryQuery.data?.fetchedAt}
                onRefresh={() => {
                    checksQuery.refetch();
                    summaryQuery.refetch();
                }}
            >
                <ReadinessRings checks={checks} summary={summary} area={area} onArea={setArea} />
            </VisualCard>

            <VisualCard
                className="span-5"
                title="Telemetry coverage"
                subtitle="Telemetry tables each target sent in the latest validation run, and how old its newest sample was (fresh means 15 minutes or less)."
                specs={[coverageSpec]}
                loading={coverageQueryState.loading}
                error={coverageQueryState.error}
                empty={!coverageQueryState.loading && coverage.length === 0}
                table={coverageQueryState.data ? { columns: coverageSpec.columns, rows: coverageQueryState.data.rows, caption: "Telemetry coverage per target" } : null}
                summary={coverage.map((c) => `${c.target}: ${c.tables ?? 0} tables, ${c.attention}`).join("; ")}
                fetchedAt={coverageQueryState.data?.fetchedAt}
            >
                <ul className="coverage">
                    {coverage.map((c) => (
                        <li key={c.target}>
                            <span className="coverage-target" style={{ color: `var(--${c.target.toLowerCase()})` }}>
                                {c.target}
                            </span>
                            <span className="coverage-bar" aria-hidden="true">
                                <span style={{ width: `${((c.tables ?? 0) / maxTables) * 100}%`, background: `var(--${c.target.toLowerCase()})` }} />
                            </span>
                            <span>{`${formatNumber(c.tables, "int")} tables`}</span>
                            <span className="gate-muted">{c.ageMin !== null ? `newest ${formatNumber(c.ageMin, "minutes")}` : "not captured"}</span>
                            <span className={c.attention.startsWith("✓") ? "status status-pass" : c.attention.startsWith("▲") ? "status status-warning" : "status status-muted"}>{c.attention}</span>
                        </li>
                    ))}
                </ul>
            </VisualCard>

            <AgentCard
                className="span-12"
                title="Ask the Database Agent"
                subtitle="Before the demo, check what the agent can see: telemetry coverage, then the estate prompt library."
                lead={`For ${filters.targets.join(", ")}, with the names the telemetry reported.`}
                build={(surface: AgentSurface) => {
                    const context: LibraryContext = { names, resourceGroup: runtime.resourceGroup, targets: filters.targets, period: filters.window, latestDay: meta?.latestDay ?? null };
                    return [coveragePrompt(context, surface), ...libraryPrompts(context, surface)];
                }}
            />

            <VisualCard
                className="span-12"
                title="Every check, worst first"
                subtitle="Each check with its exact remediation and documentation. Filter by status or by area (the rings)."
                specs={[checksSpec]}
                loading={checksQuery.loading}
                error={checksQuery.error}
                empty={!checksQuery.loading && shown.length === 0}
                emptyText="No check matches these filters."
                table={checksQuery.data ? { columns: checksSpec.columns, rows: checksQuery.data.rows, caption: "Validation checks of the latest six runs" } : null}
                summary={`${shown.length} checks shown.`}
                fetchedAt={checksQuery.data?.fetchedAt}
                toolbar={
                    <div className="segmented" role="group" aria-label="Filter by status">
                        <button type="button" aria-pressed={status === null} onClick={() => setStatus(null)}>
                            All
                        </button>
                        {STATUSES.filter((s) => latest.some((c) => statusMeta(c.status).name === s.name)).map((s) => (
                            <button key={s.name} type="button" aria-pressed={status === s.name} onClick={() => setStatus(status === s.name ? null : s.name)}>
                                {`${s.glyph} ${s.short}`}
                            </button>
                        ))}
                    </div>
                }
            >
                {area ? (
                    <p className="dax-meta">
                        Area: <strong>{area}</strong>{" "}
                        <button type="button" className="btn-link" onClick={() => setArea(null)}>
                            Show every area
                        </button>
                    </p>
                ) : null}
                <ol className="checks">
                    {shown.map((c) => (
                        <li key={`${c.runId}-${c.checkId}`}>
                            <div className="check-head">
                                <StatusBadge status={c.status} />
                                <code>{c.checkId}</code>
                                <span className="gate-muted">{`${c.area} · ${c.target}`}</span>
                                <time className="gate-muted">{formatDateTimeUtc(c.checkedAt)}</time>
                            </div>
                            <p>{c.message}</p>
                            {c.remediation ? (
                                <p className="remediation">
                                    <strong>Next step:</strong> {c.remediation}
                                </p>
                            ) : null}
                            {c.docUrl ? (
                                <a href={c.docUrl} target="_blank" rel="noopener noreferrer">
                                    Documentation
                                </a>
                            ) : null}
                        </li>
                    ))}
                </ol>
            </VisualCard>
        </div>
    );
}
