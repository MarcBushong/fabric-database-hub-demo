import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createSourceClient } from "@/data/query-client";
import IncidentsPage from "@/pages/IncidentsPage";
import RcaPage from "@/pages/RcaPage";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { answerKeyInContext } from "@/test/blind";
import { renderWithApp, type FakeQueryClient } from "@/test/render";
import { STAGE_TOKENS } from "@/theme/stage";

// The Root cause view (ADR 0031, step 1.6) on the contract's fixtures, as the preview shows it: T1's blocking chain from
// the fixture, and T4's from a real capture on a local PostgreSQL primary and standby.

/** The preview's own source: the RCA tables from the fixtures, the rest from the sample history. */
function sampleClient(): FakeQueryClient {
    const client = createSourceClient([{ provenance: "sample", answers: () => true, fetch: async (spec) => ({ rows: sampleRcaRows(spec) ?? sampleRows(spec), requestId: "sample" }) }]);
    return Object.assign(client, { ran: [] as string[] });
}

const SLOW = 20000;

afterEach(() => cleanup());

describe("the Root cause view (ADR 0031)", () => {
    it(
        "shows T1's blocking chain head blocker first, with who ran what, the recommendations, and what to do next",
        async () => {
            const { copilot } = renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca" } });
            const trees = await screen.findAllByRole("tree", {}, { timeout: 10000 });
            const shapes = trees.map((tree) => {
                const items = within(tree).getAllByRole("treeitem");
                return { label: tree.getAttribute("aria-label") ?? "", items, levels: items.map((i) => Number(i.getAttribute("aria-level"))) };
            });
            // One tree per formation of the chain, each on T1 and head blocker first.
            for (const s of shapes) {
                expect(s.label).toMatch(/^The blocking chain on T1 at /);
                expect(s.levels[0]).toBe(1);
                expect(s.items[0].textContent).toMatch(/^Head blocker · session \d+/);
            }
            // The fixture's chain at its peak: the acquire procedure at its head, 2 branches, 4 levels deep.
            const peak = shapes.find((s) => Math.max(...s.levels) === 4 && s.levels.filter((l) => l === 2).length === 2);
            expect(peak, JSON.stringify(shapes.map((s) => s.levels))).toBeDefined();
            expect(peak!.items[0].textContent).toContain("usp_scenario_chain_acquire");
            // And the escalation's: its table lock at the head.
            expect(shapes.some((s) => /usp_scenario_chain_escalate/.test(s.items[0].textContent ?? "") && /Holds X/.test(s.items[0].textContent ?? ""))).toBe(true);
            for (const name of ["Root cause", "The blocking chain, head blocker first", "Timeline", "Errors in these minutes", "Recommendations", "Next steps"]) {
                expect(screen.getByRole("heading", { name }), name).toBeInTheDocument();
            }
            // Every recommendation cites Microsoft Learn.
            const recs = screen.getByRole("heading", { name: "Recommendations" }).closest("section")!;
            const links = within(recs).getAllByRole("link");
            expect(links.length).toBeGreaterThan(0);
            for (const link of links) expect(link.getAttribute("href")).toMatch(/^https:\/\/learn\.microsoft\.com\//);
            // "Explain this incident" hands the chat the blind episode's key, never the answer key.
            fireEvent.click(screen.getByRole("button", { name: "Explain this incident" }));
            const ctx = vi.mocked(copilot.ask).mock.calls[0][0];
            expect(ctx).toMatchObject({ page: "rca", visualId: "rca.incident" });
            expect(ctx.prompt).toMatch(/^Explain the incident T1-[a-z_]+-\d{8}T\d{6}Z: call explain_incident/);
            expect(answerKeyInContext(ctx)).toBeNull();
            // It never links back to the pages that show the answer key.
            expect(screen.queryByRole("button", { name: /^(Incidents|Scoreboard|Session replay)$/ })).toBeNull();
        },
        SLOW,
    );

    it("says no RCA capture is recorded when the model has no RCA tables, and shows nothing else", async () => {
        renderWithApp(<RcaPage />, { rca: false, client: sampleClient(), view: { page: "rca" } });
        expect(await screen.findByText("No RCA capture is recorded yet")).toBeInTheDocument();
        await waitFor(() => expect(screen.queryByRole("tree")).toBeNull());
        expect(screen.getByRole("button", { name: "Explain this incident" })).toBeDisabled();
    });

    it("colors with the stage's tokens only, each defined in every theme, and marks the current incident with the system's colors under forced colors (F22)", () => {
        const css = readFileSync(join(process.cwd(), "src", "rca", "view", "rca.css"), "utf8");
        const block = /@media \(forced-colors: active\) \{([\s\S]*?)\n\}/;
        const outside = css.replace(block, "");
        // No literal color outside forced colors: light, dark, and high contrast each keep their contrast.
        expect(outside.match(/#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\(/gi)).toBeNull();
        const used = [...new Set([...outside.matchAll(/var\((--[a-z0-9-]+)\)/g)].map((m) => m[1]))];
        expect(used.length).toBeGreaterThan(5);
        for (const id of ["light", "dark", "contrast"] as const) {
            const tokens: Record<string, string> = { ...STAGE_TOKENS[id].surfaces, ...STAGE_TOKENS[id].text, ...STAGE_TOKENS[id].graphic, ...STAGE_TOKENS[id].decor };
            for (const token of used) expect(tokens[token], `${id} ${token}`).toBeTruthy();
        }
        const forced = css.match(block)?.[1] ?? "";
        const rule = (selector: string) => forced.match(new RegExp(`^\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{([^}]*)\\}`, "m"))?.[1] ?? "";
        const value = (body: string, property: string) => body.match(new RegExp(`(?:^|[;\\s])${property}:\\s*([^;]+);`))?.[1]?.trim() ?? "missing";
        const current = rule('.rca-episode[aria-current="true"]');
        expect(["background", "color", "forced-color-adjust", "box-shadow", "outline-color"].map((p) => value(current, p))).toEqual(["Highlight", "HighlightText", "none", "none", "CanvasText"]);
        // Its muted lines too: with nothing forced, the stage's grey would sit on the selection color.
        expect(value(rule('.rca-episode[aria-current="true"] .rca-muted'), "color")).toBe("HighlightText");
        // The head blocker keeps a mark that forced colors don't take away: a wider border.
        expect(value(rule(".rca-node.head"), "border-inline-start-width")).toBe("4px");
    });
});

describe("links into the Root cause view, one way (ADR 0031)", () => {
    it(
        "links the selected incident's target and minutes, never its name, and only with the RCA tables",
        async () => {
            const { navigate } = renderWithApp(<IncidentsPage />, { rca: true });
            fireEvent.click(await screen.findByRole("button", { name: "Root cause" }, { timeout: 8000 }));
            expect(navigate).toHaveBeenCalledWith("rca", { incident: expect.stringMatching(/^T[1-3]\.\d{8}T\d{6}Z\.\d{8}T\d{6}Z$/) });
            cleanup();
            renderWithApp(<IncidentsPage />);
            await screen.findByRole("button", { name: "Ask the agent" }, { timeout: 8000 });
            expect(screen.queryByRole("button", { name: "Root cause" })).toBeNull();
        },
        SLOW,
    );
});
