# Integration tests

Tests that need real services: the workload runner against a SQL Server 2022 container (Phase 11) and live checks against a deployed environment, which run only with the owner's go-ahead.

- `Invoke-LivyTokenProbe.ps1` (F35, 2026-11-23): whether Fabric's Livy API takes the Azure CLI's Fabric token. It starts a Livy session in the demo's lakehouse, runs `SELECT 1`, reads the history table, and deletes the session. Read-only, except with `-KeptValueModule`, its smoke test of `fabric/history/kept_value.py`, which works only on a scratch copy of the history table and drops it. `-ExportPath` also writes that copy's rows to a local JSON lines file for F35's live proof (`fabric/app/scripts/f35-proof.ts`).
- [rca-query-store.md](rca-query-store.md): unit 2's live probes for the Incident RCA's Query Store evidence (2026-11-23): blindness by query IDs, execution-weighted totals against the source, waits, and the reviews' live checks.
