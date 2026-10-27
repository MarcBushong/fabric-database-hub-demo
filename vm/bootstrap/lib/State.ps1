function Get-DemoVmState {
    <#
    .SYNOPSIS
    Returns state.json as an ordered hashtable, or a new state when the file doesn't exist yet.
    #>
    [CmdletBinding()]
    param()

    $context = Get-DemoVmContext
    $state = Read-DemoVmJsonFile -Path $context.StatePath
    if ($null -eq $state) {
        $state = [ordered]@{}
    }
    $now = Get-DemoVmUtcNow
    $defaults = [ordered]@{
        schemaVersion      = 1
        role               = $context.Role
        generation         = ''
        state              = 'NotStarted'
        currentStep        = $null
        message            = 'The bootstrap has not run yet.'
        instructions       = @()
        warnings           = @()
        pendingReboot      = $false
        rebootRequestedUtc = $null
        rebootCount        = 0
        startedUtc         = $now
        updatedUtc         = $now
        completedUtc       = $null
        steps              = [ordered]@{}
    }
    foreach ($key in $defaults.Keys) {
        if (-not $state.Contains($key)) {
            $state[$key] = $defaults[$key]
        }
    }
    if ($null -eq $state['steps']) {
        $state['steps'] = [ordered]@{}
    }
    $state['instructions'] = @($state['instructions'] | Where-Object { $_ })
    $state['warnings'] = @($state['warnings'] | Where-Object { $_ })
    return $state
}

function Save-DemoVmState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State
    )

    $State['updatedUtc'] = Get-DemoVmUtcNow
    Write-DemoVmJsonFile -Path (Get-DemoVmContext).StatePath -InputObject $State -Redact
}

function Get-DemoVmStepRecord {
    <#
    .SYNOPSIS
    Returns the record for one step in the state, adding a Pending record the first time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not $State['steps'].Contains($Name)) {
        $State['steps'][$Name] = [ordered]@{
            status          = 'Pending'
            attempts        = 0
            rebootCount     = 0
            firstStartedUtc = $null
            lastStartedUtc  = $null
            completedUtc    = $null
            lastError       = $null
            message         = $null
        }
    }
    return $State['steps'][$Name]
}

function Add-DemoVmWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message
    )

    if ($Message -and @($State['warnings']) -notcontains $Message) {
        $State['warnings'] = @(@($State['warnings']) + $Message)
    }
}

function Enter-DemoVmLock {
    <#
    .SYNOPSIS
    Takes the bootstrap lock: an exclusive handle on bootstrap.lock. Returns $null when another run holds it.

    .DESCRIPTION
    The operating system releases the handle when the process ends, so a crashed run never leaves a stale lock.
    #>
    [CmdletBinding()]
    param()

    $context = Get-DemoVmContext
    try {
        $stream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList @($context.LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException -and $exception -isnot [System.IO.IOException]) {
            $exception = $exception.InnerException
        }
        if ($exception -is [System.IO.IOException]) {
            Write-DemoVmLog -Message 'Another bootstrap run holds the lock; this run exits.'
            return $null
        }
        throw
    }
    $text = [System.Text.Encoding]::ASCII.GetBytes(('pid={0} runId={1} startedUtc={2}' -f $PID, $context.RunId, (Get-DemoVmUtcNow)))
    $stream.SetLength(0)
    $stream.Write($text, 0, $text.Length)
    $stream.Flush()
    return $stream
}

function Exit-DemoVmLock {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [System.IO.FileStream] $Lock
    )

    if ($null -ne $Lock) {
        $Lock.Dispose()
    }
}

function New-DemoVmStepResult {
    <#
    .SYNOPSIS
    The value a step's Set block returns to tell the runner what happened.

    .DESCRIPTION
    Done: re-run the step's Test to confirm. RebootRequired: restart from the task, then resume.
    Waiting: stop here until an outside event (Arc onboarding, a product key, the guest's SQL Server). ManualActionRequired: stop
    with operator instructions. InProgress: long work continues on the next run. Failed: stop without
    retrying. NotSelected: the step doesn't apply.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Done', 'RebootRequired', 'Waiting', 'ManualActionRequired', 'InProgress', 'Failed', 'NotSelected')]
        [string] $Outcome = 'Done',

        [ValidateSet('', 'WaitingForArcOnboarding', 'WaitingForProductKey', 'WaitingForGuestSql', 'WaitingForInput')]
        [string] $WaitState = '',

        [string] $Message = '',

        [string[]] $Instruction = @(),

        [string[]] $WarningMessage = @()
    )

    [pscustomobject]@{
        PSTypeName     = 'DbHubDemo.VmStepResult'
        Outcome        = $Outcome
        WaitState      = $WaitState
        Message        = $Message
        Instruction    = @($Instruction)
        WarningMessage = @($WarningMessage)
    }
}

function Write-DemoVmHealth {
    <#
    .SYNOPSIS
    Writes health.json (vm/health/health.schema.json). The validator reads it through Run Command.

    .DESCRIPTION
    status maps the machine state to the ADR 0012 statuses: Ready is Pass (Warning with warnings), Failed
    is Fail, ManualActionRequired is "Manual action required", and every in-flight state is Warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [System.Collections.IDictionary] $Detail = @{}
    )

    $context = Get-DemoVmContext
    $warnings = @($State['warnings'] | Where-Object { $_ })
    $status = 'Warning'
    if ($State['state'] -eq 'Ready' -and $warnings.Count -eq 0) {
        $status = 'Pass'
    }
    elseif ($State['state'] -eq 'Failed') {
        $status = 'Fail'
    }
    elseif ($State['state'] -eq 'ManualActionRequired') {
        $status = 'Manual action required'
    }
    $steps = @(foreach ($name in $State['steps'].Keys) {
            $record = $State['steps'][$name]
            [ordered]@{
                name         = [string]$name
                status       = [string]$record['status']
                attempts     = [int]$record['attempts']
                completedUtc = $record['completedUtc']
                lastError    = $record['lastError']
            }
        })
    $health = [ordered]@{
        schemaVersion = 1
        role          = [string]$State['role']
        computerName  = [Environment]::MachineName
        state         = [string]$State['state']
        status        = $status
        message       = [string]$State['message']
        currentStep   = $State['currentStep']
        generation    = [string]$State['generation']
        instructions  = @($State['instructions'] | Where-Object { $_ })
        warnings      = $warnings
        rebootCount   = [int]$State['rebootCount']
        startedUtc    = $State['startedUtc']
        updatedUtc    = Get-DemoVmUtcNow
        completedUtc  = $State['completedUtc']
        steps         = $steps
        details       = $Detail
    }
    Write-DemoVmJsonFile -Path $context.HealthPath -InputObject $health -Redact
}

function Invoke-DemoVmRestart {
    <#
    .SYNOPSIS
    Restarts the computer from the scheduled task (never from an extension); the task resumes at startup.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($PSCmdlet.ShouldProcess([Environment]::MachineName, 'Restart the computer to resume the bootstrap')) {
        Write-DemoVmLog -Message 'Restarting the computer; the scheduled task resumes at startup.'
        Restart-Computer -Force
    }
}
