import type { ReactNode } from "react";
import { Breadcrumb, BreadcrumbButton, BreadcrumbDivider, BreadcrumbItem } from "@fluentui/react-components";

import { GlobalFilter } from "./GlobalFilter";

export interface Crumb {
    label: string;
    onClick?: () => void;
}

/** A page's header: breadcrumbs for drill-downs, the title and what it answers, actions, and the global filter. */
export function PageHeader({ title, description, crumbs, actions, filter = true }: { title: ReactNode; description?: ReactNode; crumbs?: Crumb[]; actions?: ReactNode; filter?: boolean }) {
    return (
        <header className="page-head">
            {crumbs && crumbs.length > 0 ? (
                <Breadcrumb aria-label="Where you are" size="small">
                    {crumbs.map((c, i) => (
                        <span key={`${c.label}-${i}`} className="crumb">
                            <BreadcrumbItem>
                                <BreadcrumbButton onClick={c.onClick} current={i === crumbs.length - 1}>
                                    {c.label}
                                </BreadcrumbButton>
                            </BreadcrumbItem>
                            {i < crumbs.length - 1 ? <BreadcrumbDivider /> : null}
                        </span>
                    ))}
                </Breadcrumb>
            ) : null}
            <div className="page-title-row">
                <div className="page-titles">
                    <h1>{title}</h1>
                    {description ? <p>{description}</p> : null}
                </div>
                {actions ? <div className="page-actions">{actions}</div> : null}
            </div>
            {filter ? <GlobalFilter /> : null}
        </header>
    );
}
