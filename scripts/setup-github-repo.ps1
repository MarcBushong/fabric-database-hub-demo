#Requires -Version 7.4
<#
.SYNOPSIS
Applies the public repository's GitHub settings, after the repository is public (ADR 0022): a ruleset on the
default branch, secret scanning with push protection, private vulnerability reporting, Dependabot alerts, and
with -Template, the template flag. Opt-in; run it with -WhatIf first.

.DESCRIPTION
Uses the GitHub CLI as the account gh is signed in with (run 'gh auth login' first; the script never signs in), and
needs an administrator of the repository. It makes no Azure call and never changes the repository's visibility.
Each setting is read first and reported with the ADR 0012 statuses:
- REPO.RULESET: "Protect the default branch": changes through a pull request (0 required approvals, so a solo
  owner can merge their own pull request), no force-push, no deletion, and no bypass actors.
- REPO.SECRETSCANNING and REPO.PUSHPROTECTION: GitHub secret scanning, and push protection, which refuses a push
  that contains a known secret format.
- REPO.VULNERABILITYREPORTING: private vulnerability reporting (SECURITY.md's "Report a vulnerability").
- REPO.DEPENDABOTALERTS: Dependabot alerts.
- REPO.TEMPLATE: with -Template, a template repository ("Use this template" starts a copy with one fresh commit).
On a private repository, GitHub refuses several of these on GitHub Free, Pro, and Team (HTTP 403): each is reported
as Manual action required, to run again once the repository is public.

.PARAMETER Repository
owner/repo; defaults to github.repository in the configuration.

.PARAMETER ConfigPath
Demo configuration, read only for github.repository when -Repository isn't given (default: config/demo.config.json).

.PARAMETER Template
Also mark the repository as a template repository.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/setup-github-repo.ps1 -Repository contoso/fabric-database-hub-demo -Template -WhatIf

.EXAMPLE
./scripts/setup-github-repo.ps1 -Template
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = '',

    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [switch] $Template,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/setup-github-repo.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

if (-not $Repository -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $config = Get-DemoConfig -Path $ConfigPath
    $Repository = [string](& (Get-Module -Name 'DbHubDemo') { param($Value) Get-DemoMemberValue -InputObject $Value -Name 'repository' } $config['github'])
}
$results = if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Repository -like 'your-org/*') {
    @(New-DemoResult -CheckId 'REPO.GITHUB' -Area 'security' -Target 'repo' -Status 'Fail' -Message 'No GitHub repository: pass -Repository owner/repo, or set github.repository in the configuration.')
}
else {
    @(Initialize-DemoGitHubRepository -Repository $Repository -Template:$Template -WhatIf:([bool]$WhatIfPreference) -Confirm:$false)
}

Write-DemoResultReport -Result $results -Title 'setup-github-repo.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
