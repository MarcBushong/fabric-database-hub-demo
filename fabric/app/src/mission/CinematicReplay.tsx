// The cinematic replay (ADR 0030): one scrubber drives the service map, all five engines' charts, and the event ribbon
// for a whole session. The map's nodes take each target's state at the moment, and a shockwave plays when a fault's signal
// shows; the ribbon counts down to the next injection. The moment lives in the app's address (r: minutes from the start).

import { useEffect, useMemo, useState } from "react";
import { area, curveMonotoneX, line } from "d3-shape";
import { scaleLinear } from "d3-scale";
import { Button, ToggleButton, Tooltip } from "@fluentui/react-components";
import { Share16Regular, Next16Regular, Pause16Filled, Play16Filled, Previous16Regular } from "@fluentui/react-icons";

import { POSTGRES_METRICS, postgresSeries, type Bin, type CosmosCapture, type PostgresCapture } from "@/data/model";
import { serviceOf } from "@/lib/business";
import { TARGETS } from "@/lib/estate";
import { formatNumber, formatTimeUtc, type NumberKind } from "@/lib/format";
import type { TargetHealth } from "@/lib/health";
import { useElementSize } from "@/lib/hooks";
import { planEvents, TELEMETRY_LAG_MINUTES, type FaultScore, type MeasuredEpisode, type Plan } from "@/lib/scoreboard";
import type { EstateTarget } from "@/lib/view-state";
import { mapNodes } from "./nodes";
import { ServiceMap, type Lens } from "./ServiceMap";
import { SessionRibbon } from "./SessionRibbon";
import { cosmosLanePoints, ribbonRange } from "./timeline";

const MIN = 60000;
const SPEEDS = [1, 2, 4, 8] as const;

interface Point {
    t: number;
    v: number;
}

interface Series {
    name: string;
    kind: NumberKind;
    points: Point[];
    /** A fixed top of the scale (100 for percentages), or the series' own peak. */
    max?: number;
    shape: "area" | "line";
}

interface Band {
    from: number;
    to: number;
    hot: boolean;
}

interface Lane {
    target: EstateTarget;
    title: string;
    series: Series[];
    bands: Band[];
    note?: string;
}

function valueAt(points: readonly Point[], t: number): number | null {
    let found: number | null = null;
    for (const p of points) {
        if (p.t > t) break;
        found = p.v;
    }
    return found;
}

function lanesOf(bins: readonly Bin[], scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[], cosmos: CosmosCapture | null, postgres: PostgresCapture | null, from: number, to: number): Lane[] {
    const inRange = (t: number) => t >= from && t <= to;
    const bandsFor = (target: EstateTarget): Band[] => [
        ...scores.filter((s) => s.target === target).map((s) => ({ from: s.injectedAt.getTime(), to: s.injectedEnd.getTime(), hot: false })),
        ...scores
            .filter((s) => s.target === target && s.visibleAt)
            .map((s) => ({ from: (s.visibleAt as Date).getTime(), to: (s.recoveredAt ?? new Date(s.injectedEnd.getTime() + TELEMETRY_LAG_MINUTES * MIN)).getTime(), hot: true })),
        ...episodes.filter((e) => e.target === target || (target === "T4" && e.target === "T4-replica")).map((e) => ({ from: e.visibleAt.getTime(), to: (e.recoveredAt ?? e.endAt ?? e.visibleAt).getTime(), hot: true })),
    ];
    const lanes: Lane[] = [];
    for (const target of ["T1", "T2", "T3"] as const) {
        const mine = bins.filter((b) => b.target === target && inRange(b.at.getTime()));
        lanes.push({
            target,
            title: `${target} · ${TARGETS[target].name}`,
            series: [
                { name: "Wait time", kind: "seconds", shape: "area", points: mine.filter((b) => b.waitS !== null).map((b) => ({ t: b.at.getTime(), v: b.waitS as number })) },
                { name: "CPU", kind: "percent", shape: "line", max: 100, points: mine.filter((b) => b.cpu !== null).map((b) => ({ t: b.at.getTime(), v: b.cpu as number })) },
            ],
            bands: bandsFor(target),
            note: mine.length === 0 ? "No telemetry in this session" : undefined,
        });
    }
    const pgPoints = (target: "T4" | "T4-replica", metric: string) =>
        postgresSeries(postgres, target, metric)
            .filter((p) => inRange(p.at.getTime()))
            .map((p) => ({ t: p.at.getTime(), v: p.value }));
    const lag = pgPoints("T4-replica", POSTGRES_METRICS.lag);
    const pgCpu = pgPoints("T4", POSTGRES_METRICS.cpu);
    lanes.push({
        target: "T4",
        title: `T4 · ${TARGETS.T4.name}`,
        series: [
            { name: "Replica lag", kind: "seconds", shape: "area", points: lag },
            { name: "CPU", kind: "percent", shape: "line", max: 100, points: pgCpu },
        ],
        bands: bandsFor("T4"),
        note: lag.length + pgCpu.length === 0 ? "Its latest capture isn't from this session" : undefined,
    });
    const { ru, throttled } = cosmosLanePoints(cosmos, from, to);
    lanes.push({
        target: "T5",
        title: `T5 · ${TARGETS.T5.name}`,
        series: [
            { name: "Normalized RU", kind: "percent", shape: "area", max: 100, points: ru },
            // Per minute where the window holds saves at different intervals (cosmosLanePoints), and named so.
            { name: (cosmos?.saves ?? 1) > 1 ? "429s a minute" : "429s", kind: "int", shape: "line", points: throttled },
        ],
        bands: bandsFor("T5"),
        note: ru.length === 0 ? "Its latest capture isn't from this session" : undefined,
    });
    return lanes;
}

function EngineLane({ lane, from, to, now, width }: { lane: Lane; from: number; to: number; now: number; width: number }) {
    const h = 58;
    const x = scaleLinear().domain([from, to]).range([0, Math.max(width, 10)]);
    const color = TARGETS[lane.target].color;
    const readout = lane.series
        .map((s) => {
            const v = valueAt(s.points, now);
            return v === null ? null : `${s.name} ${formatNumber(v, s.kind)}`;
        })
        .filter((v): v is string => v !== null)
        .join(" · ");
    return (
        <div className="cr-lane">
            <div className="cr-lane-label">
                <strong>{serviceOf(lane.target)?.service}</strong>
                <span>{lane.title}</span>
            </div>
            <div className="cr-lane-track">
                <svg viewBox={`0 0 ${Math.max(width, 10)} ${h}`} width="100%" height={h} preserveAspectRatio="none" aria-hidden="true">
                    {lane.bands.map((b, i) => (
                        <rect key={i} className={b.hot ? "cr-band-hot" : "cr-band"} x={x(b.from)} y={0} width={Math.max(2, x(b.to) - x(b.from))} height={h} />
                    ))}
                    {lane.series.map((s) => {
                        if (s.points.length === 0) return null;
                        const top = s.max ?? Math.max(1e-9, ...s.points.map((p) => p.v));
                        const y = scaleLinear().domain([0, top * 1.1]).range([h - 3, 4]);
                        const path = s.shape === "area" ? area<Point>().x((p) => x(p.t)).y0(h - 3).y1((p) => y(p.v)).curve(curveMonotoneX)(s.points) : line<Point>().x((p) => x(p.t)).y((p) => y(p.v)).curve(curveMonotoneX)(s.points);
                        return s.shape === "area" ? <path key={s.name} d={path ?? ""} className="cr-area" style={{ fill: color }} /> : <path key={s.name} d={path ?? ""} className="cr-line" />;
                    })}
                    <line className="cr-playhead" x1={x(now)} x2={x(now)} y1={0} y2={h} />
                </svg>
                <span className="cr-readout">{lane.note ?? (readout || "–")}</span>
            </div>
        </div>
    );
}

/** Each moment's mark and word, as the ribbon draws it. */
const EVENT_WORD = { injected: "▼ Injected", visible: "● Signal visible", answered: "◆ Answered", recovered: "✓ Recovered" } as const;

export interface CinematicReplayProps {
    plan: Plan;
    scores: readonly FaultScore[];
    episodes: readonly MeasuredEpisode[];
    bins: readonly Bin[];
    cosmos: CosmosCapture | null;
    postgres: PostgresCapture | null;
    health: readonly TargetHealth[];
    /** Minutes from the replay's start, or null for its start. */
    minute: number | null;
    onMinute: (minute: number) => void;
    lens: Lens;
    motion: boolean;
    autoplay?: boolean;
    /** Holds the playback while true (the kiosk's pause). */
    paused?: boolean;
    /** Starts over at the end (the kiosk). */
    loop?: boolean;
    onCopyLink?: () => void;
    /** A smaller layout for the kiosk's scene. */
    compact?: boolean;
}

export function CinematicReplay(props: CinematicReplayProps) {
    const { plan, scores, episodes, onMinute } = props;
    const [from, to] = useMemo(() => ribbonRange(plan, scores, episodes), [plan, scores, episodes]);
    const total = Math.max(1, Math.ceil((to - from) / MIN));
    const position = Math.min(Math.max(props.minute ?? 0, 0), total);
    const now = from + position * MIN;
    const [playing, setPlaying] = useState(Boolean(props.autoplay));
    const [speed, setSpeed] = useState<(typeof SPEEDS)[number]>(props.autoplay ? 2 : 1);
    const [ref, size] = useElementSize<HTMLDivElement>(700);
    const events = useMemo(() => planEvents(scores, episodes), [scores, episodes]);
    const lanes = useMemo(() => lanesOf(props.bins, scores, episodes, props.cosmos, props.postgres, from, to), [props.bins, scores, episodes, props.cosmos, props.postgres, from, to]);
    const nodes = useMemo(() => mapNodes(props.health, scores, episodes, props.postgres, new Date(now)), [props.health, scores, episodes, props.postgres, now]);
    // A shockwave on each target whose signal showed in the last 4 minutes of the replay, keyed by that moment, so crossing
    // a new one plays it again.
    const shockKeys = useMemo(() => {
        const keys: Partial<Record<EstateTarget, string>> = {};
        for (const e of events) if (e.kind === "visible" && e.at.getTime() <= now && now - e.at.getTime() <= 4 * MIN) keys[e.target] = `${e.ref}`;
        return keys;
    }, [events, now]);

    useEffect(() => {
        if (!playing || props.paused) return;
        const timer = window.setTimeout(() => {
            if (position >= total) {
                if (props.loop) onMinute(0);
                else setPlaying(false);
                return;
            }
            onMinute(position + 1);
        }, 700 / speed);
        return () => window.clearTimeout(timer);
    }, [playing, props.paused, position, total, speed, onMinute, props.loop]);

    // What a screen reader hears: play, pause, and each seek to a moment, never each step of the playback.
    const [said, setSaid] = useState("");
    const momentText = (t: number) => {
        const e = [...events].reverse().find((x) => x.at.getTime() <= t);
        return e ? `${EVENT_WORD[e.kind]} at ${formatTimeUtc(e.at)}: ${e.label}` : "Before the first fault";
    };
    const seek = (minute: number) => {
        onMinute(minute);
        setSaid(`${formatTimeUtc(new Date(from + minute * MIN))} UTC. ${momentText(from + minute * MIN)}`);
    };
    const nextEvent = events.find((e) => e.at.getTime() > now + 1);
    const previousEvent = [...events].reverse().find((e) => e.at.getTime() < now - 1);
    const toMinute = (t: number) => Math.min(total, Math.max(0, Math.round((t - from) / MIN)));
    const current = [...events].reverse().find((e) => e.at.getTime() <= now);

    return (
        <div className={`cr${props.compact ? " cr-compact" : ""}`}>
            <div className="cr-top">
                <div className="cr-clock" aria-live="off">
                    <span className="cr-time">{formatTimeUtc(new Date(now))}</span>
                    <span className="cr-utc">UTC</span>
                </div>
                <p className="cr-moment">{momentText(now)}</p>
                <p className="sr-only" aria-live="polite">
                    {said}
                </p>
                <div className="cr-controls" role="group" aria-label="Replay">
                    <Tooltip content="The previous moment" relationship="label">
                        <Button size="small" appearance="subtle" icon={<Previous16Regular />} disabled={!previousEvent} onClick={() => previousEvent && seek(toMinute(previousEvent.at.getTime()))} />
                    </Tooltip>
                    <Button
                        size="small"
                        appearance="primary"
                        icon={playing ? <Pause16Filled /> : <Play16Filled />}
                        aria-pressed={playing}
                        onClick={() => {
                            if (!playing && position >= total) onMinute(0);
                            setSaid(playing ? `Paused at ${formatTimeUtc(new Date(now))} UTC.` : `Playing at ${speed}×.`);
                            setPlaying((p) => !p);
                        }}
                    >
                        {playing ? "Pause" : "Play"}
                    </Button>
                    <Tooltip content="The next moment" relationship="label">
                        <Button size="small" appearance="subtle" icon={<Next16Regular />} disabled={!nextEvent} onClick={() => nextEvent && seek(toMinute(nextEvent.at.getTime()))} />
                    </Tooltip>
                    <span className="period" role="group" aria-label="Speed">
                        {SPEEDS.map((s) => (
                            <ToggleButton key={s} size="small" appearance="subtle" checked={speed === s} onClick={() => setSpeed(s)}>
                                {`${s}×`}
                            </ToggleButton>
                        ))}
                    </span>
                    {props.onCopyLink ? (
                        <Button size="small" appearance="subtle" icon={<Share16Regular />} onClick={props.onCopyLink}>
                            Link to this moment
                        </Button>
                    ) : null}
                </div>
                <input
                    className="cr-scrubber"
                    type="range"
                    min={0}
                    max={total}
                    step={1}
                    value={position}
                    onChange={(e) => {
                        setPlaying(false);
                        onMinute(Number(e.target.value));
                    }}
                    aria-label="Replay position"
                    aria-valuetext={`${formatTimeUtc(new Date(now))} UTC${current ? `, after ${current.label}` : ""}`}
                />
            </div>
            <div className="cr-body">
                <div className="cr-map">
                    <ServiceMap nodes={nodes} lens={props.lens} motion={props.motion} shockKeys={shockKeys} title={`ContosoCare's services at ${formatTimeUtc(new Date(now))} UTC`} hubLine={formatTimeUtc(new Date(now)) + " UTC"} dense />
                </div>
                <div className="cr-lanes" ref={ref}>
                    {lanes.map((lane) => (
                        <EngineLane key={lane.target} lane={lane} from={from} to={to} now={now} width={Math.max(120, size.width - 200)} />
                    ))}
                </div>
            </div>
            <SessionRibbon plan={plan} scores={scores} episodes={episodes} now={new Date(now)} onSelect={(ref) => {
                const e = events.find((x) => x.ref === ref);
                if (e) seek(toMinute(e.at.getTime()));
            }} onSeek={(at) => seek(toMinute(at.getTime()))} />
        </div>
    );
}
