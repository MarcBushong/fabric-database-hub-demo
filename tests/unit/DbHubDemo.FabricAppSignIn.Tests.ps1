BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one digit.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        return $config
    }

    # A stand-in for the sign-in's process: HasExited, ExitCode, and Kill, which records that it was called.
    function New-TestProcess([bool] $Exited = $false, [int] $ExitCode = 0) {
        $process = [pscustomobject]@{ HasExited = $Exited; ExitCode = $ExitCode; Killed = $false }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($Tree) $this.Killed = [bool]$Tree; $this.HasExited = $true; $this.ExitCode = -1 }
        return $process
    }

    function New-TestModelFile {
        $path = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $path } { Initialize-DemoProgress -Path $Path -Model (New-DemoProgressModel -Catalog (Get-DemoProgressCatalog)) -Confirm:$false }
        return $path
    }

    function Get-TestRow([string] $Path, [string] $Id) {
        $model = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        foreach ($track in @($model['tracks'])) {
            foreach ($item in @($track['steps'])) {
                if ([string]$item['id'] -eq $Id) {
                    return $item
                }
            }
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Start-DemoFabricAppSignIn: the Insights app''s sign-in starts alongside the deployment (2026-11-05)' {
    BeforeEach {
        $config = New-TestConfig
        $script:progress = New-TestModelFile
        $script:started = 0
        $script:fake = New-TestProcess
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoConsoleBlock -MockWith { $script:console = @($Line) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAttention -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { '' }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInProcess -MockWith { $script:started++; $script:fake }
    }

    It 'starts nothing in a session that can''t answer a browser sign-in, and says why' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $false }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $script:started | Should -Be 0
        $state.Done | Should -BeTrue
        $state.Result.checkId | Should -Be 'DEPLOY.FABRIC.APPSIGNIN'
        $state.Result.status | Should -Be 'Not supported'
        $state.Result.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Skipped'
        # Its record is handed out once.
        $first = @(InModuleScope DbHubDemo -Parameters @{ State = $state } { Complete-DemoFabricAppSignIn -SignIn $State })
        $first.Count | Should -Be 1
        @(InModuleScope DbHubDemo -Parameters @{ State = $state } { Complete-DemoFabricAppSignIn -SignIn $State }).Count | Should -Be 0
    }

    It 'opens no browser when the stage''s CLI is already signed in to the demo''s tenant' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Data = @{ status = 'ok'; tenant = '66666666-7777-8888-9999-000000000000' } } }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $script:started | Should -Be 0
        $state.Result.status | Should -Be 'Pass'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Done'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'login status --json' -and $TimeoutSeconds -le 30 }
    }

    It 'starts the sign-in without waiting for it, says so on the page and the console, and records its deadline for the app''s step' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ''; Data = @{ status = 'not-signed-in' } } }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -TimeoutMinutes 15 -Confirm:$false }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'nothing waits for the sign-in'
        $script:started | Should -Be 1
        $state.Done | Should -BeFalse
        $state.Process | Should -Be $script:fake
        $state.TenantId | Should -Be '66666666-7777-8888-9999-000000000000' -Because 'Complete-DemoFabricAppSignIn reads the CLI''s status for that tenant'
        $row = Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn'
        $row['state'] | Should -Be 'Running'
        $row['message'] | Should -Match 'The deployment goes on meanwhile; only the Insights app waits for it'
        $model = Get-Content -LiteralPath $script:progress -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        [long]$model['run']['appSignInUntil'] | Should -BeGreaterThan ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 14 * 60)
        ($script:console -join ' ') | Should -Match 'ONE SIGN-IN FOR THE INSIGHTS APP'
        ($script:console -join ' ') | Should -Match 'the deployment still finishes'
        # While it runs: nothing to hand out yet.
        @(InModuleScope DbHubDemo -Parameters @{ State = $state; Path = $script:progress } { Complete-DemoFabricAppSignIn -SignIn $State -ProgressPath $Path }).Count | Should -Be 0
        InModuleScope DbHubDemo { Stop-DemoFabricAppSignIn }
        $script:fake.Killed | Should -BeTrue -Because 'the run''s end stops a sign-in that''s still open'
    }

    It 'gives a Warning, never a Fail, without a tenant or when the sign-in can''t start' {
        $noTenant = New-TestConfig
        $noTenant['tenantId'] = ''
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $noTenant } { Start-DemoFabricAppSignIn -Config $Config -Confirm:$false }
        $state.Result.status | Should -Be 'Warning'
        Mock -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInProcess -MockWith { throw 'npx wasn''t found on PATH. Install Node.js 20, 22, 24 (LTS), which includes npm and npx.' }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $state.Result.status | Should -Be 'Warning'
        $state.Result.message | Should -Match 'npx wasn''t found on PATH'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Action needed'
    }

    It 'starts nothing with -WhatIf' {
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Start-DemoFabricAppSignIn -Config $Config -WhatIf }
        $script:started | Should -Be 0
        $state.Result.status | Should -Be 'Not selected'
    }
}

Describe 'Complete-DemoFabricAppSignIn: settled once, from its exit code or its deadline (2026-11-05)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:progress = New-TestModelFile
        $script:newState = {
            param([object] $Process, [int] $MinutesLeft = 10)
            [pscustomobject]@{ Process = $Process; TenantId = '66666666-7777-8888-9999-000000000000'; StartedUtc = [DateTime]::UtcNow; DeadlineUtc = [DateTime]::UtcNow.AddMinutes($MinutesLeft); TimeoutMinutes = 15; Done = $false; Reported = $false; Result = $null }
        }
        $script:complete = { param([object] $State, [switch] $Final, [switch] $Wait) @(InModuleScope DbHubDemo -Parameters @{ State = $State; Path = $script:progress; Final = [bool]$Final; Wait = [bool]$Wait } { Complete-DemoFabricAppSignIn -SignIn $State -ProgressPath $Path -Final:$Final -Wait:$Wait }) }
        # What the CLI's own status says when the sign-in didn't finish (Get-DemoRayfinSignInState): not signed in, unless
        # a test says otherwise.
        $script:cliState = 'NotSignedIn'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinSignInState -MockWith { $script:cliState }
    }

    It 'is Pass when the person signed in (exit code 0), handed out once' {
        $state = & $script:newState (New-TestProcess -Exited $true -ExitCode 0)
        $first = @(& $script:complete $state)
        $first.Count | Should -Be 1
        $first[0].status | Should -Be 'Pass'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Done'
        @(& $script:complete $state).Count | Should -Be 0
    }

    It 'is a Warning, and the row Action needed, when the sign-in was closed or failed' {
        $state = & $script:newState (New-TestProcess -Exited $true -ExitCode 3)
        $result = @(& $script:complete $state)
        $result[0].status | Should -Be 'Warning'
        $result[0].message | Should -Match 'exit code 3'
        $result[0].message | Should -Match 'The deployment went on'
        $result[0].message | Should -Match 'without the sign-in the Insights app isn''t created'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Action needed'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRayfinSignInState -Times 1 -Exactly -ParameterFilter { $TenantId -eq '66666666-7777-8888-9999-000000000000' }
    }

    It 'is Pass, not a Warning, when the window was closed but the CLI is signed in to the demo''s tenant anyway (live, 2026-11-06)' {
        # The live run: the window that opened no browser was closed (-1) after a separate rayfin login had signed in.
        $script:cliState = 'SignedIn'
        $state = & $script:newState (New-TestProcess -Exited $true -ExitCode -1)
        $result = @(& $script:complete $state)
        $result.Count | Should -Be 1
        $result[0].status | Should -Be 'Pass'
        $result[0].message | Should -BeExactly 'The Rayfin CLI is signed in to the demo''s tenant (its sign-in window was closed, with exit code -1, but a sign-in already exists); the Insights app''s step uses it.'
        $row = Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn'
        $row['state'] | Should -Be 'Done'
        $row['message'] | Should -Not -Match 'isn''t created'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRayfinSignInState -Times 1 -Exactly -ParameterFilter { $TenantId -eq '66666666-7777-8888-9999-000000000000' }
    }

    It 'is Pass when a window stopped at its deadline, or once the tracks are done, finds the CLI signed in anyway' {
        $script:cliState = 'SignedIn'
        $late = New-TestProcess
        $result = @(& $script:complete (& $script:newState $late -MinutesLeft -1))
        $late.Killed | Should -BeTrue
        $result[0].status | Should -Be 'Pass'
        $result[0].message | Should -Match 'its sign-in window was still open, so it was stopped, but a sign-in already exists'
        $open = New-TestProcess
        $result = @(& $script:complete (& $script:newState $open) -Final)
        $open.Killed | Should -BeTrue
        $result[0].status | Should -Be 'Pass'
    }

    It 'says so when the CLI''s status couldn''t be read, instead of claiming there''s no sign-in' {
        $script:cliState = 'Unknown'
        $result = @(& $script:complete (& $script:newState (New-TestProcess -Exited $true -ExitCode -1)))
        $result[0].status | Should -Be 'Warning'
        $result[0].message | Should -Match '^The Rayfin CLI''s sign-in ended with exit code -1: it was closed, cancelled, or failed\. Whether the CLI is signed in another way couldn''t be read'
        $result[0].message | Should -Match 'uses a sign-in this machine already has, if any'
        $result[0].message | Should -Not -Match 'isn''t created'
        $result[0].remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
    }

    It 'doesn''t read the CLI''s status when the sign-in finished, or after Ctrl+C, so a stop stays quick' {
        $null = @(& $script:complete (& $script:newState (New-TestProcess -Exited $true -ExitCode 0)))
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        $result = @(& $script:complete (& $script:newState (New-TestProcess)) -Final)
        $result[0].status | Should -Be 'Warning'
        $result[0].message | Should -Match 'couldn''t be read'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRayfinSignInState -Times 0 -Exactly
    }

    It 'stops a sign-in nobody finished by its deadline, and one still open once the tracks are done' {
        $late = New-TestProcess
        $state = & $script:newState $late -MinutesLeft -1
        $result = @(& $script:complete $state)
        $late.Killed | Should -BeTrue
        $result[0].status | Should -Be 'Warning'
        $result[0].message | Should -Match 'Nobody finished the Rayfin CLI''s sign-in within 15 minutes, so it was stopped'

        $open = New-TestProcess
        $state = & $script:newState $open
        @(& $script:complete $state).Count | Should -Be 0 -Because 'it still runs, before its deadline'
        $open.Killed | Should -BeFalse
        $result = @(& $script:complete $state -Final)
        $open.Killed | Should -BeTrue
        $result[0].message | Should -Match 'still open when the Insights app''s step was over'
    }

    It 'waits for it with -Wait, at most until its deadline (deploy.ps1 -Sequential)' {
        $script:polls = 0
        $slow = New-TestProcess
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {
            $script:polls++
            if ($script:polls -ge 3) {
                $slow.HasExited = $true
            }
        }
        $state = & $script:newState $slow
        $result = @(& $script:complete $state -Wait)
        $script:polls | Should -Be 3
        $result[0].status | Should -Be 'Pass'
        $slow.Killed | Should -BeFalse
    }
}

Describe 'Get-DemoRayfinSignInState: the CLI''s own status, never a browser, bounded, and never an exception (2026-11-06)' {
    BeforeAll {
        $script:tenant = '66666666-7777-8888-9999-000000000000'
        $script:read = { param([string] $Tenant = $script:tenant) InModuleScope DbHubDemo -Parameters @{ Tenant = $Tenant } { Get-DemoRayfinSignInState -TenantId $Tenant } }
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:stageCli = ''
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { $script:stageCli }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Data = @{ status = 'ok'; identityType = 'user'; tenant = '66666666-7777-8888-9999-000000000000' } } }
        $script:npxOut = '{"status":"ok","identityType":"user","tenant":"66666666-7777-8888-9999-000000000000"}'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = $script:npxOut; StdErr = '' } }
    }

    It 'reads the stage''s pinned CLI when it''s installed, within a minute' {
        $script:stageCli = 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js'
        & $script:read | Should -Be 'SignedIn'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'login status --json' -and $TimeoutSeconds -le 60 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 0 -Exactly
    }

    It 'without a stage (a first run), reads the same pinned CLI through npx, from npm''s cache, within a minute' {
        # npm can print warnings before the CLI's JSON.
        $script:npxOut = "npm warn exec The following package was not found and will be installed`n" + $script:npxOut
        & $script:read | Should -Be 'SignedIn'
        $settings = InModuleScope DbHubDemo { Get-DemoFabricAppSetting }
        $expected = '--yes --prefer-offline --package={0}@{1} -- rayfin login status --json' -f $settings['cliPackage'], $settings['cliVersion']
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 1 -Exactly -ParameterFilter {
            $Tool -eq 'npx' -and ($ArgumentList -join ' ') -eq $expected -and $TimeoutSeconds -le 60 -and
            $Environment['RAYFIN_TELEMETRY_OPTOUT'] -eq '1' -and $Environment.Contains('RAYFIN_TOKEN') -and $null -eq $Environment['RAYFIN_TOKEN']
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 0 -Exactly
    }

    It 'is NotSignedIn when <Case>' -ForEach @(
        @{ Case = 'the CLI isn''t signed in'; Out = '{"status":"not-signed-in","command":"login status","recovery":"Run ''rayfin login'' to authenticate."}' }
        @{ Case = 'it''s signed in to another tenant'; Out = '{"status":"ok","identityType":"user","tenant":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}' }
    ) {
        $script:npxOut = $Out
        & $script:read | Should -Be 'NotSignedIn'
    }

    It 'is Unknown, without an exception, when <Case>' -ForEach @(
        @{ Case = 'the npx call timed out'; Out = '' }
        @{ Case = 'the output isn''t JSON'; Out = 'npm error code ENOTCACHED' }
        @{ Case = 'the CLI reports an error'; Out = '{"status":"error","error":"Sign-in tenant differs from the configured tenant."}' }
        @{ Case = 'npx can''t run'; Out = 'THROW' }
        @{ Case = 'the stage''s CLI throws'; Out = 'STAGE-THROW' }
    ) {
        $script:npxOut = $Out
        if ($Out -eq 'THROW') {
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { throw 'npx was not found on PATH. Install Node.js 20, 22, 24, which includes npm.' }
        }
        if ($Out -eq 'STAGE-THROW') {
            $script:stageCli = 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js'
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { throw 'node did not finish within 60 seconds and was stopped.' }
        }
        { & $script:read } | Should -Not -Throw
        & $script:read | Should -Be 'Unknown'
    }

    It 'is Unknown without a tenant, and runs nothing' {
        & $script:read '' | Should -Be 'Unknown'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 0 -Exactly
    }
}

Describe 'Wait-DemoFabricAppSignIn: only the Insights app''s step waits, and only until the deadline (2026-11-05)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:progress = New-TestModelFile
    }

    It 'doesn''t wait without a model, or while the sign-in isn''t running' {
        (InModuleScope DbHubDemo { Wait-DemoFabricAppSignIn -ProgressPath '' }) | Should -Be 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { throw 'no wait expected' }
        (InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Wait-DemoFabricAppSignIn -ProgressPath $Path }) | Should -Be 0
    }

    It 'waits while it runs, until deploy.ps1 settles it, and says so on the app''s row' {
        $until = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 600
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress; Until = $until } {
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ appSignInUntil = $Until })
            Set-DemoProgressStep -Path $Path -Id 'Fabric.AppSignIn' -State 'Running' -Message 'A browser opens for your sign-in.'
        }
        $script:polls = 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {
            $script:polls++
            if ($script:polls -eq 2) {
                # deploy.ps1 settles the sign-in meanwhile.
                & (Get-Module -Name DbHubDemo) { param($p) Set-DemoProgressStep -Path $p -Id 'Fabric.AppSignIn' -State 'Done' -Status 'Pass' -Message 'Signed in.' } $script:progress
            }
        }
        $null = InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Wait-DemoFabricAppSignIn -ProgressPath $Path -PollSeconds 1 }
        $script:polls | Should -Be 2
        (Get-TestRow -Path $script:progress -Id 'Fabric.App')['message'] | Should -Match 'Waiting for the Rayfin CLI''s sign-in in the browser, at most until'
    }

    It 'doesn''t wait past the deadline' {
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress; Until = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1) } {
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ appSignInUntil = $Until })
            Set-DemoProgressStep -Path $Path -Id 'Fabric.AppSignIn' -State 'Running' -Message 'A browser opens for your sign-in.'
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { throw 'no wait expected' }
        (InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Wait-DemoFabricAppSignIn -ProgressPath $Path }) | Should -Be 0
    }
}

Describe 'Start-DemoRayfinSignInProcess' {
    BeforeAll {
        # Its BROWSER check reads this process's environment (Get-DemoRayfinSignInEnvironment): none here, whatever the
        # terminal that runs the tests has.
        $script:browserOutside = [System.Environment]::GetEnvironmentVariable('BROWSER')
        [System.Environment]::SetEnvironmentVariable('BROWSER', $null)
    }

    AfterAll {
        [System.Environment]::SetEnvironmentVariable('BROWSER', $script:browserOutside)
    }

    It 'runs the pinned CLI''s sign-in through npx, in a window of its own on Windows, with the telemetry off and no ambient token' {
        $script:startArguments = $null
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'npx' } -MockWith { [pscustomobject]@{ Source = 'C:\nodejs\npx.cmd' } }
        Mock -ModuleName DbHubDemo -CommandName Start-Process -MockWith { $script:startArguments = $PesterBoundParameters; [pscustomobject]@{ Handle = [System.IntPtr]::Zero; HasExited = $false } }
        $null = InModuleScope DbHubDemo { Start-DemoRayfinSignInProcess -TenantId '66666666-7777-8888-9999-000000000000' }
        $settings = InModuleScope DbHubDemo { Get-DemoFabricAppSetting }
        $script:startArguments['FilePath'] | Should -Be 'C:\nodejs\npx.cmd'
        @($script:startArguments['ArgumentList']) | Should -Be @('--yes', ('--package={0}@{1}' -f $settings['cliPackage'], $settings['cliVersion']), '--', 'rayfin', 'login', '--tenant', '66666666-7777-8888-9999-000000000000')
        $script:startArguments['Environment']['RAYFIN_TELEMETRY_OPTOUT'] | Should -Be '1'
        $script:startArguments['Environment'].Contains('RAYFIN_TOKEN') | Should -BeTrue
        $script:startArguments['Environment']['RAYFIN_TOKEN'] | Should -BeNullOrEmpty
        $script:startArguments.ContainsKey('Wait') | Should -BeFalse -Because 'nothing waits for it'
        $script:startArguments.ContainsKey('NoNewWindow') | Should -Be (-not $IsWindows)
    }

    It 'throws, naming Node.js, when npx isn''t on PATH' {
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'npx' } -MockWith { }
        { InModuleScope DbHubDemo { Start-DemoRayfinSignInProcess -TenantId '66666666-7777-8888-9999-000000000000' } } | Should -Throw '*npx wasn''t found on PATH*'
    }
}

Describe 'The Rayfin CLI''s sign-in and BROWSER: one the CLI can''t start is removed for its process only (live finding, 2026-11-06)' {
    BeforeAll {
        $script:browserBefore = [System.Environment]::GetEnvironmentVariable('BROWSER')
        # The live run's value: a command line set for az login, which Python's webbrowser module accepts. The Rayfin CLI
        # runs "<BROWSER>" "<url>", so nothing opened.
        $script:liveBrowser = '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --inprivate %s'
        $script:environmentFor = {
            param([string] $WorkingDirectory)
            InModuleScope DbHubDemo -Parameters @{ Dir = $WorkingDirectory } { Get-DemoRayfinSignInEnvironment -WorkingDirectory $Dir }
        }
    }

    AfterAll {
        [System.Environment]::SetEnvironmentVariable('BROWSER', $script:browserBefore)
    }

    BeforeEach {
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add(('{0}: {1}' -f $Level, $Message)) }
        # A stand-in for a dev container's browser helper: a file that exists.
        $script:helper = Join-Path -Path $TestDrive -ChildPath 'tools/browser-helper.sh'
        $null = New-Item -ItemType File -Path $script:helper -Force
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable('BROWSER', $script:browserBefore)
    }

    It 'removes a BROWSER that isn''t a program for the CLI only, says so in one line, and leaves the caller''s as it was: <Case>' -ForEach @(
        @{ Case = 'the live run''s command line for az login'; Value = '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --inprivate %s' }
        @{ Case = 'a program name with arguments'; Value = 'msedge --inprivate %s' }
        @{ Case = 'a list of browsers'; Value = 'firefox:chromium' }
        @{ Case = 'a file that doesn''t exist'; Value = '<TestDrive>/tools/missing-browser.exe' }
        @{ Case = 'a folder'; Value = '<TestDrive>/tools' }
        @{ Case = 'blank'; Value = ' ' }
    ) {
        $browser = $Value.Replace('<TestDrive>', $TestDrive)
        $env:BROWSER = $browser
        $environment = & $script:environmentFor $TestDrive
        $environment.ContainsKey('BROWSER') | Should -BeTrue
        $environment['BROWSER'] | Should -BeNullOrEmpty -Because 'a $null value removes it from the CLI''s process (Start-Process -Environment)'
        $environment['RAYFIN_TELEMETRY_OPTOUT'] | Should -Be '1'
        $environment.ContainsKey('RAYFIN_TOKEN') | Should -BeTrue
        $environment['RAYFIN_TOKEN'] | Should -BeNullOrEmpty
        $environment['NO_COLOR'] | Should -Be '1'
        $env:BROWSER | Should -BeExactly $browser -Because 'the caller''s own environment never changes'
        $script:logged.Count | Should -Be 1
        $script:logged[0] | Should -Match '^Warning: The Rayfin CLI can''t open its sign-in page with BROWSER'
        $script:logged[0] | Should -Match 'opens your default browser instead \(for the CLI only; BROWSER stays as it is in this terminal\)'
    }

    It 'keeps a BROWSER that''s the path of an existing file, such as a dev container''s helper, a relative one from the CLI''s working directory too' {
        foreach ($browser in @($script:helper, 'tools/browser-helper.sh')) {
            $env:BROWSER = $browser
            (& $script:environmentFor $TestDrive).ContainsKey('BROWSER') | Should -BeFalse -Because ('{0} reaches the CLI as it is' -f $browser)
            $env:BROWSER | Should -BeExactly $browser
        }
        $script:logged.Count | Should -Be 0
        # The same relative path names no file from another working directory.
        $env:BROWSER = 'tools/browser-helper.sh'
        (& $script:environmentFor (Join-Path -Path $TestDrive -ChildPath 'tools')).ContainsKey('BROWSER') | Should -BeTrue
    }

    It 'keeps a BROWSER that''s a program on PATH' {
        $program = if ($IsWindows) { 'cmd' } else { 'sh' }
        $env:BROWSER = $program
        (& $script:environmentFor $TestDrive).ContainsKey('BROWSER') | Should -BeFalse
        $env:BROWSER | Should -BeExactly $program
        $script:logged.Count | Should -Be 0
    }

    It 'leaves an unset BROWSER alone' {
        [System.Environment]::SetEnvironmentVariable('BROWSER', $null)
        (& $script:environmentFor $TestDrive).ContainsKey('BROWSER') | Should -BeFalse
        [System.Environment]::GetEnvironmentVariable('BROWSER') | Should -BeNullOrEmpty
        $script:logged.Count | Should -Be 0
    }

    It 'is what both sign-ins give the CLI: deploy.ps1''s (Start-DemoRayfinSignInProcess) and -SignIn''s (Invoke-DemoRayfinInteractive)' {
        $script:starts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'npx' } -MockWith { [pscustomobject]@{ Source = 'C:\nodejs\npx.cmd' } }
        Mock -ModuleName DbHubDemo -CommandName Start-Process -MockWith { $script:starts.Add($PesterBoundParameters); [pscustomobject]@{ Handle = [System.IntPtr]::Zero; HasExited = $true; ExitCode = 0 } }
        $tenant = '66666666-7777-8888-9999-000000000000'
        $rayfinSignIn = @('login', '--tenant', $tenant)
        foreach ($browser in @($script:liveBrowser, $script:helper)) {
            $env:BROWSER = $browser
            $null = InModuleScope DbHubDemo -Parameters @{ Tenant = $tenant } { Start-DemoRayfinSignInProcess -TenantId $Tenant }
            $null = InModuleScope DbHubDemo -Parameters @{ Dir = $TestDrive; SignIn = $rayfinSignIn } { Invoke-DemoRayfinInteractive -NodePath 'node' -CliPath 'C:\stage\node_modules\@microsoft\rayfin-cli\scripts\main' -ArgumentList $SignIn -WorkingDirectory $Dir }
            $env:BROWSER | Should -BeExactly $browser -Because 'neither sign-in changes the caller''s environment'
        }
        $script:starts.Count | Should -Be 4
        foreach ($start in $script:starts[0..1]) {
            $start['Environment'].ContainsKey('BROWSER') | Should -BeTrue
            $start['Environment']['BROWSER'] | Should -BeNullOrEmpty
            $start['Environment']['RAYFIN_TELEMETRY_OPTOUT'] | Should -Be '1'
        }
        foreach ($start in $script:starts[2..3]) {
            $start['Environment'].ContainsKey('BROWSER') | Should -BeFalse -Because 'a usable BROWSER reaches the CLI'
        }
        $script:starts[1].ContainsKey('NoNewWindow') | Should -BeTrue -Because '-SignIn runs the CLI in this console'
        $script:starts[1].ContainsKey('Wait') | Should -BeTrue
        $script:logged.Count | Should -Be 2 -Because 'each sign-in with the unusable BROWSER says so once'
    }

    It 'leaves BROWSER out of a real child process, and in the caller''s environment (Start-Process -Environment)' {
        $env:BROWSER = $script:liveBrowser
        $environment = & $script:environmentFor $TestDrive
        $out = Join-Path -Path $TestDrive -ChildPath 'child-environment.txt'
        $probe = '[Console]::Out.Write(''BROWSER=['' + [System.Environment]::GetEnvironmentVariable(''BROWSER'') + ''] RAYFIN_TELEMETRY_OPTOUT=['' + $env:RAYFIN_TELEMETRY_OPTOUT + '']'')'
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded -Environment $environment -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out
        $child.ExitCode | Should -Be 0
        Get-Content -LiteralPath $out -Raw | Should -BeExactly 'BROWSER=[] RAYFIN_TELEMETRY_OPTOUT=[1]'
        $env:BROWSER | Should -BeExactly $script:liveBrowser
    }
}

Describe 'Test-DemoFabricAppTenantSetting: preflight''s look at P12 and P13, never more than a Warning (2026-11-05)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:settingsAnswer = 'Both'
        Initialize-HubFabricMock -Handler {
            switch ($script:settingsAnswer) {
                'Forbidden' { ConvertTo-HubFabricResponse -StatusCode 403 -Body @{ errorCode = 'Forbidden'; message = 'The caller is not a Fabric administrator' } }
                'Off' { ConvertTo-HubFabricResponse -Body @{ value = @(@{ title = 'Fabric Apps (preview)'; enabled = $false }, @{ title = 'Semantic Model Execute Queries REST API'; enabled = $true }) } }
                'Groups' { ConvertTo-HubFabricResponse -Body @{ value = @(@{ title = 'Fabric Apps (preview)'; enabled = $true; enabledSecurityGroups = @(@{ name = 'sg-demo' }) }, @{ title = 'Dataset Execute Queries REST API'; enabled = $true }) } }
                'Missing' { ConvertTo-HubFabricResponse -Body @{ value = @(@{ title = 'Dataset Execute Queries REST API'; enabled = $true }) } }
                default { ConvertTo-HubFabricResponse -Body @{ value = @(@{ title = 'Fabric Apps (preview)'; enabled = $true }, @{ title = 'Dataset Execute Queries REST API'; enabled = $true }) } }
            }
        }
        $script:check = { InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Test-DemoFabricAppTenantSetting -Config $Config } }
    }

    It 'is Pass when both are on for the organization, read once through the admin API' {
        $result = & $script:check
        $result.checkId | Should -Be 'PREFLIGHT.FABRIC.APPSETTINGS'
        $result.status | Should -Be 'Pass'
        @($result.evidence.on).Count | Should -Be 2
        @($script:HubFabricCalls | Where-Object { $_.Uri -like '*/admin/tenantsettings*' }).Count | Should -Be 1
    }

    It 'is a Warning that names what''s off, matched by an alternate title too' {
        $script:settingsAnswer = 'Off'
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'off: Fabric Apps \(preview\)'
        $result.message | Should -Match 'doesn''t keep the run from DONE'
        $result.remediation | Should -Match 'Fabric admin portal'
        @($result.evidence.on) | Should -Be @('Dataset Execute Queries REST API')
    }

    It 'is a Warning, never Manual action required or Fail, when on only for groups, not found, or not readable' -ForEach @('Groups', 'Missing', 'Forbidden') {
        $script:settingsAnswer = $_
        $result = & $script:check
        $result.status | Should -Be 'Warning'
        switch ($_) {
            'Groups' { $result.message | Should -Match 'only for security groups.*Fabric Apps \(preview\) \(only for sg-demo\)' }
            'Missing' { $result.message | Should -Match 'not found among the 1 settings' }
            'Forbidden' { $result.message | Should -Match 'needs a Fabric administrator; HTTP 403' }
        }
    }
}
