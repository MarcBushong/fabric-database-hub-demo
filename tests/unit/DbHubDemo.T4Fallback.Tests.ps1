# T4's fallback (ADR 0019; since T4's 4-vCore default, 2026-11-04): when Azure refuses Standard_D4ds_v5 with
# SkuNotAvailable, deploy.ps1 tries another zone, then Standard_D4ads_v5, then Standard_D2ds_v5 (autonomous tuning off)
# after a cost check, says so, and keeps it. Since 2026-11-09 (user-directed) T4 is part of every deployment: a cost check
# that doesn't pass, or t4AutonomousTuning true, is a Warning and T4 is created anyway, no record leaves it out, and only
# Azure's refusal of every size does, with a Fail. The tests kept Phase 28's shape: its B1ms, B2s, and D2ds_v5 steps are
# now D4ds_v5, D4ads_v5, and D2ds_v5. One
# Describe per guardrail, and one for a record that says an earlier run left T4 out (review of 64c28b2). Preflight's
# part is in DbHubDemo.Preflight.Tests.ps1, the estimate's in DbHubDemo.Cost.Tests.ps1, status.ps1's restart date and its
# reading of T4 whatever the record says in DbHubDemo.Lifecycle.Tests.ps1, stop-demo.ps1's in DbHubDemo.T4.Tests.ps1,
# and the status page's Infrastructure step in DbHubDemo.Tracks.Tests.ps1. Prices here are obviously fake fixtures, never
# real ones (ADR 0016), and no test reaches Azure or the Retail Prices API.
BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    # Obviously fake IDs: every group repeats one character.
    function New-TestConfig([switch] $Off, [string] $SkuName = '', [switch] $Control) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        $config['t4Enabled'] = -not $Off
        if ($SkuName) {
            $config['t4SkuName'] = $SkuName
        }
        if ($Control) {
            $config['control']['enabled'] = $true
        }
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    # The cost check's verdict, in ConvertTo-DemoT4FallbackCost's shape.
    function New-TestCost([string] $SkipReason = '', [object] $HourlyUsd = 0.5, [double] $MonthlyWorstCaseUsd = 220.0, [double] $SessionUsd = 8.0, [string] $SkuName = 'Standard_D2ds_v5', [string] $RestartAssumption = '', [double] $T4LightUseMonthlyUsd = 25.0, [double] $T4MonthlyWorstCaseUsd = 385.0) {
        [pscustomobject]@{
            Allowed               = (-not $SkipReason)
            SkipReason            = $SkipReason
            SkuName               = $SkuName
            RestartAssumption     = $RestartAssumption
            HourlyUsd             = $HourlyUsd
            T4LightUseMonthlyUsd  = $(if ($null -ne $HourlyUsd) { $T4LightUseMonthlyUsd } else { $null })
            T4MonthlyWorstCaseUsd = $(if ($null -ne $HourlyUsd) { $T4MonthlyWorstCaseUsd } else { $null })
            LightUseMonthlyUsd    = 100.0
            MonthlyWorstCaseUsd   = $MonthlyWorstCaseUsd
            SessionUsd            = $SessionUsd
            MonthlyCeilingUsd     = 250.0
            SessionCeilingUsd     = 15.0
            DefenderIncluded      = $true
            Unpriced              = @()
            Location              = 'westus3'
            PriceError            = $(if ($SkipReason -eq 'Price') { 'offline' } else { '' })
        }
    }

    # The demo's estimate with T4 at Standard_D2ds_v5, in Get-DemoCostEstimate's shape.
    function New-TestEstimate([double] $LightUse = 100.0, [double] $Restart = 120.0, [double] $Session = 8.0, [double] $UnitPrice = 0.25, [switch] $NoCompute, [switch] $NoDefender, [string[]] $Missing = @()) {
        [pscustomobject]@{
            LightUseMonthly               = $LightUse
            T4AutoRestartWorstCaseMonthly = $Restart
            SessionCost                   = $Session
            T4FixedMonthly                = 20.0
            DefenderIncluded              = (-not $NoDefender)
            MissingPrices                 = $Missing
            Components                    = @(if (-not $NoCompute) { [pscustomobject]@{ Name = 'T4 compute (Standard_D2ds_v5)'; UnitPrice = $UnitPrice; Quantity = 2 } })
        }
    }

    function New-TestState([string] $T4Sku, [string] $TrackT4 = 'Telemetry', [string] $T4Refused = '') {
        [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = $TrackT4; TrackFabric = 'Fabric'; T4Sku = $T4Sku; T4Refused = $T4Refused; GuidedStopUtc = ''; HostPasswordUtc = '' }
    }

    # A fake template step: Azure answers a T4 size with $script:codes[<size>] (SkuNotAvailable, or another error code)
    # and creates everything else; $script:server is an existing T4 server (Servers - Get's sku), or $null. With
    # $script:freeOfferFails, Azure rejects the T3 free offer. What each attempt sent, the tags it carried, and what the
    # fallback recorded at once are kept. T4's server depends only on the network (infra/modules/demo.bicep), so the
    # attempt that sends $script:createsServer's size creates it whatever else fails in that attempt: the T3 free offer, or
    # another resource with $script:elsewhere[<size>]'s code (the post-merge review of 64c28b2). With
    # $script:refusesExisting, Azure answers $script:codes for an existing server's update too.
    function Initialize-TemplateHarness {
        $script:sizes = [System.Collections.Generic.List[string]]::new()
        $script:recorded = [System.Collections.Generic.List[string]]::new()
        $script:deployCalls = [System.Collections.Generic.List[object]]::new()
        $script:codes = @{}
        $script:currentSize = ''
        $script:groupTags = @{ deploymentId = 'abc123' }
        $script:server = $null
        $script:cost = New-TestCost
        $script:freeOfferFails = $false
        $script:createsServer = ''
        $script:elsewhere = @{}
        $script:refusesExisting = $false
        # The zones the region's capabilities list for Standard_D4ds_v5, for the fallback's retry in another zone; none by
        # default, so the fallback moves straight on to Standard_D4ads_v5.
        $script:zones = @()
        # The zones the region lists for other sizes, by size, in their tier's edition (2026-11-09, a size t4SkuName sets).
        $script:skuZones = @{}
        $script:sentZones = [System.Collections.Generic.List[string]]::new()
        # What the fallback recorded in DbHubT4Refused, and each size's cost check (2026-11-09).
        $script:recordedRefused = [System.Collections.Generic.List[string]]::new()
        $script:costBySize = @{}
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { $script:groupTags }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoExistingVmName -MockWith { @('sqlvm01', 'archost01') }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBudgetStartDate -MockWith { '2026-11-01' }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT1SecurityType -MockWith { [pscustomobject]@{ SecurityType = 'TrustedLaunch' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { @() }
        $script:serverState = 'Ready'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = ($null -ne $script:server); State = $(if ($null -ne $script:server) { $script:serverState } else { 'NotFound' }); Server = $script:server } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -MockWith {
            if ([string]$script:codes[$script:currentSize] -eq 'SkuNotAvailable') {
                [pscustomobject]@{ Sku = $script:currentSize; Zone = $(if ($script:sentZones.Count -gt 0) { [string]$script:sentZones[-1] } else { '' }); TimeUtc = '2026-11-02T14:00:00Z' }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:recorded.Add([string]$Value['T4Sku']); $script:recordedRefused.Add([string]$Value['T4Refused']) }
        # The sizes priced since the harness was set up (Should -Invoke counts a whole It's calls). The 2-vCore fallback calls
        # without -SkuName, as it always has, and Pester sets no variable for a parameter that isn't bound, which strict mode
        # refuses to read (CI on 413990f), so the size comes from $PesterBoundParameters, with the function's own default.
        $script:pricedSizes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith {
            $pricedSize = if ($PesterBoundParameters.ContainsKey('SkuName')) { [string]$PesterBoundParameters['SkuName'] } else { 'Standard_D2ds_v5' }
            $script:pricedSizes.Add($pricedSize)
            if ($script:costBySize.ContainsKey($pricedSize)) { $script:costBySize[$pricedSize] } else { $script:cost }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            $script:currentSize = if (-not $Config['t4Enabled']) { 'none' } elseif ($Config.Contains('t4SkuName') -and $Config['t4SkuName']) { [string]$Config['t4SkuName'] } else { 'Standard_D4ds_v5' }
            $script:sizes.Add($script:currentSize)
            $script:sentZones.Add([string]$Config['t4AvailabilityZone'])
            @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{ t3UseFreeLimit = @{ value = $T3UseFreeLimit }; budgetTags = @{ value = $ExistingResourceGroupTags } } }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = @($ArgumentList) -join ' '
            if ($joined -like 'vm show *') {
                return (New-AzResult -StdOut "archost01`n")
            }
            if ($joined -like 'deployment operation *') {
                return (New-AzResult -StdOut '[]')
            }
            if ($joined -like 'postgres flexible-server list-skus *') {
                if (@($script:zones).Count -eq 0 -and $script:skuZones.Count -eq 0) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: not faked')
                }
                $listed = @{ Standard_D4ds_v5 = @($script:zones) }
                foreach ($key in $script:skuZones.Keys) {
                    $listed[$key] = @($script:skuZones[$key])
                }
                $editions = foreach ($edition in 'Burstable', 'GeneralPurpose') {
                    @{ name = $edition; supportedServerSkus = @(foreach ($key in $listed.Keys) { if (($edition -eq 'Burstable') -eq ($key -like 'Standard_B*')) { @{ name = $key; supportedZones = @($listed[$key]) } } }) }
                }
                return (New-AzResult -StdOut (ConvertTo-Json -Depth 10 -InputObject @(@{ name = 'westus3'; supportedServerEditions = @($editions) })))
            }
            if ($joined -like 'deployment sub create *') {
                $file = [string]$ArgumentList[[array]::IndexOf([string[]]@($ArgumentList), '--parameters') + 1]
                $script:deployCalls.Add((Get-Content -LiteralPath $file.Substring(1) -Raw | ConvertFrom-Json -AsHashtable))
                if ($script:createsServer -and $script:currentSize -ceq $script:createsServer -and $null -eq $script:server) {
                    $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = $script:currentSize } }
                }
                if ($script:freeOfferFails -and $script:deployCalls[-1]['parameters']['t3UseFreeLimit']['value']) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (ProvisioningDisabled) Cannot update paid database to free database.')
                }
                # Azure refuses a size only when it creates the server; an existing one isn't created again.
                $code = [string]$script:codes[$script:currentSize]
                if ($code -and ($null -eq $script:server -or $script:refusesExisting)) {
                    return (New-AzResult -ExitCode 1 -StdErr ('ERROR: {{"status":"Failed","error":{{"code":"DeploymentFailed","message":"At least one resource deployment operation failed.","details":[{{"code":"{0}","message":"A fake error."}}]}}}}' -f $code))
                }
                $other = [string]$script:elsewhere[$script:currentSize]
                if ($other) {
                    return (New-AzResult -ExitCode 1 -StdErr ('ERROR: {{"status":"Failed","error":{{"code":"DeploymentFailed","message":"At least one resource deployment operation failed.","details":[{{"code":"{0}","message":"A fake error in another resource."}}]}}}}' -f $other))
                }
                return (New-AzResult -StdOut '{"properties":{"provisioningState":"Succeeded","duration":"PT3M","outputs":{"resourceGroupName":{"value":"rg-dbhub-demo"}}}}')
            }
            throw ('unexpected Azure CLI call: {0}' -f $joined)
        }
    }

    function Invoke-TestTemplate([System.Collections.IDictionary] $Config, [string] $T4StartSku = '') {
        Invoke-DemoTemplateDeployment -Config $Config -NetworkMode private -T3UseFreeLimit $false -T4StartSku $T4StartSku
    }

    function Resolve-TestConfig([System.Collections.IDictionary] $Config, [string] $Record, [switch] $TemplateRuns, [string] $Refused = '') {
        InModuleScope DbHubDemo -Parameters @{ Config = $Config; Record = $Record; TemplateRuns = [bool]$TemplateRuns; Refused = $Refused } { Resolve-DemoEffectiveConfig -Config $Config -State ([pscustomobject]@{ T4Sku = $Record; T4Refused = $Refused }) -TemplateRuns:$TemplateRuns }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Guardrail 1: only SkuNotAvailable is a refusal' {
    It 'reads only SkuNotAvailable in the T4 deployment''s failed operations as a refusal: <Code>' -ForEach @(
        @{ Code = 'SkuNotAvailable'; Refused = $true }
        @{ Code = 'QuotaExceeded'; Refused = $false }
        @{ Code = 'RequestDisallowedByPolicy'; Refused = $false }
        @{ Code = 'InternalServerError'; Refused = $false }
    ) {
        # The real Get-DemoT4CreateFailure, over a failed pgflex01 deployment as 'az deployment group show' and 'az deployment
        # operation group list' print it: the code is in the server's operation, not in the deployment's own error.
        $script:operationCode = $Code
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $joined = @($ArgumentList) -join ' '
            if ($joined -like 'deployment group show *') {
                return (New-AzResult -StdOut (ConvertTo-Json -Depth 20 -InputObject @{ name = 'pgflex01'; properties = @{ provisioningState = 'Failed'; timestamp = '2026-11-02T14:00:00Z'; parameters = @{ sizing = @{ value = @{ skuName = 'Standard_D4ads_v5'; tier = 'Burstable' } }; availabilityZone = @{ value = '' } }; error = @{ code = 'DeploymentFailed'; details = @(@{ code = 'ResourceDeploymentFailure' }) } } }))
            }
            if ($joined -like 'deployment operation group list *') {
                return (New-AzResult -StdOut (ConvertTo-Json -Depth 20 -InputObject @(@{ properties = @{ provisioningState = 'Failed'; statusMessage = @{ status = 'Failed'; error = @{ code = $script:operationCode; message = 'A fake error.' } } } })))
            }
            throw ('unexpected Azure CLI call: {0}' -f $joined)
        }
        $failure = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4CreateFailure -Config $Config }
        if ($Refused) {
            $failure.Sku | Should -Be 'Standard_D4ads_v5'
        }
        else {
            $failure | Should -BeNullOrEmpty
        }
    }
}

Describe 'Guardrail 1: only SkuNotAvailable for both 4-vCore sizes moves T4 to its 2-vCore size' {
    BeforeEach {
        Initialize-TemplateHarness
    }

    It 'moves from Standard_D4ds_v5 to Standard_D4ads_v5, then to General Purpose Standard_D2ds_v5 after its cost check, when Azure refuses both with SkuNotAvailable' {
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        # The cost check ran once, right before the General Purpose attempt, with this run's network mode and free offer, and
        # the size change's notice priced the default once, for the difference (2026-11-09).
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') -and $Config['t4SkuName'] -eq 'Standard_D2ds_v5' -and $NetworkMode -eq 'private' -and $T3UseFreeLimit -eq $false }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['SkuName'] -eq 'Standard_D4ds_v5' }
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK').status | Should -Be 'Warning'
        $steps = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        @($steps.status) | Should -Be @('Warning', 'Warning')
        $steps[0].evidence.next | Should -Be 'Standard_D4ads_v5'
        $steps[1].evidence.next | Should -Be 'Standard_D2ds_v5'
        $steps[1].evidence.refusedSku | Should -Be 'Standard_D4ads_v5'
        $steps[1].evidence.fallbackTier | Should -Be 'GeneralPurpose'
        $steps[1].message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').evidence.t4Fallback | Should -Be 'Standard_D2ds_v5'
    }

    It 'keeps today''s behavior for <Name> of Standard_D4ds_v5: no other size, no cost check, no record, and a DEPLOY.TEMPLATE Fail' -ForEach @(
        @{ Name = 'a quota refusal'; Code = 'QuotaExceeded' }
        @{ Name = 'a policy denial'; Code = 'RequestDisallowedByPolicy' }
        @{ Name = 'a transient error'; Code = 'InternalServerError' }
    ) {
        $script:codes = @{ Standard_D4ds_v5 = $Code }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        $script:recorded.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').status | Should -Be 'Fail'
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
    }

    It 'stops at Standard_D4ads_v5 for <Name>, after a SkuNotAvailable for Standard_D4ds_v5: no General Purpose attempt and no cost check' -ForEach @(
        @{ Name = 'a quota refusal'; Code = 'QuotaExceeded' }
        @{ Name = 'a policy denial'; Code = 'RequestDisallowedByPolicy' }
        @{ Name = 'a transient error'; Code = 'InternalServerError' }
    ) {
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = $Code }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5')
        @($script:recorded) | Should -Be @('Standard_D4ads_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').status | Should -Be 'Fail'
    }


    It 'finishes without T4 when Azure refuses Standard_D2ds_v5 too: a DEPLOY.T4.SKU Fail, NOT DONE with the fix, and no record, so every run tries the sizes again (2026-11-09)' {
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable'; Standard_D2ds_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue -Because 'the rest of the demo is deployed without T4'
        $deployment.T4Enabled | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'none')
        # The size the fallback was trying is cleared: no "no T4" record stays.
        @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5', '')
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -BeNullOrEmpty
        $refused = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')[-1]
        $refused.status | Should -Be 'Fail'
        $refused.evidence.next | Should -Be 'Refused'
        $refused.message | Should -Match 'T4 is part of every deployment, so this run deploys the rest and ends NOT DONE'
        $refused.message | Should -Match 'every run tries the sizes again'
        $refused.remediation | Should -Match 'Region access request'
        $refused.remediation | Should -Match 't4SkuName'
        $refused.remediation | Should -Not -Match 't4Enabled'
        # DONE says T4 is missing, with the fix (DEPLOY.T4.OFF, a Fail).
        $off = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Result = $deployment.Results } { New-DemoT4OffResult -Config $Config -State ([pscustomobject]@{ T4Sku = '' }) -Result $Result }
        $off.checkId | Should -Be 'DEPLOY.T4.OFF'
        $off.status | Should -Be 'Fail'
        $off.message | Should -Match '^T4 \(Azure Database for PostgreSQL\) isn''t deployed, and DONE needs it: Azure refused every size'
        $off.message | Should -Match 'Region access request'
        # A Refused record an earlier run wrote never turns T4 off: a run that deploys the template starts from the default
        # size again, because Azure's regional capacity changes, and a run that doesn't (a resume) keeps T4 on.
        $resolved = Resolve-TestConfig -Config (New-TestConfig) -Record 'Refused' -TemplateRuns
        $resolved['t4Enabled'] | Should -BeTrue
        $resolved['t4SkuSource'] | Should -Be 'retry'
        $resolved['t4SkuName'] | Should -Be 'Standard_D4ds_v5'
        $resumed = Resolve-TestConfig -Config (New-TestConfig) -Record 'Refused'
        $resumed['t4Enabled'] | Should -BeTrue
        $resumed.Contains('t4SkuSource') | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'Refused' }) } | Should -BeNullOrEmpty
    }

    It 'falls back for a t4SkuName Azure refuses too (2026-11-09), and a record no longer holds once t4SkuName names another size (review finding 5)' {
        # A 4-vCore size's peer comes first (the whole order is in its own Describe below).
        $script:codes = @{ Standard_D4ads_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_D4ads_v5')
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ads_v5', 'Standard_D4ds_v5')
        $deployment.T4SkuName | Should -Be 'Standard_D4ds_v5'
        @($script:recorded) | Should -Be @('Standard_D4ds_v5')
        @($deployment.Results | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.SKU' -and [string]$_.status -eq 'Fail' }) | Should -BeNullOrEmpty

        # A record for another size, preflight's start, and an existing server's own size don't hold for a size you set.
        $script:codes = @{}
        $script:recorded.Clear()
        $script:pricedSizes.Clear()
        $script:sizes.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_D2ds_v5' }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_D4ds_v5') -T4StartSku 'Standard_D2ds_v5'
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
        # Its record no longer holds (review finding 5).
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be ''
        $script:pricedSizes.Count | Should -Be 0 -Because 'an existing server isn''t priced for a fallback'
        (Resolve-TestConfig -Config (New-TestConfig -SkuName 'Standard_D4ds_v5') -Record 'Standard_D2ds_v5' -TemplateRuns)['t4SkuName'] | Should -Be 'Standard_D4ds_v5'
    }

    It 'sends no T4 when this run''s configuration has t4Enabled false in memory (Get-DemoConfig never gives that since 2026-11-09): no attempt, no cost check, and no record, whatever an earlier run recorded; DONE says T4 is missing' {
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'None' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -Off) -T4StartSku 'Standard_D2ds_v5'
        $deployment.Succeeded | Should -BeTrue
        $deployment.T4Enabled | Should -BeFalse
        @($script:sizes) | Should -Be @('none')
        $script:recorded.Count | Should -Be 0
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4State -Times 0 -Exactly
        foreach ($record in 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'None', 'Refused') {
            (Resolve-TestConfig -Config (New-TestConfig -Off) -Record $record -TemplateRuns)['t4Enabled'] | Should -BeFalse -Because $record
        }
        # T4 is part of every deployment, so DONE needs it and says how to get it, never that it's off on purpose.
        $offReason = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Off) } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5' }) }
        $offReason | Should -Be 'T4 (Azure Database for PostgreSQL) isn''t deployed in this run, and DONE needs it. Run ./scripts/deploy.ps1 again: it deploys the template, which creates T4, after preflight checks its cost.'
        $offReason | Should -Not -Match 't4Enabled' -Because 'the configuration can''t turn T4 off (2026-11-09)'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Off) } { Get-DemoT4FallbackNote -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5' }) -HourlyUsd 0.5 } | Should -BeNullOrEmpty
    }
}

Describe 'Guardrail 2: priced from the Retail Prices API before anything is created, and created anyway over a ceiling, with a Warning (2026-11-09)' {
    It 'allows the fallback only with a compute price, the worst-case month within monthlyCeilingUsd, and a session within sessionCeilingUsd' {
        $verdict = { param($Estimate, $Config) InModuleScope DbHubDemo -Parameters @{ Estimate = $Estimate; Config = $Config } { ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $Config } }
        # Its numbers are set against a 250 USD ceiling (the default is 375 since 2026-11-04).
        function New-TestConfig { $c = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json'); $c['monthlyCeilingUsd'] = 250; $c }
        $within = & $verdict (New-TestEstimate) (New-TestConfig)
        $within.Allowed | Should -BeTrue
        $within.SkipReason | Should -Be ''
        $within.HourlyUsd | Should -Be 0.5 -Because '2 vCores at the fake vCore price'
        # The worst case is every hour of a month (Azure starts a stopped server again after 7 days): the light-use month
        # plus the rest of the month's compute, as PREFLIGHT.COST.MONTHLY counts it; T4 alone adds its fixed costs.
        $within.MonthlyWorstCaseUsd | Should -Be 220.0
        $within.T4MonthlyWorstCaseUsd | Should -Be (20.0 + 0.5 * 730)
        $within.SessionUsd | Should -Be 8.0
        $within.MonthlyCeilingUsd | Should -Be 250
        $within.SessionCeilingUsd | Should -Be 15

        $month = & $verdict (New-TestEstimate -LightUse 200) (New-TestConfig)
        $month.Allowed | Should -BeFalse
        $month.SkipReason | Should -Be 'MonthlyCeiling'
        $month.MonthlyWorstCaseUsd | Should -Be 320.0
        $raised = New-TestConfig
        $raised['monthlyCeilingUsd'] = 400
        (& $verdict (New-TestEstimate -LightUse 200) $raised).Allowed | Should -BeTrue -Because 'a ceiling raised on purpose allows it'

        (& $verdict (New-TestEstimate -Session 16.2) (New-TestConfig)).SkipReason | Should -Be 'SessionCeiling'
        (& $verdict (New-TestEstimate -NoCompute) (New-TestConfig)).SkipReason | Should -Be 'Price'
        (& $verdict $null (New-TestConfig)).SkipReason | Should -Be 'Price'
    }

    It 'names what the Retail Prices API had no price for, and Defender for Cloud when its plans weren''t read, instead of guessing' {
        $cost = InModuleScope DbHubDemo -Parameters @{ Estimate = (New-TestEstimate -NoDefender -Missing @('Defender CSPM (T4 server)')); Config = (New-TestConfig) } { ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $Config }
        $cost.Allowed | Should -BeTrue
        @($cost.Unpriced) | Should -Be @('Defender CSPM (T4 server)', 'Microsoft Defender for Cloud (the subscription''s plans weren''t read)')
        $text = InModuleScope DbHubDemo -Parameters @{ Cost = $cost } { Format-DemoT4FallbackCostText -Cost $Cost }
        $text | Should -Match 'about 0\.500 USD an hour while it runs \(list price in westus3, Azure Retail Prices API, read now\)'
        $text | Should -Match 'Not priced, so left out of these totals: Defender CSPM \(T4 server\); Microsoft Defender for Cloud'
    }

    It 'creates T4 anyway as Standard_D2ds_v5, with a Warning that says why and how to keep the month within the ceilings, when <Name> (2026-11-09)' -ForEach @(
        @{ Name = 'the worst-case month is over monthlyCeilingUsd'; Reason = 'MonthlyCeiling'; Because = 'brings the demo''s month to 600\.00 USD, over monthlyCeilingUsd \(250\.00 USD\)'; Fix = '^To keep the month within your ceilings, raise monthlyCeilingUsd to at least 600 in your configuration \(the budget follows it\), and stop T4 between sessions with \./scripts/stop-demo\.ps1\.$' }
        @{ Name = 'a session is over sessionCeilingUsd'; Reason = 'SessionCeiling'; Because = 'a session is estimated at 16\.20 USD, over sessionCeilingUsd \(15\.00 USD\)'; Fix = '^To keep the month within your ceilings, raise sessionCeilingUsd to at least 17 in your configuration, and stop T4 between sessions with \./scripts/stop-demo\.ps1\.$' }
        @{ Name = 'its price can''t be read'; Reason = 'Price'; Because = 'its price couldn''t be read from the Azure Retail Prices API'; Fix = '^Nothing to do: T4 is created; \./scripts/estimate-cost\.ps1 prices it once the Azure Retail Prices API answers\.$' }
    ) {
        Initialize-TemplateHarness
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
        $script:cost = switch ($Reason) {
            'MonthlyCeiling' { New-TestCost -SkipReason $Reason -MonthlyWorstCaseUsd 600 }
            'SessionCeiling' { New-TestCost -SkipReason $Reason -SessionUsd 16.2 }
            default { New-TestCost -SkipReason $Reason -HourlyUsd $null }
        }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5') -Because 'T4 is part of every deployment, so a cost check that doesn''t pass never leaves it out'
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5')
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        $skip = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')[-1]
        $skip.status | Should -Be 'Warning'
        $skip.evidence.next | Should -Be 'None'
        $skip.evidence.startSku | Should -Be 'Standard_D2ds_v5' -Because 'no step leaves T4 out, so a later run starts at the size, never at None (2026-11-09)'
        $skip.evidence.skipReason | Should -Be $Reason
        $skip.message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5 \(2 vCores, 8 GiB\), with autonomous tuning off, although its cost check doesn''t pass: '
        $skip.message | Should -Match $Because
        $skip.message | Should -Match 'T4 is part of every deployment, so a ceiling never leaves it out\. Later runs keep this size\.'
        $skip.remediation | Should -Match $Fix
        $skip.remediation | Should -Not -Match 't4Enabled'
        $deployment.T4Note | Should -Match '^T4 was created as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, T4''s default size, because Azure refused Standard_D4ds_v5 \(no zone preference\), then Standard_D4ads_v5 \(no zone preference\) with SkuNotAvailable\.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'although its cost check doesn''t pass' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Message -match '^T4 isn''t created' }
        # DONE has no missing T4 to explain: it's deployed, and this run's Warning says what it costs.
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Result = $deployment.Results } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5' }) -Result $Result } | Should -BeNullOrEmpty
    }

    It 'checks the cost again right before every General Purpose creation: one preflight started, one only on record, and one after an earlier run''s "no T4" record (2026-11-09)' {
        Initialize-TemplateHarness
        $script:cost = New-TestCost -SkipReason 'MonthlyCeiling' -MonthlyWorstCaseUsd 600
        $deployment = Invoke-TestTemplate -Config (New-TestConfig) -T4StartSku 'Standard_D2ds_v5'
        @($script:sizes) | Should -Be @('Standard_D2ds_v5') -Because 'over a ceiling, it''s a Warning, and T4 is created anyway (2026-11-09)'
        $deployment.T4Enabled | Should -BeTrue
        @($script:recorded) | Should -Be @('Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }

        # A record of Standard_D2ds_v5 for a server that doesn't exist (a run that stopped before the template finished).
        $script:cost = New-TestCost
        $script:sizes.Clear()
        $script:recorded.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_D2ds_v5' }
        Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_D2ds_v5' -TemplateRuns) | Out-Null
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 2 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        $script:recorded.Count | Should -Be 0 -Because 'the group already records it'

        # An earlier run's "no T4" record (DbHubT4Size None) makes the next run that deploys the template try T4's sizes
        # again from the default (DEPLOY.T4.RETRY), and the cost check comes again right before General Purpose. Without
        # -TemplateRuns, the configuration stays as it is, with T4 on.
        $script:sizes.Clear()
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'None' }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'None' -TemplateRuns)
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 3 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        $retry = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.RETRY')
        $retry.Count | Should -Be 1
        $retry[0].status | Should -Be 'Warning'
        $retry[0].message | Should -Match '^An earlier run left T4 out \(DbHubT4Size None\)\. T4 is part of every deployment, so this run tries its sizes again: Standard_D4ds_v5, '
        $retry[0].remediation | Should -Be 'Nothing to do. To choose T4''s size yourself, set t4SkuName.'
        $resumed = Resolve-TestConfig -Config (New-TestConfig) -Record 'None'
        $resumed['t4Enabled'] | Should -BeTrue
        $resumed.Contains('t4SkuSource') | Should -BeFalse
    }

    It 'checks the cost again without the T3 free offer''s allowance after Azure rejects the free offer, only while T4''s server doesn''t exist: <Name>' -ForEach @(
        @{ Name = 'the rejected attempt didn''t create it (review of 20e855c)'; Creates = $false }
        @{ Name = 'the rejected attempt created it, so it exists and bills (review of 64c28b2)'; Creates = $true }
    ) {
        Initialize-TemplateHarness
        $script:freeOfferFails = $true
        # T4's server depends only on the network, so the attempt that Azure fails for the free offer can still create it.
        $script:createsServer = $(if ($Creates) { 'Standard_D2ds_v5' } else { '' })
        # Within the ceilings only with the free offer's allowance.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith { if ($T3UseFreeLimit) { New-TestCost } else { New-TestCost -SkipReason 'MonthlyCeiling' -MonthlyWorstCaseUsd 260 } }
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $true -T4StartSku 'Standard_D2ds_v5'
        $deployment.Succeeded | Should -BeTrue
        $deployment.T3UseFreeLimit | Should -BeFalse
        $sku = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        $sku.Count | Should -Be 1 -Because 'one DEPLOY.T4.SKU says what this run did about T4''s size'
        if (-not $Creates) {
            $deployment.T4Enabled | Should -BeTrue -Because 'without the free offer the worst case is over monthlyCeilingUsd: a Warning, never T4 left out (2026-11-09)'
            $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
            @($script:sizes) | Should -Be @('Standard_D2ds_v5', 'Standard_D2ds_v5')
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 2 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') -and $T3UseFreeLimit -eq $false }
            $sku[0].status | Should -Be 'Warning'
            $sku[0].evidence.next | Should -Be 'None' -Because 'the second check''s result replaces the first one'
            $sku[0].evidence.skipReason | Should -Be 'MonthlyCeiling'
            $sku[0].message | Should -Match 'although its cost check doesn''t pass'
            @($script:recorded) | Should -Be @('Standard_D2ds_v5') -Because 'the second check keeps the size the group already records'
            $deployment.T4Note | Should -Match '^T4 was created as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, T4''s default size, because Standard_D4ds_v5 was unavailable here \(found by preflight or an earlier run\)\.'
            return
        }
        # The server exists, so it's kept as it is: no second check, never "None", and the next attempt deploys it as the
        # existing server it is.
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        @($script:sizes) | Should -Be @('Standard_D2ds_v5', 'Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') -and $T3UseFreeLimit -eq $false }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T4Exists }
        @($script:recorded) | Should -Be @('Standard_D2ds_v5')
        $script:recorded | Should -Not -Contain 'None'
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'Standard_D2ds_v5'
        $sku[0].evidence.next | Should -Be 'Standard_D2ds_v5'
        $sku[0].evidence.freeOfferCounted | Should -BeTrue
        $sku[0].message | Should -Match 'Azure then rejected the T3 free offer, whose allowance this check counted, but that attempt had already created T4''s server, so it isn''t priced again'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').evidence.t4Fallback | Should -Be 'Standard_D2ds_v5'
        $deployment.T4Note | Should -Match '^T4 was created as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, T4''s default size, because Standard_D4ds_v5 was unavailable here'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match '^T4''s server exists after this failed attempt .+ it''s kept at Standard_D2ds_v5' }
        # DONE, with the record the group now has: T4 created, never "wasn't created".
        $state = New-TestState -T4Sku ([string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size']) -TrackT4 ''
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $state; Result = $deployment.Results } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -T4HourlyUsd 0.5 }
        $note = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
        $note.Count | Should -Be 1
        $note[0] | Should -Match '^T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.500 USD an hour while running'
        ($outcome.Notes -join ' ') | Should -Not -Match 'wasn''t created|isn''t deployed'
    }

    It 'prices the fallback with the run''s network mode, free offer, Defender plans, and snapshots, and never throws' {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDefenderPlan -MockWith { @([pscustomobject]@{ name = 'OpenSourceRelationalDatabases'; pricingTier = 'Standard'; subPlan = $null }, [pscustomobject]@{ name = 'CloudPosture'; pricingTier = 'Standard'; subPlan = $null }) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { New-TestEstimate }
        $cost = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode private -T3UseFreeLimit $false }
        $cost.Allowed | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -Times 1 -Exactly -ParameterFilter {
            $Config['t4SkuName'] -eq 'Standard_D2ds_v5' -and $Config['t4SkuSource'] -eq 'fallback' -and $NetworkMode -eq 'private' -and $T3UseFreeLimit -eq $false -and @($DefenderPlans).Count -eq 2
        }

        Mock -ModuleName DbHubDemo -CommandName Get-DemoCostEstimate -MockWith { throw 'The Retail Prices API is unreachable.' }
        $offline = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4GeneralPurposeCost -Config $Config -NetworkMode private -T3UseFreeLimit $false }
        $offline.Allowed | Should -BeFalse
        $offline.SkipReason | Should -Be 'Price'
        $offline.PriceError | Should -Match 'unreachable'
    }
}

Describe 'Guardrail 3: the console, DONE, and the status page say it, with the hourly price from the API' {
    BeforeEach {
        Initialize-TemplateHarness
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
    }

    It 'logs a console line and returns it for the status page''s Infrastructure step, with what was tried, what was deployed, and both estimates: <Light> USD at light use (2026-11-09)' -ForEach @(
        @{ Light = 25.0; Text = '25.00 USD and 385.00 USD, so 35.00 USD less a month at light use and 315.00 USD less in the worst case' }
        @{ Light = 75.0; Text = '75.00 USD and 385.00 USD, so 15.00 USD more a month at light use and 315.00 USD less in the worst case' }
    ) {
        $script:cost = New-TestCost -T4LightUseMonthlyUsd $Light
        $script:costBySize = @{ Standard_D4ds_v5 = (New-TestCost -SkuName 'Standard_D4ds_v5' -HourlyUsd 1.0 -T4LightUseMonthlyUsd 60.0 -T4MonthlyWorstCaseUsd 700.0) }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $script:line = [string]$deployment.T4Note
        $script:line | Should -Match '^T4 was created as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, T4''s default size, because Azure refused Standard_D4ds_v5 \(no zone preference\), then Standard_D4ads_v5 \(no zone preference\) with SkuNotAvailable\. '
        $script:line | Should -Match ('Estimated monthly cost of T4 alone \(list prices in westus3, Azure Retail Prices API, read now; estimates\): Standard_D4ds_v5 60\.00 USD at light use and 700\.00 USD in the worst case; Standard_D2ds_v5 {0}, which counts Azure starting a stopped T4 again on its own after 7 days\.' -f [regex]::Escape($Text))
        $script:line | Should -Match 'Autonomous tuning is off at this size: it needs a General Purpose size with at least 4 vCores\.$'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq $script:line }
        $change = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK')
        $change.Count | Should -Be 1
        $change[0].status | Should -Be 'Warning'
        $change[0].message | Should -Be $script:line
        $change[0].evidence.askedSku | Should -Be 'Standard_D4ds_v5'
        $change[0].evidence.deployedSku | Should -Be 'Standard_D2ds_v5'
        @($change[0].evidence.refused | ForEach-Object { $_.sku }) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5')
        $change[0].evidence.asked.t4LightUseMonthlyUsd | Should -Be 60.0
        $change[0].evidence.deployed.t4LightUseMonthlyUsd | Should -Be $Light
        $change[0].evidence.lightUseDifferenceUsd | Should -Be ([System.Math]::Round($Light - 60.0, 2))
        $change[0].evidence.worstCaseDifferenceUsd | Should -Be (-315.0)
        $change[0].remediation | Should -Match '^Nothing to do: later runs keep T4 at Standard_D2ds_v5\. To choose another size, set t4SkuName to it'
    }

    It 'puts it in DONE and NOT DONE, with the 7-day restart and whether anything stops T4 again' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku 'Standard_D2ds_v5') } { Get-DemoDeploymentOutcome -Result @() -State $State -Config $Config -T4HourlyUsd 0.5 }
        $note = @($outcome.Notes | Where-Object { $_ -match '^T4 created as General Purpose' })
        $note.Count | Should -Be 1
        $note[0] | Should -Be 'T4 created as General Purpose Standard_D2ds_v5 (2 vCores) because Azure refused the 4-vCore sizes here, so autonomous tuning is off (it needs 4 vCores); about 0.500 USD an hour while running (list price in westus3, Azure Retail Prices API). Azure starts a stopped T4 again on its own after 7 days; the nightly safety stop stops it again within a day when it''s in place, at its T3 check or at the next auto-shutdown time, and ./scripts/stop-demo.ps1 and ./scripts/status.ps1 show the date and whether it is.'
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $lines | Should -Contain $note[0]

        # With the on-demand control too, the note says it as a condition: DONE reads no schedule, while stop-demo.ps1
        # and status.ps1 read the nightly safety stop's (ADR 0024; review of 20e855c).
        $controlled = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Control); State = (New-TestState -T4Sku 'Standard_D2ds_v5') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 -Created $true }
        $controlled | Should -Match 'Azure starts a stopped T4 again on its own after 7 days; the nightly safety stop stops it again within a day when it''s in place, at its T3 check or at the next auto-shutdown time, and \./scripts/stop-demo\.ps1 and \./scripts/status\.ps1 show the date and whether it is\.$'
        # Only for the size the fallback chose: not one you set, and not a size an existing server kept.
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -SkuName 'Standard_D2ds_v5'); State = (New-TestState -T4Sku 'Standard_D2ds_v5') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 } | Should -BeNullOrEmpty
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku 'Standard_B1ms') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 } | Should -BeNullOrEmpty
        # The fallback's 4-vCore size keeps autonomous tuning on, and says so (2026-11-04).
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku 'Standard_D4ads_v5') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 -Created $true } | Should -Match '^T4 created as General Purpose Standard_D4ads_v5 \(4 vCores\) because Azure refused Standard_D4ds_v5 here, with autonomous tuning on; about 0\.500 USD an hour'
        # No number is made up when the price can't be read.
        InModuleScope DbHubDemo { Format-DemoT4FallbackCreatedText -HourlyUsd $null -Location 'westus3' } | Should -Match 'its hourly list price couldn''t be read just now'
    }

    It 'says "created" only with evidence that the server exists (review of 20e855c): <Case>' -ForEach @(
        @{ Case = 'this run''s template created it'; Ids = @('DEPLOY.T4.SKU:Warning:Standard_D2ds_v5', 'DEPLOY.TEMPLATE:Pass'); TrackT4 = ''; Created = $true; Pattern = '^T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.500 USD an hour while running' }
        @{ Case = 'T4''s own check found it'; Ids = @('T4.SERVER:Pass'); TrackT4 = ''; Created = $true; Pattern = '^T4 created as General Purpose' }
        @{ Case = 'the T4 track finished a step'; Ids = @(); TrackT4 = 'Telemetry'; Created = $true; Pattern = '^T4 created as General Purpose' }
        # Neither of the next two says the server is missing (review of 64c28b2): T4's server depends only on the network, so
        # a template that failed for another resource can still have created it, and T4.SERVER fails when its read fails
        # too. Without a Servers - Get (the ending makes one; this pure path doesn't), it couldn't be confirmed, never
        # "created" and never "isn't created yet", whatever the T4 track's record says.
        @{ Case = 'this run''s fallback was creating it and the template failed'; Ids = @('DEPLOY.T4.SKU:Warning:Standard_D2ds_v5', 'DEPLOY.TEMPLATE:Fail'); TrackT4 = 'Telemetry'; Created = $null; Pattern = '^The fallback chose General Purpose Standard_D2ds_v5 for T4 because Azure refused the 4-vCore sizes here, so autonomous tuning is off, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\); whether the server exists couldn''t be confirmed just now, and \./scripts/status\.ps1 shows it\.$' }
        @{ Case = 'T4''s own check failed'; Ids = @('T4.SERVER:Fail'); TrackT4 = 'Telemetry'; Created = $null; Pattern = '^The fallback chose General Purpose Standard_D2ds_v5 for T4 .+; whether the server exists couldn''t be confirmed just now' }
        @{ Case = 'nothing says'; Ids = @(); TrackT4 = ''; Created = $null; Pattern = '^The fallback chose General Purpose Standard_D2ds_v5 for T4 because Azure refused the 4-vCore sizes here, so autonomous tuning is off, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\); whether the server exists couldn''t be confirmed just now, and \./scripts/status\.ps1 shows it\.$' }
    ) {
        $results = @(foreach ($id in $Ids) {
                $part = $id -split ':'
                $evidence = [ordered]@{}
                if ($part[0] -eq 'DEPLOY.TEMPLATE') {
                    $evidence['t4Enabled'] = $true
                }
                if ($part.Count -gt 2) {
                    $evidence['next'] = $part[2]
                }
                New-DemoResult -CheckId $part[0] -Area 't4' -Target 'T4' -Status $part[1] -Message 'A fake result.' -Evidence $evidence
            })
        $state = New-TestState -T4Sku 'Standard_D2ds_v5' -TrackT4 $TrackT4
        $evidence = InModuleScope DbHubDemo -Parameters @{ Result = $results; State = $state } { Get-DemoT4ServerEvidence -Result $Result -State $State }
        if ($null -eq $Created) {
            $evidence | Should -BeNullOrEmpty
        }
        else {
            $evidence | Should -Be $Created
        }
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = $state; Result = $results } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -T4HourlyUsd 0.5 }
        $note = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
        $note.Count | Should -Be 1
        $note[0] | Should -Match $Pattern
        if ($Created -ne $true) {
            $note[0] | Should -Not -Match 'T4 created as'
        }
        if ($null -eq $Created) {
            $note[0] | Should -Not -Match 'isn''t created yet'
        }
    }

    Context 'the status page' {
        BeforeEach {
            $script:out = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
            Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { }
            Mock -ModuleName DbHubDemo -CommandName Enter-DemoKeepAwake -MockWith { $true }
            Mock -ModuleName DbHubDemo -CommandName Start-DemoProgressPageWriter -MockWith { $null }
            Mock -ModuleName DbHubDemo -CommandName Open-DemoProgressPage -MockWith { 'The status page is open in your browser.' }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true } }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith { @([pscustomobject]@{ productName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; skuName = 'vCore'; meterName = 'vCore'; retailPrice = 0.375; unitOfMeasure = '1 Hour' }) }
        }

        It 'shows it with the price this run''s check read, or one read now for a later run' {
            $config = New-TestConfig
            $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            $priced = New-DemoResult -CheckId 'DEPLOY.T4.SKU' -Area 't4' -Target 'T4' -Status 'Warning' -Message 'The fallback created T4 as General Purpose.' -Evidence ([ordered]@{ next = 'Standard_D2ds_v5'; startSku = 'Standard_D2ds_v5'; hourlyUsd = 0.5 })
            Complete-DemoDeploymentRun -Run $run -Config $config -Result @($priced) -State (New-TestState -T4Sku 'Standard_D2ds_v5') | Out-Null
            $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['run']['reason'] | Should -Match 'T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.500 USD an hour while running'
            Get-Content -LiteralPath $run.PagePath -Raw | Should -Match 'T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.500 USD an hour while running'
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -Times 0 -Exactly

            $later = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            Complete-DemoDeploymentRun -Run $later -Config $config -Result @() -State (New-TestState -T4Sku 'Standard_D2ds_v5') | Out-Null
            $model = Get-Content -LiteralPath $later.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['run']['reason'] | Should -Match 'about 0\.750 USD an hour while running' -Because '2 vCores at the fake hourly vCore price, read now'
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -Times 1 -Exactly -ParameterFilter { $Filter -match 'General Purpose Ddsv5 Series Compute' -and $Filter -match "armRegionName eq 'westus3'" }
        }

        It 'says T4 isn''t created yet when Azure refuses Standard_D2ds_v5 for another reason after the fallback chose it, and a later run reads whether it exists (review of 20e855c)' {
            $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable'; Standard_D2ds_v5 = 'QuotaExceeded' }
            $config = New-TestConfig
            $deployment = Invoke-TestTemplate -Config $config
            $deployment.Succeeded | Should -BeFalse
            @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
            @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5') -Because 'the choice is kept: the next run creates it, after its own cost check'
            $deployment.T4Note | Should -BeNullOrEmpty
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Message -match 'T4 created as' }

            # deploy.ps1's ending: the group records Standard_D2ds_v5, and the T4 track never ran.
            $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $deployment.Results -State (New-TestState -T4Sku 'Standard_D2ds_v5' -TrackT4 '')
            $outcome.Kind | Should -Be 'NotDone'
            $note = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
            $note.Count | Should -Be 1
            $note[0] | Should -Match '^T4 isn''t created yet: the fallback chose General Purpose Standard_D2ds_v5 because Azure refused the 4-vCore sizes here, so autonomous tuning is off, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\), but this run''s template deployment failed \(DEPLOY\.TEMPLATE says why\)\.'
            ($outcome.Notes -join ' ') | Should -Not -Match 'T4 created as'
            $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['run']['reason'] | Should -Match 'T4 isn''t created yet'
            $model['run']['reason'] | Should -Not -Match 'T4 created as'
            Get-Content -LiteralPath $run.PagePath -Raw | Should -Not -Match 'T4 created as'

            # A later run with no results of its own: a Servers - Get decides, and says so when it can't.
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = ($null -ne $script:server); State = $script:serverState; Server = $script:server; Error = '' } }
            foreach ($case in @(
                    @{ Server = $null; State = 'NotFound'; Note = '^T4 isn''t created yet: .+, but no server exists yet: no deployment has created it\.' }
                    @{ Server = $null; State = 'Unknown'; Note = '^The fallback chose General Purpose Standard_D2ds_v5 for T4 .+; whether the server exists couldn''t be confirmed just now' }
                    @{ Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5' } }; State = 'Ready'; Note = '^T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.750 USD an hour while running' }
                )) {
                $script:server = $case.Server
                $script:serverState = $case.State
                $later = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
                $outcome = Complete-DemoDeploymentRun -Run $later -Config $config -Result @() -State (New-TestState -T4Sku 'Standard_D2ds_v5' -TrackT4 '')
                $found = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
                $found.Count | Should -Be 1
                $found[0] | Should -Match $case.Note
            }
        }

        It 'reads the server when the General Purpose attempt failed for another resource, which can still have created it (review of 64c28b2): <Name>' -ForEach @(
            @{ Name = 'that attempt created it'; Creates = $true; Pattern = '^T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\)\. Azure starts a stopped T4 again on its own after 7 days' }
            @{ Name = 'Servers - Get finds none'; Creates = $false; Pattern = '^T4 isn''t created yet: the fallback chose General Purpose Standard_D2ds_v5 because Azure refused the 4-vCore sizes here, so autonomous tuning is off, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\), but this run''s template deployment failed \(DEPLOY\.TEMPLATE says why\)\.' }
        ) {
            # Azure refuses both Burstable sizes, and the General Purpose attempt fails for another resource; T4's server
            # depends only on the network, so that attempt can still create it.
            $script:elsewhere = @{ Standard_D2ds_v5 = 'BadRequest' }
            $script:createsServer = $(if ($Creates) { 'Standard_D2ds_v5' } else { '' })
            $config = New-TestConfig
            $deployment = Invoke-TestTemplate -Config $config
            $deployment.Succeeded | Should -BeFalse
            @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
            @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5') -Because 'a server that exists is never recorded None or Refused'
            ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').status | Should -Be 'Fail'

            # deploy.ps1's ending: this run's results don't say whether the server exists, so a Servers - Get decides.
            $script:serverReads = 0
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { $script:serverReads++; [pscustomobject]@{ Exists = ($null -ne $script:server); State = $(if ($null -ne $script:server) { 'Ready' } else { 'NotFound' }); Server = $script:server; Error = '' } }
            $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $deployment.Results -State (New-TestState -T4Sku 'Standard_D2ds_v5' -TrackT4 '')
            $outcome.Kind | Should -Be 'NotDone'
            $note = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
            $note.Count | Should -Be 1
            $note[0] | Should -Match $Pattern
            $script:serverReads | Should -Be 1
            $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['run']['reason'] | Should -Match $(if ($Creates) { 'T4 created as General Purpose Standard_D2ds_v5' } else { 'T4 isn''t created yet' })
            if ($Creates) {
                $model['run']['reason'] | Should -Not -Match 'isn''t created yet'
            }
            # The template step kept the server it found after the failed attempt.
            $deployment.T4Enabled | Should -BeTrue
            $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times $(if ($Creates) { 1 } else { 0 }) -Exactly -ParameterFilter { $Message -match '^T4''s server exists after this failed attempt' }
        }

        It 'reads the server after a T4.SERVER Fail, which a read that failed gives too, instead of saying it isn''t created (review of 64c28b2): <Name>' -ForEach @(
            @{ Name = 'Servers - Get finds it'; Exists = $true; ReadState = 'Ready'; Pattern = '^T4 created as General Purpose Standard_D2ds_v5 \(2 vCores\) because Azure refused the 4-vCore sizes here, so autonomous tuning is off \(it needs 4 vCores\); about 0\.750 USD an hour while running' }
            @{ Name = 'Servers - Get fails too'; Exists = $false; ReadState = 'Unknown'; Pattern = '^The fallback chose General Purpose Standard_D2ds_v5 for T4 because Azure refused the 4-vCore sizes here, so autonomous tuning is off, about 0\.750 USD an hour while running .+; whether the server exists couldn''t be confirmed just now' }
            @{ Name = 'Servers - Get finds none'; Exists = $false; ReadState = 'NotFound'; Pattern = '^T4 isn''t created yet: .+, but no server exists yet: no deployment has created it\.' }
        ) {
            # T4's own check when its read fails: T4.SERVER Fail, "couldn't be read", as for a missing server.
            $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = $false; State = 'Unknown'; Server = $null; Error = 'A fake transient error.' } }
            $config = New-TestConfig
            $checks = @(Test-DemoT4 -Config $config -DeploymentId 'abc123')
            $failed = $checks | Where-Object checkId -EQ 'T4.SERVER'
            $failed.status | Should -Be 'Fail'
            $failed.message | Should -Be 'T4 (pgflex01-abc123) couldn''t be read: A fake transient error.'

            # deploy.ps1's ending, after a T4 track that finished before: the T4.SERVER Fail doesn't say the server is
            # missing, so a Servers - Get decides.
            $script:serverReads = 0
            $script:server = $(if ($Exists) { [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5' } } } else { $null })
            $script:serverState = $ReadState
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { $script:serverReads++; [pscustomobject]@{ Exists = ($null -ne $script:server); State = $script:serverState; Server = $script:server; Error = '' } }
            $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $checks -State (New-TestState -T4Sku 'Standard_D2ds_v5')
            $note = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
            $note.Count | Should -Be 1
            $note[0] | Should -Match $Pattern
            if ($ReadState -ne 'NotFound') {
                $note[0] | Should -Not -Match 'isn''t created yet'
            }
            $script:serverReads | Should -Be 1
        }
    }
}

Describe 'Guardrail 4: the size is recorded, and an existing server is never resized' {
    BeforeEach {
        Initialize-TemplateHarness
    }

    It 'records Standard_D2ds_v5 in DbHubT4Size and the tags the template carries, and a redeploy keeps it without trying a Burstable size' {
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
        Invoke-TestTemplate -Config (New-TestConfig) | Out-Null
        @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5')
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'Standard_D2ds_v5'
        # What Azure refused, the asked size first, with the zones tried and when (2026-11-09).
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Refused'] | Should -Be 'Standard_D4ds_v5@any;Standard_D4ads_v5@any;2026-11-02T14:00:00Z'

        # The redeploy: deploy.ps1 resolves the record, and the server exists as Standard_D2ds_v5.
        $script:sizes.Clear()
        $script:recorded.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_D2ds_v5' }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_D2ds_v5' -TemplateRuns)
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        $script:recorded.Count | Should -Be 0
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
        $deployment.T4Note | Should -BeNullOrEmpty -Because 'the console said it when it was created; DONE keeps saying it'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') } -Because 'only the run that created it checked the cost'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T4Exists }
    }

    It 'keeps an existing server''s own size, and keeps a record only while it matches that size (review of 20e855c): <Name>' -ForEach @(
        @{ Name = 'created as Standard_D2ds_v5 by a configuration that set it, now without t4SkuName'; Server = 'Standard_D2ds_v5'; Record = '' }
        @{ Name = 'created by the fallback'; Server = 'Standard_D2ds_v5'; Record = 'Standard_D2ds_v5' }
        @{ Name = 'a General Purpose server with a stale Burstable record'; Server = 'Standard_D2ds_v5'; Record = 'Standard_D4ads_v5' }
        @{ Name = 'a General Purpose server with a stale "no T4" record'; Server = 'Standard_D2ds_v5'; Record = 'None' }
        @{ Name = 'a Burstable server with a General Purpose record'; Server = 'Standard_D4ds_v5'; Record = 'Standard_D2ds_v5' }
    ) {
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = $Record }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = $Server } }
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record $Record -TemplateRuns)
        $deployment.Succeeded | Should -BeTrue -Because 'an existing server isn''t created again, so Azure has nothing to refuse'
        @($script:sizes) | Should -Be @($Server)
        $deployment.T4SkuName | Should -Be $Server
        $script:recorded.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        # Only the fallback writes a size, so a record that doesn't match the server is cleared, never set to its size.
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be $(if ($Record -ceq $Server) { $Server } else { '' })
    }

    It 'never moves a server that a failed attempt created to another size, even when Azure then answers SkuNotAvailable for its size (review of 64c28b2): <Name>' -ForEach @(
        @{ Name = 'Standard_D4ds_v5, which 64c28b2 moved on to Standard_D4ads_v5'; Start = ''; Size = 'Standard_D4ds_v5'; Record = '' }
        @{ Name = 'Standard_D4ads_v5, which 64c28b2 moved on to General Purpose Standard_D2ds_v5'; Start = 'Standard_D4ads_v5'; Size = 'Standard_D4ads_v5'; Record = 'Standard_D4ads_v5' }
    ) {
        # Azure rejects the T3 free offer in the attempt that creates T4's server (it depends only on the network), and
        # answers the next attempt's update of that server with SkuNotAvailable for its size. 64c28b2 took that for a
        # refusal of a new server and sent the next size to the existing one, a resize.
        $script:freeOfferFails = $true
        $script:createsServer = $Size
        $script:codes = @{ $Size = 'SkuNotAvailable' }
        $script:refusesExisting = $true
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $true -T4StartSku $Start
        @($script:sizes) | Should -Be @($Size, $Size) -Because 'the server that exists is never sent another size'
        $deployment.Succeeded | Should -BeFalse
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be $Size
        $script:recorded.Count | Should -Be 0
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be $Record
        @($deployment.Results | Where-Object { [string]$_.checkId -eq 'DEPLOY.T4.SKU' -and $_.evidence['refusedSku'] }).Count | Should -Be 0 -Because 'no step of the fallback followed'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T4Exists }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
    }

    It 'claims no Burstable refusal for a Standard_D2ds_v5 server that a configuration set, once t4SkuName is removed (review of 20e855c)' {
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record '' -TemplateRuns)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D2ds_v5') -Because 'its size is kept'
        $script:recorded.Count | Should -Be 0
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -BeNullOrEmpty
        $deployment.T4Note | Should -BeNullOrEmpty
        # deploy.ps1's ending reads the group's record, which stays empty: DONE says nothing about a fallback.
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku ''); Result = $deployment.Results } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -T4HourlyUsd 0.5 }
        ($outcome.Notes -join ' ') | Should -Not -Match 'refused|fallback'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku '') } { Test-DemoT4FallbackSize -Config $Config -State $State } | Should -BeFalse
    }

    It 'resolves each record for later runs: <Record> (the template runs: <TemplateRuns>)' -ForEach @(
        @{ Record = 'Standard_D4ads_v5'; TemplateRuns = $false; Sku = 'Standard_D4ads_v5'; Source = 'record' }
        @{ Record = 'Standard_D2ds_v5'; TemplateRuns = $false; Sku = 'Standard_D2ds_v5'; Source = 'record' }
        @{ Record = 'Standard_D2ds_v5'; TemplateRuns = $true; Sku = 'Standard_D2ds_v5'; Source = 'record' }
        # No record turns T4 off (2026-11-09): an earlier run's None or Refused starts the fallback again from the default
        # size when this run deploys the template, and otherwise leaves the configuration as it is.
        @{ Record = 'None'; TemplateRuns = $true; Sku = 'Standard_D4ds_v5'; Source = 'retry' }
        @{ Record = 'None'; TemplateRuns = $false; Sku = ''; Source = '' }
        @{ Record = 'Refused'; TemplateRuns = $true; Sku = 'Standard_D4ds_v5'; Source = 'retry' }
        @{ Record = 'Refused'; TemplateRuns = $false; Sku = ''; Source = '' }
    ) {
        $resolved = Resolve-TestConfig -Config (New-TestConfig) -Record $Record -TemplateRuns:$TemplateRuns
        $resolved['t4Enabled'] | Should -BeTrue -Because 'no record leaves T4 out'
        [string]$resolved['t4SkuSource'] | Should -Be $Source
        [string]$resolved['t4SkuName'] | Should -Be $Sku
        InModuleScope DbHubDemo -Parameters @{ Config = $resolved } { Test-DemoT4SkuExplicit -Config $Config } | Should -BeFalse -Because 'a resolved size is never taken for one you set'
        if ($Source) {
            # Resolved once, it stays as it is.
            (Resolve-TestConfig -Config $resolved -Record 'Standard_D4ads_v5' -TemplateRuns)['t4SkuSource'] | Should -Be $Source
        }
    }

    It 'starts the fallback at the furthest step preflight found' {
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('', 'Standard_D4ads_v5') } | Should -Be 'Standard_D4ads_v5'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Standard_D2ds_v5', 'Standard_D4ads_v5', '') } | Should -Be 'Standard_D2ds_v5'
        # No step leaves T4 out since 2026-11-09: an older run's None counts as Standard_D2ds_v5, and Refused as the default.
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Standard_D4ads_v5', 'None') } | Should -Be 'Standard_D2ds_v5'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Refused') } | Should -Be ''
        # A size t4SkuName sets: its own order (2026-11-09).
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Standard_B2s', '') -Order @('', 'Standard_B2s', 'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5') } | Should -Be 'Standard_B2s'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Standard_B2s') } | Should -Be '' -Because 'without t4SkuName, a Burstable size is no step of the fallback'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @() } | Should -Be ''
    }

    It 'deploys either tier from the same template: the tier follows the size, and storage, backups, and high availability are valid on both' {
        $demo = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/demo.bicep') -Raw
        $server = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/pgflex01.bicep') -Raw
        $demo | Should -Match "tier: startsWith\(t4SkuName, 'Standard_B'\) \? 'Burstable' : 'GeneralPurpose'"
        # High availability isn't supported on Burstable, so it stays off on both; no geo-redundant backup or auto-grow.
        $server | Should -Match "highAvailability: \{\s+mode: 'Disabled'"
        $server | Should -Match "geoRedundantBackup: 'Disabled'"
        $server | Should -Match "autoGrow: 'Disabled'"
        $server | Should -Match "type: 'Premium_LRS'"
        $server | Should -Not -Match 'iops' -Because 'Premium SSD''s IOPS come from its tier on both'
        $sizing = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/profiles.json') -Raw | ConvertFrom-Json -AsHashtable).profiles['lowest-cost'].t4
        $sizing['storageSizeGB'] | Should -Be 32
        $sizing['storageTier'] | Should -Be 'P4'
        $sizing['backupRetentionDays'] | Should -Be 7
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw | ConvertFrom-Json -AsHashtable
        $template.parameters['t4SkuName'].allowedValues | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B1ms', 'Standard_B2s')
        (InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_D2ds_v5' }).Tier | Should -Be 'GeneralPurpose'
    }
}

Describe 'A record that says an earlier run left T4 out never turns T4 off (2026-11-09; review of 64c28b2)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
        $script:t4Names = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Names = $script:t4Names; Exists = ($null -ne $script:server); State = $(if ($null -ne $script:server) { 'Stopped' } else { 'NotFound' }); Server = $script:server; Error = '' } }
        # T4's checks have their own tests (DbHubDemo.T4.Tests.ps1); here they only say that they ran.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT4 -MockWith { New-DemoResult -CheckId 'T4.SERVER' -Area 't4' -Target 'T4' -Status 'Pass' -Message 'T4''s own checks ran.' }
    }

    It 'runs validate.ps1''s T4 checks as usual, with the configuration as it is, whether or not a server exists: <Record>' -ForEach @(
        @{ Record = 'None' }
        @{ Record = 'Refused' }
    ) {
        # A server that a run before 64c28b2's review recorded as left out, and one an earlier run's fallback left out.
        foreach ($server in @([pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }, $null)) {
            $script:server = $server
            $context = [pscustomobject]@{ Config = (New-TestConfig); Tags = @{ deploymentId = 'abc123'; DbHubT4Size = $Record }; DeploymentId = 'abc123' }
            $results = @(InModuleScope DbHubDemo -Parameters @{ Context = $context } { Invoke-DemoValidationT4 -Context $Context })
            $results.Count | Should -Be 1
            $results[0].checkId | Should -Be 'T4.SERVER'
            $results[0].status | Should -Be 'Pass'
            $results[0].message | Should -Be 'T4''s own checks ran.' -Because 'no record says T4 is off any more'
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoT4 -Times 2 -Exactly -ParameterFilter { $IncludeMetrics -and $DeploymentId -eq 'abc123' -and $Config['t4Enabled'] -and -not $Config.Contains('t4SkuSource') }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4State -Times 0 -Exactly -Because 'T4''s own checks read the server'
    }
}

Describe 'The 4-vCore default (2026-11-04): another zone, the fallback''s sizes, autonomous tuning, and existing servers' {
    BeforeEach {
        Initialize-TemplateHarness
    }

    It 'tries Standard_D4ds_v5 once more in another zone the region lists, then Standard_D4ads_v5, and says the size and tuning it created' {
        $script:zones = @('2', '3')
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5')
        @($script:sentZones) | Should -Be @('', '2', '') -Because 'the retry goes to a listed zone, and the next size back to the configured one'
        $steps = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        @($steps.evidence.next) | Should -Be @('Zone', 'Standard_D4ads_v5')
        $steps[0].message | Should -Match 'tries it once more in zone 2, which the region''s capabilities list for it'
        $steps[1].message | Should -Match 'so autonomous tuning stays on, and later runs keep it'
        @($script:recorded) | Should -Be @('Standard_D4ads_v5')
        $deployment.T4SkuName | Should -Be 'Standard_D4ads_v5'
        # The notice names both zones tried and the size deployed; both sizes are priced for it (2026-11-09).
        $deployment.T4Note | Should -Match '^T4 was created as Standard_D4ads_v5 \(General Purpose, 4 vCores\) instead of Standard_D4ds_v5, T4''s default size, because Azure refused Standard_D4ds_v5 \(no zone preference, then zone 2\) with SkuNotAvailable\. Estimated monthly cost of T4 alone'
        $deployment.T4Note | Should -Not -Match 'Autonomous tuning is off' -Because 'both 4-vCore sizes run it'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').evidence.t4AutonomousTuning | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        @($script:pricedSizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5')
        @(($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK').evidence.refused[0].zones) | Should -Be @('any', '2')
    }

    It 'goes on to the 2-vCore size with autonomous tuning off when t4AutonomousTuning is true, after its cost check: tuning never leaves T4 out (2026-11-09)' {
        $config = New-TestConfig
        $config['t4AutonomousTuning'] = $true
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable'; Standard_D4ads_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config $config
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_D2ds_v5')
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        @($script:recorded) | Should -Be @('Standard_D4ads_v5', 'Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('SkuName') }
        $step = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')[-1]
        $step.status | Should -Be 'Warning'
        $step.evidence.next | Should -Be 'Standard_D2ds_v5'
        $step.evidence.Contains('tuningRequired') | Should -BeFalse
        @($deployment.Results | Where-Object status -EQ 'Fail') | Should -BeNullOrEmpty
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').evidence.t4AutonomousTuning | Should -BeFalse
        $deployment.T4Note | Should -Match '^T4 was created as Standard_D2ds_v5 \(General Purpose, 2 vCores\) instead of Standard_D4ds_v5, .+ Autonomous tuning is off at this size'
        # The fallback's size is a Warning that says why tuning is off; only a t4SkuName the file sets to a size that can't
        # run autonomous tuning is a Fail.
        $tuning = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4Tuning -Config $Config -SkuName 'Standard_D2ds_v5' }
        $tuning.Status | Should -Be 'Warning'
        $tuning.Enabled | Should -BeFalse
        $tuning.Message | Should -Match 'T4 is part of every deployment, so it''s created with autonomous tuning off'
        $tuning.Remediation | Should -Match 'Region access request'
        $pinned = New-TestConfig -SkuName 'Standard_D2ds_v5'
        $pinned['t4AutonomousTuning'] = $true
        (InModuleScope DbHubDemo -Parameters @{ Config = $pinned } { Get-DemoT4Tuning -Config $Config }).Status | Should -Be 'Fail'
    }

    It 'moves an existing T4 that no record keeps to the default at deploy.ps1''s run, which restarts it, and says so' {
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } }
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        $size = $deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE'
        $size.status | Should -Be 'Warning'
        $size.evidence.outcome | Should -Be 'Scale'
        $size.message | Should -Match 'so this deployment scales it to the default, General Purpose Standard_D4ds_v5 with 4 vCores and autonomous tuning \(since 2026-11-04\), which restarts it'
        $deployment.T4Note | Should -Match '^T4 scaled from Standard_B1ms to the default, General Purpose Standard_D4ds_v5, with autonomous tuning on;'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').evidence.t4Scaled | Should -Be 'Standard_B1ms'
        @($script:recorded).Count | Should -Be 0

        # Without -ScaleT4 (start-demo.ps1's T3 recreation), it keeps its size.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        @($script:sizes) | Should -Be @('Standard_B1ms')
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE').Count | Should -Be 0

        # While it isn't Ready, deploy.ps1 keeps its size this time and says when it moves.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } }
        $script:serverState = 'Stopped'
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        @($script:sizes) | Should -Be @('Standard_B1ms')
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE').evidence.outcome | Should -Be 'Waiting'

        # A size the configuration sets never changes on its own, and a size a record keeps stays.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_D2ds_v5' }
        $deployment = Invoke-DemoTemplateDeployment -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_D2ds_v5' -TemplateRuns) -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE').Count | Should -Be 0
    }

    It 'keeps an existing T4''s size, and records it, when Azure refuses the move to the default; later runs keep it' {
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } }
        $script:codes = @{ Standard_D4ds_v5 = 'SkuNotAvailable' }
        $script:refusesExisting = $true
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D4ds_v5', 'Standard_B1ms')
        @($script:recorded) | Should -Be @('Standard_B1ms')
        $refused = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE')[-1]
        $refused.evidence.outcome | Should -Be 'Refused'
        $refused.message | Should -Match '^Azure refused to scale T4 to Standard_D4ds_v5 \(SkuNotAvailable, at 2026-11-02T14:00:00Z\), so T4 keeps Standard_B1ms \(Burstable\)'
        $deployment.T4SkuName | Should -Be 'Standard_B1ms'

        # The record keeps it: the next deploy sends its own size, and the DONE note doesn't call it a fallback creation.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } }
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_B1ms' }
        Invoke-DemoTemplateDeployment -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_B1ms' -TemplateRuns) -NetworkMode private -T3UseFreeLimit $false -ScaleT4 | Out-Null
        @($script:sizes) | Should -Be @('Standard_B1ms')
        (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_B1ms')['t4SkuName'] | Should -Be 'Standard_B1ms'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Test-DemoT4FallbackSize -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_B1ms' }) } | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Test-DemoT4FallbackSize -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D4ads_v5' }) } | Should -BeTrue
    }

    It 'prices the move of an existing T4 to the default first, and keeps its size over a ceiling, naming the ceiling to raise (review of PR 20)' {
        # The reviewer's case: monthlyCeilingUsd set to 250, no t4SkuName, and no safety stop in place, so T4's 7-day restart
        # counts the rest of the month: light use plus that worst case is 312.21 USD, a Fail that -FromStage Infrastructure never ran.
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $config = New-TestConfig
        $config['monthlyCeilingUsd'] = 250
        $script:cost = New-TestCost -SkipReason 'MonthlyCeiling' -MonthlyWorstCaseUsd 312.21 -SkuName 'Standard_D4ds_v5' -RestartAssumption 'RestOfMonth'
        $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D2ds_v5') -Because 'the server keeps its size'
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['SkuName'] -eq 'Standard_D4ds_v5' -and $NetworkMode -eq 'private' -and $T3UseFreeLimit -eq $false }
        @($script:pricedSizes) | Should -Be @('Standard_D4ds_v5') -Because 'only the move is priced: the server exists, so no fallback runs'
        $size = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE')
        $size.Count | Should -Be 1
        $size[0].status | Should -Be 'Warning'
        $size[0].evidence.outcome | Should -Be 'Ceiling'
        $size[0].evidence.skipReason | Should -Be 'MonthlyCeiling'
        $size[0].message | Should -Match '^T4 exists as Standard_D2ds_v5 \(General Purpose\)\. Moving it to the default, General Purpose Standard_D4ds_v5 with autonomous tuning, would put the demo''s month at 312\.21 USD, over monthlyCeilingUsd \(250\.00 USD\), so this deployment keeps its size, and the next run that deploys the template checks again\.'
        $size[0].remediation | Should -Match 'raise monthlyCeilingUsd to at least 313 \(the budget follows it\), then run \./scripts/deploy\.ps1 -FromStage Infrastructure again\. Or put the nightly safety stop fully in place \(\./scripts/deploy\.ps1 sets it up, and an Owner runs \./scripts/grant-safety-stop\.ps1 once when deploy\.ps1 couldn''t assign its role\)'
        $size[0].remediation | Should -Match 'set t4SkuName to Standard_D2ds_v5'
        @($script:recorded).Count | Should -Be 0 -Because 'nothing is recorded, so the next run checks again'
        $deployment.T4Note | Should -Not -Match 'scaled'

        # A session over its ceiling, or no price, keeps the size too.
        foreach ($case in @(@{ Reason = 'SessionCeiling'; Match = 'would put a session at 16\.00 USD, over sessionCeilingUsd \(15\.00 USD\)'; Fix = 'raise sessionCeilingUsd to at least 16' }, @{ Reason = 'Price'; Match = 'would need a price the Azure Retail Prices API didn''t give just now \(offline\)'; Fix = 'once the Azure Retail Prices API answers' })) {
            Initialize-TemplateHarness
            $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B1ms'; tier = 'Burstable' } }
            $script:cost = New-TestCost -SkipReason $case.Reason -SessionUsd 16 -SkuName 'Standard_D4ds_v5'
            $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false -ScaleT4
            @($script:sizes) | Should -Be @('Standard_B1ms') -Because $case.Reason
            $size = $deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE'
            $size.evidence.outcome | Should -Be 'Ceiling'
            $size.message | Should -Match $case.Match
            $size.remediation | Should -Match $case.Fix
        }
    }

    It 'scales an existing T4 to the default when the move''s cost check fits both ceilings, and says the check passed' {
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $script:cost = New-TestCost -MonthlyWorstCaseUsd 137.55 -SkuName 'Standard_D4ds_v5' -RestartAssumption 'SafetyStop'
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['SkuName'] -eq 'Standard_D4ds_v5' }
        $size = $deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE'
        $size.evidence.outcome | Should -Be 'Scale'
        $size.message | Should -Match 'Its cost check passed: about 0\.500 USD an hour while it runs .* counted as about a day per restart because a safety stop is in place'
        $deployment.T4Note | Should -Match '^T4 scaled from Standard_D2ds_v5 to the default'

        # A move that doesn't raise the price isn't priced: the two 4-vCore sizes share the vCore price.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D4ads_v5'; tier = 'GeneralPurpose' } }
        Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $false -ScaleT4 | Out-Null
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        @($script:pricedSizes) | Should -BeNullOrEmpty
    }

    It 'prices a t4SkuName the configuration changed on an existing T4, then scales it or keeps its size (review of PR 20)' {
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $script:cost = New-TestCost -SkipReason 'MonthlyCeiling' -MonthlyWorstCaseUsd 312.21 -SkuName 'Standard_D4ds_v5' -RestartAssumption 'RestOfMonth'
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig -SkuName 'Standard_D4ds_v5') -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D2ds_v5') -Because 'over the ceiling, the server keeps its size'
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['SkuName'] -eq 'Standard_D4ds_v5' }
        $size = $deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE'
        $size.evidence.outcome | Should -Be 'Ceiling'
        $size.evidence.explicit | Should -BeTrue
        $size.message | Should -Match '^T4 exists as Standard_D2ds_v5 \(General Purpose\)\. Moving it to Standard_D4ds_v5, the size your configuration sets in t4SkuName, would put the demo''s month at 312\.21 USD, over monthlyCeilingUsd'
        $size.remediation | Should -Match 'raise monthlyCeilingUsd to at least 313 .* Or set t4SkuName back to Standard_D2ds_v5\.$'
        @($deployment.Results | Where-Object { $_.checkId -eq 'DEPLOY.T4.SKU' -and $_.status -eq 'Fail' }) | Should -BeNullOrEmpty

        # Within both ceilings, it scales, and says so.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $script:cost = New-TestCost -SkuName 'Standard_D4ds_v5'
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig -SkuName 'Standard_D4ds_v5') -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        $size = $deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE'
        $size.evidence.outcome | Should -Be 'Scale'
        $size.message | Should -Match '^T4 exists as Standard_D2ds_v5 \(General Purpose\), and your configuration sets t4SkuName to Standard_D4ds_v5, so this deployment scales it, which restarts it'

        # A smaller size can only lower the cost, so it isn't priced.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D4ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig -SkuName 'Standard_B1ms') -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        @($script:sizes) | Should -Be @('Standard_B1ms')
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE') | Should -BeNullOrEmpty
        @($script:pricedSizes) | Should -BeNullOrEmpty

        # Without -ScaleT4 (start-demo.ps1's T3 recreation, after its own cost check), a size the configuration sets goes as before.
        Initialize-TemplateHarness
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_D4ds_v5') | Out-Null
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        @($script:pricedSizes) | Should -BeNullOrEmpty
    }

    It 'tells a larger T4 size from a smaller one: <From> to <To>' -ForEach @(
        @{ From = 'Standard_B1ms'; To = 'Standard_B2s'; Larger = $true }
        @{ From = 'Standard_B2s'; To = 'Standard_D2ds_v5'; Larger = $true }
        @{ From = 'Standard_D2ds_v5'; To = 'Standard_D4ds_v5'; Larger = $true }
        @{ From = 'Standard_B1ms'; To = 'Standard_D4ads_v5'; Larger = $true }
        @{ From = 'Standard_D4ads_v5'; To = 'Standard_D4ds_v5'; Larger = $false }
        @{ From = 'Standard_D4ds_v5'; To = 'Standard_D2ds_v5'; Larger = $false }
        @{ From = 'Standard_D2ds_v5'; To = 'Standard_B2s'; Larger = $false }
        @{ From = 'Standard_D4ds_v5'; To = 'Standard_E4ds_v5'; Larger = $true }
    ) {
        InModuleScope DbHubDemo -Parameters @{ From = $From; To = $To } { Test-DemoT4SizeIncrease -From $From -To $To } | Should -Be $Larger
    }

    It 'drops Phase 28''s record from the group''s tags, and doesn''t read it' {
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = 'Standard_D2ds_v5' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        @($script:sizes) | Should -Be @('Standard_D4ds_v5')
        $script:deployCalls[-1].parameters.budgetTags.value.Contains('DbHubT4Sku') | Should -BeFalse
        $deployment.Succeeded | Should -BeTrue
    }
}

Describe 'A size t4SkuName sets falls back too, cheapest first, and every automatic size change says what it cost (2026-11-09, user-directed)' {
    BeforeEach {
        Initialize-TemplateHarness
        # Obviously fake estimates for T4 alone at each size (light use, worst case), never real prices (ADR 0016).
        $script:costBySize = @{
            Standard_B1ms     = (New-TestCost -SkuName 'Standard_B1ms' -HourlyUsd 0.1 -T4LightUseMonthlyUsd 10.0 -T4MonthlyWorstCaseUsd 30.0)
            Standard_B2s      = (New-TestCost -SkuName 'Standard_B2s' -HourlyUsd 0.2 -T4LightUseMonthlyUsd 40.0 -T4MonthlyWorstCaseUsd 120.0)
            Standard_D2ds_v5  = (New-TestCost -SkuName 'Standard_D2ds_v5' -HourlyUsd 0.3 -T4LightUseMonthlyUsd 50.0 -T4MonthlyWorstCaseUsd 200.0)
            Standard_D4ds_v5  = (New-TestCost -SkuName 'Standard_D4ds_v5' -HourlyUsd 0.6 -T4LightUseMonthlyUsd 90.0 -T4MonthlyWorstCaseUsd 400.0)
            Standard_D4ads_v5 = (New-TestCost -SkuName 'Standard_D4ads_v5' -HourlyUsd 0.6 -T4LightUseMonthlyUsd 90.0 -T4MonthlyWorstCaseUsd 400.0)
        }
    }

    It 'orders the fallback by tier and vCores, never a price: <Name>' -ForEach @(
        @{ Name = 'Standard_B1ms'; Pinned = 'Standard_B1ms'; Order = @('Standard_B2s', 'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5') }
        @{ Name = 'Standard_B2s'; Pinned = 'Standard_B2s'; Order = @('Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_B1ms') }
        @{ Name = 'Standard_D2ds_v5'; Pinned = 'Standard_D2ds_v5'; Order = @('Standard_D4ds_v5', 'Standard_D4ads_v5', 'Standard_B2s', 'Standard_B1ms') }
        @{ Name = 'a 4-vCore size, its peer first'; Pinned = 'Standard_D4ds_v5'; Order = @('Standard_D4ads_v5', 'Standard_D2ds_v5', 'Standard_B2s', 'Standard_B1ms') }
        @{ Name = 'the other 4-vCore size'; Pinned = 'Standard_D4ads_v5'; Order = @('Standard_D4ds_v5', 'Standard_D2ds_v5', 'Standard_B2s', 'Standard_B1ms') }
        @{ Name = 'no t4SkuName, as since 2026-11-04'; Pinned = ''; Order = @('Standard_D4ads_v5', 'Standard_D2ds_v5') }
    ) {
        $config = New-TestConfig -SkuName $Pinned
        @(InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoT4FallbackOrder -Config $Config }) | Should -Be $Order
        # A copy the fallback or a record made still knows the size t4SkuName set.
        $copy = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Copy-DemoT4Config -Config $Config -Source fallback -SkuName 'Standard_D2ds_v5' }
        InModuleScope DbHubDemo -Parameters @{ Config = $copy } { Get-DemoT4AskedSku -Config $Config } | Should -Be $(if ($Pinned) { $Pinned } else { 'Standard_D4ds_v5' })
    }

    It 'falls back from <Pinned> to <Deployed> when <Case>, on a <Run>' -ForEach @(
        @{ Case = 'Azure refuses it in both zones'; Pinned = 'Standard_B1ms'; Codes = @('Standard_B1ms'); Sizes = @('Standard_B1ms', 'Standard_B1ms', 'Standard_B2s'); Deployed = 'Standard_B2s'; Refused = 'Standard_B1ms \(no zone preference, then zone 1\)'; Costs = 'Standard_B1ms 10\.00 USD at light use and 30\.00 USD in the worst case; Standard_B2s 40\.00 USD and 120\.00 USD, so 30\.00 USD more a month at light use and 90\.00 USD more in the worst case'; Light = 30.0; Worst = 90.0; Run = 'fresh deploy'; Fresh = $true }
        @{ Case = 'Azure refuses it in both zones'; Pinned = 'Standard_B1ms'; Codes = @('Standard_B1ms'); Sizes = @('Standard_B1ms', 'Standard_B1ms', 'Standard_B2s'); Deployed = 'Standard_B2s'; Refused = 'Standard_B1ms \(no zone preference, then zone 1\)'; Costs = 'Standard_B2s 40\.00 USD and 120\.00 USD, so 30\.00 USD more'; Light = 30.0; Worst = 90.0; Run = 'resume'; Fresh = $false }
        @{ Case = 'Azure refuses it and Standard_B2s'; Pinned = 'Standard_B1ms'; Codes = @('Standard_B1ms', 'Standard_B2s'); Sizes = @('Standard_B1ms', 'Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5'); Deployed = 'Standard_D2ds_v5'; Refused = 'Standard_B1ms \(no zone preference, then zone 1\), then Standard_B2s \(no zone preference\)'; Costs = 'Standard_D2ds_v5 50\.00 USD and 200\.00 USD, so 40\.00 USD more a month at light use and 170\.00 USD more in the worst case'; Light = 40.0; Worst = 170.0; Run = 'fresh deploy'; Fresh = $true }
        @{ Case = 'Azure refuses it and Standard_B2s'; Pinned = 'Standard_B1ms'; Codes = @('Standard_B1ms', 'Standard_B2s'); Sizes = @('Standard_B1ms', 'Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5'); Deployed = 'Standard_D2ds_v5'; Refused = 'Standard_B1ms \(no zone preference, then zone 1\), then Standard_B2s \(no zone preference\)'; Costs = 'so 40\.00 USD more a month at light use'; Light = 40.0; Worst = 170.0; Run = 'resume'; Fresh = $false }
        @{ Case = 'Azure refuses a 4-vCore size, which tries its peer first'; Pinned = 'Standard_D4ds_v5'; Codes = @('Standard_D4ds_v5'); Sizes = @('Standard_D4ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5'); Deployed = 'Standard_D4ads_v5'; Refused = 'Standard_D4ds_v5 \(no zone preference, then zone 1\)'; Costs = 'so 0\.00 USD more a month at light use and 0\.00 USD more in the worst case'; Light = 0.0; Worst = 0.0; Run = 'resume'; Fresh = $false }
    ) {
        $script:codes = @{}
        foreach ($code in $Codes) {
            $script:codes[$code] = 'SkuNotAvailable'
        }
        $script:skuZones = @{ $Pinned = @('1', '2') }
        if ($Fresh) {
            # A fresh deploy: no resource group yet, so what the fallback chose goes into the tags the template carries.
            Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $false }
            $script:groupTags = @{}
        }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName $Pinned)
        $deployment.Succeeded | Should -BeTrue
        $deployment.T4Enabled | Should -BeTrue -Because 'T4 is part of every deployment, so a refused t4SkuName never leaves it out'
        $deployment.T4SkuName | Should -Be $Deployed
        @($script:sizes) | Should -Be $Sizes
        @($script:sentZones)[0..1] | Should -Be @('', '1') -Because 'the size t4SkuName sets is tried once more in another zone the region lists'
        # Each step is a Warning; none is a Fail.
        $steps = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        @($steps | Where-Object status -NE 'Warning') | Should -BeNullOrEmpty
        $steps[0].evidence.next | Should -Be 'Zone'
        $steps[0].evidence.pinnedSku | Should -Be $Pinned
        $steps[-1].evidence.next | Should -Be $Deployed
        $steps[-1].evidence.hourlyUsd | Should -Be $script:costBySize[$Deployed].HourlyUsd
        $steps[-1].message | Should -Match ('so this run creates T4 as {0} \(' -f $Deployed)
        # The notice: what was tried and refused, with the zones, what was deployed, and both estimates with the difference.
        $change = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK')
        $change.Count | Should -Be 1
        $change[0].status | Should -Be 'Warning' -Because 'DONE stays reachable'
        $change[0].message | Should -Match ('^T4 was created as {0} \(.+\) instead of {1}, the size t4SkuName sets, because Azure refused {2} with SkuNotAvailable\. ' -f $Deployed, $Pinned, $Refused)
        $change[0].message | Should -Match 'Estimated monthly cost of T4 alone \(list prices in westus3, Azure Retail Prices API, read now; estimates\): '
        $change[0].message | Should -Match $Costs
        $change[0].evidence.askedSku | Should -Be $Pinned
        $change[0].evidence.pinned | Should -BeTrue
        $change[0].evidence.deployedSku | Should -Be $Deployed
        $change[0].evidence.lightUseDifferenceUsd | Should -Be $Light
        $change[0].evidence.worstCaseDifferenceUsd | Should -Be $Worst
        $change[0].remediation | Should -Match ('^Nothing to do: later runs keep T4 at {0}, so nothing resizes or restarts it\. To choose another size, set t4SkuName to it' -f $Deployed)
        $change[0].remediation | Should -Match 'Region access request'
        $deployment.T4Note | Should -Be $change[0].message
        $script:notice = $change[0].message
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq $script:notice }
        # Each size after the asked one is priced right before it's tried, and the asked size once, for the difference.
        @($script:pricedSizes | Where-Object { $_ -ceq $Pinned }).Count | Should -Be 1
        @($script:pricedSizes | Where-Object { $_ -ceq $Deployed }).Count | Should -Be 1
        # The record, carried by the template: the size used, and what Azure refused, the asked size first.
        $carried = $script:deployCalls[-1].parameters.budgetTags.value
        $carried['DbHubT4Size'] | Should -Be $Deployed
        [string]$carried['DbHubT4Refused'] | Should -Match ('^{0}@any,1;' -f $Pinned)
        # The group gets the record at once, so a later run starts from it: on a fresh deploy, once the first attempt created
        # the group (the template creates it before anything else).
        $script:recorded[-1] | Should -Be $Deployed
        $script:recordedRefused[-1] | Should -Match ('^{0}@any,1;' -f $Pinned)

    }

    It 'ends NOT DONE with a Fail that names every size Azure refused for a t4SkuName, and records nothing' {
        $script:codes = @{}
        foreach ($size in 'Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5') {
            $script:codes[$size] = 'SkuNotAvailable'
        }
        $script:skuZones = @{ Standard_B1ms = @('1') }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_B1ms')
        $deployment.Succeeded | Should -BeTrue -Because 'the rest of the demo is deployed without T4'
        $deployment.T4Enabled | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_B1ms', 'Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5', 'none')
        $refused = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')[-1]
        $refused.status | Should -Be 'Fail'
        $refused.evidence.next | Should -Be 'Refused'
        @($refused.evidence.tried) | Should -Be @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D4ads_v5')
        $refused.message | Should -Match '^Azure refused every size T4''s fallback tries for Standard_B1ms, the size t4SkuName sets: Standard_B1ms \(no zone preference, then zone 1\), Standard_B2s \(no zone preference\), '
        $refused.message | Should -Match 'T4 is part of every deployment, so this run deploys the rest and ends NOT DONE'
        $refused.remediation | Should -Match 'Region access request'
        $refused.remediation | Should -Not -Match 't4SkuName' -Because 'every size was tried, so setting another one doesn''t help'
        $script:recorded[-1] | Should -Be ''
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -BeNullOrEmpty
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Refused'] | Should -BeNullOrEmpty
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK') | Should -BeNullOrEmpty
        $off = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -SkuName 'Standard_B1ms'); Result = $deployment.Results } { New-DemoT4OffResult -Config $Config -State ([pscustomobject]@{ T4Sku = '' }) -Result $Result }
        $off.status | Should -Be 'Fail'
        $off.message | Should -Match 'Azure refused every size'
    }

    It 'keeps a server the fallback created at its size on later runs: no resize, no restart, no refusal again, and no cost check' {
        $refusedRecord = 'Standard_B1ms@any,1;2026-11-02T14:00:00Z'
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_B2s'; DbHubT4Refused = $refusedRecord }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_B2s'; tier = 'Burstable' } }
        # Azure still refuses Standard_B1ms: a resize to it would fail the template on every run.
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable' }
        $script:refusesExisting = $true
        $pinned = New-TestConfig -SkuName 'Standard_B1ms'
        $resolved = Resolve-TestConfig -Config $pinned -Record 'Standard_B2s' -Refused $refusedRecord -TemplateRuns
        $resolved['t4SkuName'] | Should -Be 'Standard_B2s'
        $resolved['t4SkuSource'] | Should -Be 'record'
        $resolved['t4SkuPinned'] | Should -Be 'Standard_B1ms'
        foreach ($config in @($resolved, $pinned)) {
            # deploy.ps1's run (resolved, -ScaleT4) and start-demo.ps1's T3 recreation (as the file says, resolved inside).
            $script:sizes.Clear()
            $deployment = Invoke-DemoTemplateDeployment -Config $config -NetworkMode private -T3UseFreeLimit $false -ScaleT4
            $deployment.Succeeded | Should -BeTrue
            @($script:sizes) | Should -Be @('Standard_B2s')
            $deployment.T4SkuName | Should -Be 'Standard_B2s'
            @($deployment.Results | Where-Object { [string]$_.checkId -in 'DEPLOY.T4.SIZE', 'DEPLOY.T4.SKU', 'DEPLOY.T4.FALLBACK' }) | Should -BeNullOrEmpty
            $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -Be 'Standard_B2s'
            $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Refused'] | Should -Be $refusedRecord
        }
        $script:pricedSizes.Count | Should -Be 0
        $script:recorded.Count | Should -Be 0
        # DONE and status.ps1 still say T4 runs at a size the fallback chose.
        $state = New-TestState -T4Sku 'Standard_B2s' -T4Refused $refusedRecord
        InModuleScope DbHubDemo -Parameters @{ Config = $pinned; State = $state } { Test-DemoT4FallbackSize -Config $Config -State $State } | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Config = $pinned; State = $state } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.2 -Created $true } | Should -Match '^T4 runs as Burstable Standard_B2s because Azure refused Standard_B1ms, the size t4SkuName sets, here; about 0\.200 USD an hour while running'

        # Setting another size is a choice: the record no longer holds, and T4 moves to it after its cost check.
        $script:sizes.Clear()
        $script:codes = @{}
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig -SkuName 'Standard_D2ds_v5') -NetworkMode private -T3UseFreeLimit $false -ScaleT4
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SIZE').evidence.outcome | Should -Be 'Scale'
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Size'] | Should -BeNullOrEmpty
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Refused'] | Should -BeNullOrEmpty
        (Resolve-TestConfig -Config (New-TestConfig -SkuName 'Standard_D2ds_v5') -Record 'Standard_B2s' -Refused $refusedRecord -TemplateRuns)['t4SkuName'] | Should -Be 'Standard_D2ds_v5'
    }

    It 'starts a resumed run at the size its record holds, when the server wasn''t created yet, and the notice says the earlier refusal' {
        $refusedRecord = 'Standard_B1ms@any,1;2026-11-02T14:00:00Z'
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Size = 'Standard_B2s'; DbHubT4Refused = $refusedRecord }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig -SkuName 'Standard_B1ms') -Record 'Standard_B2s' -Refused $refusedRecord -TemplateRuns)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_B2s') -Because 'the size Azure refused isn''t tried again in this run'
        @($script:pricedSizes) | Should -Be @('Standard_B2s', 'Standard_B1ms')
        $notice = ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK').message
        $notice | Should -Match '^T4 was created as Standard_B2s \(Burstable, 2 vCores\) instead of Standard_B1ms, the size t4SkuName sets, because Azure refused Standard_B1ms \(no zone preference, then zone 1\) with SkuNotAvailable\.'
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Refused'] | Should -Be $refusedRecord
    }

    It 'starts where preflight found the size t4SkuName sets unavailable, and says so' {
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_B1ms') -T4StartSku 'Standard_B2s'
        @($script:sizes) | Should -Be @('Standard_B2s')
        $step = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        $step.Count | Should -Be 1
        $step[0].message | Should -Match '^Azure doesn''t offer Standard_B1ms, the size t4SkuName sets, here now \(SkuNotAvailable, on record or found by preflight\), so this run creates T4 as Standard_B2s \(Burstable, 2 vCores\)'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK').message | Should -Match 'because Standard_B1ms was unavailable here \(found by preflight or an earlier run\)\.'
        $script:recordedRefused[-1] | Should -Be 'Standard_B1ms' -Because 'the asked size comes first, so the record holds for t4SkuName Standard_B1ms'
    }

    It 'reads the record: <Value>' -ForEach @(
        @{ Value = 'Standard_B1ms@any,1;Standard_B2s@any;2026-11-02T14:00:00Z'; Asked = 'Standard_B1ms'; Count = 2; Time = '2026-11-02T14:00:00Z' }
        @{ Value = 'Standard_B1ms'; Asked = 'Standard_B1ms'; Count = 1; Time = '' }
        @{ Value = ''; Asked = ''; Count = 0; Time = '' }
        @{ Value = 'None'; Asked = ''; Count = 0; Time = '' }
    ) {
        $read = InModuleScope DbHubDemo -Parameters @{ Value = $Value } { ConvertFrom-DemoT4RefusedRecord -Value $Value }
        $read.Asked | Should -Be $Asked
        @($read.Refusals).Count | Should -Be $Count
        $read.TimeUtc | Should -Be $Time
        if ($Count -gt 0) {
            InModuleScope DbHubDemo -Parameters @{ Read = $read; Time = $Time } { ConvertTo-DemoT4RefusedRecord -Refusal $Read.Refusals -TimeUtc $Time } | Should -Be $Value
        }
    }

    Context 'the summary, the status page, and status.ps1' {
        BeforeEach {
            $script:out = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
            Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { }
            Mock -ModuleName DbHubDemo -CommandName Enter-DemoKeepAwake -MockWith { $true }
            Mock -ModuleName DbHubDemo -CommandName Start-DemoProgressPageWriter -MockWith { $null }
            Mock -ModuleName DbHubDemo -CommandName Open-DemoProgressPage -MockWith { 'The status page is open in your browser.' }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true } }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -MockWith { @() }
        }

        It 'puts the notice in DONE''s summary and on the status page, and DONE stays reachable' {
            $script:codes = @{ Standard_B1ms = 'SkuNotAvailable' }
            $config = New-TestConfig -SkuName 'Standard_B1ms'
            $deployment = Invoke-TestTemplate -Config $config
            $notice = [string]($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.FALLBACK').message
            $notice | Should -Match 'instead of Standard_B1ms'
            $state = New-TestState -T4Sku 'Standard_B2s' -T4Refused ([string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Refused'])
            # DONE: the run's Warning never blocks it.
            $outcome = InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $state; Result = $deployment.Results; Notice = $notice } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -T4Created $true -T4Notice $Notice }
            $note = @($outcome.Notes | Where-Object { $_ -match 'instead of Standard_B1ms' })
            $note.Count | Should -Be 1
            $note[0] | Should -Be ('{0} Azure starts a stopped T4 again on its own after 7 days; the nightly safety stop stops it again within a day when it''s in place, at its T3 check or at the next auto-shutdown time, and ./scripts/stop-demo.ps1 and ./scripts/status.ps1 show the date and whether it is.' -f $notice)
            @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome }) | Should -Contain $note[0]
            # The ending takes the notice from this run's results, and the status page's summary shows it whole.
            $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            $ended = Complete-DemoDeploymentRun -Run $run -Config $config -Result $deployment.Results -State $state
            @($ended.Notes | Where-Object { $_ -match [regex]::Escape($notice) }).Count | Should -Be 1
            $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['run']['reason'] | Should -Match ([regex]::Escape($notice))
            $model['run']['reason'] | Should -Match 'so 30\.00 USD more a month at light use and 90\.00 USD more in the worst case'
            Get-Content -LiteralPath $run.PagePath -Raw | Should -Match 'instead of Standard_B1ms, the size t4SkuName sets'
        }

        It 'gives status.ps1 the notice for a size an earlier run chose, with both estimates read now' {
            $refusedRecord = 'Standard_B1ms@any,1;2026-11-02T14:00:00Z'
            $state = [pscustomobject]@{ T4Sku = 'Standard_B2s'; T4Refused = $refusedRecord; NetworkMode = 'private'; T3UseFreeLimit = $false }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SizeChangeCost -MockWith { [pscustomobject]@{ Asked = $script:costBySize['Standard_B1ms']; Deployed = $script:costBySize['Standard_B2s'] } }
            $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -SkuName 'Standard_B1ms'); State = $state } { Get-DemoT4RecordedSizeChange -Config $Config -State $State }
            $result.checkId | Should -Be 'STATUS.T4.SIZE'
            $result.status | Should -Be 'Warning'
            $result.message | Should -Match '^T4 runs as Standard_B2s \(Burstable, 2 vCores\) instead of Standard_B1ms, the size t4SkuName sets: deploy\.ps1''s fallback created it at that size because Azure refused Standard_B1ms \(no zone preference, then zone 1\) with SkuNotAvailable, at 2026-11-02T14:00:00Z\.'
            $result.message | Should -Match 'Standard_B1ms 10\.00 USD at light use and 30\.00 USD in the worst case; Standard_B2s 40\.00 USD and 120\.00 USD, so 30\.00 USD more a month at light use and 90\.00 USD more in the worst case'
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4SizeChangeCost -Times 1 -Exactly -ParameterFilter { $Asked -eq 'Standard_B1ms' -and $Deployed -eq 'Standard_B2s' -and $NetworkMode -eq 'private' }
            # Nothing when T4 runs at the size the configuration asks for, or the record no longer holds.
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -SkuName 'Standard_B2s'); State = $state } { Get-DemoT4RecordedSizeChange -Config $Config -State $State } | Should -BeNullOrEmpty
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -SkuName 'Standard_D2ds_v5'); State = $state } { Get-DemoT4RecordedSizeChange -Config $Config -State $State } | Should -BeNullOrEmpty
        }
    }
}
