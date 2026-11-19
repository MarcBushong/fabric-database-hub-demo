// T2's migration assessment, the "ready to migrate" moment (2026-11-18): live from Database Hub's inventory, which
// carries its readiness for each Azure SQL target, and the Azure portal's path when the app doesn't read it live.
// Database Hub doesn't raise a ready assessment as an issue, so this card is where it shows; it never says otherwise.

import { Badge, Button, MessageBar, MessageBarBody } from "@fluentui/react-components";
import { Open16Regular, Sparkle16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import type { ColumnSpec } from "@/data/queries";
import { liveDataOf, useLiveEstate } from "@/data/live-estate";
import { buildAskContext } from "@/lib/ask";
import { formatDateTimeUtc, sentence } from "@/lib/format";
import { liveMigrations, migrationSentence, type MigrationTargetRow } from "@/lib/live-findings";
import { ProvenanceBadge } from "./ProvenanceBadge";
import { VisualCard } from "./VisualCard";

const COLUMNS: ColumnSpec[] = [
    { key: "azureTarget", label: "Azure SQL target", kind: "text" },
    { key: "readiness", label: "Readiness", kind: "text" },
    { key: "resource", label: "SQL Server instance", kind: "text" },
];

const ASK = "Which of my servers can move to Azure, and to what?";

const badgeColor = (readiness: string) => (readiness === "Ready" ? "success" : readiness === "Not ready" ? "warning" : "informative");

export function MigrationCard({ className = "span-12", resourceName = "arcsql01" }: { className?: string; resourceName?: string }) {
    const { runtime, view } = useApp();
    const copilot = useCopilot();
    const inventory = useLiveEstate("inventory");
    const answer = inventory.answer;
    const all = liveMigrations(liveDataOf(answer));
    const m = all.find((x) => x.target === "T2") ?? all[0] ?? null;
    const name = m?.resource ?? resourceName;
    const portalUrl = runtime.links.t2MigrationAssessment;
    const path = `In the Azure portal, open ${name}, then, under Migration, select Assessments.`;
    const portal = portalUrl ? (
        <Button as="a" size="small" href={portalUrl} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
            {`${name} in the Azure portal`}
        </Button>
    ) : null;

    if (!answer && !inventory.loading) {
        return (
            <section className={`panel ${className} live-panel`} aria-label="T2's migration assessment">
                <h3>{`T2's migration assessment: ${name}`}</h3>
                <p className="muted live-off">
                    <ProvenanceBadge provenance="live" liveState="unavailable" />
                    {` ${sentence(inventory.unavailable ?? "this app has no live source")} ${path}`}
                </p>
                <p className="panel-sub">
                    {`Azure Arc assesses ${name} every week for Azure SQL Managed Instance, SQL Server on Azure Virtual Machines, and Azure SQL Database: its readiness for each, the recommended target and size, and a monthly estimate. The status page's T2.ARC.MIGRATIONASSESSMENT says when it last uploaded.`}
                </p>
                {portal ? <div>{portal}</div> : null}
            </section>
        );
    }

    const live = answer ? { at: answer.at, source: answer.source, errors: answer.errors } : null;
    const rows: MigrationTargetRow[] = m?.rows ?? [];
    const results = m !== null && m.hasResults;
    const askWhy = (row: MigrationTargetRow) =>
        copilot.ask(
            buildAskContext({
                title: `${name}: ${row.azureTarget}`,
                page: view.page,
                visualId: "migration.readiness",
                rows,
                columns: COLUMNS,
                prompt: `Why isn't ${name} ready for ${row.azureTarget}, and what would make it ready? Its assessment: ${m ? migrationSentence(m) : ""}`,
                provenance: "live",
                meta: null,
                ...(live ? { asOf: live.at } : {}),
            }),
        );

    return (
        <VisualCard
            id="migration.readiness"
            className={className}
            title={results && m.ready.length > 0 ? `Ready to migrate: ${name}` : `Migration assessment: ${name}`}
            subtitle={
                results
                    ? `${m.type} (T2), assessed by Azure Arc every week${m.uploadedAt ? `; this assessment was uploaded ${formatDateTimeUtc(m.uploadedAt)}` : ""}. From Database Hub's inventory.`
                    : `${name}'s readiness for each Azure SQL target, from Database Hub's inventory.`
            }
            specs={[]}
            live={live}
            loading={inventory.loading}
            empty={!inventory.loading && !results}
            emptyText={
                <div className="migration-empty">
                    <strong>{m && !m.enabled ? `Migration assessment is off for ${name}.` : `No migration assessment for ${name} in Database Hub's inventory yet.`}</strong>
                    <span>{`./scripts/deploy.ps1 turns it on for ${name} and starts its first run; the status page's T2.ARC.MIGRATIONASSESSMENT says when it uploaded. Then Azure Arc runs it every Sunday at 23:00 on ${name}'s clock. ${path}`}</span>
                </div>
            }
            table={{ columns: COLUMNS, rows, caption: `${name}: readiness per Azure SQL target` }}
            summary={m ? `${name}: ${migrationSentence(m)}` : `No migration assessment for ${name}.`}
            askPrompt={ASK}
            onRefresh={inventory.refresh}
            toolbar={portal}
        >
            {m ? (
                <div className="migration">
                    {/^stale$/i.test(m.dataStatus) ? (
                        <MessageBar intent="warning">
                            <MessageBarBody>{`Database Hub marks this assessment as stale${m.uploadedAt ? `: it was uploaded ${formatDateTimeUtc(m.uploadedAt)}` : ""}. Azure Arc runs a new one every Sunday at 23:00 on ${name}'s clock; Run assessment in the portal starts one now.`}</MessageBarBody>
                        </MessageBar>
                    ) : null}
                    <p className="migration-headline">{migrationSentence(m)}</p>
                    <ul className="migration-targets" aria-label="Readiness per Azure SQL target">
                        {rows.map((row) => (
                            <li key={row.id}>
                                <Badge appearance="tint" color={badgeColor(row.readiness)}>
                                    {row.readiness}
                                </Badge>
                                <span>{row.azureTarget}</span>
                                {row.readiness === "Not ready" ? (
                                    <Button size="small" appearance="transparent" className="ask-why" icon={<Sparkle16Filled />} onClick={() => askWhy(row)}>
                                        Ask why
                                    </Button>
                                ) : null}
                            </li>
                        ))}
                    </ul>
                    <p className="muted">{`A ready assessment isn't an issue, so Database Hub's issue lists don't show it. The details, with the recommended target, its size, and a monthly estimate: ${path.charAt(0).toLowerCase()}${path.slice(1)}`}</p>
                </div>
            ) : null}
        </VisualCard>
    );
}
