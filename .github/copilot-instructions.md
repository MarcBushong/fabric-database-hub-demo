# Copilot instructions for this repository

This repo deploys a low-cost, repeatable customer demo of **Microsoft Fabric Database Hub (preview)** and its in-Hub **Database Agent (preview)** across three SQL targets: T1 SQL Server on an Azure VM, T2 Arc-enabled SQL Server in a nested Hyper-V guest, and T3 Azure SQL Database. Read `docs/architecture.md` and the ADRs in `docs/adr/` before you change behavior.

## Non-negotiable rules

- **No secrets anywhere:** not in Git, ARM outputs, logs, notebook outputs, docs, or test fixtures. Build fake tokens at run time in tests so scanners don't flag them. Log only through `Write-DemoLog`, which redacts.
- **Subscription guard:** every Azure CLI call goes through `Invoke-DemoAz`, which adds `--subscription`. Scripts call `Assert-DemoAzContext` before any Azure work and never start an interactive sign-in (`az login`) or change the CLI context (`az account set`).
- **Documented interfaces only:** never call private Database Hub routes, scrape or automate the portal, or treat a preview UI as an ARM resource. Cite the Microsoft Learn page for every API, CLI command, or setting you rely on.
- **Contributor is the minimum:** the default path creates no role assignments and no Key Vault (ADR 0008, ADR 0009). Anything needing more is optional and gated by `assignRoles`.
- **Status model:** report checks with `New-DemoResult` using exactly Pass, Fail, Warning, Manual action required, Not supported, or Not selected (ADR 0012). Deployment success alone is never Pass.
- **Bounded workloads:** scenarios have hard maximum durations, act only inside the `ContosoCare` database, and touch only sessions tagged `ContosoCare.Demo/` (ADR 0010).
- **No hard-coded prices:** cost figures come from the Azure Retail Prices API at run time, or are labeled as dated examples (ADR 0016).

## Conventions

- PowerShell: operator scripts target PowerShell 7.4; VM-side scripts target Windows PowerShell 5.1. PowerShell files are ASCII-only. Use full cmdlet and parameter names.
- Bicep: subscription-scope `infra/main.bicep`; regenerate `azuredeploy.json` with the Bicep version pinned in `config/versions.json`.
- Pin every version in `config/versions.json` and every GitHub Action by full commit SHA.
- Run `./tests/Invoke-StaticValidation.ps1` before you open a pull request.
- One pull request per implementation phase; record work summary, changed files, validation results, and risks in `docs/implementation-report.md`.
