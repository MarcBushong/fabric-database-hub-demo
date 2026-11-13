# T4's read replica (2026-11-13, user-directed; ADR 0025): a same-region read replica of T4 created for each session and
# deleted after it. These tests cover what the live probe of 2026-11-13 found and the user's rules: the sizes it tries
# (never fewer vCores than T4, cheapest first, the record of a size Azure refused), the fallback's notice with its price,
# a Burstable T4 (Not supported, never silent), environments deployed before the replica (the upgrade's command, nothing
# changed), Azure's power order, and its deletion. Azure is mocked at the helpers; IDs are obviously fake, and prices are
# fixtures, never real ones (ADR 0016). The cost estimate's part is in DbHubDemo.Cost.Tests.ps1, the runbooks' in
# Automation.Runbooks.Tests.ps1.
BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig([string] $SkuName = '') {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        if ($SkuName) {
            $config['t4SkuName'] = $SkuName
        }
        return $config
    }

    $script:t4Id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgflex01-abc123'

    function New-T4State([string] $SkuName = 'Standard_D4ds_v5', [string] $State = 'Ready', [string] $Zone = '2') {
        $tier = if ($SkuName -like 'Standard_B*') { 'Burstable' } else { 'GeneralPurpose' }
        [pscustomobject]@{
            Names    = [pscustomobject]@{ ServerName = 'pgflex01-abc123'; ServerId = $script:t4Id; ResourceGroup = 'rg-dbhub-demo'; Enabled = $true }
            Exists   = $true
            Present  = $true
            Removing = $false
            State    = $State
            Server   = [pscustomobject]@{
                location   = 'westus3'
                sku        = [pscustomobject]@{ name = $SkuName; tier = $tier }
                properties = [pscustomobject]@{
                    state            = $State
                    availabilityZone = $Zone
                    network          = [pscustomobject]@{ delegatedSubnetResourceId = '/subscriptions/x/subnets/snet-pg'; privateDnsZoneArmResourceId = '/subscriptions/x/privateDnsZones/zone' }
                    storage          = [pscustomobject]@{ storageSizeGB = 32; tier = 'P4' }
                }
            }
            Error    = ''
        }
    }

    function New-ReplicaState([string] $State = 'NotFound', [string] $SkuName = '', [string] $Zone = '') {
        $names = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4ReplicaName -Config $Config -DeploymentId 'abc123' }
        $present = $State -notin 'NotFound', 'Unknown'
        [pscustomobject]@{ Names = $names; Exists = ($present -and $State -ne 'Dropping'); Present = $present; Removing = ($State -eq 'Dropping'); State = $State; Server = $null; SkuName = $SkuName; Zone = $Zone; Role = $(if ($present) { 'AsyncReplica' } else { '' }); SourceId = $(if ($present) { $script:t4Id } else { '' }); Error = '' }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'The sizes the replica tries: never fewer vCores than T4, cheapest first (ADR 0025)' {
    It 'tries T4''s size, then once in another zone, then the same-vCore peer, for <T4>' -ForEach @(
        @{ T4 = 'Standard_D4ds_v5'; Expected = @('Standard_D4ds_v5@', 'Standard_D4ds_v5@3', 'Standard_D4ads_v5@') }
        @{ T4 = 'Standard_D4ads_v5'; Expected = @('Standard_D4ads_v5@', 'Standard_D4ads_v5@3', 'Standard_D4ds_v5@') }
        @{ T4 = 'Standard_D2ds_v5'; Expected = @('Standard_D2ds_v5@', 'Standard_D2ds_v5@3', 'Standard_D4ds_v5@', 'Standard_D4ads_v5@') }
    ) {
        $order = InModuleScope DbHubDemo -Parameters @{ T4 = $T4 } { Get-DemoT4ReplicaSizeOrder -T4SkuName $T4 -Zone @('3', '1') }
        @($order | ForEach-Object { '{0}@{1}' -f $_.SkuName, $_.Zone }) | Should -Be $Expected
    }

    It 'starts with a recorded size that has T4''s vCores, asks for T4''s size before a larger recorded one, and ignores a smaller or unknown one' {
        $peer = InModuleScope DbHubDemo { Get-DemoT4ReplicaSizeOrder -T4SkuName 'Standard_D4ds_v5' -Record 'Standard_D4ads_v5@any' -Zone @('3') }
        @($peer | ForEach-Object { '{0}@{1}' -f $_.SkuName, $_.Zone }) | Should -Be @('Standard_D4ads_v5@', 'Standard_D4ds_v5@', 'Standard_D4ds_v5@3')
        # A larger fallback costs more, so each session asks for T4's own size first.
        $larger = InModuleScope DbHubDemo { Get-DemoT4ReplicaSizeOrder -T4SkuName 'Standard_D2ds_v5' -Record 'Standard_D4ds_v5@2' -Zone @('3') }
        @($larger | ForEach-Object { '{0}@{1}' -f $_.SkuName, $_.Zone }) | Should -Be @('Standard_D2ds_v5@', 'Standard_D2ds_v5@3', 'Standard_D4ds_v5@2', 'Standard_D4ds_v5@', 'Standard_D4ads_v5@')
        foreach ($record in 'Standard_D2ds_v5@any', 'Standard_E8ds_v5@any', 'garbage') {
            $order = InModuleScope DbHubDemo -Parameters @{ Record = $record } { Get-DemoT4ReplicaSizeOrder -T4SkuName 'Standard_D4ds_v5' -Record $Record }
            $order[0].SkuName | Should -Be 'Standard_D4ds_v5' -Because ('{0} isn''t a size the replica can keep' -f $record)
            @($order | Where-Object { $_.SkuName -match '^Standard_[A-Z]+2' }) | Should -BeNullOrEmpty -Because 'a replica never has fewer vCores than T4'
        }
    }
}

Describe 'A Burstable T4 has no replica, and says so with the fix (never silently)' {
    It 'is Not supported in preflight, in support, and in the DONE requirements, with the fix' {
        $preflight = InModuleScope DbHubDemo { New-DemoT4ReplicaPreflightResult -SkuName 'Standard_B1ms' }
        $preflight.checkId | Should -Be 'PREFLIGHT.T4.REPLICA'
        $preflight.status | Should -Be 'Not supported'
        $preflight.message | Should -Match 'Burstable size Standard_B1ms, and Azure supports read replicas only on the General Purpose and Memory Optimized tiers'
        $preflight.remediation | Should -Match 'remove t4SkuName .+ then run \./scripts/deploy\.ps1'
        (InModuleScope DbHubDemo { New-DemoT4ReplicaPreflightResult -SkuName 'Standard_D4ds_v5' }).status | Should -Be 'Pass'
        $support = InModuleScope DbHubDemo -Parameters @{ T4 = (New-T4State -SkuName 'Standard_B1ms') } { Get-DemoT4ReplicaSupport -T4State $T4 }
        $support.Reason | Should -Be 'Burstable'
        $support.Supported | Should -BeFalse
        $missing = InModuleScope DbHubDemo { Get-DemoT4ReplicaSupport -T4State ([pscustomobject]@{ Exists = $false }) }
        $missing.Reason | Should -Be 'NoT4'
        # DONE's evidence: a Burstable T4's Not supported meets the replica's requirements, as the user's rule says.
        $done = InModuleScope DbHubDemo {
            $requirements = @(Get-DemoDoneRequirement)
            $notSupported = @(New-DemoT4ReplicaNotSupportedResult -CheckId 'HUB.ESTATE.T4.REPLICA' -T4SkuName 'Standard_B1ms'; New-DemoT4ReplicaNotSupportedResult -CheckId 'METRICS.T4.REPLICA' -T4SkuName 'Standard_B1ms')
            $warning = New-DemoResult -CheckId 'METRICS.T4.REPLICA' -Area 't4' -Target 'T4' -Status 'Warning' -Message 'No lag yet.'
            [pscustomobject]@{ Ids = $requirements; Met = (Test-DemoDoneEvidence -Requirement @('HUB.ESTATE.T4.REPLICA', 'METRICS.T4.REPLICA') -Result $notSupported); Open = (Test-DemoDoneEvidence -Requirement @('METRICS.T4.REPLICA') -Result @($warning)) }
        }
        $done.Ids | Should -Contain 'HUB.ESTATE.T4.REPLICA'
        $done.Ids | Should -Contain 'METRICS.T4.REPLICA'
        $done.Met.Complete | Should -BeTrue
        $done.Open.Complete | Should -BeFalse -Because 'only Pass, or Not supported on a Burstable T4, meets it'
    }
}

Describe 'An environment deployed before the replica: start, stop, status, and validate change nothing and name the upgrade (ADR 0025)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        # deploy.ps1 from before 2026-11-13 left no DbHubT4Replica tag.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T4Replica = ''; T4ReplicaSize = ''; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { New-T4State }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoT4ReplicaTemplate -MockWith { throw 'nothing is created before deploy.ps1 sets the replica up' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { throw ('unexpected Azure CLI call: {0}' -f (@($ArgumentList) -join ' ')) }
    }

    It 'start-demo.ps1''s step: Not selected, with ./scripts/deploy.ps1, and no Azure read' {
        $context = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Start-DemoT4ReplicaCreate -Config $Config -DeploymentId 'abc123' -CheckPrefix START -Confirm:$false }
        $context.Done | Should -BeTrue
        $result = @($context.Results)[0]
        $result.checkId | Should -Be 'START.T4.REPLICA'
        $result.status | Should -Be 'Not selected'
        $result.message | Should -Match 'isn''t deployed yet: this environment was deployed before the replica existed, so nothing was done for it'
        $result.remediation | Should -Match '^Run \./scripts/deploy\.ps1: it adds the replica \(about 9 minutes\) and changes nothing else'
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoT4State -Times 0 -Exactly
    }

    It 'status.ps1 and validate.ps1: a Warning with the same command' {
        $status = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4ReplicaStatusResult -Config $Config -DeploymentId 'abc123' }
        $status.checkId | Should -Be 'STATUS.T4.REPLICA'
        $status.status | Should -Be 'Warning'
        $status.remediation | Should -Match '^Run \./scripts/deploy\.ps1'
        $validate = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Test-DemoT4ReplicaServer -Config $Config -DeploymentId 'abc123' }
        $validate.checkId | Should -Be 'T4.REPLICA'
        $validate.status | Should -Be 'Warning'
    }

    It 'T4''s start finds no replica to start first, and goes on' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'NotFound' }
        $replica = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4ReplicaStartFirst -Config $Config -DeploymentId 'abc123' -CheckPrefix START }
        $replica | Should -BeNullOrEmpty
    }
}

Describe 'Creating the replica: the fallback, its notice, and Azure''s refusals (ADR 0025)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T4Replica = 'Session'; T4ReplicaSize = ''; Tags = @{ deploymentId = 'abc123' } } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { New-T4State }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ParameterState -MockWith { [pscustomobject]@{ Found = $true; Value = '50'; PendingRestart = $false } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4SkuZone -MockWith { @('1', '2', '3') }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4HourlyPrice -MockWith { if ($SkuName -eq 'Standard_D4ads_v5') { 0.5 } else { 0.4 } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'NotFound' }
        $script:sent = [System.Collections.Generic.List[string]]::new()
        $script:outcomes = [System.Collections.Generic.Queue[string]]::new()
        $script:recorded = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName DbHubDemo -CommandName Send-DemoT4ReplicaTemplate -MockWith { $script:sent.Add(('{0}@{1}' -f $SkuName, $Zone)); [pscustomobject]@{ ExitCode = 0; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaTemplate -MockWith { $script:outcomes.Dequeue() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ReplicaCreateFailure -MockWith {
            $last = $script:sent[$script:sent.Count - 1].Split('@')
            [pscustomobject]@{ Code = $script:failureCode; Text = 'A fake error.'; Sku = $last[0]; Zone = $last[1]; TimeUtc = '2026-11-13T12:00:00Z' }
        }
        $script:failureCode = 'SkuNotAvailable'
        # Before the creation it isn't there; after a refusal its shell is Dropping; after a success it's Ready.
        $script:replicaReads = 0
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ReplicaState -MockWith {
            $script:replicaReads++
            if ($script:replicaReads -eq 1) { return (New-ReplicaState -State 'NotFound') }
            if ($script:outcomes.Count -gt 0) { return (New-ReplicaState -State 'Dropping') }
            $last = $script:sent[$script:sent.Count - 1].Split('@')
            return (New-ReplicaState -State 'Ready' -SkuName $last[0] -Zone $(if ($last[1]) { $last[1] } else { '2' }))
        }
    }

    It 'creates it at T4''s size, records it, and marks the environment as set up (deploy.ps1)' {
        $script:outcomes.Enqueue('Succeeded')
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Record = { param($Values) $script:recorded.Add($Values) } } { Invoke-DemoT4ReplicaCreate -Config $Config -DeploymentId 'abc123' -CheckPrefix DEPLOY -RecordState $Record -Confirm:$false })
        @($script:sent) | Should -Be @('Standard_D4ds_v5@')
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'DEPLOY.T4.REPLICA'
        $results[0].status | Should -Be 'Pass'
        $results[0].message | Should -Match 'was created as Standard_D4ds_v5 in zone 2 .+ Database Hub''s Estate lists it, and its PostgreSQL dashboard charts its Read replica lag'
        $script:recorded[0]['T4ReplicaSize'] | Should -Be 'Standard_D4ds_v5@any'
        $script:recorded[0]['T4Replica'] | Should -Be 'Session'
    }

    It 'goes on after SkuNotAvailable, waits for the refused shell, and says what it tried, what it created, and the price difference' {
        $script:outcomes.Enqueue('Failed')
        $script:outcomes.Enqueue('Failed')
        $script:outcomes.Enqueue('Succeeded')
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Record = { param($Values) $script:recorded.Add($Values) } } { Invoke-DemoT4ReplicaCreate -Config $Config -DeploymentId 'abc123' -CheckPrefix START -RecordState $Record -Confirm:$false })
        @($script:sent) | Should -Be @('Standard_D4ds_v5@', 'Standard_D4ds_v5@1', 'Standard_D4ads_v5@')
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaState -Times 2 -Exactly -ParameterFilter { @($State) -contains 'NotFound' }
        $notice = $results | Where-Object checkId -EQ 'START.T4.REPLICA.FALLBACK'
        $notice.status | Should -Be 'Warning'
        $notice.message | Should -Match '^T4''s read replica was created as Standard_D4ads_v5 \(no zone preference\), where T4''s size Standard_D4ds_v5 was asked for, because Azure refused Standard_D4ds_v5 \(no zone preference\), Standard_D4ds_v5 in zone 1 \(SkuNotAvailable\)\.'
        $notice.message | Should -Match 'about 0\.500 USD an hour of compute while it exists, against 0\.400 USD at Standard_D4ds_v5: \+0\.100 USD an hour, about \+0\.50 USD for a 5-hour session'
        $notice.remediation | Should -Match 'the next replica starts at this size \(recorded as DbHubT4ReplicaSize\), which has T4''s vCores'
        $script:recorded[0]['T4ReplicaSize'] | Should -Be 'Standard_D4ads_v5@any'
        $script:recorded[0].Contains('T4Replica') | Should -BeFalse -Because 'start-demo.ps1 doesn''t set the environment up; deploy.ps1 does'
    }

    It 'ends with a Fail for deploy.ps1, with the Region access request, when Azure refuses every size, and records nothing' {
        foreach ($i in 1..3) {
            $script:outcomes.Enqueue('Failed')
        }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Record = { param($Values) $script:recorded.Add($Values) } } { Invoke-DemoT4ReplicaCreate -Config $Config -DeploymentId 'abc123' -CheckPrefix DEPLOY -RecordState $Record -Confirm:$false })
        $main = $results | Where-Object checkId -EQ 'DEPLOY.T4.REPLICA'
        $main.status | Should -Be 'Fail'
        $main.message | Should -Match 'Azure refused every size it can have \(SkuNotAvailable\): Standard_D4ds_v5 \(no zone preference\), Standard_D4ds_v5 in zone 1, Standard_D4ads_v5 \(no zone preference\)'
        $main.remediation | Should -Match '^Ask for access with a Region access request for Azure Database for PostgreSQL flexible server in westus3 .+ then run \./scripts/deploy\.ps1'
        $script:recorded.Count | Should -Be 0
    }

    It 'stops at an error that isn''t a refusal, without trying another size: a Warning for start-demo.ps1' {
        $script:failureCode = 'Other'
        $script:outcomes.Enqueue('Failed')
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4ReplicaCreate -Config $Config -DeploymentId 'abc123' -CheckPrefix START -Confirm:$false })
        @($script:sent) | Should -Be @('Standard_D4ds_v5@')
        ($results | Where-Object checkId -EQ 'START.T4.REPLICA').status | Should -Be 'Warning'
    }

    It 'doesn''t create a replica of a T4 that isn''t Ready (Azure refuses: ReadReplicaServerInUnexpectedState)' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { New-T4State -State 'Stopped' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4ReplicaCreate -Config $Config -DeploymentId 'abc123' -CheckPrefix START -Confirm:$false })
        $script:sent.Count | Should -Be 0
        $results[0].status | Should -Be 'Warning'
        $results[0].message | Should -Match 'is Stopped, not Ready, so its read replica wasn''t created'
    }
}

Describe 'Azure''s power order, and deleting the replica (live, 2026-11-13)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ T4Replica = 'Session'; T4ReplicaSize = ''; Tags = @{ deploymentId = 'abc123' } } }
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { $script:azCalls.Add((@($ArgumentList) -join ' ')); [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzWithConflictRetry -MockWith { $script:azCalls.Add((@($ArgumentList) -join ' ')); [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
    }

    It 'starts a stopped replica before T4 and waits for it to be Ready, because Azure starts T4 only after its replicas' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'Stopped' -SkuName 'Standard_D4ds_v5' }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'Ready' -SkuName 'Standard_D4ds_v5' }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Invoke-DemoT4ReplicaStartFirst -Config $Config -DeploymentId 'abc123' -CheckPrefix START }
        $result.status | Should -Be 'Pass'
        @($script:azCalls | Where-Object { $_ -match '--method post --url \S+/flexibleServers/pgreplica01-abc123/start\?' }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaState -Times 1 -Exactly -ParameterFilter { @($State) -contains 'Ready' }
    }

    It 'deletes a replica with az rest (the CLI''s delete has no --no-wait), and does nothing when there''s none' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'Ready' -SkuName 'Standard_D4ds_v5' }
        Mock -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'NotFound' }
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Remove-DemoT4Replica -Config $Config -DeploymentId 'abc123' -CheckPrefix STOP -Confirm:$false }
        $result.checkId | Should -Be 'STOP.T4.REPLICA'
        $result.status | Should -Be 'Pass'
        @($script:azCalls | Where-Object { $_ -match '^rest --method delete --url \S+/flexibleServers/pgreplica01-abc123\?' }).Count | Should -Be 1
        $script:azCalls.Clear()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoT4ReplicaState -MockWith { New-ReplicaState -State 'NotFound' }
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Remove-DemoT4Replica -Config $Config -DeploymentId 'abc123' -CheckPrefix DESTROY -Quiet -Confirm:$false } | Should -BeNullOrEmpty
        $script:azCalls.Count | Should -Be 0
    }
}

Describe 'The history keeps the session''s lag: captured before stop-demo.ps1 deletes the replica (ADR 0025)' {
    It 'stop-demo.ps1 captures the metrics before it sends the delete, and hands them to the notebook' {
        # Azure Monitor answers ResourceNotFound for a deleted replica's metrics (live, 2026-11-13), so the order matters.
        $source = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/Public/Stop-DemoEnvironment.ps1') -Raw
        $capture = $source.IndexOf('Get-DemoPostgresHistoryCapture', [System.StringComparison]::Ordinal)
        $delete = $source.IndexOf('Remove-DemoT4Replica', [System.StringComparison]::Ordinal)
        $capture | Should -BeGreaterThan 0
        $delete | Should -BeGreaterThan $capture
        $source | Should -Match '-PostgresMetrics'
    }

    It 'keeps the captured metrics in a file, with the command that adds them to the history, and says the replica''s are otherwise gone' {
        $json = '{"version":1,"servers":[{"role":"primary","target":"T4","resourceName":"pgflex01-abc123","sku":"Standard_D4ds_v5"},{"role":"replica","target":"T4-replica","resourceName":"pgreplica01-abc123","sku":"Standard_D4ds_v5"}],"series":[{"resourceName":"pgreplica01-abc123","role":"replica","metric":"physical_replication_delay_in_seconds","aggregation":"Maximum","unit":"Seconds","points":[["2026-11-13T17:00:00Z",6],["2026-11-13T17:05:00Z",245]]}]}'
        $folder = Join-Path -Path $TestDrive -ChildPath 'history-pending'
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Json = $json; Folder = $folder } {
            Save-DemoPostgresHistoryPending -Config $Config -Json $Json -Directory $Folder -NowUtc ([datetime]::new(2026, 11, 13, 19, 0, 0, [System.DateTimeKind]::Utc)) -Confirm:$false
        }
        $result.checkId | Should -Be 'STOP.T4.HISTORY.PENDING'
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'replica is deleted, and Azure Monitor no longer has its metrics'
        $result.message | Should -Match 'Read replica lag up to 245 s'
        $path = @(Get-ChildItem -LiteralPath $folder -Filter 'postgres-metrics-rg-*-20261113T190000Z.json' -File -Force)[0].FullName
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $json
        $result.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath ' + $path))

        # Nothing captured: nothing to keep, and nothing said.
        InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Folder = $folder } { Save-DemoPostgresHistoryPending -Config $Config -Json '' -Directory $Folder -Confirm:$false } | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $folder -File).Count | Should -Be 1
    }

    It 'says the session''s metrics are lost when the file can''t be written' {
        $blocked = Join-Path -Path $TestDrive -ChildPath 'blocked'
        Set-Content -LiteralPath $blocked -Value 'a file where the folder would go'
        $result = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig); Folder = (Join-Path -Path $blocked -ChildPath 'pending') } {
            Save-DemoPostgresHistoryPending -Config $Config -Json '{"version":1,"servers":[],"series":[]}' -Directory $Folder -Confirm:$false
        }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Match 'couldn''t be kept either'
        $result.message | Should -Match 'so this session''s are lost'
    }
}
