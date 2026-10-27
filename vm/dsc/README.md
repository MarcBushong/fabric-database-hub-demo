# Desired-state data

Declarative data files that describe the state the bootstrap state machines converge to ([ADR 0003](../../docs/adr/0003-t2-host-size-security-type-bootstrap.md)). They're plain PowerShell data files, read with `Import-PowerShellDataFile`; no DSC resources are compiled or applied.

| File | Read by | Contents |
|---|---|---|
| `host.psd1` | `Invoke-HostBootstrap.ps1` | Windows features (Hyper-V, DNS), the internal switch and NAT (`192.168.200.0/24`, host `192.168.200.1`), the DNS listen address and forwarder (`168.63.129.16`), the data-disk layout, the media pin names, and the Arc marker file name |
| `guest.psd1` | `Invoke-HostBootstrap.ps1` | The guest `arcsql01`: generation, image pattern (Datacenter with Desktop Experience), static address and DNS, the IMDS and wire-server addresses to block ([ADR 0004](../../docs/adr/0004-guest-imds-isolation.md)), and the SQL Server setup values |
| `sqlvm.psd1` | `Invoke-SqlVmBootstrap.ps1` | T1's data-disk layout, SQL Server service names, and the database name |

Values that vary by profile (guest vCPUs, memory, VHDX size, and seed scale) come from `settings.json`, which the template fills from `config/profiles.json`.

The repo doesn't use the Azure DSC extension or Azure Machine Configuration. Azure Automation State Configuration retires on 2027-09-30, and Machine Configuration needs packaging, hosting, and policy assignments that a one-time demo bootstrap doesn't justify. See ADR 0003.
