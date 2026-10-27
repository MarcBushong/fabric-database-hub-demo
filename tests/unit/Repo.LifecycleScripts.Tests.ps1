BeforeDiscovery {
    $repoRootForDiscovery = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # The demo's scheduled workflows: they call the shared runner (codeql.yml has its own schedule).
    $script:scheduled = @(Get-ChildItem -Path (Join-Path -Path $repoRootForDiscovery -ChildPath '.github/workflows') -Filter '*.yml' | Where-Object { $text = Get-Content -LiteralPath $_.FullName -Raw; $text -match '(?m)^\s+schedule:' -and $text -match 'reusable-demo-run\.yml' } | ForEach-Object { $_.Name })
    $script:callers = @(Get-ChildItem -Path (Join-Path -Path $repoRootForDiscovery -ChildPath '.github/workflows') -Filter '*.yml' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'uses: \./\.github/workflows/reusable-demo-run\.yml' } | ForEach-Object { $_.Name })
}

BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $workflows = Join-Path -Path $repoRoot -ChildPath '.github/workflows'
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    function Get-WorkflowText([string] $Name) {
        Get-Content -LiteralPath (Join-Path -Path $workflows -ChildPath $Name) -Raw
    }

    function Get-DispatchInput([string] $Text) {
        # The input names under on.workflow_dispatch.inputs (six-space indentation), with their types.
        $block = [regex]::Match($Text, '(?ms)^  workflow_dispatch:\s*\n    inputs:\s*\n(.*?)(?=^\S|^  \S|\z)').Groups[1].Value
        $inputs = [ordered]@{}
        $current = ''
        foreach ($line in $block -split "`n") {
            if ($line -match '^      ([a-z][a-z0-9-]*):\s*$') {
                $current = $Matches[1]
                $inputs[$current] = 'string'
            }
            elseif ($current -and $line -match '^        type:\s*(\S+)') {
                $inputs[$current] = $Matches[1]
            }
        }
        return $inputs
    }
}

Describe 'Demo workflows' {
    It 'demo-control.yml declares exactly the ADR 0014 input contract, all as strings' {
        $inputs = Get-DispatchInput -Text (Get-WorkflowText 'demo-control.yml')
        @($inputs.Keys) | Should -Be @('environment', 'target', 'scenario', 'duration', 'concurrency', 'intensity', 'reset-before', 'auto-cleanup')
        foreach ($name in $inputs.Keys) {
            $inputs[$name] | Should -BeIn @('string', 'choice') -Because "the notebook dispatches $name as a string"
        }
    }

    It 'deploy.yml offers exactly deploy.ps1''s stages' {
        $text = Get-WorkflowText 'deploy.yml'
        $options = [regex]::Match($text, '(?ms)from-stage:.*?options:\s*\n((?:\s+- .*\n)+)').Groups[1].Value
        $values = @([regex]::Matches($options, '- "?([A-Za-z0-9]*)"?') | ForEach-Object { $_.Groups[1].Value })
        $stages = & (Get-Module -Name DbHubDemo) { Get-DemoDeploymentStageName }
        $values | Should -Be (@('auto') + $stages)
        $text | Should -Match ([regex]::Escape("toJSON(inputs.from-stage != 'auto' && inputs.from-stage || '')"))
    }

    It 'the shared runner signs in with OpenID Connect, one concurrency group per environment, and an allowlist of scripts' {
        $text = Get-WorkflowText 'reusable-demo-run.yml'
        $text | Should -Match '(?m)^\s+id-token: write'
        $text | Should -Match 'environment: \$\{\{ inputs\.environment \}\}'
        $text | Should -Match 'group: dbhub-demo-\$\{\{ inputs\.environment \}\}'
        $text | Should -Match 'cancel-in-progress: false'
        $text | Should -Not -Match 'az login'
        $allowed = [regex]::Match($text, "\`$allowed = @\(([^)]*)\)").Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") }
        foreach ($script in $allowed) {
            Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath ('scripts/{0}.ps1' -f $script)) | Should -BeTrue -Because $script
        }
        $action = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.github/actions/demo-setup/action.yml') -Raw
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $action | Should -Match ('uses: azure/login@{0} # {1}' -f $versions.actions['azure/login'].sha, $versions.actions['azure/login'].version)
        $versions.actions['azure/login'].version | Should -Match '^v3\.'
        $action | Should -Not -Match 'client-secret|creds:'
    }

    It '<_> calls the shared runner with an allowed script and may request an OpenID Connect token' -ForEach $script:callers {
        $text = Get-WorkflowText $_
        $runner = Get-WorkflowText 'reusable-demo-run.yml'
        $allowed = [regex]::Match($runner, "\`$allowed = @\(([^)]*)\)").Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") }
        foreach ($match in [regex]::Matches($text, '(?m)^\s+script: (\S+)')) {
            $match.Groups[1].Value | Should -BeIn $allowed
        }
        $text | Should -Match '(?m)^\s+id-token: write'
    }

    It '<_> is off unless DBHUB_SCHEDULES_ENABLED is true, and can be run by hand' -ForEach $script:scheduled {
        $text = Get-WorkflowText $_
        $text | Should -Match "if: vars\.DBHUB_SCHEDULES_ENABLED == 'true' \|\| github\.event_name == 'workflow_dispatch'"
        $text | Should -Match '(?m)^  workflow_dispatch:'
    }

    It 'has the scheduled start, stop, expiry, and Bastion cleanup, and a warm-up workflow' {
        foreach ($name in 'schedule-start.yml', 'schedule-stop.yml', 'expiry.yml', 'bastion-cleanup.yml', 'warm-up.yml') {
            Test-Path -LiteralPath (Join-Path -Path $workflows -ChildPath $name) | Should -BeTrue -Because $name
        }
        (Get-WorkflowText 'bastion-cleanup.yml') | Should -Match '"RemoveBastionOnly": true, "IfExpired": true'
        (Get-WorkflowText 'expiry.yml') | Should -Match '"Force": true, "IfExpired": true'
        (Get-WorkflowText 'schedule-start.yml') | Should -Match '"WarmUpMinutes": 30'
        (Get-WorkflowText 'destroy.yml') | Should -Match 'if: inputs\.confirm == inputs\.environment'
    }

    It 'validate.yml keeps the static job and runs validate.ps1 live only by hand, with its JSON lines as an artifact' {
        $text = Get-WorkflowText 'validate.yml'
        $text | Should -Match 'uses: \./\.github/workflows/reusable-static-checks\.yml'
        $text | Should -Match "if: github\.event_name == 'workflow_dispatch' && inputs\.live"
        $text | Should -Match 'script: validate'
        $text | Should -Match '"ConfigPath": "config/demo\.config\.json", "OutputPath": "out/validate\.jsonl"'
        (Get-WorkflowText 'reusable-demo-run.yml') | Should -Match 'path: out/\*\.jsonl'
        (Get-WorkflowText 'reusable-demo-run.yml') | Should -Match 'exit \$LASTEXITCODE'
    }
}

Describe 'Workflows in a public repository (ADR 0022)' {
    BeforeAll {
        $script:allWorkflows = @(Get-ChildItem -Path $workflows -Filter '*.yml' | ForEach-Object { $_.Name })

        function Get-WorkflowTrigger([string] $Text) {
            # The event names under the top-level on: key (two-space indentation).
            $block = [regex]::Match($Text, '(?ms)^on:\s*\n(.*?)(?=^\S)').Groups[1].Value
            @([regex]::Matches($block, '(?m)^  ([a-z_]+):') | ForEach-Object { $_.Groups[1].Value })
        }

        function Get-TopLevelPermission([string] $Text) {
            [regex]::Match($Text, '(?m)^permissions:[ \t]*\n((?:  .*\n)+)').Groups[1].Value
        }
    }

    It 'no workflow runs on pull_request_target or workflow_run, which run with the base repository''s secrets' {
        foreach ($name in $script:allWorkflows) {
            $text = Get-WorkflowText $name
            $text | Should -Not -Match 'pull_request_target|workflow_run' -Because $name
        }
    }

    It 'every workflow sets its token''s permissions, and only the shared runner asks for an OpenID Connect token at the top level' {
        foreach ($name in $script:allWorkflows) {
            $text = Get-WorkflowText $name
            $text | Should -Match '(?m)^permissions:' -Because $name
            $top = Get-TopLevelPermission -Text $text
            $top | Should -Match 'contents: read' -Because $name
            $top | Should -Not -Match '(contents|actions|checks|deployments|issues|packages|pull-requests|security-events|statuses|attestations): write' -Because $name
            if ($name -ne 'reusable-demo-run.yml') {
                $top | Should -Not -Match 'id-token' -Because "$name asks for id-token only in the job that signs in"
            }
        }
    }

    It '<_> reaches Azure only by hand or on a schedule, in its environment, with the environment''s secrets' -ForEach $script:callers {
        $text = Get-WorkflowText $_
        $triggers = Get-WorkflowTrigger -Text $text
        if ($_ -eq 'validate.yml') {
            $text | Should -Match "(?ms)^  live:.*?if: github\.event_name == 'workflow_dispatch' && inputs\.live"
        }
        else {
            foreach ($trigger in $triggers) {
                $trigger | Should -BeIn @('workflow_dispatch', 'schedule') -Because $_
            }
        }
        $text | Should -Match '(?ms)^    permissions:\s*\n      contents: read\s*\n      id-token: write'
        $text | Should -Match '(?m)^    secrets: inherit\s*$'
    }

    It 'the shared runner reads the identifiers from environment secrets, never from variables, and refuses the schedule environment outside a schedule' {
        $text = Get-WorkflowText 'reusable-demo-run.yml'
        foreach ($wiring in 'client-id: ${{ secrets.AZURE_CLIENT_ID }}', 'tenant-id: ${{ secrets.AZURE_TENANT_ID }}', 'subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}', 'config-json: ${{ secrets.DBHUB_CONFIG_JSON }}') {
            $text | Should -Match ([regex]::Escape($wiring))
        }
        $text | Should -Not -Match 'vars\.(AZURE_|DBHUB_CONFIG_JSON)'
        $steps = [regex]::Matches($text, '(?m)^      - (?:name|uses): (.+)$') | ForEach-Object { $_.Groups[1].Value }
        $steps[0] | Should -Be 'Refuse the schedule environment outside a schedule'
        $text | Should -Match ([regex]::Escape("if: github.event_name != 'schedule' && vars.DBHUB_SCHEDULE_ENVIRONMENT != '' && inputs.environment == vars.DBHUB_SCHEDULE_ENVIRONMENT"))
    }

    It 'demo-setup masks the identifiers before anything else, azure/login included' {
        $action = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.github/actions/demo-setup/action.yml') -Raw
        $steps = @([regex]::Matches($action, '(?m)^    - name: (.+)$') | ForEach-Object { $_.Groups[1].Value })
        $steps[0] | Should -Be 'Mask the environment''s identifiers'
        $steps.IndexOf('Mask the environment''s identifiers') | Should -BeLessThan $steps.IndexOf('Sign in to Azure with OpenID Connect')
        $action | Should -Match 'Register-DemoLogMask -Value @\(\$env:DBHUB_MASK_CLIENT_ID, \$env:DBHUB_MASK_TENANT_ID, \$env:DBHUB_MASK_SUBSCRIPTION_ID\)'
        $action | Should -Match 'Register-DemoLogMask -Config \$config'
        $action | Should -Not -Match 'vars\.'
    }

    It '<_> uses the schedule environment only when a schedule started it' -ForEach $script:scheduled {
        $text = Get-WorkflowText $_
        $text | Should -Match ([regex]::Escape("environment: `${{ github.event_name == 'schedule' && vars.DBHUB_SCHEDULE_ENVIRONMENT || 'demo' }}"))
    }
}

Describe 'Lifecycle scripts' {
    BeforeAll {
        $configPath = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        $config = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 10)
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'results.jsonl'
    }

    BeforeEach {
        # Mocks run inside the scripts, where $script: is the script's own scope, so they share this table.
        $capture = @{ exported = $null; clipboard = [System.Collections.Generic.List[string]]::new(); sent = '' }
        Mock -CommandName Write-DemoResultReport -MockWith { }
    }

    It 'deploy.ps1 passes its switches and stages through, and drops an empty stage' {
        Mock -CommandName Invoke-DemoDeployment -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/deploy.ps1') -ConfigPath $configPath -Resume -FromStage '' -StopAfter Activity -SkipFabric -OutputPath $outputPath
        $LASTEXITCODE | Should -Be 0
        Should -Invoke -CommandName Invoke-DemoDeployment -Times 1 -Exactly -ParameterFilter { $Resume -and $SkipFabric -and $StopAfter -eq 'Activity' -and -not $PSBoundParameters.ContainsKey('FromStage') }
        Test-Path -LiteralPath $outputPath | Should -BeTrue
    }

    It 'stop-demo.ps1 passes -RemoveT3, -ParkT2, and the Bastion-only cleanup through' {
        Mock -CommandName Stop-DemoEnvironment -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/stop-demo.ps1') -ConfigPath $configPath -RemoveT3 -ParkT2 -OutputPath $outputPath
        Should -Invoke -CommandName Stop-DemoEnvironment -Times 1 -Exactly -ParameterFilter { $RemoveT3 -and $ParkT2 -and -not $RemoveBastionOnly }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/stop-demo.ps1') -ConfigPath $configPath -RemoveBastionOnly -IfExpired -OutputPath $outputPath
        Should -Invoke -CommandName Stop-DemoEnvironment -Times 1 -Exactly -ParameterFilter { $RemoveBastionOnly -and $IfExpired }
    }

    It 'start-demo.ps1 sets no password without -Interactive, and never without a working clipboard' {
        Mock -CommandName Start-DemoEnvironment -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -CommandName Set-DemoVmLocalPassword -MockWith { throw 'should not run' }
        Mock -CommandName Export-DemoResult -MockWith { $capture['exported'] = $Result }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/start-demo.ps1') -ConfigPath $configPath -ResetAdminPassword -SkipCostCheck -OutputPath $outputPath
        ($capture['exported'] | Where-Object { $_.checkId -eq 'START.HOSTPASSWORD' }).status | Should -Be 'Not selected'
        Should -Invoke -CommandName Start-DemoEnvironment -Times 1 -Exactly -ParameterFilter { $SkipCostCheck }

        Mock -CommandName Set-Clipboard -MockWith { throw 'no clipboard here' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/start-demo.ps1') -ConfigPath $configPath -Interactive -ResetAdminPassword -OutputPath $outputPath
        ($capture['exported'] | Where-Object { $_.checkId -eq 'START.HOSTPASSWORD' }).status | Should -Be 'Manual action required'
        ($capture['exported'] | Where-Object { $_.checkId -eq 'START.HOSTPASSWORD' }).remediation | Should -Match 'Reset password'
        Should -Invoke -CommandName Set-DemoVmLocalPassword -Times 0 -Exactly
    }

    It 'start-demo.ps1 puts the one-time password on the clipboard only, never in the results' {
        Mock -CommandName Start-DemoEnvironment -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -CommandName Export-DemoResult -MockWith { $capture['exported'] = $Result }
        Mock -CommandName Set-Clipboard -MockWith { $capture['clipboard'].Add([string]$Value) }
        Mock -CommandName Set-DemoVmLocalPassword -MockWith {
            $capture['sent'] = [System.Net.NetworkCredential]::new('', $Password).Password
            New-DemoResult -CheckId 'START.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'set' -Evidence @{ userName = 'demoadmin' }
        }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/start-demo.ps1') -ConfigPath $configPath -Interactive -ResetAdminPassword -OutputPath $outputPath
        $capture['clipboard'][-1] | Should -Be $capture['sent']
        $capture['sent'].Length | Should -BeGreaterOrEqual 16
        $capture['sent'] | Should -Not -Be 'System.Security.SecureString'
        $capture['clipboard'] | Should -Not -Contain 'System.Security.SecureString'
        ($capture['exported'] | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($capture['sent']))
    }

    It 'start-demo.ps1 with the Key Vault opt-in stores the password before it sets it, and never uses the clipboard' {
        $vaultConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
        $vaultConfig['assignRoles'] = $true
        $vaultConfig['keyVault']['enabled'] = $true
        $vaultConfigPath = Join-Path -Path $TestDrive -ChildPath 'demo.vault.config.json'
        Set-Content -LiteralPath $vaultConfigPath -Value ($vaultConfig | ConvertTo-Json -Depth 10)
        $capture['order'] = [System.Collections.Generic.List[string]]::new()
        $capture['setStatus'] = 'Pass'
        $capture['initStatus'] = 'Pass'
        Mock -CommandName Start-DemoEnvironment -MockWith { New-DemoResult -CheckId 'START.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'ready' -Evidence ([ordered]@{ expiresUtc = '2026-10-21T22:00:00Z' }) }
        Mock -CommandName Export-DemoResult -MockWith { $capture['exported'] = $Result }
        Mock -CommandName Set-Clipboard -MockWith { $capture['clipboard'].Add([string]$Value) }
        Mock -CommandName Initialize-DemoKeyVault -MockWith {
            $capture['order'].Add('Init:' + [bool]$PesterBoundParameters['EnsureOnly'])
            New-DemoResult -CheckId 'INFRA.KEYVAULT' -Area 'infra' -Target 'subscription' -Status $capture['initStatus'] -Message 'vault'
        }
        Mock -CommandName Set-DemoHostPasswordSecret -MockWith {
            $capture['order'].Add('Store:' + $PesterBoundParameters['ExpiresUtc'])
            $capture['stored'] = [System.Net.NetworkCredential]::new('', $Password).Password
            New-DemoResult -CheckId 'START.KEYVAULT' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'stored'
        }
        Mock -CommandName Set-DemoVmLocalPassword -MockWith {
            $capture['order'].Add('Set')
            $capture['sent'] = [System.Net.NetworkCredential]::new('', $Password).Password
            New-DemoResult -CheckId 'START.HOSTPASSWORD' -Area 'infra' -Target 'T2' -Status $capture['setStatus'] -Message 'set' -Evidence @{ userName = 'demoadmin' }
        }
        Mock -CommandName Disable-DemoHostPasswordSecret -MockWith {
            $capture['order'].Add('Disable:' + $PesterBoundParameters['CheckId'])
            New-DemoResult -CheckId $PesterBoundParameters['CheckId'] -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'disabled'
        }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/start-demo.ps1') -ConfigPath $vaultConfigPath -Interactive -ResetAdminPassword -OutputPath $outputPath
        $capture['order'] | Should -Be @('Init:True', 'Store:2026-10-21T22:00:00Z', 'Set')
        $capture['stored'] | Should -BeExactly $capture['sent']
        $capture['stored'] | Should -Not -Be 'System.Security.SecureString'
        $capture['stored'].Length | Should -BeGreaterOrEqual 16
        $capture['clipboard'].Count | Should -Be 0
        ($capture['exported'] | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($capture['stored']))

        # The VM refused the password: the stored copy is disabled at once.
        $capture['order'].Clear()
        $capture['setStatus'] = 'Fail'
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/start-demo.ps1') -ConfigPath $vaultConfigPath -Interactive -ResetAdminPassword -OutputPath $outputPath
        $capture['order'] | Should -Be @('Init:True', 'Store:2026-10-21T22:00:00Z', 'Set', 'Disable:START.KEYVAULT.CLEANUP')

        # No vault or no access: nothing is stored, and nothing is set.
        $capture['order'].Clear()
        $capture['initStatus'] = 'Fail'
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/start-demo.ps1') -ConfigPath $vaultConfigPath -Interactive -ResetAdminPassword -OutputPath $outputPath
        $capture['order'] | Should -Be @('Init:True')
        $LASTEXITCODE | Should -Be 1
    }

    It 'destroy.ps1 passes -IfExpired and the residual-check options through, writes one manifest per environment, and asks unless -Force' {
        Mock -CommandName Remove-DemoEnvironment -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/destroy.ps1') -ConfigPath $configPath -Force -IfExpired -OutputPath $outputPath
        Should -Invoke -CommandName Remove-DemoEnvironment -Times 1 -Exactly -ParameterFilter { $IfExpired -and -not $Confirm -and -not $SkipResidueCheck -and $ResidueWaitMinutes -eq 10 -and $ManifestPath -match 'out[\\/]destroy-manifest-demo\.json$' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/destroy.ps1') -ConfigPath $configPath -Force -SkipResidueCheck -ResidueWaitMinutes 2 -ManifestPath (Join-Path -Path $TestDrive -ChildPath 'm.json') -OutputPath $outputPath
        Should -Invoke -CommandName Remove-DemoEnvironment -Times 1 -Exactly -ParameterFilter { $SkipResidueCheck -and $ResidueWaitMinutes -eq 2 -and $ManifestPath -match 'm\.json$' }
    }

    It 'reset-demo.ps1 and status.ps1 pass their switches through' {
        Mock -CommandName Reset-DemoWorkload -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -CommandName Get-DemoEnvironmentStatus -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/reset-demo.ps1') -ConfigPath $configPath -Target T1 -Reseed -OutputPath $outputPath
        Should -Invoke -CommandName Reset-DemoWorkload -Times 1 -Exactly -ParameterFilter { $Target -eq 'T1' -and $Reseed -and -not $UndoRemediation }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/status.ps1') -ConfigPath $configPath -Detail -OutputPath $outputPath
        Should -Invoke -CommandName Get-DemoEnvironmentStatus -Times 1 -Exactly -ParameterFilter { $Detail }
    }

    It 'demo-control.ps1 takes the workflow''s string inputs' {
        Mock -CommandName Invoke-DemoControl -MockWith { New-DemoResult -CheckId 'TEST.RESULT' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/demo-control.ps1') -ConfigPath $configPath -Target 'T1' -Scenario 'incident:locking-blocking' -Duration '15' -Concurrency '' -Intensity '' -ResetBefore 'true' -AutoCleanup 'false' -OutputPath $outputPath
        Should -Invoke -CommandName Invoke-DemoControl -Times 1 -Exactly -ParameterFilter { $DurationMinutes -eq 15 -and $Concurrency -eq 0 -and $ResetBefore -eq $true -and $AutoCleanup -eq $false }
    }

    It 'demo-control.ps1 and Invoke-DemoControl accept every target demo-control.yml offers, T4 included (Phase 24)' {
        $workflow = Get-WorkflowText 'demo-control.yml'
        $options = @([regex]::Match($workflow, '(?ms)^\s+target:.*?options:\s*\n((?:\s+- \S+\s*\n)+)').Groups[1].Value -split '\n' | ForEach-Object { $_.Trim().TrimStart('-').Trim() } | Where-Object { $_ })
        $options | Should -Contain 'T4'
        $script = (Get-Command -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/demo-control.ps1')).Parameters['Target'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $module = (Get-Command -Name Invoke-DemoControl).Parameters['Target'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        foreach ($option in $options) {
            $script.ValidValues | Should -Contain $option -Because "demo-control.yml offers $option"
            $module.ValidValues | Should -Contain $option -Because "demo-control.yml offers $option"
        }
    }

    It 'exits 1 when a result is Fail' {
        Mock -CommandName Get-DemoEnvironmentStatus -MockWith { New-DemoResult -CheckId 'STATUS.T3' -Area 't3' -Target 'T3' -Status 'Fail' -Message 'broken' }
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/status.ps1') -ConfigPath $configPath -OutputPath $outputPath
        $LASTEXITCODE | Should -Be 1
    }
}
