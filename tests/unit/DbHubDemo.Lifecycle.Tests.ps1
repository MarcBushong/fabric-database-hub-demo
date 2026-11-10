BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    # The .NET SDK that deploy.ps1 installs when it's missing (2026-11-09) has its own tests (DbHubDemo.DotNetSdk.Tests.ps1);
    # here it's there, and adds no record, unless a test says otherwise.
    Mock -ModuleName DbHubDemo -CommandName Initialize-DemoDotNetSdk -MockWith { }

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
            BastionExpiresUtc = ''; HostPasswordUtc = ''; T2BuildUtc = ''; Tags = @{ deploymentId = 'abc123' }
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

    Context 'tag values as Azure holds them (Phase 28 follow-up)' {
        BeforeEach {
            # ISO 8601 dates, with Z and with an offset, in the demo's tags and in a person's own; a date-only expiry.
            $script:groupTags = [ordered]@{
                deploymentId        = 'abc123'
                DbHubDeployStage    = 'T3'
                DbHubDeployStageUtc = '2026-11-02T14:05:09Z'
                DbHubGuidedStopUtc  = '2026-11-02T15:00:00Z'
                expiresOn           = '2026-12-31'
                reviewedOn          = '2026-10-31T09:30:00+02:00'
                createdAt           = '2026-10-30T08:00:00.1234567Z'
                note                = 'kept by hand'
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
                $script:azCalls.Add(@($ArgumentList))
                if ($ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'exists') {
                    return (New-AzResult -StdOut 'true')
                }
                if ($ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'show') {
                    # As the Azure CLI prints it: the dates are JSON strings.
                    return (New-AzResult -StdOut ([ordered]@{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo'; name = 'rg-dbhub-demo'; tags = $script:groupTags } | ConvertTo-Json))
                }
                return (New-AzResult -StdOut '{}')
            }
        }

        It 'reads every tag''s text unchanged, whatever the culture and time zone, so a redeploy writes it back as it was' {
            $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            $savedZone = $env:TZ
            try {
                # A culture that writes the day first, and on Linux a zone west of UTC, where a [datetime] read from an ISO
                # string with an offset becomes local time.
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                if (-not $IsWindows) {
                    $env:TZ = 'America/Los_Angeles'
                    [System.TimeZoneInfo]::ClearCachedData()
                }
                $tags = InModuleScope DbHubDemo { Get-DemoResourceGroupTag -SubscriptionId '11111111-2222-3333-4444-555555555555' -ResourceGroupName 'rg-dbhub-demo' }
                foreach ($key in $script:groupTags.Keys) {
                    $tags[$key] | Should -BeExactly $script:groupTags[$key] -Because $key
                    $tags[$key] | Should -BeOfType [string]
                }
                $state = Get-DemoDeploymentState -Config $config
                $state.StageUtc | Should -BeExactly '2026-11-02T14:05:09Z'
                $state.GuidedStopUtc | Should -BeExactly '2026-11-02T15:00:00Z'
                # What the template gets back for the group (existingResourceGroupTags) is the same text.
                $document = Get-DemoDeploymentParameter -Config $config -ExistingResourceGroupTags $tags -NetworkMode public -T3UseFreeLimit $false
                $sent = $document['parameters']['existingResourceGroupTags']['value']
                $json = $document | ConvertTo-Json -Depth 30
                foreach ($key in $script:groupTags.Keys) {
                    $sent[$key] | Should -BeExactly $script:groupTags[$key] -Because $key
                    $json | Should -Match ([regex]::Escape(('"{0}": "{1}"' -f $key, $script:groupTags[$key]))) -Because $key
                }
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
                $env:TZ = $savedZone
                [System.TimeZoneInfo]::ClearCachedData()
            }
        }

        It 'reads both forms of a date tag, ISO and the "MM/dd/yyyy HH:mm:ss" that earlier redeploys wrote, as the same UTC time' {
            $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                $iso = InModuleScope DbHubDemo { ConvertTo-DemoRunCommandUtc -Value '2026-11-02T15:00:00Z' }
                $rewritten = InModuleScope DbHubDemo { ConvertTo-DemoRunCommandUtc -Value '11/02/2026 15:00:00' }
                $iso | Should -Be ([datetime]::new(2026, 11, 2, 15, 0, 0, [System.DateTimeKind]::Utc))
                $rewritten | Should -Be $iso
                # The watchdog reads the guided stop's time either way (Get-DemoHostRestartBlocker).
                foreach ($value in '2099-11-02T15:00:00Z', '11/02/2099 15:00:00') {
                    $script:groupTags['DbHubGuidedStopUtc'] = $value
                    InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoHostRestartBlocker -Config $Config } | Should -Match 'guided stop' -Because $value
                }
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
            }
        }
    }
}

Describe 'ConvertTo-DemoDeploymentOutput (Phase 28 follow-up)' {
    It 'returns no outputs for a deployment whose outputs object is empty, under strict mode' {
        Set-StrictMode -Version Latest
        $deployment = '{"properties":{"provisioningState":"Succeeded","outputs":{}}}' | ConvertFrom-Json -Depth 64
        $outputs = InModuleScope DbHubDemo -Parameters @{ Deployment = $deployment } { ConvertTo-DemoDeploymentOutput -Deployment $Deployment }
        $outputs | Should -BeOfType [hashtable]
        $outputs.Count | Should -Be 0
        $named = '{"properties":{"outputs":{"deploymentId":{"type":"String","value":"abc123"}}}}' | ConvertFrom-Json -Depth 64
        (InModuleScope DbHubDemo -Parameters @{ Deployment = $named } { ConvertTo-DemoDeploymentOutput -Deployment $Deployment })['deploymentId'] | Should -Be 'abc123'
        (InModuleScope DbHubDemo { ConvertTo-DemoDeploymentOutput -Deployment $null }).Count | Should -Be 0
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
        # No unit test reaches the Retail Prices API (ADR 0016): T4's cost checks and the size change's notice (2026-11-09)
        # get obviously fake estimates here; DbHubDemo.T4Fallback.Tests.ps1 tests the checks themselves.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith {
            $size = if ($PesterBoundParameters.ContainsKey('SkuName')) { [string]$PesterBoundParameters['SkuName'] } else { 'Standard_D2ds_v5' }
            [pscustomobject]@{ Allowed = $true; SkipReason = ''; SkuName = $size; HourlyUsd = 0.5; T4LightUseMonthlyUsd = 30.0; T4MonthlyWorstCaseUsd = 380.0; LightUseMonthlyUsd = 70.0; MonthlyWorstCaseUsd = 450.0; SessionUsd = 9.0; MonthlyCeilingUsd = 1000.0; SessionCeilingUsd = 15.0; DefenderIncluded = $true; Unpriced = @(); Location = 'westus3'; PriceError = ''; RestartAssumption = 'SafetyStop' }
        }
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
            # A failed create's operations, read for its cause; these tests' failures have none to show.
            if ($ArgumentList[0] -eq 'deployment' -and $ArgumentList[1] -eq 'operation') {
                return (New-AzResult -StdOut '[]')
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

        # A size the configuration sets falls back too since 2026-11-09 (user-directed): its refusal moves it on to the next
        # size, cheapest first, after that size's cost check; any other failure there fails the template as before.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SkuZone -MockWith { @() }
        $withT4['t4SkuName'] = 'Standard_B1ms'
        $script:t4State = 'NotFound'
        $script:templateFails = $true
        $script:t4Failure = [pscustomobject]@{ Sku = 'Standard_B1ms'; Zone = ''; TimeUtc = '2026-10-26T14:11:42Z' }
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeFalse -Because 'the next size failed for another reason'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 2 -Exactly -ParameterFilter { -not $T4Exists }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['SkuName'] -eq 'Standard_B2s' }
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Fail'
        $step = @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' })
        $step.Count | Should -Be 1
        $step[0].status | Should -Be 'Warning'
        $step[0].evidence.next | Should -Be 'Standard_B2s'
        $step[0].evidence.pinnedSku | Should -Be 'Standard_B1ms'
        $step[0].message | Should -Match '^Azure refused Standard_B1ms \(no zone preference, at 2026-10-26T14:11:42Z; SkuNotAvailable\), so this run creates T4 as Standard_B2s \(Burstable, 2 vCores\), the next size of the fallback for Standard_B1ms, cheapest first'
        $step[0].remediation | Should -Not -Match 'Set t4SkuName'
    }

    It 'falls back on its own from a refused Standard_D4ds_v5 to another zone, Standard_D4ads_v5, then Standard_D2ds_v5, which it creates even when its cost check doesn''t pass, and records it, when the configuration doesn''t set the size (2026-11-04; 2026-11-09)' {
        $withT4 = New-TestConfig -WithT4
        $withT4.Contains('t4SkuName') | Should -BeFalse -Because 'the schema has no default for it'
        $script:sizes = [System.Collections.Generic.List[string]]::new()
        $script:zones = [System.Collections.Generic.List[string]]::new()
        $script:recordedSku = [System.Collections.Generic.List[string]]::new()
        $script:failures = [System.Collections.Generic.Queue[object]]::new()
        $script:failures.Enqueue([pscustomobject]@{ Sku = 'Standard_D4ds_v5'; Zone = ''; TimeUtc = '2026-11-04T14:11:42Z' })
        $script:failures.Enqueue([pscustomobject]@{ Sku = 'Standard_D4ds_v5'; Zone = '2'; TimeUtc = '2026-11-04T14:21:42Z' })
        $script:failures.Enqueue([pscustomobject]@{ Sku = 'Standard_D4ads_v5'; Zone = ''; TimeUtc = '2026-11-04T14:31:42Z' })
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SkuZone -MockWith { @('2', '3') }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -MockWith { if ($script:failures.Count -gt 0) { $script:failures.Dequeue() } else { $null } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:recordedSku.Add([string]$Value['T4Sku']) }
        # The cost check has its own tests (DbHubDemo.T4Fallback.Tests.ps1); here its worst case is over the monthly ceiling,
        # which no longer leaves T4 out (2026-11-09, user-directed: T4 is part of every deployment).
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith { [pscustomobject]@{ Allowed = $false; SkipReason = 'MonthlyCeiling'; SkuName = 'Standard_D2ds_v5'; HourlyUsd = 0.5; T4MonthlyWorstCaseUsd = 400.0; MonthlyWorstCaseUsd = 600.0; SessionUsd = 9.0; MonthlyCeilingUsd = 250.0; SessionCeilingUsd = 15.0; DefenderIncluded = $true; Unpriced = @(); Location = 'westus3'; PriceError = '' } }
        # The template fails while T4 is at a 4-vCore size (SkuNotAvailable) and succeeds at the 2-vCore one.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            $size = if ($Config['t4Enabled']) { if ($Config.Contains('t4SkuName')) { [string]$Config['t4SkuName'] } else { 'default' } } else { 'none' }
            $script:sizes.Add($size)
            $script:zones.Add([string]$Config['t4AvailabilityZone'])
            $script:templateFails = $size -notin 'none', 'Standard_D2ds_v5'
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit }; budgetTags = @{ value = $ExistingResourceGroupTags } } }
        }
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeTrue
        $script:sizes | Should -Be @('default', 'Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5') -Because 'a cost check that doesn''t pass never leaves T4 out'
        @($script:zones | Select-Object -First 3) | Should -Be @('', '2', '') -Because 'the retry goes to another zone the region lists, and the next size to the configured zone'
        $script:recordedSku | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4SkuZone -Times 1 -Exactly
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['SkuName'] -eq 'Standard_D4ds_v5' } -Because 'the notice prices the default, for the difference (2026-11-09)'
        $fallbacks = @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' })
        @($fallbacks.status) | Should -Be @('Warning', 'Warning', 'Warning')
        $fallbacks[0].message | Should -Match 'tries it once more in zone 2'
        $fallbacks[1].message | Should -Match 'tries Standard_D4ads_v5, General Purpose with 4 vCores'
        $fallbacks[2].message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5 \(2 vCores, 8 GiB\), with autonomous tuning off, although its cost check doesn''t pass'
        $fallbacks[2].message | Should -Match 'T4 is part of every deployment, so a ceiling never leaves it out'
        $fallbacks[2].evidence.skipReason | Should -Be 'MonthlyCeiling'
        $fallbacks[2].remediation | Should -Match 'raise monthlyCeilingUsd to at least 600'
        $fallbacks[2].remediation | Should -Not -Match 't4Enabled'
        $deployment.T4Note | Should -Match '^T4 was created as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, T4''s default size, because Azure refused Standard_D4ds_v5 \(no zone preference, then zone 2\), then Standard_D4ads_v5 \(no zone preference\) with SkuNotAvailable\.'
        # The template keeps the choice in the resource group's tags too.
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'Standard_D2ds_v5'
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Pass'
    }

    It 'starts the fallback one size on when preflight already ruled the default out, and never for a size the configuration sets (Phase 28)' {
        $withT4 = New-TestConfig -WithT4
        $script:sizes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            $script:sizes.Add($(if ($Config['t4Enabled']) { if ($Config.Contains('t4SkuName')) { [string]$Config['t4SkuName'] } else { 'default' } } else { 'none' }))
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit } } }
        }
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false -T4StartSku 'Standard_D4ads_v5'
        $script:sizes | Should -Be @('Standard_D4ads_v5')
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' }).status | Should -Be 'Warning'
        $deployment.T4SkuName | Should -Be 'Standard_D4ads_v5'

        $script:sizes.Clear()
        $withT4['t4SkuName'] = 'Standard_D2ds_v5'
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false -T4StartSku 'Standard_D4ads_v5'
        $script:sizes | Should -Be @('Standard_D2ds_v5')
        @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' }).Count | Should -Be 0
    }

    It 'clears a recorded "no T4" when the configuration sets t4SkuName, and never leaves T4 out for one, whether the configuration is resolved or not (review finding 5; 2026-11-09)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'abc123'; owner = 'your-alias'; DbHubT4Size = 'None' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit }; budgetTags = @{ value = $ExistingResourceGroupTags } } }
        }
        $withT4 = New-TestConfig -WithT4
        $withT4['t4SkuName'] = 'Standard_D2ds_v5'
        $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
        $deployment.Succeeded | Should -BeTrue
        $deployment.T4Enabled | Should -BeTrue
        # The template carries the group's tags, so the stale record goes in them.
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Size'] | Should -Be ''

        # 2026-11-09 (user-directed: T4 is part of every deployment): no record leaves T4 out. A configuration without a size
        # that isn't resolved yet, as start-demo.ps1's T3 recreation passes it, gets T4 at the default size; it doesn't try
        # the sizes again on the record's account, so the record stays until a run that deploys the template resolves it.
        $script:deployCalls.Clear()
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig -WithT4) -NetworkMode private -T3UseFreeLimit $false
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D4ds_v5'
        @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.RETRY' }).Count | Should -Be 0
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'None'

        # deploy.ps1 resolves it with -TemplateRuns: the fallback tries T4's sizes again from the default, DEPLOY.T4.RETRY
        # says so, and the record goes.
        $script:deployCalls.Clear()
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -WithT4) } { Resolve-DemoEffectiveConfig -Config $Config -State ([pscustomobject]@{ T4Sku = 'None' }) -TemplateRuns }
        $deployment = Invoke-DemoTemplateDeployment -Config $resolved -NetworkMode private -T3UseFreeLimit $false
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D4ds_v5'
        ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.RETRY' }).status | Should -Be 'Warning'
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Size'] | Should -Be ''

        # With T4 off in this run's configuration (in memory only: Get-DemoConfig always turns it on), the record stays.
        $script:deployCalls.Clear()
        Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false | Out-Null
        $script:deployCalls[-1].Parameters.parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'None'
    }
}

Describe 'The budget''s start date and a failed template''s cause (Phase 28 live finding, 2026-11-02)' {
    BeforeAll {
        $config = New-TestConfig
        $script:sub = '11111111-2222-3333-4444-555555555555'
        $script:createError = 'ERROR: {"status":"Failed","error":{"code":"DeploymentFailed","target":"/subscriptions/' + $script:sub + '/providers/Microsoft.Resources/deployments/dbhub-demo-main","message":"At least one resource deployment operation failed. Please list deployment operations for details. Please see https://aka.ms/arm-deployment-operations for usage details."}}'
        $script:budgetError = 'Start date of budgets cannot be updated. Please delete and create a new budget.'

        # One deployment operation as 'az deployment operation ... list' prints it.
        function New-TestOperation([string] $Type, [string] $Name, [string] $State = 'Failed', [object] $StatusMessage = $null, [string] $Group = 'rg-dbhub-demo', [string] $StatusCode = 'BadRequest') {
            $id = if ($Type -eq 'Microsoft.Resources/resourceGroups') { '/subscriptions/{0}/resourceGroups/{1}' -f $script:sub, $Name } elseif ($Group) { '/subscriptions/{0}/resourceGroups/{1}/providers/{2}/{3}' -f $script:sub, $Group, $Type, $Name } else { '/subscriptions/{0}/providers/{1}/{2}' -f $script:sub, $Type, $Name }
            $properties = [ordered]@{ provisioningOperation = 'Create'; provisioningState = $State; statusCode = $(if ($State -eq 'Failed') { $StatusCode } else { 'OK' }); targetResource = [ordered]@{ id = $id; resourceType = $Type; resourceName = $Name }; timestamp = '2026-11-02T14:03:11.123456+00:00' }
            if ($null -ne $StatusMessage) {
                $properties['statusMessage'] = $StatusMessage
            }
            [ordered]@{ id = '{0}/operations/0F1E2D3C4B5A6978' -f $id; operationId = '0F1E2D3C4B5A6978'; properties = $properties }
        }
        function New-TestDeploymentFailed([string] $Target) {
            [ordered]@{ status = 'Failed'; error = [ordered]@{ code = 'DeploymentFailed'; target = $Target; message = 'At least one resource deployment operation failed. Please list deployment operations for details. Please see https://aka.ms/arm-deployment-operations for usage details.'; details = @([ordered]@{ code = 'ResourceDeploymentFailure'; target = $Target; message = 'The resource write operation failed to complete successfully, because it reached terminal provisioning state ''Failed''.' }) } }
        }
        function ConvertTo-TestOperationJson([object[]] $Operation) {
            ConvertTo-Json -InputObject @($Operation) -Depth 30
        }
        # The live finding's chain: the subscription deployment, its resource group deployment, the budget module, the budget.
        function Set-TestBudgetChain {
            $script:operations['sub/dbhub-demo-main'] = ConvertTo-TestOperationJson @(
                (New-TestOperation -Type 'Microsoft.Resources/resourceGroups' -Name 'rg-dbhub-demo' -State 'Succeeded')
                (New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'demo-abc123' -StatusCode 'Conflict' -StatusMessage (New-TestDeploymentFailed ('/subscriptions/{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.Resources/deployments/demo-abc123' -f $script:sub)))
            )
            $script:operations['rg-dbhub-demo/demo-abc123'] = ConvertTo-TestOperationJson @(
                (New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'network' -State 'Succeeded')
                (New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'budget' -StatusCode 'Conflict' -StatusMessage ([ordered]@{ status = 'Failed'; error = [ordered]@{ code = 'DeploymentFailed'; message = 'At least one resource deployment operation failed.'; details = @([ordered]@{ code = 'BadRequest'; message = ('{"error":{"code":"400","message":"' + $script:budgetError + '"}}') }) } }))
            )
            $script:operations['rg-dbhub-demo/budget'] = ConvertTo-TestOperationJson @(
                (New-TestOperation -Type 'Microsoft.Consumption/budgets' -Name 'budget-dbhub-demo' -StatusMessage ([ordered]@{ error = [ordered]@{ code = '400'; message = $script:budgetError } }))
            )
        }
        # What az prints for the budget: the whole resource as JSON, or, with --query and --output, only the start date,
        # as the API wrote it (az applies the query itself, so the test does the same for the one query the module sends).
        function Get-TestBudgetResponse([string[]] $Arguments) {
            if ($script:budgetRead -eq 'Missing') {
                return (New-AzResult -ExitCode 1 -StdErr 'ERROR: Not Found({"error":{"code":"NotFound","message":"Budget budget-dbhub-demo was not found."}})')
            }
            if ($script:budgetRead -eq 'Denied') {
                return (New-AzResult -ExitCode 1 -StdErr ('ERROR: Forbidden({{"error":{{"code":"AuthorizationFailed","message":"The client was refused; correlation {0}."}}}})' -f $script:fakeSecret))
            }
            $queryAt = [array]::IndexOf($Arguments, '--query')
            if ($queryAt -ge 0) {
                $Arguments[$queryAt + 1] | Should -Be 'properties.timePeriod.startDate'
                if ($Arguments[[array]::IndexOf($Arguments, '--output') + 1] -eq 'tsv') {
                    return (New-AzResult -StdOut $script:budgetStart)
                }
                return (New-AzResult -StdOut ('"{0}"' -f $script:budgetStart))
            }
            $body = [ordered]@{ id = '/subscriptions/{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.Consumption/budgets/budget-dbhub-demo' -f $script:sub; name = 'budget-dbhub-demo'; type = 'Microsoft.Consumption/budgets'; properties = [ordered]@{ category = 'Cost'; amount = 250; timeGrain = 'Monthly'; timePeriod = [ordered]@{ startDate = $script:budgetStart; endDate = '2036-09-30T00:00:00Z' } } }
            return (New-AzResult -StdOut (ConvertTo-Json -InputObject $body -Depth 10))
        }
    }

    BeforeEach {
        $script:azLog = [System.Collections.Generic.List[string]]::new()
        $script:creates = [System.Collections.Generic.List[object]]::new()
        $script:operations = @{}
        $script:budgetRead = 'Found'
        $script:budgetStart = '2026-10-01T00:00:00Z'
        $script:createFails = { $false }
        $script:createStdErr = $script:createError
        $script:groupExists = $true
        $script:pgDeployment = $null
        $script:fakeSecret = -join @('Fk', 'q7', 'Lm', '29', 'Pz', 'Wd')
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $script:groupExists }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'abc123'; owner = 'your-alias' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoExistingVmName -MockWith { @('sqlvm01', 'archost01') }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT1SecurityType -MockWith { [pscustomobject]@{ SecurityType = 'TrustedLaunch' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = $false; State = 'NotFound' } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { $null }
        # No unit test reaches the Retail Prices API (ADR 0016): T4's cost checks and the size change's notice (2026-11-09)
        # get obviously fake estimates here; DbHubDemo.T4Fallback.Tests.ps1 tests the checks themselves.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith {
            $size = if ($PesterBoundParameters.ContainsKey('SkuName')) { [string]$PesterBoundParameters['SkuName'] } else { 'Standard_D2ds_v5' }
            [pscustomobject]@{ Allowed = $true; SkipReason = ''; SkuName = $size; HourlyUsd = 0.5; T4LightUseMonthlyUsd = 30.0; T4MonthlyWorstCaseUsd = 380.0; LightUseMonthlyUsd = 70.0; MonthlyWorstCaseUsd = 450.0; SessionUsd = 9.0; MonthlyCeilingUsd = 1000.0; SessionCeilingUsd = 15.0; DefenderIncluded = $true; Unpriced = @(); Location = 'westus3'; PriceError = ''; RestartAssumption = 'SafetyStop' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:azLog.Add($joined)
            if ($joined -match '^rest --method get --url https://management\.azure\.com/subscriptions/[^/]+/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Consumption/budgets/budget-dbhub-demo\?api-version=') {
                return (Get-TestBudgetResponse -Arguments $ArgumentList)
            }
            if ($joined -like 'vm show *') {
                return (New-AzResult -StdOut "archost01`n")
            }
            if ($joined -like 'deployment sub create *') {
                $file = [string]$ArgumentList[[array]::IndexOf($ArgumentList, '--parameters') + 1]
                $parameters = Get-Content -LiteralPath $file.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                $script:creates.Add($parameters)
                if (& $script:createFails $parameters) {
                    return (New-AzResult -ExitCode 1 -StdErr $script:createStdErr)
                }
                return (New-AzResult -StdOut '{"properties":{"provisioningState":"Succeeded","duration":"PT4M","outputs":{"resourceGroupName":{"value":"rg-dbhub-demo"}}}}')
            }
            if ($joined -match '^deployment operation (sub|group) list (?:--resource-group (\S+) )?--name (\S+)') {
                $key = if ($Matches[1] -eq 'sub') { 'sub/' + $Matches[3] } else { $Matches[2] + '/' + $Matches[3] }
                if ($script:operations.ContainsKey($key)) {
                    return (New-AzResult -StdOut $script:operations[$key])
                }
                return (New-AzResult -ExitCode 3 -StdErr ('ERROR: (DeploymentNotFound) Deployment ''{0}'' could not be found.' -f $Matches[3]))
            }
            if ($joined -like 'deployment group show --resource-group rg-dbhub-demo --name pgflex01 *' -and $null -ne $script:pgDeployment) {
                return (New-AzResult -StdOut $script:pgDeployment)
            }
            return (New-AzResult -ExitCode 3 -StdErr 'ERROR: (ResourceNotFound) Not faked in this test.')
        }
    }

    AfterEach {
        Clear-DemoSecret
    }

    Context 'Get-DemoBudgetStartDate' {
        It 'reads the start date as the API wrote it and returns it as yyyy-MM-dd in UTC, whatever the culture and time zone' {
            $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            $savedZone = $env:TZ
            try {
                # A Buddhist-calendar culture writes another year with the same format string, so only the invariant culture
                # gives 2026; on Linux, TZ moves the machine's zone west of UTC, where the local date of 2026-10-01T00:00Z is
                # still September.
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('th-TH')
                if (-not $IsWindows) {
                    $env:TZ = 'America/Los_Angeles'
                    [System.TimeZoneInfo]::ClearCachedData()
                }
                InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoBudgetStartDate -Config $Config } | Should -Be '2026-10-01'
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
                $env:TZ = $savedZone
                [System.TimeZoneInfo]::ClearCachedData()
            }
            $script:azLog[0] | Should -Match ('^rest --method get --url https://management\.azure\.com/subscriptions/{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Consumption/budgets/budget-dbhub-demo\?api-version=\S+ --query properties\.timePeriod\.startDate --output tsv --subscription {0}$' -f [regex]::Escape($script:sub))
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }

            # An offset that isn't UTC still names the day in UTC.
            $script:budgetStart = '2026-10-01T02:00:00+02:00'
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoBudgetStartDate -Config $Config } | Should -Be '2026-10-01'
        }

        It 'returns nothing, and says nothing, when there''s no budget yet (HTTP 404)' {
            $script:budgetRead = 'Missing'
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoBudgetStartDate -Config $Config } | Should -Be ''
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly
        }

        It 'logs one redacted Warning and returns nothing when the budget can''t be read, or its date isn''t the first of a month' {
            Register-DemoSecret -Value $script:fakeSecret
            $script:budgetRead = 'Denied'
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoBudgetStartDate -Config $Config } | Should -Be ''
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'The start date of the budget budget-dbhub-demo couldn''t be read \(ERROR: Forbidden.*AuthorizationFailed.*\[REDACTED\].*\), so the template sends the first day of this month\. In a later month than the budget''s own, Azure refuses that change' -and $Message -notmatch $script:fakeSecret -and $Message -notmatch '[\r\n]' }

            $script:budgetRead = 'Found'
            $script:budgetStart = '2026-10-15T00:00:00Z'
            InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoBudgetStartDate -Config $Config } | Should -Be ''
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'Azure returned "2026-10-15T00:00:00Z", not the first day of a month' }
        }
    }

    Context 'Invoke-DemoTemplateDeployment' {
        It 'sends the budget''s own start date to the template in a later month than the budget''s' {
            # The template's default is the first day of the current month, which Azure refuses for this budget.
            '2026-10-01' | Should -BeLessThan ([System.DateTime]::UtcNow.ToString('yyyy-MM-01', [System.Globalization.CultureInfo]::InvariantCulture))
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            $deployment.Succeeded | Should -BeTrue
            $script:creates.Count | Should -Be 1
            $script:creates[0].parameters.budgetStartDate.value | Should -Be '2026-10-01'
        }

        It 'reads the budget even when the resource group is gone, because a budget at its scope outlives it' {
            $script:groupExists = $false
            Mock -ModuleName DbHubDemo -CommandName Get-DemoExistingVmName -MockWith { @() }
            Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false | Out-Null
            $script:creates[0].parameters.budgetStartDate.value | Should -Be '2026-10-01'

            # A new environment has no budget, so the template's default applies.
            $script:creates.Clear()
            $script:budgetRead = 'Missing'
            Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false | Out-Null
            $script:creates[0].parameters.Contains('budgetStartDate') | Should -BeFalse
        }

        It 'names the innermost error of a failed deployment''s nested operations in DEPLOY.TEMPLATE, with a remediation for the budget' {
            Set-TestBudgetChain
            $script:createFails = { $true }
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            $deployment.Succeeded | Should -BeFalse
            $template = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }
            $template.status | Should -Be 'Fail'
            $template.message | Should -Be ('The template create failed: Microsoft.Consumption/budgets budget-dbhub-demo: 400: {0}' -f $script:budgetError)
            $template.evidence.deploymentName | Should -Be 'dbhub-demo-main'
            $template.evidence.failedOperations.Count | Should -Be 1
            $template.evidence.failedOperations[0].resourceType | Should -Be 'Microsoft.Consumption/budgets'
            $template.evidence.failedOperations[0].code | Should -Be '400'
            $template.evidence.deploymentError | Should -Match 'DeploymentFailed'
            $template.remediation | Should -Match 'Delete the budget budget-dbhub-demo at the scope of the resource group rg-dbhub-demo \(Azure portal: Cost Management > Budgets'
            $template.remediation | Should -Match 'Budgets - Delete\), then run \./scripts/deploy\.ps1 again: it creates the budget anew, starting the first day of this month\.'
            $template.docUrl | Should -Be 'https://learn.microsoft.com/rest/api/consumption/budgets/delete'
            @($script:azLog | Where-Object { $_ -like 'deployment operation *' }) | Should -Be @(
                ('deployment operation sub list --name dbhub-demo-main --output json --subscription {0}' -f $script:sub)
                ('deployment operation group list --resource-group rg-dbhub-demo --name demo-abc123 --output json --subscription {0}' -f $script:sub)
                ('deployment operation group list --resource-group rg-dbhub-demo --name budget --output json --subscription {0}' -f $script:sub)
            )
        }

        It 'bounds the depth, the number of errors, and each message, and redacts secrets' {
            Register-DemoSecret -Value $script:fakeSecret
            $script:createFails = { $true }
            # Six nested deployments in a row: only four levels are read, and the fourth's own error is used.
            $script:operations['sub/dbhub-demo-main'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'level2' -StatusMessage (New-TestDeploymentFailed 'level2'))
            foreach ($level in 2..5) {
                $script:operations[('rg-dbhub-demo/level{0}' -f $level)] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Resources/deployments' -Name ('level{0}' -f ($level + 1)) -StatusMessage ([ordered]@{ status = 'Failed'; error = [ordered]@{ code = 'DeploymentFailed'; message = 'At least one resource deployment operation failed.'; details = @([ordered]@{ code = ('InnerOfLevel{0}' -f ($level + 1)); message = 'Level {0} failed.' -f ($level + 1) }) } }))
            }
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            $template = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }
            $template.message | Should -Be 'The template create failed: Microsoft.Resources/deployments level5: InnerOfLevel5: Level 5 failed.'
            @($script:azLog | Where-Object { $_ -like 'deployment operation *' }).Count | Should -Be 4
            @($script:azLog | Where-Object { $_ -like '*--name level5 *' }).Count | Should -Be 0

            # Eight failed resources with long messages: five errors, each at most 300 characters, the secret redacted.
            $script:azLog.Clear()
            $long = ('{0} ' -f $script:fakeSecret) + ('word ' * 500)
            $script:operations['sub/dbhub-demo-main'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'demo-abc123' -StatusMessage (New-TestDeploymentFailed 'demo-abc123'))
            $script:operations['rg-dbhub-demo/demo-abc123'] = ConvertTo-TestOperationJson @(foreach ($index in 1..8) { New-TestOperation -Type 'Microsoft.Network/networkSecurityGroups' -Name ('nsg-{0}' -f $index) -StatusMessage ([ordered]@{ error = [ordered]@{ code = 'InvalidRequest'; message = "Line one $index`r`n$long" } }) })
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            $template = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }
            $template.evidence.failedOperations.Count | Should -Be 5
            foreach ($item in $template.evidence.failedOperations) {
                $item.message.Length | Should -BeLessOrEqual 300
                $item.message | Should -Match '^Line one \d \[REDACTED\] word word'
                $item.message | Should -Match '\.\.\.$'
            }
            $template.message.Length | Should -BeLessOrEqual ('The template create failed: '.Length + 1200)
            $template.message | Should -Not -Match $script:fakeSecret
            $template.message | Should -Not -Match '[\r\n]'
            $template.message | Should -Match '^The template create failed: Microsoft\.Network/networkSecurityGroups nsg-1: InvalidRequest: Line one 1 '
            $template.remediation | Should -Match 'Fix the cause in the message, then run deploy\.ps1 -Resume\.'
            $template.docUrl | Should -Be 'https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/find-error-code'
        }

        It 'falls back to the Azure CLI''s error when the operations can''t be read, and reads none for an error that isn''t DeploymentFailed' {
            $script:createFails = { $true }
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            $template = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }
            $template.message | Should -Be ('The template create failed: {0}' -f $script:createError)
            $template.remediation | Should -Be 'Fix the cause in the message, then run deploy.ps1 -Resume. A 409 Conflict while a policy installs an extension clears within minutes.'
            $template.docUrl | Should -Be 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-create'
            @($script:azLog | Where-Object { $_ -like 'deployment operation sub list *' }).Count | Should -Be 1

            # A validation error names its cause itself, and the record with this name can still be an earlier run's.
            $script:azLog.Clear()
            Set-TestBudgetChain
            $script:createStdErr = 'ERROR: {"code":"InvalidTemplateDeployment","message":"The template deployment ''dbhub-demo-main'' is not valid according to the validation procedure."}'
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).message | Should -Match '^The template create failed: ERROR: \{"code":"InvalidTemplateDeployment"'
            @($script:azLog | Where-Object { $_ -like 'deployment operation *' }).Count | Should -Be 0

            # An older Azure CLI's error text that still names the budget gets the budget's remediation too.
            $script:createStdErr = $script:createError + ' {"code":"400","message":"' + $script:budgetError + '"}'
            $script:operations.Clear()
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
            ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).remediation | Should -Match 'Delete the budget budget-dbhub-demo'
        }

        It 'shows no subscription ID, tenant ID, object ID, or account in what GitHub Actions writes' {
            $savedActions = $env:GITHUB_ACTIONS
            $savedSummary = $env:GITHUB_STEP_SUMMARY
            try {
                $env:GITHUB_ACTIONS = 'true'
                $env:GITHUB_STEP_SUMMARY = Join-Path -Path $TestDrive -ChildPath 'summary.md'
                InModuleScope DbHubDemo { $script:DemoLogMasks.Clear() }
                $null = Register-DemoLogMask -Value 'operator@contoso.example' 6>&1
                $script:createFails = { $true }
                $denied = 'The client ''operator@contoso.example'' with object id ''aaaaaaaa-1111-2222-3333-444444444444'' does not have authorization to perform action ''Microsoft.Consumption/budgets/write'' over scope ''/subscriptions/{0}/resourceGroups/rg-dbhub-demo/providers/Microsoft.Consumption/budgets/budget-dbhub-demo'' in tenant ''66666666-7777-8888-9999-000000000000''.' -f $script:sub
                $script:operations['sub/dbhub-demo-main'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'demo-abc123' -StatusMessage (New-TestDeploymentFailed 'demo-abc123'))
                $script:operations['rg-dbhub-demo/demo-abc123'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Consumption/budgets' -Name 'budget-dbhub-demo' -StatusCode 'Forbidden' -StatusMessage ([ordered]@{ error = [ordered]@{ code = 'AuthorizationFailed'; message = $denied } }))
                $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false
                $template = $deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }
                $template.message | Should -Match '^The template create failed: Microsoft\.Consumption/budgets budget-dbhub-demo: AuthorizationFailed: The client '
                $path = Join-Path -Path $TestDrive -ChildPath 'out/deploy.jsonl'
                Export-DemoResult -Result @($template) -Path $path
                $written = @((Get-Content -LiteralPath $path -Raw), (Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw), (InModuleScope DbHubDemo -Parameters @{ Text = $template.message } { Protect-DemoLogText -Text $Text }))
                foreach ($text in $written) {
                    $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
                    $text | Should -Not -Match 'operator@contoso\.example'
                    $text | Should -Match 'AuthorizationFailed'
                }
            }
            finally {
                $env:GITHUB_ACTIONS = $savedActions
                $env:GITHUB_STEP_SUMMARY = $savedSummary
                InModuleScope DbHubDemo { $script:DemoLogMasks.Clear() }
            }
        }

        It 'still falls back from a rejected free offer without reading the operations, also inside DeploymentFailed' {
            $script:createFails = { param($Parameters) [bool]$Parameters.parameters.t3UseFreeLimit.value }
            foreach ($stdErr in @(
                    'ERROR: (ProvisioningDisabled) The free offer is not available in region westus3 for this subscription.'
                    ($script:createError.TrimEnd('}') + ',"details":[{"code":"ProvisioningDisabled","message":"Cannot update paid database to free database."}]}}')
                )) {
                $script:creates.Clear()
                $script:azLog.Clear()
                $script:createStdErr = $stdErr
                Set-TestBudgetChain
                $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $true
                $deployment.Succeeded | Should -BeTrue
                $deployment.T3UseFreeLimit | Should -BeFalse
                $script:creates.Count | Should -Be 2
                ($deployment.Results | Where-Object { $_.checkId -eq 'T3.FREEOFFER' }).status | Should -Be 'Warning'
                ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Pass'
                @($script:azLog | Where-Object { $_ -like 'deployment operation *' }).Count | Should -Be 0
            }
        }

        It 'still falls back from a refused Burstable size through T4''s own reads, and keeps DEPLOY.T4.SKU beside the cause for a size the configuration sets' {
            $withT4 = New-TestConfig -WithT4
            # Azure refuses T4 while it's in the template; T4's own check reads pgflex01's deployment and operations.
            $script:createFails = { param($Parameters) [bool]$Parameters.parameters.t4Enabled.value -and [string]$Parameters.parameters.t4SkuName.value -eq 'Standard_D4ds_v5' }
            $script:pgDeployment = ConvertTo-Json -Depth 20 -InputObject ([ordered]@{ name = 'pgflex01'; properties = [ordered]@{ provisioningState = 'Failed'; timestamp = '2026-11-02T14:03:11.123456+00:00'; parameters = [ordered]@{ sizing = [ordered]@{ value = [ordered]@{ skuName = 'Standard_D4ds_v5'; tier = 'GeneralPurpose' } }; availabilityZone = [ordered]@{ value = '' } }; error = [ordered]@{ code = 'DeploymentFailed'; details = @([ordered]@{ code = 'ResourceDeploymentFailure' }) } } })
            $script:operations['sub/dbhub-demo-main'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'demo-abc123' -StatusMessage (New-TestDeploymentFailed 'demo-abc123'))
            $script:operations['rg-dbhub-demo/demo-abc123'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.Resources/deployments' -Name 'pgflex01' -StatusMessage (New-TestDeploymentFailed 'pgflex01'))
            $script:operations['rg-dbhub-demo/pgflex01'] = ConvertTo-TestOperationJson @(New-TestOperation -Type 'Microsoft.DBforPostgreSQL/flexibleServers' -Name 'pgflex01-abc123' -StatusMessage ([ordered]@{ status = 'Failed'; error = [ordered]@{ code = 'SkuNotAvailable'; message = 'Specified SKU is not supported in this region. Please choose a different SKU.' } }))
            $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
            $deployment.Succeeded | Should -BeTrue
            $deployment.T4SkuName | Should -Be 'Standard_D4ads_v5'
            @($script:creates | ForEach-Object { [string]$_.parameters.t4SkuName.value }) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5')
            @($script:azLog | Where-Object { $_ -like 'postgres flexible-server list-skus --location westus3 *' }).Count | Should -Be 1 -Because 'the retry in another zone needs a zone the region lists, which couldn''t be read here'
            ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' }).status | Should -Be 'Warning'
            ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.TEMPLATE' }).status | Should -Be 'Pass'
            @($script:azLog | Where-Object { $_ -like 'deployment operation group list --resource-group rg-dbhub-demo --name pgflex01 *' }).Count | Should -Be 1
            @($script:azLog | Where-Object { $_ -like 'deployment operation sub list *' }).Count | Should -Be 0

            # A size the configuration sets falls back too since 2026-11-09 (user-directed), through the same reads: a 4-vCore
            # size tries its peer first, after that size's cost check, and the notice says what T4 got.
            $script:creates.Clear()
            $script:azLog.Clear()
            $withT4['t4SkuName'] = 'Standard_D4ds_v5'
            $deployment = Invoke-DemoTemplateDeployment -Config $withT4 -NetworkMode private -T3UseFreeLimit $false
            $deployment.Succeeded | Should -BeTrue
            @($script:creates | ForEach-Object { [string]$_.parameters.t4SkuName.value }) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5')
            @($deployment.Results | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.SKU' -and [string]$_.status -eq 'Fail' }) | Should -BeNullOrEmpty
            ($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.FALLBACK' }).message | Should -Match '^T4 was created as Standard_D4ads_v5 \(General Purpose, 4 vCores\) instead of Standard_D4ds_v5, the size t4SkuName sets'
            @($script:azLog | Where-Object { $_ -like 'deployment operation group list --resource-group rg-dbhub-demo --name pgflex01 *' }).Count | Should -Be 1
        }
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
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -MockWith { $script:order.Add('PowerBI'); New-TestResult 'FABRIC.REPORT' 'Pass' 'fabric' 'fabric' }
        # The Insights app, part of every deployment (2026-11-05): its sign-in starts before the stages, and its step runs
        # after the report. Both have their own tests (DbHubDemo.FabricAppSignIn.Tests.ps1, DbHubDemo.FabricTrack.Tests.ps1);
        # here the CLI is already signed in, and the app deploys.
        $script:appSignIn = [pscustomobject]@{ Process = $null; Done = $true; Reported = $false; Result = (New-DemoResult -CheckId 'DEPLOY.FABRIC.APPSIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Pass' -Message 'The Rayfin CLI is already signed in to the demo''s tenant.') }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignIn -MockWith { $script:appSignIn }
        # The read of its sign-in that starts before the guard (2026-11-06) never runs the CLI here either; what it does is
        # kept apart from the stages' order.
        $script:signInCalls = [System.Collections.Generic.List[string]]::new()
        $script:signInCheck = [pscustomobject]@{ TenantId = '66666666-7777-8888-9999-000000000000'; Via = 'npx'; Run = $null; Result = $null }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignInCheck -MockWith { $script:signInCalls.Add('check'); $script:signInCheck }
        Mock -ModuleName DbHubDemo -CommandName Stop-DemoRayfinSignInStatus -MockWith {
            if ($null -ne $Status) {
                $script:signInCalls.Add('stop')
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoInsightsAppStep -MockWith { $script:order.Add('App'); New-TestResult 'FABRIC.APP.DEPLOY' 'Pass' 'fabric' 'fabric' }
        # The switch from the interim baseline to a profile with incidents, after DONE's reads (2026-11-03).
        $script:switchOutcome = 'Set'
        Mock -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -MockWith {
            $script:order.Add(('Switch:{0}={1}' -f (@($Target) -join ','), $ProfileName))
            foreach ($item in $Target) {
                [pscustomobject]@{ Target = $item; VmName = $(if ($item -eq 'T2') { 'archost01' } else { 'sqlvm01' }); Outcome = $(if ([int]$PesterBoundParameters['WaitSeconds'] -eq 0) { 'Sent' } else { $script:switchOutcome }); Detail = 'the runner said no'; Data = $null; Seconds = 3 }
            }
        }
        # The wait for the interim baseline on a VM this run started (re-review of PR 16, 2026-11-04).
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoProfileRunCommand -MockWith {
            $script:order.Add(('Interim:{0}' -f (@($Record | ForEach-Object { $_.Target }) -join ',')))
            foreach ($item in $Record) {
                [pscustomobject]@{ Target = $item.Target; VmName = $item.VmName; Outcome = $(if ($item.Outcome -eq 'Sent') { 'Set' } else { $item.Outcome }); Detail = 'set'; Data = $null; Seconds = 30 }
            }
        }
        # Phase 28 live finding: what's stopped starts before the first stage that needs it; here both VMs run.
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power[$VmName] }
        # The nightly safety stop's setup (ADR 0024), after the Infrastructure stage.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoSafetyStopSetup -MockWith { New-TestResult 'SAFETYSTOP.SCHEDULE' 'Pass' 'infra' }
        # The history report's snapshot at the end (2026-11-06) has its own tests (DbHubDemo.HistorySnapshot.Tests.ps1); here it
        # notes what had run before it and what it was given, apart from the stages' order, and never reaches Fabric.
        $script:history = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHistorySnapshotStep -MockWith {
            $script:history.Add([pscustomobject]@{ Before = $script:order.ToArray(); DoneChecked = [bool]$PesterBoundParameters['DoneChecked']; SkipFabric = [bool]$PesterBoundParameters['SkipFabric']; WhatIfRun = [bool]$PesterBoundParameters['WhatIfRun'] })
            New-DemoResult -CheckId 'DEPLOY.FABRIC.HISTORY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'Saved the history report''s snapshots.' -Evidence @{ nonBlocking = 'historySnapshot' }
        }
    }

    It 'sets up the nightly safety stop after the Infrastructure stage, and not with -WhatIf (ADR 0024)' {
        $results = @(Invoke-DemoDeployment -Config $config -StopAfter Infrastructure)
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoSafetyStopSetup -Times 1 -Exactly
        ($results | Where-Object { $_.checkId -eq 'SAFETYSTOP.SCHEDULE' }).status | Should -Be 'Pass'
        Invoke-DemoDeployment -Config $config -Resume -WhatIf | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoSafetyStopSetup -Times 1 -Exactly
    }

    It 'starts deallocated VMs while preflight runs, and runs them before the first stage that needs them; running ones are only read (Phase 28 live finding)' {
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $true }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Running:' + $VmName); New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) 'Pass' 'infra' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -MockWith { $script:order.Add('SourceRelease') }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:order.Add('T1Monitoring'); New-TestResult 'DEPLOY.T1.MONITORING' 'Pass' 't1' 'T1' }
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/running' }
        $results = @(Invoke-DemoDeployment -Config $config)
        $script:order[0..6] | Should -Be @('Request:sqlvm01', 'Preflight', 'Running:sqlvm01', 'Switch:T1,T3=baseline', 'Interim:T1,T3', 'Switch:T2=baseline', 'Template') -Because 'it boots while preflight runs, and runs before the template; sqlvm01, which this run started, gets the interim baseline as soon as it runs and the run waits for it (review of PR 16, and its re-review), and archost01, which already ran, gets it next (2026-11-03)'
        $script:order | Should -Not -Contain 'Request:archost01'
        $script:order | Should -Not -Contain 'Running:archost01'
        $script:order | Should -Not -Contain 'T1Monitoring' -Because 'the Monitoring stage runs in this run'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }).status | Should -Be 'Pass'

        # A resume at T2: both start before it, with the golden source's guest and T1's monitoring plugin, which no
        # Monitoring stage of this run checks. The source's release comes as soon as archost01 runs, before its interim
        # baseline (review of PR 17).
        $script:order.Clear()
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' }
        $script:state = New-TestState @{ Stage = 'Monitoring'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('archost01', 'sqlvm01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('archost01', 'sqlvm01') }
        Invoke-DemoDeployment -Config $config -Resume | Out-Null
        $script:order[0..9] | Should -Be @('Request:sqlvm01', 'Request:archost01', 'Running:sqlvm01', 'Switch:T1,T3=baseline', 'Running:archost01', 'SourceRelease', 'Switch:T2=baseline', 'Interim:T1,T3,T2', 'T1Monitoring', 'Arc')
    }

    It 'checks T1''s monitoring plugin on a run without a Monitoring stage, whether or not a VM was stopped, before the first stage that needs the VMs (Phase 28 live finding, 2026-10-30)' {
        # Live: start-demo.ps1 found the plugin running at 07:47; by 09:12 it was NotRunning, and a resumed run whose
        # Monitoring stage had finished earlier never noticed.
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:order.Add(('T1Monitoring:{0}:{1}' -f $CheckId, $Occasion)); New-TestResult 'DEPLOY.T1.MONITORING' 'Pass' 't1' 'T1' }
        $script:state = New-TestState @{ Stage = 'Monitoring'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('archost01', 'sqlvm01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('archost01', 'sqlvm01') }
        $results = @(Invoke-DemoDeployment -Config $config -Resume)
        $script:order[0..2] | Should -Be @('Switch:T1,T3,T2=baseline', 'T1Monitoring:DEPLOY.T1.MONITORING:the deployment', 'Arc') -Because 'VMs that already run get the interim baseline before this run''s Run Commands (2026-11-03)'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.T1.MONITORING' }).status | Should -Be 'Pass'

        # A run with its own Monitoring stage leaves it to that stage.
        $script:order.Clear()
        $script:state = New-TestState
        Invoke-DemoDeployment -Config $config | Out-Null
        @($script:order | Where-Object { $_ -like 'T1Monitoring*' }) | Should -BeNullOrEmpty
    }

    It 'checks T1''s plugin once, and T1''s telemetry again, before its validation fails for missing T1 data, then runs DONE''s checks (Phase 28 live finding, 2026-10-30)' {
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:order.Add('T1Monitoring'); New-TestResult 'DEPLOY.T1.MONITORING' 'Pass' 't1' 'T1' }
        $script:telemetryPolls = 0
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith {
            $script:telemetryPolls++
            $script:order.Add('Telemetry:' + ($Target -join ','))
            foreach ($t in $Target) {
                if ($t -eq 'T1' -and $script:telemetryPolls -eq 1) {
                    New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'No performance telemetry from T1 (sqlvm01) in the last 60 minutes.' -Evidence ([ordered]@{ resourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01'; rows = 0 })
                }
                else {
                    New-TestResult ('TELEMETRY.{0}' -f $t) 'Pass' 'hub' $t
                }
            }
        }
        $script:state = New-TestState @{ Stage = 'Fabric' }
        $results = @(Invoke-DemoDeployment -Config $config -Resume)
        $validation = $script:order.IndexOf('Telemetry:T1,T2,T3')
        $validation | Should -BeGreaterOrEqual 0
        $script:order[($validation + 1)..($validation + 3)] | Should -Be @('T1Monitoring', 'Telemetry:T1', 'Inventory:Fail')
        $script:order | Should -Contain 'DoneGate' -Because 'nothing failed once T1''s data came'
        @($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be @('Pass')
    }

    It 'says what it started keeps running when preflight then fails, and deploys nothing (Phase 28 live finding)' {
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $true }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Running:' + $VmName); New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) 'Pass' 'infra' 'T1' }
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/stopped' }
        $script:preflightStatus = 'Fail'
        $results = @(Invoke-DemoDeployment -Config $config)
        $script:order | Should -Be @('Request:sqlvm01', 'Request:archost01', 'Preflight')
        $warning = $results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }
        $warning.status | Should -Be 'Warning'
        $warning.message | Should -Match 'This run started sqlvm01 and archost01 while preflight ran; it keeps running until \./scripts/stop-demo\.ps1'
    }

    It 'makes sure of the .NET SDK before preflight when the run builds the workload runner, and stops at its Fail before anything is created (-Sequential, 2026-11-09)' {
        $script:sdkStatus = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Initialize-DemoDotNetSdk -MockWith {
            $script:order.Add('Sdk')
            New-DemoResult -CheckId 'DEPLOY.DOTNETSDK' -Area 'preflight' -Target 'repo' -Status $script:sdkStatus -Message ('sdk {0}' -f $script:sdkStatus)
        }
        $results = @(Invoke-DemoDeployment -Config $config)
        $script:order[0..1] | Should -Be @('Sdk', 'Preflight')
        @($script:order | Where-Object { $_ -eq 'Sdk' }).Count | Should -Be 1
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.DOTNETSDK' }).status | Should -Be 'Pass'

        # It couldn't be installed: nothing else runs, and the Insights app's sign-in read stops.
        $script:order.Clear()
        $script:signInCalls.Clear()
        $script:sdkStatus = 'Fail'
        $results = @(Invoke-DemoDeployment -Config $config)
        @($script:order) | Should -Be @('Sdk')
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.DOTNETSDK' }).status | Should -Be 'Fail'
        $script:signInCalls | Should -Contain 'stop'

        # Not with -SkipRunner, a run that stops before the Artifacts stage, or one that starts after it.
        foreach ($run in @(@{ SkipRunner = $true }, @{ StopAfter = 'Infrastructure' }, @{ FromStage = 'Validation' })) {
            $script:order.Clear()
            $null = @(Invoke-DemoDeployment -Config $config @run)
            $script:order | Should -Not -Contain 'Sdk'
        }
    }

    It 'imports the Real-Time Dashboard and the history model and report in the Fabric stage, as the parallel Fabric track does (review follow-up)' {
        # FABRIC.ITEMS.REQUIRED needs them, and a new workspace has neither.
        $results = Invoke-DemoDeployment -Config $config
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -Times 1 -Exactly -ParameterFilter { [bool]$PesterBoundParameters['ImportDashboard'] }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -Times 1 -Exactly
        $script:order[$script:order.IndexOf('Fabric') + 1] | Should -Be 'PowerBI'
        ($results | Where-Object { $_.checkId -eq 'FABRIC.REPORT' }).status | Should -Be 'Pass'

        # A Power BI Fail stops the run at the Fabric stage, as a Fabric Fail does.
        $script:order.Clear()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -MockWith { $script:order.Add('PowerBI'); New-TestResult 'FABRIC.REPORT' 'Fail' 'fabric' 'fabric' }
        $failed = Invoke-DemoDeployment -Config $config
        ($failed | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.FABRIC' }).status | Should -Be 'Fail'
        $script:order | Should -Not -Contain 'DoneGate'
    }

    It 'starts the Insights app''s sign-in before its stages and runs the app''s step after the report; a failed app never stops the stage or keeps the run from DONE (-Sequential, 2026-11-05)' {
        # Every requirement passes, so the outcome turns on the app alone.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDoneGate -MockWith {
            $script:order.Add('DoneGate')
            foreach ($id in @($Requirement)) {
                New-TestResult $id 'Pass' 'hub' 'subscription'
            }
        }
        $results = @(Invoke-DemoDeployment -Config $config)
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignIn -Times 1 -Exactly
        $script:order[$script:order.IndexOf('PowerBI') + 1] | Should -Be 'App'
        @($results | Where-Object { $_.checkId -eq 'DEPLOY.FABRIC.APPSIGNIN' }).Count | Should -Be 1 -Because 'the sign-in''s record is handed out once'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.FABRIC' }).message | Should -Match 'with the Insights app'

        # The app wasn't created: its step's record never blocks, the stage passes, and the run goes on to DONE.
        $script:order.Clear()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoInsightsAppStep -MockWith {
            $script:order.Add('App')
            New-DemoResult -CheckId 'DEPLOY.FABRIC.APP' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The Insights app''s step failed: rayfin up exited with code 1.' -Remediation 'Run ./scripts/configure-fabric-app.ps1 -SignIn.' -Evidence ([ordered]@{ nonBlocking = 'insightsApp'; reportedStatus = 'Fail' })
        }
        $appFailed = @(Invoke-DemoDeployment -Config $config)
        $stage = $appFailed | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.FABRIC' }
        $stage.status | Should -Be 'Pass'
        $stage.message | Should -Match 'the Insights app wasn''t created or doesn''t work, which doesn''t block DONE'
        $script:order | Should -Contain 'DoneGate'
        @($appFailed | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $appFailed; State = $script:state; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Sequential }
        $outcome.Kind | Should -Be 'Done' -Because ('Missing: {0}; reason: {1}' -f (@($outcome.Missing) -join ', '), $outcome.Reason)
        $outcome.ExitCode | Should -Be 0
        (@($outcome.NonBlocking | ForEach-Object { [string]$_['message'] }) -join ' ') | Should -Match 'rayfin up exited with code 1'

        # -SkipFabric starts no sign-in and runs no app step.
        $script:order.Clear()
        Invoke-DemoDeployment -Config $config -SkipFabric | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignIn -Times 2 -Exactly -Because 'only the two runs above started it'
        $script:order | Should -Not -Contain 'App'
    }

    It 'reads the Rayfin CLI''s sign-in from before the guard when the Fabric stage can run, and the sign-in''s start takes that read (-Sequential, 2026-11-06)' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { $script:signInCalls.Add('guard'); New-TestResult 'PREFLIGHT.GUARD.CONTEXT' 'Pass' 'preflight' }
        Invoke-DemoDeployment -Config $config | Out-Null
        @($script:signInCalls) | Should -Be @('check', 'guard') -Because 'the read runs alongside the guard, and the sign-in''s start uses it'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignIn -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($Check, $script:signInCheck) }

        # A run whose stages can't reach the Fabric stage reads nothing.
        $script:signInCalls.Clear()
        Invoke-DemoDeployment -Config $config -StopAfter Infrastructure | Out-Null
        Invoke-DemoDeployment -Config $config -SkipFabric | Out-Null
        $script:signInCalls | Should -Not -Contain 'check'

        # A resume that turns out to start after the Fabric stage ends the read it started for nothing.
        $script:state = New-TestState @{ Stage = 'Fabric' }
        Invoke-DemoDeployment -Config $config -Resume | Out-Null
        @($script:signInCalls | Where-Object { $_ -ne 'guard' }) | Should -Be @('check', 'stop')
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignIn -Times 1 -Exactly
    }

    It 'ends the read of the Rayfin CLI''s sign-in when the guard stops the run (-Sequential, 2026-11-06)' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'Subscription guard: check ''account'' failed: the Azure CLI has no sign-in for the subscription. Nothing was changed.' }
        $results = @(Invoke-DemoDeployment -Config $config)
        ($results | Where-Object { $_.checkId -eq 'PREFLIGHT.GUARD.CONTEXT' }).status | Should -Be 'Fail'
        @($script:signInCalls) | Should -Be @('check', 'stop')
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppSignIn -Times 0 -Exactly
    }

    It 'settles the sign-in''s Warning from the app step''s records, so the two agree (-Sequential, live, 2026-11-06)' {
        # The live run: the sign-in's row said the app isn't created, and the app's row said it's deployed.
        $newSignIn = { [pscustomobject]@{ Process = $null; Done = $true; Reported = $false; Result = (New-DemoResult -CheckId 'DEPLOY.FABRIC.APPSIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Warning' -Message 'Nobody finished the Rayfin CLI''s sign-in within 15 minutes, so it was stopped. The deployment went on; without the sign-in the Insights app isn''t created, and its step says why.') } }
        $script:appSignIn = & $newSignIn
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoInsightsAppStep -MockWith { $script:order.Add('App'); New-TestResult 'FABRIC.APP.SIGNIN' 'Pass' 'fabric' 'tenant'; New-TestResult 'FABRIC.APP.DEPLOY' 'Pass' 'fabric' 'fabric' }
        $results = @(Invoke-DemoDeployment -Config $config)
        $signIn = @($results | Where-Object { $_.checkId -eq 'DEPLOY.FABRIC.APPSIGNIN' })
        $signIn.Count | Should -Be 1
        $signIn[0].status | Should -Be 'Pass'
        $signIn[0].message | Should -Match 'the Insights app''s step found it signed in and used that sign-in'
        $signIn[0].message | Should -Not -Match 'isn''t created'

        # An app step that found no sign-in either leaves the Warning as it was.
        $script:appSignIn = & $newSignIn
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoInsightsAppStep -MockWith { $script:order.Add('App'); New-TestResult 'FABRIC.APP.SIGNIN' 'Manual action required' 'fabric' 'tenant' }
        $results = @(Invoke-DemoDeployment -Config $config)
        @($results | Where-Object { $_.checkId -eq 'DEPLOY.FABRIC.APPSIGNIN' }).status | Should -Be 'Warning'
    }

    It 'can end DONE on a new workspace, because its Fabric stage creates what FABRIC.ITEMS.REQUIRED looks for (review follow-up)' {
        # Before, every stage passed on a new workspace and the run still ended NOT DONE with exit code 1.
        $names = InModuleScope DbHubDemo { Get-DemoFabricAppSetting }
        $script:workspace = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:required = @([string]$names['dashboardName'], [string]$names['semanticModelName'], [string]$names['reportName'])
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricStage -MockWith {
            $script:order.Add('Fabric')
            if ([bool]$PesterBoundParameters['ImportDashboard']) {
                $null = $script:workspace.Add($script:required[0])
            }
            New-TestResult 'HUB.CHECKLIST' 'Pass' 'hub' 'fabric'
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -MockWith {
            $script:order.Add('PowerBI')
            $null = $script:workspace.Add($script:required[1])
            $null = $script:workspace.Add($script:required[2])
            New-TestResult 'FABRIC.REPORT' 'Pass' 'fabric' 'fabric'
        }
        # DONE's read-only checks: every target shows in Database Hub, and the Fabric items pass only when they're in the workspace.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDoneGate -MockWith {
            $missing = @($script:required | Where-Object { -not $script:workspace.Contains($_) })
            foreach ($id in @($Requirement | Where-Object { $_ -ne 'FABRIC.ITEMS.REQUIRED' })) {
                New-TestResult $id 'Pass' 'hub' 'subscription'
            }
            New-TestResult 'FABRIC.ITEMS.REQUIRED' $(if ($missing.Count -eq 0) { 'Pass' } else { 'Fail' }) 'fabric' 'fabric'
        }
        $results = @(Invoke-DemoDeployment -Config $config)
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $results; State = $script:state; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Sequential }
        ($results | Where-Object { $_.checkId -eq 'FABRIC.ITEMS.REQUIRED' }).status | Should -Be 'Pass'
        $outcome.Kind | Should -Be 'Done' -Because ('Missing: {0}; reason: {1}' -f (@($outcome.Missing) -join ', '), $outcome.Reason)
        $outcome.ExitCode | Should -Be 0
    }

    It 'records that the T2 host''s loader started a bootstrap generation, and clears it once T2 is done (review follow-up)' {
        # The watchdog never restarts the host while that generation may still build its guest (Get-DemoHostRestartBlocker).
        Invoke-DemoDeployment -Config $config | Out-Null
        $marks = @($script:recorded | Where-Object { $_.Contains('T2BuildUtc') } | ForEach-Object { if ($_['T2BuildUtc']) { 'set' } else { 'clear' } })
        $marks | Should -Be @('set', 'clear')
        $script:state.T2BuildUtc | Should -BeNullOrEmpty

        # T2 left open (the wizard step waits): the generation stays on record.
        $script:recorded.Clear()
        $script:arcStatus = 'Manual action required'
        Invoke-DemoDeployment -Config $config | Out-Null
        @($script:recorded | Where-Object { $_.Contains('T2BuildUtc') } | ForEach-Object { if ($_['T2BuildUtc']) { 'set' } else { 'clear' } }) | Should -Be @('set')
    }

    It 'cleans up in the T2 stage what an earlier guided stop left open, and isn''t DONE while it stays open (Phase 28 review)' {
        # After a Ctrl+C at a parallel run's guided stop, setup can finish anyway; a -Sequential rerun left Bastion up and
        # the handed-over host password valid, and could end DONE.
        $script:state = New-TestState @{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '2026-10-29T16:00:00Z' }
        Mock -ModuleName DbHubDemo -CommandName Complete-DemoGuidedStop -MockWith {
            $script:order.Add('Cleanup')
            $script:state.HostPasswordUtc = ''
            $script:state.GuidedStopUtc = ''
            @()
        }
        $results = @(Invoke-DemoDeployment -Config $config)
        $script:order[$script:order.IndexOf('Arc') + 1] | Should -Be 'Cleanup'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }).status | Should -Be 'Pass'

        # A cleanup that couldn't rotate the password: the run says so, names stop-demo.ps1, and isn't DONE.
        $script:order.Clear()
        $script:state = New-TestState @{ HostPasswordUtc = '2026-10-29T15:00:00Z'; GuidedStopUtc = '' }
        Mock -ModuleName DbHubDemo -CommandName Complete-DemoGuidedStop -MockWith { $script:order.Add('Cleanup'); @() }
        $open = @(Invoke-DemoDeployment -Config $config)
        ($open | Where-Object { $_.checkId -eq 'DEPLOY.T2.GUIDEDLEFTOVER' }).status | Should -Be 'Manual action required'
        $outcome = InModuleScope DbHubDemo -Parameters @{ Result = $open; State = $script:state; Config = $config } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -Sequential }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.NextCommand | Should -Be './scripts/stop-demo.ps1 -RemoveBastionOnly'
    }

    It 'runs DONE''s read-only checks after the validation, as the parallel path does, so a sequential run can end DONE (review finding 4)' {
        $results = Invoke-DemoDeployment -Config $config
        $script:order[-2..-1] | Should -Be @('DoneGate', 'Switch:T1,T3,T2=business-day') -Because 'the switch to business-day comes after DONE''s reads (2026-11-03)'
        # DONE needs T4 like the other targets, whatever this run's configuration says (2026-11-09).
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDoneGate -Times 1 -Exactly -ParameterFilter { $Requirement -contains 'HUB.ESTATE.T1' -and $Requirement -contains 'T2.ARC.SQLINSTANCE' -and $Requirement -contains 'FABRIC.ITEMS.REQUIRED' -and $Requirement -contains 'HUB.ESTATE.T4' -and $Requirement -contains 'METRICS.T4' }
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
            'Preflight', 'Switch:T1,T3,T2=baseline', 'Template', 'Bundle', 'SendBundle:sqlvm01', 'SendBundle:archost01', 'Publish', 'SendRunner:sqlvm01', 'SendRunner:archost01',
            'Template+Bundle', 'Loader:sqlvm01', 'Loader:archost01', 'T1Ready', 'Group', 'T3Setup', 'EnableT3', 'TestT3',
            'Profile:T1=baseline', 'Profile:T3=baseline', 'Monitoring', 'Arc', 'Profile:T2=baseline', 'Fabric', 'PowerBI', 'App', 'Telemetry:T1,T2,T3', 'Inventory:Fail', 'RunnerStatus', 'DoneGate', 'Switch:T1,T3,T2=business-day'
        )
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.SUMMARY' }).status | Should -Be 'Pass'
        $script:state.Stage | Should -Be 'Validation'
        @($script:state.BundleSentTo | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        @($script:state.RunnerSentTo | Sort-Object) | Should -Be @('archost01', 'sqlvm01')
        $script:state.RunnerSha256 | Should -Be $script:runnerSha
        @($results | ForEach-Object { $_.checkId } | Where-Object { $_ -like 'DEPLOY.STAGE.*' }).Count | Should -Be 11
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.T4' }).status | Should -Be 'Not selected' -Because 'T4 is off in this test configuration'
    }

    It 'sets the interim baseline in its stages and switches to business-day after DONE''s reads, for a configuration without activityProfile too (-Sequential, 2026-11-03)' {
        $unset = New-TestConfig
        $unset.Remove('activityProfile')
        $results = @(Invoke-DemoDeployment -Config $unset)
        @($script:order | Where-Object { $_ -like 'Profile:*' }) | Should -Be @('Profile:T1=baseline', 'Profile:T3=baseline', 'Profile:T2=baseline')
        $script:order[-2..-1] | Should -Be @('DoneGate', 'Switch:T1,T3,T2=business-day')
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoTargetProfile -Times 3 -Exactly -ParameterFilter { $ProfileName -eq 'baseline' -and $SwitchTo -eq 'business-day' }
        foreach ($target in 'T1', 'T3', 'T2') {
            ($results | Where-Object { $_.checkId -eq ('DEPLOY.INCIDENTS_{0}' -f $target) }).status | Should -Be 'Pass'
        }
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        [array]::IndexOf($ids, 'DEPLOY.INCIDENTS_T1') | Should -BeLessThan ([array]::IndexOf($ids, 'DEPLOY.SUMMARY'))
        $unset.Contains('activityProfile') | Should -BeFalse -Because 'the run never writes the configuration'

        # A resumed run that skips preflight says once that it uses the default (DEPLOY.ACTIVITYPROFILE).
        $script:order.Clear()
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { New-TestResult 'DEPLOY.T1.MONITORING' 'Pass' 't1' 'T1' }
        $script:state = New-TestState @{ Stage = 'Monitoring'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('archost01', 'sqlvm01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('archost01', 'sqlvm01') }
        $resumed = @(Invoke-DemoDeployment -Config $unset -Resume)
        $notice = @($resumed | Where-Object { $_.checkId -eq 'DEPLOY.ACTIVITYPROFILE' })
        $notice.Count | Should -Be 1
        $notice[0].message | Should -Match 'uses the new default, business-day \(incidents every hour\); set it to baseline for the quieter demo'
        $script:order[0] | Should -Be 'Switch:T1,T3,T2=baseline' -Because 'both VMs already ran'
        $script:order[-1] | Should -Be 'Switch:T1,T3,T2=business-day'
    }

    It 'keeps an explicit baseline: no switch (-Sequential)' {
        $quiet = New-TestConfig
        $quiet['activityProfile'] = 'baseline'
        $results = @(Invoke-DemoDeployment -Config $quiet)
        $script:order[-1] | Should -Be 'DoneGate'
        @($script:order | Where-Object { $_ -like 'Switch:*' }) | Should -BeNullOrEmpty
        @($results | Where-Object { $_.checkId -like 'DEPLOY.INCIDENTS_*' -or $_.checkId -eq 'DEPLOY.ACTIVITYPROFILE' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoTargetProfile -Times 3 -Exactly -ParameterFilter { $ProfileName -eq 'baseline' -and -not $SwitchTo }
    }

    It 'takes the history report''s snapshot last: after DONE''s checks and the switch, before DEPLOY.SUMMARY (-Sequential, 2026-11-06)' {
        $results = @(Invoke-DemoDeployment -Config $config)
        $script:history.Count | Should -Be 1
        $script:history[0].Before[-2..-1] | Should -Be @('DoneGate', 'Switch:T1,T3,T2=business-day') -Because 'DONE''s checks read first, and the VMs'' incidents don''t wait for Spark'
        $script:history[0].DoneChecked | Should -BeTrue
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        [array]::IndexOf($ids, 'DEPLOY.FABRIC.HISTORY') | Should -BeGreaterThan ([array]::IndexOf($ids, 'DEPLOY.INCIDENTS_T1'))
        [array]::IndexOf($ids, 'DEPLOY.FABRIC.HISTORY') | Should -BeLessThan ([array]::IndexOf($ids, 'DEPLOY.SUMMARY'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoHistorySnapshotStep -Times 1 -Exactly -ParameterFilter {
            [bool]$PesterBoundParameters['DoneChecked'] -and -not [bool]$PesterBoundParameters['SkipFabric'] -and -not [bool]$PesterBoundParameters['WhatIfRun'] -and [string]$ActivityProfile.Name -eq 'business-day' -and
            @($Requirement) -contains 'TELEMETRY.T2' -and @($Requirement) -contains 'FABRIC.ITEMS.REQUIRED' -and
            @($Result | Where-Object { [string]$_.checkId -eq 'HUB.ESTATE.T1' }).Count -gt 0
        }
    }

    It 'tells the snapshot when DONE''s checks didn''t run, passes -SkipFabric on, takes none on a run that stops before its validation, and reports it Not selected with -WhatIf (-Sequential, 2026-11-06)' {
        # T2 waits for a manual step, so DONE's checks don't run; the validation still does.
        $script:arcStatus = 'Manual action required'
        Invoke-DemoDeployment -Config $config | Out-Null
        $script:history.Count | Should -Be 1
        $script:history[0].DoneChecked | Should -BeFalse

        $script:arcStatus = 'Pass'
        $script:history.Clear()
        $script:state = New-TestState
        Invoke-DemoDeployment -Config $config -SkipFabric | Out-Null
        $script:history[0].SkipFabric | Should -BeTrue

        $script:history.Clear()
        $script:state = New-TestState
        Invoke-DemoDeployment -Config $config -StopAfter Fabric | Out-Null
        $script:history.Count | Should -Be 0

        $script:order.Clear()
        $script:state = New-TestState
        $results = @(Invoke-DemoDeployment -Config $config -Resume -WhatIf)
        $script:order | Should -Be @('Preflight', 'Template')
        $script:history.Count | Should -Be 1
        $script:history[0].WhatIfRun | Should -BeTrue
        $results[-1].checkId | Should -Be 'DEPLOY.FABRIC.HISTORY'
    }

    It 'still switches when it stops at a Fail after the profiles were set, so no VM stays on the interim baseline (-Sequential)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoPowerBIStage -MockWith { $script:order.Add('PowerBI'); New-TestResult 'FABRIC.REPORT' 'Fail' 'fabric' 'fabric' }
        $results = @(Invoke-DemoDeployment -Config $config)
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.STAGE.FABRIC' }).status | Should -Be 'Fail'
        $script:order | Should -Not -Contain 'DoneGate'
        $script:order[-1] | Should -Be 'Switch:T1,T3,T2=business-day'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.INCIDENTS_T2' }).status | Should -Be 'Pass'
    }

    It 'reports a switch that doesn''t finish in time as a Warning, never a Fail (-Sequential)' {
        $script:switchOutcome = 'TimedOut'
        $results = @(Invoke-DemoDeployment -Config $config)
        foreach ($target in 'T1', 'T3', 'T2') {
            ($results | Where-Object { $_.checkId -eq ('DEPLOY.INCIDENTS_{0}' -f $target) }).status | Should -Be 'Warning'
        }
        @($results | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
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
        $script:order[0..1] | Should -Be @('Switch:T1,T3,T2=baseline', 'Arc')
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
        $script:order | Should -Be @('Preflight', 'Switch:T1,T3,T2=baseline', 'Template', 'Switch:T1,T3,T2=business-day') -Because 'VMs that already run get the interim baseline first, and the profile back at the end (2026-11-03)'
        $script:state.Stage | Should -Be 'Infrastructure'
    }

    It 'resets the parallel tracks'' records once its preflight passed, so a later plain deploy.ps1 never resumes past a step this run does again (Phase 28 live finding, 2026-10-30)' {
        # -Sequential records only its stages; a parallel run's records from before it could let a later parallel resume skip
        # a step that this run did again and that failed.
        $script:state = New-TestState @{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = ''; TrackFabric = 'Fabric' }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith {
            $script:recorded.Add(@{} + $Value)
            if ($Value.Contains('TrackT1')) {
                $script:order.Add('ResetTracks')
            }
            foreach ($key in $Value.Keys) {
                $script:state.$key = $Value[$key]
            }
        }
        Invoke-DemoDeployment -Config $config -StopAfter Infrastructure | Out-Null
        $script:order | Should -Be @('Preflight', 'ResetTracks', 'Switch:T1,T3,T2=baseline', 'Template', 'Switch:T1,T3,T2=business-day')
        $script:state.TrackT1 | Should -Be ''
        $script:state.TrackT2 | Should -Be ''
        $script:state.TrackFabric | Should -Be '' -Because 'a run that starts over trusts nothing recorded before it'

        # A preflight Fail resets nothing.
        $script:order.Clear()
        $script:state = New-TestState @{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = ''; TrackFabric = 'Fabric' }
        $script:preflightStatus = 'Fail'
        Invoke-DemoDeployment -Config $config | Out-Null
        $script:order | Should -Be @('Preflight')
        $script:state.TrackFabric | Should -Be 'Fabric'

        # -Resume lowers only the records of the steps it does again.
        $script:order.Clear()
        $script:recorded.Clear()
        $script:preflightStatus = 'Pass'
        $script:state = New-TestState @{ Stage = 'Monitoring'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = ''; TrackFabric = 'Fabric'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('archost01', 'sqlvm01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('archost01', 'sqlvm01') }
        Invoke-DemoDeployment -Config $config -Resume | Out-Null
        $script:order[0..2] | Should -Be @('ResetTracks', 'Switch:T1,T3,T2=baseline', 'Arc')
        $reset = @($script:recorded | Where-Object { $_.ContainsKey('TrackT1') })[0]
        $reset['TrackT1'] | Should -Be 'Monitoring'
        $reset['TrackT2'] | Should -Be 'Bootstraps'
        $reset['TrackFabric'] | Should -Be ''
    }

    It 'deploys the opt-in Key Vault after the template, and a vault Fail is reported without stopping the run' {
        $vaultConfig = New-TestConfig
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        Mock -ModuleName DbHubDemo -CommandName Initialize-DemoKeyVault -MockWith { $script:order.Add('KeyVault'); New-TestResult 'INFRA.KEYVAULT' 'Fail' }
        $results = Invoke-DemoDeployment -Config $vaultConfig
        $script:order[0..3] | Should -Be @('Preflight', 'Switch:T1,T3,T2=baseline', 'Template', 'KeyVault')
        $script:order[-2..-1] | Should -Be @('RunnerStatus', 'Switch:T1,T3,T2=business-day') -Because 'a run that isn''t DONE switches from the interim baseline too (2026-11-03)'
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
        # The profiles go off in one managed Run Command per VM, waited for at most -WaitSeconds (2026-11-03).
        $script:offOutcome = @{}
        Mock -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -MockWith {
            foreach ($item in $Target) {
                $script:order.Add(('Profile:{0}={1}' -f $item, $ProfileName))
            }
            foreach ($item in $Target) {
                $outcome = if ($script:offOutcome.ContainsKey($item)) { $script:offOutcome[$item] } else { 'Set' }
                [pscustomobject]@{ Target = $item; VmName = $(if ($item -eq 'T2') { 'archost01' } else { 'sqlvm01' }); Outcome = $outcome; Detail = 'the runner said no'; Data = $null; Seconds = [int]$PesterBoundParameters['WaitSeconds'] }
            }
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

    It 'turns the profiles off in one bounded wait for both VMs, then stops the guest and deallocates anyway (2026-11-03)' {
        $script:offOutcome = @{ T1 = 'TimedOut'; T3 = 'TimedOut'; T2 = 'TimedOut' }
        $results = @(Stop-DemoEnvironment -Config $config -Confirm:$false)
        $script:order | Should -Be @('Bastion', 'Rotate:archost01', 'Profile:T1=off', 'Profile:T3=off', 'Profile:T2=off', 'Guest', 'Deallocate:archost01', 'Deallocate:sqlvm01')
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { $ProfileName -eq 'off' -and $WaitSeconds -eq 180 -and (@($Target) -join ',') -eq 'T1,T3,T2' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Stop-DemoGuestVm -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 180 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 0 -Exactly
        foreach ($target in 'T1', 'T3', 'T2') {
            $off = $results | Where-Object { $_.checkId -eq ('STOP.PROFILE_{0}' -f $target) }
            $off.status | Should -Be 'Warning'
            $off.message | Should -Match 'didn''t finish within 180 seconds'
            $off.message | Should -Match 'was deallocated anyway \(STOP\.VM_(SQLVM01|ARCHOST01)\), which stops the incident with it'
        }
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        [array]::IndexOf($ids, 'STOP.PROFILE_T1') | Should -BeGreaterThan ([array]::IndexOf($ids, 'STOP.VM_SQLVM01')) -Because 'the Warning says the VM was deallocated, so it comes after the deallocation'
    }

    It 'says so when a VM that didn''t turn its profile off wasn''t deallocated either' {
        $script:offOutcome = @{ T1 = 'TimedOut' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Deallocate:' + $VmName); New-TestResult ('STOP.VM_{0}' -f $VmName.ToUpperInvariant()) $(if ($VmName -eq 'sqlvm01') { 'Fail' } else { 'Pass' }) 'infra' 'T1' }
        $results = @(Stop-DemoEnvironment -Config $config -Confirm:$false)
        $t1 = $results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T1' }
        $t1.status | Should -Be 'Warning'
        $t1.message | Should -Match 'wasn''t deallocated either'
        ($results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T3' }).status | Should -Be 'Pass'
    }

    It 'reports T2''s guest that isn''t running as Not selected, with the others before the deallocation: nothing to turn off there (review of PR 17)' {
        $script:offOutcome = @{ T2 = 'GuestOff' }
        $results = @(Stop-DemoEnvironment -Config $config -Confirm:$false)
        $t2 = $results | Where-Object { $_.checkId -eq 'STOP.PROFILE_T2' }
        $t2.status | Should -Be 'Not selected'
        $t2.message | Should -Match '^T2: nothing to turn off: the runner said no\. The profile stored in the guest'
        $ids = @($results | ForEach-Object { [string]$_.checkId })
        [array]::IndexOf($ids, 'STOP.PROFILE_T2') | Should -BeLessThan ([array]::IndexOf($ids, 'STOP.VM_ARCHOST01'))
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
        # The switch from the interim baseline to a profile with incidents (2026-11-03): one managed Run Command per VM.
        $script:switchOutcome = 'Set'
        Mock -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -MockWith {
            $script:order.Add(('Switch:{0}={1}' -f (@($Target) -join ','), $ProfileName))
            foreach ($item in $Target) {
                [pscustomobject]@{ Target = $item; VmName = $(if ($item -eq 'T2') { 'archost01' } else { 'sqlvm01' }); Outcome = $(if ([int]$PesterBoundParameters['WaitSeconds'] -eq 0) { 'Sent' } else { $script:switchOutcome }); Detail = 'the runner said no'; Data = $null; Seconds = 4 }
            }
        }
        # The wait for the interim baseline on a VM this start booted (re-review of PR 16, 2026-11-04).
        $script:interimOutcome = 'Set'
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoProfileRunCommand -MockWith {
            $script:order.Add(('Interim:{0}' -f (@($Record | ForEach-Object { $_.Target }) -join ',')))
            foreach ($item in $Record) {
                [pscustomobject]@{ Target = $item.Target; VmName = $item.VmName; Outcome = $(if ($item.Outcome -eq 'Sent') { $script:interimOutcome } else { $item.Outcome }); Detail = 'sqlvm01 didn''t finish it within 750 seconds'; Data = [ordered]@{ evidence = [ordered]@{ attempts = 3 } }; Seconds = 41 }
            }
        }
        # The on-demand control's Run Command cleanup (Phase 28 follow-up) has its own tests below; here it records when it ran.
        $script:cleanup = $null
        $script:cleanupAt = -1
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoControlRunCommand -MockWith { $script:cleanupAt = $script:order.Count; $script:cleanup }
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

    It 'checks the cost, starts the VMs, resumes T3, and sets the configured profile everywhere: baseline first, then business-day once its own Run Commands are done (2026-11-03)' {
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        # A VM this start booted gets the interim baseline as soon as it runs, and its own Run Commands wait for it (review of
        # PR 16, and its re-review).
        $script:order | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'Start:sqlvm01', 'Switch:T1,T3=baseline', 'Start:archost01', 'SourceRelease', 'Switch:T2=baseline', 'Interim:T1,T3,T2', 'T1Monitoring', 'WarmT3', 'Profile:T1=baseline', 'Profile:T3=baseline', 'Profile:T2=baseline', 'Switch:T1,T3,T2=business-day')
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { $ProfileName -eq 'business-day' -and $WaitSeconds -eq 180 -and $RequestedBy -eq 'start-demo' }
        foreach ($target in 'T1', 'T3', 'T2') {
            $switch = $results | Where-Object { $_.checkId -eq ('START.INCIDENTS_{0}' -f $target) }
            $switch.status | Should -Be 'Pass'
            $switch.message | Should -Match 'They started only once this run''s own Run Commands on (sqlvm01|archost01) were done, so none slowed them'
        }
        ($results | Where-Object { $_.checkId -eq 'START.INCIDENTS_T2' }).message | Should -Match ':05 \(cpu-pressure, 8 minutes\), :20 \(missing-index, 8 minutes\), :35 \(io-pressure, 8 minutes\), and :50 \(inefficient-query, 6 minutes\) past each UTC hour'
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T1' }).message | Should -Match 'business-day'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoStartCost -Times 1 -Exactly -ParameterFilter { $ActivityProfile -eq 'business-day' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like 'Activity: business-day:*set activityProfile to baseline for a quiet demo*' } -Times 1 -Exactly
    }

    It 'clears an earlier run''s record that left T4 out, which no longer holds, and keeps any other record (2026-11-09)' {
        $script:recorded = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:recorded.Add($Value) }
        $base = @{ Stage = 'Validation'; BundleSha256 = $script:sha; BundleChunkCount = 1; BundleSentTo = @('sqlvm01', 'archost01'); RunnerSha256 = $script:runnerSha; RunnerChunkCount = 7; RunnerSentTo = @('sqlvm01', 'archost01') }
        foreach ($old in 'None', 'Refused') {
            $script:recorded.Clear()
            $script:state = New-TestState ($base + @{ T4Sku = $old })
            $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
            $record = @($results | Where-Object { $_.checkId -eq 'START.T4.RECORD' })
            $record.Count | Should -Be 1 -Because $old
            $record[0].status | Should -Be 'Pass'
            $record[0].message | Should -Match ('DbHubT4Size {0}\): T4 is part of every deployment' -f $old)
            @($script:recorded | Where-Object { $_.Contains('T4Sku') -and $_['T4Sku'] -eq '' -and $_.Contains('T4Refused') -and $_['T4Refused'] -eq '' }).Count | Should -Be 1 -Because ('{0}, with what Azure refused (DbHubT4Refused, 2026-11-09)' -f $old)
        }
        foreach ($kept in '', 'Standard_D2ds_v5') {
            $script:recorded.Clear()
            $script:state = New-TestState ($base + @{ T4Sku = $kept })
            $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
            $results | Where-Object { $_.checkId -eq 'START.T4.RECORD' } | Should -BeNullOrEmpty
            @($script:recorded | Where-Object { $_.Contains('T4Sku') }).Count | Should -Be 0 -Because ('a record of "{0}" stays' -f $kept)
        }
        # A record that can't be cleared is a Warning, and the start goes on.
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { throw 'The tag write was refused.' }
        $script:state = New-TestState ($base + @{ T4Sku = 'None' })
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        ($results | Where-Object { $_.checkId -eq 'START.T4.RECORD' }).status | Should -Be 'Warning'
        $script:order | Should -Contain 'Start:sqlvm01'
    }
    It 'uses business-day for a configuration without activityProfile, says so once, and checks the cost with it (2026-11-03)' {
        $unset = New-TestConfig
        $unset.Remove('activityProfile')
        $results = @(Start-DemoEnvironment -Config $unset -Confirm:$false)
        $notice = @($results | Where-Object { $_.checkId -eq 'START.ACTIVITYPROFILE' })
        $notice.Count | Should -Be 1
        $notice[0].status | Should -Be 'Pass'
        $notice[0].message | Should -Match ([regex]::Escape('activityProfile isn''t set, so this run uses the new default, business-day (incidents every hour); set it to baseline for the quieter demo.'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'activityProfile isn''t set, so this run uses the new default, business-day*' } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoStartCost -Times 1 -Exactly -ParameterFilter { $ActivityProfile -eq 'business-day' }
        $script:order | Should -Contain 'Switch:T1,T3,T2=business-day'
        ($results | Where-Object { $_.checkId -eq 'START.INCIDENTS_T1' }).message | Should -Match 'business-day is the default because activityProfile isn''t set; set it to baseline for the quieter demo'
        $unset.Contains('activityProfile') | Should -BeFalse -Because 'the run never writes the configuration'

        # The notice comes with -SkipCostCheck too.
        $skipped = @(Start-DemoEnvironment -Config $unset -SkipCostCheck -Confirm:$false)
        @($skipped | Where-Object { $_.checkId -eq 'START.ACTIVITYPROFILE' }).Count | Should -Be 1
    }

    It 'keeps an explicit baseline, from the configuration or -ActivityProfile: no switch, no notice' {
        $quiet = New-TestConfig
        $quiet['activityProfile'] = 'baseline'
        $results = @(Start-DemoEnvironment -Config $quiet -Confirm:$false)
        $script:order | Should -Contain 'Profile:T2=baseline'
        @($script:order | Where-Object { $_ -like 'Switch:*' }) | Should -BeNullOrEmpty
        @($results | Where-Object { $_.checkId -like 'START.ACTIVITYPROFILE' -or $_.checkId -like 'START.INCIDENTS_*' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoStartCost -Times 1 -Exactly -ParameterFilter { $ActivityProfile -eq 'baseline' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like 'Activity: baseline:*problem panels stay empty*set activityProfile to business-day*' } -Times 1 -Exactly

        $script:order.Clear()
        Start-DemoEnvironment -Config $config -ActivityProfile 'baseline' -Confirm:$false | Out-Null
        @($script:order | Where-Object { $_ -like 'Switch:*' }) | Should -BeNullOrEmpty
        $script:order | Should -Contain 'Profile:T1=baseline'
    }

    It 'leaves a VM the caller still sends Run Commands to on the interim baseline for the caller to switch (-HoldActivitySwitchVm)' {
        Start-DemoEnvironment -Config $config -HoldActivitySwitchVm 'archost01' -Confirm:$false | Out-Null
        $script:order[-1] | Should -Be 'Switch:T1,T3=business-day'
        InModuleScope DbHubDemo { @(Get-DemoActivitySwitchVm) } | Should -Be @('archost01')
        InModuleScope DbHubDemo { Clear-DemoActivitySwitch }
    }

    It 'sets the interim baseline first on a VM that already ran, before its own Run Commands there, and switches it back at the end (2026-11-03)' {
        # An earlier start, or a deploy.ps1 that ended NOT DONE, can have left business-day's incidents running.
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $false }
        Start-DemoEnvironment -Config $config -SkipT3 -Confirm:$false | Out-Null
        $script:order | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'Switch:T1,T2=baseline', 'Start:sqlvm01', 'Start:archost01', 'SourceRelease', 'T1Monitoring', 'Profile:T1=baseline', 'Profile:T2=baseline', 'Switch:T1,T2=business-day') -Because '-SkipT3 leaves T3 alone, quiet included'
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { $ProfileName -eq 'baseline' -and $WaitSeconds -eq 0 -and $ExpiresMinutes -eq 10 }

        # An explicit baseline has no incidents to quiet.
        $script:order.Clear()
        $quiet = New-TestConfig
        $quiet['activityProfile'] = 'baseline'
        Start-DemoEnvironment -Config $quiet -SkipT3 -Confirm:$false | Out-Null
        @($script:order | Where-Object { $_ -like 'Switch:*' }) | Should -BeNullOrEmpty
    }

    It 'sets the interim baseline on a VM this start booted as soon as it runs, before its own Run Commands there, and says why (review of PR 16)' {
        # Reviewer: a stored business-day can outlive a stop, and the profile host resumes it about 2 minutes after the
        # boot, while the start's own Run Commands (the monitoring restore, T3's warm-up, the profiles) still run.
        Start-DemoEnvironment -Config $config -Confirm:$false | Out-Null
        $script:order.IndexOf('Switch:T1,T3=baseline') | Should -Be ($script:order.IndexOf('Start:sqlvm01') + 1)
        # The golden source's release comes first on archost01 (review of PR 17): it runs Run Commands only on a guest the
        # capture left off, where no incident runs, and the interim must never wait for such a guest.
        $script:order.IndexOf('SourceRelease') | Should -Be ($script:order.IndexOf('Start:archost01') + 1)
        $script:order.IndexOf('Switch:T2=baseline') | Should -Be ($script:order.IndexOf('SourceRelease') + 1)
        $script:order.IndexOf('Interim:T1,T3,T2') | Should -BeLessThan $script:order.IndexOf('T1Monitoring') -Because 'the first Run Command on sqlvm01 waits for its interim'
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 2 -Exactly -ParameterFilter { $ProfileName -eq 'baseline' -and $WaitSeconds -eq 0 -and $ExpiresMinutes -eq 10 -and $RequestedBy -eq 'start-demo' -and $RetrySeconds -eq 15 -and $RunnerTimeoutSeconds -eq 120 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'sqlvm01 started, so T1 and T3 get the interim baseline before this run''s own Run Commands there: its profile host resumes the profile stored there about 2 minutes after the boot. The VM tries every 15 seconds until it''s set, for at most 10 minutes, while its SQL Server starts; business-day comes back at the end.' }
    }

    It 'waits for the interim baseline on a VM it booted before its own Run Commands there, and reports one not set in time as a Warning with the commands (re-review of PR 16)' {
        $script:interimOutcome = 'TimedOut'
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        $script:order.IndexOf('Interim:T1,T3,T2') | Should -BeLessThan $script:order.IndexOf('T1Monitoring')
        $late = $results | Where-Object { $_.checkId -eq 'START.INTERIM_T1' }
        $late.status | Should -Be 'Warning'
        $late.message | Should -Match '^T1: the interim baseline on sqlvm01, which this run started, wasn''t set within \d+ seconds\. This run''s own Run Commands there went on'
        $late.remediation | Should -Be './scripts/validate.ps1 -Area Workload -Target T1 says whether T1''s runner answers now. If this run''s switch to business-day (START.INCIDENTS_T1) didn''t pass, set it once it does: ./scripts/demo-control.ps1 -Target T1 -Scenario business-day -Duration 240.'
        Get-DemoExitCode -Result $results | Should -Be 0 -Because 'a start goes on, with the Warning'

        $script:order.Clear()
        $script:interimOutcome = 'Set'
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        @($results | Where-Object { $_.checkId -like 'START.INTERIM_*' } | ForEach-Object { '{0}={1}' -f $_.checkId, $_.status }) | Should -Be @('START.INTERIM_T1=Pass', 'START.INTERIM_T3=Pass', 'START.INTERIM_T2=Pass')
        ($results | Where-Object { $_.checkId -eq 'START.INTERIM_T1' }).message | Should -Be 'T1: the interim baseline is set on sqlvm01, which this run started, in 41 seconds and 3 attempt(s), before this run''s own Run Commands there; business-day comes back at the end.'
    }

    It 'sets the interim baseline once a VM that was still stopping runs, and none on a VM that didn''t start (review of PR 16)' {
        # archost01 was still deallocating: this start didn't request its start, and the first interim request found it
        # not running; the power check started it once it had settled.
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $VmName -eq 'sqlvm01' }
        $script:refuse = @('T2')
        Mock -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -MockWith {
            $script:order.Add(('Switch:{0}={1}' -f (@($Target) -join ','), $ProfileName))
            foreach ($item in $Target) {
                $outcome = if ([int]$PesterBoundParameters['WaitSeconds'] -ne 0) { 'Set' } elseif ($item -in $script:refuse) { 'NotSent' } else { 'Sent' }
                [pscustomobject]@{ Target = $item; VmName = $(if ($item -eq 'T2') { 'archost01' } else { 'sqlvm01' }); Outcome = $outcome; Detail = 'archost01 isn''t running'; Data = $null; Seconds = 1 }
            }
            $script:refuse = @()
        }
        Start-DemoEnvironment -Config $config -SkipT3 -Confirm:$false | Out-Null
        @($script:order[0..9]) | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'Switch:T2=baseline', 'Start:sqlvm01', 'Switch:T1=baseline', 'Start:archost01', 'SourceRelease', 'Switch:T2=baseline', 'Interim:T1,T2')
        $script:order[-1] | Should -Be 'Switch:T1,T2=business-day'

        # A VM that doesn't run gets nothing: a Run Command can't reach it.
        $script:order.Clear()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Start:' + $VmName); New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) $(if ($VmName -eq 'archost01') { 'Fail' } else { 'Pass' }) 'infra' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:order.Add('Request:' + $VmName); $true }
        Start-DemoEnvironment -Config $config -SkipT3 -Confirm:$false | Out-Null
        $script:order[$script:order.IndexOf('Start:archost01') + 1] | Should -Not -Be 'Switch:T2=baseline'
        @($script:order | Where-Object { $_ -eq 'Switch:T2=baseline' }) | Should -BeNullOrEmpty
    }

    It 'reports a switch that doesn''t finish in time as a Warning with the command, never a Fail' {
        $script:switchOutcome = 'TimedOut'
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        $late = $results | Where-Object { $_.checkId -eq 'START.INCIDENTS_T1' }
        $late.status | Should -Be 'Warning'
        $late.message | Should -Match 'didn''t finish within 180 seconds'
        $late.remediation | Should -Match ([regex]::Escape('./scripts/demo-control.ps1 -Target T1 -Scenario business-day -Duration 240'))
        Get-DemoExitCode -Result $results | Should -Be 0
    }

    It 'deletes the on-demand control''s finished Run Commands on the VMs that run, after the profiles, and carries on with its Warning (Phase 28 follow-up)' {
        $script:cleanup = New-TestResult 'START.CONTROL.RUNCOMMANDS' 'Warning' 'workload'
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoControlRunCommand -Times 1 -Exactly -ParameterFilter { (@($VmName) -join ',') -eq 'sqlvm01,archost01' }
        $script:cleanupAt | Should -Be $script:order.IndexOf('Switch:T1,T3,T2=business-day') -Because 'it runs once this start''s own Run Commands, the profiles, are done, and the switch to business-day comes after it'
        ($results | Where-Object { $_.checkId -eq 'START.CONTROL.RUNCOMMANDS' }).status | Should -Be 'Warning'
        Get-DemoExitCode -Result $results | Should -Be 0

        # A VM that didn't start isn't cleaned (a deallocated VM can't remove one); with none running, nothing is called.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Start:' + $VmName); New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) $(if ($VmName -eq 'archost01') { 'Fail' } else { 'Pass' }) 'infra' 'T1' }
        $null = Start-DemoEnvironment -Config $config -Confirm:$false
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoControlRunCommand -Times 1 -Exactly -ParameterFilter { (@($VmName) -join ',') -eq 'sqlvm01' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Start:' + $VmName); New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) 'Fail' 'infra' 'T1' }
        $null = Start-DemoEnvironment -Config $config -Confirm:$false
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoControlRunCommand -Times 2 -Exactly
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

    It 'releases a golden source as soon as archost01 runs, before its interim baseline, and sends none to a guest the release left off (review of PR 17)' {
        # Reviewer: the first start after a capture sent T2's interim, and waited for it, before the release: the guest was
        # off and air-gapped, so it was tried for 10 minutes, held sqlvm01's steps, and ended in a misleading Warning.
        $script:sourceRelease = New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'archost01 is the source of snap-1, and its guest stays air-gapped: a golden capture is in progress on this host.' -Evidence ([ordered]@{ snapshots = @('snap-1'); captureInProgress = $true })
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        $script:order.IndexOf('SourceRelease') | Should -Be ($script:order.IndexOf('Start:archost01') + 1)
        $script:order | Should -Not -Contain 'Switch:T2=baseline'
        $script:order | Should -Contain 'Interim:T1,T3' -Because 'only sqlvm01''s interim is waited for'
        $skipped = $results | Where-Object { $_.checkId -eq 'START.INTERIM_T2' }
        $skipped.status | Should -Be 'Not selected'
        $skipped.message | Should -Match '^T2: no interim baseline to set on archost01, and none to wait for: a golden capture is in progress on archost01'
        Get-DemoExitCode -Result $results | Should -Be 0

        # A release that failed leaves the guest off as well.
        $script:order.Clear()
        $script:sourceRelease = New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status 'Fail' -Message 'archost01 is a golden snapshot''s source, and its guest couldn''t be reconnected: the Run Command failed.'
        $results = @(Start-DemoEnvironment -Config $config -Confirm:$false)
        $script:order | Should -Not -Contain 'Switch:T2=baseline'
        ($results | Where-Object { $_.checkId -eq 'START.INTERIM_T2' }).message | Should -Match 'the golden source''s release failed'

        # A released guest gets its interim right after the release.
        $script:order.Clear()
        $script:sourceRelease = New-TestResult 'T2.GOLDEN.SOURCE' 'Pass' 't2' 'T2'
        $null = Start-DemoEnvironment -Config $config -Confirm:$false
        $script:order.IndexOf('Switch:T2=baseline') | Should -Be ($script:order.IndexOf('SourceRelease') + 1)
    }

    It 'tries T1 and T2 once more, without another wait, when they stayed down through their interim''s wait (review of PR 17)' {
        # Each had its VM's 10-minute bound already; a second budget of 4 minutes each would only add to it.
        $script:interimOutcome = 'TimedOut'
        $script:t1Failures = 1
        $script:t2Failures = 1
        $results = @(Start-DemoEnvironment -Config $config -T2ProfileRetrySeconds 1 -Confirm:$false)
        @($script:order | Where-Object { $_ -eq 'Profile:T1=baseline' }).Count | Should -Be 1
        @($script:order | Where-Object { $_ -eq 'Profile:T2=baseline' }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 2 -Exactly -ParameterFilter { $Target -in 'T1', 'T2' -and $ReadySeconds -eq 0 }
        ($results | Where-Object { $_.checkId -eq 'START.PROFILE_T1' }).status | Should -Be 'Warning'

        # The same after the VM's own retries failed until the bound (the line's attempts).
        $script:order.Clear()
        $script:interimOutcome = 'Failed'
        $script:t1Failures = 1
        $null = Start-DemoEnvironment -Config $config -T2ProfileRetrySeconds 1 -Confirm:$false
        @($script:order | Where-Object { $_ -eq 'Profile:T1=baseline' }).Count | Should -Be 1
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
        # A plugin the redeployment leaves NotRunning gets the agent's restart at once, as after a start (the owner's
        # decision, 2026-10-30), never the whole wait.
        Should -Invoke -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['NotRunningGraceMinutes'] -eq 0 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('NotRunningGraceMinutes') } -Because 'the check after the start restarts at once, its default'
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
        $script:order | Should -Be @('Cost', 'Request:sqlvm01', 'Request:archost01', 'T4:Start:0', 'Start:sqlvm01', 'Switch:T1,T3,T4=baseline', 'Start:archost01', 'SourceRelease', 'Switch:T2=baseline', 'Interim:T1,T3,T4,T2', 'T1Monitoring', 'WarmT3', 'T4:Start:15', 'Profile:T1=baseline', 'Profile:T3=baseline', 'Profile:T4=baseline', 'Profile:T2=baseline', 'Switch:T1,T3,T4,T2=business-day')
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
        # No unit test reaches the Retail Prices API (ADR 0016): the size change's notice (STATUS.T4.SIZE, 2026-11-09) gets
        # obviously fake estimates.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SizeChangeCost -MockWith {
            [pscustomobject]@{
                Asked    = [pscustomobject]@{ SkuName = $Asked; HourlyUsd = 1.0; T4LightUseMonthlyUsd = 60.0; T4MonthlyWorstCaseUsd = 700.0; LightUseMonthlyUsd = 100.0; MonthlyWorstCaseUsd = 800.0; Location = 'westus3' }
                Deployed = [pscustomobject]@{ SkuName = $Deployed; HourlyUsd = 0.5; T4LightUseMonthlyUsd = 30.0; T4MonthlyWorstCaseUsd = 380.0; LightUseMonthlyUsd = 70.0; MonthlyWorstCaseUsd = 450.0; Location = 'westus3' }
            }
        }
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
        # STATUS.RUNCOMMANDS (Phase 28 follow-up) has its own tests below; here it records what it was asked.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunCommandStatus -MockWith { New-TestResult 'STATUS.RUNCOMMANDS' 'Pass' 'infra' }
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
        foreach ($id in 'STATUS.DEPLOYMENT', 'STATUS.VM_SQLVM01', 'STATUS.VM_ARCHOST01', 'STATUS.T3', 'T1.SQLVM.ASSOCIATEDSERVICES', 'T2.ARC.CONNECTED', 'STATUS.BASTION', 'STATUS.COST', 'STATUS.SHUTDOWN', 'STATUS.RUNCOMMANDS') {
            @($results | Where-Object { $_.checkId -eq $id }).Count | Should -Be 1 -Because $id
        }
        ($results | Where-Object { $_.checkId -eq 'STATUS.VM_SQLVM01' }).area | Should -Be 't1'
        ($results | Where-Object { $_.checkId -eq 'STATUS.T3' }).message | Should -Match 'Paused'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -Times 0 -Exactly -Because 'T1 is deallocated'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -Times 0 -Exactly
        # The leftover Run Commands of both VMs it found, each with its power state (Phase 28 follow-up).
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRunCommandStatus -Times 1 -Exactly -ParameterFilter { (@($VmName) -join ',') -eq 'sqlvm01,archost01' -and $Running['sqlvm01'] -eq $false -and $Running['archost01'] -eq $false }
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

    It 'flags T2''s guest that a golden capture left air-gapped while archost01 runs, from the same health read (live, 2026-11-03)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { if ($VmName -eq 'archost01') { 'PowerState/running' } else { 'PowerState/deallocated' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith {
            [pscustomobject]@{ status = 'Pass'; state = 'Ready'; message = 'ok'; t2Guest = [pscustomobject]@{ present = $true; state = 'Off'; heartbeat = ''; startAction = 'Nothing'; adapters = 1; connected = 0; golden = [pscustomobject]@{ released = $false; reset = $false; role = 'Source' } } }
        }
        $results = Get-DemoEnvironmentStatus -Config $config
        $guest = $results | Where-Object { $_.checkId -eq 'T2.GUEST.STATE' }
        $guest.status | Should -Be 'Fail'
        $guest.message | Should -Match 'still air-gapped by a golden capture \(Off, automatic start Nothing, 0 of 1 adapter\(s\) connected\)'
        $guest.remediation | Should -Match 'start-demo\.ps1'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 1 -Exactly -ParameterFilter { $VmName -eq 'archost01' }
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

    It 'says what the active profile does and how to choose the other: business-day''s incidents, a baseline a run hasn''t switched yet, or a configured baseline (2026-11-03)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ status = 'Pass'; state = 'Ready'; message = 'ok' } }
        $script:active = 'business-day'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $record = [pscustomobject]@{ target = $Target; name = $script:active; description = ('{0} (active until 2026-11-03T23:58:00Z; set by start-demo at 2026-11-03T15:00:00Z)' -f $script:active); expiresAt = '2026-11-03T23:58:00Z'; setBy = 'start-demo'; setAt = '2026-11-03T15:00:00Z' }
            [pscustomobject]@{ Status = 'Pass'; ExitCode = 0; Records = @($record); Result = (New-TestResult ('WORKLOAD.{0}.COMMAND' -f $Target) 'Pass' 'workload' $Target) }
        }
        $results = Get-DemoEnvironmentStatus -Config $config
        $t1 = $results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T1' }
        $t1.status | Should -Be 'Pass'
        $t1.message | Should -Match ([regex]::Escape('Bounded incidents run at :10 (locking-blocking, 8 minutes) and :40 (locking-blocking, 6 minutes) past each UTC hour; Database Hub''s Performance page shows each a few minutes after it starts. For a quiet demo, set activityProfile to baseline.'))
        ($results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T3' }).message | Should -Match ([regex]::Escape(':15 (resource-governance, 5 minutes) and :45 (log-rate-pressure, 5 minutes)'))

        # The interim baseline of a configuration that asks for business-day: a run switches it, and how to now.
        $script:active = 'baseline'
        $t1 = Get-DemoEnvironmentStatus -Config $config | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T1' }
        $t1.message | Should -Match ([regex]::Escape('The configuration asks for business-day: deploy.ps1 and start-demo.ps1 switch to it once their own Run Commands are done; to switch now: ./scripts/demo-control.ps1 -Target T1 -Scenario business-day -Duration 240.'))

        # A configured baseline: the problem panels stay empty, and how to choose business-day.
        $quiet = New-TestConfig
        $quiet['activityProfile'] = 'baseline'
        $t1 = Get-DemoEnvironmentStatus -Config $quiet | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T1' }
        $t1.message | Should -Match ([regex]::Escape('No incidents run, so the Performance page''s problem panels stay empty; business-day, the default, adds bounded incidents every hour (set activityProfile to business-day).'))
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

    It 'says when a stopped T4 starts on its own, what it then bills, and warns within a day of it (Phase 24; Phase 28 follow-up)' {
        $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $true; State = 'Stopped'; Server = $null; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4StoppedUtc -MockWith { [datetime]::new(2026, 10, 20, 23, 0, 0, [System.DateTimeKind]::Utc) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -MockWith { throw 'a stopped server sends no fresh metrics' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { 0.178 }
        # Neither safety stop is in place (ADR 0024, ADR 0020): nothing here stops a restarted T4.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4RestartStopState -MockWith { [pscustomobject]@{ State = 'NotScheduled'; NextRunUtc = $null } }
        $results = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) -NowUtc ([datetime]::new(2026, 10, 21, 2, 0, 0, [System.DateTimeKind]::Utc))
        $t4 = $results | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Pass'
        $t4.message | Should -BeLike 'pgflex01-abc123 is stopped since 2026-10-20 23:00 UTC. Azure starts it again on its own at 2026-10-27 23:00 UTC, 7 days after the stop, *'
        $t4.message | Should -Match 'it then bills compute at about 0\.178 USD an hour \(Standard_D4ds_v5, list price\) until it''s stopped again: the nightly safety stop isn''t in place \(\./scripts/deploy\.ps1 sets it up\), so nothing here stops it on its own'
        ([datetime]$t4.evidence.autoStartUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be '2026-10-27T23:00'
        $t4.evidence.hourlyUsd | Should -Be 0.178
        $t4.evidence.dailySafetyStop | Should -BeFalse

        $results = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) -NowUtc ([datetime]::new(2026, 10, 27, 5, 0, 0, [System.DateTimeKind]::Utc))
        $t4 = $results | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Warning'
        $t4.remediation | Should -Match 'stop-demo\.ps1'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -Times 0 -Exactly
    }

    It 'says a General Purpose T4 that the fallback chose, with its price, and when the daily safety stop stops a restarted one (Phase 28 follow-up)' {
        $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
        $script:t4State = 'Stopped'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); T4Sku = 'Standard_D2ds_v5'; Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $true; State = $script:t4State; Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4StoppedUtc -MockWith { [datetime]::new(2026, 10, 20, 23, 0, 0, [System.DateTimeKind]::Utc) }
        # An obviously fake price, as the Retail Prices API would give it at run time.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { 0.5 }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlStatus -MockWith { New-TestResult 'STATUS.CONTROL' 'Pass' 'infra' 'subscription' }
        $config = New-TestConfig -WithT4
        $config['control']['enabled'] = $true

        # The nightly safety stop in place (ADR 0024): it stops a restarted T4 at its first run after the restart, here that
        # evening's stop (2026-10-27 23:00 UTC is 16:00 Pacific daylight time).
        $script:nightlyState = 'InPlace'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopState -MockWith { [pscustomobject]@{ State = $script:nightlyState; NextRunUtc = $null; CheckNextRunUtc = $null; CheckScheduled = ($script:nightlyState -eq 'InPlace'); RoleAssigned = ($script:nightlyState -eq 'InPlace'); Missing = ''; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopLastRun -MockWith { [pscustomobject]@{ Ok = $true; Error = ''; Stop = $null; Check = $null } }
        $t4 = Get-DemoEnvironmentStatus -Config $config -NowUtc ([datetime]::new(2026, 10, 21, 2, 0, 0, [System.DateTimeKind]::Utc)) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.message | Should -Match 'and it then bills compute at about 0\.500 USD an hour \(Standard_D2ds_v5, list price\) until the nightly safety stop stops it again at 2026-10-28 02:00 UTC \(19:00 Pacific Standard Time\), about 3 hours after it starts\.'
        $t4.evidence.dailySafetyStop | Should -BeTrue
        $t4.evidence.safetyStop | Should -Be 'Nightly'

        # Without it, the daily safety stop's schedule, read as CONTROL.SAFETYSTOP reads it (review of 20e855c).
        $script:nightlyState = 'NotScheduled'
        $script:safetyState = 'Scheduled'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SafetyStopState -MockWith { [pscustomobject]@{ State = $script:safetyState; NextRunUtc = $null } }
        $t4 = Get-DemoEnvironmentStatus -Config $config -NowUtc ([datetime]::new(2026, 10, 21, 2, 0, 0, [System.DateTimeKind]::Utc)) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.message | Should -Match 'Azure starts it again on its own at 2026-10-27 23:00 UTC, 7 days after the stop, and it then bills compute at about 0\.500 USD an hour \(Standard_D2ds_v5, list price\) until the on-demand control''s daily safety stop stops it again, within a day\.'
        $t4.message | Should -Match 'It''s General Purpose Standard_D2ds_v5, which the fallback chose because Azure refused the 4-vCore sizes here, so autonomous tuning is off\.$'
        $t4.evidence.dailySafetyStop | Should -BeTrue
        $t4.evidence.safetyStop | Should -Be 'Scheduled'
        $t4.evidence.skuName | Should -Be 'Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -ParameterFilter { $SkuName -eq 'Standard_D2ds_v5' }

        # The control is on, but its daily safety stop couldn't be scheduled, and the nightly one isn't in place: nothing
        # here stops a restarted T4.
        $script:safetyState = 'NotScheduled'
        $t4 = Get-DemoEnvironmentStatus -Config $config -NowUtc ([datetime]::new(2026, 10, 21, 2, 0, 0, [System.DateTimeKind]::Utc)) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.message | Should -Match 'Azure starts it again on its own at 2026-10-27 23:00 UTC, 7 days after the stop, and it then bills compute at about 0\.500 USD an hour \(Standard_D2ds_v5, list price\) until it''s stopped again: the nightly safety stop isn''t in place'
        $t4.message | Should -Not -Match 'stops it again, within a day'
        $t4.evidence.dailySafetyStop | Should -BeFalse
        $t4.evidence.safetyStop | Should -Be 'NotScheduled'

        # Running: its size, and what it bills while it runs.
        $script:t4State = 'Ready'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -MockWith { [pscustomobject]@{ Succeeded = $true; Error = ''; Minutes = 15; LatestUtc = '2026-10-23T20:00:00.0000000Z'; Latest = [ordered]@{ cpu_percent = 12 }; ByState = [ordered]@{}; ByWaitEventType = [ordered]@{} } }
        $t4 = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Pass'
        $t4.message | Should -Match 'It''s General Purpose Standard_D2ds_v5, which the fallback chose because Azure refused the 4-vCore sizes here, so autonomous tuning is off: about 0\.500 USD an hour \(list price\) while it runs\.'
        # 2026-11-09 (user-directed): status.ps1 gives the size change's notice too, with both monthly estimates.
        $all = @(Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4))
        $size = @($all | Where-Object { $_.checkId -eq 'STATUS.T4.SIZE' })
        $size.Count | Should -Be 1
        $size[0].status | Should -Be 'Warning'
        $size[0].message | Should -Match '^T4 runs as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, T4''s default size: deploy\.ps1''s fallback created it at that size because Standard_D4ds_v5 was unavailable here \(found by preflight or an earlier run\)\.'
        $size[0].message | Should -Match 'Standard_D4ds_v5 60\.00 USD at light use and 700\.00 USD in the worst case; Standard_D2ds_v5 30\.00 USD and 380\.00 USD, so 30\.00 USD less a month at light use and 320\.00 USD less in the worst case'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4SizeChangeCost -ParameterFilter { $Asked -eq 'Standard_D4ds_v5' -and $Deployed -eq 'Standard_D2ds_v5' }
        $t4.evidence.hourlyUsd | Should -Be 0.5

        # A Standard_D2ds_v5 server that a configuration set, after t4SkuName is removed: no record (only the fallback writes
        # one), so no refusal is claimed (review of 20e855c).
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); T4Sku = ''; Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        $t4 = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.message | Should -Match 'It''s General Purpose Standard_D2ds_v5: about 0\.500 USD an hour \(list price\) while it runs\.'
        $t4.message | Should -Not -Match 'fallback|refused'

        # The fallback chose Standard_D2ds_v5, but the server doesn't exist (its creation failed for another reason): never
        # "created" (review of 20e855c).
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); T4Sku = 'Standard_D2ds_v5'; Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $false; State = 'NotFound'; Server = $null; Error = '' } }
        $t4 = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Not selected'
        $t4.message | Should -Be 'T4 (pgflex01-abc123) doesn''t exist; deploy.ps1 creates it as General Purpose Standard_D2ds_v5, which the fallback chose because Azure refused the 4-vCore sizes here, so autonomous tuning is off, after checking its price against the ceilings again.'

        # A server Azure is deleting (Dropping: the shell of a size it refused, live 2026-11-09) isn't T4, so its size isn't
        # read as T4's: here the refused Standard_D4ds_v5's shell, while the record holds the next size, Standard_D4ads_v5.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); T4Sku = 'Standard_D4ads_v5'; Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $false; Present = $true; Removing = $true; State = 'Dropping'; Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D4ds_v5'; tier = 'GeneralPurpose' } }; Error = '' } }
        $t4 = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Not selected'
        $t4.message | Should -Be 'T4 (pgflex01-abc123) is being deleted (Dropping: Azure removes a server it refused within minutes, and one deleted by hand too); once it''s gone, deploy.ps1 creates T4 as General Purpose Standard_D4ads_v5, which the fallback chose because Azure refused Standard_D4ds_v5 here, after checking its price against the ceilings again.'
    }

    It 'reads T4 in STATUS.T4 as usual, metrics included, whatever the record says: <Record> (2026-11-09; review of 64c28b2)' -ForEach @(
        @{ Record = 'None' }
        @{ Record = 'Refused' }
    ) {
        # Earlier runs wrote None or Refused when the fallback left T4 out, and 64c28b2 could record None for a server that a
        # template attempt which failed for another resource had created. Since 2026-11-09 T4 is part of every deployment,
        # and no record turns it off, so status.ps1 reads it as it does without a record.
        $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
        $script:t4Record = $Record
        $script:t4Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { New-TestState @{ Stage = 'Validation'; RunnerSha256 = $script:runnerSha; RunnerSentTo = @('sqlvm01', 'archost01'); T4Sku = $script:t4Record; Tags = @{ deploymentId = 'abc123'; expiresOn = '2026-12-31' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = ($null -ne $script:t4Server); State = $(if ($null -ne $script:t4Server) { 'Ready' } else { 'NotFound' }); Server = $script:t4Server; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -MockWith { [pscustomobject]@{ Succeeded = $true; Error = ''; Minutes = 15; LatestUtc = '2026-10-23T20:00:00.0000000Z'; Latest = [ordered]@{ cpu_percent = 12 }; ByState = [ordered]@{}; ByWaitEventType = [ordered]@{} } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { 0.5 }
        $t4 = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Pass'
        $t4.message | Should -Match '^pgflex01-abc123 is running: CPU 12%'
        $t4.message | Should -Match 'It''s General Purpose Standard_D2ds_v5: about 0\.500 USD an hour \(list price\) while it runs\.'
        $t4.message | Should -Not -Match 'record says T4 is off|fallback|refused'
        $t4.evidence.skuName | Should -Be 'Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4MetricSnapshot -Times 1 -Exactly -ParameterFilter { $Minutes -eq 15 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4State -Times 1 -Exactly -ParameterFilter { $DeploymentId -eq 'abc123' -and -not $Config.Contains('t4SkuSource') }

        # Without a server, STATUS.T4 says deploy.ps1 creates it, as for any T4 that doesn't exist.
        $script:t4Server = $null
        $t4 = Get-DemoEnvironmentStatus -Config (New-TestConfig -WithT4) | Where-Object { $_.checkId -eq 'STATUS.T4' }
        $t4.status | Should -Be 'Not selected'
        $t4.message | Should -Be 'T4 (pgflex01-abc123) doesn''t exist; deploy.ps1 creates it.'
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
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunCommandStatus -MockWith { New-TestResult 'STATUS.RUNCOMMANDS' 'Pass' 'infra' }
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

    It 'reports T2''s profile as Not selected, not a Warning, before T2 is set up (Phase 28 live finding)' {
        # Before SQL Server setup, the guest has no demo module, so its Import-Module fails.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadAction -ParameterFilter { $Request['target'] -eq 'T2' } -MockWith {
            @{ marker = 'DBHUBDEMO-WORKLOAD'; action = 'Runner'; status = 'Fail'; message = 'The control action failed: The specified module ''C:\ProgramData\DbHubDemo\module\DbHubDemo.Vm.psd1'' was not loaded because no valid module file was found in any module directory.'; evidence = @{} }
        }
        $results = Get-DemoEnvironmentStatus -Config $config -Detail
        $t2 = $results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T2' }
        $t2.status | Should -Be 'Not selected'
        $t2.message | Should -Match 'T2 isn''t set up yet'
        ($results | Where-Object { $_.checkId -eq 'STATUS.PROFILE_T1' }).status | Should -Be 'Pass'
    }
}

Describe 'Leftover managed Run Commands: start-demo.ps1''s cleanup and status.ps1''s report (Phase 28 follow-up)' {
    BeforeAll {
        $config = New-TestConfig
        function New-RunCommand([string] $Name, [string] $Execution = 'Succeeded', [string] $Provisioning = 'Succeeded') {
            @{ name = $Name; properties = @{ provisioningState = $Provisioning; instanceView = @{ executionState = $Execution } } }
        }
    }

    BeforeEach {
        $script:azLog = [System.Collections.Generic.List[string]]::new()
        $script:listed = @{ sqlvm01 = @(); archost01 = @() }
        $script:listFails = @{}
        $script:deleteAnswers = @{}
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:azLog.Add($joined)
            if ($joined -match '^rest --method get --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Compute/virtualMachines/(\w+)/runCommands\?api-version=[\d-]+&\$expand=instanceView ') {
                if ($script:listFails[$Matches[1]]) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access to read the Run Commands.')
                }
                return (New-AzResult -StdOut (@{ value = @($script:listed[$Matches[1]]) } | ConvertTo-Json -Depth 8))
            }
            if ($joined -match '^rest --method delete --url https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Compute/virtualMachines/\w+/runCommands/([A-Za-z0-9-]+)\?api-version=[\d-]+ ') {
                if ($script:deleteAnswers.ContainsKey($Matches[1])) {
                    return $script:deleteAnswers[$Matches[1]]
                }
                return (New-AzResult)
            }
            return (New-AzResult -ExitCode 3 -StdErr ('ERROR: not faked in this test: {0}' -f $joined))
        }
    }

    It 'start-demo.ps1 deletes the control''s finished Run Commands on the VMs that run, without waiting, and nothing else' {
        # Live, 2026-11-02: the 2026-10-27 run's DbHubControl-sqlvm01-<timestamp> was still on sqlvm01; a VM takes 25.
        $script:listed['sqlvm01'] = @(
            New-RunCommand 'DbHubControl-sqlvm01-20261027153000'
            New-RunCommand 'DbHubControl-monitoring-20261027153000' 'Failed'
            New-RunCommand 'DbHubControl-sqlvm01-20261102120000' 'Running'
            New-RunCommand 'DbHubDemo-Bootstrap'
            New-RunCommand 'DbHubDemo-HealthRead' 'Running'
            New-RunCommand 'DbHubDemo-Workload'
            New-RunCommand 'OtherTeam-Patch'
        )
        $script:listed['archost01'] = @(New-RunCommand 'DbHubControl-archost01-20261027153000' 'TimedOut')
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoControlRunCommand -Config $Config -VmName @('sqlvm01', 'archost01') -Confirm:$false }
        $result.checkId | Should -Be 'START.CONTROL.RUNCOMMANDS'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match '^Deleted 3 finished Run Command\(s\) the on-demand control left on the VMs: sqlvm01/DbHubControl-sqlvm01-20261027153000, sqlvm01/DbHubControl-monitoring-20261027153000, archost01/DbHubControl-archost01-20261027153000\.'
        $deletes = @($script:azLog | Where-Object { $_ -match '^rest --method delete' })
        $deletes.Count | Should -Be 3
        $deletes | ForEach-Object { $_ | Should -Match '/runCommands/DbHubControl-(sqlvm01|monitoring|archost01)-20261027153000\?api-version=2025-11-01 --subscription 11111111-2222-3333-4444-555555555555$' }
        # It never waits for a delete: no read of a single Run Command after it.
        @($script:azLog | Where-Object { $_ -match '/runCommands/[A-Za-z0-9-]+\?' -and $_ -match '^rest --method get' }) | Should -BeNullOrEmpty
    }

    It 'start-demo.ps1''s cleanup is a Warning the next start retries, never a Fail, when a VM can''t remove one or can''t be listed' {
        $script:listed['sqlvm01'] = @(New-RunCommand 'DbHubControl-sqlvm01-20261027153000')
        $script:listed['archost01'] = @(New-RunCommand 'DbHubControl-archost01-20261027153000')
        $script:deleteAnswers['DbHubControl-archost01-20261027153000'] = New-AzResult -ExitCode 1 -StdErr 'ERROR: (OperationNotAllowed) Cannot modify extensions in the VM when the VM is not running.'
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoControlRunCommand -Config $Config -VmName @('sqlvm01', 'archost01') -Confirm:$false }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'archost01/DbHubControl-archost01-20261027153000: the VM isn''t running'
        $result.message | Should -Match 'Deleted: sqlvm01/DbHubControl-sqlvm01-20261027153000\.'
        $result.remediation | Should -Match 'The next start-demo\.ps1 tries again'
        $result.remediation | Should -Match ([regex]::Escape('az vm run-command delete --resource-group rg-dbhub-demo --vm-name archost01 --name DbHubControl-archost01-20261027153000 --subscription 11111111-2222-3333-4444-555555555555 --yes'))
        Get-DemoExitCode -Result @($result) | Should -Be 0

        $script:listFails['sqlvm01'] = $true
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoControlRunCommand -Config $Config -VmName @('sqlvm01') -Confirm:$false }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'sqlvm01: the Run Commands couldn''t be listed \(ERROR: \(AuthorizationFailed\)'
    }

    It 'start-demo.ps1''s cleanup says nothing with the control off and nothing to delete, and a Pass with it on' {
        $script:listed['sqlvm01'] = @(New-RunCommand 'DbHubDemo-Bootstrap')
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoControlRunCommand -Config $Config -VmName @('sqlvm01') -Confirm:$false } | Should -BeNullOrEmpty
        $controlConfig = New-TestConfig
        $controlConfig['control']['enabled'] = $true
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $controlConfig } { Remove-DemoControlRunCommand -Config $Config -VmName @('sqlvm01') -Confirm:$false }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'No finished Run Command of the on-demand control is left on sqlvm01'
        @($script:azLog | Where-Object { $_ -match '^rest --method delete' }) | Should -BeNullOrEmpty
    }

    It 'status.ps1 reports what''s left on the VMs as a Warning with the commands that delete them, and deletes nothing' {
        $script:listed['sqlvm01'] = @(
            New-RunCommand 'DbHubControl-sqlvm01-20261027153000'
            New-RunCommand 'DbHubControl-sqlvm01-20261102120000' 'Running'
            New-RunCommand 'DbHubDemo-Bootstrap'
            New-RunCommand 'DbHubDemo-HealthRead' 'Running'
            New-RunCommand 'DbHubDemo-Workload' 'Failed'
            New-RunCommand 'DbHubDemo-Chunk-0123456789ab-001' 'Succeeded' 'Deleting'
            New-RunCommand 'OtherTeam-Patch'
        )
        # A deallocated VM runs nothing, so a "Running" there is a stale instance view, and it counts.
        $script:listed['archost01'] = @(New-RunCommand 'DbHubControl-archost01-20261027153000' 'Running')
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoRunCommandStatus -Config $Config -VmName @('sqlvm01', 'archost01') -Running @{ sqlvm01 = $true; archost01 = $false } }
        $result.checkId | Should -Be 'STATUS.RUNCOMMANDS'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Be '3 managed Run Command(s) are left on the demo VMs: sqlvm01/DbHubControl-sqlvm01-20261027153000, sqlvm01/DbHubDemo-Workload, archost01/DbHubControl-archost01-20261027153000.'
        $result.remediation | Should -Match 'start-demo\.ps1 deletes the on-demand control''s finished ones \(DbHubControl-\*\) once the VMs run'
        $result.remediation | Should -Match 'the next run of the step that made a DbHubDemo-\* one deletes it first'
        $result.remediation | Should -Match ([regex]::Escape('az vm run-command delete --resource-group rg-dbhub-demo --vm-name sqlvm01 --name DbHubControl-sqlvm01-20261027153000 --subscription 11111111-2222-3333-4444-555555555555 --yes'))
        $result.remediation | Should -Match 'Azure allows 25 managed Run Commands per VM'
        @($result.evidence.deleteCommands).Count | Should -Be 3
        @($script:azLog | Where-Object { $_ -notmatch '^rest --method get ' }) | Should -BeNullOrEmpty -Because 'status.ps1 only reads'
    }

    It 'status.ps1 passes with only the bootstrap loader and the activity profiles'' Run Command left, and warns when it can''t list a VM''s Run Commands' {
        $script:listed['sqlvm01'] = @((New-RunCommand 'DbHubDemo-Bootstrap'), (New-RunCommand 'DbHubDemo-Profile' 'Running'))
        $script:listed['archost01'] = @((New-RunCommand 'DbHubDemo-Bootstrap'), (New-RunCommand 'DbHubDemo-Profile' 'TimedOut'))
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoRunCommandStatus -Config $Config -VmName @('sqlvm01', 'archost01') -Running @{ sqlvm01 = $false; archost01 = $false } }
        $result.status | Should -Be 'Pass' -Because 'each profile change replaces DbHubDemo-Profile, and its script does nothing once it has expired (2026-11-03)'
        $result.message | Should -Match 'No leftover Run Command on sqlvm01 and archost01; the bootstrap loader DbHubDemo-Bootstrap and the activity profiles'' DbHubDemo-Profile stay by design\.'
        $script:listFails['archost01'] = $true
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoRunCommandStatus -Config $Config -VmName @('sqlvm01', 'archost01') -Running @{} }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'couldn''t all be listed: archost01: ERROR: \(AuthorizationFailed\)'
    }

    It 'a control Run Command is finished when its state is terminal, or empty or Unknown an hour after the time in its name: <Name> <State>' -ForEach @(
        @{ Name = 'DbHubControl-sqlvm01-20261102120000'; State = 'Succeeded'; Finished = $true }
        @{ Name = 'DbHubControl-sqlvm01-20261102120000'; State = 'Canceled'; Finished = $true }
        @{ Name = 'DbHubControl-sqlvm01-20261102120000'; State = 'TimedOut'; Finished = $true }
        @{ Name = 'DbHubControl-monitoring-20261102120000'; State = 'Failed'; Finished = $true }
        @{ Name = 'DbHubControl-sqlvm01-20261102105959'; State = ''; Finished = $true }
        @{ Name = 'DbHubControl-sqlvm01-reset-20261102105959'; State = 'Unknown'; Finished = $true }
        @{ Name = 'DbHubControl-sqlvm01-20261102113000'; State = ''; Finished = $false }
        @{ Name = 'DbHubControl-sqlvm01-20261102113000'; State = 'Unknown'; Finished = $false }
        @{ Name = 'DbHubControl-sqlvm01-20261101090000'; State = 'Running'; Finished = $false }
        @{ Name = 'DbHubControl-sqlvm01-20261101090000'; State = 'Pending'; Finished = $false }
        @{ Name = 'DbHubControl-sqlvm01-manual'; State = 'Unknown'; Finished = $false }
        @{ Name = 'DbHubControl-sqlvm01-20261399999999'; State = ''; Finished = $false }
    ) {
        $now = [DateTime]::new(2026, 11, 2, 12, 0, 0, [DateTimeKind]::Utc)
        InModuleScope DbHubDemo -Parameters @{ Name = $Name; State = $State; Now = $now } { Test-DemoRunCommandFinished -Name $Name -ExecutionState $State -NowUtc $Now } | Should -Be $Finished
    }

    It 'start-demo.ps1 never deletes a control Run Command an overlapping run has just created, and status.ps1 doesn''t count it on a running VM (review of 7fb941e)' {
        # Right after it's created, a Run Command's execution state is empty or Unknown until the VM agent picks it up.
        $now = [DateTime]::UtcNow
        $at = { param([double] $MinutesAgo) $now.AddMinutes(-$MinutesAgo).ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture) }
        $new = 'DbHubControl-sqlvm01-{0}' -f (& $at 1)
        $script:listed['sqlvm01'] = @(
            New-RunCommand $new ''
            New-RunCommand ('DbHubControl-monitoring-{0}' -f (& $at 2)) 'Unknown'
            @{ name = ('DbHubControl-sqlvm01-reset-{0}' -f (& $at 3)); properties = @{ provisioningState = 'Succeeded' } }
            New-RunCommand 'DbHubControl-sqlvm01-manual' 'Unknown'
            New-RunCommand ('DbHubControl-sqlvm01-{0}' -f (& $at 90)) 'Unknown'
            New-RunCommand ('DbHubControl-sqlvm01-reset-{0}' -f (& $at 120)) ''
            New-RunCommand ('DbHubControl-monitoring-{0}' -f (& $at 5)) 'Canceled'
        )
        $finished = @(('DbHubControl-sqlvm01-{0}' -f (& $at 90)), ('DbHubControl-sqlvm01-reset-{0}' -f (& $at 120)), ('DbHubControl-monitoring-{0}' -f (& $at 5)))
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoControlRunCommand -Config $Config -VmName @('sqlvm01') -Confirm:$false }
        $result.status | Should -Be 'Pass'
        $deleted = @($script:azLog | Where-Object { $_ -match '^rest --method delete' } | ForEach-Object { [regex]::Match($_, '/runCommands/([A-Za-z0-9-]+)\?').Groups[1].Value })
        $deleted | Should -Be $finished
        @($result.evidence.deleted) | Should -Be @($finished | ForEach-Object { 'sqlvm01/' + $_ })

        $status = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoRunCommandStatus -Config $Config -VmName @('sqlvm01') -Running @{ sqlvm01 = $true } }
        @($status.evidence.leftover) | Should -Be @($finished | ForEach-Object { 'sqlvm01/' + $_ })
        @($status.evidence.deleteCommands) | Should -Not -Match ([regex]::Escape($new))
        # A deallocated VM runs nothing, so there every one counts.
        $status = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoRunCommandStatus -Config $Config -VmName @('sqlvm01') -Running @{ sqlvm01 = $false } }
        @($status.evidence.leftover).Count | Should -Be 7
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
        # The nightly safety stop's role definition (ADR 0024): none in these tests, unless one says so.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSafetyStopRoleState -MockWith { [pscustomobject]@{ Id = ''; Actions = @(); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $script:order.Add('az ' + ($ArgumentList[0..1] -join ' '))
            $script:groupExists = $false
            New-AzResult
        }
    }

    It 'deletes the Arc SQL instances, then the Arc machines, then the resource group, then the deployment record and the budget, and checks for residue' {
        $results = Remove-DemoEnvironment -Config $config -Confirm:$false
        $script:order | Should -Be @('Instance', 'Machine', 'az group delete', 'az deployment sub', 'az deployment sub', 'az rest --method', 'az rest --method', 'Residue') -Because 'JumpstartImage, the default since 2026-11-05, has no golden guard, so destroy reads no host first'
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
        # Before T2's setup, the guest has no demo module yet (Phase 28 live finding): a Warning too, not a Fail.
        $script:t2Message = 'The control action failed: The specified module ''C:\ProgramData\DbHubDemo\module\DbHubDemo.Vm.psd1'' was not loaded because no valid module file was found in any module directory.'
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

    It 'logs Warnings that share a remediation, 3 or more, as one line, keeps each Fail on its own line, and leaves the table and the job summary complete (Phase 28 live run)' {
        # Live, 2026-10-30: about 58 blank-measure Warnings with the same remediation came right before the DONE banner.
        $summary = Join-Path -Path $TestDrive -ChildPath 'grouped.md'
        $previous = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = $summary
        $script:logged = [System.Collections.Generic.List[string]]::new()
        $blank = 'Expected before a scenario runs. Run one, then check the model again.'
        $results = @(
            foreach ($measure in 'TELEMETRY.AVG_CPU', 'TELEMETRY.MAX_WAIT', 'INCIDENT.COUNT') {
                New-DemoResult -CheckId ('FABRIC.SEMANTICMODEL.MEASURE.{0}' -f $measure) -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The measure is blank.' -Remediation $blank
            }
            New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.ROWS' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'No rows.' -Remediation $blank
            New-DemoResult -CheckId 'HUB.ESTATE.T1' -Area 'hub' -Target 'T1' -Status 'Warning' -Message 'Not in Estate yet.' -Remediation 'Wait about 10 minutes.'
            New-DemoResult -CheckId 'HUB.ESTATE.T2' -Area 'hub' -Target 'T2' -Status 'Warning' -Message 'Not in Estate yet.' -Remediation 'Wait about 10 minutes.'
            New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Pass' -Message 'Telemetry arrives.'
        )
        try {
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
            $table = @(Write-DemoResultReport -Result $results -Title 'deploy.ps1' 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        }
        finally {
            $env:GITHUB_STEP_SUMMARY = $previous
        }
        $script:logged | Should -Be @(
            ('3 checks (FABRIC.SEMANTICMODEL.MEASURE.*, e.g. FABRIC.SEMANTICMODEL.MEASURE.TELEMETRY.AVG_CPU, FABRIC.SEMANTICMODEL.MEASURE.TELEMETRY.MAX_WAIT): {0}' -f $blank)
            ('FABRIC.SEMANTICMODEL.ROWS: {0}' -f $blank)
            'HUB.ESTATE.T1: Wait about 10 minutes.'
            'HUB.ESTATE.T2: Wait about 10 minutes.'
        )
        $text = Get-Content -LiteralPath $summary -Raw
        foreach ($item in $results) {
            $table | Should -Match ([regex]::Escape($item.checkId))
            $text | Should -Match ([regex]::Escape(('| {0} | {1} |' -f $item.checkId, $item.status)))
        }
    }

    It 'says, after a run that ended DONE, that none of its Manual action required items keeps it from DONE (Phase 28 live run)' {
        # Live, 2026-10-30: "2 item(s) need you" came right before a DONE banner whose summary said nothing else needed the person.
        $script:logged = [System.Collections.Generic.List[string]]::new()
        $results = @(
            New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The app is deployed.' -Remediation 'Open the app once in the browser.'
            New-DemoResult -CheckId 'DEPLOY.SUMMARY' -Area 'infra' -Target 'subscription' -Status 'Manual action required' -Message 'Nothing else needs you for DONE.'
        )
        $previous = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = ''
        try {
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
            Write-DemoResultReport -Result $results -Title 'deploy.ps1' -OutcomeDone 6>$null
            $script:logged | Should -Be @('2 item(s) are Manual action required; none of them keeps this run from DONE:', '  FABRIC.APP.BROWSER: Open the app once in the browser.', '  DEPLOY.SUMMARY: Nothing else needs you for DONE.')
            $script:logged.Clear()
            Write-DemoResultReport -Result $results -Title 'deploy.ps1' 6>$null
            $script:logged[0] | Should -Be '2 item(s) need you (Manual action required):'
        }
        finally {
            $env:GITHUB_STEP_SUMMARY = $previous
        }
    }

    It 'logs a check''s remediation once when two sources report the same check and remediation, and keeps the table and the job summary complete (Phase 28 live run)' {
        # Live, 2026-10-30: PREFLIGHT.FABRIC.VIEWERLICENSE's remediation came twice, from preflight and from the Fabric track.
        $summary = Join-Path -Path $TestDrive -ChildPath 'deduplicated.md'
        $previous = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = $summary
        $script:logged = [System.Collections.Generic.List[string]]::new()
        $licence = 'For viewers of the report or the app: assign Pro or PPU licenses (P11).'
        $results = @(
            New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status 'Warning' -Message 'The capacity is F2.' -Remediation $licence
            New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status 'Warning' -Message 'The capacity is F2.' -Remediation $licence
            New-DemoResult -CheckId 'HUB.ESTATE.T1' -Area 'hub' -Target 'T1' -Status 'Warning' -Message 'Not in Estate yet.' -Remediation 'Wait about 10 minutes.'
            New-DemoResult -CheckId 'HUB.ESTATE.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'Not in Estate.' -Remediation 'Wait about 10 minutes.'
            New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The app is deployed.' -Remediation 'Open the app once in the browser.'
            New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The app is deployed.' -Remediation 'Open the app once in the browser.'
        )
        try {
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
            $table = @(Write-DemoResultReport -Result $results -Title 'deploy.ps1' 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        }
        finally {
            $env:GITHUB_STEP_SUMMARY = $previous
        }
        $script:logged | Should -Be @(
            ('PREFLIGHT.FABRIC.VIEWERLICENSE: {0}' -f $licence)
            'HUB.ESTATE.T1: Wait about 10 minutes.'
            '1 item(s) need you (Manual action required):'
            '  FABRIC.APP.BROWSER: Open the app once in the browser.'
        )
        ([regex]::Matches($table, 'PREFLIGHT\.FABRIC\.VIEWERLICENSE')).Count | Should -Be 2 -Because 'the table keeps every result'
        $text = Get-Content -LiteralPath $summary -Raw
        ([regex]::Matches($text, '\| PREFLIGHT\.FABRIC\.VIEWERLICENSE \| Warning \|')).Count | Should -Be 2
        ([regex]::Matches($text, '\*\*FABRIC\.APP\.BROWSER:\*\*')).Count | Should -Be 2 -Because 'the job summary is unchanged'
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

Describe 'Request-DemoStoppedStart and Wait-DemoStoppedStart: deploy.ps1 starts what was stopped (Phase 28 live finding)' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        # Live, 2026-10-30: a rerun after the nightly auto-shutdown found the VMs deallocated, and its first Run Command failed.
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/running' }
        $script:page = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power[$VmName] }
        Mock -ModuleName DbHubDemo -CommandName Request-DemoVmStart -MockWith { $script:calls.Add('request ' + $VmName); $true }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith {
            $script:calls.Add(('running {0} requested={1}' -f $VmName, [bool]$PesterBoundParameters['StartRequested']))
            New-TestResult ('START.VM_{0}' -f $VmName.ToUpperInvariant()) $(if ($VmName -eq $script:noStart) { 'Warning' } else { 'Pass' }) 'infra' 'T1'
        }
        $script:noStart = ''
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -MockWith { $script:calls.Add('source release'); New-TestResult 'T2.GOLDEN.SOURCE' 'Pass' 't2' 'T2' }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { $script:calls.Add('t1 monitoring'); New-TestResult 'DEPLOY.T1.MONITORING' 'Pass' 't1' 'T1' }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:page.Add(('{0}|{1}|{2}|{3}' -f (@($PesterBoundParameters['Id']) -join ','), $PesterBoundParameters['State'], $PesterBoundParameters['Status'], $PesterBoundParameters['Message'])) }
    }

    It 'leaves running VMs and a Ready T4 alone, read-only, and says nothing needed starting' {
        $withT4 = New-TestConfig -WithT4
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith { $script:calls.Add('t4 ' + $PesterBoundParameters['WaitMinutes']); New-DemoResult -CheckId 'DEPLOY.T4.START' -Area 'infra' -Target 'T4' -Status 'Pass' -Message 'T4 was already running (Ready).' -Evidence ([ordered]@{ stateBefore = 'Ready'; stateAfter = 'Ready' }) }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $withT4 } { Request-DemoStoppedStart -Config $Config -ProgressPath 'progress.json' -Confirm:$false }
        $request.Needed | Should -BeFalse
        @($request.Running) | Should -Be @('sqlvm01', 'archost01') -Because 'a VM that already runs gets the interim baseline before the run''s Run Commands (2026-11-03)'
        $script:calls | Should -Be @('t4 0') -Because 'Invoke-DemoT4PowerAction only reads a T4 that''s Ready'
        $script:page | Should -Be @('StartVms|Skipped||Not needed: nothing was stopped.')
        @(InModuleScope DbHubDemo -Parameters @{ Config = $withT4; Request = $request } { Wait-DemoStoppedStart -Config $Config -Request $Request }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -Times 0 -Exactly
    }

    It 'asks a deallocated VM to start without waiting, waits for one that''s still stopping, and says so on the status page' {
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocating' }
        $script:billing = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Add-DemoProgressStartedVm -MockWith { $script:billing.Add((@($PesterBoundParameters['Name']) -join ',')) }
        # Invoke-DemoVmPowerAction issues the start for the one that was still stopping once it has settled.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith {
            $script:calls.Add(('running {0} requested={1}' -f $VmName, [bool]$PesterBoundParameters['StartRequested']))
            $issued = if ([bool]$PesterBoundParameters['StartRequested']) { '' } else { 'start' }
            New-DemoResult -CheckId ('START.VM_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target 'T1' -Status 'Pass' -Message ('{0} is running.' -f $VmName) -Evidence ([ordered]@{ issued = $issued })
        }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -ProgressPath 'progress.json' -Confirm:$false }
        $request.Needed | Should -BeTrue
        $request.Requested | Should -Be @('sqlvm01') -Because 'only what this run asked to start bills because of it'
        $script:billing | Should -Be @('sqlvm01') -Because 'the ending names what this run started, even after Ctrl+C (Phase 28)'
        $script:calls | Should -Be @('request sqlvm01') -Because 'a VM that''s still deallocating is only waited for'
        $script:page[0] | Should -Be 'StartVms|Running||Starting sqlvm01 (deallocated) and archost01 (deallocating), which were stopped; no action needed from you.'
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request } { Wait-DemoStoppedStart -Config $Config -Request $Request -ProgressPath 'progress.json' })
        $script:calls | Should -Contain 'running sqlvm01 requested=True'
        $script:calls | Should -Contain 'running archost01 requested=False'
        $script:calls | Should -Contain 'source release' -Because 'a golden snapshot''s source host gets its guest back, as start-demo.ps1 does'
        $script:calls | Should -Not -Contain 't1 monitoring' -Because 'T1''s Monitoring step runs in this run'
        $done = $results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }
        $done.status | Should -Be 'Pass'
        $done.message | Should -Match 'Started sqlvm01 and archost01, which had been stopped'
        $script:page[-1] | Should -Match '^StartVms\|\|Pass\|Started sqlvm01 and archost01'
        $script:billing[-1] | Should -Be 'sqlvm01,archost01' -Because 'the one that was still stopping was started too'
        @($done.evidence.started) | Should -Be @('sqlvm01', 'archost01')
    }

    It 'records as billing because of this run only the VMs it issued a start for, not one that was already starting (Phase 28 review)' {
        # Reviewer, 2026-10-30: the record named every VM that wasn't running, including one something else was starting.
        $script:power = @{ sqlvm01 = 'PowerState/starting'; archost01 = 'PowerState/deallocated' }
        $script:billing = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Add-DemoProgressStartedVm -MockWith { $script:billing.Add((@($PesterBoundParameters['Name']) -join ',')) }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -ProgressPath 'progress.json' -Confirm:$false }
        $request.Requested | Should -Be @('archost01')
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request } { Wait-DemoStoppedStart -Config $Config -Request $Request -ProgressPath 'progress.json' })
        $script:calls | Should -Contain 'running sqlvm01 requested=False' -Because 'a VM that''s starting is only waited for'
        $script:billing[-1] | Should -Be 'archost01'
        @(($results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }).evidence.started) | Should -Be @('archost01')
    }

    It 'starts a stopped T4 and waits for it, and leaves T1''s monitoring plugin to the caller''s check on every run (Phase 28 live finding)' {
        $withT4 = New-TestConfig -WithT4
        $script:power = @{ sqlvm01 = 'PowerState/stopped'; archost01 = 'PowerState/running' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith {
            $script:calls.Add(('t4 {0} requested={1}' -f $PesterBoundParameters['WaitMinutes'], [bool]$PesterBoundParameters['Requested']))
            $after = if ([int]$PesterBoundParameters['WaitMinutes'] -gt 0) { 'Ready' } else { 'Starting' }
            New-DemoResult -CheckId 'DEPLOY.T4.START' -Area 'infra' -Target 'T4' -Status 'Pass' -Message ('T4 is {0}.' -f $after) -Evidence ([ordered]@{ stateBefore = 'Stopped'; stateAfter = $after })
        }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $withT4 } { Request-DemoStoppedStart -Config $Config -Confirm:$false }
        $request.Names | Should -Be @('sqlvm01 (stopped)', 'T4 (stopped)')
        $request.Requested | Should -Be @('sqlvm01', 'T4')
        $script:page[0] | Should -Be 'StartVms|Running||Starting sqlvm01 and T4, which were stopped; no action needed from you.'
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $withT4; Request = $request } { Wait-DemoStoppedStart -Config $Config -Request $Request })
        # The plugin can stop hours after a start, so deploy.ps1 checks it on every run, not only after it started sqlvm01.
        $script:calls | Should -Be @('request sqlvm01', 't4 0 requested=False', 'running sqlvm01 requested=True', 't4 15 requested=True')
        $results | Where-Object { $_.checkId -eq 'DEPLOY.T1.MONITORING' } | Should -BeNullOrEmpty
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }).message | Should -Match 'T4 is Ready'
    }

    It 'says in plain words which VMs start because they were stopped, and that nothing is needed from the person (Phase 28 live run)' {
        # Live, 2026-10-30: "Starting the VMs that were stopped: no action needed (sqlvm01 (deallocated), archost01
        # (deallocated))" read as if nothing were needed for those VMs.
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -ProgressPath 'progress.json' -Confirm:$false }
        $script:page[0] | Should -Be 'StartVms|Running||Starting sqlvm01 and archost01, which were stopped (deallocated); no action needed from you.'
        $script:page.Clear()
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/stopped' }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -ProgressPath 'progress.json' -Confirm:$false }
        $script:page[0] | Should -Be 'StartVms|Running||Starting archost01, which was stopped; no action needed from you.'
    }

    It 'fails with the next action when a VM still doesn''t run, so nothing needs it' {
        $script:power = @{ sqlvm01 = 'PowerState/running'; archost01 = 'PowerState/deallocated' }
        $script:noStart = 'archost01'
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -Confirm:$false }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request } { Wait-DemoStoppedStart -Config $Config -Request $Request })
        $failed = $results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'archost01 isn''t running'
        $failed.remediation | Should -Match ([regex]::Escape('./scripts/start-demo.ps1'))
        $script:calls | Should -Not -Contain 'source release' -Because 'the host isn''t running'
    }

    It 'sets the interim baseline on each VM it started as soon as that VM runs, and waits for it before the run''s first Run Command there, and none on a VM that didn''t start (review of PR 16, and its re-review)' {
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActivityQuiet -MockWith {
            $script:calls.Add(('quiet {0} started={1} by={2}' -f (@($VmName) -join ','), [bool]$Started, $RequestedBy))
            foreach ($vm in $VmName) {
                [pscustomobject]@{ Target = $(if ($vm -eq 'archost01') { 'T2' } else { 'T1' }); VmName = $vm; Outcome = 'Sent'; Detail = 'sent'; Data = $null; Seconds = 0 }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoActivityInterim -MockWith {
            $script:calls.Add(('interim wait {0} {1}' -f (@($Record | ForEach-Object { $_.Target }) -join ','), $CheckPrefix))
            New-DemoResult -CheckId 'DEPLOY.INTERIM_T1' -Area 'workload' -Target 'T1' -Status 'Pass' -Message 'set'
        }
        $activity = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityProfile -Config $Config }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -Confirm:$false }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request; Activity = $activity } { Wait-DemoStoppedStart -Config $Config -Request $Request -ActivityProfile $Activity })
        $script:calls | Should -Be @('request sqlvm01', 'request archost01', 'running sqlvm01 requested=True', 'quiet sqlvm01 started=True by=deploy', 'running archost01 requested=True', 'source release', 'quiet archost01 started=True by=deploy', 'interim wait T1,T2 DEPLOY') -Because 'the golden source''s release comes as soon as archost01 runs, before its interim baseline, which must never wait for a guest the capture left off (review of PR 17)'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.INTERIM_T1' }).status | Should -Be 'Pass'

        # A VM that didn't start gets none.
        $script:calls.Clear()
        $script:noStart = 'archost01'
        $null = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request; Activity = $activity } { Wait-DemoStoppedStart -Config $Config -Request $Request -ActivityProfile $Activity })
        $script:calls | Should -Be @('running sqlvm01 requested=True', 'quiet sqlvm01 started=True by=deploy', 'running archost01 requested=True', 'interim wait T1 DEPLOY')

        # Without -ActivityProfile, nothing is sent or waited for, as before.
        $script:calls.Clear()
        $script:noStart = ''
        $null = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request } { Wait-DemoStoppedStart -Config $Config -Request $Request })
        @($script:calls | Where-Object { $_ -like 'quiet*' -or $_ -like 'interim*' }) | Should -BeNullOrEmpty
    }

    It 'sends archost01 no interim baseline, and waits for none, when the golden source''s release leaves its guest off (review of PR 17)' {
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -MockWith { $script:calls.Add('source release'); New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'archost01 is the source of snap-1, and its guest stays air-gapped: a golden capture is in progress on this host.' -Evidence ([ordered]@{ snapshots = @('snap-1'); captureInProgress = $true }) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActivityQuiet -MockWith {
            $script:calls.Add(('quiet {0}' -f (@($VmName) -join ',')))
            [pscustomobject]@{ Target = 'T1'; VmName = 'sqlvm01'; Outcome = 'Sent'; Detail = 'sent'; Data = $null; Seconds = 0 }
        }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoActivityInterim -MockWith {
            $script:calls.Add(('interim wait {0}' -f (@($Record | ForEach-Object { $_.Target }) -join ',')))
            New-DemoResult -CheckId 'DEPLOY.INTERIM_T1' -Area 'workload' -Target 'T1' -Status 'Pass' -Message 'set'
        }
        $activity = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityProfile -Config $Config }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -Confirm:$false }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Request = $request; Activity = $activity } { Wait-DemoStoppedStart -Config $Config -Request $Request -ActivityProfile $Activity })
        $script:calls | Should -Be @('request sqlvm01', 'request archost01', 'running sqlvm01 requested=True', 'quiet sqlvm01', 'running archost01 requested=True', 'source release', 'interim wait T1')
        $skipped = $results | Where-Object { $_.checkId -eq 'DEPLOY.INTERIM_T2' }
        $skipped.status | Should -Be 'Not selected'
        $skipped.message | Should -Match '^T2: no interim baseline to set on archost01, and none to wait for: a golden capture is in progress on archost01'
        ($results | Where-Object { $_.checkId -eq 'DEPLOY.VMSTART' }).status | Should -Be 'Pass'
    }

    It 'starts nothing in a what-if' {
        $script:power = @{ sqlvm01 = 'PowerState/deallocated'; archost01 = 'PowerState/deallocated' }
        $request = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Request-DemoStoppedStart -Config $Config -WhatIf }
        $request.Needed | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Request-DemoVmStart -Times 0 -Exactly
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

    It 'reports T2 as Not selected, not set up yet, when stop-demo.ps1 runs before its setup and the guest has no demo module (Phase 28 live finding)' {
        # Live: stop-demo.ps1 at the guided stop gave STOP.PROFILE_T2 a Warning with the guest's Import-Module error.
        $script:attempts = 0
        $script:failFirst = 9
        $script:message = 'The control action failed: The specified module ''C:\ProgramData\DbHubDemo\module\DbHubDemo.Vm.psd1'' was not loaded because no valid module file was found in any module directory.'
        $stop = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName off -CheckPrefix STOP } $config
        $stop.status | Should -Be 'Not selected'
        $stop.message | Should -Match 'T2 isn''t set up yet'
        $stop.message | Should -Match 'no activity runs there to turn off'
        # What the guest says since this fix, before it imports anything.
        $script:message = 'The control action failed: T2 isn''t set up yet: the guest gets its demo module after SQL Server setup, so the workload runner is not installed in the guest yet.'
        (& (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName baseline -CheckPrefix START } $config).status | Should -Be 'Not selected'
        $vmScript = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoWorkloadControl.ps1') -Raw
        $vmScript | Should -Match ([regex]::Escape('if (-not (Test-Path -LiteralPath $modulePath)) {'))
        $thrown = [regex]::Match($vmScript, "throw '(T2 isn''t set up yet(?:[^']|'')*)'").Groups[1].Value -replace "''", "'"
        $thrown | Should -Not -BeNullOrEmpty
        & (Get-Module -Name DbHubDemo) { param($t) Test-DemoT2NotSetUpText -Text $t } ('The control action failed: ' + $thrown) | Should -BeTrue
        # Any other T2 problem stays a Warning, and so does any other target's.
        $script:message = 'The control action failed: The module manifest DbHubDemo.Vm.psd1 could not be processed.'
        (& (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName off -CheckPrefix STOP } $config).status | Should -Be 'Warning'
        $script:message = 'The specified module was not loaded because no valid module file was found in any module directory.'
        (& (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName off -CheckPrefix STOP } $config).status | Should -Be 'Warning'
    }

    It 'spends one readiness budget across its attempts: a target that stays down costs it once (review, 2026-11-04)' {
        # The VM side waits up to readySeconds for its target before 'profile set'; start-demo.ps1's 3 attempts used to
        # wait 10 (T1) or 20 (T2) minutes each, 34 to 64 minutes in all, before the Warning.
        $script:ready = [System.Collections.Generic.List[int]]::new()
        $script:waits = $true
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:ready.Add($ReadySeconds)
            $evidence = if ($script:waits) { @{ ready = 'TimedOut'; readySeconds = $ReadySeconds } } else { @{} }
            [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Records = @(); Result = (New-DemoResult -CheckId ('WORKLOAD.{0}.COMMAND' -f $Target) -Area 'workload' -Target $Target -Status 'Fail' -Message 'T1 didn''t accept connections within 240 seconds' -Evidence $evidence) }
        }
        $down = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 120 } $config
        $down.status | Should -Be 'Warning'
        @($script:ready) | Should -Be @(240)
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly

        # A host whose bundle predates readySeconds fails at once: the retries and their pauses are as before.
        $script:ready.Clear()
        $script:waits = $false
        $null = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 120 } $config
        @($script:ready) | Should -Be @(240, 120, 0)
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 120 }

        # One attempt (deploy.ps1, stop-demo.ps1, the capture) never waits.
        $script:ready.Clear()
        $null = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName baseline -CheckPrefix DEPLOY } $config
        @($script:ready) | Should -Be @(0)
    }

    It 'counts what the VM side waited before a failure that isn''t readiness, and stays within the budget' {
        $script:ready = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:ready.Add($ReadySeconds)
            [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Records = @(); Result = (New-DemoResult -CheckId 'WORKLOAD.T1.COMMAND' -Area 'workload' -Target 'T1' -Status 'Fail' -Message 'runner exited with code 1' -Evidence @{ ready = 'Ready'; readySeconds = 100 }) }
        }
        $null = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 120 } $config
        @($script:ready) | Should -Be @(240, 20)
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 120 }
    }

    It 'doesn''t try T2 again while its relay holds the guest for a golden capture, and tries any other failure again (review of PR 17)' {
        $script:golden = 'CaptureInProgress'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoWorkloadCommand -MockWith {
            $script:attempts++
            [pscustomobject]@{ Status = 'Fail'; ExitCode = 1; Records = @(); Result = (New-DemoResult -CheckId ('WORKLOAD.{0}.COMMAND' -f $Target) -Area 'workload' -Target $Target -Status 'Fail' -Message 'runner profile set --target T2: A golden capture is in progress on ARCHOST01 (snapshot snap-1), so arcsql01 stays as the capture left it: off and air-gapped.' -Evidence @{ target = $Target; guest = 'arcsql01'; golden = $script:golden; readySeconds = 0 }) }
        }
        foreach ($golden in 'CaptureInProgress', 'CaptureMarkerUnreadable', 'CopyNotReset') {
            $script:attempts = 0
            $script:golden = $golden
            $held = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 120 } $config
            $held.status | Should -Be 'Warning'
            $held.message | Should -Match 'golden capture is in progress'
            $script:attempts | Should -Be 1 -Because ('{0} lasts until the capture ends or deploy.ps1 resets the copy' -f $golden)
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly

        # A guest that's still booting, for one, is tried again within the budget; so is any target's failure but T2's.
        $script:attempts = 0
        $script:golden = 'Source'
        $null = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 1 } $config
        $script:attempts | Should -Be 3
        $script:attempts = 0
        $script:golden = 'CaptureInProgress'
        $null = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T1 -ProfileName baseline -CheckPrefix START -Attempts 3 -RetrySeconds 1 } $config
        $script:attempts | Should -Be 3
    }

    It 'reports a T2 guest without SQL Server as Not selected, with the relay''s own words (Phase 28)' {
        $script:failFirst = 9
        $vmScript = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-DemoWorkloadControl.ps1') -Raw
        $said = [regex]::Match($vmScript, "\('(T2 isn''t set up yet: SQL Server isn''t installed in \{0\} yet(?:[^']|'')*)' -f \`$GuestName\)").Groups[1].Value -replace "''", "'"
        $said | Should -Not -BeNullOrEmpty
        $script:message = 'runner profile set --name baseline --target T2: ' + ($said -replace '\{0\}', 'arcsql01')
        $missing = & (Get-Module -Name DbHubDemo) { param($c) Set-DemoTargetProfile -Config $c -Target T2 -ProfileName baseline -CheckPrefix START } $config
        $missing.status | Should -Be 'Not selected'
        $missing.message | Should -Match 'T2 isn''t set up yet'
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
        @($results.checkId) | Should -Be @('PREFLIGHT.COST.SESSION', 'PREFLIGHT.COST.MONTHLY', 'START.COST.T4RESTART', 'START.COST.ACTUAL')
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
        # -ReportedUtc adds the agent's health report (its ComponentStatus/Resource Provider Plugin substatus; live,
        # 2026-11-04) with MainServiceLastReportedTime.
        function New-TestSqlIaasExtension([string] $PluginState, [bool] $FlagOn = $true, [string] $ReportedUtc = '') {
            $plugin = switch ($PluginState) {
                'Empty' { '' }
                'Running' { 'DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"};' }
                # The documented troubleshooting symptom of a blocked endpoint or identity (enable-performance-monitoring-sql-vm).
                'RunningHttp403' { 'DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"HTTP 403 Forbidden"};' }
                'RunningNoUpload' { 'DatabaseMonitorArcPlugin: {"State":"Running"};' }
                default { 'DatabaseMonitorArcPlugin: {"State":"' + $PluginState + '"};' }
            }
            [pscustomobject]@{
                settings     = [pscustomobject]@{ FeatureFlags = @([pscustomobject]@{ Name = 'DatabaseWatcheronAzureVM'; Enable = $FlagOn }) }
                instanceView = [pscustomobject]@{
                    statuses    = @([pscustomobject]@{ code = 'ProvisioningState/succeeded'; message = ('SQL Server IaaS Agent: Healthy;{0}Resource Provider Plugin: Rp plugin is enabled.' -f $plugin) })
                    substatuses = @(
                        [pscustomobject]@{ code = 'ComponentStatus/DatabaseMonitorArcPlugin/succeeded'; message = '{"endpointUrl":"https://telemetry.{0}.arcdataservices.com/","endpointAppId":"<id>"}' }
                        if ($ReportedUtc) { [pscustomobject]@{ code = 'ComponentStatus/Resource Provider Plugin/succeeded'; message = ('{"ExtensionServiceHealthReport":{"MainServiceStatus":"Running","MainServiceLastReportedTime":"' + $ReportedUtc + '"}}') } }
                    )
                }
            }
        }
    }

    BeforeEach {
        $script:pluginStates = [System.Collections.Generic.Queue[string]]::new()
        $script:flagOn = $true
        $script:reads = 0
        $script:readsAtRestart = -1
        # The VM's latest start in its instance view; $null (no time) compares with nothing, so every status is fresh.
        $script:vmSinceUtc = $null
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerInfo -MockWith { [pscustomobject]@{ PowerState = 'PowerState/running'; SinceUtc = $script:vmSinceUtc } }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm extension show ' } -MockWith {
            $script:reads++
            # 'State' or 'State|<MainServiceLastReportedTime>'.
            $entry = if ($script:pluginStates.Count -gt 1) { $script:pluginStates.Dequeue() } else { $script:pluginStates.Peek() }
            $parts = $entry.Split('|')
            New-TestSqlIaasExtension -PluginState $parts[0] -FlagOn $script:flagOn -ReportedUtc $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
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

    It 'passes a running plugin only with uploads OK, and hands back uploads that fail with their cause and fix, without a restart (Phase 28 review)' {
        # Reviewer, 2026-10-30: the early Pass checked only State Running, so a plugin that started by itself with its uploads
        # already failing passed here, and the deployment step lost the real cause.
        $script:pluginStates.Enqueue('RunningHttp403')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment' } $config
        $result.status | Should -Be 'Warning'
        $result.message | Should -Be 'sqlvm01''s monitoring plugin is running, but its uploads fail (HTTP 403 Forbidden); a restart of the SQL IaaS Agent doesn''t fix that.'
        $result.remediation | Should -Match '^Check sqlvm01''s system-assigned identity and outbound HTTPS to telemetry\.[a-z0-9]+\.arcdataservices\.com:443, then run \./scripts/configure-monitoring\.ps1\.$'
        $result.evidence.restarted | Should -BeFalse
        $result.evidence.after | Should -Match 'HTTP 403 Forbidden'

        $script:pluginStates.Clear()
        $script:pluginStates.Enqueue('RunningNoUpload')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.status | Should -Be 'Warning'
        $result.message | Should -Be 'sqlvm01''s monitoring plugin is running, but its uploads aren''t OK yet (upload status '''').'
        $result.remediation | Should -Match 'configure-monitoring\.ps1 -WaitMinutes 15'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly -Because 'a restart of the agent doesn''t fix uploads'
    }

    It 'reports as the deployment''s check when deploy.ps1 calls it after its wait (Phase 25d)' {
        # Live, 2026-10-27: after the deployment's template run the plugin stayed NotRunning; the restart brought it back.
        foreach ($state in 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        # The Monitoring step has already given the plugin its grace (Invoke-DemoSqlVmMonitoringWait), so it passes 0.
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment' -NotRunningGraceMinutes 0 } $config
        $result.checkId | Should -Be 'DEPLOY.T1.MONITORING'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'wasn''t running after the deployment \(DatabaseMonitorArcPlugin: \{"State":"NotRunning"\}\); the SQL IaaS Agent service was restarted'
        $script:readsAtRestart | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly -ParameterFilter { $Seconds -eq 60 }
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
        $result.evidence.gracePolls | Should -Be 0
        $result.evidence.after | Should -Match '"State":"Running","MetricsUploadStatus":"OK"'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $VmName -eq 'sqlvm01' -and $Script -match "Restart-Service -Name 'SQLIaaSExtension' -Force" }
    }

    It 'restarts the SQL IaaS Agent at once when the plugin stayed NotRunning after the start, with no grace by default, and waits for Running and OK' {
        # Live, 2026-10-22: NotRunning for more than 90 minutes after a deallocation and start; Running a minute after the
        # restart. start-demo.ps1 and deploy.ps1's check beside the tracks keep this immediate restart (the owner's decision,
        # 2026-10-30: presenters run start-demo.ps1 before each session).
        foreach ($state in 'NotRunning', 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -PollSeconds 1 } $config
        $script:readsAtRestart | Should -Be 1
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'restarted'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly -ParameterFilter { $Seconds -eq 60 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $VmName -eq 'sqlvm01' -and $Script -match "Restart-Service -Name 'SQLIaaSExtension' -Force" }

        # With a grace, the restart comes after it: the first read, then three more a minute apart.
        $script:pluginStates.Clear()
        $script:reads = 0
        foreach ($state in 'NotRunning', 'NotRunning', 'NotRunning', 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -PollSeconds 1 -NotRunningGraceMinutes 3 } $config
        $script:readsAtRestart | Should -Be 4
        $result.evidence.gracePolls | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 60 }
    }

    It 'counts the grace in elapsed time, the reads included, and never sleeps past its end (Phase 28 live finding)' {
        # Live, 2026-10-30: each read takes 15 to 20 seconds, so a wait counted in reads ran 25 minutes instead of 20.
        $script:pluginStates.Enqueue('NotRunning')
        $script:now = [datetime]::new(2026, 10, 30, 13, 30, 0, [System.DateTimeKind]::Utc)
        $script:sleeps = [System.Collections.Generic.List[int]]::new()
        $script:restartAt = $null
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:now }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:sleeps.Add([int]$Seconds); $script:now = $script:now.AddSeconds($Seconds) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm extension show ' } -MockWith {
            $script:reads++
            $script:now = $script:now.AddSeconds(20)
            New-TestSqlIaasExtension -PluginState $(if ($null -ne $script:restartAt) { 'Running' } else { 'NotRunning' })
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $script:readsAtRestart = $script:reads
            $script:restartAt = $script:now
            [pscustomobject]@{ Succeeded = $true; Output = 'SQLIaaSExtension is Running.' }
        }
        $start = $script:now
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment' -NotRunningGraceMinutes 3 } $config
        $result.status | Should -Be 'Pass'
        @($script:sleeps)[0..2] | Should -Be @(60, 60, 20) -Because 'the last sleep ends with the 3-minute grace'
        $script:readsAtRestart | Should -Be 4
        ($script:restartAt - $start).TotalSeconds | Should -Be 220 -Because 'the first read (20 s), then the grace of 180 s, and the read that ends it'
    }

    It 'says on the console and the status page, with a grace, that it waits for a NotRunning plugin, and leaves one that starts by itself alone (Phase 28 live finding)' {
        foreach ($state in 'NotRunning', 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $script:page = [System.Collections.Generic.List[string]]::new()
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:page.Add(('{0}|{1}|{2}' -f (@($PesterBoundParameters['Id']) -join ','), [bool]$PesterBoundParameters['AzureSide'], $PesterBoundParameters['Message'])) }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment' -NotRunningGraceMinutes 3 -ProgressPath 'progress.json' } $config
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'is running \(upload status ''OK''\), reported \d+ seconds after the check began'
        $result.evidence.gracePolls | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        $script:page | Should -Be @(
            'T1.Monitoring|True|T1''s monitoring plugin reports NotRunning; the deployment restarts it if it doesn''t start by itself within 3 minutes; no action needed.'
            'T1.Monitoring|True|T1''s monitoring plugin reports NotRunning (1 min so far); the deployment restarts it if it doesn''t start by itself within 2 minutes; no action needed.'
        )
        $script:logged | Should -Be @('T1''s monitoring plugin reports NotRunning; the deployment restarts it if it doesn''t start by itself within 3 minutes; no action needed.') -Because 'a console line on the first read, then every few minutes'
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

    It 'reads when the agent last reported, and has no time when it doesn''t say' {
        $status = & (Get-Module -Name DbHubDemo) { param($e) Get-DemoSqlVmMonitoringStatus -Extension $e } (New-TestSqlIaasExtension -PluginState 'Running' -ReportedUtc '2026-11-04T14:46:32Z')
        $status.State | Should -Be 'Running'
        $status.ReportedUtc | Should -Be ([datetime]::new(2026, 11, 4, 14, 46, 32, [System.DateTimeKind]::Utc))
        (& (Get-Module -Name DbHubDemo) { param($e) Get-DemoSqlVmMonitoringStatus -Extension $e } (New-TestSqlIaasExtension -PluginState 'Running')).ReportedUtc | Should -BeNullOrEmpty
    }

    It 'counts only a status reported after the VM''s start: a stale Running gets one restart when no fresh status comes within the wait (live, 2026-11-04)' {
        # Live: a minute after a cold start the instance view still said Running and OK from before the stop; 12 minutes
        # later NotRunning, and T1 had sent no telemetry. The restart brought it to Running and OK in 194 seconds.
        $script:vmSinceUtc = [datetime]::new(2026, 11, 4, 14, 35, 0, [System.DateTimeKind]::Utc)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { [datetime]::new(2026, 11, 4, 14, 36, 0, [System.DateTimeKind]::Utc) }
        foreach ($entry in 'Running|2026-11-04T03:10:00Z', 'Running|2026-11-04T03:10:00Z', 'Running|2026-11-04T03:10:00Z', 'Running|2026-11-04T14:40:00Z') {
            $script:pluginStates.Enqueue($entry)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -SettleMinutes 1 -PollSeconds 30 } $config
        $script:readsAtRestart | Should -Be 3 -Because 'it waited the whole -SettleMinutes for a fresh status'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match ('^sqlvm01''s monitoring plugin had no fresh status after the start \(no fresh plugin status since its start at 2026-11-04T14:35:00Z \(waited \d+ seconds\); the last one, reported at 2026-11-04T03:10:00Z, said ' + [regex]::Escape('DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"}') + '\); the SQL IaaS Agent service was restarted')
        $result.evidence.fresh | Should -BeFalse
        # The result's JSON round trip can turn these into DateTime values in PowerShell 7.
        $asUtc = { param($Value) ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
        & $asUtc $result.evidence.startedUtc | Should -Be '2026-11-04T14:35:00Z'
        & $asUtc $result.evidence.reportedUtc | Should -Be '2026-11-04T03:10:00Z'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly

        # -StartedUtc, when a caller knows its start, comes before the instance view.
        $script:pluginStates.Clear()
        $script:reads = 0
        $script:vmSinceUtc = $null
        foreach ($entry in 'Running|2026-11-04T03:10:00Z', 'Running|2026-11-04T03:10:00Z', 'Running|2026-11-04T03:10:00Z', 'Running|2026-11-04T14:40:00Z') {
            $script:pluginStates.Enqueue($entry)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -StartedUtc ([datetime]::new(2026, 11, 4, 14, 34, 25, [System.DateTimeKind]::Utc)) -SettleMinutes 1 -PollSeconds 30 } $config
        $script:readsAtRestart | Should -Be 3
        & $asUtc $result.evidence.startedUtc | Should -Be '2026-11-04T14:34:25Z'
    }

    It 'restarts the SQL IaaS Agent at once when a fresh status says NotRunning' {
        $script:vmSinceUtc = [datetime]::new(2026, 11, 4, 14, 35, 0, [System.DateTimeKind]::Utc)
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { [datetime]::new(2026, 11, 4, 14, 36, 0, [System.DateTimeKind]::Utc) }
        foreach ($entry in 'NotRunning|2026-11-04T14:35:40Z', 'Running|2026-11-04T14:39:00Z') {
            $script:pluginStates.Enqueue($entry)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $script:readsAtRestart | Should -Be 1
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'wasn''t running after the start \(DatabaseMonitorArcPlugin: \{"State":"NotRunning"\}\); the SQL IaaS Agent service was restarted'
        $result.evidence.fresh | Should -BeTrue
    }

    It 'leaves the plugin alone when a fresh status says Running' {
        $script:vmSinceUtc = [datetime]::new(2026, 11, 4, 14, 35, 0, [System.DateTimeKind]::Utc)
        $script:pluginStates.Enqueue('Running|2026-11-04T14:35:40Z')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.status | Should -Be 'Pass'
        $result.evidence.fresh | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
    }

    It 'restarts once after a recent start when the agent reports no time, and takes a VM that has run a while at its word' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { [datetime]::new(2026, 11, 4, 14, 36, 0, [System.DateTimeKind]::Utc) }
        $script:vmSinceUtc = [datetime]::new(2026, 11, 4, 14, 34, 0, [System.DateTimeKind]::Utc)
        foreach ($entry in 'Running', 'Running', 'Running', 'Running') {
            $script:pluginStates.Enqueue($entry)
        }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -SettleMinutes 1 -PollSeconds 30 } $config
        $script:readsAtRestart | Should -Be 3
        $result.status | Should -Be 'Pass' -Because 'after the restart, an agent without the time is taken at its word'
        $result.evidence.reportedUtc | Should -Be 'an unknown time'

        $script:pluginStates.Clear()
        $script:reads = 0
        $script:readsAtRestart = -1
        $script:vmSinceUtc = [datetime]::new(2026, 11, 4, 12, 0, 0, [System.DateTimeKind]::Utc)
        $script:pluginStates.Enqueue('Running')
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.status | Should -Be 'Pass'
        $script:readsAtRestart | Should -Be -1 -Because 'a VM started more than 30 minutes ago isn''t restarted for a status without a time'
    }

    It 'touches nothing when monitoring isn''t turned on' {
        $script:pluginStates.Enqueue('NotRunning')
        $script:flagOn = $false
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c } $config
        $result.status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 0 -Exactly
    }

    It 'says on the status page, as it restarts the agent, that T1''s monitoring plugin is restarting with no action needed (Phase 28 live finding)' {
        foreach ($state in 'NotRunning', 'Running') {
            $script:pluginStates.Enqueue($state)
        }
        $script:page = [System.Collections.Generic.List[string]]::new()
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:page.Add(('{0}|{1}|{2}|{3}|{4}' -f (@($PesterBoundParameters['Id']) -join ','), $PesterBoundParameters['State'], $PesterBoundParameters['Status'], [bool]$PesterBoundParameters['AzureSide'], $PesterBoundParameters['Message'])) }
        $result = & (Get-Module -Name DbHubDemo) { param($c) Restore-DemoSqlVmMonitoringPlugin -Config $c -CheckId 'DEPLOY.T1.MONITORING' -Occasion 'the deployment' -NotRunningGraceMinutes 0 -ProgressPath 'progress.json' } $config
        $result.status | Should -Be 'Pass'
        $script:page | Should -Be @('T1.Monitoring|Running||True|Restarting T1''s monitoring plugin, which stopped after a restart; no action needed.')
        $script:readsAtRestart | Should -Be 1 -Because 'the message comes just before the restart'
        $script:logged[0] | Should -Be 'sqlvm01''s monitoring plugin reports DatabaseMonitorArcPlugin: {"State":"NotRunning"}; restarting the SQL IaaS Agent service so it starts again; no action needed.'
        $script:logged[1] | Should -Be 'The SQL IaaS Agent service on sqlvm01 restarted; waiting up to 5 minutes for its monitoring plugin to report Running and OK; no action needed.'

        # The check deploy.ps1 runs on every run: the step shows it, and a failure is a Warning, never an exception.
        $script:page.Clear()
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith { throw 'The VM isn''t running (deallocated or stopped).' }
        $check = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoT1MonitoringCheck -Config $c -ProgressPath 'progress.json' } $config
        $check.checkId | Should -Be 'DEPLOY.T1.MONITORING'
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'T1''s monitoring plugin couldn''t be checked: The VM isn''t running'
        Should -Invoke -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('NotRunningGraceMinutes') } -Because 'the check beside the tracks restarts at once, Restore''s default (the owner''s decision, 2026-10-30)'
        $script:page[0] | Should -Be 'T1.Monitoring|Running||True|Checking T1''s monitoring plugin, which can stop after a restart: no action needed.'
        $script:page[-1] | Should -Match '^T1\.Monitoring\|\|Warning\|False\|T1''s monitoring plugin couldn''t be checked'
    }
}

Describe 'Invoke-DemoSqlVmMonitoringWait: a deployment step''s T1 monitoring (Phase 28 live finding, 2026-10-30)' {
    BeforeAll {
        $config = New-TestConfig
        $script:waitRemediation = 'Run configure-monitoring.ps1 -WaitMinutes 15, or check again later.'
        function New-StuckMonitoring {
            New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Warning' -Message 'The DatabaseWatcheronAzureVM flag is set on sqlvm01, but DatabaseMonitorArcPlugin doesn''t report Running and OK yet (state ''NotRunning'', upload '''').' -Remediation $script:waitRemediation -Evidence ([ordered]@{ provisioningState = 'Succeeded'; featureFlagEnabled = $true; pluginState = 'NotRunning'; powerState = 'PowerState/running'; pending = $true; stoppedForRestart = $true })
        }
    }

    BeforeEach {
        # Live, b18a028's rerun from deallocated VMs: the step waited 25 minutes on a NotRunning plugin, the restart brought it
        # back in 17 seconds, and the console still printed the wait's "Run configure-monitoring.ps1 -WaitMinutes 15".
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:logged = [System.Collections.Generic.List[string]]::new()
        $script:restoreStatus = 'Pass'
        $script:restoreRestarted = $true
        $script:reread = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith { $script:calls.Add(('wait {0} grace {1}' -f $PesterBoundParameters['WaitMinutes'], $PesterBoundParameters['NotRunningGraceMinutes'])); New-StuckMonitoring }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoSqlVmMonitoringPlugin -MockWith {
            $script:calls.Add(('restore {0} grace {1}' -f $PesterBoundParameters['CheckId'], $PesterBoundParameters['NotRunningGraceMinutes']))
            $message = if (-not $script:restoreRestarted) { 'sqlvm01''s monitoring plugin is running (upload status ''OK''), reported 200 seconds after the check began.' } else { 'sqlvm01''s monitoring plugin wasn''t running after the deployment; the SQL IaaS Agent service was restarted, and it''s Running with uploads OK after 17 seconds.' }
            New-DemoResult -CheckId $PesterBoundParameters['CheckId'] -Area 't1' -Target 'T1' -Status $script:restoreStatus -Message $message -Remediation $(if ($script:restoreStatus -eq 'Pass') { '' } else { './scripts/configure-monitoring.ps1 -WaitMinutes 15 checks it again.' }) -Evidence ([ordered]@{ restarted = $script:restoreRestarted })
        }
        # T1.SQLVM.MONITORING read right after, as ConvertTo-DemoSqlVmMonitoringResult and Test-DemoSqlVmMonitoring report it.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoSqlVmMonitoring -MockWith {
            $script:calls.Add('reread')
            switch ($script:reread) {
                'Pass' {
                    New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Pass' -Message 'sqlvm01 reports DatabaseMonitorArcPlugin Running with MetricsUploadStatus OK.' -Evidence ([ordered]@{ pluginState = 'Running'; metricsUploadStatus = 'OK'; pending = $false })
                }
                'Fail' {
                    New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Fail' -Message 'Monitoring runs on sqlvm01, but uploads fail: HTTP 403 Forbidden.' -Remediation 'Check the VM''s system-assigned identity and outbound HTTPS to telemetry.<location>.arcdataservices.com:443.' -Evidence ([ordered]@{ pluginState = 'Running'; metricsUploadStatus = 'HTTP 403 Forbidden'; pending = $false })
                }
                'Pending' {
                    New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Warning' -Message 'The DatabaseWatcheronAzureVM flag is set on sqlvm01, but DatabaseMonitorArcPlugin doesn''t report Running and OK yet (state ''Running'', upload '''').' -Remediation $script:waitRemediation -Evidence ([ordered]@{ pluginState = 'Running'; metricsUploadStatus = ''; pending = $true })
                }
                default {
                    throw 'The operation timed out.'
                }
            }
        }
    }

    It 'restarts a plugin still NotRunning after the short grace, then reports T1.SQLVM.MONITORING as it is then, so the console doesn''t tell the person to act' {
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 -ProgressPath 'progress.json' } $config)
        $script:calls | Should -Be @('wait 20 grace 3', 'restore DEPLOY.T1.MONITORING grace 0', 'reread') -Because 'the flag was set before this run, and the restart waits no second grace'
        @($results.checkId) | Should -Be @('T1.SQLVM.MONITORING', 'DEPLOY.T1.MONITORING')
        $results[0].status | Should -Be 'Pass'
        $results[0].remediation | Should -BeNullOrEmpty
        $results[0].message | Should -Match 'The plugin had reported NotRunning; the SQL IaaS Agent service was restarted \(DEPLOY\.T1\.MONITORING\)\.$'
        $results[0].evidence.restartCheckId | Should -Be 'DEPLOY.T1.MONITORING'
        $results[0].evidence.restarted | Should -BeTrue
        $results[0].evidence.pluginStateBefore | Should -Be 'NotRunning'

        $previous = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = ''
        try {
            Write-DemoResultReport -Result $results -Title 'deploy.ps1' 6>$null
        }
        finally {
            $env:GITHUB_STEP_SUMMARY = $previous
        }
        @($script:logged | Where-Object { $_ -like 'T1.SQLVM.MONITORING*' }) | Should -BeNullOrEmpty

        # When this run merged the flag (T1's Bootstraps step), the plugin gets the longer grace first.
        $script:calls.Clear()
        $null = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 -JustMerged } $config
        $script:calls[0] | Should -Be 'wait 20 grace 5'

        # start-demo.ps1, after it recreates T3, restarts a NotRunning plugin at once (the owner's decision, 2026-10-30).
        $script:calls.Clear()
        $null = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 -RestartAtOnce -CheckId 'START.T1.MONITORING' } $config
        @($script:calls)[0..1] | Should -Be @('wait 20 grace 0', 'restore START.T1.MONITORING grace 0')
    }

    It 'marks the wait''s Warning superseded, without a remediation and without claiming uploads OK, when a read right after the restart is still a wait' {
        # Phase 28 review (2026-10-30): "superseded" only for a read that's still a wait, with what that read shows.
        $script:reread = 'Pending'
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 -CheckId 'START.T1.MONITORING' } $config)
        @($results.checkId) | Should -Be @('T1.SQLVM.MONITORING', 'START.T1.MONITORING')
        $results[0].status | Should -Be 'Warning'
        $results[0].remediation | Should -BeNullOrEmpty
        $results[0].message | Should -Match 'Superseded: the SQL IaaS Agent service was restarted \(START\.T1\.MONITORING\); a read right after shows state ''Running'', upload ''''\.$'
        $results[0].message | Should -Not -Match 'uploads OK'
        $results[0].evidence.superseded | Should -BeTrue
        $results[0].evidence.restarted | Should -BeTrue
    }

    It 'returns a Fail read right after a restart that passed unchanged, with its own cause and fix and the restart in its evidence (Phase 28 review)' {
        # Reviewer, 2026-10-30, reproduced: the Fail went to the else branch, which returned the wait's Warning, superseded,
        # without a remediation, and with "...restarted, and the plugin reported Running with uploads OK".
        $script:reread = 'Fail'
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 } $config)
        @($results.checkId) | Should -Be @('T1.SQLVM.MONITORING', 'DEPLOY.T1.MONITORING')
        $results[0].status | Should -Be 'Fail'
        $results[0].message | Should -Be 'Monitoring runs on sqlvm01, but uploads fail: HTTP 403 Forbidden.'
        $results[0].remediation | Should -Be 'Check the VM''s system-assigned identity and outbound HTTPS to telemetry.<location>.arcdataservices.com:443.'
        $results[0].evidence.metricsUploadStatus | Should -Be 'HTTP 403 Forbidden'
        $results[0].evidence.restartCheckId | Should -Be 'DEPLOY.T1.MONITORING'
        $results[0].evidence.restarted | Should -BeTrue
        $results[0].evidence.pluginStateBefore | Should -Be 'NotRunning'
        $results[0].evidence.Contains('superseded') | Should -BeFalse
    }

    It 'returns a Fail read unchanged when the plugin started without a restart, and when the restart didn''t help (Phase 28 review)' {
        # The reviewer's second variant: Restore found the plugin Running (no restart), and the read right after is a Fail.
        $script:reread = 'Fail'
        $script:restoreRestarted = $false
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 } $config)
        $results[0].status | Should -Be 'Fail'
        $results[0].message | Should -Be 'Monitoring runs on sqlvm01, but uploads fail: HTTP 403 Forbidden.'
        $results[0].remediation | Should -Match 'system-assigned identity'
        $results[0].evidence.restarted | Should -BeFalse
        $results[0].message | Should -Not -Match 'Superseded|uploads OK'

        $script:restoreRestarted = $true
        $script:restoreStatus = 'Warning'
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 } $config)
        $results[0].status | Should -Be 'Fail'
        $results[1].status | Should -Be 'Warning'

        # A read that throws is a Fail too, as Test-DemoSqlVmMonitoring reports one, never a superseded Warning.
        $script:restoreStatus = 'Pass'
        $script:reread = 'Throw'
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 } $config)
        $results[0].status | Should -Be 'Fail'
        $results[0].message | Should -Be 'Azure couldn''t be read: The operation timed out.'
        $results[0].evidence.restarted | Should -BeTrue
    }

    It 'names a restart in a Pass read only when there was one' {
        $script:restoreRestarted = $false
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 } $config)
        $results[0].status | Should -Be 'Pass'
        $results[0].message | Should -Match 'The plugin had reported NotRunning; then it started without a restart \(DEPLOY\.T1\.MONITORING\)\.$'
        $results[0].evidence.restarted | Should -BeFalse
    }

    It 'leaves the wait''s Warning and its remediation when the restart didn''t bring the plugin back, and restarts nothing that isn''t stuck' {
        $script:restoreStatus = 'Warning'
        $script:reread = 'Pending'
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c -WaitMinutes 20 } $config)
        $results[0].remediation | Should -Be $script:waitRemediation
        $results[0].message | Should -Not -Match 'Superseded'
        $results[1].status | Should -Be 'Warning'
        $script:calls | Should -Contain 'reread' -Because 'a read right after can show a Fail with its own cause'

        $script:calls.Clear()
        Mock -ModuleName DbHubDemo -CommandName Enable-DemoSqlVmMonitoring -MockWith { $script:calls.Add('wait'); New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Pass' -Message 'Running and OK.' -Evidence ([ordered]@{ pluginState = 'Running' }) }
        $results = @(& (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoSqlVmMonitoringWait -Config $c } $config)
        @($results.checkId) | Should -Be @('T1.SQLVM.MONITORING')
        $script:calls | Should -Be @('wait')
    }
}

Describe 'T1''s monitoring when Azure can''t be read (review of c7c86ec)' {
    BeforeAll {
        $config = New-TestConfig
        # What the Azure CLI writes when it can't reach Azure Resource Manager (fake host lookup failure).
        $script:unreachable = 'ERROR: HTTPSConnectionPool(host=''management.azure.com'', port=443): Max retries exceeded with url: /subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo (Caused by NameResolutionError("Failed to resolve ''management.azure.com''"))'
        $script:extensionJson = ConvertTo-Json -Depth 10 -InputObject ([ordered]@{
                name              = 'SqlIaasExtension'
                provisioningState = 'Succeeded'
                settings          = [ordered]@{ FeatureFlags = @([ordered]@{ Name = 'DatabaseWatcheronAzureVM'; Enable = $true }) }
                instanceView      = [ordered]@{ typeHandlerVersion = '2.0.240.0'; statuses = @([ordered]@{ code = 'ProvisioningState/succeeded'; message = 'SQL Server IaaS Agent: Healthy;DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"};' }) }
            })
    }

    BeforeEach {
        $script:failing = ''
        $script:sqlRegistration = 'Registered'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmInventoryInstance -MockWith { [pscustomobject]@{ properties = [pscustomobject]@{ edition = 'Standard' } } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $part = if ($joined -like 'vm extension show *') { 'extension' } elseif ($joined -like 'vm show *') { 'vm' } elseif ($joined -like 'provider show --namespace Microsoft.Sql *') { 'sql' } elseif ($joined -like 'provider show --namespace Microsoft.AzureArcData *') { 'arcdata' } else { 'other' }
            if ($part -eq $script:failing) {
                return (New-AzResult -ExitCode 1 -StdErr $script:unreachable)
            }
            if ($part -eq 'extension' -and $script:failing -eq 'missing') {
                return (New-AzResult -ExitCode 3 -StdErr "ERROR: (ResourceNotFound) The Resource 'Microsoft.Compute/virtualMachines/sqlvm01/extensions/SqlIaasExtension' under resource group 'rg-dbhub-demo' was not found.")
            }
            if ($part -eq 'sql' -and $script:sqlRegistration -eq 'GatewayTimeout') {
                return (New-AzResult -ExitCode 1 -StdErr "ERROR: (GatewayTimeout) The gateway did not receive a response from 'Microsoft.Resources' within the specified time period.")
            }
            switch ($part) {
                'extension' { return (New-AzResult -StdOut $script:extensionJson) }
                'vm' { return (New-AzResult -StdOut '{"name":"sqlvm01","identity":{"type":"SystemAssigned"}}') }
                'sql' { return (New-AzResult -StdOut $script:sqlRegistration) }
                'arcdata' { return (New-AzResult -StdOut 'Registered') }
            }
            if ($joined -like 'vm get-instance-view *') {
                return (New-AzResult -StdOut '{"instanceView":{"statuses":[{"code":"PowerState/running"}]}}')
            }
            return (New-AzResult -StdOut '{"sqlManagement":"Full"}')
        }
    }

    It 'says Azure couldn''t be read, with the redacted error, instead of a missing extension, identity, or registration' {
        foreach ($case in @(
                @{ Failing = 'extension'; What = 'the SqlIaasExtension on sqlvm01'; Not = 'has no SqlIaasExtension' }
                @{ Failing = 'vm'; What = 'sqlvm01'; Not = 'system-assigned managed identity' }
                @{ Failing = 'arcdata'; What = 'the Microsoft\.AzureArcData registration'; Not = 'not Registered' }
            )) {
            $script:failing = $case.Failing
            $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoSqlVmMonitoring -Config $Config }
            $result.status | Should -Be 'Fail' -Because $case.Failing
            $result.message | Should -Match ('^Azure couldn''t be read for sqlvm01''s monitoring: {0}: ERROR: HTTPSConnectionPool' -f $case.What)
            $result.message | Should -Not -Match $case.Not
            $result.remediation | Should -Be 'Run ./scripts/deploy.ps1 again: it resumes at T1''s Monitoring step (or run ./scripts/configure-monitoring.ps1 again).'
            @($result.evidence.readErrors).Count | Should -BeGreaterThan 0
        }

        # Not found is still what it was: the extension is missing.
        $script:failing = 'missing'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoSqlVmMonitoring -Config $Config }).message | Should -Be 'sqlvm01 has no SqlIaasExtension, so performance monitoring can''t run.'
        $script:failing = ''
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoSqlVmMonitoring -Config $Config }).status | Should -Be 'Pass'
    }

    It 'returns that Fail after the agent''s restart (R584), with the restart in its evidence, so the step stops on the real cause' {
        $script:failing = 'extension'
        $stuck = New-DemoResult -CheckId 'T1.SQLVM.MONITORING' -Area 't1' -Target 'T1' -Status 'Warning' -Message 'The DatabaseWatcheronAzureVM flag is set on sqlvm01, but DatabaseMonitorArcPlugin doesn''t report Running and OK yet (state ''NotRunning'', upload '''').' -Evidence ([ordered]@{ pluginState = 'NotRunning'; pending = $true })
        $restore = New-DemoResult -CheckId 'DEPLOY.T1.MONITORING' -Area 't1' -Target 'T1' -Status 'Pass' -Message 'Restarted.' -Evidence ([ordered]@{ restarted = $true })
        $after = InModuleScope DbHubDemo -Parameters @{ Config = $config; Monitoring = $stuck; Restore = $restore } { Get-DemoSqlVmMonitoringAfterRestart -Config $Config -Monitoring $Monitoring -Restore $Restore }
        $after.status | Should -Be 'Fail'
        $after.message | Should -Match '^Azure couldn''t be read for sqlvm01''s monitoring: the SqlIaasExtension on sqlvm01: ERROR: HTTPSConnectionPool'
        $after.message | Should -Not -Match 'has no SqlIaasExtension'
        $after.remediation | Should -Match 'Run \./scripts/deploy\.ps1 again: it resumes at T1''s Monitoring step'
        $after.evidence.restarted | Should -BeTrue
        $after.evidence.restartCheckId | Should -Be 'DEPLOY.T1.MONITORING'
    }

    It 'keeps a Microsoft.Sql registration that couldn''t be read the Warning an unregistered one gets, not a Fail (review of 76d10b2)' {
        # 76d10b2 made a GatewayTimeout on this read a Fail that stopped T1's Monitoring step and blocked DONE.
        $sqlWarning = 'T1 uploads telemetry, but Microsoft.Sql isn''t Registered; Database Hub needs it.'
        foreach ($case in @(
                @{ Registration = 'GatewayTimeout'; Failing = ''; State = 'Unknown' }
                @{ Registration = 'Registered'; Failing = 'sql'; State = 'Unknown' }
                @{ Registration = 'NotRegistered'; Failing = ''; State = 'NotRegistered' }
            )) {
            $script:sqlRegistration = $case.Registration
            $script:failing = $case.Failing
            $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoSqlVmMonitoring -Config $Config }
            $result.status | Should -Be 'Warning' -Because ('{0} {1}' -f $case.Registration, $case.Failing)
            $result.message | Should -Be $sqlWarning
            $result.evidence.providers['Microsoft.Sql'] | Should -Be $case.State
            $result.evidence.Contains('readErrors') | Should -BeFalse
        }

        # A failed extension or VM read is still "couldn't be read", and names only what failed.
        $script:sqlRegistration = 'GatewayTimeout'
        foreach ($failing in 'extension', 'vm') {
            $script:failing = $failing
            $result = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Test-DemoSqlVmMonitoring -Config $Config }
            $result.status | Should -Be 'Fail'
            $result.message | Should -Match '^Azure couldn''t be read for sqlvm01''s monitoring: '
            $result.message | Should -Not -Match 'Microsoft\.Sql|GatewayTimeout'
            @($result.evidence.readErrors).Count | Should -Be 1
        }
    }
}
