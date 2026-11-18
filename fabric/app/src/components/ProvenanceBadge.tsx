import { Tooltip } from "@fluentui/react-components";
import { Beaker16Regular, History16Regular, Live20Regular } from "@fluentui/react-icons";

import type { DataProvenance } from "@/copilot/contract";
import { formatAgo } from "@/lib/format";

const TEXT: Record<DataProvenance, { label: string; tip: string }> = {
    history: {
        label: "History",
        tip: "From the lakehouse history (SM_DatabaseHub_History): snapshots NB_DatabaseHub_LiveActivity saves, kept past the telemetry's 7 days. Not live; open Database Hub for live.",
    },
    live: { label: "Live", tip: "Read live from Database Hub's estate when the page opened." },
    sample: { label: "Sample data", tip: "Made-up data for the local preview. The deployed app shows the demo's own history." },
};

/** Says where a visual's data comes from, and how fresh it is. */
export function ProvenanceBadge({ provenance, asOf, compact = false }: { provenance: DataProvenance; asOf?: Date | null; compact?: boolean }) {
    const text = TEXT[provenance];
    const Icon = provenance === "live" ? Live20Regular : provenance === "sample" ? Beaker16Regular : History16Regular;
    const age = asOf && provenance !== "live" ? ` · ${formatAgo(asOf)}` : "";
    return (
        <Tooltip content={text.tip} relationship="description" withArrow>
            <span className={`provenance provenance-${provenance}`} tabIndex={0}>
                <Icon aria-hidden={true} />
                {compact ? text.label : `${text.label}${age}`}
            </span>
        </Tooltip>
    );
}
