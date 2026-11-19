import { Tooltip } from "@fluentui/react-components";
import { Beaker16Regular, History16Regular, Live20Regular, LiveOff20Regular } from "@fluentui/react-icons";

import type { DataProvenance } from "@/copilot/contract";
import { formatAgo, formatDateTimeUtc } from "@/lib/format";

const TEXT: Record<DataProvenance, { label: string; tip: string }> = {
    history: {
        label: "History",
        tip: "From the lakehouse history (SM_DatabaseHub_History): snapshots NB_DatabaseHub_LiveActivity saves, kept past the telemetry's 7 days. Not live; open Database Hub for live.",
    },
    live: { label: "Live", tip: "Read live from Database Hub through the app's function: its read-only routes, scoped to the demo's resource groups, cached for a minute." },
    sample: { label: "Sample data", tip: "Made-up data for the local preview. The deployed app shows the demo's own history." },
};

/** A live source with no live answer yet (reading) or none at all (unavailable): neutral, so only real live data is green. */
export type LiveState = "reading" | "unavailable";

const OFF: Record<LiveState, { label: string; tip: string }> = {
    reading: { label: "Live \u00b7 reading\u2026", tip: "Reading Database Hub through the app's function: a first read takes 5 to 12 seconds." },
    unavailable: { label: "Live \u00b7 unavailable", tip: "Nothing is read live in this app right now: every page shows the history. Database Hub has the live view." },
};

/** Says where a visual's data comes from, and how fresh it is; label and tip name a source of their own (saved at deploy). */
export function ProvenanceBadge({ provenance, asOf, compact = false, liveState, label, tip }: { provenance: DataProvenance; asOf?: Date | null; compact?: boolean; liveState?: LiveState; label?: string; tip?: string }) {
    if (provenance === "live" && liveState) {
        const off = OFF[liveState];
        return (
            <Tooltip content={off.tip} relationship="description" withArrow>
                <span className="provenance provenance-off" tabIndex={0}>
                    <LiveOff20Regular aria-hidden={true} />
                    {off.label}
                </span>
            </Tooltip>
        );
    }
    const text = { label: label ?? TEXT[provenance].label, tip: tip ?? TEXT[provenance].tip };
    const Icon = provenance === "live" ? Live20Regular : provenance === "sample" ? Beaker16Regular : History16Regular;
    const age = asOf ? (provenance === "live" ? ` · as of ${formatDateTimeUtc(asOf)}` : ` · ${formatAgo(asOf)}`) : "";
    return (
        <Tooltip content={text.tip} relationship="description" withArrow>
            <span className={`provenance provenance-${provenance}`} tabIndex={0}>
                <Icon aria-hidden={true} />
                {compact ? text.label : `${text.label}${age}`}
            </span>
        </Tooltip>
    );
}
