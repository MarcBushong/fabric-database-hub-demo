function New-DemoBootstrapBundle {
    <#
    .SYNOPSIS
    Builds the versioned bootstrap bundle that Send-DemoBootstrapBundle delivers to the VMs in Run Command
    chunks (ADR 0001, ADR 0003).

    .DESCRIPTION
    Pure: it reads the repository and writes one zip, with no Azure calls. The zip holds vm/ and database/
    (Markdown files are left out) plus bundle-manifest.json, which lists every file's SHA-256 and carries
    the media pins and the .NET runtime pin (dotnetRuntime) from config/versions.json; the T2 host verifies
    media against them and fails closed, and the WorkloadRunner steps check the runtime's SHA-512.
    Entries are sorted, use forward slashes, and have a fixed timestamp, so the same content produces the
    same zip and the same SHA-256, and an unchanged bundle doesn't re-run the bootstrap. Nothing in it is
    secret: the VMs get settings as Run Command parameters, and secrets never travel in the bundle
    (New-DemoBootstrapChunk checks).

    Returns Path, Sha256 (of the zip), Version, ContentSha256 (of the file list), FileCount, SizeBytes,
    and FileName.

    .PARAMETER OutputDirectory
    Where to write the zip. Defaults to out/bundle, which Git ignores.

    .PARAMETER RepositoryRoot
    Repository to bundle. Defaults to this repository.

    .EXAMPLE
    $bundle = New-DemoBootstrapBundle
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $OutputDirectory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/bundle'),

        [string] $RepositoryRoot = $script:RepoRoot
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    Add-Type -AssemblyName 'System.IO.Compression'
    $version = [string]$MyInvocation.MyCommand.Module.Version
    $sources = foreach ($folder in @('vm', 'database')) {
        $path = Join-Path -Path $root -ChildPath $folder
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "The bundle source folder $folder is missing under $root."
        }
        Get-ChildItem -LiteralPath $path -Recurse -File | Where-Object { $_.Extension -ne '.md' }
    }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $sources) {
        $ordered.Add([pscustomobject]@{
                Path     = [System.IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
                FullName = $item.FullName
            })
    }
    # Ordinal order, so the zip is identical on every OS and culture.
    $ordered.Sort([System.Comparison[object]] { param($left, $right) [string]::CompareOrdinal($left.Path, $right.Path) })

    $entries = foreach ($file in $ordered) {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        [pscustomobject]@{
            Path   = $file.Path
            Bytes  = $bytes
            Sha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
    }
    $listing = ($entries | ForEach-Object { '{0}  {1}' -f $_.Sha256, $_.Path }) -join "`n"
    $contentSha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($listing))).ToLowerInvariant()

    $versions = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $media = [ordered]@{}
    if ($versions.ContainsKey('media')) {
        foreach ($name in ($versions.media.Keys | Where-Object { $_ -ne 'note' } | Sort-Object)) {
            $media[$name] = $versions.media[$name]
        }
    }
    # The .NET runtime pin for the workload runner (ADR 0010): the VMs download it and check its SHA-512.
    $dotnetRuntime = $null
    if ($versions.ContainsKey('dotnetRuntime')) {
        $dotnetRuntime = [ordered]@{}
        foreach ($name in ($versions.dotnetRuntime.Keys | Where-Object { $_ -ne 'note' } | Sort-Object)) {
            $dotnetRuntime[$name] = $versions.dotnetRuntime[$name]
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        name          = 'dbhub-demo-bootstrap'
        version       = $version
        contentSha256 = $contentSha256
        files         = @($entries | ForEach-Object { [ordered]@{ path = $_.Path; sha256 = $_.Sha256; size = $_.Bytes.Length } })
        media         = $media
        dotnetRuntime = $dotnetRuntime
    }
    $manifestBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 10).Replace("`r`n", "`n"))

    $fileName = 'dbhub-bootstrap-{0}-{1}.zip' -f $version, $contentSha256.Substring(0, 12)
    $zipPath = Join-Path -Path ([System.IO.Path]::GetFullPath($OutputDirectory)) -ChildPath $fileName
    if (-not $PSCmdlet.ShouldProcess($zipPath, 'Create the bootstrap bundle')) {
        return
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $timestamp = [System.DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
    $temporary = '{0}.{1}.tmp' -f $zipPath, [guid]::NewGuid().ToString('N')
    $stream = [System.IO.File]::Create($temporary)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $all = @([pscustomobject]@{ Path = 'bundle-manifest.json'; Bytes = $manifestBytes }) + @($entries)
            foreach ($entry in $all) {
                $zipEntry = $archive.CreateEntry($entry.Path, [System.IO.Compression.CompressionLevel]::Optimal)
                $zipEntry.LastWriteTime = $timestamp
                $entryStream = $zipEntry.Open()
                try {
                    $entryStream.Write($entry.Bytes, 0, $entry.Bytes.Length)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    Move-Item -LiteralPath $temporary -Destination $zipPath -Force

    $sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject]@{
        Path          = $zipPath
        Sha256        = $sha256
        Version       = $version
        ContentSha256 = $contentSha256
        FileCount     = @($entries).Count
        SizeBytes     = (Get-Item -LiteralPath $zipPath).Length
        FileName      = $fileName
    }
}
