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

    # A stand-in for a read of the CLI's sign-in (Start-DemoRayfinSignInStatus) that hasn't answered yet.
    function New-TestStatusRead([string] $TenantId = '66666666-7777-8888-9999-000000000000', [int] $TimeoutSeconds = 90) {
        [pscustomobject]@{ TenantId = $TenantId; Via = 'the stage''s CLI'; Run = $null; StartedUtc = [DateTime]::UtcNow; TimeoutSeconds = $TimeoutSeconds; Error = ''; Result = $null }
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
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add(('{0}: {1}' -f $(if ($PesterBoundParameters.ContainsKey('Level')) { $Level } else { 'Info' }), $Message)) }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoConsoleBlock -MockWith { $script:console = @($Line) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAttention -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInProcess -MockWith { $script:started++; $script:fake }
        # The CLI's own status (Start- and Receive-DemoRayfinSignInStatus, tested below): not signed in, unless a test says
        # otherwise, and already answered.
        $script:cli = [pscustomobject]@{ State = 'NotSignedIn'; Detail = 'not signed in'; Seconds = 9; Via = 'the stage''s CLI' }
        $script:stillReading = $false
        $script:rowWhileReading = $null
        Mock -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -MockWith { New-TestStatusRead -TenantId $TenantId -TimeoutSeconds $TimeoutSeconds }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRayfinSignInStatusRunning -MockWith { $script:stillReading }
        Mock -ModuleName DbHubDemo -CommandName Receive-DemoRayfinSignInStatus -MockWith { $script:rowWhileReading = Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn'; $script:cli }
        Mock -ModuleName DbHubDemo -CommandName Stop-DemoRayfinSignInStatus -MockWith { }
        # Fabric refused the Azure CLI's token for the demo's tenant in an earlier run (out/fabric-app-auth.json), so the
        # CLI's own sign-in starts at the run's start; the default since 2026-11-09, no sign-in, is tested on its own.
        $script:record = [pscustomobject]@{ Outcome = 'Refused'; Reason = 'HTTP 401 Unauthorized'; TenantId = '66666666-7777-8888-9999-000000000000'; CheckedUtc = '2026-11-09T12:00:00.0000000Z' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinAuthRecord -MockWith { $script:record }
    }

    It 'opens no browser, reads nothing, and says it''s not needed by default: the app''s step uses your az login (2026-11-09, user-directed): <Case>' -ForEach @(
        @{ Case = 'nothing recorded (a first run)'; Outcome = ''; Tenant = ''; Accepted = $false }
        @{ Case = 'Fabric accepted the Azure CLI''s token'; Outcome = 'Accepted'; Tenant = '66666666-7777-8888-9999-000000000000'; Accepted = $true }
        @{ Case = 'a refusal for another tenant'; Outcome = 'Refused'; Tenant = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; Accepted = $false }
    ) {
        $script:record = [pscustomobject]@{ Outcome = $Outcome; Reason = ''; TenantId = $Tenant; CheckedUtc = '' }
        $early = New-TestStatusRead
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress; Check = $early } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Check $Check -Confirm:$false }
        $script:started | Should -Be 0 -Because 'no browser opens by default'
        $state.Done | Should -BeTrue
        $state.Process | Should -BeNullOrEmpty
        $state.Result.checkId | Should -Be 'DEPLOY.FABRIC.APPSIGNIN'
        $state.Result.status | Should -Be 'Not selected'
        $state.Result.message | Should -Match '^Not needed: the Insights app''s step gives the Rayfin CLI your Azure CLI sign-in \(az login\)'
        ($state.Result.message -match 'Fabric accepted it in the last deployment') | Should -Be $Accepted
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Skipped'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Receive-DemoRayfinSignInStatus -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Stop-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($Status, $early) }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoConsoleBlock -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAttention -Times 0 -Exactly
        $model = Get-Content -LiteralPath $script:progress -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        [long]$model['run']['appSignInUntil'] | Should -Be 0 -Because 'the app''s step waits for no sign-in'
    }

    It 'needs no interactive session by default: CI and assistants get Not selected, not Not supported' {
        $script:record = [pscustomobject]@{ Outcome = ''; Reason = ''; TenantId = ''; CheckedUtc = '' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $false }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $state.Result.status | Should -Be 'Not selected'
        $script:started | Should -Be 0
    }

    It 'starts nothing in a session that can''t answer a browser sign-in, and says why' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $false }
        $early = New-TestStatusRead
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress; Check = $early } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Check $Check -Confirm:$false }
        $script:started | Should -Be 0
        $state.Done | Should -BeTrue
        $state.Result.checkId | Should -Be 'DEPLOY.FABRIC.APPSIGNIN'
        $state.Result.status | Should -Be 'Not supported'
        $state.Result.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Skipped'
        Should -Invoke -ModuleName DbHubDemo -CommandName Stop-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($Status, $early) }
        Should -Invoke -ModuleName DbHubDemo -CommandName Receive-DemoRayfinSignInStatus -Times 0 -Exactly
        # Its record is handed out once.
        $first = @(InModuleScope DbHubDemo -Parameters @{ State = $state } { Complete-DemoFabricAppSignIn -SignIn $State })
        $first.Count | Should -Be 1
        @(InModuleScope DbHubDemo -Parameters @{ State = $state } { Complete-DemoFabricAppSignIn -SignIn $State }).Count | Should -Be 0
    }

    It 'opens no browser when the CLI is already signed in to the demo''s tenant, read within 90 seconds, and says so' {
        $script:cli = [pscustomobject]@{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant'; Seconds = 9; Via = 'the stage''s CLI' }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $script:started | Should -Be 0
        $state.Result.status | Should -Be 'Pass'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Done'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { $TenantId -eq '66666666-7777-8888-9999-000000000000' -and $TimeoutSeconds -eq 90 }
        $script:logged | Should -Contain 'Info: The Rayfin CLI is already signed in to the demo''s tenant (rayfin login status through the stage''s CLI, 9 seconds), so no browser opens for the Insights app.'
    }

    It 'starts the sign-in without waiting for it, says so on the page and the console, and records its deadline for the app''s step' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -TimeoutMinutes 15 -Confirm:$false }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'nothing waits for the sign-in'
        $script:started | Should -Be 1
        $state.Done | Should -BeFalse
        $state.Process | Should -Be $script:fake
        $state.TenantId | Should -Be '66666666-7777-8888-9999-000000000000' -Because 'Complete-DemoFabricAppSignIn reads the CLI''s status for that tenant'
        $script:logged | Should -Contain 'Info: The Rayfin CLI is not signed in (rayfin login status through the stage''s CLI, 9 seconds), so its sign-in for the Insights app starts: a browser opens.'
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

    It 'gives a Warning, never a Fail, when the sign-in can''t start, and needs none without a tenant' {
        $noTenant = New-TestConfig
        $noTenant['tenantId'] = ''
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $noTenant } { Start-DemoFabricAppSignIn -Config $Config -Confirm:$false }
        $state.Result.status | Should -Be 'Not selected' -Because 'a refusal is recorded for a tenant, and there''s none'
        Mock -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInProcess -MockWith { throw 'The Insights app''s stage (out/fabric-app) has no Rayfin CLI yet; the app''s step installs it from the lock file.' }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $state.Result.status | Should -Be 'Warning'
        $state.Result.message | Should -Match 'has no Rayfin CLI yet'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Action needed'
    }

    It 'starts nothing with -WhatIf' {
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Start-DemoFabricAppSignIn -Config $Config -WhatIf }
        $script:started | Should -Be 0
        $state.Result.status | Should -Be 'Not selected'
    }

    It 'takes the answer of the read the run started before its guard, without reading again (2026-11-06)' {
        $script:cli = [pscustomobject]@{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant'; Seconds = 9; Via = 'the stage''s CLI' }
        $early = New-TestStatusRead
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress; Check = $early } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Check $Check -Confirm:$false }
        $state.Result.status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Receive-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($Status, $early) }
        @($script:logged | Where-Object { $_ -match 'Checking whether' }) | Should -BeNullOrEmpty -Because 'it had answered while the run''s first steps ran'
    }

    It 'waits for a read that still runs, at most 90 seconds from its start, and says so on the page and the console (2026-11-06 live finding: 44 seconds cold)' {
        $script:stillReading = $true
        $script:cli = [pscustomobject]@{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant'; Seconds = 44; Via = 'the stage''s CLI' }
        $early = New-TestStatusRead
        $clock = InModuleScope DbHubDemo -Parameters @{ Until = $early.StartedUtc.AddSeconds(90) } { Format-DemoProgressClock -Unix (Get-DemoUnixTime -Value $Until) }
        $state = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress; Check = $early } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Check $Check -Confirm:$false }
        $expected = 'Checking whether the Rayfin CLI is already signed in to the demo''s tenant, at most until {0}; a browser opens only if it isn''t.' -f $clock
        $script:rowWhileReading['state'] | Should -Be 'Running'
        $script:rowWhileReading['message'] | Should -BeExactly $expected
        $script:logged | Should -Contain ('Info: {0}' -f $expected)
        $script:logged | Should -Contain 'Info: The Rayfin CLI is already signed in to the demo''s tenant (rayfin login status through the stage''s CLI, 44 seconds), so no browser opens for the Insights app.'
        $script:started | Should -Be 0 -Because 'the cold read answered within its 90 seconds, so no browser opened for nothing'
        $state.Result.status | Should -Be 'Pass'
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Done'
    }

    It 'says why a browser opens, at Info, when the CLI <Case>' -ForEach @(
        @{ Case = 'isn''t signed in'; Detail = 'not signed in'; Line = 'Info: The Rayfin CLI is not signed in (rayfin login status through the stage''s CLI, 9 seconds), so its sign-in for the Insights app starts: a browser opens.' }
        @{ Case = 'is signed in to another tenant'; Detail = 'signed in to another tenant than the demo''s'; Line = 'Info: The Rayfin CLI is signed in to another tenant than the demo''s (rayfin login status through the stage''s CLI, 9 seconds), so its sign-in for the Insights app starts: a browser opens.' }
    ) {
        $script:cli = [pscustomobject]@{ State = 'NotSignedIn'; Detail = $Detail; Seconds = 9; Via = 'the stage''s CLI' }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $script:started | Should -Be 1
        $script:logged | Should -Contain $Line
        @($script:logged | Where-Object { $_ -like 'Warning:*' }) | Should -BeNullOrEmpty
    }

    It 'says why at Warning, and starts the sign-in, when the CLI''s status couldn''t be read: <Detail> (2026-11-06 live finding)' -ForEach @(
        @{ Detail = 'no answer within 90 seconds' }
        @{ Detail = 'it couldn''t start: node was not found on PATH. Install Node.js 20, 22, 24, which includes npm.' }
        @{ Detail = 'exit code 1: Sign-in tenant differs from the configured tenant.' }
    ) {
        $script:cli = [pscustomobject]@{ State = 'Unknown'; Detail = $Detail; Seconds = 90; Via = 'the stage''s CLI' }
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Confirm:$false }
        $script:started | Should -Be 1
        $warnings = @($script:logged | Where-Object { $_ -like 'Warning:*' })
        $warnings.Count | Should -Be 1
        $warnings[0] | Should -BeExactly ('Warning: Whether the Rayfin CLI is already signed in couldn''t be read ({0}; rayfin login status through the stage''s CLI), so its sign-in for the Insights app starts: a browser opens, even if it''s signed in. To read it yourself, from the repository root: ./out/fabric-app/node_modules/.bin/rayfin login status' -f $Detail)
    }

    It 'reads the CLI''s status itself when the run started no read, or one for another tenant, which it ends' {
        $other = New-TestStatusRead -TenantId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config; Path = $script:progress; Check = $other } { Start-DemoFabricAppSignIn -Config $Config -ProgressPath $Path -Check $Check -Confirm:$false }
        Should -Invoke -ModuleName DbHubDemo -CommandName Stop-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($Status, $other) }
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { $TenantId -eq '66666666-7777-8888-9999-000000000000' -and $TimeoutSeconds -eq 90 }
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
        $script:cliDetail = 'not signed in'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinSignInState -MockWith { [pscustomobject]@{ State = $script:cliState; Detail = $script:cliDetail; Seconds = 9; Via = 'the stage''s CLI' } }
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
        # Read twice when it says not signed in: a read while another Rayfin process renews its token can (live, 2026-11-06).
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoRayfinSignInState -Times 1 -Exactly -ParameterFilter { $TenantId -eq '66666666-7777-8888-9999-000000000000' -and $Attempts -eq 2 }
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

    It 'says so when the CLI''s status couldn''t be read, and why, instead of claiming there''s no sign-in' {
        $script:cliState = 'Unknown'
        $script:cliDetail = 'no answer within 60 seconds'
        $result = @(& $script:complete (& $script:newState (New-TestProcess -Exited $true -ExitCode -1)))
        $result[0].status | Should -Be 'Warning'
        $result[0].message | Should -Match '^The Rayfin CLI''s sign-in ended with exit code -1: it was closed, cancelled, or failed\. Whether the CLI is signed in another way couldn''t be read \(no answer within 60 seconds\):'
        $result[0].message | Should -Match 'uses a sign-in this machine already has, if any'
        $result[0].message | Should -Not -Match 'isn''t created'
        $result[0].remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
    }

    It 'doesn''t read the CLI''s status when the sign-in finished, or after Ctrl+C, so a stop stays quick' {
        $null = @(& $script:complete (& $script:newState (New-TestProcess -Exited $true -ExitCode 0)))
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        $result = @(& $script:complete (& $script:newState (New-TestProcess)) -Final)
        $result[0].status | Should -Be 'Warning'
        $result[0].message | Should -Match 'couldn''t be read \(the run was stopped first\)'
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

Describe 'Start- and Receive-DemoRayfinSignInStatus: the CLI''s own status, never a browser, bounded, and never an exception (2026-11-06)' {
    BeforeAll {
        $script:tenant = '66666666-7777-8888-9999-000000000000'
        $script:readStatus = { param([string] $Tenant = $script:tenant, [int] $Timeout = 90) InModuleScope DbHubDemo -Parameters @{ Tenant = $Tenant; Timeout = $Timeout } { Receive-DemoRayfinSignInStatus -Status (Start-DemoRayfinSignInStatus -TenantId $Tenant -TimeoutSeconds $Timeout) } }
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:stageCli = 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { $script:stageCli }
        # The process layer (Start- and Receive-DemoFabricAppProcess, tested with real processes in DbHubDemo.FabricApp.Tests.ps1).
        $script:out = '{"status":"ok","command":"login status","identityType":"user","tenant":"66666666-7777-8888-9999-000000000000","verification":"endpoint-not-verified"}'
        $script:read = [pscustomobject]@{ ExitCode = 0; StdErr = ''; Seconds = 9; TimedOut = $false }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -MockWith { [pscustomobject]@{ Tool = $Tool; Process = $null; StartedUtc = [DateTime]::UtcNow; TimeoutSeconds = $TimeoutSeconds; Closed = $false } }
        Mock -ModuleName DbHubDemo -CommandName Receive-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = $script:read.ExitCode; StdOut = $script:out; StdErr = $script:read.StdErr; Seconds = $script:read.Seconds; TimedOut = $script:read.TimedOut } }
    }

    It 'reads the stage''s pinned CLI with node when it''s installed, from the stage, within the time it''s given, with the telemetry off and no ambient token' {
        $script:stageCli = 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js'
        $answer = & $script:readStatus
        $answer.State | Should -Be 'SignedIn'
        $answer.Detail | Should -Be 'signed in to the demo''s tenant'
        $answer.Via | Should -Be 'the stage''s CLI'
        $answer.Seconds | Should -Be 9
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -Times 1 -Exactly -ParameterFilter {
            $Tool -eq 'node' -and ($ArgumentList -join ' ') -eq 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js login status --json' -and $TimeoutSeconds -eq 90 -and
            $WorkingDirectory -like '*fabric-app' -and $Environment['RAYFIN_TELEMETRY_OPTOUT'] -eq '1' -and $Environment.Contains('RAYFIN_TOKEN') -and $null -eq $Environment['RAYFIN_TOKEN']
        }
    }

    It 'reads nothing without a stage, never through npx, which ignores the lock file''s npm overrides: Unknown, saying why (2026-11-09)' {
        $script:stageCli = ''
        $answer = & $script:readStatus
        $answer.State | Should -Be 'Unknown'
        $answer.Detail | Should -Be 'it couldn''t start: the Insights app''s stage (out/fabric-app) has no Rayfin CLI yet'
        $answer.Via | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -Times 0 -Exactly
    }

    It 'is NotSignedIn, saying why, when <Case>' -ForEach @(
        @{ Case = 'the CLI isn''t signed in'; Out = '{"status":"not-signed-in","command":"login status","recovery":"Run ''rayfin login'' to authenticate."}'; Detail = 'not signed in' }
        @{ Case = 'it''s signed in to another tenant'; Out = '{"status":"ok","identityType":"user","tenant":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}'; Detail = 'signed in to another tenant than the demo''s' }
    ) {
        $script:out = $Out
        $answer = & $script:readStatus
        $answer.State | Should -Be 'NotSignedIn'
        $answer.Detail | Should -Be $Detail
    }

    It 'is Unknown, saying why, when <Case>' -ForEach @(
        @{ Case = 'it ran out of time (the live finding''s 30 seconds were too few)'; Out = ''; ExitCode = -1; StdErr = 'node did not finish within 90 seconds and was stopped.'; TimedOut = $true; Detail = 'no answer within 90 seconds' }
        @{ Case = 'the output isn''t JSON'; Out = 'Error: Cannot find module ''keytar'''; ExitCode = 1; StdErr = ''; TimedOut = $false; Detail = 'exit code 1: Error: Cannot find module ''keytar''' }
        @{ Case = 'the CLI reports an error'; Out = '{"status":"error","error":"Sign-in tenant differs from the configured tenant."}'; ExitCode = 1; StdErr = ''; TimedOut = $false; Detail = 'exit code 1: Sign-in tenant differs from the configured tenant.' }
        @{ Case = 'only its error output says why'; Out = ''; ExitCode = 1; StdErr = "first line`nsecond line"; TimedOut = $false; Detail = 'exit code 1: first line' }
        @{ Case = 'it says nothing'; Out = ''; ExitCode = 3; StdErr = ''; TimedOut = $false; Detail = 'exit code 3: no output' }
    ) {
        $script:out = $Out
        $script:read = [pscustomobject]@{ ExitCode = $ExitCode; StdErr = $StdErr; Seconds = 90; TimedOut = $TimedOut }
        $answer = & $script:readStatus
        $answer.State | Should -Be 'Unknown'
        $answer.Detail | Should -Be $Detail
    }

    It 'is Unknown, without an exception, when it can''t start or be read: <Case>' -ForEach @(
        @{ Case = 'node isn''t on PATH'; Breaks = 'Start'; Detail = 'it couldn''t start: node was not found on PATH.*' }
        @{ Case = 'the stage can''t be read'; Breaks = 'Stage'; Detail = 'it couldn''t start: the stage''s package.json is damaged' }
        @{ Case = 'reading it throws'; Breaks = 'Receive'; Detail = 'it couldn''t be read: the read broke' }
    ) {
        switch ($Breaks) {
            'Start' { Mock -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -MockWith { throw 'node was not found on PATH. Install Node.js 20, 22, 24, which includes npm.' } }
            'Stage' { Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { throw 'the stage''s package.json is damaged' } }
            'Receive' { Mock -ModuleName DbHubDemo -CommandName Receive-DemoFabricAppProcess -MockWith { throw 'the read broke' } }
        }
        { $script:answer = & $script:readStatus } | Should -Not -Throw
        $script:answer.State | Should -Be 'Unknown'
        $script:answer.Detail | Should -BeLike $Detail
    }

    It 'is Unknown without a tenant, and starts nothing' {
        $answer = & $script:readStatus ''
        $answer.State | Should -Be 'Unknown'
        $answer.Detail | Should -Be 'it couldn''t start: no tenant (tenantId) is configured'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -Times 0 -Exactly
    }

    It 'reads once and gives the same answer after that; Get-DemoRayfinSignInState reads now, within the start''s 90 seconds unless told otherwise (a cold read took 64.8 seconds live, 2026-11-06)' {
        $status = InModuleScope DbHubDemo -Parameters @{ Tenant = $script:tenant } { Start-DemoRayfinSignInStatus -TenantId $Tenant }
        $status.TimeoutSeconds | Should -Be 90
        $first = InModuleScope DbHubDemo -Parameters @{ Status = $status } { Receive-DemoRayfinSignInStatus -Status $Status }
        $second = InModuleScope DbHubDemo -Parameters @{ Status = $status } { Receive-DemoRayfinSignInStatus -Status $Status }
        [object]::ReferenceEquals($first, $second) | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Receive-DemoFabricAppProcess -Times 1 -Exactly
        $state = InModuleScope DbHubDemo -Parameters @{ Tenant = $script:tenant } { Get-DemoRayfinSignInState -TenantId $Tenant }
        $state.State | Should -Be 'SignedIn'
        $state.Attempts | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -Times 2 -Exactly -ParameterFilter { $TimeoutSeconds -eq 90 }
    }
}

Describe 'Get-DemoRayfinSignInState: a second read when the first finds no sign-in, which a token renewal elsewhere can cause (live, 2026-11-06)' {
    BeforeEach {
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logs.Add(('{0}: {1}' -f $(if ($PesterBoundParameters.ContainsKey('Level')) { $PesterBoundParameters['Level'] } else { 'Info' }), $Message)) }
        # What each read answers, in order; the last answer repeats.
        $script:answers = @(@{ State = 'NotSignedIn'; Detail = 'not signed in' })
        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -MockWith { New-TestStatusRead -TenantId $TenantId -TimeoutSeconds $TimeoutSeconds }
        Mock -ModuleName DbHubDemo -CommandName Receive-DemoRayfinSignInStatus -MockWith {
            $answer = $script:answers[[System.Math]::Min($script:reads, $script:answers.Count - 1)]
            $script:reads++
            [pscustomobject]@{ State = $answer.State; Detail = $answer.Detail; Seconds = 9; Via = 'the stage''s CLI' }
        }
        $script:sleeps = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:sleeps.Add($Seconds) }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $false }
        $script:read = { param([int] $Attempts = 2) InModuleScope DbHubDemo -Parameters @{ Attempts = $Attempts } { Get-DemoRayfinSignInState -TenantId '66666666-7777-8888-9999-000000000000' -Attempts $Attempts } }
    }

    It 'reads once by default, within 90 seconds, even when it says not signed in' {
        $answer = InModuleScope DbHubDemo { Get-DemoRayfinSignInState -TenantId '66666666-7777-8888-9999-000000000000' }
        $answer.State | Should -Be 'NotSignedIn'
        $answer.Attempts | Should -Be 1
        $script:reads | Should -Be 1
        $script:sleeps.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 90 }
    }

    It 'reads again 10 seconds later when the first read says not signed in, and the second answer counts, both within 90 seconds' {
        $script:answers = @(@{ State = 'NotSignedIn'; Detail = 'not signed in' }, @{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant' })
        $answer = & $script:read
        $answer.State | Should -Be 'SignedIn'
        $answer.Attempts | Should -Be 2
        $script:reads | Should -Be 2
        @($script:sleeps) -join ',' | Should -Be '10'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoRayfinSignInStatus -Times 2 -Exactly -ParameterFilter { $TimeoutSeconds -eq 90 -and $TenantId -eq '66666666-7777-8888-9999-000000000000' }
        $script:logs | Should -Contain 'Info: The Rayfin CLI''s sign-in says it isn''t signed in (rayfin login status through the stage''s CLI, 9 seconds); it''s read again in 10 seconds, because a read while another Rayfin process rewrites its token cache can find no sign-in for a moment.'
        $script:logs | Should -Contain 'Info: The Rayfin CLI''s sign-in, read again: signed in to the demo''s tenant (9 seconds).'
    }

    It 'reads again when the first read couldn''t be read: <Detail>' -ForEach @(
        @{ Detail = 'exit code 1: no output' }
        @{ Detail = 'it couldn''t be read: the read broke' }
    ) {
        $script:answers = @(@{ State = 'Unknown'; Detail = $Detail }, @{ State = 'NotSignedIn'; Detail = 'not signed in' })
        $answer = & $script:read
        $answer.State | Should -Be 'NotSignedIn'
        $answer.Attempts | Should -Be 2
        ($script:logs -join "`n") | Should -Match ([regex]::Escape(('couldn''t be read ({0})' -f $Detail)))
    }

    It 'doesn''t read again when a second read can''t change it: <Case>' -ForEach @(
        @{ Case = 'signed in at once'; State = 'SignedIn'; Detail = 'signed in to the demo''s tenant' }
        @{ Case = 'the read ran out of time, which another 90 seconds would only repeat'; State = 'Unknown'; Detail = 'no answer within 90 seconds' }
        @{ Case = 'the read couldn''t start'; State = 'Unknown'; Detail = 'it couldn''t start: node was not found on PATH.' }
        @{ Case = 'signed in to another tenant, which a renewal doesn''t cause'; State = 'NotSignedIn'; Detail = 'signed in to another tenant than the demo''s' }
    ) {
        $script:answers = @(@{ State = $State; Detail = $Detail }, @{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant' })
        $answer = & $script:read
        $answer.State | Should -Be $State
        $answer.Detail | Should -Be $Detail
        $answer.Attempts | Should -Be 1
        $script:reads | Should -Be 1
        $script:sleeps.Count | Should -Be 0
    }

    It 'doesn''t read again after Ctrl+C, so a stop stays quick' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        $answer = & $script:read
        $answer.State | Should -Be 'NotSignedIn'
        $script:reads | Should -Be 1
        $script:sleeps.Count | Should -Be 0
    }

    It 'reads at most -Attempts times' {
        $answer = & $script:read 3
        $answer.State | Should -Be 'NotSignedIn'
        $answer.Attempts | Should -Be 3
        $script:reads | Should -Be 3
        @($script:sleeps) -join ',' | Should -Be '10,10'
    }

    It 'makes the window''s deadline a Pass when the second read finds the sign-in the first missed (Complete-DemoFabricAppSignIn, the live finding)' {
        $script:answers = @(@{ State = 'NotSignedIn'; Detail = 'not signed in' }, @{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant' })
        $progress = New-TestModelFile
        $late = New-TestProcess
        $state = [pscustomobject]@{ Process = $late; TenantId = '66666666-7777-8888-9999-000000000000'; StartedUtc = [DateTime]::UtcNow.AddMinutes(-16); DeadlineUtc = [DateTime]::UtcNow.AddMinutes(-1); TimeoutMinutes = 15; Done = $false; Reported = $false; Result = $null }
        $result = @(InModuleScope DbHubDemo -Parameters @{ State = $state; Path = $progress } { Complete-DemoFabricAppSignIn -SignIn $State -ProgressPath $Path })
        $late.Killed | Should -BeTrue
        $result.Count | Should -Be 1
        $result[0].status | Should -Be 'Pass'
        $result[0].message | Should -Match 'its sign-in window was still open, so it was stopped, but a sign-in already exists'
        (Get-TestRow -Path $progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Done'
        $script:reads | Should -Be 2
    }
}

Describe 'Update-DemoFabricAppSignInFromApp: the app step''s records settle the sign-in''s row, so the two never disagree (live, 2026-11-06)' {
    BeforeEach {
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logs.Add([string]$Message) }
        $script:progress = New-TestModelFile
        # The live run: nobody answered the window, and the read at its deadline said "not signed in".
        $script:signIn = [pscustomobject]@{ Process = $null; TenantId = '66666666-7777-8888-9999-000000000000'; Done = $false; Reported = $true; Result = $null }
        $script:earlier = 'Nobody finished the Rayfin CLI''s sign-in within 15 minutes, so it was stopped. The deployment went on; without the sign-in the Insights app isn''t created, and its step says why. ./scripts/configure-fabric-app.ps1 -SignIn adds it later.'
        InModuleScope DbHubDemo -Parameters @{ SignIn = $script:signIn; Path = $script:progress; Message = $script:earlier } {
            Set-DemoFabricAppSignInResult -SignIn $SignIn -ProgressPath $Path -Status 'Warning' -Message $Message -Remediation 'Run ./scripts/configure-fabric-app.ps1 -SignIn in a terminal.'
        }
        $script:warning = $script:signIn.Result
        # The run's results, with the Warning between two others.
        $script:results = [System.Collections.Generic.List[object]]::new()
        $script:results.Add((New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message 'ok'))
        $script:results.Add($script:warning)
        $script:results.Add((New-DemoResult -CheckId 'FABRIC.NOTEBOOKS' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'ok'))
        # The app step's records, from "ID=Status" pairs.
        $script:records = { param([string[]] $Spec) foreach ($item in $Spec) { $id, $status = $item -split '=', 2; New-DemoResult -CheckId $id -Area 'fabric' -Target 'fabric' -Status $status -Message ('{0}: {1}' -f $id, $status) } }
        $script:update = { param([object[]] $App) InModuleScope DbHubDemo -Parameters @{ SignIn = $script:signIn; App = $App; Results = $script:results; Path = $script:progress } { Update-DemoFabricAppSignInFromApp -SignIn $SignIn -AppResult $App -Results $Results -ProgressPath $Path } }
    }

    It 'makes the Warning a Pass when the app''s step found the CLI signed in: the record, the run''s results, and the row, once' {
        $app = @(& $script:records 'FABRIC.APP.SIGNIN=Pass', 'FABRIC.APP.DEPLOY=Pass', 'DEPLOY.FABRIC.APP=Manual action required')
        $new = & $script:update $app
        $new.checkId | Should -Be 'DEPLOY.FABRIC.APPSIGNIN'
        $new.status | Should -Be 'Pass'
        $new.message | Should -BeExactly 'The Rayfin CLI was signed in to the demo''s tenant: the Insights app''s step found it signed in and used that sign-in, so the sign-in this run started wasn''t needed.'
        $new.message | Should -Not -Match 'isn''t created'
        $new.evidence['settledBy'] | Should -Be 'FABRIC.APP.SIGNIN, FABRIC.APP.DEPLOY'
        $new.evidence['earlierStatus'] | Should -Be 'Warning'
        $new.evidence['earlierMessage'] | Should -Be $script:earlier
        [object]::ReferenceEquals($script:signIn.Result, $new) | Should -BeTrue
        # The run's results hold the new record where the Warning was, and the Warning no more.
        $script:results.Count | Should -Be 3
        [object]::ReferenceEquals($script:results[1], $new) | Should -BeTrue
        @($script:results | Where-Object { [object]::ReferenceEquals($_, $script:warning) }).Count | Should -Be 0
        $row = Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn'
        $row['state'] | Should -Be 'Done'
        $row['message'] | Should -Be $new.message
        $script:logs | Should -Contain ('The Insights app''s sign-in, settled from the app''s step: {0}' -f $new.message)
        # Once: a second look changes nothing.
        $logged = $script:logs.Count
        & $script:update $app | Should -BeNullOrEmpty
        [object]::ReferenceEquals($script:results[1], $new) | Should -BeTrue
        $script:logs.Count | Should -Be $logged
    }

    It 'makes it a Pass on the app''s deployment alone (FABRIC.APP.DEPLOY Pass)' {
        $new = & $script:update @(& $script:records 'FABRIC.APP.DEPLOY=Pass')
        $new.status | Should -Be 'Pass'
        $new.message | Should -Match 'the Insights app''s step deployed the app with that sign-in'
        $new.evidence['settledBy'] | Should -Be 'FABRIC.APP.DEPLOY'
    }

    It 'leaves a Warning that the step''s records don''t contradict: <Case>' -ForEach @(
        @{ Case = 'no records yet'; Spec = @() }
        @{ Case = 'the step found no sign-in either'; Spec = @('FABRIC.APP.SIGNIN=Manual action required', 'DEPLOY.FABRIC.APP=Manual action required') }
        @{ Case = 'the app wasn''t deployed'; Spec = @('FABRIC.APP.DEPLOY=Manual action required') }
        @{ Case = 'only other checks passed'; Spec = @('FABRIC.APP.TENANTSETTING=Pass', 'DEPLOY.FABRIC.APP=Pass') }
    ) {
        & $script:update @(& $script:records $Spec) | Should -BeNullOrEmpty
        [object]::ReferenceEquals($script:signIn.Result, $script:warning) | Should -BeTrue
        [object]::ReferenceEquals($script:results[1], $script:warning) | Should -BeTrue
        (Get-TestRow -Path $script:progress -Id 'Fabric.AppSignIn')['state'] | Should -Be 'Action needed'
    }

    It 'leaves a sign-in that isn''t a Warning alone: <Status>' -ForEach @(
        @{ Status = 'Pass' }
        @{ Status = 'Not supported' }
        @{ Status = 'Not selected' }
    ) {
        InModuleScope DbHubDemo -Parameters @{ SignIn = $script:signIn; Status = $Status } { Set-DemoFabricAppSignInResult -SignIn $SignIn -Status $Status -Message 'Settled before.' }
        $before = $script:signIn.Result
        & $script:update @(& $script:records 'FABRIC.APP.SIGNIN=Pass') | Should -BeNullOrEmpty
        [object]::ReferenceEquals($script:signIn.Result, $before) | Should -BeTrue
    }

    It 'never throws: no sign-in, one not settled yet, or odd records, which don''t keep a real one from settling it' {
        { InModuleScope DbHubDemo { Update-DemoFabricAppSignInFromApp -SignIn $null -AppResult @() } } | Should -Not -Throw
        $open = [pscustomobject]@{ Process = $null; Done = $false; Reported = $false; Result = $null }
        (InModuleScope DbHubDemo -Parameters @{ SignIn = $open } { Update-DemoFabricAppSignInFromApp -SignIn $SignIn -AppResult @([pscustomobject]@{ checkId = 'FABRIC.APP.SIGNIN'; status = 'Pass' }) }) | Should -BeNullOrEmpty
        $odd = @($null, 'text', @{ checkId = 'FABRIC.APP.SIGNIN' }, [pscustomobject]@{ status = 'Pass' })
        { $script:none = & $script:update $odd } | Should -Not -Throw
        $script:none | Should -BeNullOrEmpty
        [object]::ReferenceEquals($script:signIn.Result, $script:warning) | Should -BeTrue
        $new = & $script:update (@($odd) + @(& $script:records 'FABRIC.APP.SIGNIN=Pass'))
        $new.status | Should -Be 'Pass'
    }
}

Describe 'Start-DemoFabricAppSignInCheck: the read starts before the guard, and ends when nobody needs it (2026-11-06)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:interactive = $true
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $script:interactive }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js' }
        # Fabric refused the Azure CLI's token for the demo's tenant before, so the CLI's own sign-in may start (2026-11-09).
        $script:record = [pscustomobject]@{ Outcome = 'Refused'; Reason = 'HTTP 401 Unauthorized'; TenantId = '66666666-7777-8888-9999-000000000000'; CheckedUtc = '' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinAuthRecord -MockWith { $script:record }
        # A process stand-in whose Kill and Dispose record that they ran.
        Mock -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -MockWith {
            $process = [pscustomobject]@{ HasExited = $false; Killed = $null; Disposed = 0 }
            $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($Tree) $this.Killed = [bool]$Tree; $this.HasExited = $true }
            $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++ }
            [pscustomobject]@{ Tool = $Tool; Process = $process; StartedUtc = [DateTime]::UtcNow; TimeoutSeconds = $TimeoutSeconds; Closed = $false }
        }
        InModuleScope DbHubDemo { $script:DemoFabricAppSignInCheck = $null }
        $script:config = @{ tenantId = '66666666-7777-8888-9999-000000000000' }
    }

    AfterEach {
        InModuleScope DbHubDemo { $script:DemoFabricAppSignInCheck = $null }
    }

    It 'starts nothing where no sign-in could start: <Case>' -ForEach @(
        @{ Case = 'a session that can''t answer one'; Interactive = $false; Tenant = '66666666-7777-8888-9999-000000000000'; Outcome = 'Refused' }
        @{ Case = 'no tenant'; Interactive = $true; Tenant = ''; Outcome = 'Refused' }
        @{ Case = 'no refusal recorded, the default since 2026-11-09: the app''s step uses the Azure CLI''s token'; Interactive = $true; Tenant = '66666666-7777-8888-9999-000000000000'; Outcome = '' }
        @{ Case = 'Fabric accepted the Azure CLI''s token'; Interactive = $true; Tenant = '66666666-7777-8888-9999-000000000000'; Outcome = 'Accepted' }
    ) {
        $script:interactive = $Interactive
        $script:record = [pscustomobject]@{ Outcome = $Outcome; Reason = ''; TenantId = '66666666-7777-8888-9999-000000000000'; CheckedUtc = '' }
        (InModuleScope DbHubDemo -Parameters @{ Config = @{ tenantId = $Tenant } } { Start-DemoFabricAppSignInCheck -Config $Config }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -Times 0 -Exactly
    }

    It 'starts the read at once, for 90 seconds, through the stage''s CLI, and keeps it for the run''s end; one at a time' {
        $first = InModuleScope DbHubDemo -Parameters @{ Config = $script:config } { Start-DemoFabricAppSignInCheck -Config $Config }
        $first.TimeoutSeconds | Should -Be 90
        $first.Via | Should -Be 'the stage''s CLI'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoFabricAppProcess -Times 1 -Exactly -ParameterFilter { $Tool -eq 'node' }
        $first.Run.Process.Killed | Should -BeNullOrEmpty -Because 'nothing waits for it or ends it yet'
        (InModuleScope DbHubDemo -Parameters @{ Check = $first } { [object]::ReferenceEquals($script:DemoFabricAppSignInCheck, $Check) }) | Should -BeTrue
        $second = InModuleScope DbHubDemo -Parameters @{ Config = $script:config } { Start-DemoFabricAppSignInCheck -Config $Config }
        $first.Run.Process.Killed | Should -BeTrue -Because 'a new read ends the one before it, with every process it started'
        $first.Result.Detail | Should -Be 'it was stopped before it was read'
        (InModuleScope DbHubDemo -Parameters @{ Check = $second } { [object]::ReferenceEquals($script:DemoFabricAppSignInCheck, $Check) }) | Should -BeTrue
    }

    It 'ends a read the run never used when the run ends (Stop-DemoFabricAppSignIn), and leaves one that answered as it was' {
        $check = InModuleScope DbHubDemo -Parameters @{ Config = $script:config } { Start-DemoFabricAppSignInCheck -Config $Config }
        InModuleScope DbHubDemo { Stop-DemoFabricAppSignIn }
        $check.Run.Process.Killed | Should -BeTrue
        $check.Run.Process.Disposed | Should -Be 1
        $check.Run.Closed | Should -BeTrue
        $check.Result.State | Should -Be 'Unknown'
        (InModuleScope DbHubDemo { $null -eq $script:DemoFabricAppSignInCheck }) | Should -BeTrue
        # One that answered keeps its answer, and anything else is left alone without an exception.
        $answered = New-TestStatusRead
        $answered.Result = [pscustomobject]@{ State = 'SignedIn'; Detail = 'signed in to the demo''s tenant'; Seconds = 9; Via = 'the stage''s CLI' }
        { InModuleScope DbHubDemo -Parameters @{ Status = $answered } { Stop-DemoRayfinSignInStatus -Status $Status; Stop-DemoRayfinSignInStatus -Status $null; Stop-DemoRayfinSignInStatus -Status ([pscustomobject]@{ Name = 'not a read' }) } } | Should -Not -Throw
        $answered.Result.State | Should -Be 'SignedIn'
    }

    It 'is Unknown, and stops nothing, for a read that never started' {
        $status = InModuleScope DbHubDemo { Start-DemoRayfinSignInStatus -TenantId '' }
        (InModuleScope DbHubDemo -Parameters @{ Status = $status } { Test-DemoRayfinSignInStatusRunning -Status $Status }) | Should -BeFalse
        (InModuleScope DbHubDemo -Parameters @{ Status = $status } { Receive-DemoRayfinSignInStatus -Status $Status }).State | Should -Be 'Unknown'
    }
}

Describe 'Wait-DemoFabricAppSignIn: only the Insights app''s step waits: until the deadline, then while the run reads the sign-in, at most 4 minutes (2026-11-05, 2026-11-06)' {
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

    It 'past the deadline, waits while the run reads the CLI''s sign-in, and says so on the app''s row, so the two reads don''t overlap (live, 2026-11-06)' {
        $until = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress; Until = $until } {
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ appSignInUntil = $Until })
            Set-DemoProgressStep -Path $Path -Id 'Fabric.AppSignIn' -State 'Running' -Message 'A browser opens for your sign-in.'
        }
        $script:polls = 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {
            $script:polls++
            if ($script:polls -eq 3) {
                # deploy.ps1's read at the deadline settles the sign-in meanwhile.
                & (Get-Module -Name DbHubDemo) { param($p) Set-DemoProgressStep -Path $p -Id 'Fabric.AppSignIn' -State 'Action needed' -Status 'Warning' -Message 'Not signed in.' } $script:progress
            }
        }
        $null = InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Wait-DemoFabricAppSignIn -ProgressPath $Path -PollSeconds 1 }
        $script:polls | Should -Be 3
        (Get-TestRow -Path $script:progress -Id 'Fabric.App')['message'] | Should -Match 'reached its deadline; the run is checking whether the CLI is signed in, and the Insights app''s step goes on once it has, at most at'
    }

    It 'waits at most -GraceSeconds past the deadline when nothing settles the sign-in, saying each wait once' {
        # A clock that moves only when the wait sleeps.
        $script:clock = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUnixTime -MockWith { $script:clock }
        $script:slept = 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:slept += $Seconds; $script:clock += $Seconds }
        $script:logs = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logs.Add([string]$Message) }
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress; Until = ($script:clock + 20) } {
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ appSignInUntil = $Until })
            Set-DemoProgressStep -Path $Path -Id 'Fabric.AppSignIn' -State 'Running' -Message 'A browser opens for your sign-in.'
        }
        $null = InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Wait-DemoFabricAppSignIn -ProgressPath $Path }
        $script:slept | Should -Be 260 -Because 'it waits 20 seconds to the deadline, then 240 more at most'
        @($script:logs | Where-Object { $_ -like 'Waiting for the Rayfin CLI''s sign-in in the browser*' }).Count | Should -Be 1
        @($script:logs | Where-Object { $_ -like 'The Rayfin CLI''s sign-in reached its deadline*' }).Count | Should -Be 1
    }

    It 'doesn''t wait past the deadline without a grace (-GraceSeconds 0), or once the grace is over' {
        $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { throw 'no wait expected' }
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress; Until = ($now - 1) } {
            Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ appSignInUntil = $Until })
            Set-DemoProgressStep -Path $Path -Id 'Fabric.AppSignIn' -State 'Running' -Message 'A browser opens for your sign-in.'
        }
        (InModuleScope DbHubDemo -Parameters @{ Path = $script:progress } { Wait-DemoFabricAppSignIn -ProgressPath $Path -GraceSeconds 0 }) | Should -Be 0
        InModuleScope DbHubDemo -Parameters @{ Path = $script:progress; Until = ($now - 241) } { Set-DemoProgressValue -Path $Path -Section 'run' -Value ([ordered]@{ appSignInUntil = $Until }) }
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

    It 'runs the stage''s pinned CLI''s sign-in with node, never npx, from the stage, in a window of its own on Windows, with the telemetry off and no ambient token (2026-11-09)' {
        $script:startArguments = $null
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Source = 'C:\nodejs\node.exe' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { 'C:\repo\out\fabric-app\node_modules\@microsoft\rayfin-cli\bin\rayfin.js' }
        Mock -ModuleName DbHubDemo -CommandName Start-Process -MockWith { $script:startArguments = $PesterBoundParameters; [pscustomobject]@{ Handle = [System.IntPtr]::Zero; HasExited = $false } }
        $null = InModuleScope DbHubDemo { Start-DemoRayfinSignInProcess -TenantId '66666666-7777-8888-9999-000000000000' }
        $script:startArguments['FilePath'] | Should -Be 'C:\nodejs\node.exe'
        @($script:startArguments['ArgumentList']) | Should -Be @('"C:\repo\out\fabric-app\node_modules\@microsoft\rayfin-cli\bin\rayfin.js"', 'login', '--tenant', '66666666-7777-8888-9999-000000000000')
        $script:startArguments['WorkingDirectory'] | Should -BeLike '*fabric-app'
        $script:startArguments['Environment']['RAYFIN_TELEMETRY_OPTOUT'] | Should -Be '1'
        $script:startArguments['Environment'].Contains('RAYFIN_TOKEN') | Should -BeTrue
        $script:startArguments['Environment']['RAYFIN_TOKEN'] | Should -BeNullOrEmpty
        $script:startArguments.ContainsKey('Wait') | Should -BeFalse -Because 'nothing waits for it'
        $script:startArguments.ContainsKey('NoNewWindow') | Should -Be (-not $IsWindows)
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-Command -Times 0 -Exactly -ParameterFilter { $Name -eq 'npx' }
    }

    It 'throws, naming Node.js, when node isn''t on PATH, and the stage when it has no CLI yet, starting nothing' {
        Mock -ModuleName DbHubDemo -CommandName Start-Process -MockWith { throw 'nothing starts' }
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { }
        { InModuleScope DbHubDemo { Start-DemoRayfinSignInProcess -TenantId '66666666-7777-8888-9999-000000000000' } } | Should -Throw '*node wasn''t found on PATH*'
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Source = 'C:\nodejs\node.exe' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { '' }
        { InModuleScope DbHubDemo { Start-DemoRayfinSignInProcess -TenantId '66666666-7777-8888-9999-000000000000' } } | Should -Throw '*stage (out/fabric-app) has no Rayfin CLI yet*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Process -Times 0 -Exactly
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
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Source = 'C:\nodejs\node.exe' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { 'C:\stage\node_modules\@microsoft\rayfin-cli\bin\rayfin.js' }
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
        # The child writes what it sees to a file itself. Start-Process -RedirectStandardOutput differs by platform: on
        # Linux and macOS it writes each line the child prints, with a line ending, from handlers that run as the output
        # arrives, so the file ended with a newline in CI (2026-11-06); on Windows the file gets the child's bytes as written.
        $file = Join-Path -Path $TestDrive -ChildPath 'child-environment.txt'
        $probe = '[System.IO.File]::WriteAllText(''{0}'', ''BROWSER=['' + [System.Environment]::GetEnvironmentVariable(''BROWSER'') + ''] RAYFIN_TELEMETRY_OPTOUT=['' + $env:RAYFIN_TELEMETRY_OPTOUT + '']'')' -f $file.Replace("'", "''")
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded -Environment $environment -NoNewWindow -Wait -PassThru
        $child.ExitCode | Should -Be 0
        Get-Content -LiteralPath $file -Raw | Should -BeExactly 'BROWSER=[] RAYFIN_TELEMETRY_OPTOUT=[1]'
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
