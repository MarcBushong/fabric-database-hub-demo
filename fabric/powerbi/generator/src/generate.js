#!/usr/bin/env node
// Generates fabric/powerbi/RPT_DatabaseHub_History.Report and DbHubHistory.pbip from the Design Brief.
//   node src/generate.js                 write the report next to the spec (the committed form, byPath)
//   node src/generate.js --check         exit 1 when the committed files differ from a fresh generation
//   node src/generate.js --out <dir> --connection "<connection string>"
//                                        write a copy for Power BI Desktop with the byConnection form; keep
//                                        <dir> outside Git (out/), because the connection string has real IDs
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readDesignBrief, readModel } from './inputs.js';
import { BASE_THEME, MODEL_FOLDER, REPORT_FOLDER, buildReport } from './report.js';
import { SCHEMAS } from './pbir.js';

const POWERBI_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const SPEC_PATH = join(POWERBI_DIR, '_brief', 'report-spec.md');
export const MODEL_DEFINITION = join(POWERBI_DIR, MODEL_FOLDER, 'definition');
const MANAGED_DIRS = [`${REPORT_FOLDER}/definition`, `${REPORT_FOLDER}/StaticResources/RegisteredResources`];
const BASE_THEME_FILE = `${REPORT_FOLDER}/StaticResources/SharedResources/${BASE_THEME.path}`;

export function generate() {
  return buildReport(readDesignBrief(SPEC_PATH), readModel(MODEL_DEFINITION));
}

function listFiles(root, dir) {
  const absolute = join(root, dir);
  if (!existsSync(absolute)) {
    return [];
  }
  return readdirSync(absolute, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => relative(root, join(entry.parentPath ?? entry.path, entry.name)).split(sep).join('/'));
}

// Lists every difference between the generated files and the files under root.
export function compare(files, root) {
  const problems = [];
  for (const [path, content] of files) {
    const absolute = join(root, path);
    if (!existsSync(absolute)) {
      problems.push(`missing: ${path}`);
    } else if (readFileSync(absolute, 'utf8') !== content) {
      problems.push(`differs: ${path}`);
    }
  }
  for (const dir of MANAGED_DIRS) {
    for (const path of listFiles(root, dir)) {
      if (!files.has(path)) {
        problems.push(`not generated: ${path}`);
      }
    }
  }
  if (!existsSync(join(root, BASE_THEME_FILE))) {
    problems.push(`missing vendored base theme: ${BASE_THEME_FILE}`);
  }
  return problems;
}

function write(files, root) {
  for (const dir of MANAGED_DIRS) {
    for (const path of listFiles(root, dir)) {
      if (!files.has(path)) {
        rmSync(join(root, path));
      }
    }
  }
  for (const [path, content] of files) {
    const absolute = join(root, path);
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, content, 'utf8');
  }
}

function main(argv) {
  const args = { check: false, out: null, connection: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--check') {
      args.check = true;
    } else if (arg === '--out') {
      args.out = argv[++index];
    } else if (arg === '--connection') {
      args.connection = argv[++index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (args.connection && !args.out) {
    throw new Error('--connection needs --out: the connection string has real IDs and never goes into Git.');
  }

  const { files, notes } = generate();
  for (const note of notes) {
    console.log(`note: ${note}`);
  }
  if (args.check) {
    const problems = compare(files, POWERBI_DIR);
    if (problems.length) {
      console.error(`The committed report differs from the generator's output (run: npm run generate):\n  ${problems.join('\n  ')}`);
      return 1;
    }
    console.log(`OK: ${files.size} generated files match.`);
    return 0;
  }

  const root = args.out ? resolve(args.out) : POWERBI_DIR;
  if (args.connection) {
    files.set(`${REPORT_FOLDER}/definition.pbir`, `${JSON.stringify({
      $schema: SCHEMAS.definitionProperties,
      version: '4.0',
      datasetReference: { byConnection: { connectionString: args.connection } },
    }, null, 2)}\n`);
  }
  write(files, root);
  if (args.out) {
    const source = join(POWERBI_DIR, BASE_THEME_FILE);
    if (existsSync(source)) {
      cpSync(source, join(root, BASE_THEME_FILE));
    }
  }
  console.log(`Wrote ${files.size} files under ${root}`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
