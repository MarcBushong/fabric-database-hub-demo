function Assert-DemoNoSecretContent {
    <#
    .SYNOPSIS
    Throws when a file, or any entry of a zip file, contains a registered secret or matches one of the
    module's redaction patterns. Internal.

    .DESCRIPTION
    Guards content that leaves the operator's machine in clear text, such as the bootstrap bundle that
    travels in Run Command scripts (ADR 0003, ADR 0009). The same patterns that Protect-DemoText redacts
    are checked, so a JWT, a SAS signature, an account key, a connection-string password, a secret-named
    JSON property, a GitHub token, a product key, or any value registered with Register-DemoSecret stops
    the operation. The error names the file or entry and the rule, never the value.

    Binary entries (a NUL byte in their first 8,000 bytes, the heuristic Git uses), such as the workload
    runner's compiled assemblies, are checked for registered secrets only, as UTF-8 and UTF-16 text: compiled
    code legitimately holds the redaction patterns themselves (the runner has its own redactor) and arbitrary
    byte sequences. Their content comes from the repository's source, which gitleaks scans in CI, and from
    NuGet packages pinned with lock files (ADR 0010).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $texts = [System.Collections.Generic.List[object]]::new()
    $isZip = $false
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $header = [byte[]]::new(4)
        $isZip = $stream.Read($header, 0, 4) -eq 4 -and $header[0] -eq 0x50 -and $header[1] -eq 0x4B -and $header[2] -eq 0x03 -and $header[3] -eq 0x04
    }
    finally {
        $stream.Dispose()
    }
    if ($isZip) {
        Add-Type -AssemblyName 'System.IO.Compression'
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $archive.Entries) {
                $memory = [System.IO.MemoryStream]::new()
                $source = $entry.Open()
                try {
                    $source.CopyTo($memory)
                }
                finally {
                    $source.Dispose()
                }
                $texts.Add((ConvertTo-DemoSecretCheckItem -Name $entry.FullName -Bytes $memory.ToArray()))
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    else {
        $texts.Add((ConvertTo-DemoSecretCheckItem -Name ([System.IO.Path]::GetFileName($Path)) -Bytes ([System.IO.File]::ReadAllBytes($Path))))
    }

    foreach ($item in $texts) {
        foreach ($secret in $script:DemoSecrets) {
            if ($item.Text.Contains($secret) -or ($item.IsBinary -and $item.Unicode.Contains($secret))) {
                throw ('{0} contains a registered secret, so it must not leave this machine in clear text (ADR 0009).' -f $item.Name)
            }
        }
        if ($item.IsBinary) {
            continue
        }
        foreach ($rule in $script:RedactionRules) {
            if ([regex]::IsMatch($item.Text, $rule.Pattern)) {
                throw ('{0} matches the secret pattern ''{1}'', so it must not leave this machine in clear text (ADR 0009). Remove the value, or change the text so it no longer looks like a secret.' -f $item.Name, $rule.Name)
            }
        }
    }
}

function ConvertTo-DemoSecretCheckItem {
    # One item for Assert-DemoNoSecretContent: its text as UTF-8, and for binary content also as UTF-16. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    $probe = [System.Math]::Min(8000, $Bytes.Length)
    $isBinary = $probe -gt 0 -and [System.Array]::IndexOf($Bytes, [byte]0, 0, $probe) -ge 0
    [pscustomobject]@{
        Name     = $Name
        IsBinary = $isBinary
        Text     = [System.Text.Encoding]::UTF8.GetString($Bytes)
        Unicode  = if ($isBinary) { [System.Text.Encoding]::Unicode.GetString($Bytes) } else { '' }
    }
}