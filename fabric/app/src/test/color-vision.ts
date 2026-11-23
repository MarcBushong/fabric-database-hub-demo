// Color-vision checks for the theme tests: protanopia, deuteranopia, and tritanopia simulated with Machado, Oliveira, and
// Fernandes's matrices at full severity (2009), applied in linear sRGB, and the distance between two colors in OKLab
// (Ottosson, 2020), where about 0.02 is hard to tell apart and 0.08 and more is clear.

export type Vision = "normal" | "protanopia" | "deuteranopia" | "tritanopia";
export const VISIONS: readonly Vision[] = ["normal", "protanopia", "deuteranopia", "tritanopia"];

const MATRICES: Record<Exclude<Vision, "normal">, number[][]> = {
    protanopia: [
        [0.152286, 1.052583, -0.204868],
        [0.114503, 0.786281, 0.099216],
        [-0.003882, -0.048116, 1.051998],
    ],
    deuteranopia: [
        [0.367322, 0.860646, -0.227968],
        [0.280085, 0.672501, 0.047413],
        [-0.01182, 0.04294, 0.968881],
    ],
    tritanopia: [
        [1.255528, -0.076749, -0.178779],
        [-0.078411, 0.930809, 0.147602],
        [0.004733, 0.691367, 0.3039],
    ],
};

function linear(hex: string): number[] {
    return [1, 3, 5].map((i) => {
        const c = parseInt(hex.slice(i, i + 2), 16) / 255;
        return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
}

function oklab([r, g, b]: number[]): number[] {
    const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s, 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s];
}

/** A #RRGGBB color as one vision sees it, in OKLab. */
export function seen(hex: string, vision: Vision): number[] {
    const rgb = linear(hex);
    if (vision === "normal") return oklab(rgb);
    return oklab(MATRICES[vision].map((row) => Math.min(1, Math.max(0, row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2]))));
}

/** The closest two of a set of colors, for one vision: their names and their OKLab distance. */
export function closestPair(colors: Record<string, string>, vision: Vision): { pair: string; distance: number } {
    const names = Object.keys(colors);
    let closest = { pair: "", distance: Infinity };
    for (let i = 0; i < names.length; i++) {
        for (let j = i + 1; j < names.length; j++) {
            const [a, b] = [seen(colors[names[i]], vision), seen(colors[names[j]], vision)];
            const distance = Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
            if (distance < closest.distance) closest = { pair: `${names[i]} and ${names[j]}`, distance };
        }
    }
    return closest;
}
