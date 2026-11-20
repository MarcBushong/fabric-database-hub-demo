# The Database Agent loop on T3 (2026-11-18): FORCE_LAST_GOOD_PLAN, which plan-regression's Database Agent beat turns off
# from the regression to its response (demo.auto_tuning_hold), and what Database Agents needs from T3, read where an API
# documents it. Database Agents itself has no API: its one-time selection is made in Database Hub, and only a person can
# confirm it (HUB.AGENT.T3).
# - Database Agents: https://learn.microsoft.com/fabric/database/hub/database-agents
# - Enable and activate Database Agents: https://learn.microsoft.com/fabric/database/hub/enable-database-agents
# - Limitations and troubleshooting: https://learn.microsoft.com/fabric/database/hub/database-agents-known-limitations
# - Database Automatic Tuning (REST): https://learn.microsoft.com/rest/api/sql/database-automatic-tuning
# - Permissions - List For Resource: https://learn.microsoft.com/rest/api/authorization/permissions/list-for-resource

$script:DemoAgentDocUrl = 'https://learn.microsoft.com/fabric/database/hub/enable-database-agents'
$script:DemoAutoTuningDocUrl = 'https://learn.microsoft.com/azure/azure-sql/database/automatic-tuning-overview'
# The Agent policy options the beat's issues need (Learn's UI labels): the regression, its long-running lookup, and T3's CPU.
$script:DemoAgentPolicy = @('Flag long-running queries', 'Force last known good plans', 'Flag high CPU')
# A Save checks every selected database and fails as a whole if any fails (Learn, checked 2026-11-20), and Database Hub
# keeps a deleted database selected (live, 2026-11-20: an earlier destroy's T3s failed the owner's Save with this error).
# Its list names databases without their server, so every environment's T3 is a row named ContosoCare.
$script:DemoAgentSaveError = 'Database agent changes couldn''t be saved'
$script:DemoAgentLookAlike = 'The list names databases without their server: when several are named ContosoCare, clear the selection, then check one ContosoCare row at a time and Save, and uncheck any whose Save fails'

function Get-DemoT3AgentUri {
    <#
    .SYNOPSIS
    T3's database's Azure Resource Manager URL, with -Path after it and -ApiType's API version from config/versions.json.
    Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^azuresql01-[a-z0-9]{6}$')]
        [string] $ServerName,

        [ValidateSet('automaticTuning/current', 'providers/Microsoft.Authorization/permissions')]
        [string] $Path = 'automaticTuning/current'
    )

    $apiType = if ($Path -like 'providers/*') { 'Microsoft.Authorization/permissions' } else { 'Microsoft.Sql/servers/databases/automaticTuning' }
    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $apiVersion = [string]$versions['apiVersions'][$apiType]
    if (-not $apiVersion) {
        throw ('config/versions.json has no API version for {0}.' -f $apiType)
    }
    return ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Sql/servers/{2}/databases/ContosoCare/{3}?api-version={4}' -f [string]$Config['subscriptionId'], (Get-DemoResourceGroupName -Config $Config), $ServerName, $Path, $apiVersion)
}

function Get-DemoT3AutoTuning {
    <#
    .SYNOPSIS
    T3's FORCE_LAST_GOOD_PLAN, read with Database Automatic Tuning - Get: Read, Desired (Default, On, or Off), Actual (On
    or Off), Reason (reasonDesc), and Error. Call it only while T3 is Online: a paused serverless database can resume to
    answer it. A read. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^azuresql01-[a-z0-9]{6}$')]
        [string] $ServerName
    )

    $response = Invoke-DemoRestRequest -SubscriptionId ([string]$Config['subscriptionId']) -Method GET -Uri (Get-DemoT3AgentUri -Config $Config -ServerName $ServerName)
    if ($response.ExitCode -ne 0) {
        return [pscustomobject]@{ Read = $false; Desired = ''; Actual = ''; Reason = ''; Error = (Protect-DemoText -Text $(if ($response.StdErr) { [string]$response.StdErr } else { 'HTTP {0}' -f $response.StatusCode })) }
    }
    $option = $null
    try {
        $body = [string]$response.StdOut | ConvertFrom-Json -AsHashtable
        $option = $body['properties']['options']['forceLastGoodPlan']
    }
    catch {
        $option = $null
    }
    if ($option -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Read = $false; Desired = ''; Actual = ''; Reason = ''; Error = 'the answer has no forceLastGoodPlan option' }
    }
    return [pscustomobject]@{ Read = $true; Desired = [string]$option['desiredState']; Actual = [string]$option['actualState']; Reason = [string]$option['reasonDesc']; Error = '' }
}

function Invoke-DemoT3AutoTuningRelease {
    <#
    .SYNOPSIS
    stop-demo.ps1's release of the Database Agent beat's hold (2026-11-18 review): runs demo.usp_release_auto_tuning_hold on
    T3 from T1 (Invoke-DemoT3SqlFromT1), before T1 deallocates, and returns Ran, Released, RestoredState, and Error.
    Internal.

    .DESCRIPTION
    The procedure puts back only what a demo hold recorded (demo.auto_tuning_hold), so a FORCE_LAST_GOOD_PLAN that
    someone set off outside the demo stays off, and it does nothing without a hold. @force releases a hold whose run is
    still finishing, because the session ends now, and the release is logged as auto-tuning-restored "by stop-demo.ps1".
    Bounded: one Run Command, no login or resume wait, a 120-second batch. It runs only while T3 is Online, because a
    paused serverless database would wake; Ran is false otherwise, or when T1 can't run it, with Error saying why.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [object] $T3,

        [AllowEmptyString()]
        [string] $DeploymentId = ''
    )

    $outcome = [ordered]@{ Ran = $false; Released = $false; RestoredState = ''; Error = '' }
    if (-not [bool](Get-DemoMemberValue -InputObject $T3 -Name 'Exists')) {
        $outcome.Error = 'T3 doesn''t exist'
        return [pscustomobject]$outcome
    }
    $status = [string](Get-DemoMemberValue -InputObject $T3 -Name 'Status')
    if ($status -ne 'Online') {
        $outcome.Error = 'T3 is {0}, and running T-SQL there would wake it' -f $(if ($status) { $status } else { 'in an unknown state' })
        return [pscustomobject]$outcome
    }
    $query = "DECLARE @released bit, @restored nvarchar(60); EXEC demo.usp_release_auto_tuning_hold @force = 1, @by = N'stop-demo.ps1', @released = @released OUTPUT, @restored_state = @restored OUTPUT; SELECT released = CAST(ISNULL(@released, 0) AS int), restored_state = @restored;"
    try {
        $run = Invoke-DemoT3SqlFromT1 -Config $Config -Query $query -DeploymentId $DeploymentId -CheckId 'STOP.T3.AUTOTUNING' -MaxLoginWaitSeconds 0 -MaxResumeWaitSeconds 0 -BatchTimeoutSeconds 120 -RunCommandAttempts 1 -Confirm:$false
    }
    catch {
        $outcome.Error = Protect-DemoText -Text $_.Exception.Message
        return [pscustomobject]$outcome
    }
    if ([string]$run.Status -ne 'Pass') {
        $outcome.Error = Protect-DemoText -Text ([string]$run.Message)
        return [pscustomobject]$outcome
    }
    $row = @($run.Rows) | Select-Object -First 1
    $outcome.Ran = $true
    $outcome.Released = [int](Get-DemoMemberValue -InputObject $row -Name 'released') -eq 1
    $outcome.RestoredState = [string](Get-DemoMemberValue -InputObject $row -Name 'restored_state')
    return [pscustomobject]$outcome
}

function Invoke-DemoT3AutoTuningCheck {
    <#
    .SYNOPSIS
    T3's FORCE_LAST_GOOD_PLAN for status.ps1 (-CheckId STATUS.T3.AUTOTUNING) and stop-demo.ps1 (-CheckId
    STOP.T3.AUTOTUNING, with -Release), 2026-11-18. Read-only. Returns $null when T3 doesn't exist.

    .DESCRIPTION
    Read only while T3 is Online (Get-DemoT3State's Status), because reading a paused serverless database's tuning
    options can wake it: otherwise Not selected, saying what puts it back. Pass when it's on. Off with a desired state of
    Off is what the Database Agent beat leaves while it holds it, from the regression to its response. The holds are put
    back inside T3, where the hold recorded what it found (demo.usp_release_auto_tuning_hold, logged as
    auto-tuning-restored): by the run's response and end, auto-cleanup, the next run's start, reset, deploy.ps1's setup,
    and stop-demo.ps1 before it deallocates T1 (Invoke-DemoT3AutoTuningRelease, whose outcome -Release passes here). So
    nothing here changes the setting, and an off that a person set outside the demo stays as it is (2026-11-18 review).
    - status.ps1: off is a Warning that says the beat holds it during a session and what puts it back.
    - stop-demo.ps1: Pass when the release put it back, or it's on; when it's off and T3 had no demo hold, a Warning that
      says it was set outside the demo and is left as it is; when the release couldn't run, a Warning with what puts it
      back.
    A desired state of Default or On that isn't in effect (Query Store read-only, for example) is a Warning with its
    reason. A read that fails is a Warning. Never a Fail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [object] $T3,

        [Parameter(Mandatory)]
        [ValidateSet('STATUS.T3.AUTOTUNING', 'STOP.T3.AUTOTUNING')]
        [string] $CheckId,

        [AllowNull()]
        [object] $Release = $null
    )

    if (-not [bool](Get-DemoMemberValue -InputObject $T3 -Name 'Exists')) {
        return $null
    }
    $server = [string](Get-DemoMemberValue -InputObject $T3 -Name 'ServerName')
    $status = [string](Get-DemoMemberValue -InputObject $T3 -Name 'Status')
    $area = if ($CheckId -like 'STOP.*') { 'infra' } else { 't3' }
    $result = {
        param([string] $State, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
        New-DemoResult -CheckId $CheckId -Area $area -Target 'T3' -Status $State -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $script:DemoAutoTuningDocUrl
    }
    $putBack = 'If a session''s Database Agent beat held it, the next run on T3 puts it back when it starts, and so do ./scripts/reset-demo.ps1 and ./scripts/deploy.ps1.'
    $released = [bool](Get-DemoMemberValue -InputObject $Release -Name 'Released')
    $ran = [bool](Get-DemoMemberValue -InputObject $Release -Name 'Ran')
    $releaseEvidence = if ($null -ne $Release) { [ordered]@{ ran = $ran; released = $released; restoredState = [string](Get-DemoMemberValue -InputObject $Release -Name 'RestoredState'); error = [string](Get-DemoMemberValue -InputObject $Release -Name 'Error') } } else { $null }
    if ($status -ne 'Online') {
        $evidence = [ordered]@{ t3Status = $status }
        if ($null -ne $releaseEvidence) {
            $evidence['release'] = $releaseEvidence
        }
        return (& $result 'Not selected' ('T3 is {0}, so FORCE_LAST_GOOD_PLAN wasn''t read: reading it could wake T3. {1}' -f $(if ($status) { $status } else { 'unknown' }), $putBack) $evidence)
    }
    $read = Get-DemoT3AutoTuning -Config $Config -ServerName $server
    $evidence = [ordered]@{ t3Status = $status; desiredState = $read.Desired; actualState = $read.Actual; reason = $read.Reason }
    if ($null -ne $releaseEvidence) {
        $evidence['release'] = $releaseEvidence
    }
    $putBackNow = if ($released) { 'stop-demo.ps1 put back what the Database Agent beat''s hold recorded ({0}). ' -f [string](Get-DemoMemberValue -InputObject $Release -Name 'RestoredState') } else { '' }
    if (-not $read.Read) {
        return (& $result 'Warning' ('{0}T3''s FORCE_LAST_GOOD_PLAN couldn''t be read: {1}.' -f $putBackNow, $read.Error.TrimEnd('.')) $evidence ('Run the script again. {0}' -f $putBack))
    }
    if ($read.Desired -eq 'Off') {
        if ($CheckId -eq 'STATUS.T3.AUTOTUNING') {
            return (& $result 'Warning' ('FORCE_LAST_GOOD_PLAN is off on T3 (actual {0}). A session''s Database Agent beat holds it off from the regression to its response, so during that beat this is expected; after a session, the run that held it stopped before putting it back, and automatic tuning doesn''t correct plan regressions until it''s back.' -f $read.Actual) $evidence $putBack)
        }
        if ($ran -and -not $released) {
            return (& $result 'Warning' ('FORCE_LAST_GOOD_PLAN is off on T3 (actual {0}), and no Database Agent beat holds it, so it was set outside the demo, and stop-demo.ps1 leaves it as it is. Automatic tuning doesn''t correct plan regressions while it''s off.' -f $read.Actual) $evidence 'If you didn''t mean to turn it off, set it back on ContosoCare: ALTER DATABASE CURRENT SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = DEFAULT).')
        }
        $why = if ($null -eq $Release) { 'whether a Database Agent beat holds it wasn''t checked' } elseif ($released) { 'it still reads as off right after the release' } else { 'whether a Database Agent beat holds it couldn''t be checked ({0})' -f ([string](Get-DemoMemberValue -InputObject $Release -Name 'Error')).TrimEnd('.') }
        return (& $result 'Warning' ('{0}FORCE_LAST_GOOD_PLAN is off on T3 (actual {1}), and {2}.' -f $putBackNow, $read.Actual, $why) $evidence $putBack)
    }
    if ($read.Actual -eq 'On') {
        $how = if ($released) { $putBackNow } else { '' }
        return (& $result 'Pass' ('{0}T3''s FORCE_LAST_GOOD_PLAN is on (desired {1}): automatic tuning corrects plan regressions, as the showcase''s third cycle shows.' -f $how, $read.Desired) $evidence)
    }
    return (& $result 'Warning' ('{0}FORCE_LAST_GOOD_PLAN''s desired state on T3 is {1}, but it''s {2} ({3}), so automatic tuning doesn''t correct plan regressions.' -f $putBackNow, $read.Desired, $(if ($read.Actual) { $read.Actual } else { 'not reported' }), $(if ($read.Reason) { $read.Reason } else { 'no reason given' })) $evidence 'Query Store must be READ_WRITE on ContosoCare: ./scripts/validate.ps1 -Area T3 shows its state.')
}

function ConvertTo-DemoT3AutoTuningResult {
    <#
    .SYNOPSIS
    T3.AUTOTUNING (2026-11-18) from the row of database/azuresql/900-status.sql that Test-DemoT3 reads through T1:
    FORCE_LAST_GOOD_PLAN's desired and actual state, and the Database Agent beat's hold (demo.auto_tuning_hold) with its
    run's status. Pure. Internal.

    .DESCRIPTION
    - Pass: on; or off while the beat's run that holds it is still Running, which is the beat working as designed.
    - Warning: held by a run that isn't Running any more (it stopped before any of its own ways back; the next run's
      start, reset, or deploy.ps1's setup puts it back); off with no hold, which something outside the demo did; on by
      its desired state but not in effect (Query Store read-only, for example); or not in the row.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Row
    )

    $desired = [string](Get-DemoMemberValue -InputObject $Row -Name 'force_last_good_plan_desired')
    $actual = [string](Get-DemoMemberValue -InputObject $Row -Name 'force_last_good_plan_actual')
    $holder = [string](Get-DemoMemberValue -InputObject $Row -Name 'auto_tuning_hold_run')
    $holderStatus = [string](Get-DemoMemberValue -InputObject $Row -Name 'auto_tuning_hold_status')
    $queryStore = [string](Get-DemoMemberValue -InputObject $Row -Name 'query_store_state')
    $evidence = [ordered]@{ desiredState = $desired; actualState = $actual; holdRun = $holder; holdRunStatus = $holderStatus; queryStore = $queryStore }
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'T3.AUTOTUNING' -Area 't3' -Target 'T3' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $script:DemoAutoTuningDocUrl
    }
    $putBack = 'The next run on T3 puts it back when it starts, and so do reset (./scripts/reset-demo.ps1 -Target T3), ./scripts/stop-demo.ps1 while T3 is awake, and ./scripts/deploy.ps1.'
    if (-not $desired -and -not $actual) {
        return (& $result 'Warning' 'T3''s FORCE_LAST_GOOD_PLAN wasn''t in its status, so it wasn''t checked.' 'Run ./scripts/validate.ps1 -Area T3 again.')
    }
    if ($holder -and $holderStatus -eq 'Running') {
        return (& $result 'Pass' ('FORCE_LAST_GOOD_PLAN is held off on T3 by the Database Agent beat''s run {0}, which is running: automatic tuning waits until its response, and the run puts it back then, or at its end.' -f $holder))
    }
    if ($holder) {
        return (& $result 'Warning' ('FORCE_LAST_GOOD_PLAN is still held off on T3 (desired {0}): the Database Agent beat''s run {1} ({2}) stopped before putting it back, so automatic tuning doesn''t correct plan regressions until it''s back.' -f $desired, $holder, $(if ($holderStatus) { $holderStatus } else { 'no longer recorded' })) $putBack)
    }
    if ($actual -eq 'ON') {
        return (& $result 'Pass' ('T3''s FORCE_LAST_GOOD_PLAN is on (desired {0}): automatic tuning corrects plan regressions, as the showcase''s third cycle shows.' -f $desired))
    }
    if ($desired -eq 'OFF') {
        return (& $result 'Warning' 'T3''s FORCE_LAST_GOOD_PLAN is off, and no Database Agent beat holds it, so something outside the demo turned it off; automatic tuning doesn''t correct the showcase''s third-cycle regression.' 'In the Azure portal, open the database''s Automatic tuning page and set Force plan to Inherit, or run ALTER DATABASE CURRENT SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = DEFAULT) on ContosoCare.')
    }
    return (& $result 'Warning' ('T3''s FORCE_LAST_GOOD_PLAN is {0} but not in effect (actual {1}; Query Store {2}), so automatic tuning doesn''t correct plan regressions.' -f $desired, $(if ($actual) { $actual } else { 'not reported' }), $(if ($queryStore) { $queryStore } else { 'not reported' })) 'Automatic tuning needs Query Store READ_WRITE on ContosoCare: check sys.database_query_store_options, or the database''s Query Store settings in SSMS.')
}

function Test-DemoT3AgentPermission {
    <#
    .SYNOPSIS
    Whether the signed-in Azure account can save T3 in Database agent settings: saving needs Azure RBAC write on each
    selected database (Learn), read with Permissions - List For Resource. Returns Read, Allowed, and Error. A read.
    Internal.

    .DESCRIPTION
    Test-DemoPermission decides: one role's actions match Microsoft.Sql/servers/databases/write (wildcards included) and
    that role's notActions don't. Deny assignments aren't listed by that API, so an Allowed account can still be refused.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^azuresql01-[a-z0-9]{6}$')]
        [string] $ServerName
    )

    $action = 'Microsoft.Sql/servers/databases/write'
    $response = Invoke-DemoRestRequest -SubscriptionId ([string]$Config['subscriptionId']) -Method GET -Uri (Get-DemoT3AgentUri -Config $Config -ServerName $ServerName -Path 'providers/Microsoft.Authorization/permissions')
    if ($response.ExitCode -ne 0) {
        return [pscustomobject]@{ Read = $false; Allowed = $false; Error = (Protect-DemoText -Text $(if ($response.StdErr) { [string]$response.StdErr } else { 'HTTP {0}' -f $response.StatusCode })) }
    }
    try {
        $permissions = @((([string]$response.StdOut | ConvertFrom-Json).value) | Where-Object { $null -ne $_ })
    }
    catch {
        return [pscustomobject]@{ Read = $false; Allowed = $false; Error = 'the answer isn''t JSON' }
    }
    return [pscustomobject]@{ Read = $true; Allowed = (Test-DemoPermission -Permission $permissions -Action $action); Error = '' }
}

function Test-DemoT3AgentReadiness {
    <#
    .SYNOPSIS
    T3.AGENT (2026-11-18): what Database Agents needs from T3 that deploy.ps1 and validate.ps1 can read. Pass, or a
    Warning that names each gap with its fix; never a Fail, because the rest of the demo doesn't need the agent.

    .DESCRIPTION
    - T3 isn't a one-vCore serverless database, which Database Agents doesn't support: the lowest-cost profile's maximum
      went from 1 to 2 vCores for it (ADR 0016), and deploy.ps1 scales an existing T3 online.
    - T3 isn't in an elastic pool.
    - The signed-in account can save T3 in Database agent settings: Azure RBAC write on the database
      (Test-DemoT3AgentPermission). It's the account the presenter signs in to Fabric with, in the demo's one-click path.
    - Performance monitoring is on: -PerformanceMonitoring, T3.PROPERTY's value ('true'), when it was read.
    What deploy can't read, the Fabric home region and whether the agent is on, is HUB.AGENT.T3's to confirm.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^azuresql01-[a-z0-9]{6}$')]
        [string] $ServerName,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Database,

        [AllowEmptyString()]
        [string] $PerformanceMonitoring = ''
    )

    $gaps = [System.Collections.Generic.List[string]]::new()
    $fixes = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $sku = Get-DemoMemberValue -InputObject $Database -Name 'currentSku'
    if ($null -eq $sku) {
        $sku = Get-DemoMemberValue -InputObject $Database -Name 'sku'
    }
    $skuName = [string](Get-DemoMemberValue -InputObject $sku -Name 'name')
    $capacity = Get-DemoMemberValue -InputObject $sku -Name 'capacity'
    $pool = [string](Get-DemoMemberValue -InputObject $Database -Name 'elasticPoolId')
    $evidence = [ordered]@{ database = ('{0}/ContosoCare' -f $ServerName); sku = $skuName; maxVcores = $capacity; elasticPool = $pool; performanceMonitoring = $PerformanceMonitoring }
    if ($skuName -like 'GP_S_*' -and $null -ne $capacity -and [double]$capacity -le 1) {
        $gaps.Add('T3 is a one-vCore serverless database, which Database Agents doesn''t support')
        $fixes.Add('run ./scripts/deploy.ps1, which scales T3 to the profile''s 2 vCores online (ADR 0016)')
    }
    if ($pool) {
        $gaps.Add('T3 is in an elastic pool, which Database Agents doesn''t support')
        $fixes.Add('move T3 out of the pool')
    }
    $permission = Test-DemoT3AgentPermission -Config $Config -ServerName $ServerName
    $evidence['canSaveAgent'] = if ($permission.Read) { $permission.Allowed } else { $null }
    if ($permission.Read -and -not $permission.Allowed) {
        $gaps.Add('the signed-in Azure account can''t save T3 in Database agent settings, which needs Azure write access on the database (Microsoft.Sql/servers/databases/write)')
        $fixes.Add('sign in to Fabric with an account that has Contributor or SQL DB Contributor on T3, such as the account that deployed the demo, or have an Owner grant one')
    }
    elseif (-not $permission.Read) {
        $notes.Add(('your write access on T3 couldn''t be read ({0}); saving T3 in Database agent settings needs it' -f $permission.Error.TrimEnd('.')))
    }
    if ($PerformanceMonitoring -and $PerformanceMonitoring -ne 'true') {
        $gaps.Add('T3''s performance monitoring is off (T3.PROPERTY), so Database Hub can''t list T3 for the agent')
        $fixes.Add('run ./scripts/deploy.ps1, which turns it on')
    }
    if ($gaps.Count -gt 0) {
        return (New-DemoResult -CheckId 'T3.AGENT' -Area 't3' -Target 'T3' -Status 'Warning' -Message ('Database Agents can''t monitor T3 yet: {0}. The rest of the demo doesn''t need it.' -f ($gaps -join '; ')) -Evidence $evidence -Remediation (($fixes -join '; ') + '.') -DocUrl $script:DemoAgentDocUrl)
    }
    $text = 'Database Agents can monitor T3: it''s a {0}-vCore serverless database outside any pool{1}{2}.' -f $capacity, $(if ($permission.Read) { ', and your account can save it in Database agent settings' } else { '' }), $(if ($PerformanceMonitoring -eq 'true') { ', with performance monitoring on' } else { '' })
    if ($notes.Count -gt 0) {
        return (New-DemoResult -CheckId 'T3.AGENT' -Area 't3' -Target 'T3' -Status 'Warning' -Message ('{0}. But {1}.' -f $text.TrimEnd('.'), ($notes -join '; ')) -Evidence $evidence -Remediation 'Run ./scripts/validate.ps1 -Area T3 again to read it.' -DocUrl $script:DemoAgentDocUrl)
    }
    return (New-DemoResult -CheckId 'T3.AGENT' -Area 't3' -Target 'T3' -Status 'Pass' -Message $text -Evidence $evidence -DocUrl $script:DemoAgentDocUrl)
}

function Get-DemoDatabaseHubLink {
    <#
    .SYNOPSIS
    Database Hub's page in the demo's tenant, from config/versions.json (fabricApp.portalUrl), as the Insights app's links
    are: Database Hub has no API, and this is the page a person opens. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $tenant = ([string]$Config['tenantId']).ToLowerInvariant()
    $portal = ([string](Get-DemoFabricAppSetting)['portalUrl']).TrimEnd('/')
    return ('{0}/workloads/fdh/databaseHub{1}' -f $portal, $(if ($tenant) { '?ctid=' + $tenant } else { '' }))
}

function Get-DemoT3AgentSetupItem {
    <#
    .SYNOPSIS
    HUB.AGENT.T3 (2026-11-18): the Database Agent loop's one manual step, optional (the owner's decision, 2026-11-19), which
    no API offers, as a Manual action required that only a person confirms (Test-DemoConfirmOnlyResult): deploy.ps1's
    ending and the status page list it under "Please confirm", with Database Hub's link, the exact database to select, and
    the Agent policy options. It's once per deployment: the selection stays across sessions and upgrades, unless T3 is
    recreated (stop-demo.ps1 -RemoveT3). Only the Database Agent loop on T3 needs it. Database Agents also needs T3 in the
    supported region associated with the Fabric tenant's home region, which no API reads, so it's named here too.
    Since 2026-11-20 it selects T3 alone, says how to tell T3's row from other environments' ContosoCare rows, and what to
    uncheck when a Save fails: the selection is the tenant's, Database Hub keeps a deleted database in it, and a Save fails
    as a whole when any selected database fails its check (live, 2026-11-20). Returns $null when T3 doesn't exist. Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ServerName,

        [AllowEmptyString()]
        [string] $Region = ''
    )

    if ($ServerName -notmatch '^azuresql01-[a-z0-9]{6}$') {
        return $null
    }
    $link = Get-DemoDatabaseHubLink -Config $Config
    $database = '{0}/ContosoCare' -f $ServerName
    $where = if ($Region) { $Region } else { [string]$Config['location'] }
    $failed = 'uncheck any database that''s deleted, paused, one-vCore serverless, in another region, or without your Azure write access'
    # The status page keeps 1,200 characters of each "Please confirm" line (Set-DemoProgressValue), so this stays shorter.
    $message = 'Optional, for the Database Agent loop: select T3 in Database Agents, once per deployment (it stays selected across sessions and upgrades, unless T3 is recreated). Open {0}, select Manage agents, then Database agent settings; turn Enabled on, clear the selection, select {1}, and under Agent policy turn on {2}; select Apply, then Save (about 30 seconds). {3}. T3 must be awake: right after deploy.ps1, or during a session. T3''s region ({4}) must be your Fabric tenant''s home region (Fabric: ? > About Fabric). If Save says "{5}", {6}, and Save again.' -f $link, $database, ($script:DemoAgentPolicy -join ', '), $script:DemoAgentLookAlike, $where, $script:DemoAgentSaveError, $failed
    return (New-DemoResult -CheckId 'HUB.AGENT.T3' -Area 'hub' -Target 'T3' -Status 'Manual action required' -Message $message -Evidence ([ordered]@{ link = $link; database = $database; policy = @($script:DemoAgentPolicy); region = $where; oncePerDeployment = $true }) -Remediation ('In Database Hub, Manage agents > Database agent settings: Enabled, clear the selection, select {0}, Apply, Save. If Save says "{1}", {2}, and Save again; the walkthrough''s Database Agent loop shows the rest.' -f $database, $script:DemoAgentSaveError, $failed) -DocUrl $script:DemoAgentDocUrl)
}

function Get-DemoT3AgentRemovalItem {
    <#
    .SYNOPSIS
    DESTROY.HUB.AGENT.T3 (2026-11-20): what destroy.ps1 can't do, remove T3 from Database Hub's Database agent settings,
    which no API offers, as a Manual action required that changes nothing and leaves destroy.ps1's exit code alone. The
    selection is the tenant's, Database Hub keeps a deleted database in it, and a Save checks every selected database and
    fails as a whole when any fails ("If any selected database fails that permission check, the entire save fails", Learn,
    enable Database Agents), so a deleted T3 fails every later Save, as when the next deployment's T3 is selected (live,
    2026-11-20). The steps say how to tell T3's row from other environments' ContosoCare rows. Returns $null without T3's
    server name. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ServerName
    )

    if ($ServerName -notmatch '^azuresql01-[a-z0-9]{6}$') {
        return $null
    }
    $link = Get-DemoDatabaseHubLink -Config $Config
    $database = '{0}/ContosoCare' -f $ServerName
    $message = 'If you selected T3 for Database Agents, remove {0} from Database Hub''s Database agent settings and Save, before or after destroy.ps1; no API can. Database Hub keeps a deleted database selected, and a Save checks every selected database, so every later Save there fails ("{1}") until it''s removed, as when you select the next deployment''s T3.' -f $database, $script:DemoAgentSaveError
    $remediation = 'Open {0}, select Manage agents, then Database agent settings; uncheck {1}, then Save. {2}; after destroy.ps1, T3''s row is one that fails. Nothing to do if you never selected it. Why: {3}' -f $link, $database, $script:DemoAgentLookAlike, $script:DemoAgentDocUrl
    return (New-DemoResult -CheckId 'DESTROY.HUB.AGENT.T3' -Area 'teardown' -Target 'T3' -Status 'Manual action required' -Message $message -Evidence ([ordered]@{ link = $link; database = $database }) -Remediation $remediation -DocUrl $script:DemoAgentDocUrl)
}
