import { useMemo } from "react";
import { BookOpen, Copy, ExternalLink, Gauge, LayoutDashboard, Radio } from "lucide-react";

import { useApp } from "@/app-context";
import { VisualCard } from "@/components/VisualCard";
import { probeQuery } from "@/data/queries";
import { useQuery } from "@/data/use-query";
import { copyText } from "@/lib/clipboard";
import { formatDateTimeUtc, formatNumber } from "@/lib/format";
import { appItemUrl } from "@/lib/runtime-config";

interface LinkCard {
    key: string;
    title: string;
    what: string;
    href?: string;
    icon: typeof Radio;
    missing: string;
}

export default function LinksPage() {
    const { runtime, meta, notify, embedded } = useApp();
    const probeSpec = useMemo(() => probeQuery(), []);
    const probe = useQuery(probeSpec);
    const row = probe.data?.rows[0];
    const itemUrl = appItemUrl(runtime.portalUrl, runtime.workspaceId, runtime.itemId, runtime.tenantId);
    const cards: LinkCard[] = [
        {
            key: "hub",
            title: "Database Hub",
            what: "The live estate: inventory, performance, and the Database Agent, straight from the telemetry endpoint. Free, no capacity.",
            href: runtime.links.databaseHub,
            icon: Radio,
            missing: "Open Database Hub from the Fabric portal's Workloads.",
        },
        {
            key: "rtd",
            title: "Real-Time Dashboard",
            what: "RTD_DatabaseHub_LiveView: the same live telemetry as code, refreshed every minute, for a second screen during an incident.",
            href: runtime.links.realTimeDashboard,
            icon: Gauge,
            missing: "Not found at deploy time: run ./scripts/configure-fabric.ps1 -ImportDashboard, then redeploy this app.",
        },
        {
            key: "report",
            title: "Power BI report",
            what: "RPT_DatabaseHub_History: the same history model as four governed report pages, for sharing and printing.",
            href: runtime.links.report,
            icon: LayoutDashboard,
            missing: "Not found at deploy time: run ./scripts/configure-powerbi.ps1, then redeploy this app.",
        },
    ];

    return (
        <div className="page">
            <header className="page-head">
                <div>
                    <h2>
                        Live is <span className="gradient-text">elsewhere</span>
                    </h2>
                    <p>
                        This app is history: it reads the lakehouse snapshots that NB_DatabaseHub_LiveActivity writes, through the semantic model SM_DatabaseHub_History. The live view is Database Hub plus
                        the Real-Time Dashboard. Each link opens in a new browser tab.
                    </p>
                </div>
            </header>

            <div className="links span-12">
                {cards.map((c) => (
                    <article key={c.key} className="link-card glass">
                        <c.icon aria-hidden="true" className="link-icon" />
                        <h3>{c.title}</h3>
                        <p>{c.what}</p>
                        {c.href ? (
                            <a className="btn-primary" href={c.href} target="_blank" rel="noopener noreferrer">
                                Open in a new tab <ExternalLink aria-hidden="true" width={16} height={16} />
                            </a>
                        ) : (
                            <p className="gate-muted">{c.missing}</p>
                        )}
                    </article>
                ))}
            </div>

            <section className="card glass span-7" aria-labelledby="path-title">
                <h3 id="path-title">How the history gets here</h3>
                <ol className="data-path">
                    <li>
                        <strong>Telemetry endpoint</strong>
                        <span>T1, T2, and T3 report performance telemetry (kept 7 days).</span>
                    </li>
                    <li>
                        <strong>NB_DatabaseHub_LiveActivity</strong>
                        <span>The notebook analyzes a window and writes snapshots, findings, and incident windows.</span>
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
                        <span>Read-only DAX through the semantic model connector, as you (delegated), never writing anything.</span>
                    </li>
                </ol>
                <p className="dax-meta">
                    {meta?.latestCapture ? `Newest snapshot ${formatDateTimeUtc(meta.latestCapture)} · ${formatNumber(meta.notebookRuns, "int")} notebook runs captured` : "No snapshot yet."}
                </p>
            </section>

            <VisualCard
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
            >
                {row ? (
                    <p className="gate-ok" data-testid="probe-ok">
                        ✓ Connector check passed: {formatNumber(row.ValidationRows, "int")} validation checks, {formatNumber(row.SnapshotRows, "int")} telemetry rows, and{" "}
                        {formatNumber(row.Incidents, "int")} incident windows in SM_DatabaseHub_History.
                    </p>
                ) : null}
                <dl className="kv">
                    <dt>Opened</dt>
                    <dd>{embedded ? "Inside the Fabric portal (signed in through the portal)" : "Directly in a browser tab"}</dd>
                    {runtime.links.workspace ? (
                        <>
                            <dt>The demo workspace</dt>
                            <dd>
                                <a href={runtime.links.workspace} target="_blank" rel="noopener noreferrer">
                                    Open in a new tab
                                </a>
                            </dd>
                        </>
                    ) : null}
                    <dt>This app's item page</dt>
                    <dd>
                        <a href={itemUrl} target="_blank" rel="noopener noreferrer">
                            Open in Fabric
                        </a>{" "}
                        <button type="button" className="icon-btn" aria-label="Copy the link to this app's item page" onClick={async () => notify((await copyText(itemUrl)) ? "Link copied" : "Copy is blocked here")}>
                            <Copy aria-hidden="true" />
                        </button>
                    </dd>
                </dl>
                <p className="gate-muted">
                    Inside the portal the app has no address bar of its own, so a link opens the app's home page; the app remembers your last view in this browser.
                </p>
            </VisualCard>

            <section className="card glass span-12" aria-labelledby="about-title">
                <h3 id="about-title">
                    <BookOpen aria-hidden="true" width={18} height={18} /> About this app
                </h3>
                <ul className="about">
                    <li>Fabric Apps is a preview. This app is read-only toward the demo: no controls, no writes to the targets, Azure, the lakehouse, or the model.</li>
                    <li>Open it from its item in the Fabric workspace. Opening the hosted address directly is a known preview limitation (its sign-in pop-up can lose its link back).</li>
                    <li>It runs on the workspace's Fabric capacity and uses its capacity units, outside the demo's Azure budget.</li>
                    <li>Every visual can show its DAX, copy it, show its data as a table, and download it as CSV. Insights are rules over the query results; no external AI service.</li>
                </ul>
            </section>
        </div>
    );
}
