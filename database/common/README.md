# Common database objects

The `ContosoCare` schema shared by every target. Every value is synthetic and obviously fake: names like `Test Patient-0000001`, `555-01xx` phone numbers, `example.invalid` email addresses, and `SYN-` codes. Nothing resembles real patient data.

| File | Run in | Contents |
|---|---|---|
| `010-schema.sql` | `ContosoCare` | Schemas `care` and `demo`. Business tables in `care`: `facilities`, `providers`, `patients`, `appointments`, `encounters`, `claims`, `orders`, `inventory`, `payments`, `audit_events`, and `work_queues`. Control tables in `demo`: `scenario_runs`, `scenario_control`, `activity_profile` (with the `off` profile), and `seed_state`. Helper functions `demo.fn_numbers` and `demo.fn_rand`. Two lookups are left unindexed on purpose for the missing-index scenario. |
| `020-seed.sql` | `ContosoCare` | `demo.usp_seed_contosocare @scale, @seed, @force`. |
| `110-demo-control.sql` | `ContosoCare` | Phase 11 control objects: the `contosocare_runner` role and grants; columns added to `scenario_runs` (parameters, outcome, session IDs, runner host, profile), `scenario_control` (stop time and requester), and `activity_profile` (parameters); `scenario_run_events` (session IDs and timestamps); the scratch tables `io_scratch` and `log_rate_scratch`; `demo.fn_scenario_catalog()` (the T-SQL copy of every scenario's maximum duration); and the procedures to begin, record, end, and stop runs, set the activity profile, check free space, kill only `ContosoCare.Demo/` sessions, clean up, undo the missing-index remediation, and reset. |
| `120-scenario-procedures.sql` | `ContosoCare` | The bounded scenario procedures `demo.usp_scenario_*`: each checks its run first, loops only until the run's deadline, and stops within about a second of a stop request ([scenarios](../../scenarios/README.md)). |
| `900-status.sql` | `ContosoCare` | Read-only status the bootstraps use to decide what's left to do: Query Store state, uncapped files, recovery model, seed procedure and runner role presence, and seed state. |

## The seed

- **Deterministic:** pseudo-random values come from SHA-256 of (seed, stream, row number) through `demo.fn_rand`, never from `RAND()` or `NEWID()`. The same `@seed` (default `20261019`) and `@scale` produce the same rows on every target.
- **Set-based:** each table is filled with one `INSERT ... SELECT` over a numbers function, with no loops or cursors.
- **Sized by scale (1 to 50):** 5,000 patients, 40 providers, 20,000 appointments, 10,000 audit events, and 2,000 work items per unit. The profile sets the scale (`database.seedScale` in `config/profiles.json`: 1, 2, or 4).
- **Idempotent:** a completed seed with the same seed, scale, and version is a no-op unless `@force = 1`. It refuses to reseed while a scenario run is `Running`.

## Order

The bootstraps run the target's `000-create-database.sql` in `master`, then `010-schema.sql` and `020-seed.sql`, then the target's `030-configure.sql` in `ContosoCare`, and finally `EXEC demo.usp_seed_contosocare`. Every script is safe to re-run. The Phase 11 scripts `110-demo-control.sql` and `120-scenario-procedures.sql` follow `030-configure.sql`; the runner embeds them and applies them with `ContosoCare.Workload setup` ([workload generator](../../workload-generator/README.md)), and a bootstrap can run them directly the same way as the others.

A .NET test (`SqlScriptTests` in `workload-generator/tests/ContosoCare.Workload.Tests`) parses every `database/**/*.sql` and `scenarios/**/*.sql` file with the SQL Server 2022 parser from `Microsoft.SqlServer.TransactSql.ScriptDom` and fails on syntax errors. For the Phase 11 scripts it also checks that every loop is bounded by a deadline or a counter, that every scenario procedure checks its run and the stop flag, that nothing uses `USE`, three-part names, `DBCC`, or `xp_` procedures, and that `KILL` appears only in `demo.usp_kill_demo_sessions`, after its `ContosoCare.Demo/` and database filters.
