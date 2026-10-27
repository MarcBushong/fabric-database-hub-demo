# Idle in transaction

A T4 incident (Azure Database for PostgreSQL flexible server, [ADR 0019](../../docs/adr/0019-t4-postgresql-flexible-server.md)): sessions that opened a transaction and went quiet without committing.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 3 idle sessions by default).
- **Sessions:** all tagged `ContosoCare.Demo/idle-in-transaction/<run>`:
  - **Idle sessions** (`concurrency`) each open a `REPEATABLE READ` transaction, lock `rowsPerSession` Submitted claims (`demo.usp_scenario_idle_in_transaction`), then send nothing for `holdSeconds`: state `idle in transaction`. They always roll back, pause `pauseSeconds`, and repeat.
  - **Blocked writers** (`blockedWriters`) keep updating those claims (`demo.usp_scenario_idle_writer`) in transactions they roll back, so they queue on the idle sessions' row locks (wait event `Lock:transactionid`).
  - **Normal workers** (`normalWorkers`) run the healthy baseline, whose writes leave dead rows that vacuum can't remove while the idle transactions hold the horizon.
- **Bounds:** each session's `idle_in_transaction_session_timeout` ends it before the run's hard deadline, and the server's 15-minute setting is the backstop.
- **Expected signals:** the Azure portal's Metrics show **Sessions By State** (idle in transaction), **Oldest Transaction**, **Sessions By WaitEventType** (Lock), and **Oldest xmin Age** (enhanced metrics); Hub's PostgreSQL dashboard shows steady connections.
- **Reset:** every transaction rolls back, so the claims stay as seeded; `reset` ends leftover demo sessions and verifies no demo transaction is open.

```powershell
ContosoCare.Workload run --target T4 --server <fqdn> --scenario idle-in-transaction --duration 10m --param holdSeconds=180
```
