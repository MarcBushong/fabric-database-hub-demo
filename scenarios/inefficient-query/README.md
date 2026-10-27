# Inefficient query

A frequent front-desk lookup by the numeric part of the MRN, for Query Store before-and-after comparisons. Default targets T2 and T3; runs on any target. Log-rate pressure on Azure SQL Database, which this folder's first description also mentioned, is its own scenario: [log-rate-pressure](../log-rate-pressure/README.md).

- **Definition:** [`scenario.json`](scenario.json) (10 minutes by default, 30 at most; 4 sessions; back to back at intensity 10).
- **Problem:** `RIGHT(p.mrn, 7) = @digits` hides the indexed column from `uq_patients_mrn`, so every call scans `care.patients`: modest per call, expensive in total because it runs constantly.
- **Healthy:** `--param variant=healthy` compares the full MRN and seeks.
- **Expected signals:** CPU and `Batch Requests/sec` above the baseline, many short requests, and an inefficient-query finding that names the non-SARGable predicate.
- **Reset:** read-only.

```powershell
ContosoCare.Workload run --target T3 --server <logical server> --scenario inefficient-query
ContosoCare.Workload run --target T3 --server <logical server> --scenario inefficient-query --param variant=healthy
```
