// Checks that every production dependency (the code that can ship in the app) has a permissive license.
// Reads package-lock.json, so it needs no network and no extra package. Exit code 1 lists the offenders.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ALLOWED = new Set(["MIT", "ISC", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "0BSD", "OFL-1.1", "BlueOak-1.0.0", "Unlicense", "CC0-1.0"]);

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(readFileSync(join(root, "package-lock.json"), "utf8"));

/** True when an SPDX expression is satisfied by the allow list: every AND term allowed, or any OR branch. */
function isAllowed(expression) {
    if (typeof expression !== "string" || !expression.trim()) return false;
    const text = expression.trim().replace(/^\((.*)\)$/, "$1");
    if (/\bOR\b/.test(text)) return text.split(/\s+OR\s+/).some((part) => isAllowed(part));
    if (/\bAND\b/.test(text)) return text.split(/\s+AND\s+/).every((part) => isAllowed(part));
    return ALLOWED.has(text.replace(/[()]/g, "").trim());
}

const offenders = [];
let checked = 0;
for (const [path, meta] of Object.entries(lock.packages ?? {})) {
    if (path === "" || meta.dev || meta.devOptional || meta.link) continue;
    checked += 1;
    let license = meta.license;
    if (!license) {
        try {
            license = JSON.parse(readFileSync(join(root, path, "package.json"), "utf8")).license;
        } catch {
            license = undefined;
        }
    }
    if (!isAllowed(license)) offenders.push(`${path.replace(/^node_modules\//, "")}@${meta.version}: ${license ?? "no license field"}`);
}

if (offenders.length > 0) {
    console.error(`License check failed: ${offenders.length} of ${checked} production packages aren't on the allow list (${[...ALLOWED].join(", ")}):`);
    for (const line of offenders) console.error(`  ${line}`);
    process.exit(1);
}
console.log(`License check passed: ${checked} production packages, all on the allow list.`);
