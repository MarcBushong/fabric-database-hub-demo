import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { CopilotDock } from "./CopilotDock";
import { CopilotProvider } from "./CopilotProvider";
import { useCopilot, useCopilotAccount, useCopilotDock } from "./use-copilot";

function Harness() {
    const copilot = useCopilot();
    const dock = useCopilotDock();
    const account = useCopilotAccount();
    return (
        <>
            <button type="button" onClick={() => copilot.ask({ title: "CPU per target", prompt: "Why did T3 peak?", rows: [{ a: 1 }, { a: 2 }], dax: "EVALUATE\nROW ( \"a\", 1 )", source: "history" })}>
                Ask
            </button>
            <span>{dock.isOpen ? "open" : "closed"}</span>
            <span>{`account ${account.status}`}</span>
            {dock.isOpen ? <CopilotDock mode="docked" onModeChange={() => undefined} onClose={() => dock.setOpen(false)} headingId="dock-title" /> : null}
        </>
    );
}

describe("the Copilot stub", () => {
    it("opens the dock on ask and shows what the entry point attached", () => {
        render(
            <CopilotProvider>
                <Harness />
            </CopilotProvider>,
        );
        expect(screen.getByText("closed")).toBeInTheDocument();
        expect(screen.getByText("account unavailable")).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Ask" }));
        expect(screen.getByText("open")).toBeInTheDocument();
        const panel = screen.getByRole("region", { name: "Copilot" });
        expect(panel).toHaveTextContent("You asked about");
        expect(panel).toHaveTextContent("CPU per target");
        expect(panel).toHaveTextContent("Why did T3 peak?");
        expect(panel).toHaveTextContent("2 rows");
        expect(panel).toHaveTextContent("DAX, 2 lines");
        fireEvent.click(screen.getByRole("button", { name: "Close Copilot" }));
        expect(screen.getByText("closed")).toBeInTheDocument();
    });

    it("does nothing outside a provider", () => {
        render(<Harness />);
        fireEvent.click(screen.getByRole("button", { name: "Ask" }));
        expect(screen.getByText("closed")).toBeInTheDocument();
    });
});
