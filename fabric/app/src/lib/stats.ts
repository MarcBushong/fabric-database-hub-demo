// Small statistics helpers for the ridgelines and the insight rules.

export function mean(values: readonly number[]): number | null {
    if (values.length === 0) return null;
    return values.reduce((a, b) => a + b, 0) / values.length;
}

export function quantile(values: readonly number[], q: number): number | null {
    if (values.length === 0) return null;
    const sorted = [...values].sort((a, b) => a - b);
    const pos = (sorted.length - 1) * Math.min(Math.max(q, 0), 1);
    const lo = Math.floor(pos);
    const hi = Math.ceil(pos);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

function standardDeviation(values: readonly number[]): number {
    const m = mean(values) ?? 0;
    return Math.sqrt(values.reduce((a, v) => a + (v - m) ** 2, 0) / Math.max(values.length - 1, 1));
}

/** Silverman's rule of thumb, with a floor so a flat series still draws a narrow ridge. */
export function bandwidth(values: readonly number[], span: number): number {
    if (values.length < 2) return Math.max(span / 20, 1e-6);
    const sd = standardDeviation(values);
    const iqr = (quantile(values, 0.75) ?? 0) - (quantile(values, 0.25) ?? 0);
    const spread = Math.min(sd, iqr / 1.34 || sd);
    const h = 0.9 * (spread || sd || span / 10) * values.length ** -0.2;
    return Math.max(h, span / 200, 1e-6);
}

/** Gaussian kernel density over `steps` evenly spaced points in [min, max]; densities scaled so the peak is 1. */
export function density(values: readonly number[], min: number, max: number, steps = 64): Array<[number, number]> {
    const span = max - min || 1;
    const h = bandwidth(values, span);
    const points: Array<[number, number]> = [];
    let peak = 0;
    for (let i = 0; i < steps; i++) {
        const x = min + (span * i) / (steps - 1);
        let sum = 0;
        for (const v of values) {
            const u = (x - v) / h;
            sum += Math.exp(-0.5 * u * u);
        }
        const d = values.length ? sum / (values.length * h * Math.sqrt(2 * Math.PI)) : 0;
        peak = Math.max(peak, d);
        points.push([x, d]);
    }
    return points.map(([x, d]) => [x, peak > 0 ? d / peak : 0]);
}
