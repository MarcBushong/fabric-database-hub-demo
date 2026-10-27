function Invoke-DemoWorkloadCommand {
    <#
    .SYNOPSIS
    Runs one ContosoCare.Workload command on a target through action Run Command: on T1 for T1, T3, and T4,
    and through the T2 host into the guest over PowerShell Direct for T2 (ADR 0010, ADR 0011).

    .DESCRIPTION
    The same entry point for start-demo.ps1, stop-demo.ps1, reset-demo.ps1, status.ps1, and demo-control.yml:
    'profile set', 'profile get', 'stop', 'reset', 'status', 'run', and 'warmup'. The function adds --target
    (and --server for T3, and --server and the runner's role for T4, from T1's workload settings) on the VM, so
    ArgumentList holds only the command and its options. T4's commands are the same as T1 to T3's, with the
    same scenario names (Phase 24, ADR 0019); its 'status' is the live view of T4's sessions, waits, blockers,
    and connections against max_connections. The token {{NEXT_SHUTDOWN}} in an argument becomes the VM's next auto-shutdown time, for
    example '--not-after', '{{NEXT_SHUTDOWN}}'. Add '--json' for structured records.

    The runner holds no secrets: T1 and T2 use Windows authentication as SYSTEM (or the guest administrator
    for T2), and T3 and T4 the T1 managed identity. Output is redacted, and the VM keeps only the last 4,096 bytes of
    a Run Command's output, so long output is cut from the front.

    Returns Target, Status (an ADR 0012 status from the runner's exit code: 0 Pass or Warning, 2 Manual action
    required, otherwise Fail), ExitCode, Records (the --json output: the items of a JSON array, or one JSON object
    as one record, as 'profile get', 'status', and 'run' write; ConvertFrom-DemoRunnerRecord), StdOut, StdErr, and
    Result (a WORKLOAD.<target>.COMMAND record).

    .PARAMETER Target
    T1, T2, T3, or T4.

    .PARAMETER ArgumentList
    The runner command and its options, without --target.

    .PARAMETER TimeoutSeconds
    How long the runner may take (30 to 5400). A 'run' command waits for its scenario to end.

    .EXAMPLE
    Invoke-DemoWorkloadCommand -Config $config -Target T1 -ArgumentList 'status', '--json'

    .EXAMPLE
    Invoke-DemoWorkloadCommand -Config $config -Target T2 -ArgumentList 'profile', 'set', '--name', 'incident:cpu-pressure', '--not-after', '{{NEXT_SHUTDOWN}}'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $ArgumentList,

        [ValidateRange(30, 5400)]
        [int] $TimeoutSeconds = 1800
    )

    foreach ($argument in $ArgumentList) {
        if ($argument -in '--target', '-t') {
            throw 'Pass the target with -Target, not in ArgumentList.'
        }
        if ($argument.Length -gt 512 -or $argument -match '[\r\n]') {
            throw 'A runner argument is too long or holds a line break.'
        }
    }
    $command = ($ArgumentList | Select-Object -First 2) -join ' '
    $vmName = if ($Target -eq 'T2') { 'archost01' } else { 'sqlvm01' }
    if (-not $PSCmdlet.ShouldProcess(('{0} through {1}' -f $Target, $vmName), ('Run ContosoCare.Workload {0}' -f $command))) {
        return
    }
    $data = Invoke-DemoWorkloadAction -Config $Config -VmName $vmName -Action 'Runner' -Request @{ target = $Target; arguments = @($ArgumentList); timeoutSeconds = $TimeoutSeconds }
    $evidence = @{}
    if ($data['evidence'] -is [System.Collections.IDictionary]) {
        foreach ($key in $data['evidence'].Keys) {
            $evidence[$key] = $data['evidence'][$key]
        }
    }
    $stdout = [string]$evidence['stdout']
    $records = @(ConvertFrom-DemoRunnerRecord -StdOut $stdout)
    $status = [string]$data['status']
    $exitCode = if ($null -ne $evidence['exitCode']) { [int]$evidence['exitCode'] } else { $null }
    $evidence['command'] = $command
    $result = New-DemoResult -CheckId ('WORKLOAD.{0}.COMMAND' -f $Target) -Area 'workload' -Target $Target -Status $status -Message ([string]$data['message']) -Evidence $evidence `
        -Remediation $(if ($status -in 'Pass', 'Warning', 'Not selected') { '' } else { 'Run the command again, or run reset as an administrator (Invoke-DemoWorkloadCommand -Target <target> -ArgumentList reset).' }) `
        -DocUrl 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command'
    [pscustomobject]@{
        Target   = $Target
        Status   = $status
        ExitCode = $exitCode
        Records  = $records
        StdOut   = $stdout
        StdErr   = [string]$evidence['stderr']
        Result   = $result
    }
}
