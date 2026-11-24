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
import { episodeOf, ERRORS_AROUND_MINUTES } from "@/rca/view/facts";
import { answerKeyInContext } from "@/test/blind";
import { renderWithApp, type FakeQueryClient } from "@/test/render";
import { STAGE_TOKENS } from "@/theme/stage";
import { APP_TOKENS } from "@/theme/fluent";
import type { RcaFilters } from "@/rca/facet-ids";

// The Root cause view (ADR 0031, step 1.6) on the contract's fixtures, as the preview shows it: T1's blocking chain from
// the fixture, and T4's from a real capture on a local PostgreSQL primary and standby.

/** The preview's own source: the RCA tables from the fixtures, the rest from the sample history. */
function sampleClient(): FakeQueryClient {
    const client = createSourceClient([{ provenance: "sample", answers: () => true, fetch: async (spec) => ({ rows: sampleRcaRows(spec) ?? sampleRows(spec), requestId: "sample" }) }]);
    return Object.assign(client, { ran: [] as string[] });
}

// The page's tests mount the whole Root cause page, its facet bar's Fluent controls among them (as mission.test.tsx's do).
const SLOW = 30000;

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

    it("colors with theme tokens only, the stage's and the app's, each defined in every theme, and marks the current incident with the system's colors under forced colors (F22)", () => {
        const css = readFileSync(join(process.cwd(), "src", "rca", "view", "rca.css"), "utf8");
        const block = /@media \(forced-colors: active\) \{([\s\S]*?)\n\}/;
        const outside = css.replace(block, "");
        // No literal color outside forced colors: light, dark, and high contrast each keep their contrast.
        expect(outside.match(/#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\(/gi)).toBeNull();
        const used = [...new Set([...outside.matchAll(/var\((--[a-z0-9-]+)\)/g)].map((m) => m[1]))];
        expect(used.length).toBeGreaterThan(5);
        // The stage's own, and the app's status and target tokens, which the stage sets beside them (stageStyle).
        for (const id of ["light", "dark", "contrast"] as const) {
            const tokens: Record<string, string> = { ...STAGE_TOKENS[id].surfaces, ...STAGE_TOKENS[id].text, ...STAGE_TOKENS[id].graphic, ...STAGE_TOKENS[id].decor, ...APP_TOKENS[id].text, ...APP_TOKENS[id].graphic };
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

// The owner's feedback (2026-11-23): the list read as one big list. Facets with counts, grouping, sorting, and the filters in
// the address, so a view can be shared; on the preview's sample session, 49 incidents.
describe("the organized Root cause list", () => {
    const facets = async () => screen.findByRole("region", { name: "Filter the incidents" }, { timeout: 10000 });
    const DEFAULTS: RcaFilters = { categories: [], severities: [], targets: [], window: { newest: 90 }, group: "category", sort: "severity" };

    it(
        "counts each facet's values, names each server and database, and groups the incidents by category with each one's severity",
        async () => {
            renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca" } });
            const bar = await facets();
            const counts = (name: string) => within(within(bar).getByRole("group", { name })).getAllByRole("button").map((b) => b.getAttribute("aria-label"));
            expect(counts("Severity")).toEqual(["High: 31 incidents", "Medium: 15 incidents", "Low: 3 incidents"]);
            expect(counts("Category")).toEqual(["Blocking: 7 incidents", "Deadlocks: 1 incident", "CPU: 14 incidents", "Waits: 7 incidents", "Errors: 0 incidents", "Connections: 0 incidents", "Replica lag: 1 incident", "Throttling: 13 incidents", "IO: 6 incidents"]);
            // T1 to T3 as Database Hub's telemetry names them, T4, its replica, and T5 as Azure Monitor's do.
            await waitFor(() => expect(counts("Server and database")[0]).toBe("T1 · sqlvm01 / ContosoCare: 9 incidents"));
            expect(counts("Server and database")).toEqual([
                "T1 · sqlvm01 / ContosoCare: 9 incidents",
                "T2 · arcsql01 / ContosoCare: 13 incidents",
                "T3 · azuresql01-sample / ContosoCare: 9 incidents",
                "T4 · pgflex01-sample: 5 incidents",
                "T4-replica · pgreplica01-sample: 1 incident",
                "T5 · cosmos01-sample: 12 incidents",
            ]);
            expect(within(bar).getByRole("button", { name: "Errors: 0 incidents" })).toBeDisabled();
            expect(within(bar).getByText("49 incidents.")).toBeInTheDocument();
            const list = screen.getByRole("complementary", { name: "Incidents the detector found" });
            expect(within(list).getAllByRole("heading", { level: 3 }).map((h) => h.textContent)).toEqual(["Blocking7", "Deadlocks1", "CPU14", "Waits7", "Replica lag1", "Throttling13", "IO6"]);
            // Most severe first in each group, the capture's chain first among them, and each with its severity's reason.
            const first = within(list).getAllByRole("button")[0];
            expect(first).toHaveAttribute("aria-current", "true");
            expect(first.textContent).toMatch(/^HighT1: blocked processes.*in the RCA capture.*High: peak 7 processes, four times its level or more .*, there for 6\.8 minutes in all; over its level for 9\.1 minutes, 5 or more; high confidence\.$/);
            // The report says the same, where a keyboard reaches it too.
            expect(await screen.findByText(/^Severity High: peak 7 processes, /, {}, { timeout: 10000 })).toBeInTheDocument();
        },
        SLOW,
    );

    it(
        "writes the filters to the address, keeps an incident the list still shows, and starts over in other minutes",
        async () => {
            const { setView } = renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca", incident: "T1-blocking-20261117T140230Z" } });
            const bar = await facets();
            fireEvent.click(within(bar).getByRole("button", { name: "High: 31 incidents" }));
            expect(setView).toHaveBeenLastCalledWith({ rcaFilters: { ...DEFAULTS, severities: ["high"] } });
            fireEvent.click(within(within(bar).getByRole("group", { name: "Group by" })).getByRole("button", { name: "Server" }));
            expect(setView).toHaveBeenLastCalledWith({ rcaFilters: { ...DEFAULTS, group: "target" } });
            // A filter that leaves the incident out, or other minutes, start over with the list's first incident.
            fireEvent.click(within(bar).getByRole("button", { name: "Low: 3 incidents" }));
            expect(setView).toHaveBeenLastCalledWith({ rcaFilters: { ...DEFAULTS, severities: ["low"] }, incident: null });
            fireEvent.change(within(bar).getByRole("combobox", { name: "Minutes" }), { target: { value: "360" } });
            expect(setView).toHaveBeenLastCalledWith({ rcaFilters: { ...DEFAULTS, window: { newest: 360 } }, incident: null });
        },
        SLOW,
    );

    it(
        "shows only what the filters let through, grouped by server, and says how many of all",
        async () => {
            renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca", rcaFilters: { ...DEFAULTS, severities: ["high"], targets: ["T1", "T3"], group: "target" } } });
            const bar = await facets();
            const shown = Number(/^Showing (\d+) of 49 incidents\.$/.exec(within(bar).getByText(/^Showing \d+ of 49 incidents\.$/).textContent ?? "")?.[1]);
            expect(within(bar).getByRole("button", { name: `High: ${shown} incidents` })).toHaveAttribute("aria-pressed", "true");
            const list = screen.getByRole("complementary", { name: "Incidents the detector found" });
            await waitFor(() => expect(within(list).getAllByRole("heading", { level: 3 }).map((h) => h.textContent?.replace(/\d+$/, ""))).toEqual(["T1 · sqlvm01 / ContosoCare", "T3 · azuresql01-sample / ContosoCare"]));
            const items = within(list).getAllByRole("button");
            expect(items).toHaveLength(shown);
            for (const item of items) expect(item.textContent).toMatch(/^HighT[13]: /);
        },
        SLOW,
    );

    it(
        "reads an older link's window key as its target and minutes, and says when no incident matches, with a way to clear the filters",
        async () => {
            const { setView } = renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca", incident: "T1.20261117T140000Z.20261117T143000Z" } });
            const bar = await facets();
            expect(within(bar).getByRole("button", { name: /^T1 · .*incidents?$/ })).toHaveAttribute("aria-pressed", "true");
            expect((within(bar).getByRole("combobox", { name: "Minutes" }) as HTMLSelectElement).value).toBe("custom");
            cleanup();
            // A window longer than the page reads, an older link's too, is the newest minutes' (the review of 90e9d914).
            renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca", incident: "T1.20261101T000000Z.20261123T000000Z" } });
            const long = await facets();
            expect((within(long).getByRole("combobox", { name: "Minutes" }) as HTMLSelectElement).value).toBe("90");
            expect(within(long).getByRole("button", { name: /^T1 · .*incidents?$/ })).toHaveAttribute("aria-pressed", "true");
            cleanup();
            const cleared = renderWithApp(<RcaPage />, { rca: true, client: sampleClient(), view: { page: "rca", rcaFilters: { ...DEFAULTS, categories: ["connections"] } } });
            expect(await screen.findByText(/^No incident in these minutes matches the filters\./, {}, { timeout: 10000 })).toBeInTheDocument();
            fireEvent.click(screen.getAllByRole("button", { name: "Clear the filters" })[0]);
            expect(cleared.setView).toHaveBeenLastCalledWith({ rcaFilters: DEFAULTS, incident: null });
            expect(setView).not.toHaveBeenCalled();
        },
        SLOW,
    );
});

describe("links into the Root cause view, one way (ADR 0031)", () => {
    it(
        "links the selected incident's target and minutes as the page's filters, never its name or its category, and only with the RCA tables",
        async () => {
            const { navigate } = renderWithApp(<IncidentsPage />, { rca: true });
            fireEvent.click(await screen.findByRole("button", { name: "Root cause" }, { timeout: 8000 }));
            expect(navigate).toHaveBeenCalledWith("rca", {
                rcaFilters: { categories: [], severities: [], targets: [expect.stringMatching(/^T[1-3]$/)], window: { from: expect.any(Date), to: expect.any(Date) }, group: "category", sort: "severity" },
            });
            const { window } = vi.mocked(navigate).mock.calls[0][1]!.rcaFilters!;
            expect("from" in window && window.to > window.from).toBe(true);
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

    // Final tests' check of ddebd4c3 (F2): a coverage row marked not captured says "no RCA evidence for", and the errors'
    // minutes said it again, for a span after the storm had ended. One per target, in either form.
    it("says once per target that it wasn't captured, in either form", () => {
        const incident: InvestigationResult = { tool: "explain_incident", version: 1, window: { fromUtc: "2026-11-21T15:46:00Z", toUtc: "2026-11-21T15:55:00Z" }, targets: ["T5"], episodes: [], findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: ["T5: no RCA evidence for 15:27:09-15:55:03 UTC"] };
        const errors: InvestigationResult = { ...incident, tool: "explain_errors", notCaptured: ["T5: no RCA evidence for 15:55:03-16:24:58 UTC", "T5: no RCA capture recorded for 15:46:00-15:56:00 UTC; only the telemetry (Telemetry Snapshots) is known"] };
        renderWithApp(<RcaReport incident={incident} errors={errors} timeZone="UTC" logs={[]} />);
        const gaps = screen.getByRole("region", { name: "Not captured" });
        expect(within(gaps).getAllByRole("listitem").map((li) => li.textContent)).toEqual(["T5: no RCA evidence for 15:27:09-15:55:03 UTC"]);
    });

    // Final tests' check of ddebd4c3 (F5): one instant reads "at" it, so the view counts that form as a target's note too.
    it("counts a note of one instant, 'at' it, as its target's, the incident's or the errors'", () => {
        const at = (lines: string[], extra: string[]) => {
            const incident: InvestigationResult = { tool: "explain_incident", version: 1, window: { fromUtc: "2026-11-21T16:57:00Z", toUtc: "2026-11-21T16:57:00Z" }, targets: ["T4-replica"], episodes: [], findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: lines };
            renderWithApp(<RcaReport incident={incident} errors={{ ...incident, tool: "explain_errors", notCaptured: extra }} timeZone="UTC" logs={[]} />);
            const shown = within(screen.getByRole("region", { name: "Not captured" })).getAllByRole("listitem").map((li) => li.textContent);
            cleanup();
            return shown;
        };
        const instant = "T4-replica: no RCA capture recorded at 16:57:00 UTC; only the telemetry (Telemetry Snapshots) is known";
        const span = "T4-replica: no RCA capture recorded for 16:55:00-16:59:00 UTC; only the telemetry (Telemetry Snapshots) is known";
        expect(at([instant], [span])).toEqual([instant]);
        expect(at([span], [instant, "T4-replica: no RCA evidence at 16:59:00 UTC"])).toEqual([span]);
        // The review of 921d3097: a span across two UTC days reads "from" one date and time "to" the other, a note all the same.
        const days = "T4-replica: no RCA capture recorded from 2026-11-20 23:55:00 to 2026-11-21 00:05:00 UTC; only the telemetry (Telemetry Snapshots) is known";
        expect(at([days], [span, "T4-replica: no RCA evidence from 2026-11-20 23:50:00 to 2026-11-21 00:10:00 UTC"])).toEqual([days]);
        expect(at([span], [days])).toEqual([span]);
    });

    // The re-review of ab1d2d41: an incident across two coverage rows not captured has a line for each, and the view kept
    // only the first, so T5's storm from 12:15 read as not captured only up to 12:25:52.
    it("keeps each of an incident's own lines, and leaves out the errors' for a target it notes", async () => {
        const tools = createInvestigationTools({ ...liveSources(), timeZone: "UTC", latestDay: live("00:00:00"), latest: live("21:33:15") });
        const incident = (await tools.investigate("explain_incident", { episodeKey: "T5-ru-20261121T121500Z" })) as InvestigationResult;
        const errors = (await tools.investigate("explain_errors", { from: incident.window.fromUtc, to: incident.window.toUtc, targets: ["T5"] })) as InvestigationResult;
        renderWithApp(<RcaReport incident={incident} errors={errors} timeZone="UTC" logs={[]} />);
        const gaps = within(screen.getByRole("region", { name: "Not captured" })).getAllByRole("listitem").map((li) => li.textContent ?? "");
        expect(gaps.filter((s) => s.startsWith("T5: no RCA"))).toEqual(["T5: no RCA evidence for 12:09:10-12:25:52 UTC", "T5: no RCA evidence for 12:25:52-12:47:21 UTC"]);
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

    // Final tests' check of ddebd4c3 (F6): T5's storm from 15:31 said 13,222 throttled requests, for its 9 intervals at 100 %,
    // and its errors table 14,593, read as the page reads them, with nothing on the page to say why.
    it("says which minutes it counts, the incident's and 2 on either side, beside a root cause that counts only the intervals it names", async () => {
        const tools = createInvestigationTools({ ...liveSources(), timeZone: "UTC", latestDay: live("00:00:00"), latest: live("21:33:15") });
        const storm = (await tools.investigate("explain_incident", { episodeKey: LIVE_KEYS.ru })) as InvestigationResult;
        const facts = episodeOf(storm)!;
        const around = (at: string, sign: number) => new Date(Date.parse(at) + sign * ERRORS_AROUND_MINUTES * 60_000).toISOString();
        const errors = (await tools.investigate("explain_errors", { from: around(facts.start, -1), to: around(facts.end!, 1), targets: ["T5"] })) as InvestigationResult;
        renderWithApp(<RcaReport incident={storm} errors={errors} timeZone="UTC" logs={[]} />);
        const section = screen.getByRole("heading", { name: "Errors in these minutes" }).closest("section")!;
        expect(within(section).getByText("Recorded from 15:29 UTC (15:29 UTC) to 15:44 UTC (15:44 UTC), the incident's minutes and 2 on either side. A count in the root cause covers only the intervals it names, so it can be lower.")).toBeInTheDocument();
        expect(within(within(section).getByRole("table")).getAllByRole("row")[1].textContent).toContain("14,593");
        expect(storm.rootCause?.statement).toContain("13222 of them throttled");
    });

    it("shows counts of an interval whose length isn't known apart, from that interval's start with its length unknown", () => {
        expect(rowsOf([count("T4", hour, 7, "unknown")])).toEqual([["7 in an interval of unknown length", "T4", "from 15:00 UTC (15:00 UTC), length unknown"]]);
        const inside = Array.from({ length: 16 }, (_, i) => count("T5", minute("15:14", i), 100, 60_000));
        expect(rowsOf([count("T5", hour, 3000, "unknown"), ...inside])).toEqual([["3,000 in an interval of unknown length, which may hold the 1,600 counted", "T5", "from 15:00 UTC (15:00 UTC), length unknown; counted 15:14 UTC (15:14 UTC) to 15:30 UTC (15:30 UTC)"]]);
        const before = Array.from({ length: 20 }, (_, i) => count("T5", minute("14:40", i), 5, 60_000));
        expect(rowsOf([count("T5", hour, 3000, "unknown"), ...before])).toEqual([["3,100: 100 counted, then 3,000 in an interval of unknown length", "T5", "14:40 UTC (14:40 UTC) to 15:00 UTC (15:00 UTC), then from 15:00 UTC (15:00 UTC), length unknown"]]);
        // Known counts alone, as before.
        expect(rowsOf(before)).toEqual([["100", "T5", "14:40 UTC (14:40 UTC) to 15:00 UTC (15:00 UTC)"]]);
    });

    // The re-review of 8b43102e: two of three known 5-minute counts end before an interval of unknown length from 15:00, but
    // the table said it "may hold the 3 counted", where the tools say "some of", and the class counted 30, not those 2 more.
    it("says an interval of unknown length may hold some of the known counts when some end before it, and counts those", () => {
        const known = ["14:50", "14:55", "15:05"].map((hm) => count("T4", minute(hm, 0), 1, 300_000));
        const events = [count("T4", hour, 30, "unknown"), ...known];
        expect(rowsOf(events)).toEqual([["30 in an interval of unknown length, which may hold some of the 3 counted", "T4", "from 15:00 UTC (15:00 UTC), length unknown; counted 14:50 UTC (14:50 UTC) to 15:10 UTC (15:10 UTC)"]]);
        expect((analyzeErrorsResult(events).details!.classes as Array<{ count: number }>)[0].count).toBe(32);
        // One known instant reads as one.
        const instant = [count("T4", hour, 30, "unknown"), count("T4", minute("15:20", 0), 2, 0)];
        expect(rowsOf(instant)[0][2]).toBe("from 15:00 UTC (15:00 UTC), length unknown; counted at 15:20 UTC (15:20 UTC)");
    });
});
