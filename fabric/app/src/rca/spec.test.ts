import { describe, expect, it } from "vitest";
import { RCA_SPEC, type FieldKind } from "./spec";
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
    columns: ContractColumn[];
}

const contract = readContract<{ tables: ContractTable[] }>("history-tables.json");
const kindOf = (type: string): FieldKind => (type === "timestamp" ? "timestamp" : type === "boolean" ? "boolean" : ["long", "integer", "double"].includes(type) ? "number" : "string");

describe("the app's names for the RCA tables (rca/history-tables.json)", () => {
    for (const [key, spec] of Object.entries(RCA_SPEC)) {
        it(`reads ${spec.model} by the contract's lakehouse and model names, every column, with its type`, () => {
            const table = contract.tables.find((t) => t.name === spec.lake);
            expect(table, `${key}: no ${spec.lake} in the contract`).toBeDefined();
            expect(table!.model).toBe(spec.model);
            expect(table!.role).toBe("detection");
            const fields = Object.values(spec.fields) as Array<{ lake: string; model: string; kind: FieldKind }>;
            for (const field of fields) {
                const column = table!.columns.find((c) => c.name === field.lake);
                expect(column, `${spec.lake}.${field.lake}`).toBeDefined();
                expect(column!.model?.column).toBe(field.model);
                expect(field.kind, `${spec.lake}.${field.lake}`).toBe(kindOf(column!.type));
            }
            // Every column the contract defines is one the app knows, so nothing the capture sends goes unread.
            expect(table!.columns.map((c) => c.name).sort()).toEqual(fields.map((f) => f.lake).sort());
            expect(Object.keys(spec.fields)).toContain(spec.time);
        });
    }

    it("never names the answer key's table", () => {
        const answerKey = contract.tables.filter((t) => t.role !== "detection").map((t) => [t.name, t.model]).flat();
        const names = Object.values(RCA_SPEC).flatMap((s) => [s.lake, s.model]);
        for (const name of answerKey) expect(names).not.toContain(name);
    });
});
