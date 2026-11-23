// The session ribbon (ADR 0030): the session's plan as Scenario Runs recorded it, one lane per target, each fault from
// its injection to its window's end, its signal's visible span, and its moments in shapes as well as colors: ▼ injected,
// ● signal visible, ◆ answered, ✓ recovered. In the replay it has a playhead and counts down to the next injection.

import { serviceOf } from "@/lib/business";
import { formatTimeUtc } from "@/lib/format";
import { nextInjection, TELEMETRY_LAG_MINUTES, type FaultScore, type MeasuredEpisode, type Plan } from "@/lib/scoreboard";
import type { EstateTarget } from "@/lib/view-state";
import { TargetChip } from "@/components/TargetChip";
import { MARKS, ribbonRange } from "./timeline";

const MIN = 60000;
const LANES: readonly EstateTarget[] = ["T1", "T2", "T3", "T4", "T4-replica", "T5"];

interface Item {
    ref: string;
    target: EstateTarget;
    title: string;
    from: number;
    to: number;
    visible: number | null;
    visibleEnd: number | null;
    injected: number | null;
    answered: number | null;
    recovered: number | null;
    label: string;
}

function itemsOf(scores: readonly FaultScore[], episodes: readonly MeasuredEpisode[]): Item[] {
    const t = (d: Date | null) => (d ? d.getTime() : null);
    const at = (d: Date | null) => (d ? `${formatTimeUtc(d)}` : "–");
    return [
        ...scores.map((s) => ({
            ref: s.key,
            target: s.target,
            title: s.title,
            from: s.injectedAt.getTime(),
            to: s.injectedEnd.getTime(),
            visible: t(s.visibleAt),
            visibleEnd: s.visibleAt ? (s.recoveredAt ?? new Date(s.injectedEnd.getTime() + TELEMETRY_LAG_MINUTES * MIN)).getTime() : null,
            injected: s.injectedAt.getTime(),
            answered: t(s.answeredAt),
            recovered: t(s.recoveredAt),
            label: `${s.target} ${s.title}: injected ${at(s.injectedAt)}, signal visible ${at(s.visibleAt)}, answered ${at(s.answeredAt)}, recovered ${at(s.recoveredAt)} UTC. ${s.status === "Pass" ? "Signal seen." : s.note}`,
        })),
        ...episodes.map((e) => ({
            ref: e.key,
            target: e.target,
            title: e.signal,
            from: e.visibleAt.getTime(),
            to: (e.recoveredAt ?? e.endAt ?? e.visibleAt).getTime(),
            visible: e.visibleAt.getTime(),
            visibleEnd: (e.recoveredAt ?? e.endAt ?? e.visibleAt).getTime(),
            injected: null,
            answered: null,
            recovered: t(e.recoveredAt),
            label: `${e.target} ${e.signal}: visible ${at(e.visibleAt)}, recovered ${at(e.recoveredAt)} UTC. ${e.impact.sentence}.`,
        })),
    ];
}

export interface RibbonProps {
    plan: Plan;
    scores: readonly FaultScore[];
    episodes: readonly MeasuredEpisode[];
    /** The replay's moment, with a playhead and the countdown; absent outside the replay. */
    now?: Date | null;
    selected?: string | null;
    onSelect?: (ref: string) => void;
    /** Seeking by clicking the time axis (the replay). */
    onSeek?: (at: Date) => void;
}

const ROW = 15;

/** Puts a lane's items on rows so none overlaps another: faults that run at once on one target stack. */
function pack(items: readonly Item[]): { rowOf: Map<string, number>; rows: number } {
    const ends: number[] = [];
    const rowOf = new Map<string, number>();
    for (const item of [...items].sort((a, b) => a.from - b.from)) {
        let row = ends.findIndex((end) => end <= item.from);
        if (row < 0) {
            row = ends.length;
            ends.push(0);
        }
        ends[row] = Math.max(item.to, item.visibleEnd ?? 0, item.recovered ?? 0) + MIN;
        rowOf.set(item.ref, row);
    }
    return { rowOf, rows: Math.max(1, ends.length) };
}

export function SessionRibbon(props: RibbonProps) {
    const items = itemsOf(props.scores, props.episodes);
    const [from, to] = ribbonRange(props.plan, props.scores, props.episodes);
    const span = Math.max(to - from, MIN);
    const x = (t: number) => `${((t - from) / span) * 100}%`;
    const lanes = LANES.filter((l) => items.some((i) => i.target === l));
    const step = span > 6 * 3600000 ? 60 : span > 3 * 3600000 ? 30 : 15;
    const ticks: number[] = [];
    for (let t = Math.ceil(from / (step * MIN)) * step * MIN; t <= to; t += step * MIN) ticks.push(t);
    const now = props.now ?? null;
    const next = now ? nextInjection(props.scores, now) : null;
    return (
        <div className="rb" role="group" aria-label={`The plan of ${props.plan.label}, ${formatTimeUtc(props.plan.start)} to ${formatTimeUtc(props.plan.end)} UTC`}>
            {now ? (
                <p className="rb-countdown">
                    <span className="rb-now">{formatTimeUtc(now)} UTC</span>
                    {next ? (
                        <span>
                            {"Next: "}
                            <strong>{`${next.score.target} ${next.score.title}`}</strong>
                            {` in ${Math.max(1, Math.round(next.inMin))} min`}
                        </span>
                    ) : (
                        <span>No more injections in this session</span>
                    )}
                </p>
            ) : null}
            <div className="rb-lanes">
                {lanes.map((lane) => {
                    const mine = items.filter((i) => i.target === lane);
                    const { rowOf, rows } = pack(mine);
                    const top = (i: Item) => 4 + (rowOf.get(i.ref) ?? 0) * ROW;
                    return (
                        <div key={lane} className="rb-lane">
                            <div className="rb-lane-label">
                                <TargetChip target={lane} />
                                <span>{serviceOf(lane)?.service}</span>
                            </div>
                            <div className="rb-track" style={{ height: rows * ROW + 6 }}>
                                {mine.map((i) => (
                                    <button
                                        key={i.ref}
                                        type="button"
                                        className={`rb-item${i.injected === null ? " rb-measured" : ""}${props.selected === i.ref ? " rb-selected" : ""}`}
                                        style={{ left: x(i.from), top: top(i), width: `max(${((i.to - i.from) / span) * 100}%, 6px)` }}
                                        aria-label={i.label}
                                        title={i.label}
                                        aria-pressed={props.onSelect ? props.selected === i.ref : undefined}
                                        onClick={props.onSelect ? () => props.onSelect?.(i.ref) : undefined}
                                        tabIndex={props.onSelect ? 0 : -1}
                                    >
                                        <span className="sr-only">{i.title}</span>
                                    </button>
                                ))}
                                {mine
                                    .filter((i) => i.visible !== null && i.visibleEnd !== null)
                                    .map((i) => (
                                        <span
                                            key={`v-${i.ref}`}
                                            className="rb-visible"
                                            style={{ left: x(i.visible as number), top: top(i) + 4, width: `max(${(((i.visibleEnd as number) - (i.visible as number)) / span) * 100}%, 3px)` }}
                                            aria-hidden="true"
                                        />
                                    ))}
                                {mine.flatMap((i) =>
                                    (
                                        [
                                            ["injected", i.injected],
                                            ["visible", i.visible],
                                            ["answered", i.answered],
                                            ["recovered", i.recovered],
                                        ] as const
                                    )
                                        .filter(([, t]) => t !== null)
                                        .map(([kind, t]) => (
                                            <span key={`${i.ref}-${kind}`} className={`rb-mark rb-m-${kind}`} style={{ left: x(t as number), top: top(i) - 1 }} aria-hidden="true">
                                                {MARKS[kind]}
                                            </span>
                                        )),
                                )}
                            </div>
                        </div>
                    );
                })}
                {now ? <span className="rb-playhead" style={{ left: `calc(var(--rb-label) + (100% - var(--rb-label)) * ${(now.getTime() - from) / span})` }} aria-hidden="true" /> : null}
            </div>
            <div className="rb-axis" aria-hidden="true">
                <span className="rb-axis-label" />
                <div
                    className="rb-axis-track"
                    onClick={
                        props.onSeek
                            ? (event) => {
                                  const box = event.currentTarget.getBoundingClientRect();
                                  props.onSeek?.(new Date(from + ((event.clientX - box.left) / Math.max(box.width, 1)) * span));
                              }
                            : undefined
                    }
                >
                    {ticks.map((t) => (
                        <span key={t} style={{ left: x(t) }}>
                            {formatTimeUtc(new Date(t))}
                        </span>
                    ))}
                </div>
            </div>
            <p className="rb-legend">
                <span>
                    <b className="rb-m-injected">{MARKS.injected}</b> Injected
                </span>
                <span>
                    <b className="rb-m-visible">{MARKS.visible}</b> Signal visible in telemetry
                </span>
                <span>
                    <b className="rb-m-answered">{MARKS.answered}</b> Answered
                </span>
                <span>
                    <b className="rb-m-recovered">{MARKS.recovered}</b> Recovered
                </span>
                {props.episodes.length > 0 ? <span>Dotted: T4's and T5's episodes in their metrics (their injections aren't in the history)</span> : null}
            </p>
        </div>
    );
}
