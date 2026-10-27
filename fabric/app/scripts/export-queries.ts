// Writes every DAX query in the catalog as a connector payload ({ query, resultSetRowCountLimit }), so
// configure-fabric-app.ps1 can run each one with `rayfin connector invoke history executeQuery --file`.
// Usage: tsx scripts/export-queries.ts <output folder inside the Rayfin project> [newest telemetry day, yyyy-mm-dd]
//   [--t3-incident-start <instant>] [--t3-incident-end <instant>] [--t3-latest-bucket <instant>]
// The instants (yyyy-mm-ddThh:mm:ssZ, from history-meta) anchor the check's T3 replay; see checkIncidentRange.
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { catalogForCheck, checkIncidentRange, type CheckAnchors } from "../src/data/queries";

const INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$/;

function option(name: string): Date | null {
    const at = process.argv.indexOf(name, 4);
    const value = at > 0 ? process.argv[at + 1] : undefined;
    return value && INSTANT.test(value) ? new Date(value) : null;
}

const outDir = resolve(process.argv[2] ?? "rayfin/.temp/queries");
const dayArg = process.argv[3];
const now = new Date();
const latestDay = dayArg && /^\d{4}-\d{2}-\d{2}$/.test(dayArg)
    ? new Date(`${dayArg}T00:00:00Z`)
    : new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
const anchors: CheckAnchors = {
    t3IncidentStart: option("--t3-incident-start"),
    t3IncidentEnd: option("--t3-incident-end"),
    t3LatestBucket: option("--t3-latest-bucket"),
};
const range = checkIncidentRange(latestDay, anchors);

mkdirSync(outDir, { recursive: true });
const index = catalogForCheck(latestDay, anchors).map((spec) => {
    const file = `${spec.id}.json`;
    writeFileSync(join(outDir, file), JSON.stringify({ query: spec.dax, resultSetRowCountLimit: spec.rowLimit }), "utf8");
    return { id: spec.id, title: spec.title, file, rowLimit: spec.rowLimit };
});
const incidentRange = { target: range.target, start: range.start.toISOString(), end: range.end.toISOString() };
writeFileSync(join(outDir, "index.json"), `${JSON.stringify({ latestDay: latestDay.toISOString().slice(0, 10), incidentRange, queries: index }, null, 2)}\n`, "utf8");
console.log(`Wrote ${index.length} queries to ${outDir}`);
