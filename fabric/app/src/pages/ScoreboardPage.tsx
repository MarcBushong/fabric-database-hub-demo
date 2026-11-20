// "Did we catch it?" (ADR 0030): every fault the demo injected, when its signal showed in the telemetry, when it was
// answered, and when it recovered, with the times to detect and recover per engine and fault type across sessions. Only
// the app can show this: Database Hub doesn't know what was injected. "Signal visible in telemetry" is measured from the
// history's bins; what Database Hub itself detected isn't in the history, so the page never says it.

import { useMemo, useState } from "react";
import { Button } from "@fluentui/react-components";
import { Replay20Regular, HeartPulse20Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { DataGrid, type GridColumn } from "@/components/DataGrid";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { TargetChip } from "@/components/TargetChip";
import { VisualCard } from "@/components/VisualCard";
import type { ColumnSpec } from "@/data/queries";
import { serviceOf } from "@/lib/business";
import { formatTimeUtc } from "@/lib/format";
import { POSTMORTEM_COLUMNS, postmortemRows, type PostmortemInput } from "@/lib/postmortem";
import { aggregate, boundText, minutesText, RECOVERED_BINS, summarize, TELEMETRY_LAG_MINUTES, type Aggregate, type FaultScore } from "@/lib/scoreboard";
import { GlobalFilter } from "@/shell/GlobalFilter";
import { ChartView } from "@/visuals/ChartView";
import { BigStat, LensSwitch, LoadNotice, MissingSession, PlanPicker, PostmortemButton } from "@/mission/parts";
import { PostmortemDialog } from "@/mission/PostmortemDialog";
import type { Lens } from "@/mission/ServiceMap";
import { SessionRibbon } from "@/mission/SessionRibbon";
import { Stage } from "@/mission/Stage";
import { useMission } from "@/mission/use-mission";

import "@/mission/mission.css";

/** The newest sessions besides the one in focus whose faults the aggregates measure. */
const ACROSS = 3;

interface FaultRow extends Record<string, unknown> {
    key: string;
    status: string;
    injected: Date;
    target: string;
    service: string;
    fault: string;
    signal: string;
    visible: Date | null;
    ttd: number | null;
    answered: Date | null;
    recovered: Date | null;
    ttr: number | null;
    impact: string;
    how: string;
    score: FaultScore;
}

const time = (d: Date | null) => (d ? formatTimeUtc(d) : "–");

function columns(lens: Lens): GridColumn<FaultRow>[] {
    return [
        { key: "status", label: "Caught?", render: (r) => <StatusBadge status={r.status === "Pass" ? "Pass" : r.status} short />, sortValue: (r) => (r.status === "Pass" ? 0 : 1) },
        { key: "injected", label: "Injected (UTC)", render: (r) => time(r.injected), sortValue: (r) => r.injected.getTime() },
        { key: "target", label: "Target", render: (r) => <TargetChip target={r.target} /> },
        { key: "service", label: "Service" },
        { key: "fault", label: "Fault" },
        { key: "signal", label: "Signal" },
        { key: "visible", label: "Signal visible", render: (r) => time(r.visible), sortValue: (r) => r.visible?.getTime() ?? null },
        { key: "ttd", label: "Time to detect", render: (r) => minutesText(r.ttd, r.score.binMinutes), sortValue: (r) => r.ttd, numeric: true },
        { key: "answered", label: "Answered", render: (r) => time(r.answered), sortValue: (r) => r.answered?.getTime() ?? null },
        { key: "recovered", label: "Recovered", render: (r) => (r.recovered ? time(r.recovered) : r.score.recoveryWord || "–"), sortValue: (r) => r.recovered?.getTime() ?? null },
        { key: "ttr", label: "Time to recover", render: (r) => minutesText(r.ttr), sortValue: (r) => r.ttr, numeric: true },
        lens === "business" ? { key: "impact", label: "Business impact (measured)" } : { key: "how", label: "How it was measured" },
    ];
}

const AGG_COLUMNS: ColumnSpec[] = [
    { key: "label", label: "Group", kind: "text" },
    { key: "faults", label: "Faults", kind: "int" },
    { key: "visible", label: "Signal visible", kind: "int" },
    { key: "ttdMedian", label: "Median time to detect (min)", kind: "minutes" },
    { key: "ttdN", label: "Faults behind it", kind: "int" },
    { key: "ttrMedian", label: "Median time to recover (min)", kind: "minutes" },
    { key: "ttrN", label: "Faults behind it", kind: "int" },
];

function aggChart(rows: readonly Aggregate[], title: string) {
    return {
        kind: "bar" as const,
        title,
        unit: "min",
        x: "Group",
        y: ["Time to detect", "Time to recover"],
        rows: rows.map((a) => ({ Group: a.label, "Time to detect": a.ttdMedian === null ? null : Math.round(a.ttdMedian * 10) / 10, "Time to recover": a.ttrMedian === null ? null : Math.round(a.ttrMedian * 10) / 10 })),
    };
}

export default function ScoreboardPage() {
    const { view, setView, navigate, provenance, meta } = useApp();
    const data = useMission(ACROSS);
    const [lens, setLens] = useState<Lens>("technical");
    const [selected, setSelected] = useState<string | null>(null);
    const [postmortem, setPostmortem] = useState<PostmortemInput | null>(null);
    const { plan, scores, episodes } = data;
    const summary = useMemo(() => summarize(scores), [scores]);
    const across = useMemo(() => [...data.scored.values()].flat(), [data.scored]);
    const engines = useMemo(() => aggregate(across, "engine"), [across]);
    const types = useMemo(() => aggregate(across, "type"), [across]);
    const rows: FaultRow[] = useMemo(
        () =>
            scores.map((s) => ({
                key: s.key,
                status: s.status,
                injected: s.injectedAt,
                target: s.target,
                service: serviceOf(s.target)?.service ?? s.target,
                fault: s.title,
                signal: s.signal,
                visible: s.visibleAt,
                ttd: s.ttdMin,
                answered: s.answeredAt,
                recovered: s.recoveredAt,
                ttr: s.ttrMin,
                impact: s.impact?.sentence ?? (s.status === "Pass" ? "" : s.note),
                how: s.bound
                    ? `${boundText(s.bound, s.kind)} (${s.bound.short})${s.bound.minBins > 1 ? `, ${s.bound.minBins} bins` : ""}${s.status === "Pass" ? "" : `. ${s.note}`}`
                    : s.note,
                score: s,
            })),
        [scores],
    );
    const csvRows = useMemo(() => postmortemRows(scores, episodes), [scores, episodes]);
    const picked = rows.find((r) => r.key === selected) ?? null;
    const sessions = data.scored.size;

    return (
        <div className="page scoreboard-page">
            <Stage className="span-12 mc-stage" label="Did we catch it?">
                <header className="mc-head">
                    <div className="mc-titles">
                        <p className="mc-kicker">ContosoCare · Scoreboard</p>
                        <h1>{plan && summary.faults ? `Did we catch it? ${summary.visible} of ${summary.faults}` : "Did we catch it?"}</h1>
                        <p className="mc-asof">
                            <span>The app knows what was injected; Database Hub sees the symptoms. "Signal visible" is measured from the telemetry, by its sample time.</span>
                        </p>
                    </div>
                    <div className="mc-actions">
                        <LensSwitch lens={lens} onChange={setLens} />
                        <Button size="small" appearance="primary" icon={<Replay20Regular />} disabled={!plan} onClick={() => navigate("replay", { session: view.session })}>
                            Replay
                        </Button>
                        <PostmortemButton
                            ready={Boolean(plan) && !data.loading}
                            scoreError={data.scoreError}
                            onClick={() => plan && setPostmortem({ plan, scores, episodes, beat: data.beat, asOf: meta?.latestCapture ?? null, provenance, specs: data.specs, generatedAt: new Date() })}
                        />
                        <Button size="small" icon={<HeartPulse20Regular />} onClick={() => navigate("mission", { session: view.session })}>
                            Mission Control
                        </Button>
                    </div>
                </header>
                <div className="mc-filter">
                    <PlanPicker id="sb-plan" plans={data.plans} value={plan?.key ?? null} onChange={(key) => setView({ session: key, replay: null })} />
                    <GlobalFilter />
                </div>
                <LoadNotice error={data.loadError} onRetry={data.refetch} />
                {plan ? (
                    <>
                        <div className="sb-stats" aria-label="The session in numbers">
                            <BigStat label="Faults injected" value={String(plan.faults.length)} sub="by the plan (Scenario Runs)" />
                            <BigStat label="Caught: signal visible" value={summary.faults ? `${summary.visible} of ${summary.faults}` : "–"} sub={data.scoreError ? "the telemetry didn't load, so nothing is measured" : "in the telemetry, by sample time"} tone={summary.notVisible ? "alert" : summary.visible ? "good" : undefined} />
                            <BigStat label="Median time to detect" value={minutesText(summary.ttdMedian)} sub="injected → signal visible" />
                            <BigStat label="Median time to recover" value={minutesText(summary.ttrMedian)} sub="injected → back under its bound" />
                            <BigStat label="Answered" value={String(summary.answered)} sub={summary.answered ? "a response step: the Database Agent loop, or a reset" : "every fault ended at its time limit"} />
                        </div>
                        <SessionRibbon plan={plan} scores={scores} episodes={episodes} selected={selected} onSelect={(ref) => setSelected((current) => (current === ref ? null : ref))} />
                        {picked ? (
                            <p className="sb-picked" aria-live="polite">
                                <StatusBadge status={picked.status} short />
                                <strong>{`${picked.target} ${picked.fault}`}</strong>
                                <span>{picked.score.impact?.sentence ?? picked.score.note}</span>
                            </p>
                        ) : null}
                    </>
                ) : data.missingSession ? (
                    <MissingSession session={data.missingSession} onAllHistory={() => setView({ window: "all" })} onLatest={() => setView({ session: null, replay: null })} />
                ) : !data.loading ? (
                    <EmptyState title={data.error ? "The sessions couldn't load" : "Nothing injected in this period"}>
                        <p>{data.error ? data.error.message : "Run all in NB_DatabaseHub_Control runs a session; its plan, the faults it injects, lands in the history when it ends. Or pick All history."}</p>
                    </EmptyState>
                ) : null}
            </Stage>

            {plan ? (
                <VisualCard
                    id="scoreboard.faults"
                    className="span-12"
                    title="Every injected fault"
                    subtitle={`${plan.label}: what was injected, when its signal showed, the response, and the recovery. ${lens === "business" ? "The business lens says what each service felt, next to the measured signal." : "Each row says how its signal was measured."}`}
                    specs={data.specs}
                    loading={data.loading && rows.length === 0}
                    error={data.scoreError}
                    onRefresh={data.refetch}
                    empty={!data.loading && rows.length === 0}
                    emptyText="This session injected no fault on the targets in the filter."
                    table={{ columns: POSTMORTEM_COLUMNS, rows: csvRows, caption: "Every injected fault" }}
                    summary={`${summary.visible} of ${summary.faults} faults had their signal visible in the telemetry.`}
                    askPrompt="Did we catch every fault in this session? Which ones were slowest to detect or recover, and why?"
                >
                    <DataGrid columns={columns(lens)} rows={rows} caption="Every injected fault" exportName="scoreboard" onRowClick={(r) => setSelected(r.key)} rowLabel={(r) => `Select ${r.target} ${r.fault}`} />
                </VisualCard>
            ) : null}

            {across.length > 0 ? (
                <>
                    <VisualCard
                        id="scoreboard.engines"
                        className="span-6"
                        title="Times per engine"
                        subtitle={`Median minutes, across the ${sessions} newest session${sessions === 1 ? "" : "s"} in the period (each median rests on the faults it could measure).`}
                        specs={data.specs}
                        loading={false}
                        table={{ columns: AGG_COLUMNS, rows: engines.map((a) => ({ ...a })), caption: "Times to detect and recover per engine" }}
                        summary={engines.map((a) => `${a.label}: detect ${minutesText(a.ttdMedian)}, recover ${minutesText(a.ttrMedian)}`).join("; ")}
                        askPrompt="Which engine was slowest to show and to recover from the injected faults, and what would make it faster?"
                    >
                        <ChartView hideHeader height={220} spec={aggChart(engines, "Times per engine")} colors={{ "Time to detect": "var(--chart-2)", "Time to recover": "var(--chart-6)" }} />
                    </VisualCard>
                    <VisualCard
                        id="scoreboard.types"
                        className="span-6"
                        title="Times per fault type"
                        subtitle={`Median minutes, across the same ${sessions} session${sessions === 1 ? "" : "s"}.`}
                        specs={data.specs}
                        loading={false}
                        table={{ columns: AGG_COLUMNS, rows: types.map((a) => ({ ...a })), caption: "Times to detect and recover per fault type" }}
                        summary={types.map((a) => `${a.label}: detect ${minutesText(a.ttdMedian)}, recover ${minutesText(a.ttrMedian)}`).join("; ")}
                        askPrompt="Which kinds of fault take longest to detect and to recover from?"
                    >
                        <ChartView hideHeader height={220} spec={aggChart(types, "Times per fault type")} colors={{ "Time to detect": "var(--chart-2)", "Time to recover": "var(--chart-6)" }} />
                    </VisualCard>
                </>
            ) : null}

            {episodes.length > 0 ? (
                <VisualCard
                    id="scoreboard.metrics"
                    className="span-12"
                    title="T4 and T5: what their metrics show"
                    subtitle="Their beats aren't in Scenario Runs, so their injections aren't in the history; their episodes and recoveries are, from the Azure Monitor metrics captured at the session's end."
                    specs={data.specs}
                    loading={false}
                    table={null}
                    summary={episodes.map((e) => e.impact.sentence).join(". ")}
                    askPrompt="What did T4's and T5's metrics show in this session, and did they recover?"
                >
                    <ul className="sb-episodes">
                        {episodes.map((e) => (
                            <li key={e.key}>
                                <TargetChip target={e.target} />
                                <span className="sb-ep-time">{`${time(e.visibleAt)}–${time(e.recoveredAt ?? e.endAt)} UTC`}</span>
                                <span>{lens === "business" ? e.impact.sentence : `${e.signal}: peak ${e.peak === null ? "–" : e.kind === "percent" ? `${Math.round(e.peak)} %` : `${Math.round(e.peak)} s`}. ${e.note}`}</span>
                            </li>
                        ))}
                    </ul>
                </VisualCard>
            ) : null}

            <section className="panel span-12 sb-how" aria-labelledby="sb-how-title">
                <h3 id="sb-how-title">How it's measured</h3>
                <ul>
                    <li>
                        <strong>What was injected:</strong> Scenario Runs, which NB_DatabaseHub_LiveActivity writes at the session's end from the control's plan: each beat on T1 to T3, its scenario, and its window. The Database Agent beat counts from when its plan regressed.
                    </li>
                    <li>
                        <strong>Signal visible in telemetry:</strong> the first bin, from the injection to {TELEMETRY_LAG_MINUTES} minutes after its window, where the scenario's own signal reaches the analysis notebook's level: CPU 80 %, or 1.5 times and 10 points above its baseline; blocked processes or Log Rate Governor waits above 0; Buffer IO waits 1 s; other wait categories 5 s per bin; for 2 bins in a row where the notebook asks for them. It's by the telemetry's sample time: Database Hub shows the telemetry 3 to 15 minutes later, and what it detected isn't in the history.
                    </li>
                    <li>
                        <strong>Answered:</strong> a response step, where one exists: the Database Agent loop's documented response (the last good plan, forced), or a reset. The others end at their time limit.
                    </li>
                    <li>
                        <strong>Recovered:</strong> the first bin after the signal's last bin at that level, with {RECOVERED_BINS} bins under it in a row.
                    </li>
                </ul>
            </section>

            <PostmortemDialog input={postmortem} onClose={() => setPostmortem(null)} />
        </div>
    );
}
