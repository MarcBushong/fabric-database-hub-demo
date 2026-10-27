import { statusClass, statusMeta, type StatusMeta } from "@/lib/status";

/** The status's shape as a 16 px SVG: octagon (Fail), flag (Manual), triangle (Warning), circle (Pass), slash, ring. */
export function StatusShape({ meta, size = 16 }: { meta: StatusMeta; size?: number }) {
    const common = { width: size, height: size, viewBox: "0 0 16 16", "aria-hidden": true as const, focusable: "false" as const };
    switch (meta.shape) {
        case "octagon":
            return (
                <svg {...common}>
                    <polygon points="5,1 11,1 15,5 15,11 11,15 5,15 1,11 1,5" fill="currentColor" />
                    <path d="M5.5 5.5l5 5M10.5 5.5l-5 5" stroke="var(--bg)" strokeWidth="1.8" strokeLinecap="round" />
                </svg>
            );
        case "flag":
            return (
                <svg {...common}>
                    <path d="M3 15V1.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
                    <path d="M3.8 2h9l-2.2 3.4 2.2 3.4h-9z" fill="currentColor" />
                </svg>
            );
        case "triangle":
            return (
                <svg {...common}>
                    <polygon points="8,1 15.5,14.5 0.5,14.5" fill="currentColor" />
                    <path d="M8 6v4" stroke="var(--bg)" strokeWidth="1.8" strokeLinecap="round" />
                    <circle cx="8" cy="12.2" r="1" fill="var(--bg)" />
                </svg>
            );
        case "circle":
            return (
                <svg {...common}>
                    <circle cx="8" cy="8" r="7" fill="currentColor" />
                    <path d="M4.6 8.2l2.3 2.3 4.6-4.8" fill="none" stroke="var(--bg)" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
            );
        case "slash":
            return (
                <svg {...common}>
                    <circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" strokeWidth="1.8" />
                    <path d="M3.6 12.4l8.8-8.8" stroke="currentColor" strokeWidth="1.8" />
                </svg>
            );
        default:
            return (
                <svg {...common}>
                    <circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" strokeWidth="1.8" />
                </svg>
            );
    }
}

/** Color, shape, and the status word together, so color is never the only signal. */
export function StatusBadge({ status, short = false }: { status: unknown; short?: boolean }) {
    const meta = statusMeta(status);
    return (
        <span className={`status ${statusClass(meta)}`} title={meta.meaning}>
            <StatusShape meta={meta} />
            {short ? meta.short : meta.name}
        </span>
    );
}
