// ChartView: one chart component for the whole app. It draws a ChartSpec (the Copilot contract's chart) as a line,
// area, bar, stacked bar, scatter, table, or KPI tiles, with the app's colors, axes, tooltip, legend, and keyboard
// reading. The app's own visuals add annotations (thresholds, incident bands, markers) that a ChartSpec doesn't carry.

import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import { scaleBand, scaleLinear, scalePoint, scaleUtc } from "d3-scale";
import { area as d3area, curveMonotoneX, line as d3line } from "d3-shape";

import type { ChartSpec, ContextRow } from "@/copilot/contract";
import { AXIS_ROTATION_DEG, buildChartModel, categoryAxis, describeModel, formatTick, formatValue, formatX, labelWidth, nearestIndex, numberOf, seriesColor, timeOf, truncateLabel, yDomain, type ChartModel, type ChartPoint, type ChartSeries } from "./chart-kit";

import "./chart-view.css";

export interface ChartThreshold {
    value: number;
    label: string;
    tone?: "warning" | "danger" | "neutral";
}

export interface ChartBand {
    from: number | string | Date;
    to: number | string | Date;
    label?: string;
    tone?: "incident" | "neutral";
}

export interface ChartMarker {
    x: number | string | Date;
    y: number;
    label: string;
}

export interface ChartAnnotations {
    thresholds?: ChartThreshold[];
    bands?: ChartBand[];
    markers?: ChartMarker[];
}

export interface ChartSelection {
    series: string;
    x: number | string;
    y: number | null;
    row: ContextRow;
}

export interface ChartViewProps {
    spec: ChartSpec;
    /** The plot's height in pixels (line, area, bar, and scatter). */
    height?: number;
    annotations?: ChartAnnotations;
    /** Colors by series key; targets (T1 to T5, T4-replica) and the palette fill in the rest. */
    colors?: Record<string, string>;
    /** Series keys drawn dashed. */
    dashed?: readonly string[];
    /** Hide the title and subtitle when a card around the chart shows them. */
    hideHeader?: boolean;
    onSelect?: (selection: ChartSelection) => void;
}

const MARGIN = { top: 12, right: 16, bottom: 26 };

function useWidth<T extends HTMLElement>(fallback: number): [React.RefObject<T | null>, number] {
    const ref = useRef<T | null>(null);
    const [width, setWidth] = useState(fallback);
    useEffect(() => {
        const node = ref.current;
        if (!node || typeof ResizeObserver === "undefined") return;
        const observer = new ResizeObserver((entries) => {
            const next = Math.floor(entries[0]?.contentRect.width ?? 0);
            if (next > 0) setWidth(next);
        });
        observer.observe(node);
        return () => observer.disconnect();
    }, []);
    return [ref, width];
}

function annotationX(value: number | string | Date, model: ChartModel): number | string | null {
    if (model.xKind === "time") return timeOf(value instanceof Date ? value : typeof value === "number" ? new Date(value) : value);
    if (model.xKind === "number" || model.xKind === "index") return numberOf(value);
    return String(value);
}

export function ChartView(props: ChartViewProps) {
    const { spec } = props;
    const titleId = useId();
    const summaryId = useId();
    const model = useMemo(() => buildChartModel(spec), [spec]);
    const summary = useMemo(() => describeModel(model, spec.title), [model, spec.title]);

    let body;
    if (spec.kind === "kpi") body = <KpiTiles spec={spec} model={model} />;
    else if (spec.kind === "table") body = <ChartTable spec={spec} model={model} />;
    else if (model.series.length === 0 || model.xs.length === 0) body = <p className="chart-empty">No data to chart.</p>;
    else body = <Plot {...props} model={model} titleId={titleId} summaryId={summaryId} />;

    return (
        <figure className="chart" aria-labelledby={titleId} data-kind={spec.kind}>
            <figcaption className={props.hideHeader ? "sr-only" : "chart-head"}>
                <span id={titleId} className="chart-title">
                    {spec.title}
                </span>
                {spec.subtitle ? <span className="chart-subtitle">{spec.subtitle}</span> : null}
            </figcaption>
            <p id={summaryId} className="sr-only">
                {summary}
            </p>
            {body}
            {model.truncated ? <p className="chart-note">{`Showing the first ${model.series[0]?.points.length ?? 0} of ${model.rowCount} rows.`}</p> : null}
        </figure>
    );
}

function Plot(props: ChartViewProps & { model: ChartModel; titleId: string; summaryId: string }) {
    const { spec, model, annotations } = props;
    const height = props.height ?? 220;
    const [ref, width] = useWidth<HTMLDivElement>(640);
    const [hidden, setHidden] = useState<ReadonlySet<string>>(new Set());
    const [active, setActive] = useState<number | null>(null);
    const visible = model.series.filter((s) => !hidden.has(s.key));
    const bars = spec.kind === "bar" || spec.kind === "stackedBar";
    const stacked = spec.kind === "stackedBar";

    const [y0, y1] = yDomain(model, visible.length > 0 ? visible : model.series, stacked);
    const y = scaleLinear().domain([y0, y1]).nice(4);
    const yTicks = y.ticks(4);
    const numeric = model.xKind === "time" || model.xKind === "number" || model.xKind === "index";
    const xs = model.xs;
    const first = xs[0] as number;
    const last = xs[xs.length - 1] as number;
    const span = numeric ? last - first : 0;
    const categorical = bars || !numeric;
    const xLabels = categorical ? xs.map((x) => formatX(x, model.xKind, span)) : [];

    const leftForTicks = Math.max(32, Math.min(72, 10 + Math.max(...yTicks.map((t) => formatTick(t, model.unit).length)) * 6.6));
    const slot = (width - leftForTicks - MARGIN.right) / Math.max(1, xs.length);
    const axis = categorical ? categoryAxis(xLabels, slot) : null;
    // A rotated first label reaches left of its tick; the margin makes room for it, up to a point.
    const overhang = axis?.rotate ? labelWidth(truncateLabel(xLabels[0] ?? "", axis.maxChars)) * Math.cos((AXIS_ROTATION_DEG * Math.PI) / 180) - slot / 2 + 4 : 0;
    const left = Math.max(leftForTicks, Math.min(Math.ceil(overhang), Math.floor(width * 0.3)));
    const innerW = Math.max(40, width - left - MARGIN.right);
    const innerH = Math.max(40, height - MARGIN.top - MARGIN.bottom);
    y.range([innerH, 0]);

    const keyOf = (x: number | string) => String(x);
    const band = scaleBand<string>().domain(model.xs.map(keyOf)).range([0, innerW]).paddingInner(0.22).paddingOuter(0.1);
    const groups = scaleBand<string>().domain(visible.map((s) => s.key)).range([0, band.bandwidth()]).padding(0.08);
    const time = scaleUtc().domain([new Date(first), new Date(last === first ? first + 60000 : last)]).range([0, innerW]);
    const linear = scaleLinear().domain([first, last === first ? first + 1 : last]).range([0, innerW]);
    const point = scalePoint<string>().domain(xs.map(keyOf)).range([0, innerW]).padding(0.5);
    const px = (x: number | string): number => {
        if (bars) return (band(keyOf(x)) ?? 0) + band.bandwidth() / 2;
        if (model.xKind === "time") return time(new Date(x as number));
        if (numeric) return linear(x as number);
        return point(keyOf(x)) ?? 0;
    };

    const byX = useMemo(() => model.series.map((s) => new Map<number | string, ChartPoint>(s.points.map((p) => [p.x, p]))), [model]);
    const colorOf = (s: ChartSeries) => seriesColor(s.key, model.series.indexOf(s), props.colors);

    const xTicks: Array<number | string> = categorical
        ? xs.filter((_, i) => i % (axis?.every ?? 1) === 0)
        : model.xKind === "time"
          ? time.ticks(Math.max(2, Math.floor(innerW / 96))).map((d) => d.getTime())
          : linear.ticks(Math.max(2, Math.floor(innerW / 80)));

    const pickIndex = (clientX: number, rect: DOMRect): number => {
        const at = clientX - rect.left - left;
        if (bars || !numeric) {
            const step = innerW / Math.max(1, xs.length);
            return Math.max(0, Math.min(xs.length - 1, Math.floor(at / step)));
        }
        const value = model.xKind === "time" ? time.invert(at).getTime() : linear.invert(at);
        return nearestIndex(xs as number[], value);
    };

    const onPointerMove = (event: PointerEvent<HTMLDivElement>) => setActive(pickIndex(event.clientX, event.currentTarget.getBoundingClientRect()));
    const selectAt = (index: number) => {
        if (!props.onSelect) return;
        const x = xs[index];
        const s = visible.find((one) => byX[model.series.indexOf(one)].get(x));
        const p = s ? byX[model.series.indexOf(s)].get(x) : undefined;
        if (s && p) props.onSelect({ series: s.key, x, y: p.y, row: p.row });
    };
    const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
        const lastIndex = xs.length - 1;
        const current = active ?? -1;
        let next: number | null = null;
        if (event.key === "ArrowRight") next = Math.min(lastIndex, current + 1);
        else if (event.key === "ArrowLeft") next = Math.max(0, current < 0 ? lastIndex : current - 1);
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = lastIndex;
        else if (event.key === "Escape") {
            setActive(null);
            return;
        } else if (event.key === "Enter" && active !== null) {
            selectAt(active);
            return;
        }
        if (next !== null) {
            event.preventDefault();
            setActive(next);
        }
    };

    const activeX = active !== null ? xs[active] : null;
    const readout =
        activeX === null
            ? ""
            : `${formatX(activeX, model.xKind, span, true)}: ${visible
                  .map((s) => `${s.label} ${formatValue(byX[model.series.indexOf(s)].get(activeX)?.y ?? null, model.unit)}`)
                  .join(", ")}`;

    const linePath = d3line<ChartPoint>()
        .defined((p) => p.y !== null)
        .x((p) => px(p.x))
        .y((p) => y(p.y as number))
        .curve(curveMonotoneX);
    const areaPath = d3area<ChartPoint>()
        .defined((p) => p.y !== null)
        .x((p) => px(p.x))
        .y0(y(Math.max(y.domain()[0], 0)))
        .y1((p) => y(p.y as number))
        .curve(curveMonotoneX);

    const stackBase = new Map<string, { pos: number; neg: number }>();
    const zero = y(Math.max(y.domain()[0], 0));
    const tooltipLeft = activeX === null ? 0 : left + px(activeX);

    return (
        <div className="chart-body">
            <div
                ref={ref}
                className="chart-plot"
                style={{ height: height + (axis?.extraBottom ?? 0) }}
                tabIndex={0}
                role="group"
                aria-roledescription="chart"
                aria-labelledby={props.titleId}
                aria-describedby={props.summaryId}
                onPointerMove={onPointerMove}
                onPointerLeave={() => setActive(null)}
                onClick={() => active !== null && selectAt(active)}
                onKeyDown={onKeyDown}
                onBlur={() => setActive(null)}
            >
                <svg className="chart-svg" width={width} height={height + (axis?.extraBottom ?? 0)} aria-hidden="true" focusable="false">
                    <g transform={`translate(${left},${MARGIN.top})`}>
                        {(() => {
                            // Band labels skip when they'd overlap the previous one; the band itself always shows.
                            const placed = (annotations?.bands ?? []).map((b) => {
                                const from = annotationX(b.from, model);
                                const to = annotationX(b.to, model);
                                if (from === null || to === null) return null;
                                const x0 = Math.max(0, Math.min(innerW, px(from)));
                                const x1 = Math.max(0, Math.min(innerW, px(to)));
                                return { b, left: Math.min(x0, x1), width: Math.max(2, Math.abs(x1 - x0)) };
                            });
                            const labelled = placed.reduce<{ end: number; shown: boolean[] }>(
                                (acc, p) => {
                                    const show = Boolean(p && p.b.label && p.left >= acc.end + 6 && p.left < innerW - 40);
                                    return { end: show && p ? p.left + (p.b.label?.length ?? 0) * 6.2 : acc.end, shown: [...acc.shown, show] };
                                },
                                { end: -Infinity, shown: [] },
                            ).shown;
                            return placed.map((p, i) =>
                                p ? (
                                    <g key={`band-${i}`} className={`chart-band chart-band-${p.b.tone ?? "incident"}`}>
                                        <rect x={p.left} y={0} width={p.width} height={innerH} />
                                        {labelled[i] ? (
                                            <text x={p.left + 4} y={11}>
                                                {p.b.label}
                                            </text>
                                        ) : null}
                                    </g>
                                ) : null,
                            );
                        })()}
                        {yTicks.map((t) => (
                            <g key={`y-${t}`} className="chart-grid">
                                <line x1={0} x2={innerW} y1={y(t)} y2={y(t)} />
                                <text x={-8} y={y(t)} dy="0.32em" textAnchor="end">
                                    {formatTick(t, model.unit)}
                                </text>
                            </g>
                        ))}
                        <line className="chart-axis" x1={0} x2={innerW} y1={innerH} y2={innerH} />
                        {xTicks.map((t) => {
                            const full = categorical ? (xLabels[xs.indexOf(t)] ?? String(t)) : formatX(t, model.xKind, span);
                            if (!axis?.rotate) {
                                return (
                                    <text key={`x-${t}`} className="chart-xtick" x={px(t)} y={innerH + 17} textAnchor="middle">
                                        {full}
                                    </text>
                                );
                            }
                            const shown = truncateLabel(full, axis.maxChars);
                            return (
                                <text key={`x-${t}`} className="chart-xtick" x={px(t)} y={innerH + 14} textAnchor="end" transform={`rotate(-${AXIS_ROTATION_DEG} ${px(t)} ${innerH + 14})`}>
                                    {shown !== full ? <title>{full}</title> : null}
                                    {shown}
                                </text>
                            );
                        })}

                        {bars
                            ? model.xs.map((x) => (
                                  <g key={`bar-${keyOf(x)}`}>
                                      {visible.map((s) => {
                                          const p = byX[model.series.indexOf(s)].get(x);
                                          if (!p || p.y === null) return null;
                                          const color = colorOf(s);
                                          if (stacked) {
                                              const base = stackBase.get(keyOf(x)) ?? { pos: 0, neg: 0 };
                                              const from = p.y >= 0 ? base.pos : base.neg;
                                              const to = from + p.y;
                                              if (p.y >= 0) base.pos = to;
                                              else base.neg = to;
                                              stackBase.set(keyOf(x), base);
                                              return <rect key={s.key} className="chart-bar" x={band(keyOf(x)) ?? 0} width={band.bandwidth()} y={y(Math.max(from, to))} height={Math.max(1, Math.abs(y(from) - y(to)))} fill={color} />;
                                          }
                                          return (
                                              <rect
                                                  key={s.key}
                                                  className="chart-bar"
                                                  x={(band(keyOf(x)) ?? 0) + (groups(s.key) ?? 0)}
                                                  width={groups.bandwidth()}
                                                  y={y(Math.max(0, p.y))}
                                                  height={Math.max(1, Math.abs(y(p.y) - zero))}
                                                  fill={color}
                                              />
                                          );
                                      })}
                                  </g>
                              ))
                            : visible.map((s) => {
                                  const color = colorOf(s);
                                  const dashed = props.dashed?.includes(s.key);
                                  if (spec.kind === "scatter") {
                                      return (
                                          <g key={s.key} fill={color}>
                                              {s.points
                                                  .filter((p) => p.y !== null)
                                                  .map((p, i) => (
                                                      <circle key={i} className="chart-dot" cx={px(p.x)} cy={y(p.y as number)} r={3.2} />
                                                  ))}
                                          </g>
                                      );
                                  }
                                  const single = s.points.filter((p) => p.y !== null).length === 1;
                                  return (
                                      <g key={s.key}>
                                          {spec.kind === "area" ? <path className="chart-area" d={areaPath(s.points) ?? ""} fill={color} /> : null}
                                          <path className="chart-line" d={linePath(s.points) ?? ""} stroke={color} strokeDasharray={dashed ? "5 4" : undefined} />
                                          {single
                                              ? s.points
                                                    .filter((p) => p.y !== null)
                                                    .map((p, i) => <circle key={i} cx={px(p.x)} cy={y(p.y as number)} r={3.5} fill={color} />)
                                              : null}
                                      </g>
                                  );
                              })}

                        {(annotations?.thresholds ?? []).map((t, i) => (
                            <g key={`th-${i}`} className={`chart-threshold chart-threshold-${t.tone ?? "warning"}`}>
                                <line x1={0} x2={innerW} y1={y(t.value)} y2={y(t.value)} />
                                <text x={4} y={y(t.value) - 5} textAnchor="start">
                                    {t.label}
                                </text>
                            </g>
                        ))}
                        {(annotations?.markers ?? []).map((m, i) => {
                            const x = annotationX(m.x, model);
                            if (x === null) return null;
                            const cx = px(x);
                            return (
                                <g key={`mk-${i}`} className="chart-marker">
                                    <circle cx={cx} cy={y(m.y)} r={4.5} />
                                    <text x={Math.min(innerW - 4, cx + 8)} y={y(m.y) - 8} textAnchor={cx > innerW - 90 ? "end" : "start"}>
                                        {m.label}
                                    </text>
                                </g>
                            );
                        })}

                        {activeX !== null ? (
                            <g className="chart-cursor">
                                {!bars ? <line x1={px(activeX)} x2={px(activeX)} y1={0} y2={innerH} /> : <rect x={band(keyOf(activeX)) ?? 0} y={0} width={band.bandwidth()} height={innerH} />}
                                {!bars
                                    ? visible.map((s) => {
                                          const p = byX[model.series.indexOf(s)].get(activeX);
                                          return p && p.y !== null ? <circle key={s.key} cx={px(activeX)} cy={y(p.y)} r={4} fill={colorOf(s)} /> : null;
                                      })
                                    : null}
                            </g>
                        ) : null}
                    </g>
                </svg>
                {activeX !== null ? (
                    <div className="chart-tooltip" style={tooltipLeft > width - 200 ? { right: width - tooltipLeft + 12 } : { left: tooltipLeft + 12 }} aria-hidden="true">
                        <strong>{formatX(activeX, model.xKind, span, true)}</strong>
                        {visible.map((s) => (
                            <span key={s.key}>
                                <i style={{ background: colorOf(s) }} />
                                {s.label}
                                <b>{formatValue(byX[model.series.indexOf(s)].get(activeX)?.y ?? null, model.unit)}</b>
                            </span>
                        ))}
                    </div>
                ) : null}
            </div>
            <p className="sr-only" aria-live="polite">
                {readout}
            </p>
            {model.series.length > 1 ? (
                <div className="chart-legend" role="group" aria-label={`${spec.title}: series`}>
                    {model.series.map((s) => (
                        <button
                            key={s.key}
                            type="button"
                            aria-pressed={!hidden.has(s.key)}
                            onClick={() =>
                                setHidden((h) => {
                                    const next = new Set(h);
                                    if (next.has(s.key)) next.delete(s.key);
                                    else if (model.series.length - next.size > 1) next.add(s.key);
                                    return next;
                                })
                            }
                        >
                            <i style={{ background: colorOf(s) }} className={props.dashed?.includes(s.key) ? "dashed" : undefined} aria-hidden="true" />
                            {s.label}
                        </button>
                    ))}
                </div>
            ) : null}
        </div>
    );
}

function KpiTiles({ spec, model }: { spec: ChartSpec; model: ChartModel }) {
    const tiles: Array<{ label: string; value: number | null }> =
        spec.x && spec.rows.length > 1
            ? spec.rows.slice(0, 12).map((row) => ({ label: String(row[spec.x as string] ?? ""), value: numberOf(row[model.yFields[0]]) }))
            : model.yFields.slice(0, 12).map((field) => ({ label: field, value: numberOf(spec.rows[0]?.[field]) }));
    if (tiles.length === 0) return <p className="chart-empty">No data to show.</p>;
    return (
        <ul className="chart-kpis">
            {tiles.map((t, i) => (
                <li key={`${t.label}-${i}`} className="chart-kpi">
                    <span className="chart-kpi-label">{t.label}</span>
                    <span className="chart-kpi-value">{formatValue(t.value, model.unit)}</span>
                </li>
            ))}
        </ul>
    );
}

function cellText(value: unknown, isMeasure: boolean, unit: string | undefined): string {
    if (value === null || value === undefined || value === "") return "–";
    const time = typeof value === "string" || value instanceof Date ? timeOf(value) : null;
    if (time !== null) return formatX(time, "time", 0, true);
    if (typeof value === "number") return isMeasure ? formatValue(value, unit) : formatValue(value);
    return String(value);
}

function ChartTable({ spec, model }: { spec: ChartSpec; model: ChartModel }) {
    const columns = useMemo(() => {
        const listed = [spec.x, spec.series, ...(spec.y !== undefined ? model.yFields : [])].filter((c): c is string => typeof c === "string");
        const all = listed.length > 0 ? listed : Object.keys(spec.rows[0] ?? {});
        return [...new Set(all)].slice(0, 12);
    }, [spec, model.yFields]);
    const [sort, setSort] = useState<{ key: string; dir: 1 | -1 } | null>(null);
    const rows = useMemo(() => {
        const copy = spec.rows.slice(0, 500);
        if (!sort) return copy;
        const value = (r: ContextRow) => {
            const v = r[sort.key];
            return timeOf(v) ?? numberOf(v) ?? (v === null || v === undefined ? "" : String(v));
        };
        return copy.sort((a, b) => {
            const va = value(a);
            const vb = value(b);
            if (typeof va === "number" && typeof vb === "number") return (va - vb) * sort.dir;
            return String(va).localeCompare(String(vb)) * sort.dir;
        });
    }, [spec.rows, sort]);
    if (columns.length === 0) return <p className="chart-empty">No data to show.</p>;
    return (
        <div className="chart-table-wrap" tabIndex={0} role="region" aria-label={spec.title}>
            <table className="chart-table">
                <thead>
                    <tr>
                        {columns.map((c) => (
                            <th key={c} scope="col" aria-sort={sort?.key === c ? (sort.dir === 1 ? "ascending" : "descending") : "none"}>
                                <button type="button" onClick={() => setSort((s) => (s?.key === c ? { key: c, dir: s.dir === 1 ? -1 : 1 } : { key: c, dir: 1 }))}>
                                    {c}
                                </button>
                            </th>
                        ))}
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r, i) => (
                        <tr key={i}>
                            {columns.map((c) => (
                                <td key={c} className={typeof r[c] === "number" ? "num" : undefined}>
                                    {cellText(r[c], model.yFields.includes(c), spec.unit)}
                                </td>
                            ))}
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}
