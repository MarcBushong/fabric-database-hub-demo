import type { ReactNode } from "react";

import { statusTone } from "@/lib/status";

export interface KpiTileProps {
    label: string;
    value: string;
    /** A line under the value: the comparison, the peak, the window. */
    sub?: ReactNode;
    /** An ADR 0012 status that colors the tile's rail; its word is in `sub` or the label. */
    status?: string | null;
    icon?: ReactNode;
    /** Opens the drill-down. */
    onOpen?: () => void;
    openLabel?: string;
    /** "Ask why" and other actions. */
    actions?: ReactNode;
}

/** A dense, readable number with its context; opens its drill-down when it has one. */
export function KpiTile(props: KpiTileProps) {
    const tone = statusTone(props.status);
    const content = (
        <>
            <span className="kpi-label">
                {props.icon ? <span className="kpi-icon" aria-hidden="true">{props.icon}</span> : null}
                {props.label}
            </span>
            <span className="kpi-value">{props.value}</span>
            {props.sub ? <span className="kpi-sub">{props.sub}</span> : null}
        </>
    );
    return (
        <div className={`kpi kpi-${tone}`}>
            {props.onOpen ? (
                <button type="button" className="kpi-main" onClick={props.onOpen} aria-label={props.openLabel ? `${props.label}: ${props.value}. ${props.openLabel}` : undefined}>
                    {content}
                </button>
            ) : (
                <div className="kpi-main">{content}</div>
            )}
            {props.actions ? <div className="kpi-actions">{props.actions}</div> : null}
        </div>
    );
}
