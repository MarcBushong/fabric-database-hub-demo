import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { QueryClientContext } from "@/data/use-query";
import type { QueryClient } from "@/data/query-client";
import { CopilotDock } from "./CopilotDock";
import { CopilotProvider } from "./CopilotProvider";
import { COSMOS_PROBE_DAX } from "./starters";
import { useCopilot, useCopilotAccount, useCopilotDock } from "./use-copilot";

// Built at run time so secret scanners never see a token-shaped literal.
const fakeToken = () => ["gho", "D".repeat(36)].join("_");
const RELAY = "https://relay.example";

class FakeSocket {
    static last: FakeSocket | null = null;
    /** When set, the relay refuses the start with this fatal error. */
    static startError: { code: string; message: string } | null = null;
    readyState = 0;
    closed = false;
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
        if (message.type === "start") {
            if (FakeSocket.startError) this.emit({ type: "error", ...FakeSocket.startError, fatal: true });
            else this.emit({ type: "ready", sessionId: "ask-1", model: null, login: "octo", plan: "enterprise" });
        }
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
        this.closed = true;
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

type Route = unknown | ((init?: RequestInit) => Response);

function fetchStub(routes: Record<string, Route>) {
    return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        const key = Object.keys(routes).find((path) => url === `${RELAY}${path}`);
        if (!key) return new Response("{}", { status: 404 });
        const route = routes[key];
        if (typeof route === "function") return (route as (init?: RequestInit) => Response)(init);
        return new Response(JSON.stringify(route), { status: 200, headers: { "Content-Type": "application/json" } });
    });
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const SESSION = "dbhub-insights.github.v1";
const HOUR = 60 * 60 * 1000;
/** A sign-in from 9 hours ago: its 8-hour token has expired, and its 6-month refresh token still works. */
const signedInNineHoursAgo = () => ({ accessToken: fakeToken(), expiresAt: Date.now() - HOUR, refreshToken: ["ghr", "R".repeat(36)].join("_"), refreshExpiresAt: Date.now() + 170 * 24 * HOUR, login: "octo" });

/** What the history model's T5 probe answers: 1 once the lakehouse holds T5's (Azure Cosmos DB) metrics. */
let hasCosmos = 0;
const queryClient: QueryClient = {
    run: vi.fn(async (spec) => ({ spec, columns: [], rows: spec.dax === COSMOS_PROBE_DAX ? [{ HasCosmos: hasCosmos }] : [{ CpuPct: 88.2 }], requestId: "q", fetchedAt: new Date(0), provenance: "history" as const })),
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
    hasCosmos = 0;
    FakeSocket.startError = null;
    vi.mocked(queryClient.run).mockClear();
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
        const hardest = await screen.findByRole("button", { name: "Which target worked hardest this week?" });
        await waitFor(() => expect(queryClient.run).toHaveBeenCalledWith(expect.objectContaining({ dax: COSMOS_PROBE_DAX })));
        await act(async () => undefined);
        expect(screen.queryByRole("button", { name: "Was Cosmos DB throttled?" })).not.toBeInTheDocument();
        fireEvent.click(hardest);
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

    it("offers T5's starter once the history holds T5's metrics, asking the history model once", async () => {
        hasCosmos = 1;
        window.localStorage.setItem("dbhub-insights.github.v1", JSON.stringify({ accessToken: fakeToken(), expiresAt: null, refreshToken: null, refreshExpiresAt: null, login: "octo" }));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/user": { login: "octo", name: null, avatarUrl: null },
                "/auth/copilot": { ok: true, login: "octo", plan: "enterprise" },
            }),
        );
        const run = vi.mocked(queryClient.run);
        renderDock();
        expect(await screen.findByRole("button", { name: "Was Cosmos DB throttled?" })).toBeInTheDocument();
        expect(run.mock.calls.filter(([spec]) => spec.dax === COSMOS_PROBE_DAX)).toHaveLength(1);
    });

    it("keeps the viewer signed in 9 hours after sign-in: it renews before asking GitHub who the token is (security review, 2026-11-19)", async () => {
        const renewed = ["gho", "E".repeat(36)].join("_");
        window.localStorage.setItem(SESSION, JSON.stringify(signedInNineHoursAgo()));
        const asked: string[] = [];
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/refresh": () => json({ status: "ok", accessToken: renewed, expiresIn: 28800, refreshToken: ["ghr", "S".repeat(36)].join("_"), refreshTokenExpiresIn: 15552000 }),
                "/auth/user": (init?: RequestInit) => {
                    const sent = String(new Headers(init?.headers).get("Authorization")).replace(/^Bearer /, "");
                    asked.push(sent);
                    return sent === renewed ? json({ login: "octo", name: null, avatarUrl: null }) : json({ error: "github", message: "GitHub didn't accept the sign-in any more. Sign in to GitHub again." }, 401);
                },
                "/auth/copilot": { ok: true, login: "octo", plan: "enterprise" },
            }),
        );
        renderDock();
        await waitFor(() => expect(screen.getByTestId("account")).toHaveTextContent("signed-in octo Copilot Enterprise"));
        expect(asked).toEqual([renewed]);
        expect(JSON.parse(window.localStorage.getItem(SESSION) ?? "{}")).toMatchObject({ accessToken: renewed, login: "octo" });
    });

    it("keeps the sign-in when renewing it fails on the way (security review, 2026-11-19)", async () => {
        const session = signedInNineHoursAgo();
        window.localStorage.setItem(SESSION, JSON.stringify(session));
        const stub = fetchStub({
            "/healthz": { ok: true, version: "t", signIn: "device" },
            "/auth/refresh": () => json({ error: "relay_error", message: "The relay couldn't reach GitHub. Try again." }, 502),
        });
        vi.stubGlobal("fetch", stub);
        renderDock();
        await waitFor(() => expect(stub.mock.calls.some(([url]) => String(url).endsWith("/auth/refresh"))).toBe(true));
        await act(async () => undefined);
        expect(JSON.parse(window.localStorage.getItem(SESSION) ?? "null")).toEqual(session);
        expect(screen.getByTestId("account")).toHaveTextContent("signed-in octo");
    });

    it("follows another tab: its sign-out signs this tab out too (security review, 2026-11-19)", async () => {
        window.localStorage.setItem(SESSION, JSON.stringify({ accessToken: fakeToken(), expiresAt: null, refreshToken: null, refreshExpiresAt: null, login: "octo" }));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/user": { login: "octo", name: null, avatarUrl: null },
                "/auth/copilot": { ok: true, login: "octo", plan: "enterprise" },
            }),
        );
        renderDock();
        await waitFor(() => expect(screen.getByTestId("account")).toHaveTextContent("signed-in octo"));
        window.localStorage.removeItem(SESSION);
        await act(async () => {
            window.dispatchEvent(new StorageEvent("storage", { key: SESSION }));
        });
        expect(screen.getByTestId("account")).toHaveTextContent("signed-out");
    });

    it("closes the socket of a start the relay refused, without pinging it (security review, 2026-11-19)", async () => {
        FakeSocket.startError = { code: "session_failed", message: "Copilot couldn't start: the runtime is busy." };
        window.localStorage.setItem(SESSION, JSON.stringify({ accessToken: fakeToken(), expiresAt: null, refreshToken: null, refreshExpiresAt: null, login: "octo" }));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/user": { login: "octo", name: null, avatarUrl: null },
                "/auth/copilot": { ok: true, login: "octo", plan: "enterprise" },
            }),
        );
        renderDock();
        fireEvent.click(await screen.findByRole("button", { name: "Which target worked hardest this week?" }));
        expect(await screen.findByText(/the runtime is busy/)).toBeInTheDocument();
        const socket = FakeSocket.last!;
        expect(socket.closed).toBe(true);
        expect(socket.sent.map((m) => m.type)).toEqual(["start"]);
    });

    it("doesn't send for an account that can't use Copilot here (security review, 2026-11-19)", async () => {
        window.localStorage.setItem(SESSION, JSON.stringify({ accessToken: fakeToken(), expiresAt: null, refreshToken: null, refreshExpiresAt: null, login: "octo" }));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/user": { login: "octo", name: null, avatarUrl: null },
                "/auth/copilot": { ok: false, login: "octo", plan: null, message: "This GitHub account can't use GitHub Copilot here." },
            }),
        );
        renderDock();
        expect(await screen.findByText("This GitHub account can't use Copilot here")).toBeInTheDocument();
        expect(screen.getByRole("textbox", { name: "Message Copilot" })).toBeDisabled();
        expect(screen.getByRole("button", { name: "Which target worked hardest this week?" })).toBeDisabled();
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
