# F35's speed candidates (temporary)

Two faster forms of the history model's `Snapshot Value`, for Final tests to time on B's model before one replaces the TMDL's. Both give the TMDL's answers, to floating-point rounding, so only the work per bin and series differs. They're written from the TMDL's measure, and `tests/unit/Fabric.PowerBI.Tests.ps1` keeps every other measure they define equal to the TMDL's. This folder goes once the measure is chosen.

| Candidate | What changes, against 30392d79's measure |
|---|---|
| C1 | A bin reads its points' own saves first, with their intervals. Another save can weigh on those points only if its window starts before the longest of those intervals ends, counted from the bin. So where no other save's window reaches that far, the points are the value, with no other save's interval, rows, or table of points worked out. An Azure Monitor save's interval takes one pass over its bins, not one pass for each of the ladder's 9 steps. |
| C2 | C1, and where one save has points at a bin and no finer save's window reaches their interval, its point is the value, without the table of points per save. |

## Why the answers can't change

- **C1:** before, a bin weighed every save whose window ends after the bin and starts within a day of it, and the saves with a point there.
  - A save can be finer than a point and overlap it only if its window starts before the point's interval ends, which is at most the longest of the bin's own intervals after the bin, and ends after the bin. C1 weighs exactly those saves, and the saves with a point there.
  - Where that's only the points' own save, the TMDL's rule finds no finer save, so the value is that save's point.
  - The ladder's steps divide each other in turn (1, 5, 15, 30, 60, 180, 360, 720, 1,440), so a step divides every bin's minute exactly when it's at most the smallest, over the bins, of the coarsest step that divides each. That's the same set of steps as before.
- **C2:** with one save's points at a bin, the TMDL's rule keeps that save's point when no finer save's window reaches its interval. C2 tests exactly that, with the same interval and window cut, before it builds the table of points.

## Files

| File | For | Its answer must equal, to floating-point rounding |
|---|---|---|
| `c1-bins.dax`, `c2-bins.dax` | The values per series and bin | `../snapshot-value-bins.dax`'s at 30392d79 |
| `c1-window.dax`, `c2-window.dax` | The window's totals and peaks | `../window-f35.dax`'s at 30392d79 |
| `c1-estate.dax`, `c2-estate.dax` | Timing the Estate series query | `../estate-f35.dax`'s at 30392d79 |
| `c1-t5.dax`, `c2-t5.dax` | Timing T5's measures per bin | `../t5-f35.dax`'s at 30392d79 |

Each query defines its candidate `Snapshot Value` and every measure it evaluates, with the TMDL's expressions, as the checks one folder up do. A shortcut sums a point's rows in one query where the TMDL's measure sums them per save, so a value can differ in its last digits: compare numbers as the checks one folder up do, to within a difference of at most 1e-9 of the larger.

## How to time them

1. In one capacity lease, warm each query up once, then run each 5 times, interleaved and in alternating order: `../estate-today.dax`, the da68aed5 measure with `Under` renamed (Final tests' own variant), `../estate-f35.dax` at 30392d79, `c1-estate.dax`, and `c2-estate.dax`. Then do the same with the T5 queries.
2. Take each query's median, end to end, and the trivial query's round trip, as before.
3. **Pass:** each answer equals the one in the table above, to that tolerance, and the Estate and T5 queries take at most about twice today's time, end to end.
