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
        param([string] $Edition = 'Standard', [string] $LicenseType = 'PAYG', [bool] $Monitoring = $true, [string] $Container = $script:machineId, [string] $Name = 'arcsql01', [int] $Cores = 2, [AllowNull()] [object] $Assessment = $null)
        $instance = [pscustomobject]@{
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
        if ($null -ne $Assessment) {
            $instance.properties | Add-Member -NotePropertyName 'migration' -NotePropertyValue ([pscustomobject]@{ assessment = $Assessment })
        }
        return $instance
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
        # Names Azure keeps marked for deletion (2026-11-13 live finding): listed as Deleting, a delete doesn't remove them,
        # and a PUT of one fails with OperationNotAllowed.
        $script:stuck = [System.Collections.Generic.HashSet[string]]::new()
        $script:extraListed = 0
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
            if ($method -eq 'get' -and -not $name) {
                # The VM's Run Commands (List By Virtual Machine).
                $listed = @(foreach ($key in $script:runCommands.Keys) { @{ name = $key; properties = @{ provisioningState = 'Succeeded' } } }) + @(foreach ($key in $script:stuck) { @{ name = $key; properties = @{ provisioningState = 'Deleting' } } }) + @(for ($i = 1; $i -le $script:extraListed; $i++) { @{ name = ('Other-{0:00}' -f $i); properties = @{ provisioningState = 'Succeeded' } } })
                return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $listed } | ConvertTo-Json -Depth 6); StdErr = '' }
            }
            switch ($method) {
                'put' {
                    $call.BodyPath = $ArgumentList[[array]::IndexOf($ArgumentList, '--body') + 1].Substring(1)
                    $call.BodyExisted = Test-Path -LiteralPath $call.BodyPath
                    $call.Body = Get-Content -LiteralPath $call.BodyPath -Raw | ConvertFrom-Json -AsHashtable
                    if ($script:stuck.Contains($name)) {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('ERROR: ({{"error":{{"code":"OperationNotAllowed","message":"Operation ''PUT Extension'' is not allowed on VM extension ''{0}'' since it is marked for deletion. You can only retry the Delete operation (or wait for an ongoing one to complete)."}}}})' -f $name) }
                    }
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
                    if ($script:stuck.Contains($name)) {
                        return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ name = $name; properties = @{ provisioningState = 'Deleting'; instanceView = @{ executionState = 'Succeeded'; exitCode = 0 } } } | ConvertTo-Json -Depth 5); StdErr = '' }
                    }
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

    It 'leaves the Run Command for the next run instead of waiting to delete it when deploy.ps1 was stopped (Phase 28 live finding)' {
        # A stop (Ctrl+C) runs this finally block, and the delete's wait would hold the stop for minutes.
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoRunCommand -MockWith { throw 'The pipeline has been stopped.' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoRunCancelled -MockWith { $true }
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -ProtectedParameter @{ AccessToken = $script:fakeToken } -PollIntervalSeconds 0 } | Should -Throw '*stopped*'
        $methods = @($script:calls.Method)
        [array]::LastIndexOf($methods, 'delete') | Should -BeLessThan ([array]::IndexOf($methods, 'put')) -Because 'only the leftover delete before the PUT ran'
        $script:runCommands.Keys | Should -Contain 'DbHubDemo-HealthRead'
        $put = @($script:calls | Where-Object Method -eq 'put')
        Test-Path -LiteralPath (Split-Path -Path $put[0].BodyPath -Parent) | Should -BeFalse -Because 'the private body still goes'
        ($script:logs -join ' ') | Should -Match 'left for the next run'
    }

    It 'runs under a fresh name when Azure keeps the name in Deleting after the leftover wait, and reports it once (2026-11-13 live finding)' {
        InModuleScope -ModuleName DbHubDemo { $script:DemoRunCommandStuck.Clear(); $script:DemoRunCommandStuckName.Clear() }
        $null = $script:stuck.Add('DbHubDemo-HealthRead')
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0 -LeftoverWaitSeconds 0

        $result.Succeeded | Should -BeTrue
        $result.RunCommandName | Should -Be 'DbHubDemo-HealthRead'
        $result.UsedName | Should -Match '^DbHubDemo-HealthRead-\d{14}$'
        @($script:calls | Where-Object Method -eq 'put' | ForEach-Object Name) | Should -Be @($result.UsedName) -Because 'no PUT goes to a name Azure keeps marked for deletion'
        $script:runCommands.Count | Should -Be 0 -Because 'the fresh one is deleted afterward, as usual'
        ($script:logs -join ' ') | Should -Match ('Azure still lists DbHubDemo-HealthRead after 0s .*so it runs as {0} instead of waiting' -f [regex]::Escape($result.UsedName))
        $stuck = @(InModuleScope -ModuleName DbHubDemo { Get-DemoRunCommandStuckResult -Clear })
        $stuck.Count | Should -Be 1
        $stuck[0].checkId | Should -Be 'DEPLOY.RUNCOMMAND.STUCK_ARCHOST01'
        $stuck[0].status | Should -Be 'Warning'
        $stuck[0].target | Should -Be 'T2'
        $stuck[0].evidence.freshNames | Should -Contain $result.UsedName
        $stuck[0].message | Should -Match 'Azure kept DbHubDemo-HealthRead on archost01 in Deleting'
        @(InModuleScope -ModuleName DbHubDemo { Get-DemoRunCommandStuckResult }).Count | Should -Be 0 -Because '-Clear reports each once'
    }

    It 'asks earlier fresh copies and finished chunks to go without waiting, and makes no fresh name when the VM is close to Azure''s limit of 25' {
        InModuleScope -ModuleName DbHubDemo { $script:DemoRunCommandStuck.Clear(); $script:DemoRunCommandStuckName.Clear() }
        $null = $script:stuck.Add('DbHubDemo-HealthRead')
        $null = $script:stuck.Add('DbHubDemo-HealthRead-20261113200000')
        # A chunk left from a finished transfer (live: 9 of the 20 on the T2 host).
        $script:runCommands['DbHubDemo-Chunk-abcdef123456-001'] = $true
        $result = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0 -LeftoverWaitSeconds 0
        $result.Succeeded | Should -BeTrue
        @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq 'DbHubDemo-HealthRead-20261113200000' }).Count | Should -Be 1
        @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq 'DbHubDemo-Chunk-abcdef123456-001' }).Count | Should -Be 1
        InModuleScope -ModuleName DbHubDemo { $script:DemoRunCommandStuck.Clear() }

        $script:calls.Clear()
        $script:extraListed = 22
        { Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0 -LeftoverWaitSeconds 0 } | Should -Throw '*already has 24 Run Commands (2 being deleted), close to Azure''s limit of 25*'
        @($script:calls | Where-Object Method -eq 'put').Count | Should -Be 0
        @($script:calls | Where-Object { $_.Method -eq 'delete' -and $_.Name -eq 'DbHubDemo-HealthRead' }).Count | Should -Be 2 -Because 'the delete goes again, without a second wait'
        @(InModuleScope -ModuleName DbHubDemo { Get-DemoRunCommandStuckResult }).Count | Should -Be 0
    }

    It 'waits only 30 seconds for a name Azure kept in Deleting earlier in the process, and never for a fresh name''s own delete (live, 2026-11-13)' {
        InModuleScope -ModuleName DbHubDemo { $script:DemoRunCommandStuck.Clear(); $script:DemoRunCommandStuckName.Clear() }
        $null = $script:stuck.Add('DbHubDemo-HealthRead')
        $script:waits = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoRunCommand -MockWith {
            $name = if ($Url -match '/runCommands/([^?]+)\?') { $Matches[1] } else { '' }
            $script:waits.Add(('{0} wait={1} nowait={2}' -f $name, $PesterBoundParameters['WaitSeconds'], [bool]$PesterBoundParameters['NoWait']))
            if ($script:stuck.Contains($name)) {
                return $false
            }
            $script:runCommands.Remove($name)
            return $true
        }
        $first = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0
        $firstWaits = @($script:waits)
        $script:waits.Clear()
        $second = Invoke-DemoVmRunCommand -Config $config -VmName 'archost01' -RunCommandName 'DbHubDemo-HealthRead' -Script 'Write-Output 1' -PollIntervalSeconds 0

        $first.Succeeded | Should -BeTrue
        $second.Succeeded | Should -BeTrue
        $firstWaits[0] | Should -Be 'DbHubDemo-HealthRead wait=300 nowait=False' -Because 'the first time, the whole leftover wait'
        $firstWaits[-1] | Should -BeLike ('{0} wait=* nowait=True' -f $first.UsedName) -Because 'a fresh name''s own delete isn''t waited for'
        $script:waits[0] | Should -Be 'DbHubDemo-HealthRead wait=30 nowait=False' -Because 'the second time, it was stuck already'
        $second.UsedName | Should -Match '^DbHubDemo-HealthRead-\d{14}$'
        InModuleScope -ModuleName DbHubDemo { $script:DemoRunCommandStuck.Clear(); $script:DemoRunCommandStuckName.Clear() }
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
        # The guest's part when a test sets it; the host's otherwise.
        $script:sweepGuest = $null
        # The sweep's other output (lock, guestRecovery) when a test sets it (2026-11-19).
        $script:sweepExtra = [ordered]@{}
        # The resource group's record that a sweep after onboarding is owed (DbHubArcSweepUtc): none unless a test sets it.
        $script:sweepOwed = ''
        $script:owedWrites = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcSweepOwed -MockWith { $script:sweepOwed }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoArcSweepOwed -MockWith { $script:owedWrites.Add([string]$Value); $script:sequence.Add($(if ($Value) { 'owed' } else { 'owed-cleared' })); $true }
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
            $output = if ($RunCommandName -eq 'DbHubDemo-ArcProbe') {
                $script:probe | ConvertTo-Json -Compress
            }
            elseif ($RunCommandName -eq 'DbHubDemo-SignInData') {
                $guestPart = if ($null -ne $script:sweepGuest) { $script:sweepGuest } else { $script:sweepPart }
                $sweepOut = [ordered]@{ action = 'Clean'; succeeded = $true; pass = [bool]$script:sweepPart.pass -and [bool]$guestPart.pass; local = $script:sweepPart; guest = $guestPart }
                foreach ($key in $script:sweepExtra.Keys) {
                    $sweepOut[$key] = $script:sweepExtra[$key]
                }
                $sweepOut | ConvertTo-Json -Compress -Depth 6
            }
            else {
                '{"succeeded":true,"outcome":"Onboarded","resourceId":"' + $script:machineId + '"}'
            }
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

    It 'with -Force, waits for the host''s pass over a new bootstrap generation before its probe and marker go into the guest (#65 follow-up)' {
        # A golden copy after an update: the loader just started a generation whose pass hasn't reported yet.
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:machine = New-TestMachine
        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith {
            $script:reads++
            $script:sequence.Add('health')
            if ($script:reads -lt 3) { [pscustomobject]@{ state = 'InProgress'; currentStep = 'GuestSignInCleanup'; generationPending = $true } } else { [pscustomobject]@{ state = 'Ready'; message = 'Every step is in the desired state.' } }
        }
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.evidence.decision | Should -Be 'AlreadyConnected'
        $result.evidence.hostState | Should -Be 'Ready'
        $result.evidence.passWaitSeconds | Should -Not -BeNullOrEmpty
        $result.evidence.PSObject.Properties['passPending'] | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 3 -Exactly
        $script:sequence.IndexOf('DbHubDemo-ArcProbe') | Should -BeGreaterThan $script:sequence.LastIndexOf('health')
    }

    It 'with -Force, goes on waiting while the pass converges a step after its generation reported, and probes only once it''s Ready (#65 follow-up review)' {
        # An existing golden copy keeps its Arc marker, so after an update its pass's first step that converges is WorkloadRunner,
        # whose install stops the workload in the guest over PowerShell Direct: health.json then reports InProgress with the new
        # generation, so generationPending is gone, but the pass isn't over.
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:machine = New-TestMachine
        $script:reads = 0
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith {
            $script:reads++
            $script:sequence.Add(('health {0}' -f $script:reads))
            if ($script:reads -eq 1) { [pscustomobject]@{ state = 'InProgress'; currentStep = 'GuestSignInCleanup'; generationPending = $true } }
            elseif ($script:reads -le 3) { [pscustomobject]@{ state = 'InProgress'; currentStep = 'WorkloadRunner'; message = 'Step WorkloadRunner is converging (attempt 1 of 3).' } }
            else { [pscustomobject]@{ state = 'Ready'; message = 'Every step is in the desired state.' } }
        }
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.evidence.hostState | Should -Be 'Ready'
        $result.evidence.PSObject.Properties['passPending'] | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 4 -Exactly
        $script:sequence.IndexOf('DbHubDemo-ArcProbe') | Should -BeGreaterThan $script:sequence.IndexOf('health 4')
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'runs its bootstrap pass \(InProgress, step WorkloadRunner\); onboarding waits until the pass ends' }
    }

    It 'with -Force, also waits through a restart and a host with no report yet, and not at all where a pass ends (#65 follow-up review)' {
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:machine = New-TestMachine
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        $script:passReads = [System.Collections.Generic.Queue[object]]::new()
        foreach ($state in 'RebootPending', 'NotStarted', 'Ready') {
            $script:passReads.Enqueue([pscustomobject]@{ state = $state; currentStep = 'ConfigureSql' })
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { $script:sequence.Add('health'); $script:passReads.Dequeue() }
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PollIntervalSeconds 1
        $result.evidence.hostState | Should -Be 'Ready'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 3 -Exactly
        $script:sequence.IndexOf('DbHubDemo-ArcProbe') | Should -BeGreaterThan $script:sequence.LastIndexOf('health')
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'runs its bootstrap pass \(RebootPending, step ConfigureSql\)' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'hasn''t reported a bootstrap pass yet \(NotStarted\)' }
        # Where a pass ends, there's nothing to wait for: one read each, and no wait in the evidence.
        foreach ($state in 'WaitingForArcOnboarding', 'ManualActionRequired', 'Failed', 'WaitingForProductKey', 'WaitingForGuestSql') {
            $script:passReads.Enqueue([pscustomobject]@{ state = $state; currentStep = 'WorkloadRunner' })
            $ended = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PollIntervalSeconds 1
            $ended.evidence.hostState | Should -Be $state
            $ended.evidence.PSObject.Properties['passWaitSeconds'] | Should -BeNullOrEmpty -Because $state
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 8 -Exactly
    }

    It 'with -Force, goes ahead once PassWaitMinutes is over, and says the pass hadn''t ended (#65 follow-up)' {
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:machine = New-TestMachine
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith { $script:passHealth }
        foreach ($read in @([pscustomobject]@{ state = 'InProgress'; generationPending = $true }, [pscustomobject]@{ state = 'InProgress'; currentStep = 'WorkloadRunner' })) {
            $script:passHealth = $read
            $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PassWaitMinutes 0 -PollIntervalSeconds 1
            $result.status | Should -Be 'Pass'
            $result.evidence.passPending | Should -BeTrue
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -Times 2 -Exactly
        @($script:runs | Where-Object { $_.Name -eq 'DbHubDemo-ArcProbe' }).Count | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'still checks every step again for its new bootstrap generation \(starting\) after 0 minutes' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'still runs its bootstrap pass \(InProgress, step WorkloadRunner\) after 0 minutes' }
    }

    It 'gives the host the run''s recovery key, and keeps a guest restart the probe made in the evidence (issue #65)' {
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:probe.guestRecovery = [ordered]@{ action = 'Restart'; restarted = $true; recovered = $true; seconds = 95; restartUtc = '2026-11-18T18:52:10.0000000Z'; stoppedBy = 'Shutdown'; by = 'Arc onboarding'; key = 'deploy-aaaaaaaaaaaa'; reason = 'The Hyper-V socket target process has ended.' }
        $script:machine = New-TestMachine
        InModuleScope DbHubDemo { Set-DemoRunRecoveryKey -Key 'deploy-aaaaaaaaaaaa' }
        try {
            $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        }
        finally {
            InModuleScope DbHubDemo { Set-DemoRunRecoveryKey -Key '' }
        }
        $result.evidence.guestRecovery.restarted | Should -BeTrue
        $result.evidence.guestRecovery.restartUtc | Should -Not -BeNullOrEmpty
        @($script:runs | Where-Object { $_.Name -in 'DbHubDemo-ArcProbe', 'DbHubDemo-ArcOnboard' }).Count | Should -Be 2
        foreach ($run in @($script:runs | Where-Object { $_.Name -in 'DbHubDemo-ArcProbe', 'DbHubDemo-ArcOnboard' })) {
            $run.Parameter['RecoveryKey'] | Should -Be 'deploy-aaaaaaaaaaaa' -Because $run.Name
        }
    }

    It 'outside a deploy.ps1 run, gives its probe, its onboarding, and its sign-in data check one key of its own, so they share one guest restart (review of e617f34)' {
        # configure-arc.ps1 sets no run key: the host's own hourly keys differ by caller (arc- for the probe and the onboarding,
        # signin- for the check), so the probe and the check could each restart arcsql01 in one call.
        $script:machine = New-TestMachine -Status 'Disconnected'
        $first = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $first.status | Should -Be 'Pass'
        @($script:runs | ForEach-Object { $_.Name }) | Should -Be @('DbHubDemo-ArcProbe', 'DbHubDemo-ArcOnboard', 'DbHubDemo-SignInData')
        $key = [string]$script:runs[0].Parameter['RecoveryKey']
        $key | Should -Match '^arc-[0-9a-f]{12}$'
        foreach ($run in $script:runs) {
            $run.Parameter['RecoveryKey'] | Should -Be $key -Because $run.Name
        }
        # Each call has its own, as each deploy.ps1 run does.
        $script:runs.Clear()
        $null = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $script:runs[0].Parameter['RecoveryKey'] | Should -Match '^arc-[0-9a-f]{12}$'
        $script:runs[0].Parameter['RecoveryKey'] | Should -Not -Be $key
    }

    It 'rewrites the marker without a token when the guest is already Connected' {
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:machine = New-TestMachine
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.evidence.decision | Should -Be 'AlreadyConnected'
        # The probe's agent keys, as a flat list (not an array inside an array).
        , $result.evidence.agentKeys | Should -BeOfType [object[]]
        $result.evidence.agentKeys.Count | Should -Be 0
        $script:runs[1].Parameter['Action'] | Should -Be 'WriteMarker'
        $script:runs[1].Protected.Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoArcStaleResource -Times 0 -Exactly

        $script:probe.agentKeys = @('status', 'resourceName')
        $script:runs.Clear()
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.evidence.agentKeys.Count | Should -Be 2
        $result.evidence.agentKeys[0] | Should -Be 'status'
    }

    It 'deletes a stale machine first, then onboards with the token only as a protected parameter' {
        $script:machine = New-TestMachine -Status 'Disconnected'
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $script:sequence | Should -Be @('DbHubDemo-ArcProbe', 'cleanup', 'identity', 'token', 'owed', 'DbHubDemo-ArcOnboard', 'DbHubDemo-SignInData', 'owed-cleared') -Because 'the sweep is recorded as owed before the token goes to the host, and cleared once it passed (2026-11-19)'
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

    It 'passes with a note when the sweep after onboarding deleted only the LSA secret Azure''s provisioning leaves on the host (live finding, 2026-11-06)' {
        $script:machine = New-TestMachine -Status 'Disconnected'
        $script:sweepPart.found['loneSecret'] = 1
        $script:sweepPart['actions'] = [ordered]@{ redacted = 0; deleted = 0; failed = 0; caches = 0; broker = 0; logsCleared = @(); logsNotCleared = @(); autologon = 0; loneSecret = 1 }
        $script:sweepGuest = [ordered]@{ computer = 'VM'; reachable = $true; pass = $true; found = [ordered]@{ user = 0; other = 0; app = 0; files = 0; archives = 0; caches = 0; unverified = 0; logUser = 0; logApp = 0 }; remaining = [ordered]@{ user = 0; other = 0; app = 0; files = 0; archives = 0; caches = 0; unverified = 0; logUser = 0; logApp = 0 }; eventLogs = @(); found_at = @(); left_at = @(); seconds = 9 }
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Pass'
        $result.message | Should -Be 'arcsql01 is onboarded and Connected; the host continues its bootstrap. The cleanup deleted the LSA secret DefaultPassword that Azure''s provisioning leaves on archost01; automatic sign-in was off.'
        $result.evidence.signInData.status | Should -Be 'Pass'
        $result.evidence.signInData.note | Should -Match 'on archost01;'
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

    It 'sweeps only after the host''s own bootstrap pass (its lock), with the run''s recovery key, and reports the guest restart that cleared the sweep''s broken channel (2026-11-19, dbhubfn)' {
        $script:sweepExtra['lock'] = [ordered]@{ minutes = 30; seconds = 312; timedOut = $false }
        $script:sweepExtra['guestRecovery'] = [ordered]@{ action = 'Restart'; restarted = $true; recovered = $true; ranAgain = $true; seconds = 95; atUtc = '2026-11-19T19:44:02.0000000Z'; restartUtc = '2026-11-19T19:44:31.0000000Z'; stoppedBy = 'Shutdown'; by = 'the sign-in data cleanup'; key = 'deploy-bbbbbbbbbbbb'; reason = 'The Hyper-V socket target process has ended. (PSSessionStateBroken)'; message = 'arcsql01 was restarted once (a clean shutdown, 95 s) and answers over PowerShell Direct again.'; guest = 'arcsql01' }
        InModuleScope DbHubDemo { Set-DemoRunRecoveryKey -Key 'deploy-bbbbbbbbbbbb' }
        try {
            $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        }
        finally {
            InModuleScope DbHubDemo { Set-DemoRunRecoveryKey -Key '' }
        }
        $result.status | Should -Be 'Pass'
        $sweep = @($script:runs | Where-Object Name -EQ 'DbHubDemo-SignInData')[0]
        $sweep.Parameter['ResidueScope'] | Should -Be 'Both'
        $sweep.Parameter['ResidueLockMinutes'] | Should -Be '30' -Because 'the host''s own sign-in cleanup must never sweep the guest at the same time'
        $sweep.Parameter['RecoveryKey'] | Should -Be 'deploy-bbbbbbbbbbbb'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -match 'waits for archost01''s own bootstrap pass first \(at most 30 minutes\), so the two never sweep arcsql01 at the same time' }
        $result.evidence.signInData.lockSeconds | Should -Be 312
        $result.evidence.signInData.guestRecovery.restarted | Should -BeTrue
        # deploy.ps1 reports it once, as it does the onboarding's own restart (issue #65).
        $restarts = @(InModuleScope DbHubDemo -Parameters @{ R = $result } { param($R) Get-DemoGuestRecoveryRunResult -Result @($R) -CheckPrefix 'DEPLOY' })
        $restarts.Count | Should -Be 1
        $restarts[0].checkId | Should -Be 'DEPLOY.T2.GUESTRESTART'
        $restarts[0].status | Should -Be 'Warning'
        $restarts[0].message | Should -Match 'the sign-in data cleanup restarted arcsql01 once for this run'
        $restarts[0].message | Should -Match 'Hyper-V socket target process has ended'
    }

    It 'fails closed with PowerShell Direct''s own error when the guest still can''t be reached, keeps the record, and NOT DONE''s one next step is ./scripts/deploy.ps1 (2026-11-19, dbhubfn)' {
        $script:sweepGuest = [ordered]@{ reachable = $false; state = 'Running'; pass = $false; error = 'The Hyper-V socket target process has ended. (PSSessionStateBroken)' }
        $script:sweepExtra['guestRecovery'] = [ordered]@{ action = 'Restart'; restarted = $true; recovered = $false; tries = 4; ranAgain = $true; seconds = 140; atUtc = '2026-11-19T19:44:02.0000000Z'; restartUtc = '2026-11-19T19:44:31.0000000Z'; stoppedBy = 'Shutdown'; by = 'the sign-in data cleanup'; key = 'deploy-bbbbbbbbbbbb'; reason = 'The Hyper-V socket target process has ended. (PSSessionStateBroken)'; message = 'arcsql01 was restarted once (a clean shutdown, 140 s) and answers over PowerShell Direct again.'; guest = 'arcsql01' }
        $failed = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'traces couldn''t be removed and verified'
        $failed.message | Should -Match 'arcsql01 \(guest\) couldn''t be reached \(Running: The Hyper-V socket target process has ended'
        $failed.message | Should -Match 'It ran 3 more times, and each failed too, after archost01 restarted arcsql01 once for this run'
        $failed.evidence.signInData.error | Should -Match 'PSSessionStateBroken'
        $failed.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again: it runs the sign-in data cleanup after the Arc onboarding and its check again by itself'
        # Owed before the onboarding, and again after the failed sweep; never cleared.
        $script:owedWrites.Count | Should -Be 2
        $script:owedWrites | Should -Not -Contain ''
        # Live, NOT DONE said to run check-sign-in-data.ps1 until it passes, then configure-arc.ps1, then deploy.ps1 (F8).
        $state = [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Bootstraps'; TrackT4 = 'Telemetry'; TrackFabric = 'Fabric'; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ R = $failed; S = $state; C = (New-TestConfig) } { param($R, $S, $C) Get-DemoDeploymentOutcome -Result @($R) -State $S -Config $C -Command './scripts/deploy.ps1' }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
        $outcome.Next | Should -Match '^Run \./scripts/deploy\.ps1 again: '
        $outcome.Next | Should -Not -Match 'check-sign-in-data|configure-arc|Then run'
    }

    It 'fails, and configuration waits, when the guest still doesn''t answer after the host''s pass and the probe''s tries; NOT DONE leads with it, and its one next step is ./scripts/deploy.ps1 (2026-11-19, dbhubfx)' {
        $script:probe.guestReachable = $false
        $script:probe.guestError = 'An error has occurred which Windows PowerShell cannot handle. A remote session might have ended.'
        $script:probe.probeTries = 4
        $script:probe.lockSeconds = 12
        $result = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $result.status | Should -Be 'Fail'
        $result.evidence.decision | Should -Be 'GuestUnreachable'
        $result.message | Should -Be 'arcsql01 didn''t answer over PowerShell Direct on archost01 after 4 tries: An error has occurred which Windows PowerShell cannot handle. A remote session might have ended. It isn''t onboarded to Azure Arc, so its configuration waits for it.'
        $result.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again: it probes arcsql01 again'
        ('{0} {1}' -f $result.message, $result.remediation) | Should -Not -Match 'configure-arc'
        $result.evidence.guestError | Should -Match 'remote session might have ended'
        $result.evidence.probeTries | Should -Be 4
        $result.evidence.lockSeconds | Should -Be 12
        @($script:runs | ForEach-Object { $_.Name }) | Should -Be @('DbHubDemo-ArcProbe')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly
        # The probe waits for the host's pass (its lock, at most 30 minutes) and tries again, so its Run Command has room for both.
        $script:runs[0].Parameter['LockMinutes'] | Should -Be '30'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $RunCommandName -eq 'DbHubDemo-ArcProbe' -and $TimeoutSeconds -gt (1500 + 30 * 60) }

        # Live, a Warning let configuration go on, and NOT DONE led with its consequence, T2.ARC.SQLEXTENSION, and said to run
        # configure-arc.ps1, then deploy.ps1 (F12, F13). A Fail skips configuration (Invoke-DemoArcConfiguration), so it leads.
        $results = @(
            $result
            New-DemoResult -CheckId 'T2.ARC.CONFIGURATION' -Area 't2' -Target 'T2' -Status 'Not selected' -Message 'Configuring SQL Server enabled by Azure Arc was skipped because onboarding failed.'
            New-DemoResult -CheckId 'DEPLOY.TRACK.T2' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'Track T2: Fail; finished steps: Restore, Artifacts, Bootstraps.' -Remediation 'Run ./scripts/deploy.ps1 again: it continues the unfinished track(s).'
            New-DemoResult -CheckId 'HUB.ESTATE.T2' -Area 'hub' -Target 'T2' -Status 'Fail' -Message 'The Arc machine arcsql01 isn''t in Azure Resource Graph in rg-dbhub-demo, so T2 isn''t onboarded to Azure Arc.' -Remediation 'Onboard the guest with scripts/configure-arc.ps1 once the host reports WaitingForArcOnboarding.'
        )
        $state = [pscustomobject]@{ Stage = 'Validation'; TrackT1 = 'Telemetry'; TrackT2 = 'Bootstraps'; TrackT4 = 'Telemetry'; TrackFabric = 'Fabric'; T4Sku = ''; GuidedStopUtc = ''; HostPasswordUtc = '' }
        $outcome = InModuleScope DbHubDemo -Parameters @{ R = $results; S = $state; C = (New-TestConfig) } { param($R, $S, $C) Get-DemoDeploymentOutcome -Result $R -State $S -Config $C -Command './scripts/deploy.ps1' }
        $outcome.Kind | Should -Be 'NotDone'
        $outcome.Reason | Should -Match '^T2\.ARC\.ONBOARDING: arcsql01 didn''t answer over PowerShell Direct'
        $outcome.NextCommand | Should -Be './scripts/deploy.ps1'
        $outcome.Next | Should -Match '^Run \./scripts/deploy\.ps1 again: '
        $outcome.Next | Should -Not -Match 'configure-arc|Then run'

        # With an Azure machine that's already Connected (an update), configuration, which goes through Azure, goes on.
        $script:machine = New-TestMachine
        $connected = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PollIntervalSeconds 1
        $connected.status | Should -Be 'Warning'
        $connected.message | Should -Match 'Its Azure Arc machine is Connected, so its configuration goes on\.$'
        $connected.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again'
    }

    It 'gives the onboarding Run Command room for the host''s pass and the tries, and a fix that''s a plain rerun when the host''s pass held its lock (2026-11-19, dbhubfx)' {
        $script:machine = $null
        $null = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $onboard = @($script:runs | Where-Object Name -EQ 'DbHubDemo-ArcOnboard')
        $onboard.Count | Should -Be 1
        $onboard[0].Parameter['LockMinutes'] | Should -Be '30'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -Times 1 -Exactly -ParameterFilter { $RunCommandName -eq 'DbHubDemo-ArcOnboard' -and $TimeoutSeconds -gt (1800 + 30 * 60) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            $RunCommandName = $PesterBoundParameters['RunCommandName']
            if ($RunCommandName -eq 'DbHubDemo-ArcProbe') {
                return [pscustomobject]@{ Succeeded = $true; ExecutionState = 'Succeeded'; ExitCode = 0; Output = ($script:probe | ConvertTo-Json -Compress); Error = '' }
            }
            [pscustomobject]@{ Succeeded = $false; ExecutionState = 'Failed'; ExitCode = 1; Output = ''; Error = 'DbHubDemo Arc Onboard failed: The host''s own bootstrap pass held its lock (bootstrap.lock) for 1800 seconds, so Arc Onboard didn''t run beside it; nothing was changed (fail closed).' }
        }
        $failed = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match 'bootstrap\.lock'
        $failed.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again: it onboards arcsql01 after archost01''s own bootstrap pass'
        # The probe that the lock stopped: it says the probe failed, and why, with the same one fix.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmRunCommand -MockWith {
            [pscustomobject]@{ Succeeded = $false; ExecutionState = 'Failed'; ExitCode = 1; Output = ''; Error = 'DbHubDemo Arc Probe failed: The host''s own bootstrap pass held its lock (bootstrap.lock) for 1800 seconds, so Arc Probe didn''t run beside it; nothing was changed (fail closed).' }
        }
        $probeFailed = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $probeFailed.status | Should -Be 'Fail'
        $probeFailed.message | Should -Match '^The probe of arcsql01 on archost01 failed: DbHubDemo Arc Probe failed: The host''s own bootstrap pass held its lock \(bootstrap\.lock\)'
        $probeFailed.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again'
    }

    It 'sweeps again by itself on a later run while the record says it''s owed, whatever the host''s state, and clears it once it passes (2026-11-19, dbhubfn)' {
        $script:sweepOwed = '2026-11-19T19:37:17Z'
        # A Ready host, where onboarding ran nothing before.
        $script:hostState = 'Ready'
        $ready = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $ready.status | Should -Be 'Pass'
        $ready.message | Should -Match 'is Ready, so it isn''t waiting for onboarding'
        $ready.message | Should -Match 'which didn''t pass then, passed now: Sign-in data was removed from archost01 and arcsql01 \(guest\), and none is left'
        @($script:runs | ForEach-Object { $_.Name }) | Should -Be @('DbHubDemo-SignInData')
        $script:runs[0].Parameter['ResidueScope'] | Should -Be 'Both'
        $script:runs[0].Parameter['ResidueLockMinutes'] | Should -Be '30'
        $script:owedWrites | Should -Be @('')
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArmAccessToken -Times 0 -Exactly

        # Past onboarding and already Connected, while the host's pass still runs.
        $script:hostState = 'InProgress'
        $script:machine = New-TestMachine
        $script:runs.Clear()
        $script:owedWrites.Clear()
        $connected = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $connected.status | Should -Be 'Pass'
        $connected.message | Should -Match 'already Connected.*passed now'
        @($script:runs | ForEach-Object { $_.Name }) | Should -Be @('DbHubDemo-SignInData')
        $script:owedWrites | Should -Be @('')

        # -Force on a guest that's Connected (a golden copy): after the marker.
        $script:hostState = 'WaitingForArcOnboarding'
        $script:probe.agentStatus = 'Connected'
        $script:probe.agentResourceName = 'arcsql01'
        $script:probe.agentResourceGroup = 'rg-dbhub-demo'
        $script:runs.Clear()
        $script:owedWrites.Clear()
        $marker = Invoke-DemoArcOnboarding -Config (New-TestConfig) -Force -PollIntervalSeconds 1
        $marker.status | Should -Be 'Pass'
        $marker.message | Should -Match 'the marker was written again.*passed now'
        @($script:runs | ForEach-Object { $_.Name }) | Should -Be @('DbHubDemo-ArcProbe', 'DbHubDemo-ArcOnboard', 'DbHubDemo-SignInData')
        $script:runs[1].Parameter['Action'] | Should -Be 'WriteMarker'
        $script:owedWrites | Should -Be @('')

        # A sweep that fails again keeps the record, with the same time, and the same one fix.
        $script:hostState = 'Ready'
        $script:sweepGuest = [ordered]@{ reachable = $false; state = 'Running'; pass = $false; error = 'Cannot find path ''C:\Windows\Temp\x.log'' because it does not exist. (PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand)' }
        $script:owedWrites.Clear()
        $again = Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1
        $again.status | Should -Be 'Fail'
        $again.message | Should -Match 'PathNotFound'
        $again.remediation | Should -Match '^Run \./scripts/deploy\.ps1 again'
        $script:owedWrites | Should -Be @('2026-11-19T19:37:17Z')

        # Without the record, a Ready host runs nothing, as before.
        $script:sweepOwed = ''
        $script:runs.Clear()
        (Invoke-DemoArcOnboarding -Config (New-TestConfig) -PollIntervalSeconds 1).message | Should -Not -Match 'passed now'
        $script:runs.Count | Should -Be 0
    }

    It 'in the evaluation-only mode, never reads or writes the record of an owed check, nor runs one later (review of e617f34)' {
        # That VM turns its Azure guest agent off at least 15 minutes after its Arc marker, so Run Command never reaches it again
        # and configure-arc.ps1 reads it as Ready from its Arc machine: an owed check there failed on every later run.
        $evaluation = New-TestConfig -Override @{ t2Mode = 'EvaluationOnlyAzureVm' }
        $script:sweepOwed = 'unknown'
        $ready = Invoke-DemoArcOnboarding -Config $evaluation -Health ([pscustomobject]@{ state = 'Ready'; message = 'Read from Azure Arc; the Azure guest agent is disabled.' }) -PollIntervalSeconds 1
        $ready.status | Should -Be 'Pass'
        $ready.message | Should -Not -Match 'passed now'
        $script:runs.Count | Should -Be 0 -Because 'no Run Command reaches the VM once its agent is off'
        # Already Connected while its bootstrap goes on: the same.
        $script:machine = New-TestMachine
        $connected = Invoke-DemoArcOnboarding -Config $evaluation -Health ([pscustomobject]@{ state = 'InProgress' }) -PollIntervalSeconds 1
        $connected.status | Should -Be 'Pass'
        $script:runs.Count | Should -Be 0

        # The check right after its onboarding still runs, on the VM itself, as before; when it fails, nothing is recorded, and
        # its fix is what works there.
        $script:machine = $null
        $script:sweepPart.pass = $false
        $script:sweepPart.remaining.logUser = 2
        $failed = Invoke-DemoArcOnboarding -Config $evaluation -PollIntervalSeconds 1
        $failed.status | Should -Be 'Fail'
        $failed.message | Should -Match '^EVALUATION ONLY: arcsql01 is onboarded, but the onboarding token''s traces couldn''t be removed and verified'
        $sweep = @($script:runs | Where-Object Name -EQ 'DbHubDemo-SignInData')
        $sweep.Count | Should -Be 1
        $sweep[0].VmName | Should -Be 'arcsql01'
        $sweep[0].Parameter['ResidueScope'] | Should -Be 'Local'
        $failed.remediation | Should -Match ([regex]::Escape('Run ./scripts/check-sign-in-data.ps1 -VmName arcsql01 -Clean -Force while Run Command still works on arcsql01'))
        $failed.remediation | Should -Not -Match 'by itself'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoArcSweepOwed -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSweepOwed -Times 0 -Exactly
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

    It 'configures a golden copy (-Force) whose host waits at ArcOnboardingBeforeWizard after the Release (review finding 1)' {
        # The Release renames the host's Arc marker, so a copy settles at ArcOnboardingBeforeWizard while its guest
        # already runs Standard; the read can also predate the guest's facts (no edition yet).
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { [pscustomobject]@{ Health = $script:health; Polls = 0 } }
        foreach ($edition in 'Standard Edition (64-bit)', '') {
            $script:health = [pscustomobject]@{ state = 'WaitingForArcOnboarding'; currentStep = 'ArcOnboardingBeforeWizard'; sqlEdition = $edition; guidedArmed = $false }
            $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig) -Force -WaitMinutes 1)
            ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Pass'
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 2 -Exactly
    }

    It 'configures without -Force once the guest runs Standard and nothing is armed (the host''s setup check passed)' {
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { [pscustomobject]@{ Health = [pscustomobject]@{ state = 'WaitingForArcOnboarding'; currentStep = 'ArcOnboardingBeforeWizard'; sqlEdition = 'Standard Edition (64-bit)'; guidedArmed = $false }; Polls = 0 } }
        $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig) -WaitMinutes 1)
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 1 -Exactly
    }

    It 'waits for the setup check in PaygWizard mode while setup hasn''t happened or is armed' {
        $cases = @(
            @{ state = 'WaitingForArcOnboarding'; currentStep = 'ArcOnboardingBeforeWizard'; sqlEdition = ''; guidedArmed = $false }
            @{ state = 'InProgress'; currentStep = 'GuidedSetup'; sqlEdition = ''; guidedArmed = $false }
            @{ state = 'ManualActionRequired'; currentStep = 'SqlSetupWizard'; sqlEdition = 'Enterprise Evaluation Edition (64-bit)'; guidedArmed = $false }
            @{ state = 'ManualActionRequired'; currentStep = 'SqlSetupWizard'; sqlEdition = 'Standard Edition (64-bit)'; guidedArmed = $true }
        )
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { [pscustomobject]@{ Health = $script:health; Polls = 0 } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcOnboarding -MockWith { New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Connected.' -Evidence @{ azureStatus = 'Connected' } }
        foreach ($case in $cases) {
            $script:health = [pscustomobject]$case
            $results = @(Invoke-DemoArcConfiguration -Config (New-TestConfig -Override @{ t2SqlInstallMode = 'PaygWizard' }) -WaitMinutes 1)
            ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Manual action required' -Because ('{0} at {1}' -f $case.state, $case.currentStep)
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 0 -Exactly
    }

    It 'doesn''t wait for a setup check in JumpstartImage mode (the default): nothing needs a person' {
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmHealthState -MockWith { [pscustomobject]@{ Health = [pscustomobject]@{ state = 'WaitingForArcOnboarding'; currentStep = 'ArcOnboarding'; sqlEdition = 'Standard Edition (64-bit)'; guidedArmed = $false }; Polls = 0 } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcOnboarding -MockWith { New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'Connected.' -Evidence @{ azureStatus = 'Connected' } }
        $config = New-TestConfig
        $config['t2SqlInstallMode'] | Should -Be 'JumpstartImage'
        $results = @(Invoke-DemoArcConfiguration -Config $config -WaitMinutes 1)
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoArcSqlConfiguration -Times 1 -Exactly
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
                    'MigrationAssessment' { Test-DemoArcMigrationAssessment -State $S }
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
        $wizard = New-TestConfig -Override @{ t2SqlInstallMode = 'PaygWizard' }
        (Invoke-Check 'Extension' (New-TestState -Config $wizard -Machine (New-TestMachine -SqlDetected $false) -Extension $null)).status | Should -Be 'Manual action required'
        (Invoke-Check 'Extension' (New-TestState -Config $config -Machine (New-TestMachine -SqlDetected $false) -Extension $null)).status | Should -Be 'Warning'
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
        $wizard = New-TestConfig -Override @{ t2SqlInstallMode = 'PaygWizard' }
        (Invoke-Check 'Instance' (New-TestState -Config $wizard -Machine (New-TestMachine) -Instances @(New-TestInstance))).status | Should -Be 'Pass'
        (Invoke-Check 'Instance' (New-TestState -Config $wizard -Machine (New-TestMachine -SqlDetected $false))).status | Should -Be 'Manual action required'
        (Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine -SqlDetected $false))).status | Should -Be 'Warning'
        (Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Enterprise' -LicenseType 'PAYG'))).status | Should -Be 'Fail'
        (Invoke-Check 'Instance' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -LicenseType 'Paid'))).status | Should -Be 'Fail'
    }

    It 'reports monitoring as Not supported in Developer mode' {
        $developer = New-TestConfig -Override @{ t2SqlInstallMode = 'Developer' }
        $result = Invoke-Check 'Monitoring' (New-TestState -Config $developer -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Developer' -Monitoring $false))
        $result.status | Should -Be 'Not supported'
    }

    It 'checks migration assessment: uploaded is Pass with each target type''s readiness; off, none uploaded yet, or no machine is a Warning, never a Fail (2026-11-18)' {
        $ready = [pscustomobject]@{
            enabled                  = $true
            assessmentUploadTime     = '2026-11-18T22:10:00Z'
            skuRecommendationResults = [pscustomobject]@{
                azureSqlDatabase        = [pscustomobject]@{ recommendationStatus = 'Ready'; targetSku = [pscustomobject]@{ computeSize = 2; category = [pscustomobject]@{ sqlServiceTier = 'General Purpose' } } }
                azureSqlManagedInstance = [pscustomobject]@{ recommendationStatus = 'Ready' }
                azureSqlVirtualMachine  = [pscustomobject]@{ recommendationStatus = 'NotReady' }
            }
        }
        $pass = Invoke-Check 'MigrationAssessment' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -Assessment $ready) -Extension (New-TestExtension -Version '1.1.2600.1'))
        $pass.checkId | Should -Be 'T2.ARC.MIGRATIONASSESSMENT'
        $pass.status | Should -Be 'Pass'
        $pass.message | Should -Match 'Azure SQL Database: Ready \(General Purpose, 2 vCores\); Azure SQL Managed Instance: Ready; SQL Server on Azure Virtual Machines: NotReady'
        $pass.docUrl | Should -Be 'https://learn.microsoft.com/sql/sql-server/azure-arc/migration-assessment'

        $off = Invoke-Check 'MigrationAssessment' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance) -Extension (New-TestExtension -Version '1.1.2600.1'))
        # Optional (2026-11-18 review): a Warning with the fix, so it never ends T2's track or keeps the run from DONE.
        $off.status | Should -Be 'Warning'
        $off.message | Should -Match 'nothing else depends on it'
        $off.remediation | Should -Match 'configure-arc\.ps1'

        $pending = [pscustomobject]@{ enabled = $true }
        (Invoke-Check 'MigrationAssessment' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -Assessment $pending) -Extension (New-TestExtension -Version '1.1.2600.1'))).status | Should -Be 'Warning'
        $old = Invoke-Check 'MigrationAssessment' (New-TestState -Config $config -Machine (New-TestMachine) -Instances @(New-TestInstance -Assessment $pending) -Extension (New-TestExtension -Version '1.1.2504.99'))
        $old.status | Should -Be 'Warning'
        $old.message | Should -Match '1\.1\.2594\.118'
        # Free for every edition: Developer mode is checked too.
        $developer = New-TestConfig -Override @{ t2SqlInstallMode = 'Developer' }
        (Invoke-Check 'MigrationAssessment' (New-TestState -Config $developer -Machine (New-TestMachine) -Instances @(New-TestInstance -Edition 'Developer' -Assessment $ready) -Extension (New-TestExtension -Version '1.1.2600.1'))).status | Should -Be 'Pass'
        (Invoke-Check 'MigrationAssessment' (New-TestState -Config $config -Machine $null)).status | Should -Be 'Warning'
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

    It 'gives a running host 10 minutes from its start or the last status change, whichever is later, then fails (live, 2026-11-03)' -ForEach @(
        @{ Case = 'the host started 4 minutes ago'; HostMinutes = 4; ChangeMinutes = 6000; Status = 'Warning' }
        @{ Case = 'the host started 12 minutes ago'; HostMinutes = 12; ChangeMinutes = 6000; Status = 'Fail' }
        @{ Case = 'it went Disconnected 8 minutes ago on a host running for an hour'; HostMinutes = 60; ChangeMinutes = 8; Status = 'Warning' }
        @{ Case = 'it went Disconnected 11 minutes ago on a host running for an hour'; HostMinutes = 60; ChangeMinutes = 11; Status = 'Fail' }
    ) {
        $state = New-TestState -Config $config -Machine (New-TestMachine -Status 'Disconnected' -LastStatusChange $script:now.AddMinutes(-$ChangeMinutes).ToString('o')) -HostPowerState 'PowerState/running'
        $state | Add-Member -NotePropertyName 'HostSinceUtc' -NotePropertyValue $script:now.AddMinutes(-$HostMinutes)
        $result = Invoke-Check 'Connected' $state
        $result.status | Should -Be $Status
        if ($Status -eq 'Fail') {
            $result.message | Should -Match ('archost01 has been running for {0} minutes' -f $HostMinutes)
            $result.remediation | Should -Match 'T2\.GUEST\.STATE'
        }
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

Describe 'Set-DemoArcSqlConfiguration turns on migration assessment and starts its first run (2026-11-18)' {
    BeforeEach {
        $script:config = New-TestConfig
        $script:assessment = $null
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcState -MockWith { New-TestState -Config $script:config -Machine (New-TestMachine) -Instances @(New-TestInstance -Assessment $script:assessment) -Extension (New-TestExtension -Version '1.1.2600.1') }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoArcSqlInstance -MockWith { , @(New-TestInstance -Assessment $script:assessment) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcMonitoringUpdate -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcMigrationAssessmentUpdate -MockWith { $script:assessment = [pscustomobject]@{ enabled = $true }; $true }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -MockWith { 'InProgress' }
    }

    It 'turns it on and starts a run, which is Pass on its own row' {
        $results = @(Set-DemoArcSqlConfiguration -Config $script:config -WaitMinutes 0 -PollIntervalSeconds 1)
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoArcMigrationAssessmentUpdate -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -Times 1 -Exactly
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').message | Should -Match 'Turned on migration assessment for arcsql01\. Started a migration assessment of arcsql01 \(job InProgress\)\.'
        $row = $results | Where-Object checkId -eq 'T2.ARC.MIGRATIONASSESSMENT'
        $row.status | Should -Be 'Pass'
        $row.message | Should -Match 'first run started \(InProgress\)'
    }

    It 'leaves one that has uploaded an assessment alone' {
        $script:assessment = [pscustomobject]@{ enabled = $true; assessmentUploadTime = '2026-11-18T22:10:00Z' }
        $results = @(Set-DemoArcSqlConfiguration -Config $script:config -WaitMinutes 0 -PollIntervalSeconds 1)
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoArcMigrationAssessmentUpdate -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -Times 0 -Exactly
        ($results | Where-Object checkId -eq 'T2.ARC.MIGRATIONASSESSMENT').status | Should -Be 'Pass'
    }

    It 'says on its own row, as a Warning, when a policy denies it, and the rest of the configuration still counts (2026-11-18 review)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcMigrationAssessmentUpdate -MockWith { throw 'Turning on migration assessment for arcsql01 failed: (RequestDisallowedByPolicy) Resource ''arcsql01'' was disallowed by policy.' }
        $results = @(Set-DemoArcSqlConfiguration -Config $script:config -WaitMinutes 0 -PollIntervalSeconds 1)
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').status | Should -Be 'Pass'
        @($results | Where-Object status -EQ 'Fail') | Should -BeNullOrEmpty
        $row = $results | Where-Object checkId -eq 'T2.ARC.MIGRATIONASSESSMENT'
        $row.status | Should -Be 'Warning'
        $row.message | Should -Match 'RequestDisallowedByPolicy'
        $row.remediation | Should -Match 'exemption'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -Times 0 -Exactly

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcMigrationAssessmentUpdate -MockWith { $script:assessment = [pscustomobject]@{ enabled = $true }; $true }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -MockWith { throw 'Starting a migration assessment of arcsql01 failed: (Conflict)' }
        $script:assessment = $null
        $again = @(Set-DemoArcSqlConfiguration -Config $script:config -WaitMinutes 0 -PollIntervalSeconds 1)
        ($again | Where-Object checkId -eq 'T2.ARC.MIGRATIONASSESSMENT').status | Should -Be 'Warning'
    }

    It 'is a Warning, and starts no run, when Azure accepted it but the setting doesn''t read as on yet (2026-11-18 review)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoArcMigrationAssessmentUpdate -MockWith { $false }
        $results = @(Set-DemoArcSqlConfiguration -Config $script:config -WaitMinutes 0 -PollIntervalSeconds 1)
        $row = $results | Where-Object checkId -eq 'T2.ARC.MIGRATIONASSESSMENT'
        $row.status | Should -Be 'Warning'
        $row.message | Should -Match 'didn''t read as on within 3 minutes'
        ($results | Where-Object checkId -eq 'T2.ARC.CONFIGURATION').message | Should -Not -Match 'Turned on migration assessment'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -Times 0 -Exactly
    }
}

Describe 'Invoke-DemoArcMigrationAssessmentUpdate reads the setting back after its PATCH (2026-11-18 review)' {
    BeforeEach {
        $script:target = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = (New-TestConfig) } { param($C) Get-DemoArcTarget -Config $C }
        $script:reads = 0
        $script:onAfter = 2
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArmCollection -MockWith {
            $script:reads++
            $enabled = $script:onAfter -gt 0 -and $script:reads -ge $script:onAfter
            , @(New-TestInstance -Assessment ([pscustomobject]@{ enabled = $enabled }))
        }
    }

    It 'waits through a 202 Accepted until the setting reads as on' {
        $on = InModuleScope -ModuleName DbHubDemo -Parameters @{ T = $script:target } { param($T) Invoke-DemoArcMigrationAssessmentUpdate -Target $T -InstanceName 'arcsql01' -WaitSeconds 60 -PollSeconds 15 -Confirm:$false }
        $on | Should -BeTrue
        $script:reads | Should -Be 2
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '--method patch' }
    }

    It 'returns false, without throwing, when the setting still reads as off after the wait' {
        $script:onAfter = 0
        $on = InModuleScope -ModuleName DbHubDemo -Parameters @{ T = $script:target } { param($T) Invoke-DemoArcMigrationAssessmentUpdate -Target $T -InstanceName 'arcsql01' -WaitSeconds 60 -PollSeconds 15 -Confirm:$false }
        $on | Should -BeFalse
        $script:reads | Should -Be 5
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'didn''t read as on within 60 seconds' }
    }

    It 'throws the refusal, redacted, when Azure denies the PATCH, and reads nothing' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (RequestDisallowedByPolicy) Resource ''arcsql01'' was disallowed by policy.' } }
        { InModuleScope -ModuleName DbHubDemo -Parameters @{ T = $script:target } { param($T) Invoke-DemoArcMigrationAssessmentUpdate -Target $T -InstanceName 'arcsql01' -Confirm:$false } } | Should -Throw '*RequestDisallowedByPolicy*'
        $script:reads | Should -Be 0
    }
}

Describe 'T2''s first migration assessment is tried again later in the run (2026-11-18 live finding)' {
    BeforeEach {
        $script:config = New-TestConfig
        $script:assessment = [pscustomobject]@{ enabled = $true }
        $script:tries = 0
        $script:refusals = 2
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcState -MockWith { New-TestState -Config $script:config -Machine (New-TestMachine) -Instances @(New-TestInstance -Assessment $script:assessment) -Extension (New-TestExtension -Version '1.1.3579.481') }
        Mock -ModuleName DbHubDemo -CommandName Start-DemoArcMigrationAssessment -MockWith {
            $script:tries++
            if ($script:tries -le $script:refusals) {
                throw 'Starting a migration assessment of arcsql01 failed: ERROR: Internal Server Error({"error":{"code":"InternalServerError","message":"There was an unexpected problem communicating with the Arc Sql Extension"}})'
            }
            'InProgress'
        }
    }

    It 'tries every 2 minutes until Azure takes the run, which is Pass' {
        $row = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = $script:config } { param($C) Invoke-DemoArcMigrationAssessmentRetry -Config $C -WaitMinutes 10 }
        $script:tries | Should -Be 3
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 120 }
        $row.checkId | Should -Be 'T2.ARC.MIGRATIONASSESSMENT'
        $row.status | Should -Be 'Pass'
        $row.message | Should -Match 'first run started \(InProgress\)'
    }

    It 'stops at its deadline with a Warning that keeps Azure''s last answer' {
        $script:refusals = 99
        $row = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = $script:config } { param($C) Invoke-DemoArcMigrationAssessmentRetry -Config $C -WaitMinutes 0 }
        $script:tries | Should -Be 1
        $row.status | Should -Be 'Warning'
        $row.message | Should -Match 'communicating with the Arc Sql Extension'
    }

    It 'starts nothing when the assessment is off or already uploaded' {
        foreach ($assessment in @([pscustomobject]@{ enabled = $false }, [pscustomobject]@{ enabled = $true; assessmentUploadTime = '2026-11-19T02:33:29Z' })) {
            $script:assessment = $assessment
            $null = InModuleScope -ModuleName DbHubDemo -Parameters @{ C = $script:config } { param($C) Invoke-DemoArcMigrationAssessmentRetry -Config $C }
        }
        $script:tries | Should -Be 0
    }

    It 'retries only a Warning whose assessment is on, with none uploaded and no run started' {
        $retry = {
            param([string] $Status, [object] $Evidence, [string] $CheckId = 'T2.ARC.MIGRATIONASSESSMENT')
            $result = New-DemoResult -CheckId $CheckId -Area 't2' -Target 'T2' -Status $Status -Message 'm' -Evidence $Evidence
            InModuleScope -ModuleName DbHubDemo -Parameters @{ R = $result } { param($R) Test-DemoArcMigrationAssessmentRetry -Result $R }
        }
        & $retry 'Warning' ([ordered]@{ enabled = $true; uploadedAt = ''; runStarted = '' }) | Should -BeTrue
        & $retry 'Warning' ([ordered]@{ enabled = $false; uploadedAt = ''; runStarted = '' }) | Should -BeFalse
        & $retry 'Warning' ([ordered]@{ enabled = $true; uploadedAt = '2026-11-19T02:33:29Z'; runStarted = '' }) | Should -BeFalse
        & $retry 'Pass' ([ordered]@{ enabled = $true; uploadedAt = ''; runStarted = 'InProgress' }) | Should -BeFalse
        & $retry 'Warning' ([ordered]@{ enabled = $true; uploadedAt = ''; runStarted = '' }) 'T2.ARC.MONITORING' | Should -BeFalse
        InModuleScope -ModuleName DbHubDemo { Test-DemoArcMigrationAssessmentRetry -Result $null } | Should -BeFalse
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
        # Live, 2026-11-03: the plugin stopped and T1 sent nothing; the remediation restarts its agent, which
        # configure-monitoring.ps1 never does.
        $pending.message | Should -Match 'reports ''NotRunning'''
        $pending.remediation | Should -Match 'start-demo\.ps1, which restarts the SQL IaaS Agent service'
        $pending.remediation | Should -Match 'deploy\.ps1, which repairs T1''s SQL IaaS Agent extension'
        $pending.remediation | Should -Not -Match 'az vm run-command' -Because 'a person never repairs it by hand (AGENTS.md)'
        $pending.remediation | Should -Not -Match 'configure-monitoring'
        $noStatus = & $convert (New-SqlVmState -Settings $flag -Message 'SqlIaasAgent: OK')
        $noStatus.status | Should -Be 'Warning'
        $noStatus.remediation | Should -Match 'check again later'
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

    Context 'a plugin that doesn''t report Running and OK (Phase 28 live finding, 2026-10-30)' {
        BeforeEach {
            # Live, b18a028's rerun from deallocated VMs: the flag was set, the plugin reported NotRunning, and the Monitoring
            # step polled it for 20 minutes (25 with the reads, about 20 seconds each) before the agent's restart.
            $script:flag = '{"FeatureFlags":[{"Name":"DatabaseWatcheronAzureVM","Enable":true}]}' | ConvertFrom-Json
            $script:notRunning = 'SqlIaasAgent: OK; DatabaseMonitorArcPlugin: {"State":"NotRunning"}'
            $script:now = [datetime]::new(2026, 10, 30, 13, 29, 21, [System.DateTimeKind]::Utc)
            $script:sleeps = [System.Collections.Generic.List[int]]::new()
            $script:reads = 0
            $script:message = $script:notRunning
            $script:settings = $script:flag
            $script:page = [System.Collections.Generic.List[string]]::new()
            $script:logged = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $script:now }
            Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $script:sleeps.Add([int]$Seconds); $script:now = $script:now.AddSeconds($Seconds) }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
                $script:reads++
                $script:now = $script:now.AddSeconds(20)
                New-SqlVmState -Settings $script:settings -Message $script:message
            }
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { $script:logged.Add([string]$PesterBoundParameters['Message']) }
            Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:page.Add(('{0}|{1}|{2}|{3}' -f (@($PesterBoundParameters['Id']) -join ','), $PesterBoundParameters['State'], [bool]$PesterBoundParameters['AzureSide'], $PesterBoundParameters['Message'])) }
        }

        It 'ends the wait after the short grace when the flag was already set, so the agent''s restart comes after about 3 minutes, not 20, and says so on the console and the status page' {
            $start = $script:now
            $result = Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 20 -NotRunningGraceMinutes 3 -ProgressPath 'progress.json' -Confirm:$false
            $result.status | Should -Be 'Warning'
            $result.evidence.stoppedForRestart | Should -BeTrue
            $result.evidence.notRunningGraceMinutes | Should -Be 3
            $result.evidence.waitedSeconds | Should -Be 220 -Because 'the first read (20 s), then 180 s of NotRunning, counted in elapsed time with the reads'
            ($script:now - $start).TotalSeconds | Should -Be 220
            @($script:sleeps) | Should -Be @(60, 60, 20) -Because 'no sleep runs past the grace'
            InModuleScope -ModuleName DbHubDemo -Parameters @{ R = $result } { param($R) Test-DemoSqlVmMonitoringStuck -Result $R } | Should -BeTrue -Because 'the caller restarts the agent next'
            $script:page | Should -Be @(
                'T1.Monitoring|Running|True|T1''s monitoring plugin reports NotRunning; the deployment restarts it if it doesn''t start by itself within 3 minutes; no action needed.'
                'T1.Monitoring|Running|True|T1''s monitoring plugin reports NotRunning (1 min so far); the deployment restarts it if it doesn''t start by itself within 2 minutes; no action needed.'
                'T1.Monitoring|Running|True|T1''s monitoring plugin reports NotRunning (3 min so far); the deployment restarts it if it doesn''t start by itself within 1 minute; no action needed.'
            )
            $script:logged | Should -Be @(
                'T1''s monitoring plugin reports NotRunning; the deployment restarts it if it doesn''t start by itself within 3 minutes; no action needed.'
                'T1''s monitoring plugin reports NotRunning (3 min so far); the deployment restarts it if it doesn''t start by itself within 1 minute; no action needed.'
            ) -Because 'a console line when the wait starts, then every few minutes'
        }

        It 'gives the plugin the longer grace when this call merged the flag, and still ends the wait after about 5 minutes, not 20' {
            $script:settings = $null
            Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
                $script:reads++
                $script:now = $script:now.AddSeconds(20)
                New-SqlVmState -Settings $(if ($script:reads -eq 1) { $null } else { $script:flag }) -Message $(if ($script:reads -eq 1) { '' } else { $script:notRunning })
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' } }
            $result = Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 20 -NotRunningGraceMinutes 3 -Confirm:$false
            $result.evidence.actions[0] | Should -Match '^Merged DatabaseWatcheronAzureVM'
            $result.evidence.notRunningGraceMinutes | Should -Be 5
            $result.evidence.stoppedForRestart | Should -BeTrue
            $result.evidence.waitedSeconds | Should -Be 360 -Because 'two reads (40 s), then reads a minute apart until NotRunning has lasted 5 minutes'
            @($script:sleeps) | Should -Be @(60, 60, 60, 60)
        }

        It 'bounds the whole wait in elapsed time, the reads included, not in reads times the interval' {
            # A plugin with no status yet is waited for the whole -WaitMinutes: 20 minutes of elapsed time, not 21 reads.
            $script:message = ''
            $result = Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 20 -NotRunningGraceMinutes 3 -Confirm:$false
            $result.status | Should -Be 'Warning'
            $result.evidence.stoppedForRestart | Should -BeFalse
            $result.evidence.waitedSeconds | Should -BeLessOrEqual (1200 + 20) -Because 'it ends with the first read after 20 minutes'
            $result.evidence.waitedSeconds | Should -BeGreaterOrEqual 1200
            $script:reads | Should -Be 16 -Because 'counted in reads, 20 polls at 80 seconds each took 27 minutes'
            $script:logged[0] | Should -Be 'T1''s monitoring plugin has no status yet; waiting up to 20 minutes more for Running and OK; no action needed.'
            @($script:logged).Count | Should -Be 6 -Because 'a console line every few minutes (at 0, 3, 7, 11, 15, and 19), never silent'
        }

        It 'ends the wait at the first NotRunning read with a grace of 0, as start-demo.ps1 does after it recreates T3, still gives a flag it merges 5 minutes, and waits the whole time without a grace' {
            # The owner's decision, 2026-10-30: start-demo.ps1 restarts a NotRunning plugin at once; presenters run it before
            # each session.
            $result = Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 20 -NotRunningGraceMinutes 0 -Confirm:$false
            $result.evidence.stoppedForRestart | Should -BeTrue
            $result.evidence.notRunningGraceMinutes | Should -Be 0
            $result.evidence.waitedSeconds | Should -Be 20 -Because 'one read, and no sleep'
            @($script:sleeps) | Should -BeNullOrEmpty
            $script:reads | Should -Be 1

            # A flag this call merges still gets 5 minutes: the setting takes a few minutes to apply.
            $script:reads = 0
            $script:sleeps.Clear()
            Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
                $script:reads++
                $script:now = $script:now.AddSeconds(20)
                New-SqlVmState -Settings $(if ($script:reads -eq 1) { $null } else { $script:flag }) -Message $(if ($script:reads -eq 1) { '' } else { $script:notRunning })
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' } }
            $result = Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 20 -NotRunningGraceMinutes 0 -Confirm:$false
            $result.evidence.notRunningGraceMinutes | Should -Be 5
            $result.evidence.waitedSeconds | Should -Be 360

            # Without -NotRunningGraceMinutes (configure-monitoring.ps1), a NotRunning plugin is waited for the whole time.
            $script:reads = 0
            Mock -ModuleName DbHubDemo -CommandName Get-DemoSqlVmMonitoringState -MockWith {
                $script:reads++
                $script:now = $script:now.AddSeconds(20)
                New-SqlVmState -Settings $script:flag -Message $script:notRunning
            }
            $result = Enable-DemoSqlVmMonitoring -Config $config -WaitMinutes 5 -Confirm:$false
            $result.status | Should -Be 'Warning'
            $result.evidence.Contains('stoppedForRestart') | Should -BeFalse
            $result.evidence.waitedSeconds | Should -BeGreaterOrEqual 300
        }
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

Describe 'Wait-DemoVmHealthState stops when the VM has no room for a fresh Run Command name (2026-11-13 live finding)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:reads = 0
        $script:readError = 'archost01: Azure still lists DbHubDemo-HealthRead after 30s, and the VM already has 24 Run Commands (9 being deleted), close to Azure''s limit of 25, so it didn''t run under a fresh name either. That''s Azure-side: Azure deletes them on its own, and the next try checks again.'
    }

    It 'ends the wait with Full, whatever MaxPolls allows, and keeps the last state it read' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith {
            $script:reads++
            if ($script:reads -eq 1) {
                return [pscustomobject]@{ state = 'InProgress'; currentStep = 'GuestSignInCleanup' }
            }
            throw $script:readError
        }
        $wait = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Wait-DemoVmHealthState -Config $Config -VmName 'archost01' -State @('Ready') -MaxPolls 30 -PollSeconds 60 -FullMinutes 0 }
        $wait.Full | Should -BeTrue
        $wait.Health.state | Should -Be 'InProgress'
        $script:reads | Should -Be 2 -Because 'the first refusal ends it with -FullMinutes 0, not 30 polls'
    }

    It 'keeps waiting through other read failures, as before' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoVmHealth -MockWith {
            $script:reads++
            if ($script:reads -lt 3) {
                throw 'archost01: DbHubDemo-HealthRead timed out.'
            }
            [pscustomobject]@{ state = 'Ready'; currentStep = '' }
        }
        $wait = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Wait-DemoVmHealthState -Config $Config -VmName 'archost01' -State @('Ready') -MaxPolls 30 -PollSeconds 60 -FullMinutes 0 }
        $wait.Full | Should -BeFalse
        $wait.Health.state | Should -Be 'Ready'
        $script:reads | Should -Be 3
    }
}
