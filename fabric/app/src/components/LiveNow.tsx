// What Database Hub shows right now, beside the history: the estate's resources, high usage in the last 24 hours,
// security warnings, and Cosmos DB, read live through the app's function (cached for a minute, shared with the dock).

import { Button, Popover, PopoverSurface, PopoverTrigger, Spinner, Tooltip } from "@fluentui/react-components";
import { ArrowClockwise16Regular, Code16Regular, Sparkle16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import { useLiveEstate, type EstateAnswer, type EstateView, type HealthData, type UsageCounts } from "@/data/live-estate";
import { formatNumber } from "@/lib/format";
import { inventoryMix, liveSecurityRows, targetOfResource } from "@/lib/live-findings";
import { KpiTile } from "./KpiTile";
import { ProvenanceBadge } from "./ProvenanceBadge";

/** The states Database Hub reports for a resource that's up. */
const UP = /^(online|ready|connected|running|succeeded|available)$/i;

function usage(u: UsageCounts | null | undefined): number {
    return u ? u.cpu + u.memory + u.storage : 0;
}

/** "SQL: CPU 1", naming only the nonzero counts; null when there are none. */
function usageText(name: string, u: UsageCounts | null | undefined): string | null {
    if (!u) return null;
    const parts = ([["CPU", u.cpu], ["memory", u.memory], ["storage", u.storage]] as const).filter(([, n]) => n > 0).map(([k, n]) => `${k} ${n}`);
    return parts.length > 0 ? `${name}: ${parts.join(", ")}` : null;
}

export function LiveNow() {
    const { navigate } = useApp();
    const copilot = useCopilot();
    const inventory = useLiveEstate("inventory");
    const health = useLiveEstate("health");
    const security = useLiveEstate("security");
    const answers: Array<EstateAnswer<EstateView>> = [inventory.answer, health.answer, security.answer].filter((a) => a !== null);
    const loading = inventory.loading || health.loading || security.loading;

    if (answers.length === 0 && !loading) {
        const reason = inventory.unavailable ?? health.unavailable ?? security.unavailable;
        return (
            <p className="live-off muted span-12">
                <ProvenanceBadge provenance="live" compact />
                {` Not read live here: ${reason ?? "no live source"}. Every page shows the history; Database Hub has the live view.`}
            </p>
        );
    }

    const inv = inventory.answer?.data;
    const h: HealthData | undefined = health.answer?.data;
    const down = (inv?.resources ?? []).filter((r) => r.status && !UP.test(r.status));
    const warnings = security.answer || inventory.answer ? liveSecurityRows(security.answer?.data, inv).filter((r) => r.attention === "Needs attention") : null;
    const high = h ? usage(h.microsoftSql?.highUsage) + usage(h.postgreSql?.highUsage) : null;
    const cosmos = h?.cosmosDb && h.cosmosDb.totalAccounts > 0 ? h.cosmosDb : null;
    const at = answers.map((a) => a.at).sort()[0];
    const routes = answers.flatMap((a) => a.source);
    const failed = answers.flatMap((a) => a.errors);

    const rows = [
        { signal: "Resources", value: inv?.totalCount ?? null, detail: inventoryMix(inv, true) },
        ...down.map((r) => ({ signal: "Not up", value: r.status ?? "", detail: `${r.name} (${targetOfResource(r) || r.databaseType})` })),
        { signal: "High-usage signals, last 24 hours", value: high, detail: [usageText("Microsoft SQL", h?.microsoftSql?.highUsage), usageText("PostgreSQL", h?.postgreSql?.highUsage)].filter(Boolean).join("; ") },
        { signal: "Security warnings", value: warnings?.length ?? null, detail: (warnings ?? []).map((w) => `${w.resource}: ${w.check}`).join("; ") },
        ...(cosmos ? [{ signal: "Cosmos DB, peak normalized RU (%)", value: cosmos.maximumNormalizedRu, detail: `lowest availability ${cosmos.minimumServiceAvailability ?? "n/a"} %` }] : []),
    ];

    const ask = () =>
        copilot.ask({
            title: "Live now, from Database Hub",
            page: "overview",
            visualId: "overview.live",
            prompt: "What does Database Hub show right now about the demo's databases, and what should I look at first?",
            rows,
            source: "live",
            ...(at ? { asOf: at } : {}),
        });

    return (
        <section className="live-now span-12" aria-labelledby="live-now-title" aria-busy={loading}>
            <header className="live-now-head">
                <h2 id="live-now-title" className="section-title">
                    Live now
                </h2>
                {at ? <ProvenanceBadge provenance="live" asOf={new Date(at)} /> : <ProvenanceBadge provenance="live" compact />}
                {loading ? <Spinner size="extra-tiny" label="Reading Database Hub: a first read takes 5 to 12 seconds" labelPosition="after" /> : null}
                {failed.length > 0 ? <span className="vcard-partial">{`Partial: ${failed.length} API calls failed`}</span> : null}
                <span className="live-now-tools">
                    <Button size="small" appearance="subtle" className="ask-copilot" icon={<Sparkle16Filled />} onClick={ask} disabled={answers.length === 0}>
                        Ask Copilot
                    </Button>
                    <Popover withArrow>
                        <PopoverTrigger disableButtonEnhancement>
                            <Tooltip content="The Database Hub API calls behind these tiles" relationship="label">
                                <Button size="small" appearance="subtle" icon={<Code16Regular />} disabled={routes.length === 0} />
                            </Tooltip>
                        </PopoverTrigger>
                        <PopoverSurface aria-label="Database Hub API">
                            <pre className="vcard-routes">{[...routes, ...failed.map((e) => `failed: ${e}`)].join("\n")}</pre>
                        </PopoverSurface>
                    </Popover>
                    <Tooltip content="Read again" relationship="label">
                        <Button size="small" appearance="subtle" icon={<ArrowClockwise16Regular />} onClick={() => (inventory.refresh(), health.refresh(), security.refresh())} />
                    </Tooltip>
                </span>
            </header>
            <div className="kpis live-kpis">
                <KpiTile
                    label="Resources in Database Hub"
                    value={inv ? String(inv.totalCount) : "\u2013"}
                    sub={inv ? (down.length > 0 ? `${down.length} not up: ${down.map((r) => `${r.name} ${r.status}`).join(", ")}` : inventoryMix(inv)) : "Reading\u2026"}
                    status={inv ? (down.length > 0 ? "Warning" : "Pass") : null}
                    onOpen={() => navigate("estate")}
                    openLabel="Open the estate"
                />
                <KpiTile
                    label="High usage, last 24 hours"
                    value={high === null ? "\u2013" : String(high)}
                    sub={h ? [usageText("SQL", h.microsoftSql?.highUsage), usageText("PostgreSQL", h.postgreSql?.highUsage)].filter(Boolean).join(" \u00b7 ") || "None on SQL or PostgreSQL" : "Reading\u2026"}
                    status={high === null ? null : high > 0 ? "Warning" : "Pass"}
                    onOpen={() => navigate("performance")}
                    openLabel="Open performance"
                />
                <KpiTile
                    label="Security warnings"
                    value={warnings === null ? "\u2013" : String(warnings.length)}
                    sub={warnings === null ? "Reading\u2026" : warnings.length > 0 ? warnings.slice(0, 2).map((w) => `${w.resource.split("/").pop()}: ${w.check}`).join(" \u00b7 ") : "Authentication, auditing, and keys pass"}
                    status={warnings === null ? null : warnings.length > 0 ? "Warning" : "Pass"}
                    onOpen={() => navigate("findings", { category: "security" })}
                    openLabel="Show the live security checks"
                />
                {cosmos ? (
                    <KpiTile
                        label="Cosmos DB, last 24 hours"
                        value={cosmos.maximumNormalizedRu === null ? "\u2013" : formatNumber(cosmos.maximumNormalizedRu, "percent")}
                        sub={`peak normalized RU \u00b7 lowest availability ${cosmos.minimumServiceAvailability === null ? "n/a" : formatNumber(cosmos.minimumServiceAvailability, "percent")}`}
                        status={(cosmos.maximumNormalizedRu ?? 0) >= 100 ? "Warning" : "Pass"}
                        onOpen={() => navigate("estate", { target: "T5" })}
                        openLabel="Open T5"
                    />
                ) : null}
            </div>
        </section>
    );
}
