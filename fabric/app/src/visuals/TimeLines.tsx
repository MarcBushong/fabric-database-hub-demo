import { curveMonotoneX, line } from "d3-shape";
import { scaleLinear, scaleUtc } from "d3-scale";

import { formatNumber, formatTimeUtc, type NumberKind } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";

export interface TimePoint {
    at: Date;
    value: number;
}

export interface TimeLine {
    id: string;
    label: string;
    color: string;
    points: readonly TimePoint[];
    dashed?: boolean;
}

export interface TimeLinesProps {
    lines: readonly TimeLine[];
    kind: NumberKind;
    /** What the chart shows, for screen readers. */
    label: string;
    /** The time axis: the capture's window when it's known, otherwise the points' own span. */
    from?: Date | null;
    to?: Date | null;
    /** A dashed reference line, such as a warning threshold. */
    threshold?: { value: number; label: string } | null;
    /** A marked point, such as a series' peak. */
    peak?: { at: Date; value: number; label: string } | null;
    height?: number;
}

const isTime = (value: Date | null | undefined): value is Date => value instanceof Date && Number.isFinite(value.getTime());

/** Lines of one unit over UTC time, with an optional threshold and a marked peak, for T4's metrics. */
export function TimeLines({ lines, kind, label, from, to, threshold, peak, height = 220 }: TimeLinesProps) {
    const [ref, { width }] = useElementSize<HTMLDivElement>(640);
    const shown = lines.filter((l) => l.points.length > 0);
    const times = shown.flatMap((l) => l.points.map((p) => p.at.getTime()));
    if (times.length === 0) {
        // The same element keeps the size observer, so the chart takes the card's width once points arrive.
        return (
            <div ref={ref} className="time-lines">
                <div className="empty">No points to draw.</div>
            </div>
        );
    }
    const w = Math.max(width, 320);
    const left = 58;
    const right = 18;
    const top = 16;
    const bottom = 30;
    const start = Math.min(isTime(from) ? from.getTime() : Infinity, ...times);
    const end = Math.max(isTime(to) ? to.getTime() : -Infinity, ...times);
    const x = scaleUtc()
        .domain([new Date(start), new Date(end > start ? end : start + 60000)])
        .range([left, w - right]);
    const highest = Math.max(1e-9, threshold?.value ?? 0, ...shown.flatMap((l) => l.points.map((p) => p.value)));
    const y = scaleLinear()
        .domain([0, highest * 1.15])
        .range([height - bottom, top])
        .nice();
    const xTicks = x.ticks(Math.max(2, Math.floor(w / 130)));
    const yTicks = y.ticks(4);
    const path = line<TimePoint>()
        .x((p) => x(p.at))
        .y((p) => y(p.value))
        .curve(curveMonotoneX);
    const peakX = peak ? x(peak.at) : 0;

    return (
        <div ref={ref} className="time-lines">
            <svg className="viz" viewBox={`0 0 ${w} ${height}`} width={w} height={height} role="img" aria-label={label}>
                {yTicks.map((v) => (
                    <g key={`y-${v}`}>
                        <line className="gridline" x1={left} x2={w - right} y1={y(v)} y2={y(v)} />
                        <text x={left - 8} y={y(v) + 4} textAnchor="end">
                            {formatNumber(v, kind)}
                        </text>
                    </g>
                ))}
                {xTicks.map((t) => (
                    <text key={`x-${t.getTime()}`} x={x(t)} y={height - 10} textAnchor="middle">
                        {formatTimeUtc(t)}
                    </text>
                ))}
                {threshold ? (
                    <g>
                        <line x1={left} x2={w - right} y1={y(threshold.value)} y2={y(threshold.value)} stroke="var(--status-warning)" strokeDasharray="6 5" strokeWidth="1.5" />
                        <text x={w - right} y={y(threshold.value) - 6} textAnchor="end" style={{ fill: "var(--status-warning)" }}>
                            {threshold.label}
                        </text>
                    </g>
                ) : null}
                {shown.map((l) => (
                    <g key={l.id}>
                        <path d={path([...l.points]) ?? ""} fill="none" stroke={l.color} strokeWidth="2.4" strokeDasharray={l.dashed ? "5 4" : undefined} />
                        {l.points.length === 1 ? <circle cx={x(l.points[0].at)} cy={y(l.points[0].value)} r="4" fill={l.color} /> : null}
                    </g>
                ))}
                {peak ? (
                    <g>
                        <circle cx={peakX} cy={y(peak.value)} r="6" fill="var(--bg)" stroke="var(--accent-3)" strokeWidth="3" />
                        <text x={Math.min(Math.max(peakX, left + 40), w - right - 40)} y={y(peak.value) - 12} textAnchor="middle" className="label-strong">
                            {peak.label}
                        </text>
                    </g>
                ) : null}
            </svg>
            <div className="legend">
                {shown.map((l) => (
                    <span key={l.id}>
                        <i style={{ background: l.color }} />
                        {l.label}
                    </span>
                ))}
            </div>
        </div>
    );
}
