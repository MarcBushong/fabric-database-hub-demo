function Invoke-DemoControl {
    <#
    .SYNOPSIS
    Changes the activity on the demo's targets, as demo-control.yml and the live-activity notebook ask:
    a profile (baseline, business-day, off) or one bounded incident (incident:<scenario>) (ADR 0010, ADR 0011).

    .DESCRIPTION
    The inputs are the ones the notebook dispatches (Phase 12), as strings or their typed equivalents:
    environment (the caller's), target (all, T1, T2, T3, or T4), scenario (baseline, business-day, off, or
    incident:<scenario>), duration (1-240 minutes), concurrency (0 for the scenario's default, or 1-64),
    intensity (0, or 1-10), reset-before, and auto-cleanup.

    For each target it runs 'profile set' through Invoke-DemoWorkloadCommand (on sqlvm01 for T1, T3, and T4,
    through archost01 for T2): --name, and unless the profile is off, --duration <minutes>m and --not-after the
    next auto-shutdown, plus --concurrency, --intensity, --reset-before, and --no-auto-cleanup when asked. The
    runner clamps everything to the scenario's limits. An incident on 'all' runs on the scenario's default
    target (scenarios/<id>/scenario.json), as the notebook does. A target whose runner isn't installed yet
    (T2 before its guest has SQL Server) reports Warning, not Fail.

    Returns one CONTROL.<target> result per target.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Target
    all, T1, T2, T3, or T4 (the PostgreSQL flexible server, when t4Enabled; Phase 24, ADR 0019).

    .PARAMETER Scenario
    baseline, business-day, off, or incident:<scenario>.

    .PARAMETER DurationMinutes
    1 to 240.

    .PARAMETER Concurrency
    0 for the scenario's default, or 1 to 64.

    .PARAMETER Intensity
    0 for the scenario's default, or 1 to 10.

    .PARAMETER ResetBefore
    Reset the target first.

    .PARAMETER AutoCleanup
    Clean up the scenario's scratch data after the run (the default).

    .PARAMETER RequestedBy
    Who asked, recorded with the request (never a secret).

    .EXAMPLE
    Invoke-DemoControl -Config $config -Target T1 -Scenario incident:locking-blocking -DurationMinutes 15
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('all', 'T1', 'T2', 'T3', 'T4')]
        [string] $Target = 'all',

        [Parameter(Mandatory)]
        [ValidatePattern('^(off|baseline|business-day|incident:[a-z0-9][a-z0-9-]{0,47})$')]
        [string] $Scenario,

        [ValidateRange(1, 240)]
        [int] $DurationMinutes = 30,

        [ValidateRange(0, 64)]
        [int] $Concurrency = 0,

        [ValidateRange(0, 10)]
        [int] $Intensity = 0,

        [bool] $ResetBefore = $false,

        [bool] $AutoCleanup = $true,

        [ValidatePattern('^[A-Za-z0-9._@/-]{1,64}$')]
        [string] $RequestedBy = 'demo-control'
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing changed. Check the GitHub environment''s Azure variables (setup-github-oidc.ps1).'))
        return $results.ToArray()
    }

    $targets = if ($Target -eq 'all') { @('T1', 'T2', 'T3') + @(if (Test-DemoT4Enabled -Config $Config) { 'T4' }) } else { @($Target) }
    if ($Scenario -like 'incident:*') {
        $id = $Scenario.Substring(9)
        $definition = Join-Path -Path $script:RepoRoot -ChildPath ('scenarios/{0}/scenario.json' -f $id)
        if (-not (Test-Path -LiteralPath $definition)) {
            $results.Add((New-DemoResult -CheckId 'CONTROL.REQUEST' -Area 'workload' -Target 'subscription' -Status 'Fail' -Message ('There''s no scenario ''{0}'' (scenarios/{0}).' -f $id) -Remediation ('Use one of: {0}.' -f ((Get-ChildItem -Path (Join-Path -Path $script:RepoRoot -ChildPath 'scenarios') -Directory | ForEach-Object { 'incident:' + $_.Name }) -join ', '))))
            return $results.ToArray()
        }
        if ($Target -eq 'all') {
            $default = @((Get-Content -LiteralPath $definition -Raw | ConvertFrom-Json).targets.default)
            $targets = @(if ($default.Count -gt 0) { [string]$default[0] } else { 'T1' })
            Write-DemoLog -Message ('An incident runs on one target: {0}, the default for {1}.' -f $targets[0], $id)
        }
    }

    $arguments = [System.Collections.Generic.List[string]]::new([string[]]@('profile', 'set', '--name', $Scenario))
    if ($Scenario -ne 'off') {
        $arguments.AddRange([string[]]@('--duration', ('{0}m' -f $DurationMinutes), '--not-after', '{{NEXT_SHUTDOWN}}'))
        if ($Concurrency -gt 0) {
            $arguments.AddRange([string[]]@('--concurrency', [string]$Concurrency))
        }
        if ($Intensity -gt 0) {
            $arguments.AddRange([string[]]@('--intensity', [string]$Intensity))
        }
        if ($ResetBefore) {
            $arguments.Add('--reset-before')
        }
        if (-not $AutoCleanup) {
            $arguments.Add('--no-auto-cleanup')
        }
    }
    $arguments.AddRange([string[]]@('--requested-by', $RequestedBy))

    foreach ($item in $targets) {
        $checkId = 'CONTROL.{0}' -f $item
        if (-not $PSCmdlet.ShouldProcess($item, ('Set the activity profile {0}' -f $Scenario))) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status 'Not selected' -Message ('What if: {0} wasn''t changed (runner arguments: {1}).' -f $item, ($arguments -join ' '))))
            continue
        }
        $run = Invoke-DemoWorkloadCommand -Config $Config -Target $item -ArgumentList $arguments.ToArray() -TimeoutSeconds 600 -Confirm:$false
        $status = [string]$run.Status
        $message = [string]$run.Result.message
        if (-not $message) {
            $message = '{0}: the runner exited with code {1}.' -f $item, $run.ExitCode
        }
        if ($status -eq 'Fail' -and $item -eq 'T2' -and $message -match '(?i)not installed|no workload|isn''t running|not running|PowerShell Direct|guest') {
            $status = 'Warning'
            $message = 'T2''s runner isn''t ready yet (the guest needs SQL Server first): ' + $message
        }
        $evidence = [ordered]@{ scenario = $Scenario; durationMinutes = $DurationMinutes; concurrency = $Concurrency; intensity = $Intensity; resetBefore = $ResetBefore; autoCleanup = $AutoCleanup; exitCode = $run.ExitCode }
        $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target $item -Status $status -Message $message -Evidence $evidence))
    }
    return $results.ToArray()
}
