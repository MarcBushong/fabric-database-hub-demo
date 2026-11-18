import { Button } from "@fluentui/react-components";
import { ArrowRight16Regular, Lightbulb16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import type { Insight } from "@/lib/insights";
import { AskWhy } from "./AskWhy";
import { StatusBadge } from "./StatusBadge";

/** Rule-based insights: plain sentences computed from the query results in the browser, each with its evidence. */
export function Insights({ insights, label, page }: { insights: Insight[]; label: string; page: string }) {
    const { navigate } = useApp();
    if (insights.length === 0) return null;
    return (
        <section className="insights" aria-label={label}>
            <h3 className="section-title">
                <Lightbulb16Regular aria-hidden={true} /> {label}
            </h3>
            <ul>
                {insights.map((insight) => (
                    <li key={insight.id} className={`insight insight-${insight.status ? insight.status.toLowerCase().replace(/\s+/g, "-") : "neutral"}`}>
                        <span className="insight-metric">{insight.metric}</span>
                        <div className="insight-text">
                            <p className="insight-title">
                                {insight.status ? <StatusBadge status={insight.status} short /> : null} {insight.title}
                            </p>
                            <p className="insight-detail">{insight.detail}</p>
                        </div>
                        <div className="insight-actions">
                            {insight.status === "Warning" || insight.status === "Fail" ? (
                                <AskWhy
                                    prompt={`${insight.title} ${insight.detail} Why did this happen, and what should I check first?`}
                                    title={insight.title}
                                    visualId={`${page}.insight.${insight.id}`}
                                    anomaly={{ metric: insight.metric, ...(insight.incident ? { incidentKey: insight.incident } : {}), ...(insight.target ? { target: insight.target } : {}) }}
                                />
                            ) : null}
                            {insight.page ? (
                                <Button
                                    size="small"
                                    appearance="transparent"
                                    icon={<ArrowRight16Regular />}
                                    iconPosition="after"
                                    onClick={() => navigate(insight.page!, { ...(insight.incident ? { incident: insight.incident, replay: null } : {}), ...(insight.target ? { target: insight.target } : {}) })}
                                >
                                    Show me
                                </Button>
                            ) : null}
                        </div>
                    </li>
                ))}
            </ul>
        </section>
    );
}
