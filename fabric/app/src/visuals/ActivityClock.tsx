import { useMemo, useState } from "react";
import { arc } from "d3-shape";
import { interpolateRgbBasis } from "d3-interpolate";

import { useApp } from "@/app-context";
import type { Bin } from "@/data/model";
import type { TargetKey } from "@/lib/dax";
import { formatNumber } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";
import type { ClockMetric } from "@/lib/view-state";
import { THEMES } from "@/theme/themes";
import { CLOCK_METRICS, clockCells, type ClockCell } from "./layout";

/** A 24-hour clock per target ring: when the estate works, and which target does the work. */
export function ActivityClock({ bins, targets, metric }: { bins: Bin[]; targets: TargetKey[]; metric: ClockMetric }) {
    const { theme } = useApp();
    const [ref, { width }] = useElementSize<HTMLDivElement>(420);
    const [hover, setHover] = useState<ClockCell | null>(null);
    const size = Math.min(Math.max(width, 280), 460);
    const c = size / 2;
    const cells = useMemo(() => clockCells(bins, metric, targets), [bins, metric, targets]);
    const max = Math.max(0, ...cells.map((x) => x.value));
    const tokens = THEMES[theme].tokens;
    const color = interpolateRgbBasis([tokens["--heat-1"], tokens["--heat-2"], tokens["--heat-3"]]);
    const inner = size * 0.2;
    const ringWidth = (size * 0.42 - inner) / Math.max(targets.length, 1);
    const wedge = arc<{ innerRadius: number; outerRadius: number; startAngle: number; endAngle: number }>().padAngle(0.012).cornerRadius(3);
    const busiest = cells.reduce<ClockCell | null>((best, x) => (!best || x.value > best.value ? x : best), null);
    const shown = hover ?? busiest;
    const { label, kind } = CLOCK_METRICS[metric];

    return (
        <div ref={ref} style={{ display: "grid", placeItems: "center" }}>
            <svg className="viz" viewBox={`0 0 ${size} ${size}`} width={size} height={size} onMouseLeave={() => setHover(null)}>
                <g transform={`translate(${c},${c})`}>
                    {targets.map((t, ring) => (
                        <g key={t}>
                            {cells
                                .filter((x) => x.target === t)
                                .map((x) => {
                                    const start = (x.hour / 24) * Math.PI * 2;
                                    const d = wedge({ innerRadius: inner + ring * ringWidth + 2, outerRadius: inner + (ring + 1) * ringWidth, startAngle: start, endAngle: start + (Math.PI * 2) / 24 }) ?? "";
                                    const fill = x.value > 0 && max > 0 ? color(Math.sqrt(x.value / max)) : tokens["--heat-0"];
                                    return (
                                        <path key={x.hour} d={d} fill={fill} stroke={hover === x ? "var(--ink)" : "none"} strokeWidth={2} onMouseEnter={() => setHover(x)}>
                                            <title>{`${t}, ${String(x.hour).padStart(2, "0")}:00 UTC: ${formatNumber(x.value, kind)} ${label.toLowerCase()}`}</title>
                                        </path>
                                    );
                                })}
                            <text x={4} y={-(inner + ring * ringWidth + ringWidth / 2) + 4} className="label-strong" style={{ fontSize: 10 }}>
                                {t}
                            </text>
                        </g>
                    ))}
                    {[0, 6, 12, 18].map((h) => {
                        const a = (h / 24) * Math.PI * 2 - Math.PI / 2;
                        const r = size * 0.46;
                        return (
                            <text key={h} x={r * Math.cos(a)} y={r * Math.sin(a) + 4} textAnchor="middle">
                                {`${String(h).padStart(2, "0")}:00`}
                            </text>
                        );
                    })}
                    <text y={-6} textAnchor="middle" className="label-strong" style={{ fontSize: 18 }}>
                        {shown && shown.value > 0 ? `${String(shown.hour).padStart(2, "0")}:00` : "–"}
                    </text>
                    <text y={12} textAnchor="middle">
                        {shown && shown.value > 0 ? `${shown.target} · ${formatNumber(shown.value, kind)}` : "no activity"}
                    </text>
                    <text y={27} textAnchor="middle" style={{ fontSize: 10 }}>
                        {hover ? "hovered hour (UTC)" : "busiest hour (UTC)"}
                    </text>
                </g>
            </svg>
            <div className="legend" aria-hidden="true">
                <span>
                    <i style={{ background: tokens["--heat-0"] }} /> none
                </span>
                <span>
                    <i style={{ background: color(0.15) }} /> low
                </span>
                <span>
                    <i style={{ background: color(0.6) }} /> busy
                </span>
                <span>
                    <i style={{ background: color(1) }} /> peak
                </span>
                <span>Rings, inside out: {targets.join(", ")}</span>
            </div>
        </div>
    );
}
