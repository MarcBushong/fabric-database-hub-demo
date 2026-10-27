// Reads the Design Brief YAML block from the report spec and the semantic model's TMDL field catalog.
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { parse } from 'yaml';

export function readDesignBrief(specPath) {
  const text = readFileSync(specPath, 'utf8');
  const block = [...text.matchAll(/```yaml\r?\n([\s\S]*?)```/g)]
    .map((match) => match[1])
    .find((body) => /^Design Brief:/m.test(body));
  if (!block) {
    throw new Error(`No "Design Brief:" YAML block in ${specPath}`);
  }
  const brief = parse(block)['Design Brief'];
  if (!brief || brief.contract_version !== 1 || !Array.isArray(brief.pages)) {
    throw new Error('The Design Brief must have contract_version 1 and a pages list.');
  }
  return brief;
}

function unquote(name) {
  const trimmed = name.trim();
  return trimmed.startsWith("'") && trimmed.endsWith("'") ? trimmed.slice(1, -1).replace(/''/g, "'") : trimmed;
}

const NAME = "('(?:[^']|'')+'|[^\\s='][^\\s=]*)";
const TABLE_RE = new RegExp(`^table\\s+${NAME}\\s*$`);
const COLUMN_RE = new RegExp(`^ {4}column\\s+${NAME}(?:\\s*=.*)?$`);
const MEASURE_RE = new RegExp(`^ {4}measure\\s+${NAME}\\s*=`);
const PROPERTY_RE = /^ {8}([A-Za-z]+)(?::\s*(.*))?$/;

// Parses the TMDL tables folder into Map<table, { columns: Map, measures: Map }>.
export function readModel(definitionDir) {
  const tables = new Map();
  const tablesDir = join(definitionDir, 'tables');
  for (const file of readdirSync(tablesDir).filter((name) => name.endsWith('.tmdl')).sort()) {
    let table = null;
    let member = null;
    for (const line of readFileSync(join(tablesDir, file), 'utf8').split(/\r?\n/)) {
      let match = TABLE_RE.exec(line);
      if (match) {
        table = { name: unquote(match[1]), columns: new Map(), measures: new Map() };
        tables.set(table.name, table);
        member = null;
        continue;
      }
      if (!table) {
        continue;
      }
      match = COLUMN_RE.exec(line);
      if (match) {
        member = { name: unquote(match[1]), kind: 'column', dataType: 'string', isHidden: false };
        table.columns.set(member.name, member);
        continue;
      }
      match = MEASURE_RE.exec(line);
      if (match) {
        member = { name: unquote(match[1]), kind: 'measure', dataType: null, isHidden: false };
        table.measures.set(member.name, member);
        continue;
      }
      if (/^ {4}\S/.test(line)) {
        member = null;
        continue;
      }
      match = PROPERTY_RE.exec(line);
      if (match && member) {
        if (match[1] === 'dataType' && member.kind === 'column') {
          member.dataType = match[2].trim();
        } else if (match[1] === 'isHidden') {
          member.isHidden = true;
        }
      }
    }
  }
  if (tables.size === 0) {
    throw new Error(`No TMDL tables in ${tablesDir}`);
  }
  return tables;
}

const FIELD_RE = /^'((?:[^']|'')+)'\[([^\]]+)\]$/;

// Resolves "'Table'[Name]" against the model. Throws for a binding the model doesn't have.
export function resolveField(model, text) {
  const match = FIELD_RE.exec(String(text).trim());
  if (!match) {
    throw new Error(`Not a field reference: ${text}`);
  }
  const tableName = match[1].replace(/''/g, "'");
  const table = model.get(tableName);
  if (!table) {
    throw new Error(`Unknown table in ${text}`);
  }
  const member = table.measures.get(match[2]) ?? table.columns.get(match[2]);
  if (!member) {
    throw new Error(`Unknown column or measure in ${text}`);
  }
  return {
    table: tableName,
    name: member.name,
    kind: member.kind,
    dataType: member.dataType,
    text: `'${tableName.replace(/'/g, "''")}'[${member.name}]`,
    queryRef: `${tableName}.${member.name}`,
  };
}
