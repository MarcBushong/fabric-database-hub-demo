// The Root cause view's report of one incident (ADR 0031): the blind root cause with its evidence and times first, then
// the chain (head blocker first), the timeline, the errors by class, the recommendations with who approves each, the
// next steps, and what wasn't captured. It renders the investigation tools' results as they are: no fact of its own.

import type { DaxLog } from "../loader";
import { bothTimes } from "../time";
import type { ChainNodeView } from "../tools";
import type { InvestigationResult, Recommendation } from "../types";
import { ChainTree } from "./ChainTree";
import { episodeOf, errorClassCells, errorsWindowNote, type ErrorClassRow } from "./facts";

interface Tree {
    target: string;
    kind: string;
    at: string;
    blocked: number;
    depth: number;
    width: number;
    root: ChainNodeView;
}

interface Part {
    tool: string;
    details?: Record<string, unknown>;
}

const KIND: Record<string, string> = {
    "idle-open-transaction": "Idle with its transaction open",
    "long-running": "Still running",
    "client-not-fetching": "The client isn't reading the results",
    rollback: "Rolling back",
    special: "A system owner",
    "not-visible": "Not visible to the capture",
};

const parts = (result: InvestigationResult): Part[] => ((result.details?.parts as Part[] | undefined) ?? [{ tool: result.tool, details: result.details }]).filter(Boolean);

function Sparkline({ points, unit, label, timeZone }: { points: Array<{ at: Date; value: number }>; unit: string; label: string; timeZone: string }) {
    if (points.length < 2) return null;
    const w = 600;
    const h = 80;
    const pad = 5;
    const t0 = points[0].at.getTime();
    const t1 = points[points.length - 1].at.getTime();
    const max = Math.max(1, ...points.map((p) => p.value));
    const x = (t: number) => pad + ((t - t0) / Math.max(1, t1 - t0)) * (w - 2 * pad);
    const y = (v: number) => h - pad - (v / max) * (h - 2 * pad);
    const peak = points.reduce((a, p) => (p.value > a.value ? p : a));
    const amount = (v: number) => `${v.toLocaleString("en-US", { maximumFractionDigits: 1 })}${unit === "s" ? " s" : ` ${unit}`}`;
    const summary = `${label}: from ${bothTimes(points[0].at, timeZone)} to ${bothTimes(points[points.length - 1].at, timeZone)}, peak ${amount(peak.value)} at ${bothTimes(peak.at, timeZone)}`;
    return (
        <figure style={{ margin: 0 }}>
            <svg className="rca-spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" role="img" aria-label={summary}>
                <line className="rca-spark-axis" x1={pad} x2={w - pad} y1={h - pad} y2={h - pad} />
                <polyline className="rca-spark-line" vectorEffect="non-scaling-stroke" points={points.map((p) => `${x(p.at.getTime()).toFixed(1)},${y(p.value).toFixed(1)}`).join(" ")} />
                <circle className="rca-spark-peak" cx={x(peak.at.getTime())} cy={y(peak.value)} r={3.5} />
            </svg>
            <figcaption className="rca-spark-legend">
                <span>{bothTimes(points[0].at, timeZone)}</span>
                <span>
                    Peak {amount(peak.value)} at {bothTimes(peak.at, timeZone)}
                </span>
                <span>{bothTimes(points[points.length - 1].at, timeZone)}</span>
            </figcaption>
        </figure>
    );
}

function Recommendations({ items }: { items: Recommendation[] }) {
    return (
        <ul className="rca-list">
            {items.map((r) => (
                <li key={r.id}>
                    <strong>{r.title}</strong> <span className="rca-chip">{r.approver} approves</span>
                    <div>{r.why}</div>
                    <div className="rca-muted">Risk: {r.risk}</div>
                    <a href={r.learn.url} target="_blank" rel="noreferrer noopener">
                        {r.learn.title}
                    </a>
                </li>
            ))}
        </ul>
    );
}

export interface RcaReportProps {
    incident: InvestigationResult;
    /** The errors in the incident's minutes (explain_errors), when they loaded. */
    errors: InvestigationResult | null;
    timeZone: string;
    logs: readonly DaxLog[];
}

export function RcaReport({ incident, errors, timeZone, logs }: RcaReportProps) {
    const episode = episodeOf(incident);
    const all = parts(incident);
    const locking = all.find((p) => p.tool === "explain_locking")?.details;
    const replica = all.find((p) => p.tool === "explain_replica_lag")?.details;
    const trees = ((locking?.trees as Tree[] | undefined) ?? []).filter((t) => !episode || t.target === episode.target);
    const series = ((locking?.series as Array<{ target: string; at: string; blocked: number }> | undefined) ?? []).filter((p) => !episode || p.target === episode.target);
    const lag = (replica?.lag as Array<{ at: string; seconds: number }> | undefined) ?? [];
    const classes = (errors?.details?.classes as ErrorClassRow[] | undefined) ?? [];
    const also = (incident.details?.alsoInTheseMinutes as string[] | undefined) ?? [];
    // The errors' minutes say a target has no capture for their own span, in either form (no capture recorded, or a coverage
    // row marked not captured), for a span or "at" one instant (F5): for a target the incident notes already, theirs go. The
    // incident's own lines all stay: one per coverage row not captured, so a storm across two rows has two (the re-review of
    // ab1d2d41), as tools.ts keeps an incident's own lines and drops its parts' for a target it notes.
    const noCapture = (s: string) => /^(T1|T2|T3|T4|T4-replica|T5): no RCA (?:capture recorded|evidence) (?:for|at) /.exec(s)?.[1];
    const noted = new Set(incident.notCaptured.map(noCapture).filter((t): t is string => t !== undefined));
    const notCaptured = [...new Set([...incident.notCaptured, ...(errors?.notCaptured ?? []).filter((s) => !noted.has(noCapture(s) ?? ""))])];
    const recommendations = [...new Map([...incident.recommendations, ...(errors?.recommendations ?? [])].map((r) => [r.id, r])).values()];
    const cause = incident.rootCause;
    const confidence = cause ? (cause.confidence === "high" ? "accent" : cause.confidence === "low" ? "alert" : "") : "";

    return (
        <div className="rca-sections">
            <section className="rca-panel" aria-labelledby="rca-cause-title">
                <h2 id="rca-cause-title">Root cause</h2>
                {episode ? (
                    <p className="rca-muted" style={{ margin: "0 0 8px" }}>
                        <span className="rca-chip accent">{episode.target}</span>
                        <span className="rca-chip">{episode.signal}</span>
                        <span className="rca-chip">{episode.support}</span>
                        <span className="rca-chip">seen in {episode.source}</span>
                        {incident.window.local}
                    </p>
                ) : null}
                {cause ? (
                    <>
                        <p className="rca-cause">{cause.statement}</p>
                        <p style={{ margin: "8px 0 0" }}>
                            <span className={`rca-chip ${confidence}`}>Confidence: {cause.confidence}</span>
                        </p>
                        {cause.evidence.length > 0 ? (
                            <ul className="rca-evidence" aria-label="The evidence">
                                {cause.evidence.map((e, i) => (
                                    <li key={`${e.table}-${e.at}-${i}`}>
                                        {e.text} ({e.table}, {e.target}, {bothTimes(new Date(e.at), timeZone)})
                                    </li>
                                ))}
                            </ul>
                        ) : null}
                    </>
                ) : (
                    <p className="rca-cause">
                        {notCaptured.length > 0 ? "The capture holds no cause for these minutes: see what wasn't captured below." : "The capture and the telemetry hold no cause for these minutes."}
                    </p>
                )}
                {also.length > 0 ? (
                    <>
                        <h3>Also in these minutes</h3>
                        <ul className="rca-list">
                            {also.map((text) => (
                                <li key={text}>{text}</li>
                            ))}
                        </ul>
                    </>
                ) : null}
            </section>

            {trees.length > 0 ? (
                <section className="rca-panel" aria-labelledby="rca-chain-title">
                    <h2 id="rca-chain-title">The blocking chain, head blocker first</h2>
                    {trees.map((t) => (
                        <div key={`${t.target}-${t.at}-${t.root.session}`}>
                            <p className="rca-muted" style={{ margin: "0 0 4px" }}>
                                {KIND[t.kind] ?? t.kind} · {t.blocked} blocked, {t.depth} levels deep, {t.width} {t.width === 1 ? "branch" : "branches"} at its peak, {bothTimes(new Date(t.at), timeZone)}
                            </p>
                            <ChainTree root={t.root} label={`The blocking chain on ${t.target} at ${bothTimes(new Date(t.at), timeZone)}`} />
                        </div>
                    ))}
                </section>
            ) : null}

            {series.length > 1 || lag.length > 1 ? (
                <section className="rca-panel" aria-labelledby="rca-timeline-title">
                    <h2 id="rca-timeline-title">Timeline</h2>
                    {series.length > 1 ? <Sparkline label="Blocked sessions per sample" unit="blocked" timeZone={timeZone} points={series.map((p) => ({ at: new Date(p.at), value: p.blocked }))} /> : null}
                    {lag.length > 1 ? <Sparkline label="The read replica's lag" unit="s" timeZone={timeZone} points={lag.map((p) => ({ at: new Date(p.at), value: p.seconds }))} /> : null}
                </section>
            ) : null}

            <section className="rca-panel" aria-labelledby="rca-errors-title">
                <h2 id="rca-errors-title">Errors in these minutes</h2>
                {errors ? (
                    <p className="rca-muted" style={{ margin: "0 0 8px" }}>
                        {errorsWindowNote(errors, timeZone)}
                    </p>
                ) : null}
                {classes.length > 0 ? (
                    <table className="rca-table">
                        <thead>
                            <tr>
                                <th scope="col">Class</th>
                                <th scope="col">Count</th>
                                <th scope="col">Where</th>
                                <th scope="col">When</th>
                                <th scope="col">Most from</th>
                            </tr>
                        </thead>
                        <tbody>
                            {classes.map((c) => {
                                const cells = errorClassCells(c, timeZone);
                                return (
                                    <tr key={c.class}>
                                        <td>{c.title}</td>
                                        <td>{cells.count}</td>
                                        <td>{c.targets.join(", ")}</td>
                                        <td>{cells.when}</td>
                                        <td>{c.top ? <code className="rca-code">{c.top}</code> : "—"}</td>
                                    </tr>
                                );
                            })}
                        </tbody>
                    </table>
                ) : (
                    <p className="rca-muted" style={{ margin: 0 }}>
                        {errors ? "No errors, cancels, failed connections, or 429s were recorded in these minutes." : "The errors didn't load."}
                    </p>
                )}
            </section>

            {recommendations.length > 0 ? (
                <section className="rca-panel" aria-labelledby="rca-recs-title">
                    <h2 id="rca-recs-title">Recommendations</h2>
                    <Recommendations items={recommendations} />
                </section>
            ) : null}

            {incident.nextSteps.length > 0 ? (
                <section className="rca-panel" aria-labelledby="rca-next-title">
                    <h2 id="rca-next-title">Next steps</h2>
                    <ol className="rca-list">
                        {incident.nextSteps.map((s) => (
                            <li key={s}>{s}</li>
                        ))}
                    </ol>
                </section>
            ) : null}

            {notCaptured.length > 0 ? (
                <section className="rca-panel" aria-labelledby="rca-gaps-title">
                    <h2 id="rca-gaps-title">Not captured</h2>
                    <ul className="rca-list">
                        {notCaptured.map((s) => (
                            <li key={s}>{s}</li>
                        ))}
                    </ul>
                </section>
            ) : null}

            {logs.length > 0 ? (
                <details className="rca-panel rca-dax">
                    <summary>Show the DAX ({logs.length} queries)</summary>
                    {logs.map((l, i) => (
                        <div key={`${l.table}-${i}`}>
                            <p className="rca-muted" style={{ margin: "8px 0 0" }}>
                                {l.table}: {l.error ? `failed (${l.error})` : `${l.rows.toLocaleString("en-US")} rows`}
                                {l.ms !== undefined ? `, ${l.ms} ms` : ""}
                            </p>
                            <pre className="rca-code">{l.query}</pre>
                        </div>
                    ))}
                </details>
            ) : null}
        </div>
    );
}
