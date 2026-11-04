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
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:calls.Add('power ' + $Action); New-TestResult ('POWER.' + $Action.ToUpperInvariant()) $(if ($script:powerFails -eq $Action) { 'Fail' } else { 'Pass' }) }
        $script:powerFails = ''
        $script:hostPower = 'PowerState/deallocated'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:hostPower }
        Mock -ModuleName DbHubDemo -CommandName Restore-DemoGoldenCaptureSource -MockWith { $script:calls.Add('restore ' + $FoundPowerState); New-TestResult 'GOLDEN.CAPTURE.SOURCE' }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
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
        $script:prepareFails = $false
        $script:snapshotFails = ''
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoSignInDataAction -MockWith { $script:calls.Add(('sweep {0} {1} {2}' -f $Action, $Scope, [bool]$PesterBoundParameters['ClearSecurityLog'])); New-TestSweepOutcome -Pass $script:sweepPass -Security $script:sweepSecurity }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2GoldenSnapshot -MockWith { @() }
        $script:controlStatus = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGoldenCaptureControlResult -MockWith { $script:calls.Add('control'); New-TestResult 'GOLDEN.CAPTURE.CONTROL' $script:controlStatus }
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
                    if ($script:prepareFails) {
                        return [pscustomobject]@{ Succeeded = $false; Error = 'The guest did not shut down cleanly within 15 minutes (state Running); it was not turned off by force.'; Seconds = 900; Data = [pscustomobject]@{ succeeded = $false } }
                    }
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
                '^snapshot create' {
                    if ($script:snapshotFails -eq 'throw') { throw 'The Azure CLI stopped.' }
                    if ($script:snapshotFails -eq 'policy') { return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (RequestDisallowedByPolicy) Resource was disallowed by policy.') }
                    return (New-AzResult -StdOut ((New-SnapshotJson) | ConvertTo-Json -Depth 8))
                }
                '^disk create' {
                    if ($script:snapshotFails -eq 'disk') { return (New-AzResult -ExitCode 1 -StdErr 'ERROR: (InternalError) The disk could not be created.') }
                    return (New-AzResult -StdOut '{"provisioningState":"Succeeded"}')
                }
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

    It 'returns the source to service after the snapshot and its disk check, to the power state the capture found (live, 2026-11-03)' {
        # 2026-10-28: the capture left the source air-gapped, and T2 stayed missing from every Fabric start after it.
        $results = @(New-DemoT2GoldenSnapshot -Config $config -NowUtc ([datetime]::new(2026, 10, 22, 12, 30, 0, [System.DateTimeKind]::Utc)) -Confirm:$false)
        @($script:calls | Where-Object { $_ -match '^restore' }) | Should -Be @('restore PowerState/deallocated')
        $verified = [array]::FindIndex([string[]]$script:calls.ToArray(), [Predicate[string]] { param($call) $call -match '^az tag update .*dbhubDiskVerifiedUtc=' })
        $restored = [array]::IndexOf([string[]]$script:calls.ToArray(), 'restore PowerState/deallocated')
        $restored | Should -BeGreaterThan $verified
        @($results | ForEach-Object checkId | Select-Object -Last 2) | Should -Be @('GOLDEN.CAPTURE', 'GOLDEN.CAPTURE.SOURCE')
        $script:hostPower = 'PowerState/running'
        $script:calls.Clear()
        $null = New-DemoT2GoldenSnapshot -Config $config -Confirm:$false
        @($script:calls | Where-Object { $_ -match '^restore' }) | Should -Be @('restore PowerState/running')
    }

    It 'returns the source to service when <Case>, and captures nothing more' -ForEach @(
        @{ Case = 'Prepare fails after the air gap'; Setup = { $script:prepareFails = $true }; Check = 'GOLDEN.CAPTURE.PREPARE'; Wipe = $false }
        @{ Case = 'the compaction fails with the guest off'; Setup = { $script:wipeFails = 'HostCompact' }; Check = 'GOLDEN.CAPTURE.COMPACT'; Wipe = $true }
        @{ Case = 'the host doesn''t deallocate'; Setup = { $script:powerFails = 'Deallocate' }; Check = 'POWER.DEALLOCATE'; Wipe = $false }
        @{ Case = 'a policy denies the snapshot'; Setup = { $script:snapshotFails = 'policy' }; Check = 'GOLDEN.CAPTURE.SNAPSHOT'; Wipe = $false }
        @{ Case = 'no disk can be created from the snapshot'; Setup = { $script:snapshotFails = 'disk' }; Check = 'GOLDEN.CAPTURE.DISKVERIFY'; Wipe = $false }
    ) {
        & $Setup
        $results = @(New-DemoT2GoldenSnapshot -Config $config -WipeFreeSpace:([bool]$Wipe) -Confirm:$false)
        ($results | Where-Object checkId -EQ $Check).status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE') | Should -BeNullOrEmpty
        @($script:calls | Where-Object { $_ -match '^restore' }).Count | Should -Be 1
        $results[-1].checkId | Should -Be 'GOLDEN.CAPTURE.SOURCE'
        if ($Check -eq 'GOLDEN.CAPTURE.SNAPSHOT') {
            ($results | Where-Object checkId -EQ $Check).remediation | Should -Not -Match 'air-gapped until'
        }
    }

    It 'returns the source to service even when a step after Prepare throws' {
        $script:snapshotFails = 'throw'
        { New-DemoT2GoldenSnapshot -Config $config -Confirm:$false } | Should -Throw '*Azure CLI stopped*'
        @($script:calls | Where-Object { $_ -match '^restore' }).Count | Should -Be 1
    }

    It 'touches no source when the capture stops before Prepare, or under -WhatIf' {
        $script:sweepPass = $false
        $null = New-DemoT2GoldenSnapshot -Config $config -Confirm:$false
        $script:passwordStatus = 'Fail'
        $script:sweepPass = $true
        $null = New-DemoT2GoldenSnapshot -Config $config -Confirm:$false
        $null = New-DemoT2GoldenSnapshot -Config $config -WhatIf
        @($script:calls | Where-Object { $_ -match '^restore' }) | Should -BeNullOrEmpty
    }

    It 'captures nothing, and touches nothing, while an on-demand run is active; -WhatIf doesn''t read the control (review, 2026-11-04)' {
        $script:controlStatus = 'Fail'
        $results = @(New-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.CAPTURE.CONTROL').status | Should -Be 'Fail'
        $results[-1].checkId | Should -Be 'GOLDEN.CAPTURE.CONTROL'
        @($script:calls | Where-Object { $_ -match '^(power|guest|profile|password|restore)' }) | Should -BeNullOrEmpty
        $script:calls.Clear()
        $null = New-DemoT2GoldenSnapshot -Config $config -WhatIf
        $script:calls | Should -Not -Contain 'control'
    }

    It 'ends an interrupted capture''s marker with its own first Release, and checks the control before it starts the host' {
        $null = New-DemoT2GoldenSnapshot -Config $config -Confirm:$false
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -Times 1 -Exactly -ParameterFilter { $Action -eq 'Release' -and [string]$Parameter['EndCapture'] -eq 'true' }
        [array]::IndexOf([string[]]$script:calls.ToArray(), 'control') | Should -BeLessThan ([array]::IndexOf([string[]]$script:calls.ToArray(), 'power Start'))
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
        $script:sourceBeforeStatus = 'Disconnected'
        $script:sourceBeforeChange = '2026-10-22T12:50:00Z'
        $script:sourceAfterStatus = 'Disconnected'
        $script:sourceAfterChange = '2026-10-22T12:50:00Z'
        $script:activityLog = @()
        $script:sourceReads = 0
        $script:adapterConnected = 0
        # The source host's power state for each read (the last one repeating), and its provisioning status's time.
        $script:sourceHostPower = @('PowerState/deallocated')
        $script:sourceHostSince = '2026-10-22T12:40:00Z'
        $script:hostReads = 0
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
            $after = $script:sourceReads -ge 2
            $status = if ($after) { $script:sourceAfterStatus } else { $script:sourceBeforeStatus }
            $change = if ($after) { $script:sourceAfterChange } else { $script:sourceBeforeChange }
            # 'now': a status change at the time of the read, inside the test's window.
            if ($change -eq 'now') { $change = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
            [pscustomobject]@{ properties = [pscustomobject]@{ status = $status; lastStatusChange = $change; vmId = 'machine-1'; agentVersion = '1.0'; provisioningState = 'Succeeded' } }
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
                '^monitor activity-log list' { return $script:activityLog }
                '^snapshot delete' { return (New-AzResult) }
                '^vm get-instance-view --resource-group rg-dbhub-demo --name archost01' {
                    $script:hostReads++
                    $power = @($script:sourceHostPower)[[Math]::Min($script:hostReads, @($script:sourceHostPower).Count) - 1]
                    return [pscustomobject]@{ instanceView = [pscustomobject]@{ statuses = @([pscustomobject]@{ code = 'ProvisioningState/succeeded'; time = $script:sourceHostSince }, [pscustomobject]@{ code = $power }) } }
                }
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

    It 'passes a source that only Resource Health events mention, and keeps every entry with its category in the evidence' {
        # The 2026-10-28 proof: Disconnected before and after with the same last status change, and Resource Health
        # events about the machine while its host was deallocated.
        $script:activityLog = @(
            [pscustomobject]@{ operation = 'Microsoft.Resourcehealth/healthevent/Resolved/action'; category = 'ResourceHealth'; status = 'Resolved'; time = [DateTime]::UtcNow.ToString('o') }
            [pscustomobject]@{ operation = 'Microsoft.Resourcehealth/healthevent/Activated/action'; category = 'ResourceHealth'; status = 'Active'; time = [DateTime]::UtcNow.ToString('o') }
        )
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Onboard -Confirm:$false)
        $source = $results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE'
        $source.status | Should -Be 'Pass'
        $source.message | Should -Match '2 other event\(s\) there \(ResourceHealth\) aren''t operations'
        @($source.evidence['operations']).Count | Should -Be 0
        @($source.evidence['otherEvents']).Count | Should -Be 2
        @($source.evidence['otherEvents'] | ForEach-Object { $_.category } | Sort-Object -Unique) | Should -Be @('ResourceHealth')
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -match '^az monitor activity-log list .*category: category\.value' }).Count | Should -Be 1
    }

    It 'fails when the Activity Log shows an Administrative operation on the source' {
        $script:activityLog = @(
            [pscustomobject]@{ operation = 'Microsoft.HybridCompute/machines/write'; category = 'Administrative'; status = 'Succeeded'; time = [DateTime]::UtcNow.ToString('o') }
            [pscustomobject]@{ operation = 'Microsoft.Resourcehealth/healthevent/Activated/action'; category = 'ResourceHealth'; status = 'Active'; time = [DateTime]::UtcNow.ToString('o') }
        )
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        $source = $results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE'
        $source.status | Should -Be 'Fail'
        $source.message | Should -Match 'shows 1 operation\(s\) on it'
        @($source.evidence['operations']).Count | Should -Be 1
        @($source.evidence['otherEvents']).Count | Should -Be 1
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Fail'
    }

    It 'fails when a source that was Disconnected before the test has a later status change after it' {
        # Connected for a while during the test, and Disconnected again by the time it's read.
        $script:sourceAfterChange = 'now'
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        $source = $results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE'
        $source.status | Should -Be 'Fail'
        $source.message | Should -Match 'its status changed during the test'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Fail'
    }

    It 'doesn''t fail a source that read Connected right after its capture and turned Disconnected during the test' {
        $recent = New-SnapshotJson
        $recent.tags | Add-Member -NotePropertyName 'dbhubDiskVerifiedUtc' -NotePropertyValue ([DateTime]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        $script:snapshots = @(InModuleScope DbHubDemo -Parameters @{ Item = $recent } { ConvertFrom-DemoGoldenSnapshot -Snapshot $Item })
        $script:sourceBeforeStatus = 'Connected'
        $script:sourceBeforeChange = [DateTime]::UtcNow.AddMinutes(-40).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $script:sourceAfterChange = 'now'
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE').status | Should -Not -Be 'Fail'
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Pass'
    }

    It 'warns, not fails, when the source host ran during the test: the capture returns its source to service (2026-11-03)' {
        $script:sourceHostPower = @('PowerState/running')
        $script:sourceBeforeStatus = 'Connected'
        $script:sourceAfterStatus = 'Connected'
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        $source = $results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE'
        $source.status | Should -Be 'Warning'
        $source.message | Should -Match 'its host archost01 wasn''t deallocated for the whole test \(running before, running after\), so its status \(Connected\) is its own'
        $source.remediation | Should -Match 'stop-demo\.ps1'
        $source.evidence['hostStayedDeallocated'] | Should -BeFalse
        ($results | Where-Object checkId -EQ 'GOLDEN.TEST').status | Should -Be 'Pass'
    }

    It 'still fails a source whose host ran on an operation in the Activity Log, and reads a host that started during the test as running' {
        $script:sourceHostPower = @('PowerState/deallocated', 'PowerState/running')
        $script:sourceAfterStatus = 'Connected'
        $script:sourceAfterChange = 'now'
        $script:activityLog = @([pscustomobject]@{ operation = 'Microsoft.HybridCompute/machines/write'; category = 'Administrative'; status = 'Succeeded'; time = [DateTime]::UtcNow.ToString('o') })
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        $source = $results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE'
        $source.status | Should -Be 'Fail'
        $source.message | Should -Match 'shows 1 operation'
        $source.message | Should -Not -Match 'turned Connected during the test'
    }

    It 'counts a source''s quiet minutes from its host''s deallocation after the capture''s release' {
        # The capture released the source 40 minutes ago and deallocated its host 10 minutes ago: a Connected status
        # is still the decay, not a heartbeat.
        $released = New-SnapshotJson
        $released.tags | Add-Member -NotePropertyName 'dbhubDiskVerifiedUtc' -NotePropertyValue ([DateTime]::UtcNow.AddMinutes(-60).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        $released.tags | Add-Member -NotePropertyName 'dbhubSourceReleasedUtc' -NotePropertyValue ([DateTime]::UtcNow.AddMinutes(-40).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        $script:snapshots = @(InModuleScope DbHubDemo -Parameters @{ Item = $released } { ConvertFrom-DemoGoldenSnapshot -Snapshot $Item })
        $script:sourceHostSince = [DateTime]::UtcNow.AddMinutes(-10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $script:sourceBeforeStatus = 'Connected'
        $script:sourceAfterStatus = 'Connected'
        $script:sourceBeforeChange = [DateTime]::UtcNow.AddMinutes(-45).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $script:sourceAfterChange = $script:sourceBeforeChange
        $results = @(Test-DemoT2GoldenSnapshot -Config $config -Confirm:$false)
        $source = $results | Where-Object checkId -EQ 'GOLDEN.TEST.SOURCE'
        $source.status | Should -Be 'Warning'
        $source.evidence['minutesSinceCapture'] | Should -BeLessOrEqual 11
        $source.message | Should -Match 'before Azure marks it Disconnected'
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
        # Only the capture's own return of its source ends its marker (review, 2026-11-04).
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -Times 0 -Exactly -ParameterFilter { $Parameter.Contains('EndCapture') }
        $script:released = $null
        $null = & (Get-Module -Name DbHubDemo) { param($c) Invoke-DemoGoldenSourceRelease -Config $c -EndCapture } $config
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -Times 1 -Exactly -ParameterFilter { [string]$Parameter['EndCapture'] -eq 'true' }
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

Describe 'Restore-DemoGoldenCaptureSource' {
    BeforeEach {
        $config = New-TestConfig
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:clock = [datetime]::new(2026, 11, 3, 14, 0, 0, [System.DateTimeKind]::Utc)
        $script:airGap = $script:clock.AddMinutes(-15)
        $script:power = 'PowerState/deallocated'
        $script:powerFails = ''
        $script:sourceRelease = 'Pass'
        $script:guestRelease = $true
        $script:adapterBefore = 0
        # arcsql01's status for the clock; by default Disconnected until 4 minutes after the release, then Connected.
        $script:arc = { if ($script:clock -lt $script:releasedAt.AddMinutes(4)) { @('Disconnected', $script:airGap.AddMinutes(20)) } else { @('Connected', $script:releasedAt.AddMinutes(4)) } }
        $script:releasedAt = $script:clock
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:clock }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:clock = $script:clock.AddSeconds($Seconds) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { $script:power }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith {
            $script:calls.Add('power ' + $Action)
            if ($script:powerFails -eq $Action) { return (New-TestResult ('POWER.' + $Action.ToUpperInvariant()) 'Warning') }
            $script:power = if ($Action -eq 'Start') { 'PowerState/running' } else { 'PowerState/deallocated' }
            New-TestResult ('POWER.' + $Action.ToUpperInvariant())
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -MockWith {
            $script:calls.Add('source release')
            $script:releasedAt = $script:clock
            if ($script:sourceRelease) { New-DemoResult -CheckId 'T2.GOLDEN.SOURCE' -Area 't2' -Target 'T2' -Status $script:sourceRelease -Message 'archost01 is the source of snap-1.' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -MockWith {
            $script:calls.Add('guest ' + $Action)
            $script:releasedAt = $script:clock
            [pscustomobject]@{ Succeeded = $script:guestRelease; Error = $(if ($script:guestRelease) { '' } else { 'The virtual machine arcsql01 could not be found.' }); Seconds = 30; Data = [pscustomobject]@{ succeeded = $script:guestRelease; role = 'Source'; captured = $true; before = [pscustomobject]@{ guestState = 'Off'; startAction = 'Nothing'; adapter = [pscustomobject]@{ count = 1; connected = $script:adapterBefore } } } }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith {
            $script:calls.Add('arc')
            $state = & $script:arc
            [pscustomobject]@{ properties = [pscustomobject]@{ status = $state[0]; lastStatusChange = $state[1].ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } }
        }
        Mock -ModuleName DbHubDemo -CommandName Stop-DemoGuestVm -MockWith { $script:calls.Add('guest stop'); New-TestResult 'STOP.GUEST' }
        function Invoke-Restore([string] $Found = 'PowerState/deallocated', [int] $Wait = 30) {
            & (Get-Module -Name DbHubDemo) { param($c, $f, $g, $w) Restore-DemoGoldenCaptureSource -Config $c -FoundPowerState $f -AirGapUtc $g -ArcWaitMinutes $w } $config $Found $script:airGap $Wait
        }
    }

    It 'starts the deallocated source, releases it, sees arcsql01 reconnect, and deallocates it again after a clean guest stop' {
        $result = Invoke-Restore
        $result.checkId | Should -Be 'GOLDEN.CAPTURE.SOURCE'
        $result.status | Should -Be 'Pass'
        $result.evidence['arcProof'] | Should -Be 'reconnected'
        $result.evidence['hostAfter'] | Should -Be 'deallocated'
        $result.message | Should -Match 'deallocated again, as the capture found it'
        @($script:calls | Where-Object { $_ -ne 'arc' }) | Should -Be @('power Start', 'source release', 'guest stop', 'power Deallocate')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -Times 0 -Exactly
        # The capture's own Release ends its marker (review, 2026-11-04).
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenSourceRelease -Times 1 -Exactly -ParameterFilter { $EndCapture }
    }

    It 'doesn''t take a Connected status left over from before the air gap for a reconnection' {
        # Azure marks a machine Disconnected 15 to 30 minutes after its last heartbeat: right after a short capture it
        # can still read Connected, with a last status change from before the air gap.
        $script:arc = { @('Connected', $script:airGap.AddMinutes(-120)) }
        $result = Invoke-Restore
        $result.status | Should -Be 'Pass'
        $result.evidence['arcProof'] | Should -Be 'heartbeat'
        $script:clock | Should -BeGreaterOrEqual $script:airGap.AddMinutes(30)
        $script:clock | Should -BeLessThan $script:airGap.AddMinutes(31)
        $script:clock = $script:airGap.AddMinutes(15)
        $script:power = 'PowerState/deallocated'
        $short = Invoke-Restore -Wait 5
        $short.status | Should -Be 'Warning'
        $short.message | Should -Match 'may still be the one from before the air gap'
        $short.remediation | Should -Match 'T2\.ARC\.CONNECTED'
    }

    It 'leaves a source the capture found running running, without a guest stop' {
        $script:power = 'PowerState/running'
        $result = Invoke-Restore -Found 'PowerState/running'
        $result.status | Should -Be 'Pass'
        $result.evidence['hostAfter'] | Should -Be 'running'
        @($script:calls | Where-Object { $_ -ne 'arc' }) | Should -Be @('source release')
    }

    It 'releases the guest itself when no snapshot names the host yet, and needs no proof when the guest was never disconnected' {
        $script:sourceRelease = ''
        $script:power = 'PowerState/running'
        $script:adapterBefore = 1
        $script:arc = { @('Connected', $script:airGap.AddMinutes(-120)) }
        $result = Invoke-Restore -Found 'PowerState/running'
        $result.status | Should -Be 'Pass'
        $result.evidence['release'] | Should -Be 'Release'
        $result.evidence['arcProof'] | Should -Be 'never disconnected'
        @($script:calls | Where-Object { $_ -eq 'arc' }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoGoldenGuestAction -Times 1 -Exactly -ParameterFilter { $Action -eq 'Release' -and [string]$Parameter['EndCapture'] -eq 'true' }
    }

    It 'fails when the guest can''t be released, and still deallocates the host it started' {
        $script:sourceRelease = 'Fail'
        $result = Invoke-Restore
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'stays air-gapped'
        $result.remediation | Should -Match 'start-demo\.ps1'
        $script:calls | Should -Not -Contain 'arc'
        $script:calls | Should -Contain 'power Deallocate'
    }

    It 'fails when arcsql01 doesn''t reconnect within the wait' {
        $script:arc = { @('Disconnected', $script:airGap.AddMinutes(20)) }
        $result = Invoke-Restore -Wait 20
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'arcsql01 is Disconnected after 20 minutes'
        $result.remediation | Should -Match 'validate\.ps1 -Area T2'
        $result.evidence['hostAfter'] | Should -Be 'deallocated'
    }

    It 'warns when the host can''t be deallocated again, or when the release wasn''t recorded on the snapshot' {
        $script:powerFails = 'Deallocate'
        $result = Invoke-Restore
        $result.status | Should -Be 'Warning'
        $result.remediation | Should -Match 'stop-demo\.ps1'
        $script:powerFails = ''
        $script:power = 'PowerState/deallocated'
        $script:sourceRelease = 'Warning'
        $script:releasedAt = $script:clock
        $recorded = Invoke-Restore
        $recorded.status | Should -Be 'Warning'
        $recorded.message | Should -Match 'releases it again, which is harmless'
    }

    It 'fails without a release when the host doesn''t start' {
        $script:powerFails = 'Start'
        $result = Invoke-Restore
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'didn''t start'
        $script:calls | Should -Not -Contain 'source release'
    }
}

Describe 'Get-DemoT2GuestStateResult (T2.GUEST.STATE, 2026-11-03)' {
    BeforeAll {
        $config = New-TestConfig
        function Get-GuestState([object] $Guest, [string] $HostState = 'Ready') {
            $health = [pscustomobject]@{ status = 'Pass'; state = $HostState; currentStep = 'Watchdog'; t2Guest = $Guest }
            & (Get-Module -Name DbHubDemo) { param($c, $h) Get-DemoT2GuestStateResult -Config $c -Health $h } $config $health
        }
        function New-Guest([string] $State = 'Running', [string] $Heartbeat = 'OkApplicationsHealthy', [string] $StartAction = 'Start', [int] $Adapters = 1, [int] $Connected = 1, [object] $Golden = $null) {
            $guest = [ordered]@{ present = $true; state = $State; heartbeat = $Heartbeat; startAction = $StartAction; adapters = $Adapters; connected = $Connected }
            if ($null -ne $Golden) {
                $guest['golden'] = $Golden
            }
            [pscustomobject]$guest
        }
    }

    It 'is <Status> when <Case>' -ForEach @(
        @{ Case = 'the guest runs as designed'; Guest = { New-Guest }; Status = 'Pass'; Match = 'runs with its heartbeat OK, starts with the host, and its adapter is connected to DbHubDemoNat'; Fix = '' }
        @{ Case = 'the capture left the source air-gapped'; Guest = { New-Guest -State 'Off' -StartAction 'Nothing' -Connected 0 -Golden ([pscustomobject]@{ released = $false; reset = $false; role = 'Source' }) }; Status = 'Fail'; Match = 'still air-gapped by a golden capture'; Fix = '^Start T2 from the Fabric control.*start-demo\.ps1 releases it too \(T2\.GOLDEN\.SOURCE\) once a golden snapshot names archost01.*next \./scripts/capture-t2-golden\.ps1' }
        @{ Case = 'a restored copy isn''t reset'; Guest = { New-Guest -State 'Off' -StartAction 'Nothing' -Connected 0 -Golden ([pscustomobject]@{ released = $false; reset = $false; role = 'Copy' }) }; Status = 'Fail'; Match = 'must stay air-gapped'; Fix = 'deploy\.ps1: its T2 track resets the copy.*Don''t connect it by hand' }
        @{ Case = 'a reset copy isn''t released'; Guest = { New-Guest -State 'Off' -StartAction 'Nothing' -Connected 0 -Golden ([pscustomobject]@{ released = $false; reset = $true; role = 'Copy' }) }; Status = 'Fail'; Match = 'was reset, but it isn''t released yet'; Fix = 'deploy\.ps1' }
        @{ Case = 'the host''s role can''t be read'; Guest = { New-Guest -State 'Off' -Connected 0 -Golden ([pscustomobject]@{ released = $false; reset = $false; role = 'Unknown' }) }; Status = 'Fail'; Match = 'can''t tell a source from a copy'; Fix = 'Don''t connect the guest by hand' }
        @{ Case = 'the guest is off without a capture'; Guest = { New-Guest -State 'Off' -Heartbeat '' }; Status = 'Fail'; Match = 'it''s Off'; Fix = 'Fabric control.*Start-VM -Name arcsql01' }
        @{ Case = 'its adapter is disconnected'; Guest = { New-Guest -Connected 0 }; Status = 'Fail'; Match = 'isn''t connected to DbHubDemoNat'; Fix = "--name archost01 --command-id RunPowerShellScript --scripts 'Connect-VMNetworkAdapter -VMName arcsql01 -SwitchName DbHubDemoNat" }
        @{ Case = 'a released capture''s guest is off'; Guest = { New-Guest -State 'Off' -Heartbeat '' -Golden ([pscustomobject]@{ released = $true; reset = $false; role = '' }) }; Status = 'Fail'; Match = 'it''s Off'; Fix = 'Start-VM' }
        @{ Case = 'it won''t start with the host'; Guest = { New-Guest -StartAction 'StartIfRunning' }; Status = 'Warning'; Match = 'doesn''t start with the host \(automatic start action StartIfRunning\)'; Fix = 'AutomaticStartAction Start' }
        @{ Case = 'its heartbeat isn''t OK yet'; Guest = { New-Guest -Heartbeat 'NoContact' }; Status = 'Warning'; Match = 'heartbeat is NoContact'; Fix = 'again in a few minutes' }
        @{ Case = 'the host couldn''t read it'; Guest = { [pscustomobject]@{ present = $false; error = 'Access is denied.' } }; Status = 'Warning'; Match = 'couldn''t read its guest'; Fix = 'again' }
        @{ Case = 'a capture is in progress on this host'; Guest = { $g = New-Guest -State 'Off' -StartAction 'Nothing' -Connected 0 -Golden ([pscustomobject]@{ released = $false; reset = $false; role = 'Source' }); $g | Add-Member -NotePropertyName capture -NotePropertyValue ([pscustomobject]@{ state = 'Active'; snapshotName = 'snap-dbhub-t2golden-202611040100'; sinceUtc = [datetime]::new(2026, 11, 4, 1, 0, 0, [System.DateTimeKind]::Utc); untilUtc = '2026-11-04T07:00:00Z' }) -PassThru }; Status = 'Warning'; Match = 'A golden capture is in progress on archost01: snapshot snap-dbhub-t2golden-202611040100, since 2026-11-04 01:00 UTC'; Fix = '^Let \./scripts/capture-t2-golden\.ps1 finish.*From 2026-11-04 07:00 UTC' }
        @{ Case = 'a recent marker can''t be matched to this host'; Guest = { $g = New-Guest -State 'Off' -StartAction 'Nothing' -Connected 0; $g | Add-Member -NotePropertyName capture -NotePropertyValue ([pscustomobject]@{ state = 'Unknown'; snapshotName = 'snap-dbhub-t2golden-202611040100'; sinceUtc = '2026-11-04T01:00:00Z'; untilUtc = '2026-11-04T07:00:00Z' }) -PassThru }; Status = 'Warning'; Match = 'Azure VM ID couldn''t be read to confirm'; Fix = 'capture-t2-golden\.ps1' }
        @{ Case = 'a copy''s record says released without a reset'; Guest = { New-Guest -Golden ([pscustomobject]@{ released = $true; reset = $false; role = 'Copy' }) }; Status = 'Fail'; Match = 'record says released, but its Arc identity was never reset'; Fix = 'deploy\.ps1: its T2 track resets the restored copy' }
        @{ Case = 'a released record''s host can''t tell its role'; Guest = { New-Guest -Golden ([pscustomobject]@{ released = $true; reset = $false; role = 'Unknown' }) }; Status = 'Warning'; Match = 'can''t be told from a copy''s'; Fix = 'deploy\.ps1' }
        @{ Case = 'the source''s record is released'; Guest = { New-Guest -Golden ([pscustomobject]@{ released = $true; reset = $false; role = 'Source' }) }; Status = 'Pass'; Match = 'runs with its heartbeat OK'; Fix = '' }
    ) {
        $result = Get-GuestState (& $Guest)
        $result.checkId | Should -Be 'T2.GUEST.STATE'
        $result.status | Should -Be $Status
        $result.message | Should -Match $Match
        if ($Fix) {
            $result.remediation | Should -Match $Fix
        }
        if ($Status -ne 'Pass') {
            $result.remediation | Should -Not -BeNullOrEmpty
        }
    }

    It 'never offers to connect a copy that may hold the captured identity' {
        $result = Get-GuestState (New-Guest -State 'Off' -StartAction 'Nothing' -Connected 0 -Golden ([pscustomobject]@{ released = $false; reset = $false; role = 'Copy' }))
        $result.remediation | Should -Not -Match 'Connect-VMNetworkAdapter|run-command'
    }

    It 'waits for a guest the build hasn''t created yet, fails one a Ready host lost, and says nothing without a Hyper-V read' {
        (Get-GuestState ([pscustomobject]@{ present = $false }) -HostState 'Running').status | Should -Be 'Not selected'
        $lost = Get-GuestState ([pscustomobject]@{ present = $false }) -HostState 'Ready'
        $lost.status | Should -Be 'Fail'
        $lost.remediation | Should -Match 'deploy\.ps1 -Resume'
        & (Get-Module -Name DbHubDemo) { param($c) Get-DemoT2GuestStateResult -Config $c -Health ([pscustomobject]@{ status = 'Pass'; state = 'Ready' }) } $config | Should -BeNullOrEmpty
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

Describe 'Get-DemoGoldenCaptureControlResult (GOLDEN.CAPTURE.CONTROL, review of 2026-11-04)' {
    BeforeEach {
        $config = New-TestConfig
        $config['control'] = @{ enabled = $true }
        $script:now = [datetime]::new(2026, 11, 4, 2, 0, 0, [System.DateTimeKind]::Utc)
        $script:jobs = @{ 'DbHub-Control' = @(); 'DbHub-Stop' = @() }
        $script:jobsFail = ''
        $script:autoStop = ''
        $script:autoStopFail = $false
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActivityControlArm -MockWith {
            if ($Url -match '/jobs$') {
                $runbook = ([string]$Query['$filter'] -replace "^properties/runbook/name eq '([^']+)'$", '$1')
                if ($script:jobsFail -eq $runbook) { return [pscustomobject]@{ Ok = $false; Missing = $false; Value = $null; Error = 'Forbidden' } }
                return [pscustomobject]@{ Ok = $true; Missing = $false; Value = [pscustomobject]@{ value = @($script:jobs[$runbook] | ForEach-Object { [pscustomobject]@{ properties = [pscustomobject]@{ jobId = $_[0]; status = $_[1]; runbook = [pscustomobject]@{ name = $runbook } } } }) }; Error = '' }
            }
            if ($Url -match '/schedules/dbhub-autostop\?') {
                if ($script:autoStopFail) { return [pscustomobject]@{ Ok = $false; Missing = $false; Value = $null; Error = 'Timeout' } }
                if (-not $script:autoStop) { return [pscustomobject]@{ Ok = $false; Missing = $true; Value = $null; Error = 'NotFound' } }
                return [pscustomobject]@{ Ok = $true; Missing = $false; Value = [pscustomobject]@{ properties = [pscustomobject]@{ startTime = $script:autoStop } }; Error = '' }
            }
            throw ('unexpected: {0}' -f $Url)
        }
        function Get-ControlCheck {
            & (Get-Module -Name DbHubDemo) { param($c, $n) Get-DemoGoldenCaptureControlResult -Config $c -NowUtc $n } $config $script:now
        }
    }

    It 'passes with no job queued or running and no pending auto-stop, also after an auto-stop''s time' {
        $result = Get-ControlCheck
        $result.checkId | Should -Be 'GOLDEN.CAPTURE.CONTROL'
        $result.status | Should -Be 'Pass'
        $script:autoStop = '2026-11-04T01:30:00Z'
        (Get-ControlCheck).status | Should -Be 'Pass'
        $script:jobs['DbHub-Control'] = @(, @('aaaaaaaa-0000-0000-0000-00000000000a', 'Completed'))
        (Get-ControlCheck).status | Should -Be 'Pass'
    }

    It 'fails while a DbHub-Control or DbHub-Stop job is queued or running' -ForEach @(
        @{ Runbook = 'DbHub-Control'; Status = 'Running' }
        @{ Runbook = 'DbHub-Control'; Status = 'New' }
        @{ Runbook = 'DbHub-Stop'; Status = 'Activating' }
    ) {
        $script:jobs[$Runbook] = @(, @('bbbbbbbb-0000-0000-0000-00000000000b', $Status))
        $result = Get-ControlCheck
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match ('{0} bbbbbbbb-0000-0000-0000-00000000000b {1}' -f $Runbook, $Status)
        $result.remediation | Should -Match 'Nothing was captured.*Stop now in NB_DatabaseHub_Control, or \./scripts/stop-demo\.ps1'
    }

    It 'fails while an auto-stop is pending, with its time' {
        $script:autoStop = '2026-11-04T03:10:00Z'
        $result = Get-ControlCheck
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'active until 2026-11-04 03:10 UTC'
        ([datetime]$result.evidence['autoStopUtc']).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm") | Should -Be '2026-11-04T03:10'
    }

    It 'fails when the jobs or the auto-stop can''t be read, because a run may be active' {
        $script:jobsFail = 'DbHub-Stop'
        $jobs = Get-ControlCheck
        $jobs.status | Should -Be 'Fail'
        $jobs.message | Should -Match 'DbHub-Stop jobs couldn''t be read \(Forbidden\)'
        $script:jobsFail = ''
        $script:autoStopFail = $true
        $schedule = Get-ControlCheck
        $schedule.status | Should -Be 'Fail'
        $schedule.message | Should -Match 'dbhub-autostop couldn''t be read \(Timeout\)'
    }

    It 'is Not selected, and reads nothing, when the control is off' {
        $config['control'] = @{ enabled = $false }
        (Get-ControlCheck).status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoActivityControlArm -Times 0 -Exactly
    }
}
