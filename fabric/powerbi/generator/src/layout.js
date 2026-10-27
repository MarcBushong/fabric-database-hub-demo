// Converts the layout contract's grid regions to pixel rectangles snapped to the contract's grid step.

export function makeLayout(contract) {
  const { canvas, grid } = contract;
  const columnWidth = (canvas.width - 2 * canvas.margin - (grid.columns - 1) * canvas.gutter) / grid.columns;
  const rowHeight = (canvas.height - 2 * canvas.margin - (grid.rows - 1) * canvas.gutter) / grid.rows;
  const snap = (value) => Math.round(value / canvas.snap) * canvas.snap;

  // Regions are [column1, row1, column2, row2) with 1-based, end-exclusive grid lines.
  function region(name) {
    const cells = grid.regions[name];
    if (!Array.isArray(cells) || cells.length !== 4) {
      throw new Error(`Unknown or malformed region: ${name}`);
    }
    const [c1, r1, c2, r2] = cells;
    const left = canvas.margin + (c1 - 1) * (columnWidth + canvas.gutter);
    const top = canvas.margin + (r1 - 1) * (rowHeight + canvas.gutter);
    const right = canvas.margin + (c2 - 1) * (columnWidth + canvas.gutter) - canvas.gutter;
    const bottom = canvas.margin + (r2 - 1) * (rowHeight + canvas.gutter) - canvas.gutter;
    const x = snap(left);
    const y = snap(top);
    return { x, y, width: snap(right) - x, height: snap(bottom) - y };
  }

  // Splits a region into equal slots along one axis, with gutters between them.
  function split(rect, count, index, axis) {
    const length = axis === 'x' ? rect.width : rect.height;
    const size = (length - (count - 1) * canvas.gutter) / count;
    const start = (axis === 'x' ? rect.x : rect.y) + (index - 1) * (size + canvas.gutter);
    const end = index === count ? (axis === 'x' ? rect.x + rect.width : rect.y + rect.height) : snap(start + size);
    const from = snap(start);
    return axis === 'x'
      ? { x: from, y: rect.y, width: end - from, height: rect.height }
      : { x: rect.x, y: from, width: rect.width, height: end - from };
  }

  // Stacks slots vertically: fixed heights for most, and the one flexible slot takes the rest.
  function stack(rect, heights, index) {
    const fixed = heights.reduce((sum, height) => sum + (height ?? 0), 0);
    const flexible = rect.height - fixed - (heights.length - 1) * canvas.gutter;
    if (flexible < 0 || heights.filter((height) => height === null).length > 1) {
      throw new Error('The stacked slots do not fit their region.');
    }
    let y = rect.y;
    for (let slot = 0; slot < index - 1; slot += 1) {
      y += (heights[slot] ?? flexible) + canvas.gutter;
    }
    const height = index === heights.length ? rect.y + rect.height - y : heights[index - 1] ?? flexible;
    return { x: rect.x, y, width: rect.width, height };
  }

  return { region, split, stack, columnWidth, rowHeight, snap, canvas };
}
