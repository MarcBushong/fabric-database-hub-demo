import { describe, expect, it } from "vitest";
import { RCA_SPEC, SIDECAR_SPEC, type FieldKind, type TableSpec } from "./spec";
import { readContract } from "./testdata/contract";

interface ContractColumn {
    name: string;
    type: string;
    required?: boolean;
    model?: { column?: string };
}

interface ContractTable {
    name: string;
    model: string;
    role: string;
    document: string;
    columns: ContractColumn[];
}

const contract = readContract<{ tables: ContractTable[] }>("history-tables.json");
const kindOf = (type: string): FieldKind => (type === "timestamp" ? "timestamp" : type === "boolean" ? "boolean" : ["long", "integer", "double"].includes(type) ? "number" : "string");

describe("the app's names for the RCA tables (rca/history-tables.json)", () => {
    const specs: Array<[string, TableSpec, "evidence" | "sidecar"]> = [
        ...Object.entries(RCA_SPEC).map(([key, spec]) => [key, spec, "evidence"] as [string, TableSpec, "evidence"]),
        ...Object.entries(SIDECAR_SPEC).map(([key, spec]) => [key, spec, "sidecar"] as [string, TableSpec, "sidecar"]),
    ];
    for (const [key, spec, document] of specs) {
        it(`reads ${spec.model} by the contract's lakehouse and model names, every column, with its type, from the ${document} document`, () => {
            const table = contract.tables.find((t) => t.name === spec.lake);
            expect(table, `${key}: no ${spec.lake} in the contract`).toBeDefined();
            expect(table!.model).toBe(spec.model);
            expect(table!.role).toBe("detection");
            expect(table!.document).toBe(document);
            const fields = Object.values(spec.fields);
            for (const field of fields) {
                const column = table!.columns.find((c) => c.name === field.lake);
                expect(column, `${spec.lake}.${field.lake}`).toBeDefined();
                expect(column!.model?.column).toBe(field.model);
                // A 64-bit ID is a long read as its exact digits (spec.ts): only a long may be one.
                if (field.kind === "id") expect(column!.type, `${spec.lake}.${field.lake}`).toBe("long");
                else expect(field.kind, `${spec.lake}.${field.lake}`).toBe(kindOf(column!.type));
            }
            // Every column the contract defines is one the app knows, so nothing the capture sends goes unread.
            expect(table!.columns.map((c) => c.name).sort()).toEqual(fields.map((f) => f.lake).sort());
            expect(Object.keys(spec.fields)).toContain(spec.time);
            for (const name of [spec.end, ...(spec.spans ?? []).flat()].filter((n): n is string => !!n)) expect(Object.keys(spec.fields), `${key}.${name}`).toContain(name);
        });
    }

    it("reads every one of the sidecar's tables, and every Query Store ID as its exact digits", () => {
        const sidecar = contract.tables.filter((t) => t.document === "sidecar").map((t) => t.name);
        expect(Object.values(SIDECAR_SPEC).map((s) => s.lake).sort()).toEqual(sidecar.sort());
        for (const spec of Object.values(SIDECAR_SPEC)) {
            for (const field of Object.values(spec.fields) as Array<{ lake: string; kind: FieldKind }>) {
                if (field.lake === "query_id" || field.lake === "plan_id") expect(field.kind, `${spec.lake}.${field.lake}`).toBe("id");
            }
        }
    });

    it("never names the answer key's table", () => {
        const answerKey = contract.tables.filter((t) => t.role !== "detection").map((t) => [t.name, t.model]).flat();
        const names = [...Object.values(RCA_SPEC), ...Object.values(SIDECAR_SPEC)].flatMap((s) => [s.lake, s.model]);
        for (const name of answerKey) expect(names).not.toContain(name);
    });
});
