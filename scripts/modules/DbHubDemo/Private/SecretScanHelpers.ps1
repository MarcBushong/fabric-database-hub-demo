function ConvertFrom-DemoSecretScanContent {
    <#
    .SYNOPSIS
    Decodes a file's bytes for the secret scan, or returns $null for binary content. Internal.

    .DESCRIPTION
    A byte order mark decides first: UTF-8, UTF-16 little or big endian, or UTF-32 little endian. Without
    one, content with no NUL byte in its first 8,000 bytes is UTF-8, and content whose NUL bytes fall on
    every other byte is UTF-16 without a byte order mark. Windows PowerShell 5.1 writes UTF-16 with
    Out-File and redirection, and other Windows tools' logs can be UTF-16 too; skipped as binary, they
    would hide a token. Anything else with NUL bytes is binary.
    Returns Text and Encoding.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    $length = $Bytes.Length
    $decode = {
        param([System.Text.Encoding] $Encoding, [int] $Offset, [int] $Unit, [string] $Name)
        $count = $length - $Offset
        $count -= $count % $Unit
        [pscustomobject]@{ Text = $Encoding.GetString($Bytes, $Offset, $count); Encoding = $Name }
    }
    if ($length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return (& $decode ([System.Text.UTF8Encoding]::new($false)) 3 1 'utf-8')
    }
    if ($length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
        return (& $decode ([System.Text.Encoding]::UTF32) 4 4 'utf-32')
    }
    if ($length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return (& $decode ([System.Text.Encoding]::Unicode) 2 2 'utf-16')
    }
    if ($length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return (& $decode ([System.Text.Encoding]::BigEndianUnicode) 2 2 'utf-16be')
    }
    $probe = [System.Math]::Min($length, 8000)
    if ($probe -eq 0 -or [System.Array]::IndexOf($Bytes, [byte]0, 0, $probe) -lt 0) {
        return (& $decode ([System.Text.UTF8Encoding]::new($false)) 0 1 'utf-8')
    }
    $pairs = [System.Math]::Floor($probe / 2)
    $evenZero = 0
    $oddZero = 0
    for ($index = 0; $index -lt 2 * $pairs; $index += 2) {
        if ($Bytes[$index] -eq 0) {
            $evenZero++
        }
        if ($Bytes[$index + 1] -eq 0) {
            $oddZero++
        }
    }
    if ($pairs -gt 0 -and $oddZero -ge 0.3 * $pairs -and $evenZero -le 0.02 * $pairs) {
        return (& $decode ([System.Text.Encoding]::Unicode) 0 2 'utf-16')
    }
    if ($pairs -gt 0 -and $evenZero -ge 0.3 * $pairs -and $oddZero -le 0.02 * $pairs) {
        return (& $decode ([System.Text.Encoding]::BigEndianUnicode) 0 2 'utf-16be')
    }
    return $null
}

function Find-DemoSecretInText {
    <#
    .SYNOPSIS
    The matches of the redaction rules and of the given values in one text, as findings that never hold the
    matched value. Internal; Find-DemoSecretLeak describes the rules.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory)]
        [string] $Source,

        [AllowEmptyCollection()]
        [object[]] $Value = @()
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in $script:RedactionRules) {
        foreach ($match in [regex]::Matches($Text, $rule.Pattern)) {
            $candidate = $match.Value
            $replacement = [string]$rule.Replacement
            if ($replacement.Contains('$1') -and $match.Groups.Count -gt 1 -and $match.Groups[1].Success) {
                $candidate = $candidate.Substring($match.Groups[1].Length)
            }
            if ($replacement.Contains('$2') -and $match.Groups.Count -gt 2 -and $match.Groups[2].Success) {
                $candidate = $candidate.Substring(0, $candidate.Length - $match.Groups[2].Length)
            }
            if (Test-DemoSecretCandidate -Value $candidate -Rule $rule.Name) {
                $hits.Add([pscustomobject]@{ Index = $match.Index; Length = $match.Length; Rule = $rule.Name })
            }
        }
    }
    foreach ($entry in $Value) {
        $needle = [string]$entry.Value
        if ($needle.Length -lt 4) {
            continue
        }
        $index = $Text.IndexOf($needle, [System.StringComparison]::Ordinal)
        while ($index -ge 0) {
            $hits.Add([pscustomobject]@{ Index = $index; Length = $needle.Length; Rule = [string]$entry.Rule })
            $index = $Text.IndexOf($needle, $index + $needle.Length, [System.StringComparison]::Ordinal)
        }
    }
    if ($hits.Count -eq 0) {
        return
    }

    $newlines = [int[]]@([regex]::Matches($Text, "`n") | ForEach-Object { $_.Index })
    foreach ($hit in ($hits | Sort-Object -Property Index, Rule)) {
        $position = [System.Array]::BinarySearch($newlines, $hit.Index)
        if ($position -lt 0) {
            $position = -bnot $position
        }
        $lineStart = if ($position -eq 0) { 0 } else { $newlines[$position - 1] + 1 }
        $lineEnd = if ($position -lt $newlines.Length) { $newlines[$position] } else { $Text.Length }
        $line = $Text.Substring($lineStart, $lineEnd - $lineStart)
        $offset = $hit.Index - $lineStart
        $length = [System.Math]::Min($hit.Length, $line.Length - $offset)
        $marker = '[REDACTED:{0}]' -f $hit.Rule
        $masked = $line.Substring(0, $offset) + $marker + $line.Substring($offset + $length)
        foreach ($entry in $Value) {
            $needle = [string]$entry.Value
            if ($needle.Length -ge 4) {
                $masked = $masked.Replace($needle, '[REDACTED]')
            }
        }
        $masked = (Protect-DemoText -Text $masked).TrimEnd("`r")
        $center = $masked.IndexOf($marker, [System.StringComparison]::Ordinal)
        if ($masked.Length -gt 200) {
            $start = [System.Math]::Max(0, [System.Math]::Min($center - 80, $masked.Length - 200))
            $masked = $masked.Substring($start, 200)
        }
        [pscustomobject]@{
            PSTypeName = 'DbHubDemo.SecretFinding'
            Source     = $Source
            Line       = $position + 1
            Rule       = $hit.Rule
            Excerpt    = $masked.Trim()
        }
    }
}

function Test-DemoSecretCandidate {
    <#
    .SYNOPSIS
    True when a redaction rule's matched value looks like a real secret, not an empty value, a redaction
    marker, an asterisk mask, or a placeholder. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Value,

        [string] $Rule
    )

    $trimmed = $Value.Trim()
    if (-not $trimmed) {
        return $false
    }
    if ($trimmed.StartsWith('[REDACTED', [System.StringComparison]::Ordinal) -or $trimmed -match '^\*+$' -or $trimmed -match '^<[^<>]*>$') {
        return $false
    }
    # These two rules also match prose ("Bearer authentication.", "password=<value>"); tokens and generated
    # passwords are longer and contain a digit or a symbol. Sentence punctuation at the end doesn't count.
    if ($Rule -in 'bearer', 'connection-password') {
        $word = $trimmed -replace '[.,;:!?)]+$', ''
        return ($word.Length -ge 8 -and $word -match '[0-9]|[^A-Za-z0-9]')
    }
    return $true
}
