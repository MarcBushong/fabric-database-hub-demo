#Requires -Version 7.4
<#
.SYNOPSIS
Installs the pinned PowerShell validation modules listed in config/versions.json.

.DESCRIPTION
Installs Pester and PSScriptAnalyzer (and optionally PSRule with PSRule.Rules.Azure) for the current
user from the PowerShell Gallery, at the exact versions recorded in config/versions.json. Modules that
are already installed at those versions are skipped.

.PARAMETER IncludePSRule
Also install PSRule and PSRule.Rules.Azure, which validate the Bicep templates.

.EXAMPLE
./tests/Install-TestTools.ps1
#>
[CmdletBinding()]
param(
    [switch] $IncludePSRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$versionsPath = Join-Path -Path $PSScriptRoot -ChildPath '../config/versions.json'
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json

$modules = [ordered]@{
    'Pester'           = $versions.tools.pester
    'PSScriptAnalyzer' = $versions.tools.psscriptanalyzer
}
if ($IncludePSRule) {
    $modules['PSRule'] = $versions.tools.psrule
    $modules['PSRule.Rules.Azure'] = $versions.tools.psruleRulesAzure
}

foreach ($name in $modules.Keys) {
    $version = $modules[$name]
    $installed = Get-InstalledPSResource -Name $name -Version $version -ErrorAction SilentlyContinue
    if ($installed) {
        Write-Output "$name $version is already installed."
        continue
    }

    Install-PSResource -Name $name -Version $version -Scope CurrentUser -Repository PSGallery -TrustRepository -Quiet
    Write-Output "Installed $name $version."
}
