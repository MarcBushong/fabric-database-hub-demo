import type { ReactNode } from "react";

/** What a page or a visual shows when there's nothing yet: what fills it, and the one thing to do. */
export function EmptyState({ icon, title, children, actions, compact = false }: { icon?: ReactNode; title: string; children?: ReactNode; actions?: ReactNode; compact?: boolean }) {
    return (
        <div className={`empty-state${compact ? " compact" : ""}`} role="status">
            {icon ? <div className="empty-icon" aria-hidden="true">{icon}</div> : null}
            <p className="empty-title">{title}</p>
            {children ? <div className="empty-body">{children}</div> : null}
            {actions ? <div className="empty-actions">{actions}</div> : null}
        </div>
    );
}
