# Read replica lag

A T4 incident (Azure Database for PostgreSQL flexible server, [ADR 0019](../../docs/adr/0019-t4-postgresql-flexible-server.md)) on T4's read replica ([ADR 0025](../../docs/adr/0025-t4-read-replica.md)): a reporting query on the replica holds back the replay of T4's changes.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 15 at most; each cycle holds for 240 seconds by default, 540 at most).
- **Needs the replica:** `pgreplica01-<deploymentId>`, which `start-demo.ps1` creates for each session. T1 knows its name from `deploy.ps1`, and its runner gets it as `--replica-server`; without it, the run is refused with that fix, and a replica that doesn't answer or isn't in recovery refuses it too.
- **Sessions:** all tagged `ContosoCare.Demo/replica-lag/<run>`, all to `contosocare`. Each cycle:
  - **The report** (on the replica) reads `demo.replica_lag_marks` and sleeps for `holdSeconds` in the same statement, so it holds the table's `ACCESS SHARE` lock that long. Its `statement_timeout` is the hold plus 30 seconds, never past the run's hard deadline.
  - **The writer** (on T4), once the replica's `pg_locks` shows the report holding the table, calls `demo.usp_scenario_replica_lag` once with its lock: an `ACCESS EXCLUSIVE` lock on the table in a short transaction (`lock_timeout` 5 seconds), which T4 writes to the WAL. Then it commits a small mark every `markIntervalMs`.
  - **A monitor** (on the replica, one for the run) confirms the report's lock and reads the replay lag for the run's events.
- **What happens:** the replica can't replay T4's lock while the report holds the table, so its replay waits, up to `max_standby_streaming_delay` (10 minutes on the replica), and everything after the lock waits with it ([handling query conflicts](https://www.postgresql.org/docs/current/hot-standby.html#HOT-STANDBY-CONFLICT)). **Read Replica Lag**, the time since the last replayed transaction, climbs to about `holdSeconds`. When the report ends, or recovery cancels it at `max_standby_streaming_delay` (SQLSTATE 40001, which the run records as an expected end), replay catches up within seconds. The writer goes on for 30 seconds, so the lag visibly drops, then the run pauses `pauseSeconds` and starts the next cycle, each cut to end before the run's deadline.
- **Bounds:** only the demo's own table and sessions. T4 holds its lock for one short call; on the replica, only a query on `demo.replica_lag_marks` would wait behind the replay, and every query there sees data as old as the lag. `stop` and `reset` with `--replica-server` end the replica's `ContosoCare.Demo/` sessions (`pg_cancel_backend`, then `pg_terminate_backend`), and a replica that isn't there never fails them.
- **Proven live:** not yet.
- **Expected signals:** Database Hub's PostgreSQL dashboard for the replica shows **Read replica lag** climbing to about `holdSeconds` and dropping each cycle; the Azure portal's Metrics show **Max Physical Replication Lag** (bytes) growing on T4.
- **Reset:** the marks are the only rows the scenario writes; the auto-cleanup and `reset` delete them.

```powershell
ContosoCare.Workload run --target T4 --server <fqdn> --replica-server <replica-fqdn> --scenario replica-lag --duration 10m --param holdSeconds=240
```
