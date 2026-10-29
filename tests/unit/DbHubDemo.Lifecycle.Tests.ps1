BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    function New-TestConfig([switch] $WithT4) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        # T4 (Phase 24) has its own tests; the others keep their focus with T4 off.
        $config['t4Enabled'] = [bool]$WithT4
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass', [string] $Area = 'infra', [string] $Target = 'subscription') {
        New-DemoResult -CheckId $CheckId -Area $Area -Target $Target -Status $Status -Message ('{0}: {1}' -f $CheckId, $Status)
    }

    function New-TestState([hashtable] $Values = @{}) {
        $state = [ordered]@{
            Exists = $true; Stage = ''; StageUtc = ''; BundleSha256 = ''; BundleChunkCount = 0; RunnerSha256 = ''; RunnerChunkCount = 0
            BundleSentTo = @(); RunnerSentTo = @(); NetworkMode = 'private'; T3UseFreeLimit = $false; T3AdminGroupName = 'DbHub T3 Admins'
            BastionExpiresUtc = ''; HostPasswordUtc = ''; Tags = @{ deploymentId = 'abc123' }
        }
        foreach ($key in $Values.Keys) {
            $state[$key] = $Values[$key]
        }
        return [pscustomobject]$state
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    $script:sha = 'ab' * 32
    $script:runnerSha = 'cd' * 32
}

Describe 'Deployment state in the resource group''s tags' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:azCalls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $script:azCalls.Add(@($ArgumentList))
            if ($ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'exists') {
                return (New-AzResult -StdOut 'true')
            }
            if ($ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'show') {
                $tags = @{ deploymentId = 'abc123'; DbHubDeployStage = 'T3'; DbHubBundleSha256 = ('AB' * 32); DbHubBundleChunks = '1'; DbHubBundleSentTo = 'archost01,sqlvm01'; DbHubRunnerSentTo = 'sqlvm01'; DbHubT3FreeOffer = 'false'; DbHubHostPasswordUtc = '' }
                return (New-AzResult -StdOut (@{ name = 'rg-dbhub-demo'; tags = $tags } | ConvertTo-Json))
            }
            return (New-AzResult -StdOut '{}')
        }
    }

    It 'merges the values into the tags with az tag update, which Contributor can do' {
        Set-DemoDeploymentState -Config $config -Value @{ Stage = 'T3'; BundleSentTo = @('sqlvm01', 'archost01', 'sqlvm01'); T3UseFreeLimit = $false; BundleChunkCount = 1 } -Confirm:$false
        $call = @($script:azCalls | Where-Object { $_[0] -eq 'tag' })
        $call.Count | Should -Be 1
        $arguments = $call[0]
        ($arguments[0..1] -join ' ') | Should -Be 'tag update'
        $arguments | Should -Contain 'Merge'
        $arguments | Should -Contain '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo'
        $arguments | Should -Contain 'DbHubDeployStage=T3'
        $arguments | Should -Contain 'DbHubBundleSentTo=archost01,sqlvm01'
        $arguments | Should -Contain 'DbHubT3FreeOffer=false'
        $arguments | Should -Contain 'DbHubBundleChunks=1'
        @($arguments | Where-Object { $_ -like 'DbHubDeployStageUtc=*' }).Count | Should -Be 1
    }

    It 'refuses an unknown key, and leaves out a value a tag can''t carry safely' {
        { Set-DemoDeploymentState -Config $config -Value @{ Nope = 'x' } -Confirm:$false } | Should -Throw '*Nope*'
        Set-DemoDeploymentState -Config $config -Value @{ T3AdminGroupName = 'a"b' } -Confirm:$false
        @($script:azCalls | Where-Object { $_[0] -eq 'tag' }).Count | Should -Be 0
    }

    It 'reads the state back, with lists, counts, and an explicit false' {
        $state = Get-DemoDeploymentState -Config $config
        $state.Exists | Should -BeTrue
        $state.Stage | Should -Be 'T3'
        $state.BundleSha256 | Should -Be ('ab' * 32)
        $state.BundleChunkCount | Should -Be 1
        $state.BundleSentTo | Should -Be @('archost01', 'sqlvm01')
        $state.RunnerSentTo | Should -Be @('sqlvm01')
        $state.T3UseFreeLimit | Should -Be $false
        $state.HostPasswordUtc | Should -BeNullOrEmpty
    }

    It 'knows the stage order, and that a later stage means an earlier one finished' {
        $stages = & (Get-Module -Name DbHubDemo) { Get-DemoDeploymentStageName }
        $stages | Should -Be @('Preflight', 'Infrastructure', 'Artifacts', 'Bootstraps', 'T3', 'T4', 'Activity', 'Monitoring', 'T2', 'Fabric', 'Validation')
        & (Get-Module -Name DbHubDemo) { Test-DemoDeploymentStageReached -Recorded 'Fabric' -Stage 'T2' } | Should -BeTrue
        & (Get-Module -Name DbHubDemo) { Test-DemoDeploymentStageReached -Recorded 'Monitoring' -Stage 'T2' } | Should -BeFalse
        & (Get-Module -Name DbHubDemo) { Test-DemoDeploymentStageReached -Recorded '' -Stage 'T3' } | Should -BeFalse
    }
}

Describe 'Invoke-DemoTemplateDeployment' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:deployCalls = [System.Collections.Generic.List[object]]::new()
        $script:freeOfferFails = $false
        $script:existing = @('sqlvm01', 'archost01')
        $script:hostComputerName = "archost01`n"
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'abc123'; owner = 'your-alias' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoExistingVmName -MockWith { $script:existing }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBudgetStartDate -MockWith { '2026-10-01' }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT1SecurityType -MockWith { [pscustomobject]@{ SecurityType = 'TrustedLaunch' } }
        $script:drift = @()
        $script:t4State = 'NotFound'
        $script:t4Failure = $null
        $script:templateFails = $false
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { $script:drift }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = ($script:t4State -ne 'NotFound'); State = $script:t4State } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -MockWith { $script:t4Failure }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            @{
                '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                contentVersion = '1.0.0.0'
                parameters     = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit }; budgetStartDate = @{ value = $BudgetStartDate } }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            # The probe for a host restored from a golden disk, which has no osProfile (ADR 0018).
            if ($ArgumentList[0] -eq 'vm' -and $ArgumentList[1] -eq 'show') {
                return (New-AzResult -StdOut $script:hostComputerName)
            }
            $file = [string]$ArgumentList[[array]::IndexOf($ArgumentList, '--parameters') + 1]
            $content = Get-Content -LiteralPath $file.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
            $script:deployCalls.Add([pscustomobject]@{ Arguments = @($ArgumentList); Parameters = $content })
            if ($ArgumentList[2] -eq 'what-if') {
                return (New-AzResult -StdOut '{"changes":[{"changeType":"Modify"},{"changeType":"Modify"},{"changeType":"NoChange"}]}')
            }
            if ($script:freeOfferFails -and $content.parameters.t3UseFreeLimit.value) {
                return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (ProvisioningDisabled) The free offer is not available in region westus3 for this subscription.')
            }
            if ($script:templateFails) {
                return (New-AzResult -ExitCode 1 -StdErr 'ERROR: {"status":"Failed","error":{"code":"DeploymentFailed","message":"At least one resource deployment operation failed."}}')
            }
            return (New-AzResult -StdOut '{"properties":{"provisioningState":"Succeeded","duration":"PT3M","outputs":{"resourceGroupName":{"value":"rg-dbhub-demo"}}}}')
        }
    }

    It 'deploys at subscription scope from a private parameters file, keeping the budget''s start date' {
        $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $true
        $deployment.Succeeded | Should -BeTrue
        $deployment.Outputs['resourceGroupName'] | Should -Be 'rg-dbhub-demo'
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Pass'
        $script:deployCalls.Count | Should -Be 1
        $call = $script:deployCalls[0]
        ($call.Arguments[0..2] -join ' ') | Should -Be 'deployment sub create'
        $call.Arguments | Should -Contain 'dbhub-demo-main'
        $call.Parameters.parameters.budgetStartDate.value | Should -Be '2026-10-01'
        $call.Parameters.parameters.Contains('adminPassword') | Should -BeFalse -Because 'both VMs exist, so no password is generated'
    }

    It 'generates an administrator password only for a VM that doesn''t exist, and only in the file' {
        $script:existing = @()
        Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false | Out-Null
        $call = $script:deployCalls[0]
        $call.Parameters.parameters.adminPassword.value | Should -Not -BeNullOrEmpty
        ($call.Arguments -join ' ') | Should -Not -Match ([regex]::Escape([string]$call.Parameters.parameters.adminPassword.value))
    }

    It 'falls back to regular serverless when Azure rejects the free offer, with a Warning' {
        $script:freeOfferFails = $true
        $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $true
        $deployment.Succeeded | Should -BeTrue
        $deployment.T3UseFreeLimit | Should -BeFalse
        $script:deployCalls.Count | Should -Be 2
        $script:deployCalls[1].Parameters.parameters.t3UseFreeLimit.value | Should -BeFalse
        ($deployment.Results | Where-Object { $_.checkId -eq 'T3.FREEOFFER' }).status | Should -Be 'Warning'
    }

    It 'runs the what-if and counts the changes' {
        $deployment = Invoke-DemoTemplateDeployment -Config $config -Action WhatIf -NetworkMode public -T3UseFreeLimit $false
        $script:deployCalls[0].Arguments | Should -Contain 'what-if'
        $script:deployCalls[0].Arguments | Should -Contain '--no-pretty-print'
        $result = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE.WHATIF' }
        $result.message | Should -Match '2 Modify, 1 NoChange'
    }

    It 'attaches the existing OS disk of a host restored from a golden snapshot, which has no osProfile' {
        $script:hostComputerName = ''
        Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false -T2OsDiskSourceId '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/snap-dbhub-t2golden-202610221306' | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T2AttachExistingOsDisk -and -not $T2OsDiskSourceId }
    }

    It 'copies a new host''s OS disk from the golden snapshot it''s given' {
        $script:existing = @('sqlvm01')
        $snapshotId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/snap-dbhub-t2golden-202610221306'
        Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false -T2OsDiskSourceId $snapshotId | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T2OsDiskSourceId -eq $snapshotId -and -not $T2AttachExistingOsDisk }
    }

    It 'builds an existing host from the image when it has an osProfile' {
        Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { -not $T2AttachExistingOsDisk -and -not $T2OsDiskSourceId }
    }

    It 'keeps each drifted disk''s current type and warns instead of failing (Phase 24)' {
        # Live, 2026-10-26: the subscription's automation had switched both OS disks to Standard HDD while the VMs
        # were deallocated, and the template's StandardSSD_LRS for sqlvm01 failed the whole deployment.
        $script:drift = @([pscustomobject]@{ VmName = 'sqlvm01'; DiskName = 'sqlvm01-osdisk'; Kind = 'OS'; Current = 'Standard_LRS'; Expected = 'StandardSSD_LRS'; TemplateSetsType = $true })
        $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeTrue
        $warning = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.DISKS.DRIFT' }
        $warning.status | Should -Be 'Warning'
        $warning.message | Should -Match 'sqlvm01-osdisk \(sqlvm01''s OS disk\) is Standard_LRS, not the profile''s StandardSSD_LRS'
        $warning.message | Should -Match 'keeps each disk''s current type'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -Times 1 -Exactly -ParameterFilter { @($VmName) -contains 'sqlvm01' -and @($VmName) -contains 'archost01' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $null -ne $DiskSkuOverride -and $DiskSkuOverride['sqlvm01-osdisk'] -eq 'Standard_LRS' }

        $script:drift = @()
        $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
        @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.DISKS.DRIFT' }).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $null -eq $DiskSkuOverride -or $DiskSkuOverride.Count -eq 0 }
    }

    It 'sends T4''s zone only to a server that doesn''t exist, and names a size Azure refused with the documented fallback (Phase 24)' {
        $withT4 = New-TestConfig -WithT4
        $script:t4State = 'Ready'
        Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T4Exists }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -Times 0 -Exactly

        # A size the configuration sets never changes on its own (Phase 28): a refusal stays a Fail with the fallback named.
        $withT4['t4SkuName'] = 'Standard_B1ms'
        $script:t4State = 'NotFound'
        $script:templateFails = $true
        $script:t4Failure = [pscustomobject]@{ Sku = 'Standard_B1ms'; Zone = ''; TimeUtc = '2026-10-26T14:11:42Z' }
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { -not $T4Exists }
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Fail'
        $sku = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' }
        $sku.status | Should -Be 'Fail'
        $sku.message | Should -Match 'Standard_B1ms with no zone preference'
        $sku.remediation | Should -Match 'Set t4SkuName to Standard_B2s, the documented fallback'
        $sku.remediation | Should -Match 'A size you set is never changed on its own'
    }

    It 'falls back on its own from a refused Standard_B1ms to Standard_B2s, then to no T4, and records it, when the configuration doesn''t set the size (Phase 28)' {
        $withT4 = New-TestConfig -WithT4
        $withT4.Contains('t4SkuName') | Should -BeFalse -Because 'the schema has no default for it'
        $script:sizes = [System.Collections.Generic.List[string]]::new()
        $script:recordedSku = [System.Collections.Generic.List[string]]::new()
        $script:failures = [System.Collections.Generic.Queue[object]]::new()
        $script:failures.Enqueue([pscustomobject]@{ Sku = 'Standard_B1ms'; Zone = ''; TimeUtc = '2026-10-26T14:11:42Z' })
        $script:failures.Enqueue([pscustomobject]@{ Sku = 'Standard_B2s'; Zone = ''; TimeUtc = '2026-10-26T14:31:42Z' })
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -MockWith { if ($script:failures.Count -gt 0) { $script:failures.Dequeue() } else { $null } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:recordedSku.Add([string]$Value['T4Sku']) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { $null }
        # The template fails while T4 is in it (SkuNotAvailable) and succeeds without it.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            $script:sizes.Add($(if ($Config['t4Enabled']) { if ($Config.Contains('t4SkuName')) { [string]$Config['t4SkuName'] } else { 'default' } } else { 'none' }))
            $script:templateFails = [bool]$Config['t4Enabled']
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit }; budgetTags = @{ value = $ExistingResourceGroupTags } } }
        }
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeTrue
        $script:sizes | Should -Be @('default', 'Standard_B2s', 'none')
        $script:recordedSku | Should -Be @('Standard_B2s', 'None')
        $deployment.T4Enabled | Should -BeFalse
        $fallbacks = @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' })
        @($fallbacks.status) | Should -Be @('Warning', 'Warning')
        $fallbacks[0].message | Should -Match 'tries Standard_B2s, the same Burstable class'
        $fallbacks[1].message | Should -Match 't4Enabled stays as you configured it'
        $fallbacks[1].remediation | Should -Match '"t4SkuName": "Standard_D2ds_v5"'
        $fallbacks[1].remediation | Should -Match 'dated example'
        # The template keeps the choice in the resource group's tags too.
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Sku'] | Should -Be 'None'
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Pass'
    }

    It 'starts the fallback one size on when preflight already ruled the default out, and never for a size the configuration sets (Phase 28)' {
        $withT4 = New-TestConfig -WithT4
        $script:sizes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            $script:sizes.Add($(if ($Config['t4Enabled']) { if ($Config.Contains('t4SkuName')) { [string]$Config['t4SkuName'] } else { 'default' } } else { 'none' }))
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit } } }
        }
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false -T4StartSku 'Standard_B2s'
        $script:sizes | Should -Be @('Standard_B2s')
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' }).status | Should -Be 'Warning'
        $deployment.T4SkuName | Should -Be 'Standard_B2s'

        $script:sizes.Clear()
        $withT4['t4SkuName'] = 'Standard_D2ds_v5'
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false -T4StartSku 'None'
        $script:sizes | Should -Be @('Standard_D2ds_v5')
        @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' }).Count | Should -Be 0
    }

    It 'clears a recorded "no T4" once a size is deployed, and when the configuration sets t4SkuName (review finding 5)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'abc123'; owner = 'your-alias'; DbHubT4Sku = 'None' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit }; budgetTags = @{ value = $ExistingResourceGroupTags } } }
        }
        $withT4 = New-TestConfig -WithT4
        $withT4['t4SkuName'] = 'Standard_D2ds_v5'
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeTrue
        $deployment.T4Enabled | Should -BeTrue
        # The template carries the group's tags, so the stale record goes in them.
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Sku'] | Should -Be ''

        # A T4 left on in a configuration without a size (a sequential run reads no record) clears it once it's deployed.
        $script:deployCalls.Clear()
        Invoke-DemoTemplateDeployment -Config (New-TestConfig -WithT4) -NetworkMode private -T3UseFreeLimit $false | Out-Null
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Sku'] | Should -Be ''

        # With T4 off, the record stays.
        $script:deployCalls.Clear()
        Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false | Out-Null
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Sku'] | Should -Be 'None'
    }
}

Describe 'Invoke-DemoDeployment' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:recorded = [System.Collections.Generic.List[hashtable]]::new()
        $script:state = New-TestState
        $script:arcStatus = 'Pass'
        $script:preflightStatus = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $script:state }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith {
            $script:recorded.Add(@{} + $Value)
            foreach ($key in $Value.Keys) {
                $script:state.$key = $Value[$key]
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPreflight -MockWith {
            $script:order.Add('Preflight')
            New-TestResult 'PREFLIGHT.P1.ROLE' $script:preflightStatus 'preflight'
            New-DemoResult -CheckId 'PREFLIGHT.POLICY.SQLPUBLIC' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'policy' -Evidence @{ effectiveNetworkMode = 'private' }
            New-DemoResult -CheckId 'PREFLIGHT.T3.FREEOFFER' -Area 'preflight' -Target 'T3' -Status 'Pass' -Message 'free' -Evidence @{ useFreeLimit = $true }
            New-DemoResult -CheckId 'PREFLIGHT.P6.GROUP' -Area 'preflight' -Target 'tenant' -Status 'Pass' -Message 'group' -Evidence @{ groupDisplayName = 'DbHub T3 Admins' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -MockWith {
            # Only bound parameters exist as variables in a mock, and the static checks run under StrictMode.
            $script:order.Add($(if ($PesterBoundParameters.ContainsKey('BootstrapBundleSha256')) { 'Template+Bundle' } else { 'Template' }))
            [pscustomobject]@{ Succeeded = $true; Results = @(New-TestResult 'DEPLOY.TEMPLATE'); Outputs = @{}; Changes = @(); T3UseFreeLimit = $T3UseFreeLimit }
        }
        Mock -ModuleName DbHubDemo -CommandName New-DemoBootstrapBundle -MockWith { $script:order.Add('Bundle'); [pscustomobject]@{ Sha256 = $script:sha; Path = 'bundle.zip' } }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoBootstrapBundle -MockWith { $script:order.Add('SendBundle:' + $VmName); [pscustomobject]@{ ChunkCount = 1; Seconds = 50 } }
        Mock -ModuleName DbHubDemo -CommandName Publish-DemoWorkloadRunner -MockWith { $script:order.Add('Publish'); [pscustomobject]@{ Sha256 = $script:runnerSha; Path = 'runner.zip' } }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoWorkloadRunner -MockWith { $script:order.Add('SendRunner:' + $VmName); [pscustomobject]@{ ChunkCount = 7; Seconds = 300 } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoBootstrapLoader -MockWith { $script:order.Add('Loader:' + $VmName); New-TestResult ('INFRA.BOOTSTRAP.LOADER_{0}' -f $VmName.ToUpperInvariant()) }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { $script:order.Add('T1Ready'); [pscustomobject]@{ Health = [pscustomobject]@{ state = 'Ready'; message = 'all steps done' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { '88888888-8888-8888-8888-888888888888' }
        Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith { $script:order.Add('Group'); New-TestResult 'T3.GROUP.T1MEMBER' 'Pass' 't3' 'T3' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith { $script:order.Add('T3Setup'); [pscustomobject]@{ Status = 'Pass'; Result = (New-TestResult 'T3.SQL.SETUP' 'Pass' 't3' 'T3') } }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoT3Workload -MockWith { $script:order.Add('EnableT3'); New-TestResult 'WORKLOAD.T3.ENABLE' 'Pass' 'workload' 'T3' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT3 -MockWith { $script:order.Add('TestT3'); New-TestResult 'T3.DATABASE' 'Pass' 't3' 'T3' }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoTargetProfile -MockWith { $script:order.Add(('Profile:{0}={1}' -f $Target, $ProfileName)); New-TestResult ('{0}.PROFILE_{1}' -f $CheckPrefix, $Target) 'Pass' 'workload' $Target }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith { $script:order.Add('Monitoring'); New-TestResult 'T1.SQLVM.MONITORING' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcConfiguration -MockWith {
            $script:order.Add('Arc')
            if ($script:arcStatus -eq 'Manual action required') {
                New-DemoResult -CheckId 'T2.PAYGWIZARD' -Area 't2' -Target 'T2' -Status 'Manual action required' -Message 'The wizard waits.' -Remediation 'Open Bastion, run the wizard, choose Pay-as-you-go.'
            }
            else {
                New-TestResult 'T2.ARC.CONNECTED' 'Pass' 't2' 'T2'
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -MockWith { $script:order.Add('Fabric'); New-TestResult 'HUB.ESTATE' 'Pass' 'hub' 'fabric' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:order.Add('Telemetry:' + ($Target -join ',')); New-TestResult 'HUB.TELEMETRY.T1' 'Pass' 'hub' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { $script:order.Add('Inventory:' + $ListedStatus); New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith { $script:order.Add('RunnerStatus'); [pscustomobject]@{ Status = 'Pass'; Result = (New-TestResult 'WORKLOAD.T1.COMMAND' 'Pass' 'workload' 'T1') } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDoneGate -MockWith { $script:order.Add('DoneGate'); New-TestResult 'HUB.ESTATE.T1' 'Pass' 'hub' 'T1' }
    }

    It 'runs DONE''s read-only checks after the validation, as the parallel path does, so a sequential run can end DONE (review finding 4)' {
        $results = Invoke-DemoDeployment -Config $config
        $script:order[-1] | Should -Be 'DoneGate'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDoneGate -Times 1 -Exactly -ParameterFilter { $Requirement -contains 'HUB.ESTATE.T1' -and $Requirement -contains 'T2.ARC.SQLINSTANCE' -and $Requirement -contains 'FABRIC.ITEMS.REQUIRED' -and $Requirement -notcontains 'HUB.ESTATE.T4' }
        ($results | Where-Object { $_.checkId -eq 'HUB.ESTATE.T1' }).status | Should -Be 'Pass'

        # Not while a stage is open (T2 in PaygWizard mode, which -Sequential doesn't guide): that run isn't done anyway.
        $script:order.Clear()
        $script:arcStatus = 'Manual action required'
        Invoke-DemoDeployment -Config $config | Out-Null
        $script:order | Should -Not -Contain 'DoneGate'
    }

    It 'runs every stage in the live-proven order' {
        $results = Invoke-DemoDeployment -Config $config
        $script:order | Should -Be @(
            'Preflight', 'Template', 'Bundle', 'SendBundle:sqlvm01', 'SendBundle:archost01', 'Publish', 'SendRunner:sqlvm01', 'SendRunner:archost01',
            'Template+Bundle', 'Loader:sqlvm01', 'Loader:archost01', 'T1Ready', 'Group', 'T3Setup', 'EnableT3', 'TestT3',
            'Profile:T1=baseline', 'Profile:T3=baseline', 'Monitoring', 'Arc', 'Profile:T2=baseline', 'Fabric', 'Telemetry:T1,T2,T3', 'Inventory:Fail', 'RunnerStatus', 'DoneGate'
        )
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).status | Should -Be 'Pass'
        $script:state.Stage | Should -Be 'Validation'
        @($script:state.BundleSentTo | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        @($script:state.RunnerSentTo | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        $script:state.RunnerSha256 | Should -Be $script:runnerSha
        @($results | ForEach-Object { $_.checkId } | Where-Object { $_ -like 'DEPLOY.STAGE.*' }).Count | Should -Be 11
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.T4' }).status | Should -Be 'Not selected' -Because 'T4 is off in this test configuration'
    }

    It 'stops at a preflight Fail before anything is deployed' {
        $script:preflightStatus = 'Fail'
        $results = Invoke-DemoDeployment -Config $config
        $script:order | Should -Be @('Preflight')
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.PREFLIGHT' }).status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -Times 0 -Exactly
    }

    It 'resumes after the recorded stage, with the bundle and runner it recorded' {
        $script:state = New-TestState @{ Stage = 'Monitoring'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('archost01', 'sqlvm01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('archost01', 'sqlvm01') }
        Invoke-DemoDeployment -Config $config -Resume | Out-Null
        $script:order[0] | Should -Be 'Arc'
        $script:order | Should -Not -Contain 'Preflight'
        $script:order | Should -Not -Contain 'Bundle'
    }

    It 'never hides a manual step: T2 stays open, the later stages run, and the summary lists the steps' {
        $script:arcStatus = 'Manual action required'
        $results = Invoke-DemoDeployment -Config $config
        $script:order | Should -Contain 'Fabric'
        $script:order | Should -Not -Contain 'Profile:T2=baseline'
        $script:state.Stage | Should -Be 'Monitoring' -Because 'the recorded stage never moves past an open stage, so -Resume continues with T2'
        $summary = $results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }
        $summary.status | Should -Be 'Manual action required'
        $summary.message | Should -Match 'T2.PAYGWIZARD: Open Bastion, run the wizard'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.T2' }).status | Should -Be 'Manual action required'
    }

    It 'runs only the preflight and the what-if with -WhatIf, and records nothing' {
        $results = Invoke-DemoDeployment -Config $config -Resume -WhatIf
        $script:order | Should -Be @('Preflight', 'Template')
        $script:recorded.Count | Should -Be 0
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.INFRASTRUCTURE' }).status | Should -Be 'Not selected'
    }

    It 'skips the runner with -SkipRunner, and the activity profiles say so' {
        Mock -ModuleName DbHubDemo -CommandName Set-DemoTargetProfile -MockWith { $script:order.Add('Profile:' + $Target + ':' + $SkipReason); New-TestResult ('{0}.PROFILE_{1}' -f $CheckPrefix, $Target) 'Not selected' 'workload' $Target }
        Invoke-DemoDeployment -Config $config -SkipRunner -StopAfter Activity | Out-Null
        $script:order | Should -Not -Contain 'Publish'
        @($script:order | Where-Object { $_ -like 'Profile:T1:No workload runner*' }).Count | Should -Be 1
    }

    It 'stops after the given stage' {
        Invoke-DemoDeployment -Config $config -StopAfter Infrastructure | Out-Null
        $script:order | Should -Be @('Preflight', 'Template')
        $script:state.Stage | Should -Be 'Infrastructure'
    }

    It 'deploys the opt-in Key Vault after the template, and a vault Fail is reported without stopping the run' {
        $vaultConfig = New-TestConfig
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        Mock -ModuleName DbHubDemo -CommandName Initialize-DemoKeyVault -MockWith { $script:order.Add('KeyVault'); New-TestResult 'INFRA.KEYVAULT' 'Fail' }
        $results = Invoke-DemoDeployment -Config $vaultConfig
        $script:order[0..2] | Should -Be @('Preflight', 'Template', 'KeyVault')
        $script:order[-1] | Should -Be 'RunnerStatus'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).status | Should -Be 'Fail'
        $script:state.Stage | Should -Be 'Validation'

        $script:order.Clear()
        Invoke-DemoDeployment -Config $config -StopAfter Infrastructure | Out-Null
        $script:order | Should -Not -Contain 'KeyVault' -Because 'the default path creates no vault'
    }
}

Describe 'Remove-DemoBastion' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:resources = @()
        $script:inUse = 0
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            $script:azCalls.Add($text)
            if ($text -like 'resource list*') {
                return (New-AzResult -StdOut (ConvertTo-Json -InputObject @($script:resources) -Depth 5))
            }
            if ($text -like 'network public-ip delete*' -and $script:inUse -gt 0) {
                $script:inUse--
                return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (InUsePublicIpAddressCannotBeDeleted) Public IP address pip-dbhub-demo-bastion can not be deleted since it is still allocated to resource bas-dbhub-demo.')
            }
            return (New-AzResult)
        }
    }

    It 'deletes a public IP that an interrupted delete left behind, even without the Bastion host' {
        $script:resources = @(@{ name = 'pip-dbhub-demo-bastion'; type = 'Microsoft.Network/publicIPAddresses'; id = '/x/pip' })
        $result = Remove-DemoBastion -Config $config -IfExpired -Confirm:$false
        $result.checkId | Should -Be 'STOP.BASTION'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'interrupted Bastion delete'
        $result.evidence.leftover | Should -BeTrue
        @($script:azCalls | Where-Object { $_ -like 'resource delete*' }).Count | Should -Be 0
        @($script:azCalls | Where-Object { $_ -like 'network public-ip delete*pip-dbhub-demo-bastion*' }).Count | Should -Be 1
    }

    It 'deletes the Bastion host first, then its public IP' {
        $script:resources = @(
            @{ name = 'bas-dbhub-demo'; type = 'Microsoft.Network/bastionHosts'; id = '/x/bas'; tags = @{ DbHubBastionExpiresUtc = '2026-10-20T10:00:00Z' } }
            @{ name = 'pip-dbhub-demo-bastion'; type = 'Microsoft.Network/publicIPAddresses'; id = '/x/pip' }
        )
        $result = Remove-DemoBastion -Config $config -Confirm:$false
        $result.status | Should -Be 'Pass'
        $deletes = @($script:azCalls | Where-Object { $_ -like '*delete*' })
        $deletes[0] | Should -BeLike 'resource delete*bas-dbhub-demo*Microsoft.Network/bastionHosts*'
        $deletes[1] | Should -BeLike 'network public-ip delete*pip-dbhub-demo-bastion*'
        @($script:azCalls | Where-Object { $_ -like 'network bastion*' }).Count | Should -Be 0 -Because 'az network bastion needs an extension that prompts'
    }

    It 'waits while the host''s own delete still holds the public IP' {
        $script:resources = @(@{ name = 'pip-dbhub-demo-bastion'; type = 'Microsoft.Network/publicIPAddresses'; id = '/x/pip' })
        $script:inUse = 2
        (Remove-DemoBastion -Config $config -Confirm:$false -InUseRetrySeconds 1).status | Should -Be 'Pass'
        @($script:azCalls | Where-Object { $_ -like 'network public-ip delete*' }).Count | Should -Be 3
    }

    It 'keeps a Bastion that hasn''t expired, and reports Not selected when there''s nothing to remove' {
        $script:resources = @(
            @{ name = 'bas-dbhub-demo'; type = 'Microsoft.Network/bastionHosts'; id = '/x/bas'; tags = @{ DbHubBastionExpiresUtc = '2026-10-20T16:00:00Z' } }
            @{ name = 'pip-dbhub-demo-bastion'; type = 'Microsoft.Network/publicIPAddresses'; id = '/x/pip' }
        )
        $kept = Remove-DemoBastion -Config $config -IfExpired -NowUtc ([datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc)) -Confirm:$false
        $kept.status | Should -Be 'Not selected'
        $kept.message | Should -Match 'stays until'
        @($script:azCalls | Where-Object { $_ -like '*delete*' }).Count | Should -Be 0

        $script:resources = @()
        (Remove-DemoBastion -Config $config -Confirm:$false).status | Should -Be 'Not selected'
    }
}

Describe 'New-DemoBastion' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:deploy = $null
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:expiryRecorded = $Value['BastionExpiresUtc'] }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ owner = 'your-alias'; DbHubDeployStage = 'Validation' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $file = [string]$ArgumentList[[array]::IndexOf($ArgumentList, '--parameters') + 1]
            $script:deploy = [pscustomobject]@{ Arguments = @($ArgumentList); Parameters = (Get-Content -LiteralPath $file.Substring(1) -Raw | ConvertFrom-Json -AsHashtable) }
            return (New-AzResult -StdOut '{}')
        }
    }

    It 'deploys the Bastion module as a template into the existing subnet, capped at bastionMaxHours' {
        $config['bastionMaxHours'] = 4
        $result = New-DemoBastion -Config $config -Hours 12 -Confirm:$false
        $result.status | Should -Be 'Pass'
        ($script:deploy.Arguments[0..2] -join ' ') | Should -Be 'deployment group create'
        ($script:deploy.Arguments -join ' ') | Should -Match 'infra[\\/]modules[\\/]bastion\.bicep'
        $script:deploy.Parameters.parameters.vnetName.value | Should -Be 'vnet-dbhub-demo'
        $script:deploy.Parameters.parameters.tags.value.Contains('DbHubDeployStage') | Should -BeFalse -Because 'the deployment state stays on the resource group only'
        $expires = [datetime]::Parse($script:deploy.Parameters.parameters.expiresUtc.value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        ($expires - [DateTime]::UtcNow).TotalHours | Should -BeLessOrEqual 4.01
        ($expires - [DateTime]::UtcNow).TotalHours | Should -BeGreaterThan 3.9
    }
}

Describe 'Set-DemoVmLocalPassword' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:power = 'PowerState/running'
        $script:runs = [System.Collections.Generic.List[object]]::new()
        $script:recorded = $null
        $script:passwordLog = 'DBHUBDEMO-LOG found=0 cleared=False error='
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:recorded = $Value['HostPasswordSet'] }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -StdOut "demoadmin`n" }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $script:runs.Add([pscustomobject]@{ Name = $RunCommandName; Script = $Script; Parameter = $Parameter; Protected = $ProtectedParameter })
            [pscustomobject]@{ Succeeded = $true; Output = ("DBHUBDEMO-PASSWORD set for demoadmin`n" + $script:passwordLog); Error = '' }
        }
    }

    It 'sets the password with Set-LocalUser in a Run Command, Base64-encoded in a protected parameter only' {
        $plain = 'Tq' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '#*x9'
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $plain.ToCharArray()) {
            $secure.AppendChar($character)
        }
        $result = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Password $secure -Confirm:$false
        $result.checkId | Should -Be 'START.HOSTPASSWORD'
        $result.status | Should -Be 'Pass'
        $script:runs.Count | Should -Be 1
        $run = $script:runs[0]
        $run.Name | Should -Be 'DbHubDemo-HostPassword'
        $run.Script | Should -Match 'Set-LocalUser'
        $run.Parameter['UserName'] | Should -Be 'demoadmin'
        $run.Parameter.Contains('PasswordBase64') | Should -BeFalse
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($run.Protected['PasswordBase64'])) | Should -Be $plain
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($plain))
        $script:recorded | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'clears the Windows PowerShell log in the same Run Command when it recorded the password, and warns' {
        $script:passwordLog = 'DBHUBDEMO-LOG found=2 cleared=True error='
        $result = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'rotated to a value nobody keeps'
        $result.message | Should -Match 'endpoint protection may report'
        $result.evidence.powerShellLog.cleared | Should -BeTrue
        $sent = $script:runs[0].Script
        $sent | Should -Match 'function Clear-DemoProtectedValueLog'
        $sent | Should -Match ([regex]::Escape('Clear-DemoProtectedValueLog -Value $PasswordBase64'))
        $sent.IndexOf('function Disable-DemoSessionEventLog') | Should -BeGreaterThan $sent.IndexOf('param(') -Because 'the param block stays first'

        $script:passwordLog = 'DBHUBDEMO-LOG found=1 cleared=False error=UnauthorizedAccessException'
        $manual = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false
        $manual.status | Should -Be 'Manual action required'
        $manual.remediation | Should -Match ([regex]::Escape('wevtutil clear-log "Windows PowerShell"'))
    }

    It 'reports the Windows PowerShell log even when the password wasn''t changed' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            [pscustomobject]@{ Succeeded = $false; Output = $script:passwordLog; Error = 'Set-LocalUser failed.' }
        }
        $script:passwordLog = 'DBHUBDEMO-LOG found=2 cleared=True error='
        $result = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'endpoint protection may report'
        $result.evidence.powerShellLog.cleared | Should -BeTrue

        $script:passwordLog = 'DBHUBDEMO-LOG found=1 cleared=False error=UnauthorizedAccessException'
        $failed = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false
        $failed.status | Should -Be 'Fail'
        $failed.remediation | Should -Match ([regex]::Escape('wevtutil clear-log "Windows PowerShell"'))
    }

    It 'sends a value the Run Command accepts, and never the type name of a SecureString: <Name>' -ForEach @(
        @{ Name = 'a new password'; Rotate = $false }
        @{ Name = 'a rotation'; Rotate = $true }
    ) {
        # A SecureString bound to a [string] parameter becomes the literal 'System.Security.SecureString', and Run
        # Command refuses symbols outside its pattern.
        $runCommandPattern = '^[A-Za-z0-9._:/@=,+?&%~-]*$'
        $sent = $null
        if ($Rotate) {
            Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false | Out-Null
        }
        else {
            $sent = New-DemoAdminPassword
            Set-DemoVmLocalPassword -Config $config -VmName archost01 -Password $sent -Confirm:$false | Out-Null
        }
        $script:runs.Count | Should -Be 1
        $protected = [string]$script:runs[0].Protected['PasswordBase64']
        $protected | Should -Match $runCommandPattern
        $protected | Should -Match '^[A-Za-z]' -Because 'a value that starts with - would read as a parameter name'
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($protected))
        $decoded | Should -Not -Be 'System.Security.SecureString'
        $decoded | Should -Not -Match '^System\.'
        $decoded.Length | Should -BeGreaterOrEqual 16
        if ($sent) {
            $decoded | Should -BeExactly ([System.Net.NetworkCredential]::new('', $sent).Password)
        }
    }

    It 'refuses a password that is a type name before any Run Command' {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'System.Security.SecureString'.ToCharArray()) {
            $secure.AppendChar($character)
        }
        $result = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Password $secure -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'type name'
        $script:runs.Count | Should -Be 0
    }

    It 'reports Manual action required for a rotation while the VM is deallocated, without a Run Command' {
        $script:power = 'PowerState/deallocated'
        $result = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false
        $result.checkId | Should -Be 'STOP.HOSTPASSWORD'
        $result.status | Should -Be 'Manual action required'
        $result.remediation | Should -Match 'Reset password'
        $script:runs.Count | Should -Be 0
    }

    It 'rotates to a value nobody keeps and clears the record' {
        $result = Set-DemoVmLocalPassword -Config $config -VmName archost01 -Rotate -Confirm:$false
        $result.status | Should -Be 'Pass'
        $script:runs[0].Protected['PasswordBase64'] | Should -Not -BeNullOrEmpty
        $script:recorded | Should -Be ''
    }
}

Describe 'Stop-DemoEnvironment' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:state = New-TestState @{ RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); HostPasswordUtc = '2026-10-20T15:00:00Z' }
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $script:state }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power[$VmName] }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { $script:order.Add('Bastion'); New-TestResult 'STOP.BASTION' 'Pass' 'infra' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:order.Add('Rotate:' + $VmName); New-TestResult 'STOP.HOSTPASSWORD' 'Pass' 'infra' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:order.Add(('Profile:{0}={1}' -f $Target, $ArgumentList[3]))
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @(); Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
        Mock -ModuleName DbHubDemo -CommandName Stop-DemoGuestVm -MockWith { $script:order.Add('Guest'); New-TestResult 'STOP.GUEST' 'Pass' 'infra' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Deallocate:' + $VmName); New-TestResult ('STOP.VM_{0}' -f $VmName.ToUpperInvariant()) 'Pass' 'infra' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoT3 -MockWith { $script:order.Add('RemoveT3'); New-TestResult 'T3.REMOVE' 'Pass' 't3' 'T3' }
    }

    It 'removes Bastion, rotates the password, turns every profile off, stops the guest, then deallocates' {
        $results = Stop-DemoEnvironment -Config $config -Confirm:$false
        $script:order | Should -Be @('Bastion', 'Rotate:archost01', 'Profile:T1=off', 'Profile:T3=off', 'Profile:T2=off', 'Guest', 'Deallocate:archost01', 'Deallocate:sqlvm01')
        ($results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T3' }).message | Should -Match 'off'
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoT3 -Times 0 -Exactly
    }

    It 'parks only T2 with -ParkT2, and deletes T3 only with -RemoveT3' {
        Stop-DemoEnvironment -Config $config -ParkT2 -Confirm:$false | Out-Null
        $script:order | Should -Be @('Bastion', 'Rotate:archost01', 'Profile:T2=off', 'Guest', 'Deallocate:archost01')
        $script:order.Clear()
        Stop-DemoEnvironment -Config $config -RemoveT3 -Confirm:$false | Out-Null
        $script:order[-1] | Should -Be 'RemoveT3'
    }

    It 'only removes Bastion and rotates the password with -RemoveBastionOnly' {
        Stop-DemoEnvironment -Config $config -RemoveBastionOnly -IfExpired -Confirm:$false | Out-Null
        $script:order | Should -Be @('Bastion', 'Rotate:archost01')
    }

    It 'doesn''t rotate on an hourly cleanup that removed nothing' {
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { $script:order.Add('Bastion'); New-TestResult 'STOP.BASTION' 'Not selected' 'infra' 'T2' }
        Stop-DemoEnvironment -Config $config -RemoveBastionOnly -IfExpired -Confirm:$false | Out-Null
        $script:order | Should -Be @('Bastion')
    }

    It 'disables the Key Vault copy with the rotation, even when the host can''t be rotated, and not during a session' {
        $vaultConfig = New-TestConfig
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:order.Add('Rotate:' + $VmName); New-TestResult 'STOP.HOSTPASSWORD' 'Manual action required' 'infra' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Disable-DemoHostPasswordSecret -MockWith { $script:order.Add('DisableSecret:' + $CheckId); New-TestResult $CheckId 'Pass' 'infra' 'T2' }
        Stop-DemoEnvironment -Config $vaultConfig -RemoveBastionOnly -Confirm:$false | Out-Null
        $script:order | Should -Be @('Bastion', 'Rotate:archost01', 'DisableSecret:STOP.KEYVAULT')

        $script:order.Clear()
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { $script:order.Add('Bastion'); New-TestResult 'STOP.BASTION' 'Not selected' 'infra' 'T2' }
        Stop-DemoEnvironment -Config $vaultConfig -RemoveBastionOnly -IfExpired -Confirm:$false | Out-Null
        $script:order | Should -Be @('Bastion') -Because 'a Bastion that hasn''t expired means the session is still on'
        Should -Invoke -ModuleName DbHubDemo -CommandName Disable-DemoHostPasswordSecret -Times 1 -Exactly
    }

    It 'skips the profile of a VM that isn''t running: nothing runs there, and nothing restarts it at boot' {
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' }
        $results = Stop-DemoEnvironment -Config $config -Confirm:$false
        $script:order | Should -Not -Contain 'Profile:T1=off'
        $script:order | Should -Not -Contain 'Guest'
        ($results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T1' }).status | Should -Be 'Not selected'
        ($results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T1' }).message | Should -Match 'activityProfileOnBoot'
    }

    It 'changes nothing with -WhatIf' {
        $results = Stop-DemoEnvironment -Config $config -WhatIf
        $script:order.Count | Should -Be 0
        ($results | Where-Object { $_.checkId -eq 'STOP.DEMO' }).status | Should -Be 'Not selected'
    }

    It 'turns T4''s profile off with the others and stops T4 after the VMs when T4 is on, but not with -ParkT2 (Phase 24)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $true; State = 'Ready' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith { $script:order.Add(('T4:{0}:{1}' -f $Action, $WaitMinutes)); New-TestResult 'STOP.T4.STOP' 'Pass' 'infra' 'T4' }
        $results = Stop-DemoEnvironment -Config (New-TestConfig -WithT4) -Confirm:$false
        $script:order | Should -Be @('Bastion', 'Rotate:archost01', 'Profile:T1=off', 'Profile:T3=off', 'Profile:T4=off', 'Profile:T2=off', 'Guest', 'Deallocate:archost01', 'Deallocate:sqlvm01', 'T4:Stop:0')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -Times 1 -Exactly -ParameterFilter { $Action -eq 'Stop' -and $CheckPrefix -eq 'STOP' }
        ($results | Where-Object { $_.checkId -eq 'STOP.T4.STOP' }).status | Should -Be 'Pass'

        $script:order.Clear()
        Stop-DemoEnvironment -Config (New-TestConfig -WithT4) -ParkT2 -Confirm:$false | Out-Null
        $script:order | Should -Not -Contain 'T4:Stop:0'
        $script:order | Should -Not -Contain 'Profile:T4=off'
    }

    It 'leaves a T4 that was never created alone, and still stops one whose state couldn''t be read (Phase 24)' {
        # Live, 2026-10-26: T1's runner from before Phase 24 refused T4's profile while T4 didn't exist yet.
        $script:t4Read = 'NotFound'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $false; State = $script:t4Read } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith { $script:order.Add('T4:' + $Action); New-TestResult 'STOP.T4.STOP' 'Warning' 'infra' 'T4' }
        $results = Stop-DemoEnvironment -Config (New-TestConfig -WithT4) -Confirm:$false
        $script:order | Should -Not -Contain 'Profile:T4=off'
        $script:order | Should -Not -Contain 'T4:Stop'
        ($results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T4' }).status | Should -Be 'Not selected'
        ($results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T4' }).message | Should -Match 'isn''t deployed'
        ($results | Where-Object { $_.checkId -eq 'STOP.T4.STOP' }).status | Should -Be 'Not selected'

        $script:order.Clear()
        $script:t4Read = 'Unknown'
        Stop-DemoEnvironment -Config (New-TestConfig -WithT4) -Confirm:$false | Out-Null
        $script:order | Should -Contain 'T4:Stop' -Because 'a server that only couldn''t be read may still be running and billing'
    }
}

Describe 'Start-DemoEnvironment' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:state = New-TestState @{ Stage = 'Validation'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('sqlvm01', 'archost01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('sqlvm01', 'archost01') }
        $script:costStatus = 'Pass'
        $script:t3Exists = $true
        $script:t2Failures = 0
        $script:t1Failures = 0
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { $script:state }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoStartCost -MockWith { $script:order.Add('Cost'); New-TestResult 'START.COST.ACTUAL' $script:costStatus 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Start:' + $VmName); New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) 'Pass' 'infra' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $true }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -MockWith { $script:order.Add('SourceRelease'); $script:sourceRelease }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:order.Add('T1Monitoring'); New-TestResult 'START.T1.MONITORING' 'Pass' 't1' 'T1' }
        $script:sourceRelease = $null
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:order.Add('Rotate'); New-TestResult 'STOP.HOSTPASSWORD' 'Pass' 'infra' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3State -MockWith { [pscustomobject]@{ Exists = $script:t3Exists; Status = 'Paused'; ServerName = 'azuresql01-abc123'; DeploymentId = 'abc123' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3WarmUp -MockWith { $script:order.Add('WarmT3'); New-TestResult 'T3.WARMUP' 'Pass' 't3' 'T3' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoTemplateDeployment -MockWith { $script:order.Add('Template:' + $BootstrapBundleSha256.Substring(0, 4) + ':' + $WorkloadRunnerSha256.Substring(0, 4)); [pscustomobject]@{ Succeeded = $true; Results = @(New-TestResult 'DEPLOY.TEMPLATE'); Outputs = @{}; Changes = @(); T3UseFreeLimit = $false } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT1PrincipalId -MockWith { '88888888-8888-8888-8888-888888888888' }
        Mock -ModuleName DbHubDemo -CommandName Add-DemoT1ToT3AdminGroup -MockWith { $script:order.Add('Group'); New-TestResult 'T3.GROUP.T1MEMBER' 'Pass' 't3' 'T3' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith { $script:order.Add('T3Setup'); [pscustomobject]@{ Status = 'Pass'; Result = (New-TestResult 'T3.SQL.SETUP' 'Pass' 't3' 'T3') } }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoT3Workload -MockWith { $script:order.Add('EnableT3'); New-TestResult 'WORKLOAD.T3.ENABLE' 'Pass' 'workload' 'T3' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT3Readiness -MockWith { $script:order.Add('Gate'); [pscustomobject]@{ Results = @(New-TestResult 'HUB.T3.READINESS' 'Pass' 'hub' 'T3') } }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith { $script:order.Add('Monitoring:' + $WaitMinutes); New-TestResult 'T1.SQLVM.MONITORING' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:order.Add(('Profile:{0}={1}' -f $Target, $ArgumentList[3]))
            if ($Target -eq 'T2' -and $script:t2Failures -gt 0) {
                $script:t2Failures--
                return [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Records = @(); Result = (New-TestResult 'WORKLOAD.T2.COMMAND' 'Fail' 'workload' 'T2') }
            }
            if ($Target -eq 'T1' -and $script:t1Failures -gt 0) {
                $script:t1Failures--
                return [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Records = @(); Result = (New-TestResult 'WORKLOAD.T1.COMMAND' 'Fail' 'workload' 'T1') }
            }
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @(); Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { $script:order.Add('Telemetry:' + ($Target -join ',')); New-TestResult 'HUB.TELEMETRY.T1' 'Pass' 'hub' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName New-DemoBastion -MockWith { $script:order.Add('Bastion'); New-TestResult 'START.BASTION' 'Pass' 'infra' 'T2' }
        $script:autoStopThrows = $false
        $script:stopJobWaited = $false
        Mock -ModuleName DbHubDemo -CommandName Clear-DemoActivityControlAutoStop -MockWith {
            $script:order.Add('AutoStop:' + $Purpose)
            if ($script:autoStopThrows) {
                throw 'ERROR: (AuthorizationFailed) The client has no access to read the schedule.'
            }
            if ($script:stopJobWaited) {
                New-TestResult 'START.CONTROL.AUTOSTOP' 'Not selected' 'workload'
                New-TestResult 'START.CONTROL.STOPJOB' 'Pass' 'workload'
                return
            }
            New-TestResult 'START.CONTROL.AUTOSTOP' 'Warning' 'workload'
        }
        function New-ControlTestConfig {
            $controlConfig = New-TestConfig
            $controlConfig['control']['enabled'] = $true
            return $controlConfig
        }
    }

    It 'checks the cost, starts the VMs, resumes T3, and sets the configured profile everywhere' {
        Start-DemoEnvironment -Config $config -Confirm:$false | Out-Null
        $script:order | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'Start:sqlvm01', 'Start:archost01', 'SourceRelease', 'T1Monitoring', 'WarmT3', 'Profile:T1=baseline', 'Profile:T3=baseline', 'Profile:T2=baseline')
    }

    It 'tells the power check which VMs this start requested, so a VM it started isn''t "already running" (Phase 25d)' {
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $VmName -eq 'sqlvm01' }
        Start-DemoEnvironment -Config $config -Confirm:$false | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -Times 1 -Exactly -ParameterFilter { $VmName -eq 'sqlvm01' -and $StartRequested }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -Times 1 -Exactly -ParameterFilter { $VmName -eq 'archost01' -and -not $StartRequested }
    }

    It 'cancels a pending on-demand auto-stop before the VMs start, with the control on (ADR 0020)' {
        $results = Start-DemoEnvironment -Config (New-ControlTestConfig) -Confirm:$false
        @($script:order | Select-Object -First 3) | Should -Be @('Cost', 'AutoStop:Start', 'Request:sqlvm01')
        ($results | Where-Object { $_.checkId -eq 'START.CONTROL.AUTOSTOP' }).status | Should -Be 'Warning'
    }

    It 'keeps both results when it waited for an on-demand stop job before the VMs start' {
        $script:stopJobWaited = $true
        $results = Start-DemoEnvironment -Config (New-ControlTestConfig) -Confirm:$false
        ($results | Where-Object { $_.checkId -eq 'START.CONTROL.AUTOSTOP' }).status | Should -Be 'Not selected'
        ($results | Where-Object { $_.checkId -eq 'START.CONTROL.STOPJOB' }).status | Should -Be 'Pass'
        @($script:order | Select-Object -First 3) | Should -Be @('Cost', 'AutoStop:Start', 'Request:sqlvm01')
    }

    It 'carries on with a Warning when a pending auto-stop can''t be checked' {
        $script:autoStopThrows = $true
        $results = Start-DemoEnvironment -Config (New-ControlTestConfig) -Confirm:$false
        $warning = $results | Where-Object { $_.checkId -eq 'START.CONTROL.AUTOSTOP' }
        $warning.status | Should -Be 'Warning'
        $warning.message | Should -Match 'AuthorizationFailed.*the start carried on'
        $warning.remediation | Should -Match 'delete the schedule dbhub-autostop'
        $script:order | Should -Contain 'Start:sqlvm01'
        $script:order | Should -Contain 'Profile:T2=baseline'
    }

    It 'leaves the auto-stop alone with the control off, or with -WhatIf' {
        Start-DemoEnvironment -Config $config -Confirm:$false | Out-Null
        Start-DemoEnvironment -Config (New-ControlTestConfig) -WhatIf | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Clear-DemoActivityControlAutoStop -Times 0 -Exactly
    }

    It 'reconnects a golden snapshot''s source host before the T2 profile' {
        $script:sourceRelease = New-TestResult 'T2.GOLDEN.SOURCE' 'Pass' 't2' 'T2'
        $results = Start-DemoEnvironment -Config $config -Confirm:$false
        ($results | Where-Object { $_.checkId -eq 'T2.GOLDEN.SOURCE' }).status | Should -Be 'Pass'
        $script:order.IndexOf('SourceRelease') | Should -BeLessThan $script:order.IndexOf('Profile:T2=baseline')
    }

    It 'stops before anything starts when the cost guardrail fails' {
        $script:costStatus = 'Fail'
        $results = Start-DemoEnvironment -Config $config -Confirm:$false
        $script:order | Should -Be @('Cost')
        ($results | Where-Object { $_.checkId -eq 'START.DEMO' }).status | Should -Be 'Fail'
    }

    It 'recreates a removed T3 under the same names, with the recorded bundle and runner, and checks T1''s monitoring after the template' {
        $script:t3Exists = $false
        Start-DemoEnvironment -Config $config -ActivityProfile 'off' -Confirm:$false | Out-Null
        $script:order | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'Start:sqlvm01', 'Start:archost01', 'SourceRelease', 'T1Monitoring', 'Template:abab:cdcd', 'Group', 'T3Setup', 'EnableT3', 'Gate', 'Monitoring:20', 'Profile:T1=off', 'Profile:T3=off', 'Profile:T2=off')
    }

    It 'rotates a one-time password left from an earlier session, retries T2 while its guest boots, and warms up with -WaitForWarmUp' {
        $script:state.HostPasswordUtc = '2026-10-19T15:00:00Z'
        $script:t2Failures = 1
        $results = Start-DemoEnvironment -Config $config -WarmUpMinutes 30 -WaitForWarmUp -T2ProfileRetrySeconds 1 -Confirm:$false
        $script:order | Should -Contain 'Rotate'
        @($script:order | Where-Object { $_ -eq 'Profile:T2=baseline' }).Count | Should -Be 2
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T2' }).status | Should -Be 'Pass'
        $script:order[-1] | Should -Be 'Telemetry:T1,T3,T2'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 1800 } -Times 1 -Exactly
    }

    It 'retries T1 too, whose SQL Server can still be starting because both VMs boot at once' {
        # Live, 2026-10-22: T1's only attempt found no server, so its profile stayed unset.
        $script:t1Failures = 1
        $results = Start-DemoEnvironment -Config $config -T2ProfileRetrySeconds 1 -Confirm:$false
        @($script:order | Where-Object { $_ -eq 'Profile:T1=baseline' }).Count | Should -Be 2
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T1' }).status | Should -Be 'Pass'
        @($script:order | Where-Object { $_ -eq 'Profile:T3=baseline' }).Count | Should -Be 1
    }

    It 'leaves the warm-up running in the background without -WaitForWarmUp (ADR 0018)' {
        $results = Start-DemoEnvironment -Config $config -WarmUpMinutes 30 -Confirm:$false
        $warm = $results | Where-Object { $_.checkId -eq 'START.WARMUP' }
        $warm.status | Should -Be 'Not selected'
        $warm.message | Should -Match 'validate\.ps1 -Area Telemetry'
        $script:order | Should -Not -Contain 'Telemetry:T1,T3,T2'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 1800 } -Times 0 -Exactly
    }

    It 'deploys Bastion with -Interactive and leaves the password to start-demo.ps1' {
        $script:state.HostPasswordUtc = '2026-10-19T15:00:00Z'
        Start-DemoEnvironment -Config $config -Interactive -SkipT3 -Confirm:$false | Out-Null
        $script:order | Should -Not -Contain 'Rotate'
        $script:order | Should -Not -Contain 'WarmT3'
        $script:order[-1] | Should -Be 'Bastion'
        $script:order | Should -Not -Contain 'Profile:T3=baseline'
    }

    It 'disables the Key Vault copy of a leftover password it rotates' {
        $vaultConfig = New-TestConfig
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        $script:state.HostPasswordUtc = '2026-10-19T15:00:00Z'
        Mock -ModuleName DbHubDemo -CommandName Disable-DemoHostPasswordSecret -MockWith { $script:order.Add('DisableSecret:' + $CheckId); New-TestResult $CheckId 'Pass' 'infra' 'T2' }
        Start-DemoEnvironment -Config $vaultConfig -SkipT3 -Confirm:$false | Out-Null
        $rotate = $script:order.IndexOf('Rotate')
        $rotate | Should -BeGreaterOrEqual 0
        $script:order[$rotate + 1] | Should -Be 'DisableSecret:START.KEYVAULT.CLEANUP'
    }

    It 'requests T4''s start with the VMs, waits for Ready before its profile, and leaves T4 alone with -SkipT4 (Phase 24)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith {
            $script:order.Add(('T4:{0}:{1}' -f $Action, $WaitMinutes))
            $after = if ($WaitMinutes -gt 0) { 'Ready' } else { 'Starting' }
            New-DemoResult -CheckId 'START.T4.START' -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 is {0}.' -f $after) -Evidence @{ stateBefore = 'Stopped'; stateAfter = $after }
        }
        $results = Start-DemoEnvironment -Config (New-TestConfig -WithT4) -Confirm:$false
        $script:order | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'T4:Start:0', 'Start:sqlvm01', 'Start:archost01', 'SourceRelease', 'T1Monitoring', 'WarmT3', 'T4:Start:15', 'Profile:T1=baseline', 'Profile:T3=baseline', 'Profile:T4=baseline', 'Profile:T2=baseline')
        ($results | Where-Object { $_.checkId -eq 'START.T4.START' }).status | Should -Be 'Pass'
        # The confirming call knows this run requested the start, so it doesn't say "was already running" (Phase 25d).
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -Times 1 -Exactly -ParameterFilter { $WaitMinutes -gt 0 -and $Requested }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -Times 1 -Exactly -ParameterFilter { $WaitMinutes -eq 0 -and -not $Requested }

        $script:order.Clear()
        $results = Start-DemoEnvironment -Config (New-TestConfig -WithT4) -SkipT4 -Confirm:$false
        $script:order | Should -Not -Contain 'T4:Start:0'
        $script:order | Should -Not -Contain 'Profile:T4=baseline'
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T4' }).status | Should -Be 'Not selected'
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T4' }).message | Should -Match '-SkipT4'
    }

    It 'doesn''t start T4''s activity when T4 isn''t Ready yet (Phase 24)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith {
            $script:order.Add(('T4:{0}:{1}' -f $Action, $WaitMinutes))
            New-DemoResult -CheckId 'START.T4.START' -Area 'infra' -Target 'T4' -Status 'Warning' -Message 'T4 is Starting, not Ready.' -Evidence @{ stateBefore = 'Stopped'; stateAfter = 'Starting' }
        }
        $results = Start-DemoEnvironment -Config (New-TestConfig -WithT4) -Confirm:$false
        $script:order | Should -Not -Contain 'Profile:T4=baseline'
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T4' }).message | Should -Match 'START\.T4\.START'
        ($results | Where-Object { $_.checkId -eq 'START.T4.START' }).status | Should -Be 'Warning'
    }
}

Describe 'Get-DemoEnvironmentStatus' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:bastion = [pscustomobject]@{ Name = 'bas-dbhub-demo'; Id = ''; HostExists = $false; ExpiresUtc = ''; PublicIpName = 'pip-dbhub-demo-bastion'; PublicIpExists = $true; Leftover = $true }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/deallocated' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3State -MockWith { [pscustomobject]@{ Exists = $true; Status = 'Paused'; ServerName = 'azuresql01-abc123'; DeploymentId = 'abc123' } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -MockWith { New-TestResult 'T1.SQLVM.MONITORING' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { New-TestResult 'T2.ARC.CONNECTED' 'Pass' 't2' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBastionInfo -MockWith { $script:bastion }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBastionHourlyPrice -MockWith { [pscustomobject]@{ Bastion = 0.19; PublicIp = 0.005; Currency = 'USD' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoMonthToDateCost -MockWith { if ((Get-Variable -Name 'ResourceGroupName' -ValueOnly -ErrorAction SilentlyContinue) -eq 'rg-dbhub-golden') { [pscustomobject]@{ Amount = 0.5; Currency = 'USD' } } else { [pscustomobject]@{ Amount = 42.5; Currency = 'USD' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @($script:golden) }
        $script:golden = @()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith { throw 'no Run Command while the VMs are deallocated' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { @() }
        # STATUS.FABRIC (Phase 26a) has its own tests (DbHubDemo.FabricResolve.Tests.ps1); here it sends nothing.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricStatus -MockWith { New-TestResult 'STATUS.FABRIC' 'Pass' 'fabric' 'fabric' }
    }

    It 'warns in STATUS.DISKS about a disk whose type drifted from the profile, and passes without one (Phase 24)' {
        $results = Get-DemoEnvironmentStatus -Config $config
        ($results | Where-Object { $_.checkId -eq 'STATUS.DISKS' }).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -Times 1 -Exactly -ParameterFilter { @($VmName) -contains 'sqlvm01' -and @($VmName) -contains 'archost01' }

        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { @([pscustomobject]@{ VmName = 'archost01'; DiskName = 'archost01-osdisk'; Kind = 'OS'; Current = 'Standard_LRS'; Expected = 'StandardSSD_LRS'; TemplateSetsType = $false }) }
        $disks = Get-DemoEnvironmentStatus -Config $config | Where-Object { $_.checkId -eq 'STATUS.DISKS' }
        $disks.status | Should -Be 'Warning'
        $disks.message | Should -Match 'archost01-osdisk \(archost01''s OS disk\) is Standard_LRS'
        $disks.message | Should -Match 'IO-heavy scenarios look worse'
        $disks.evidence.disks[0].templateSetsType | Should -BeFalse
    }

    It 'reports the T2 golden snapshot and adds the golden group to the month-to-date cost (ADR 0018)' {
        $results = Get-DemoEnvironmentStatus -Config $config
        ($results | Where-Object { $_.checkId -eq 'STATUS.T2.GOLDEN' }).status | Should -Be 'Not selected'
        ($results | Where-Object { $_.checkId -eq 'STATUS.COST' }).message | Should -Match '^Month-to-date cost: 42\.50 USD of'
        $script:golden = @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202610221306'; CapturedUtc = [datetime]'2026-10-22T13:06:00Z'; BootVerifiedUtc = [datetime]'2026-10-22T14:30:00Z'; OnboardVerifiedUtc = $null; EvalExpiresUtc = [datetime]'2027-04-19T00:00:00Z'; EvalDaysLeft = 179; SizeGiB = 128; UsedGiB = 37 })
        $results = Get-DemoEnvironmentStatus -Config $config
        $golden = $results | Where-Object { $_.checkId -eq 'STATUS.T2.GOLDEN' }
        $golden.status | Should -Be 'Pass'
        $golden.message | Should -Match 'in 179 days'
        ($results | Where-Object { $_.checkId -eq 'STATUS.COST' }).message | Should -Match '43\.00 USD \(42\.50 in rg-dbhub-demo, 0\.50 in rg-dbhub-golden\)'
    }

    It 'reports a leftover Bastion public IP as a Warning with its hourly list price' {
        $results = Get-DemoEnvironmentStatus -Config $config -NowUtc ([datetime]::new(2026, 10, 21, 2, 0, 0, [System.DateTimeKind]::Utc))
        $bastion = $results | Where-Object { $_.checkId -eq 'STATUS.BASTION' }
        $bastion.status | Should -Be 'Warning'
        $bastion.message | Should -Match 'pip-dbhub-demo-bastion is left over'
        $bastion.message | Should -Match '0\.005 USD per hour'
        $bastion.remediation | Should -Match 'stop-demo\.ps1 -RemoveBastionOnly'
        $bastion.evidence.hourlyUsd | Should -Be 0.005
    }

    It 'prices a Bastion host with its public IP, and passes when neither exists' {
        $script:bastion = [pscustomobject]@{ Name = 'bas-dbhub-demo'; Id = '/x'; HostExists = $true; ExpiresUtc = '2026-10-21T03:00:00Z'; PublicIpName = 'pip-dbhub-demo-bastion'; PublicIpExists = $true; Leftover = $false }
        $results = Get-DemoEnvironmentStatus -Config $config
        ($results | Where-Object { $_.checkId -eq 'STATUS.BASTION' }).message | Should -Match '0\.195 USD per hour'
        $script:bastion = [pscustomobject]@{ Name = 'bas-dbhub-demo'; Id = ''; HostExists = $false; ExpiresUtc = ''; PublicIpName = 'pip-dbhub-demo-bastion'; PublicIpExists = $false; Leftover = $false }
        ($results = Get-DemoEnvironmentStatus -Config $config) | Out-Null
        ($results | Where-Object { $_.checkId -eq 'STATUS.BASTION' }).status | Should -Be 'Pass'
    }

    It 'covers the plan''s status items, read-only, and every result follows the schema' {
        $results = Get-DemoEnvironmentStatus -Config $config
        foreach ($id in 'STATUS.DEPLOYMENT', 'STATUS.VM_SQLVM01', 'STATUS.VM_ARCHOST01', 'STATUS.T3', 'T1.SQLVM.ASSOCIATEDSERVICES', 'T2.ARC.CONNECTED', 'STATUS.BASTION', 'STATUS.COST', 'STATUS.SHUTDOWN') {
            @($results | Where-Object { $_.checkId -eq $id }).Count | Should -Be 1 -Because $id
        }
        ($results | Where-Object { $_.checkId -eq 'STATUS.VM_SQLVM01' }).area | Should -Be 't1'
        ($results | Where-Object { $_.checkId -eq 'STATUS.T3' }).message | Should -Match 'Paused'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -Times 0 -Exactly -Because 'T1 is deallocated'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 0 -Exactly
    }

    It 'reads the active profile on T1 and T3 while sqlvm01 runs, from T1 only' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ status = 'Pass'; state = 'Ready'; message = 'ok' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $record = [pscustomobject]@{ target = $Target; name = 'off'; description = 'off (no activity)'; expiresAt = $null; setBy = 'stop-demo'; setAt = '2026-10-20T23:00:00Z' }
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @($record); Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
        $results = Get-DemoEnvironmentStatus -Config $config
        ($results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T3' }).message | Should -Be 'T3: activity profile off (no activity)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 2 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'profile' -and $ArgumentList[1] -eq 'get' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -Times 1 -Exactly
    }

    It 'reads profile get''s JSON object and takes on a stalled host lane''s status' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ status = 'Pass'; state = 'Ready'; message = 'ok' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $hostStatus = if ($Target -eq 'T1') { 'Warning' } else { 'Pass' }
            $stdout = '{{ "target": "{0}", "name": "baseline", "description": "baseline (active until 2026-10-23T22:58:00Z; set by deploy at 2026-10-23T19:33:49Z)", "setBy": "deploy", "host": {{ "status": "{1}", "message": "The {0} lane hasn''t finished a poll for 6 min (reading the profile since 2026-10-23T20:06:18Z); the host''s supervisor replaces it.", "lane": {{ "state": "Serving" }} }} }}' -f $Target, $hostStatus
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @($stdout | ConvertFrom-Json); StdOut = $stdout; Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
        $results = Get-DemoEnvironmentStatus -Config $config
        $t1 = $results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T1' }
        $t1.status | Should -Be 'Warning'
        $t1.message | Should -Match '^T1: activity profile baseline \(active until .*\) Profile host: The T1 lane hasn''t finished a poll'
        $t1.evidence.host.laneState | Should -Be 'Serving'
        $t1.remediation | Should -Match 'WORKLOAD.T1.HOST'
        $t3 = $results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T3' }
        $t3.status | Should -Be 'Pass'
        $t3.message | Should -Not -Match 'Profile host'
    }

    It 'shows a running T4''s Azure Monitor metrics with the enhanced ones in STATUS.T4 (Phase 24)' {
        $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $true; State = 'Ready'; Server = $null; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -MockWith {
            [pscustomobject]@{
                Succeeded = $true; Error = ''; Minutes = 15; LatestUtc = '2026-10-23T20:00:00.0000000Z'
                Latest = [ordered]@{ cpu_percent = 97; memory_percent = 41; active_connections = 12; longest_transaction_time_sec = 75; deadlocks = 1 }
                ByState = [ordered]@{ active = 3; 'idle in transaction' = 2 }
                ByWaitEventType = [ordered]@{ Lock = 4; IO = 0 }
            }
        }
        $results = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4)
        $t4 = $results | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Pass'
        $t4.message | Should -Match '^pgflex01-abc123 is running: CPU 97%; memory 41%; 12 active connection\(s\); sessions active 3, idle in transaction 2; waiting on Lock 4; oldest transaction 75 s; 1 deadlock'
        $t4.message | Should -Not -Match 'IO 0'
        $t4.evidence.sessionsByWaitEventType.Lock | Should -Be 4
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -Times 1 -Exactly -ParameterFilter { $Minutes -eq 15 }
    }

    It 'says when a stopped T4 starts on its own, and warns within a day of it (Phase 24)' {
        $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $true; State = 'Stopped'; Server = $null; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4StoppedUtc -MockWith { [datetime]::new(2026, 10, 20, 23, 0, 0, [System.DateTimeKind]::Utc) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -MockWith { throw 'a stopped server sends no fresh metrics' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { 0.178 }
        $results = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) -NowUtc ([datetime]::new(2026, 10, 21, 2, 0, 0, [System.DateTimeKind]::Utc))
        $t4 = $results | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Pass'
        $t4.message | Should -BeLike 'pgflex01-abc123 is stopped since 2026-10-20 23:00 UTC; it starts on its own at 2026-10-27 23:00 UTC unless it''s stopped again before then.*'
        $t4.message | Should -Match 'It then bills compute at about 0\.18 USD an hour \(Standard_B1ms, list price\) until it''s stopped, unless a scheduled daily stop of T4 stops it first\.'
        ([datetime]$t4.evidence.autoStartUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be '2026-10-27T23:00'
        $t4.evidence.hourlyUsd | Should -Be 0.178

        $results = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) -NowUtc ([datetime]::new(2026, 10, 27, 5, 0, 0, [System.DateTimeKind]::Utc))
        $t4 = $results | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Warning'
        $t4.remediation | Should -Match 'stop-demo\.ps1'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -Times 0 -Exactly
    }
}

Describe 'Get-DemoEnvironmentStatus with the runner''s own profile get output' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:bastion = [pscustomobject]@{ Name = 'bas-dbhub-demo'; Id = ''; HostExists = $false; ExpiresUtc = ''; PublicIpName = 'pip-dbhub-demo-bastion'; PublicIpExists = $true; Leftover = $true }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3State -MockWith { [pscustomobject]@{ Exists = $true; Status = 'Paused'; ServerName = 'azuresql01-abc123'; DeploymentId = 'abc123' } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmAssociatedService -MockWith { New-TestResult 'T1.SQLVM.ASSOCIATEDSERVICES' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -MockWith { New-TestResult 'T1.SQLVM.MONITORING' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { New-TestResult 'T2.ARC.CONNECTED' 'Pass' 't2' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBastionInfo -MockWith { $script:bastion }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBastionHourlyPrice -MockWith { [pscustomobject]@{ Bastion = 0.19; PublicIp = 0.005; Currency = 'USD' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoMonthToDateCost -MockWith { if ((Get-Variable -Name 'ResourceGroupName' -ValueOnly -ErrorAction SilentlyContinue) -eq 'rg-dbhub-golden') { [pscustomobject]@{ Amount = 0.5; Currency = 'USD' } } else { [pscustomobject]@{ Amount = 42.5; Currency = 'USD' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @($script:golden) }
        $script:golden = @()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ status = 'Pass'; state = 'Ready'; message = 'ok' } }
        # Only the Run Command transport is faked: Invoke-DemoWorkloadCommand parses the runner's output itself.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadAction -MockWith {
            # 'profile get --json' as the runner writes it (Cli/CommandLine.cs): one JSON object, not an array, with a
            # bracket inside a string, as the lane's last error can have.
            $document = [ordered]@{
                target      = $Request['target']
                store       = 'file C:\ProgramData\DbHubDemo\Workload\profile.json'
                name        = 'baseline'
                setAt       = '2026-10-26T14:55:02Z'
                setBy       = 'start-demo'
                expiresAt   = '2026-10-26T23:00:00Z'
                parameters  = [ordered]@{ durationSeconds = 900; concurrency = 4; intensity = 2 }
                description = 'baseline (active until 2026-10-26T23:00:00Z; set by start-demo at 2026-10-26T14:55:02Z)'
                host        = [ordered]@{
                    status  = 'Pass'
                    message = ('The {0} lane finished a poll 4 s ago.' -f $Request['target'])
                    lane    = [ordered]@{ state = 'Serving'; generation = 2; restarts = 1; lastRestartReason = 'stalled'; operation = 'poll'; consecutiveFailures = 0; lastError = 'Execution Timeout Expired [poll 412]'; runningRuns = 2 }
                }
            }
            @{ marker = 'DBHUBDEMO-WORKLOAD'; action = 'Runner'; status = 'Pass'; message = 'profile get: Pass'; evidence = @{ exitCode = 0; stdout = ($document | ConvertTo-Json -Depth 8 -Compress); stderr = '' } }
        }
    }

    It 'reads each target''s profile from profile get''s single JSON object, which read as "couldn''t be read" before' {
        $results = Get-DemoEnvironmentStatus -Config $config
        foreach ($target in 'T1', 'T3') {
            $read = $results | Where-Object { $_.checkId -eq ('STATUS.PROFILE_{0}' -f $target) }
            $read.status | Should -Be 'Pass' -Because $target
            $read.message | Should -Match ('^{0}: activity profile baseline \(active until 2026-10-26T23:00:00Z' -f $target)
            $read.evidence.name | Should -Be 'baseline'
            $read.evidence.host.laneState | Should -Be 'Serving'
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadAction -Times 2 -Exactly -ParameterFilter { $Action -eq 'Runner' -and $Request['arguments'][0] -eq 'profile' -and $Request['arguments'][1] -eq 'get' }
    }
}
Describe 'Remove-DemoEnvironment' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:groupExists = $true
        $script:expiresOn = ''
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $script:groupExists }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ expiresOn = $script:expiresOn } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith {
            if ($Url -match 'sqlServerInstances') {
                @([pscustomobject]@{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.AzureArcData/sqlServerInstances/arcsql01'; name = 'arcsql01' })
            }
            else {
                @([pscustomobject]@{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01'; name = 'arcsql01' })
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoArmResource -MockWith { $script:order.Add($(if ($Url -match 'sqlServerInstances') { 'Instance' } else { 'Machine' })); $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { [pscustomobject]@{ DeploymentId = 'abc123'; Principals = @() } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoTeardownResidue -MockWith { $script:order.Add('Residue'); New-TestResult 'TEARDOWN.RESIDUAL.ARC' 'Pass' 'teardown' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $script:order.Add('az ' + ($ArgumentList[0..1] -join ' '))
            $script:groupExists = $false
            New-AzResult
        }
    }

    It 'deletes the Arc SQL instances, then the Arc machines, then the resource group, then the deployment record and the budget, and checks for residue' {
        $results = Remove-DemoEnvironment -Config $config -Confirm:$false
        $script:order | Should -Be @('az vm show', 'Instance', 'Machine', 'az group delete', 'az deployment sub', 'az deployment sub', 'az rest --method', 'az rest --method', 'Residue')
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESOURCEGROUP' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.ARC.SQLINSTANCES' }).area | Should -Be 'teardown'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.RESIDUAL' }).status | Should -Be 'Pass'
    }

    It 'removes T4 with the resource group whether t4Enabled is on or off, so its private DNS zone and link never outlive a destroy (Phase 24)' {
        # Live, 2026-10-26: T4 was refused, and the template had already created its private DNS zone and VNet link,
        # which stay (about 0.50 USD a month) while t4Enabled is false; the group delete removes them with the rest.
        foreach ($t4 in $true, $false) {
            $script:order.Clear()
            $script:groupExists = $true
            Remove-DemoEnvironment -Config (New-TestConfig -WithT4:$t4) -Confirm:$false | Out-Null
            $script:order | Should -Contain 'az group delete' -Because "t4Enabled is $t4"
            @($script:order | Where-Object { $_ -match 'postgres|network private-dns' }).Count | Should -Be 0 -Because 'nothing T4-specific is deleted by hand; the group goes as a whole'
            $script:order[-1] | Should -Be 'Residue' -Because 'the residual check covers anything left in the group or carrying its tags'
        }
    }

    It 'deletes every Arc resource when the collection comes back as one array, as Get-DemoArmCollection returns it (live finding, 2026-10-22)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith {
            $type = if ($Url -match 'sqlServerInstances') { 'Microsoft.AzureArcData/sqlServerInstances' } else { 'Microsoft.HybridCompute/machines' }
            , @(
                [pscustomobject]@{ id = ('/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/{0}/arcsql01' -f $type); name = 'arcsql01' }
                [pscustomobject]@{ id = ('/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/{0}/sqlvm01' -f $type); name = 'sqlvm01' }
            )
        }
        $results = Remove-DemoEnvironment -Config $config -Confirm:$false
        @($script:order | Where-Object { $_ -eq 'Instance' }).Count | Should -Be 2
        @($script:order | Where-Object { $_ -eq 'Machine' }).Count | Should -Be 2
        ($results | Where-Object { $_.checkId -eq 'DESTROY.ARC.SQLINSTANCES' }).message | Should -Be 'Deleted 2 of 2 Microsoft.AzureArcData/sqlServerInstances resource(s).'
    }

    It 'deletes nothing with -IfExpired before the expiry date or without one' {
        $now = [datetime]::new(2026, 10, 21, 6, 30, 0, [System.DateTimeKind]::Utc)
        foreach ($expiry in '', '2026-10-21', '2026-12-31') {
            $script:expiresOn = $expiry
            $results = Remove-DemoEnvironment -Config $config -IfExpired -NowUtc $now -Confirm:$false
            ($results | Where-Object { $_.checkId -eq 'DESTROY.EXPIRY' }).status | Should -Be 'Not selected' -Because "expiresOn is '$expiry'"
        }
        $script:order.Count | Should -Be 0
    }

    It 'destroys with -IfExpired after the expiry date' {
        $script:expiresOn = '2026-10-20'
        $results = Remove-DemoEnvironment -Config $config -IfExpired -NowUtc ([datetime]::new(2026, 10, 21, 6, 30, 0, [System.DateTimeKind]::Utc)) -Confirm:$false
        ($results | Where-Object { $_.checkId -eq 'DESTROY.EXPIRY' }).status | Should -Be 'Pass'
        $script:order | Should -Contain 'az group delete'
        $script:order[-1] | Should -Be 'Residue'
    }
}

Describe 'Invoke-DemoControl' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:t2Message = ''
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:calls.Add([pscustomobject]@{ Target = $Target; Arguments = ($ArgumentList -join ' ') })
            if ($Target -eq 'T2' -and $script:t2Message) {
                return [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Records = @(); Result = (New-DemoResult -CheckId 'WORKLOAD.T2.COMMAND' -Area 'workload' -Target 'T2' -Status 'Fail' -Message $script:t2Message) }
            }
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @(); Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
    }

    It 'maps the workflow inputs to profile set on every target, ending before the auto-shutdown' {
        $results = Invoke-DemoControl -Config $config -Target all -Scenario business-day -DurationMinutes 45 -Concurrency 4 -Intensity 7 -ResetBefore $true -AutoCleanup $false -Confirm:$false
        $script:calls.Target | Should -Be @('T1', 'T2', 'T3')
        $script:calls[0].Arguments | Should -Be 'profile set --name business-day --duration 45m --not-after {{NEXT_SHUTDOWN}} --concurrency 4 --intensity 7 --reset-before --no-auto-cleanup --requested-by demo-control'
        @($results | Where-Object { $_.checkId -like 'CONTROL.T*' }).Count | Should -Be 3
    }

    It 'leaves out the scenario''s defaults and the end time for off' {
        Invoke-DemoControl -Config $config -Target T3 -Scenario off -Confirm:$false | Out-Null
        $script:calls[0].Arguments | Should -Be 'profile set --name off --requested-by demo-control'
    }

    It 'runs an incident on all on the scenario''s default target' {
        $scenario = Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'scenarios') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'scenario.json') } | Select-Object -First 1
        $default = @((Get-Content -LiteralPath (Join-Path -Path $scenario.FullName -ChildPath 'scenario.json') -Raw | ConvertFrom-Json).targets.default)[0]
        Invoke-DemoControl -Config $config -Target all -Scenario ('incident:' + $scenario.Name) -DurationMinutes 10 -Confirm:$false | Out-Null
        $script:calls.Count | Should -Be 1
        $script:calls[0].Target | Should -Be $default
    }

    It 'fails an unknown scenario without a Run Command, and reports a T2 guest without the runner as a Warning' {
        (Invoke-DemoControl -Config $config -Target T1 -Scenario 'incident:no-such-scenario' -Confirm:$false | Where-Object { $_.checkId -eq 'CONTROL.REQUEST' }).status | Should -Be 'Fail'
        $script:calls.Count | Should -Be 0
        $script:t2Message = 'The workload runner is not installed in the guest yet.'
        (Invoke-DemoControl -Config $config -Target T2 -Scenario baseline -Confirm:$false | Where-Object { $_.checkId -eq 'CONTROL.T2' }).status | Should -Be 'Warning'
    }
}

Describe 'Initialize-DemoGitHubOidc' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            $script:azCalls.Add($text)
            if ($text -like 'identity create*') {
                return (New-AzResult -StdOut '{"clientId":"aaaaaaaa-1111-2222-3333-444444444444","principalId":"bbbbbbbb-1111-2222-3333-444444444444"}')
            }
            if ($text -like 'identity federated-credential show*') {
                return (New-AzResult -ExitCode 3 -StdErr 'ERROR: (NotFound) The federated credential was not found.')
            }
            return (New-AzResult -StdOut '{}')
        }
    }

    It 'creates the identity in the control resource group and trusts the GitHub environment, without a role assignment by default' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository 'contoso/dbhub-demo' -Environment demo -Confirm:$false
        $script:azCalls[0] | Should -BeLike 'group create --name rg-dbhub-control*'
        $credential = $script:azCalls | Where-Object { $_ -like 'identity federated-credential create*' }
        $credential | Should -Match '--issuer https://token\.actions\.githubusercontent\.com'
        $credential | Should -Match '--subject repo:contoso/dbhub-demo:environment:demo'
        $credential | Should -Match '--audiences api://AzureADTokenExchange'
        @($script:azCalls | Where-Object { $_ -like 'role assignment*' }).Count | Should -Be 0
        $role = $results | Where-Object { $_.checkId -eq 'OIDC.ROLE' }
        $role.status | Should -Be 'Manual action required'
        $role.remediation | Should -Match 'az role assignment create --assignee-object-id bbbbbbbb-1111-2222-3333-444444444444 --assignee-principal-type ServicePrincipal --role Contributor'
        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB' }).remediation | Should -Match 'gh secret set AZURE_CLIENT_ID --env demo --repo contoso/dbhub-demo'
    }

    It 'assigns the role itself only with -AssignRole' {
        Initialize-DemoGitHubOidc -Config $config -Repository 'contoso/dbhub-demo' -Environment demo -AssignRole -Confirm:$false | Out-Null
        @($script:azCalls | Where-Object { $_ -like 'role assignment create*--role Contributor*' }).Count | Should -Be 1
    }

    It 'asks to add the identity to keyVault.operatorObjectIds only with the Key Vault opt-in' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository 'contoso/dbhub-demo' -Environment demo -Confirm:$false
        @($results | Where-Object { $_.checkId -eq 'OIDC.KEYVAULT' }).Count | Should -Be 0
        $vaultConfig = New-TestConfig
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        $results = Initialize-DemoGitHubOidc -Config $vaultConfig -Repository 'contoso/dbhub-demo' -Environment demo -Confirm:$false
        $keyVault = $results | Where-Object { $_.checkId -eq 'OIDC.KEYVAULT' }
        $keyVault.status | Should -Be 'Manual action required'
        $keyVault.remediation | Should -Match 'bbbbbbbb-1111-2222-3333-444444444444 to keyVault\.operatorObjectIds'
        $vaultConfig['keyVault']['operatorObjectIds'] = @('BBBBBBBB-1111-2222-3333-444444444444')
        @(Initialize-DemoGitHubOidc -Config $vaultConfig -Repository 'contoso/dbhub-demo' -Environment demo -Confirm:$false | Where-Object { $_.checkId -eq 'OIDC.KEYVAULT' }).Count | Should -Be 0
    }

    It 'needs a repository' {
        (Initialize-DemoGitHubOidc -Config $config -Confirm:$false | Where-Object { $_.checkId -eq 'OIDC.REPOSITORY' }).status | Should -Be 'Fail'
        $script:azCalls.Count | Should -Be 0
    }
}

Describe 'Write-DemoResultReport' {
    It 'lists the manual steps last and writes the GitHub job summary' {
        $summary = Join-Path -Path $TestDrive -ChildPath 'summary.md'
        $previous = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = $summary
        try {
            $results = @(
                New-TestResult 'DEPLOY.STAGE.T3'
                New-DemoResult -CheckId 'T2.PAYGWIZARD' -Area 't2' -Target 'T2' -Status 'Manual action required' -Message 'The wizard waits | here.' -Remediation 'Open Bastion and run the wizard.'
            )
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
            Write-DemoResultReport -Result $results -Title 'deploy.ps1' 6>$null
        }
        finally {
            $env:GITHUB_STEP_SUMMARY = $previous
        }
        $text = Get-Content -LiteralPath $summary -Raw
        $text | Should -Match '## deploy\.ps1'
        $text | Should -Match '\| T2\.PAYGWIZARD \| Manual action required \| The wizard waits \\\| here\. \|'
        $text | Should -Match '### Manual action required'
        $text | Should -Match '\*\*T2\.PAYGWIZARD:\*\* Open Bastion and run the wizard\.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'T2.PAYGWIZARD: Open Bastion' }
    }
}

Describe 'Run Command waits and a VM that isn''t running (R49)' {
    It 'recognizes the deallocated-VM error and nothing else' {
        & (Get-Module -Name DbHubDemo) {
            Test-DemoAzVmNotRunning -Text "ERROR: (OperationNotAllowed) Operation 'Run Command' is not allowed on VM 'archost01' since the VM is deallocated." | Should -BeTrue
            Test-DemoAzVmNotRunning -Text 'ERROR: Cannot run command on a VM that is not running.' | Should -BeTrue
            Test-DemoAzVmNotRunning -Text 'ERROR: (Conflict) Run command extension execution is in progress.' | Should -BeFalse
            Test-DemoAzVmNotRunning -Text 'ERROR: (AllocationFailed) Allocation failed. Please try deallocating the VM later.' | Should -BeFalse
            Test-DemoAzVmNotRunning -Text '' | Should -BeFalse
        }
    }

    It 'waits about 12.5 minutes on a busy extension, and not at all on a deallocated VM' {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -ExitCode 1 -StdErr 'ERROR: (Conflict) Another operation is in progress: MDE.Windows is being updated.' }
        $busy = & (Get-Module -Name DbHubDemo) { Invoke-DemoAzWithConflictRetry -SubscriptionId '11111111-2222-3333-4444-555555555555' -ArgumentList @('vm', 'start', '--name', 'archost01') -Label 'test' }
        $busy.ExitCode | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 10 -Exactly
        $waited = 0
        foreach ($attempt in 1..9) {
            $waited += & (Get-Module -Name DbHubDemo) { param($n) Get-DemoConflictDelay -Attempt $n } $attempt
        }
        $waited | Should -Be 750
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'MDE\.Windows' }

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -ExitCode 1 -StdErr "ERROR: (OperationNotAllowed) Operation 'Run Command' is not allowed on VM 'archost01' since the VM is deallocated." }
        $stopped = & (Get-Module -Name DbHubDemo) { Invoke-DemoAzWithConflictRetry -SubscriptionId '11111111-2222-3333-4444-555555555555' -ArgumentList @('rest', '--method', 'put', '--url', 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01/runCommands/x?api-version=2025-11-01') -Label 'test' }
        $stopped.ExitCode | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'put' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'start-demo\.ps1' }
    }

    It 'says the VM must be started when a managed Run Command meets a deallocated VM' {
        $config = New-TestConfig
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoRunCommand -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -ExitCode 1 -StdErr "ERROR: (OperationNotAllowed) Operation 'Run Command' is not allowed on VM 'archost01' since the VM is deallocated." }
        { Invoke-DemoVmRunCommand -Config $config -VmName archost01 -RunCommandName 'DbHubDemo-Test' -Script 'Write-Output 1' -Confirm:$false } | Should -Throw '*Start it first*'
    }

    It 'stops a deallocated VM''s chunk delivery at once instead of retrying' {
        $config = New-TestConfig
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Clear-DemoChunkRunCommand -MockWith { 0 }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult -ExitCode 1 -StdErr "ERROR: (OperationNotAllowed) Operation 'Run Command' is not allowed on VM 'sqlvm01' since the VM is deallocated." }
        $zip = Join-Path -Path $TestDrive -ChildPath 'bundle.zip'
        [System.IO.File]::WriteAllBytes($zip, [byte[]](1..64))
        $bundle = [pscustomobject]@{ Path = $zip; Sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant(); SizeBytes = 64 }
        { Send-DemoBootstrapBundle -Config $config -Bundle $bundle -VmName sqlvm01 -Confirm:$false } | Should -Throw '*start it first*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly
    }
}

Describe 'Invoke-DemoVmPowerAction' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:states = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { if ($script:states.Count -gt 1) { $script:states.Dequeue() } else { $script:states.Peek() } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { New-AzResult }
    }

    It 'waits for an auto-shutdown that''s still deallocating before it starts the VM' {
        foreach ($state in 'PowerState/deallocating', 'PowerState/deallocated', 'PowerState/starting', 'PowerState/running') {
            $script:states.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoVmPowerAction -Config $c -VmName 'archost01' -Action Start -PollSeconds 1 } $config
        $result.checkId | Should -Be 'START.VM_ARCHOST01'
        $result.status | Should -Be 'Pass'
        $result.target | Should -Be 'T2'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'start' -and $ArgumentList -contains '--no-wait' }
    }

    It 'doesn''t touch a VM that''s already in the wanted state' {
        $script:states.Enqueue('PowerState/deallocated')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoVmPowerAction -Config $c -VmName 'sqlvm01' -Action Deallocate } $config
        $result.status | Should -Be 'Pass'
        $result.target | Should -Be 'T1'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -Times 0 -Exactly
    }

    It 'says a running VM was started by this run when the caller requested its start, and "already running" otherwise (Phase 25d)' {
        # Live, 2026-10-27: both VMs were deallocated, start-demo.ps1 requested both starts, and by the time each was
        # checked it was running, so the results said "already running".
        $script:states.Enqueue('PowerState/running')
        $requested = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoVmPowerAction -Config $c -VmName 'sqlvm01' -Action Start -StartRequested } $config
        $requested.status | Should -Be 'Pass'
        $requested.message | Should -Be 'sqlvm01 is running; this start requested it.'
        $requested.evidence.startRequested | Should -BeTrue
        $already = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoVmPowerAction -Config $c -VmName 'sqlvm01' -Action Start } $config
        $already.message | Should -Be 'sqlvm01 is already running.'
        $already.evidence.startRequested | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -Times 0 -Exactly
    }

    It 'waits for a VM that shows no power state right after its start request, instead of calling it missing' {
        # Live, 2026-10-22: sqlvm01's instance view had no PowerState status just after 'az vm start --no-wait'.
        foreach ($state in '', '', 'PowerState/starting', 'PowerState/running') {
            $script:states.Enqueue($state)
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show ' } -MockWith { New-AzResult -StdOut '/subscriptions/x/resourceGroups/rg-dbhub-test/providers/Microsoft.Compute/virtualMachines/sqlvm01' }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoVmPowerAction -Config $c -VmName 'sqlvm01' -Action Start -PollSeconds 1 } $config
        $result.checkId | Should -Be 'START.VM_SQLVM01'
        $result.status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show ' }
    }

    It 'reports a VM that Azure says doesn''t exist as missing, without starting anything' {
        $script:states.Enqueue('')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show ' } -MockWith { New-AzResult -ExitCode 3 -StdErr "(ResourceNotFound) The Resource 'Microsoft.Compute/virtualMachines/sqlvm01' under resource group 'rg-dbhub-test' was not found." }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoVmPowerAction -Config $c -VmName 'sqlvm01' -Action Start -PollSeconds 1 } $config
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'wasn''t found'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -Times 0 -Exactly
    }
}

Describe 'Set-DemoTargetProfile' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:attempts = 0
        $script:failFirst = 0
        $script:message = 'profile set: Pass'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:attempts++
            $script:arguments = $ArgumentList -join ' '
            $status = if ($script:attempts -le $script:failFirst) { 'Fail' } else { 'Pass' }
            [pscustomobject]@{ Status = $status; ExitCode = $(if ($status -eq 'Pass') { 0 } else { 1 }); Records = @(); Result = (New-DemoResult -CheckId ('WORKLOAD.{0}.COMMAND' -f $Target) -Area 'workload' -Target $Target -Status $status -Message $script:message) }
        }
    }

    It 'sets a profile until the next auto-shutdown, and off without an end' {
        $set = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T3 -ProfileName baseline -CheckPrefix START -RequestedBy 'start-demo' } $config
        $set.checkId | Should -Be 'START.PROFILE_T3'
        $set.status | Should -Be 'Pass'
        $set.message | Should -Match 'stays awake and bills compute'
        $script:arguments | Should -Be 'profile set --name baseline --requested-by start-demo --not-after {{NEXT_SHUTDOWN}}'
        & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName off -CheckPrefix STOP } $config | Out-Null
        $script:arguments | Should -Be 'profile set --name off --requested-by DbHubDemo'
    }

    It 'reports Not selected for a target it was told to skip, without a Run Command' {
        $skipped = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName off -CheckPrefix STOP -SkipReason 'sqlvm01 isn''t running.' } $config
        $skipped.status | Should -Be 'Not selected'
        $script:attempts | Should -Be 0
    }

    It 'retries, then reports a Warning, never a Fail; a guest without the runner is Not selected' {
        $script:failFirst = 1
        $retried = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 1 } $config
        $retried.status | Should -Be 'Pass'
        $script:attempts | Should -Be 2

        $script:attempts = 0
        $script:failFirst = 9
        $script:message = 'runner exited with code 1'
        (& (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName baseline -CheckPrefix START } $config).status | Should -Be 'Warning'

        $script:message = 'The workload runner is not installed in the guest yet.'
        (& (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName off -CheckPrefix STOP } $config).status | Should -Be 'Not selected'
    }
}

Describe 'Test-DemoStartCost' {
    BeforeAll {
        $config = New-TestConfig
        $config['monthlyCeilingUsd'] = 250
    }

    BeforeEach {
        $script:actual = [pscustomobject]@{ Amount = 100.0; Currency = 'USD' }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDefenderPlan -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith {
            [pscustomobject]@{ SessionCost = 12.5; Results = @((New-TestResult 'PREFLIGHT.COST.SESSION' 'Pass' 'preflight'), (New-TestResult 'PREFLIGHT.COST.MONTHLY' 'Pass' 'preflight'), (New-TestResult 'PREFLIGHT.COST.DEFENDER' 'Pass' 'preflight')) }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoMonthToDateCost -MockWith { $script:actual }
    }

    It 'checks the estimate against both ceilings and the month''s actual cost: <Name>' -ForEach @(
        @{ Name = 'well under'; Amount = 100.0; Currency = 'USD'; Expected = 'Pass' }
        @{ Name = 'a session crosses it'; Amount = 240.0; Currency = 'USD'; Expected = 'Warning' }
        @{ Name = 'already reached'; Amount = 251.0; Currency = 'USD'; Expected = 'Fail' }
        @{ Name = 'another currency'; Amount = 300.0; Currency = 'EUR'; Expected = 'Warning' }
    ) {
        $script:actual = [pscustomobject]@{ Amount = $Amount; Currency = $Currency }
        $results = & (Get-Module -Name DbHubDemo) { param($c) Test-DemoStartCost -Config $c -NetworkMode private -T3UseFreeLimit $false } $config
        @($results.checkId) | Should -Be @('PREFLIGHT.COST.SESSION', 'PREFLIGHT.COST.MONTHLY', 'START.COST.ACTUAL')
        ($results | Where-Object { $_.checkId -eq 'START.COST.ACTUAL' }).status | Should -Be $Expected
    }

    It 'warns when Cost Management can''t be read' {
        $script:actual = $null
        $results = & (Get-Module -Name DbHubDemo) { param($c) Test-DemoStartCost -Config $c -NetworkMode public -T3UseFreeLimit $null } $config
        ($results | Where-Object { $_.checkId -eq 'START.COST.ACTUAL' }).status | Should -Be 'Warning'
    }
}

Describe 'Reset-DemoWorkload' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:power = 'PowerState/running'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01') } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT3State -MockWith { [pscustomobject]@{ Exists = $true; Status = 'Online'; ServerName = 'azuresql01-abc123'; DeploymentId = 'abc123' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:calls.Add([pscustomobject]@{ Target = $Target; Arguments = ($ArgumentList -join ' '); Timeout = $TimeoutSeconds })
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @(); Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
    }

    It 'resets every target with the runner, reseeding on request' {
        $results = Reset-DemoWorkload -Config $config -Reseed -UndoRemediation -Confirm:$false
        $script:calls.Target | Should -Be @('T1', 'T3', 'T2')
        $script:calls[0].Arguments | Should -Be 'reset --json --requested-by reset-demo --reseed --undo-remediation'
        $script:calls[0].Timeout | Should -Be 3600
        ($results | Where-Object { $_.checkId -eq 'RESET.T1' }).message | Should -Match 'activity profile is off'
    }

    It 'skips targets whose VM isn''t running, and doesn''t support rebuilding the guest yet' {
        $script:power = 'PowerState/deallocated'
        $results = Reset-DemoWorkload -Config $config -RebuildGuest -Confirm:$false
        $script:calls.Count | Should -Be 0
        ($results | Where-Object { $_.checkId -eq 'RESET.GUEST' }).status | Should -Be 'Not supported'
        ($results | Where-Object { $_.checkId -eq 'RESET.T1' }).status | Should -Be 'Not selected'
    }
}

Describe 'Get-DemoNextShutdownUtc' {
    It 'computes the next auto-shutdown from the configured time and Windows time zone' {
        $config = New-TestConfig
        $config['autoShutdownTime'] = '1900'
        $config['autoShutdownTimeZone'] = 'Eastern Standard Time'
        $before = & (Get-Module -Name DbHubDemo) { param($c) Get-DemoNextShutdownUtc -Config $c -NowUtc ([datetime]::new(2026, 10, 20, 20, 0, 0, [System.DateTimeKind]::Utc)) } $config
        $before | Should -Be ([datetime]::new(2026, 10, 20, 23, 0, 0, [System.DateTimeKind]::Utc))
        $after = & (Get-Module -Name DbHubDemo) { param($c) Get-DemoNextShutdownUtc -Config $c -NowUtc ([datetime]::new(2026, 10, 20, 23, 30, 0, [System.DateTimeKind]::Utc)) } $config
        $after | Should -Be ([datetime]::new(2026, 10, 21, 23, 0, 0, [System.DateTimeKind]::Utc))
    }
}

Describe 'Test-DemoSqlVmMonitoringStuck' {
    BeforeAll {
        function New-MonitoringResult([string] $Status, [string] $Provisioning = 'Succeeded', [bool] $Flag = $true, [string] $Plugin = 'NotRunning', [string] $Power = 'PowerState/running') {
            [pscustomobject]@{ checkId = 'T1.SQLVM.MONITORING'; status = $Status; evidence = [ordered]@{ provisioningState = $Provisioning; featureFlagEnabled = $Flag; pluginState = $Plugin; powerState = $Power; pending = $true } }
        }
    }

    It 'is true only for a running VM whose Succeeded extension has the flag while the plugin isn''t Running (Phase 25d)' {
        $stuck = { param($r) & (Get-Module -Name DbHubDemo) { param($x) Test-DemoSqlVmMonitoringStuck -Result $x } $r }
        & $stuck (New-MonitoringResult 'Warning') | Should -BeTrue
        & $stuck (New-MonitoringResult 'Warning' -Plugin '') | Should -BeTrue
        & $stuck (New-MonitoringResult 'Warning' -Power '') | Should -BeTrue
        & $stuck (New-MonitoringResult 'Warning' -Provisioning 'Updating') | Should -BeFalse -Because 'a template deployment keeps the extension Updating: a wait, not a restart'
        & $stuck (New-MonitoringResult 'Warning' -Flag $false) | Should -BeFalse
        & $stuck (New-MonitoringResult 'Warning' -Plugin 'Running') | Should -BeFalse -Because 'a Running plugin without OK uploads yet is still starting'
        & $stuck (New-MonitoringResult 'Warning' -Power 'PowerState/deallocated') | Should -BeFalse
        & $stuck (New-MonitoringResult 'Pass' -Plugin 'Running') | Should -BeFalse
        & $stuck (New-MonitoringResult 'Fail') | Should -BeFalse
        & $stuck $null | Should -BeFalse
    }
}

Describe 'Restore-DemoSqlVmMonitoringPlugin' {
    BeforeAll {
        $config = New-TestConfig
        # Shaped like the live instance view (2026-10-26): the plugin's state is in statuses[0].message, and the
        # DatabaseMonitorArcPlugin substatus holds only its endpoint. 'Empty' is the agent right after boot, before
        # it reports the plugin.
        function New-TestSqlIaasExtension([string] $PluginState, [bool] $FlagOn = $true) {
            $plugin = switch ($PluginState) {
                'Empty' { '' }
                'Running' { 'DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"};' }
                default { 'DatabaseMonitorArcPlugin: {"State":"' + $PluginState + '"};' }
            }
            [pscustomobject]@{
                settings     = [pscustomobject]@{ FeatureFlags = @([pscustomobject]@{ Name = 'DatabaseWatcheronAzureVM'; Enable = $FlagOn }) }
                instanceView = [pscustomobject]@{
                    statuses    = @([pscustomobject]@{ code = 'ProvisioningState/succeeded'; message = ('SQL Server IaaS Agent: Healthy;{0}Resource Provider Plugin: Rp plugin is enabled.' -f $plugin) })
                    substatuses = @([pscustomobject]@{ code = 'ComponentStatus/DatabaseMonitorArcPlugin/succeeded'; message = '{"endpointUrl":"https://telemetry.{0}.arcdataservices.com/","endpointAppId":"<id>"}' })
                }
            }
        }
    }

    BeforeEach {
        $script:pluginStates = [System.Collections.Generic.Queue[string]]::new()
        $script:flagOn = $true
        $script:reads = 0
        $script:readsAtRestart = -1
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm extension show ' } -MockWith {
            $script:reads++
            $state = if ($script:pluginStates.Count -gt 1) { $script:pluginStates.Dequeue() } else { $script:pluginStates.Peek() }
            New-TestSqlIaasExtension -PluginState $state -FlagOn $script:flagOn
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $script:readsAtRestart = $script:reads
            [pscustomobject]@{ Succeeded = $true; Output = 'SQLIaaSExtension is Running.' }
        }
    }

    It 'leaves a running plugin alone' {
        $script:pluginStates.Enqueue('Running')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.checkId | Should -Be 'START.T1.MONITORING'
        $result.status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
    }

    It 'reports as the deployment''s check when deploy.ps1 calls it after its wait (Phase 25d)' {
        # Live, 2026-10-27: after the deployment's template run the plugin stayed NotRunning; the restart brought it back.
        foreach ($state in 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment' } $config
        $result.checkId | Should -Be 'DEPLOY.T1.MONITORING'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'wasn''t running after the deployment \(DatabaseMonitorArcPlugin: \{"State":"NotRunning"\}\); the SQL IaaS Agent service was restarted'
    }

    It 'waits for the agent''s first plugin status after boot, and leaves a plugin that comes up Running alone' {
        # Live, 2026-10-26: about a minute after boot the agent reported no plugin status at all.
        foreach ($state in 'Empty', 'Empty', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'is running \(upload status ''OK''\), reported \d+ seconds after the check began'
        $result.evidence.settlePolls | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 15 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
    }

    It 'waits for the agent''s first plugin status before it restarts a NotRunning plugin, then checks for Running and OK' {
        # Live, 2026-10-26: a restart while the status was still empty left the plugin NotRunning for hours.
        foreach ($state in 'Empty', 'NotRunning', 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $script:readsAtRestart | Should -Be 2
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'wasn''t running after the start \(DatabaseMonitorArcPlugin: \{"State":"NotRunning"\}\); the SQL IaaS Agent service was restarted'
        $result.evidence.restarted | Should -BeTrue
        $result.evidence.after | Should -Match '"State":"Running","MetricsUploadStatus":"OK"'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $VmName -eq 'sqlvm01' -and $Script -match "Restart-Service -Name 'SQLIaaSExtension' -Force" }
    }

    It 'restarts the SQL IaaS Agent when the plugin stayed NotRunning after the start, and waits for Running and OK' {
        # Live, 2026-10-22: NotRunning for more than 90 minutes after a deallocation and start; Running a minute after the restart.
        foreach ($state in 'NotRunning', 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -PollSeconds 1 } $config
        $script:readsAtRestart | Should -Be 1
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'restarted'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $VmName -eq 'sqlvm01' -and $Script -match "Restart-Service -Name 'SQLIaaSExtension' -Force" }
    }

    It 'restarts the SQL IaaS Agent when the plugin still has no status after the bounded wait' {
        foreach ($state in 'Empty', 'Empty', 'Empty', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -SettleMinutes 1 -PollSeconds 30 } $config
        $script:readsAtRestart | Should -Be 3
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'wasn''t running after the start \(no plugin status after \d+ seconds\)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }

    It 'reports a Warning, after a bounded wait, when the restart doesn''t bring the plugin back' {
        $script:pluginStates.Enqueue('NotRunning')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -WaitMinutes 1 -PollSeconds 30 } $config
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'still reports DatabaseMonitorArcPlugin: \{"State":"NotRunning"\} 1 minutes after the SQL IaaS Agent service was restarted'
        $result.remediation | Should -Match 'configure-monitoring\.ps1'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }

    It 'touches nothing when monitoring isn''t turned on' {
        $script:pluginStates.Enqueue('NotRunning')
        $script:flagOn = $false
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
    }
}
