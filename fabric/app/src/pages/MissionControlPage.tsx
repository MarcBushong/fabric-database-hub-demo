// Mission Control (ADR 0030): the app's home. ContosoCare's services on a map, pulsing with their health from the
// history; the latest session's plan, as Scenario Runs recorded it at its end, with what showed and when; the big numbers;
// and one click to the replay, the postmortem, the kiosk, or Database Hub for the live view. The plan reaches the history
// only when its session ends, so nothing here pretends to be live.

import { useMemo, useState } from "react";
import { Button, Link, MessageBar, MessageBarBody } from "@fluentui/react-components";
import { DocumentText16Regular, Replay20Regular, Open16Regular, Trophy20Regular, Tv20Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { EmptyState } from "@/components/EmptyState";
import { ProvenanceBadge } from "@/components/ProvenanceBadge";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import type { ColumnSpec } from "@/data/queries";
import { hubUrlOf } from "@/lib/agent-prompts";
import { serviceOf } from "@/lib/business";
import { formatDateTimeUtc, formatDayUtc, formatNumber, formatTimeUtc } from "@/lib/format";
import type { PostmortemInput } from "@/lib/postmortem";
import { minutesText, summarize } from "@/lib/scoreboard";
import { statusMeta } from "@/lib/status";
import type { EstateTarget } from "@/lib/view-state";
import { GlobalFilter } from "@/shell/GlobalFilter";
import { enterFullscreen } from "@/mission/kiosk";
import { mapNodes } from "@/mission/nodes";
import { BigStat, LensSwitch, PlanPicker } from "@/mission/parts";
import { PostmortemDialog } from "@/mission/PostmortemDialog";
import { ServiceMap, type Lens } from "@/mission/ServiceMap";
import { SessionRibbon } from "@/mission/SessionRibbon";
import { Stage } from "@/mission/Stage";
import { useMission } from "@/mission/use-mission";

import "@/mission/mission.css";

const SERVICE_COLUMNS: ColumnSpec[] = [
    { key: "service", label: "ContosoCare service", kind: "text" },
    { key: "target", label: "Target", kind: "text" },
    { key: "status", label: "Health (history)", kind: "status" },
    { key: "metric", label: "Key number", kind: "text" },
    { key: "impact", label: "In this session, in business words", kind: "text" },
    { key: "evidence", label: "Measured signal", kind: "text" },
    { key: "events", label: "Faults and episodes", kind: "int" },
];

export default function MissionControlPage() {
    const { view, setView, navigate, runtime, meta, provenance, reducedMotion, manage } = useApp();
    const data = useMission();
    const [lens, setLens] = useState<Lens>("technical");
    const [postmortem, setPostmortem] = useState<PostmortemInput | null>(null);
    const { plan, scores, episodes, health } = data;
    const summary = useMemo(() => summarize(scores), [scores]);
    const nodes = useMemo(() => mapNodes(health, scores, episodes), [health, scores, episodes]);
    const shockKeys = useMemo(() => Object.fromEntries(nodes.filter((n) => n.events > 0).map((n) => [n.target, "arrive"])) as Partial<Record<EstateTarget, string>>, [nodes]);
    const hubUrl = hubUrlOf(runtime);
    const t5 = episodes.filter((e) => e.target === "T5");
    const t5Throttled = t5.reduce((a, e) => a + (e.throttled ?? 0), 0);
    const t5Requests = t5.reduce((a, e) => a + (e.requests ?? 0), 0);
    const beat = data.beat;
    const rows = nodes.map((n) => ({
        service: serviceOf(n.target)?.service ?? n.target,
        target: n.target,
        status: n.status ?? "",
        metric: n.metric,
        impact: n.impact ?? "No measured impact",
        evidence: n.evidence ?? "",
        events: n.events,
    }));
    const openPostmortem = () => {
        if (!plan) return;
        setPostmortem({ plan, scores, episodes, beat, asOf: meta?.latestCapture ?? null, provenance, specs: data.specs, generatedAt: new Date() });
    };
    const running = manage.mode === "run" ? manage.running : null;
    const windowText = plan ? `${formatDayUtc(plan.start)} ${formatTimeUtc(plan.start)}–${formatTimeUtc(plan.end)} UTC` : "";

    return (
        <div className="page mission-page">
            <Stage className="span-12 mc-stage" label="Mission Control">
                <header className="mc-head">
                    <div className="mc-titles">
                        <p className="mc-kicker">ContosoCare · Mission Control</p>
                        <h1>{plan ? `${plan.label} · ${windowText}` : "ContosoCare's services"}</h1>
                        <p className="mc-asof">
                            <ProvenanceBadge provenance={provenance} asOf={meta?.latestCapture} />
                            <span>
                                {plan
                                    ? `The ${plan.kind === "session" ? "session's plan" : "request"} as recorded at its end, as of ${formatDateTimeUtc(meta?.latestCapture ?? plan.end)}. For the live view, open Database Hub.`
                                    : "Each service's health from the history. A session's plan reaches the history at its end."}
                            </span>
                        </p>
                    </div>
                    <div className="mc-actions">
                        <LensSwitch lens={lens} onChange={setLens} />
                        <Button size="small" appearance="primary" icon={<Replay20Regular />} disabled={!plan} onClick={() => navigate("replay", { session: plan?.key ?? null })}>
                            Replay
                        </Button>
                        <Button size="small" icon={<Trophy20Regular />} disabled={!plan} onClick={() => navigate("scoreboard", { session: plan?.key ?? null })}>
                            Scoreboard
                        </Button>
                        <Button size="small" icon={<DocumentText16Regular />} disabled={!plan || data.loading} onClick={openPostmortem}>
                            Write the postmortem
                        </Button>
                        <Button
                            size="small"
                            icon={<Tv20Regular />}
                            onClick={() => {
                                enterFullscreen(document.documentElement);
                                navigate("kiosk", { session: view.session });
                            }}
                        >
                            Kiosk
                        </Button>
                        {hubUrl ? (
                            <Link className="mc-hub-link" href={hubUrl} target="_blank" rel="noopener noreferrer">
                                <Open16Regular aria-hidden={true} /> Database Hub, live
                            </Link>
                        ) : null}
                    </div>
                </header>
                <div className="mc-filter">
                    <PlanPicker id="mc-plan" plans={data.plans} value={plan?.key ?? null} onChange={(key) => setView({ session: key, replay: null })} />
                    <GlobalFilter />
                </div>
                {running ? (
                    <MessageBar intent="info" className="mc-running">
                        <MessageBarBody>
                            {`A session is running now: the control's run since ${running.startedAt ? formatTimeUtc(new Date(running.startedAt)) : "a moment ago"} UTC. Its plan reaches the history when it ends; until then, Database Hub shows it live.`}{" "}
                            {hubUrl ? (
                                <Link href={hubUrl} target="_blank" rel="noopener noreferrer">
                                    Open Database Hub
                                </Link>
                            ) : null}
                        </MessageBarBody>
                    </MessageBar>
                ) : null}
                <div className="mc-main">
                    <div className="mc-map-wrap">
                        <ServiceMap
                            nodes={nodes}
                            lens={lens}
                            motion={!reducedMotion}
                            shockKeys={shockKeys}
                            onOpen={(target) => navigate("estate", { target })}
                            title={`ContosoCare's services, ${lens === "business" ? "in business words" : "with their key numbers"}`}
                            hubLine={`${nodes.filter((n) => n.target !== "T4-replica").length} services`}
                        />
                    </div>
                    <aside className="mc-side" aria-label="The session in numbers">
                        <BigStat label="Faults injected" value={plan ? String(summary.faults) : "–"} sub={plan ? "by the session's plan (Scenario Runs)" : "no session in this period"} />
                        <BigStat
                            label="Signal visible in telemetry"
                            value={plan && summary.faults ? `${summary.visible} of ${summary.faults}` : "–"}
                            sub={summary.notVisible ? `${summary.notVisible} not visible: see the scoreboard` : "by the telemetry's sample time"}
                            tone={summary.notVisible ? "alert" : summary.visible ? "good" : undefined}
                        />
                        <BigStat label="Median time to detect" value={minutesText(summary.ttdMedian)} sub="injected → signal visible" />
                        <BigStat label="Median time to recover" value={minutesText(summary.ttrMedian)} sub="injected → back under its bound" />
                        {beat?.cpuBefore !== null && beat?.cpuBefore !== undefined && beat.cpuAfter !== null ? (
                            <BigStat label="Database Agent loop, T3" value={`${Math.round(beat.cpuBefore)} % → ${Math.round(beat.cpuAfter)} %`} sub={`CPU before and after the last good plan, forced at ${formatTimeUtc(beat.respondAt)} UTC`} tone="good" />
                        ) : null}
                        {t5.length > 0 ? (
                            <BigStat
                                label="Patient events, T5"
                                value={t5Requests ? `${Math.round((t5Throttled / t5Requests) * 100)} % throttled` : `${t5.length} episode${t5.length === 1 ? "" : "s"}`}
                                sub={t5Requests ? `${formatNumber(t5Throttled, "int")} of ${formatNumber(t5Requests, "int")} requests answered 429 in ${t5.length} episode${t5.length === 1 ? "" : "s"}` : "throttling in its Azure Monitor metrics"}
                                tone="alert"
                            />
                        ) : null}
                    </aside>
                </div>
                {plan ? (
                    <SessionRibbon plan={plan} scores={scores} episodes={episodes} onSelect={() => navigate("scoreboard", { session: plan.key })} />
                ) : !data.loading ? (
                    <EmptyState title={data.error ? "The sessions couldn't load" : "No session in this period"}>
                        <p>{data.error ? data.error.message : "Run all in NB_DatabaseHub_Control runs a session; its plan lands here when it ends. Or pick All history above."}</p>
                    </EmptyState>
                ) : null}
            </Stage>

            <VisualCard
                id="mission.services"
                className="span-12"
                title="ContosoCare's services"
                subtitle={lens === "business" ? "Each service with what it went through in the session, in business words next to the measured signal." : "Each service with its health from the history and its key number."}
                specs={data.specs}
                loading={data.loading && nodes.length === 0}
                table={{ columns: SERVICE_COLUMNS, rows, caption: "ContosoCare's services" }}
                summary={rows.map((r) => `${r.service} (${r.target}): ${r.status || "no data"}; ${lens === "business" ? r.impact : r.metric}`).join(". ")}
                askPrompt="What did ContosoCare's services go through in this session, in business terms, and which needs attention first?"
            >
                <ul className="mc-services">
                    {nodes.map((n) => (
                        <li key={n.target}>
                            <TargetChip target={n.target} />
                            <strong>{serviceOf(n.target)?.service}</strong>
                            {n.status ? <StatusBadge status={n.status} short /> : <span className="muted">No data</span>}
                            <span>{lens === "business" ? (n.impact ?? "No measured impact") : n.metric}</span>
                            {lens === "business" && n.evidence ? <span className="muted">{`(${n.evidence})`}</span> : null}
                            {n.status ? <span className="sr-only">{statusMeta(n.status).meaning}</span> : null}
                        </li>
                    ))}
                </ul>
            </VisualCard>

            <PostmortemDialog input={postmortem} onClose={() => setPostmortem(null)} />
        </div>
    );
}
