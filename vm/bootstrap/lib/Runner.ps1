function Invoke-DemoVmStepTest {
    # A step's Test or When block passes when its last output is true; extra output is ignored. Blocks get
    # the step definition as their first argument, so they can read its Context without closures.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $Block,

        [System.Collections.IDictionary] $Definition = @{}
    )

    $output = @(& $Block $Definition)
    if ($output.Count -eq 0) {
        return $false
    }
    return [bool]$output[$output.Count - 1]
}

function Get-DemoVmStepOutcome {
    # A Set block may return a step result; anything else means Done.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]] $Output
    )

    $result = $null
    foreach ($item in @($Output)) {
        if ($null -ne $item -and $item.PSObject.TypeNames -contains 'DbHubDemo.VmStepResult') {
            $result = $item
        }
    }
    if ($null -eq $result) {
        $result = New-DemoVmStepResult -Outcome 'Done'
    }
    return $result
}

function Complete-DemoVmStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Record,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $Record['status'] = 'Succeeded'
    $Record['completedUtc'] = Get-DemoVmUtcNow
    $Record['lastError'] = $null
    $Record['message'] = $Message
    Write-DemoVmLog -Step $Name -Message $Message
}

function Invoke-DemoVmStateMachine {
    <#
    .SYNOPSIS
    Runs idempotent steps in order and records progress in state.json, so a run resumes where the last one stopped.

    .DESCRIPTION
    Each step is a hashtable: Name, Test (scriptblock: true when already in the desired state), Set
    (scriptblock: converge, optionally returning New-DemoVmStepResult), and optional MaxAttempts (default 3),
    When (scriptblock: false marks the step NotSelected), NotSelectedMessage, and Context. Test, Set, and
    When receive the step hashtable as their first argument, so they can read Context without closures.

    - Succeeded and NotSelected steps are skipped until the generation changes; a new generation (a new
      bundle or another loader run) re-checks every step, so a re-run converges without redoing work.
    - An exception counts one attempt and stops the run; the next run (every 5 minutes) retries. After
      MaxAttempts the step is Failed and stays Failed until the next generation.
    - RebootRequired saves pendingReboot, writes health, and restarts the computer; the startup trigger
      resumes. More than MaxRebootsPerStep reboots for one step is a failure.
    - Waiting, ManualActionRequired, and InProgress stop the run without counting an attempt.
    Returns the resulting machine state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary[]] $Step,

        [string] $Generation = '',

        [ValidateRange(1, 10)]
        [int] $MaxRebootsPerStep = 2,

        [scriptblock] $HealthDetail
    )

    $state = Get-DemoVmState
    if ($Generation -and [string]$state['generation'] -ne $Generation) {
        Write-DemoVmLog -Message ('Generation {0} (previous: {1}); every step is checked again.' -f $Generation, $state['generation'])
        foreach ($name in @($state['steps'].Keys)) {
            $record = $state['steps'][$name]
            $record['status'] = 'Pending'
            $record['attempts'] = 0
            $record['rebootCount'] = 0
            $record['lastError'] = $null
        }
        $state['generation'] = $Generation
        $state['completedUtc'] = $null
    }
    if ($state['pendingReboot']) {
        Write-DemoVmLog -Message 'Resuming after a restart.'
        $state['pendingReboot'] = $false
    }
    $state['state'] = 'InProgress'
    $state['instructions'] = @()
    $outcome = $null

    foreach ($definition in $Step) {
        $name = [string]$definition['Name']
        $record = Get-DemoVmStepRecord -State $state -Name $name
        if ($record['status'] -eq 'Succeeded' -or $record['status'] -eq 'NotSelected') {
            continue
        }
        if ($record['status'] -eq 'Failed') {
            $state['state'] = 'Failed'
            $state['currentStep'] = $name
            $state['message'] = 'Step {0} failed and is retried only when the bootstrap runs again (deploy.ps1 -Resume): {1}' -f $name, $record['lastError']
            $outcome = 'Failed'
            break
        }
        if ($definition.Contains('When') -and $null -ne $definition['When']) {
            if (-not (Invoke-DemoVmStepTest -Block $definition['When'] -Definition $definition)) {
                $record['status'] = 'NotSelected'
                $record['message'] = [string]$definition['NotSelectedMessage']
                Write-DemoVmLog -Step $name -Message ('Not selected. {0}' -f $record['message'])
                continue
            }
        }

        $state['currentStep'] = $name
        $now = Get-DemoVmUtcNow
        if (-not $record['firstStartedUtc']) {
            $record['firstStartedUtc'] = $now
        }
        $record['lastStartedUtc'] = $now
        $maxAttempts = 3
        if ($definition.Contains('MaxAttempts')) {
            $maxAttempts = [int]$definition['MaxAttempts']
        }
        $record['status'] = 'Running'
        Save-DemoVmState -State $state

        try {
            if (Invoke-DemoVmStepTest -Block $definition['Test'] -Definition $definition) {
                Complete-DemoVmStep -Record $record -Name $name -Message 'Already in the desired state.'
                continue
            }
            # Long steps (the guest image takes about 14 minutes) would otherwise leave the previous run's
            # health.json in place until the run ends.
            $state['message'] = 'Step {0} is converging (attempt {1} of {2}).' -f $name, ([int]$record['attempts'] + 1), $maxAttempts
            try {
                Write-DemoVmHealth -State $state
            }
            catch {
                Write-DemoVmLog -Step $name -Level 'Warning' -Message ('Could not write the in-progress health.json: {0}' -f $_.Exception.Message)
            }
            Write-DemoVmLog -Step $name -Message 'Converging.'
            $result = Get-DemoVmStepOutcome -Output @(& $definition['Set'] $definition)
            foreach ($warning in @($result.WarningMessage)) {
                Add-DemoVmWarning -State $state -Message $warning
            }

            if ($result.Outcome -eq 'Done') {
                if (-not (Invoke-DemoVmStepTest -Block $definition['Test'] -Definition $definition)) {
                    throw ('Step {0} ran, but its check still fails.' -f $name)
                }
                Complete-DemoVmStep -Record $record -Name $name -Message 'Converged.'
            }
            elseif ($result.Outcome -eq 'NotSelected') {
                $record['status'] = 'NotSelected'
                $record['message'] = $result.Message
                Write-DemoVmLog -Step $name -Message ('Not selected. {0}' -f $result.Message)
            }
            elseif ($result.Outcome -eq 'RebootRequired') {
                if ([int]$record['rebootCount'] -ge $MaxRebootsPerStep) {
                    throw ('Step {0} asked for more than {1} restarts.' -f $name, $MaxRebootsPerStep)
                }
                $record['rebootCount'] = [int]$record['rebootCount'] + 1
                $record['status'] = 'RebootPending'
                $state['pendingReboot'] = $true
                $state['rebootRequestedUtc'] = Get-DemoVmUtcNow
                $state['rebootCount'] = [int]$state['rebootCount'] + 1
                $state['state'] = 'RebootPending'
                $state['message'] = 'Step {0} needs a restart. The computer restarts now, and the scheduled task resumes at startup.' -f $name
                $outcome = 'RebootPending'
            }
            elseif ($result.Outcome -eq 'Waiting') {
                $waitState = $result.WaitState
                if (-not $waitState) {
                    $waitState = 'WaitingForInput'
                }
                $record['status'] = 'Waiting'
                $state['state'] = $waitState
                $state['message'] = $result.Message
                $outcome = $waitState
            }
            elseif ($result.Outcome -eq 'ManualActionRequired') {
                $record['status'] = 'ManualActionRequired'
                $state['state'] = 'ManualActionRequired'
                $state['message'] = $result.Message
                $state['instructions'] = @($result.Instruction)
                $outcome = 'ManualActionRequired'
            }
            elseif ($result.Outcome -eq 'InProgress') {
                $record['status'] = 'InProgress'
                $state['state'] = 'InProgress'
                $state['message'] = $result.Message
                $outcome = 'InProgress'
            }
            else {
                $record['status'] = 'Failed'
                $record['lastError'] = Protect-DemoVmText -Text $result.Message
                $state['state'] = 'Failed'
                $state['message'] = 'Step {0} failed: {1}' -f $name, $record['lastError']
                $outcome = 'Failed'
            }
            if ($outcome) {
                Write-DemoVmLog -Step $name -Message $state['message']
            }
        }
        catch {
            $record['attempts'] = [int]$record['attempts'] + 1
            $record['lastError'] = Protect-DemoVmText -Text $_.Exception.Message
            Write-DemoVmLog -Step $name -Level 'Error' -Message ('Attempt {0} of {1} failed: {2}' -f $record['attempts'], $maxAttempts, $record['lastError'])
            if ([int]$record['attempts'] -ge $maxAttempts) {
                $record['status'] = 'Failed'
                $state['state'] = 'Failed'
                $state['message'] = 'Step {0} failed after {1} attempts: {2}' -f $name, $maxAttempts, $record['lastError']
                $outcome = 'Failed'
            }
            else {
                $record['status'] = 'Retrying'
                $state['message'] = 'Step {0} failed (attempt {1} of {2}); the next run retries it: {3}' -f $name, $record['attempts'], $maxAttempts, $record['lastError']
                $outcome = 'InProgress'
            }
        }
        if ($outcome) {
            break
        }
    }

    if (-not $outcome) {
        $state['state'] = 'Ready'
        $state['currentStep'] = $null
        $state['message'] = 'Every step is in the desired state.'
        if (-not $state['completedUtc']) {
            $state['completedUtc'] = Get-DemoVmUtcNow
        }
        $outcome = 'Ready'
    }
    Save-DemoVmState -State $state

    $detail = @{}
    if ($null -ne $HealthDetail) {
        try {
            $output = @(& $HealthDetail)
            if ($output.Count -gt 0 -and $output[$output.Count - 1] -is [System.Collections.IDictionary]) {
                $detail = $output[$output.Count - 1]
            }
        }
        catch {
            $detail = @{ healthDetailError = (Protect-DemoVmText -Text $_.Exception.Message) }
        }
    }
    Write-DemoVmHealth -State $state -Detail $detail

    if ($outcome -eq 'RebootPending') {
        Invoke-DemoVmRestart
    }
    return $outcome
}
