# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for a security problem.

- Use GitHub's **private vulnerability reporting**: on the repository's **Security** tab, select **Report a vulnerability** ([how it works](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)). The maintainer turns it on with `./scripts/setup-github-repo.ps1` once the repository is public.
- If that button isn't there, contact the maintainer, [@MarcBushong](https://github.com/MarcBushong), through GitHub and ask for a private channel. Don't include the details in that first message.

Include what you found, how to reproduce it, and its impact. Never include real secrets, tokens, subscription IDs, tenant IDs, or object IDs: replace them with placeholders such as `<subscriptionId>`.

## Supported versions

Only the `main` branch is supported.

## Security model

- The threat model, trust boundaries, and residual risks are in [docs/security-model.md](docs/security-model.md).
- The permission model is in [docs/permissions.md](docs/permissions.md). The minimum is Contributor on the subscription, with no role assignments by default.
- Secrets handling is in [ADR 0009](docs/adr/0009-secrets-handling.md). The default deployment stores no secrets.
- The public repository's controls (fork safety, the GitHub environments, and the masked Actions logs) are in [ADR 0022](docs/adr/0022-public-repository-and-github-actions-hardening.md).

## A public repository

- **Actions logs and artifacts are public.** Anyone can read a public repository's workflow logs, and anyone signed in to GitHub can download its artifacts. So the live workflows read the subscription, tenant, and client IDs and the configuration (`DBHUB_CONFIG_JSON`) from **environment secrets**, which GitHub masks, and mask every identifier they derive from them with `::add-mask::` before anything is printed. In Actions, the scripts' log lines, the job summary, and the uploaded `out/*.jsonl` results show `***` instead of those identifiers and of any other GUID ([ADR 0022](docs/adr/0022-public-repository-and-github-actions-hardening.md)).
- **No secret is stored for Azure:** the workflows sign in with OpenID Connect. The environment secrets hold identifiers, not credentials; they're secrets only so that GitHub masks them. The federated credentials trust only this repository's named environments, so a fork or a pull request can't get an Azure token.
- **Pull requests from forks** run the static checks only, with a read-only token and no secrets. No workflow uses `pull_request_target`.
- **Before you share output** from your own deployment (an issue, a discussion, a screenshot), replace the subscription, tenant, object, and workspace IDs, the T3 and T4 server names' random suffix, and your account with placeholders.

## Scanning in this repository

- **Secret scanning:** gitleaks runs on every pull request (`.github/workflows/reusable-static-checks.yml`, job **Secret scan**) and as a pre-commit hook, with every default rule plus the JWT rule in `.gitleaks.toml`, whose one allowlist covers only the public commit SHA pins in `config/versions.json`. Once the repository is public, `./scripts/setup-github-repo.ps1` also turns on GitHub secret scanning and push protection.
- **Code scanning:** CodeQL (`.github/workflows/codeql.yml`) runs when the repository is public, or when the repository variable `CODE_SCANNING_ENABLED` is `true`. On a private repository, code scanning and GitHub secret scanning need GitHub Code Security or Secret Protection; without them, gitleaks and the other static checks are the fallback.
- **Run-time output:** `./scripts/validate.ps1 -Area Security` scans `out/`, the Run Command instance views on running VMs, and the ARM deployment history for secrets and token patterns. To scan anything else, such as a downloaded Actions log or an exported notebook, pass it with `-ScanPath`, or run `Find-DemoSecretLeak -Path <file or folder>` after importing the module. See [ADR 0009](docs/adr/0009-secrets-handling.md).
- **Dependencies:** Dependabot updates GitHub Actions, NuGet packages, the .NET SDK, container base images, and devcontainer features, and `./scripts/setup-github-repo.ps1` turns on Dependabot alerts. Every action is pinned by commit SHA.
