import { arc } from "d3-shape";
import { motion } from "framer-motion";

import { useApp } from "@/app-context";
import type { Check, ReadinessSummary } from "@/data/model";
import { STATUSES, statusColor, statusMeta } from "@/lib/status";
import { areaRings, dialSegments, type AreaRing } from "./layout";

const colorOf = statusColor;

function ReadinessDial({ summary }: { summary: ReadinessSummary }) {
    const { reducedMotion } = useApp();
    const size = 220;
    const r = size / 2;
    const applicable = summary.checks - summary.notSupported - summary.notSelected;
    const share = applicable > 0 ? summary.passed / applicable : 0;
    const start = -Math.PI * 0.75;
    const sweep = Math.PI * 1.5;
    const track = arc<{ endAngle: number }>().innerRadius(r - 26).outerRadius(r - 10).startAngle(start).cornerRadius(8);
    const counts = STATUSES.map((s) => ({
        meta: s,
        count: [summary.failed, summary.manual, summary.warnings, summary.passed, summary.notSupported, summary.notSelected][s.sort - 1],
    }));
    const segments = dialSegments(counts, start, sweep);
    const segment = arc<{ startAngle: number; endAngle: number }>().innerRadius(r - 6).outerRadius(r - 1).padAngle(0.03).cornerRadius(2);
    const perfect = applicable > 0 && summary.passed === applicable;

    return (
        <svg className="viz" viewBox={`0 0 ${size} ${size}`} width={size} height={size} style={{ maxWidth: "100%" }}>
            <defs>
                <linearGradient id="dial-gradient" x1="0" y1="1" x2="1" y2="0">
                    <stop offset="0%" stopColor="var(--accent)" />
                    <stop offset="100%" stopColor="var(--accent-2)" />
                </linearGradient>
            </defs>
            <g transform={`translate(${r},${r})`}>
                <path d={track({ endAngle: start + sweep }) ?? ""} fill="var(--grid)" />
                <motion.path
                    d={track({ endAngle: start + sweep * Math.max(share, 0.001) }) ?? ""}
                    fill="url(#dial-gradient)"
                    initial={reducedMotion ? false : { opacity: 0, scale: 0.9 }}
                    animate={{ opacity: 1, scale: 1 }}
                    transition={{ duration: 0.8, ease: [0.16, 1, 0.3, 1] }}
                />
                {segments.map((x) => (
                    <path key={x.meta.name} d={segment({ startAngle: x.startAngle, endAngle: x.endAngle }) ?? ""} fill={colorOf(x.meta)}>
                        <title>{`${x.meta.name}: ${x.count}`}</title>
                    </path>
                ))}
                <text y={4} textAnchor="middle" className="label-strong" style={{ fontSize: 40 }}>
                    {`${Math.round(share * 100)}%`}
                </text>
                <text y={28} textAnchor="middle">{`${summary.passed} of ${applicable} applicable pass`}</text>
                {perfect && !reducedMotion
                    ? [0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
                          <motion.circle
                              key={i}
                              r={3}
                              fill="var(--status-warning)"
                              initial={{ opacity: 0, x: 0, y: 0 }}
                              animate={{ opacity: [0, 1, 0], x: Math.cos((i / 8) * Math.PI * 2) * 90, y: Math.sin((i / 8) * Math.PI * 2) * 90 }}
                              transition={{ duration: 1.6, repeat: Infinity, repeatDelay: 1.2, delay: i * 0.05 }}
                          />
                      ))
                    : null}
            </g>
        </svg>
    );
}

function AreaRingView({ ring, active, onSelect }: { ring: AreaRing; active: boolean; onSelect: () => void }) {
    const size = 120;
    const r = size / 2;
    const each = (Math.PI * 2) / Math.max(ring.checks.length, 1);
    const segment = arc<{ startAngle: number; endAngle: number; innerRadius: number; outerRadius: number }>().padAngle(0.05).cornerRadius(3);
    const worst = ring.worst ?? statusMeta("Not selected");
    return (
        <button type="button" className={`ring-tile${active ? " active" : ""}`} aria-pressed={active} onClick={onSelect} aria-label={`Area ${ring.area}: ${ring.checks.length} checks, worst ${worst.name}. Show its checks.`}>
            <svg className="viz" viewBox={`0 0 ${size} ${size}`} width={size} height={size} aria-hidden="true">
                <g transform={`translate(${r},${r})`}>
                    {ring.checks.map((c, i) => (
                        <path key={c.checkId} d={segment({ startAngle: i * each, endAngle: (i + 1) * each, innerRadius: r - 14, outerRadius: r - 3 }) ?? ""} fill={colorOf(statusMeta(c.status))}>
                            <title>{`${c.checkId}: ${c.status}`}</title>
                        </path>
                    ))}
                    {ring.history.slice(0, 4).map((h, i) => (
                        <circle key={h.runId} r={r - 20 - i * 7} fill="none" stroke={h.worst ? colorOf(h.worst) : "var(--grid)"} strokeOpacity="0.7" strokeWidth="3" />
                    ))}
                    <text y={6} textAnchor="middle" className="label-strong" style={{ fontSize: 18, fill: colorOf(worst) }}>
                        {worst.glyph}
                    </text>
                </g>
            </svg>
            <strong>{ring.area}</strong>
            <span>{`${ring.checks.length} check${ring.checks.length === 1 ? "" : "s"} · worst ${worst.short}`}</span>
        </button>
    );
}

/** Mission-control readiness: the dial for the latest run and one ring per area (outer: this run's checks; inner:
 *  the worst status of earlier runs). Selecting an area filters the check list. */
export function ReadinessRings({ checks, summary, area, onArea }: { checks: Check[]; summary: ReadinessSummary | null; area: string | null; onArea: (area: string | null) => void }) {
    const { areas, runs } = areaRings(checks);
    return (
        <div className="readiness-rings">
            {summary ? <ReadinessDial summary={summary} /> : null}
            <div className="ring-grid">
                {areas.map((ring) => (
                    <AreaRingView key={ring.area} ring={ring} active={area === ring.area} onSelect={() => onArea(area === ring.area ? null : ring.area)} />
                ))}
            </div>
            <p className="dax-meta">{runs.length > 1 ? `Inner rings: the worst status in each of the ${runs.length - 1} earlier runs.` : "One validation run so far; earlier runs appear as inner rings."}</p>
        </div>
    );
}
