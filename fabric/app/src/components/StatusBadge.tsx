import { CheckmarkCircle16Filled, Circle16Regular, ErrorCircle16Filled, Flag16Filled, SubtractCircle16Regular, Warning16Filled } from "@fluentui/react-icons";
import type { ComponentType } from "react";

import { statusMeta, type StatusName } from "@/lib/status";

const ICONS: Record<StatusName, ComponentType<{ "aria-hidden"?: boolean; className?: string }>> = {
    Fail: ErrorCircle16Filled,
    "Manual action required": Flag16Filled,
    Warning: Warning16Filled,
    Pass: CheckmarkCircle16Filled,
    "Not supported": SubtractCircle16Regular,
    "Not selected": Circle16Regular,
};

const CLASS: Record<StatusName, string> = {
    Fail: "fail",
    "Manual action required": "manual",
    Warning: "warning",
    Pass: "pass",
    "Not supported": "muted",
    "Not selected": "muted",
};

/** An ADR 0012 status: an icon with its own shape, and its word, never color alone. Empty statuses render nothing. */
export function StatusBadge({ status, short = false, className }: { status: unknown; short?: boolean; className?: string }) {
    if (typeof status !== "string" || !status.trim()) return null;
    const meta = statusMeta(status);
    const Icon = ICONS[meta.name];
    return (
        <span className={`status-badge status-${CLASS[meta.name]}${className ? ` ${className}` : ""}`} title={meta.meaning}>
            <Icon aria-hidden={true} />
            {short ? meta.short : meta.name}
        </span>
    );
}
