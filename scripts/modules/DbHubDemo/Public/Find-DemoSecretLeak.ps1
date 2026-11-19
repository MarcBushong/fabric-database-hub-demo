function Find-DemoSecretLeak {
    <#
    .SYNOPSIS
    Scans files, folders, or text for secrets with the module's redaction rules and the registered secrets,
    and reports where they are without ever returning a secret (ADR 0009).

    .DESCRIPTION
    The scanner behind the Phase 14 secret checks (SECURITY.SECRETSCAN.*). It applies the same rules that
    Protect-DemoText redacts with (JWTs, bearer tokens, SAS signatures, storage account keys,
    connection-string passwords, secret-named JSON properties, GitHub tokens, and product keys), plus every
    value registered with Register-DemoSecret in this session and any -KnownValue, such as a password typed
    for break-glass access.

    A match counts only when it would change the text: a value that is already a redaction marker
    ([REDACTED...]), empty, masked with asterisks, or an <angle-bracket> placeholder isn't a leak. The bearer
    and connection-password rules, which also match prose, count only for values of at least 8 characters
    with a digit or a symbol (not counting sentence punctuation at the end), as real tokens and generated
    passwords have.

    Folders are scanned recursively, except .git and dependency trees: a folder named node_modules,
    bower_components, jspm_packages, .npm, .pnpm-store, .yarn, .nuget, __pycache__, .venv, venv, site-packages,
    .tox, .gradle, or .m2 anywhere under a scanned folder is third-party code or a package cache, never the
    repository's or the user's output, so it's left out as the folder is walked, without reading or even
    listing its files (2026-11-18: after the Insights app's build, out/fabric-app/node_modules alone held
    114,315 files, 658 MB, and walking it kept validate.ps1's Security area busy for more than 37 minutes).
    Junctions and symbolic links to folders aren't followed. A folder or file named in -Path is scanned even
    when it's inside such a tree. Text is decoded as UTF-8, or as UTF-16 or UTF-32 when a
    byte order mark says so, or as UTF-16 without one when NUL bytes fall on every other byte (Windows
    PowerShell 5.1's Out-File and redirection write UTF-16). Other files with a NUL byte in the first 8,000
    bytes are binary; they, files larger than -MaxFileBytes, and files and folders that can't be read are
    skipped and listed. A file another process is still writing, such as a transcript, is read with shared
    access.
    Returns one DbHubDemo.SecretScan object:
    Findings (each with Source, Line, Rule, and an Excerpt in which every match is replaced by
    [REDACTED:<rule>] and the rest is redacted again), Scanned (the sources read), Skipped (with the
    reason), Pruned (the dependency-tree folders left out, full paths, sorted, the first 50), and PrunedCount
    (how many were left out).

    Sources (checked 2026-10-20): what ADR 0009 requires scanned, and gitleaks for the repository itself
    (https://github.com/gitleaks/gitleaks); GitHub Actions log masking
    (https://docs.github.com/actions/reference/workflows-and-actions/workflow-commands#masking-a-value-in-a-log).

    .PARAMETER Path
    Files or folders to scan.

    .PARAMETER Text
    Text to scan, for example a Run Command instance view or deployment operations read from Azure.

    .PARAMETER Source
    The label for -Text in the findings.

    .PARAMETER KnownValue
    Values to look for besides the registered secrets, as SecureStrings. They're compared in memory only.

    .PARAMETER MaxFileBytes
    Larger files are skipped.

    .EXAMPLE
    (Find-DemoSecretLeak -Path ./out).Findings | Format-Table Source, Line, Rule, Excerpt

    .EXAMPLE
    gh run view 123456789 --log > ./out/actions-123456789.log; (Find-DemoSecretLeak -Path ./out/actions-123456789.log).Findings
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(ParameterSetName = 'Text')]
        [ValidateNotNullOrEmpty()]
        [string] $Source = 'text',

        [securestring[]] $KnownValue = @(),

        [ValidateRange(1024, 1073741824)]
        [long] $MaxFileBytes = 52428800
    )

    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($secret in $script:DemoSecrets) {
        $values.Add([pscustomobject]@{ Rule = 'registered-secret'; Value = [string]$secret })
    }
    foreach ($secure in $KnownValue) {
        if ($null -eq $secure) {
            continue
        }
        $plain = [System.Net.NetworkCredential]::new('', $secure).Password
        if ($plain.Length -ge 4) {
            $values.Add([pscustomobject]@{ Rule = 'known-value'; Value = $plain })
        }
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    $scanned = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $pruned = [System.Collections.Generic.List[string]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'Text') {
        foreach ($finding in @(Find-DemoSecretInText -Text $Text -Source $Source -Value $values.ToArray())) {
            $findings.Add($finding)
        }
        $scanned.Add($Source)
    }
    else {
        # Dependency trees and package caches are left out while each folder is walked, one level at a time, so not one of
        # their files is listed: Get-ChildItem -Recurse with a filter after it still walked all of node_modules.
        $prunedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @('node_modules', 'bower_components', 'jspm_packages', '.npm', '.pnpm-store', '.yarn', '.nuget', '__pycache__', '.venv', 'venv', 'site-packages', '.tox', '.gradle', '.m2')) {
            $null = $prunedNames.Add($name)
        }
        # Hidden and system entries too, as Get-ChildItem -Force listed them; a folder that can't be read is skipped and
        # listed rather than left out silently.
        $options = [System.IO.EnumerationOptions]::new()
        $options.RecurseSubdirectories = $false
        $options.IgnoreInaccessible = $false
        $options.AttributesToSkip = [System.IO.FileAttributes]::None
        $options.ReturnSpecialDirectories = $false
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($item in $Path) {
            if (Test-Path -LiteralPath $item -PathType Leaf) {
                $files.Add((Get-Item -LiteralPath $item -Force))
            }
            elseif (Test-Path -LiteralPath $item -PathType Container) {
                $found = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
                $pending.Push((Get-Item -LiteralPath $item -Force))
                while ($pending.Count -gt 0) {
                    $directory = $pending.Pop()
                    try {
                        $entries = $directory.GetFileSystemInfos('*', $options)
                    }
                    catch {
                        $skipped.Add([pscustomobject]@{ Source = $directory.FullName; Reason = ('unreadable: {0}' -f $_.Exception.Message) })
                        continue
                    }
                    foreach ($entry in $entries) {
                        if ($entry -is [System.IO.FileInfo]) {
                            $found.Add($entry)
                        }
                        elseif ($prunedNames.Contains($entry.Name)) {
                            $pruned.Add($entry.FullName)
                        }
                        elseif ($entry.Name -ne '.git' -and -not $entry.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                            $pending.Push($entry)
                        }
                    }
                }
                foreach ($file in @($found | Sort-Object -Property FullName)) {
                    $files.Add($file)
                }
            }
            else {
                $skipped.Add([pscustomobject]@{ Source = $item; Reason = 'not found' })
            }
        }
        foreach ($file in $files) {
            if ($file.Length -gt $MaxFileBytes) {
                $skipped.Add([pscustomobject]@{ Source = $file.FullName; Reason = ('larger than {0} bytes' -f $MaxFileBytes) })
                continue
            }
            # Shared read, so a log that another process is still writing (a transcript) can be scanned too.
            try {
                $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try {
                    $buffer = [System.IO.MemoryStream]::new()
                    $stream.CopyTo($buffer)
                    $bytes = $buffer.ToArray()
                }
                finally {
                    $stream.Dispose()
                }
            }
            catch {
                $skipped.Add([pscustomobject]@{ Source = $file.FullName; Reason = ('unreadable: {0}' -f $_.Exception.Message) })
                continue
            }
            $decoded = ConvertFrom-DemoSecretScanContent -Bytes $bytes
            if ($null -eq $decoded) {
                $skipped.Add([pscustomobject]@{ Source = $file.FullName; Reason = 'binary' })
                continue
            }
            foreach ($finding in @(Find-DemoSecretInText -Text $decoded.Text -Source $file.FullName -Value $values.ToArray())) {
                $findings.Add($finding)
            }
            $scanned.Add($file.FullName)
        }
    }

    [pscustomobject]@{
        PSTypeName  = 'DbHubDemo.SecretScan'
        Findings    = $findings.ToArray()
        Scanned     = $scanned.ToArray()
        Skipped     = $skipped.ToArray()
        Pruned      = @($pruned | Sort-Object | Select-Object -First 50)
        PrunedCount = $pruned.Count
    }
}
