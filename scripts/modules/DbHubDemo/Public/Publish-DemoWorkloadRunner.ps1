function Publish-DemoWorkloadRunner {
    <#
    .SYNOPSIS
    Builds the ContosoCare.Workload runner for the VMs and zips it deterministically (ADR 0010).

    .DESCRIPTION
    Runs 'dotnet publish' of workload-generator/src/ContosoCare.Workload with the settings Phase 11 documents:
    Release, runtime identifier win-x64 (config/versions.json workloadRunner.publishRuntimeIdentifier),
    framework-dependent (--self-contained false), English resources only, and without the Windows broker's
    native runtime, with locked-mode restore, and without a program database (-p:DebugType=none). The VMs run
    it with the pinned .NET runtime zip (config/versions.json dotnetRuntime), which they download from Microsoft
    and check against its SHA-512.

    The same source builds the same runner in any checkout (live, 2026-10-22): a program database's Source Link
    data holds the checkout's path and the commit, and the assembly records the program database's checksum, so
    none is built; workload-generator/Directory.Build.props maps the checkout's path and keeps the commit out of
    the informational version.

    The publish output goes into a zip with sorted entries, forward slashes, and a fixed timestamp, plus
    runner-manifest.json (version, runtime identifier, SDK, source hash, and every file's SHA-256). Program
    database files (*.pdb) are left out if any appear: they hold build paths and the runner never needs them.
    The zip is named after a hash of the runner's inputs (source, package pins, global.json, the embedded
    scenarios and T-SQL, the runtime identifier, the SDK pin, and the publish properties): when a zip with the
    same name exists, it's reused, so 'deploy.ps1 -Resume' keeps the same runner SHA-256. -Force builds again.

    Send-DemoWorkloadRunner delivers the zip to the VMs in SHA-256-checked Run Command chunks, and the
    template passes its SHA-256 and chunk count to the bootstraps (Get-DemoDeploymentParameter).

    Returns Path, Sha256, SizeBytes, FileName, Version, RuntimeIdentifier, SourceSha256, FileCount, and Reused.

    Sources (checked 2026-10-20):
    - dotnet publish: https://learn.microsoft.com/dotnet/core/tools/dotnet-publish
    - Framework-dependent deployment: https://learn.microsoft.com/dotnet/core/deploying/
    - PathMap (checked 2026-10-22): https://learn.microsoft.com/dotnet/csharp/language-reference/compiler-options/advanced#pathmap
    - DebugType (checked 2026-10-22): https://learn.microsoft.com/dotnet/csharp/language-reference/compiler-options/code-generation#debugtype

    .PARAMETER OutputDirectory
    Where to write the zip. Defaults to out/runner, which Git ignores.

    .PARAMETER RepositoryRoot
    Repository to build. Defaults to this repository.

    .PARAMETER Force
    Build again even when a zip for the same inputs exists.

    .EXAMPLE
    $runner = Publish-DemoWorkloadRunner
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string] $OutputDirectory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/runner'),

        [string] $RepositoryRoot = $script:RepoRoot,

        [switch] $Force
    )

    $root = Resolve-DemoUserPath -Path $RepositoryRoot
    $output = Resolve-DemoUserPath -Path $OutputDirectory
    $versions = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $pins = $versions['workloadRunner']
    if ($null -eq $pins) {
        throw 'config/versions.json has no workloadRunner entry.'
    }
    $version = [string]$pins['version']
    $rid = [string]$pins['publishRuntimeIdentifier']
    $sdk = [string]$versions['tools']['dotnetSdk']
    if ($version -notmatch '^\d+\.\d+\.\d+$' -or $rid -notmatch '^[a-z0-9-]+$') {
        throw 'config/versions.json workloadRunner needs a version (x.y.z) and a publishRuntimeIdentifier.'
    }
    $project = Join-Path -Path $root -ChildPath 'workload-generator/src/ContosoCare.Workload/ContosoCare.Workload.csproj'
    if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
        throw "The runner project $project doesn't exist."
    }

    $publishProperties = @('-p:RestoreLockedMode=true', '-p:DebugType=none')
    $sourceSha256 = Get-DemoWorkloadSourceHash -RepositoryRoot $root -RuntimeIdentifier $rid -SdkVersion $sdk -BuildProperty $publishProperties
    $fileName = 'contosocare-workload-{0}-{1}-{2}.zip' -f $version, $rid, $sourceSha256.Substring(0, 12)
    $zipPath = Join-Path -Path $output -ChildPath $fileName
    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    if (-not $Force -and (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        $manifest = $null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entry = $archive.GetEntry('runner-manifest.json')
            if ($null -ne $entry) {
                $reader = [System.IO.StreamReader]::new($entry.Open())
                try {
                    $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                }
                finally {
                    $reader.Dispose()
                }
            }
            $count = @($archive.Entries).Count - 1
        }
        finally {
            $archive.Dispose()
        }
        if ($null -ne $manifest -and [string]$manifest['sourceSha256'] -eq $sourceSha256) {
            Write-DemoLog -Message ('Reusing the workload runner {0}: its inputs are unchanged.' -f $fileName)
            return [pscustomobject]@{
                Path              = $zipPath
                Sha256            = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
                SizeBytes         = (Get-Item -LiteralPath $zipPath).Length
                FileName          = $fileName
                Version           = $version
                RuntimeIdentifier = $rid
                SourceSha256      = $sourceSha256
                FileCount         = $count
                Reused            = $true
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($zipPath, "Publish the workload runner for $rid and zip it")) {
        return
    }
    if (-not (Test-Path -LiteralPath $output)) {
        New-Item -ItemType Directory -Path $output -Force | Out-Null
    }
    $staging = Join-Path -Path $output -ChildPath ('publish-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $arguments = @('publish', $project, '--configuration', 'Release', '--runtime', $rid, '--self-contained', 'false', '--output', $staging) + $publishProperties + @('--nologo')
        Write-DemoLog -Message ('Publishing the workload runner {0} for {1} (framework-dependent).' -f $version, $rid)
        $build = Invoke-DemoDotNet -ArgumentList $arguments -WorkingDirectory (Join-Path -Path $root -ChildPath 'workload-generator')
        if ($build.ExitCode -ne 0) {
            $detail = (([string]$build.StdOut) + "`n" + ([string]$build.StdErr)).Trim()
            if ($detail.Length -gt 1500) {
                $detail = $detail.Substring($detail.Length - 1500)
            }
            throw ('dotnet publish failed with exit code {0}: {1}' -f $build.ExitCode, $detail)
        }
        foreach ($required in 'ContosoCare.Workload.dll', 'ContosoCare.Workload.runtimeconfig.json', 'ContosoCare.Workload.deps.json') {
            if (-not (Test-Path -LiteralPath (Join-Path -Path $staging -ChildPath $required) -PathType Leaf)) {
                throw "dotnet publish produced no $required."
            }
        }

        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
            if ($file.Extension -eq '.pdb') {
                continue
            }
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $entries.Add([pscustomobject]@{
                    Path   = [System.IO.Path]::GetRelativePath($staging, $file.FullName).Replace('\', '/')
                    Bytes  = $bytes
                    Sha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                })
        }
        $entries.Sort([System.Comparison[object]] { param($left, $right) [string]::CompareOrdinal($left.Path, $right.Path) })
        $manifest = [ordered]@{
            schemaVersion     = 1
            name              = 'ContosoCare.Workload'
            version           = $version
            runtimeIdentifier = $rid
            targetFramework   = [string]$pins['targetFramework']
            sdkVersion        = $sdk
            sourceSha256      = $sourceSha256
            entryPoint        = 'ContosoCare.Workload.dll'
            files             = @($entries | ForEach-Object { [ordered]@{ path = $_.Path; sha256 = $_.Sha256; size = $_.Bytes.Length } })
        }
        $manifestBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 10).Replace("`r`n", "`n"))

        $timestamp = [System.DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
        $temporary = '{0}.{1}.tmp' -f $zipPath, [guid]::NewGuid().ToString('N')
        $stream = [System.IO.File]::Create($temporary)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $all = @([pscustomobject]@{ Path = 'runner-manifest.json'; Bytes = $manifestBytes }) + @($entries)
                foreach ($item in $all) {
                    $zipEntry = $archive.CreateEntry($item.Path, [System.IO.Compression.CompressionLevel]::Optimal)
                    $zipEntry.LastWriteTime = $timestamp
                    $entryStream = $zipEntry.Open()
                    try {
                        $entryStream.Write($item.Bytes, 0, $item.Bytes.Length)
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
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $size = (Get-Item -LiteralPath $zipPath).Length
    Write-DemoLog -Level Success -Message ('Workload runner {0}: {1} files, {2:N0} bytes, SHA-256 {3}.' -f $fileName, $entries.Count, $size, $sha256.Substring(0, 12))
    [pscustomobject]@{
        Path              = $zipPath
        Sha256            = $sha256
        SizeBytes         = $size
        FileName          = $fileName
        Version           = $version
        RuntimeIdentifier = $rid
        SourceSha256      = $sourceSha256
        FileCount         = $entries.Count
        Reused            = $false
    }
}
