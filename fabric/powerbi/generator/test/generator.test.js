import { strict as assert } from 'node:assert';
import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { MODEL_DEFINITION, SPEC_PATH, compare, generate } from '../src/generate.js';
import { readDesignBrief, readModel, resolveField } from '../src/inputs.js';
import { makeLayout } from '../src/layout.js';
import { REPORT_FOLDER } from '../src/report.js';

const here = dirname(fileURLToPath(import.meta.url));
const powerbiDir = resolve(here, '..', '..');
const brief = readDesignBrief(SPEC_PATH);
const model = readModel(MODEL_DEFINITION);
const { files, notes } = generate();
const visuals = [...files.entries()]
  .filter(([path]) => path.endsWith('/visual.json'))
  .map(([path, content]) => ({ path, page: path.split('/')[3], json: JSON.parse(content) }));

function walk(node, visit) {
  if (Array.isArray(node)) {
    node.forEach((item) => walk(item, visit));
  } else if (node && typeof node === 'object') {
    visit(node);
    Object.values(node).forEach((value) => walk(value, visit));
  }
}

test('the generator is deterministic', () => {
  const again = generate().files;
  assert.deepEqual([...again.keys()], [...files.keys()]);
  for (const [path, content] of files) {
    assert.equal(again.get(path), content, path);
  }
});

test('the committed report matches a fresh generation', () => {
  assert.deepEqual(compare(files, powerbiDir), []);
});

test('every generated file is valid JSON with LF line endings and a final newline', () => {
  for (const [path, content] of files) {
    assert.doesNotThrow(() => JSON.parse(content), path);
    assert.ok(!content.includes('\r'), path);
    assert.ok(content.endsWith('}\n'), path);
  }
});

test('the report has the contract\'s four pages with 10, 8, 11, and 10 placements, in order', () => {
  const pages = JSON.parse(files.get(`${REPORT_FOLDER}/definition/pages/pages.json`));
  assert.equal(pages.pageOrder.length, 4);
  const counts = pages.pageOrder.map((name) => visuals.filter((visual) => visual.page === name).length);
  assert.deepEqual(counts, [10, 8, 11, 10]);
  const displayNames = pages.pageOrder.map((name) => JSON.parse(files.get(`${REPORT_FOLDER}/definition/pages/${name}/page.json`)).displayName);
  assert.deepEqual(displayNames, brief.pages.map((page) => page.display_name));
  assert.equal(pages.activePageName, pages.pageOrder[0]);
});

test('every visual sits on the 8 px grid inside the margins, and no two visuals on a page overlap', () => {
  for (const { path, json } of visuals) {
    const { x, y, width, height } = json.position;
    assert.match(json.name, /^[0-9a-f]{20}$/, path);
    for (const value of [x, y, width, height]) {
      assert.equal(value % 8, 0, `${path} ${value}`);
    }
    assert.ok(x >= 32 && y >= 32 && x + width <= 1888 && y + height <= 1048, path);
  }
  const byPage = Map.groupBy(visuals, (visual) => visual.page);
  for (const [page, list] of byPage) {
    for (let i = 0; i < list.length; i += 1) {
      for (let j = i + 1; j < list.length; j += 1) {
        const a = list[i].json.position;
        const b = list[j].json.position;
        const apart = a.x + a.width + 16 <= b.x || b.x + b.width + 16 <= a.x || a.y + a.height + 16 <= b.y || b.y + b.height + 16 <= a.y;
        assert.ok(apart, `${page}: ${list[i].json.name} and ${list[j].json.name} overlap or touch`);
      }
    }
  }
});

test('region math follows the contract: 32 px margins, 24 px gutters, snapped to 8', () => {
  const layout = makeLayout(brief.pages[0].layout_contract);
  assert.deepEqual(layout.region('header'), { x: 32, y: 32, width: 1384, height: 64 });
  assert.deepEqual(layout.region('filters'), { x: 1440, y: 32, width: 448, height: 64 });
  assert.deepEqual(layout.region('kpis'), { x: 32, y: 120, width: 1856, height: 152 });
  assert.deepEqual(layout.split(layout.region('kpis'), 5, 2, 'x'), { x: 408, y: 120, width: 352, height: 152 });
});

test('every field a visual, filter, or bookmark references exists in the semantic model', () => {
  const referenced = new Set();
  for (const [path, content] of files) {
    if (!path.includes('/definition/')) {
      continue;
    }
    walk(JSON.parse(content), (node) => {
      for (const kind of ['Column', 'Measure']) {
        const ref = node[kind];
        if (ref && ref.Expression && ref.Expression.SourceRef && ref.Expression.SourceRef.Entity) {
          referenced.add(`'${ref.Expression.SourceRef.Entity}'[${ref.Property}]`);
        }
      }
    });
  }
  assert.ok(referenced.size > 60);
  for (const ref of referenced) {
    assert.doesNotThrow(() => resolveField(model, ref), ref);
  }
});

test('the custom theme is registered under its file name and the base theme is vendored', () => {
  const report = JSON.parse(files.get(`${REPORT_FOLDER}/definition/report.json`));
  const custom = report.themeCollection.customTheme;
  assert.equal(custom.type, 'RegisteredResources');
  assert.match(custom.name, /^DbHubCockpitDark-[0-9a-f]{8}\.json$/);
  const registered = report.resourcePackages.find((item) => item.type === 'RegisteredResources').items[0];
  assert.equal(registered.name, custom.name);
  assert.equal(registered.path, custom.name);
  const theme = JSON.parse(files.get(`${REPORT_FOLDER}/StaticResources/RegisteredResources/${custom.name}`));
  assert.equal(theme.name, custom.name);
  assert.equal(theme.background, '#0E0E10');
  assert.deepEqual(theme.dataColors, brief.theme.data_colors);
  const base = readFileSync(join(powerbiDir, REPORT_FOLDER, 'StaticResources', 'SharedResources', 'BaseThemes', `${report.themeCollection.baseTheme.name}.json`), 'utf8');
  assert.doesNotThrow(() => JSON.parse(base));
});

test('the committed definition.pbir binds the local model by path and has no IDs', () => {
  const pbir = JSON.parse(files.get(`${REPORT_FOLDER}/definition.pbir`));
  assert.deepEqual(pbir.datasetReference, { byPath: { path: '../SM_DatabaseHub_History.SemanticModel' } });
});

test('the incident page is the drillthrough target on Target, without the source filters', () => {
  const pageFiles = [...files.entries()].filter(([path]) => path.endsWith('/page.json')).map(([, content]) => JSON.parse(content));
  const drill = pageFiles.filter((page) => page.pageBinding);
  assert.equal(drill.length, 1);
  assert.equal(drill[0].displayName, brief.pages[1].display_name);
  assert.equal(drill[0].pageBinding.acceptsFilterContext, 'None');
  assert.equal(drill[0].filterConfig.filters[0].howCreated, 'Drillthrough');
  assert.deepEqual(drill[0].filterConfig.filters[0].field, { Column: { Expression: { SourceRef: { Entity: 'Target' } }, Property: 'Target' } });
});

test('the period slicers share the history_period sync group, and the reset button targets the bookmark', () => {
  const synced = visuals.filter(({ json }) => json.visual.syncGroup);
  assert.equal(synced.length, 2);
  assert.ok(synced.every(({ json }) => json.visual.syncGroup.groupName === 'history_period'));
  const bookmarks = JSON.parse(files.get(`${REPORT_FOLDER}/definition/bookmarks/bookmarks.json`));
  assert.equal(bookmarks.items.length, 1);
  const bookmark = JSON.parse(files.get(`${REPORT_FOLDER}/definition/bookmarks/${bookmarks.items[0].name}.bookmark.json`));
  assert.equal(bookmark.displayName, 'Explorer reset');
  assert.equal(bookmark.options.targetVisualNames.length, 4);
  const reset = visuals.find(({ json }) => json.visual.visualContainerObjects?.visualLink?.[0].properties.bookmark);
  assert.equal(reset.json.visual.visualContainerObjects.visualLink[0].properties.bookmark.expr.Literal.Value, `'${bookmarks.items[0].name}'`);
});

test('the only skipped contract filter is the evidence table\'s Top 4', () => {
  assert.equal(notes.length, 1);
  assert.match(notes[0], /incident_evidence/);
});

// Findings of the Desktop render check (2026-10-22): each of these rendered wrong before its fix.
test('buttons and the list slicer carry a static entry next to the id selector, so Desktop applies their formatting', () => {
  const buttons = visuals.filter(({ json }) => json.visual.visualType === 'actionButton');
  assert.equal(buttons.length, 3);
  for (const { path, json } of buttons) {
    for (const name of ['icon', 'text', 'outline']) {
      const entries = json.visual.objects[name];
      assert.ok(entries.some((entry) => !entry.selector), `${path} ${name}: static entry`);
      assert.ok(entries.some((entry) => entry.selector?.id === 'default'), `${path} ${name}: default entry`);
    }
    assert.ok(json.visual.objects.fill.some((entry) => !entry.selector), `${path} fill: static entry`);
  }
  const lists = visuals.filter(({ json }) => json.visual.visualType === 'listSlicer');
  assert.equal(lists.length, 1);
  assert.deepEqual(lists[0].json.visual.objects.value.map((entry) => entry.selector?.id ?? null), [null, 'default']);
});

test('the incident band takes its color and transparency from the combo chart\'s static data point entry', () => {
  const combo = visuals.find(({ json }) => json.visual.visualType === 'lineClusteredColumnComboChart');
  const [first, ...rest] = combo.json.visual.objects.dataPoint;
  assert.equal(first.selector, undefined);
  assert.equal(first.properties.defaultColor.solid.color.expr.Literal.Value, '\'#5772D9\'');
  assert.equal(first.properties.fillTransparency.expr.Literal.Value, '70D');
  assert.ok(rest.every((entry) => entry.selector.metadata !== 'Incident Windows.Focus Window Band'));
});

test('callout labels on the narrow multi-value tiles stay within nine characters', () => {
  for (const { path, json } of visuals.filter(({ json }) => json.visual.visualType === 'cardVisual')) {
    const labels = (json.visual.objects.label ?? []).filter((entry) => entry.selector?.metadata).map((entry) => entry.properties.text.expr.Literal.Value.slice(1, -1));
    if (json.visual.query.queryState.Data.projections.length > 1 && json.position.width <= 352) {
      assert.ok(labels.every((label) => label.length <= 9), `${path}: ${labels.join(', ')}`);
    }
  }
});

test('--connection without --out is refused, so a real connection string never lands in Git', () => {
  const result = spawnSync(process.execPath, [join(here, '..', 'src', 'generate.js'), '--connection', 'semanticmodelid=x'], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /--connection needs --out/);
  const after = readdirSync(join(powerbiDir, REPORT_FOLDER));
  assert.ok(after.includes('definition.pbir'));
  assert.deepEqual(JSON.parse(readFileSync(join(powerbiDir, REPORT_FOLDER, 'definition.pbir'), 'utf8')).datasetReference.byPath, { path: '../SM_DatabaseHub_History.SemanticModel' });
});
