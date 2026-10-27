BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        return $config
    }

    function New-AzResult([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass') {
        New-DemoResult -CheckId $CheckId -Area 't2' -Target 'T2' -Status $Status -Message ('{0} {1}' -f $CheckId, $Status)
    }

    function New-SnapshotJson {
        param(
            [string] $Name = 'snap-dbhub-t2golden-202610221230',
            [string] $Captured = '2026-10-22T12:30:00Z',
            [string] $Expires = '2027-04-19T13:46:22Z',
            [string] $Role = 't2-golden',
            [string] $Prefix = 'dbhub',
            [string] $BootVerified = ''
        )
        $tags = [ordered]@{
            dbhubRole           = $Role
            dbhubPrefix         = $Prefix
            dbhubCapturedUtc    = $Captured
            dbhubEvalExpiresUtc = $Expires
            dbhubSqlVersion     = '16.0.1000.6'
            dbhubHostSize       = 'Standard_E2s_v5'
            dbhubUsedGiB        = '37'
            dbhubArcIdentity    = 'rg-dbhub-demo/arcsql01'
        }
        if ($BootVerified) {
            $tags['dbhubBootVerifiedUtc'] = $BootVerified
        }
        [pscustomobject]@{
            name                = $Name
            id                  = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/{0}' -f $Name
            location            = 'westus3'
            sku                 = [pscustomobject]@{ name = 'Standard_ZRS' }
            diskSizeGB          = 128
            incremental         = $true
            networkAccessPolicy = 'DenyAll'
            provisioningState   = 'Succeeded'
            tags                = [pscustomobject]$tags
        }
    }

    function New-TestSweepOutcome {
        # The sign-in data sweep's outcome (Invoke-DemoSignInDataAction) for the host and its guest: counts only.
        param([bool] $Pass = $true, [int] $Security = 0)
        $counts = { param([int] $User, [int] $InSecurityLog) [ordered]@{ scanned = 9; user = $User; other = 0; app = 0; files = [int]($User -gt 0); archives = 0; caches = 0; unverified = 0; logUser = 0; logApp = 0; security = $InSecurityLog } }
        $part = [ordered]@{ computer = 'VM'; reachable = $true; pass = $Pass; found = & $counts 1 $Security; remaining = & $counts ([int](-not $Pass)) $Security; eventLogs = @(); found_at = @(); left_at = @(); seconds = 30 }
        $data = [ordered]@{ action = 'Clean'; scope = 'Both'; succeeded = $true; pass = $Pass; local = $part; guest = $part } | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        [pscustomobject]@{ Succeeded = $true; Data = $data; Error = ''; Seconds = 60 }
    }
}
Describe 'Golden snapshot names and tags' {
    It 'keeps the snapshots of a prefix in its golden group, rg-dbhub-golden' {
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoGoldenResourceGroupName -Config $Config } | Should -Be 'rg-dbhub-golden'
    }

    It 'names a snapshot after the prefix and the capture minute in UTC' {
        $name = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoGoldenSnapshotName -Config $Config -NowUtc ([datetime]::new(2026, 10, 22, 12, 30, 59, [System.DateTimeKind]::Utc)) }
        $name | Should -Be 'snap-dbhub-t2golden-202610221230'
    }

    It 'tags the golden group as environment golden without a deploymentId, so no environment''s residue check counts it' {
        $tags = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoGoldenStandardTag -Config $Config }
        $tags['environment'] | Should -Be 'golden'
        $tags['purpose'] | Should -Be 't2-golden-snapshot'
        $tags['solution'] | Should -Be 'fabric-database-hub-demo'
        $tags.Contains('deploymentId') | Should -BeFalse
        $tags.Contains('autoShutdown') | Should -BeFalse
    }

    It 'turns tags into key=value arguments in order' {
        $arguments = InModuleScope DbHubDemo { ConvertTo-DemoTagArgument -Tag ([ordered]@{ a = '1'; b = 'two' }) }
        $arguments | Should -Be @('a=1', 'b=two')
    }

    It 'parses a snapshot''s lifetime and provenance tags' {
        $snapshot = InModuleScope DbHubDemo -Parameters @{ Item = (New-SnapshotJson -BootVerified '2026-10-22T14:00:00Z') } {
            ConvertFrom-DemoGoldenSnapshot -Snapshot $Item -NowUtc ([datetime]::new(2026, 10, 22, 13, 0, 0, [System.DateTimeKind]::Utc))
        }
        $snapshot.Name | Should -Be 'snap-dbhub-t2golden-202610221230'
        $snapshot.Sku | Should -Be 'Standard_ZRS'
        $snapshot.SizeGiB | Should -Be 128
        $snapshot.UsedGiB | Should -Be 37
        $snapshot.Incremental | Should -BeTrue
        $snapshot.NetworkAccessPolicy | Should -Be 'DenyAll'
        $snapshot.EvalDaysLeft | Should -Be 179
        $snapshot.CapturedUtc.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $snapshot.BootVerifiedUtc | Should -Not -BeNullOrEmpty
        $snapshot.OnboardVerifiedUtc | Should -BeNullOrEmpty
        $snapshot.ArcIdentity | Should -Be 'rg-dbhub-demo/arcsql01'
    }
}

Describe 'Get-DemoT2GoldenSnapshot' {
    BeforeEach {
        $config = New-TestConfig
        $script:groupExists = 'true'
        $script:listed = @()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            if ($ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq 'exists') {
                return (New-AzResult -StdOut $script:groupExists)
            }
            if ($ArgumentList[0] -eq 'snapshot' -and $ArgumentList[1] -eq 'list') {
                return $script:listed
            }
            throw ('unexpected: {0}' -f ($ArgumentList -join ' '))
        }
    }

    It 'returns nothing when the golden group doesn''t exist' {
        $script:groupExists = 'false'
        @(Get-DemoT2GoldenSnapshot -Config $config).Count | Should -Be 0
    }

    It 'keeps this prefix''s golden snapshots, newest first' {
        $script:listed = @(
            (New-SnapshotJson -Name 'snap-dbhub-t2golden-202610011200' -Captured '2026-10-01T12:00:00Z')
            (New-SnapshotJson -Name 'snap-dbhub-t2golden-202610221230' -Captured '2026-10-22T12:30:00Z')
            (New-SnapshotJson -Name 'snap-other-t2golden-202610221230' -Prefix 'other')
            (New-SnapshotJson -Name 'unrelated' -Role 'backup')
        )
        $snapshots = @(Get-DemoT2GoldenSnapshot -Config $config)
        $snapshots.Name | Should -Be @('snap-dbhub-t2golden-202610221230', 'snap-dbhub-t2golden-202610011200')
    }
}

Describe 'Wait-DemoVmAgentReady' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
    }

    It 'returns once the VM agent reports Ready' {
        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $script:reads++
            New-AzResult -StdOut $(if ($script:reads -ge 3) { "Ready`n" } else { "Not Ready`n" })
        }
        $seconds = InModuleScope DbHubDemo { Wait-DemoVmAgentReady -SubscriptionId '11111111-2222-3333-4444-555555555555' -ResourceGroupName 'rg-dbhub-gtest' -VmName 'archost01' -PollSeconds 1 }
        $seconds | Should -BeGreaterOrEqual 0
        $script:reads | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm get-instance-view .*instanceView\.vmAgent\.statuses\[0\]\.displayStatus' }
    }
}

Describe 'Invoke-DemoGoldenGuestAction' {
    BeforeEach {
        $config = New-TestConfig
    }

    It 'runs the golden script on archost01 and returns its JSON line' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            [pscustomobject]@{ Succeeded = $true; Output = "note`n{""action"":""Inspect"",""succeeded"":true,""host"":{""hostState"":""Ready""}}"; Error = ''; ExecutionState = 'Succeeded'; ExitCode = 0 }
        }
        $run = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoGoldenGuestAction -Config $Config -Action 'Inspect' -ResourceGroupName 'rg-dbhub-gtest' }
        $run.Succeeded | Should -BeTrue
        $run.Data.host.hostState | Should -Be 'Ready'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter {
            $VmName -eq 'archost01' -and $RunCommandName -eq 'DbHubDemo-Golden' -and $Parameter['Action'] -eq 'Inspect' -and $ResourceGroupName -eq 'rg-dbhub-gtest' -and $Script -match 'Invoke-GoldenRelease'
        }
    }

    It 'reports the script''s error when the action fails' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            [pscustomobject]@{ Succeeded = $false; Output = '{"action":"Release","succeeded":false,"error":"Isolation failed: management.azure.com answered"}'; Error = 'exit 1'; ExecutionState = 'Failed'; ExitCode = 1 }
        }
        $run = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoGoldenGuestAction -Config $Config -Action 'Release' }
        $run.Succeeded | Should -BeFalse
        $run.Error | Should -Match 'Isolation failed'
    }
}

Describe 'New-DemoT2GoldenSnapshot' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:dataDisks = @()
        $script:guestEdition = 'Standard Edition (64-bit)'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPolicyConstraint -MockWith { [pscustomobject]@{ Results = @([pscustomobject]@{ checkId = 'PREFLIGHT.POLICY.RESOURCETYPES'; evidence = [pscustomobject]@{ denied = @() } }) } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:calls.Add('power ' + $Action); New-TestResult ('POWER.' + $Action.ToUpperInvariant()) }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoTargetProfile -MockWith { $script:calls.Add('profile ' + $ProfileName); New-TestResult 'STOP.PROFILE.T2' }
        $script:passwordStatus = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:calls.Add('password'); New-TestResult 'STOP.HOSTPASSWORD' $script:passwordStatus }
        $script:wipeFails = ''
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDiskWipeAction -MockWith {
            $script:calls.Add('wipe ' + $Action)
            $failed = $script:wipeFails -eq $Action
            $data = if ($Action -eq 'GuestFill') { [pscustomobject]@{ succeeded = -not $failed; hostFreeBefore = 90GB; hostFreeAfter = 60GB; guest = [pscustomobject]@{ bytes = 30GB; trimAfter = 'done' } } } else { [pscustomobject]@{ succeeded = -not $failed; host = [pscustomobject]@{ bytes = 55GB; freeAfter = 85GB; trim = 'done'; disks = @() } } }
            [pscustomobject]@{ Succeeded = -not $failed; Data = $data; Error = $(if ($failed) { 'The host''s C: has 20.0 GB free' } else { '' }); Seconds = 1200 }
        }
        $script:sweepPass = $true
        $script:sweepSecurity = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoSignInDataAction -MockWith { $script:calls.Add(('sweep {0} {1} {2}' -f $Action, $Scope, [bool]$PesterBoundParameters['ClearSecurityLog'])); New-TestSweepOutcome -Pass $script:sweepPass -Security $script:sweepSecurity }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
            $script:calls.Add('guest ' + $Action)
            switch ($Action) {
                'Release' { [pscustomobject]@{ Succeeded = $true; Data = [pscustomobject]@{ succeeded = $true; captured = $false }; Error = ''; Seconds = 5 } }
                'Inspect' {
                    [pscustomobject]@{
                        Succeeded = $true; Error = ''; Seconds = 60
                        Data      = [pscustomobject]@{
                            succeeded = $true
                            host      = [pscustomobject]@{ hostState = 'Ready'; productKeyFile = $false; bundleSha256 = 'aa'; runnerSha256 = 'bb'; usedGiB = 37 }
                            guest     = [pscustomobject]@{
                                sqlService = 'Running'; sqlEdition = $script:guestEdition; sqlVersion = '16.0.1000.6'; sqlUpdateLevel = ''; sqlUpdateReference = ''
                                evaluationExpiresUtc = '2027-04-19T13:46:22Z'; setupLogFilesWithToken = 0; signInCacheCount = 0; workloadTask = 'Running'
                                ieEsc = [pscustomobject]@{ administrators = 1; users = 1 }
                                agent = [pscustomobject]@{ status = 'Connected'; resourceName = 'arcsql01'; resourceGroup = 'rg-dbhub-demo'; keys = @('status') }
                            }
                        }
                    }
                }
                'Prepare' {
                    [pscustomobject]@{ Succeeded = $true; Error = ''; Seconds = 120; Data = [pscustomobject]@{ succeeded = $true; cachesRemoved = 0; logFilesRedacted = 0; guestState = 'Off'; guestShutdownSeconds = 40; record = [pscustomobject]@{ sourceAzureVmId = 'vm-source' } } }
                }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $text = $ArgumentList -join ' '
            $script:calls.Add('az ' + $text)
            switch -Regex ($text) {
                '^vm show' {
                    return [pscustomobject]@{
                        hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_E2s_v5' }
                        securityProfile = $null
                        storageProfile  = [pscustomobject]@{ osDisk = [pscustomobject]@{ name = 'archost01-osdisk'; managedDisk = [pscustomobject]@{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/disks/archost01-osdisk' } }; dataDisks = $script:dataDisks }
                    }
                }
                '^group exists' { return (New-AzResult -StdOut 'false') }
                '^group create' { return (New-AzResult -StdOut '{}') }
                '^snapshot create' { return (New-AzResult -StdOut ((New-SnapshotJson) | ConvertTo-Json -Depth 8)) }
                '^disk create' { return (New-AzResult -StdOut '{"provisioningState":"Succeeded"}') }
                '^disk delete' { return (New-AzResult) }
                '^tag update' { return (New-AzResult -StdOut '{}') }
                default { throw ('unexpected: {0}' -f $text) }
            }
        }
    }

    It 'changes nothing under -WhatIf' {
        $results = @(New-DemoT2GoldenSnapshot -Config $config -WhatIf)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE').status | Should -Be 'Not selected'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.POLICY').status | Should -Be 'Pass'
        $script:calls | Should -Not -Contain 'power Start'
        @($script:calls | Where-Object { $_ -match '^az (snapshot|group create|disk)' }).Count | Should -Be 0
    }

    It 'doesn''t capture a T2 that isn''t installed with the setup wizard' {
        $config['t2SqlInstallMode'] = 'Developer'
        $results = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.MODE').status | Should -Be 'Not supported'
        $script:calls | Should -Not -Contain 'power Start'
    }

    It 'doesn''t capture a host with a data disk, because only the OS disk is copied' {
        $script:dataDisks = @([pscustomobject]@{ name = 'archost01-data01' })
        $results = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.HOST').status | Should -Be 'Not supported'
    }

    It 'stops before any change when SQL Server isn''t Standard' {
        $script:guestEdition = 'Developer Edition (64-bit)'
        $results = @(New-DemoT2GoldenSnapshot -Config $config -HostReadyMinutes 0 -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.INSPECT').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'password'
        $script:calls | Should -Not -Contain 'guest Prepare'
    }

    It 'rotates the host password, prepares the guest, deallocates, then takes an incremental DenyAll snapshot and proves a disk from it' {
        $results = @(New-DemoT2GoldenSnapshot -Config $config -NowUtc ([datetime]::new(2026, 10, 22, 12, 30, 0, [System.DateTimeKind]::Utc)) -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.SNAPSHOT').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.DISKVERIFY').status | Should -Be 'Pass'
        $order = @($script:calls | Where-Object { $_ -in 'profile off', 'password', 'sweep Clean Both False', 'guest Prepare', 'power Deallocate' })
        $order | Should -Be @('profile off', 'password', 'sweep Clean Both False', 'guest Prepare', 'power Deallocate') -Because 'the gate never clears the Security log on its own'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.SIGNIN').status | Should -Be 'Pass'
        $create = $script:calls | Where-Object { $_ -match '^az snapshot create' } | Select-Object -First 1
        $create | Should -Match '--incremental true'
        $create | Should -Match '--network-access-policy DenyAll'
        $create | Should -Match '--public-network-access Disabled'
        $create | Should -Match '--resource-group rg-dbhub-golden'
        $create | Should -Match 'dbhubEvalExpiresUtc=2027-04-19T13:46:22Z'
        $create | Should -Match 'dbhubArcIdentity=rg-dbhub-demo/arcsql01'
        $create | Should -Not -Match 'deploymentId='
        $script:calls | Should -Contain 'az disk delete --resource-group rg-dbhub-golden --name snap-dbhub-t2golden-202610221230-verify --yes'
        @($script:calls | Where-Object { $_ -match '^az tag update .*dbhubDiskVerifiedUtc=' }).Count | Should -Be 1
    }
    It 'captures nothing when sign-in data is left on the host or in the guest after the cleanup' {
        $script:sweepPass = $false
        $results = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.SIGNIN').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.SIGNIN').message | Should -Match 'fail closed'
        $script:calls | Should -Not -Contain 'guest Prepare'
        $script:calls | Should -Not -Contain 'power Deallocate'
        @($script:calls | Where-Object { $_ -match '^az snapshot create' }).Count | Should -Be 0
    }

    It 'overwrites the guest''s free space before Prepare and compacts with the guest off before the snapshot, with -WipeFreeSpace' {
        $results = @(New-DemoT2GoldenSnapshot -Config $config -WipeFreeSpace -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.WIPE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.COMPACT').status | Should -Be 'Pass'
        $order = @($script:calls | Where-Object { $_ -match '^(sweep|wipe|guest Prepare|power Deallocate)' })
        $order | Should -Be @('sweep Clean Both False', 'wipe GuestFill', 'guest Prepare', 'wipe HostCompact', 'power Deallocate')
        @($script:calls | Where-Object { $_ -match '^az snapshot create' }).Count | Should -Be 1
    }

    It 'captures nothing when a wipe fails, and wipes nothing without -WipeFreeSpace' {
        $script:wipeFails = 'GuestFill'
        $results = @(New-DemoT2GoldenSnapshot -Config $config -WipeFreeSpace -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.WIPE').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'guest Prepare'
        @($script:calls | Where-Object { $_ -match '^az snapshot create' }).Count | Should -Be 0

        $script:calls.Clear()
        $script:wipeFails = 'HostCompact'
        $results = @(New-DemoT2GoldenSnapshot -Config $config -WipeFreeSpace -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.COMPACT').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'power Deallocate'
        @($script:calls | Where-Object { $_ -match '^az snapshot create' }).Count | Should -Be 0

        $script:calls.Clear()
        $script:wipeFails = ''
        $null = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        @($script:calls | Where-Object { $_ -match '^wipe' }).Count | Should -Be 0
    }

    It 'goes on when the rotation warns that it cleared the Windows PowerShell log that recorded the password' {
        $script:passwordStatus = 'Warning'
        $results = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE').status | Should -Be 'Pass'
        $script:calls | Should -Contain 'guest Prepare'
        $script:passwordStatus = 'Fail'
        $script:calls.Clear()
        $failed = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($failed | Where-Object checkId -EQ 'GOLDEN.CAPTURE.HOSTPASSWORD').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'guest Prepare'
    }

    It 'captures nothing, and asks for manual action, when the Security log holds a token-shaped value' {
        $script:sweepSecurity = 1
        $results = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        $signIn = $results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.SIGNIN'
        $signIn.status | Should -Be 'Manual action required'
        $signIn.message | Should -Match 'Nothing was captured'
        $signIn.remediation | Should -Match ([regex]::Escape('-Clean -ClearSecurityLog'))
        $script:calls | Should -Not -Contain 'guest Prepare'
        @($script:calls | Where-Object { $_ -match '^az snapshot create' }).Count | Should -Be 0
    }
}

Describe 'Test-DemoT2GoldenSnapshot' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:snapshots = @(InModuleScope DbHubDemo -Parameters @{ Item = (New-SnapshotJson) } { ConvertFrom-DemoGoldenSnapshot -Snapshot $Item -NowUtc ([datetime]::new(2026, 10, 22, 13, 0, 0, [System.DateTimeKind]::Utc)) })
        $script:testGroupExists = 'false'
        $script:groupPurpose = 't2-golden-boot-test'
        $script:releaseData = [pscustomobject]@{
            succeeded = $true; role = 'Copy'; guestBootSeconds = 90; sqlService = 'Running'; sqlEdition = 'Standard Edition (64-bit)'; guestPassword = 'Rotated'
            isolation = [pscustomobject]@{ tested = 8; reachable = @(); checkExitCode = 1; checkReachable = @(); checkSample = 'unreachable' }
            agentBefore = [pscustomobject]@{ status = 'Disconnected'; resourceName = 'arcsql01'; resourceGroup = 'rg-dbhub-demo' }
            reset = [pscustomobject]@{ steps = @('disconnect --force-local-only exited 0'); removeExitCode = 0; disconnectExitCode = 0; agentAfter = [pscustomobject]@{ status = 'Disconnected'; resourceName = '' } }
            markerRenamed = $true
        }
        $script:releaseSucceeded = $true
        $script:sourceAfterStatus = 'Disconnected'
        $script:sourceReads = 0
        $script:adapterConnected = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'unexpected Azure CLI call' }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-TestResult 'PREFLIGHT.GUARD.CONTEXT' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { $script:snapshots }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ purpose = $script:groupPurpose } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmAgentReady -MockWith { 30 }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoVmLocalPassword -MockWith { $script:calls.Add('password ' + $Config['environment']); New-TestResult 'STOP.HOSTPASSWORD' }
        $script:sweepPass = $true
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoSignInDataAction -MockWith { $script:calls.Add(('sweep {0} {1} {2}' -f $Action, $Scope, $Config['environment'])); New-TestSweepOutcome -Pass $script:sweepPass }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
            # Strict mode (static validation sets it): a parameter the caller didn't pass isn't a variable here.
            $passed = Get-Variable -Name 'Parameter' -ValueOnly -ErrorAction SilentlyContinue
            $proveIsolation = if ($passed) { $passed['ProveIsolation'] } else { '' }
            $script:calls.Add(('guest {0} {1} {2}' -f $Action, $Config['environment'], $proveIsolation))
            if ($Action -eq 'Inspect') {
                return [pscustomobject]@{ Succeeded = $true; Error = ''; Seconds = 40; Data = [pscustomobject]@{ succeeded = $true; host = [pscustomobject]@{ guestState = 'Off'; guestStartAction = 'Nothing'; guestAdapter = [pscustomobject]@{ count = 1; connected = $script:adapterConnected }; captureRecord = $true; administratorPasswordLastSetUtc = '2026-10-22T13:05:00Z' } } }
            }
            [pscustomobject]@{ Succeeded = $script:releaseSucceeded; Data = $script:releaseData; Error = $(if ($script:releaseSucceeded) { '' } else { 'Isolation failed' }); Seconds = 300 }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith {
            $script:sourceReads++
            $status = if ($script:sourceReads -ge 2) { $script:sourceAfterStatus } else { 'Disconnected' }
            [pscustomobject]@{ properties = [pscustomobject]@{ status = $status; lastStatusChange = '2026-10-22T12:50:00Z'; vmId = 'machine-1'; agentVersion = '1.0'; provisioningState = 'Succeeded' } }
        }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoEnvironment -MockWith {
            $script:calls.Add('teardown ' + $Config['environment'])
            @((New-TestResult 'DESTROY.RESOURCEGROUP'), (New-TestResult 'DESTROY.RESIDUAL'))
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcConfiguration -MockWith { $script:calls.Add('configure ' + $Config['environment']); @((New-TestResult 'T2.ARC.ONBOARDING')) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { @((New-TestResult 'T2.ARC.SQLEXTENSION'), (New-TestResult 'T2.ARC.SQLINSTANCE'), (New-TestResult 'T2.ARC.MONITORING')) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $text = $ArgumentList -join ' '
            $script:calls.Add('az ' + $text)
            switch -Regex ($text) {
                '^group exists' { return (New-AzResult -StdOut $script:testGroupExists) }
                '^vm list-usage' { return @([pscustomobject]@{ name = [pscustomobject]@{ value = 'cores' }; limit = 20; currentValue = 4 }, [pscustomobject]@{ name = [pscustomobject]@{ value = 'standardESv5Family' }; limit = 10; currentValue = 2 }) }
                '^group create' { $script:testGroupExists = 'true'; return (New-AzResult -StdOut '{}') }
                '^disk create' { return (New-AzResult -StdOut '{"provisioningState":"Succeeded"}') }
                '^disk delete' { return (New-AzResult) }
                '^deployment group create' { return (New-AzResult) }
                '^network nsg rule show' { return [pscustomobject]@{ access = 'Deny'; direction = 'Outbound'; destinationAddressPrefix = '*'; priority = 90 } }
                '^network nsg rule delete' { return (New-AzResult) }
                '^tag update' { return (New-AzResult -StdOut '{}') }
                '^monitor activity-log list' { return @() }
                '^snapshot delete' { return (New-AzResult) }
                default { throw ('unexpected: {0}' -f $text) }
            }
        }
    }

    It 'refuses a test environment that is the demo''s own' {
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -TestEnvironment 'demo' -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.ENVIRONMENT').status | Should -Be 'Fail'
        @($script:calls | Where-Object { $_ -match '^az group create' }).Count | Should -Be 0
    }

    It 'fails without a golden snapshot' {
        $script:snapshots = @()
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.SNAPSHOT').status | Should -Be 'Fail'
    }

    It 'refuses to start when the test group already exists' {
        $script:testGroupExists = 'true'
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.GROUP').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'teardown gtest'
    }

    It 'creates nothing under -WhatIf' {
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -WhatIf)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Not selected'
        @($script:calls | Where-Object { $_ -match '^az (group create|disk create|deployment)' }).Count | Should -Be 0
    }

    It 'deletes only a group tagged as the boot test''s with -CleanupOnly' {
        $script:testGroupExists = 'true'
        $script:groupPurpose = 'customer-demo'
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -CleanupOnly -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.TEARDOWN').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'teardown gtest'
    }

    It 'proves the copy in quarantine in the test group, then deletes the group through the destroy path' {
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Pass'
        foreach ($id in 'GOLDEN.TEST.DISK', 'GOLDEN.TEST.DEPLOY', 'GOLDEN.TEST.AIRGAP', 'GOLDEN.TEST.ISOLATION', 'GOLDEN.TEST.RESET', 'GOLDEN.TEST.SQL', 'GOLDEN.TEST.GUESTPASSWORD', 'GOLDEN.TEST.SIGNIN', 'GOLDEN.TEST.BOOT', 'GOLDEN.TEST.SOURCE', 'GOLDEN.TEST.TEARDOWN') {
            ($results | Where-Object checkId -EQ $id).status | Should -Be 'Pass' -Because $id
        }
        $script:calls | Should -Contain 'password gtest'
        $script:calls | Should -Contain 'guest Release gtest true'
        $script:calls | Should -Contain 'teardown gtest'
        $order = @($script:calls | Where-Object { $_ -match '^(password|guest|sweep|teardown)' })
        $order | Should -Be @('password gtest', 'guest Inspect gtest ', 'guest Release gtest true', 'sweep Scan Both gtest', 'teardown gtest')
        $deploy = $script:calls | Where-Object { $_ -match '^az deployment group create' } | Select-Object -First 1
        $deploy | Should -Match '--resource-group rg-dbhub-gtest'
        $deploy | Should -Match 'infra[\\/]golden-test\.bicep'
        $group = $script:calls | Where-Object { $_ -match '^az group create' } | Select-Object -First 1
        $group | Should -Match 'purpose=t2-golden-boot-test'
        $group | Should -Match 'ArcSQLServerExtensionDeployment=PAYG'
        $group | Should -Match 'deploymentId=[0-9a-f]{6}'
        @($script:calls | Where-Object { $_ -match '^az tag update .*dbhubBootVerifiedUtc=' }).Count | Should -Be 1
        $script:calls | Should -Not -Contain 'configure gtest'
    }

    It 'onboards the reset copy fresh after deleting the deny rule with -Onboard' {
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.ONBOARD').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Pass'
        $order = @($script:calls | Where-Object { $_ -match '^(az network nsg rule delete|configure|teardown)' })
        $order[0] | Should -Match 'Deny-Quarantine-Outbound'
        $order[1] | Should -Be 'configure gtest'
        $order[2] | Should -Be 'teardown gtest'
        @($script:calls | Where-Object { $_ -match '^az tag update .*dbhubOnboardVerifiedUtc=' }).Count | Should -Be 1
    }

    It 'gives the copy its own onboarding identity with assignRoles and -Onboard, and counts an onboarding that warns only about sign-in data' {
        $script:templateParameters = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoPrivateFile -MockWith { $script:templateParameters.Add($Content); Join-Path -Path $Directory -ChildPath $Name }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcConfiguration -MockWith {
            $script:calls.Add('configure ' + $Config['environment'])
            @(New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'arcsql01 is onboarded and Connected; the cleanup cleared Windows PowerShell on archost01.' -Evidence @{ azureStatus = 'Connected'; tokenSource = 'HostIdentity' })
        }
        $config['assignRoles'] = $true
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        ($script:templateParameters[0] | ConvertFrom-Json).parameters.assignArcOnboardingRole.value | Should -BeTrue
        $onboard = $results | Where-Object checkId -EQ 'GOLDEN.TEST.ONBOARD'
        $onboard.status | Should -Be 'Pass'
        $onboard.message | Should -Match 'with the host identity'
        $onboard.evidence['tokenSource'] | Should -Be 'HostIdentity'

        $script:templateParameters.Clear()
        $script:testGroupExists = 'false'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcConfiguration -MockWith {
            @(New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'Azure shows the machine as Disconnected.' -Evidence @{ azureStatus = 'Disconnected' })
        }
        $config['assignRoles'] = $false
        $notConnected = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        ($script:templateParameters[0] | ConvertFrom-Json).parameters.assignArcOnboardingRole.value | Should -BeFalse
        ($notConnected | Where-Object checkId -EQ 'GOLDEN.TEST.ONBOARD').status | Should -Be 'Fail'
    }

    It 'resets nothing, tags nothing, and still deletes the copy when an endpoint answers from the quarantined guest' {
        $script:releaseSucceeded = $false
        $script:releaseData.isolation.reachable = @('management.azure.com')
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.ISOLATION').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Fail'
        @($script:calls | Where-Object { $_ -match '^az tag update' }).Count | Should -Be 0
        $script:calls | Should -Not -Contain 'configure gtest'
        $script:calls | Should -Contain 'teardown gtest'
    }

    It 'keeps older golden snapshots with -KeepOlderSnapshots, and deletes them without it once the newest passes' {
        $older = New-SnapshotJson -Name 'snap-dbhub-t2golden-202610201200' -Captured '2026-10-20T12:00:00Z'
        $script:snapshots = @(InModuleScope DbHubDemo -Parameters @{ Items = @((New-SnapshotJson), $older) } { foreach ($item in $Items) { ConvertFrom-DemoGoldenSnapshot -Snapshot $item -NowUtc ([datetime]::new(2026, 10, 22, 13, 0, 0, [System.DateTimeKind]::Utc)) } })
        $kept = @(Test-DemoT2GoldenSnapshot -Config $config -KeepOlderSnapshots -Confirm:$false)
        ($kept | Where-Object checkId -EQ 'GOLDEN.TEST.PREVIOUS').status | Should -Be 'Not selected'
        ($kept | Where-Object checkId -EQ 'GOLDEN.TEST.PREVIOUS').message | Should -Match 'kept \(-KeepOlderSnapshots\)'
        @($script:calls | Where-Object { $_ -match '^az snapshot delete' }).Count | Should -Be 0
        $script:calls.Clear()
        $script:testGroupExists = 'false'
        $deleted = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($deleted | Where-Object checkId -EQ 'GOLDEN.TEST.PREVIOUS').status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -match '^az snapshot delete .*snap-dbhub-t2golden-202610201200' }).Count | Should -Be 1
    }
    It 'tags nothing, onboards nothing, deletes no older snapshot, and still deletes the copy when the copy holds sign-in data' {
        $script:sweepPass = $false
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.SIGNIN').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.BOOT').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Fail'
        @($script:calls | Where-Object { $_ -match '^az (tag update|snapshot delete)' }).Count | Should -Be 0
        $script:calls | Should -Not -Contain 'configure gtest'
        $script:calls | Should -Contain 'teardown gtest'
    }

    It 'fails when the source''s Arc machine reports Connected during the test' {
        $script:sourceAfterStatus = 'Connected'
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Fail'
    }

    It 'warns, not fails, when the source still reads Connected minutes after its capture' {
        $script:sourceAfterStatus = 'Connected'
        $recent = New-SnapshotJson
        $recent.tags | Add-Member -NotePropertyName 'dbhubDiskVerifiedUtc' -NotePropertyValue ([DateTime]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        $script:snapshots = @(InModuleScope DbHubDemo -Parameters @{ Item = $recent } { ConvertFrom-DemoGoldenSnapshot -Snapshot $Item })
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE').status | Should -Be 'Warning'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Pass'
    }

    It 'never starts a copy whose guest adapter booted connected, and deletes it' {
        $script:adapterConnected = 1
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.AIRGAP').status | Should -Be 'Fail'
        $script:calls | Should -Not -Contain 'guest Release gtest true'
        $script:calls | Should -Contain 'teardown gtest'
        @($script:calls | Where-Object { $_ -match '^az tag update' }).Count | Should -Be 0
    }
}

Describe 'Invoke-DemoGoldenSourceRelease' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:vmId = 'aaaaaaaa-0000-0000-0000-000000000001'
        $script:released = $null
        $script:releaseOk = $true
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $text = $ArgumentList -join ' '
            $script:calls.Add(($ArgumentList[0..1] -join ' '))
            if ($text -match '^vm show') {
                return (New-AzResult -StdOut ($script:vmId + "`n"))
            }
            New-AzResult
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith {
            @([pscustomobject]@{ Name = 'snap-dbhub-t2golden-202610221306'; Id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/snap-dbhub-t2golden-202610221306'; SourceGroup = 'rg-dbhub-demo'; SourceAzureVmId = 'aaaaaaaa-0000-0000-0000-000000000001'; SourceReleasedUtc = $script:released })
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
            $script:calls.Add('Release')
            [pscustomobject]@{ Succeeded = $script:releaseOk; Error = $(if ($script:releaseOk) { '' } else { 'the guest is gone' }); Seconds = 45; Data = [pscustomobject]@{ role = 'Source'; captured = $true } }
        }
    }

    It 'reconnects the source host''s guest once and records it on the snapshot' {
        $result = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoGoldenSourceRelease -Config $c } $config
        $result.checkId | Should -Be 'T2.GOLDEN.SOURCE'
        $result.status | Should -Be 'Pass'
        $script:calls | Should -Contain 'Release'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^tag update --resource-id /subscriptions/.*/snapshots/snap-dbhub-t2golden-202610221306 --operation Merge --tags dbhubSourceReleasedUtc=' }
    }

    It 'does nothing on a host that isn''t a capture source, or once the release is recorded' {
        $script:vmId = 'bbbbbbbb-0000-0000-0000-000000000002'
        & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoGoldenSourceRelease -Config $c } $config | Should -BeNullOrEmpty
        $script:vmId = 'aaaaaaaa-0000-0000-0000-000000000001'
        $script:released = [datetime]'2026-10-22T16:00:00Z'
        & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoGoldenSourceRelease -Config $c } $config | Should -BeNullOrEmpty
        $script:calls | Should -Not -Contain 'Release'
    }

    It 'fails when the guest can''t be reconnected, and records nothing' {
        $script:releaseOk = $false
        $result = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoGoldenSourceRelease -Config $c } $config
        $result.status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'tag' }
    }
}

Describe 'Request-DemoVmStart' {
    BeforeEach {
        $config = New-TestConfig
        $script:power = 'PowerState/deallocated'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { New-AzResult }
    }

    It 'requests a start without waiting for a deallocated VM, and leaves a running one alone' {
        & (Get-Module -Name DbHubDemo) { param($c) Request-DemoVmStart -Config $c -VmName 'archost01' } $config | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^vm start --resource-group rg-dbhub-demo --name archost01 --no-wait' }
        $script:power = 'PowerState/running'
        & (Get-Module -Name DbHubDemo) { param($c) Request-DemoVmStart -Config $c -VmName 'archost01' } $config | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'start' }
    }
}

Describe 'Get-DemoT2GoldenStatus' {
    BeforeEach {
        $config = New-TestConfig
        $config['expiresOn'] = ''
        $script:make = {
            param([object] $Days, [object] $Boot = [datetime]'2026-10-22T14:30:00Z')
            [pscustomobject]@{ Name = 'snap-dbhub-t2golden-202610221306'; CapturedUtc = [datetime]'2026-10-22T13:06:00Z'; BootVerifiedUtc = $Boot; OnboardVerifiedUtc = $null; EvalExpiresUtc = ([datetime]'2026-10-22').AddDays([int]$Days); EvalDaysLeft = $Days; SizeGiB = 128; UsedGiB = 37 }
        }
    }

    It 'is Not selected without a snapshot and says how to capture one' {
        $result = & (Get-Module -Name DbHubDemo) { param($c) Get-DemoT2GoldenStatus -Config $c -Snapshot @() } $config
        $result.status | Should -Be 'Not selected'
        $result.remediation | Should -Match 'capture-t2-golden\.ps1'
    }

    It 'warns when no snapshot is usable, at 30 days, at 7 days, and before expiresOn; passes otherwise' {
        $status = { param([object[]] $Items, [System.Collections.IDictionary] $Configuration) & (Get-Module -Name DbHubDemo) { param($c, $s) Get-DemoT2GoldenStatus -Config $c -Snapshot $s } $Configuration $Items }
        (& $status @(& $script:make 100 $null) $config).status | Should -Be 'Warning'
        (& $status @(& $script:make 0) $config).status | Should -Be 'Warning'
        (& $status @(& $script:make 25) $config).status | Should -Be 'Warning'
        (& $status @(& $script:make 5) $config).message | Should -Match 're-capture now'
        (& $status @(& $script:make 100) $config).status | Should -Be 'Pass'
        $config['expiresOn'] = '2027-12-31'
        (& $status @(& $script:make 100) $config).message | Should -Match 'before the environment''s expiresOn'
    }
}
