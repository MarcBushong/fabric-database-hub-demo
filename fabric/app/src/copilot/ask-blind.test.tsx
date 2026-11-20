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
import { namesAScenario } from "@/rca/testdata/contract";
import type { ViewState } from "@/lib/view-state";
import { FIXTURES, renderWithApp } from "@/test/render";
import { answerKeyIn } from "./answer-key";
import type { AskContext } from "./contract";
import { ANSWER_KEY_MEASURES } from "./model-guide.generated";

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

/** What in a context would hand the chat the answer key, or null when it's blind. */
export function answerKeyInContext(ctx: AskContext): string | null {
    for (const [field, value] of Object.entries(ctx)) {
        const text = JSON.stringify(value);
        const named = answerKeyIn(text, ANSWER_KEY_MEASURES);
        if (named) return `${named} (in ${field})`;
        const scenarios = namesAScenario(text);
        if (scenarios.length > 0) return `scenario ${scenarios.join(", ")} (in ${field})`;
        if (/\binject/i.test(text)) return `what was injected (in ${field})`;
    }
    return null;
}

afterEach(() => cleanup());

describe("every Ask is blind (ADR 0031)", () => {
    for (const { name, Page, view, postmortem } of CASES) {
        it(`${name}: hands the chat measured data only`, async () => {
            const { copilot } = renderWithApp(<Page />, { view });
            await waitFor(() => expect(document.querySelectorAll('[aria-busy="true"]').length).toBe(0), { timeout: 4000 });
            for (const button of screen.queryAllByRole("button", { name: ASKS })) {
                if (!(button as HTMLButtonElement).disabled) fireEvent.click(button);
            }
            if (postmortem) {
                const write = await screen.findByRole("button", { name: "Write the postmortem" });
                await waitFor(() => expect(write).toBeEnabled());
                fireEvent.click(write);
                fireEvent.click(await screen.findByRole("button", { name: "Draft with Copilot", hidden: true }));
                expect(copilot.ask).toHaveBeenCalledWith(expect.objectContaining({ visualId: "postmortem.plan" }));
            }
            const leaks = vi
                .mocked(copilot.ask)
                .mock.calls.map(([ctx]) => ({ visual: ctx.visualId ?? ctx.title ?? "?", leak: answerKeyInContext(ctx) }))
                .filter((x) => x.leak !== null);
            expect(leaks).toEqual([]);
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
