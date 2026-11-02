function Test-DemoFabricApp {
    <#
    .SYNOPSIS
    Checks the deployed Fabric App: every DAX query the app runs returns data through its semantic model connector,
    its hosted assets refuse anonymous requests, and the browser check that only a person can do
    (FABRIC.APP.CONNECTOR, FABRIC.APP.QUERIES, FABRIC.APP.HOSTING, FABRIC.APP.BROWSER).

    .DESCRIPTION
    1. Connector: 'npm run queries:export' writes the app's own DAX catalog (fabric/app/src/data/queries.ts) as
       connector payloads, and each one runs with
         rayfin connector invoke --name history --operation executeQuery --file <payload> --json
       (https://learn.microsoft.com/fabric/apps/connectors, https://learn.microsoft.com/fabric/apps/cli-reference).
       The CLI runs the query as the signed-in operator (delegated, the access every viewer needs too); the deployed
       transport needs an app session the CLI can't create yet, so the in-app path is the browser check. The
       connector check (one row with the validation, snapshot, and incident counts) must return a row: Pass;
       FABRIC.APP.QUERIES is a Pass when every query runs, a Warning when some return no rows (history not captured
       yet for that window), and a Fail when the model rejects one.
    2. Hosting: an anonymous GET of the hosted app with Accept: application/json must be refused (HTTP 401), because
       rayfin.yml sets staticHosting.assetAccess to protected (https://learn.microsoft.com/fabric/apps/hosting).
       HTTP 200 with app content would mean public assets: Fail.
    3. Browser: Manual action required. Open the app from its item in the Fabric workspace (the supported entry
       point: it runs embedded and signs in with initEmbeddedAuth, https://learn.microsoft.com/fabric/apps/fabric-authentication)
       and confirm the Live links page shows the connector check. Opening the hosted URL directly is a known preview
       limitation: the sign-in pop-up stops at "Page not accessible directly".

    .PARAMETER StagePath
    The deploy stage (out/fabric-app) with the pinned CLI installed.

    .PARAMETER HostingUrl
    The hosted app's URL from the deployment (FABRIC.APP.DEPLOY evidence).

    .PARAMETER ItemUrl
    The app item's page in the Fabric portal, for the browser steps.

    .PARAMETER Queries
    All runs the whole catalog (14 queries); Probe runs only the connector check.

    .PARAMETER TimeoutSeconds
    How long each connector call may run.

    .EXAMPLE
    Test-DemoFabricApp -StagePath ./out/fabric-app -HostingUrl $hosting -ItemUrl $item
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $StagePath,

        [AllowEmptyString()]
        [string] $HostingUrl = '',

        [AllowEmptyString()]
        [string] $ItemUrl = '',

        [ValidateSet('All', 'Probe')]
        [string] $Queries = 'All',

        [ValidateRange(30, 1800)]
        [int] $TimeoutSeconds = 300
    )

    $settings = Get-DemoFabricAppSetting
    $connector = [string]$settings['connectorName']
    $connectorDoc = 'https://learn.microsoft.com/fabric/apps/connectors'
    $results = [System.Collections.Generic.List[object]]::new()
    $stage = Resolve-DemoUserPath -Path $StagePath
    $queryFolder = 'rayfin/.temp/dbhub-queries'
    $callTimeout = $TimeoutSeconds
    if (-not $HostingUrl -or -not $ItemUrl) {
        # Without a deploy in this run, the stage's deployment record has both.
        $record = Get-DemoFabricAppDeploymentRecord -StagePath $stage
        if ($record) {
            if (-not $HostingUrl) {
                $HostingUrl = $record.HostingUrl
            }
            if (-not $ItemUrl) {
                $ItemUrl = $record.ItemUrl
            }
        }
    }

    # Every query is a payload file inside the project, which is where the CLI accepts --file.
    $export = {
        param([string] $Day, [string[]] $Anchor = @())
        $arguments = @('run', 'queries:export', '--', $queryFolder)
        if ($Day) {
            # The newest telemetry day, then history-meta's anchors for the T3 replay (--t3-incident-start <instant> ...).
            $arguments += $Day
            $arguments += @($Anchor)
        }
        $run = Invoke-DemoFabricAppProcess -Tool 'npm' -ArgumentList $arguments -WorkingDirectory $stage -TimeoutSeconds 300
        $indexPath = Join-Path -Path $stage -ChildPath ($queryFolder + '/index.json')
        if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
            throw ('npm run queries:export failed (exit code {0}): {1}' -f $run.ExitCode, (@($run.StdErr, $run.StdOut) | Where-Object { $_ } | Select-Object -First 1))
        }
        return (Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -AsHashtable)
    }
    $invoke = {
        param([string] $File)
        $call = Invoke-DemoRayfinCli -StagePath $stage -ArgumentList @('connector', 'invoke', '--name', $connector, '--operation', 'executeQuery', '--file', ($queryFolder + '/' + $File), '--max-inline-bytes', '0', '--json') -TimeoutSeconds $callTimeout
        $data = $call.Data
        $output = if ($data -and $data['output'] -is [System.Collections.IDictionary]) { $data['output'] } else { @{} }
        $table = if ($output['table'] -is [System.Collections.IDictionary]) { $output['table'] } else { @{} }
        $rows = @(if ($table['rows']) { $table['rows'] })
        $columns = @(if ($table['columns']) { $table['columns'] | ForEach-Object { [string]$_['name'] -replace '^.*\[([^\]]+)\]$', '$1' } })
        $failure = ''
        if (-not $data -or [string]$data['status'] -ne 'ok' -or [string]$output['status'] -ne 'success') {
            $failure = if ($output['error'] -is [System.Collections.IDictionary]) { '{0}: {1}' -f $output['error']['category'], $output['error']['message'] }
            elseif ($data -and $data['error']) { [string]$data['error'] }
            elseif ($call.ExitCode -eq -1) { [string]$call.StdErr }
            else { 'exit code {0}: {1}' -f $call.ExitCode, (@($call.StdErr, $call.StdOut) | Where-Object { $_ } | Select-Object -First 1) }
        }
        [pscustomobject]@{ Ok = -not $failure; Rows = $rows; Columns = $columns; Error = $failure }
    }

    try {
        $index = & $export ''
        $probeEntry = @($index['queries']) | Where-Object { $_['id'] -eq 'connector-check' } | Select-Object -First 1
        $probe = & $invoke ([string]$probeEntry['file'])
        if ($probe.Ok -and $probe.Rows.Count -gt 0) {
            $values = @{}
            for ($i = 0; $i -lt $probe.Columns.Count; $i++) {
                $values[$probe.Columns[$i]] = @($probe.Rows[0])[$i]
            }
            # COUNTROWS over an empty table is blank in DAX, which a new lakehouse has until a notebook writes rows.
            $count = { param($Value) if ($null -eq $Value -or [string]$Value -eq '') { 0 } else { $Value } }
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('Connector check passed: the {0} connector returned {1} validation checks, {2} telemetry rows, and {3} incident windows from {4}.' -f $connector, (& $count $values['ValidationRows']), (& $count $values['SnapshotRows']), (& $count $values['Incidents']), $settings['semanticModelName']) -Evidence ([ordered]@{ connector = $connector; row = $values }) -DocUrl $connectorDoc))
        }
        else {
            $why = if ($probe.Error) { $probe.Error } else { 'the query returned no rows' }
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The {0} connector didn''t return the connector check: {1}' -f $connector, $why) -Evidence @{ connector = $connector } -Remediation ('The signed-in user needs Read and Build on {0}; check that the model is deployed and refreshed (configure-powerbi.ps1 -CheckModelData).' -f $settings['semanticModelName']) -DocUrl $connectorDoc))
        }

        if ($Queries -eq 'All' -and $probe.Ok) {
            # Anchor the catalog to the newest telemetry day, as the app does, so every window has data to return.
            $metaEntry = @($index['queries']) | Where-Object { $_['id'] -eq 'history-meta' } | Select-Object -First 1
            $meta = & $invoke ([string]$metaEntry['file'])
            $latestDay = ''
            $anchors = [System.Collections.Generic.List[string]]::new()
            if ($meta.Ok -and $meta.Rows.Count -gt 0) {
                $position = [array]::IndexOf([string[]]$meta.Columns, 'LatestDay')
                if ($position -ge 0) {
                    # ConvertFrom-Json turns ISO date text into DateTime; the model's dates have no zone (UTC).
                    $value = @($meta.Rows[0])[$position]
                    if ($value -is [datetime]) {
                        $day = if ($value.Kind -eq [System.DateTimeKind]::Local) { $value.ToUniversalTime() } else { $value }
                        $latestDay = $day.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    elseif ([string]$value -match '^(\d{4}-\d{2}-\d{2})') {
                        $latestDay = $Matches[1]
                    }
                }
                # The newest T3 incident window and T3's newest bin anchor the T3 replay to bins that exist (Phase 25b:
                # the range used to end at midnight at the start of the newest day, so replay-T3 and spotlight-T3 were empty).
                $anchorColumns = [ordered]@{ T3IncidentStart = '--t3-incident-start'; T3IncidentEnd = '--t3-incident-end'; T3LatestBucket = '--t3-latest-bucket' }
                foreach ($column in $anchorColumns.GetEnumerator()) {
                    $position = [array]::IndexOf([string[]]$meta.Columns, $column.Key)
                    $instant = if ($position -ge 0) { ConvertTo-DemoFabricAppInstant -Value (@($meta.Rows[0])[$position]) } else { '' }
                    if ($instant) {
                        $anchors.Add($column.Value)
                        $anchors.Add($instant)
                    }
                }
            }
            if ($latestDay) {
                $index = & $export $latestDay $anchors.ToArray()
            }
            $outcomes = foreach ($entry in @($index['queries'])) {
                $id = [string]$entry['id']
                $outcome = if ($id -eq 'connector-check') { $probe } elseif ($id -eq 'history-meta') { $meta } else { & $invoke ([string]$entry['file']) }
                [pscustomobject]@{ Id = $id; Ok = $outcome.Ok; Rows = $outcome.Rows.Count; Error = $outcome.Error }
            }
            $failed = @($outcomes | Where-Object { -not $_.Ok })
            $empty = @($outcomes | Where-Object { $_.Ok -and $_.Rows -eq 0 })
            $evidence = [ordered]@{ latestDay = $latestDay; incidentRange = $index['incidentRange']; queries = @($outcomes | ForEach-Object { [ordered]@{ id = $_.Id; rows = $_.Rows; ok = $_.Ok } }) }
            if ($failed.Count -gt 0) {
                $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} of {1} app queries failed: {2}' -f $failed.Count, $outcomes.Count, (($failed | ForEach-Object { '{0} ({1})' -f $_.Id, $_.Error }) -join '; ')) -Evidence $evidence -Remediation 'Compare the failing query (fabric/app/src/data/queries.ts) with the model''s TMDL; a renamed measure or column breaks it.' -DocUrl $connectorDoc))
            }
            elseif ($empty.Count -gt 0) {
                $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('All {0} app queries ran; {1} returned no rows for the newest telemetry day {2}: {3}.' -f $outcomes.Count, $empty.Count, $latestDay, (($empty | ForEach-Object { $_.Id }) -join ', ')) -Evidence $evidence -Remediation 'Run NB_DatabaseHub_LiveActivity (and a scenario) so the lakehouse has history for those visuals, then run the check again.' -DocUrl $connectorDoc))
            }
            else {
                $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('All {0} app queries returned rows through the {1} connector (newest telemetry day {2}).' -f $outcomes.Count, $connector, $latestDay) -Evidence $evidence -DocUrl $connectorDoc))
            }
        }
        elseif ($Queries -eq 'All') {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The connector check failed, so the rest of the app''s queries weren''t run.' -DocUrl $connectorDoc))
        }
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The connector check couldn''t run: {0}' -f (Protect-DemoRayfinText -Text $_.Exception.Message)) -Remediation 'Run the script again without -SkipInstall so the stage has its packages.' -DocUrl $connectorDoc))
    }

    # Hosting: protected assets refuse anonymous requests.
    $hostingDoc = 'https://learn.microsoft.com/fabric/apps/hosting'
    if ($HostingUrl -notmatch '^https://[A-Za-z0-9.-]+(/.*)?$') {
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.HOSTING' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'No hosting URL is known for the app (no deployment in this run), so the protected-assets check didn''t run.' -DocUrl $hostingDoc))
    }
    else {
        $code = 0
        try {
            $response = Invoke-WebRequest -Uri $HostingUrl -Method Get -Headers @{ Accept = 'application/json' } -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60 -ErrorAction Stop
            $code = [int]$response.StatusCode
        }
        catch {
            $code = 0
        }
        $evidence = [ordered]@{ anonymousStatusCode = $code; assetAccess = [string]$settings['assetAccess'] }
        if ($code -eq 401 -or $code -eq 403) {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.HOSTING' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('The hosted app refuses anonymous requests (HTTP {0}): its assets are protected.' -f $code) -Evidence $evidence -DocUrl $hostingDoc))
        }
        elseif ($code -eq 200) {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.HOSTING' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'The hosted app answered an anonymous request (HTTP 200): its assets are public.' -Evidence $evidence -Remediation 'Set services.staticHosting.assetAccess to protected in fabric/app/rayfin/rayfin.yml and redeploy.' -DocUrl $hostingDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.HOSTING' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The hosted app answered an anonymous request with HTTP {0}, so protection couldn''t be confirmed.' -f $code) -Evidence $evidence -Remediation 'Run the script with -CheckOnly again in a few minutes.' -DocUrl $hostingDoc))
        }
    }

    $where = if ($ItemUrl) { 'its item page ({0})' -f $ItemUrl } else { 'the demo workspace, then select the item {0}' -f $settings['itemName'] }
    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'A person must confirm the app in the browser: sign-in and the connector in the app can''t be checked from a script.' -Evidence @{ entryPoint = 'workspace item page (embedded)' } -Remediation ('In the Fabric portal, signed in as a user with access to the workspace, open {0}. The app opens embedded and signs in by itself. On Live links it shows "Connector check passed" with the validation, telemetry, and incident counts. Don''t open the hosted URL directly: that is a known preview limitation (the sign-in pop-up stops at "Page not accessible directly").' -f $where) -DocUrl 'https://learn.microsoft.com/fabric/apps/fabric-authentication'))
    return $results.ToArray()
}
