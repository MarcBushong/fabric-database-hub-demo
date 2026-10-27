BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    $examplePath = Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json'

    function New-TestConfig {
        param([hashtable] $Values)
        $base = @{
            subscriptionId       = '00000000-0000-0000-0000-000000000000'
            tenantId             = '00000000-0000-0000-0000-000000000000'
            t3AdminGroupObjectId = '00000000-0000-0000-0000-000000000000'
            ownerEmail           = 'owner@example.com'
        }
        foreach ($key in $Values.Keys) {
            $base[$key] = $Values[$key]
        }
        $path = Join-Path -Path $TestDrive -ChildPath ("config-{0}.json" -f [guid]::NewGuid())
        $base | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        return $path
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoConfig' {
    It 'accepts the example configuration' {
        $config = Get-DemoConfig -Path $examplePath
        $config.location | Should -Be 'westus3'
        $config.securityType.t2Host | Should -Be 'Standard'
        $config.fabric.lakehouseName | Should -Be 'LH_DatabaseHub'
        $config.ContainsKey('$schema') | Should -BeFalse
    }

    It 'fills schema defaults for omitted values' {
        $config = Get-DemoConfig -Path (New-TestConfig -Values @{})
        $config.profile | Should -Be 'lowest-cost'
        $config.networkMode | Should -Be 'auto'
        $config.t2Mode | Should -Be 'Nested'
        $config.t2SqlInstallMode | Should -Be 'PaygWizard'
        $config.monthlyCeilingUsd | Should -Be 250
        $config.sessionCeilingUsd | Should -Be 15
        $config.assignRoles | Should -BeFalse
        $config.bastionMaxHours | Should -Be 4
        $config.t3AutoPauseMinutes | Should -Be 15
        $config.securityType.t1 | Should -Be 'Auto'
        $config.securityType.t2Host | Should -Be 'Standard'
        $config.hybridBenefit.windows | Should -BeFalse
        $config.fabric.lakehouseName | Should -Be 'LH_DatabaseHub'
    }

    It 'keeps explicit values over defaults, including nested ones' {
        $config = Get-DemoConfig -Path (New-TestConfig -Values @{ profile = 'demo-day'; securityType = @{ t1 = 'Standard' } })
        $config.profile | Should -Be 'demo-day'
        $config.securityType.t1 | Should -Be 'Standard'
        $config.securityType.t2Host | Should -Be 'Standard'
    }

    It 'rejects a malformed subscription ID' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ subscriptionId = 'not-a-guid' }) } | Should -Throw '*environment.schema.json*'
    }

    It 'rejects an unknown property' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ unexpected = 'value' }) } | Should -Throw
    }

    It 'rejects an unknown T2 install mode' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ t2SqlInstallMode = 'Evaluation' }) } | Should -Throw
    }

    It 'defaults the T2 source to auto and accepts every source: <_>' -ForEach @('auto', 'golden', 'build') {
        (Get-DemoConfig -Path (New-TestConfig -Values @{})).t2Source | Should -Be 'auto'
        (Get-DemoConfig -Path (New-TestConfig -Values @{ t2Source = $_ })).t2Source | Should -Be $_
    }

    It 'rejects an unknown T2 source' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ t2Source = 'snapshot' }) } | Should -Throw '*environment.schema.json*'
    }

    It 'accepts every network mode: <_>' -ForEach @('auto', 'public', 'private') {
        (Get-DemoConfig -Path (New-TestConfig -Values @{ networkMode = $_ })).networkMode | Should -Be $_
    }

    It 'rejects an unknown network mode' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ networkMode = 'hybrid' }) } | Should -Throw
    }

    It 'rejects an auto-pause delay under 15 minutes' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ t3AutoPauseMinutes = 10 }) } | Should -Throw
    }

    It 'accepts -1 to disable auto-pause' {
        (Get-DemoConfig -Path (New-TestConfig -Values @{ t3AutoPauseMinutes = -1 })).t3AutoPauseMinutes | Should -Be -1
    }

    It 'defaults dataDiskSku to Auto' {
        (Get-DemoConfig -Path (New-TestConfig -Values @{})).dataDiskSku | Should -Be 'Auto'
    }

    It 'accepts the P10 opt-in without a zone' {
        (Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'P10' })).dataDiskSku | Should -Be 'P10'
    }

    It 'accepts dataDiskSku None, with or without a zone' {
        (Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'None' })).dataDiskSku | Should -Be 'None'
        (Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'None'; zone = '2' })).dataDiskSku | Should -Be 'None'
    }

    It 'rejects dataDiskSku PremiumV2 without a zone' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'PremiumV2' }) } | Should -Throw '*environment.schema.json*'
        { Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'PremiumV2'; zone = $null }) } | Should -Throw '*environment.schema.json*'
    }

    It 'accepts dataDiskSku PremiumV2 with a zone' {
        (Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'PremiumV2'; zone = '1' })).dataDiskSku | Should -Be 'PremiumV2'
    }

    It 'rejects an unknown dataDiskSku' {
        { Get-DemoConfig -Path (New-TestConfig -Values @{ dataDiskSku = 'P20' }) } | Should -Throw
    }

    It 'requires the T3 admin group' {
        $path = Join-Path -Path $TestDrive -ChildPath 'missing-group.json'
        @{ subscriptionId = '00000000-0000-0000-0000-000000000000'; tenantId = '00000000-0000-0000-0000-000000000000'; ownerEmail = 'a@b.cd' } |
            ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        { Get-DemoConfig -Path $path } | Should -Throw
    }

    It 'explains how to create a missing configuration file' {
        { Get-DemoConfig -Path (Join-Path -Path $TestDrive -ChildPath 'absent.json') } | Should -Throw '*Copy config/demo.config.example.json*'
    }
}
