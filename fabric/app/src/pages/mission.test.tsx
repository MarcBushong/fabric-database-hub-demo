// Wave 1's pages (ADR 0030) on the preview's sample session: Mission Control's map and numbers, the business lens, the
// postmortem, the scoreboard, the replay's moment, the kiosk's keys, and the map without motion.

import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import type { QuerySpec } from "@/data/queries";
import { createSourceClient, type QueryResult, type Row } from "@/data/query-client";
import type { PostmortemInput } from "@/lib/postmortem";
import { KIOSK_START, kioskReducer, RETRY_SECONDS, SCENE_SECONDS } from "@/mission/kiosk";
import { PostmortemDialog } from "@/mission/PostmortemDialog";
import { SCOREBOARD_SUBTITLE } from "@/lib/scoreboard";
import { ServiceMap, type MapNode } from "@/mission/ServiceMap";
import { sampleRows } from "@/preview/sample-data";
import { sampleRcaRows } from "@/preview/sample-rca";
import { SESSION_KEY } from "@/preview/sample-session";
import { answerKeyInContext } from "@/test/blind";
import { renderWithApp, type FakeQueryClient } from "@/test/render";
import KioskPage from "./KioskPage";
import MissionControlPage from "./MissionControlPage";
import ReplayPage from "./ReplayPage";
import ScoreboardPage from "./ScoreboardPage";

const SLOW = 30000;

/** The preview's sample, with its latest session, answering every query by its ID and parameters; `failing` queries throw, and `rows` replace a query's answer. */
function sampleClient(failing: Record<string, string> = {}, rows: Record<string, Row[]> = {}): FakeQueryClient {
    const ran: string[] = [];
    return {
        ran,
        peek: () => undefined,
        clear: () => undefined,
        run: vi.fn(async (spec: QuerySpec): Promise<QueryResult> => {
            ran.push(spec.id);
            if (failing[spec.id]) throw new Error(failing[spec.id]);
            return { spec, columns: spec.columns, rows: rows[spec.id] ?? sampleRows(spec), requestId: "sample", fetchedAt: new Date(Date.UTC(2026, 10, 17, 21)), provenance: "sample" };
        }),
    };
}

/** The sample with its RCA tables, as the preview has them; each read of the Incident RCA waits for `gate`, and `runs` join Scenario Runs. */
function sampleRcaClient(gate: Promise<void>, runs: Row[] = []): FakeQueryClient {
    const ran: string[] = [];
    return {
        ran,
        peek: () => undefined,
        clear: () => undefined,
        run: vi.fn(async (spec: QuerySpec): Promise<QueryResult> => {
            ran.push(spec.id);
            if (spec.id.startsWith("rca-")) await gate;
            const rows = sampleRcaRows(spec) ?? sampleRows(spec);
            return { spec, columns: spec.columns, rows: spec.id === "scenario-runs" ? [...runs, ...rows] : rows, requestId: "sample", fetchedAt: new Date(Date.UTC(2026, 10, 17, 21)), provenance: "sample" };
        }),
    };
}

const headingsOf = (dialog: HTMLElement) => [...dialog.querySelectorAll(".pm-view h4")].map((h) => h.textContent);

/** The list right under a heading of the postmortem's view. */
function listUnder(dialog: HTMLElement, heading: string): HTMLUListElement {
    let el = [...dialog.querySelectorAll(".pm-view h4")].find((h) => h.textContent === heading)?.nextElementSibling ?? null;
    while (el && el.tagName !== "UL") el = el.nextElementSibling;
    return el as HTMLUListElement;
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
            expect(within(numbers).getByText("Median time to signal")).toBeInTheDocument();
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
        "never rounds T5's throttled share to none in its numbers: 3 of 1,000 requests are less than 1 %, as on the map (the re-review of 2056a53)",
        async () => {
            const throttle: Row = {
                FindingId: "cosmosdb.T5.throttle.20261117T1400",
                TargetKey: "T5",
                Status: "Warning",
                StatusSort: 3,
                Finding: "Normalized RU consumption on T5 reached 100% with 3 throttled requests (429s) of 1,000 requests between 14:00 and 14:05 UTC.",
                Evidence: JSON.stringify({ throttled: 3, requests: 1000, peakNormalizedRuPercent: 100, stopped: true, recoveredAtUtc: "2026-11-17T14:05:00Z" }),
                WindowStart: "2026-11-17T14:00:00",
                WindowEnd: "2026-11-17T14:05:00",
                CapturedAt: "2026-11-17T15:06:00",
            };
            renderWithApp(<MissionControlPage />, { client: sampleClient({}, { "cosmos-findings": [throttle] }) });
            const numbers = await screen.findByRole("complementary", { name: "The session in numbers" }, { timeout: 15000 });
            await waitFor(() => expect(within(numbers).getByText("less than 1 % throttled")).toBeInTheDocument(), { timeout: 15000 });
            expect(within(numbers).getByText("3 of 1,000 requests answered 429 in 1 episode")).toBeInTheDocument();
            fireEvent.click(screen.getByRole("button", { name: "Business impact" }));
            expect(await screen.findByRole("button", { name: /^Patient events, T5 Azure Cosmos DB: .*less than 1 % of requests throttled for 5 min/i })).toBeInTheDocument();
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
            expect([...dialog.querySelectorAll(".pm-view h4")].map((h) => h.textContent)).toEqual(["Summary", "Timeline (UTC)", "Impact on ContosoCare", "Cause", "Response", "Times to signal and recover", "Follow-ups", "How this was measured", "Queries"]);
            expect(within(dialog).getByText(/^The Database Agent loop on T3: the plan regressed at 14:03 UTC, and the run forced the last good plan at 14:26 UTC/)).toBeInTheDocument();
            fireEvent.click(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true }));
            expect(notify).toHaveBeenCalledWith(expect.stringMatching(/^Downloaded contosocare-postmortem-7f3a9c21-\d{8}T\d{4}Z\.md$/), "success");
            fireEvent.click(within(dialog).getByRole("button", { name: "Draft with Copilot", hidden: true }));
            expect(copilot.ask).toHaveBeenCalledWith(expect.objectContaining({ page: "scoreboard", visualId: "postmortem.plan", totalRows: expect.any(Number) }));
            // The draft is blind (ADR 0031): the window and what was measured, never what was injected.
            expect(vi.mocked(copilot.ask).mock.calls[0][0].prompt).toMatch(/with exactly these sections: Summary, Timeline \(UTC\), Impact on ContosoCare, Cause, Response, Follow-ups\./);
            expect(JSON.stringify(vi.mocked(copilot.ask).mock.calls[0][0])).not.toMatch(/inject|Scenario Runs/i);
        },
        SLOW,
    );

    // ADR 0031, decision 7: the chat gets a session's minutes, never a lone incident request's, which are its fault's own.
    // The line points to the Root cause page whenever the navigation lists it (AppShell).
    const LONE: Array<{ state: string; rca: boolean | null; rcaError: string | null; points: boolean }> = [
        { state: "and points to the Root cause page", rca: true, rcaError: null, points: true },
        { state: "and points to the Root cause page when the RCA tables' check failed, which that page says", rca: null, rcaError: "The model didn't answer.", points: true },
        { state: "with no Root cause page to point to without the RCA tables", rca: false, rcaError: null, points: false },
    ];
    for (const { state, rca, rcaError, points } of LONE) {
        it(
            `offers no Copilot draft for a lone incident request, whose minutes are its fault's own, ${state} (the re-review of feb64ad3)`,
            async () => {
                renderWithApp(<MissionControlPage />, { client: sampleClient(), rca, rcaError, view: { session: "s5" } });
                const write = await screen.findByRole("button", { name: "Write the postmortem" });
                await waitFor(() => expect(write).toBeEnabled());
                fireEvent.click(write);
                const dialog = await screen.findByRole("dialog", { name: /^Postmortem: ContosoCare incident request: .+ on T1$/ });
                expect(within(dialog).queryByRole("button", { name: "Draft with Copilot", hidden: true })).toBeNull();
                const lead = dialog.querySelector(".pm-lead")?.textContent ?? "";
                expect(lead).toContain("There's no Draft with Copilot for a lone incident request, only for a session: a request's minutes are its fault's own, so they'd tell the chat where to look.");
                expect(lead.includes("The Root cause page finds the incidents from the signals alone and explains each one.")).toBe(points);
                // The app's own Markdown stays, with no sign-in. What the page's Asks hand the chat is ask-blind's to check.
                await waitFor(() => expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeEnabled());
            },
            SLOW,
        );
    }

    it(
        "with the Incident RCA's tables, writes the Cause from a blind investigation of the session's minutes, then what was injected, labeled as the answer key (ADR 0031, section 9)",
        async () => {
            URL.createObjectURL = vi.fn(() => "blob:postmortem");
            URL.revokeObjectURL = vi.fn();
            let release = () => undefined as void;
            const gate = new Promise<void>((resolve) => (release = resolve));
            const client = sampleRcaClient(gate);
            const { copilot, notify } = renderWithApp(<MissionControlPage />, { client, rca: true });
            const write = await screen.findByRole("button", { name: "Write the postmortem" });
            await waitFor(() => expect(write).toBeEnabled());
            fireEvent.click(write);
            // Titled at once, while the investigation runs; Download and Copy wait for its Markdown, and the draft doesn't.
            const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
            expect(within(dialog).getByText("Investigating the session's minutes for the Cause, which can take a minute or two…")).toBeInTheDocument();
            expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeDisabled();
            expect(within(dialog).getByRole("button", { name: "Copy", hidden: true })).toBeDisabled();
            expect(within(dialog).getByRole("button", { name: "Draft with Copilot", hidden: true })).toBeEnabled();
            release();
            await waitFor(() => expect(headingsOf(dialog)).toContain("What the demo injected (answer key)"), { timeout: 20000 });
            expect(headingsOf(dialog)).toEqual(["Summary", "Timeline (UTC)", "Impact on ContosoCare", "Cause", "What the demo injected (answer key)", "Response", "Times to signal and recover", "Follow-ups", "How this was measured", "Queries"]);
            expect(within(dialog).queryByText("Investigating the session's minutes for the Cause, which can take a minute or two…")).toBeNull();
            // The capture's chain first, its head blocker named, with the rows it cites nested under it.
            const first = listUnder(dialog, "Cause").children[0];
            expect(first.textContent).toMatch(/^T1, blocked processes, 14:02:30 to 14:11:40 UTC \(confidence high\): \[demo\]\.\[usp_scenario_chain_acquire\] \(session 63;/);
            const cited = [...first.querySelectorAll("ul > li")].map((li) => li.textContent);
            expect(cited).toHaveLength(3);
            expect(cited[0]).toMatch(/^head 63: sleeping, open transactions 1, idle \d+ s, \[demo\]\.\[usp_scenario_chain_acquire\] \(RCA Sessions, 14:03:00 UTC\)$/);
            // What the plan injected, only in its own section.
            expect(listUnder(dialog, "What the demo injected (answer key)").textContent).toMatch(/on T1 \(Billing\)/);
            expect(client.ran.filter((id) => id.startsWith("rca-")).length).toBeGreaterThan(0);
            fireEvent.click(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true }));
            expect(notify).toHaveBeenCalledWith(expect.stringMatching(/^Downloaded contosocare-postmortem-7f3a9c21-\d{8}T\d{4}Z\.md$/), "success");
            fireEvent.click(within(dialog).getByRole("button", { name: "Draft with Copilot", hidden: true }));
            expect(answerKeyInContext(vi.mocked(copilot.ask).mock.calls[0][0])).toBeNull();
        },
        SLOW,
    );

    it(
        "says in the Cause that the check of the RCA tables failed, never taking it for their absence, and runs no investigation",
        async () => {
            const client = sampleClient();
            renderWithApp(<MissionControlPage />, { client, rca: null, rcaError: "Execute Queries answered 429 Too Many Requests." });
            const write = await screen.findByRole("button", { name: "Write the postmortem" });
            await waitFor(() => expect(write).toBeEnabled());
            fireEvent.click(write);
            const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
            expect(headingsOf(dialog)).toEqual(["Summary", "Timeline (UTC)", "Impact on ContosoCare", "Cause", "What the demo injected (answer key)", "Response", "Times to signal and recover", "Follow-ups", "How this was measured", "Queries"]);
            expect(within(dialog).getByText("It couldn't run, so it gives no cause: the check of the Incident RCA's tables failed: Execute Queries answered 429 Too Many Requests.")).toBeInTheDocument();
            expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeEnabled();
            expect(client.ran.some((id) => id.startsWith("rca-"))).toBe(false);
        },
        SLOW,
    );

    it(
        "ends the investigated minutes at the next session's start, from the session control's record, when it comes within 15 minutes (the review of 63fb530c)",
        async () => {
            const next = { RequestedAt: "2026-11-17T15:05:00.000Z", Intensity: null, Concurrency: null, Dispatch: "session", Status: "Pass", RequestId: "session:abcdef12-1111-2222-3333-444444444444", TargetKey: "all", Profile: "session", DurationMin: 30, Message: "Session abcdef12: NB_DatabaseHub_Control's Run all (ADR 0026).", WindowStart: "2026-11-17T15:05:00.000Z", WindowEnd: "2026-11-17T15:35:00.000Z" };
            renderWithApp(<MissionControlPage />, { client: sampleRcaClient(Promise.resolve(), [next]), rca: true, view: { session: SESSION_KEY } });
            const write = await screen.findByRole("button", { name: "Write the postmortem" });
            await waitFor(() => expect(write).toBeEnabled());
            fireEvent.click(write);
            const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
            expect(await within(dialog).findByText(/of the session's minutes as the session control recorded them, and the 5 minutes after them, up to the next session's start \(13:30 to 15:05 UTC\)\./, {}, { timeout: 20000 })).toBeInTheDocument();
        },
        SLOW,
    );

    // Each page that writes the postmortem hands it the period's plans (the re-review of feb64ad3).
    for (const [name, Page] of [
        ["Mission Control", MissionControlPage],
        ["the scoreboard", ScoreboardPage],
        ["the replay", ReplayPage],
    ] as const) {
        it(
            `lists another plan's fault in the investigated minutes in the answer key, labeled as outside this session, from ${name} (the re-review of feb64ad3)`,
            async () => {
                const next = { RequestedAt: "2026-11-17T15:05:00.000Z", Intensity: null, Concurrency: null, Dispatch: "session", Status: "Pass", RequestId: "session:abcdef12-1111-2222-3333-444444444444", TargetKey: "all", Profile: "session", DurationMin: 30, Message: "Session abcdef12: NB_DatabaseHub_Control's Run all (ADR 0026).", WindowStart: "2026-11-17T15:05:00.000Z", WindowEnd: "2026-11-17T15:35:00.000Z" };
                const r12 = { RequestedAt: "2026-11-17T15:02:00.000Z", Intensity: 5, Concurrency: 2, Dispatch: "webhook", Status: "Pass", RequestId: "r12", TargetKey: "T2", Profile: "incident:io-pressure", DurationMin: 8, Message: "Ran io-pressure on T2 for 8 minutes", WindowStart: "2026-11-17T15:02:00.000Z", WindowEnd: "2026-11-17T15:10:00.000Z" };
                renderWithApp(<Page />, { client: sampleRcaClient(Promise.resolve(), [next, r12]), rca: true, view: { session: SESSION_KEY } });
                const write = await screen.findByRole("button", { name: "Write the postmortem" });
                await waitFor(() => expect(write).toBeEnabled());
                fireEvent.click(write);
                const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
                await waitFor(() => expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeEnabled(), { timeout: 20000 });
                expect(dialog.textContent).toContain("Outside this session: other plans injected these faults in the investigated minutes");
                expect(dialog.textContent).toContain("IO pressure on T2 (Front desk), 15:02 to 15:10 UTC: a lone incident request.");
            },
            SLOW,
        );
    }

    // The investigation reads every target, so the answer key does too, whatever the page's filter shows (the review of
    // b4370565): the session's own faults on T3, and T4's and T5's episodes, which the page doesn't load when it hides them.
    // Each page that writes the postmortem hands it the period's plans before the filter.
    for (const [name, Page, targets, hides] of [
        ["Mission Control", MissionControlPage, ["T1", "T2"], true],
        ["the scoreboard", ScoreboardPage, ["T1", "T2"], true],
        ["the replay", ReplayPage, ["T1", "T2"], true],
        ["Mission Control", MissionControlPage, ["T1", "T2", "T3", "T4", "T5"], false],
    ] as const) {
        it(
            `lists the session's faults and T4's and T5's episodes in the answer key with the filter on ${targets.join(", ")}, from ${name} (the review of b4370565)`,
            async () => {
                const client = sampleRcaClient(Promise.resolve());
                renderWithApp(<Page />, { client, rca: true, view: { session: SESSION_KEY, targets: [...targets] } });
                const write = await screen.findByRole("button", { name: "Write the postmortem" });
                await waitFor(() => expect(write).toBeEnabled());
                const loaded = ["postgres-series", "cosmos-series", "cosmos-findings"].filter((id) => client.ran.includes(id));
                expect(loaded).toEqual(hides ? [] : ["postgres-series", "cosmos-series", "cosmos-findings"]);
                fireEvent.click(write);
                const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
                await waitFor(() => expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeEnabled(), { timeout: 20000 });
                const text = dialog.textContent ?? "";
                // The session's first fault on T3, in the key either way, and the note on T4's and T5's episodes.
                expect(text).toMatch(/on T3 \(Scheduling\), 13:31 to 13:43 UTC\./);
                expect(text).toContain("T4's and T5's beats aren't in Scenario Runs; their episodes come from their own Azure Monitor metrics, as captured at the session's end.");
                // Shown, T3's faults and T4's and T5's episodes are in the timeline above; hidden, the key lists them.
                expect(/on T4 \(Reporting\), \d\d:\d\d to \d\d:\d\d UTC, an episode in its Azure Monitor metrics\./.test(text)).toBe(hides);
                expect(/on T5 \(Patient events\), \d\d:\d\d to \d\d:\d\d UTC, an episode in its Azure Monitor metrics\./.test(text)).toBe(hides);
                for (const target of ["T3", "T5"]) expect([...dialog.querySelectorAll("td")].some((td) => td.textContent === target), target).toBe(!hides);
                expect(text.includes("On targets this page's filter hides: the investigation above reads every target, so the key does too, though the sections above leave these out:")).toBe(hides);
                expect(text.includes("And the answer key's, for the targets this page's filter hides:")).toBe(hides);
                // Only what the filter hides is loaded again, for the key.
                expect(client.ran.filter((id) => id === "postgres-series").length).toBe(1);
                expect(client.ran.filter((id) => id === "cosmos-findings").length).toBe(1);
            },
            SLOW,
        );
    }

    // The answer key's T4 on a page whose filter hides it reads every save in the latest capture's window, as the pages do
    // (F35): a later day-long save's 15-minute point never moves an episode the session's own 5-minute points give.
    it(
        "takes each interval of T4's hidden capture from its finest save in the answer key (F35, the RCA release's merge)",
        async () => {
            const at = (hhmm: string) => `2026-11-17T${hhmm}:00`;
            const lag = (save: Record<string, string>, minutes: number, from: string, values: readonly number[]): Row[] =>
                values.map((value, i) => ({ Bucket: new Date(Date.parse(`${at(from)}Z`) + i * minutes * 60000).toISOString().slice(0, 19), TargetKey: "T4-replica", ResourceName: "pgreplica01-sample", Metric: "physical_replication_delay_in_seconds", Value: value, Unit: "", ...save }));
            const session = { WindowStart: at("13:30"), WindowEnd: at("15:00"), CapturedAt: at("15:06") };
            const day = { WindowStart: "2026-11-16T19:00:00", WindowEnd: at("19:00"), CapturedAt: at("19:04") };
            // The session's 5-minute points: 180 s at 14:20 only. The day's 15-minute ones: that peak, at 14:15.
            const rows = [...lag(session, 5, "13:30", Array.from({ length: 18 }, (_, i) => (i === 10 ? 180 : 2))), ...lag(day, 15, "13:30", Array.from({ length: 6 }, (_, i) => (i === 3 ? 180 : 2)))];
            const sample = sampleRcaClient(Promise.resolve());
            const client: FakeQueryClient = { ...sample, run: vi.fn(async (spec: QuerySpec) => (spec.id === "postgres-series" ? { ...(await sample.run(spec)), rows } : sample.run(spec))) };
            renderWithApp(<MissionControlPage />, { client, rca: true, view: { session: SESSION_KEY, targets: ["T1", "T2", "T3"] } });
            const write = await screen.findByRole("button", { name: "Write the postmortem" });
            await waitFor(() => expect(write).toBeEnabled());
            fireEvent.click(write);
            const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare session 7f3a9c21" });
            await waitFor(() => expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeEnabled(), { timeout: 20000 });
            const text = dialog.textContent ?? "";
            expect(text).toMatch(/14:20 to 14:25 UTC, an episode in its Azure Monitor metrics\./);
            expect(text).not.toMatch(/14:15 to \d\d:\d\d UTC, an episode in its Azure Monitor metrics\./);
        },
        SLOW,
    );

    it(
        "never investigates a lone incident request's minutes, which are its fault's own, and points to the Root cause page (the review of 63fb530c)",
        async () => {
            const client = sampleRcaClient(Promise.resolve());
            const request: PostmortemInput["plan"] = { key: "r9", kind: "request", label: "CPU pressure on T1", start: new Date("2026-11-17T12:00:00Z"), end: new Date("2026-11-17T12:10:00Z"), requestedAt: null, status: "Pass", message: "", faults: [] };
            const input: PostmortemInput = { plan: request, scores: [], episodes: [], beat: null, asOf: null, provenance: "history", specs: [], generatedAt: new Date("2026-11-17T21:00:00Z") };
            renderWithApp(<PostmortemDialog input={input} onClose={vi.fn()} />, { client, rca: true });
            const dialog = await screen.findByRole("dialog", { name: "Postmortem: ContosoCare incident request: CPU pressure on T1" });
            expect(headingsOf(dialog)).toEqual(["Summary", "Timeline (UTC)", "Impact on ContosoCare", "Cause", "What the demo injected (answer key)", "Response", "Times to signal and recover", "Follow-ups", "How this was measured", "Queries"]);
            expect(within(dialog).getByText(/^This is one incident request's postmortem, and its minutes are its fault's own, .+ The Root cause page finds the incidents from the signals alone, .+ and explains each one\.$/)).toBeInTheDocument();
            expect(within(dialog).queryByText(/Investigating the session's minutes/)).toBeNull();
            expect(within(dialog).getByRole("button", { name: "Download Markdown", hidden: true })).toBeEnabled();
            expect(client.ran.some((id) => id.startsWith("rca-"))).toBe(false);
        },
        SLOW,
    );

    it(
        "names the history that didn't load, and measures nothing rather than reading every fault as not visible",
        async () => {
            const client = sampleClient({
                "signals-per-bin": "The query returned more rows than the app allows: pick a shorter period.",
                "spotlight-T1": "The model didn't answer.",
                "agent-loop": "The model didn't answer.",
            });
            renderWithApp(<MissionControlPage />, { client });
            await screen.findByRole("heading", { level: 1, name: /^Session 7f3a9c21/ });
            const numbers = await screen.findByRole("complementary", { name: "The session in numbers" });
            await waitFor(() => expect(within(numbers).getByText("The telemetry didn't load, so nothing is measured")).toBeInTheDocument());
            // The plan is in Scenario Runs: its 35 faults stand; what wasn't measured isn't "0 of 35".
            expect(within(numbers).getByText("35")).toBeInTheDocument();
            expect(within(numbers).queryByText(/^\d+ of 35$/)).toBeNull();
            const notice = await screen.findByText(/^Some of the history didn't load, so this view may be incomplete: /);
            expect(notice.textContent).toContain("Signals per bin and target (The query returned more rows than the app allows: pick a shorter period)");
            expect(notice.textContent).toContain("Waits before and during: T1 (The model didn't answer)");
            expect(notice.textContent).toContain("Database Agent loop on T3 (The model didn't answer)");
            // The postmortem waits for the telemetry: written now, it would have no measured fault.
            const write = screen.getByRole("button", { name: "Write the postmortem" });
            await waitFor(() => expect(write).toHaveAttribute("aria-disabled", "true"));
            fireEvent.click(write);
            expect(screen.queryByRole("dialog", { hidden: true })).toBeNull();
            const runs = vi.mocked(client.run).mock.calls.length;
            fireEvent.click(screen.getByRole("button", { name: "Retry" }));
            await waitFor(() => expect(vi.mocked(client.run).mock.calls.length).toBeGreaterThanOrEqual(runs + 3));
        },
        SLOW,
    );

    it(
        "says when the session the address asks for isn't in this period, rather than showing another in its place",
        async () => {
            const { setView } = renderWithApp(<MissionControlPage />, { client: sampleClient(), view: { session: "session:gone" } });
            expect(await screen.findByText("Session gone isn't in this period")).toBeInTheDocument();
            expect(screen.queryByRole("heading", { level: 1, name: /^Session 7f3a9c21/ })).toBeNull();
            fireEvent.click(screen.getByRole("button", { name: "Show the latest session" }));
            expect(setView).toHaveBeenCalledWith({ session: null, replay: null });
            fireEvent.click(screen.getByRole("button", { name: "Show all history" }));
            expect(setView).toHaveBeenCalledWith({ window: "all" });
        },
        SLOW,
    );

    it(
        "takes only a session the viewer picked to the other pages: without one, they follow the latest, so no later visit opens on a session nobody chose",
        async () => {
            const latest = renderWithApp(<MissionControlPage />, { client: sampleClient() });
            await screen.findByRole("heading", { level: 1, name: /^Session 7f3a9c21/ });
            fireEvent.click(screen.getByRole("button", { name: "Scoreboard" }));
            expect(latest.navigate).toHaveBeenLastCalledWith("scoreboard", { session: null });
            fireEvent.click(screen.getByRole("button", { name: "Replay" }));
            expect(latest.navigate).toHaveBeenLastCalledWith("replay", { session: null });
            latest.unmount();
            const picked = renderWithApp(<MissionControlPage />, { client: sampleClient(), view: { session: SESSION_KEY } });
            await screen.findByRole("heading", { level: 1, name: /^Session 7f3a9c21/ });
            fireEvent.click(screen.getByRole("button", { name: "Scoreboard" }));
            expect(picked.navigate).toHaveBeenLastCalledWith("scoreboard", { session: SESSION_KEY });
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
            const { navigate } = renderWithApp(<ScoreboardPage />, { client: sampleClient() });
            expect(await screen.findByRole("heading", { level: 1, name: "Did we catch it? 34 of 35" }, { timeout: 15000 })).toBeInTheDocument();
            // It says what it verifies, never that it caught anything blind: each injected fault's expected signal, in its window.
            expect(screen.getByText(SCOREBOARD_SUBTITLE)).toBeInTheDocument();
            const stats = screen.getByLabelText("The session in numbers");
            expect(within(stats).getByText("Signal seen")).toBeInTheDocument();
            expect(within(stats).getByText("Median time to signal")).toBeInTheDocument();
            expect(within(stats).queryByText(/Caught|detect/)).toBeNull();
            const table = screen.getByRole("table", { name: "Every injected fault" });
            expect(within(table).getByRole("columnheader", { name: /^Signal seen\?/ })).toBeInTheDocument();
            expect(within(table).getByRole("columnheader", { name: /^Time to signal/ })).toBeInTheDocument();
            const rows = within(table).getAllByRole("row").slice(1);
            expect(rows).toHaveLength(35);
            const missed = rows.filter((r) => /Warning/.test(r.textContent ?? ""));
            expect(missed).toHaveLength(1);
            expect(missed[0].textContent).toMatch(/14:48.*IO pressure/);
            const agent = rows.find((r) => /Plan regression/.test(r.textContent ?? "") && /14:26/.test(r.textContent ?? ""));
            expect(agent?.textContent).toMatch(/14:03.*14:03.*14:26.*14:27.*24 min/);
            expect(screen.getByRole("heading", { name: "Times per engine" })).toBeInTheDocument();
            expect(screen.getByRole("heading", { name: "Times per fault type" })).toBeInTheDocument();
            for (const name of ["Times per engine", "Times per fault type"]) {
                // The card's own body, described by its summary (the chart inside has the same name and its own description).
                const card = screen.getAllByRole("group", { name }).find((g) => g.classList.contains("vcard-body"));
                expect(card).toBeDefined();
                expect(card).toHaveAccessibleDescription(/: time to signal .+, time to recover /);
                expect(card).not.toHaveAccessibleDescription(/detect/);
            }
            expect(screen.getByRole("heading", { name: "T4 and T5: what their metrics show" })).toBeInTheDocument();
            fireEvent.click(screen.getByRole("button", { name: "Business impact" }));
            expect(within(screen.getByRole("table", { name: "Every injected fault" })).getByRole("columnheader", { name: /Business impact \(measured\)/ })).toBeInTheDocument();
            // No session was picked, so Mission Control keeps following the latest.
            fireEvent.click(screen.getByRole("button", { name: "Mission Control" }));
            expect(navigate).toHaveBeenLastCalledWith("mission", { session: null });
        },
        SLOW,
    );

    it(
        "writes the T4 and T5 card's peaks as measured, never 100 % for a peak under 100, in both lenses",
        async () => {
            const episode = (from: string, to: string, peak: number): Row => ({
                FindingId: `cosmosdb.T5.throttle.20261117T${from.replace(":", "")}`,
                TargetKey: "T5",
                Status: "Warning",
                StatusSort: 3,
                Finding: `Throttling from ${from} to ${to} UTC.`,
                Evidence: JSON.stringify({ throttled: 520, requests: 1000, peakNormalizedRuPercent: peak, stopped: true, recoveredAtUtc: `2026-11-17T${to}:00Z` }),
                WindowStart: `2026-11-17T${from}:00`,
                WindowEnd: `2026-11-17T${to}:00`,
                CapturedAt: "2026-11-17T15:06:00",
            });
            renderWithApp(<ScoreboardPage />, { client: sampleClient({}, { "cosmos-findings": [episode("14:00", "14:05", 99.6), episode("14:20", "14:25", 99.996)] }) });
            await screen.findByRole("heading", { level: 1, name: /^Did we catch it\?/ }, { timeout: 15000 });
            // The card's own body (a VisualCard's group, named by its title).
            const card = () => screen.getAllByRole("group", { name: "T4 and T5: what their metrics show" }).find((g) => g.classList.contains("vcard-body"));
            await waitFor(() => expect(card()?.textContent).toContain("normalized RU and 429s: peak 99.6 %."), { timeout: 15000 });
            expect(card()?.textContent).toContain("normalized RU and 429s: peak 99.996 %.");
            expect(card()?.textContent).not.toMatch(/normalized RU and 429s: peak 100/);
            fireEvent.click(screen.getByRole("button", { name: "Business impact" }));
            await waitFor(() => expect(card()?.textContent).toContain("(normalized RU 99.6 %, 429s on 520 of 1,000 requests)"));
            expect(card()?.textContent).toContain("(normalized RU 99.996 %, 429s on 520 of 1,000 requests)");
            expect(card()?.textContent).not.toMatch(/normalized RU 100/);
        },
        SLOW,
    );

    it(
        "shows the telemetry's failure in its faults card, not a count of faults it couldn't read",
        async () => {
            renderWithApp(<ScoreboardPage />, { client: sampleClient({ "signals-per-bin": "The query returned more rows than the app allows: pick a shorter period." }) });
            expect(await screen.findByRole("heading", { level: 1, name: "Did we catch it?" }, { timeout: 15000 })).toBeInTheDocument();
            const alert = await screen.findByText("The query returned more rows than the app allows: pick a shorter period.", { selector: ".vcard-error span" });
            expect(alert.closest('[role="alert"]')).not.toBeNull();
            expect(screen.queryByRole("table", { name: "Every injected fault" })).toBeNull();
            await waitFor(() => expect(screen.getByRole("button", { name: "Write the postmortem" })).toHaveAttribute("aria-disabled", "true"));
        },
        SLOW,
    );
});

describe("Session replay", () => {
    it(
        "drives the map and the ribbon from one scrubber, counts down to the next injection, and keeps the moment in the address",
        async () => {
            const { setView, navigate } = renderWithApp(<ReplayPage />, { client: sampleClient(), view: { page: "replay", replay: 28 } });
            // The replay starts 3 minutes before the session's first fault (13:30): minute 28 is 13:55.
            expect(await screen.findByText("13:55", { selector: ".cr-time" }, { timeout: 15000 })).toBeInTheDocument();
            await waitFor(() => expect(screen.getByText("T1 Deep blocking chain and lock escalation", { selector: "strong" }).parentElement?.textContent).toBe("Next: T1 Deep blocking chain and lock escalation in 5 min"));
            expect(screen.getByRole("img", { name: /^Scheduling, T3 Azure SQL Database: Signal visible\./ })).toBeInTheDocument();
            // The countdown changes with every step of the playback, so it isn't a live region.
            expect(screen.getByText("T1 Deep blocking chain and lock escalation", { selector: "strong" }).closest("[aria-live]")).toBeNull();
            fireEvent.change(screen.getByRole("slider", { name: "Replay position" }), { target: { value: "36" } });
            // The address takes the moment once it holds still, not at every step of a drag, and not the session nobody picked.
            await waitFor(() => expect(setView).toHaveBeenCalledWith({ replay: 36 }), { timeout: 3000 });
            expect(setView.mock.calls.some(([patch]) => "session" in patch)).toBe(false);
            fireEvent.click(screen.getByRole("button", { name: "Scoreboard" }));
            expect(navigate).toHaveBeenLastCalledWith("scoreboard", { session: null });
            // Copying the link to the moment is a pick: the link, and this browser, keep its session.
            fireEvent.click(screen.getByRole("button", { name: "Link to this moment" }));
            expect(setView).toHaveBeenLastCalledWith({ replay: 36, session: SESSION_KEY });
        },
        SLOW,
    );

    it(
        "waits to write the postmortem while the telemetry it's scored from hasn't loaded",
        async () => {
            renderWithApp(<ReplayPage />, { client: sampleClient({ "signals-per-bin": "The model didn't answer." }), view: { page: "replay" } });
            expect(await screen.findByRole("heading", { level: 1, name: "Session 7f3a9c21, beat by beat" }, { timeout: 15000 })).toBeInTheDocument();
            expect(await screen.findByText(/^Some of the history didn't load, so this view may be incomplete: Signals per bin and target/)).toBeInTheDocument();
            await waitFor(() => expect(screen.getByRole("button", { name: "Write the postmortem" })).toHaveAttribute("aria-disabled", "true"));
        },
        SLOW,
    );

    it(
        "reads T5's 429s per minute where a day-long save's 15-minute total meets the session's own minutes (F35)",
        async () => {
            // The review of 3fe52edb: the lane read the day's 1,500 from 13:45 beside the session's 10 a minute before it.
            const save = (CapturedAt: string, WindowStart: string, WindowEnd: string) => ({ CapturedAt, WindowStart, WindowEnd });
            const session = save("2026-11-17T13:50:00", "2026-11-17T13:30:00", "2026-11-17T13:45:00");
            const day = save("2026-11-17T14:05:00", "2026-11-16T14:00:00", "2026-11-17T14:00:00");
            const point = (from: Record<string, string>, minute: string, metric: string, value: number): Row => ({ Bucket: `2026-11-17T${minute}:00`, TargetKey: "T5", ResourceName: "cosmos01-test", Metric: metric, Value: value, Unit: "", ...from });
            const rows = [
                ...Array.from({ length: 15 }, (_, m) => `13:${30 + m}`).flatMap((m) => [point(session, m, "ThrottledRequests", 10), point(session, m, "NormalizedRUConsumption", 100)]),
                ...(
                    [
                        ["13:15", 0, 5],
                        ["13:30", 150, 100],
                        ["13:45", 1500, 100],
                    ] as const
                ).flatMap(([m, throttled, ru]) => [point(day, m, "ThrottledRequests", throttled), point(day, m, "NormalizedRUConsumption", ru)]),
            ];
            const { container } = renderWithApp(<ReplayPage />, { client: sampleClient({}, { "cosmos-series": rows }), view: { page: "replay", replay: 28 } });
            expect(await screen.findByText("13:55", { selector: ".cr-time" }, { timeout: 15000 })).toBeInTheDocument();
            const t5 = () => [...container.querySelectorAll(".cr-readout")].map((e) => e.textContent ?? "").find((t) => t.includes("429s"));
            await waitFor(() => expect(t5()).toMatch(/· 429s a minute 100$/));
        },
        SLOW,
    );

    it(
        "plays back without writing the address at each step, writes the moment once paused, and says play and pause to a screen reader",
        async () => {
            const { setView, container } = renderWithApp(<ReplayPage />, { client: sampleClient(), view: { page: "replay", replay: 28 } });
            await screen.findByText("13:55", { selector: ".cr-time" }, { timeout: 15000 });
            const writes = () => setView.mock.calls.filter(([patch]) => "replay" in patch).length;
            fireEvent.click(screen.getByRole("button", { name: "8×" }));
            fireEvent.click(screen.getByRole("button", { name: "Play" }));
            expect(screen.getByText("Playing at 8×.")).toBeInTheDocument();
            // 10 steps of 87.5 ms each: WebKit refuses more than 100 address changes in 10 seconds.
            await waitFor(() => expect((container.querySelector(".cr-time")?.textContent ?? "") >= "14:05").toBe(true), { timeout: 5000 });
            expect(writes()).toBe(0);
            fireEvent.click(screen.getByRole("button", { name: "Pause" }));
            expect(screen.getByText(/^Paused at \d\d:\d\d UTC\.$/)).toBeInTheDocument();
            await waitFor(() => expect(writes()).toBe(1), { timeout: 3000 });
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

    it(
        "tells a screen reader the scene and whether it's paused, never the countdown",
        async () => {
            const { container } = renderWithApp(<KioskPage />, { client: sampleClient(), view: { page: "kiosk" } });
            const countdown = await screen.findByText(/^Next scene in \d+ s$/);
            expect(countdown.closest("[aria-live]")).toBeNull();
            const live = container.querySelector('.kiosk [aria-live="polite"]');
            expect(live?.textContent).toBe("Mission Control");
            fireEvent.keyDown(window, { key: "ArrowRight" });
            expect(live?.textContent).toBe("Did we catch it?");
            fireEvent.keyDown(window, { key: " " });
            expect(live?.textContent).toBe("Did we catch it?, paused");
        },
        SLOW,
    );

    it(
        "counts the plan's faults when the telemetry didn't load, and says nothing is measured rather than 0 of 0",
        async () => {
            renderWithApp(<KioskPage />, { client: sampleClient({ "signals-per-bin": "The query returned more rows than the app allows: pick a shorter period." }), view: { page: "kiosk" } });
            const seen = await screen.findByText("The telemetry didn't load, so nothing is measured", {}, { timeout: 15000 });
            expect(seen.parentElement?.textContent).toBe("Seen in telemetry–The telemetry didn't load, so nothing is measured");
            expect(within(screen.getByText("Faults injected").parentElement as HTMLElement).getByText("35")).toBeInTheDocument();
            fireEvent.keyDown(window, { key: "ArrowRight" });
            expect(screen.getByRole("heading", { level: 2, name: "Did we catch it?" })).toBeInTheDocument();
            expect(screen.getByText(SCOREBOARD_SUBTITLE)).toBeInTheDocument();
            expect(screen.getByText(`The telemetry didn't load, so none of the 35 faults is measured yet: the kiosk tries again every ${RETRY_SECONDS} s.`)).toBeInTheDocument();
            expect(screen.queryByText(/\b0 of 0\b/)).toBeNull();
        },
        SLOW,
    );

    it(
        "keeps its session on screen when its history expires and a refresh fails, asks again on its own, then keeps refreshing",
        async () => {
            vi.useFakeTimers({ shouldAdvanceTime: true });
            try {
                let now = Date.UTC(2026, 10, 17, 21);
                let refusing = false;
                let gate: Promise<void> | null = null;
                let openGate: () => void = () => undefined;
                const fetch = vi.fn(async (spec: QuerySpec) => {
                    if (gate) await gate;
                    if (refusing) throw new Error("The semantic model didn't answer.");
                    return { rows: sampleRows(spec), requestId: "sample" };
                });
                const client = Object.assign(createSourceClient([{ provenance: "sample", answers: () => true, fetch }], { now: () => now }), { ran: [] as string[] });
                const first = renderWithApp(<KioskPage />, { client, view: { page: "kiosk" } });
                expect(await screen.findByText("34 of 35", {}, { timeout: 15000 })).toBeInTheDocument();
                first.unmount();
                // A kiosk opened later reads the same history from the cache, as one opened from Mission Control does.
                renderWithApp(<KioskPage />, { client, view: { page: "kiosk" } });
                expect(await screen.findByText("34 of 35", {}, { timeout: 15000 })).toBeInTheDocument();
                // The cache's five minutes pass: the kiosk's next tick refreshes its history, which takes a while, then fails.
                refusing = true;
                gate = new Promise<void>((resolve) => {
                    openGate = () => resolve();
                });
                now += 6 * 60000;
                const before = fetch.mock.calls.length;
                await vi.advanceTimersByTimeAsync(1000);
                await waitFor(() => expect(fetch.mock.calls.length).toBeGreaterThan(before));
                // While the refresh runs, the kiosk keeps what it had, on whichever scene it's on.
                expect(screen.getByText(/34 of 35$/)).toBeInTheDocument();
                openGate();
                gate = null;
                expect(await screen.findByText(`Some of the history didn't load: trying again every ${RETRY_SECONDS} s`)).toBeInTheDocument();
                // That note shows only with a session on screen: the kiosk kept its last history, rather than going blank.
                expect(screen.queryByText(/^No session in this period yet/)).toBeNull();
                // The model answers again: the kiosk's own retry brings it back, with no one at the screen.
                refusing = false;
                const failed = fetch.mock.calls.length;
                await vi.advanceTimersByTimeAsync(RETRY_SECONDS * 1000);
                await waitFor(() => expect(fetch.mock.calls.length).toBeGreaterThan(failed));
                await waitFor(() => expect(screen.queryByText(/trying again every/)).toBeNull());
                // And the queries the retry ran keep refreshing each time their five minutes pass, so a later session shows.
                const ranOf = (id: string) => fetch.mock.calls.filter(([spec]) => spec.id === id).length;
                const sessionsRan = ranOf("scenario-runs");
                const seriesRan = ranOf("signals-per-bin");
                now += 6 * 60000;
                await vi.advanceTimersByTimeAsync(1000);
                await waitFor(() => expect(ranOf("scenario-runs")).toBeGreaterThan(sessionsRan));
                await waitFor(() => expect(ranOf("signals-per-bin")).toBeGreaterThan(seriesRan));
                expect(screen.getByText(/34 of 35$/)).toBeInTheDocument();
            } finally {
                vi.useRealTimers();
            }
        },
        SLOW,
    );
});
