# Arc Jumpstart's prebuilt SQL Server guest for the JumpstartImage install mode (ADR 0006, amendment of 2026-11-05):
# download and verify ArcBox's SQL Server Standard VHDX, make it this demo's arcsql01 at its first boot, and check it.
# Windows PowerShell 5.1 on the Hyper-V host; every in-guest action runs over PowerShell Direct.
# Dot-sourced by vm/bootstrap/Invoke-HostBootstrap.ps1.
#
# Sources (checked 2026-11-05):
# - The image and how ArcBox uses it (azcopy download, Generation 2, PowerShell Direct with its published credential):
#   https://github.com/microsoft/azure_arc/blob/e2c114eed98d18105dcf3a718bef965d5112781b/azure_jumpstart_arcbox/artifacts/ArcServersLogonScript.ps1
# - PowerShell Direct: https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct
# - Renaming a computer that hosts SQL Server (sp_dropserver, sp_addserver ... 'local', restart):
#   https://learn.microsoft.com/sql/database-engine/install-windows/rename-a-computer-that-hosts-a-stand-alone-instance-of-sql-server
# - Uninstalling a feature with setup: https://learn.microsoft.com/sql/sql-server/install/uninstall-an-existing-instance-of-sql-server-setup
# - Database Hub's prerequisites for SQL Server enabled by Azure Arc:
#   https://learn.microsoft.com/fabric/database/hub/add-sql#prerequisites-for-sql-server-enabled-by-azure-arc

function Get-DemoJumpstartPin {
    # The image's pin from the bundle manifest (config/versions.json media.jumpstartArcBoxSqlStd).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    return (Get-DemoVmMediaPin -Name $Context.Host.Media.JumpstartImage -BundleRoot $Context.BundleRoot)
}

function Get-DemoJumpstartPath {
    # The JumpstartImage mode's records in the host's state folder. None of them holds a secret.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    return [pscustomobject]@{
        Image     = Join-Path -Path $Context.Root -ChildPath 'jumpstart-image.json'
        FirstBoot = Join-Path -Path $Context.Root -ChildPath 'jumpstart-firstboot.json'
    }
}

function Get-DemoJumpstartRemoteFact {
    # HEAD on the image's URL: its length, etag, Content-MD5, and Last-Modified. Tests mock it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
    $request.Method = 'HEAD'
    $request.Timeout = 60000
    $response = [System.Net.HttpWebResponse]$request.GetResponse()
    try {
        return [pscustomobject]@{
            ContentLength = [long]$response.ContentLength
            ETag          = ([string]$response.Headers['ETag']).Trim('"')
            ContentMd5    = [string]$response.Headers['Content-MD5']
            LastModified  = [string]$response.Headers['Last-Modified']
        }
    }
    finally {
        $response.Close()
    }
}

function New-DemoJumpstartDownloadRequest {
    <#
    .SYNOPSIS
    The GET for the image from Offset, not sent yet. A resumed download asks for a closed range, bytes=Offset-(Length-1):
    Blob storage serves an anonymous request without x-ms-version at its earliest service version, which takes only that
    form, so an open-ended range (bytes=Offset-) got the whole file and every resume started over (live finding,
    2026-11-06). No x-ms-version is sent: it changes the format of the ETag that the sidecar and the pin compare.

    .NOTES
    https://learn.microsoft.com/rest/api/storageservices/specifying-the-range-header-for-blob-service-operations
    https://learn.microsoft.com/rest/api/storageservices/versioning-for-the-azure-storage-services
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([System.Net.HttpWebRequest])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [long] $Offset = 0,

        [Parameter(Mandatory = $true)]
        [long] $Length
    )

    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 300000
    if ($Offset -gt 0) {
        $request.AddRange([long]$Offset, [long]($Length - 1))
    }
    return $request
}

function Open-DemoJumpstartDownload {
    # Sends New-DemoJumpstartDownloadRequest's GET for the image of Length bytes from Offset. Returns the response stream,
    # the status code, Content-Range, and the response to close. Tests mock it with a MemoryStream.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [long] $Offset = 0,

        [Parameter(Mandatory = $true)]
        [long] $Length
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = New-DemoJumpstartDownloadRequest -Uri $Uri -Offset $Offset -Length $Length
    $response = [System.Net.HttpWebResponse]$request.GetResponse()
    return [pscustomobject]@{
        Stream       = $response.GetResponseStream()
        StatusCode   = [int]$response.StatusCode
        ContentRange = [string]$response.Headers['Content-Range']
        Response     = $response
    }
}

function New-DemoJumpstartHashAlgorithm {
    # The native CNG implementation where it exists (Windows hosts: fast on a 34 GiB file), else the platform's default.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('MD5', 'SHA256')]
        [string] $Name
    )

    try {
        return (New-Object -TypeName ('System.Security.Cryptography.{0}Cng' -f $Name))
    }
    catch {
        if ($Name -eq 'MD5') {
            return [System.Security.Cryptography.MD5]::Create()
        }
        return [System.Security.Cryptography.SHA256]::Create()
    }
}

function New-DemoJumpstartHasher {
    # MD5 for the blob's own Content-MD5 and SHA-256 for the evidence and the pin. A FIPS-only host can't create MD5; the
    # download is then checked by its length and, for the tested image, its pinned SHA-256.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $md5 = $null
    try {
        $md5 = New-DemoJumpstartHashAlgorithm -Name 'MD5'
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('MD5 isn''t available on this host ({0}); the image is checked by its length and SHA-256.' -f $_.Exception.Message)
    }
    return [pscustomobject]@{
        Md5    = $md5
        Sha256 = New-DemoJumpstartHashAlgorithm -Name 'SHA256'
    }
}

function Complete-DemoJumpstartHash {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Hasher
    )

    $empty = New-Object -TypeName 'byte[]' -ArgumentList 0
    $md5 = ''
    if ($null -ne $Hasher.Md5) {
        [void]$Hasher.Md5.TransformFinalBlock($empty, 0, 0)
        $md5 = [System.Convert]::ToBase64String($Hasher.Md5.Hash)
        $Hasher.Md5.Dispose()
    }
    [void]$Hasher.Sha256.TransformFinalBlock($empty, 0, 0)
    $sha256 = ([System.BitConverter]::ToString($Hasher.Sha256.Hash) -replace '-', '').ToLowerInvariant()
    $Hasher.Sha256.Dispose()
    return [pscustomobject]@{ Md5Base64 = $md5; Sha256 = $sha256 }
}

function Get-DemoJumpstartImageDecision {
    <#
    .SYNOPSIS
    Pure: what a finished download means. Fail when the transfer doesn't match the blob (length, or its own Content-MD5),
    or when the pinned image doesn't match its pinned SHA-256; otherwise Pinned when it's the tested image, or Newer with a
    warning when Jumpstart published another one at the same URL (user decision, 2026-11-05: used after the image checks).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Pin,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Remote,

        [Parameter(Mandatory = $true)]
        [long] $Length,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Hash
    )

    if ($Length -ne $Remote.ContentLength) {
        return [pscustomobject]@{ Outcome = 'Incomplete'; Pinned = $false; Message = ('The download has {0:N0} of {1:N0} bytes.' -f $Length, $Remote.ContentLength); Warning = @() }
    }
    if ($Remote.ContentMd5 -and $Hash.Md5Base64 -and $Hash.Md5Base64 -ne $Remote.ContentMd5) {
        return [pscustomobject]@{ Outcome = 'Fail'; Pinned = $false; Message = ('The download doesn''t match the image''s own Content-MD5 (expected {0}, got {1}).' -f $Remote.ContentMd5, $Hash.Md5Base64); Warning = @() }
    }
    $pinned = ([string]$Remote.ETag -eq [string]$Pin['etag'] -and $Remote.ContentLength -eq [long]$Pin['sizeBytes'])
    $warnings = @()
    if ($pinned -and $Pin['sha256'] -and $Hash.Sha256 -ne ([string]$Pin['sha256']).ToLowerInvariant()) {
        return [pscustomobject]@{ Outcome = 'Fail'; Pinned = $true; Message = ('The tested image doesn''t match its pinned SHA-256 (expected {0}, got {1}).' -f ([string]$Pin['sha256']).ToLowerInvariant(), $Hash.Sha256); Warning = @() }
    }
    if (-not $Remote.ContentMd5 -or -not $Hash.Md5Base64) {
        if ($pinned -and $Pin['sha256']) {
            $warnings += 'The image has no Content-MD5 here, so it was checked by its length and its pinned SHA-256.'
        }
        else {
            $warnings += 'The image has no Content-MD5 here and no pinned SHA-256, so only its length was checked; the image checks run next.'
        }
    }
    if (-not $pinned) {
        $warnings += ('Jumpstart published another ArcBox SQL Server Standard image than the one this repository was tested with (etag {0}, Last-Modified {1}; tested: etag {2}, {3}). T2 uses it once the guest passes the image checks (JumpstartImageCheck); config/versions.json media.jumpstartArcBoxSqlStd records the tested one.' -f $Remote.ETag, $Remote.LastModified, $Pin['etag'], $Pin['lastModified'])
    }
    return [pscustomobject]@{ Outcome = $(if ($pinned) { 'Pinned' } else { 'Newer' }); Pinned = $pinned; Message = ''; Warning = $warnings }
}

function Test-DemoJumpstartImage {
    # True when the guest's disk is in place and its download was verified (jumpstart-image.json for this URL). The disk
    # changes once the guest runs, so only the record is compared.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VhdxPath
    )

    if (-not (Test-Path -LiteralPath $VhdxPath -PathType Leaf)) {
        return $false
    }
    $record = Read-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $Context).Image
    if ($null -eq $record) {
        return $false
    }
    return ([string]$record['url'] -eq [string](Get-DemoJumpstartPin -Context $Context)['url'] -and [string]$record['vhdxPath'] -eq $VhdxPath)
}

function Save-DemoJumpstartImage {
    <#
    .SYNOPSIS
    Downloads the Jumpstart VHDX to the guest's disk path and verifies it while it streams, so 34 GiB is read once: its
    length and the blob's own Content-MD5 always (fail closed), and the pinned SHA-256 for the tested image. A partial
    download of the same etag resumes. Writes jumpstart-image.json and the guest's source record, and returns the
    step result, with a warning when Jumpstart published another image than the tested one.

    .DESCRIPTION
    It never replaces the disk of a guest that exists: that's a Fail with the fix, because only a new guest takes an
    image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VhdxPath
    )

    if (Get-VM -Name $Context.GuestName -ErrorAction SilentlyContinue) {
        return (New-DemoVmStepResult -Outcome 'Failed' -Message ('The guest {0} exists, but its Jumpstart image record (jumpstart-image.json) is missing, so its disk is never replaced. Rebuild T2: ./scripts/destroy.ps1, then ./scripts/deploy.ps1 (docs/troubleshooting.md).' -f $Context.GuestName))
    }
    $pin = Get-DemoJumpstartPin -Context $Context
    $settings = $Context.Host.JumpstartImage
    $uri = [string]$pin['url']
    $remote = Get-DemoJumpstartRemoteFact -Uri $uri
    if ($remote.ContentLength -le 0) {
        throw ('The Jumpstart image at {0} reported no length.' -f $uri)
    }
    $folder = Split-Path -Path $VhdxPath -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $partial = $VhdxPath + '.partial'
    $sidecar = $partial + '.json'
    $started = Read-DemoVmJsonFile -Path $sidecar
    if ((Test-Path -LiteralPath $partial) -and ($null -eq $started -or [string]$started['etag'] -ne $remote.ETag)) {
        Remove-Item -LiteralPath $partial -Force
        Write-DemoVmLog -Message 'Discarded a partial download of another version of the Jumpstart image.'
    }
    Write-DemoVmJsonFile -Path $sidecar -InputObject ([ordered]@{ url = $uri; etag = $remote.ETag; startedUtc = (Get-DemoVmUtcNow) })

    # The copy loops below call .NET methods only, never a PowerShell function: Windows PowerShell 5.1 checks a
    # mandatory array parameter by walking every element, so a hash function called per chunk walked the whole 4 MiB
    # buffer for each network read and held the 34 GiB download to 0.2 MB/s (live finding, 2026-11-06).
    $hasher = New-DemoJumpstartHasher
    $bufferBytes = [int]$settings.BufferMB * 1MB
    $buffer = New-Object -TypeName 'byte[]' -ArgumentList $bufferBytes
    $offset = [long]0
    if (Test-Path -LiteralPath $partial) {
        $offset = (Get-Item -LiteralPath $partial).Length
        if ($offset -gt $remote.ContentLength) {
            Remove-Item -LiteralPath $partial -Force
            $offset = 0
        }
        elseif ($offset -gt 0) {
            # A resumed download: the bytes already on disk go through the hashes first.
            $md5Algorithm = $hasher.Md5
            $sha256Algorithm = $hasher.Sha256
            $existing = [System.IO.File]::OpenRead($partial)
            try {
                while (($count = $existing.Read($buffer, 0, $bufferBytes)) -gt 0) {
                    if ($null -ne $md5Algorithm) {
                        [void]$md5Algorithm.TransformBlock($buffer, 0, $count, $null, 0)
                    }
                    [void]$sha256Algorithm.TransformBlock($buffer, 0, $count, $null, 0)
                }
            }
            finally {
                $existing.Dispose()
            }
        }
    }
    if ($offset -lt $remote.ContentLength) {
        $resumeText = ''
        if ($offset -gt 0) {
            $resumeText = ', resuming at {0:N1} GiB' -f ($offset / 1GB)
        }
        Write-DemoVmLog -Message ('Downloading the Jumpstart image ({0:N1} GiB, etag {1}){2}.' -f ($remote.ContentLength / 1GB), $remote.ETag, $resumeText)
        $download = Open-DemoJumpstartDownload -Uri $uri -Offset $offset -Length $remote.ContentLength
        try {
            $mode = [System.IO.FileMode]::Append
            if ($offset -gt 0 -and $download.StatusCode -ne 206) {
                # The server sent the whole file instead of the rest: start over, and say so.
                Write-DemoVmLog -Level 'Warning' -Message ('The server ignored the range request from byte {0:N0} and sent the whole Jumpstart image (HTTP {1}, not 206), so the download starts over.' -f $offset, $download.StatusCode)
                $hasher = New-DemoJumpstartHasher
                $offset = 0
            }
            elseif ($offset -gt 0 -and [string]$download.ContentRange -notmatch ('^bytes {0}-' -f $offset)) {
                throw ('The server answered the range request from byte {0} with "{1}"; the next attempt resumes again.' -f $offset, $download.ContentRange)
            }
            if ($offset -eq 0) {
                $mode = [System.IO.FileMode]::Create
            }
            # A network read returns a few KiB; the file's own BufferMB buffer turns them into large disk writes.
            $target = New-Object -TypeName 'System.IO.FileStream' -ArgumentList $partial, $mode, ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None), $bufferBytes
            $source = $download.Stream
            $md5Algorithm = $hasher.Md5
            $sha256Algorithm = $hasher.Sha256
            try {
                while (($count = $source.Read($buffer, 0, $bufferBytes)) -gt 0) {
                    $target.Write($buffer, 0, $count)
                    if ($null -ne $md5Algorithm) {
                        [void]$md5Algorithm.TransformBlock($buffer, 0, $count, $null, 0)
                    }
                    [void]$sha256Algorithm.TransformBlock($buffer, 0, $count, $null, 0)
                }
            }
            finally {
                $target.Dispose()
            }
        }
        finally {
            $download.Stream.Dispose()
            if ($null -ne $download.Response) {
                $download.Response.Close()
            }
        }
    }
    $hash = Complete-DemoJumpstartHash -Hasher $hasher
    $length = (Get-Item -LiteralPath $partial).Length
    $decision = Get-DemoJumpstartImageDecision -Pin $pin -Remote $remote -Length $length -Hash $hash
    if ($decision.Outcome -eq 'Incomplete') {
        throw ('{0} The partial file is kept, so the next run resumes it.' -f $decision.Message)
    }
    if ($decision.Outcome -eq 'Fail') {
        Remove-Item -LiteralPath $partial, $sidecar -Force -ErrorAction SilentlyContinue
        throw ('{0} The download was deleted (fail closed); the next run downloads it again.' -f $decision.Message)
    }

    $record = [ordered]@{
        url                = $uri
        vhdxPath           = $VhdxPath
        etag               = $remote.ETag
        lastModified       = $remote.LastModified
        sizeBytes          = $length
        contentMd5         = $remote.ContentMd5
        md5Verified        = [bool]($remote.ContentMd5 -and $hash.Md5Base64)
        sha256             = $hash.Sha256
        pinned             = $decision.Pinned
        pinnedEtag         = [string]$pin['etag']
        pinnedLastModified = [string]$pin['lastModified']
        verifiedUtc        = Get-DemoVmUtcNow
    }
    # The record goes first: a run that stops before the move finds the complete partial file and only moves it.
    Write-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $Context).Image -InputObject $record
    Move-Item -LiteralPath $partial -Destination $VhdxPath -Force
    Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
    Set-DemoHostGuestSource -Context $Context -Source 'JumpstartImage'
    Write-DemoVmLog -Message ('The Jumpstart image is in place: {0:N1} GiB, etag {1}, SHA-256 {2}, {3}.' -f ($length / 1GB), $remote.ETag, $hash.Sha256, $(if ($decision.Pinned) { 'the tested image' } else { 'another image than the tested one' }))
    if (@($decision.Warning).Count -gt 0) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage @($decision.Warning))
    }
}

function Get-DemoJumpstartTextDownload {
    # The pinned script, as bytes. Tests mock it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object -TypeName 'System.Net.WebClient'
    try {
        return , $client.DownloadData($Uri)
    }
    finally {
        $client.Dispose()
    }
}

function Get-DemoJumpstartPatternValue {
    # Pure: the one 'value' group that Pattern matches in Text; anything but exactly one match fails closed.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    $found = [regex]::Matches($Text, $Pattern)
    if ($found.Count -ne 1 -or -not $found[0].Groups['value'].Success -or [string]::IsNullOrEmpty($found[0].Groups['value'].Value)) {
        throw ('Jumpstart''s pinned script has {0} match(es) for the {1}, not exactly one; nothing was used (fail closed).' -f $found.Count, $Label)
    }
    return $found[0].Groups['value'].Value
}

function Get-DemoJumpstartDefaultCredential {
    <#
    .SYNOPSIS
    The image's published default credential, read from Jumpstart's own script at the pinned commit, never from this
    repository (user decision, 2026-11-05), after its SHA-256 is checked (fail closed). The password is registered for
    redaction and lives only in the returned credential; it's used once, while the guest has no network, and replaced.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Pin
    )

    $source = $Pin['credentialSource']
    if ($null -eq $source -or [string]$source['url'] -notmatch '^https://' -or [string]$source['sha256'] -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The Jumpstart image''s pin has no usable credentialSource (an HTTPS url and a SHA-256) in config/versions.json.'
    }
    $bytes = Get-DemoJumpstartTextDownload -Uri ([string]$source['url'])
    $sha = New-DemoJumpstartHashAlgorithm -Name 'SHA256'
    try {
        $actual = ([System.BitConverter]::ToString($sha.ComputeHash([byte[]]$bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    if ($actual -ne ([string]$source['sha256']).ToLowerInvariant()) {
        throw ('Jumpstart''s script at the pinned commit doesn''t match its SHA-256 (expected {0}, got {1}); nothing was used (fail closed).' -f ([string]$source['sha256']).ToLowerInvariant(), $actual)
    }
    $text = [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes)
    $userName = Get-DemoJumpstartPatternValue -Text $text -Pattern ([string]$source['userNamePattern']) -Label 'user name'
    $value = Get-DemoJumpstartPatternValue -Text $text -Pattern ([string]$source['passwordPattern']) -Label 'password'
    Register-DemoVmSecret -Value $value
    $secure = New-Object -TypeName 'System.Security.SecureString'
    foreach ($character in $value.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    $value = $null
    return (New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $userName, $secure)
}

function Wait-DemoGuestHeartbeat {
    # Bounded wait until Hyper-V's heartbeat says the guest's operating system runs, so a credential is tried only then.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 20
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if ($vm -and [string]$vm.State -eq 'Running' -and [string]$vm.Heartbeat -like 'Ok*') {
            return $true
        }
        Start-Sleep -Seconds 15
    }
    return $false
}

function Set-DemoGuestInitialSecret {
    <#
    .SYNOPSIS
    Replaces the image's published password with a random one the way Update-DemoGuestSecret rotates (ADR 0009): the new
    value is stored with DPAPI as pending, set in the guest over PowerShell Direct with the published credential, proven
    with a new session, and only then promoted. If it can't sign in, the published one is set back, so the next run starts
    over. Nothing is logged or returned.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [pscredential] $InitialCredential,

        [Parameter(Mandatory = $true)]
        [string] $SecretPath,

        [string] $UserName = 'Administrator'
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Replace the published administrator password')) {
        return
    }
    $folder = Split-Path -Path $SecretPath -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Protect-DemoVmFolder -Path $folder
    }
    $pendingPath = $SecretPath + '.pending'
    $value = Build-DemoVmPassword -Length 24
    Protect-DemoVmSecret -Value $value -Path $pendingPath
    $value = $null
    $new = Get-DemoGuestCredential -SecretPath $pendingPath -UserName $UserName
    $setSecret = {
        param($Account, $Secret)
        Set-LocalUser -Name $Account -Password $Secret
    }
    Invoke-Command -VMName $Name -Credential $InitialCredential -ScriptBlock $setSecret -ArgumentList $UserName, $new.Password -ErrorAction Stop
    if (Test-DemoGuestOnline -Name $Name -Credential $new) {
        Move-Item -LiteralPath $pendingPath -Destination $SecretPath -Force
        Write-DemoVmLog -Message 'Replaced the image''s published administrator password with a random one, stored on the host with DPAPI.'
        return
    }
    Invoke-Command -VMName $Name -Credential $InitialCredential -ScriptBlock $setSecret -ArgumentList $UserName, $InitialCredential.Password -ErrorAction Stop
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
    throw 'The new guest password could not sign in, so the published one was set back.'
}

function Get-DemoJumpstartGuestCredential {
    <#
    .SYNOPSIS
    The credential that signs in to the guest now: the stored one; a pending one from a rotation that stopped midway
    (promoted); or, before the first rotation, Jumpstart's published one, replaced with a random one at once.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $userName = $Context.Guest.AdministratorName
    if (Test-Path -LiteralPath $Context.SecretPath -PathType Leaf) {
        $stored = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $userName
        if (Wait-DemoGuestOnline -Name $Context.GuestName -Credential $stored -TimeoutMinutes 3) {
            return $stored
        }
    }
    $pending = $Context.SecretPath + '.pending'
    if (Test-Path -LiteralPath $pending -PathType Leaf) {
        $candidate = Get-DemoGuestCredential -SecretPath $pending -UserName $userName
        if (Test-DemoGuestOnline -Name $Context.GuestName -Credential $candidate) {
            Move-Item -LiteralPath $pending -Destination $Context.SecretPath -Force
            Write-DemoVmLog -Message 'A guest password rotation had stopped midway; its new password is the one that signs in, so it was kept.'
            return $candidate
        }
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
    }
    $published = Get-DemoJumpstartDefaultCredential -Pin (Get-DemoJumpstartPin -Context $Context)
    $minutes = [int]$Context.Host.JumpstartImage.CredentialWaitMinutes
    if (-not (Wait-DemoGuestOnline -Name $Context.GuestName -Credential $published -TimeoutMinutes $minutes)) {
        throw ('{0} didn''t accept Jumpstart''s published credential within {1} minutes. Either its first boot is slow (the next run tries again) or Jumpstart changed the image''s password: then point media.jumpstartArcBoxSqlStd.credentialSource in config/versions.json at the Jumpstart commit that matches the image (docs/troubleshooting.md).' -f $Context.GuestName, $minutes)
    }
    Set-DemoGuestInitialSecret -Name $Context.GuestName -InitialCredential $published -SecretPath $Context.SecretPath -UserName $userName -Confirm:$false
    return (Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $userName)
}

# In the guest: the computer name and the time zone (the rename takes effect at the next restart).
$script:DemoJumpstartIdentityBlock = {
    param($NewName, $TimeZoneId)
    $ErrorActionPreference = 'Stop'
    $result = [ordered]@{ oldName = [string]$env:COMPUTERNAME; renamed = $false; timeZone = '' }
    if ((Get-TimeZone).Id -ne $TimeZoneId) {
        Set-TimeZone -Id $TimeZoneId
    }
    $result.timeZone = (Get-TimeZone).Id
    if ([string]$env:COMPUTERNAME -ne $NewName) {
        Rename-Computer -NewName $NewName -Force -WarningAction SilentlyContinue
        $result.renamed = $true
    }
    [pscustomobject]$result
}

# In the guest, as its Administrator (a sysadmin through the image's own login): SQL Server's name after the computer's
# (sp_dropserver, then sp_addserver ... 'local', then a restart), BUILTIN\Administrators as sysadmin as in the build path
# (so SYSTEM, which runs the workload task, is one too), every enabled SQL login disabled (sa with a random password that
# never leaves the guest), and the image's sample databases dropped. Each statement checks first, so a re-run changes
# nothing.
$script:DemoJumpstartSqlBlock = {
    param($ServerName, $SampleDatabases)
    $ErrorActionPreference = 'Stop'
    $result = [ordered]@{ oldServerName = ''; serverRenamed = $false; sysadminGroupAdded = $false; loginsDisabled = @(); databasesDropped = @(); restarted = $false }
    $connection = New-Object -TypeName 'System.Data.SqlClient.SqlConnection' -ArgumentList 'Data Source=.;Initial Catalog=master;Integrated Security=True;Application Name=DbHubDemo.Bootstrap;Connect Timeout=30'
    $connection.Open()
    $run = {
        param($Text)
        $command = $connection.CreateCommand()
        $command.CommandText = $Text
        $command.CommandTimeout = 600
        $command.ExecuteScalar()
    }
    $quote = {
        param($Name)
        '[' + ([string]$Name).Replace(']', ']]') + ']'
    }
    try {
        $current = & $run 'SELECT @@SERVERNAME'
        if ($current -is [System.DBNull]) {
            $current = ''
        }
        $result.oldServerName = [string]$current
        if ([string]$current -ne $ServerName) {
            if ([string]$current) {
                & $run ("EXEC sp_dropserver @server = N'{0}';" -f ([string]$current).Replace("'", "''")) | Out-Null
            }
            & $run ("EXEC sp_addserver @server = N'{0}', @local = N'local';" -f $ServerName.Replace("'", "''")) | Out-Null
            $result.serverRenamed = $true
        }
        if ([int](& $run "SELECT COUNT(*) FROM sys.server_principals WHERE name = N'BUILTIN\Administrators'") -eq 0) {
            & $run 'CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS;' | Out-Null
        }
        if ([string](& $run "SELECT IS_SRVROLEMEMBER(N'sysadmin', N'BUILTIN\Administrators')") -ne '1') {
            & $run 'ALTER SERVER ROLE [sysadmin] ADD MEMBER [BUILTIN\Administrators];' | Out-Null
            $result.sysadminGroupAdded = $true
        }
        $logins = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT name FROM sys.sql_logins WHERE is_disabled = 0 AND name NOT LIKE N'##%##'"
        $reader = $command.ExecuteReader()
        while ($reader.Read()) {
            $logins.Add([string]$reader.GetValue(0))
        }
        $reader.Close()
        foreach ($login in $logins) {
            if ($login -eq 'sa') {
                $bytes = New-Object -TypeName 'byte[]' -ArgumentList 24
                $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                $generator.GetBytes($bytes)
                $generator.Dispose()
                $random = [System.Convert]::ToBase64String($bytes) + 'a1!A'
                & $run ("ALTER LOGIN {0} WITH PASSWORD = '{1}';" -f (& $quote $login), $random.Replace("'", "''")) | Out-Null
                $random = $null
            }
            & $run ('ALTER LOGIN {0} DISABLE;' -f (& $quote $login)) | Out-Null
            $result.loginsDisabled += $login
        }
        foreach ($database in @($SampleDatabases)) {
            if (-not ((& $run ("SELECT DB_ID(N'{0}')" -f ([string]$database).Replace("'", "''"))) -is [System.DBNull])) {
                & $run ('ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {0};' -f (& $quote $database)) | Out-Null
                $result.databasesDropped += [string]$database
            }
        }
    }
    finally {
        $connection.Dispose()
    }
    if ($result.serverRenamed) {
        Restart-Service -Name 'MSSQLSERVER' -Force
        $agent = Get-Service -Name 'SQLSERVERAGENT' -ErrorAction SilentlyContinue
        if ($agent -and [string]$agent.StartType -eq 'Automatic' -and [string]$agent.Status -ne 'Running') {
            Start-Service -Name 'SQLSERVERAGENT'
        }
        $result.restarted = $true
    }
    [pscustomobject]$result
}

# In the guest: the image's extra services stopped and disabled, and Integration Services uninstalled with setup (as on
# T1, ADR 0006: Arc's inventory lists an installed feature as its own instance resource), then C:\Jumpstart deleted: the
# licensed SQL Server media with its embedded key, the sample backup, and ArcBox's files. An Arc agent identity left in
# the image is reset locally, before the guest has any network. A failed uninstall is only a warning.
$script:DemoJumpstartCleanupBlock = {
    param($ServiceNames, $Features, $InstanceName, $JumpstartFolder, $SetupTimeoutMinutes)
    $ErrorActionPreference = 'Stop'
    $result = [ordered]@{ disabled = @(); uninstall = $null; folderRemoved = $false; arcReset = '' }
    foreach ($name in @($ServiceNames)) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) {
            if ([string]$service.StartType -ne 'Disabled') {
                Set-Service -Name $name -StartupType Disabled
            }
            if ([string]$service.Status -ne 'Stopped') {
                Stop-Service -Name $name -Force
            }
            $result.disabled += $name
        }
    }
    if (Get-Service -Name 'MsDtsServer160' -ErrorAction SilentlyContinue) {
        $setup = Get-ChildItem -Path (Join-Path -Path $JumpstartFolder -ChildPath '*\setup.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $setup) {
            $setup = Get-Item -LiteralPath 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\SQL2022\setup.exe' -ErrorAction SilentlyContinue
        }
        $uninstall = [ordered]@{ setup = ''; exitCode = $null; finalResult = ''; serviceLeft = $true }
        if ($setup) {
            $uninstall.setup = [string]$setup.FullName
            $arguments = @('/QUIET', '/ACTION=Uninstall', ('/FEATURES={0}' -f $Features), ('/INSTANCENAME={0}' -f $InstanceName))
            $process = Start-Process -FilePath $setup.FullName -ArgumentList $arguments -PassThru -WindowStyle Hidden
            $null = $process.Handle
            if ($process.WaitForExit([int]$SetupTimeoutMinutes * 60000)) {
                $uninstall.exitCode = [int]$process.ExitCode
            }
            $summary = 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt'
            if (Test-Path -LiteralPath $summary) {
                $line = @(Get-Content -LiteralPath $summary | Where-Object { $_ -match '^\s*Final result:\s*(.+?)\s*$' } | Select-Object -First 1)
                if ($line.Count -gt 0 -and [string]$line[0] -match '^\s*Final result:\s*(.+?)\s*$') {
                    $uninstall.finalResult = $Matches[1]
                }
            }
        }
        $uninstall.serviceLeft = [bool](Get-Service -Name 'MsDtsServer160' -ErrorAction SilentlyContinue)
        $result.uninstall = $uninstall
    }
    if (Test-Path -LiteralPath $JumpstartFolder) {
        Remove-Item -LiteralPath $JumpstartFolder -Recurse -Force
        $result.folderRemoved = $true
    }
    $agent = Join-Path -Path $env:ProgramFiles -ChildPath 'AzureConnectedMachineAgent\azcmagent.exe'
    if (Test-Path -LiteralPath $agent) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $shown = ((& $agent show -j 2>$null) | ForEach-Object { [string]$_ }) -join ''
            $resource = ''
            if ($shown) {
                $parsed = $shown | ConvertFrom-Json
                foreach ($key in 'resourceName', 'ResourceName', 'resourceId') {
                    if ($parsed.PSObject.Properties[$key] -and [string]$parsed.$key) {
                        $resource = [string]$parsed.$key
                        break
                    }
                }
            }
            if ($resource) {
                & $agent disconnect --force-local-only 2>&1 | Out-Null
                $result.arcReset = 'reset'
            }
        }
        finally {
            $ErrorActionPreference = $previous
        }
    }
    [pscustomobject]$result
}

function Test-DemoGuestAdapterConnected {
    # True when the guest's network adapter is on the switch.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $SwitchName
    )

    $adapters = @(Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue)
    return ($adapters.Count -gt 0 -and @($adapters | Where-Object { [string]$_.SwitchName -ne $SwitchName }).Count -eq 0)
}

function Connect-DemoGuestAdapter {
    # Puts the guest's network adapters on the switch (Connect-VMNetworkAdapter).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $SwitchName
    )

    foreach ($adapter in @(Get-VMNetworkAdapter -VMName $Name)) {
        if ([string]$adapter.SwitchName -ne $SwitchName) {
            Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $SwitchName
        }
    }
    Write-DemoVmLog -Message ('Connected {0} to {1}.' -f $Name, $SwitchName)
}

function Test-DemoJumpstartFirstBoot {
    # True when the first boot finished (its record), the guest is on its switch, and the stored password signs in.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $record = Read-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $Context).FirstBoot
    if ($null -eq $record -or -not [bool]$record['completed']) {
        return $false
    }
    if (-not (Test-DemoGuestAdapterConnected -Name $Context.GuestName -SwitchName $Context.Host.SwitchName)) {
        return $false
    }
    return (Test-DemoHostGuestReachable -Context $Context)
}

function Invoke-DemoJumpstartFirstBoot {
    <#
    .SYNOPSIS
    Makes the Jumpstart guest this demo's arcsql01, while it has no network: the published password replaced, the computer
    renamed and set to UTC (a restart), SQL Server renamed with the sysadmin group, its SQL logins disabled, and its sample
    databases dropped, the extra services removed and C:\Jumpstart deleted; then its adapter goes on the switch. Every part
    checks first, so a run that stopped midway finishes the rest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $name = $Context.GuestName
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw ('The guest {0} doesn''t exist yet.' -f $name)
    }
    if ([string]$vm.State -ne 'Running') {
        Start-VM -Name $name
    }
    if (-not (Wait-DemoGuestHeartbeat -Name $name -TimeoutMinutes ([int]$Context.Host.GuestBootTimeoutMinutes))) {
        return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('Waiting for the Jumpstart guest {0} to boot.' -f $name))
    }
    $credential = Get-DemoJumpstartGuestCredential -Context $Context
    $settings = $Context.Host.JumpstartImage
    $expected = (Get-DemoJumpstartPin -Context $Context)['expected']
    $warnings = @()

    $identity = Invoke-Command -VMName $name -Credential $credential -ScriptBlock $script:DemoJumpstartIdentityBlock -ArgumentList $name, $Context.Guest.TimeZone -ErrorAction Stop
    if ([bool]$identity.renamed) {
        Write-DemoVmLog -Message ('Renamed the guest''s computer from {0} to {1}; restarting it.' -f $identity.oldName, $name)
        Invoke-Command -VMName $name -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 30
        if (-not (Wait-DemoGuestOnline -Name $name -Credential $credential -TimeoutMinutes 15)) {
            return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('The guest {0} is restarting after its rename.' -f $name))
        }
    }

    $sql = Invoke-Command -VMName $name -Credential $credential -ScriptBlock $script:DemoJumpstartSqlBlock -ArgumentList $name, @($expected['sampleDatabases']) -ErrorAction Stop
    Write-DemoVmLog -Message ('SQL Server in the guest: name {0}{1}, sysadmin group {2}, {3} SQL login(s) disabled, {4} sample database(s) dropped.' -f $name, $(if ([bool]$sql.serverRenamed) { ' (was ' + [string]$sql.oldServerName + ')' } else { '' }), $(if ([bool]$sql.sysadminGroupAdded) { 'added' } else { 'in place' }), @($sql.loginsDisabled).Count, @($sql.databasesDropped).Count)

    # Every typed argument is in parentheses: in argument mode, [string]$x is an expandable string, not a cast (live finding,
    # 2026-11-06: the cleanup got "[string]System.Collections.Hashtable[jumpstartFolder]" and never deleted C:\Jumpstart).
    $cleanup = Invoke-Command -VMName $name -Credential $credential -ScriptBlock $script:DemoJumpstartCleanupBlock -ArgumentList @($settings.AssociatedServices), ([string]$settings.UninstallFeatures), ([string]$Context.Guest.Sql.InstanceName), ([string]$expected['jumpstartFolder']), ([int]$settings.SetupTimeoutMinutes) -ErrorAction Stop
    if ($null -ne $cleanup.uninstall) {
        $exitCode = $cleanup.uninstall.exitCode
        if ([bool]$cleanup.uninstall.serviceLeft -or ($null -ne $exitCode -and [int]$exitCode -notin 0, 3010)) {
            $warnings += ('Uninstalling {0} in {1} didn''t pass (setup {2}, exit code {3}, final result "{4}"); its services stay stopped and disabled, and Arc''s inventory may list it as another instance.' -f $settings.UninstallFeatures, $name, $(if ($cleanup.uninstall.setup) { $cleanup.uninstall.setup } else { 'not found' }), $(if ($null -eq $exitCode) { 'none' } else { $exitCode }), $cleanup.uninstall.finalResult)
        }
        if ($null -ne $exitCode -and [int]$exitCode -eq 3010) {
            Invoke-Command -VMName $name -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 30
            if (-not (Wait-DemoGuestOnline -Name $name -Credential $credential -TimeoutMinutes 15)) {
                return (New-DemoVmStepResult -Outcome 'InProgress' -Message ('The guest {0} is restarting after setup removed {1}.' -f $name, $settings.UninstallFeatures))
            }
        }
    }
    if (-not (Test-DemoGuestAdapterConnected -Name $name -SwitchName $Context.Host.SwitchName)) {
        Connect-DemoGuestAdapter -Name $name -SwitchName $Context.Host.SwitchName
    }
    $record = [ordered]@{
        completed          = $true
        completedUtc       = Get-DemoVmUtcNow
        oldComputerName    = [string]$identity.oldName
        timeZone           = [string]$identity.timeZone
        oldServerName      = [string]$sql.oldServerName
        sysadminGroupAdded = [bool]$sql.sysadminGroupAdded
        loginsDisabled     = @($sql.loginsDisabled)
        databasesDropped   = @($sql.databasesDropped)
        servicesDisabled   = @($cleanup.disabled)
        uninstall          = $cleanup.uninstall
        jumpstartFolder    = $(if ([bool]$cleanup.folderRemoved) { 'removed' } else { 'absent' })
        arcReset           = [string]$cleanup.arcReset
        warnings           = @($warnings)
    }
    Write-DemoVmJsonFile -Path (Get-DemoJumpstartPath -Context $Context).FirstBoot -InputObject $record -Redact
    Write-DemoVmLog -Message ('The Jumpstart guest is {0}: renamed, password replaced, SQL Server prepared, extras removed, and on {1}.' -f $name, $Context.Host.SwitchName)
    if ($warnings.Count -gt 0) {
        return (New-DemoVmStepResult -Outcome 'Done' -WarningMessage $warnings)
    }
}

# In the guest, read-only: the facts the image checks need.
$script:DemoJumpstartFactBlock = {
    param($InstanceName, $SampleDatabases, $JumpstartFolder)
    $ErrorActionPreference = 'Stop'
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Select-Object -First 1
    $result = [ordered]@{
        computerName       = [string]$env:COMPUTERNAME
        osCaption          = [string]$os.Caption
        osBuild            = [string]$os.BuildNumber
        licenseDescription = $(if ($license) { [string]$license.Description } else { '' })
        licenseStatus      = $(if ($license) { [int]$license.LicenseStatus } else { -1 })
        sqlServiceExists   = $false
        sqlRunning         = $false
        sqlEdition         = ''
        sqlVersion         = ''
        sqlServerName      = ''
        sqlIsSysAdmin      = $false
        sqlEnabledLogins   = @()
        sampleDatabases    = @()
        jumpstartFolder    = (Test-Path -LiteralPath $JumpstartFolder)
        sqlError           = ''
    }
    $service = Get-Service -Name $InstanceName -ErrorAction SilentlyContinue
    if ($service) {
        $result.sqlServiceExists = $true
        $result.sqlRunning = [string]$service.Status -eq 'Running'
    }
    if ($result.sqlRunning) {
        try {
            $connection = New-Object -TypeName 'System.Data.SqlClient.SqlConnection' -ArgumentList 'Data Source=.;Initial Catalog=master;Integrated Security=True;Application Name=DbHubDemo.Bootstrap;Connect Timeout=20'
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = "SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), CAST(@@SERVERNAME AS nvarchar(128)), IS_SRVROLEMEMBER('sysadmin')"
            $reader = $command.ExecuteReader()
            if ($reader.Read()) {
                $result.sqlEdition = [string]$reader.GetValue(0)
                $result.sqlVersion = [string]$reader.GetValue(1)
                $result.sqlServerName = [string]$reader.GetValue(2)
                $result.sqlIsSysAdmin = ([string]$reader.GetValue(3) -eq '1')
            }
            $reader.Close()
            $command.CommandText = "SELECT name FROM sys.sql_logins WHERE is_disabled = 0 AND name NOT LIKE N'##%##'"
            $reader = $command.ExecuteReader()
            $logins = @()
            while ($reader.Read()) {
                $logins += [string]$reader.GetValue(0)
            }
            $reader.Close()
            $result.sqlEnabledLogins = $logins
            $present = @()
            foreach ($database in @($SampleDatabases)) {
                $command.CommandText = "SELECT DB_ID(N'{0}')" -f ([string]$database).Replace("'", "''")
                if (-not ($command.ExecuteScalar() -is [System.DBNull])) {
                    $present += [string]$database
                }
            }
            $result.sampleDatabases = $present
            $connection.Dispose()
        }
        catch {
            $result.sqlError = ([string]$_.Exception.Message).Substring(0, [Math]::Min(200, ([string]$_.Exception.Message).Length))
        }
    }
    [pscustomobject]$result
}

function Get-DemoJumpstartCheckProblem {
    <#
    .SYNOPSIS
    Pure: what keeps the guest from being T2. Fatal problems (no default instance, an edition other than Standard, another
    major version, the guest's Administrator not a sysadmin) stop T2 with the cause; the others are first-boot work that
    a re-run finishes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Fact,

        [Parameter(Mandatory = $true)]
        [string] $GuestName,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Expected
    )

    $problems = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $add = {
        param($Code, $Fatal, $Message)
        $problems.Add([pscustomobject]@{ Code = $Code; Fatal = [bool]$Fatal; Message = $Message })
    }
    if ([string]$Fact.computerName -ne $GuestName) {
        & $add 'ComputerName' $false ('the computer name is {0}, not {1}' -f $Fact.computerName, $GuestName)
    }
    if (-not [bool]$Fact.sqlServiceExists) {
        & $add 'NoDefaultInstance' $true ('there''s no default SQL Server instance ({0})' -f $Expected['instanceName'])
        return $problems.ToArray()
    }
    if (-not [bool]$Fact.sqlRunning -or [string]$Fact.sqlError -or -not [string]$Fact.sqlEdition) {
        & $add 'SqlNotRunning' $false ('SQL Server isn''t answering{0}' -f $(if ([string]$Fact.sqlError) { ': ' + [string]$Fact.sqlError } else { '' }))
        return $problems.ToArray()
    }
    if ([string]$Fact.sqlEdition -notlike ('{0}*' -f $Expected['sqlEdition'])) {
        & $add 'Edition' $true ('SQL Server is {0}, not {1} Edition, which Database Hub''s performance views need' -f $Fact.sqlEdition, $Expected['sqlEdition'])
    }
    $major = 0
    if ([string]$Fact.sqlVersion -match '^(\d+)\.') {
        $major = [int]$Matches[1]
    }
    if ($major -ne [int]$Expected['sqlMajorVersion']) {
        & $add 'Version' $true ('SQL Server is version {0}, not {1}.x (SQL Server 2022), which this repository was tested with' -f $Fact.sqlVersion, $Expected['sqlMajorVersion'])
    }
    if (-not [bool]$Fact.sqlIsSysAdmin) {
        & $add 'SysAdmin' $true 'the guest''s Administrator isn''t a SQL Server sysadmin'
    }
    if ([string]$Fact.sqlServerName -ne $GuestName) {
        & $add 'ServerName' $false ('SQL Server''s name is {0}, not {1}' -f $Fact.sqlServerName, $GuestName)
    }
    if (@($Fact.sqlEnabledLogins).Count -gt 0) {
        & $add 'SqlLogin' $false ('SQL login(s) still enabled: {0}' -f (@($Fact.sqlEnabledLogins) -join ', '))
    }
    if (@($Fact.sampleDatabases).Count -gt 0) {
        & $add 'SampleDatabase' $false ('sample database(s) still there: {0}' -f (@($Fact.sampleDatabases) -join ', '))
    }
    if ([bool]$Fact.jumpstartFolder) {
        & $add 'JumpstartFolder' $false ('{0} is still there' -f $Expected['jumpstartFolder'])
    }
    return $problems.ToArray()
}

function Get-DemoJumpstartGuestFact {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
    $expected = (Get-DemoJumpstartPin -Context $Context)['expected']
    return (Invoke-Command -VMName $Context.GuestName -Credential $credential -ScriptBlock $script:DemoJumpstartFactBlock -ArgumentList ([string]$Context.Guest.Sql.InstanceName), @($expected['sampleDatabases']), ([string]$expected['jumpstartFolder']) -ErrorAction Stop)
}

function Test-DemoJumpstartGuest {
    # The JumpstartImageCheck step's check: no problem at all. Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    try {
        $fact = Get-DemoJumpstartGuestFact -Context $Context
        $expected = (Get-DemoJumpstartPin -Context $Context)['expected']
        return (@(Get-DemoJumpstartCheckProblem -Fact $fact -GuestName $Context.GuestName -Expected $expected).Count -eq 0)
    }
    catch {
        Write-DemoVmLog -Level 'Warning' -Message ('Jumpstart image check: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Invoke-DemoJumpstartImageCheck {
    <#
    .SYNOPSIS
    The image checks before Arc onboarding. A fatal problem stops T2 here with the cause and the commands, and nothing
    switches by itself (user decision, 2026-11-05). First-boot work that's unfinished runs again, and SQL Server that isn't
    answering is started; a problem that's still there after that counts an attempt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $expected = (Get-DemoJumpstartPin -Context $Context)['expected']
    $fact = Get-DemoJumpstartGuestFact -Context $Context
    $problems = @(Get-DemoJumpstartCheckProblem -Fact $fact -GuestName $Context.GuestName -Expected $expected)
    $fatal = @($problems | Where-Object { $_.Fatal })
    if ($fatal.Count -gt 0) {
        $text = ($fatal | ForEach-Object { $_.Message }) -join '; '
        return (New-DemoVmStepResult -Outcome 'Failed' -Message ('T2 can''t use this Jumpstart image: {0}. Nothing switches by itself. To check the guest again, run ./scripts/deploy.ps1 -FromStage Artifacts, which starts a new bootstrap generation; or choose another t2SqlInstallMode (PaygWizard, ProductKey, or Developer) in config/demo.config.json, then ./scripts/destroy.ps1 and ./scripts/deploy.ps1 (docs/troubleshooting.md).' -f $text))
    }
    if (@($problems | Where-Object { $_.Code -eq 'SqlNotRunning' }).Count -gt 0) {
        $credential = Get-DemoGuestCredential -SecretPath $Context.SecretPath -UserName $Context.Guest.AdministratorName
        Invoke-Command -VMName $Context.GuestName -Credential $credential -ArgumentList ([string]$Context.Guest.Sql.InstanceName) -ErrorAction Stop -ScriptBlock {
            param($Service)
            Start-Service -Name $Service
        }
        Start-Sleep -Seconds 20
    }
    elseif ($problems.Count -gt 0) {
        Invoke-DemoJumpstartFirstBoot -Context $Context | Out-Null
    }
    if (-not (Test-DemoJumpstartGuest -Context $Context)) {
        $left = @(Get-DemoJumpstartCheckProblem -Fact (Get-DemoJumpstartGuestFact -Context $Context) -GuestName $Context.GuestName -Expected $expected)
        throw ('The Jumpstart guest isn''t ready yet: {0}.' -f (($left | ForEach-Object { $_.Message }) -join '; '))
    }
    Write-DemoVmLog -Message ('The Jumpstart guest passed the image checks: {0}, SQL Server {1} {2} as {3}.' -f $fact.osCaption, $fact.sqlEdition, $fact.sqlVersion, $Context.GuestName)
}

function Get-DemoJumpstartHealthDetail {
    # The image's records for health.json: the download's identity and the first boot's outcome. No secret.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Context
    )

    $paths = Get-DemoJumpstartPath -Context $Context
    $image = Read-DemoVmJsonFile -Path $paths.Image
    $firstBoot = Read-DemoVmJsonFile -Path $paths.FirstBoot
    $detail = [ordered]@{}
    if ($null -ne $image) {
        $detail.image = [ordered]@{ etag = $image['etag']; lastModified = $image['lastModified']; sizeBytes = $image['sizeBytes']; sha256 = $image['sha256']; md5Verified = $image['md5Verified']; pinned = $image['pinned']; verifiedUtc = $image['verifiedUtc'] }
    }
    if ($null -ne $firstBoot) {
        $detail.firstBoot = [ordered]@{ completedUtc = $firstBoot['completedUtc']; oldComputerName = $firstBoot['oldComputerName']; oldServerName = $firstBoot['oldServerName']; databasesDropped = $firstBoot['databasesDropped']; uninstall = $firstBoot['uninstall']; warnings = $firstBoot['warnings'] }
    }
    return $detail
}
