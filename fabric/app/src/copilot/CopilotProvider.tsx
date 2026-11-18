// The Copilot chat behind the dock: GitHub sign-in (the device flow, through the relay), one conversation at a
// time on the viewer's own GitHub Copilot, the page tools that answer Copilot's tool calls, and the transcript,
// kept for the browser session. It implements the contract (contract.ts) through use-copilot.ts's context.

import { useCallback, useContext, useEffect, useMemo, useReducer, useRef, useState, type ReactNode } from "react";

import { QueryClientContext } from "@/data/use-query";
import type { ChatController, ChatState, CopilotPlan, RelayStatus, SignInMode } from "./chat-types";
import type { AskContext, CopilotAccountState, CopilotApi, CopilotDockState } from "./contract";
import { clearConversation, contextPrompt, loadAskSettings, loadConversation, recap, reduceConversation, saveConversation, toMarkdown, type AskSettings } from "./conversation";
import { readEstate, type EstateView } from "./estate";
import { clearSession, fromPoll, loadSession, saveSession, sessionState, type GitHubSession } from "./github-session";
import { buildSystemMessage } from "./guide";
import { describeAskError, planLabel } from "./messages";
import { ChatConnection, RelayClient, RelayError, type GitHubUser, type RelayEvent } from "./relay";
import { createToolRunner, toolSpecs, type ToolRunner } from "./tools";
import { CopilotContext, type AttachedContext, type CopilotContextValue } from "./use-copilot";

const IDLE_CLOSE_MS = 5 * 60_000;
const NO_PLAN: CopilotPlan = { label: null, ok: null };
const local = () => (typeof window !== "undefined" ? window.localStorage : undefined);
const perTab = () => (typeof window !== "undefined" ? window.sessionStorage : undefined);

let idCounter = 0;
const newId = (prefix: string) => `${prefix}${Date.now().toString(36)}${(++idCounter).toString(36)}`;

interface Health {
    state: "idle" | "pending" | "ok" | "error";
    signIn: SignInMode;
    error: string | null;
}

interface Identity {
    token: string;
    user: GitHubUser | null;
    plan: CopilotPlan;
}

function hash(text: string): string {
    let h = 5381;
    for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36);
}

export function CopilotProvider({ children, initialOpen = false, settings: settingsOverride }: { children: ReactNode; initialOpen?: boolean; settings?: AskSettings }) {
    const queryClient = useContext(QueryClientContext);
    const [loadedSettings, setLoadedSettings] = useState<AskSettings | null>(null);
    const settings = settingsOverride ?? loadedSettings;
    const [health, setHealth] = useState<Health>({ state: "idle", signIn: null, error: null });
    const [session, setSession] = useState<GitHubSession | null>(() => loadSession(local()));
    const [identity, setIdentity] = useState<Identity | null>(null);
    const [device, setDevice] = useState<ChatState["device"]>(null);
    const [authError, setAuthError] = useState<string | null>(null);
    const [turns, dispatch] = useReducer(reduceConversation, undefined, () => loadConversation(perTab()));
    const [busy, setBusy] = useState(false);
    const [connecting, setConnecting] = useState(false);
    const [isOpen, setIsOpen] = useState(initialOpen);
    const [attached, setAttached] = useState<AttachedContext | null>(null);

    const relayUrl = settings?.relayUrl ?? null;
    const relay = useMemo(() => (relayUrl ? new RelayClient(relayUrl) : null), [relayUrl]);
    const connection = useRef<ChatConnection | null>(null);
    const runner = useRef<ToolRunner | null>(null);
    const idleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
    const signInRun = useRef<{ cancelled: boolean } | null>(null);
    const turnsRef = useRef(turns);

    useEffect(() => {
        turnsRef.current = turns;
        saveConversation(perTab(), turns);
    }, [turns]);

    useEffect(() => {
        if (settingsOverride) return;
        let cancelled = false;
        loadAskSettings().then(
            (s) => !cancelled && setLoadedSettings(s),
            () => !cancelled && setLoadedSettings({ relayUrl: null, estate: false }),
        );
        return () => {
            cancelled = true;
        };
    }, [settingsOverride]);

    const relayStatus: RelayStatus = !settings ? "unknown" : !relay ? "off" : health.state === "ok" ? "ready" : health.state === "error" ? "unreachable" : health.state === "pending" ? "waking" : "unknown";

    const checkRelay = useCallback(() => {
        if (!relay) return;
        relay.health().then(
            (h) => setHealth({ state: "ok", signIn: h.signIn === "device" ? "device" : "off", error: null }),
            (err: unknown) => setHealth({ state: "error", signIn: null, error: err instanceof Error ? err.message : String(err) }),
        );
    }, [relay]);

    /** Wakes the relay (it scales to zero) and learns how it signs viewers in. Safe to call often. */
    const warmUp = useCallback(() => {
        if (!relay || health.state === "pending" || health.state === "ok") return;
        setHealth((h) => ({ ...h, state: "pending", error: null }));
        checkRelay();
    }, [checkRelay, health.state, relay]);

    // The first check when the app opens with the dock open; otherwise opening the dock or hovering the launcher starts it.
    useEffect(() => {
        if (!initialOpen || !relay) return;
        checkRelay();
    }, [checkRelay, initialOpen, relay]);

    // Who the stored sign-in belongs to, and whether that account can use GitHub Copilot here.
    const token = session?.accessToken ?? null;
    useEffect(() => {
        if (!relay || health.state !== "ok" || !token) return;
        let cancelled = false;
        Promise.all([relay.user(token).catch((err: unknown) => err), relay.copilot(token).catch(() => null)]).then(([user, check]) => {
            if (cancelled) return;
            if (user instanceof RelayError && user.status === 401) {
                clearSession(local());
                setSession(null);
                setAuthError("Your GitHub sign-in expired or was revoked. Sign in with GitHub again.");
                return;
            }
            const plan: CopilotPlan = check
                ? check.ok
                    ? { label: planLabel(check.plan), ok: true }
                    : { label: null, ok: false, detail: check.message ?? "This GitHub account can't use GitHub Copilot here." }
                : { label: null, ok: null };
            setIdentity({ token, user: user && typeof user === "object" && "login" in user ? (user as GitHubUser) : null, plan });
        });
        return () => {
            cancelled = true;
        };
    }, [health.state, relay, token]);

    const user = identity && identity.token === token ? identity.user : null;
    const plan: CopilotPlan = identity && identity.token === token ? identity.plan : NO_PLAN;

    const disconnect = useCallback(() => {
        if (idleTimer.current) clearTimeout(idleTimer.current);
        idleTimer.current = null;
        connection.current?.close();
        connection.current = null;
    }, []);

    useEffect(() => () => disconnect(), [disconnect]);

    const armIdle = useCallback(() => {
        if (idleTimer.current) clearTimeout(idleTimer.current);
        // An idle conversation lets the relay scale to zero; the next question starts a new session with a recap.
        idleTimer.current = setTimeout(() => disconnect(), IDLE_CLOSE_MS);
    }, [disconnect]);

    /** A usable token: renewed through the relay when it's close to expiry, or null when the viewer must sign in. */
    const freshToken = useCallback(async (): Promise<string | null> => {
        if (!session) return null;
        const state = sessionState(session, Date.now());
        if (state === "valid") return session.accessToken;
        if (state === "refresh" && relay && session.refreshToken) {
            const renewed = await relay.refresh(session.refreshToken).catch(() => null);
            if (renewed && renewed.status === "ok") {
                const next = fromPoll(renewed, Date.now(), session.login);
                saveSession(local(), next);
                setSession(next);
                return next.accessToken;
            }
        }
        clearSession(local());
        setSession(null);
        setAuthError("Your GitHub sign-in expired. Sign in with GitHub again.");
        return null;
    }, [relay, session]);

    const handleEvent = useCallback(
        (event: RelayEvent) => {
            switch (event.type) {
                case "delta":
                    dispatch({ type: "delta", messageId: event.messageId, text: event.text });
                    break;
                case "message":
                    dispatch({ type: "message", messageId: event.messageId, text: event.text });
                    break;
                case "usage":
                    dispatch({ type: "model", model: event.model });
                    break;
                case "tool_call": {
                    const conn = connection.current;
                    const run = runner.current;
                    if (!conn || !run) break;
                    void run.run(event.name, event.arguments).then((outcome) => conn.toolResult(event.callId, outcome.ok, outcome.text));
                    break;
                }
                case "idle":
                    dispatch({ type: "idle" });
                    setBusy(false);
                    armIdle();
                    break;
                case "error":
                    dispatch({ type: "error", message: describeAskError(new RelayError(event.message, 0, event.code)) });
                    setBusy(false);
                    if (event.fatal) disconnect();
                    break;
                case "closed":
                    connection.current = null;
                    setBusy((wasBusy) => {
                        if (wasBusy) dispatch({ type: "error", message: "The conversation's connection closed. Ask again to continue: Copilot gets a recap of this conversation." });
                        return false;
                    });
                    break;
                default:
                    break;
            }
        },
        [armIdle, disconnect],
    );

    const ensureConnection = useCallback(
        async (accessToken: string): Promise<ChatConnection> => {
            if (connection.current) return connection.current;
            if (!relay || !settings) throw new RelayError("Ask isn't deployed in this environment.", 0, "off");
            setConnecting(true);
            try {
                runner.current = createToolRunner({
                    runDax: async (query, rowLimit) => {
                        if (!queryClient) throw new Error("The history connector isn't ready yet.");
                        const result = await queryClient.run({ id: `copilot-${hash(query)}`, title: "Copilot query", dax: query, rowLimit, columns: [] });
                        return result.rows;
                    },
                    estate: settings.estate
                        ? async (view) => {
                              const answer = await readEstate(view as EstateView);
                              return { source: answer.source, data: { scope: answer.scope, data: answer.data, errors: answer.errors, at: answer.at } };
                          }
                        : undefined,
                    onDax: (run) => dispatch({ type: "dax", run }),
                    onChart: (chart, run) => dispatch({ type: "chart", chart, runId: run.id }),
                    onFollowups: (questions) => dispatch({ type: "followups", questions }),
                    onEstate: (call) => dispatch({ type: "estate", call }),
                });
                const earlier = recap(turnsRef.current.slice(0, -2));
                const systemMessage =
                    buildSystemMessage({ estate: settings.estate, resourceGroup: settings.resourceGroup }) +
                    (earlier ? `\n\n# Earlier in this conversation (the previous session ended; continue from it)\n${earlier}` : "");
                const conn = new ChatConnection(relay.chatUrl(), handleEvent);
                await conn.open({ token: accessToken, systemMessage, tools: toolSpecs({ estate: settings.estate }) });
                connection.current = conn;
                return conn;
            } finally {
                setConnecting(false);
            }
        },
        [handleEvent, queryClient, relay, settings],
    );

    const send = useCallback(
        (text: string, ctx?: AskContext | null) => {
            const prompt = ctx ? contextPrompt({ ...ctx, prompt: text || ctx.prompt }) : text.trim();
            if (!prompt || busy) return;
            setAttached(null);
            const shown = (text || ctx?.prompt || (ctx?.title ? `Explain "${ctx.title}"` : prompt)).trim();
            dispatch({ type: "user", id: newId("u"), text: shown, from: ctx ? { title: ctx.title, page: ctx.page } : undefined, at: Date.now() });
            dispatch({ type: "assistant-start", id: newId("a"), at: Date.now() });
            setBusy(true);
            if (idleTimer.current) clearTimeout(idleTimer.current);
            void (async () => {
                try {
                    const accessToken = await freshToken();
                    if (!accessToken) throw new RelayError("Sign in with GitHub first.", 401, "signin");
                    const conn = await ensureConnection(accessToken);
                    if (!conn.ask(prompt)) throw new RelayError("The conversation's connection isn't open. Ask again.", 0, "closed");
                } catch (err) {
                    const message = describeAskError(err);
                    if (err instanceof RelayError && /sign in to github again/i.test(message)) {
                        clearSession(local());
                        setSession(null);
                        setAuthError(message);
                    }
                    dispatch({ type: "error", message });
                    setBusy(false);
                    disconnect();
                }
            })();
        },
        [busy, disconnect, ensureConnection, freshToken],
    );

    const stop = useCallback(() => {
        connection.current?.abort();
    }, []);

    const newChat = useCallback(() => {
        disconnect();
        setBusy(false);
        dispatch({ type: "reset" });
        clearConversation(perTab());
        setAttached(null);
    }, [disconnect]);

    const cancelSignIn = useCallback(() => {
        if (signInRun.current) signInRun.current.cancelled = true;
        signInRun.current = null;
        setDevice(null);
    }, []);

    /** GitHub's device flow through the relay: opens github.com/login/device, copies the code, and waits for it. */
    const signInWithGitHub = useCallback(() => {
        if (!relay) return;
        setAuthError(null);
        // Opened in the click itself, so the browser allows the new tab; it goes to GitHub once the code arrives.
        const tab = typeof window !== "undefined" ? window.open("about:blank", "_blank") : null;
        const run = { cancelled: false };
        if (signInRun.current) signInRun.current.cancelled = true;
        signInRun.current = run;
        void (async () => {
            let start;
            try {
                start = await relay.startDeviceFlow();
            } catch (err) {
                tab?.close();
                if (!run.cancelled) setAuthError(describeAskError(err));
                return;
            }
            if (run.cancelled) {
                tab?.close();
                return;
            }
            const copied = await (navigator.clipboard?.writeText(start.userCode).then(() => true, () => false) ?? Promise.resolve(false));
            let opened = false;
            if (tab) {
                try {
                    tab.opener = null;
                    tab.location.href = start.verificationUri;
                    opened = !tab.closed;
                } catch {
                    tab.close();
                }
            }
            setDevice({ userCode: start.userCode, verificationUri: start.verificationUri, expiresAt: Date.now() + start.expiresIn * 1000, copied, opened });
            let interval = Math.max(5, start.interval);
            const deadline = Date.now() + start.expiresIn * 1000;
            while (!run.cancelled && Date.now() < deadline) {
                await new Promise((r) => setTimeout(r, interval * 1000));
                if (run.cancelled) return;
                const poll = await relay.pollDeviceFlow(start.deviceCode).catch((err: unknown) => ({ status: "error" as const, message: describeAskError(err) }));
                if (poll.status === "pending") continue;
                if (poll.status === "slow_down") {
                    interval = Math.max(interval + 5, poll.interval);
                    continue;
                }
                if (run.cancelled) return;
                setDevice(null);
                signInRun.current = null;
                if (poll.status === "ok") {
                    const next = fromPoll(poll, Date.now());
                    const who = await relay.user(next.accessToken).catch(() => null);
                    const withLogin = { ...next, login: who?.login ?? null };
                    saveSession(local(), withLogin);
                    setSession(withLogin);
                    return;
                }
                setAuthError(
                    poll.status === "denied"
                        ? "GitHub sign-in was cancelled on github.com. Select Sign in with GitHub to try again."
                        : poll.status === "expired"
                          ? "The sign-in code expired before it was entered. Select Sign in with GitHub for a new one."
                          : `GitHub sign-in didn't finish: ${poll.message}`,
                );
                return;
            }
            if (!run.cancelled) {
                setDevice(null);
                signInRun.current = null;
                setAuthError("The sign-in code expired before it was entered. Select Sign in with GitHub for a new one.");
            }
        })();
    }, [relay]);

    const signOut = useCallback(() => {
        cancelSignIn();
        disconnect();
        clearSession(local());
        setSession(null);
        setIdentity(null);
        setBusy(false);
    }, [cancelSignIn, disconnect]);

    const open = useCallback(
        (ctx?: AskContext) => {
            if (ctx) setAttached({ ctx, asked: false, at: Date.now() });
            setIsOpen(true);
            warmUp();
        },
        [warmUp],
    );

    const ask = useCallback(
        (ctx: AskContext) => {
            setIsOpen(true);
            warmUp();
            if (session && !busy) send(ctx.prompt ?? "", ctx);
            else setAttached({ ctx, asked: true, at: Date.now() });
        },
        [busy, send, session, warmUp],
    );

    const setOpen = useCallback(
        (value: boolean) => {
            setIsOpen(value);
            if (value) warmUp();
        },
        [warmUp],
    );

    const api = useMemo<CopilotApi>(() => ({ open, ask }), [open, ask]);
    const dock = useMemo<CopilotDockState>(() => ({ isOpen, setOpen }), [isOpen, setOpen]);

    const signInMode = health.signIn;
    const account = useMemo<CopilotAccountState>(() => {
        const base = {
            signIn: () => {
                setIsOpen(true);
                warmUp();
                if (!session) signInWithGitHub();
            },
            signOut,
        };
        if (settings && !relay) return { ...base, status: "unavailable", detail: "Ask isn't deployed in this environment." };
        if (signInMode === "off") return { ...base, status: "unavailable", detail: "GitHub sign-in isn't set up on the chat relay." };
        if (device) return { ...base, status: "signing-in", detail: `Enter ${device.userCode} at github.com/login/device` };
        if (session) {
            return {
                ...base,
                status: "signed-in",
                login: user?.login ?? session.login ?? undefined,
                plan: plan.label ?? undefined,
                avatarUrl: user?.avatarUrl ?? undefined,
                detail: plan.ok === false ? plan.detail : undefined,
            };
        }
        return { ...base, status: "signed-out", detail: authError ?? undefined };
    }, [authError, device, plan, relay, session, settings, signInMode, signInWithGitHub, signOut, user, warmUp]);

    const chatState: ChatState = {
        settings,
        relayStatus,
        relayError: health.error,
        signIn: signInMode,
        session,
        user,
        plan,
        device,
        authError,
        turns,
        busy,
        connecting,
        pending: attached?.ctx ?? null,
    };
    const chat: ChatController = {
        state: chatState,
        send,
        stop,
        newChat,
        signInWithGitHub,
        cancelSignIn,
        signOut,
        clearPending: () => setAttached(null),
        exportMarkdown: () => toMarkdown(turns),
        warmUp,
    };

    const value: CopilotContextValue = { api, dock, account, attached, chat };
    return <CopilotContext.Provider value={value}>{children}</CopilotContext.Provider>;
}
