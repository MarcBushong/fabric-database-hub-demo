import { useMemo } from "react";
import { line } from "d3-shape";
import { scaleLinear } from "d3-scale";

/** A tiny line of one signal over the period, for tiles; decorative, the tile's text carries the numbers. */
export function Sparkline({ values, color, height = 28 }: { values: ReadonlyArray<number | null>; color: string; height?: number }) {
    const d = useMemo(() => {
        const points = values.map((v, i) => [i, v] as const).filter((p): p is readonly [number, number] => p[1] !== null);
        if (points.length < 2) return "";
        const max = Math.max(...points.map((p) => p[1]), 1e-9);
        const x = scaleLinear().domain([0, values.length - 1]).range([1, 99]);
        const y = scaleLinear().domain([0, max]).range([height - 2, 2]);
        return line<readonly [number, number]>()
            .x((p) => x(p[0]))
            .y((p) => y(p[1]))(points) ?? "";
    }, [values, height]);
    if (!d) return null;
    return (
        <svg className="spark" viewBox={`0 0 100 ${height}`} preserveAspectRatio="none" aria-hidden="true" focusable="false">
            <path d={d} stroke={color} vectorEffect="non-scaling-stroke" />
        </svg>
    );
}
