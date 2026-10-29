function Invoke-DemoVmRunCommand {
    <#
    .SYNOPSIS
    Runs a script on a VM in a managed Run Command, with optional protected parameters, and always deletes
    the Run Command afterward (ADR 0005, ADR 0009).

    .DESCRIPTION
    Builds on the Phase 6 Run Command helpers (Get-DemoRunCommandApiVersion, Get-DemoRunCommandBaseUrl,
    Wait-DemoRunCommand, Remove-DemoRunCommand, Test-DemoAzConflict):

    1. Deletes a leftover Run Command with the same name, for example from an interrupted run.
    2. Writes the request body to a file in a new private temporary directory (only the current user can
       open it; mode 700 on Linux and macOS) and creates the Run Command with
       'az rest --method put --body @<file>' through Invoke-DemoAz. Values in -ProtectedParameter go only
       into properties.protectedParameters in that file: never on a command line and never in a log. Each is
       registered with Register-DemoSecret first, so it's redacted everywhere for the rest of the session. A
       409 Conflict is retried with backoff (policy-installed extensions). The directory is deleted as soon as
       Azure accepts the request, and again in a finally block.
    3. Polls the instance view until the script reaches a terminal state, within -TimeoutSeconds plus 5
       minutes. A terminal state from an execution that started before the request belongs to an earlier
       Run Command with the same name (Wait-DemoRunCommand -NotBeforeUtc); the whole run is tried once more
       after 60 seconds, and if that's stale too, the result has Stale set and Succeeded false.
    4. Deletes the Run Command in a finally block, whatever happened, and waits until it's gone. Deleting a
       Run Command also stops a script that's still running.

    With -WhileRunning, a script block runs once in this process as soon as Azure has accepted the Run
    Command, while the script runs on the VM; the wait and the delete follow as usual, so a long Run Command
    is never deleted (which would stop its script) because the work beside it failed.

    Returns VmName, RunCommandName, Succeeded (execution state Succeeded and exit code 0), ExecutionState,
    ProvisioningState, ExitCode, Output, Error (the last 4 KB the instance view keeps, redacted with
    Protect-DemoText), WaitTimedOut, Stale, Removed, Seconds, and WhileRunningError (the redacted error of
    the -WhileRunning block, empty when it succeeded or there was none). A script that fails doesn't throw;
    a Run Command that can't be created does.

    Run Command passes parameters to a Windows script as '-Name value' arguments
    (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed), so names must be valid
    PowerShell parameter names and values may contain only letters, digits, and . _ : / @ = , + ? & % ~ -
    (Base64-encode anything else). Empty values are left out, so the script's default applies.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    The VM: sqlvm01, archost01, or arcsql01 in the evaluation-only mode.

    .PARAMETER RunCommandName
    A deterministic name that starts with DbHubDemo-.

    .PARAMETER Script
    The script text, Windows PowerShell 5.1.

    .PARAMETER Parameter
    Public parameters: name to value. They're visible in the Run Command resource; never put secrets here.

    .PARAMETER ProtectedParameter
    Protected parameters: name to value, as a String or a SecureString.

    .PARAMETER ResourceGroupName
    Defaults to rg-<prefix>-<environment>.

    .PARAMETER TimeoutSeconds
    The script's timeout on the VM.

    .PARAMETER PollIntervalSeconds
    Seconds between instance-view reads.

    .PARAMETER WhileRunning
    Work to do in this process while the script runs on the VM, for example deploy.ps1's T2 track sending
    archost01's artifacts in other Run Commands during the golden Release (ADR 0018). It runs once, after
    the Run Command was created; its output is discarded, and an error is logged and returned, never thrown.

    .PARAMETER StartTimeoutSeconds
    Phase 28's watchdog: when the script hasn't started running this long after the Run Command was created (it
    waits behind the VM's extension work), stop waiting; the result has NotStarted set, and the Run Command is
    deleted as usual. 0 (the default) waits the whole timeout.

    .EXAMPLE
    Invoke-DemoVmRunCommand -Config $config -VmName archost01 -RunCommandName DbHubDemo-HealthRead -Script (Get-Content ./vm/health/Get-DemoHealth.ps1 -Raw) -Parameter @{ View = 'Summary' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidatePattern('^DbHubDemo-[A-Za-z0-9-]{1,50}$')]
        [string] $RunCommandName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Script,

        [System.Collections.IDictionary] $Parameter = @{},

        [System.Collections.IDictionary] $ProtectedParameter = @{},

        [string] $ResourceGroupName = '',

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1800,

        [ValidateRange(0, 300)]
        [int] $PollIntervalSeconds = 10,

        [scriptblock] $WhileRunning = $null,

        [ValidateRange(0, 7200)]
        [int] $StartTimeoutSeconds = 0
    )

    $subscriptionId = $Config['subscriptionId']
    if (-not $ResourceGroupName) {
        $ResourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    }

    $namePattern = '^[A-Za-z][A-Za-z0-9]{0,63}$'
    $valuePattern = '^[A-Za-z0-9._:/@=,+?&%~-]*$'
    # A SecureString or a credential bound to a [string] becomes its type name; never send that to a VM.
    $typeNamePattern = '^System\.(Security\.SecureString|Management\.Automation\.PSCredential)$'
    $publicList = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $Parameter.Keys) {
        $value = [string]$Parameter[$name]
        if ([string]$name -notmatch $namePattern) {
            throw ("Run Command parameter name '{0}' isn't a valid PowerShell parameter name." -f $name)
        }
        if ($value -match $typeNamePattern) {
            throw ("The value of Run Command parameter '{0}' is a .NET type name, so a SecureString or credential was converted with [string]; pass the secret in -ProtectedParameter as a SecureString." -f $name)
        }
        if ($value -notmatch $valuePattern) {
            throw ("The value of Run Command parameter '{0}' has characters that don't survive the -Name value command line; Base64-encode it." -f $name)
        }
        if ($value) {
            $publicList.Add([ordered]@{ name = [string]$name; value = $value })
        }
    }
    foreach ($name in $ProtectedParameter.Keys) {
        if ([string]$name -notmatch $namePattern) {
            throw ("Protected Run Command parameter name '{0}' isn't a valid PowerShell parameter name." -f $name)
        }
        if ($Parameter.Contains($name)) {
            throw ("Run Command parameter '{0}' is both public and protected." -f $name)
        }
        if ($ProtectedParameter[$name] -is [string] -and $ProtectedParameter[$name] -match $typeNamePattern) {
            throw ("The value of protected Run Command parameter '{0}' is a .NET type name, so a SecureString or credential was converted with [string]; pass the SecureString itself." -f $name)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($VmName, ('Run the managed Run Command {0} ({1} parameter(s), {2} protected)' -f $RunCommandName, $publicList.Count, $ProtectedParameter.Count))) {
        return
    }

    $apiVersion = Get-DemoRunCommandApiVersion
    $url = '{0}/{1}?api-version={2}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $ResourceGroupName -VmName $VmName), $RunCommandName, $apiVersion
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $state = $null
    $removed = $false
    $whileRan = $false
    $whileError = ''
    # A Run Command created again right after it was deleted can report the previous run's instance view
    # without running its own script (seen live on 2026-10-21); such a result is retried once, then fails.
    $maxAttempts = 2
    Write-DemoLog -Message ('{0}: running {1} ({2} parameter(s), {3} protected).' -f $VmName, $RunCommandName, $publicList.Count, $ProtectedParameter.Count)
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $directory = $null
        $removed = $false
        try {
            if (-not (Remove-DemoRunCommand -SubscriptionId $subscriptionId -Url $url -WaitSeconds 300 -PollIntervalSeconds $PollIntervalSeconds -Confirm:$false)) {
                Write-DemoLog -Level Warning -Message ('{0}: a leftover {1} is still being deleted; creating it again may hit a conflict, which is retried.' -f $VmName, $RunCommandName)
            }

            $protectedList = [System.Collections.Generic.List[object]]::new()
            foreach ($name in $ProtectedParameter.Keys) {
                $raw = $ProtectedParameter[$name]
                $plain = if ($raw -is [securestring]) { [System.Net.NetworkCredential]::new('', $raw).Password } else { [string]$raw }
                if ([string]::IsNullOrEmpty($plain)) {
                    throw ("Protected Run Command parameter '{0}' is empty." -f $name)
                }
                if ($plain -match $typeNamePattern) {
                    throw ("The value of protected Run Command parameter '{0}' is a .NET type name, so a SecureString was built from one; nothing was sent." -f $name)
                }
                Register-DemoSecret -Value $plain
                if ($plain -notmatch $valuePattern) {
                    throw ("The value of protected Run Command parameter '{0}' has characters that don't survive the -Name value command line." -f $name)
                }
                $protectedList.Add([ordered]@{ name = [string]$name; value = $plain })
            }

            $body = [ordered]@{
                location   = [string]$Config['location']
                properties = [ordered]@{
                    source                          = [ordered]@{ script = $Script }
                    parameters                      = $publicList.ToArray()
                    protectedParameters             = $protectedList.ToArray()
                    asyncExecution                  = $false
                    treatFailureAsDeploymentFailure = $false
                    timeoutInSeconds                = $TimeoutSeconds
                }
            }
            $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-rc'
            $bodyPath = Write-DemoPrivateFile -Directory $directory -Name 'runcommand.json' -Content ($body | ConvertTo-Json -Depth 8 -Compress)
            $body = $null
            $protectedList.Clear()

            # 30 seconds of allowance for clock skew between this machine and the VM.
            $notBeforeUtc = [System.DateTime]::UtcNow.AddSeconds(-30)
            $put = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'put', '--url', $url, '--body', "@$bodyPath") -Label ('{0}: {1}' -f $VmName, $RunCommandName)
            # The body holds the protected values; it goes as soon as Azure has the request.
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
            $directory = $null
            if ($put.ExitCode -ne 0) {
                if (Test-DemoAzVmNotRunning -Text ([string]$put.StdErr)) {
                    throw ('{0}: {1} can''t run, because the VM isn''t running (deallocated or stopped) and Run Command needs it running. Start it first (./scripts/start-demo.ps1).' -f $VmName, $RunCommandName)
                }
                throw ('{0}: creating the Run Command {1} failed: {2}' -f $VmName, $RunCommandName, (Protect-DemoText -Text ([string]$put.StdErr).Trim()))
            }

            if ($null -ne $WhileRunning -and -not $whileRan) {
                $whileRan = $true
                try {
                    $null = & $WhileRunning
                }
                catch {
                    $whileError = Protect-DemoText -Text ([string]$_.Exception.Message)
                    Write-DemoLog -Level Warning -Message ('{0}: the work done while {1} ran failed; {1} is still awaited: {2}' -f $VmName, $RunCommandName, $whileError)
                }
            }

            $state = Wait-DemoRunCommand -SubscriptionId $subscriptionId -Url $url -TimeoutSeconds ($TimeoutSeconds + 300) -PollIntervalSeconds $PollIntervalSeconds -NotBeforeUtc $notBeforeUtc -StartTimeoutSeconds $StartTimeoutSeconds
        }
        finally {
            Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
            try {
                $removed = Remove-DemoRunCommand -SubscriptionId $subscriptionId -Url $url -PollIntervalSeconds $PollIntervalSeconds -Confirm:$false
            }
            catch {
                Write-DemoLog -Level Warning -Message ('{0}: the Run Command {1} could not be deleted: {2}' -f $VmName, $RunCommandName, $_.Exception.Message)
            }
            if (-not $removed) {
                Write-DemoLog -Level Warning -Message ('{0}: the Run Command {1} is still being deleted; delete it with az vm run-command delete if it remains.' -f $VmName, $RunCommandName)
            }
        }
        if (-not [bool](Get-DemoMemberValue -InputObject $state -Name 'Stale')) {
            break
        }
        if ($attempt -lt $maxAttempts) {
            Write-DemoLog -Level Warning -Message ('{0}: {1} reported an earlier run (started {2:u}) instead of running the script; trying again in 60 seconds.' -f $VmName, $RunCommandName, $state.StartTime)
            Start-Sleep -Seconds 60
        }
    }
    $stopwatch.Stop()

    $stale = [bool](Get-DemoMemberValue -InputObject $state -Name 'Stale')
    $succeeded = $state.Found -and -not $stale -and $state.ExecutionState -eq 'Succeeded' -and $state.ExitCode -eq 0
    $level = if ($succeeded) { 'Info' } else { 'Warning' }
    if ($stale) {
        Write-DemoLog -Level Warning -Message ('{0}: {1} reported an earlier run twice, so the script did not run and its result is ignored. Run it again in a few minutes.' -f $VmName, $RunCommandName)
    }
    Write-DemoLog -Level $level -Message ('{0}: {1} finished (execution state {2}, exit code {3}) in {4:N0} seconds.' -f $VmName, $RunCommandName, $state.ExecutionState, $state.ExitCode, $stopwatch.Elapsed.TotalSeconds)
    [pscustomobject]@{
        VmName            = $VmName
        RunCommandName    = $RunCommandName
        Succeeded         = [bool]$succeeded
        ExecutionState    = [string]$state.ExecutionState
        ProvisioningState = [string]$state.ProvisioningState
        ExitCode          = $state.ExitCode
        Output            = if ($stale) { '' } else { [string]$state.Output }
        Error             = if ($stale) { 'The Run Command reported an earlier run with the same name instead of running the script.' } else { [string]$state.Error }
        WaitTimedOut      = [bool]$state.WaitTimedOut
        NotStarted        = [bool](Get-DemoMemberValue -InputObject $state -Name 'NotStarted')
        Stale             = $stale
        Removed           = [bool]$removed
        Seconds           = [System.Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        WhileRunningError = $whileError
    }
}
