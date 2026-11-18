import { useMemo } from "react";

import type { Bin } from "@/data/model";
import { formatNumber, type NumberKind } from "@/lib/format";

/** A target-by-hour grid of one signal: when the estate works, and who does the work. Its cells are a real table. */
export function Heatmap({ bins, targets, field, combine, kind, label, colors }: { bins: readonly Bin[]; targets: readonly string[]; field: keyof Bin; combine: "sum" | "max"; kind: NumberKind; label: string; colors: Record<string, string> }) {
    const cells = useMemo(() => {
        const grid = new Map<string, number>();
        for (const b of bins) {
            const v = b[field];
            if (typeof v !== "number") continue;
            const key = `${b.target}:${b.at.getUTCHours()}`;
            const prev = grid.get(key) ?? 0;
            grid.set(key, combine === "sum" ? prev + v : Math.max(prev, v));
        }
        return grid;
    }, [bins, field, combine]);
    const max = Math.max(1e-9, ...cells.values());
    const hours = Array.from({ length: 24 }, (_, h) => h);
    return (
        <div className="heatmap-wrap" tabIndex={0} role="region" aria-label={`${label} by UTC hour and target`}>
            <table className="heatmap">
                <caption className="sr-only">{`${label} by UTC hour of day and target`}</caption>
                <thead>
                    <tr>
                        <th scope="col">Target</th>
                        {hours.map((h) => (
                            <th key={h} scope="col">
                                {h % 3 === 0 ? String(h).padStart(2, "0") : <span className="sr-only">{h}</span>}
                            </th>
                        ))}
                    </tr>
                </thead>
                <tbody>
                    {targets.map((t) => (
                        <tr key={t}>
                            <th scope="row">{t}</th>
                            {hours.map((h) => {
                                const v = cells.get(`${t}:${h}`);
                                const share = v === undefined ? 0 : v / max;
                                return (
                                    <td key={h} title={`${t}, ${String(h).padStart(2, "0")}:00 UTC: ${formatNumber(v ?? null, kind)}`}>
                                        <span className="heat" style={{ background: colors[t] ?? "var(--chart-1)", opacity: v === undefined ? 0.06 : 0.12 + 0.88 * share }} aria-hidden="true" />
                                        <span className="sr-only">{formatNumber(v ?? null, kind)}</span>
                                    </td>
                                );
                            })}
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}
