// The "DbHub Cockpit Dark" theme: the design skill's base theme (assets/base.json) adapted to the contract's tokens.
// Theme files use plain JSON values, not PBIR expressions.

export const TOKENS = {
  page: '#0E0E10',
  surface: '#17171C',
  raised: '#1F1F26',
  rowAlternate: '#1B1B22',
  border: '#2A2A3A',
  gridline: '#3A3A4A',
  foreground: '#F2F2F5',
  secondary: '#B4B4C2',
  muted: '#8C8C9C',
  ink: '#E6E6EE',
  indigo: '#5772D9',
  indigoLine: '#7B93F0',
  warning: '#FFB020',
  fail: '#FF4D5A',
  manual: '#8CEEEE',
  selected: '#3A3A48',
};

function parseTextClass(spec) {
  const match = /^(.+?)\s+(\d+)\s+(#[0-9A-Fa-f]{6})$/.exec(String(spec).trim());
  if (!match) {
    throw new Error(`Malformed text class: ${spec}`);
  }
  return { fontFace: match[1], fontSize: Number(match[2]), color: match[3].toUpperCase() };
}

const fill = (hex) => ({ solid: { color: hex } });

export function buildTheme(themeContract) {
  const t = TOKENS;
  const textClasses = Object.fromEntries(
    Object.entries(themeContract.text_classes).map(([name, spec]) => [name, parseTextClass(spec)]),
  );
  const tableStyle = {
    columnHeaders: [{
      autoSizeColumnWidth: true,
      columnAdjustment: 'growToFit',
      backColor: fill(t.raised),
      fontColor: fill(t.foreground),
      outlineColor: fill(t.border),
      bold: true,
    }],
    values: [{
      backColorPrimary: fill(t.surface),
      backColorSecondary: fill(t.rowAlternate),
      fontColorPrimary: fill(t.foreground),
      fontColorSecondary: fill(t.foreground),
      outlineColor: fill(t.border),
    }],
    grid: [{
      gridHorizontal: true,
      gridHorizontalColor: fill(t.border),
      gridVertical: false,
      outlineColor: fill(t.border),
    }],
    total: [{ fontColor: fill(t.foreground), backColor: fill(t.raised) }],
  };
  const axisText = { labelColor: fill(t.secondary), titleColor: fill(t.secondary), fontSize: 9 };

  return {
    name: themeContract.name,
    dataColors: themeContract.data_colors,
    background: themeContract.background,
    foreground: themeContract.foreground,
    tableAccent: themeContract.table_accent,
    good: themeContract.sentiment.good,
    neutral: themeContract.sentiment.neutral,
    bad: themeContract.sentiment.bad,
    maximum: t.ink,
    center: t.muted,
    minimum: t.selected,
    null: t.muted,
    firstLevelElements: themeContract.foreground,
    secondLevelElements: themeContract.secondary_foreground,
    thirdLevelElements: t.border,
    fourthLevelElements: t.muted,
    secondaryBackground: t.surface,
    textClasses,
    visualStyles: {
      '*': {
        '*': {
          background: [{ show: true, color: fill(t.surface), transparency: 0 }],
          border: [{ show: true, color: fill(t.border), radius: 4, width: 1 }],
          dropShadow: [{ show: false }],
          padding: [{ top: 8, bottom: 8, left: 8, right: 8 }],
          visualHeader: [{ show: false }],
          title: [{ fontColor: fill(t.foreground), fontFamily: 'Segoe UI Semibold', fontSize: 13 }],
          subTitle: [{ fontColor: fill(t.secondary), fontSize: 10 }],
          categoryAxis: [{ ...axisText, gridlineShow: false, showAxisTitle: false }],
          valueAxis: [{ ...axisText, gridlineShow: true, gridlineStyle: 'dotted', gridlineColor: fill(t.gridline), showAxisTitle: false }],
          legend: [{ labelColor: fill(t.secondary), fontSize: 9 }],
          labels: [{ color: fill(t.foreground), fontSize: 9 }],
        },
      },
      page: {
        '*': {
          background: [{ color: fill(t.page), transparency: 0 }],
          outspace: [{ color: fill(t.page), transparency: 0 }],
        },
      },
      textbox: {
        '*': {
          padding: [{ top: 0, bottom: 0, left: 0, right: 0 }],
          background: [{ show: false }],
          border: [{ show: false }],
        },
      },
      cardVisual: {
        '*': {
          value: [{ bold: true, fontColor: fill(t.foreground), $id: 'default' }],
          label: [{ show: true, fontColor: fill(t.secondary), $id: 'default' }],
          outline: [{ show: false, $id: 'default' }],
          cardCalloutArea: [{ paddingUniform: 0 }],
        },
      },
      tableEx: { '*': tableStyle },
      pivotTable: {
        '*': {
          ...tableStyle,
          rowHeaders: [{ fontColor: fill(t.foreground), backColor: fill(t.surface), outlineColor: fill(t.border) }],
        },
      },
      lineChart: {
        '*': {
          lineStyles: [{ strokeWidth: 2, lineChartType: 'linear', areaShow: false, showMarker: false }],
          labels: [{ show: false }],
          legend: [{ show: true, position: 'Top', labelColor: fill(t.secondary), fontSize: 9 }],
        },
      },
      barChart: {
        '*': {
          labels: [{ show: true, fontSize: 10, color: fill(t.foreground) }],
          valueAxis: [{ show: false, gridlineShow: false, showAxisTitle: false }],
          categoryAxis: [{ show: true, fontSize: 10, labelColor: fill(t.secondary), showAxisTitle: false, gridlineShow: false }],
          dataPoint: [{ borderShow: false }],
          legend: [{ show: false }],
        },
      },
      scatterChart: {
        '*': {
          legend: [{ show: true, position: 'Top', labelColor: fill(t.secondary), fontSize: 9 }],
        },
      },
      slicer: {
        '*': {
          header: [{ fontFamily: 'Segoe UI Semibold', textSize: 10, fontColor: fill(t.secondary), outlineStyle: 0 }],
          items: [{ fontFamily: 'Segoe UI', textSize: 10, fontColor: fill(t.foreground), background: fill(t.raised), outlineStyle: 0, padding: 2 }],
          date: [{ fontFamily: 'Segoe UI', textSize: 10, fontColor: fill(t.foreground), background: fill(t.raised) }],
        },
      },
      advancedSlicerVisual: {
        '*': {
          value: [{ fontColor: fill(t.foreground), fontSize: 10 }],
        },
      },
      listSlicer: {
        '*': {
          value: [{ fontColor: fill(t.foreground), fontSize: 10 }],
        },
      },
    },
  };
}
