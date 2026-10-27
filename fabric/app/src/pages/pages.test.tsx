import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import EstatePage from "@/pages/EstatePage";
import IncidentsPage from "@/pages/IncidentsPage";
import LinksPage from "@/pages/LinksPage";
import ReadinessPage from "@/pages/ReadinessPage";
import { fakeQueryClient, renderWithApp } from "@/test/render";

describe("Estate page", () => {
    it("renders the model's headline, insights, the constellation, and the findings feed", async () => {
        const { client } = renderWithApp(<EstatePage />);
        expect(await screen.findByText(/3 of 3 SQL targets sent telemetry/)).toBeInTheDocument();
        expect(await screen.findByText(/T3 carries \d+ % of the estate's wait time/)).toBeInTheDocument();
        expect(screen.getByRole("heading", { name: "Estate constellation" })).toBeInTheDocument();
        expect(await screen.findByText("Buffer IO waits rose sharply")).toBeInTheDocument();
        expect(screen.getByRole("button", { name: /T1 · SQL Server on an Azure VM\. No findings/ })).toBeInTheDocument();
        expect(client.ran).toEqual(expect.arrayContaining(["estate-targets", "signals-per-bin", "findings-latest", "waits-by-category", "headlines"]));
    });

    it("selects a target from the constellation with the keyboard", async () => {
        renderWithApp(<EstatePage />);
        const t3 = await screen.findByRole("button", { name: /T3 · Azure SQL Database\. Worst finding: Warning/ });
        fireEvent.keyDown(t3, { key: "Enter" });
        const detail = screen.getByRole("region", { name: "Selected target" });
        expect(within(detail).getByRole("heading", { name: "T3 · Azure SQL Database" })).toBeInTheDocument();
        expect(within(detail).getByText("97.5 %", { exact: false })).toBeInTheDocument();
    });

    it("shows a plain-language error when a query fails", async () => {
        renderWithApp(<EstatePage />, { client: fakeQueryClient({ "estate-targets": new Error("Fabric refused the query for this account.") }) });
        expect(await screen.findByText(/Fabric refused the query for this account/)).toBeInTheDocument();
    });
});

describe("Incidents page", () => {
    it("picks the newest incident, compares it with its baseline, and offers the replay", async () => {
        const { client } = renderWithApp(<IncidentsPage />);
        expect(await screen.findByRole("heading", { name: "Replay: T3 IO pressure" })).toBeInTheDocument();
        expect(await screen.findByText(/T3 Buffer IO \(PAGEIOLATCH\) waits ran at/)).toBeInTheDocument();
        expect(screen.getByRole("button", { name: /Play/ })).toBeInTheDocument();
        await waitFor(() => expect(client.ran).toEqual(expect.arrayContaining(["incident-windows", "waits-by-category", "replay-T3", "spotlight-T3"])));
    });

    it("says so when there is no incident", async () => {
        renderWithApp(<IncidentsPage />, { client: fakeQueryClient({ "incident-windows": [] }) });
        expect(await screen.findByText(/No incident window in this period/)).toBeInTheDocument();
    });
});

describe("Readiness page", () => {
    it("shows the dial, the coverage, and every check worst first with its next step", async () => {
        renderWithApp(<ReadinessPage />);
        expect(await screen.findByText("Ask a Fabric admin.")).toBeInTheDocument();
        const list = screen.getAllByRole("listitem").filter((li) => li.querySelector("code"));
        expect(list.map((li) => li.querySelector("code")?.textContent)).toEqual(["fabric-hub-setting", "t1-telemetry", "t3-telemetry"]);
        expect(screen.getByText("1 of 3 applicable pass")).toBeInTheDocument();
    });

    it("filters the checks by area from the rings", async () => {
        renderWithApp(<ReadinessPage />);
        fireEvent.click(await screen.findByRole("button", { name: /Area Telemetry/ }));
        expect(screen.queryByText("fabric-hub-setting")).not.toBeInTheDocument();
        expect(screen.getByText("t1-telemetry")).toBeInTheDocument();
    });
});

describe("Live links page", () => {
    it("passes the connector check and opens every link in a new tab", async () => {
        renderWithApp(<LinksPage />);
        expect(await screen.findByTestId("probe-ok")).toHaveTextContent("✓ Connector check passed: 12 validation checks, 2,293 telemetry rows, and 4 incident windows");
        const opens = screen.getAllByRole("link", { name: /Open in a new tab/ });
        expect(opens).toHaveLength(1);
        for (const a of [...opens, screen.getByRole("link", { name: "Open in Fabric" })]) {
            expect(a).toHaveAttribute("target", "_blank");
            expect(a).toHaveAttribute("rel", "noopener noreferrer");
        }
        expect(screen.getByRole("link", { name: "Open in Fabric" })).toHaveAttribute("href", expect.stringMatching(/\/groups\/[0-9a-f-]+\/appbackends\/[0-9a-f-]+$/));
        expect(screen.getByText(/run \.\/scripts\/configure-fabric\.ps1 -ImportDashboard/)).toBeInTheDocument();
    });
});

describe("Database Agent prompts", () => {
    const writeText = vi.fn(async (text: string) => {
        void text;
    });

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
        writeText.mockClear();
        vi.stubGlobal("localStorage", memoryStorage());
        vi.stubGlobal("isSecureContext", true);
        Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    });

    afterEach(() => {
        vi.unstubAllGlobals();
        Reflect.deleteProperty(navigator, "clipboard");
    });

    it("builds the selected window's prompts from its numbers, copies them, and opens Database Hub in a new tab", async () => {
        const { notify } = renderWithApp(<IncidentsPage />);
        const card = await screen.findByRole("region", { name: "Investigate with the Database Agent" });
        expect(
            await within(card).findByText(
                /^On T3 \(Azure SQL Database azuresql01-test01\/ContosoCare\) between 10:00 and 11:00 UTC on 2026-10-21, Buffer IO \(PAGEIOLATCH\) waits peaked at 60\.0 s per 15-minute bin and averaged about 6 times the baseline \(10\.0 s per 15-minute bin in the 30 minutes before\)\. What caused it/,
            ),
        ).toBeInTheDocument();
        expect(within(card).getByText("Preview")).toBeInTheDocument();
        expect(within(card).getByText(/The agent proposes; you approve each action/)).toBeInTheDocument();
        expect(within(card).getByText(/Investigation only: this app never runs anything/)).toBeInTheDocument();
        expect(within(card).getByText("Paste it into the Database Agent")).toBeInTheDocument();

        fireEvent.click(within(card).getByRole("button", { name: "Copy prompt 1: What caused it" }));
        await waitFor(() => expect(notify).toHaveBeenCalledWith("Prompt copied: paste it into the Database Agent"));
        expect(writeText).toHaveBeenCalledWith(expect.stringMatching(/^On T3 .+ Don't apply anything; propose only\.$/));

        const hubLinks = within(card).getAllByRole("link", { name: /open Database Hub/i });
        expect(hubLinks).toHaveLength(5);
        for (const a of hubLinks) {
            expect(a).toHaveAttribute("href", "https://app.fabric.microsoft.com/workloads/fdh/databaseHub");
            expect(a).toHaveAttribute("target", "_blank");
            expect(a).toHaveAttribute("rel", "noopener noreferrer");
        }
        // jsdom can't open a tab; keep the click's own handler (the copy) and drop the navigation.
        card.addEventListener("click", (event) => event.preventDefault());
        fireEvent.click(within(card).getByRole("link", { name: "Copy prompt 2 and open Database Hub in a new tab" }));
        await waitFor(() => expect(notify).toHaveBeenCalledWith("Prompt copied: paste it into the Database Agent in the new tab"));
        expect(writeText).toHaveBeenLastCalledWith(expect.stringMatching(/^On T3 .+ changed at the same time as the Buffer IO \(PAGEIOLATCH\) waits\?/));
    });

    it("switches every panel to the Copilot CLI and VS Code fallback, and remembers the choice", async () => {
        renderWithApp(<IncidentsPage />);
        const card = await screen.findByRole("region", { name: "Investigate with the Database Agent" });
        fireEvent.click(within(card).getByRole("button", { name: "Copilot CLI · VS Code" }));
        expect(
            await within(card).findByText(/^Using the telemetry agent instructions, write a KQL query on SqlServerStorageIO for azuresql01-test01\/ContosoCare in resource group rg-dbhub-test from 2026-10-21T10:00Z to 2026-10-21T11:00Z\./),
        ).toBeInTheDocument();
        expect(within(card).queryByRole("link", { name: /open Database Hub/i })).not.toBeInTheDocument();
        expect(window.localStorage.getItem("dbhub-insights.agent-surface.v1")).toBe("skills");
    });

    it("asks about any window from the ribbon or the replay in a dialog that Esc closes", async () => {
        const { setView } = renderWithApp(<IncidentsPage />);
        fireEvent.click(await screen.findByRole("button", { name: /^Ask the Database Agent about T2 IO pressure/ }));
        expect(setView).toHaveBeenCalledWith({ incident: "detected:T2:io:1", replay: null });
        const dialog = await screen.findByRole("dialog", { name: "Investigate with the Database Agent" });
        expect(within(dialog).getAllByRole("button", { name: /^Copy prompt/ })).toHaveLength(4);
        fireEvent.keyDown(document, { key: "Escape" });
        await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());

        fireEvent.click(screen.getByRole("button", { name: "Ask the agent" }));
        expect(await screen.findByRole("dialog", { name: "Investigate with the Database Agent" })).toBeInTheDocument();
        fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Close" }));
        await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    });

    it("offers the estate prompt library on the Estate page", async () => {
        renderWithApp(<EstatePage />);
        const card = await screen.findByRole("region", { name: "Ask the Database Agent" });
        expect(
            await within(card).findByText(
                /^Summarize the health of the SQL resources in resource group rg-dbhub-test: T1 \(SQL Server on an Azure VM sqlvm01\), T2 \(Arc-enabled SQL Server arcsql01\), and T3 \(Azure SQL Database azuresql01-test01\/ContosoCare\)\./,
            ),
        ).toBeInTheDocument();
        expect(within(card).getAllByRole("button", { name: /^Copy prompt/ })).toHaveLength(4);
        expect(within(card).getByText("What changed since the baseline")).toBeInTheDocument();
    });

    it("starts the Readiness page's library with telemetry coverage", async () => {
        renderWithApp(<ReadinessPage />);
        const card = await screen.findByRole("region", { name: "Ask the Database Agent" });
        expect(within(card).getAllByRole("button", { name: /^Copy prompt/ })).toHaveLength(5);
        expect(within(card).getByRole("button", { name: "Copy prompt 1: Telemetry coverage" })).toBeInTheDocument();
    });
});
