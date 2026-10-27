BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    $script:repository = 'contoso/dbhub-demo'
    $script:clientId = 'aaaaaaaa-1111-2222-3333-444444444444'

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t4Enabled'] = $false
        return $config
    }

    function New-GhResult([int] $ExitCode = 0, [string] $StdOut = '', [int] $StatusCode = 0) {
        $status = if ($StatusCode) { $StatusCode } elseif ($ExitCode -eq 0) { 200 } else { 0 }
        $stderr = if ($ExitCode -ne 0) { 'gh: request failed (HTTP {0})' -f $status } else { '' }
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $stderr; StatusCode = $status }
    }

    function Reset-GitHubState {
        # What the mocked GitHub CLI answers with; tests change single entries.
        $script:ghCalls = [System.Collections.Generic.List[object]]::new()
        $script:gh = @{
            Installed     = $true
            SignedIn      = $true
            Admin         = $true
            Visibility    = 'public'
            IsTemplate    = $false
            Scanning      = 'disabled'
            Push          = 'disabled'
            Rulesets      = '[]'
            RulesetsCode  = 0
            Reporting     = $false
            ReportingCode = 0
            AlertsOn      = $false
            WriteCode     = 0
        }
    }

    function Set-GitHubMock {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGitHubCli -MockWith {
            $script:ghCalls.Add([pscustomobject]@{ Arguments = @($ArgumentList); Input = $InputText })
            $state = $script:gh
            if (-not $state.Installed) {
                return [pscustomobject]@{ ExitCode = 127; StdOut = ''; StdErr = 'The GitHub CLI (gh) was not found on PATH.'; StatusCode = 0 }
            }
            if ($ArgumentList[0] -ne 'api') {
                # gh secret set and gh variable set.
                return (New-GhResult)
            }
            $method = $ArgumentList[2]
            $endpoint = $ArgumentList[7]
            if ($method -eq 'GET' -and $endpoint -eq 'user') {
                if (-not $state.SignedIn) {
                    return (New-GhResult -ExitCode 4 -StatusCode 401)
                }
                return (New-GhResult -StdOut '{"login":"octo-owner","id":4242}')
            }
            if ($method -eq 'GET' -and $endpoint -eq "repos/$($script:repository)") {
                $repo = [ordered]@{
                    default_branch        = 'main'
                    visibility            = $state.Visibility
                    is_template           = $state.IsTemplate
                    permissions           = @{ admin = $state.Admin }
                    security_and_analysis = @{ secret_scanning = @{ status = $state.Scanning }; secret_scanning_push_protection = @{ status = $state.Push } }
                }
                return (New-GhResult -StdOut ($repo | ConvertTo-Json -Depth 5))
            }
            if ($method -eq 'GET' -and $endpoint -like '*/rulesets') {
                if ($state.RulesetsCode) {
                    return (New-GhResult -ExitCode 1 -StatusCode $state.RulesetsCode)
                }
                return (New-GhResult -StdOut $state.Rulesets)
            }
            if ($method -eq 'GET' -and $endpoint -like '*/private-vulnerability-reporting') {
                if ($state.ReportingCode) {
                    return (New-GhResult -ExitCode 1 -StatusCode $state.ReportingCode)
                }
                return (New-GhResult -StdOut (@{ enabled = $state.Reporting } | ConvertTo-Json))
            }
            if ($method -eq 'GET' -and $endpoint -like '*/vulnerability-alerts') {
                if ($state.AlertsOn) {
                    return (New-GhResult -StatusCode 204)
                }
                return (New-GhResult -ExitCode 1 -StatusCode 404)
            }
            if ($state.WriteCode) {
                return (New-GhResult -ExitCode 1 -StatusCode $state.WriteCode)
            }
            return (New-GhResult -StdOut '{}')
        }
    }

    function Get-ApiCall([string] $Method, [string] $Like) {
        @($script:ghCalls | Where-Object { $_.Arguments[0] -eq 'api' -and $_.Arguments[2] -eq $Method -and $_.Arguments[7] -like $Like })
    }

    function Get-Body([object] $Call) {
        $Call.Input | ConvertFrom-Json -AsHashtable
    }
}

AfterAll {
    Initialize-GuardTestContext -Clear
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Initialize-DemoGitHubOidc: the GitHub environments and their secrets (ADR 0022)' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        Reset-GitHubState
        Set-GitHubMock
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            $script:azCalls.Add($text)
            if ($text -like 'identity create*') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = ('{{"clientId":"{0}","principalId":"bbbbbbbb-1111-2222-3333-444444444444"}}' -f $script:clientId); StdErr = '' }
            }
            if ($text -like 'identity federated-credential show*') {
                return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = 'ERROR: (NotFound) The federated credential was not found.' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
        }
    }

    It 'by default writes nothing to GitHub and prints gh secret set commands, never gh variable set' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -Confirm:$false
        $script:ghCalls.Count | Should -Be 0
        $github = $results | Where-Object { $_.checkId -eq 'OIDC.GITHUB' }
        $github.status | Should -Be 'Manual action required'
        $github.remediation | Should -Match ([regex]::Escape("gh secret set AZURE_CLIENT_ID --env demo --repo $($script:repository) --body $($script:clientId)"))
        $github.remediation | Should -Match ([regex]::Escape("gh secret set DBHUB_CONFIG_JSON --env demo --repo $($script:repository)"))
        $github.remediation | Should -Not -Match 'gh variable set AZURE_|gh variable set DBHUB_CONFIG_JSON'
        $github.message | Should -Match '-ConfigureGitHub'
    }

    It 'with -ConfigureGitHub, makes you the required reviewer, allows only the default branch, and sends each secret on standard input' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ConfigureGitHub -ConfigJson '{"prefix":"dbhub"}' -Confirm:$false

        $put = @(Get-ApiCall 'PUT' "repos/$($script:repository)/environments/demo")
        $put.Count | Should -Be 1
        $body = Get-Body $put[0]
        @($body.reviewers).Count | Should -Be 1
        $body.reviewers[0].type | Should -Be 'User'
        $body.reviewers[0].id | Should -Be 4242
        $body.prevent_self_review | Should -BeFalse
        $body.deployment_branch_policy.protected_branches | Should -BeFalse
        $body.deployment_branch_policy.custom_branch_policies | Should -BeTrue
        $policy = @(Get-ApiCall 'POST' "repos/$($script:repository)/environments/demo/deployment-branch-policies")
        $policy.Count | Should -Be 1
        (Get-Body $policy[0]).name | Should -Be 'main'
        (Get-Body $policy[0]).type | Should -Be 'branch'

        $secrets = @($script:ghCalls | Where-Object { $_.Arguments[0] -eq 'secret' })
        @($secrets | ForEach-Object { $_.Arguments[2] }) | Should -Be @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'DBHUB_CONFIG_JSON')
        foreach ($call in $secrets) {
            $call.Arguments | Should -Be @('secret', 'set', $call.Arguments[2], '--env', 'demo', '--repo', $script:repository)
        }
        ($secrets | Where-Object { $_.Arguments[2] -eq 'AZURE_CLIENT_ID' }).Input | Should -Be $script:clientId
        ($secrets | Where-Object { $_.Arguments[2] -eq 'DBHUB_CONFIG_JSON' }).Input | Should -Be '{"prefix":"dbhub"}'
        foreach ($call in $script:ghCalls) {
            ($call.Arguments -join ' ') | Should -Not -Match ([regex]::Escape($script:clientId)) -Because 'a value never goes on the command line'
        }

        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.ENV_DEMO' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.SECRETS_DEMO' }).status | Should -Be 'Pass'
        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.SCHEDULE' }).status | Should -Be 'Not selected'
        @($script:ghCalls | Where-Object { $_.Arguments[0] -eq 'variable' }).Count | Should -Be 0
    }

    It 'with -ScheduleEnvironment, trusts demo-schedule in Azure, gives it no reviewers, and never turns the schedules on' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ConfigureGitHub -ScheduleEnvironment -Confirm:$false

        @($script:azCalls | Where-Object { $_ -like 'identity federated-credential create*--name gh-demo-schedule*--subject repo:contoso/dbhub-demo:environment:demo-schedule*' }).Count | Should -Be 1
        @($script:azCalls | Where-Object { $_ -like 'identity federated-credential create*--subject repo:contoso/dbhub-demo:environment:demo *' }).Count | Should -Be 1
        $schedule = @(Get-ApiCall 'PUT' "repos/$($script:repository)/environments/demo-schedule")
        $schedule.Count | Should -Be 1
        @((Get-Body $schedule[0]).reviewers).Count | Should -Be 0
        (Get-Body $schedule[0]).deployment_branch_policy.custom_branch_policies | Should -BeTrue
        @(Get-ApiCall 'POST' "repos/$($script:repository)/environments/demo-schedule/deployment-branch-policies").Count | Should -Be 1
        @($script:ghCalls | Where-Object { $_.Arguments[0] -eq 'secret' -and $_.Arguments[4] -eq 'demo-schedule' }).Count | Should -Be 4

        $variables = @($script:ghCalls | Where-Object { $_.Arguments[0] -eq 'variable' })
        $variables.Count | Should -Be 1
        $variables[0].Arguments | Should -Be @('variable', 'set', 'DBHUB_SCHEDULE_ENVIRONMENT', '--repo', $script:repository)
        $variables[0].Input | Should -Be 'demo-schedule'
        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.SCHEDULE' }).status | Should -Be 'Pass'
        $off = $results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.SCHEDULES' }
        $off.status | Should -Be 'Not selected'
        $off.remediation | Should -Match 'DBHUB_SCHEDULES_ENABLED'
    }

    It 'without -ConfigureGitHub, -ScheduleEnvironment still adds the credential and prints the schedule environment''s commands' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ScheduleEnvironment -ScheduleEnvironmentName 'nightly' -Confirm:$false
        $script:ghCalls.Count | Should -Be 0
        @($script:azCalls | Where-Object { $_ -like '*--subject repo:contoso/dbhub-demo:environment:nightly*' }).Count | Should -Be 1
        $github = $results | Where-Object { $_.checkId -eq 'OIDC.GITHUB' }
        $github.remediation | Should -Match 'gh secret set AZURE_TENANT_ID --env nightly'
        $github.remediation | Should -Match 'gh variable set DBHUB_SCHEDULE_ENVIRONMENT --repo contoso/dbhub-demo --body nightly'
    }

    It 'refuses a schedule environment with the reviewed environment''s name' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ScheduleEnvironment -ScheduleEnvironmentName 'demo' -Confirm:$false
        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.SCHEDULE' }).status | Should -Be 'Fail'
        $script:azCalls.Count | Should -Be 0
    }

    It 'reports Manual action required when GitHub refuses the environment on a private repository' {
        $script:gh.Visibility = 'private'
        $script:gh.WriteCode = 422
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ConfigureGitHub -Confirm:$false
        $environment = $results | Where-Object { $_.checkId -eq 'OIDC.GITHUB.ENV_DEMO' }
        $environment.status | Should -Be 'Manual action required'
        $environment.remediation | Should -Match 'once contoso/dbhub-demo is public'
        @($script:ghCalls | Where-Object { $_.Arguments[0] -eq 'secret' }).Count | Should -Be 0
    }

    It 'asks for the GitHub CLI or its sign-in, and keeps what it did in Azure: <Case>' -ForEach @(
        @{ Case = 'no gh'; Installed = $false; SignedIn = $true; Expected = 'isn''t installed' }
        @{ Case = 'not signed in'; Installed = $true; SignedIn = $false; Expected = 'gh auth login' }
    ) {
        $script:gh.Installed = $Installed
        $script:gh.SignedIn = $SignedIn
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ConfigureGitHub -Confirm:$false
        $github = $results | Where-Object { $_.checkId -eq 'OIDC.GITHUB' }
        $github.status | Should -Be 'Manual action required'
        $github.message | Should -Match $Expected
        ($results | Where-Object { $_.checkId -eq 'OIDC.IDENTITY' }).status | Should -Be 'Pass'
    }

    It 'needs an administrator of the repository' {
        $script:gh.Admin = $false
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ConfigureGitHub -Confirm:$false
        ($results | Where-Object { $_.checkId -eq 'OIDC.GITHUB' }).message | Should -Match 'isn''t an administrator'
        @(Get-ApiCall 'PUT' '*').Count | Should -Be 0
    }

    It 'with -WhatIf, writes nothing to Azure or GitHub and says what it would do' {
        $results = Initialize-DemoGitHubOidc -Config $config -Repository $script:repository -Environment demo -ConfigureGitHub -ScheduleEnvironment -WhatIf
        $script:azCalls.Count | Should -Be 0
        $script:ghCalls.Count | Should -Be 0
        $github = $results | Where-Object { $_.checkId -eq 'OIDC.GITHUB' }
        $github.status | Should -Be 'Not selected'
        $github.message | Should -Match 'demo-schedule: no reviewers'
    }
}

Describe 'Initialize-DemoGitHubRepository: the public repository''s settings (ADR 0022)' {
    BeforeEach {
        Reset-GitHubState
        Set-GitHubMock
    }

    It 'turns on each setting that is off: the ruleset, secret scanning, push protection, private reporting, and Dependabot alerts' {
        $results = Initialize-DemoGitHubRepository -Repository $script:repository -Confirm:$false

        $create = @(Get-ApiCall 'POST' "repos/$($script:repository)/rulesets")
        $create.Count | Should -Be 1
        $ruleset = Get-Body $create[0]
        $ruleset.target | Should -Be 'branch'
        $ruleset.enforcement | Should -Be 'active'
        $ruleset.conditions.ref_name.include | Should -Be @('~DEFAULT_BRANCH')
        @($ruleset.rules | ForEach-Object { $_.type }) | Should -Be @('deletion', 'non_fast_forward', 'pull_request')
        $pullRequest = $ruleset.rules | Where-Object { $_.type -eq 'pull_request' }
        $pullRequest.parameters.required_approving_review_count | Should -Be 0
        $pullRequest.parameters.require_code_owner_review | Should -BeFalse
        $ruleset.ContainsKey('bypass_actors') | Should -BeFalse

        $patch = @(Get-ApiCall 'PATCH' "repos/$($script:repository)")
        $patch.Count | Should -Be 1
        (Get-Body $patch[0]).security_and_analysis.secret_scanning.status | Should -Be 'enabled'
        (Get-Body $patch[0]).security_and_analysis.secret_scanning_push_protection.status | Should -Be 'enabled'
        @(Get-ApiCall 'PUT' "repos/$($script:repository)/private-vulnerability-reporting").Count | Should -Be 1
        @(Get-ApiCall 'PUT' "repos/$($script:repository)/vulnerability-alerts").Count | Should -Be 1

        foreach ($checkId in 'REPO.VISIBILITY', 'REPO.RULESET', 'REPO.SECRETSCANNING', 'REPO.PUSHPROTECTION', 'REPO.VULNERABILITYREPORTING', 'REPO.DEPENDABOTALERTS') {
            ($results | Where-Object { $_.checkId -eq $checkId }).status | Should -Be 'Pass' -Because $checkId
        }
        ($results | Where-Object { $_.checkId -eq 'REPO.TEMPLATE' }).status | Should -Be 'Not selected'
        @(Get-ApiCall 'PATCH' '*' | Where-Object { $patchBody = Get-Body $_; $patchBody.ContainsKey('visibility') -or $patchBody.ContainsKey('private') }).Count | Should -Be 0 -Because 'it never changes the visibility'
    }

    It 'updates its ruleset in place, and leaves what is already on alone' {
        $script:gh.Rulesets = '[{"id":77,"name":"Protect the default branch"}]'
        $script:gh.Scanning = 'enabled'
        $script:gh.Push = 'enabled'
        $script:gh.Reporting = $true
        $script:gh.AlertsOn = $true
        Initialize-DemoGitHubRepository -Repository $script:repository -Confirm:$false | Out-Null
        @(Get-ApiCall 'PUT' "repos/$($script:repository)/rulesets/77").Count | Should -Be 1
        @(Get-ApiCall 'POST' '*').Count | Should -Be 0
        @(Get-ApiCall 'PATCH' '*').Count | Should -Be 0
        @(Get-ApiCall 'PUT' '*/private-vulnerability-reporting').Count | Should -Be 0
        @(Get-ApiCall 'PUT' '*/vulnerability-alerts').Count | Should -Be 0
    }

    It 'marks the repository as a template only with -Template' {
        $results = Initialize-DemoGitHubRepository -Repository $script:repository -Template -Confirm:$false
        $template = @(Get-ApiCall 'PATCH' "repos/$($script:repository)" | Where-Object { (Get-Body $_).ContainsKey('is_template') })
        $template.Count | Should -Be 1
        (Get-Body $template[0]).is_template | Should -BeTrue
        ($results | Where-Object { $_.checkId -eq 'REPO.TEMPLATE' }).status | Should -Be 'Pass'
    }

    It 'on a private repository, reports each setting GitHub refuses as Manual action required, to run again after the flip' {
        $script:gh.Visibility = 'private'
        $script:gh.RulesetsCode = 403
        $script:gh.ReportingCode = 422
        $script:gh.WriteCode = 403
        $results = Initialize-DemoGitHubRepository -Repository $script:repository -Template -Confirm:$false
        foreach ($checkId in 'REPO.VISIBILITY', 'REPO.RULESET', 'REPO.SECRETSCANNING', 'REPO.PUSHPROTECTION', 'REPO.VULNERABILITYREPORTING', 'REPO.DEPENDABOTALERTS', 'REPO.TEMPLATE') {
            $item = $results | Where-Object { $_.checkId -eq $checkId }
            $item.status | Should -Be 'Manual action required' -Because $checkId
            $item.remediation | Should -Match 'setup-github-repo\.ps1 again' -Because $checkId
        }
    }

    It 'with -WhatIf, only reads, and says what it would do' {
        $results = Initialize-DemoGitHubRepository -Repository $script:repository -Template -WhatIf
        @($script:ghCalls | Where-Object { $_.Arguments[0] -ne 'api' -or $_.Arguments[2] -ne 'GET' }).Count | Should -Be 0
        foreach ($checkId in 'REPO.RULESET', 'REPO.SECRETSCANNING', 'REPO.PUSHPROTECTION', 'REPO.VULNERABILITYREPORTING', 'REPO.DEPENDABOTALERTS', 'REPO.TEMPLATE') {
            $item = $results | Where-Object { $_.checkId -eq $checkId }
            $item.status | Should -Be 'Not selected' -Because $checkId
            $item.message | Should -Match '^What if:' -Because $checkId
        }
    }

    It 'needs gh, its sign-in, and an administrator, and stops there: <Case>' -ForEach @(
        @{ Case = 'no gh'; Installed = $false; SignedIn = $true; Admin = $true; Expected = 'isn''t installed' }
        @{ Case = 'not signed in'; Installed = $true; SignedIn = $false; Admin = $true; Expected = 'gh auth login' }
        @{ Case = 'not an administrator'; Installed = $true; SignedIn = $true; Admin = $false; Expected = 'isn''t an administrator' }
    ) {
        $script:gh.Installed = $Installed
        $script:gh.SignedIn = $SignedIn
        $script:gh.Admin = $Admin
        $results = @(Initialize-DemoGitHubRepository -Repository $script:repository -Confirm:$false)
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'REPO.GITHUB'
        $results[0].status | Should -Be 'Manual action required'
        $results[0].message | Should -Match $Expected
    }
}

Describe 'setup-github-repo.ps1' {
    BeforeAll {
        $script:scriptPath = Join-Path -Path $repoRoot -ChildPath 'scripts/setup-github-repo.ps1'
        # Not script-scoped: the mock runs inside setup-github-repo.ps1, whose script scope is its own.
        $capture = @{}
    }

    BeforeEach {
        $capture.Clear()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -CommandName Write-DemoResultReport -MockWith { }
    }

    It 'takes the repository from github.repository in the configuration, and with -WhatIf only reads' {
        $config = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $config['github'] = @{ repository = $script:repository; environment = 'demo' }
        $path = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        Set-Content -LiteralPath $path -Value ($config | ConvertTo-Json -Depth 16) -Encoding utf8NoBOM
        # Self-contained (the script has its own script scope): any write under -WhatIf throws.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGitHubCli -ParameterFilter { $true } -MockWith {
            if ($ArgumentList[0] -ne 'api' -or $ArgumentList[2] -ne 'GET') {
                throw ('A write under -WhatIf: {0}' -f ($ArgumentList -join ' '))
            }
            $answer = switch -Wildcard ($ArgumentList[7]) {
                'user' { '{"login":"octo-owner","id":4242}' }
                'repos/contoso/dbhub-demo' { '{"default_branch":"main","visibility":"public","is_template":false,"permissions":{"admin":true}}' }
                '*/rulesets' { '[]' }
                '*/private-vulnerability-reporting' { '{"enabled":false}' }
                default { $null }
            }
            if ($null -eq $answer) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'gh: Not Found (HTTP 404)'; StatusCode = 404 }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $answer; StdErr = ''; StatusCode = 200 }
        }
        $output = Join-Path -Path $TestDrive -ChildPath 'out.jsonl'
        & $script:scriptPath -ConfigPath $path -Template -WhatIf -OutputPath $output 6>$null
        $LASTEXITCODE | Should -Be 0
        $written = @(Get-Content -LiteralPath $output | ForEach-Object { $_ | ConvertFrom-Json })
        @($written | Where-Object { $_.checkId -eq 'REPO.GITHUB' }).Count | Should -Be 0 -Because 'the configuration named the repository'
        foreach ($checkId in 'REPO.RULESET', 'REPO.SECRETSCANNING', 'REPO.VULNERABILITYREPORTING', 'REPO.DEPENDABOTALERTS', 'REPO.TEMPLATE') {
            $item = $written | Where-Object { $_.checkId -eq $checkId }
            $item.status | Should -Be 'Not selected' -Because $checkId
            $item.message | Should -Match '^What if:' -Because $checkId
        }
    }

    It 'prefers -Repository, and fails on the example''s placeholder' {
        Mock -CommandName Initialize-DemoGitHubRepository -MockWith {
            $capture['repository'] = $Repository
            @(New-DemoResult -CheckId 'REPO.RULESET' -Area 'security' -Target 'repo' -Status 'Pass' -Message 'ruleset')
        }
        & $script:scriptPath -Repository 'contoso/other-demo' -ConfigPath (Join-Path -Path $TestDrive -ChildPath 'missing.json') -OutputPath (Join-Path -Path $TestDrive -ChildPath 'out.jsonl')
        $capture['repository'] | Should -Be 'contoso/other-demo'
        $capture.Clear()
        & $script:scriptPath -Repository 'your-org/fabric-database-hub-demo' -OutputPath (Join-Path -Path $TestDrive -ChildPath 'out2.jsonl')
        $LASTEXITCODE | Should -Be 1
        $capture.ContainsKey('repository') | Should -BeFalse
    }
}
