// The business impact lens (ADR 0030): which ContosoCare service each target serves, and what a measured signal meant
// for it, in business words next to the measurement it comes from. Every number here is measured; nothing is estimated,
// and nothing claims a user-facing latency the history doesn't measure.
//
// The services come from the demo's own story: the baseline is "a front desk, billing, and scheduling workload"
// (docs/demo-walkthrough.md), T3's Database Agent beat regresses "the visit lookup" (scenarios/activity-profiles.json),
// T4's read replica serves reports and is the copy to recover to, and T5 holds `patient-events`, a bedside-monitor
// integration's events (docs/architecture.md). Which of T1 and T2 is billing and which the front desk is this file's
// choice: change it here, in one place.

import { formatDuration, formatLevel, formatNumber, type NumberKind } from "./format";
import { timesText } from "./insights";
import type { EstateTarget } from "./view-state";

export interface BusinessService {
    target: EstateTarget;
    /** The service's name, as a person at ContosoCare says it. */
    service: string;
    /** What it does, in a few words. */
    what: string;
}

export const SERVICES: Record<EstateTarget, BusinessService> = {
    T1: { target: "T1", service: "Billing", what: "Claims and payments" },
    T2: { target: "T2", service: "Front desk", what: "Clinic check-in, on-premises" },
    T3: { target: "T3", service: "Scheduling", what: "Appointments and the visit lookup" },
    T4: { target: "T4", service: "Reporting", what: "Care reports" },
    "T4-replica": { target: "T4-replica", service: "Reports' DR copy", what: "The read replica reports run on" },
    T5: { target: "T5", service: "Patient events", what: "Bedside-monitor events" },
};

export function serviceOf(target: string): BusinessService | null {
    return (SERVICES as Record<string, BusinessService | undefined>)[target] ?? null;
}

/** What a measured signal was, for the lens: its family, how long it was visible, and its numbers. */
export interface ImpactInput {
    target: EstateTarget;
    /** cpu, blocking, io, log_rate, tran_log, latch, memory, parallelism, network, throttle (T5), replica_lag (T4's replica), connections (T4). */
    family: string;
    /** Minutes from the signal showing to its recovery, or null when the telemetry doesn't say. */
    durationMin: number | null;
    /** True when the signal was still there at the end of the telemetry, so the duration is a minimum. */
    ongoing?: boolean;
    /** The signal's peak, in its own unit. */
    peak: number | null;
    /** The signal's baseline, for "N times its baseline". */
    baseline?: number | null;
    /** T5: requests answered 429, and all requests, in the episode. */
    throttled?: number | null;
    requests?: number | null;
}

export interface Impact {
    service: string;
    /** The business words: "Patient events: 52 % of requests throttled for 10 min". */
    headline: string;
    /** The measured signal behind them: "normalized RU 100 %, 429s on 520 of 1,000 requests". */
    evidence: string;
    /** Both: the headline, then the evidence in parentheses. */
    sentence: string;
}

interface Wording {
    /** What happened to the service, in business words. */
    what: string;
    /** The measurement's name and unit. */
    signal: string;
    kind: NumberKind;
}

const WORDING: Record<string, Wording> = {
    cpu: { what: "under heavy load", signal: "CPU", kind: "percent" },
    blocking: { what: "work blocked behind other work", signal: "blocked processes", kind: "int" },
    io: { what: "waiting on storage", signal: "Buffer IO waits", kind: "seconds" },
    log_rate: { what: "writes held back by its service tier", signal: "Log Rate Governor waits", kind: "seconds" },
    tran_log: { what: "commits waiting on the transaction log", signal: "Tran Log IO waits", kind: "seconds" },
    latch: { what: "contention in tempdb", signal: "Buffer Latch waits", kind: "seconds" },
    memory: { what: "queries waiting for memory", signal: "Memory waits", kind: "seconds" },
    parallelism: { what: "queries spread over parallel scans", signal: "Parallelism waits", kind: "seconds" },
    network: { what: "results held by a slow client", signal: "Network IO waits", kind: "seconds" },
    replica_lag: { what: "behind its primary", signal: "read replica lag", kind: "seconds" },
    connections: { what: "connections refused", signal: "failed connections", kind: "int" },
};

const percent = (share: number) => `${Math.round(share * 100)} %`;

function forDuration(input: Pick<ImpactInput, "durationMin" | "ongoing">): string {
    if (input.durationMin === null || !Number.isFinite(input.durationMin) || input.durationMin < 0) return "";
    return ` for ${input.ongoing ? "at least " : ""}${formatDuration(Math.max(1, input.durationMin))}`;
}

/** What a measured signal meant for the target's ContosoCare service, next to the measurement. */
export function impactOf(input: ImpactInput): Impact {
    const service = serviceOf(input.target)?.service ?? input.target;
    const span = forDuration(input);
    let headline: string;
    let evidence: string;
    if (input.family === "throttle") {
        const { throttled, requests } = input;
        const share = throttled !== null && throttled !== undefined && requests ? throttled / requests : null;
        headline = share !== null ? `${service}: ${percent(share)} of requests throttled${span}` : `${service}: requests throttled${span}`;
        const peak = input.peak !== null ? `normalized RU ${formatNumber(input.peak, "percent")}, ` : "";
        evidence = share !== null ? `${peak}429s on ${formatNumber(throttled, "int")} of ${formatNumber(requests, "int")} requests` : `${peak}429s`;
    } else if (input.family === "replica_lag") {
        const minutes = input.peak !== null ? input.peak / 60 : null;
        headline = minutes !== null ? `${service}: ${minutes >= 1 ? `${minutes.toFixed(1)} min` : formatNumber(input.peak, "seconds")} behind its primary${span}` : `${service}: behind its primary${span}`;
        evidence = input.peak !== null ? `read replica lag peak ${formatNumber(input.peak, "seconds")}` : "read replica lag";
    } else if (input.family === "connections") {
        headline = input.peak !== null ? `${service}: ${formatNumber(input.peak, "int")} connection attempts refused${span}` : `${service}: connection attempts refused${span}`;
        evidence = "failed connections";
    } else {
        const wording = WORDING[input.family] ?? { what: "a signal above its baseline", signal: input.family.replace(/_/g, " "), kind: "decimal" as NumberKind };
        headline = `${service}: ${wording.what}${span}`;
        const ratio = input.peak !== null && input.baseline ? input.peak / input.baseline : null;
        // A bin's blocked processes are its highest sample; a fraction is written as it is, never rounded to a whole count.
        const peak =
            input.peak === null
                ? wording.signal
                : input.family === "blocking"
                  ? `up to ${formatLevel(input.peak, "int")} ${input.peak === 1 ? "blocked process" : wording.signal}`
                  : `${wording.signal} peak ${formatNumber(input.peak, wording.kind)}${wording.kind === "seconds" ? " per bin" : ""}`;
        evidence = ratio !== null && Number.isFinite(ratio) && ratio >= 1.05 ? `${peak}, ${timesText(ratio)} its baseline` : peak;
    }
    return { service, headline, evidence, sentence: `${headline} (${evidence})` };
}
