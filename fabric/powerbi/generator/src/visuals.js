// One builder per placement kind. Roles, objects, properties, selectors, and enum values come from
// `powerbi-report-author catalog describe` and `formatting describe-object` (CLI 0.5.0).
import { TOKENS as T } from './theme.js';
import {
  bool, columnColor, equalsFilter, fieldRef, hexGuid, hexName, int, measureColor, measureValue, num,
  projection, solid, text, topNFilter, wildcardSelector,
} from './pbir.js';

const FIELD_TEXT_RE = /'(?:[^']|'')+'\[[^\]]+\]/g;
const asArray = (value) => (value === undefined || value === null ? [] : Array.isArray(value) ? value : [value]);
const refsIn = (value) => [...String(value ?? '').matchAll(FIELD_TEXT_RE)].map((match) => match[0]);

// Short callout labels for multi-value cards, where the measure name would not fit a third of a tile. Labels on the
// 352-pixel tiles stay within nine characters: the Desktop render check (2026-10-22) showed longer ones cut short.
const CALLOUT_LABELS = {
  'CPU (%)': 'Avg CPU',
  'Blocked Processes (peak)': 'Blocked',
  'Findings Needing Attention': 'Findings',
  'Checks Needing Attention (selected run)': 'Attention',
  'Checks (selected run)': 'Checks',
  'Readiness (%)': 'Readiness',
  'Hours Since Latest Capture': 'Hours ago',
  'Notebook Runs Captured': 'Runs',
  'Scenario Requests': 'Requests',
  'Focus Verdict': 'Expected signal',
  'Focus Peak Delta Label': 'Peak vs baseline',
  'Focus Duration (min)': 'Minutes',
};

// Button and list-slicer objects need a static entry next to the one with an id selector (the dual-entry rule in
// the authoring skill's formatting reference); with only the selector entry, Desktop drops the properties silently.
const dualEntry = (properties) => [{ properties }, { properties, selector: { id: 'default' } }];

// Fixed heights for stacked rail slots; null marks the slot that takes the remaining height.
const RAIL_HEIGHTS = { slicer_between: 112, advancedSlicerVisual: 112, slicer_dropdown: 80, listSlicer: null, actionButton: 48 };

function containerObjects({ title, altText, padding, background, border, link } = {}) {
  const objects = {};
  if (title !== undefined) {
    objects.title = [{ properties: title ? { show: bool(true), text: text(title) } : { show: bool(false) } }];
  }
  if (background) {
    objects.background = [{ properties: background === 'none' ? { show: bool(false) } : { show: bool(true), color: solid(background), transparency: num(0) } }];
  }
  if (border === false) {
    objects.border = [{ properties: { show: bool(false) } }];
  }
  if (padding !== undefined) {
    const sides = typeof padding === 'number' ? { top: padding, bottom: padding, left: padding, right: padding } : padding;
    objects.padding = [{ properties: Object.fromEntries(Object.entries(sides).map(([side, value]) => [side, num(value)])) }];
  }
  if (altText) {
    objects.general = [{ properties: { altText: typeof altText === 'string' ? text(altText) : { expr: fieldRef(altText) } } }];
  }
  if (link) {
    objects.visualLink = [{ properties: link }];
  }
  objects.visualHeader = [{ properties: { show: bool(false) } }];
  return objects;
}

// ---- Filters -------------------------------------------------------------------------------------

// Parses the contract's visual_filters strings. The returned notes list filters the generator skips on purpose.
export function buildFilters(placement, ctx, categoryField) {
  const filters = [];
  const notes = [];
  asArray(placement.visual_filters).forEach((rule, index) => {
    const name = hexName('filter', ctx.page.name, placement.id, String(index));
    let match = /^('(?:[^']|'')+'\[[^\]]+\]) is (.+)$/.exec(rule);
    if (match) {
      filters.push(equalsFilter(name, ctx.field(match[1]), match[2]));
      return;
    }
    match = /^Top (\d+) ('(?:[^']|'')+'\[[^\]]+\]) by ('(?:[^']|'')+'\[[^\]]+\])$/.exec(rule);
    if (match) {
      filters.push(topNFilter(name, ctx.field(match[2]), ctx.field(match[3]), Number(match[1])));
      return;
    }
    match = /^Top (\d+) by ('(?:[^']|'')+'\[[^\]]+\])$/.exec(rule);
    if (match && categoryField) {
      filters.push(topNFilter(name, categoryField, ctx.field(match[2]), Number(match[1])));
      return;
    }
    if (match && !categoryField) {
      // A table has no category to rank, and a Top N subquery doesn't see the visual's measure filters,
      // so "Top N by time" would rank findings outside the focus window. The table keeps its measure filter
      // and sort, and its height shows about N rows.
      notes.push(`${ctx.page.name} / ${placement.id}: skipped "${rule}" (no category to rank; height-bound instead)`);
      return;
    }
    throw new Error(`Unsupported visual filter on ${placement.id}: ${rule}`);
  });
  return { filters, notes };
}

function sortDefinition(policy, ctx) {
  const sort = [];
  for (const segment of String(policy ?? '').split(/,\s*then\s+/)) {
    const [ref] = refsIn(segment);
    if (ref) {
      sort.push({ field: fieldRef(ctx.field(ref)), direction: /descending/i.test(segment) ? 'Descending' : 'Ascending' });
    }
  }
  return sort.length ? { sort, isDefaultSort: false } : undefined;
}

// ---- Reference lines ------------------------------------------------------------------------------

function referenceLines(rules, ctx) {
  const lines = { y: [], x: [] };
  for (const rule of asArray(rules)) {
    const match = /^(x|y) = (.+?), (.+)$/.exec(rule);
    if (!match) {
      throw new Error(`Unsupported reference line: ${rule}`);
    }
    const [, axis, valuePart, stylePart] = match;
    const color = (/#[0-9A-Fa-f]{6}/.exec(stylePart) ?? [/Warning amber/i.test(stylePart) ? T.warning : T.secondary])[0].toUpperCase();
    const style = (/\b(dashed|dotted|solid)\b/.exec(stylePart) ?? [null, 'dashed'])[1];
    const label = (/labeled '([^']+)'/.exec(stylePart) ?? [null, null])[1];
    const values = refsIn(valuePart).length ? refsIn(valuePart).map((ref) => ({ field: ctx.field(ref) })) : [{ number: Number(valuePart) }];
    values.forEach((value, index) => {
      const id = String(lines[axis].length + 1);
      const name = label ?? (axis === 'y' ? 'attention threshold' : (index === 0 ? 'window start' : 'window end'));
      lines[axis].push({
        properties: {
          show: bool(true),
          displayName: text(name),
          value: value.field ? { expr: fieldRef(value.field) } : num(value.number),
          lineColor: solid(color),
          style: text(style),
          width: num(1),
          transparency: num(0),
          position: text('front'),
          dataLabelShow: bool(axis === 'y'),
          ...(axis === 'y' ? { dataLabelText: text('Name'), dataLabelColor: solid(color), dataLabelHorizontalPosition: text('left') } : {}),
        },
        selector: { id },
      });
    });
  }
  return lines;
}

// ---- Builders --------------------------------------------------------------------------------------

function textbox(placement, ctx) {
  const field = ctx.field(placement.text_binding);
  const id = 'headline';
  const run = (style) => ({ value: { propertyIdentifier: { objectName: 'values', propertyName: 'expr' }, selector: { id } }, textStyle: style });
  const paragraphs = [];
  let vco;
  if (placement.id === 'page_title') {
    paragraphs.push({ textRuns: [run({ fontFamily: 'Segoe UI Semibold', fontSize: '24pt', color: T.foreground })], horizontalTextAlignment: 'left' });
    if (placement.subtitle) {
      paragraphs.push({ textRuns: [{ value: placement.subtitle, textStyle: { fontFamily: 'Segoe UI', fontSize: '10pt', color: T.secondary } }], horizontalTextAlignment: 'left' });
    }
    vco = containerObjects({ altText: placement.text, background: 'none', border: false, padding: 0 });
  } else if (placement.region === 'breadcrumb') {
    paragraphs.push({ textRuns: [run({ fontFamily: 'Segoe UI', fontSize: '10pt', color: T.secondary })], horizontalTextAlignment: 'right' });
    vco = containerObjects({ altText: placement.purpose, background: 'none', border: false, padding: { top: 24, bottom: 0, left: 0, right: 0 } });
  } else {
    paragraphs.push({ textRuns: [run({ fontFamily: 'Segoe UI', fontSize: '12pt', color: T.foreground })], horizontalTextAlignment: 'left' });
    vco = containerObjects({ altText: placement.purpose, background: T.surface, padding: 16 });
  }
  return {
    visual: {
      visualType: 'textbox',
      objects: {
        general: [{ properties: { paragraphs } }],
        values: [{ properties: { expr: measureValue(field, id) }, selector: { id } }],
      },
      visualContainerObjects: vco,
      drillFilterOtherVisuals: true,
    },
  };
}

function slicer(placement, ctx) {
  const field = ctx.field(placement.field_bindings);
  const between = placement.slicer_type === 'between';
  const objects = {
    data: [{ properties: { mode: text(between ? 'Between' : 'Dropdown') } }],
    header: [{ properties: { show: bool(true), text: text(placement.header_text), fontColor: solid(T.secondary), fontFamily: text('Segoe UI Semibold'), textSize: num(10) } }],
    items: [{ properties: { fontColor: solid(T.foreground), background: solid(T.raised), textSize: num(10) } }],
  };
  if (between) {
    objects.date = [{ properties: { fontColor: solid(T.foreground), background: solid(T.raised) } }];
  } else {
    objects.selection = [{ properties: { singleSelect: bool(/single select/i.test(placement.selection ?? '')), selectAllCheckboxEnabled: bool(false) } }];
  }
  const visual = {
    visualType: 'slicer',
    query: { queryState: { Values: { projections: [projection(field, { active: true })] } } },
    objects,
    visualContainerObjects: containerObjects({ altText: placement.header_text, padding: 2 }),
    drillFilterOtherVisuals: true,
  };
  if (/sorted descending/i.test(placement.selection ?? '')) {
    visual.query.sortDefinition = { sort: [{ field: fieldRef(field), direction: 'Descending' }], isDefaultSort: false };
  }
  if (placement.sync_group) {
    visual.syncGroup = { groupName: placement.sync_group, fieldChanges: true, filterChanges: true };
  }
  return { visual };
}

function buttonSlicer(placement, ctx) {
  const field = ctx.field(placement.field_bindings);
  const tiles = placement.kind === 'advancedSlicerVisual';
  const objects = {
    selection: [{ properties: { singleSelect: bool(/single select/i.test(placement.selection ?? '')), selectAllCheckboxEnabled: bool(false) } }],
    value: tiles
      ? [{ properties: { fontColor: solid(T.foreground), fontSize: num(10), horizontalAlignment: text('center') } }]
      : dualEntry({ fontColor: solid(T.foreground), fontSize: num(10) }),
  };
  if (tiles) {
    objects.background = [
      { properties: { show: bool(true), color: solid(T.raised), transparency: num(0) }, selector: { id: 'default' } },
      { properties: { color: solid(T.selected) }, selector: { id: 'selected' } },
    ];
  }
  return {
    visual: {
      visualType: placement.kind,
      query: { queryState: { Values: { projections: [projection(field, { active: true })] } } },
      objects,
      visualContainerObjects: containerObjects({ title: placement.header_text, altText: placement.header_text, padding: 4 }),
      drillFilterOtherVisuals: true,
    },
  };
}

function card(placement, ctx) {
  const data = asArray(placement.field_bindings.Data).map((ref) => ctx.field(ref));
  const multi = data.length > 1;
  const rail = ctx.field(placement.accent_bar);
  const objects = {
    value: [{ properties: { fontFamily: text('Segoe UI'), fontSize: num(multi ? 20 : 32), bold: bool(true), fontColor: solid(T.foreground) }, selector: { id: 'default' } }],
    label: [
      { properties: { show: bool(true), fontSize: num(10), fontColor: solid(T.secondary), textWrap: bool(true) }, selector: { id: 'default' } },
      ...data.filter((field) => multi && CALLOUT_LABELS[field.name]).map((field) => ({ properties: { text: text(CALLOUT_LABELS[field.name]) }, selector: { metadata: field.queryRef } })),
    ],
    accentBar: [
      { properties: { show: bool(false) }, selector: { id: 'default' } },
      { properties: { show: bool(true), position: text('Left'), width: num(4), color: measureColor(rail) }, selector: { metadata: data[0].queryRef } },
    ],
    outline: [{ properties: { show: bool(false) }, selector: { id: 'default' } }],
  };
  const reference = placement.field_bindings.ReferenceLabel ? ctx.field(placement.field_bindings.ReferenceLabel) : null;
  if (reference) {
    objects.referenceLabel = [{
      properties: { value: { expr: fieldRef(reference) } },
      selector: { data: [{ dataViewWildcard: { matchingOption: 0 } }], metadata: data[0].queryRef, id: `field-${hexGuid('reference', ctx.page.name, placement.id)}`, order: 0 },
    }];
    objects.referenceLabelTitle = [{ properties: { show: bool(false) }, selector: { id: 'default' } }];
    objects.referenceLabelValue = [{ properties: { valueFontColor: solid(T.secondary), valueFontSize: num(10), textWrap: bool(true) }, selector: { id: 'default' } }];
    objects.referenceLabelDetail = [{ properties: { show: bool(false) }, selector: { id: 'default' } }];
  }
  return {
    visual: {
      visualType: 'cardVisual',
      query: { queryState: { Data: { projections: data.map((field) => projection(field)) } } },
      objects,
      visualContainerObjects: containerObjects({ title: placement.label_text, altText: placement.alt_text, padding: 8 }),
      drillFilterOtherVisuals: true,
    },
  };
}

function seriesColor(ctx, field) {
  const entry = ctx.brief.color_map.find((item) => item.measure === field.text);
  return entry ? entry.color : T.ink;
}

function axes(placement, { scalar = true } = {}) {
  const fixedRange = /from 0 to 100/.exec(placement.axes ?? '');
  return {
    categoryAxis: [{ properties: { show: bool(true), ...(scalar ? { axisType: text('Scalar') } : {}), labelColor: solid(T.secondary), gridlineShow: bool(false), showAxisTitle: bool(false) } }],
    valueAxis: [{
      properties: {
        show: bool(true),
        start: num(0),
        ...(fixedRange ? { end: num(100) } : {}),
        labelColor: solid(T.secondary),
        gridlineShow: bool(true),
        gridlineStyle: text('dotted'),
        gridlineColor: solid(T.gridline),
        showAxisTitle: bool(false),
      },
    }],
  };
}

function lineChart(placement, ctx) {
  const bindings = placement.field_bindings;
  const category = ctx.field(bindings.Category);
  const series = asArray(bindings.Y).map((ref) => ctx.field(ref));
  const panels = bindings.SmallMultiples ? ctx.field(bindings.SmallMultiples) : null;
  const queryState = {
    Category: { projections: [projection(category, { active: true })] },
    Y: { projections: series.map((field) => projection(field)) },
  };
  if (panels) {
    queryState.Rows = { projections: [projection(panels)] };
  }
  const lines = referenceLines(placement.reference_lines, ctx);
  const objects = {
    ...axes(placement),
    lineStyles: [
      { properties: { lineChartType: text('linear'), areaShow: bool(false), showMarker: bool(false) } },
      ...series.map((field) => ({ properties: { strokeWidth: num(/Incident Window/.test(field.name) ? 3 : 2) }, selector: { metadata: field.queryRef } })),
    ],
    dataPoint: series.map((field) => ({ properties: { fill: solid(seriesColor(ctx, field)) }, selector: { metadata: field.queryRef } })),
    labels: [{ properties: { show: bool(false) } }],
    legend: [{ properties: { show: bool(true), position: text('Top'), labelColor: solid(T.secondary) } }],
  };
  if (lines.y.length) {
    objects.y1AxisReferenceLine = lines.y;
  }
  if (panels) {
    objects.smallMultiplesLayout = [{ properties: { layoutType: text('custom'), rowCount: int(1), columnCount: int(3), gridLineShow: bool(false) } }];
    objects.subheader = [{ properties: { fontColor: solid(T.ink), fontSize: num(10) } }];
  }
  return {
    category,
    visual: {
      visualType: 'lineChart',
      query: { queryState, sortDefinition: { sort: [{ field: fieldRef(category), direction: 'Ascending' }], isDefaultSort: true } },
      objects,
      visualContainerObjects: containerObjects({ title: placement.purpose, altText: placement.alt_text }),
      drillFilterOtherVisuals: true,
    },
  };
}

function comboChart(placement, ctx) {
  const bindings = placement.field_bindings;
  const category = ctx.field(bindings.Category);
  const columns = asArray(bindings.ColumnY).map((ref) => ctx.field(ref));
  const lines = asArray(bindings.LineY).map((ref) => ctx.field(ref));
  const [signal, peak] = lines;
  const band = columns[0];
  const refs = referenceLines(placement.reference_lines, ctx);
  const objects = {
    ...axes(placement),
    // The band is the only column series. Desktop ignores a metadata selector on a combo chart's column series (render
    // check, 2026-10-22), so its color and transparency go in the static entry, which applies to every column.
    dataPoint: [
      { properties: { defaultColor: solid(seriesColor(ctx, band)), fillTransparency: num(70) } },
      ...lines.map((field) => ({ properties: { fill: solid(seriesColor(ctx, field)) }, selector: { metadata: field.queryRef } })),
    ],
    lineStyles: [
      { properties: { lineChartType: text('linear'), showMarker: bool(false) } },
      { properties: { strokeWidth: num(3) }, selector: { metadata: signal.queryRef } },
      { properties: { strokeShow: bool(false), showMarker: bool(true), markerShape: text('circle'), markerSize: num(6), markerColor: solid(seriesColor(ctx, peak)) }, selector: { metadata: peak.queryRef } },
    ],
    labels: [
      { properties: { show: bool(true), color: solid(T.foreground) } },
      { properties: { showSeries: bool(false) }, selector: { metadata: band.queryRef } },
      { properties: { showSeries: bool(false) }, selector: { metadata: signal.queryRef } },
      { properties: { showSeries: bool(true), labelPosition: text('Above') }, selector: { metadata: peak.queryRef } },
    ],
    legend: [{ properties: { show: bool(false) } }],
  };
  objects.categoryAxis[0].properties.innerPadding = int(0);
  objects.valueAxis[0].properties.secShow = bool(false);
  if (refs.y.length) {
    objects.y1AxisReferenceLine = refs.y;
  }
  if (refs.x.length) {
    objects.xAxisReferenceLine = refs.x;
  }
  return {
    category,
    visual: {
      visualType: 'lineClusteredColumnComboChart',
      query: {
        queryState: {
          Category: { projections: [projection(category, { active: true })] },
          Y: { projections: columns.map((field) => projection(field)) },
          Y2: { projections: lines.map((field) => projection(field)) },
        },
        sortDefinition: { sort: [{ field: fieldRef(category), direction: 'Ascending' }], isDefaultSort: true },
      },
      objects,
      visualContainerObjects: containerObjects({
        title: placement.purpose,
        altText: placement.alt_text_binding ? ctx.field(placement.alt_text_binding) : placement.alt_text,
      }),
      drillFilterOtherVisuals: true,
    },
  };
}

function scatterChart(placement, ctx) {
  const bindings = placement.field_bindings;
  const x = ctx.field(bindings.X);
  const y = ctx.field(bindings.Y);
  const details = ctx.field(bindings.Details);
  const legend = ctx.field(bindings.Legend);
  const identities = [...String(placement.series_styles).matchAll(/\b(T\d) (circle|square|triangle|diamond) (#[0-9A-Fa-f]{6})/g)];
  const seriesSelector = (value) => ({
    data: [{ scopeId: { Comparison: { ComparisonKind: 0, Left: fieldRef(legend), Right: { Literal: { Value: `'${value}'` } } } } }],
  });
  return {
    visual: {
      visualType: 'scatterChart',
      query: {
        queryState: {
          Category: { projections: [projection(details, { active: true })] },
          Series: { projections: [projection(legend)] },
          X: { projections: [projection(x)] },
          Y: { projections: [projection(y)] },
        },
      },
      objects: {
        dataPoint: identities.map(([, value, , color]) => ({ properties: { fill: solid(color.toUpperCase()) }, selector: seriesSelector(value) })),
        bubbles: identities.map(([, value, shape]) => ({ properties: { markerShape: text(shape) }, selector: seriesSelector(value) })),
        categoryAxis: [{ properties: { show: bool(true), labelColor: solid(T.secondary), gridlineShow: bool(false), showAxisTitle: bool(true), titleText: text(x.name), titleColor: solid(T.secondary) } }],
        valueAxis: [{ properties: { show: bool(true), start: num(0), labelColor: solid(T.secondary), gridlineShow: bool(true), gridlineStyle: text('dotted'), gridlineColor: solid(T.gridline), showAxisTitle: bool(false) } }],
        legend: [{ properties: { show: bool(true), position: text('Top'), labelColor: solid(T.secondary) } }],
      },
      visualContainerObjects: containerObjects({ title: placement.purpose, altText: placement.alt_text }),
      drillFilterOtherVisuals: true,
    },
  };
}

function barChart(placement, ctx) {
  const bindings = placement.field_bindings;
  const category = ctx.field(bindings.Category);
  const value = ctx.field(bindings.Y);
  const [colorRef] = refsIn(placement.conditional_formatting);
  return {
    category,
    visual: {
      visualType: 'barChart',
      query: {
        queryState: {
          Category: { projections: [projection(category, { active: true })] },
          Y: { projections: [projection(value)] },
        },
        sortDefinition: { sort: [{ field: fieldRef(value), direction: 'Descending' }], isDefaultSort: false },
      },
      objects: {
        dataPoint: [{ properties: { fill: colorRef ? measureColor(ctx.field(colorRef)) : solid(seriesColor(ctx, value)) }, selector: { data: [{ dataViewWildcard: { matchingOption: 1 } }] } }],
        labels: [{ properties: { show: bool(true), color: solid(T.foreground), labelPosition: text('OutsideEnd') } }],
        categoryAxis: [{ properties: { show: bool(true), labelColor: solid(T.secondary), showAxisTitle: bool(false), gridlineShow: bool(false) } }],
        valueAxis: [{ properties: { show: bool(false), gridlineShow: bool(false), showAxisTitle: bool(false) } }],
        legend: [{ properties: { show: bool(false) } }],
      },
      visualContainerObjects: containerObjects({ title: placement.purpose, altText: placement.alt_text }),
      drillFilterOtherVisuals: true,
    },
  };
}

const colorSource = (field) => (field.kind === 'measure' ? measureColor(field) : columnColor(field));

// Font-color rules from the contract's conditional_formatting prose, mapped to the visual's projections.
function fontColorRules(placement, ctx, fields) {
  const rule = String(placement.conditional_formatting ?? '').split(';')[0];
  const byName = new Map(fields.map((field) => [field.name, field]));
  let match = /^Font color of (.+?) from ('(?:[^']|'')+'\[[^\]]+\])/.exec(rule);
  if (match) {
    const source = ctx.field(match[2]);
    const targets = match[1].split(/,\s*|\s+and\s+/).map((part) => part.trim()).filter(Boolean)
      .map((part) => (part.startsWith("'") ? ctx.field(part) : byName.get(part)));
    if (targets.some((target) => !target)) {
      throw new Error(`Unresolved font-color target in ${placement.id}: ${rule}`);
    }
    return targets.map((target) => ({ target, source }));
  }
  match = /^Font color from ('(?:[^']|'')+'\[[^\]]+\])$/.exec(rule.trim());
  if (match) {
    const source = ctx.field(match[1]);
    return fields.filter((field) => field.kind === 'measure').map((target) => ({ target, source }));
  }
  match = /^Font color from (.+)$/.exec(rule.trim());
  if (match) {
    const prefixes = [...match[1].matchAll(/([A-Z][A-Za-z ]*?) Font Color/g)].map((item) => item[1].trim());
    const table = ctx.model.get(fields.find((field) => field.kind === 'measure').table);
    return prefixes.map((prefix) => {
      const target = fields.find((field) => field.kind === 'measure' && field.name.startsWith(prefix));
      const sourceName = [...table.measures.keys()].find((name) => name === `${prefix} Font Color`);
      if (!target || !sourceName) {
        throw new Error(`Unresolved font-color rule "${prefix}" in ${placement.id}`);
      }
      return { target, source: ctx.field(`'${table.name.replace(/'/g, "''")}'[${sourceName}]`) };
    });
  }
  if (rule.trim()) {
    throw new Error(`Unsupported conditional formatting in ${placement.id}: ${rule}`);
  }
  return [];
}

function gridObjects(fields, rules, { urlIcon = false } = {}) {
  return {
    columnHeaders: [{
      properties: {
        autoSizeColumnWidth: bool(true),
        columnAdjustment: text('growToFit'),
        backColor: solid(T.raised),
        fontColor: solid(T.foreground),
        outlineColor: solid(T.border),
        bold: bool(true),
        fontSize: num(10),
        wordWrap: bool(true),
      },
    }],
    values: [
      {
        properties: {
          backColorPrimary: solid(T.surface),
          backColorSecondary: solid(T.rowAlternate),
          fontColorPrimary: solid(T.foreground),
          fontColorSecondary: solid(T.foreground),
          outlineColor: solid(T.border),
          fontSize: num(10),
          wordWrap: bool(true),
          ...(urlIcon ? { urlIcon: bool(true) } : {}),
        },
      },
      ...rules.map(({ target, source }) => ({ properties: { fontColor: colorSource(source) }, selector: wildcardSelector(target.queryRef) })),
    ],
    grid: [{
      properties: {
        gridHorizontal: bool(true),
        gridHorizontalColor: solid(T.border),
        gridVertical: bool(false),
        outlineColor: solid(T.border),
      },
    }],
  };
}

function table(placement, ctx) {
  const fields = asArray(placement.field_bindings).map((ref) => ctx.field(ref));
  const rules = fontColorRules(placement, ctx, fields);
  const visual = {
    visualType: 'tableEx',
    query: { queryState: { Values: { projections: fields.map((field) => projection(field)) } } },
    objects: gridObjects(fields, rules, { urlIcon: /link icon/i.test(placement.conditional_formatting ?? '') }),
    visualContainerObjects: containerObjects({ title: placement.purpose, altText: placement.alt_text }),
    drillFilterOtherVisuals: true,
  };
  const sort = sortDefinition(placement.sort_policy, ctx);
  if (sort) {
    visual.query.sortDefinition = sort;
  }
  return { visual };
}

function matrix(placement, ctx) {
  const bindings = placement.field_bindings;
  const rows = asArray(bindings.Rows).map((ref) => ctx.field(ref));
  const columns = asArray(bindings.Columns).map((ref) => ctx.field(ref));
  const values = asArray(bindings.Values).map((ref) => ctx.field(ref));
  const rules = fontColorRules(placement, ctx, values);
  const queryState = { Rows: { projections: rows.map((field) => projection(field)) } };
  if (columns.length) {
    queryState.Columns = { projections: columns.map((field) => projection(field)) };
  }
  queryState.Values = { projections: values.map((field) => projection(field)) };
  const objects = gridObjects(values, rules);
  objects.rowHeaders = [{ properties: { fontColor: solid(T.foreground), backColor: solid(T.surface), outlineColor: solid(T.border), fontSize: num(10) } }];
  objects.subTotals = [{ properties: { rowSubtotals: bool(false), columnSubtotals: bool(false) } }];
  const visual = {
    visualType: 'pivotTable',
    query: { queryState },
    objects,
    visualContainerObjects: containerObjects({ title: placement.purpose, altText: placement.alt_text }),
    drillFilterOtherVisuals: true,
  };
  const rowSort = rows.map((field) => ({ field: fieldRef(field), direction: 'Ascending' }));
  visual.query.sortDefinition = { sort: rowSort, isDefaultSort: true };
  return { visual };
}

function actionButton(placement, ctx) {
  let link;
  const navigation = /^Page navigation to (.+)$/.exec(placement.action ?? '');
  const bookmark = /^Bookmark: (.+)$/.exec(placement.action ?? '');
  if (navigation) {
    link = { show: bool(true), type: text('PageNavigation'), navigationSection: text(ctx.pageNameOf(navigation[1])) };
  } else if (bookmark) {
    link = { show: bool(true), type: text('Bookmark'), bookmark: text(ctx.bookmarkNameOf(bookmark[1])) };
  } else {
    throw new Error(`Unsupported button action on ${placement.id}: ${placement.action}`);
  }
  return {
    visual: {
      visualType: 'actionButton',
      objects: {
        icon: dualEntry({ shapeType: text('blank') }),
        text: dualEntry({ show: bool(true), text: text(placement.text), fontColor: solid(T.foreground), fontSize: num(10), horizontalAlignment: text('center') }),
        fill: [
          ...dualEntry({ show: bool(true), fillColor: solid(T.raised), transparency: num(0) }),
          { properties: { fillColor: solid(T.selected) }, selector: { id: 'hover' } },
        ],
        outline: dualEntry({ show: bool(true), lineColor: solid(T.border), weight: num(1) }),
        shape: [{ properties: { tileShape: text('rectangle') } }],
      },
      visualContainerObjects: containerObjects({ altText: placement.alt_text, background: 'none', border: false, padding: 0, link }),
      drillFilterOtherVisuals: true,
    },
  };
}

const BUILDERS = {
  textbox,
  slicer,
  advancedSlicerVisual: buttonSlicer,
  listSlicer: buttonSlicer,
  cardVisual: card,
  lineChart,
  lineClusteredColumnComboChart: comboChart,
  scatterChart,
  barChart,
  tableEx: table,
  pivotTable: matrix,
  actionButton,
};

export function buildVisual(placement, ctx) {
  const builder = BUILDERS[placement.kind];
  if (!builder) {
    throw new Error(`No builder for placement kind ${placement.kind} (${placement.id})`);
  }
  return builder(placement, ctx);
}

// The rectangle for a placement: its region, or its slot inside a region shared with other placements.
export function placementRect(placement, layout) {
  const rect = layout.region(placement.region);
  if (!placement.of || placement.of === 1) {
    return rect;
  }
  if (placement.region === 'rail') {
    return layout.stack(rect, placement.railHeights, placement.slot);
  }
  if (placement.region === 'nav') {
    return layout.split(rect, placement.of, placement.slot, 'y');
  }
  return layout.split(rect, placement.of, placement.slot, 'x');
}

export function railHeight(placement) {
  const key = placement.kind === 'slicer' ? `slicer_${placement.slicer_type === 'between' ? 'between' : 'dropdown'}` : placement.kind;
  if (!(key in RAIL_HEIGHTS)) {
    throw new Error(`No rail height for ${placement.id}`);
  }
  return RAIL_HEIGHTS[key];
}
