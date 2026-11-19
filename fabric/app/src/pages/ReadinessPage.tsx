import { useMemo, useState } from "react";
import { Tab, TabList } from "@fluentui/react-components";

import { useApp } from "@/app-context";
import { AgentCard } from "@/components/AgentPrompts";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { Insights } from "@/components/Insights";
import { KpiTile } from "@/components/KpiTile";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { toChecks, toCoverage, toReadinessSummary, toTargetNames, toTargets, type Check } from "@/data/model";
import { coverageQuery, estateQuery, readinessChecksQuery, readinessSummaryQuery, targetNamesQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { coveragePrompt, libraryPrompts, type AgentSurface, type LibraryContext } from "@/lib/agent-prompts";
import { formatDateTimeUtc, formatNumber } from "@/lib/format";
import { lagInsight, readinessInsight } from "@/lib/insights";
import { statusMeta, STATUSES } from "@/lib/status";
import { PageHeader } from "@/shell/PageHeader";
import { ChartView } from "@/visuals/ChartView";
import { areaRings } from "@/visuals/layout";

type CheckRow = Check & Record<string, unknown>;

const COLUMNS: GridColumn<CheckRow>[] = [
    { key: "status", label: "Status", render: (r) => <StatusBadge status={r.status} short />, sortValue: (r) => r.statusSort, width: "120px" },
    { key: "checkId", label: "Check", render: (r) => <code>{r.checkId}</code>, width: "200px" },
    { key: "area", label: "Area", width: "110px" },
    { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} />, width: "100px" },
    { key: "message", label: "What it found" },
    { key: "remediation", label: "Next step", render: (r) => (r.remediation ? r.remediation : <span className="muted">–</span>) },
    { key: "docUrl", label: "Docs", kind: "url", width: "70px" },
];

const STATUS_COLORS: Record<string, string> = {
    Fail: "var(--status-fail)",
    "Manual action required": "var(--status-manual)",
    Warning: "var(--status-warning)",
    Pass: "var(--status-pass)",
    "Not supported": "var(--colorNeutralStroke1)",
    "Not selected": "var(--colorNeutralStroke2)",
};

export default function ReadinessPage() {
    const { filters, meta, runtime } = useApp();
    const [status, setStatus] = useState<string>("open");
    const checksSpec = useMemo(() => readinessChecksQuery(), []);
    const summarySpec = useMemo(() => readinessSummaryQuery(), []);
    const coverageSpec = useMemo(() => coverageQuery(), []);
    const estateSpec = useMemo(() => (filters.targets.length ? estateQuery(filters) : null), [filters]);
    const namesSpec = useMemo(() => targetNamesQuery(), []);
    const checksState = useQuery(checksSpec);
    const summaryState = useQuery(summarySpec);
    const coverageState = useQuery(coverageSpec);
    const estate = useQuery(estateSpec);
    const namesState = useQuery(namesSpec);

    const checks = useMemo(() => toChecks(checksState.data?.rows ?? []), [checksState.data]);
    const summary = useMemo(() => toReadinessSummary(summaryState.data?.rows ?? []), [summaryState.data]);
    const coverage = useMemo(() => toCoverage(coverageState.data?.rows ?? []), [coverageState.data]);
    const targets = useMemo(() => toTargets(estate.data?.rows ?? []), [estate.data]);
    const names = useMemo(() => toTargetNames(namesState.data?.rows ?? []), [namesState.data]);
    const latestRun = useMemo(() => areaRings(checks).latestRun, [checks]);
    const latest = useMemo(() => checks.filter((c) => c.runId === latestRun).sort((a, b) => a.statusSort - b.statusSort || a.checkId.localeCompare(b.checkId)), [checks, latestRun]);
    const shown = latest.filter((c) => status === "all" || (status === "open" ? c.statusSort <= 3 : statusMeta(c.status).name === status)) as CheckRow[];
    const byArea = useMemo(() => {
        const rows: Array<{ area: string; status: string; checks: number }> = [];
        for (const c of latest) {
            const name = statusMeta(c.status).name;
            const row = rows.find((r) => r.area === c.area && r.status === name);
            if (row) row.checks += 1;
            else rows.push({ area: c.area, status: name, checks: 1 });
        }
        return rows.sort((a, b) => STATUSES.findIndex((s) => s.name === a.status) - STATUSES.findIndex((s) => s.name === b.status));
    }, [latest]);
    const insights = useMemo(() => [readinessInsight(summary, latest), lagInsight(targets)].filter((x): x is NonNullable<typeof x> => x !== null), [summary, latest, targets]);
    const applicable = summary ? summary.checks - summary.notSupported - summary.notSelected : 0;

    return (
        <div className="page">
            <PageHeader
                title="Readiness"
                description={summary && summary.checks > 0 ? `${summary.runLabel}: the Fabric-side checks from NB_DatabaseHub_Deployment, worst first. The Azure-side catalog stays in ./scripts/validate.ps1.` : "Is the demo ready to present? The latest validation run's checks, worst first."}
                filter={false}
            />

            {!checksState.loading && checks.length === 0 ? (
                <EmptyState title="No validation run in the history yet">
                    <p>
                        Run all in <strong>NB_DatabaseHub_Control</strong> fills this: once its session runs, it runs NB_DatabaseHub_Deployment's read-only checks, which save here.
                    </p>
                    <p>Or run NB_DatabaseHub_Deployment yourself, in the demo workspace.</p>
                </EmptyState>
            ) : (
                <>
                    <section className="kpis" aria-label="Readiness at a glance">
                        <KpiTile label="Ready" value={summary?.readiness !== null && summary?.readiness !== undefined ? `${Math.round(summary.readiness * 100)} %` : "–"} sub={summary ? `${summary.passed} of ${applicable} applicable pass` : ""} status={summary ? (summary.failed > 0 ? "Fail" : summary.manual > 0 ? "Manual action required" : summary.warnings > 0 ? "Warning" : "Pass") : null} />
                        <KpiTile label="Failed" value={String(summary?.failed ?? 0)} status={summary?.failed ? "Fail" : null} onOpen={() => setStatus("Fail")} openLabel="Show the failed checks" />
                        <KpiTile label="Manual steps" value={String(summary?.manual ?? 0)} status={summary?.manual ? "Manual action required" : null} onOpen={() => setStatus("Manual action required")} openLabel="Show the manual steps" />
                        <KpiTile label="Warnings" value={String(summary?.warnings ?? 0)} status={summary?.warnings ? "Warning" : null} onOpen={() => setStatus("Warning")} openLabel="Show the warnings" />
                        <KpiTile label="Passed" value={String(summary?.passed ?? 0)} status={summary?.passed ? "Pass" : null} onOpen={() => setStatus("Pass")} openLabel="Show the passed checks" />
                    </section>

                    <VisualCard
                        id="readiness.areas"
                        className="span-7"
                        title="Checks by area"
                        subtitle="The latest run's checks per area, by status."
                        specs={[checksSpec]}
                        loading={checksState.loading}
                        error={checksState.error}
                        empty={!checksState.loading && byArea.length === 0}
                        table={{ columns: [{ key: "area", label: "Area", kind: "text" }, { key: "status", label: "Status", kind: "status" }, { key: "checks", label: "Checks", kind: "int" }], rows: byArea, caption: "Checks per area and status" }}
                        summary={`${latest.length} checks in ${new Set(latest.map((c) => c.area)).size} areas.`}
                        askPrompt="Is the demo ready to present? What should I fix first, and how?"
                    >
                        <ChartView hideHeader height={220} spec={{ kind: "stackedBar", title: "Checks by area", rows: byArea, x: "area", y: "checks", series: "status", unit: "count" }} colors={STATUS_COLORS} />
                    </VisualCard>

                    <VisualCard
                        id="readiness.coverage"
                        className="span-5"
                        title="Telemetry coverage"
                        subtitle="Telemetry tables each SQL target sent in the latest validation run, and how old its newest sample was."
                        specs={[coverageSpec]}
                        loading={coverageState.loading}
                        error={coverageState.error}
                        empty={!coverageState.loading && coverage.length === 0}
                        table={coverageState.data ? { columns: coverageSpec.columns, rows: coverageState.data.rows, caption: "Telemetry coverage per target" } : null}
                        summary={coverage.map((c) => `${c.target}: ${c.tables ?? 0} tables, ${c.attention}`).join("; ")}
                    >
                        <ul className="coverage">
                            {coverage.map((c) => (
                                <li key={c.target}>
                                    <TargetChip target={c.target} />
                                    <span>{`${formatNumber(c.tables, "int")} tables`}</span>
                                    <span className="muted">{c.ageMin !== null ? `newest ${formatNumber(c.ageMin, "minutes")}` : "not captured"}</span>
                                    <StatusBadge status={c.attention.startsWith("✓") ? "Pass" : c.attention.startsWith("▲") ? "Warning" : "Not selected"} short />
                                </li>
                            ))}
                        </ul>
                    </VisualCard>

                    <TabList selectedValue={status} onTabSelect={(_, d) => setStatus(String(d.value))} aria-label="Filter the checks" size="small">
                        <Tab value="open">{`Open (${latest.filter((c) => c.statusSort <= 3).length})`}</Tab>
                        <Tab value="all">{`All (${latest.length})`}</Tab>
                        {STATUSES.filter((s) => latest.some((c) => statusMeta(c.status).name === s.name)).map((s) => (
                            <Tab key={s.name} value={s.name}>{`${s.short} (${latest.filter((c) => statusMeta(c.status).name === s.name).length})`}</Tab>
                        ))}
                    </TabList>

                    <VisualCard
                        id="readiness.checks"
                        title="Checks, worst first"
                        subtitle={`Each check with its next step and documentation${latest[0]?.checkedAt ? `, checked ${formatDateTimeUtc(latest[0].checkedAt)}` : ""}.`}
                        specs={[checksSpec]}
                        loading={checksState.loading}
                        error={checksState.error}
                        empty={!checksState.loading && shown.length === 0}
                        emptyText="No check matches this filter."
                        table={checksState.data ? { columns: checksSpec.columns, rows: checksState.data.rows.filter((r) => r.RunId === latestRun), caption: "Checks of the latest validation run" } : null}
                        summary={`${shown.length} checks shown.`}
                        askPrompt="Explain these checks and what each next step does."
                        quiet
                    >
                        <DataGrid columns={COLUMNS} rows={shown} caption="Validation checks" exportName="readiness-checks" />
                    </VisualCard>

                    <AgentCard
                        className="span-12"
                        title="Ask the Database Agent"
                        subtitle="Before the demo, check what the agent can see: telemetry coverage, then the estate prompt library."
                        lead={`For ${filters.targets.join(", ") || "the SQL targets"}, with the names the telemetry reported.`}
                        visualId="readiness.agent"
                        build={(surface: AgentSurface) => {
                            const context: LibraryContext = { names, resourceGroup: runtime.resourceGroup, targets: filters.targets, period: filters.window, latestDay: meta?.latestDay ?? null };
                            return [coveragePrompt(context, surface), ...libraryPrompts(context, surface)];
                        }}
                    />

                    <Insights insights={insights} label="What the data says" page="readiness" />
                </>
            )}
        </div>
    );
}
