#Requires -Version 7.4
<#
.SYNOPSIS
Live teardown tests (Phase 16, ADR 0002): after destroy.ps1, nothing of the environment is left, Arc
resources included.

.DESCRIPTION
Opt-in and read-only. They run only when -Live is passed (or DBHUB_TEARDOWN_TESTS is 'true') and a
configuration path is given (-ConfigPath or DBHUB_TEARDOWN_CONFIG); otherwise every test is skipped, so the
static run never touches Azure. They never delete anything: run destroy.ps1 first, or use
Invoke-TeardownTest.ps1 -Destroy. The manifest that destroy.ps1 writes (out/destroy-manifest-<environment>.json)
carries the deploymentId and the identities that can't be found once the resource group is gone.

.PARAMETER ConfigPath
The destroyed environment's configuration.

.PARAMETER ManifestPath
The manifest destroy.ps1 wrote before it deleted anything (default: out/destroy-manifest-<environment>.json).

.PARAMETER Live
Run the tests (also DBHUB_TEARDOWN_TESTS = 'true').

.PARAMETER WaitMinutes
How long the residual check waits for Azure Resource Graph and Microsoft Entra to catch up.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester passes the parameters to BeforeDiscovery and BeforeAll, which the analyzer can''t follow.')]
param(
    [string] $ConfigPath = $env:DBHUB_TEARDOWN_CONFIG,

    [string] $ManifestPath = $env:DBHUB_TEARDOWN_MANIFEST,

    [switch] $Live,

    [int] $WaitMinutes = 5
)

BeforeDiscovery {
    $script:runLive = ($Live -or $env:DBHUB_TEARDOWN_TESTS -eq 'true') -and -not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)
}

Describe 'Teardown residue (live, opt-in)' -Tag 'Teardown', 'Live' -Skip:(-not $script:runLive) {
    BeforeAll {
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
        Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
        $config = Get-DemoConfig -Path $ConfigPath
        $null = Assert-DemoAzContext -SubscriptionId ([string]$config['subscriptionId']) -TenantId ([string]$config['tenantId']) -Account ([string]$config['azureAccount'])
        if (-not $ManifestPath) {
            $ManifestPath = Join-Path -Path $repoRoot -ChildPath ('out/destroy-manifest-{0}.json' -f $config['environment'])
        }
        $manifest = $null
        if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 10
            $expected = 'rg-{0}-{1}' -f $config['prefix'], $config['environment']
            if ([string]$manifest.ResourceGroupName -ne $expected) {
                throw ('The manifest is for {0}, not {1}; pass the manifest of this environment''s destroy.' -f $manifest.ResourceGroupName, $expected)
            }
        }
        $script:residue = @{}
        foreach ($item in @(Test-DemoTeardownResidue -Config $config -Manifest $manifest -WaitMinutes $WaitMinutes)) {
            $script:residue[[string]$item.checkId] = $item
        }
    }

    It 'the resource group is gone' {
        $script:residue['TEARDOWN.RESIDUAL.RESOURCEGROUP'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.RESOURCEGROUP'].message
    }

    It 'nothing in the subscription carries the environment''s tags' {
        $script:residue['TEARDOWN.RESIDUAL.TAGGED'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.TAGGED'].message
    }

    It 'Resource Graph lists nothing in the resource group' {
        $script:residue['TEARDOWN.RESIDUAL.GROUPRESOURCES'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.GROUPRESOURCES'].message
    }

    It 'no Arc machine, machine extension, or SQL Server instance is left' {
        $script:residue['TEARDOWN.RESIDUAL.ARC'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.ARC'].message
    }

    It 'no role assignment is left at the group or for its identities' {
        $script:residue['TEARDOWN.RESIDUAL.ROLEASSIGNMENTS'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.ROLEASSIGNMENTS'].message
    }

    It 'the managed identities and their P6 group membership are gone' {
        $script:residue['TEARDOWN.RESIDUAL.IDENTITIES'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.IDENTITIES'].message
    }

    It 'no subscription deployment record is left' {
        $script:residue['TEARDOWN.RESIDUAL.DEPLOYMENTS'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.DEPLOYMENTS'].message
    }

    It 'the budget is gone' {
        $script:residue['TEARDOWN.RESIDUAL.BUDGET'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.BUDGET'].message
    }

    It 'nothing outside the group still names it' {
        $script:residue['TEARDOWN.RESIDUAL.REFERENCES'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.REFERENCES'].message
    }

    It 'only records remain in Defender for Cloud, Azure Policy, and guest configuration, nothing billable' {
        # Records about deleted resources aren't resources and age out: Pass either way; Warning when unreadable.
        $script:residue['TEARDOWN.RESIDUAL.RECORDS'].status | Should -BeIn @('Pass', 'Warning') -Because $script:residue['TEARDOWN.RESIDUAL.RECORDS'].message
    }

    It 'no Key Vault is left, other than the opt-in vault''s documented soft delete' {
        $script:residue['TEARDOWN.RESIDUAL.KEYVAULT'].status | Should -BeIn @('Pass', 'Not selected', 'Warning') -Because $script:residue['TEARDOWN.RESIDUAL.KEYVAULT'].message
    }
}
