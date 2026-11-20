// Session replay (ADR 0030): play a whole session back across every engine, with the service map, the five engines'
// charts, and the event ribbon on one scrubber. The moment is kept in the app's address (#/replay?s=<session>&r=<minute>).

import { useCallback, useEffect, useMemo, useState } from "react";
import { Button } from "@fluentui/react-components";
import { DocumentText16Regular, HeartPulse20Regular, Trophy20Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { ProvenanceBadge } from "@/components/ProvenanceBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import type { ColumnSpec } from "@/data/queries";
import { copyText } from "@/lib/clipboard";
import { formatTimeUtc } from "@/lib/format";
import { isEmbedded, toHash } from "@/lib/view-state";
import type { PostmortemInput } from "@/lib/postmortem";
import { EVENT_LABEL, planEvents } from "@/lib/scoreboard";
import { CinematicReplay } from "@/mission/CinematicReplay";
import { LensSwitch, LoadNotice, MissingSession, PlanPicker } from "@/mission/parts";
import { PostmortemDialog } from "@/mission/PostmortemDialog";
import type { Lens } from "@/mission/ServiceMap";
import { Stage } from "@/mission/Stage";
import { ribbonRange } from "@/mission/timeline";
import { useMission } from "@/mission/use-mission";

import "@/mission/mission.css";

// Inside Fabric's frame the address is the app's hosted URL, which opens only from the app's item (a preview limit), so
// the toast says how the moment comes back instead of promising the link opens it.
const COPIED_IN_FABRIC = "Copied this moment's address. In Fabric, the app opens from its item, and this browser reopens it where you leave it.";

/**
 * How long the replay's moment holds before the address takes it. Playback (a step every 700 ms or less) and a drag never
 * write it, a pause or a seek writes it once: WebKit refuses more than 100 address changes in 10 seconds.
 */
const ADDRESS_DELAY_MS = 1000;

interface EventRow extends Record<string, unknown> {
    at: Date;
    target: string;
    event: string;
    detail: string;
}

const EVENT_COLUMNS: GridColumn<EventRow>[] = [
    { key: "at", label: "Time (UTC)", render: (r) => formatTimeUtc(r.at), sortValue: (r) => r.at.getTime() },
    { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} /> },
    { key: "event", label: "Moment" },
    { key: "detail", label: "What" },
];

const EVENT_SPEC_COLUMNS: ColumnSpec[] = [
    { key: "at", label: "Time (UTC)", kind: "datetime" },
    { key: "target", label: "Target", kind: "text" },
    { key: "event", label: "Moment", kind: "text" },
    { key: "detail", label: "What", kind: "text" },
];

export default function ReplayPage() {
    const { view, setView, navigate, reducedMotion, provenance, meta, notify } = useApp();
    const data = useMission();
    const [lens, setLens] = useState<Lens>("technical");
    const [postmortem, setPostmortem] = useState<PostmortemInput | null>(null);
    const { plan, scores, episodes } = data;
    const planKey = plan?.key ?? null;
    // The moment the viewer moved the replay to, for this session; until then, the address's (a session without one starts at its start).
    const [moment, setMoment] = useState<{ key: string | null; minute: number } | null>(null);
    const minute = moment && moment.key === planKey ? moment.minute : view.session === null || view.session === planKey ? view.replay : null;
    const onMinute = useCallback((next: number) => setMoment({ key: planKey, minute: next }), [planKey]);
    useEffect(() => {
        if (!moment || moment.key !== planKey || (moment.minute === view.replay && view.session === planKey)) return;
        const timer = window.setTimeout(() => setView({ replay: moment.minute, session: planKey }), ADDRESS_DELAY_MS);
        return () => window.clearTimeout(timer);
    }, [moment, planKey, view.replay, view.session, setView]);
    const copyLink = async () => {
        // The address takes the moment now, and the copied link carries it, whatever the delay above.
        setView({ replay: minute, session: planKey });
        const url = new URL(window.location.href);
        url.hash = toHash({ ...view, replay: minute, session: planKey });
        notify((await copyText(url.toString())) ? (isEmbedded() ? COPIED_IN_FABRIC : "Copied the link to this moment: it opens the replay here") : "Copy is blocked here: the moment is in this app's address", "info");
    };
    const rows: EventRow[] = useMemo(() => planEvents(scores, episodes).map((e) => ({ at: e.at, target: e.target, event: EVENT_LABEL[e.kind], detail: e.label })), [scores, episodes]);
    const rangeFrom = useMemo(() => (plan ? ribbonRange(plan, scores, episodes)[0] : 0), [plan, scores, episodes]);

    return (
        <div className="page replay-page">
            <Stage className="span-12 mc-stage" label="Session replay">
                <header className="mc-head">
                    <div className="mc-titles">
                        <p className="mc-kicker">ContosoCare · Session replay</p>
                        <h1>{plan ? `${plan.label}, beat by beat` : "Session replay"}</h1>
                        <p className="mc-asof">
                            <ProvenanceBadge provenance={provenance} asOf={meta?.latestCapture} />
                            <span>One scrubber drives the map, every engine, and the plan. The moment stays in the app's address.</span>
                        </p>
                    </div>
                    <div className="mc-actions">
                        <LensSwitch lens={lens} onChange={setLens} />
                        <Button size="small" icon={<HeartPulse20Regular />} onClick={() => navigate("mission", { session: plan?.key ?? null })}>
                            Mission Control
                        </Button>
                        <Button size="small" icon={<Trophy20Regular />} disabled={!plan} onClick={() => navigate("scoreboard", { session: plan?.key ?? null })}>
                            Scoreboard
                        </Button>
                        <Button
                            size="small"
                            icon={<DocumentText16Regular />}
                            disabled={!plan || data.loading}
                            onClick={() => plan && setPostmortem({ plan, scores, episodes, beat: data.beat, asOf: meta?.latestCapture ?? null, provenance, specs: data.specs, generatedAt: new Date() })}
                        >
                            Write the postmortem
                        </Button>
                    </div>
                </header>
                <div className="mc-filter">
                    <PlanPicker id="replay-plan" plans={data.plans} value={plan?.key ?? null} onChange={(key) => setView({ session: key, replay: null })} />
                </div>
                <LoadNotice error={data.loadError} onRetry={data.refetch} />
                {plan ? (
                    <CinematicReplay
                        plan={plan}
                        scores={scores}
                        episodes={episodes}
                        bins={data.bins}
                        cosmos={data.cosmos}
                        postgres={data.postgres}
                        health={data.health}
                        minute={minute}
                        onMinute={onMinute}
                        lens={lens}
                        motion={!reducedMotion}
                        onCopyLink={copyLink}
                    />
                ) : data.missingSession ? (
                    <MissingSession session={data.missingSession} onAllHistory={() => setView({ window: "all" })} onLatest={() => setView({ session: null, replay: null })} />
                ) : !data.loading ? (
                    <EmptyState title={data.error ? "The sessions couldn't load" : "No session to replay in this period"}>
                        <p>{data.error ? data.error.message : "Run all in NB_DatabaseHub_Control runs a session; its plan lands in the history when it ends."}</p>
                    </EmptyState>
                ) : null}
            </Stage>

            <VisualCard
                id="replay.events"
                className="span-12"
                title="Every moment of the session"
                subtitle="Injected, signal visible in telemetry, answered, and recovered, in time order. Select one to move the replay there."
                specs={data.specs}
                loading={data.loading && rows.length === 0}
                error={data.scoreError}
                onRefresh={data.refetch}
                empty={!data.loading && rows.length === 0}
                emptyText="No moment in this session."
                table={{ columns: EVENT_SPEC_COLUMNS, rows, caption: "The session's moments" }}
                summary={`${rows.length} moments.`}
                askPrompt="Walk me through this session's replay: what happened first, what followed, and how fast each signal showed and recovered?"
            >
                <DataGrid
                    columns={EVENT_COLUMNS}
                    rows={rows}
                    caption="The session's moments"
                    exportName="session-moments"
                    onRowClick={(r) => onMinute(Math.max(0, Math.round((r.at.getTime() - rangeFrom) / 60000)))}
                    rowLabel={(r) => `Move the replay to ${formatTimeUtc(r.at)} UTC: ${r.event}, ${r.detail}`}
                />
            </VisualCard>

            <PostmortemDialog input={postmortem} onClose={() => setPostmortem(null)} />
        </div>
    );
}
