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

function Clear-DemoChunkRunCommand {
    # Deletes every DbHubDemo-Chunk-* Run Command left on a VM, for example by an interrupted run, without waiting for
    # Azure to finish each delete. Returns the names it asked Azure to delete. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $BaseUrl,

        [Parameter(Mandatory)]
        [string] $ApiVersion
    )

    $names = Get-DemoChunkRunCommandName -SubscriptionId $SubscriptionId -BaseUrl $BaseUrl -ApiVersion $ApiVersion
    if ($null -eq $names) {
        Write-DemoLog -Level Warning -Message 'The Run Commands on the VM could not be listed, so leftover chunk Run Commands were not checked.'
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
    # when they can't be listed. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $BaseUrl,

        [Parameter(Mandatory)]
        [string] $ApiVersion
    )

    $list = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}' -f $BaseUrl, $ApiVersion)) -AsJson -AllowFailure
    if ($null -eq $list) {
        return $null
    }
    $items = Get-DemoMemberValue -InputObject $list -Name 'value'
    return @(foreach ($item in @($items)) {
            $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            if ($name -like 'DbHubDemo-Chunk-*') {
                $name
            }
        })
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
    Conflict is retried with backoff), read its instance view until the script is terminal (exit code 0
    required), then DELETE it without waiting for Azure to finish the delete (Phase 28: a delete that a busy,
    usually policy-installed, extension holds cost up to 3 minutes per chunk before; R49, R336). Up to
    -Parallelism chunk Run Commands run at once, read every 10 seconds; with 1 they go one at a time. When no
    chunk finishes for -StallSeconds while several run, the rest go one at a time (Stalled). Leftover
    DbHubDemo-Chunk-* Run Commands are deleted before the first chunk, and once at the end, in a finally block,
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
        [int] $CleanupWaitSeconds = 120
    )

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
        Write-DemoLog -Message ('{0}: the {1} files'' {2} chunks travel together, up to {3} at once.' -f $VmName, $entries.Count, $pending.Count, $Parallelism)
    }
    try {
        Clear-DemoChunkRunCommand -SubscriptionId $subscriptionId -BaseUrl $baseUrl -ApiVersion $apiVersion | Out-Null
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

            for ($attempt = 1; ; $attempt++) {
                $put = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'put', '--url', $url, '--body', "@$bodyPath") -AllowFailure
                if ($put.ExitCode -eq 0) {
                    break
                }
                if (Test-DemoAzVmNotRunning -Text $put.StdErr) {
                    $shared['VmStopped'] = $true
                    throw ('{0} isn''t running (deallocated), so it can''t receive chunks; start it first (start-demo.ps1), then send again.' -f $VmName)
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
            if (-not (Remove-DemoRunCommand -SubscriptionId $subscriptionId -Url $Url -NoWait -Confirm:$false)) {
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
            # A VM that isn't running gets no cleanup now; its next run's cleanup does it.
            $shared['Leftover'] = if ($shared['VmStopped']) { @() } else { @(Wait-DemoChunkRunCommandGone -SubscriptionId $subscriptionId -BaseUrl $baseUrl -ApiVersion $apiVersion -TimeoutSeconds $CleanupWaitSeconds) }
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
        [int] $MaxConflictRetries = 9
    )

    for ($attempt = 1; ; $attempt++) {
        $result = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList $ArgumentList -AllowFailure
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
