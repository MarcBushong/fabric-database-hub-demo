function Sync-DemoFabricAppStage {
    <#
    .SYNOPSIS
    Copies the Fabric App source (fabric/app) into its Git-ignored deploy stage (out/fabric-app), writes the
    deploy-time values, and installs the pinned packages (FABRIC.APP.STAGE, FABRIC.APP.DEPENDENCIES).

    .DESCRIPTION
    The Rayfin CLI deploys from a project folder and writes its deployment record there (rayfin/.deployments.json,
    rayfin/.env, .env.local). Keeping that folder under out/ keeps every real ID out of Git. Each run:
    1. Mirrors the source into the stage: copies every file except build output, packages, and local files, and
       removes stage files the source no longer has. The CLI's own files (rayfin/.deployments.json, rayfin/.env,
       .env.local, rayfin/.temp) and node_modules stay.
    2. Sets the connector's IDs in rayfin/.env (-EnvValues; rayfin.yml reads them as ${NAME}, so the committed file
       holds only placeholders) and writes public/dbhub-app.json (-DeployFile: the live links and the expected
       account, which the app reads at run time).
    3. Runs npm ci when package-lock.json changed since the last install, so the stage always runs the CLI and SDK
       versions the lock file pins.
    Sources: https://learn.microsoft.com/fabric/apps/project-structure, https://learn.microsoft.com/fabric/apps/cli-reference

    .PARAMETER SourcePath
    The app's source folder (fabric/app).

    .PARAMETER StagePath
    The deploy stage (out/fabric-app). Created when it doesn't exist.

    .PARAMETER EnvValues
    KEY=value pairs for rayfin/.env, for example DBHUB_FABRIC_WORKSPACE_ID and DBHUB_SEMANTIC_MODEL_ID.

    .PARAMETER DeployFile
    The content of public/dbhub-app.json: links (databaseHub, realTimeDashboard, report, workspace),
    expectedAccount, and expectedTenantId.

    .PARAMETER SkipInstall
    Don't run npm ci (the dependencies result is Not selected).

    .PARAMETER TimeoutSeconds
    How long npm ci may run.

    .EXAMPLE
    Sync-DemoFabricAppStage -SourcePath ./fabric/app -StagePath ./out/fabric-app -EnvValues @{ DBHUB_SEMANTIC_MODEL_ID = $id } -DeployFile $links
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $StagePath,

        [System.Collections.IDictionary] $EnvValues = @{},

        [System.Collections.IDictionary] $DeployFile = @{},

        [switch] $SkipInstall,

        [ValidateRange(60, 7200)]
        [int] $TimeoutSeconds = 1200
    )

    $docUrl = 'https://learn.microsoft.com/fabric/apps/project-structure'
    $source = Resolve-DemoUserPath -Path $SourcePath
    $stage = Resolve-DemoUserPath -Path $StagePath
    $results = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath (Join-Path -Path $source -ChildPath 'rayfin/rayfin.yml') -PathType Leaf)) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.STAGE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} isn''t a Fabric Apps project: rayfin/rayfin.yml is missing.' -f $SourcePath) -DocUrl $docUrl))
        return $results.ToArray()
    }

    # Paths relative to the project root, with forward slashes. Never copied from the source, never removed from the stage.
    $keep = '^(node_modules|dist|coverage|\.vite|rayfin/\.temp)(/|$)|^(\.env|\.env\..*|rayfin/\.env|rayfin/\.env\..*|rayfin/\.deployments\.json|public/rayfin\.config\.json|public/dbhub-app\.json)$'
    $relativeOf = {
        param([string] $Root, [string] $Path)
        return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
    }
    # Walks a project without entering the kept folders (node_modules alone has thousands of files).
    $walk = {
        param([string] $Root)
        $pending = [System.Collections.Generic.Stack[string]]::new()
        $pending.Push($Root)
        while ($pending.Count -gt 0) {
            foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                if ((& $relativeOf $Root $item.FullName) -match $keep) {
                    continue
                }
                if ($item.PSIsContainer) {
                    $pending.Push($item.FullName)
                }
                $item
            }
        }
    }
    $sourceFiles = @(& $walk $source | Where-Object { -not $_.PSIsContainer })
    $relativeSource = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $sourceFiles) {
        [void]$relativeSource.Add((& $relativeOf $source $file.FullName))
    }

    if (-not $PSCmdlet.ShouldProcess($stage, ('Mirror {0} files from {1}, write the deploy-time values, and run npm ci when the lock file changed' -f $sourceFiles.Count, $source))) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.STAGE' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message ('Planned: mirror {0} files into {1} and write rayfin/.env and public/dbhub-app.json.' -f $sourceFiles.Count, $StagePath) -Evidence @{ files = $sourceFiles.Count } -DocUrl $docUrl))
        return $results.ToArray()
    }

    $copied = 0
    $removed = 0
    try {
        $null = New-Item -ItemType Directory -Path $stage -Force
        foreach ($file in $sourceFiles) {
            $relative = & $relativeOf $source $file.FullName
            $target = Join-Path -Path $stage -ChildPath $relative
            $targetDir = Split-Path -Path $target -Parent
            if (-not (Test-Path -LiteralPath $targetDir)) {
                $null = New-Item -ItemType Directory -Path $targetDir -Force
            }
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-DemoFabricAppFileHash -Path $target) -ne (Get-DemoFabricAppFileHash -Path $file.FullName)) {
                Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                $copied++
            }
        }
        $stageItems = @(& $walk $stage)
        foreach ($file in @($stageItems | Where-Object { -not $_.PSIsContainer -and -not $relativeSource.Contains((& $relativeOf $stage $_.FullName)) })) {
            Remove-Item -LiteralPath $file.FullName -Force
            $removed++
        }
        $stageItems | Where-Object { $_.PSIsContainer } |
            Sort-Object -Property { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

        if ($EnvValues.Count -gt 0) {
            Set-DemoFabricAppEnvValue -Path (Join-Path -Path $stage -ChildPath 'rayfin/.env') -Values $EnvValues -Confirm:$false
        }
        $deployPath = Join-Path -Path $stage -ChildPath 'public/dbhub-app.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $deployPath -Parent) -Force
        [System.IO.File]::WriteAllText($deployPath, (($DeployFile | ConvertTo-Json -Depth 5) + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.STAGE' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The deploy stage {0} couldn''t be updated: {1}' -f $StagePath, $_.Exception.Message) -Remediation 'Close any program that holds files in the stage (an editor or a dev server), then run the script again.' -DocUrl $docUrl))
        return $results.ToArray()
    }
    $evidence = [ordered]@{ files = $sourceFiles.Count; copied = $copied; removed = $removed; envValues = @($EnvValues.Keys | Sort-Object); deployFileLinks = @(if ($DeployFile['links']) { $DeployFile['links'].Keys | Sort-Object }) }
    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.STAGE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('The deploy stage {0} matches fabric/app ({1} files; {2} copied, {3} removed) and has the deploy-time values.' -f $StagePath, $sourceFiles.Count, $copied, $removed) -Evidence $evidence -DocUrl $docUrl))

    # Dependencies: npm ci when the lock file changed since the last successful install.
    $installDoc = 'https://docs.npmjs.com/cli/commands/npm-ci'
    if ($SkipInstall) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPENDENCIES' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'Skipped (-SkipInstall); the stage keeps the packages it has.' -DocUrl $installDoc))
        return $results.ToArray()
    }
    $lockHash = Get-DemoFabricAppFileHash -Path (Join-Path -Path $stage -ChildPath 'package-lock.json')
    $marker = Join-Path -Path $stage -ChildPath 'node_modules/.dbhub-lock.sha256'
    $installed = if (Test-Path -LiteralPath $marker -PathType Leaf) { (Get-Content -LiteralPath $marker -Raw).Trim() } else { '' }
    if ($installed -eq $lockHash -and (Get-DemoRayfinCliPath -StagePath $stage)) {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPENDENCIES' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'The stage''s packages already match package-lock.json.' -Evidence @{ lockSha256 = $lockHash; installed = $false } -DocUrl $installDoc))
        return $results.ToArray()
    }
    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $install = Invoke-DemoFabricAppProcess -Tool 'npm' -ArgumentList @('ci', '--no-audit', '--no-fund', '--loglevel=error') -WorkingDirectory $stage -TimeoutSeconds $TimeoutSeconds
    $seconds = [int]$started.Elapsed.TotalSeconds
    if ($install.ExitCode -ne 0 -or -not (Get-DemoRayfinCliPath -StagePath $stage)) {
        $detail = (@($install.StdErr, $install.StdOut) | Where-Object { $_ } | Select-Object -First 1)
        if ($detail.Length -gt 600) {
            $detail = $detail.Substring(0, 600)
        }
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPENDENCIES' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('npm ci failed in the stage (exit code {0}, {1} s): {2}' -f $install.ExitCode, $seconds, $detail) -Evidence @{ exitCode = $install.ExitCode; seconds = $seconds } -Remediation ('Check that Node.js {0} and npm can reach your npm registry, then run the script again.' -f ((Get-DemoFabricAppSetting)['supportedNodeMajors'] -join ', ')) -DocUrl $installDoc))
        return $results.ToArray()
    }
    [System.IO.File]::WriteAllText($marker, $lockHash, [System.Text.UTF8Encoding]::new($false))
    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.DEPENDENCIES' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('npm ci installed the pinned packages in {0} s.' -f $seconds) -Evidence @{ lockSha256 = $lockHash; installed = $true; seconds = $seconds } -DocUrl $installDoc))
    return $results.ToArray()
}
