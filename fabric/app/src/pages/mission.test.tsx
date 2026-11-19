// Wave 1's pages (ADR 0030) on the preview's sample session: Mission Control's map and numbers, the business lens, the
// postmortem, the scoreboard, the replay's moment, the kiosk's keys, and the map without motion.

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import type { QuerySpec } from "@/data/queries";
import type { QueryResult } from "@/data/query-client";
import { KIOSK_START, kioskReducer, SCENE_SECONDS } from "@/mission/kiosk";
import { ServiceMap, type MapNode } from "@/mission/ServiceMap";
import { sampleRows } from "@/preview/sample-data";
import { SESSION_KEY } from "@/preview/sample-session";
import { renderWithApp, type FakeQueryClient } from "@/test/render";
import KioskPage from "./KioskPage";
import MissionControlPage from "./MissionControlPage";
import ReplayPage from "./ReplayPage";
import ScoreboardPage from "./ScoreboardPage";

const SLOW = 30000;

/** The preview's sample, with its latest session, answering every query by its ID and parameters. */
function sampleClient(): FakeQueryClient {
    const ran: string[] = [];
    return {
        ran,
        peek: () => undefined,
        clear: () => undefined,
        run: vi.fn(async (spec: QuerySpec): Promise<QueryResult> => {
            ran.push(spec.id);
            return { spec, columns: spec.columns, rows: sampleRows(spec), requestId: "sample", fetchedAt: new Date(Date.UTC(2026, 10, 17, 21)), provenance: "sample" };
        }),
    };
}

describe("Mission Control", () => {
    it(
        "puts ContosoCare's services on a map with their health, the latest session's plan as recorded at its end, and its numbers",
        async () => {
            const { navigate, container } = renderWithApp(<MissionControlPage />, { client: sampleClient() });
            expect(await screen.findByRole("heading", { level: 1, name: "Session 7f3a9c21 · 17 Nov 13:30–15:00 UTC" })).toBeInTheDocument();
            expect(screen.getByText(/as recorded at its end, as of .+\. For the live view, open Database Hub\./)).toBeInTheDocument();
            const numbers = await screen.findByRole("complementary", { name: "The session in numbers" });
            await waitFor(() => expect(within(numbers).getByText("34 of 35")).toBeInTheDocument());
            expect(within(numbers).getByText("35")).toBeInTheDocument();
            expect(within(numbers).getByText("84 % → 22 %")).toBeInTheDocument();
            expect(within(numbers).getByText(/% throttled$/)).toBeInTheDocument();
            const scheduling = screen.getByRole("button", { name: /^Scheduling, T3 Azure SQL Database: / });
            expect(screen.getByRole("button", { name: /^Patient events, T5 Azure Cosmos DB: / })).toBeInTheDocument();
            // The viewer asked for reduced motion: no pulse and no shockwave, the words still say everything.
            expect(container.querySelector(".mc-pulse, .mc-shock")).toBeNull();
            fireEvent.click(scheduling);
            expect(navigate).toHaveBeenCalledWith("estate", { target: "T3" });
        },
        SLOW,
    );

    it(
        "switches to the business lens: what each service felt, next to the measured signal it comes from",
        async () => {
            renderWithApp(<MissionControlPage />, { client: sampleClient() });
            await screen.findByRole("heading", { level: 1, name: /^Session 7f3a9c21/ });
            fireEvent.click(screen.getByRole("button", { name: "Business impact" }));
            const events = await screen.findByRole("button", { name: /^Patient events, T5 Azure Cosmos DB: Warning\. \d+ % of requests throttled for \d+ min \(normalized RU 100\.0 %, 429s on [\d,]+ of [\d,]+ requests\)\.$/ });
            expect(events).toBeInTheDocument();
            expect(screen.getByRole("button", { name: /^Scheduling, T3 Azure SQL Database: .+Under heavy load for \d+ min \(CPU peak [\d.]+ %, [\d.]+ times its baseline\)\.$/ })).toBeInTheDocument();
            expect(screen.getAllByText(/^Reports' DR copy$/).length).toBeGreaterThan(0);
        },
        SLOW,
    );

    it(
        "writes the session's postmortem from the data alone, downloads it as Markdown, and drafts it with the viewer's own Copilot",
        async () => {
            URL.createObjectURL = vi.fn(() => "blob:postmortem");
            URL.revokeObjectURL = vi.fn();
            const { copilot, notify } = renderWithApp(<MissionControlPage />, { client: sampleClient() });
            const write = await screen.findByRole("button", { name: "Write the postmortem" });
            await waitFor(() => expect(write).toBeEnabled());
            fireEvent.click(write);
            const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
            // jsdom keeps no focus in the dialog, so Fluent's modal may mark it hidden after it opens; a browser keeps focus in it.
            // Its own Markdown, rendered: the sections in order, each a heading.
            expect([...dialog.querySelectorAll(".pm-view h4")].map((h) => h.textContent)).toEqual(["Summary", "Timeline (UTC)", "Impact on ContosoCare", "Cause", "Response", "Times to detect and recover", "Follow-ups", "How this was measured", "Queries"]);
            expect(within(dialog).getByText(/^The Database Agent loop on T3: the plan regressed at 14:03 UTC, and the run forced the last good plan at 14:26 UTC/)).toBeInTheDocument();
            fireEvent.click(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true }));
            expect(notify).toHaveBeenCalledWith(expect.stringMatching(/^Downloaded contosocare-postmortem-7f3a9c21-\d{8}T\d{4}Z\.md$/), "success");
            fireEvent.click(within(dialog).getByRole("button", { name: "Draft with Copilot", hidden: true }));
            expect(copilot.ask).toHaveBeenCalledWith(expect.objectContaining({ page: "scoreboard", visualId: "postmortem.plan", totalRows: expect.any(Number) }));
            expect(vi.mocked(copilot.ask).mock.calls[0][0].prompt).toMatch(/with exactly these sections: Summary, Timeline \(UTC\), Impact on ContosoCare, Cause, Response, Times to detect and recover, Follow-ups\./);
        },
        SLOW,
    );
});

describe("the service map", () => {
    const nodes: MapNode[] = [{ target: "T3", status: "Warning", metric: "CPU peak 97.5 %", impact: null, events: 2 }];

    it("pulses and sends a shockwave only with motion, and says each node's status in a word", () => {
        const { container, rerender } = render(<ServiceMap nodes={nodes} lens="technical" motion={false} shockKeys={{ T3: "fault" }} title="Services" />);
        expect(container.querySelector(".mc-pulse")).toBeNull();
        expect(container.querySelector(".mc-shock")).toBeNull();
        expect(screen.getByRole("img", { name: "Scheduling, T3 Azure SQL Database: Warning. CPU peak 97.5 %." })).toBeInTheDocument();
        rerender(<ServiceMap nodes={nodes} lens="technical" motion shockKeys={{ T3: "fault" }} title="Services" />);
        expect(container.querySelector(".mc-pulse")).not.toBeNull();
        expect(container.querySelector(".mc-shock")).not.toBeNull();
        rerender(<ServiceMap nodes={nodes} lens="business" motion={false} title="Services" />);
        expect(screen.getByRole("img", { name: "Scheduling, T3 Azure SQL Database: Warning. No measured impact." })).toBeInTheDocument();
    });
});

describe("Scoreboard", () => {
    it(
        "lists every injected fault with when its signal showed, the response, and the recovery, and the one it didn't catch",
        async () => {
            renderWithApp(<ScoreboardPage />, { client: sampleClient() });
            expect(await screen.findByRole("heading", { level: 1, name: "Did we catch it? 34 of 35" }, { timeout: 15000 })).toBeInTheDocument();
            const table = screen.getByRole("table", { name: "Every injected fault" });
            const rows = within(table).getAllByRole("row").slice(1);
            expect(rows).toHaveLength(35);
            const missed = rows.filter((r) => /Warning/.test(r.textContent ?? ""));
            expect(missed).toHaveLength(1);
            expect(missed[0].textContent).toMatch(/14:48.*IO pressure/);
            const agent = rows.find((r) => /Plan regression/.test(r.textContent ?? "") && /14:26/.test(r.textContent ?? ""));
            expect(agent?.textContent).toMatch(/14:03.*14:03.*14:26.*14:27.*24 min/);
            expect(screen.getByRole("heading", { name: "Times per engine" })).toBeInTheDocument();
            expect(screen.getByRole("heading", { name: "Times per fault type" })).toBeInTheDocument();
            expect(screen.getByRole("heading", { name: "T4 and T5: what their metrics show" })).toBeInTheDocument();
            fireEvent.click(screen.getByRole("button", { name: "Business impact" }));
            expect(within(screen.getByRole("table", { name: "Every injected fault" })).getByRole("columnheader", { name: /Business impact \(measured\)/ })).toBeInTheDocument();
        },
        SLOW,
    );
});

describe("Session replay", () => {
    it(
        "drives the map and the ribbon from one scrubber, counts down to the next injection, and keeps the moment in the address",
        async () => {
            const { setView } = renderWithApp(<ReplayPage />, { client: sampleClient(), view: { page: "replay", replay: 28 } });
            // The replay starts 3 minutes before the session's first fault (13:30): minute 28 is 13:55.
            expect(await screen.findByText("13:55", { selector: ".cr-time" }, { timeout: 15000 })).toBeInTheDocument();
            await waitFor(() => expect(screen.getByText("T1 Deep blocking chain and lock escalation", { selector: "strong" }).parentElement?.textContent).toBe("Next: T1 Deep blocking chain and lock escalation in 5 min"));
            expect(screen.getByRole("img", { name: /^Scheduling, T3 Azure SQL Database: Signal visible\./ })).toBeInTheDocument();
            fireEvent.change(screen.getByRole("slider", { name: "Replay position" }), { target: { value: "36" } });
            expect(setView).toHaveBeenCalledWith({ replay: 36, session: SESSION_KEY });
        },
        SLOW,
    );
});

describe("Kiosk", () => {
    it("shows each scene for its seconds, round and round, pauses with Space, switches with the arrows, and leaves with Esc", () => {
        let state = kioskReducer(KIOSK_START, { type: "tick", seconds: SCENE_SECONDS.mission });
        expect(state.scene).toBe("scoreboard");
        state = kioskReducer(state, { type: "tick", seconds: SCENE_SECONDS.scoreboard });
        state = kioskReducer(state, { type: "tick", seconds: SCENE_SECONDS.replay });
        expect(state).toMatchObject({ scene: "mission", elapsed: 0 });
        const paused = kioskReducer(KIOSK_START, { type: "key", key: " " });
        expect(kioskReducer(paused, { type: "tick", seconds: 600 })).toMatchObject({ scene: "mission", paused: true, elapsed: 0 });
        expect(kioskReducer(KIOSK_START, { type: "key", key: "ArrowLeft" }).scene).toBe("replay");
        expect(kioskReducer(KIOSK_START, { type: "key", key: "Escape" }).exit).toBe(true);
        expect(kioskReducer(KIOSK_START, { type: "key", key: "Enter" })).toBe(KIOSK_START);
    });

    it(
        "runs without the app's frame: says to press F11 where the frame can't go full screen, and leaves for Mission Control with Esc",
        async () => {
            const { navigate } = renderWithApp(<KioskPage />, { client: sampleClient(), view: { page: "kiosk" } });
            expect(await screen.findByText("Press F11 for full screen")).toBeInTheDocument();
            fireEvent.keyDown(window, { key: " " });
            expect(await screen.findByText("Paused")).toBeInTheDocument();
            fireEvent.keyDown(window, { key: "ArrowRight" });
            expect(screen.getByRole("button", { name: "Did we catch it?" })).toHaveAttribute("aria-current", "step");
            fireEvent.keyDown(window, { key: "Escape" });
            await waitFor(() => expect(navigate).toHaveBeenCalledWith("mission", { session: null }));
        },
        SLOW,
    );
});
