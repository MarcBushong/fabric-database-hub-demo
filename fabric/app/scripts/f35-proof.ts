// F35 design (i)'s live proof, from an export of telemetry_snapshots after kept_value_step resolved it (fabric/history/kept_value.py).
// Usage: tsx scripts/f35-proof.ts <export.jsonl> [--from <instant>] [--to <instant>] [--model <response.json>]
// The export holds one JSON object a line with the table's columns: target, analysis, metric, bucket_utc,
// captured_at_utc, window_start_utc, window_end_utc (ISO 8601 UTC), value, grain_minutes, kept_value, and resolved_at_utc.
// It prints one JSON object, and fails (exit 1) on any check that doesn't hold:
// - bins: the written kept values, read per bin as the model's kept form reads them (keptFormValues), against the rule's
//   reference on the raw rows (snapshotValues), in every bin whose rows are all worked out;
// - hours: each series' total or peak in each whole hour, from those bins and from finestPerInterval's kept points on the
//   raw rows, one per save, series, and bin, as the shared cases compare them (kept-value-cases.test.ts); the release's
//   newest-per-bin totals beside them show what the double count was;
// - steps: each save's step in both rules, its declared grain or, for a save written before F35, each rule's reading;
// - model, with --model and both --from and --to: the deployed model's Snapshot Value per bin, from
//   fabric/powerbi/kept-value/model-bins.dax with the same instants, against keptFormValues on the export's rows, in every
//   bin with a bin time from --from to --to, worked out or not. The export and the model must read the same version of
//   the table: nothing written to it between the export and the model's refresh. The file is Execute Queries' response
//   as saved, a JSON array of its rows, or JSON lines.
import { readFileSync } from "node:fs";
import { declaredGrain, finestPerInterval, HOURLY_METRICS, OFF_GRID_ANALYSES, addsUp } from "../src/data/finest-per-interval";
import { keptFormValues, monitorGrain, snapshotValues, sqlGrain } from "../src/data/snapshot-value";
import { toDate } from "../src/lib/format";

type Row = Record<string, unknown>;
const HOUR = 3_600_000;
const MINUTE = 60_000;
const MONITOR_ANALYSES = new Set(["postgresql", "cosmosdb"]);

function argument(name: string): string | null {
    const at = process.argv.indexOf(name, 3);
    return at > 0 && at + 1 < process.argv.length ? process.argv[at + 1] : null;
}

function option(name: string): number | null {
    const value = toDate(argument(name));
    return value ? value.getTime() : null;
}

const USAGE = "Usage: tsx scripts/f35-proof.ts <export.jsonl> [--from <instant>] [--to <instant>] [--model <response.json>]";
const path = process.argv[2];
if (!path) {
    console.error(USAGE);
    process.exit(2);
}
const from = option("--from") ?? -Infinity;
const to = option("--to") ?? Infinity;
const modelPath = argument("--model");
if (modelPath !== null && (from === -Infinity || to === Infinity)) {
    console.error(`${USAGE}\n--model needs --from and --to, the instants model-bins.dax's BinsFrom and BinsTo bound its bins with.`);
    process.exit(2);
}
const rows: Row[] = readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as Record<string, unknown>)
    .map((r) => ({
        TargetKey: r.target,
        AnalysisKey: r.analysis,
        Metric: r.metric,
        Bucket: r.bucket_utc ?? null,
        CapturedAt: r.captured_at_utc ?? null,
        WindowStart: r.window_start_utc ?? null,
        WindowEnd: r.window_end_utc ?? null,
        Value: r.value ?? null,
        GrainMinutes: r.grain_minutes ?? null,
        KeptValue: r.kept_value ?? null,
        ResolvedAt: r.resolved_at_utc ?? null,
    }));
const time = (value: unknown) => toDate(value)?.getTime() ?? null;
const close = (a: number, b: number) => Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));

// Bins: the kept form's read of the written values against the rule's reference, where every row is worked out.
const resolvedBins = new Set<string>();
const unresolved = new Set<string>();
for (const r of rows) {
    const at = time(r.Bucket);
    if (at === null || OFF_GRID_ANALYSES.has(String(r.AnalysisKey))) continue;
    const key = `${String(r.TargetKey)}|${String(r.AnalysisKey)}|${String(r.Metric)}|${at}`;
    if (time(r.ResolvedAt) === null) unresolved.add(key);
    else resolvedBins.add(key);
}
const model = keptFormValues(rows);
const reference = snapshotValues(rows);
const binDiffers: string[] = [];
let binsCompared = 0;
for (const key of resolvedBins) {
    if (unresolved.has(key)) continue;
    const at = Number(key.split("|")[3]);
    if (at < from || at >= to) continue;
    binsCompared += 1;
    const a = model.get(key);
    const b = reference.get(key);
    if ((a === undefined) !== (b === undefined) || (a !== undefined && b !== undefined && !close(a, b))) binDiffers.push(`${key}: kept ${a} and rule ${b}`);
}

// Hours: per series, from the kept form's bins and from finestPerInterval's points on the raw rows.
const fold = (map: Map<string, number>, key: string, adds: boolean, value: number) => {
    const before = map.get(key);
    map.set(key, before === undefined ? value : adds ? before + value : Math.max(before, value));
};
const hourOf = (at: number) => new Date(Math.floor(at / HOUR) * HOUR).toISOString();
const hoursKept = new Map<string, number>();
for (const [key, value] of model) {
    const [target, analysis, metric, binText] = key.split("|");
    if (binText === "" || OFF_GRID_ANALYSES.has(analysis)) continue;
    const at = Number(binText);
    if (at < from || at >= to) continue;
    fold(hoursKept, `${target}|${analysis}|${metric}|${hourOf(at)}`, addsUp({ AnalysisKey: analysis, Metric: metric }), value);
}
const grouped = new Map<string, Row>();
const newest = new Map<string, { captured: number; value: number }>();
for (const r of rows) {
    const at = time(r.Bucket);
    if (at === null || OFF_GRID_ANALYSES.has(String(r.AnalysisKey))) continue;
    const key = `${String(r.TargetKey)}|${String(r.AnalysisKey)}|${String(r.Metric)}|${at}|${time(r.CapturedAt)}`;
    const before = grouped.get(key);
    grouped.set(key, before ? { ...before, Value: Number(before.Value) + Number(r.Value) } : { ...r, Value: Number(r.Value) });
    const bin = `${String(r.TargetKey)}|${String(r.AnalysisKey)}|${String(r.Metric)}|${at}`;
    const captured = time(r.CapturedAt) ?? -Infinity;
    const current = newest.get(bin);
    if (!current || captured > current.captured) newest.set(bin, { captured, value: Number(r.Value) });
    else if (captured === current.captured) current.value += Number(r.Value);
}
const hoursFinest = new Map<string, number>();
for (const r of finestPerInterval([...grouped.values()]).kept) {
    const at = time(r.Bucket) ?? 0;
    if (at < from || at >= to) continue;
    fold(hoursFinest, `${String(r.TargetKey)}|${String(r.AnalysisKey)}|${String(r.Metric)}|${hourOf(at)}`, addsUp(r), Number(r.Value));
}
const hoursRelease = new Map<string, number>();
for (const [bin, { value }] of newest) {
    const [target, analysis, metric, binText] = bin.split("|");
    const at = Number(binText);
    if (at < from || at >= to) continue;
    fold(hoursRelease, `${target}|${analysis}|${metric}|${hourOf(at)}`, addsUp({ AnalysisKey: analysis, Metric: metric }), value);
}
const hourDiffers: string[] = [];
const unresolvedHours = new Set([...unresolved].map((key) => key.split("|").slice(0, 3).join("|") + "|" + hourOf(Number(key.split("|")[3]))));
let hoursCompared = 0;
for (const key of new Set([...hoursKept.keys(), ...hoursFinest.keys()])) {
    if (unresolvedHours.has(key)) continue;
    hoursCompared += 1;
    const a = hoursKept.get(key);
    const b = hoursFinest.get(key);
    if (a === undefined || b === undefined || !close(a, b)) hourDiffers.push(`${key}: kept ${a} and finestPerInterval ${b} (release ${hoursRelease.get(key)})`);
}

// Steps: per save (capture and family), each rule's step.
const familyOf = (target: string) => (target === "T5" ? "cosmos" : target === "T4" || target === "T4-replica" ? "postgres" : "sql");
const finestStep = new Map<string, number>();
const binsOf = new Map<string, Set<number>>();
for (const r of rows) {
    const at = time(r.Bucket);
    if (at === null || HOURLY_METRICS.has(String(r.Metric)) || OFF_GRID_ANALYSES.has(String(r.AnalysisKey))) continue;
    const key = `${String(r.CapturedAt)}|${familyOf(String(r.TargetKey))}|${String(r.TargetKey)}|${String(r.AnalysisKey)}|${String(r.Metric)}`;
    const set = binsOf.get(key) ?? new Set<number>();
    set.add(at);
    binsOf.set(key, set);
}
for (const [key, set] of binsOf) {
    const save = key.split("|").slice(0, 2).join("|");
    const sorted = [...set].sort((a, b) => a - b);
    for (let i = 1; i < sorted.length; i++) {
        const gap = sorted[i] - sorted[i - 1];
        if (!finestStep.has(save) || gap < (finestStep.get(save) ?? Infinity)) finestStep.set(save, gap);
    }
}
const monitorBins = new Map<string, number[]>();
for (const r of rows) {
    const at = time(r.Bucket);
    if (at === null || !MONITOR_ANALYSES.has(String(r.AnalysisKey)) || HOURLY_METRICS.has(String(r.Metric))) continue;
    const key = `${String(r.TargetKey)}|${String(r.AnalysisKey)}|${time(r.CapturedAt)}`;
    monitorBins.set(key, [...(monitorBins.get(key) ?? []), at]);
}
const stepDiffers: string[] = [];
const saves = new Map<string, { declared: number | null; rule: number; finest: number | null }>();
for (const r of rows) {
    const analysis = String(r.AnalysisKey);
    const start = time(r.WindowStart);
    const end = time(r.WindowEnd);
    if (time(r.Bucket) === null || OFF_GRID_ANALYSES.has(analysis) || HOURLY_METRICS.has(String(r.Metric)) || start === null || end === null) continue;
    const save = `${String(r.CapturedAt)}|${familyOf(String(r.TargetKey))}`;
    const key = `${save}|${String(r.TargetKey)}|${analysis}`;
    if (saves.has(key)) continue;
    const declared = declaredGrain(r);
    const rule = declared ?? (MONITOR_ANALYSES.has(analysis) ? monitorGrain(start, end, monitorBins.get(`${String(r.TargetKey)}|${analysis}|${time(r.CapturedAt)}`) ?? []) : sqlGrain(start, end));
    const finest = declared ?? (finestStep.has(save) ? (finestStep.get(save) ?? 0) / MINUTE : null);
    saves.set(key, { declared, rule, finest });
    if (finest !== null && finest !== rule) stepDiffers.push(`${key}: the rule's ${rule} and finestPerInterval's ${finest} minutes${declared === null ? " (written before F35)" : ""}`);
}
// Model: the deployed model's Snapshot Value per bin (model-bins.dax) against keptFormValues, the DAX measure's reference.
// Execute Queries names a row's values "Telemetry Snapshots[Target Key]" and "[snapshot_value]"; plain names work too.
const objectOf = (value: unknown): Record<string, unknown> => (value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {});
const listOf = (value: unknown): unknown[] => (Array.isArray(value) ? (value as unknown[]) : []);
function deployedRows(file: string): Row[] {
    const content = readFileSync(file, "utf8").replace(/^\uFEFF/, "");
    let parsed: unknown;
    try {
        parsed = JSON.parse(content) as unknown;
    } catch {
        parsed = content
            .split(/\r?\n/)
            .filter((line) => line.trim() !== "")
            .map((line) => JSON.parse(line) as unknown);
    }
    const results = objectOf(parsed).results;
    const list = Array.isArray(results)
        ? listOf(results).flatMap((result) => listOf(objectOf(result).tables).flatMap((table) => listOf(objectOf(table).rows)))
        : Array.isArray(parsed)
          ? listOf(parsed)
          : [parsed];
    return list.map((row) =>
        Object.fromEntries(Object.entries(objectOf(row)).map(([name, value]) => [name.replace(/^[^[]*\[/, "").replace(/\]$/, "").toLowerCase().replace(/[\s_]/g, ""), value])),
    );
}
let deployed: { file: string; rows: number; from: string; to: string; compared: number; differ: number; missing: number; extra: number; first: string[] } | null = null;
if (modelPath !== null) {
    const textOf = (value: unknown) => (value === null || value === undefined ? "" : String(value));
    const numberOrNull = (value: unknown) => (value === null || value === undefined || value === "" ? null : Number(value));
    const expected = new Map<string, number>();
    for (const [key, value] of model) {
        const binText = key.slice(key.lastIndexOf("|") + 1);
        if (binText !== "" && Number(binText) >= from && Number(binText) < to) expected.set(key, value);
    }
    const found = deployedRows(modelPath);
    const seen = new Set<string>();
    const differs: string[] = [];
    const extras: string[] = [];
    for (const row of found) {
        const at = time(row.bucketutc ?? row.bucket);
        if (at === null || at < from || at >= to) continue;
        const series = `${textOf(row.target ?? row.targetkey)}|${textOf(row.analysis ?? row.analysiskey)}|${textOf(row.metric)}`;
        const value = numberOrNull(row.snapshotvalue ?? row.value);
        // A bin time finer than a millisecond (off the grid, a capture's time) can round either way in the model.
        const key = [at, at - 1, at + 1].map((t) => `${series}|${t}`).find((k) => expected.has(k) && !seen.has(k));
        if (key === undefined) {
            extras.push(`${series}|${at}: the model's ${value}, where keptFormValues has none`);
            continue;
        }
        seen.add(key);
        const want = expected.get(key) ?? Number.NaN;
        if (value === null || !close(value, want)) differs.push(`${key}: the model's ${value} and keptFormValues' ${want}`);
    }
    const missing = [...expected.keys()].filter((key) => !seen.has(key)).map((key) => `${key}: keptFormValues' ${expected.get(key)}, where the model has none`);
    deployed = {
        file: modelPath,
        rows: found.length,
        from: new Date(from).toISOString(),
        to: new Date(to).toISOString(),
        compared: seen.size,
        differ: differs.length,
        missing: missing.length,
        extra: extras.length,
        first: [...differs, ...missing, ...extras].slice(0, 20),
    };
}

const result = {
    rows: rows.length,
    bins: { compared: binsCompared, unresolved: unresolved.size, differ: binDiffers.length, first: binDiffers.slice(0, 20) },
    hours: { compared: hoursCompared, differ: hourDiffers.length, first: hourDiffers.slice(0, 20) },
    steps: { saves: saves.size, declared: [...saves.values()].filter((s) => s.declared !== null).length, differ: stepDiffers.length, first: stepDiffers.slice(0, 20) },
    totals: Object.fromEntries(
        [...new Set([...hoursKept.keys()].map((key) => key.split("|").slice(0, 2).join("|")))].sort().map((series) => {
            const sum = (map: Map<string, number>) => [...map].filter(([key]) => key.startsWith(`${series}|`)).reduce((a, [key, v]) => (addsUp({ AnalysisKey: key.split("|")[1], Metric: key.split("|")[2] }) ? a + v : a), 0);
            return [series, { kept: sum(hoursKept), finest: sum(hoursFinest), release: sum(hoursRelease) }];
        }),
    ),
    ...(deployed ? { model: deployed } : {}),
};
console.log(JSON.stringify(result, null, 2));
const deployedProblems = deployed ? deployed.differ + deployed.missing + deployed.extra : 0;
process.exit(binDiffers.length + hourDiffers.length + deployedProblems > 0 ? 1 : 0);
