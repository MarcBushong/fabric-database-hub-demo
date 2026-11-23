# Integration tests

Tests that need real services: the workload runner against a SQL Server 2022 container (Phase 11) and live checks against a deployed environment, which run only with the owner's go-ahead.

- [rca-query-store.md](rca-query-store.md): unit 2's live probes for the Incident RCA's Query Store evidence (2026-11-23): blindness by query IDs, execution-weighted totals against the source, waits, and the reviews' live checks.
