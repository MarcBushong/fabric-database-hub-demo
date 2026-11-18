import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import EstatePage from "@/pages/EstatePage";
import FindingsPage from "@/pages/FindingsPage";
import IncidentsPage from "@/pages/IncidentsPage";
import LinksPage from "@/pages/LinksPage";
import ManagePage from "@/pages/ManagePage";
import OverviewPage from "@/pages/OverviewPage";
import PerformancePage from "@/pages/PerformancePage";
import ReadinessPage from "@/pages/ReadinessPage";
import TrendsPage from "@/pages/TrendsPage";
import { FIXTURES, fakeQueryClient, renderWithApp } from "@/test/render";

/** A storage the test owns: newer Node versions put their own, empty localStorage in front of jsdom's. */
function memoryStorage(): Storage {
    const data = new Map<string, string>();
    return {
        get length() {
            return data.size;
        },
        clear: () => data.clear(),
        getItem: (key: string) => data.get(key) ?? null,
        key: (index: number) => [...data.keys()][index] ?? null,
        removeItem: (key: string) => void data.delete(key),
        setItem: (key: string, value: string) => void data.set(key, String(value)),
    };
}

beforeEach(() => {
    vi.stubGlobal("localStorage", memoryStorage());
});

afterEach(() => {
    vi.unstubAllGlobals();
});

describe("Overview", () => {
    it("says what needs attention: the tiles, each target's health, the incidents, and the findings", async () => {
        const { client } = renderWithApp(<OverviewPage />);
        expect(await screen.findByRole("heading", { level: 1, name: "Overview" })).toBeInTheDocument();
        const glance = screen.getByRole("region", { name: "At a glance" });
        expect(await within(glance).findByText("Targets needing attention")).toBeInTheDocument();
        expect(within(glance).getByText("Incident windows")).toBeInTheDocument();
        await waitFor(() => expect(screen.getByRole("button", { name: /^T3 · Azure SQL Database, Warning: open its details/ })).toBeInTheDocument());
        expect(screen.getByRole("button", { name: /^T4 · Azure Database for PostgreSQL, Warning: open its details/ })).toBeInTheDocument();
        expect(await screen.findByText("Buffer IO waits rose sharply")).toBeInTheDocument();
        expect(client.ran).toEqual(expect.arrayContaining(["estate-targets", "signals-per-bin", "findings-latest", "incident-windows", "readiness-summary", "scenario-runs", "postgres-series"]));
    });

    it("drills from a target's tile into the Estate page", async () => {
        const { navigate } = renderWithApp(<OverviewPage />);
        fireEvent.click(await screen.findByRole("button", { name: /^T3 · Azure SQL Database, Warning: open its details/ }));
        expect(navigate).toHaveBeenCalledWith("estate", { target: "T3" });
    });

    it("asks Copilot which databases need attention, with the rows and the DAX behind them", async () => {
        const { copilot } = renderWithApp(<OverviewPage />);
        await screen.findByRole("button", { name: /^T3 · Azure SQL Database/ });
        fireEvent.click(screen.getByRole("button", { name: "Which databases need attention this week, and why?" }));
        expect(copilot.ask).toHaveBeenCalledTimes(1);
        const ctx = vi.mocked(copilot.ask).mock.calls[0][0];
        expect(ctx).toMatchObject({ prompt: "Which databases need attention this week, and why?", page: "overview", visualId: "overview.attention", source: "history" });
        expect(ctx.rows?.map((r) => r.target)).toEqual(["T1", "T2", "T3", "T4"]);
        expect(ctx.dax).toMatch(/^\/\/ Estate: key signals per target\nEVALUATE/);
        expect(ctx.asOf).toBe("2026-10-21T20:30:00.000Z");
    });

    it("on the first run, says the one action that fills it: Run all in NB_DatabaseHub_Control", async () => {
        renderWithApp(<OverviewPage />, { client: fakeQueryClient({ "history-meta": [] }), metaEmpty: true });
        expect(await screen.findByText("No history yet")).toBeInTheDocument();
        expect(screen.getByText(/Run all in/)).toHaveTextContent("Run all in NB_DatabaseHub_Control fills it");
        expect(screen.queryByRole("region", { name: "At a glance" })).not.toBeInTheDocument();
    });
});

describe("Estate", () => {
    it("lists every target with its engine, and opens one from the inventory", async () => {
        const { navigate } = renderWithApp(<EstatePage />);
        const grid = await screen.findByRole("table", { name: "Estate inventory" });
        await waitFor(() => expect(within(grid).getAllByRole("row").length).toBeGreaterThan(3));
        expect(within(grid).getByText("Azure SQL Database")).toBeInTheDocument();
        expect(within(grid).getByText("azuresql01-test01/ContosoCare")).toBeInTheDocument();
        expect(within(grid).getByText("pgreplica01-test01")).toBeInTheDocument();
        fireEvent.click(within(grid).getByRole("row", { name: "Open T3" }));
        expect(navigate).toHaveBeenCalledWith("estate", { target: "T3" });
    });

    it("drills into a SQL target: its numbers, its CPU with incident bands, and Ask why on the peak", async () => {
        const { copilot } = renderWithApp(<EstatePage />, { view: { page: "estate", target: "T3" } });
        expect(await screen.findByRole("heading", { level: 1, name: "T3 · Azure SQL Database" })).toBeInTheDocument();
        expect(screen.getByRole("navigation", { name: "Where you are" })).toHaveTextContent("Estate");
        const cpu = await screen.findByRole("region", { name: "CPU" });
        await waitFor(() => expect(cpu.querySelector("path.chart-line")?.getAttribute("d") ?? "").toMatch(/^M[\d.]+,[\d.]+/));
        fireEvent.click(await screen.findByRole("button", { name: "Ask why" }));
        const ctx = vi.mocked(copilot.ask).mock.calls[0][0];
        expect(ctx.prompt).toMatch(/^Why did T3's CPU reach 120\.0 % at 21 Oct 10:00 UTC when its median/);
        expect(ctx.anomaly).toMatchObject({ metric: "CPU", target: "T3", unit: "%" });
    });

    it("shows T4 and its read replica from the latest PostgreSQL capture", async () => {
        renderWithApp(<EstatePage />, { view: { page: "estate", target: "T4" } });
        expect(await screen.findByRole("heading", { level: 1, name: "T4 · Azure Database for PostgreSQL" })).toBeInTheDocument();
        const glance = await screen.findByRole("region", { name: "T4 at a glance" });
        await waitFor(() => expect(within(glance).getByText("241 s")).toBeInTheDocument());
        expect(within(glance).getByText("pgreplica01-test01")).toBeInTheDocument();
        expect(within(glance).getAllByText("Standard_D4ds_v5")).toHaveLength(2);
        const found = screen.getByRole("region", { name: "What the notebook found" });
        expect(within(found).getAllByRole("listitem")).toHaveLength(3);
    });

    it("explains a PostgreSQL page without a capture yet", async () => {
        renderWithApp(<EstatePage />, { view: { page: "estate", target: "T4" }, client: fakeQueryClient({ "postgres-series": [], "postgres-findings": [] }) });
        expect(await screen.findByText("No PostgreSQL history yet")).toBeInTheDocument();
        expect(screen.getByText(/A session's end saves T4's and its read replica's Azure Monitor metrics/)).toBeInTheDocument();
    });
});

describe("Incidents", () => {
    it("selects the newest incident, compares it with its baseline, replays it, and shows the loop from signal to fix", async () => {
        const { client } = renderWithApp(<IncidentsPage />);
        expect(await screen.findByRole("heading", { name: "Replay: T3 IO pressure" })).toBeInTheDocument();
        expect(await screen.findByRole("button", { name: "Play" })).toBeInTheDocument();
        const loop = await screen.findByRole("list", { name: "The Database Agent loop" });
        expect(await within(loop).findByText("The plan regressed at 10:03 UTC; the run forced the last good plan through Query Store at 10:26 UTC, the documented response.")).toBeInTheDocument();
        expect(within(loop).getByText(/^T3's CPU fell from 84(\.0)? ?% before the response to 22(\.0)? ?% after it\.$/)).toBeInTheDocument();
        expect(within(loop).getByRole("link", { name: "The agent's issue in Database Hub" })).toHaveAttribute("target", "_blank");
        await waitFor(() => expect(client.ran).toEqual(expect.arrayContaining(["incident-windows", "replay-T3", "spotlight-T3", "scenario-runs", "agent-loop"])));
    });

    it("falls back to the session's message for the response before a beat's finding exists", async () => {
        renderWithApp(<IncidentsPage />, { client: fakeQueryClient({ "agent-loop": [] }) });
        const loop = await screen.findByRole("list", { name: "The Database Agent loop" });
        expect(await within(loop).findByText(/^Session abcd1234's Database Agent beat: the plan regresses at 10:03 UTC; the run's response forces the last good plan at 10:26 UTC\.$/)).toBeInTheDocument();
    });

    it("selects another incident from the timeline", async () => {
        const { setView } = renderWithApp(<IncidentsPage />);
        fireEvent.click(await screen.findByRole("button", { name: /^T2 IO pressure, 20 Oct 20:00 UTC/ }));
        expect(setView).toHaveBeenCalledWith({ incident: "detected:T2:io:1", replay: null });
    });

    it("says so when there is no incident", async () => {
        renderWithApp(<IncidentsPage />, { client: fakeQueryClient({ "incident-windows": [] }) });
        expect(await screen.findByText("No incident window in this period")).toBeInTheDocument();
    });
});

describe("Database Agent prompts", () => {
    const writeText = vi.fn(async (text: string) => {
        void text;
    });

    beforeEach(() => {
        writeText.mockClear();
        vi.stubGlobal("isSecureContext", true);
        Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    });

    afterEach(() => {
        Reflect.deleteProperty(navigator, "clipboard");
    });

    it("builds the selected window's prompts from its numbers, copies one, and opens Database Hub in a new tab", async () => {
        const { notify } = renderWithApp(<IncidentsPage />);
        const card = await screen.findByRole("region", { name: "Investigate with the Database Agent" });
        expect(
            await within(card).findByText(
                /^On T3 \(Azure SQL Database azuresql01-test01\/ContosoCare\) between 10:00 and 11:00 UTC on 2026-10-21, Buffer IO \(PAGEIOLATCH\) waits peaked at 60\.0 s per 15-minute bin and averaged about 6 times the baseline/,
            ),
        ).toBeInTheDocument();
        expect(within(card).getByText("Preview")).toBeInTheDocument();
        expect(within(card).getByText(/The agent proposes; you approve each action/)).toBeInTheDocument();
        expect(within(card).getByText(/Investigation only: this app never runs anything/)).toBeInTheDocument();

        fireEvent.click(within(card).getByRole("button", { name: "Copy prompt 1: What caused it" }));
        await waitFor(() => expect(notify).toHaveBeenCalledWith("Prompt copied: paste it into the Database Agent", "success"));
        expect(writeText).toHaveBeenCalledWith(expect.stringMatching(/^On T3 .+ Don't apply anything; propose only\.$/));
        for (const a of within(card).getAllByRole("link", { name: /open Database Hub/i })) {
            expect(a).toHaveAttribute("href", "https://app.fabric.microsoft.com/workloads/fdh/databaseHub");
            expect(a).toHaveAttribute("target", "_blank");
            expect(a).toHaveAttribute("rel", "noopener noreferrer");
        }
    });

    it("asks the in-app Copilot instead, with the prompt", async () => {
        const { copilot } = renderWithApp(<IncidentsPage />);
        const card = await screen.findByRole("region", { name: "Investigate with the Database Agent" });
        fireEvent.click(await within(card).findByRole("button", { name: "Ask Copilot prompt 1: What caused it" }));
        expect(vi.mocked(copilot.ask).mock.calls[0][0]).toMatchObject({ title: "What caused it", visualId: "incidents.agent", prompt: expect.stringMatching(/^On T3 /) });
    });

    it("switches to the Copilot CLI and VS Code fallback and remembers the choice", async () => {
        renderWithApp(<IncidentsPage />);
        const card = await screen.findByRole("region", { name: "Investigate with the Database Agent" });
        fireEvent.click(within(card).getByRole("button", { name: "Copilot CLI · VS Code" }));
        expect(await within(card).findByText(/^Using the telemetry agent instructions, write a KQL query on SqlServerStorageIO/)).toBeInTheDocument();
        expect(window.localStorage.getItem("dbhub-insights.agent-surface.v1")).toBe("skills");
    });
});

describe("Performance", () => {
    it("charts the chosen signal per target, the waits, the distribution, and the hours", async () => {
        renderWithApp(<PerformancePage />);
        expect(await screen.findByRole("heading", { name: "CPU per target" })).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Wait time" }));
        expect(await screen.findByRole("heading", { name: "Wait time per target" })).toBeInTheDocument();
        expect(screen.getByRole("table", { name: "Wait time by UTC hour of day and target" })).toBeInTheDocument();
        expect(await screen.findByRole("table", { name: "Wait time: distribution per target" })).toBeInTheDocument();
    });
});

describe("Findings", () => {
    it("files each finding under its category, and points security to Database Hub's live view", async () => {
        renderWithApp(<FindingsPage />);
        const grid = await screen.findByRole("table", { name: "Findings" });
        await waitFor(() => expect(within(grid).getByText("Auditing is off on arcsql01")).toBeInTheDocument());
        fireEvent.click(screen.getByRole("tab", { name: /^Security \(1\)/ }));
        expect(screen.getByRole("heading", { name: "Security posture, live in Database Hub" })).toBeInTheDocument();
        expect(screen.getByRole("link", { name: "Open Database Hub, then Security" })).toHaveAttribute("target", "_blank");
        expect(within(screen.getByRole("table", { name: "Findings" })).getAllByRole("row")).toHaveLength(2);
        fireEvent.click(screen.getByRole("tab", { name: /^Availability/ }));
        expect(await screen.findByText(/^Read replica lag on pgreplica01-test01 peaked at 241\.4 s/)).toBeInTheDocument();
    });

    it("names T2's SQL Server instance on Optimization, whose migration assessment Database Hub shows live", async () => {
        renderWithApp(<FindingsPage />);
        fireEvent.click(await screen.findByRole("tab", { name: /^Optimization/ }));
        const panel = screen.getByRole("region", { name: "Optimization insights, live in Database Hub" });
        expect(await within(panel).findByText(/T2's SQL Server instance arcsql01 shows as "migration assessment ready"/)).toBeInTheDocument();
        expect(within(panel).getByRole("link", { name: "Open Database Hub, then Optimization" })).toHaveAttribute("rel", "noopener noreferrer");
        expect(screen.getByText(/^From the history, a fallback for Database Hub's live view/)).toBeInTheDocument();
    });
});

describe("Readiness", () => {
    it("shows the open checks worst first with their next steps", async () => {
        renderWithApp(<ReadinessPage />);
        const grid = await screen.findByRole("table", { name: "Validation checks" });
        await waitFor(() => expect(within(grid).getByText("Ask a Fabric admin.")).toBeInTheDocument());
        expect(within(grid).getAllByRole("row").slice(1).map((r) => r.querySelector("code")?.textContent)).toEqual(["fabric-hub-setting", "t1-telemetry"]);
        fireEvent.click(screen.getByRole("tab", { name: /^All/ }));
        expect(within(screen.getByRole("table", { name: "Validation checks" })).getByText("t3-telemetry")).toBeInTheDocument();
    });
});

describe("Trends", () => {
    it("compares the newest week with the week before, per target", async () => {
        renderWithApp(<TrendsPage />, { view: { window: "30d" } });
        const grid = await screen.findByRole("table", { name: "Week over week" });
        await waitFor(() => expect(within(grid).getAllByRole("row")).toHaveLength(3));
        expect(within(grid).getByText("T3 · Azure SQL Database")).toBeInTheDocument();
    });
});

describe("Manage", () => {
    it("is read-only with the reason, and still says exactly what an action would do", async () => {
        renderWithApp(<ManagePage />);
        expect(await screen.findByText("Read-only for you.")).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Start a session…" }));
        const dialog = await screen.findByRole("dialog", { name: "Start a 90-minute session" });
        expect(within(dialog).getByText(/Ends after 90 minutes: saves T4's metrics, deletes the read replica/)).toBeInTheDocument();
        expect(within(dialog).getByText(/MODE = "session"/)).toBeInTheDocument();
        expect(within(dialog).getByRole("button", { name: "Confirm" })).toHaveAttribute("aria-disabled", "true");
    });

    it("lets an operator confirm a bounded action", async () => {
        const { notify } = renderWithApp(<ManagePage />, { manage: { canRun: true, reason: "" } });
        fireEvent.click(await screen.findByRole("button", { name: "Stop now…" }));
        const dialog = await screen.findByRole("dialog", { name: "Stop now" });
        fireEvent.click(within(dialog).getByRole("button", { name: "Confirm" }));
        expect(notify).toHaveBeenCalledWith("Stop now: sent to the session control", "success");
    });

    it("lists what the control ran", async () => {
        renderWithApp(<ManagePage />);
        expect(await screen.findByText(/^Session abcd1234's Database Agent beat: the plan regresses at 10:03 UTC/)).toBeInTheDocument();
    });
});

describe("Live views", () => {
    it("passes the connector check and opens every link in a new tab", async () => {
        renderWithApp(<LinksPage />);
        expect(await screen.findByTestId("probe-ok")).toHaveTextContent("✓ Connector check passed: 12 validation checks, 2,293 telemetry rows, and 4 incident windows");
        for (const a of screen.getAllByRole("link", { name: /open in a new tab/i })) {
            expect(a).toHaveAttribute("target", "_blank");
            expect(a).toHaveAttribute("rel", "noopener noreferrer");
        }
        expect(screen.getByRole("link", { name: "Open in Fabric" })).toHaveAttribute("href", expect.stringMatching(/\/groups\/[0-9a-f-]+\/appbackends\/[0-9a-f-]+$/));
        expect(FIXTURES["connector-check"]).toHaveLength(1);
    });
});
