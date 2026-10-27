import { useEffect, useMemo, useState } from "react";
import { arc } from "d3-shape";
import { scaleSqrt } from "d3-scale";
import { interpolateRgb } from "d3-interpolate";

import { useApp } from "@/app-context";
import { formatNumber } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";
import { THEMES } from "@/theme/themes";
import type { SpotlightRow } from "./layout";

/** The before-and-after spotlight: the wait "rose" morphs from the minutes before the window to the window itself. */
export function Spotlight({ rows }: { rows: SpotlightRow[] }) {
    const { theme, reducedMotion } = useApp();
    const [ref, { width }] = useElementSize<HTMLDivElement>(420);
    const [mix, setMix] = useState(100);
    const [pulsing, setPulsing] = useState(false);
    const size = Math.min(Math.max(width, 280), 440);
    const c = size / 2;
    const tokens = THEMES[theme].tokens;
    const tint = interpolateRgb(tokens["--accent-2"], tokens["--accent-3"]);
    const max = Math.max(1e-9, ...rows.flatMap((r) => [r.before, r.during]));
    const radius = scaleSqrt().domain([0, max]).range([6, size * 0.36]);
    const t = mix / 100;
    const petal = arc<{ startAngle: number; endAngle: number; outerRadius: number }>().innerRadius(0).padAngle(0.05).cornerRadius(6);

    useEffect(() => {
        if (!pulsing || reducedMotion) return;
        let frame = 0;
        const started = performance.now();
        const tick = (now: number) => {
            setMix(Math.round(50 + 50 * Math.sin(((now - started) / 2400) * Math.PI * 2 - Math.PI / 2)));
            frame = requestAnimationFrame(tick);
        };
        frame = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(frame);
    }, [pulsing, reducedMotion]);

    const biggest = useMemo(() => {
        let best: { category: string; ratio: number } | null = null;
        for (const r of rows) {
            if (r.before > 0 && r.during > 0) {
                const ratio = r.during / r.before;
                if (!best || ratio > best.ratio) best = { category: r.category, ratio };
            }
        }
        return best;
    }, [rows]);

    if (rows.length === 0) return <div className="empty">No wait categories in the padding before or inside this window.</div>;

    return (
        <div ref={ref} style={{ display: "grid", placeItems: "center", gap: 8 }}>
            <svg className="viz" viewBox={`0 0 ${size} ${size}`} width={size} height={size}>
                <g transform={`translate(${c},${c})`}>
                    {[0.25, 0.5, 0.75, 1].map((k) => (
                        <circle key={k} r={radius(max * k)} fill="none" stroke="var(--grid)" />
                    ))}
                    {rows.map((r, i) => {
                        const a0 = (i / rows.length) * Math.PI * 2;
                        const a1 = ((i + 1) / rows.length) * Math.PI * 2;
                        const value = r.before + (r.during - r.before) * t;
                        const outer = radius(value);
                        const mid = (a0 + a1) / 2 - Math.PI / 2;
                        const lr = size * 0.42;
                        return (
                            <g key={r.category}>
                                <path d={petal({ startAngle: a0, endAngle: a1, outerRadius: outer }) ?? ""} fill={tint(t)} fillOpacity={0.35 + 0.5 * (value / max)} stroke={tint(t)} strokeWidth="1.5">
                                    <title>{`${r.category}: ${formatNumber(r.before, "seconds")} per bin before, ${formatNumber(r.during, "seconds")} during`}</title>
                                </path>
                                <text x={lr * Math.cos(mid)} y={lr * Math.sin(mid)} textAnchor={Math.cos(mid) > 0.2 ? "start" : Math.cos(mid) < -0.2 ? "end" : "middle"} style={{ fontSize: 10.5 }}>
                                    {r.category.replace(" (PAGEIOLATCH)", "")}
                                </text>
                            </g>
                        );
                    })}
                    <text y={-4} textAnchor="middle" className="label-strong">
                        {t < 0.5 ? "Before" : "During"}
                    </text>
                    <text y={12} textAnchor="middle" style={{ fontSize: 10 }}>
                        {`${Math.round((1 - t) * 100)} / ${Math.round(t * 100)}`}
                    </text>
                </g>
            </svg>
            <label className="spotlight-slider">
                <span>Before</span>
                <input type="range" min={0} max={100} value={mix} onChange={(e) => { setPulsing(false); setMix(Number(e.target.value)); }} aria-label="Blend between the minutes before the window and the window itself" aria-valuetext={`${Math.round(t * 100)} % of the way to the incident window`} />
                <span>During</span>
            </label>
            <div className="dax-meta">
                {!reducedMotion ? (
                    <button type="button" className="icon-btn" aria-pressed={pulsing} onClick={() => setPulsing((p) => !p)}>
                        {pulsing ? "Stop the morph" : "Morph back and forth"}
                    </button>
                ) : null}
                {biggest ? <span>{`Biggest change: ${biggest.category} at ${biggest.ratio >= 10 ? Math.round(biggest.ratio) : biggest.ratio.toFixed(1)}× its level before the window.`}</span> : null}
            </div>
        </div>
    );
}
