// Ready-made prompts for Database Hub's Database Agent (UI-only, no API) or the Copilot CLI fallback, built from the
// data on screen. Copy one and paste it there, or ask the in-app Copilot. The app itself never runs anything.

import { useEffect, useId, useState, type ReactNode } from "react";
import { Badge, Button, Dialog, DialogBody, DialogSurface, DialogTitle, MessageBar, MessageBarBody, ToggleButton, Tooltip } from "@fluentui/react-components";
import { Bot20Regular, Checkmark16Regular, Copy16Regular, Dismiss20Regular, Eye16Regular, Open16Regular, ShieldCheckmark16Regular, Sparkle16Filled, WindowConsole20Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import { AGENT_SURFACES, hubUrlOf, promptsAsText, TELEMETRY_RETENTION_DAYS, type AgentPrompt, type AgentSurface } from "@/lib/agent-prompts";
import { copyText } from "@/lib/clipboard";
import { useAgentSurface } from "@/lib/hooks";

export interface AgentPanelProps {
    /** Builds the prompts for the chosen surface from the data on screen. */
    build: (surface: AgentSurface) => AgentPrompt[];
    /** One sentence on what the prompts are about. */
    lead: ReactNode;
    /** A caveat for these prompts, such as a window older than Database Hub's retention. */
    warning?: string | null;
    /** Where the prompts come from, for Copilot's context ("incidents.agent"). */
    visualId: string;
}

function AgentPanel({ build, lead, warning, visualId }: AgentPanelProps) {
    const { runtime, notify, view, provenance } = useApp();
    const copilot = useCopilot();
    const [surface, setSurface] = useAgentSurface();
    const [copied, setCopied] = useState<string | null>(null);
    const prompts = build(surface);
    const hubUrl = hubUrlOf(runtime);
    const where = surface === "hub" ? "the Database Agent" : "Copilot CLI or VS Code chat";

    useEffect(() => {
        if (!copied) return;
        const timer = window.setTimeout(() => setCopied(null), 2200);
        return () => window.clearTimeout(timer);
    }, [copied]);

    const copy = async (id: string, text: string, done: string) => {
        const ok = await copyText(text);
        notify(ok ? done : "Copy is blocked here: select the prompt and press Ctrl+C", ok ? "success" : "warning");
        if (ok) setCopied(id);
    };

    return (
        <div className="agent">
            <ul className="labels" aria-label="About these prompts">
                <li>
                    <Badge appearance="tint" color="informative">
                        Preview
                    </Badge>
                </li>
                <li>
                    <Badge appearance="outline" color="subtle" icon={<ShieldCheckmark16Regular />}>
                        The agent proposes; you approve each action
                    </Badge>
                </li>
                <li>
                    <Badge appearance="outline" color="subtle" icon={<Eye16Regular />}>
                        Investigation only: this app never runs anything
                    </Badge>
                </li>
            </ul>

            <div className="agent-bar">
                <p className="panel-sub">{lead}</p>
                <div className="period" role="group" aria-label="Where you'll ask">
                    {AGENT_SURFACES.map((s) => (
                        <ToggleButton key={s.id} size="small" appearance="subtle" checked={surface === s.id} icon={s.id === "hub" ? <Bot20Regular /> : <WindowConsole20Regular />} onClick={() => setSurface(s.id)} title={s.label}>
                            {s.short}
                        </ToggleButton>
                    ))}
                </div>
            </div>

            {warning ? (
                <MessageBar intent="warning">
                    <MessageBarBody>{warning}</MessageBarBody>
                </MessageBar>
            ) : null}

            <ol className="prompts" aria-label={`Prompts for ${AGENT_SURFACES.find((s) => s.id === surface)?.label ?? "the agent"}`}>
                {prompts.map((p, i) => (
                    <li key={p.id} className="prompt">
                        <div className="prompt-head">
                            <Badge size="small" shape="circular" appearance="filled" color="brand" aria-hidden="true">
                                {i + 1}
                            </Badge>
                            <span>{p.title}</span>
                        </div>
                        <span className="muted">{p.purpose}</span>
                        <p className="prompt-text">{p.text}</p>
                        <div className="prompt-actions">
                            <Button size="small" appearance="subtle" icon={copied === p.id ? <Checkmark16Regular /> : <Copy16Regular />} aria-label={`Copy prompt ${i + 1}: ${p.title}`} onClick={() => copy(p.id, p.text, `Prompt copied: paste it into ${where}`)}>
                                {copied === p.id ? "Copied" : "Copy"}
                            </Button>
                            {surface === "hub" ? (
                                <Button
                                    size="small"
                                    appearance="subtle"
                                    as="a"
                                    href={hubUrl}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    icon={<Open16Regular />}
                                    aria-label={`Copy prompt ${i + 1} and open Database Hub in a new tab`}
                                    onClick={() => void copy(p.id, p.text, "Prompt copied: paste it into the Database Agent in the new tab")}
                                >
                                    Copy and open Database Hub
                                </Button>
                            ) : null}
                            <Tooltip content="Ask the in-app Copilot instead" relationship="description">
                                <Button
                                    size="small"
                                    appearance="subtle"
                                    className="ask-copilot"
                                    icon={<Sparkle16Filled />}
                                    aria-label={`Ask Copilot prompt ${i + 1}: ${p.title}`}
                                    onClick={() => copilot.ask({ prompt: p.text, title: p.title, page: view.page, visualId, source: provenance })}
                                >
                                    Ask Copilot
                                </Button>
                            </Tooltip>
                        </div>
                    </li>
                ))}
            </ol>

            <div className="agent-go">
                {surface === "hub" ? (
                    <ol className="agent-howto" aria-label="How to ask">
                        <li>Copy a prompt</li>
                        <li>Open Database Hub</li>
                        <li>Paste it into the Database Agent</li>
                    </ol>
                ) : (
                    <ol className="agent-howto" aria-label="How to ask">
                        <li>Install the fabric-skills (databasehub-cli) and microsoft-sql plugins</li>
                        <li>Run the session-setup prompt</li>
                        <li>Paste it into Copilot CLI or VS Code chat</li>
                    </ol>
                )}
                <div className="page-actions">
                    <Button size="small" icon={copied === "all" ? <Checkmark16Regular /> : <Copy16Regular />} onClick={() => copy("all", promptsAsText(prompts), `All ${prompts.length} prompts copied: paste one at a time into ${where}`)}>
                        {`Copy all ${prompts.length}`}
                    </Button>
                    {surface === "hub" ? (
                        <Button size="small" appearance="primary" as="a" href={hubUrl} target="_blank" rel="noopener noreferrer" icon={<Open16Regular />} iconPosition="after">
                            Open Database Hub
                        </Button>
                    ) : null}
                </div>
            </div>

            <p className="muted">
                {surface === "hub"
                    ? `Database Hub's Database Agent is a preview with no API, so this app can't send it a prompt: copy one, open Database Hub in a new tab, and paste it into the Database Agent. The agent proposes actions, and each one runs only after you explicitly approve it there; in this demo, read a proposal aloud, then cancel it. The agent sees ${TELEMETRY_RETENTION_DAYS} days of telemetry or less; this app's history goes further back.`
                    : "The documented fallback (fabric/agent/README.md): GitHub Copilot CLI or VS Code with the GA Database Hub skill (databasehub-cli, in the fabric-skills plugin) and the microsoft-sql plugin, each from its pinned marketplace commit, and the telemetry agent instructions from Microsoft Learn. Start the session with the guide's deny rules for the bundle's MCP servers. Approve only read commands, one at a time; every prompt forbids changes."}
            </p>
        </div>
    );
}

/** A panel of ready-made prompts for the Database Agent, in the page grid. */
export function AgentCard({ className, title, subtitle, ...panel }: AgentPanelProps & { className?: string; title: string; subtitle?: string }) {
    const headingId = useId();
    return (
        <section className={`panel ${className ?? ""}`} aria-labelledby={headingId}>
            <div className="agent-title">
                <span className="agent-mark" aria-hidden="true">
                    <Bot20Regular />
                </span>
                <div>
                    <h3 id={headingId}>{title}</h3>
                    {subtitle ? <p className="panel-sub">{subtitle}</p> : null}
                </div>
            </div>
            <AgentPanel {...panel} />
        </section>
    );
}

/** The same prompts in a dialog over the page: Esc or Close closes it, and focus returns to the opener. */
export function AgentDialog({ open, onClose, title, subtitle, ...panel }: AgentPanelProps & { open: boolean; onClose: () => void; title: string; subtitle?: string }) {
    return (
        <Dialog open={open} onOpenChange={(_, data) => !data.open && onClose()}>
            <DialogSurface className="vcard-focus" aria-label={title}>
                <DialogBody>
                    <DialogTitle
                        action={
                            <Tooltip content="Close (Esc)" relationship="label">
                                <Button appearance="subtle" icon={<Dismiss20Regular />} onClick={onClose} aria-label="Close" />
                            </Tooltip>
                        }
                    >
                        {title}
                    </DialogTitle>
                    <div className="vcard-focus-body">
                        {subtitle ? <p className="panel-sub">{subtitle}</p> : null}
                        <AgentPanel {...panel} />
                    </div>
                </DialogBody>
            </DialogSurface>
        </Dialog>
    );
}
