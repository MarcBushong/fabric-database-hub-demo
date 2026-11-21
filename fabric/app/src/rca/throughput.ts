// Why T5's normalized RU consumption reached 100 % (ADR 0031), from Azure Monitor's metrics in the history, since T5 has no
// observer: NormalizedRUConsumption, the busiest partition key range's share of its RU/s in the busiest second of each
// interval (the highest in each); TotalRequests; and ThrottledRequests, the requests answered 429. At 100 %, a request to
// that range in that second is throttled (429), and the client retries it after the time the service gives.
//   RU-THROTTLED   requests were throttled in those minutes
//   RU-AT-LIMIT    it reached 100 % without throttling a request
// Live, 2026-11-21's audit: the RCA view explained a 100 % episode only through its 429s, so one without any had no cause.
// https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units

import { COSMOS_METRICS } from "@/data/model";
import { recommend } from "./catalog";
import { hhmmss, iso, metricIn, plural, type Confidence, type EvidenceRef, type Finding, type MetricPoint, type Recommendation } from "./types";

export interface ThroughputAnalysis {
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    notCaptured: string[];
    details: Record<string, unknown>;
}

const hhmm = (d: Date) => hhmmss(d).slice(0, 5);

export function analyzeThroughput(input: { from: Date; to: Date; metrics: readonly MetricPoint[] }): ThroughputAnalysis {
    const { from, to } = input;
    const series = (metric: string) => input.metrics.filter((m) => m.target === "T5" && m.metric === metric && m.value !== null && metricIn(m, from, to)).sort((a, b) => a.at.getTime() - b.at.getTime());
    const normalized = series(COSMOS_METRICS.normalizedRu);
    const requests = series(COSMOS_METRICS.requests);
    const throttled = series(COSMOS_METRICS.throttled);
    if (normalized.length === 0) {
        return { findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: [`T5: Azure Monitor's normalized RU consumption isn't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC.`], details: {} };
    }
    const end = (m: MetricPoint) => new Date(m.at.getTime() + (m.intervalMs ?? 0));
    const minutes = Math.round((normalized[0].intervalMs ?? 60_000) / 60_000);
    const full = normalized.filter((m) => (m.value ?? 0) >= 100);
    const peak = normalized.reduce((best, m) => ((m.value ?? 0) > (best.value ?? 0) ? m : best));
    const at100 = full.length ? full : [peak];
    const sum = (rows: readonly MetricPoint[]) => rows.reduce((n, m) => n + (m.value ?? 0), 0);
    const total = requests.length ? sum(requests) : null;
    const refused = throttled.length ? sum(throttled) : null;
    const share = total && refused !== null ? Math.round((1000 * refused) / total) / 10 : null;
    const reached = `T5's normalized RU consumption (the busiest partition key range's share of its RU/s; Azure Monitor keeps the highest in each ${minutes}-minute interval) reached ${Math.round(peak.value ?? 0)} % ${full.length > 1 ? `in ${full.length} intervals from ${hhmm(at100[0].at)} to ${hhmm(end(at100[at100.length - 1]))} UTC` : `in the interval from ${hhmm(peak.at)} to ${hhmm(end(peak))} UTC`}.`;
    const counted =
        refused === null
            ? ""
            : refused > 0
              ? ` Azure Monitor counted ${total !== null ? `${plural(total, "request")} in those minutes, ${refused} of them throttled (429${share !== null ? `, ${share} %` : ""})` : `${plural(refused, "throttled request")} (429) in those minutes`}: requests past a range's share in a second were refused, and their clients retried after the time the service gave.`
              : ` Azure Monitor counted ${total !== null ? `${plural(total, "request")} in those minutes, none of them throttled` : "no throttled request (429) in those minutes"}: the container used its throughput to the limit without refusing a request.`;
    const ruleId = refused !== null && refused > 0 ? "RU-THROTTLED" : "RU-AT-LIMIT";
    const statement = `${reached}${counted}`;
    const notCaptured = [
        "T5: which partition key range was busiest, and which operations used the RU/s, aren't in the history: it keeps the container's highest normalized RU consumption and its request counts.",
        ...(refused === null ? [`T5: Azure Monitor's throttled requests aren't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC, so whether any request was refused isn't known.`] : []),
    ];
    const evidence: EvidenceRef[] = [
        { table: "Telemetry Snapshots", at: iso(peak.at), target: "T5", text: `Normalized RU consumption ${Math.round(peak.value ?? 0)} %, the highest from ${hhmm(peak.at)} to ${hhmm(end(peak))} UTC` },
        ...throttled.filter((m) => (m.value ?? 0) > 0).slice(0, 2).map((m) => ({ table: "Telemetry Snapshots", at: iso(m.at), target: "T5" as const, text: `${plural(m.value ?? 0, "throttled request")} (429) from ${hhmm(m.at)} to ${hhmm(end(m))} UTC` })),
    ];
    const ids = ruleId === "RU-THROTTLED" ? ["RU-RETRY", "RU-PARTITION", "RU-AUTOSCALE"] : ["RU-PARTITION", "RU-AUTOSCALE"];
    return {
        findings: [{ ruleId, target: "T5", severity: ruleId === "RU-THROTTLED" ? "critical" : "warning", title: `T5: normalized RU consumption ${Math.round(peak.value ?? 0)} %`, detail: statement, evidence }],
        rootCause: { statement, confidence: "medium", ruleIds: [ruleId], evidence },
        recommendations: recommend(...ids),
        nextSteps: [
            "In Azure Monitor, split Normalized RU Consumption by PartitionKeyRangeId for the same minutes: one range at 100 % while the others stay low is a hot partition.",
            "Filter Total Requests to status code 429 and split them by operation type for the same minutes.",
        ],
        notCaptured,
        details: { peak: { at: iso(peak.at), percent: peak.value }, intervalsAt100: full.length, requests: total, throttled: refused },
    };
}
