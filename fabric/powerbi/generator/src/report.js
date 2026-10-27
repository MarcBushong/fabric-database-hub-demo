// Assembles the report: report.json, version.json, pages, visuals, filters, interactions, bookmarks, and theme.
import { createHash } from 'node:crypto';
import { makeLayout } from './layout.js';
import { SCHEMAS, bool, fieldRef, hexGuid, hexName, text } from './pbir.js';
import { buildTheme } from './theme.js';
import { buildFilters, buildVisual, placementRect, railHeight } from './visuals.js';
import { resolveField } from './inputs.js';

export const REPORT_FOLDER = 'RPT_DatabaseHub_History.Report';
export const MODEL_FOLDER = 'SM_DatabaseHub_History.SemanticModel';
export const PBIP_FILE = 'DbHubHistory.pbip';

// The base theme ships with Power BI; the file is vendored from `powerbi-report-author scaffold` (CLI 0.5.0).
export const BASE_THEME = {
  name: 'Fluent2-CY26SU10',
  path: 'BaseThemes/Fluent2-CY26SU10.json',
  reportVersionAtImport: { visual: '2.11.0', report: '3.4.0', page: '2.3.1' },
};

const DATA_KINDS = new Set(['cardVisual', 'lineChart', 'lineClusteredColumnComboChart', 'scatterChart', 'barChart', 'tableEx', 'pivotTable']);
const SLICER_KINDS = new Set(['slicer', 'advancedSlicerVisual', 'listSlicer']);

// The contract's cross_filter_rules, as source/target placement pairs that differ from the default interaction.
// "*data" expands to the page's data visuals, "*data-except:<id>" to all of them but one.
const INTERACTIONS = {
  'Estate at a glance': [['period_slicer', 'tile_history']],
  'The incident, minute by minute': [['*data', '*data']],
  'Signal explorer': [['status_slicer', '*data-except:findings_detail'], ['status_slicer', 'page_title'], ['status_slicer', 'filter_summary']],
  'Readiness checks': [['run_slicer', 'readiness_history']],
};

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function buildReport(brief, model) {
  const files = new Map();
  const notes = [];
  const field = (ref) => resolveField(model, ref);
  const pageNames = new Map(brief.pages.map((page) => [page.name, hexName('page', page.name)]));
  const bookmarkName = (display) => hexName('bookmark', display);
  const visualName = (page, id) => hexName('visual', page.name, id);

  const theme = buildTheme(brief.theme);
  // Desktop caches themes by name, so the file name carries a hash of the content, and the theme's "name"
  // matches the file name, as the authoring CLI's validator requires.
  const themeHash = createHash('sha256').update(json({ ...theme, name: '' })).digest('hex').slice(0, 8);
  const themeFile = `${brief.theme.name.replace(/[^A-Za-z0-9]/g, '')}-${themeHash}.json`;
  const themeText = json({ ...theme, name: themeFile });
  files.set(`${REPORT_FOLDER}/StaticResources/RegisteredResources/${themeFile}`, themeText);
  files.set(`${REPORT_FOLDER}/.platform`, json({
    $schema: SCHEMAS.platform,
    metadata: { type: 'Report', displayName: brief.report },
    config: { version: '2.0', logicalId: hexGuid('logicalId', brief.report) },
  }));

  for (const page of brief.pages) {
    const contract = page.layout_contract;
    const layout = makeLayout(contract);
    const pageName = pageNames.get(page.name);
    const placements = contract.placements.map((placement) => ({ ...placement }));
    const railSlots = placements.filter((placement) => placement.region === 'rail').sort((a, b) => a.slot - b.slot);
    const railHeights = railSlots.map(railHeight);
    railSlots.forEach((placement) => { placement.railHeights = railHeights; });

    const ctx = {
      brief,
      model,
      page,
      field,
      pageNameOf: (display) => {
        const name = pageNames.get(display);
        if (!name) {
          throw new Error(`Unknown page in a navigation action: ${display}`);
        }
        return name;
      },
      bookmarkNameOf: (display) => {
        if (!asList(brief.interaction_pattern.bookmarks).some((entry) => entry.startsWith(`${display}:`))) {
          throw new Error(`Unknown bookmark: ${display}`);
        }
        return bookmarkName(display);
      },
    };

    placements.forEach((placement, index) => {
      const rect = placementRect(placement, layout);
      const built = buildVisual(placement, ctx);
      const { filters, notes: skipped } = buildFilters(placement, ctx, built.category);
      notes.push(...skipped);
      const container = {
        $schema: SCHEMAS.visual,
        name: visualName(page, placement.id),
        position: { x: rect.x, y: rect.y, z: (index + 1) * 1000, height: rect.height, width: rect.width, tabOrder: index * 1000 },
        visual: built.visual,
      };
      if (filters.length) {
        container.filterConfig = { filters };
      }
      files.set(`${REPORT_FOLDER}/definition/pages/${pageName}/visuals/${container.name}/visual.json`, json(container));
    });

    const pageJson = {
      $schema: SCHEMAS.page,
      name: pageName,
      displayName: page.display_name,
      displayOption: 'FitToPage',
      height: contract.canvas.height,
      width: contract.canvas.width,
    };
    const drillFields = asList(page.drillthrough_fields).map(field);
    if (drillFields.length) {
      const drillFilters = drillFields.map((drill) => ({
        name: hexName('drillthrough', page.name, drill.queryRef),
        field: fieldRef(drill),
        type: 'Categorical',
        howCreated: 'Drillthrough',
      }));
      pageJson.filterConfig = { filters: drillFilters };
      pageJson.pageBinding = {
        name: 'Pod',
        type: 'Drillthrough',
        acceptsFilterContext: page.keep_all_filters ? 'Default' : 'None',
        parameters: drillFilters.map((filter, index) => ({
          name: `Param_${filter.name}`,
          boundFilter: filter.name,
          fieldExpr: fieldRef(drillFields[index]),
        })),
      };
    }
    const personalize = /On for (.+) only/.exec(brief.interaction_pattern.personalize_visuals ?? '');
    pageJson.objects = {
      background: [{ properties: { color: { solid: { color: text(page.page_background) } }, transparency: { expr: { Literal: { Value: '0D' } } } } }],
      outspace: [{ properties: { color: { solid: { color: text(page.page_background) } }, transparency: { expr: { Literal: { Value: '0D' } } } } }],
      personalizeVisual: [{ properties: { show: bool(Boolean(personalize) && personalize[1] === page.name) } }],
    };
    const interactions = buildInteractions(page, placements, visualName);
    if (interactions.length) {
      pageJson.visualInteractions = interactions;
    }
    files.set(`${REPORT_FOLDER}/definition/pages/${pageName}/page.json`, json(pageJson));
  }

  files.set(`${REPORT_FOLDER}/definition/pages/pages.json`, json({
    $schema: SCHEMAS.pages,
    pageOrder: brief.pages.map((page) => pageNames.get(page.name)),
    activePageName: pageNames.get(brief.pages[0].name),
  }));

  const bookmarkItems = [];
  for (const entry of asList(brief.interaction_pattern.bookmarks)) {
    const display = entry.split(':')[0].trim();
    const page = brief.pages.find((candidate) => candidate.layout_contract.placements.some((placement) => placement.action === `Bookmark: ${display}`));
    if (!page) {
      throw new Error(`No button uses the bookmark ${display}`);
    }
    const name = bookmarkName(display);
    const railSlicers = page.layout_contract.placements.filter((placement) => placement.region === 'rail' && SLICER_KINDS.has(placement.kind));
    const containers = {};
    for (const slicer of railSlicers) {
      const slicerField = field(slicer.field_bindings);
      containers[visualName(page, slicer.id)] = {
        filters: {
          byExpr: [{ name: hexName('bookmark-filter', page.name, slicer.id), type: slicer.slicer_type === 'between' ? 'Advanced' : 'Categorical', expression: fieldRef(slicerField), howCreated: 0 }],
        },
        singleVisual: { visualType: slicer.kind, objects: {}, activeProjections: { Values: [fieldRef(slicerField)] } },
      };
    }
    files.set(`${REPORT_FOLDER}/definition/bookmarks/${name}.bookmark.json`, json({
      $schema: SCHEMAS.bookmark,
      displayName: display,
      name,
      options: {
        applyOnlyToTargetVisuals: true,
        targetVisualNames: railSlicers.map((slicer) => visualName(page, slicer.id)),
        suppressActiveSection: true,
        suppressDisplay: true,
      },
      explorationState: {
        version: '1.3',
        activeSection: pageNames.get(page.name),
        sections: { [pageNames.get(page.name)]: { visualContainers: containers } },
      },
    }));
    bookmarkItems.push({ name });
  }
  if (bookmarkItems.length) {
    files.set(`${REPORT_FOLDER}/definition/bookmarks/bookmarks.json`, json({ $schema: SCHEMAS.bookmarks, items: bookmarkItems }));
  }

  files.set(`${REPORT_FOLDER}/definition/report.json`, json({
    $schema: SCHEMAS.report,
    themeCollection: {
      baseTheme: { name: BASE_THEME.name, reportVersionAtImport: BASE_THEME.reportVersionAtImport, type: 'SharedResources' },
      customTheme: { name: themeFile, reportVersionAtImport: BASE_THEME.reportVersionAtImport, type: 'RegisteredResources' },
    },
    resourcePackages: [
      { name: 'SharedResources', type: 'SharedResources', items: [{ name: BASE_THEME.name, path: BASE_THEME.path, type: 'BaseTheme' }] },
      { name: 'RegisteredResources', type: 'RegisteredResources', items: [{ name: themeFile, path: themeFile, type: 'CustomTheme' }] },
    ],
    settings: {
      useStylableVisualContainerHeader: true,
      hideVisualContainerHeader: true,
      exportDataMode: 'AllowSummarized',
      defaultDrillFilterOtherVisuals: true,
      allowChangeFilterTypes: true,
      useEnhancedTooltips: true,
      useDefaultAggregateDisplayName: true,
    },
  }));
  files.set(`${REPORT_FOLDER}/definition/version.json`, json({ $schema: SCHEMAS.version, version: '2.0.0' }));
  files.set(`${REPORT_FOLDER}/definition.pbir`, json({
    $schema: SCHEMAS.definitionProperties,
    version: '4.0',
    datasetReference: { byPath: { path: `../${MODEL_FOLDER}` } },
  }));
  files.set(PBIP_FILE, json({
    $schema: SCHEMAS.pbip,
    version: '1.0',
    artifacts: [{ report: { path: REPORT_FOLDER } }],
    settings: { enableAutoRecovery: true },
  }));

  return { files, notes, themeFile };
}

function asList(value) {
  return value === undefined || value === null ? [] : Array.isArray(value) ? value : [value];
}

function buildInteractions(page, placements, visualName) {
  const rules = INTERACTIONS[page.name] ?? [];
  const ids = new Set(placements.map((placement) => placement.id));
  const data = placements.filter((placement) => DATA_KINDS.has(placement.kind)).map((placement) => placement.id);
  const expand = (token) => {
    if (token === '*data') {
      return data;
    }
    if (token.startsWith('*data-except:')) {
      return data.filter((id) => id !== token.split(':')[1]);
    }
    if (!ids.has(token)) {
      throw new Error(`Unknown placement in an interaction rule on ${page.name}: ${token}`);
    }
    return [token];
  };
  const seen = new Set();
  const interactions = [];
  for (const [source, target] of rules) {
    for (const from of expand(source)) {
      for (const to of expand(target)) {
        const key = `${from}>${to}`;
        if (from !== to && !seen.has(key)) {
          seen.add(key);
          interactions.push({ source: visualName(page, from), target: visualName(page, to), type: 'NoFilter' });
        }
      }
    }
  }
  return interactions;
}
