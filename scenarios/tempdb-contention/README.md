# tempdb allocation contention

Latch contention in tempdb for T2 (and any target): many sessions creating and dropping temporary tables at once (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 16 sessions by default, 32 at most).
- **Sessions:** `concurrency` sessions tagged `ContosoCare.Demo/tempdb-contention/<run>`, each running `demo.usp_scenario_tempdb_contention`: in a loop, `CREATE TABLE #scratch`, a clustered index added after the table exists, `rowsPerTable` rows of 400 bytes, one read, and `DROP TABLE`.
- **Why the index:** SQL Server caches and reuses temporary tables created in a procedure; changing a table's definition after `CREATE TABLE` stops that, so every iteration allocates pages and system catalog rows in tempdb, the source of the `PAGELATCH` waits.
- **Scope:** the `#tables` belong to the scenario's own sessions and are dropped every iteration (at most about 800 KB per session at a time). tempdb is the only place outside `ContosoCare` the scenario touches, as any `#table` does.
- **Expected signals:** Buffer Latch waits (`PAGELATCH_EX`, `PAGELATCH_SH`, `PAGELATCH_UP`) on tempdb pages; `Temp Tables Creation Rate`, `Active Temp Tables`, and `Free Space in tempdb (KB)`; `SQL Re-Compilations/sec` and CPU rising with the DDL churn.
- **By target:** T1's tempdb is on the VM's local temporary disk; T2's is in the guest. Azure SQL Database (T3) manages tempdb, and at 1 vCore or less fewer sessions run at once, so expect fewer latch waits and more CPU waits there.
- **Reset:** nothing persists; SQL Server drops any `#table` that remains when its session closes, and `reset` kills leftover `ContosoCare.Demo/` sessions.

```powershell
ContosoCare.Workload run --target T2 --scenario tempdb-contention --duration 10m --concurrency 24 --intensity 10
```
