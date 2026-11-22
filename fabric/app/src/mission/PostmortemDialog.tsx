// One-click postmortem (ADR 0030): the session's write-up from the data alone, previewed, downloaded as Markdown, or
// copied; and, for a session, "Draft with Copilot", which hands the measured rows and queries to the viewer's own Copilot
// through the app's existing ask contract (ADR 0031, decision 7). Nothing is stored: the download is the record. With the
// Incident RCA's tables, its Cause is the blind investigation of the session's minutes, run when it opens (ADR 0031,
// section 9).

import { useContext, useEffect, useMemo, useState } from "react";
import { Button, Dialog, DialogActions, DialogBody, DialogContent, DialogSurface, DialogTitle, Spinner } from "@fluentui/react-components";
import { ArrowDownload16Regular, Copy16Regular, Dismiss20Regular, Sparkle16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import { QueryClientContext } from "@/data/use-query";
import { copyText } from "@/lib/clipboard";
import { downloadText } from "@/lib/csv";
import { buildPostmortem, causeWindow, draftsWithCopilot, postmortemAsk, postmortemTitle, type PostmortemInput } from "@/lib/postmortem";
import { createRcaClient } from "@/rca/client";
import { blindCauses, type BlindCauses } from "@/rca/postmortem";
import { MarkdownView } from "./parts";

const message = (err: unknown) => (err instanceof Error ? err.message : String(err));

/** Open while `input` is set; its `generatedAt` is when the viewer asked for it. */
export function PostmortemDialog({ input, onClose }: { input: PostmortemInput | null; onClose: () => void }) {
    const { notify, rca, rcaError } = useApp();
    const copilot = useCopilot();
    const queryClient = useContext(QueryClientContext);
    // With the RCA tables, the Cause is the blind investigation of the plan's minutes, once each time it's asked for.
    const investigates = input !== null && rca === true && queryClient !== null;
    const key = input ? `${input.plan.key}|${input.generatedAt.toISOString()}` : "";
    const [investigated, setInvestigated] = useState<{ key: string; value: BlindCauses } | null>(null);
    useEffect(() => {
        if (!input || rca !== true || !queryClient) return;
        const asked = `${input.plan.key}|${input.generatedAt.toISOString()}`;
        const { from, to } = causeWindow(input.plan);
        let alive = true;
        // Closed or asked again: the investigation explains no further incident.
        const stop = new AbortController();
        blindCauses(createRcaClient(queryClient, { timeZone: "UTC" }), from, to, stop.signal).then(
            (value) => alive && setInvestigated({ key: asked, value }),
            (err: unknown) => alive && setInvestigated({ key: asked, value: { from, to, causes: [], notCaptured: [], queries: [], error: message(err) } }),
        );
        return () => {
            alive = false;
            stop.abort();
        };
    }, [input, queryClient, rca]);
    // The blind Cause; undefined while it's investigated; null for the Cause as it was, without the RCA tables. A failed
    // check of the tables is said in the Cause, never taken for their absence.
    const cause = useMemo((): BlindCauses | null | undefined => {
        if (!input) return null;
        if (investigates) return investigated && investigated.key === key ? investigated.value : undefined;
        if (rca !== true && rca !== false && rcaError) {
            const { from, to } = causeWindow(input.plan);
            return { from, to, causes: [], notCaptured: [], queries: [], error: `the check of the Incident RCA's tables failed: ${rcaError}` };
        }
        return null;
    }, [input, investigates, investigated, key, rca, rcaError]);
    const investigating = cause === undefined;
    const postmortem = useMemo(() => (input && cause !== undefined ? buildPostmortem({ ...input, rca: cause }) : null), [input, cause]);
    // A lone incident request's minutes are its fault's own, so only a session's postmortem has a draft. Its line points to
    // the Root cause page when the navigation lists it: with the RCA tables, or when their check failed (AppShell).
    const drafts = input !== null && draftsWithCopilot(input.plan);
    const rootCause = rca === true || !!rcaError;
    return (
        <Dialog open={input !== null} onOpenChange={(_, data) => (data.open ? undefined : onClose())}>
            <DialogSurface className="pm-surface" aria-describedby={undefined}>
                <DialogBody>
                    <DialogTitle action={<Button appearance="subtle" aria-label="Close" icon={<Dismiss20Regular />} onClick={onClose} />}>{input ? postmortemTitle(input.plan) : "Postmortem"}</DialogTitle>
                    <DialogContent>
                        <p className="pm-lead">
                            Written from the history alone, so it works without a GitHub sign-in: {cause === null ? "what was injected" : "a blind investigation of the session's minutes for the Cause, as on the Root cause page, then what was injected, labeled as the answer key"}, when each signal showed in the telemetry, the response, and the recovery, with every query behind it.{" "}
                            {drafts ? (
                                <>
                                    <strong>Draft with Copilot</strong> hands the measured rows and queries to your own GitHub Copilot.
                                </>
                            ) : (
                                <>
                                    There's no <strong>Draft with Copilot</strong> for a lone incident request, only for a session: a request's minutes are its fault's own, so they'd tell the chat where to look.
                                    {rootCause ? (
                                        <>
                                            {" "}
                                            The <strong>Root cause</strong> page finds the incidents from the signals alone and explains each one.
                                        </>
                                    ) : null}
                                </>
                            )}
                        </p>
                        {investigating ? <Spinner size="small" label="Investigating the session's minutes for the Cause, which can take a minute or two…" /> : null}
                        {postmortem ? <MarkdownView markdown={postmortem.markdown} /> : null}
                    </DialogContent>
                    <DialogActions>
                        <Button
                            appearance="primary"
                            icon={<ArrowDownload16Regular />}
                            disabled={!postmortem}
                            onClick={() => {
                                if (!postmortem) return;
                                downloadText(postmortem.fileName, postmortem.markdown, "text/markdown;charset=utf-8");
                                notify(`Downloaded ${postmortem.fileName}`, "success");
                            }}
                        >
                            Download Markdown
                        </Button>
                        <Button
                            icon={<Copy16Regular />}
                            disabled={!postmortem}
                            onClick={async () => {
                                if (postmortem) notify((await copyText(postmortem.markdown)) ? "Postmortem copied as Markdown" : "Copy is blocked here: use Download Markdown", "info");
                            }}
                        >
                            Copy
                        </Button>
                        {drafts ? (
                            <Button
                                icon={<Sparkle16Filled />}
                                onClick={() => {
                                    if (!input) return;
                                    copilot.ask(postmortemAsk(input));
                                    onClose();
                                }}
                            >
                                Draft with Copilot
                            </Button>
                        ) : null}
                    </DialogActions>
                </DialogBody>
            </DialogSurface>
        </Dialog>
    );
}
