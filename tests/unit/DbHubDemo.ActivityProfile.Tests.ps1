BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes through Invoke-DemoAz need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    function New-TestConfig([switch] $WithT4, [switch] $Unset, [string] $ActivityProfile = '') {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t4Enabled'] = [bool]$WithT4
        if ($Unset) {
            $config.Remove('activityProfile')
        }
        elseif ($ActivityProfile) {
            $config['activityProfile'] = $ActivityProfile
        }
        return $config
    }

    function New-TestResult([string] $CheckId, [string] $Status = 'Pass', [string] $Target = 'T1') {
        New-DemoResult -CheckId $CheckId -Area 'workload' -Target $Target -Status $Status -Message ('{0}: {1}' -f $CheckId, $Status)
    }

    function New-ProfileRecord([string] $Target, [string] $Outcome, [string] $Detail = 'detail') {
        [pscustomobject]@{ Target = $Target; VmName = $(if ($Target -eq 'T2') { 'archost01' } else { 'sqlvm01' }); Outcome = $Outcome; Detail = $Detail; Data = $null; Seconds = 7 }
    }

    function ConvertTo-ProfileLine([string] $Target, [string] $Status, [string] $Message) {
        'DBHUBDEMO-WORKLOAD ' + ([ordered]@{ marker = 'DBHUBDEMO-WORKLOAD'; action = 'Runner'; status = $Status; message = $Message; evidence = [ordered]@{ target = $Target; exitCode = 0 } } | ConvertTo-Json -Depth 4 -Compress)
    }

    $script:module = Get-Module -Name 'DbHubDemo'
}

Describe 'The default activity profile (the owner''s decision of 2026-11-03)' {
    It 'is business-day for a configuration that doesn''t set activityProfile, which Get-DemoConfig leaves unset so a run can say so' {
        $example = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $example.Remove('activityProfile')
        $path = Join-Path -Path $TestDrive -ChildPath 'unset.config.json'
        Set-Content -LiteralPath $path -Value ($example | ConvertTo-Json -Depth 10)
        $config = Get-DemoConfig -Path $path
        $config.Contains('activityProfile') | Should -BeFalse
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityProfile -Config $Config }
        $resolved.Name | Should -Be 'business-day'
        $resolved.Source | Should -Be 'default'
        $resolved.Defaulted | Should -BeTrue
        $resolved.HasIncidents | Should -BeTrue
        $resolved.Interim | Should -Be 'baseline'
    }

    It 'keeps an explicit value, and -ActivityProfile wins over the configuration: <Configured> + <Requested> -> <Name>' -ForEach @(
        @{ Configured = 'baseline'; Requested = ''; Name = 'baseline'; Source = 'configuration'; Incidents = $false; Interim = 'baseline' }
        @{ Configured = 'business-day'; Requested = ''; Name = 'business-day'; Source = 'configuration'; Incidents = $true; Interim = 'baseline' }
        @{ Configured = 'business-day'; Requested = 'baseline'; Name = 'baseline'; Source = 'parameter'; Incidents = $false; Interim = 'baseline' }
        @{ Configured = 'baseline'; Requested = 'business-day'; Name = 'business-day'; Source = 'parameter'; Incidents = $true; Interim = 'baseline' }
        @{ Configured = 'incident:cpu-pressure'; Requested = ''; Name = 'incident:cpu-pressure'; Source = 'configuration'; Incidents = $true; Interim = 'baseline' }
        @{ Configured = 'off'; Requested = ''; Name = 'off'; Source = 'configuration'; Incidents = $false; Interim = 'off' }
    ) {
        $config = New-TestConfig -ActivityProfile $Configured
        $resolved = InModuleScope DbHubDemo -Parameters @{ Config = $config; Requested = $Requested } { Get-DemoActivityProfile -Config $Config -Requested $Requested }
        $resolved.Name | Should -Be $Name
        $resolved.Source | Should -Be $Source
        $resolved.Defaulted | Should -BeFalse
        $resolved.HasIncidents | Should -Be $Incidents
        $resolved.Interim | Should -Be $Interim
    }
}

Describe 'business-day''s schedule and what the scripts say about it' {
    It 'reads the hourly incidents from the runner''s profiles, for every target and for one' {
        InModuleScope DbHubDemo { Format-DemoBusinessDaySchedule } | Should -Be 'T1 at :10 and :40, T2 at :05, :20, :35, and :50, T3 at :15 and :45, and T4 at :08, :22, and :42 past each UTC hour'
        InModuleScope DbHubDemo { Format-DemoBusinessDaySchedule -Target 'T3' } | Should -Be 'at :15 (resource-governance, 5 minutes) and :45 (log-rate-pressure, 5 minutes) past each UTC hour'
        InModuleScope DbHubDemo { Get-DemoT3IncidentShare } | Should -Be (10.0 / 60.0)
    }

    It 'gives DONE, start-demo.ps1, and the status page an Activity line that says what runs and how to choose the other profile' {
        $line = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Unset) } { Get-DemoActivitySummaryLine -ActivityProfile (Get-DemoActivityProfile -Config $Config) }
        $line | Should -BeLike 'Activity: business-day (the default): bounded incidents at fixed minutes every hour (T1 at :10 and :40, *) show on Database Hub''s Performance page a few minutes after each starts; set activityProfile to baseline for a quiet demo. For one right now: ./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25.'
        $explicit = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoActivitySummaryLine -ActivityProfile (Get-DemoActivityProfile -Config $Config) }
        $explicit | Should -BeLike 'Activity: business-day: bounded incidents*'
        $quiet = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -ActivityProfile 'baseline') } { Get-DemoActivitySummaryLine -ActivityProfile (Get-DemoActivityProfile -Config $Config) }
        $quiet | Should -Be 'Activity: baseline: the steady mix with no incidents, so the Performance page''s problem panels stay empty. business-day, the default, adds bounded incidents every hour (set activityProfile to business-day); for one right now: ./scripts/demo-control.ps1 -Target T2 -Scenario incident:cpu-pressure -Duration 25.'
    }

    It 'says once, as <Prefix>.ACTIVITYPROFILE and on the console, that a configuration without activityProfile uses business-day' -ForEach @(
        @{ Prefix = 'PREFLIGHT' }
        @{ Prefix = 'DEPLOY' }
        @{ Prefix = 'START' }
    ) {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $notice = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Unset); Prefix = $Prefix } { New-DemoActivityProfileNotice -ActivityProfile (Get-DemoActivityProfile -Config $Config) -CheckPrefix $Prefix }
        $notice.checkId | Should -Be ('{0}.ACTIVITYPROFILE' -f $Prefix)
        $notice.status | Should -Be 'Pass'
        $notice.message | Should -BeLike 'activityProfile isn''t set, so this run uses the new default, business-day (incidents every hour); set it to baseline for the quieter demo. Its incidents run T1 at :10 and :40, *; the cost checks count them (ADR 0016).'
        $notice.remediation | Should -Match '"activityProfile": "baseline"'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq 'activityProfile isn''t set, so this run uses the new default, business-day (incidents every hour); set it to baseline for the quieter demo.' }

        # A configuration that names a profile, any profile, gets no notice.
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -ActivityProfile 'business-day'); Prefix = $Prefix } { New-DemoActivityProfileNotice -ActivityProfile (Get-DemoActivityProfile -Config $Config) -CheckPrefix $Prefix } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly
    }
}

Describe 'The activity profiles'' Run Command (DbHubDemo-Profile)' {
    It 'runs the workload-control template once per target, with the profile until the next auto-shutdown, and is ASCII PowerShell' {
        $script = InModuleScope DbHubDemo { Get-DemoProfileRunCommandScript -Target 'T1', 'T3' -ProfileName 'business-day' -RequestedBy 'deploy' -NotAfterUtc ([datetime]::UtcNow.AddMinutes(30)) }
        $script | Should -Not -Match '[^\x00-\x7F]'
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $requests = @([regex]::Matches($script, "-RequestBase64 '([A-Za-z0-9+/=]+)'") | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_.Groups[1].Value)) | ConvertFrom-Json -AsHashtable })
        @($requests | ForEach-Object { $_['target'] }) | Should -Be @('T1', 'T3')
        foreach ($request in $requests) {
            @($request['arguments']) | Should -Be @('profile', 'set', '--name', 'business-day', '--requested-by', 'deploy', '--not-after', '{{NEXT_SHUTDOWN}}')
        }
        # Each target's line is cut short, with its target, so up to four fit in the 4 KB the instance view keeps.
        @([regex]::Matches($script, "target = 'T[13]'; exitCode = \`$dbhubExit")).Count | Should -Be 2

        $off = InModuleScope DbHubDemo { Get-DemoProfileRunCommandScript -Target 'T2' -ProfileName 'off' -RequestedBy 'stop-demo' -NotAfterUtc ([datetime]::UtcNow.AddMinutes(10)) }
        $request = [regex]::Match($off, "-RequestBase64 '([A-Za-z0-9+/=]+)'").Groups[1].Value
        @(([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($request)) | ConvertFrom-Json -AsHashtable)['arguments']) | Should -Be @('profile', 'set', '--name', 'off', '--requested-by', 'stop-demo')
    }

    It 'changes nothing once it has expired, for example after a deallocation held it back, and says so per target' {
        $script = InModuleScope DbHubDemo { Get-DemoProfileRunCommandScript -Target 'T1', 'T3' -ProfileName 'business-day' -RequestedBy 'deploy' -NotAfterUtc ([datetime]::UtcNow.AddMinutes(-1)) }
        $writer = [System.IO.StringWriter]::new()
        $console = [Console]::Out
        [Console]::SetOut($writer)
        try {
            & ([scriptblock]::Create($script))
        }
        finally {
            [Console]::SetOut($console)
        }
        $lines = InModuleScope DbHubDemo -Parameters @{ Output = $writer.ToString() } { ConvertFrom-DemoProfileRunCommandOutput -Output $Output -Target 'T1', 'T3' }
        foreach ($target in 'T1', 'T3') {
            $lines[$target]['status'] | Should -Be 'Not selected'
            $lines[$target]['message'] | Should -BeLike ('{0}: not run: the request to set business-day expired at *' -f $target)
            $lines[$target]['evidence']['expired'] | Should -BeTrue
        }
    }

    It 'matches the result lines to their targets by the target they name, else in order from the end' {
        $named = @((ConvertTo-ProfileLine 'T3' 'Pass' 'T3 set'), 'noise', (ConvertTo-ProfileLine 'T1' 'Fail' 'T1 failed')) -join "`n"
        $lines = InModuleScope DbHubDemo -Parameters @{ Output = $named } { ConvertFrom-DemoProfileRunCommandOutput -Output $Output -Target 'T1', 'T3', 'T4' }
        $lines['T1']['status'] | Should -Be 'Fail'
        $lines['T3']['message'] | Should -Be 'T3 set'
        $lines.ContainsKey('T4') | Should -BeFalse
        # Lines without a target: the output's start may be cut, so they line up from the end.
        $unnamed = 'DBHUBDEMO-WORKLOAD {"marker":"DBHUBDEMO-WORKLOAD","action":"Runner","status":"Pass","message":"last","evidence":{}}'
        $lines = InModuleScope DbHubDemo -Parameters @{ Output = ('...cut' + "`n" + $unnamed) } { ConvertFrom-DemoProfileRunCommandOutput -Output $Output -Target 'T1', 'T3' }
        $lines.ContainsKey('T1') | Should -BeFalse
        $lines['T3']['message'] | Should -Be 'last'
    }
}

Describe 'Send-DemoProfileRunCommand: one managed Run Command per VM, both VMs at once, a bounded wait' {
    BeforeEach {
        $script:puts = [System.Collections.Generic.List[hashtable]]::new()
        $script:putAnswers = [System.Collections.Generic.Queue[object]]::new()
        $script:reads = 0
        $script:stale = $false
        $script:outputs = @{}
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { [System.Threading.Thread]::Sleep(20) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $url = [string]$ArgumentList[[array]::IndexOf($ArgumentList, '--url') + 1]
            $bodyPath = ([string]$ArgumentList[[array]::IndexOf($ArgumentList, '--body') + 1]).TrimStart('@')
            $script:puts.Add(@{ Url = $url; Body = (Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json -AsHashtable); Timeout = $PesterBoundParameters['TimeoutSeconds'] })
            if ($script:putAnswers.Count -gt 0) {
                return $script:putAnswers.Dequeue()
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunCommandState -MockWith {
            $script:reads++
            $vm = if ($Url -match '/virtualMachines/(\w+)/runCommands/') { $Matches[1] } else { '' }
            $start = if ($script:stale) { [DateTime]::UtcNow.AddHours(-2) } else { [DateTime]::UtcNow }
            [pscustomobject]@{ Found = $true; NotFound = $false; ProvisioningState = 'Succeeded'; ExecutionState = 'Succeeded'; ExitCode = 0; StartTime = $start; Output = [string]$script:outputs[$vm]; Error = '' }
        }
    }

    It 'sets the profile of each VM''s targets in one asynchronous Run Command, and returns a record per target in order' {
        $script:outputs['sqlvm01'] = @((ConvertTo-ProfileLine 'T1' 'Pass' 'T1 set'), (ConvertTo-ProfileLine 'T3' 'Pass' 'T3 set')) -join "`n"
        $script:outputs['archost01'] = ConvertTo-ProfileLine 'T2' 'Pass' 'T2 set'
        $records = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoProfileRunCommand -Config $Config -Target 'T1', 'T2', 'T3' -ProfileName 'business-day' -RequestedBy 'deploy' -WaitSeconds 60 -PollSeconds 1 })
        @($records | ForEach-Object { $_.Target }) | Should -Be @('T1', 'T2', 'T3')
        @($records | ForEach-Object { $_.Outcome }) | Should -Be @('Set', 'Set', 'Set')
        @($records | ForEach-Object { $_.VmName }) | Should -Be @('sqlvm01', 'archost01', 'sqlvm01')
        $script:puts.Count | Should -Be 2
        $script:puts[0].Url | Should -Match '^https://management\.azure\.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft\.Compute/virtualMachines/sqlvm01/runCommands/DbHubDemo-Profile\?api-version=[\d-]+$'
        $script:puts[1].Url | Should -Match '/virtualMachines/archost01/runCommands/DbHubDemo-Profile\?'
        $script:puts[0].Body['properties']['asyncExecution'] | Should -BeTrue
        $script:puts[0].Body['properties']['treatFailureAsDeploymentFailure'] | Should -BeFalse
        $script:puts[0].Timeout | Should -Be 60
        $sent = [string]$script:puts[0].Body['properties']['source']['script']
        @([regex]::Matches($sent, '-RequestBase64') ).Count | Should -Be 2 -Because 'T1 and T3 both run on sqlvm01'
    }

    It 'ignores an earlier request''s state under the same name, and stops waiting at -WaitSeconds: TimedOut' {
        $script:stale = $true
        $script:outputs['sqlvm01'] = ConvertTo-ProfileLine 'T1' 'Pass' 'an old line'
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $records = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoProfileRunCommand -Config $Config -Target 'T1' -ProfileName 'off' -RequestedBy 'stop-demo' -WaitSeconds 1 -PollSeconds 1 })
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 30
        $records[0].Outcome | Should -Be 'TimedOut'
        $records[0].Detail | Should -Be 'sqlvm01 didn''t finish it within 1 seconds'
        $script:reads | Should -BeGreaterThan 0
    }

    It 'tells a target without its runner (NotSetUp) from a failure, and a VM that isn''t running (NotSent)' {
        $script:outputs['sqlvm01'] = @((ConvertTo-ProfileLine 'T1' 'Fail' 'The runner said no.'), (ConvertTo-ProfileLine 'T3' 'Fail' 'T1 has no T3 server in its workload settings.')) -join "`n"
        $script:putAnswers.Enqueue([pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' })
        $script:putAnswers.Enqueue([pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "ERROR: (OperationNotAllowed) Operation 'Run Command' is not allowed on VM 'archost01' since the VM is deallocated." })
        $records = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoProfileRunCommand -Config $Config -Target 'T1', 'T3', 'T2' -ProfileName 'business-day' -RequestedBy 'deploy' -WaitSeconds 60 -PollSeconds 1 })
        ($records | Where-Object Target -EQ 'T1').Outcome | Should -Be 'Failed'
        ($records | Where-Object Target -EQ 'T1').Detail | Should -Be 'The runner said no.'
        ($records | Where-Object Target -EQ 'T3').Outcome | Should -Be 'NotSetUp'
        ($records | Where-Object Target -EQ 'T2').Outcome | Should -Be 'NotSent'
        ($records | Where-Object Target -EQ 'T2').Detail | Should -Match 'archost01 isn''t running'
    }

    It 'retries a busy VM (409) within the wait, and only sends with -WaitSeconds 0' {
        $script:putAnswers.Enqueue([pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (Conflict) Another operation is in progress.' })
        $script:outputs['sqlvm01'] = ConvertTo-ProfileLine 'T1' 'Pass' 'set'
        $records = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoProfileRunCommand -Config $Config -Target 'T1' -ProfileName 'business-day' -RequestedBy 'deploy' -WaitSeconds 60 -PollSeconds 1 })
        $script:puts.Count | Should -Be 2
        $records[0].Outcome | Should -Be 'Set'

        $script:puts.Clear()
        $script:reads = 0
        $sent = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoProfileRunCommand -Config $Config -Target 'T1', 'T2' -ProfileName 'business-day' -RequestedBy 'deploy' -WaitSeconds 0 })
        @($sent | ForEach-Object { $_.Outcome }) | Should -Be @('Sent', 'Sent')
        $script:puts.Count | Should -Be 2
        $script:reads | Should -Be 0
    }
}

Describe 'The switch from the interim baseline (Invoke-DemoActivitySwitch, Send-DemoPendingActivitySwitch)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:outcomes = @{}
        $script:sendThrows = $false
        Mock -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -MockWith {
            if ($script:sendThrows) {
                throw 'Azure CLI not reachable'
            }
            foreach ($item in $Target) {
                $outcome = if ($script:outcomes.ContainsKey($item)) { $script:outcomes[$item] } elseif ([int]$PesterBoundParameters['WaitSeconds'] -eq 0) { 'Sent' } else { 'Set' }
                New-ProfileRecord $item $outcome 'the runner said no'
            }
        }
        InModuleScope DbHubDemo { Clear-DemoActivitySwitch }
    }

    AfterEach {
        InModuleScope DbHubDemo { Clear-DemoActivitySwitch }
    }

    It 'reports <Outcome> as <Status>, never a Fail' -ForEach @(
        @{ Outcome = 'Set'; Status = 'Pass'; Text = 'T3: business-day from now on, until two minutes before the next auto-shutdown: the baseline plus bounded incidents at :15 (resource-governance, 5 minutes) and :45 (log-rate-pressure, 5 minutes) past each UTC hour. They started only once this run''s own Run Commands on sqlvm01 were done, so none slowed them; Database Hub shows each a few minutes after it starts. While it runs, T3''s serverless database stays awake and bills compute (ADR 0016).' }
        @{ Outcome = 'NotSetUp'; Status = 'Not selected'; Text = 'T3: not switched to business-day: the runner said no' }
        @{ Outcome = 'TimedOut'; Status = 'Warning'; Text = 'T3: the switch to business-day was sent to sqlvm01, but it didn''t finish within 180 seconds; the VM runs it when its Run Commands allow, within 30 minutes. ./scripts/status.ps1 shows the profile.' }
        @{ Outcome = 'Failed'; Status = 'Warning'; Text = 'T3: the switch to business-day failed: the runner said no.' }
        @{ Outcome = 'NotSent'; Status = 'Warning'; Text = 'T3: the switch to business-day failed: the runner said no.' }
    ) {
        $script:outcomes['T3'] = $Outcome
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -Target 'T3' -CheckPrefix 'START' -RequestedBy 'start-demo' })
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'START.INCIDENTS_T3'
        $results[0].status | Should -Be $Status
        $results[0].message | Should -Be $Text
        if ($Status -eq 'Warning') {
            $results[0].remediation | Should -Match ([regex]::Escape('./scripts/demo-control.ps1 -Target T3 -Scenario business-day -Duration 240'))
        }
    }

    It 'sends nothing for a profile without incidents, or without targets' {
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -ActivityProfile 'baseline') } { Invoke-DemoActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -Target 'T1' -CheckPrefix 'DEPLOY' -RequestedBy 'deploy' }) | Should -BeNullOrEmpty
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -Target @() -CheckPrefix 'DEPLOY' -RequestedBy 'deploy' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 0 -Exactly
    }

    It 'only sends with -NoWait, for a run that stopped (Ctrl+C) or failed, says so on the console, and never throws' {
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -Target 'T1', 'T3', 'T2' -CheckPrefix 'DEPLOY' -RequestedBy 'deploy' -NoWait })
        $results | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { $WaitSeconds -eq 0 -and $ProfileName -eq 'business-day' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -eq 'The run stopped before its end, so business-day was sent to sqlvm01 and archost01 without waiting: T1, T3, and T2 switch from the interim baseline when the VM runs it.' }

        $script:sendThrows = $true
        { InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -Target 'T1' -CheckPrefix 'DEPLOY' -RequestedBy 'deploy' -NoWait } } | Should -Not -Throw
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'The run stopped before its end, and business-day couldn''t be sent: Azure CLI not reachable.*demo-control.ps1 -Target all -Scenario business-day -Duration 240.' }
    }

    It 'switches the targets of the VMs the run noted, except what the run skipped on purpose, and only once' {
        InModuleScope DbHubDemo { Register-DemoActivitySwitch -VmName 'sqlvm01'; Register-DemoActivitySwitch -VmName 'archost01' }
        $skipped = @((New-TestResult 'START.PROFILE_T1'), (New-TestResult 'START.PROFILE_T3' 'Not selected' 'T3'), (New-TestResult 'START.PROFILE_T2' 'Warning' 'T2'))
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -WithT4); Result = $skipped } { Send-DemoPendingActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -Result $Result -CheckPrefix 'START' -RequestedBy 'start-demo' })
        @($results | ForEach-Object { $_.checkId }) | Should -Be @('START.INCIDENTS_T1', 'START.INCIDENTS_T4', 'START.INCIDENTS_T2')
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { (@($Target) -join ',') -eq 'T1,T4,T2' -and $WaitSeconds -eq 180 }
        InModuleScope DbHubDemo { @(Get-DemoActivitySwitchVm) } | Should -BeNullOrEmpty
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoPendingActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -CheckPrefix 'START' -RequestedBy 'start-demo' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly
    }

    It 'sets the interim baseline without waiting on VMs that already run, notes the ones it reached, and does nothing for a profile without incidents' {
        $script:outcomes['T2'] = 'NotSent'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivityQuiet -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -VmName 'sqlvm01', 'archost01' -RequestedBy 'deploy' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { $ProfileName -eq 'baseline' -and $WaitSeconds -eq 0 -and $ExpiresMinutes -eq 10 -and (@($Target) -join ',') -eq 'T1,T3,T2' }
        InModuleScope DbHubDemo { @(Get-DemoActivitySwitchVm) } | Should -Be @('sqlvm01') -Because 'archost01 wasn''t reached, so there''s nothing to switch back there'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'sqlvm01 was already running, so T1 and T3 get the interim baseline first, without waiting: no incident slows this run''s own Run Commands there, and business-day comes back at the end.' }

        # -Target keeps only the targets the run sets (start-demo.ps1 -SkipT3); a profile without incidents sends nothing.
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivityQuiet -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -VmName 'sqlvm01' -Target 'T1', 'T2' -RequestedBy 'start-demo' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { (@($Target) -join ',') -eq 'T1' }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -ActivityProfile 'baseline') } { Invoke-DemoActivityQuiet -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -VmName 'sqlvm01', 'archost01' -RequestedBy 'deploy' }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoActivityQuiet -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -VmName @() -RequestedBy 'deploy' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 2 -Exactly
    }

    It 'leaves a VM outside -VmName for later, and reads what a track process noted in its handoff directory after a stop' {
        InModuleScope DbHubDemo { Register-DemoActivitySwitch -VmName 'sqlvm01'; Register-DemoActivitySwitch -VmName 'archost01' }
        $null = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Send-DemoPendingActivitySwitch -Config $Config -ActivityProfile (Get-DemoActivityProfile -Config $Config) -CheckPrefix 'START' -RequestedBy 'start-demo' -VmName 'sqlvm01' })
        InModuleScope DbHubDemo { @(Get-DemoActivitySwitchVm) } | Should -Be @('archost01')

        InModuleScope DbHubDemo { Clear-DemoActivitySwitch }
        $handoff = Join-Path -Path $TestDrive -ChildPath ('handoff-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $handoff
        InModuleScope DbHubDemo -Parameters @{ Path = $handoff } { Register-DemoActivitySwitch -VmName 'archost01' -HandoffPath $Path; Clear-DemoActivitySwitch }
        Test-Path -LiteralPath (Join-Path -Path $handoff -ChildPath 'activity-archost01.xml') | Should -BeTrue
        InModuleScope DbHubDemo -Parameters @{ Path = $handoff } { @(Get-DemoActivitySwitchVm -HandoffPath $Path) } | Should -Be @('archost01')
        InModuleScope DbHubDemo { @(Get-DemoActivitySwitchVm) } | Should -BeNullOrEmpty
    }
}

Describe 'Complete-DemoDeploymentRun sends a switch the run didn''t get to (Ctrl+C, an error)' {
    BeforeEach {
        $script:out = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N'))
        Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Enter-DemoKeepAwake -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoProgressPageWriter -MockWith { $null }
        Mock -ModuleName DbHubDemo -CommandName Open-DemoProgressPage -MockWith { 'The status page is open in your browser.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRunEnvironment -MockWith { [pscustomobject]@{ GitHubActions = $false; Ci = $false; Interactive = $true; Codespaces = $false; Windows = $true } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { throw 'a stopped run makes no Azure call' }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -MockWith { foreach ($item in $Target) { New-ProfileRecord $item 'Sent' } }
        InModuleScope DbHubDemo { Clear-DemoActivitySwitch }
    }

    It 'sends business-day to what the stopped run left on the interim baseline, without waiting, and nothing after a run that switched' {
        $config = New-TestConfig
        $run = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory $script:out -Confirm:$false
        InModuleScope DbHubDemo { Register-DemoActivitySwitch -VmName 'sqlvm01'; Register-DemoActivitySwitch -VmName 'archost01' }
        $outcome = Complete-DemoDeploymentRun -Run $run -Config $config -Result @() -Stopped
        $outcome.Kind | Should -Be 'NotDone'
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -ParameterFilter { $WaitSeconds -eq 0 -and $ProfileName -eq 'business-day' -and (@($Target) -join ',') -eq 'T1,T3,T2' -and $RequestedBy -eq 'deploy' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'The run stopped before its end, so business-day was sent to sqlvm01 and archost01 without waiting*' }
        $outcome.Activity | Should -BeLike 'Activity: business-day: bounded incidents at fixed minutes every hour*'
        $model = Get-Content -LiteralPath $run.ProgressPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $model['run']['activity'] | Should -Be $outcome.Activity

        $second = Start-DemoDeploymentRun -Config $config -WaitForT2 -OutputDirectory ($script:out + '-second') -Confirm:$false
        Complete-DemoDeploymentRun -Run $second -Config $config -Result @() -Stopped | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoProfileRunCommand -Times 1 -Exactly -Because 'nothing is pending after the first'
    }

    It 'puts the Activity line in DONE''s "Where to look"' {
        $outcome = [pscustomobject]@{ Kind = 'Done'; ExitCode = 0; Minutes = 64; Reason = ''; Next = ''; NextCommand = ''; Optional = @(); Notes = @(); Resume = ''; Missing = @(); Confirm = @(); Activity = 'Activity: business-day: bounded incidents at fixed minutes every hour.' }
        $lines = @(InModuleScope DbHubDemo -Parameters @{ Outcome = $outcome } { Get-DemoDeploymentOutcomeLine -Outcome $Outcome })
        $where = [array]::IndexOf($lines, @($lines | Where-Object { $_ -like 'Where to look:*' })[0])
        $where | Should -BeGreaterOrEqual 0
        $lines[$where + 1] | Should -Be 'Activity: business-day: bounded incidents at fixed minutes every hour.'
    }
}

Describe 'stop-demo.ps1''s bounded steps (2026-11-03)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
    }

    It 'reports a profile that isn''t off: <Outcome>, deallocated <Deallocated>' -ForEach @(
        @{ Outcome = 'Set'; Deallocated = $true; Status = 'Pass'; Pattern = '^T1: the activity profile is off\.' }
        @{ Outcome = 'NotSetUp'; Deallocated = $true; Status = 'Not selected'; Pattern = '^T1: T1 doesn''t drive T1 yet|^T1: ' }
        @{ Outcome = 'TimedOut'; Deallocated = $true; Status = 'Warning'; Pattern = '^T1: turning the activity profile off didn''t finish within 180 seconds \(sqlvm01 is busy, for example with an incident in progress\), so sqlvm01 was deallocated anyway \(STOP\.VM_SQLVM01\), which stops the incident with it\.' }
        @{ Outcome = 'TimedOut'; Deallocated = $false; Status = 'Warning'; Pattern = '^T1: turning the activity profile off didn''t finish within 180 seconds \(sqlvm01 is busy, for example with an incident in progress\), and sqlvm01 wasn''t deallocated either \(STOP\.VM_SQLVM01\)' }
        @{ Outcome = 'Failed'; Deallocated = $true; Status = 'Warning'; Pattern = '^T1: the activity profile couldn''t be set to off: the runner said no, so sqlvm01 was deallocated anyway' }
    ) {
        $record = New-ProfileRecord 'T1' $Outcome 'the runner said no'
        $result = InModuleScope DbHubDemo -Parameters @{ Record = $record; Failed = (-not $Deallocated) } { ConvertTo-DemoStopProfileResult -Record $Record -WaitSeconds 180 -DeallocationFailed:$Failed }
        $result.checkId | Should -Be 'STOP.PROFILE_T1'
        $result.status | Should -Be $Status
        $result.message | Should -Match $Pattern
    }

    It 'bounds the guest''s clean shutdown, and a time-out is a Warning: the host''s deallocation shuts the guest down' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActionRunCommand -MockWith { [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'The Azure CLI did not finish within 180 seconds and was stopped.' } }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Stop-DemoGuestVm -Config $Config -TimeoutSeconds 180 -Confirm:$false }
        $result.checkId | Should -Be 'STOP.GUEST'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Be 'The guest''s clean shutdown didn''t finish within 180 seconds (archost01 is busy, for example with an incident in the guest), so the stop went on: archost01 is deallocated anyway, and its automatic stop action (ShutDown) shuts the guest down.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoActionRunCommand -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 180 -and $VmName -eq 'archost01' }
    }

    It 'stops retrying a busy VM at the bound, and keeps today''s retries without one' {
        $script:azCalls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { $script:azCalls.Add($PesterBoundParameters['TimeoutSeconds']); [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (Conflict) Another operation is in progress.' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoConflictDelay -MockWith { 40 }
        $run = InModuleScope DbHubDemo { Invoke-DemoActionRunCommand -SubscriptionId '11111111-2222-3333-4444-555555555555' -ResourceGroupName 'rg-dbhub-demo' -VmName 'archost01' -Script 'Write-Output 1' -TimeoutSeconds 30 }
        $run.ExitCode | Should -Be 1
        $script:azCalls.Count | Should -Be 1 -Because 'the next try would start after the bound'
        [int]$script:azCalls[0] | Should -BeGreaterThan 0
        [int]$script:azCalls[0] | Should -BeLessOrEqual 30

        $script:azCalls.Clear()
        $null = InModuleScope DbHubDemo { Invoke-DemoActionRunCommand -SubscriptionId '11111111-2222-3333-4444-555555555555' -ResourceGroupName 'rg-dbhub-demo' -VmName 'archost01' -Script 'Write-Output 1' }
        $script:azCalls.Count | Should -Be 10
        @($script:azCalls | Where-Object { $null -ne $_ }) | Should -BeNullOrEmpty -Because 'no bound means no -TimeoutSeconds, as before'
    }
}

Describe 'Checks during business-day''s incidents (validate.ps1, 2026-11-03)' {
    It 'finds the incident due on a target at <At> UTC: <Expected>' -ForEach @(
        @{ At = '2026-11-03T14:07:00Z'; Target = @('T2'); Slack = 3; Expected = 'cpu-pressure 14:05-14:13' }
        @{ At = '2026-11-03T14:15:59Z'; Target = @('T2'); Slack = 3; Expected = 'cpu-pressure 14:05-14:13' }
        @{ At = '2026-11-03T14:16:00Z'; Target = @('T2'); Slack = 3; Expected = '' }
        @{ At = '2026-11-03T14:04:59Z'; Target = @('T2'); Slack = 3; Expected = '' }
        @{ At = '2026-11-03T14:16:30Z'; Target = @('T3', 'T1'); Slack = 3; Expected = 'resource-governance 14:15-14:20' }
        @{ At = '2026-11-03T14:08:30Z'; Target = @('T4'); Slack = 3; Expected = 'connection-surge 14:08-14:12' }
        @{ At = '2026-11-04T00:03:00Z'; Target = @('T2'); Slack = 10; Expected = 'inefficient-query 23:50-23:56' }
    ) {
        $now = [datetime]::Parse($At, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $incident = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Unset); Target = $Target; Now = $now; Slack = $Slack } { Get-DemoScheduledIncident -Config $Config -Target $Target -NowUtc $Now -SlackMinutes $Slack }
        if (-not $Expected) {
            $incident | Should -BeNullOrEmpty
            return
        }
        ('{0} {1:HH:mm}-{2:HH:mm}' -f $incident.Scenario, $incident.StartUtc, $incident.EndUtc) | Should -Be $Expected
        $incident.ClearUtc | Should -Be $incident.EndUtc.AddMinutes($Slack)
        $incident.StartUtc.Kind | Should -Be ([System.DateTimeKind]::Utc)
    }

    It 'finds none for a profile that runs no incident on a schedule' {
        $now = [datetime]::new(2026, 11, 3, 14, 7, 0, [System.DateTimeKind]::Utc)
        foreach ($name in 'baseline', 'off', 'incident:cpu-pressure') {
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -ActivityProfile $name); Now = $now } { Get-DemoScheduledIncident -Config $Config -Target 'T2' -NowUtc $Now } | Should -BeNullOrEmpty -Because $name
        }
    }

    It 'turns a Fail that a read got during an incident into a Warning that names it and when to check again' {
        $now = [datetime]::new(2026, 11, 3, 14, 7, 0, [System.DateTimeKind]::Utc)
        $fail = New-DemoResult -CheckId 'WORKLOAD.T2.COMMAND' -Area 'workload' -Target 'T2' -Status 'Fail' -Message 'The Run Command on archost01 failed: the runner timed out' -Evidence @{ operatorSeconds = 181 } -Remediation 'Run the command again.' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command'
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Result = $fail; Now = $now } { ConvertTo-DemoIncidentAwareResult -Result $Result -Config $Config -IncidentTarget 'T2' -ValidationArea 'Workload' -NowUtc $Now }
        $result.checkId | Should -Be 'WORKLOAD.T2.COMMAND'
        $result.area | Should -Be 'workload'
        $result.target | Should -Be 'T2'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Be 'The Run Command on archost01 failed: the runner timed out. It ran during business-day''s cpu-pressure incident on T2 (14:05 to 14:13 UTC), whose load can slow or refuse this read, so it''s a Warning, not a Fail.'
        $result.remediation | Should -Be 'Run ./scripts/validate.ps1 -Area Workload -Target T2 again after 14:16 UTC, once the incident has ended; a Fail then is a fault. Run the command again.'
        $result.evidence['operatorSeconds'] | Should -Be 181
        $result.evidence['failedDuringIncident'] | Should -BeTrue
        $result.evidence['incident']['scenario'] | Should -Be 'cpu-pressure'
        $result.docUrl | Should -Be $fail.docUrl
    }

    It 'returns any other result as it is: a Fail outside an incident, and a Pass or Warning during one' {
        $quiet = [datetime]::new(2026, 11, 3, 14, 17, 0, [System.DateTimeKind]::Utc)
        $busy = [datetime]::new(2026, 11, 3, 14, 7, 0, [System.DateTimeKind]::Utc)
        $fail = New-DemoResult -CheckId 'WORKLOAD.T2.HOST' -Area 'workload' -Target 'T2' -Status 'Fail' -Message 'T2: the lane keeps failing.'
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Result = $fail; Now = $quiet } { ConvertTo-DemoIncidentAwareResult -Result $Result -Config $Config -IncidentTarget 'T2' -ValidationArea 'Workload' -NowUtc $Now } | Should -Be $fail
        foreach ($status in 'Pass', 'Warning') {
            $other = New-DemoResult -CheckId 'WORKLOAD.T2.HOST' -Area 'workload' -Target 'T2' -Status $status -Message 'T2: serving.'
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Result = $other; Now = $busy } { ConvertTo-DemoIncidentAwareResult -Result $Result -Config $Config -IncidentTarget 'T2' -ValidationArea 'Workload' -NowUtc $Now } | Should -Be $other
        }
        $explicit = New-TestConfig -ActivityProfile 'baseline'
        InModuleScope DbHubDemo -Parameters @{ Config = $explicit; Result = $fail; Now = $busy } { ConvertTo-DemoIncidentAwareResult -Result $Result -Config $Config -IncidentTarget 'T2' -ValidationArea 'Workload' -NowUtc $Now } | Should -Be $fail -Because 'baseline runs no incident'
    }
}
