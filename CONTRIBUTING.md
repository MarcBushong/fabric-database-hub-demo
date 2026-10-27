# Contributing

Thanks for helping improve the Fabric Database Hub hybrid SQL demo. Read [docs/architecture.md](docs/architecture.md) and the [ADRs](docs/adr/README.md) first, and follow the [code of conduct](CODE_OF_CONDUCT.md).

- **Questions and bugs:** open an issue with one of the templates; the **Deployment problem** template asks for status.ps1's output with your IDs replaced. For a larger change, open an issue first, so we can agree on the approach.
- **Security problems:** report them privately, as [SECURITY.md](SECURITY.md) describes, never in an issue.

## Tooling

The fastest path is the devcontainer (`.devcontainer/devcontainer.json`), which installs everything below. To set up a machine yourself, install:

- PowerShell 7.4 or later
- Azure CLI with Bicep
- .NET 10 SDK
- Node.js (for markdownlint)
- Python 3 and `pre-commit`

Then install the pinned PowerShell modules and the Git hooks:

```powershell
./tests/Install-TestTools.ps1 -IncludePSRule
pre-commit install
```

## Validate before you open a pull request

```powershell
./tests/Invoke-StaticValidation.ps1
```

It runs PSScriptAnalyzer, Pester, the Bicep build and `azuredeploy.json` sync check, PSRule for Azure, the workload generator's build and tests, the Fabric App's checks (when Node.js is installed), and markdownlint, and reports each check as **Pass**, **Fail**, or **Not selected**. It makes no Azure calls. CI runs the same checks, plus actionlint and gitleaks.

- **A faster loop:** pick checks with `-Check`, for example `./tests/Invoke-StaticValidation.ps1 -Check PSScriptAnalyzer, Pester`, or run one test file with `Invoke-Pester -Path tests/unit/<file>.Tests.ps1`. Run the whole validation once before you open the pull request.
- **Secrets and workflows:** the pre-commit hook runs gitleaks; to run it and actionlint yourself, use the versions pinned in `config/versions.json` (`gitleaks git --redact .` and `actionlint`).
- **What a pull request runs:** `validate.yml` runs the static checks on every pull request, from a fork too, with a read-only token and no secrets. The live workflows (deploy, destroy, demo-control, warm-up, and the schedules) never run on a pull request: they run only by hand or on a schedule, in a GitHub environment that a maintainer approves ([ADR 0022](docs/adr/0022-public-repository-and-github-actions-hardening.md)).

## Rules

These are the repository's non-negotiable rules (`.github/copilot-instructions.md`); a pull request that breaks one isn't merged.

- **No secrets or real IDs:** not in Git, ARM outputs, logs, notebook outputs, docs, test fixtures, issues, or pull request text. Use obviously fake values (for example `11111111-2222-3333-4444-555555555555`), and build fake tokens at run time in tests, so scanners don't flag them. Log only through `Write-DemoLog`, which redacts, and in GitHub Actions also masks identifiers.
- **Subscription guard:** call Azure only through `Invoke-DemoAz`, which adds `--subscription`, after `Assert-DemoAzContext`. Never add `az login`, `az logout`, or `az account set` to scripts.
- **Documented interfaces only:** never call private Database Hub routes, scrape or automate the portal, or treat a preview UI as an ARM resource. Cite the Microsoft Learn page (or GitHub Docs, for GitHub settings) for every API, CLI command, or setting you rely on.
- **Contributor is the minimum:** the default path creates no role assignments and no Key Vault ([ADR 0008](docs/adr/0008-identity-rbac-abac.md), [ADR 0009](docs/adr/0009-secrets-handling.md)). Anything that needs more is optional and gated by `assignRoles`.
- **Statuses:** report checks with `New-DemoResult` and exactly the six statuses in [ADR 0012](docs/adr/0012-validation-model.md): Pass, Fail, Warning, Manual action required, Not supported, and Not selected. A successful deployment alone is never Pass.
- **Bounded workloads:** scenarios have hard maximum durations, act only inside the `ContosoCare` database, and touch only sessions tagged `ContosoCare.Demo/` ([ADR 0010](docs/adr/0010-workload-generator-technology.md)).
- **No hard-coded prices:** cost figures come from the Azure Retail Prices API at run time, or are labeled as dated examples ([ADR 0016](docs/adr/0016-cost-profiles.md)).
- **PowerShell:** ASCII-only files; full cmdlet and parameter names; operator scripts target PowerShell 7.4, and VM-side scripts target Windows PowerShell 5.1.
- **Bicep:** `infra/main.bicep` is subscription-scoped; regenerate `azuredeploy.json` with the Bicep version pinned in `config/versions.json`.
- **Versions:** record every pinned version in `config/versions.json`, and pin GitHub Actions by full commit SHA. Dependabot has no ecosystem for the Bicep registry, so review Azure Verified Module versions by hand once a month.
- **Workflows:** no `pull_request_target`; the smallest `permissions` each job needs; anything that reaches Azure runs only by hand or on a schedule, in a GitHub environment, and reads its identifiers from environment secrets ([ADR 0022](docs/adr/0022-public-repository-and-github-actions-hardening.md)).
- **Decisions:** a change to an accepted decision needs a new ADR that supersedes the old one.
- **Pull requests:** one per implementation phase or fix, using the pull request template. Record the work summary, changed files, validation results, and risks in `docs/implementation-report.md`.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `ci:`, `build:`, `chore:`), which the release tooling uses to build the changelog.
