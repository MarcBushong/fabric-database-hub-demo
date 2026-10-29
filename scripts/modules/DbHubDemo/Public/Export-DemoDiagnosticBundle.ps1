function Export-DemoDiagnosticBundle {
    <#
    .SYNOPSIS
    Zips what a deploy.ps1 run left in out/, redacted again, for a Deployment problem issue (Phase 28, brief item 9).
    collect-diagnostics.ps1 calls it.

    .DESCRIPTION
    1. Takes the newest files (at most -MaxFiles, each at most -MaxFileBytes) of: out/*.jsonl (every script's results),
       out/deploy-progress.json (the status page's model), out/logs/*.log (deploy.ps1's console transcripts), and
       out/diagnostics/*.json (VM instance views the Run Command watchdog saved). Nothing else: not the configuration,
       out/config-backup, the policy cache, or the status page.
    2. Each file's text is redacted again (Protect-DemoBundleText: secrets, every GUID, the servers' random suffix,
       email addresses, the home folder, and -Mask values such as the configuration's owner) into a staging folder under
       out/.
    3. The staged copy is scanned (Find-DemoSecretLeak, with the registered secrets). Any finding stops it: no zip, and
       DIAG.BUNDLE is a Fail that names the file and the rule, never the value (fail closed, ADR 0009).
    4. Compress-Archive writes the zip (out/diagnostics-<UTC time>.zip by default), and the staging folder goes.
    Returns DIAG.BUNDLE: Pass with the zip's path and the files in it, Not selected when there's nothing to collect, or
    Fail.

    .PARAMETER Directory
    The out/ folder (default: the repository's out/).

    .PARAMETER Path
    The zip to write (default out/diagnostics-<UTC time>.zip).

    .PARAMETER Mask
    More values to mask, for example the configuration's owner and azureAccount.

    .PARAMETER MaxFiles
    At most this many files, the newest first (default 60).

    .PARAMETER MaxFileBytes
    Larger files are left out (default 20 MB).

    .EXAMPLE
    Export-DemoDiagnosticBundle
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $Directory = '',

        [string] $Path = '',

        [AllowEmptyCollection()]
        [string[]] $Mask = @(),

        [ValidateRange(1, 500)]
        [int] $MaxFiles = 60,

        [ValidateRange(1024, 209715200)]
        [long] $MaxFileBytes = 20971520
    )

    $checkId = 'DIAG.BUNDLE'
    $docUrl = 'https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/compress-archive'
    if (-not $Directory) {
        $Directory = Join-Path -Path $script:RepoRoot -ChildPath 'out'
    }
    $Directory = [System.IO.Path]::GetFullPath($Directory)
    $stamp = [System.DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not $Path) {
        $Path = Join-Path -Path $Directory -ChildPath ('diagnostics-{0}.zip' -f $stamp)
    }
    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($pattern in @(@('', '*.jsonl'), @('', 'deploy-progress.json'), @('logs', '*.log'), @('diagnostics', '*.json'))) {
            $folder = if ($pattern[0]) { Join-Path -Path $Directory -ChildPath $pattern[0] } else { $Directory }
            if (Test-Path -LiteralPath $folder -PathType Container) {
                foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter $pattern[1] -File -ErrorAction SilentlyContinue)) {
                    $candidates.Add($file)
                }
            }
        }
    }
    $chosen = @($candidates | Where-Object { $_.Length -le $MaxFileBytes } | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First $MaxFiles)
    $tooLarge = @($candidates | Where-Object { $_.Length -gt $MaxFileBytes } | ForEach-Object { $_.Name })
    if ($chosen.Count -eq 0) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('There''s nothing to collect in {0}: run deploy.ps1 (or another script) first.' -f (Split-Path -Path $Directory -Leaf)) -DocUrl $docUrl)
    }
    if (-not $PSCmdlet.ShouldProcess($Path, ('Write a redacted zip of {0} file(s) from out/' -f $chosen.Count))) {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Not selected' -Message ('What if: {0} file(s) would be redacted and zipped.' -f $chosen.Count) -Evidence ([ordered]@{ files = @($chosen | ForEach-Object { $_.Name }) }))
    }
    $staging = Join-Path -Path $Directory -ChildPath ('diagnostics-staging-{0}' -f $stamp)
    $names = [System.Collections.Generic.List[string]]::new()
    try {
        $null = New-Item -ItemType Directory -Path $staging -Force
        foreach ($file in $chosen) {
            $relative = $file.FullName.Substring($Directory.Length).TrimStart('\', '/')
            $target = Join-Path -Path $staging -ChildPath $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force
            $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
            }
            finally {
                $stream.Dispose()
            }
            $lines = foreach ($line in ($text -split '\r?\n')) {
                Protect-DemoBundleText -Text $line -Mask $Mask
            }
            [System.IO.File]::WriteAllText($target, (@($lines) -join "`n"), [System.Text.UTF8Encoding]::new($false))
            $names.Add(($relative -replace '\\', '/'))
        }
        $scan = Find-DemoSecretLeak -Path $staging
        if (@($scan.Findings).Count -gt 0) {
            $where = @($scan.Findings | Select-Object -First 5 | ForEach-Object { '{0} line {1} ({2})' -f ((Split-Path -Path ([string]$_.Source) -Leaf)), $_.Line, $_.Rule })
            return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The redacted copy still has {0} value(s) that look secret, so no zip was written: {1}.' -f @($scan.Findings).Count, ($where -join '; ')) -Remediation 'Don''t share those files. Open an issue without the bundle, describe what happened, and paste the DONE or NOT DONE banner; a maintainer asks for what''s needed.' -DocUrl $docUrl)
        }
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        Compress-Archive -Path (Join-Path -Path $staging -ChildPath '*') -DestinationPath $Path -CompressionLevel Optimal
        $message = 'Wrote {0} with {1} redacted file(s). Look through it before you attach it to a Deployment problem issue.' -f $Path, $names.Count
        if ($tooLarge.Count -gt 0) {
            $message += (' Left out as too large: {0}.' -f ($tooLarge -join ', '))
        }
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Pass' -Message $message -Evidence ([ordered]@{ path = $Path; files = $names.ToArray() }) -DocUrl $docUrl)
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'infra' -Target 'subscription' -Status 'Fail' -Message ('The diagnostics bundle couldn''t be written: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Check that out/ is writable, then run ./scripts/collect-diagnostics.ps1 again.' -DocUrl $docUrl)
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
