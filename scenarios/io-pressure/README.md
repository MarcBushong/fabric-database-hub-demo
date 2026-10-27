# IO pressure

Bounded reads and writes over seeded scratch data. Default target T2; runs on any target.

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 2 sessions; `scratchMb` 1,024 by default, 256 on T3, at most 6,144).
- **Free space first:** the runner checks that the volumes holding `ContosoCare` have `scratchMb` plus 2 GB free (on T2 that's the guest's VHDX), and `demo.usp_check_space` checks the headroom under the file caps with a 512 MB margin; an uncapped file is refused.
- **Procedure:** `demo.usp_scenario_io_pressure`. Worker 1 grows `demo.io_scratch` to `scratchMb`, 8 MB per statement (one 7,000-byte row per page); then every worker alternates range scans of up to 256 MB with 16 MB range updates that checkpoints write back.
- **Expected signals:** `SqlServerStorageIO` reads, writes, and stalls; `Page reads/sec`, `Readahead pages/sec`, and `Page writes/sec`; `WRITELOG` while the set grows. `PAGEIOLATCH` waits appear only once `scratchMb` exceeds the memory SQL Server can use, so on small VMs with the default size most reads come from memory; raise `scratchMb` within the caps to make them physical.
- **Reset:** auto-cleanup and reset truncate `demo.io_scratch`; the space stays allocated in the data file for the next run. Business data is never touched.

```powershell
ContosoCare.Workload run --target T2 --scenario io-pressure --param scratchMb=2048
```
