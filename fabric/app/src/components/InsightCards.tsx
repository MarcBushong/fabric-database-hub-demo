import { motion } from "framer-motion";
import { ArrowRight, Copy, Sparkles } from "lucide-react";

import { useApp } from "@/app-context";
import { copyText } from "@/lib/clipboard";
import type { Insight } from "@/lib/insights";
import { statusClass, statusMeta } from "@/lib/status";
import { StatusShape } from "./StatusBadge";

const TOKEN_COLOR: Record<string, string> = {
    "--status-fail": "var(--status-fail)",
    "--status-manual": "var(--status-manual)",
    "--status-warning": "var(--status-warning)",
    "--status-pass": "var(--status-pass)",
    "--status-muted": "var(--status-muted)",
};

/** Rule-based insight cards: a number, a sentence, the numbers behind it, and a jump to the evidence. */
export function InsightCards({ insights, label }: { insights: Insight[]; label: string }) {
    const { setView, notify, reducedMotion } = useApp();
    if (insights.length === 0) return null;
    return (
        <section className="insights" aria-label={label}>
            {insights.map((insight, i) => {
                const meta = insight.status ? statusMeta(insight.status) : null;
                const color = meta ? TOKEN_COLOR[meta.token] : "var(--accent)";
                return (
                    <motion.article
                        key={insight.id}
                        className="insight glass"
                        style={{ ["--insight-color" as string]: color }}
                        initial={reducedMotion ? false : { opacity: 0, y: 14, scale: 0.98 }}
                        animate={{ opacity: 1, y: 0, scale: 1 }}
                        transition={{ duration: 0.5, delay: reducedMotion ? 0 : i * 0.07, ease: [0.16, 1, 0.3, 1] }}
                    >
                        <div className="dax-meta">
                            {meta ? (
                                <span className={`status ${statusClass(meta)}`}>
                                    <StatusShape meta={meta} />
                                    {meta.short}
                                </span>
                            ) : (
                                <span className="status" style={{ color: "var(--accent)" }}>
                                    <Sparkles aria-hidden="true" width={16} height={16} />
                                    Insight
                                </span>
                            )}
                        </div>
                        <div className="metric" style={{ color }}>
                            {insight.metric}
                        </div>
                        <p className="title">{insight.title}</p>
                        <p className="detail">{insight.detail}</p>
                        <div className="insight-actions">
                            {insight.page ? (
                                <button
                                    type="button"
                                    className="icon-btn"
                                    onClick={() => setView({ page: insight.page, ...(insight.incident ? { incident: insight.incident, replay: null } : {}) })}
                                >
                                    Show me <ArrowRight aria-hidden="true" />
                                </button>
                            ) : null}
                            <button
                                type="button"
                                className="icon-btn"
                                aria-label="Copy this insight"
                                title="Copy this insight"
                                onClick={async () => notify((await copyText(`${insight.title} ${insight.detail}`)) ? "Insight copied" : "Copy is blocked here")}
                            >
                                <Copy aria-hidden="true" />
                            </button>
                        </div>
                    </motion.article>
                );
            })}
        </section>
    );
}
