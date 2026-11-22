import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createSourceClient } from "@/data/query-client";
import IncidentsPage from "@/pages/IncidentsPage";
import RcaPage from "@/pages/RcaPage";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { LIVE_KEYS, live, liveSources } from "@/rca/testdata/live-rb-2233e0ae";
import { analyzeErrorsResult } from "@/rca/errors";
import { createInvestigationTools } from "@/rca/tools";
import type { EventRow, InvestigationResult } from "@/rca/types";
import { RcaReport } from "@/rca/view/RcaReport";
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

    // The review of eb89acbb: the list said "Nothing abnormal in these minutes" whenever it had no episode, also when its
    // read had stopped short. Here Azure Monitor's pages always come back full, with nothing abnormal in them.
    it("says nothing abnormal only up to where a read stopped short", async () => {
        const client = createSourceClient([
            {
                provenance: "sample",
                answers: () => true,
                fetch: async (spec) => {
                    if (spec.id === "rca-newest-bin") return { rows: [{ Newest: "2026-11-20T18:00:00" }], requestId: "test" };
                    if (spec.title !== "Azure Monitor metrics") return { rows: [], requestId: "test" };
                    const m = /\[Bucket UTC\] >= DATE \( (\d+), (\d+), (\d+) \) \+ TIME \( (\d+), (\d+), (\d+) \)/.exec(spec.dax);
                    const from = m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : 0;
                    // 50 overlapping saves of one metric a minute: a page holds 100 minutes, so the read stops short.
                    const rows = Array.from({ length: spec.rowLimit }, (_, i) => ({ Bucket: new Date(from + Math.floor(i / 50) * 60_000).toISOString().slice(0, 19), TargetKey: "T5", ResourceName: "cosmos01", Metric: "NormalizedRUConsumption", Value: 10, Unit: "Percent", CapturedAt: `2026-11-20T18:${String(i % 50).padStart(2, "0")}:00`, WindowStart: "2026-11-20T00:00:00", WindowEnd: "2026-11-20T23:00:00" }));
                    return { rows, requestId: "test" };
                },
            },
        ]);
        renderWithApp(<RcaPage />, { rca: true, client: Object.assign(client, { ran: [] as string[] }), view: { page: "rca" } });
        expect(await screen.findByText(/^Nothing abnormal up to .+, where the read stopped: the detector found no episode there, and what came after it wasn't read\.$/, {}, { timeout: 10000 })).toBeInTheDocument();
        expect(screen.queryByText(/Nothing abnormal in these minutes/)).toBeNull();
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

// Live, 2026-11-21 (Final tests at 94a17ff7): T4's connection surge showed "The capture holds no cause for these minutes:
// see what wasn't captured below", with nothing below.
describe("the report's root cause, never blank", () => {
    it("explains T4's connection surge, with its recommendations and what isn't captured below it", async () => {
        const tools = createInvestigationTools({ ...liveSources(), timeZone: "UTC", latestDay: live("00:00:00"), latest: live("21:33:15") });
        const incident = (await tools.investigate("explain_incident", { episodeKey: LIVE_KEYS.connections })) as InvestigationResult;
        renderWithApp(<RcaReport incident={incident} errors={null} timeZone="UTC" logs={[]} />);
        expect(screen.getByText(/^T4's client connections reached 35 of the 35 slots clients can use/)).toBeInTheDocument();
        expect(screen.getByRole("heading", { name: "Recommendations" })).toBeInTheDocument();
        expect(screen.getByRole("heading", { name: "Not captured" })).toBeInTheDocument();
        expect(screen.queryByText(/holds no cause/)).toBeNull();
    });

    it("says plainly that nothing holds a cause, and never points below at nothing", () => {
        const incident: InvestigationResult = { tool: "explain_incident", version: 1, window: { fromUtc: "2026-11-21T15:26:41Z", toUtc: "2026-11-21T15:35:11Z" }, targets: ["T4"], episodes: [], findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: [] };
        renderWithApp(<RcaReport incident={incident} errors={null} timeZone="UTC" logs={[]} />);
        expect(screen.getByText("The capture and the telemetry hold no cause for these minutes.")).toBeInTheDocument();
        expect(screen.queryByText(/see what wasn't captured below/)).toBeNull();
        expect(screen.queryByRole("heading", { name: "Not captured" })).toBeNull();
    });
});

// The re-review of 087e096a: the errors table showed each class's count and "first to last" alone, so an hour's 3,000 429s
// read "15:00 to 15:00", 3,000 and the 1,600 it may hold read "3,000", and 100 counted before it read "3,000" too.
describe("the report's errors table", () => {
    const incident: InvestigationResult = { tool: "explain_incident", version: 1, window: { fromUtc: "2026-11-20T14:40:00Z", toUtc: "2026-11-20T15:30:00Z" }, targets: ["T4", "T5"], episodes: [], findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: [] };
    const minute = (hm: string, i: number) => new Date(Date.parse(`2026-11-20T${hm}:00Z`) + i * 60_000);
    const count = (target: "T4" | "T5", at: Date, n: number, interval: number | "unknown"): EventRow => ({ target, at, kind: "error", name: "Azure Monitor", code: target === "T5" ? "429" : "connections_failed", count: n, ...(interval === "unknown" ? { intervalUnknown: true } : { intervalMs: interval }), detail: "Azure Monitor's count" });
    /** The table's rows, each cell's text, as the report shows explain_errors' classes for these counts. */
    const rowsOf = (events: EventRow[]) => {
        const errors: InvestigationResult = { ...incident, tool: "explain_errors", ...analyzeErrorsResult(events) };
        renderWithApp(<RcaReport incident={incident} errors={errors} timeZone="UTC" logs={[]} />);
        const section = screen.getByRole("heading", { name: "Errors in these minutes" }).closest("section")!;
        const rows = within(within(section).getByRole("table")).getAllByRole("row").slice(1);
        const cells = rows.map((r) => within(r).getAllByRole("cell").slice(1, 4).map((c) => c.textContent));
        cleanup();
        return cells;
    };
    const hour = minute("15:00", 0);

    it("shows counts of an interval whose length isn't known apart, from that interval's start with its length unknown", () => {
        expect(rowsOf([count("T4", hour, 7, "unknown")])).toEqual([["7 in an interval of unknown length", "T4", "from 15:00 UTC (15:00 UTC), length unknown"]]);
        const inside = Array.from({ length: 16 }, (_, i) => count("T5", minute("15:14", i), 100, 60_000));
        expect(rowsOf([count("T5", hour, 3000, "unknown"), ...inside])).toEqual([["3,000 in an interval of unknown length, which may hold the 1,600 counted", "T5", "from 15:00 UTC (15:00 UTC), length unknown; counted 15:14 UTC (15:14 UTC) to 15:30 UTC (15:30 UTC)"]]);
        const before = Array.from({ length: 20 }, (_, i) => count("T5", minute("14:40", i), 5, 60_000));
        expect(rowsOf([count("T5", hour, 3000, "unknown"), ...before])).toEqual([["3,100: 100 counted, then 3,000 in an interval of unknown length", "T5", "14:40 UTC (14:40 UTC) to 15:00 UTC (15:00 UTC), then from 15:00 UTC (15:00 UTC), length unknown"]]);
        // Known counts alone, as before.
        expect(rowsOf(before)).toEqual([["100", "T5", "14:40 UTC (14:40 UTC) to 15:00 UTC (15:00 UTC)"]]);
    });
});
