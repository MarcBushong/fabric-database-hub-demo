import { describe, expect, it } from "vitest";

import { contrastRatio, THEMES, THEME_ORDER, TEXT_TOKENS } from "./themes";

describe("themes", () => {
    it.each(THEME_ORDER)("%s: every text token reaches WCAG AA (4.5:1) on every surface", (id) => {
        const theme = THEMES[id];
        const failures: string[] = [];
        for (const token of TEXT_TOKENS) {
            for (const surface of theme.surfaces) {
                const ratio = contrastRatio(theme.tokens[token], surface);
                if (ratio < 4.5) failures.push(`${token} ${theme.tokens[token]} on ${surface}: ${ratio.toFixed(2)}`);
            }
        }
        expect(failures).toEqual([]);
    });

    it.each(THEME_ORDER)("%s: text on accent fills and the focus ring are readable", (id) => {
        const t = THEMES[id].tokens;
        expect(contrastRatio(t["--accent-ink"], t["--accent"])).toBeGreaterThanOrEqual(4.5);
        for (const surface of THEMES[id].surfaces) {
            expect(contrastRatio(t["--focus"], surface)).toBeGreaterThanOrEqual(3);
        }
    });

    it("computes the known WCAG ratio for black on white", () => {
        expect(contrastRatio("#000000", "#FFFFFF")).toBeCloseTo(21, 5);
    });
});
