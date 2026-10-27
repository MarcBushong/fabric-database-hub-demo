#Requires -Version 7.4
<#
.SYNOPSIS
Runs the live teardown tests (Phase 16): optionally destroy.ps1 first, then tests/teardown/*.Tests.ps1
against the destroyed environment.

.DESCRIPTION
Opt-in. Without -Destroy it only reads (the residual check). With -Destroy it first runs destroy.ps1 -Force
for the configured environment, which deletes it, so it needs -ConfirmEnvironment with the environment's
name. The shared demo environment (environment 'demo', rg-<prefix>-demo) and any PaygWizard environment hold
work that can't be rebuilt automatically (the setup-wizard step), so -Destroy refuses them unless
-IncludeDemoEnvironment says the owner approved it (docs/cleanup.md). It never signs in.

.PARAMETER ConfigPath
The environment's configuration.

.PARAMETER Destroy
Run destroy.ps1 -Force before the tests.

.PARAMETER ConfirmEnvironment
With -Destroy: the configuration's environment name, typed again.

.PARAMETER IncludeDemoEnvironment
With -Destroy: allow environment 'demo' or a PaygWizard environment. Only with the owner's explicit
go-ahead.

.PARAMETER ManifestPath
Where destroy.ps1 writes, and the tests read, the manifest (default: out/destroy-manifest-<environment>.json).

.PARAMETER WaitMinutes
How long the residual check waits for Azure Resource Graph and Microsoft Entra to catch up.

.PARAMETER OutputPath
Where to write the destroy results as JSON lines.

.EXAMPLE
./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath ./out/demo.config.test.json

.EXAMPLE
./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath ./out/demo.config.test.json -Destroy -ConfirmEnvironment test
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigPath,

    [switch] $Destroy,

    [string] $ConfirmEnvironment = '',

    [switch] $IncludeDemoEnvironment,

    [string] $ManifestPath = '',

    [ValidateRange(0, 120)]
    [int] $WaitMinutes = 5,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../out/teardown-destroy.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
$config = Get-DemoConfig -Path $ConfigPath
$environment = [string]$config['environment']
if (-not $ManifestPath) {
    $ManifestPath = Join-Path -Path $repoRoot -ChildPath ('out/destroy-manifest-{0}.json' -f $environment)
}

if ($Destroy) {
    if ($ConfirmEnvironment -ne $environment) {
        throw ('-Destroy deletes rg-{0}-{1}; pass -ConfirmEnvironment {1} to confirm.' -f $config['prefix'], $environment)
    }
    if (($environment -eq 'demo' -or [string]$config['t2SqlInstallMode'] -eq 'PaygWizard') -and -not $IncludeDemoEnvironment) {
        throw ('{0} holds the owner''s setup-wizard work (environment demo or t2SqlInstallMode PaygWizard); destroying it needs the owner''s explicit go-ahead and -IncludeDemoEnvironment (docs/cleanup.md).' -f ('rg-{0}-{1}' -f $config['prefix'], $environment))
    }
    & (Join-Path -Path $repoRoot -ChildPath 'scripts/destroy.ps1') -ConfigPath $ConfigPath -Force -ManifestPath $ManifestPath -OutputPath $OutputPath
    Write-DemoLog -Message ('destroy.ps1 exited with {0}; running the teardown tests.' -f $LASTEXITCODE)
}

$versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json
Import-Module -Name Pester -RequiredVersion $versions.tools.pester
$container = New-PesterContainer -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Teardown.Residue.Tests.ps1') -Data @{
    ConfigPath   = (Resolve-Path -LiteralPath $ConfigPath).Path
    ManifestPath = $ManifestPath
    Live         = $true
    WaitMinutes  = $WaitMinutes
}
$configuration = New-PesterConfiguration
$configuration.Run.Container = $container
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$run = Invoke-Pester -Configuration $configuration
exit $(if ($run.Result -eq 'Passed') { 0 } else { 1 })
