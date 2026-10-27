import { useMemo } from "react";

import { useApp } from "@/app-context";
import { TARGET_INFO, type TargetSummary } from "@/data/model";
import type { TargetKey } from "@/lib/dax";
import { formatNumber, type NumberKind } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";
import { statusBySort, statusMeta } from "@/lib/status";

interface Satellite {
    key: keyof TargetSummary;
    label: string;
    kind: NumberKind;
    color: string;
}

const SATELLITES: Satellite[] = [
    { key: "waitS", label: "Wait time", kind: "seconds", color: "var(--accent)" },
    { key: "bufferIoS", label: "Buffer IO waits", kind: "seconds", color: "var(--accent-2)" },
    { key: "cpuPeak", label: "CPU peak", kind: "percent", color: "var(--accent-3)" },
    { key: "sessionsPeak", label: "Active sessions, peak", kind: "int", color: "var(--status-manual)" },
    { key: "batch", label: "Batch requests", kind: "int", color: "var(--status-pass)" },
    { key: "blockedPeak", label: "Blocked processes, peak", kind: "int", color: "var(--status-fail)" },
    { key: "logRateS", label: "Log Rate Governor waits", kind: "seconds", color: "var(--status-warning)" },
];

const ANGLE: Record<TargetKey, number> = { T1: -150, T2: -30, T3: 90 };
const COLOR: Record<TargetKey, string> = { T1: "var(--t1)", T2: "var(--t2)", T3: "var(--t3)" };
const STATUS_COLOR: Record<string, string> = {
    "--status-fail": "var(--status-fail)",
    "--status-manual": "var(--status-manual)",
    "--status-warning": "var(--status-warning)",
    "--status-pass": "var(--status-pass)",
    "--status-muted": "var(--status-muted)",
};

/** The estate as a constellation: the three targets orbit the hub, their signals orbit them as satellites sized by
 *  value, and a halo in the worst finding's status color pulses when something needs attention. */
export function Constellation({ targets, selected, onSelect }: { targets: TargetSummary[]; selected: TargetKey | null; onSelect: (key: TargetKey) => void }) {
    const { reducedMotion } = useApp();
    const [ref, { width }] = useElementSize<HTMLDivElement>(720);
    const w = Math.max(width, 320);
    const h = Math.round(Math.min(Math.max(w * 0.58, 320), 520));
    const cx = w / 2;
    const cy = h / 2 - 6;
    const rx = Math.min(w * 0.34, 380);
    const ry = Math.min(h * 0.32, 170);
    const compact = w < 560;

    const max = useMemo(() => {
        const out: Partial<Record<keyof TargetSummary, number>> = {};
        for (const s of SATELLITES) out[s.key] = Math.max(0, ...targets.map((t) => (t[s.key] as number | null) ?? 0));
        return out;
    }, [targets]);

    const activity = Math.max(1, ...targets.map((t) => t.waitS ?? 0));

    return (
        <div ref={ref} className="constellation">
            <svg className="viz" viewBox={`0 0 ${w} ${h}`} width={w} height={h} aria-hidden="false" role="presentation">
                <defs>
                    <radialGradient id="core-gradient">
                        <stop offset="0%" stopColor="var(--ink)" stopOpacity="0.95" />
                        <stop offset="45%" stopColor="var(--accent)" stopOpacity="0.85" />
                        <stop offset="100%" stopColor="var(--accent-2)" stopOpacity="0" />
                    </radialGradient>
                    {targets.map((t) => (
                        <radialGradient key={t.key} id={`planet-${t.key}`} cx="35%" cy="30%">
                            <stop offset="0%" stopColor="var(--ink)" stopOpacity="0.9" />
                            <stop offset="55%" stopColor={COLOR[t.key]} />
                            <stop offset="100%" stopColor={COLOR[t.key]} stopOpacity="0.55" />
                        </radialGradient>
                    ))}
                </defs>

                <ellipse cx={cx} cy={cy} rx={rx} ry={ry} fill="none" stroke="var(--grid)" strokeDasharray="2 6" />
                <ellipse cx={cx} cy={cy} rx={rx * 0.55} ry={ry * 0.55} fill="none" stroke="var(--grid)" />

                <circle className={reducedMotion ? undefined : "core-glow"} cx={cx} cy={cy} r={34} fill="url(#core-gradient)" />
                <text x={cx} y={cy + 52} textAnchor="middle" className="label-strong">
                    Estate history
                </text>

                {targets.map((t) => {
                    const angle = (ANGLE[t.key] * Math.PI) / 180;
                    const x = cx + rx * Math.cos(angle);
                    const y = cy + ry * Math.sin(angle);
                    const worst = statusBySort(t.worstFindingSort);
                    const status = worst ?? statusMeta("Not selected");
                    const statusText = worst ? `${worst.glyph} ${worst.short}` : "○ No findings";
                    const haloColor = STATUS_COLOR[status.token];
                    const planetR = compact ? 20 : 26;
                    const orbitR = planetR + (compact ? 22 : 30);
                    const flow = 0.6 + (2.4 * (t.waitS ?? 0)) / activity;
                    const shown = SATELLITES.filter((s) => ((t[s.key] as number | null) ?? 0) > 0);
                    const label = `${TARGET_INFO[t.key].name}. ${worst ? `Worst finding: ${worst.name}` : "No findings"}. ${shown
                        .map((s) => `${s.label} ${formatNumber(t[s.key], s.kind)}`)
                        .join(", ")}. Press Enter for details.`;
                    return (
                        <g key={t.key}>
                            <line
                                x1={cx}
                                y1={cy}
                                x2={x}
                                y2={y}
                                stroke={COLOR[t.key]}
                                strokeOpacity="0.55"
                                strokeWidth={flow}
                                strokeDasharray="3 9"
                                strokeLinecap="round"
                                className={reducedMotion ? undefined : "flow-line"}
                            />
                            <g
                                role="button"
                                tabIndex={0}
                                aria-pressed={selected === t.key}
                                aria-label={label}
                                onClick={() => onSelect(t.key)}
                                onKeyDown={(e) => {
                                    if (e.key === "Enter" || e.key === " ") {
                                        e.preventDefault();
                                        onSelect(t.key);
                                    }
                                }}
                            >
                                <circle className="focus-ring" cx={x} cy={y} r={orbitR + 10} />
                                {status.needsAttention ? (
                                    <circle className={reducedMotion ? undefined : "halo"} cx={x} cy={y} r={planetR + 6} fill="none" stroke={haloColor} strokeWidth="3" />
                                ) : null}
                                <circle cx={x} cy={y} r={planetR + 6} fill="none" stroke={haloColor} strokeWidth={selected === t.key ? 4 : 2} />
                                <circle cx={x} cy={y} r={orbitR} fill="none" stroke="var(--grid)" strokeDasharray="1 5" />
                                <circle cx={x} cy={y} r={planetR} fill={`url(#planet-${t.key})`} />
                                <text x={x} y={y + 4} textAnchor="middle" className="label-strong" style={{ fill: "var(--accent-ink)" }}>
                                    {t.key}
                                </text>
                                <g
                                    className={reducedMotion ? undefined : "orbit"}
                                    style={{ transformOrigin: `${x}px ${y}px`, ["--orbit-duration" as string]: `${50 + ANGLE[t.key] / 6}s` }}
                                >
                                    {shown.map((s, i) => {
                                        const a = (i / Math.max(shown.length, 1)) * Math.PI * 2 - Math.PI / 2;
                                        const value = (t[s.key] as number | null) ?? 0;
                                        const r = 3 + 8 * Math.sqrt(value / Math.max(max[s.key] ?? 1, 1e-9));
                                        return (
                                            <circle key={String(s.key)} cx={x + orbitR * Math.cos(a)} cy={y + orbitR * Math.sin(a)} r={r} fill={s.color} fillOpacity="0.9">
                                                <title>{`${t.key} ${s.label}: ${formatNumber(value, s.kind)}`}</title>
                                            </circle>
                                        );
                                    })}
                                </g>
                                <text x={x} y={y + orbitR + 22} textAnchor="middle" className="label-strong">
                                    {compact ? t.key : TARGET_INFO[t.key].name}
                                </text>
                                <text x={x} y={y + orbitR + 38} textAnchor="middle" style={{ fill: haloColor }}>
                                    {statusText}
                                    {t.lagMin !== null ? ` · lag ${formatNumber(t.lagMin, "minutes")}` : ""}
                                </text>
                            </g>
                        </g>
                    );
                })}
            </svg>
            <div className="legend" aria-hidden="true">
                {SATELLITES.map((s) => (
                    <span key={String(s.key)}>
                        <i style={{ background: s.color, borderRadius: "50%" }} />
                        {s.label}
                    </span>
                ))}
            </div>
        </div>
    );
}
