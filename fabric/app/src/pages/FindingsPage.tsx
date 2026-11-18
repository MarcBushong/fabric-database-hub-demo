import { useMemo, useState } from "react";
import { Button, Tab, TabList } from "@fluentui/react-components";
import { Open16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { KpiTile } from "@/components/KpiTile";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { FINDING_CATEGORIES, findingCategory, toFindings, toPostgresFindings, toTargetNames, type FindingCategory, type TargetName } from "@/data/model";
import { findingsQuery, postgresFindingsQuery, targetNamesQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { hubUrlOf } from "@/lib/agent-prompts";
import { formatDateTimeUtc } from "@/lib/format";
import { worstStatus } from "@/lib/status";
import { PageHeader } from "@/shell/PageHeader";

interface FindingRow extends Record<string, unknown> {
    id: string;
    status: string;
    statusSort: number;
    target: string;
    category: FindingCategory;
    analysis: string;
    finding: string;
    capturedAt: Date | null;
}

const CATEGORY_LABEL = Object.fromEntries(FINDING_CATEGORIES.map((c) => [c.id, c.label])) as Record<FindingCategory, string>;

const COLUMNS: GridColumn<FindingRow>[] = [
    { key: "status", label: "Status", render: (r) => <StatusBadge status={r.status} short />, sortValue: (r) => r.statusSort, width: "120px" },
    { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} />, width: "110px" },
    { key: "category", label: "Category", render: (r) => CATEGORY_LABEL[r.category], width: "130px" },
    { key: "analysis", label: "Analysis", width: "150px" },
    { key: "finding", label: "Finding" },
    { key: "capturedAt", label: "Captured (UTC)", render: (r) => formatDateTimeUtc(r.capturedAt), sortValue: (r) => r.capturedAt?.getTime() ?? 0, width: "150px" },
];

/** Where Database Hub's own security and optimization insights live: it has no API for them, so the app links to its views. */
const LIVE_ONLY: Partial<Record<FindingCategory, { title: string; view: string; text: (t2: TargetName | undefined) => string }>> = {
    security: {
        title: "Security posture, live in Database Hub",
        view: "Security",
        text: () => "Database Hub shows each database's security posture live: authentication, auditing, and encryption with customer-managed keys. It has no API for them yet, so they aren't in the history; the table below is the history's own security findings.",
    },
    optimization: {
        title: "Optimization insights, live in Database Hub",
        view: "Optimization",
        text: (t2) =>
            `Database Hub's optimization insights are live: migration assessments, license-model opportunities, and SQL Server instances that don't report usage. T2's SQL Server instance ${t2?.resource ? `${t2.resource}${t2.instance && t2.instance !== "MSSQLSERVER" ? `\\${t2.instance}` : ""}` : "arcsql01"} shows as "migration assessment ready", with its readiness for each Azure SQL target. The table below is the history's own findings.`,
    },
};
export default function FindingsPage() {
    const { filters, view, runtime } = useApp();
    const [tab, setTab] = useState<FindingCategory | "all">("all");
    const findingsSpec = useMemo(() => findingsQuery(filters), [filters]);
    const pgSpec = useMemo(() => (view.targets.includes("T4") ? postgresFindingsQuery() : null), [view.targets]);
    const findingsState = useQuery(findingsSpec);
    const pgState = useQuery(pgSpec);
    const namesSpec = useMemo(() => (tab === "optimization" ? targetNamesQuery() : null), [tab]);
    const namesState = useQuery(namesSpec);
    const t2 = useMemo(() => toTargetNames(namesState.data?.rows ?? []).T2, [namesState.data]);

    const rows: FindingRow[] = useMemo(() => {
        const sql = toFindings(findingsState.data?.rows ?? []).filter((f) => !/^T\d/.test(f.target) || view.targets.some((t) => f.target === t || f.target.startsWith(`${t}-`)));
        const ids = new Set(sql.map((f) => f.id));
        const pg = toPostgresFindings(pgState.data?.rows ?? []).filter((f) => !ids.has(f.id));
        return [
            ...sql.map((f) => ({ id: f.id, status: f.status, statusSort: f.statusSort, target: f.target, category: findingCategory(f), analysis: f.analysis, finding: f.text, capturedAt: f.capturedAt })),
            ...pg.map((f) => ({ id: f.id, status: f.status, statusSort: f.statusSort, target: f.target, category: findingCategory({ analysisKey: "postgresql", group: "PostgreSQL", id: f.id }), analysis: "PostgreSQL", finding: f.text, capturedAt: f.capturedAt })),
        ].sort((a, b) => a.statusSort - b.statusSort || (b.capturedAt?.getTime() ?? 0) - (a.capturedAt?.getTime() ?? 0));
    }, [findingsState.data, pgState.data, view.targets]);

    const shown = tab === "all" ? rows : rows.filter((r) => r.category === tab);
    const attention = rows.filter((r) => r.statusSort <= 3);
    const count = (c: FindingCategory) => rows.filter((r) => r.category === c).length;
    const live = tab !== "all" ? LIVE_ONLY[tab] : undefined;

    return (
        <div className="page">
            <PageHeader title="Findings" description="What the notebooks found, worst first: performance, availability, security, optimization, capacity, and what Database Hub can see." />

            <section className="kpis" aria-label="Findings at a glance">
                <KpiTile label="Need attention" value={String(attention.length)} status={worstStatus(attention.map((r) => r.status))?.name ?? "Pass"} sub={`${rows.length} findings in the period`} />
                {FINDING_CATEGORIES.slice(0, 4).map((c) => (
                    <KpiTile key={c.id} label={c.label} value={String(count(c.id))} sub={c.description} status={worstStatus(rows.filter((r) => r.category === c.id && r.statusSort <= 3).map((r) => r.status))?.name ?? null} onOpen={() => setTab(c.id)} openLabel={`Show the ${c.label.toLowerCase()} findings`} />
                ))}
            </section>

            <TabList selectedValue={tab} onTabSelect={(_, d) => setTab(d.value as FindingCategory | "all")} aria-label="Finding categories" size="small">
                <Tab value="all">{`All (${rows.length})`}</Tab>
                {FINDING_CATEGORIES.map((c) => (
                    <Tab key={c.id} value={c.id}>{`${c.label} (${count(c.id)})`}</Tab>
                ))}
            </TabList>

            {live ? (
                <section className="panel span-12 live-panel" aria-label={live.title}>
                    <h3>{live.title}</h3>
                    <p className="panel-sub">{live.text(t2)}</p>
                    <div>
                        <Button as="a" href={hubUrlOf(runtime)} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                            {`Open Database Hub, then ${live.view}`}
                        </Button>
                    </div>
                </section>
            ) : null}

            <VisualCard
                id={`findings.${tab}`}
                title={tab === "all" ? "Every finding" : CATEGORY_LABEL[tab]}
                subtitle={live ? "From the history, a fallback for Database Hub's live view: the latest capture of each finding in the period." : "The latest capture of each finding in the period. Sort, filter, and export."}
                specs={[findingsSpec, pgSpec]}
                loading={findingsState.loading}
                error={findingsState.error}
                empty={!findingsState.loading && shown.length === 0}
                emptyText={<EmptyState compact title={tab === "all" ? "No findings in this period" : `No ${CATEGORY_LABEL[tab].toLowerCase()} findings in the history`}>{tab === "all" ? "Run all in NB_DatabaseHub_Control: the session's history brings the findings." : null}</EmptyState>}
                table={{ columns: [
                    { key: "status", label: "Status", kind: "status" },
                    { key: "target", label: "Target", kind: "text" },
                    { key: "category", label: "Category", kind: "text" },
                    { key: "analysis", label: "Analysis", kind: "text" },
                    { key: "finding", label: "Finding", kind: "text" },
                    { key: "capturedAt", label: "Captured (UTC)", kind: "datetime" },
                ], rows: shown, caption: "Findings" }}
                summary={`${shown.length} findings shown.`}
                askPrompt="Which of these findings should I address first, and how?"
                quiet
            >
                <DataGrid columns={COLUMNS} rows={shown} caption="Findings" exportName={`findings-${tab}`} />
            </VisualCard>
        </div>
    );
}
