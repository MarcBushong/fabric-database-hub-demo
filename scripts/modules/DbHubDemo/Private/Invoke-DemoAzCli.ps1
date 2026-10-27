function Invoke-DemoAzCli {
    <#
    .SYNOPSIS
    Runs the Azure CLI with an argument array and captures exit code, stdout, and stderr.

    .DESCRIPTION
    Internal. Every Azure CLI call in the module goes through this function so tests can mock it.
    It never logs its arguments, because they can contain protected values. When az is a batch file
    (az.cmd on Windows), each argument is quoted for cmd.exe by ConvertTo-DemoBatchArgument, and
    PowerShell's own quoting is pinned to Legacy so it passes those quotes through unchanged.
    Callers decide with ShouldProcess whether a command runs. Under a caller's -WhatIf, the inherited
    $WhatIfPreference would skip the stderr redirection and the temporary file's deletion (Phase 14
    finding), so it's pinned to $false here, for both paths.

    With -TimeoutSeconds, the CLI runs as a child process with no console input, and the whole process
    tree is stopped when it doesn't finish in time: ExitCode is then -1 and StdErr says so. A token request
    can otherwise wait forever, for example when the Web Account Manager broker would need an interactive
    prompt (live finding, 2026-10-21). The command line is the same as without the time limit.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0
    )

    $WhatIfPreference = $false
    $az = Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $az) {
        throw 'The Azure CLI (az) was not found on PATH. Install it, or run from Azure Cloud Shell.'
    }

    $arguments = $ArgumentList
    $isBatch = $az.Source -match '\.(cmd|bat)$'
    if ($isBatch) {
        $arguments = @($ArgumentList | ForEach-Object { ConvertTo-DemoBatchArgument -Argument $_ })
        $PSNativeCommandArgumentPassing = 'Legacy'
    }

    if ($TimeoutSeconds -gt 0) {
        return (Invoke-DemoAzProcess -FilePath $az.Source -ArgumentList $arguments -Batch:$isBatch -TimeoutSeconds $TimeoutSeconds)
    }

    $PSNativeCommandUseErrorActionPreference = $false
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & $az.Source @arguments 2> $errorFile
        $exitCode = $LASTEXITCODE
        $stderr = Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = (@($stdout) -join [System.Environment]::NewLine)
        StdErr   = [string]$stderr
    }
}

function Invoke-DemoAzProcess {
    <#
    .SYNOPSIS
    Runs the Azure CLI as a child process with a time limit. Internal; Invoke-DemoAzCli calls it.

    .DESCRIPTION
    For az.cmd, the arguments are already quoted for cmd.exe and are joined into one command line, as
    PowerShell's Legacy argument passing does; otherwise each argument is passed as is. Standard input is
    closed, so nothing can wait for a reply, and stdout and stderr are read without blocking. When the time
    limit passes, the whole process tree is stopped (for az.cmd: cmd.exe and Python) and the result has
    ExitCode -1. Output is decoded like PowerShell decodes native output ([Console]::OutputEncoding) and
    trailing line breaks are trimmed, so the result matches the untimed path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $ArgumentList,

        [switch] $Batch,

        [Parameter(Mandatory)]
        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    if ($Batch) {
        $startInfo.Arguments = ($ArgumentList -join ' ')
    }
    else {
        foreach ($argument in $ArgumentList) {
            $startInfo.ArgumentList.Add($argument)
        }
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Console]::OutputEncoding
    $startInfo.StandardErrorEncoding = [System.Console]::OutputEncoding

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose -Message 'The Azure CLI process had already exited.'
            }
            $null = $process.WaitForExit(15000)
            return [pscustomobject]@{
                ExitCode = -1
                StdOut   = ''
                StdErr   = ('The Azure CLI did not finish within {0} seconds and was stopped.' -f $TimeoutSeconds)
            }
        }
        # The parameterless overload also waits for the redirected streams to close.
        $process.WaitForExit()
        $lines = [System.Collections.Generic.List[string]]::new([string[]]([string]$stdoutTask.GetAwaiter().GetResult() -split '\r?\n'))
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
            $lines.RemoveAt($lines.Count - 1)
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = ($lines -join [System.Environment]::NewLine)
            StdErr   = [string]$stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}
