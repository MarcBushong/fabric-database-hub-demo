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
destroy.ps1 -ResidueOnly runs the same check with the demo's status model instead of Pester's pass or fail. Only
this environment counts (Phase 28 follow-up): its resource group by name and its deploymentId, never another
prefix's environment with the same environment name. A Warning the check can't settle yet (Resource Graph rows that
Azure Resource Manager didn't confirm, or no deploymentId) is inconclusive here, not a failure.

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
            # The default path is shared by every subscription with this environment name (Phase 28 follow-up review).
            $property = $manifest.PSObject.Properties['SubscriptionId']
            $recordedSubscription = if ($null -ne $property) { ([string]$property.Value).Trim() } else { '' }
            if ($recordedSubscription -and $recordedSubscription -ne [string]$config['subscriptionId']) {
                throw ('The manifest is of another subscription than the configured one; pass the manifest of this environment''s destroy.')
            }
        }
        $script:residue = @{}
        $script:hasManifest = $null -ne $manifest
        foreach ($item in @(Test-DemoTeardownResidue -Config $config -Manifest $manifest -WaitMinutes $WaitMinutes)) {
            $script:residue[[string]$item.checkId] = $item
        }
        # A Warning these tests can't settle (Phase 28 follow-up): rows Resource Graph still lists that Azure Resource
        # Manager didn't confirm within the check's bound of reads, or a tag check without the manifest's deploymentId.
        # Inconclusive, not failed: running the check again later settles it.
        $script:assertClean = {
            param([string] $CheckId)
            $result = $script:residue[$CheckId]
            $evidence = $result.evidence
            $unconfirmed = @(if ($evidence -is [System.Collections.IDictionary] -and $evidence.Contains('unconfirmed')) { $evidence['unconfirmed'] | Where-Object { $_ } })
            if ($result.status -eq 'Warning' -and ($unconfirmed.Count -gt 0 -or ($CheckId -eq 'TEARDOWN.RESIDUAL.TAGGED' -and -not $script:hasManifest))) {
                Set-ItResult -Inconclusive -Because $result.message
                return
            }
            $result.status | Should -Be 'Pass' -Because $result.message
        }
    }

    It 'the resource group is gone' {
        $script:residue['TEARDOWN.RESIDUAL.RESOURCEGROUP'].status | Should -Be 'Pass' -Because $script:residue['TEARDOWN.RESIDUAL.RESOURCEGROUP'].message
    }

    It 'nothing in the subscription carries the environment''s deploymentId, and its resource group isn''t listed' {
        # Only this environment: another prefix's environment with the same environment name isn't counted.
        & $script:assertClean 'TEARDOWN.RESIDUAL.TAGGED'
    }

    It 'Resource Graph lists nothing in the resource group that Azure Resource Manager still returns' {
        # Rows Resource Manager says are gone are index records (Pass, reported under RECORDS).
        & $script:assertClean 'TEARDOWN.RESIDUAL.GROUPRESOURCES'
    }

    It 'no Arc machine, machine extension, or SQL Server instance is left' {
        & $script:assertClean 'TEARDOWN.RESIDUAL.ARC'
    }

    It 'no role assignment is left at the group or for its identities in the demo''s groups' {
        # One a tenant policy gave a deleted identity outside the demo's groups is a Warning that names its scope; the
        # demo didn't create it, and an Owner or User Access Administrator removes it.
        $result = $script:residue['TEARDOWN.RESIDUAL.ROLEASSIGNMENTS']
        if ($result.status -eq 'Warning' -and $result.evidence.Contains('orphaned')) {
            @($result.evidence['orphaned']).Count | Should -BeGreaterThan 0 -Because $result.message
            @($result.evidence['remaining'] | Where-Object { $_ }).Count | Should -Be 0 -Because $result.message
            return
        }
        $result.status | Should -Be 'Pass' -Because $result.message
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

    It 'only records remain in Defender for Cloud, Azure Policy, guest configuration, and Resource Graph''s index, nothing billable' {
        # Records about deleted resources aren't resources and age out: Pass either way; Warning when unreadable.
        $script:residue['TEARDOWN.RESIDUAL.RECORDS'].status | Should -BeIn @('Pass', 'Warning') -Because $script:residue['TEARDOWN.RESIDUAL.RECORDS'].message
    }

    It 'no Key Vault is left, other than the opt-in vault''s documented soft delete' {
        $script:residue['TEARDOWN.RESIDUAL.KEYVAULT'].status | Should -BeIn @('Pass', 'Not selected', 'Warning') -Because $script:residue['TEARDOWN.RESIDUAL.KEYVAULT'].message
    }
}
