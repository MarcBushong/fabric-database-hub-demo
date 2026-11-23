// The contract's files (rca/ at the repository's root) for the app's tests. Test-only: it reads the fixtures whole,
// answer key included, so grading tests can compare a blind RCA with what was injected.

import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { decodeEvidence, mergeEvidence } from "../evidence";
import { decodeSidecar, mergeSidecars, parseExact, type SidecarEvidence } from "../sidecar";
import type { Evidence } from "../types";

export const CONTRACT_DIR = resolve(import.meta.dirname, "../../../../../rca");

export function readContract<T = unknown>(relative: string): T {
    return JSON.parse(readFileSync(resolve(CONTRACT_DIR, relative), "utf8")) as T;
}

/** A contract file's text: its README's rules, which a test can hold the app's words to. */
export function readContractText(relative: string): string {
    return readFileSync(resolve(CONTRACT_DIR, relative), "utf8");
}

/** A contract file read with its 64-bit integers' exact digits (sidecar.ts's parseExact). */
export function readContractExact<T = unknown>(relative: string): T {
    return parseExact(readFileSync(resolve(CONTRACT_DIR, relative), "utf8")) as T;
}

export const FIXTURES = {
    t1: "fixtures/t1-blocking-chain.evidence.json",
    t4: "fixtures/t4-replica-lag.evidence.json",
} as const;

/** The sidecar fixtures (rca/fixtures/README.md, What a blind RCA finds in the sidecars). */
export const SIDECAR_FIXTURES = {
    t3: "fixtures/t3-plan-regression.sidecar.json",
    t4: "fixtures/t4-query-store.sidecar.json",
    surge: "fixtures/t4-connection-surge.sidecar.json",
} as const;

export function fixtureEvidence(...names: Array<keyof typeof FIXTURES>): Evidence {
    return mergeEvidence(names.map((name) => decodeEvidence(readContract(FIXTURES[name])).evidence));
}

export function fixtureSidecar(...names: Array<keyof typeof SIDECAR_FIXTURES>): SidecarEvidence {
    return mergeSidecars(names.map((name) => decodeSidecar(readContractExact(SIDECAR_FIXTURES[name])).sidecar));
}

export interface AnswerKeyRow {
    kind: string;
    target: string;
    at: Date;
    end: Date | null;
    scenario: string;
    runToken: string;
    eventName: string | null;
}

/** The answer key of a fixture: what the workload ran, for grading only. */
export function answerKeyOf(name: keyof typeof FIXTURES): AnswerKeyRow[] {
    const doc = readContract<{ epochUtc: string; answerKey: { strings: string[]; tables: { rca_answer_key?: { rows: number; columns: Record<string, Array<number | null>> } } } }>(FIXTURES[name]);
    const epoch = Date.parse(doc.epochUtc);
    const key = doc.answerKey;
    const table = key.tables.rca_answer_key;
    if (!table) return [];
    const s = (col: string, i: number) => {
        const v = table.columns[col]?.[i];
        return typeof v === "number" ? key.strings[v] : null;
    };
    const t = (col: string, i: number) => {
        const v = table.columns[col]?.[i];
        return typeof v === "number" ? new Date(epoch + v) : null;
    };
    return Array.from({ length: table.rows }, (_, i) => ({
        kind: s("kind", i) ?? "",
        target: s("target", i) ?? "",
        at: t("event_time_utc", i) as Date,
        end: t("end_time_utc", i),
        scenario: s("scenario", i) ?? "",
        runToken: s("run_token", i) ?? "",
        eventName: s("event_name", i),
    }));
}

/** Every scenario ID (the folders of scenarios/), which no blind output may name. */
export function scenarioIds(): string[] {
    return readdirSync(resolve(CONTRACT_DIR, "../scenarios"), { withFileTypes: true })
        .filter((d) => d.isDirectory())
        .map((d) => d.name);
}

/** The words a blind output must never contain: every scenario ID, as a whole token. */
export function namesAScenario(text: string): string[] {
    return scenarioIds().filter((id) => new RegExp(`(?<![A-Za-z0-9_./-])${id.replace(/[-]/g, "\\-")}(?![A-Za-z0-9_./-])`).test(text));
}
