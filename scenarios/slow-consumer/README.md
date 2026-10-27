# Slow consumer

A client that reads its results slowly, for T3 (and any target): the server waits on the network, not on itself (Phase 25b).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 4 sessions by default, 8 at most).
- **Sessions:** `concurrency` sessions tagged `ContosoCare.Demo/slow-consumer/<run>`. Each runs `demo.usp_scenario_slow_consumer`, a wide query (about 1 KB per row, `rowsPerQuery` rows at most), and the runner reads the result set slowly on purpose: 25 rows, then a pause from the intensity (about 100 ms at 1 up to 1 second at 10). The server fills its network buffers and waits for the client (`ASYNC_NETWORK_IO`).
- **Bounds:** the runner cancels the query at the deadline or on a stop request (an attention), and runs it again while the run lasts. The procedure only reads.
- **Expected signals:** Network IO waits (`ASYNC_NETWORK_IO`), one long wait per session; `SQL Attention rate` above 0 when the runner cancels; the sessions in `SqlServerActiveSessions` for minutes.
- **By target:** on T3 the client is T1's runner, across the network, the usual shape of a slow application against Azure SQL Database. On T1 and T2 the runner on the same machine is the client; the wait is the same.
- **Reset:** read-only; the runner cancels its queries and closes its sessions, and `reset` kills any that remain.

```powershell
ContosoCare.Workload run --target T3 --scenario slow-consumer --duration 10m --concurrency 6 --intensity 8
```
