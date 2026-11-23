import { TARGETS } from "@/lib/estate";
import { isEstateTarget } from "@/lib/view-state";

/** A target's short name with its color swatch; color is never the only label. */
export function TargetChip({ target, full = false }: { target: string; full?: boolean }) {
    const info = isEstateTarget(target) ? TARGETS[target] : null;
    return (
        <span className="target-chip">
            <i style={{ background: info?.color ?? "var(--colorNeutralStroke1)" }} aria-hidden="true" />
            {info ? (full ? `${info.short} · ${info.name}` : info.short) : target}
        </span>
    );
}
