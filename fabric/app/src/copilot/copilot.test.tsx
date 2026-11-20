import { act, configure, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { QueryClientContext } from "@/data/use-query";
import type { QueryClient } from "@/data/query-client";
import { setLiveEstateReader, useLiveEstate, type EstateAnswer, type EstateReader, type EstateView } from "@/data/live-estate";
import { AccountChips } from "@/shell/AccountChips";
import { CopilotDock } from "./CopilotDock";
import { CopilotProvider } from "./CopilotProvider";
import { COSMOS_PROBE_DAX } from "./starters";
import { useCopilot, useCopilotAccount, useCopilotDock } from "./use-copilot";

// These tests play conversations through several scripted hops, which can take longer than Testing Library's 1-second
// wait on a busy machine (the test timeout is the app's, in vitest.config.ts).
configure({ asyncUtilTimeout: 4000 });

// Built at run time so secret scanners never see a token-shaped literal.
const fakeToken = () => ["gho", "D".repeat(36)].join("_");
const RELAY = "https://relay.example";

// The app's estate function, as the dock reads it (estate.ts), for the live view's tests.
const estateMock = vi.hoisted(() => ({ readEstate: vi.fn() }));
vi.mock("./estate", () => ({ readEstate: estateMock.readEstate }));

// What the pages' live reads answer (useLiveEstate, and so useLiveOff, which the dock follows): data, unless a test
// sets the sentence Database Hub refuses the app with.
let pagesRefusal: string | null = null;
const LIVE_SCOPE = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-test"] };
const pagesReader: EstateReader = async <V extends EstateView>(view: V) =>
    (pagesRefusal
        ? { view, source: ["GET /auth/warnings"], scope: LIVE_SCOPE, data: {}, errors: ["GET /auth/warnings: HTTP 401 Unauthorized"], at: "2026-11-19T22:00:00Z", unavailable: pagesRefusal }
        : { view, source: ["POST /savedView/resources/list"], scope: LIVE_SCOPE, data: { totalCount: 4 }, errors: [], at: "2026-11-19T22:00:00Z" }) as unknown as EstateAnswer<V>;

class FakeSocket {
    static last: FakeSocket | null = null;
    static all: FakeSocket[] = [];
    /** When set, the relay refuses the start with this fatal error. */
    static startError: { code: string; message: string } | null = null;
    /** When set, plays the relay's side of the conversation instead of the default script: it gets each question and tool answer. */
    static script: ((socket: FakeSocket, message: Record<string, unknown>) => void) | null = null;
    /** When set, the relay answers a start only once this resolves: the session is still starting until then. */
    static startGate: Promise<void> | null = null;
    readyState = 0;
    closed = false;
    sent: Array<Record<string, unknown>> = [];
    onopen: ((ev: Event) => unknown) | null = null;
    onmessage: ((ev: MessageEvent) => unknown) | null = null;
    onclose: ((ev: CloseEvent) => unknown) | null = null;
    onerror: ((ev: Event) => unknown) | null = null;
    constructor(readonly url: string) {
        FakeSocket.last = this;
        FakeSocket.all.push(this);
        setTimeout(() => {
            this.readyState = 1;
            this.onopen?.(new Event("open"));
        }, 0);
    }
    send(data: string) {
        const message = JSON.parse(data) as Record<string, unknown>;
        this.sent.push(message);
        if (message.type === "start") {
            const reply = () => {
                if (FakeSocket.startError) this.emit({ type: "error", ...FakeSocket.startError, fatal: true });
                else this.emit({ type: "ready", sessionId: "ask-1", model: null, login: "octo", plan: "enterprise" });
            };
            if (FakeSocket.startGate) void FakeSocket.startGate.then(reply);
            else reply();
        }
        if (FakeSocket.script && (message.type === "user" || message.type === "tool_result")) {
            FakeSocket.script(this, message);
            return;
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
    /** The relay closing the conversation's socket (its session ended). */
    drop() {
        this.readyState = 3;
        this.onclose?.({ code: 1000, reason: "" } as CloseEvent);
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

/** A page's own live read (useLiveEstate), as Overview's and Findings' are, outside the dock. */
function PageRead() {
    const inventory = useLiveEstate("inventory");
    return <span>{inventory.answer ? "page: data" : inventory.loading ? "page: reading" : "page: none"}</span>;
}

/** The app's header (its account chips) and the dock, as the shell places them. */
function ShellHarness() {
    const dock = useCopilotDock();
    return (
        <>
            <AccountChips email={null} onSignOut={() => undefined} />
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

function renderDock(initialOpen = true, estate = false) {
    return render(
        <QueryClientContext.Provider value={queryClient}>
            <CopilotProvider initialOpen={initialOpen} settings={{ relayUrl: RELAY, estate }}>
                <Harness />
            </CopilotProvider>
        </QueryClientContext.Provider>,
    );
}

beforeEach(() => {
    hasCosmos = 0;
    FakeSocket.startError = null;
    FakeSocket.script = null;
    FakeSocket.startGate = null;
    FakeSocket.all = [];
    estateMock.readEstate.mockReset();
    pagesRefusal = null;
    setLiveEstateReader(pagesReader);
    vi.mocked(queryClient.run).mockClear();
    window.localStorage.clear();
    window.sessionStorage.clear();
    vi.stubGlobal("WebSocket", FakeSocket);
    Element.prototype.scrollIntoView = vi.fn();
});

afterEach(() => {
    vi.unstubAllGlobals();
    setLiveEstateReader(null);
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

// R925 (2026-11-19): a live turn ended with its query rows and no answer, silently. Each way the relay can deliver the
// model's text after the rows is scripted here, and so is a model that writes none.
describe("the end of a turn (R925)", () => {
    const ANSWER = "T2 needs attention first: CPU above 90% for 14 minutes.";
    const QUESTION = "How is my estate doing right now?";
    const dax = (callId: string) => ({ type: "tool_call", callId, name: "run_dax", arguments: { query: 'EVALUATE ROW("CpuPct", 88.2)', purpose: "Peak CPU" } });

    function signedIn() {
        window.localStorage.setItem(SESSION, JSON.stringify({ accessToken: fakeToken(), expiresAt: null, refreshToken: null, refreshExpiresAt: null, login: "octo" }));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/user": { login: "octo", name: null, avatarUrl: null },
                "/auth/copilot": { ok: true, login: "octo", plan: "enterprise" },
            }),
        );
    }
    async function ask(question = QUESTION) {
        await waitFor(() => expect(screen.getByTestId("account")).toHaveTextContent("signed-in octo"));
        const box = screen.getByRole("textbox", { name: "Message Copilot" });
        fireEvent.change(box, { target: { value: question } });
        fireEvent.keyDown(box, { key: "Enter" });
    }
    const resultOf = (socket: FakeSocket, callId: string) => socket.sent.find((m) => m.type === "tool_result" && m.callId === callId);
    const follows = (first: HTMLElement, second: HTMLElement) => Boolean(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING);

    it("renders a final answer that comes as a new message after the query rows", async () => {
        FakeSocket.script = (s, m) => {
            if (m.type === "user") s.emit(dax("c1"));
            else {
                s.emit({ type: "message", messageId: "m2", text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock();
        await ask();
        const answer = await screen.findByText(ANSWER);
        expect(follows(screen.getByText("Peak CPU"), answer)).toBe(true);
        expect(screen.queryByText("Copilot didn't write an answer")).not.toBeInTheDocument();
    });

    it("renders an answer that comes only as deltas after the query rows", async () => {
        FakeSocket.script = (s, m) => {
            if (m.type === "user") s.emit(dax("c1"));
            else {
                s.emit({ type: "delta", messageId: "m2", text: "T2 needs attention first: " });
                s.emit({ type: "delta", messageId: "m2", text: "CPU above 90% for 14 minutes." });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock();
        await ask();
        const answer = await screen.findByText(ANSWER);
        expect(follows(screen.getByText("Peak CPU"), answer)).toBe(true);
        await waitFor(() => expect(screen.getByRole("button", { name: /Show the source/ })).toBeInTheDocument());
        expect(screen.queryByText("Copilot didn't write an answer")).not.toBeInTheDocument();
    });

    it("renders the last message when the turn's end arrives before it", async () => {
        FakeSocket.script = (s, m) => {
            if (m.type === "user") s.emit(dax("c1"));
            else {
                s.emit({ type: "idle" });
                s.emit({ type: "message", messageId: "m2", text: ANSWER });
            }
        };
        signedIn();
        renderDock();
        await ask();
        const answer = await screen.findByText(ANSWER);
        expect(follows(screen.getByText("Peak CPU"), answer)).toBe(true);
        expect(screen.queryByText("Copilot didn't write an answer")).not.toBeInTheDocument();
    });

    it("says Copilot didn't write an answer, with Retry, which asks the same conversation and fills the same turn", async () => {
        let questions = 0;
        FakeSocket.script = (s, m) => {
            if (m.type === "user") {
                questions += 1;
                if (questions === 1) {
                    s.emit({ type: "message", messageId: "m1", text: "I'll check the history." });
                    s.emit(dax("c1"));
                } else {
                    s.emit({ type: "message", messageId: "m3", text: ANSWER });
                    s.emit({ type: "idle" });
                }
            } else if (m.callId === "c1") s.emit({ type: "tool_call", callId: "c2", name: "suggest_followups", arguments: { questions: ["Why T2?"] } });
            else if (m.callId === "c2") s.emit({ type: "idle" });
        };
        signedIn();
        renderDock();
        await ask();
        expect(await screen.findByText("Copilot didn't write an answer")).toBeInTheDocument();
        const socket = FakeSocket.last!;
        // The follow-ups' answer reminds Copilot that it hasn't written the answer since its last query.
        expect(String(resultOf(socket, "c2")?.result)).toMatch(/haven't written the answer itself yet/);
        fireEvent.click(screen.getByRole("button", { name: "Retry" }));
        const answer = await screen.findByText(ANSWER);
        expect(follows(screen.getByText("Peak CPU"), answer)).toBe(true);
        expect(screen.queryByText("Copilot didn't write an answer")).not.toBeInTheDocument();
        const asked = socket.sent.filter((m) => m.type === "user").map((m) => String(m.text));
        expect(asked).toHaveLength(2);
        expect(asked[1]).toContain(`You didn't write an answer to my last question: "${QUESTION}"`);
        expect(document.querySelectorAll(".copilot-user")).toHaveLength(1);
        expect(document.querySelectorAll(".copilot-answer")).toHaveLength(1);
    });

    it("gives Copilot one plain sentence when the live view isn't available, and doesn't offer it again in the conversation", async () => {
        const sentence = "Database Hub's live view isn't available to the app";
        estateMock.readEstate.mockResolvedValue({
            view: "health",
            source: ["POST /health/v2/filtered-summary"],
            scope: { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-test"] },
            data: {},
            errors: ["POST /health/v2/filtered-summary: HTTP 401 Unauthorized"],
            unavailable: sentence,
            at: "2026-11-19T21:48:48Z",
        });
        FakeSocket.script = (s, m) => {
            if (m.type === "user") {
                if (s === FakeSocket.all[0]) s.emit({ type: "tool_call", callId: "e1", name: "estate_overview", arguments: { view: "health" } });
                else {
                    s.emit({ type: "message", messageId: `n${FakeSocket.all.length}`, text: "From the history: T2 needs attention first." });
                    s.emit({ type: "idle" });
                }
            } else if (m.callId === "e1") s.emit({ type: "tool_call", callId: "e2", name: "estate_overview", arguments: { view: "inventory" } });
            else if (m.callId === "e2") {
                s.emit({ type: "message", messageId: "m2", text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock(true, true);
        await ask();
        await screen.findByText(ANSWER);
        const first = FakeSocket.all[0];
        expect((first.sent[0].tools as Array<{ name: string }>).map((t) => t.name)).toContain("estate_overview");
        const told = String(resultOf(first, "e1")?.result);
        expect(resultOf(first, "e1")).toMatchObject({ ok: false });
        expect(told).toContain(sentence);
        expect(told).not.toMatch(/HTTP|401|filtered-summary|\/health/);
        // The second live call in the conversation doesn't reach the function.
        expect(String(resultOf(first, "e2")?.result)).toMatch(/Don't call estate_overview again/);
        expect(estateMock.readEstate).toHaveBeenCalledTimes(1);
        fireEvent.click(screen.getByRole("button", { name: /Live estate from Database Hub: health/ }));
        expect(screen.getByText(new RegExp(`^${sentence}`))).toBeInTheDocument();
        expect(screen.queryByText(/401|HTTP/)).not.toBeInTheDocument();

        // A new session in the same conversation (the relay closed the last one) doesn't offer the live view at all.
        await act(async () => first.drop());
        await ask("And now?");
        await waitFor(() => expect(FakeSocket.all).toHaveLength(2));
        await screen.findByText("From the history: T2 needs attention first.");
        const second = FakeSocket.all[1];
        expect((second.sent[0].tools as Array<{ name: string }>).map((t) => t.name)).not.toContain("estate_overview");
        expect(String(second.sent[0].systemMessage)).toContain(`LIVE estate: ${sentence}`);

        // A new chat tries the live view again.
        await act(async () => {
            fireEvent.click(screen.getByRole("button", { name: "New chat" }));
        });
        await ask("How is my estate doing now?");
        await waitFor(() => expect(FakeSocket.all).toHaveLength(3));
        expect((FakeSocket.all[2].sent[0].tools as Array<{ name: string }>).map((t) => t.name)).toContain("estate_overview");
    });

    // The review of 754fc4c: New chat while the last conversation's live call still runs (a cold start), then a new question.
    it("keeps the live view on in a new chat when the last conversation's live call ends after it, and keeps that call's row out", async () => {
        const sentence = "Database Hub's live view isn't available to the app";
        const scope = { subscriptionId: "11111111-2222-3333-4444-555555555555", resourceGroups: ["rg-test"] };
        let release: (answer: unknown) => void = () => undefined;
        estateMock.readEstate
            .mockImplementationOnce(() => new Promise((resolve) => (release = resolve)))
            .mockResolvedValue({ view: "inventory", source: ["POST /savedView/resources/list"], scope, data: { totalCount: 4, countByType: { AzureSql: 1 }, resources: [], complete: true }, errors: [], at: "2026-11-19T21:50:00Z" });
        FakeSocket.script = (s, m) => {
            if (s === FakeSocket.all[0]) {
                if (m.type === "user") s.emit({ type: "tool_call", callId: "e1", name: "estate_overview", arguments: { view: "health" } });
            } else if (m.type === "tool_result" && m.callId === "e2") {
                s.emit({ type: "message", messageId: "n2", text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock(true, true);
        await ask();
        await waitFor(() => expect(estateMock.readEstate).toHaveBeenCalledTimes(1));
        await act(async () => {
            fireEvent.click(screen.getByRole("button", { name: "New chat" }));
        });
        await ask("How is my estate doing now?");
        await waitFor(() => expect(FakeSocket.all).toHaveLength(2));
        const second = FakeSocket.all[1];
        await waitFor(() => expect(second.sent.some((m) => m.type === "user")).toBe(true));
        expect((second.sent[0].tools as Array<{ name: string }>).map((t) => t.name)).toContain("estate_overview");

        // The first conversation's call ends now, with the live view unavailable to it.
        await act(async () => {
            release({ view: "health", source: ["POST /health/v2/filtered-summary"], scope, data: {}, errors: ["POST /health/v2/filtered-summary: HTTP 401 Unauthorized"], unavailable: sentence, at: "2026-11-19T21:49:30Z" });
            await new Promise((resolve) => setTimeout(resolve, 0));
        });
        // The new conversation's own live call still reaches the function, and nothing of the first one shows in it.
        await act(async () => second.emit({ type: "tool_call", callId: "e2", name: "estate_overview", arguments: { view: "inventory" } }));
        await screen.findByText(ANSWER);
        expect(estateMock.readEstate).toHaveBeenCalledTimes(2);
        expect(resultOf(second, "e2")).toMatchObject({ ok: true });
        expect(screen.getByRole("button", { name: /Live estate from Database Hub: inventory/ })).toBeInTheDocument();
        expect(screen.queryByRole("button", { name: /Live estate from Database Hub: health/ })).not.toBeInTheDocument();
    });

    // The owner's question 2, the coordinator's decision: while Database Hub refuses the app as a whole, as the pages read
    // it (useLiveOff: every view unavailable), a new conversation starts without the live view and hides its starters.
    it("starts without the live view while Database Hub refuses the app as a whole, as the pages read it, and uses it again once a view answers", async () => {
        const sentence = "Database Hub's live view isn't available to the app: Database Hub refuses the app's own sign-in.";
        const toolsOf = (socket: FakeSocket) => (socket.sent[0].tools as Array<{ name: string }>).map((t) => t.name);
        pagesRefusal = sentence;
        FakeSocket.script = (s, m) => {
            if (m.type === "user") {
                s.emit({ type: "message", messageId: `h${FakeSocket.all.length}`, text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock(true, true);
        await waitFor(() => expect(screen.getByTestId("account")).toHaveTextContent("signed-in octo"));
        await screen.findByRole("button", { name: "Which target worked hardest this week?" });
        await waitFor(() => expect(screen.queryByRole("button", { name: "How is my estate doing right now?" })).not.toBeInTheDocument());
        await ask();
        await screen.findByText(ANSWER);
        const first = FakeSocket.all[0];
        expect(toolsOf(first)).not.toContain("estate_overview");
        expect(String(first.sent[0].systemMessage)).toContain(`LIVE estate: ${sentence}`);
        expect(estateMock.readEstate).not.toHaveBeenCalled();

        // Database Hub answers again: the next conversation reads the pages' state again, and offers the live view.
        pagesRefusal = null;
        await act(async () => {
            fireEvent.click(screen.getByRole("button", { name: "New chat" }));
        });
        await screen.findByRole("button", { name: "How is my estate doing right now?" });
        await ask("How is my estate doing now?");
        await waitFor(() => expect(FakeSocket.all).toHaveLength(2));
        expect(toolsOf(FakeSocket.all[1])).toContain("estate_overview");
        expect(String(FakeSocket.all[1].sent[0].systemMessage)).not.toContain(sentence);
    });

    // The re-review of 35abaab: a page reads the live estate again while the dock stays open with no conversation, where
    // New chat is off. The dock follows the page's read, as the pages would.
    it("follows a page's later live read while it stays open: the live starters return, and the next session offers the live view", async () => {
        const sentence = "Database Hub's live view isn't available to the app: Database Hub refuses the app's own sign-in.";
        pagesRefusal = sentence;
        FakeSocket.script = (s, m) => {
            if (m.type === "user") {
                s.emit({ type: "message", messageId: "h1", text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock(true, true);
        await screen.findByRole("button", { name: "Which target worked hardest this week?" });
        await waitFor(() => expect(screen.queryByRole("button", { name: "How is my estate doing right now?" })).not.toBeInTheDocument());

        // A page reads the live estate again, and Database Hub answers this time.
        pagesRefusal = null;
        render(<PageRead />);
        await screen.findByText("page: data");
        await screen.findByRole("button", { name: "How is my estate doing right now?" });
        await ask();
        await screen.findByText(ANSWER);
        const tools = (FakeSocket.all[0].sent[0].tools as Array<{ name: string }>).map((t) => t.name);
        expect(tools).toContain("estate_overview");
        expect(String(FakeSocket.all[0].sent[0].systemMessage)).not.toContain(sentence);
    });

    // The re-review of 6125812: New chat while the first question's session starts, then a new question. The session that
    // started for the conversation that's gone is closed unused; the new question starts its own and shows its rows.
    it("starts the new conversation's own session when New chat comes while a session starts, and shows its query rows", async () => {
        const FIRST = "First question, overtaken by New chat";
        let release: () => void = () => undefined;
        FakeSocket.startGate = new Promise<void>((resolve) => (release = resolve));
        FakeSocket.script = (s, m) => {
            if (m.type === "user") s.emit(dax("c1"));
            else {
                s.emit({ type: "message", messageId: "m2", text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock();
        await ask(FIRST);
        await waitFor(() => expect(FakeSocket.all[0]?.sent.some((m) => m.type === "start")).toBe(true));
        await act(async () => {
            fireEvent.click(screen.getByRole("button", { name: "New chat" }));
        });
        // The first session's start completes after New chat.
        await act(async () => {
            release();
            await new Promise((resolve) => setTimeout(resolve, 20));
        });
        await ask(QUESTION);
        const answer = await screen.findByText(ANSWER);
        expect(follows(screen.getByText("Peak CPU"), answer)).toBe(true);
        const [first, second] = FakeSocket.all;
        expect(first.closed).toBe(true);
        expect(first.sent.some((m) => m.type === "user")).toBe(false);
        expect(second.sent.filter((m) => m.type === "user").map((m) => m.text)).toEqual([QUESTION]);
        expect(screen.queryByText(FIRST)).not.toBeInTheDocument();
        expect(screen.queryByText("Copilot didn't write an answer")).not.toBeInTheDocument();
    });

    // The same, with the new question asked while the first session is still starting: when the first start completes,
    // its question is dropped quietly, with no error in the new conversation's turn and nothing of the new one closed.
    it("drops the first question quietly when the new conversation's question comes while the first session still starts", async () => {
        const FIRST = "First question, overtaken by New chat";
        let release: () => void = () => undefined;
        FakeSocket.startGate = new Promise<void>((resolve) => (release = resolve));
        FakeSocket.script = (s, m) => {
            if (m.type === "user") s.emit(dax("c1"));
            else {
                s.emit({ type: "message", messageId: "m2", text: ANSWER });
                s.emit({ type: "idle" });
            }
        };
        signedIn();
        renderDock();
        await ask(FIRST);
        await waitFor(() => expect(FakeSocket.all[0]?.sent.some((m) => m.type === "start")).toBe(true));
        await act(async () => {
            fireEvent.click(screen.getByRole("button", { name: "New chat" }));
        });
        await ask(QUESTION);
        await waitFor(() => expect(FakeSocket.all[1]?.sent.some((m) => m.type === "start")).toBe(true));
        // Both starts complete now, the first conversation's first.
        await act(async () => {
            release();
        });
        const answer = await screen.findByText(ANSWER);
        expect(follows(screen.getByText("Peak CPU"), answer)).toBe(true);
        const [first, second] = FakeSocket.all;
        expect(first.closed).toBe(true);
        expect(first.sent.some((m) => m.type === "user")).toBe(false);
        expect(second.closed).toBe(false);
        expect(second.sent.filter((m) => m.type === "user").map((m) => m.text)).toEqual([QUESTION]);
        expect(screen.queryByText(/New chat started another conversation/)).not.toBeInTheDocument();
        expect(document.querySelectorAll(".copilot-answer")).toHaveLength(1);
    });
});

// The owner's report, 2026-11-20: the header's GitHub sign-in opened an empty page inside Fabric, while the chat worked.
describe("the header's GitHub chip", () => {
    const device = { deviceCode: "d", userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device", expiresIn: 900, interval: 5 };

    function renderShell() {
        return render(
            <QueryClientContext.Provider value={queryClient}>
                <CopilotProvider settings={{ relayUrl: RELAY, estate: false }}>
                    <ShellHarness />
                </CopilotProvider>
            </QueryClientContext.Provider>,
        );
    }

    it("opens the Copilot panel's own sign-in, with GitHub's code and link there, and opens no blank tab", async () => {
        vi.stubGlobal("fetch", fetchStub({ "/healthz": { ok: true, version: "t", signIn: "device" }, "/auth/device": device }));
        const open = vi.fn(() => null);
        vi.stubGlobal("open", open);
        renderShell();
        expect(document.querySelector(".copilot-dock")).toBeNull();
        fireEvent.click(screen.getByRole("button", { name: "Sign in to GitHub" }));
        expect(await screen.findByText("WDJB-MJHT")).toBeInTheDocument();
        expect(document.querySelector(".copilot-dock")).toHaveTextContent("Open github.com/login/device in a new tab");
        expect(open).not.toHaveBeenCalled();
        // GitHub opens from the panel's button, in its own click.
        fireEvent.click(screen.getByRole("button", { name: "Copy the code and open GitHub" }));
        await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
        expect(open).toHaveBeenCalledWith("https://github.com/login/device", "_blank", "noopener,noreferrer");
        fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    });

    it("follows the panel's sign-in: while GitHub's code is on its way, once it's there, and after a cancel", async () => {
        let release: () => void = () => undefined;
        const codeReady = new Promise<void>((resolve) => (release = resolve));
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/device": async () => {
                    await codeReady;
                    return json(device);
                },
            }),
        );
        vi.stubGlobal("open", vi.fn(() => null));
        renderShell();
        fireEvent.click(screen.getByRole("button", { name: "Sign in to GitHub" }));
        // While the relay gets the code, the chip says it's signing in, as the panel does, and doesn't offer a second sign-in.
        expect(await screen.findByRole("button", { name: "GitHub: signing in" })).toBeInTheDocument();
        expect(screen.queryByRole("button", { name: "Sign in to GitHub" })).not.toBeInTheDocument();
        await waitFor(() => expect(document.querySelector(".copilot-dock")).toHaveTextContent("Getting a sign-in code from GitHub"));
        await act(async () => release());
        expect(await screen.findByText("WDJB-MJHT")).toBeInTheDocument();
        expect(screen.getByRole("button", { name: "GitHub: signing in" })).toBeInTheDocument();
        fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
        expect(await screen.findByRole("button", { name: "Sign in to GitHub" })).toBeInTheDocument();
    });

    it("says why a sign-in from the header didn't finish, on the chip and in the panel", async () => {
        const reason = "GitHub didn't answer the sign-in request. Try again.";
        vi.stubGlobal(
            "fetch",
            fetchStub({
                "/healthz": { ok: true, version: "t", signIn: "device" },
                "/auth/device": () => json({ error: "github_error", message: reason }, 502),
            }),
        );
        vi.stubGlobal("open", vi.fn(() => null));
        renderShell();
        fireEvent.click(screen.getByRole("button", { name: "Sign in to GitHub" }));
        await waitFor(() => expect(document.querySelector(".copilot-dock")).toHaveTextContent(reason));
        expect(await screen.findByRole("button", { name: /Sign in to GitHub\s*Didn't finish/ })).toBeInTheDocument();
    });
});
