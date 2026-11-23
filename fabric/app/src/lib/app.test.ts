import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { teamsHighContrastTheme, webDarkTheme, webLightTheme } from "@fluentui/react-components";

import { DBHUB_BASE, LIVE_NO_SCOPE, LIVE_REFUSED, readEstate } from "../../rayfin/functions/src/estate-core";
import { MAX_CONTEXT_ROWS } from "@/copilot/contract";
import { estateQuery } from "@/data/queries";
import { liveDataOf, liveRouteLines, liveRoutes, type InventoryData } from "@/data/live-estate";
import { flagText, inventoryMix, isDown, liveMigrations, liveOptimizationRows, liveSecurityRows, migrationSentence, readinessText, savedMigration, targetOfResource, uniqueInventory } from "@/lib/live-findings";
import { parseDeployedMigration } from "@/lib/runtime-config";
import { sampleLiveAnswers } from "@/preview/sample-live";
import { buildAskContext } from "@/lib/ask";
import { describeRequest, notebookParameters, validateRequest } from "@/lib/control";
import { parameterCellText } from "@/lib/manage-client";
import { profileLabel, SCENARIOS } from "@/lib/scenarios";
import { weekOverWeek } from "@/lib/trends";
import { DEFAULT_VIEW, mergeView, parseHash, replaceAddress, toHash } from "@/lib/view-state";
import { closestPair, VISIONS } from "@/test/color-vision";
import { APP_TOKENS, applyAppTokens, contrastRatio, FABRIC_BRAND, FLUENT_THEMES, loadThemeChoice, luminance, resolveTheme, type ThemeId } from "@/theme/fluent";
import { APP_BRAND, EARTH_ACCENTS, MICROSOFT_BRAND, TERRACOTTA_BRAND } from "@/theme/identity";
import { STAGE_TOKENS, stageStyle, stageTheme } from "@/theme/stage";

/** A stylesheet's rules, comments dropped, each with the at-rules around it (its @media, @container, ...), outermost first. */
function cssRules(css: string): Array<{ selectors: string[]; body: string; media: string[] }> {
    const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
    const rules: Array<{ selectors: string[]; body: string; media: string[] }> = [];
    const open: string[] = [];
    let start = 0;
    for (let i = 0; i < text.length; i++) {
        if (text[i] === "}") {
            open.pop();
            start = i + 1;
        } else if (text[i] === "{") {
            const prelude = (text.slice(start, i).split(";").pop() ?? "").trim();
            if (prelude.startsWith("@")) {
                open.push(prelude);
                start = i + 1;
            } else {
                const close = text.indexOf("}", i);
                rules.push({ selectors: prelude.split(",").map((s) => s.trim()), body: text.slice(i + 1, close), media: [...open] });
                i = close;
                start = close + 1;
            }
        }
    }
    return rules;
}
describe("themes", () => {
    const warm = { light: FLUENT_THEMES.light, dark: FLUENT_THEMES.dark };
    // The solid colors text and controls sit on: cards, navigation, the page, and the darker panels (a stage panel in light).
    const SURFACES = {
        light: [warm.light.colorNeutralBackground1, warm.light.colorNeutralBackground2, warm.light.colorNeutralBackground3, warm.light.colorNeutralBackground4],
        dark: [warm.dark.colorNeutralBackground1, warm.dark.colorNeutralBackground2, warm.dark.colorNeutralBackground3, warm.dark.colorNeutralBackground6],
    };
    const token = (id: "light" | "dark", name: string) => (warm[id] as unknown as Record<string, string>)[name] ?? `no ${name}`;

    it("keeps every status color readable (4.5:1) and every target and chart color visible (3:1) on each surface, and on a hovered or pressed row, button, or menu item", () => {
        for (const [id, tokens] of Object.entries(APP_TOKENS)) {
            for (const surface of [...tokens.surfaces, ...tokens.states]) {
                for (const [name, color] of Object.entries(tokens.text)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
                for (const [name, color] of Object.entries(tokens.graphic)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
        }
        // The fills a status or a target's mark sits on in a hovered or pressed row, subtle button, button, or menu item.
        for (const id of ["light", "dark"] as const) {
            for (const name of ["colorSubtleBackgroundHover", "colorSubtleBackgroundPressed", "colorNeutralBackground1Hover", "colorNeutralBackground1Pressed"]) expect(APP_TOKENS[id].states, `${id} ${name}`).toContain(token(id, name));
        }
    });

    it("keeps Fluent's text, links, buttons, inputs, and focus ring at WCAG 2.2 AA on the warm surfaces, and on a hovered or pressed fill", () => {
        for (const id of ["light", "dark"] as const) {
            const rest = SURFACES[id];
            const all = [...rest, ...APP_TOKENS[id].states];
            for (const name of ["colorNeutralForeground1", "colorNeutralForeground2", "colorNeutralForeground3", "colorBrandForeground1", "colorBrandForegroundLink", "colorBrandForegroundLinkHover"]) {
                for (const surface of all) expect(contrastRatio(token(id, name), surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
            }
            // A Fluent Link's pressed or selected color sits on a card, the navigation, or the page: no Fluent Link sits in a row
            // (DataGrid's Open is a plain link in the link color, below). A transparent button's hovered, pressed, or checked
            // text takes Fluent's brand foreground 2 on the same surfaces, since its fill stays transparent.
            for (const name of ["colorBrandForegroundLinkPressed", "colorBrandForegroundLinkSelected", "colorNeutralForeground2BrandHover", "colorNeutralForeground2BrandPressed", "colorNeutralForeground2BrandSelected"]) {
                for (const surface of rest) expect(contrastRatio(token(id, name), surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
            }
            // A subtle button's icon takes the same color on its hovered, pressed, or checked fill: a mark, so 3:1.
            for (const name of ["colorNeutralForeground2BrandHover", "colorNeutralForeground2BrandPressed", "colorNeutralForeground2BrandSelected"]) {
                for (const surface of APP_TOKENS[id].states) expect(contrastRatio(token(id, name), surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
            // Hints and placeholders sit on cards, the navigation, and the page.
            for (const surface of rest.slice(0, 3)) expect(contrastRatio(token(id, "colorNeutralForeground4"), surface), `${id} foreground 4 on ${surface}`).toBeGreaterThanOrEqual(4.5);
            for (const name of ["colorNeutralStrokeAccessible", "colorStrokeFocus2", "colorCompoundBrandForeground1", "colorCompoundBrandStroke"]) {
                for (const surface of all) expect(contrastRatio(token(id, name), surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
            for (const fill of ["colorBrandBackground", "colorBrandBackgroundHover", "colorBrandBackgroundPressed", "colorBrandBackgroundSelected"]) {
                expect(contrastRatio(token(id, "colorNeutralForegroundOnBrand"), token(id, fill)), `${id} button text on ${fill}`).toBeGreaterThanOrEqual(4.5);
            }
        }
    });

    it("gives a plain link in a table or on the Links page the theme's link color, readable at rest and in a hovered or pressed row", () => {
        // DataGrid's Open (a URL column, the Readiness page's Docs) and the Links page's Open in Fabric are plain anchors:
        // without a rule, the browser's own blue, outside the theme.
        const css = readFileSync(join(process.cwd(), "src", "styles", "app.css"), "utf8")
            .replace(/\/\*[\s\S]*?\*\//g, "")
            .replace(/@media \(forced-colors: active\) \{[\s\S]*?\n\}/g, "");
        const ruleFor = (selector: string) => [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].find((m) => m[1].split(",").map((s) => s.trim()).includes(selector))?.[2] ?? "";
        for (const selector of [".grid-table a", ".kv a"]) {
            const name = ruleFor(selector).match(/(?:^|[;\s])color:\s*var\(--(\w+)\)/)?.[1] ?? "missing";
            expect(name, selector).toBe("colorBrandForegroundLink");
            for (const id of ["light", "dark"] as const) {
                for (const surface of [...SURFACES[id], ...APP_TOKENS[id].states]) expect(contrastRatio(token(id, name), surface), `${id} ${selector} on ${surface}`).toBeGreaterThanOrEqual(4.5);
            }
        }
    });

    it("in high contrast, gives what the app colors on a hovered or pressed fill the foreground Fluent pairs with that fill, outside Windows forced colors", () => {
        // Fluent's high contrast fills a hovered or pressed row, subtle or transparent button, menu item, or list option in
        // cyan, under black. The app's own colors don't switch with it: on the cyan they were 1.03:1 to 1.53:1 (the re-check
        // of f28d6320, and the review of cc1fe148). So each place they sit on such a fill takes the foreground Fluent pairs
        // with it (styles/app.css).
        const hc = FLUENT_THEMES.contrast as unknown as Record<string, string>;
        const rules = cssRules(readFileSync(join(process.cwd(), "src", "styles", "app.css"), "utf8"));
        const ruleOf = (selector: string) => rules.find((r) => r.selectors.includes(`[data-theme="contrast"] ${selector}`));
        // Each place: what the app colors there, the property, the fill under it, and its minimum: 4.5:1 for text, 3:1 for a mark.
        const ROW = { hover: "colorSubtleBackgroundHover", active: "colorSubtleBackgroundPressed" } as const;
        const ITEM = { hover: "colorNeutralBackground1Hover", active: "colorNeutralBackground1Pressed" } as const;
        const CLEAR = { hover: "colorTransparentBackgroundHover", active: "colorTransparentBackgroundPressed" } as const;
        // Fluent drops a disabled button's, menu item's, and option's hover and pressed fill, so the black follows only an
        // enabled one: on a disabled Ask Copilot it went black on black, and the target filter's disabled item lost its mark.
        const ENABLED_ITEM = ':not([aria-disabled="true"])';
        const PLACES: Array<[selector: string, property: string, fill: string, minimum: number]> = [
            ...(["hover", "active"] as const).flatMap((s): Array<[string, string, string, number]> => [
                [`.fui-TableRow:${s} .status-badge`, "color", ROW[s], 4.5],
                [`.fui-TableRow:${s} .muted`, "color", ROW[s], 4.5],
                [`.fui-TableRow:${s} a`, "color", ROW[s], 4.5],
                [`.fui-TableRow:${s} .target-chip i`, "background", ROW[s], 3],
                // The target filter's menu, and the Manage page's target list.
                [`.fui-MenuItemCheckbox${ENABLED_ITEM}:${s} .target-chip i`, "background", ITEM[s], 3],
                [`.fui-Option${ENABLED_ITEM}:${s} .target-chip i`, "background", ITEM[s], 3],
                // The top bar's account chips, and their captions: "Fabric", the GitHub plan, and "Didn't finish".
                [`.account-chip:enabled:${s}`, "color", ROW[s], 4.5],
                [`.account-chip:enabled:${s} .account-text small`, "color", ROW[s], 4.5],
                [`.ask-copilot:enabled:${s}`, "color", ROW[s], 4.5],
                [`.ask-why:enabled:${s}`, "color", CLEAR[s], 4.5],
                [`.copilot-account:enabled:${s} .copilot-account-plan`, "color", CLEAR[s], 4.5],
            ]),
            // A KPI tile's button: the app's own hover fill, which a press keeps.
            ["button.kpi-main:hover", "color", ROW.hover, 4.5],
            ["button.kpi-main:hover .kpi-label", "color", ROW.hover, 4.5],
            ["button.kpi-main:hover .kpi-sub", "color", ROW.hover, 4.5],
        ];
        for (const [selector, property, fill, minimum] of PLACES) {
            const rule = ruleOf(selector);
            const name = rule?.body.match(new RegExp(`(?:^|[;\\s])${property}:\\s*var\\(--(\\w+)\\)`))?.[1] ?? "missing";
            expect(contrastRatio(hc[name] ?? `no ${name}`, hc[fill]), `${selector}: ${name} on ${fill}`).toBeGreaterThanOrEqual(minimum);
            // A target's mark is an inline background, and Ask's text the brand's with !important: only !important replaces them.
            if (/target-chip i$|^\.ask-/.test(selector)) expect(rule?.body, selector).toMatch(/!important\s*;/);
            // Not under Windows forced colors: the app picks high contrast there too, but a hovered menu item takes the system's
            // Highlight under forced-color-adjust: none, on which Fluent's black can be 2.78:1 (the Desert theme's #903909).
            expect(rule?.media, selector).toEqual(["@media (forced-colors: none)"]);
        }
        // Every high contrast rule for a hovered or pressed control is in that group, and none colors a disabled one.
        for (const rule of rules.filter((r) => r.selectors.some((s) => s.startsWith('[data-theme="contrast"]') && /:(hover|active)\b/.test(s)))) {
            expect(rule.media, rule.selectors.join(", ")).toEqual(["@media (forced-colors: none)"]);
            for (const s of rule.selectors) {
                if (/\.(ask-copilot|ask-why|account-chip|copilot-account)\b/.test(s)) expect(s).toContain(":enabled");
                if (/\.fui-(MenuItemCheckbox|Option)\b/.test(s)) expect(s).toContain(ENABLED_ITEM);
            }
        }
        // A bar chart's hovered category: the cyan band would sit under high contrast's bright bars (1.03:1 to 1.36:1), so
        // it's an outline with no fill, at 3:1 or more on the chart's black. Under forced colors too, where the app's high
        // contrast charts keep their colors.
        const band = ruleOf(".chart-cursor-band rect");
        expect(band?.body, "the band's fill").toMatch(/(?:^|[;\s])fill:\s*none\s*;/);
        const stroke = band?.body.match(/(?:^|[;\s])stroke:\s*var\(--(\w+)\)/)?.[1] ?? "missing";
        expect(contrastRatio(hc[stroke] ?? `no ${stroke}`, hc.colorNeutralBackground1), `the band's outline, ${stroke}`).toBeGreaterThanOrEqual(3);
        expect(band?.media, "the band's outline").toEqual([]);
    });

    it("under Windows forced colors, gives a hovered filter item's target mark HighlightText, the system's pair for the Highlight Fluent paints the item in", () => {
        // Fluent's hovered menu item takes the system's Highlight under forced-color-adjust: none, so a target's mark showed its
        // theme color on it, as low as 1.01:1 on Night sky's Highlight (the review of cc1fe148).
        const rules = cssRules(readFileSync(join(process.cwd(), "src", "styles", "app.css"), "utf8"));
        const selector = '.fui-MenuItemCheckbox:not([aria-disabled="true"]):hover .target-chip i';
        const rule = rules.find((r) => r.selectors.includes(selector));
        expect(rule?.media, selector).toEqual(["@media (forced-colors: active)"]);
        // The mark's color is an inline background: only !important replaces it.
        expect(rule?.body, selector).toMatch(/(?:^|[;\s])background:\s*HighlightText\s*!important\s*;/);
        // Only there: a list option, and a disabled or focused item, have no Highlight under forced colors, and HighlightText
        // on their Canvas would hide the mark as surely as Canvas does.
        const marks = rules.filter((r) => r.media.includes("@media (forced-colors: active)") && r.selectors.some((s) => s.includes(".target-chip")));
        expect(marks.flatMap((r) => r.selectors)).toEqual([selector]);
    });
    it("keeps the chart's incident band label readable (4.5:1) with the band over each surface a chart sits on, the stage's included", () => {
        // The band is translucent: its label sits on the band blended over the surface, as the browser composites it.
        const over = (rgba: string, base: string) => {
            const [r, g, b, a] = (rgba.match(/[\d.]+/g) ?? []).map(Number);
            const channel = (i: number) => parseInt(base.slice(1 + 2 * i, 3 + 2 * i), 16);
            return `#${[r, g, b].map((c, i) => Math.round(c * a + channel(i) * (1 - a)).toString(16).padStart(2, "0")).join("")}`;
        };
        for (const id of ["light", "dark", "contrast"] as const) {
            const { decor, text, surfaces } = APP_TOKENS[id];
            expect(decor["--chart-band"]).toMatch(/^rgba\(/);
            for (const surface of new Set([...surfaces, ...Object.values(STAGE_TOKENS[id].surfaces)])) {
                const fill = over(decor["--chart-band"], surface);
                expect(contrastRatio(text["--chart-band-ink"], fill), `${id}: the band's label on ${fill}, the band over ${surface}`).toBeGreaterThanOrEqual(4.5);
            }
        }
    });

    it("keeps every badge the app shows legible in light and dark: its text on its own fill, or on each surface for an outline", () => {
        // Fluent 9's badge colors (useBadgeStyles): the text's token, and its fill's, or none for an outline, which sits on
        // the surface. Subtle's outline draws its text in the static inverted color, meant for a dark or brand fill: on the
        // app's surfaces it was invisible, cream on cream (the review of 2b0e46b0).
        const BADGES: Record<string, [text: string, fill: string | null]> = {
            "filled-brand": ["colorNeutralForegroundOnBrand", "colorBrandBackground"],
            "tint-informative": ["colorNeutralForeground3", "colorNeutralBackground4"],
            "tint-success": ["colorPaletteGreenForeground1", "colorPaletteGreenBackground1"],
            "tint-warning": ["colorPaletteYellowForeground1", "colorPaletteYellowBackground1"],
            "outline-informative": ["colorNeutralForeground3", null],
            "outline-subtle": ["colorNeutralForegroundStaticInverted", null],
        };
        const COLOR = /^(brand|danger|important|informative|severe|subtle|success|warning)$/;
        // A JSX opening tag, to its closing angle bracket outside any braces (an icon prop holds a tag of its own).
        const openingTag = (source: string, from: number) => {
            let depth = 0;
            for (let i = from; i < source.length; i++) {
                if (source[i] === "{") depth++;
                else if (source[i] === "}") depth--;
                else if (source[i] === ">" && depth === 0) return source.slice(from, i + 1);
            }
            return source.slice(from);
        };
        const src = join(process.cwd(), "src");
        const files = (readdirSync(src, { recursive: true, encoding: "utf8" }) as string[]).filter((f) => f.endsWith(".tsx") && !f.endsWith(".test.tsx"));
        const used = new Set<string>();
        for (const file of files) {
            const source = readFileSync(join(src, file), "utf8");
            for (const match of source.matchAll(/<Badge\b/g)) {
                const tag = openingTag(source, match.index ?? 0);
                const appearance = tag.match(/\bappearance="(\w+)"/)?.[1] ?? "filled";
                const literal = tag.match(/\bcolor="(\w+)"/)?.[1];
                const expression = tag.match(/\bcolor=\{([^{}]*)\}/)?.[1] ?? "";
                // A helper's colors are the literals of its definition in the same file (MigrationCard's badgeColor).
                const helper = expression.match(/^\s*(\w+)\(/)?.[1];
                const scope = helper ? (source.match(new RegExp(`\\b${helper}\\s*=[^;]*;`))?.[0] ?? "") : expression;
                const colors = literal ? [literal] : /\bcolor=/.test(tag) ? [...scope.matchAll(/"(\w+)"/g)].map((m) => m[1]).filter((c) => COLOR.test(c)) : ["brand"];
                expect(colors.length, `${file}: a badge whose color the test can't read`).toBeGreaterThan(0);
                for (const color of colors) used.add(`${appearance}-${color}`);
            }
        }
        expect(used.size).toBeGreaterThanOrEqual(4);
        for (const combination of used) {
            expect(BADGES[combination], `${combination}: add Fluent's tokens for it to this test`).toBeDefined();
            const [text, fill] = BADGES[combination];
            for (const id of ["light", "dark"] as const) {
                for (const background of fill ? [token(id, fill)] : SURFACES[id]) expect(contrastRatio(token(id, text), background), `${id} ${combination} badge on ${background}`).toBeGreaterThanOrEqual(4.5);
            }
        }
    });

    it("puts cream and ivory where white was, and espresso where near-black was, with softer but AAA body text (the owner, 2026-11-23)", () => {
        const PURE_GRAY = /^#([0-9a-f]{2})\1\1$/i;
        const GRAY_RGBA = /rgba\((\d{1,3}),\s*\1,\s*\1,/;
        const warmish = (hex: string) => parseInt(hex.slice(1, 3), 16) > parseInt(hex.slice(5, 7), 16);
        for (const id of ["light", "dark"] as const) {
            // Every gray Fluent uses, its hover, pressed, selected, and disabled states included, takes a warm color.
            const grays = Object.entries(warm[id]).filter(([, value]) => typeof value === "string" && (PURE_GRAY.test(value) || GRAY_RGBA.test(value) || /rgba\(0,\s*0,\s*0,/.test(value)));
            expect(grays, `${id}: Fluent grays left`).toEqual([]);
            for (const name of ["colorNeutralBackground1", "colorNeutralBackground3", "colorNeutralForeground1", "colorNeutralStroke2"]) expect(warmish(token(id, name)), `${id} ${name} is warm`).toBe(true);
        }
        expect(warm.light.colorNeutralBackground1.toUpperCase()).not.toBe("#FFFFFF");
        expect(warm.dark.colorNeutralForeground1.toUpperCase()).not.toBe("#FFFFFF");
        // Softer: body text stays above AAA's 7:1 but well under Fluent's 15.5:1 (light) and 14.5:1 (dark) on a card.
        for (const id of ["light", "dark"] as const) {
            const body = contrastRatio(token(id, "colorNeutralForeground1"), token(id, "colorNeutralBackground1"));
            expect(body, `${id} body text on a card`).toBeGreaterThanOrEqual(7);
            expect(body, `${id} body text on a card`).toBeLessThanOrEqual(12.5);
        }
        // Dark surfaces a step lighter than Fluent's near-black.
        expect(luminance(warm.dark.colorNeutralBackground3)).toBeGreaterThan(luminance(webDarkTheme.colorNeutralBackground3));
        expect(luminance(warm.dark.colorNeutralBackground1)).toBeGreaterThan(luminance(webDarkTheme.colorNeutralBackground1));
    });

    it("colors message bars and badges in the same earth tones, each readable on its own fill", () => {
        for (const id of ["light", "dark"] as const) {
            for (const family of ["Danger", "Warning", "Success"]) {
                const fill = token(id, `colorStatus${family}Background1`);
                expect(contrastRatio(token(id, "colorNeutralForeground1"), fill), `${id} ${family} message text`).toBeGreaterThanOrEqual(4.5);
                expect(contrastRatio(token(id, `colorStatus${family}Foreground1`), fill), `${id} ${family} foreground 1`).toBeGreaterThanOrEqual(4.5);
                expect(contrastRatio(token(id, `colorStatus${family}Foreground3`), fill), `${id} ${family} icon`).toBeGreaterThanOrEqual(3);
                expect(token(id, `colorStatus${family}Background3`).toLowerCase(), `${id} ${family} is the app's`).not.toBe((id === "light" ? webLightTheme : webDarkTheme)[`colorStatus${family}Background3` as "colorStatusDangerBackground3"].toLowerCase());
            }
            // Fluent's badges (useBadgeStyles): tint, filled, and outline, in red, dark orange, green, and yellow.
            for (const color of ["Red", "DarkOrange", "Green", "Yellow"]) {
                expect(contrastRatio(token(id, `colorPalette${color}Foreground1`), token(id, `colorPalette${color}Background1`)), `${id} ${color} tint badge`).toBeGreaterThanOrEqual(4.5);
                const filledText = color === "Yellow" ? "colorNeutralForeground1Static" : "colorNeutralForegroundOnBrand";
                expect(contrastRatio(token(id, filledText), token(id, `colorPalette${color}Background3`)), `${id} ${color} filled badge`).toBeGreaterThanOrEqual(4.5);
                const outline = color === "Yellow" ? "colorPaletteYellowForeground2" : `colorPalette${color}Foreground3`;
                for (const surface of SURFACES[id]) expect(contrastRatio(token(id, outline), surface), `${id} ${color} outline badge on ${surface}`).toBeGreaterThanOrEqual(4.5);
            }
        }
    });

    it("tells the four statuses apart under protanopia, deuteranopia, and tritanopia too, by lightness as well as hue", () => {
        for (const id of ["light", "dark"] as const) {
            const text = APP_TOKENS[id].text;
            const statuses = { Fail: text["--status-fail"], Warning: text["--status-warning"], Pass: text["--status-pass"], Manual: text["--status-manual"] };
            for (const vision of VISIONS) {
                const { pair, distance } = closestPair(statuses, vision);
                expect(distance, `${id}, ${vision}: ${pair}`).toBeGreaterThanOrEqual(vision === "normal" ? 0.12 : 0.09);
            }
        }
    });

    it("keeps each target's mark its own under every color vision, and the charts' eight categories apart", () => {
        for (const id of ["light", "dark"] as const) {
            const graphic = APP_TOKENS[id].graphic;
            const targets = Object.fromEntries(Object.entries(graphic).filter(([name]) => name.startsWith("--target-")));
            expect(Object.keys(targets)).toHaveLength(6);
            for (const vision of VISIONS) {
                const { pair, distance } = closestPair(targets, vision);
                expect(distance, `${id}, ${vision}: ${pair}`).toBeGreaterThanOrEqual(vision === "normal" ? 0.1 : 0.07);
            }
            const charts = Object.fromEntries(Object.entries(graphic).filter(([name]) => name.startsWith("--chart-")));
            expect(Object.keys(charts)).toHaveLength(8);
            const { pair, distance } = closestPair(charts, "normal");
            expect(distance, `${id} charts: ${pair}`).toBeGreaterThanOrEqual(0.06);
        }
    });

    it("keeps the navigation's hovered and selected page readable in every theme, high contrast included", () => {
        // The token pairs styles/app.css applies, read from its rules: high contrast's selected and hover fill is cyan.
        const css = readFileSync(join(process.cwd(), "src", "styles", "app.css"), "utf8");
        const rule = (selector: string) => {
            const body = css.match(new RegExp(`^${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{([^}]*)\\}`, "m"))?.[1] ?? "";
            const token = (property: string) => body.match(new RegExp(`(?:^|[;\\s])${property}:\\s*var\\(--(\\w+)\\)`))?.[1] ?? "missing";
            return { color: token("color"), background: token("background") };
        };
        const hover = rule(".nav-item:hover");
        const selected = rule('.nav-item[aria-current="page"]');
        const bar = rule('.nav-item[aria-current="page"]::before');
        const icon = rule('.nav-item[aria-current="page"] .nav-icon');
        for (const [id, theme] of Object.entries(FLUENT_THEMES)) {
            const value = (token: string) => (theme as unknown as Record<string, string>)[token] ?? `no ${token}`;
            expect(contrastRatio(value(hover.color), value(hover.background)), `${id}: hovered page`).toBeGreaterThanOrEqual(4.5);
            expect(contrastRatio(value(selected.color), value(selected.background)), `${id}: selected page`).toBeGreaterThanOrEqual(4.5);
            expect(contrastRatio(value(icon.color), value(selected.background)), `${id}: selected page's icon`).toBeGreaterThanOrEqual(3);
            expect(contrastRatio(value(bar.background), value(selected.background)), `${id}: selected page's bar`).toBeGreaterThanOrEqual(3);
        }
    });

    it("marks the current page with the system's selection colors under Windows forced colors, where the theme's colors give way, and keeps its name legible (F22)", () => {
        const css = readFileSync(join(process.cwd(), "src", "styles", "app.css"), "utf8");
        const forced = css.match(/@media \(forced-colors: active\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
        const rule = (selector: string) => forced.match(new RegExp(`^\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{([^}]*)\\}`, "m"))?.[1] ?? "";
        const value = (body: string, property: string) => body.match(new RegExp(`(?:^|[;\\s])${property}:\\s*([^;]+);`))?.[1]?.trim() ?? "missing";
        const selected = rule('.nav-item[aria-current="page"]');
        // Every other item takes the system's text on its canvas; the current one, its selection colors, like Windows's own lists.
        expect([value(selected, "background"), value(selected, "color")]).toEqual(["Highlight", "HighlightText"]);
        expect(value(rule('.nav-item[aria-current="page"] .nav-icon'), "color")).toBe("HighlightText");
        expect(value(rule('.nav-item[aria-current="page"]::before'), "background")).toBe("HighlightText");
        // Without it, Edge paints its readability backplate (Canvas) behind the HighlightText name: black on black, 1:1, as
        // the final tests found in headless Edge; with it, 14.11:1 on the dark palette and 14.83:1 on the light one. Its focus
        // ring then keeps the theme's color, which can be the Canvas's: CanvasText, as forced colors paint one.
        expect(value(selected, "forced-color-adjust")).toBe("none");
        expect(value(selected, "outline-color")).toBe("CanvasText");
    });

    it("marks the kiosk's current scene with the system's selection colors under Windows forced colors, as the current page, legibly (F22)", () => {
        const css = readFileSync(join(process.cwd(), "src", "mission", "mission.css"), "utf8");
        const forced = css.match(/@media \(forced-colors: active\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
        const body = forced.match(/^\s*\.kiosk-scenes button\[aria-current="step"\]\s*\{([^}]*)\}/m)?.[1] ?? "";
        const value = (property: string) => body.match(new RegExp(`(?:^|[;\\s])${property}:\\s*([^;]+);`))?.[1]?.trim() ?? "missing";
        // Its marks on the stage, a border's color and an inset shadow, give way in forced colors: the system's selection colors don't.
        expect([value("background"), value("color")]).toEqual(["Highlight", "HighlightText"]);
        // Without it, its name was painted at 1.89:1 over Edge's backplate; with it, at 14.11:1. Then nothing is forced: no
        // shadow from the stage, and a CanvasText focus ring.
        expect([value("forced-color-adjust"), value("box-shadow"), value("outline-color")]).toEqual(["none", "none", "CanvasText"]);
    });

    it("uses terracotta as the brand, not Microsoft blue or Fabric's teal, from one set of tokens, and leaves high contrast Fluent's own (the owner's choice, 2026-11-23)", () => {
        expect(APP_BRAND).toBe(TERRACOTTA_BRAND);
        expect(FLUENT_THEMES.light.colorBrandBackground).toBe(TERRACOTTA_BRAND[80]);
        expect(FLUENT_THEMES.light.colorBrandForegroundLink).toBe(TERRACOTTA_BRAND[70]);
        expect(FLUENT_THEMES.dark.colorBrandBackground).toBe(TERRACOTTA_BRAND[70]);
        expect(FLUENT_THEMES.dark.colorBrandForegroundLink).toBe(TERRACOTTA_BRAND[120]);
        for (const other of [MICROSOFT_BRAND[80], FABRIC_BRAND[80]]) expect(FLUENT_THEMES.light.colorBrandBackground).not.toBe(other);
        // Neither the warm grays nor the earth-toned statuses reach high contrast.
        expect(FLUENT_THEMES.contrast).toBe(teamsHighContrastTheme);
    });

    it("marks each target and the charts' categories with the earth accents: slate, moss, ochre, and clay first", () => {
        for (const id of ["light", "dark"] as const) {
            const a = EARTH_ACCENTS[id];
            const graphic = APP_TOKENS[id].graphic;
            expect(["--target-t1", "--target-t2", "--target-t3", "--target-t4", "--target-t5", "--target-t4r"].map((t) => graphic[t]), `${id} targets`).toEqual([a.slate, a.moss, a.ochre, a.clay, a.plum, a.verdigris]);
            expect(Array.from({ length: 8 }, (_, i) => graphic[`--chart-${i + 1}`]), `${id} charts`).toEqual([a.slate, a.moss, a.ochre, a.clay, a.plum, a.verdigris, a.stone, a.rose]);
        }
    });

    it("layers the stage on the app's warm neutrals and shadows: a panel a layer above the stage, with the theme's shadow under it", () => {
        const { light, dark } = FLUENT_THEMES;
        expect(STAGE_TOKENS.dark.surfaces).toEqual({ "--stage-bg": dark.colorNeutralBackground3, "--stage-panel": dark.colorNeutralBackground2, "--stage-panel-2": dark.colorNeutralBackground1 });
        expect(STAGE_TOKENS.light.surfaces).toEqual({ "--stage-bg": light.colorNeutralBackground3, "--stage-panel": light.colorNeutralBackground1, "--stage-panel-2": light.colorNeutralBackground4 });
        expect(STAGE_TOKENS.dark.decor["--stage-shadow"]).toBe(dark.shadow8);
        expect(STAGE_TOKENS.light.decor["--stage-shadow"]).toBe(light.shadow8);
        expect(STAGE_TOKENS.contrast.decor["--stage-shadow"]).toBe("none");
        // The stage's ink is the theme's own text.
        expect(STAGE_TOKENS.light.text["--stage-ink"]).toBe(light.colorNeutralForeground1);
        expect(STAGE_TOKENS.dark.text["--stage-ink"]).toBe(dark.colorNeutralForeground1);
    });

    it("keeps the stage's text readable (4.5:1) and its marks visible (3:1), with the app's own tokens on it, in every theme", () => {
        for (const id of ["light", "dark", "contrast"] as const) {
            const stage = STAGE_TOKENS[id];
            const text = { ...stage.text, ...APP_TOKENS[id].text };
            const graphic = { ...stage.graphic, ...APP_TOKENS[id].graphic };
            for (const surface of Object.values(stage.surfaces)) {
                for (const [name, color] of Object.entries(text)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(4.5);
                for (const [name, color] of Object.entries(graphic)) expect(contrastRatio(color, surface), `${id} ${name} on ${surface}`).toBeGreaterThanOrEqual(3);
            }
        }
    });

    it("keeps the stage's calm accent and its alert apart, for every color vision", () => {
        for (const id of ["light", "dark"] as const) {
            const g = STAGE_TOKENS[id].graphic;
            for (const vision of VISIONS) {
                const { distance } = closestPair({ accent: g["--stage-accent"], alert: g["--stage-alert"] }, vision);
                expect(distance, `${id}, ${vision}`).toBeGreaterThanOrEqual(0.08);
            }
        }
    });

    it("keeps the Copilot mark's glyph visible on both ends of its fill, and high contrast's mark as it was", () => {
        for (const [id, tokens] of Object.entries(APP_TOKENS)) {
            const stops = tokens.decor["--copilot-mark"].match(/#[0-9a-f]{6}/gi) ?? [];
            expect(stops, `${id} stops`).toHaveLength(2);
            for (const stop of stops) expect(contrastRatio(tokens.decor["--copilot-mark-ink"], stop), `${id} glyph on ${stop}`).toBeGreaterThanOrEqual(3);
        }
        expect(APP_TOKENS.contrast.decor["--copilot-mark"]).toBe("linear-gradient(135deg, #8A3FFC 0%, #0F6CBD 100%)");
    });

    it("colors every stylesheet from the theme only: no literal color outside forced colors, and every app and stage token defined in every theme", () => {
        const files = [["styles", "app.css"], ["mission", "mission.css"], ["rca", "view", "rca.css"], ["copilot", "copilot-dock.css"], ["visuals", "chart-view.css"]];
        for (const parts of files) {
            const css = readFileSync(join(process.cwd(), "src", ...parts), "utf8").replace(/@media \(forced-colors: active\) \{[\s\S]*?\n\}/g, "");
            expect(css.match(/#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\(/gi), parts.join("/")).toBeNull();
            const used = [...new Set([...css.matchAll(/var\((--(?:status|target|chart|copilot|stage)-[a-z0-9-]+)\)/g)].map((m) => m[1]))];
            for (const id of ["light", "dark", "contrast"] as const) {
                const app = { ...APP_TOKENS[id].text, ...APP_TOKENS[id].graphic, ...APP_TOKENS[id].decor };
                const stage = STAGE_TOKENS[id];
                const defined = { ...app, ...stage.surfaces, ...stage.text, ...stage.graphic, ...stage.decor };
                for (const name of used) expect(defined[name], `${parts.join("/")}: ${name} in ${id}`).toBeTruthy();
            }
        }
    });

    it("sets the app's tokens, the chart band and the Copilot mark included, on <html> and on a stage", () => {
        const root = document.createElement("div");
        applyAppTokens("dark", root);
        expect(root.dataset.theme).toBe("dark");
        for (const [name, value] of Object.entries({ ...APP_TOKENS.dark.text, ...APP_TOKENS.dark.graphic, ...APP_TOKENS.dark.decor })) expect(root.style.getPropertyValue(name), name).toBe(value);
        const style = stageStyle("light", APP_TOKENS.light) as Record<string, string>;
        expect(style["--chart-band"]).toBe(APP_TOKENS.light.decor["--chart-band"]);
        expect(style["--chart-band-ink"]).toBe(APP_TOKENS.light.text["--chart-band-ink"]);
    });

    it("makes the stage dark until the viewer picks a theme, and keeps a picked theme and high contrast", () => {
        expect(stageTheme("system", "light")).toBe("dark");
        expect(stageTheme("system", "dark")).toBe("dark");
        expect(stageTheme("system", "contrast")).toBe("contrast");
        expect(stageTheme("light", "light")).toBe("light");
        expect(stageTheme("dark", "dark")).toBe("dark");
        expect(stageTheme("contrast", "contrast")).toBe("contrast");
        const style = stageStyle("dark", APP_TOKENS.dark) as Record<string, string>;
        expect(style["--stage-bg"]).toBe(STAGE_TOKENS.dark.surfaces["--stage-bg"]);
        expect(style["--status-fail"]).toBe(APP_TOKENS.dark.text["--status-fail"]);
    });

    it("follows the system until the viewer picks, and carries over the older app's choice", () => {
        expect(resolveTheme("system", true, false)).toBe("dark");
        expect(resolveTheme("system", false, true)).toBe("contrast");
        expect(resolveTheme("light", true, true)).toBe("light");
        const store = (values: Record<string, string>) => ({ getItem: (k: string) => values[k] ?? null });
        expect(loadThemeChoice(store({ "dbhub-insights.theme.v1": "aurora" }))).toBe("dark");
        expect(loadThemeChoice(store({ "dbhub-insights.theme.v2": "contrast", "dbhub-insights.theme.v1": "daybreak" }))).toBe("contrast");
        expect(loadThemeChoice(undefined)).toBe("system");
        const ids: ThemeId[] = ["light", "dark", "contrast"];
        expect(Object.keys(FLUENT_THEMES).sort()).toEqual([...ids].sort());
    });
});
describe("view state", () => {
    it("round-trips drill-downs and the filter through the hash", () => {
        const view = mergeView({ page: "estate", target: "T3", targets: ["T1", "T3"], window: "30d" });
        expect(toHash(view)).toBe("#/estate/T3?t=T1%2CT3&w=30d");
        expect(mergeView(parseHash(toHash(view)))).toEqual(view);
        const incident = mergeView({ page: "incidents", incident: "scenario:T3:cpu:7", replay: 4 });
        expect(toHash(incident)).toBe("#/incidents/scenario%3AT3%3Acpu%3A7?r=4");
        expect(mergeView(parseHash(toHash(incident)))).toEqual(incident);
        expect(toHash(DEFAULT_VIEW)).toBe("#/mission");
    });

    it("keeps the session in focus and the replay's moment in the address, and opens the kiosk from it", () => {
        const moment = mergeView({ page: "replay", session: "session:7f3a9c21", replay: 33 });
        expect(toHash(moment)).toBe("#/replay?s=session%3A7f3a9c21&r=33");
        expect(mergeView(parseHash(toHash(moment)))).toEqual(moment);
        expect(parseHash("#/kiosk")).toEqual({ page: "kiosk" });
        expect(parseHash("#/scoreboard?s=<script>").session).toBeUndefined();
    });

    it("keeps the view in memory when the browser refuses another address change (WebKit, past 100 in 10 seconds)", () => {
        const refusing = {
            location: { hash: "#/replay?r=1" },
            history: {
                replaceState: vi.fn(() => {
                    throw new DOMException("Attempt to use history.replaceState() more than 100 times per 10 seconds", "SecurityError");
                }),
            },
        };
        expect(() => replaceAddress("#/replay?r=2", refusing as unknown as Pick<Window, "location" | "history">)).not.toThrow();
        const browser = { location: { hash: "#/replay?r=1" }, history: { replaceState: vi.fn() } };
        replaceAddress("#/replay?r=2", browser as unknown as Pick<Window, "location" | "history">);
        replaceAddress("#/replay?r=1", browser as unknown as Pick<Window, "location" | "history">);
        expect(browser.history.replaceState).toHaveBeenCalledTimes(1);
        expect(browser.history.replaceState).toHaveBeenCalledWith(null, "", "#/replay?r=2");
    });

    it("opens a Findings category from the address, and drops an unknown one", () => {
        expect(parseHash("#/findings/security")).toMatchObject({ page: "findings", category: "security" });
        expect(parseHash("#/findings/bogus").category).toBeUndefined();
        expect(toHash(mergeView({ page: "findings", category: "optimization" }))).toBe("#/findings/optimization");
    });
    it("opens an older app's PostgreSQL page as T4's drill-down, and drops unknown or unsafe values", () => {
        expect(parseHash("#/postgres")).toEqual({ page: "estate", target: "T4" });
        expect(parseHash("#/admin?t=T9,T2&w=1y&i=<script>&r=-3")).toEqual({ targets: ["T2"] });
        expect(parseHash("#/estate/T9")).toEqual({ page: "estate" });
        expect(parseHash("#/incidents/%E0%A4%A")).toEqual({ page: "incidents" });
    });
});

describe("Ask Copilot's context", () => {
    it("bounds the rows, makes dates plain text, and joins the DAX behind them", () => {
        const spec = estateQuery({ targets: ["T3"], window: null });
        const rows = Array.from({ length: MAX_CONTEXT_ROWS + 5 }, (_, i) => ({ at: new Date(Date.UTC(2026, 10, 17, 0, i)), cpu: i }));
        const ctx = buildAskContext({ title: "CPU", page: "estate", visualId: "estate.target.cpu", specs: [spec, null], rows, provenance: "history", meta: null, prompt: "Why?" });
        expect(ctx.rows).toHaveLength(MAX_CONTEXT_ROWS);
        expect(ctx).toMatchObject({ totalRows: MAX_CONTEXT_ROWS + 5, truncated: true, prompt: "Why?", source: "history" });
        expect(ctx.rows?.[1]).toEqual({ at: "2026-11-17T00:01:00.000Z", cpu: 1 });
        expect(ctx.dax).toBe(`// ${spec.title}\n${spec.dax}`);
    });
});

describe("the control's requests", () => {
    it("maps each action to the control notebook's parameters", () => {
        expect(notebookParameters({ action: "session", durationMinutes: 60 })).toEqual({
            MODE: { value: "session", type: "string" },
            DURATION_MINUTES: { value: 60, type: "int" },
            WAIT_FOR_END: { value: true, type: "bool" },
        });
        expect(notebookParameters({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10, intensity: 7 })).toMatchObject({
            MODE: { value: "activities" },
            ACTIVITIES: { value: '[{"target":"T3","scenario":"cpu-pressure","intensity":7}]', type: "string" },
        });
        expect(notebookParameters({ action: "stop" })).toEqual({ STOP_NOW: { value: true, type: "bool" } });
        expect(notebookParameters({ action: "reset", targets: ["T1", "T3"] })).toEqual({ RESET_NOW: { value: true, type: "bool" }, RESET_TARGETS: { value: '["T1","T3"]', type: "string" } });
    });

    it("rejects what the control's allow-lists and caps would", () => {
        expect(validateRequest({ action: "session", durationMinutes: 200 })).toBe("A session runs 30 to 120 minutes.");
        expect(validateRequest({ action: "run", scenario: "replica-lag", target: "T3" })).toBe("Read replica lag runs on T4.");
        expect(validateRequest({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 45 })).toBe("CPU pressure runs 5 to 30 minutes.");
        expect(validateRequest({ action: "run", scenario: "drop-database", target: "T3" })).toBe("Pick a scenario from the catalog.");
        expect(validateRequest({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10 })).toBeNull();
        expect(describeRequest({ action: "stop" }).effects[0]).toBe("Stops every running activity.");
        expect(describeRequest({ action: "session" }).effects[2]).toMatch(/^Includes T3's Database Agent beat/);
    });

    it("copies a request as Python lines for a new cell under the control notebook's parameters cell", () => {
        expect(parameterCellText({ action: "run", scenario: "cpu-pressure", target: "T3", durationMinutes: 10, intensity: 6 }).split("\n").slice(1)).toEqual([
            'MODE = "activities"',
            'ACTIVITIES = [{"target":"T3","scenario":"cpu-pressure","intensity":6}]',
            "DURATION_MINUTES = 10",
            "WATCH_MINUTES = 0",
        ]);
        expect(parameterCellText({ action: "reset", targets: ["T1", "T3"] })).toMatch(/\nRESET_NOW = True\nRESET_TARGETS = \["T1","T3"\]$/);
        expect(parameterCellText({ action: "stop" })).toMatch(/^# From the Insights app: stop\. .+\nSTOP_NOW = True$/);
    });
    it("offers exactly the scenarios in scenarios/*/scenario.json, with their targets and bounds", () => {
        const root = join(process.cwd(), "..", "..", "scenarios");
        const fromRepo = readdirSync(root, { withFileTypes: true })
            .filter((d) => d.isDirectory())
            .map((d) => JSON.parse(readFileSync(join(root, d.name, "scenario.json"), "utf8")) as { id: string; title: string; duration: { defaultSeconds: number; maxSeconds: number }; targets: { applicable: string[] } })
            .map((s) => ({ id: s.id, title: s.title, targets: s.targets.applicable, defaultMinutes: Math.round(s.duration.defaultSeconds / 60), maxMinutes: Math.floor(s.duration.maxSeconds / 60) }))
            .sort((a, b) => a.id.localeCompare(b.id));
        expect(SCENARIOS).toEqual(fromRepo);
    });

    it("names each recorded profile: a session, an incident by its scenario's title, a reset", () => {
        expect(["showcase", "incident:plan-regression", "incident:not-in-catalog", "reset", ""].map(profileLabel)).toEqual(["Session", "Plan regression (automatic plan correction)", "not-in-catalog", "Reset", "Session"]);
    });
});

describe("trends", () => {
    it("compares the newest week with the week before, per target", () => {
        const day = (d: number) => new Date(Date.UTC(2026, 10, 1 + d));
        const days = [
            ...Array.from({ length: 14 }, (_, d) => ({ day: day(d), target: "T1" as const, cpuAvg: d < 7 ? 10 : 20, cpuPeak: null, waitS: 1, bufferIoS: null, lockWaitS: null, batch: null, sessionsPeak: null, incidents: d === 13 ? 1 : 0 })),
        ];
        const [t1] = weekOverWeek(days);
        expect(t1).toMatchObject({ target: "T1", cpuNow: 20, cpuBefore: 10, waitNow: 7, waitBefore: 7, incidentsNow: 1, incidentsBefore: 0 });
        expect(weekOverWeek([])).toEqual([]);
    });
});

describe("live findings", () => {
    it("names the demo's targets, reads Database Hub's flags, and keeps each warning once", () => {
        const answers = sampleLiveAnswers("2026-10-21T21:00:00.000Z");
        expect(targetOfResource({ name: "pgreplica01-x", databaseType: "PostgreSql" })).toBe("T4-replica");
        expect(targetOfResource({ name: "ContosoCare", databaseType: "AzureSql" }, "azuresql01-x")).toBe("T3");
        expect(targetOfResource({ name: "elsewhere", databaseType: "PostgreSql" })).toBe("");
        expect(flagText("hasSomethingNewIssue")).toBe("Something new");
        const inventory = liveDataOf(answers.inventory);
        const rows = liveSecurityRows(liveDataOf(answers.security), inventory);
        expect(rows.map((r) => `${r.attention}|${r.target}|${r.area}`)).toEqual([
            "Needs attention|T3|Auditing",
            "Needs attention|T3|Customer-managed keys",
            "Recommended|T3|Ledger",
            "Recommended|T4|Customer-managed keys",
            "Recommended|T4-replica|Customer-managed keys",
        ]);
        // Live, 2026-11-18: neither T1 nor T2 has a license finding, and a ready assessment isn't an issue.
        expect(liveOptimizationRows(inventory)).toEqual([]);
        expect(inventoryMix(inventory)).toBe("2 PostgreSQL · 1 Arc SQL · 1 Azure SQL · 1 SQL VM · 1 Cosmos DB");
        expect(inventoryMix(inventory, true)).toMatch(/^2 Azure Database for PostgreSQL, 1 Arc-enabled SQL Server, /);
        expect(liveSecurityRows(null, null)).toEqual([]);
        expect(flagText("hasUsageReportingIssue")).toBe("Usage reporting to Azure needs attention");
    });

    it("counts a SQL Server on an Azure VM once, though Database Hub lists its VM and its instance (live, 2026-11-18)", () => {
        const vm = { databaseType: "AzureSqlVM", name: "sqlvm01", resourceGroup: "rg-x", location: "westus3" };
        const inventory: InventoryData = {
            totalCount: 3,
            countByType: { AzureSqlVM: 2, AzureSql: 1 },
            complete: true,
            resources: [
                { ...vm, status: "Unknown", issues: { optimization: { hasPaygLicenseIssue: true, hasLowComputeUtilizationIssue: false } } },
                { ...vm, resourceGroup: "RG-X", status: "Connected", issues: { optimization: { hasLowComputeUtilizationIssue: true } } },
                { databaseType: "AzureSql", name: "ContosoCare", resourceGroup: "rg-x", location: "westus3", status: "Online" },
            ],
        };
        const unique = uniqueInventory(inventory);
        expect(unique.totalCount).toBe(2);
        expect(unique.countByType).toEqual({ AzureSqlVM: 1, AzureSql: 1 });
        expect(unique.resources[0]).toMatchObject({ status: "Connected", issues: { optimization: { hasPaygLicenseIssue: true, hasLowComputeUtilizationIssue: true } } });
        expect(liveOptimizationRows(inventory).map((r) => `${r.target}|${r.area}|${r.check}`)).toEqual(["T1|Licensing|Pay-as-you-go SQL Server license: a license-model opportunity", "T1|Sizing|Low compute use: it may be oversized"]);
        expect([isDown("Unknown"), isDown(undefined), isDown("Connected"), isDown("Stopped")]).toEqual([false, false, false, true]);
    });

    it("reads T2's migration assessment: readiness per Azure SQL target in Learn's words, ready ones named first", () => {
        const [t2] = liveMigrations(liveDataOf(sampleLiveAnswers("2026-10-21T21:00:00.000Z").inventory));
        expect(t2).toMatchObject({ resource: "arcsql01", target: "T2", type: "Arc-enabled SQL Server", enabled: true, dataStatus: "Available", hasResults: true });
        expect(t2.uploadedAt?.toISOString()).toBe("2026-10-21T18:00:00.000Z");
        expect(t2.rows.map((r) => `${r.azureTarget}: ${r.readiness}`)).toEqual(["Azure SQL Managed Instance: Ready", "SQL Server on Azure Virtual Machines: Ready", "Azure SQL Database: Not ready"]);
        expect(migrationSentence(t2)).toBe("Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database.");
        expect(migrationSentence({ ready: [], notReady: ["Azure SQL Database"] })).toBe("Not ready for Azure SQL Database.");
        expect([readinessText("NotReady"), readinessText("Unknown"), readinessText("ReadyWithConditions")]).toEqual(["Not ready", "Unknown", "Ready With Conditions"]);
        const none = liveMigrations({ totalCount: 1, countByType: {}, complete: true, resources: [{ databaseType: "ArcSqlServer", name: "arcsql01", resourceGroup: "rg-x", location: "westus3", status: "Connected", migrationAssessment: { enabled: true, uploadedAt: null, dataStatus: "Unavailable", targets: { azureSqlDatabase: "Unknown" }, readyTargets: [] } }] });
        expect(none[0]).toMatchObject({ hasResults: false, ready: [], uploadedAt: null });
    });

    it("reads T2's assessment saved at deploy: Azure's words, checked field by field, with the recommended tier and size (R924)", () => {
        const deployed = parseDeployedMigration({
            resource: "arcsql01",
            readAt: "2026-11-19T22:10:00Z",
            enabled: true,
            uploadedAt: "2026-11-17T23:05:00Z",
            targets: { azureSqlDatabase: "NotReady", azureSqlManagedInstance: "Ready", azureSqlVirtualMachine: "Ready", "bad key": "Ready", other: "<b>Ready</b>" },
            recommended: { azureSqlManagedInstance: "General Purpose, 4 vCores", azureSqlDatabase: "x".repeat(80) },
            extra: "left out",
        });
        expect(deployed).toEqual({
            resource: "arcsql01",
            readAt: "2026-11-19T22:10:00Z",
            enabled: true,
            uploadedAt: "2026-11-17T23:05:00Z",
            targets: { azureSqlDatabase: "NotReady", azureSqlManagedInstance: "Ready", azureSqlVirtualMachine: "Ready" },
            recommended: { azureSqlManagedInstance: "General Purpose, 4 vCores" },
        });
        if (!deployed) throw new Error("The deploy's shape parses.");
        const t2 = savedMigration(deployed);
        expect(t2).toMatchObject({ resource: "arcsql01", target: "T2", type: "Arc-enabled SQL Server", enabled: true, hasResults: true });
        expect(t2.uploadedAt?.toISOString()).toBe("2026-11-17T23:05:00.000Z");
        expect(t2.rows.map((r) => `${r.azureTarget}: ${r.readiness}${r.recommended ? ` (${r.recommended})` : ""}`)).toEqual([
            "Azure SQL Managed Instance: Ready (General Purpose, 4 vCores)",
            "SQL Server on Azure Virtual Machines: Ready",
            "Azure SQL Database: Not ready",
        ]);
        expect(migrationSentence(t2)).toBe("Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database.");
        expect(savedMigration({ ...deployed, targets: { azureSqlDatabase: "Unknown" } }).hasResults).toBe(false);
        expect([null, "arcsql01", { resource: "arcsql01" }, { resource: "../arcsql01", readAt: "2026-11-19T22:10:00Z" }, { resource: "arcsql01", readAt: "yesterday" }].map(parseDeployedMigration)).toEqual([undefined, undefined, undefined, undefined, undefined]);
    });
});

describe("the live estate when Database Hub refuses the app (R924)", () => {
    const scope = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-dbhub-demo"] };
    // Built at run time so secret scanners never see a token-shaped literal.
    const token = ["eyJ", "x".repeat(24)].join("");
    /** Database Hub answering each route with a status: its body for a refusal is the one it gave the app on 2026-11-19. */
    function dbHub(statusOf: (route: string) => number) {
        const routes: string[] = [];
        const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
            const route = `${init.method ?? "GET"} ${new URL(url).pathname.replace(new URL(DBHUB_BASE).pathname, "")}`;
            routes.push(route);
            const status = statusOf(route);
            if (status === 200) return new Response(JSON.stringify({ items: [], hasMore: false, resources: [] }), { status });
            return new Response(JSON.stringify({ code: "Unauthorized", subCode: 1, message: "Authentication failed for all authenticators", httpStatusCode: status }), { status });
        });
        return { routes, fetchImpl };
    }

    it("says in one plain sentence that Database Hub refused the app, keeps each route's reason for the log, and still calls every route", async () => {
        const { routes, fetchImpl } = dbHub((route) => (route === "GET /auditing/warnings" ? 403 : 401));
        const answers = await Promise.all((["inventory", "health", "security"] as const).map((view) => readEstate(view, scope, token, fetchImpl)));
        for (const answer of answers) {
            expect(answer.unavailable).toBe(LIVE_REFUSED);
            expect(answer.data).toEqual({});
            expect(liveDataOf(answer)).toBeNull();
            expect(answer.errors).toHaveLength(answer.source.length);
            expect(answer.errors.join(" ")).not.toContain(token);
        }
        expect(new Set(routes)).toEqual(new Set(["POST /savedView/resources/list", "POST /health/v2/filtered-summary", "POST /postgreSql/health/v2/summary", "POST /cosmosDb/health/summary", "GET /auth/warnings", "GET /auditing/warnings", "GET /cmk/warnings"]));
        expect(answers[0].errors[0]).toMatch(/^POST \/savedView\/resources\/list: HTTP 401 .*Authentication failed for all authenticators/);
        expect(answers[2].errors).toContainEqual(expect.stringMatching(/^GET \/auditing\/warnings: HTTP 403 /));
        expect(LIVE_REFUSED).not.toMatch(/40[13]|HTTP|token|authenticat/i);
    });

    it("leaves the sentence out when Database Hub didn't answer for another reason, and keeps a partial answer's data with its failed routes by name only", async () => {
        const down = await readEstate("health", scope, token, dbHub(() => 503).fetchImpl);
        expect(down.data).toEqual({});
        expect(down.unavailable).toBeUndefined();
        expect(down.errors[0]).toMatch(/^POST \/[\w/.-]+: HTTP 503 /);
        expect(await readEstate("security", scope, token, dbHub((route) => (route === "GET /auth/warnings" ? 401 : 500)).fetchImpl)).not.toHaveProperty("unavailable");
        expect((await readEstate("inventory", { subscriptionId: "", resourceGroups: [] }, token, dbHub(() => 200).fetchImpl)).unavailable).toBe(LIVE_NO_SCOPE);

        const partial = await readEstate("security", scope, token, dbHub((route) => (route === "GET /auth/warnings" ? 200 : 401)).fetchImpl);
        expect(partial.unavailable).toBeUndefined();
        expect(liveDataOf(partial)?.authentication).toMatchObject({ warningCount: 0, complete: true });
        expect(partial.errors).toHaveLength(2);
        expect(liveRoutes(partial.source, partial.errors)).toEqual({ called: ["GET /auth/warnings", "GET /auditing/warnings", "GET /cmk/warnings"], failed: ["GET /auditing/warnings", "GET /cmk/warnings"] });
        expect(liveRouteLines(partial.source, partial.errors)).toBe("GET /auth/warnings\nGET /auditing/warnings  (didn't answer)\nGET /cmk/warnings  (didn't answer)");
    });
});
