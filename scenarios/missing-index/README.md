# Missing index

Before, recommendation, action, after. Default target T2; runs on any target.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 2 sessions).
- **Before:** `demo.usp_scenario_missing_index` repeats two lookups that no index covers: claims aging by payer and submission date, and visits by reason code. Each call scans its table, and the optimizer records missing-index suggestions.
- **Recommendation:** the Database Agent (preview), the missing-index DMVs, or the plan's `MissingIndex` element suggest `(payer_code, submitted_on) INCLUDE (billed_amount, claim_status)` on `care.claims` and `(reason_code, scheduled_start)` on `care.appointments`.
- **Action, with human approval:** a person reviews and runs [`remediation.sql`](remediation.sql) in `ContosoCare` (it needs `ALTER` on the tables). Nothing in the repo applies it automatically: the runner doesn't embed it and has no code that creates indexes.
- **After:** run the scenario again; the same lookups seek, and Query Store shows the plan change.
- **Back to "before":** `reset --undo-remediation` (or `EXEC demo.usp_undo_missing_index_remediation;`) drops exactly those two indexes.

```powershell
ContosoCare.Workload run --target T2 --scenario missing-index
ContosoCare.Workload reset --target T2 --undo-remediation
```
