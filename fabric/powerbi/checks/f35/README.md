# F35's live check of Snapshot Value

Read-only DAX queries that check the history model's new `Snapshot Value` (F35) on a deployed model whose history already holds overlapping saves at different intervals, with no redeploy. They're set for B's live test (2026-11-21): the session's own save, with a window of 15:14 to 16:57 UTC, and a day-long save four hours later. Its bins from 15:00 to 17:15 hold the partly covered 15-minute ones at both ends.

Each `-f35` query and `snapshot-value-bins.dax` defines the new measure in the query (`DEFINE MEASURE`), with the same expression as `SM_DatabaseHub_History.SemanticModel/definition/tables/Telemetry Snapshots.tmdl`, which `tests/unit/Fabric.PowerBI.Tests.ps1` keeps identical. A `-today` query uses the deployed model's own measure.

| File | What it returns |
|---|---|
| `rows.dax` | The rows for the TypeScript reference: every SQL row of the bins from 14:45 to 17:30, one row with no bin and no value for each SQL series and save whose window overlaps them (the measure sees every save of a series; the reference reads these rows as saves only), and every row of each Azure Monitor save whose window overlaps them, whose bins give its step. |
| `snapshot-value-bins.dax` | Per target, analysis, metric, and bin from 15:00 to 17:15: `Today` (the deployed measure) and `F35` (the new one). |
| `window-today.dax`, `window-f35.dax` | Per target, the window's totals and peaks (lock, wait, and buffer IO seconds, IO MB, batches, deadlocks, CPU, blocked processes, sessions, T5's requests, 429s, RU, and normalized RU) from 15:00 to 17:15, with each measure. |
| `estate-today.dax`, `estate-f35.dax` | The Insights app's Estate series query (`fabric/app/src/data/queries.ts`, per bin and target, T1 to T3, for B's date), with each measure: for timing. |

## Run it

1. Run the six queries against the model, for example through the Execute Queries REST API or an XMLA endpoint, and save each result as JSON.
2. From `fabric/app`, run the reference on `rows.dax`'s result: `npx tsx scripts/f35-reference.ts <rows.json>`. It reads rows as objects or as arrays beside their column names, keys with or without brackets, and prints JSON:
   - `bins`: the new measure's value per `target|analysis|metric|bin` (bin in ISO UTC), by the model's rule (`fabric/app/src/data/snapshot-value.ts`);
   - `measures`: per target, each window measure by the model's rule (`model`) and by the shared `finestPerInterval` (`finest`, `fabric/app/src/data/finest-per-interval.ts`), on the same rows.
3. For another model or session, change the dates in every file, and pass the window to the reference: `npx tsx scripts/f35-reference.ts <rows.json> <from> <to>`.

## Pass

Compare numbers to within floating-point rounding, for example a difference of at most 1e-9 of the larger.

- **No doubled totals:** `window-f35.dax`'s totals equal the reference's `model` values, and those equal its `finest` values. `window-today.dax` shows what the newest-per-bin rule counted twice.
- **Peaks from the finest grain:** the same for the peaks, for example the replica's lag and T5's normalized RU.
- **The partly covered bins** in `snapshot-value-bins.dax`'s `F35` column equal the reference's `bins`: T5's requests and 429s at 15:30, the replica's lag at 16:45, and SQL's bins at 15:00 and 16:45. In the model, a remainder stays at its own bin's start: the day save's 34 s of replica lag, from 16:57 to 17:00 after the session's window ended, shows at 16:45, beside the session's 1 s there, so the bin shows 34 s.
- **Query time:** `estate-f35.dax` takes at most about twice as long as `estate-today.dax`. Run each a few times, and compare like with like (cold or warm cache).

Where the model's rule differs from `finestPerInterval` by design (a finer save's window stands for its rows), [the limitations](../../../../docs/limitations.md#the-history-models-overlapping-saves-f35) say how.
