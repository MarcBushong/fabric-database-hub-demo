# Plan regression (automatic plan correction)

A T3 incident (Azure SQL Database) for the showcase: one query's plan regresses, and automatic tuning corrects it. It's the one optimization that can be recommended and applied within a single session.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 20 at most; 2 sessions by default, 4 at most). T3 only: SQL Server 2022 Standard on T1 and T2 has no automatic tuning ([editions](https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2022)), and the procedure refuses to run there.
- **The query:** `demo.usp_visit_summary_lookup`, a front-desk summary of a few patients' visits by patient ID range. Its plan follows the first range it's compiled for: a few patients seek `ix_appointments_patient` and look their rows up (plan A); every patient scans `care.appointments` (plan B). A range predicate keeps it out of parameter-sensitive plan optimization, which handles equality predicates only.
- **The run:**
  1. Session 1 unforces a plan that an earlier run left forced for the lookup, and marks the lookup for recompilation (`sp_recompile`).
  2. For the first `goodPercent` of the run (35% by default), every session runs the lookup for one to three patients at a time: plan A, fast.
  3. At the switch, session 1 marks the lookup for recompilation again and runs it once for every patient, so the cached plan scans (plan B). The other sessions stay out of those 5 seconds.
  4. Every session goes on with narrow ranges on plan B: each lookup now scans the table. Query Store records one query whose plan regressed.
  5. With `FORCE_LAST_GOOD_PLAN` on, Azure SQL Database's default, the engine forces plan A once the estimated CPU gain is over 10 seconds, and then verifies that the forced plan is better ([automatic tuning](https://learn.microsoft.com/sql/relational-databases/automatic-tuning/automatic-tuning), [Azure SQL automatic tuning](https://learn.microsoft.com/azure/azure-sql/database/automatic-tuning-overview)).
- **Bounds:** sessions tagged `ContosoCare.Demo/plan-regression/<run>`; the lookups only read; the run touches only `demo.usp_visit_summary_lookup`'s own plans (recompile and unforce); its maximum is 20 minutes. The runner can recompile and unforce on T3 because it signs in as a member of the P6 group, T3's Microsoft Entra administrator.
- **Where to look:**
  - `sys.dm_db_tuning_recommendations`: a `FORCE_LAST_GOOD_PLAN` recommendation for the lookup's query, with the regressed and recommended plan IDs, its estimated gain, and its state (Verifying, then Success). The DMV shows the regression whether or not the option is on.
  - The Azure portal: the database's **Automatic tuning** page and its history.
  - Query Store in SSMS: **Regressed Queries** and **Queries With Forced Plans**; `sys.query_store_plan.is_forced_plan`.
  - Database Hub: CPU steps up at the switch and back down once plan A is forced. Database Hub's telemetry describes resources, not queries, so the plans themselves are in the places above.
- **Timing (not documented):** the engine's detection follows the regressed executions; with 2 sessions at intensity 6, several hundred regressed lookups run within the first minutes after the switch. Whether and when the plan is forced within a 10-minute slot is unproven live until the owner's check ([limitations](../../docs/limitations.md)).
- **Reset:** a forced plan stays after the run, so it can be shown. The next run of this scenario, or `reset`, unforces it (`sp_query_store_unforce_plan`, for the lookup's queries only; the reset's check `forced-plan-unforced` says when it did).

```powershell
ContosoCare.Workload run --target T3 --server <server> --scenario plan-regression --duration 10m
```
