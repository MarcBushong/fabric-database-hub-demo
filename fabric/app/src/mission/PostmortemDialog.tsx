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
import { toCosmosCapture, toPostgresCapture } from "@/data/model";
import { cosmosFindingsQuery, cosmosSeriesQuery, postgresSeriesQuery, type QuerySpec } from "@/data/queries";
import type { QueryClient } from "@/data/query-client";
import { QueryClientContext } from "@/data/use-query";
import { copyText } from "@/lib/clipboard";
import { downloadText } from "@/lib/csv";
import { buildPostmortem, causeWindow, draftsWithCopilot, postmortemAsk, postmortemTitle, type HiddenCaptures, type PostmortemInput } from "@/lib/postmortem";
import { cosmosEpisodes, episodesIn, postgresEpisodes, type MeasuredEpisode, type Plan } from "@/lib/scoreboard";
import { createRcaClient } from "@/rca/client";
import { blindCauses, type BlindCauses } from "@/rca/postmortem";
import { MarkdownView } from "./parts";

const message = (err: unknown) => (err instanceof Error ? err.message : String(err));

/**
 * T4's and T5's episodes in a plan's window on the targets the page's filter hides, for the answer key (the review of
 * b4370565): the investigation reads every target, and the page loads their captures only when its filter shows them. A
 * capture that can't be read is said in the key, never taken for a quiet target.
 */
async function hiddenCaptures(client: QueryClient, hidden: ReadonlyArray<"T4" | "T5">, plan: Plan): Promise<HiddenCaptures> {
    const specs: QuerySpec[] = [];
    const found: MeasuredEpisode[] = [];
    const errors: string[] = [];
    const missing = (target: string, err: unknown) => `${target}'s Azure Monitor capture couldn't be read for this key, so its episodes aren't in it: ${message(err)}`;
    if (hidden.includes("T4")) {
        const series = postgresSeriesQuery();
        specs.push(series);
        try {
            found.push(...postgresEpisodes(toPostgresCapture((await client.run(series)).rows)));
        } catch (err) {
            errors.push(missing("T4", err));
        }
    }
    if (hidden.includes("T5")) {
        const series = cosmosSeriesQuery();
        const findings = cosmosFindingsQuery();
        specs.push(series, findings);
        try {
            const [s, f] = await Promise.all([client.run(series), client.run(findings)]);
            found.push(...cosmosEpisodes(toCosmosCapture(s.rows), f.rows));
        } catch (err) {
            errors.push(missing("T5", err));
        }
    }
    return { episodes: episodesIn(found, plan).sort((a, b) => a.visibleAt.getTime() - b.visibleAt.getTime()), specs, errors };
}

/** Open while `input` is set; its `generatedAt` is when the viewer asked for it. */
export function PostmortemDialog({ input, onClose }: { input: PostmortemInput | null; onClose: () => void }) {
    const { notify, rca, rcaError, view } = useApp();
    const copilot = useCopilot();
    const queryClient = useContext(QueryClientContext);
    // With the RCA tables, the Cause is the blind investigation of a session's minutes, once each time it's asked for; a
    // lone incident request's minutes are its fault's own, so they're never investigated (causeWindow, the review of
    // 63fb530c).
    const minutes = useMemo(() => (input ? causeWindow(input.plan, input.nextSessionStart ?? null) : null), [input]);
    const investigates = minutes !== null && rca === true && queryClient !== null;
    const key = input ? `${input.plan.key}|${input.generatedAt.toISOString()}` : "";
    // The investigation reads every target, so its answer key does too: T4's and T5's captures, which the page loads only
    // when its filter shows them, load here when it hides them (the review of b4370565).
    const hiddenTargets = useMemo(() => (["T4", "T5"] as const).filter((t) => !view.targets.includes(t)), [view.targets]);
    const [investigated, setInvestigated] = useState<{ key: string; value: BlindCauses; hidden: HiddenCaptures } | null>(null);
    useEffect(() => {
        if (!input || !minutes || rca !== true || !queryClient) return;
        const asked = `${input.plan.key}|${input.generatedAt.toISOString()}`;
        const { from, to } = minutes;
        let alive = true;
        // Closed or asked again: the investigation explains no further incident.
        const stop = new AbortController();
        const cause = blindCauses(createRcaClient(queryClient, { timeZone: "UTC" }), from, to, stop.signal).catch((err: unknown): BlindCauses => ({ from, to, causes: [], notCaptured: [], queries: [], error: message(err) }));
        const hidden = hiddenCaptures(queryClient, hiddenTargets, input.plan).catch((err: unknown): HiddenCaptures => ({ episodes: [], specs: [], errors: [`T4's and T5's captures couldn't be read for this key: ${message(err)}`] }));
        void Promise.all([cause, hidden]).then(([value, captures]) => alive && setInvestigated({ key: asked, value, hidden: captures }));
        return () => {
            alive = false;
            stop.abort();
        };
    }, [input, minutes, queryClient, rca, hiddenTargets]);
    // The blind Cause; "request" for a lone request's pointer to the Root cause page; undefined while it's investigated;
    // null for the Cause as it was, without the RCA tables. A failed check of the tables is said in the Cause, never taken
    // for their absence.
    const cause = useMemo((): BlindCauses | "request" | null | undefined => {
        if (!input) return null;
        const checkFailed = rca !== true && rca !== false && !!rcaError;
        if (!minutes) return rca === true || checkFailed ? "request" : null;
        if (investigates) return investigated && investigated.key === key ? investigated.value : undefined;
        if (checkFailed) return { from: minutes.from, to: minutes.to, causes: [], notCaptured: [], queries: [], error: `the check of the Incident RCA's tables failed: ${rcaError}` };
        return null;
    }, [input, minutes, investigates, investigated, key, rca, rcaError]);
    const investigating = cause === undefined;
    const hiddenFound = investigates && investigated && investigated.key === key ? investigated.hidden : null;
    const postmortem = useMemo(() => (input && cause !== undefined ? buildPostmortem({ ...input, rca: cause, hidden: hiddenFound }) : null), [input, cause, hiddenFound]);
    const causeText = cause === null ? "what was injected" : cause === "request" ? "what was injected, labeled as the answer key, with the Root cause page for the cause" : "a blind investigation of the session's minutes for the Cause, as on the Root cause page, then what was injected, labeled as the answer key";
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
                            Written from the history alone, so it works without a GitHub sign-in: {causeText}, when each signal showed in the telemetry, the response, and the recovery, with every query behind it.{" "}
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
