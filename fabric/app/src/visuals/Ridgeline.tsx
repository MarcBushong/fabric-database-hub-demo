import { useMemo } from "react";
import { area, curveBasis, line } from "d3-shape";
import { scaleLinear } from "d3-scale";

import { useApp } from "@/app-context";
import type { Bin } from "@/data/model";
import type { TargetKey } from "@/lib/dax";
import { formatNumber } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";
import { density, quantile } from "@/lib/stats";
import type { SignalId } from "@/lib/view-state";
import { RIDGE_SIGNALS, ridges } from "./layout";

const COLOR: Record<TargetKey, string> = { T1: "var(--t1)", T2: "var(--t2)", T3: "var(--t3)" };

/** Joy plot: the distribution of a signal's per-bin values on each target, so spikes and steady states stand apart. */
export function Ridgeline({ bins, targets, signal }: { bins: Bin[]; targets: TargetKey[]; signal: SignalId }) {
    const { reducedMotion } = useApp();
    const [ref, { width }] = useElementSize<HTMLDivElement>(560);
    const w = Math.max(width, 300);
    const rowGap = 64;
    const top = 26;
    const left = 44;
    const right = 18;
    const data = useMemo(() => ridges(bins, signal, targets), [bins, signal, targets]);
    const max = Math.max(0, ...data.map((r) => quantile(r.values, 0.99) ?? 0));
    const domainMax = max > 0 ? max : 1;
    const h = top + rowGap * data.length + 40;
    const x = scaleLinear().domain([0, domainMax]).range([left, w - right]).nice();
    const ticks = x.ticks(Math.max(2, Math.floor(w / 120)));
    const { kind, label } = RIDGE_SIGNALS[signal];

    return (
        <div ref={ref}>
            <svg className="viz" viewBox={`0 0 ${w} ${h}`} width={w} height={h}>
                <defs>
                    {data.map((r) => (
                        <linearGradient key={r.target} id={`ridge-${r.target}`} x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stopColor={COLOR[r.target]} stopOpacity="0.75" />
                            <stop offset="100%" stopColor={COLOR[r.target]} stopOpacity="0.05" />
                        </linearGradient>
                    ))}
                </defs>
                {ticks.map((t) => (
                    <g key={t}>
                        <line className="gridline" x1={x(t)} x2={x(t)} y1={top - 10} y2={h - 30} />
                        <text x={x(t)} y={h - 12} textAnchor="middle">
                            {formatNumber(t, kind)}
                        </text>
                    </g>
                ))}
                {data.map((r, i) => {
                    const base = top + rowGap * (i + 1);
                    const amp = rowGap * 1.35;
                    const points = r.values.length > 0 ? density(r.values, 0, domainMax, 72) : [];
                    const shape = area<[number, number]>()
                        .x((p) => x(p[0]))
                        .y0(base)
                        .y1((p) => base - p[1] * amp)
                        .curve(curveBasis);
                    const edge = line<[number, number]>()
                        .x((p) => x(p[0]))
                        .y((p) => base - p[1] * amp)
                        .curve(curveBasis);
                    return (
                        <g key={r.target} style={reducedMotion ? undefined : { animation: `rise 0.9s ${0.12 * i}s both cubic-bezier(0.16, 1, 0.3, 1)` }}>
                            <line className="gridline" x1={left} x2={w - right} y1={base} y2={base} />
                            <text x={4} y={base - 4} className="label-strong">
                                {r.target}
                            </text>
                            {points.length > 0 ? (
                                <>
                                    <path d={shape(points) ?? ""} fill={`url(#ridge-${r.target})`} />
                                    <path d={edge(points) ?? ""} fill="none" stroke={COLOR[r.target]} strokeWidth="2" />
                                    {r.median !== null ? <line x1={x(r.median)} x2={x(r.median)} y1={base} y2={base - 10} stroke="var(--ink)" strokeWidth="2" /> : null}
                                    {r.p95 !== null ? (
                                        <g>
                                            <circle cx={Math.min(x(r.p95), w - right)} cy={base - 4} r="3.5" fill="var(--ink)" />
                                            <text x={Math.min(x(r.p95), w - right) - 6} y={base - 12} textAnchor="end" style={{ fontSize: 10 }}>
                                                {`p95 ${formatNumber(r.p95, kind)}`}
                                            </text>
                                        </g>
                                    ) : null}
                                    <text x={w - right} y={base + 14} textAnchor="end" style={{ fontSize: 10 }}>
                                        {`${r.values.length} bins · median ${formatNumber(r.median, kind)}`}
                                    </text>
                                </>
                            ) : (
                                <text x={left + 8} y={base - 8}>
                                    No bins with {label.toLowerCase()} in this period
                                </text>
                            )}
                        </g>
                    );
                })}
            </svg>
        </div>
    );
}
