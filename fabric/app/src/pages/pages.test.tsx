import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
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
        expect(ctx.rows?.map((r) => r.target)).toEqual(["T1", "T2", "T3", "T4", "T5"]);
        expect(ctx.dax).toMatch(/^\/\/ Estate: key signals per target\nEVALUATE/);
        expect(ctx.asOf).toBe("2026-10-21T20:30:00.000Z");
    });

    it("shows what Database Hub says right now, live, and opens its security checks", async () => {
        const { navigate } = renderWithApp(<OverviewPage />, { live: "sample" });
        const live = await screen.findByRole("region", { name: "Live now" });
        await waitFor(() => expect(within(live).getByRole("button", { name: /^Resources in Database Hub: 6\./ })).toBeInTheDocument());
        expect(within(live).getByText("Live · as of 21 Oct 21:00 UTC")).toBeInTheDocument();
        expect(within(live).getByRole("button", { name: /^Cosmos DB, last 24 hours: 100(\.0)? ?%\./ })).toBeInTheDocument();
        fireEvent.click(within(live).getByRole("button", { name: /^Security warnings: 2\./ }));
        expect(navigate).toHaveBeenCalledWith("findings", { category: "security" });
    });

    it("says in one line when nothing is read live, with a neutral badge and one period per sentence", async () => {
        renderWithApp(<OverviewPage />);
        const line = await screen.findByText(/^The live estate function isn't deployed in this app\. Every page shows the history; Database Hub has the live view\.$/);
        expect(line.textContent).not.toMatch(/\.\./);
        expect(within(line).getByText("Live · unavailable")).toHaveClass("provenance-off");
        expect(screen.queryByText(/^Live$/)).not.toBeInTheDocument();
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

    it("shows on T2's page whether it's ready to migrate, live; other targets have no migration card", async () => {
        renderWithApp(<EstatePage />, { view: { page: "estate", target: "T2" }, live: "sample" });
        const card = await screen.findByRole("region", { name: "Ready to migrate: arcsql01" });
        expect(within(card).getByText(/^Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database\.$/)).toBeInTheDocument();
        cleanup();
        renderWithApp(<EstatePage />, { view: { page: "estate", target: "T1" }, live: "sample" });
        expect(await screen.findByRole("heading", { level: 1, name: /^T1 · / })).toBeInTheDocument();
        expect(screen.queryByRole("region", { name: /migrat/i })).not.toBeInTheDocument();
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

    it("shows T5's normalized RU with its throttling episode, its 429s, and its recovery, and asks why it hit 100 %", async () => {
        const { copilot, client } = renderWithApp(<EstatePage />, { view: { page: "estate", target: "T5" } });
        expect(await screen.findByRole("heading", { level: 1, name: "T5 · Azure Cosmos DB" })).toBeInTheDocument();
        const glance = await screen.findByRole("region", { name: "T5 at a glance" });
        await waitFor(() => expect(within(glance).getByText("cosmos01-test01")).toBeInTheDocument());
        expect(within(glance).getByText("1,560")).toBeInTheDocument();
        expect(within(glance).getByText(/^20\.2 % of 7,710 requests$/)).toBeInTheDocument();
        expect(within(glance).getByText("Recovered")).toBeInTheDocument();
        expect(within(glance).getByText(/400 RU\/s provisioned/)).toBeInTheDocument();
        const chart = screen.getByRole("region", { name: "Normalized RU, and when it throttled" });
        await waitFor(() => expect(chart.querySelectorAll(".chart-band rect")).toHaveLength(1));
        fireEvent.click(within(glance).getByRole("button", { name: "Ask why" }));
        expect(vi.mocked(copilot.ask).mock.calls[0][0].anomaly).toMatchObject({ metric: "Normalized RU consumption", target: "T5", value: 100, unit: "%" });
        expect(client.ran).toEqual(expect.arrayContaining(["cosmos-series", "cosmos-findings"]));
    });

    it("explains T5's page without a capture, and leaves T5 out of the inventory when it has no history", async () => {
        const empty = { "cosmos-series": [], "cosmos-findings": [] };
        const { unmount } = renderWithApp(<EstatePage />, { view: { page: "estate", target: "T5" }, client: fakeQueryClient(empty) });
        expect(await screen.findByText("No Cosmos DB history yet")).toBeInTheDocument();
        unmount();
        renderWithApp(<EstatePage />, { client: fakeQueryClient(empty) });
        expect(await screen.findByText("No T5 history yet")).toBeInTheDocument();
        expect(screen.queryByRole("button", { name: /^T5 · Azure Cosmos DB/ })).not.toBeInTheDocument();
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
    it("files each finding under its category, and opens a category in the address", async () => {
        const { setView } = renderWithApp(<FindingsPage />);
        const grid = await screen.findByRole("table", { name: "Findings" });
        await waitFor(() => expect(within(grid).getByText("Auditing is off on arcsql01")).toBeInTheDocument());
        fireEvent.click(screen.getByRole("tab", { name: /^Security \(1\)/ }));
        expect(setView).toHaveBeenCalledWith({ category: "security" });
    });

    it("says why security isn't read live, links to Database Hub, and keeps the history's findings", async () => {
        renderWithApp(<FindingsPage />, { view: { page: "findings", category: "security" } });
        expect(await screen.findByText(/^The live estate function isn't deployed in this app\. The table below is the history's own findings\.$/)).toBeInTheDocument();
        const panel = screen.getByRole("region", { name: "Security posture, live from Database Hub" });
        expect(within(panel).getByRole("link", { name: "Open Database Hub, then Security" })).toHaveAttribute("target", "_blank");
        await waitFor(() => expect(within(screen.getByRole("table", { name: "Findings" })).getAllByRole("row")).toHaveLength(2));
    });

    it("reads security live: the Hub's warnings first, then its recommendations, without repeating a warning", async () => {
        const { copilot } = renderWithApp(<FindingsPage />, { view: { page: "findings", category: "security" }, live: "sample" });
        const grid = await screen.findByRole("table", { name: "Live security checks" });
        await waitFor(() => expect(within(grid).getAllByRole("row")).toHaveLength(6));
        const checks = within(grid).getAllByRole("row").slice(1).map((r) => r.textContent ?? "");
        expect(checks[0]).toMatch(/^Needs attention.*azuresql01-sample\/ContosoCare.*Auditing is disabled$/);
        expect(checks[1]).toMatch(/^Needs attention.*Customer-managed keys.*CMK is not configured for TDE protector$/);
        expect(checks.filter((c) => /ContosoCare.*No customer-managed key/.test(c))).toHaveLength(0);
        expect(checks.filter((c) => /^Recommended/.test(c))).toHaveLength(3);
        expect(screen.getByText("Live · as of 21 Oct 21:00 UTC")).toBeInTheDocument();
        expect(screen.getByRole("button", { name: /^Security · live: 2\./ })).toBeInTheDocument();
        fireEvent.click(within(screen.getByRole("region", { name: "Security posture, live from Database Hub" })).getByRole("button", { name: "Ask Copilot" }));
        const ctx = vi.mocked(copilot.ask).mock.calls[0][0];
        expect(ctx).toMatchObject({ source: "live", asOf: "2026-10-21T21:00:00.000Z", visualId: "findings.live.security", totalRows: 5 });
        expect(ctx.dax).toBeUndefined();
    });

    it("shows T2 ready to migrate, live, with its readiness per Azure SQL target, and never as a Database Hub issue (2026-11-18)", async () => {
        const { copilot } = renderWithApp(<FindingsPage />, { view: { page: "findings", category: "optimization" }, live: "sample" });
        const card = await screen.findByRole("region", { name: "Ready to migrate: arcsql01" });
        expect(within(card).getByText("Ready for Azure SQL Managed Instance and SQL Server on Azure Virtual Machines; not ready for Azure SQL Database.")).toBeInTheDocument();
        expect(within(card).getByRole("list", { name: "Readiness per Azure SQL target" }).textContent).toBe("ReadyAzure SQL Managed InstanceReadySQL Server on Azure Virtual MachinesNot readyAzure SQL DatabaseAsk why");
        expect(within(card).getByText(/assessed by Azure Arc every week; this assessment was uploaded 21 Oct 18:00 UTC/)).toBeInTheDocument();
        expect(within(card).getByText(/^A ready assessment isn't an issue, so Database Hub's issue lists don't show it\./)).toBeInTheDocument();
        expect(within(card).getByRole("link", { name: "arcsql01 in the Azure portal" })).toHaveAttribute("href", expect.stringMatching(/^https:\/\/portal\.azure\.com\/#@0{8}-0{4}-0{4}-0{4}-0{12}\/resource\/subscriptions\/.+\/sqlServerInstances\/arcsql01$/));
        fireEvent.click(within(card).getByRole("button", { name: "Ask Copilot" }));
        expect(vi.mocked(copilot.ask).mock.calls[0][0]).toMatchObject({ prompt: "Which of my servers can move to Azure, and to what?", source: "live", visualId: "migration.readiness", totalRows: 3 });
        fireEvent.click(within(card).getByRole("button", { name: "Ask why" }));
        expect(vi.mocked(copilot.ask).mock.calls[1][0].prompt).toMatch(/^Why isn't arcsql01 ready for Azure SQL Database, and what would make it ready\?/);
        // The optimization checks Database Hub raises: none on this estate, as live.
        expect(await screen.findByText("Database Hub flags nothing here")).toBeInTheDocument();
        expect(document.body.textContent).not.toMatch(/Optimization (view|issues?) (shows|lists) (T2|arcsql01)|migration assessment ready/i);
    });

    it("links T2's migration assessment in the Azure portal when Database Hub isn't read live, and names the path", async () => {
        renderWithApp(<FindingsPage />, { view: { page: "findings", category: "optimization" } });
        const panel = await screen.findByRole("region", { name: "T2's migration assessment" });
        expect(within(panel).getByText(/In the Azure portal, open arcsql01, then, under Migration, select Assessments\.$/)).toBeInTheDocument();
        expect(within(panel).getByText("Live · unavailable")).toHaveClass("provenance-off");
        expect(within(panel).getByRole("link", { name: "arcsql01 in the Azure portal" })).toHaveAttribute("rel", "noopener noreferrer");
        expect(screen.getByText(/^From the history, beside Database Hub's live view/)).toBeInTheDocument();
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

    it("says what fills readiness before any validation run: Run all in NB_DatabaseHub_Control, or the validator by hand", async () => {
        renderWithApp(<ReadinessPage />, { client: fakeQueryClient(NO_VALIDATION_RUN) });
        expect(await screen.findByText("No validation run in the history yet")).toBeInTheDocument();
        expect(screen.getByText(/fills this: once its session runs/)).toHaveTextContent("Run all in NB_DatabaseHub_Control fills this: once its session runs, it runs NB_DatabaseHub_Deployment's read-only checks, which save here.");
        expect(screen.getByText("Or run NB_DatabaseHub_Deployment yourself, in the demo workspace.")).toBeInTheDocument();
    });

    it("keeps Overview's readiness tile blank, with what fills it, while the summary is a row of zeros", async () => {
        renderWithApp(<OverviewPage />, { client: fakeQueryClient(NO_VALIDATION_RUN) });
        expect(await screen.findByRole("button", { name: "Demo readiness: –. Open readiness" })).toBeInTheDocument();
        expect(screen.getByText("Run all in NB_DatabaseHub_Control fills this")).toBeInTheDocument();
        expect(screen.queryByText(/0 failed · 0 manual · 0 warnings/)).not.toBeInTheDocument();
    });
});

// What a new environment's model answers before any validation run (dbhubc5, 2026-11-18): no checks, and a summary row of zeros.
const NO_VALIDATION_RUN = { "readiness-checks": [], "readiness-summary": [{ Checks: 0, Failed: 0, Manual: 0, Warnings: 0, Passed: 0, NotSupported: 0, NotSelected: 0, Readiness: null, RunLabel: null }] };

describe("Trends", () => {
    it("compares the newest week with the week before, per target", async () => {
        renderWithApp(<TrendsPage />, { view: { window: "30d" } });
        const grid = await screen.findByRole("table", { name: "Week over week" });
        await waitFor(() => expect(within(grid).getAllByRole("row")).toHaveLength(3));
        expect(within(grid).getByText("T3 · Azure SQL Database")).toBeInTheDocument();
    });
});

describe("Manage", () => {
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

    it("without the Manage function, copies each request for Run all in the control notebook and opens it", async () => {
        const open = vi.spyOn(window, "open").mockImplementation(() => null);
        const { notify } = renderWithApp(<ManagePage />);
        expect(await screen.findByText("Each action copies its request for the control notebook.")).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Start a session…" }));
        const dialog = await screen.findByRole("dialog", { name: "Start a 90-minute session" });
        expect(within(dialog).getByText(/Ends after 90 minutes: saves T4's metrics, and T5's when it's deployed, deletes the read replica/)).toBeInTheDocument();
        fireEvent.click(within(dialog).getByRole("button", { name: "Copy and open the notebook" }));
        await waitFor(() => expect(writeText).toHaveBeenCalledWith(expect.stringMatching(/\nMODE = "session"\nDURATION_MINUTES = 90\nWAIT_FOR_END = True$/)));
        expect(open).toHaveBeenCalledWith(expect.stringMatching(/^https:\/\//), "_blank", "noopener,noreferrer");
        expect(notify).toHaveBeenCalledWith(expect.stringMatching(/^Copied: paste it into a new cell under the parameters cell/), "success");
        open.mockRestore();
    });

    it("is read-only with the reason for a viewer who isn't an operator", async () => {
        renderWithApp(<ManagePage />, { manage: { mode: "run", canRun: false, reason: "Only the demo's operators send actions from the app.", running: null } });
        expect(await screen.findByText("Read-only for you.")).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Stop now…" }));
        const dialog = await screen.findByRole("dialog", { name: "Stop now" });
        expect(within(dialog).getByRole("button", { name: "Confirm" })).toHaveAttribute("aria-disabled", "true");
        expect(within(dialog).getByText("Only the demo's operators send actions from the app.")).toBeInTheDocument();
    });

    it("lets an operator send a bounded action, then follows its run to how it ended", async () => {
        const send = vi.fn(async () => ({ started: true, jobInstance: "00000000-0000-0000-0000-000000000000", reason: "", requestedBy: "app/ops@contoso.example", copy: false, cancelled: [] }));
        const job = vi.fn(async () => ({ status: "Failed", startedAt: "2026-10-21T20:00:00Z", endedAt: "2026-10-21T20:01:00Z", failureReason: "NotebookFailed: The webhook refused it." }));
        const { notify } = renderWithApp(<ManagePage />, { manage: { mode: "run", canRun: true, reason: "", who: "ops@contoso.example", running: null, send, job } });
        expect(await screen.findByText("You can run these actions, as ops@contoso.example.")).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Start a session…" }));
        const dialog = await screen.findByRole("dialog", { name: "Start a 90-minute session" });
        fireEvent.click(within(dialog).getByRole("button", { name: "Confirm" }));
        await waitFor(() => expect(send).toHaveBeenCalledWith({ action: "session", durationMinutes: 90 }));
        expect(notify).toHaveBeenCalledWith("Start a 90-minute session: NB_DatabaseHub_Control started as app/ops@contoso.example (run 00000000)", "success");
        expect(await screen.findByText(/^Start a 90-minute session: run 00000000 failed at .+: NotebookFailed: The webhook refused it\. Its output is in the notebook's run history\.$/)).toBeInTheDocument();
        expect(job).toHaveBeenCalledWith("00000000-0000-0000-0000-000000000000");
    });

    const running = { id: "00000000-0000-0000-0000-000000000000", status: "InProgress", startedAt: "2026-10-21T20:00:00Z" };
    const inProgress = async () => ({ status: "InProgress", startedAt: "2026-10-21T20:00:00Z", endedAt: null, failureReason: null });

    it("takes one request at a time while the control runs one, and shows that run", async () => {
        const send = vi.fn();
        renderWithApp(<ManagePage />, { manage: { mode: "run", canRun: true, reason: "", who: "ops@contoso.example", running, send, job: vi.fn(inProgress) } });
        expect(await screen.findByText(/^The control's run: run 00000000 is in progress, since /)).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Start a session…" }));
        const dialog = await screen.findByRole("dialog", { name: "Start a 90-minute session" });
        expect(within(dialog).getByText(/^A run of NB_DatabaseHub_Control is in progress, since .+\. The control follows a session that's running instead of starting another: Stop now first, then start a new one\.$/)).toBeInTheDocument();
        expect(within(dialog).getByRole("button", { name: "Confirm" })).toHaveAttribute("aria-disabled", "true");
        expect(send).not.toHaveBeenCalled();
    });

    it("says Stop now cancels the control's run in progress first", async () => {
        renderWithApp(<ManagePage />, { manage: { mode: "run", canRun: true, reason: "", who: "ops@contoso.example", running, send: vi.fn(), job: vi.fn(inProgress) } });
        fireEvent.click(await screen.findByRole("button", { name: "Stop now…" }));
        const dialog = await screen.findByRole("dialog", { name: "Stop now" });
        expect(within(dialog).getByText("Stop now cancels the control's run first.")).toBeInTheDocument();
        expect(within(dialog).getByRole("button", { name: "Confirm" })).not.toHaveAttribute("aria-disabled", "true");
    });

    it("hands a request the function couldn't send over to copy mode, with the reason", async () => {
        const reason = "Fabric didn't start NB_DatabaseHub_Control (HTTP 403, InsufficientPrivileges). Run all in the notebook sends the same request.";
        const send = vi.fn(async () => ({ started: false, jobInstance: "", reason, requestedBy: "app/ops@contoso.example", copy: true, cancelled: [] }));
        const fallBack = vi.fn();
        const { notify } = renderWithApp(<ManagePage />, { manage: { mode: "run", canRun: true, reason: "", who: "ops@contoso.example", running: null, send, fallBack } });
        fireEvent.click(await screen.findByRole("button", { name: "Reset…" }));
        const dialog = await screen.findByRole("dialog", { name: "Reset every running target" });
        fireEvent.click(within(dialog).getByRole("button", { name: "Confirm" }));
        await waitFor(() => expect(fallBack).toHaveBeenCalledWith(reason));
        expect(await within(dialog).findByText("The app couldn't send it.")).toBeInTheDocument();
        expect(within(dialog).getByText(`${reason} Copy it below instead.`)).toBeInTheDocument();
        expect(notify).not.toHaveBeenCalledWith(expect.stringMatching(/wasn't sent/), "error");
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
