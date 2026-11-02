function Get-DemoVmHealth {
    <#
    .SYNOPSIS
    Reads C:\ProgramData\DbHubDemo\health.json from a demo VM through a read-only managed Run Command
    (ADR 0003, ADR 0012).

    .DESCRIPTION
    Runs vm/health/Get-DemoHealth.ps1 with Invoke-DemoVmRunCommand (Run Command DbHubDemo-HealthRead, deleted
    afterward) and returns the parsed JSON. -View Summary (the default) returns only role, state, status,
    message, currentStep, generation, updatedUtc, installMode, arcOnboarded, guestState, and sqlEdition, plus
    the PaygWizard guided stop's guidedArmed, guidedRequest, guidedLast, and guidedLeft (Phase 28), which
    always fits in the 4 KB the instance view keeps. Under -WhatIf nothing runs and the result is $null. Throws
    when the Run Command fails or its output doesn't parse.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    sqlvm01, archost01, or arcsql01 in the evaluation-only mode.

    .PARAMETER View
    Summary (default) or Full.

    .PARAMETER TimeoutSeconds
    The Run Command's script timeout.

    .EXAMPLE
    (Get-DemoVmHealth -Config $config -VmName archost01).state
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [ValidateSet('Summary', 'Full')]
        [string] $View = 'Summary',

        [ValidateRange(60, 1800)]
        [int] $TimeoutSeconds = 300
    )

    $script = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'vm/health/Get-DemoHealth.ps1') -Raw
    $run = Invoke-DemoVmRunCommand -Config $Config -VmName $VmName -RunCommandName 'DbHubDemo-HealthRead' -Script $script -Parameter @{ View = $View } -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    if ($null -eq $run) {
        return $null
    }
    if (-not $run.Succeeded) {
        $detail = if ($run.Error) { $run.Error } else { $run.Output }
        throw ('Reading health.json on {0} failed (execution state {1}, exit code {2}): {3}' -f $VmName, $run.ExecutionState, $run.ExitCode, $detail)
    }
    $health = ConvertFrom-DemoRunCommandOutput -Text $run.Output
    if ($null -eq $health) {
        throw ('The health.json read from {0} did not parse as JSON.' -f $VmName)
    }
    return $health
}
