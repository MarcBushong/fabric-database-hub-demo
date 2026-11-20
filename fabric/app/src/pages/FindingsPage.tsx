import { useMemo } from "react";
import { Badge, Button, MessageBar, MessageBarBody, Tab, TabList } from "@fluentui/react-components";
import { Open16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { KpiTile } from "@/components/KpiTile";
import { MigrationCard } from "@/components/MigrationCard";
import { ProvenanceBadge } from "@/components/ProvenanceBadge";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import { FINDING_CATEGORIES, findingCategory, toFindings, toPostgresFindings, toTargetNames, type FindingCategory, type TargetName } from "@/data/model";
import { findingsQuery, postgresFindingsQuery, targetNamesQuery } from "@/data/queries";
import { liveDataOf, liveOffOf, liveRoutes, useLiveEstate, type EstateAnswer, type EstateView, type MissedAnswer } from "@/data/live-estate";
import { useQuery } from "@/data/use-query";
import { hubUrlOf } from "@/lib/agent-prompts";
import { liveOptimizationRows, liveSecurityRows, type LiveCheckRow } from "@/lib/live-findings";
import { formatDateTimeUtc, sentence } from "@/lib/format";
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

const LIVE_COLUMNS: GridColumn<LiveCheckRow>[] = [
    { key: "attention", label: "Attention", render: (r) => (<Badge appearance="tint" shape="rounded" color={r.attention === "Needs attention" ? "warning" : "informative"}>{r.attention}</Badge>), width: "150px" },
    { key: "target", label: "Target", render: (r) => (r.target ? <TargetChip target={r.target} /> : "\u2013"), width: "110px" },
    { key: "resource", label: "Resource", width: "200px" },
    { key: "type", label: "Type", width: "170px" },
    { key: "area", label: "Area", width: "150px" },
    { key: "check", label: "Check" },
];

const LIVE_TABLE_COLUMNS = [
    { key: "attention", label: "Attention", kind: "text" as const },
    { key: "target", label: "Target", kind: "text" as const },
    { key: "resource", label: "Resource", kind: "text" as const },
    { key: "type", label: "Type", kind: "text" as const },
    { key: "area", label: "Area", kind: "text" as const },
    { key: "check", label: "Check", kind: "text" as const },
];

/** What Database Hub shows that the history doesn't have: the app reads it live, and links to the Hub's own view. */
const LIVE_TABS: Partial<Record<FindingCategory, { title: string; view: string; reads: string; fallback: string; ask: string }>> = {
    security: {
        title: "Security posture, live from Database Hub",
        view: "Security",
        reads: "Authentication, auditing, and customer-managed key warnings, and each resource's security checks.",
        fallback: "Database Hub shows each database's security posture live: authentication, auditing, and encryption with customer-managed keys.",
        ask: "Which of these security checks should I fix first, and how, on each database?",
    },
    optimization: {
        title: "Optimization, live from Database Hub",
        view: "Optimization",
        reads: "The optimization checks Database Hub raises on each resource: license-model opportunities, usage reporting, and sizing.",
        fallback: "Database Hub's optimization checks are live: license-model opportunities, SQL Server instances that don't report usage, and sizing.",
        ask: "Which of these optimization opportunities save the most, and what does each one take?",
    },
};

/**
 * One live source for a visual: when the oldest answer was read, every route behind it, and every route that didn't
 * answer, a view's that came back without data included (R924), so the partial bar names it.
 */
function liveSourceOf(answers: ReadonlyArray<EstateAnswer<EstateView> | null>, missed: ReadonlyArray<MissedAnswer | null> = []) {
    const present = answers.filter((a): a is EstateAnswer<EstateView> => a !== null);
    if (present.length === 0) return null;
    const read = [...present, ...missed.filter((m): m is MissedAnswer => m !== null)];
    const at = present.map((a) => a.at).sort()[0];
    return { at, source: read.flatMap((a) => a.source), errors: read.flatMap((a) => a.errors) };
}

function t2Instance(t2: TargetName | undefined): string {
    if (!t2?.resource) return "arcsql01";
    return t2.instance && t2.instance !== "MSSQLSERVER" ? `${t2.resource}\\${t2.instance}` : t2.resource;
}

function LiveChecks(props: { tab: "security" | "optimization"; rows: LiveCheckRow[]; answers: Array<EstateAnswer<EstateView> | null>; missed: Array<MissedAnswer | null>; loading: boolean; unavailable: string | null; off: string | null; onRefresh: () => void; hubUrl: string }) {
    const info = LIVE_TABS[props.tab];
    if (!info) return null;
    const live = liveSourceOf(props.answers, props.missed);
    // While Database Hub refuses the app as a whole (R924), the tab has no live section; Live views says why.
    if (!live && props.off) return null;
    const open = (
        <Button as="a" size="small" href={props.hubUrl} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
            {`Open Database Hub, then ${info.view}`}
        </Button>
    );
    if (!live && !props.loading) {
        return (
            <section className="panel span-12 live-panel" aria-label={info.title}>
                <h3>{info.title}</h3>
                <p className="panel-sub">{info.fallback}</p>
                <p className="muted live-off">
                    <ProvenanceBadge provenance="live" liveState="unavailable" />
                    {` ${sentence(props.unavailable ?? "this app has no live source")} The table below is the history's own findings.`}
                </p>
                <div>{open}</div>
            </section>
        );
    }
    const attention = props.rows.filter((r) => r.attention === "Needs attention").length;
    return (
        <VisualCard
            id={`findings.live.${props.tab}`}
            className="span-12"
            title={info.title}
            subtitle={info.reads}
            specs={[]}
            live={live}
            loading={props.loading}
            empty={!props.loading && props.rows.length === 0}
            emptyText={<EmptyState compact title="Database Hub flags nothing here">{`Every ${props.tab} check it runs on the demo's resources passed.`}</EmptyState>}
            table={{ columns: LIVE_TABLE_COLUMNS, rows: props.rows, caption: `Live ${props.tab} checks` }}
            summary={`${props.rows.length} live checks: ${attention} need attention.`}
            askPrompt={info.ask}
            onRefresh={props.onRefresh}
            toolbar={open}
        >
            {live && live.errors.length > 0 ? (
                <MessageBar intent="warning">
                    <MessageBarBody>{`Partial answer: ${liveRoutes(live.source, live.errors).failed.join(", ") || "a Database Hub call"} didn't answer. What the other routes read is below.`}</MessageBarBody>
                </MessageBar>
            ) : null}
            <DataGrid columns={LIVE_COLUMNS} rows={props.rows} caption={`Live ${props.tab} checks`} exportName={`findings-live-${props.tab}`} />
        </VisualCard>
    );
}

export default function FindingsPage() {
    const { filters, view, setView, runtime } = useApp();
    const tab: FindingCategory | "all" = view.category ?? "all";
    const setTab = (next: FindingCategory | "all") => setView({ category: next === "all" ? null : next });
    const findingsSpec = useMemo(() => findingsQuery(filters), [filters]);
    const pgSpec = useMemo(() => (view.targets.includes("T4") ? postgresFindingsQuery() : null), [view.targets]);
    const findingsState = useQuery(findingsSpec);
    const pgState = useQuery(pgSpec);
    const namesSpec = useMemo(() => (tab === "optimization" ? targetNamesQuery() : null), [tab]);
    const namesState = useQuery(namesSpec);
    const t2 = useMemo(() => toTargetNames(namesState.data?.rows ?? []).T2, [namesState.data]);
    // The live reads are cached for a minute and shared with the Copilot dock, so the tiles and tabs read them once.
    const security = useLiveEstate("security");
    const inventory = useLiveEstate("inventory");
    // Whether Database Hub refuses the app as a whole takes every view, health's too (cached and shared, R924).
    const health = useLiveEstate("health");
    const liveOff = liveOffOf([inventory, health, security]);
    // Until both views behind the security checks have answered (the warnings, and the resources' own checks in the
    // inventory), the count is partial, never a clean pass: one is still being read, or came back without data.
    const securityWaiting = security.answer === null ? security : inventory;
    const securityPartial = (security.answer === null) !== (inventory.answer === null) ? (securityWaiting.loading ? "part of Database Hub is still being read" : "part of Database Hub didn't answer") : null;
    const liveSecurity = useMemo(() => (security.answer || inventory.answer ? liveSecurityRows(liveDataOf(security.answer), liveDataOf(inventory.answer)) : null), [security.answer, inventory.answer]);
    const liveOptimization = useMemo(() => (inventory.answer ? liveOptimizationRows(liveDataOf(inventory.answer)) : null), [inventory.answer]);
    const hubUrl = hubUrlOf(runtime);
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

    return (
        <div className="page">
            <PageHeader title="Findings" description="What the notebooks found, worst first: performance, availability, security, optimization, capacity, and what Database Hub can see." />

            <section className="kpis" aria-label="Findings at a glance">
                <KpiTile label="Need attention" value={String(attention.length)} status={worstStatus(attention.map((r) => r.status))?.name ?? "Pass"} sub={`${rows.length} findings in the period`} />
                {FINDING_CATEGORIES.slice(0, 4).map((c) => {
                    const liveRows = c.id === "security" ? liveSecurity : c.id === "optimization" ? liveOptimization : null;
                    if (liveRows) {
                        const needs = liveRows.filter((r) => r.attention === "Needs attention").length;
                        const partial = c.id === "security" ? securityPartial : null;
                        return <KpiTile key={c.id} label={`${c.label} \u00b7 live`} value={String(needs)} sub={`need attention in Database Hub, ${liveRows.length - needs} recommended${partial ? `; partial: ${partial}` : ""}`} status={needs > 0 ? "Warning" : partial ? null : "Pass"} onOpen={() => setTab(c.id)} openLabel={`Show the ${c.label.toLowerCase()} checks`} />;
                    }
                    return <KpiTile key={c.id} label={c.label} value={String(count(c.id))} sub={c.description} status={worstStatus(rows.filter((r) => r.category === c.id && r.statusSort <= 3).map((r) => r.status))?.name ?? null} onOpen={() => setTab(c.id)} openLabel={`Show the ${c.label.toLowerCase()} findings`} />;
                })}
            </section>

            <TabList selectedValue={tab} onTabSelect={(_, d) => setTab(d.value as FindingCategory | "all")} aria-label="Finding categories" size="small">
                <Tab value="all">{`All (${rows.length})`}</Tab>
                {FINDING_CATEGORIES.map((c) => (
                    <Tab key={c.id} value={c.id}>{`${c.label} (${count(c.id)}${c.id === "security" && liveSecurity ? ` \u00b7 ${liveSecurity.length} live` : c.id === "optimization" && liveOptimization ? ` \u00b7 ${liveOptimization.length} live` : ""})`}</Tab>
                ))}
            </TabList>

            {tab === "security" ? <LiveChecks tab="security" rows={liveSecurity ?? []} answers={[security.answer, inventory.answer]} missed={[security.missed, inventory.missed]} loading={security.loading || inventory.loading} unavailable={security.unavailable ?? inventory.unavailable} off={liveOff} onRefresh={() => (security.refresh(), inventory.refresh())} hubUrl={hubUrl} /> : null}
            {tab === "optimization" ? (
                <>
                    <MigrationCard className="span-12" resourceName={t2Instance(t2)} />

                    <LiveChecks tab="optimization" rows={liveOptimization ?? []} answers={[inventory.answer]} missed={[inventory.missed]} loading={inventory.loading} unavailable={inventory.unavailable} off={liveOff} onRefresh={inventory.refresh} hubUrl={hubUrl} />
                </>
            ) : null}
            <VisualCard
                id={`findings.${tab}`}
                title={tab === "all" ? "Every finding" : CATEGORY_LABEL[tab]}
                subtitle={(tab === "security" || tab === "optimization") && !liveOff ? "From the history, beside Database Hub's live view: the latest capture of each finding in the period." : "The latest capture of each finding in the period. Sort, filter, and export."}
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
