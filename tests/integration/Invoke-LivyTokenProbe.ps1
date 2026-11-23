#Requires -Version 7.4
<#
.SYNOPSIS
F35's token probe (2026-11-23): does Fabric's Livy API take the Azure CLI's Fabric token? It starts a Livy session in
the demo's lakehouse, runs SELECT 1, reads the history table's columns and row count, and deletes the session.
Read-only, except with -KeptValueModule, F35's smoke test, which writes only a scratch copy of the history table and
drops it.

.DESCRIPTION
Learn documents the Livy API for a Microsoft Entra app or a service principal, with the scopes Lakehouse.Execute.All,
Lakehouse.Read.All, Code.AccessFabric.All, and Code.AccessStorage.All. The Azure CLI's token carries only
user_impersonation. F35's history steps send the repository's code through Livy with that token, so this probe answers
whether Fabric accepts it before the steps are built on it. If it's refused, F35 runs the step as a notebook job
instead (Run On Demand Item Job).

What it does, in order, with the configured subscription's Azure CLI account and nothing else:
1. The subscription guard (Assert-DemoAzContext) and the CLI's Fabric token (Get-DemoFabricToken). It never signs in
   and never changes the Azure CLI's context. The token is never printed or saved.
2. The workspace and the lakehouse by name (Resolve-DemoFabricConfig without -Create, so it creates nothing).
3. Create Livy Session (POST .../livyapi/versions/2023-12-01/sessions, on the workspace's starter pool), then Get Livy
   Session until the session is idle.
4. Two statements in PySpark (kind pyspark, which F35's steps send): SELECT 1 through spark.sql, then one that reads
   telemetry_snapshots's columns and row count, and how the session sees the lakehouse. Nothing is written.
5. Delete Livy Session, always, after a failure or Ctrl+C too. A session that isn't deleted ends after 20 minutes idle.

With -KeptValueModule (F35's smoke test of fabric/history/kept_value.py, before the steps use it), in the same session
after step 4, and only on a scratch copy, so telemetry_snapshots itself is never changed:
a. CREATE TABLE telemetry_snapshots_f35smoke_<8 hex> AS SELECT * FROM telemetry_snapshots.
b. The module's text, as is, as one statement (it only defines names), then kept_value_step(spark, table=<the copy>):
   it adds the F35 columns to the copy and works out every row. Its JSON is the output's last line.
c. A read-back of the copy, per analysis: rows, rows worked out, rows with a kept value, and the sums of value and
   kept_value.
d. kept_value_step again, which should find nothing left to work out (a rerun changes nothing).
e. DROP TABLE of the copy, always, unless -KeepCopy.

Results (ADR 0012), printed and written as JSON lines to -OutputPath:
- PROBE.LIVY.SESSION: Pass when the session started; Fail when Fabric refused it (its status and error code are in the
  message); Manual action required when the workspace's capacity is paused.
- PROBE.LIVY.SQL: Pass when SELECT 1 returned 1.
- PROBE.LIVY.READ: Pass when the session read the history table (OneLake storage, through the same token).
- PROBE.LIVY.DELETE: Pass when the session was deleted.
- PROBE.LIVY.TOKEN: the answer. Pass when the Azure CLI's token started a session, ran SQL, and read the lakehouse;
  Fail when Fabric refused it.
- With -KeptValueModule: PROBE.KEPTVALUE.COPY, .LOAD, .STEP, .READBACK, .RERUN, and .DROP, one per step above, and
  PROBE.KEPTVALUE.SMOKE, its answer: Pass when the step worked out every row of the copy with form Kept and no error,
  the read-back found the three columns, and the rerun had nothing left.
Exit code: 0 without a Fail, 1 with one.

Sources (checked 2026-11-23):
- Livy API overview: https://learn.microsoft.com/fabric/data-engineering/api-livy-overview
- Authentication, scopes, and the endpoint: https://learn.microsoft.com/fabric/data-engineering/get-started-api-livy
- Session jobs: https://learn.microsoft.com/fabric/data-engineering/get-started-api-livy-session
- The Livy API's Swagger, linked from the page above:
  https://github.com/microsoft/fabric-samples/blob/main/docs-samples/data-engineering/Livy-API-swagger/swagger.json

.PARAMETER ConfigPath
The demo configuration (default: config/demo.config.json in -RepoRoot).

.PARAMETER RepoRoot
The checkout whose DbHubDemo module the probe loads (default: the one this script is in). It needs only functions that
main has had since 2026-11-16.

.PARAMETER OutputPath
Where the results go, as JSON lines (default: out/livy-token-probe.jsonl in -RepoRoot).

.PARAMETER TimeoutMinutes
How long to wait for the session to be idle, and for each statement.

.PARAMETER KeptValueModule
A kept_value.py to smoke-test on a scratch copy of the history table (the steps a. to e. above). Its first resolve
of a whole history can take minutes: raise -TimeoutMinutes for a long one.

.PARAMETER KeepCopy
With -KeptValueModule: keep the scratch copy for inspection; the result says how to drop it.

.EXAMPLE
pwsh -NoProfile -File ./tests/integration/Invoke-LivyTokenProbe.ps1 -ConfigPath ./config/demo.config.json

.EXAMPLE
pwsh -NoProfile -File ./tests/integration/Invoke-LivyTokenProbe.ps1 -ConfigPath ./config/demo.config.json -KeptValueModule ./fabric/history/kept_value.py -TimeoutMinutes 20
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = '',

    [string] $RepoRoot = (Join-Path -Path $PSScriptRoot -ChildPath '../..'),

    [string] $OutputPath = '',

    [ValidateRange(1, 30)]
    [int] $TimeoutMinutes = 10,

    [string] $KeptValueModule = '',

    [switch] $KeepCopy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
# That checkout's DbHubDemo, loaded again, unless the repository's own code runs this script (a test): its module, and the
# module's state, stay.
$entryRepoRoot = $RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$entryNested = $false
foreach ($entryFrame in @(Get-PSCallStack | Select-Object -Skip 1)) {
    $entryNested = $entryNested -or [bool]($entryFrame.ScriptName -and $entryFrame.ScriptName.StartsWith($entryRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))
}
$module = Import-Module -Name (Join-Path -Path $RepoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force:(-not $entryNested) -PassThru
if (-not $ConfigPath) {
    $ConfigPath = Join-Path -Path $RepoRoot -ChildPath 'config/demo.config.json'
}
if (-not $OutputPath) {
    $OutputPath = Join-Path -Path $RepoRoot -ChildPath 'out/livy-token-probe.jsonl'
}
$ConfigPath = Resolve-DemoUserPath -Path $ConfigPath
$OutputPath = Resolve-DemoUserPath -Path $OutputPath

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$docUrl = 'https://learn.microsoft.com/fabric/data-engineering/get-started-api-livy'
$results = [System.Collections.Generic.List[object]]::new()
$add = {
    param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
    $results.Add((New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl))
}
$finish = {
    $results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    Export-DemoResult -Result $results.ToArray() -Path $OutputPath
    Write-DemoLog -Message ('Results: {0}' -f $OutputPath)
    exit (Get-DemoExitCode -Result $results.ToArray())
}
# The module's own Fabric request (Invoke-DemoFabricRequest): the token stays a SecureString, goes only to the Fabric
# API, is renewed when it's about to expire or was refused, and transient failures are retried.
$send = {
    param([string] $Method, [string] $Uri, [System.Collections.IDictionary] $Body, [bool] $NotIdempotent)
    & $module {
        param([string] $Method, [string] $Uri, [securestring] $Token, [System.Collections.IDictionary] $Body, [bool] $NotIdempotent)
        $call = @{ Method = $Method; Uri = $Uri; Token = $Token; NotIdempotent = $NotIdempotent }
        if ($null -ne $Body) {
            $call['Body'] = $Body
        }
        Invoke-DemoFabricRequest @call
    } $Method $Uri $fabricToken $Body $NotIdempotent
}
$errorText = {
    param([pscustomobject] $Response)
    & $module { param([pscustomobject] $Response) Get-DemoFabricErrorText -Response $Response } $Response
}
$isCapacityInactive = {
    param([string] $Text)
    & $module { param([string] $Text) Test-DemoFabricCapacityInactiveText -Text $Text } $Text
}
# A property or a key, ignoring case, or $null. An array value is enumerated, so wrap the call in @() for a list.
$member = {
    param([object] $InputObject, [string] $Name)
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}
$excerpt = {
    param([string] $Text)
    $clean = (Protect-DemoText -Text ([string]$Text)).Trim()
    if ($clean.Length -gt 600) {
        return $clean.Substring(0, 600) + '...'
    }
    return $clean
}
# The smoke test's results by check, for its answer (PROBE.KEPTVALUE.SMOKE).
$smokeStatus = [ordered]@{}
$smokeAdd = {
    param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
    $smokeStatus[$CheckId] = $Status
    & $add $CheckId $Status $Message $Evidence $Remediation
}
# The JSON a statement's output ends with: its last line, or the last line that starts with -Prefix; $null without one.
$lastJson = {
    param([string] $Text, [string] $Prefix = '')
    $lines = @(([string]$Text) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Prefix) {
        $lines = @($lines | Where-Object { $_.StartsWith($Prefix, [System.StringComparison]::Ordinal) } | ForEach-Object { $_.Substring($Prefix.Length) })
    }
    if ($lines.Count -eq 0) {
        return $null
    }
    try {
        return ($lines[$lines.Count - 1] | ConvertFrom-Json -Depth 16)
    }
    catch {
        return $null
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath."
}
# F35's smoke test: the module is read before anything reaches Azure, so a wrong path costs nothing.
$keptValueText = ''
if ($KeptValueModule) {
    $KeptValueModule = Resolve-DemoUserPath -Path $KeptValueModule
    if (-not (Test-Path -LiteralPath $KeptValueModule -PathType Leaf)) {
        throw "The module to smoke-test isn't there: $KeptValueModule."
    }
    $keptValueText = [System.IO.File]::ReadAllText($KeptValueModule)
    if (-not $keptValueText.Contains('def kept_value_step(')) {
        throw "The module to smoke-test has no kept_value_step function: $KeptValueModule."
    }
}
$config = Get-DemoConfig -Path $ConfigPath
try {
    $results.Add((Assert-DemoAzContext -SubscriptionId $config['subscriptionId'] -TenantId $config['tenantId'] -Account ([string]$config['azureAccount'])))
}
catch {
    & $add 'PROBE.LIVY.TOKEN' 'Fail' ('The subscription guard failed, so no token was requested: {0}' -f $_.Exception.Message) @{} "Sign in once with 'az login --tenant <tenantId>' as the configured azureAccount, then run the probe again."
    & $finish
}
$fabricToken = Get-DemoFabricToken -SubscriptionId $config['subscriptionId']
$resolution = Resolve-DemoFabricConfig -Config $config -Token $fabricToken
$results.AddRange([object[]]@($resolution.Results))
$workspaceId = [string](& $member (& $member $resolution.Config 'fabric') 'workspaceId')
$lakehouseId = [string](& $member (& $member $resolution.Config 'fabric') 'lakehouseId')
if ($workspaceId -notmatch $guidPattern -or $lakehouseId -notmatch $guidPattern) {
    & $add 'PROBE.LIVY.TOKEN' 'Fail' 'The workspace and the lakehouse weren''t resolved (FABRIC.RESOLVE.* says why), so no session was started.' @{} 'Run it against a deployed environment, after deploy.ps1''s Fabric track.'
    & $finish
}

$sessionsUri = '{0}/workspaces/{1}/lakehouses/{2}/livyapi/versions/2023-12-01/sessions' -f 'https://api.fabric.microsoft.com/v1', $workspaceId, $lakehouseId
$sessionUri = ''
$sessionStarted = $false
# The smoke test's scratch copy, a name of its own, so it never meets the history table or another run's copy.
$copyName = 'telemetry_snapshots_f35smoke_{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)
$copyMade = $false
$runStatement = $null
$sqlOk = $false
$readOk = $false
$refused = $false
$deadline = { param([datetime] $Start) $Start.AddMinutes($TimeoutMinutes) }
# One pass: 'break probe' leaves it early, after its finally has deleted the session.
:probe foreach ($pass in @(1)) {
    try {
        #region 1. Create Livy Session, then Get Livy Session until it's idle.
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        Write-DemoLog -Message 'Starting a Livy session in the demo''s lakehouse, on the workspace''s starter pool.'
        $create = & $send 'Post' $sessionsUri @{ name = ('dbhub-livy-probe-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)) } $true
        $createEvidence = [ordered]@{ createStatus = [int]$create.StatusCode }
        if ($create.StatusCode -notin 200, 201, 202) {
            $text = & $errorText $create
            $createEvidence['error'] = $text
            if (& $isCapacityInactive $text) {
                & $add 'PROBE.LIVY.SESSION' 'Manual action required' ('The session wasn''t started: the workspace''s capacity is paused or inactive ({0}).' -f $text) $createEvidence 'Resume the capacity, then run the probe again.'
            }
            else {
                $refused = $create.StatusCode -in 401, 403
                & $add 'PROBE.LIVY.SESSION' 'Fail' ('Fabric refused to start a Livy session with the Azure CLI''s token: {0}' -f $text) $createEvidence
            }
            break probe
        }
        $sessionId = [string](& $member $create.Body 'id')
        if (-not $sessionId -or $sessionId -notmatch '^[A-Za-z0-9-]+$') {
            & $add 'PROBE.LIVY.SESSION' 'Fail' ('Fabric accepted the session (HTTP {0}), but its answer had no session ID.' -f $create.StatusCode) $createEvidence
            break probe
        }
        $sessionUri = '{0}/{1}' -f $sessionsUri, $sessionId
        $createEvidence['sessionId'] = $sessionId
        $states = [System.Collections.Generic.List[string]]::new()
        $state = ''
        $until = & $deadline ([datetime]::UtcNow)
        while ($true) {
            $read = & $send 'Get' $sessionUri $null $false
            if ($read.StatusCode -ne 200) {
                $createEvidence['getStatus'] = [int]$read.StatusCode
                $refused = $read.StatusCode -in 401, 403
                & $add 'PROBE.LIVY.SESSION' 'Fail' ('The session was accepted, but reading it failed: {0}' -f (& $errorText $read)) $createEvidence
                break probe
            }
            $state = [string](& $member $read.Body 'state')
            $acquisition = [string](& $member (& $member $read.Body 'fabricSessionStateInfo') 'state')
            $seen = if ($acquisition) { '{0} ({1})' -f $state, $acquisition } else { $state }
            if ($states.Count -eq 0 -or $states[$states.Count - 1] -ne $seen) {
                $states.Add($seen)
            }
            if ($state -eq 'idle') {
                break
            }
            if ($state -in 'dead', 'killed', 'error', 'success', 'shutting_down', 'not_submitted' -or $acquisition -in 'error', 'cancelled') {
                $why = [string](& $member (& $member $read.Body 'fabricSessionStateInfo') 'errorMessage')
                $infos = @(& $member $read.Body 'errorInfo')
                if (-not $why -and $infos.Count -gt 0 -and $null -ne $infos[0]) {
                    $why = '{0} {1}' -f (& $member $infos[0] 'errorCode'), (& $member $infos[0] 'message')
                }
                $createEvidence['states'] = $states.ToArray()
                & $add 'PROBE.LIVY.SESSION' 'Fail' ('The session ended before it was ready ({0}): {1}' -f $seen, (& $excerpt $why)) $createEvidence
                break probe
            }
            if ([datetime]::UtcNow -ge $until) {
                $createEvidence['states'] = $states.ToArray()
                & $add 'PROBE.LIVY.SESSION' 'Warning' ('The session wasn''t idle after {0} minutes (last state {1}).' -f $TimeoutMinutes, $seen) $createEvidence 'Run the probe again, with -TimeoutMinutes 20 if the capacity is busy.'
                break probe
            }
            Start-Sleep -Seconds 5
        }
        $sessionStarted = $true
        $createEvidence['states'] = $states.ToArray()
        $createEvidence['secondsToIdle'] = [int]$clock.Elapsed.TotalSeconds
        & $add 'PROBE.LIVY.SESSION' 'Pass' ('The Azure CLI''s token started a Livy session; it was idle after about {0} seconds.' -f [int]$clock.Elapsed.TotalSeconds) $createEvidence
        #endregion

        #region 2. Statements: SELECT 1, then a read of the history table.
        $runStatement = {
            param([string] $Kind, [string] $Code)
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $submit = & $send 'Post' ('{0}/statements' -f $sessionUri) @{ code = $Code; kind = $Kind } $true
            if ($submit.StatusCode -notin 200, 201) {
                return [pscustomobject]@{ Ok = $false; Status = [int]$submit.StatusCode; Text = (& $errorText $submit); Seconds = [int]$watch.Elapsed.TotalSeconds }
            }
            $statementId = [string](& $member $submit.Body 'id')
            if ($statementId -notmatch '^\d+$') {
                return [pscustomobject]@{ Ok = $false; Status = [int]$submit.StatusCode; Text = 'The statement was accepted, but its answer had no statement ID.'; Seconds = [int]$watch.Elapsed.TotalSeconds }
            }
            $statement = $submit.Body
            $limit = & $deadline ([datetime]::UtcNow)
            while ([string](& $member $statement 'state') -notin 'available', 'Error', 'error', 'cancelled') {
                if ([datetime]::UtcNow -ge $limit) {
                    return [pscustomobject]@{ Ok = $false; Status = 200; Text = ('Still {0} after {1} minutes.' -f (& $member $statement 'state'), $TimeoutMinutes); Seconds = [int]$watch.Elapsed.TotalSeconds }
                }
                Start-Sleep -Seconds 2
                $poll = & $send 'Get' ('{0}/statements/{1}' -f $sessionUri, $statementId) $null $false
                if ($poll.StatusCode -ne 200) {
                    return [pscustomobject]@{ Ok = $false; Status = [int]$poll.StatusCode; Text = (& $errorText $poll); Seconds = [int]$watch.Elapsed.TotalSeconds }
                }
                $statement = $poll.Body
            }
            $output = & $member $statement 'output'
            $data = & $member $output 'data'
            $plain = [string](& $member $data 'text/plain')
            if (-not $plain -and $null -ne $data) {
                $plain = $data | ConvertTo-Json -Depth 8 -Compress
            }
            $outputStatus = [string](& $member $output 'status')
            if ($outputStatus -ne 'ok') {
                $plain = '{0}: {1}' -f (& $member $output 'ename'), (& $member $output 'evalue')
            }
            # Full: the whole output, redacted, for the JSON lines it ends with; Text: an excerpt for the results.
            [pscustomobject]@{ Ok = ($outputStatus -eq 'ok'); Status = 200; Text = (& $excerpt $plain); Full = (Protect-DemoText -Text ([string]$plain)); Seconds = [int]$watch.Elapsed.TotalSeconds; State = [string](& $member $statement 'state') }
        }

        # PySpark, the kind F35's steps send; spark.sql runs the SQL.
        $sql = & $runStatement 'pyspark' 'print(spark.sql("SELECT 1 AS probe").collect()[0][0])'
        $sqlEvidence = [ordered]@{ kind = 'pyspark'; httpStatus = $sql.Status; seconds = $sql.Seconds; output = $sql.Text }
        $sqlOk = $sql.Ok -and $sql.Text.Trim() -eq '1'
        if ($sqlOk) {
            & $add 'PROBE.LIVY.SQL' 'Pass' ('SELECT 1 ran in the session and returned 1, in about {0} seconds.' -f $sql.Seconds) $sqlEvidence
        }
        else {
            $refused = $refused -or $sql.Status -in 401, 403
            & $add 'PROBE.LIVY.SQL' 'Fail' ('SELECT 1 didn''t return 1: {0}' -f $sql.Text) $sqlEvidence
        }

        $read = @(
            'import json'
            'probe = {}'
            'try:'
            '    probe["database"] = spark.catalog.currentDatabase()'
            '    probe["catalog"] = spark.catalog.currentCatalog()'
            'except Exception as error:'
            '    probe["catalogError"] = "%s: %s" % (type(error).__name__, str(error)[:300])'
            'try:'
            '    from notebookutils import runtime'
            '    probe["defaultLakehouse"] = bool(runtime.context.get("defaultLakehouseId"))'
            'except Exception as error:'
            '    probe["contextError"] = "%s: %s" % (type(error).__name__, str(error)[:300])'
            'try:'
            '    probe["exists"] = bool(spark.catalog.tableExists("telemetry_snapshots"))'
            '    if probe["exists"]:'
            '        frame = spark.table("telemetry_snapshots")'
            '        probe["columns"] = [field.name for field in frame.schema.fields]'
            '        probe["rows"] = frame.count()'
            'except Exception as error:'
            '    probe["error"] = "%s: %s" % (type(error).__name__, str(error)[:400])'
            'print("DBHUB_PROBE " + json.dumps(probe))'
        ) -join "`n"
        $lakehouse = & $runStatement 'pyspark' $read
        $readEvidence = [ordered]@{ kind = 'pyspark'; httpStatus = $lakehouse.Status; seconds = $lakehouse.Seconds; output = $lakehouse.Text }
        $line = @(([string]$lakehouse.Text) -split "`n" | Where-Object { $_ -like 'DBHUB_PROBE *' }) | Select-Object -First 1
        $found = $null
        if ($line) {
            try {
                $found = $line.Substring('DBHUB_PROBE '.Length) | ConvertFrom-Json -Depth 8
            }
            catch {
                $found = $null
            }
        }
        if ($null -ne $found) {
            foreach ($name in 'database', 'catalog', 'defaultLakehouse', 'exists', 'rows', 'columns', 'catalogError', 'contextError', 'error') {
                $value = & $member $found $name
                if ($null -ne $value) {
                    $readEvidence[$name] = $value
                }
            }
        }
        $rows = if ($null -ne $found) { & $member $found 'rows' } else { $null }
        $readOk = $lakehouse.Ok -and $null -ne $rows -and -not (& $member $found 'error')
        if ($readOk) {
            & $add 'PROBE.LIVY.READ' 'Pass' ('The session read telemetry_snapshots: {0:N0} rows, {1} columns.' -f [long]$rows, @(& $member $found 'columns').Count) $readEvidence
        }
        elseif ($lakehouse.Ok -and $null -ne $found -and (& $member $found 'exists') -eq $false) {
            & $add 'PROBE.LIVY.READ' 'Warning' 'The session ran PySpark, but the lakehouse has no telemetry_snapshots table yet, so a read of OneLake data wasn''t proven.' $readEvidence 'Run it against an environment with history (a Run all session, or deploy.ps1''s end).'
        }
        else {
            $refused = $refused -or $lakehouse.Status -in 401, 403
            & $add 'PROBE.LIVY.READ' 'Fail' ('The session didn''t read telemetry_snapshots: {0}' -f $lakehouse.Text) $readEvidence
        }
        #endregion

        #region F35's smoke test (-KeptValueModule): kept_value.py on a scratch copy of the history table, never on the table.
        if ($KeptValueModule) {
            if (-not $readOk) {
                & $smokeAdd 'PROBE.KEPTVALUE.COPY' 'Not selected' 'The history table wasn''t read (PROBE.LIVY.READ says why), so the smoke test didn''t run.'
                break probe
            }
            $copyCode = @(
                'import json'
                ('spark.sql("CREATE TABLE {0} AS SELECT * FROM telemetry_snapshots")' -f $copyName)
                ('print("DBHUB_PROBE " + json.dumps({{"rows": spark.table("{0}").count()}}))' -f $copyName)
            ) -join "`n"
            # Set first: a statement that stopped after the CREATE still leaves a copy for the drop below.
            $copyMade = $true
            $copy = & $runStatement 'pyspark' $copyCode
            $copied = & $lastJson $copy.Full 'DBHUB_PROBE '
            $copyEvidence = [ordered]@{ table = $copyName; seconds = $copy.Seconds; output = $copy.Text }
            if (-not $copy.Ok -or $null -eq $copied) {
                & $smokeAdd 'PROBE.KEPTVALUE.COPY' 'Fail' ('The scratch copy of telemetry_snapshots wasn''t made: {0}' -f $copy.Text) $copyEvidence
                break probe
            }
            $copyEvidence['rows'] = & $member $copied 'rows'
            & $smokeAdd 'PROBE.KEPTVALUE.COPY' 'Pass' ('Copied telemetry_snapshots to the scratch table {0}: {1:N0} rows, in about {2} seconds.' -f $copyName, [long](& $member $copied 'rows'), $copy.Seconds) $copyEvidence

            # The module's text as is, as one statement: it only defines names (the interface note).
            $load = & $runStatement 'pyspark' $keptValueText
            $loadEvidence = [ordered]@{ module = (Split-Path -Path $KeptValueModule -Leaf); characters = $keptValueText.Length; seconds = $load.Seconds; output = $load.Text }
            if (-not $load.Ok) {
                & $smokeAdd 'PROBE.KEPTVALUE.LOAD' 'Fail' ('The module didn''t load in the session: {0}' -f $load.Text) $loadEvidence
                break probe
            }
            & $smokeAdd 'PROBE.KEPTVALUE.LOAD' 'Pass' ('The module loaded in the session as one statement, in about {0} seconds.' -f $load.Seconds) $loadEvidence

            $stepCode = 'import json; print(json.dumps(kept_value_step(spark, table="{0}")))' -f $copyName
            $keys = @('version', 'table', 'exists', 'missing', 'added', 'form', 'scope', 'read', 'resolved', 'pending', 'attempts', 'seconds', 'error')
            $step = & $runStatement 'pyspark' $stepCode
            $stepJson = & $lastJson $step.Full
            $stepEvidence = [ordered]@{ seconds = $step.Seconds; output = $step.Text }
            if (-not $step.Ok -or $null -eq $stepJson) {
                & $smokeAdd 'PROBE.KEPTVALUE.STEP' 'Fail' ('kept_value_step didn''t print its JSON: {0}' -f $step.Text) $stepEvidence
                break probe
            }
            $stepEvidence['result'] = $stepJson
            $absent = @($keys | Where-Object { $null -eq $stepJson.PSObject.Properties[$_] })
            $stepError = [string](& $member $stepJson 'error')
            $pending = [long](& $member $stepJson 'pending')
            if ($absent.Count -gt 0) {
                & $smokeAdd 'PROBE.KEPTVALUE.STEP' 'Fail' ('kept_value_step''s JSON lacks {0}, which the interface says are always there.' -f ($absent -join ', ')) $stepEvidence
            }
            elseif ((& $member $stepJson 'exists') -ne $true -or [string](& $member $stepJson 'form') -ne 'Kept') {
                & $smokeAdd 'PROBE.KEPTVALUE.STEP' 'Fail' ('kept_value_step left the copy without its columns: exists {0}, form {1}, error {2}.' -f (& $member $stepJson 'exists'), (& $member $stepJson 'form'), $(if ($stepError) { $stepError } else { 'none' })) $stepEvidence
            }
            elseif ($stepError -or $pending -gt 0) {
                & $smokeAdd 'PROBE.KEPTVALUE.STEP' 'Warning' ('kept_value_step stopped with {0:N0} rows still to work out: {1}' -f $pending, $(if ($stepError) { $stepError } else { 'no error was given' })) $stepEvidence
            }
            else {
                & $smokeAdd 'PROBE.KEPTVALUE.STEP' 'Pass' ('kept_value_step added {0} to the copy and worked out {1:N0} rows ({2:N0} read, {3} MERGE attempt(s)) in {4} seconds; none left.' -f $(if (@(& $member $stepJson 'added').Count -gt 0) { @(& $member $stepJson 'added') -join ', ' } else { 'no column' }), [long](& $member $stepJson 'resolved'), [long](& $member $stepJson 'read'), (& $member $stepJson 'attempts'), (& $member $stepJson 'seconds')) $stepEvidence
            }

            $readBackCode = @(
                'import json'
                'from pyspark.sql import functions as F'
                ('frame = spark.table("{0}")' -f $copyName)
                'names = set(frame.columns)'
                'probe = {"columns": [c for c in ("grain_minutes", "kept_value", "resolved_at_utc") if c in names], "rows": frame.count()}'
                'if {"kept_value", "resolved_at_utc"} <= names:'
                '    grouped = frame.groupBy("analysis").agg(F.count(F.lit(1)).alias("rows"), F.count("resolved_at_utc").alias("resolved"), F.count("kept_value").alias("kept"), F.sum("value").alias("value"), F.sum("kept_value").alias("kept_sum"))'
                '    probe["analyses"] = {str(row["analysis"]): {"rows": row["rows"], "resolved": row["resolved"], "kept": row["kept"], "value": row["value"], "kept_sum": row["kept_sum"]} for row in grouped.collect()}'
                'print("DBHUB_PROBE " + json.dumps(probe, default=str))'
            ) -join "`n"
            $readBack = & $runStatement 'pyspark' $readBackCode
            $readBackJson = & $lastJson $readBack.Full 'DBHUB_PROBE '
            $readBackEvidence = [ordered]@{ seconds = $readBack.Seconds }
            if (-not $readBack.Ok -or $null -eq $readBackJson) {
                $readBackEvidence['output'] = $readBack.Text
                & $smokeAdd 'PROBE.KEPTVALUE.READBACK' 'Fail' ('The copy wasn''t read back: {0}' -f $readBack.Text) $readBackEvidence
            }
            else {
                $readBackEvidence['result'] = $readBackJson
                $columns = @(& $member $readBackJson 'columns')
                $analyses = & $member $readBackJson 'analyses'
                $resolvedRows = [long]0
                if ($null -ne $analyses) {
                    foreach ($entry in $analyses.PSObject.Properties) {
                        $resolvedRows += [long](& $member $entry.Value 'resolved')
                    }
                }
                $readBackEvidence['resolvedRows'] = $resolvedRows
                if ($columns.Count -ne 3) {
                    & $smokeAdd 'PROBE.KEPTVALUE.READBACK' 'Fail' ('The copy has {0} of the three F35 columns ({1}).' -f $columns.Count, ($columns -join ', ')) $readBackEvidence
                }
                elseif ($null -ne $stepJson.PSObject.Properties['resolved'] -and $resolvedRows -ne [long](& $member $stepJson 'resolved')) {
                    & $smokeAdd 'PROBE.KEPTVALUE.READBACK' 'Warning' ('The copy has {0:N0} rows worked out, where kept_value_step said it wrote {1:N0}.' -f $resolvedRows, [long](& $member $stepJson 'resolved')) $readBackEvidence
                }
                else {
                    & $smokeAdd 'PROBE.KEPTVALUE.READBACK' 'Pass' ('The copy has the three F35 columns and {0:N0} of its {1:N0} rows worked out; the evidence has each analysis''s rows and its sums of value and kept_value.' -f $resolvedRows, [long](& $member $readBackJson 'rows')) $readBackEvidence
                }
            }

            # A rerun works out only rows that aren't yet, so it should find none.
            $rerun = & $runStatement 'pyspark' $stepCode
            $rerunJson = & $lastJson $rerun.Full
            $rerunEvidence = [ordered]@{ seconds = $rerun.Seconds; output = $rerun.Text }
            if (-not $rerun.Ok -or $null -eq $rerunJson) {
                & $smokeAdd 'PROBE.KEPTVALUE.RERUN' 'Fail' ('kept_value_step''s rerun didn''t print its JSON: {0}' -f $rerun.Text) $rerunEvidence
            }
            else {
                $rerunEvidence['result'] = $rerunJson
                $again = [long](& $member $rerunJson 'resolved')
                $left = [long](& $member $rerunJson 'pending')
                $rerunError = [string](& $member $rerunJson 'error')
                if ($again -eq 0 -and $left -eq 0 -and -not $rerunError) {
                    & $smokeAdd 'PROBE.KEPTVALUE.RERUN' 'Pass' ('kept_value_step''s rerun found nothing left to work out, in {0} seconds.' -f (& $member $rerunJson 'seconds')) $rerunEvidence
                }
                else {
                    & $smokeAdd 'PROBE.KEPTVALUE.RERUN' 'Warning' ('kept_value_step''s rerun wrote {0:N0} rows and left {1:N0}{2}; a rerun should find nothing left.' -f $again, $left, $(if ($rerunError) { ' ({0})' -f $rerunError } else { '' })) $rerunEvidence
                }
            }
        }
        #endregion
    }
    finally {
        #region The smoke test's scratch copy, dropped before the session goes (unless -KeepCopy).
        if ($copyMade -and $sessionUri -and $null -ne $runStatement) {
            if ($KeepCopy) {
                & $smokeAdd 'PROBE.KEPTVALUE.DROP' 'Not selected' ('The scratch copy {0} was kept (-KeepCopy).' -f $copyName) ([ordered]@{ table = $copyName }) ('Drop it when you''re done, in a notebook cell in the workspace: spark.sql("DROP TABLE {0}").' -f $copyName)
            }
            else {
                try {
                    $drop = & $runStatement 'pyspark' ('spark.sql("DROP TABLE IF EXISTS {0}")' -f $copyName)
                    if ($drop.Ok) {
                        & $smokeAdd 'PROBE.KEPTVALUE.DROP' 'Pass' ('The scratch copy {0} was dropped.' -f $copyName) ([ordered]@{ table = $copyName })
                    }
                    else {
                        & $smokeAdd 'PROBE.KEPTVALUE.DROP' 'Warning' ('The scratch copy {0} wasn''t dropped: {1}' -f $copyName, $drop.Text) ([ordered]@{ table = $copyName }) ('Drop it in a notebook cell in the workspace: spark.sql("DROP TABLE {0}").' -f $copyName)
                    }
                }
                catch {
                    & $smokeAdd 'PROBE.KEPTVALUE.DROP' 'Warning' ('The scratch copy {0} wasn''t dropped: {1}' -f $copyName, (& $excerpt $_.Exception.Message)) ([ordered]@{ table = $copyName }) ('Drop it in a notebook cell in the workspace: spark.sql("DROP TABLE {0}").' -f $copyName)
                }
            }
        }
        #endregion
        #region 3. Delete Livy Session, whatever happened above.
        if ($sessionUri) {
            try {
                $delete = & $send 'Delete' $sessionUri $null $false
                if ($delete.StatusCode -in 200, 202, 204) {
                    & $add 'PROBE.LIVY.DELETE' 'Pass' 'The session was deleted.' @{ httpStatus = [int]$delete.StatusCode }
                }
                elseif ($delete.StatusCode -eq 404) {
                    & $add 'PROBE.LIVY.DELETE' 'Warning' 'The session was already gone when the probe deleted it.' @{ httpStatus = 404 }
                }
                else {
                    & $add 'PROBE.LIVY.DELETE' 'Warning' ('The session wasn''t deleted ({0}); it ends by itself after 20 minutes idle.' -f (& $errorText $delete)) @{ httpStatus = [int]$delete.StatusCode }
                }
            }
            catch {
                & $add 'PROBE.LIVY.DELETE' 'Warning' ('The session wasn''t deleted ({0}); it ends by itself after 20 minutes idle.' -f (& $excerpt $_.Exception.Message))
            }
        }
        #endregion
    }
}

if ($sessionStarted -and $sqlOk -and $readOk) {
    & $add 'PROBE.LIVY.TOKEN' 'Pass' 'Fabric''s Livy API accepted the Azure CLI''s token: a session started, ran SQL, and read the lakehouse''s history table. F35''s steps can use Livy.'
}
elseif ($refused) {
    & $add 'PROBE.LIVY.TOKEN' 'Fail' 'Fabric''s Livy API refused the Azure CLI''s token (see PROBE.LIVY.*). F35''s steps take the maintenance-notebook route (Run On Demand Item Job) instead.'
}
elseif ($sessionStarted -and $sqlOk) {
    & $add 'PROBE.LIVY.TOKEN' 'Warning' 'The Azure CLI''s token started a Livy session and ran SQL, but the history table''s read wasn''t proven (PROBE.LIVY.READ says why).'
}
else {
    & $add 'PROBE.LIVY.TOKEN' 'Warning' 'The probe didn''t reach an answer (PROBE.LIVY.* says why); it isn''t a refusal of the token.' @{} 'Fix what PROBE.LIVY.* names, then run the probe again.'
}
if ($KeptValueModule) {
    $needed = @('PROBE.KEPTVALUE.STEP', 'PROBE.KEPTVALUE.READBACK', 'PROBE.KEPTVALUE.RERUN')
    $failed = @($smokeStatus.Keys | Where-Object { $smokeStatus[$_] -eq 'Fail' })
    if ($failed.Count -gt 0) {
        & $add 'PROBE.KEPTVALUE.SMOKE' 'Fail' ('The kept-value smoke test failed: {0}.' -f ($failed -join ', '))
    }
    elseif (@($needed | Where-Object { $smokeStatus[$_] -eq 'Pass' }).Count -eq $needed.Count) {
        & $add 'PROBE.KEPTVALUE.SMOKE' 'Pass' 'kept_value.py ran through Livy on a scratch copy of the history: it added the columns, worked out every row, and a rerun found nothing left.'
    }
    else {
        & $add 'PROBE.KEPTVALUE.SMOKE' 'Warning' 'The kept-value smoke test didn''t pass all its steps (PROBE.KEPTVALUE.* says why).'
    }
}
& $finish
