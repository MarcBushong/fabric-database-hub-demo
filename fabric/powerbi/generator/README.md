# PBIR generator for RPT_DatabaseHub_History

This Node.js tool writes the Power BI history report as PBIR files from the `Design Brief:` YAML block in [`../_brief/report-spec.md`](../_brief/report-spec.md). It checks every field against the semantic model's TMDL in [`../SM_DatabaseHub_History.SemanticModel/definition/`](../SM_DatabaseHub_History.SemanticModel/definition/). The output is deterministic: the same spec and model always give byte-identical files, and a test fails when the committed report drifts from them.

## Use

Node.js 22 or later; the build pins Node 26 and the CLIs in [`config/versions.json`](../../../config/versions.json).

```powershell
cd fabric/powerbi/generator
npm ci
npm run generate   # rewrites ../RPT_DatabaseHub_History.Report and ../DbHubHistory.pbip
npm test           # determinism, page and visual counts, layout, model bindings, theme, drillthrough, render fixes
npm run check      # exit 1 when the committed files differ from a fresh generation
powerbi-report-author validate ../RPT_DatabaseHub_History.Report
```

Validation has 0 errors. It shows 4 warnings by design:

- Three `PBIR_SLICER_HEADER_MAY_CLIP` warnings for the dropdown slicers in the 64 px header band. The contract gives these slicers 2 px padding so they fit the band.
- One `PBIR_DRILLTHROUGH_BACK_BUTTON_MISSING` warning for the incident page. Its Previous button returns to the estate page instead.

For a Power BI Desktop preview against the deployed model, write a copy outside Git with the full `byConnection` form. The connection string holds real IDs, so the generator refuses `--connection` without `--out`:

```powershell
node src/generate.js --out ../../../out/desktop-preview --connection "<connection string>"
```

`powerbi-desktop open` can't start the Microsoft Store build of Power BI Desktop (`spawn EPERM`). Start it through its app execution alias, `& "$env:LOCALAPPDATA\Microsoft\WindowsApps\PBIDesktopStore.exe" "<full path>\DbHubHistory.pbip"`, then use `powerbi-desktop status` and `powerbi-desktop screenshot <page-id> --pid <pid>`. `reload` needs a report folder, which a `byConnection` copy doesn't give it, so close and reopen Desktop after each change.

## What it writes

| Path | Content |
|------|---------|
| `RPT_DatabaseHub_History.Report/definition.pbir` | `byPath` to the local semantic model. `scripts/configure-powerbi.ps1` swaps in the minimal `byConnection` form at deploy time. |
| `RPT_DatabaseHub_History.Report/.platform` | Item type and display name, with a logical ID derived from the report name |
| `RPT_DatabaseHub_History.Report/definition/` | `report.json`, `version.json`, four pages with 10, 8, 11, and 10 visuals, the `Explorer reset` bookmark |
| `RPT_DatabaseHub_History.Report/StaticResources/RegisteredResources/` | The "DbHub Cockpit Dark" theme, named `DbHubCockpitDark-<content hash>.json` so Desktop never serves a cached copy |
| `DbHubHistory.pbip` | The project entry point |

`StaticResources/SharedResources/BaseThemes/Fluent2-CY26SU10.json` is vendored, not generated. It's the base theme that `powerbi-report-author scaffold` 0.5.0 writes.

## Implementation choices

The contract leaves these choices to the implementation:

- **IDs.** Page, visual, filter, and bookmark names are the first 20 hex characters of a SHA-256 of their contract IDs.
- **Layout.** Regions convert to pixels with 32 px margins, 24 px gutters, and every edge snapped to 8 px. Slots split their region evenly, except on the explorer's filter rail. There the slicers get fixed heights and the status list takes the rest.
- **Formatting.** Objects, properties, and enum values come from `powerbi-report-author formatting describe-object`. Tables use explicit dark cell colors, and cards bind their accent bar to each tile's rail measure. Multi-value tiles use short callout labels of nine characters or fewer, because a measure name doesn't fit a third of a tile.
- **What Desktop ignores** (the render check, 2026-10-22; a test pins each):
  - Buttons and the list slicer get a static entry next to the `id: default` entry, per the authoring skill's dual-entry rule. With only the selector entry, Desktop drops the text and the font size silently.
  - On the incident timeline (a combo chart), Desktop ignores a metadata selector on the column series. The band's color and 70 % transparency are in the static `dataPoint` entry, which applies to the band, the only column series.
- **Top N filters.** These order by a measure, the form Power BI Desktop writes when the subquery lists the measure's table. The incident evidence table's "Top 4 by Captured At UTC" is skipped and printed as a note. A table has no category to rank, and a Top N subquery doesn't see the visual's measure filter, so it would rank findings outside the incident window. The table keeps its measure filter and its severity sort, and its height shows about four rows.
- **Interactions.** The contract's `cross_filter_rules` are prose, so `src/report.js` restates them as source and target pairs.

Sources: [Power BI Project report folder (PBIR)](https://learn.microsoft.com/power-bi/developer/projects/projects-report), [PBIR JSON schemas](https://github.com/microsoft/json-schemas/tree/main/fabric/item/report/definition).
