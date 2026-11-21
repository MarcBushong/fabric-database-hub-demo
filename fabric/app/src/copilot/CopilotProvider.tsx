// The Copilot chat behind the dock: GitHub sign-in (the device flow, through the relay), one conversation at a
// time on the viewer's own GitHub Copilot, the page tools that answer Copilot's tool calls, and the transcript,
// kept for the browser session. It implements the contract (contract.ts) through use-copilot.ts's context.

import { useCallback, useContext, useEffect, useMemo, useReducer, useRef, useState, useSyncExternalStore, type ReactNode } from "react";

import { liveOffNow, onLiveOffChange, useLiveOff } from "@/data/live-estate";
import { QueryClientContext } from "@/data/use-query";
import type { ChatController, ChatState, CopilotPlan, RelayStatus, SignInMode } from "./chat-types";
import type { AskContext, CopilotAccountState, CopilotApi, CopilotDockState } from "./contract";
import { clearConversation, contextPrompt, endedWithoutAnswer, loadAskSettings, loadConversation, recap, reduceConversation, retryPrompt, saveConversation, toMarkdown, type AskSettings, type ConversationAction } from "./conversation";
import type { EstateView } from "./estate";
import { clearSession, deviceStartOf, fromPoll, GITHUB_DEVICE_PAGE, loadSession, renewSession, saveSession, SESSION_KEY, sessionState, waitForDeviceToken, type DeviceCode, type GitHubSession } from "./github-session";
import { describeAskError, planLabel } from "./messages";
import { ChatConnection, isTransient, RelayClient, RelayError, type GitHubUser, type RelayEvent } from "./relay";
import { COSMOS_PROBE_DAX } from "./starters";
import type { ToolRunner } from "./tools";
import { CopilotContext, type AttachedContext, type CopilotContextValue } from "./use-copilot";

const IDLE_CLOSE_MS = 5 * 60_000;
const NO_PLAN: CopilotPlan = { label: null, ok: null };
const local = () => (typeof window !== "undefined" ? window.localStorage : undefined);
const perTab = () => (typeof window !== "undefined" ? window.sessionStorage : undefined);
/** A session start or a question that New chat overtook: dropped quietly, never shown to the viewer. */
const newChatStarted = () => new RelayError("New chat started another conversation.", 0, "cancelled");

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

/** The system message (with the model guide) and the page tools, loaded when the first conversation starts rather than with the app. */
function loadChatModules() {
    return Promise.all([import("./guide"), import("./tools")]).catch(() => {
        throw new Error("The chat's tools didn't load. Reload the page and ask again.");
    });
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
    /** From a sign-in's click until GitHub's code arrives (a cold relay takes a few seconds): the dock and the header's chip say so. */
    const [signInStarting, setSignInStarting] = useState(false);
    const [turns, dispatch] = useReducer(reduceConversation, undefined, () => loadConversation(perTab()));
    const [busy, setBusy] = useState(false);
    const [connecting, setConnecting] = useState(false);
    const [isOpen, setIsOpen] = useState(initialOpen);
    const [attached, setAttached] = useState<AttachedContext | null>(null);

    const relayUrl = settings?.relayUrl ?? null;
    const relay = useMemo(() => (relayUrl ? new RelayClient(relayUrl) : null), [relayUrl]);
    const connection = useRef<ChatConnection | null>(null);
    /** The token the open conversation started with: a renewed token starts a new conversation at the next question. */
    const connectionToken = useRef<string | null>(null);
    const runner = useRef<ToolRunner | null>(null);
    /** Set once the estate function said the live view isn't available: the rest of the conversation answers from history. */
    const liveUnavailable = useRef<string | null>(null);
    /** Counts conversations (New chat starts the next): a tool call an earlier one still runs changes nothing in this one. */
    const conversationNo = useRef(0);
    /** Copilot's text since its last query, by message: what suggest_followups checks before it ends a turn (R925). */
    const answerText = useRef(new Map<string, number>());
    const idleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
    const signInRun = useRef<{ cancelled: boolean } | null>(null);
    const turnsRef = useRef(turns);
    /** The sign-in callbacks act on, current even between a renewal and the render that follows it. */
    const sessionRef = useRef(session);
    /** A token that came from renewing one GitHub refused: if GitHub refuses it too, the sign-in is over. */
    const renewedAfterRefusal = useRef<string | null>(null);
    const applySession = useCallback((next: GitHubSession | null) => {
        sessionRef.current = next;
        setSession(next);
    }, []);

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

    // Whether the history holds T5's (Azure Cosmos DB) metrics, asked once when the dock first opens, so T5's starter
    // shows only when it has an answer. A failure (the local preview's sample, a model without T5's measures) leaves it out.
    const [cosmosHistory, setCosmosHistory] = useState(false);
    // Whether Database Hub refuses the app as a whole, as the pages read it (R924): by the latest read of each view in this
    // browser, whichever page or the dock read it (liveOffNow), so it follows reads while the dock stays open. While it
    // does, a new conversation starts without the live view, and the live starters hide. LiveOffWatch reads the three
    // views while the dock is open, and again for each new conversation.
    const liveOff = useSyncExternalStore(onLiveOffChange, liveOffNow);
    const [liveWatch, setLiveWatch] = useState(0);
    const cosmosProbed = useRef(false);
    useEffect(() => {
        if (!isOpen || !relay || !queryClient || cosmosProbed.current) return;
        cosmosProbed.current = true;
        queryClient.run({ id: "copilot-has-cosmos", title: "Copilot: T5 history", dax: COSMOS_PROBE_DAX, rowLimit: 1, columns: [] }).then(
            (result) => setCosmosHistory(Number(result.rows[0]?.HasCosmos) === 1),
            () => undefined,
        );
    }, [isOpen, queryClient, relay]);

    // Who the stored sign-in belongs to, and whether that account can use GitHub Copilot here (checked below freshToken).
    const token = session?.accessToken ?? null;

    const user = identity && identity.token === token ? identity.user : null;
    const plan: CopilotPlan = identity && identity.token === token ? identity.plan : NO_PLAN;

    const disconnect = useCallback(() => {
        if (idleTimer.current) clearTimeout(idleTimer.current);
        idleTimer.current = null;
        connection.current?.close();
        connection.current = null;
        connectionToken.current = null;
    }, []);

    useEffect(() => () => disconnect(), [disconnect]);

    const armIdle = useCallback(() => {
        if (idleTimer.current) clearTimeout(idleTimer.current);
        // An idle conversation lets the relay scale to zero; the next question starts a new session with a recap.
        idleTimer.current = setTimeout(() => disconnect(), IDLE_CLOSE_MS);
    }, [disconnect]);

    /**
     * A usable token: renewed through the relay when it's close to expiry (or, with force, because GitHub just refused
     * it), or null when the viewer must sign in again. Only GitHub refusing the refresh token ends the sign-in; a renewal
     * that fails on the way (the relay waking, a network blip) keeps it, and throws unless the token in hand still works.
     */
    const freshToken = useCallback(
        async (force = false): Promise<string | null> => {
            const current = sessionRef.current;
            if (!current) return null;
            if (!force && sessionState(current, Date.now()) === "valid") return current.accessToken;
            if (!relay) return current.accessToken;
            const renewal = await renewSession({ storage: local(), current, refresh: (refreshToken) => relay.refresh(refreshToken), now: () => Date.now(), force });
            if (renewal.kind === "ok") {
                if (renewal.session.accessToken !== current.accessToken) applySession(renewal.session);
                return renewal.session.accessToken;
            }
            if (renewal.kind === "signed-out") {
                applySession(null);
                return null;
            }
            if (renewal.kind === "expired") {
                clearSession(local());
                applySession(null);
                setAuthError("Your GitHub sign-in expired. Sign in with GitHub again.");
                return null;
            }
            if (!force && current.expiresAt !== null && current.expiresAt > Date.now()) return current.accessToken;
            throw new RelayError(`Your GitHub sign-in couldn't be renewed just now (${renewal.message}). Try again in a moment.`, 0, "renew_unavailable");
        },
        [applySession, relay],
    );

    // Who the sign-in belongs to, and whether that account can use GitHub Copilot here. A token past its 8 hours is
    // renewed first: GitHub refuses it, and the 6-month refresh token keeps the viewer signed in.
    useEffect(() => {
        if (!relay || health.state !== "ok" || !token) return;
        let cancelled = false;
        void (async () => {
            let usable: string | null;
            try {
                usable = await freshToken();
            } catch {
                return; // Not renewed just now: the sign-in stays, and the next question or visit renews it.
            }
            // A renewal changed the token: this check runs again for the new one.
            if (cancelled || usable !== token) return;
            const [found, check] = await Promise.all([relay.user(token).catch((err: unknown) => err), relay.copilot(token).catch(() => null)]);
            if (cancelled) return;
            if (found instanceof RelayError && found.status === 401) {
                if (renewedAfterRefusal.current === token) {
                    // GitHub refuses even the token renewed a moment ago: the app's authorization is gone.
                    clearSession(local());
                    applySession(null);
                    setAuthError("GitHub didn't accept your sign-in. Sign in with GitHub again.");
                    return;
                }
                const renewed = await freshToken(true).catch(() => null);
                if (renewed) renewedAfterRefusal.current = renewed;
                return;
            }
            const plan: CopilotPlan = check
                ? check.ok
                    ? { label: planLabel(check.plan), ok: true }
                    : { label: null, ok: false, detail: check.message ?? "This GitHub account can't use GitHub Copilot here." }
                : { label: null, ok: null };
            setIdentity({ token, user: found && typeof found === "object" && "login" in found ? (found as GitHubUser) : null, plan });
        })();
        return () => {
            cancelled = true;
        };
    }, [applySession, freshToken, health.state, relay, token]);

    // Another tab renewed the sign-in, signed out, or signed in: follow it, so this tab never holds a token that's gone.
    useEffect(() => {
        if (typeof window === "undefined") return;
        const onStorage = (event: StorageEvent) => {
            if (event.key !== null && event.key !== SESSION_KEY) return;
            const next = loadSession(local());
            if (next?.accessToken === sessionRef.current?.accessToken) return;
            applySession(next);
            if (!next) disconnect();
        };
        window.addEventListener("storage", onStorage);
        return () => window.removeEventListener("storage", onStorage);
    }, [applySession, disconnect]);

    const handleEvent = useCallback(
        (event: RelayEvent) => {
            switch (event.type) {
                case "delta":
                    answerText.current.set(event.messageId, (answerText.current.get(event.messageId) ?? 0) + event.text.length);
                    dispatch({ type: "delta", messageId: event.messageId, text: event.text });
                    break;
                case "message":
                    answerText.current.set(event.messageId, event.text.trim().length);
                    dispatch({ type: "message", messageId: event.messageId, text: event.text });
                    break;
                case "usage":
                    dispatch({ type: "model", model: event.model });
                    break;
                case "tool_call": {
                    const conn = connection.current;
                    const run = runner.current;
                    // Text before a query is Copilot saying what it will check; the answer is what it writes after.
                    if (event.name === "run_dax" || event.name === "estate_overview") answerText.current.clear();
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
        async (accessToken: string, no: number): Promise<ChatConnection> => {
            if (connection.current && connectionToken.current === accessToken) return connection.current;
            // A renewed token (here or in another tab) starts a new conversation on it; Copilot gets a recap.
            if (connection.current) disconnect();
            if (!relay || !settings) throw new RelayError("Ask isn't deployed in this environment.", 0, "off");
            // The conversation this session serves (no): once New chat starts another, nothing of this one is kept.
            const stale = () => conversationNo.current !== no;
            setConnecting(true);
            try {
                const [{ buildSystemMessage }, { createToolRunner, toolSpecs }] = await loadChatModules();
                if (stale()) throw newChatStarted();
                // A conversation that learned the live view isn't available doesn't offer it again, even on a new session;
                // nor does one that starts while Database Hub refuses the app as a whole, by the latest reads (liveOffNow).
                const live = liveUnavailable.current ?? (settings.estate ? liveOffNow() : null);
                // Once New chat starts another conversation, what this session's calls return is dropped.
                const dispatchHere = (action: ConversationAction) => {
                    if (!stale()) dispatch(action);
                };
                const run = createToolRunner({
                    runDax: async (query, rowLimit) => {
                        if (!queryClient) throw new Error("The history connector isn't ready yet.");
                        const result = await queryClient.run({ id: `copilot-${hash(query)}`, title: "Copilot query", dax: query, rowLimit, columns: [] });
                        return result.rows;
                    },
                    estate: settings.estate
                        ? async (view) => {
                              const { readEstate } = await import("./estate");
                              // unavailable: the function's plain sentence when nothing was read and won't be on the next read (R924).
                              const answer = await readEstate(view as EstateView);
                              return { source: answer.source, data: answer.data, errors: answer.errors, at: answer.at, unavailable: answer.unavailable };
                          }
                        : undefined,
                    liveOff: () => liveUnavailable.current,
                    onLiveUnavailable: (reason) => {
                        if (!stale()) liveUnavailable.current = reason;
                    },
                    answered: () => [...answerText.current.values()].some((chars) => chars > 0),
                    onDax: (run) => dispatchHere({ type: "dax", run }),
                    onChart: (chart, run) => dispatchHere({ type: "chart", chart, runId: run.id }),
                    onFollowups: (questions) => dispatchHere({ type: "followups", questions }),
                    onEstate: (call) => dispatchHere({ type: "estate", call }),
                });
                const earlier = recap(turnsRef.current.slice(0, -2));
                const systemMessage =
                    buildSystemMessage({ estate: settings.estate, resourceGroup: settings.resourceGroup, liveUnavailable: live ?? undefined }) +
                    (earlier ? `\n\n# Earlier in this conversation (the previous session ended; continue from it)\n${earlier}` : "");
                const conn = new ChatConnection(relay.chatUrl(), handleEvent);
                try {
                    await conn.open({ token: accessToken, systemMessage, tools: toolSpecs({ estate: settings.estate && !live }) });
                } catch (err) {
                    // Nothing of a failed start stays open: no socket and no pings.
                    conn.close();
                    throw err;
                }
                // New chat while the session started: it belongs to the conversation that's gone, so it isn't kept, and the
                // new conversation's first question starts its own (the review of 6125812).
                if (stale()) {
                    conn.close();
                    throw newChatStarted();
                }
                runner.current = run;
                connection.current = conn;
                connectionToken.current = accessToken;
                return conn;
            } finally {
                // New chat cleared it already, and a start of the new conversation may have set it again.
                if (!stale()) setConnecting(false);
            }
        },
        [disconnect, handleEvent, queryClient, relay, settings],
    );

    /** Sends one prompt on the conversation, starting a session when there's none; the current assistant turn gets the answer. */
    const deliver = useCallback(
        (prompt: string) => {
            // The conversation this question belongs to: when New chat starts another before it's sent, it's dropped quietly,
            // with no message and nothing closed, as the new conversation may be starting already.
            const no = conversationNo.current;
            const stale = () => conversationNo.current !== no;
            setBusy(true);
            answerText.current.clear();
            if (idleTimer.current) clearTimeout(idleTimer.current);
            void (async () => {
                try {
                    let accessToken = await freshToken();
                    if (stale()) return;
                    if (!accessToken) throw new RelayError("Sign in with GitHub first.", 401, "signin");
                    let conn: ChatConnection;
                    try {
                        conn = await ensureConnection(accessToken, no);
                    } catch (err) {
                        // Copilot refused the token (revoked, or expired early): renew it once and start again. Only GitHub
                        // refusing the refresh token ends the sign-in (freshToken).
                        if (!(err instanceof RelayError) || !/sign in to github again/i.test(err.message)) throw err;
                        accessToken = await freshToken(true);
                        if (stale()) return;
                        if (!accessToken) throw new RelayError("Your GitHub sign-in expired. Sign in with GitHub again.", 401, "signin");
                        conn = await ensureConnection(accessToken, no);
                    }
                    if (stale()) return;
                    if (!conn.ask(prompt)) throw new RelayError("The conversation's connection isn't open. Ask again.", 0, "closed");
                } catch (err) {
                    if (stale()) return;
                    dispatch({ type: "error", message: describeAskError(err) });
                    setBusy(false);
                    disconnect();
                }
            })();
        },
        [disconnect, ensureConnection, freshToken],
    );

    const send = useCallback(
        (text: string, ctx?: AskContext | null) => {
            const prompt = ctx ? contextPrompt({ ...ctx, prompt: text || ctx.prompt }) : text.trim();
            if (!prompt || busy || plan.ok === false) return;
            setAttached(null);
            const shown = (text || ctx?.prompt || (ctx?.title ? `Explain "${ctx.title}"` : prompt)).trim();
            dispatch({ type: "user", id: newId("u"), text: shown, from: ctx ? { title: ctx.title, page: ctx.page } : undefined, at: Date.now() });
            dispatch({ type: "assistant-start", id: newId("a"), at: Date.now() });
            deliver(prompt);
        },
        [busy, deliver, plan.ok],
    );

    /** Retry for a turn that ended without an answer: the same conversation is asked to write it, in the same turn (R925). */
    const retry = useCallback(() => {
        if (busy || plan.ok === false) return;
        // The turns this button was rendered with: turnsRef follows them only after the render's effects.
        const last = turns[turns.length - 1];
        if (!last || last.role !== "assistant" || !endedWithoutAnswer(last)) return;
        const question = [...turns].reverse().find((t) => t.role === "user");
        dispatch({ type: "resume" });
        deliver(retryPrompt(question?.role === "user" ? question.text : ""));
    }, [busy, deliver, plan.ok, turns]);

    const stop = useCallback(() => {
        connection.current?.abort();
    }, []);

    const newChat = useCallback(() => {
        conversationNo.current += 1;
        disconnect();
        setBusy(false);
        // A session the last conversation was starting closes when it's ready (ensureConnection), so nothing waits for it.
        setConnecting(false);
        dispatch({ type: "reset" });
        clearConversation(perTab());
        setAttached(null);
        // A new conversation tries the live view again, unless the app is refused as a whole: that's read again too.
        liveUnavailable.current = null;
        setLiveWatch((n) => n + 1);
    }, [disconnect]);

    const cancelSignIn = useCallback(() => {
        if (signInRun.current) signInRun.current.cancelled = true;
        signInRun.current = null;
        setSignInStarting(false);
        setDevice(null);
    }, []);

    // The provider goes away (AuthGate signs the viewer out of Fabric): a sign-in it started stops waiting for GitHub.
    useEffect(() => cancelSignIn, [cancelSignIn]);

    /**
     * GitHub's device flow through the relay: gets a code, shows it in the dock with "Copy the code and open GitHub", and
     * waits for it. It opens no tab of its own: one opened in the click, before the code arrives, can stay blank inside
     * Fabric's frame, where the browser may open it but give the app no handle to send it to GitHub (the owner's report,
     * 2026-11-20). The dock's button opens GitHub in its own click, which works there. The run stays this tab's sign-in
     * until its session is saved, so a click meanwhile starts no second one (the review of 1c94891, 2026-11-20).
     */
    const signInWithGitHub = useCallback(() => {
        if (!relay) return;
        setAuthError(null);
        const run = { cancelled: false };
        if (signInRun.current) signInRun.current.cancelled = true;
        signInRun.current = run;
        setDevice(null);
        setSignInStarting(true);
        const end = () => {
            if (signInRun.current === run) signInRun.current = null;
            setSignInStarting(false);
            setDevice(null);
        };
        void (async () => {
            let start: DeviceCode | null;
            try {
                // Checked: GitHub's codes only, and never the address the relay names (deviceStartOf).
                start = deviceStartOf(await relay.startDeviceFlow());
            } catch (err) {
                if (!run.cancelled) {
                    end();
                    setAuthError(describeAskError(err));
                }
                return;
            }
            if (run.cancelled) return;
            if (!start) {
                end();
                setAuthError("The chat relay didn't pass on a sign-in code from GitHub. Select Sign in with GitHub to try again.");
                return;
            }
            const userCode = start.userCode;
            const copied = await (navigator.clipboard?.writeText(userCode).then(() => true, () => false) ?? Promise.resolve(false));
            if (run.cancelled) return;
            // One update: the chip and the panel go from getting a code to showing it, never back to "Sign in" between.
            setSignInStarting(false);
            setDevice({ userCode, expiresAt: Date.now() + start.expiresIn * 1000, copied, opened: false });
            const code = start.deviceCode;
            const outcome = await waitForDeviceToken({
                poll: () => relay.pollDeviceFlow(code),
                sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
                now: () => Date.now(),
                expiresAt: Date.now() + start.expiresIn * 1000,
                interval: start.interval,
                cancelled: () => run.cancelled,
                isTransient,
            });
            if (outcome.status === "cancelled" || run.cancelled) return;
            if (outcome.status === "ok") {
                const next = fromPoll(outcome, Date.now());
                // Whose token it is, while the code stays on screen: Cancel, a newer sign-in, or the provider going away
                // still wins, and nothing is saved for a run that's over.
                const who = await relay.user(next.accessToken).catch(() => null);
                if (run.cancelled) return;
                const withLogin = { ...next, login: who?.login ?? null };
                saveSession(local(), withLogin);
                renewedAfterRefusal.current = null;
                end();
                applySession(withLogin);
                return;
            }
            end();
            // Signed in meanwhile another way (another tab's sign-in): this run's end has nothing to report.
            if (sessionRef.current) return;
            setAuthError(
                outcome.status === "denied"
                    ? "GitHub sign-in was cancelled on github.com. Select Sign in with GitHub to try again."
                    : outcome.status === "expired"
                      ? "The sign-in code expired before it was entered. Select Sign in with GitHub for a new one."
                      : `GitHub sign-in didn't finish: ${outcome.message}`,
            );
        })();
    }, [applySession, relay]);

    const signOut = useCallback(() => {
        cancelSignIn();
        disconnect();
        clearSession(local());
        applySession(null);
        setIdentity(null);
        setBusy(false);
    }, [applySession, cancelSignIn, disconnect]);

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
            // The header's chip: it opens the dock, where the sign-in runs with its code, GitHub's link, and any error. It
            // starts one only when none is running and the relay can sign viewers in; it never opens a tab itself.
            signIn: () => {
                setIsOpen(true);
                warmUp();
                if (!session && !device && !signInStarting && relay && signInMode !== "off") signInWithGitHub();
            },
            signOut,
        };
        if (settings && !relay) return { ...base, status: "unavailable", detail: "Ask isn't deployed in this environment." };
        if (signInMode === "off") return { ...base, status: "unavailable", detail: "GitHub sign-in isn't set up on the chat relay." };
        // A session wins: the chip offers its menu (sign out, switch) as the panel shows the conversation.
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
        if (device) return { ...base, status: "signing-in", detail: `Enter ${device.userCode} at ${GITHUB_DEVICE_PAGE}: the Copilot panel has the code and the link.` };
        if (signInStarting) return { ...base, status: "signing-in", detail: "Getting a sign-in code from GitHub. The Copilot panel shows it." };
        return { ...base, status: "signed-out", detail: authError ?? undefined };
    }, [authError, device, plan, relay, session, settings, signInMode, signInStarting, signInWithGitHub, signOut, user, warmUp]);

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
        cosmosHistory,
        liveOff,
        signInStarting,
    };
    const chat: ChatController = {
        state: chatState,
        send,
        retry,
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
    return (
        <CopilotContext.Provider value={value}>
            {children}
            {isOpen && settings?.estate ? <LiveOffWatch key={liveWatch} /> : null}
        </CopilotContext.Provider>
    );
}

/**
 * Reads the three live views as the pages do (useLiveOff), while the dock is open, so this browser learns whether
 * Database Hub refuses the app even when no page has read them; the provider follows the result through liveOffNow.
 */
function LiveOffWatch() {
    useLiveOff();
    return null;
}
