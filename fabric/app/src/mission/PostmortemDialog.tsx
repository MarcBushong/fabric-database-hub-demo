// One-click postmortem (ADR 0030): the session's write-up from the data alone, previewed, downloaded as Markdown, or
// copied; and "Draft with Copilot", which hands the same rows and queries to the viewer's own Copilot through the app's
// existing ask contract. Nothing is stored: the download is the record.

import { useMemo } from "react";
import { Button, Dialog, DialogActions, DialogBody, DialogContent, DialogSurface, DialogTitle } from "@fluentui/react-components";
import { ArrowDownload16Regular, Copy16Regular, Dismiss20Regular, Sparkle16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilot } from "@/copilot/use-copilot";
import { copyText } from "@/lib/clipboard";
import { downloadText } from "@/lib/csv";
import { buildPostmortem, postmortemAsk, type PostmortemInput } from "@/lib/postmortem";
import { MarkdownView } from "./parts";

/** Open while `input` is set; its `generatedAt` is when the viewer asked for it. */
export function PostmortemDialog({ input, onClose }: { input: PostmortemInput | null; onClose: () => void }) {
    const { notify } = useApp();
    const copilot = useCopilot();
    const postmortem = useMemo(() => (input ? buildPostmortem(input) : null), [input]);
    return (
        <Dialog open={postmortem !== null} onOpenChange={(_, data) => (data.open ? undefined : onClose())}>
            <DialogSurface className="pm-surface" aria-describedby={undefined}>
                <DialogBody>
                    <DialogTitle action={<Button appearance="subtle" aria-label="Close" icon={<Dismiss20Regular />} onClick={onClose} />}>{postmortem?.title ?? "Postmortem"}</DialogTitle>
                    <DialogContent>
                        <p className="pm-lead">
                            Written from the history alone, so it works without a GitHub sign-in: what was injected, when each signal showed in the telemetry, the response, and the recovery, with every query behind it. <strong>Draft with Copilot</strong> hands the same rows and queries to your own GitHub Copilot.
                        </p>
                        {postmortem ? <MarkdownView markdown={postmortem.markdown} /> : null}
                    </DialogContent>
                    <DialogActions>
                        <Button
                            appearance="primary"
                            icon={<ArrowDownload16Regular />}
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
                            onClick={async () => {
                                if (postmortem) notify((await copyText(postmortem.markdown)) ? "Postmortem copied as Markdown" : "Copy is blocked here: use Download Markdown", "info");
                            }}
                        >
                            Copy
                        </Button>
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
                    </DialogActions>
                </DialogBody>
            </DialogSurface>
        </Dialog>
    );
}
