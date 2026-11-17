BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        return $config
    }

    function New-AzAnswer([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    $script:notFound = "ERROR: (ResourceNotFound) The Resource 'Microsoft.Compute/virtualMachines/archost01' under resource group 'rg-dbhub-demo' was not found."
}

Describe 'The T2 host''s rebuild: its template and the values it''s created with (2026-11-17)' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        $script:template = @{ parameters = [ordered]@{
                location               = @{ type = 'string' }
                vmSize                 = @{ type = 'string' }
                adminPassword          = @{ type = 'securestring' }
                includeOsProfile       = @{ type = 'bool' }
                osDiskSourceResourceId = @{ type = 'string'; defaultValue = '' }
                attachExistingOsDisk   = @{ type = 'bool'; defaultValue = $false }
                diskSkuOverrides       = @{ type = 'object'; defaultValue = @{} }
                licenseType            = @{ type = 'string' }
            }
        }
        $script:record = '{"location":{"type":"String","value":"westus3"},"vmSize":{"type":"String","value":"Standard_E2s_v5"},"adminPassword":{"type":"SecureString"},"includeOsProfile":{"type":"Bool","value":false},"osDiskSourceResourceId":{"type":"String","value":"/subscriptions/x/resourceGroups/rg-dbhub-golden/providers/Microsoft.Compute/snapshots/snap"},"attachExistingOsDisk":{"type":"Bool","value":true},"diskSkuOverrides":{"type":"Object","value":{"archost01-osdisk":"Standard_LRS"}},"licenseType":{"type":"String","value":""}}'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^deployment group show ' } -MockWith { New-AzAnswer -StdOut $script:record }
    }

    It 'reads archost01''s own template from azuredeploy.json: the nested deployment every deployment creates the host with' {
        $template = InModuleScope DbHubDemo { Get-DemoT2HostTemplate }
        @($template['parameters'].Keys) | Should -Contain 'adminPassword'
        @($template['parameters'].Keys) | Should -Contain 'includeOsProfile'
        @($template['resources'] | ForEach-Object { [string]$_['name'] }) | Should -Contain 'archost01-vm'

        $empty = Join-Path -Path $TestDrive -ChildPath 'empty.json'
        Set-Content -LiteralPath $empty -Value '{"resources":[]}'
        { InModuleScope DbHubDemo -Parameters @{ Path = $empty } { Get-DemoT2HostTemplate -TemplatePath $Path } } | Should -Throw '*no nested deployment archost01*'
    }

    It 'takes the values archost01''s last deployment recorded, for a new VM: its OS profile, the image, its own disks, and no password' {
        $answer = InModuleScope DbHubDemo -Parameters @{ Config = $config; Template = $script:template } { Get-DemoT2HostDeploymentParameter -Config $Config -Template $Template }
        $answer.Ok | Should -BeTrue
        $answer.Parameters['location']['value'] | Should -Be 'westus3'
        $answer.Parameters['vmSize']['value'] | Should -Be 'Standard_E2s_v5'
        $answer.Parameters['licenseType']['value'] | Should -Be ''
        $answer.Parameters['includeOsProfile']['value'] | Should -BeTrue -Because 'the VM is new'
        $answer.Parameters['osDiskSourceResourceId']['value'] | Should -Be '' -Because 'the new host builds its guest from the image'
        $answer.Parameters['attachExistingOsDisk']['value'] | Should -BeFalse
        $answer.Parameters['diskSkuOverrides']['value'].Count | Should -Be 0 -Because 'its disks are new'
        $answer.Parameters.Contains('adminPassword') | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^deployment group show --resource-group rg-dbhub-demo --name archost01 ' }
    }

    It 'fails, saying why, when the record lacks a value the template needs, or can''t be read' {
        $script:record = '{"location":{"type":"String","value":"westus3"}}'
        $answer = InModuleScope DbHubDemo -Parameters @{ Config = $config; Template = $script:template } { Get-DemoT2HostDeploymentParameter -Config $Config -Template $Template }
        $answer.Ok | Should -BeFalse
        $answer.Error | Should -Be 'archost01''s last deployment record has no value for vmSize, licenseType, which its template needs'

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^deployment group show ' } -MockWith { New-AzAnswer -ExitCode 3 -StdErr "ERROR: (DeploymentNotFound) Deployment 'archost01' could not be found." }
        $unread = InModuleScope DbHubDemo -Parameters @{ Config = $config; Template = $script:template } { Get-DemoT2HostDeploymentParameter -Config $Config -Template $Template }
        $unread.Ok | Should -BeFalse
        $unread.Error | Should -Match '^archost01''s last deployment record in rg-dbhub-demo couldn''t be read: .*DeploymentNotFound'
    }

    It 'creates archost01 from its template with a new password that''s only in a private file, deleted afterward' {
        $script:seen = $null
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^deployment group create ' } -MockWith {
            $list = @($ArgumentList)
            $parametersFile = ([string]$list[[array]::IndexOf($list, '--parameters') + 1]).Substring(1)
            $templateFile = [string]$list[[array]::IndexOf($list, '--template-file') + 1]
            $script:seen = [pscustomobject]@{
                Arguments  = ($list -join ' ')
                Parameters = (Get-Content -LiteralPath $parametersFile -Raw | ConvertFrom-Json -AsHashtable)
                Template   = (Get-Content -LiteralPath $templateFile -Raw | ConvertFrom-Json -AsHashtable -Depth 200)
                Directory  = (Split-Path -Path $parametersFile -Parent)
                Timeout    = $PesterBoundParameters['TimeoutSeconds']
            }
            New-AzAnswer -StdOut '{"properties":{"provisioningState":"Succeeded"}}'
        }
        $created = InModuleScope DbHubDemo -Parameters @{ Config = $config } { New-DemoT2HostVm -Config $Config -Template (Get-DemoT2HostTemplate) -Parameters ([ordered]@{ vmSize = @{ value = 'Standard_E2s_v5' }; includeOsProfile = @{ value = $true } }) -Confirm:$false }
        $created.Created | Should -BeTrue
        $script:seen.Arguments | Should -Match '^deployment group create --resource-group rg-dbhub-demo --name archost01-rebuild --template-file '
        $password = [string]$script:seen.Parameters['parameters']['adminPassword']['value']
        $password.Length | Should -BeGreaterThan 11
        $script:seen.Arguments | Should -Not -Match ([regex]::Escape($password))
        $script:seen.Parameters['parameters']['vmSize']['value'] | Should -Be 'Standard_E2s_v5'
        @($script:seen.Template['resources'] | ForEach-Object { [string]$_['name'] }) | Should -Contain 'archost01-vm'
        Test-Path -LiteralPath $script:seen.Directory | Should -BeFalse -Because 'the password file goes with its folder'
        [int]$script:seen.Timeout | Should -Be 2400

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^deployment group create ' } -MockWith { New-AzAnswer -ExitCode 1 -StdErr 'ERROR: {"code":"OperationNotAllowed","message":"Operation could not be completed as it results in exceeding approved Total Regional Cores quota."}' }
        $refused = InModuleScope DbHubDemo -Parameters @{ Config = $config } { New-DemoT2HostVm -Config $Config -Template @{ resources = @() } -Parameters ([ordered]@{}) -Confirm:$false }
        $refused.Created | Should -BeFalse
        $refused.Detail | Should -Match '^the deployment archost01-rebuild failed: .*quota'
    }

    It 'clears what the state records for the old host, under the tracks'' lock' {
        $script:written = $null
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ BundleSentTo = @('sqlvm01', 'archost01'); RunnerSentTo = @('sqlvm01', 'archost01') } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:written = $Value }
        InModuleScope DbHubDemo -Parameters @{ Config = $config } { Reset-DemoT2HostRecord -Config $Config -Confirm:$false }
        @($script:written['BundleSentTo']) | Should -Be @('sqlvm01')
        @($script:written['RunnerSentTo']) | Should -Be @('sqlvm01')
        $script:written['TrackT2'] | Should -Be ''
        $script:written['T2BuildUtc'] | Should -Be ''
        $script:written['T2InstallMode'] | Should -Be ''
        $script:written['T2Source'] | Should -Be 'build'
    }
}

Describe 'The T2 host''s rebuild: deleting the old host (2026-11-17)' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:shows = 0
        $script:keep = $false
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { $script:calls.Add(($ArgumentList -join ' ')); New-AzAnswer }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $joined = $ArgumentList -join ' '
            $script:calls.Add($joined)
            if ($joined -match '^vm show ') {
                $script:shows++
                if ($script:keep -or $script:shows -lt 3) {
                    return (New-AzAnswer -StdOut 'Deleting')
                }
                return (New-AzAnswer -ExitCode 3 -StdErr $script:notFound)
            }
            if ($joined -match '^disk show .*--name archost01-data01 ') {
                return (New-AzAnswer -StdOut '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/disks/archost01-data01')
            }
            return (New-AzAnswer -ExitCode 3 -StdErr $script:notFound)
        }
    }

    It 'deletes archost01, waits until Azure no longer has it, then deletes the disk the template keeps apart, and nothing else' {
        $removal = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoT2HostVm -Config $Config -TimeoutMinutes 5 -PollSeconds 20 -Confirm:$false }
        $removal.Deleted | Should -BeTrue
        @($removal.Removed) | Should -Be @('archost01-data01')
        $script:calls[0] | Should -Be 'vm delete --resource-group rg-dbhub-demo --name archost01 --yes --no-wait'
        $script:shows | Should -Be 3
        @($script:calls | Where-Object { $_ -match ' delete ' -and $_ -notmatch '^vm delete' }) | Should -Be @('disk delete --resource-group rg-dbhub-demo --name archost01-data01 --yes')
    }

    It 'stops at its bound, saying so, while Azure still has the VM' {
        $script:keep = $true
        $removal = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoT2HostVm -Config $Config -TimeoutMinutes 1 -PollSeconds 20 -Confirm:$false }
        $removal.Deleted | Should -BeFalse
        $removal.Detail | Should -Be 'Azure hadn''t deleted it after 1 minutes'
        $script:shows | Should -Be 4 -Because 'a minute is three polls 20 seconds apart, after the first read'
        @($script:calls | Where-Object { $_ -match '^disk ' }) | Should -BeNullOrEmpty
    }

    It 'stops at once, with Azure''s reason, when Azure refuses the delete' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { New-AzAnswer -ExitCode 1 -StdErr 'ERROR: (ScopeLocked) The scope cannot perform delete operation because following scope(s) are locked.' }
        $removal = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Remove-DemoT2HostVm -Config $Config -Confirm:$false }
        $removal.Deleted | Should -BeFalse
        $removal.Detail | Should -Match '^Azure refused its delete: .*ScopeLocked'
        $script:shows | Should -Be 0
    }
}

Describe 'Invoke-DemoT2HostRebuild: once, in order, and what it says (2026-11-17)' {
    BeforeAll {
        $config = New-TestConfig
    }

    BeforeEach {
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:rows = [System.Collections.Generic.List[string]]::new()
        $script:paramsOk = $true
        $script:deleted = $true
        $script:created = $true
        $script:agent = 95
        $script:busyBy = ''
        $script:busyUntil = ''
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { $script:rows.Add(('{0}|{1}|{2}' -f (@($Id) -join ','), $State, $Status)) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2HostTemplate -MockWith { $script:order.Add('template'); @{ parameters = @{}; resources = @() } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT2HostDeploymentParameter -MockWith { $script:order.Add('parameters'); [pscustomobject]@{ Ok = $script:paramsOk; Parameters = [ordered]@{ vmSize = @{ value = 'Standard_E2s_v5' } }; Error = 'archost01''s last deployment record in rg-dbhub-demo couldn''t be read: not found' } }
        Mock -ModuleName DbHubDemo -CommandName Reset-DemoT2HostRecord -MockWith { $script:order.Add('reset') }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoT2HostVm -MockWith { $script:order.Add('delete'); [pscustomobject]@{ Deleted = $script:deleted; Detail = 'Azure refused its delete: conflict'; Seconds = 300; Removed = @() } }
        Mock -ModuleName DbHubDemo -CommandName New-DemoT2HostVm -MockWith { $script:order.Add('create'); [pscustomobject]@{ Created = $script:created; Detail = 'the deployment archost01-rebuild failed: quota'; Seconds = 240 } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoVmAgentReady -MockWith { $script:order.Add('agent'); $script:agent }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ BusyBy = $script:busyBy; BusyUntilUtc = $script:busyUntil } }
        Mock -ModuleName DbHubDemo -CommandName Sync-DemoAutoShutdownForBusy -MockWith { $script:order.Add('shutdown'); @() }
    }

    It 'reads the template and the last values first, then clears the records, deletes the host, creates it again, and waits for its agent: a Warning' {
        $rebuild = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoT2HostRebuild -Config $Config -Cause 'T2''s Artifacts step' -ProgressPath 'progress.json' -Confirm:$false }
        $rebuild.Rebuilt | Should -BeTrue
        $script:order | Should -Be @('template', 'parameters', 'reset', 'delete', 'create', 'agent')
        $rebuild.Result.checkId | Should -Be 'DEPLOY.T2.HOSTREBUILD'
        $rebuild.Result.status | Should -Be 'Warning'
        $rebuild.Result.message | Should -Match '^archost01''s VM agent stayed down, and a deallocate and start didn''t bring it back \(T2''s Artifacts step\), so deploy\.ps1 rebuilt T2''s host in \d+ minutes: it deleted archost01 and its disks and created it again from the template, and the new host''s agent is Ready\.'
        $rebuild.Result.remediation | Should -Match '^Nothing to do: the run goes on with T2\.'
        $script:rows[0] | Should -Be 'T2.HostRebuild|Running|'
        $script:rows[-1] | Should -Be 'T2.HostRebuild|Done|Warning'
        $script:order | Should -Not -Contain 'shutdown' -Because 'no run is marked busy'
        # What the run builds on the new host follows the T2 mode.
        $rebuild.Result.message | Should -Match 'This run now builds T2 on it from Arc Jumpstart''s image and onboards it to Azure Arc \(about an hour\)'
        $developer = New-TestConfig
        $developer['t2SqlInstallMode'] = 'Developer'
        (InModuleScope DbHubDemo -Parameters @{ Config = $developer } { Invoke-DemoT2HostRebuild -Config $Config -Confirm:$false }).Result.message | Should -Match 'This run now builds T2''s guest on it in Developer mode and onboards it to Azure Arc \(longer than an hour'
    }

    It 'moves the new host''s auto-shutdown out of a busy run''s way before it waits for the agent' {
        $script:busyBy = 'deploy'
        $script:busyUntil = [DateTime]::UtcNow.AddMinutes(40).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $null = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoT2HostRebuild -Config $Config -Confirm:$false }
        $script:order | Should -Be @('template', 'parameters', 'reset', 'delete', 'create', 'shutdown', 'agent')
    }

    It 'ends with a Fail and the next step when <Case>' -ForEach @(
        @{ Case = 'the last values can''t be read: nothing is deleted'; Variable = 'paramsOk'; Value = $false; Order = @('template', 'parameters'); Pattern = 'the host wasn''t rebuilt: archost01''s last deployment record in rg-dbhub-demo couldn''t be read: not found\. Nothing was deleted\.'; Fix = '^Run \./scripts/deploy\.ps1 -FromStage Infrastructure' }
        @{ Case = 'Azure refuses the delete'; Variable = 'deleted'; Value = $false; Order = @('template', 'parameters', 'reset', 'delete'); Pattern = 'its rebuild stopped: archost01 couldn''t be deleted \(Azure refused its delete: conflict\)\.'; Fix = 'DEPLOY\.T2\.HOSTMISSING' }
        @{ Case = 'the host can''t be created again'; Variable = 'created'; Value = $false; Order = @('template', 'parameters', 'reset', 'delete', 'create'); Pattern = '^archost01 was deleted for its rebuild, but creating it again failed: the deployment archost01-rebuild failed: quota\.'; Fix = 'doesn''t exist, so it deploys the template, which creates it \(DEPLOY\.T2\.HOSTMISSING\)' }
        @{ Case = 'the new host''s agent stays down too'; Variable = 'agent'; Value = -1; Order = @('template', 'parameters', 'reset', 'delete', 'create', 'agent'); Pattern = 'the new host''s VM agent wasn''t Ready within 20 minutes either, so the cause is on Azure''s side\.'; Fix = 'support request' }
    ) {
        Set-Variable -Scope Script -Name $Variable -Value $Value
        $rebuild = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Invoke-DemoT2HostRebuild -Config $Config -Confirm:$false }
        $rebuild.Rebuilt | Should -BeFalse
        $script:order | Should -Be $Order
        $rebuild.Result.status | Should -Be 'Fail'
        $rebuild.Result.message | Should -Match $Pattern
        $rebuild.Result.remediation | Should -Match $Fix
        $script:rows[-1] | Should -Be 'T2.HostRebuild|Failed|Fail'
    }
}

Describe 'The T2 host''s rebuild: its cue, a host that''s gone, and what DONE says (2026-11-17)' {
    BeforeAll {
        $config = New-TestConfig
        $script:dead = New-DemoResult -CheckId 'DEPLOY.WATCHDOG_ARCHOST01' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'archost01 was deallocated and started automatically at 05:37 (local time).' -Evidence ([ordered]@{ vmName = 'archost01'; agentDead = $true })
    }

    It 'takes only the T2 host''s watchdog Fail whose agent stayed down as the cue' {
        $cue = { param([object[]] $Items) InModuleScope DbHubDemo -Parameters @{ Items = $Items } { Test-DemoT2HostDeadResult -Result $Items } }
        & $cue @($script:dead) | Should -BeTrue
        & $cue @((New-DemoResult -CheckId 'DEPLOY.WATCHDOG_ARCHOST01' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'x' -Evidence ([ordered]@{ agentDead = $false }))) | Should -BeFalse
        & $cue @((New-DemoResult -CheckId 'DEPLOY.WATCHDOG_ARCHOST01' -Area 'infra' -Target 'T2' -Status 'Warning' -Message 'x' -Evidence ([ordered]@{ agentDead = $true }))) | Should -BeFalse
        & $cue @((New-DemoResult -CheckId 'DEPLOY.WATCHDOG_SQLVM01' -Area 'infra' -Target 'T1' -Status 'Fail' -Message 'x' -Evidence ([ordered]@{ agentDead = $true }))) | Should -BeFalse
        & $cue @() | Should -BeFalse
    }

    It 'turns the failed attempt''s Fails into Warnings that name the rebuild, and leaves the rebuild''s own result' {
        $failed = New-DemoResult -CheckId 'DEPLOY.TRACK.T2' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'Track T2 stopped at Artifacts: archost01 isn''t back.' -Remediation 'Fix the cause.'
        $rebuild = New-DemoResult -CheckId 'DEPLOY.T2.HOSTREBUILD' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'kept'
        $other = New-DemoResult -CheckId 'DEPLOY.ARTIFACTS.STALL_ARCHOST01' -Area 'infra' -Target 'T2' -Status 'Warning' -Message 'kept too'
        InModuleScope DbHubDemo -Parameters @{ Items = @($failed, $rebuild, $other) } { Set-DemoT2HostRebuildSuperseded -Result $Items }
        $failed.status | Should -Be 'Warning'
        $failed.message | Should -Be 'Track T2 stopped at Artifacts: archost01 isn''t back. deploy.ps1 then rebuilt archost01 (DEPLOY.T2.HOSTREBUILD).'
        $failed.remediation | Should -Match '^Nothing to do: deploy\.ps1 rebuilt archost01'
        $rebuild.status | Should -Be 'Fail'
        $other.message | Should -Be 'kept too'
    }

    It 'clears the old host''s records and says the template creates it, when the state records a host Azure doesn''t have' {
        $script:resets = 0
        Mock -ModuleName DbHubDemo -CommandName Reset-DemoT2HostRecord -MockWith { $script:resets++ }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show ' } -MockWith { New-AzAnswer -ExitCode 3 -StdErr $script:notFound }
        $state = [pscustomobject]@{ Exists = $true; Stage = 'Validation'; BundleSentTo = @('sqlvm01', 'archost01'); RunnerSentTo = @('sqlvm01', 'archost01'); TrackT2 = 'Telemetry' }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $state } { Get-DemoT2HostMissingResult -Config $Config -State $State }
        $result.checkId | Should -Be 'DEPLOY.T2.HOSTMISSING'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match '^archost01, T2''s host, doesn''t exist .* so this run deploys the template, which creates it again, and builds T2 on it'
        $script:resets | Should -Be 1
    }

    It 'does nothing for a host that exists, one that couldn''t be read, or one the state doesn''t record' {
        $script:resets = 0
        $script:answer = New-AzAnswer -StdOut '/subscriptions/x/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01'
        Mock -ModuleName DbHubDemo -CommandName Reset-DemoT2HostRecord -MockWith { $script:resets++ }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show ' } -MockWith { $script:answer }
        $state = [pscustomobject]@{ Exists = $true; Stage = 'Validation'; BundleSentTo = @('archost01'); RunnerSentTo = @(); TrackT2 = '' }
        $missing = { param($State) InModuleScope DbHubDemo -Parameters @{ Config = $config; State = $State } { Get-DemoT2HostMissingResult -Config $Config -State $State } }
        & $missing $state | Should -BeNullOrEmpty
        $script:answer = New-AzAnswer -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client does not have authorization.'
        & $missing $state | Should -BeNullOrEmpty
        & $missing ([pscustomobject]@{ Exists = $true; Stage = 'Validation'; BundleSentTo = @('sqlvm01'); RunnerSentTo = @('sqlvm01'); TrackT2 = '' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show ' } -Because 'a state without the host makes no call'
        $script:resets | Should -Be 0
    }

    It 'says in DONE what happened to the host: rebuilt, or created again at the start; nothing for a rebuild that failed' {
        $note = { param([object[]] $Items) InModuleScope DbHubDemo -Parameters @{ Items = $Items } { Get-DemoT2HostRebuildNote -Result $Items } }
        & $note @((New-DemoResult -CheckId 'DEPLOY.T2.HOSTREBUILD' -Area 'infra' -Target 'T2' -Status 'Warning' -Message 'x')) | Should -Match '^archost01, T2''s host, was rebuilt in this run: .*\(DEPLOY\.T2\.HOSTREBUILD\)\.$'
        & $note @((New-DemoResult -CheckId 'DEPLOY.T2.HOSTMISSING' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'x')) | Should -Match '\(DEPLOY\.T2\.HOSTMISSING\)\.$'
        & $note @((New-DemoResult -CheckId 'DEPLOY.T2.HOSTREBUILD' -Area 'infra' -Target 'T2' -Status 'Fail' -Message 'x')) | Should -Be ''
    }
}
