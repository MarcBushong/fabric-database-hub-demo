// The Root cause view (ADR 0031): the incidents the blind detector found in the history, and for the one selected, its root
// cause with the evidence and times, the blocking chain head blocker first, the timeline, the errors, the recommendations,
// the next steps, and what wasn't captured. It reads only what a DBA's tools would show: the RCA capture, Database Hub's
// telemetry, and Azure Monitor's metrics. Shown only when the history model has the RCA tables.

import { useContext, useEffect, useMemo, useState } from "react";
import { Button, Spinner } from "@fluentui/react-components";
import { Sparkle20Filled, Warning20Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { EmptyState } from "@/components/EmptyState";
import { ProvenanceBadge } from "@/components/ProvenanceBadge";
import { useCopilot } from "@/copilot/use-copilot";
import type { QuerySpec } from "@/data/queries";
import { QueryClientContext } from "@/data/use-query";
import { buildAskContext } from "@/lib/ask";
import { Stage } from "@/mission/Stage";
import { createRcaClient } from "@/rca/client";
import type { DaxLog } from "@/rca/loader";
import { bothTimes } from "@/rca/time";
import { EXPLAINED_FAMILIES } from "@/rca/tools";
import type { InvestigationResult } from "@/rca/types";
import { episodeOf } from "@/rca/view/facts";
import { RcaReport } from "@/rca/view/RcaReport";
import { parseSelection } from "@/rca/view/selection";

import "@/mission/mission.css";
import "@/rca/view/rca.css";

/** A result with the key it was loaded for: a newer key means it's loading again (no state set inside an effect). */
type Keyed<T> = { key: string; value?: T; error?: string };

const asResult = (value: InvestigationResult | string): InvestigationResult => {
    if (typeof value === "string") throw new Error(value);
    return value;
};

const message = (err: unknown) => (err instanceof Error ? err.message : String(err));

export default function RcaPage() {
    const { view, setView, navigate, provenance, meta, rca } = useApp();
    const queryClient = useContext(QueryClientContext);
    const copilot = useCopilot();
    const client = useMemo(() => (queryClient ? createRcaClient(queryClient) : null), [queryClient]);
    const selection = useMemo(() => parseSelection(view.incident), [view.incident]);
    const [list, setList] = useState<Keyed<InvestigationResult> | null>(null);
    const [report, setReport] = useState<Keyed<{ incident: InvestigationResult; errors: InvestigationResult | null; logs: DaxLog[] }> | null>(null);

    // The incidents in the selected window, or in the history's newest 90 minutes.
    const listKey = JSON.stringify(selection?.kind === "window" ? { from: selection.from.toISOString(), to: selection.to.toISOString(), targets: [selection.target] } : {});
    useEffect(() => {
        if (rca !== true || !client) return;
        let alive = true;
        client
            .tools()
            .then((tools) => tools.investigate("find_incidents", JSON.parse(listKey) as Record<string, unknown>))
            .then(asResult)
            .then(
                (value) => alive && setList({ key: listKey, value }),
                (err: unknown) => alive && setList({ key: listKey, error: message(err) }),
            );
        return () => {
            alive = false;
        };
    }, [client, listKey, rca]);

    const listed = list && list.key === listKey ? list : null;
    // The incidents with the richest evidence first: the capture's own (a blocking chain, the replica's stall), then the
    // others the investigations explain (errors, throttling), then the telemetry-only ones, each group in time order.
    const episodes = useMemo(() => {
        const rank = (e: { family: string; source: string }) => (e.source === "the RCA capture" ? 2 : EXPLAINED_FAMILIES.includes(e.family) ? 1 : 0);
        return [...(listed?.value?.episodes ?? [])].sort((a, b) => rank(b) - rank(a) || a.start.localeCompare(b.start));
    }, [listed]);
    const selectedKey = selection?.kind === "episode" ? selection.key : (episodes[0]?.key ?? null);
    const selected = episodes.find((e) => e.key === selectedKey) ?? null;
    const fallbackTarget = selection?.target ?? "T1";

    useEffect(() => {
        if (rca !== true || !client || !selectedKey) return;
        let alive = true;
        (async () => {
            client.drainLogs();
            const tools = await client.tools();
            const incident = asResult(await tools.investigate("explain_incident", { episodeKey: selectedKey }));
            const facts = episodeOf(incident);
            const start = new Date(facts?.start ?? incident.window.fromUtc);
            const end = new Date(facts?.end ?? incident.window.toUtc);
            const errors = await tools.investigate("explain_errors", {
                from: new Date(start.getTime() - 2 * 60000).toISOString(),
                to: new Date(end.getTime() + 2 * 60000).toISOString(),
                targets: [facts?.target ?? fallbackTarget],
            });
            return { incident, errors: typeof errors === "string" ? null : errors, logs: client.drainLogs() };
        })().then(
            (value) => alive && setReport({ key: selectedKey, value }),
            (err: unknown) => alive && setReport({ key: selectedKey, error: message(err) }),
        );
        return () => {
            alive = false;
        };
    }, [client, rca, selectedKey, fallbackTarget]);

    const shown = report && report.key === selectedKey ? report : null;
    const logs = shown?.value?.logs ?? [];
    const explain = () => {
        if (!selectedKey) return;
        const specs: QuerySpec[] = logs.map((l, i) => ({ id: `rca-${i}`, title: l.table, dax: l.query, rowLimit: 0, columns: [] }));
        copilot.ask(
            buildAskContext({
                title: selected ? `Root cause: ${selected.signal} on ${selected.target}` : "Root cause",
                page: "rca",
                visualId: "rca.incident",
                specs,
                prompt: `Explain the incident ${selectedKey}: call explain_incident with that key, then give the root cause with its evidence and times, the recommendations with who approves each, the next steps, and what wasn't captured.`,
                provenance,
                meta,
            }),
        );
    };

    const timeZone = client?.timeZone ?? "UTC";
    let body;
    if (rca === false) {
        body = (
            <EmptyState icon={<Warning20Regular />} title="No RCA capture is recorded yet">
                <p>
                    The history model reads the Incident RCA's tables once the lakehouse has them, and the next session saved after the update creates them. Until then the rest of the app works as before. In this environment,
                    FABRIC.SEMANTICMODEL.RCA in the deployment's results says what adds them.
                </p>
            </EmptyState>
        );
    } else if (rca !== true || !listed) {
        body = (
            <div className="page-loading">
                <Spinner size="small" label="Finding the incidents in the history" />
            </div>
        );
    } else if (!listed.value) {
        body = (
            <EmptyState title="The incidents couldn't load">
                <p>{listed.error}</p>
            </EmptyState>
        );
    } else {
        const found = listed.value;
        body = (
            <div className="rca-layout">
                <aside className="rca-panel" aria-labelledby="rca-list-title">
                    <h2 id="rca-list-title">Incidents the detector found</h2>
                    <p className="rca-muted" style={{ marginTop: 0 }}>
                        {found.window.local ?? `${found.window.fromUtc} to ${found.window.toUtc}`}
                    </p>
                    {episodes.length > 0 ? (
                        <ul className="rca-episodes">
                            {episodes.map((e) => (
                                <li key={e.key}>
                                    <button type="button" className="rca-episode" aria-current={e.key === selectedKey ? "true" : undefined} onClick={() => setView({ incident: e.key })}>
                                        <strong>
                                            {e.target}: {e.signal}
                                        </strong>
                                        <span className="rca-muted">
                                            {bothTimes(new Date(e.start), timeZone)} · peak {e.peak}
                                        </span>
                                        <span className="rca-muted">
                                            {e.support}, in {e.source}
                                        </span>
                                    </button>
                                </li>
                            ))}
                        </ul>
                    ) : (
                        <p>Nothing abnormal in these minutes: the detector found no episode.</p>
                    )}
                    {selection?.kind === "window" ? (
                        <p style={{ marginBottom: 0 }}>
                            <Button size="small" appearance="subtle" onClick={() => setView({ incident: null })}>
                                The newest 90 minutes instead
                            </Button>
                        </p>
                    ) : null}
                </aside>
                <div>
                    {!selectedKey ? (
                        <section className="rca-panel">
                            <h2>Nothing to explain</h2>
                            <ul className="rca-list">
                                {found.notCaptured.map((s) => (
                                    <li key={s}>{s}</li>
                                ))}
                            </ul>
                        </section>
                    ) : shown?.value ? (
                        <RcaReport incident={shown.value.incident} errors={shown.value.errors} timeZone={timeZone} logs={logs} />
                    ) : shown?.error ? (
                        <EmptyState title="This incident couldn't be explained">
                            <p>{shown.error}</p>
                        </EmptyState>
                    ) : (
                        <div className="page-loading">
                            <Spinner size="small" label="Investigating the incident" />
                        </div>
                    )}
                </div>
            </div>
        );
    }

    return (
        <div className="page rca-page">
            <Stage className="span-12 mc-stage" label="Root cause">
                <header className="mc-head">
                    <div className="mc-titles">
                        <p className="mc-kicker">ContosoCare · Root cause</p>
                        <h1>{selected ? `${selected.target}: ${selected.signal}` : "Why it happened"}</h1>
                        <p className="mc-asof">
                            <ProvenanceBadge provenance={provenance} asOf={meta?.latestCapture} />
                            <span>Found the way a DBA's tools would: from what the capture and the telemetry recorded, with nothing about what anyone planned.</span>
                        </p>
                    </div>
                    <div className="mc-actions">
                        <Button size="small" appearance="primary" icon={<Sparkle20Filled />} disabled={!shown?.value} onClick={explain}>
                            Explain this incident
                        </Button>
                        <Button size="small" onClick={() => navigate("incidents")}>
                            Incidents
                        </Button>
                    </div>
                </header>
                {body}
            </Stage>
        </div>
    );
}
