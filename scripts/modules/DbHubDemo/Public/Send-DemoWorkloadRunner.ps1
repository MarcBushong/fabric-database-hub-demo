function Send-DemoWorkloadRunner {
    <#
    .SYNOPSIS
    Delivers the workload runner zip to one VM in SHA-256-checked Run Command chunks (ADR 0010).

    .DESCRIPTION
    A thin wrapper over Send-DemoBootstrapBundle, so the runner travels exactly like the bootstrap bundle:
    New-DemoBootstrapChunk turns the zip into ASCII-only Windows PowerShell 5.1 scripts that each write one
    chunk to C:\ProgramData\DbHubDemo\downloads\<sha12> after checking its SHA-256; they're sent one managed
    Run Command at a time, each deleted before the next, with 409 retries and leftover cleanup. Nothing secret
    travels: the runner holds no credentials, and the chunk builder refuses content that looks like a secret.

    Send it to sqlvm01 (T1 drives T1 and T3) and archost01 (the T2 host copies it into the guest over
    PowerShell Direct) before deploying the template with -WorkloadRunnerSha256 and -WorkloadRunnerChunkCount
    (Get-DemoDeploymentParameter). The WorkloadRunner steps then assemble and verify it like the loader does,
    and wait (WaitingForInput, not Failed) while chunks are missing.

    At about 60-80 seconds per chunk (Phase 6 live measurement), a 3.2 MB runner is 7 chunks of 512 KiB, or
    about 7-10 minutes per VM.

    Returns VmName, RunnerSha256, ChunkCount, and Seconds.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Runner
    Output of Publish-DemoWorkloadRunner.

    .PARAMETER VmName
    sqlvm01 or archost01.

    .PARAMETER ResourceGroupName
    Defaults to rg-<prefix>-<environment>.

    .PARAMETER ChunkSizeKiB
    Raw bytes per chunk, in KiB (1 to 512).

    .PARAMETER TimeoutSeconds
    Each chunk Run Command's script timeout.

    .PARAMETER Parallelism
    How many chunk Run Commands may run on the VM at once (Send-DemoBootstrapBundle -Parallelism).

    .EXAMPLE
    $runner = Publish-DemoWorkloadRunner
    'sqlvm01', 'archost01' | ForEach-Object { Send-DemoWorkloadRunner -Config $config -Runner $runner -VmName $_ }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Runner,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $ResourceGroupName = '',

        [ValidateRange(1, 512)]
        [int] $ChunkSizeKiB = 512,

        [ValidateRange(60, 3600)]
        [int] $TimeoutSeconds = 600,

        [ValidateRange(1, 16)]
        [int] $Parallelism = 1
    )

    foreach ($name in 'Path', 'Sha256', 'SizeBytes') {
        if (-not $Runner.PSObject.Properties[$name]) {
            throw "The runner object has no $name. Pass the output of Publish-DemoWorkloadRunner."
        }
    }
    if ([string]$Runner.Sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'The runner object has no valid SHA-256. Pass the output of Publish-DemoWorkloadRunner.'
    }
    $parameters = @{
        Config         = $Config
        Bundle         = $Runner
        VmName         = $VmName
        ChunkSizeKiB   = $ChunkSizeKiB
        TimeoutSeconds = $TimeoutSeconds
        Description    = 'workload runner'
        Parallelism    = $Parallelism
    }
    if ($ResourceGroupName) {
        $parameters['ResourceGroupName'] = $ResourceGroupName
    }
    if (-not $PSCmdlet.ShouldProcess($VmName, ('Send the workload runner {0} in Run Command chunks' -f $Runner.Sha256.Substring(0, 12)))) {
        return
    }
    $sent = Send-DemoBootstrapBundle @parameters -Confirm:$false
    if ($null -eq $sent) {
        return
    }
    [pscustomobject]@{
        VmName       = $sent.VmName
        RunnerSha256 = $sent.BundleSha256
        ChunkCount   = $sent.ChunkCount
        Seconds      = $sent.Seconds
    }
}
