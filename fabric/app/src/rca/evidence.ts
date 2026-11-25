// Reads an evidence document (rca/evidence.schema.json, version 1) into evidence rows: its detection tables only, by
// their lakehouse columns. The app reads the history through DAX (loader.ts); this is for the tests, which read the
// contract's fixtures, and the local preview's sample.

import { ROW_MAPPERS, type Get } from "./rows";
import { RCA_SPEC, type RcaTableKey, type TableSpec } from "./spec";
import { emptyEvidence, type Evidence } from "./types";

export const EVIDENCE_KIND = "ContosoCare.RcaEvidence";
export const EVIDENCE_VERSION = 1;

/** One table of a document: its row count and its columns, each an array of values (rca/README.md, The evidence document). */
export interface ColumnarTable {
    rows: number;
    columns: Record<string, unknown[]>;
}

export interface EvidenceDocument {
    kind: string;
    version: number;
    documentId: string;
    sessionId: string | null;
    windowStartUtc: string;
    windowEndUtc: string;
    targets: string[];
    epochUtc: string;
    strings: string[];
    tables: Record<string, ColumnarTable>;
}

export class EvidenceFormatError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "EvidenceFormatError";
    }
}

function isDocument(value: unknown): value is EvidenceDocument {
    const doc = value as Partial<EvidenceDocument> | null;
    return Boolean(doc && typeof doc === "object" && typeof doc.epochUtc === "string" && Array.isArray(doc.strings) && doc.tables && typeof doc.tables === "object");
}

/**
 * One table of a document (an evidence document's or a sidecar's) as typed rows: a column's strings come from the
 * dictionary, its times from the epoch, and an ID keeps its digits (spec.ts's id). A missing table has no rows.
 */
export function readColumnarTable<T>(doc: { strings: string[]; tables: Record<string, ColumnarTable> }, spec: TableSpec, map: (get: Get) => T | null, epoch: number): T[] {
    const table = doc.tables[spec.lake];
    if (!table) return [];
    const fields = spec.fields;
    const out: T[] = [];
    for (let i = 0; i < table.rows; i++) {
        const get = (field: string) => {
            const def = fields[field];
            const raw = def ? table.columns[def.lake]?.[i] : undefined;
            if (raw === null || raw === undefined) return undefined;
            if (def.kind === "string") return typeof raw === "number" ? doc.strings[raw] : undefined;
            if (def.kind === "timestamp") return typeof raw === "number" ? new Date(epoch + raw) : undefined;
            if (def.kind === "id") return typeof raw === "string" ? raw : typeof raw === "number" && Number.isSafeInteger(raw) ? String(raw) : undefined;
            return raw;
        };
        const row = map(get);
        if (row) out.push(row);
    }
    return out;
}

/** One table's rows as typed evidence rows. */
function readTable(doc: EvidenceDocument, key: RcaTableKey, epoch: number): unknown[] {
    return readColumnarTable(doc, RCA_SPEC[key], ROW_MAPPERS[key] as (get: Get) => unknown, epoch);
}

/** The evidence in a document, or an EvidenceFormatError when it isn't one this version reads. */
export function decodeEvidence(value: unknown): { documentId: string; from: Date; to: Date; evidence: Evidence } {
    if (!isDocument(value)) throw new EvidenceFormatError("This isn't an RCA evidence document.");
    if (value.kind !== EVIDENCE_KIND || value.version !== EVIDENCE_VERSION) throw new EvidenceFormatError(`Evidence version ${String(value.version)} isn't one this app reads (${EVIDENCE_VERSION}).`);
    const epoch = Date.parse(value.epochUtc);
    if (!Number.isFinite(epoch)) throw new EvidenceFormatError("The document's epoch isn't a time.");
    const evidence = emptyEvidence();
    evidence.sessions = readTable(value, "sessions", epoch) as Evidence["sessions"];
    evidence.events = readTable(value, "events", epoch) as Evidence["events"];
    evidence.resource = readTable(value, "resource", epoch) as Evidence["resource"];
    evidence.replica = readTable(value, "replica", epoch) as Evidence["replica"];
    evidence.coverage = readTable(value, "coverage", epoch) as Evidence["coverage"];
    evidence.waits = readTable(value, "waits", epoch) as Evidence["waits"];
    return { documentId: value.documentId, from: new Date(value.windowStartUtc), to: new Date(value.windowEndUtc), evidence };
}

/** Several documents' evidence, merged in time order (a session's exports, or both hosts'). */
export function mergeEvidence(parts: readonly Evidence[]): Evidence {
    const merged = emptyEvidence();
    for (const part of parts) {
        merged.sessions.push(...part.sessions);
        merged.events.push(...part.events);
        merged.resource.push(...part.resource);
        merged.replica.push(...part.replica);
        merged.coverage.push(...part.coverage);
        merged.waits.push(...part.waits);
        merged.metrics.push(...part.metrics);
    }
    const byTime = <T>(at: (row: T) => Date) => (a: T, b: T) => at(a).getTime() - at(b).getTime();
    merged.sessions.sort(byTime((r) => r.capturedAt));
    merged.events.sort(byTime((r) => r.at));
    merged.resource.sort(byTime((r) => r.at));
    merged.replica.sort(byTime((r) => r.at));
    merged.coverage.sort(byTime((r) => r.from));
    merged.waits.sort(byTime((r) => r.from));
    merged.metrics.sort(byTime((r) => r.at));
    return merged;
}
