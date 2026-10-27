import { useEffect, useId, useMemo, useState } from "react";
import { area, curveMonotoneX, line } from "d3-shape";
import { scaleLinear, scaleUtc } from "d3-scale";
import { Pause, Play, SkipBack, SkipForward, Target as TargetIcon } from "lucide-react";

import { useApp } from "@/app-context";
import { FAMILY_LABEL, type Bin, type Incident } from "@/data/model";
import { formatDateTimeUtc, formatNumber, formatTimeUtc, type NumberKind } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";
import { compareIncident, familySignal, incidentPadMinutes } from "@/lib/insights";
import { binMinutes, phaseOf } from "./layout";

interface Lane {
    field: keyof Bin;
    label: string;
    kind: NumberKind;
    color: string;
}

const LANES: Lane[] = [
    { field: "waitS", label: "Wait time", kind: "seconds", color: "var(--accent)" },
    { field: "sessions", label: "Active sessions", kind: "int", color: "var(--status-manual)" },
    { field: "batch", label: "Batch requests", kind: "int", color: "var(--status-pass)" },
    { field: "ioMb", label: "Data and log IO", kind: "mb", color: "var(--accent-2)" },
    { field: "cpu", label: "CPU", kind: "percent", color: "var(--accent-3)" },
];

/** Plays an incident back bin by bin: the incident's own signal with its window, baseline, and peak, and every
 *  other signal as a lane, with a scrubber, steps, speeds, and a live readout. */
export function IncidentReplay({ incident, bins, index, onIndex }: { incident: Incident; bins: Bin[]; index: number | null; onIndex: (i: number) => void }) {
    const { reducedMotion } = useApp();
    const [ref, { width }] = useElementSize<HTMLDivElement>(900);
    const [playing, setPlaying] = useState(false);
    const [speed, setSpeed] = useState(1);
    const clipId = useId().replace(/:/g, "");
    const focus = familySignal(incident.family);
    const comparison = useMemo(() => compareIncident(incident, bins), [incident, bins]);
    const step = binMinutes(bins);
    const firstInWindow = Math.max(0, bins.findIndex((b) => b.at >= incident.start));
    const position = Math.min(Math.max(index ?? firstInWindow, 0), Math.max(bins.length - 1, 0));
    const current = bins[position];

    useEffect(() => {
        if (!playing || position >= bins.length - 1) return;
        const timer = window.setTimeout(() => {
            onIndex(position + 1);
            if (position + 1 >= bins.length - 1) setPlaying(false);
        }, 900 / speed);
        return () => window.clearTimeout(timer);
    }, [playing, position, speed, bins.length, onIndex]);

    const w = Math.max(width, 320);
    const left = 54;
    const right = 16;
    const mainH = 210;
    const laneH = 46;
    const h = mainH + LANES.length * laneH + 34;
    const t0 = bins[0]?.at ?? incident.start;
    const t1 = new Date((bins[bins.length - 1]?.at ?? incident.end).getTime() + step * 60000);
    const x = scaleUtc().domain([t0, t1]).range([left, w - right]);
    const mid = (b: Bin) => x(new Date(b.at.getTime() + (step * 60000) / 2));
    const focusValues = bins.map((b) => (b[focus.field] as number | null) ?? null);
    const focusMax = Math.max(1e-9, ...focusValues.map((v) => v ?? 0), comparison.baseline ?? 0);
    const y = scaleLinear().domain([0, focusMax * 1.15]).range([mainH - 24, 16]);
    const defined = bins.filter((b) => b[focus.field] !== null);
    const focusArea = area<Bin>()
        .x(mid)
        .y0(mainH - 24)
        .y1((b) => y((b[focus.field] as number) ?? 0))
        .curve(curveMonotoneX);
    const focusLine = line<Bin>()
        .x(mid)
        .y((b) => y((b[focus.field] as number) ?? 0))
        .curve(curveMonotoneX);
    const headX = current ? mid(current) : left;
    const ticks = x.ticks(Math.max(2, Math.floor(w / 140)));
    const phase = current ? phaseOf(incident, current.at) : "before";
    const value = current ? (current[focus.field] as number | null) : null;
    const ratio = value !== null && comparison.baseline ? value / comparison.baseline : null;
    const peakBin = comparison.peakAt ? bins.find((b) => b.at.getTime() === comparison.peakAt?.getTime()) : undefined;

    if (bins.length === 0) {
        return <div className="empty">No telemetry bins on {incident.target} around this window.</div>;
    }

    return (
        <div ref={ref} className="replay">
            <svg className="viz" viewBox={`0 0 ${w} ${h}`} width={w} height={h}>
                <defs>
                    <clipPath id={`reveal-${clipId}`}>
                        <rect x={0} y={0} width={headX} height={h} />
                    </clipPath>
                    <linearGradient id={`focus-fill-${clipId}`} x1="0" y1="0" x2="0" y2="1">
                        <stop offset="0%" stopColor="var(--accent-3)" stopOpacity="0.55" />
                        <stop offset="100%" stopColor="var(--accent)" stopOpacity="0.04" />
                    </linearGradient>
                </defs>

                <rect x={x(incident.start)} y={8} width={Math.max(2, x(incident.end) - x(incident.start))} height={h - 30} rx={10} fill="var(--accent)" fillOpacity="0.12" stroke="var(--accent)" strokeOpacity="0.45" strokeDasharray="4 6" />
                <text x={x(incident.start) + 8} y={24} className="label-strong" style={{ fill: "var(--accent)" }}>
                    {FAMILY_LABEL[incident.family] ?? "Incident"} window
                </text>

                {ticks.map((t) => (
                    <g key={t.getTime()}>
                        <line className="gridline" x1={x(t)} x2={x(t)} y1={8} y2={h - 26} />
                        <text x={x(t)} y={h - 10} textAnchor="middle">
                            {formatTimeUtc(t)}
                        </text>
                    </g>
                ))}

                <text x={4} y={20} className="label-strong">
                    {focus.label}
                </text>
                <path d={focusArea(defined) ?? ""} fill={`url(#focus-fill-${clipId})`} opacity="0.35" />
                <path d={focusLine(defined) ?? ""} fill="none" stroke="var(--ink-faint)" strokeWidth="1.5" strokeDasharray="3 4" />
                <g clipPath={`url(#reveal-${clipId})`}>
                    <path d={focusArea(defined) ?? ""} fill={`url(#focus-fill-${clipId})`} />
                    <path d={focusLine(defined) ?? ""} fill="none" stroke="var(--accent-3)" strokeWidth="3" />
                </g>
                {comparison.baseline !== null ? (
                    <g>
                        <line x1={left} x2={w - right} y1={y(comparison.baseline)} y2={y(comparison.baseline)} stroke="var(--accent-2)" strokeDasharray="6 5" strokeWidth="1.5" />
                        <text x={w - right} y={y(comparison.baseline) - 6} textAnchor="end" style={{ fill: "var(--accent-2)" }}>
                            {`baseline ${formatNumber(comparison.baseline, focus.kind)}`}
                        </text>
                    </g>
                ) : null}
                {peakBin && comparison.peak !== null ? (
                    <g>
                        <circle cx={mid(peakBin)} cy={y(comparison.peak)} r="6" fill="var(--bg)" stroke="var(--accent-3)" strokeWidth="3" />
                        <text x={mid(peakBin)} y={y(comparison.peak) - 12} textAnchor="middle" className="label-strong">
                            {`peak ${formatNumber(comparison.peak, focus.kind)}`}
                        </text>
                    </g>
                ) : null}

                {LANES.map((lane, i) => {
                    const top = mainH + i * laneH;
                    const values = bins.map((b) => (b[lane.field] as number | null) ?? null);
                    const laneMax = Math.max(1e-9, ...values.map((v) => v ?? 0));
                    const ly = scaleLinear().domain([0, laneMax]).range([top + laneH - 8, top + 10]);
                    const pts = bins.filter((b) => b[lane.field] !== null);
                    const path = line<Bin>().x(mid).y((b) => ly((b[lane.field] as number) ?? 0)).curve(curveMonotoneX)(pts) ?? "";
                    const now = current ? (current[lane.field] as number | null) : null;
                    return (
                        <g key={String(lane.field)}>
                            <line className="gridline" x1={left} x2={w - right} y1={top + laneH - 8} y2={top + laneH - 8} />
                            <text x={4} y={top + 22}>
                                {lane.label}
                            </text>
                            <path d={path} fill="none" stroke={lane.color} strokeOpacity="0.35" strokeWidth="1.5" />
                            <g clipPath={`url(#reveal-${clipId})`}>
                                <path d={path} fill="none" stroke={lane.color} strokeWidth="2.2" />
                            </g>
                            {now !== null && current ? <circle cx={mid(current)} cy={ly(now)} r="4" fill={lane.color} /> : null}
                            <text x={w - right} y={top + 22} textAnchor="end" className="label-strong" style={{ fontSize: 11 }}>
                                {formatNumber(now, lane.kind)}
                            </text>
                        </g>
                    );
                })}

                <line x1={headX} x2={headX} y1={8} y2={h - 26} stroke="var(--ink)" strokeWidth="2" style={reducedMotion ? undefined : { transition: "all 0.35s cubic-bezier(0.16, 1, 0.3, 1)" }} />
                {value !== null && current ? <circle cx={headX} cy={y(value)} r="7" fill="var(--accent-3)" stroke="var(--ink)" strokeWidth="2" /> : null}
            </svg>

            <div className="replay-controls">
                <button type="button" className="icon-btn" onClick={() => onIndex(Math.max(position - 1, 0))} aria-label="Previous bin" title="Previous bin">
                    <SkipBack aria-hidden="true" />
                </button>
                <button
                    type="button"
                    className="icon-btn replay-play"
                    aria-pressed={playing}
                    onClick={() => {
                        if (!playing && position >= bins.length - 1) onIndex(0);
                        setPlaying((p) => !p);
                    }}
                >
                    {playing ? <Pause aria-hidden="true" /> : <Play aria-hidden="true" />}
                    {playing ? "Pause" : "Play"}
                </button>
                <button type="button" className="icon-btn" onClick={() => onIndex(Math.min(position + 1, bins.length - 1))} aria-label="Next bin" title="Next bin">
                    <SkipForward aria-hidden="true" />
                </button>
                <input
                    className="scrubber"
                    type="range"
                    min={0}
                    max={bins.length - 1}
                    value={position}
                    onChange={(e) => {
                        setPlaying(false);
                        onIndex(Number(e.target.value));
                    }}
                    aria-label="Replay position"
                    aria-valuetext={current ? `${formatDateTimeUtc(current.at)}, ${phase} the incident window` : ""}
                />
                <div className="segmented" role="group" aria-label="Replay speed">
                    {[1, 2, 4].map((s) => (
                        <button key={s} type="button" aria-pressed={speed === s} onClick={() => setSpeed(s)}>
                            {s}×
                        </button>
                    ))}
                </div>
                {peakBin ? (
                    <button type="button" className="icon-btn" onClick={() => onIndex(bins.indexOf(peakBin))}>
                        <TargetIcon aria-hidden="true" /> Peak
                    </button>
                ) : null}
            </div>
            <p className="replay-readout" aria-live="polite">
                <strong>{current ? `${formatDateTimeUtc(current.at)}` : ""}</strong>
                {` · ${phase === "during" ? "inside the incident window" : phase === "before" ? "before the window" : "after the window"} · ${focus.label} ${formatNumber(value, focus.kind)}`}
                {ratio !== null && Number.isFinite(ratio) ? ` (${ratio >= 10 ? Math.round(ratio) : ratio.toFixed(1)}× the baseline)` : ""}
                {` · ${step}-minute bins, padded ${incidentPadMinutes(incident)} minutes each side`}
            </p>
        </div>
    );
}
