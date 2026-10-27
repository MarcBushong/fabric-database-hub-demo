import { useMemo, useState } from "react";
import { sankey, sankeyLinkHorizontal, type SankeyGraph } from "d3-sankey";
import { hierarchy, partition } from "d3-hierarchy";
import { arc } from "d3-shape";

import { type WaitFlow as Flow } from "@/data/model";
import { formatNumber } from "@/lib/format";
import { useElementSize } from "@/lib/hooks";
import type { WaitsView } from "@/lib/view-state";
import { familiesOf, familyOf, foldFlows } from "./layout";

const FAMILY_COLORS = ["var(--accent)", "var(--accent-2)", "var(--accent-3)", "var(--status-warning)", "var(--status-manual)", "var(--status-pass)", "var(--ink-faint)"];
const TARGET_COLOR: Record<string, string> = { T1: "var(--t1)", T2: "var(--t2)", T3: "var(--t3)" };

function paletteFor(families: readonly string[]): (family: string) => string {
    return (family) => FAMILY_COLORS[Math.max(0, families.indexOf(family)) % FAMILY_COLORS.length];
}

interface NodeExtra {
    id: string;
    name: string;
    kind: "family" | "category" | "target";
}

interface LinkExtra {
    source: string;
    target: string;
    value: number;
}

function SankeyView({ flows, width }: { flows: Flow[]; width: number }) {
    const [hover, setHover] = useState<string | null>(null);
    const w = Math.max(width, 320);
    const h = Math.max(280, Math.min(460, 60 + flows.length * 18));
    const families = useMemo(() => familiesOf(flows), [flows]);
    const color = paletteFor(families);
    const graph = useMemo(() => {
        const nodes: NodeExtra[] = [];
        const seen = new Set<string>();
        const add = (id: string, name: string, kind: NodeExtra["kind"]) => {
            if (!seen.has(id)) {
                seen.add(id);
                nodes.push({ id, name, kind });
            }
        };
        const links = new Map<string, LinkExtra>();
        const link = (source: string, target: string, value: number) => {
            const key = `${source}->${target}`;
            const prev = links.get(key);
            links.set(key, { source, target, value: (prev?.value ?? 0) + value });
        };
        for (const f of flows) {
            const family = familyOf(f.category);
            add(`f:${family}`, family, "family");
            add(`c:${f.category}`, f.category, "category");
            add(`t:${f.target}`, f.target, "target");
            link(`f:${family}`, `c:${f.category}`, f.seconds);
            link(`c:${f.category}`, `t:${f.target}`, f.seconds);
        }
        const layout = sankey<NodeExtra, LinkExtra>()
            .nodeId((d) => d.id)
            .nodeWidth(12)
            .nodePadding(14)
            .extent([
                [1, 10],
                [w - 1, h - 10],
            ]);
        return layout({ nodes: nodes.map((d) => ({ ...d })), links: [...links.values()].map((d) => ({ ...d })) }) as SankeyGraph<NodeExtra, LinkExtra>;
    }, [flows, w, h]);
    const path = sankeyLinkHorizontal<NodeExtra, LinkExtra>();

    return (
        <svg className="viz" viewBox={`0 0 ${w} ${h}`} width={w} height={h} onMouseLeave={() => setHover(null)}>
            <g fill="none">
                {graph.links.map((l, i) => {
                    const source = l.source as unknown as NodeExtra;
                    const target = l.target as unknown as NodeExtra;
                    const stroke = target.kind === "target" ? TARGET_COLOR[target.name] ?? "var(--accent)" : color(source.name);
                    const active = hover === null || hover === source.id || hover === target.id;
                    return (
                        <path key={i} d={path(l) ?? ""} stroke={stroke} strokeOpacity={active ? 0.55 : 0.12} strokeWidth={Math.max(1, l.width ?? 1)}>
                            <title>{`${source.name} → ${target.name}: ${formatNumber(l.value, "seconds")}`}</title>
                        </path>
                    );
                })}
            </g>
            {graph.nodes.map((n) => {
                const fill = n.kind === "target" ? TARGET_COLOR[n.name] : n.kind === "family" ? color(n.name) : color(familyOf(n.name));
                const x0 = n.x0 ?? 0;
                const x1 = n.x1 ?? 0;
                const y0 = n.y0 ?? 0;
                const y1 = n.y1 ?? 0;
                const leftSide = x0 < w / 2;
                return (
                    <g key={n.id} onMouseEnter={() => setHover(n.id)}>
                        <rect x={x0} y={y0} width={x1 - x0} height={Math.max(1, y1 - y0)} rx={3} fill={fill} />
                        <text x={leftSide ? x1 + 6 : x0 - 6} y={(y0 + y1) / 2 + 4} textAnchor={leftSide ? "start" : "end"} className={n.kind === "target" ? "label-strong" : undefined}>
                            {`${n.name.replace(" (PAGEIOLATCH)", "")} · ${formatNumber(n.value, "seconds")}`}
                        </text>
                    </g>
                );
            })}
        </svg>
    );
}

interface Datum {
    name: string;
    value?: number;
    children?: Datum[];
}

function SunburstView({ flows, width }: { flows: Flow[]; width: number }) {
    const size = Math.min(Math.max(width, 280), 440);
    const r = size / 2;
    const [hover, setHover] = useState<{ name: string; value: number; path: string } | null>(null);
    const families = useMemo(() => familiesOf(flows), [flows]);
    const color = paletteFor(families);
    const root = useMemo(() => {
        const tree: Datum = { name: "Wait time", children: [] };
        for (const family of families) {
            const categories = [...new Set(flows.filter((f) => familyOf(f.category) === family).map((f) => f.category))];
            tree.children!.push({
                name: family,
                children: categories.map((category) => ({
                    name: category,
                    children: flows.filter((f) => f.category === category).map((f) => ({ name: f.target, value: f.seconds })),
                })),
            });
        }
        const h = hierarchy(tree)
            .sum((d) => d.value ?? 0)
            .sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
        return partition<Datum>().size([2 * Math.PI, r])(h);
    }, [flows, families, r]);
    const total = root.value ?? 0;
    const ring = arc<{ x0: number; x1: number; y0: number; y1: number }>()
        .startAngle((d) => d.x0)
        .endAngle((d) => d.x1)
        .innerRadius((d) => d.y0 + (d.y0 === 0 ? 0 : 2))
        .outerRadius((d) => d.y1 - 2)
        .padAngle(0.006)
        .cornerRadius(4);

    return (
        <div style={{ display: "grid", placeItems: "center" }}>
            <svg className="viz" viewBox={`0 0 ${size} ${size}`} width={size} height={size} onMouseLeave={() => setHover(null)}>
                <g transform={`translate(${r},${r})`}>
                    {root
                        .descendants()
                        .filter((d) => d.depth > 0)
                        .map((d, i) => {
                            const family = d.ancestors().find((a) => a.depth === 1)?.data.name ?? "";
                            const fill = d.depth === 3 ? TARGET_COLOR[d.data.name] ?? "var(--accent)" : color(family);
                            const path = d
                                .ancestors()
                                .reverse()
                                .slice(1)
                                .map((a) => a.data.name)
                                .join(" › ");
                            return (
                                <path
                                    key={i}
                                    d={ring(d) ?? ""}
                                    fill={fill}
                                    fillOpacity={d.depth === 1 ? 0.9 : d.depth === 2 ? 0.6 : 0.85}
                                    onMouseEnter={() => setHover({ name: d.data.name, value: d.value ?? 0, path })}
                                >
                                    <title>{`${path}: ${formatNumber(d.value, "seconds")}`}</title>
                                </path>
                            );
                        })}
                    <circle r={root.children?.[0]?.y0 ?? r / 4} fill="var(--panel-solid)" opacity="0.9" />
                    <text y={-6} textAnchor="middle" className="label-strong">
                        {hover ? hover.name.replace(" (PAGEIOLATCH)", "") : "Wait time"}
                    </text>
                    <text y={12} textAnchor="middle">
                        {formatNumber(hover ? hover.value : total, "seconds")}
                    </text>
                    <text y={27} textAnchor="middle" style={{ fontSize: 10 }}>
                        {hover && total > 0 ? `${Math.round((hover.value / total) * 100)} % of all` : "family › category › target"}
                    </text>
                </g>
            </svg>
        </div>
    );
}

/** Where the wait time went: a flow from wait families to categories to targets, or the same tree as a sunburst. */
export function WaitFlowChart({ flows, view }: { flows: Flow[]; view: WaitsView }) {
    const [ref, { width }] = useElementSize<HTMLDivElement>(560);
    const folded = useMemo(() => foldFlows(flows), [flows]);
    return <div ref={ref}>{view === "sankey" ? <SankeyView flows={folded} width={width} /> : <SunburstView flows={folded} width={width} />}</div>;
}
