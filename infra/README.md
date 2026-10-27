# Infrastructure as code

Bicep templates for the demo ([ADR 0001](../docs/adr/0001-iac-bicep-avm-compiled-arm.md), [ADR 0002](../docs/adr/0002-resource-group-topology.md)).

- `main.bicep`: subscription scope; creates the demo resource group and deploys `modules/demo.bicep` into it.
- `main.bicepparam`: defaults for the `lowest-cost` profile, with no secrets.
- `modules/`: network and NSGs, budget, the T1 VM, the T2 host, and the bootstrap Run Commands. See [modules/README.md](modules/README.md). The artifact cache (a storage account) was dropped on 2026-10-20; see [ADR 0016](../docs/adr/0016-cost-profiles.md), C9.

**Secure parameters.** `adminPassword` is the only one. It's needed only when a VM is created; `deploy.ps1` generates one, passes it once, and lists existing VMs in `existingVmNames` so their `osProfile` is left out on re-runs ([ADR 0009](../docs/adr/0009-secrets-handling.md)).

**Bootstrap.** `deploy.ps1` deploys the VMs, sends the bootstrap bundle to each one in Run Command chunks (`Send-DemoBootstrapBundle`), then deploys again with `bootstrapBundleSha256` and `bootstrapChunkCount`, which adds the loader Run Command `DbHubDemo-Bootstrap`. When `bootstrapBundleSha256` is empty, as on the Deploy to Azure button path, no bootstrap Run Command is deployed ([ADR 0003](../docs/adr/0003-t2-host-size-security-type-bootstrap.md)).

**Data disks.** `dataDiskSku` `Auto` lets the profile decide: `lowest-cost` has none, and the other profiles have one 128 GiB disk per VM at LUN 0 ([ADR 0016](../docs/adr/0016-cost-profiles.md)).

`azuredeploy.json` at the repo root is compiled from `main.bicep` with the Bicep version pinned in `config/versions.json`. CI fails when it's out of sync. `azuredeploy.parameters.json` holds non-secret defaults only.
