BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

# 2026-11-23 (user-directed: "We would want query store enabled wherever possible"): validate.ps1's T1.QUERYSTORE to
# T3.QUERYSTORE, from Query Store's state in ContosoCare (scripts/modules/DbHubDemo/Private/QueryStoreHelpers.ps1). Its fix
# follows the measured reason, never a redeploy for every READ_ONLY (the review of the Query Store design, finding 6).
Describe 'Query Store on T1 to T3 (2026-11-23)' {
    It 'passes READ_WRITE, with its settings in the message' {
        $state = [ordered]@{ actualState = 'READ_WRITE'; desiredState = 'READ_WRITE'; readonlyReason = 0; captureMode = 'AUTO'; intervalMinutes = 15; storageMb = 12; maxStorageMb = 1024 }
        $result = InModuleScope DbHubDemo -Parameters @{ State = $state } { ConvertTo-DemoSqlQueryStoreResult -Target 'T1' -State $State }
        $result.checkId | Should -Be 'T1.QUERYSTORE'
        $result.area | Should -Be 't1'
        $result.status | Should -Be 'Pass'
        $result.message | Should -Be 'Query Store is on in ContosoCare on T1: READ_WRITE (AUTO capture, 15-minute intervals, 12 of 1024 MB), so it keeps the queries'' plans and their runtime and wait statistics.'
        $result.docUrl | Should -Be 'https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql'
    }

    It 'fails <Target>''s Query Store that someone turned <Actual>, with the redeploy that sets it again' -ForEach @(
        @{ Target = 'T1'; Actual = 'OFF'; Desired = 'OFF'; Fix = 'T1''s bootstrap runs database/sqlvm01/030-configure\.sql again' }
        @{ Target = 'T2'; Actual = 'READ_ONLY'; Desired = 'READ_ONLY'; Fix = 'T2''s host runs database/arcsql01/030-configure\.sql in the guest again' }
        @{ Target = 'T3'; Actual = 'ERROR'; Desired = 'READ_WRITE'; Fix = 'its T3 stage runs database/azuresql/030-configure\.sql again' }
    ) {
        $state = @{ actualState = $Actual; desiredState = $Desired; readonlyReason = 0 }
        $result = InModuleScope DbHubDemo -Parameters @{ Target = $Target; State = $state } { ConvertTo-DemoSqlQueryStoreResult -Target $Target -State $State }
        $result.status | Should -Be 'Fail'
        $result.area | Should -Be $Target.ToLowerInvariant()
        $result.message | Should -Match ('^Query Store in ContosoCare on {0} is {1}' -f $Target, $Actual)
        $result.remediation | Should -Match ('^Run \./scripts/deploy\.ps1: ' + $Fix)
    }

    It 'gives READ_ONLY''s measured reason its own fix: <Name>' -ForEach @(
        @{ Name = 'the size limit'; Reason = 65536; Status = 'Fail'; Why = 'because Query Store reached its size limit \(max_storage_size_mb\)'; Fix = '^Raise MAX_STORAGE_SIZE_MB or remove the queries you don''t need, then set OPERATION_MODE = READ_WRITE: \./scripts/deploy\.ps1 only sets READ_WRITE' }
        @{ Name = 'the statements'' memory limit'; Reason = 131072; Status = 'Fail'; Why = 'different statements in Query Store reached its internal memory limit'; Fix = 'move to a higher service tier' }
        @{ Name = 'items waiting for the disk, temporary'; Reason = 262144; Status = 'Warning'; Why = 'which Learn says is temporary'; Fix = '^Nothing to do: Query Store is READ_WRITE again once those items are on disk' }
        @{ Name = 'a full database'; Reason = 524288; Status = 'Fail'; Why = 'ContosoCare reached its disk size limit'; Fix = '^Free space in ContosoCare' }
        @{ Name = 'a read-only database'; Reason = 1; Status = 'Fail'; Why = 'ContosoCare is read-only'; Fix = '^Set ContosoCare READ_WRITE again' }
        @{ Name = 'two reasons at once'; Reason = 65536 + 262144; Status = 'Fail'; Why = 'size limit .*; the in-memory items'; Fix = 'Raise MAX_STORAGE_SIZE_MB.* Nothing to do' }
        @{ Name = 'a reason Learn doesn''t list'; Reason = 1048576; Status = 'Fail'; Why = 'read-only reason 1048576, which Learn doesn''t list'; Fix = 'Learn''s read-only reasons' }
    ) {
        $state = @{ actualState = 'READ_ONLY'; desiredState = 'READ_WRITE'; readonlyReason = $Reason; captureMode = 'AUTO'; intervalMinutes = 15; storageMb = 1024; maxStorageMb = 1024 }
        $result = InModuleScope DbHubDemo -Parameters @{ State = $state } { ConvertTo-DemoSqlQueryStoreResult -Target 'T1' -State $State }
        $result.status | Should -Be $Status
        $result.message | Should -Match $Why
        $result.message | Should -Match 'so it keeps what it has but records nothing new\.$'
        $result.remediation | Should -Match $Fix
        $result.remediation | Should -Not -Match '^Run \./scripts/deploy\.ps1' -Because 'a redeploy only sets READ_WRITE, which the measured reason undoes'
    }

    It 'is a Warning with the read''s error when the state couldn''t be read' {
        $result = InModuleScope DbHubDemo { ConvertTo-DemoSqlQueryStoreResult -Target 'T2' -State ([pscustomobject]@{ error = '300: VIEW DATABASE STATE permission denied in database ''ContosoCare''.' }) }
        $result.status | Should -Be 'Warning'
        $result.message | Should -Be 'Query Store''s state in ContosoCare on T2 couldn''t be read from the runner''s status: 300: VIEW DATABASE STATE permission denied in database ''ContosoCare''.'
    }
}

Describe 'T1.QUERYSTORE and T2.QUERYSTORE from the Workload area''s status read (2026-11-23)' {
    It 'reads the state the VM''s relay kept from the whole output' {
        $result = [pscustomobject]@{ evidence = [pscustomobject]@{ queryStore = [pscustomobject]@{ actualState = 'READ_WRITE'; desiredState = 'READ_WRITE'; readonlyReason = 0; captureMode = 'AUTO'; intervalMinutes = 15; storageMb = 3; maxStorageMb = 512 } } }
        $check = InModuleScope DbHubDemo -Parameters @{ Result = $result } { Test-DemoValidationWorkloadQueryStore -Target 'T2' -Result $Result -StdOut '...{"host":{"status":"Pass"}}' }
        $check.checkId | Should -Be 'T2.QUERYSTORE'
        $check.area | Should -Be 't2'
        $check.status | Should -Be 'Pass'
        $check.message | Should -Match '3 of 512 MB'
    }

    It 'reads it from the kept output when a relay from before it kept none' {
        $stdout = '{"target":"T1","profile":{"name":"off"},"runs":[],"queryStore":{"actualState":"OFF","desiredState":"OFF","readonlyReason":0},"host":{"status":"Pass"}}'
        $check = InModuleScope DbHubDemo -Parameters @{ StdOut = $stdout } { Test-DemoValidationWorkloadQueryStore -Target 'T1' -Result ([pscustomobject]@{ evidence = [pscustomobject]@{} }) -StdOut $StdOut }
        $check.status | Should -Be 'Fail'
        $check.message | Should -Match '^Query Store in ContosoCare on T1 is OFF'
    }

    It 'is a Warning whose fix is ./scripts/deploy.ps1 when the runner is from before it' {
        $check = InModuleScope DbHubDemo { Test-DemoValidationWorkloadQueryStore -Target 'T1' -Result ([pscustomobject]@{ evidence = [pscustomobject]@{ profile = @{ name = 'off' } } }) -StdOut '...,"host":{"status":"Pass"}}' }
        $check.status | Should -Be 'Warning'
        $check.message | Should -Match 'from before 2026-11-23'
        $check.remediation | Should -Match '^Run \./scripts/deploy\.ps1, which updates the runner and the relay on both VMs'
    }
}
