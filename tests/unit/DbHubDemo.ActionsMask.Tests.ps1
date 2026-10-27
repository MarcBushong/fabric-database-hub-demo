BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    # Obviously fake values: every group repeats one digit or letter.
    $script:Subscription = '11111111-2222-3333-4444-555555555555'
    $script:Tenant = '66666666-7777-8888-9999-000000000000'
    $script:Group = 'aaaaaaaa-1111-2222-3333-444444444444'
    $script:Account = 'operator@contoso.example'

    function Set-ActionsState([string] $Value) {
        # CI runs these tests in GitHub Actions too, so each test sets GITHUB_ACTIONS itself.
        $env:GITHUB_ACTIONS = $Value
        InModuleScope DbHubDemo { $script:DemoLogMasks.Clear() }
    }

    function Get-HostText([scriptblock] $Script) {
        # Host output (Write-Host) arrives as information records.
        @(& $Script 6>&1 | ForEach-Object { [string]$_ })
    }

    $script:savedActions = $env:GITHUB_ACTIONS
    $script:savedSummary = $env:GITHUB_STEP_SUMMARY
}

AfterAll {
    $env:GITHUB_ACTIONS = $script:savedActions
    $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    InModuleScope DbHubDemo { $script:DemoLogMasks.Clear() }
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Register-DemoLogMask (ADR 0022)' {
    AfterEach {
        Set-ActionsState -Value $script:savedActions
    }

    It 'does nothing outside GitHub Actions, so local output keeps every value' {
        Set-ActionsState -Value ''
        $output = Get-HostText { Register-DemoLogMask -Value $script:Subscription }
        $output | Should -BeNullOrEmpty
        InModuleScope DbHubDemo { $script:DemoLogMasks.Count } | Should -Be 0
        InModuleScope DbHubDemo -Parameters @{ Id = $script:Subscription } { Protect-DemoLogText -Text "subscription $Id" } | Should -Be "subscription $($script:Subscription)"
    }

    It 'masks a value as given, in lowercase, and in uppercase, once each, and ignores short values' {
        Set-ActionsState -Value 'true'
        $mixed = 'AbCdEf12-1111-2222-3333-444444444444'
        $output = Get-HostText { Register-DemoLogMask -Value $mixed, 'abc', '' }
        $output | Should -Be @("::add-mask::$mixed", "::add-mask::$($mixed.ToLowerInvariant())", "::add-mask::$($mixed.ToUpperInvariant())")
        Get-HostText { Register-DemoLogMask -Value $mixed.ToLowerInvariant() } | Should -BeNullOrEmpty
    }

    It 'with -Config, masks every GUID and email address in the configuration, nested or in a list, and nothing else' {
        Set-ActionsState -Value 'true'
        $config = [ordered]@{
            subscriptionId     = $script:Subscription
            tenantId           = $script:Tenant
            azureAccount       = $script:Account
            location           = 'westus3'
            environment        = 'demo'
            presenterObjectIds = @('bbbbbbbb-1111-2222-3333-444444444444')
            fabric             = [ordered]@{ workspaceName = 'Database Hub Demo'; workspaceId = 'cccccccc-1111-2222-3333-444444444444' }
            keyVault           = [ordered]@{ operatorObjectIds = @('dddddddd-1111-2222-3333-444444444444') }
        }
        $output = Get-HostText { Register-DemoLogMask -Config $config }
        foreach ($value in $script:Subscription, $script:Tenant, $script:Account, 'bbbbbbbb-1111-2222-3333-444444444444', 'cccccccc-1111-2222-3333-444444444444', 'dddddddd-1111-2222-3333-444444444444') {
            $output | Should -Contain "::add-mask::$value"
        }
        ($output -join "`n") | Should -Not -Match 'westus3|Database Hub Demo|::add-mask::demo'
    }
}

Describe 'What the module writes in GitHub Actions (ADR 0022)' {
    BeforeEach {
        Set-ActionsState -Value 'true'
        $null = Get-HostText { Register-DemoLogMask -Value $script:Subscription, $script:Account, 'abc123' }
        $script:message = "Subscription $script:Subscription in tenant $script:Tenant as $($script:Account.ToUpperInvariant()); T3 azuresql01-zz9yy8 and T4 pgflex01-abc123."
    }

    AfterEach {
        Set-ActionsState -Value $script:savedActions
        $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    }

    It 'Protect-DemoLogText writes registered values in any case, any other GUID, and the servers'' suffix as ***, and still redacts secrets' {
        $text = InModuleScope DbHubDemo -Parameters @{ Text = $script:message + ' Bearer abcdefghijklmnop' } { Protect-DemoLogText -Text $Text }
        $text | Should -Be 'Subscription *** in tenant *** as ***; T3 azuresql01-*** and T4 pgflex01-***. Bearer [REDACTED]'
    }

    It 'Write-DemoLog writes the line, and a warning annotation, masked' {
        $lines = Get-HostText {
            Write-DemoLog -Message $script:message
            Write-DemoLog -Level Warning -Message $script:message
        }
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '\[INFO\] Subscription \*\*\* in tenant \*\*\* as \*\*\*'
        $lines[1] | Should -BeLike '::warning::Subscription *** in tenant ***'
        ($lines -join "`n") | Should -Not -Match ([regex]::Escape($script:Subscription))
    }

    It 'Export-DemoResult writes the JSON lines and the job summary masked, and keeps the result in memory' {
        $summary = Join-Path -Path $TestDrive -ChildPath 'summary.md'
        $env:GITHUB_STEP_SUMMARY = $summary
        $result = New-DemoResult -CheckId 'TEST.MASK' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message $script:message -Evidence ([ordered]@{ subscriptionId = $script:Subscription; objectId = $script:Group })
        $path = Join-Path -Path $TestDrive -ChildPath 'out/results.jsonl'
        Export-DemoResult -Result @($result) -Path $path
        $line = Get-Content -LiteralPath $path -Raw
        foreach ($value in $script:Subscription, $script:Tenant, $script:Group, $script:Account, 'zz9yy8') {
            $line | Should -Not -Match ([regex]::Escape($value))
            (Get-Content -LiteralPath $summary -Raw) | Should -Not -Match ([regex]::Escape($value))
        }
        ($line | ConvertFrom-Json).evidence.subscriptionId | Should -Be '***'
        (Get-Content -LiteralPath $summary -Raw) | Should -Match 'Subscription \\\*\\\*\\\* in tenant'
        $result.message | Should -Match ([regex]::Escape($script:Subscription))
        $result.evidence.objectId | Should -Be $script:Group
    }

    It 'Write-DemoResultReport writes the table, the remediation, and the job summary masked' {
        $summary = Join-Path -Path $TestDrive -ChildPath 'report.md'
        $env:GITHUB_STEP_SUMMARY = $summary
        $result = New-DemoResult -CheckId 'TEST.MANUAL' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message $script:message -Remediation "Run it for $($script:Subscription)."
        $output = @(Write-DemoResultReport -Result @($result) -Title 'test' 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $output | Should -Not -Match ([regex]::Escape($script:Subscription))
        $output | Should -Match 'Run it for \*\*\*\.'
        (Get-Content -LiteralPath $summary -Raw) | Should -Not -Match ([regex]::Escape($script:Subscription))
    }

    It 'Get-DemoConfig masks the configuration''s IDs and accounts in the job log' {
        $path = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        $example = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $example['subscriptionId'] = '22222222-3333-4444-5555-666666666666'
        $example['t3AdminGroupObjectId'] = 'eeeeeeee-1111-2222-3333-444444444444'
        Set-Content -LiteralPath $path -Value ($example | ConvertTo-Json -Depth 16) -Encoding utf8NoBOM
        $output = Get-HostText { $null = Get-DemoConfig -Path $path }
        $output | Should -Contain '::add-mask::22222222-3333-4444-5555-666666666666'
        $output | Should -Contain '::add-mask::eeeeeeee-1111-2222-3333-444444444444'
    }

    It 'the resource group tag reader masks the deployment''s random suffix' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ name = 'rg-dbhub-demo'; tags = @{ deploymentId = 'qq7rr6' } } | ConvertTo-Json); StdErr = '' }
        }
        $output = Get-HostText { InModuleScope DbHubDemo -Parameters @{ Id = $script:Subscription } { $null = Get-DemoResourceGroupTag -SubscriptionId $Id -ResourceGroupName 'rg-dbhub-demo' } }
        $output | Should -Contain '::add-mask::qq7rr6'
        $output | Should -Contain '::add-mask::QQ7RR6'
    }
}
