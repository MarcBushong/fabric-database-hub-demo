import { useMemo } from "react";
import { Button, Tooltip } from "@fluentui/react-components";
import { Board20Regular, Copy16Regular, Database20Regular, DocumentTable20Regular, Gauge20Regular, Open16Regular, PlayCircle20Regular } from "@fluentui/react-icons";
import type { ReactNode } from "react";

import { useApp } from "@/app-context";
import { VisualCard } from "@/components/VisualCard";
import { liveOffText, useLiveOff } from "@/data/live-estate";
import { probeQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { hubUrlOf } from "@/lib/agent-prompts";
import { copyText } from "@/lib/clipboard";
import { formatDateTimeUtc, formatNumber } from "@/lib/format";
import { appItemUrl } from "@/lib/runtime-config";
import { PageHeader } from "@/shell/PageHeader";

interface LinkCard {
    key: string;
    title: string;
    what: string;
    href?: string;
    icon: ReactNode;
    missing: string;
}

export default function LinksPage() {
    const { runtime, meta, notify, embedded } = useApp();
    const probeSpec = useMemo(() => probeQuery(), []);
    const probe = useQuery(probeSpec);
    const row = probe.data?.rows[0];
    // While Database Hub refuses the app as a whole (R924), the pages hide their live parts and this line says why.
    const liveOff = useLiveOff();
    const itemUrl = appItemUrl(runtime.portalUrl, runtime.workspaceId, runtime.itemId, runtime.tenantId);
    const hub = hubUrlOf(runtime);
    const cards: LinkCard[] = [
        {
            key: "hub",
            title: "Database Hub",
            what: "The live estate: Overview's what needs attention, Estate, Performance, Security, and Optimization, plus the Database Agent. Its views need no capacity.",
            href: hub,
            icon: <Database20Regular />,
            missing: "Open Database Hub from the Fabric portal's Workloads.",
        },
        {
            key: "rtd",
            title: "Real-Time Dashboard",
            what: "RTD_DatabaseHub_LiveView: the live telemetry as code, refreshed every minute, for a second screen during an incident.",
            href: runtime.links.realTimeDashboard,
            icon: <Gauge20Regular />,
            missing: "Not found at deploy time: ./scripts/deploy.ps1 imports it, then redeploys this app.",
        },
        {
            key: "report",
            title: "Power BI report",
            what: "RPT_DatabaseHub_History: the same history model as governed report pages, for sharing and printing.",
            href: runtime.links.report,
            icon: <DocumentTable20Regular />,
            missing: "Not found at deploy time: ./scripts/deploy.ps1 deploys it, then redeploys this app.",
        },
        {
            key: "control",
            title: "The control notebook",
            what: "NB_DatabaseHub_Control: Run all runs a whole session, from the start to the stop, and saves its history here.",
            href: runtime.links.controlNotebook,
            icon: <PlayCircle20Regular />,
            missing: "Open the control workspace in Fabric and select NB_DatabaseHub_Control.",
        },
        {
            key: "workspace",
            title: "The demo's workspace",
            what: "Every Fabric item of the demo: the lakehouse, the notebooks, the model, the report, the dashboard, and this app.",
            href: runtime.links.workspace,
            icon: <Board20Regular />,
            missing: "Open the demo's workspace from the Fabric portal.",
        },
    ];

    return (
        <div className="page">
            <PageHeader title="Live views" description="This app is the estate's history; the live view is Database Hub and the real-time dashboards. Each link opens in a new tab." filter={false} />
            {liveOff ? <p className="live-off muted">{liveOffText(liveOff)}</p> : null}

            <section className="link-cards span-12" aria-label="Live views">
                {cards.map((c) => (
                    <article key={c.key} className="link-card">
                        <h3>
                            <span aria-hidden="true">{c.icon}</span>
                            {c.title}
                        </h3>
                        <p>{c.what}</p>
                        {c.href ? (
                            <div className="link-go">
                                <Button as="a" href={c.href} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after" aria-label={`${c.title}: open in a new tab`}>
                                    Open in a new tab
                                </Button>
                            </div>
                        ) : (
                            <p className="muted link-go">{c.missing}</p>
                        )}
                    </article>
                ))}
            </section>

            <section className="panel span-7" aria-labelledby="path-title">
                <h3 id="path-title">How the history gets here</h3>
                <ol className="data-path">
                    <li>
                        <strong>Database Hub's telemetry</strong>
                        <span>T1, T2, and T3 report performance telemetry, kept 7 days.</span>
                    </li>
                    <li>
                        <strong>Azure Monitor</strong>
                        <span>T4's and its read replica's metrics, which a session's end captures and passes to the notebook.</span>
                    </li>
                    <li>
                        <strong>NB_DatabaseHub_LiveActivity</strong>
                        <span>Analyzes a window and writes snapshots, findings, and incident windows.</span>
                    </li>
                    <li>
                        <strong>LH_DatabaseHub</strong>
                        <span>Delta tables keep the history past the telemetry's retention.</span>
                    </li>
                    <li>
                        <strong>SM_DatabaseHub_History</strong>
                        <span>The Direct Lake model: the same measures as the Power BI report.</span>
                    </li>
                    <li>
                        <strong>This app</strong>
                        <span>Read-only DAX through the semantic model connector, as you (delegated).</span>
                    </li>
                </ol>
                <p className="muted">{meta?.latestCapture ? `Newest snapshot ${formatDateTimeUtc(meta.latestCapture)} · ${formatNumber(meta.notebookRuns, "int")} notebook runs saved` : "No snapshot yet."}</p>
            </section>

            <VisualCard
                id="links.connection"
                className="span-5"
                title="Connection check"
                subtitle="One DAX query through the connector proves sign-in, the connector, and your access to the model."
                specs={[probeSpec]}
                loading={probe.loading}
                error={probe.error}
                table={probe.data ? { columns: probeSpec.columns, rows: probe.data.rows, caption: "Connector check" } : null}
                summary={row ? `Connector check passed: ${String(row.ValidationRows)} validation checks, ${String(row.SnapshotRows)} telemetry rows, ${String(row.Incidents)} incident windows.` : "Connector check."}
                fetchedAt={probe.data?.fetchedAt}
                onRefresh={probe.refetch}
                quiet
            >
                {row ? (
                    <p className="ok-line" data-testid="probe-ok">
                        ✓ Connector check passed: {formatNumber(row.ValidationRows, "int")} validation checks, {formatNumber(row.SnapshotRows, "int")} telemetry rows, and {formatNumber(row.Incidents, "int")} incident windows in
                        SM_DatabaseHub_History.
                    </p>
                ) : null}
                <dl className="kv">
                    <dt>Opened</dt>
                    <dd>{embedded ? "Inside the Fabric portal" : "Directly in a browser tab"}</dd>
                    <dt>This app's item page</dt>
                    <dd>
                        <a href={itemUrl} target="_blank" rel="noopener noreferrer">
                            Open in Fabric
                        </a>{" "}
                        <Tooltip content="Copy the link to this app's item page" relationship="label">
                            <Button size="small" appearance="subtle" icon={<Copy16Regular />} onClick={async () => notify((await copyText(itemUrl)) ? "Link copied" : "Copy is blocked here", "info")} />
                        </Tooltip>
                    </dd>
                </dl>
                <p className="muted">Inside the portal the app has no address bar of its own, so a link opens the app's home page; the app remembers your last view in this browser.</p>
            </VisualCard>

            <section className="panel span-12" aria-labelledby="about-title">
                <h3 id="about-title">About this app</h3>
                <ul className="confirm-list">
                    <li>Fabric Apps is a preview. The app reads the history as you, through the read-only semantic model connector.</li>
                    <li>Open it from its item in the Fabric workspace. Opening the hosted address directly is a known preview limitation.</li>
                    <li>It runs on the workspace's Fabric capacity and uses its capacity units, outside the demo's Azure budget.</li>
                    <li>Every visual can show its DAX, its data as a table, and download it as CSV, and every visual has Ask Copilot.</li>
                </ul>
            </section>
        </div>
    );
}
