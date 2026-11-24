# Query Store's state on T1 to T4 (2026-11-23, user-directed: "We would want query store enabled wherever possible"):
# validate.ps1's T1.QUERYSTORE to T4.QUERYSTORE. T1 and T2 from the runner's status (its queryStore node, which the VM's
# relay keeps from the whole output), T3 from its status row (database/azuresql/900-status.sql), and T4 from its two
# parameters through Azure Resource Manager. Only validate.ps1 runs them: deploy.ps1's own T3 and T4 checks don't, so
# Query Store's state never stops a deployment. ASCII-only.

function Get-DemoSqlQueryStoreDocUrl {
    # sys.database_query_store_options: the states, and what each read-only reason means (checked 2026-11-23).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql'
}

function Get-DemoSqlQueryStoreFix {
    <#
    .SYNOPSIS
    How Query Store on T1, T2, or T3 gets back to READ_WRITE, from what was measured (2026-11-23; the review of the Query
    Store design, finding 6): a read-only reason from sys.database_query_store_options gets its own fix, from Learn, and
    only a state someone set (OFF, or READ_ONLY as the desired state) is what ./scripts/deploy.ps1 sets again. Returns
    Why (the reason in words, or ''), Fix, and Temporary (Learn says it ends by itself). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3')]
        [string] $Target,

        [AllowEmptyString()]
        [string] $ActualState = '',

        [AllowEmptyString()]
        [string] $DesiredState = '',

        [AllowNull()]
        [object] $ReadonlyReason
    )

    $deploy = switch ($Target) {
        'T1' { 'Run ./scripts/deploy.ps1: T1''s bootstrap runs database/sqlvm01/030-configure.sql again whenever Query Store isn''t READ_WRITE.' }
        'T2' { 'Run ./scripts/deploy.ps1: T2''s host runs database/arcsql01/030-configure.sql in the guest again whenever Query Store isn''t READ_WRITE.' }
        default { 'Run ./scripts/deploy.ps1: its T3 stage runs database/azuresql/030-configure.sql again from T1 (Invoke-DemoT3SqlFromT1 -Name Setup).' }
    }
    $reason = 0L
    if ($null -ne $ReadonlyReason -and [string]$ReadonlyReason -ne '') {
        $reason = [long]$ReadonlyReason
    }
    if ($ActualState -ne 'READ_ONLY' -or $DesiredState -ne 'READ_WRITE' -or $reason -eq 0) {
        # A state someone set (OFF, or READ_ONLY as its desired state), or ERROR: the configure script sets READ_WRITE again.
        return [pscustomobject]@{ Why = ''; Fix = $deploy; Temporary = $false }
    }
    $whys = [System.Collections.Generic.List[string]]::new()
    $fixes = [System.Collections.Generic.List[string]]::new()
    $temporaryOnly = $true
    $known = @{
        1      = @('ContosoCare is read-only', 'Set ContosoCare READ_WRITE again; Query Store follows it.')
        2      = @('ContosoCare is in single-user mode', 'Set ContosoCare MULTI_USER again; Query Store follows it.')
        4      = @('ContosoCare is in emergency mode', 'Bring ContosoCare back online; Query Store follows it.')
        8      = @('this is a secondary replica', 'Read Query Store on the primary.')
        65536  = @('Query Store reached its size limit (max_storage_size_mb)', 'Raise MAX_STORAGE_SIZE_MB or remove the queries you don''t need, then set OPERATION_MODE = READ_WRITE: ./scripts/deploy.ps1 only sets READ_WRITE, which lasts only while Query Store has room.')
        131072 = @('the number of different statements in Query Store reached its internal memory limit', 'Remove the queries you don''t need, or move to a higher service tier, as Learn advises; then set OPERATION_MODE = READ_WRITE.')
        262144 = @('the in-memory items waiting to be persisted on disk reached their internal memory limit, which Learn says is temporary', 'Nothing to do: Query Store is READ_WRITE again once those items are on disk. Check again in a few minutes.')
        524288 = @('ContosoCare reached its disk size limit', 'Free space in ContosoCare or raise its size limit, then set OPERATION_MODE = READ_WRITE.')
    }
    $left = $reason
    foreach ($bit in ($known.Keys | Sort-Object)) {
        if (($reason -band [long]$bit) -ne 0) {
            $whys.Add($known[$bit][0])
            $fixes.Add($known[$bit][1])
            $left = $left -band (-bnot [long]$bit)
            if ($bit -ne 262144) {
                $temporaryOnly = $false
            }
        }
    }
    if ($left -ne 0) {
        $whys.Add(('read-only reason {0}, which Learn doesn''t list' -f $left))
        $fixes.Add('See Learn''s read-only reasons, then set OPERATION_MODE = READ_WRITE.')
        $temporaryOnly = $false
    }
    return [pscustomobject]@{ Why = ($whys -join '; '); Fix = ($fixes -join ' '); Temporary = $temporaryOnly }
}

function ConvertTo-DemoSqlQueryStoreResult {
    <#
    .SYNOPSIS
    <Target>.QUERYSTORE for T1, T2, or T3 from Query Store's state in ContosoCare (2026-11-23): Pass when it's READ_WRITE,
    the state the demo's 030-configure.sql sets (AUTO capture, 15-minute intervals); Fail when it's OFF, READ_ONLY, or
    ERROR, with the measured reason and its fix (Get-DemoSqlQueryStoreFix); a Warning when Learn says the read-only
    state is temporary, or when the state couldn't be read (the error the read returned). State is the runner's
    queryStore node (actualState, desiredState, readonlyReason, captureMode, intervalMinutes, storageMb, maxStorageMb,
    or error), or the same names from T3's status row. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3')]
        [string] $Target,

        [AllowNull()]
        [object] $State,

        [string] $Source = 'the runner''s status'
    )

    $checkId = '{0}.QUERYSTORE' -f $Target
    $area = $Target.ToLowerInvariant()
    $docUrl = Get-DemoSqlQueryStoreDocUrl
    $values = @{}
    foreach ($name in 'actualState', 'desiredState', 'readonlyReason', 'captureMode', 'intervalMinutes', 'storageMb', 'maxStorageMb', 'error') {
        $values[$name] = Get-DemoMemberValue -InputObject $State -Name $name
    }
    $read = {
        param([string] $Name)
        $values[$Name]
    }
    $actual = [string](& $read 'actualState')
    $readError = [string](& $read 'error')
    $evidence = [ordered]@{ source = $Source }
    foreach ($name in 'actualState', 'desiredState', 'readonlyReason', 'captureMode', 'intervalMinutes', 'storageMb', 'maxStorageMb') {
        $evidence[$name] = & $read $name
    }
    if (-not $actual) {
        $why = if ($readError) { Protect-DemoText -Text $readError } else { 'it gave no state' }
        $evidence['error'] = $why
        return (New-DemoResult -CheckId $checkId -Area $area -Target $Target -Status 'Warning' -Message ('Query Store''s state in ContosoCare on {0} couldn''t be read from {1}: {2}' -f $Target, $Source, $why) -Evidence $evidence -Remediation 'Run ./scripts/validate.ps1 again in a few minutes; the read needs VIEW DATABASE STATE, which the runner''s sign-in has.' -DocUrl $docUrl)
    }
    $capture = [string](& $read 'captureMode')
    $interval = & $read 'intervalMinutes'
    $settings = @(
        $(if ($capture) { '{0} capture' -f $capture })
        $(if ($null -ne $interval) { '{0}-minute intervals' -f $interval })
        $(if ($null -ne (& $read 'storageMb') -and $null -ne (& $read 'maxStorageMb')) { '{0} of {1} MB' -f (& $read 'storageMb'), (& $read 'maxStorageMb') })
    ) | Where-Object { $_ }
    $detail = if ($settings) { ' ({0})' -f ($settings -join ', ') } else { '' }
    if ($actual -eq 'READ_WRITE') {
        return (New-DemoResult -CheckId $checkId -Area $area -Target $Target -Status 'Pass' -Message ('Query Store is on in ContosoCare on {0}: READ_WRITE{1}, so it keeps the queries'' plans and their runtime and wait statistics.' -f $Target, $detail) -Evidence $evidence -DocUrl $docUrl)
    }
    $desired = [string](& $read 'desiredState')
    $fix = Get-DemoSqlQueryStoreFix -Target $Target -ActualState $actual -DesiredState $desired -ReadonlyReason (& $read 'readonlyReason')
    $why = if ($fix.Why) { ' because {0}' -f $fix.Why } elseif ($desired -and $desired -ne $actual) { ' (its desired state is {0})' -f $desired } else { '' }
    $status = if ($fix.Temporary) { 'Warning' } else { 'Fail' }
    $consequence = if ($actual -eq 'READ_ONLY') { 'it keeps what it has but records nothing new' } else { 'it records no queries' }
    return (New-DemoResult -CheckId $checkId -Area $area -Target $Target -Status $status -Message ('Query Store in ContosoCare on {0} is {1}{2}{3}, so {4}.' -f $Target, $actual, $detail, $why, $consequence) -Evidence $evidence -Remediation $fix.Fix -DocUrl $docUrl)
}

function New-DemoQueryStoreUnreadResult {
    <#
    .SYNOPSIS
    <Target>.QUERYSTORE as a Warning (or Not selected) when its state wasn't read: the VM is stopped, the runner's status
    couldn't be read, or T3's status row wasn't (2026-11-23; the review of the Query Store design, finding 6: unread
    stays a Warning). Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [Parameter(Mandatory)]
        [string] $Why,

        [string] $Remediation = 'Run ./scripts/validate.ps1 again once it''s running.',

        [ValidateSet('Warning', 'Not selected')]
        [string] $Status = 'Warning'
    )

    $docUrl = if ($Target -eq 'T4') { [string](Get-DemoPostgresSetting)['queryStore']['docUrls']['queryStore'] } else { Get-DemoSqlQueryStoreDocUrl }
    return (New-DemoResult -CheckId ('{0}.QUERYSTORE' -f $Target) -Area $Target.ToLowerInvariant() -Target $Target -Status $Status -Message ('Query Store''s state on {0} wasn''t read: {1}' -f $Target, $Why) -Remediation $(if ($Status -eq 'Warning') { $Remediation } else { '' }) -DocUrl $docUrl)
}

function Test-DemoValidationWorkloadQueryStore {
    <#
    .SYNOPSIS
    T1.QUERYSTORE and T2.QUERYSTORE from the Workload area's status read (2026-11-23): the runner's queryStore node, which
    the VM's relay reads from the whole output (the result's evidence.queryStore), or else from the output's kept tail. A
    runner or relay from before it has neither: a Warning whose fix is ./scripts/deploy.ps1, which updates both. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2')]
        [string] $Target,

        [AllowNull()]
        [object] $Result,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $StdOut
    )

    $node = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Result -Name 'evidence') -Name 'queryStore'
    $source = 'the runner''s status'
    if ($null -eq $node) {
        $node = Get-DemoMemberValue -InputObject (ConvertFrom-DemoRunnerDocument -StdOut $StdOut) -Name 'queryStore'
    }
    if ($null -eq $node) {
        $where = if ($Target -eq 'T2') { 'in T2''s guest' } else { 'on sqlvm01' }
        return (New-DemoQueryStoreUnreadResult -Target $Target -Why ('the runner''s status has no Query Store state: the runner {0}, or the relay that reads its output, is from before 2026-11-23.' -f $where) -Remediation 'Run ./scripts/deploy.ps1, which updates the runner and the relay on both VMs; then ./scripts/validate.ps1 -Area Workload.')
    }
    return (ConvertTo-DemoSqlQueryStoreResult -Target $Target -State $node -Source $source)
}

function ConvertTo-DemoT4QueryStoreResult {
    <#
    .SYNOPSIS
    T4.QUERYSTORE from T4's two parameters, read through Azure Resource Manager (2026-11-23, ADR 0019): Pass when
    pg_qs.query_capture_mode is top or all and pgms_wait_sampling.query_capture_mode is all on a General Purpose or Memory
    Optimized size; Fail when Query Store is off there; a Warning with wait sampling off, or with Query Store on at
    Burstable, where Learn advises against it; Not supported at Burstable with it off, with the fix (a General Purpose
    t4SkuName). Capture and WaitSampling are Get-DemoT4ParameterState's reads; a read that failed is a Warning. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Tier = '',

        [AllowEmptyString()]
        [string] $SkuName = '',

        [Parameter(Mandatory)]
        [object] $Capture,

        [Parameter(Mandatory)]
        [object] $WaitSampling
    )

    $queryStore = (Get-DemoPostgresSetting)['queryStore']
    $docUrl = [string]$queryStore['docUrls']['queryStore']
    $captureValue = ([string](Get-DemoMemberValue -InputObject $Capture -Name 'Value')).ToLowerInvariant()
    $waitValue = ([string](Get-DemoMemberValue -InputObject $WaitSampling -Name 'Value')).ToLowerInvariant()
    $evidence = [ordered]@{ tier = $Tier; sku = $SkuName; queryCaptureMode = $captureValue; waitSamplingCaptureMode = $waitValue; wanted = [ordered]@{ queryCaptureMode = [string]$queryStore['queryCaptureMode']; waitSamplingCaptureMode = [string]$queryStore['waitSamplingCaptureMode'] } }
    $add = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'T4.QUERYSTORE' -Area 't4' -Target 'T4' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl
    }
    foreach ($read in @($Capture, $WaitSampling)) {
        if (-not [bool](Get-DemoMemberValue -InputObject $read -Name 'Found')) {
            $evidence['error'] = Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $read -Name 'Error'))
            return (& $add 'Warning' ('T4''s Query Store parameters couldn''t be read: {0}' -f $evidence['error']) 'Run ./scripts/validate.ps1 -Area T4 again.')
        }
    }
    $on = $captureValue -in 'top', 'all'
    if ($Tier -eq 'Burstable') {
        if ($on) {
            return (& $add 'Warning' ('Query Store is on at T4''s Burstable size ({0}; pg_qs.query_capture_mode {1}), where Learn says: "Don''t enable query store on the Burstable pricing tier as it causes performance problems".' -f $SkuName, $captureValue) 'Run ./scripts/deploy.ps1, which sets both Query Store parameters to none at a Burstable size; or set t4SkuName to a General Purpose size, where it stays on.')
        }
        return (& $add 'Not supported' ('Query Store is off at T4''s Burstable size ({0}), as Learn advises: "Don''t enable query store on the Burstable pricing tier as it causes performance problems".' -f $SkuName) 'To have it, remove t4SkuName (the default is General Purpose Standard_D4ds_v5) or set it to a General Purpose size, then run ./scripts/deploy.ps1.')
    }
    if (-not $on) {
        return (& $add 'Fail' ('Query Store is off on T4 ({0}; pg_qs.query_capture_mode {1}), so it records no queries.' -f $SkuName, $(if ($captureValue) { $captureValue } else { 'unknown' })) 'Run ./scripts/deploy.ps1: the template sets pg_qs.query_capture_mode to all at every size but Burstable, a dynamic parameter, so setting it restarts nothing.')
    }
    if ($waitValue -ne 'all') {
        return (& $add 'Warning' ('Query Store is on on T4 (pg_qs.query_capture_mode {0}), but its wait sampling is off (pgms_wait_sampling.query_capture_mode {1}), so it records no waits per query.' -f $captureValue, $(if ($waitValue) { $waitValue } else { 'unknown' })) 'Run ./scripts/deploy.ps1: the template sets pgms_wait_sampling.query_capture_mode to all, a dynamic parameter, so setting it restarts nothing.')
    }
    $nested = if ($captureValue -eq 'all') { 'top-level and nested statements' } else { 'top-level statements only' }
    return (& $add 'Pass' ('Query Store is on on T4 ({0}): pg_qs.query_capture_mode {1} ({2}) and its wait sampling all, in the azure_sys database (query_store.qs_view and query_store.pgms_wait_sampling_view).' -f $SkuName, $captureValue, $nested))
}
