// The ContosoCare service map (ADR 0030): each target as the business service it serves, around the care network, pulsing
// with its health from the history; in the replay, with what it's going through at the scrubber's moment, and a shockwave
// when a fault's signal shows. Status is never color alone: every node says its status in a glyph and a word.

import type { KeyboardEvent } from "react";

import { serviceOf } from "@/lib/business";
import { TARGETS } from "@/lib/estate";
import type { TargetState } from "@/lib/scoreboard";
import { statusMeta, statusTone, type StatusName } from "@/lib/status";
import type { EstateTarget } from "@/lib/view-state";

export type Lens = "technical" | "business";

export interface MapNode {
    target: EstateTarget;
    /** Its health from the history (an ADR 0012 status), or null without data. */
    status: StatusName | null;
    /** In the replay: what it's going through at the scrubber's moment. */
    state?: TargetState;
    /** The technical lens's line: its key measured number. */
    metric: string;
    /** The business lens's line, from a measured signal, or null when nothing was measured. */
    impact: string | null;
    /** The measured signal behind the business line. */
    evidence?: string | null;
    /** Faults and episodes in the session. */
    events: number;
}

interface Place {
    x: number;
    y: number;
}

const HUB: Place = { x: 500, y: 262 };
const PLACES: Record<EstateTarget, Place> = {
    T3: { x: 500, y: 74 },
    T2: { x: 190, y: 146 },
    T1: { x: 190, y: 380 },
    T5: { x: 810, y: 146 },
    T4: { x: 810, y: 380 },
    "T4-replica": { x: 920, y: 292 },
};

const STATE_WORD: Record<TargetState, string> = { calm: "Calm", injected: "Fault running", visible: "Signal visible", answered: "Answered" };
const STATE_GLYPH: Record<TargetState, string> = { calm: "○", injected: "▼", visible: "●", answered: "◆" };

function line(node: MapNode, lens: Lens): string {
    if (lens === "business") return node.impact ?? "No measured impact";
    return node.metric || "No data in this period";
}

function label(node: MapNode, lens: Lens): string {
    const service = serviceOf(node.target)?.service ?? node.target;
    const status = node.state ? STATE_WORD[node.state] : node.status ? statusMeta(node.status).name : "No data";
    const evidence = lens === "business" && node.evidence ? ` (${node.evidence})` : "";
    return `${service}, ${node.target} ${TARGETS[node.target].name}: ${status}. ${line(node, lens)}${evidence}.`;
}

/** Cuts a line for the map at a word, with an ellipsis; the full text is in the node's label and the services list. */
function clip(text: string, max: number): string {
    if (text.length <= max) return text;
    const cut = text.slice(0, max - 1);
    return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), max - 12))}…`;
}

export function ServiceMap(props: {
    nodes: MapNode[];
    lens: Lens;
    motion: boolean;
    shockKeys?: Partial<Record<EstateTarget, string>>;
    onOpen?: (target: EstateTarget) => void;
    title: string;
    hubLine?: string;
    /** Fewer, larger words: the service and its state, for the replay's smaller map. */
    dense?: boolean;
}) {
    const { nodes, lens, motion, onOpen, dense } = props;
    const shown = new Set(nodes.map((n) => n.target));
    const open = (target: EstateTarget) => (event: KeyboardEvent<SVGGElement>) => {
        if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            onOpen?.(target);
        }
    };
    return (
        <svg className={`mc-map${motion ? " mc-motion" : ""}${dense ? " mc-dense" : ""}`} viewBox="0 0 1000 520" role="group" aria-label={props.title} preserveAspectRatio="xMidYMid meet">
            <defs>
                <radialGradient id="mc-hub-fill" cx="50%" cy="45%" r="60%">
                    <stop offset="0%" stopColor="var(--stage-cyan)" stopOpacity="0.35" />
                    <stop offset="100%" stopColor="var(--stage-panel)" stopOpacity="1" />
                </radialGradient>
            </defs>
            {nodes.map((n) => {
                const at = PLACES[n.target];
                const from = n.target === "T4-replica" && shown.has("T4") ? PLACES.T4 : HUB;
                const hot = n.state === "visible" || n.state === "injected" || (!n.state && (n.status === "Fail" || n.status === "Warning"));
                return <line key={`link-${n.target}`} className={`mc-link${hot ? " mc-link-alert" : ""}`} x1={from.x} y1={from.y} x2={at.x} y2={at.y} />;
            })}
            <g className="mc-hub" aria-hidden="true">
                <circle cx={HUB.x} cy={HUB.y} r={70} fill="url(#mc-hub-fill)" />
                <circle cx={HUB.x} cy={HUB.y} r={70} className="mc-hub-ring" />
                <text x={HUB.x} y={HUB.y - 4} className="mc-hub-name" textAnchor="middle">
                    ContosoCare
                </text>
                <text x={HUB.x} y={HUB.y + 20} className="mc-hub-sub" textAnchor="middle">
                    {props.hubLine ?? "care network"}
                </text>
            </g>
            {nodes.map((n) => {
                const at = PLACES[n.target];
                const satellite = n.target === "T4-replica";
                const r = satellite ? 22 : 36;
                const service = serviceOf(n.target)?.service ?? n.target;
                const tone = n.state ? `state-${n.state}` : `tone-${statusTone(n.status ?? "")}`;
                const glyph = n.state ? STATE_GLYPH[n.state] : n.status ? statusMeta(n.status).glyph : "–";
                const word = n.state ? STATE_WORD[n.state] : n.status ? statusMeta(n.status).short : "No data";
                const interactive = Boolean(onOpen);
                const shock = props.shockKeys?.[n.target];
                return (
                    <g
                        key={n.target}
                        className={`mc-node mc-${tone}${satellite ? " mc-satellite" : ""}`}
                        transform={`translate(${at.x} ${at.y})`}
                        role={interactive ? "button" : "img"}
                        tabIndex={interactive ? 0 : undefined}
                        aria-label={label(n, lens)}
                        onClick={interactive ? () => onOpen?.(n.target) : undefined}
                        onKeyDown={interactive ? open(n.target) : undefined}
                    >
                        <title>{label(n, lens)}</title>
                        {motion && (n.status || n.state) ? <circle className="mc-pulse" r={r + 4} /> : null}
                        {motion && shock ? <circle key={shock} className="mc-shock" r={r} /> : null}
                        <circle className="mc-halo" r={r + 8} />
                        <circle className="mc-core" r={r} style={{ stroke: TARGETS[n.target].color }} />
                        <text className="mc-key" y={satellite ? 5 : 2} textAnchor="middle">
                            {satellite ? "DR" : n.target}
                        </text>
                        {satellite ? null : (
                            <text className="mc-glyph" y={22} textAnchor="middle">
                                {glyph}
                            </text>
                        )}
                        {n.events > 0 && !satellite ? (
                            <g className="mc-badge" transform={`translate(${r * 0.72} ${-r * 0.72})`}>
                                <circle r={11} />
                                <text y={4} textAnchor="middle">
                                    {n.events}
                                </text>
                            </g>
                        ) : null}
                        <text className="mc-service" y={satellite ? -r - 10 : r + 24} textAnchor="middle">
                            {satellite ? (dense ? "DR copy" : "Reports' DR copy") : service}
                        </text>
                        {satellite ? null : dense ? (
                            <text className="mc-word" y={r + 48} textAnchor="middle">
                                {`${glyph} ${word}`}
                            </text>
                        ) : (
                            <>
                                <text className="mc-word" y={r + 42} textAnchor="middle">
                                    {`${glyph} ${word} · ${n.target} ${TARGETS[n.target].name}`}
                                </text>
                                <text className={`mc-line${lens === "business" ? " mc-line-business" : ""}`} y={r + 60} textAnchor="middle">
                                    {clip(line(n, lens), 40)}
                                </text>
                            </>
                        )}
                    </g>
                );
            })}
        </svg>
    );
}
