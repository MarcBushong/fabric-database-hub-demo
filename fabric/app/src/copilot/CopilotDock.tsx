// The Copilot dock's panel. The shell places it (docked or full screen) and passes its mode; the panel renders the
// whole chat: GitHub sign-in (once per browser), the conversation with streamed answers, native charts and
// tables (ChartView), the DAX or Database Hub source behind every answer, follow-ups, copy, and export.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
    Avatar,
    Badge,
    Button,
    Caption1,
    Menu,
    MenuItem,
    MenuList,
    MenuPopover,
    MenuTrigger,
    MessageBar,
    MessageBarActions,
    MessageBarBody,
    MessageBarTitle,
    Spinner,
    Textarea,
    Tooltip,
} from "@fluentui/react-components";
import {
    ArrowClockwise16Regular,
    ArrowDownload20Regular,
    ChatAdd20Regular,
    Checkmark16Regular,
    ChevronDown16Regular,
    ChevronRight16Regular,
    Code16Regular,
    Copy16Regular,
    Database16Regular,
    Dismiss20Regular,
    FullScreenMaximize20Regular,
    FullScreenMinimize20Regular,
    Key20Regular,
    Live16Regular,
    PersonSwap20Regular,
    Send20Filled,
    SignOut20Regular,
    Sparkle20Filled,
    Stop20Filled,
} from "@fluentui/react-icons";

import { DaxView } from "@/components/DaxView";
import { copyText } from "@/lib/clipboard";
import { downloadText } from "@/lib/csv";
import { ChartView } from "@/visuals/ChartView";
import type { ChatController } from "./chat-types";
import type { CopilotDockProps } from "./contract";
import { endedWithoutAnswer, NO_ANSWER, type AssistantTurn, type Part, type UserTurn } from "./conversation";
import { Markdown } from "./markdown";
import { closeOpenMarks } from "./markdown-blocks";
import { relayRegion } from "./messages";
import { startersFor } from "./starters";
import { useCopilotChat } from "./use-copilot";

import "./copilot-dock.css";

export function CopilotDock({ mode, onModeChange, onClose, headingId }: CopilotDockProps) {
    const chat = useCopilotChat();
    return (
        <section className="copilot-dock" aria-labelledby={headingId} data-mode={mode}>
            <header className="copilot-dock-head">
                <span className="copilot-mark" aria-hidden="true">
                    <Sparkle20Filled />
                </span>
                <div className="copilot-dock-titles">
                    <div className="copilot-dock-titleline">
                        <h2 id={headingId}>Copilot</h2>
                        <Badge appearance="tint" size="small" color="informative">
                            Preview
                        </Badge>
                    </div>
                    {chat?.state.session ? <AccountMenu chat={chat} /> : <Caption1>On your own GitHub Copilot · read-only</Caption1>}
                </div>
                <span className="copilot-dock-spacer" />
                {chat ? (
                    <>
                        <Tooltip content="New chat" relationship="label">
                            <Button appearance="subtle" icon={<ChatAdd20Regular />} onClick={chat.newChat} disabled={chat.state.turns.length === 0 && !chat.state.busy} />
                        </Tooltip>
                        <Tooltip content="Export the conversation (Markdown, with every query)" relationship="label">
                            <Button
                                appearance="subtle"
                                icon={<ArrowDownload20Regular />}
                                disabled={chat.state.turns.length === 0}
                                onClick={() => downloadText(`copilot-conversation-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-")}.md`, chat.exportMarkdown(), "text/markdown;charset=utf-8")}
                            />
                        </Tooltip>
                    </>
                ) : null}
                <Tooltip content={mode === "fullscreen" ? "Dock beside the page" : "Full screen"} relationship="label">
                    <Button appearance="subtle" icon={mode === "fullscreen" ? <FullScreenMinimize20Regular /> : <FullScreenMaximize20Regular />} onClick={() => onModeChange(mode === "fullscreen" ? "docked" : "fullscreen")} />
                </Tooltip>
                <Tooltip content="Close Copilot" relationship="label">
                    <Button appearance="subtle" icon={<Dismiss20Regular />} onClick={onClose} />
                </Tooltip>
            </header>
            {chat ? <DockBody chat={chat} /> : <div className="copilot-dock-body">Copilot chat isn't connected.</div>}
        </section>
    );
}

function AccountMenu({ chat }: { chat: ChatController }) {
    const { state } = chat;
    if (!state.session) return null;
    const login = state.user?.login ?? state.session.login ?? "GitHub";
    const plan = state.plan.label;
    return (
        <Menu>
            <MenuTrigger disableButtonEnhancement>
                <Tooltip content={`GitHub: ${login}. Copilot runs on this GitHub account, separate from your Fabric sign-in. Select to switch or sign out.`} relationship="description">
                    <Button
                        appearance="transparent"
                        size="small"
                        className="copilot-account"
                        icon={<Avatar size={16} name={login} image={state.user?.avatarUrl ? { src: state.user.avatarUrl } : undefined} />}
                        aria-label={`GitHub: ${login}${plan ? ` · ${plan}` : ""}`}
                    >
                        <span className="copilot-account-text">
                            {login}
                            {plan ? <span className="copilot-account-plan"> · {plan}</span> : null}
                        </span>
                    </Button>
                </Tooltip>
            </MenuTrigger>
            <MenuPopover>
                <MenuList>
                    <MenuItem
                        icon={<PersonSwap20Regular />}
                        onClick={() => {
                            chat.signOut();
                            chat.signInWithGitHub();
                        }}
                    >
                        Switch GitHub account
                    </MenuItem>
                    <MenuItem icon={<SignOut20Regular />} onClick={chat.signOut}>
                        Sign out of GitHub
                    </MenuItem>
                </MenuList>
            </MenuPopover>
        </Menu>
    );
}

function DockBody({ chat }: { chat: ChatController }) {
    const { state } = chat;
    const ready = state.relayStatus === "ready" && state.signIn === "device" && Boolean(state.session);
    return (
        <>
            <div className="copilot-dock-body">
                <Status chat={chat} />
                {ready ? <Conversation chat={chat} /> : null}
            </div>
            {ready ? <Composer chat={chat} /> : null}
        </>
    );
}

/** The states before a conversation can start, each with what to do next. */
function Status({ chat }: { chat: ChatController }) {
    const { state } = chat;
    if (!state.settings || state.relayStatus === "unknown") {
        return <Spinner size="tiny" label="Connecting…" />;
    }
    if (state.relayStatus === "off") {
        return (
            <MessageBar intent="info" layout="multiline">
                <MessageBarBody>
                    <MessageBarTitle>Ask isn't deployed here</MessageBarTitle>
                    This environment's app has no chat relay. Run <code>./scripts/deploy.ps1</code> again: it creates the relay (an Azure Container App that scales to zero) and redeploys this app with it.
                </MessageBarBody>
            </MessageBar>
        );
    }
    if (state.relayStatus === "waking") {
        return (
            <div className="copilot-card" role="status">
                <Spinner size="small" labelPosition="after" label="Waking the chat relay. It scales to zero when nobody asks, so the first answer of the day takes a few seconds more." />
            </div>
        );
    }
    if (state.relayStatus === "unreachable") {
        return (
            <MessageBar intent="warning" layout="multiline">
                <MessageBarBody>
                    <MessageBarTitle>The chat relay didn't answer</MessageBarTitle>
                    {state.relayError} If it keeps happening inside the Fabric portal, a Fabric administrator may have turned on the strict content security policy for Fabric apps, which blocks every service
                    outside Fabric; the deployment's status page says what to do.
                </MessageBarBody>
                <MessageBarActions>
                    <Button size="small" icon={<ArrowClockwise16Regular />} onClick={chat.warmUp}>
                        Try again
                    </Button>
                </MessageBarActions>
            </MessageBar>
        );
    }
    if (state.signIn === "off") {
        return (
            <MessageBar intent="warning" layout="multiline">
                <MessageBarBody>
                    <MessageBarTitle>GitHub sign-in isn't set up yet</MessageBarTitle>
                    The chat relay has no GitHub app to sign viewers in with. The demo ships one (its client ID is in <code>config/versions.json</code>, <code>askRelay.githubClientId</code>), so the relay was deployed from a
                    version without it: run <code>./scripts/deploy.ps1</code> again. To use your own app instead: on GitHub, Settings, Developer settings, OAuth Apps, New OAuth App; tick Enable Device Flow (no
                    client secret); put its Client ID in <code>ask.githubClientId</code> in <code>config/demo.config.json</code>; run <code>./scripts/deploy.ps1</code>.
                </MessageBarBody>
            </MessageBar>
        );
    }
    if (!state.session) return <SignIn chat={chat} />;
    if (state.plan.ok === false) {
        return (
            <MessageBar intent="error" layout="multiline">
                <MessageBarBody>
                    <MessageBarTitle>This GitHub account can't use Copilot here</MessageBarTitle>
                    {state.plan.detail} Sign in with the GitHub account that has your Copilot license.
                </MessageBarBody>
                <MessageBarActions>
                    <Button
                        size="small"
                        onClick={() => {
                            chat.signOut();
                            chat.signInWithGitHub();
                        }}
                    >
                        Switch account
                    </Button>
                </MessageBarActions>
            </MessageBar>
        );
    }
    return null;
}

function SignIn({ chat }: { chat: ChatController }) {
    const { state } = chat;
    const [copied, setCopied] = useState(false);
    const region = relayRegion(state.settings?.relayUrl);
    if (state.device) {
        return (
            <div className="copilot-card copilot-signin" aria-live="polite">
                <h3>Enter this code on GitHub</h3>
                <p className="copilot-code" aria-label={`Code ${state.device.userCode.split("").join(" ")}`}>
                    {state.device.userCode}
                </p>
                <p>
                    {state.device.opened ? (
                        <>
                            {state.device.copied ? "It's on your clipboard, and " : ""}GitHub opened in a new tab: paste the code there and authorize <strong>Database Hub Insights Ask</strong>.
                        </>
                    ) : (
                        <>
                            Open <strong>{state.device.verificationUri.replace(/^https:\/\//, "")}</strong> in a new tab{state.device.copied ? " (the code is on your clipboard)" : ""}, enter the code, and authorize{" "}
                            <strong>Database Hub Insights Ask</strong>.
                        </>
                    )}{" "}
                    This panel continues by itself.
                </p>
                <p className="copilot-fine">
                    GitHub may show the request coming from the app&apos;s chat relay in Azure{region ? ` (${region})` : ""}, not from where you are: the relay asks GitHub on your behalf. Check that the app
                    is Database Hub Insights Ask, then select Authorize.
                </p>
                <div className="copilot-row">
                    <Button
                        appearance="primary"
                        icon={copied ? <Checkmark16Regular /> : <Copy16Regular />}
                        onClick={async () => {
                            setCopied(await copyText(state.device?.userCode ?? ""));
                            window.open(state.device?.verificationUri ?? "https://github.com/login/device", "_blank", "noopener,noreferrer");
                        }}
                    >
                        Copy the code and open GitHub
                    </Button>
                    <Button appearance="subtle" onClick={chat.cancelSignIn}>
                        Cancel
                    </Button>
                </div>
                <Spinner size="tiny" labelPosition="after" label="Waiting for GitHub…" />
            </div>
        );
    }
    return (
        <div className="copilot-card copilot-signin">
            <h3>Ask about your estate, on your own GitHub Copilot</h3>
            <p>Sign in to GitHub once in this browser. Copilot answers with your Copilot license, from the live estate and the demo's history, and draws its answers as charts.</p>
            <Button appearance="primary" icon={<Key20Regular />} onClick={chat.signInWithGitHub}>
                Sign in with GitHub
            </Button>
            {state.authError ? (
                <p role="alert" className="copilot-error">
                    {state.authError}
                </p>
            ) : null}
            <ul className="copilot-fine">
                <li>Your GitHub account is separate from your Fabric sign-in: use the one with your Copilot license. You stay signed in on this browser for up to six months.</li>
                <li>What goes to GitHub Copilot: your questions, a guide to the history model, and the results of the read-only queries it runs. The relay stores nothing.</li>
            </ul>
        </div>
    );
}

function Conversation({ chat }: { chat: ChatController }) {
    const { state } = chat;
    const end = useRef<HTMLDivElement>(null);
    const last = state.turns[state.turns.length - 1];
    const size = last?.role === "assistant" ? last.parts.reduce((n, p) => n + (p.type === "text" ? p.text.length : 500), 0) + last.followups.length : 0;
    useLayoutEffect(() => {
        end.current?.scrollIntoView?.({ block: "end" });
    }, [state.turns.length, size]);
    if (state.turns.length === 0) {
        return (
            <div className="copilot-intro">
                <p className="copilot-intro-title">Ask about your database estate</p>
                <p>What needs attention now, what happened, and why. Every answer shows the query, or the Database Hub source, behind it. Every visual has Ask Copilot, and every anomaly has Ask why.</p>
                <div className="copilot-starters" role="group" aria-label="Start with a question">
                    {startersFor(Boolean(state.settings?.estate) && !state.liveOff, state.cosmosHistory).map((s) => (
                        <Button key={s.label} appearance="outline" size="small" shape="circular" onClick={() => chat.send(s.prompt)} disabled={state.busy || state.plan.ok === false}>
                            {s.label}
                        </Button>
                    ))}
                </div>
            </div>
        );
    }
    return (
        <div className="copilot-turns" aria-live="polite">
            {state.turns.map((t) => (t.role === "user" ? <UserBubble key={t.id} turn={t} /> : <Answer key={t.id} turn={t} chat={chat} isLast={t === last} />))}
            <div ref={end} />
        </div>
    );
}

function UserBubble({ turn }: { turn: UserTurn }) {
    return (
        <div className="copilot-user">
            {turn.from?.title ? <span className="copilot-from">From “{turn.from.title}”</span> : null}
            <p>{turn.text}</p>
        </div>
    );
}

function Answer({ turn, chat, isLast }: { turn: AssistantTurn; chat: ChatController; isLast: boolean }) {
    const [showSources, setShowSources] = useState(false);
    const [copied, setCopied] = useState(false);
    const text = turn.parts
        .filter((p): p is Extract<Part, { type: "text" }> => p.type === "text")
        .map((p) => p.text)
        .join("\n\n");
    const sources = turn.parts.filter((p) => p.type === "dax" || p.type === "estate").length;
    return (
        <article className="copilot-answer">
            {turn.parts.map((p, i) => (
                <PartView key={`${i}-${showSources}`} part={p} expanded={showSources} streaming={turn.streaming && i === turn.parts.length - 1} />
            ))}
            {turn.streaming && !turn.parts.some((p) => p.type === "text") ? (
                <Spinner size="tiny" labelPosition="after" label={chat.state.connecting ? "Starting a Copilot session…" : turn.parts.length > 0 ? "Working…" : "Thinking…"} />
            ) : null}
            {turn.error ? (
                <MessageBar intent="error" layout="multiline">
                    <MessageBarBody>{turn.error}</MessageBarBody>
                </MessageBar>
            ) : null}
            {endedWithoutAnswer(turn) ? (
                <MessageBar intent="warning" layout="multiline" className="copilot-no-answer">
                    <MessageBarBody>
                        <MessageBarTitle>{NO_ANSWER}</MessageBarTitle>
                        {isLast ? "It finished this turn without writing text. Retry asks it to write the answer from what it found." : "It finished this turn without writing text."}
                    </MessageBarBody>
                    {isLast ? (
                        <MessageBarActions>
                            <Button size="small" icon={<ArrowClockwise16Regular />} onClick={chat.retry} disabled={chat.state.busy || chat.state.plan.ok === false}>
                                Retry
                            </Button>
                        </MessageBarActions>
                    ) : null}
                </MessageBar>
            ) : null}
            {!turn.streaming ? (
                <div className="copilot-answer-actions">
                    {sources > 0 ? (
                        <Button size="small" appearance="transparent" icon={<Code16Regular />} aria-pressed={showSources} onClick={() => setShowSources((v) => !v)}>
                            {showSources ? "Hide" : "Show"} the {sources === 1 ? "source" : `${sources} sources`}
                        </Button>
                    ) : null}
                    {text ? (
                        <Button
                            size="small"
                            appearance="transparent"
                            icon={copied ? <Checkmark16Regular /> : <Copy16Regular />}
                            onClick={async () => {
                                setCopied(await copyText(text));
                                window.setTimeout(() => setCopied(false), 1600);
                            }}
                        >
                            Copy
                        </Button>
                    ) : null}
                    {turn.model ? <Caption1 className="copilot-model">{turn.model}</Caption1> : null}
                </div>
            ) : null}
            {isLast && !turn.streaming && turn.followups.length > 0 ? (
                <div className="copilot-starters copilot-followups" role="group" aria-label="Follow-up questions">
                    {turn.followups.map((q) => (
                        <Button key={q} appearance="outline" size="small" shape="circular" onClick={() => chat.send(q)} disabled={chat.state.busy || chat.state.plan.ok === false}>
                            {q}
                        </Button>
                    ))}
                </div>
            ) : null}
        </article>
    );
}

function PartView({ part, expanded, streaming = false }: { part: Part; expanded: boolean; streaming?: boolean }) {
    const [open, setOpen] = useState(expanded);
    if (part.type === "text") return <Markdown text={streaming ? closeOpenMarks(part.text) : part.text} />;
    if (part.type === "chart") {
        return (
            <figure className="copilot-figure">
                <ChartView spec={part.chart} height={220} />
            </figure>
        );
    }
    if (part.type === "dax") {
        const run = part.run;
        return (
            <div className={`copilot-source ${run.error ? "copilot-source-failed" : ""}`}>
                <button type="button" className="copilot-source-head" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
                    {open ? <ChevronDown16Regular aria-hidden="true" /> : <ChevronRight16Regular aria-hidden="true" />}
                    <Database16Regular aria-hidden="true" />
                    <span className="copilot-source-purpose">{run.purpose}</span>
                    <span className="copilot-source-meta">{run.error ? "failed" : `${run.rowCount.toLocaleString("en-US")} rows · ${(run.ms / 1000).toFixed(1)} s`}</span>
                </button>
                {open ? (
                    <div className="copilot-source-body">
                        <DaxView dax={run.query} label={`DAX: ${run.purpose}`} />
                        {run.error ? <p className="copilot-error">{run.error}</p> : null}
                        {run.rows.length > 0 ? <ChartView spec={{ kind: "table", title: run.purpose, rows: run.rows.slice(0, 50) }} /> : null}
                        <div className="copilot-row">
                            <Button size="small" appearance="transparent" icon={<Copy16Regular />} onClick={() => void copyText(run.query)}>
                                Copy DAX
                            </Button>
                            <Caption1>Read-only, through the history connector, as you.</Caption1>
                        </div>
                    </div>
                ) : null}
            </div>
        );
    }
    const call = part.call;
    return (
        <div className={`copilot-source copilot-source-live ${call.error ? "copilot-source-failed" : ""}`}>
            <button type="button" className="copilot-source-head" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
                {open ? <ChevronDown16Regular aria-hidden="true" /> : <ChevronRight16Regular aria-hidden="true" />}
                <Live16Regular aria-hidden="true" />
                <span className="copilot-source-purpose">Live estate from Database Hub: {call.view}</span>
                <span className="copilot-source-meta">{call.error ? "failed" : `${(call.ms / 1000).toFixed(1)} s`}</span>
            </button>
            {open ? (
                <div className="copilot-source-body">
                    {call.error ? <p className="copilot-error">{call.error}</p> : null}
                    <Caption1>Database Hub API: read-only, as this app's owner, filtered to the demo's resource group.</Caption1>
                    <ul className="copilot-routes">
                        {call.source.map((s) => (
                            <li key={s}>
                                <code>{s}</code>
                            </li>
                        ))}
                    </ul>
                    {call.result !== undefined ? <pre className="copilot-pre">{JSON.stringify(call.result, null, 2).slice(0, 6000)}</pre> : null}
                </div>
            ) : null}
        </div>
    );
}

function Composer({ chat }: { chat: ChatController }) {
    const { state } = chat;
    const [text, setText] = useState("");
    const box = useRef<HTMLTextAreaElement>(null);
    // An account that can't use Copilot here can't send: each try would only start a session that fails.
    const blocked = state.plan.ok === false;
    useEffect(() => {
        box.current?.focus();
    }, [state.pending]);
    const submit = () => {
        if (blocked || state.busy || (!text.trim() && !state.pending)) return;
        chat.send(text.trim(), state.pending);
        setText("");
    };
    return (
        <footer className="copilot-dock-foot">
            {state.pending ? (
                <div className="copilot-attached">
                    <span>
                        Asking about <strong>{state.pending.title ?? state.pending.page ?? "this view"}</strong>
                        {state.pending.rows?.length ? ` · ${state.pending.totalRows ?? state.pending.rows.length} rows` : ""}
                        {state.pending.dax ? " · DAX" : ""}
                    </span>
                    <Button size="small" appearance="subtle" icon={<Dismiss20Regular />} aria-label="Remove the context" onClick={chat.clearPending} />
                </div>
            ) : null}
            <div className="copilot-input">
                <Textarea
                    ref={box}
                    value={text}
                    resize="vertical"
                    aria-label="Message Copilot"
                    disabled={blocked}
                    placeholder={state.pending ? "Ask about it, or press Enter to have Copilot explain it" : "Ask about the estate, an incident, or a trend"}
                    onChange={(_, d) => setText(d.value.slice(0, 4000))}
                    onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.shiftKey) {
                            e.preventDefault();
                            submit();
                        }
                    }}
                />
                {state.busy ? (
                    <Tooltip content="Stop" relationship="label">
                        <Button appearance="primary" icon={<Stop20Filled />} onClick={chat.stop} />
                    </Tooltip>
                ) : (
                    <Tooltip content="Send (Enter)" relationship="label">
                        <Button appearance="primary" icon={<Send20Filled />} onClick={submit} disabled={blocked || (!text.trim() && !state.pending)} />
                    </Tooltip>
                )}
            </div>
            <Caption1 className="copilot-fine">Copilot can be wrong: check the source behind each answer. It's read-only and can't change anything.</Caption1>
        </footer>
    );
}
