# Cosmos DB for NoSQL data model (T5)

The `contosocare` database on T5, the Azure Cosmos DB for NoSQL account `cosmos01-<deploymentId>`. Unlike the other targets, T5 has no scripts: the template creates the database and its container, and the runner's REST client ([workload generator](../../workload-generator/README.md#t5-azure-cosmos-db-for-nosql)) writes the documents. There are no stored procedures, triggers, or user-defined functions, and no control tables: T5's runs are recorded on T1, in `t5-runs.json`.

| Resource | Settings |
|---|---|
| Database `contosocare` | Created by the template. |
| Container `patient-events` | Partition key `/patientId` (Hash, version 2); 400 RU/s of manual throughput on the container; no default time to live; every path indexed except `/payload/*` and `/"_etag"/?`. |

- **Only during a session:** to cut T5's idle cost, the container exists only during a session: a session's start creates it through Azure Resource Manager (`./scripts/start-demo.ps1` or the control notebook's **Run all**; the runner can't, with data-plane access) and its end deletes it with its documents, while the account and the database stay. While it's missing, the runner refuses runs with that reason and the profile host tries them again every 30 seconds, so the baseline starts once the container exists; `reset` and ru-storm's cleanup find no storm document to delete (a **Pass**), `status` says so without an error, and `warmup` and `setup`'s container check fail with that reason ([workload generator](../../workload-generator/README.md#t5-azure-cosmos-db-for-nosql)).
- **Access:** local (key) authentication is off, so there's no key to store or leak. T1's system-assigned managed identity has the **Cosmos DB Built-in Data Contributor** data-plane role on the account, which the template assigns when `deploy.ps1` runs it; a new assignment can take a few minutes to take effect, and until then the runner's requests get HTTP 403, which it reports as a refusal the profile host tries again ([data-plane access](https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access)).
- **Network:** HTTPS on port 443 to the account's gateway, the only port T1's network security group lets out: through a private endpoint in private mode, or a virtual network rule for T1's subnet in public mode.

## Documents

Every document keeps `id`, `patientId` (the partition key), `type`, `at` (an ISO 8601 UTC time), and `source` at the top level, where they're indexed. `source` is the tag of whatever wrote it: `ContosoCare.Demo/<scenario>/<run>` for a run, `ContosoCare.Demo/control/<command>` for setup and warmup, the same tag every request's User-Agent starts with. A document's bulk is one top-level string, `payload`, which the indexing policy leaves out, so its size changes what it costs to store and write, not its index.

| Document | `id` | `patientId` | `type` | Also | Size | Written by |
|---|---|---|---|---|---|---|
| Patient profile | `patient` | `p-0001` to `p-5000` | `patient` | `facility`, `ward`, `status` | about 0.8 KB | `setup --target T5 --seed-scale <n>` for `n` x 100 patients; `healthy-baseline` rewrites those of `p-0001` to `p-0500` |
| Baseline event | `hb-ev-0` to `hb-ev-19` | `p-0001` to `p-0500` | `vitals`, `medication`, `lab-result`, `nursing-note`, `bed-move` | `sequence` | 0.7 to 0.9 KB | `healthy-baseline` |
| Storm reading | `storm-01-000` to `storm-01-099` in `p-storm-01`, up to `storm-04-099` in `p-storm-04` | `p-storm-01` to `p-storm-04` | `monitor-reading` | `kind: "ru-storm"`, `device`, `sequence` | about `documentKb` KB, 1 to 16 | `ru-storm`, which deletes them when it ends |
| Warmup | `warmup` | `p-warmup` | `warmup` | | about 0.2 KB | `warmup --target T5` |

## Bounded by design

- **Fixed IDs:** every write is an upsert to an ID from a fixed set, so nothing grows from run to run or from session to session, and no delete is needed to keep it that way. The most there can be: 5,000 patient profiles (4 MB at scale 50), 10,000 baseline events (about 9 MB), 400 storm readings (6.4 MB of 16 KB documents, and only while a storm runs), and the warmup document. About 20 MB in all.
- **ru-storm cleans up after itself:** however a run ends (its deadline, a stop, Ctrl+C, or the profile host stopping), it deletes its storm readings before it records its end: a single-partition query in each of `p-storm-01` to `p-storm-04` for `kind` `ru-storm`, then a Delete Document request for each, paced by each request's charge to 200 RU/s, half the container's throughput. With the default parameters that's 100 documents of 2 KB and a few seconds; the most a run can write, 400 documents of 16 KB, takes well under a minute. The cleanup stops after 2 minutes, or 20 seconds when the run's caller is stopping.
- **Leftovers are removed:** when T1 stopped mid-storm (deallocated, for example), the profile host that starts next ends the run its predecessor left Running and deletes its storm readings the same way. `reset --target T5` deletes any storm reading left behind, and nothing else; with nothing left, it costs four small queries, so it's safe to repeat. The next ru-storm run's cleanup deletes leftovers too.
- **The baseline's documents stay during a session:** `healthy-baseline` and setup only rewrite their own fixed sets; nothing deletes them until the session's end deletes the container with them.

## Monitoring

Database Hub shows T5's Azure Monitor metrics: **Normalized RU Consumption** (the busiest partition range's share of its throughput, each minute), **Total Requests** split by status code (429 is a throttled request), and availability ([normalized RU consumption](https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units), [request rate too large](https://learn.microsoft.com/azure/cosmos-db/nosql/troubleshoot-request-rate-too-large)). `ContosoCare.Workload status --target T5` shows the requests, request units, and 429s per second that its runs measure.

## Testing locally

`CosmosClientTests`, `CosmosRunStoreTests`, and `CosmosRunnerTests` (in `workload-generator/tests`) run the REST client, the run store, reset, and both scenarios against a fake account, an `HttpMessageHandler` that keeps documents in memory, on an accelerated clock. No Cosmos DB account or emulator is needed or used.

## Sources (checked 2026-11-18)

- Azure Cosmos DB REST API: <https://learn.microsoft.com/rest/api/cosmos-db/>
- Access control with Microsoft Entra tokens: <https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources>
- Data-plane role-based access control: <https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access>
- Indexing policies: <https://learn.microsoft.com/azure/cosmos-db/index-policy>
- Request units: <https://learn.microsoft.com/azure/cosmos-db/request-units>
- HTTP status codes (404, and substatus 1013 while a container's creation is in progress): <https://learn.microsoft.com/rest/api/cosmos-db/http-status-codes-for-cosmosdb>
- Not found, after a container or database was deleted: <https://learn.microsoft.com/azure/cosmos-db/troubleshoot-not-found>
