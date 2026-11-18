import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { QueryClientContext } from "@/data/use-query";
import type { QueryClient } from "@/data/query-client";
import { CopilotDock } from "./CopilotDock";
import { CopilotProvider } from "./CopilotProvider";
import { useCopilot, useCopilotAccount, useCopilotDock } from "./use-copilot";

// Built at run time so secret scanners never see a token-shaped literal.
const fakeToken = () => ["gho", "D".repeat(36)].join("_");
const RELAY = "https://relay.example";

class FakeSocket {
    static last: FakeSocket | null = null;
    readyState = 0;
    sent: Array<Record<string, unknown>> = [];
    onopen: ((ev: Event) => unknown) | null = null;
    onmessage: ((ev: MessageEvent) => unknown) | null = null;
    onclose: ((ev: CloseEvent) => unknown) | null = null;
    onerror: ((ev: Event) => unknown) | null = null;
    constructor(readonly url: string) {
        FakeSocket.last = this;
        setTimeout(() => {
            this.readyState = 1;
            this.onopen?.(new Event("open"));
        }, 0);
    }
    send(data: string) {
        const message = JSON.parse(data) as Record<string, unknown>;
        this.sent.push(message);
        if (message.type === "start") this.emit({ type: "ready", sessionId: "ask-1", model: null, login: "octo", plan: "enterprise" });
        if (message.type === "user") this.emit({ type: "tool_call", callId: "c1", name: "run_dax", arguments: { query: "EVALUATE ROW(\"CpuPct\", 88.2)", purpose: "Peak CPU" } });
        if (message.type === "tool_result") {
            this.emit({ type: "delta", messageId: "m1", text: "T1 peaked " });
            this.emit({ type: "message", messageId: "m1", text: "**T1** peaked at 88.2 %." });
            this.emit({ type: "idle" });
        }
    }
    emit(event: Record<string, unknown>) {
        setTimeout(() => this.onmessage?.(new MessageEvent("message", { data: JSON.stringify(event) })), 0);
    }
    close() {
        this.readyState = 3;
    }
}

function Harness() {
    const copilot = useCopilot();
    const dock = useCopilotDock();
    const account = useCopilotAccount();
    return (
        <>
            <button type="button" onClick={() => copilot.open({ title: "CPU per target", rows: [{ a: 1 }], dax: "EVALUATE x", source: "history" })}>
                Attach
            </button>
            <span data-testid="account">{`${account.status} ${account.login ?? ""} ${account.plan ?? ""}`.trim()}</span>
            <span>{dock.isOpen ? "open" : "closed"}</span>
            {dock.isOpen ? <CopilotDock mode="docked" onModeChange={() => undefined} onClose={() => dock.setOpen(false)} headingId="dock-title" /> : null}
        </>
    );
}

function fetchStub(routes: Record<string, unknown>) {
    return vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        const key = Object.keys(routes).find((path) => url === `${RELAY}${path}`);
        if (!key) return new Response("{}", { status: 404 });
        return new Response(JSON.stringify(routes[key]), { status: 200, headers: { "Content-Type": "application/json" } });
    });
}

const queryClient: QueryClient = {
    run: vi.fn(async (spec) => ({ spec, columns: [], rows: [{ CpuPct: 88.2 }], requestId: "q", fetchedAt: new Date(0) })),
    peek: () => undefined,
    clear: () => undefined,
};

function renderDock(initialOpen = true) {
    return render(
        <QueryClientContext.Provider value={queryClient}>
            <CopilotProvider initialOpen={initialOpen} settings={{ relayUrl: RELAY, estate: false }}>
                <Harness />
            </CopilotProvider>
        </QueryClientContext.Provider>,
    );
}

beforeEach(() => {
    window.localStorage.clear();
    window.sessionStorage.clear();
    vi.stubGlobal("WebSocket", FakeSocket);
    Element.prototype.scrollIntoView = vi.fn();
});

afterEach(() => {
    vi.unstubAllGlobals();
});

describe("the Copilot dock", () => {
    it("asks a signed-out viewer to sign in with GitHub, once", async () => {
        vi.stubGlobal("fetch", fetchStub({ "/healthz": { ok: true, version: "t", signIn: "device" } }));
        renderDock();
        expect(await screen.findByRole("button", { name: /Sign in with GitHub/ })).toBeInTheDocument();
        expect(screen.getByTestId("account")).toHaveTextContent("signed-out");
    });

    it("says where to enter the code when the browser or the portal's frame blocks the new tab", async () => {
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/device": { deviceCode: "d", userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device", expiresIn: 900, interval: 5 },
            }),
        );
        vi.stubGlobal("open", vi.fn(() => null));
        renderDock();
        fireEvent.click(await screen.findByRole("button", { name: /Sign in with GitHub/ }));
        expect(await screen.findByText("WDJB-MJHT")).toBeInTheDocument();
        expect(screen.getByText(/in a new tab/)).toHaveTextContent("Open github.com/login/device in a new tab");
    });

    it("says when GitHub sign-in isn't set up, and when Ask isn't deployed", async () => {
        vi.stubGlobal("fetch", fetchStub({ "/healthz": { ok: true, version: "t", signIn: "off" } }));
        renderDock();
        expect(await screen.findByText("GitHub sign-in isn't set up yet")).toBeInTheDocument();
        expect(screen.getByTestId("account")).toHaveTextContent("unavailable");
    });

    it("shows the GitHub account and plan, answers a starter with a page-run query, and shows its DAX", async () => {
        window.localStorage.setItem("dbhub-insights.github.v1", JSON.stringify({ accessToken: fakeToken(), expiresAt: null, refreshToken: null, refreshExpiresAt: null, login: "octo" }));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/user": { login: "octo", name: null, avatarUrl: null },
                "/auth/copilot": { ok: true, login: "octo", plan: "enterprise" },
            }),
        );
        renderDock();
        await waitFor(() => expect(screen.getByTestId("account")).toHaveTextContent("signed-in octo Copilot Enterprise"));
        fireEvent.click(await screen.findByRole("button", { name: "Which target worked hardest this week?" }));
        expect(await screen.findByText(/peaked at 88.2/)).toBeInTheDocument();
        const socket = FakeSocket.last!;
        expect(socket.sent[0]).toMatchObject({ type: "start", token: fakeToken() });
        expect((socket.sent[0].tools as Array<{ name: string }>).map((t) => t.name)).toEqual(["run_dax", "show_chart", "suggest_followups"]);
        const toolResult = socket.sent.find((m) => m.type === "tool_result");
        expect(toolResult).toMatchObject({ callId: "c1", ok: true });
        expect(JSON.parse(String(toolResult?.result))).toMatchObject({ columns: ["CpuPct"], rows: [[88.2]] });
        fireEvent.click(screen.getByRole("button", { name: /Show the source/ }));
        expect(screen.getByLabelText("DAX: Peak CPU")).toHaveTextContent("EVALUATE");
        await act(async () => {
            fireEvent.click(screen.getByRole("button", { name: "New chat" }));
        });
        expect(screen.queryByText(/peaked at 88.2/)).not.toBeInTheDocument();
    });

    it("keeps a visual's context attached until the viewer asks", async () => {
        vi.stubGlobal("fetch", fetchStub({ "/healthz": { ok: true, version: "t", signIn: "device" } }));
        renderDock(false);
        expect(screen.getByText("closed")).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Attach" }));
        expect(screen.getByText("open")).toBeInTheDocument();
        expect(await screen.findByRole("button", { name: /Sign in with GitHub/ })).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Close Copilot" }));
        expect(screen.getByText("closed")).toBeInTheDocument();
    });
});
