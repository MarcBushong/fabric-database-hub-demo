// The dock's placeholder panel: the shell renders it in its right-hand region until the chat lands. It shows what an
// entry point attached (title, rows, DAX) and the questions the chat will start from. The chat replaces this file.

import { Badge, Button, Caption1, Textarea, Tooltip } from "@fluentui/react-components";
import { Dismiss20Regular, FullScreenMaximize20Regular, FullScreenMinimize20Regular, Sparkle20Filled, TableSimple16Regular, Code16Regular } from "@fluentui/react-icons";

import type { CopilotDockProps } from "./contract";
import { useCopilot, useCopilotAttached } from "./use-copilot";

import "./copilot-dock.css";

/** Questions a DBA starts from; Database Hub's GA prompts first. */
const STARTER_PROMPTS: readonly string[] = [
    "Which databases need attention this week?",
    "What changed in my databases?",
    "Which resource should I investigate next?",
    "Which security findings should I address first?",
];

export function CopilotDock({ mode, onModeChange, onClose, headingId }: CopilotDockProps) {
    const attached = useCopilotAttached();
    const { ask } = useCopilot();
    const ctx = attached?.ctx;
    const daxLines = ctx?.dax ? ctx.dax.split("\n").length : 0;

    return (
        <section className="copilot-dock" aria-labelledby={headingId} data-mode={mode}>
            <header className="copilot-dock-head">
                <span className="copilot-mark" aria-hidden="true">
                    <Sparkle20Filled />
                </span>
                <h2 id={headingId}>Copilot</h2>
                <Badge appearance="tint" size="small" color="informative">
                    Preview
                </Badge>
                <span className="copilot-dock-spacer" />
                <Tooltip content={mode === "fullscreen" ? "Dock beside the page" : "Full screen"} relationship="label">
                    <Button appearance="subtle" icon={mode === "fullscreen" ? <FullScreenMinimize20Regular /> : <FullScreenMaximize20Regular />} onClick={() => onModeChange(mode === "fullscreen" ? "docked" : "fullscreen")} />
                </Tooltip>
                <Tooltip content="Close Copilot" relationship="label">
                    <Button appearance="subtle" icon={<Dismiss20Regular />} onClick={onClose} />
                </Tooltip>
            </header>

            <div className="copilot-dock-body">
                {ctx ? (
                    <article className="copilot-attached" aria-label="Attached to your question">
                        <span className="copilot-eyebrow">{attached?.asked ? "You asked about" : "Attached"}</span>
                        <strong>{ctx.title ?? "This view"}</strong>
                        {ctx.prompt ? <p className="copilot-prompt">{ctx.prompt}</p> : null}
                        <span className="copilot-chips">
                            {ctx.rows ? (
                                <span>
                                    <TableSimple16Regular aria-hidden="true" />
                                    {`${ctx.totalRows ?? ctx.rows.length} rows${ctx.truncated ? `, first ${ctx.rows.length} attached` : ""}`}
                                </span>
                            ) : null}
                            {daxLines > 0 ? (
                                <span>
                                    <Code16Regular aria-hidden="true" />
                                    {`DAX, ${daxLines} lines`}
                                </span>
                            ) : null}
                            {ctx.source ? <span>{ctx.source === "live" ? "Live data" : ctx.source === "sample" ? "Sample data" : "History"}</span> : null}
                        </span>
                    </article>
                ) : (
                    <div className="copilot-intro">
                        <p className="copilot-intro-title">Ask about your database estate</p>
                        <p>Every visual and table has Ask Copilot, and every anomaly has Ask why: they bring their title, their rows, and the DAX behind them here.</p>
                    </div>
                )}

                <div className="copilot-starters" role="group" aria-label="Start with a question">
                    {STARTER_PROMPTS.map((prompt) => (
                        <Button key={prompt} appearance="outline" size="small" shape="circular" onClick={() => ask({ prompt })}>
                            {prompt}
                        </Button>
                    ))}
                </div>
            </div>

            <footer className="copilot-dock-foot">
                <Textarea aria-label="Message Copilot" placeholder="Ask about your database estate" resize="none" disabled />
                <Caption1>Copilot chat isn't connected in this build.</Caption1>
            </footer>
        </section>
    );
}
