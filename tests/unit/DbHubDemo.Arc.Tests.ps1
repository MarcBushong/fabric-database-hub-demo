BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    function New-TestConfig {
        param([hashtable] $Override = @{})
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        foreach ($key in $Override.Keys) {
            $config[$key] = $Override[$key]
        }
        return $config
    }

    # A token-shaped value built at run time, so no scanner sees a token in the repository.
    $script:fakeToken = ('ey' + 'J') + ('a' * 24) + '.' + ('ey' + 'J') + ('b' * 24) + '.' + ('c' * 32)
    $script:machineId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01'

    function New-TestMachine {
        param([string] $Status = 'Connected', [string] $LastStatusChange = '', [bool] $SqlDetected = $true, [string] $VmId = '')
        [pscustomobject]@{
            id         = $script:machineId
            name       = 'arcsql01'
            location   = 'westus3'
            properties = [pscustomobject]@{
                status           = $Status
                lastStatusChange = $LastStatusChange
                agentVersion     = '1.60.0'
                mssqlDiscovered  = if ($SqlDetected) { 'true' } else { 'false' }
                vmId             = $VmId
            }
        }
    }

    function New-TestInstance {
        param([string] $Edition = 'Standard', [string] $LicenseType = 'PAYG', [bool] $Monitoring = $true, [string] $Container = $script:machineId, [string] $Name = 'arcsql01', [int] $Cores = 2)
        [pscustomobject]@{
            name       = $Name
            properties = [pscustomobject]@{
                instanceName        = 'MSSQLSERVER'
                edition             = $Edition
                licenseType         = $LicenseType
                version             = 'SQL Server 2022'
                containerResourceId = $Container
                vCore               = $Cores
                cores               = $Cores
                monitoring          = [pscustomobject]@{ enabled = $Monitoring }
            }
        }
    }

    function New-TestExtension {
        param([string] $Version = '1.1.2504.99', [string] $State = 'Succeeded', [string] $LicenseType = 'PAYG')
        [pscustomobject]@{
            name       = 'WindowsAgent.SqlServer'
            location   = 'westus3'
            properties = [pscustomobject]@{
                publisher          = 'Microsoft.AzureData'
                type               = 'WindowsAgent.SqlServer'
                typeHandlerVersion = '1.1'
                provisioningState  = $State
                settings           = [pscustomobject]@{ LicenseType = $LicenseType; SqlManagement = [pscustomobject]@{ IsEnabled = $true } }
                instanceView       = [pscustomobject]@{ typeHandlerVersion = $Version }
            }
        }
    }

    function New-TestState {
        param(
            [System.Collections.IDictionary] $Config,
            [AllowNull()] [object] $Machine,
            [object[]] $Machines = @(),
            [object[]] $Instances = @(),
            [AllowNull()] [object] $Extension = $null,
            [string] $HostPowerState = ''
        )
        $target = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = $Config } { param($C) Get-DemoArcTarget -Config $C }
        $hosted = @($Instances | Where-Object { $_.properties.containerResourceId -eq $script:machineId })
        [pscustomobject]@{
            Target          = $target
            Machine         = $Machine
            Machines        = $Machines
            Instances       = $Instances
            HostedInstances = $hosted
            Extension       = $Extension
            HostPowerState  = $HostPowerState
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoVmRunCommand' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:arguments = [System.Collections.Generic.List[string]]::new()
        $script:logs = [System.Collections.Generic.List[string]]::new()
        $script:runCommands = [ordered]@{}
        $script:putError = ''
        $script:putCount = 0
        $script:viewStart = $null
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logs.Add([string]$Message) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            foreach ($argument in $ArgumentList) { $script:arguments.Add([string]$argument) }
            $method = $ArgumentList[[array]::IndexOf($ArgumentList, '--method') + 1]
            $url = $ArgumentList[[array]::IndexOf($ArgumentList, '--url') + 1]
            $name = if ($url -match '/runCommands/([^?]+)\?') { $Matches[1] } else { '' }
            $call = [pscustomobject]@{ Method = $method; Name = $name; BodyPath = ''; BodyExisted = $false; Body = $null }
            $script:calls.Add($call)
            switch ($method) {
                'put' {
                    $call.BodyPath = $ArgumentList[[array]::IndexOf($ArgumentList, '--body') + 1].Substring(1)
                    $call.BodyExisted = Test-Path -LiteralPath $call.BodyPath
                    $call.Body = Get-Content -LiteralPath $call.BodyPath -Raw | ConvertFrom-Json -AsHashtable
                    if ($script:putError) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $script:putError }
                    }
                    $script:runCommands[$name] = $true
                    $script:putCount++
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
                }
                'delete' {
                    $script:runCommands.Remove($name)
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                default {
                    if (-not $script:runCommands.Contains($name)) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: Not Found({"error":{"code":"NotFound"}})' }
                    }
                    $view = @{ executionState = 'Succeeded'; exitCode = 0; output = "log line`n{""outcome"":""Onboarded"",""succeeded"":true}"; error = '' }
                    if ($script:viewStart) {
                        $view['startTime'] = & $script:viewStart
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ name = $name; properties = @{ provisioningState = 'Succeeded'; instanceView = $view } } | ConvertTo-Json -Depth 5); StdErr = '' }
                }
            }
        }
    }

    It 'puts the protected value only in a private body file, deletes the file, and deletes the Run Command' {
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-ArcOnboard' -Script 'Write-Output 1' -Parameter @{ Action = 'Onboard'; MachineName = 'arcsql01'; Empty = '' } -ProtectedParameter @{ AccessToken = $script:fakeToken } -PollIntervalSeconds 0

        $result.Succeeded | Should -BeTrue
        $result.Removed | Should -BeTrue
        (ConvertFrom-Json -InputObject (($result.Output -split "`n")[-1])).outcome | Should -Be 'Onboarded'
        $put = @($script:calls | Where-Object Method -eq 'put')
        $put.Count | Should -Be 1
        $put[0].BodyExisted | Should -BeTrue
        Test-Path -LiteralPath $put[0].BodyPath | Should -BeFalse
        Test-Path -LiteralPath (Split-Path -Path $put[0].BodyPath -Parent) | Should -BeFalse
        $put[0].Body.properties.protectedParameters[0].name | Should -Be 'AccessToken'
        $put[0].Body.properties.protectedParameters[0].value | Should -Be $script:fakeToken
        $put[0].Body.properties.parameters.name | Should -Not -Contain 'Empty'
        ($put[0].Body.properties.parameters | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:fakeToken))
        $put[0].Body.properties.asyncExecution | Should -BeFalse
        ($script:arguments -join ' ') | Should -Not -Match ([regex]::Escape($script:fakeToken))
        ($script:logs -join ' ') | Should -Not -Match ([regex]::Escape($script:fakeToken))
        # Leftover delete, PUT, then the delete in finally.
        $methods = @($script:calls.Method)
        $methods[0] | Should -Be 'delete'
        [array]::LastIndexOf($methods, 'delete') | Should -BeGreaterThan ([array]::IndexOf($methods, 'put'))
        $script:runCommands.Count | Should -Be 0
    }

    It 'deletes the body file and the Run Command when the PUT fails' {
        $script:putError = 'ERROR: BadRequest({"error":{"code":"BadRequest"}})'
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-ArcOnboard' -Script 'Write-Output 1' -ProtectedParameter @{ AccessToken = $script:fakeToken } -PollIntervalSeconds 0 } | Should -Throw '*creating the Run Command DbHubDemo-ArcOnboard failed*'
        $put = @($script:calls | Where-Object Method -eq 'put')
        Test-Path -LiteralPath $put[0].BodyPath | Should -BeFalse
        @($script:calls | Where-Object Method -eq 'delete').Count | Should -Be 2
        ($script:logs -join ' ') | Should -Not -Match ([regex]::Escape($script:fakeToken))
    }

    It 'deletes the Run Command even when waiting for it throws' {
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoRunCommand -MockWith { throw 'The wait was interrupted.' }
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0 } | Should -Throw '*interrupted*'
        $methods = @($script:calls.Method)
        [array]::LastIndexOf($methods, 'delete') | Should -BeGreaterThan ([array]::IndexOf($methods, 'put'))
        $script:runCommands.Count | Should -Be 0
    }

    It 'runs -WhileRunning once, after Azure accepted the Run Command and before waiting for it (ADR 0018)' {
        $script:seen = [System.Collections.Generic.List[string]]::new()
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-Golden' -Script 'Write-Output 1' -PollIntervalSeconds 0 -WhileRunning { $script:seen.Add(('{0} {1}' -f $script:calls.Count, $script:calls[$script:calls.Count - 1].Method)); 'ignored output' }

        $result.Succeeded | Should -BeTrue
        $result.WhileRunningError | Should -BeNullOrEmpty
        $script:seen.Count | Should -Be 1
        # The leftover delete and the PUT came first; the reads and the final delete came after the block.
        $putAt = [array]::IndexOf(@($script:calls.Method), 'put')
        $script:seen[0] | Should -Be ('{0} put' -f ($putAt + 1))
        @($script:calls | Select-Object -Skip ($putAt + 1) | Where-Object Method -eq 'get').Count | Should -BeGreaterThan 0
        [array]::LastIndexOf(@($script:calls.Method), 'delete') | Should -BeGreaterThan $putAt
        $script:runCommands.Count | Should -Be 0
    }

    It 'returns a -WhileRunning error instead of throwing, and still waits for the Run Command and deletes it' {
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-Golden' -Script 'Write-Output 1' -PollIntervalSeconds 0 -WhileRunning { throw 'chunk 3 of 7 failed' }

        $result.Succeeded | Should -BeTrue
        $result.WhileRunningError | Should -Match 'chunk 3 of 7 failed'
        @($script:calls | Where-Object Method -eq 'get').Count | Should -BeGreaterThan 0
        $script:runCommands.Count | Should -Be 0
        ($script:logs -join ' ') | Should -Match 'still awaited'
    }

    It 'runs again once when the instance view reports an earlier run with the same name' {
        $script:viewStart = { if ($script:putCount -lt 2) { [System.DateTime]::UtcNow.AddMinutes(-10).ToString('o') } else { [System.DateTime]::UtcNow.ToString('o') } }
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0

        $result.Succeeded | Should -BeTrue
        $result.Stale | Should -BeFalse
        (ConvertFrom-Json -InputObject (($result.Output -split "`n")[-1])).outcome | Should -Be 'Onboarded'
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 60 } -Times 1 -Exactly
        ($script:logs -join ' ') | Should -Match 'reported an earlier run'
        $script:runCommands.Count | Should -Be 0
    }

    It 'ignores the result and reports Stale when the second run reports an earlier run too' {
        $script:viewStart = { [System.DateTime]::UtcNow.AddMinutes(-10).ToString('o') }
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0

        $result.Succeeded | Should -BeFalse
        $result.Stale | Should -BeTrue
        $result.Output | Should -BeNullOrEmpty
        $result.Error | Should -Match 'earlier run'
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 2
        $script:runCommands.Count | Should -Be 0
    }

    It 'accepts a run that started just before the request was sent, within the clock-skew allowance' {
        $script:viewStart = { [System.DateTime]::UtcNow.AddSeconds(-10).ToString('o') }
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0

        $result.Succeeded | Should -BeTrue
        $result.Stale | Should -BeFalse
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 1
    }

    It 'refuses a public value that would not survive the command line, before calling Azure' {
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-ArcOnboard' -Script 'x' -Parameter @{ Tags = 'owner=a b' } } | Should -Throw '*Base64-encode it*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'refuses a parameter that is both public and protected' {
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-ArcOnboard' -Script 'x' -Parameter @{ AccessToken = 'a' } -ProtectedParameter @{ AccessToken = $script:fakeToken } } | Should -Throw '*both public and protected*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'refuses a value that is a .NET type name, which means a SecureString was converted with [string]: <Kind>' -ForEach @(
        @{ Kind = 'public'; Public = @{ Password = 'System.Security.SecureString' }; Protected = @{} }
        @{ Kind = 'protected string'; Public = @{}; Protected = @{ Password = 'System.Security.SecureString' } }
        @{ Kind = 'public credential'; Public = @{ Credential = 'System.Management.Automation.PSCredential' }; Protected = @{} }
    ) {
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HostPassword' -Script 'x' -Parameter $Public -ProtectedParameter $Protected } | Should -Throw '*is a .NET type name*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'refuses a SecureString whose content is a type name, before any PUT' {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'System.Security.SecureString'.ToCharArray()) { $secure.AppendChar($character) }
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HostPassword' -Script 'x' -ProtectedParameter @{ Password = $secure } -PollIntervalSeconds 0 } | Should -Throw '*is a .NET type name*'
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 0
    }

    It 'changes nothing under -WhatIf' {
        Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-ArcOnboard' -Script 'x' -ProtectedParameter @{ AccessToken = $script:fakeToken } -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }
}

Describe 'Run Command helpers' {
    It 'creates private directories for the current user only and deletes them' {
        $directory = InModuleScope -ModuleName DbHubDemo { Initialize-DemoPrivateDirectory -Prefix 'dbhub-test' }
        try {
            $file = InModuleScope -ModuleName DbHubDemo -Parameters @{ D = $directory } { param($D) Write-DemoPrivateFile -Directory $D -Name 'body.json' -Content '{}' }
            Get-Content -LiteralPath $file -Raw | Should -Be '{}'
            if ($IsWindows) {
                $acl = Get-Acl -LiteralPath $directory
                $acl.AreAccessRulesProtected | Should -BeTrue
                @($acl.Access).Count | Should -Be 1
                $acl.Access[0].IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value | Should -Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            }
            else {
                [System.IO.File]::GetUnixFileMode($directory) | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
                [System.IO.File]::GetUnixFileMode($file) | Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite')
            }
        }
        finally {
            InModuleScope -ModuleName DbHubDemo -Parameters @{ D = $directory } { param($D) Remove-DemoPrivateDirectory -Path $D -Confirm:$false } | Should -BeTrue
        }
        Test-Path -LiteralPath $directory | Should -BeFalse
    }

    It 'reads the last JSON line of Run Command output' {
        InModuleScope -ModuleName DbHubDemo {
            (ConvertFrom-DemoRunCommandOutput -Text "starting`n{""a"":1}`nnoise`n{""state"":""Ready""}`n").state | Should -Be 'Ready'
            ConvertFrom-DemoRunCommandOutput -Text "no json here`n{broken" | Should -BeNullOrEmpty
            ConvertFrom-DemoRunCommandOutput -Text '' | Should -BeNullOrEmpty
        }
    }

    It 'reads the instance view start time as UTC' {
        InModuleScope -ModuleName DbHubDemo {
            $expected = [datetime]::new(2026, 10, 21, 15, 42, 6, [System.DateTimeKind]::Utc)
            ConvertTo-DemoRunCommandUtc -Value '2026-10-21T15:42:06Z' | Should -Be $expected
            ConvertTo-DemoRunCommandUtc -Value '2026-10-21T15:42:06+00:00' | Should -Be $expected
            ConvertTo-DemoRunCommandUtc -Value $expected | Should -Be $expected
            (ConvertTo-DemoRunCommandUtc -Value ([datetime]::SpecifyKind($expected, [System.DateTimeKind]::Unspecified))).Kind | Should -Be 'Utc'
            ConvertTo-DemoRunCommandUtc -Value $null | Should -BeNullOrEmpty
            ConvertTo-DemoRunCommandUtc -Value '' | Should -BeNullOrEmpty
            ConvertTo-DemoRunCommandUtc -Value 'not a time' | Should -BeNullOrEmpty
        }
    }

    It 'retries a 409 Conflict with backoff and returns other failures at once' {
        $script:answers = [System.Collections.Generic.Queue[object]]::new()
        $script:answers.Enqueue([pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (Conflict) Another operation is in progress.' })
        $script:answers.Enqueue([pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: Conflict' })
        $script:answers.Enqueue([pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' })
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { $script:answers.Dequeue() }
        $result = InModuleScope -ModuleName DbHubDemo { Invoke-DemoAzWithConflictRetry -SubscriptionId '11111111-2222-3333-4444-555555555555' -ArgumentList @('rest', '--method', 'put', '--url', 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01/runCommands/x?api-version=2025-11-01') -Label 'test' }
        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 10 } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 20 } -Times 1 -Exactly

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: AuthorizationFailed' } }
        $failed = InModuleScope -ModuleName DbHubDemo { Invoke-DemoAzWithConflictRetry -SubscriptionId '11111111-2222-3333-4444-555555555555' -ArgumentList @('rest', '--method', 'get', '--url', 'https://management.azure.com/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01/runCommands/x?api-version=2025-11-01') -Label 'test' }
        $failed.ExitCode | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'get' }
    }
}

Describe 'Arc onboarding decision table' {
    BeforeAll {
        function New-Probe {
            param([bool] $Reachable = $true, [bool] $Imds = $false, [bool] $Wire = $false, [string] $Status = '', [string] $Name = '', [string] $Group = '', [string] $VmId = '')
            [pscustomobject]@{ guestReachable = $Reachable; imdsReachable = $Imds; wireServerReachable = $Wire; agentStatus = $Status; agentResourceName = $Name; agentResourceGroup = $Group; agentSubscriptionId = ''; agentVmId = $VmId }
        }
        function Get-Decision {
            param([string] $HostState = 'WaitingForArcOnboarding', [AllowNull()] [object] $Probe, [AllowNull()] [object] $Machine, [switch] $Force, [switch] $EvaluationOnly)
            InModuleScope -ModuleName DbHubDemo -Parameters @{ H = $HostState; P = $Probe; M = $Machine; F = [bool]$Force; E = [bool]$EvaluationOnly } {
                param($H, $P, $M, $F, $E)
                Get-DemoArcOnboardingDecision -HostState $H -Probe $P -Machine $M -Force:$F -EvaluationOnly:$E -MachineName 'arcsql01' -ResourceGroupName 'rg-dbhub-demo' -SubscriptionId '11111111-2222-3333-4444-555555555555'
            }
        }
    }

    It 'reports the host state and changes nothing when the host is not waiting' {
        $decision = Get-Decision -HostState 'InProgress' -Probe (New-Probe) -Machine $null
        $decision.Action | Should -Be 'ReportHostState'
        $decision.Status | Should -Be 'Warning'
    }

    It 'evaluates the guest with -Force even when the host is not waiting' {
        (Get-Decision -HostState 'Ready' -Probe (New-Probe) -Machine $null -Force).Action | Should -Be 'Onboard'
    }

    It 'skips onboarding when the guest is already Connected to the expected machine' {
        $decision = Get-Decision -Probe (New-Probe -Status 'Connected' -Name 'arcsql01' -Group 'rg-dbhub-demo') -Machine (New-TestMachine)
        $decision.Action | Should -Be 'AlreadyConnected'
        $decision.Status | Should -Be 'Pass'
    }

    It 'falls back to vmId when the agent reports Connected without resource details' {
        (Get-Decision -Probe (New-Probe -Status 'Connected' -VmId 'abc') -Machine (New-TestMachine -VmId 'ABC')).Action | Should -Be 'AlreadyConnected'
        $unverified = Get-Decision -Probe (New-Probe -Status 'Connected' -VmId 'abc') -Machine (New-TestMachine -VmId 'other')
        $unverified.Action | Should -Be 'ConnectedUnverified'
        $unverified.Status | Should -Be 'Manual action required'
    }

    It 'deletes a stale machine before onboarding a rebuilt guest' {
        $decision = Get-Decision -Probe (New-Probe) -Machine (New-TestMachine -Status 'Disconnected')
        $decision.Action | Should -Be 'CleanupStaleThenOnboard'
        $decision.Reason | Should -Match 'AZCM0044'
    }

    It 'never deletes a machine that is Connected while the guest has no identity (ADR 0018)' {
        $decision = Get-Decision -Probe (New-Probe) -Machine (New-TestMachine -Status 'Connected')
        $decision.Action | Should -Be 'StaleMachineConnected'
        $decision.Status | Should -Be 'Fail'
        $decision.Reason | Should -Match 'Nothing is deleted'
    }

    It 'resets the agent locally when its Azure resource was deleted' {
        (Get-Decision -Probe (New-Probe -Status 'Disconnected' -Name 'arcsql01') -Machine $null).Action | Should -Be 'DisconnectLocalThenOnboard'
    }

    It 'waits instead of deleting when the agent is configured for the machine but not Connected right now' {
        (Get-Decision -Probe (New-Probe -Status 'Disconnected' -Name 'arcsql01') -Machine (New-TestMachine -Status 'Disconnected')).Action | Should -Be 'AgentNotConnected'
    }

    It 'refuses to touch an agent connected to another resource' {
        $decision = Get-Decision -Probe (New-Probe -Status 'Connected' -Name 'other' -Group 'rg-other') -Machine (New-TestMachine)
        $decision.Action | Should -Be 'ConnectedElsewhere'
        $decision.Status | Should -Be 'Fail'
    }

    It 'onboards when there is neither an agent connection nor a machine' {
        (Get-Decision -Probe (New-Probe) -Machine $null).Action | Should -Be 'Onboard'
    }

    It 'fails closed when the guest can reach IMDS or, nested, the wire server' {
        (Get-Decision -Probe (New-Probe -Imds $true) -Machine $null).Action | Should -Be 'GuestNotIsolated'
        (Get-Decision -Probe (New-Probe -Wire $true) -Machine $null).Action | Should -Be 'GuestNotIsolated'
        (Get-Decision -Probe (New-Probe -Wire $true) -Machine $null -EvaluationOnly).Action | Should -Be 'Onboard'
    }

    It 'waits when the guest does not answer' {
        (Get-Decision -Probe (New-Probe -Reachable $false) -Machine $null).Action | Should -Be 'GuestUnreachable'
        (Get-Decision -Probe $null -Machine $null).Action | Should -Be 'GuestUnreachable'
    }
}

Describe 'Invoke-DemoArcOnboarding' {
    BeforeEach {
        $script:sequence = [System.Collections.Generic.List[string]]::new()
        $script:runs = [System.Collections.Generic.List[object]]::new()
        $script:probe = @{ guestReachable = $true; imdsReachable = $false; wireServerReachable = $false; agentStatus = ''; agentResourceName = ''; agentResourceGroup = ''; agentKeys = @() }
        $script:machine = $null
        $script:hostState = 'WaitingForArcOnboarding'
        $script:sweepPart = [ordered]@{ computer = 'VM'; reachable = $true; pass = $true; found = [ordered]@{ user = 1; other = 0; app = 0; files = 0; archives = 0; caches = 0; unverified = 0; logUser = 1; logApp = 0 }; remaining = [ordered]@{ user = 0; other = 0; app = 0; files = 0; archives = 0; caches = 0; unverified = 0; logUser = 0; logApp = 0 }; eventLogs = @('Windows PowerShell|u1 a0 o0|..'); found_at = @(); left_at = @(); seconds = 9 }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { [pscustomobject]@{ state = $script:hostState; message = 'host message' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith { $script:machine }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -MockWith { $script:sequence.Add('cleanup'); @('sqlServerInstances/arcsql01', 'machines/arcsql01') }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -MockWith { $script:sequence.Add('token'); $script:fakeToken }
        $script:identity = [pscustomobject]@{ Found = $false; ClientId = ''; Name = 'id-dbhub-demo-arc-onboard'; Reason = 'id-dbhub-demo-arc-onboard isn''t attached to archost01 (deploy.ps1 creates it only with assignRoles = true)' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcHostIdentity -MockWith { $script:sequence.Add('identity'); $script:identity }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ solution = 'fabric-database-hub-demo'; owner = 'demo-owner'; autoShutdown = '1900 Pacific Standard Time' } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoArcMachineConnected -MockWith { New-TestMachine }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            # Unbound parameters aren't variables in a mock, which strict mode would reject.
            $RunCommandName = $PesterBoundParameters['RunCommandName']
            $script:sequence.Add($RunCommandName)
            # Copies: the caller clears its protected values as soon as the Run Command returns.
            $protectedCopy = @{}
            if ($PesterBoundParameters.ContainsKey('ProtectedParameter')) {
                foreach ($key in $PesterBoundParameters['ProtectedParameter'].Keys) { $protectedCopy[$key] = $PesterBoundParameters['ProtectedParameter'][$key] }
            }
            $parameterCopy = @{}
            if ($PesterBoundParameters.ContainsKey('Parameter')) {
                foreach ($key in $PesterBoundParameters['Parameter'].Keys) { $parameterCopy[$key] = $PesterBoundParameters['Parameter'][$key] }
            }
            $script:runs.Add([pscustomobject]@{ Name = $RunCommandName; Parameter = $parameterCopy; Protected = $protectedCopy; VmName = $PesterBoundParameters['VmName'] })
            $output = if ($RunCommandName -eq 'DbHubDemo-ArcProbe') { $script:probe | ConvertTo-Json -Compress } elseif ($RunCommandName -eq 'DbHubDemo-SignInData') { [ordered]@{ action = 'Clean'; succeeded = $true; pass = [bool]$script:sweepPart.pass; local = $script:sweepPart; guest = $script:sweepPart } | ConvertTo-Json -Compress -Depth 6 } else { '{"succeeded":true,"outcome":"Onboarded","resourceId":"' + $script:machineId + '"}' }
            [pscustomobject]@{ Succeeded = $true; ExecutionState = 'Succeeded'; ExitCode = 0; Output = $output; Error = '' }
        }
    }

    It 'only reports the host state when the host is still building' {
        $script:hostState = 'InProgress'
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.checkId | Should -Be 'T2.ARC.ONBOARDING'
        $result.status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly
    }

    It 'passes without running anything when the host is Ready' {
        $script:hostState = 'Ready'
        (Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1).status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
    }

    It 'passes without onboarding when the host is past the wizard and the machine is already Connected' {
        # Live finding (2026-10-21): after the setup wizard the host reports InProgress while it configures SQL.
        $script:hostState = 'InProgress'
        $script:machine = New-TestMachine
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'already Connected'
        $result.evidence.azureStatus | Should -Be 'Connected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly
    }

    It 'uses the health the caller already read' {
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Health ([pscustomobject]@{ state = 'InProgress' }) -PollIntervalSeconds 1
        $result.status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 0 -Exactly
    }

    It 'rewrites the marker without a token when the guest is already Connected' {
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:machine = New-TestMachine
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.evidence.decision | Should -Be 'AlreadyConnected'
        $script:runs[1].Parameter['Action'] | Should -Be 'WriteMarker'
        $script:runs[1].Protected.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -Times 0 -Exactly
    }

    It 'deletes a stale machine first, then onboards with the token only as a protected parameter' {
        $script:machine = New-TestMachine -Status 'Disconnected'
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $script:sequence | Should -Be @('DbHubDemo-ArcProbe', 'cleanup', 'identity', 'token', 'DbHubDemo-ArcOnboard', 'DbHubDemo-SignInData')
        $result.evidence.tokenSource | Should -Be 'Caller'
        $onboard = $script:runs[1]
        $onboard.VmName | Should -Be 'archost01'
        $onboard.Parameter['Action'] | Should -Be 'Onboard'
        $onboard.Protected['AccessToken'] | Should -Be $script:fakeToken
        ($onboard.Parameter.Values -join ' ') | Should -Not -Match ([regex]::Escape($script:fakeToken))
        $onboard.Parameter['Tags'] | Should -Be 'solution=fabric-database-hub-demo,owner=demo-owner'
        $onboard.Parameter['DisconnectLocalFirst'] | Should -Be 'false'
        $result.evidence.deletedStaleResources | Should -Be @('sqlServerInstances/arcsql01', 'machines/arcsql01')
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:fakeToken))
    }

    It 'removes the onboarding token''s traces on the host and in the guest right after onboarding, and fails closed when any is left' {
        $script:machine = New-TestMachine -Status 'Disconnected'
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $sweep = @($script:runs | Where-Object Name -EQ 'DbHubDemo-SignInData')
        $sweep.Count | Should -Be 1
        $sweep[0].VmName | Should -Be 'archost01'
        $sweep[0].Parameter['ResidueAction'] | Should -Be 'Clean'
        $sweep[0].Parameter['ResidueScope'] | Should -Be 'Both'
        $sweep[0].Protected.Count | Should -Be 0 -Because 'the sweep takes no secret'
        $result.status | Should -Be 'Pass'
        $result.evidence.signInData.status | Should -Be 'Pass'

        $script:sweepPart.pass = $false
        $script:sweepPart.remaining.logUser = 2
        $failed = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'traces couldn''t be removed and verified'
        $failed.message | Should -Match '2 sign-in token\(s\) in event logs'
        ($failed | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:fakeToken))
    }

    It 'clears the host''s Windows PowerShell log after onboarding with the caller''s token, warns, and passes the check that follows' {
        # The default path for a Contributor-only caller: Run Command hands the token to the host's PowerShell as
        # an argument, so the Windows PowerShell log records it (live audit, 2026-10-27: 9 values from one onboarding).
        $script:machine = New-TestMachine -Status 'Disconnected'
        $script:sweepPart.found.logUser = 9
        $script:sweepPart['actions'] = [ordered]@{ redacted = 0; deleted = 0; failed = 0; caches = 0; broker = 0; logsCleared = @('Windows PowerShell'); logsNotCleared = @() }
        $warned = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $sweep = @($script:runs | Where-Object Name -EQ 'DbHubDemo-SignInData')[0]
        $sweep.Parameter['ResidueAction'] | Should -Be 'Clean'
        $sweep.Parameter['ClearEventLogs'] | Should -Be 'true' -Because 'the automatic flow clears a non-Security log that holds a token-shaped value'
        $sweep.Parameter['ClearSecurityLog'] | Should -Be 'false' -Because 'only an operator clears the Security log'
        $warned.status | Should -Be 'Warning' -Because 'the log was cleared and the scan after it passed, so nothing fails closed'
        $warned.message | Should -Match 'is onboarded and Connected'
        $warned.message | Should -Match 'endpoint protection may report'
        $warned.evidence.signInData.status | Should -Be 'Warning'
    }

    It 'warns when the sweep after onboarding cleared an event log, and asks for manual action when the Security log holds a token-shaped value' {
        $script:machine = New-TestMachine -Status 'Disconnected'
        $script:sweepPart['actions'] = [ordered]@{ redacted = 0; deleted = 0; failed = 0; caches = 0; broker = 0; logsCleared = @('Windows PowerShell'); logsNotCleared = @() }
        $warned = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $warned.status | Should -Be 'Warning'
        $warned.message | Should -Match 'is onboarded and Connected'
        $warned.message | Should -Match 'endpoint protection may report'

        $script:sweepPart['actions']['logsCleared'] = @()
        $script:sweepPart.remaining['security'] = 1
        $manual = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $manual.status | Should -Be 'Manual action required'
        $manual.message | Should -Match 'is onboarded'
        $manual.remediation | Should -Match ([regex]::Escape('./scripts/check-sign-in-data.ps1 -VmName archost01 -Clean -ClearSecurityLog'))
    }
    It 'onboards with the host identity whenever it''s attached: no token of the caller''s, nothing protected' {
        $script:identity = [pscustomobject]@{ Found = $true; ClientId = 'aaaaaaaa-1111-2222-3333-444444444444'; Name = 'id-dbhub-demo-arc-onboard'; Reason = '' }
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig -Override @{ assignRoles = $false }) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.evidence.tokenSource | Should -Be 'HostIdentity'
        $result.evidence.hostIdentity | Should -Be 'attached'
        $onboard = @($script:runs | Where-Object Name -EQ 'DbHubDemo-ArcOnboard')[0]
        $onboard.Parameter['TokenSource'] | Should -Be 'HostIdentity'
        $onboard.Parameter['IdentityClientId'] | Should -Be 'aaaaaaaa-1111-2222-3333-444444444444'
        $onboard.Protected.Count | Should -Be 0 -Because 'no token leaves the operator''s machine'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly
        @($script:runs | Where-Object Name -EQ 'DbHubDemo-SignInData').Count | Should -Be 1 -Because 'the guest still got a token, the identity''s'
    }

    It 'uses the caller''s token with -UseCallerToken, and fails with -UseHostIdentity when the identity isn''t attached' {
        $script:identity = [pscustomobject]@{ Found = $true; ClientId = 'aaaaaaaa-1111-2222-3333-444444444444'; Name = 'id-dbhub-demo-arc-onboard'; Reason = '' }
        $caller = Invoke-DemoArcOnboarding -Config (New-TestConfig) -UseCallerToken -PollIntervalSeconds 1
        $caller.evidence.tokenSource | Should -Be 'Caller'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArcHostIdentity -Times 0 -Exactly
        @($script:runs | Where-Object Name -EQ 'DbHubDemo-ArcOnboard')[0].Protected['AccessToken'] | Should -Be $script:fakeToken

        $script:identity = [pscustomobject]@{ Found = $false; ClientId = ''; Name = 'id-dbhub-demo-arc-onboard'; Reason = 'id-dbhub-demo-arc-onboard isn''t attached to archost01' }
        $script:runs.Clear()
        $required = Invoke-DemoArcOnboarding -Config (New-TestConfig) -UseHostIdentity -PollIntervalSeconds 1
        $required.status | Should -Be 'Fail'
        $required.message | Should -Match 'isn''t attached'
        @($script:runs | Where-Object Name -EQ 'DbHubDemo-ArcOnboard').Count | Should -Be 0
    }

    It 'refuses -UseHostIdentity in the evaluation-only mode and together with -UseCallerToken' {
        (Invoke-DemoArcOnboarding -Config (New-TestConfig -Override @{ t2Mode = 'EvaluationOnlyAzureVm' }) -UseHostIdentity).status | Should -Be 'Fail'
        (Invoke-DemoArcOnboarding -Config (New-TestConfig) -UseHostIdentity -UseCallerToken).status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 0 -Exactly
    }

    It 'warns when the agent got the token on its command line because it didn''t take it from its config file' {
        $script:machine = New-TestMachine -Status 'Disconnected'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $RunCommandName = $PesterBoundParameters['RunCommandName']
            $output = if ($RunCommandName -eq 'DbHubDemo-ArcProbe') { $script:probe | ConvertTo-Json -Compress } elseif ($RunCommandName -eq 'DbHubDemo-SignInData') { [ordered]@{ action = 'Clean'; succeeded = $true; pass = $true; local = $script:sweepPart; guest = $script:sweepPart } | ConvertTo-Json -Compress -Depth 6 } else { '{"succeeded":true,"outcome":"Onboarded","resourceId":"' + $script:machineId + '","tokenPassedBy":"CommandLine","connectAttempts":2,"authorizationWaitSeconds":30}' }
            [pscustomobject]@{ Succeeded = $true; ExecutionState = 'Succeeded'; ExitCode = 0; Output = $output; Error = '' }
        }
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'command line once'
        $result.evidence.connectAttempts | Should -Be 2
        $result.evidence.authorizationWaitSeconds | Should -Be 30
    }

    It 'labels every result EVALUATION ONLY and targets the Azure VM in the evaluation-only mode' {
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig -Override @{ t2Mode = 'EvaluationOnlyAzureVm' }) -PollIntervalSeconds 1
        $result.message | Should -Match '^EVALUATION ONLY: '
        $result.evaluationOnly | Should -BeTrue
        $script:runs[0].VmName | Should -Be 'arcsql01'
        $script:runs[0].Parameter['Mode'] | Should -Be 'EvaluationOnlyAzureVm'
    }
}

Describe 'Remove-DemoArcStaleResource' {
    It 'deletes the machine''s SQL Server instances before the machine, and only its own' {
        $script:deleted = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith {
            , @((New-TestInstance -Name 'arcsql01'), (New-TestInstance -Name 'sqlvm01' -Container '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01'))
        }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoArmResource -MockWith { $script:deleted.Add(($Url -replace '\?.*$', '')); $true }
        $config = New-TestConfig
        $deleted = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = $config } { param($C) Remove-DemoArcStaleResource -Target (Get-DemoArcTarget -Config $C) -Confirm:$false }
        $deleted | Should -Be @('sqlServerInstances/arcsql01', 'machines/arcsql01')
        $script:deleted[0] | Should -Match '/providers/Microsoft\.AzureArcData/sqlServerInstances/arcsql01$'
        $script:deleted[1] | Should -Match '/providers/Microsoft\.HybridCompute/machines/arcsql01$'
    }

    It 'leaves the machine in place when an instance is still being deleted' {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith { , @(New-TestInstance) }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoArmResource -MockWith { $false }
        $config = New-TestConfig
        { InModuleScope -ModuleName DbHubDemo -Parameters @{ C = $config } { param($C) Remove-DemoArcStaleResource -Target (Get-DemoArcTarget -Config $C) -Confirm:$false } } | Should -Throw '*left in place*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArmResource -Times 1 -Exactly
    }
}

Describe 'Product key' {
    BeforeAll {
        $script:fakeKey = (@('A1B2C') * 5) -join '-'
        function ConvertTo-TestSecureString([string] $Text) {
            $secure = [System.Security.SecureString]::new()
            foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
            $secure.MakeReadOnly()
            return $secure
        }
    }

    BeforeEach {
        $script:runs = [System.Collections.Generic.List[object]]::new()
        $script:keyLog = 'DBHUBDEMO-LOG found=0 cleared=False error='
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $parameterCopy = @{}
            if ($PesterBoundParameters.ContainsKey('Parameter')) { $parameterCopy = $PesterBoundParameters['Parameter'] }
            $protectedCopy = @{}
            foreach ($key in $PesterBoundParameters['ProtectedParameter'].Keys) { $protectedCopy[$key] = $PesterBoundParameters['ProtectedParameter'][$key] }
            $script:runs.Add([pscustomobject]@{ Name = $PesterBoundParameters['RunCommandName']; Parameter = $parameterCopy; Protected = $protectedCopy; Script = $PesterBoundParameters['Script'] })
            [pscustomobject]@{ Succeeded = $true; ExecutionState = 'Succeeded'; ExitCode = 0; Output = ("The product key is stored for the T2 install step.`n" + $script:keyLog); Error = '' }
        }
    }

    It 'clears the host''s Windows PowerShell log in the same Run Command when it recorded the key, and warns' {
        $script:keyLog = 'DBHUBDEMO-LOG found=3 cleared=True error='
        $result = Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey (ConvertTo-TestSecureString $script:fakeKey)
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'endpoint protection may report'
        $result.evidence.powerShellLog.found | Should -Be 3
        $script:runs[0].Script | Should -Match 'function Clear-DemoProtectedValueLog' -Because 'the orchestrator inserts the helper into the Run Command'
        $script:runs[0].Script | Should -Match ([regex]::Escape('Clear-DemoProtectedValueLog -Value $ProductKey'))
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:fakeKey))

        $script:keyLog = 'DBHUBDEMO-LOG found=1 cleared=False error=UnauthorizedAccessException'
        $manual = Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey (ConvertTo-TestSecureString $script:fakeKey)
        $manual.status | Should -Be 'Manual action required'
        $manual.remediation | Should -Match ([regex]::Escape('wevtutil clear-log "Windows PowerShell"'))
        $manual.remediation | Should -Not -Match 'Security'
    }

    It 'reports the host''s Windows PowerShell log even when storing the key failed' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            [pscustomobject]@{ Succeeded = $false; ExecutionState = 'Failed'; ExitCode = 1; Output = $script:keyLog; Error = 'Storing the product key failed: access denied.' }
        }
        $script:keyLog = 'DBHUBDEMO-LOG found=2 cleared=True error='
        $result = Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey (ConvertTo-TestSecureString $script:fakeKey)
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'endpoint protection may report'
        $result.remediation | Should -Not -Match 'wevtutil'

        $script:keyLog = 'DBHUBDEMO-LOG found=2 cleared=False error=UnauthorizedAccessException'
        $failed = Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey (ConvertTo-TestSecureString $script:fakeKey)
        $failed.status | Should -Be 'Fail'
        $failed.remediation | Should -Match ([regex]::Escape('wevtutil clear-log "Windows PowerShell"'))
        ($failed | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:fakeKey))
    }

    It 'sends the key only as a protected parameter to Set-DemoSqlProductKey.ps1' {
        $result = Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey (ConvertTo-TestSecureString $script:fakeKey)
        $result.checkId | Should -Be 'T2.SQL.PRODUCTKEY'
        $result.status | Should -Be 'Pass'
        $script:runs.Count | Should -Be 1
        $script:runs[0].Name | Should -Be 'DbHubDemo-SqlProductKey'
        $script:runs[0].Protected['ProductKey'] | Should -Be $script:fakeKey
        $script:runs[0].Parameter.Count | Should -Be 0
        $script:runs[0].Script | Should -Match 'DataProtectionScope'
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:fakeKey))
    }

    It 'sends nothing outside ProductKey mode' {
        (Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'PaygWizard' }) -ProductKey (ConvertTo-TestSecureString $script:fakeKey)).status | Should -Be 'Not selected'
        $script:runs.Count | Should -Be 0
    }

    It 'rejects a malformed key without sending it' {
        $result = Set-DemoArcSqlProductKey -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey (ConvertTo-TestSecureString 'not-a-key')
        $result.status | Should -Be 'Fail'
        $script:runs.Count | Should -Be 0
    }
}

Describe 'Invoke-DemoArcConfiguration' {
    BeforeAll {
        $script:fakeKey = (@('A1B2C') * 5) -join '-'
        $secureKey = [System.Security.SecureString]::new()
        foreach ($character in $script:fakeKey.ToCharArray()) { $secureKey.AppendChar($character) }
        $secureKey.MakeReadOnly()
    }

    BeforeEach {
        $script:states = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Guard passed.' }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { [pscustomobject]@{ Health = [pscustomobject]@{ state = $script:states.Dequeue() }; Polls = 1 } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoArcSqlProductKey -MockWith { New-DemoResult -CheckId 'T2.SQL.PRODUCTKEY' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Sent.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcOnboarding -MockWith { New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('Onboarded at {0}.' -f $Health.state) }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -MockWith { New-DemoResult -CheckId 'T2.ARC.CONFIGURATION' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Configured.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcCheck -MockWith { New-DemoResult -CheckId 'T2.ARC.CONNECTED' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Connected.' }
    }

    It 'refuses to run when the subscription guard fails' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'Subscription guard: wrong subscription.' }
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig))
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoArcOnboarding -Times 0 -Exactly
    }

    It 'asks for the product key when the host waits for it and none was given' {
        $script:states.Enqueue('WaitingForProductKey')
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }))
        ($results | Where-Object checkId -eq 'T2.SQL.PRODUCTKEY').status | Should -Be 'Manual action required'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoArcOnboarding -Times 0 -Exactly
    }

    It 'sends the key, waits for the install within the same budget, then onboards and configures' {
        $script:states.Enqueue('WaitingForProductKey')
        $script:states.Enqueue('WaitingForArcOnboarding')
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey $secureKey -WaitForHostMinutes 30 -HostPollMinutes 5)
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlProductKey -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -Times 1 -Exactly -ParameterFilter { $MaxPolls -eq 6 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -Times 1 -Exactly -ParameterFilter { $MaxPolls -eq 5 -and $State -notcontains 'WaitingForProductKey' }
        ($results | Where-Object checkId -eq 'T2.ARC.ONBOARDING').message | Should -Be 'Onboarded at WaitingForArcOnboarding.'
        $results.checkId | Should -Contain 'T2.ARC.CONFIGURATION'
        $results.checkId | Should -Contain 'T2.ARC.CONNECTED'
    }

    It 'never sends a key to a host that is not waiting for one' {
        $script:states.Enqueue('InProgress')
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }) -ProductKey $secureKey)
        ($results | Where-Object checkId -eq 'T2.SQL.PRODUCTKEY').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlProductKey -Times 0 -Exactly
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 0 -Exactly
    }

    It 'configures SQL Server enabled by Azure Arc once the host is past onboarding' {
        $script:states.Enqueue('ManualActionRequired')
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig) -WaitMinutes 1)
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 1 -Exactly
        $results.checkId | Should -Contain 'T2.ARC.CONNECTED'
    }

    It 'configures when the host is InProgress after the wizard and the machine is already Connected' {
        $script:states.Enqueue('InProgress')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcOnboarding -MockWith { New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Already Connected.' -Evidence @{ azureStatus = 'Connected' } }
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig) -WaitMinutes 1)
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 1 -Exactly
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Pass'
    }

    It 'checks an evaluation-only VM through Azure once its guest agent is disabled' {
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { throw 'Run Command timed out.' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith { New-TestMachine }
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig -Override @{ t2Mode = 'EvaluationOnlyAzureVm' }) -WaitMinutes 1)
        ($results | Where-Object checkId -eq 'T2.ARC.ONBOARDING').message | Should -Be 'Onboarded at Ready.'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 1 -Exactly

        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcArmResource -MockWith { $null }
        $failed = @(Invoke-DemoArcConfiguration -Config (New-TestConfig -Override @{ t2Mode = 'EvaluationOnlyAzureVm' }))
        ($failed | Where-Object checkId -eq 'T2.ARC.ONBOARDING').status | Should -Be 'Fail'
        ($failed | Where-Object checkId -eq 'T2.ARC.ONBOARDING').message | Should -Match '^EVALUATION ONLY: '
    }

    It 'runs only the guard under -WhatIf' {
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig) -WhatIf)
        $results.checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'T2.ARC.ONBOARDING')
        $results[1].status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -Times 0 -Exactly
    }
}

Describe 'T2 Arc checks' {
    BeforeAll {
        $config = New-TestConfig
        $script:now = [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc)
        function Invoke-Check([string] $Name, [object] $State, [datetime] $Now = $script:now) {
            InModuleScope -ModuleName DbHubDemo -Parameters @{ N = $Name; S = $State; T = $Now } {
                param($N, $S, $T)
                switch ($N) {
                    'Extension' { Test-DemoArcSqlExtension -State $S }
                    'Instance' { Test-DemoArcSqlInstance -State $S }
                    'Monitoring' { Test-DemoArcMonitoring -State $S }
                    'Duplicates' { Test-DemoArcNoDuplicate -State $S }
                    'Connected' { Test-DemoArcConnected -State $S -Now $T }
                    'Disconnected' { Test-DemoArcDisconnection -State $S -Now $T }
                }
            }
        }
    }

    It 'compares extension versions part by part' {
        InModuleScope -ModuleName DbHubDemo {
            Test-DemoVersionAtLeast -Version '1.1.2504.99' -Minimum '1.1.2504.99' | Should -BeTrue
            Test-DemoVersionAtLeast -Version '1.1.2504.100' -Minimum '1.1.2504.99' | Should -BeTrue
            Test-DemoVersionAtLeast -Version '1.1.2600.1' -Minimum '1.1.2504.99' | Should -BeTrue
            Test-DemoVersionAtLeast -Version '1.1.2504.98' -Minimum '1.1.2504.99' | Should -BeFalse
            Test-DemoVersionAtLeast -Version '1.1' -Minimum '1.1.2504.99' | Should -BeFalse
            Test-DemoVersionAtLeast -Version '2.0.229.0' -Minimum '2.0.229.0' | Should -BeTrue
            Test-DemoVersionAtLeast -Version '2.0.228.9' -Minimum '2.0.229.0' | Should -BeFalse
            Test-DemoVersionAtLeast -Version 'preview' -Minimum '2.0.229.0' | Should -BeFalse
            Test-DemoVersionAtLeast -Version '' -Minimum '2.0.229.0' | Should -BeFalse
        }
    }

    It 'checks the Azure extension for SQL Server: version, state, and license type' {
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine) -Extension (New-TestExtension))).status | Should -Be 'Pass'
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine) -Extension (New-TestExtension -Version '1.1.2504.98'))).status | Should -Be 'Fail'
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine) -Extension (New-TestExtension -State 'Creating'))).status | Should -Be 'Warning'
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine) -Extension (New-TestExtension -LicenseType 'LicenseOnly'))).status | Should -Be 'Fail'
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine) -Extension $null)).status | Should -Be 'Fail'
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine -SqlDetected $false) -Extension $null)).status | Should -Be 'Manual action required'
    }

    It 'checks the instance''s edition and license type per install mode, and records billable cores' {
        $pass = Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance))
        $pass.status | Should -Be 'Pass'
        $pass.evidence.billableCores | Should -Be 4
        $pass.evidence.cores | Should -Be 2
        (Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Developer'))).status | Should -Be 'Fail'
        (Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -LicenseType 'LicenseOnly'))).status | Should -Be 'Fail'
        $developer = New-TestConfig -Override @{ t2SqlInstallMode = 'Developer' }
        (Invoke-Check 'Instance' (New-TestState -Config $developer -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Developer' -LicenseType 'LicenseOnly'))).status | Should -Be 'Pass'
        $productKey = New-TestConfig -Override @{ t2SqlInstallMode = 'ProductKey' }
        (Invoke-Check 'Instance' (New-TestState -Config $productKey -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Enterprise' -LicenseType 'Paid'))).status | Should -Be 'Pass'
        (Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine -SqlDetected $false))).status | Should -Be 'Manual action required'
    }

    It 'reports monitoring as Not supported in Developer mode' {
        $developer = New-TestConfig -Override @{ t2SqlInstallMode = 'Developer' }
        $result = Invoke-Check 'Monitoring' (New-TestState -Config $developer -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Developer' -Monitoring $false))
        $result.status | Should -Be 'Not supported'
    }

    It 'checks monitoring and its documented prerequisites' {
        (Invoke-Check 'Monitoring' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance) -Extension (New-TestExtension))).status | Should -Be 'Pass'
        (Invoke-Check 'Monitoring' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -Monitoring $false) -Extension (New-TestExtension))).status | Should -Be 'Fail'
        $old = Invoke-Check 'Monitoring' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance) -Extension (New-TestExtension -Version '1.1.2400.1'))
        $old.status | Should -Be 'Fail'
        $old.message | Should -Match '1\.1\.2504\.99'
    }

    It 'finds duplicate and orphaned Arc resources, ignoring T1''s unified-inventory instance' {
        $t1 = New-TestInstance -Name 'sqlvm01' -Container '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/sqlvm01'
        $clean = New-TestState -Config $config -Machine (New-TestMachine) -Machines @((New-TestMachine)) -Instances @((New-TestInstance), $t1)
        (Invoke-Check 'Duplicates' $clean).status | Should -Be 'Pass'
        $extra = [pscustomobject]@{ name = 'arcsql01-old'; properties = [pscustomobject]@{ status = 'Disconnected' } }
        $duplicate = New-TestState -Config $config -Machine (New-TestMachine) -Machines @((New-TestMachine), $extra) -Instances @(New-TestInstance)
        (Invoke-Check 'Duplicates' $duplicate).status | Should -Be 'Fail'
        $orphan = New-TestInstance -Name 'arcsql01-gone' -Container '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.HybridCompute/machines/arcsql01-gone'
        (Invoke-Check 'Duplicates' (New-TestState -Config $config -Machine (New-TestMachine) -Machines @((New-TestMachine)) -Instances @((New-TestInstance), $orphan))).status | Should -Be 'Fail'
    }

    It 'reports Connected, and a short disconnection while the host is stopped as a Warning' {
        (Invoke-Check 'Connected' (New-TestState -Config $config -Machine (New-TestMachine))).status | Should -Be 'Pass'
        $stopped = New-TestState -Config $config -Machine (New-TestMachine -Status 'Disconnected' -LastStatusChange '2026-10-19T12:00:00Z') -HostPowerState 'PowerState/deallocated'
        (Invoke-Check 'Connected' $stopped).status | Should -Be 'Warning'
        $running = New-TestState -Config $config -Machine (New-TestMachine -Status 'Disconnected' -LastStatusChange '2026-10-19T12:00:00Z') -HostPowerState 'PowerState/running'
        (Invoke-Check 'Connected' $running).status | Should -Be 'Fail'
        (Invoke-Check 'Connected' (New-TestState -Config $config -Machine $null)).status | Should -Be 'Fail'
    }

    It 'applies the disconnected-days thresholds: <Days> days is <Status>' -TestCases @(
        @{ Days = 20.9; Status = 'Pass'; Strong = $false }
        @{ Days = 21; Status = 'Warning'; Strong = $false }
        @{ Days = 27.9; Status = 'Warning'; Strong = $false }
        @{ Days = 28; Status = 'Warning'; Strong = $true }
        @{ Days = 30; Status = 'Warning'; Strong = $true }
        @{ Days = 30.1; Status = 'Fail'; Strong = $false }
    ) {
        $changed = $script:now.AddDays(-$Days).ToString('o')
        $result = Invoke-Check 'Disconnected' (New-TestState -Config $config -Machine (New-TestMachine -Status 'Disconnected' -LastStatusChange $changed))
        $result.checkId | Should -Be 'T2.ARC.DISCONNECTEDDAYS'
        $result.status | Should -Be $Status
        $result.evidence.daysDisconnected | Should -Be $Days
        if ($Strong) { $result.message | Should -Match '^Reconnect now' } else { $result.message | Should -Not -Match 'Reconnect now' }
    }

    It 'labels results EVALUATION ONLY in the evaluation-only mode' {
        $evaluation = New-TestConfig -Override @{ t2Mode = 'EvaluationOnlyAzureVm' }
        $result = Invoke-Check 'Connected' (New-TestState -Config $evaluation -Machine (New-TestMachine))
        $result.message | Should -Match '^EVALUATION ONLY: '
        $result.evaluationOnly | Should -BeTrue
        (Invoke-Check 'Connected' (New-TestState -Config $config -Machine (New-TestMachine))).evaluationOnly | Should -BeFalse
    }

    It 'builds the documented extension settings and keeps every setting on a license-type update' {
        InModuleScope -ModuleName DbHubDemo {
            $setting = Get-DemoArcSetting
            $install = Get-DemoArcExtensionBody -SqlExtension $setting.SqlExtension -Location 'westus3' -Existing $null -LicenseType 'PAYG'
            $install.properties.publisher | Should -Be 'Microsoft.AzureData'
            $install.properties.type | Should -Be 'WindowsAgent.SqlServer'
            $install.properties.settings.LicenseType | Should -Be 'PAYG'
            $install.properties.settings.SqlManagement.IsEnabled | Should -BeTrue
            $existing = [pscustomobject]@{ Settings = [pscustomobject]@{ LicenseType = 'LicenseOnly'; SqlManagement = [pscustomobject]@{ IsEnabled = $true }; ExcludedSqlInstances = @('X') }; TypeHandlerVersion = '1.1'; AutoUpgradeMinorVersion = $true; EnableAutomaticUpgrade = $true }
            $update = Get-DemoArcExtensionBody -SqlExtension $setting.SqlExtension -Location 'westus3' -Existing $existing -LicenseType 'PAYG'
            $update.properties.settings.LicenseType | Should -Be 'PAYG'
            @($update.properties.settings.ExcludedSqlInstances) | Should -Be @('X')
        }
    }
}

Describe 'T1 SQL VM performance monitoring' {
    BeforeAll {
        $config = New-TestConfig
        function New-SqlVmState {
            param([object] $Settings, [string] $Version = '2.0.229.0', [string] $Message = '', [string] $Identity = 'SystemAssigned', [string] $ArcData = 'Registered', [int] $Instances = 1)
            $setting = InModuleScope -ModuleName DbHubDemo { (Get-DemoArcSetting).SqlVm }
            [pscustomobject]@{
                VmName             = 'sqlvm01'
                SubscriptionId     = '11111111-2222-3333-4444-555555555555'
                ResourceGroupName  = 'rg-dbhub-demo'
                Location           = 'westus3'
                Setting            = $setting
                Extension          = [pscustomobject]@{ provisioningState = 'Succeeded'; settings = $Settings; instanceView = [pscustomobject]@{ typeHandlerVersion = $Version; statuses = @([pscustomobject]@{ message = $Message }) } }
                Vm                 = [pscustomobject]@{ identity = [pscustomobject]@{ type = $Identity } }
                SqlManagement      = 'Full'
                Providers          = [ordered]@{ 'Microsoft.Sql' = 'Registered'; 'Microsoft.AzureArcData' = $ArcData }
                InventoryInstances = @(if ($Instances -gt 0) { 1..$Instances | ForEach-Object { [pscustomobject]@{ properties = [pscustomobject]@{ edition = 'Standard' } } } })
            }
        }
        $script:running = 'SqlIaasAgent: OK; DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"}'
    }

    It 'merges the feature flag and keeps every existing setting and flag' {
        $existing = '{"AutoPatchingSettings":{"Enable":true},"FeatureFlags":[{"Name":"OtherFeature","Enable":true},{"Name":"databasewatcheronazurevm","Enable":false}],"ServerConfigurationsManagementSettings":{"SQLConnectivityUpdateSettings":{"Port":1433}}}' | ConvertFrom-Json
        $merged = InModuleScope -ModuleName DbHubDemo -Parameters @{ S = $existing } { param($S) Merge-DemoSqlIaasFeatureFlag -Settings $S -Name 'DatabaseWatcheronAzureVM' }
        $round = $merged | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $round.AutoPatchingSettings.Enable | Should -BeTrue
        $round.ServerConfigurationsManagementSettings.SQLConnectivityUpdateSettings.Port | Should -Be 1433
        @($round.FeatureFlags).Count | Should -Be 2
        @($round.FeatureFlags.Name) | Should -Be @('OtherFeature', 'DatabaseWatcheronAzureVM')
        ($round.FeatureFlags | Where-Object Name -eq 'DatabaseWatcheronAzureVM').Enable | Should -BeTrue
    }

    It 'creates the flag list when the extension has no settings' {
        $merged = InModuleScope -ModuleName DbHubDemo { Merge-DemoSqlIaasFeatureFlag -Settings $null -Name 'DatabaseWatcheronAzureVM' }
        ($merged | ConvertTo-Json -Depth 5 -Compress) | Should -Be '{"FeatureFlags":[{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}'
    }

    It 'reads the plugin status from the instance view' {
        $status = InModuleScope -ModuleName DbHubDemo -Parameters @{ M = $script:running } { param($M) Get-DemoSqlVmMonitoringStatus -Extension ([pscustomobject]@{ instanceView = [pscustomobject]@{ statuses = @([pscustomobject]@{ message = $M }) } }) }
        $status.Found | Should -BeTrue
        $status.State | Should -Be 'Running'
        $status.MetricsUploadStatus | Should -Be 'OK'
    }

    It 'reports T1.SQLVM.MONITORING from the prerequisites and the plugin status' {
        $flag = '{"FeatureFlags":[{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}' | ConvertFrom-Json
        $convert = { param($State) InModuleScope -ModuleName DbHubDemo -Parameters @{ S = $State } { param($S) ConvertTo-DemoSqlVmMonitoringResult -State $S } }
        (& $convert (New-SqlVmState -Settings $flag -Message $script:running)).status | Should -Be 'Pass'
        $pending = & $convert (New-SqlVmState -Settings $flag -Message 'DatabaseMonitorArcPlugin: {"State":"NotRunning","MetricsUploadStatus":""}')
        $pending.status | Should -Be 'Warning'
        $pending.evidence.pending | Should -BeTrue
        (& $convert (New-SqlVmState -Settings $flag -Message 'DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"HTTP 403 Forbidden"}')).status | Should -Be 'Fail'
        (& $convert (New-SqlVmState -Settings $flag -Version '2.0.228.0' -Message $script:running)).status | Should -Be 'Fail'
        (& $convert (New-SqlVmState -Settings $flag -Identity 'None' -Message $script:running)).status | Should -Be 'Fail'
        (& $convert (New-SqlVmState -Settings $flag -ArcData 'NotRegistered' -Message $script:running)).status | Should -Be 'Fail'
        (& $convert (New-SqlVmState -Settings $null -Message '')).status | Should -Be 'Fail'
        (& $convert (New-SqlVmState -Settings $flag -Message $script:running -Instances 0)).status | Should -Be 'Warning'
    }

    It 'writes the merged settings with az vm extension set through a private file, then deletes it' {
        $script:existing = '{"AutoPatchingSettings":{"Enable":true},"FeatureFlags":[{"Name":"OtherFeature","Enable":true}]}' | ConvertFrom-Json
        $script:flagged = '{"AutoPatchingSettings":{"Enable":true},"FeatureFlags":[{"Name":"OtherFeature","Enable":true},{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}' | ConvertFrom-Json
        $script:reads = 0
        $script:written = $null
        $script:settingsPath = ''
        $script:setArguments = @()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
            $script:reads++
            if ($script:reads -eq 1) { New-SqlVmState -Settings $script:existing -Message '' } else { New-SqlVmState -Settings $script:flagged -Message $script:running }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith {
            $script:setArguments = $ArgumentList
            $script:settingsPath = $ArgumentList[[array]::IndexOf($ArgumentList, '--settings') + 1].Substring(1)
            $script:written = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
            [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
        }
        $result = Enable-DemoSqlVmMonitoring -Config $config
        $result.status | Should -Be 'Pass'
        $script:setArguments[0..2] | Should -Be @('vm', 'extension', 'set')
        $script:setArguments | Should -Contain 'Microsoft.SqlServer.Management'
        $script:setArguments[[array]::IndexOf($script:setArguments, '--name') + 1] | Should -Be 'SqlIaaSAgent'
        $script:setArguments[[array]::IndexOf($script:setArguments, '--extension-instance-name') + 1] | Should -Be 'SqlIaasExtension'
        $script:written.AutoPatchingSettings.Enable | Should -BeTrue
        @($script:written.FeatureFlags.Name) | Should -Be @('OtherFeature', 'DatabaseWatcheronAzureVM')
        Test-Path -LiteralPath $script:settingsPath | Should -BeFalse
        $result.evidence.actions[0] | Should -Match 'keeping 1 other setting\(s\) and 1 other feature flag\(s\)'
    }

    It 'writes nothing when the flag is already set, or when a prerequisite fails' {
        $script:flag = '{"FeatureFlags":[{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}' | ConvertFrom-Json
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith { New-SqlVmState -Settings $script:flag -Message $script:running }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { throw 'should not run' }
        (Enable-DemoSqlVmMonitoring -Config $config).status | Should -Be 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith { New-SqlVmState -Settings $null -Version '2.0.100.0' }
        (Enable-DemoSqlVmMonitoring -Config $config).status | Should -Be 'Fail'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -Times 0 -Exactly
    }

    It 'treats an extension that a template deployment is updating as a wait, not a failure (Phase 13)' {
        $script:flag = '{"FeatureFlags":[{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}' | ConvertFrom-Json
        $updating = New-SqlVmState -Settings $script:flag -Message $script:running
        $updating.Extension.provisioningState = 'Updating'
        $result = InModuleScope -ModuleName DbHubDemo -Parameters @{ S = $updating } { param($S) ConvertTo-DemoSqlVmMonitoringResult -State $S }
        $result.status | Should -Be 'Warning'
        $result.evidence.pending | Should -BeTrue
        $result.message | Should -Match 'Updating'

        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { throw 'should not run' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
            $script:reads++
            $state = New-SqlVmState -Settings $script:flag -Message $script:running
            if ($script:reads -le 2) { $state.Extension.provisioningState = 'Updating' }
            $state
        }
        (Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 5 -PollIntervalSeconds 60).status | Should -Be 'Pass'
        $script:reads | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly

        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
            $state = New-SqlVmState -Settings $script:flag -Message $script:running
            $state.Extension.provisioningState = 'Updating'
            $state
        }
        (Enable-DemoSqlVmMonitoring -Config $config).status | Should -Be 'Warning'
    }
}

Describe 'Phase 7 template and configuration' {
    BeforeAll {
        $mainBicep = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/main.bicep') -Raw
        $template = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json') -Raw
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    It 'declares t2Mode (Nested by default) and the optional onboarding role (off by default)' {
        $mainBicep | Should -Match "(?s)@allowed\(\[\s*'Nested'\s*'EvaluationOnlyAzureVm'\s*\]\)\s*param t2Mode string = 'Nested'"
        $mainBicep | Should -Match 'param assignArcOnboardingRole bool = false'
    }

    It 'creates the onboarding identity and its Azure Connected Machine Onboarding assignment only on request' {
        $parsed = $template | ConvertFrom-Json -AsHashtable
        $found = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push($parsed)
        while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if ($node -is [System.Collections.IDictionary]) {
                if ($node['type'] -in 'Microsoft.Authorization/roleAssignments', 'Microsoft.ManagedIdentity/userAssignedIdentities' -and [string]$node['condition'] -match 'assignArcOnboardingRole') { $found.Add($node) }
                foreach ($value in $node.Values) { $stack.Push($value) }
            }
            elseif ($node -is [System.Collections.IList]) {
                foreach ($value in $node) { $stack.Push($value) }
            }
        }
        $found.Count | Should -Be 2
        foreach ($resource in $found) {
            $resource['condition'] | Should -Be "[parameters('assignArcOnboardingRole')]"
        }
        $assignment = $found | Where-Object { $_['type'] -eq 'Microsoft.Authorization/roleAssignments' }
        $assignment['properties']['principalType'] | Should -Be 'ServicePrincipal'
        $assignment['properties']['roleDefinitionId'] | Should -Match 'connectedMachineOnboardingRoleId'
        $template | Should -Match ([regex]::Escape('"connectedMachineOnboardingRoleId": "b64e21ea-ac4e-4cdf-9dc9-5b892992bee7"'))
        $mainBicep | Should -Match ([regex]::Escape("assignArcOnboardingRole: assignArcOnboardingRole && t2Mode == 'Nested'"))
    }

    It 'deploys either archost01 or the evaluation-only arcsql01 VM' {
        $template | Should -Match ([regex]::Escape('"condition": "[variables(''isNestedT2'')]"'))
        $template | Should -Match ([regex]::Escape('"condition": "[not(variables(''isNestedT2''))]"'))
        $evaluationModule = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/modules/arcsql01-eval.bicep') -Raw
        $evaluationModule | Should -Match "evaluationOnly: 'true'"
        $evaluationModule | Should -Not -Match 'sqlVirtualMachines'
        $template | Should -Match ([regex]::Escape("createObject('evaluationOnly', 'true')"))
    }

    It 'passes t2Mode and the onboarding role from the configuration' {
        # Phase 8 requires the resolved T3 free-offer decision when t3FreeOffer is auto.
        $nested = (Get-DemoDeploymentParameter -Config (New-TestConfig -Override @{ assignRoles = $true }) -NetworkMode public -T3UseFreeLimit $false).parameters
        $nested['t2Mode'].value | Should -Be 'Nested'
        $nested['assignArcOnboardingRole'].value | Should -BeTrue
        $evaluation = (Get-DemoDeploymentParameter -Config (New-TestConfig -Override @{ assignRoles = $true; t2Mode = 'EvaluationOnlyAzureVm' }) -NetworkMode public -ExistingVmName 'arcsql01' -T3UseFreeLimit $false).parameters
        $evaluation['t2Mode'].value | Should -Be 'EvaluationOnlyAzureVm'
        $evaluation['assignArcOnboardingRole'].value | Should -BeFalse
        $evaluation['existingVmNames'].value | Should -Be @('arcsql01')
        (Get-DemoDeploymentParameter -Config (New-TestConfig -Override @{ assignRoles = $false }) -NetworkMode public -T3UseFreeLimit $false).parameters['assignArcOnboardingRole'].value | Should -BeFalse
    }

    It 'pins the Arc agent, the extensions, and the API versions the scripts call' {
        $versions.arc.agent.url | Should -Match '^https://'
        $versions.arc.agent.signerSubjectPattern | Should -Be 'O=Microsoft Corporation'
        $versions.arc.sqlExtension.name | Should -Be 'WindowsAgent.SqlServer'
        $versions.arc.sqlExtension.publisher | Should -Be 'Microsoft.AzureData'
        $versions.arc.sqlExtension.minimumVersion | Should -Be '1.1.2504.99'
        $versions.arc.monitoringApiVersion | Should -Be '2023-09-01-preview'
        $versions.arc.billing.minimumCoresPerOse | Should -Be 4
        $versions.sqlVm.minimumVersion | Should -Be '2.0.229.0'
        $versions.sqlVm.featureFlag | Should -Be 'DatabaseWatcheronAzureVM'
        foreach ($type in 'Microsoft.HybridCompute/machines', 'Microsoft.HybridCompute/machines/extensions', 'Microsoft.AzureArcData/sqlServerInstances') {
            $versions.apiVersions[$type] | Should -Match '^\d{4}-\d{2}-\d{2}(-preview)?$' -Because $type
        }
    }

    It 'implements configure-arc.ps1 and configure-monitoring.ps1 behind the subscription guard' {
        foreach ($name in 'configure-arc.ps1', 'configure-monitoring.ps1') {
            $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath "scripts/$name") -Raw
            $text | Should -Match '^#Requires -Version 7\.4'
            $text | Should -Not -Match 'not implemented yet'
            $text | Should -Match 'SupportsShouldProcess'
            $text | Should -Match 'Get-DemoExitCode'
            $text | Should -Match 'Export-DemoResult'
            $text | Should -Match 'WhatIf'
        }
        $monitoring = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/configure-monitoring.ps1') -Raw
        $monitoring | Should -Match 'Assert-DemoAzContext'
        # T3's monitoring setting is its extended property, which deploy.ps1's T3 stage sets and validate.ps1 checks.
        $monitoring | Should -Match "CheckId 'T3\.MONITORING'.+-Status 'Not selected'"
        $monitoring | Should -Match 'MS_EnablePerformanceMonitoringPreview'
        $monitoring | Should -Match 'T3\.PROPERTY'
        $monitoring | Should -Not -Match 'TODO\(phase9\)'
        Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/configure-arc.ps1') -Raw | Should -Match 'Remove-Item -LiteralPath ''Env:DBHUB_SQL_PRODUCT_KEY'''
    }
}

Describe 'Get-DemoArcHostIdentity' {
    BeforeEach {
        $script:vmShow = @{ ExitCode = 0; StdOut = 'null'; StdErr = '' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            ($ArgumentList -join ' ') | Should -Match '^vm show --resource-group rg-dbhub-demo --name archost01 --query identity\.userAssignedIdentities'
            [pscustomobject]$script:vmShow
        }
    }

    It 'returns the client ID of the onboarding identity when it''s attached to the host' {
        $script:vmShow.StdOut = '{"/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/rg-dbhub-demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ID-DBHUB-DEMO-ARC-ONBOARD":{"clientId":"aaaaaaaa-1111-2222-3333-444444444444","principalId":"bbbbbbbb-1111-2222-3333-444444444444"}}'
        $found = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoArcHostIdentity -Config $Config -Target (Get-DemoArcTarget -Config $Config) }
        $found.Found | Should -BeTrue
        $found.ClientId | Should -Be 'aaaaaaaa-1111-2222-3333-444444444444'
    }

    It 'reports why it isn''t used: no identity, another identity, or the host can''t be read' {
        $none = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoArcHostIdentity -Config $Config -Target (Get-DemoArcTarget -Config $Config) }
        $none.Found | Should -BeFalse
        $none.Reason | Should -Match 'assignRoles'
        $script:vmShow.StdOut = '{"/subscriptions/x/resourcegroups/rg-dbhub-demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-other":{"clientId":"aaaaaaaa-1111-2222-3333-444444444444"}}'
        (InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoArcHostIdentity -Config $Config -Target (Get-DemoArcTarget -Config $Config) }).Found | Should -BeFalse
        $script:vmShow = @{ ExitCode = 1; StdOut = ''; StdErr = 'ResourceNotFound' }
        $failed = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoArcHostIdentity -Config $Config -Target (Get-DemoArcTarget -Config $Config) }
        $failed.Found | Should -BeFalse
        $failed.Reason | Should -Match 'couldn''t be read'
    }
}