# Bicep modules

One module per concern, deployed by `../main.bicep` (ADR 0001).

| Module | Contents | Phase |
|---|---|---|
| `demo.bicep` | Resource-group scope entry point called by `main.bicep`; picks sizes and disk tiers from `config/profiles.json` | 5, 6 |
| `network.bicep` | VNet, subnets, four NSGs (ADR 0007), outbound mode and optional NAT gateway (ADR 0017) | 5 |
| `budget.bicep` | Azure budget with alerts at 50, 80, and 100 percent (ADR 0016, C2) | 5 |
| `windows-vm.bicep` | Shared Windows VM: NIC without a public IP, system identity, OS disk, an optional data disk at LUN 0 (none for tier `None`; Premium SSD v2 only in a zone), Spot option, security type, boot diagnostics, and the DevTest Labs auto-shutdown schedule. Leaves out `osProfile` for an existing VM. | 6 |
| `sqlvm01.bicep` | T1 from `MicrosoftSQLServer:sql2022-ws2022:standard-gen2`, plus the SQL IaaS Agent registration (`sqlVirtualMachines`, PAYG or AHUB, connectivity `LOCAL`) | 6 |
| `archost01.bicep` | T2 host from Windows Server 2022 Datacenter Gen2, `securityType` `Standard` by default (ADR 0003). With `assignArcOnboardingRole`, also the user-assigned identity `id-<prefix>-<env>-arc-onboard`, its Azure Connected Machine Onboarding assignment on the resource group, and its attachment to the host (ADR 0005) | 6, 7 |
| `arcsql01-eval.bicep` | **Evaluation only** (`t2Mode = EvaluationOnlyAzureVm`): `arcsql01` as an Azure VM from the plain Windows Server 2022 image, with no SQL IaaS Agent registration and no data disk, tagged `evaluationOnly` (ADR 0006). Deployed instead of `archost01` | 7 |
| `bootstrap.bicep` | The managed Run Command `DbHubDemo-Bootstrap` on each VM, which runs the loader with the bundle's SHA-256 and chunk count. Deployed only after `Send-DemoBootstrapBundle` has delivered the bundle in Run Command chunks (ADR 0003) | 6 |
| `azuresql01.bicep` | T3: the logical server `azuresql01-<deploymentId>` (Entra-only, the P6 group as administrator, TLS 1.2) and `ContosoCare` (General Purpose serverless, the free offer when `t3UseFreeLimit`), with a private endpoint and the `privatelink` DNS zone in private mode or a VNet rule for `snet-sqlvm` in public mode (ADR 0007) | 8 |

Resource-group tags are set in `main.bicep` (ADR 0002). Azure Verified Module versions and resource API versions are listed in `config/versions.json`, and Pester tests keep them in sync.
