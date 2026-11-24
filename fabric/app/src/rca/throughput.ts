// Why T5's normalized RU consumption reached 100 % (ADR 0031), from Azure Monitor's metrics in the history, since T5 has no
// observer: NormalizedRUConsumption, the busiest partition key range's share of its RU/s in the busiest second of each
// interval (the highest in each); TotalRequests; ThrottledRequests, the requests answered 429; and ProvisionedThroughput,
// hourly. 100 % only means that in at least one second, at least one partition key range used all of its share of the
// RU/s: a request to it in that second is throttled (429) and told how long to wait before it retries. Learn counts 1 to
// 5 % of requests throttled, with acceptable latency, as RU/s fully used, with no action needed, and recommends more
// throughput above 5 %.
//   RU-THROTTLED   requests were throttled in those intervals
//   RU-AT-LIMIT    it reached 100 % without throttling a request
// Live, 2026-11-21's audit: the RCA view explained a 100 % episode only through its 429s, so one without any had no cause.
// The review of 4e2c65ed: the counts are those of the intervals the sentence names, and nothing is recommended that the
// evidence can't support: no change without a 429, more throughput only above Learn's 5 %, and a new partition key only
// for a container that has more than one physical partition, since one physical partition's ranges share all its RU/s.
// https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units,
// https://learn.microsoft.com/azure/cosmos-db/partitioning-overview#physical-partitions

import { COSMOS_METRICS } from "@/data/model";
import { recommend } from "./catalog";
import { asWholeReadings, hhmmss, iso, metricIn, plural, type Confidence, type EvidenceRef, type Finding, type MetricPoint, type Recommendation } from "./types";

export interface ThroughputAnalysis {
    findings: Finding[];
    rootCause: { statement: string; confidence: Confidence; ruleIds: string[]; evidence: EvidenceRef[] } | null;
    recommendations: Recommendation[];
    nextSteps: string[];
    notCaptured: string[];
    details: Record<string, unknown>;
}

/** The RU/s one physical partition serves at most (Learn: partitioning overview, physical partitions). */
export const PARTITION_RU = 10_000;
/** The share of requests throttled above which Learn recommends more throughput. */
export const THROTTLED_SHARE = 5;

const hhmm = (d: Date) => hhmmss(d).slice(0, 5);

export function analyzeThroughput(input: { from: Date; to: Date; metrics: readonly MetricPoint[] }): ThroughputAnalysis {
    const { from, to } = input;
    // A split point's pieces in these minutes as its one whole reading, over its save's whole interval (the review of c4c63abe).
    const series = (metric: string) => asWholeReadings(input.metrics.filter((m) => m.target === "T5" && m.metric === metric && metricIn(m, from, to))).filter((m) => m.value !== null);
    const normalized = series(COSMOS_METRICS.normalizedRu);
    const requests = series(COSMOS_METRICS.requests);
    const throttled = series(COSMOS_METRICS.throttled);
    if (normalized.length === 0) {
        return { findings: [], rootCause: null, recommendations: [], nextSteps: [], notCaptured: [`T5: Azure Monitor's normalized RU consumption isn't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC.`], details: {} };
    }
    const end = (m: MetricPoint) => new Date(m.at.getTime() + (m.intervalMs ?? 0));
    // An interval whose length the read can't tell is said from its start only, and its counts as at its time (the review
    // of c4c63abe: a 60-minute save's one point read "each 1-minute interval … from 15:00 to 15:00 UTC").
    const until = (m: MetricPoint) => (m.intervalUnknown ? "" : ` to ${hhmm(end(m))}`);
    const full = normalized.filter((m) => (m.value ?? 0) >= 100);
    const peak = normalized.reduce((best, m) => ((m.value ?? 0) > (best.value ?? 0) ? m : best));
    const at100 = full.length ? full : [peak];
    // Azure Monitor's interval, its save's (the shared finestPerInterval's grains). A remainder of a coarser point, or an
    // interval its save's window cuts, spans only part of it, and its value is the highest in its own minutes, which the
    // sentence gives: so it's never named by its save's interval beside them, as the replica's isn't (the review of
    // 96abcf65, after F4's grain).
    const minutes = Math.round((at100[0].grainMs ?? at100[0].intervalMs ?? 60_000) / 60_000);
    const partial = at100.some((m) => !m.intervalUnknown && Math.round((m.intervalMs ?? 0) / 60_000) < Math.round((m.grainMs ?? m.intervalMs ?? 0) / 60_000));
    const each = at100[0].intervalUnknown ? "each interval of its save, whose length isn't known in these minutes" : partial ? "each interval" : `each ${minutes}-minute interval`;
    // Only the intervals the sentence names (the review of 4e2c65ed: a window a minute past the episode added the next one).
    const named = (m: MetricPoint) => at100.some((n) => m.at.getTime() >= n.at.getTime() && m.at.getTime() < Math.max(end(n).getTime(), n.at.getTime() + 1));
    const sum = (rows: readonly MetricPoint[]) => rows.reduce((n, m) => n + (m.value ?? 0), 0);
    const requestsIn = requests.filter(named);
    const throttledIn = throttled.filter(named);
    const total = requestsIn.length ? sum(requestsIn) : null;
    const refused = throttledIn.length ? sum(throttledIn) : null;
    const share = total && refused !== null ? Math.round((1000 * refused) / total) / 10 : null;
    // The latest provisioned throughput at or before the window's end, the hour it stands for.
    const provisionedPoint = input.metrics.filter((m) => m.target === "T5" && m.metric === COSMOS_METRICS.provisioned && m.value !== null && m.at <= to).sort((a, b) => a.at.getTime() - b.at.getTime()).pop();
    const provisioned = provisionedPoint?.value ?? null;

    // The intervals between the first at 100 % and the last: "each of the 9" only when none is under it. Final tests' check
    // of ddebd4c3 (F6): 9 of the 11 from 15:31 to 15:42 read as all of them, and the 429s of the other 2 were in the page's
    // errors only (14,593 there, 13,222 here).
    const [first, last] = [at100[0].at.getTime(), at100[at100.length - 1].at.getTime()];
    const lower = full.length > 1 ? normalized.filter((m) => m.at.getTime() > first && m.at.getTime() < last && (m.value ?? 0) < 100) : [];
    const those = at100.length > 1 ? (lower.length > 0 ? `those ${full.length} intervals` : "those intervals") : "that interval";
    const which = lower.length > 0 ? `${full.length} of the ${full.length + lower.length} intervals` : `each of the ${full.length} intervals`;
    const where = full.length > 1 ? `${which} from ${hhmm(at100[0].at)}${until(at100[at100.length - 1])} UTC` : `the interval from ${hhmm(peak.at)}${until(peak)} UTC`;
    const reached = full.length
        ? `T5's normalized RU consumption (the busiest partition key range's share of its RU/s; Azure Monitor keeps the highest in ${each}) reached 100 % in at least one second of ${where}: in such a second, at least one partition key range used all of its share of the RU/s.`
        : `T5's normalized RU consumption (the busiest partition key range's share of its RU/s; Azure Monitor keeps the highest in ${each}) peaked at ${Math.round(peak.value ?? 0)} % in ${where}.`;
    let counted = "";
    if (refused !== null && refused > 0) {
        const of = total !== null ? `${plural(total, "request")} in ${those}, ${refused} of them throttled (429${share !== null ? `, ${share} %` : ""})` : `${plural(refused, "throttled request")} (429) in ${those}`;
        const guide =
            share === null
                ? " Their share of all requests isn't known: the request counts aren't in the history for those minutes."
                : share > THROTTLED_SHARE
                  ? ` That's more than the ${THROTTLED_SHARE} % of requests at which Learn recommends more throughput.`
                  : ` Learn counts up to ${THROTTLED_SHARE} % of requests throttled, with acceptable latency, as RU/s fully used, with no action needed.`;
        counted = ` Azure Monitor counted ${of}: a request to a range that had used its share in that second was refused, with the time to wait before retrying it.${guide}`;
    } else if (refused !== null) {
        counted = ` Azure Monitor counted ${total !== null ? `${plural(total, "request")} in ${those}, none of them throttled` : `no throttled request (429) in ${those}`}.`;
    }
    // The 429s of the span's intervals under 100 %, so its count adds up to the minutes' own (F6).
    const inLower = (m: MetricPoint) => lower.some((n) => m.at.getTime() >= n.at.getTime() && m.at.getTime() < Math.max(end(n).getTime(), n.at.getTime() + 1));
    const between = sum(throttled.filter(inLower));
    if (between > 0) {
        const others = lower.length === 1 ? "the other interval" : `the other ${lower.length} intervals`;
        counted += ` In ${others}, where normalized RU consumption stayed under 100 %, Azure Monitor counted ${plural(between, `${refused ? "more " : ""}throttled request`)}.`;
    }
    // A whole reading's interval that finer saves hold part of says what they hold (the review of c4c63abe).
    const wholeOf = (rows: readonly MetricPoint[]) => rows.find((m) => m.whole && m.whole.covered.length > 0)?.whole;
    const reading = wholeOf(at100) ?? wholeOf(requestsIn) ?? wholeOf(throttledIn);
    if (reading) {
        const held = [wholeOf(requestsIn)?.finer, wholeOf(throttledIn)?.finer];
        const what = held[0] !== null && held[0] !== undefined ? `: ${plural(held[0], "request")}${held[1] !== null && held[1] !== undefined ? `, ${held[1] === 0 ? "none" : held[1]} of them throttled` : ""}` : "";
        counted += ` A finer save holds ${reading.covered.map((c) => `${hhmm(c.from)} to ${hhmm(c.to)}`).join(" and ")} UTC of ${those}${what}.`;
    }
    const ru = provisioned === null ? "" : `${Math.round(provisioned)} RU/s`;
    const partitions =
        provisioned === null
            ? ""
            : provisioned <= PARTITION_RU
              ? ` At ${ru}, under the 10,000 RU/s one physical partition serves, the container needs only one physical partition unless it holds more than 50 GB, so all its requests share those ${ru} whatever their partition key: a new key wouldn't raise the limit.`
              : ` At ${ru}, over the 10,000 RU/s one physical partition serves, the container has several physical partitions, each with an equal share of the RU/s, so one hot partition key range can be throttled while the others aren't.`;
    const ruleId = refused !== null && refused > 0 ? "RU-THROTTLED" : "RU-AT-LIMIT";
    const statement = `${reached}${counted}${partitions}`;
    const notCaptured = [
        `T5: which partition key range was busiest, and which operations used the RU/s, aren't in the history: it keeps the container's highest normalized RU consumption and its request counts.${provisioned === null ? " Nor is its provisioned throughput for these minutes, so whether a new partition key could help isn't known: it helps only a container with more than one physical partition." : ""}`,
        ...(refused === null ? [`T5: Azure Monitor's throttled requests aren't in the history for ${hhmmss(from)}-${hhmmss(to)} UTC, so whether any request was refused isn't known.`] : []),
    ];
    const evidence: EvidenceRef[] = [
        { table: "Telemetry Snapshots", at: iso(peak.at), target: "T5", text: `Normalized RU consumption ${Math.round(peak.value ?? 0)} %, the highest ${peak.intervalUnknown ? "in the interval " : ""}from ${hhmm(peak.at)}${until(peak)} UTC` },
        ...throttledIn.filter((m) => (m.value ?? 0) > 0).slice(0, 2).map((m) => ({ table: "Telemetry Snapshots", at: iso(m.at), target: "T5" as const, text: `${plural(m.value ?? 0, "throttled request")} (429) ${m.intervalUnknown ? "in the interval " : ""}from ${hhmm(m.at)}${until(m)} UTC` })),
        ...(provisionedPoint ? [{ table: "Telemetry Snapshots", at: iso(provisionedPoint.at), target: "T5" as const, text: `Provisioned throughput ${ru}` }] : []),
    ];
    // RU-AT-LIMIT: no change. RU-THROTTLED: the clients' retries; more throughput above Learn's 5 %; and a new partition key
    // only where several physical partitions make a hot range possible.
    const ids =
        ruleId === "RU-AT-LIMIT"
            ? []
            : ["RU-RETRY", ...(share !== null && share > THROTTLED_SHARE ? ["RU-AUTOSCALE"] : []), ...(provisioned !== null && provisioned > PARTITION_RU ? ["RU-PARTITION"] : [])];
    return {
        findings: [{ ruleId, target: "T5", severity: ruleId === "RU-THROTTLED" ? "critical" : "warning", title: `T5: normalized RU consumption ${Math.round(peak.value ?? 0)} %`, detail: statement, evidence }],
        rootCause: { statement, confidence: "medium", ruleIds: [ruleId], evidence },
        recommendations: recommend(...ids),
        nextSteps: [
            "In Azure Monitor, split Normalized RU Consumption by PartitionKeyRangeId for the same minutes: one range at 100 % while the others stay low is a hot partition.",
            "Filter Total Requests to status code 429 and split them by operation type for the same minutes.",
        ],
        notCaptured,
        details: { peak: { at: iso(peak.at), percent: peak.value }, intervalsAt100: full.length, requests: total, throttled: refused, throttledPercent: share, provisionedRuPerSecond: provisioned },
    };
}