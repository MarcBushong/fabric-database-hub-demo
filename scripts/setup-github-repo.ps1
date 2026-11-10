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
# This checkout's DbHubDemo, loaded again on every run, so a session that ran an earlier checkout's script doesn't keep
# that code (live finding, 2026-11-06). Not when the repository's own code runs this script (a DbHubDemo function,
# another script, or a test): it loaded the module already, and the module's state stays, such as the subscription
# guard's validated context, the redaction's registered values, or a test's mocks. $module is the module object this
# script imported, for the code that runs in its scope (& $module { ... }): a session that ran other checkouts' scripts
# has their DbHubDemo loaded too, so Get-Module -Name 'DbHubDemo' returns every copy (live finding, 2026-11-10).
$entryRepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$entryNested = $false
foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {
    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))
}
$module = Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1') -Force:(-not $entryNested) -PassThru
# Paths relative to PowerShell's current location, which .NET file calls don't follow (Resolve-DemoUserPath).
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

if (-not $Repository -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $config = Get-DemoConfig -Path $ConfigPath
    $Repository = [string](& $module { param($Value) Get-DemoMemberValue -InputObject $Value -Name 'repository' } $config['github'])
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
