# T4's General Purpose fallback (Phase 28 follow-up, ADR 0019): when Azure refuses both Burstable sizes with
# SkuNotAvailable, deploy.ps1 moves T4 to General Purpose Standard_D2ds_v5 after a cost check, says so, and keeps it. One
# Describe per guardrail. Preflight's part is in DbHubDemo.Preflight.Tests.ps1, the estimate's in DbHubDemo.Cost.Tests.ps1,
# status.ps1's restart date in DbHubDemo.Lifecycle.Tests.ps1, stop-demo.ps1's in DbHubDemo.T4.Tests.ps1, and the status
# page's Infrastructure step in DbHubDemo.Tracks.Tests.ps1. Prices here are obviously fake fixtures, never real ones
# (ADR 0016), and no test reaches Azure or the Retail Prices API.
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
    function New-TestCost([string] $SkipReason = '', [object] $HourlyUsd = 0.5, [double] $MonthlyWorstCaseUsd = 220.0, [double] $SessionUsd = 8.0) {
        [pscustomobject]@{
            Allowed               = (-not $SkipReason)
            SkipReason            = $SkipReason
            SkuName               = 'Standard_D2ds_v5'
            HourlyUsd             = $HourlyUsd
            T4MonthlyWorstCaseUsd = 385.0
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

    function New-TestState([string] $T4Sku, [string] $TrackT4 = 'Telemetry') {
        [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = $TrackT4; TrackFabric = 'Fabric'; T4Sku = $T4Sku; GuidedStopUtc = ''; HostPasswordUtc = '' }
    }

    # A fake template step: Azure answers a T4 size with $script:codes[<size>] (SkuNotAvailable, or another error code)
    # and creates everything else; $script:server is an existing T4 server (Servers - Get's sku), or $null. With
    # $script:freeOfferFails, Azure rejects the T3 free offer. What each attempt sent, the tags it carried, and what the
    # fallback recorded at once are kept.
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
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRetailPriceRequest -MockWith { throw 'The unit tests make no Retail Prices API call.' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { $script:groupTags }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoExistingVmName -MockWith { @('sqlvm01', 'archost01') }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoBudgetStartDate -MockWith { '2026-11-01' }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoT1SecurityType -MockWith { [pscustomobject]@{ SecurityType = 'TrustedLaunch' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmDiskDrift -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ Exists = ($null -ne $script:server); State = $(if ($null -ne $script:server) { 'Ready' } else { 'NotFound' }); Server = $script:server } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4CreateFailure -MockWith {
            if ([string]$script:codes[$script:currentSize] -eq 'SkuNotAvailable') {
                [pscustomobject]@{ Sku = $script:currentSize; Zone = ''; TimeUtc = '2026-11-02T14:00:00Z' }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:recorded.Add([string]$Value['T4Sku']) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith { $script:cost }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -MockWith {
            $script:currentSize = if (-not $Config['t4Enabled']) { 'none' } elseif ($Config.Contains('t4SkuName') -and $Config['t4SkuName']) { [string]$Config['t4SkuName'] } else { 'Standard_B1ms' }
            $script:sizes.Add($script:currentSize)
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
            if ($joined -like 'deployment sub create *') {
                $file = [string]$ArgumentList[[array]::IndexOf([string[]]@($ArgumentList), '--parameters') + 1]
                $script:deployCalls.Add((Get-Content -LiteralPath $file.Substring(1) -Raw | ConvertFrom-Json -AsHashtable))
                if ($script:freeOfferFails -and $script:deployCalls[-1]['parameters']['t3UseFreeLimit']['value']) {
                    return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (ProvisioningDisabled) Cannot update paid database to free database.')
                }
                # Azure refuses a size only when it creates the server; an existing one isn't created again.
                $code = [string]$script:codes[$script:currentSize]
                if ($code -and $null -eq $script:server) {
                    return (New-AzResult -ExitCode 1 -StdErr ('ERROR: {{"status":"Failed","error":{{"code":"DeploymentFailed","message":"At least one resource deployment operation failed.","details":[{{"code":"{0}","message":"A fake error."}}]}}}}' -f $code))
                }
                return (New-AzResult -StdOut '{"properties":{"provisioningState":"Succeeded","duration":"PT3M","outputs":{"resourceGroupName":{"value":"rg-dbhub-demo"}}}}')
            }
            throw ('unexpected Azure CLI call: {0}' -f $joined)
        }
    }

    function Invoke-TestTemplate([System.Collections.IDictionary] $Config, [string] $T4StartSku = '') {
        Invoke-DemoTemplateDeployment -Config $Config -NetworkMode private -T3UseFreeLimit $false -T4StartSku $T4StartSku
    }

    function Resolve-TestConfig([System.Collections.IDictionary] $Config, [string] $Record, [switch] $TemplateRuns) {
        InModuleScope DbHubDemo -Parameters @{ Config = $Config; Record = $Record; TemplateRuns = [bool]$TemplateRuns } { Resolve-DemoEffectiveConfig -Config $Config -State ([pscustomobject]@{ T4Sku = $Record }) -TemplateRuns:$TemplateRuns }
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
                return (New-AzResult -StdOut (ConvertTo-Json -Depth 20 -InputObject @{ name = 'pgflex01'; properties = @{ provisioningState = 'Failed'; timestamp = '2026-11-02T14:00:00Z'; parameters = @{ sizing = @{ value = @{ skuName = 'Standard_B2s'; tier = 'Burstable' } }; availabilityZone = @{ value = '' } }; error = @{ code = 'DeploymentFailed'; details = @(@{ code = 'ResourceDeploymentFailure' }) } } }))
            }
            if ($joined -like 'deployment operation group list *') {
                return (New-AzResult -StdOut (ConvertTo-Json -Depth 20 -InputObject @(@{ properties = @{ provisioningState = 'Failed'; statusMessage = @{ status = 'Failed'; error = @{ code = $script:operationCode; message = 'A fake error.' } } } })))
            }
            throw ('unexpected Azure CLI call: {0}' -f $joined)
        }
        $failure = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4CreateFailure -Config $Config }
        if ($Refused) {
            $failure.Sku | Should -Be 'Standard_B2s'
        }
        else {
            $failure | Should -BeNullOrEmpty
        }
    }
}

Describe 'Guardrail 1: only SkuNotAvailable for both Burstable sizes moves T4 to General Purpose' {
    BeforeEach {
        Initialize-TemplateHarness
    }

    It 'moves from Standard_B1ms to Standard_B2s, then to General Purpose Standard_D2ds_v5 after its cost check, when Azure refuses both with SkuNotAvailable' {
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5')
        $deployment.T4Enabled | Should -BeTrue
        $deployment.T4SkuName | Should -Be 'Standard_D2ds_v5'
        # The cost check ran once, right before the General Purpose attempt, with this run's network mode and free offer.
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $Config['t4SkuName'] -eq 'Standard_D2ds_v5' -and $NetworkMode -eq 'private' -and $T3UseFreeLimit -eq $false }
        $steps = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        @($steps.status) | Should -Be @('Warning', 'Warning')
        $steps[0].evidence.next | Should -Be 'Standard_B2s'
        $steps[1].evidence.next | Should -Be 'Standard_D2ds_v5'
        $steps[1].evidence.refusedSku | Should -Be 'Standard_B2s'
        $steps[1].evidence.fallbackTier | Should -Be 'GeneralPurpose'
        $steps[1].message | Should -Match 'so this run creates T4 as General Purpose Standard_D2ds_v5'
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').evidence.t4Fallback | Should -Be 'GeneralPurpose'
    }

    It 'keeps today''s behavior for <Name> of Standard_B1ms: no other size, no cost check, no record, and a DEPLOY.TEMPLATE Fail' -ForEach @(
        @{ Name = 'a quota refusal'; Code = 'QuotaExceeded' }
        @{ Name = 'a policy denial'; Code = 'RequestDisallowedByPolicy' }
        @{ Name = 'a transient error'; Code = 'InternalServerError' }
    ) {
        $script:codes = @{ Standard_B1ms = $Code }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_B1ms')
        $script:recorded.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').status | Should -Be 'Fail'
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
    }

    It 'stops at Standard_B2s for <Name>, after a SkuNotAvailable for Standard_B1ms: no General Purpose attempt and no cost check' -ForEach @(
        @{ Name = 'a quota refusal'; Code = 'QuotaExceeded' }
        @{ Name = 'a policy denial'; Code = 'RequestDisallowedByPolicy' }
        @{ Name = 'a transient error'; Code = 'InternalServerError' }
    ) {
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = $Code }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_B1ms', 'Standard_B2s')
        @($script:recorded) | Should -Be @('Standard_B2s')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        ($deployment.Results | Where-Object checkId -EQ 'DEPLOY.TEMPLATE').status | Should -Be 'Fail'
    }


    It 'finishes without T4 and records Refused when Azure refuses Standard_D2ds_v5 too; later runs don''t try again on their own' {
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable'; Standard_D2ds_v5 = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue
        $deployment.T4Enabled | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5', 'none')
        @($script:recorded) | Should -Be @('Standard_B2s', 'Standard_D2ds_v5', 'Refused')
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')[-1].message | Should -Match 'later runs don''t try again on their own'
        $resolved = Resolve-TestConfig -Config (New-TestConfig) -Record 'Refused' -TemplateRuns
        $resolved['t4Enabled'] | Should -BeFalse
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'Refused' }) } | Should -Match 'Region access request'
    }

    It 'never falls back, prices, or keeps another size for a t4SkuName the configuration sets' {
        $script:codes = @{ Standard_B2s = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_B2s')
        $deployment.Succeeded | Should -BeFalse
        @($script:sizes) | Should -Be @('Standard_B2s')
        $script:recorded.Count | Should -Be 0
        $refusal = $deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU'
        $refusal.status | Should -Be 'Fail'
        $refusal.remediation | Should -Match 'A size you set is never changed on its own'

        # Nor a record, preflight's start, or an existing server's own size: a size you set is what you asked for.
        $script:codes = @{}
        $script:sizes.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = 'Standard_D2ds_v5' }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -SkuName 'Standard_B1ms') -T4StartSku 'Standard_D2ds_v5'
        @($script:sizes) | Should -Be @('Standard_B1ms')
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
        # Its record no longer holds (review finding 5).
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Sku'] | Should -Be ''
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        (Resolve-TestConfig -Config (New-TestConfig -SkuName 'Standard_B1ms') -Record 'Standard_D2ds_v5' -TemplateRuns)['t4SkuName'] | Should -Be 'Standard_B1ms'
    }

    It 'leaves T4 out entirely with t4Enabled false: no attempt, no cost check, and no record, whatever an earlier run recorded' {
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = 'None' }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig -Off) -T4StartSku 'Standard_D2ds_v5'
        $deployment.Succeeded | Should -BeTrue
        $deployment.T4Enabled | Should -BeFalse
        @($script:sizes) | Should -Be @('none')
        $script:recorded.Count | Should -Be 0
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4State -Times 0 -Exactly
        foreach ($record in 'Standard_B2s', 'Standard_D2ds_v5', 'None', 'Refused') {
            (Resolve-TestConfig -Config (New-TestConfig -Off) -Record $record -TemplateRuns)['t4Enabled'] | Should -BeFalse -Because $record
        }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Off) } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5' }) } | Should -Be 'T4 (Azure Database for PostgreSQL) isn''t deployed: t4Enabled is false in your configuration.'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Off) } { Get-DemoT4FallbackNote -Config $Config -State ([pscustomobject]@{ T4Sku = 'Standard_D2ds_v5' }) -HourlyUsd 0.5 } | Should -BeNullOrEmpty
    }
}

Describe 'Guardrail 2: priced from the Retail Prices API before anything is created, and left out over a ceiling' {
    It 'allows the fallback only with a compute price, the worst-case month within monthlyCeilingUsd, and a session within sessionCeilingUsd' {
        $verdict = { param($Estimate, $Config) InModuleScope DbHubDemo -Parameters @{ Estimate = $Estimate; Config = $Config } { ConvertTo-DemoT4FallbackCost -Estimate $Estimate -Config $Config } }
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

    It 'leaves T4 out with the note instead of creating it when <Name>' -ForEach @(
        @{ Name = 'the worst-case month is over monthlyCeilingUsd'; Reason = 'MonthlyCeiling'; Because = 'brings the demo''s month to 600\.00 USD, over monthlyCeilingUsd \(250\.00 USD\)'; Fix = 'raise monthlyCeilingUsd to at least 600' }
        @{ Name = 'a session is over sessionCeilingUsd'; Reason = 'SessionCeiling'; Because = 'a session is estimated at 16\.20 USD, over sessionCeilingUsd \(15\.00 USD\)'; Fix = 'raise sessionCeilingUsd to at least 17' }
        @{ Name = 'its price can''t be read'; Reason = 'Price'; Because = 'its price couldn''t be read from the Azure Retail Prices API'; Fix = 'prices the fallback again before it creates anything' }
    ) {
        Initialize-TemplateHarness
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable' }
        $script:cost = switch ($Reason) {
            'MonthlyCeiling' { New-TestCost -SkipReason $Reason -MonthlyWorstCaseUsd 600 }
            'SessionCeiling' { New-TestCost -SkipReason $Reason -SessionUsd 16.2 }
            default { New-TestCost -SkipReason $Reason -HourlyUsd $null }
        }
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_B1ms', 'Standard_B2s', 'none') -Because 'nothing is sent at General Purpose'
        $deployment.T4Enabled | Should -BeFalse
        @($script:recorded) | Should -Be @('Standard_B2s', 'None')
        $skip = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')[-1]
        $skip.status | Should -Be 'Warning'
        $skip.evidence.startSku | Should -Be 'None'
        $skip.evidence.skipReason | Should -Be $Reason
        $skip.message | Should -Match $Because
        $skip.remediation | Should -Match $Fix
        $deployment.T4Note | Should -Match '^T4 isn''t deployed: Azure refused its Burstable sizes here'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -match '^T4 isn''t created: ' }
        # DONE and NOT DONE say why, with this run's numbers and the fix.
        $note = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Result = $deployment.Results } { Get-DemoT4OffReason -Config $Config -State ([pscustomobject]@{ T4Sku = 'None' }) -Result $Result }
        $note | Should -Match '^T4 \(Azure Database for PostgreSQL\) isn''t deployed: Azure refused both Burstable sizes, Standard_B1ms and Standard_B2s, in westus3 \(SkuNotAvailable\), and the General Purpose fallback, Standard_D2ds_v5, wasn''t created: '
        $note | Should -Match $Because
        $note | Should -Match $Fix
    }

    It 'checks the cost again right before every General Purpose creation: one preflight started, and one only on record' {
        Initialize-TemplateHarness
        $script:cost = New-TestCost -SkipReason 'MonthlyCeiling' -MonthlyWorstCaseUsd 600
        Invoke-TestTemplate -Config (New-TestConfig) -T4StartSku 'Standard_D2ds_v5' | Out-Null
        @($script:sizes) | Should -Be @('none')
        @($script:recorded) | Should -Be @('None')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly

        # A record of Standard_D2ds_v5 for a server that doesn't exist (a run that stopped before the template finished).
        $script:cost = New-TestCost
        $script:sizes.Clear()
        $script:recorded.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = 'Standard_D2ds_v5' }
        Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_D2ds_v5' -TemplateRuns) | Out-Null
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 2 -Exactly
        $script:recorded.Count | Should -Be 0 -Because 'the group already records it'

        # A legacy "no T4" record (Phase 28) is checked again when deploy.ps1 deploys the template; without it, T4 stays off.
        $script:sizes.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = 'None' }
        Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'None' -TemplateRuns) | Out-Null
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        @($script:recorded) | Should -Be @('Standard_D2ds_v5')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 3 -Exactly
        (Resolve-TestConfig -Config (New-TestConfig) -Record 'None')['t4Enabled'] | Should -BeFalse
    }

    It 'checks the cost again without the T3 free offer''s allowance when Azure rejects the free offer before T4 is created (review of 20e855c)' {
        Initialize-TemplateHarness
        $script:freeOfferFails = $true
        # Within the ceilings only with the free offer's allowance.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -MockWith { if ($T3UseFreeLimit) { New-TestCost } else { New-TestCost -SkipReason 'MonthlyCeiling' -MonthlyWorstCaseUsd 260 } }
        $deployment = Invoke-DemoTemplateDeployment -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $true -T4StartSku 'Standard_D2ds_v5'
        $deployment.Succeeded | Should -BeTrue
        $deployment.T3UseFreeLimit | Should -BeFalse
        $deployment.T4Enabled | Should -BeFalse -Because 'without the free offer, the worst case is over monthlyCeilingUsd'
        @($script:sizes) | Should -Be @('Standard_D2ds_v5', 'none')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 2 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -ParameterFilter { $T3UseFreeLimit -eq $false }
        $sku = @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU')
        $sku.Count | Should -Be 1 -Because 'the second check''s result replaces the first one'
        $sku[0].evidence.next | Should -Be 'None'
        $sku[0].evidence.skipReason | Should -Be 'MonthlyCeiling'
        @($script:recorded) | Should -Be @('Standard_D2ds_v5', 'None')
        $deployment.T4Note | Should -Not -Match 'T4 created as'
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
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable' }
    }

    It 'logs a console line and returns it for the status page''s Infrastructure step, with the price the check read: <HourlyUsd>' -ForEach @(
        @{ HourlyUsd = 0.5; Text = '0.500' }
        @{ HourlyUsd = 0.75; Text = '0.750' }
    ) {
        $script:cost = New-TestCost -HourlyUsd $HourlyUsd
        $deployment = Invoke-TestTemplate -Config (New-TestConfig)
        $script:line = 'T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about {0} USD an hour while running (list price in westus3, Azure Retail Prices API).' -f $Text
        $deployment.T4Note | Should -Be $script:line
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq $script:line }
    }

    It 'puts it in DONE and NOT DONE, with the 7-day restart and whether anything stops T4 again' {
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku 'Standard_D2ds_v5') } { Get-DemoDeploymentOutcome -Result @() -State $State -Config $Config -T4HourlyUsd 0.5 }
        $note = @($outcome.Notes | Where-Object { $_ -match '^T4 created as General Purpose' })
        $note.Count | Should -Be 1
        $note[0] | Should -Be 'T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about 0.500 USD an hour while running (list price in westus3, Azure Retail Prices API). Azure starts a stopped T4 again on its own after 7 days, and nothing here stops it again (no daily safety stop is set up), so ./scripts/stop-demo.ps1 and ./scripts/status.ps1 show that date.'
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $lines | Should -Contain $note[0]

        # With the on-demand control, its daily safety stop stops T4 again when its schedule is in place, which
        # stop-demo.ps1 and status.ps1 read (review of 20e855c).
        $controlled = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Control); State = (New-TestState -T4Sku 'Standard_D2ds_v5') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 -Created $true }
        $controlled | Should -Match 'Azure starts a stopped T4 again on its own after 7 days; the on-demand control''s daily safety stop stops it again within a day when its schedule is in place, and \./scripts/stop-demo\.ps1 and \./scripts/status\.ps1 show the date and whether it is\.$'
        # Only for the size the fallback chose: not one you set, and not a Burstable one.
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -SkuName 'Standard_D2ds_v5'); State = (New-TestState -T4Sku 'Standard_D2ds_v5') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 } | Should -BeNullOrEmpty
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku 'Standard_B2s') } { Get-DemoT4FallbackNote -Config $Config -State $State -HourlyUsd 0.5 } | Should -BeNullOrEmpty
        # No number is made up when the price can't be read.
        InModuleScope DbHubDemo { Format-DemoT4FallbackCreatedText -HourlyUsd $null -Location 'westus3' } | Should -Match 'its hourly list price couldn''t be read just now'
    }

    It 'says "created" only with evidence that the server exists (review of 20e855c): <Case>' -ForEach @(
        @{ Case = 'this run''s template created it'; Ids = @('DEPLOY.T4.SKU:Warning:Standard_D2ds_v5', 'DEPLOY.TEMPLATE:Pass'); TrackT4 = ''; Created = $true; Pattern = '^T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about 0\.500 USD an hour while running' }
        @{ Case = 'T4''s own check found it'; Ids = @('T4.SERVER:Pass'); TrackT4 = ''; Created = $true; Pattern = '^T4 created as General Purpose' }
        @{ Case = 'the T4 track finished a step'; Ids = @(); TrackT4 = 'Telemetry'; Created = $true; Pattern = '^T4 created as General Purpose' }
        @{ Case = 'this run''s fallback was creating it and the template failed'; Ids = @('DEPLOY.T4.SKU:Warning:Standard_D2ds_v5', 'DEPLOY.TEMPLATE:Fail'); TrackT4 = 'Telemetry'; Created = $false; Pattern = '^T4 isn''t created yet: the fallback chose General Purpose Standard_D2ds_v5 because Burstable sizes were refused here, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\), but no server exists yet: no deployment has created it\. The next \./scripts/deploy\.ps1 that deploys the template creates it, after checking its price against the ceilings again\.$' }
        @{ Case = 'T4''s own check found no server'; Ids = @('T4.SERVER:Fail'); TrackT4 = 'Telemetry'; Created = $false; Pattern = '^T4 isn''t created yet: ' }
        @{ Case = 'nothing says'; Ids = @(); TrackT4 = ''; Created = $null; Pattern = '^The fallback chose General Purpose Standard_D2ds_v5 for T4 because Burstable sizes were refused here, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\); whether the server exists couldn''t be confirmed just now, and \./scripts/status\.ps1 shows it\.$' }
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
            $model['run']['reason'] | Should -Match 'T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about 0\.500 USD an hour while running'
            Get-Content -LiteralPath $run.PagePath -Raw | Should -Match 'T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about 0\.500 USD an hour while running'
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -Times 0 -Exactly

            $later = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            Complete-DemoDeploymentRun -Run $later -Config $config -Result @() -State (New-TestState -T4Sku 'Standard_D2ds_v5') | Out-Null
            $model = Get-Content -LiteralPath $later.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            $model['run']['reason'] | Should -Match 'about 0\.750 USD an hour while running' -Because '2 vCores at the fake hourly vCore price, read now'
            Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRetailPrice -Times 1 -Exactly -ParameterFilter { $Filter -match 'General Purpose Ddsv5 Series Compute' -and $Filter -match "armRegionName eq 'westus3'" }
        }

        It 'says T4 isn''t created yet when Azure refuses Standard_D2ds_v5 for another reason after the fallback chose it, and a later run reads whether it exists (review of 20e855c)' {
            $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable'; Standard_D2ds_v5 = 'QuotaExceeded' }
            $config = New-TestConfig
            $deployment = Invoke-TestTemplate -Config $config
            $deployment.Succeeded | Should -BeFalse
            @($script:sizes) | Should -Be @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5')
            @($script:recorded) | Should -Be @('Standard_B2s', 'Standard_D2ds_v5') -Because 'the choice is kept: the next run creates it, after its own cost check'
            $deployment.T4Note | Should -BeNullOrEmpty
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly -ParameterFilter { $Message -match 'T4 created as' }

            # deploy.ps1's ending: the group records Standard_D2ds_v5, and the T4 track never ran.
            $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
            $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result $deployment.Results -State (New-TestState -T4Sku 'Standard_D2ds_v5' -TrackT4 '')
            $outcome.Kind | Should -Be 'NotDone'
            $note = @($outcome.Notes | Where-Object { $_ -match 'Standard_D2ds_v5' })
            $note.Count | Should -Be 1
            $note[0] | Should -Match '^T4 isn''t created yet: the fallback chose General Purpose Standard_D2ds_v5 because Burstable sizes were refused here, about 0\.500 USD an hour while running \(list price in westus3, Azure Retail Prices API\), but this run''s template deployment failed \(DEPLOY\.TEMPLATE says why\)\.'
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
                    @{ Server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5' } }; State = 'Ready'; Note = '^T4 created as General Purpose Standard_D2ds_v5 because Burstable sizes were refused here; about 0\.750 USD an hour while running' }
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
    }
}

Describe 'Guardrail 4: the size is recorded, and an existing server is never resized' {
    BeforeEach {
        Initialize-TemplateHarness
    }

    It 'records Standard_D2ds_v5 in DbHubT4Sku and the tags the template carries, and a redeploy keeps it without trying a Burstable size' {
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable' }
        Invoke-TestTemplate -Config (New-TestConfig) | Out-Null
        @($script:recorded) | Should -Be @('Standard_B2s', 'Standard_D2ds_v5')
        $script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Sku'] | Should -Be 'Standard_D2ds_v5'

        # The redeploy: deploy.ps1 resolves the record, and the server exists as Standard_D2ds_v5.
        $script:sizes.Clear()
        $script:recorded.Clear()
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = 'Standard_D2ds_v5' }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record 'Standard_D2ds_v5' -TemplateRuns)
        @($script:sizes) | Should -Be @('Standard_D2ds_v5')
        $script:recorded.Count | Should -Be 0
        @($deployment.Results | Where-Object checkId -EQ 'DEPLOY.T4.SKU').Count | Should -Be 0
        $deployment.T4Note | Should -BeNullOrEmpty -Because 'the console said it when it was created; DONE keeps saying it'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 1 -Exactly -Because 'only the run that created it checked the cost'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoDeploymentParameter -Times 1 -Exactly -ParameterFilter { $T4Exists }
    }

    It 'keeps an existing server''s own size, and keeps a record only while it matches that size (review of 20e855c): <Name>' -ForEach @(
        @{ Name = 'created as Standard_D2ds_v5 by a configuration that set it, now without t4SkuName'; Server = 'Standard_D2ds_v5'; Record = '' }
        @{ Name = 'created by the fallback'; Server = 'Standard_D2ds_v5'; Record = 'Standard_D2ds_v5' }
        @{ Name = 'a General Purpose server with a stale Burstable record'; Server = 'Standard_D2ds_v5'; Record = 'Standard_B2s' }
        @{ Name = 'a General Purpose server with a stale "no T4" record'; Server = 'Standard_D2ds_v5'; Record = 'None' }
        @{ Name = 'a Burstable server with a General Purpose record'; Server = 'Standard_B1ms'; Record = 'Standard_D2ds_v5' }
    ) {
        $script:groupTags = @{ deploymentId = 'abc123'; DbHubT4Sku = $Record }
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = $Server } }
        $script:codes = @{ Standard_B1ms = 'SkuNotAvailable'; Standard_B2s = 'SkuNotAvailable' }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record $Record -TemplateRuns)
        $deployment.Succeeded | Should -BeTrue -Because 'an existing server isn''t created again, so Azure has nothing to refuse'
        @($script:sizes) | Should -Be @($Server)
        $deployment.T4SkuName | Should -Be $Server
        $script:recorded.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4GeneralPurposeCost -Times 0 -Exactly
        # Only the fallback writes a size, so a record that doesn't match the server is cleared, never set to its size.
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Sku'] | Should -Be $(if ($Record -ceq $Server) { $Server } else { '' })
    }

    It 'claims no Burstable refusal for a Standard_D2ds_v5 server that a configuration set, once t4SkuName is removed (review of 20e855c)' {
        $script:server = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard_D2ds_v5'; tier = 'GeneralPurpose' } }
        $deployment = Invoke-TestTemplate -Config (Resolve-TestConfig -Config (New-TestConfig) -Record '' -TemplateRuns)
        $deployment.Succeeded | Should -BeTrue
        @($script:sizes) | Should -Be @('Standard_D2ds_v5') -Because 'its size is kept'
        $script:recorded.Count | Should -Be 0
        [string]$script:deployCalls[-1].parameters.budgetTags.value['DbHubT4Sku'] | Should -BeNullOrEmpty
        $deployment.T4Note | Should -BeNullOrEmpty
        # deploy.ps1's ending reads the group's record, which stays empty: DONE says nothing about a fallback.
        $outcome = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku ''); Result = $deployment.Results } { Get-DemoDeploymentOutcome -Result $Result -State $State -Config $Config -T4HourlyUsd 0.5 }
        ($outcome.Notes -join ' ') | Should -Not -Match 'refused|fallback'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); State = (New-TestState -T4Sku '') } { Test-DemoT4FallbackSize -Config $Config -State $State } | Should -BeFalse
    }

    It 'resolves each record for later runs: <Record> (the template runs: <TemplateRuns>)' -ForEach @(
        @{ Record = 'Standard_B2s'; TemplateRuns = $false; Sku = 'Standard_B2s'; Source = 'record' }
        @{ Record = 'Standard_D2ds_v5'; TemplateRuns = $false; Sku = 'Standard_D2ds_v5'; Source = 'record' }
        @{ Record = 'Standard_D2ds_v5'; TemplateRuns = $true; Sku = 'Standard_D2ds_v5'; Source = 'record' }
        @{ Record = 'None'; TemplateRuns = $true; Sku = 'Standard_D2ds_v5'; Source = 'fallback' }
        @{ Record = 'None'; TemplateRuns = $false; Sku = ''; Source = 'record' }
        @{ Record = 'Refused'; TemplateRuns = $true; Sku = ''; Source = 'record' }
    ) {
        $resolved = Resolve-TestConfig -Config (New-TestConfig) -Record $Record -TemplateRuns:$TemplateRuns
        $resolved['t4SkuSource'] | Should -Be $Source
        if ($Sku) {
            $resolved['t4Enabled'] | Should -BeTrue
            $resolved['t4SkuName'] | Should -Be $Sku
        }
        else {
            $resolved['t4Enabled'] | Should -BeFalse
        }
        InModuleScope DbHubDemo -Parameters @{ Config = $resolved } { Test-DemoT4SkuExplicit -Config $Config } | Should -BeFalse -Because 'a resolved size is never taken for one you set'
        # Resolved once, it stays as it is.
        (Resolve-TestConfig -Config $resolved -Record 'Standard_B2s' -TemplateRuns)['t4SkuSource'] | Should -Be $Source
    }

    It 'starts the fallback at the furthest step preflight found' {
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('', 'Standard_B2s') } | Should -Be 'Standard_B2s'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Standard_D2ds_v5', 'Standard_B2s', '') } | Should -Be 'Standard_D2ds_v5'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('Standard_D2ds_v5', 'None') } | Should -Be 'None'
        InModuleScope DbHubDemo { Select-DemoT4StartSku -Sku @('None', 'Refused') } | Should -Be 'Refused'
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
        $template.parameters['t4SkuName'].allowedValues | Should -Be @('Standard_B1ms', 'Standard_B2s', 'Standard_D2ds_v5')
        (InModuleScope DbHubDemo { Get-DemoT4SkuSpec -SkuName 'Standard_D2ds_v5' }).Tier | Should -Be 'GeneralPurpose'
    }
}
