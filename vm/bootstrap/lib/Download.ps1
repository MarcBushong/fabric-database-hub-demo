function Get-DemoVmFileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DemoVmFileSha512 {
    # The .NET runtime zip is pinned by the SHA-512 that Microsoft publishes in its release metadata (ADR 0010).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Get-DemoVmHashCache {
    # media-hashes.json: 'verified' caches hashes of files already checked (by path, size, and time), and
    # 'tofu' records first-use hashes for media that have no pinned SHA-256.
    [CmdletBinding()]
    param()

    $cache = Read-DemoVmJsonFile -Path (Get-DemoVmContext).HashCachePath
    if ($null -eq $cache) {
        $cache = [ordered]@{}
    }
    foreach ($key in @('verified', 'tofu')) {
        if (-not $cache.Contains($key) -or $null -eq $cache[$key]) {
            $cache[$key] = [ordered]@{}
        }
    }
    return $cache
}

function Save-DemoVmHashCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Cache
    )

    Write-DemoVmJsonFile -Path (Get-DemoVmContext).HashCachePath -InputObject $Cache -Redact
}

function Get-DemoVmExpectedSha256 {
    # The pinned hash, or the hash recorded on first use when nothing is pinned.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $ExpectedSha256,

        [string] $Name = ''
    )

    if ($ExpectedSha256) {
        return $ExpectedSha256.ToLowerInvariant()
    }
    if ($Name) {
        $cache = Get-DemoVmHashCache
        if ($cache['tofu'].Contains($Name)) {
            return [string]$cache['tofu'][$Name]['sha256']
        }
    }
    return ''
}

function Test-DemoVmFileHash {
    <#
    .SYNOPSIS
    True when the file exists and matches its pinned SHA-256 (or its first-use hash when nothing is pinned),
    or its pinned SHA-512 with -ExpectedSha512.

    .DESCRIPTION
    A verified file is cached by path, size, and last-write time, so large media aren't hashed on every run.
    SHA-512 pins (the .NET runtime) are never trusted on first use.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ExpectedSha256 = '',

        [string] $Name = '',

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ExpectedSha512 = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $field = 'sha256'
    if ($ExpectedSha512) {
        $field = 'sha512'
        $expected = $ExpectedSha512.ToLowerInvariant()
    }
    else {
        $expected = Get-DemoVmExpectedSha256 -ExpectedSha256 $ExpectedSha256 -Name $Name
    }
    if (-not $expected) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path
    $key = $item.FullName.ToLowerInvariant()
    $stamp = $item.LastWriteTimeUtc.Ticks
    $cache = Get-DemoVmHashCache
    if ($cache['verified'].Contains($key)) {
        $entry = $cache['verified'][$key]
        if ($entry.Contains($field) -and [long]$entry['length'] -eq $item.Length -and [long]$entry['lastWriteTicks'] -eq $stamp -and [string]$entry[$field] -eq $expected) {
            return $true
        }
    }
    if ($field -eq 'sha512') {
        $actual = Get-DemoVmFileSha512 -Path $Path
    }
    else {
        $actual = Get-DemoVmFileSha256 -Path $Path
    }
    if ($actual -ne $expected) {
        $label = 'SHA-256'
        if ($field -eq 'sha512') {
            $label = 'SHA-512'
        }
        Write-DemoVmLog -Level 'Warning' -Message ('{0} does not match its {1} (expected {2}, found {3}).' -f $item.Name, $label, $expected, $actual)
        return $false
    }
    $entry = [ordered]@{ length = $item.Length; lastWriteTicks = $stamp }
    $entry[$field] = $actual
    $cache['verified'][$key] = $entry
    Save-DemoVmHashCache -Cache $cache
    return $true
}

function Invoke-DemoVmWebDownload {
    <#
    .SYNOPSIS
    The only network call in the module; tests mock it. Downloads Uri into Path, resuming at Offset.

    .DESCRIPTION
    With an Offset, it asks for the rest of the file with an HTTP Range request (HttpWebRequest.AddRange).
    On 206 Partial Content from that offset it appends to Path; on 200 OK the server sent the whole file,
    so Path is started over. 416 Range Not Satisfiable means Path already holds the whole file; the caller
    verifies the hash either way. Returns StatusCode and Resumed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [long] $Offset = 0
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 300000
    if ($Offset -gt 0) {
        $request.AddRange([long]$Offset)
    }
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
    }
    catch [System.Net.WebException] {
        $failed = $_.Exception.Response
        if ($null -ne $failed -and [int]$failed.StatusCode -eq 416 -and $Offset -gt 0) {
            $failed.Close()
            return [pscustomobject]@{ StatusCode = 416; Resumed = $true }
        }
        throw
    }
    try {
        $status = [int]$response.StatusCode
        $mode = [System.IO.FileMode]::Create
        $resumed = $false
        if ($Offset -gt 0 -and $status -eq 206) {
            $range = [string]$response.Headers['Content-Range']
            if ($range -notmatch ('^bytes {0}-' -f $Offset)) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                throw ('The server answered the range request from byte {0} with "{1}"; the next attempt starts over.' -f $Offset, $range)
            }
            $mode = [System.IO.FileMode]::Append
            $resumed = $true
        }
        $source = $response.GetResponseStream()
        $target = New-Object -TypeName 'System.IO.FileStream' -ArgumentList $Path, $mode, ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
        try {
            $source.CopyTo($target, 1048576)
        }
        finally {
            $target.Dispose()
            $source.Dispose()
        }
        return [pscustomobject]@{ StatusCode = $status; Resumed = $resumed }
    }
    finally {
        $response.Close()
    }
}

function Save-DemoVmDownload {
    <#
    .SYNOPSIS
    Downloads a file with retries and resume, and verifies its SHA-256 before it's used. A mismatch
    deletes the download and throws.

    .DESCRIPTION
    The download goes to <Path>.partial and is retried up to MaxAttempts times with exponential backoff
    (RetryDelaySeconds, then twice that, and so on, at most 5 minutes). Each attempt resumes from the
    bytes already in the .partial file with an HTTP Range request, and the .partial file is kept between
    attempts and between runs, so a 5 GB ISO doesn't start over after a dropped connection. A .partial
    file left by a different URL is discarded first.

    With a pinned SHA-256, a mismatch fails closed. Without one (trust on first use), the first hash is
    recorded and returned with a warning, and any later download with a different hash fails closed.
    With -ExpectedSha512 (the .NET runtime zip, whose SHA-512 Microsoft publishes in its release metadata),
    the file is checked against that hash instead, and a mismatch fails closed; there's no trust on first
    use for it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ExpectedSha256 = '',

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [ValidateRange(1, 20)]
        [int] $MaxAttempts = 5,

        [ValidateRange(0, 300)]
        [int] $RetryDelaySeconds = 15,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ExpectedSha512 = ''
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $partial = $Path + '.partial'
    $sourceMarker = $partial + '.source'
    $source = $Uri.Trim()
    if (Test-Path -LiteralPath $partial) {
        $recorded = ''
        if (Test-Path -LiteralPath $sourceMarker) {
            $recorded = [System.IO.File]::ReadAllText($sourceMarker).Trim()
        }
        if ($recorded -ne $source) {
            Remove-Item -LiteralPath $partial -Force
        }
    }
    [System.IO.File]::WriteAllText($sourceMarker, $source, $script:DemoVmUtf8)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $offset = [long]0
        if (Test-Path -LiteralPath $partial) {
            $offset = (Get-Item -LiteralPath $partial).Length
        }
        if ($offset -gt 0) {
            Write-DemoVmLog -Message ('Downloading {0} (attempt {1} of {2}), resuming at {3:N0} bytes.' -f $Name, $attempt, $MaxAttempts, $offset)
        }
        else {
            Write-DemoVmLog -Message ('Downloading {0} (attempt {1} of {2}).' -f $Name, $attempt, $MaxAttempts)
        }
        try {
            Invoke-DemoVmWebDownload -Uri $Uri -Path $partial -Offset $offset | Out-Null
            break
        }
        catch {
            $message = Protect-DemoVmText -Text $_.Exception.Message
            if ($attempt -ge $MaxAttempts) {
                throw ('The download of {0} failed after {1} attempts: {2}. The partial file is kept, so the next run resumes it.' -f $Name, $MaxAttempts, $message)
            }
            $delay = [int][System.Math]::Min(300, $RetryDelaySeconds * [System.Math]::Pow(2, $attempt - 1))
            Write-DemoVmLog -Level 'Warning' -Message ('The download of {0} failed (attempt {1} of {2}): {3}. Retrying in {4} seconds.' -f $Name, $attempt, $MaxAttempts, $message, $delay)
            Start-Sleep -Seconds $delay
        }
    }
    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        throw ('The download of {0} produced no file.' -f $Name)
    }

    $warning = ''
    $cache = Get-DemoVmHashCache
    if ($ExpectedSha512) {
        $actual = Get-DemoVmFileSha512 -Path $partial
        if ($actual -ne $ExpectedSha512.ToLowerInvariant()) {
            Remove-Item -LiteralPath $partial, $sourceMarker -Force -ErrorAction SilentlyContinue
            throw ('SHA-512 mismatch for {0}: expected {1}, got {2}. The download was deleted (fail closed).' -f $Name, $ExpectedSha512.ToLowerInvariant(), $actual)
        }
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        Move-Item -LiteralPath $partial -Destination $Path
        Remove-Item -LiteralPath $sourceMarker -Force -ErrorAction SilentlyContinue
        $item = Get-Item -LiteralPath $Path
        $cache['verified'][$item.FullName.ToLowerInvariant()] = [ordered]@{
            sha512         = $actual
            length         = $item.Length
            lastWriteTicks = $item.LastWriteTimeUtc.Ticks
        }
        Save-DemoVmHashCache -Cache $cache
        Write-DemoVmLog -Message ('{0} verified: SHA-512 {1}.' -f $Name, $actual)
        return [pscustomobject]@{
            Path            = $Path
            Sha256          = ''
            Sha512          = $actual
            TrustOnFirstUse = $false
            Warning         = ''
        }
    }
    $actual = Get-DemoVmFileSha256 -Path $partial
    if ($ExpectedSha256) {
        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $partial, $sourceMarker -Force -ErrorAction SilentlyContinue
            throw ('SHA-256 mismatch for {0}: expected {1}, got {2}. The download was deleted (fail closed).' -f $Name, $ExpectedSha256.ToLowerInvariant(), $actual)
        }
    }
    else {
        if ($cache['tofu'].Contains($Name)) {
            $recorded = [string]$cache['tofu'][$Name]['sha256']
            if ($recorded -ne $actual) {
                Remove-Item -LiteralPath $partial, $sourceMarker -Force -ErrorAction SilentlyContinue
                throw ('SHA-256 for {0} changed since first use: recorded {1}, got {2}. The download was deleted (fail closed); verify the media and pin its hash in config/versions.json.' -f $Name, $recorded, $actual)
            }
        }
        else {
            $cache['tofu'][$Name] = [ordered]@{ sha256 = $actual; recordedUtc = (Get-DemoVmUtcNow) }
        }
        $warning = 'No SHA-256 is pinned for {0}; its first download was trusted and recorded as {1}. Pin it in config/versions.json.' -f $Name, $actual
        Write-DemoVmLog -Level 'Warning' -Message $warning
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    Move-Item -LiteralPath $partial -Destination $Path
    Remove-Item -LiteralPath $sourceMarker -Force -ErrorAction SilentlyContinue
    $item = Get-Item -LiteralPath $Path
    $cache['verified'][$item.FullName.ToLowerInvariant()] = [ordered]@{
        sha256         = $actual
        length         = $item.Length
        lastWriteTicks = $item.LastWriteTimeUtc.Ticks
    }
    Save-DemoVmHashCache -Cache $cache
    Write-DemoVmLog -Message ('{0} verified: SHA-256 {1}.' -f $Name, $actual)

    [pscustomobject]@{
        Path            = $Path
        Sha256          = $actual
        Sha512          = ''
        TrustOnFirstUse = -not [bool]$ExpectedSha256
        Warning         = $warning
    }
}
