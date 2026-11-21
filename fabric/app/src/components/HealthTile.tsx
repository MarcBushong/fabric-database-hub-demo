import { StatusBadge } from "@/components/StatusBadge";
import { TARGETS } from "@/lib/estate";
import type { TargetHealth } from "@/lib/health";
import { Sparkline } from "@/visuals/Sparkline";

/** One target's health: its status, three numbers, its CPU over the period, and its freshness. Opens its details. */
export function HealthTile({ health, onOpen }: { health: TargetHealth; onOpen: () => void }) {
    const info = TARGETS[health.key];
    return (
        <article className="health-tile" style={{ ["--tile-color" as string]: info.color }}>
            <div className="health-head">
                <button type="button" className="health-name tile-link" onClick={onOpen} aria-label={`${info.short} · ${info.name}, ${health.status ?? "no status"}: open its details`}>
                    <strong>{info.short}</strong>
                    <span>{info.name}</span>
                </button>
                {health.status ? <StatusBadge status={health.status} short /> : <span className="muted">No data</span>}
            </div>
            {health.metrics.length > 0 ? (
                <div className="health-metrics">
                    {health.metrics.map((m) => (
                        <div key={m.label}>
                            <span className="m-label">{m.label}</span>
                            <span className="m-value">{m.value}</span>
                        </div>
                    ))}
                </div>
            ) : null}
            <Sparkline values={health.spark} color={info.color} />
            <span className="health-foot">
                {health.note}
                {health.incidents > 0 ? ` · ${health.incidents} incident${health.incidents === 1 ? "" : "s"}` : ""}
            </span>
        </article>
    );
}
