# Smoke tests

Quick live checks after a deployment: VM health, SQL connectivity, Arc status, and telemetry presence. They're the live validation catalog in `scripts/validate.ps1` (Phase 14, [ADR 0012](../../docs/adr/0012-validation-model.md)), not separate files here: for example, `./scripts/validate.ps1 -Area Infrastructure, T1, T2, T3, Telemetry`. They run only against a deployed environment, with the owner's go-ahead.
