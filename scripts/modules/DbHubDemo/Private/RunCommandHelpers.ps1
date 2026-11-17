function Get-DemoRunCommandApiVersion {
    <#
    .SYNOPSIS
    The Microsoft.Compute/virtualMachines/runCommands API version pinned in config/versions.json, the same
    one infra/modules/bootstrap.bicep uses (a Pester test keeps them in sync). Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $apiVersion = [string]$versions.apiVersions['Microsoft.Compute/virtualMachines/runCommands']
    if (-not $apiVersion) {
        throw 'config/versions.json has no API version for Microsoft.Compute/virtualMachines/runCommands.'
    }
    return $apiVersion
}

function Get-DemoRunCommandBaseUrl {
    # ARM URL of a VM's runCommands collection. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    return ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}/runCommands' -f $SubscriptionId, $ResourceGroupName, $VmName)
}

function Test-DemoAzConflict {
    # True for an Azure CLI error that a retry can fix: 409 Conflict or another operation in progress, which
    # policy-installed extensions (Guest Configuration, Defender for SQL) cause after a deployment. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    return ([string]$Text -match '(?i)\bConflict\b|\(409\)|\b409\b|AnotherOperationInProgress|OperationPreempted|RetryableError')
}

function Test-DemoAzVmNotRunning {
    # True for an Azure CLI error that says the VM isn't running, for example OperationNotAllowed because it's
    # deallocated. A retry can't fix it, so callers report it at once instead of waiting (R49). Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    return ([string]$Text -match '(?i)(OperationNotAllowed|not allowed|cannot|can''t|unable)[^\r\n]{0,240}(deallocat|not running|is stopped|PowerState/stopped)')
}

function Get-DemoConflictDelay {
    # Seconds to wait before conflict retry N: 10, 20, 40, 80, then 120. Nine retries wait about 12.5 minutes,
    # longer than the 10 minutes a policy-driven MDE.Windows update blocked Run Commands live (R49). Internal.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int] $Attempt
    )

    return [int][System.Math]::Min(120, 10 * [System.Math]::Pow(2, $Attempt - 1))
}

function Test-DemoAzNotFound {
    # True for an Azure CLI error that says the resource doesn't exist, including through its parent: the
    # resource group (ResourceGroupNotFound, "could not be found"), a deployment, or a Microsoft Graph object
    # (Request_ResourceNotFound). Deletes treat it as already done, and reads as gone. A subscription that
    # can't be found (SubscriptionNotFound) means a wrong context or no access, never a deleted resource
    # (https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/common-deployment-errors).
    # Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    if ([string]$Text -match '(?i)SubscriptionNotFound|\bsubscription ''[^'']*'' (could )?not (be )?found') {
        return $false
    }
    return ([string]$Text -match '(?i)NotFound\b|\bNot ?Found\b|\(404\)|could not be found')
}

function Get-DemoRunCommandState {
    <#
    .SYNOPSIS
    Reads one managed Run Command with its instance view (az rest GET ...?$expand=instanceView). Internal.

    .DESCRIPTION
    Returns Found, ProvisioningState, ExecutionState, ExitCode, Output, and Error. Output and Error are the
    last 4 KB that the instance view keeps (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed),
    redacted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url
    )

    $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ($Url + '&$expand=instanceView')) -AllowFailure
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Found             = $false
            NotFound          = (Test-DemoAzNotFound -Text $result.StdErr)
            ProvisioningState = ''
            ExecutionState    = ''
            ExitCode          = $null
            StartTime         = $null
            Output            = ''
            Error             = (Protect-DemoText -Text ([string]$result.StdErr).Trim())
        }
    }
    $resource = $result.StdOut | ConvertFrom-Json -Depth 32
    $properties = Get-DemoMemberValue -InputObject $resource -Name 'properties'
    $view = Get-DemoMemberValue -InputObject $properties -Name 'instanceView'
    $exitCode = Get-DemoMemberValue -InputObject $view -Name 'exitCode'
    [pscustomobject]@{
        Found             = $true
        NotFound          = $false
        ProvisioningState = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
        ExecutionState    = [string](Get-DemoMemberValue -InputObject $view -Name 'executionState')
        ExitCode          = if ($null -ne $exitCode) { [int]$exitCode } else { $null }
        StartTime         = ConvertTo-DemoRunCommandUtc -Value (Get-DemoMemberValue -InputObject $view -Name 'startTime')
        Output            = Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $view -Name 'output')).Trim()
        Error             = Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $view -Name 'error')).Trim()
    }
}

function ConvertTo-DemoRunCommandUtc {
    # The instance view's startTime as a UTC DateTime, or $null when it's missing or unreadable. Internal.
    [CmdletBinding()]
    [OutputType([System.Nullable[datetime]])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Wait-DemoRunCommand {
    <#
    .SYNOPSIS
    Polls a managed Run Command until its script reaches a terminal state, or until the wait times out. Internal.

    .DESCRIPTION
    Terminal execution states are Succeeded, Failed, TimedOut, and Canceled (REST reference: ExecutionState).
    A provisioning state of Failed is terminal too: the extension platform couldn't run the script. With
    treatFailureAsDeploymentFailure false, only the instance view shows whether the script failed. Returns
    the last state read, with WaitTimedOut set when the deadline passed first.

    With -NotBeforeUtc, a terminal state whose execution started earlier belongs to an earlier Run Command with
    the same name: a Run Command created again right after it was deleted can report the previous run's
    instance view, and its own script may never run (seen live on 2026-10-21). Such a state is read again for
    about -StaleGraceSeconds; if it doesn't change, it's returned with Stale set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url,

        [Parameter(Mandatory)]
        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds,

        [ValidateRange(0, 300)]
        [int] $PollIntervalSeconds = 5,

        [System.Nullable[datetime]] $NotBeforeUtc = $null,

        [ValidateRange(0, 3600)]
        [int] $StaleGraceSeconds = 120,

        [ValidateRange(0, 7200)]
        [int] $StartTimeoutSeconds = 0
    )

    $terminal = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
    $deadline = [System.DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $startDeadline = if ($StartTimeoutSeconds -gt 0) { [System.DateTime]::UtcNow.AddSeconds($StartTimeoutSeconds) } else { [System.DateTime]::MaxValue }
    # Counted in polls rather than wall-clock time, so the grace follows the poll interval.
    $staleLimit = [int][System.Math]::Ceiling($StaleGraceSeconds / [System.Math]::Max(1, $PollIntervalSeconds))
    $stalePolls = 0
    while ($true) {
        $state = Get-DemoRunCommandState -SubscriptionId $SubscriptionId -Url $Url
        $done = $state.Found -and ($state.ExecutionState -in $terminal -or $state.ProvisioningState -eq 'Failed')
        $startTime = Get-DemoMemberValue -InputObject $state -Name 'StartTime'
        $stale = $done -and $null -ne $NotBeforeUtc -and $null -ne $startTime -and $startTime -lt $NotBeforeUtc
        if ($stale) {
            if ($stalePolls -ge $staleLimit -or [System.DateTime]::UtcNow -ge $deadline) {
                $state | Add-Member -NotePropertyName 'WaitTimedOut' -NotePropertyValue $false
                $state | Add-Member -NotePropertyName 'Stale' -NotePropertyValue $true
                $state | Add-Member -NotePropertyName 'NotStarted' -NotePropertyValue $false
                return $state
            }
            $stalePolls++
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
        # Phase 28's watchdog: a script that hasn't started by -StartTimeoutSeconds waits behind the VM's extension work.
        $notStarted = -not $done -and -not $state.NotFound -and [string]$state.ExecutionState -notin 'Running' -and [System.DateTime]::UtcNow -ge $startDeadline
        if ($done -or $state.NotFound -or $notStarted -or [System.DateTime]::UtcNow -ge $deadline) {
            $state | Add-Member -NotePropertyName 'WaitTimedOut' -NotePropertyValue (-not $done -and -not $state.NotFound)
            $state | Add-Member -NotePropertyName 'Stale' -NotePropertyValue $false
            $state | Add-Member -NotePropertyName 'NotStarted' -NotePropertyValue ([bool]$notStarted)
            return $state
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Remove-DemoRunCommand {
    <#
    .SYNOPSIS
    Deletes a managed Run Command and waits until it's gone, so a VM never holds more than one chunk Run
    Command (Azure allows 25 managed Run Commands per VM). Deleting also stops a script that's still
    running. With -NoWait it returns as soon as Azure accepted the delete (Phase 28: a delete that a busy
    extension holds no longer stalls the next chunk). Internal; returns $true when the Run Command is gone, or
    with -NoWait when Azure accepted the delete.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url,

        [ValidateRange(0, 3600)]
        [int] $WaitSeconds = 180,

        [ValidateRange(0, 300)]
        [int] $PollIntervalSeconds = 5,

        [switch] $NoWait
    )

    if (-not $PSCmdlet.ShouldProcess($Url, 'Delete the Run Command')) {
        return $false
    }
    $delete = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', $Url) -AllowFailure
    if ($delete.ExitCode -ne 0 -and -not (Test-DemoAzNotFound -Text $delete.StdErr)) {
        Write-DemoLog -Level Warning -Message ('Deleting a Run Command failed: {0}' -f ([string]$delete.StdErr).Trim())
        return $false
    }
    if ($NoWait) {
        return $true
    }
    $deadline = [System.DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ($true) {
        $state = Get-DemoRunCommandState -SubscriptionId $SubscriptionId -Url $Url
        if ($state.NotFound) {
            return $true
        }
        if ([System.DateTime]::UtcNow -ge $deadline) {
            return $false
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Get-DemoRunCommandFreshName {
    # The name a Run Command runs under when Azure keeps its own name in Deleting (2026-11-13 live finding): the name and
    # -yyyyMMddHHmmss in UTC, the suffix Test-DemoRunCommandFinished reads. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    return ('{0}-{1}' -f $Name, $NowUtc.ToUniversalTime().ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture))
}

function Test-DemoRunCommandFullError {
    # True for Resolve-DemoRunCommandFreshName's refusal: the VM had no room for a fresh name, because Azure keeps the
    # others in Deleting (2026-11-13 live finding). The health waits stop after 15 minutes of it. Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    return ([string]$Text -match 'close to Azure''s limit of 25, so it didn''t run under a fresh name')
}

function Test-DemoRunCommandHeldError {
    # True for Azure's refusal of a PUT to a Run Command name it keeps marked for deletion: "Operation 'PUT Extension' is
    # not allowed on VM extension '<name>' since it is marked for deletion" (live on archost01, 2026-11-13 and 16). A
    # retry doesn't help: Azure has held such names for hours. Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    return ([string]$Text -match '(?i)\bmarked for deletion\b')
}

function Resolve-DemoRunCommandFreshName {
    <#
    .SYNOPSIS
    The name Invoke-DemoVmRunCommand runs under when Azure still lists -RunCommandName after the leftover wait: a fresh one
    (Get-DemoRunCommandFreshName), so a name stuck in Deleting never holds a run (2026-11-13 live finding). Returns it, or
    throws when the VM has no room for it. Internal.

    .DESCRIPTION
    Live on archost01 (2026-11-13, both test environments), Azure ended 27 of 29 Run Command deletes with
    InternalExecutionError after 6 to 11 minutes, and a name whose delete failed stays marked for deletion: a PUT of it
    fails with OperationNotAllowed until a later delete succeeds, which took hours there. A new name ran at once (its
    script finished within a minute). One read of the VM's Run Commands comes first:
    - Earlier fresh copies of the same name, and chunk Run Commands whose script ended (a finished transfer's leftovers,
      which only a later Artifacts step deleted before; 9 of the 20 on the T2 host, live), are asked to go, without
      waiting (Remove-DemoRunCommand -NoWait), so they don't pile up across calls and runs.
    - Azure allows 25 managed Run Commands per VM (https://learn.microsoft.com/azure/virtual-machines/run-command-overview)
      and doesn't say whether one being deleted counts, so every one listed counts: at -Limit (24) or more, there's no
      fresh name, and it throws, which the caller reports as a Run Command that couldn't be created.
    What it used goes to $script:DemoRunCommandStuck, which deploy.ps1 reports (Get-DemoRunCommandStuckResult), and the
    console says so at once. -ForChunk is Send-DemoChunkSet's, for a chunk whose PUT Azure refused because it keeps the
    name marked for deletion (2026-11-16 live finding): other chunks are left alone, because the chunk set deletes its
    own and one of them can have finished without being read back yet, and the text says what Azure answered, since
    nothing was waited for.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $BaseUrl,

        [Parameter(Mandatory)]
        [string] $ApiVersion,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $RunCommandName,

        [int] $WaitedSeconds = 0,

        [ValidateRange(1, 25)]
        [int] $Limit = 24,

        [datetime] $NowUtc = [DateTime]::UtcNow,

        [switch] $ForChunk
    )

    $listed = [System.Collections.Generic.List[string]]::new()
    $deleting = 0
    $finishedChunks = [System.Collections.Generic.List[string]]::new()
    $list = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}' -f $BaseUrl, $ApiVersion)) -AsJson -AllowFailure
    # Assigned first: Get-DemoMemberValue returns an array as one object, which @() wouldn't unroll.
    $values = Get-DemoMemberValue -InputObject $list -Name 'value'
    foreach ($item in @($values | Where-Object { $null -ne $_ })) {
        $itemName = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
        if (-not $itemName) {
            continue
        }
        $listed.Add($itemName)
        $provisioning = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'properties') -Name 'provisioningState')
        if ($provisioning -eq 'Deleting') {
            $deleting++
        }
        elseif (-not $ForChunk -and $itemName -like 'DbHubDemo-Chunk-*' -and $provisioning -in 'Succeeded', 'Failed') {
            # A chunk whose script ended: its file is on the VM or failed, and nothing reads the Run Command again.
            $finishedChunks.Add($itemName)
        }
    }
    $copyPattern = '^{0}-\d{{14}}$' -f [regex]::Escape($RunCommandName)
    # Earlier fresh copies of the name, and chunks left from finished transfers (live, 2026-11-13: 9 of the 20 there), are
    # asked to go without waiting; they still count until Azure has deleted them.
    foreach ($leftover in @(@($listed | Where-Object { $_ -match $copyPattern }) + $finishedChunks.ToArray())) {
        $null = Remove-DemoRunCommand -SubscriptionId $SubscriptionId -Url ('{0}/{1}?api-version={2}' -f $BaseUrl, $leftover, $ApiVersion) -NoWait -Confirm:$false
    }
    $held = if ($ForChunk) { 'Azure keeps {0} marked for deletion' -f $RunCommandName } else { 'Azure still lists {0} after {1}' -f $RunCommandName, (Format-DemoProgressDuration -Seconds ([long]$WaitedSeconds)) }
    if ($listed.Count -ge $Limit) {
        throw ('{0}: {1}, and the VM already has {2} Run Commands ({3} being deleted), close to Azure''s limit of 25, so it didn''t run under a fresh name either. That''s Azure-side: Azure deletes them on its own, and the next try checks again.' -f $VmName, $held, $listed.Count, $deleting)
    }
    $fresh = Get-DemoRunCommandFreshName -Name $RunCommandName -NowUtc $NowUtc
    $script:DemoRunCommandStuck.Add([pscustomobject]@{ VmName = $VmName; Name = $RunCommandName; FreshName = $fresh; AtUtc = $NowUtc.ToUniversalTime(); WaitedSeconds = $WaitedSeconds; Listed = $listed.Count; Deleting = $deleting; Refused = [bool]$ForChunk })
    $null = $script:DemoRunCommandStuckName.Add(('{0}/{1}' -f $VmName, $RunCommandName))
    $instead = if ($ForChunk) { '' } else { ' instead of waiting' }
    Write-DemoLog -Level Warning -Message ('{0}: {1} (its delete hasn''t finished, or Azure ended it with an internal error and keeps the name until another delete), so it runs as {2}{3}. Nothing to do: Azure deletes the stuck one on its own (DEPLOY.RUNCOMMAND.STUCK_{4}).' -f $VmName, $held, $fresh, $instead, $VmName.ToUpperInvariant())
    return $fresh
}

function Get-DemoRunCommandStuckResult {
    <#
    .SYNOPSIS
    DEPLOY.RUNCOMMAND.STUCK_<VM>: a Warning for each VM where a Run Command ran under a fresh name in this process, because
    Azure kept its own name in Deleting (Resolve-DemoRunCommandFreshName; 2026-11-13 live finding), for the status page and
    DONE or NOT DONE (Get-DemoRunCommandStuckNote). -Clear takes what it returns off the record, so each is reported once;
    -VmName reads one VM's. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string] $VmName = '',

        [switch] $Clear
    )

    $items = @($script:DemoRunCommandStuck | Where-Object { -not $VmName -or [string]$_.VmName -eq $VmName })
    if ($Clear) {
        foreach ($item in $items) {
            $null = $script:DemoRunCommandStuck.Remove($item)
        }
    }
    $results = foreach ($group in @($items | Group-Object -Property VmName)) {
        $vm = [string]$group.Name
        $names = @($group.Group | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
        $fresh = @($group.Group | ForEach-Object { [string]$_.FreshName })
        $waited = [long](@($group.Group | ForEach-Object { [long]$_.WaitedSeconds }) | Measure-Object -Maximum).Maximum
        # Chunks (Send-DemoChunkSet) don't wait for a delete, so a group of them alone says what Azure answered instead.
        $refusedOnly = @($group.Group | Where-Object { -not [bool](Get-DemoMemberValue -InputObject $_ -Name 'Refused') }).Count -eq 0
        $kept = if ($refusedOnly) { 'marked for deletion' } else { 'in Deleting for more than {0}' -f (Format-DemoProgressDuration -Seconds $waited) }
        $message = 'Azure kept {0} on {1} {2}, so {3} Run Command run(s) used a fresh name instead of waiting (the last: {4}). That''s Azure-side: Azure ends some Run Command deletes with an internal error (InternalExecutionError) and keeps the name until a later delete succeeds.' -f ($names -join ', '), $vm, $kept, $fresh.Count, $fresh[-1]
        New-DemoResult -CheckId ('DEPLOY.RUNCOMMAND.STUCK_{0}' -f $vm.ToUpperInvariant()) -Area 'infra' -Target (Get-DemoVmTarget -VmName $vm) -Status 'Warning' -Message $message -Evidence ([ordered]@{ vmName = $vm; stuck = $names; freshNames = $fresh; waitedSeconds = $waited }) -Remediation 'Nothing to do: the run went on, and Azure deletes the stuck ones on its own. ./scripts/status.ps1 lists any that stay (STATUS.RUNCOMMANDS), with the command that deletes them; if it happens on every run, see docs/troubleshooting.md (Run Commands stuck in Deleting).' -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    }
    return @($results)
}

function Get-DemoRunCommandStuckNote {
    # What DONE and NOT DONE say when Run Commands ran under fresh names because Azure kept their own in Deleting
    # (DEPLOY.RUNCOMMAND.STUCK_<VM>; 2026-11-13 live finding), or ''. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $stuck = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -like 'DEPLOY.RUNCOMMAND.STUCK_*' })
    if ($stuck.Count -eq 0) {
        return ''
    }
    $vms = [System.Collections.Generic.List[string]]::new()
    $runs = 0
    foreach ($item in $stuck) {
        $evidence = Get-DemoMemberValue -InputObject $item -Name 'evidence'
        $vm = [string](Get-DemoMemberValue -InputObject $evidence -Name 'vmName')
        if ($vm -and -not $vms.Contains($vm)) {
            $vms.Add($vm)
        }
        # Assigned first: Get-DemoMemberValue returns an array as one object.
        $fresh = Get-DemoMemberValue -InputObject $evidence -Name 'freshNames'
        $runs += @($fresh | Where-Object { $_ }).Count
    }
    return ('Azure kept Run Command names on {0} in Deleting, so {1} Run Command run(s) used a fresh name instead of waiting (DEPLOY.RUNCOMMAND.STUCK): nothing to do, Azure deletes the stuck ones on its own, and ./scripts/status.ps1 lists any that stay.' -f ($vms -join ' and '), $runs)
}

function Clear-DemoChunkRunCommand {
    # Deletes every DbHubDemo-Chunk-* Run Command left on a VM, for example by an interrupted run, without waiting for
    # Azure to finish each delete. Returns the names it asked Azure to delete; -Status gets the listing's (Total, or Tries
    # and Error). Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $BaseUrl,

        [Parameter(Mandatory)]
        [string] $ApiVersion,

        [AllowNull()]
        [hashtable] $Status = $null
    )

    $status = if ($null -ne $Status) { $Status } else { @{} }
    $names = Get-DemoChunkRunCommandName -SubscriptionId $SubscriptionId -BaseUrl $BaseUrl -ApiVersion $ApiVersion -Status $status
    if ($null -eq $names) {
        $vm = ($BaseUrl -split '/')[-2]
        Write-DemoLog -Level Warning -Message ('The Run Commands on {0} could not be listed in {1} tries ({2}), so leftover chunk Run Commands weren''t deleted this time. Nothing to do: the next cleanup checks again (after this send, or in the next run), and ./scripts/status.ps1 lists any Run Command that stays.' -f $vm, $status['Tries'], $status['Error'])
        return @()
    }
    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($names)) {
        $url = '{0}/{1}?api-version={2}' -f $BaseUrl, $name, $ApiVersion
        $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', $url) -AllowFailure
        if ($result.ExitCode -eq 0 -or (Test-DemoAzNotFound -Text $result.StdErr)) {
            $removed.Add($name)
        }
        else {
            Write-DemoLog -Level Warning -Message ('The leftover Run Command {0} could not be deleted: {1}' -f $name, ([string]$result.StdErr).Trim())
        }
    }
    if ($removed.Count -gt 0) {
        Write-DemoLog -Message ('Deleted {0} leftover chunk Run Command(s): {1}.' -f $removed.Count, ($removed -join ', '))
    }
    return $removed.ToArray()
}

function Get-DemoChunkRunCommandName {
    # The DbHubDemo-Chunk-* Run Commands a VM still lists (a Run Command Azure is deleting is still listed), or $null
    # when they can't be listed in -Tries tries, -RetrySeconds apart; -Status then gets Tries and Error, az's last error,
    # redacted, and otherwise Total, every Run Command the VM lists. A failed try that a later one makes up for is logged
    # with its error, so its cause shows (2026-11-16: a Warning in nearly every deploy, main's too, that az's dropped error
    # left unexplained). Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $BaseUrl,

        [Parameter(Mandatory)]
        [string] $ApiVersion,

        [AllowNull()]
        [hashtable] $Status = $null,

        [ValidateRange(1, 5)]
        [int] $Tries = 3,

        [ValidateRange(0, 60)]
        [int] $RetrySeconds = 5
    )

    $list = $null
    $problem = ''
    for ($try = 1; $try -le $Tries -and $null -eq $list; $try++) {
        if ($try -gt 1) {
            Start-Sleep -Seconds $RetrySeconds
        }
        $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}' -f $BaseUrl, $ApiVersion), '--output', 'json') -AllowFailure
        if ($result.ExitCode -ne 0) {
            $text = (Protect-DemoText -Text ([string]$result.StdErr)).Trim() -replace '\s+', ' '
            $problem = if ($text) { 'az: {0}' -f $text.Substring(0, [System.Math]::Min(400, $text.Length)) } else { 'az ended with exit code {0} and no error text' -f $result.ExitCode }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
            $problem = 'az returned nothing'
            continue
        }
        try {
            $list = $result.StdOut | ConvertFrom-Json -Depth 64
        }
        catch {
            $problem = 'az''s answer wasn''t JSON: {0}' -f $_.Exception.Message
        }
    }
    if ($null -eq $list) {
        if ($null -ne $Status) {
            $Status['Tries'] = $Tries
            $Status['Error'] = $problem
        }
        return $null
    }
    if ($problem) {
        Write-DemoLog -Message ('Listed the Run Commands on {0} on try {1} of {2}; the try before failed ({3}).' -f ($BaseUrl -split '/')[-2], ($try - 1), $Tries, $problem)
    }
    $items = Get-DemoMemberValue -InputObject $list -Name 'value'
    if ($null -ne $Status) {
        # Every Run Command listed, a chunk or not, one being deleted included: what counts toward Azure's 25 per VM.
        $Status['Total'] = @($items | Where-Object { $null -ne $_ }).Count
    }
    $names = [string[]]@(foreach ($item in @($items)) {
            $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            if ($name -like 'DbHubDemo-Chunk-*') {
                $name
            }
        })
    # The unary comma keeps an empty list a list: unrolled, it reached the callers as $null, which they read as "couldn't
    # be listed" (the cause of that Warning in nearly every deploy, and of a false "still deleting" Warning; 2026-11-16).
    return , $names
}

function Wait-DemoChunkRunCommandGone {
    <#
    .SYNOPSIS
    The one bounded cleanup at the end of a chunk set (Phase 28): asks Azure to delete what's left, then waits at most
    -TimeoutSeconds until no chunk Run Command is listed. Returns the names still listed, which the caller reports as a
    Warning: a delete that a busy extension holds finishes on its own, and the next run's cleanup checks again. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $BaseUrl,

        [Parameter(Mandatory)]
        [string] $ApiVersion,

        [ValidateRange(0, 1800)]
        [int] $TimeoutSeconds = 120,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10
    )

    $asked = @(Clear-DemoChunkRunCommand -SubscriptionId $SubscriptionId -BaseUrl $BaseUrl -ApiVersion $ApiVersion | Where-Object { $_ -is [string] -and $_ })
    if ($asked.Count -eq 0) {
        return @()
    }
    $deadline = [System.DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $left = Get-DemoChunkRunCommandName -SubscriptionId $SubscriptionId -BaseUrl $BaseUrl -ApiVersion $ApiVersion
        if ($null -eq $left) {
            # They can't be listed: nothing to wait for here; the next run's cleanup checks again.
            return $asked
        }
        if (@($left).Count -eq 0) {
            return @()
        }
        if ([System.DateTime]::UtcNow -ge $deadline) {
            return @($left)
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Send-DemoChunkSet {
    <#
    .SYNOPSIS
    Sends one or more files to one VM in SHA-256-checked chunk Run Commands through one queue: the engine of
    Send-DemoBootstrapBundle and Send-DemoWorkloadRunner. Internal.

    .DESCRIPTION
    Each file is split with New-DemoBootstrapChunk (or brings its chunks in a Chunks property), and the
    chunks of every file share one queue, so deploy.ps1's tracks send the bootstrap bundle (1 chunk) and the
    workload runner (7) in one wave of 8 instead of one after the other (ADR 0018). For each chunk: PUT the
    managed Run Command DbHubDemo-Chunk-<sha12>-<nnn> with 'az rest' (the body in a temporary file; a 409
    Conflict is retried with backoff; a name Azure keeps marked for deletion runs at once under a fresh one,
    <name>-yyyyMMddHHmmss, through Resolve-DemoRunCommandFreshName, 2026-11-16 live finding), read its
    instance view until the script is terminal (exit code 0 required), then DELETE it without waiting for
    Azure to finish the delete (Phase 28: a delete that a busy,
    usually policy-installed, extension holds cost up to 3 minutes per chunk before; R49, R336). Up to
    -Parallelism chunk Run Commands run at once, read every 10 seconds; with 1 they go one at a time. When no
    chunk finishes for -StallSeconds while several run, the rest go one at a time (Stalled). Leftover
    DbHubDemo-Chunk-* Run Commands are deleted before the first chunk (their deletes waited for, at most
    -RoomWaitSeconds, only when the VM wouldn't otherwise have room for the set under Azure's limit of 25), and
    once at the end, in a finally block,
    with one bounded wait of -CleanupWaitSeconds; the names Azure still lists then are returned as
    LeftoverRunCommands for the caller's Warning. Two calls must never run on one VM at once: one call with
    every file is how they travel together. Returns one object per file, in order: Description, Sha256,
    ChunkCount, Seconds (until its last chunk was delivered), Stalled, and LeftoverRunCommands.

    Managed Run Command runs scripts in parallel, 25 per VM at most
    (https://learn.microsoft.com/azure/virtual-machines/run-command-overview, checked 2026-10-23).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]] $File,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $ResourceGroupName = '',

        [ValidateRange(1, 512)]
        [int] $ChunkSizeKiB = 512,

        [ValidateRange(60, 3600)]
        [int] $TimeoutSeconds = 600,

        [ValidateRange(1, 16)]
        [int] $Parallelism = 1,

        [ValidateRange(30, 3600)]
        [int] $StallSeconds = 300,

        [ValidateRange(0, 1800)]
        [int] $CleanupWaitSeconds = 120,

        [ValidateRange(0, 1800)]
        [int] $RoomWaitSeconds = 300,

        # How long each chunk's delete is waited for, then once more after a second delete, before the next chunk goes
        # (2026-11-17, R871); 0 deletes without waiting (Phase 28). The T2 host defaults to 300, one chunk at a time: there,
        # with 8 chunks at once, Azure ended every chunk's delete with InternalExecutionError, the chunks stayed on the
        # VM, and its next start never got its goal state from Azure.
        [ValidateRange(0, 1800)]
        [int] $DeleteWaitSeconds = 0
    )

    if (-not $PSBoundParameters.ContainsKey('DeleteWaitSeconds') -and $VmName -eq (Get-DemoHostVmName -Config $Config)) {
        $DeleteWaitSeconds = 300
    }
    if ($DeleteWaitSeconds -gt 0) {
        $Parallelism = 1
    }

    $subscriptionId = $Config['subscriptionId']
    if (-not $ResourceGroupName) {
        $ResourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($item in @($File)) {
        $description = [string](Get-DemoMemberValue -InputObject $item -Name 'Description')
        if (-not $description) {
            $description = 'bootstrap bundle'
        }
        $path = [string](Get-DemoMemberValue -InputObject $item -Name 'Path')
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw ('The {0} file {1} doesn''t exist. Build it first (New-DemoBootstrapBundle or Publish-DemoWorkloadRunner).' -f $description, $path)
        }
        $sha = ([string](Get-DemoMemberValue -InputObject $item -Name 'Sha256')).ToLowerInvariant()
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
            throw ('The {0} changed after it was built; build it again.' -f $description)
        }
        $given = Get-DemoMemberValue -InputObject $item -Name 'Chunks'
        $chunks = if ($null -ne $given) { @($given) } else { @(New-DemoBootstrapChunk -Path $path -ChunkSizeKiB $ChunkSizeKiB) }
        $entry = [pscustomobject]@{ Description = $description; Sha256 = $sha; SizeBytes = [long](Get-DemoMemberValue -InputObject $item -Name 'SizeBytes'); ChunkCount = $chunks.Count; Left = $chunks.Count; Seconds = 0.0 }
        $entries.Add($entry)
        foreach ($chunk in $chunks) {
            $pending.Enqueue([pscustomobject]@{ Chunk = $chunk; Entry = $entry })
        }
    }

    $apiVersion = Get-DemoRunCommandApiVersion
    $baseUrl = Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $ResourceGroupName -VmName $VmName
    $maxConflictRetries = 9
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # What the closures below share and change: the last time a chunk finished, a stall, and the cleanup's leftovers.
    $shared = @{ LastProgressUtc = (Get-DemoUtcNow); Stalled = $false; Leftover = @(); VmStopped = $false }
    $bodyPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dbhub-chunk-{0}.json' -f [guid]::NewGuid().ToString('N'))
    foreach ($entry in $entries) {
        Write-DemoLog -Message ('{0}: sending {1} {2} ({3} bytes) in {4} chunk(s) of {5} KiB.' -f $VmName, $entry.Description, $entry.Sha256.Substring(0, 12), $entry.SizeBytes, $entry.ChunkCount, $ChunkSizeKiB)
    }
    if ($entries.Count -gt 1) {
        $how = if ($DeleteWaitSeconds -gt 0) { 'one at a time, each chunk''s Run Command deleted before the next' } else { 'up to {0} at once' -f $Parallelism }
        Write-DemoLog -Message ('{0}: the {1} files'' {2} chunks travel together, {3}.' -f $VmName, $entries.Count, $pending.Count, $how)
    }
    try {
        $listing = @{}
        $asked = @(Clear-DemoChunkRunCommand -SubscriptionId $subscriptionId -BaseUrl $baseUrl -ApiVersion $apiVersion -Status $listing | Where-Object { $_ -is [string] -and $_ })
        # Room for the set (2026-11-16 live finding: 23 of Azure's 25 on the upgrade test's T2 host, 17 of them chunks). Every
        # Run Command listed counts, one being deleted included, and each chunk of this set can stay listed until Azure has
        # deleted it, so when they wouldn't fit under the fresh-name limit of 24 (Resolve-DemoRunCommandFreshName), the
        # deletes just asked for are waited for, at most -RoomWaitSeconds, before the first chunk.
        if ($asked.Count -gt 0 -and $listing.ContainsKey('Total') -and ([int]$listing['Total'] + $pending.Count) -gt 24) {
            $before = [int]$listing['Total']
            $total = $before
            Write-DemoLog -Message ('{0}: it lists {1} Run Commands, {2} of them chunks it just asked Azure to delete, and {3} chunk(s) need room under Azure''s limit of 25, so it waits up to {4} for those deletes first.' -f $VmName, $before, $asked.Count, $pending.Count, (Format-DemoProgressDuration -Seconds $RoomWaitSeconds))
            $roomDeadline = [System.DateTime]::UtcNow.AddSeconds($RoomWaitSeconds)
            $roomWatch = [System.Diagnostics.Stopwatch]::StartNew()
            while (($total + $pending.Count) -gt 24 -and [System.DateTime]::UtcNow -lt $roomDeadline) {
                Start-Sleep -Seconds 10
                $poll = @{}
                $null = Get-DemoChunkRunCommandName -SubscriptionId $subscriptionId -BaseUrl $baseUrl -ApiVersion $apiVersion -Status $poll -Tries 1
                if (-not $poll.ContainsKey('Total')) {
                    break
                }
                $total = [int]$poll['Total']
            }
            $waitedText = Format-DemoProgressDuration -Seconds ([long]$roomWatch.Elapsed.TotalSeconds)
            if (($total + $pending.Count) -le 24) {
                Write-DemoLog -Message ('{0}: Azure finished enough of those deletes in {1}: {2} Run Commands listed, room for the {3} chunk(s).' -f $VmName, $waitedText, $total, $pending.Count)
            }
            else {
                Write-DemoLog -Level Warning -Message ('{0}: Azure still lists {1} Run Commands after {2}, so the {3} chunk(s) go now; a chunk that finds no room stops with Azure''s limit named, and the watchdog steps in (Azure-side).' -f $VmName, $total, $waitedText, $pending.Count)
            }
        }
        # Creates one chunk's Run Command (retrying a conflict) and returns its URL. PUTs are sent one at a time,
        # so one body file serves them all.
        $putChunk = {
            param($Chunk)
            $url = '{0}/{1}?api-version={2}' -f $baseUrl, $Chunk.Name, $apiVersion
            $body = [ordered]@{
                location   = [string]$Config['location']
                properties = [ordered]@{
                    source                          = [ordered]@{ script = $Chunk.Script }
                    asyncExecution                  = $false
                    treatFailureAsDeploymentFailure = $false
                    timeoutInSeconds                = $TimeoutSeconds
                }
            }
            [System.IO.File]::WriteAllText($bodyPath, ($body | ConvertTo-Json -Depth 5 -Compress), [System.Text.UTF8Encoding]::new($false))

            $renamed = $false
            for ($attempt = 1; ; $attempt++) {
                $put = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'put', '--url', $url, '--body', "@$bodyPath") -AllowFailure
                if ($put.ExitCode -eq 0) {
                    break
                }
                if (Test-DemoAzVmNotRunning -Text $put.StdErr) {
                    $shared['VmStopped'] = $true
                    throw ('{0} isn''t running (deallocated), so it can''t receive chunks; start it first (start-demo.ps1), then send again.' -f $VmName)
                }
                if (-not $renamed -and (Test-DemoRunCommandHeldError -Text $put.StdErr)) {
                    # Azure keeps the name marked for deletion (an earlier run's chunk; on archost01 it held 17 for hours,
                    # and the refused PUT restarted the VM, 2026-11-16), so the chunk runs under a fresh name at once, like
                    # a named Run Command, before any conflict backoff. The script is the same, so the VM writes the same
                    # chunk-<nnn> file, and the name still matches DbHubDemo-Chunk-*, so the cleanup deletes it.
                    $renamed = $true
                    $fresh = Resolve-DemoRunCommandFreshName -SubscriptionId $subscriptionId -BaseUrl $baseUrl -ApiVersion $apiVersion -VmName $VmName -RunCommandName $Chunk.Name -ForChunk
                    $url = '{0}/{1}?api-version={2}' -f $baseUrl, $fresh, $apiVersion
                    continue
                }
                if ($attempt -le $maxConflictRetries -and (Test-DemoAzConflict -Text $put.StdErr)) {
                    $delay = Get-DemoConflictDelay -Attempt $attempt
                    Write-DemoLog -Level Warning -Message ('{0}: chunk {1} of {2} hit a conflict: an extension that a policy installs or updates (Guest Configuration, Defender for SQL, MDE.Windows) is busy; retry {3} of {4} in {5} seconds.' -f $VmName, $Chunk.Index, $Chunk.Count, $attempt, $maxConflictRetries, $delay)
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw ('{0}: sending chunk {1} of {2} failed: {3}' -f $VmName, $Chunk.Index, $Chunk.Count, (Protect-DemoText -Text ([string]$put.StdErr).Trim()))
            }
            return $url
        }
        # Checks a finished chunk, deletes its Run Command, logs it, and notes when its file is complete.
        $finishChunk = {
            param($Item, $Url, $State)
            $Chunk = $Item.Chunk
            if (-not $State.Found) {
                throw ('{0}: chunk {1} of {2} could not be read back: {3}' -f $VmName, $Chunk.Index, $Chunk.Count, $State.Error)
            }
            if ($State.ExecutionState -ne 'Succeeded' -or $State.ExitCode -ne 0) {
                $detail = if ($State.Error) { $State.Error } else { $State.Output }
                throw ('{0}: chunk {1} of {2} failed on the VM (execution state {3}, provisioning state {4}, exit code {5}): {6}' -f $VmName, $Chunk.Index, $Chunk.Count, $State.ExecutionState, $State.ProvisioningState, $State.ExitCode, $detail)
            }
            if ($DeleteWaitSeconds -gt 0) {
                # One chunk on the VM at a time (R871): its Run Command is gone before the next chunk goes. A delete Azure
                # ends without deleting it is asked for once more; a second one stops the transfer, so no more chunks stay.
                # The wait counts its own polls, 15 seconds apart (no conflict backoff step uses 15).
                $waitText = Format-DemoProgressDuration -Seconds $DeleteWaitSeconds
                $gone = $false
                for ($round = 1; $round -le 2 -and -not $gone; $round++) {
                    if ($round -gt 1) {
                        Write-DemoLog -Level Warning -Message ('{0}: Azure didn''t delete the Run Command of chunk {1} of {2} within {3}, so it''s deleted once more.' -f $VmName, $Chunk.Index, $Chunk.Count, $waitText)
                    }
                    $null = Remove-DemoRunCommand -SubscriptionId $subscriptionId -Url $Url -NoWait -Confirm:$false
                    for ($waited = 0; $waited -lt $DeleteWaitSeconds -and -not $gone; $waited += 15) {
                        Start-Sleep -Seconds 15
                        $gone = [bool](Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url $Url).NotFound
                    }
                }
                if (-not $gone) {
                    throw ('{0}: Azure didn''t delete the Run Command of chunk {1} of {2}, twice in {3}, so the transfer stops before more chunks stay on {0}: a VM that keeps them may not start again (R871).' -f $VmName, $Chunk.Index, $Chunk.Count, $waitText)
                }
            }
            elseif (-not (Remove-DemoRunCommand -SubscriptionId $subscriptionId -Url $Url -NoWait -Confirm:$false)) {
                Write-DemoLog -Level Warning -Message ('{0}: the Run Command for chunk {1} of {2} couldn''t be deleted yet; the cleanup at the end tries again.' -f $VmName, $Chunk.Index, $Chunk.Count)
            }
            $shared['LastProgressUtc'] = Get-DemoUtcNow
            Write-DemoLog -Message ('{0}: chunk {1} of {2} delivered ({3} bytes, SHA-256 {4}).' -f $VmName, $Chunk.Index, $Chunk.Count, $Chunk.SizeBytes, $Chunk.Sha256.Substring(0, 12))
            $entry = $Item.Entry
            $entry.Left--
            if ($entry.Left -eq 0) {
                $entry.Seconds = [System.Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
                Write-DemoLog -Level Success -Message ('{0}: {1} {2} delivered in {3} chunk(s) in {4} seconds.' -f $VmName, $entry.Description, $entry.Sha256.Substring(0, 12), $entry.ChunkCount, $entry.Seconds)
            }
        }

        if ($Parallelism -le 1) {
            while ($pending.Count -gt 0) {
                $item = $pending.Dequeue()
                $url = & $putChunk $item.Chunk
                $state = Wait-DemoRunCommand -SubscriptionId $subscriptionId -Url $url -TimeoutSeconds ($TimeoutSeconds + 300)
                if ($state.WaitTimedOut) {
                    throw ('{0}: chunk {1} of {2} did not finish within {3} seconds (execution state {4}).' -f $VmName, $item.Chunk.Index, $item.Chunk.Count, ($TimeoutSeconds + 300), $state.ExecutionState)
                }
                & $finishChunk $item $url $state
            }
        }
        else {
            $terminal = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
            $active = [System.Collections.Generic.List[object]]::new()
            $limit = $Parallelism
            $shared['LastProgressUtc'] = Get-DemoUtcNow
            while ($pending.Count -gt 0 -or $active.Count -gt 0) {
                while ($active.Count -lt $limit -and $pending.Count -gt 0) {
                    $item = $pending.Dequeue()
                    $url = & $putChunk $item.Chunk
                    $active.Add([pscustomobject]@{ Item = $item; Url = $url; DeadlineUtc = [System.DateTime]::UtcNow.AddSeconds($TimeoutSeconds + 300) })
                }
                Start-Sleep -Seconds 10
                foreach ($running in @($active)) {
                    $state = Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url $running.Url
                    $done = $state.Found -and ($state.ExecutionState -in $terminal -or $state.ProvisioningState -eq 'Failed')
                    if (-not $done -and -not $state.NotFound) {
                        if ([System.DateTime]::UtcNow -ge $running.DeadlineUtc) {
                            throw ('{0}: chunk {1} of {2} did not finish within {3} seconds (execution state {4}).' -f $VmName, $running.Item.Chunk.Index, $running.Item.Chunk.Count, ($TimeoutSeconds + 300), $state.ExecutionState)
                        }
                        continue
                    }
                    & $finishChunk $running.Item $running.Url $state
                    $null = $active.Remove($running)
                }
                # A stall (no chunk finished for StallSeconds while several run): the rest go one at a time, which a busy
                # extension handles better than a queue of parallel ones (Phase 28).
                if ($limit -gt 1 -and $active.Count -gt 0 -and ((Get-DemoUtcNow) - [datetime]$shared['LastProgressUtc']).TotalSeconds -ge $StallSeconds) {
                    $limit = 1
                    $shared['Stalled'] = $true
                    Write-DemoLog -Level Warning -Message ('{0}: no chunk finished for {1} seconds while {2} ran, so the rest go one at a time. Azure is busy with the VM''s extensions (Azure-side; nothing to do).' -f $VmName, $StallSeconds, $active.Count)
                }
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        try {
            # A VM that isn't running gets no cleanup now, and neither does a stopped run (Ctrl+C, Phase 28 live finding):
            # the next run's cleanup does it.
            $shared['Leftover'] = if ($shared['VmStopped'] -or (Test-DemoRunCancelled)) { @() } else { @(Wait-DemoChunkRunCommandGone -SubscriptionId $subscriptionId -BaseUrl $baseUrl -ApiVersion $apiVersion -TimeoutSeconds $CleanupWaitSeconds) }
            if (@($shared['Leftover']).Count -gt 0) {
                Write-DemoLog -Level Warning -Message ('{0}: Azure is still deleting {1} chunk Run Command(s) ({2}); that''s Azure-side and finishes on its own, and the next run checks again.' -f $VmName, @($shared['Leftover']).Count, (@($shared['Leftover']) -join ', '))
            }
        }
        catch {
            Write-DemoLog -Level Warning -Message ('{0}: leftover chunk Run Commands could not be checked: {1}' -f $VmName, $_.Exception.Message)
        }
    }
    return @(foreach ($entry in $entries) {
            [pscustomobject]@{ Description = $entry.Description; Sha256 = $entry.Sha256; ChunkCount = $entry.ChunkCount; Seconds = $entry.Seconds; Stalled = [bool]$shared['Stalled']; LeftoverRunCommands = @($shared['Leftover']) }
        })
}

function Invoke-DemoAzWithConflictRetry {
    <#
    .SYNOPSIS
    Runs one Azure CLI command through Invoke-DemoAz and retries it with backoff while Azure answers 409
    Conflict or another operation is in progress. Internal.

    .DESCRIPTION
    Tenant policies install the Guest Configuration and Defender for SQL extensions on VMs and Arc machines
    after a deployment, and update MDE.Windows later, and a VM or Arc machine rejects other changes while they
    run (ADR 0012, PREFLIGHT.POLICY.EXTENSIONS). Live, an MDE.Windows update blocked Run Commands on archost01
    for about 10 minutes (R49), so the default nine retries wait 10, 20, 40, 80, then 120 seconds each, about
    12.5 minutes in all, the same backoff as Send-DemoBootstrapBundle. A VM that isn't running (deallocated)
    isn't retried: the warning says so at once. Returns the last result object (ExitCode, StdOut, StdErr)
    without throwing, so the caller decides; nothing it logs contains the arguments, which can hold @<file>
    paths only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $Label,

        [ValidateRange(0, 12)]
        [int] $MaxConflictRetries = 9,

        # Bounds each try (Invoke-DemoAz -TimeoutSeconds); 0 leaves it to the command (2026-11-16: calls that wait on a VM,
        # such as 'az vm extension set', pass one).
        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0
    )

    $bound = @{}
    if ($TimeoutSeconds -gt 0) {
        $bound['TimeoutSeconds'] = $TimeoutSeconds
    }
    for ($attempt = 1; ; $attempt++) {
        $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList $ArgumentList -AllowFailure @bound
        if ($result.ExitCode -eq 0) {
            return $result
        }
        if (Test-DemoAzVmNotRunning -Text $result.StdErr) {
            Write-DemoLog -Level Warning -Message ('{0}: the VM isn''t running (deallocated), so Azure refused the operation; start it first (start-demo.ps1).' -f $Label)
            return $result
        }
        if ($attempt -le $MaxConflictRetries -and (Test-DemoAzConflict -Text $result.StdErr)) {
            $delay = Get-DemoConflictDelay -Attempt $attempt
            Write-DemoLog -Level Warning -Message ('{0} hit a conflict: an extension that a policy installs or updates (Guest Configuration, Defender for SQL, MDE.Windows) is busy on the VM; retry {1} of {2} in {3} seconds.' -f $Label, $attempt, $MaxConflictRetries, $delay)
            Start-Sleep -Seconds $delay
            continue
        }
        return $result
    }
}

function ConvertFrom-DemoRunCommandOutput {
    <#
    .SYNOPSIS
    Returns the last line of a Run Command's output that parses as a JSON object, or $null. Internal.

    .DESCRIPTION
    The demo's VM-side scripts print one compact JSON object as their last line of output, because the
    instance view keeps only the last 4 KB of output
    (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $lines = @($Text -split '\r?\n')
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if ($line.StartsWith('{') -and $line.EndsWith('}')) {
            try {
                return ($line | ConvertFrom-Json -Depth 16)
            }
            catch {
                Write-Debug -Message 'A Run Command output line looked like JSON but did not parse.'
            }
        }
    }
    return $null
}

function Test-DemoRunCommandFinished {
    <#
    .SYNOPSIS
    Whether a managed Run Command's script has ended, for the cleanup of the on-demand control's Run Commands by
    start-demo.ps1: its execution state is terminal (Succeeded, Failed, Canceled, or TimedOut), or the state is empty
    or Unknown and the time at the end of its name (-yyyyMMddHHmmss, UTC) is more than an hour old. Internal.

    .DESCRIPTION
    An empty or Unknown state is what a Run Command shows right after it's created, before the VM agent picks it up,
    and after a deallocation cleared its instance view; only the age in its name tells the two apart, and the
    control's longest timeout is 25 minutes. Without a time in its name, or in any other state (Pending, Running), it
    isn't finished, so a control run that overlaps start-demo.ps1 never loses a Run Command it has just created
    (Phase 28 follow-up review). The control's runbooks (Clear-DbHubOldRunCommand -FinishedOnly) use the same hour but
    count any state that isn't terminal once the hour has passed. Execution states:
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/get-by-virtual-machine
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [AllowEmptyString()]
        [string] $ExecutionState = '',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    if ($ExecutionState -in 'Succeeded', 'Failed', 'Canceled', 'TimedOut') {
        return $true
    }
    if ($ExecutionState -and $ExecutionState -ne 'Unknown') {
        return $false
    }
    $stamp = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ($Name -match '-(\d{14})$' -and [DateTime]::TryParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$stamp)) {
        return $stamp.AddHours(1) -lt $NowUtc.ToUniversalTime()
    }
    return $false
}

function Get-DemoVmRunCommandLeftover {
    <#
    .SYNOPSIS
    The demo's managed Run Commands left on one VM, read-only: the on-demand control's DbHubControl-* and the scripts'
    DbHubDemo-*, except the two that stay on each VM by design: the bootstrap loader DbHubDemo-Bootstrap, which the template
    (or deploy.ps1) keeps (ADR 0003), and DbHubDemo-Profile, the activity profiles' one Run Command, which each profile
    change replaces and whose script does nothing once it has expired (Send-DemoProfileRunCommand, 2026-11-03). Internal.

    .DESCRIPTION
    One read: Virtual Machine Run Commands - List By Virtual Machine with $expand=instanceView
    (https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine). Not counted:
    one that Azure is deleting (provisioningState Deleting), and on a running VM one whose script is still Pending or
    Running (a deployment, a check, or an on-demand run in progress). Nothing runs on a VM that isn't running, so there
    every one of them counts. Names of anything else aren't the demo's and are left out. Azure allows 25 managed Run
    Commands per VM (https://learn.microsoft.com/azure/virtual-machines/run-command-overview). Returns Ok, Error, and
    Items (VmName, Name, Kind Control or Demo, ExecutionState, ProvisioningState, Finished, by
    Test-DemoRunCommandFinished, and Deleting). With -IncludeDeleting (the T2 host, 2026-11-17), the demo's ones that Azure
    is deleting are items too, the bootstrap loader and the profile included, with Deleting set: on that host, they go
    with a VM agent that isn't working (R871).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [switch] $Running,

        [switch] $IncludeDeleting,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $base = Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $VmName
    $list = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}&$expand=instanceView' -f $base, (Get-DemoRunCommandApiVersion))) -AllowFailure
    if ($list.ExitCode -ne 0) {
        return [pscustomobject]@{ Ok = $false; Error = (Protect-DemoText -Text ([string]$list.StdErr).Trim()); Items = @() }
    }
    $parsed = if ([string]::IsNullOrWhiteSpace([string]$list.StdOut)) { $null } else { [string]$list.StdOut | ConvertFrom-Json -Depth 32 }
    # Assigned first: Get-DemoMemberValue returns an array as one object, which @() wouldn't unroll.
    $values = Get-DemoMemberValue -InputObject $parsed -Name 'value'
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($values)) {
        $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
        $kind = if ($name.StartsWith('DbHubControl-', [System.StringComparison]::Ordinal)) { 'Control' } elseif ($name.StartsWith('DbHubDemo-', [System.StringComparison]::Ordinal)) { 'Demo' } else { '' }
        if (-not $kind) {
            continue
        }
        $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
        $provisioning = [string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState')
        $execution = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'instanceView') -Name 'executionState')
        $deleting = $provisioning -eq 'Deleting'
        if ($deleting) {
            if (-not $IncludeDeleting) {
                continue
            }
        }
        elseif ($name -in 'DbHubDemo-Bootstrap', 'DbHubDemo-Profile' -or ($Running -and $execution -in 'Pending', 'Running')) {
            continue
        }
        $items.Add([pscustomobject]@{ VmName = $VmName; Name = $name; Kind = $kind; ExecutionState = $execution; ProvisioningState = $provisioning; Finished = (Test-DemoRunCommandFinished -Name $name -ExecutionState $execution -NowUtc $NowUtc); Deleting = $deleting })
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Items = $items.ToArray() }
}

function Get-DemoRunCommandDeleteCommand {
    # The Azure CLI command that deletes one Run Command, for a result's remediation. Internal.
    # https://learn.microsoft.com/cli/azure/vm/run-command#az-vm-run-command-delete
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [string] $Name
    )

    return ('az vm run-command delete --resource-group {0} --vm-name {1} --name {2} --subscription {3} --yes' -f (Get-DemoResourceGroupName -Config $Config), $VmName, $Name, [string]$Config['subscriptionId'])
}

function Remove-DemoControlRunCommand {
    <#
    .SYNOPSIS
    start-demo.ps1's cleanup of the on-demand control's finished Run Commands (DbHubControl-*) on the VMs that run,
    without waiting for the deletes (START.CONTROL.RUNCOMMANDS). Internal.

    .DESCRIPTION
    The control deletes its earlier Run Commands when a run or a reset starts, but its stop path never touches Run
    Command (ADR 0020), so a VM keeps the last run's until the next run or this start. Only finished ones go
    (Test-DemoRunCommandFinished): a terminal execution state, or an empty or Unknown one more than an hour after the
    time in its name, so a control run that overlaps this start keeps the Run Command it has just created (Phase 28
    follow-up review). A VM that isn't running can't have one removed, so only the VMs that run are
    cleaned; a list or delete that fails, for example because a VM was deallocated meanwhile, is a Warning that the
    next start retries, never a Fail. Returns nothing with control.enabled false and nothing to delete.
    - Delete: https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/delete
    - Limit of 25 per VM: https://learn.microsoft.com/azure/virtual-machines/run-command-overview
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [string[]] $VmName = @()
    )

    $doc = 'https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/delete'
    $subscriptionId = [string]$Config['subscriptionId']
    $apiVersion = Get-DemoRunCommandApiVersion
    $deleted = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $commands = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($VmName | Where-Object { $_ })) {
        $found = Get-DemoVmRunCommandLeftover -Config $Config -VmName $vm -Running
        if (-not $found.Ok) {
            $failed.Add(('{0}: the Run Commands couldn''t be listed ({1})' -f $vm, $found.Error))
            continue
        }
        foreach ($item in @($found.Items | Where-Object { $_.Kind -eq 'Control' -and $_.Finished })) {
            if (-not $PSCmdlet.ShouldProcess(('{0}/{1}' -f $vm, $item.Name), 'Delete the on-demand control''s finished Run Command')) {
                continue
            }
            $url = '{0}/{1}?api-version={2}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $vm), $item.Name, $apiVersion
            $delete = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', $url) -AllowFailure
            if ($delete.ExitCode -eq 0 -or (Test-DemoAzNotFound -Text ([string]$delete.StdErr))) {
                $deleted.Add(('{0}/{1}' -f $vm, $item.Name))
                continue
            }
            $why = if (Test-DemoAzVmNotRunning -Text ([string]$delete.StdErr)) { 'the VM isn''t running' } else { (Get-DemoDeploymentErrorText -Text ([string]$delete.StdErr) -MaxLength 300) }
            $failed.Add(('{0}/{1}: {2}' -f $vm, $item.Name, $why))
            $commands.Add((Get-DemoRunCommandDeleteCommand -Config $Config -VmName $vm -Name $item.Name))
        }
    }
    $evidence = [ordered]@{ deleted = $deleted.ToArray(); failed = $failed.ToArray(); vms = @($VmName) }
    if ($failed.Count -gt 0) {
        $done = if ($deleted.Count) { ' Deleted: {0}.' -f ($deleted -join ', ') } else { '' }
        $fix = 'The next start-demo.ps1 tries again, and so does the on-demand control''s next run.{0}' -f $(if ($commands.Count) { ' To delete one now, while its VM runs: {0}' -f $commands[0] } else { '' })
        return (New-DemoResult -CheckId 'START.CONTROL.RUNCOMMANDS' -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The on-demand control''s finished Run Commands weren''t all deleted: {0}.{1}' -f ($failed -join '; '), $done) -Evidence $evidence -Remediation $fix -DocUrl $doc)
    }
    if ($deleted.Count -gt 0) {
        return (New-DemoResult -CheckId 'START.CONTROL.RUNCOMMANDS' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('Deleted {0} finished Run Command(s) the on-demand control left on the VMs: {1}. Azure allows 25 managed Run Commands per VM.' -f $deleted.Count, ($deleted -join ', ')) -Evidence $evidence -DocUrl $doc)
    }
    if ((Get-DemoActivityControlSetting -Config $Config).Enabled) {
        return (New-DemoResult -CheckId 'START.CONTROL.RUNCOMMANDS' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message ('No finished Run Command of the on-demand control is left on {0}.' -f $(if (@($VmName).Count) { @($VmName) -join ' or ' } else { 'a running VM' })) -Evidence $evidence -DocUrl $doc)
    }
    return $null
}

function Get-DemoRunCommandStatus {
    <#
    .SYNOPSIS
    STATUS.RUNCOMMANDS for status.ps1, read-only: the demo's leftover managed Run Commands on its VMs
    (Get-DemoVmRunCommandLeftover). Pass when there's none; a Warning that names them, with the commands that delete
    them, otherwise, or when they can't be listed. On a running VM, a control Run Command that isn't finished
    (Test-DemoRunCommandFinished) belongs to a run in progress and isn't counted, so no delete command stops it.
    On the T2 host, archost01 (2026-11-17), the demo's Run Commands that Azure is still deleting come first, as a Warning
    whose fix is deploy.ps1: ones that stay there go with a VM agent that isn't working (R871), which deploy.ps1 recovers,
    or rebuilds the host for (R872). -RunInProgress names a run the busy marker says is going on, whose own deletes show
    for a few minutes. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowEmptyCollection()]
        [string[]] $VmName = @(),

        [System.Collections.IDictionary] $Running = @{},

        [string] $RunInProgress = ''
    )

    $doc = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $left = [System.Collections.Generic.List[object]]::new()
    $marked = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $hostVm = Get-DemoHostVmName -Config $Config
    foreach ($vm in @($VmName | Where-Object { $_ })) {
        $found = Get-DemoVmRunCommandLeftover -Config $Config -VmName $vm -Running:([bool]$Running[$vm]) -IncludeDeleting:($vm -eq 'archost01' -and $hostVm -eq $vm)
        if (-not $found.Ok) {
            $errors.Add(('{0}: {1}' -f $vm, $found.Error))
            continue
        }
        foreach ($item in @($found.Items)) {
            if ([bool](Get-DemoMemberValue -InputObject $item -Name 'Deleting')) {
                $marked.Add($item)
                continue
            }
            if ([bool]$Running[$vm] -and $item.Kind -eq 'Control' -and -not $item.Finished) {
                continue
            }
            $left.Add($item)
        }
    }
    $names = @($left | ForEach-Object { '{0}/{1}' -f $_.VmName, $_.Name })
    $markedNames = @($marked | ForEach-Object { '{0}/{1}' -f $_.VmName, $_.Name })
    $commands = @($left | Select-Object -First 10 | ForEach-Object { Get-DemoRunCommandDeleteCommand -Config $Config -VmName $_.VmName -Name $_.Name })
    $evidence = [ordered]@{ leftover = $names; markedForDeletion = $markedNames; deleteCommands = $commands; readErrors = $errors.ToArray(); vms = @($VmName); runInProgress = $RunInProgress }
    $vmText = if (@($VmName).Count) { @($VmName) -join ' and ' } else { 'the demo VMs' }
    $more = if ($errors.Count) { ' The Run Commands of {0} couldn''t be listed.' -f (($errors | ForEach-Object { $_.Split(':')[0] }) -join ' and ') } else { '' }
    if ($marked.Count -gt 0) {
        $shown = @($markedNames | Select-Object -First 10) -join ', '
        $extra = if ($marked.Count -gt 10) { ' and {0} more' -f ($marked.Count - 10) } else { '' }
        $during = if ($RunInProgress) { ' {0} is running now, and a run''s own deletes show here for a few minutes.' -f $RunInProgress } else { '' }
        $others = if ($left.Count -gt 0) { ' {0} other managed Run Command(s) are left: {1}.' -f $left.Count, ($names -join ', ') } else { '' }
        $message = '{0} Run Command(s) on archost01, T2''s host, are marked for deletion, and Azure hasn''t finished deleting them: {1}{2}.{3} Ones that stay there go with a VM agent that isn''t working, and they count toward the VM''s limit of 25 managed Run Commands.{4}{5}' -f $marked.Count, $shown, $extra, $during, $others, $more
        $fix = 'Run ./scripts/deploy.ps1{0}: when archost01''s VM agent is down, it sends the deletes of its chunk Run Commands again and deallocates and starts the host, which completes them, and it rebuilds the host once if the agent stays down (DEPLOY.T2.HOSTREBUILD). Deleting them yourself doesn''t help: Azure is already deleting them. See docs/troubleshooting.md ("A host''s VM agent that isn''t Ready").' -f $(if ($RunInProgress) { ' after that run ends, if they''re still listed' } else { '' })
        return (New-DemoResult -CheckId 'STATUS.RUNCOMMANDS' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $fix -DocUrl $doc)
    }
    if ($left.Count -gt 0) {
        $control = @($left | Where-Object { $_.Kind -eq 'Control' }).Count
        $why = @(
            if ($control) { 'start-demo.ps1 deletes the on-demand control''s finished ones (DbHubControl-*) once the VMs run, and so does the control''s next run' }
            if ($left.Count - $control) { 'the next run of the step that made a DbHubDemo-* one deletes it first' }
        ) -join '; '
        $fix = 'Nothing is needed: {0}. To delete one now, while its VM runs: {1}{2}. Azure allows 25 managed Run Commands per VM.' -f $why, $commands[0], $(if ($commands.Count -gt 1) { ' (each command is in this result''s evidence)' } else { '' })
        return (New-DemoResult -CheckId 'STATUS.RUNCOMMANDS' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('{0} managed Run Command(s) are left on the demo VMs: {1}.{2}' -f $left.Count, ($names -join ', '), $more) -Evidence $evidence -Remediation $fix -DocUrl $doc)
    }
    if ($errors.Count -gt 0) {
        return (New-DemoResult -CheckId 'STATUS.RUNCOMMANDS' -Area 'infra' -Target 'subscription' -Status 'Warning' -Message ('The Run Commands on the demo VMs couldn''t all be listed: {0}' -f ($errors -join '; ')) -Evidence $evidence -Remediation 'Run status.ps1 again; listing Run Commands needs Reader or higher on the resource group.' -DocUrl $doc)
    }
    return (New-DemoResult -CheckId 'STATUS.RUNCOMMANDS' -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('No leftover Run Command on {0}; the bootstrap loader DbHubDemo-Bootstrap and the activity profiles'' DbHubDemo-Profile stay by design.' -f $vmText) -Evidence $evidence -DocUrl $doc)
}
