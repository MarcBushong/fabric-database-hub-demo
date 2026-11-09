# Missing index

Before, recommendation, action, after. Default target T2; runs on any target (T4 since 2026-11-04).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 2 sessions).
- **Before:** `demo.usp_scenario_missing_index` repeats two lookups that no index covers: claims aging by payer and submission date, and visits by reason code. Each call scans its table, and the optimizer records missing-index suggestions.
- **Recommendation:** the Database Agent (preview), the missing-index DMVs, or the plan's `MissingIndex` element suggest `(payer_code, submitted_on) INCLUDE (billed_amount, claim_status)` on `care.claims` and `(reason_code, scheduled_start)` on `care.appointments`.
- **Action, with human approval:** a person reviews and runs [`remediation.sql`](remediation.sql) in `ContosoCare` (it needs `ALTER` on the tables). Nothing in the repo applies it automatically: the runner doesn't embed it and has no code that creates indexes.
- **After:** run the scenario again; the same lookups seek, and Query Store shows the plan change.
- **Back to "before":** `reset --undo-remediation` (or `EXEC demo.usp_undo_missing_index_remediation;`) drops exactly those two indexes.
- **On T4 (PostgreSQL, 2026-11-04):** the runner sends the same two lookups itself, as top-level parameterized statements, so Query Store (`pg_qs.query_capture_mode` `TOP`) captures them; `demo.usp_scenario_missing_index` only checks that the run still runs, because a statement inside a function is nested, and `TOP` doesn't capture nested statements. Autonomous tuning, on by default on T4's 4-vCore size, can then recommend `CREATE INDEX` for them after a tuning session (`index_tuning.analysis_interval` 60: about an hour after the lookups start, while T4 runs). The recommendation is in the Azure portal (the server's **Intelligent Performance** > **Autonomous tuning**) and through `az postgres flexible-server autonomous-tuning`, not in Database Hub, whose PostgreSQL view shows metrics only. Nothing applies it: `index_tuning.mode` is `REPORT`, and `remediation.sql` and `--undo-remediation` are for T1 to T3. The timing is unproven live ([autonomous tuning](https://learn.microsoft.com/azure/postgresql/monitor/concepts-autonomous-tuning), updated 2026-07-16, checked 2026-11-04).

```powershell
ContosoCare.Workload run --target T2 --scenario missing-index
ContosoCare.Workload reset --target T2 --undo-remediation
```
