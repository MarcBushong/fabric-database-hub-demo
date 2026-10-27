function Send-DemoBootstrapBundle {
    <#
    .SYNOPSIS
    Delivers the bootstrap bundle to one VM in SHA-256-checked chunks, one managed Run Command at a time
    (ADR 0003).

    .DESCRIPTION
    Replaces the artifact cache, which was dropped on 2026-10-20 (ADR 0016, C9): no storage account, no SAS,
    and no keys. New-DemoBootstrapChunk splits the bundle into scripts that each write one chunk to
    C:\ProgramData\DbHubDemo\downloads\<sha12> on the VM. For each chunk, in order:

    1. PUT the managed Run Command DbHubDemo-Chunk-<sha12>-<nnn> with 'az rest' (the JSON body goes in a
       temporary file and is passed as --body @<file>, because cmd.exe can't pass large or quoted values to
       az.cmd), with asyncExecution false, treatFailureAsDeploymentFailure false, and timeoutInSeconds. A
       409 Conflict is retried with backoff: tenant policies install the Guest Configuration and Defender
       for SQL extensions after a deployment, and the VM rejects changes while they run.
    2. Poll GET ...?$expand=instanceView until the execution state is Succeeded, Failed, TimedOut, or
       Canceled, and require exit code 0.
    3. DELETE the Run Command and wait until it's gone before the next chunk, so the VM never holds more
       than one chunk Run Command. Azure allows 25 managed Run Commands per VM.

    With -Parallelism above 1 (deploy.ps1's parallel tracks pass 8), up to that many chunk Run Commands are
    created at once and each is checked and deleted as it finishes: managed Run Commands run in parallel on
    one VM (documented, and proven live on 2026-10-21 with three at once), so the transfer takes about one
    round trip per wave instead of one per chunk. Their state is read every 10 seconds, to stay well inside
    Azure Resource Manager's read limits when two VMs receive chunks at the same time.

    Leftover DbHubDemo-Chunk-* Run Commands on the VM are deleted before the first chunk and again in a
    finally block, so two sends must never run on one VM at once: deploy.ps1's tracks send the bundle and
    the runner together in one call to the same engine, Send-DemoChunkSet (ADR 0018). The chunk writer is
    idempotent, so a resend after an interruption is safe. Every Azure CLI call goes through Invoke-DemoAz,
    so it carries the configured subscription. The bundle holds no secrets; New-DemoBootstrapChunk refuses
    content that looks like one (ADR 0009).

    Then deploy.ps1 deploys the template again with bootstrapBundleSha256 and bootstrapChunkCount, which
    adds the loader Run Command DbHubDemo-Bootstrap, and Wait-DemoBootstrapLoader reports its exit code.

    Returns VmName, BundleSha256, ChunkCount, and Seconds.

    Documented limits (checked 2026-10-20): 25 managed Run Commands per VM
    (https://learn.microsoft.com/azure/virtual-machines/run-command-overview); instance view output and
    error keep the last 4 KB (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed);
    an ARM request is at most 4,194,304 bytes
    (https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits).
    No inline script size limit is documented. A live check on 2026-10-20 delivered 48, 192, and 512 KiB
    chunks; each took about 60-80 seconds whatever its size, so the default is the largest, 512 KiB.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Bundle
    Output of New-DemoBootstrapBundle.

    .PARAMETER VmName
    The VM: sqlvm01 or archost01.

    .PARAMETER ResourceGroupName
    Defaults to rg-<prefix>-<environment>.

    .PARAMETER ChunkSizeKiB
    Raw bytes per chunk, in KiB (1 to 512). The default, 512, is the largest size proven live (2026-10-20);
    a Run Command round trip costs about the same whatever the chunk size.

    .PARAMETER TimeoutSeconds
    The Run Command's script timeout. The operator waits up to this long plus 5 minutes for each chunk.

    .PARAMETER Description
    What is sent, for the log lines: 'bootstrap bundle' by default; Send-DemoWorkloadRunner passes
    'workload runner'. The chunks land in the same place either way, named by the file's SHA-256.

    .PARAMETER Parallelism
    How many chunk Run Commands may run on the VM at once (1 to 16). 1, the default, sends them one at a time.

    .EXAMPLE
    $bundle = New-DemoBootstrapBundle
    'sqlvm01', 'archost01' | ForEach-Object { Send-DemoBootstrapBundle -Config $config -Bundle $bundle -VmName $_ }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Bundle,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [string] $ResourceGroupName = '',

        [ValidateRange(1, 512)]
        [int] $ChunkSizeKiB = 512,

        [ValidateRange(60, 3600)]
        [int] $TimeoutSeconds = 600,

        [ValidatePattern('^[A-Za-z0-9 -]{1,40}$')]
        [string] $Description = 'bootstrap bundle',

        [ValidateRange(1, 16)]
        [int] $Parallelism = 1
    )

    if (-not $ResourceGroupName) {
        $ResourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    }
    if (-not (Test-Path -LiteralPath $Bundle.Path -PathType Leaf)) {
        throw "The bundle file $($Bundle.Path) doesn't exist. Run New-DemoBootstrapBundle first."
    }
    $actual = (Get-FileHash -LiteralPath $Bundle.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Bundle.Sha256) {
        throw 'The bundle changed after it was built; run New-DemoBootstrapBundle again.'
    }
    $chunks = @(New-DemoBootstrapChunk -Path $Bundle.Path -ChunkSizeKiB $ChunkSizeKiB)
    $shortSha = $Bundle.Sha256.Substring(0, 12)
    if (-not $PSCmdlet.ShouldProcess($VmName, ('Send {0} {1} in {2} chunk Run Command(s) of {3} KiB' -f $Description, $shortSha, $chunks.Count, $ChunkSizeKiB))) {
        return
    }

    $file = [pscustomobject]@{ Path = $Bundle.Path; Sha256 = $Bundle.Sha256; SizeBytes = $Bundle.SizeBytes; Description = $Description; Chunks = $chunks }
    $sent = @(Send-DemoChunkSet -Config $Config -File @($file) -VmName $VmName -ResourceGroupName $ResourceGroupName -ChunkSizeKiB $ChunkSizeKiB -TimeoutSeconds $TimeoutSeconds -Parallelism $Parallelism)[0]

    [pscustomobject]@{
        VmName       = $VmName
        BundleSha256 = $Bundle.Sha256
        ChunkCount   = $sent.ChunkCount
        Seconds      = $sent.Seconds
    }
}
