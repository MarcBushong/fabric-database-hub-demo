function Test-DemoFabricApp {
    <#
    .SYNOPSIS
    Checks the deployed Fabric App: every DAX query the app runs returns data from its semantic model under the
    operator's identity, its hosted assets refuse anonymous requests, and whether a person still has to open it
    (FABRIC.APP.CONNECTOR, FABRIC.APP.QUERIES, FABRIC.APP.HOSTING, FABRIC.APP.BROWSER).

    .DESCRIPTION
    1. Queries: 'npm run queries:export' writes the app's own DAX catalog (fabric/app/src/data/queries.ts) as
       connector payloads ({ query, resultSetRowCountLimit }), and each one runs as the signed-in operator (delegated,
       the access every viewer needs too), by the first of these routes that takes the operator's token:
       - The connector's direct route, with the Azure CLI's Power BI token (-Token) as RAYFIN_TOKEN:
           rayfin connector invoke --name history --operation executeQuery --file <payload> --json
         (https://learn.microsoft.com/fabric/apps/connectors, https://learn.microsoft.com/fabric/apps/cli-reference),
         which calls Power BI's executeDaxQueries.
       - When that route refuses the token (live, 2026-11-09: HTTP 401 from executeDaxQueries for the Azure CLI's
         token, which 'rayfin up' had just accepted), Power BI's Execute Queries In Group with the same token
         (Invoke-DemoDaxQuery; https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group), for
         that query and every one after it. It runs one query per request and has no resultSetRowCountLimit, so the
         app's row bound is compared with each result here: over it, the app's connector fails the query (overflow).
         This isn't a refusal of the deploy's token: nothing is recorded for a later run (out/fabric-app-auth.json is
         only 'rayfin up''s'), and no browser opens.
       - The Rayfin CLI's own sign-in only with -RayfinSignIn, never as a fallback, so a run does the same whether or
         not this machine has a Rayfin sign-in. Without -Token and -RayfinSignIn, no query runs: FABRIC.APP.CONNECTOR
         is a Warning that says so.
       None of them crosses the deployed app's own route (its backend, then User Data Functions, then a delegated
       on-behalf-of call to the model: the CLI's own comment on 'connector invoke --transport'), which only opening the
       app exercises. The connector check (one row with the validation, snapshot, and incident counts) must return a
       row: Pass. FABRIC.APP.QUERIES is a Pass when every query returns rows, a Warning when some return no rows
       (history not captured yet for that window), and a Fail when the model rejects one or one is over its row bound.
       The evidence says which route ran each query (route: connector or executeQueries), whose sign-in (auth:
       azureCli or rayfinSignIn), and why the connector's route refused the token (connectorRefusal).
    2. Hosting: an anonymous GET of the hosted app with Accept: application/json must be refused (HTTP 401), because
       rayfin.yml sets staticHosting.assetAccess to protected (https://learn.microsoft.com/fabric/apps/hosting).
       HTTP 200 with app content would mean public assets: Fail.
    3. Browser: Not selected ("Not needed") when the connector check passed, every query the app runs ran
       (FABRIC.APP.QUERIES Pass or Warning), and the app is deployed: in this run (-Deployed), or its hosting answered
       (FABRIC.APP.HOSTING Pass); nobody needs to open the app to finish the deployment (2026-11-09, user-directed: no
       user steps). The note says exactly what was verified, and that the app's own route in the browser can't be
       checked from a script, with the link to open it. Otherwise Manual action required: open the app from its item
       in the Fabric workspace (the supported entry point: it runs embedded and signs in with initEmbeddedAuth,
       https://learn.microsoft.com/fabric/apps/fabric-authentication) and confirm the Live links page shows the
       connector check. Opening the hosted URL directly is a known preview limitation: the sign-in pop-up stops at
       "Page not accessible directly".

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

    .PARAMETER Token
    The Azure CLI's Power BI API token (Get-DemoPowerBIToken): 'rayfin connector invoke' gets it as RAYFIN_TOKEN, in
    that command's process only (Get-DemoRayfinTokenAudience), and when the connector's direct route refuses it,
    Execute Queries gets the same token (2026-11-09).

    .PARAMETER WorkspaceId
    The workspace that holds the semantic model, for Execute Queries. Without it, the stage's rayfin/.env
    (DBHUB_FABRIC_WORKSPACE_ID, which Sync-DemoFabricAppStage writes for the connector).

    .PARAMETER SemanticModelId
    The semantic model, for Execute Queries. Without it, the stage's rayfin/.env (DBHUB_SEMANTIC_MODEL_ID).

    .PARAMETER RayfinSignIn
    Run the queries through the connector with the Rayfin CLI's own sign-in, without a token, as before 2026-11-09
    (configure-fabric-app.ps1 -RayfinSignIn).

    .PARAMETER Deployed
    The app was deployed in this run (FABRIC.APP.DEPLOY Pass), for the browser check's note.

    .EXAMPLE
    Test-DemoFabricApp -StagePath ./out/fabric-app -HostingUrl $hosting -ItemUrl $item -Token (Get-DemoPowerBIToken -SubscriptionId $subscriptionId)
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
        [int] $TimeoutSeconds = 300,

        [securestring] $Token,

        [AllowEmptyString()]
        [string] $WorkspaceId = '',

        [AllowEmptyString()]
        [string] $SemanticModelId = '',

        [switch] $RayfinSignIn,

        [switch] $Deployed
    )

    $settings = Get-DemoFabricAppSetting
    $connector = [string]$settings['connectorName']
    $model = [string]$settings['semanticModelName']
    $connectorDoc = 'https://learn.microsoft.com/fabric/apps/connectors'
    $executeDoc = 'https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group'
    $results = [System.Collections.Generic.List[object]]::new()
    $stage = Resolve-DemoUserPath -Path $StagePath
    $queryFolder = 'rayfin/.temp/dbhub-queries'
    $callTimeout = $TimeoutSeconds
    # The IDs Execute Queries needs: the caller's, or those the stage's rayfin/.env gives the connector.
    if ($WorkspaceId -notmatch $script:GuidPattern -or $SemanticModelId -notmatch $script:GuidPattern) {
        $envFile = Join-Path -Path $stage -ChildPath 'rayfin/.env'
        $envLines = if (Test-Path -LiteralPath $envFile -PathType Leaf) { @(Get-Content -LiteralPath $envFile) } else { @() }
        foreach ($line in $envLines) {
            if ($WorkspaceId -notmatch $script:GuidPattern -and $line -match '^\s*DBHUB_FABRIC_WORKSPACE_ID\s*=\s*(\S+)\s*$') {
                $WorkspaceId = $Matches[1]
            }
            elseif ($SemanticModelId -notmatch $script:GuidPattern -and $line -match '^\s*DBHUB_SEMANTIC_MODEL_ID\s*=\s*(\S+)\s*$') {
                $SemanticModelId = $Matches[1]
            }
        }
    }
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
    # How each query runs (2026-11-09 live finding): the connector's direct route with the Azure CLI's Power BI token;
    # once that route refuses the token, Power BI's Execute Queries with the same token, which accepted it live, for that
    # query and every one after it; the Rayfin CLI's own sign-in only with -RayfinSignIn, never as a fallback.
    $route = @{ Name = ''; Refusal = '' }
    if ($RayfinSignIn) {
        $route.Name = 'rayfinSignIn'
    }
    elseif ($null -ne $Token) {
        $route.Name = 'connector'
    }
    $cli = {
        param([string] $File, [switch] $WithToken)
        $arguments = @('connector', 'invoke', '--name', $connector, '--operation', 'executeQuery', '--file', ($queryFolder + '/' + $File), '--max-inline-bytes', '0', '--json')
        if ($WithToken) {
            return (Invoke-DemoRayfinCli -StagePath $stage -ArgumentList $arguments -TimeoutSeconds $callTimeout -Token $Token -TokenAudience 'PowerBI')
        }
        return (Invoke-DemoRayfinCli -StagePath $stage -ArgumentList $arguments -TimeoutSeconds $callTimeout)
    }
    # A connector call's table, or why it failed.
    $fromCli = {
        param([object] $Call, [string] $Auth)
        $data = $Call.Data
        $output = if ($data -and $data['output'] -is [System.Collections.IDictionary]) { $data['output'] } else { @{} }
        $table = if ($output['table'] -is [System.Collections.IDictionary]) { $output['table'] } else { @{} }
        $rows = @(if ($table['rows']) { $table['rows'] })
        $columns = @(if ($table['columns']) { $table['columns'] | ForEach-Object { [string]$_['name'] -replace '^.*\[([^\]]+)\]$', '$1' } })
        $failure = ''
        if (-not $data -or [string]$data['status'] -ne 'ok' -or [string]$output['status'] -ne 'success') {
            $failure = if ($output['error'] -is [System.Collections.IDictionary]) { '{0}: {1}' -f $output['error']['category'], $output['error']['message'] }
            elseif ($data -and $data['error']) { [string]$data['error'] }
            elseif ($Call.ExitCode -eq -1) { [string]$Call.StdErr }
            else { 'exit code {0}: {1}' -f $Call.ExitCode, (@($Call.StdErr, $Call.StdOut) | Where-Object { $_ } | Select-Object -First 1) }
        }
        [pscustomobject]@{ Ok = -not $failure; Rows = $rows; Columns = $columns; Error = $failure; Route = 'connector'; Auth = $Auth; StatusCode = 0 }
    }
    # The same payload through Execute Queries In Group (one query per request, no row bound): its rows as the
    # connector gives them, columns in order, and the app's row bound compared here.
    $fromExecuteQueries = {
        param([string] $File)
        $outcome = [pscustomobject]@{ Ok = $false; Rows = @(); Columns = @(); Error = ''; Route = 'executeQueries'; Auth = 'azureCli'; StatusCode = 0 }
        if ($WorkspaceId -notmatch $script:GuidPattern -or $SemanticModelId -notmatch $script:GuidPattern) {
            $outcome.Error = 'the workspace and the semantic model aren''t known (-WorkspaceId and -SemanticModelId, or the stage''s rayfin/.env), so Execute Queries couldn''t run'
            return $outcome
        }
        try {
            $payload = Get-Content -LiteralPath (Join-Path -Path $stage -ChildPath ($queryFolder + '/' + $File)) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            $answer = Invoke-DemoDaxQuery -WorkspaceId $WorkspaceId -SemanticModelId $SemanticModelId -Query ([string]$payload['query']) -Token $Token
        }
        catch {
            $outcome.Error = Protect-DemoText -Text $_.Exception.Message
            return $outcome
        }
        $outcome.StatusCode = [int]$answer.StatusCode
        if ($answer.StatusCode -ne 200 -or $answer.Error) {
            $outcome.Error = [string]$answer.Error
            return $outcome
        }
        $found = @($answer.Rows)
        if ($found.Count -gt 0) {
            $first = $found[0]
            $names = @(if ($first -is [System.Collections.IDictionary]) { $first.Keys | ForEach-Object { [string]$_ } } else { $first.PSObject.Properties | ForEach-Object { $_.Name } })
            $outcome.Columns = @($names | ForEach-Object { $_ -replace '^.*\[([^\]]+)\]$', '$1' })
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in $found) {
                $values = [object[]]::new($names.Count)
                for ($i = 0; $i -lt $names.Count; $i++) {
                    $property = if ($row -is [System.Collections.IDictionary]) { $null } else { $row.PSObject.Properties[$names[$i]] }
                    $values[$i] = if ($row -is [System.Collections.IDictionary]) { $row[$names[$i]] } elseif ($null -ne $property) { $property.Value } else { $null }
                }
                $rows.Add($values)
            }
            $outcome.Rows = $rows.ToArray()
        }
        $bound = $payload['resultSetRowCountLimit']
        if ($bound -is [System.ValueType] -and [long]$bound -gt 0 -and $found.Count -gt [long]$bound) {
            $outcome.Error = 'overflow: {0} rows, over the app''s bound of {1} (resultSetRowCountLimit), which its connector refuses' -f $found.Count, $bound
            return $outcome
        }
        $outcome.Ok = $true
        return $outcome
    }
    $invoke = {
        param([string] $File)
        if ($route.Name -eq 'connector') {
            $call = & $cli $File -WithToken
            $refusal = Get-DemoRayfinTokenRefusal -Run $call
            if (-not $refusal) {
                return (& $fromCli $call 'azureCli')
            }
            # Not a refusal of the deploy's token, which 'rayfin up' took: nothing is recorded for a later run, and no
            # browser opens (2026-11-09 live finding: HTTP 401 from executeDaxQueries, then HTTP 200 from Execute Queries).
            $route.Name = 'executeQueries'
            $route.Refusal = $refusal
            Write-DemoLog -Message ('The {0} connector''s direct route refused the Azure CLI''s Power BI token ({1}), so the Insights app''s queries run through Power BI''s Execute Queries with the same token: no Rayfin sign-in is needed.' -f $connector, $refusal)
        }
        if ($route.Name -eq 'executeQueries') {
            return (& $fromExecuteQueries $File)
        }
        return (& $fromCli (& $cli $File) 'rayfinSignIn')
    }
    # The refusal in a few words, for a message; the evidence keeps all of it.
    $short = {
        param([string] $Text)
        if ($Text -match '\b(40[13])\b') {
            return ('HTTP {0}' -f $Matches[1])
        }
        if ($Text.Length -gt 120) {
            return ($Text.Substring(0, 120) + '...')
        }
        return $Text
    }

    if (-not $route.Name) {
        # No token and no -RayfinSignIn: nothing to run the queries with, and the CLI's own sign-in is no fallback.
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'The app''s queries weren''t checked: the check got no Power BI token from the Azure CLI, and the Rayfin CLI''s own sign-in runs them only with -RayfinSignIn, never as a fallback (2026-11-09).' -Evidence ([ordered]@{ connector = $connector; route = ''; auth = '' }) -Remediation 'Sign in with az login --tenant <tenantId> as the demo''s Fabric user, then check again with -CheckOnly and without -FabricToken: the script asks the Azure CLI for the token after its subscription guard. Or check with the Rayfin CLI''s own sign-in: -CheckOnly -RayfinSignIn.' -DocUrl $executeDoc))
        if ($Queries -eq 'All') {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The connector check didn''t run, so the app''s queries weren''t run.' -DocUrl $executeDoc))
        }
    }
    else {
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
                $counts = '{0} validation checks, {1} telemetry rows, and {2} incident windows' -f (& $count $values['ValidationRows']), (& $count $values['SnapshotRows']), (& $count $values['Incidents'])
                $connectorEvidence = [ordered]@{ connector = $connector; route = $probe.Route; auth = $probe.Auth; row = $values }
                if ($route.Refusal) {
                    $connectorEvidence['connectorRefusal'] = $route.Refusal
                }
                $message = if ($probe.Route -eq 'executeQueries') {
                    'Connector check passed through Power BI''s Execute Queries with the Azure CLI''s Power BI token, because the {0} connector''s direct route refused that token ({1}): {2} returned {3}. No Rayfin sign-in was needed.' -f $connector, (& $short $route.Refusal), $model, $counts
                }
                elseif ($probe.Auth -eq 'rayfinSignIn') {
                    'Connector check passed with the Rayfin CLI''s own sign-in (-RayfinSignIn): the {0} connector returned {1} from {2}.' -f $connector, $counts, $model
                }
                else {
                    'Connector check passed with the Azure CLI''s Power BI token: the {0} connector returned {1} from {2}.' -f $connector, $counts, $model
                }
                $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message $message -Evidence $connectorEvidence -DocUrl $(if ($probe.Route -eq 'executeQueries') { $executeDoc } else { $connectorDoc })))
            }
            else {
                $why = if ($probe.Error) { $probe.Error } else { 'the query returned no rows' }
                $failEvidence = [ordered]@{ connector = $connector; route = $probe.Route; auth = $probe.Auth }
                if ($route.Refusal) {
                    $failEvidence['connectorRefusal'] = $route.Refusal
                }
                if ($probe.Route -eq 'executeQueries') {
                    # Both routes failed with the Azure CLI's token: the fix depends on what Execute Queries answered.
                    $failEvidence['statusCode'] = $probe.StatusCode
                    $message = 'The connector check failed on both routes: the {0} connector''s direct route refused the Azure CLI''s Power BI token ({1}), and Power BI''s Execute Queries {2} {3}' -f $connector, (& $short $route.Refusal), $(if ($probe.StatusCode -gt 0) { 'answered' } else { 'couldn''t run:' }), $why
                    $fix = if ($WorkspaceId -notmatch $script:GuidPattern -or $SemanticModelId -notmatch $script:GuidPattern) {
                        'Pass -WorkspaceId and -SemanticModelId, or deploy the app first, which writes both to the stage''s rayfin/.env.'
                    }
                    else {
                        switch ($probe.StatusCode) {
                            401 { 'Power BI refused the Azure CLI''s token on both routes: sign in again with az login --tenant <tenantId> as the configured azureAccount, the demo''s Fabric user, who must be able to open the workspace in the Fabric portal; then check again with -CheckOnly.' }
                            403 { 'The signed-in user needs Read and Build on {0} (a workspace Contributor or higher has both), and the Fabric tenant setting Dataset Execute Queries REST API must be on for them (FABRIC.APP.EXECUTEQUERIES); then check again with -CheckOnly.' -f $model }
                            404 { '{0} wasn''t found in the workspace: deploy it with ./scripts/configure-powerbi.ps1, then check again with -CheckOnly.' -f $model }
                            { $_ -in 200, 400 } { 'The model rejected the connector check''s DAX, or returned no row for it: compare the query (fabric/app/src/data/queries.ts) with {0}''s TMDL, and check that the model is refreshed (./scripts/configure-powerbi.ps1 -CheckModelData).' -f $model }
                            default { 'Power BI didn''t answer the check{0}: check again with -CheckOnly in a few minutes.' -f $(if ($probe.StatusCode -gt 0) { ' (HTTP {0})' -f $probe.StatusCode } else { '' }) }
                        }
                    }
                }
                else {
                    $own = $probe.Auth -eq 'rayfinSignIn'
                    $message = 'The {0} connector didn''t return the connector check{1}: {2}' -f $connector, $(if ($own) { ' with the Rayfin CLI''s own sign-in' } else { '' }), $why
                    $fix = 'The signed-in user needs Read and Build on {0}; check that the model is deployed and refreshed (./scripts/configure-powerbi.ps1 -CheckModelData).{1}' -f $model, $(if ($own) { ' With -RayfinSignIn, the Rayfin CLI must be signed in to the demo''s tenant: -SignIn signs it in.' } else { '' })
                }
                $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message $message -Evidence $failEvidence -Remediation $fix -DocUrl $(if ($probe.Route -eq 'executeQueries') { $executeDoc } else { $connectorDoc })))
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
                    [pscustomobject]@{ Id = $id; Ok = $outcome.Ok; Rows = $outcome.Rows.Count; Error = $outcome.Error; Route = $outcome.Route }
                }
                $failed = @($outcomes | Where-Object { -not $_.Ok })
                $empty = @($outcomes | Where-Object { $_.Ok -and $_.Rows -eq 0 })
                $routes = @($outcomes | ForEach-Object { [string]$_.Route } | Select-Object -Unique)
                $through = if ($routes.Count -gt 1) {
                    'through the {0} connector''s direct route, then Power BI''s Execute Queries with the same Azure CLI token once that route refused it' -f $connector
                }
                elseif ($routes -contains 'executeQueries') {
                    'through Power BI''s Execute Queries with the Azure CLI''s Power BI token (the {0} connector''s direct route refused it)' -f $connector
                }
                elseif ($probe.Auth -eq 'rayfinSignIn') {
                    'through the {0} connector with the Rayfin CLI''s own sign-in' -f $connector
                }
                else {
                    'through the {0} connector with the Azure CLI''s Power BI token' -f $connector
                }
                $evidence = [ordered]@{ latestDay = $latestDay; incidentRange = $index['incidentRange']; route = ($routes -join ', '); auth = $probe.Auth; queries = @($outcomes | ForEach-Object { [ordered]@{ id = $_.Id; rows = $_.Rows; ok = $_.Ok; route = $_.Route } }) }
                if ($route.Refusal) {
                    $evidence['connectorRefusal'] = $route.Refusal
                }
                if ($routes -contains 'executeQueries') {
                    $evidence['rowBound'] = 'Execute Queries runs one query per request and has no resultSetRowCountLimit, so each result''s rows were compared with the app''s bound here.'
                }
                $queriesDoc = if ($routes -contains 'executeQueries') { $executeDoc } else { $connectorDoc }
                if ($failed.Count -gt 0) {
                    $fix = 'Compare the failing query (fabric/app/src/data/queries.ts) with the model''s TMDL; a renamed measure or column breaks it.'
                    if (@($failed | Where-Object { [string]$_.Error -like 'overflow*' }).Count -gt 0) {
                        $fix += ' A query over its row bound (overflow) needs a narrower window, or a larger rowLimit in the same file.'
                    }
                    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} of {1} app queries failed {2}: {3}' -f $failed.Count, $outcomes.Count, $through, (($failed | ForEach-Object { '{0} ({1})' -f $_.Id, $_.Error }) -join '; ')) -Evidence $evidence -Remediation $fix -DocUrl $queriesDoc))
                }
                elseif ($empty.Count -gt 0) {
                    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('All {0} app queries ran {1}; {2} returned no rows for the newest telemetry day {3}: {4}.' -f $outcomes.Count, $through, $empty.Count, $latestDay, (($empty | ForEach-Object { $_.Id }) -join ', ')) -Evidence $evidence -Remediation 'Run NB_DatabaseHub_LiveActivity (and a scenario) so the lakehouse has history for those visuals, then run the check again.' -DocUrl $queriesDoc))
                }
                else {
                    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message ('All {0} app queries returned rows {1} (newest telemetry day {2}).' -f $outcomes.Count, $through, $latestDay) -Evidence $evidence -DocUrl $queriesDoc))
                }
            }
            elseif ($Queries -eq 'All') {
                $results.Add((New-DemoResult -CheckId 'FABRIC.APP.QUERIES' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'The connector check failed, so the rest of the app''s queries weren''t run.' -DocUrl $connectorDoc))
            }
        }
        catch {
            $results.Add((New-DemoResult -CheckId 'FABRIC.APP.CONNECTOR' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('The connector check couldn''t run: {0}' -f (Protect-DemoRayfinText -Text $_.Exception.Message)) -Remediation 'Run the script again without -SkipInstall so the stage has its packages.' -DocUrl $connectorDoc))
        }
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
    # Nobody needs to open the app once what it depends on is verified (2026-11-09, user-directed: no user steps): it's
    # deployed, and every query it runs ran under the operator's identity. The note says exactly that, and that the app's
    # own route in the browser isn't checked: neither the connector's direct route nor Execute Queries crosses it (the
    # CLI's own comment on 'connector invoke --transport'; review of 2026-11-09).
    $connectorPassed = @($results | Where-Object { $_.checkId -eq 'FABRIC.APP.CONNECTOR' -and $_.status -eq 'Pass' }).Count -gt 0
    $queriesRecord = @($results | Where-Object { $_.checkId -eq 'FABRIC.APP.QUERIES' -and $_.status -in 'Pass', 'Warning' }) | Select-Object -First 1
    $hostingPassed = @($results | Where-Object { $_.checkId -eq 'FABRIC.APP.HOSTING' -and $_.status -eq 'Pass' }).Count -gt 0
    if ($connectorPassed -and $null -ne $queriesRecord -and ($Deployed -or $hostingPassed)) {
        $deployedText = if ($hostingPassed) {
            'the app is deployed{0}, and its hosting is protected: the hosted app refuses anonymous requests (FABRIC.APP.HOSTING)' -f $(if ($Deployed) { ' (FABRIC.APP.DEPLOY)' } else { '' })
        }
        else {
            'the app is deployed (FABRIC.APP.DEPLOY), though its hosting''s protection wasn''t confirmed (FABRIC.APP.HOSTING says why)'
        }
        $ran = @($queriesRecord.evidence['queries'])
        $withRows = @($ran | Where-Object { [int]$_['rows'] -gt 0 }).Count
        $dataText = if ($withRows -eq $ran.Count) {
            'every query it runs ({0}) returned data from {1} under your identity' -f $ran.Count, $model
        }
        elseif ($ran.Count - $withRows -eq 1) {
            'every query it runs ({0}) ran on {1} under your identity, and {2} returned data; the other one has no history for its window yet' -f $ran.Count, $model, $withRows
        }
        else {
            'every query it runs ({0}) ran on {1} under your identity, and {2} returned data; the other {3} have no history for their window yet' -f $ran.Count, $model, $withRows, ($ran.Count - $withRows)
        }
        $queryRoute = [string]$queriesRecord.evidence['route']
        $how = if ($queryRoute -match 'executeQueries' -and $queryRoute -match 'connector') { 'the connector''s direct route, then Power BI''s Execute Queries' } elseif ($queryRoute -eq 'executeQueries') { 'Power BI''s Execute Queries' } else { 'the connector''s direct route' }
        $message = 'Not needed: {0}; and {1} (FABRIC.APP.QUERIES, through {2}). What no script can check is the app''s own route in the browser: its embedded sign-in, then its backend, User Data Functions, and a delegated on-behalf-of call to the model, which none of these checks crosses. To see it, open {3} in the Fabric portal; it opens embedded and signs in by itself.' -f $deployedText, $dataText, $how, $where
        $verifiedBy = @(@(if ($Deployed) { 'FABRIC.APP.DEPLOY' }) + @(if ($hostingPassed) { 'FABRIC.APP.HOSTING' }) + @('FABRIC.APP.CONNECTOR', 'FABRIC.APP.QUERIES'))
        $results.Add((New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message $message -Evidence ([ordered]@{ entryPoint = 'workspace item page (embedded)'; verifiedBy = $verifiedBy; route = $queryRoute; inAppRouteChecked = $false }) -DocUrl 'https://learn.microsoft.com/fabric/apps/fabric-authentication'))
        return $results.ToArray()
    }
    $why = if (-not ($connectorPassed -and $null -ne $queriesRecord)) { 'its queries didn''t all run here (FABRIC.APP.CONNECTOR, FABRIC.APP.QUERIES)' } else { 'that it''s deployed wasn''t confirmed here (no deploy in this run, and FABRIC.APP.HOSTING didn''t pass)' }
    $results.Add((New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message ('A person must confirm the app in the browser: {0}, and its own route there (its sign-in, then its deployed route to the model) can''t be checked from a script.' -f $why) -Evidence @{ entryPoint = 'workspace item page (embedded)' } -Remediation ('In the Fabric portal, signed in as a user with access to the workspace, open {0}. The app opens embedded and signs in by itself. On Live links it shows "Connector check passed" with the validation, telemetry, and incident counts. Don''t open the hosted URL directly: that is a known preview limitation (the sign-in pop-up stops at "Page not accessible directly").' -f $where) -DocUrl 'https://learn.microsoft.com/fabric/apps/fabric-authentication'))
    return $results.ToArray()
}
