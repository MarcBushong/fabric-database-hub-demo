import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import type { ComponentType } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import EstatePage from "@/pages/EstatePage";
import FindingsPage from "@/pages/FindingsPage";
import IncidentsPage from "@/pages/IncidentsPage";
import ManagePage from "@/pages/ManagePage";
import MissionControlPage from "@/pages/MissionControlPage";
import OverviewPage, { OVERVIEW_PROMPT } from "@/pages/OverviewPage";
import PerformancePage from "@/pages/PerformancePage";
import ReadinessPage from "@/pages/ReadinessPage";
import ReplayPage from "@/pages/ReplayPage";
import ScoreboardPage from "@/pages/ScoreboardPage";
import TrendsPage from "@/pages/TrendsPage";
import type { ViewState } from "@/lib/view-state";
import { FIXTURES, renderWithApp } from "@/test/render";
import { answerKeyInContext } from "@/test/blind";
import { findIncidentsAsk, triageAsk } from "@/rca/entry";
import type { AskContext } from "./contract";

// ADR 0031, decision 7 (the coordinator's call, 2026-11-20): the chat is blind, so no page hands it the demo's answer
// key. Every "Ask Copilot", "Ask why", and Copilot draft passes measured data only, never an answer-key table or a
// measure that reads one (run_dax would refuse to query it again), never a scenario's name or what was injected. The
// drill-downs count too, and so does the postmortem's draft.
const injected = FIXTURES["incident-windows"].find((r) => r.Scenario) ?? FIXTURES["incident-windows"][0];
const CASES: Array<{ name: string; Page: ComponentType; view?: Partial<ViewState>; postmortem?: boolean }> = [
    { name: "Overview", Page: OverviewPage },
    { name: "Estate", Page: EstatePage },
    { name: "Estate, T1", Page: EstatePage, view: { page: "estate", target: "T1" } },
    { name: "Estate, T4 and its replica", Page: EstatePage, view: { page: "estate", target: "T4" } },
    { name: "Estate, T5", Page: EstatePage, view: { page: "estate", target: "T5" } },
    { name: "Performance", Page: PerformancePage },
    { name: "Incidents", Page: IncidentsPage },
    { name: "Incidents, one selected", Page: IncidentsPage, view: { page: "incidents", incident: String(injected.Key) } },
    { name: "Findings", Page: FindingsPage },
    { name: "Readiness", Page: ReadinessPage },
    { name: "Trends", Page: TrendsPage },
    { name: "Manage", Page: ManagePage },
    { name: "Mission Control", Page: MissionControlPage, postmortem: true },
    { name: "Scoreboard", Page: ScoreboardPage, postmortem: true },
    { name: "Session replay", Page: ReplayPage, postmortem: true },
];

/** Every button that hands Copilot a context: "Ask Copilot", "Ask why", the agent cards' "Ask Copilot prompt …", and Overview's own question. */
const ASKS = new RegExp(`^(Ask\\b|${OVERVIEW_PROMPT.replace(/[?.]/g, "\\$&")}$)`);

afterEach(() => cleanup());

/** Renders a page, waits for its data, and clicks every Ask on it (the postmortem's draft too, when asked): the contexts it handed the chat. */
async function askAll(Page: ComponentType, options: { view?: Partial<ViewState>; rca?: boolean; postmortem?: boolean } = {}): Promise<AskContext[]> {
    const { copilot } = renderWithApp(<Page />, { view: options.view, rca: options.rca });
    await waitFor(() => expect(document.querySelectorAll('[aria-busy="true"]').length).toBe(0), { timeout: 4000 });
    for (const button of screen.queryAllByRole("button", { name: ASKS })) {
        if (!(button as HTMLButtonElement).disabled) fireEvent.click(button);
    }
    if (options.postmortem) {
        const write = await screen.findByRole("button", { name: "Write the postmortem" });
        await waitFor(() => expect(write).toBeEnabled());
        fireEvent.click(write);
        fireEvent.click(await screen.findByRole("button", { name: "Draft with Copilot", hidden: true }));
        expect(copilot.ask).toHaveBeenCalledWith(expect.objectContaining({ visualId: "postmortem.plan" }));
    }
    return vi.mocked(copilot.ask).mock.calls.map(([ctx]) => ctx);
}

const leaksIn = (contexts: readonly AskContext[]) => contexts.map((ctx) => ({ visual: ctx.visualId ?? ctx.title ?? "?", leak: answerKeyInContext(ctx) })).filter((x) => x.leak !== null);

describe("every Ask is blind (ADR 0031)", () => {
    for (const { name, Page, view, postmortem } of CASES) {
        it(`${name}: hands the chat measured data only`, async () => {
            expect(leaksIn(await askAll(Page, { view, postmortem }))).toEqual([]);
        });
    }

    it("covers every place the app hands Copilot a context", () => {
        // A new call site needs a case above (or its own blind test) before it joins this list.
        const sources = import.meta.glob(["/src/**/*.{ts,tsx}", "!/src/**/*.test.{ts,tsx}"], { query: "?raw", import: "default", eager: true }) as Record<string, string>;
        const callers = Object.entries(sources)
            .filter(([, text]) => /copilot\.ask\(/.test(text))
            .map(([path]) => path)
            .sort();
        expect(callers).toEqual([
            "/src/components/AgentPrompts.tsx",
            "/src/components/AskWhy.tsx",
            "/src/components/LiveNow.tsx",
            "/src/components/MigrationCard.tsx",
            "/src/components/VisualCard.tsx",
            "/src/mission/PostmortemDialog.tsx",
            "/src/pages/OverviewPage.tsx",
            // The Root cause view's own Ask reads only the capture, which the contract's blind scan checks.
            "/src/pages/RcaPage.tsx",
        ]);
    });
});

// The coordinator's call (2026-11-20): the chat's entry points never drop below the release's. Where decision 7 took an
// Ask away because it had only the answer key to hand over, the card hands the chat a window to investigate instead, once
// the history has the RCA tables (the investigation tools come with them). Without them, the card has no Ask.
const BLIND_ENTRIES: Array<{ name: string; Page: ComponentType; view?: Partial<ViewState>; visuals: string[]; tool: "find_incidents" | "triage_window" }> = [
    { name: "Overview's incidents", Page: OverviewPage, visuals: ["overview.incidents"], tool: "find_incidents" },
    { name: "Overview's sessions", Page: OverviewPage, visuals: ["overview.sessions"], tool: "triage_window" },
    { name: "the Incidents timeline and list", Page: IncidentsPage, visuals: ["incidents.timeline", "incidents.list"], tool: "find_incidents" },
    { name: "a SQL target's incidents", Page: EstatePage, view: { page: "estate", target: "T1" }, visuals: ["estate.target.incidents"], tool: "find_incidents" },
    { name: "Manage's sessions", Page: ManagePage, visuals: ["manage.sessions"], tool: "triage_window" },
    { name: "Replay's moments", Page: ReplayPage, visuals: ["replay.events"], tool: "triage_window" },
    { name: "the scoreboard's faults", Page: ScoreboardPage, visuals: ["scoreboard.faults"], tool: "triage_window" },
];

describe("the chat's entry points come back blind with the RCA tables (ADR 0031)", () => {
    for (const { name, Page, view, visuals, tool } of BLIND_ENTRIES) {
        it(`${name}: a window to investigate with ${tool}, and nothing else; no Ask without the tables`, async () => {
            const withTables = await askAll(Page, { view, rca: true });
            expect(leaksIn(withTables)).toEqual([]);
            for (const visual of visuals) {
                const ctx = withTables.find((c) => c.visualId === visual);
                expect(ctx, visual).toBeDefined();
                expect(ctx!.prompt).toContain(`call ${tool}`);
                // No rows and no DAX: the chat gets the minutes and finds the rest itself.
                expect([ctx!.rows, ctx!.dax]).toEqual([undefined, undefined]);
            }
            cleanup();
            const without = await askAll(Page, { view });
            expect(without.filter((c) => visuals.includes(c.visualId ?? "")).map((c) => c.visualId)).toEqual([]);
        });
    }

    it("hands a session's own minutes, and the history's newest minutes otherwise", () => {
        const from = new Date(Date.UTC(2026, 10, 17, 13, 30));
        const to = new Date(Date.UTC(2026, 10, 17, 15, 0));
        expect(triageAsk({ title: "The session's minutes", from, to })).toEqual({
            title: "The session's minutes",
            specs: [],
            table: null,
            prompt: expect.stringMatching(/^Triage ContosoCare's databases from 2026-11-17 13:30 UTC to 2026-11-17 15:00 UTC: call triage_window for those minutes, then explain/),
        });
        expect(findIncidentsAsk({ targets: ["T1"] })).toMatchObject({ title: "The history's newest 90 minutes on T1", prompt: expect.stringMatching(/^Find the incidents in ContosoCare's databases in the history's newest 90 minutes on T1 from the signals themselves: call find_incidents/) });
    });
});
