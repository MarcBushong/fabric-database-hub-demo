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
        transientWarnings  = @()
        notes              = @()
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
    $state['transientWarnings'] = @($state['transientWarnings'] | Where-Object { $_ })
    $state['notes'] = @($state['notes'] | Where-Object { $_ })
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
    # Adds a non-blocking warning to health.json's list, once. With -Step, it names the step it came from ("<Step>: ..."),
    # so validate.ps1 and status.ps1 can say which step warned (F24, 2026-11-20). With -Transient, it's a one-off note (a
    # restart that's pending, media trusted on first use, a recovery or a cleanup the step did), which the next bootstrap
    # generation clears (Clear-DemoVmTransientWarning); any other warning stays until its step's Set runs again
    # (Remove-DemoVmStepWarning), so a lasting cause keeps its warning while its step passes its Test.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message,

        [AllowEmptyString()]
        [string] $Step = '',

        [switch] $Transient
    )

    if ($Message -and $Step -and -not $Message.StartsWith(('{0}: ' -f $Step), [System.StringComparison]::Ordinal)) {
        $Message = '{0}: {1}' -f $Step, $Message
    }
    if ($Message -and @($State['warnings']) -notcontains $Message) {
        $State['warnings'] = @(@($State['warnings']) + $Message)
    }
    if ($Message -and $Transient -and @($State['transientWarnings']) -notcontains $Message) {
        $State['transientWarnings'] = @(@($State['transientWarnings']) + $Message)
    }
}

function Add-DemoVmNote {
    # Adds a note that a new VM's bootstrap gives by design to health.json's notes, once, naming its step ("<Step>: ..."),
    # as information: unlike a warning, it leaves a Ready VM's status a Pass (the expected-notes decision, 2026-11-23: a
    # sign-in cleanup that cleared an event log, the restart SQL Server setup asked for, T1's sysadmin recovery, and
    # Jumpstart's image checked by its pinned SHA-256). It's a one-off note: the next bootstrap generation clears it
    # (Clear-DemoVmTransientWarning), and its step's Set drops it when it runs again (Remove-DemoVmStepWarning).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message,

        [AllowEmptyString()]
        [string] $Step = ''
    )

    if ($Message -and $Step -and -not $Message.StartsWith(('{0}: ' -f $Step), [System.StringComparison]::Ordinal)) {
        $Message = '{0}: {1}' -f $Step, $Message
    }
    if ($Message -and @($State['notes']) -notcontains $Message) {
        $State['notes'] = @(@($State['notes']) + $Message)
    }
}

function Remove-DemoVmStepWarning {
    # A step's own warnings ("<Step>: ..."), dropped once its Set has run to its end, Done or NotSelected, which says again
    # what still holds (the F24 reviews, 2026-11-20). A Set that throws, or stops early (InProgress, Waiting, a restart),
    # leaves them: the guest it couldn't reach may still have the cause.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the in-memory state only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory = $true)]
        [string] $Step
    )

    $prefix = '{0}: ' -f $Step
    $State['warnings'] = @(@($State['warnings']) | Where-Object { $_ -and -not ([string]$_).StartsWith($prefix, [System.StringComparison]::Ordinal) })
    $State['transientWarnings'] = @(@($State['transientWarnings']) | Where-Object { $_ -and -not ([string]$_).StartsWith($prefix, [System.StringComparison]::Ordinal) })
    $State['notes'] = @(@($State['notes']) | Where-Object { $_ -and -not ([string]$_).StartsWith($prefix, [System.StringComparison]::Ordinal) })
}

# The one-off notes of bundles from before 2026-11-20, which named no step and weren't marked transient: the restart that
# SQL Server setup asked for, T1's sysadmin recovery, the sign-in cleanups, and media trusted on first use.
$script:DemoVmLegacyNotePattern = @(
    '^SQL Server setup asked for a restart',
    '^SYSTEM was not a sysadmin, so ',
    '^Windows automatic sign-in was armed on ',
    '^The sign-in cleanup cleared ',
    '^No SHA-256 is pinned for .+; its first download was trusted',
    '^The image has no Content-MD5 here'
)

# The lasting warnings of bundles from before 2026-11-20, which named no step, and the step that gives each (the F24
# re-review): a new generation names it, so the warning follows its step's lifecycle like the ones that name it.
$script:DemoVmLegacyWarningStep = [ordered]@{
    '^The SQL IaaS Agent service .+ couldn''t be restarted'                  = 'AssociatedServices'
    '^The image has no SQL Server setup media at '                           = 'AssociatedServices'
    '^SQL Server setup was still uninstalling '                              = 'AssociatedServices'
    '^Uninstalling .+ didn''t pass \(exit code '                             = 'AssociatedServices'
    '^Uninstalling .+ in .+ didn''t pass \(setup '                           = 'GuestFirstBoot'
    '^T[1-5] \(.+\) (does not resolve|was not updated)'                      = 'WorkloadRunner'
    '^T[1-5]: '                                                              = 'WorkloadRunner'
    '^Jumpstart published another ArcBox SQL Server Standard image'          = 'GuestImage'
    '^EVALUATION ONLY: this Azure VM is prepared for Azure Arc'              = 'ArcEvaluationPrep'
    '^EVALUATION ONLY: the Azure guest agent is disabled'                    = 'DisableAzureGuestAgent'
}

function Clear-DemoVmTransientWarning {
    # At a new bootstrap generation (the F24 reviews, 2026-11-20): the one-off notes go (Add-DemoVmWarning -Transient), and
    # so do the same notes from a bundle before then. Every other warning stays until its step's Set runs again to its end
    # (Remove-DemoVmStepWarning): a step whose cause lasts, such as features that setup couldn't uninstall, passes its Test
    # at the next generation, so its Set wouldn't say it again. A lasting warning from a bundle before then, which names no
    # step, gets its step's name ($script:DemoVmLegacyWarningStep), when that step is one of StepName, the steps this
    # VM runs, so it goes the same way; one that's there already that way isn't added twice.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the in-memory state only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State,

        [AllowEmptyCollection()]
        [string[]] $StepName = @()
    )

    $transient = @($State['transientWarnings'] | Where-Object { $_ })
    $kept = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($warning in @($State['warnings'])) {
        $text = [string]$warning
        if (-not $text -or $transient -contains $text) {
            continue
        }
        $legacy = $false
        foreach ($pattern in $script:DemoVmLegacyNotePattern) {
            if ($text -match $pattern) {
                $legacy = $true
                break
            }
        }
        if ($legacy) {
            continue
        }
        $named = $false
        foreach ($name in $StepName) {
            if ($name -and $text.StartsWith(('{0}: ' -f $name), [System.StringComparison]::Ordinal)) {
                $named = $true
                break
            }
        }
        if (-not $named) {
            foreach ($pattern in $script:DemoVmLegacyWarningStep.Keys) {
                $step = [string]$script:DemoVmLegacyWarningStep[$pattern]
                if ($text -match $pattern -and $StepName -contains $step) {
                    $text = '{0}: {1}' -f $step, $text
                    break
                }
            }
        }
        if (-not $kept.Contains($text)) {
            $kept.Add($text)
        }
    }
    $State['warnings'] = @($kept.ToArray())
    $State['transientWarnings'] = @()
    # The notes a new VM's bootstrap gives by design are one-off too (Add-DemoVmNote, 2026-11-23).
    $State['notes'] = @()
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

        [string[]] $WarningMessage = @(),

        # One-off notes, which the next bootstrap generation clears (Add-DemoVmWarning -Transient; the F24 review,
        # 2026-11-20); WarningMessage stays until the step's Set runs again.
        [string[]] $TransientWarningMessage = @(),

        # Notes a new VM's bootstrap gives by design, recorded as information, which leave a Ready VM a Pass
        # (Add-DemoVmNote; the expected-notes decision, 2026-11-23). One-off, as TransientWarningMessage is.
        [string[]] $NoteMessage = @()
    )

    [pscustomobject]@{
        PSTypeName              = 'DbHubDemo.VmStepResult'
        Outcome                 = $Outcome
        WaitState               = $WaitState
        Message                 = $Message
        Instruction             = @($Instruction)
        WarningMessage          = @($WarningMessage)
        TransientWarningMessage = @($TransientWarningMessage)
        NoteMessage             = @($NoteMessage)
    }
}

function Write-DemoVmHealth {
    <#
    .SYNOPSIS
    Writes health.json (vm/health/health.schema.json). The validator reads it through Run Command.

    .DESCRIPTION
    status maps the machine state to the ADR 0012 statuses: Ready is Pass (Warning with warnings), Failed
    is Fail, ManualActionRequired is "Manual action required", and every in-flight state is Warning. notes, the
    information a new VM's bootstrap gives by design (Add-DemoVmNote, 2026-11-23), don't change it.
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
        notes         = @($State['notes'] | Where-Object { $_ })
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
